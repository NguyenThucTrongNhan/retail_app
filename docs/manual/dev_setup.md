# Developer Environment Setup Guide
## Retail MVP Mobile App — Local Dev from Zero

This document walks a new developer through installing every tool needed to
run and modify the full stack locally: Flutter, Node.js, Python, Docker, and
VS Code extensions.

Follow the sections in order. Each section ends with a verification command
so you know it is working before moving on.

---

## Rules before you start

> **Flutter must NOT be installed on C:\**
> Install the Flutter SDK on your D:\ drive (or any non-system drive).
> The SDK is ~2 GB and grows with each upgrade; keeping it off C:\ avoids
> permission problems and protects your system drive space.
> All paths in this guide use `D:\Mobile_dev\flutter`.

> **Use VS Code integrated terminal only.**
> Never open a raw WSL2 shell window. Run all commands through VS Code's
> built-in terminal (PowerShell or Git Bash). This avoids Windows/WSL path
> separator confusion.

---

## Tool Overview

| Tool | Version target | Used for |
|------|---------------|---------|
| Git | latest | Source control |
| VS Code | latest | IDE — all editing and terminals |
| Flutter SDK | ≥ 3.0 | Mobile/web app |
| Android Studio | latest | Android SDK, emulator (no need to use the IDE) |
| Node.js | ≥ 18 LTS | Fastify backend |
| Python | ≥ 3.10 | Vision service (CLIP) |
| Docker Desktop | latest | PostgreSQL container |
| Chrome | any | Flutter web target |

---

## Step 1 — Git

Download from https://git-scm.com/download/win and install with defaults.

**Verify:**
```powershell
git --version
# git version 2.x.x
```

---

## Step 2 — VS Code

Download from https://code.visualstudio.com and install.

**Required extensions** — install all of these from the Extensions panel
(`Ctrl+Shift+X`):

| Extension | Publisher | Purpose |
|-----------|-----------|---------|
| Flutter | Dart Code | Flutter + Dart language support, debugger |
| Dart | Dart Code | Installed automatically with Flutter extension |
| Docker | Microsoft | Manage containers from VS Code |
| ESLint | Microsoft | TypeScript linting for backend |
| Python | Microsoft | Python language support for vision service |
| Pylance | Microsoft | Python type checking |
| REST Client | Huachao Mao | Run `.http` files to test API (optional but useful) |

**Verify:** After installing the Flutter extension, the status bar at the
bottom of VS Code shows the Dart SDK version.

---

## Step 3 — Flutter SDK

> ⚠️ Install to `D:\Mobile_dev\flutter` — NOT C:\

1. Go to https://docs.flutter.dev/get-started/install/windows
2. Download the latest stable Flutter SDK zip
3. Extract to **`D:\Mobile_dev\flutter`**
   - Final path should be: `D:\Mobile_dev\flutter\bin\flutter.bat`

### Add Flutter to PATH

Open **System Properties → Environment Variables → System variables → Path**,
click **New**, and add:

```
D:\Mobile_dev\flutter\bin
```

Close and reopen any terminal after this change.

**Verify:**
```powershell
flutter --version
# Flutter 3.x.x • channel stable
```

---

## Step 4 — Android Studio (Android SDK only)

> **Skip this step if you are only running on Flutter Web (Chrome).**
> Android Studio is only required when you want to test on a physical Android
> device or emulator. Come back to this step when you are ready for that.

You need Android Studio to get the Android SDK and create an emulator.
You do not need to use Android Studio as your IDE.

1. Download from https://developer.android.com/studio
2. Install to default location
3. On first launch, complete the setup wizard — this installs the Android SDK
4. Open **SDK Manager** (`Tools → SDK Manager`) and ensure these are installed:
   - Android SDK Platform (API level 33 or higher)
   - Android SDK Build-Tools
   - Android Emulator
   - Android SDK Platform-Tools

### Add Android tools to PATH

