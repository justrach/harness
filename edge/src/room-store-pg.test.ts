import { Client } from "pg";
import { describe, expect, it, vi } from "vitest";
import { issueRefreshCredential, verifyRefreshCredential } from "./auth";
import { storeCrashReports, type CrashRow } from "./crash-reports";
import type { Env } from "./env";
import { PgPool, type PgClient, type PgEnv, type PgQueryResult } from "./pg";
import { ROOM_ACTOR_LOCATION_HINT, roomActorStub, userRoomIds } from "./room-actor";
import type { LedgerBatch, MemberRow, MessageRow, RoomRow } from "./room-core";
import { PgRoomStore } from "./room-store-pg";

function countingEnv(handler?: (sql: string, values?: unknown[]) => PgQueryResult) {
  let connects = 0;
  let ends = 0;
  const queries: string[] = [];
  const env: PgEnv = {
    HYPERDRIVE: { connectionString: "postgresql://unit-test/db" } as Hyperdrive,
    pgClientFactory: () => ({
      async connect() {
        connects++;
      },
      async query<R = Record<string, unknown>>(sql: string, values?: unknown[]): Promise<PgQueryResult<R>> {
        queries.push(sql);
        if (handler) return handler(sql, values) as PgQueryResult<R>;
        return { rows: [], rowCount: 0 };
      },
      async end() {
        ends++;
      }
    })
  };
  return {
    env,
    stats: () => ({ connects, ends, queries })
  };
}

const sampleRoom = (id = "room_0123456789abcdef01234567"): RoomRow => ({
  id,
  orgId: "user-42",
  createdBy: "42",
  name: "perf-test-room",
  kind: "ephemeral",
  parentChat: null,
  idleTtlS: 3600,
  projectRef: "proj-1",
  lastSeq: 0,
  createdAt: 1_790_000_000,
  lastActivityAt: 1_790_000_000,
  archivedAt: null
});

const sampleOwner = (): MemberRow => ({
  member: "lead",
  memberKind: "graff",
  memberRef: null,
  deviceId: "dev-1",
  userId: "42",
  role: "owner",
  readSeq: 0,
  joinedAt: 1_790_000_000
});

const sampleMsg = (seq: number, body = `msg-${seq}`): MessageRow => ({
  seq,
  sender: "lead",
  senderDevice: "dev-1",
  senderUserId: "42",
  fromUser: false,
  kind: "message",
  toMember: null,
  body,
  replyTo: null,
  mentions: [],
  hop: 1,
  clientId: `cid-${seq}`,
  claimKey: null,
  createdAt: 1_790_000_000 + seq
});

describe("RoomActor APAC placement", () => {
  it("hints every RoomActor Durable Object to apac while leaving room naming intact", () => {
    const calls: Array<{ id: unknown; options: unknown }> = [];
    const ns = {
      idFromName: (name: string) => ({ name }),
      get: (id: unknown, options?: unknown) => {
        calls.push({ id, options });
        return {} as DurableObjectStub;
      }
    } as unknown as DurableObjectNamespace;

    roomActorStub(ns, "room_abc123");
    expect(ROOM_ACTOR_LOCATION_HINT).toBe("apac");
    expect(calls).toEqual([{ id: { name: "room1/room_abc123" }, options: { locationHint: "apac" } }]);
  });
});

