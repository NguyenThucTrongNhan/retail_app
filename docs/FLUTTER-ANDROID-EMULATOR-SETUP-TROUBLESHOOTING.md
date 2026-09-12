# Flutter Android Emulator Setup & Troubleshooting Notes

> Project reference for the first Flutter Android application setup on
> Windows 10 using Android Studio, Android Emulator, and a D:-drive
> development environment.

## 1. Final Working Environment

### Project

``` text
D:\2026\retail_app\mobile
```

### Development tools

``` text
Flutter SDK:
D:\Mobile_dev\flutter

Android Studio:
D:\Mobile_dev\Android\AndroidStudio

Android SDK:
D:\Mobile_dev\Android\sdk

Android AVD:
D:\Mobile_dev\Android\avd

Gradle cache:
D:\Mobile_dev\gradle

Pub cache:
D:\Mobile_dev\.pub-cache
```

### Environment variables

``` text
ANDROID_HOME          = D:\Mobile_dev\Android\sdk
ANDROID_USER_HOME     = D:\Mobile_dev\Android\user
ANDROID_EMULATOR_HOME = D:\Mobile_dev\Android\emulator-home
ANDROID_AVD_HOME      = D:\Mobile_dev\Android\avd
GRADLE_USER_HOME      = D:\Mobile_dev\gradle
PUB_CACHE             = D:\Mobile_dev\.pub-cache
```

### Android target

``` text
Device: Pixel 6
Android: Android 15
API: 35
ABI: x86_64
Emulator device ID: emulator-5554
```

------------------------------------------------------------------------

## 2. Issue #1 --- Required Android NDK Was Missing

### Symptom

The first Flutter Android build failed because Gradle required:

``` text
NDK 28.2.13676358
```

but that NDK version was not installed.

### Root cause

The Flutter/Android build depended on a specific NDK version. The
command-line SDK installation path was unreliable in this environment.

### Fix

Install it through Android Studio:

``` text
Android Studio
→ SDK Manager
→ SDK Tools
→ Show Package Details
→ NDK (Side by side)
→ 28.2.13676358
```

Installed location:

``` text
D:\Mobile_dev\Android\sdk\ndk\28.2.13676358
```

### Lesson

For exact NDK/CMake/SDK component versions, use Android Studio SDK
Manager when the command-line installer behaves unexpectedly.

------------------------------------------------------------------------

## 3. Issue #2 --- Old Isar Android Plugin Namespace

The project uses:

``` text
isar_flutter_libs 3.1.0+1
```

### Symptom

Modern Android Gradle Plugin versions require an Android namespace,
while the older Isar Android plugin did not define one.

### Original configuration

``` gradle
android {
    compileSdkVersion 30

    defaultConfig {
        minSdkVersion 16
    }
}
```

### Required compatibility patch

``` gradle
android {
    namespace 'dev.isar.isar_flutter_libs'
    compileSdkVersion 37

    defaultConfig {
        minSdkVersion 21
    }
}
```

The legacy manifest package declaration should also not be relied on as
the modern namespace definition:

``` xml
package="dev.isar.isar_flutter_libs"
```

### Lesson

Older Flutter plugins may need compatibility work when used with modern
AGP versions. Check `namespace`, `compileSdk`, `minSdk`, and plugin age
before assuming the Flutter project itself is broken.

------------------------------------------------------------------------

## 4. Issue #3 --- UTF-8 BOM in Isar `build.gradle`

This was the **actual root cause of the later Gradle build failure**.

### Error

``` text
Unexpected character: '﻿' @ line 1, column 1
```

Affected file:

``` text
D:\Mobile_dev\.pub-cache\hosted\pub.dev\
isar_flutter_libs-3.1.0+1\android\build.gradle
```

The first line effectively contained:

``` text
[BOM]group 'dev.isar.isar_flutter_libs'
```

instead of:

``` gradle
group 'dev.isar.isar_flutter_libs'
```

### Root cause

