# Concerns, Decisions & Feature Tracker
## Retail MVP Mobile App

This document is the single source of truth for every concern raised during
design/review, every architectural decision made, and every planned feature.
Update it as the project evolves.

---

## How to read this document

| Symbol | Meaning |
|--------|---------|
| ✅ Done | Implemented and verified |
| 🔄 In progress | Work has started |
| 📋 Planned | Accepted, not yet implemented |
| ⏭ Skipped | Deliberately deferred or out of scope |
| ❌ Won't fix | Rejected with reason |

---

## Section 1 — Architecture Concerns (C-series)

Concerns raised before or during implementation, each with the decision taken.

---

### C1 — Web crash: sqflite does not support Flutter Web
**Raised by:** Architect review  
**Status:** ✅ Done

**Problem:** The original plan used `sqflite` which relies on native SQLite binaries.
Flutter Web (IndexedDB) is unsupported, causing a crash on first launch in Chrome.

**Decision:** Replace `sqflite` with **Isar 3.x**.
- Isar uses IndexedDB on web via a `kIsWeb` branch in `_openIsar()`
- Bulk import of 5,000 products in a single transaction takes < 400 ms
- Generated `.g.dart` files via `build_runner`

**Files changed:** `pubspec.yaml`, all model files, `database_helper.dart`

---

### C2 — Offline edits lost when server is unreachable
**Raised by:** Architect review  
**Status:** ✅ Done

**Problem:** Price/stock edits made while offline had no queue — they were
lost if the sync server could not be reached at save time.

**Decision:** Add a **SyncOutbox** Isar collection.
- Every local edit atomically saves to the product AND writes an outbox entry
- `SyncService._flushOutbox()` deduplicates by productId (last write wins)
- Max 3 retries per item; `failed = true` after 3 failures to stop infinite loops
- Flushed automatically at the end of every sync

**Files changed:** `sync_outbox.dart` (new model), `database_helper.dart`, `sync_service.dart`

---

### C3 — Categories never stored or synced locally
**Raised by:** Architect review  
**Status:** ✅ Done

**Problem:** The original sync only transferred products. Categories existed in
PostgreSQL but were never sent to the mobile device, making `category_id`
on products meaningless locally.

**Decision:** Add a **Category** Isar collection and include categories in
every sync operation (both `bulkImport` and `applyDelta`).

**Files changed:** `category.dart` (new model), `database_helper.dart`, `sync_service.dart`, `server.ts`

---

### C4 — Product images not served to the mobile app
**Raised by:** Architect review  
**Status:** ✅ Done

**Problem:** Product images were stored in `backend/uploads/` but no route
existed to serve them. `image_url` on products always resolved to a 404.

**Decision:** Register `@fastify/static` on the `/static/images/` prefix,
mounting `./uploads/`. Docker Compose mounts the same folder as a volume.

**Files changed:** `server.ts`, `docker-compose.yml`

---

### C5 — HNSW vector index created on empty embedding column
**Raised by:** Architect review  
**Status:** ✅ Done

**Problem:** The original `01_init.sql` created the pgvector HNSW index at
database init time. With zero embeddings the index is useless and the
`CREATE INDEX` raises a warning; it also blocks future index recreation.

**Decision:** Remove the HNSW index from `01_init.sql`. Provide instead:
- `backend/scripts/create_vector_index.sql` — guarded DO block; raises
  EXCEPTION if 0 embeddings, WARNING if < 50
- `POST /api/v1/admin/create-vector-index` endpoint in the vision service
  with the same embedding count guard

**Files changed:** `01_init.sql`, `create_vector_index.sql` (new), `vision_service/main.py`

---

### C6 — Two hardcoded URL constants for two different ports
**Raised by:** Architect review  
**Status:** ✅ Done

**Problem:** The app had separate hardcoded constants for the Fastify backend
(port 8080) and the Python vision service (port 8081). Staff had to know and
edit two values every time the shop PC's IP changed.

**Decision:** Store a single `server_ip` key in Isar SyncMetadata.
Both service URLs are derived automatically:
- Sync API → `http://<ip>:8080/api/v1`
- Vision AI → `http://<ip>:8081`

A **Config screen** (gear icon on Sync tab) lets staff enter the IP once,
test the connection, and save. Defaults to `localhost` for local dev.

**Files changed:** `app_config.dart` (new), `config_screen.dart` (new),
`main.dart`, `visual_search_screen.dart`, `sync_service.dart`

---

### C7 — CLIP cold-start penalty (~10 s on CPU) with no user feedback
**Raised by:** Architect review  
**Status:** ✅ Done

**Problem:** The first visual search request after service startup triggered
PyTorch JIT compilation, causing a 5–15 second delay with no indication to
the user that anything was happening.