describe("PgPool bounded connection reuse & eviction", () => {
  it("reuses warm connections across sequential calls, caps maxIdle, and evicts after idleMs", async () => {
    const { env, stats } = countingEnv(() => ({ rows: [{ ok: 1 }], rowCount: 1 }));
    const pool = new PgPool(env, { maxIdle: 2, idleMs: 40 });

    // 10 sequential calls reuse a single connection (1 connect instead of 10).
    for (let i = 0; i < 10; i++) {
      await pool.withClient(async (pg) => pg.query("SELECT 1"));
    }
    expect(stats().connects).toBe(1);
    expect(stats().ends).toBe(0);
    expect(pool.idleCount).toBe(1);

    // 3 concurrent calls open 2 more (total 3), but maxIdle=2 immediately closes the 3rd on release.
    await Promise.all([
      pool.withClient(async (pg) => {
        await new Promise((r) => setTimeout(r, 10));
        return pg.query("SELECT 1");
      }),
      pool.withClient(async (pg) => {
        await new Promise((r) => setTimeout(r, 10));
        return pg.query("SELECT 1");
      }),
      pool.withClient(async (pg) => {
        await new Promise((r) => setTimeout(r, 10));
        return pg.query("SELECT 1");
      })
    ]);
    expect(stats().connects).toBe(3);
    expect(stats().ends).toBe(1);
    expect(pool.idleCount).toBe(2);

    // After idleMs, quiet actors drop back to zero connections.
    await new Promise((r) => setTimeout(r, 70));
    expect(pool.idleCount).toBe(0);
    expect(stats().ends).toBe(3);
  });

  it("recovers transparently when a parked idle connection drops before an idempotent read", async () => {
    let clientSeq = 0;
    let connects = 0;
    const env: PgEnv = {
      HYPERDRIVE: { connectionString: "postgresql://unit-test/db" } as Hyperdrive,
      pgClientFactory: () => {
        const id = ++clientSeq;
        let call = 0;
        const client: PgClient = {
          async connect() {
            connects++;
          },
          async query<R = Record<string, unknown>>(): Promise<PgQueryResult<R>> {
            call++;
            if (id === 1 && call === 2) throw new Error("Connection terminated unexpectedly");
            return { rows: [{ clientId: id } as unknown as R], rowCount: 1 };
          },
          async end() {}
        };
        return client;
      }
    };
    const pool = new PgPool(env, { maxIdle: 2, idleMs: 5_000 });
    const first = await pool.withClient((pg) => pg.query("SELECT 1"), { retryIdleDisconnect: true });
    expect(first.rows[0]?.clientId).toBe(1);

    const second = await pool.withClient((pg) => pg.query("SELECT 1"), { retryIdleDisconnect: true });
    expect(second.rows[0]?.clientId).toBe(2);
    expect(connects).toBe(2);
    await pool.close();
  });
});

describe("1-RT SQL statement shape", () => {
  it("runs createRoom, loadAccess, loadRoom, loadHydration, applyLedger, removePerson and redactPerson in 1 SQL round-trip each", async () => {
    const room = sampleRoom();
    const owner = sampleOwner();
    const { env, stats } = countingEnv((sql) => {
      if (sql.includes("AS room_found")) {
        return { rows: [{ room_found: 1, diverged: 0 }], rowCount: 1 };
      }
      if (sql.includes("FROM app.agent_rooms r")) {
        return {
          rows: [
            {
              id: room.id,
              org_id: room.orgId,
              created_by: room.createdBy,
              name: room.name,
              kind: room.kind,
              parent_chat: null,
              idle_ttl_s: 3600,
              project_ref: "proj-1",
              last_seq: 1,
              created_at: room.createdAt,
              last_activity_at: room.lastActivityAt,
              archived_at: null,
              members_json: [],
              access_json: [],
              recent_json: [],
              claims_json: []
            }
          ],
          rowCount: 1
        };
      }
      return { rows: [], rowCount: 1 };
    });

    const store = new PgRoomStore(env, { maxIdle: 2, idleMs: 5_000 });
    const mark = () => stats().queries.length;

    let before = mark();
    await store.createRoom(room, owner);
    expect(mark() - before).toBe(1);

    before = mark();
    const access = await store.loadAccess(room.id);
    expect(mark() - before).toBe(1);
    expect(access?.room.id).toBe(room.id);

    before = mark();
    const loaded = await store.loadRoom(room.id);
    expect(mark() - before).toBe(1);
    expect(loaded?.room.id).toBe(room.id);

    before = mark();
    const hydrated = await store.loadHydration(room.id);
    expect(mark() - before).toBe(1);
    expect(hydrated?.loaded.room.id).toBe(room.id);

    const batch: LedgerBatch = {
      lastSeq: 2,
      lastActivityAt: room.lastActivityAt + 2,
      messages: [sampleMsg(1), sampleMsg(2)],
      members: [owner],
      removed: [],
      claims: [{ claimKey: "task-1", member: "lead", userId: "42", claimedSeq: 1, state: "held", updatedAt: 1_790_000_002 }]
    };
    before = mark();
    expect(await store.applyLedger(room.id, batch)).toBe("ok");
    expect(mark() - before).toBe(1);

    before = mark();
    await store.removePerson(room.id, "99");
    expect(mark() - before).toBe(1);

    before = mark();
    await store.redactPerson(room.id, "99", "[removed]", 1_790_000_010);
    expect(mark() - before).toBe(1);

    // Every call reused the single warm pooled connection (1 connect for 7 operations).
    expect(stats().connects).toBe(1);
    await store.close();
  });

  it("inserts 10 crash reports in 1 round-trip instead of 10 and skips connecting on empty input", async () => {
    const { env, stats } = countingEnv(() => ({ rows: [], rowCount: 10 }));
    expect(await storeCrashReports(env, "42", [])).toBe(0);
    expect(stats().connects).toBe(0);

    const rows: CrashRow[] = Array.from({ length: 10 }, (_, i) => ({
      digest: String(i).padStart(64, "a"),
      kind: "crash",
      headline: `Crash #${i}`,
      signature: "0123456789abcdef",
      appVersion: "0.2.194",
      appBuild: "194",
      osVersion: "iOS 27.0",
      deviceType: "iPhone18,1",
      crashCount: 1,
      hangCount: 0,
      payload: "{}"
    }));
    expect(await storeCrashReports(env, "42", rows)).toBe(10);
    expect(stats().connects).toBe(1);
    expect(stats().queries).toHaveLength(1);
  });

  it("shares one DB connection in userRoomIds across listRooms + invites", async () => {
    const { env, stats } = countingEnv(() => ({ rows: [], rowCount: 0 }));
    const store = new PgRoomStore(env);
    expect(await userRoomIds(store, "42")).toEqual([]);
    expect(stats().connects).toBe(1);
    expect(stats().ends).toBe(1);
    expect(stats().queries).toHaveLength(2);
  });

  it("derives the HKDF refresh encryption key once per signing secret instead of per call", async () => {
    const spy = vi.spyOn(crypto.subtle, "deriveBits");
    try {
      const secretEnv = { HARNESS_AUTH_SIGNING_KEY: "m".repeat(48) } as Env;
      for (let i = 0; i < 12; i++) {
        const cred = await issueRefreshCredential(secretEnv, "42", `cg_rt_tok_${i}`);
        const verified = await verifyRefreshCredential(secretEnv, cred);
        expect(verified?.codegraffRefreshToken).toBe(`cg_rt_tok_${i}`);
      }
      expect(spy).toHaveBeenCalledTimes(1);
    } finally {
      spy.mockRestore();
    }
  });
});

