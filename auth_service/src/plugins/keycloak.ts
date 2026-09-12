import { fetch } from 'undici';
import type { KeycloakTokenResponse } from '../types/keycloak.js';

const KEYCLOAK_URL = process.env.KEYCLOAK_URL!;
const CLIENT_ID = process.env.KEYCLOAK_CLIENT_ID!;
const CLIENT_SECRET = process.env.KEYCLOAK_CLIENT_SECRET!;

// Only allow realm names that are safe to interpolate into URLs
const STORE_CODE_RE = /^[a-z0-9][a-z0-9_-]*$/i;

function assertStoreCode(storeCode: string): void {
  if (!storeCode || !STORE_CODE_RE.test(storeCode)) {
    throw { status: 400, error: 'invalid_store_code', error_description: 'Store code must contain only letters, numbers, hyphens, and underscores' };
  }
}

async function keycloakPost(url: string, params: Record<string, string>): Promise<KeycloakTokenResponse> {
  const body = new URLSearchParams({
    client_id: CLIENT_ID,
    client_secret: CLIENT_SECRET,
    ...params,
  });
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: body.toString(),
  });
  const json = await res.json() as any;
  if (!res.ok) throw { status: res.status, error: json.error, error_description: json.error_description };
  return json as KeycloakTokenResponse;
}

export async function keycloakLogin(
  storeCode: string,
  username: string,
  password: string,
): Promise<KeycloakTokenResponse> {
  assertStoreCode(storeCode);
  return keycloakPost(
    `${KEYCLOAK_URL}/realms/${storeCode}/protocol/openid-connect/token`,
    { grant_type: 'password', username, password, scope: 'openid' },
  );
}

export async function keycloakRefresh(
  storeCode: string,
  refreshToken: string,
): Promise<KeycloakTokenResponse> {
  assertStoreCode(storeCode);
  return keycloakPost(
    `${KEYCLOAK_URL}/realms/${storeCode}/protocol/openid-connect/token`,
    { grant_type: 'refresh_token', refresh_token: refreshToken },
  );
}

export async function keycloakLogout(storeCode: string, refreshToken: string): Promise<void> {
  assertStoreCode(storeCode);
  const url = `${KEYCLOAK_URL}/realms/${storeCode}/protocol/openid-connect/logout`;
  const body = new URLSearchParams({
    client_id: CLIENT_ID,
    client_secret: CLIENT_SECRET,
    refresh_token: refreshToken,
  });
  // Best-effort: ignore errors so logout always succeeds from the client's perspective
  await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: body.toString(),
  }).catch(() => undefined);
}

export async function keycloakUserInfo(storeCode: string, accessToken: string): Promise<unknown> {
  assertStoreCode(storeCode);
  const res = await fetch(
    `${KEYCLOAK_URL}/realms/${storeCode}/protocol/openid-connect/userinfo`,
    { headers: { Authorization: `Bearer ${accessToken}` } },
  );
  if (!res.ok) throw { status: res.status };
  return res.json();
}
