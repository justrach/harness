export interface Env {
  SESSION_ROOMS: DurableObjectNamespace;
  DEVICE_ROOMS: DurableObjectNamespace;
  PREVIEW_ROOMS: DurableObjectNamespace;
  /** Per-user workspace registries (`reg1/{orgId}/{userId}`) — the row-table
   * replacement for the Loro workspace doc (docs/registry-sync.md). */
  REGISTRY_ROOMS: DurableObjectNamespace;
  /** chat2 session rooms (`chat2/{chatId}`) — dumb authenticated log relays
   * replacing SessionRoom's loro-aware s2 rooms (docs/chat2-sync.md). */
  CHAT_ROOMS: DurableObjectNamespace;
  /** Per-user login vaults (`vault1/{userId}`): encrypted agent logins synced
   * between a person's own devices (docs/adr/0005). */
  VAULT_ROOMS: DurableObjectNamespace;
  /** Agent rooms (`room1/{roomId}`): the live actor per room; PostgreSQL
   * through HYPERDRIVE is the store of record (room-actor.ts). */
  ROOM_ACTORS: DurableObjectNamespace;
  /** Account deletion jobs (`purge1/{userId}`, account-purge.ts). */
  ACCOUNT_PURGE: DurableObjectNamespace;
  /** Per-user refresh leeway (`refresh1/{userId}`, refresh-leeway.ts): a refresh whose answer never
   * reached the device can be asked again. Absent in unit tests; /auth/refresh then refreshes directly. */
  REFRESH_LEEWAY?: DurableObjectNamespace;
  /** Agent rooms' PostgreSQL. Absent in `wrangler dev` unless a local connection string
   * is supplied; rooms then use an in-memory store (dev auth only). */
  HYPERDRIVE?: Hyperdrive;
  /** "off": rooms go straight to PostgreSQL (no actor-local ledger). */
  ROOM_LEDGER?: string;
  /** Agent rooms' hop decay in seconds (default 600); tests shorten it. */
  ROOM_HOP_DECAY_S?: string;
  BLOBS: R2Bucket;
  /** Release artifacts (headless tarballs, dmgs, latest.txt) served at
   * /releases/* for the curl-install flow. */
  RELEASES: R2Bucket;
  CODEGRAFF_OAUTH_CLIENT_ID: string;
  /** Secret for short-lived Harness JWTs; set with `wrangler secret put`. */
  HARNESS_AUTH_SIGNING_KEY?: string;
  /** "codegraff" or "dev" (bearer == userId, never prod). */
  AUTH_MODE: string;
  /** Gateway that vouches for a sandbox's device token (default https://gateway.codegraff.com); tests point it elsewhere. */
  CODEGRAFF_GATEWAY_URL?: string;
  /** APNs auth key (contents of AuthKey_XXXX.p8, wrangler secret) and its
   * key id. Unset ⇒ session notifications are decided and logged, not sent. */
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  /** Apple team id and the app's bundle id (defaults: the Harness iOS app). */
  APNS_TEAM_ID?: string;
  APNS_TOPIC?: string;
}

/** APNs settings, when push is set up for this deployment. */
export const apnsConfig = (env: Env) =>
  env.APNS_KEY_P8 && env.APNS_KEY_ID
    ? {
        keyP8: env.APNS_KEY_P8,
        keyId: env.APNS_KEY_ID,
        teamId: env.APNS_TEAM_ID ?? "WWP9DLJ27P",
        topic: env.APNS_TOPIC ?? "harness.codegraff.ios"
      }
    : undefined;

/** Header the Worker stamps on requests it forwards into DOs after verifying
 * the caller's JWT. DOs trust it blindly — they are only reachable through
 * the Worker (design §2: "DO never sees an unauthenticated frame"). */
export const AUTH_USER_HEADER = "x-harness-auth-user";

/** Header the Worker stamps on requests forwarded into workspace-doc rooms
 * (`ws/{orgId}`). Membership (JWT org claim == orgId) is enforced at the
 * Worker; the SessionRoom DO sees this and skips its per-chat
 * claim-on-first-join ownership discipline for the room. */
export const ROOM_KIND_HEADER = "x-harness-room-kind";
