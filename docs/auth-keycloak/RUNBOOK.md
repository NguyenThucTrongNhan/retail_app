# Auth & Multi-Tenant — Pre-Test Runbook

This document covers what was implemented, what remains to be done manually,
and the step-by-step test procedure before going to production.

---

## Dev Environment

**Current setup (as of 2026-09-11):**
- Keycloak: Docker (WSL) — admin console at `http://localhost:9090`
- Main Backend: Docker (WSL) — reached via Nginx
- Auth Service: Docker (WSL) — reached via Nginx
- PostgreSQL: Windows host — `localhost:5432`
- Vision Service: Windows host — `localhost:8081`
- Mobile: Android emulator → server URL `http://10.0.2.2:8080`

Start dev stack: `docker compose -f docker-compose.dev.yml up --build`

---

## Implementation Status

### Done ✅

| # | Item | Files |
|---|------|-------|
| 1 | DB migration — `tenant_id` columns + indexes | `backend/migrations/02_add_tenant_id.sql` |
| 2 | Auth service — Fastify :8082 with Keycloak ROPC proxy | `auth_service/src/**` |
| 3 | Backend JWT plugin — multi-tenant JWKS validation (`jose`) | `backend/src/plugins/jwt-auth.ts` |
| 4 | Backend sync routes guarded with `preHandler: requireAuth` | `backend/src/server.ts` |
| 5 | Backend sync queries filter by `tenant_id` | `backend/src/server.ts` |
| 6 | Seed script accepts `--tenant <store_code>` | `backend/src/seed.ts` |
| 7 | Mobile `AuthService` — login / refresh / logout / token storage | `mobile/lib/services/auth_service.dart` |
| 8 | Mobile `LoginScreen` — Store Code + Username + Password | `mobile/lib/screens/login_screen.dart` |
| 9 | Mobile `AppConfig` — URL-based config (replaces IP:port) | `mobile/lib/config/app_config.dart` |
| 10 | Mobile `SyncService` — Bearer header on all HTTP requests | `mobile/lib/services/sync_service.dart` |
| 11 | Mobile `main.dart` — auth gate + logout callback wiring | `mobile/lib/main.dart` |
| 12 | Mobile `SettingsScreen` — Server URL field | `mobile/lib/screens/settings_screen.dart` |
| 13 | Android network security config (cleartext for dev IPs only) | `mobile/android/app/src/main/res/xml/network_security_config.xml` |
| 14 | Dev Docker Compose — Keycloak + Backend + Auth + Nginx (HTTP) | `docker-compose.dev.yml` |
| 15 | Dev Nginx config — HTTP-only, routes to Docker services + host vision | `nginx/nginx.dev.conf` |
| 16 | Backend dev Dockerfile — all deps + tsx watch + volume mount | `backend/Dockerfile.dev` |
| 17 | Auth service Dockerfile (prod) + Dockerfile.dev | `auth_service/Dockerfile`, `auth_service/Dockerfile.dev` |
| 18 | Auth service `.env` — Docker-internal Keycloak URL | `auth_service/.env` |
| 19 | Project root `.env` — shared Docker Compose secrets | `.env` |
| 20 | Production Docker Compose (all services + certbot) | `docker-compose.prod.yml` |
| 21 | Production Nginx config — HTTPS + path routing | `nginx/nginx.conf` |

### Pending — Manual Steps Required ⏳

| # | Item | Who | Notes |
|---|------|-----|-------|
| M1 | Apply DB migration to local PostgreSQL | Developer | `psql -d retail_store -f backend/migrations/02_add_tenant_id.sql` |
| M2 | Set `KEYCLOAK_CLIENT_SECRET` in project root `.env` | Developer | Copy from Keycloak after M3 |
| M3 | Keycloak: create realm per store | Developer | Start stack first, then see Keycloak Setup below |
| M4 | Re-seed with `--tenant` flag | Developer | Run from host: `cd backend && npm run seed:db -- --tenant <store_code>` |
| M5 | `flutter pub get` in mobile | Developer | Picks up `flutter_secure_storage` |
| M6 | Edit `nginx/nginx.conf` — replace `YOUR_DOMAIN_HERE` | Operator | Before VPS deploy only |