The Gradle file had been saved with a UTF-8 BOM. Groovy's parser treated
the BOM as an unexpected character before the first valid token.

### Fix

Rewrite/save the file as **UTF-8 without BOM**.

After the fix, line 1 must start directly with:

``` gradle
group 'dev.isar.isar_flutter_libs'
```

### Important durability warning

This file is inside:

``` text
D:\Mobile_dev\.pub-cache
```

A future package re-download, `flutter pub cache repair`, cache cleanup,
or dependency refresh may overwrite the fix.

For a durable project solution, prefer one of these later:

-   vendor the dependency into the repository;
-   maintain a patched fork;
-   use a dependency override to a local patched package;
-   upgrade/migrate away from the old Isar 3.x plugin when practical.

------------------------------------------------------------------------

## 5. Why the `kotlin-android` Error Appeared

Another error appeared:

``` text
'kotlin-android' plugin requires one of the Android Gradle plugins
```

This was **not the root cause**.

The failure chain was:

``` text
UTF-8 BOM in build.gradle
        ↓
Groovy cannot parse build.gradle
        ↓
Android library plugin is never applied
        ↓
Kotlin Android plugin has no Android plugin to attach to
        ↓
Secondary kotlin-android error
```

### Lesson

When Gradle reports multiple failures, fix the **first
parser/configuration failure** before changing unrelated Gradle/Kotlin
settings.

------------------------------------------------------------------------

## 6. AGP 9 / Flutter New DSL Warning

Flutter also reported:

``` text
Starting AGP 9+, only the new DSL interface will be read.
```

This project already handles that compatibility path in:

``` text
mobile\android\gradle.properties
```

with:

``` properties
android.newDsl=false
```

Therefore this warning was not the root cause of the BOM build failure.

### Lesson

Do not automatically upgrade/downgrade Flutter, AGP, Gradle, and Kotlin
because a `Flutter Fix` warning appears.

First separate:

``` text
Primary FAILURE
Secondary/cascade errors
Warnings
```

Fix the primary failure first.

------------------------------------------------------------------------

## 7. Issue #4 --- Android Emulator 37.1.11 Crashed

The Pixel 6 AVD existed correctly, but Android Emulator 37.1.11 could
not successfully start on this machine.

### Important log

``` text
Host Vulkan driver is not supported.
Failed to load opengl32sw
Software OpenGL failed.
Showing crashdialog to get consent.
```

Host GPU:

``` text
Intel(R) HD Graphics 630
```

Reported host Vulkan API:

``` text
1.3.215
```

Emulator 37.1.11 reported a minimum requirement of:

``` text
1.3.240
```

### What was already working

``` text
Pixel_6 AVD found             OK
API 35 system image found     OK
x86_64 image                  OK
Hypervisor                    OK
System requirements           OK
Disk space                    OK
ADB server                    OK
```

The failure occurred during emulator graphics initialization.

### Attempts that did not solve it

``` powershell
emulator -avd Pixel_6 -gpu swiftshader -no-snapshot-load -no-metrics
```

and:

``` powershell
emulator -avd Pixel_6 -gpu host -no-snapshot-load -no-metrics
```

Reinstalling Android Emulator 37.1.11 also produced the same graphics
failure.

### Lesson

Do not delete the AVD or reinstall the whole Android SDK when the logs
clearly show that the failure is in the emulator runtime/graphics layer.

------------------------------------------------------------------------

## 8. Emulator 36.6.11 Solved the Startup Crash

Android Studio SDK Manager only exposed Emulator 37.1.11, so Emulator
**36.6.11** was manually installed.

The existing Pixel 6/API 35/x86_64 AVD was preserved.

### Result

36.6.11 still logged:

``` text
Failed to load opengl32sw
```

but unlike 37.1.11, it successfully continued with fallback rendering:

``` text
Initializing gfxstream backend
Selecting Vulkan device: llvmpipe
Graphics Adapter Android Emulator OpenGL ES Translator (Google SwiftShader)
Windows Hypervisor Platform accelerator is operational
```

Comparison:

