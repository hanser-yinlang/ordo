# Ordo - one-command verification
#
# Usage (Windows PowerShell 5.1 or PowerShell 7):
#   powershell -File tools/verify.ps1                  # core + server + contract check
#   powershell -File tools/verify.ps1 -WithWindows     # also build/test the Windows desktop app
#   powershell -File tools/verify.ps1 -WithAndroid     # also verify the Android logic layer (no SDK needed)
#   powershell -File tools/verify.ps1 -All             # all of the above + encoding scan
#
# Android/HarmonyOS full builds need their own SDKs (see README section 4).
# NOTE: the iOS app was removed on 2026-10-13, so there is no iOS step any more.
#
# NOTE: ASCII-only on purpose - Windows PowerShell 5.1 reads BOM-less UTF-8 .ps1 files as ANSI
#       and corrupts non-ASCII string literals at parse time.

param(
    [switch]$WithWindows,
    [switch]$WithAndroid,
    [switch]$All,
    [string]$JavaHome = "",
    [string]$GradleBin = ""
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$failed = @()

if ($All) { $WithWindows = $true; $WithAndroid = $true }

if ($JavaHome -eq "") {
    foreach ($c in @($env:JAVA_HOME, "C:\Users\admin\Desktop\Ordo\_tools\jdk-21.0.12.1+1")) {
        if ($c -and (Test-Path $c)) { $JavaHome = $c; break }
    }
}
if ($JavaHome -and (Test-Path $JavaHome)) { $env:JAVA_HOME = $JavaHome }

function Step([string]$title, [scriptblock]$action) {
    Write-Host ""
    Write-Host "=== $title ===" -ForegroundColor Cyan
    & $action
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
        $script:failed += $title
    } else {
        Write-Host "  OK" -ForegroundColor Green
    }
}

function Invoke-Gradle([string]$taskArgs) {
    if ($GradleBin -and (Test-Path $GradleBin)) {
        & $GradleBin -p $root $taskArgs --console=plain
    } elseif (Test-Path (Join-Path $root "gradlew.bat")) {
        & (Join-Path $root "gradlew.bat") -p $root $taskArgs --console=plain
    } else {
        & gradle -p $root $taskArgs --console=plain
    }
}

Step "shared core: compile + unit tests" { Invoke-Gradle ":shared:core:jvmTest" }

Step "server: build + tests" {
    Push-Location (Join-Path $root "server")
    if (-not (Test-Path "node_modules")) { pnpm install }
    pnpm run build
    if ($LASTEXITCODE -eq 0) { pnpm test }
    Pop-Location
}

Step "contract conformance check" { node (Join-Path $root "tools\contract-check.mjs") }

if ($WithWindows) {
    Step "windows desktop: build + tests" { Invoke-Gradle ":apps:windows:test" }
}

if ($WithAndroid) {
    Step "android logic layer: compile + tests (no SDK required)" {
        & powershell -NoProfile -File (Join-Path $root "tools\verify-android-logic.ps1")
    }
}

if ($All) {
    Step "source encoding scan (UTF-8 / mojibake)" {
        python (Join-Path $root "tools\check-encoding.py")
    }
}

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
    exit 0
}
Write-Host "FAILED STEPS:" -ForegroundColor Red
$failed | ForEach-Object { Write-Host "  - $_" }
exit 1