---

## Phase 1 — Keycloak Setup

Do this **before** starting any services. Verify with curl before writing any code.

### 1.1 Create a test realm

1. Open Keycloak Admin Console → `https://<keycloak-host>/admin`
2. Top-left dropdown → **Create realm**
3. Realm name: `store-hanoi` (use your actual store code — it becomes the `tenant_id`)
4. **Enabled: ON** → Create

### 1.2 Create realm roles

Under the `store-hanoi` realm:
- **Realm roles** → Create role → `pos-staff`
- **Realm roles** → Create role → `pos-manager`

### 1.3 Create the confidential client

1. **Clients** → Create client
2. Client ID: `pos-auth-service`
3. Client type: OpenID Connect
4. Next → **Client authentication: ON**, Authorization: OFF
5. Authentication flow: Enable **Direct access grants** only (uncheck Standard flow, Implicit)
6. Save
7. **Credentials** tab → Copy the generated **Client Secret**

### 1.4 Create a test user

1. **Users** → Add user → Username: `staff01` → Create
2. **Credentials** tab → Set password → `Staff01Pass!` → **Temporary: OFF** → Save
3. **Role mapping** → Assign role → `pos-staff`

### 1.5 Verify ROPC with curl

```bash
# Replace with your actual values
KC_URL="https://<keycloak-host>"
SECRET="<client-secret-from-step-1.3>"

curl -X POST "$KC_URL/realms/store-hanoi/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=pos-auth-service" \
  -d "client_secret=$SECRET" \
  -d "username=staff01" \
  -d "password=Staff01Pass!" \
  -d "scope=openid"
```

**Expected:** HTTP 200 with JSON containing `access_token` and `refresh_token`

**Common failures:**
- `401 invalid_grant` → wrong credentials or user not in this realm
- `400 unauthorized_client` → Direct Access Grants not enabled on client
- Connection refused → wrong Keycloak URL or port

Also verify JWKS endpoint is reachable:
```bash
curl "$KC_URL/realms/store-hanoi/protocol/openid-connect/certs"
# Expected: {"keys":[...]} with at least one RS256 entry
```

---

## Phase 2 — Database Migration

```bash
# From the retail_app root, apply migration to local dev DB
psql -U shop_admin -d retail_store \
  -f backend/migrations/02_add_tenant_id.sql

# Verify columns exist
psql -U shop_admin -d retail_store \
  -c "\d products" | grep tenant_id

# Re-seed for your test store (clears existing data for that tenant)
cd backend
npm install          # picks up jose + fastify-plugin
npm run seed:db -- --tenant store-hanoi
```

**Note:** If you have existing products with the old schema (no `tenant_id`), the migration
backfills them with `DEFAULT 'default'`. Those rows are only visible to a JWT from a realm
named `default`. Run `npm run seed:db -- --tenant <your_realm>` to create fresh test data.

---

## Phase 3 — Auth Service

```bash
cd auth_service
npm install

# Create .env from example
cp .env.example .env
# Edit .env — set:
#   KEYCLOAK_URL=https://<your-keycloak-host>
#   KEYCLOAK_CLIENT_SECRET=<from step 1.3>

npm run dev
# Expected: "Auth service ready on http://0.0.0.0:8082"
```

### Verify auth service endpoints

