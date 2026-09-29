/**
 * AccountPurge — one Durable Object per deleted account (`purge1/{userId}`):
 * the job that wipes everything the edge holds for a person once CodeGraff
 * has deleted their account (account-delete.ts).
 *
 * Two passes. The first runs at once. Harness access tokens are stateless and
 * live 55 minutes, so a desktop still signed in can keep syncing for up to
 * that long, and the registry re-seeds itself from any device that finds it
 * empty. Here that helps: whatever a lingering device re-uploads lands in the
 * registry, and the second pass, once every token has expired, lists it and
 * wipes it again. CodeGraff refuses the refresh after deletion, so no token
 * for the account exists after that.
 *
 * A pass wipes the registry (which hands back the chat, session and device ids
 * it lists), those rooms, the rooms named after the person (workspace docs,
 * vault, previews), their agent rooms, and R2: tool outputs under the
 * person's prefix and the backups the wiped rooms name. Rooms wipe themselves
 * through their own `POST /purge` (purge.ts); chat, session and device rooms
 * only when this person owns them.
 *
 * The work is a queue in this object's storage, a batch per alarm, so no one
 * invocation runs into the subrequest limit, and a target that fails is
 * retried with backoff.
 */
import { personalOrgId } from "./auth";
import { AUTH_USER_HEADER, ROOM_KIND_HEADER, type Env } from "./env";
import { PURGE_PATH } from "./purge";
import { AUTH_ORG_HEADER, roomStore } from "./room-actor";

/** The second pass waits out the longest-lived access token, plus slack. */
export const SECOND_PASS_MS = 65 * 60 * 1000;
/** Targets worked per alarm. */
const BATCH = 25;
/** A target that fails this often is logged and dropped. */
const MAX_ATTEMPTS = 8;
const RETRY_MS = 30_000;

type Target =
  | { t: "registry"; org: string }
  | { t: "rooms" }
  | { t: "object"; ns: ObjectNs; name: string; workspace?: boolean }
  | { t: "room"; id: string }
  | { t: "r2"; key: string }
  | { t: "r2prefix"; prefix: string };

type ObjectNs = "SESSION_ROOMS" | "CHAT_ROOMS" | "DEVICE_ROOMS" | "VAULT_ROOMS" | "PREVIEW_ROOMS";

interface Queued {
  target: Target;
  attempts: number;
}

interface Job {
  userId: string;
  orgs: string[];
  startedAt: number;
  pass: 1 | 2;
  doneAt?: number;
}

const keyOf = (t: Target): string => {
  switch (t.t) {
    case "registry":
      return `registry|${t.org}`;
    case "rooms":
      return "rooms";
    case "object":
      return `object|${t.ns}|${t.name}`;
    case "room":
      return `room|${t.id}`;
    case "r2":
      return `r2|${t.key}`;
    case "r2prefix":
      return `r2prefix|${t.prefix}`;
  }
};

const json = (value: unknown, status = 200): Response =>
  new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });

export class AccountPurge implements DurableObject {
  constructor(
    private readonly ctx: DurableObjectState,
    private readonly env: Env
  ) {}

