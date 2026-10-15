# D-01 DEBRIEF ENGINE (dash\src\debrief.cs, docs\cards\v4\D-01.md): his race result, his position lap by lap and his pace
# against the field, and a practice pace story against the PB / optimal when the session has no race log.
# The engine is the same code the HTTP route sends (Debrief.Route). This test loads the freshly built irdash.exe (dash\build.ps1
# -NoDeploy, so nothing is deployed) and calls that function on real fixtures, then compares every number with a real race log
# and with the deployed lap-analysis routes (/analysis/race, /analysis/session, /analysis/lap). Out of the car only (guard.ps1).
# D-02 adds the corner video pairs: the three greatest time losses are cut from the recorder's own clips (this lap and the
# reference lap) with ffmpeg -c copy on a BelowNormal thread, both clips the same length and starting at the corner marker.
# The HTTP section is required: this test fails until /debrief is deployed and answers correctly.
#   powershell -ExecutionPolicy Bypass -File tests\debrief-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$api = if ($env:VAULT_TEST_API) { $env:VAULT_TEST_API } else { 'http://localhost:8199' }
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree

$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Note($what) { "  info  $what" }
function Near($a, $b, $t) { [math]::Abs([double]$a - [double]$b) -le $t }
function Section($title) { Assert-RigFree -Where $title; $title }
function Code($p) { try { return [int](Invoke-WebRequest -UseBasicParsing "$api$p" -TimeoutSec 60).StatusCode } catch [Net.WebException] { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } return 0 } }
$wc = New-Object System.Net.WebClient
function Txt($p) { [Text.Encoding]::UTF8.GetString($wc.DownloadData("$api$p")) }
function J($p) { (Txt $p) | ConvertFrom-Json }
function Q($s) { [uri]::EscapeDataString($s) }

$me = Get-Process -Id $PID; $me.PriorityClass = 'BelowNormal'
$cores = [Environment]::ProcessorCount
if ($cores -gt 2) { $mask = [int64]0; for ($i = 0; $i -lt 2; $i++) { $mask = $mask -bor ([int64]1 -shl ($cores - 1 - $i)) }; $me.ProcessorAffinity = [IntPtr]$mask }

$raceId = 'f20261011-220050-2'                                                # a real race log in vault\field (Peter, 20 cars, 6 laps)
$realField = Join-Path $root "vault\field\$raceId.json"
$pracName = 'bmwz4gt3_roadatlanta full 2026-10-11 21-48-35.ibt'                # a real practice session with no race log
$www = Join-Path $root 'dash\www\v2'
$shots = Join-Path $PSScriptRoot 'shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$work = Join-Path $env:TEMP ('debrief-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$vf = Join-Path $work 'vault'; $fd = Join-Path $vf 'field'
$script:sdkFake = $null; $script:sdkEnd = $null

# the same clean-lap rule RfSummary uses, written again here from the raw log (the independent pace check)
function CleanDur($l, $race) {
  $n = [int]$l[0]; $s = $l[1]; $e = $l[2]; $flags = [int]$l[6]; $off = [int]$l[7]
  if ($null -eq $s -or $null -eq $e) { return $null }
  $dur = [double]$e - [double]$s
  if (($flags -band 1) -ne 0 -or ($flags -band 2) -ne 0 -or $off -gt 0 -or $dur -lt 15) { return $null }
  if ($race -and $n -lt 2) { return $null }
  return $dur
}
function Median($v) { $s = @($v | Sort-Object); $n = $s.Count; if ($n -eq 0) { return $null }; if ($n % 2 -eq 1) { return [double]$s[[int][math]::Floor($n / 2)] }; return ([double]$s[$n / 2 - 1] + [double]$s[$n / 2]) / 2.0 }

# ---- headless Chrome with the DevTools protocol (the same harness as home-test, its own port) ----
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
$script:cdpProfile = $null
$script:cdpLaunchCmd = $null
function Cdp-Open($url, $w = 1920, $h = 1080, $init = '') {
  $prof = Join-Path $env:TEMP ('debrief-test-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $script:cdpProfile = $prof
  New-Item -ItemType Directory -Force -Path $prof | Out-Null
  $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
  $launchAt = Get-Date
  $chromeArgs = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', '--autoplay-policy=no-user-gesture-required', 'about:blank')
  $launchCmd = Join-Path $prof 'launch.cmd'
  $script:cdpLaunchCmd = $launchCmd
  [IO.File]::WriteAllText($launchCmd, '@echo off' + "`r`n" + '"' + $chrome + '" ' + ($chromeArgs -join ' ') + "`r`n", [Text.Encoding]::ASCII)
  Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $launchCmd + '"') -WindowStyle Hidden | Out-Null
  $p = $null
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  if (-not $page) { throw 'headless Chrome did not start' }
  $p = Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -ge $launchAt } | Sort-Object StartTime -Descending | Select-Object -First 1
  if ($p) { try { $p.PriorityClass = 'BelowNormal' } catch { } }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0; errors = New-Object System.Collections.Generic.List[string] }
  $null = Cdp 'Page.enable' @{}
  $null = Cdp 'Runtime.enable' @{}
  if ($init) { $null = Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $init } }
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
    if ($o.method -eq 'Runtime.exceptionThrown') { $c.errors.Add($o.params.exceptionDetails.exception.description) }
    if ($o.id -eq $c.id) { return $o }
  }
}
function Cdp-Eval($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return "js error: " + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
function Cdp-Json($expr) { return (Cdp-Eval "JSON.stringify($expr)") | ConvertFrom-Json }
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Cdp-Wait($cond, $secs = 15) { $until = (Get-Date).AddSeconds($secs); while ((Get-Date) -lt $until) { if ((Cdp-Eval "(function(){try{return !!($cond)}catch(e){return false}})()") -eq $true) { return $true }; Start-Sleep -Milliseconds 250 }; return $false }
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  try { Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } } } catch { }
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  $script:cdpProfile = $null; $script:cdpLaunchCmd = $null
}

