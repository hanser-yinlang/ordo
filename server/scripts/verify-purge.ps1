# Ordo server - live check of the tombstone purge scheduler (short interval)
#
# Usage (Windows PowerShell 5.1 or PowerShell 7):
#   powershell -File scripts/verify-purge.ps1
#
# NOTE: ASCII-only on purpose (Windows PowerShell 5.1 reads BOM-less UTF-8 .ps1 as ANSI).

$ErrorActionPreference = 'Continue'
$serverDir = Split-Path -Parent $PSScriptRoot
Set-Location $serverDir

function Test-PortTaken([int]$p) {
  try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $p); $c.Close(); return $true }
  catch { return $false }
}

$port = 0
foreach ($candidate in 18080..18099) { if (-not (Test-PortTaken $candidate)) { $port = $candidate; break } }
if ($port -eq 0) { Write-Output 'no free port'; exit 1 }

$env:PORT = "$port"
$env:HOST = '127.0.0.1'
$env:NODE_ENV = 'production'
$env:JWT_SECRET = 'purge-check-secret-0123456789abcdef'
$env:LOG_LEVEL = 'info'
# 200ms period, 1ms TTL -> every run purges (so runs counter must climb)
$env:TOMBSTONE_PURGE_INTERVAL_MS = '200'
$env:TOMBSTONE_TTL_MS = '1'
Remove-Item Env:\DATABASE_URL -ErrorAction SilentlyContinue

$outLog = Join-Path $env:TEMP "ordo-purge-$port.out.log"
$errLog = Join-Path $env:TEMP "ordo-purge-$port.err.log"
Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue

$proc = Start-Process -FilePath 'node' -ArgumentList 'dist/index.js' -PassThru -NoNewWindow `
  -RedirectStandardOutput $outLog -RedirectStandardError $errLog

$ready = $false
foreach ($i in 1..60) {
  Start-Sleep -Milliseconds 250
  try { if ((Invoke-WebRequest -Uri "http://127.0.0.1:$port/v1/health" -TimeoutSec 2 -UseBasicParsing).StatusCode -eq 200) { $ready = $true; break } } catch { }
}
if (-not $ready) {
  Write-Output 'server not ready'
  if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
  exit 1
}

# Let several purge periods elapse
Start-Sleep -Milliseconds 1500

$status = (Invoke-WebRequest -Uri "http://127.0.0.1:$port/v1/ops/status" -TimeoutSec 5 -UseBasicParsing).Content
$metrics = (Invoke-WebRequest -Uri "http://127.0.0.1:$port/metrics" -TimeoutSec 5 -UseBasicParsing).Content

Stop-Process -Id $proc.Id -Force
$proc.WaitForExit(10000) | Out-Null
Start-Sleep -Milliseconds 400
$released = -not (Test-PortTaken $port)

$outText = ''
if (Test-Path $outLog) { $outText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($outLog)) }

Write-Output '=== /v1/ops/status ==='
Write-Output $status
Write-Output ''
Write-Output '=== purge metrics ==='
($metrics -split "`n" | Where-Object { $_ -match 'tombstone' }) -join "`n"
Write-Output ''
Write-Output '=== purge log lines (event=tombstone_purge*) ==='
($outText -split "`n" | Where-Object { $_ -match 'tombstone_purge' } | Select-Object -First 4) -join "`n"
Write-Output ''
Write-Output "port released = $released"

$runMatch = [regex]::Match($metrics, 'ordo_tombstone_purge_runs_total\{result="ok"\} (\d+)')
$runs = if ($runMatch.Success) { [int]$runMatch.Groups[1].Value } else { 0 }
Write-Output "purge ok runs = $runs"

if ($runs -lt 3) { Write-Output 'FAIL: scheduler did not run on the configured interval'; exit 1 }
if (-not $released) { Write-Output 'FAIL: port not released'; exit 1 }
Write-Output 'purge scheduler check PASSED'
exit 0