**Decision:**
1. Add `@app.on_event("startup")` warmup: embed a 1×1 blank PIL image on
   service start so JIT is compiled before any real request arrives
2. Add `GET /health` endpoint returning `device`, `model`, `status`
3. Show "First search may take 5–15 s on CPU" subtitle in the camera UI

**Files changed:** `vision_service/main.py`, `visual_search_screen.dart`

---

### C8 — Category delta query used a fragile version sub-select
**Raised by:** Architect review  
**Status:** ✅ Done

**Problem:** The category sync query used:
```sql
WHERE updated_at > (SELECT updated_at FROM products WHERE version = $1 LIMIT 1)
```
This sub-select can return NULL when no product exactly matches that version,
silently returning all categories on every delta sync.

**Decision:** Pass `since_timestamp` (the ISO 8601 timestamp returned by the
previous sync) as a separate query parameter. The category query becomes:
```sql
WHERE $1 = 0 OR updated_at > $2::timestamptz
```
The mobile app stores and sends this timestamp on every subsequent sync.

**Files changed:** `server.ts`, `sync_service.dart`, `database_helper.dart`

---

### C9 — No authentication on any endpoint
**Raised by:** Architect review  
**Status:** 📋 Planned — implement before demo

**Problem:** All sync endpoints are completely open. Any device on the LAN
can read all 5,000 products or push arbitrary price changes.

**Decision:** Add JWT-based staff authentication.
- `POST /api/v1/auth/register` and `POST /api/v1/auth/login`
- Middleware guard on all `/sync/` routes
- Token stored in Isar SyncMetadata on mobile
- `LoginScreen` shown on first launch if no token is stored

**Scope:** Backend `auth.ts`, SQL migration `02_auth.sql`,
mobile `auth_service.dart`, `login_screen.dart`, `main.dart` update

---

### C10 — WSL terminal used directly instead of VS Code integrated terminal
**Raised by:** Developer (nhan.nguyen)  
**Status:** ⏭ Skipped — dev workflow decision, not a code change

**Decision:** All terminal commands run through VS Code's integrated terminal
on Windows. Never open a raw WSL2 shell window directly. This avoids
path separator confusion and keeps tooling consistent.

---

## Section 2 — Bugs Found in Code Review (B-series)

---

### B1 — Wrong static files path in server.ts
**Found during:** Code review (Session 1)  
**Status:** ✅ Fixed

**Bug:** `path.join(__dirname, '../../uploads')` resolves two directories
above `src/`, landing outside the project entirely.

**Fix:** Use `path.join(process.cwd(), 'uploads')`.
`process.cwd()` returns `backend/` when `npm run dev` is invoked from there.
Removed the now-unused `fileURLToPath` import and `__dirname` declaration.

**File:** `backend/src/server.ts`

---

### B2 — Category delta query (same root cause as C8)
**Found during:** Code review (Session 1)  
**Status:** ✅ Fixed (resolved by C8)

---

### B3 — Type bug in SyncService._flushOutbox
**Found during:** Code review (Session 1)  
**Status:** ✅ Fixed

**Bug:** `_flushOutbox()` used `Map<String, dynamic>` to deduplicate outbox
entries by productId. Dart's type system allowed silent downcasting that could
lose the `SyncOutbox` object fields at runtime.

**Fix:** Changed to `Map<String, SyncOutbox>` for full type safety.

**File:** `mobile/lib/services/sync_service.dart`

---

## Section 3 — Planned Features (F-series)

Features accepted by the developer but not yet implemented.

---

### F1 — Staff Authentication (login / register)
**Requested by:** Developer  
**Status:** 📋 Planned  
**Priority:** High — required before any external demo

**Scope:**
- `backend/init-scripts/02_auth.sql` — `staff` table
- `backend/src/auth.ts` — register, login, JWT sign/verify, route middleware
- `mobile/lib/services/auth_service.dart` — HTTP calls + token storage
- `mobile/lib/screens/login_screen.dart` — email + password form
- `mobile/lib/main.dart` — check for stored token on startup

**Notes:** JWT with refresh tokens. Token stored in Isar SyncMetadata.
Every sync HTTP request adds `Authorization: Bearer <token>` header.

---

### F2 — Dashboard Screen (Tab 0)
**Requested by:** Developer  
**Status:** 📋 Planned  
**Priority:** Medium — useful for demo, required for go-live

**Scope:**
| Card | Source |
|------|--------|
| Sales today (count + revenue) | `sales` table, `created_at >= today` |
| Low stock alerts | Local Isar: `stock_quantity < 5` |
| Inventory value | Local: `SUM(price × stock_quantity)` |
| Sync health | Last sync timestamp + pending outbox count |

