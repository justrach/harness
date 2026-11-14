/**
 * RoomStore over PostgreSQL: rooms, members, messages, grants, claims and the
 * wake rules (migrations 0020_agent_rooms and 0022_agent_rooms_people).
 * Times are unix seconds; bigints come back from `pg` as strings and are
 * narrowed here (seqs, ids and seconds stay far below 2^53).
 */
import {
  PgPool,
  isSqlError,
  withPg,
  type PgClient,
  type PgEnv,
  type PgPoolOptions
} from "./pg";
import {
  ROOM_LIMITS,
  type AccessRow,
  type ClaimRow,
  type LedgerBatch,
  type ExternalWakes,
  type InboxItem,
  type Invite,
  type LoadedRoom,
  type MemberKey,
  type MemberRow,
  type MessageRow,
  type PendingWake,
  type RoomRow,
  type RoomStore,
  type RoomSummary,
  type WakeBatch,
  type WakeRequest,
  type WakeVerdict
} from "./room-core";

type Row = Record<string, unknown>;

const num = (v: unknown): number => Number(v);
const numOrNull = (v: unknown): number | null => (v === null || v === undefined ? null : Number(v));
const strOrNull = (v: unknown): string | null => (v === null || v === undefined ? null : (v as string));

const roomFrom = (r: Row): RoomRow => ({
  id: r.id as string,
  orgId: r.org_id as string,
  createdBy: r.created_by as string,
  name: r.name as string,
  kind: r.kind as RoomRow["kind"],
  parentChat: strOrNull(r.parent_chat),
  idleTtlS: numOrNull(r.idle_ttl_s),
  projectRef: strOrNull(r.project_ref),
  lastSeq: num(r.last_seq),
  createdAt: num(r.created_at),
  lastActivityAt: num(r.last_activity_at),
  archivedAt: numOrNull(r.archived_at)
});

const memberFrom = (r: Row): MemberRow => ({
  member: r.member as string,
  memberKind: r.member_kind as MemberRow["memberKind"],
  memberRef: strOrNull(r.member_ref),
  deviceId: r.device_id as string,
  userId: r.user_id as string,
  role: r.role as MemberRow["role"],
  readSeq: num(r.read_seq),
  joinedAt: num(r.joined_at)
});

const accessFrom = (r: Row): AccessRow => ({
  userId: r.user_id as string,
  role: r.role as AccessRow["role"],
  invitedBy: r.invited_by as string,
  invitedAt: num(r.invited_at),
  acceptedAt: numOrNull(r.accepted_at),
  externalWakes: r.external_wakes as ExternalWakes
});

const messageFrom = (r: Row): MessageRow => ({
  seq: num(r.seq),
  sender: r.sender as string,
  senderDevice: r.sender_device as string,
  senderUserId: r.sender_user_id as string,
  fromUser: r.from_user as boolean,
  kind: r.kind as MessageRow["kind"],
  toMember: strOrNull(r.to_member),
  body: r.body as string,
  replyTo: numOrNull(r.reply_to),
  mentions: (r.mentions as string[] | null) ?? [],
  hop: num(r.hop),
  clientId: strOrNull(r.client_id),
  claimKey: strOrNull(r.claim_key),
  createdAt: num(r.created_at)
});

const messageTo = (m: MessageRow) => ({
  seq: m.seq,
  sender: m.sender,
  sender_device: m.senderDevice,
  sender_user_id: m.senderUserId,
  from_user: m.fromUser,
  kind: m.kind,
  to_member: m.toMember,
  body: m.body,
  reply_to: m.replyTo,
  mentions: m.mentions,
  hop: m.hop,
  client_id: m.clientId,
  claim_key: m.claimKey,
  created_at: m.createdAt
});

const memberTo = (m: MemberRow) => ({
  member: m.member,
  member_kind: m.memberKind,
  member_ref: m.memberRef,
  device_id: m.deviceId,
  user_id: m.userId,
  role: m.role,
  read_seq: m.readSeq,
  joined_at: m.joinedAt
});

const MESSAGE_COLUMNS = [
  "seq",
  "sender",
  "sender_device",
  "sender_user_id",
  "from_user",
  "kind",
  "to_member",
  "body",
  "reply_to",
  "mentions",
  "hop",
  "client_id",
  "claim_key",
  "created_at"
];
const MESSAGE_SELECT = MESSAGE_COLUMNS.join(", ");
const qualified = (alias: string): string => MESSAGE_COLUMNS.map((c) => `${alias}.${c}`).join(", ");

