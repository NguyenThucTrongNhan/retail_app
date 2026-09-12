# Architecture Decision Records — Keycloak Auth & Multi-Tenancy

---

## ADR-001: One Keycloak Realm Per Tenant

**Status:** Accepted
**Date:** 2026-09-11

### Context
Multiple stores (tenants) share a single backend. Authentication contexts must be isolated so a
staff member from Store A cannot log into Store B, even with the same username/password.

Three options were evaluated:
- Option A: One realm per tenant (store_code = realm name)
- Option B: Single realm with groups/organizations per tenant
- Option C: Single realm with custom `tenant_id` user attribute

### Decision
**Option A** — one Keycloak realm per tenant.

### Consequences
**Positive:**
- True isolation: credentials are scoped to the realm; no accidental cross-store login
- The JWT `iss` claim (`https://kc/realms/{realm}`) already contains the tenant identifier —
  no extra claim mapper or DB lookup needed
- Realm name = store code = tenant_id, a clean three-way equivalence
- Each store's token lifetimes, password policies, and MFA settings can differ

**Negative:**
- Admin must create a new realm for each store (mitigated: manual onboarding is the agreed model)
- The `pos-auth-service` confidential client and Client Secret must be recreated in each realm
- Keycloak console can become cluttered with many realms at large scale

---

## ADR-002: Resource Owner Password Credentials (ROPC) Grant

**Status:** Accepted
**Date:** 2026-09-11

### Context
The mobile app needs a login screen where retail staff enter credentials. Two flows were evaluated:
- ROPC: staff enter username + password directly; auth service exchanges credentials with Keycloak
- Authorization Code + PKCE: browser/in-app browser redirect to Keycloak login page

### Decision
**ROPC** via a confidential auth service that holds the client secret server-side.

### Consequences
**Positive:**
- Native username/password UX with a store code field — familiar for retail staff
- No external browser or redirect URI needed
- Client secret never leaves the auth service (mobile never sees it)
- Appropriate for internal staff app on managed/controlled devices

**Negative:**
- ROPC is deprecated in OAuth 2.1 and may be removed in future Keycloak versions
- If mobile app is ever distributed publicly, PKCE would be required

**Migration path:** If ROPC is retired, the auth service can be replaced with a PKCE flow
(using flutter_appauth on mobile) without touching the main backend or database.

---

## ADR-003: Dedicated Auth Microservice (not inline in main backend)

**Status:** Accepted
**Date:** 2026-09-11

### Context
Auth logic could have been added directly to `backend/src/server.ts`. A separate service
adds deployment complexity but has architectural benefits.

### Decision
New `auth_service/` — independent Fastify process on port 8082.

### Consequences
**Positive:**
- Main backend has zero knowledge of Keycloak URLs or client secrets
- Auth service can be updated or replaced independently (e.g., swap ROPC for PKCE)
- Scale auth and sync services independently under load
- Clear audit boundary: all credential-handling code is in one place

**Negative:**
- One more service to deploy, monitor, and restart
- Adds ~50ms latency for initial login (negligible; login is once per session)

---

## ADR-004: JWKS Validation on Main Backend (not introspection)

**Status:** Accepted
**Date:** 2026-09-11

### Context
Every sync request (pull/push) needs the token validated. Three options:
- **JWKS local validation:** backend fetches Keycloak public keys, verifies JWT signature locally
- **Introspection:** backend calls Keycloak's `/introspect` endpoint per request
- **Auth service proxy:** backend calls auth service to validate

### Decision
**JWKS local validation** using the `jose` library with in-memory key cache.

### Consequences
**Positive:**
- Stateless — no network call per sync request (keys cached per realm, refreshed automatically)
- Sub-millisecond token validation after initial JWKS fetch
- `jose` handles key rotation and cache invalidation transparently
- Works correctly for multiple realms (one JWKS set cached per realm name)

**Negative:**
- Backend needs `KEYCLOAK_URL` env var to construct JWKS URIs
- In the rare event Keycloak rotates signing keys, next request triggers a cache refresh
  (this is handled automatically by `jose`'s `createRemoteJWKSet`)

---

## ADR-005: tenant_id Column for Row-Level Data Isolation

**Status:** Accepted
**Date:** 2026-09-11

### Context
Two main isolation strategies were evaluated:
- **Separate PostgreSQL schemas** per tenant (`store_hanoi.products`, `store_hcm.products`)
- **Shared schema with tenant_id column** on all tables

### Decision
**Shared schema with `tenant_id` column** (`VARCHAR(50) NOT NULL DEFAULT 'default'`).

### Consequences
**Positive:**
- One database to backup, restore, monitor, and migrate
- Single `ALTER TABLE` migration adds isolation to existing data
- `tenant_id` = JWT realm name (no mapping table needed)
- Simpler application code: one connection pool, no schema-switching

**Negative:**
- Application-level enforcement only — a bug in a query could leak cross-tenant data
  (mitigated: all queries use parameterized `tenant_id = $1`, audited in code review)
- At very large scale (thousands of tenants, billions of rows) a separate DB per tenant
  would perform better — not a concern for this use case

---

## ADR-006: flutter_secure_storage for Token Persistence

**Status:** Accepted
**Date:** 2026-09-11

### Context
Access tokens and refresh tokens need to survive app restarts. The existing `SyncMetadata`
(Isar key-value store) was already used for non-sensitive config. Two options:
- Continue using Isar SyncMetadata for tokens (simpler, consistent)
- Use `flutter_secure_storage` backed by platform secure enclaves

### Decision
**flutter_secure_storage** for all auth tokens.

### Consequences
**Positive:**
- Tokens stored in Android Keystore / iOS Keychain — encrypted at rest by the OS
- Not accessible to other apps or via ADB backup
- Industry standard for mobile token storage

**Negative:**
- One additional pub dependency
- Requires `minSdkVersion 18` for Android (Flutter default ≥ 21, so no change needed)
- Token state is in two stores (Isar for config, secure storage for tokens) — acceptable
  given the clear security boundary

**Non-sensitive config** (server URL, store name, theme) remains in Isar SyncMetadata.

---

## ADR-007: Single Server URL via Nginx (replace IP:port config)

**Status:** Accepted
**Date:** 2026-09-11

### Context
The original app stored a server IP and derived two ports (8080 for sync, 8081 for vision).
For internet deployment, the new auth service adds port 8082. Three options:
- Extend the per-port model (three fields: sync URL, auth URL, vision URL)
- Use an Nginx reverse proxy with path-based routing behind a single domain
- Subdomain routing per service

### Decision
**Nginx with path-based routing** — single server URL, Nginx routes by path prefix.

### Consequences
**Positive:**
- One URL to configure in the mobile Settings screen
- TLS terminated once at Nginx — all internal services communicate over plain HTTP
- Easy to add rate limiting, logging, or a WAF at a single choke point
- Mobile `AppConfig` simplified: `syncBaseUrl()`, `authBaseUrl()`, `visionBaseUrl()` all
  return the same base URL; only the path differs

**Negative:**
- Local development without Nginx requires direct port connections
  (dev workaround: run `docker compose -f docker-compose.prod.yml` locally,
  or configure server URL as `http://10.0.2.2:8080` and bypass auth for dev)
- `nginx.conf` requires `YOUR_DOMAIN_HERE` to be replaced before first deploy
