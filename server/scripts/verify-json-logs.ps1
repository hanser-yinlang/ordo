# Ordo server - assert stdout is pure JSON lines (structured logging contract)
#
# Usage (Windows PowerShell 5.1 or PowerShell 7):
#   powershell -File scripts/verify-json-logs.ps1
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
$env:JWT_SECRET = 'json-log-check-secret-0123456789abcdef'
# Required in production (contract 7.6.5 / 9): HMAC pepper for email login codes.
# Missing -> the server refuses to start.
$env:ORDO_CODE_PEPPER = 'json-log-check-code-pepper-0123456789abcdef'
$env:LOG_LEVEL = 'info'
Remove-Item Env:\DATABASE_URL -ErrorAction SilentlyContinue

$outLog = Join-Path $env:TEMP "ordo-jsonlog-$port.out.log"
$errLog = Join-Path $env:TEMP "ordo-jsonlog-$port.err.log"
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

# Drive a little traffic so there are request logs too
try { $null = Invoke-WebRequest -Uri "http://127.0.0.1:$port/v1/sync/snapshot" -TimeoutSec 5 -UseBasicParsing } catch { }
try { $null = Invoke-WebRequest -Uri "http://127.0.0.1:$port/metrics" -TimeoutSec 5 -UseBasicParsing } catch { }

# Graceful shutdown via SIGTERM is not available from PowerShell; force-stop then wait.
Stop-Process -Id $proc.Id -Force
$proc.WaitForExit(10000) | Out-Null
Start-Sleep -Milliseconds 500

$released = -not (Test-PortTaken $port)

$outText = ''
if (Test-Path $outLog) { $outText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($outLog)) }
$errText = ''
if (Test-Path $errLog) { $errText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($errLog)) }

$ok = 0; $bad = 0; $badLines = @()
foreach ($line in ($outText -split "`n")) {
  $t = $line.Trim()
  if (-not $t) { continue }
  try { $null = $t | ConvertFrom-Json; $ok++ } catch { $bad++; $badLines += $t }
}

Write-Output "port              = $port"
Write-Output "port released     = $released"
Write-Output "stdout JSON lines = $ok"
Write-Output "stdout bad lines  = $bad"
if ($badLines.Count -gt 0) {
  Write-Output '--- non-JSON stdout lines (first 5) ---'
  $badLines | Select-Object -First 5
}
Write-Output "stderr has banner = $($errText -match 'Ordo')"
Write-Output "redacted fields   = $(([regex]::Matches($outText, '\[Redacted\]')).Count)"

$fail = $false
if ($bad -ne 0) { Write-Output 'FAIL: stdout contains non-JSON lines'; $fail = $true }
if ($ok -lt 5) { Write-Output 'FAIL: too few JSON log lines'; $fail = $true }
if (-not $released) { Write-Output 'FAIL: port not released'; $fail = $true }
if (-not ($errText -match 'Ordo')) { Write-Output 'FAIL: banner missing on stderr'; $fail = $true }

if ($fail) { exit 1 }
Write-Output 'JSON log check PASSED'
exit 0