const claimFrom = (r: Row): ClaimRow => ({
  claimKey: r.claim_key as string,
  member: r.member as string,
  userId: r.user_id as string,
  claimedSeq: num(r.claimed_seq),
  state: r.state as ClaimRow["state"],
  updatedAt: num(r.updated_at)
});

const jsonRows = (v: unknown): Row[] => {
  if (Array.isArray(v)) return v as Row[];
  if (typeof v === "string" && v.length > 0) return JSON.parse(v) as Row[];
  return [];
};

export class PgRoomStore implements RoomStore {
  /** Held across the store calls of one busy stretch (see {@link session}). */
  private client: Promise<PgClient> | null = null;
  private held = 0;
  private readonly pool: PgPool;

  /**
   * Default pool options (`maxIdle: 0`) close connections immediately when a
   * stateless Worker request finishes (Workers cannot share sockets across
   * incoming requests). Durable Objects pass `{ maxIdle: 2, idleMs: 5_000 }`
   * so wakes, posts and 1s ledger flushes reuse warm connections while idle
   * actors still drop to zero connections.
   */
  constructor(
    env: PgEnv,
    poolOptions: PgPoolOptions = { maxIdle: 0, idleMs: 0 }
  ) {
    this.pool = new PgPool(env, poolOptions);
  }

  /** Drain any parked idle connections immediately. */
  close(): Promise<void> {
    return this.pool.close();
  }

  /**
   * Run `fn` with one connection for every store call inside it, instead of
   * a fresh Hyperdrive connect per call (a post is several calls: append,
   * wake checks, claims). Overlapping sessions share the connection; when the
   * last one ends, the connection returns to {@link pool} (closed immediately
   * in stateless routes, or kept warm briefly inside a RoomActor).
   */
  async session<T>(fn: () => Promise<T>): Promise<T> {
    this.held++;
    try {
      return await fn();
    } finally {
      if (--this.held === 0) await this.releaseSession(false);
    }
  }

  private async releaseSession(broken: boolean): Promise<void> {
    const pending = this.client;
    this.client = null;
    if (!pending) return;
    try {
      const c = await pending;
      if (broken) this.pool.discard(c);
      else this.pool.release(c);
    } catch {
      // Connection failed before it opened; nothing to release.
    }
  }

  private async run<T>(
    fn: (client: PgClient) => Promise<T>,
    options: { retryIdleDisconnect?: boolean } = {}
  ): Promise<T> {
    if (this.held === 0) return this.pool.withClient(fn, options);
    const fresh = this.client === null;
    let reused = false;
    if (fresh) {
      this.client = this.pool.acquire().then((a) => {
        reused = a.reused;
        return a.client;
      });
    }
    let client: PgClient;
    try {
      client = await this.client!;
    } catch (err) {
      this.client = null;
      throw err;
    }
    try {
      return await fn(client);
    } catch (err) {
      // A dropped connection is discarded and replaced on the next call; a SQL
      // error leaves the connection synchronized and usable.
      if (!isSqlError(err)) {
        await this.releaseSession(true);
        if (fresh && reused && options.retryIdleDisconnect) {
          return this.run(fn, { retryIdleDisconnect: false });
        }
      }
      throw err;
    }
  }

  /** Single-round-trip atomic room + owner grant + owner member insert. */
  createRoom(room: RoomRow, owner: MemberRow): Promise<void> {
    return this.run(async (pg) => {
      await pg.query(
        `WITH ins_room AS (
           INSERT INTO app.agent_rooms (id, org_id, created_by, name, kind, parent_chat, idle_ttl_s,
             project_ref, last_seq, created_at, last_activity_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 0, $9, $9)
           RETURNING id
         ),
         ins_access AS (
           INSERT INTO app.agent_room_access (room_id, user_id, role, invited_by, invited_at, accepted_at)
           SELECT id, $3, 'owner', $3, $9, $9 FROM ins_room
         )
         INSERT INTO app.agent_room_members (room_id, member, member_kind, member_ref, device_id, user_id, role, read_seq, joined_at)
         SELECT id, $10, $11, $12, $13, $14, $15, $16, $17 FROM ins_room
         ON CONFLICT (room_id, member, device_id)
         DO UPDATE SET member_kind = excluded.member_kind, member_ref = excluded.member_ref
         WHERE app.agent_room_members.user_id = excluded.user_id`,
        [
          room.id,
          room.orgId,
          room.createdBy,
          room.name,
          room.kind,
          room.parentChat,
          room.idleTtlS,
          room.projectRef,
          room.createdAt,
          owner.member,
          owner.memberKind,
          owner.memberRef,
          owner.deviceId,
          owner.userId,
          owner.role,
          owner.readSeq,
          owner.joinedAt
        ]
      );
    });
  }

