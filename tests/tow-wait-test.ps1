# RESET CAR / TOW after a crash: if the car is still moving, wait until it is nearly stopped, then tow.
# Pretend speeds exercise the same decision the live wait uses. No keys. This script does not start the sim.
# The live stationary tow (log line "back in the car in the pits") runs only when the sim is already
# up, Peter has been away for 10 minutes, and the car is stopped (not a replay). In that one case it
# claims the sim before the guard, then tows. Any other running sim stops the test, as usual.
#   powershell -ExecutionPolicy Bypass -File tests\tow-wait-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'guard.ps1')
if (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue) {
  if ([RigGuard]::IdleMinutes() -ge 10) {
    $pre = & (Join-Path $root 'irdeck-cli.exe') sess 2>&1 | Out-String
    # speed= must be the last -match: $Matches is what the next comparison reads
    if ($pre -match 'onTrack=True' -and $pre -notmatch 'replay=True' -and $pre -match 'speed=([0-9.]+)' -and [double]$Matches[1] -le 1.0) {
      $env:RIG_TEST_OWNS_SIM = '1'
    }
  }
}
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "  ok    $what" } else { $script:fail++; Write-Host "  FAIL  $what" } }
function Note($what) { Write-Host "  info  $what" }
function Section($title) { Assert-RigFree -Where $title; Write-Host $title }
$cli = Join-Path $root 'irdeck-cli.exe'
$flag = Join-Path $root 'dash\tow-wait.txt'
function Ir {
  $o = & $cli @args 2>&1 | ForEach-Object { "$_" }
  [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join "`n") }
}

'Tow wait test'
Section '1. pretend speeds: stop, wait, give up'
$src = Get-Content (Join-Path $root 'src\irdeck.cs') -Raw
Check 'the wait and the old stopped-car tow are both in CmdTow' ($src -match 'TowWaitLive\(ref inCar, ref speed\)' -and $src -match 'SendCombo\("esc", 1800\)' -and $src -match 'tow refused: the car is moving')
Check 'guest reset still tows, and a give-up is not a fresh car' ((Get-Content (Join-Path $root 'src\guest.cs') -Raw) -match 'int rc = CmdTow\(\)' -and (Get-Content (Join-Path $root 'src\guest.cs') -Raw) -match 'rc == 4')
if ($src -notmatch 'const int TowPollMs = (\d+);' -or $src -notmatch 'const int TowLimitMs = (\d+);') { Check 'poll and limit constants are present' $false; $poll = 250; $limit = 20000 }
else {
  $poll = [int]([regex]::Match($src, 'const int TowPollMs = (\d+);').Groups[1].Value)
  $limit = [int]([regex]::Match($src, 'const int TowLimitMs = (\d+);').Groups[1].Value)
  Check 'the wait is about 20 s, polled several times a second' ($limit -ge 15000 -and $limit -le 25000 -and $poll -ge 100 -and $poll -le 1000)
}
if (Test-Path $flag) { Remove-Item $flag -Force }

$r = Ir tow --pretend 0.4
Check 'already at 0.4 m/s does not wait' ($r.rc -eq 0 -and $r.out -match 'tow: stationary' -and $r.out -notmatch 'waiting')
Check 'a stopped pretend does not light the top-screen line' (-not (Test-Path $flag))

$r = Ir tow --pretend 1.0
Check '1.0 m/s counts as stopped (same line as the old refuse)' ($r.rc -eq 0 -and $r.out -match 'tow: stationary' -and $r.out -notmatch 'waiting')

$r = Ir tow --pretend '1.2,0.5'
Check 'just over 1 m/s waits, then would tow' ($r.rc -eq 0 -and $r.out -match 'waiting for the car to stop \(1\.2 m/s\)' -and $r.out -match 'the car has stopped \(0\.5 m/s\)' -and $r.out -match 'would tow now')
Check 'the line is cleared once the pretend car has stopped' (-not (Test-Path $flag))

$r = Ir tow --pretend '18.5,9,0.4'
Check 'a slide that stops would tow, and says the speed it stopped at' ($r.rc -eq 0 -and $r.out -match 'waiting for the car to stop \(18\.5 m/s\)' -and $r.out -match 'the car has stopped \(0\.4 m/s\)' -and $r.out -match 'would tow now')

$steps = [int][Math]::Ceiling($limit / [double]$poll)
$speeds = (@(1..($steps + 1) | ForEach-Object { '30' })) -join ','
$r = Ir tow --pretend $speeds
Check 'still moving after the limit gives up quietly' ($r.rc -eq 0 -and $r.out -match 'still moving after 20 s \(30\.0 m/s\), leaving it' -and $r.out -notmatch 'would tow now')
Check 'giving up clears the top-screen line' (-not (Test-Path $flag))

$r = Ir tow --pretend
Check 'pretend without speeds is refused' ($r.rc -ne 0 -and $r.out -match 'pretend needs speeds')

