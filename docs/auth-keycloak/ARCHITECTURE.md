# Auth & Multi-Tenant Architecture

## Overview

The retail POS system is extended with Keycloak-based authentication and multi-tenant isolation,
deployed internet-facing on a VPS behind Nginx HTTPS.

Each store (tenant) is a separate Keycloak **realm**. The Store Code the staff enters at login
is the realm name. One shared PostgreSQL database stores all tenants' data, isolated by a
`tenant_id` column on every table that equals the realm name.

---

## Environments

| Service          | Local Dev (docker-compose.dev.yml)         | Production (docker-compose.prod.yml)     |
|------------------|--------------------------------------------|------------------------------------------|
| Keycloak         | Docker — internal `keycloak:8080`, admin at `localhost:9090` | External server (user-managed) |
| Main Backend     | Docker — `backend:8080` (internal)        | Docker                                   |
| Auth Service     | Docker — `auth_service:8082` (internal)   | Docker                                   |
| PostgreSQL       | **Windows host** — `host.docker.internal:5432` | Docker container                    |
| Nginx            | Docker — HTTP on host `:8080`             | Docker — HTTPS on host `:443`            |
| Vision Service   | Windows host — `localhost:8081`            | Docker                                   |
| Mobile URL       | `http://10.0.2.2:8080` (emulator)        | `https://yourdomain.com`                 |

---

## Dev Environment Diagram (docker-compose.dev.yml)

```
Android Emulator / Physical Device
  │  http://10.0.2.2:8080  (emulator)
  │  http://<LAN-IP>:8080  (physical device)
  │
  ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  Windows Host                                                                 │
│                                                                               │
│  PostgreSQL :5432  (local, unchanged)                                         │
│  Vision Service :8081  (local Python, unchanged)                             │
│                                                                               │
│  ┌──────────────────────────────────────────────────────────────────────┐    │
│  │  WSL2 / Docker                                                        │    │
│  │                                                                       │    │
│  │  Nginx :80  (host port 8080)                                          │    │
│  │   ├─ /api/v1/auth/*   ──► auth_service:8082                          │    │
│  │   ├─ /api/v1/sync/*   ──► backend:8080                               │    │
│  │   ├─ /api/v1/search/* ──► host.docker.internal:8081  (vision, local) │    │
│  │   └─ /health + /static ─► backend:8080                               │    │
│  │                                                                       │    │
│  │  backend:8080  ──► host.docker.internal:5432  (Windows PostgreSQL)   │    │
│  │  auth_service:8082  ──► keycloak:8080                                │    │
│  │  keycloak:8080  (host port 9090 for admin console)                   │    │
│  │                                                                       │    │
│  └──────────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Critical: JWT Issuer Consistency

Keycloak is configured with `KC_HOSTNAME=keycloak` so the JWT `iss` claim is always
`http://keycloak:8080/realms/{store_code}` — regardless of whether Keycloak is accessed
from within Docker (via `keycloak:8080`) or from the browser (via `localhost:9090`).

Both backend and auth_service use `KEYCLOAK_URL=http://keycloak:8080`, so the issuer
prefix check (`iss.startsWith(KEYCLOAK_URL + "/realms/")`) always passes.

---

## Component Diagram

```
Internet (HTTPS)
       │
       ▼
┌──────────────────────────────────────────────────────────┐
│  Nginx :443  (Let's Encrypt TLS, path-based routing)     │
│                                                          │
│  /api/v1/auth/*   ──► Auth Service    :8082  (Node.js)  │
│  /api/v1/sync/*   ──► Main Backend    :8080  (Node.js)  │
│  /api/v1/search/* ──► Vision Service  :8081  (Python)   │
│  /health          ──► Main Backend    :8080              │
│  /static/*        ──► Main Backend    :8080              │
└──────────────────────────────────────────────────────────┘
         │                   │                  │
         ▼                   ▼                  ▼
  ┌─────────────┐    ┌──────────────┐   ┌──────────────┐
  │  Keycloak   │    │  PostgreSQL  │   │  PostgreSQL  │
  │  (external) │    │  (shared DB) │   │  + pgvector  │
  │  one realm  │    │  tenant_id   │   │  (same DB)   │
  │  per store  │    │  on all rows │   │              │
  └─────────────┘    └──────────────┘   └──────────────┘

Mobile Flutter App
  └─ server_url: https://yourdomain.com  (single config)
  └─ tokens: flutter_secure_storage (Android Keystore / iOS Keychain)
```

---

## Login Flow

```
Mobile                   Auth Service (:8082)        Keycloak              Main Backend (:8080)
  │                              │                      │                         │
  │  POST /api/v1/auth/login     │                      │                         │
  │  {store_code, user, pass}    │                      │                         │
  │─────────────────────────────►│                      │                         │
  │                              │  POST /realms/       │                         │
  │                              │  {store_code}/token  │                         │
  │                              │  grant_type=password │                         │
  │                              │─────────────────────►│                         │
  │                              │                      │  200 access_token       │
  │                              │                      │  (JWT iss=.../store_X)  │
  │                              │◄─────────────────────│                         │
  │  200 {access_token,          │                      │                         │
  │       refresh_token,         │                      │                         │
  │       expires_in}            │                      │                         │
  │◄─────────────────────────────│                      │                         │
  │                              │                      │                         │
  │  flutter_secure_storage      │                      │                         │
  │  .write(tokens + store_code) │                      │                         │
```

## Sync Flow (authenticated)

