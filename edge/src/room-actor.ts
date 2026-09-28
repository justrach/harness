/**
 * RoomActor — one Durable Object per agent room (`room1/{roomId}`), the live
 * actor over PostgreSQL's store of record (room-core.ts has the logic).
 *
 * The actor holds members, last seq and a ring of recent posts in memory,
 * assigns seq, and acks a post only after PostgreSQL has it; then it
 * broadcasts to connected sockets. It keeps nothing durable of its own but
 * two markers: `room` (its id, so a cold alarm knows what to load) and
 * `destroyed` (a tombstone that answers 410 room_destroyed forever). On wake
 * it reloads from PostgreSQL; an actor that had a room but finds no row was
 * swept or destroyed elsewhere, so it wipes itself — the two sides heal
 * each other.
 *
 * Ephemeral rooms die of idleness: the alarm fires at last activity plus
 * idle_ttl_s and every post pushes it out. The edge cron's sweeper covers
 * actors that never wake.
 *
 * Internal routes (the Worker has checked the bearer and org):
 *   POST /create?room=      GET /state?room=      GET /ws?room=&member=&device=
 *   POST /join  /leave  /post  /archive  /destroy       (?room=)
 *   GET  /messages?room=&member=&device=&since=&limit=&advance=1
 *   POST /wipe?room=        (Worker cron only; never routed from fetch)
 */
import { AUTH_USER_HEADER, type Env } from "./env";
import { PgRoomStore } from "./room-store-pg";
import { MemoryRoomStore, RoomCore, RoomError, memberKey, type Json, type RoomStore } from "./room-core";

/** The verified caller's org, stamped by the Worker next to the user. */
export const AUTH_ORG_HEADER = "x-harness-auth-org";

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

/** The hibernation tag that finds one member's sockets. */
const socketTag = (key: { member: string; deviceId: string }): string => JSON.stringify([key.member, key.deviceId]);

interface SocketTag {
  member: string;
  deviceId: string;
}

export class RoomActor implements DurableObject {
  private core: RoomCore | null = null;
  /** One load at a time: concurrent cold requests share it rather than each
   * building a RoomCore and the later one replacing the earlier mid-post. */
  private loading: Promise<RoomCore> | null = null;

  constructor(
    private readonly ctx: DurableObjectState,
    private readonly env: Env
  ) {}

  private store(): RoomStore {
    const store = roomStore(this.env);
    if (!store) throw new RoomError(503, "rooms_unavailable", "no room store configured");
    return store;
  }

  private async destroyed(): Promise<boolean> {
    return (await this.ctx.storage.get<boolean>("destroyed")) === true;
  }

  /** Drop everything, keep the tombstone, and tell connected sockets. */
  private async wipe(): Promise<void> {
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(JSON.stringify({ type: "destroyed" }));
        ws.close(4410, "room_destroyed");
      } catch {
        // Already gone.
      }
    }
    this.core = null;
    this.loading = null;
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
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
    const core = await RoomCore.load(this.store(), roomId);
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

  private async schedule(): Promise<void> {
    const at = this.core?.expiresAt();
    if (at === null || at === undefined) await this.ctx.storage.deleteAlarm();
    else await this.ctx.storage.setAlarm(at * 1000);
  }

  private broadcast(event: unknown): void {
    const frame = JSON.stringify(event);
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(frame);
      } catch {
        // A dead socket is cleaned up by its close event.
      }
    }
  }

  async fetch(request: Request): Promise<Response> {
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
    const userId = request.headers.get(AUTH_USER_HEADER) ?? "";
    const orgId = request.headers.get(AUTH_ORG_HEADER) ?? "";
    const path = url.pathname;

    if (path === "/wipe" && request.method === "POST") {
      await this.wipe();
      return json({ ok: true });
    }

    if (path === "/create" && request.method === "POST") {
      if (await this.destroyed()) throw new RoomError(410, "room_destroyed");
      if (this.core || (await this.ctx.storage.get<string>("room")) !== undefined) {
        throw new RoomError(409, "room_exists");
      }
      const body = await this.body(request);
      this.core = await RoomCore.create(this.store(), roomId, orgId, userId, body);
      await this.ctx.storage.put("room", roomId);
      await this.schedule();
      return json(this.core.snapshot(), 201);
    }

    const core = await this.loaded(roomId);
    // Rooms are one org's: anyone else gets the same answer as a missing room.
    if (core.room.orgId !== orgId) throw new RoomError(404, "room_not_found");

    if (path === "/ws" && request.method === "GET") {
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return json({ error: "expected websocket" }, 426);
      }
      const key = memberKey({ member: url.searchParams.get("member"), device: url.searchParams.get("device") ?? "" });
      if (!core.find(key)) throw new RoomError(403, "not_a_member");
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1], [socketTag(key)]);
      pair[1].serializeAttachment({ member: key.member, deviceId: key.deviceId } satisfies SocketTag);
      pair[1].send(JSON.stringify({ type: "hello", lastSeq: core.room.lastSeq }));
      return new Response(null, { status: 101, webSocket: pair[0] });
    }

    if (path === "/state" && request.method === "GET") return json(core.snapshot());

    if (path === "/messages" && request.method === "GET") {
      const key = memberKey({ member: url.searchParams.get("member"), device: url.searchParams.get("device") ?? "" });
      const since = Number(url.searchParams.get("since") ?? 0) || 0;
      const limit = Number(url.searchParams.get("limit") ?? 0) || 0;
      return json(await core.read(key, since, limit, url.searchParams.get("advance") === "1"));
    }

    if (request.method !== "POST") return json({ error: "not_found" }, 404);
    const body = await this.body(request);
    switch (path) {
      case "/join": {
        const member = await core.join(body);
        this.broadcast({ type: "member", member });
        return json({ member, lastSeq: core.room.lastSeq });
      }
      case "/leave": {
        const key = memberKey(body);
        await core.leave(body);
        for (const ws of this.ctx.getWebSockets(socketTag(key))) {
          try {
            ws.close(4403, "left");
          } catch {
            // Already closed.
          }
        }
        this.broadcast({ type: "left", member: key.member, device: key.deviceId });
        return json({ ok: true });
      }
      case "/post": {
        const result = await this.post(core, body);
        await this.schedule();
        this.broadcast({ type: "message", roomId: core.room.id, message: result.message });
        return json(result);
      }
      case "/archive": {
        const room = await core.setArchived(memberKey(body), body.archived !== false);
        this.broadcast({ type: "room", room });
        return json({ room });
      }
      case "/destroy": {
        await core.destroy(memberKey(body));
        await this.wipe();
        return json({ ok: true });
      }
      default:
        return json({ error: "not_found" }, 404);
    }
  }

  /** A post the store refused as stale gets one retry on reloaded state; a
   * failed write reloads (the append may have committed) and reports 503. */
  private async post(core: RoomCore, body: Json) {
    const roomId = core.room.id;
    try {
      return await core.post(body);
    } catch (err) {
      if (err instanceof RoomError && err.code !== "stale") throw err;
      const fresh = await this.reload(roomId);
      if (err instanceof RoomError) return fresh.post(body);
      throw err;
    }
  }

  /** Idle expiry for ephemeral rooms, on freshly loaded state. */
  async alarm(): Promise<void> {
    if (await this.destroyed()) return;
    const store = roomStore(this.env);
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
