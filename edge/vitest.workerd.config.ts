import { defineConfig } from "vitest/config";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";

// Runtime-real test tier: runs inside actual workerd via
// @cloudflare/vitest-pool-workers, against a real SQLite-backed Durable
// Object, so platform limits like the ~2MB SQLITE_TOOBIG row cap (the
// 2026-08-05 whale sync freeze) are the runtime's own, not FakeSql constants.
// `npm run test:workerd`.
//
// loro-wasm does NOT work in this tier: the pool's test runner evaluates
// modules where wasm codegen is disallowed, while a real worker compiles the
// base64-inlined module at startup (deployed edge and `wrangler dev` are
// fine). loro-on-workerd coverage lives in the wrangler-dev scripts
// (scripts/whale-check.mjs, scripts/fold-check.mjs).
export default defineConfig({
  plugins: [
    cloudflareTest({
      main: "./test/workerd/fixture.ts",
      miniflare: {
        compatibilityDate: "2026-07-01",
        // Room actors reach PostgreSQL through `pg` (never here: no
        // Hyperdrive, so they use the in-memory dev store).
        compatibilityFlags: ["nodejs_compat"],
        bindings: {
          AUTH_MODE: "dev",
          CODEGRAFF_OAUTH_CLIENT_ID: "cg_client_test",
          HARNESS_AUTH_SIGNING_KEY: "test-signing-key-that-is-at-least-32-bytes"
        },
        r2Buckets: ["BLOBS"],
        durableObjects: {
          DEVICE_ROOMS: { className: "DeviceRoom", useSQLite: true },
          TEST_LOG: { className: "TestLogRoom", useSQLite: true },
          CHAT_ROOMS: { className: "ChatRoom", useSQLite: true },
          PREVIEW_ROOMS: { className: "PreviewRoom", useSQLite: true },
          REGISTRY_ROOMS: { className: "RegistryRoom", useSQLite: true },
          VAULT_ROOMS: { className: "VaultRoom", useSQLite: true },
          // SessionRoom's loro-wasm can't load in this tier: a stand-in
          // that records what the account purge asked of it.
          SESSION_ROOMS: { className: "TestSessionRoom", useSQLite: true },
          ROOM_ACTORS: { className: "RoomActor", useSQLite: true },
          ACCOUNT_PURGE: { className: "AccountPurge", useSQLite: true },
          REFRESH_LEEWAY: { className: "RefreshLeeway", useSQLite: true }
        }
      }
    })
  ],
  resolve: {
    // Mirror wrangler.jsonc: workerd cannot fetch loro's WASM by URL; the
    // base64 entry inlines it.
    alias: {
      "loro-crdt": "loro-crdt/base64",
      // `pg` is CommonJS the runner can't load; nothing here reaches it.
      pg: new URL("./test/workerd/pg-stub.ts", import.meta.url).pathname
    }
  },
  test: {
    include: ["test/workerd/**/*.test.ts"]
  }
});
