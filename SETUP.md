# Retail App — Setup Guide

## Prerequisites

| Tool | Required version | Notes |
|------|-----------------|-------|
| Flutter SDK | ≥ 3.0 | `flutter --version` to check |
| Dart | included with Flutter | |
| Node.js | ≥ 18 | `node --version` |
| Docker Desktop | any recent | must be running before step 3 |
| Python | ≥ 3.10 | `python --version` |
| pip | included with Python | |

---

## Step 1 — Create Flutter project skeleton

Open a VS Code terminal, navigate to the `mobile/` folder, then run:

```powershell
flutter create . --org com.retailshop --project-name retail_store
```

This adds `android/`, `ios/`, `web/` platform directories without overwriting
the existing `lib/` source files.

---

## Step 2 — Install Flutter packages & generate Isar code

Still in `mobile/`:

```powershell
flutter pub get
flutter pub run build_runner build --delete-conflicting-outputs
```

This generates the required `*.g.dart` files for all Isar models
(`product.g.dart`, `category.g.dart`, `sync_metadata.g.dart`, `sync_outbox.g.dart`).
The app will not compile without them. Re-run this command any time a
`@collection` model class is changed.

---

## Step 3 — Start PostgreSQL (Docker)

In `backend/`:

```powershell
docker-compose up -d
```

Wait ~10 seconds for the container to initialise. The init script
`backend/init-scripts/01_init.sql` runs automatically on first boot and
creates all tables, triggers, and indexes.

---

## Step 4 — Install backend packages & seed the database

Still in `backend/`:

```powershell
npm install
npm run seed:db
```

`seed:db` inserts 5,000 sample products in batches of 500 (takes ~5 s).
Run it only once; re-running is safe (upsert by id) but slow.

---

## Step 5 — Start the Fastify backend

```powershell
npm run dev
```

Verify at: `http://localhost:8080/health`
Expected response: `{"status":"ok","database":"connected"}`

---

## Step 6 — Install Python dependencies & start the vision service

In `vision_service/` (one-time install):

```powershell
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8081
```

First startup downloads the CLIP model (~350 MB). Subsequent starts use
the cached model and take ~5 s.

Verify at: `http://localhost:8081/health`
Expected response: `{"status":"ready","device":"cpu","model":"openai/clip-vit-base-patch32"}`

---

## Step 7 — Run the Flutter app

### Web (browser — for quick verification)

In `mobile/`:

```powershell
flutter run -d chrome
```

### Physical Android device

Connect phone via USB, enable USB debugging, then:

```powershell
flutter run
```

---

## Per-device server IP settings

Open the app → Sync tab → gear icon (top right) → Server Configuration.

| Device type | IP to enter |
|-------------|-------------|
| Flutter web / same machine | `localhost` |
| Android emulator | `10.0.2.2` |
| Physical phone on same Wi-Fi | PC's LAN IP e.g. `192.168.1.50` |

After setting the IP, tap **Test Connection** to confirm reachability,
then **Save & Close**.

---

## What works on web vs physical device

| Feature | Web (Chrome) | Physical Android/iOS |
|---------|:------------:|:--------------------:|
| Catalog search (5,000 items) | ✅ | ✅ |
| Edit price / stock locally | ✅ | ✅ |
| Basket calculator | ✅ | ✅ |
| Delta sync (pull + push) | ✅ | ✅ |
| Barcode scanner (USB / camera) | ❌ web limitation | ✅ |
| Visual lens search (CLIP) | ❌ no camera on web | ✅ |

Use web for verifying all core data flows.
Use a physical device to verify barcode and visual search.

---

## HNSW vector index (visual search optimisation)

After embedding at least 50 products via
`POST http://localhost:8081/api/v1/products/{id}/embed`, create the index:

```powershell
curl -X POST http://localhost:8081/api/v1/admin/create-vector-index
```

This is optional for initial testing — cosine search still works without
the index, just slower for large catalogs.
