/**
 * RoomActor — one Durable Object per agent room (`room1/{roomId}`), the live
 * actor over PostgreSQL's store of record (room-core.ts has the logic).
 *
 * The actor holds members, grants, last seq and a ring of recent posts in
 * memory, assigns seq, and acks a post only after PostgreSQL has it; then it
 * broadcasts to connected sockets. It keeps nothing durable of its own but
 * two markers: `room` (its id, so a cold alarm knows what to load) and
 * `destroyed` (a tombstone that answers 410 room_destroyed forever). On wake
 * it reloads from PostgreSQL; an actor that had a room but finds no row was
 * swept or destroyed elsewhere, so it wipes itself — the two sides heal
 * each other.
 *
 * The caller is the user the Worker verified from the bearer (never the
 * request body). A post that wakes another person's chat, once their rules
 * allow it, nudges that chat's device with {@link ROOM_WAKES_NUDGE}; their
 * engine then collects its wakes from `GET /rooms/wakes`.
 *
 * Ephemeral rooms die of idleness: the alarm fires at last activity plus
 * idle_ttl_s and every post pushes it out. The edge cron's sweeper covers
 * actors that never wake.
 *
 * Internal routes (the Worker has checked the bearer):
 *   POST /create?room=   GET /state?room=   GET /ws?room=&member=&device=
 *   GET  /messages?room=&member=&device=&since=&limit=&advance=1
 *   POST /join /leave /post /archive /destroy /invite /accept /decline
 *        /remove /wakes /release                                   (?room=)
 *   POST /wipe?room=     (Worker cron only; never routed from fetch)
 */
import { AUTH_USER_HEADER, type Env } from "./env";
import { PgRoomStore } from "./room-store-pg";
import { LedgerRoomStore } from "./room-ledger";
import {
  MemoryRoomStore,
  RoomCore,
  RoomError,
  memberKey,
  type Caller,
  type Json,
  type MemberKey,
  type RoomStore
} from "./room-core";

/** The verified caller's org, stamped by the Worker next to the user. New
 * rooms record it; access is by grant, not org. */
export const AUTH_ORG_HEADER = "x-harness-auth-org";

/** The chat id a device nudge carries when it means "you have room wakes":
 * not a chat (chat ids are UUIDs), so no chat doc is ever opened for it. */
export const ROOM_WAKES_NUDGE = "rooms-wakes";

const MAX_BODY_BYTES = 64 * 1024;

const json = (value: unknown, status = 200): Response =>
  new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" }
  });

const fail = (err: RoomError): Response => json({ error: err.code, message: err.message }, err.status);

/** `wrangler dev` without Hyperdrive: one isolate, so a module-level map
 * behaves like a shared database for local testing. Never used in prod. */
const devStore = new MemoryRoomStore();

export function roomStore(env: Env): RoomStore | undefined {
  if (env.HYPERDRIVE) return new PgRoomStore(env);
  return env.AUTH_MODE === "dev" ? devStore : undefined;
}

/** Run `fn` inside a store session when the store has them (one database
 * connection for the whole request). */
const inSession = <T>(store: RoomStore | undefined, fn: () => Promise<T>): Promise<T> =>
  store instanceof PgRoomStore || store instanceof LedgerRoomStore ? store.session(fn) : fn();

/** A flush after the first write of a quiet spell goes out at once; later
 * writes ride the alarm this long after the last flush. */
const FLUSH_EVERY_MS = 1000;
/** After a failed flush, try again this much later. */
const FLUSH_RETRY_MS = 5000;
/** The alarm is only the flusher's safety net (an evicted actor, a flush that
 * kept failing): an in-memory timer does the work, so the alarm (a storage
 * write that holds the actor's input gate) is set rarely. */
const FLUSH_SAFETY_MS = 30_000;

/** The hibernation tag that finds one member's sockets. */
const socketTag = (key: MemberKey): string => JSON.stringify([key.member, key.deviceId]);

interface SocketTag {
  member: string;
  deviceId: string;
  userId: string;
}

