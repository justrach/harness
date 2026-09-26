/**
 * VaultRoom: one per user (`vault1/{userId}`), the edge half of the login
 * vault (docs/adr/0005). It stores device public keys, the vault key wrapped
 * to each enrolled device, and item ciphertext. It never decrypts anything and
 * never calls a provider.
 *
 * The Worker's bearer check proves the account; it does not prove the device.
 * Every mutating request therefore also carries an Ed25519 signature from an
 * enrolled device over `method|path|sha256hex(body)|timestampMs|deviceId`
 * (X-Vault-Device, X-Vault-Timestamp, X-Vault-Signature), within 60 s and
 * never replayed. With the bearer alone a caller can read ciphertext and
 * register a pending device, nothing else.
 *
 * Routes (all under the authed Worker):
 *   GET    /vault
 *   POST   /vault/devices                       (bearer only: register)
 *   POST   /vault/devices/{id}/approve          (signed)
 *   DELETE /vault/devices/{id}                  (signed)
 *   POST   /vault/rotate                        (signed)
 *   GET    /vault/items/{agent}/{slot}
 *   PUT    /vault/items/{agent}/{slot}          (signed, If-Match)
 *   POST   /vault/items/{agent}/{slot}/status   (signed)
 *   POST   /vault/items/{agent}/{slot}/lease    (signed)
 *   DELETE /vault/items/{agent}/{slot}/lease    (signed)
 *   POST   /vault/items/{agent}/{slot}/hold     (signed)
 */
import { AUTH_USER_HEADER, type Env } from "./env";

export const VAULT_LIMITS = {
  devices: 20,
  pendingDevices: 5,
  items: 64,
  ciphertextChars: 90_000, // base64url of the 64 KiB plaintext cap plus tag
  bodyBytes: 128 * 1024,
  leaseSeconds: 60,
  skewMs: 60_000,
  replayMs: 120_000,
  pendingTtlMs: 24 * 60 * 60 * 1000
};

const DEVICE_ID = /^[A-Za-z0-9_-]{1,128}$/;
const NAME = /^[A-Za-z0-9_.-]{1,64}$/;
const B64URL = /^[A-Za-z0-9_-]*$/;
const KEY_CHARS = 43; // 32 bytes, base64url without padding
const WRAPPED_CHARS = 139; // 104 bytes: ephPub(32) ‖ nonce(24) ‖ ct(32) ‖ tag(16)
const NONCE_CHARS = 32; // 24 bytes

type DeviceRow = {
  device_id: string;
  name: string;
  public_key: string;
  signing_key: string;
  status: "pending" | "enrolled";
  wrapped_key: string | null;
  created_at: number;
  last_seen_at: number;
};

type ItemRow = {
  agent: string;
  slot: string;
  version: number;
  key_epoch: number;
  kind: string;
  status: string;
  nonce: string | null;
  ciphertext: string | null;
  holder: string | null;
  lease_holder: string | null;
  lease_until: number;
  updated_at: number;
  updated_by: string | null;
};

const json = (value: unknown, status = 200): Response =>
  new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" }
  });

// DELETEs answer 200 with a tiny body rather than a bodyless 204: some HTTP
// clients (Zig's std.http among them) mishandle a 204 on a reused request
// shape, and every vault client already accepts 200.
const noContent = (): Response => json({ ok: true });

const b64urlDecode = (s: string): Uint8Array | undefined => {
  if (!B64URL.test(s)) return undefined;
  try {
    const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4));
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch {
    return undefined;
  }
};

const sha256Hex = async (bytes: Uint8Array): Promise<string> => {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
};

export class VaultRoom implements DurableObject {
  private readonly sql: SqlStorage;

