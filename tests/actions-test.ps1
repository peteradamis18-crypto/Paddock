# Every Stream Deck ACTION key, end to end, in real sessions (the real sim starts; you must not be in the car):
#   AI race: startlast ai, getout, go, tow, replay, RESTART RACE (pressed twice), skip, quit mid-race
#   Test drive: startlast td, quitmain
#   Friends START (and its wheel strength put back), then quitmain
# Each action's END STATE is read from the sim's own telemetry (session number, time, in the car, pit road, session over)
# and the iRacing UI (Home, nothing over it). Every dialog the sim or the UI shows is saved to tests\shots\a-*.png
# (irdeck saves them while IRDECK_SHOTS is set). Ends with iRacing back on Home.
#   powershell -ExecutionPolicy Bypass -File tests\actions-test.ps1 [-NoFriends] [-NoTestDrive]
param([switch]$NoFriends, [switch]$NoTestDrive)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$env:IRDECK_SHOTS = $shots
$cli = Join-Path $root 'irdeck-cli.exe'
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$mid = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.X -eq 0 -and $_.Bounds.Y -eq 0 } | Select-Object -First 1
function Shot($name) {
  $b = $mid.Bounds; $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height; $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $s = New-Object System.Drawing.Bitmap $bmp, 1280, 720; $s.Save((Join-Path $shots "a-$name.png")); $g.Dispose(); $bmp.Dispose(); $s.Dispose()
}
# run an irdeck command; returns rc and what it printed
function Ir {
  $o = & $cli @args 2>&1 | ForEach-Object { "$_" }
  [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join "`n") }
}
function Sess {
  $o = (Ir sess).out
  $m = [regex]::Match($o, 'session (\d+) (.+?) \(state (\d+)\), event (\S+), ai=(\w+), onTrack=(\w+), onPit=(\w+), speed=([\d.]+), replay=(\w+), time=(\d+)s, left=(-?\d+)s, frame=(-?\d+), ffb=(-?[\d.]+)')
  if (-not $m.Success) { return [pscustomobject]@{ live = $false; num = -1; type = ''; state = 0; ai = $false; onTrack = $false; onPit = $false; speed = 0; replay = $false; time = 0; frame = 0; ffb = -1 } }
  [pscustomobject]@{ live = $true; num = [int]$m.Groups[1].Value; type = $m.Groups[2].Value; state = [int]$m.Groups[3].Value; ai = $m.Groups[5].Value -eq 'True'; onTrack = $m.Groups[6].Value -eq 'True'; onPit = $m.Groups[7].Value -eq 'True'
                     speed = [double]$m.Groups[8].Value; replay = $m.Groups[9].Value -eq 'True'; time = [int]$m.Groups[10].Value; frame = [int]$m.Groups[12].Value; ffb = [double]$m.Groups[13].Value }
}
function WaitSess($cond, $secs = 20) { for ($i = 0; $i -lt $secs * 2; $i++) { $s = Sess; if (& $cond $s) { return $s }; Start-Sleep -Milliseconds 500 }; return (Sess) }
function Timed($sb) { $t = [Diagnostics.Stopwatch]::StartNew(); $r = & $sb; [pscustomobject]@{ r = $r; secs = [int]$t.Elapsed.TotalSeconds } }
# the iRacing UI shows Home with nothing over it (read-only look at its accessibility tree).
# A results window has Event Log / Lap Graph tabs (its Back link is greyed, so it is not named Close).
# A dialog over Home has a Close link, or Last settings (the Test Drive window's Close is now called Back).
function UiHome {
  for ($try = 0; $try -lt 4; $try++) {   # the accessibility scan sometimes comes back empty: look again
    $l = (Ir uilist).out
    if ($l -match 'TabItem\s+Dashboard') {
      $over = ($l -match 'Hyperlink\s+Close\b') -or ($l -match 'TabItem\s+Event Log') -or ($l -match 'TabItem\s+Lap Graph') -or ($l -match 'Hyperlink\s+Last settings')
      return (($l -match 'TabItem\s+Stream') -and -not $over)
    }
    Start-Sleep -Milliseconds 1500
  }
  return $false
}

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree -NeedAway
if ((Ir state).out -match 'telemetry=on') { 'iRacing is in a session - run this when nobody is in the car.'; exit 1 }
'Action keys test (real sessions)'