Add to **System variables → Path**:
```
C:\Users\<your-username>\AppData\Local\Android\Sdk\platform-tools
```

**Verify:**
```powershell
adb --version
# Android Debug Bridge version 1.x.x
```

### Accept Android licenses

```powershell
flutter doctor --android-licenses
# Press y to accept each one
```

### Create an emulator (optional — physical device works too)

In Android Studio: **Device Manager → Create Device → Pixel 6 → API 33**

---

## Step 5 — Flutter doctor

Run this to confirm Flutter and Chrome are working. One command covers both
web-only and full Android setups.

```powershell
flutter doctor -v
```

**Web-only target** — these three lines must be green, ignore everything else:
```
[✓] Flutter (Channel stable, 3.x.x)
[✓] Chrome - develop for the web
[✓] VS Code
```

`[!]` or `[✗]` lines for Android toolchain or Android Studio are expected
if you skipped Step 4. They do not affect `flutter run -d chrome`.

**Full Android target** — all of these must be green:
```
[✓] Flutter (Channel stable, 3.x.x)
[✓] Windows Version
[✓] Android toolchain
[✓] Chrome - develop for the web
[✓] VS Code
```

---

## Step 6 — Node.js

Download the **LTS** installer from https://nodejs.org

Install with defaults. npm is included.

**Verify:**
```powershell
node --version   # v18.x.x or higher
npm --version    # 9.x.x or higher
```

---

## Step 7 — Python

Download from https://www.python.org/downloads/ (3.10 or higher).

> During installation, tick **"Add Python to PATH"** before clicking Install.

**Verify:**
```powershell
python --version   # Python 3.10.x or higher
pip --version      # pip 23.x
```

### (Recommended) Create a virtual environment for the vision service

```powershell
cd D:\2026\retail_app\vision_service
python -m venv .venv
.venv\Scripts\Activate.ps1
```

Your terminal prompt should now show `(.venv)`.

Install dependencies inside the venv:
```powershell
pip install -r requirements.txt
```

> The first install downloads the PyTorch wheel (~800 MB) and the CLIP model
> weights (~350 MB). This is a one-time download; subsequent installs use cache.

**Verify:**
```powershell
python -c "import torch; print(torch.__version__)"
# 2.x.x
```

---

## Step 8 — PostgreSQL 16 (local install)

PostgreSQL runs locally on your machine — no Docker needed for local dev.
Docker is kept only for production/staging deployment of the API container.

### 8a — Install PostgreSQL 16

Download the Windows installer from https://www.postgresql.org/download/windows/
(use the EDB interactive installer).

During installation:
- Set the **superuser password** (remember this — you will need it in Step 8c)
- Keep the default port **5432**
- Tick **pgAdmin 4** in the component list — useful for running SQL scripts via GUI

**Verify:**
```powershell
psql --version   # psql (PostgreSQL) 16.x
```

If `psql` is not found, add the bin folder to PATH:
```
C:\Program Files\PostgreSQL\16\bin
```

### 8b — Install pgvector extension

pgvector adds the `vector` data type used for CLIP image embeddings.

