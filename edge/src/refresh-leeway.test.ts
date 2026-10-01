import { afterEach, describe, expect, it, vi } from "vitest";
import { issueRefreshCredential, verifyToken } from "./auth";
import { handleAuthRoute } from "./auth-routes";
import type { Env } from "./env";
import { LEEWAY_MS, RefreshLeeway } from "./refresh-leeway";

const baseEnv = {
  HARNESS_AUTH_SIGNING_KEY: "k".repeat(48),
  CODEGRAFF_OAUTH_CLIENT_ID: "client",
  AUTH_MODE: "codegraff"
} as Env;

class FakeStorage {
  data = new Map<string, unknown>();
  async get<T>(key: string) { return this.data.get(key) as T | undefined; }
  async put(key: string, value: unknown) { this.data.set(key, value); }
  async delete(keys: string | string[]) { for (const k of [keys].flat()) this.data.delete(k); }
  async list<T>({ prefix }: { prefix: string }) {
    return new Map([...this.data].filter(([k]) => k.startsWith(prefix))) as Map<string, T>;
  }
}

/** CodeGraff's token endpoint: single-use refresh tokens that rotate, like the real one. */
const codegraff = () => {
  const live = new Set<string>(["cg_rt_1"]);
  let n = 1;
  const state = { calls: 0, status: 200, delay: 0 };
  const impl = vi.fn(async (_url: unknown, init: RequestInit) => {
    state.calls++;
    if (state.delay) await new Promise((r) => setTimeout(r, state.delay));
    if (state.status !== 200) return new Response("{}", { status: state.status });
    const presented = new URLSearchParams(String(init.body)).get("refresh_token") ?? "";
    if (!live.delete(presented)) return new Response("{}", { status: 400 });
    const next = `cg_rt_${++n}`;
    live.add(next);
    return Response.json({ access_token: "a", refresh_token: next });
  });
  vi.stubGlobal("fetch", impl);
  return state;
};

const leeway = () => new RefreshLeeway({ storage: new FakeStorage() } as unknown as DurableObjectState, baseEnv);
const ask = (room: RefreshLeeway, refreshToken: string, userId = "42") =>
  room.fetch(new Request("https://refresh-leeway/refresh", {
    method: "POST",
    body: JSON.stringify({ userId, refreshToken })
  }));

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe("refresh leeway", () => {
  it("rotates once, and a repeat of the same request gets the same result", async () => {
    const upstream = codegraff();
    const room = leeway();
    const credential = await issueRefreshCredential(baseEnv, "42", "cg_rt_1");

    const first = await ask(room, credential);
    expect(first.status).toBe(200);
    const a = (await first.json()) as { accessToken: string; refreshToken: string };

    // The phone never saw `a` and asks again with the credential it still holds.
    const second = await ask(room, credential);
    expect(second.status).toBe(200);
    const b = (await second.json()) as { accessToken: string; refreshToken: string };

    expect(upstream.calls).toBe(1);
    expect(b.refreshToken).toBe(a.refreshToken);
    expect(await verifyToken(baseEnv, b.accessToken)).toEqual({ userId: "42", orgId: "user-42" });
  });

  it("lets the successor refresh as usual afterwards", async () => {
    const upstream = codegraff();
    const room = leeway();
    const first = (await (await ask(room, await issueRefreshCredential(baseEnv, "42", "cg_rt_1"))).json()) as {
      refreshToken: string;
    };
    const next = await ask(room, first.refreshToken);
    expect(next.status).toBe(200);
    expect(upstream.calls).toBe(2);
  });

  it("shares one rotation between requests that overlap", async () => {
    const upstream = codegraff();
    upstream.delay = 20;
    const room = leeway();
    const credential = await issueRefreshCredential(baseEnv, "42", "cg_rt_1");
    const [x, y] = await Promise.all([ask(room, credential), ask(room, credential)]);
    expect(x.status).toBe(200);
    expect(y.status).toBe(200);
    expect(upstream.calls).toBe(1);
    expect(((await x.json()) as { refreshToken: string }).refreshToken).toBe(
      ((await y.json()) as { refreshToken: string }).refreshToken
    );
  });

  it("stops answering a repeat once the leeway has passed", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    const upstream = codegraff();
    const room = leeway();
    const credential = await issueRefreshCredential(baseEnv, "42", "cg_rt_1");
    expect((await ask(room, credential)).status).toBe(200);
    vi.setSystemTime(Date.now() + LEEWAY_MS + 1000);
    const late = await ask(room, credential);
    expect(late.status).toBe(401); // CodeGraff refuses the dead token; no cached stand-in
    expect(upstream.calls).toBe(2);
  });

  it("tells a rejected credential (401) from CodeGraff being down (503)", async () => {
    const upstream = codegraff();
    const room = leeway();
    const credential = await issueRefreshCredential(baseEnv, "42", "cg_rt_1");

    upstream.status = 503;
    const down = await ask(room, credential);
    expect(down.status).toBe(503);
    expect(((await down.json()) as { retryable?: boolean }).retryable).toBe(true);

    upstream.status = 429;
    expect((await ask(room, credential)).status).toBe(503);

    upstream.status = 400;
    expect((await ask(room, credential)).status).toBe(401);
  });

  it("treats a network failure as retryable, not as a rejection", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new TypeError("network"); }));
    const credential = await issueRefreshCredential(baseEnv, "42", "cg_rt_1");
    expect((await ask(leeway(), credential)).status).toBe(503);
  });

  it("is not reachable for a credential that is not the account's own (route level)", async () => {
    const upstream = codegraff();
    const credential = await issueRefreshCredential(baseEnv, "42", "cg_rt_1");
    const room = leeway();
    const env = {
      ...baseEnv,
      REFRESH_LEEWAY: {
        idFromName: (name: string) => name,
        get: () => ({ fetch: (url: string, init: RequestInit) => room.fetch(new Request(url, init)) })
      }
    } as unknown as Env;
    const call = (organizationId: string) =>
      handleAuthRoute(
        new Request("https://edge/auth/refresh", {
          method: "POST",
          body: JSON.stringify({ refreshToken: credential, organizationId })
        }),
        env,
        new URL("https://edge/auth/refresh")
      );
    expect((await call("user-7"))?.status).toBe(401);
    expect(upstream.calls).toBe(0);
    expect((await call("user-42"))?.status).toBe(200);
    expect(upstream.calls).toBe(1);
  });

  it("answers 503 at the route when the leeway object itself is broken", async () => {
    const credential = await issueRefreshCredential(baseEnv, "42", "cg_rt_1");
    const env = {
      ...baseEnv,
      REFRESH_LEEWAY: { idFromName: (n: string) => n, get: () => ({ fetch: async () => { throw new Error("DO down"); } }) }
    } as unknown as Env;
    const res = await handleAuthRoute(
      new Request("https://edge/auth/refresh", { method: "POST", body: JSON.stringify({ refreshToken: credential }) }),
      env,
      new URL("https://edge/auth/refresh")
    );
    expect(res?.status).toBe(503);
  });
});
