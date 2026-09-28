import { describe, expect, it } from "vitest";
import {
  HOP_CAP,
  MemoryRoomStore,
  ROOM_ID,
  ROOM_LIMITS,
  RoomCore,
  RoomError,
  bodyMentions,
  newRoomId,
  type Caller,
  type Json
} from "./room-core";

const ORG = "user-1";
const me: Caller = { userId: "1" };
const them: Caller = { userId: "2" };
const alice = { member: "alice", device: "mac", memberKind: "harness_chat", memberRef: "chat-a" };
const bob = { member: "bob", device: "mac", memberKind: "harness_chat", memberRef: "chat-b" };
const carol = { member: "carol", device: "linux", memberKind: "graff" };
const dave = { member: "dave", device: "pc", memberKind: "harness_chat", memberRef: "chat-d" };

async function room(extra: Json = {}, clock = () => 1_000) {
  const store = new MemoryRoomStore();
  store.users.set("them@example.com", them.userId);
  const core = await RoomCore.create(store, newRoomId(), ORG, me, { name: "Build", ...alice, ...extra }, clock);
  await core.join(me, bob);
  await core.join(me, carol);
  return { store, core };
}

/** A room with a second person (`them`) who accepted and joined `dave`. */
async function shared(extra: Json = {}) {
  const made = await room(extra);
  await made.core.invite(me, { email: "Them@Example.com" });
  await made.core.respond(them, true);
  await made.core.join(them, dave);
  return made;
}

const code = async (p: Promise<unknown>): Promise<string> => {
  try {
    await p;
    return "ok";
  } catch (err) {
    return err instanceof RoomError ? err.code : String(err);
  }
};

