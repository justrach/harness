import { describe, expect, it } from "vitest";
import { readCapped, readJsonCapped, withoutToken } from "./body";

/** A body sent in `chunk`-byte pieces with no declared length, counting what was read. */
const chunked = (total: number, chunk: number) => {
  const pulled = { bytes: 0, cancelled: false };
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (pulled.bytes >= total) return controller.close();
      const size = Math.min(chunk, total - pulled.bytes);
      controller.enqueue(new Uint8Array(size).fill(7));
      pulled.bytes += size;
    },
    cancel() {
      pulled.cancelled = true;
    }
  });
  const request = new Request("https://edge.test/upload", { method: "POST", body, duplex: "half" } as RequestInit);
  return { request, pulled };
};

describe("bounded request bodies", () => {
  it("refuses a body by its declared length without reading it", async () => {
    const { request, pulled } = chunked(1024, 256);
    request.headers.set("content-length", "5000");
    expect(await readCapped(request, 4096)).toBeUndefined();
    expect(pulled.bytes).toBeLessThanOrEqual(256);
    expect(pulled.cancelled).toBe(true);
  });

  it("stops reading an undeclared body once it outgrows the limit", async () => {
    const { request, pulled } = chunked(64 * 1024 * 1024, 64 * 1024);
    expect(await readCapped(request, 1024 * 1024)).toBeUndefined();
    // Nowhere near the 64 MiB on offer.
    expect(pulled.bytes).toBeLessThan(2 * 1024 * 1024);
    expect(pulled.cancelled).toBe(true);
  });

  it("returns exactly the bytes sent, declared or not, up to the limit itself", async () => {
    const exact = chunked(300_000, 4096).request;
    const read = await readCapped(exact, 300_000);
    expect(read?.byteLength).toBe(300_000);
    expect(read?.buffer.byteLength).toBe(300_000);
    expect(read?.every((b) => b === 7)).toBe(true);

    const declared = new Request("https://edge.test/upload", { method: "POST", body: new Uint8Array([1, 2, 3]) });
    expect([...(await readCapped(declared, 3))!]).toEqual([1, 2, 3]);
    expect(await readCapped(new Request("https://edge.test/upload", { method: "POST", body: new Uint8Array(4) }), 3)).toBeUndefined();
    expect((await readCapped(new Request("https://edge.test/read"), 16))?.byteLength).toBe(0);
  });

  it("tells an oversized JSON body from a malformed one", async () => {
    const post = (body: string) => new Request("https://edge.test/json", { method: "POST", body });
    expect(await readJsonCapped(post('{"ids":[1,2]}'), 64)).toEqual({ ok: true, value: { ids: [1, 2] } });
    expect(await readJsonCapped(post("{not json"), 64)).toEqual({ ok: false, error: "bad_json", status: 400 });
    expect(await readJsonCapped(post(JSON.stringify({ pad: "x".repeat(100) })), 64)).toEqual({
      ok: false,
      error: "too_large",
      status: 413
    });
  });

  it("drops only the token from a forwarded query", () => {
    expect(withoutToken("?after=12&device=synthetic")).toBe("?after=12&device=synthetic");
    expect(withoutToken("?token=synthetic-bearer&after=12&device=synthetic")).toBe("?after=12&device=synthetic");
    expect(withoutToken("?token=synthetic-bearer")).toBe("");
    expect(withoutToken("")).toBe("");
  });
});
