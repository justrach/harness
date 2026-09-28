/**
 * Agent rooms (room-actor.ts): the logic, free of Durable Object and
 * PostgreSQL plumbing so it runs under plain vitest against MemoryRoomStore.
 *
 * A room is a shared log agents and people post into and read on demand.
 * PostgreSQL (`app.agent_rooms`, `app.agent_room_members`,
 * `app.agent_room_messages`; zigrepper migration 0020) is the store of
 * record; the RoomActor holds members, the last seq and a small ring of
 * recent messages, assigns seq, and acks a post only after the store has it.
 *
 * Delivery is pull by default: a plain post wakes nobody. A DM (`to`) or an
 * @mention names targets, which the post result returns as `deliver` for the
 * poster's engine to queue into those chats. Guards: bodies ≤ 8000 chars, 30
 * posts a minute per member, members only, and a hop cap — `hop` counts
 * consecutive agent posts since a person last posted, and a post at
 * {@link HOP_CAP} or beyond wakes nobody.
 */

export const ROOM_LIMITS = {
  bodyChars: 8000,
  nameChars: 80,
  mentions: 32,
  postsPerMinute: 30,
  ring: 200,
  readPage: 200,
  members: 64
};

/** A post this many agent hops from a person's post wakes nobody. */
export const HOP_CAP = 6;

export type RoomKind = "ephemeral" | "persistent";
export type MemberKind = "harness_chat" | "graff" | "external";
export type MessageKind = "message" | "claim" | "done" | "task";

const ROOM_KINDS: readonly string[] = ["ephemeral", "persistent"];
const MEMBER_KINDS: readonly string[] = ["harness_chat", "graff", "external"];
const MESSAGE_KINDS: readonly string[] = ["message", "claim", "done", "task"];

export const ROOM_ID = /^room_[0-9a-f]{24}$/;
const REF = /^[A-Za-z0-9_-]{1,128}$/;
const DEVICE = /^[A-Za-z0-9_-]{0,128}$/;
/** Member names are what @mentions match, exactly: no whitespace and no
 * leading `@`. An inner `@` is normal (graff peers are `claude@codegraff`). */
const MEMBER = /^[^\s@][^\s]{0,127}$/;

export interface RoomRow {
  id: string;
  orgId: string;
  createdBy: string;
  name: string;
  kind: RoomKind;
  parentChat: string | null;
  idleTtlS: number | null;
  lastSeq: number;
  createdAt: number;
  lastActivityAt: number;
  archivedAt: number | null;
}

export interface MemberRow {
  member: string;
  memberKind: MemberKind;
  memberRef: string | null;
  deviceId: string;
  role: "owner" | "member";
  readSeq: number;
  joinedAt: number;
}

export interface MessageRow {
  seq: number;
  sender: string;
  senderDevice: string;
  fromUser: boolean;
  kind: MessageKind;
  toMember: string | null;
  body: string;
  replyTo: number | null;
  mentions: string[];
  hop: number;
  createdAt: number;
}

export interface RoomSummary {
  id: string;
  name: string;
  kind: RoomKind;
  lastSeq: number;
  lastActivityAt: number;
  archivedAt: number | null;
  members: number;
  /** Set when the listing asked on behalf of a member of this room. */
  unread?: number;
}

export interface InboxItem {
  roomId: string;
  roomName: string;
  message: MessageRow;
}

export interface LoadedRoom {
  room: RoomRow;
  members: MemberRow[];
  /** Newest last, at most {@link ROOM_LIMITS.ring}. */
  recent: MessageRow[];
}

export interface MemberKey {
  member: string;
  deviceId: string;
}

