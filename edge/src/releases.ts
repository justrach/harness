/**
 * Release artifacts (`GET|HEAD /releases/*`): what the `curl | sh` installer
 * downloads, served from the `harness-releases` bucket. The route is public,
 * so a path is checked before the bucket sees it.
 */
import type { Env } from "./env";

/** R2's limit on an object key, in bytes. */
const MAX_KEY_BYTES = 1024;

const json = (value: unknown, status = 200): Response =>
  new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" }
  });

/** The bucket key a `/releases/…` path names. Undefined for a path that names
 * none: a malformed %-escape (which `decodeURIComponent` throws on), an empty
 * key, one with `..`, or one longer than the bucket takes. */
export const releaseKey = (pathname: string): string | undefined => {
  let key: string;
  try {
    key = decodeURIComponent(pathname.slice("/releases/".length));
  } catch {
    return undefined;
  }
  if (key.length === 0 || key.includes("..")) return undefined;
  if (new TextEncoder().encode(key).length > MAX_KEY_BYTES) return undefined;
  return key;
};

/** `GET|HEAD /releases/*`; undefined for any other request. */
export const releaseRoute = async (
  request: Request,
  env: Pick<Env, "RELEASES">,
  url: URL,
  parts: string[]
): Promise<Response | undefined> => {
  if (parts[0] !== "releases" || parts.length < 2) return undefined;
  if (request.method !== "GET" && request.method !== "HEAD") return undefined;
  const key = releaseKey(url.pathname);
  if (key === undefined) return json({ error: "bad request" }, 400);
  const object = await env.RELEASES.get(key);
  if (!object) return json({ error: "not_found" }, 404);
  // latest.txt / manifest.json flip on release; artifacts are immutable by name.
  const mutable = key.endsWith(".txt") || key.endsWith(".json");
  const headers = new Headers({
    "content-type": key.endsWith(".txt")
      ? "text/plain; charset=utf-8"
      : key.endsWith(".json")
        ? "application/json"
        : "application/octet-stream",
    "content-length": String(object.size),
    "cache-control": mutable ? "public, max-age=60" : "public, max-age=86400, immutable",
    etag: object.httpEtag
  });
  return new Response(request.method === "HEAD" ? null : object.body, { headers });
};