  private async insertMember(pg: PgClient, roomId: string, m: MemberRow): Promise<void> {
    await pg.query(
      `INSERT INTO app.agent_room_members (room_id, member, member_kind, member_ref, device_id, user_id, role, read_seq, joined_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
       ON CONFLICT (room_id, member, device_id)
       DO UPDATE SET member_kind = excluded.member_kind, member_ref = excluded.member_ref
       WHERE app.agent_room_members.user_id = excluded.user_id`,
      [roomId, m.member, m.memberKind, m.memberRef, m.deviceId, m.userId, m.role, m.readSeq, m.joinedAt]
    );
  }

  /** Single-round-trip room + members + grants + recent messages load. */
  loadRoom(id: string): Promise<LoadedRoom | null> {
    return this.run(
      async (pg) => {
        const res = await pg.query(
          `SELECT r.*,
                  COALESCE(
                    (SELECT json_agg(m ORDER BY m.joined_at, m.member)
                       FROM app.agent_room_members m
                      WHERE m.room_id = r.id),
                    '[]'::json
                  ) AS members_json,
                  COALESCE(
                    (SELECT json_agg(a ORDER BY a.invited_at)
                       FROM app.agent_room_access a
                      WHERE a.room_id = r.id),
                    '[]'::json
                  ) AS access_json,
                  COALESCE(
                    (SELECT json_agg(t ORDER BY t.seq ASC)
                       FROM (
                         SELECT ${MESSAGE_SELECT}
                           FROM app.agent_room_messages
                          WHERE room_id = r.id
                          ORDER BY seq DESC
                          LIMIT $2
                       ) t),
                    '[]'::json
                  ) AS recent_json
             FROM app.agent_rooms r
            WHERE r.id = $1`,
          [id, ROOM_LIMITS.ring]
        );
        if (res.rows.length === 0) return null;
        const row = res.rows[0];
        return {
          room: roomFrom(row),
          members: jsonRows(row.members_json).map(memberFrom),
          access: jsonRows(row.access_json).map(accessFrom),
          recent: jsonRows(row.recent_json).map(messageFrom)
        };
      },
      { retryIdleDisconnect: true }
    );
  }

  /** Single-round-trip full hydration (room + members + grants + recent + claims). */
  loadHydration(id: string): Promise<{ loaded: LoadedRoom; claims: ClaimRow[] } | null> {
    return this.run(
      async (pg) => {
        const res = await pg.query(
          `SELECT r.*,
                  COALESCE(
                    (SELECT json_agg(m ORDER BY m.joined_at, m.member)
                       FROM app.agent_room_members m
                      WHERE m.room_id = r.id),
                    '[]'::json
                  ) AS members_json,
                  COALESCE(
                    (SELECT json_agg(a ORDER BY a.invited_at)
                       FROM app.agent_room_access a
                      WHERE a.room_id = r.id),
                    '[]'::json
                  ) AS access_json,
                  COALESCE(
                    (SELECT json_agg(t ORDER BY t.seq ASC)
                       FROM (
                         SELECT ${MESSAGE_SELECT}
                           FROM app.agent_room_messages
                          WHERE room_id = r.id
                          ORDER BY seq DESC
                          LIMIT $2
                       ) t),
                    '[]'::json
                  ) AS recent_json,
                  COALESCE(
                    (SELECT json_agg(c)
                       FROM (
                         SELECT claim_key, member, user_id, claimed_seq, state, updated_at
                           FROM app.agent_room_claims
                          WHERE room_id = r.id
                       ) c),
                    '[]'::json
                  ) AS claims_json
             FROM app.agent_rooms r
            WHERE r.id = $1`,
          [id, ROOM_LIMITS.ring]
        );
        if (res.rows.length === 0) return null;
        const row = res.rows[0];
        return {
          loaded: {
            room: roomFrom(row),
            members: jsonRows(row.members_json).map(memberFrom),
            access: jsonRows(row.access_json).map(accessFrom),
            recent: jsonRows(row.recent_json).map(messageFrom)
          },
          claims: jsonRows(row.claims_json).map(claimFrom)
        };
      },
      { retryIdleDisconnect: true }
    );
  }

