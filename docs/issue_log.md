# Issue Log
## Retail MVP Mobile App

Record of issues encountered during development, setup, and testing — with root cause and solution.

**Rule:** Never edit existing issue entries. Append new issues at the bottom.
Status updates go in the **Update Log** section only.

---

## How to read this document

| Symbol | Meaning |
|--------|---------|
| ✅ Resolved | Fix applied and verified |
| 🔄 In progress | Being investigated or fixed |
| 📋 Open | Reported, not yet fixed |
| ⏭ Won't fix | Accepted limitation or out of scope |

---

## Issue #001 — VS Code Source Control shows ~10,000 files instead of ~100

**Reported:** 2026-09-08  
**Status:** ✅ Resolved  
**Area:** Developer tooling / Git  

**Symptom:**  
VS Code Source Control panel badge showed ~10,000 changed files.
GitHub Desktop showed the correct count (~103 files) for the same repository.

**Root cause:**  
VS Code's `git.autoRepositoryDetection` scans all folders visible to the editor
and auto-registers every `.git` directory it finds as a source control repository.
The Flutter SDK installed at `D:\Mobile_dev\flutter` is itself a git repository
(it tracks the Flutter framework source). VS Code was merging the Flutter SDK's
entire file tree into the Source Control count alongside the retail_app files.

GitHub Desktop was unaffected because it only watches the repository you
explicitly open — it does not auto-discover sibling repos.

**Fix applied:**  
Created `.vscode/settings.json` in the project root (committed so all team
members get the same behaviour):

```json
{
  "git.ignoredRepositories": ["D:\\Mobile_dev\\flutter"],
  "git.autoRepositoryDetection": "openEditors"
}
```

- `git.ignoredRepositories` — explicitly excludes the Flutter SDK repo
- `git.autoRepositoryDetection: "openEditors"` — limits repo scanning to only
  files currently open in the editor, preventing discovery of unrelated repos

**Resolution:** Reload VS Code window (`Ctrl+Shift+P` → Reload Window).
Source Control count drops to match GitHub Desktop.

**Files changed:**  
- `.vscode/settings.json` (new)  
- `.gitignore` — removed `.vscode/settings.json` from ignored list so the fix is shared

---

## Update Log

> **Rule:** Never edit entries above. Append a new row here for every status change.
> Format: `YYYY-MM-DD | #ID | From → To | Note`

---

## Issue #002 — `flutter analyze` reports 47 issues after build_runner

**Reported:** 2026-09-08  
**Status:** ✅ Resolved  
**Area:** Flutter / Dart static analysis  

**Symptom:**  
Running `flutter analyze` after `build_runner` completed reported 47 issues:
2 errors, 3 infos, 40 warnings, 2 extras.

**Root causes and fixes:**

| # | Severity | Location | Root cause | Fix applied |
|---|----------|----------|------------|-------------|
| 1 | error | `database_helper.dart:38` | `Isar.open()` requires `directory` parameter even on web in Isar 3.1.x — the API signature changed after 3.0 | Passed `directory: ''`; Isar ignores it on web and uses IndexedDB |
| 2 | error | `test/widget_test.dart:16` | Flutter generated a smoke test referencing `MyApp` but the app class is `RetailApp` | Replaced test with a correct smoke test using `RetailApp` |
| 3 | info | `main.dart:180` | `mounted` checked after `await` but using the bottom sheet's `ctx` BuildContext, not the State's context — wrong mounted owner | Changed `if (mounted)` to `if (ctx.mounted)` so the check belongs to the correct context |
| 4 | info | `main.dart:211` | `ScaffoldMessenger.of(context)` called after `await DatabaseHelper` — context may be stale | Captured `final messenger = ScaffoldMessenger.of(context)` before the `await` |
| 5 | info | `visual_search_screen.dart:273` | `Color.withOpacity()` deprecated in Flutter 3.x | Replaced with `.withValues(alpha: 0.7)` |
| 6 | warning ×40 | `*.g.dart` | Isar 3.1.x generated code calls experimental index APIs (`putByIndex`, `putAllByIndex`, etc.) — cannot modify generated files | Added `experimental_member_use: ignore` to `analysis_options.yaml` and excluded `lib/**/*.g.dart` from analysis |

