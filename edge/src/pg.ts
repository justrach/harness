/**
 * PostgreSQL through Hyperdrive.
 *
 * Stateless Worker routes run one statement per request via {@link withPg} and
 * close the client before returning (Workers forbid sharing sockets across
 * separate incoming requests; Hyperdrive pools the origin TCP/TLS session).
 *
 * Long-lived Durable Objects (RoomActor) use {@link PgPool} to keep a small
 * bounded set of warm clients across back-to-back wakes, posts and 1s ledger
 * flushes, evicting idle connections after {@link DEFAULT_IDLE_MS} so quiet
 * actors hold none.
 */
import { Client } from "pg";

export interface PgQueryResult<R = Record<string, unknown>> {
  rows: R[];
  rowCount: number | null;
}

export interface PgClient {
  connect(): Promise<void>;
  query<R = Record<string, unknown>>(text: string, values?: unknown[]): Promise<PgQueryResult<R>>;
  end(): Promise<void>;
}

export type PgEnv = {
  HYPERDRIVE?: Hyperdrive;
  /** Test hook: inject a mock or counting client without touching network sockets. */
  pgClientFactory?: (connectionString: string) => PgClient;
};

export interface PgPoolOptions {
  maxIdle?: number;
  idleMs?: number;
}

export const DEFAULT_MAX_IDLE = 2;
export const DEFAULT_IDLE_MS = 5_000;

/** A PostgreSQL error answer (a SQLSTATE), as opposed to a broken connection. */
export const isSqlError = (err: unknown): boolean =>
  typeof (err as { code?: unknown })?.code === "string" && /^[0-9A-Z]{5}$/.test((err as { code: string }).code);

function createClient(env: PgEnv): PgClient {
  if (!env.HYPERDRIVE) throw new Error("postgres is not configured (no HYPERDRIVE binding)");
  if (env.pgClientFactory) return env.pgClientFactory(env.HYPERDRIVE.connectionString);
  return new Client({ connectionString: env.HYPERDRIVE.connectionString }) as unknown as PgClient;
}

/** Run `fn` with a connected client, closing it afterwards whatever happens. */
export async function withPg<T>(env: PgEnv, fn: (client: PgClient) => Promise<T>): Promise<T> {
  const client = createClient(env);
  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.end().catch(() => {});
  }
}

/**
 * Bounded idle client pool scoped to a single I/O context (a Durable Object
 * instance, or a single test). Never share an instance across unrelated
 * stateless Worker requests.
 */
export class PgPool {
  private readonly maxIdle: number;
  private readonly idleMs: number;
  private readonly idle: PgClient[] = [];
  private timer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private readonly env: PgEnv,
    options: PgPoolOptions = {}
  ) {
    this.maxIdle = Math.max(0, options.maxIdle ?? DEFAULT_MAX_IDLE);
    this.idleMs = Math.max(0, options.idleMs ?? DEFAULT_IDLE_MS);
  }

  get idleCount(): number {
    return this.idle.length;
  }

  private armTimer(): void {
    if (this.timer) clearTimeout(this.timer);
    if (this.idle.length === 0 || this.idleMs <= 0) {
      this.timer = null;
      return;
    }
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.close();
    }, this.idleMs);
    (this.timer as { unref?: () => void }).unref?.();
  }

  async acquire(): Promise<{ client: PgClient; reused: boolean }> {
    const parked = this.idle.pop();
    if (parked) {
      if (this.idle.length === 0 && this.timer) {
        clearTimeout(this.timer);
        this.timer = null;
      }
      return { client: parked, reused: true };
    }
    const client = createClient(this.env);
    await client.connect();
    return { client, reused: false };
  }

  release(client: PgClient): void {
    if (this.maxIdle <= 0 || this.idleMs <= 0 || this.idle.length >= this.maxIdle) {
      void client.end().catch(() => {});
      return;
    }
    this.idle.push(client);
    this.armTimer();
  }

  discard(client: PgClient): void {
    void client.end().catch(() => {});
  }

  async withClient<T>(
    fn: (client: PgClient) => Promise<T>,
    options: { retryIdleDisconnect?: boolean } = {}
  ): Promise<T> {
    for (let attempt = 0; ; attempt++) {
      const { client, reused } = await this.acquire();
      try {
        const out = await fn(client);
        this.release(client);
        return out;
      } catch (err) {
        if (isSqlError(err)) {
          this.release(client);
          throw err;
        }
        this.discard(client);
        if (reused && attempt === 0 && options.retryIdleDisconnect) continue;
        throw err;
      }
    }
  }

  async close(): Promise<void> {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    const clients = this.idle.splice(0, this.idle.length);
    await Promise.allSettled(clients.map((c) => c.end()));
  }
}
