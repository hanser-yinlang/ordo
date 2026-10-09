# Ordo - verify Android logic layer WITHOUT the Android SDK
#
# Why: on a machine without the Android SDK, Gradle cannot configure :apps:android at all,
#      yet we still want to prove that the parts of the Android module which do NOT depend on
#      the Android framework compile, and that their unit tests pass.
#
# How: use a JDK (DevEco Studio's bundled JBR, or JAVA_HOME, or java on PATH) together with the
#      Kotlin compiler found in the Gradle cache, compile the 4 test classes + the pure-logic
#      data classes against shared/core's core-jvm.jar, then run them with JUnitCore.
#
# Usage: powershell -File tools/verify-android-logic.ps1
# Requires: gradle :shared:core:jvmJar has produced shared/core/build/libs/core-jvm.jar
#
# Scope: covers business rules + tests only. Compose UI, SqliteStorage (android.database) and the
#        Android glue layer still need `gradle :apps:android:app:assembleDebug` / `testDebugUnitTest`
#        on a machine with the SDK.
#
# NOTE: this file is intentionally ASCII-only: Windows PowerShell 5.1 reads BOM-less UTF-8 .ps1
#       files as ANSI and would corrupt non-ASCII string literals.

$ErrorActionPreference = "Continue"

$root = Split-Path -Parent $PSScriptRoot
$cache = "$env:USERPROFILE\.gradle\caches\modules-2\files-2.1"
$coreJar = Join-Path $root "shared\core\build\libs\core-jvm.jar"
$app = Join-Path $root "apps\android\app\src"
$out = Join-Path $root "build\android-logic-verify"

$javaCandidates = @(
    "C:\Program Files\Huawei\DevEco Studio\jbr\bin\java.exe",
    "$env:LOCALAPPDATA\Huawei\DevEco Studio\jbr\bin\java.exe",
    "$env:JAVA_HOME\bin\java.exe"
)
$java = ""
foreach ($c in $javaCandidates) { if ($c -and (Test-Path $c)) { $java = $c; break } }
if ($java -eq "") {
    $cmd = Get-Command java -ErrorAction SilentlyContinue
    if ($cmd -ne $null) { $java = $cmd.Source }
}
if ($java -eq "") { Write-Host "ERROR: no JVM found (install DevEco Studio or set JAVA_HOME)" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $coreJar)) { Write-Host "ERROR: missing $coreJar - run: gradle :shared:core:jvmJar" -ForegroundColor Red; exit 1 }

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$out\classes" | Out-Null

function Find-Jar([string]$pattern) {
    $hit = Get-ChildItem $cache -Recurse -Filter $pattern -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'sources|javadoc' } | Select-Object -First 1
    if ($hit -eq $null) { return "" }
    return $hit.FullName
}

# Versions must match gradle/libs.versions.toml - wildcards can match older cached versions
# (that yields NoClassDefFoundError: kotlin/coroutines/jvm/internal/SpillingKt).
$compiler = Find-Jar "kotlin-compiler-embeddable-2.4.20.jar"
$stdlib = Find-Jar "kotlin-stdlib-2.4.20.jar"
$serJson = Find-Jar "kotlinx-serialization-json-jvm-1.9.0.jar"
$serCore = Find-Jar "kotlinx-serialization-core-jvm-1.9.0.jar"
$coroutines = Find-Jar "kotlinx-coroutines-core-jvm-1.11.0.jar"
$junit = Find-Jar "junit-4.13.2.jar"
$hamcrest = Find-Jar "hamcrest-core-1.3.jar"

# The compiler itself needs org.jetbrains:annotations when generating code.
# Do NOT use com.android.tools:annotations - it does not contain org.jetbrains.annotations.NotNull.
$annotations = ""
$annDir = Join-Path $cache "org.jetbrains\annotations"
if (Test-Path $annDir) {
    $annHit = Get-ChildItem $annDir -Recurse -Filter "annotations-*.jar" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'sources|javadoc' } | Sort-Object Name -Descending | Select-Object -First 1
    if ($annHit -ne $null) { $annotations = $annHit.FullName }
}

$missing = @()
$pairs = @(
    @("kotlin-compiler-embeddable", $compiler),
    @("kotlin-stdlib", $stdlib),
    @("kotlinx-serialization-json", $serJson),
    @("kotlinx-serialization-core", $serCore),
    @("kotlinx-coroutines-core", $coroutines),
    @("junit", $junit),
    @("hamcrest", $hamcrest),
    @("org.jetbrains:annotations", $annotations)
)
foreach ($pair in $pairs) { if ($pair[1] -eq "") { $missing += $pair[0] } }
if ($missing.Count -gt 0) {
    Write-Host ("ERROR: missing jars (let Gradle resolve dependencies once): " + ($missing -join ", ")) -ForegroundColor Red
    exit 1
}

$runtimeCp = @($coreJar, $stdlib, $serJson, $serCore, $coroutines, $junit, $hamcrest, $annotations) -join ";"
$compilerCp = @($compiler, $stdlib, $coroutines, $annotations) -join ";"

$sources = @()
Get-ChildItem (Join-Path $app "test\java\com\ordo\android") -Filter *.kt | ForEach-Object { $sources += $_.FullName }
foreach ($extra in @("data\SeedData.kt", "data\ModelExt.kt")) {
    $p = Join-Path $app "main\java\com\ordo\android\$extra"
    if (Test-Path $p) { $sources += $p }
}

Write-Host "=== Ordo Android logic-layer verification ==="
Write-Host "  java     : $java"
Write-Host "  core jar : $coreJar"
Write-Host "  sources  : $($sources.Count) files"

Write-Host ""
Write-Host "=== (1) compile ==="
$compileArgs = @("-cp", $compilerCp, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-stdlib", "-nowarn", "-cp", $runtimeCp, "-d", "$out\classes")
foreach ($s in $sources) { $compileArgs += $s }
$compileOut = & $java $compileArgs 2>&1 | Out-String
$compileErr = @($compileOut -split "`n" | Where-Object { $_ -match 'error:|exception:' })
if ($compileErr.Count -gt 0) {
    Write-Host "  COMPILE FAILED:" -ForegroundColor Red
    $compileErr | Select-Object -First 10 | ForEach-Object { Write-Host "    $($_.Trim())" }
    exit 1
}
Write-Host "  OK compiled" -ForegroundColor Green

Write-Host ""
Write-Host "=== (2) run unit tests ==="
$classes = @(
    "com.ordo.android.NlpParsingTest",
    "com.ordo.android.QueryRulesTest",
    "com.ordo.android.RepeatEngineTest",
    "com.ordo.android.SyncMergeTest"
)
$runCp = "$out\classes;" + $runtimeCp
$runArgs = @("-cp", $runCp, "org.junit.runner.JUnitCore")
foreach ($c in $classes) { $runArgs += $c }
$runOut = & $java $runArgs 2>&1 | Out-String
$summary = @($runOut -split "`n" | Where-Object { $_ -match '^OK|^Tests run|^FAILURES|^There w|^[0-9]+\) ' })
foreach ($l in $summary) { Write-Host "  $($l.Trim())" }
if ($runOut -match 'OK \(\d+ test') {
    Write-Host "  OK all tests passed" -ForegroundColor Green
    exit 0
}
Write-Host "  FAIL some tests failed" -ForegroundColor Red
exit 1
