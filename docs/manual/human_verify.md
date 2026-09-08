# Human Verification Manual
## Retail MVP Mobile App — Full Stack Test Guide

This document walks a tester through verifying every layer of the application —
from raw API calls to mobile UI flows — against the original customer requirements.

**Customer requirements summary:**
- Offline-first catalog of ~5,000 products on a mobile device
- Delta sync: only changed records transferred after initial import
- Easy inline price and stock-quantity edits
- "Google Lens for the store" — point camera at unlabelled product, get price instantly
- Barcode scan to add products to a running basket total
- No full re-download unless necessary

---

## Part 0 — Environment Checklist

Before testing, confirm all services are healthy.

### Services required

| Service | Port | Start command (from project root) |
|---------|------|-----------------------------------|
| PostgreSQL | 5432 | `docker-compose up -d` (inside `backend/`) |
| Fastify backend | 8080 | `npm run dev` (inside `backend/`) |
| Python vision service | 8081 | `uvicorn main:app --host 0.0.0.0 --port 8081` (inside `vision_service/`) |
| Flutter app | browser | `flutter run -d chrome` (inside `mobile/`) |

> Full installation instructions: see `SETUP.md` in the project root.

### Quick health checks

```
GET http://localhost:8080/health
→ {"status":"ok","database":"connected"}

GET http://localhost:8081/health
→ {"status":"ready","device":"cpu","model":"openai/clip-vit-base-patch32"}
```

If either health check fails, stop here and fix the service before continuing.

---

## Part 1 — Backend API Verification

Use curl, Postman, or any HTTP client. All examples use curl.

### 1.1 — Health check (Fastify)

```bash
curl http://localhost:8080/health
```

Expected:
```json
{"status":"ok","database":"connected"}
```

---

### 1.2 — Initial pull (full catalog)

Simulates the mobile app on first boot (no prior sync).

```bash
curl "http://localhost:8080/api/v1/sync/pull?since_version=0"
```

Expected:
```json
{
  "sync_timestamp": "2026-...",
  "latest_version": <number>,
  "has_more": false,
  "changes": {
    "categories": {
      "updated": [ ... ],
      "deleted_ids": []
    },
    "products": {
      "updated": [ array of 5000 products ],
      "deleted_ids": []
    }
  }
}
```

Verify:
- `products.updated` length is 5,000
- Each product has: `id`, `sku`, `name`, `category_id`, `price`, `stock_quantity`, `barcode`, `image_url`, `version`, `updated_at`, `is_deleted`
- `categories.updated` is non-empty
- `sync_timestamp` is an ISO 8601 string

---

### 1.3 — Delta pull (incremental)

Simulates a subsequent sync after the initial import. Copy `latest_version` from the response above.

```bash
curl "http://localhost:8080/api/v1/sync/pull?since_version=<latest_version>&since_timestamp=2026-09-08T00:00:00Z"
```

Expected:
```json
{
  "changes": {
    "products": { "updated": [], "deleted_ids": [] },
    "categories": { "updated": [], "deleted_ids": [] }
  }
}
```

`products.updated` should be empty since nothing changed after the seed.

---

### 1.4 — Push (offline edit flush)

Simulates the mobile app flushing a queued price/stock edit.

```bash
curl -X POST http://localhost:8080/api/v1/sync/push \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "pos-mobile-01",
    "changes": {
      "products": [
        { "id": "<any product UUID from 1.2>", "price": 9.99, "stock_quantity": 42 }
      ]
    }
  }'
```

Expected:
```json
{
  "status": "success",
  "results": {
    "products": [
      { "id": "...", "status": "applied", "version": <incremented>, "updated_at": "..." }
    ]
  },
  "conflicts": []
}
```

Verify:
- `status` is `"applied"` (not `"not_found"`)
- `version` is higher than the product's previous version

Then pull again with the old `since_version` — the edited product should appear in `products.updated` with the new price.

---

### 1.5 — Static image serving (C4)

If the embed pipeline has been run for a product, its image is served by Fastify.

```bash
curl -I "http://localhost:8080/static/images/SKU-0001.jpg"
```

Expected: `HTTP/1.1 200 OK` with `Content-Type: image/jpeg`

If no images have been embedded yet, expect `404` — that is correct behaviour.

---

### 1.6 — Vision service health (C7)

```bash
curl http://localhost:8081/health
```

Expected:
```json
{"status":"ready","device":"cpu","model":"openai/clip-vit-base-patch32"}
```

---

### 1.7 — Embed a product image (vision service)

Requires a real product photo file. Creates a 512-d vector and stores it in PostgreSQL.

```bash
curl -X POST "http://localhost:8081/api/v1/products/<product_id>/embed" \
  -F "file=@/path/to/product_photo.jpg"
```

