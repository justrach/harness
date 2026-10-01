import { previewRoute } from "../../src/preview-route";
export { DeviceRoom } from "../../src/device-room";
export { ChatRoom } from "../../src/chat-room";
export { PreviewRoom } from "../../src/preview-room";
export { RegistryRoom } from "../../src/registry-room";
export { VaultRoom } from "../../src/vault-room";
export { RoomActor } from "../../src/room-actor";
export { AccountPurge } from "../../src/account-purge";
export { RefreshLeeway } from "../../src/refresh-leeway";
import { DurableObject } from "cloudflare:workers";

/** Bare SQLite-backed DO; tests reach its real `ctx.storage.sql` via
 * `runInDurableObject` (the cloudflare-os TEST_OVERSEER pattern). */
export class TestLogRoom extends DurableObject {}

/** Stand-in for SessionRoom (its loro-wasm can't load here): answers the
 * account purge like the real one (owner-checked unless workspace) and
 * records each call. */
export class TestSessionRoom extends DurableObject {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const userId = request.headers.get("x-harness-auth-user") ?? "";
    if (url.pathname === "/seed") {
      await this.ctx.storage.put({ owner: userId, chatId: url.searchParams.get("chatId") ?? "", data: "doc" });
      return new Response("ok");
    }
    if (url.pathname === "/purge") {
      const workspace = request.headers.get("x-harness-room-kind") === "workspace";
      const owner = await this.ctx.storage.get<string>("owner");
      const calls = ((await this.ctx.storage.get<number>("purgeCalls")) ?? 0) + 1;
      if (!workspace && owner !== userId) {
        await this.ctx.storage.put("purgeCalls", calls);
        return Response.json({ purged: false });
      }
      const chatId = await this.ctx.storage.get<string>("chatId");
      await this.ctx.storage.deleteAll();
      await this.ctx.storage.put("purgeCalls", calls);
      return Response.json({ purged: true, ...(chatId ? { backup: `backup/${chatId}/latest.loro` } : {}) });
    }
    if (url.pathname === "/peek") {
      return Response.json({
        data: (await this.ctx.storage.get<string>("data")) ?? null,
        purgeCalls: (await this.ctx.storage.get<number>("purgeCalls")) ?? 0
      });
    }
    return new Response("not found", { status: 404 });
  }
}

export default {
  fetch(request: Request, env: { PREVIEW_ROOMS: DurableObjectNamespace }): Response | Promise<Response> {
    // Test credentials exercise the production routing seam without loading
    // the unrelated session-room WASM inside the Workers test runner.
    const bearer = request.headers.get("authorization");
    if (!bearer?.startsWith("Bearer ")) return new Response("Unauthorized", { status: 401 });
    const [userId, orgId] = bearer.slice(7).split("@");
    return previewRoute(request, env, { userId, orgId }) ?? new Response("test fixture", { status: 404 });
  }
};