```bash
# Health
curl http://localhost:8082/health
# Expected: {"status":"ok"}

# Login
curl -X POST http://localhost:8082/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"store_code":"store-hanoi","username":"staff01","password":"Staff01Pass!"}'
# Expected: {"access_token":"...","refresh_token":"...","expires_in":300,"token_type":"Bearer"}

# Save the tokens:
TOKEN=$(curl -s -X POST http://localhost:8082/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"store_code":"store-hanoi","username":"staff01","password":"Staff01Pass!"}' \
  | jq -r .access_token)

REFRESH=$(curl -s -X POST http://localhost:8082/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"store_code":"store-hanoi","username":"staff01","password":"Staff01Pass!"}' \
  | jq -r .refresh_token)

# Me endpoint
curl http://localhost:8082/api/v1/auth/me \
  -H "Authorization: Bearer $TOKEN"
# Expected: {"sub":"...","preferred_username":"staff01",...}

# Refresh
curl -X POST http://localhost:8082/api/v1/auth/refresh \
  -H "Content-Type: application/json" \
  -d "{\"store_code\":\"store-hanoi\",\"refresh_token\":\"$REFRESH\"}"
# Expected: new access_token and refresh_token

# Logout
curl -X POST http://localhost:8082/api/v1/auth/logout \
  -H "Content-Type: application/json" \
  -d "{\"store_code\":\"store-hanoi\",\"refresh_token\":\"$REFRESH\"}"
# Expected: HTTP 204 No Content
```

---

## Phase 4 — Main Backend (with JWT Auth)

```bash
cd backend
# .env already has KEYCLOAK_URL placeholder — fill it in:
# KEYCLOAK_URL=https://<your-keycloak-host>

npm run dev
# Expected: server ready on :8080
```

### Verify JWT guarding

```bash
# No token → 401
curl http://localhost:8080/api/v1/sync/pull?since_version=0
# Expected: {"error":"Missing Bearer token"}

# Wrong token → 401
curl http://localhost:8080/api/v1/sync/pull?since_version=0 \
  -H "Authorization: Bearer garbage"
# Expected: {"error":"Invalid or expired token"}

# Valid token → 200 with only store-hanoi data
curl "http://localhost:8080/api/v1/sync/pull?since_version=0" \
  -H "Authorization: Bearer $TOKEN"
# Expected: 200 with products/categories (all tenant_id='store-hanoi')

# Health still open (no auth required)
curl http://localhost:8080/health
# Expected: {"status":"ok"}
```

### Verify tenant isolation (if you have a second tenant)

```bash
# Seed a second store
cd backend && npm run seed:db -- --tenant store-hcm

# In Keycloak, create realm 'store-hcm' with same client and a user

# Login as store-hcm staff
TOKEN_HCM=$(curl -s -X POST http://localhost:8082/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"store_code":"store-hcm","username":"staff01","password":"Staff01Pass!"}' \
  | jq -r .access_token)

# store-hcm token returns store-hcm products only
curl "http://localhost:8080/api/v1/sync/pull?since_version=0" \
  -H "Authorization: Bearer $TOKEN_HCM" | jq '.changes.products.updated | length'
# Expected: 5000 (store-hcm products)

# store-hanoi token returns store-hanoi products only
curl "http://localhost:8080/api/v1/sync/pull?since_version=0" \
  -H "Authorization: Bearer $TOKEN" | jq '.changes.products.updated | length'
# Expected: 5000 (store-hanoi products — different data set)

# Cross-tenant push attempt: store-hcm token, product ID from store-hanoi
curl -X POST http://localhost:8080/api/v1/sync/push \
  -H "Authorization: Bearer $TOKEN_HCM" \
  -H "Content-Type: application/json" \
  -d '{"client_id":"test","changes":{"products":[{"id":"<store-hanoi-product-id>","price":999}]}}'
# Expected: {"results":{"products":[{"id":"...","status":"not_found"}]}}
# The UPDATE includes AND tenant_id = 'store-hcm', so store-hanoi product is invisible
```

---

## Phase 5 — Mobile App

```bash
cd mobile
flutter pub get   # installs flutter_secure_storage
flutter run       # on Android emulator or physical device
```

### Manual test checklist