**Dependency:** Requires F3 (transaction recording) for the sales cards
to have data.

**Files needed:**
- `backend/init-scripts/03_sales.sql`
- `backend/src/sales.ts` (`POST /api/v1/sales`, `GET /api/v1/dashboard`)
- `mobile/lib/models/sale.dart`
- `mobile/lib/screens/dashboard_screen.dart`
- `mobile/lib/main.dart` — add Tab 0, shift existing tabs right

---

### F3 — Complete Sale Button + Transaction Recording
**Requested by:** Developer  
**Status:** 📋 Planned  
**Priority:** Medium — dependency for F2 dashboard data

**Problem:** The basket currently calculates a running total but discards it
when cleared. No sales history is recorded.

**Decision:** Add a **Complete Sale** button below the basket total.
- Records the sale to the backend (`POST /api/v1/sales`)
- Saves a local Isar `Sale` record for offline history
- Original trash-icon clear remains for abandoned/cancelled baskets

**Files changed:** `main.dart` (BasketCalculatorScreen), new `sale.dart` model

---

## Section 4 — Architectural Decisions Log

Quick reference for decisions that are not tied to a specific concern.

| # | Decision | Reason | Date |
|---|----------|--------|------|
| D1 | Flutter over React Native | Faster SQLite/Isar bulk import, direct ARM compilation, better camera package ecosystem | Session 1 |
| D2 | Isar 3.x over sqflite | Web support (IndexedDB), single-transaction bulk import < 400 ms, no raw SQL | Session 1 |
| D3 | Fastify over Express | Built-in TypeScript types, plugin ecosystem (`@fastify/postgres`), 2× throughput | Session 1 |
| D4 | pgvector over Qdrant/FAISS | Single container handles both relational and vector search; no extra service | Session 1 |
| D5 | CLIP clip-vit-base-patch32 | 512-d vectors, runs on CPU, good accuracy for product photos | Session 1 |
| D6 | Version sequence + timestamp dual-key sync | Version for products (monotonic, gap-safe); timestamp for categories (no sequence trigger) | Session 1 |
| D7 | Isar collection naming: literal 's' append | Isar 3.x does NOT English-pluralise — `isar.categorys`, `isar.syncOutboxs` | Session 1 |

---

## Section 5 — Out of Scope for MVP

Items explicitly deferred to post-MVP phases per customer brief.

| Feature | Reason deferred |
|---------|----------------|
| Tax calculation | Customer said "MVP first, tax later" |
| Full bill / receipt printing | Post-MVP phase |
| Inventory management (reorder, supplier) | Post-MVP phase |
| Multi-user concurrent edit conflict resolution | Single-device MVP scope |
| Image upload UI in mobile app | Embedding done via curl/admin tools for now |
| Push notifications (price change alerts) | Post-MVP |
| Customer-facing display screen | Post-MVP |

---

## Update Log

> **Rule:** Never edit the sections above. When any item changes status, append a new row here.
> Format: `YYYY-MM-DD | ID | From → To | Note`

| Date | Item | Status change | Note |
|------|------|--------------|------|
| 2026-09-07 | C1 | — → ✅ Done | Isar replaces sqflite; `kIsWeb` branch for IndexedDB |
| 2026-09-07 | C2 | — → ✅ Done | SyncOutbox model + `_flushOutbox()` with 3-retry cap |
| 2026-09-07 | C3 | — → ✅ Done | Category Isar model; included in bulkImport and applyDelta |
| 2026-09-07 | C4 | — → ✅ Done | `@fastify/static` on `/static/images/`; uploads volume in docker-compose |
| 2026-09-07 | C5 | — → ✅ Done | HNSW removed from init SQL; guarded admin endpoint in vision service |
| 2026-09-07 | B1 | — → ✅ Fixed | `process.cwd()` replaces `__dirname` in server.ts |
| 2026-09-07 | B3 | — → ✅ Fixed | `Map<String, SyncOutbox>` in `_flushOutbox()` |
| 2026-09-07 | C6 | — → ✅ Done | AppConfig + ConfigScreen; single IP derives both ports |
| 2026-09-07 | C7 | — → ✅ Done | Startup warmup + `/health` endpoint + UI warmup note |
| 2026-09-07 | C8 | — → ✅ Done | `since_timestamp` param; category SQL uses `updated_at > $2::timestamptz` |
| 2026-09-07 | B2 | — → ✅ Fixed | Resolved as part of C8 |
| 2026-09-08 | F1 | — → 📋 Planned | JWT auth accepted; implementation deferred |
| 2026-09-08 | F2 | — → 📋 Planned | Dashboard screen accepted; depends on F3 |
| 2026-09-08 | F3 | — → 📋 Planned | Complete Sale button accepted; dependency for F2 sales cards |