  /** Single-round-trip room row + grants load for ledger-backed actors on wake. */
  loadAccess(id: string): Promise<{ room: RoomRow; access: AccessRow[] } | null> {
    return this.run(
      async (pg) => {
        const res = await pg.query(
          `SELECT r.*,
                  COALESCE(
                    (SELECT json_agg(a ORDER BY a.invited_at)
                       FROM app.agent_room_access a
                      WHERE a.room_id = r.id),
                    '[]'::json
                  ) AS access_json
             FROM app.agent_rooms r
            WHERE r.id = $1`,
          [id]
        );
        if (res.rows.length === 0) return null;
        const row = res.rows[0];
        return {
          room: roomFrom(row),
          access: jsonRows(row.access_json).map(accessFrom)
        };
      },
      { retryIdleDisconnect: true }
    );
  }

  /** Every claim in a room (a ledger hydrating a room that predates it). */
  loadClaims(roomId: string): Promise<ClaimRow[]> {
    return this.run(
      async (pg) => {
        const res = await pg.query(
          "SELECT claim_key, member, user_id, claimed_seq, state, updated_at FROM app.agent_room_claims WHERE room_id = $1",
          [roomId]
        );
        return res.rows.map(claimFrom);
      },
      { retryIdleDisconnect: true }
    );
  }

  /**
   * Write a slice of an actor's ledger behind in a single atomic CTE statement
   * on its own pooled connection (never the request session). Idempotent:
   * messages insert-or-skip by seq unless diverged (in which case no write CTE
   * runs), read cursors only move forward, counters take the greater value.
   * "gone" means the room row no longer exists (destroyed or swept).
   */
  applyLedger(roomId: string, batch: LedgerBatch): Promise<"ok" | "gone" | "diverged"> {
    const msgsJson = JSON.stringify(batch.messages.map(messageTo));
    const membersJson = JSON.stringify(batch.members.map(memberTo));
    const removedJson = JSON.stringify(
      batch.removed.map((k) => ({ member: k.member, device_id: k.deviceId }))
    );
    const claimsJson = JSON.stringify(
      batch.claims.map((c) => ({
        claim_key: c.claimKey,
        member: c.member,
        user_id: c.userId,
        claimed_seq: c.claimedSeq,
        state: c.state,
        updated_at: c.updatedAt
      }))
    );
    return this.pool.withClient(
      async (pg) => {
        const res = await pg.query(
          `WITH locked AS (
             SELECT id FROM app.agent_rooms WHERE id = $1 FOR UPDATE
           ),
           incoming_msgs AS (
             SELECT *
               FROM jsonb_to_recordset($2::jsonb) AS x(
                 seq bigint, sender text, sender_device text, sender_user_id text,
                 from_user boolean, kind text, to_member text, body text, reply_to bigint,
                 mentions text[], hop smallint, client_id text, claim_key text, created_at bigint
               )
              WHERE EXISTS (SELECT 1 FROM locked)
           ),
           divergence AS (
             SELECT 1
               FROM incoming_msgs m
               JOIN app.agent_room_messages e ON e.room_id = $1 AND e.seq = m.seq
              WHERE e.sender_user_id IS DISTINCT FROM m.sender_user_id
                 OR e.created_at IS DISTINCT FROM m.created_at
                 OR e.body IS DISTINCT FROM m.body
              LIMIT 1
           ),
           guard AS (
             SELECT id FROM locked WHERE NOT EXISTS (SELECT 1 FROM divergence)
           ),
           ins_msgs AS (
             INSERT INTO app.agent_room_messages (room_id, ${MESSAGE_SELECT})
             SELECT $1, ${MESSAGE_SELECT}
               FROM incoming_msgs
              WHERE EXISTS (SELECT 1 FROM guard)
             ON CONFLICT (room_id, seq) DO NOTHING
           ),
           upd_room AS (
             UPDATE app.agent_rooms
                SET last_seq = GREATEST(last_seq, $3),
                    last_activity_at = GREATEST(last_activity_at, $4)
              WHERE id = $1 AND EXISTS (SELECT 1 FROM guard)
           ),
           removed_keys AS (
             SELECT member, device_id
               FROM jsonb_to_recordset($6::jsonb) AS x(member text, device_id text)
           ),
           ins_members AS (
             INSERT INTO app.agent_room_members (room_id, member, member_kind, member_ref, device_id, user_id, role, read_seq, joined_at)
             SELECT $1, x.member, x.member_kind, x.member_ref, x.device_id, x.user_id, x.role, x.read_seq, x.joined_at
               FROM jsonb_to_recordset($5::jsonb) AS x(
                 member text, member_kind text, member_ref text, device_id text,
                 user_id text, role text, read_seq bigint, joined_at bigint
               )
              WHERE EXISTS (SELECT 1 FROM guard)
                AND NOT EXISTS (
                  SELECT 1 FROM removed_keys r WHERE r.member = x.member AND r.device_id = x.device_id
                )
             ON CONFLICT (room_id, member, device_id) DO UPDATE
               SET member_kind = excluded.member_kind, member_ref = excluded.member_ref,
                   read_seq = GREATEST(app.agent_room_members.read_seq, excluded.read_seq)
             WHERE app.agent_room_members.user_id = excluded.user_id
           ),
           del_members AS (
             DELETE FROM app.agent_room_members m
              USING removed_keys r
              WHERE m.room_id = $1 AND m.member = r.member AND m.device_id = r.device_id
                AND EXISTS (SELECT 1 FROM guard)
           ),
           ins_claims AS (
             INSERT INTO app.agent_room_claims (room_id, claim_key, member, user_id, claimed_seq, state, updated_at)
             SELECT $1, claim_key, member, user_id, claimed_seq, state, updated_at
               FROM jsonb_to_recordset($7::jsonb) AS x(
                 claim_key text, member text, user_id text,
                 claimed_seq bigint, state text, updated_at bigint
               )
              WHERE EXISTS (SELECT 1 FROM guard)
             ON CONFLICT (room_id, claim_key) DO UPDATE
               SET member = excluded.member, user_id = excluded.user_id, claimed_seq = excluded.claimed_seq,
                   state = excluded.state, updated_at = excluded.updated_at
             WHERE app.agent_room_claims.updated_at <= excluded.updated_at
           )
           SELECT (SELECT count(*)::int FROM locked) AS room_found,
                  (SELECT count(*)::int FROM divergence) AS diverged`,
          [roomId, msgsJson, batch.lastSeq, batch.lastActivityAt, membersJson, removedJson, claimsJson]
        );
        const row = res.rows[0];
        if (!row || num(row.room_found) === 0) return "gone";
        if (num(row.diverged) > 0) return "diverged";
        return "ok";
      },
      { retryIdleDisconnect: true }
    );
  }

