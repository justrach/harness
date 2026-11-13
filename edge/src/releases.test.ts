import { describe, expect, it } from "vitest";
import { releaseKey, releaseRoute } from "./releases";

/** A bucket holding made-up artifacts, recording the keys it was asked for. */
const bucket = (objects: Record<string, string>) => {
  const asked: string[] = [];
  const RELEASES = {
    async get(key: string) {
      asked.push(key);
      const text = objects[key];
      if (text === undefined) return null;
      const bytes = new TextEncoder().encode(text);
      return { size: bytes.length, httpEtag: `"etag-${key}"`, body: new Blob([bytes]).stream() };
    }
  } as unknown as R2Bucket;
  return { env: { RELEASES }, asked };
};

const ask = (env: { RELEASES: R2Bucket }, path: string, method = "GET") => {
  const url = new URL(`https://edge.test${path}`);
  return releaseRoute(new Request(url, { method }), env, url, url.pathname.split("/").filter(Boolean));
};

describe("release artifacts", () => {
  it("answers 400 for a malformed %-escape instead of throwing", async () => {
    const { env, asked } = bucket({});
    for (const path of ["/releases/%", "/releases/%E0%A4%A", "/releases/harness-%ZZ.tar.gz"]) {
      expect(releaseKey(path)).toBeUndefined();
      const res = await ask(env, path);
      expect(res?.status).toBe(400);
    }
    expect(asked).toEqual([]);
  });

  it("never asks the bucket for an empty, traversing or over-long key", async () => {
    const { env, asked } = bucket({});
    // The URL parser folds real `..` segments away before the route runs;
    // these are the ones that survive it.
    for (const path of ["/releases/x%2F..%2Fy", "/releases/a..b", `/releases/${"a".repeat(1025)}`]) {
      const res = await ask(env, path);
      expect(res?.status).toBe(400);
    }
    expect(asked).toEqual([]);
    expect(releaseKey(`/releases/${"a".repeat(1024)}`)).toBe("a".repeat(1024));
  });

  it("serves an artifact by its decoded key, and 404s one that isn't there", async () => {
    const { env, asked } = bucket({ "latest.txt": "0.2.183\n", "harness 0.2.183.dmg": "synthetic" });
    const latest = await ask(env, "/releases/latest.txt");
    expect(latest?.status).toBe(200);
    expect(latest?.headers.get("content-type")).toBe("text/plain; charset=utf-8");
    expect(latest?.headers.get("cache-control")).toBe("public, max-age=60");
    expect(await latest?.text()).toBe("0.2.183\n");

    const dmg = await ask(env, "/releases/harness%200.2.183.dmg", "HEAD");
    expect(dmg?.status).toBe(200);
    expect(dmg?.headers.get("cache-control")).toBe("public, max-age=86400, immutable");
    expect(dmg?.headers.get("content-length")).toBe("9");
    expect(await dmg?.text()).toBe("");

    expect((await ask(env, "/releases/missing.tar.gz"))?.status).toBe(404);
    expect(asked).toEqual(["latest.txt", "harness 0.2.183.dmg", "missing.tar.gz"]);
  });

  it("leaves other paths and methods to the rest of the Worker", async () => {
    const { env } = bucket({});
    expect(await ask(env, "/releases")).toBeUndefined();
    expect(await ask(env, "/health")).toBeUndefined();
    expect(await ask(env, "/releases/latest.txt", "POST")).toBeUndefined();
  });
});
