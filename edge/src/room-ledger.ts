/**
 * LedgerRoomStore — a room's own ledger in its RoomActor's SQLite, written
 * behind to PostgreSQL (the Rivet-style actor: state lives with the actor, the
 * database is the durable copy everyone else reads).
 *
 * Room-scoped state is authoritative here: the room row's counters, members and
 * their read cursors, every message with its client id, and task claims. A post
 * is committed to SQLite and acknowledged; nothing on its path waits for
 * PostgreSQL unless it wakes another person (their engine reads the wake's body
 * from PostgreSQL, so the actor flushes before it nudges them).
 *
 * Cross-room state stays in PostgreSQL and passes straight through: grants and
 * invites (the console edits them directly), wake rules and checks, the room
 * list, the inbox and the wake queue. Creating, archiving and destroying a room
 * also go to PostgreSQL synchronously: grants reference the room row, and the
 * destroy cascade and its dropped-wakes trigger must run.
 *
 * {@link flush} writes the unflushed slice in one idempotent transaction; the
 * actor calls it on the first write after a quiet spell, then at most once a
 * second (and from its alarm, so an evicted actor's ledger still lands). Once
 * rows are flushed, all but the newest {@link KEEP_LOCAL} messages are trimmed
 * from SQLite; older reads come from PostgreSQL.
 */
