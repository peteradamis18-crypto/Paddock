# Deck v2, live: every new one-press key, pressed through its REAL key exe (keys\<name>.exe, the same path as a Stream Deck
# press), in real sessions. After each press: the sim's telemetry (irdeck-cli sess), what irdeck logged for that press, and the
# message the top screen shows (GET /keymsg), plus a picture of the real top screen (tests\shots\v2-*.png).
#   Test Drive (LAST DRIVE): GET OUT, GET IN from the replay screen, RESTART (back in the pits), kids lock / blocked key /
#     allowed key / KIDS then HOME, MUTE SPOTTER twice, NEXT SESSION (ends the test drive)
#   AI race (AI RACE): RESTART in qualify, NEXT SESSION to the race, GET IN, QUIT TO MENU (LEAVE page)
#   AI race again: RACE NOW from qualify, QUIT TO MENU (the second LEAVE cell)
# Not covered: GET OUT while the car rolls (a test cannot drive the car; the wait is in tests\deck-behaviour-test.ps1).
# Starts the real sim, so it needs 10 minutes with nobody at the keyboard (tests\guard.ps1 -NeedAway).
#   powershell -ExecutionPolicy Bypass -File tests\deck-v2-live.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree -NeedAway
Enter-TestLock 'deck-v2-live' 0
# a kids lock this test starts ends by itself within 2 minutes even if the test is cut off (key exes and the hook inherit this)
$env:IRDECK_KIDS_TEST_MAXSEC = '120'
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$env:IRDECK_SHOTS = $shots
$cli = Join-Path $root 'irdeck-cli.exe'
$log = Join-Path $root 'irdeck.log'
$own = Join-Path $root 'tests\last\own-input.txt'; New-Item -ItemType Directory -Force (Split-Path $own) | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Section($s) { Assert-RigFree -NeedAway -Where $s; $s }
function Touch { [IO.File]::WriteAllText($own, (Get-Date).ToString('o')) }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# the dashboard monitor sits ABOVE the race screens (y < 0): find it by position, never by \\.\DISPLAYn
$top = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.Y -lt 0 } | Select-Object -First 1
function TopShot($name) {
  if (-not $top) { return }
  $b = $top.Bounds; $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height; $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $bmp.Save((Join-Path $shots "v2-$name.png")); $g.Dispose(); $bmp.Dispose()
}
function Ir { $o = & $cli @args 2>&1 | ForEach-Object { "$_" }; [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join "`n") } }
function Sess {
  $o = (Ir sess).out
  $m = [regex]::Match($o, 'session (\d+) (.+?) \(state (\d+)\), event (\S+), ai=(\w+), onTrack=(\w+), onPit=(\w+), speed=([\d.]+), replay=(\w+), time=(\d+)s')
  if (-not $m.Success) { return [pscustomobject]@{ live = $false; num = -1; type = ''; ai = $false; onTrack = $false; onPit = $false; replay = $false; time = 0 } }
  [pscustomobject]@{ live = $true; num = [int]$m.Groups[1].Value; type = $m.Groups[2].Value; ai = $m.Groups[5].Value -eq 'True'; onTrack = $m.Groups[6].Value -eq 'True'
                     onPit = $m.Groups[7].Value -eq 'True'; replay = $m.Groups[9].Value -eq 'True'; time = [int]$m.Groups[10].Value }
}
function WaitSess($cond, $secs = 20) { for ($i = 0; $i -lt $secs * 2; $i++) { $s = Sess; if (& $cond $s) { return $s }; Start-Sleep -Milliseconds 500 }; return (Sess) }
function UiHome {
  for ($try = 0; $try -lt 4; $try++) {
    $l = (Ir uilist).out
    if ($l -match 'TabItem\s+Dashboard') {
      $over = ($l -match 'Hyperlink\s+Close\b') -or ($l -match 'TabItem\s+Event Log') -or ($l -match 'TabItem\s+Lap Graph') -or ($l -match 'Hyperlink\s+Last settings')
      return (($l -match 'TabItem\s+Stream') -and -not $over)
    }
    Start-Sleep -Milliseconds 1500
  }
  return $false
}
function Shot-Sim($name) { try { $b = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.X -eq 0 -and $_.Bounds.Y -eq 0 } | Select-Object -First 1; $bmp = New-Object System.Drawing.Bitmap $b.Bounds.Width, $b.Bounds.Height; $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Bounds.Location, [System.Drawing.Point]::Empty, $b.Bounds.Size); $s = New-Object System.Drawing.Bitmap $bmp, 1280, 720; $s.Save((Join-Path $shots "v2-$name.png")); $g.Dispose(); $bmp.Dispose(); $s.Dispose() } catch { } }
function KeyMsg { try { (Invoke-WebRequest -UseBasicParsing 'http://localhost:8199/keymsg' -TimeoutSec 3).Content | ConvertFrom-Json } catch { $null } }
# press a deck key: run its exe, wait for it, return what it logged and what the top screen says
function Press($key, $secs = 300) {
  $start = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process (Join-Path $root "keys\$key.exe") -PassThru -WindowStyle Hidden
  if (-not $p.WaitForExit($secs * 1000)) { try { $p.Kill() } catch { }; "  (the $key key was still running after $secs s - stopped)" | Out-Host }
  Touch
  Start-Sleep -Milliseconds 600   # the message is sent fire-and-forget; give irdash a moment
  $len = (Get-Item $log).Length; if ($len -lt $start) { $start = 0 }   # the log rotated
  $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite'); $fs.Seek($start, 'Begin') | Out-Null
  $text = (New-Object IO.StreamReader($fs)).ReadToEnd(); $fs.Dispose()
  $m = KeyMsg
  $r = [pscustomobject]@{ key = $key; rc = $p.ExitCode; secs = [int]$sw.Elapsed.TotalSeconds; log = $text; msgKey = $(if ($m) { $m.key } else { '' }); msg = $(if ($m) { $m.text } else { '' }) }
  "        [$key] $($r.secs) s, top screen: '$($r.msg)'" | Out-Host
  return $r
}
function Said($r, $text) { $r.msgKey -eq $r.key -and $r.msg -eq $text }