``` text
Emulator 37.1.11
graphics initialization/fallback → crash

Emulator 36.6.11
graphics fallback → succeeds → Android boots
```

### Current rule for this development machine

Keep **Android Emulator 36.6.11** for this Intel HD Graphics 630 machine
until a newer emulator version has been explicitly tested and confirmed
working.

Do not automatically upgrade the emulator just because SDK Manager
offers a newer version.

------------------------------------------------------------------------

## 9. `System UI Isn't Responding`

After 36.6.11 successfully booted Android, the emulator temporarily
displayed:

``` text
System UI isn't responding
```

This was a different issue from the Emulator 37 crash.

Android was already running, but rendering was slow because the emulator
was using software/fallback graphics such as SwiftShader/llvmpipe.

### Response

Choose **Wait** initially and allow the cold boot to finish.

Verify the emulator from PowerShell:

``` powershell
adb devices
```

and optionally:

``` powershell
adb shell getprop sys.boot_completed
```

A returned value of:

``` text
1
```

means Android boot completed.

------------------------------------------------------------------------

## 10. Final Emulator/Flutter Verification

The decisive verification was:

``` powershell
flutter devices
```

which detected:

``` text
sdk gphone64 x86 64 (mobile)
emulator-5554
android-x64
Android 15 (API 35) (emulator)
```

At that point:

``` text
Android Emulator       OK
ADB                    OK
Flutter device detect  OK
```

Any subsequent `flutter run` build failure should therefore be diagnosed
as a Flutter/Gradle/dependency problem unless new emulator evidence says
otherwise.

------------------------------------------------------------------------

## 11. Standard Startup Procedure

### Start/check ADB

``` powershell
adb start-server
adb devices
```

### Start the Pixel 6 emulator when necessary

``` powershell
emulator -avd Pixel_6 -no-snapshot-load -no-metrics
```

Keep the emulator process running.

### Verify ADB

``` powershell
adb devices
```

Expected:

``` text
List of devices attached
emulator-5554    device
```

### Verify Flutter

``` powershell
flutter devices
```

### Run the app

``` powershell
cd D:\2026\retail_app\mobile
flutter run -d emulator-5554
```

------------------------------------------------------------------------

## 12. Troubleshooting by Layer

  ------------------------------------------------------------------------------------------
  Layer             Symptom                      Root cause /       Fix
                                                 interpretation     
  ----------------- ---------------------------- ------------------ ------------------------
  Android SDK       NDK missing                  Required NDK       Install NDK
                                                 version absent     28.2.13676358

  Flutter plugin    Namespace error              Old Isar plugin vs Add `namespace`
                                                 modern AGP         compatibility patch

  Gradle parser     `Unexpected character: '﻿'`   UTF-8 BOM          Save `build.gradle`
                                                                    UTF-8 without BOM

  Kotlin            Android plugin required      Cascade from       Fix the first Gradle
                                                 failed Gradle      error
                                                 parsing            

  AGP               New DSL warning              Compatibility      `android.newDsl=false`
                                                 warning            already used

  Emulator 37       Crashes before Android boot  Graphics/runtime   Use Emulator 36.6.11
                                                 compatibility      

  Android SystemUI  Temporary not responding     Slow software      Wait; verify boot with
                                                 graphics/cold boot ADB

  ADB               Empty device list            Emulator not       Start emulator, then
                                                 booted/connected   check `adb devices`

  Flutter           Device not found             ADB/emulator layer Fix emulator/ADB before
                                                 not ready          Flutter

  Flutter build     Gradle/dependency failure    Project            Diagnose first Gradle
                                                 dependency/build   FAILURE
                                                 layer              
  ------------------------------------------------------------------------------------------

------------------------------------------------------------------------

## 13. Important Diagnostic Principle

Always identify **which layer is failing** before changing the
environment:

``` text
Flutter application
        ↓
Flutter dependencies/plugins
        ↓
Gradle / AGP / Kotlin
        ↓
Android SDK / NDK
        ↓
ADB
        ↓
Android Emulator / AVD
        ↓
Windows hypervisor / GPU / drivers
```

