/** Harness access tokens are short-lived JWTs issued after CodeGraff OAuth. */
import { EncryptJWT, SignJWT, jwtDecrypt, jwtVerify, type JWTPayload } from "jose";
import type { Env } from "./env";

export interface Verified {
  readonly userId: string;
  readonly sessionId?: string;
  readonly orgId?: string;
}

const ISSUER = "https://edge.codegraff.com";
const AUDIENCE = "harness-edge";
const REFRESH_AUDIENCE = "harness-edge-refresh";

const signingKey = (env: Env): Uint8Array | undefined => {
  const value = env.HARNESS_AUTH_SIGNING_KEY;
  return value && value.length >= 32 ? new TextEncoder().encode(value) : undefined;
};

export const personalOrgId = (userId: string): string => `user-${userId}`;

export const issueToken = async (env: Env, userId: string): Promise<string> => {
  const key = signingKey(env);
  if (!key) throw new Error("HARNESS_AUTH_SIGNING_KEY is not configured");
  return new SignJWT({ org_id: personalOrgId(userId) })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime("55m")
    .sign(key);
};

// Shipped engines keep a stored session only if its refresh token starts with
// `harness_rt_`, so the prefix stays; the body's shape tells the formats
// apart (compact JWE has five segments, the legacy signed JWT three).
const REFRESH_PREFIX = "harness_rt_";
const segments = (token: string): number => token.split(".").length;

/** The refresh credential carries CodeGraff's refresh token, so it is
 * encrypted (JWE dir + A256GCM), not just signed: a signed JWT exposes the
 * token to anyone who reads the credential. The key is derived from the
 * signing secret under its own HKDF label so the two uses never share a key. */
const refreshEncryptionKey = async (env: Env): Promise<Uint8Array | undefined> => {
  const secret = signingKey(env);
  if (!secret) return undefined;
  const base = await crypto.subtle.importKey("raw", secret, "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: new TextEncoder().encode("harness-refresh-v2") },
    base,
    256
  );
  return new Uint8Array(bits);
};

const refreshClaims = (payload: JWTPayload) => {
  if (typeof payload.sub !== "string" || !payload.sub ||
      typeof payload.codegraff_refresh_token !== "string" ||
      !payload.codegraff_refresh_token.startsWith("cg_rt_")) return undefined;
  return { userId: payload.sub, codegraffRefreshToken: payload.codegraff_refresh_token };
};

/** Bind CodeGraff's rotating refresh token to the identity verified at exchange. */
export const issueRefreshCredential = async (
  env: Env, userId: string, codegraffRefreshToken: string
): Promise<string> => {
  const key = await refreshEncryptionKey(env);
  if (!key) throw new Error("HARNESS_AUTH_SIGNING_KEY is not configured");
  const jwe = await new EncryptJWT({ codegraff_refresh_token: codegraffRefreshToken })
    .setProtectedHeader({ alg: "dir", enc: "A256GCM" })
    .setIssuer(ISSUER)
    .setAudience(REFRESH_AUDIENCE)
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime("30d")
    .encrypt(key);
  return `${REFRESH_PREFIX}${jwe}`;
};

export const verifyRefreshCredential = async (
  env: Env, credential: string
): Promise<{ userId: string; codegraffRefreshToken: string } | undefined> => {
  if (!credential.startsWith(REFRESH_PREFIX)) return undefined;
  const body = credential.slice(REFRESH_PREFIX.length);
  try {
    if (segments(body) === 5) {
      const key = await refreshEncryptionKey(env);
      if (!key) return undefined;
      const { payload } = await jwtDecrypt(body, key, {
        issuer: ISSUER,
        audience: REFRESH_AUDIENCE,
        keyManagementAlgorithms: ["dir"],
        contentEncryptionAlgorithms: ["A256GCM"]
      });
      return refreshClaims(payload);
    }
    // Legacy signed credentials stay valid for one more refresh so existing
    // sign-ins are not dropped; the refresh rotates the CodeGraff token they
    // carry and returns an encrypted credential in their place.
    if (segments(body) === 3) {
      const key = signingKey(env);
      if (!key) return undefined;
      const { payload } = await jwtVerify(body, key, {
        issuer: ISSUER,
        audience: REFRESH_AUDIENCE,
        algorithms: ["HS256"]
      });
      return refreshClaims(payload);
    }
    return undefined;
  } catch {
    return undefined;
  }
};

export const bearerFromRequest = (request: Request): string | undefined => {
  const header = request.headers.get("authorization");
  if (header?.toLowerCase().startsWith("bearer ")) return header.slice(7).trim();
  return new URL(request.url).searchParams.get("token") ?? undefined;
};

export const verifyToken = async (env: Env, token: string): Promise<Verified | undefined> => {
  if (env.AUTH_MODE === "dev") {
    if (!token) return undefined;
    const at = token.indexOf("@");
    if (at > 0) return { userId: token.slice(0, at), orgId: token.slice(at + 1) };
    return { userId: token };
  }
  const key = signingKey(env);
  if (!key) return undefined;
  try {
    const { payload } = await jwtVerify(token, key, {
      issuer: ISSUER,
      audience: AUDIENCE,
      algorithms: ["HS256"]
    });
    if (typeof payload.sub !== "string" || !payload.sub) return undefined;
    return {
      userId: payload.sub,
      orgId: typeof payload.org_id === "string" ? payload.org_id : undefined
    };
  } catch {
    return undefined;
  }
};

export const authenticate = async (env: Env, request: Request): Promise<Verified | undefined> => {
  const token = bearerFromRequest(request);
  return token ? verifyToken(env, token) : undefined;
};