| # | Test | Expected Result |
|---|------|-----------------|
| T1 | Fresh install, launch app | LoginScreen shown (Store Code + Username + Password fields) |
| T2 | Wrong store code | Error message: "Invalid store code, username, or password." |
| T3 | Wrong password | Same error message |
| T4 | Correct credentials | Transition to MainNavigationScreen |
| T5 | Kill app and relaunch | LoginScreen NOT shown (token rehydrated from secure storage) |
| T6 | Go to Sync tab → Run Sync Now | Sync completes successfully (Bearer token sent) |
| T7 | Check sync data | Only this store's products are shown |
| T8 | Tap logout button (top-right of Sync tab) | LoginScreen shown |
| T9 | Relaunch after logout | LoginScreen shown (tokens cleared) |
| T10 | Settings tab → Server URL field | Shows URL (not IP), save/test connection works |
| T11 | Test Connection button | Shows "Server reachable" on success |

### Token expiry simulation

To test auto-refresh without waiting:
1. In Keycloak: Realm Settings → Tokens → set **Access Token Lifespan** to **1 minute**
2. Login on mobile
3. Wait 90 seconds (token expired, refresh still valid)
4. Tap Run Sync Now
5. Expected: sync succeeds silently (auto-refresh happened in background)
6. Reset token lifespan back to 5 minutes after testing

---

## Phase 6 — Production VPS Deploy

### Prerequisites
- VPS with Docker + Docker Compose installed
- Domain pointed to VPS IP (`A` record in DNS)
- Keycloak running (on same VPS or external)
- Port 80 and 443 open in firewall

### Steps

```bash
# 1. Clone repo to VPS
git clone <repo-url> /opt/retail_app
cd /opt/retail_app

# 2. Create production .env file
cat > .env <<EOF
POSTGRES_PASSWORD=<strong-random-password>
POSTGRES_USER=shop_admin
POSTGRES_DB=retail_store
KEYCLOAK_URL=https://<keycloak-host>
KEYCLOAK_CLIENT_ID=pos-auth-service
KEYCLOAK_CLIENT_SECRET=<from-keycloak-credentials-tab>
EOF

# 3. Replace domain in nginx.conf
sed -i 's/YOUR_DOMAIN_HERE/retail.yourdomain.com/g' nginx/nginx.conf

# 4. Issue Let's Encrypt certificate (HTTP must reach the server first)
# Temporarily allow HTTP in nginx.conf, then:
docker compose -f docker-compose.prod.yml run --rm certbot certonly \
  --webroot -w /var/www/certbot \
  -d retail.yourdomain.com \
  --email admin@yourdomain.com \
  --agree-tos --no-eff-email

# 5. Start all services
docker compose -f docker-compose.prod.yml up -d

# 6. Apply DB migration
docker compose -f docker-compose.prod.yml exec backend \
  sh -c "psql \$DATABASE_URL -f migrations/02_add_tenant_id.sql"

# 7. Seed first tenant
docker compose -f docker-compose.prod.yml exec backend \
  npm run seed:db -- --tenant store-hanoi

# 8. Verify
curl https://retail.yourdomain.com/health
# Expected: {"status":"ok"}
```

### Certificate renewal

The certbot container auto-renews every 12 hours. No manual action needed after initial setup.

---

## Known Limitations & Future Work

| Item | Notes |
|------|-------|
| Vision service has no auth | `/api/v1/search/*` is currently unprotected; add `requireAuth` to `vision_service/main.py` in a future iteration |
| No token revocation on backend | If a staff member is deleted from Keycloak, their existing access token is valid until expiry (max 5 min). Acceptable for this use case. |
| ROPC deprecation | RFC 9700 (OAuth 2.1) deprecates ROPC. Migrate to PKCE + flutter_appauth when Keycloak drops support. |
| Same client secret across realms | Currently all realms share one `KEYCLOAK_CLIENT_SECRET`. For higher security, use per-realm secrets stored in the auth service config. |
| No admin UI for tenant onboarding | Tenant creation is manual (Keycloak console + CLI seed). A future admin API could automate this. |
| Dev setup requires manual Nginx or direct ports | `AppConfig.authBaseUrl()` and `syncBaseUrl()` return the same base URL; in dev without Nginx, only `syncBaseUrl` (port 8080) is reachable. Use `docker compose -f docker-compose.prod.yml` locally for full integration. |
