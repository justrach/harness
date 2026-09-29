import { env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { deleteAccount } from "../../src/account-delete";
import { SECOND_PASS_MS } from "../../src/account-purge";
import { issueRefreshCredential } from "../../src/auth";
import { encodeHlc } from "../../src/registry-core";
import { devStore } from "../../src/room-actor";
import { FORGOTTEN_BODY, newRoomId } from "../../src/room-core";

const USER = "x-harness-auth-user";
const ORG = "x-harness-auth-org";

const stub = (ns: DurableObjectNamespace, name: string) => ns.get(ns.idFromName(name));

/** A fresh person per test: the objects and the dev room store outlive a test. */
const person = () => `u${crypto.randomUUID().slice(0, 8)}`;

const pushRegistry = async (userId: string, ops: { kind: string; id: string; deleted?: boolean }[]) => {
  const res = await stub(env.REGISTRY_ROOMS, `reg1/user-${userId}/${userId}`).fetch("https://r/push?device=mac", {
    method: "POST",
    headers: { [USER]: userId },
    body: JSON.stringify({
      batch: crypto.randomUUID(),
      ops: ops.map((o, i) =>
        o.deleted
          ? { kind: o.kind, id: o.id, op: "delete", hlc: encodeHlc(Date.now(), i + 100, "mac") }
          : { kind: o.kind, id: o.id, op: "upsert", set: { title: o.id }, hlc: encodeHlc(Date.now(), i, "mac") }
      )
    })
  });
  expect(res.status, await res.clone().text()).toBe(200);
};

/** A chat2 room with one log row, claimed by `owner`. */
const seedChat = (chatId: string, owner: string) =>
  runInDurableObject(stub(env.CHAT_ROOMS, `chat2/${chatId}`), (_i, state) => {
    state.storage.sql.exec("INSERT INTO meta (key, value) VALUES ('owner', ?)", owner);
    state.storage.sql.exec(
      "INSERT INTO rows (seq, device, batch_id, bytes, received_at) VALUES (1, 'mac', ?, ?, 1)",
      crypto.randomUUID(),
      new Uint8Array([1, 2, 3])
    );
  });

const chatRows = (chatId: string) =>
  runInDurableObject(stub(env.CHAT_ROOMS, `chat2/${chatId}`), (_i, state) => ({
    owner: [...state.storage.sql.exec("SELECT value FROM meta WHERE key = 'owner'")][0]?.value ?? null,
    rows: [...state.storage.sql.exec("SELECT seq FROM rows")].length
  }));

type Status = { status?: string; pass?: number; doneAt?: number | null; queued?: number };

const status = async (userId: string): Promise<Status> =>
  (await (await stub(env.ACCOUNT_PURGE, `purge1/${userId}`).fetch("https://p/status")).json()) as Status;

/** Run the job's alarms until `until` holds (each run works one batch). */
const drain = async (userId: string, until: (s: Status) => boolean) => {
  for (let i = 0; i < 50; i++) {
    if (until(await status(userId))) return;
    await runDurableObjectAlarm(stub(env.ACCOUNT_PURGE, `purge1/${userId}`));
  }
  throw new Error("purge did not settle");
};

const start = (userId: string) =>
  stub(env.ACCOUNT_PURGE, `purge1/${userId}`).fetch("https://p/start", { method: "POST", body: JSON.stringify({ userId }) });

/** The second pass waits out the access-token lifetime: move the job's clock past it. */
const elapse = (userId: string) =>
  runInDurableObject(stub(env.ACCOUNT_PURGE, `purge1/${userId}`), async (_i, state) => {
    const job = await state.storage.get<{ startedAt: number }>("job");
    await state.storage.put("job", { ...job, startedAt: (job?.startedAt ?? 0) - SECOND_PASS_MS });
  });

describe("account purge", () => {
  it("wipes what the person owns, leaves other people's data, and wipes again after tokens expire", async () => {
    const me = person();
    const other = person();
    await pushRegistry(me, [
      { kind: "chats", id: `${me}-c1` },
      { kind: "chats", id: `${me}-gone`, deleted: true },
      // Someone else's chat, listed in my registry: must survive.
      { kind: "chats", id: `${other}-c9` },
      { kind: "devices", id: `${me}-mac` }
    ]);
    await seedChat(`${me}-c1`, me);
    await seedChat(`${me}-gone`, me);
    await seedChat(`${other}-c9`, other);
    await stub(env.SESSION_ROOMS, `s2/${me}-c1`).fetch(`https://s/seed?chatId=${me}-c1`, { headers: { [USER]: me } });
    await stub(env.SESSION_ROOMS, `ws4/user-${me}/${me}`).fetch("https://s/seed", { headers: { [USER]: me } });
    await runInDurableObject(stub(env.DEVICE_ROOMS, `d2/${me}-mac`), (_i, state) => {
      state.storage.sql.exec("INSERT INTO meta (key, value) VALUES ('owner', ?)", me);
    });
    await runInDurableObject(stub(env.VAULT_ROOMS, `vault1/${me}`), (_i, state) => {
      state.storage.sql.exec("INSERT INTO vault_meta (k, v) VALUES ('keyEpoch', '3')");
    });
    await env.BLOBS.put(`blob/${me}/${me}-c1/tool-1`, "output");
    await env.BLOBS.put(`blob/${other}/${other}-c9/tool-1`, "theirs");
    await env.BLOBS.put(`backup/${me}-c1/latest.loro`, "snapshot");

    expect((await start(me)).status).toBe(200);
    expect(await (await start(me)).json()).toMatchObject({ status: "running" });
    await drain(me, (s) => s.pass === 2);

    expect(await chatRows(`${me}-c1`)).toEqual({ owner: null, rows: 0 });
    expect(await chatRows(`${me}-gone`)).toEqual({ owner: null, rows: 0 });
    expect(await chatRows(`${other}-c9`)).toEqual({ owner: other, rows: 1 });
    expect(await (await stub(env.SESSION_ROOMS, `s2/${me}-c1`).fetch("https://s/peek")).json()).toMatchObject({
      data: null,
      purgeCalls: 1
    });
    expect(await (await stub(env.SESSION_ROOMS, `ws4/user-${me}/${me}`).fetch("https://s/peek")).json()).toMatchObject({
      data: null
    });
    expect(
      await runInDurableObject(stub(env.DEVICE_ROOMS, `d2/${me}-mac`), (_i, state) =>
        [...state.storage.sql.exec("SELECT value FROM meta WHERE key = 'owner'")].length
      )
    ).toBe(0);
    expect(
      await runInDurableObject(stub(env.VAULT_ROOMS, `vault1/${me}`), (_i, state) =>
        [...state.storage.sql.exec("SELECT * FROM vault_meta")].length
      )
    ).toBe(0);
    expect(await env.BLOBS.get(`blob/${me}/${me}-c1/tool-1`)).toBeNull();
    expect(await env.BLOBS.get(`backup/${me}-c1/latest.loro`)).toBeNull();
    expect(await (await env.BLOBS.get(`blob/${other}/${other}-c9/tool-1`))?.text()).toBe("theirs");
    const registry = await stub(env.REGISTRY_ROOMS, `reg1/user-${me}/${me}`).fetch("https://r/rows", {
      headers: { [USER]: me }
    });
    expect(((await registry.json()) as { rows: unknown[] }).rows).toEqual([]);

    // A desktop still holding a live token re-seeds the registry and opens a
    // new chat before the second pass.
    await pushRegistry(me, [{ kind: "chats", id: `${me}-late` }]);
    await seedChat(`${me}-late`, me);
    await elapse(me);
    await drain(me, (s) => typeof s.doneAt === "number");
    expect(await chatRows(`${me}-late`)).toEqual({ owner: null, rows: 0 });
    expect(await chatRows(`${other}-c9`)).toEqual({ owner: other, rows: 1 });
    expect(await (await start(me)).json()).toMatchObject({ status: "done" });
  });

  it("leaves the second pass queued until the tokens have expired", async () => {
    const me = person();
    await start(me);
    await drain(me, (s) => s.pass === 2);

    // Alarms that land early (a retry, or one delivered around the pass change) do nothing.
    for (let i = 0; i < 3; i++) await runDurableObjectAlarm(stub(env.ACCOUNT_PURGE, `purge1/${me}`));
    const early = await status(me);
    expect(early).toMatchObject({ pass: 2, doneAt: null });
    expect(early.queued).toBeGreaterThan(0);

    await elapse(me);
    await drain(me, (s) => typeof s.doneAt === "number");
    expect(await status(me)).toMatchObject({ queued: 0 });
  });

  it("destroys the rooms a person made and redacts them from everyone else's", async () => {
    const me = person();
    const other = person();
    devStore.users.set(`${me}@rooms.test`, me);
    const call = async (id: string, path: string, userId: string, body?: unknown, query = "") => {
      const res = await stub(env.ROOM_ACTORS, `room1/${id}`).fetch(`https://room${path}?room=${id}${query}`, {
        method: body === undefined ? "GET" : "POST",
        headers: { [USER]: userId, [ORG]: `user-${userId}` },
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
      });
      return { status: res.status, body: (await res.json()) as Record<string, unknown> };
    };
    const mine = newRoomId();
    const theirs = newRoomId();
    const ana = { member: "ana", device: "mac", memberKind: "graff" };
    const ben = { member: "ben", device: "pc", memberKind: "graff" };
    expect((await call(mine, "/create", me, { name: "Mine", ...ana })).status).toBe(201);
    expect((await call(theirs, "/create", other, { name: "Theirs", ...ben })).status).toBe(201);
    expect((await call(theirs, "/invite", other, { email: `${me}@rooms.test` })).status).toBe(200);
    expect((await call(theirs, "/accept", me, {})).status).toBe(200);
    expect((await call(theirs, "/join", me, ana)).status).toBe(200);
    expect((await call(theirs, "/post", me, { ...ana, body: "my notes, @ben" })).status).toBe(200);
    expect((await call(theirs, "/post", other, { ...ben, body: "their notes" })).status).toBe(200);

    await start(me);
    await drain(me, (s) => s.pass === 2);

    expect((await call(mine, "/state", me)).body.error).toBe("room_destroyed");
    expect((await call(theirs, "/state", me)).status).toBe(404);
    const read = await call(theirs, "/messages", other, undefined, "&member=ben&device=pc");
    expect(read.status, JSON.stringify(read.body)).toBe(200);
    const messages = read.body.messages as { senderUserId: string; body: string; mentions: string[] }[];
    expect(messages.find((m) => m.senderUserId === me)).toMatchObject({ body: FORGOTTEN_BODY, mentions: [] });
    expect(messages.find((m) => m.senderUserId === other)?.body).toBe("their notes");
  });
});

describe("POST /auth/account/delete", () => {
  afterEach(() => vi.restoreAllMocks());

  /** CodeGraff: the token endpoint, then the delete endpoint's answers in order. */
  const codegraff = (answers: { status: number; body: unknown }[]) => {
    const calls: { url: string; body: unknown }[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input instanceof Request ? input.url : input);
      if (url.endsWith("/api/oauth/token")) {
        return Response.json({ access_token: "cg_at_test", refresh_token: "cg_rt_rotated" });
      }
      calls.push({ url, body: JSON.parse(String(init?.body ?? "{}")) });
      const next = answers.shift() ?? { status: 500, body: {} };
      return Response.json(next.body, { status: next.status });
    });
    return calls;
  };

  const request = async (userId: string, body: Record<string, unknown>, credentialUser = userId) =>
    deleteAccount(
      new Request("https://edge/auth/account/delete", {
        method: "POST",
        headers: { authorization: `Bearer ${userId}@user-${userId}` },
        body: JSON.stringify({
          refreshToken: await issueRefreshCredential(env, credentialUser, "cg_rt_original"),
          ...body
        })
      }),
      env
    );

  it("wants the word, and both credentials from the same person", async () => {
    const me = person();
    codegraff([]);
    expect((await request(me, {})).status).toBe(400);
    expect((await request(me, { confirm: "delete" }, person())).status).toBe(403);
  });

  it("stops before touching anything when CodeGraff says no, and hands back the rotated tokens", async () => {
    const me = person();
    const calls = codegraff([{ status: 409, body: { error: "active_subscription", message: "Cancel your plan first." } }]);
    const res = await request(me, { confirm: "delete" });
    expect(res.status).toBe(409);
    const body = (await res.json()) as { error: string; message: string; tokens: { refreshToken: string } };
    expect(body).toMatchObject({ error: "active_subscription", message: "Cancel your plan first." });
    expect(body.tokens.refreshToken).toMatch(/^harness_rt_/);
    expect(calls).toEqual([{ url: "https://codegraff.com/api/account/delete", body: { confirm: "delete", dryRun: true } }]);
    expect(await status(me)).toEqual({ status: "none" });
  });

  it("says the feature isn't there yet while CodeGraff has no endpoint", async () => {
    const me = person();
    codegraff([{ status: 404, body: {} }]);
    expect((await request(me, { confirm: "delete" })).status).toBe(501);
  });

  it("deletes at CodeGraff after the dry run, then starts the purge", async () => {
    const me = person();
    const calls = codegraff([
      { status: 200, body: { deletable: true } },
      { status: 200, body: { deleted: true, appleRevoked: null } }
    ]);
    const res = await request(me, { confirm: "delete" });
    expect(res.status, await res.clone().text()).toBe(200);
    expect(await res.json()).toEqual({ deleted: true });
    expect(calls.map((c) => c.body)).toEqual([{ confirm: "delete", dryRun: true }, { confirm: "delete" }]);
    expect(await status(me)).toMatchObject({ pass: 1 });
  });
});