import type { PgRoomStore } from "./room-store-pg";
import {
  ROOM_LIMITS,
  redactMessage,
  type ClaimRow,
  type ExternalWakes,
  type InboxItem,
  type Invite,
  type LedgerBatch,
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

/** Flushed messages kept in SQLite for reads and client-id retries. */
export const KEEP_LOCAL = 5000;
/** Most messages in one flush transaction. */
const FLUSH_BATCH = 500;

type SqlRow = Record<string, SqlStorageValue>;

const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS ledger_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS ledger_members (
     member TEXT NOT NULL, device_id TEXT NOT NULL, row TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0,
     PRIMARY KEY (member, device_id))`,
  `CREATE TABLE IF NOT EXISTS ledger_removed (member TEXT NOT NULL, device_id TEXT NOT NULL, PRIMARY KEY (member, device_id))`,
  `CREATE TABLE IF NOT EXISTS ledger_messages (
     seq INTEGER PRIMARY KEY, row TEXT NOT NULL, sender_user_id TEXT NOT NULL, client_id TEXT,
     flushed INTEGER NOT NULL DEFAULT 0)`,
  `CREATE UNIQUE INDEX IF NOT EXISTS ledger_messages_client ON ledger_messages (sender_user_id, client_id)
     WHERE client_id IS NOT NULL`,
  `CREATE INDEX IF NOT EXISTS ledger_messages_unflushed ON ledger_messages (seq) WHERE flushed = 0`,
  `CREATE TABLE IF NOT EXISTS ledger_claims (claim_key TEXT PRIMARY KEY, row TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0)`
];

export class LedgerRoomStore implements RoomStore {
  private ready = false;
  private readonly sql: SqlStorage;

  constructor(
    private readonly storage: DurableObjectStorage,
    private readonly pg: PgRoomStore,
    /** Told after every local write, so the actor can schedule a flush. */
    private readonly onWrite: () => void = () => {}
  ) {
    this.sql = storage.sql;
  }

  /** One database connection for a request's cross-room calls. */
  session<T>(fn: () => Promise<T>): Promise<T> {
    return this.pg.session(fn);
  }

  /** After storage.deleteAll() (a wipe), the tables must be made again. */
  forget(): void {
    this.ready = false;
  }

  private init(): void {
    if (this.ready) return;
    for (const stmt of SCHEMA) this.sql.exec(stmt);
    this.ready = true;
  }

  private rows(query: string, ...args: SqlStorageValue[]): SqlRow[] {
    this.init();
    return this.sql.exec<SqlRow>(query, ...args).toArray();
  }

  private exec(query: string, ...args: SqlStorageValue[]): void {
    this.init();
    this.sql.exec(query, ...args);
  }

  private meta(k: string): string | null {
    const r = this.rows("SELECT v FROM ledger_meta WHERE k = ?", k);
    return r.length ? (r[0].v as string) : null;
  }

  private setMeta(k: string, v: string): void {
    this.exec("INSERT INTO ledger_meta (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = excluded.v", k, v);
  }

  private localRoom(): RoomRow | null {
    const v = this.meta("room");
    return v ? (JSON.parse(v) as RoomRow) : null;
  }

  private saveRoom(room: RoomRow): void {
    this.setMeta("room", JSON.stringify(room));
  }

  private localFrom(): number {
    return Number(this.meta("local_from") ?? 1);
  }

  private touched(): void {
    this.onWrite();
  }

  /** Is anything waiting to be written behind? */
  hasUnflushed(): boolean {
    if (!this.localRoom()) return false;
    return (
      this.meta("dirty_room") === "1" ||
      this.rows("SELECT 1 FROM ledger_messages WHERE flushed = 0 LIMIT 1").length > 0 ||
      this.rows("SELECT 1 FROM ledger_members WHERE dirty > 0 LIMIT 1").length > 0 ||
      this.rows("SELECT 1 FROM ledger_removed LIMIT 1").length > 0 ||
      this.rows("SELECT 1 FROM ledger_claims WHERE dirty > 0 LIMIT 1").length > 0
    );
  }

  private members(): MemberRow[] {
    return this.rows("SELECT row FROM ledger_members ORDER BY rowid").map((r) => JSON.parse(r.row as string) as MemberRow);
  }

  private recent(): MessageRow[] {
    return this.rows("SELECT row FROM ledger_messages ORDER BY seq DESC LIMIT ?", ROOM_LIMITS.ring)
      .map((r) => JSON.parse(r.row as string) as MessageRow)
      .reverse();
  }

  // ── room lifecycle ────────────────────────────────────────────────────────

  async createRoom(room: RoomRow, owner: MemberRow): Promise<void> {
    await this.pg.createRoom(room, owner);
    this.saveRoom(room);
    this.setMeta("local_from", "1");
    this.exec(
      "INSERT INTO ledger_members (member, device_id, row, dirty) VALUES (?, ?, ?, 0)",
      owner.member,
      owner.deviceId,
      JSON.stringify(owner)
    );
  }

  async loadRoom(id: string): Promise<LoadedRoom | null> {
    const local = this.localRoom();
    if (local && local.id === id) {
      // Existence and grants still come from PostgreSQL: a room swept or
      // destroyed elsewhere is gone, and the console edits grants there.
      const pg = await this.pg.loadAccess(id);
      if (!pg) return null;
      // PostgreSQL moved past what this ledger ever wrote: posts landed there
      // without it (ROOM_LEDGER was off, or an older version ran). Trusting
      // the ledger would reuse those seqs and the flush would drop ours.
      if (pg.room.lastSeq > this.flushedSeq()) return this.rehydrate(id);
      const room: RoomRow = { ...local, archivedAt: pg.room.archivedAt };
      return { room, members: this.members(), access: pg.access, recent: this.recent() };
    }
    // First wake with a ledger: hydrate from PostgreSQL (a room that predates it).
    const loaded = await this.pg.loadRoom(id);
    if (!loaded) return null;
    const claims = await this.pg.loadClaims(id);
    this.hydrate(loaded, claims);
    return loaded;
  }

  /**
   * Rebuild the ledger from PostgreSQL, then put back what only this ledger
   * had: unflushed posts are re-appended after PostgreSQL's last seq (they
   * were never visible outside this actor but for its live sockets), and
   * unflushed member, removal and claim changes are re-applied as dirty.
   */
  private async rehydrate(id: string): Promise<LoadedRoom | null> {
    const unflushed = this.rows("SELECT row FROM ledger_messages WHERE flushed = 0 ORDER BY seq").map(
      (r) => JSON.parse(r.row as string) as MessageRow
    );
    const dirtyMembers = this.rows("SELECT row FROM ledger_members WHERE dirty > 0").map(
      (r) => JSON.parse(r.row as string) as MemberRow
    );
    const removed = this.rows("SELECT member, device_id FROM ledger_removed").map((r) => ({
      member: r.member as string,
      deviceId: r.device_id as string
    }));
    const dirtyClaims = this.rows("SELECT row FROM ledger_claims WHERE dirty > 0").map(
      (r) => JSON.parse(r.row as string) as ClaimRow
    );
    const loaded = await this.pg.loadRoom(id);
    if (!loaded) return null;
    const claims = await this.pg.loadClaims(id);
    console.log(
      JSON.stringify({ event: "room_ledger_rehydrate", room: id, pgSeq: loaded.room.lastSeq, reappended: unflushed.length })
    );
    this.init();
    this.storage.transactionSync(() => {
      this.hydrateRows(loaded, claims);
      let room = loaded.room;
      for (const m of unflushed) {
        const moved: MessageRow = { ...m, seq: room.lastSeq + 1 };
        this.sql.exec(
          "INSERT INTO ledger_messages (seq, row, sender_user_id, client_id, flushed) VALUES (?, ?, ?, ?, 0)",
          moved.seq,
          JSON.stringify(moved),
          moved.senderUserId,
          moved.clientId
        );
        room = { ...room, lastSeq: moved.seq, lastActivityAt: Math.max(room.lastActivityAt, moved.createdAt) };
      }
      this.saveRoom(room);
      if (unflushed.length) this.setMeta("dirty_room", "1");
      for (const m of dirtyMembers) {
        const pgRow = loaded.members.find((x) => x.member === m.member && x.deviceId === m.deviceId);
        const merged = pgRow ? { ...m, readSeq: Math.max(m.readSeq, pgRow.readSeq) } : m;
        this.sql.exec(
          `INSERT INTO ledger_members (member, device_id, row, dirty) VALUES (?, ?, ?, 1)
           ON CONFLICT (member, device_id) DO UPDATE SET row = excluded.row, dirty = 1`,
          m.member,
          m.deviceId,
          JSON.stringify(merged)
        );
      }
      for (const k of removed) {
        this.sql.exec("DELETE FROM ledger_members WHERE member = ? AND device_id = ?", k.member, k.deviceId);
        this.sql.exec("INSERT OR IGNORE INTO ledger_removed (member, device_id) VALUES (?, ?)", k.member, k.deviceId);
      }
      for (const c of dirtyClaims) {
        this.sql.exec(
          `INSERT INTO ledger_claims (claim_key, row, dirty) VALUES (?, ?, 1)
           ON CONFLICT (claim_key) DO UPDATE SET row = excluded.row, dirty = 1`,
          c.claimKey,
          JSON.stringify(c)
        );
      }
    });
    if (unflushed.length || dirtyMembers.length || removed.length || dirtyClaims.length) this.touched();
    return { room: this.localRoom()!, members: this.members(), access: loaded.access, recent: this.recent() };
  }

  private hydrate(loaded: LedgerHydration, claims: ClaimRow[]): void {
    this.init();
    this.storage.transactionSync(() => this.hydrateRows(loaded, claims));
  }

  private hydrateRows(loaded: LedgerHydration, claims: ClaimRow[]): void {
    this.sql.exec("DELETE FROM ledger_members");
    this.sql.exec("DELETE FROM ledger_removed");
    this.sql.exec("DELETE FROM ledger_messages");
    this.sql.exec("DELETE FROM ledger_claims");
    this.saveRoom(loaded.room);
    const oldest = loaded.recent.length ? loaded.recent[0].seq : loaded.room.lastSeq + 1;
    this.setMeta("local_from", String(oldest));
    // Everything hydrated came from PostgreSQL, so it is flushed by definition.
    this.setMeta("flushed_seq", String(loaded.room.lastSeq));
    this.setMeta("dirty_room", "0");
    for (const m of loaded.members) {
      this.sql.exec(
        "INSERT INTO ledger_members (member, device_id, row, dirty) VALUES (?, ?, ?, 0)",
        m.member,
        m.deviceId,
        JSON.stringify(m)
      );
    }
    for (const m of loaded.recent) {
      this.sql.exec(
        "INSERT INTO ledger_messages (seq, row, sender_user_id, client_id, flushed) VALUES (?, ?, ?, ?, 1)",
        m.seq,
        JSON.stringify(m),
        m.senderUserId,
        m.clientId
      );
    }
    for (const c of claims) {
      this.sql.exec("INSERT INTO ledger_claims (claim_key, row, dirty) VALUES (?, ?, 0)", c.claimKey, JSON.stringify(c));
    }
  }

  async setArchived(roomId: string, at: number | null): Promise<void> {
    await this.pg.setArchived(roomId, at);
    const room = this.localRoom();
    if (room) this.saveRoom({ ...room, archivedAt: at });
  }

  async destroy(roomId: string): Promise<void> {
    // The cascade and the dropped-wakes trigger run in PostgreSQL; the actor
    // wipes its storage (and this ledger) right after.
    await this.pg.destroy(roomId);
  }

  // ── the ledger: room-scoped, authoritative here ──────────────────────────

  async append(_roomId: string, m: MessageRow): Promise<boolean> {
    const room = this.localRoom();
    if (!room || room.archivedAt !== null || m.seq !== room.lastSeq + 1) return false;
    this.init();
    return this.storage.transactionSync(() => {
      this.exec(
        "INSERT INTO ledger_messages (seq, row, sender_user_id, client_id, flushed) VALUES (?, ?, ?, ?, 0)",
        m.seq,
        JSON.stringify(m),
        m.senderUserId,
        m.clientId
      );
      this.saveRoom({ ...room, lastSeq: m.seq, lastActivityAt: Math.max(room.lastActivityAt, m.createdAt) });
      this.setMeta("dirty_room", "1");
      this.touched();
      return true;
    });
  }

  async findByClientId(roomId: string, senderUserId: string, clientId: string): Promise<MessageRow | null> {
    const r = this.rows(
      "SELECT row FROM ledger_messages WHERE sender_user_id = ? AND client_id = ?",
      senderUserId,
      clientId
    );
    if (r.length) return JSON.parse(r[0].row as string) as MessageRow;
    // Older than the local window: PostgreSQL has every flushed message.
    return this.localFrom() > 1 ? this.pg.findByClientId(roomId, senderUserId, clientId) : null;
  }

  async upsertMember(_roomId: string, member: MemberRow): Promise<void> {
    this.exec("DELETE FROM ledger_removed WHERE member = ? AND device_id = ?", member.member, member.deviceId);
    this.exec(
      `INSERT INTO ledger_members (member, device_id, row, dirty) VALUES (?, ?, ?, 1)
       ON CONFLICT (member, device_id) DO UPDATE SET row = excluded.row, dirty = ledger_members.dirty + 1`,
      member.member,
      member.deviceId,
      JSON.stringify(member)
    );
    this.touched();
  }

  async removeMember(_roomId: string, key: MemberKey): Promise<void> {
    this.exec("DELETE FROM ledger_members WHERE member = ? AND device_id = ?", key.member, key.deviceId);
    this.exec("INSERT OR IGNORE INTO ledger_removed (member, device_id) VALUES (?, ?)", key.member, key.deviceId);
    this.touched();
  }

  async setReadSeq(_roomId: string, key: MemberKey, seq: number): Promise<void> {
    const r = this.rows("SELECT row FROM ledger_members WHERE member = ? AND device_id = ?", key.member, key.deviceId);
    if (!r.length) return;
    const m = JSON.parse(r[0].row as string) as MemberRow;
    if (seq <= m.readSeq) return;
    this.exec(
      "UPDATE ledger_members SET row = ?, dirty = dirty + 1 WHERE member = ? AND device_id = ?",
      JSON.stringify({ ...m, readSeq: seq }),
      key.member,
      key.deviceId
    );
    this.touched();
  }

  async messages(roomId: string, since: number, limit: number): Promise<MessageRow[]> {
    const from = this.localFrom();
    const out: MessageRow[] = [];
    if (since + 1 < from) {
      // The part older than the local window was flushed long ago.
      out.push(...(await this.pg.messages(roomId, since, Math.min(limit, from - 1 - since))));
      if (out.length >= limit) return out;
    }
    const after = out.length ? out[out.length - 1].seq : since;
    for (const r of this.rows("SELECT row FROM ledger_messages WHERE seq > ? ORDER BY seq LIMIT ?", after, limit - out.length)) {
      out.push(JSON.parse(r.row as string) as MessageRow);
    }
    return out;
  }

  async takeClaim(_roomId: string, claimKey: string, member: string, userId: string, seq: number, now: number): Promise<boolean> {
    const r = this.rows("SELECT row FROM ledger_claims WHERE claim_key = ?", claimKey);
    if (r.length && (JSON.parse(r[0].row as string) as ClaimRow).state !== "released") return false;
    const claim: ClaimRow = { claimKey, member, userId, claimedSeq: seq, state: "held", updatedAt: now };
    this.exec(
      `INSERT INTO ledger_claims (claim_key, row, dirty) VALUES (?, ?, 1)
       ON CONFLICT (claim_key) DO UPDATE SET row = excluded.row, dirty = ledger_claims.dirty + 1`,
      claimKey,
      JSON.stringify(claim)
    );
    this.touched();
    return true;
  }

  async settleClaim(_roomId: string, claimKey: string, userId: string, state: "done" | "released", now: number): Promise<boolean> {
    const r = this.rows("SELECT row FROM ledger_claims WHERE claim_key = ?", claimKey);
    if (!r.length) return false;
    const claim = JSON.parse(r[0].row as string) as ClaimRow;
    if (claim.userId !== userId || claim.state !== "held") return false;
    this.exec(
      "UPDATE ledger_claims SET row = ?, dirty = dirty + 1 WHERE claim_key = ?",
      JSON.stringify({ ...claim, state, updatedAt: now }),
      claimKey
    );
    this.touched();
    return true;
  }

  // ── write-behind ─────────────────────────────────────────────────────────

  /**
   * Write the unflushed slice to PostgreSQL. "gone": the room row no longer
   * exists there (destroyed or swept); the caller wipes. Rows written while
   * the flush was in flight stay dirty (their counters moved) for the next one.
   */
  async flush(roomId: string): Promise<"ok" | "gone" | "idle" | "diverged"> {
    const room = this.localRoom();
    if (!room || room.id !== roomId) return "idle";
    const messages = this.rows("SELECT row FROM ledger_messages WHERE flushed = 0 ORDER BY seq LIMIT ?", FLUSH_BATCH).map(
      (r) => JSON.parse(r.row as string) as MessageRow
    );
    const memberRows = this.rows("SELECT member, device_id, row, dirty FROM ledger_members WHERE dirty > 0");
    const removed = this.rows("SELECT member, device_id FROM ledger_removed").map((r) => ({
      member: r.member as string,
      deviceId: r.device_id as string
    }));
    const claimRows = this.rows("SELECT claim_key, row, dirty FROM ledger_claims WHERE dirty > 0");
    const dirtyRoom = this.meta("dirty_room") === "1";
    if (!messages.length && !memberRows.length && !removed.length && !claimRows.length && !dirtyRoom) return "idle";
    // Counters as of this slice: never claim a seq the batch doesn't carry.
    const lastSeq = messages.length ? messages[messages.length - 1].seq : Math.min(room.lastSeq, this.flushedSeq());
    const batch: LedgerBatch = {
      messages,
      members: memberRows.map((r) => JSON.parse(r.row as string) as MemberRow),
      removed,
      claims: claimRows.map((r) => JSON.parse(r.row as string) as ClaimRow),
      lastSeq,
      lastActivityAt: room.lastActivityAt
    };
    const result = await this.pg.applyLedger(roomId, batch);
    if (result === "gone" || result === "diverged") return result;
    // Mark exactly what was sent; anything that changed meanwhile stays dirty.
    if (messages.length) {
      this.exec("UPDATE ledger_messages SET flushed = 1 WHERE seq BETWEEN ? AND ?", messages[0].seq, lastSeq);
      this.setMeta("flushed_seq", String(lastSeq));
    }
    for (const r of memberRows) {
      this.exec(
        "UPDATE ledger_members SET dirty = 0 WHERE member = ? AND device_id = ? AND dirty = ?",
        r.member,
        r.device_id,
        r.dirty
      );
    }
    for (const k of removed) this.exec("DELETE FROM ledger_removed WHERE member = ? AND device_id = ?", k.member, k.deviceId);
    for (const r of claimRows) this.exec("UPDATE ledger_claims SET dirty = 0 WHERE claim_key = ? AND dirty = ?", r.claim_key, r.dirty);
    const still = this.localRoom();
    if (still && still.lastSeq === lastSeq && !this.rows("SELECT 1 FROM ledger_messages WHERE flushed = 0 LIMIT 1").length) {
      this.setMeta("dirty_room", "0");
    }
    this.trim();
    return "ok";
  }

  private flushedSeq(): number {
    return Number(this.meta("flushed_seq") ?? this.localFrom() - 1);
  }

  /** Keep the newest KEEP_LOCAL flushed messages; PostgreSQL has the rest. */
  private trim(): void {
    const room = this.localRoom();
    if (!room) return;
    const cut = room.lastSeq - KEEP_LOCAL;
    if (cut < this.localFrom()) return;
    this.exec("DELETE FROM ledger_messages WHERE seq <= ? AND flushed = 1", cut);
    this.setMeta("local_from", String(cut + 1));
  }

  // ── cross-room: PostgreSQL ───────────────────────────────────────────────

  userIdByEmail(email: string): Promise<string | null> {
    return this.pg.userIdByEmail(email);
  }
  invite(roomId: string, userId: string, invitedBy: string, now: number): Promise<void> {
    return this.pg.invite(roomId, userId, invitedBy, now);
  }
  respondInvite(roomId: string, userId: string, accept: boolean, now: number): Promise<boolean> {
    return this.pg.respondInvite(roomId, userId, accept, now);
  }
  async removePerson(roomId: string, userId: string): Promise<void> {
    await this.pg.removePerson(roomId, userId);
    for (const m of this.members().filter((x) => x.userId === userId)) {
      this.exec("DELETE FROM ledger_members WHERE member = ? AND device_id = ?", m.member, m.deviceId);
    }
  }
  /** Local rows are rewritten before the first await, so any write-behind
   * that starts from here on carries the redacted text; PostgreSQL then
   * redacts what was already written behind (older than the local window
   * too). The actor waits out an in-flight flush before calling this. */
  async redactPerson(roomId: string, userId: string, body: string, now: number): Promise<void> {
    for (const r of this.rows("SELECT seq, row FROM ledger_messages WHERE sender_user_id = ?", userId)) {
      const m = redactMessage(JSON.parse(r.row as string) as MessageRow, body);
      this.exec("UPDATE ledger_messages SET row = ? WHERE seq = ?", JSON.stringify(m), r.seq);
    }
    for (const r of this.rows("SELECT claim_key, row FROM ledger_claims")) {
      const claim = JSON.parse(r.row as string) as ClaimRow;
      if (claim.userId !== userId || claim.state !== "held") continue;
      this.exec(
        "UPDATE ledger_claims SET row = ?, dirty = dirty + 1 WHERE claim_key = ?",
        JSON.stringify({ ...claim, state: "released", updatedAt: now }),
        r.claim_key
      );
      this.touched();
    }
    await this.pg.redactPerson(roomId, userId, body, now);
  }
  setExternalWakes(roomId: string, userId: string, value: ExternalWakes): Promise<void> {
    return this.pg.setExternalWakes(roomId, userId, value);
  }
  invites(userId: string): Promise<Invite[]> {
    return this.pg.invites(userId);
  }
  wakeCheck(wake: WakeRequest): Promise<WakeVerdict> {
    return this.pg.wakeCheck(wake);
  }
  wakeCheckMany(batch: WakeBatch): Promise<WakeVerdict[]> {
    return this.pg.wakeCheckMany(batch);
  }
  pendingWakes(userId: string, limit: number): Promise<PendingWake[]> {
    return this.pg.pendingWakes(userId, limit);
  }
  ackWakes(userId: string, ids: number[], now: number, dropped?: boolean): Promise<void> {
    return this.pg.ackWakes(userId, ids, now, dropped);
  }
  listRooms(userId: string, who?: MemberKey): Promise<RoomSummary[]> {
    return this.pg.listRooms(userId, who);
  }
  inbox(userId: string, who: MemberKey, limit: number): Promise<InboxItem[]> {
    return this.pg.inbox(userId, who, limit);
  }
}

type LedgerHydration = LoadedRoom;
