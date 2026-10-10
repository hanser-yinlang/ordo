# Ordo server - guest account smoke verification (contract 7.6 / v1.2)
#
# Usage (Windows PowerShell 5.1 or PowerShell 7):
#   powershell -NoProfile -File scripts\verify-guest-smoke.ps1
#   powershell -NoProfile -File scripts\verify-guest-smoke.ps1 -DatabaseUrl "postgres://ordo:ordo_secret@127.0.0.1:55432/ordo"
#
# What it proves (end to end, against a real running server):
#   1.  POST /v1/auth/guest returns 201 with user.email = null and user.isGuest = true
#   2.  register/login/refresh/guest responses are structurally isomorphic (same keys)
#   3.  a guest is NOT offline mode: push/pull/snapshot persist real data
#   4.  two guests cannot see each other's data (isolation by userId)
#   5.  POST /v1/auth/upgrade keeps the same userId and keeps the data
#   6.  upgrade with an already-taken email returns 409 AUTH_EMAIL_TAKEN
#   7.  a guest calling login is rejected with 401 AUTH_INVALID_CREDENTIALS
#   8.  a non-guest account calling upgrade returns 400 with details.reason = not_guest
#   9.  the server process is stopped and its port is released
#
# NOTE: ASCII-only on purpose - Windows PowerShell 5.1 reads BOM-less UTF-8 .ps1 files as ANSI
#       and corrupts non-ASCII string literals at parse time (see tools/verify.ps1).

param(
  [string]$DatabaseUrl = ''
)

$ErrorActionPreference = 'Continue'
$serverDir = Split-Path -Parent $PSScriptRoot
Set-Location $serverDir

$script:passed = 0
$script:failed = 0
$script:failures = @()

function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) {
    $script:passed++
    Write-Output ("  PASS  " + $name + $(if ($detail) { " - $detail" } else { '' }))
  } else {
    $script:failed++
    $script:failures += $name
    Write-Output ("  FAIL  " + $name + $(if ($detail) { " - $detail" } else { '' }))
  }
}

function Test-PortTaken([int]$p) {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', $p)
    $c.Close()
    return $true
  } catch { return $false }
}

# Pick a free port in the reserved test range
$port = 0
foreach ($candidate in 18080..18099) {
  if (-not (Test-PortTaken $candidate)) { $port = $candidate; break }
}
if ($port -eq 0) { Write-Output 'no free port found'; exit 1 }
Write-Output "=== port $port ==="

$env:PORT = "$port"
$env:HOST = '127.0.0.1'
$env:NODE_ENV = 'production'
$env:JWT_SECRET = 'guest-smoke-secret-please-rotate-0123456789'
# Required in production (contract 7.6.5 / 9): HMAC pepper for email login codes.
# Missing -> the server refuses to start.
$env:ORDO_CODE_PEPPER = 'guest-smoke-code-pepper-please-rotate-0123456789'
$env:LOG_LEVEL = 'info'
$env:TZ_OFFSET_MINUTES = '480'
if ($DatabaseUrl -ne '') {
  $env:DATABASE_URL = $DatabaseUrl
  Write-Output "DATABASE_URL = $DatabaseUrl (expect storage=postgres)"
} else {
  Remove-Item Env:\DATABASE_URL -ErrorAction SilentlyContinue
  Write-Output 'DATABASE_URL = (empty, expect storage=memory)'
}

$outLog = Join-Path $env:TEMP "ordo-guest-$port.out.log"
$errLog = Join-Path $env:TEMP "ordo-guest-$port.err.log"
Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue

Write-Output '=== starting server (node dist/index.js) ==='
$proc = Start-Process -FilePath 'node' -ArgumentList 'dist/index.js' -PassThru -NoNewWindow `
  -RedirectStandardOutput $outLog -RedirectStandardError $errLog
Write-Output "pid=$($proc.Id)"

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

$base = "http://127.0.0.1:$port"

# Invoke-Json returns @{ status = <int>; body = <object|null> }
function Invoke-Json([string]$method, [string]$path, $body, [string]$token) {
  $headers = @{ 'x-ordo-schema' = '1' }
  if ($token) { $headers['authorization'] = "Bearer $token" }
  # NOTE: do NOT name this $args - that is a PowerShell automatic variable.
  $reqArgs = @{
    Uri             = "$base$path"
    Method          = $method
    Headers         = $headers
    TimeoutSec      = 10
    UseBasicParsing = $true
  }
  if ($null -ne $body) {
    $reqArgs['ContentType'] = 'application/json'
    $reqArgs['Body'] = ($body | ConvertTo-Json -Depth 12 -Compress)
  }
  try {
    $res = Invoke-WebRequest @reqArgs
    return @{ status = [int]$res.StatusCode; body = ($res.Content | ConvertFrom-Json) }
  } catch {
    $status = 0
    $text = ''
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    # IMPORTANT (Windows PowerShell 5.1): $_.Exception.Response.GetResponseStream() reads back EMPTY
    # for an error response; the body lives in $_.ErrorDetails.Message. PowerShell 7 fills both,
    # so prefer ErrorDetails and fall back to the stream. (This cost a debugging round - do not regress.)
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
      $text = $_.ErrorDetails.Message
    } elseif ($_.Exception.Response) {
      try {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $text = $reader.ReadToEnd()
      } catch { $text = '' }
    }
    $parsed = $null
    if ($text) { try { $parsed = $text | ConvertFrom-Json } catch { $parsed = $null } }
    return @{ status = $status; body = $parsed }
  }
}

function New-Guest([string]$deviceId) {
  return Invoke-Json 'POST' '/v1/auth/guest' @{ deviceId = $deviceId; deviceName = 'guest-smoke'; platform = 'cli' } ''
}

function Sync-Push([string]$token, [string]$deviceId, [string]$todoId, [string]$title, [long]$clientTs) {
  $todo = @{
    id          = $todoId
    title       = $title
    note        = ''
    when        = 'inbox'
    date        = $null
    reminder    = $null
    deadline    = $null
    tags        = @()
    checklist   = @()
    projectId   = $null
    areaId      = $null
    headingId   = $null
    repeat      = $null
    order       = 0
    status      = 'open'
    createdAt   = $clientTs
    updatedAt   = $clientTs
    completedAt = $null
    deleted     = $false
  }
  $opId = "op_guest_" + [guid]::NewGuid().ToString('N').Substring(0, 12)
  return Invoke-Json 'POST' '/v1/sync/push' @{
    deviceId = $deviceId
    sinceSeq = $null
    ops      = @(@{
        opId     = $opId
        deviceId = $deviceId
        entity   = 'todo'
        entityId = $todoId
        type     = 'upsert'
        payload  = $todo
        clientTs = $clientTs
      })
  } $token
}

Write-Output ''
Write-Output '=== guest auth flow ==='

$guestA = New-Guest 'dev_guest_smoke_a'
Check 'POST /v1/auth/guest -> 201' ($guestA.status -eq 201) ("status=" + $guestA.status)

$bodyA = $guestA.body
Check 'guest user.email is null' ($null -eq $bodyA.user.email) 'email=(null)'
Check 'guest user.isGuest is true' ($bodyA.user.isGuest -eq $true) ("isGuest=" + $bodyA.user.isGuest)
Check 'guest response has device/accessToken/refreshToken/expiresIn' `
  (($null -ne $bodyA.device.id) -and ($bodyA.accessToken.Length -gt 20) -and ($bodyA.refreshToken.Length -ge 40) -and ($bodyA.expiresIn -gt 0)) `
  ("device=" + $bodyA.device.id + " expiresIn=" + $bodyA.expiresIn)

# Structural isomorphism: guest vs register response must expose the same top-level keys
$regEmail = "guest_smoke_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '@example.com'
$reg = Invoke-Json 'POST' '/v1/auth/register' @{ email = $regEmail; password = 'password123'; deviceName = 'member'; platform = 'cli' } ''
Check 'POST /v1/auth/register -> 201 (isGuest=false)' ($reg.status -eq 201 -and $reg.body.user.isGuest -eq $false) ("status=" + $reg.status)

$guestKeys = ($bodyA.PSObject.Properties.Name | Sort-Object) -join ','
$regKeys = ($reg.body.PSObject.Properties.Name | Sort-Object) -join ','
Check 'guest and register responses are isomorphic (same top-level keys)' ($guestKeys -eq $regKeys) ("guest=[$guestKeys] register=[$regKeys]")

$userKeys = ($bodyA.user.PSObject.Properties.Name | Sort-Object) -join ','
$regUserKeys = ($reg.body.user.PSObject.Properties.Name | Sort-Object) -join ','
Check 'guest and register user projections match' ($userKeys -eq $regUserKeys) ("guest=[$userKeys] register=[$regUserKeys]")

# refresh carries user.isGuest too, and keeps the same userId
$refresh = Invoke-Json 'POST' '/v1/auth/refresh' @{ refreshToken = $bodyA.refreshToken } ''
Check 'POST /v1/auth/refresh carries user.isGuest' `
  ($refresh.status -eq 200 -and $refresh.body.user.isGuest -eq $true -and $refresh.body.user.id -eq $bodyA.user.id) `
  ("status=" + $refresh.status + " isGuest=" + $refresh.body.user.isGuest)

$tokenA = $refresh.body.accessToken
$refreshA = $refresh.body.refreshToken

# A guest must not be able to log in (no password to verify against)
$guestLogin = Invoke-Json 'POST' '/v1/auth/login' @{ email = 'guest_smoke_nobody@example.com'; password = 'password123' } ''
Check 'guest login attempt -> 401 AUTH_INVALID_CREDENTIALS' `
  ($guestLogin.status -eq 401 -and $guestLogin.body.error.code -eq 'AUTH_INVALID_CREDENTIALS') `
  ("status=" + $guestLogin.status + " code=" + $guestLogin.body.error.code)

Write-Output ''
Write-Output '=== guest data is real and isolated ==='

$guestB = New-Guest 'dev_guest_smoke_b'
$tokenB = $guestB.body.accessToken
Check 'second guest is a different account' ($guestB.status -eq 201 -and $guestB.body.user.id -ne $bodyA.user.id) `
  ("A=" + $bodyA.user.id + " B=" + $guestB.body.user.id)