  constructor(private readonly ctx: DurableObjectState, _env: Env) {
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS vault_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS vault_devices (
      device_id TEXT PRIMARY KEY, name TEXT NOT NULL, public_key TEXT NOT NULL,
      signing_key TEXT NOT NULL, status TEXT NOT NULL, wrapped_key TEXT,
      created_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS vault_items (
      agent TEXT NOT NULL, slot TEXT NOT NULL, version INTEGER NOT NULL,
      key_epoch INTEGER NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL,
      nonce TEXT, ciphertext TEXT, holder TEXT, lease_holder TEXT,
      lease_until INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL,
      updated_by TEXT, PRIMARY KEY (agent, slot))`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS vault_seen (sig TEXT PRIMARY KEY, at INTEGER NOT NULL)`);
  }

  // ── state helpers ────────────────────────────────────────────────────────

  private epoch(): number {
    const row = [...this.sql.exec("SELECT v FROM vault_meta WHERE k = 'keyEpoch'")][0];
    return row ? Number(row.v) : 1;
  }

  private setEpoch(epoch: number): void {
    this.sql.exec(
      "INSERT INTO vault_meta (k, v) VALUES ('keyEpoch', ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
      String(epoch)
    );
  }

  private devices(): DeviceRow[] {
    return [...this.sql.exec("SELECT * FROM vault_devices ORDER BY created_at")] as unknown as DeviceRow[];
  }

  private device(id: string): DeviceRow | undefined {
    return [...this.sql.exec("SELECT * FROM vault_devices WHERE device_id = ?", id)][0] as unknown as
      | DeviceRow
      | undefined;
  }

  private item(agent: string, slot: string): ItemRow | undefined {
    return [...this.sql.exec("SELECT * FROM vault_items WHERE agent = ? AND slot = ?", agent, slot)][0] as unknown as
      | ItemRow
      | undefined;
  }

  private itemHeader(it: ItemRow, now: number) {
    const leased = it.lease_holder !== null && it.lease_until > now;
    return {
      agent: it.agent,
      slot: it.slot,
      version: it.version,
      keyEpoch: it.key_epoch,
      kind: it.kind,
      status: it.status,
      holder: it.holder,
      leaseHolder: leased ? it.lease_holder : null,
      leaseUntil: leased ? it.lease_until : null,
      updatedAt: it.updated_at,
      updatedBy: it.updated_by
    };
  }

  private prune(now: number): void {
    this.sql.exec("DELETE FROM vault_seen WHERE at < ?", now - VAULT_LIMITS.replayMs);
    this.sql.exec(
      "DELETE FROM vault_devices WHERE status = 'pending' AND created_at < ?",
      now - VAULT_LIMITS.pendingTtlMs
    );
  }

  /** The enrolled device that signed this request, or a 401 response. */
  private async verify(request: Request, url: URL, body: Uint8Array, now: number): Promise<DeviceRow | Response> {
    const deny = () => json({ error: "bad_signature" }, 401);
    const deviceId = request.headers.get("x-vault-device") ?? "";
    const ts = Number(request.headers.get("x-vault-timestamp") ?? "");
    const sigText = request.headers.get("x-vault-signature") ?? "";
    const device = DEVICE_ID.test(deviceId) ? this.device(deviceId) : undefined;
    if (!device || device.status !== "enrolled") return deny();
    if (!Number.isSafeInteger(ts) || Math.abs(now - ts) > VAULT_LIMITS.skewMs) return deny();
    const sig = b64urlDecode(sigText);
    const pub = b64urlDecode(device.signing_key);
    if (!sig || sig.length !== 64 || !pub || pub.length !== 32) return deny();
    if ([...this.sql.exec("SELECT 1 FROM vault_seen WHERE sig = ?", sigText)].length > 0) return deny();
    const message = `${request.method}|${url.pathname}${url.search}|${await sha256Hex(body)}|${ts}|${deviceId}`;
    try {
      const key = await crypto.subtle.importKey("raw", pub, { name: "Ed25519" }, false, ["verify"]);
      const ok = await crypto.subtle.verify({ name: "Ed25519" }, key, sig, new TextEncoder().encode(message));
      if (!ok) return deny();
    } catch {
      return deny();
    }
    this.sql.exec("INSERT INTO vault_seen (sig, at) VALUES (?, ?)", sigText, now);
    this.sql.exec("UPDATE vault_devices SET last_seen_at = ? WHERE device_id = ?", now, deviceId);
    return device;
  }

