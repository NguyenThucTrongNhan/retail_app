#Requires -Version 5.1
<#
.SYNOPSIS
  Patches pub-cache packages incompatible with newer Android Gradle Plugin.
  Run after every `flutter pub get` to re-apply fixes.

.EXAMPLE
  cd mobile; flutter pub get; ..\scripts\fix_pub_deps.ps1
#>

$ErrorActionPreference = "Stop"

function Get-PubCacheRoot {
    if ($env:PUB_CACHE) { return $env:PUB_CACHE }
    $custom = "D:\Mobile_dev\.pub-cache"
    if (Test-Path $custom) { return $custom }
    return Join-Path $env:LOCALAPPDATA "Pub\Cache"
}

function Patch-IsarFlutterLibs {
    param([string]$hosted)

    $pkg      = "isar_flutter_libs-3.*"
    $relFile  = "android\build.gradle"
    $checkStr = "namespace"

    $dirs = Get-ChildItem -Path $hosted -Directory -Filter $pkg -ErrorAction SilentlyContinue
    if (-not $dirs) {
        Write-Host "  [SKIP] $pkg not found in pub cache" -ForegroundColor Yellow
        return 0
    }

    $count = 0
    foreach ($dir in $dirs) {
        $file = Join-Path $dir.FullName $relFile
        if (-not (Test-Path $file)) {
            Write-Host "  [SKIP] $($dir.Name): $relFile not found" -ForegroundColor Yellow
            continue
        }

        $text = Get-Content $file -Raw
        if ($text -match $checkStr) {
            Write-Host "  [OK]   $($dir.Name): already patched" -ForegroundColor Green
            continue
        }

        # Bump compileSdkVersion
        $text = $text -replace '(?m)^(\s*)compileSdkVersion\s+\d+', '${1}compileSdkVersion 35'
        # Raise minSdkVersion
        $text = $text -replace '(?m)^(\s*)minSdkVersion\s+\d+', '${1}minSdkVersion 21'
        # Insert namespace after "android {" line
        $text = $text -replace '(?m)^(\s*android\s*\{)', "android {`n    namespace `"dev.isar.isar_flutter_libs`""

        [System.IO.File]::WriteAllText($file, $text, [System.Text.Encoding]::UTF8)
        Write-Host "  [FIX]  $($dir.Name): patched $relFile" -ForegroundColor Cyan
        $count++
    }
    return $count
}

# ---- main ----

$hosted  = Join-Path (Get-PubCacheRoot) "hosted\pub.dev"
Write-Host "Pub cache: $(Split-Path $hosted -Parent)"

$total = 0
$total += Patch-IsarFlutterLibs -hosted $hosted

# Add more Patch-* function calls here for other packages as needed

Write-Host ""
if ($total -gt 0) {
    Write-Host "Done. $total file(s) patched." -ForegroundColor Cyan
} else {
    Write-Host "Done. All packages already up-to-date." -ForegroundColor Green
}