```
Mobile                                                          Main Backend (:8080)     Keycloak
  │                                                                    │                    │
  │  AuthService.getValidAccessToken()                                 │                    │
  │  └─ if expired → POST /api/v1/auth/refresh → new tokens           │                    │
  │                                                                    │                    │
  │  GET /api/v1/sync/pull                                             │                    │
  │  Authorization: Bearer {access_token}                              │                    │
  │───────────────────────────────────────────────────────────────────►│                    │
  │                                                                    │  GET /realms/       │
  │                                                                    │  {realm}/certs      │
  │                                                                    │  (cached 5 min)     │
  │                                                                    │───────────────────►│
  │                                                                    │◄───────────────────│
  │                                                                    │                    │
  │                                                              jwtVerify(token, jwks)     │
  │                                                              req.user.tenant_id = realm │
  │                                                                    │                    │
  │                                                              SELECT ... FROM products   │
  │                                                              WHERE tenant_id = $1        │
  │                                                              AND version > $2            │
  │                                                                    │                    │
  │  200 {products, categories} (this tenant only)                     │                    │
  │◄───────────────────────────────────────────────────────────────────│                    │
```

## Token Refresh Flow

```
Mobile                     Auth Service (:8082)         Keycloak
  │                                │                       │
  │  AuthService.getValidAccessToken()                     │
  │  └─ _expiryMs < now            │                       │
  │                                │                       │
  │  POST /api/v1/auth/refresh     │                       │
  │  {store_code, refresh_token}   │                       │
  │───────────────────────────────►│                       │
  │                                │  POST /realms/        │
  │                                │  {store_code}/token   │
  │                                │  grant_type=          │
  │                                │  refresh_token        │
  │                                │──────────────────────►│
  │                                │◄──────────────────────│
  │  200 new {access_token,        │                       │
  │           refresh_token}       │                       │
  │◄───────────────────────────────│                       │
  │                                │                       │
  │  If 401 (refresh expired):     │                       │
  │  AuthService.clearTokens()     │                       │
  │  → show LoginScreen            │                       │
```

---

## Multi-Tenant Data Isolation

### Tenant Identification Chain

```
JWT access_token
  └─ payload.iss = "https://keycloak.example.com/realms/store-hanoi"
                                                         ├────────────┘
                                                         realm = "store-hanoi"
                                                                │
                                                         req.user.tenant_id
                                                                │
                                                    WHERE tenant_id = 'store-hanoi'
```

### Database Schema (relevant columns)

```sql
-- products
id         UUID PRIMARY KEY
tenant_id  VARCHAR(50) NOT NULL DEFAULT 'default'  -- e.g. 'store-hanoi'
sku, name, category_id, price, stock_quantity, barcode, image_url, version, ...

-- categories
id         UUID PRIMARY KEY
tenant_id  VARCHAR(50) NOT NULL DEFAULT 'default'
name, updated_at, is_deleted
```

All `SELECT`, `UPDATE`, `DELETE` on products and categories include `WHERE tenant_id = $1`.

---

## Keycloak Configuration Per Tenant

For each new store, repeat these steps in Keycloak Admin Console:

| Step | Action |
|------|--------|
| 1 | Create realm named exactly as the store code (e.g., `store-hanoi`) |
| 2 | Create realm roles: `pos-staff`, `pos-manager` |
| 3 | Create confidential client `pos-auth-service`, enable Direct Access Grants only |
| 4 | Copy Client Secret from Credentials tab → set in auth service `.env` |
| 5 | Create staff user accounts, assign roles, set non-temporary passwords |

All realms use the same `KEYCLOAK_CLIENT_ID=pos-auth-service` and
`KEYCLOAK_CLIENT_SECRET`. The auth service routes to the correct realm via the `store_code`
in the login request body.

---

## Security Controls

| Control | Implementation |
|---------|---------------|
| Token storage | flutter_secure_storage → Android Keystore / iOS Keychain |
| Token expiry | 30-second safety buffer before actual expiry |
| SSRF prevention | Auth service validates store_code: `[a-z0-9_-]+` only |
| SSRF prevention | Backend validates JWT issuer starts with `KEYCLOAK_URL` |
| Tenant isolation | All DB queries filter by `tenant_id` from JWT claim |
| Transport security | TLS 1.2/1.3 only in production; cleartext blocked on Android 9+ |
| Push isolation | UPDATE includes `AND tenant_id = $1` so cross-tenant writes are impossible |

---

## Directory Structure

```
retail_app/
├── auth_service/            NEW — auth microservice
│   ├── src/
│   │   ├── plugins/keycloak.ts   ROPC proxy to Keycloak
│   │   ├── routes/auth.ts        login / refresh / logout / me
│   │   └── server.ts             Fastify entry
│   ├── package.json
│   ├── tsconfig.json
│   └── .env.example
├── backend/
│   ├── src/
│   │   ├── plugins/jwt-auth.ts   NEW — multi-tenant JWKS validation
│   │   ├── server.ts             MODIFIED — guarded routes + tenant_id queries
│   │   └── seed.ts               MODIFIED — --tenant CLI arg
│   └── migrations/
│       └── 02_add_tenant_id.sql  NEW
├── mobile/
│   └── lib/
│       ├── config/app_config.dart        MODIFIED — URL-based config
│       ├── services/auth_service.dart    NEW — token management
│       ├── screens/login_screen.dart     NEW — Store Code + credentials
│       ├── screens/settings_screen.dart  MODIFIED — Server URL field
│       ├── services/sync_service.dart    MODIFIED — Bearer headers
│       └── main.dart                     MODIFIED — auth gate + logout
├── nginx/
│   └── nginx.conf               NEW — HTTPS reverse proxy
└── docker-compose.prod.yml      NEW — full production stack
```
