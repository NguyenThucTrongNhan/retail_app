# Flutter Android Emulator — Full Setup, Issues & Monitoring Runbook

> **Purpose:** Single reference for installing, running, monitoring, and
> safely shutting down a Flutter app on an Android ADB emulator (Windows 10).
> Covers every issue encountered on this machine from first install through
> first live sync test, with root-cause analysis, fixes, and investigation
> commands for each layer.

---

## Table of Contents

1. [Known-Good Environment Baseline](#1-known-good-environment-baseline)
2. [Diagnostic Layer Model](#2-diagnostic-layer-model)
3. [Full Startup Procedure with Monitoring Commands](#3-full-startup-procedure-with-monitoring-commands)
4. [All Documented Issues](#4-all-documented-issues)
5. [Runtime Monitoring Commands](#5-runtime-monitoring-commands)
6. [Safe Shutdown Procedure](#6-safe-shutdown-procedure)
7. [Quick Recovery Cheat Sheet](#7-quick-recovery-cheat-sheet)
8. [Prevention Checklist](#8-prevention-checklist)

---

## 1. Known-Good Environment Baseline

### Paths

```text
Project:              D:\2026\retail_app\mobile
Flutter SDK:          D:\Mobile_dev\flutter
Android Studio:       D:\Mobile_dev\Android\AndroidStudio
Android SDK:          D:\Mobile_dev\Android\sdk
Android AVD:          D:\Mobile_dev\Android\avd
Gradle cache:         D:\Mobile_dev\gradle
Pub cache:            D:\Mobile_dev\.pub-cache
```

### Environment Variables

```text
ANDROID_HOME          = D:\Mobile_dev\Android\sdk
ANDROID_USER_HOME     = D:\Mobile_dev\Android\user
ANDROID_EMULATOR_HOME = D:\Mobile_dev\Android\emulator-home
ANDROID_AVD_HOME      = D:\Mobile_dev\Android\avd
GRADLE_USER_HOME      = D:\Mobile_dev\gradle
PUB_CACHE             = D:\Mobile_dev\.pub-cache
```

### Version Pins (do not upgrade blindly)

```text
OS:               Windows 10 Pro 22H2
Flutter:          3.47.2 stable
Dart:             3.13.2
Android target:   Android 15 / API 35 / x86_64
AVD:              Pixel_6
Android Emulator: 36.6.11   ← pinned — 37.1.11 crashes on Intel HD 630
NDK:              28.2.13676358
AGP:              9.1.0 (with android.newDsl=false + android.builtInKotlin=false)
Kotlin:           2.4.0
```

### Flutter project key files

```text
mobile/android/settings.gradle.kts   — AGP + Kotlin version declarations
mobile/android/gradle.properties      — android.newDsl=false, JVM args
mobile/android/app/build.gradle.kts  — app build config
mobile/lib/models/product.dart        — Isar collection + JSON parsing
mobile/lib/services/sync_service.dart — pull/push sync logic
mobile/lib/services/database_helper.dart — Isar DB wrapper
```

---

## 2. Diagnostic Layer Model

Always identify **which layer is failing** before changing anything.
Work top-down on symptoms, bottom-up on fixes.

```
Flutter application code
        ↓
Flutter plugin / pub dependency
        ↓
Gradle / AGP / Kotlin build
        ↓
Android SDK / NDK
        ↓
ADB server
        ↓
Android Emulator / AVD
        ↓
Windows Hypervisor / GPU / drivers
```

**Rules:**
- An emulator GPU crash is **not** a Flutter problem.
- A Gradle parser error is **not** an emulator problem.
- An empty `adb devices` means **do not touch application code** yet.
- When Gradle reports multiple failures, fix the **first** one — others
  are usually cascade.

---

## 3. Full Startup Procedure with Monitoring Commands

Follow these steps in order. Each step has a verification command.

---

### Step 1 — Verify Environment Variables

```powershell
[System.Environment]::GetEnvironmentVariable("ANDROID_HOME", "User")
[System.Environment]::GetEnvironmentVariable("GRADLE_USER_HOME", "User")
[System.Environment]::GetEnvironmentVariable("PUB_CACHE", "User")
$env:Path -split ";" | Select-String "flutter","android"
```

Expected: all paths resolve to `D:\Mobile_dev\...`

---

### Step 2 — Verify Flutter Doctor

```powershell
flutter doctor -v
```

Look for:
```text
[✓] Flutter
[✓] Android toolchain
[✓] Android Studio
[✓] Connected device (after emulator is up)
```

Investigate any `[✗]` or `[!]` before proceeding.

---

### Step 3 — Start ADB Server

```powershell
adb start-server
adb version
adb devices
```

Expected:
```text
List of devices attached
(empty — no emulator running yet)
```

If ADB fails to start:
```powershell
taskkill /F /IM adb.exe 2>$null
adb start-server
```

---

### Step 4 — Start the Android Emulator

```powershell
emulator -avd Pixel_6 -no-snapshot-load -no-metrics
```

Keep this terminal open — do not close it.

**Monitor emulator startup (new terminal):**

```powershell
# Watch boot completion flag
adb wait-for-device shell getprop sys.boot_completed

# Stream emulator log (filter out noise)
adb logcat -s AndroidRuntime:E ActivityManager:I System.err:W *:F
```

Boot is complete when `sys.boot_completed` returns `1`.

If the emulator window shows "System UI isn't responding" on first cold boot,
choose **Wait** — this is normal with software-rendered graphics (SwiftShader/llvmpipe).

---

### Step 5 — Verify Emulator is Connected

```powershell
adb devices
```

Expected:
```text
List of devices attached
emulator-5554   device
```

If status shows `offline` or `unauthorized`:
```powershell
adb kill-server
adb start-server
adb devices
```

---

### Step 6 — Verify Flutter Sees the Device

```powershell
flutter devices
```

Expected:
```text
sdk gphone64 x86 64 (mobile) • emulator-5554 • android-x64 • Android 15 (API 35)
```

---

### Step 7 — Start the Backend Server

```powershell
cd D:\2026\retail_app\backend
npm run dev
```

Confirm it is listening:
```text
Server listening at http://0.0.0.0:8080
```

Monitor in a separate terminal:
```powershell
# Verify port is open
netstat -ano | Select-String ":8080"

# Test health endpoint from host
Invoke-WebRequest -Uri http://localhost:8080/health -UseBasicParsing
```

---

### Step 8 — Run the Flutter App

```powershell
cd D:\2026\retail_app\mobile
flutter run -d emulator-5554
```

**Monitor Gradle build:**
```powershell
# In a second terminal — stream Gradle build output
flutter run -d emulator-5554 --verbose 2>&1 | Tee-Object -FilePath build_log.txt
```

**Monitor device logs while app runs:**
```powershell
# Flutter-specific logs only
adb logcat -s flutter

# Broader app errors
adb logcat -s AndroidRuntime:E *:F

# All logs with timestamp
adb logcat -v time | Select-String "flutter|retail|isar"
```

---

### Step 9 — Verify App Sync

In the app:
1. Tap the **gear icon** on the Sync tab.
2. Set server IP to **`10.0.2.2`** (not `localhost` — see Issue #8).
3. Test connection.
4. Go back → tap **Run Sync Now**.

Monitor sync on the backend terminal — you should see:
```text
incoming request GET /api/v1/sync/pull?since_version=0
request completed  statusCode: 200
```

---

## 4. All Documented Issues

---

### Issue #1 — NDK Missing

**Error:**
```text
NDK 28.2.13676358 was not installed
```

**Root cause:** Required NDK version not installed; CLI installer unreliable
on this machine.

**Fix:** Android Studio → SDK Manager → SDK Tools → Show Package Details
→ NDK (Side by side) → 28.2.13676358 → Apply.

**Verify:**
```powershell
Test-Path "D:\Mobile_dev\Android\sdk\ndk\28.2.13676358"
```

---

### Issue #2 — Isar Plugin Missing `namespace`

**Error:**
```text
Namespace not specified. Please specify a namespace in the module's
build file.
```

**Root cause:** `isar_flutter_libs 3.1.0+1` predates the AGP namespace
requirement. Its `build.gradle` had no `namespace` declaration.

**Fix** (in pub cache file):
```gradle
android {
    namespace "dev.isar.isar_flutter_libs"   // ← add this
    compileSdkVersion 35
    defaultConfig {
        minSdkVersion 21
    }
}
```

File location:
```text
D:\Mobile_dev\.pub-cache\hosted\pub.dev\isar_flutter_libs-3.1.0+1\android\build.gradle
```

**Verify:**
```powershell
Select-String -Path "D:\Mobile_dev\.pub-cache\hosted\pub.dev\isar_flutter_libs-3.1.0+1\android\build.gradle" -Pattern "namespace"
```

---

### Issue #3 — UTF-8 BOM in `isar_flutter_libs` `build.gradle`

**Error:**
```text
Could not compile build file '...isar_flutter_libs-3.1.0+1\android\build.gradle'.
> startup failed:
  build file '...': 1: Unexpected character: '﻿' @ line 1, column 1.
```

**Root cause:** The Gradle file was saved with a UTF-8 BOM (`EF BB BF`).
Groovy's parser treats the BOM as an unexpected token before the first
valid character.

**Fix:** Rewrite the file as UTF-8 **without BOM**. Line 1 must start
directly with:
```gradle
group 'dev.isar.isar_flutter_libs'
```

**Investigate encoding:**
```powershell
# Read first 4 bytes — BOM = EF BB BF
$bytes = [System.IO.File]::ReadAllBytes("D:\Mobile_dev\.pub-cache\hosted\pub.dev\isar_flutter_libs-3.1.0+1\android\build.gradle")
$bytes[0..3] | ForEach-Object { "0x{0:X2}" -f $_ }
# Clean result (no BOM): 0x67 0x72 0x6F 0x75  (g r o u p)
# BOM present:           0xEF 0xBB 0xBF 0x67
```

**Durability warning:** This file is inside `.pub-cache`. A future
`flutter pub cache repair`, package update, or cache clear will overwrite
the fix. Long-term solution: vendor the dependency or use a local path
override in `pubspec.yaml`.

---

### Issue #4 — `kotlin-android` Plugin Error (Cascade)

**Error:**
```text
A problem occurred configuring project ':isar_flutter_libs'.
> 'kotlin-android' plugin requires one of the Android Gradle plugins.
```

**Root cause:** Cascade from Issue #3. Because the BOM prevented
`build.gradle` from parsing, the Android library plugin was never applied.
Kotlin then had no Android plugin to attach to.

**Failure chain:**
```
BOM → Groovy parse fail → Android plugin not applied → Kotlin plugin fails
```

**Fix:** Fix Issue #3. This error disappears automatically.

**Lesson:** When Gradle reports multiple failures, fix the **first**
configuration error before touching Kotlin or AGP settings.

---

### Issue #5 — AGP 9 / Flutter New DSL Warning

**Warning:**
```text
[!] Starting AGP 9+, only the new DSL interface will be read.
This results in a build failure when applying the Flutter Gradle plugin.
To resolve this update flutter or opt out of android.newDsl.
```

**Root cause:** Flutter Gradle plugin compatibility warning with AGP 9+
new DSL.

**Status:** Already handled. `mobile/android/gradle.properties` contains:
```properties
android.newDsl=false
android.builtInKotlin=false
```

**This was not the root cause of the BOM build failure.**

**Investigate:**
```powershell
Select-String -Path "D:\2026\retail_app\mobile\android\gradle.properties" -Pattern "newDsl|builtInKotlin"
```

---

### Issue #6 — Android Emulator 37.1.11 Crashes on Boot

**Errors in emulator log:**
```text
Host Vulkan driver is not supported.
Failed to load opengl32sw
Software OpenGL failed.
Showing crashdialog to get consent.
```

**Root cause:**
- Host GPU: Intel HD Graphics 630
- Host Vulkan API: 1.3.215
- Emulator 37.1.11 minimum requirement: Vulkan 1.3.240
- Both hardware GPU and software fallback (`opengl32sw`) failed to
  initialize inside 37.1.11.

**Fix:** Install Emulator 36.6.11 manually (not offered in SDK Manager).
36.6.11 fails the same Vulkan check but successfully falls back to
llvmpipe/SwiftShader:
```text
Selecting Vulkan device: llvmpipe
Graphics Adapter Android Emulator OpenGL ES Translator (Google SwiftShader)
Windows Hypervisor Platform accelerator is operational
```

**Rule:** Keep Emulator 36.6.11 on this machine until a newer version is
explicitly tested and confirmed working on Intel HD 630.

**Investigate emulator GPU/graphics:**
```powershell
# Stream emulator log filtered to graphics
adb logcat | Select-String "Vulkan|SwiftShader|opengl|llvmpipe|gfxstream"

# Check emulator process
Get-Process | Where-Object { $_.Name -like "emulator*" -or $_.Name -like "qemu*" }
```

---

### Issue #7 — "System UI Isn't Responding" on Cold Boot

**Symptom:** Android boots but shows "System UI isn't responding" dialog.

**Root cause:** SwiftShader/llvmpipe software rendering is slow. On first
cold boot the System UI ANR timeout fires before rendering catches up.

**Fix:** Choose **Wait** and let the boot finish. This is not a crash.

**Monitor boot completion:**
```powershell
# Blocks until device is ready, then returns
adb wait-for-device shell getprop sys.boot_completed

# Poll manually
adb shell getprop sys.boot_completed    # returns 1 when done

# Other useful boot props
adb shell getprop init.svc.bootanim    # returns 'stopped' when boot anim ends
adb shell getprop dev.bootcomplete     # returns 1 when fully booted
```

---

### Issue #8 — Sync Fails with "Connection Refused" (Wrong IP)

**Error shown in app:**
```text
Error: ClientException with SocketException: Connection refused
(OS Error: Connection refused, errno = 111)
address = localhost, port = 46006
uri = http://localhost:8080/api/v1/sync/pull?since_version=0
```

**Root cause:** The app was configured with server IP `localhost`. Inside
an Android emulator, `localhost` refers to the **emulator's own loopback**,
not the host machine. The backend running on the host PC is not reachable
via `localhost` from inside the emulator.

**Fix:** In the app Config screen (gear icon on Sync tab), change the
server IP to:

```text
10.0.2.2
```

This is the Android emulator's reserved alias for the host machine's
loopback address.

**IP reference table:**

| Context | Address to use |
|---|---|
| Android emulator → host PC | `10.0.2.2` |
| Physical device on same Wi-Fi → host PC | Host LAN IP (e.g. `192.168.1.50`) |
| Host PC → host PC | `localhost` or `127.0.0.1` |

**Investigate from emulator shell:**
```powershell
# Verify backend is reachable from emulator network namespace
adb shell curl -s http://10.0.2.2:8080/health

# Check backend is actually listening on host
netstat -ano | Select-String ":8080"

# Get host LAN IP (for physical device testing)
ipconfig | Select-String "IPv4"
```

---

### Issue #9 — Sync Succeeds (HTTP 200) but 0 Items Loaded — Type Cast Error

**Error shown in app:**
```text
Error: type 'String' is not a subtype of type 'num' in type cast
```

**Symptom:** Backend returns HTTP 200 and products are in the response body,
but the local Isar database remains empty (0 items).

**Root cause:** PostgreSQL `NUMERIC` and `DECIMAL` column types are returned
as Dart `String` by the Node.js `pg` driver, not as `num`. The original
`Product.fromJson` used hard casts:
```dart
..price = (j['price'] as num).toDouble()   // throws: 'String' is not 'num'
..stockQuantity = j['stock_quantity'] as int
..version = j['version'] as int
```

**Fix** (in `mobile/lib/models/product.dart`):
```dart
factory Product.fromJson(Map<String, dynamic> j) => Product()
  ..id = j['id'] as String
  ..sku = j['sku'] as String
  ..name = j['name'] as String
  ..categoryId = j['category_id'] as String?
  ..price = double.parse(j['price'].toString())           // ← safe parse
  ..stockQuantity = int.parse(j['stock_quantity'].toString())
  ..barcode = j['barcode'] as String?
  ..imageUrl = j['image_url'] as String?
  ..version = int.parse(j['version'].toString())
  ..updatedAt = j['updated_at'] as String;
```

Using `.toString()` then `parse()` safely handles both `String` and `num`
input regardless of what the driver returns.

**Investigate the raw API response:**
```powershell
# Call the sync endpoint directly and inspect field types
$r = Invoke-WebRequest -Uri "http://localhost:8080/api/v1/sync/pull?since_version=0" -UseBasicParsing
$body = $r.Content | ConvertFrom-Json
$body.changes.products.updated[0]   # inspect one product — check price type

# Or with curl for raw JSON
curl "http://localhost:8080/api/v1/sync/pull?since_version=0" | python -m json.tool | Select-String "price|stock|version" -Context 0,1
```

**Rule:** Never hard-cast numeric fields from a PostgreSQL-backed API.
Use `double.parse(…toString())` / `int.parse(…toString())` for fields
declared as NUMERIC, DECIMAL, BIGINT, or when the DB driver is unknown.

---

## 5. Runtime Monitoring Commands

### Flutter / Dart logs

```powershell
# All flutter print() output
adb logcat -s flutter

# Flutter + runtime errors only
adb logcat -s flutter AndroidRuntime:E *:F

# Save session log to file
adb logcat -s flutter | Tee-Object -FilePath flutter_session.log

# Stream with timestamps
adb logcat -v time -s flutter
```

### Isar database (from device shell)

```powershell
# Open shell on emulator
adb shell

# Find Isar DB file location
find /data/data/com.retailshop.retail_store -name "*.isar" 2>/dev/null
```

### Backend (Fastify) monitoring

```powershell
# Confirm port is open
netstat -ano | Select-String ":8080"

# Test each endpoint
Invoke-WebRequest -Uri http://localhost:8080/health -UseBasicParsing
Invoke-WebRequest -Uri "http://localhost:8080/api/v1/sync/pull?since_version=0" -UseBasicParsing

# Watch backend logs in real time (npm run dev uses pino — already streams)
# Tail log file if backend writes to one:
Get-Content -Path D:\2026\retail_app\backend\app.log -Wait -Tail 50
```

### ADB / Emulator health

```powershell
# Device list + status
adb devices -l

# Emulator boot state
adb shell getprop sys.boot_completed
adb shell getprop ro.build.version.release
adb shell getprop ro.product.model

# CPU/memory on emulator
adb shell top -n 1 | Select-Object -First 20

# Network interfaces inside emulator
adb shell ip addr show

# Emulator process on host
Get-Process | Where-Object { $_.Name -like "emulator*" -or $_.Name -like "qemu*" } | Select-Object Name,Id,CPU,WorkingSet
```

### Gradle build investigation

```powershell
# Verbose build (writes all Gradle output)
cd D:\2026\retail_app\mobile
flutter build apk --debug --verbose 2>&1 | Tee-Object gradle_build.log

# Run assembleDebug directly with stacktrace
cd D:\2026\retail_app\mobile\android
.\gradlew assembleDebug --stacktrace --info 2>&1 | Tee-Object gradle_debug.log

# Check Gradle daemon status
.\gradlew --status

# Check isar build.gradle encoding (first bytes)
$file = "D:\Mobile_dev\.pub-cache\hosted\pub.dev\isar_flutter_libs-3.1.0+1\android\build.gradle"
$bytes = [System.IO.File]::ReadAllBytes($file)
"First 4 bytes: " + ($bytes[0..3] | ForEach-Object { "0x{0:X2}" -f $_ } | Join-String -Separator " ")
```

### Flutter dependency investigation

```powershell
cd D:\2026\retail_app\mobile

# List all dependencies and versions
flutter pub deps

# Check for outdated packages
flutter pub outdated

# Validate pub cache integrity
flutter pub cache verify

# Re-fetch dependencies
flutter pub get
```

---

## 6. Safe Shutdown Procedure

Stop in this order to avoid data loss or stale processes.

### Step 1 — Stop the Flutter app

In the `flutter run` terminal:
```text
Press: q
```
This cleanly detaches the Dart VM and disconnects the debug session without
killing the emulator.

### Step 2 — Stop the backend server

In the `npm run dev` terminal:
```text
Ctrl + C
```
Fastify handles SIGINT and closes the database connection pool cleanly.

Verify the port is released:
```powershell
netstat -ano | Select-String ":8080"
# Should return nothing
```

### Step 3 — Stop the vision service (if running)

In the Python/uvicorn terminal:
```text
Ctrl + C
```

Then deactivate the virtual environment:
```powershell
deactivate
```

### Step 4 — Stop the Android emulator

**Option A — from the emulator window:** click the X button (clean shutdown).

**Option B — from PowerShell (clean):**
```powershell
adb -s emulator-5554 emu kill
```

**Option C — from PowerShell (force, if emulator is frozen):**
```powershell
taskkill /F /IM emulator.exe 2>$null
taskkill /F /IM qemu-system-x86_64.exe 2>$null
```

### Step 5 — Stop the ADB server (optional)

Only needed if ADB is misbehaving on next startup:
```powershell
adb kill-server
```

### Step 6 — Stop Gradle daemon (optional, frees ~1 GB RAM)

```powershell
cd D:\2026\retail_app\mobile\android
.\gradlew --stop
```

### Step 7 — Verify all ports released

```powershell
netstat -ano | Select-String ":8080|:8081|:5432"
# Should return nothing (or only PostgreSQL :5432 if DB runs as a service)
```

---

## 7. Quick Recovery Cheat Sheet

| Symptom | First command | Fix |
|---|---|---|
| `adb devices` empty | `adb start-server` | Then start emulator |
| Emulator offline/unauthorized | `adb kill-server && adb start-server` | Restart emulator |
| `flutter devices` shows nothing | Check `adb devices` first | Emulator not ready |
| Emulator won't start (37.x) | Check GPU logs | Use Emulator 36.6.11 |
| "System UI isn't responding" | Click **Wait** | Cold boot slow — normal |
| Gradle build fails | Check **first** failure line | Fix parse/config errors before cascade |
| `Unexpected character '﻿'` | Check BOM bytes | Rewrite file UTF-8 without BOM |
| Sync "Connection refused" | Check config IP | Use `10.0.2.2` not `localhost` |
| Sync 200 OK but 0 items | Check Flutter logs | Fix `fromJson` type casts |
| Backend not responding | `netstat -ano \| Select-String ":8080"` | Start backend with `npm run dev` |

### Kill and restart everything

```powershell
# Kill all
taskkill /F /IM emulator.exe 2>$null
taskkill /F /IM qemu-system-x86_64.exe 2>$null
adb kill-server

# Restart
adb start-server
emulator -avd Pixel_6 -no-snapshot-load -no-metrics
# (wait for boot)
adb wait-for-device shell getprop sys.boot_completed
flutter devices
```

### BOM fix (if pub cache is refreshed)

```powershell
$file = "D:\Mobile_dev\.pub-cache\hosted\pub.dev\isar_flutter_libs-3.1.0+1\android\build.gradle"
$content = Get-Content $file -Raw -Encoding UTF8
$content = $content.TrimStart([char]0xFEFF)
[System.IO.File]::WriteAllText($file, $content, [System.Text.UTF8Encoding]::new($false))
```

---

## 8. Prevention Checklist

### Before starting a new session

- [ ] Confirm `ANDROID_HOME`, `GRADLE_USER_HOME`, `PUB_CACHE` env vars point to `D:\Mobile_dev\...`
- [ ] Backend is started before running the Flutter app
- [ ] Emulator 36.6.11 is the active emulator binary (not 37.x)
- [ ] `adb devices` shows `emulator-5554 device` before `flutter run`

### After `flutter pub get` or dependency changes

- [ ] Check isar_flutter_libs BOM is still clean (byte check above)
- [ ] Run `flutter pub cache verify`
- [ ] Do a clean build: `flutter clean && flutter pub get`

### When adding new API fields in Flutter fromJson

- [ ] Use `double.parse(…toString())` for any numeric field from PostgreSQL
- [ ] Never use `as num`, `as int`, `as double` directly on fields that may come from a `pg` driver
- [ ] Test with `Invoke-WebRequest` against the real endpoint to confirm field types before writing the model

### Before upgrading any tool version

| Tool | Check |
|---|---|
| Android Emulator | Test on this GPU before pinning new version |
| AGP | Verify isar_flutter_libs still builds; check `android.newDsl` flag |
| Flutter SDK | Run `flutter doctor -v` and test full Gradle build |
| Kotlin | Check compatibility matrix with current AGP version |
| Isar package | Run sync test end-to-end after upgrade |

---

**Status:** Environment confirmed working as of 2026-09-10.
Emulator 36.6.11 is the pinned baseline. Sync pipeline tested end-to-end
(pull from Fastify → Isar bulk import → catalog search).
