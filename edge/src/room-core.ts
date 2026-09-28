/**
 * Agent rooms (room-actor.ts): the logic, free of Durable Object and
 * PostgreSQL plumbing so it runs under plain vitest against MemoryRoomStore.
 *
 * A room is a shared log agents and people post into and read on demand, and
 * it can span people. PostgreSQL (`app.agent_rooms`, `…_members`, `…_messages`,
 * `…_access`, `…_claims`, and the wake rules; migrations 0020 and 0022) is
 * the store of record. The RoomActor holds members, grants, the last seq and a
 * ring of recent posts, assigns seq, and acks a post only after the store has
 * it.
 *
 * Who is who comes from the verified bearer, never the request: every member
 * and post carries the owning user id the edge stamped, a caller acts only as
 * members its own user owns, and seeing a room takes an accepted grant.
 *
 * Delivery is pull by default: a plain post wakes nobody. A DM (`to`) or an
 * @mention names targets. The poster's engine wakes its own user's chats;
 * another person's chats are woken only if their wake rules allow it
 * (`agent_wake_check`), and then by their own engine. Guards: bodies ≤ 8000
 * chars, 30 posts a minute per member, and a hop cap — `hop` counts
 * consecutive agent posts along the wake chain, and a post at
 * {@link HOP_CAP} or beyond wakes nobody.
 */

export const ROOM_LIMITS = {
  bodyChars: 8000,
  nameChars: 80,
  mentions: 32,
  postsPerMinute: 30,
  ring: 200,
  readPage: 200,
  members: 64,
  people: 32,
  /** Longest idle lifetime an ephemeral room may ask for: 30 days. */
  maxIdleTtlS: 30 * 24 * 60 * 60,
  /** An ephemeral room created without one dies after a day of silence. */
  defaultIdleTtlS: 24 * 60 * 60
};

/** A post this many agent hops from a person's post wakes nobody. */
export const HOP_CAP = 6;

export type RoomKind = "ephemeral" | "persistent";
export type MemberKind = "harness_chat" | "graff" | "external";
export type MessageKind = "message" | "claim" | "done" | "task";
export type Role = "owner" | "member";
/** A person's per-room override of their account wake rules. */
export type ExternalWakes = "follow" | "allow" | "block";

const ROOM_KINDS: readonly string[] = ["ephemeral", "persistent"];
const MEMBER_KINDS: readonly string[] = ["harness_chat", "graff", "external"];
const MESSAGE_KINDS: readonly string[] = ["message", "claim", "done", "task"];
const EXTERNAL_WAKES: readonly string[] = ["follow", "allow", "block"];

export const ROOM_ID = /^room_[0-9a-f]{24}$/;
const REF = /^[A-Za-z0-9_-]{1,128}$/;
const DEVICE = /^[A-Za-z0-9_-]{0,128}$/;
const CLIENT_ID = /^[A-Za-z0-9_.:-]{1,64}$/;
const CLAIM_KEY = /^[^\s\p{Cc}]{1,128}$/u;
/** A repository identity, e.g. `github.com/owner/repo`. */
const PROJECT_REF = /^[^\s\p{Cc}]{1,200}$/u;
const EMAIL = /^[^\s@]{1,128}@[^\s@]{1,253}$/;
/** Member names are what @mentions match, exactly: no whitespace or control
 * characters and no leading `@`. An inner `@` is normal (graff peers are
 * `claude@codegraff`). */
const MEMBER = /^[^\s@\p{Cc}][^\s\p{Cc}]{0,127}$/u;

/** The verified caller: stamped by the Worker from the bearer. */
export interface Caller {
  userId: string;
}

export interface RoomRow {
  id: string;
  orgId: string;
  createdBy: string;
  name: string;
  kind: RoomKind;
  parentChat: string | null;
  idleTtlS: number | null;
  /** Set: only chats from this project may join. */
  projectRef: string | null;
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
  /** The person this member belongs to (never from the request). */
  userId: string;
  role: Role;
  readSeq: number;
  joinedAt: number;
}

export interface MessageRow {
  seq: number;
  sender: string;
  senderDevice: string;
  senderUserId: string;
  fromUser: boolean;
  kind: MessageKind;
  toMember: string | null;
  body: string;
  replyTo: number | null;
  mentions: string[];
  hop: number;
  clientId: string | null;
  claimKey: string | null;
  createdAt: number;
}

export interface AccessRow {
  userId: string;
  role: Role;
  invitedBy: string;
  invitedAt: number;
  acceptedAt: number | null;
  externalWakes: ExternalWakes;
}