'1. AI race: START (the AI RACE key)'
$t = Timed { Ir startlast ai }
Check "startlast ai succeeded ($($t.secs) s)" ($t.r.rc -eq 0)
if ($t.r.rc -ne 0) { 'The AI race did not start - the rest of this test needs it.'; $t.r.out; "$pass passed, $fail failed"; exit 1 }
$s = Sess
Check 'the sim is in the car, in an AI session, first session of the weekend' ($s.live -and $s.onTrack -and $s.ai -and $s.num -eq 0)
"        $($s.type) (session $($s.num)), $($t.secs) s from press to in the car"
Shot 'in-car-ai'

'2. GET OUT (car stopped)'
$r = Ir getout
$s = WaitSess { param($x) -not $x.onTrack } 8
Check 'GET OUT leaves the car' ($r.rc -eq 0 -and -not $s.onTrack)
Shot 'getout'

'3. GO (the DRIVE key)'
$t = Timed { Ir go }
$s = Sess
Check "GO gets back in the car ($($t.secs) s)" ($t.r.rc -eq 0 -and $s.onTrack)

'4. TOW TO PITS (car stopped)'
$t = Timed { Ir tow }
$s = Sess
Check "TOW ends in the car, on pit road ($($t.secs) s)" ($t.r.rc -eq 0 -and $s.onTrack -and $s.onPit)

'5. REPLAY (last incident), out of the car'
$null = Ir getout; $null = WaitSess { param($x) -not $x.onTrack } 8
$f0 = (Sess).frame
$r1 = Ir replay
Start-Sleep -Milliseconds 800
$s1 = Sess
"        replay frame before $f0, after the first press $($s1.frame); replay playing: $($s1.replay)"
Check 'the first REPLAY press is accepted (jump to the last incident or back to live)' ($r1.rc -eq 0 -and $r1.out -match 'replay: (jumped to the last incident|back to live)')
$r2 = Ir replay
Check 'a second press is accepted' ($r2.rc -eq 0)
Shot 'replay'
$null = Ir go
Check 'back in the car after the replay keys (GO)' ((Sess).onTrack)

'6. RESTART RACE (ONE press, like the key since 2026-10-23)'
Start-Sleep -Seconds 4
$s0 = Sess
$t = Timed { Ir confirm restart-race restartrace }
$s = Sess
Check 'the press does not arm: it restarts at once' ($t.r.out -match 'one press, no arming' -and $t.r.out -notmatch 'armed - press again')
Check "the one press restarts the session and gets back in the car ($($t.secs) s)" ($t.r.rc -eq 0 -and $s.live -and $s.num -eq $s0.num -and $s.time -lt $s0.time -and $s.onTrack)
Check 'the log says he is back in the car' ($t.r.out -match 'restart: back in the car')
Check 'the sim''s Restart Session? dialog was met and confirmed' ($t.r.out -match 'the sim asks to confirm' -and (Test-Path (Join-Path $shots 'a-restartrace-dialog1.png')))
"        session time $($s0.time) s -> $($s.time) s"

'7. SKIP SESSION (the SKIP key): to the race'
$null = Ir getout; $null = WaitSess { param($x) -not $x.onTrack } 8
$t = Timed { Ir skip }
$s = Sess
Check "SKIP moves on to session 1 ($($s.type)) ($($t.secs) s)" ($t.r.rc -eq 0 -and $s.live -and $s.num -eq 1)
Check 'the sim''s Skip to Next Session? dialog was met and confirmed' ($t.r.out -match 'the sim asks to confirm' -and (Test-Path (Join-Path $shots 'a-skip-dialog1.png')))
Shot 'after-skip'

