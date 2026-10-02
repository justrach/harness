/**
 * RefreshLeeway — one Durable Object per account (`refresh1/{userId}`).
 *
 * CodeGraff's refresh tokens are single-use: the moment a refresh succeeds the old token is dead, and
 * presenting it again revokes the whole family. A phone suspended or dropped between our answer and its
 * Keychain write would be left holding a dead credential for good: "not connecting" until it signs in
 * again. Here a repeat of a request that already succeeded gets the same result back instead of a
 * second rotation, for LEEWAY_MS. Requests for the same credential that arrive while the first is still
 * with CodeGraff share its outcome, so the rotation happens exactly once.
 *
 * Only the successor credential is kept, and it is the same encrypted `harness_rt_` value the device
 * would have received. Nothing here outlives the window and the object is only reachable through the
 * Worker, which has already checked the presented credential belongs to this account.
 */
import { issueToken } from "./auth";
import { CodegraffAuthFailed, refresh } from "./codegraff";
import type { Env } from "./env";

export const LEEWAY_MS = 2 * 60 * 1000;
/** Rotations remembered at once (a person's devices each hold their own credential). */
const MAX_REMEMBERED = 16;

interface Remembered {
  successor: string;
  at: number;
}

interface Body {
  userId?: unknown;
  refreshToken?: unknown;
  organizationId?: unknown;
}

const json = (value: unknown, status = 200): Response =>
  new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" }
  });

const digest = async (value: string): Promise<string> => {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
};

export class RefreshLeeway implements DurableObject {
  private readonly inflight = new Map<string, Promise<{ accessToken: string; refreshToken: string }>>();

  constructor(
    private readonly ctx: DurableObjectState,
    private readonly env: Env
  ) {}

  async fetch(request: Request): Promise<Response> {
    if (new URL(request.url).pathname !== "/refresh" || request.method !== "POST") {
      return json({ error: "not_found" }, 404);
    }
    const body = (await request.json().catch(() => null)) as Body | null;
    if (typeof body?.userId !== "string" || typeof body.refreshToken !== "string") {
      return json({ error: "bad request" }, 400);
    }
    const organizationId = typeof body.organizationId === "string" ? body.organizationId : undefined;
    const key = await digest(body.refreshToken);
    try {
      const joined = this.inflight.get(key);
      if (joined) return json(await joined);

      const replay = await this.ctx.storage.get<Remembered>(`r:${key}`);
      if (replay && Date.now() - replay.at < LEEWAY_MS) {
        return json({ accessToken: await issueToken(this.env, body.userId), refreshToken: replay.successor });
      }

      const rotation = refresh(this.env, body.refreshToken, organizationId);
      this.inflight.set(key, rotation);
      try {
        const result = await rotation;
        await this.remember(key, result.refreshToken);
        return json(result);
      } finally {
        this.inflight.delete(key);
      }
    } catch (e) {
      if (e instanceof CodegraffAuthFailed) return json({ error: e.message }, 401);
      console.warn("auth/refresh leeway failed", String(e));
      return json({ error: "refresh is temporarily unavailable", retryable: true }, 503);
    }
  }

  private async remember(key: string, successor: string): Promise<void> {
    const now = Date.now();
    const kept = await this.ctx.storage.list<Remembered>({ prefix: "r:" });
    const stale = [...kept].filter(([, v]) => now - v.at >= LEEWAY_MS).map(([k]) => k);
    const live = [...kept].filter(([, v]) => now - v.at < LEEWAY_MS).sort((a, b) => a[1].at - b[1].at);
    const overflow = live.slice(0, Math.max(0, live.length - (MAX_REMEMBERED - 1))).map(([k]) => k);
    const drop = [...stale, ...overflow];
    if (drop.length) await this.ctx.storage.delete(drop);
    await this.ctx.storage.put(`r:${key}`, { successor, at: now } satisfies Remembered);
  }
}