  /** One statement, so the row and the room's counters commit together.
   * Zero rows: stale seq, archived, or gone. */
  append(roomId: string, m: MessageRow): Promise<boolean> {
    return this.run(async (pg) => {
      const res = await pg.query(
        `WITH r AS (
           UPDATE app.agent_rooms SET last_seq = $2, last_activity_at = $15
            WHERE id = $1 AND last_seq = $2 - 1 AND archived_at IS NULL
           RETURNING id)
         INSERT INTO app.agent_room_messages (room_id, seq, sender, sender_device, sender_user_id,
           from_user, kind, to_member, body, reply_to, mentions, hop, client_id, claim_key, created_at)
         SELECT r.id, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15 FROM r
         RETURNING seq`,
        [
          roomId,
          m.seq,
          m.sender,
          m.senderDevice,
          m.senderUserId,
          m.fromUser,
          m.kind,
          m.toMember,
          m.body,
          m.replyTo,
          m.mentions,
          m.hop,
          m.clientId,
          m.claimKey,
          m.createdAt
        ]
      );
      return res.rows.length === 1;
    });
  }

  findByClientId(roomId: string, senderUserId: string, clientId: string): Promise<MessageRow | null> {
    return this.run(async (pg) => {
      const res = await pg.query(
        `SELECT ${MESSAGE_SELECT} FROM app.agent_room_messages
          WHERE room_id = $1 AND sender_user_id = $2 AND client_id = $3`,
        [roomId, senderUserId, clientId]
      );
      return res.rows.length ? messageFrom(res.rows[0]) : null;
    });
  }

  upsertMember(roomId: string, member: MemberRow): Promise<void> {
    return this.run((pg) => this.insertMember(pg, roomId, member));
  }

  removeMember(roomId: string, key: MemberKey): Promise<void> {
    return this.run(async (pg) => {
      await pg.query("DELETE FROM app.agent_room_members WHERE room_id = $1 AND member = $2 AND device_id = $3", [
        roomId,
        key.member,
        key.deviceId
      ]);
    });
  }

