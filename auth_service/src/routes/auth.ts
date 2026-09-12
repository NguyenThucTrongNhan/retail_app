import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import {
  keycloakLogin,
  keycloakRefresh,
  keycloakLogout,
  keycloakUserInfo,
} from '../plugins/keycloak.js';

interface LoginBody   { store_code: string; username: string; password: string; }
interface RefreshBody { store_code: string; refresh_token: string; }
interface LogoutBody  { store_code: string; refresh_token: string; }

// Extract realm (store_code) from the iss claim of a raw JWT without verifying it.
// Used in GET /me where only the access token is available.
function realmFromToken(token: string): string | null {
  try {
    const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()) as { iss?: string };
    const match = payload.iss?.match(/\/realms\/([^/]+)$/);
    return match?.[1] ?? null;
  } catch {
    return null;
  }
}

export async function authRoutes(fastify: FastifyInstance): Promise<void> {
  // POST /api/v1/auth/login
  fastify.post<{ Body: LoginBody }>(
    '/api/v1/auth/login',
    async (req: FastifyRequest<{ Body: LoginBody }>, reply: FastifyReply) => {
      const { store_code, username, password } = req.body ?? {};
      if (!store_code || !username || !password) {
        return reply.status(400).send({ error: 'store_code, username and password are required' });
      }
      try {
        const tokens = await keycloakLogin(store_code, username, password);
        return reply.send({
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          expires_in: tokens.expires_in,
          token_type: 'Bearer',
        });
      } catch (err: any) {
        // 401 from Keycloak = invalid_grant (wrong credentials or user not in realm)
        const status = err.status === 401 || err.error === 'invalid_grant' ? 401
          : err.status === 400 ? 400
          : 502;
        return reply.status(status).send({
          error: err.error_description ?? err.error ?? 'Login failed',
        });
      }
    },
  );

  // POST /api/v1/auth/refresh
  fastify.post<{ Body: RefreshBody }>(
    '/api/v1/auth/refresh',
    async (req: FastifyRequest<{ Body: RefreshBody }>, reply: FastifyReply) => {
      const { store_code, refresh_token } = req.body ?? {};
      if (!store_code || !refresh_token) {
        return reply.status(400).send({ error: 'store_code and refresh_token are required' });
      }
      try {
        const tokens = await keycloakRefresh(store_code, refresh_token);
        return reply.send({
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          expires_in: tokens.expires_in,
          token_type: 'Bearer',
        });
      } catch (err: any) {
        // Any error from Keycloak on refresh = session expired → force re-login
        return reply.status(401).send({ error: 'Refresh token expired or invalid — please log in again' });
      }
    },
  );

  // POST /api/v1/auth/logout
  fastify.post<{ Body: LogoutBody }>(
    '/api/v1/auth/logout',
    async (req: FastifyRequest<{ Body: LogoutBody }>, reply: FastifyReply) => {
      const { store_code, refresh_token } = req.body ?? {};
      if (store_code && refresh_token) {
        await keycloakLogout(store_code, refresh_token);
      }
      return reply.status(204).send();
    },
  );

  // GET /api/v1/auth/me
  fastify.get(
    '/api/v1/auth/me',
    async (req: FastifyRequest, reply: FastifyReply) => {
      const auth = req.headers.authorization;
      if (!auth?.startsWith('Bearer ')) {
        return reply.status(401).send({ error: 'Bearer token required' });
      }
      const token = auth.slice(7);
      const storeCode = realmFromToken(token);
      if (!storeCode) {
        return reply.status(401).send({ error: 'Cannot determine store from token' });
      }
      try {
        const info = await keycloakUserInfo(storeCode, token);
        return reply.send(info);
      } catch (err: any) {
        return reply.status(err.status ?? 401).send({ error: 'Invalid or expired token' });
      }
    },
  );
}