export class RoomActor implements DurableObject {
  private core: RoomCore | null = null;
  /** The actor's one store: requests share its database connection. */
  private storeInstance: RoomStore | undefined;
  /** One load at a time: concurrent cold requests share it rather than each
   * building a RoomCore and the later one replacing the earlier mid-post. */
  private loading: Promise<RoomCore> | null = null;
  /** The ledger's write-behind: one flush at a time, and when the last ended. */
  private flushing: Promise<void> | null = null;
  private lastFlushAt = 0;
  /** The safety-net alarm time for unflushed rows (null: nothing waiting). */
  private flushDueAt: number | null = null;
  /** The in-memory timer for the next flush. */
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  /** What the alarm is currently set to, so unchanged schedules skip the write. */
  private alarmAt: number | null | undefined = undefined;

  constructor(
    private readonly ctx: DurableObjectState,
    private readonly env: Env
  ) {}

  /** `ROOM_HOP_DECAY_S` (seconds) overrides the default decay: tests shorten it. */
  private options() {
    const decay = Number(this.env.ROOM_HOP_DECAY_S);
    return Number.isFinite(decay) && decay > 0 ? { hopDecayS: decay } : {};
  }

  /** The ledger (the room's state in this actor's SQLite, written behind to
   * PostgreSQL) unless ROOM_LEDGER=off; without Hyperdrive, the dev store. */
  private makeStore(): RoomStore | undefined {
    if (this.env.HYPERDRIVE && this.env.ROOM_LEDGER !== "off") {
      return new LedgerRoomStore(this.ctx.storage, new PgRoomStore(this.env), () => this.onLedgerWrite());
    }
    return roomStore(this.env);
  }

  private ledger(): LedgerRoomStore | null {
    return this.storeInstance instanceof LedgerRoomStore ? this.storeInstance : null;
  }

  private store(): RoomStore {
    this.storeInstance ??= this.makeStore();
    if (!this.storeInstance) throw new RoomError(503, "rooms_unavailable", "no room store configured");
    return this.storeInstance;
  }

  private async destroyed(): Promise<boolean> {
    return (await this.ctx.storage.get<boolean>("destroyed")) === true;
  }

  private closeSockets(sockets: WebSocket[], code: number, reason: string, notice?: unknown): void {
    for (const ws of sockets) {
      try {
        if (notice) ws.send(JSON.stringify(notice));
        ws.close(code, reason);
      } catch {
        // Already gone.
      }
    }
  }

  /** Drop everything, keep the tombstone, and tell connected sockets. */
  private async wipe(): Promise<void> {
    this.closeSockets(this.ctx.getWebSockets(), 4410, "room_destroyed", { type: "destroyed" });
    this.core = null;
    this.loading = null;
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    this.ledger()?.forget();
    this.flushDueAt = null;
    this.alarmAt = null;
    if (this.flushTimer) clearTimeout(this.flushTimer);
    this.flushTimer = null;
    await this.ctx.storage.put("destroyed", true);
  }

  private loaded(roomId: string): Promise<RoomCore> {
    if (this.core) return Promise.resolve(this.core);
    this.loading ??= this.load(roomId).finally(() => {
      this.loading = null;
    });
    return this.loading;
  }

  private async load(roomId: string): Promise<RoomCore> {
    if (await this.destroyed()) throw new RoomError(410, "room_destroyed");
    const core = await RoomCore.load(this.store(), roomId, undefined, this.options());
    if (!core) {
      if ((await this.ctx.storage.get<string>("room")) !== undefined) {
        await this.wipe();
        throw new RoomError(410, "room_destroyed");
      }
      throw new RoomError(404, "room_not_found");
    }
    this.core = core;
    await this.schedule();
    return core;
  }

  /** Drop the in-memory room and read it back: after a write the store
   * refused or that failed midway, memory can't be trusted (a lost ack may
   * have committed). A room that's gone is wiped (410). */
  private reload(roomId: string): Promise<RoomCore> {
    this.core = null;
    return this.loaded(roomId);
  }

