import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";

const b64u = (bytes: Uint8Array): string =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const random = (n: number): Uint8Array => crypto.getRandomValues(new Uint8Array(n));
const hex = async (bytes: Uint8Array): Promise<string> =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((b) => b.toString(16).padStart(2, "0")).join("");

type Device = { id: string; publicKey: string; signingKey: string; priv: CryptoKey };

const newDevice = async (id: string): Promise<Device> => {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const raw = new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  return { id, publicKey: b64u(random(32)), signingKey: b64u(raw), priv: pair.privateKey };
};

const wrapped = (): string => b64u(random(104));
const room = () => env.VAULT_ROOMS.get(env.VAULT_ROOMS.idFromName(crypto.randomUUID()));
type Room = ReturnType<typeof room>;

const call = (r: Room, method: string, path: string, body?: unknown, headers: Record<string, string> = {}) =>
  r.fetch(`https://test${path}`, {
    method,
    headers: { "x-harness-auth-user": "u1", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body)
  });

const signed = async (
  r: Room, d: Device, method: string, path: string, body?: unknown,
  opts: { ts?: number; headers?: Record<string, string>; tamper?: boolean; reuse?: Record<string, string> } = {}
) => {
  const text = body === undefined ? "" : JSON.stringify(body);
  const ts = opts.ts ?? Date.now();
  const message = `${method}|${path}|${await hex(new TextEncoder().encode(text))}|${ts}|${d.id}`;
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, d.priv, new TextEncoder().encode(message)));
  const auth = opts.reuse ?? { "x-vault-device": d.id, "x-vault-timestamp": String(ts), "x-vault-signature": b64u(sig) };
  const res = await r.fetch(`https://test${path}`, {
    method,
    headers: { "x-harness-auth-user": "u1", ...auth, ...(opts.headers ?? {}) },
    body: body === undefined ? undefined : opts.tamper ? text.replace("ok", "needs_signin") : text
  });
  return { res, auth };
};

const register = (r: Room, d: Device, withKey = false) =>
  call(r, "POST", "/vault/devices", {
    deviceId: d.id, name: d.id, publicKey: d.publicKey, signingKey: d.signingKey,
    ...(withKey ? { wrappedKey: wrapped() } : {})
  });

const item = (keyEpoch = 1) => ({ kind: "rotating", status: "ok", nonce: b64u(random(24)), ciphertext: b64u(random(80)), keyEpoch });

const setup = async () => {
  const r = room();
  const a = await newDevice("dev-a");
  const b = await newDevice("dev-b");
  expect((await register(r, a, true)).status).toBe(200);
  expect(await (await register(r, b)).json()).toMatchObject({ status: "pending" });
  const ok = await signed(r, a, "POST", "/vault/devices/dev-b/approve", { wrappedKey: wrapped() });
  expect(ok.res.status).toBe(200);
  return { r, a, b };
};

