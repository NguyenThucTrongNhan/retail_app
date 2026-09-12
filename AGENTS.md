# AGENTS.md — Retail POS App

Agent guide for the **offline-first retail point-of-sale** mobile app.
Read this before touching any file. It captures conventions, API contracts, and hard-won gotchas that are not visible from the code alone.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Repository Layout](#2-repository-layout)
3. [Tech Stack & Why](#3-tech-stack--why)
4. [Mobile — Flutter](#4-mobile--flutter)
5. [Backend — Fastify](#5-backend--fastify)
6. [Vision Service — FastAPI + CLIP](#6-vision-service--fastapi--clip)
7. [Running the Stack Locally](#7-running-the-stack-locally)
8. [Resolved Concerns (Do Not Re-Litigate)](#8-resolved-concerns-do-not-re-litigate)
9. [Known Bugs Fixed](#9-known-bugs-fixed)
10. [Planned Features (Not Yet Implemented)](#10-planned-features-not-yet-implemented)
11. [Commit & Doc Conventions](#11-commit--doc-conventions)
12. [File Cross-Reference](#12-file-cross-reference)

---

## 1. Project Overview

A retail store with ~5,000 products needs:
- Offline-first mobile catalog that works without Wi-Fi
- Delta sync when Wi-Fi is available
- Barcode scan for fast item lookup
- "Google Lens"-style visual price lookup (point camera at unlabelled item)
- Inline price/stock editing with offline queue

**Three services talk to each other:**

```
Mobile (Flutter/Isar) ←──pull/push──→ Backend (Fastify/PostgreSQL/pgvector)
                                                 ↑
                                       Vision (FastAPI/CLIP)
                                       embeds product images → stores in pgvector
                                       searches → cosine distance query
```

---

## 2. Repository Layout

```
retail_app/
├── AGENTS.md                          ← you are here
├── mobile/                            ← Flutter app
│   ├── lib/
│   │   ├── main.dart                  ← entry point, 5-tab nav, CatalogSearch, BasketCalc, SyncControl
│   │   ├── config/
│   │   │   └── app_config.dart        ← type-safe wrappers for all Isar-backed settings
│   │   ├── models/
│   │   │   ├── product.dart           ← Isar collection (5 k items)
│   │   │   ├── category.dart          ← Isar collection (synced from backend)
│   │   │   ├── sync_metadata.dart     ← Isar key-value store (config + sync state)
│   │   │   └── sync_outbox.dart       ← offline edit queue
│   │   ├── screens/
│   │   │   ├── visual_search_screen.dart  ← camera viewfinder + CLIP search UI
│   │   │   └── settings_screen.dart       ← all app settings (server IP, theme, etc.)
│   │   ├── services/
│   │   │   ├── database_helper.dart   ← Isar singleton; all DB calls go here
│   │   │   └── sync_service.dart      ← pull + push orchestrator
│   │   └── widgets/
│   │       └── barcode_scanner_modal.dart ← camera scanner + USB keyboard fallback
│   ├── pubspec.yaml
│   └── android/, ios/, web/           ← platform shells (do not edit manually)
│
├── backend/                           ← Node.js + Fastify
│   ├── src/
│   │   ├── server.ts                  ← Fastify app: routes, DB pool, static serving
│   │   └── seed.ts                    ← generate 5,000 test products
│   ├── init-scripts/
│   │   └── 01_init.sql                ← PostgreSQL schema (run once on DB init)
│   ├── scripts/
│   │   ├── local_db_setup.sql         ← manual local dev setup helper
│   │   └── create_vector_index.sql    ← HNSW index (run after ≥ 50 embeddings)
│   ├── uploads/                       ← product images (served at /static/images/)
│   ├── .env                           ← PORT, HOST, DATABASE_URL
│   ├── docker-compose.yml
│   └── package.json
│
├── vision_service/                    ← Python + FastAPI + CLIP
│   ├── main.py                        ← routes, CLIP model, pgvector search
│   └── requirements.txt
│
├── docs/
│   ├── concerns_and_decisions.md      ← C/B/F-series tracker (append-only)
│   ├── issue_log.md                   ← dev issues log (append-only)
│   ├── manual/
│   │   ├── human_verify.md            ← manual QA checklist
│   │   └── dev_setup.md               ← initial dev environment guide
│   └── *.pdf / *.txt                  ← architecture reference
│
└── scripts/
    └── fix_pub_deps.ps1               ← patches isar_flutter_libs build.gradle for AGP compat
```

---

## 3. Tech Stack & Why

| Layer | Technology | Why chosen |
|---|---|---|
| Mobile | Flutter 3.x | Better SQLite, camera, ARM compilation vs React Native |
| Local DB | Isar 3.x | Web (IndexedDB) support, bulk import < 400 ms, no sqflite web crash (C1) |
| Backend | Node.js + Fastify | Low overhead, `@fastify/postgres` pool, native async |
| DB | PostgreSQL 16 + pgvector | SQL reliability + vector similarity in one engine |
| Vision | Python FastAPI + CLIP | `clip-vit-base-patch32` is small (350 MB), runs on CPU |
| Dev env | Flutter SDK on `D:\Mobile_dev\flutter`, backend+vision in WSL2 or local |

---

## 4. Mobile — Flutter

### 4.1 Navigation

Five-tab `NavigationBar` (bottom). Order is fixed — do not reorder without updating `IndexedStack`:

| Index | Tab | Screen class | File |
|---|---|---|---|
| 0 | Catalog | `CatalogSearchScreen` | `main.dart` |
| 1 | Lens Search | `VisualSearchScreen` | `screens/visual_search_screen.dart` |
| 2 | Calculator | `BasketCalculatorScreen` | `main.dart` |
| 3 | Sync | `SyncControlScreen` | `main.dart` |
| 4 | Settings | `SettingsScreen` | `screens/settings_screen.dart` |

Shared basket state lives in `_MainNavigationScreenState._basket: List<Product>` and is passed as a constructor parameter to Catalog, VisualSearch, and Calculator screens.

Theme mode is lifted to `_RetailAppState._themeMode` and passed down via `onThemeChanged` callback. Changing the theme in Settings calls this callback immediately — no restart needed.

### 4.2 Isar Models

> **CRITICAL — Isar 3.x pluralization rule:**
> Isar appends a literal `s` to collection names. It does NOT do English pluralization.
> | Model | Accessor |
> |---|---|
> | `Product` | `isar.products` |
> | `Category` | `isar.categorys` (NOT `categories`) |
> | `SyncMetadata` | `isar.syncMetadatas` |
> | `SyncOutbox` | `isar.syncOutboxs` (NOT `syncOutboxes`) |

#### Product (`mobile/lib/models/product.dart`)
```dart
@collection
class Product {
  Id isarId = Isar.autoIncrement;   // internal; never expose to backend

  @Index(unique: true, replace: true)
  late String id;                   // UUID — upsert key for putAllByIndex('id', ...)

  @Index()
  late String sku;                  // e.g. "SKU-00001"

  @Index(type: IndexType.value, caseSensitive: false)
  late String name;                 // indexed for sub-10ms name search

  String? categoryId;
  late double price;
  late int stockQuantity;

  @Index()
  String? barcode;                  // exact-match only (barcode scan)

  String? imageUrl;                 // served by backend /static/images/
  late int version;
  late String updatedAt;            // ISO 8601
}
```

Upsert: `isar.products.putAllByIndex('id', products)` inside a `writeTxn`.
Search: `filter().nameContains(q, caseSensitive: false).or().skuContains(...).or().barcodeEqualTo(barcode)`.

#### Category (`mobile/lib/models/category.dart`)
```dart
@collection
class Category {
  Id isarId = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String id;                   // UUID

  late String name;
  late String updatedAt;
  bool isDeleted = false;
}
```

Categories are **read-only on mobile** — never edited, only synced from the backend.

#### SyncMetadata (`mobile/lib/models/sync_metadata.dart`)
Key-value store. Do not access directly; use `AppConfig` or `DatabaseHelper.getMetaValue/setMetaValue`.

```dart
@collection
class SyncMetadata {
  Id isarId = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String key;    // the setting name

  late String value;  // always stored as a String; AppConfig parses on read
}
```

**All known metadata keys:**

| Key | Default | Type (after parse) | Owner |
|---|---|---|---|
| `server_ip` | `"localhost"` | String | AppConfig |
| `store_name` | `""` | String | AppConfig |
| `currency_symbol` | `"$"` | String | AppConfig |
| `theme_mode` | `"system"` | `ThemeMode` (`"light"/"dark"/"system"`) | AppConfig |
| `products_per_page` | `"30"` | int | AppConfig |
| `auto_sync_on_start` | `"false"` | bool | AppConfig |
| `last_synced_version` | `"0"` | int | SyncService |
| `last_synced_timestamp` | `null` | ISO 8601 String | SyncService |

#### SyncOutbox (`mobile/lib/models/sync_outbox.dart`)
Offline edit queue. One entry per product edit.

```dart
@collection
class SyncOutbox {
  Id isarId = Isar.autoIncrement;   // insertion order = edit order

  late String productId;            // UUID of edited product
  double? newPrice;
  int? newStockQuantity;
  late DateTime createdAt;

  int retries = 0;                  // incremented on each failed push
  bool failed = false;              // set true when retries >= 3 — stops retry loop
}
```

**Deduplication on push:** `SyncService._flushOutbox()` builds `Map<String, SyncOutbox>` keyed by `productId`. For the same product edited multiple times, the last entry (highest `isarId`) wins.

### 4.3 AppConfig (`mobile/lib/config/app_config.dart`)

Static-only class. All calls are `async` because they hit Isar.

```dart
// Server URLs (both derived from server_ip)
AppConfig.getServerIp()         → Future<String>
AppConfig.setServerIp(ip)       → Future<void>
AppConfig.syncBaseUrl()         → Future<String>  // "http://<ip>:8080/api/v1"
AppConfig.visionBaseUrl()       → Future<String>  // "http://<ip>:8081"

// Store profile
AppConfig.getStoreName()        → Future<String>
AppConfig.setStoreName(name)    → Future<void>
AppConfig.getCurrencySymbol()   → Future<String>
AppConfig.setCurrencySymbol(s)  → Future<void>

// Appearance
AppConfig.getThemeMode()        → Future<ThemeMode>
AppConfig.setThemeMode(mode)    → Future<void>
AppConfig.getProductsPerPage()  → Future<int>     // 20 | 30 | 50
AppConfig.setProductsPerPage(n) → Future<void>

// Sync
AppConfig.getAutoSyncOnStart()  → Future<bool>
AppConfig.setAutoSyncOnStart(v) → Future<void>
```

### 4.4 DatabaseHelper (`mobile/lib/services/database_helper.dart`)

Singleton accessed via `DatabaseHelper.instance`. All public methods return `Future<T>`.

Key methods:

```dart
// Meta (AppConfig / SyncService use these)
getMetaValue(String key)  → Future<String?>
setMetaValue(String key, String value)  → Future<void>

// Sync operations
bulkImport({productsJson, categoriesJson, latestVersion, syncTimestamp})
applyDelta({updatedProducts, deletedProductIds, updatedCategories, deletedCategoryIds, latestVersion, syncTimestamp})

// Search (used by CatalogSearchScreen)
searchProducts(String query, {int limit = 30, int offset = 0})  → Future<List<Product>>
// query="" → all products (paginated)
// query non-empty → name LIKE OR sku LIKE OR barcode EXACT

// Local edit (Catalog inline edit)
updateProductLocally(String id, double price, int stock)
// atomically: update product + write outbox entry

// Outbox
getPendingOutbox()                      → Future<List<SyncOutbox>>
clearOutboxItems(List<Id> isarIds)      → Future<void>
incrementOutboxRetry(Id id)             → Future<void>

// Stats (Sync Control screen)
getProductCount()           → Future<int>
getLastSyncedVersion()      → Future<int>
getLastSyncedTimestamp()    → Future<String?>

// Destructive (Settings > Clear local data)
clearLocalData()            → Future<void>   // deletes products + categorys collections
```

> **Generated files:** `*.g.dart` files next to every model are auto-generated. Never edit them.
> Regenerate after any model change:
> ```powershell
> cd mobile
> flutter pub run build_runner build --delete-conflicting-outputs
> ```

### 4.5 SyncService (`mobile/lib/services/sync_service.dart`)

```dart
SyncService({ required String baseUrl })
// baseUrl = AppConfig.syncBaseUrl() value, e.g. "http://192.168.1.50:8080/api/v1"

performSync() → Future<SyncResult>
// 1. Read last_synced_version and last_synced_timestamp from Isar
// 2. GET <baseUrl>/sync/pull?since_version=V&since_timestamp=T
// 3. If v==0 → bulkImport; else → applyDelta
// 4. Flush outbox → POST <baseUrl>/sync/push
// Returns: SyncResult { itemsReceived, outboxFlushed, latestVersion, wasInitialImport }
```

Timeouts: 30 s pull, 15 s push.

### 4.6 Screens Summary

**CatalogSearchScreen** (`main.dart`)
- Real-time search by name/SKU/barcode
- Infinite scroll pagination; page size read from `AppConfig.getProductsPerPage()` on `initState`
- Tap row → edit modal (price + stock inline); edit calls `DatabaseHelper.updateProductLocally`
- Barcode scanner icon → `BarcodeScannerModal` bottom sheet
- Products added to basket via `+` button

**VisualSearchScreen** (`screens/visual_search_screen.dart`)
- Camera viewfinder via `camera` package (physical device only)
- FAB captures still image → multipart POST to `/api/v1/search/visual?top_k=3`
- Shows top match in bottom sheet; tap "Add to Total" adds to basket
- Gracefully shows "No camera detected" on web/emulator

**BasketCalculatorScreen** (`main.dart`)
- In-memory basket passed from `MainNavigationScreen`
- Running total = sum of `product.price`
- Badge on Calculator tab shows item count
- Basket cleared on app restart (not persisted to Isar — F3 feature)

**SyncControlScreen** (`main.dart`)
- Shows local product count, last synced version, pending outbox count
- "Run Sync Now" button calls `SyncService.performSync()`

**SettingsScreen** (`screens/settings_screen.dart`)
- Five sections: Store Profile, Server, Sync, Appearance, About
- Test Connection hits `http://<ip>:8080/health`
- Theme change calls `onThemeChanged` callback → immediately applies to `MaterialApp`
- Clear local data requires confirmation dialog → calls `DatabaseHelper.clearLocalData()`

**BarcodeScannerModal** (`widgets/barcode_scanner_modal.dart`)
- Mobile: `MobileScanner` viewfinder (ML Kit, `DetectionSpeed.noDuplicates`)
- Web/desktop: keyboard listener accumulates chars < 20 ms apart → treats as USB scanner input

### 4.7 pubspec.yaml — Dependencies

```yaml
isar: ^3.1.0
isar_flutter_libs: ^3.1.0    # native binaries (Android/iOS)
path_provider: ^2.1.0        # app documents dir (native only)
http: ^1.2.0                 # sync + vision HTTP calls
camera: ^0.10.5+9            # visual search viewfinder
mobile_scanner: ^5.1.1       # barcode (ML Kit, Android/iOS)
cupertino_icons: ^1.0.6
```

After `flutter pub get`, run `scripts/fix_pub_deps.ps1` to patch `isar_flutter_libs` `build.gradle` for Android Gradle Plugin compatibility (adds `namespace`, bumps `compileSdkVersion 35`, `minSdkVersion 21`).

---

## 5. Backend — Fastify

### 5.1 Environment

```
PORT=8080
HOST=0.0.0.0
DATABASE_URL=postgres://shop_admin:LocalShopSecretPassword123!@localhost:5432/retail_store
```

### 5.2 PostgreSQL Schema (`backend/init-scripts/01_init.sql`)

Extensions required:
```sql
CREATE EXTENSION IF NOT EXISTS vector;       -- pgvector
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";  -- uuid_generate_v4()
```

Global sequence:
```sql
CREATE SEQUENCE IF NOT EXISTS product_change_seq START 1;
-- Monotonic version counter. Every product UPDATE auto-increments this via trigger.
```

**categories table:**
```sql
CREATE TABLE categories (
    id         UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    name       VARCHAR(100) NOT NULL,
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    is_deleted BOOLEAN      NOT NULL DEFAULT FALSE
);
CREATE INDEX idx_categories_sync_timestamp ON categories (updated_at);
```

**products table:**
```sql
CREATE TABLE products (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    sku             VARCHAR(50)   UNIQUE NOT NULL,
    name            VARCHAR(255)  NOT NULL,
    category_id     UUID          REFERENCES categories(id) ON DELETE SET NULL,
    price           NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    stock_quantity  INT           NOT NULL DEFAULT 0,
    barcode         VARCHAR(100),
    image_url       TEXT,
    image_embedding vector(512),           -- CLIP embedding (512-d)
    version         BIGINT        NOT NULL DEFAULT nextval('product_change_seq'),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    is_deleted      BOOLEAN       NOT NULL DEFAULT FALSE
);
CREATE INDEX idx_products_sync_version   ON products (version);
CREATE INDEX idx_products_sync_timestamp ON products (updated_at);
```

**Trigger** — fires on every `UPDATE products`:
```sql
-- Auto-bumps version and updated_at; mobile sees these on next delta pull
CREATE TRIGGER trg_products_sync_metadata
BEFORE UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION update_product_sync_metadata();
```

> **HNSW index** — NOT in `01_init.sql`. Build it only after ≥ 50 products have embeddings.
> Run `backend/scripts/create_vector_index.sql` or call `POST /api/v1/admin/create-vector-index`.

### 5.3 API Routes (`backend/src/server.ts`)

#### Health
```
GET /health
  → 200 { status: "ok" }

GET /health/db
  → 200 { status: "ok", database: "connected" }
  → 503 if PostgreSQL unreachable
```

#### Pull (Mobile → gets changes)
```
GET /api/v1/sync/pull?since_version=<n>&since_timestamp=<iso8601>

Query params:
  since_version  (required) — 0 for first sync, else last known version
  since_timestamp (optional, ISO 8601) — used for category delta filter (C8)
  limit           (optional, default+max 5000)

Behavior:
  since_version == 0 → return all products + all categories
  since_version  > 0 → products WHERE version > since_version
                        categories WHERE updated_at > since_timestamp (or all if no timestamp)

Response shape:
{
  "sync_timestamp": "2026-09-10T12:30:00Z",
  "latest_version": 5000,
  "has_more": false,
  "changes": {
    "products": {
      "updated": [ { id, sku, name, category_id, price, stock_quantity, barcode,
                     image_url, version, updated_at, is_deleted }, ... ],
      "deleted_ids": [ "uuid", ... ]    // products where is_deleted = true since last sync
    },
    "categories": {
      "updated": [ { id, name, updated_at, is_deleted }, ... ],
      "deleted_ids": [ "uuid", ... ]
    }
  }
}
```

#### Push (Mobile → sends offline edits)
```
POST /api/v1/sync/push
Content-Type: application/json

Body:
{
  "client_id": "pos-mobile-01",
  "changes": {
    "products": [
      { "id": "<uuid>", "price": 12.50, "stock_quantity": 20 }
    ]
  }
}

Behavior:
  Runs inside a transaction.
  UPDATE products SET price=$, stock_quantity=$ WHERE id=$
  Trigger auto-bumps version + updated_at.

Response:
{
  "status": "success",
  "processed_at": "2026-09-10T12:30:00Z",
  "results": {
    "products": [
      { "id": "<uuid>", "status": "applied", "version": 5001, "updated_at": "..." }
    ]
  },
  "conflicts": []
}

Errors:
  400 — no products in changes
  500 — DB error (transaction rolled back)
```

#### Static images
```
GET /static/images/<filename>
  Served from backend/uploads/
  Product image_url format: "http://<ip>:8080/static/images/SKU-00001.jpg"
```

### 5.4 Seed Script

```powershell
cd backend
npm run seed:db
# Truncates products + categories, inserts 8 categories + 5,000 products.
# SKU-00001 → SKU-05000, barcodes 893000000001–893000005000, prices $0.99–$48.99
```

---

## 6. Vision Service — FastAPI + CLIP

### 6.1 Setup & Model

```python
# HuggingFace cache redirected to D: (C: space constraint)
os.environ.setdefault("HF_HOME", r"D:\hf_cache")

model = CLIPModel.from_pretrained("openai/clip-vit-base-patch32")  # 350 MB
processor = CLIPProcessor.from_pretrained("openai/clip-vit-base-patch32")
# Runs on GPU if available, else CPU
```

**Startup warmup (C7):** On FastAPI `startup` event, a 224×224 blank image is passed through the model to JIT-compile PyTorch. This prevents a 5–15 s delay on the first real request.

### 6.2 requirements.txt

```
fastapi==0.110.0
uvicorn[standard]==0.28.0
psycopg2-binary==2.9.9
pgvector==0.2.5
torch==2.2.1
transformers==4.38.2
Pillow==10.2.0
python-multipart==0.0.9
numpy<2          # torch 2.2.1 is incompatible with numpy ≥ 2.x — keep this pin
```

### 6.3 Embed Helper

```python
def embed(image: Image.Image) -> List[float]:
    # Returns 512-d L2-normalized CLIP vector
    inputs = processor(images=image, return_tensors="pt").to(device)
    with torch.no_grad():
        features = model.get_image_features(**inputs)
        features = features / features.norm(dim=-1, keepdim=True)
    return features.cpu().numpy()[0].tolist()
```

### 6.4 API Routes (`vision_service/main.py`)

#### Health
```
GET /health
→ 200 { "status": "ready", "device": "cpu", "model": "openai/clip-vit-base-patch32" }
```

#### Visual Search
```
POST /api/v1/search/visual?top_k=3
Content-Type: multipart/form-data
Field: "file" (image file)

SQL:
  SELECT id, sku, name, price, stock_quantity, image_url,
         1 - (image_embedding <=> %s::vector) AS confidence
  FROM products
  WHERE image_embedding IS NOT NULL AND is_deleted = FALSE
  ORDER BY image_embedding <=> %s::vector ASC
  LIMIT %s;

Response:
{
  "status": "success",
  "search_time_ms": 125.45,
  "matches": [
    { "id": "<uuid>", "sku": "SKU-00001", "name": "...", "price": 12.50,
      "stock_quantity": 42, "image_url": "...", "confidence": 0.87 },
    ...
  ]
}

Note: confidence = 1 - cosine_distance (higher = better).
Only products with image_embedding IS NOT NULL are searchable.
```

#### Embed Single Product (Admin)
```
POST /api/v1/products/{product_id}/embed
Content-Type: multipart/form-data
Field: "file" (image file)

→ 200 { "status": "success", "product": { "id", "sku", "name" } }
→ 404 if product_id not found
```

#### Create HNSW Index (Admin)
```
POST /api/v1/admin/create-vector-index

Checks that ≥ 50 products have embeddings first.
Creates: CREATE INDEX ... USING hnsw (image_embedding vector_cosine_ops) WITH (m=16, ef_construction=64)

→ 200 { "status": "success", "message": "...", "embedding_count": N }
→ 400 if < 50 embeddings exist
```

---

## 7. Running the Stack Locally

### Prerequisites
- Flutter SDK at `D:\Mobile_dev\flutter` (not C:)
- Node.js ≥ 18 LTS
- Python ≥ 3.10
- PostgreSQL ≥ 14 with pgvector extension

### Terminal 1 — PostgreSQL
```powershell
# If using local install: ensure pg service is running
# If using Docker (from backend/):
docker-compose up -d
```

### Terminal 2 — Backend (Fastify, port 8080)
```powershell
cd backend
npm install
npm run seed:db      # one-time: 5,000 products
npm run dev
# verify: curl http://localhost:8080/health
```

### Terminal 3 — Vision Service (port 8081)
```powershell
cd vision_service
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
pip install "numpy<2" --upgrade --no-cache-dir   # re-pin after install
uvicorn main:app --host 0.0.0.0 --port 8081 --reload
# verify: curl http://localhost:8081/health
```

### Terminal 4 — Flutter (mobile app)
```powershell
cd mobile
flutter pub get
..\scripts\fix_pub_deps.ps1   # patch isar_flutter_libs for AGP compat
flutter pub run build_runner build --delete-conflicting-outputs
flutter run                    # Android device/emulator
# or: flutter run -d chrome    # Web
```

### Android Emulator: set server IP to `10.0.2.2`
### Physical device on LAN: set server IP to the PC's LAN IP (e.g. `192.168.1.50`)
### Same machine / web: leave as `localhost`

---

## 8. Resolved Concerns (Do Not Re-Litigate)

These decisions are closed. If you believe one needs revisiting, open a new entry in `docs/concerns_and_decisions.md` rather than reverting silently.

| ID | Decision | Files |
|---|---|---|
| **C1** | Replaced `sqflite` with **Isar 3.x** for web + speed | `pubspec.yaml`, all model files, `database_helper.dart` |
| **C2** | Added **SyncOutbox** collection with 3-retry cap | `sync_outbox.dart`, `database_helper.dart`, `sync_service.dart` |
| **C3** | **Category** Isar collection synced alongside products | `category.dart`, `database_helper.dart`, `sync_service.dart` |
| **C4** | `@fastify/static` serves `backend/uploads/` at `/static/images/` | `server.ts` |
| **C5** | **No HNSW index in init SQL** — build it only after ≥ 50 embeddings | `01_init.sql`, `create_vector_index.sql`, `main.py` |
| **C6** | **Dynamic server IP** in AppConfig — both API URLs derived from one IP | `app_config.dart`, `settings_screen.dart` |
| **C7** | **CLIP warmup** on startup with 224×224 blank image (not 1×1) | `vision_service/main.py` |
| **C8** | **`since_timestamp`** param on category pull query (not version sub-select) | `server.ts`, `sync_service.dart`, `database_helper.dart` |
| **C9** | Auth deferred — implement JWT before demo | — |
| **C10** | Always use VS Code on Windows; never edit files from WSL terminal directly | — |

---

## 9. Known Bugs Fixed

| ID | Bug | Fix location |
|---|---|---|
| **B1** | `server.ts` used `import.meta.url` to resolve uploads dir → broke Docker | `server.ts`: use `path.join(process.cwd(), 'uploads')` |
| **B2** | Category delta query missing `since_timestamp` param | Same as C8 |
| **B3** | `_flushOutbox` used `Map<String, dynamic>` → lost type info | `sync_service.dart`: changed to `Map<String, SyncOutbox>` |

---

## 10. Planned Features (Not Yet Implemented)

Use the F-series prefix when adding entries to `docs/concerns_and_decisions.md`.

| ID | Feature | Notes |
|---|---|---|
| **F1** | Staff authentication (JWT) | Needed before demo. Sync routes → `Authorization: Bearer <token>` header |
| **F2** | Dashboard screen | Sales count, revenue, low stock alerts — depends on F3 |
| **F3** | "Complete Sale" button | Records basket to backend `/api/v1/sales`, saves local `Sale` Isar record |

---

## 11. Commit & Doc Conventions

### Commit messages
```
[area] Short description (imperative, < 72 chars)

Optional body.

Co-Authored-By: Claude <noreply@anthropic.com>
```

Areas: `[mobile]`, `[backend]`, `[vision]`, `[docs]`, `[scripts]`, `[config]`

Example:
```
[mobile] Add Settings tab with theme and server config

Absorbs ConfigScreen into SettingsScreen. Theme mode is
now persisted in Isar and applied reactively via RetailApp state.
```

### `docs/concerns_and_decisions.md` — append-only
Never edit existing entries. Add updates in the **Update Log** block at the bottom of each entry. New concerns get the next C/B/F number.

### `docs/issue_log.md` — append-only
Same rule. New issues appended at the bottom with an incrementing `#NNN` ID.

### `*.g.dart` files
Never commit — they are in `.gitignore`. Regenerate locally with `build_runner`.

### `scripts/fix_pub_deps.ps1`
Run after every `flutter pub get` on a machine where `isar_flutter_libs` is freshly downloaded. The script is idempotent — safe to run multiple times.

---

## 12. File Cross-Reference

| Task | File(s) |
|---|---|
| Add a new Isar model | Create `mobile/lib/models/<name>.dart`, add to `DatabaseHelper._openIsar` schemas list, run `build_runner` |
| Add a new app setting | Add key constant + getter/setter to `app_config.dart`, wire UI in `settings_screen.dart` |
| Change sync API shape | `backend/src/server.ts` (route) + `mobile/lib/services/sync_service.dart` (client) |
| Add a new backend route | `backend/src/server.ts` |
| Add a new vision route | `vision_service/main.py` |
| Add a product field | `backend/init-scripts/01_init.sql` + `mobile/lib/models/product.dart` + `build_runner` |
| Debug sync issues | `docs/issue_log.md` → `mobile/lib/services/sync_service.dart` |
| Understand architecture decisions | `docs/concerns_and_decisions.md` |
| Manual QA | `docs/manual/human_verify.md` |
| Android emulator setup | `docs/FLUTTER-ANDROID-DEV-RUNBOOK.md`, `docs/FLUTTER-ANDROID-EMULATOR-SETUP-TROUBLESHOOTING.md` |
| Patch pub cache for AGP | `scripts/fix_pub_deps.ps1` |
