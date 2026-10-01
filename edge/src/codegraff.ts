import { createRemoteJWKSet, jwtVerify } from "jose";
import { issueRefreshCredential, issueToken, personalOrgId, verifyRefreshCredential } from "./auth";
import type { Env } from "./env";

const ISSUER = "https://codegraff.com";
const TOKEN_URL = `${ISSUER}/api/oauth/token`;
const JWKS = createRemoteJWKSet(new URL(`${ISSUER}/.well-known/jwks.json`));
const REDIRECTS = new Set([
  "http://127.0.0.1:27643/callback",
  "https://edge.codegraff.com/auth/cli/callback",
  "https://edge.codegraff.com/auth/ios/callback"
]);

type TokenResponse = {
  access_token?: string;
  refresh_token?: string;
  id_token?: string;
};

export class CodegraffAuthFailed extends Error {}

/** CodeGraff could not answer (down, overloaded, unreachable). Says nothing about the credential:
 * callers must not treat it as a rejection, or a blip signs everyone out. */
export class CodegraffUnavailable extends Error {}

const tokenRequest = async (env: Env, values: Record<string, string>): Promise<TokenResponse> => {
  let response: Response;
  try {
    response = await fetch(TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: env.CODEGRAFF_OAUTH_CLIENT_ID, ...values })
    });
  } catch {
    throw new CodegraffUnavailable("CodeGraff could not be reached");
  }
  if (response.status >= 500 || response.status === 429) {
    throw new CodegraffUnavailable(`CodeGraff is unavailable (${response.status})`);
  }
  if (!response.ok) throw new CodegraffAuthFailed(`CodeGraff rejected the grant (${response.status})`);
  return response.json() as Promise<TokenResponse>;
};

export const exchange = async (
  env: Env,
  code: string,
  verifier: string,
  redirectUri: string,
  nonce: string
) => {
  if (!REDIRECTS.has(redirectUri)) throw new CodegraffAuthFailed("redirect URI is not allowed");
  if (!/^[A-Za-z0-9._~-]{43,128}$/.test(verifier) || !nonce) {
    throw new CodegraffAuthFailed("invalid PKCE verifier or nonce");
  }
  const token = await tokenRequest(env, {
    grant_type: "authorization_code",
    code,
    code_verifier: verifier,
    redirect_uri: redirectUri
  });
  if (!token.id_token || !token.refresh_token) throw new CodegraffAuthFailed("incomplete token response");
  const { payload } = await jwtVerify(token.id_token, JWKS, {
    issuer: ISSUER,
    audience: env.CODEGRAFF_OAUTH_CLIENT_ID,
    algorithms: ["ES256"]
  });
  if (payload.nonce !== nonce || typeof payload.sub !== "string" || !payload.sub ||
      typeof payload.email !== "string" || !payload.email) {
    throw new CodegraffAuthFailed("CodeGraff identity could not be verified");
  }
  return {
    user: { id: payload.sub, email: payload.email },
    accessToken: await issueToken(env, payload.sub),
    refreshToken: await issueRefreshCredential(env, payload.sub, token.refresh_token)
  };
};

/** CodeGraff's account deletion (the shared login's own endpoint). */
export const ACCOUNT_DELETE_URL = `${ISSUER}/api/account/delete`;

/** Swap a verified refresh credential for a CodeGraff access token. CodeGraff
 * rotates its refresh token on every use, so the caller also gets the
 * replacement Harness tokens: a request that stops before deleting anything
 * must hand them back, or the device is left holding a dead credential. */
export const codegraffAccess = async (env: Env, userId: string, codegraffRefreshToken: string) => {
  const token = await tokenRequest(env, { grant_type: "refresh_token", refresh_token: codegraffRefreshToken });
  if (!token.access_token || !token.refresh_token) throw new CodegraffAuthFailed("incomplete refresh response");
  return {
    codegraffAccessToken: token.access_token,
    tokens: {
      accessToken: await issueToken(env, userId),
      refreshToken: await issueRefreshCredential(env, userId, token.refresh_token)
    }
  };
};

export const refresh = async (env: Env, refreshToken: string, organizationId?: string) => {
  const credential = await verifyRefreshCredential(env, refreshToken);
  if (!credential) throw new CodegraffAuthFailed("invalid refresh credential");
  if (organizationId && organizationId !== personalOrgId(credential.userId)) {
    throw new CodegraffAuthFailed("workspace does not belong to this account");
  }
  const token = await tokenRequest(env, {
    grant_type: "refresh_token",
    refresh_token: credential.codegraffRefreshToken
  });
  if (!token.access_token || !token.refresh_token) {
    throw new CodegraffAuthFailed("incomplete refresh response");
  }
  return {
    accessToken: await issueToken(env, credential.userId),
    refreshToken: await issueRefreshCredential(env, credential.userId, token.refresh_token)
  };
};
