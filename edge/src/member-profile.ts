/**
 * Harness member card identity & join date (`app.harness_members` + `app.cg_auth_user`).
 *
 * CodeGraff accounts can predate Harness, so "when they started using Harness"
 * comes from the earliest Harness-specific record (`app.harness_members`, backfilled
 * by migration `0106_harness_members.sql` from Harness OAuth grants/keys/codes/
 * sandboxes, agent rooms, and mobile crash reports), while display name and avatar
 * come from `app.cg_auth_user` via `app.cg_auth_user_links`.
 */
import type { Env } from "./env";
import { withPg, type PgEnv } from "./pg";

export const HARNESS_OAUTH_CLIENT_ID = "cg_client_43e753878956c2cf7b5b0f53";
export const CURRENT_CARD_SCENES = 20;

export interface HarnessCardTraits {
  scene: number;
  sky: number;
  enso: number;
  holo: number;
  seal: number;
}

export interface HarnessMemberProfile {
  id: string;
  email?: string;
  name?: string;
  avatarUrl?: string;
  memberNumber?: number;
  startedAt?: number;
  cardScenes?: number;
  cardTraits?: HarnessCardTraits;
}

interface MemberQueryRow {
  email: string | null;
  name: string | null;
  avatar_url: string | null;
  member_number: string | number | null;
  started_at: string | number | null;
  card_scenes: string | number | null;
  card_scene?: string | number | null;
  card_sky?: string | number | null;
  card_enso?: string | number | null;
  card_holo?: string | number | null;
  card_seal?: string | number | null;
}

/** Exact cross-tier affine bijection over Z_3200 + Z_40 epoch folding (see migration 0107). */
export const deriveMemberCardTraits = (memberNumber: number): HarnessCardTraits => {
  const m0 = Math.max(0, Math.floor(memberNumber) - 1) % 128000;
  const epoch = Math.floor(m0 / 3200);
  const artIdx = (m0 * 1993 + 733) % 3200;
  const scene = artIdx % 20;
  const sky = (scene + (Math.floor(artIdx / 20) % 20)) % 20;
  const enso = Math.floor(artIdx / 400) % 8;
  const holo = (m0 * 3 + Math.floor(artIdx / 20) + 2 + epoch) % 5;
  const seal = (m0 * 5 + Math.floor(artIdx / 80) + 1 + Math.floor(epoch / 5)) % 8;
  return { scene, sky, enso, holo, seal };
};

const toInt = (value: unknown): number | undefined => {
  if (typeof value === "number" && Number.isSafeInteger(value)) return value;
  if (typeof value === "string" && /^-?\d+$/.test(value)) {
    const n = Number(value);
    if (Number.isSafeInteger(n)) return n;
  }
  return undefined;
};

const nonEmpty = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;

const MEMBER_PROFILE_PREFIX = `
WITH candidates AS (
  SELECT MIN(created_at) AS first_at
    FROM app.api_keys
   WHERE $1 ~ '^[0-9]+$'
     AND user_id = $1::bigint
     AND (oauth_client_id = $2 OR name = 'Harness' OR name LIKE 'Harness on %')
  UNION ALL
  SELECT MIN(created_at) AS first_at
    FROM app.oauth_consents
   WHERE $1 ~ '^[0-9]+$' AND user_id = $1::bigint AND client_id = $2
  UNION ALL
  SELECT MIN(created_at) AS first_at
    FROM app.oauth_refresh_tokens
   WHERE $1 ~ '^[0-9]+$' AND user_id = $1::bigint AND client_id = $2
  UNION ALL
  SELECT MIN(created_at) AS first_at
    FROM app.oauth_codes
   WHERE $1 ~ '^[0-9]+$' AND user_id = $1::bigint AND client_id = $2 AND consumed_at IS NOT NULL
  UNION ALL
  SELECT MIN(created_at) AS first_at
    FROM app.oauth_app_sandboxes
   WHERE $1 ~ '^[0-9]+$' AND user_id = $1::bigint AND client_id = $2
  UNION ALL
  SELECT MIN(created_at) AS first_at
    FROM app.agent_rooms
   WHERE created_by = $1
  UNION ALL
  SELECT MIN(received_at) AS first_at
    FROM app.harness_crash_reports
   WHERE user_id = $1
),
seed AS (
  SELECT COALESCE(
    CASE
      WHEN (SELECT created_at FROM app.users WHERE $1 ~ '^[0-9]+$' AND id = $1::bigint) IS NOT NULL
       AND MIN(c.first_at) IS NOT NULL
      THEN GREATEST(
        (SELECT created_at FROM app.users WHERE $1 ~ '^[0-9]+$' AND id = $1::bigint),
        MIN(c.first_at)
      )
      ELSE MIN(c.first_at)
    END,
    floor(extract(epoch FROM now()))::bigint
  ) AS started_at
  FROM candidates c
),`;