export interface RoomSummary {
  id: string;
  name: string;
  kind: RoomKind;
  projectRef: string | null;
  lastSeq: number;
  lastActivityAt: number;
  archivedAt: number | null;
  members: number;
  people: number;
  /** Set when the listing asked on behalf of a member of this room. */
  unread?: number;
}

export interface InboxItem {
  roomId: string;
  roomName: string;
  message: MessageRow;
}

export interface Invite {
  roomId: string;
  roomName: string;
  invitedBy: string;
  invitedAt: number;
}

export interface LoadedRoom {
  room: RoomRow;
  members: MemberRow[];
  access: AccessRow[];
  /** Newest last, at most {@link ROOM_LIMITS.ring}. */
  recent: MessageRow[];
}

export interface MemberKey {
  member: string;
  deviceId: string;
}

/** A wake of another person's chat, recorded by the store once their rules
 * allowed it; their engine picks it up and queues it into that chat. */
export interface PendingWake {
  id: number;
  roomId: string;
  roomName: string;
  seq: number;
  fromMember: string;
  fromUserId: string;
  /** The sender's account email, so the woken agent knows whose agent spoke. */
  fromDisplay: string | null;
  toMember: string;
  toRef: string | null;
  toDevice: string;
  body: string;
}

/** `agent_wake_check`'s verdict; only `allowed` wakes. */
export type WakeVerdict =
  | "allowed"
  | "self"
  | "not_member"
  | "off"
  | "blocked"
  | "not_listed"
  | "room_blocked"
  | "capped";

export interface WakeRequest {
  roomId: string;
  seq: number;
  fromUserId: string;
  fromMember: string;
  target: MemberRow;
  now: number;
}