  /** `POST /start` {userId, orgId?}: begin the job, or report on it. */
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/start" && request.method === "POST") {
      const body = (await request.json().catch(() => null)) as { userId?: unknown; orgId?: unknown } | null;
      if (typeof body?.userId !== "string" || !body.userId) return json({ error: "missing userId" }, 400);
      const existing = await this.ctx.storage.get<Job>("job");
      if (existing) return json({ status: existing.doneAt ? "done" : "running", pass: existing.pass });
      const orgs = [personalOrgId(body.userId)];
      if (typeof body.orgId === "string" && body.orgId && !orgs.includes(body.orgId)) orgs.push(body.orgId);
      const job: Job = { userId: body.userId, orgs, startedAt: Date.now(), pass: 1 };
      await this.ctx.storage.put("job", job);
      await this.seed(job);
      await this.ctx.storage.setAlarm(Date.now());
      return json({ status: "started" });
    }
    if (url.pathname === "/status" && request.method === "GET") {
      const job = await this.ctx.storage.get<Job>("job");
      const queued = (await this.ctx.storage.list({ prefix: "q:" })).size;
      return json(job ? { pass: job.pass, doneAt: job.doneAt ?? null, queued } : { status: "none" });
    }
    return json({ error: "not_found" }, 404);
  }

  /** The targets every pass starts from. */
  private async seed(job: Job): Promise<void> {
    const u = job.userId;
    const targets: Target[] = [{ t: "rooms" }, { t: "object", ns: "VAULT_ROOMS", name: `vault1/${u}` }];
    for (const org of job.orgs) {
      targets.push(
        { t: "registry", org },
        // `ws3` held the same per-user workspace doc before the ws4 break.
        { t: "object", ns: "SESSION_ROOMS", name: `ws4/${org}/${u}`, workspace: true },
        { t: "object", ns: "SESSION_ROOMS", name: `ws3/${org}/${u}`, workspace: true },
        { t: "object", ns: "PREVIEW_ROOMS", name: `preview1/${org}/${u}` }
      );
    }
    targets.push({ t: "r2prefix", prefix: `blob/${u}/` });
    await this.enqueue(targets);
  }

  /** Queue targets not already queued; ones found by a pass are also kept
   * so the second pass wipes them again even if the registry no longer
   * lists them. */
  private async enqueue(targets: Target[], remember = false): Promise<void> {
    const entries: Record<string, Queued> = {};
    const known: Record<string, Target> = {};
    for (const target of targets) {
      const key = keyOf(target);
      entries[`q:${key}`] = { target, attempts: 0 };
      if (remember) known[`k:${key}`] = target;
    }
    const existing = await this.ctx.storage.get<Queued>(Object.keys(entries));
    for (const key of existing.keys()) delete entries[key];
    for (let i = 0, keys = Object.keys(entries); i < keys.length; i += 128) {
      await this.ctx.storage.put(Object.fromEntries(keys.slice(i, i + 128).map((k) => [k, entries[k]])));
    }
    for (let i = 0, keys = Object.keys(known); i < keys.length; i += 128) {
      await this.ctx.storage.put(Object.fromEntries(keys.slice(i, i + 128).map((k) => [k, known[k]])));
    }
  }

  /** One batch at a time: the purges are subrequests, which let other events
   * in, and a second alarm run would read and work the same batch. */
  async alarm(): Promise<void> {
    await this.ctx.blockConcurrencyWhile(() => this.runBatch());
  }

  private async runBatch(): Promise<void> {
    const job = await this.ctx.storage.get<Job>("job");
    if (!job || job.doneAt) return;
    const batch = await this.ctx.storage.list<Queued>({ prefix: "q:", limit: BATCH });
    if (batch.size === 0) return this.finishPass(job);

    let failed = false;
    await Promise.all(
      [...batch].map(async ([key, queued]) => {
        try {
          // Not finished (more R2 objects under a prefix): stays queued.
          if (await this.run(job, queued.target)) await this.ctx.storage.delete(key);
        } catch (err) {
          const attempts = queued.attempts + 1;
          const log = { event: "account_purge_target_failed", target: keyOf(queued.target), attempts, error: String(err) };
          if (attempts >= MAX_ATTEMPTS) {
            console.error(JSON.stringify({ ...log, dropped: true }));
            await this.ctx.storage.delete(key);
          } else {
            console.warn(JSON.stringify(log));
            failed = true;
            // Behind the rest of the queue, so one stuck target can't hold a batch.
            await this.ctx.storage.delete(key);
            await this.ctx.storage.put(`q:~${attempts}|${keyOf(queued.target)}`, { ...queued, attempts });
          }
        }
      })
    );
    await this.ctx.storage.setAlarm(Date.now() + (failed ? RETRY_MS : 0));
  }

  private async finishPass(job: Job): Promise<void> {
    if (job.pass === 1) {
      await this.ctx.storage.put("job", { ...job, pass: 2 } satisfies Job);
      const known = await this.ctx.storage.list<Target>({ prefix: "k:" });
      await this.seed(job);
      await this.enqueue([...known.values()]);
      await this.ctx.storage.setAlarm(job.startedAt + SECOND_PASS_MS);
      return;
    }
    // Done: keep only the record that the account was purged.
    await this.ctx.storage.deleteAll();
    await this.ctx.storage.put("job", { userId: job.userId, orgs: [], startedAt: job.startedAt, pass: 2, doneAt: Date.now() });
    console.log(JSON.stringify({ event: "account_purged", startedAt: job.startedAt }));
  }

  /** Work one target; false when it has more to do and stays queued. */
  private async run(job: Job, target: Target): Promise<boolean> {
    switch (target.t) {
      case "registry": {
        const res = await this.purgeObject(this.env.REGISTRY_ROOMS, `reg1/${target.org}/${job.userId}`, job.userId);
        const ids = (res.ids ?? {}) as { chats?: string[]; sessions?: string[]; devices?: string[] };
        const found: Target[] = [];
        for (const id of [...(ids.chats ?? []), ...(ids.sessions ?? [])]) {
          found.push({ t: "object", ns: "SESSION_ROOMS", name: `s2/${id}` }, { t: "object", ns: "CHAT_ROOMS", name: `chat2/${id}` });
        }
        for (const id of ids.devices ?? []) found.push({ t: "object", ns: "DEVICE_ROOMS", name: `d2/${id}` });
        if (typeof res.backup === "string") found.push({ t: "r2", key: res.backup });
        await this.enqueue(found, true);
        return true;
      }
      case "rooms": {
        const store = roomStore(this.env);
        if (!store) return true;
        const [rooms, invites] = await Promise.all([store.listRooms(job.userId), store.invites(job.userId)]);
        const ids = new Set([...rooms.map((r) => r.id), ...invites.map((i) => i.roomId)]);
        await this.enqueue([...ids].map((id): Target => ({ t: "room", id })), true);
        return true;
      }
      case "object": {
        const res = await this.purgeObject(this.env[target.ns], target.name, job.userId, target.workspace);
        if (typeof res.backup === "string") await this.enqueue([{ t: "r2", key: res.backup }]);
        return true;
      }
      case "room": {
        const stub = this.env.ROOM_ACTORS.get(this.env.ROOM_ACTORS.idFromName(`room1/${target.id}`));
        const res = await stub.fetch(`https://room/forget?room=${encodeURIComponent(target.id)}`, {
          method: "POST",
          headers: { [AUTH_USER_HEADER]: job.userId, [AUTH_ORG_HEADER]: job.orgs[0] }
        });
        if (!res.ok) throw new Error(`room forget ${res.status}`);
        return true;
      }
      case "r2":
        await this.env.BLOBS.delete(target.key);
        return true;
      case "r2prefix": {
        const listed = await this.env.BLOBS.list({ prefix: target.prefix, limit: 1000 });
        if (listed.objects.length) await this.env.BLOBS.delete(listed.objects.map((o) => o.key));
        return !listed.truncated;
      }
    }
  }

  private async purgeObject(
    ns: DurableObjectNamespace,
    name: string,
    userId: string,
    workspace?: boolean
  ): Promise<Record<string, unknown>> {
    const headers: Record<string, string> = { [AUTH_USER_HEADER]: userId };
    if (workspace) headers[ROOM_KIND_HEADER] = "workspace";
    const res = await ns.get(ns.idFromName(name)).fetch(`https://purge${PURGE_PATH}`, { method: "POST", headers });
    if (!res.ok) throw new Error(`purge ${name.split("/")[0]} ${res.status}`);
    return (await res.json()) as Record<string, unknown>;
  }
}