const MEMBER_PROFILE_SQL = `${MEMBER_PROFILE_PREFIX}
ensured AS (
  INSERT INTO app.harness_members (user_id, started_at, card_scenes)
  SELECT $1, s.started_at, $3 FROM seed s
  ON CONFLICT (user_id) DO UPDATE
    SET started_at = LEAST(app.harness_members.started_at, EXCLUDED.started_at),
        card_scenes = GREATEST(app.harness_members.card_scenes, EXCLUDED.card_scenes)
  RETURNING user_id, member_number, started_at, card_scenes,
            card_scene, card_sky, card_enso, card_holo, card_seal
)
SELECT COALESCE(NULLIF(btrim(u.email), ''), NULLIF(btrim(au.email), '')) AS email,
       NULLIF(btrim(au.name), '') AS name,
       NULLIF(btrim(au.image), '') AS avatar_url,
       e.member_number,
       e.started_at,
       e.card_scenes,
       e.card_scene,
       e.card_sky,
       e.card_enso,
       e.card_holo,
       e.card_seal
  FROM ensured e
  LEFT JOIN app.users u ON $1 ~ '^[0-9]+$' AND u.id = $1::bigint
  LEFT JOIN app.cg_auth_user_links l ON $1 ~ '^[0-9]+$' AND l.user_id = $1::bigint
  LEFT JOIN app.cg_auth_user au ON au.id = l.auth_user_id
 LIMIT 1`;

const LEGACY_MEMBER_PROFILE_SQL = `${MEMBER_PROFILE_PREFIX}
ensured AS (
  INSERT INTO app.harness_members (user_id, started_at, card_scenes)
  SELECT $1, s.started_at, $3 FROM seed s
  ON CONFLICT (user_id) DO UPDATE
    SET started_at = LEAST(app.harness_members.started_at, EXCLUDED.started_at)
  RETURNING user_id, member_number, started_at, card_scenes
)
SELECT COALESCE(NULLIF(btrim(u.email), ''), NULLIF(btrim(au.email), '')) AS email,
       NULLIF(btrim(au.name), '') AS name,
       NULLIF(btrim(au.image), '') AS avatar_url,
       e.member_number,
       e.started_at,
       e.card_scenes
  FROM ensured e
  LEFT JOIN app.users u ON $1 ~ '^[0-9]+$' AND u.id = $1::bigint
  LEFT JOIN app.cg_auth_user_links l ON $1 ~ '^[0-9]+$' AND l.user_id = $1::bigint
  LEFT JOIN app.cg_auth_user au ON au.id = l.auth_user_id
 LIMIT 1`;

const isUndefinedColumnError = (err: unknown): boolean =>
  typeof err === "object" &&
  err !== null &&
  "code" in err &&
  (err as { code?: unknown }).code === "42703";

const extractCardTraits = (row: MemberQueryRow, memberNumber?: number): HarnessCardTraits | undefined => {
  const scene = toInt(row.card_scene);
  const sky = toInt(row.card_sky);
  const enso = toInt(row.card_enso);
  const holo = toInt(row.card_holo);
  const seal = toInt(row.card_seal);
  if (
    scene !== undefined &&
    sky !== undefined &&
    enso !== undefined &&
    holo !== undefined &&
    seal !== undefined &&
    scene >= 0 &&
    sky >= 0 &&
    enso >= 0 &&
    holo >= 0 &&
    seal >= 0
  ) {
    return { scene, sky, enso, holo, seal };
  }
  return memberNumber !== undefined ? deriveMemberCardTraits(memberNumber) : undefined;
};

/** Ensure a Harness member row exists and return identity + join metadata. */
export const ensureHarnessMemberProfile = async (
  env: Env & PgEnv,
  userId: string,
  fallbackEmail?: string
): Promise<HarnessMemberProfile> => {
  const base: HarnessMemberProfile = {
    id: userId,
    ...(nonEmpty(fallbackEmail) ? { email: nonEmpty(fallbackEmail) } : {})
  };
  if (!env.HYPERDRIVE) return base;
  try {
    const params = [userId, HARNESS_OAUTH_CLIENT_ID, CURRENT_CARD_SCENES];
    const row = await withPg(env, async (pg) => {
      try {
        const res = await pg.query<MemberQueryRow>(MEMBER_PROFILE_SQL, params);
        return res.rows[0];
      } catch (err) {
        if (!isUndefinedColumnError(err)) throw err;
        const legacyRes = await pg.query<MemberQueryRow>(LEGACY_MEMBER_PROFILE_SQL, params);
        return legacyRes.rows[0];
      }
    });
    if (!row) return base;
    const email = nonEmpty(fallbackEmail) ?? nonEmpty(row.email);
    const name = nonEmpty(row.name);
    const avatarUrl = nonEmpty(row.avatar_url);
    const memberNumber = toInt(row.member_number);
    const startedAt = toInt(row.started_at);
    const cardScenes = toInt(row.card_scenes);
    const cardTraits = extractCardTraits(row, memberNumber);
    return {
      id: userId,
      ...(email ? { email } : {}),
      ...(name ? { name } : {}),
      ...(avatarUrl ? { avatarUrl } : {}),
      ...(memberNumber !== undefined ? { memberNumber } : {}),
      ...(startedAt !== undefined ? { startedAt } : {}),
      ...(cardScenes !== undefined ? { cardScenes } : {}),
      ...(cardTraits !== undefined ? { cardTraits } : {})
    };
  } catch (err) {
    console.warn(JSON.stringify({ event: "member_profile_fallback", error: String(err) }));
    return base;
  }
};

/** Account purge: remove the user's Harness member card record. */
export const deleteHarnessMember = (env: PgEnv, userId: string): Promise<void> =>
  withPg(env, async (pg) => {
    await pg.query("DELETE FROM app.harness_members WHERE user_id = $1", [userId]);
  });
