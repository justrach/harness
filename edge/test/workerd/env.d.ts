/// <reference types="@cloudflare/vitest-pool-workers" />

declare module "cloudflare:test" {
  interface ProvidedEnv extends import("../../src/env").Env {
    TEST_LOG: DurableObjectNamespace;
  }
}
