/**
 * Request bodies read with a limit. `request.arrayBuffer()` and
 * `request.json()` take whatever is sent before a size check can run; these
 * refuse a body by its declared length, and stop reading one that outgrows
 * the limit, so no route holds more than it accepts.
 */

/** The body, or undefined when it is larger than `max` bytes. What is left of
 * a refused body is cancelled, not left dangling on the connection. */
export const readCapped = async (request: Request, max: number): Promise<Uint8Array | undefined> => {
  const declared = Number(request.headers.get("content-length") ?? 0);
  const stream = request.body;
  if (declared > max) {
    await stream?.cancel().catch(() => {});
    return undefined;
  }
  if (!stream) return new Uint8Array(0);
  const reader = stream.getReader();
  // A declared length is taken whole (no second copy of a large checkpoint);
  // an undeclared body grows from 64 KiB, never past the limit.
  let out = new Uint8Array(Math.min(max, declared > 0 ? declared : 64 * 1024));
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (total + value.byteLength > max) {
      await reader.cancel().catch(() => {});
      return undefined;
    }
    if (total + value.byteLength > out.length) {
      const grown = new Uint8Array(Math.min(max, Math.max(out.length * 2, total + value.byteLength)));
      grown.set(out.subarray(0, total));
      out = grown;
    }
    out.set(value, total);
    total += value.byteLength;
  }
  return total === out.length ? out : out.slice(0, total);
};

export type JsonBody =
  | { ok: true; value: unknown }
  | { ok: false; error: "too_large"; status: 413 }
  | { ok: false; error: "bad_json"; status: 400 };

/** A JSON body no larger than `max` bytes. */
export const readJsonCapped = async (request: Request, max: number): Promise<JsonBody> => {
  const bytes = await readCapped(request, max);
  if (!bytes) return { ok: false, error: "too_large", status: 413 };
  try {
    return { ok: true, value: JSON.parse(new TextDecoder().decode(bytes)) };
  } catch {
    return { ok: false, error: "bad_json", status: 400 };
  }
};

/** A query string without the caller's `?token=`: a room is handed the
 * verified user in a header, and its URL reaches request logs. */
export const withoutToken = (search: string): string => {
  const params = new URLSearchParams(search);
  if (!params.has("token")) return search;
  params.delete("token");
  const rest = params.toString();
  return rest ? `?${rest}` : "";
};