1. Go to https://github.com/pgvector/pgvector/releases
2. Download the prebuilt zip for **pg16 / Windows** (e.g. `pgvector-windows-pg16.zip`)
3. Extract and copy files to the PostgreSQL install directory:
   - `vector.dll` → `C:\Program Files\PostgreSQL\16\lib\`
   - `vector.control` → `C:\Program Files\PostgreSQL\16\share\extension\`
   - `vector--*.sql` → `C:\Program Files\PostgreSQL\16\share\extension\`
4. Restart the PostgreSQL service:

```powershell
Restart-Service -Name "postgresql-x64-16"
```

**Verify inside psql:**
```sql
CREATE EXTENSION IF NOT EXISTS vector;
-- Should return: CREATE EXTENSION
DROP EXTENSION vector;
```

### 8c — Create the database and schema

Run the setup script in two steps.

**Step 1 — create role and database** (run as postgres superuser):
```powershell
psql -U postgres -f D:\2026\retail_app\backend\scripts\local_db_setup.sql
```

Enter the postgres superuser password when prompted.

**Step 2 — create tables, indexes, triggers** (run as shop_admin):
```powershell
psql -U shop_admin -d retail_store -f D:\2026\retail_app\backend\scripts\local_db_setup.sql
```

Password: `LocalShopSecretPassword123!`

> **pgAdmin alternative:** Open pgAdmin → connect to the `postgres` database →
> open Query Tool → paste and run Part A of the script. Then switch to the
> `retail_store` database → paste and run Part B.

**Verify:**
```powershell
psql -U shop_admin -d retail_store -c "\dt"
# Should list: categories, products
```

### 8d — Docker Desktop (optional)

Docker is only needed if you want to run the backend API in a container
(production mode). For local dev (`npm run dev`), Docker is not required.

If you do install it: https://www.docker.com/products/docker-desktop/ (WSL2 backend).

---

## Step 9 — Clone the repository and open in VS Code

```powershell
git clone <repo-url> D:\2026\retail_app
code D:\2026\retail_app
```

VS Code will detect the Flutter project and prompt you to get packages —
click **Get Packages** or run manually in the next step.

---

## Step 10 — Flutter project first-time setup

Open a VS Code terminal (`Ctrl+`` `), navigate to the mobile folder:

```powershell
cd D:\2026\retail_app\mobile
```

### 10a — Create platform directories (first time only)

```powershell
flutter create . --org com.retailshop --project-name retail_store
```

This adds `android/`, `ios/`, `web/` without overwriting existing `lib/` code.

### 10b — Install packages

```powershell
flutter pub get
```

### 10c — Generate Isar model files

```powershell
flutter pub run build_runner build --delete-conflicting-outputs
```

This generates `*.g.dart` files for all four Isar collections.
Re-run this command any time you modify a class annotated with `@collection`.

**Verify:**
```powershell
flutter analyze
# No issues found!
```

---

## Step 11 — Backend first-time setup

```powershell
cd D:\2026\retail_app\backend
npm install
```

### Environment file

A `.env` file is already committed with local dev defaults:

```env
DATABASE_URL=postgres://shop_admin:LocalShopSecretPassword123!@localhost:5432/retail_store
PORT=8080
HOST=0.0.0.0
```

Do not commit changes to `.env`. If you need different values, create a
`.env.local` file (add it to `.gitignore`).

**Verify TypeScript compiles:**
```powershell
npx tsc --noEmit
# (no output = success)
```

---

## Step 12 — Start PostgreSQL service and seed the database

PostgreSQL runs as a local Windows service (installed in Step 8).
Make sure it is running before starting the backend.

**Check / start the PostgreSQL service:**
```powershell
Get-Service -Name "postgresql-x64-16"
# If Status is Stopped:
Start-Service -Name "postgresql-x64-16"
```

**Verify connection:**
```powershell
psql -U shop_admin -d retail_store -c "SELECT COUNT(*) FROM products;"
# Should return 0 (empty before seed)
```

### Seed 5,000 products (run once, from backend/ folder)

```powershell
cd D:\2026\retail_app\backend
npm run seed:db
# Seeded batch 1/10 ... Seeded batch 10/10 — Done.
```

---

## Step 13 — Verify all services

Start each service in a separate VS Code terminal tab:

**Terminal 1 — Fastify backend:**
```powershell
cd D:\2026\retail_app\backend
npm run dev
```
Check: `http://localhost:8080/health` → `{"status":"ok","database":"connected"}`

**Terminal 2 — Vision service:**
```powershell
cd D:\2026\retail_app\vision_service
.venv\Scripts\Activate.ps1
uvicorn main:app --host 0.0.0.0 --port 8081 --reload
```
Check: `http://localhost:8081/health` → `{"status":"ready","device":"cpu",...}`

