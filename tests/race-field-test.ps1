# W6 RACE FIELD (dash\src\field.cs, dash\www\v2\workbench-race.js, docs\DESIGN-workbench.md 2.5 and 3 "RACE"): Paddock's own log of every car in a session.
# The pretend race is a small simulation (tests\race-field-gen.cs): 20 cars in 2 classes, a standing start, 6 laps, a pit stop, an off-track, a retirement, passes, a
# lapped class, five cars with no LastLapTime, cars whose lap counter / LastLapTime run a sample late or early. It is played into irdash through the test hook
# (/api/test/frame, 10 samples a second of sim time, as fast as the sampler takes them) and every number the sampler logs is checked against the simulation:
#   laps, lap times (sim and derived), line crossings and every corner boundary of every lap (to 3 ms), positions and gaps by lap, the final order, pit in/out/lane/stall,
#   off-track, retirement, passes (cars, lap, time, corner), per-corner medians, the results text, the flush at every lap, the file on disk.
# Then: the sampler's CPU (real-time 10 Hz for 25 s, and idle), the endpoint (by field id and by a real .ibt's time window, 404 when there is none),
# and the RACE page headless (tab only with data, numbers, plates, charts, no overlaps, no JS errors; pictures tests\shots\wb-race*.png).
# Out of the car only (guard.ps1); irdash refuses the test hook with 409 while a real session is on. Needs the irdash built from field.cs (dash\build.ps1).
#   powershell -ExecutionPolicy Bypass -File tests\race-field-test.ps1 [-Keep] [-NoPage]
#   -Keep leaves vault-test\ (the race log) behind; -Reuse then skips sections 2 and 3 and checks that kept log (development: a page change needs no 90 s race).
param([switch]$Keep, [switch]$NoPage, [switch]$Reuse)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = if ($env:VAULT_TEST_API) { $env:VAULT_TEST_API } else { 'http://localhost:8199' }
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Note($what) { "  info  $what" }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
function Q($s) { [uri]::EscapeDataString($s) }
function Code($path) { try { return [int](Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 30).StatusCode } catch [Net.WebException] { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } return 0 } }
$wc = New-Object System.Net.WebClient
function Get-Text($path) { [Text.Encoding]::UTF8.GetString($wc.DownloadData("$api$path")) }
function J($path) { (Get-Text $path) | ConvertFrom-Json }
function Status() { J '/field/status' }
function Samples() { $s = Get-Text '/field/status'; if ($s -match '"samples":(\d+)') { [int]$Matches[1] } else { -1 } }

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; $title }
$me = Get-Process -Id $PID; $me.PriorityClass = 'BelowNormal'
$cores = [Environment]::ProcessorCount
if ($cores -gt 2) { $mask = [int64]0; for ($i = 0; $i -lt 2; $i++) { $mask = $mask -bor ([int64]1 -shl ($cores - 1 - $i)) }; $me.ProcessorAffinity = [IntPtr]$mask }

