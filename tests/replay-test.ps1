# REPLAY screen test (WS15). Parts:
#   1. irdash with a PRETEND session (the test hook + a real race's YAML): every key sends exactly the SDK message(s) it should
#      (recorded through /api/test/replaylog, never broadcast), labels' data change with the state (paused, driving, live ...)
#   2. the deck screen, drawn by the real add-on code in headless Chrome with a pretend Stream Deck app and the real /replay
#      answers of part 1: every view has all 32 keys, presses send the right requests, pictures in tests\shots\rp-*.png
#   3. -Live only: a real AI race that you SPECTATE (nobody in the car): every key pressed through irdash's /api/do and checked
#      by reading the sim's telemetry back, a picture of the middle screen per key. Needs Peter away for 10 minutes.
# Never runs while Peter races or is about to (tests\guard.ps1); irdash refuses the test hook while a real session is on.
# Needs the NEW irdash running (dash\build.ps1) for parts 1 and 2, and the add-on code in deck-intro\plugin.html (read from the file).
#   powershell -ExecutionPolicy Bypass -File tests\replay-test.ps1 [-Live] [-NoDeck]
param([switch]$Live, [switch]$NoDeck)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'tests\guard.ps1')
if ($Live) { Assert-RigFree -NeedAway } else { Assert-RigFree }
# (once the live part has started the sim, the test's own clicks in the iRacing app are keyboard/mouse input too: from then on only "the sim is not Peter's" is checked, through RIG_TEST_OWNS_SIM)
function Section($title) { $g = @{ Where = $title }; if ($Live -and -not $script:liveStart) { $g.NeedAway = $true }; Assert-RigFree @g; if ($Live) { Touch-Lock }; $title }
. (Join-Path $root 'tests\deck-harness.ps1')
. (Join-Path $root 'tests\deck-fixtures.ps1')
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = 'http://localhost:8199'
$pass = 0; $fail = 0
# Write-Host so Press-Live can return a telemetry reading without swallowing ok/FAIL.
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "  ok    $what" } else { $script:fail++; Write-Host "  FAIL  $what" } }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
function Raw($p) { $r = Invoke-WebRequest -UseBasicParsing "$api$p" -TimeoutSec 8; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
function J($p) { Raw $p | ConvertFrom-Json }
function Q($s) { [uri]::EscapeDataString($s) }
# the status code of a request that may fail (400 = refused)
function Api($c, $a) { $u = "$api/api/do?c=$c" + $(if ($a) { '&a=' + (Q $a) } else { '' }); try { $r = Invoke-WebRequest -UseBasicParsing $u -TimeoutSec 8; return [int]$r.StatusCode } catch { return [int]$_.Exception.Response.StatusCode } }
function Get-Code($path) { try { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 8; return [int]$r.StatusCode } catch { $resp = $_.Exception.Response; if ($resp) { return [int]$resp.StatusCode } else { return 0 } } }
function Fake($q) { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?$q" -TimeoutSec 8 }
function Fresh { $null = J '/api/test/replaylog?clear=1' }                      # empties the recorded messages and forgets the last presses
function Sent { $r = J '/api/test/replaylog'; $o = @(); foreach ($m in @($r.msgs)) { if ($m) { $o += "$($m.m),$($m.a),$($m.b)" } }; return $o }

$hook = Join-Path $root 'dash\test-hook.on'
$lock = Join-Path $root 'dash\deploy.lock'
$script:lockAt = [datetime]::MinValue; $script:liveStart = $null
# the deploy lock is re-touched every 2 minutes so build.ps1 and the other tests (which treat a lock older than 15 minutes as stale) never restart irdash under a live run
function Touch-Lock([switch]$Force) { if ($Force -or ((Get-Date) - $script:lockAt).TotalMinutes -ge 2) { Set-Content $lock ('replay-live ' + (Get-Date).ToString('HH:mm:ss')); $script:lockAt = Get-Date } }
# hard stop: the live phase may not run longer than 45 minutes
function Check-Time { Touch-Lock; if ($script:liveStart -and ((Get-Date) - $script:liveStart).TotalMinutes -gt 45) { throw 'the live phase has run for more than 45 minutes - stopping' } }
$testDir = Join-Path $root 'replay\test'                                         # where irdash puts the pretend photo's folders
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$race = @('chevyvettez06rgt3_roadatlanta full 2026-10-06 21-26-58.ibt', 'chevyvettez06rgt3_roadatlanta full 2026-10-04 22-13-50.ibt') | Where-Object { Test-Path (Join-Path $tel $_) } | Select-Object -First 1   # both: a 15-lap AI race with 20 cars, sessions Practice / Qualify / Race
if (-not $race) { 'No Road Atlanta race .ibt in the telemetry folder - this test needs one for its session information.'; exit 1 }
$snap = @{}                                                                     # real /replay answers kept for the deck part
$allSent = New-Object System.Collections.Generic.List[string]
$ownsSim = $false

'Replay screen test'
if ((Get-Process irdash -ErrorAction SilentlyContinue) -eq $null) { 'irdash is not running - start it (dash\irdash.exe) first.'; exit 1 }
$probe = $null; try { $probe = J '/replay' } catch { }
if (-not $probe -or -not $probe.ready) { 'irdash is running, but it is not the new build (/replay is not answering). Run dash\build.ps1, then this test again.'; exit 1 }
Enter-TestLock 'replay'   # one live test at a time (tests\guard.ps1); released in finally
for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock (' + (Get-Content $lock) + ')'; Start-Sleep -Seconds 60 }
Touch-Lock -Force

try {

# ================= 1. irdash: the keys and the exact SDK messages =================
Section '1. irdash with a pretend session: every key sends the exact SDK message(s)'
Set-Content $hook 'replay-test'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/session?file=$(Q $race)" -TimeoutSec 15
# a race with 20 cars, 130 s behind live, the camera on car 5 (Zhu, #940) in the TV1 group, camera 3; I am car 0 (#64, in last place)
$base = [ordered]@{ IsOnTrack = 0; IsReplayPlaying = 1; ReplayPlaySpeed = 1; ReplayPlaySlowMotion = 0; SessionNum = 2; SessionTime = 600.5; ReplaySessionNum = 2; ReplaySessionTime = 470.5
                    ReplayFrameNumEnd = 7800; CamCarIdx = 5; CamGroupNumber = 11; CamCameraNumber = 3; CamCameraState = 1; PlayerCarIdx = 0 }
for ($i = 0; $i -lt 20; $i++) { $base["CarIdxPosition_$i"] = 20 - $i; $base["CarIdxClassPosition_$i"] = 20 - $i; $base["CarIdxLap_$i"] = 3 }
function Inv($x) { [Convert]::ToString($x, [Globalization.CultureInfo]::InvariantCulture) }       # 600.5, never 600,5
function State($over = @{}) {
  $v = [ordered]@{}; foreach ($k in $base.Keys) { $v[$k] = $base[$k] }; foreach ($k in $over.Keys) { $v[$k] = $over[$k] }
  Fake (($v.GetEnumerator() | ForEach-Object { "$($_.Key)=$(Inv $_.Value)" }) -join '&')
  Start-Sleep -Milliseconds 300; Fresh
}
# one key: the message(s) it must send, in order ("msg,var1,var2;msg,var1,var2")
function Key($label, $c, $a, $expect) {
  Fresh; $code = Api $c $a; Start-Sleep -Milliseconds 150
  $got = (Sent) -join ';'; $allSent.Add($got)
  Check "$label sends $expect" ($code -eq 200 -and $got -eq $expect)
  if ($code -ne 200 -or $got -ne $expect) { "        got: '$got' (HTTP $code)" }
}
function Refused($label, $c, $a) { Fresh; $code = Api $c $a; Start-Sleep -Milliseconds 100; $got = (Sent) -join ';'; Check "$label is refused and sends nothing" ($code -eq 400 -and $got -eq '') }

State
$st = J '/replay'; $snap.play = Raw '/replay'
Check '/replay is ready, in a session, not driving' ($st.ready -and $st.inSession -and -not $st.driving)
Check 'replaying at x1 (not live): mode play' (-not $st.live -and $st.mode -eq 'play' -and $st.raw -eq 1 -and $st.rate -eq 1)
Check 'the session is RACE, 15 laps, lap 3 of the car watched, 130 s from live' ($st.session.name -eq 'RACE' -and $st.session.laps -eq 15 -and $st.session.lap -eq 3 -and $st.session.fromLive -eq 130)
Check 'the tape is as long as the session so far (470.5 s + 130 s) and the marker is at 78 %' ((Near $st.session.len 600.5 0.05) -and (Near $st.session.frac 0.784 0.002))
Check 'sessions on the tape: practice, qualify, race; SESSION goes to practice next' ((@($st.sessions | ForEach-Object { $_.name }) -join ',') -eq 'PRACTICE,QUALIFY,RACE' -and $st.nextSession.name -eq 'PRACTICE')
Check 'the camera is TV1, view 3 of 11, and TV / COCKPIT / CHASE all exist here' ($st.camera.name -eq 'TV1' -and $st.camera.camera -eq 3 -and $st.camera.count -eq 11 -and $st.camera.tv -and $st.camera.cockpit -and $st.camera.chase -and $st.camera.onTv -and -not $st.camera.onCockpit)
Check 'auto TV and hidden UI are off' (-not $st.camera.autoTv -and -not $st.camera.uiHidden)
Check 'watching #940 ZHU in P15; I am #64 ADAMIS in P20' ($st.watch.num -eq '940' -and $st.watch.name -eq 'ZHU' -and $st.watch.pos -eq 15 -and $st.me.num -eq '64' -and $st.me.name -eq 'ADAMIS' -and $st.me.pos -eq 20)
Check 'car ahead is P14 #32 EDGERTON, car behind is P16 #69 BROADBENT, the leader is P1 #00 REGAN' ($st.ahead.pos -eq 14 -and $st.ahead.num -eq '32' -and $st.behind.pos -eq 16 -and $st.behind.num -eq '69' -and $st.leader.pos -eq 1 -and $st.leader.name -eq 'REGAN')
Check 'the PICK CAR list has the 20 cars by position (no pace car), mine marked, the watched one marked' (@($st.cars).Count -eq 20 -and $st.cars[0].pos -eq 1 -and $st.cars[19].pos -eq 20 -and @($st.cars | Where-Object { $_.me }).Count -eq 1 -and @($st.cars | Where-Object { $_.watch }).Count -eq 1)
Check 'only one class here' (-not $st.multiClass)

'row 1: where am I'
Key 'LIVE' 'rplive' '' '5,1,0;3,1,0'
Key 'START' 'rpstart' '' '12,2,0'
foreach ($i in 0..4) {
  Fresh; $code = Api 'rpjump' "$i"; Start-Sleep -Milliseconds 150; $got = @(Sent); $allSent.Add($got -join ';')
  $want = 600.5 * ($i + 0.5) / 5 * 1000; $p = if ($got.Count -eq 1) { $got[0].Split(',') } else { @('', '', '') }
  Check "timeline fifth $($i + 1) sends ReplaySearchSessionTime(race, the middle of that fifth = $([math]::Round($want)) ms)" ($code -eq 200 -and $p[0] -eq '12' -and $p[1] -eq '2' -and (Near $p[2] $want 2))
}
Refused 'a fifth that is not there (7)' 'rpjump' '7'
Key 'SESSION' 'rpsession' '' '12,0,0'
'row 2: moving through the tape'
Key 'LAP back' 'rplapprev' '' '5,4,0'
Key 'LAP on' 'rplapnext' '' '5,5,0'
Key 'REWIND (from normal speed)' 'rprew' '' '3,-1,0'
Key 'FAST (from normal speed)' 'rpfast' '' '3,2,0'
Key 'SLOW MO (from normal speed: raw 1 = half speed)' 'rpslow' '' '3,1,1'
Key 'PAUSE (playing)' 'rpplay' '' '3,0,0'
Key 'BACK 10 S' 'rpback10' '' '12,2,460500;3,1,0'
'row 3: what to watch'
Key 'INCIDENT back' 'rpincprev' '' '5,8,0;3,1,0'
Key 'INCIDENT on' 'rpincnext' '' '5,9,0;3,1,0'
Key 'MY CAR' 'rpmycar' '' '1,64,196619'
Key 'CAR AHEAD' 'rpahead' '' '1,32,196619'
Key 'CAR BEHIND' 'rpbehind' '' '1,69,196619'
Key 'LEADER' 'rpleader' '' '0,-2,196619'
Key 'PICK CAR #12 (Jr.)' 'rpcar' '12' '1,12,196619'
Key 'PICK CAR #2000 (car 19, number 00)' 'rpcar' '19' '1,2000,196619'
Refused 'PICK CAR with a car that is not there' 'rpcar' '99'
Refused 'PICK CAR with the pace car' 'rpcar' '62'
Key 'MY LAST INCIDENT (replaying: to the end of the tape first)' 'rpmyinc' '' '5,1,0;5,8,0;1,64,196619;3,1,0'
'row 4: how it looks'
Key 'CAMERA >' 'rpcamnext' '' '1,940,262155'
Key 'CAMERA <' 'rpcamprev' '' '1,940,131083'
Key 'TV (same view number)' 'rpgroup' 'tv' '1,940,196619'
Key 'COCKPIT' 'rpgroup' 'cockpit' '1,940,65545'
Key 'CHASE' 'rpgroup' 'chase' '1,940,65556'
Refused 'a camera kind that does not exist' 'rpgroup' 'blimp'
Key 'AUTO TV (turns the director on, keeps the other bits)' 'rpautotv' '' '2,16,0'
Key 'HIDE UI' 'rphideui' '' '2,8,0'
Refused 'an unknown command' 'rpnope' ''
Check 'ReplaySetState (message 6, erases the tape) was never sent' (@($allSent | Where-Object { $_ -match '(^|;)6,' }).Count -eq 0)

'paused: the same keys become one-frame steps'
State @{ ReplayPlaySpeed = 0 }
$st = J '/replay'; Check 'paused is seen (mode paused, rate 0)' ($st.mode -eq 'paused' -and $st.rate -eq 0)
Key 'REWIND while paused = one frame back' 'rprew' '' '5,6,0'
Key 'FAST while paused = one frame on' 'rpfast' '' '5,7,0'
Key 'PLAY (paused)' 'rpplay' '' '3,1,0'

'the speed steps follow what the sim reports (slow motion raw N = 1 / (N + 1))'
foreach ($c in @(@('FAST x2 -> x4', 'ReplayPlaySpeed=2', 'rpfast', '3,4,0'), @('FAST x4 -> x8', 'ReplayPlaySpeed=4', 'rpfast', '3,8,0'), @('FAST x8 -> x16', 'ReplayPlaySpeed=8', 'rpfast', '3,16,0'),
                 @('FAST x16 -> back to normal', 'ReplayPlaySpeed=16', 'rpfast', '3,1,0'), @('REWIND x1 -> x2', 'ReplayPlaySpeed=-1', 'rprew', '3,-2,0'), @('REWIND x4 -> x8', 'ReplayPlaySpeed=-4', 'rprew', '3,-8,0'),
                 @('REWIND x16 -> back to normal', 'ReplayPlaySpeed=-16', 'rprew', '3,1,0'), @('SLOW 1/2 -> 1/4 (raw 3)', 'ReplayPlaySpeed=1&ReplayPlaySlowMotion=1', 'rpslow', '3,3,1'),
                 @('SLOW 1/4 -> 1/8 (raw 7)', 'ReplayPlaySpeed=3&ReplayPlaySlowMotion=1', 'rpslow', '3,7,1'), @('SLOW 1/8 -> back to normal', 'ReplayPlaySpeed=7&ReplayPlaySlowMotion=1', 'rpslow', '3,1,0'))) {
  $over = @{}; foreach ($kv in $c[1].Split('&')) { $p = $kv.Split('='); $over[$p[0]] = $p[1] }
  if (-not $over.ContainsKey('ReplayPlaySlowMotion')) { $over['ReplayPlaySlowMotion'] = 0 }
  State $over; Key $c[0] $c[2] '' $c[3]
}
State @{ ReplayPlaySpeed = 3; ReplayPlaySlowMotion = 1 }
$st = J '/replay'; $snap.slow = Raw '/replay'
Check 'slow motion is read back as a quarter speed (raw 3 + the slow flag)' ($st.mode -eq 'slow' -and $st.raw -eq 3 -and (Near $st.rate 0.25 0.0001))
State @{ ReplayPlaySpeed = 4 }
$st = J '/replay'; $snap.fast = Raw '/replay'
Check 'fast forward x4 is read back' ($st.mode -eq 'fast' -and $st.rate -eq 4)
State @{ ReplayPlaySpeed = -4 }
$st = J '/replay'; Check 'rewind x4 is read back' ($st.mode -eq 'rewind' -and $st.rate -eq -4)

'a press shows at once (before the sim has changed), and pressing again goes on from there'
State
Fresh; $null = Api 'rpfast' ''; Start-Sleep -Milliseconds 100
$st = J '/replay'; Check 'right after FAST the screen already says fast x2' ($st.mode -eq 'fast' -and $st.raw -eq 2)
foreach ($want in @('3,4,0', '3,8,0', '3,16,0', '3,1,0')) { Start-Sleep -Milliseconds 300; $null = Api 'rpfast' ''; Start-Sleep -Milliseconds 100 }
$log = Sent
Check 'FAST pressed five times in a row: x2, x4, x8, x16, then normal' (($log -join ';') -eq '3,2,0;3,4,0;3,8,0;3,16,0;3,1,0')
Start-Sleep -Milliseconds 1800
$st = J '/replay'; Check 'after 1.8 s the screen goes by what the sim says again (x1)' ($st.mode -eq 'play')
State
Fresh; $null = Api 'rpplay' ''; $null = Api 'rpplay' ''; Start-Sleep -Milliseconds 150
Check 'the same press twice within a quarter of a second counts once (a deck can repeat a press)' (((Sent) -join ';') -eq '3,0,0')

'live (not watching a replay): BACK 10 S is an instant replay of what just happened'
State @{ IsReplayPlaying = 0 }
$st = J '/replay'; $snap.live = Raw '/replay'
Check 'live is seen (live true, mode live, marker at the end)' ($st.live -and $st.mode -eq 'live' -and $st.session.fromLive -eq 0 -and $st.session.frac -eq 1)
Key 'BACK 10 S from live goes 10 s back from now (600.5 s)' 'rpback10' '' '12,2,590500;3,1,0'
Key 'PAUSE while live' 'rpplay' '' '3,0,0'
Key 'MY LAST INCIDENT from live: no jump to the end first' 'rpmyinc' '' '5,8,0;1,64,196619;3,1,0'

'out of the car the sim may say "replay playing" while it is at the live edge: that is live too'
State @{ ReplayFrameNumEnd = 2 }
$st = J '/replay'
Check 'playing 2 frames from the end of the tape counts as live (LIVE gold, mode live)' ($st.live -and $st.mode -eq 'live')
State @{ ReplayFrameNumEnd = 2; ReplayPlaySpeed = 0 }
$st = J '/replay'
Check 'paused at the end of the tape is not live (the picture is standing still)' (-not $st.live -and $st.mode -eq 'paused')

'the camera and the director bits are kept'
State @{ CamCameraState = 24 }
$st = J '/replay'
Check 'auto TV and hidden UI are read from the camera state bits' ($st.camera.autoTv -and $st.camera.uiHidden)
Key 'AUTO TV off again keeps UI hidden (bit 8)' 'rpautotv' '' '2,8,0'
Key 'HIDE UI off again keeps auto TV (bit 16)' 'rphideui' '' '2,16,0'

'driving: everything is refused, BACK is local to the deck'
State @{ IsOnTrack = 1; IsReplayPlaying = 0 }
$st = J '/replay'; $snap.driving = Raw '/replay'
Check 'driving is seen (in the car, not replaying)' ($st.driving -and $st.inSession)
foreach ($c in 'rplive', 'rpplay', 'rprew', 'rpfast', 'rpslow', 'rpstart', 'rpback10', 'rpincprev', 'rpmycar', 'rpleader', 'rpautotv', 'rpphoto') { Refused "$c while driving" $c '' }
State @{ IsOnTrack = 1; IsReplayPlaying = 1 }
$st = J '/replay'; Check 'in the car but watching a replay of it is not driving' (-not $st.driving)
Key 'a key works again while watching a replay in the car' 'rpplay' '' '3,0,0'

'unknown positions (before the race): CAR AHEAD / BEHIND / LEADER have nothing'
$zero = @{}; for ($i = 0; $i -lt 20; $i++) { $zero["CarIdxPosition_$i"] = 0; $zero["CarIdxClassPosition_$i"] = 0 }
State ($zero + @{ IsOnTrack = 0 })
$st = J '/replay'; Check 'no neighbours and no leader are served' ($null -eq $st.ahead -and $null -eq $st.behind -and $null -eq $st.leader)
Refused 'CAR AHEAD with no positions' 'rpahead' ''
State
$st = J '/replay'; Check 'positions back: the leader is served again' ($st.leader.pos -eq 1)

'PHOTO: UI hidden, iRacing screenshot, UI back, a copy into the gallery (the pretend folders are inside replay\test)'
Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $testDir 'shots') | Out-Null
Add-Type -AssemblyName System.Drawing
function Make-Png($path, $w, $h) { $b = New-Object Drawing.Bitmap $w, $h; $g = [Drawing.Graphics]::FromImage($b); $g.Clear([Drawing.Color]::FromArgb(20, 18, 10)); $g.Dispose(); $b.Save($path, [Drawing.Imaging.ImageFormat]::Png); $b.Dispose() }
State @{ CamCameraState = 1 }
Fresh; $code = Api 'rpphoto' ''
Start-Sleep -Milliseconds 700
$ph = (J '/replay').photo
Check 'PHOTO answers at once and the key says SNAP (working) while it waits for the picture' ($code -eq 200 -and $ph.state -eq 'working')
Make-Png (Join-Path $testDir 'shots\2026-10-09 23-59-59.png') 2560 1440     # what iRacing would save
Start-Sleep -Milliseconds 1800
$ph = (J '/replay').photo
Check 'the picture was found and copied: state saved' ($ph.state -eq 'saved')
Check 'the sequence was: hide UI (bit 8 on), screenshot, UI back' (((Sent) -join ';') -eq '2,8,0;13,0,0;2,0,0')
$mine = @(Get-ChildItem (Join-Path $testDir 'mine') -Filter 'me-*.png' -ErrorAction SilentlyContinue)
Check 'a copy is in the gallery folder (mine), the original stays where iRacing put it' ($mine.Count -eq 1 -and (Test-Path (Join-Path $testDir 'shots\2026-10-09 23-59-59.png')))
Start-Sleep -Milliseconds 5200
Check 'after a few seconds the key is PHOTO again' ((J '/replay').photo.state -eq 'idle')
State @{ CamCameraState = 9 }                                                # UI was already hidden: it must stay hidden
Fresh; $null = Api 'rpphoto' ''; Start-Sleep -Milliseconds 500
Make-Png (Join-Path $testDir 'shots\small.png') 1280 720
Start-Sleep -Milliseconds 1800
Check 'with the UI already hidden it is left hidden (no UI messages), a small picture is "small" and not copied' ((((Sent) -join ';') -eq '13,0,0') -and (J '/replay').photo.state -eq 'small' -and @(Get-ChildItem (Join-Path $testDir 'mine') -Filter 'me-*.png').Count -eq 1)
Start-Sleep -Milliseconds 5200
State
Fresh; $null = Api 'rpphoto' ''; Start-Sleep -Milliseconds 9500
Check 'when iRacing saves nothing it says so (failed) and the UI comes back' ((J '/replay').photo.state -eq 'failed' -and (((Sent) -join ';') -eq '2,8,0;13,0,0;2,0,0'))
Start-Sleep -Milliseconds 5200

'PHOTO when iRacing has screen capture switched off (its Interface settings; the sim says so in VidCapEnabled): nothing is sent, the key says so'
State @{ VidCapEnabled = 0 }
$st = J '/replay'
Check 'capture is reported off (photo.capture 0)' ($st.photo.capture -eq 0)
Refused 'PHOTO while iRacing''s screen capture is off' 'rpphoto' ''
State @{ VidCapEnabled = 1 }
$st = J '/replay'
Check 'with capture on again it is reported on (1) and PHOTO is accepted' ($st.photo.capture -eq 1 -and (Api 'rpphoto' '') -eq 200)
Start-Sleep -Milliseconds 9500                                                  # no picture comes: the attempt ends (failed) and the UI is put back
Start-Sleep -Milliseconds 100

'a view chosen by hand turns the TV director (auto shot selection, bit 0x10) off first - it is on by default out of the car and would change the camera again'
State @{ CamCameraState = 17 }
Key 'TV with the director on' 'rpgroup' 'tv' '2,0,0;1,940,196619'
Key 'CAMERA > with the director on' 'rpcamnext' '' '2,0,0;1,940,262155'
State @{ CamCameraState = 25 }
Key 'CAMERA < with the director on and the UI hidden: only the director bit goes' 'rpcamprev' '' '2,8,0;1,940,131083'
State @{ CamCameraState = 17 }
Key 'MY CAR with the director on leaves it on (the director follows the car)' 'rpmycar' '' '1,64,196619'

'no session: MY REPLAYS'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8; Start-Sleep -Milliseconds 600
$st = J '/replay'; $snap.none = Raw '/replay'
Check 'out of a session /replay says so and lists the saved replays' (-not $st.inSession -and $null -ne $st.replays -and $st.replays.count -ge 0 -and @($st.replays.items).Count -le 8)
Refused 'a key out of a session' 'rpplay' ''
"        saved replays found in Documents\iRacing\replay: $($st.replays.count)"

# ================= 2. the deck screen =================
if (-not $NoDeck) {
Section '2. the deck screen drawn by the real add-on code (headless Chrome, pretend Stream Deck app)'
# bring the pretend session back for a fresh set of real answers for each view
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/session?file=$(Q $race)" -TimeoutSec 15
State
$snap.play = Raw '/replay'
State @{ ReplayPlaySpeed = 0 }; $snap.paused = Raw '/replay'
State @{ ReplayPlaySpeed = 4 }; $snap.fast = Raw '/replay'
State @{ ReplayPlaySpeed = -2 }; $snap.rew = Raw '/replay'
State @{ ReplayPlaySpeed = 3; ReplayPlaySlowMotion = 1 }; $snap.slow = Raw '/replay'
State @{ IsReplayPlaying = 0 }; $snap.live = Raw '/replay'
State @{ ReplaySessionNum = 0; ReplaySessionTime = 300; ReplayFrameNumEnd = 99999; CamGroupNumber = 9; CamCameraNumber = 1; CamCameraState = 24 }; $snap.old = Raw '/replay'
State @{ IsOnTrack = 1; IsReplayPlaying = 0 }; $snap.driving = Raw '/replay'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8; Start-Sleep -Milliseconds 600
$snap.none = Raw '/replay'
Remove-Item -LiteralPath $hook -Force -ErrorAction SilentlyContinue   # the pretend session is over: the deck part does not need irdash's hook

$fx = @{ '/guest' = (J '/guest'); '/overlays' = (J '/overlays'); '/showcase' = @{ seq = 0; play = $false; driving = $false }; '/replay' = @{ ready = $false } }
$fx['/mydrive'] = New-MyDriveFixture
# the pretend Stream Deck app (tests\deck-mock.js) knows three opener keys; this test adds the REPLAY key and the RigReplay profile to its copy
$html = Join-Path $env:TEMP 'replay-test-harness.html'
$url = Build-DeckHarness (Join-Path $root 'deck-intro\plugin.html') $html
$h = [IO.File]::ReadAllText($html)
$h2 = $h.Replace("['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1]];", "['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1], ['k-replay', 'com.peter.rigintro.replay', 4, 1]];").Replace("RigMyDrive: 'mydrive',", "RigMyDrive: 'mydrive', RigReplay: 'replay',")
Check 'the pretend Stream Deck app was given the REPLAY key and the RigReplay profile' ($h2 -ne $h -and $h2.Contains('RigReplay'))
[IO.File]::WriteAllText($html, $h2, (New-Object Text.UTF8Encoding($false)))
$b = Start-DeckBrowser 9353
try {
  $page = New-DeckPage $b $url -Hidden
  Start-Sleep -Milliseconds 600
  Start-DeckAddon $page $fx
  Start-Sleep -Seconds 3
  $null = Invoke-DeckJs $page "(() => { window.__apis = []; __sd.onApi = p => window.__apis.push(p); return 1; })()"
  function Apis { @(Invoke-DeckJs $page 'window.__apis') }
  function ClearApis { $null = Invoke-DeckJs $page 'window.__apis.length = 0' }
  function Press($c, $r, $wait = 400) { $null = Invoke-DeckJs $page "(async () => { __sd.pressTile($c, $r); await __sd.sleep($wait); return 1; })()" }
  function Use($name) { $null = Invoke-DeckJs $page "(async () => { __sd.fx['/replay'] = $($snap[$name]); await __sd.sleep(1400); return 1; })()" }
  function Js($js) { $null = Invoke-DeckJs $page "(async () => { const m = __sd.fx['/replay']; $js; await __sd.sleep(1400); return 1; })()" }
  function Sheet($name) { return Save-DeckSheet $page (Join-Path $shots "$name.png") }
  function Look($c, $r) { Invoke-DeckJs $page "(async () => { const u = __sd.images[__sd.tileCtx($c, $r)]; return u ? await __sd.classify(u) : 'none'; })()" }
  function Reg($c, $r) { Invoke-DeckJs $page "(() => { const r = Replay.regions.find(x => $c >= x.c && $c < x.c + x.w && $r >= x.r && $r < x.r + x.h); return r ? { t: r.text, s: r.sub, st: r.style, a: r.act, g: r.arg } : null; })()" }
  function Blank { Invoke-DeckJs $page "Object.values(Replay.looks).filter(l => l.startsWith('blank')).length" }
  function Req($c, $r, $re, $what, $wait = 400) { ClearApis; Press $c $r $wait; $a = @(Apis); Check "$what -> $re" (@($a | Where-Object { $_ -match $re }).Count -ge 1); if (@($a | Where-Object { $_ -match $re }).Count -lt 1) { '        requests: ' + ($a -join ' ') } }

  # -- the REPLAY key on your own page, then open it while replaying at x1 --
  Use 'play'
  Start-Sleep -Milliseconds 2500                                            # the opener key fetches /replay every 2 s
  $m1 = Invoke-DeckJs $page "__sd.measureOpen('replay')"
  Start-Sleep -Milliseconds 800
  "        press -> first key appeared $([int]$m1.firstAppearMs) ms, all 32 pictures $([int]$m1.allPicturesMs) ms (the pretend Stream Deck app takes 150 ms to show a profile)"
  Check 'REPLAY: all 32 pictures are on the keys within 100 ms of the deck showing the screen' ($m1.allPicturesMs -ge 0 -and ($m1.allPicturesMs - $m1.firstAppearMs) -le 100)
  Check 'REPLAY opens: all 32 keys have a picture' ((Sheet 'rp-deck-replaying') -eq 32)
  Check 'every one of the 32 keys is part of the screen (nothing left blank)' ((Blank) -eq 0)
  Check 'it asked for the RigReplay profile' ((Invoke-DeckJs $page '__sd.cur') -eq 'RigReplay')
  $r = Reg 7 0; Check 'LIVE says BACK TO NOW (green, pressable) while replaying' ($r.t -eq 'LIVE' -and $r.s -eq 'BACK TO NOW' -and $r.a -eq 'rplive' -and $r.st -eq 'go')
  $r = Reg 3 1; Check 'PLAY / PAUSE says PAUSE while playing' ($r.t -eq 'PAUSE' -and $r.a -eq 'rpplay')
  $r = Reg 2 1; Check 'REWIND says what a tap does (x1 back)' ($r.t -eq 'REWIND' -and $r.s -match 'TAP FOR' -and $r.a -eq 'rprew')
  $r = Reg 4 1; Check 'FAST says what a tap does (x2)' ($r.t -eq 'FAST' -and $r.s -match 'TAP FOR' -and $r.a -eq 'rpfast')
  $r = Reg 3 3; Check 'COCKPIT exists and is not chosen; TV is gold (the camera is TV1)' ($r.st -eq '' -and (Reg 2 3).st -eq 'sel')
  $r = Reg 0 3; Check 'the camera keys show the camera name TV1 and "VIEW 3 OF 11"' ($r.t -eq 'TV1' -and $r.s -eq 'VIEW 3 OF 11' -and $r.a -eq 'cam')
  $r = Reg 6 0; Check 'SESSION says what a tap does (PRACTICE next)' ($r.t -eq 'SESSION' -and $r.s -eq 'TAP FOR PRACTICE')
  $r = Reg 7 2; Check 'MY LAST INCIDENT is there' ($r.t -eq 'MY LAST INCIDENT' -and $r.a -eq 'rpmyinc')
  Check 'the strip (timeline) is five keys wide and pressable' ((Invoke-DeckJs $page "Replay.regions.some(r => r.c === 1 && r.r === 0 && r.w === 5 && r.act === 'rpjump')") -eq $true)
  Check 'opening REPLAY wrote a timing line' (@((Invoke-DeckJs $page '__sd.perfLines()') | Where-Object { $_ -match 'perf replay open' }).Count -ge 1)

  # -- every key sends its request --
  Req 0 1 'c=rpstart' 'START'
  Req 1 1 'c=rplapprev' 'LAP back'
  Req 2 1 'c=rprew' 'REWIND'
  Req 3 1 'c=rpplay' 'PAUSE'
  Req 4 1 'c=rpfast' 'FAST'
  Req 5 1 'c=rplapnext' 'LAP on'
  Req 6 1 'c=rpslow' 'SLOW MO'
  Req 7 1 'c=rpback10' 'BACK 10 S'
  Req 0 2 'c=rpincprev' 'INCIDENT back'
  Req 1 2 'c=rpincnext' 'INCIDENT on'
  Req 2 2 'c=rpmycar' 'MY CAR'
  Req 3 2 'c=rpahead' 'CAR AHEAD'
  Req 4 2 'c=rpbehind' 'CAR BEHIND'
  Req 5 2 'c=rpleader' 'LEADER'
  Req 7 2 'c=rpmyinc' 'MY LAST INCIDENT'
  Req 0 3 'c=rpcamprev' 'the left half of the camera key'
  Req 1 3 'c=rpcamnext' 'the right half of the camera key'
  Req 2 3 'c=rpgroup&a=tv' 'TV'
  Req 3 3 'c=rpgroup&a=cockpit' 'COCKPIT'
  Req 4 3 'c=rpgroup&a=chase' 'CHASE'
  Req 5 3 'c=rpautotv' 'AUTO TV'
  Req 6 3 'c=rphideui' 'HIDE UI'
  Req 7 3 'c=rpphoto' 'PHOTO'
  Req 6 0 'c=rpsession' 'SESSION'
  Req 7 0 'c=rplive' 'LIVE (while replaying)'
  foreach ($i in 0..4) { Req (1 + $i) 0 "c=rpjump&a=$i" "timeline fifth $($i + 1)" }

  # -- the other states --
  Use 'paused'
  Check 'paused: REWIND and FAST become one-frame steps, PLAY is green' ((Reg 2 1).t -match 'FRAME' -and (Reg 4 1).t -match 'FRAME' -and (Reg 3 1).t -eq 'PLAY' -and (Reg 3 1).st -eq 'go')
  $null = Sheet 'rp-deck-paused'
  Req 3 1 'c=rpplay' 'PLAY (paused)'
  Use 'fast'
  $r = Reg 4 1; Check 'x4 fast forward: FAST is gold and says what a tap does (x8)' ($r.st -eq 'sel' -and $r.s -match 'TAP FOR .8')
  $null = Sheet 'rp-deck-fast'
  Use 'rew'
  $r = Reg 2 1; Check 'x2 rewind: REWIND is gold and says what a tap does (x4 back)' ($r.st -eq 'sel' -and $r.s -match 'TAP FOR .4 BACK')
  Use 'slow'
  $r = Reg 6 1; Check 'quarter speed: SLOW MO is gold and says what a tap does (the next step, not NORMAL yet)' ($r.st -eq 'sel' -and $r.s -match 'TAP FOR' -and $r.s -notmatch 'NORMAL')
  $null = Sheet 'rp-deck-slow'
  Use 'live'
  $r = Reg 7 0; Check 'live: LIVE is gold and does nothing' ($r.st -eq 'sel' -and $null -eq $r.a)
  Check 'live: PAUSE says LIVE NOW' ((Reg 3 1).t -eq 'PAUSE' -and (Reg 3 1).s -eq 'LIVE NOW')
  Check 'live: LIVE key picture is gold' ((Look 7 0) -eq 'gold')
  $null = Sheet 'rp-deck-live'
  Use 'old'
  Check 'an older session: the strip counts up from the start of it, the cockpit camera is gold, auto TV and hidden UI are gold' ((Reg 3 3).st -eq 'sel' -and (Reg 5 3).st -eq 'sel' -and (Reg 6 3).st -eq 'sel')
  $null = Sheet 'rp-deck-older-session'

  # -- PICK CAR --
  Use 'play'
  Press 6 2 500
  Check 'PICK CAR shows the list (32 keys; with 20 cars the last 4 tiles are empty)' ((Sheet 'rp-deck-pick') -eq 32 -and (Blank) -eq 4)
  $r = Reg 0 1; Check 'the first tile is P1 (the leader) with number and name' ($r.t -eq 'P1' -and $r.s -eq '#00 REGAN' -and $r.a -eq 'rpcar' -and $r.g -eq '19')
  $gold = Invoke-DeckJs $page "Replay.regions.filter(x => x.r >= 1 && x.style === 'sel').map(x => x.sub)"
  Check 'my car (#64 ADAMIS) is the one gold tile, last place' (@($gold).Count -eq 1 -and @($gold)[0] -eq '#64 ADAMIS' -and (Reg 3 3).t -eq 'P20')
  Check 'the car being watched has its own colour' ((Invoke-DeckJs $page "Replay.regions.filter(x => x.r >= 1 && x.style === 'watch').map(x => x.sub)") -eq '#940 ZHU')
  Check 'with one page of cars the page keys are dim and do nothing' ((Reg 6 0).st -eq 'dim' -and (Reg 7 0).st -eq 'dim')
  Js "m.cars = m.cars.concat(m.cars.slice(0, 12).map((c, i) => Object.assign({}, c, { idx: 30 + i, pos: 21 + i, me: false, watch: false, num: String(100 + i) })))"
  Check 'with 32 cars there are two pages and NEXT PAGE works' ((Reg 7 0).a -eq 'picknext' -and (Reg 6 0).a -eq $null)
  Press 7 0 400
  Check 'page 2 shows the rest (8 cars)' ((Invoke-DeckJs $page "Replay.regions.filter(x => x.r >= 1).length") -eq 8 -and (Reg 6 0).a -eq 'pickprev' -and (Reg 7 0).a -eq $null)
  $null = Sheet 'rp-deck-pick-page2'
  Press 6 0 400
  ClearApis; Press 2 1 500
  Check 'a tile sends rpcar with that car and goes back to the controls' (@(Apis | Where-Object { $_ -match 'c=rpcar&a=17' }).Count -eq 1 -and (Reg 7 0).t -eq 'LIVE')
  Press 6 2 400; Press 0 0 400
  Check 'BACK in the list returns to the controls (not to your keys)' ((Reg 7 0).t -eq 'LIVE' -and (Invoke-DeckJs $page '__sd.cur') -eq 'RigReplay')

  # -- driving, and out of a session --
  Use 'driving'
  Check 'driving: every key except BACK is dim and does nothing' ((Invoke-DeckJs $page "Replay.regions.filter(x => x.act && x.act !== 'back').length") -eq 0 -and (Reg 0 0).a -eq 'back')
  Check 'driving: the strip says GET OUT OF THE CAR TO WATCH REPLAYS' ((Invoke-DeckJs $page "Replay.regions.find(x => x.r === 0 && x.c === 1).extra") -match 'GET OUT OF THE CAR')
  Check 'driving: 32 keys' ((Sheet 'rp-deck-driving') -eq 32)
  ClearApis; Press 3 1 400
  Check 'a press while driving sends nothing' (@(Apis | Where-Object { $_ -match 'c=rp' }).Count -eq 0)
  Use 'none'
  Check 'no session: MY REPLAYS (BACK, banner, a message or the list, a note) - 32 keys' ((Sheet 'rp-deck-myreplays-empty') -eq 32)
  Js "m.replays = { count: 3, items: [ { name: 'Race at Road Atlanta', when: 'today', where: 'raygr22 24S2 Formula 1600 Trophy Week 3', mb: 340 }, { name: 'Open practice Sebring', when: 'yesterday', where: '', mb: 120 }, { name: 'subses0000012', when: '3 Oct 2026', where: 'mx5 mx52016', mb: 80 } ] }"
  Check 'with saved replays: they are listed, newest first, not pressable (iRacing opens them)' ((Invoke-DeckJs $page "Replay.regions.filter(x => x.r >= 1 && x.r <= 2 && x.text).length") -eq 3 -and (Invoke-DeckJs $page "Replay.regions.filter(x => x.r >= 1 && x.r <= 2 && x.act).length") -eq 0)
  Check 'with saved replays: 32 keys' ((Sheet 'rp-deck-myreplays-list') -eq 32)
  Press 0 0 700
  Check 'BACK goes back to your own keys' ((Invoke-DeckJs $page '__sd.cur') -eq 'main')
  Check 'nothing the REPLAY screen sent was a command irdash would not take (all rp...)' (@(Apis | Where-Object { $_ -match '/api/do\?c=(?!rp)' }).Count -eq 0)
}
finally { Stop-DeckBrowser $b }
}

# ================= 3. LIVE =================
if ($Live) {
Section '3. LIVE: a real AI race, spectated (the real sim starts; nobody may be in the car)'
Remove-Item -LiteralPath $hook -Force -ErrorAction SilentlyContinue          # no pretend session may exist next to a real one
$cli = Join-Path $root 'irdeck-cli.exe'
function Ir { $o = & $cli @args 2>&1 | ForEach-Object { "$_" }; [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join "`n") } }
Add-Type -AssemblyName System.Windows.Forms
$mid = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.X -eq 0 -and $_.Bounds.Y -eq 0 } | Select-Object -First 1
function Shot($name) {
  $bo = $mid.Bounds; $bmp = New-Object System.Drawing.Bitmap $bo.Width, $bo.Height; $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($bo.Location, [System.Drawing.Point]::Empty, $bo.Size)
  $s = New-Object System.Drawing.Bitmap $bmp, 1280, 720; $s.Save((Join-Path $shots "rp-live-$name.png")); $g.Dispose(); $bmp.Dispose(); $s.Dispose()
}
# one reading of the sim's own telemetry (through irdash's /stream): the replay variables
function Tel {
  $names = 'IsOnTrack,IsReplayPlaying,ReplayPlaySpeed,ReplayPlaySlowMotion,ReplayFrameNum,ReplayFrameNumEnd,ReplaySessionNum,ReplaySessionTime,CamCarIdx,CamGroupNumber,CamCameraNumber,CamCameraState,PlayerCarIdx,SessionNum,SessionTime,SessionState,CarIdxPosition,CarIdxLap,VidCapEnabled,VidCapActive'
  $req = [Net.HttpWebRequest]::Create("$api/stream?vars=$names&hz=20"); $req.Timeout = 8000; $req.ReadWriteTimeout = 8000
  $resp = $req.GetResponse(); $sr = New-Object IO.StreamReader($resp.GetResponseStream())
  try { for ($i = 0; $i -lt 60; $i++) { $line = $sr.ReadLine(); if ($line -and $line.StartsWith('data: {')) { return ($line.Substring(6) | ConvertFrom-Json).v } } }
  finally { $sr.Dispose(); $resp.Close() }
  return $null
}
function Pause-Sim($ms = 800) { Start-Sleep -Milliseconds $ms }
# press a key through irdash, wait, read the sim back, picture of the middle screen
function Press-Live($label, $c, $a, $shotName, $sb) {
  Check-Time; Start-Sleep -Milliseconds 350
  $code = Api $c $a; Start-Sleep -Milliseconds 900
  $t = Tel
  $ok = $false; try { $ok = [bool](& $sb $t) } catch { Write-Host "        (check error: $($_.Exception.Message))" }
  Check "$label (HTTP $code)" ($code -eq 200 -and $ok)                       # Write-Host above: this function returns the reading, not text
  if ($shotName) { Shot $shotName }
  return $t
}
# playback speed measured over 2 s of real time: frames moved / (60 per second x seconds)
function Rate-Now {
  Check-Time; $a = Tel; $sw = [Diagnostics.Stopwatch]::StartNew(); Start-Sleep -Milliseconds 2000; $b2 = Tel
  return [math]::Round(($b2.ReplayFrameNum - $a.ReplayFrameNum) / (60.0 * $sw.Elapsed.TotalSeconds), 2)
}

$gallery = Join-Path $root 'paddock\gallery\mine'
$galBefore = @(Get-ChildItem $gallery -Filter 'me-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$shotsDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\screenshots'
$irShotsBefore = @(Get-ChildItem $shotsDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
try {
  if ((Ir state).out -match 'telemetry=on') { 'iRacing is in a session - run this when nobody is in the car.'; throw 'a session is already running' }
  $t0 = Get-Date; $script:liveStart = $t0; $markFile = Join-Path $root 'dash\start-mark.txt'; $markBefore = Test-Path $markFile
  $env:RIG_TEST_OWNS_SIM = '1'                                                # set BEFORE the start: irdeck then labels the session TEST and irdash keeps it out of Peter's outings (PL-1)
  $r = Ir startlast ai
  $ownsSim = $true                                                            # the sim is ours now: the guard must not stop us
  Check "AI RACE LAST started ($([int]((Get-Date) - $t0).TotalSeconds) s)" ($r.rc -eq 0)
  if ($r.rc -ne 0) { throw "the AI race did not start: $($r.out)" }
  $null = Ir getout; Start-Sleep -Seconds 3
  $r = Ir skip
  Check 'SKIP went on to the race (session 1)' ($r.rc -eq 0)
  $t = Tel
  Check 'we are out of the car, spectating' ($t -and $t.IsOnTrack -eq 0)
  if ($t.IsOnTrack -ne 0) { throw 'the car is on track - stopping: this test must not drive' }
  # wait for the green flag, then two minutes of racing so there is a tape to move around in
  for ($i = 0; $i -lt 480; $i++) { Check-Time; $t = Tel; if ($t.SessionState -eq 4) { break }; Start-Sleep -Seconds 1 }   # the AI race waits about 5 minutes (get in car, warm-up, parade) before the green flag
  Check 'the race is green' ($t.SessionState -eq 4)
  "        racing for two minutes so the tape has something on it ..."
  for ($i = 0; $i -lt 12; $i++) { Check-Time; Start-Sleep -Seconds 10 }
  Section '3b. LIVE: the keys'
  $me = $t.PlayerCarIdx
  $rp = J '/replay'
  Check '/replay in the real race: in a session, not driving, a race with several cars and cameras' ($rp.inSession -and -not $rp.driving -and @($rp.cars).Count -ge 5 -and $rp.camera.tv)
  "        session $($rp.session.name), $(@($rp.cars).Count) cars, cameras: tv=$($rp.camera.tv) cockpit=$($rp.camera.cockpit) chase=$($rp.camera.chase), sessions on the tape: $((@($rp.sessions) | ForEach-Object { $_.name }) -join ', ')"
  Shot 'start'
  $t = Tel
  "        at the live edge, out of the car: IsReplayPlaying=$($t.IsReplayPlaying) speed=$($t.ReplayPlaySpeed) slow=$($t.ReplayPlaySlowMotion) frame=$($t.ReplayFrameNum) framesFromEnd=$($t.ReplayFrameNumEnd) replaySession=$($t.ReplaySessionNum)/$($t.SessionNum) camCar=$($t.CamCarIdx) group=$($t.CamGroupNumber) camera=$($t.CamCameraNumber) state=$($t.CamCameraState) VidCapEnabled=$($t.VidCapEnabled) VidCapActive=$($t.VidCapActive)"
  "        /replay says: live=$($rp.live) mode=$($rp.mode) fromLive=$($rp.session.fromLive) len=$($rp.session.len) frac=$($rp.session.frac) watch=$($rp.watch.name)"

  'row 1: pause, play, rewind, fast, slow motion (speed read back; real speed measured over 2 s)'
  $t = Press-Live 'PAUSE (live) pauses and enters the replay' 'rpplay' '' 'pause' { param($x) $x.IsReplayPlaying -eq 1 -and $x.ReplayPlaySpeed -eq 0 }
  $f1 = (Tel).ReplayFrameNum; Start-Sleep -Milliseconds 1200; $f2 = (Tel).ReplayFrameNum
  Check 'paused: the picture really stands still (frame number does not move)' ($f1 -eq $f2)
  $t = Press-Live 'FRAME back (paused) steps one frame back' 'rprew' '' 'frame-back' { param($x) $x.ReplayFrameNum -lt $f2 }
  $fb = $t.ReplayFrameNum; "        one frame back moved the frame number by $($fb - $f2)"
  $t = Press-Live 'FRAME on (paused) steps one frame on' 'rpfast' '' 'frame-on' { param($x) $x.ReplayFrameNum -gt $fb }
  "        one frame on moved the frame number by $($t.ReplayFrameNum - $fb)"
  $t = Press-Live 'PLAY resumes at normal speed' 'rpplay' '' 'play' { param($x) $x.ReplayPlaySpeed -eq 1 -and $x.ReplayPlaySlowMotion -eq 0 }
  "        measured speed at x1: $(Rate-Now)"
  # room to run: FAST at the live edge snaps back to live at once (seen 2026-10-10), so go to the middle of the session first
  $null = Api 'rpjump' '2'; Start-Sleep -Milliseconds 1800
  $null = Api 'rpplay' ''; Start-Sleep -Milliseconds 400; $null = Api 'rpplay' ''; Start-Sleep -Milliseconds 1200   # (pause, then play: normal speed from the middle)
  foreach ($n in 2, 4, 8, 16) {
    $t = Press-Live "FAST step x$n" 'rpfast' '' "fast-$n" { param($x) $x.ReplayPlaySpeed -eq $n -and $x.ReplayPlaySlowMotion -eq 0 }
    if ($n -in 2, 16) { "        measured speed at x${n}: $(Rate-Now)" }
  }
  $t = Press-Live 'FAST after x16 goes back to normal' 'rpfast' '' 'fast-normal' { param($x) $x.ReplayPlaySpeed -eq 1 }
  foreach ($n in 1, 2, 4, 8, 16) {
    $t = Press-Live "REWIND step x$n back" 'rprew' '' "rew-$n" { param($x) $x.ReplayPlaySpeed -eq -$n -and $x.ReplayPlaySlowMotion -eq 0 }
    if ($n -in 1, 4) { "        measured speed at -${n}: $(Rate-Now)" }
  }
  $t = Press-Live 'REWIND after x16 goes back to normal' 'rprew' '' 'rew-normal' { param($x) $x.ReplayPlaySpeed -eq 1 }
  foreach ($raw in 1, 3, 7) {
    $t = Press-Live "SLOW MO step (raw $raw, slow-motion flag on)" 'rpslow' '' "slow-$raw" { param($x) $x.ReplayPlaySpeed -eq $raw -and $x.ReplayPlaySlowMotion -eq 1 }
    "        slow motion raw $raw read back as speed $($t.ReplayPlaySpeed), flag $($t.ReplayPlaySlowMotion); measured speed $(Rate-Now) (1 / $($raw + 1) = $([math]::Round(1.0 / ($raw + 1), 2)) if raw N plays at 1/(N+1))"
  }
  $t = Press-Live 'SLOW MO after 1/8 goes back to normal' 'rpslow' '' 'slow-normal' { param($x) $x.ReplayPlaySpeed -eq 1 -and $x.ReplayPlaySlowMotion -eq 0 }

  'timeline, START, laps, back 10 s, session'
  foreach ($i in 0, 2, 4) {
    $len = (J '/replay').session.len; $want = $len * ($i + 0.5) / 5     # the session keeps growing while we test: read its length just before each press
    $t = Press-Live "timeline fifth $($i + 1) jumps to about $([int]$want) s of $([int]$len) s" 'rpjump' "$i" "jump-$i" { param($x) [math]::Abs($x.ReplaySessionTime - $want) -lt 5 }
  }
  $t = Press-Live 'START goes to the start of the session (time under 4 s)' 'rpstart' '' 'start-of-session' { param($x) $x.ReplaySessionTime -lt 4 }
  $null = Api 'rpjump' '3'; Start-Sleep -Milliseconds 1200; $before = (Tel).ReplaySessionTime
  $t = Press-Live 'BACK 10 S goes about 10 s back' 'rpback10' '' 'back10' { param($x) $x.ReplaySessionTime -lt $before - 6 -and $x.ReplaySessionTime -gt $before - 16 }
  $null = Api 'rpplay' ''; Start-Sleep -Milliseconds 1200                  # paused: the frame number now only moves when a key moves it
  $f0 = (Tel).ReplayFrameNum
  $t = Press-Live 'LAP > (paused) jumps on to the next lap' 'rplapnext' '' 'lap-next' { param($x) $x.ReplayFrameNum -gt $f0 }
  "        next lap moved the frame by $($t.ReplayFrameNum - $f0)"
  $f0 = $t.ReplayFrameNum
  $t = Press-Live 'LAP < (paused) jumps back' 'rplapprev' '' 'lap-prev' { param($x) $x.ReplayFrameNum -lt $f0 }
  "        previous lap moved the frame by $($t.ReplayFrameNum - $f0)"
  $null = Api 'rpplay' ''; Start-Sleep -Milliseconds 600
  $rp = J '/replay'
  if ($rp.nextSession) {
    $want = $rp.nextSession.num
    $t = Press-Live "SESSION goes to $($rp.nextSession.name) (number $want)" 'rpsession' '' 'session' { param($x) $x.ReplaySessionNum -eq $want }
  } else { '  (SESSION: only one session on the tape, nothing to switch to)' }
  $t = Press-Live 'LIVE goes back to live at normal speed' 'rplive' '' 'live' { param($x) $x.IsReplayPlaying -eq 0 -or ($x.ReplayFrameNumEnd -lt 90 -and $x.ReplayPlaySpeed -eq 1) }
  "        after LIVE: replay playing $($t.IsReplayPlaying), frames from the end of the tape $($t.ReplayFrameNumEnd)"

  'row 3: incidents and cars'
  $f0 = $t.ReplayFrameNum
  $t = Press-Live 'INCIDENT < (previous) is accepted' 'rpincprev' '' 'incident-prev' { param($x) $true }
  "        the search moved the frame from $f0 to $($t.ReplayFrameNum), replay playing $($t.IsReplayPlaying) (a calm AI race may have no incident to find)"
  $f0 = $t.ReplayFrameNum
  $t = Press-Live 'INCIDENT > (next) is accepted' 'rpincnext' '' 'incident-next' { param($x) $true }
  "        the search moved the frame from $f0 to $($t.ReplayFrameNum)"
  $t = Press-Live 'MY CAR puts the camera on my car (CamSwitchNum)' 'rpmycar' '' 'my-car' { param($x) $x.CamCarIdx -eq $me }
  $pick = (@($rp.cars) | Where-Object { -not $_.me } | Select-Object -Skip 4 -First 1).idx
  $t = Press-Live "PICK CAR car $pick (CamSwitchNum with its number)" 'rpcar' "$pick" 'pick-car' { param($x) $x.CamCarIdx -eq $pick }
  $t = Tel; $pos = @($t.CarIdxPosition); $myPos = $pos[$t.CamCarIdx]
  $ahead = [array]::IndexOf($pos, $myPos - 1); $behind = [array]::IndexOf($pos, $myPos + 1)
  if ($ahead -ge 0 -and $myPos -gt 1) { $t = Press-Live "CAR AHEAD of car $($t.CamCarIdx) (P$myPos -> P$($myPos - 1), car $ahead)" 'rpahead' '' 'car-ahead' { param($x) $x.CamCarIdx -eq $ahead } } else { "  (the car watched leads: no car ahead)" }
  $t = Tel; $pos = @($t.CarIdxPosition); $myPos = $pos[$t.CamCarIdx]; $behind = [array]::IndexOf($pos, $myPos + 1)
  if ($behind -ge 0) { $t = Press-Live "CAR BEHIND car $($t.CamCarIdx) (P$myPos -> P$($myPos + 1), car $behind)" 'rpbehind' '' 'car-behind' { param($x) $x.CamCarIdx -eq $behind } } else { "  (nobody behind)" }
  $t = Press-Live 'LEADER (follow the leader, CamSwitchPos -2) puts the camera on the car in P1' 'rpleader' '' 'leader' { param($x) $p1 = [array]::IndexOf(@($x.CarIdxPosition), 1); $x.CamCarIdx -eq $p1 }
  "        camera car after LEADER: $($t.CamCarIdx); the car in P1 is $([array]::IndexOf(@($t.CarIdxPosition), 1)) (if these differ, LEADER should send CamSwitchPos with position 1 instead of -2: see docs\replay.md)"
  $t = Press-Live 'MY LAST INCIDENT (end of the tape, previous incident, my car, play)' 'rpmyinc' '' 'my-last-incident' { param($x) $x.CamCarIdx -eq $me }
  "        after MY LAST INCIDENT: frame $($t.ReplayFrameNum), $($t.ReplayFrameNumEnd) frames from the end, speed $($t.ReplayPlaySpeed)"

  'row 4: cameras'
  $rp = J '/replay'
  foreach ($k in 'tv', 'cockpit', 'chase') {
    if (-not $rp.camera.$k) { "  ($k camera: this track has none)"; continue }
    $t = Press-Live "$($k.ToUpper()) key puts the camera in that group" 'rpgroup' $k "cam-$k" { param($x) $true }
    Start-Sleep -Milliseconds 800                                          # past the 1.5 s the screen shows a press before the sim has confirmed it
    $name = (J '/replay').camera.name
    Check "the camera group is now $name ($k)" ($name -match $(if ($k -eq 'tv') { '^TV ?1$' } elseif ($k -eq 'cockpit') { '^Cockpit$' } else { '^Chase$' }))
  }
  $g0 = (Tel).CamGroupNumber; $c0 = (Tel).CamCameraNumber
  $t = Press-Live 'CAMERA > goes to another camera' 'rpcamnext' '' 'camera-next' { param($x) $x.CamGroupNumber -ne $g0 -or $x.CamCameraNumber -ne $c0 }
  $g1 = $t.CamGroupNumber; $c1 = $t.CamCameraNumber
  $t = Press-Live 'CAMERA < goes back to the one before' 'rpcamprev' '' 'camera-prev' { param($x) $x.CamGroupNumber -eq $g0 -and $x.CamCameraNumber -eq $c0 }
  $bits0 = (Tel).CamCameraState
  $t = Press-Live 'AUTO TV switches the director on (bit 0x10)' 'rpautotv' '' 'auto-tv-on' { param($x) ($x.CamCameraState -band 0x10) -ne ($bits0 -band 0x10) }
  $t = Press-Live 'AUTO TV again switches it off' 'rpautotv' '' 'auto-tv-off' { param($x) ($x.CamCameraState -band 0x10) -eq ($bits0 -band 0x10) }
  $t = Press-Live 'HIDE UI hides the menus (bit 0x08)' 'rphideui' '' 'hide-ui' { param($x) ($x.CamCameraState -band 0x08) -ne ($bits0 -band 0x08) }
  $t = Press-Live 'HIDE UI again shows them' 'rphideui' '' 'show-ui' { param($x) ($x.CamCameraState -band 0x08) -eq ($bits0 -band 0x08) }
  "        camera state bits: before $bits0, now $($t.CamCameraState)"

  'PHOTO: hide the UI, iRacing screenshot, UI back, copy to the gallery'
  $tv = Tel
  "        iRacing says VidCapEnabled=$($tv.VidCapEnabled) (the sim only takes a screenshot with Interface settings > Camera & Screen Capture > Video and Screen Capture ON; Peter's app.ini had vidCaptureEnable=0)"
  if ($tv.VidCapEnabled -eq 0) {
    $code = Api 'rpphoto' ''
    Check 'iRacing screen capture is off: /replay says so (capture 0), the key is refused (HTTP 400) and nothing is sent' ((J '/replay').photo.capture -eq 0 -and $code -eq 400)
    # the SDK screenshot message itself, once: does it save anything when capture is off? (it did not on 2026-10-10)
    $irBefore2 = @(Get-ChildItem $shotsDir -Recurse -File -ErrorAction SilentlyContinue).Count
    "        (not sent: with capture off the sim saves no screenshot; PHOTO stays dim on the deck until Peter switches it on)"
  } else {
    $code = Api 'rpphoto' ''
    Check 'PHOTO accepted' ($code -eq 200)
    for ($i = 0; $i -lt 30 -and (J '/replay').photo.state -eq 'working'; $i++) { Check-Time; Start-Sleep -Milliseconds 500 }
    $ph = (J '/replay').photo; "        photo: $($ph.state) $($ph.msg)"
    $irNew = @(Get-ChildItem $shotsDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $irShotsBefore -notcontains $_.FullName })
    Check 'iRacing saved a new screenshot in Documents\iRacing\screenshots' ($irNew.Count -ge 1)
    if ($irNew.Count -ge 1) { "        screenshot: $($irNew[0].FullName) ($([math]::Round($irNew[0].Length / 1MB, 1)) MB)" }
    Check 'the camera state is back as it was (UI visible again)' (((Tel).CamCameraState -band 0x08) -eq ($bits0 -band 0x08))
    Check 'the photo was copied into paddock\gallery\mine (if it is 2560 wide or more) - or reported as too small' ($ph.state -eq 'saved' -or $ph.state -eq 'small')
  }
  Shot 'photo-done'

  'driving refuses (the guard in irdash): get in the car'
  $null = Ir go; Start-Sleep -Seconds 2
  $t = Tel
  Check 'in the car: IsOnTrack' ($t.IsOnTrack -eq 1)
  $code = Api 'rpplay' ''
  Check 'irdash refuses a REPLAY key while you are in the car (HTTP 400)' ($code -eq 400)
  Check 'the car did not move and the sim is not paused or replaying' ((Tel).IsReplayPlaying -eq 0)
  Shot 'driving'
}
finally {
  if ($ownsSim) {
    $q = Ir quitmain
    Check 'QUIT TO MAIN at the end (iRacing back on Home)' ($q.rc -eq 0)
    # the sim must not be left running: wait for its process to go, ask it to close if it stays
    for ($i = 0; $i -lt 40 -and (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 2 }
    if (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue) { $null = Ir quit-sim; for ($i = 0; $i -lt 30 -and (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 2 } }
    Check 'the sim process has exited' (-not (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue))
    Remove-Item Env:\RIG_TEST_OWNS_SIM -ErrorAction SilentlyContinue
  }
  if ($markFile -and -not $markBefore) { Remove-Item -LiteralPath $markFile -Force -ErrorAction SilentlyContinue }   # the START mark this run made would make the guard wait 10 minutes for nothing
  # the test's own gallery copies go; iRacing's screenshot stays in its own folder
  foreach ($f in @(Get-ChildItem $gallery -Filter 'me-*' -ErrorAction SilentlyContinue | Where-Object { $galBefore -notcontains $_.Name })) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
}
}

}
finally {
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 5 } catch { }
  Start-Sleep -Milliseconds 400
  Remove-Item -LiteralPath $hook -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $env:TEMP 'replay-test-harness.html') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
  Exit-TestLock
  Remove-Item Env:\RIG_TEST_OWNS_SIM -ErrorAction SilentlyContinue
}
Check 'the test hook is switched off again' (-not (Test-Path $hook))
Check 'the deploy lock is released' (-not (Test-Path $lock))
Check 'the test folders inside replay\ are gone' (-not (Test-Path $testDir))
Check 'the test-hook route is closed again (404) so nothing can be recorded or pretended' ((Get-Code '/api/test/replaylog') -in 404, 409)
''
"$pass passed, $fail failed. Pictures in $shots (rp-*.png)"
