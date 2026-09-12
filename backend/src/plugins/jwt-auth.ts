import fp from 'fastify-plugin';
import { createRemoteJWKSet, jwtVerify } from 'jose';
import type { FastifyPluginAsync, FastifyRequest, FastifyReply } from 'fastify';

declare module 'fastify' {
  interface FastifyRequest {
    user?: {
      sub: string;
      preferred_username: string;
      tenant_id: string;
    };
  }
  interface FastifyInstance {
    requireAuth: (req: FastifyRequest, reply: FastifyReply) => Promise<void>;
  }
}

const KEYCLOAK_URL = process.env.KEYCLOAK_URL!;

// Safe realm names only — prevents SSRF via a crafted iss claim
const REALM_RE = /^[a-z0-9][a-z0-9_-]*$/i;

// Cache one JWKSet per realm (each realm has its own signing key)
const jwksSets = new Map<string, ReturnType<typeof createRemoteJWKSet>>();

function getJWKSForRealm(realm: string): ReturnType<typeof createRemoteJWKSet> {
  if (!jwksSets.has(realm)) {
    const uri = new URL(`${KEYCLOAK_URL}/realms/${realm}/protocol/openid-connect/certs`);
    jwksSets.set(realm, createRemoteJWKSet(uri));
  }
  return jwksSets.get(realm)!;
}

function extractRealm(token: string): string | null {
  try {
    const payload = JSON.parse(
      Buffer.from(token.split('.')[1], 'base64url').toString(),
    ) as { iss?: string };
    const match = payload.iss?.match(/\/realms\/([^/]+)$/);
    return match?.[1] ?? null;
  } catch {
    return null;
  }
}

const jwtAuthPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.decorateRequest('user', null);

  fastify.decorate(
    'requireAuth',
    async (req: FastifyRequest, reply: FastifyReply): Promise<void> => {
      const auth = req.headers.authorization;
      if (!auth?.startsWith('Bearer ')) {
        reply.status(401).send({ error: 'Missing Bearer token' });
        return;
      }
      const token = auth.slice(7);

      const realm = extractRealm(token);
      if (!realm || !REALM_RE.test(realm)) {
        reply.status(401).send({ error: 'Malformed token issuer' });
        return;
      }

      // Prevent SSRF: issuer must come from our known Keycloak instance
      const expectedIssPrefix = `${KEYCLOAK_URL}/realms/`;
      try {
        const rawPayload = JSON.parse(
          Buffer.from(token.split('.')[1], 'base64url').toString(),
        ) as { iss?: string };
        if (!rawPayload.iss?.startsWith(expectedIssPrefix)) {
          reply.status(401).send({ error: 'Untrusted token issuer' });
          return;
        }
      } catch {
        reply.status(401).send({ error: 'Malformed token' });
        return;
      }

      try {
        const jwks = getJWKSForRealm(realm);
        const { payload } = await jwtVerify(token, jwks, {
          issuer: `${KEYCLOAK_URL}/realms/${realm}`,
        });
        req.user = {
          sub: payload.sub as string,
          preferred_username: (payload as Record<string, unknown>).preferred_username as string ?? '',
          tenant_id: realm,
        };
      } catch {
        reply.status(401).send({ error: 'Invalid or expired token' });
      }
    },
  );
};

export default fp(jwtAuthPlugin);