$clientTs = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
$pushA = Sync-Push $tokenA 'dev_guest_smoke_a' ([guid]::NewGuid().ToString()) 'guest A todo' $clientTs
Check 'guest A push applied (not offline mode)' ($pushA.status -eq 200 -and $pushA.body.accepted[0].applied -eq $true) ("status=" + $pushA.status)

$pushB = Sync-Push $tokenB 'dev_guest_smoke_b' ([guid]::NewGuid().ToString()) 'guest B todo' ($clientTs + 1)
Check 'guest B push applied' ($pushB.status -eq 200 -and $pushB.body.accepted[0].applied -eq $true) ("status=" + $pushB.status)

$snapA = Invoke-Json 'GET' '/v1/sync/snapshot' $null $tokenA
$snapB = Invoke-Json 'GET' '/v1/sync/snapshot' $null $tokenB
Check 'guest A sees only its own todo' ($snapA.status -eq 200 -and $snapA.body.todos.Count -eq 1 -and $snapA.body.todos[0].title -eq 'guest A todo') `
  ("todos=" + $snapA.body.todos.Count + " title=" + $snapA.body.todos[0].title)
Check 'guest B sees only its own todo (no cross-user leak)' ($snapB.status -eq 200 -and $snapB.body.todos.Count -eq 1 -and $snapB.body.todos[0].title -eq 'guest B todo') `
  ("todos=" + $snapB.body.todos.Count + " title=" + $snapB.body.todos[0].title)

$pullA = Invoke-Json 'GET' '/v1/sync/pull?sinceSeq=0&limit=100' $null $tokenA
Check 'guest pull returns exactly its own ops' ($pullA.status -eq 200 -and $pullA.body.ops.Count -eq 1) ("ops=" + $pullA.body.ops.Count)

Write-Output ''
Write-Output '=== upgrade guest -> member ==='