Expected:
```json
{"status":"success","product":{"id":"...","sku":"SKU-0001","name":"..."}}
```

Run this for at least a few products before testing visual search below.

---

### 1.8 — Visual search via API

```bash
curl -X POST "http://localhost:8081/api/v1/search/visual?top_k=3" \
  -F "file=@/path/to/query_photo.jpg"
```

Expected:
```json
{
  "status": "success",
  "search_time_ms": 120.5,
  "matches": [
    {
      "id": "...",
      "sku": "SKU-0001",
      "name": "...",
      "price": 9.99,
      "stock_quantity": 42,
      "image_url": null,
      "confidence": 0.87
    }
  ]
}
```

Verify:
- `confidence` is between 0 and 1
- Returned product matches the photo you submitted
- `search_time_ms` is reasonable (< 5,000 ms on CPU without HNSW index)

---

## Part 2 — Mobile App UI Verification (Flutter Web)

Run `flutter run -d chrome` from `mobile/`. The app opens in Chrome.

### 2.1 — First launch: configure server

1. Tap the **Sync** tab (rightmost tab, sync icon)
2. Tap the **gear icon** (top right of Sync screen)
3. Enter `localhost` in the IP field
4. Tap **Test Connection** — expect green "Sync server reachable"
5. Tap **Save & Close**

Verify the derived endpoints shown on screen:
- Sync API: `http://localhost:8080/api/v1`
- Vision AI: `http://localhost:8081`

---

### 2.2 — Initial sync (import 5,000 products)

1. On the Sync tab, tap **Run Sync Now**
2. Button shows spinner and "Connecting to backend…" label
3. After ~2–5 seconds:
   - Status message shows "Initial import: 5000 products loaded"
   - "Local products (Isar)" card shows "5000 items"
   - "Last synced version" card shows a non-zero version number
   - "Pending offline edits" card shows "All synced"

---

### 2.3 — Catalog search

1. Tap the **Catalog** tab (first tab)
2. Observe the product list loads immediately (up to 100 items shown by default)

**Search by name:**
- Type part of a product name (e.g., "chair") — list filters in real time
- Clear the search field — full list returns

**Search by SKU:**
- Type `SKU-0050` — exactly that product appears

**Search by barcode (text field):**
- Type a barcode string from a known product — only that product appears

**Clear button:**
- Type any query, then tap the ✕ icon at right of search field — list resets

---

### 2.4 — Inline price and stock edit

1. Tap any product row in the catalog list
2. A bottom sheet slides up showing:
   - Product name and SKU (read-only)
   - Selling Price field (pre-filled with current price)
   - Stock Quantity field (pre-filled with current stock)
3. Change the price to a new value (e.g., `12.50`)
4. Change the stock to a new value (e.g., `20`)
5. Tap **Save (syncs on next connection)**

Verify:
- Bottom sheet closes
- Product row in list immediately reflects the new price and stock
- Sync tab → "Pending offline edits" card shows "1 queued"

6. Go back to Sync tab, tap **Run Sync Now**
7. Status message shows "Delta: 0 updated | 1 offline edits pushed"
8. "Pending offline edits" card returns to "All synced"
9. Query `GET /api/v1/sync/pull?since_version=<old_version>` — the edited product appears with the new price

---

### 2.5 — Add items to basket

1. In catalog, search for a product
2. Tap the **shopping cart icon** on any product row
3. Snackbar appears: "Added [product name] to basket"
4. **Calculator tab** badge shows the basket count (blue badge on the tab icon)
5. Add 2–3 more products

---

### 2.6 — Basket calculator

1. Tap the **Calculator** tab
2. All added items listed with name, SKU, and price
3. Bottom panel shows running total: sum of all item prices
4. Tap the **delete (trash) icon** (top right) — basket clears, list shows "Basket empty"

Verify:
- Total matches manual addition of the item prices
- Badge on tab icon disappears after clearing

---

### 2.7 — Lens search (web — graceful fallback)

1. Tap the **Lens Search** tab (camera icon)
2. Expected: "No camera detected on this device" message with a photography icon
3. Sub-text: "Use a physical Android/iOS device for visual search."

This is correct behaviour — web has no camera access. Visual search is tested in Part 3.

---

### 2.8 — Barcode scanner (web — not available)

1. In Catalog tab, tap the **barcode scanner icon** (top right of AppBar)
2. On web this may show an error or do nothing — this is expected
3. Full barcode testing is done in Part 3 on a physical device

---

### 2.9 — Offline-first behaviour

1. Stop the Fastify backend (`Ctrl+C` in its terminal)
2. In the mobile app, edit a product price and save — succeeds locally
3. Sync tab shows "1 queued" in pending edits
4. Tap **Run Sync Now** — shows "Error: …" (expected, server is down)
5. Restart the backend: `npm run dev`
6. Tap **Run Sync Now** again — edit is flushed, "All synced" returns