  setReadSeq(roomId: string, key: MemberKey, seq: number): Promise<void> {
    return this.run(async (pg) => {
      await pg.query(
        `UPDATE app.agent_room_members SET read_seq = GREATEST(read_seq, $4)
          WHERE room_id = $1 AND member = $2 AND device_id = $3`,
        [roomId, key.member, key.deviceId, seq]
      );
    });
  }

  messages(roomId: string, since: number, limit: number): Promise<MessageRow[]> {
    return this.run(async (pg) => {
      const res = await pg.query(
        `SELECT ${MESSAGE_SELECT} FROM app.agent_room_messages
          WHERE room_id = $1 AND seq > $2 ORDER BY seq LIMIT $3`,
        [roomId, since, limit]
      );
      return res.rows.map(messageFrom);
    });
  }

  setArchived(roomId: string, at: number | null): Promise<void> {
    return this.run(async (pg) => {
      await pg.query("UPDATE app.agent_rooms SET archived_at = $2 WHERE id = $1", [roomId, at]);
    });
  }

  destroy(roomId: string): Promise<void> {
    return this.run(async (pg) => {
      // Members, messages, grants, claims and wake rows cascade.
      await pg.query("DELETE FROM app.agent_rooms WHERE id = $1", [roomId]);
    });
  }

  userIdByEmail(email: string): Promise<string | null> {
    return this.run(async (pg) => {
      const res = await pg.query("SELECT id::text AS user_id FROM app.users WHERE email = lower(trim($1)) LIMIT 1", [email]);
      return res.rows.length ? (res.rows[0].user_id as string) : null;
    });
  }

  invite(roomId: string, userId: string, invitedBy: string, now: number): Promise<void> {
    return this.run(async (pg) => {
      await pg.query(
        `INSERT INTO app.agent_room_access (room_id, user_id, role, invited_by, invited_at)
         VALUES ($1, $2, 'member', $3, $4) ON CONFLICT (room_id, user_id) DO NOTHING`,
        [roomId, userId, invitedBy, now]
      );
    });
  }

  respondInvite(roomId: string, userId: string, accept: boolean, now: number): Promise<boolean> {
    return this.run(async (pg) => {
      const res = accept
        ? await pg.query(
            `UPDATE app.agent_room_access SET accepted_at = $3
              WHERE room_id = $1 AND user_id = $2 AND accepted_at IS NULL RETURNING user_id`,
            [roomId, userId, now]
          )
        : await pg.query(
            `DELETE FROM app.agent_room_access
              WHERE room_id = $1 AND user_id = $2 AND accepted_at IS NULL RETURNING user_id`,
            [roomId, userId]
          );
      return res.rows.length === 1;
    });
  }

  removePerson(roomId: string, userId: string): Promise<void> {
    return this.run(async (pg) => {
      await pg.query(
        `WITH del_members AS (
           DELETE FROM app.agent_room_members WHERE room_id = $1 AND user_id = $2
         )
         DELETE FROM app.agent_room_access WHERE room_id = $1 AND user_id = $2`,
        [roomId, userId]
      );
    });
  }

  redactPerson(roomId: string, userId: string, body: string, now: number): Promise<void> {
    return this.run(async (pg) => {
      await pg.query(
        `WITH upd_msgs AS (
           UPDATE app.agent_room_messages SET body = $3, mentions = '{}'
            WHERE room_id = $1 AND sender_user_id = $2
         )
         UPDATE app.agent_room_claims SET state = 'released', updated_at = $4
          WHERE room_id = $1 AND user_id = $2 AND state = 'held'`,
        [roomId, userId, body, now]
      );
    });
  }

  setExternalWakes(roomId: string, userId: string, value: ExternalWakes): Promise<void> {
    return this.run(async (pg) => {
      await pg.query("UPDATE app.agent_room_access SET external_wakes = $3 WHERE room_id = $1 AND user_id = $2", [
        roomId,
        userId,
        value
      ]);
    });
  }

  invites(userId: string): Promise<Invite[]> {
    return this.run(async (pg) => {
      const res = await pg.query(
        `SELECT a.room_id, r.name, a.invited_by, a.invited_at
           FROM app.agent_room_access a JOIN app.agent_rooms r ON r.id = a.room_id
          WHERE a.user_id = $1 AND a.accepted_at IS NULL
          ORDER BY a.invited_at DESC LIMIT 100`,
        [userId]
      );
      return res.rows.map((r: Row) => ({
        roomId: r.room_id as string,
        roomName: r.name as string,
        invitedBy: r.invited_by as string,
        invitedAt: num(r.invited_at)
      }));
    });
  }

