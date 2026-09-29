/**
 * `POST /auth/account/delete` — delete the caller's account, from inside the
 * app (the App Store requires it of apps where an account can be made).
 *
 * The bearer is the caller's Harness access token; the body carries their
 * refresh credential (the only thing that reaches CodeGraff on their behalf)
 * and `confirm: "delete"`. Order matters, because only the CodeGraff step can't
 * be undone and only the steps before it can still be retried by the caller:
 *
 *  1. CodeGraff dry run: a blocker the person must clear first (a paid plan)
 *     comes back as 409 before anything is touched.
 *  2. Agent rooms, through their actors: rooms they made are destroyed, and
 *     in other people's rooms they leave and their posts lose their text. The
 *     actors hold the live copy, so this can't be left to PostgreSQL.
 *  3. CodeGraff deletes the account and revokes every credential it issued.
 *  4. The edge's own copy is wiped by a durable job (account-purge.ts) that
 *     retries itself and runs again after the last access token expires.
 *
 * Until step 3 succeeds, every answer carries the rotated Harness tokens: the
 * CodeGraff refresh token was spent getting an access token, and a device
 * that kept the old credential would be signed out.
 */
import { bearerFromRequest, verifyRefreshCredential, verifyToken } from "./auth";
import { ACCOUNT_DELETE_URL, CodegraffAuthFailed, codegraffAccess } from "./codegraff";
import { AUTH_USER_HEADER, type Env } from "./env";
import { AUTH_ORG_HEADER, roomStore } from "./room-actor";

const json = (value: unknown, status = 200): Response =>
  new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" }
  });

/** CodeGraff's answer, reduced to what the phone can act on. */
type Verdict =
  | { ok: true }
  | { ok: false; status: number; error: string; message?: string };

const askCodegraff = async (accessToken: string, dryRun: boolean): Promise<Verdict> => {
  let res: Response;
  try {
    res = await fetch(ACCOUNT_DELETE_URL, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify(dryRun ? { confirm: "delete", dryRun: true } : { confirm: "delete" })
    });
  } catch {
    return { ok: false, status: 502, error: "codegraff_unavailable" };
  }
  const body = (await res.json().catch(() => ({}))) as { error?: unknown; message?: unknown; deleted?: unknown; deletable?: unknown };
  if (res.ok && (dryRun ? body.deletable === true : body.deleted === true)) return { ok: true };
  // A blocker the person has to clear, in CodeGraff's words.
  if (res.status === 409) {
    return {
      ok: false,
      status: 409,
      error: typeof body.error === "string" ? body.error : "blocked",
      ...(typeof body.message === "string" ? { message: body.message } : {})
    };
  }
  if (res.status === 404 || res.status === 405) return { ok: false, status: 501, error: "account_deletion_unavailable" };
  if (res.status === 401) return { ok: false, status: 401, error: "signed_out" };
  return { ok: false, status: 502, error: "codegraff_unavailable" };
};

/** Step 2: every room the person is in or invited to forgets them. */
const forgetRooms = async (env: Env, userId: string, orgId: string): Promise<void> => {
  const store = roomStore(env);
  if (!store) return;
  const [rooms, invites] = await Promise.all([store.listRooms(userId), store.invites(userId)]);
  const ids = new Set([...rooms.map((r) => r.id), ...invites.map((i) => i.roomId)]);
  await Promise.all(
    [...ids].map(async (id) => {
      const stub = env.ROOM_ACTORS.get(env.ROOM_ACTORS.idFromName(`room1/${id}`));
      const res = await stub.fetch(`https://room/forget?room=${encodeURIComponent(id)}`, {
        method: "POST",
        headers: { [AUTH_USER_HEADER]: userId, [AUTH_ORG_HEADER]: orgId }
      });
      if (!res.ok) throw new Error(`room forget ${res.status}`);
    })
  );
};

const startPurge = async (env: Env, userId: string, orgId: string): Promise<boolean> => {
  const stub = env.ACCOUNT_PURGE.get(env.ACCOUNT_PURGE.idFromName(`purge1/${userId}`));
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await stub.fetch("https://purge/start", {
        method: "POST",
        body: JSON.stringify({ userId, orgId })
      });
      if (res.ok) return true;
    } catch {
      /* try again */
    }
  }
  return false;
};

export const deleteAccount = async (request: Request, env: Env): Promise<Response> => {
  const bearer = bearerFromRequest(request);
  const caller = bearer ? await verifyToken(env, bearer) : undefined;
  if (!caller) return json({ error: "invalid or missing bearer token" }, 401);

  const body = (await request.json().catch(() => null)) as { refreshToken?: unknown; confirm?: unknown } | null;
  if (body?.confirm !== "delete") return json({ error: "confirm_required" }, 400);
  if (typeof body.refreshToken !== "string") return json({ error: "missing refreshToken" }, 400);
  const credential = await verifyRefreshCredential(env, body.refreshToken);
  if (!credential) return json({ error: "invalid refresh credential" }, 401);
  // Both halves must be the same person: a stolen access token alone can't
  // delete anyone, and neither can a refresh credential alone.
  if (credential.userId !== caller.userId) return json({ error: "wrong_account" }, 403);
  const userId = caller.userId;
  const orgId = caller.orgId ?? `user-${userId}`;

  let access: Awaited<ReturnType<typeof codegraffAccess>>;
  try {
    access = await codegraffAccess(env, userId, credential.codegraffRefreshToken);
  } catch (e) {
    return json({ error: e instanceof CodegraffAuthFailed ? e.message : "authentication failed" }, 401);
  }
  const refused = (v: Extract<Verdict, { ok: false }>) =>
    json({ error: v.error, ...(v.message ? { message: v.message } : {}), tokens: access.tokens }, v.status);

  const check = await askCodegraff(access.codegraffAccessToken, true);
  if (!check.ok) return refused(check);

  try {
    await forgetRooms(env, userId, orgId);
  } catch (err) {
    console.error(JSON.stringify({ event: "account_delete_rooms_failed", error: String(err) }));
    return json({ error: "rooms_unavailable", tokens: access.tokens }, 503);
  }

  const deleted = await askCodegraff(access.codegraffAccessToken, false);
  if (!deleted.ok) return refused(deleted);

  // The account is gone; from here nothing is handed back. A job that fails
  // to start leaves edge data behind with no account to reach it, so say so
  // loudly for an operator to rerun.
  if (!(await startPurge(env, userId, orgId))) {
    console.error(JSON.stringify({ event: "account_purge_unscheduled", userId }));
  }
  return json({ deleted: true });
};
