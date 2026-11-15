import { describe, expect, it } from "vitest";
import { issueToken } from "./auth";
import { handleAuthRoute } from "./auth-routes";
import type { Env } from "./env";
import {
  CURRENT_CARD_SCENES,
  HARNESS_OAUTH_CLIENT_ID,
  deleteHarnessMember,
  deriveMemberCardTraits,
  ensureHarnessMemberProfile
} from "./member-profile";
import type { PgClient, PgEnv } from "./pg";

const baseEnv = {
  CODEGRAFF_OAUTH_CLIENT_ID: HARNESS_OAUTH_CLIENT_ID,
  HARNESS_AUTH_SIGNING_KEY: "s".repeat(48),
  AUTH_MODE: "codegraff"
} as unknown as Env;

describe("member profile", () => {
  it("degrades gracefully without Hyperdrive", async () => {
    expect(await ensureHarnessMemberProfile(baseEnv, "42", "rach@example.com")).toEqual({
      id: "42",
      email: "rach@example.com"
    });
  });

  it("queries and normalizes PostgreSQL bigint member fields and cg_auth_user identity", async () => {
    const queries: Array<{ text: string; values?: unknown[] }> = [];
    const client: PgClient = {
      async connect() {},
      async query(text, values) {
        queries.push({ text, values });
        return {
          rows: [
            {
              email: "rach@example.com",
              name: "Rach",
              avatar_url: "https://example.com/avatar.png",
              member_number: "42",
              started_at: "1761955200",
              card_scenes: 20,
              card_scene: 1,
              card_sky: 12,
              card_enso: 5,
              card_holo: 3,
              card_seal: 7
            }
          ] as unknown as never[],
          rowCount: 1
        };
      },
      async end() {}
    };
    const env = {
      ...baseEnv,
      HYPERDRIVE: { connectionString: "postgres://stub" } as Hyperdrive,
      pgClientFactory: () => client
    } as Env & PgEnv;

    const profile = await ensureHarnessMemberProfile(env, "42");
    expect(profile).toEqual({
      id: "42",
      email: "rach@example.com",
      name: "Rach",
      avatarUrl: "https://example.com/avatar.png",
      memberNumber: 42,
      startedAt: 1761955200,
      cardScenes: CURRENT_CARD_SCENES,
      cardTraits: { scene: 1, sky: 12, enso: 5, holo: 3, seal: 7 }
    });
    expect(queries).toHaveLength(1);
    expect(queries[0].values).toEqual(["42", HARNESS_OAUTH_CLIENT_ID, CURRENT_CARD_SCENES]);
    expect(queries[0].text).toContain("app.harness_members");
    expect(queries[0].text).toContain("app.cg_auth_user");
  });

  it("falls back to legacy 6-column query and derives cardTraits when column 0107 is absent (42703)", async () => {
    let calls = 0;
    const client: PgClient = {
      async connect() {},
      async query() {
        calls += 1;
        if (calls === 1) {
          throw Object.assign(new Error("column card_scene does not exist"), { code: "42703" });
        }
        return {
          rows: [
            {
              email: "ada@example.com",
              name: "Ada",
              avatar_url: null,
              member_number: "42",
              started_at: "1761955200",
              card_scenes: 12
            }
          ] as unknown as never[],
          rowCount: 1
        };
      },
      async end() {}
    };
    const env = {
      ...baseEnv,
      HYPERDRIVE: { connectionString: "postgres://stub" } as Hyperdrive,
      pgClientFactory: () => client
    } as Env & PgEnv;

    const profile = await ensureHarnessMemberProfile(env, "42");
    expect(calls).toBe(2);
    expect(profile.cardTraits).toEqual(deriveMemberCardTraits(42));
  });

  it("derives 3,200 unique 3-layer artworks and 128,000 unique 5-trait cards", () => {
    const founderArt = new Set<string>();
    const allTraits = new Set<string>();
    for (let m = 1; m <= 3200; m += 1) {
      const t = deriveMemberCardTraits(m);
      expect(t.scene).toBeGreaterThanOrEqual(0);
      expect(t.scene).toBeLessThan(20);
      expect(t.sky).toBeGreaterThanOrEqual(0);
      expect(t.sky).toBeLessThan(20);
      expect(t.enso).toBeGreaterThanOrEqual(0);
      expect(t.enso).toBeLessThan(8);
      expect(t.holo).toBeGreaterThanOrEqual(0);
      expect(t.holo).toBeLessThan(5);
      expect(t.seal).toBeGreaterThanOrEqual(0);
      expect(t.seal).toBeLessThan(8);
      founderArt.add(`${t.scene}:${t.sky}:${t.enso}`);
      allTraits.add(`${t.scene}:${t.sky}:${t.enso}:${t.holo}:${t.seal}`);
    }
    expect(founderArt.size).toBe(3200);
    expect(allTraits.size).toBe(3200);
  });

  it("falls back cleanly when database query throws", async () => {
    const client: PgClient = {
      async connect() {},
      async query() {
        throw new Error("relation app.harness_members does not exist");
      },
      async end() {}
    };
    const env = {
      ...baseEnv,
      HYPERDRIVE: { connectionString: "postgres://stub" } as Hyperdrive,
      pgClientFactory: () => client
    } as Env & PgEnv;
    expect(await ensureHarnessMemberProfile(env, "42", "rach@example.com")).toEqual({
      id: "42",
      email: "rach@example.com"
    });
  });

  it("serves GET /auth/me only with a valid bearer token", async () => {
    const unauthorized = await handleAuthRoute(
      new Request("https://edge.codegraff.com/auth/me"),
      baseEnv,
      new URL("https://edge.codegraff.com/auth/me")
    );
    expect(unauthorized?.status).toBe(401);

    const token = await issueToken(baseEnv, "42");
    const authed = await handleAuthRoute(
      new Request("https://edge.codegraff.com/auth/me", {
        headers: { authorization: `Bearer ${token}` }
      }),
      baseEnv,
      new URL("https://edge.codegraff.com/auth/me")
    );
    expect(authed?.status).toBe(200);
    expect(await authed?.json()).toEqual({ user: { id: "42" } });
  });

  it("deletes from app.harness_members during account purge", async () => {
    const calls: unknown[] = [];
    const client: PgClient = {
      async connect() {},
      async query(text, values) {
        calls.push({ text, values });
        return { rows: [], rowCount: 1 };
      },
      async end() {}
    };
    await deleteHarnessMember(
      {
        HYPERDRIVE: { connectionString: "postgres://stub" } as Hyperdrive,
        pgClientFactory: () => client
      },
      "42"
    );
    expect(calls).toEqual([
      { text: "DELETE FROM app.harness_members WHERE user_id = $1", values: ["42"] }
    ]);
  });
});