An emulator graphics crash is not a Flutter application problem.

A Gradle parser error is not an emulator problem.

An empty `adb devices` result means do not debug application code yet.

------------------------------------------------------------------------

## 14. Prevention Checklist for Future Flutter Projects

1.  Keep Flutter SDK, Android SDK, Gradle cache, Pub cache, and AVD
    locations explicitly configured.
2.  Run `flutter doctor -v` after initial environment setup.
3.  Install required SDK/NDK/CMake versions before debugging application
    code.
4.  Create one known-good Android AVD first.
5.  Verify `adb devices`.
6.  Verify `flutter devices`.
7.  Only then run the Flutter application.
8.  When Gradle reports several errors, investigate the **first
    failure** first.
9.  If Groovy/Gradle reports an unexpected character at line 1,
    immediately check file encoding/BOM.
10. Treat Kotlin/plugin errors following a Gradle parse failure as
    possible cascade errors.
11. Do not blindly upgrade AGP, Kotlin, Gradle, Flutter, and
    dependencies simultaneously.
12. Keep Emulator 36.6.11 on this machine until a newer version is
    proven compatible.
13. Do not delete an AVD when logs show the emulator runtime itself is
    failing.
14. Do not reinstall the entire Android SDK to solve one emulator
    component problem.
15. Avoid permanent modifications inside `.pub-cache`;
    vendor/fork/override patched packages where possible.
16. Preserve working version information so a future environment can
    reproduce the known-good setup.
17. Keep adequate free disk space for Gradle, Android SDK packages,
    emulator data, and build output.

------------------------------------------------------------------------

## 15. Known-Good Baseline

``` text
OS:
Windows 10 Pro 22H2

Flutter:
3.47.2 stable

Dart:
3.13.2

Android target:
Android 15 / API 35 / x86_64

AVD:
Pixel 6

Android Emulator:
36.6.11

Android SDK:
D:\Mobile_dev\Android\sdk

Required NDK:
28.2.13676358

Gradle cache:
D:\Mobile_dev\gradle

Pub cache:
D:\Mobile_dev\.pub-cache

Flutter project:
D:\2026\retail_app\mobile
```

------------------------------------------------------------------------

## 16. Quick Recovery Commands

### Emulator is not detected

``` powershell
adb start-server
adb devices
```

If necessary:

``` powershell
emulator -avd Pixel_6 -no-snapshot-load -no-metrics
```

### Stale emulator process

``` powershell
taskkill /F /IM emulator.exe 2>$null
taskkill /F /IM qemu-system-x86_64.exe 2>$null
adb kill-server
adb start-server
```

### Verify emulator

``` powershell
adb devices
flutter devices
```

### Run application

``` powershell
cd D:\2026\retail_app\mobile
flutter run -d emulator-5554
```

### BOM error returns

If this error returns:

``` text
Unexpected character: '﻿' @ line 1, column 1
```

check:

``` text
D:\Mobile_dev\.pub-cache\hosted\pub.dev\
isar_flutter_libs-3.1.0+1\android\build.gradle
```

and ensure it is UTF-8 **without BOM**.

------------------------------------------------------------------------

## 17. Future Improvement

The current setup is usable, but the old Isar 3.x dependency is
technical debt.

Before production or major Flutter/AGP upgrades, evaluate:

``` text
Current Isar 3.x dependency
        ↓
Can it be upgraded safely?
        ↓
Yes → migrate and remove compatibility patches
No  → vendor/fork the dependency and version the patch in Git
```

Do not depend long-term on manually modifying `.pub-cache`, because
cache contents are not part of the application's source-controlled build
definition.

------------------------------------------------------------------------

**Status:** Android emulator and Flutter device connection established.
Emulator 36.6.11 is the known-good emulator baseline for this
development machine. The Isar Gradle BOM issue was identified and fixed;
preserve a durable version of that patch before future dependency/cache
refreshes.