/** The store of record. PgRoomStore in production, MemoryRoomStore in tests. */
export interface RoomStore {
  createRoom(room: RoomRow, owner: MemberRow): Promise<void>;
  loadRoom(id: string): Promise<LoadedRoom | null>;
  /** Commit `message` as the room's next seq. False when the room moved on,
   * was archived, or is gone: the caller must reload before trusting state. */
  append(roomId: string, message: MessageRow): Promise<boolean>;
  /** The post a retry with this client id already made, if any. */
  findByClientId(roomId: string, senderUserId: string, clientId: string): Promise<MessageRow | null>;
  upsertMember(roomId: string, member: MemberRow): Promise<void>;
  removeMember(roomId: string, key: MemberKey): Promise<void>;
  setReadSeq(roomId: string, key: MemberKey, seq: number): Promise<void>;
  messages(roomId: string, since: number, limit: number): Promise<MessageRow[]>;
  setArchived(roomId: string, at: number | null): Promise<void>;
  destroy(roomId: string): Promise<void>;
  /** The user id for an email, or null when nobody has that address. */
  userIdByEmail(email: string): Promise<string | null>;
  /** A pending grant; an existing grant (pending or accepted) is left alone. */
  invite(roomId: string, userId: string, invitedBy: string, now: number): Promise<void>;
  /** Accept (stamp accepted_at) or decline (delete) a pending grant. */
  respondInvite(roomId: string, userId: string, accept: boolean, now: number): Promise<boolean>;
  /** Drop a person from a room: their grant and every member they own. */
  removePerson(roomId: string, userId: string): Promise<void>;
  setExternalWakes(roomId: string, userId: string, value: ExternalWakes): Promise<void>;
  invites(userId: string): Promise<Invite[]>;
  /** First writer wins; a released claim can be retaken. False: held or done. */
  takeClaim(roomId: string, claimKey: string, member: string, userId: string, seq: number, now: number): Promise<boolean>;
  /** Finish or give back a claim the given user holds. False: not theirs. */
  settleClaim(roomId: string, claimKey: string, userId: string, state: "done" | "released", now: number): Promise<boolean>;
  /** Check another person's wake rules and, when allowed, record the wake
   * for their engine to deliver. */
  wakeCheck(wake: WakeRequest): Promise<WakeVerdict>;
  pendingWakes(userId: string, limit: number): Promise<PendingWake[]>;
  ackWakes(userId: string, ids: number[], now: number): Promise<void>;
  /** Rooms the user has an accepted grant for; with `who`, only those where
   * that member is in, with its unread count. */
  listRooms(userId: string, who?: MemberKey): Promise<RoomSummary[]>;
  /** Unread messages addressed to `who` (DM, exact mention, or @all) across
   * the rooms the user can see, oldest first. */
  inbox(userId: string, who: MemberKey, limit: number): Promise<InboxItem[]>;
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

export function parseMember(body: Json, caller: Caller, now: number, role: Role): MemberRow {
  const { member, deviceId } = memberKey(body);
  const memberKind = str(body.memberKind) ?? "external";
  if (!MEMBER_KINDS.includes(memberKind)) throw bad("memberKind: harness_chat | graff | external");
  const memberRef = str(body.memberRef) ?? null;
  if (memberRef !== null && !REF.test(memberRef)) throw bad("memberRef: invalid id");
  if (memberKind === "harness_chat" && memberRef === null) throw bad("memberRef: required for harness_chat");
  return {
    member,
    memberKind: memberKind as MemberKind,
    memberRef,
    deviceId,
    userId: caller.userId,
    role,
    readSeq: 0,
    joinedAt: now
  };
}

function parseProjectRef(v: unknown, field: string): string | null {
  const ref = str(v)?.trim() || null;
  if (ref !== null && !PROJECT_REF.test(ref)) throw bad(`${field}: a project identity`);
  return ref;
}

export interface CreateArgs {
  name: string;
  kind: RoomKind;
  parentChat: string | null;
  idleTtlS: number | null;
  projectRef: string | null;
}

export function parseCreate(body: Json): CreateArgs {
  const name = (str(body.name) ?? "").trim();
  if (name.length < 1 || name.length > ROOM_LIMITS.nameChars) throw bad("name: 1-80 chars");
  const kind = str(body.kind) ?? "persistent";
  if (!ROOM_KINDS.includes(kind)) throw bad("kind: ephemeral | persistent");
  const parentChat = str(body.parentChat) ?? null;
  if (parentChat !== null && !REF.test(parentChat)) throw bad("parentChat: invalid id");
  const ttl = body.idleTtlS;
  let idleTtlS = ttl === undefined || ttl === null ? null : Number(ttl);
  if (idleTtlS !== null && (!Number.isInteger(idleTtlS) || idleTtlS <= 0 || idleTtlS > ROOM_LIMITS.maxIdleTtlS)) {
    throw bad(`idleTtlS: whole seconds, 1 to ${ROOM_LIMITS.maxIdleTtlS}`);
  }
  // Every ephemeral room dies of idleness eventually, parent chat or not:
  // nothing else reliably ends a room whose parent is never archived.
  if (kind === "ephemeral" && idleTtlS === null) idleTtlS = ROOM_LIMITS.defaultIdleTtlS;
  if (kind === "persistent") idleTtlS = null;
  return { name, kind: kind as RoomKind, parentChat, idleTtlS, projectRef: parseProjectRef(body.projectRef, "projectRef") };
}

export interface PostArgs {
  body: string;
  kind: MessageKind;
  to: string | null;
  replyTo: number | null;
  mentions: string[];
  clientId: string | null;
  claimKey: string | null;
}

export function parsePost(body: Json): PostArgs {
  const text = str(body.body) ?? "";
  if (text.trim().length === 0) throw bad("body: empty");
  if (text.includes("\u0000")) throw bad("body: NUL characters");
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
  const clientId = str(body.clientId) ?? null;
  if (clientId !== null && !CLIENT_ID.test(clientId)) throw bad("clientId: 1-64 chars of [A-Za-z0-9_.:-]");
  const claimKey = str(body.claimKey) ?? null;
  if (claimKey !== null && !CLAIM_KEY.test(claimKey)) throw bad("claimKey: 1-128 chars, no spaces");
  if ((kind === "claim" || kind === "done") !== (claimKey !== null)) {
    throw bad("claimKey: required for claim and done posts, and only for them");
  }
  // No `fromUser` here: whether a person wrote a post is never the caller's
  // claim to make (it resets the hop cap). See RoomCore.post.
  return { body: text, kind: kind as MessageKind, to, replyTo, mentions, clientId, claimKey };
}

export function parseEmail(body: Json): string {
  const email = (str(body.email) ?? "").trim().toLowerCase();
  if (!EMAIL.test(email)) throw bad("email: an address");
  return email;
}

export function parseExternalWakes(body: Json): ExternalWakes {
  const value = str(body.externalWakes) ?? "";
  if (!EXTERNAL_WAKES.includes(value)) throw bad("externalWakes: follow | allow | block");
  return value as ExternalWakes;
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

export interface ExternalWake {
  member: string;
  deviceId: string;
  userId: string;
  verdict: WakeVerdict;
}

export interface PostResult {
  message: MessageRow;
  /** The poster's own members to wake (their engine queues these). Empty
   * for plain posts and at or past the hop cap. */
  deliver: Delivery[];
  /** Other people's members this post addressed, with their rules' verdict;
   * `allowed` ones are queued for their own engine to deliver. */
  external: ExternalWake[];
  /** Per other member: how many of their messages the poster hasn't read,
   * for graff's reply-to-latest rule (applied client-side). */
  unreadFrom: Record<string, number>;
  /** True when this was a retry of a post already made (same clientId). */
  duplicate: boolean;
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
    private access: AccessRow[],
    private recent: MessageRow[],
    private readonly clock: () => number = nowS
  ) {}

  static async create(
    store: RoomStore,
    id: string,
    orgId: string,
    caller: Caller,
    body: Json,
    clock: () => number = nowS
  ): Promise<RoomCore> {
    const args = parseCreate(body);
    const now = clock();
    const owner = parseMember(body, caller, now, "owner");
    if (args.projectRef !== null) {
      const chatProject = parseProjectRef(body.memberProjectRef, "memberProjectRef");
      if (chatProject !== args.projectRef) throw new RoomError(403, "wrong_project");
    }
    const room: RoomRow = {
      id,
      orgId,
      createdBy: caller.userId,
      name: args.name,
      kind: args.kind,
      parentChat: args.parentChat,
      idleTtlS: args.idleTtlS,
      projectRef: args.projectRef,
      lastSeq: 0,
      createdAt: now,
      lastActivityAt: now,
      archivedAt: null
    };
    // The store adds the creator's accepted owner grant with the room.
    await store.createRoom(room, owner);
    const grant: AccessRow = {
      userId: caller.userId,
      role: "owner",
      invitedBy: caller.userId,
      invitedAt: now,
      acceptedAt: now,
      externalWakes: "follow"
    };
    return new RoomCore(store, room, [owner], [grant], [], clock);
  }

  static async load(store: RoomStore, id: string, clock: () => number = nowS): Promise<RoomCore | null> {
    const loaded = await store.loadRoom(id);
    return loaded && new RoomCore(store, loaded.room, loaded.members, loaded.access, loaded.recent, clock);
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

  /** What a person with access sees. Other people's grant details stay
   * private: members see who is in, not who was invited. */
  snapshot(caller: Caller): { room: RoomRow; members: MemberRow[]; you: AccessRow | null } {
    this.requireAccess(caller);
    return { room: this.room, members: this.members, you: this.grant(caller) ?? null };
  }

  /** May this caller see the room? An accepted grant, nothing else. */
  canSee(caller: Caller): boolean {
    return this.grant(caller)?.acceptedAt != null;
  }

  private grant(caller: Caller): AccessRow | undefined {
    return this.access.find((a) => a.userId === caller.userId);
  }

  /** Callers without access get the same answer as a missing room. */
  private requireAccess(caller: Caller): AccessRow {
    const grant = this.grant(caller);
    if (!grant || grant.acceptedAt === null) throw new RoomError(404, "room_not_found");
    return grant;
  }

  private requireOwner(caller: Caller): AccessRow {
    const grant = this.requireAccess(caller);
    if (grant.role !== "owner") throw new RoomError(403, "owner_only");
    return grant;
  }

  find(key: MemberKey): MemberRow | undefined {
    return this.members.find((m) => sameMember(m, key));
  }

  /** A member the caller's own user owns: nobody acts as someone else's. */
  private requireOwnMember(caller: Caller, key: MemberKey): MemberRow {
    this.requireAccess(caller);
    const found = this.find(key);
    if (!found) throw new RoomError(403, "not_a_member");
    if (found.userId !== caller.userId) throw new RoomError(403, "not_your_member");
    return found;
  }

  private requireOpen(): void {
    if (this.room.archivedAt !== null) throw new RoomError(409, "room_archived");
  }

  join(caller: Caller, body: Json): Promise<MemberRow> {
    return this.serial(async () => {
      this.requireAccess(caller);
      this.requireOpen();
      const incoming = parseMember(body, caller, this.clock(), "member");
      if (this.room.projectRef !== null) {
        const chatProject = parseProjectRef(body.projectRef, "projectRef");
        if (chatProject !== this.room.projectRef) throw new RoomError(403, "wrong_project");
      }
      const existing = this.find(incoming);
      if (existing) {
        if (existing.userId !== caller.userId) throw new RoomError(409, "member_name_taken");
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

  leave(caller: Caller, body: Json): Promise<MemberKey> {
    return this.serial(async () => {
      const key = memberKey(body);
      this.requireOwnMember(caller, key);
      await this.store.removeMember(this.room.id, key);
      this.members = this.members.filter((m) => !sameMember(m, key));
      return key;
    });
  }

  /** Invite a person by email (owners only). An address with no account is
   * a 404; inviting someone already in (or invited) changes nothing. */
  invite(caller: Caller, body: Json): Promise<{ invited: boolean }> {
    return this.serial(async () => {
      this.requireOwner(caller);
      const email = parseEmail(body);
      if (this.access.length >= ROOM_LIMITS.people) throw new RoomError(409, "room_full");
      const userId = await this.store.userIdByEmail(email);
      if (userId === null) throw new RoomError(404, "no_account", "no Codegraff account with that email");
      if (this.access.some((a) => a.userId === userId)) return { invited: false };
      const now = this.clock();
      await this.store.invite(this.room.id, userId, caller.userId, now);
      this.access = [
        ...this.access,
        { userId, role: "member", invitedBy: caller.userId, invitedAt: now, acceptedAt: null, externalWakes: "follow" }
      ];
      return { invited: true };
    });
  }

  /** The invited person accepts or declines their own pending grant. */
  respond(caller: Caller, accept: boolean): Promise<AccessRow | null> {
    return this.serial(async () => {
      const grant = this.grant(caller);
      if (!grant || grant.acceptedAt !== null) throw new RoomError(404, "no_invite");
      const now = this.clock();
      if (!(await this.store.respondInvite(this.room.id, caller.userId, accept, now))) {
        throw new RoomError(404, "no_invite");
      }
      if (!accept) {
        this.access = this.access.filter((a) => a !== grant);
        return null;
      }
      const accepted = { ...grant, acceptedAt: now };
      this.access = this.access.map((a) => (a === grant ? accepted : a));
      return accepted;
    });
  }

  /** Remove a person (owners remove anyone but the last owner; anyone may
   * remove themselves). Their members go with them. */
  removePerson(caller: Caller, userId: string): Promise<MemberKey[]> {
    return this.serial(async () => {
      if (userId === caller.userId) this.requireAccess(caller);
      else this.requireOwner(caller);
      const target = this.access.find((a) => a.userId === userId);
      if (!target) throw new RoomError(404, "not_in_room");
      const owners = this.access.filter((a) => a.role === "owner" && a.acceptedAt !== null);
      if (target.role === "owner" && owners.length <= 1) throw new RoomError(409, "last_owner");
      await this.store.removePerson(this.room.id, userId);
      const gone = this.members.filter((m) => m.userId === userId);
      this.members = this.members.filter((m) => m.userId !== userId);
      this.access = this.access.filter((a) => a.userId !== userId);
      return gone.map(({ member, deviceId }) => ({ member, deviceId }));
    });
  }

  setExternalWakes(caller: Caller, body: Json): Promise<AccessRow> {
    return this.serial(async () => {
      const grant = this.requireAccess(caller);
      const value = parseExternalWakes(body);
      await this.store.setExternalWakes(this.room.id, caller.userId, value);
      const updated = { ...grant, externalWakes: value };
      this.access = this.access.map((a) => (a === grant ? updated : a));
      return updated;
    });
  }

  /** Per member name, across its devices: a new device is not a new budget. */
  private rateLimit(sender: MemberRow, now: number): void {
    const id = `${sender.userId}\u0000${sender.member}`;
    const recent = (this.postTimes.get(id) ?? []).filter((t) => now - t < 60);
    if (recent.length >= ROOM_LIMITS.postsPerMinute) throw new RoomError(429, "rate_limited");
    recent.push(now);
    this.postTimes.set(id, recent);
  }

  /** Consecutive agent hops along the wake chain: 0 for a person; else one
   * past the post this answers — the replied-to post, or the latest post
   * that addressed the sender (what woke it). Unrelated traffic never
   * raises it, and a post nobody prompted starts at 1. A reply to a post
   * that fell out of the ring counts as capped: waking on unknown ancestry
   * could restart a loop. Clamped at the cap. */
  private hopFor(fromUser: boolean, sender: MemberRow, replyTo: number | null): number {
    if (fromUser) return 0;
    let parent: MessageRow | undefined;
    if (replyTo !== null) {
      parent = this.recent.find((m) => m.seq === replyTo);
      if (!parent) return HOP_CAP;
    } else {
      for (let i = this.recent.length - 1; i >= 0 && !parent; i--) {
        const m = this.recent[i];
        if (m.sender !== sender.member && addressedTo(m, sender.member)) parent = m;
      }
    }
    if (!parent) return 1;
    return Math.min(HOP_CAP, parent.fromUser ? 1 : parent.hop + 1);
  }

  /** `fromUser` is set by the actor from how the caller reached it, never
   * from the request: today every post arrives through an agent's engine. */
  post(caller: Caller, body: Json, fromUser = false): Promise<PostResult> {
    return this.serial(async () => {
      this.requireOpen();
      const key = memberKey(body);
      const sender = this.requireOwnMember(caller, key);
      const args = parsePost(body);

      // A retry of a post already made answers with the original, waking nobody again.
      if (args.clientId !== null) {
        const earlier =
          this.recent.find((m) => m.senderUserId === caller.userId && m.clientId === args.clientId) ??
          (await this.store.findByClientId(this.room.id, caller.userId, args.clientId));
        if (earlier) {
          return { message: earlier, deliver: [], external: [], unreadFrom: this.unreadFrom(sender), duplicate: true };
        }
      }

      if (args.replyTo !== null && args.replyTo > this.room.lastSeq) throw bad("replyTo: no such seq");
      const names = new Set(this.members.map((m) => m.member));
      if (args.to !== null && !names.has(args.to)) throw bad("to: not a member of this room");
      const now = this.clock();
      this.rateLimit(sender, now);
      const seq = this.room.lastSeq + 1;

      // Claims are the lock; the post is the record. Take (or settle) first.
      if (args.kind === "claim" && args.claimKey !== null) {
        if (!(await this.store.takeClaim(this.room.id, args.claimKey, sender.member, caller.userId, seq, now))) {
          throw new RoomError(409, "claim_held", `${args.claimKey} is held or done by someone else`);
        }
      }
      if (args.kind === "done" && args.claimKey !== null) {
        if (!(await this.store.settleClaim(this.room.id, args.claimKey, caller.userId, "done", now))) {
          throw new RoomError(409, "not_your_claim");
        }
      }

      const mentions = [...new Set([...args.mentions, ...bodyMentions(args.body, names)])];
      const message: MessageRow = {
        seq,
        sender: sender.member,
        senderDevice: sender.deviceId,
        senderUserId: caller.userId,
        fromUser,
        kind: args.kind,
        toMember: args.to,
        body: args.body,
        replyTo: args.replyTo,
        mentions,
        hop: this.hopFor(fromUser, sender, args.replyTo),
        clientId: args.clientId,
        claimKey: args.claimKey,
        createdAt: now
      };
      if (!(await this.store.append(this.room.id, message))) {
        if (args.kind === "claim" && args.claimKey !== null) {
          await this.store.settleClaim(this.room.id, args.claimKey, caller.userId, "released", now).catch(() => false);
        }
        throw new RoomError(409, "stale", "the room changed underneath; retry");
      }
      this.room = { ...this.room, lastSeq: message.seq, lastActivityAt: now };
      this.recent = [...this.recent, message].slice(-ROOM_LIMITS.ring);

      const { deliver, external } = await this.targets(message, sender, now);
      // Posting reads nothing: a DM that arrived since your last read stays
      // in your inbox until read_room returns it.
      return { message, deliver, external, unreadFrom: this.unreadFrom(sender), duplicate: false };
    });
  }

  /** Split the addressed members: the poster's own are theirs to wake;
   * other people's go through those people's wake rules. */
  private async targets(message: MessageRow, sender: MemberRow, now: number) {
    const deliver: Delivery[] = [];
    const external: ExternalWake[] = [];
    if (message.hop >= HOP_CAP) return { deliver, external };
    for (const m of this.members) {
      if (sameMember(m, sender) || !addressedTo(message, m.member)) continue;
      if (m.userId === sender.userId) {
        deliver.push({ member: m.member, memberKind: m.memberKind, memberRef: m.memberRef, deviceId: m.deviceId });
        continue;
      }
      const verdict = await this.store.wakeCheck({
        roomId: this.room.id,
        seq: message.seq,
        fromUserId: sender.userId,
        fromMember: sender.member,
        target: m,
        now
      });
      external.push({ member: m.member, deviceId: m.deviceId, userId: m.userId, verdict });
    }
    return { deliver, external };
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
    caller: Caller,
    key: MemberKey,
    since: number,
    limit: number,
    advance: boolean
  ): Promise<{ messages: MessageRow[]; lastSeq: number; readSeq: number }> {
    return this.serial(async () => {
      this.requireOwnMember(caller, key);
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

  /** Give back a claim you hold, so someone else can take it. */
  release(caller: Caller, body: Json): Promise<void> {
    return this.serial(async () => {
      this.requireOwnMember(caller, memberKey(body));
      const claimKey = str(body.claimKey) ?? "";
      if (!CLAIM_KEY.test(claimKey)) throw bad("claimKey: 1-128 chars, no spaces");
      if (!(await this.store.settleClaim(this.room.id, claimKey, caller.userId, "released", this.clock()))) {
        throw new RoomError(409, "not_your_claim");
      }
    });
  }

  setArchived(caller: Caller, archived: boolean): Promise<RoomRow> {
    return this.serial(async () => {
      this.requireOwner(caller);
      const at = archived ? this.clock() : null;
      await this.store.setArchived(this.room.id, at);
      this.room = { ...this.room, archivedAt: at };
      return this.room;
    });
  }

  /** Owners only. The actor wipes itself after. */
  destroy(caller: Caller): Promise<void> {
    return this.serial(async () => {
      this.requireOwner(caller);
      await this.store.destroy(this.room.id);
    });
  }
}

// ── in-memory store (tests, and `wrangler dev` without Hyperdrive) ─────────

interface MemoryRoom {
  room: RoomRow;
  members: MemberRow[];
  access: AccessRow[];
  messages: MessageRow[];
  claims: Map<string, { member: string; userId: string; state: "held" | "done" | "released" }>;
}

export interface MemoryWakeRules {
  mode: "off" | "members" | "allowlist";
  dailyCap: number;
  allowFrom: string[];
  blockFrom: string[];
}

export class MemoryRoomStore implements RoomStore {
  readonly rooms = new Map<string, MemoryRoom>();
  readonly users = new Map<string, string>();
  readonly rules = new Map<string, MemoryWakeRules>();
  readonly wakes: (PendingWake & { toUserId: string; at: number; deliveredAt: number | null })[] = [];

  private visible(r: MemoryRoom, userId: string): boolean {
    return r.access.some((a) => a.userId === userId && a.acceptedAt !== null);
  }

  async createRoom(room: RoomRow, owner: MemberRow): Promise<void> {
    if (this.rooms.has(room.id)) throw new RoomError(409, "room_exists");
    this.rooms.set(room.id, {
      room: { ...room },
      members: [{ ...owner }],
      access: [
        {
          userId: room.createdBy,
          role: "owner",
          invitedBy: room.createdBy,
          invitedAt: room.createdAt,
          acceptedAt: room.createdAt,
          externalWakes: "follow"
        }
      ],
      messages: [],
      claims: new Map()
    });
  }

  async loadRoom(id: string): Promise<LoadedRoom | null> {
    const r = this.rooms.get(id);
    if (!r) return null;
    return {
      room: { ...r.room },
      members: r.members.map((m) => ({ ...m })),
      access: r.access.map((a) => ({ ...a })),
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

  async findByClientId(roomId: string, senderUserId: string, clientId: string): Promise<MessageRow | null> {
    return this.rooms.get(roomId)?.messages.find((m) => m.senderUserId === senderUserId && m.clientId === clientId) ?? null;
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

  async userIdByEmail(email: string): Promise<string | null> {
    return this.users.get(email.toLowerCase()) ?? null;
  }

  async invite(roomId: string, userId: string, invitedBy: string, now: number): Promise<void> {
    const r = this.rooms.get(roomId);
    if (!r || r.access.some((a) => a.userId === userId)) return;
    r.access.push({ userId, role: "member", invitedBy, invitedAt: now, acceptedAt: null, externalWakes: "follow" });
  }

  async respondInvite(roomId: string, userId: string, accept: boolean, now: number): Promise<boolean> {
    const r = this.rooms.get(roomId);
    const grant = r?.access.find((a) => a.userId === userId && a.acceptedAt === null);
    if (!r || !grant) return false;
    if (accept) grant.acceptedAt = now;
    else r.access = r.access.filter((a) => a !== grant);
    return true;
  }

  async removePerson(roomId: string, userId: string): Promise<void> {
    const r = this.rooms.get(roomId);
    if (!r) return;
    r.access = r.access.filter((a) => a.userId !== userId);
    r.members = r.members.filter((m) => m.userId !== userId);
  }

  async setExternalWakes(roomId: string, userId: string, value: ExternalWakes): Promise<void> {
    const grant = this.rooms.get(roomId)?.access.find((a) => a.userId === userId);
    if (grant) grant.externalWakes = value;
  }

  async invites(userId: string): Promise<Invite[]> {
    const out: Invite[] = [];
    for (const r of this.rooms.values()) {
      const grant = r.access.find((a) => a.userId === userId && a.acceptedAt === null);
      if (grant) out.push({ roomId: r.room.id, roomName: r.room.name, invitedBy: grant.invitedBy, invitedAt: grant.invitedAt });
    }
    return out;
  }

  async takeClaim(roomId: string, claimKey: string, member: string, userId: string): Promise<boolean> {
    const r = this.rooms.get(roomId);
    if (!r) return false;
    const held = r.claims.get(claimKey);
    if (held && held.state !== "released") return false;
    r.claims.set(claimKey, { member, userId, state: "held" });
    return true;
  }

  async settleClaim(roomId: string, claimKey: string, userId: string, state: "done" | "released"): Promise<boolean> {
    const held = this.rooms.get(roomId)?.claims.get(claimKey);
    if (!held || held.userId !== userId || held.state !== "held") return false;
    held.state = state;
    return true;
  }

  /** Mirrors `app.agent_wake_check`: per-room override, then the account
   * rule, then the daily cap. */
  async wakeCheck(w: WakeRequest): Promise<WakeVerdict> {
    const to = w.target.userId;
    if (to === w.fromUserId) return "self";
    const r = this.rooms.get(w.roomId);
    const override = r?.access.find((a) => a.userId === to)?.externalWakes ?? "follow";
    if (override === "block") return "room_blocked";
    const rules = this.rules.get(to) ?? { mode: "members", dailyCap: 50, allowFrom: [], blockFrom: [] };
    if (override !== "allow") {
      if (rules.blockFrom.includes(w.fromUserId)) return "blocked";
      if (rules.mode === "off") return "off";
      if (rules.mode === "allowlist" && !rules.allowFrom.includes(w.fromUserId)) return "not_listed";
    }
    const today = this.wakes.filter((x) => x.toUserId === to && w.now - x.at < 86_400).length;
    if (today >= rules.dailyCap) return "capped";
    const body = r?.messages.find((m) => m.seq === w.seq)?.body ?? "";
    this.wakes.push({
      id: this.wakes.length + 1,
      roomId: w.roomId,
      roomName: r?.room.name ?? w.roomId,
      seq: w.seq,
      fromMember: w.fromMember,
      fromUserId: w.fromUserId,
      fromDisplay: [...this.users].find(([, id]) => id === w.fromUserId)?.[0] ?? null,
      toMember: w.target.member,
      toRef: w.target.memberRef,
      toDevice: w.target.deviceId,
      toUserId: to,
      body,
      at: w.now,
      deliveredAt: null
    });
    return "allowed";
  }

  async pendingWakes(userId: string, limit: number): Promise<PendingWake[]> {
    return this.wakes
      .filter((w) => w.toUserId === userId && w.deliveredAt === null)
      .slice(0, limit)
      .map(({ toUserId: _to, at: _at, deliveredAt: _d, ...wake }) => wake);
  }

  async ackWakes(userId: string, ids: number[], now: number): Promise<void> {
    for (const w of this.wakes) if (w.toUserId === userId && ids.includes(w.id)) w.deliveredAt = now;
  }

  async listRooms(userId: string, who?: MemberKey): Promise<RoomSummary[]> {
    const out: RoomSummary[] = [];
    for (const r of this.rooms.values()) {
      if (!this.visible(r, userId)) continue;
      const me = who && r.members.find((m) => sameMember(m, who) && m.userId === userId);
      if (who && !me) continue;
      out.push({
        id: r.room.id,
        name: r.room.name,
        kind: r.room.kind,
        projectRef: r.room.projectRef,
        lastSeq: r.room.lastSeq,
        lastActivityAt: r.room.lastActivityAt,
        archivedAt: r.room.archivedAt,
        members: r.members.length,
        people: r.access.filter((a) => a.acceptedAt !== null).length,
        ...(me ? { unread: r.messages.filter((m) => m.seq > me.readSeq && m.sender !== me.member).length } : {})
      });
    }
    return out.sort((a, b) => b.lastActivityAt - a.lastActivityAt);
  }

  async inbox(userId: string, who: MemberKey, limit: number): Promise<InboxItem[]> {
    const items: InboxItem[] = [];
    for (const r of this.rooms.values()) {
      if (!this.visible(r, userId)) continue;
      const me = r.members.find((m) => sameMember(m, who) && m.userId === userId);
      if (!me) continue;
      for (const message of r.messages) {
        if (message.seq <= me.readSeq || message.sender === me.member) continue;
        if (addressedTo(message, me.member)) items.push({ roomId: r.room.id, roomName: r.room.name, message });
      }
    }
    return items.sort((a, b) => a.message.createdAt - b.message.createdAt || a.message.seq - b.message.seq).slice(0, limit);
  }
}