  /** One alarm serves both idle expiry and the ledger's safety net. A
   * schedule that wouldn't change it writes nothing. */
  private async schedule(): Promise<void> {
    const expiry = this.core?.expiresAt();
    const times = [expiry == null ? null : expiry * 1000, this.flushDueAt].filter((t): t is number => t !== null);
    const at = times.length ? Math.min(...times) : null;
    if (at === this.alarmAt) return;
    this.alarmAt = at;
    if (at === null) await this.ctx.storage.deleteAlarm();
    else await this.ctx.storage.setAlarm(at);
  }

  /** A local write happened: flush now if we haven't lately, else on a timer;
   * make sure the safety-net alarm exists while anything is unflushed. */
  private onLedgerWrite(): void {
    const now = Date.now();
    if (this.flushDueAt === null) {
      this.flushDueAt = now + FLUSH_SAFETY_MS;
      this.ctx.waitUntil(this.schedule());
    }
    if (this.flushing || this.flushTimer) return;
    const wait = this.lastFlushAt + FLUSH_EVERY_MS - now;
    if (wait <= 0) {
      this.ctx.waitUntil(this.flushNow());
      return;
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = null;
      this.ctx.waitUntil(this.flushNow());
    }, wait);
  }

  /** Write the ledger behind until nothing is left (or it fails, or the room
   * turns out to be gone, which wipes). Concurrent callers share one run. */
  private flushNow(): Promise<void> {
    const ledger = this.ledger();
    const roomId = this.core?.room.id;
    if (!ledger || !roomId) return Promise.resolve();
    this.flushing ??= (async () => {
      try {
        for (let i = 0; i < 20; i++) {
          const result = await ledger.flush(roomId);
          if (result === "gone") {
            await this.wipe();
            return;
          }
          if (result === "idle" || !ledger.hasUnflushed()) break;
        }
        // Writes that arrived during the flush get their own (timer) flush.
        this.flushDueAt = ledger.hasUnflushed() ? Date.now() + FLUSH_SAFETY_MS : null;
      } catch (err) {
        console.error(JSON.stringify({ event: "room_ledger_flush_failed", room: roomId, error: String(err) }));
        this.flushDueAt = Date.now() + FLUSH_RETRY_MS;
      } finally {
        this.lastFlushAt = Date.now();
        this.flushing = null;
        await this.schedule().catch(() => {});
        if (this.flushDueAt !== null && !this.flushTimer && ledger.hasUnflushed()) {
          this.flushTimer = setTimeout(() => {
            this.flushTimer = null;
            this.ctx.waitUntil(this.flushNow());
          }, FLUSH_EVERY_MS);
        }
      }
    })();
    return this.flushing;
  }

  /** Live events go only to sockets whose person can still see the room. */
  private broadcast(core: RoomCore, event: unknown): void {
    const frame = JSON.stringify(event);
    for (const ws of this.ctx.getWebSockets()) {
      const tag = ws.deserializeAttachment() as SocketTag | null;
      if (!tag || !core.canSee({ userId: tag.userId })) continue;
      try {
        ws.send(frame);
      } catch {
        // A dead socket is cleaned up by its close event.
      }
    }
  }

  async fetch(request: Request): Promise<Response> {
    this.storeInstance ??= this.makeStore();
    return inSession(this.storeInstance, () => this.handle(request));
  }

  private async handle(request: Request): Promise<Response> {
    try {
      return await this.route(request);
    } catch (err) {
      if (err instanceof RoomError) return fail(err);
      console.error(JSON.stringify({ event: "room_error", error: String(err) }));
      // A write that failed on a missing row (swept or destroyed elsewhere)
      // means this actor is serving a room that no longer exists.
      const roomId = new URL(request.url).searchParams.get("room");
      if (this.core && roomId) {
        try {
          await this.reload(roomId);
        } catch (gone) {
          if (gone instanceof RoomError) return fail(gone);
        }
      }
      return json({ error: "store_unavailable" }, 503);
    }
  }

  private async body(request: Request): Promise<Json> {
    const text = await request.text();
    if (text.length > MAX_BODY_BYTES) throw new RoomError(413, "too_large");
    try {
      const value: unknown = text ? JSON.parse(text) : {};
      if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error();
      return value as Json;
    } catch {
      throw new RoomError(400, "bad_request", "body: a JSON object");
    }
  }

  private async route(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const roomId = url.searchParams.get("room") ?? "";
    const caller: Caller = { userId: request.headers.get(AUTH_USER_HEADER) ?? "" };
    const orgId = request.headers.get(AUTH_ORG_HEADER) ?? "";
    const path = url.pathname;

    if (path === "/wipe" && request.method === "POST") {
      await this.wipe();
      return json({ ok: true });
    }
    if (!caller.userId) throw new RoomError(401, "unauthenticated");

    if (path === "/create" && request.method === "POST") {
      if (await this.destroyed()) throw new RoomError(410, "room_destroyed");
      if (this.core || (await this.ctx.storage.get<string>("room")) !== undefined) {
        throw new RoomError(409, "room_exists");
      }
      const body = await this.body(request);
      this.core = await RoomCore.create(this.store(), roomId, orgId, caller, body, undefined, this.options());
      await this.ctx.storage.put("room", roomId);
      await this.schedule();
      return json(this.core.snapshot(caller), 201);
    }

    let core = await this.loaded(roomId);
    // Grants also change outside this actor (the console accepts invites in
    // PostgreSQL directly): re-read once before turning someone away.
    if (!core.canSee(caller)) core = await this.reload(roomId);

    // The invitee answers before they can see anything else.
    if ((path === "/accept" || path === "/decline") && request.method === "POST") {
      const grant = await core.respond(caller, path === "/accept");
      if (grant) this.broadcast(core, { type: "person", userId: caller.userId });
      return json({ ok: true, grant });
    }

    if (path === "/ws" && request.method === "GET") {
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return json({ error: "expected websocket" }, 426);
      }
      const key = memberKey({ member: url.searchParams.get("member"), device: url.searchParams.get("device") ?? "" });
      const member = core.find(key);
      if (!core.canSee(caller)) throw new RoomError(404, "room_not_found");
      if (!member || member.userId !== caller.userId) throw new RoomError(403, "not_your_member");
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1], [socketTag(key)]);
      pair[1].serializeAttachment({ member: key.member, deviceId: key.deviceId, userId: caller.userId } satisfies SocketTag);
      pair[1].send(JSON.stringify({ type: "hello", lastSeq: core.room.lastSeq }));
      return new Response(null, { status: 101, webSocket: pair[0] });
    }

    if (path === "/state" && request.method === "GET") return json(core.snapshot(caller));

    if (path === "/messages" && request.method === "GET") {
      const key = memberKey({ member: url.searchParams.get("member"), device: url.searchParams.get("device") ?? "" });
      const since = Number(url.searchParams.get("since") ?? 0) || 0;
      const limit = Number(url.searchParams.get("limit") ?? 0) || 0;
      return json(await core.read(caller, key, since, limit, url.searchParams.get("advance") === "1"));
    }

    if (request.method !== "POST") return json({ error: "not_found" }, 404);
    const body = await this.body(request);
    switch (path) {
      case "/join": {
        const member = await core.join(caller, body);
        this.broadcast(core, { type: "member", member });
        return json({ member, lastSeq: core.room.lastSeq });
      }
      case "/leave": {
        const key = await core.leave(caller, body);
        this.closeSockets(this.ctx.getWebSockets(socketTag(key)), 4403, "left");
        this.broadcast(core, { type: "left", member: key.member, device: key.deviceId });
        return json({ ok: true });
      }
      case "/post": {
        const result = await this.post(core, caller, body);
        await this.schedule();
        if (!result.duplicate) {
          this.broadcast(core, { type: "message", roomId: core.room.id, message: result.message });
          // Another person's engine reads the wake's body from PostgreSQL, so
          // the post must be written behind before their device is nudged.
          if (result.external.some((w) => w.verdict === "allowed")) {
            this.ctx.waitUntil(this.flushNow().then(() => this.nudgeExternal(result.external)));
          }
        }
        return json(result);
      }
      case "/invite":
        return json(await core.invite(caller, body));
      case "/remove": {
        const userId = typeof body.userId === "string" ? body.userId : caller.userId;
        const gone = await core.removePerson(caller, userId);
        for (const key of gone) this.closeSockets(this.ctx.getWebSockets(socketTag(key)), 4403, "removed");
        this.broadcast(core, { type: "person_left", userId });
        return json({ ok: true, members: gone });
      }
      case "/wakes":
        return json({ grant: await core.setExternalWakes(caller, body) });
      case "/release":
        await core.release(caller, body);
        return json({ ok: true });
      case "/archive": {
        const room = await core.setArchived(caller, body.archived !== false);
        this.broadcast(core, { type: "room", room });
        return json({ room });
      }
      case "/destroy": {
        await core.destroy(caller);
        await this.wipe();
        return json({ ok: true });
      }
      default:
        return json({ error: "not_found" }, 404);
    }
  }

  /** A post the store refused as stale gets one retry on reloaded state; a
   * failed write reloads (the append may have committed) and reports 503. */
  private async post(core: RoomCore, caller: Caller, body: Json) {
    const roomId = core.room.id;
    try {
      return await core.post(caller, body);
    } catch (err) {
      if (err instanceof RoomError && err.code !== "stale") throw err;
      const fresh = await this.reload(roomId);
      if (err instanceof RoomError) return fresh.post(caller, body);
      throw err;
    }
  }

  /** Tell each allowed target's device it has room wakes to collect. The
   * device room queues the nudge durably while the device is offline. */
  private async nudgeExternal(external: { deviceId: string; userId: string; verdict: string }[]): Promise<void> {
    const devices = new Map<string, string>();
    for (const w of external) if (w.verdict === "allowed" && w.deviceId) devices.set(w.deviceId, w.userId);
    await Promise.all(
      [...devices].map(([deviceId, userId]) =>
        this.env.DEVICE_ROOMS.get(this.env.DEVICE_ROOMS.idFromName(`d2/${deviceId}`))
          .fetch("https://device/nudge", {
            method: "POST",
            headers: { [AUTH_USER_HEADER]: userId, "content-type": "application/json" },
            body: JSON.stringify({ chatId: ROOM_WAKES_NUDGE })
          })
          .catch((err) =>
            console.error(JSON.stringify({ event: "room_wake_nudge_failed", device: deviceId, error: String(err) }))
          )
      )
    );
  }

  /** Idle expiry for ephemeral rooms, on freshly loaded state. */
  async alarm(): Promise<void> {
    this.storeInstance ??= this.makeStore();
    return inSession(this.storeInstance, async () => {
      // A ledger left unflushed (the actor was evicted, or PostgreSQL was
      // down) lands first; then idle expiry is judged on fresh state.
      const ledger = this.ledger();
      if (ledger) {
        const roomId = this.core?.room.id ?? (await this.ctx.storage.get<string>("room"));
        if (roomId && !this.core) {
          try {
            await this.loaded(roomId);
          } catch {
            return;
          }
        }
        this.flushDueAt = null;
        this.alarmAt = null; // it just fired
        await this.flushNow();
        if (await this.destroyed()) return;
      }
      await this.expire();
    });
  }

  private async expire(): Promise<void> {
    if (await this.destroyed()) return;
    const store = this.storeInstance;
    const roomId = this.core?.room.id ?? (await this.ctx.storage.get<string>("room"));
    if (!store || !roomId) return;
    let core: RoomCore;
    try {
      core = await this.reload(roomId);
    } catch {
      return; // Gone (and wiped) or the store is down; the sweeper covers it.
    }
    const at = core.expiresAt();
    if (at !== null && at * 1000 <= Date.now()) {
      await store.destroy(roomId);
      await this.wipe();
    } else {
      await this.schedule();
    }
  }

  async webSocketMessage(): Promise<void> {
    // Rooms are read over HTTP and pushed over the socket; inbound frames
    // are ignored (ping/pong rides the runtime's auto-response).
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    try {
      ws.close(code === 1005 ? 1000 : code, "closing");
    } catch {
      // Already closed.
    }
  }
}