$upgradeEmail = "upgraded_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '@example.com'
$upgrade = Invoke-Json 'POST' '/v1/auth/upgrade' @{ email = $upgradeEmail; password = 'password123' } $tokenA
Check 'POST /v1/auth/upgrade -> 200 with isGuest=false' `
  ($upgrade.status -eq 200 -and $upgrade.body.user.isGuest -eq $false -and $upgrade.body.user.email -eq $upgradeEmail) `
  ("status=" + $upgrade.status + " body=" + ($upgrade.body | ConvertTo-Json -Compress))
Check 'upgrade keeps the same userId' ($upgrade.body.user.id -eq $bodyA.user.id) ("id=" + $upgrade.body.user.id)

$snapAfter = Invoke-Json 'GET' '/v1/sync/snapshot' $null $tokenA
Check 'data survives the upgrade (same userId, same todo)' `
  ($snapAfter.status -eq 200 -and $snapAfter.body.todos.Count -eq 1 -and $snapAfter.body.todos[0].title -eq 'guest A todo') `
  ("todos=" + $snapAfter.body.todos.Count)

$oldRefresh = Invoke-Json 'POST' '/v1/auth/refresh' @{ refreshToken = $refreshA } ''
Check 'refreshToken issued while guest still works after upgrade' `
  ($oldRefresh.status -eq 200 -and $oldRefresh.body.user.id -eq $bodyA.user.id -and $oldRefresh.body.user.isGuest -eq $false) `
  ("status=" + $oldRefresh.status + " isGuest=" + $oldRefresh.body.user.isGuest)

# Duplicate upgrade: the same account is no longer a guest -> 400 not_guest
$again = Invoke-Json 'POST' '/v1/auth/upgrade' @{ email = "again_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '@example.com'; password = 'password123' } $tokenA
Check 'second upgrade of the same account -> 400 not_guest' `
  ($again.status -eq 400 -and $again.body.error.details.reason -eq 'not_guest') `
  ("status=" + $again.status + " reason=" + $again.body.error.details.reason)

# Email already taken -> 409 AUTH_EMAIL_TAKEN
$guestC = New-Guest 'dev_guest_smoke_c'
$taken = Invoke-Json 'POST' '/v1/auth/upgrade' @{ email = $regEmail; password = 'password123' } $guestC.body.accessToken
Check 'upgrade with a taken email -> 409 AUTH_EMAIL_TAKEN' `
  ($taken.status -eq 409 -and $taken.body.error.code -eq 'AUTH_EMAIL_TAKEN') `
  ("status=" + $taken.status + " code=" + $taken.body.error.code)

# Registered (non-guest) account calling upgrade -> 400 not_guest
$memberUpgrade = Invoke-Json 'POST' '/v1/auth/upgrade' @{ email = "member_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '@example.com'; password = 'password123' } $reg.body.accessToken
Check 'non-guest account upgrade -> 400 not_guest' `
  ($memberUpgrade.status -eq 400 -and $memberUpgrade.body.error.details.reason -eq 'not_guest') `
  ("status=" + $memberUpgrade.status + " reason=" + $memberUpgrade.body.error.details.reason)

# After upgrade the account works with normal login
$memberLogin = Invoke-Json 'POST' '/v1/auth/login' @{ email = $upgradeEmail; password = 'password123' } ''
Check 'upgraded account can log in normally (isGuest=false)' `
  ($memberLogin.status -eq 200 -and $memberLogin.body.user.id -eq $bodyA.user.id -and $memberLogin.body.user.isGuest -eq $false) `
  ("status=" + $memberLogin.status)

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
Check 'port released after shutdown' $released

Write-Output ''
Write-Output '=== server log tail (structured JSON lines) ==='
Get-Content $outLog -Tail 8 -ErrorAction SilentlyContinue

Write-Output ''
Write-Output ("guest flow: " + $script:passed + " passed / " + $script:failed + " failed")
if ($script:failed -gt 0) {
  Write-Output 'failed checks:'
  foreach ($f in $script:failures) { Write-Output ("  - " + $f) }
  exit 1
}
Write-Output 'all guest checks passed'
exit 0