  // ── HTTP ─────────────────────────────────────────────────────────────────

  async fetch(request: Request): Promise<Response> {
    const userId = request.headers.get(AUTH_USER_HEADER);
    if (!userId) return json({ error: "unauthenticated" }, 401);
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    if (parts[0] !== "vault") return json({ error: "not_found" }, 404);

    const body = new Uint8Array(await request.arrayBuffer());
    if (body.byteLength > VAULT_LIMITS.bodyBytes) return json({ error: "too_large" }, 413);
    const now = Date.now();
    this.prune(now);

    const method = request.method;
    const readJson = (): Record<string, unknown> | undefined => {
      if (body.byteLength === 0) return {};
      try {
        const v = JSON.parse(new TextDecoder().decode(body));
        return v && typeof v === "object" && !Array.isArray(v) ? v : undefined;
      } catch {
        return undefined;
      }
    };

    // Reads: bearer only.
    if (method === "GET" && parts.length === 1) return this.state(userId, request, now);
    if (method === "GET" && parts[1] === "items" && parts.length === 4) return this.getItem(parts[2], parts[3]);
    // Registration: bearer only; the device is pending until approved.
    if (method === "POST" && parts[1] === "devices" && parts.length === 2) {
      const data = readJson();
      return data ? this.register(data, now) : json({ error: "bad_json" }, 400);
    }

    // Everything else mutates and must be signed by an enrolled device.
    const caller = await this.verify(request, url, body, now);
    if (caller instanceof Response) return caller;
    const data = readJson();
    if (!data) return json({ error: "bad_json" }, 400);

    if (parts[1] === "devices" && parts.length === 4 && parts[3] === "approve" && method === "POST") {
      return this.approve(parts[2], data);
    }
    if (parts[1] === "devices" && parts.length === 3 && method === "DELETE") return this.removeDevice(parts[2]);
    if (parts[1] === "rotate" && parts.length === 2 && method === "POST") return this.rotate(data);
    if (parts[1] === "items" && parts.length >= 4) {
      const [agent, slot, action] = [parts[2], parts[3], parts[4]];
      if (!NAME.test(agent) || !NAME.test(slot)) return json({ error: "bad_item" }, 400);
      if (parts.length === 4 && method === "PUT") return this.putItem(agent, slot, request, data, caller, now);
      if (parts.length === 5 && action === "status" && method === "POST") return this.setStatus(agent, slot, data, now);
      if (parts.length === 5 && action === "lease" && method === "POST") return this.lease(agent, slot, data, caller, now);
      if (parts.length === 5 && action === "lease" && method === "DELETE") return this.release(agent, slot, caller);
      if (parts.length === 5 && action === "hold" && method === "POST") return this.hold(agent, slot, caller, now);
    }
    return json({ error: "not_found" }, 404);
  }

  private state(userId: string, request: Request, now: number): Response {
    const me = request.headers.get("x-vault-device") ?? "";
    const devices = this.devices();
    const mine = devices.find((d) => d.device_id === me && d.status === "enrolled");
    const items = [...this.sql.exec("SELECT * FROM vault_items ORDER BY agent, slot")] as unknown as ItemRow[];
    return json({
      userId,
      keyEpoch: this.epoch(),
      wrappedKey: mine?.wrapped_key ?? null,
      devices: devices.map((d) => ({
        deviceId: d.device_id,
        name: d.name,
        publicKey: d.public_key,
        signingKey: d.signing_key,
        status: d.status,
        createdAt: d.created_at,
        lastSeenAt: d.last_seen_at
      })),
      items: items.map((it) => this.itemHeader(it, now))
    });
  }