/** The store of record. PgRoomStore in production, MemoryRoomStore in tests. */
export interface RoomStore {
  createRoom(room: RoomRow, owner: MemberRow): Promise<void>;
  loadRoom(id: string): Promise<LoadedRoom | null>;
  /** Commit `message` as the room's next seq. False when the room moved on,
   * was archived, or is gone: the caller must reload before trusting state. */
  append(roomId: string, message: MessageRow): Promise<boolean>;
  upsertMember(roomId: string, member: MemberRow): Promise<void>;
  removeMember(roomId: string, key: MemberKey): Promise<void>;
  setReadSeq(roomId: string, key: MemberKey, seq: number): Promise<void>;
  messages(roomId: string, since: number, limit: number): Promise<MessageRow[]>;
  setArchived(roomId: string, at: number | null): Promise<void>;
  destroy(roomId: string): Promise<void>;
  listRooms(orgId: string, who?: MemberKey): Promise<RoomSummary[]>;
  /** Unread messages addressed to `who` (DM, exact mention, or @all) across
   * the org's rooms it belongs to, oldest first. */
  inbox(orgId: string, who: MemberKey, limit: number): Promise<InboxItem[]>;
}

export class RoomError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message?: string
  ) {
    super(message ?? code);
  }
}

// ── validation ─────────────────────────────────────────────────────────────

export type Json = Record<string, unknown>;

const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);

const bad = (message: string): RoomError => new RoomError(400, "bad_request", message);

export function memberKey(body: Json): MemberKey {
  const member = str(body.member);
  const deviceId = str(body.device) ?? "";
  if (!member || !MEMBER.test(member)) throw bad("member: 1-128 chars, no spaces, not starting with @");
  if (!DEVICE.test(deviceId)) throw bad("device: invalid id");
  return { member, deviceId };
}

export function parseMember(body: Json, now: number, role: MemberRow["role"]): MemberRow {
  const { member, deviceId } = memberKey(body);
  const memberKind = str(body.memberKind) ?? "external";
  if (!MEMBER_KINDS.includes(memberKind)) throw bad("memberKind: harness_chat | graff | external");
  const memberRef = str(body.memberRef) ?? null;
  if (memberRef !== null && !REF.test(memberRef)) throw bad("memberRef: invalid id");
  if (memberKind === "harness_chat" && memberRef === null) throw bad("memberRef: required for harness_chat");
  return { member, memberKind: memberKind as MemberKind, memberRef, deviceId, role, readSeq: 0, joinedAt: now };
}

export interface CreateArgs {
  name: string;
  kind: RoomKind;
  parentChat: string | null;
  idleTtlS: number | null;
}

export function parseCreate(body: Json): CreateArgs {
  const name = (str(body.name) ?? "").trim();
  if (name.length < 1 || name.length > ROOM_LIMITS.nameChars) throw bad("name: 1-80 chars");
  const kind = str(body.kind) ?? "persistent";
  if (!ROOM_KINDS.includes(kind)) throw bad("kind: ephemeral | persistent");
  const parentChat = str(body.parentChat) ?? null;
  if (parentChat !== null && !REF.test(parentChat)) throw bad("parentChat: invalid id");
  const ttl = body.idleTtlS;
  const idleTtlS = ttl === undefined || ttl === null ? null : Number(ttl);
  if (idleTtlS !== null && (!Number.isInteger(idleTtlS) || idleTtlS <= 0)) {
    throw bad("idleTtlS: positive integer seconds");
  }
  // Mirrors agent_rooms_ephemeral_can_die: an ephemeral room needs a way out.
  if (kind === "ephemeral" && idleTtlS === null && parentChat === null) {
    throw bad("an ephemeral room needs idleTtlS or parentChat");
  }
  return { name, kind: kind as RoomKind, parentChat, idleTtlS };
}

export interface PostArgs {
  body: string;
  kind: MessageKind;
  to: string | null;
  replyTo: number | null;
  mentions: string[];
  fromUser: boolean;
}