**Files changed:**  
- `mobile/lib/services/database_helper.dart`  
- `mobile/lib/main.dart`  
- `mobile/lib/screens/visual_search_screen.dart`  
- `mobile/test/widget_test.dart`  
- `mobile/analysis_options.yaml`

---

## Update Log

> **Rule:** Never edit entries above. Append a new row here for every status change.
> Format: `YYYY-MM-DD | #ID | From → To | Note`

| Date | Issue | Status change | Note |
|------|-------|--------------|------|
| 2026-09-08 | #001 | 📋 Open → ✅ Resolved | `.vscode/settings.json` with `git.ignoredRepositories` committed |
| 2026-09-08 | #002 | 📋 Open → ✅ Resolved | 5 files fixed; experimental_member_use suppressed in analysis_options.yaml |

---

## Issue #003 — GET /health returns 404 after `npm run dev`

**Reported:** 2026-09-08
**Status:** ✅ Resolved
**Area:** Backend / Fastify startup

**Symptom:**
`npm run dev` appeared to start with no visible crash, but `GET http://localhost:8080/health` returned 404.

**Root cause:**
`@fastify/postgres` v5 runs `pool.connect()` inside a Fastify `onReady` hook.
If PostgreSQL is not running or `retail_store` database does not exist, the hook
throws → `fastify.listen()` rejects → `process.exit(1)` → `tsx watch` immediately
restarts → requests hit Fastify mid-restart → 404 on every route.
Secondary risk: `@fastify/static` throws `ENOENT` if `uploads/` directory is missing,
same effect.

**Fix applied:**
1. Split `/health` from DB check — `GET /health` always returns `200 { status:"ok" }`;
   `GET /health/db` does the `SELECT 1` probe and returns `503` if DB is unreachable.
2. Added `fs.mkdirSync(uploadsDir, { recursive: true })` before plugin registration —
   uploads dir is always created, even on a fresh clone.
3. Added startup diagnostic logging — working directory, uploads path, masked DB URL
   printed on start so misconfiguration is immediately visible.

**Files changed:** `backend/src/server.ts`

---

## Update Log

> **Rule:** Never edit entries above. Append a new row here for every status change.
> Format: `YYYY-MM-DD | #ID | From → To | Note`

| Date | Issue | Status change | Note |
|------|-------|--------------|------|
| 2026-09-08 | #001 | 📋 Open → ✅ Resolved | `.vscode/settings.json` with `git.ignoredRepositories` committed |
| 2026-09-08 | #002 | 📋 Open → ✅ Resolved | 5 files fixed; experimental_member_use suppressed in analysis_options.yaml |
| 2026-09-08 | #003 | 📋 Open → ✅ Resolved | `/health` split from DB check; uploads dir auto-created; startup logging added |

---

## Issue #005 — Vision service: C: drive full — pip and CLIP model download fail

**Reported:** 2026-09-08
**Status:** ✅ Resolved
**Area:** Vision service / Disk space

