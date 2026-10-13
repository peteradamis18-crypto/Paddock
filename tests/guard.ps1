# Shared safety guard for every test (dot-source it first:  . (Join-Path $PSScriptRoot 'guard.ps1')).
# Why: on 2026-10-09 test runs collided twice with Peter's real races (a pretend race on his top screen, overlays and
# CrewChief stopped 10 s before his session ended). Tests must never run while he is racing or about to.
#
#   Assert-RigFree              stop now if the sim is running or a START key was pressed in the last 10 minutes
#   Assert-RigFree -NeedAway    also require 10 minutes with no keyboard/mouse input (for tests that start the real sim
#                               or click in the iRacing app themselves: actions, mydrive, friends -Live)
#   Assert-RigFree -Where 'x'   use between sections; throws (so the test's finally block puts everything back)
#   $env:RIG_TEST_OWNS_SIM=1    set by a test right after IT started the sim, so its own sim does not stop it
#   Enter-TestLock 'name'       live tests take turns: waits up to 15 min for another live test (named mutex), then Assert-RigFree
#   Exit-TestLock               release it in the test's finally (the mutex also frees itself when the process ends)
#
# irdash itself also refuses the test hook (HTTP 409) while a real session is on (dash\src\irdash.cs Sdk.RealBusy).
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RigGuard {
  [StructLayout(LayoutKind.Sequential)] struct LII { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LII p);
  public static double IdleMinutes() { LII l = new LII(); l.cbSize = 8; if (!GetLastInputInfo(ref l)) return 0; return ((uint)Environment.TickCount - l.dwTime) / 60000.0; }
}
'@ -ErrorAction SilentlyContinue

# Keep the screens awake while a test runs (2026-10-11): at night Windows puts the session to sleep after 15 minutes without
# input and Chrome then stops painting its kiosk window. The real top screen froze at 01:48 and data-test's flag pictures
# (taken at 01:55) were all that frozen home page. This is the same request a video player makes: it lasts only as long as
# this PowerShell process lives, changes no Windows setting and does not count as keyboard/mouse input (IdleMinutes is unchanged).
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RigAwake {
  [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
  public static void Keep() { SetThreadExecutionState(0x80000000 | 0x00000002 | 0x00000001); }   // ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED
}
'@ -ErrorAction SilentlyContinue
try { [RigAwake]::Keep() } catch { }

$script:guardRoot = Split-Path -Parent $PSScriptRoot

function Get-RigBusy {
  if (-not $env:RIG_TEST_OWNS_SIM -and (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue)) { return 'the iRacing sim is running' }
  $mark = Join-Path $script:guardRoot 'dash\start-mark.txt'
  if (Test-Path $mark) {
    $p = ([IO.File]::ReadAllText($mark)).Split("`t")
    $t = 0L
    if ($p.Count -gt 1 -and $p[1].Trim() -ne 'TEST' -and [long]::TryParse($p[0], [ref]$t)) {
      $age = ([DateTime]::UtcNow - (New-Object DateTime $t, ([DateTimeKind]::Utc))).TotalMinutes
      if ($age -lt 10 -and -not $env:RIG_TEST_OWNS_SIM) { return "a START key was pressed $([math]::Round($age, 1)) minutes ago" }
    }
  }
  return $null
}

function Assert-RigFree([switch]$NeedAway, [string]$Where = '') {
  $why = Get-RigBusy
  if (-not $why -and $NeedAway) {
    $idle = [RigGuard]::IdleMinutes()
    $need = 10.0
# input this test produced itself (airace typing, quit clicks) is not Peter: tests touch tests\last\own-input.txt after each command they send
$own = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\last\own-input.txt'
if ($env:RIG_TEST_OWNS_SIM -and (Test-Path $own)) { $lastInput = (Get-Date).AddMinutes(-$idle); if ($lastInput -le (Get-Item $own).LastWriteTime.AddSeconds(3)) { $idle = 999 } }
# Peter said in chat he is away (the lead writes away-ok.txt, valid 60 min): 30 s without input is enough; touching the PC still stops a test
$okf = Join-Path (Split-Path -Parent $PSScriptRoot) 'away-ok.txt'
if ((Test-Path $okf) -and ((Get-Date) - (Get-Item $okf).LastWriteTime).TotalMinutes -lt 60) { $need = 0.5 }
if ($idle -lt $need) { $why = "Peter used the PC $([math]::Round($idle, 1)) minutes ago (this test drives the real sim; it needs him away for $need minutes)" }
  }
  if (-not $why) { return }
  $msg = if ($Where) { "NOT SAFE TO GO ON: $why (at '$Where'). Stopping and putting everything back." } else { "NOT SAFE TO TEST: $why. Nothing was changed." }
  if ($Where) { throw $msg }
  Write-Output $msg
  exit 3
}

# One live test at a time (2026-10-11): live tests share dash\test-hook.on, dash\deploy.lock and the Chrome debugging
# ports, so two at once break each other. The named mutex is machine-wide; a test waits for the other one to finish.
# Call Enter-TestLock before the test's try block and Exit-TestLock in its finally. If the holder process dies, Windows
# hands the mutex on (AbandonedMutexException = the lock is ours now).
$script:testLock = $null
function Enter-TestLock([string]$Who = 'a test', [double]$WaitMinutes = 15, [string]$Name = 'Global\PaddockLiveTest') {
  if ($script:testLock) { return }
  $mx = New-Object Threading.Mutex($false, $Name)
  $got = $false
  try { $got = $mx.WaitOne(0) } catch [Threading.AbandonedMutexException] { $got = $true }
  if (-not $got) {
    Write-Output "  waiting: another live test holds the test lock; $Who starts when it finishes (gives up after $WaitMinutes minutes)"
    $until = (Get-Date).AddMinutes($WaitMinutes)
    while (-not $got) {
      $left = [math]::Min(30000, [math]::Max(0, ($until - (Get-Date)).TotalMilliseconds))
      try { $got = $mx.WaitOne([int]$left) } catch [Threading.AbandonedMutexException] { $got = $true }
      if (-not $got -and (Get-Date) -ge $until) {
        $mx.Dispose()
        Write-Output "NOT RUN ($Who): another live test still holds the test lock after $WaitMinutes minutes. Nothing was changed."
        exit 3
      }
    }
  }
  $script:testLock = $mx
  Assert-RigFree   # the sim may have started while we waited
}

function Exit-TestLock {
  $mx = $script:testLock; if (-not $mx) { return }
  $script:testLock = $null
  try { $mx.ReleaseMutex() } catch { }
  try { $mx.Dispose() } catch { }
}