export function parsePost(body: Json): PostArgs {
  const text = str(body.body) ?? "";
  if (text.trim().length === 0) throw bad("body: empty");
  if (text.length > ROOM_LIMITS.bodyChars) {
    throw new RoomError(413, "too_large", `body: at most ${ROOM_LIMITS.bodyChars} chars`);
  }
  const kind = str(body.kind) ?? "message";
  if (!MESSAGE_KINDS.includes(kind)) throw bad("kind: message | claim | done | task");
  const to = str(body.to) ?? null;
  if (to !== null && !MEMBER.test(to)) throw bad("to: a member name");
  const reply = body.replyTo;
  const replyTo = reply === undefined || reply === null ? null : Number(reply);
  if (replyTo !== null && (!Number.isInteger(replyTo) || replyTo <= 0)) throw bad("replyTo: a seq");
  const raw = Array.isArray(body.mentions) ? body.mentions : [];
  if (raw.length > ROOM_LIMITS.mentions) throw bad("mentions: too many");
  const mentions = raw.map((m) => {
    const name = str(m)?.replace(/^@/, "");
    if (!name || !MEMBER.test(name)) throw bad("mentions: member names");
    return name === "all" ? "@all" : name;
  });
  return { body: text, kind: kind as MessageKind, to, replyTo, mentions, fromUser: body.fromUser === true };
}