**Terminal 3 — Flutter web:**
```powershell
cd D:\2026\retail_app\mobile
flutter run -d chrome
```

App opens in Chrome. Go to **Sync tab → gear icon**, set IP to `localhost`,
tap **Test Connection** (green = all good), then **Run Sync Now**.

---

## Step 14 — Physical Android device (optional)

1. On the phone: **Settings → Developer Options → USB Debugging → ON**
2. Connect via USB cable
3. Accept the "Allow USB debugging?" prompt on the phone

```powershell
adb devices
# List of devices attached
# XXXXXXXXXX   device
```

```powershell
cd D:\2026\retail_app\mobile
flutter run
# Flutter selects the connected device automatically
```

In the app Config screen, change IP from `localhost` to your PC's LAN IP
(e.g. `192.168.1.50`) — check it with `ipconfig` in PowerShell.

---

## Common issues and fixes

| Symptom | Fix |
|---------|-----|
| `flutter: command not found` | `D:\Mobile_dev\flutter\bin` not in PATH — re-add and restart terminal |
| `build_runner` fails with "already exists" | Add `--delete-conflicting-outputs` flag |
| `psql: error: connection refused` | PostgreSQL service not running — run `Start-Service postgresql-x64-16` |
| `CREATE EXTENSION vector` fails | pgvector not installed — follow Step 8b |
| Port 5432 already in use | Another PostgreSQL instance running — check Services panel |
| `npm run dev` — "Cannot find module" | Run `npm install` first |
| Vision service — CUDA not found | Normal on machines without GPU; `device: cpu` is expected |
| `flutter doctor` shows Chrome missing | Install Chrome and re-run |
| Android license not accepted | Run `flutter doctor --android-licenses` and press `y` |
| `adb devices` shows "unauthorized" | Unplug/replug USB and accept prompt on phone |

---

## Directory reference

```
D:\2026\retail_app\
├── backend\                  Node.js Fastify (port 8080)
│   ├── src\server.ts
│   ├── src\seed.ts
│   ├── init-scripts\         SQL reference (used by Docker only)
│   ├── scripts\              local_db_setup.sql, create_vector_index.sql
│   ├── uploads\              Product images (served at /static/images/)
│   ├── .env                  Local dev environment variables
│   └── docker-compose.yml    API container only (postgres runs locally)
├── mobile\                   Flutter app
│   ├── lib\
│   │   ├── config\           AppConfig (server IP)
│   │   ├── models\           Isar collections (*.dart + *.g.dart generated)
│   │   ├── screens\          UI screens
│   │   ├── services\         DatabaseHelper, SyncService, AuthService (planned)
│   │   └── widgets\          BarcodeScannerModal
│   └── pubspec.yaml
├── vision_service\           Python FastAPI CLIP service (port 8081)
│   ├── main.py
│   ├── requirements.txt
│   └── .venv\                Python virtual environment (not committed)
└── docs\
    ├── concerns_and_decisions.md   Architecture decisions + update log
    └── manual\
        ├── dev_setup.md            ← this file
        └── human_verify.md         Full test guide

D:\Mobile_dev\flutter\               Flutter SDK (NOT on C:\)
```

---

## Daily workflow (after first-time setup)

```powershell
# 1. Ensure PostgreSQL local service is running
Start-Service -Name "postgresql-x64-16"   # skip if already running

# 2. Open VS Code in project root
code D:\2026\retail_app

# 3. Terminal 1 — backend
cd backend && npm run dev

# 4. Terminal 2 — vision service
cd vision_service && .venv\Scripts\Activate.ps1 && uvicorn main:app --host 0.0.0.0 --port 8081 --reload

# 5. Terminal 3 — Flutter
cd mobile && flutter run -d chrome
```

If you changed any `@collection` model, regenerate before running Flutter:
```powershell
flutter pub run build_runner build --delete-conflicting-outputs
```