try {
  # =====================================================================================================
  Section '1. compile without deploying and load the engine'
  $build = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'dash\build.ps1') -NoDeploy | Out-String
  $bm = [regex]::Match($build, 'built in (.+?) \(not deployed\)')
  Check 'dash\build.ps1 -NoDeploy compiled (debrief.cs is in $src)' ($LASTEXITCODE -eq 0 -and $bm.Success)
  if (-not $bm.Success) { throw $build }
  $exe = Join-Path $bm.Groups[1].Value.Trim() 'irdash.exe'
  $asm = [Reflection.Assembly]::LoadFile($exe)
  $bf = [Reflection.BindingFlags]'Static,Public,NonPublic'
  $asm.GetType('IRDash.RaceField').GetMethod('Init').Invoke($null, [object[]]@([string]$root)) | Out-Null
  $asm.GetType('IRDash.Vault').GetField('Root').SetValue($null, [string]$vf)     # the engine reads only the scratch vault
  $asm.GetType('IRDash.Corners').GetField('DataRoot', $bf).SetValue($null, [string]$root)   # D-02: the project's corner data (Corners.LoadCorners caches per track)
  $asm.GetType('IRDash.TrackMaps').GetField('TelemetryDir').SetValue($null, [string](Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'))
  $db = $asm.GetType('IRDash.Debrief').GetMethod('Route', $bf)
  $script:sdkFake = $asm.GetType('IRDash.Sdk').GetMethod('FakeSet', $bf)
  $script:sdkEnd = $asm.GetType('IRDash.Sdk').GetMethod('FakeEnd', $bf)
  New-Item -ItemType Directory -Force $fd | Out-Null
  Check "the real race log fixture is there ($raceId)" (Test-Path $realField)
  if (-not (Test-Path $realField)) { throw "no race log fixture at $realField" }
  Check 'the deployed irdash answers the lap analysis (the cross-check routes)' ((Code '/field/status') -eq 200)
  $script:routeMethod = $db
  function Db([string]$id) {
    $q = New-Object 'System.Collections.Generic.Dictionary[string,string]'; $q['id'] = $id
    $a = [object[]]@([string]'/debrief', $q.PSObject.BaseObject, [int]0)
    $sw = [Diagnostics.Stopwatch]::StartNew(); $j = $script:routeMethod.Invoke($null, $a); $sw.Stop()
    return [pscustomobject]@{ code = [int]$a[2]; ms = $sw.Elapsed.TotalMilliseconds; json = $j; obj = ($j | ConvertFrom-Json) }
  }

  # =====================================================================================================
  Section '2. a real race log: position by lap and result'
  Copy-Item $realField (Join-Path $fd "$raceId.json") -Force
  $r = Db $raceId
  Check 'the engine answers a race (result/positionByLap/pace, no practice)' ($r.code -eq 200 -and $r.obj.race -eq $true -and $null -ne $r.obj.result -and $null -ne $r.obj.positionByLap -and $null -eq $r.obj.practice)
  $wantPos = 14, 11, 10, 9, 9, 9
  $gotPos = @($r.obj.positionByLap | ForEach-Object { $_.position })
  $bad = 0; for ($i = 0; $i -lt $wantPos.Count; $i++) { if ($i -ge $gotPos.Count -or [int]$gotPos[$i] -ne $wantPos[$i]) { $bad++ } }
  Check "his position every lap equals the log ($($gotPos -join ',')): 0 mismatches" ($gotPos.Count -eq $wantPos.Count -and $bad -eq 0)
  $race = J "/analysis/race?id=$raceId"
  $trace = @($race.summary.trace | Where-Object { $_.i -eq 0 })[0]
  $mism = 0; $gOk = $true
  for ($i = 0; $i -lt $wantPos.Count; $i++) {
    if ([int]$gotPos[$i] -ne [int]$trace.p[$i]) { $mism++ }
    if (-not (Near $r.obj.positionByLap[$i].gapToLeader $trace.g[$i] 0.0005)) { $gOk = $false }
  }
  Check "0 mismatches against the log's own position by lap (the summary RfSummary.Build already made)" ($mism -eq 0)
  Check 'the gap to the leader every lap equals the log' $gOk
  Check "result: finish P$($r.obj.result.finishPosition) from P$($r.obj.result.startPosition) (+$($r.obj.result.positionsGained)), class P$($r.obj.result.classPosition), $($r.obj.result.cleanLaps) clean / $($r.obj.result.totalLaps) laps, gap to the winner $($r.obj.result.gapToWinner) s" `
    ($r.obj.result.finishPosition -eq 9 -and $r.obj.result.classPosition -eq 9 -and $r.obj.result.startPosition -eq 20 -and $r.obj.result.positionsGained -eq 11 -and $r.obj.result.cleanLaps -eq 3 -and $r.obj.result.totalLaps -eq 6)

  # =====================================================================================================
  Section '3. pace against the field: the three hand-checked numbers'
  $p = $r.obj.pace
  Check "his best lap = $($p.hisBest) (hand-checked 83.328, iRacing's own figure for lap 5)" ((Near $p.hisBest 83.328 0.0005))
  Check "his median lap = $($p.hisMedian) (hand-checked 84.275, the median of his 3 counted laps)" ((Near $p.hisMedian 84.275 0.0005))
  Check "the class best = $($p.classBest) (hand-checked 82.289, car 3's lap 6)" ((Near $p.classBest 82.289 0.0005))
  Check "n = $($p.n) rated cars, the field median = $($p.classMedian), the top 5 % = $($p.top5)" ($p.n -eq 20 -and (Near $p.classMedian 85.949 0.0005) -and (Near $p.top5 82.700 0.0005))
  # the same three numbers worked out again here, straight from the raw log (nothing shared with the engine)
  $raw = Get-Content $realField -Raw | ConvertFrom-Json
  $all = @(); $carMed = @(); $his = @(); $classBest = $null
  foreach ($c in $raw.cars) {
    $cl = @(); foreach ($l in @($c.L)) { $d = CleanDur $l $true; if ($null -ne $d) { $cl += $d; $all += $d } }
    if ($cl.Count -gt 0) { $carMed += (Median $cl) }
    if ([double]$c.rb -gt 15) { $cb = [double]$c.rb } elseif ([double]$c.bs -gt 15) { $cb = [double]$c.bs } else { $cb = ($cl | Measure-Object -Minimum).Minimum }
    if ($null -ne $cb -and ($null -eq $classBest -or $cb -lt $classBest)) { $classBest = $cb }
    if ([int]$c.i -eq 0) { $his = $cl }
  }
  $sorted = @($all | Sort-Object)
  $idx = [int][math]::Floor(0.05 * ($sorted.Count - 1)); if ($idx -lt 0) { $idx = 0 }
  Check "the same numbers straight from the raw log: class best $classBest, his median $(Median $his), field median $(Median $carMed), top5 $($sorted[$idx])" `
    ((Near $classBest $p.classBest 0.001) -and (Near (Median $his) $p.hisMedian 0.001) -and (Near (Median $carMed) $p.classMedian 0.001) -and (Near $sorted[$idx] $p.top5 0.001) -and ($carMed.Count -eq $p.n))

  # =====================================================================================================
  Section '4. practice fallback: a pace story against the PB and optimal'
  Remove-Item (Join-Path $fd '*.json') -Force -ErrorAction SilentlyContinue     # no race log matches this session
  $pq = Q $pracName
  Check "the practice file is readable and has no race log (session route answers)" ((Code "/analysis/session?id=$pq") -eq 200)
  $q = Db $pracName
  Check 'the engine falls back to a practice pace story (practice present, no result/positionByLap/pace)' ($q.code -eq 200 -and $q.obj.race -eq $false -and $null -ne $q.obj.practice -and $null -eq $q.obj.result -and $null -eq $q.obj.pace)
  $sess = J "/analysis/session?id=$pq"
  $lapJ = J "/analysis/lap?id=$pq&lap=$($sess.best.lap)&ref=pb"
  $validT = @($sess.laps | Where-Object { $_.valid } | ForEach-Object { [double]$_.time })
  $pmed = Median $validT
  Check "best = this session's best lap ($($q.obj.practice.best) vs $($lapJ.store.sessionBest.time))" (Near $q.obj.practice.best $lapJ.store.sessionBest.time 0.0005)
  Check "PB = the reference store's PB ($($q.obj.practice.pb) vs $($lapJ.store.pb.time))" (Near $q.obj.practice.pb $lapJ.store.pb.time 0.0005)
  Check "optimal = the reference store's optimal ($($q.obj.practice.optimal) vs $($lapJ.store.optimal))" (Near $q.obj.practice.optimal $lapJ.store.optimal 0.0005)
  Check "median = the median of the laps iRacing counted ($($q.obj.practice.median) vs $pmed)" (Near $q.obj.practice.median $pmed 0.0005)
  Check "n = $($q.obj.practice.n) counted laps, best lap number $($q.obj.practice.lap) (the session's best lap)" ($q.obj.practice.n -eq $validT.Count -and $q.obj.practice.lap -eq $sess.best.lap)

  # =====================================================================================================
  Section '5. GET /debrief?id= answers in <= 5 s'
  Copy-Item $realField (Join-Path $fd "$raceId.json") -Force
  $r2 = Db $raceId
  Check "the race debrief (debrief.cs, the code the HTTP route sends) was worked out in $([math]::Round($r2.ms)) ms" ($r2.code -eq 200 -and $r2.ms -le 5000)
  $live = Code "/debrief?id=$raceId"
  Check "the live /debrief endpoint answers HTTP 200 (got $live)" ($live -eq 200)
  if ($live -eq 200) {
    $sw = [Diagnostics.Stopwatch]::StartNew(); $null = J "/debrief?id=$raceId"; $sw.Stop()
    Check "the live endpoint answered in $([math]::Round($sw.Elapsed.TotalMilliseconds)) ms (<= 5000)" ($sw.Elapsed.TotalMilliseconds -le 5000)
  } else {
    Check 'the live endpoint timing is available' $false
  }

  # D-05: exercise the same production handler methods that /api/do reaches, without any available session action.
  Section '5b. D-05 visible-screen lease and stale-id rejection'
  $dbType = $asm.GetType('IRDash.Debrief')
  $lease = $dbType.GetMethod('ActiveJson', $bf)
  $doDb = $dbType.GetMethod('Do', $bf)
  $activeQ = New-Object 'System.Collections.Generic.Dictionary[string,string]'
  $activeQ['id'] = [string]$r2.obj.id; $activeQ['open'] = '1'
  $null = $lease.Invoke($null, [object[]]@($activeQ.PSObject.BaseObject))
  $openState = $dbType.GetMethod('StateJson').Invoke($null, @()) | ConvertFrom-Json
  Check 'the visible dashboard heartbeat exposes the current debrief to the deck' ($openState.open -and $openState.id -eq $r2.obj.id)
  $activeQ['open'] = '0'; $null = $lease.Invoke($null, [object[]]@($activeQ.PSObject.BaseObject))
  $closedState = $dbType.GetMethod('StateJson').Invoke($null, @()) | ConvertFrom-Json
  $allStale = $true
  foreach ($cmd in @('db-save','db-share','db-cosworth','db-deepdive')) {
    $argsDb = [object[]]@([string]$cmd, [string]$r2.obj.id)
    if ($doDb.Invoke($null, $argsDb)) { $allStale = $false }
  }
  $wrong = New-Object 'System.Collections.Generic.Dictionary[string,string]'; $wrong['id'] = 'unknown-debrief'; $wrong['open'] = '1'
  $badLease = $lease.Invoke($null, [object[]]@($wrong.PSObject.BaseObject)) | ConvertFrom-Json
  Check 'closing the screen dims the state and every production action refuses its stale id' (-not $closedState.open -and $allStale)
  Check 'an unknown debrief id cannot acquire the visible-screen lease' (-not $badLease.ok)
  $activeQ['open'] = '1'; $null = $lease.Invoke($null, [object[]]@($activeQ.PSObject.BaseObject))
  $dbType.GetField('dbAt', $bf).SetValue($null, [DateTime]::UtcNow.AddSeconds(-16))
  $expired = $dbType.GetMethod('StateJson').Invoke($null, @()) | ConvertFrom-Json
  $expiredAction = $doDb.Invoke($null, [object[]]@('db-deepdive', [string]$r2.obj.id))
  Check 'the lease expiry dims all keys and refuses actions after heartbeat stops' (-not $expired.open -and -not $expiredAction)
  $activeQ['open'] = '0'; $null = $lease.Invoke($null, [object[]]@($activeQ.PSObject.BaseObject))

  # =====================================================================================================
  Section '6. 503 while driving'
  $drvDict = New-Object 'System.Collections.Generic.Dictionary[string,double]'; $drvDict['IsOnTrack'] = 1
  $script:sdkFake.Invoke($null, [object[]]@($drvDict.PSObject.BaseObject)) | Out-Null
  Start-Sleep -Milliseconds 400
  $drv = Db $raceId
  $drivingNow = $asm.GetType('IRDash.Program').GetProperty('IsDriving', $bf).GetValue($null, $null)
  Check "with a session on track the engine answers 503, not a debrief ($($drv.code), IsDriving=$drivingNow)" ($drv.code -eq 503)
  $script:sdkEnd.Invoke($null, [object[]]@()) | Out-Null
  Start-Sleep -Milliseconds 300
  $after = Db $raceId
  Check "the pretend session is over: the engine answers a debrief again ($($after.code))" ($after.code -eq 200)

  # =====================================================================================================
  Section '7. corner video pairs (D-02): the three worst corners cut from the recorder clips'
  # D-02: /debrief also names the three corners that cost the most time against his best lap, each with a looping
  # pair cut from the recorder's own clips. A scratch vault holds two recorder-style clips tied to laps 7 (the PB)
  # and 8 (his lap) of the Corvette Road Atlanta session; Recorder.ClipFor finds each lap's clip and the engine cuts
  # the corner pair with ffmpeg -c copy on a BelowNormal thread. All offline (no deploy, no window).
  $ffmpeg = Join-Path $root 'vault\bin\ffmpeg.exe'; $ffprobe = Join-Path $root 'vault\bin\ffprobe.exe'
  $pbName = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt'
  $tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
  Check 'ffmpeg and ffprobe are here, and the real PB telemetry file' ((Test-Path $ffmpeg) -and (Test-Path $ffprobe) -and (Test-Path -LiteralPath (Join-Path $tel $pbName)))
  $dv = Join-Path $work 'dv'; $dvVault = Join-Path $dv 'vault'; $dvClips = Join-Path $dvVault 'clips'
  New-Item -ItemType Directory -Force $dvClips | Out-Null
  $m7 = [pscustomobject]@{ id = 'l20261010-041318-7'; startMs = [DateTimeOffset]::Parse('2026-10-10T04:13:18Z').ToUnixTimeMilliseconds(); car = 'Chevrolet Corvette Z06 GT3.R'; track = 'Road Atlanta'; config = 'Full Course'; lap = 7; lapTime = 79.549 }
  Check 'the local vault fixture defines the PB session and lap identity' ($m7.id -eq 'l20261010-041318-7' -and $m7.startMs -gt 0 -and $m7.car -and $m7.track)
  $moment = @{ id = $m7.id; kind = 'lap'; startMs = $m7.startMs; ts = [long]($m7.startMs / 1000); car = $m7.car; track = $m7.track; config = $m7.config; lap = $m7.lap; lapTime = $m7.lapTime; tags = @('PB'); ibt = $pbName }
  ConvertTo-Json -InputObject @($moment) -Compress | Set-Content -LiteralPath (Join-Path $dvVault 'moments.json') -Encoding UTF8
  # Own the complete scratch-vault fixture; earlier tests do not have to run first.
  $sessionRow = @($pbName, '1000000', [string][long]$m7.startMs, [string]([long]$m7.startMs + 79549), [string]$m7.car, [string]$m7.track, [string]$m7.config, '', [string]$m7.track, 'practice', '0', '79.549', '7', '2', '7:79.549;8:79.878', '0', '0', '0', '1', '79549', '1') -join "`t"
  Set-Content -LiteralPath (Join-Path $dvVault 'sessions.tsv') -Value $sessionRow -Encoding UTF8
  $script:srcMp4 = Join-Path $dv 'rec.mp4'
  function MkClip([string]$id, [int]$lap, [double]$lt) {
    Copy-Item $script:srcMp4 (Join-Path $dvClips "$id.mp4") -Force
    $lp = [long]$m7.startMs
    $j = [ordered]@{ id = $id; lap = $lap; lapTime = $lt; lapStartMs = $lp; lapEndMs = [long]($lp + $lt * 1000); clipStartMs = [long]($lp - 3000); lapStartOffset = 3.0; lapEndOffset = (3.0 + $lt); videoStart = 0.0; duration = 100.0; fps = 60; rotation = 0; encoder = 'libx264'; car = "$($m7.car)"; track = "$($m7.track)"; config = "$($m7.config)"; sessionTime = 0.0; why = 'test'; keep = $false; pb = $true; truncated = $false; created = 0; size = (Get-Item (Join-Path $dvClips "$id.mp4")).Length }
    ($j | ConvertTo-Json -Compress) | Set-Content (Join-Path $dvClips "$id.json") -Encoding UTF8
  }
  $ErrorActionPreference = 'Continue'
  & $ffmpeg -hide_banner -y -loglevel error -f lavfi -i 'testsrc2=size=1280x720:rate=60:duration=100' -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 30 -bf 0 -crf 30 -an $script:srcMp4 2>$null
  $ErrorActionPreference = 'Stop'
  Check 'ffmpeg made the pretend recording (100 s)' (Test-Path $script:srcMp4)
  MkClip 'rec-20261010-001500-l7' 7 79.549
  MkClip 'rec-20261010-001500-l8' 8 79.878
  # point the engine at this vault, the real telemetry folder and the project's corner data
  $asm.GetType('IRDash.Program').GetField('Dir', $bf).SetValue($null, [string](Join-Path $root 'dash'))
  $asm.GetType('IRDash.TrackMaps').GetField('TelemetryDir').SetValue($null, [string]$tel)
  $asm.GetType('IRDash.Vault').GetField('Root').SetValue($null, [string]$dvVault)
  $asm.GetType('IRDash.Vault').GetMethod('Load', $bf).Invoke($null, @()) | Out-Null
  $asm.GetType('IRDash.Recorder').GetMethod('Init', $bf).Invoke($null, [object[]]@([string]$dv)) | Out-Null
  function DbLap([string]$id, [string]$lap) {
    $q = New-Object 'System.Collections.Generic.Dictionary[string,string]'; $q['id'] = $id; if ($lap) { $q['lap'] = $lap }
    $a = [object[]]@([string]'/debrief', $q.PSObject.BaseObject, [int]0)
    $sw = [Diagnostics.Stopwatch]::StartNew(); $j = $script:routeMethod.Invoke($null, $a); $sw.Stop()
    return [pscustomobject]@{ code = [int]$a[2]; ms = $sw.Elapsed.TotalMilliseconds; json = $j; obj = ($j | ConvertFrom-Json) }
  }
  function Dur($f) { if (-not (Test-Path $f)) { return [double]::NaN }; return [double]((& $ffprobe -v error -select_streams v:0 -show_entries format=duration -of csv=p=0 $f) -join '') }
  $r = DbLap $pbName '8'
  $cs = @($r.obj.corners)
  Check 'the debrief answers with corners for the requested lap against the PB' ($r.code -eq 200 -and $cs.Count -eq 3)
  if ($cs.Count -gt 0) { Note ('the corners: ' + (($cs | ForEach-Object { "$($_.label) $($_.loss)" }) -join ', ')) }
  if ($cs.Count -eq 3) {
    Check "the three are the greatest positive losses, in order ($($cs[0].label) $($cs[0].loss), $($cs[1].label) $($cs[1].loss), $($cs[2].label) $($cs[2].loss))" ($cs[0].loss -ge $cs[1].loss -and $cs[1].loss -ge $cs[2].loss -and $cs[2].loss -gt 0)
    Check 'each corner names his lap 8 and reference lap 7 with a pct start/end and a label' (@($cs | Where-Object { $_.lap -eq 8 -and $_.refLap -eq 7 -and $_.p1 -gt $_.p0 -and $_.label.Length -gt 0 }).Count -eq 3)
    Check 'each corner name a video id and a reference video id (both clips resolved)' (@($cs | Where-Object { $_.videoId -and $_.referenceId }).Count -eq 3)
  }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt 90) {
    $pending = @($cs | Where-Object { $_.videoId -and (-not (Test-Path (Join-Path $dvClips ($_.videoId + '.mp4'))) -or -not (Test-Path (Join-Path $dvClips ($_.referenceId + '.mp4')))) })
    if ($pending.Count -eq 0) { break }
    Start-Sleep -Milliseconds 500
  }
  $r2 = DbLap $pbName '8'
  $cs2 = @($r2.obj.corners)
  Check 'all three corner pairs are cut (status ready)' ($cs2.Count -eq 3 -and @($cs2 | Where-Object { $_.status -ne 'ready' }).Count -eq 0)
  Check "the cuts ran BelowNormal (recorded $($r2.obj.videoPriority))" ($r2.obj.videoPriority -eq 'BelowNormal')
  foreach ($c in $cs2) {
    $v = Join-Path $dvClips ($c.videoId + '.mp4'); $rv = Join-Path $dvClips ($c.referenceId + '.mp4')
    $d1 = Dur $v; $d2 = Dur $rv
    Check "corner $($c.label): both clips exist and their durations are within 0.5 s ($([math]::Round($d1,2)) s vs $([math]::Round($d2,2)) s)" ((Test-Path $v) -and (Test-Path $rv) -and (Near $d1 $d2 0.5))
    Check "corner $($c.label): both clips expose independently aligned corner markers within one frame (this $([math]::Round($c.startOffset,3)) s, reference $([math]::Round($c.referenceStartOffset,3)) s)" ((Near $c.startOffset 2.0 (1.0/60.0)) -and (Near $c.referenceStartOffset 2.0 (1.0/60.0)) -and $c.duration -gt 0.5)
  }
  # the reference lap having no video: this lap plays alone
  Remove-Item (Join-Path $dvClips 'rec-20261010-001500-l7.mp4') -Force
  Remove-Item (Join-Path $dvClips 'rec-20261010-001500-l7.json') -Force
  $asm.GetType('IRDash.Recorder').GetMethod('Init', $bf).Invoke($null, [object[]]@([string]$dv)) | Out-Null
  $r3 = DbLap $pbName '8'
  $c0 = @($r3.obj.corners)[0]
  $soloPath = Join-Path $dvClips ($c0.videoId + '.mp4')
  Check 'no reference video: this lap has a real playable cut and referenceVideo is null' ($c0.referenceVideo -eq $null -and $c0.referenceId -eq $null -and $c0.video -ne $null -and (Test-Path $soloPath) -and (Dur $soloPath) -gt 0.5)
  # Simulate a session beginning after the worker selected the queued job but before ffmpeg launch.
  $script:sdkEnd.Invoke($null, [object[]]@()) | Out-Null
  Start-Sleep -Milliseconds 300
  $jobType = $asm.GetType('IRDash.Debrief+CvJob', $true)
  $ibf = [Reflection.BindingFlags]'Instance,Public,NonPublic'
  $job = [Activator]::CreateInstance($jobType, $true)
  $jobType.GetField('Id', $ibf).SetValue($job, 'race-start-regression')
  $jobType.GetField('Src', $ibf).SetValue($job, $script:srcMp4)
  $jobType.GetField('Out', $ibf).SetValue($job, (Join-Path $dvClips 'must-not-cut.mp4'))
  $jobType.GetField('Dur', $ibf).SetValue($job, [double]4)
  $run = $asm.GetType('IRDash.Debrief').GetMethod('CvRun', $bf)
  $before = $asm.GetType('IRDash.Debrief').GetField('CvBeforeLaunch', $bf)
  $raceVals = New-Object 'System.Collections.Generic.Dictionary[string,double]'; $raceVals['IsOnTrack'] = 1
  $raceHook = [Action]({ $script:sdkFake.Invoke($null, [object[]]@($raceVals.PSObject.BaseObject)) | Out-Null }.GetNewClosure())
  $before.SetValue($null, $raceHook)
  try { $run.Invoke($null, [object[]]@($job)) | Out-Null } finally { $before.SetValue($null, $null) }
  $queued = [string]$jobType.GetField('State', $ibf).GetValue($job)
  Check "session starts in the launch window: worker leaves the cut queued ($queued) and launches no ffmpeg" ($queued -eq 'queued' -and -not (Test-Path (Join-Path $dvClips 'must-not-cut.mp4')))
  # while driving: no debrief, so no cut is queued
  $drvDict2 = New-Object 'System.Collections.Generic.Dictionary[string,double]'; $drvDict2['IsOnTrack'] = 1
  $script:sdkFake.Invoke($null, [object[]]@($drvDict2.PSObject.BaseObject)) | Out-Null
  Start-Sleep -Milliseconds 400
  $rd = DbLap $pbName '8'
  Check "while driving the debrief refuses to cut (503, got $($rd.code))" ($rd.code -eq 503)
  $script:sdkEnd.Invoke($null, [object[]]@()) | Out-Null
  Start-Sleep -Milliseconds 300

  # =====================================================================================================
  Section '8. debrief-v4 screen (D-03): a real fixture, the 3a bands, no overlaps, copy clean'
  # Two real /debrief replies: the race (result, position by lap, pace) and the PB lap's three worst corners
  # (D-02). Merged into one fixture because no single fixture session has both a race log AND recorder clips.
  $fx = J "/debrief?id=$raceId"
  $fc = J "/debrief?id=$(Q $pbName)&lap=8"
  Check "the race fixture has result/positionByLap/pace ($(@($fx.positionByLap).Count) laps) and the corner fixture has three corners" ($fx.race -eq $true -and $null -ne $fx.result -and $null -ne $fx.pace -and @($fx.positionByLap).Count -ge 5 -and @($fc.corners).Count -eq 3)
  $fx.corners = $fc.corners
  $fxFile = Join-Path $www 'db4-fixture.json'
  ($fx | ConvertTo-Json -Depth 12 -Compress) | Set-Content -LiteralPath $fxFile -Encoding UTF8
  Cdp-Open "$api/v2/index.html?debrief4=$([uri]::EscapeDataString('/v2/db4-fixture.json'))"
  $okS = Cdp-Wait "typeof Debrief4 !== 'undefined' && !!document.querySelector('#debrief4.on')" 30
  Check 'the screen is up from the fixture (no press, no JavaScript error)' ($okS -and $script:cdp.errors.Count -eq 0)
  if ($script:cdp.errors.Count) { Note ('JavaScript: ' + ($script:cdp.errors -join ' / ')) }
  # the 3a bands: header 0-110, the three columns 110-410, WHERE THE TIME WENT 410-850, the action band 940-1080
  function Band($b, $id, $t, $bt) { if (-not $b.$id) { return $false }; return (Near $b.$id.t $t 20) -and (Near $b.$id.b $bt 20) }
  $bb = Cdp-Json 'Debrief4.bands()'
  Check "header band y 0-110 (top $([math]::Round($bb.db4Head.t)) bottom $([math]::Round($bb.db4Head.b)))" (Band $bb 'db4Head' 0 110)
  Check "three columns y 110-410 (top $([math]::Round($bb.db4Cols.t)) bottom $([math]::Round($bb.db4Cols.b)))" (Band $bb 'db4Cols' 110 410)
  Check "WHERE THE TIME WENT y 410-850 (top $([math]::Round($bb.db4Corners.t)) bottom $([math]::Round($bb.db4Corners.b)))" (Band $bb 'db4Corners' 410 850)
  Check "the action band is reserved y 940-1080 (top $([math]::Round($bb.db4Actions.t)) bottom $([math]::Round($bb.db4Actions.b)))" (Band $bb 'db4Actions' 940 1080)
  Check "the columns sit between the 96 px margins (result left $([math]::Round($bb.db4Result.l)), pace right $([math]::Round($bb.db4Pace.r)))" ((Near $bb.db4Result.l 96 20) -and (Near $bb.db4Pace.r 1824 20))
  $ov = Cdp-Json 'Debrief4.overlaps(document.getElementById("debrief4"))'
  Check "no text overlaps on the screen ($($ov.boxes) text boxes measured)" ($ov.bad.Count -eq 0 -and $ov.boxes -gt 20) ($ov.bad -join '; ')
  $t8 = Cdp-Eval "document.getElementById('debrief4').innerText"
  Check "the fixture values are on screen (class best 1:22.289, P9, corner $($fc.corners[0].label))" (($t8 -match '1:22\.289') -and ($t8 -match 'P9') -and ($t8 -match [regex]::Escape([string]$fc.corners[0].label)))
  $banned8 = @('\b(you|your|yours|you''re|you''ve|you''ll)\b', 'good (morning|afternoon|evening)', 'ready when', 'when you are', 'welcome', '\b(just|simply|quietly|automatically|insight|journey|story)\b', 'by itself', 'let''s', 'here''s', '!', '\u2014', '\s\u2013\s', '\w - \w', 'outline from', 'from your own', 'sampled', 'explains', 'is the mean', 'worked out from', 'last time here')
  $hit8 = @($banned8 | Where-Object { ([string]$t8) -match "(?i)$_" })
  Check "copy-audit 0 on the rendered screen ($((([string]$t8) -split '\s+').Count) words)" ($hit8.Count -eq 0) ($hit8 -join ' | ')
  Start-Sleep -Milliseconds 800      # the screen fades in over 0.5 s; the picture is taken when it is fully opaque
  Cdp-Shot (Join-Path $shots 'db-screen.png')
  Check 'picture tests\shots\db-screen.png written' ((Test-Path (Join-Path $shots 'db-screen.png')) -and (Get-Item (Join-Path $shots 'db-screen.png')).Length -gt 15000)
  Cdp-Close

  # =====================================================================================================
  Section '9. the after-session trigger: the screen comes up within 60 s, no press'
  Cdp-Open "$api/v2/index.html"
  $up9 = Cdp-Wait "typeof Debrief4 !== 'undefined'" 25
  $null = Cdp-Eval "window.__debrief4Src = '/v2/db4-fixture.json'; true"
  $sw9 = [Diagnostics.Stopwatch]::StartNew()
  # Drive the production poller through a live-to-ended transition. The callback is never invoked directly.
  $null = Cdp-Eval "window.__db4Live = true; UI.live = function(){ return window.__db4Live; }; 1"
  Start-Sleep -Milliseconds 1300
  $null = Cdp-Eval "window.__db4Live = false; 1"
  $on9 = Cdp-Wait "!!document.querySelector('#debrief4.on')" 60
  $secs9 = $sw9.Elapsed.TotalSeconds
  Check "the real UI.live poll detected live-to-ended and showed the screen in $([math]::Round($secs9,1)) s (<= 60, no callback call)" ($up9 -and $on9 -and $secs9 -le 60)
  Check 'identity is omitted when the response has no driver, number, or team fields' ((Cdp-Eval "!document.querySelector('#db4Head .db4-id')") -eq $true)
  Check 'the old debrief.js no longer puts a summary up by itself' ((Cdp-Eval "!document.getElementById('debrief')") -eq $true)
  Cdp-Close

  # =====================================================================================================
  Section '10. a practice session: the PACE block, no RESULT column'
  Remove-Item (Join-Path $fd '*.json') -Force -ErrorAction SilentlyContinue     # no race log overlaps this file (same as section 4)
  $fp = (Db $pracName).obj
  Check "the practice fixture is a pace story (race=$($fp.race), practice present $($null -ne $fp.practice), no result $($null -eq $fp.result))" ($fp.race -eq $false -and $null -ne $fp.practice -and $null -eq $fp.result)
  ($fp | ConvertTo-Json -Depth 12 -Compress) | Set-Content -LiteralPath (Join-Path $www 'db4-practice.json') -Encoding UTF8
  Cdp-Open "$api/v2/index.html?debrief4=$([uri]::EscapeDataString('/v2/db4-practice.json'))"
  $on10 = Cdp-Wait "!!document.querySelector('#debrief4.on #db4Pace')" 30
  $ov10 = Cdp-Json 'Debrief4.overlaps(document.getElementById("debrief4"))'
  Check 'practice: the PACE block is drawn, there is no RESULT column, and no text overlaps' ($on10 -and (Cdp-Eval "!document.getElementById('db4Result')") -eq $true -and $ov10.bad.Count -eq 0)
  Start-Sleep -Milliseconds 800
  Cdp-Shot (Join-Path $shots 'db-practice.png')
  Check 'picture tests\shots\db-practice.png written' ((Test-Path (Join-Path $shots 'db-practice.png')) -and (Get-Item (Join-Path $shots 'db-practice.png')).Length -gt 15000)
  Check 'no JavaScript error on the practice screen' ($script:cdp.errors.Count -eq 0)
  Cdp-Close

  # =====================================================================================================
  Section '11. copy-audit (source strings) passes for the new file'
  $caOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\copy-audit-test.ps1') -SourceOnly 2>&1 | Out-String
  $caExit = $LASTEXITCODE
  Check 'tests\copy-audit-test.ps1 -SourceOnly exit 0 (debrief-v4.js has no banned strings)' ($caExit -eq 0) (($caOut -split "`n" | Select-Object -Last 4) -join ' | ')

  # =====================================================================================================
  Section '12. incidents (D-04): lap/corner from the recorder sidecar and a playable clip'
  # The recorder's S1 session sidecar + a session mp4 for the PB session, with incidents inside lap 8. The incident's
  # time into the lap comes from the lap's own axis (Analysis.LapAxis), the same one the engine uses, so it lands in a
  # real corner. Before this section there is no sidecar, so every earlier section correctly shows no incidents.
  $recId = '20261010-041318-roadatlanta'
  $sessDir = Join-Path $dvVault 'sessions'; New-Item -ItemType Directory -Force $sessDir | Out-Null
  Copy-Item $script:srcMp4 (Join-Path $sessDir "$recId.mp4") -Force
  $lax = $asm.GetType('IRDash.Analysis').GetMethod('LapAxis', $bf)
  $la = [object[]]@([string]$pbName, [int]8, [double]0.0, $null, [int]0, [double]0.0)
  $laOk = $lax.Invoke($null, $la)
  $tm = @($la[3]); $metres = [int]$la[4]
  Check "the lap's own axis is there (lap 8, $metres m)" ($laOk -and $metres -gt 0)
  if (-not $laOk -or $metres -le 0) { $tm = @(0.0); $metres = 1 }
  $c0 = @($cs)[0]
  $midPct = ([double]$c0.p0 + [double]$c0.p1) / 2.0
  $idx = [int][math]::Round($midPct * $metres); if ($idx -lt 0) { $idx = 0 }; if ($idx -ge $metres) { $idx = $metres - 1 }
  $incA = [math]::Round([double]$tm[$idx], 3); $incB = [math]::Round([double]$tm[$idx] + 0.3, 3)
  Check "the worst corner $($c0.label) is at $incA s into lap 8" ($laOk -and $incA -gt 0 -and $incA -lt 80)
  $laps = @(@{ n = 8; offset = 0.0; time = 79.878; clean = $true; pb = $false }, @{ n = 9; offset = 80.0; time = 70.0; clean = $true; pb = $false })
  $incs = @(@{ offset = $incA; count = 2 }, @{ offset = $incB; count = 1 }, @{ offset = 79.9; count = 1 }, @{ offset = 80.0; count = 1 })
  $mp4Len = (Get-Item (Join-Path $sessDir "$recId.mp4")).Length
  # A schema-2 recorder sidecar carries the iRacing session identity; the debrief matches on it, never on track + time.
  # First a legacy sidecar (no identity): at best "probable", and it must never become the SAVE target.
  $side = @{ id = $recId; track = 'Road Atlanta'; config = 'Full Course'; car = "$($m7.car)"; sessionType = 'Practice'; startMs = [double]$m7.startMs; durationSec = 100.0; bytes = $mp4Len; encoder = 'libx264'; saved = $false; recovered = $false; created = [long]$m7.startMs; laps = $laps; incidents = $incs }
  ($side | ConvertTo-Json -Compress -Depth 6) | Set-Content -LiteralPath (Join-Path $sessDir "$recId.json") -Encoding UTF8
  $rl = DbLap $pbName '8'
  Check "a legacy sidecar without session identity is never the SAVE target (association $($rl.obj.bar.recording.association))" ($rl.code -eq 200 -and $null -eq $rl.obj.bar.recId -and $rl.obj.bar.recording.association -ne 'verified')
  $ev = $asm.GetType('IRDash.Analysis').GetMethod('ShareEvent', $bf).Invoke($null, [object[]]@([string]$pbName, [int]8, [double]0, $true, [double]0, $false))
  Check "the PB session's identity is in its telemetry (SessionUniqueID $($ev.Unique), SessionNum $($ev.SessNum))" ($ev.Err -eq '' -and $ev.Unique -gt 0)
  $side.schema = 2; $side.uniqueId = [int]$ev.Unique; $side.sessionNum = [int]$ev.SessNum; $side.state = 'ready'; $side.gaps = @()
  ($side | ConvertTo-Json -Compress -Depth 6) | Set-Content -LiteralPath (Join-Path $sessDir "$recId.json") -Encoding UTF8
  # and a newer recording at the same track with another identity must not steal it (the old code's newest-wins)
  $other = $side.Clone(); $other.id = '20261010-235959-roadatlanta'; $other.uniqueId = [int]$ev.Unique + 1; $other.startMs = [double]$m7.startMs + 600000
  ($other | ConvertTo-Json -Compress -Depth 6) | Set-Content -LiteralPath (Join-Path $sessDir "$($other.id).json") -Encoding UTF8
  Copy-Item $script:srcMp4 (Join-Path $sessDir "$($other.id).mp4") -Force
  $ri = DbLap $pbName '8'
  Check "the recording with the same session identity is verified ($($ri.obj.bar.recording.association), $($ri.obj.bar.recording.id))" ($ri.obj.bar.recording.association -eq 'verified' -and $ri.obj.bar.recording.id -eq $recId)
  Remove-Item (Join-Path $sessDir "$($other.id).*") -Force
  $inc = @($ri.obj.incidents)
  Check "the debrief lists the recorder's incidents ($($inc.Count))" ($ri.code -eq 200 -and $inc.Count -eq 4)
  Check 'each names lap 8, a corner, a type and a clip id' (@($inc | Where-Object { $_.lap -eq 8 -and $_.corner -and $_.type -and $_.videoId }).Count -eq 2)
  Check 'an offset after lap 8 ends is not assigned to lap 8 or future lap 9' ($inc[2].lap -eq 0 -and $null -eq $inc[2].timeSec)
  Check 'an offset exactly at lap 9 start belongs to lap 9' ($inc[3].lap -eq 9 -and [double]$inc[3].timeSec -eq 0)
  if ($inc.Count -ge 1) { Note "incident 1 -> lap $($inc[0].lap) $($inc[0].corner) $($inc[0].type) at $($inc[0].timeSec) s ($($inc[0].videoId))" }
  $bar = $ri.obj.bar
  Check "the bar names the recorder session to SAVE ($($bar.recId)) and the analysed lap's clip to SHARE ($($bar.shareId))" ($bar.recId -eq $recId -and $bar.shareId)
  Check "the bar's DEEP DIVE target is lap $($bar.deepDive.lap) on $($bar.deepDive.corner) of $($bar.deepDive.id)" ($bar.deepDive.id -eq $pbName -and $bar.deepDive.lap -eq 8 -and $bar.deepDive.corner)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt 90) {
    $pending = @($inc | Where-Object { $_.videoId -and -not (Test-Path (Join-Path $dvClips ($_.videoId + '.mp4'))) })
    if ($pending.Count -eq 0) { break }
    Start-Sleep -Milliseconds 500
  }
  $ri2 = DbLap $pbName '8'; $inc2 = @($ri2.obj.incidents)
  Check "every incident clip finished (status ready: $(@($inc2 | ForEach-Object { $_.status }) -join ', '))" (@($inc2 | Where-Object { $_.status -eq 'ready' }).Count -eq 4)
  foreach ($x in $inc2) {
    $f = Join-Path $dvClips ($x.videoId + '.mp4')
    Check "incident lap $($x.lap) $($x.corner): the clip is cut and playable ($([math]::Round((Dur $f),1)) s)" ((Test-Path $f) -and ((Dur $f) -gt 0.5))
  }

  # =====================================================================================================
  Section '13. the one-press bar (D-04): SAVE, SHARE, COSWORTH, DEEP DIVE'
  ($ri2.obj | ConvertTo-Json -Depth 12 -Compress) | Set-Content -LiteralPath (Join-Path $www 'db4-actions.json') -Encoding UTF8
  # a stand-in for the network: records every call and answers /vault/list (not installed), /api/rec/save (SAVED), /share/make (queued)
  $init = "window.__calls=[];window.__of=window.fetch.bind(window);window.fetch=function(u,o){window.__calls.push(String(u));var p=String(u);if(p.indexOf('/vault/list')>=0)return Promise.resolve({ok:true,json:function(){return Promise.resolve({cosworth:{installed:false}})}});if(p.indexOf('/api/rec/save')>=0)return Promise.resolve({ok:true,json:function(){return Promise.resolve({state:'SAVED'})}});if(p.indexOf('/share/make')>=0){if(p.indexOf('&ref=&stripe=0')<0)return Promise.resolve({ok:false,status:400,json:function(){return Promise.resolve({error:'missing parameters'})}});return Promise.resolve({ok:true,json:function(){return Promise.resolve({state:'queued',pct:0,queue:0})}});}return window.__of(u,o);};"
  Cdp-Open "$api/v2/index.html?debrief4=$([uri]::EscapeDataString('/v2/db4-actions.json'))" 1920 1080 $init
  $on13 = Cdp-Wait "typeof Debrief4 !== 'undefined' && !!document.querySelector('#debrief4.on')" 30
  Check 'the debrief screen is up from the fixture (no JavaScript error)' ($on13 -and $script:cdp.errors.Count -eq 0)
  Check "the INCIDENTS block shows all three incidents with lap data ($((Cdp-Eval 'Debrief4.incidents().length')))" ((Cdp-Eval 'Debrief4.incidents().length') -eq 3)
  Check 'each incident row carries a play button' ((Cdp-Eval "document.querySelectorAll('#db4Incidents .db4-iplay').length") -eq 3)
  $vid = @($inc2)[0].videoId
  $null = Cdp-Eval "Debrief4.playIncident('$vid'); true"
  Check "play opens the incident clip (/debrief/video?id=$vid)" ((Cdp-Eval 'Debrief4.playerSrc()') -eq "/debrief/video?id=$vid")
  $null = Cdp-Eval 'Debrief4.closePlayer(); true'
  # SAVE: only SAVED when the reply says SAVED; a second press still SAVED with the same id
  Check 'SAVE is wired to the recorder session id' ((Cdp-Eval "document.getElementById('db4Save').getAttribute('data-id')") -eq $recId)
  Check 'first SAVE answers SAVED and the button shows SAVED' (((Cdp-Eval 'Debrief4.save()') -eq 'SAVED') -and ((Cdp-Eval "document.getElementById('db4Save').textContent") -eq 'SAVED'))
  Check 'second SAVE is idempotent (still SAVED, same id)' (((Cdp-Eval 'Debrief4.save()') -eq 'SAVED') -and ((Cdp-Eval "window.__calls.filter(function(u){return u.indexOf('/api/rec/save')>=0}).length") -eq 2) -and ((Cdp-Eval "window.__calls.filter(function(u){return u.indexOf('/api/rec/save?id=$recId')>=0}).length") -eq 2))
  $null = Cdp-Eval "window.fetch=function(u,o){var p=String(u);window.__calls.push(p);if(p.indexOf('/api/rec/save')>=0)return Promise.resolve({ok:true,json:function(){return Promise.resolve({state:'error'})}});if(p.indexOf('/share/make')>=0&&p.indexOf('&ref=&stripe=0')>=0)return Promise.resolve({ok:true,json:function(){return Promise.resolve({state:'queued',pct:0,queue:0})}});return window.__of(u,o);}; true"
  Check 'SAVE response state other than SAVED leaves the button at SAVE' (((Cdp-Eval 'Debrief4.save()') -eq 'SAVE') -and ((Cdp-Eval "document.getElementById('db4Save').textContent") -eq 'SAVE'))
  # SHARE: queues /share/make on the analysed lap's clip and shows only the queue state
  $shareId = @($ri2.obj.bar.shareId)[0]
  Check 'first SHARE queues /share/make and shows the queue state' (((Cdp-Eval 'Debrief4.share()') -eq 'queued') -and ((Cdp-Eval "document.getElementById('db4Share').textContent") -eq 'QUEUED'))
  Check "the SHARE call names the analysed lap's clip and supplies explicit optional defaults ($shareId)" ((Cdp-Eval "window.__calls.some(function(u){return u.indexOf('/share/make?id=$shareId&ref=&stripe=0')>=0})") -eq $true)
  $null = Cdp-Eval "window.fetch=function(u,o){var p=String(u);if(p.indexOf('/share/make')>=0)return Promise.resolve({ok:false,status:500,json:function(){return Promise.resolve({})}});return window.__of(u,o);}; true"
  Check 'SHARE on an HTTP error shows no success (button back to SHARE)' (((Cdp-Eval 'Debrief4.share()') -eq 'error') -and ((Cdp-Eval "document.getElementById('db4Share').textContent") -eq 'SHARE'))
  # COSWORTH shows only when /vault/list says Pi Toolbox is installed
  Check 'COSWORTH stays hidden while /vault/list says it is not installed' ((Cdp-Eval "document.getElementById('db4Cos').hidden") -eq $true)
  Check 'the page read the install flag from /vault/list' ((Cdp-Eval "window.__calls.some(function(u){return u.indexOf('/vault/list')>=0})") -eq $true)
  $null = Cdp-Eval 'Debrief4.applyVaultList({cosworth:{installed:true}}); true'
  Check 'COSWORTH appears when /vault/list says it is installed' ((Cdp-Eval "document.getElementById('db4Cos').hidden") -eq $false)
  $null = Cdp-Eval 'Debrief4.applyVaultList({cosworth:{installed:false}}); true'
  Check 'and hides again when it is not' ((Cdp-Eval "document.getElementById('db4Cos').hidden") -eq $true)
  Start-Sleep -Milliseconds 600
  Cdp-Shot (Join-Path $shots 'db-bar.png')
  Check 'picture tests\shots\db-bar.png written (the incidents and the one-press bar)' ((Test-Path (Join-Path $shots 'db-bar.png')) -and (Get-Item (Join-Path $shots 'db-bar.png')).Length -gt 15000)
  # DEEP DIVE builds the workbench URL on the worst corner and opens it over the screen
  $ddUrl = 'workbench.html?id=' + [uri]::EscapeDataString($pbName) + '&lap=8&page=driver&corner=' + $ri2.obj.bar.deepDive.cornerN
  Check "DEEP DIVE builds the Workbench URL on the worst corner" ((Cdp-Eval 'Debrief4.deepDiveUrl(window.__deb4Last)') -eq $ddUrl)
  $null = Cdp-Eval "document.getElementById('db4Deep').click(); true"
  Start-Sleep -Milliseconds 400
  Check 'DEEP DIVE opens the Workbench in an iframe at that URL' ((Cdp-Eval "document.querySelector('#db4WbHost iframe') ? document.querySelector('#db4WbHost iframe').getAttribute('src') : ''") -eq $ddUrl)
  Cdp-Close

  # =====================================================================================================
  Section '14. Workbench seeks to an explicitly requested corner, even when it is not its own worst'
  $debWorst = @($ri2.obj.corners)[0]
  $otherCorner = @($ri2.obj.corners | Where-Object { $_.n -ne $debWorst.n })[0]
  if (-not $otherCorner) { throw 'Need at least two corners to distinguish the requested target from Workbench worst.' }
  Cdp-Open "$api/v2/workbench.html?id=$([uri]::EscapeDataString($pbName))&lap=8&page=driver&corner=$($otherCorner.n)"
  $wReady = Cdp-Wait "typeof WB !== 'undefined' && WB.ready === true" 60
  Check 'the Workbench opens on the DRIVER page with real data' ($wReady -and (Cdp-Eval 'WB.state.page') -eq 'driver' -and $script:cdp.errors.Count -eq 0)
  if (-not $wReady) { if ($script:cdp.errors.Count) { Note ('JavaScript: ' + ($script:cdp.errors -join ' / ')) } }
  $worst = Cdp-Json 'WB.data() && WB.data().worst ? { n: WB.data().worst.c.n, label: WB.data().worst.c.label } : null'
  $debWorst = @($ri2.obj.corners)[0]
  Check "fixture target $($otherCorner.label) differs from Workbench's own worst ($($worst.label))" ($null -ne $worst -and [int]$worst.n -ne [int]$otherCorner.n)
  Check 'the cursor sits at the explicitly requested corner apex' ((Cdp-Eval 'Math.round(WB.state.cur)') -eq (Cdp-Eval "WB.data().corners.filter(function(c){return c.n===$($otherCorner.n)})[0].ia"))
  Cdp-Shot (Join-Path $shots 'db-deepdive.png')
  Check 'picture tests\shots\db-deepdive.png written' ((Test-Path (Join-Path $shots 'db-deepdive.png')) -and (Get-Item (Join-Path $shots 'db-deepdive.png')).Length -gt 15000)
  Cdp-Close
} finally {
  try { Cdp-Close } catch { }
  Remove-Item (Join-Path $www 'db4-fixture.json') -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $www 'db4-practice.json') -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $www 'db4-actions.json') -Force -ErrorAction SilentlyContinue
  try { if ($script:sdkEnd) { $script:sdkEnd.Invoke($null, [object[]]@()) | Out-Null } } catch { }
  if ($script:cdpLaunchCmd) { Remove-Item -LiteralPath $script:cdpLaunchCmd -Force -ErrorAction SilentlyContinue }
  if ($script:cdpProfile) { Remove-Item -LiteralPath $script:cdpProfile -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
"debrief-test: $pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
