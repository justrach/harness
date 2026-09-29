/** Stand-in for `pg` in the workerd test tier: the driver is CommonJS the
 * test runner can't load, and nothing here reaches PostgreSQL (no Hyperdrive
 * binding, so rooms use the in-memory dev store). */
export class Client {
  constructor() {
    throw new Error("pg is not available in the workerd test tier");
  }
}