  private register(data: Record<string, unknown>, now: number): Response {
    const { deviceId, name, publicKey, signingKey, wrappedKey } = data;
    if (typeof deviceId !== "string" || !DEVICE_ID.test(deviceId)) return json({ error: "bad_device_id" }, 400);
    if (typeof name !== "string" || name.length === 0 || name.length > 100) return json({ error: "bad_name" }, 400);
    if (typeof publicKey !== "string" || publicKey.length !== KEY_CHARS || !b64urlDecode(publicKey)) {
      return json({ error: "bad_public_key" }, 400);
    }
    if (typeof signingKey !== "string" || signingKey.length !== KEY_CHARS || !b64urlDecode(signingKey)) {
      return json({ error: "bad_signing_key" }, 400);
    }
    const existing = this.device(deviceId);
    if (existing) {
      // Re-registering is idempotent only with identical keys; a different key
      // under a known id would let a bearer holder take over the device.
      if (existing.public_key === publicKey && existing.signing_key === signingKey) {
        return json({ deviceId, status: existing.status });
      }
      return json({ error: "device_exists" }, 409);
    }
    const all = this.devices();
    const enrolled = all.filter((d) => d.status === "enrolled").length;
    if (all.length >= VAULT_LIMITS.devices) return json({ error: "too_many_devices" }, 409);
    if (enrolled === 0) {
      // Bootstrap: the first device brings the vault key wrapped to itself.
      if (typeof wrappedKey !== "string" || wrappedKey.length !== WRAPPED_CHARS || !b64urlDecode(wrappedKey)) {
        return json({ error: "bootstrap_requires_wrapped_key" }, 400);
      }
      this.sql.exec(
        "INSERT INTO vault_devices VALUES (?, ?, ?, ?, 'enrolled', ?, ?, ?)",
        deviceId, name, publicKey, signingKey, wrappedKey, now, now
      );
      if (![...this.sql.exec("SELECT 1 FROM vault_meta WHERE k = 'keyEpoch'")].length) this.setEpoch(1);
      return json({ deviceId, status: "enrolled" });
    }
    if (all.length - enrolled >= VAULT_LIMITS.pendingDevices) return json({ error: "too_many_pending" }, 409);
    this.sql.exec(
      "INSERT INTO vault_devices VALUES (?, ?, ?, ?, 'pending', NULL, ?, ?)",
      deviceId, name, publicKey, signingKey, now, now
    );
    return json({ deviceId, status: "pending" });
  }

  private approve(deviceId: string, data: Record<string, unknown>): Response {
    const target = DEVICE_ID.test(deviceId) ? this.device(deviceId) : undefined;
    if (!target) return json({ error: "not_found" }, 404);
    if (target.status !== "pending") return json({ error: "not_pending" }, 409);
    const { wrappedKey } = data;
    if (typeof wrappedKey !== "string" || wrappedKey.length !== WRAPPED_CHARS || !b64urlDecode(wrappedKey)) {
      return json({ error: "bad_wrapped_key" }, 400);
    }
    this.sql.exec(
      "UPDATE vault_devices SET status = 'enrolled', wrapped_key = ? WHERE device_id = ?",
      wrappedKey, deviceId
    );
    return json({ deviceId, status: "enrolled" });
  }