'Deck v2 live keys'
if ((Ir state).out -match 'telemetry=on') { 'iRacing is in a session - run this when nobody is in the car.'; exit 1 }
if (-not (UiHome)) { 'The iRacing UI is not on Home - start from Home.'; exit 1 }
try {
  Section '1. GET IN with nothing running starts your last drive (the Test Drive of the car and track chosen on CAR TRACK)'
  $env:RIG_TEST_OWNS_SIM = '1'
  $r = Press 'smart' 400
  $s = WaitSess { param($x) $x.onTrack } 20
  Check "GET IN ends in the car, in a test drive ($($r.secs) s)" ($s.live -and $s.onTrack -and -not $s.ai)
  Check "the top screen says 'In the car'" (Said $r 'In the car')
  TopShot 'last-drive'

  Section '2. GET OUT, then GET IN from the replay screen'
  $r = Press 'get-out' 60
  $s = WaitSess { param($x) -not $x.onTrack } 10
  Check 'GET OUT leaves the car' (-not $s.onTrack)
  Check "the top screen says 'Out of the car'" (Said $r 'Out of the car')
  Start-Sleep -Seconds 3
  $s0 = Sess
  "        after GET OUT: replay=$($s0.replay)"
  $r = Press 'smart' 120
  $s = WaitSess { param($x) $x.onTrack } 10
  Check "GET IN gets in from the screen after GET OUT (it used to say WAIT on the replay) ($($r.secs) s)" ($s.onTrack -and $r.log -notmatch 'WAIT')
  Check "the top screen says 'In the car'" (Said $r 'In the car')
  TopShot 'get-in'

  Section '3. RESTART in a Test Drive: back to the pits, in the car'
  $r = Press 'restart-race' 120
  $s = WaitSess { param($x) $x.onTrack } 10
  Check "RESTART in a test drive ends in the car on pit road ($($r.secs) s)" ($s.onTrack -and $s.onPit)
  Check "the top screen says 'Back in the pits, in the car'" (Said $r 'Back in the pits, in the car')

  Section '3b. the practice loop (Test Drive): SAVE SPOT, BACK TO SPOT, GHOST, PAUSE'
  $r = Press 'spot-save' 60
  Check 'SAVE SPOT saves the spot (the dashboard finds the track corner it times to)' ($r.log -match 'spot: ok - Spot saved')
  Check "the top screen says 'Spot saved - tries are timed ...'" ($r.msgKey -eq 'spot-save' -and $r.msg -like 'Spot saved*')
  $st = (Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:8199/api/spot?cmd=status' -TimeoutSec 5).Content | ConvertFrom-Json
  Check "the dashboard holds the spot and says where tries end ('$($st.where)')" ($st.saved -eq $true -and $st.where.Length -gt 0)
  $r = Press 'spot-back' 60
  Check 'BACK TO SPOT puts the car back (the dashboard saw the reset and started a try)' ($r.log -match 'spot: ok - back at the spot' -and (Sess).onTrack)
  Check "the top screen says 'Back at the spot - timing ...'" ($r.msgKey -eq 'spot-back' -and $r.msg -like 'Back at the spot*')
  Shot-Sim 'spot-back'
  $r = Press 'ghost' 30
  Check 'GHOST sends iRacing''s reference-car key' ($r.log -match 'key ctrl\+c sent')
  Shot-Sim 'ghost-on'
  $t0 = (Sess).time
  $r = Press 'pause' 30
  Start-Sleep -Milliseconds 800
  $a = (Sess).time; Start-Sleep -Milliseconds 1200; $b = (Sess).time
  Check "PAUSE freezes the sim's clock ($a -> $b)" ($r.log -match 'pause: ok - Paused' -and $a -eq $b)
  Check "the top screen says 'Paused - press again to carry on'" (Said $r 'Paused - press again to carry on')
  Shot-Sim 'paused'
  $r = Press 'pause' 30
  Start-Sleep -Milliseconds 800
  $a = (Sess).time; Start-Sleep -Milliseconds 1500; $b = (Sess).time
  Check "PAUSE again carries on ($a -> $b)" ($r.log -match 'pause: ok - Running again' -and $b -gt $a)
  Check "the top screen says 'Running again'" (Said $r 'Running again')
  $null = Press 'ghost' 30      # back to how it was

  Section '4. kids mode while in the car'
  $r = Press 'kids' 30
  Check 'KIDS locks (lock file, hook running)' ((Test-Path (Join-Path $root 'dash\kids.lock')) -and $r.log -match 'kids: locked')
  Check "the top screen says 'Kids mode on'" (Said $r 'Kids mode on')
  TopShot 'kids-on'
  Start-Sleep -Milliseconds 900
  $r = Press 'get-out' 30
  Start-Sleep -Seconds 2
  Check 'GET OUT is ignored while locked (still in the car)' ((Sess).onTrack -and $r.log -match 'kids mode: ignored')
  Check "the top screen says 'Kids mode is on'" (Said $r 'Kids mode is on')
  Start-Sleep -Milliseconds 900
  $r = Press 'smart' 60
  Check 'GET IN is allowed while locked (already in the car)' ($r.log -notmatch 'kids mode: ignored' -and $r.log -match 'already in the car')
  Start-Sleep -Milliseconds 900
  $r = Press 'kids' 30
  Check 'a second KIDS press only asks for HOME (still locked)' ((Test-Path (Join-Path $root 'dash\kids.lock')) -and $r.log -match 'press HOME within 4 seconds')
  Check "the top screen says 'Press HOME within 4 seconds to unlock'" (Said $r 'Press HOME within 4 seconds to unlock')
  $r = Press 'rig-on' 30
  Check 'HOME within 4 s unlocks, and RIG ON itself does not run' (-not (Test-Path (Join-Path $root 'dash\kids.lock')) -and $r.log -match 'kids: unlocked \(KIDS then HOME\)' -and $r.log -notmatch 'rigon: ')
  Check "the top screen says 'Kids mode off'" (Said $r 'Kids mode off')
  Start-Sleep -Seconds 1
  Check 'the hook process is gone' (-not (Get-CimInstance Win32_Process -Filter "Name='irdeck.exe' or Name='kids.exe' or Name='kids-leave.exe'" | Where-Object { $_.CommandLine -match 'kids hook' }))

  Section '5. MUTE SPOTTER twice (CrewChief''s own mixer entry)'
  if (Get-Process CrewChiefV4 -ErrorAction SilentlyContinue) {
    $r1 = Press 'mute-spotter' 20
    Start-Sleep -Milliseconds 900
    $r2 = Press 'mute-spotter' 20
    $quiet = $r1.log -match 'not making sound'
    if ($quiet) { Check 'CrewChief is not making sound right now: the key says so' ((Said $r1 'No game sound right now') -and (Said $r2 'No game sound right now')) }
    else {
      Check 'the first press toggles the spotter' ($r1.log -match 'appvol mute: CrewChiefV4 (muted|sound back on)')
      Check 'the second press toggles it back' (($r1.log -match 'muted \(' -and $r2.log -match 'sound back on') -or ($r1.log -match 'sound back on' -and $r2.log -match 'muted \('))
      Check 'the top screen says Spotter muted / Spotter on' (((Said $r1 'Spotter muted') -and (Said $r2 'Spotter on')) -or ((Said $r1 'Spotter on') -and (Said $r2 'Spotter muted')))
    }
  } else { '  info  CrewChief is not running: MUTE SPOTTER skipped' }

  Section '6. NEXT SESSION in a Test Drive ends it (back at the menu)'
  $r = Press 'skip-session' 120
  Check "the test drive ended ($($r.secs) s)" (-not (Sess).live)
  Check 'the iRacing UI is on Home' (UiHome)
  Check "the top screen says 'Back at the menu'" (Said $r 'Back at the menu')

  Section '7. AI RACE with an AI level chosen (adaptive HIGH), RESTART in the first session'
  $aiFile = Join-Path $root 'ai\level.json'; $aiHad = Test-Path $aiFile; $aiSave = if ($aiHad) { Get-Content $aiFile -Raw } else { $null }
  New-Item -ItemType Directory -Force (Split-Path $aiFile) | Out-Null
  [IO.File]::WriteAllText($aiFile, '{"mode":"adaptive","level":"high","min":25,"max":50}', (New-Object Text.UTF8Encoding $false))
  $r = Press 'ai-race' 400
  Check 'AI RACE set the AI level from the AI LEVEL screen (adaptive AI, high) and read it back from the wizard' ($r.log -match 'airace level: set \(adaptive AI, high challenge\); the step now shows Adaptive AI, High')
  $s = WaitSess { param($x) $x.live } 60
  $null = WaitSess { param($x) $x.onTrack } 30
  $s = Sess
  Check "AI RACE starts an AI event, in the car ($($r.secs) s, $($s.type))" ($s.live -and $s.ai -and $s.onTrack -and $s.num -eq 0)
  $firstType = $s.type
  $r = Press 'spot-save' 30
  Check 'SAVE SPOT in an AI race says it is for Test Drives only' ($r.rc -eq 3 -and $r.log -match 'this is for a Test Drive' -and (Said $r 'Test Drive only (Active Reset)'))
  $r = Press 'pause' 30
  Start-Sleep -Milliseconds 800
  $a = (Sess).time; Start-Sleep -Milliseconds 1200; $b = (Sess).time
  $paused = ($a -eq $b)
  if ($r.log -match 'pause: ok - Paused') { Check 'PAUSE in an AI race freezes the clock (and it is un-paused again below)' $paused } else { "  info  PAUSE in an AI race: $($r.msg) (the sim clock moved: $a -> $b)" }
  if ($paused) { $null = Press 'pause' 30; Start-Sleep -Milliseconds 800; Check 'PAUSE again carries on in the AI race' ((Sess).time -ne $a) }
  Start-Sleep -Seconds 8
  $s0 = Sess
  $r = Press 'restart-race' 180
  $s = Sess
  Check "RESTART starts the session over and ends in the car ($($r.secs) s)" ($s.live -and $s.num -eq $s0.num -and $s.time -lt $s0.time -and $s.onTrack)
  Check "the top screen says 'Race restarted'" (Said $r 'Race restarted')

  Section '8. NEXT SESSION to the race, GET IN, QUIT TO MENU from LEAVE'
  $r = Press 'skip-session' 180
  $s = Sess
  Check "NEXT SESSION moves on from $firstType ($($r.secs) s, now $($s.type))" ($s.live -and $s.num -gt 0)
  Check 'the top screen names the next session' ($r.msgKey -eq 'skip-session' -and $r.msg -like 'Next session:*')
  TopShot 'next-session'
  $r = Press 'smart' 120
  Check "GET IN gets in for the next session ($($r.secs) s)" ((WaitSess { param($x) $x.onTrack } 10).onTrack)
  $r = Press 'quit-main' 180
  Check "QUIT TO MENU (LEAVE page) leaves the race ($($r.secs) s)" (-not (Sess).live)
  Check 'the iRacing UI is on Home' (UiHome)
  Check "the top screen says 'Back at the menu'" (Said $r 'Back at the menu')

  Section '9. AI RACE again with a skill range (30 to 60), RACE NOW from the first session, QUIT (second LEAVE cell)'
  [IO.File]::WriteAllText($aiFile, '{"mode":"range","level":"low","min":30,"max":60}', (New-Object Text.UTF8Encoding $false))
  $r = Press 'ai-race' 400
  Check 'AI RACE set the skill range 30% to 60% and read it back' ($r.log -match 'airace level: set \(skill range 30% to 60%\); the step now shows Fixed Skill Range, skill 30% to 60%')
  $null = WaitSess { param($x) $x.live -and $x.onTrack } 60
  $s0 = Sess
  Check "a fresh AI event, first session ($($s0.type))" ($s0.live -and $s0.ai -and $s0.num -eq 0)
  $r = Press 'race-now' 300
  $s = Sess
  Check "RACE NOW ends in the race session, in the car ($($r.secs) s, $($s.type))" ($s.live -and $s.type -match 'Race' -and $s.onTrack)
  Check "the top screen says 'Race starting'" (Said $r 'Race starting')
  TopShot 'race-now'
  $r = Press 'quit-main2' 180
  Check "QUIT TO MENU from the second LEAVE cell ($($r.secs) s)" (-not (Sess).live)
  Check 'the iRacing UI is on Home' (UiHome)
}
finally {
  # the AI LEVEL choice goes back to what it was (no file = iRacing's own Adaptive Low)
  try { if ($aiHad) { [IO.File]::WriteAllText($aiFile, $aiSave, (New-Object Text.UTF8Encoding $false)) } elseif (Test-Path $aiFile) { Remove-Item $aiFile -Force } } catch { }
  # never leave kids mode on, and always end on Home
  if (Test-Path (Join-Path $root 'dash\kids.lock')) { $null = Ir kids off }
  if ((Sess).live) { $null = Ir quitmain }
  Remove-Item Env:\RIG_TEST_OWNS_SIM -ErrorAction SilentlyContinue
  Exit-TestLock
}
"$pass passed, $fail failed. Top-screen pictures: $shots\v2-*.png"
if ($fail -gt 0) { exit 1 }