const PG_URL = process.env.TEST_PG_URL;

describe.skipIf(!PG_URL)("PostgreSQL integration & round-trip speedup", () => {
  it("preserves exact room, ledger divergence, person removal and crash-dedup semantics while cutting round-trip latency >5x", async () => {
    const env: PgEnv = { HYPERDRIVE: { connectionString: PG_URL! } as Hyperdrive };
    const store = new PgRoomStore(env, { maxIdle: 2, idleMs: 5_000 });
    const roomId = `room_${Date.now().toString(16).padStart(24, "0").slice(-24)}`;
    const room = sampleRoom(roomId);
    const owner = sampleOwner();

    try {
      await store.createRoom(room, owner);

      const access = await store.loadAccess(roomId);
      expect(access?.room.name).toBe("perf-test-room");
      expect(access?.access).toHaveLength(1);
      expect(access?.access[0]?.role).toBe("owner");

      const batch1: LedgerBatch = {
        lastSeq: 2,
        lastActivityAt: room.lastActivityAt + 2,
        messages: [sampleMsg(1, "hello"), sampleMsg(2, "world")],
        members: [
          { ...owner, readSeq: 2 },
          { member: "helper", memberKind: "graff", memberRef: null, deviceId: "dev-2", userId: "42", role: "member", readSeq: 1, joinedAt: room.createdAt + 1 }
        ],
        removed: [],
        claims: [{ claimKey: "job-1", member: "lead", userId: "42", claimedSeq: 1, state: "held", updatedAt: room.createdAt + 2 }]
      };
      expect(await store.applyLedger(roomId, batch1)).toBe("ok");
      // Idempotent replay of the exact same batch succeeds cleanly.
      expect(await store.applyLedger(roomId, batch1)).toBe("ok");

      // Divergent message at seq=2 rolls back cleanly without advancing last_seq to 99.
      expect(
        await store.applyLedger(roomId, {
          lastSeq: 99,
          lastActivityAt: room.lastActivityAt + 99,
          messages: [sampleMsg(2, "TAMPERED")],
          members: [],
          removed: [],
          claims: []
        })
      ).toBe("diverged");

      const hydrated = await store.loadHydration(roomId);
      expect(hydrated?.loaded.room.lastSeq).toBe(2);
      expect(hydrated?.loaded.members.map((m) => m.member)).toEqual(["lead", "helper"]);
      expect(hydrated?.loaded.recent.map((m) => m.body)).toEqual(["hello", "world"]);
      expect(hydrated?.claims).toHaveLength(1);
      expect(hydrated?.claims[0]?.claimKey).toBe("job-1");

      // Overlapping member + removed in one batch resolves in favor of removal without CTE row conflict.
      expect(
        await store.applyLedger(roomId, {
          lastSeq: 2,
          lastActivityAt: room.lastActivityAt + 3,
          messages: [],
          members: [{ member: "helper", memberKind: "graff", memberRef: null, deviceId: "dev-2", userId: "42", role: "member", readSeq: 2, joinedAt: room.createdAt + 1 }],
          removed: [{ member: "helper", deviceId: "dev-2" }],
          claims: []
        })
      ).toBe("ok");
      expect((await store.loadRoom(roomId))?.members.map((m) => m.member)).toEqual(["lead"]);

      // Crash report batch insert + deduplication.
      const crashes: CrashRow[] = [0, 1, 2].map((i) => ({
        digest: `${i}`.repeat(64).slice(0, 64),
        kind: "crash",
        headline: `Crash ${i}`,
        signature: "abcdef0123456789",
        appVersion: "0.2.194",
        appBuild: "194",
        osVersion: "iOS 27.0",
        deviceType: "iPhone18,1",
        crashCount: 1,
        hangCount: 0,
        payload: `{"i":${i}}`
      }));
      expect(await storeCrashReports(env, "42", crashes)).toBe(3);
      expect(await storeCrashReports(env, "42", crashes)).toBe(0);

      // Shape / latency ratio check under realistic 5ms/RT network delay:
      // Old path (unpooled connect + 8-RT applyLedger + 4-RT loadRoom) vs new path (pooled + 1-RT CTEs).
      const rttMs = 5;
      const delayEnv = (base: PgEnv): PgEnv => ({
        HYPERDRIVE: base.HYPERDRIVE,
        pgClientFactory: (cs) => {
          const raw = new Client({ connectionString: cs });
          return {
            async connect() {
              await new Promise((r) => setTimeout(r, rttMs));
              await raw.connect();
            },
            async query<R = Record<string, unknown>>(sql: string, values?: unknown[]) {
              await new Promise((r) => setTimeout(r, rttMs));
              return (await raw.query(sql, values)) as unknown as PgQueryResult<R>;
            },
            async end() {
              await raw.end();
            }
          };
        }
      });

      const fastStore = new PgRoomStore(delayEnv(env), { maxIdle: 2, idleMs: 5_000 });
      await fastStore.loadAccess(roomId); // warm pool
      const tFast0 = performance.now();
      for (let i = 0; i < 5; i++) {
        await fastStore.applyLedger(roomId, batch1);
        await fastStore.loadRoom(roomId);
      }
      const fastMs = performance.now() - tFast0;
      await fastStore.close();

      // Slow baseline: fresh client connect + BEGIN + FOR UPDATE + INSERT + UPDATE + MEMBERS + CLAIMS + COMMIT (8 RTs) + fresh client 4-RT loadRoom.
      const slowEnv = delayEnv(env);
      const tSlow0 = performance.now();
      for (let i = 0; i < 5; i++) {
        const c1 = slowEnv.pgClientFactory!(PG_URL!);
        await c1.connect();
        await c1.query("BEGIN");
        await c1.query("SELECT 1 FROM app.agent_rooms WHERE id = $1 FOR UPDATE", [roomId]);
        await c1.query("SELECT seq FROM app.agent_room_messages WHERE room_id = $1 LIMIT 1", [roomId]);
        await c1.query("UPDATE app.agent_rooms SET last_seq = GREATEST(last_seq, $2) WHERE id = $1", [roomId, 2]);
        await c1.query("SELECT 1 FROM app.agent_room_members WHERE room_id = $1 LIMIT 1", [roomId]);
        await c1.query("SELECT 1 FROM app.agent_room_claims WHERE room_id = $1 LIMIT 1", [roomId]);
        await c1.query("COMMIT");
        await c1.end();

        const c2 = slowEnv.pgClientFactory!(PG_URL!);
        await c2.connect();
        await c2.query("SELECT * FROM app.agent_rooms WHERE id = $1", [roomId]);
        await c2.query("SELECT * FROM app.agent_room_members WHERE room_id = $1", [roomId]);
        await c2.query("SELECT * FROM app.agent_room_access WHERE room_id = $1", [roomId]);
        await c2.query("SELECT * FROM app.agent_room_messages WHERE room_id = $1 LIMIT 50", [roomId]);
        await c2.end();
      }
      const slowMs = performance.now() - tSlow0;
      expect(slowMs / fastMs).toBeGreaterThan(5);

      await store.redactPerson(roomId, "42", "[deleted]", room.createdAt + 50);
      await store.removePerson(roomId, "42");
      await store.destroy(roomId);
      expect(await store.applyLedger(roomId, batch1)).toBe("gone");
    } finally {
      await store.destroy(roomId).catch(() => {});
      await withPgDeleteCrashes(env, "42");
      await store.close();
    }
  });
});

async function withPgDeleteCrashes(env: PgEnv, userId: string): Promise<void> {
  const c = new Client({ connectionString: env.HYPERDRIVE!.connectionString });
  await c.connect();
  try {
    await c.query("DELETE FROM app.harness_crash_reports WHERE user_id = $1", [userId]);
  } finally {
    await c.end();
  }
}
