import { describe, expect, it } from "vitest";
import { requestGraffKey } from "./codegraff";

const KEY = `cg_sk_${"a".repeat(48)}`;

const codegraff = (reply: () => Response | Promise<Response>) => {
  const calls: { url: string; auth: string | null; body: unknown }[] = [];
  const impl = (async (url: string, init: RequestInit) => {
    calls.push({
      url: String(url),
      auth: new Headers(init?.headers).get("authorization"),
      body: JSON.parse(String(init?.body ?? "null"))
    });
    return reply();
  }) as unknown as typeof fetch;
  return { calls, impl };
};

describe("requestGraffKey", () => {
  it("asks codegraff.com with this sign-in's access token and returns the key", async () => {
    const cg = codegraff(() => Response.json({ api_key: KEY, email: "u@example.com" }));
    const got = await requestGraffKey("cg_at_fresh", { deviceLabel: "Mac Studio" }, cg.impl);
    expect(got).toEqual({ apiKey: KEY, email: "u@example.com" });
    expect(cg.calls).toEqual([
      {
        url: "https://codegraff.com/api/oauth/graff-key",
        auth: "Bearer cg_at_fresh",
        body: { device_label: "Mac Studio" }
      }
    ]);
  });

  it("never fails the sign-in: refusals, junk and outages give no key", async () => {
    for (const reply of [
      () => new Response("{}", { status: 403 }),
      () => new Response("{}", { status: 503 }),
      () => Response.json({ api_key: "not-a-key", email: "u@example.com" }),
      () => Response.json({ api_key: KEY }),
      () => new Response("<html>", { status: 200 }),
      () => Promise.reject(new Error("offline"))
    ]) {
      expect(await requestGraffKey("cg_at_fresh", {}, codegraff(reply).impl)).toBeUndefined();
    }
  });

  it("bounds the device label it forwards", async () => {
    const cg = codegraff(() => Response.json({ api_key: KEY, email: "u@example.com" }));
    await requestGraffKey("cg_at_fresh", { deviceLabel: "x".repeat(500) }, cg.impl);
    expect((cg.calls[0].body as { device_label: string }).device_label).toHaveLength(80);
  });
});
