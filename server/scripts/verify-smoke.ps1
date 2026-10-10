# Ordo server - smoke verification (start server -> smoke.mjs -> stop -> confirm port released)
#
# Usage (Windows PowerShell 5.1 or PowerShell 7):
#   powershell -File scripts/verify-smoke.ps1
#   powershell -File scripts/verify-smoke.ps1 -DatabaseUrl "postgres://ordo:secret@127.0.0.1:55432/ordo"
#
# NOTE: ASCII-only on purpose - Windows PowerShell 5.1 reads BOM-less UTF-8 .ps1 files as ANSI
#       and corrupts non-ASCII string literals at parse time (see tools/verify.ps1).

param(
  [string]$DatabaseUrl = ''
)

$ErrorActionPreference = 'Continue'
$serverDir = Split-Path -Parent $PSScriptRoot
Set-Location $serverDir

function Test-PortTaken([int]$p) {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', $p)
    $c.Close()
    return $true
  } catch { return $false }
}

# Pick a free port
$port = 0
foreach ($candidate in 18080..18099) {
  if (-not (Test-PortTaken $candidate)) { $port = $candidate; break }
}
if ($port -eq 0) { Write-Output 'no free port found'; exit 1 }
Write-Output "=== port $port ==="

$env:PORT = "$port"
$env:HOST = '127.0.0.1'
$env:NODE_ENV = 'production'
$env:JWT_SECRET = 'smoke-verify-secret-please-rotate-0123456789'
# Required in production (contract 7.6.5 / 9): HMAC pepper for email login codes.
# Missing -> the server refuses to start.
$env:ORDO_CODE_PEPPER = 'smoke-verify-code-pepper-please-rotate-0123456789'
$env:LOG_LEVEL = 'info'
$env:REMINDER_SCAN_MS = '200'
$env:TZ_OFFSET_MINUTES = '480'
if ($DatabaseUrl -ne '') {
  $env:DATABASE_URL = $DatabaseUrl
  Write-Output "DATABASE_URL = $DatabaseUrl (expect storage=postgres)"
} else {
  Remove-Item Env:\DATABASE_URL -ErrorAction SilentlyContinue
  Write-Output 'DATABASE_URL = (empty, expect storage=memory)'
}

$outLog = Join-Path $env:TEMP "ordo-smoke-$port.out.log"
$errLog = Join-Path $env:TEMP "ordo-smoke-$port.err.log"
Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue

Write-Output '=== starting server (node dist/index.js) ==='
$proc = Start-Process -FilePath 'node' -ArgumentList 'dist/index.js' -PassThru -NoNewWindow `
  -RedirectStandardOutput $outLog -RedirectStandardError $errLog
Write-Output "pid=$($proc.Id)"

# Wait until health check is ready
$ready = $false
foreach ($i in 1..60) {
  Start-Sleep -Milliseconds 250
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/v1/health" -TimeoutSec 2 -UseBasicParsing
    if ($r.StatusCode -eq 200) { $ready = $true; break }
  } catch { }
}
if (-not $ready) {
  Write-Output 'server not ready; stdout/stderr:'
  Get-Content $outLog -ErrorAction SilentlyContinue
  Get-Content $errLog -ErrorAction SilentlyContinue
  if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
  exit 1
}
Write-Output 'health check OK'
Write-Output ''
Write-Output (Get-Content $outLog -Raw)

Write-Output '=== node scripts/smoke.mjs ==='
node scripts/smoke.mjs "http://127.0.0.1:$port"
$smokeExit = $LASTEXITCODE
Write-Output "smoke exit=$smokeExit"

Write-Output ''
Write-Output '=== GET /metrics (first 20 non-comment lines) ==='
try {
  $m = Invoke-WebRequest -Uri "http://127.0.0.1:$port/metrics" -TimeoutSec 5 -UseBasicParsing
  Write-Output "status=$($m.StatusCode) content-type=$($m.Headers['Content-Type'])"
  ($m.Content -split "`n" | Where-Object { $_ -notmatch '^#' -and $_ -ne '' } | Select-Object -First 20) -join "`n"
} catch { Write-Output "metrics request failed: $_" }

Write-Output ''
Write-Output '=== GET /v1/ops/status ==='
try { (Invoke-WebRequest -Uri "http://127.0.0.1:$port/v1/ops/status" -TimeoutSec 5 -UseBasicParsing).Content }
catch { Write-Output "ops/status failed: $_" }

Write-Output ''
Write-Output '=== stopping server ==='
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
Start-Sleep -Milliseconds 800
Write-Output "process exited=$($proc.HasExited)"

Write-Output '=== port release check ==='
$released = $false
foreach ($i in 1..20) {
  if (-not (Test-PortTaken $port)) { $released = $true; break }
  Start-Sleep -Milliseconds 250
}
Write-Output "port $port released=$released"

Write-Output ''
Write-Output '=== server log tail (structured JSON lines) ==='
Get-Content $outLog -Tail 12 -ErrorAction SilentlyContinue

if ($smokeExit -ne 0) { exit $smokeExit }
if (-not $released) { Write-Output 'PORT NOT RELEASED'; exit 1 }
exit 0
