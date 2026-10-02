import { afterEach, describe, expect, it, vi } from "vitest";
import { handleAuthRoute } from "./auth-routes";
import { verifyToken } from "./auth";
import { sandboxExchange } from "./codegraff";
import type { Env } from "./env";

const env = {
  HARNESS_AUTH_SIGNING_KEY: "k".repeat(48),
  CODEGRAFF_OAUTH_CLIENT_ID: "client",
  AUTH_MODE: "codegraff"
} as Env;
const TOKEN = `cg_lt_${"a".repeat(48)}`;

const gateway = (reply: (url: string, init: RequestInit) => Response) => {
  const calls: { url: string; auth: string | null }[] = [];
  const impl = (async (url: string, init: RequestInit) => {
    calls.push({ url: String(url), auth: new Headers(init?.headers).get("authorization") });
    return reply(String(url), init);
  }) as unknown as typeof fetch;
  return { calls, impl };
};

afterEach(() => vi.unstubAllGlobals());

describe("sandbox sign-in", () => {
  it("turns the gateway's answer into a Harness access token for that user", async () => {
    const g = gateway(() => Response.json({ user_id: 42, email: "a@b.test", sandbox_id: "cnd_x" }));
    const out = await sandboxExchange(env, TOKEN, g.impl);
    expect(out.user).toEqual({ id: "42", email: "a@b.test" });
    expect(out.orgId).toBe("user-42");
    expect(await verifyToken(env, out.accessToken)).toEqual({ userId: "42", orgId: "user-42" });
    expect(g.calls).toEqual([{ url: "https://gateway.codegraff.com/v1/harness/identity", auth: `Bearer ${TOKEN}` }]);
  });

  it("does not call the gateway for anything that is not a sandbox token", async () => {
    const g = gateway(() => Response.json({ user_id: 1, email: "x@y.test" }));
    for (const bad of ["", "cg_sk_" + "a".repeat(48), "cg_lt_short", `${TOKEN}x`, "../etc"]) {
      await expect(sandboxExchange(env, bad, g.impl)).rejects.toThrow();
    }
    expect(g.calls).toHaveLength(0);
  });

  it("refuses when the gateway refuses, and when its answer is incomplete", async () => {
    await expect(sandboxExchange(env, TOKEN, gateway(() => new Response("no", { status: 401 })).impl)).rejects.toThrow(/401/);
    for (const body of [{}, { user_id: "42", email: "a@b.test" }, { user_id: 0, email: "a@b.test" }, { user_id: 5, email: "" }]) {
      await expect(sandboxExchange(env, TOKEN, gateway(() => Response.json(body)).impl)).rejects.toThrow();
    }
  });

  it("uses the configured gateway", async () => {
    const g = gateway(() => Response.json({ user_id: 3, email: "c@d.test" }));
    await sandboxExchange({ ...env, CODEGRAFF_GATEWAY_URL: "http://127.0.0.1:9/" } as Env, TOKEN, g.impl);
    expect(g.calls[0].url).toBe("http://127.0.0.1:9/v1/harness/identity");
  });

  it("POST /auth/sandbox answers 200 with a token, 400 without one, 401 when refused", async () => {
    const post = (body: unknown) =>
      handleAuthRoute(
        new Request("https://edge.codegraff.com/auth/sandbox", { method: "POST", body: JSON.stringify(body) }),
        env,
        new URL("https://edge.codegraff.com/auth/sandbox")
      );
    vi.stubGlobal("fetch", gateway(() => Response.json({ user_id: 7, email: "e@f.test" })).impl);
    const ok = await post({ token: TOKEN });
    expect(ok?.status).toBe(200);
    expect(((await ok!.json()) as { user: { id: string } }).user.id).toBe("7");
    expect((await post({}))?.status).toBe(400);
    expect((await post({ token: 5 }))?.status).toBe(400);
    vi.stubGlobal("fetch", gateway(() => new Response("no", { status: 401 })).impl);
    expect((await post({ token: TOKEN }))?.status).toBe(401);
    // a GET is not a sign-in
    const get = await handleAuthRoute(
      new Request("https://edge.codegraff.com/auth/sandbox"),
      env,
      new URL("https://edge.codegraff.com/auth/sandbox")
    );
    expect(get).toBeUndefined();
  });

  it("POST /auth/refresh takes the sandbox token as its refresh token and hands the same one back", async () => {
    vi.stubGlobal("fetch", gateway(() => Response.json({ user_id: 7, email: "e@f.test" })).impl);
    const res = await handleAuthRoute(
      new Request("https://edge.codegraff.com/auth/refresh", {
        method: "POST",
        body: JSON.stringify({ refreshToken: TOKEN })
      }),
      env,
      new URL("https://edge.codegraff.com/auth/refresh")
    );
    expect(res?.status).toBe(200);
    const body = (await res!.json()) as { accessToken: string; refreshToken: string };
    expect(body.refreshToken).toBe(TOKEN);
    expect(await verifyToken(env, body.accessToken)).toEqual({ userId: "7", orgId: "user-7" });
    vi.stubGlobal("fetch", gateway(() => new Response("no", { status: 401 })).impl);
    const gone = await handleAuthRoute(
      new Request("https://edge.codegraff.com/auth/refresh", {
        method: "POST",
        body: JSON.stringify({ refreshToken: TOKEN })
      }),
      env,
      new URL("https://edge.codegraff.com/auth/refresh")
    );
    expect(gone?.status).toBe(401);
  });

  it("is not available without the signing secret", async () => {
    const res = await handleAuthRoute(
      new Request("https://edge.codegraff.com/auth/sandbox", { method: "POST", body: JSON.stringify({ token: TOKEN }) }),
      { ...env, HARNESS_AUTH_SIGNING_KEY: undefined } as Env,
      new URL("https://edge.codegraff.com/auth/sandbox")
    );
    expect(res?.status).toBe(501);
  });
});
