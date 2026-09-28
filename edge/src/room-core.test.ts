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
  type Json
} from "./room-core";

const ORG = "user-1";
const alice = { member: "alice", device: "mac", memberKind: "harness_chat", memberRef: "chat-a" };
const bob = { member: "bob", device: "mac", memberKind: "harness_chat", memberRef: "chat-b" };
const carol = { member: "carol", device: "linux", memberKind: "graff" };

async function room(extra: Json = {}, clock = () => 1_000) {
  const store = new MemoryRoomStore();
  const core = await RoomCore.create(store, newRoomId(), ORG, "1", { name: "Build", ...alice, ...extra }, clock);
  await core.join(bob);
  await core.join(carol);
  return { store, core };
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
    for (let i = 1; i <= 3; i++) await core.post({ ...alice, body: `hi ${i}` });
    const read = await core.read({ member: "bob", deviceId: "mac" }, 1, 10, false);
    expect(read.messages.map((m) => m.seq)).toEqual([2, 3]);
    expect(read.lastSeq).toBe(3);
    // A cold actor reloads the same state from the store.
    const again = await RoomCore.load(store, core.room.id);
    expect(again?.room.lastSeq).toBe(3);
  });

  it("wakes nobody for a plain post, and exactly the mentioned or DM'd member otherwise", async () => {
    const { core } = await room();
    expect((await core.post({ ...alice, body: "status update" })).deliver).toEqual([]);
    const mention = await core.post({ ...alice, body: "@bob can you look?" });
    expect(mention.deliver.map((d) => d.member)).toEqual(["bob"]);
    expect(mention.deliver[0].memberRef).toBe("chat-b");
    const dm = await core.post({ ...alice, body: "just you", to: "carol", mentions: ["bob"] });
    expect(dm.deliver.map((d) => d.member)).toEqual(["carol"]);
    const all = await core.post({ ...alice, body: "@all standup" });
    expect(all.deliver.map((d) => d.member).sort()).toEqual(["bob", "carol"]);
  });

  it("matches @mentions exactly, never by substring", () => {
    const names = new Set(["bob", "bobby"]);
    expect(bodyMentions("ping @bob.", names)).toEqual(["bob"]);
    expect(bodyMentions("ping @bo and email@bob", names)).toEqual([]);
  });

  it("takes graff peer names with an inner @ as members and mentions", async () => {
    const { core } = await room();
    await core.join({ member: "claude@codegraff", device: "linux", memberKind: "graff" });
    const r = await core.post({ ...alice, body: "cc @claude@codegraff, thoughts?" });
    expect(r.deliver.map((d) => d.member)).toEqual(["claude@codegraff"]);
  });

  it("counts hops along the wake chain and stops waking at the cap", async () => {
    const { core } = await room();
    const human = await core.post({ ...alice, body: "@bob go" }, true);
    expect(human.message.hop).toBe(0);
    let last = human;
    const speakers = [bob, alice];
    for (let i = 1; i <= HOP_CAP; i++) {
      const [me, other] = [speakers[(i + 1) % 2], speakers[i % 2]];
      last = await core.post({ ...me, body: `@${other.member} next` });
      expect(last.message.hop).toBe(i);
    }
    expect(last.message.hop).toBe(HOP_CAP);
    expect(last.deliver).toEqual([]);
    // A person posting resets the chain.
    const reset = await core.post({ ...carol, body: "@all again" }, true);
    expect(reset.message.hop).toBe(0);
    expect(reset.deliver.length).toBe(2);
  });

  it("never raises the hop on unrelated traffic", async () => {
    const { core } = await room();
    for (let i = 0; i < 20; i++) await core.post({ ...(i % 2 ? alice : bob), body: `status ${i}` });
    const ping = await core.post({ ...carol, body: "@bob can you look?" });
    expect(ping.message.hop).toBe(1);
    expect(ping.deliver.map((d) => d.member)).toEqual(["bob"]);
  });

  it("ignores a caller's claim to be a person", async () => {
    const { core } = await room();
    await core.post({ ...alice, body: "@bob one" });
    const claimed = await core.post({ ...bob, body: "@alice two", fromUser: true });
    expect(claimed.message.fromUser).toBe(false);
    expect(claimed.message.hop).toBe(2);
  });

  it("enforces members only, body size, and the per-member rate", async () => {
    const { core } = await room();
    expect(await code(core.post({ member: "mallory", device: "x", body: "hi" }))).toBe("not_a_member");
    expect(await code(core.read({ member: "mallory", deviceId: "x" }, 0, 10, false))).toBe("not_a_member");
    expect(await code(core.post({ ...alice, body: "x".repeat(ROOM_LIMITS.bodyChars + 1) }))).toBe("too_large");
    expect(await code(core.post({ ...alice, body: "nul\u0000" }))).toBe("bad_request");
    await core.join({ ...bob, device: "studio" });
    for (let i = 0; i < ROOM_LIMITS.postsPerMinute; i++) await core.post({ ...bob, body: `${i}` });
    expect(await code(core.post({ ...bob, body: "one more" }))).toBe("rate_limited");
    // Another device of the same member shares the budget.
    expect(await code(core.post({ ...bob, device: "studio", body: "sneaky" }))).toBe("rate_limited");
    // Another member's budget is separate.
    expect(await code(core.post({ ...alice, body: "fine" }))).toBe("ok");
  });

  it("tells the same name on two devices apart", async () => {
    const { core } = await room();
    await core.join({ ...bob, device: "studio" });
    const r = await core.post({ ...alice, body: "@bob" });
    expect(r.deliver.map((d) => d.deviceId).sort()).toEqual(["mac", "studio"]);
  });

  it("keeps read cursors, inbox and unread counts per member", async () => {
    const { store, core } = await room();
    await core.post({ ...alice, body: "@bob one" });
    await core.post({ ...alice, body: "not for bob" });
    await core.post({ ...carol, body: "@all two" });
    const who = { member: "bob", deviceId: "mac" };
    expect((await store.inbox(ORG, who, 10)).map((i) => i.message.body)).toEqual(["@bob one", "@all two"]);
    expect((await store.listRooms(ORG, who))[0].unread).toBe(3);
    // Bob's reply reports what he hasn't read yet, per sender, and posting
    // does not swallow the DMs waiting in his inbox.
    const reply = await core.post({ ...bob, body: "on it" });
    expect(reply.unreadFrom).toEqual({ alice: 2, carol: 1 });
    expect((await store.inbox(ORG, who, 10)).length).toBe(2);
    await core.read(who, 0, 50, true);
    expect(await store.inbox(ORG, who, 10)).toEqual([]);
    // Reading with advance moves the cursor.
    await core.post({ ...alice, body: "@bob three" });
    await core.read(who, 0, 50, true);
    expect(await store.inbox(ORG, who, 10)).toEqual([]);
  });

  it("freezes writes when archived and lets only owners destroy", async () => {
    const { store, core } = await room();
    await core.setArchived({ member: "bob", deviceId: "mac" }, true);
    expect(await code(core.post({ ...alice, body: "hi" }))).toBe("room_archived");
    expect((await core.read({ member: "bob", deviceId: "mac" }, 0, 10, false)).messages).toEqual([]);
    await core.setArchived({ member: "bob", deviceId: "mac" }, false);
    expect(await code(core.post({ ...alice, body: "hi" }))).toBe("ok");
    expect(await code(core.destroy({ member: "bob", deviceId: "mac" }))).toBe("owner_only");
    await core.destroy({ member: "alice", deviceId: "mac" });
    expect(store.rooms.size).toBe(0);
  });

  it("gives every ephemeral room an idle lifetime, and reports expiry", async () => {
    const parented = await room({ kind: "ephemeral", parentChat: "chat-a" });
    expect(parented.core.room.idleTtlS).toBe(ROOM_LIMITS.defaultIdleTtlS);
    expect(await code(room({ kind: "ephemeral", idleTtlS: 2 ** 31 }))).toBe("bad_request");
    expect((await room({ kind: "persistent", idleTtlS: 60 })).core.expiresAt()).toBeNull();
    let now = 1_000;
    const { core } = await room({ kind: "ephemeral", idleTtlS: 600 }, () => now);
    expect(core.expiresAt()).toBe(1_600);
    now = 1_500;
    await core.post({ ...alice, body: "still here" });
    expect(core.expiresAt()).toBe(2_100);
  });

  it("refuses a post the store did not accept", async () => {
    const { store, core } = await room();
    // Someone else advanced the room behind this actor's back.
    store.rooms.get(core.room.id)!.room.lastSeq = 5;
    expect(await code(core.post({ ...alice, body: "hi" }))).toBe("stale");
  });
});