describe("agent rooms", () => {
  it("mints ids in the migration's shape", () => {
    expect(newRoomId()).toMatch(ROOM_ID);
  });

  it("assigns seq in order and reads back from the ring and the store", async () => {
    const { store, core } = await room();
    for (let i = 1; i <= 3; i++) await core.post(me, { ...alice, body: `hi ${i}` });
    const read = await core.read(me, { member: "bob", deviceId: "mac" }, 1, 10, false);
    expect(read.messages.map((m) => m.seq)).toEqual([2, 3]);
    expect(read.lastSeq).toBe(3);
    const again = await RoomCore.load(store, core.room.id);
    expect(again?.room.lastSeq).toBe(3);
  });

  it("wakes nobody for a plain post, and exactly the mentioned or DM'd member otherwise", async () => {
    const { core } = await room();
    expect((await core.post(me, { ...alice, body: "status update" })).deliver).toEqual([]);
    const mention = await core.post(me, { ...alice, body: "@bob can you look?" });
    expect(mention.deliver.map((d) => d.member)).toEqual(["bob"]);
    expect(mention.deliver[0].memberRef).toBe("chat-b");
    const dm = await core.post(me, { ...alice, body: "just you", to: "carol", mentions: ["bob"] });
    expect(dm.deliver.map((d) => d.member)).toEqual(["carol"]);
    const all = await core.post(me, { ...alice, body: "@all standup" });
    expect(all.deliver.map((d) => d.member).sort()).toEqual(["bob", "carol"]);
  });

  it("matches @mentions exactly, never by substring", () => {
    const names = new Set(["bob", "bobby"]);
    expect(bodyMentions("ping @bob.", names)).toEqual(["bob"]);
    expect(bodyMentions("ping @bo and email@bob", names)).toEqual([]);
  });

  it("takes graff peer names with an inner @ as members and mentions", async () => {
    const { core } = await room();
    await core.join(me, { member: "claude@codegraff", device: "linux", memberKind: "graff" });
    const r = await core.post(me, { ...alice, body: "cc @claude@codegraff, thoughts?" });
    expect(r.deliver.map((d) => d.member)).toEqual(["claude@codegraff"]);
  });

  it("counts hops along the wake chain and stops waking at the cap", async () => {
    const { core } = await room();
    const human = await core.post(me, { ...alice, body: "@bob go" }, true);
    expect(human.message.hop).toBe(0);
    let last = human;
    const speakers = [bob, alice];
    for (let i = 1; i <= HOP_CAP; i++) {
      const [who, other] = [speakers[(i + 1) % 2], speakers[i % 2]];
      last = await core.post(me, { ...who, body: `@${other.member} next` });
      expect(last.message.hop).toBe(i);
    }
    expect(last.deliver).toEqual([]);
    const reset = await core.post(me, { ...carol, body: "@all again" }, true);
    expect(reset.message.hop).toBe(0);
    expect(reset.deliver.length).toBe(2);
  });

  it("never raises the hop on unrelated traffic", async () => {
    const { core } = await room();
    for (let i = 0; i < 20; i++) await core.post(me, { ...(i % 2 ? alice : bob), body: `status ${i}` });
    const ping = await core.post(me, { ...carol, body: "@bob can you look?" });
    expect(ping.message.hop).toBe(1);
  });

  it("ignores a caller's claim to be a person", async () => {
    const { core } = await room();
    await core.post(me, { ...alice, body: "@bob one" });
    const claimed = await core.post(me, { ...bob, body: "@alice two", fromUser: true });
    expect(claimed.message.fromUser).toBe(false);
    expect(claimed.message.hop).toBe(2);
  });

  it("enforces members only, body size, and the per-member rate", async () => {
    const { core } = await room();
    expect(await code(core.post(me, { member: "mallory", device: "x", body: "hi" }))).toBe("not_a_member");
    expect(await code(core.post(me, { ...alice, body: "x".repeat(ROOM_LIMITS.bodyChars + 1) }))).toBe("too_large");
    expect(await code(core.post(me, { ...alice, body: "nul\u0000" }))).toBe("bad_request");
    await core.join(me, { ...bob, device: "studio" });
    for (let i = 0; i < ROOM_LIMITS.postsPerMinute; i++) await core.post(me, { ...bob, body: `${i}` });
    expect(await code(core.post(me, { ...bob, body: "one more" }))).toBe("rate_limited");
    expect(await code(core.post(me, { ...bob, device: "studio", body: "sneaky" }))).toBe("rate_limited");
    expect(await code(core.post(me, { ...alice, body: "fine" }))).toBe("ok");
  });

  it("keeps read cursors, inbox and unread counts per member", async () => {
    const { store, core } = await room();
    await core.post(me, { ...alice, body: "@bob one" });
    await core.post(me, { ...alice, body: "not for bob" });
    await core.post(me, { ...carol, body: "@all two" });
    const who = { member: "bob", deviceId: "mac" };
    expect((await store.inbox(me.userId, who, 10)).map((i) => i.message.body)).toEqual(["@bob one", "@all two"]);
    expect((await store.listRooms(me.userId, who))[0].unread).toBe(3);
    const reply = await core.post(me, { ...bob, body: "on it" });
    expect(reply.unreadFrom).toEqual({ alice: 2, carol: 1 });
    expect((await store.inbox(me.userId, who, 10)).length).toBe(2);
    await core.read(me, who, 0, 50, true);
    expect(await store.inbox(me.userId, who, 10)).toEqual([]);
  });

  it("freezes writes when archived and lets only owners archive or destroy", async () => {
    const { store, core } = await shared();
    expect(await code(core.setArchived(them, true))).toBe("owner_only");
    await core.setArchived(me, true);
    expect(await code(core.post(me, { ...alice, body: "hi" }))).toBe("room_archived");
    await core.setArchived(me, false);
    expect(await code(core.destroy(them))).toBe("owner_only");
    await core.destroy(me);
    expect(store.rooms.size).toBe(0);
  });

  it("gives every ephemeral room an idle lifetime, and reports expiry", async () => {
    const parented = await room({ kind: "ephemeral", parentChat: "chat-a" });
    expect(parented.core.room.idleTtlS).toBe(ROOM_LIMITS.defaultIdleTtlS);
    expect(await code(room({ kind: "ephemeral", idleTtlS: 2 ** 31 }))).toBe("bad_request");
    let now = 1_000;
    const { core } = await room({ kind: "ephemeral", idleTtlS: 600 }, () => now);
    expect(core.expiresAt()).toBe(1_600);
    now = 1_500;
    await core.post(me, { ...alice, body: "still here" });
    expect(core.expiresAt()).toBe(2_100);
  });

  it("refuses a post the store did not accept", async () => {
    const { store, core } = await room();
    store.rooms.get(core.room.id)!.room.lastSeq = 5;
    expect(await code(core.post(me, { ...alice, body: "hi" }))).toBe("stale");
  });
});