describe("VaultRoom", () => {
  it("bootstraps, keeps new devices pending until an enrolled device approves", async () => {
    const r = room();
    const a = await newDevice("dev-a");
    expect((await register(r, a)).status).toBe(400); // first device must bring a wrapped key
    expect(await (await register(r, a, true)).json()).toMatchObject({ status: "enrolled" });
    const b = await newDevice("dev-b");
    expect(await (await register(r, b)).json()).toMatchObject({ status: "pending" });
    // A pending device cannot approve itself.
    expect((await signed(r, b, "POST", "/vault/devices/dev-b/approve", { wrappedKey: wrapped() })).res.status).toBe(401);
    expect((await signed(r, a, "POST", "/vault/devices/dev-b/approve", { wrappedKey: wrapped() })).res.status).toBe(200);
    const state = await (await call(r, "GET", "/vault", undefined, { "x-vault-device": "dev-b" })).json<Record<string, unknown>>();
    expect(state).toMatchObject({ userId: "u1", keyEpoch: 1 });
    expect(typeof state.wrappedKey).toBe("string");
  });

  it("refuses re-registering a known device id with different keys", async () => {
    const { r, a } = await setup();
    const impostor = await newDevice("dev-a");
    expect((await register(r, impostor)).status).toBe(409);
    expect(await (await register(r, a)).json()).toMatchObject({ status: "enrolled" });
  });

  it("denies every mutation without a valid, fresh, unreplayed device signature", async () => {
    const { r, a } = await setup();
    const path = "/vault/items/graff/codex";
    expect((await call(r, "PUT", path, item(), { "if-match": "0" })).status).toBe(401);
    expect((await call(r, "POST", "/vault/rotate", { keyEpoch: 2, wrappedKeys: {} })).status).toBe(401);
    expect((await call(r, "DELETE", "/vault/devices/dev-a")).status).toBe(401);
    expect((await signed(r, a, "PUT", path, item(), { headers: { "if-match": "0" }, tamper: true })).res.status).toBe(401);
    expect((await signed(r, a, "PUT", path, item(), { headers: { "if-match": "0" }, ts: Date.now() - 120_000 })).res.status).toBe(401);
    const first = await signed(r, a, "PUT", path, item(), { headers: { "if-match": "0" } });
    expect(first.res.status).toBe(200);
    // Same signature again is a replay.
    const replay = await signed(r, a, "PUT", path, item(), { headers: { "if-match": "1" }, reuse: first.auth });
    expect(replay.res.status).toBe(401);
    const other = await newDevice("dev-z");
    expect((await signed(r, other, "PUT", path, item(), { headers: { "if-match": "1" } })).res.status).toBe(401);
  });

  it("writes are compare-and-swap on If-Match and bound to the current key epoch", async () => {
    const { r, a } = await setup();
    const path = "/vault/items/graff/xai";
    expect(await (await signed(r, a, "PUT", path, item(), { headers: { "if-match": "0" } })).res.json()).toEqual({ version: 1 });
    expect((await signed(r, a, "PUT", path, item(), { headers: { "if-match": "0" } })).res.status).toBe(412);
    expect((await signed(r, a, "PUT", path, item(2), { headers: { "if-match": "1" } })).res.status).toBe(409);
    const got = await (await call(r, "GET", path)).json<Record<string, unknown>>();
    expect(got).toMatchObject({ agent: "graff", slot: "xai", version: 1, keyEpoch: 1, kind: "rotating", status: "ok" });
    expect(typeof got.ciphertext).toBe("string");
  });

  it("a lease blocks other writers, reports the version, and expires", async () => {
    const { r, a, b } = await setup();
    const path = "/vault/items/graff/codex";
    await signed(r, a, "PUT", path, item(), { headers: { "if-match": "0" } });
    const lease = await signed(r, a, "POST", `${path}/lease`, { ttlSeconds: 60 });
    expect(await lease.res.json()).toMatchObject({ leaseHolder: "dev-a", version: 1 });
    expect((await signed(r, b, "POST", `${path}/lease`, { ttlSeconds: 60 })).res.status).toBe(409);
    const blocked = await signed(r, b, "PUT", path, item(), { headers: { "if-match": "1" } });
    expect(blocked.res.status).toBe(409);
    expect(await blocked.res.json()).toMatchObject({ error: "lease_held", leaseHolder: "dev-a" });
    expect((await signed(r, a, "DELETE", `${path}/lease`)).res.status).toBe(200);
    const short = await signed(r, b, "POST", `${path}/lease`, { ttlSeconds: 0.01 });
    expect(short.res.status).toBe(200);
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect((await signed(r, a, "POST", `${path}/lease`, { ttlSeconds: 60 })).res.status).toBe(200);
  });

  it("rotation must cover exactly the enrolled devices and advances the epoch atomically", async () => {
    const { r, a } = await setup();
    expect((await signed(r, a, "POST", "/vault/rotate", { keyEpoch: 2, wrappedKeys: { "dev-a": wrapped() } })).res.status).toBe(400);
    expect((await signed(r, a, "POST", "/vault/rotate", { keyEpoch: 3, wrappedKeys: { "dev-a": wrapped(), "dev-b": wrapped() } })).res.status).toBe(409);
    const ok = await signed(r, a, "POST", "/vault/rotate", { keyEpoch: 2, wrappedKeys: { "dev-a": wrapped(), "dev-b": wrapped() } });
    expect(await ok.res.json()).toEqual({ keyEpoch: 2 });
    expect((await signed(r, a, "PUT", "/vault/items/graff/kimi", item(1), { headers: { "if-match": "0" } })).res.status).toBe(409);
    expect((await signed(r, a, "PUT", "/vault/items/graff/kimi", item(2), { headers: { "if-match": "0" } })).res.status).toBe(200);
  });

  it("a removed device loses its lease, its wrapped key and every write", async () => {
    const { r, a, b } = await setup();
    const path = "/vault/items/graff/codex";
    await signed(r, a, "PUT", path, item(), { headers: { "if-match": "0" } });
    await signed(r, b, "POST", `${path}/lease`, { ttlSeconds: 60 });
    expect((await signed(r, a, "DELETE", "/vault/devices/dev-b")).res.status).toBe(200);
    expect((await signed(r, b, "PUT", path, item(), { headers: { "if-match": "1" } })).res.status).toBe(401);
    expect((await signed(r, a, "PUT", path, item(), { headers: { "if-match": "1" } })).res.status).toBe(200);
    const state = await (await call(r, "GET", "/vault", undefined, { "x-vault-device": "dev-b" })).json<Record<string, unknown>>();
    expect(state.wrappedKey).toBeNull();
  });

  it("status changes are version-guarded and pending registrations are capped", async () => {
    const { r, a } = await setup();
    const path = "/vault/items/graff/xai";
    await signed(r, a, "PUT", path, item(), { headers: { "if-match": "0" } });
    expect((await signed(r, a, "POST", `${path}/status`, { status: "needs_signin", ifVersion: 2 })).res.status).toBe(412);
    expect((await signed(r, a, "POST", `${path}/status`, { status: "needs_signin", ifVersion: 1 })).res.status).toBe(200);
    expect(await (await call(r, "GET", path)).json()).toMatchObject({ status: "needs_signin" });
    for (let i = 0; i < 5; i++) expect((await register(r, await newDevice(`p${i}`))).status).toBe(200);
    expect((await register(r, await newDevice("p5"))).status).toBe(409);
  });
});