  takeClaim(roomId: string, claimKey: string, member: string, userId: string, seq: number, now: number): Promise<boolean> {
    return this.run(async (pg) => {
      const res = await pg.query(
        `INSERT INTO app.agent_room_claims (room_id, claim_key, member, user_id, claimed_seq, updated_at)
         VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT (room_id, claim_key) DO UPDATE
           SET member = EXCLUDED.member, user_id = EXCLUDED.user_id,
               claimed_seq = EXCLUDED.claimed_seq, state = 'held', updated_at = EXCLUDED.updated_at
         WHERE app.agent_room_claims.state = 'released'
         RETURNING member`,
        [roomId, claimKey, member, userId, seq, now]
      );
      return res.rows.length === 1;
    });
  }

  settleClaim(roomId: string, claimKey: string, userId: string, state: "done" | "released", now: number): Promise<boolean> {
    return this.run(async (pg) => {
      const res = await pg.query(
        `UPDATE app.agent_room_claims SET state = $4, updated_at = $5
          WHERE room_id = $1 AND claim_key = $2 AND user_id = $3 AND state = 'held'
          RETURNING claim_key`,
        [roomId, claimKey, userId, state, now]
      );
      return res.rows.length === 1;
    });
  }

  wakeCheck(w: WakeRequest): Promise<WakeVerdict> {
    return this.run(async (pg) => {
      const res = await pg.query(
        `SELECT result FROM app.agent_wake_check($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
        [w.target.userId, w.fromUserId, w.roomId, w.seq, w.target.member, w.target.memberRef, w.target.deviceId, w.fromMember, w.now]
      );
      return (res.rows[0]?.result as WakeVerdict | undefined) ?? "off";
    });
  }

  wakeCheckMany(b: WakeBatch): Promise<WakeVerdict[]> {
    return this.run(async (pg) => {
      const targets = b.targets.map((t) => ({
        to_user_id: t.userId,
        to_member: t.member,
        to_ref: t.memberRef,
        to_device: t.deviceId
      }));
      const res = await pg.query(
        `SELECT to_user_id, to_member, to_device, result
           FROM app.agent_wake_check_many($1, $2, $3, $4, $5, $6::jsonb)`,
        [b.fromUserId, b.roomId, b.seq, b.fromMember, b.now, JSON.stringify(targets)]
      );
      // Rows come back in to_user_id order (deadlock-free locking); map them
      // back to the caller's target order.
      const key = (u: unknown, m: unknown, d: unknown) => `${u}\u0000${m}\u0000${d}`;
      const byTarget = new Map<string, WakeVerdict>(
        res.rows.map((r: Row) => [key(r.to_user_id, r.to_member, r.to_device ?? ""), r.result as WakeVerdict])
      );
      return b.targets.map((t) => byTarget.get(key(t.userId, t.member, t.deviceId)) ?? "off");
    });
  }

  pendingWakes(userId: string, limit: number): Promise<PendingWake[]> {
    return this.run(async (pg) => {
      const res = await pg.query(
        `SELECT w.id, w.room_id, r.name AS room_name, w.seq, w.from_member, w.from_user_id,
                i.github_login, i.fingerprint, w.to_member, w.to_ref, w.to_device, x.body
           FROM app.agent_wake_log w
           JOIN app.agent_rooms r ON r.id = w.room_id
           JOIN app.agent_room_messages x ON x.room_id = w.room_id AND x.seq = w.seq
           LEFT JOIN LATERAL app.agent_identity(ARRAY[w.from_user_id]) i ON true
          WHERE w.to_user_id = $1 AND w.delivered_at IS NULL AND w.dropped_at IS NULL
          ORDER BY w.id LIMIT $2`,
        [userId, limit]
      );
      return res.rows.map((r: Row) => ({
        id: num(r.id),
        roomId: r.room_id as string,
        roomName: r.room_name as string,
        seq: num(r.seq),
        fromMember: r.from_member as string,
        fromUserId: r.from_user_id as string,
        fromDisplay: r.github_login ? `@${r.github_login as string}` : strOrNull(r.fingerprint),
        fromGithub: strOrNull(r.github_login),
        fromFingerprint: strOrNull(r.fingerprint),
        toMember: r.to_member as string,
        toRef: strOrNull(r.to_ref),
        toDevice: r.to_device as string,
        body: r.body as string
      }));
    });
  }

  ackWakes(userId: string, ids: number[], now: number, dropped = false): Promise<void> {
    return this.run(async (pg) => {
      await pg.query(
        `UPDATE app.agent_wake_log SET ${dropped ? "dropped_at" : "delivered_at"} = $2
          WHERE to_user_id = $1 AND id = ANY($3::bigint[]) AND delivered_at IS NULL AND dropped_at IS NULL`,
        [userId, now, ids]
      );
    });
  }

  listRooms(userId: string, who?: MemberKey): Promise<RoomSummary[]> {
    return this.run(async (pg) => {
      const counts = `(SELECT count(*) FROM app.agent_room_members c WHERE c.room_id = r.id) AS member_count,
                      (SELECT count(*) FROM app.agent_room_access p
                        WHERE p.room_id = r.id AND p.accepted_at IS NOT NULL) AS people_count`;
      const res = who
        ? await pg.query(
            `SELECT r.*, ${counts},
                    (SELECT count(*) FROM app.agent_room_messages x
                      WHERE x.room_id = r.id AND x.seq > m.read_seq AND x.sender <> m.member) AS unread
               FROM app.agent_rooms r
               JOIN app.agent_room_access a ON a.room_id = r.id AND a.user_id = $1 AND a.accepted_at IS NOT NULL
               JOIN app.agent_room_members m ON m.room_id = r.id AND m.member = $2 AND m.device_id = $3 AND m.user_id = $1
              ORDER BY r.last_activity_at DESC LIMIT 200`,
            [userId, who.member, who.deviceId]
          )
        : await pg.query(
            `SELECT r.*, ${counts}
               FROM app.agent_rooms r
               JOIN app.agent_room_access a ON a.room_id = r.id AND a.user_id = $1 AND a.accepted_at IS NOT NULL
              ORDER BY r.last_activity_at DESC LIMIT 200`,
            [userId]
          );
      return res.rows.map((r: Row) => {
        const room = roomFrom(r);
        return {
          id: room.id,
          name: room.name,
          kind: room.kind,
          projectRef: room.projectRef,
          lastSeq: room.lastSeq,
          lastActivityAt: room.lastActivityAt,
          archivedAt: room.archivedAt,
          members: num(r.member_count),
          people: num(r.people_count),
          ...(who ? { unread: num(r.unread) } : {})
        };
      });
    });
  }

  inbox(userId: string, who: MemberKey, limit: number): Promise<InboxItem[]> {
    return this.run(async (pg) => {
      const res = await pg.query(
        `SELECT r.id AS room_id, r.name AS room_name, ${qualified("x")}
           FROM app.agent_room_members m
           JOIN app.agent_room_access a ON a.room_id = m.room_id AND a.user_id = $1 AND a.accepted_at IS NOT NULL
           JOIN app.agent_rooms r ON r.id = m.room_id
           JOIN app.agent_room_messages x ON x.room_id = m.room_id AND x.seq > m.read_seq
          WHERE m.member = $2 AND m.device_id = $3 AND m.user_id = $1 AND x.sender <> m.member
            AND (x.to_member = m.member
                 OR (x.to_member IS NULL AND ('@all' = ANY (x.mentions) OR m.member = ANY (x.mentions))))
          ORDER BY x.created_at, x.seq LIMIT $4`,
        [userId, who.member, who.deviceId, limit]
      );
      return res.rows.map((r: Row) => ({
        roomId: r.room_id as string,
        roomName: r.room_name as string,
        message: messageFrom(r)
      }));
    });
  }
}

/** The sweeper: `app.sweep_expired_agent_rooms` deletes expired ephemeral
 * rooms and returns their ids so each actor can wipe itself. */
export function sweepExpiredRooms(env: PgEnv, nowS: number, max = 500): Promise<string[]> {
  return withPg(env, async (pg) => {
    const res = await pg.query("SELECT id FROM app.sweep_expired_agent_rooms($1, $2)", [nowS, max]);
    return res.rows.map((r: Row) => r.id as string);
  });
}

/** Ephemeral rooms a chat created, deleted when that chat is archived. */
export function destroyRoomsForChat(env: PgEnv, chatId: string): Promise<string[]> {
  return withPg(env, async (pg) => {
    const res = await pg.query("SELECT id FROM app.destroy_agent_rooms_for_chat($1)", [chatId]);
    return res.rows.map((r: Row) => r.id as string);
  });
}