**Symptom:**
`pip install "numpy<2" --upgrade` failed with `[Errno 28] No space left on device`.
Even after requirements.txt was fixed (Issue #004), uvicorn crashed on startup because
HuggingFace tried to download the 605 MB CLIP model to
`C:\Users\nhan.nguyen\.cache\huggingface\hub\` and C: had 0 MB free.

**Root cause:**
C: drive is full. Two cascading failures:
1. pip's download cache writes to `%LOCALAPPDATA%\pip\cache` (C: drive) — cannot download numpy.
2. HuggingFace Transformers defaults to `C:\Users\<user>\.cache\huggingface\` for model weights — cannot download the 605 MB CLIP model.

**Fix applied:**
1. Install numpy bypassing C: drive cache:
   `pip install "numpy<2" --upgrade --no-cache-dir`
2. Added two `os.environ.setdefault` calls at the top of `main.py` **before** any torch/transformers imports:
   ```python
   os.environ.setdefault("HF_HOME", r"D:\hf_cache")
   os.environ.setdefault("TRANSFORMERS_CACHE", r"D:\hf_cache\hub")
   ```
   The model (605 MB) now downloads once to D:\hf_cache\ and loads from there on every subsequent start.

**Files changed:** `vision_service/main.py`

---

## Issue #004 — Vision service crashes: NumPy 2.x incompatible with torch 2.2.1

**Reported:** 2026-09-08
**Status:** ✅ Resolved
**Area:** Vision service / Python dependencies

**Symptom:**
`uvicorn main:app` crashed on import of `torch` with:
`UserWarning: Failed to initialize NumPy: _ARRAY_API not found`
Full traceback pointed to `torch/nn/modules/transformer.py`.

**Root cause:**
`requirements.txt` had no NumPy version pin. pip resolved to NumPy 2.4.6 (latest),
but `torch==2.2.1` was compiled against NumPy 1.x and is binary-incompatible
with NumPy 2.x (`_ARRAY_API` was removed/renamed in the C ABI).

**Fix applied:**
Added `numpy<2` to `requirements.txt` to constrain NumPy to the 1.x series.
Run `pip install "numpy<2" --upgrade` inside the venv to apply immediately.

**Files changed:** `vision_service/requirements.txt`

---

## Update Log

> **Rule:** Never edit entries above. Append a new row here for every status change.
> Format: `YYYY-MM-DD | #ID | From → To | Note`

| Date | Issue | Status change | Note |
|------|-------|--------------|------|
| 2026-09-08 | #001 | 📋 Open → ✅ Resolved | `.vscode/settings.json` with `git.ignoredRepositories` committed |
| 2026-09-08 | #002 | 📋 Open → ✅ Resolved | 5 files fixed; experimental_member_use suppressed in analysis_options.yaml |
| 2026-09-08 | #003 | 📋 Open → ✅ Resolved | `/health` split from DB check; uploads dir auto-created; startup logging added |
| 2026-09-08 | #004 | 📋 Open → ✅ Resolved | Pinned `numpy<2` in requirements.txt; torch 2.2.1 incompatible with NumPy 2.x |
| 2026-09-08 | #005 | 📋 Open → ✅ Resolved | `pip install --no-cache-dir`; HF_HOME redirected to D:\hf_cache in main.py |
| 2026-09-08 | #005 | note | `TRANSFORMERS_CACHE` env var later removed from main.py — deprecated in transformers v4 (Issue #008 fix) |
| 2026-09-08 | #006 | 📋 Open → ✅ Resolved | Existing process on port 8081 killed; uvicorn started successfully |
| 2026-09-08 | #007 | 📋 Open → ⏭ Won't fix | Reverted .g.dart patches; web ruled out of scope (see Issue #009) |
| 2026-09-08 | #008 | 📋 Open → ✅ Resolved | Warmup image changed from 1×1 to 224×224 in main.py |
| 2026-09-08 | #009 | 📋 Open → ⏭ Won't fix | Flutter web ruled out of scope — Isar 3.x deliberately blocks web at runtime |

---

## Issue #006 — Vision service fails to start: port 8081 already in use (WinError 10013)

**Reported:** 2026-09-08
**Status:** ✅ Resolved
**Area:** Vision service / Windows networking

**Symptom:**
```
[WinError 10013] An attempt was made to access a socket in a way forbidden
by its access permissions
```
uvicorn exited immediately after the "Will watch for changes" line.

**Root cause:**
Another process (PID 12184) was already bound to TCP port 8081 — likely a
previous uvicorn instance left running from an earlier session.
`netstat -ano | findstr :8081` confirmed the port was in LISTENING state.

**Fix applied:**
Killed the process holding port 8081. No code change required.

**To diagnose in future:**
```powershell
netstat -ano | findstr :8081
# then kill the offending PID:
Stop-Process -Id <PID> -Force
```

---

## Issue #007 — Flutter web compile errors: Isar 3.x generates 64-bit integer literals incompatible with JavaScript

**Reported:** 2026-09-08
**Status:** ⏭ Won't fix (web ruled out of scope — see Issue #009)
**Area:** Flutter web / Isar code generation

**Symptom:**
10 compile errors across 4 generated `.g.dart` files when building for Chrome:
```
Error: The integer literal 6222113721139403729 can't be represented exactly
in JavaScript.
```
Errors in: `product.g.dart`, `category.g.dart`, `sync_metadata.g.dart`,
`sync_outbox.g.dart`.

**Root cause:**
`isar_generator 3.1.0` computes 64-bit FNV hashes for `CollectionSchema.id`
and `IndexSchema.id`. These hashes frequently exceed JavaScript's safe integer
limit (`2^53 − 1 = 9_007_199_254_740_991`). The `// ignore_for_file: avoid_js_rounded_ints`
comment in the generated files suppresses the **lint warning** but cannot suppress
the **dart2js compile error**.

**Fix attempted (reverted):**
Replaced each out-of-range literal with the nearest JavaScript-representable
value as reported by the Dart compiler. This unblocked compilation but exposed
the deeper Issue #009 runtime block.

**Why reverted:**
Patching generated files adds noise that is wiped on every `build_runner build`
run. Since web is out of scope (Issue #009), the patches serve no purpose.

---

## Issue #008 — Vision service crashes on startup: CLIP warmup fails with channel count mismatch

**Reported:** 2026-09-08
**Status:** ✅ Resolved
**Area:** Vision service / CLIP image processor

**Symptom:**
```
ValueError: mean must have 1 elements if it is an iterable, got 3
```
Traceback originated in `transformers/image_transforms.py normalize()`,
called from the startup warmup function in `main.py`.

**Root cause:**
The warmup created a `Image.new("RGB", (1, 1), color=(0, 0, 0))` — a single
black pixel. The CLIP image processor (`CLIPImageProcessor`) performs several
pre-processing steps (resize → centre-crop → to-numpy → normalize). On a 1×1
pixel input, an internal reshape or squeeze operation collapses the 3-channel
tensor to 1 channel before the normalization step. The normalization then fails
because CLIP's mean/std are 3-element tuples `[0.481, 0.457, 0.408]` while the
image is now detected as 1-channel.

**Fix applied:**
Changed warmup image to `Image.new("RGB", (224, 224), color=(128, 128, 128))` —
CLIP's native input resolution. A properly-sized image travels through the full
resize-crop-normalize pipeline without any squeeze edge case.

Also removed the deprecated `TRANSFORMERS_CACHE` env var that was added in
Issue #005 (transformers v4 issues a `FutureWarning` for it; `HF_HOME` alone is
sufficient).

**Files changed:** `vision_service/main.py`

---

## Issue #009 — Flutter web not supported: Isar 3.x throws hard runtime error on web platform

**Reported:** 2026-09-08
**Status:** ⏭ Won't fix — Flutter web is out of scope for this project
**Area:** Flutter web / Isar database

**Symptom:**
After fixing the compile errors (Issue #007), the app loaded in Chrome but
immediately crashed:
```
IsarError: Please use Isar 2.5.0 if you need web support.
A 3.x version with web support will be released soon.
```
Stack trace: `isar/src/web/open.dart 49` → `DatabaseHelper._openIsar` →
`DatabaseHelper.db` getter → `searchProducts` → `main.dart initState`.

**Root cause:**
`isar 3.x` contains a deliberate hard-coded guard in its web backend
(`isar/src/web/open.dart`) that throws unconditionally when `openIsar()` is
called on the web platform. This is not a bug — the Isar team explicitly dropped
web support in 3.x pending a rewrite.

**Decision: out of scope.**
The app is a mobile retail POS. Its primary features (camera viewfinder,
barcode scanner via ML Kit, offline-first Isar DB with HNSW vector index) are
all mobile-only by design. Running in Chrome is not a use case. Isar 3.x is the
correct database choice for Android/iOS performance.

**What would be needed for web support (not planned):**
- Downgrade to `isar 2.5.0` (different query API, significant rewrite) OR
- Conditional imports: Isar for mobile + `drift`/`hive` for web (two DB layers)
