import { env } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { issueRefreshCredential } from "../../src/auth";
import { handleAuthRoute } from "../../src/auth-routes";

/** CodeGraff's token endpoint: single-use refresh tokens that rotate. */
const codegraff = () => {
  const live = new Set(["cg_rt_1"]);
  let n = 1;
  const state = { calls: 0 };
  vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
    state.calls++;
    const presented = new URLSearchParams(String(init?.body)).get("refresh_token") ?? "";
    if (!live.delete(presented)) return new Response("{}", { status: 400 });
    live.add(`cg_rt_${++n}`);
    return Response.json({ access_token: "a", refresh_token: `cg_rt_${n}` });
  });
  return state;
};

const refresh = (refreshToken: string) =>
  handleAuthRoute(
    new Request("https://edge/auth/refresh", { method: "POST", body: JSON.stringify({ refreshToken }) }),
    env,
    new URL("https://edge/auth/refresh")
  );

afterEach(() => vi.restoreAllMocks());

describe("refresh leeway on the real Durable Object", () => {
  it("answers a repeat of a served refresh with the same successor, spending CodeGraff's token once", async () => {
    const upstream = codegraff();
    const user = `u${crypto.randomUUID()}`;
    const credential = await issueRefreshCredential(env, user, "cg_rt_1");

    const first = await refresh(credential);
    expect(first?.status).toBe(200);
    const a = (await first!.json()) as { accessToken: string; refreshToken: string };

    // The phone was suspended before it could store `a`; it asks again with what it still holds.
    const again = await refresh(credential);
    expect(again?.status).toBe(200);
    const b = (await again!.json()) as { accessToken: string; refreshToken: string };
    expect(b.refreshToken).toBe(a.refreshToken);
    expect(upstream.calls).toBe(1);

    // And the successor keeps working.
    expect((await refresh(a.refreshToken))?.status).toBe(200);
    expect(upstream.calls).toBe(2);
  });

  it("does not turn CodeGraff's refusal into a cached success", async () => {
    codegraff();
    const credential = await issueRefreshCredential(env, `u${crypto.randomUUID()}`, "cg_rt_unknown");
    expect((await refresh(credential))?.status).toBe(401);
    expect((await refresh(credential))?.status).toBe(401);
  });
});
