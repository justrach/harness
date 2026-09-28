/**
 * PostgreSQL (codegraff-pg) through Hyperdrive. Hyperdrive keeps the pooled
 * connections to the origin, so a short-lived client per use is cheap:
 * connect, run, close. The connection string lives only in the Hyperdrive
 * config, never in this repo. Same helper as the codegraff gateway's.
 */
import { Client } from "pg";

export type PgEnv = { HYPERDRIVE?: Hyperdrive };

/** Run `fn` with a connected client, closing it afterwards whatever happens. */
export async function withPg<T>(env: PgEnv, fn: (client: Client) => Promise<T>): Promise<T> {
  if (!env.HYPERDRIVE) throw new Error("postgres is not configured (no HYPERDRIVE binding)");
  const client = new Client({ connectionString: env.HYPERDRIVE.connectionString });
  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.end().catch(() => {});
  }
}