---

## Part 3 — Physical Device Verification (Android)

These tests require a real Android phone connected via USB with USB debugging enabled.

### Setup

1. In the Config screen, change the IP from `localhost` to your PC's LAN IP (e.g., `192.168.1.50`)
2. Tap **Test Connection** — must show green before continuing
3. Run sync to populate the local database

### 3.1 — Barcode scan

1. Tap **Catalog** tab → barcode icon (top right)
2. Bottom sheet opens showing a camera viewfinder
3. Point at any product barcode
4. If barcode matches a catalog product: snackbar "Added [name] to basket"
5. If barcode not in catalog: red snackbar "Barcode not in catalog: [value]"

**USB scanner (keyboard emulator):**
- Plug in a USB barcode gun
- Scan any barcode while the barcode modal is open
- App detects the rapid keystroke sequence (<20 ms between chars) and processes it the same as camera scan

### 3.2 — Visual lens search

> Requires at least 3–5 products embedded via `POST /embed` (see Part 1.7)

1. Tap **Lens Search** tab
2. Camera live viewfinder is shown with a white target box
3. Instruction banner shows:
   - "Align unlabelled item in target box"
   - "First search may take 5–15 s on CPU" (C7 warmup note)
4. Point camera at a product photo that was previously embedded
5. Tap the large **camera button** (bottom center)
6. Target box turns amber while searching
7. Match result bottom sheet slides up showing:
   - "Visual Lens Match" label + confidence chip (green if > 70%, orange if ≤ 70%)
   - Product name, SKU, stock
   - Price in large indigo text
   - **Add to Total** button
8. Tap **Add to Total** — product added to basket, sheet closes

Verify:
- Confidence chip colour matches the threshold
- Correct product name matches the photo
- `search_time_ms` in the API response (visible in terminal logs) is reasonable

### 3.3 — End-to-end basket flow on device

1. Scan two products via barcode
2. Add one product via visual lens search
3. Add one product manually from catalog
4. Switch to **Calculator** tab — all 4 items listed, total correct
5. Verify badge count on tab icon is 4

---

## Part 4 — Delta Sync Correctness

This test verifies that the mobile app does not re-download unchanged data.

1. Note the current `latest_version` shown on the Sync tab
2. On the backend, update one product directly in PostgreSQL:

```sql
UPDATE products
SET price = 99.99, stock_quantity = 1
WHERE sku = 'SKU-0100';
```

3. In the mobile app, tap **Run Sync Now**
4. Status message shows "Delta: 1 updated"
5. In Catalog, search `SKU-0100` — price shows `$99.99`, stock shows `1`
6. `latest_version` on Sync tab has incremented by 1

Verify that only 1 product was transferred (not all 5,000).

---

## Part 5 — Known Limitations (current MVP scope)

| Feature | Status | Notes |
|---------|--------|-------|
| Authentication (login/register) | Planned | No access control yet; add before any demo |
| Dashboard / sales analytics | Planned | No transaction recording yet |
| Completed sale recording | Planned | Basket clears without saving a transaction |
| Barcode scan | Physical device only | Not available in Chrome |
| Visual lens search | Physical device only | Graceful fallback on web |
| HNSW vector index | Optional | Speeds up visual search; create after ≥ 50 embeddings |
| Multi-user / concurrent edits | Not handled | Single device scope for MVP |
| Image upload UI | Backend only | Embed via curl; no in-app photo upload for products |

---

## Verification Sign-off Checklist

| # | Test | Pass | Notes |
|---|------|------|-------|
| 1 | Backend health returns `ok` | ☐ | |
| 2 | Vision service health returns `ready` | ☐ | |
| 3 | Initial pull returns 5,000 products | ☐ | |
| 4 | Delta pull returns 0 items when nothing changed | ☐ | |
| 5 | Push applies price/stock edit and increments version | ☐ | |
| 6 | Config screen saves IP, derived URLs shown correctly | ☐ | |
| 7 | Initial sync imports 5,000 products in app | ☐ | |
| 8 | Catalog search filters by name in real time | ☐ | |
| 9 | Catalog search filters by SKU | ☐ | |
| 10 | Edit price/stock modal saves and queues outbox | ☐ | |
| 11 | Sync flushes outbox and clears pending count | ☐ | |
| 12 | Basket total is arithmetically correct | ☐ | |
| 13 | Clear basket empties list and removes badge | ☐ | |
| 14 | Lens Search shows graceful fallback on web | ☐ | |
| 15 | Offline edit queues while server is down, pushes on reconnect | ☐ | |
| 16 | Delta sync after DB edit transfers only changed record | ☐ | |
| 17 | Barcode scan adds product to basket (physical device) | ☐ | |
| 18 | Visual search returns correct product with confidence (physical device) | ☐ | |