$hook = Join-Path $root 'dash\test-hook.on'; $lock = Join-Path $root 'dash\deploy.lock'
$tdir = Join-Path $root 'vault-test'; $fieldDir = Join-Path $tdir 'vault\field'
$tmp = Join-Path $env:TEMP ('race-field-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$pbName = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt'      # the file the other workbench tests use: 00:13:18 to 00:30:06 local on 2026-10-10
$otherName = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 15-34-11.ibt'
$raceClock = [long]([DateTimeOffset](Get-Date '2026-10-10 00:16:00')).ToUnixTimeMilliseconds()       # the pretend race "happened" inside the PB file's time window
$cpuClock = [long]([DateTimeOffset](Get-Date '2026-10-10 12:00:00')).ToUnixTimeMilliseconds()

# ---- the session text of the pretend race ----
$firsts = 'Alex', 'Bruno', 'Carla', 'Dmitri', 'Elena', 'Farid', 'Greta', 'Hugo', 'Iris', 'Jonas', 'Katya', 'Luca', 'Mara', 'Niko', 'Olga', 'Pavel', 'Quinn', 'Rosa', 'Sven', 'Tessa'
$lasts = 'Ferrante', 'Holm', 'Ibarra', 'Janssen', 'Kovac', 'Laurent', 'Moreau', 'Nowak', 'Okafor', 'Petrov', 'Quist', 'Rinaldi', 'Soto', 'Tanaka', 'Ueda', 'Varga', 'Weiss', 'Xu', 'Yilmaz', 'Zeman'
function Add-Pad($sb) {      # what a real session text carries besides the drivers: camera groups, radio channels
  [void]$sb.AppendLine('CameraInfo:'); [void]$sb.AppendLine(' Groups:')
  for ($g = 1; $g -le 60; $g++) { [void]$sb.AppendLine(" - GroupNum: $g"); [void]$sb.AppendLine("   GroupName: Pretend camera group $g"); [void]$sb.AppendLine('   Cameras:')
    for ($c = 1; $c -le 4; $c++) { [void]$sb.AppendLine("   - CameraNum: $c"); [void]$sb.AppendLine("     CameraName: Pretend camera $g.$c with a name long enough to be a real one") } }
  [void]$sb.AppendLine('RadioInfo:'); [void]$sb.AppendLine(' SelectedRadioNum: 0'); [void]$sb.AppendLine(' Radios:')
  for ($r = 0; $r -lt 40; $r++) { [void]$sb.AppendLine(" - RadioNum: $r"); [void]$sb.AppendLine('   HopCount: 2'); [void]$sb.AppendLine('   NumFrequencies: 3'); [void]$sb.AppendLine('   TunedToFrequencyNum: 0'); [void]$sb.AppendLine('   ScanningIsOn: 1') }
}
function New-SoloYaml() {      # Peter and the pace car: nothing to log
  $sb = New-Object Text.StringBuilder; $null = $sb.AppendLine('---'); $null = $sb.AppendLine('WeekendInfo:'); $null = $sb.AppendLine(' TrackName: roadatlanta full'); $null = $sb.AppendLine(' TrackID: 127'); $null = $sb.AppendLine(' SubSessionID: 77002')
  $null = $sb.AppendLine('SessionInfo:'); $null = $sb.AppendLine(' Sessions:'); $null = $sb.AppendLine(' - SessionNum: 2'); $null = $sb.AppendLine('   SessionType: Lone Practice'); $null = $sb.AppendLine('   SessionName: PRACTICE')
  Add-Pad $sb
  $null = $sb.AppendLine('DriverInfo:'); $null = $sb.AppendLine(' DriverCarIdx: 7'); $null = $sb.AppendLine(' Drivers:')
  foreach ($i in 7, 20) { $null = $sb.AppendLine(" - CarIdx: $i"); $null = $sb.AppendLine('   UserName: Peter Pretend'); $null = $sb.AppendLine('   CarNumber: "7"'); $null = $sb.AppendLine('   CarClassID: 4001'); $null = $sb.AppendLine('   CarIsPaceCar: ' + $(if ($i -eq 20) { 1 } else { 0 })); $null = $sb.AppendLine('   IsSpectator: 0') }
  $null = $sb.AppendLine('...'); return $sb.ToString()
}
# P4: each pretend driver has his own livery ("pattern,colour1,colour2,colour3" as iRacing writes it, capitals); car 11 has none (an old session text), car 3 has iRacing's unset placeholder
$pal = 'D4A017,111111,FFFFFF', '0A3D91,F2C230,FFFFFF', '2E7D32,FFFFFF,111111', 'E10600,FFFFFF,111111', 'F2C230,111111,FFFFFF', 'FF6A00,111111,FFFFFF', '7B1FA2,FFFFFF,F2C230', '00897B,111111,FFFFFF', 'C2185B,FFFFFF,111111', '455A64,F2C230,FFFFFF'
function Path-Of([int]$i) { if ($i -eq 9) { return 'ferrari296gt3' }; if ($i -eq 15) { return 'unknowncar99' }; if ($i -lt 12) { return 'bmwm4gt3' }; return 'bmwm4evogt4' }      # CP-1: car 15 has no picture on iRacing's server (shows none), car 9 is another car with one
function Design-Of([int]$i) { if ($i -eq 11) { return '' }; if ($i -eq 3) { return '1,FF0000,00FF00,0000FF' }; if ($i -eq 7) { return '17,391C83,111111,CCFF00' }; return ('{0},{1}' -f (1 + $i % 20), $pal[$i % $pal.Count]) }
function New-RaceYaml([bool]$results) {
  $sb = New-Object Text.StringBuilder
  function L($s) { [void]$sb.AppendLine($s) }
  L '---'; L 'WeekendInfo:'; L ' TrackName: roadatlanta full'; L ' TrackID: 127'; L ' TrackLength: 4.0569 km'; L ' TrackLengthOfficial: 4.09 km'; L ' TrackDisplayName: Road Atlanta'; L ' TrackConfigName: Full Course'
  L ' SubSessionID: 77001'; L ' Official: 0'
  L 'SessionInfo:'; L ' CurrentSessionNum: 2'; L ' Sessions:'
  L ' - SessionNum: 0'; L '   SessionLaps: unlimited'; L '   SessionTime: 600.0000 sec'; L '   SessionType: Practice'; L '   SessionName: PRACTICE'
  L ' - SessionNum: 1'; L '   SessionLaps: unlimited'; L '   SessionTime: 600.0000 sec'; L '   SessionType: Lone Qualify'; L '   SessionName: QUALIFY'; L '   ResultsPositions:'
  for ($i = 0; $i -lt 20; $i++) { L "   - Position: $($i + 1)"; L "     ClassPosition: $i"; L "     CarIdx: $i"; L '     Lap: 2'; L '     Time: 50.1'; L '     FastestLap: 2'; L '     FastestTime: 50.1'; L '     LastTime: 50.1'; L '     LapsLed: 0'; L '     LapsComplete: 2'; L '     Incidents: 99'; L '     ReasonOutId: 0'; L '     ReasonOutStr: Running' }
  L ' - SessionNum: 2'; L '   SessionLaps: 6'; L '   SessionTime: unlimited'; L '   SessionType: Race'; L '   SessionName: RACE'
  if ($results) {
    $order = [RaceGen]::FinalOrder(); L '   ResultsPositions:'
    $clsSeen = @{}
    foreach ($idx in $order) {
      $cls = [RaceGen]::ClassOf($idx); if (-not $clsSeen.ContainsKey($cls)) { $clsSeen[$cls] = 0 }; $cpos = $clsSeen[$cls]; $clsSeen[$cls] = $cpos + 1
      if ($idx -ge 10 -and $idx -ne 14) { continue }                  # the results text only knows some cars: the others must be worked out from the laps
      $b = [RaceGen]::BestSim($idx); $pos = [array]::IndexOf($order, $idx) + 1
      L "   - Position: $pos"; L "     ClassPosition: $cpos"; L "     CarIdx: $idx"; L "     Lap: $([int]$b[1])"; L '     Time: 0.0'; L "     FastestLap: $([int]$b[1])"; L ("     FastestTime: {0}" -f ([double]$b[0]).ToString('0.0000', [Globalization.CultureInfo]::InvariantCulture))
      L '     LastTime: 0.0'; L '     LapsLed: 0'; L "     LapsComplete: $([RaceGen]::Completed($idx))"; L ("     Incidents: {0}" -f $(if ($idx -eq 14) { 8 } else { $idx % 4 })); L '     ReasonOutId: 0'; L ("     ReasonOutStr: {0}" -f $(if ($idx -eq 14) { 'Disconnected' } else { 'Running' }))
    }
    L '   ResultsFastestLap:'; L '   - CarIdx: 0'; L '     FastestLap: 3'; L '     FastestTime: 41.0'
  }
  Add-Pad $sb
  L 'DriverInfo:'; L ' DriverCarIdx: 7'; L ' PaceCarIdx: 20'; L ' Drivers:'
  for ($i = 0; $i -lt 22; $i++) {
    $nm = if ($i -eq 7) { 'Peter Pretend' } else { "$($firsts[$i % 20]) $($lasts[$i % 20])" }
    $cls = if ($i -lt 12) { 4001 } else { 4002 }; $col = if ($i -lt 12) { '0xffda59' } else { '0x33ceff' }
    $team = if ($i -ge 12 -and $i -lt 20) { 'Team Cyan ' + ($i - 11) } else { $nm }
    L " - CarIdx: $i"; L "   UserName: $nm"; L '   AbbrevName: '; L "   TeamName: $team"; L "   CarNumber: `"$i`""; L "   CarNumberRaw: $i"
    L ('   CarPath: ' + (Path-Of $i)); $dz = Design-Of $i
    L ('   CarScreenName: ' + $(if ($i -lt 12) { 'Pretend GT3 Evo' } else { 'Pretend GT4' })); L ('   CarScreenNameShort: ' + $(if ($i -lt 12) { 'Pretend GT3' } else { 'Pretend GT4' }))
    if ($dz) { L "   CarDesignStr: $dz" }
    L "   CarClassID: $cls"; L ('   CarClassShortName: ' + $(if ($i -lt 12) { 'GT3' } else { '' })); L "   CarClassColor: $col"; L "   IRating: $(1800 + $i * 37)"; L '   LicString: A 4.12'
    L ('   CarIsPaceCar: ' + $(if ($i -eq 20) { 1 } else { 0 })); L ('   IsSpectator: ' + $(if ($i -eq 21) { 1 } else { 0 })); L '   CarIsAI: 1'
  }
  L '...'
  return $sb.ToString()
}
function Put-Yaml($name, $text) { [IO.File]::WriteAllText((Join-Path $tdir $name), $text, [Text.Encoding]::GetEncoding(28591)); $r = J "/api/test/fieldyaml?name=$name"; return $r.ok }

# ---- headless Chrome with the DevTools protocol (JS errors are collected) ----
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('race-test-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9377
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', 'about:blank') -PassThru -WindowStyle Hidden
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  if (-not $page) { throw 'headless Chrome did not start' }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0; errors = New-Object System.Collections.Generic.List[string] }
  $null = Cdp 'Page.enable' @{}
  $null = Cdp 'Runtime.enable' @{}
  $null = Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $w; height = $h; deviceScaleFactor = 1; mobile = $false }
  $null = Cdp 'Page.navigate' @{ url = $url }
}
function Cdp($method, $params) {
  $c = $script:cdp; $c.id++
  $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $c.id; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress))
  $null = $c.ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
  while ($true) {
    $buf = New-Object byte[] 262144; $sb = New-Object Text.StringBuilder
    do { $seg = New-Object ArraySegment[byte] -ArgumentList @(, $buf); $r = $c.ws.ReceiveAsync($seg, [Threading.CancellationToken]::None); $null = $r.Wait(); [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Result.Count)) } while (-not $r.Result.EndOfMessage)
    $o = $sb.ToString() | ConvertFrom-Json
    if ($o.method -eq 'Runtime.exceptionThrown') { $c.errors.Add([string]$o.params.exceptionDetails.exception.description) }
    if ($o.id -eq $c.id) { return $o }
  }
}
function Cdp-Eval($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return "js error: " + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
function Cdp-Obj($expr) { $v = Cdp-Eval "(async function(){ return JSON.stringify(await ($expr)); })()"; if ($v -is [string] -and $v.StartsWith('js error')) { throw $v }; return $v | ConvertFrom-Json }
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Cdp-Mouse($type, $x, $y) { $null = Cdp 'Input.dispatchMouseEvent' @{ type = $type; x = $x; y = $y; button = $(if ($type -eq 'mouseMoved') { 'none' } else { 'left' }); clickCount = $(if ($type -eq 'mouseMoved') { 0 } else { 1 }) } }
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 400
  try { [IO.Directory]::Delete($c.prof, $true) } catch { }
}
function Open-Wb($query) {
  $url = "$api/v2/workbench.html?$query"
  if (-not $script:cdp) { Cdp-Open $url } else { $null = Cdp-Eval 'window.__old = 1; 1'; $null = Cdp 'Page.navigate' @{ url = $url } }
  for ($i = 0; $i -lt 200; $i++) { Start-Sleep -Milliseconds 250; if ((Cdp-Eval '(!window.__old && window.WB && (WB.extras || WB.error)) ? 1 : 0') -eq 1) { break } }
  Start-Sleep -Milliseconds 700
}
function Pages() { return @(Cdp-Obj 'WB.pages()' | ForEach-Object { $_ }) }
function FmtLap([double]$t) { $m = [math]::Floor($t / 60); $s = $t - $m * 60; return ('{0}:{1}' -f $m, $s.ToString('00.000', [Globalization.CultureInfo]::InvariantCulture)) }
function Plus([double]$t) { return '+' + $t.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) }

$swAll = [Diagnostics.Stopwatch]::StartNew()
'Race field test'
$hookMade = $false; $lockMade = $false
Enter-TestLock 'race-field'   # one live test at a time (tests\guard.ps1); released in finally
try {
  for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock (' + (Get-Content $lock) + ')'; Start-Sleep -Seconds 60 }
  Set-Content $lock ('race-field ' + (Get-Date).ToString('HH:mm:ss')); $lockMade = $true
  Set-Content $hook 'race field test'; $hookMade = $true
  if (-not $Reuse) { if (Test-Path $tdir) { Remove-Item $tdir -Recurse -Force } }
  New-Item -ItemType Directory -Force $tdir | Out-Null

  # =====================================================================================================
  Section '1. set up: the scratch vault, the corner list and the pretend race'
  $st0 = $null; try { $st0 = Status } catch { }
  Check 'irdash answers /field/status (it is the build with dash\src\field.cs: deploy with dash\build.ps1 if not)' ($null -ne $st0)
  if ($null -eq $st0) { throw 'irdash has no /field/status: build and deploy first (dash\build.ps1)' }
  Check 'the sampler is idle: no session, no samples' ($st0.active -eq $false)
  $sb0 = J ("/vault/test/sandbox?on=1" + $(if ($Reuse) { '' } else { '&reset=1' }))
  Check 'the scratch vault is on (vault-test\vault): the race log is never written into Peter''s Vault' ($sb0.sandbox -eq $true -and $sb0.root -like '*vault-test*')
  $cn = J '/corners?track=roadatlanta%20full&config=Full%20Course&id=127'
  $turns = @($cn.turns)
  Check "the workbench's corner list for Road Atlanta (source $($cn.source)): $($turns.Count) corners" ($turns.Count -ge 10)
  $p0 = [double[]]@($turns | ForEach-Object { [double]$_.pct0 }); $p1 = [double[]]@($turns | ForEach-Object { [double]$_.pct1 })
  Add-Type -Path (Join-Path $PSScriptRoot 'race-field-gen.cs') -ReferencedAssemblies System.Web.Extensions
  $swg = [Diagnostics.Stopwatch]::StartNew(); [RaceGen]::Init($p0, $p1, 4056.9)
  $lastFrame = [RaceGen]::LastFrame()
  Note "the generator drove 20 cars for $([RaceGen]::Steps) steps in $([math]::Round($swg.Elapsed.TotalSeconds, 1)) s: green at $([RaceGen]::Tg) s, the leader's flag at $([math]::Round([RaceGen]::TF, 2)) s, the last car at $([math]::Round([RaceGen]::TLast, 2)) s, $($lastFrame + 1) samples"
  $san = [RaceGen]::Sanity()
  Check "the scene is clean (nobody ambiguous near the flag, 19 finishers)" ($san -eq '')
  if ($san -ne '') { Note $san }
  Check 'the session text (22 drivers: 20 racers, the pace car, a spectator; a qualifying block full of decoy results) is accepted by the test hook' (Put-Yaml 'race1.yaml' (New-RaceYaml $false))

  if (-not $Reuse) {
  # =====================================================================================================
  Section '2. the sampler''s cost: idle, and 25 s of a 20-car session at the real 10 samples a second'
  $r = J "/api/test/field?on=1&ms=$cpuClock&pump=16"
  Check 'the test hook lets the sampler log pretend sessions' ($r.on -eq $true)
  $a = Status; Start-Sleep -Seconds 4; $b = Status
  Check "idle (no session): the sampler's thread used $([math]::Round($b.cpuMs - $a.cpuMs, 2)) ms of CPU in 4 s" (($b.cpuMs - $a.cpuMs) -lt 20)
  [RaceGen]::ResetFrames()
  Check "the session text is as big as a real one ($([math]::Round((New-RaceYaml $false).Length / 1024)) KB: cameras and radios besides the drivers) and is accepted" (Put-Yaml 'race1.yaml' (New-RaceYaml $false))
  $a = Status; $swc = [Diagnostics.Stopwatch]::StartNew(); $nfr = 250
  for ($j = 0; $j -lt $nfr; $j++) {
    [void]$wc.DownloadString("$api/api/test/frame?$([RaceGen]::Frame($j))")
    $due = ($j + 1) * 100; $wait = $due - $swc.ElapsedMilliseconds; if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
  }
  $b = Status; $wall = $swc.Elapsed.TotalSeconds
  $dSamples = $b.samples - $a.samples; $dCpu = $b.cpuMs - $a.cpuMs; $dBusy = $b.busyMs - $a.busyMs
  Check "it took $dSamples samples in $([math]::Round($wall, 1)) s of a 20-car session (10 a second)" ($dSamples -ge 240 -and $dSamples -le 255)
  $pct = $dCpu / ($wall * 1000) * 100
  Check ("the sampler's thread used {0:N1} ms of CPU in {1:N1} s = {2:N2} % of one core with a frame every 16 ms like the sim (the first sample also found the corner list; the session text is read once); inside the loop {3:N3} ms per sample" -f $dCpu, $wall, $pct, ($dBusy / [math]::Max(1, $dSamples))) ($pct -lt 1.0)
  Check 'the sampler took the first sample of a session of 20 cars with the corner list' ($b.active -eq $true -and $b.cars -eq 20)
  [void](Get-Text '/api/test/end'); Start-Sleep -Milliseconds 800
  $e = Status
  Check 'the session ended: the sampler stopped, and wrote no file (not one lap was completed)' (($e.active -eq $false) -and (@(Get-ChildItem $fieldDir -ErrorAction SilentlyContinue).Count -eq 0))

  # a solo session (Peter and the pace car): not logged, and the sampler does not read the 40 KB session text on every frame while it waits
  Check 'a solo session text is accepted' (Put-Yaml 'solo.yaml' (New-SoloYaml))
  $a = Status; $swc = [Diagnostics.Stopwatch]::StartNew()
  for ($j = 0; $j -lt 80; $j++) { [void]$wc.DownloadString("$api/api/test/frame?SessionTime=$(20 + $j * 0.1)&SessionNum=2&CarIdxLapDistPct_7=0.5"); $due = ($j + 1) * 80; $wait = $due - $swc.ElapsedMilliseconds; if ($wait -gt 0) { Start-Sleep -Milliseconds $wait } }
  $b = Status; [void](Get-Text '/api/test/end'); Start-Sleep -Milliseconds 500
  Check ("a solo session: no cars logged (samples $($b.samples - $a.samples)), the sampler is not active, and it cost $([math]::Round($b.cpuMs - $a.cpuMs, 1)) ms of CPU in $([math]::Round($swc.Elapsed.TotalSeconds, 1)) s of 60 frames a second") (($b.samples - $a.samples) -eq 0 -and $b.active -eq $false -and ($b.cpuMs - $a.cpuMs) -lt 40)

  # =====================================================================================================
  Section '3. the pretend race: 6 laps, played as fast as the sampler takes it'
  $r = J "/api/test/field?on=1&ms=$raceClock&pump=8"
  [RaceGen]::ResetFrames()
  Check 'the session text is in again' (Put-Yaml 'race1.yaml' (New-RaceYaml $false))
  $a = Status; $base = [int]$a.samples; $stall = 0; $swr = [Diagnostics.Stopwatch]::StartNew(); $midDone = $false; $resDone = $false; $midInfo = $null
  $tLead2 = [RaceGen]::Xs(0)[1] + 4.0; $tResults = [RaceGen]::TF + 10.0
  for ($j = 0; $j -le $lastFrame; $j++) {
    [void]$wc.DownloadString("$api/api/test/frame?$([RaceGen]::Frame($j))")
    $want = $base + $j + 1; $t0 = [Environment]::TickCount
    while ($true) { $n = Samples; if ($n -ge $want) { break }; if ([Environment]::TickCount - $t0 -gt 3000) { $stall++; break }; Start-Sleep -Milliseconds 2 }
    if ($stall -gt 10) { throw "the sampler stopped taking samples at step $j" }
    $tj = [RaceGen]::TimeOf($j)
    if (-not $midDone -and $tj -ge $tLead2) {
      $midDone = $true; $stm = Status
      $fl = @(Get-ChildItem $fieldDir -Filter 'f*.json' -ErrorAction SilentlyContinue)
      $mj = $null; if ($fl.Count -eq 1) { try { $mj = Get-Content $fl[0].FullName -Raw | ConvertFrom-Json } catch { } }
      $midInfo = [pscustomobject]@{ flushes = $stm.flushes; files = $fl.Count; ok = ($null -ne $mj); complete = $(if ($mj) { $mj.complete } else { -1 }); cars = $(if ($mj) { @($mj.cars).Count } else { 0 }); laps = $(if ($mj) { (@($mj.cars | ForEach-Object { @($_.L).Count }) | Measure-Object -Maximum).Maximum } else { 0 }) }
    }
    if (-not $resDone -and $tj -ge $tResults) { $resDone = $true; [void](Put-Yaml 'race2.yaml' (New-RaceYaml $true)) }
  }
  Check "the whole race ($($lastFrame + 1) samples, 20 cars) went through in $([math]::Round($swr.Elapsed.TotalSeconds, 0)) s with no step the sampler missed" ($stall -eq 0)
  Check "the file is flushed at every lap and is complete JSON at that moment (what a crash would leave): after lap 1, $($midInfo.flushes) flush, 1 file, complete=$($midInfo.complete), $($midInfo.cars) cars, up to $($midInfo.laps) laps" ($midInfo.flushes -ge 1 -and $midInfo.files -eq 1 -and $midInfo.ok -and $midInfo.complete -eq 0 -and $midInfo.cars -eq 20 -and $midInfo.laps -ge 1)
  $stR = Status
  Note "sampler: $($stR.samples - $base) samples, $($stR.flushes) flushes, session text read $($stR.refreshes) times ($([math]::Round($stR.refreshMs, 1)) ms in all), inside the loop $([math]::Round($stR.busyMs / [math]::Max(1, $stR.samples), 3)) ms per sample (flushes and text included)"
  [void](Get-Text '/api/test/end'); $fin = $null
  for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 250; $fin = Status; if ($fin.finals -ge 1 -and $fin.active -eq $false) { break } }
  Check "the session ended: the final file was written ($($fin.lastFile))" ($fin.finals -eq 1 -and $fin.active -eq $false -and $fin.lastFile -match '^f\d{8}-\d{6}-2$')
  $id = [string]$fin.lastFile
  Check "the log is next to the scratch vault: vault-test\vault\field\$id.json" (Test-Path (Join-Path $fieldDir "$id.json"))
  $fileText = [IO.File]::ReadAllText((Join-Path $fieldDir "$id.json")); $fileObj = $fileText | ConvertFrom-Json
  Check ("the file is compact: {0:N0} KB for 20 cars x 6 laps with every corner time" -f ($fileText.Length / 1024)) ($fileText.Length -lt 450000)
  Check 'the file says it is complete, a race, session 2, with the greens and the flag' ($fileObj.complete -eq 1 -and $fileObj.isRace -eq 1 -and $fileObj.sessNum -eq 2 -and $null -ne $fileObj.greenT -and $null -ne $fileObj.flagT)
  Check 'the file has no NaN or Infinity anywhere (valid JSON)' ($fileText -notmatch 'NaN|Infinity')
  $okCorners = @($fileObj.corners).Count -eq $turns.Count; for ($k = 0; $k -lt $turns.Count -and $okCorners; $k++) { if (-not (Near $fileObj.corners[$k].p0 $turns[$k].pct0 0.0001) -or -not (Near $fileObj.corners[$k].p1 $turns[$k].pct1 0.0001) -or $fileObj.corners[$k].n -ne $turns[$k].n) { $okCorners = $false } }
  Check "the corners in the file are the workbench's own list (/corners: $($turns.Count) corners, source $($fileObj.cornerSrc))" ($okCorners -and $fileObj.cornerSrc -eq $cn.source)
  # P4: the livery of every car (iRacing's CarDesignStr, lower case) and its CarPath are in the log; a driver whose session text has no design gets an empty one
  $badLiv = @(); foreach ($c in @($fileObj.cars)) { $want = (Design-Of ([int]$c.i)).ToLowerInvariant(); $wp = Path-Of ([int]$c.i); if ([string]$c.dz -cne $want -or [string]$c.path -cne $wp) { $badLiv += "car $($c.i): '$($c.dz)' '$($c.path)' want '$want' '$wp'" } }
  Check "every one of the 20 cars has its livery (pattern and 3 colours, lower case) and its CarPath in the log; car 11's session text had none, so its livery is empty ($($badLiv -join '; '))" (@($fileObj.cars).Count -eq 20 -and $badLiv.Count -eq 0 -and [string](@($fileObj.cars | Where-Object { $_.i -eq 7 })[0].dz) -ceq '17,391c83,111111,ccff00' -and [string](@($fileObj.cars | Where-Object { $_.i -eq 11 })[0].dz) -eq '')

  } else {
  # -Reuse (development): play nothing, use the log the last -Keep run left in vault-test\vault\field
  $kept = @(Get-ChildItem $fieldDir -Filter 'f*.json' -ErrorAction SilentlyContinue)
  Check 'a kept race log is there to use (run once with -Keep)' ($kept.Count -ge 1)
  if ($kept.Count -lt 1) { throw 'no kept race log' }
  $id = $kept[0].BaseName; $fileText = [IO.File]::ReadAllText($kept[0].FullName); $fileObj = $fileText | ConvertFrom-Json
  }
  # =====================================================================================================
  Section '4. every number against the simulation'
  $rj = Get-Text "/analysis/race?id=$id&x=1"
  Check ("/analysis/race?id=<the field id> answers: {0:N0} KB with the raw corner times, no NaN" -f ($rj.Length / 1024)) ($rj.StartsWith('{"ok":true') -and $rj -notmatch 'NaN|Infinity')
  $rjSmall = Get-Text "/analysis/race?id=$id"
  Check ("without x=1 the raw corner times are left out ({0:N0} KB)" -f ($rjSmall.Length / 1024)) ($rjSmall.Length -lt $rj.Length * 0.8)
  $lines = [RaceGen]::Verify($rj)
  foreach ($l in $lines) { $k, $txt = $l -split '\|', 2; if ($k -eq 'ok') { $script:pass++; "  ok    $txt" } elseif ($k -eq 'FAIL') { $script:fail++; "  FAIL  $txt" } else { Note $txt } }
  $sm = ($rj | ConvertFrom-Json).summary
  Check 'the summary says what the page may claim: 10 samples a second, +-0.02 s on laps, corners and gaps, 0.1 s on the pit lane' ($sm.prec.hz -eq 10 -and $sm.prec.cornerS -eq 0.02 -and $sm.prec.lapS -eq 0.02 -and $sm.prec.pitS -eq 0.1)

  # =====================================================================================================
  Section '5. finding the log from a lap file, and the errors'
  $byFile = Get-Text "/analysis/race?id=$(Q $pbName)"
  $bf = $byFile | ConvertFrom-Json
  Check "a real telemetry file ($pbName) finds the race that ran inside its time window: the same field id" ($bf.ok -eq $true -and $bf.id -eq $id)
  Check "a telemetry file from another time has none: 404" ((Code "/analysis/race?id=$(Q $otherName)") -eq 404)
  Check 'a missing id is 400; an unknown file, a path and a made-up id are 404, never a file read' ((Code '/analysis/race') -eq 400 -and (Code "/analysis/race?id=$(Q 'nothing 2020-01-01 00-00-00.ibt')") -eq 404 -and (Code "/analysis/race?id=$(Q '..\..\dash\irdash.ini.ibt')") -eq 404 -and (Code '/analysis/race?id=f20200101-000000-2') -eq 404 -and (Code '/analysis/race?id=..%5C..%5Cirdash.ini') -eq 404)
  Remove-Item $hook -Force; $c404 = Code '/api/test/field?on=1'; $cst = Code '/field/status'; Set-Content $hook 'race field test'
  Check 'the test hook routes are shut (404) without dash\test-hook.on; /field/status still answers (200)' ($c404 -eq 404 -and $cst -eq 200)

  if (-not $NoPage) {
  # =====================================================================================================
  Section '6. the RACE page, headless Chrome 1920x1080 against the running irdash'
  Check 'Chrome is on this PC' (Test-Path $chrome)
  Check "the real telemetry file the lap is opened from is on this PC ($pbName)" (Test-Path (Join-Path $tel $pbName))
  $ep = $rj | ConvertFrom-Json; $tower = @($ep.summary.tower); $byI = @{}; foreach ($c in $ep.cars) { $byI[[int]$c.i] = $c }
  Open-Wb "id=$(Q $pbName)&lap=7&page=race"
  $err = Cdp-Eval 'WB.error || ""'
  Check "the workbench opened lap 7 of the real file with no error ($err)" ($err -eq '')
  $pg = Pages
  Check "RACE is a tab (the log was found by the lap file's time window), the page opened on it (page=race): tabs $($pg -join ' ')" (($pg -contains 'race') -and (Cdp-Obj 'WB.state.page') -eq 'race')
  Check 'the tab row shows RACE and the deck is told about the page (WB.pages())' (([string](Cdp-Eval 'document.getElementById("tabs").innerText')) -match 'RACE')
  Start-Sleep -Milliseconds 1200
  $ds = Invoke-RestMethod "$api/workbench/state" -TimeoutSec 8
  Check 'the deck gets the race page in its page list (/workbench/state)' (@($ds.pages) -contains 'race')
  $rc = Cdp-Obj 'WB.race()'
  $heads = @(Cdp-Obj '[].map.call(document.querySelectorAll("table.rt th"), function (c) { return c.textContent; })' | ForEach-Object { $_ })
  Check "the tower's columns: $($heads -join ' | ')" (($heads -join '|') -eq 'P|CLS|NO|DRIVER|CAR|TEAM|LAPS|TOTAL / GAP|AHEAD|BEST LAP|PITS|INC')
  $rows = @($rc.rows | Where-Object { $_.i -ge 0 })
  Check "the tower shows all 20 cars in the final order ($($rows.Count) rows)" ($rows.Count -eq 20 -and ((@($rows | ForEach-Object { $_.i }) -join ',') -eq (@($tower | ForEach-Object { $_.i }) -join ',')))
  $badRows = @()
  foreach ($r in $rows) {
    $tw = $tower | Where-Object { $_.i -eq $r.i }; $c = $byI[[int]$r.i]; $ce = @($r.cells); $bad = @()
    $col = [Convert]::ToInt32($c.col.Substring(1), 16); $want = "rgb($(($col -shr 16) -band 255), $(($col -shr 8) -band 255), $($col -band 255))"
    if ([int]$ce[0] -ne $tw.pos) { $bad += 'pos' }
    if ([int]$ce[1] -ne $tw.cpos) { $bad += 'class pos' }
    if ($r.plateText -ne [string]$c.num -or $r.plate -ne $want) { $bad += "plate $($r.plate)/$want" }
    if ($ce[3] -ne $c.name) { $bad += 'name' }
    if ($ce[4] -ne $c.car) { $bad += 'car' }
    if ($ce[5] -ne $(if ($c.team -ne $c.name) { $c.team } else { '' })) { $bad += 'team' }
    if ([int]$ce[6] -ne $tw.laps) { $bad += 'laps' }
    $wantGap = if ($tw.out) { 'OUT' } elseif ($tw.cpos -eq 1) { FmtLap $tw.total } elseif ($tw.gapLaps -gt 0) { "+$($tw.gapLaps) LAP" + $(if ($tw.gapLaps -gt 1) { 'S' } else { '' }) } else { Plus $tw.gap }
    if ($ce[7] -ne $wantGap) { $bad += "gap '$($ce[7])' want '$wantGap'" }
    $wantAh = if ($tw.cpos -eq 1) { '–' } elseif ($tw.aheadLaps -gt 0) { "+$($tw.aheadLaps) LAP" + $(if ($tw.aheadLaps -gt 1) { 'S' } else { '' }) } else { Plus $tw.ahead }
    if ($ce[8] -ne $wantAh) { $bad += "ahead '$($ce[8])' want '$wantAh'" }
    if ($ce[9] -ne (FmtLap $tw.best)) { $bad += 'best' }
    $wantPit = if ($tw.pits -gt 0) { "$($tw.pits) · $(([double]$tw.pitLane).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)) s" } else { '–' }
    if ($ce[10] -ne $wantPit) { $bad += "pits '$($ce[10])' want '$wantPit'" }
    if ($ce[11] -ne [string]$tw.inc) { $bad += 'incidents' }
    if ($bad.Count) { $badRows += "car $($r.i): $($bad -join ', ')" }
  }
  Check "every row of the tower equals the log: position, class position, plate in the class colour, driver, car, team, laps, total or gap, gap ahead, best lap, pits, incidents ($($badRows -join '; '))" ($badRows.Count -eq 0)
  # ---- CP-1: iRacing's own car pictures in the tower and the title line (the drawn cars stay off: cars.js CARS_DRAWN = false, window.PCars does not exist) ----
  for ($w = 0; $w -lt 40; $w++) { if ((Cdp-Eval '[].every.call(document.querySelectorAll(".cpic img"), function (i) { return i.complete; }) && document.querySelectorAll(".cpic img").length >= 19') -eq $true) { break }; Start-Sleep -Milliseconds 250 }
  $rc = Cdp-Obj 'WB.race()'
  $nc = Cdp-Obj '(function () {
    var o = { noW: 0, rows: 0, plates: 0, pics: 0, loaded: 0, sizes: [], bad: [], nopic: [], pcars: document.querySelectorAll("svg.pcar").length, api: typeof window.PCars, dormant: typeof window.PCarsDormant, chips: document.querySelectorAll(".rph .rpc").length, chipPics: 0, chipLoaded: 0, chipBad: [], head: document.querySelectorAll(".ph.rph2").length, over: 0, hs: [], broken: [].filter.call(document.querySelectorAll("img"), function (i) { return i.complete && i.naturalWidth === 0; }).length, pic: typeof window.PCarPic };
    [].forEach.call(document.querySelectorAll("table.rt th"), function (c) { if (c.textContent === "NO") o.noW = c.getBoundingClientRect().width; });
    [].forEach.call(document.querySelectorAll("table.rt tbody tr[data-i]"), function (tr) {
      var td = tr.querySelector("td.no"), pl = td.querySelector(".plate"), f = td.querySelector(".cpic"), i = +tr.getAttribute("data-i"), tr0 = tr.getBoundingClientRect(); o.rows++; if (pl) o.plates++; var hh = Math.round(tr0.height * 10) / 10; if (o.hs.indexOf(hh) < 0) o.hs.push(hh);
      if (!f) { o.nopic.push(i); return; }
      o.pics++; var im = f.querySelector("img"), r = f.getBoundingClientRect(), pr = pl.getBoundingClientRect(), t0 = td.getBoundingClientRect();
      if (im && im.complete && im.naturalWidth > 0) o.loaded++;
      var sz = Math.round(r.width * 10) + "x" + Math.round(r.height * 10); if (o.sizes.indexOf(sz) < 0) o.sizes.push(sz);
      if (r.left < pr.right + 4 || r.right > t0.right + 0.5 || r.top < tr0.top || r.bottom > tr0.bottom || Math.abs((r.top + r.bottom) / 2 - (tr0.top + tr0.bottom) / 2) > 2.5) o.bad.push(i + ": pic " + Math.round(r.left) + "-" + Math.round(r.right) + " plate to " + Math.round(pr.right) + " cell to " + Math.round(t0.right));
    });
    var ph = document.querySelector(".ph.rph2"), pr2 = ph ? ph.getBoundingClientRect() : null; if (ph) o.over = ph.scrollWidth - ph.clientWidth;
    [].forEach.call(document.querySelectorAll(".rph .rpc"), function (c) { var f = c.querySelector(".cpic"), im = f && f.querySelector("img"); if (f) { o.chipPics++; var r = f.getBoundingClientRect(); if (im && im.complete && im.naturalWidth > 0) o.chipLoaded++; if (pr2 && (r.top < pr2.top - 0.5 || r.bottom > pr2.bottom + 0.5)) o.chipBad.push("pic " + Math.round(r.top) + "-" + Math.round(r.bottom) + " title " + Math.round(pr2.top) + "-" + Math.round(pr2.bottom)); } });
    return o; })()'
  Check "no DRAWN car in the tower (svg.pcar $($nc.pcars), window.PCars is $($nc.api), the drawing code only dormant: $($nc.dormant)); the pictures are iRacing's own (carpics.js: $($nc.pic))" ($nc.api -eq 'undefined' -and $nc.dormant -eq 'object' -and $nc.pcars -eq 0 -and $nc.pic -eq 'object')
  Check "CP-1: $($nc.pics) of the 20 rows show iRacing's own picture of the car next to the number plate and every one is loaded ($($nc.loaded) with naturalWidth > 0, $($nc.broken) broken images); the car without a picture on iRacing's server (car $($nc.nopic -join ',')) shows only its plate" ($nc.rows -eq 20 -and $nc.plates -eq 20 -and $nc.pics -eq 19 -and $nc.loaded -eq 19 -and $nc.broken -eq 0 -and (($nc.nopic -join ',') -eq '15'))
  Check "the pictures are all one size ($($nc.sizes -join ' ')) in 0.1 px: 64 x 23.3), sit right of the plate inside their cell and inside their row, centred on it, and no row grew ($($nc.hs -join ',') px high) ($($nc.bad -join '; '))" ($nc.sizes.Count -eq 1 -and $nc.sizes[0] -eq '640x233' -and $nc.bad.Count -eq 0 -and $nc.hs.Count -eq 1)
  Check "the NO column is wide enough for plate and picture, and no wider ($([math]::Round($nc.noW)) px)" ($nc.noW -ge 124 -and $nc.noW -le 140)
  Check "the title line has the two chips WINNER and PETER, each with the car's picture loaded ($($nc.chipLoaded) of $($nc.chipPics)), inside the line ($($nc.chipBad -join '; ')), nothing pushed out of it ($($nc.over) px), WB.race().hero has $(@($rc.hero).Count)" ($nc.chips -eq 2 -and $nc.chipPics -eq 2 -and $nc.chipLoaded -eq 2 -and $nc.chipBad.Count -eq 0 -and $nc.head -eq 1 -and $nc.over -le 1 -and @($rc.hero).Count -eq 2 -and @($rc.hero | Where-Object { $_.pic -and $_.pic.nat -eq 480 }).Count -eq 2)
  $heroTxt = @($rc.hero | ForEach-Object { $_.text })
  Check "the chips read WINNER #0 Ferrante and PETER P8 ($($heroTxt -join ' | '))" ($heroTxt.Count -eq 2 -and $heroTxt[0] -like 'WINNER*#0*Ferrante*' -and $heroTxt[1] -like 'PETER*P8*')
  Cdp-Shot (Join-Path $shots 'cars-race.png')
  # PL-1 (dormant code): which silhouette each car would get: the car's folder name, then its screen name, then its class; a road car when nothing matches
  $mapRows = @(
    @('chevyvettez06rgt3', 'Chevrolet Corvette Z06 GT3.R', 'gt3'), @('bmwm4gt3', 'BMW M4 GT3 EVO', 'gt3'), @('ferrari296gt3', 'Ferrari 296 GT3', 'gt3'), @('fordmustanggt3', 'Ford Mustang GT3', 'gt3'), @('porsche991rsr', 'Porsche 911 RSR', 'gt3'),
    @('porsche9922cup', 'Porsche 911 GT3 Cup (992)', 'gt3'), @('ferrari296challenge', 'Ferrari 296 Challenge', 'gt3'), @('mercedesamgevogt3', 'Mercedes-AMG GT3 2020', 'gt3'), @('lamborghinihuracangt3evo', 'Lamborghini Huracan GT3 EVO', 'gt3'),
    @('bmwm4evogt4', 'BMW M4 G82 GT4 EVO', 'gt4'), @('mercedesamggt4', 'Mercedes-AMG GT4', 'gt4'),
    @('toyotagr86', 'Toyota GR86', 'road'), @('bmwm2g87', 'BMW M2 CSR', 'road'), @('mx5 mx52016', 'Global Mazda MX-5 Cup', 'road'), @('hyundaielantracn7', 'Hyundai Elantra N TCR', 'road'), @('subaruwrxsti', 'Subaru WRX STI', 'road'),
    @('cadillacvseriesrgtp', 'Cadillac V-Series.R', 'gtp'), @('porsche963gtp', 'Porsche 963 GTP', 'gtp'), @('bmwlmdh', 'BMW M Hybrid V8', 'gtp'), @('acuraarx06gtp', 'Acura ARX-06 GTP', 'gtp'), @('ferrari499p', 'Ferrari 499P', 'gtp'),
    @('dallarap217', 'Dallara P217 LMP2', 'lmp'), @('ligierjsp320', 'Ligier JS P320', 'lmp'),
    @('dallaradw12', 'Dallara DW12 IndyCar', 'formula'), @('dallarair18', 'Dallara IR-18', 'formula'), @('superformulalights324', 'Super Formula Lights', 'formula'), @('formulavee', 'Formula Vee', 'formula'), @('mclarenmp430', 'McLaren MP4-30', 'formula'), @('rayff1600', 'Ray FF1600', 'formula'), @('usf2000', 'USF 2000', 'formula'),
    @('stockcars2chevycamaro', 'NASCAR Cup Series Next Gen Chevrolet Camaro ZL1', 'stock'), @('trucksilverado', 'NASCAR Craftsman Truck Series Chevrolet Silverado', 'stock'), @('arcaford', 'ARCA Menards Ford Mustang', 'stock'),
    @('', '', 'road'), @('unknowncar', 'Totally Unknown Car', 'road'))
  $mapJs = '[' + (($mapRows | ForEach-Object { "['$($_[0])','$($_[1])']" }) -join ',') + ']'
  $got = @(Cdp-Obj "$mapJs.map(function (x) { return PCarsDormant.type(x[0], x[1], ''); })" | ForEach-Object { $_ })
  $badMap = @(); for ($k = 0; $k -lt $mapRows.Count; $k++) { if ($got[$k] -ne $mapRows[$k][2]) { $badMap += "$($mapRows[$k][0]) / $($mapRows[$k][1]) -> $($got[$k]) (want $($mapRows[$k][2]))" } }
  Check "$($mapRows.Count) iRacing cars (his own 6 included) get the right silhouette: GT3, GT4, GTP, prototype, open-wheel, stock car, touring / road car; the class name is the last resort and an unknown car is a road car ($($badMap -join '; '))" ($badMap.Count -eq 0 -and $got.Count -eq $mapRows.Count -and (Cdp-Eval 'PCarsDormant.type("", "", "GT3 Class")') -eq 'gt3' -and (Cdp-Eval 'PCarsDormant.type("", "", "")') -eq 'road')
  $pr = Cdp-Obj '[PCarsDormant.parse("17,391C83,111111,CCFF00", "#ffffff"), PCarsDormant.parse("1,FF0000,00FF00,0000FF", "#ffda59"), PCarsDormant.parse("", "#33ceff"), PCarsDormant.parse("5,zzzzzz,1,2", "#33ceff"), PCarsDormant.parse("3,0A3D91", "#ffffff")]'
  Check "the livery is read as iRacing writes it: 17,391C83,111111,CCFF00 gives body #391c83, stripe #111111, accent #ccff00; iRacing's unset red-green-blue placeholder, an empty text and rubbish give the class colour and no stripes; a design with one colour has no stripes" (($pr[0].c1 -eq '#391c83' -and $pr[0].c2 -eq '#111111' -and $pr[0].c3 -eq '#ccff00' -and $pr[0].pat -eq 17 -and $pr[0].real) -and ($pr[1].c1 -eq '#ffda59' -and -not $pr[1].real -and -not $pr[1].c2) -and ($pr[2].c1 -eq '#33ceff' -and -not $pr[2].real) -and ($pr[3].c1 -eq '#33ceff' -and -not $pr[3].real) -and ($pr[4].c1 -eq '#0a3d91' -and $pr[4].real -and -not $pr[4].c2))
  $fast = [string](Cdp-Eval '[].map.call(document.querySelectorAll("table.rt td.best .gain"), function (c) { return c.textContent; }).join("|")')
  Check "only the quickest lap of the session is green in the best lap column ($fast)" ($fast -eq (FmtLap (($tower | Where-Object { $_.fastest })[0].best)))
  $me7 = $rows | Where-Object { $_.i -eq 7 }
  Check "Peter's row is the gold one" ($me7.cls -eq 'me' -and @($rows | Where-Object { $_.cls -eq 'me' }).Count -eq 1)
  Check 'the winner and the leader of the other class show their total race time, the car one lap down (9, after its stop) shows +1 LAP, the retired car shows OUT' ((@($rows | Where-Object { $_.i -eq 0 })[0].cells[7] -eq (FmtLap $tower[0].total)) -and (@($rows | Where-Object { $_.i -eq 12 })[0].cells[7] -eq (FmtLap (@($tower | Where-Object { $_.i -eq 12 })[0].total))) -and (@($rows | Where-Object { $_.i -eq 9 })[0].cells[7] -eq '+1 LAP') -and (@($rows | Where-Object { $_.i -eq 14 })[0].cells[7] -eq 'OUT'))
  # layout
  $lay = Cdp-Obj '(function () { var ps = [].slice.call(document.querySelectorAll(".panel")), rs = ps.map(function (p) { return p.getBoundingClientRect(); }), bad = []; ps.forEach(function (p, i) { var r = rs[i]; if (r.right > 1920.5 || r.bottom > 1064 || r.left < 0 || r.top < 0) bad.push("outside " + p.querySelector(".ph").textContent.substring(0, 20) + " " + Math.round(r.right) + "," + Math.round(r.bottom)); for (var j = i + 1; j < ps.length; j++) { var q = rs[j]; if (r.left < q.right - 1 && q.left < r.right - 1 && r.top < q.bottom - 1 && q.top < r.bottom - 1) bad.push("overlap " + i + "/" + j); } }); return { n: ps.length, bad: bad }; })()'
  Check "the 5 panels (tower, race trace, positions, passes, comparison) are inside the screen and do not overlap ($($lay.bad -join '; '))" ($lay.n -eq 5 -and $lay.bad.Count -eq 0)
  $ov = Cdp-Obj 'WB.overlaps()'
  Check "no text overlaps any other text, canvas or DOM ($($ov.boxes) boxes measured$(if ($ov.bad.Count) { ': ' + ($ov.bad -join ' ; ') }))" ($ov.boxes -gt 150 -and $ov.bad.Count -eq 0)
  $fs = Cdp-Obj '(function () { var m = 99; [].forEach.call(document.querySelectorAll("table.rt td, table.rc td, .pz, .tnote"), function (e) { m = Math.min(m, parseFloat(getComputedStyle(e).fontSize)); }); return m; })()'
  Check "the smallest table or note text is $fs px (14 px or more, readable from the seat)" ($fs -ge 14)
  # the charts
  $lines = Cdp-Obj "WB.raceLines('trace')"; $linesP = Cdp-Obj "WB.raceLines('pos')"
  Check "the race trace draws a line for each of the 12 cars of Peter's class; the positions chart too ($($lines.n) / $($linesP.n))" ($lines.n -eq 12 -and $linesP.n -eq 12)
  $pt = Cdp-Obj "WB.racePoint('trace', 7, 6)"; $ptA = Cdp-Obj "WB.racePoint('trace', 8, 6)"; $ptG = Cdp-Obj "WB.racePoint('trace', 3, 5)"; $pp = Cdp-Obj "WB.racePoint('pos', 7, 6)"
  $gold = { param($p) $p.rgba[0] -gt 200 -and $p.rgba[1] -gt 150 -and $p.rgba[1] -lt 235 -and $p.rgba[2] -lt 110 -and $p.rgba[3] -gt 200 }
  $white = { param($p) $p.rgba[0] -gt 170 -and $p.rgba[1] -gt 170 -and $p.rgba[2] -gt 170 -and $p.rgba[3] -gt 150 }
  $grey = { param($p) $p.rgba[0] -ge 35 -and $p.rgba[0] -lt 120 -and [math]::Abs($p.rgba[0] - $p.rgba[2]) -lt 30 -and $p.rgba[3] -gt 100 }
  Check "Peter's line is gold at the end of lap 6 in the race trace (rgb $($pt.rgba[0..2] -join ','))" (& $gold $pt)
  Check "the car ahead (#8) is cool white there, and another car is thin grey (rgb $($ptA.rgba[0..2] -join ',') / $($ptG.rgba[0..2] -join ','))" ((& $white $ptA) -and (& $grey $ptG))
  Check "Peter is gold in the positions chart too (rgb $($pp.rgba[0..2] -join ','))" (& $gold $pp)
  $trSeries = @($ep.summary.trace | Where-Object { $_.i -eq 7 })[0]; $ptY = Cdp-Obj "WB.racePoint('trace', 7, 3)"
  $g3 = $lines.geom; $expY = 10 + [double]$trSeries.g[2] / [double]$g3.ymax * $g3.H
  Check "Peter's point on lap 3 is where his gap says: $([math]::Round([double]$trSeries.g[2], 3)) s -> y $([math]::Round($expY, 1)) (page $([math]::Round($ptY.y, 1)))" ([math]::Abs($ptY.y - $expY) -lt 1.0)
  # the comparison table
  $cmp = @($rc.cmp)
  $nc = @($rc.heads).Count - 4
  Check "the comparison has a row for Peter, the car ahead and the leader, and a column for each of the $nc corners plus BEST, LAP and REST" ($cmp.Count -eq 3 -and $nc -eq @($ep.corners).Count -and $cmp[0].cells[0].t -match 'PETER' -and $cmp[1].cells[0].t -match 'AHEAD' -and $cmp[2].cells[0].t -match 'LEADER')
  $tm7 = [RaceGen]::Medians(7); $badCmp = @(); $maxD = 0
  function Num($s) { $s = ($s -replace '−', '-' -replace '±', '' -replace '\+', ''); [double]::Parse($s, [Globalization.CultureInfo]::InvariantCulture) }
  foreach ($pair in @(@(1, 8), @(2, 0))) {
    $row = $cmp[$pair[0]]; $tmo = [RaceGen]::Medians($pair[1]); $sum = 0
    for ($k = 0; $k -lt $nc; $k++) {
      $cell = $row.cells[1 + $k]; $want = $tmo[2 + $k] - $tm7[2 + $k]; $sum += $want; $got = Num $cell.t; $maxD = [math]::Max($maxD, [math]::Abs($got - $want))
      $wcls = if ([math]::Abs($want) -lt 0.0145) { 'mute' } elseif ($want -gt 0.0255) { 'gain' } elseif ($want -lt -0.0255) { 'loss' } else { $null }       # grey inside the +-0.02 s the data is good to, green / red outside it (a band between is not judged)
      if ([math]::Abs($got - $want) -gt 0.0075 -or ($wcls -and $cell.c -ne $wcls)) { $badCmp += "car $($pair[1]) corner $($k + 1): '$($cell.t)' want $([math]::Round($want, 3))" }
    }
    $lapD = $tmo[1] - $tm7[1]; $got = Num $row.cells[2 + $nc].t; $rest = Num $row.cells[3 + $nc].t
    if ([math]::Abs($got - $lapD) -gt 0.0075) { $badCmp += "car $($pair[1]) lap: '$($row.cells[2 + $nc].t)' want $([math]::Round($lapD, 3))" }
    if ([math]::Abs($rest - ($lapD - $sum)) -gt 0.012) { $badCmp += "car $($pair[1]) rest: '$($row.cells[3 + $nc].t)' want $([math]::Round($lapD - $sum, 3))" }
    $bestD = [double](@($tower | Where-Object { $_.i -eq $pair[1] })[0].best) - [double](@($tower | Where-Object { $_.i -eq 7 })[0].best); $gotB = Num $row.cells[1 + $nc].t
    if ([math]::Abs($gotB - $bestD) -gt 0.0075) { $badCmp += "car $($pair[1]) best: '$($row.cells[1 + $nc].t)' want $([math]::Round($bestD, 3))" }
  }
  Check "every number in the comparison (Peter vs car 8 ahead and vs car 0 the leader: $nc corners, the best lap, the median lap, the rest) is the generator's own medians' difference, within 7 ms of the 2-decimal text (worst $([math]::Round($maxD * 1000, 1)) ms); green when Peter is quicker, red when slower $($badCmp -join '; ')" ($badCmp.Count -eq 0)
  Check "his own row shows his median corner times, his best lap ($($cmp[0].cells[1 + $nc].t)) and his median lap ($($cmp[0].cells[2 + $nc].t))" ((Num $cmp[0].cells[1].t) -gt 0 -and [math]::Abs((Num ($cmp[0].cells[1].t)) - $tm7[2]) -lt 0.001 -and $cmp[0].cells[2 + $nc].t -eq (FmtLap $tm7[1]) -and $cmp[0].cells[1 + $nc].t -eq (FmtLap (@($tower | Where-Object { $_.i -eq 7 })[0].best)))
  $note = [string](Cdp-Eval 'document.querySelector("table.rc + .tnote").textContent')
  Check 'the page keeps the grey threshold (0.02 s) and the REST key, and does not explain how the numbers are measured (that is in docs)' ($note -match '0\.02' -and $note -match 'REST' -and $note -notmatch 'sampled|interpolated')
  # passes
  $mine = @($ep.summary.passes | Where-Object { $_.by -eq 7 -or $_.over -eq 7 })
  $pz = @($rc.passes)
  $okPz = ($pz.Count -eq [math]::Min(5, $mine.Count)) -and $mine.Count -gt 2
  for ($k = 0; $k -lt $pz.Count -and $okPz; $k++) {
    $p = $mine[$k]; $made = $p.by -eq 7; $other = if ($made) { $p.over } else { $p.by }; $txt = [string]$pz[$k].t
    if ($txt -notmatch "LAP $($p.lap)\b" -or $txt -notmatch [regex]::Escape($p.where) -or $txt -notmatch $(if ($made) { 'PASSED #' } else { 'PASSED BY #' }) -or $txt -notmatch [regex]::Escape($byI[[int]$other].name)) { $okPz = $false; Note "passes row $k : '$txt' vs $($p | ConvertTo-Json -Compress)" }
  }
  Check "the passes list has Peter's $($mine.Count) passes (made and lost) with lap, corner and who, in time order ($($pz.Count) rows)" $okPz
  Check 'P2: every pass row carries its SEE IN iRACING button, hidden while the sim has no such session open (no dead buttons; the replay-jump test presses one)' ([int](Cdp-Eval 'document.querySelectorAll(".pz .sj").length') -eq $pz.Count -and (Cdp-Eval 'getComputedStyle(document.querySelector(".pz .sj")).display') -eq 'none')
  $tr7 = @($ep.summary.trace | Where-Object { $_.i -eq 7 })[0]
  # a click on a tower row chooses that car: it turns white in both charts and gets its own row in the comparison
  $pos5 = Cdp-Obj '(function () { var r = document.querySelector("table.rt tbody tr[data-i=\"5\"]").getBoundingClientRect(); return { x: r.left + 260, y: r.top + r.height / 2 }; })()'
  Cdp-Mouse 'mouseMoved' $pos5.x $pos5.y; Cdp-Mouse 'mousePressed' $pos5.x $pos5.y; Cdp-Mouse 'mouseReleased' $pos5.x $pos5.y; Start-Sleep -Milliseconds 500
  $rc2 = Cdp-Obj 'WB.race()'; $p5 = Cdp-Obj "WB.racePoint('trace', 5, 4)"
  Check "a click on car 5's row chooses it: its row is marked, the comparison gets a CHOSEN row ($(@($rc2.cmp).Count) rows) and its line is white in the race trace (rgb $($p5.rgba[0..2] -join ','))" ($rc2.sel -eq 5 -and (@($rc2.rows | Where-Object { $_.i -eq 5 })[0].cls -eq 'sel') -and @($rc2.cmp).Count -eq 4 -and @($rc2.cmp)[3].cells[0].t -match 'CHOSEN' -and (& $white $p5))
  # hover on the race trace: the lap, Peter's place and gap
  $gm = (Cdp-Obj "WB.raceLines('trace')").geom; $hx = 1200 + $gm.l + (3 / 5) * $gm.W; $hy = 146 + $gm.t + 60
  Cdp-Mouse 'mouseMoved' ($hx - 30) $hy; Cdp-Mouse 'mouseMoved' $hx $hy; Start-Sleep -Milliseconds 400
  $tb = @(Cdp-Obj 'WB.textBoxes().map(function (b) { return b.s; })' | ForEach-Object { $_ })
  $gap4 = [double]$tr7.g[3]; $wantTxt = if ($gap4 -eq 0) { 'LAP 4 · LEADING' } else { 'LAP 4 · +' + $gap4.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) + ' s' }
  Check "hovering lap 4 of the race trace shows Peter's gap there: '$wantTxt'" ($tb -contains $wantTxt)
  if (-not ($tb -contains $wantTxt)) { Note ("readout boxes: " + ((@($tb | Where-Object { $_ -like 'LAP*' })) -join ' | ')) }
  $ov2 = Cdp-Obj 'WB.overlaps()'
  Check "still no overlapping text with a car chosen and the lap readout on ($($ov2.boxes) boxes$(if ($ov2.bad.Count) { ': ' + ($ov2.bad -join ' ; ') }))" ($ov2.boxes -gt 150 -and $ov2.bad.Count -eq 0)
  Cdp-Shot (Join-Path $shots 'wb-race-2.png')
  Cdp-Mouse 'mouseMoved' 600 600
  Cdp-Mouse 'mouseMoved' $pos5.x $pos5.y; Cdp-Mouse 'mousePressed' $pos5.x $pos5.y; Cdp-Mouse 'mouseReleased' $pos5.x $pos5.y; Start-Sleep -Milliseconds 300
  Check 'a second click on the same row lets go of it; a click on Peter''s own row chooses nothing' ((Cdp-Obj 'WB.race()').sel -eq $null)
  Cdp-Mouse 'mouseMoved' 20 600; Start-Sleep -Milliseconds 300
  Cdp-Shot (Join-Path $shots 'wb-race.png')
  Check 'no JavaScript error on the page' ($script:cdp.errors.Count -eq 0)
  if ($script:cdp.errors.Count) { Note ($script:cdp.errors -join ' | ') }
  # with a clip too there are 8 tabs (DRIVER ... VIDEO, RACE): the header must still hold the chips, the mode words and the lap times
  $careerTab = [int]([bool](Cdp-Eval 'WB.pages().indexOf("career") >= 0'))      # W6c: the CAREER tab is there when this car and track have 2 or more sessions (the real telemetry has)
  $careerTab += [int]([bool](Cdp-Eval 'WB.pages().indexOf("pro") >= 0'))         # P3: and the PRO tab whenever the server has the pro routes
  $null = Cdp-Eval 'WBX.add({ id: "fake8", name: "VIDEO", avail: function () { return true; }, build: function () {} }); WB.cmd("page", "race"); 1'
  Start-Sleep -Milliseconds 500
  $hd = Cdp-Obj '(function () { var q = function (s) { var e = document.querySelector(s); if (!e) return null; var r = e.getBoundingClientRect(); return { l: r.left, r: r.right, t: r.top, b: r.bottom, w: r.width, scroll: e.scrollWidth }; }; return { tabs: q("#tabs"), add: q("#addch"), pip: q("#pipbtn"), mode: q("#mode"), vs: q("#vs"), n: document.querySelectorAll("#tabs span").length, lead: [].reduce.call(document.querySelectorAll(".top > *"), function (m, e) { return e.id === "vs" || e.id === "mode" || getComputedStyle(e).display === "none" ? m : Math.max(m, e.getBoundingClientRect().right); }, 0), modeBelow: q("#mode").t >= q("#tabs").b - 1 }; })()'
  Check "with $($hd.n) tabs the header still fits: the tabs end at $([math]::Round($hd.tabs.r)), the tabs and chips end at $([math]::Round($hd.lead)), the lap times start at $([math]::Round($hd.vs.l)) and end at $([math]::Round($hd.vs.r)); $([math]::Round($hd.mode.w)) px are left for the SMALL VIDEO chip (about 140) and the mode words (the chip is hidden here: no clip)" ($hd.n -eq (8 + $careerTab) -and $hd.lead -le $hd.vs.l + 1 -and $hd.vs.r -le 1889 -and $hd.mode.w -ge 240)
  Cdp-Shot (Join-Path $shots 'wb-race-tabs8.png')

  # =====================================================================================================
  Section '7. no data, no tab: and a field of 45 cars'
  $moved = Join-Path $tmp "$id.json"; Move-Item (Join-Path $fieldDir "$id.json") $moved
  Open-Wb "id=$(Q $pbName)&lap=7&page=race"
  $pg2 = Pages
  Check "the session has no race log (file moved away): no RACE tab, asking for page=race stays on the page it was on ($($pg2 -join ' '))" (($pg2 -notcontains 'race') -and ([string](Cdp-Eval 'document.getElementById("tabs").innerText')) -notmatch 'RACE' -and (Cdp-Obj 'WB.state.page') -eq 'driver')
  Check 'and the other pages are still there' (($pg2 -contains 'driver') -and ($pg2 -contains 'grip'))
  Move-Item $moved (Join-Path $fieldDir "$id.json")
  Open-Wb "id=$(Q $pbName)&lap=7&page=race"
  Check 'the log is back: the RACE tab is too' ((Pages) -contains 'race')
  # an old log (nothing about liveries or CarPath in it) opens like any other: the plates stay, no car is drawn
  $epOld = $ep | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json
  foreach ($c in $epOld.cars) { $c.PSObject.Properties.Remove('dz'); $c.PSObject.Properties.Remove('path') }
  $okOld = Cdp-Eval ("WB.raceLoad(" + ($epOld | ConvertTo-Json -Depth 12 -Compress) + ")")
  Start-Sleep -Milliseconds 800
  $rcOld = Cdp-Obj 'WB.race()'; $nOld = @($rcOld.rows | Where-Object { $_.i -ge 0 }).Count; $plOld = [int](Cdp-Eval 'document.querySelectorAll("table.rt td.no .plate").length'); $strOld = [int](Cdp-Eval 'document.querySelectorAll("svg.pcar, .cpic").length'); $noOld = [double](Cdp-Eval '[].filter.call(document.querySelectorAll("table.rt th"), function (c) { return c.textContent === "NO"; })[0].getBoundingClientRect().width')
  Check "a log from before the liveries (no CarPath in it) opens the same way: all $nOld rows with their number plates ($plOld), no car picture and no empty frame ($strOld), the NO column as narrow as without pictures ($([math]::Round($noOld)) px)" ($okOld -eq $true -and $nOld -eq 20 -and $plOld -eq 20 -and $strOld -eq 0 -and $noOld -le 72)
  # a 45-car field: the tower shows the top eight, the cars around Peter and says how many it left out
  $orig = @($ep.summary.tower); $newT = New-Object System.Collections.ArrayList; $newC = New-Object System.Collections.ArrayList
  for ($k = 0; $k -lt 7; $k++) { [void]$newT.Add($orig[$k]) }
  for ($k = 0; $k -lt 25; $k++) {
    $tw = $orig[1] | ConvertTo-Json -Depth 6 | ConvertFrom-Json; $tw.i = 100 + $k; [void]$newT.Add($tw)
    $cc = $byI[[int]$orig[1].i] | ConvertTo-Json -Depth 8 | ConvertFrom-Json; $cc.i = 100 + $k; $cc.num = [string](100 + $k); $cc.name = "Clone Driver $($k + 1)"; $cc.me = 0; [void]$newC.Add($cc)
  }
  for ($k = 7; $k -lt 20; $k++) { [void]$newT.Add($orig[$k]) }
  $clsOf = @{}; foreach ($c in $ep.cars) { $clsOf[[int]$c.i] = [string]$c.cls }; for ($k = 0; $k -lt 25; $k++) { $clsOf[100 + $k] = [string]$byI[[int]$orig[1].i].cls }
  $cpos = @{}; for ($k = 0; $k -lt $newT.Count; $k++) { $cl = $clsOf[[int]$newT[$k].i]; $newT[$k].pos = $k + 1; if (-not $cpos.ContainsKey($cl)) { $cpos[$cl] = 0 }; $cpos[$cl]++; $newT[$k].cpos = $cpos[$cl] }
  $ep2 = $ep | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json; $ep2.summary.tower = @($newT); $ep2.cars = @($ep2.cars) + @($newC)
  $okLoad = Cdp-Eval ("WB.raceLoad(" + ($ep2 | ConvertTo-Json -Depth 12 -Compress) + ")")
  Start-Sleep -Milliseconds 800
  $rc3 = Cdp-Obj 'WB.race()'; $vis = @($rc3.rows)
  $skips = @($vis | Where-Object { $_.i -lt 0 }); $cars3 = @($vis | Where-Object { $_.i -ge 0 })
  Check "a 45-car field fits: $($vis.Count) rows ($($cars3.Count) cars and $($skips.Count) 'more cars' rows), the first is P1, Peter's row is there and gold, rows are $([math]::Round($vis[0].h)) px high" ($okLoad -eq $true -and $vis.Count -le 24 -and $cars3.Count -ge 18 -and $skips.Count -ge 1 -and $cars3[0].cells[0] -eq '1' -and @($cars3 | Where-Object { $_.i -eq 7 }).Count -eq 1 -and $vis[0].h -ge 26)
  Check "the skipped stretch says how many cars it leaves out ($($skips[0].cells[0]))" ($skips[0].cells[0] -match '^\d+ more cars$' -and (($skips | ForEach-Object { [int](($_.cells[0] -split ' ')[0]) } | Measure-Object -Sum).Sum + $cars3.Count) -eq 45)
  $tb3 = $rc3.tower
  Check "the tower stays above the comparison table (bottom $([math]::Round($tb3.y + $tb3.h)) px, the table starts at 868)" (($tb3.y + $tb3.h) -le 866)
  $ov3 = Cdp-Obj 'WB.overlaps()'
  Check "no overlapping text with 45 cars ($($ov3.boxes) boxes$(if ($ov3.bad.Count) { ': ' + ($ov3.bad -join ' ; ') }))" ($ov3.boxes -gt 150 -and $ov3.bad.Count -eq 0)
  Cdp-Shot (Join-Path $shots 'wb-race-field45.png')
  Check 'no JavaScript error on the page' ($script:cdp.errors.Count -eq 0)
  # PL-1: the drawing code is dormant (CARS_DRAWN = false) but kept: the seven silhouettes in four liveries and the class-colour fallback, drawn through window.PCarsDormant (a picture for the lead)
  $nSv = [int](Cdp-Eval '(function(){var D=["17,391C83,111111,CCFF00","5,FFFFFF,0A3D91,F2C230","3,111111,F2C230,FFFFFF","9,E10600,FFFFFF,111111"],h="<div style=\"position:fixed;inset:0;background:#0a0a0b;padding:30px 40px;font:16px Segoe UI,Arial;color:#cfcac0;z-index:99\">";PCarsDormant.types.forEach(function(t){h+="<div style=\"display:flex;align-items:center;gap:22px;height:116px\"><b style=\"width:130px;font-weight:400;letter-spacing:.12em\">"+PCarsDormant.names[t].toUpperCase()+"</b>";D.forEach(function(d,i){h+=PCarsDormant.svg({type:t,design:d,w:300,num:i==0?"64":null});});h+=PCarsDormant.svg({type:t,col:"#ffda59",w:300})+"</div>";});document.body.insertAdjacentHTML("beforeend",h+"</div>");return document.querySelectorAll("svg.pcar").length;})()')
  Start-Sleep -Milliseconds 300
  Cdp-Shot (Join-Path $shots 'cars-types.png')
  Check "all seven silhouettes draw in four liveries and in the class colour (picture tests\shots\cars-types.png; $nSv pictures on the page)" ($nSv -ge 35)
  Check 'no JavaScript error drawing them' ($script:cdp.errors.Count -eq 0)
  Cdp-Close
  }
} finally {
  try { [void](Get-Text '/api/test/end') } catch { }
  try { [void](Get-Text '/api/test/field?on=0') } catch { }
  try { [void](Get-Text '/vault/test/sandbox?on=0') } catch { }
  try { if ($script:cdp) { Cdp-Close } } catch { }
  if ($hookMade) { Remove-Item $hook -Force -ErrorAction SilentlyContinue }
  if ($lockMade) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
  Exit-TestLock
  if (-not $Keep) { Remove-Item $tdir -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
"race-field-test: $pass passed, $fail failed. Pictures in $shots (wb-race*.png). $([math]::Round($swAll.Elapsed.TotalSeconds, 0)) s"
if ($fail -gt 0) { exit 1 }