/** `@name` tokens in the body, matched exactly against member names. */
export function bodyMentions(body: string, names: ReadonlySet<string>): string[] {
  const found: string[] = [];
  for (const match of body.matchAll(/(^|[^\w@])@([^\s,;:!?()[\]{}"'`]+)/g)) {
    // A sentence-final period belongs to the sentence, not the name.
    const name = match[2].replace(/\.+$/, "");
    if (name === "all") found.push("@all");
    else if (names.has(name)) found.push(name);
  }
  return found;
}

export function addressedTo(message: MessageRow, member: string): boolean {
  return message.toMember !== null
    ? message.toMember === member
    : message.mentions.includes("@all") || message.mentions.includes(member);
}

export function newRoomId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(12));
  return `room_${[...bytes].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
}

const sameMember = (m: MemberKey, key: MemberKey): boolean =>
  m.member === key.member && m.deviceId === key.deviceId;

// ── the room ───────────────────────────────────────────────────────────────

export interface Delivery {
  member: string;
  memberKind: MemberKind;
  memberRef: string | null;
  deviceId: string;
}

export interface PostResult {
  message: MessageRow;
  /** Members to wake. Empty for plain posts and at or past the hop cap. */
  deliver: Delivery[];
  /** Per other member: how many of their messages the poster hasn't read,
   * for graff's reply-to-latest rule (applied client-side). */
  unreadFrom: Record<string, number>;
}

const nowS = (): number => Math.floor(Date.now() / 1000);

/**
 * One room's live state over a store. State-changing methods run one at a
 * time: the store is awaited mid-operation, and a Durable Object lets other
 * events in while it waits on a socket, so event order alone would not keep
 * seq assignment race-free.
 */
export class RoomCore {
  private queue: Promise<unknown> = Promise.resolve();
  private readonly postTimes = new Map<string, number[]>();

  constructor(
    private readonly store: RoomStore,
    public room: RoomRow,
    private members: MemberRow[],
    private recent: MessageRow[],
    private readonly clock: () => number = nowS
  ) {}

  static async create(
    store: RoomStore,
    id: string,
    orgId: string,
    userId: string,
    body: Json,
    clock: () => number = nowS
  ): Promise<RoomCore> {
    const args = parseCreate(body);
    const now = clock();
    const owner = parseMember(body, now, "owner");
    const room: RoomRow = {
      id,
      orgId,
      createdBy: userId,
      name: args.name,
      kind: args.kind,
      parentChat: args.parentChat,
      idleTtlS: args.idleTtlS,
      lastSeq: 0,
      createdAt: now,
      lastActivityAt: now,
      archivedAt: null
    };
    await store.createRoom(room, owner);
    return new RoomCore(store, room, [owner], [], clock);
  }

  static async load(store: RoomStore, id: string, clock: () => number = nowS): Promise<RoomCore | null> {
    const loaded = await store.loadRoom(id);
    return loaded && new RoomCore(store, loaded.room, loaded.members, loaded.recent, clock);
  }

  private serial<T>(fn: () => Promise<T>): Promise<T> {
    const run = this.queue.then(fn, fn);
    this.queue = run.catch(() => undefined);
    return run;
  }

  /** When an ephemeral room dies of idleness, in unix seconds; null if never. */
  expiresAt(): number | null {
    return this.room.kind === "ephemeral" && this.room.idleTtlS !== null
      ? this.room.lastActivityAt + this.room.idleTtlS
      : null;
  }

  snapshot(): { room: RoomRow; members: MemberRow[] } {
    return { room: this.room, members: this.members };
  }

  find(key: MemberKey): MemberRow | undefined {
    return this.members.find((m) => sameMember(m, key));
  }

  private requireMember(key: MemberKey): MemberRow {
    const found = this.find(key);
    if (!found) throw new RoomError(403, "not_a_member");
    return found;
  }

  private requireOpen(): void {
    if (this.room.archivedAt !== null) throw new RoomError(409, "room_archived");
  }

  join(body: Json): Promise<MemberRow> {
    return this.serial(async () => {
      this.requireOpen();
      const incoming = parseMember(body, this.clock(), "member");
      const existing = this.find(incoming);
      if (existing) {
        // Rejoining refreshes how the member is reached, never its role or cursor.
        const updated = { ...existing, memberKind: incoming.memberKind, memberRef: incoming.memberRef };
        await this.store.upsertMember(this.room.id, updated);
        this.members = this.members.map((m) => (m === existing ? updated : m));
        return updated;
      }
      if (this.members.length >= ROOM_LIMITS.members) throw new RoomError(409, "room_full");
      await this.store.upsertMember(this.room.id, incoming);
      this.members = [...this.members, incoming];
      return incoming;
    });
  }

  leave(body: Json): Promise<void> {
    return this.serial(async () => {
      const key = memberKey(body);
      this.requireMember(key);
      await this.store.removeMember(this.room.id, key);
      this.members = this.members.filter((m) => !sameMember(m, key));
    });
  }

  private rateLimit(key: MemberKey, now: number): void {
    const id = `${key.member}\u0000${key.deviceId}`;
    const recent = (this.postTimes.get(id) ?? []).filter((t) => now - t < 60);
    if (recent.length >= ROOM_LIMITS.postsPerMinute) throw new RoomError(429, "rate_limited");
    recent.push(now);
    this.postTimes.set(id, recent);
  }

  /** Consecutive agent hops: 0 for a person, else one past what it answers
   * (the replied-to post, or else the latest post). A reply to a post that
   * fell out of the ring is treated as capped: waking on unknown ancestry
   * could restart a loop. */
  private hopFor(fromUser: boolean, replyTo: number | null): number {
    if (fromUser) return 0;
    const parent =
      replyTo !== null ? this.recent.find((m) => m.seq === replyTo) : this.recent[this.recent.length - 1];
    if (!parent) return replyTo !== null ? HOP_CAP : 1;
    return parent.fromUser ? 1 : parent.hop + 1;
  }

  post(body: Json): Promise<PostResult> {
    return this.serial(async () => {
      this.requireOpen();
      const key = memberKey(body);
      const sender = this.requireMember(key);
      const args = parsePost(body);
      if (args.replyTo !== null && args.replyTo > this.room.lastSeq) throw bad("replyTo: no such seq");
      const names = new Set(this.members.map((m) => m.member));
      if (args.to !== null && !names.has(args.to)) throw bad("to: not a member of this room");
      const now = this.clock();
      this.rateLimit(key, now);
      const mentions = [...new Set([...args.mentions, ...bodyMentions(args.body, names)])];
      const message: MessageRow = {
        seq: this.room.lastSeq + 1,
        sender: sender.member,
        senderDevice: sender.deviceId,
        fromUser: args.fromUser,
        kind: args.kind,
        toMember: args.to,
        body: args.body,
        replyTo: args.replyTo,
        mentions,
        hop: this.hopFor(args.fromUser, args.replyTo),
        createdAt: now
      };
      if (!(await this.store.append(this.room.id, message))) {
        throw new RoomError(409, "stale", "the room changed underneath; retry");
      }
      this.room = { ...this.room, lastSeq: message.seq, lastActivityAt: now };
      this.recent = [...this.recent, message].slice(-ROOM_LIMITS.ring);
      const unreadFrom = this.unreadFrom(sender);
      // Posting reads everything up to your own post.
      await this.markRead(sender, message.seq);
      return { message, deliver: this.targets(message, sender), unreadFrom };
    });
  }

  private targets(message: MessageRow, sender: MemberRow): Delivery[] {
    if (message.hop >= HOP_CAP) return [];
    const others = this.members.filter((m) => !sameMember(m, sender));
    const wanted = others.filter((m) => addressedTo(message, m.member));
    return wanted.map(({ member, memberKind, memberRef, deviceId }) => ({ member, memberKind, memberRef, deviceId }));
  }

  private unreadFrom(reader: MemberRow): Record<string, number> {
    const counts: Record<string, number> = {};
    for (const m of this.recent) {
      if (m.seq > reader.readSeq && m.sender !== reader.member) {
        counts[m.sender] = (counts[m.sender] ?? 0) + 1;
      }
    }
    return counts;
  }

  private async markRead(key: MemberKey, seq: number): Promise<void> {
    const member = this.find(key);
    if (!member || seq <= member.readSeq) return;
    await this.store.setReadSeq(this.room.id, key, seq);
    const updated = { ...member, readSeq: seq };
    this.members = this.members.map((m) => (m === member ? updated : m));
  }

  /** Messages after `since`, oldest first: from the ring when it reaches back
   * that far, else from the store. With `advance`, moves the reader's cursor
   * to the newest message returned. */
  read(
    key: MemberKey,
    since: number,
    limit: number,
    advance: boolean
  ): Promise<{ messages: MessageRow[]; lastSeq: number; readSeq: number }> {
    return this.serial(async () => {
      this.requireMember(key);
      const page = Math.max(1, Math.min(limit || ROOM_LIMITS.readPage, ROOM_LIMITS.readPage));
      const from = Math.max(0, since);
      const oldest = this.recent[0]?.seq;
      const messages =
        from >= this.room.lastSeq
          ? []
          : oldest !== undefined && from >= oldest - 1
            ? this.recent.filter((m) => m.seq > from).slice(0, page)
            : await this.store.messages(this.room.id, from, page);
      const newest = messages[messages.length - 1];
      if (advance && newest) await this.markRead(key, newest.seq);
      return { messages, lastSeq: this.room.lastSeq, readSeq: this.find(key)?.readSeq ?? 0 };
    });
  }

  setArchived(key: MemberKey, archived: boolean): Promise<RoomRow> {
    return this.serial(async () => {
      this.requireMember(key);
      const at = archived ? this.clock() : null;
      await this.store.setArchived(this.room.id, at);
      this.room = { ...this.room, archivedAt: at };
      return this.room;
    });
  }

  /** Owners only (the creator joins as owner). The actor wipes itself after. */
  destroy(key: MemberKey): Promise<void> {
    return this.serial(async () => {
      if (this.requireMember(key).role !== "owner") throw new RoomError(403, "owner_only");
      await this.store.destroy(this.room.id);
    });
  }
}

// ── in-memory store (tests, and `wrangler dev` without Hyperdrive) ─────────

interface MemoryRoom {
  room: RoomRow;
  members: MemberRow[];
  messages: MessageRow[];
}

export class MemoryRoomStore implements RoomStore {
  readonly rooms = new Map<string, MemoryRoom>();

  async createRoom(room: RoomRow, owner: MemberRow): Promise<void> {
    if (this.rooms.has(room.id)) throw new RoomError(409, "room_exists");
    this.rooms.set(room.id, { room: { ...room }, members: [{ ...owner }], messages: [] });
  }

  async loadRoom(id: string): Promise<LoadedRoom | null> {
    const r = this.rooms.get(id);
    if (!r) return null;
    return {
      room: { ...r.room },
      members: r.members.map((m) => ({ ...m })),
      recent: r.messages.slice(-ROOM_LIMITS.ring)
    };
  }

  async append(roomId: string, message: MessageRow): Promise<boolean> {
    const r = this.rooms.get(roomId);
    if (!r || r.room.archivedAt !== null || r.room.lastSeq !== message.seq - 1) return false;
    r.messages.push({ ...message });
    r.room.lastSeq = message.seq;
    r.room.lastActivityAt = message.createdAt;
    return true;
  }

  async upsertMember(roomId: string, member: MemberRow): Promise<void> {
    const r = this.rooms.get(roomId);
    if (!r) throw new RoomError(410, "room_destroyed");
    r.members = [...r.members.filter((m) => !sameMember(m, member)), { ...member }];
  }

  async removeMember(roomId: string, key: MemberKey): Promise<void> {
    const r = this.rooms.get(roomId);
    if (r) r.members = r.members.filter((m) => !sameMember(m, key));
  }

  async setReadSeq(roomId: string, key: MemberKey, seq: number): Promise<void> {
    const m = this.rooms.get(roomId)?.members.find((x) => sameMember(x, key));
    if (m) m.readSeq = Math.max(m.readSeq, seq);
  }

  async messages(roomId: string, since: number, limit: number): Promise<MessageRow[]> {
    return (this.rooms.get(roomId)?.messages ?? []).filter((m) => m.seq > since).slice(0, limit);
  }

  async setArchived(roomId: string, at: number | null): Promise<void> {
    const r = this.rooms.get(roomId);
    if (r) r.room.archivedAt = at;
  }

  async destroy(roomId: string): Promise<void> {
    this.rooms.delete(roomId);
  }

  async listRooms(orgId: string, who?: MemberKey): Promise<RoomSummary[]> {
    const out: RoomSummary[] = [];
    for (const r of this.rooms.values()) {
      if (r.room.orgId !== orgId) continue;
      const me = who && r.members.find((m) => sameMember(m, who));
      if (who && !me) continue;
      out.push({
        id: r.room.id,
        name: r.room.name,
        kind: r.room.kind,
        lastSeq: r.room.lastSeq,
        lastActivityAt: r.room.lastActivityAt,
        archivedAt: r.room.archivedAt,
        members: r.members.length,
        ...(me ? { unread: r.messages.filter((m) => m.seq > me.readSeq && m.sender !== me.member).length } : {})
      });
    }
    return out.sort((a, b) => b.lastActivityAt - a.lastActivityAt);
  }

  async inbox(orgId: string, who: MemberKey, limit: number): Promise<InboxItem[]> {
    const items: InboxItem[] = [];
    for (const r of this.rooms.values()) {
      if (r.room.orgId !== orgId) continue;
      const me = r.members.find((m) => sameMember(m, who));
      if (!me) continue;
      for (const message of r.messages) {
        if (message.seq <= me.readSeq || message.sender === me.member) continue;
        if (addressedTo(message, me.member)) items.push({ roomId: r.room.id, roomName: r.room.name, message });
      }
    }
    return items.sort((a, b) => a.message.createdAt - b.message.createdAt || a.message.seq - b.message.seq).slice(0, limit);
  }
}
