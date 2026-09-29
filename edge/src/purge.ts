/**
 * Account deletion's per-object wipe. Every Durable Object that holds a
 * person's data answers `POST /purge` with the person stamped in
 * AUTH_USER_HEADER. The Worker never forwards that path from outside (every
 * forward names its own path; the vault's pass-through paths all start with
 * `/vault`), so only the account purge job (account-purge.ts) reaches it.
 *
 * Objects named by a client-minted id (chat, session and device rooms) wipe
 * only when the person owns them: the ids come from the person's own
 * registry, which they can write, so an unchecked wipe would let someone list
 * another person's chat and delete it along with their own account.
 */
import { AUTH_USER_HEADER } from "./env";

export const PURGE_PATH = "/purge";

/** Close code a purged object's sockets see. */
export const PURGED_CLOSE = 4410;

export const isPurge = (request: Request, url: URL): boolean =>
  url.pathname === PURGE_PATH && request.method === "POST";

export const purgeJson = (value: unknown, status = 200): Response =>
  new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });

/** The person being deleted, or undefined when the stamp is missing. */
export const purgeUser = (request: Request): string | undefined => request.headers.get(AUTH_USER_HEADER) || undefined;

/**
 * Drop every socket, the alarm and all storage, then make the empty tables
 * again with `schema`: the object stays in memory and must answer its next
 * request from empty, not from a missing table.
 */
export const wipeObject = async (ctx: DurableObjectState, schema: () => void): Promise<void> => {
  for (const ws of ctx.getWebSockets()) {
    try {
      ws.close(PURGED_CLOSE, "account deleted");
    } catch {
      /* already gone */
    }
  }
  await ctx.storage.deleteAlarm();
  await ctx.storage.deleteAll();
  schema();
};