  private removeDevice(deviceId: string): Response {
    if (!DEVICE_ID.test(deviceId) || !this.device(deviceId)) return json({ error: "not_found" }, 404);
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM vault_devices WHERE device_id = ?", deviceId);
      this.sql.exec("UPDATE vault_items SET lease_holder = NULL, lease_until = 0 WHERE lease_holder = ?", deviceId);
      this.sql.exec("UPDATE vault_items SET holder = NULL WHERE holder = ?", deviceId);
    });
    return noContent();
  }

  private rotate(data: Record<string, unknown>): Response {
    const current = this.epoch();
    const { keyEpoch, wrappedKeys } = data;
    if (keyEpoch !== current + 1) return json({ error: "stale_epoch", keyEpoch: current }, 409);
    if (!wrappedKeys || typeof wrappedKeys !== "object" || Array.isArray(wrappedKeys)) {
      return json({ error: "bad_wrapped_keys" }, 400);
    }
    const given = wrappedKeys as Record<string, unknown>;
    const enrolled = this.devices().filter((d) => d.status === "enrolled").map((d) => d.device_id);
    const ids = Object.keys(given);
    if (ids.length !== enrolled.length || !enrolled.every((id) => ids.includes(id))) {
      return json({ error: "wrapped_keys_must_cover_enrolled_devices" }, 400);
    }
    for (const id of ids) {
      const w = given[id];
      if (typeof w !== "string" || w.length !== WRAPPED_CHARS || !b64urlDecode(w)) {
        return json({ error: "bad_wrapped_key", deviceId: id }, 400);
      }
    }
    this.ctx.storage.transactionSync(() => {
      for (const id of ids) {
        this.sql.exec("UPDATE vault_devices SET wrapped_key = ? WHERE device_id = ?", given[id] as string, id);
      }
      this.setEpoch(current + 1);
    });
    return json({ keyEpoch: current + 1 });
  }

  private getItem(agent: string, slot: string): Response {
    if (!NAME.test(agent) || !NAME.test(slot)) return json({ error: "bad_item" }, 400);
    const it = this.item(agent, slot);
    if (!it || it.version === 0 || it.ciphertext === null) return json({ error: "not_found" }, 404);
    return json({
      ...this.itemHeader(it, Date.now()),
      nonce: it.nonce,
      ciphertext: it.ciphertext
    });
  }

  private leaseBlocks(it: ItemRow | undefined, caller: DeviceRow, now: number): Response | undefined {
    if (it && it.lease_holder && it.lease_holder !== caller.device_id && it.lease_until > now) {
      return json({ error: "lease_held", leaseHolder: it.lease_holder, leaseUntil: it.lease_until, version: it.version }, 409);
    }
    return undefined;
  }

  private putItem(
    agent: string, slot: string, request: Request, data: Record<string, unknown>, caller: DeviceRow, now: number
  ): Response {
    const ifMatch = Number(request.headers.get("if-match") ?? "");
    if (!Number.isSafeInteger(ifMatch) || ifMatch < 0) return json({ error: "if_match_required" }, 428);
    const { kind, status, nonce, ciphertext, keyEpoch } = data;
    if (kind !== "rotating" && kind !== "static") return json({ error: "bad_kind" }, 400);
    if (status !== "ok" && status !== "needs_signin") return json({ error: "bad_status" }, 400);
    if (typeof nonce !== "string" || nonce.length !== NONCE_CHARS || !b64urlDecode(nonce)) {
      return json({ error: "bad_nonce" }, 400);
    }
    if (typeof ciphertext !== "string" || ciphertext.length === 0 || ciphertext.length > VAULT_LIMITS.ciphertextChars ||
        !b64urlDecode(ciphertext)) {
      return json({ error: "bad_ciphertext" }, 400);
    }
    const it = this.item(agent, slot);
    const blocked = this.leaseBlocks(it, caller, now);
    if (blocked) return blocked;
    const epoch = this.epoch();
    if (keyEpoch !== epoch) return json({ error: "stale_epoch", keyEpoch: epoch }, 409);
    const version = it?.version ?? 0;
    if (ifMatch !== version) return json({ currentVersion: version }, 412);
    if (!it) {
      const count = [...this.sql.exec("SELECT count(*) AS n FROM vault_items")][0].n as number;
      if (count >= VAULT_LIMITS.items) return json({ error: "too_many_items" }, 409);
      this.sql.exec(
        `INSERT INTO vault_items (agent, slot, version, key_epoch, kind, status, nonce, ciphertext, holder,
           lease_holder, lease_until, updated_at, updated_by) VALUES (?, ?, 1, ?, ?, ?, ?, ?, NULL, NULL, 0, ?, ?)`,
        agent, slot, epoch, kind, status, nonce, ciphertext, now, caller.device_id
      );
      return json({ version: 1 });
    }
    this.sql.exec(
      `UPDATE vault_items SET version = ?, key_epoch = ?, kind = ?, status = ?, nonce = ?, ciphertext = ?,
         updated_at = ?, updated_by = ? WHERE agent = ? AND slot = ?`,
      version + 1, epoch, kind, status, nonce, ciphertext, now, caller.device_id, agent, slot
    );
    return json({ version: version + 1 });
  }

  private setStatus(agent: string, slot: string, data: Record<string, unknown>, now: number): Response {
    const { status, ifVersion } = data;
    if (status !== "ok" && status !== "needs_signin") return json({ error: "bad_status" }, 400);
    const it = this.item(agent, slot);
    if (!it || it.version === 0) return json({ error: "not_found" }, 404);
    if (ifVersion !== it.version) return json({ currentVersion: it.version }, 412);
    this.sql.exec("UPDATE vault_items SET status = ?, updated_at = ? WHERE agent = ? AND slot = ?", status, now, agent, slot);
    return json({ status, version: it.version });
  }

  private lease(agent: string, slot: string, data: Record<string, unknown>, caller: DeviceRow, now: number): Response {
    const ttl = typeof data.ttlSeconds === "number" ? data.ttlSeconds : VAULT_LIMITS.leaseSeconds;
    if (!Number.isFinite(ttl) || ttl <= 0) return json({ error: "bad_ttl" }, 400);
    let it = this.item(agent, slot);
    const blocked = this.leaseBlocks(it, caller, now);
    if (blocked) return blocked;
    const until = now + Math.min(ttl, VAULT_LIMITS.leaseSeconds) * 1000;
    if (!it) {
      const count = [...this.sql.exec("SELECT count(*) AS n FROM vault_items")][0].n as number;
      if (count >= VAULT_LIMITS.items) return json({ error: "too_many_items" }, 409);
      // A lease may precede the first write; version 0 has no ciphertext.
      this.sql.exec(
        `INSERT INTO vault_items (agent, slot, version, key_epoch, kind, status, nonce, ciphertext, holder,
           lease_holder, lease_until, updated_at, updated_by) VALUES (?, ?, 0, ?, 'rotating', 'ok', NULL, NULL, NULL, ?, ?, ?, ?)`,
        agent, slot, this.epoch(), caller.device_id, until, now, caller.device_id
      );
      it = this.item(agent, slot)!;
    } else {
      this.sql.exec(
        "UPDATE vault_items SET lease_holder = ?, lease_until = ? WHERE agent = ? AND slot = ?",
        caller.device_id, until, agent, slot
      );
    }
    // `version` lets the caller notice a commit that landed between its read
    // and this lease, and adopt it instead of refreshing a spent token.
    return json({ leaseHolder: caller.device_id, leaseUntil: until, version: it.version });
  }

  private release(agent: string, slot: string, caller: DeviceRow): Response {
    this.sql.exec(
      "UPDATE vault_items SET lease_holder = NULL, lease_until = 0 WHERE agent = ? AND slot = ? AND lease_holder = ?",
      agent, slot, caller.device_id
    );
    return noContent();
  }

  private hold(agent: string, slot: string, caller: DeviceRow, now: number): Response {
    const it = this.item(agent, slot);
    if (!it || it.version === 0) return json({ error: "not_found" }, 404);
    this.sql.exec("UPDATE vault_items SET holder = ?, updated_at = ? WHERE agent = ? AND slot = ?", caller.device_id, now, agent, slot);
    return json({ holder: caller.device_id, version: it.version });
  }
}
