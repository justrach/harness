/** Harness access tokens are short-lived JWTs issued after CodeGraff OAuth. */
import { SignJWT, jwtVerify } from "jose";
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

/** Bind CodeGraff's rotating refresh token to the identity verified at exchange. */
export const issueRefreshCredential = async (
  env: Env, userId: string, codegraffRefreshToken: string
): Promise<string> => {
  const key = signingKey(env);
  if (!key) throw new Error("HARNESS_AUTH_SIGNING_KEY is not configured");
  const jwt = await new SignJWT({ codegraff_refresh_token: codegraffRefreshToken })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuer(ISSUER)
    .setAudience(REFRESH_AUDIENCE)
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime("30d")
    .sign(key);
  return `harness_rt_${jwt}`;
};

export const verifyRefreshCredential = async (
  env: Env, credential: string
): Promise<{ userId: string; codegraffRefreshToken: string } | undefined> => {
  const key = signingKey(env);
  if (!key || !credential.startsWith("harness_rt_")) return undefined;
  try {
    const { payload } = await jwtVerify(credential.slice("harness_rt_".length), key, {
      issuer: ISSUER,
      audience: REFRESH_AUDIENCE,
      algorithms: ["HS256"]
    });
    if (typeof payload.sub !== "string" || !payload.sub ||
        typeof payload.codegraff_refresh_token !== "string" ||
        !payload.codegraff_refresh_token.startsWith("cg_rt_")) return undefined;
    return { userId: payload.sub, codegraffRefreshToken: payload.codegraff_refresh_token };
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
