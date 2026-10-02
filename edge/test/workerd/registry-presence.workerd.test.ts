import { env } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AUTH_USER_HEADER } from "../../src/env";
import { PRESENCE_FRESH_MS } from "../../src/registry-presence";

function room() { return env.REGISTRY_ROOMS.get(env.REGISTRY_ROOMS.idFromName(crypto.randomUUID())); }
async function pull(stub: DurableObjectStub, query = "") {
  const response = await stub.fetch(`https://registry/rows${query}`, { headers: { [AUTH_USER_HEADER]: "user" } });
  expect(response.status).toBe(200);
  return (await response.json<{ presence: Record<string, number> }>()).presence;
}

afterEach(() => vi.useRealTimers());

describe("registry presence handed to a joining client", () => {
  it("includes a host that just beat", async () => {
    const stub = room();
    await pull(stub, "?device=desktop&beat=1");
    expect(Object.keys(await pull(stub))).toEqual(["desktop"]);
  });

  it("leaves out a host whose beats stopped, so a phone never reads it as live", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(1_000_000);
    const stub = room();
    await pull(stub, "?device=desktop&beat=1");
    vi.setSystemTime(1_000_000 + PRESENCE_FRESH_MS - 1);
    expect(Object.keys(await pull(stub))).toEqual(["desktop"]);
    vi.setSystemTime(1_000_000 + PRESENCE_FRESH_MS + 1);
    expect(await pull(stub)).toEqual({});
  });
});