describe("agent rooms across people", () => {
  it("shows a room only to people with an accepted grant", async () => {
    const { store, core } = await room();
    expect(core.canSee(them)).toBe(false);
    expect(await code(core.join(them, dave))).toBe("room_not_found");
    expect(await code(Promise.resolve().then(() => core.snapshot(them)))).toBe("room_not_found");
    expect(await store.listRooms(them.userId)).toEqual([]);
    // Invited is not in: nothing until they accept.
    await core.invite(me, { email: "them@example.com" });
    expect(core.canSee(them)).toBe(false);
    expect((await store.invites(them.userId)).map((i) => i.roomName)).toEqual(["Build"]);
    await core.respond(them, true);
    expect(core.canSee(them)).toBe(true);
    expect((await store.listRooms(them.userId)).length).toBe(1);
  });

  it("invites by email, owners only, and says when there's no account", async () => {
    const { core } = await shared();
    expect(await code(core.invite(them, { email: "x@example.com" }))).toBe("owner_only");
    expect(await code(core.invite(me, { email: "nobody@example.com" }))).toBe("no_account");
    expect(await core.invite(me, { email: "them@example.com" })).toEqual({ invited: false });
  });

  it("declining drops the invite", async () => {
    const { store, core } = await room();
    await core.invite(me, { email: "them@example.com" });
    await core.respond(them, false);
    expect(await store.invites(them.userId)).toEqual([]);
    expect(await code(core.respond(them, true))).toBe("no_invite");
  });

  it("never lets one person act as another's member", async () => {
    const { core } = await shared();
    expect(await code(core.post(them, { ...alice, body: "I am alice" }))).toBe("not_your_member");
    expect(await code(core.read(them, { member: "alice", deviceId: "mac" }, 0, 10, true))).toBe("not_your_member");
    expect(await code(core.leave(them, alice))).toBe("not_your_member");
    // Nor take over a member name someone else holds.
    expect(await code(core.join(them, { ...alice, memberRef: "chat-evil" }))).toBe("member_name_taken");
    const post = await core.post(them, { ...dave, body: "hello" });
    expect(post.message.senderUserId).toBe(them.userId);
  });

  it("wakes another person's chat only through their rules, and never via the poster", async () => {
    const { store, core } = await shared();
    const r = await core.post(me, { ...alice, body: "@dave and @bob please look" });
    expect(r.deliver.map((d) => d.member)).toEqual(["bob"]);
    expect(r.external).toEqual([{ member: "dave", deviceId: "pc", userId: them.userId, verdict: "allowed" }]);
    const pending = await store.pendingWakes(them.userId, 10);
    expect(pending.map((w) => [w.toRef, w.fromMember, w.body])).toEqual([["chat-d", "alice", "@dave and @bob please look"]]);
    await store.ackWakes(them.userId, [pending[0].id], 2_000);
    expect(await store.pendingWakes(them.userId, 10)).toEqual([]);

    store.rules.set(them.userId, { mode: "off", dailyCap: 50, allowFrom: [], blockFrom: [] });
    expect((await core.post(me, { ...alice, body: "@dave again" })).external[0].verdict).toBe("off");
    // A per-room "allow" beats the account's off switch.
    await core.setExternalWakes(them, { externalWakes: "allow" });
    expect((await core.post(me, { ...alice, body: "@dave now" })).external[0].verdict).toBe("allowed");
    await core.setExternalWakes(them, { externalWakes: "block" });
    expect((await core.post(me, { ...alice, body: "@dave?" })).external[0].verdict).toBe("room_blocked");
  });

  it("binds a room to a project: only that project's chats join", async () => {
    const project = "github.com/acme/app";
    expect(await code(room({ projectRef: project }))).toBe("wrong_project");
    const store = new MemoryRoomStore();
    store.users.set("them@example.com", them.userId);
    const core = await RoomCore.create(store, newRoomId(), ORG, me, {
      name: "App",
      ...alice,
      projectRef: project,
      memberProjectRef: project
    });
    await core.invite(me, { email: "them@example.com" });
    await core.respond(them, true);
    expect(await code(core.join(them, { ...dave, projectRef: "github.com/them/personal" }))).toBe("wrong_project");
    expect(await code(core.join(them, dave))).toBe("wrong_project");
    expect(await code(core.join(them, { ...dave, projectRef: project }))).toBe("ok");
  });

  it("answers a retried post with the original instead of posting twice", async () => {
    const { core } = await shared();
    const first = await core.post(me, { ...alice, body: "@dave once", clientId: "c-1" });
    const again = await core.post(me, { ...alice, body: "@dave once", clientId: "c-1" });
    expect(again.duplicate).toBe(true);
    expect(again.message.seq).toBe(first.message.seq);
    expect(again.external).toEqual([]);
    expect(core.room.lastSeq).toBe(first.message.seq);
    // Another person's same client id is theirs, not a collision.
    const theirs = await core.post(them, { ...dave, body: "mine", clientId: "c-1" });
    expect(theirs.duplicate).toBe(false);
  });

  it("gives a task to the first claimer, and lets a released claim be retaken", async () => {
    const { core } = await shared();
    await core.post(me, { ...alice, kind: "claim", claimKey: "task-1", body: "mine" });
    expect(await code(core.post(them, { ...dave, kind: "claim", claimKey: "task-1", body: "no, mine" }))).toBe("claim_held");
    expect(await code(core.post(them, { ...dave, kind: "done", claimKey: "task-1", body: "done" }))).toBe("not_your_claim");
    await core.release(me, { ...alice, claimKey: "task-1" });
    expect(await code(core.post(them, { ...dave, kind: "claim", claimKey: "task-1", body: "now mine" }))).toBe("ok");
    expect(await code(core.post(them, { ...dave, kind: "done", claimKey: "task-1", body: "finished" }))).toBe("ok");
    expect(await code(core.post(me, { ...alice, kind: "claim", claimKey: "task-1", body: "again?" }))).toBe("claim_held");
  });

  it("removes a person with their members, but never the last owner", async () => {
    const { core } = await shared();
    expect(await code(core.removePerson(them, me.userId))).toBe("owner_only");
    expect(await code(core.removePerson(me, me.userId))).toBe("last_owner");
    const gone = await core.removePerson(me, them.userId);
    expect(gone).toEqual([{ member: "dave", deviceId: "pc" }]);
    expect(core.canSee(them)).toBe(false);
    expect(core.find({ member: "dave", deviceId: "pc" })).toBeUndefined();
  });
});
