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

interface SocketTag {
  member: string;
  deviceId: string;
}

export class RoomActor implements DurableObject {
  private core: RoomCore | null = null;

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
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    await this.ctx.storage.put("destroyed", true);
  }

  private async loaded(roomId: string): Promise<RoomCore> {
    if (this.core) return this.core;
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
      this.ctx.acceptWebSocket(pair[1], [`${key.member}\u0000${key.deviceId}`]);
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
        await core.leave(body);
        this.broadcast({ type: "left", member: body.member, device: body.device ?? "" });
        return json({ ok: true });
      }
      case "/post": {
        const result = await core.post(body);
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

  /** Idle expiry for ephemeral rooms. */
  async alarm(): Promise<void> {
    if (await this.destroyed()) return;
    const store = roomStore(this.env);
    if (!store) return;
    const roomId = this.core?.room.id ?? (await this.ctx.storage.get<string>("room"));
    if (!roomId) return;
    const fresh = await RoomCore.load(store, roomId);
    if (!fresh) {
      await this.wipe();
      return;
    }
    this.core = fresh;
    const at = fresh.expiresAt();
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