'8. the race: GO, RESTART RACE, wait for the green flag, QUIT TO MAIN while it is running'
$t = Timed { Ir go }
Check "GO gets in the car for the race ($($t.secs) s)" ($t.r.rc -eq 0 -and (Sess).onTrack)
Start-Sleep -Seconds 6   # the session clock must be well past 0 to see it start over
$s0 = Sess
$t = Timed { Ir confirm restart-race restartrace }
$s = Sess
Check "RESTART RACE works in the race session too ($($t.secs) s)" ($t.r.rc -eq 0 -and $s.num -eq 1 -and $s.onTrack -and $s.time -lt $s0.time)
$s = WaitSess { param($x) $x.state -eq 4 } 150
Check 'the race goes green' ($s.state -eq 4)
Shot 'race-running'
$t = Timed { Ir quitmain }
Check "QUIT TO MAIN in a running race ($($t.secs) s)" ($t.r.rc -eq 0)
Check 'the sim has left the session' (-not (Sess).live)
Check 'the iRacing UI shows Home with nothing over it (no results page, no news window)' (UiHome)
Check 'the sim''s quit dialog was met and confirmed' ($t.r.out -match 'the sim asks to confirm')
Shot 'home-after-race'
if ($t.r.out -match 'closing') { "        it also cleared: " + (($t.r.out -split "`n" | Where-Object { $_ -match 'closing' }) -join '; ') }

if (-not $NoTestDrive) {
  '9. TEST DRIVE key: startlast td, then QUIT TO MAIN'
  $t = Timed { Ir startlast td }
  $s = Sess
  Check "startlast td gets you in the car ($($t.secs) s)" ($t.r.rc -eq 0 -and $s.live -and $s.onTrack -and -not $s.ai)
  Shot 'in-car-td'
  $t = Timed { Ir quitmain }
  Check "QUIT TO MAIN from a test drive, in the car and stopped ($($t.secs) s)" ($t.r.rc -eq 0 -and -not (Sess).live)
  Check 'the iRacing UI shows Home with nothing over it' (UiHome)
}

if (-not $NoFriends) {
  '10. FRIENDS mode START (wheel strength must come back)'
  $null = Ir guest on
  $t = Timed { Ir guest start }
  Start-Sleep -Milliseconds 2500   # the sim takes the new wheel strength a moment after the broadcast
  $s = Sess
  Check "friends START gets you in the car ($($t.secs) s)" ($t.r.rc -eq 0 -and $s.live -and $s.onTrack)
  # the sim's own reading (SteeringWheelMaxForceNm) does not follow the broadcast, so the wheel strength cannot be read back from
  # telemetry: the check is what irdeck says it sent, and that your own value was remembered and is given back
  Check 'START sent the guest wheel strength and remembered yours (log: "guest: wheel light feel N Nm -> max force N Nm, sim reads N (yours N")' ($t.r.out -match 'guest: wheel light feel [\d.]+ Nm -> max force [\d.]+ Nm, sim reads [\d.]+ \(yours [\d.]+')
  Shot 'in-car-friends'
  $r = Ir guest off
  Start-Sleep -Milliseconds 800
  $own = (Get-Content (Join-Path $root 'guest\state.ini') | Where-Object { $_ -match '^own_ffb=' }) -replace '^own_ffb=', ''
  Check 'EXIT FRIENDS gives your own wheel strength back (the remembered value is cleared)' ($r.rc -eq 0 -and $r.out -match 'your wheel strength is back' -and "$own".Trim() -eq '')
  $t = Timed { Ir quitmain }
  Check "QUIT TO MAIN after friends ($($t.secs) s)" ($t.r.rc -eq 0 -and -not (Sess).live)
  Check 'the iRacing UI shows Home with nothing over it' (UiHome)
}

''
Check 'the sim is not running a session any more (iRacing is back on Home)' (-not (Sess).live -and (UiHome))
"$pass passed, $fail failed. Pictures in $shots (a-*.png)"