Section '2. a second press during the wait does nothing'
$outA = Join-Path $env:TEMP 'paddock-c26-hold.txt'
$errA = Join-Path $env:TEMP 'paddock-c26-hold-err.txt'
if (Test-Path $flag) { Remove-Item $flag -Force }
$hold = Start-Process -FilePath $cli -ArgumentList @('tow', '--pretend', '30,30', '--hold', '2500') -WorkingDirectory $root -RedirectStandardOutput $outA -RedirectStandardError $errA -PassThru -WindowStyle Hidden
try {
  $seen = $false
  for ($i = 0; $i -lt 40; $i++) { if (Test-Path $flag) { $seen = $true; break }; Start-Sleep -Milliseconds 50 }
  Check 'the wait publishes a line for the top screen' $seen
  $ticks = 0L
  if ($seen) { [long]::TryParse((Get-Content $flag -Raw).Trim(), [ref]$ticks) | Out-Null }
  Check 'the line expires on its own if the wait is cut off' ($ticks -gt [DateTime]::UtcNow.Ticks)
  $r2 = Ir tow --pretend '5,0.2'
  Check 'the second press does nothing' ($r2.rc -eq 0 -and $r2.out -match 'already in progress' -and $r2.out -notmatch 'would tow now' -and $r2.out -notmatch 'stationary')
  Check 'the second press does not clear the line' (Test-Path $flag)
  if (-not $hold.WaitForExit(8000)) { try { $hold.Kill() } catch { }; Check 'the first wait finished' $false }
  else { Check 'the first wait finished' $true }
  Start-Sleep -Milliseconds 200
  $held = @(Get-Content $outA -ErrorAction SilentlyContinue) -join "`n"
  Check 'the first press was the one waiting, and it did not tow' ($held -match 'waiting for the car to stop' -and $held -match 'pretend ended while still waiting' -and $held -notmatch 'would tow now')
  Check 'the line is gone when the wait ends' (-not (Test-Path $flag))
}
finally {
  if ($hold -and -not $hold.HasExited) { try { $hold.Kill() } catch { } }
  if (Test-Path $flag) { Remove-Item $flag -Force -ErrorAction SilentlyContinue }
}

Section '3. the top screen line, not a race-screen popup'
$ui = Get-Content (Join-Path $root 'dash\www\v2\ui.js') -Raw
$css = Get-Content (Join-Path $root 'dash\www\v2\style.css') -Raw
$guestCss = Get-Content (Join-Path $root 'dash\www\v2\guest.css') -Raw
Check 'the dashboard says it is waiting for the car to stop' ($ui -match 'Reset car .{1,4} waiting for the car to stop')
Check 'that line is one bar above the Friends view' ($css -match '#towWait' -and $css -match 'z-index:\s*955' -and $guestCss -match 'z-index:\s*930')
Check 'the race-screen delta bar does not say it' ((Get-Content (Join-Path $root 'dash\src\deltabar.cs') -Raw) -notmatch 'waiting for the car to stop')
Check 'the deck add-on was not changed for this' ((Get-Content (Join-Path $root 'deck-intro\plugin.html') -Raw) -notmatch 'waiting for the car to stop')
$dash = Get-Content (Join-Path $root 'dash\src\irdash.cs') -Raw
Check 'irdash answers /api/tow-wait from the flag file' ($dash -match '/api/tow-wait' -and $dash -match 'tow-wait\.txt')
$idle = $null; $page = $null; $httpErr = ''
for ($try = 0; $try -lt 8; $try++) {
  try {
    $idle = Invoke-RestMethod 'http://localhost:8199/api/tow-wait' -TimeoutSec 3
    $page = (Invoke-WebRequest 'http://localhost:8199/v2/ui.js' -UseBasicParsing -TimeoutSec 3).Content
    $httpErr = ''; break
  } catch { $httpErr = $_.Exception.Message; Start-Sleep -Seconds 1 }
}
if ($httpErr) {
  Check 'the running dashboard answers /api/tow-wait (deploy irdash if this is 404)' $false
  Note $httpErr
} else {
  Check 'the top screen is not showing the line when nothing is waiting' ($idle.on -eq $false)
  Check 'the running dashboard page has the calm line' ($page -match 'waiting for the car to stop')
}

Section '4. live stationary tow'
$idleMin = [RigGuard]::IdleMinutes()
if ($idleMin -lt 10) {
  Note ("live tow not run: Peter used the PC {0} minutes ago. When he has been away 10 minutes, with the car stopped: irdeck-cli tow should log back in the car in the pits, and not 'waiting'." -f [math]::Round($idleMin, 1))
} else {
  $sess = Ir sess
  if ($sess.out -notmatch 'onTrack=True' -or $sess.out -match 'replay=True' -or $sess.out -notmatch 'speed=([0-9.]+)' -or [double]$Matches[1] -gt 1.0) {
    Note 'live tow not run: no stopped car in a session (a replay does not count). This test does not start the sim.'
  } else {
    $env:RIG_TEST_OWNS_SIM = '1'
    $t = Ir tow
    Check 'stopped car still ends back in the car in the pits' ($t.rc -eq 0 -and $t.out -match 'back in the car in the pits' -and $t.out -notmatch 'waiting for the car to stop')
  }
}

Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0
