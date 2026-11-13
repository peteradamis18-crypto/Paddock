# server-load-test.ps1 (W0-3, plan layer 3) - what irdash costs while Peter drives, measured on the REAL server.
# Starts a copy of irdash in test mode (irdash.exe --test <folder> --port 8499, from %TEMP%: no window, no tray, no watchdog, no delta
# bar, no screen capture - irdash itself stands in for ffmpeg - no CrewChief / Stream Deck / overlay launching, every file in the folder),
# replays the 3-minute 12 Nov race fixture at 5x through /api/test/ibt while a pretend top screen reads /stream at 30 Hz and polls the
# pages, and samples irdash once a second: CPU, disk writes, threads, every file it writes, every delete (a file watcher), and its own
# count of process-list scans (proc.cs). Ceilings while the replay says a session is on:
#   no file write over 1 MB, no delete, no process scan (the perf sampler's one 5 s read for the black box is the only one, and it does
#   not go through the counter), irdash under 3 % of one core on average, under 40 threads, no job that waits for free ran.
# After the replay the deferred jobs run (after the 20 s grace) and the test prints what ran and how long each waited.
# OFFLINE: port 8499 only, never the live irdash (8199), never the live dash folder. Stops at once if the sim starts.
#   powershell -ExecutionPolicy Bypass -File tests\server-load-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$port = 8499; $B = "http://localhost:$port"
$dir = Join-Path $env:TEMP "w03-load-$PID"
$script:pass = 0; $script:fail = 0
function Check($what, $ok, $why = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what $why" } }

function Get($path, $timeout = 8000) {
  $o = @{ code = 0; body = '' }
  try {
    $r = [Net.HttpWebRequest]::Create($B + $path); $r.Timeout = $timeout; $r.ReadWriteTimeout = $timeout; $r.KeepAlive = $false
    $r.Headers['X-Paddock'] = '1'
    $resp = $r.GetResponse()
  } catch [Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { return $o } } catch { return $o }
  $o.code = [int]$resp.StatusCode
  $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $o.body = $sr.ReadToEnd(); $sr.Dispose(); $resp.Close()
  return $o
}
function Json($path) { $r = Get $path; if ($r.code -ne 200) { return $null }; try { return $r.body | ConvertFrom-Json } catch { return $null } }

# the live rig: the sim, or a START key on the LIVE checkout (this worktree has its own dash folder)
function LiveBusy {
  $why = Get-RigBusy; if ($why) { return $why }
  $mark = 'C:\Users\peter\iRacingDeck\dash\start-mark.txt'
  if (Test-Path $mark) {
    $p = ([IO.File]::ReadAllText($mark)).Split("`t"); $t = 0L
    if ($p.Count -gt 1 -and $p[1].Trim() -ne 'TEST' -and [long]::TryParse($p[0], [ref]$t) -and ([DateTime]::UtcNow - (New-Object DateTime $t, ([DateTimeKind]::Utc))).TotalMinutes -lt 10) { return 'a START key was pressed in the last 10 minutes' }
  }
  return $null
}

Add-Type @'
using System; using System.Collections.Generic; using System.IO; using System.Runtime.InteropServices;
public static class LoadProbe {
  [StructLayout(LayoutKind.Sequential)] public struct IO { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
  [DllImport("kernel32.dll")] static extern bool GetProcessIoCounters(IntPtr h, out IO c);
  public static ulong WriteBytes(IntPtr h) { IO c; return GetProcessIoCounters(h, out c) ? c.WriteBytes : 0; }
  // every delete, rename and write under the folder, with its time
  static FileSystemWatcher w; static readonly List<string> ev = new List<string>();
  public static void Watch(string dir) {
    w = new FileSystemWatcher(dir); w.IncludeSubdirectories = true; w.InternalBufferSize = 65536;
    w.NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.Size | NotifyFilters.LastWrite;
    w.Deleted += delegate (object s, FileSystemEventArgs e) { Add("delete", e.FullPath); };
    w.Renamed += delegate (object s, RenamedEventArgs e) { Add("rename", e.OldFullPath + " -> " + e.FullPath); };
    w.Created += delegate (object s, FileSystemEventArgs e) { Add("create", e.FullPath); };
    w.EnableRaisingEvents = true;
  }
  static void Add(string k, string p) { lock (ev) ev.Add(DateTime.UtcNow.Ticks + "\t" + k + "\t" + p); }
  public static string[] Events() { lock (ev) return ev.ToArray(); }
  public static void Stop() { if (w != null) { w.EnableRaisingEvents = false; w.Dispose(); } }
}
'@

$p = $null; $rs = @()
try {
  # ---------------------------------------------------------------- 0. build and the test folder
  Assert-RigFree -Where '0. build'
  'Section 0. build irdash (no deploy) and make the test folder'
  $bo = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'dash\build.ps1') -NoDeploy 2>&1
  $m = [regex]::Match(($bo -join "`n"), 'built in (\S+) \(not deployed\)')
  Check 'irdash compiles (dash\build.ps1 -NoDeploy)' $m.Success ($bo | Select-Object -Last 3)
  if (-not $m.Success) { throw 'no build' }
  $fixture = Join-Path $root 'tests\fixtures\race-12nov.ibt'
  if (-not (Test-Path $fixture)) { $fixture = 'C:\Users\peter\iRacingDeck\tests\fixtures\race-12nov.ibt' }      # the fixtures are gitignored: the live checkout's copy, read only
  if (-not (Test-Path $fixture)) {
    $source = 'C:\Users\peter\OneDrive\Documents\iRacing\telemetry\toyotagr86_roadatlanta full 2026-11-12 09-28-07.ibt'
    $fixture = Join-Path $root 'tests\fixtures\race-12nov.ibt'
    if (Test-Path $source) { & (Join-Path $root 'tests\tools\ibt-cut.ps1') -Source $source -Out $fixture -From 200 -To 380 | Out-Null }
  }
  Check 'the 3-minute 12 Nov race fixture is there' (Test-Path $fixture) $fixture
  if (-not (Test-Path $fixture)) { throw 'no fixture' }
  New-Item -ItemType Directory -Force "$dir\dash", "$dir\telemetry" | Out-Null
  Copy-Item (Join-Path $m.Groups[1].Value 'irdash.exe') "$dir\dash\irdash.exe"
  Copy-Item (Join-Path $root 'dash\irdash.exe.config') "$dir\dash\irdash.exe.config" -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $root 'dash\www') "$dir\dash\www" -Recurse      # /version looks through the page files every 15 s
  Copy-Item $fixture "$dir\telemetry\toyotagr86_roadatlanta full 2026-11-12 09-28-07.ibt"      # an old file for the deferred jobs to read (it keeps its date)
  Set-Content "$dir\dash\irdash.ini" -Encoding ascii -Value @(
    '; server-load-test: a test copy of irdash. Nothing here is the real one.',
    'port=8499', 'open_on_start=0', 'keep_dash=0', 'place_sim=0', 'hide_taskbar=0', 'delta_bar=0', 'gallery=0',
    'log_all_cars=0', 'sync_sim_ini=0', 'vault=1', 'official=1', 'recorder=1', 'perf_prio=0')
  [LoadProbe]::Watch($dir)

  # ---------------------------------------------------------------- 1. start
  Assert-RigFree -Where '1. start'
  'Section 1. irdash in test mode on port 8499'
  $p = Start-Process "$dir\dash\irdash.exe" -ArgumentList '--test', "`"$dir`"", '--port', "$port" -PassThru
  $j = $null; for ($i = 0; $i -lt 40 -and -not $j; $i++) { Start-Sleep -Milliseconds 500; $j = Json '/jobs' }
  Check 'it answers on 8499 and says it is in test mode' ($j -and $j.testMode -eq $true)
  if (-not $j) { throw 'test-mode irdash did not start' }
  $p.Refresh()
  Check 'no window (no kiosk, no tray dialog)' ($p.MainWindowHandle -eq [IntPtr]::Zero)
  $log0 = Get-Content "$dir\dash\irdash.log" -Raw -ErrorAction SilentlyContinue
  Check 'the log says test mode, data under the test folder' ($log0 -match 'test mode: port 8499, data under')
  Check 'no CrewChief watch, no watchdog, no delta bar (nothing of the kind in the log)' ($log0 -notmatch 'spotter guard|watchdog:|delta bar:')
  # the start-up jobs (maps, the career scan, the owned cars) run first: the session is measured on a quiet server
  for ($i = 0; $i -lt 90; $i++) { $j = Json '/jobs'; if ($j -and $j.jobs.queued.Count -eq 0 -and -not $j.jobs.running -and $j.jobs.ran -ge 1) { break }; Start-Sleep 1 }
  "  start-up jobs: " + (($j.jobs.recent | ForEach-Object { "$($_.name) ($($_.tookS) s)" }) -join ', ')
  # a short warm-up session first: the real irdash has run for hours before a race, so its code is already compiled (.NET compiles each
  # method the first time it runs); the measured session below is then the steady cost, not the one-off start-up cost
  [void](Get "/api/test/ibt?file=$([Uri]::EscapeDataString($fixture))&speed=5&to=25")
  try {
    $wr = [Net.HttpWebRequest]::Create("$B/stream?hz=30&vars=Speed,Lap,CarIdxLapDistPct,CarIdxPosition"); $wr.Timeout = 5000; $wx = $wr.GetResponse(); $ws = $wx.GetResponseStream()
    $wb = New-Object byte[] 65536; $sw0 = [Diagnostics.Stopwatch]::StartNew(); while ($sw0.ElapsedMilliseconds -lt 3000) { [void]$ws.Read($wb, 0, $wb.Length) }; $wx.Close()
  } catch { }
  for ($i = 0; $i -lt 20; $i++) { Start-Sleep 1; $rp = Json '/api/test/ibt?status=1'; if ($rp -and $rp.done) { break } }
  [void](Get '/api/test/end')
  for ($i = 0; $i -lt 60; $i++) { Start-Sleep 1; $j = Json '/jobs'; if ($i -ge 22 -and $j.jobs.free -and $j.jobs.queued.Count -eq 0 -and -not $j.jobs.running) { break } }
  "  warm-up session done; jobs after it: " + (($j.jobs.recent | Select-Object -Last 4 | ForEach-Object { $_.name }) -join ', ')

  # ---------------------------------------------------------------- 2. the replayed session
  Assert-RigFree -Where '2. replay'
  'Section 2. the 12 Nov race at 5x, with the top screen''s stream and page polls'
  $shared = [hashtable]::Synchronized(@{ stop = $false; events = 0; bytes = 0; req = 0; err = 0; slow = 0; byPath = @{}; errAt = '' })
  $vars = 'SessionTime,SessionNum,SessionUniqueID,SessionState,SessionFlags,SessionTimeRemain,SessionLapsRemainEx,SessionTimeOfDay,PlayerCarIdx,PlayerCarPosition,PlayerCarClassPosition,PlayerCarMyIncidentCount,PlayerTrackSurface,IsOnTrack,IsOnTrackCar,IsReplayPlaying,OnPitRoad,CamCarIdx,DisplayUnits,FrameRate,Speed,RPM,Gear,Throttle,Brake,Clutch,SteeringWheelAngle,SteeringWheelAngleMax,SteeringWheelMaxForceNm,SteeringWheelTorque,SteeringWheelPctTorque,FuelLevel,FuelLevelPct,FuelUsePerHour,Lap,LapCompleted,LapDistPct,LapCurrentLapTime,LapLastLapTime,LapBestLapTime,LapDeltaToBestLap,LapDeltaToBestLap_OK,LapDeltaToSessionBestLap,LapDeltaToSessionBestLap_OK,Lat,Lon,WaterTemp,OilTemp,OilPress,Voltage,EngineWarnings,AirTemp,TrackTempCrew,TrackWetness,WindVel,WindDir,Precipitation,WeatherDeclaredWet,Skies,RelativeHumidity,CarLeftRight,SessionLapsTotal,dcBrakeBias,dcABS,dcTractionControl,dcTractionControl2,CarIdxLapDistPct,CarIdxLap,CarIdxLapCompleted,CarIdxPosition,CarIdxClassPosition,CarIdxOnPitRoad,CarIdxTrackSurface,CarIdxEstTime,CarIdxF2Time,CarIdxLastLapTime,CarIdxBestLapTime'
  $streamScript = {
    param($B, $vars, $shared)
    try {
      $r = [Net.HttpWebRequest]::Create("$B/stream?hz=30&vars=$vars"); $r.Timeout = 10000; $r.ReadWriteTimeout = 10000
      $resp = $r.GetResponse(); $s = $resp.GetResponseStream(); $buf = New-Object byte[] 65536
      while (-not $shared.stop) {
        $n = $s.Read($buf, 0, $buf.Length); if ($n -le 0) { break }
        $shared.bytes += $n; $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
        $shared.events += ([regex]::Matches($txt, '(?m)^data: ')).Count
      }
      $resp.Close()
    } catch { $shared.err++ }
  }
  $pollScript = {
    param($B, $shared)
    # the top screen while driving: /keymsg 0.4 s, /mydrive 1.2 s, /guest 1 s, /race 2 s, /perf/live 4 s, /home 5 s, /overlays 6 s,
    # /version 15 s, /trackmap and /deck/state as the deck asks (~3 a second)
    $plan = @(@('/keymsg', 400), @('/mydrive', 1200), @('/guest', 1000), @('/race', 2000), @('/perf/live', 4000), @('/home', 5000), @('/overlays', 6000), @('/version', 15000), @('/deck/state', 350), @('/trackmap?key=t127-roadatlanta-full&id=127&name=roadatlanta+full', 10000), @('/health', 6000), @('/vault/recorder', 5000))
    $next = @{}; foreach ($x in $plan) { $next[$x[0]] = 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $shared.stop) {
      foreach ($x in $plan) {
        if ($sw.ElapsedMilliseconds -lt $next[$x[0]]) { continue }
        $next[$x[0]] = $sw.ElapsedMilliseconds + $x[1]
        $t0 = $sw.ElapsedMilliseconds
        try {
          $r = [Net.HttpWebRequest]::Create($B + $x[0]); $r.Timeout = 5000; $r.KeepAlive = $false
          $resp = $r.GetResponse(); $sr = New-Object IO.StreamReader($resp.GetResponseStream()); [void]$sr.ReadToEnd(); $sr.Dispose(); $resp.Close()
          $shared.req++
        } catch [Net.WebException] { if ($_.Exception.Response) { $shared.req++; $_.Exception.Response.Close() } else { $shared.err++; $shared.errAt += $x[0].Split('?')[0] + ' (' + $_.Exception.Status + ') ' } } catch { $shared.err++; $shared.errAt += $x[0] + ' ' }
        if ($sw.ElapsedMilliseconds - $t0 -gt 500) { $shared.slow++ }
        $k = $x[0].Split('?')[0]; if (-not $shared.byPath.ContainsKey($k)) { $shared.byPath[$k] = 0 }; $shared.byPath[$k]++
      }
      Start-Sleep -Milliseconds 50
    }
  }
  foreach ($sb in @(@($streamScript, @($B, $vars, $shared)), @($pollScript, @($B, $shared)))) {
    $ps = [PowerShell]::Create(); [void]$ps.AddScript($sb[0]); foreach ($a in $sb[1]) { [void]$ps.AddArgument($a) }
    $rs += ,@($ps, $ps.BeginInvoke())
  }
  # the same server with the same pretend screen and no session, for comparison (not a ceiling)
  Start-Sleep 2
  $c0 = $p.TotalProcessorTime.TotalSeconds; Start-Sleep 8; $p.Refresh()
  "  before the session (stream and polls, no session): $([math]::Round(100 * ($p.TotalProcessorTime.TotalSeconds - $c0) / 8, 2)) % of one core, $($p.Threads.Count) threads"
  $start = Get "/api/test/ibt?file=$([Uri]::EscapeDataString($fixture))&speed=5"
  Check 'the replay starts (GET /api/test/ibt, 5x)' ($start.code -eq 200) "$($start.code) $($start.body)"
  $on = $false; for ($i = 0; $i -lt 40 -and -not $on; $i++) { Start-Sleep -Milliseconds 250; $st = Json '/rig/state'; $on = $st -and $st.sessionOn }
  Check 'irdash says a session is on' $on
  $onAt = [DateTime]::UtcNow
  $scans0 = (Json '/jobs').proc.scans
  $ranBefore = (Json '/jobs').jobs.ran
  # the test hook's own threads (the .ibt replay and the pretend session's pump) are not irdash's cost in a race: measured apart
  $rp0 = Json '/api/test/ibt?status=1'; $hookIds = @([int]$rp0.osThread, [int]$rp0.pumpThread) | Where-Object { $_ -gt 0 }
  function HookCpu { $p.Refresh(); $s = 0.0; foreach ($th in $p.Threads) { if ($hookIds -contains $th.Id) { try { $s += $th.TotalProcessorTime.TotalSeconds } catch { } } }; return $s }
  $p.Refresh(); $hook = @{}; foreach ($th in $p.Threads) { if ($hookIds -contains $th.Id) { $hook[$th.Id] = @($th.TotalProcessorTime.TotalSeconds, $th.TotalProcessorTime.TotalSeconds) } }
  $cpu0 = $p.TotalProcessorTime.TotalSeconds; $wb0 = [LoadProbe]::WriteBytes($p.Handle); $t0 = [DateTime]::UtcNow
  $size0 = @{}; foreach ($f in Get-ChildItem $dir -Recurse -File) { $size0[$f.FullName] = $f.Length }
  $maxThreads = 0; $samples = @(); $maxGrow = 0; $maxGrowFile = ''; $done = $false; $busyStop = $null
  $whenFreeRan = @()
  for ($sec = 0; $sec -lt 75 -and -not $done; $sec++) {
    Start-Sleep 1
    $why = LiveBusy; if ($why) { $busyStop = $why; break }
    $p.Refresh(); $th = $p.Threads.Count; if ($th -gt $maxThreads) { $maxThreads = $th }
    foreach ($f in Get-ChildItem $dir -Recurse -File) {
      $g = $f.Length - $(if ($size0.ContainsKey($f.FullName)) { $size0[$f.FullName] } else { 0 })
      if ($g -gt $maxGrow) { $maxGrow = $g; $maxGrowFile = $f.FullName.Substring($dir.Length + 1) }
    }
    # 10 s in: Peter presses KEEP (the lap's clip is kept: the cut and the Vault's index save must wait for the session to end)
    if ($sec -eq 10) { $keep = Get '/api/do?c=vkkeep'; $keepOk = $keep.code -eq 200 }
    $rp = Json '/api/test/ibt?status=1'
    if ($rp -and $rp.done) { $done = $true }
    $samples += $th
    foreach ($x in $p.Threads) { if ($hook.ContainsKey($x.Id)) { try { $hook[$x.Id][1] = $x.TotalProcessorTime.TotalSeconds } catch { } } }
  }
  $j1 = Json '/jobs'; $scans1 = $j1.proc.scans
  $st = Json '/rig/state'; $stillOn = $st -and $st.sessionOn
  $cpu1 = $p.TotalProcessorTime.TotalSeconds; $wb1 = [LoadProbe]::WriteBytes($p.Handle); $t1 = [DateTime]::UtcNow
  $offAt = [DateTime]::UtcNow
  foreach ($r in $j1.jobs.recent) { if ($r.whenFree -and ([DateTime]::Parse($r.at).ToUniversalTime() -gt $onAt)) { $whenFreeRan += $r.name } }
  $ev = [LoadProbe]::Events() | ForEach-Object { $a = $_.Split("`t"); [pscustomobject]@{ T = [DateTime]::new([long]$a[0], 'Utc'); K = $a[1]; P = $a[2] } } | Where-Object { $_.T -ge $onAt -and $_.T -le $offAt }
  $dels = @($ev | Where-Object { $_.K -eq 'delete' -and $_.P -notmatch '\.tmp$' })
  if ($busyStop) { throw "the rig got busy: $busyStop" }
  $wall = ($t1 - $t0).TotalSeconds; $hookS = 0.0; foreach ($v in $hook.Values) { $hookS += $v[1] - $v[0] }
  $allPct = 100.0 * ($cpu1 - $cpu0) / $wall; $hookPct = 100.0 * $hookS / $wall; $cpuPct = $allPct - $hookPct
  Check "the replay ran to its end while a session was on ($([math]::Round($wall)) s)" ($done -and $stillOn)
  Check "the pretend top screen got the stream ($($shared.events) frames) and its polls answered ($($shared.req) requests, $($shared.err) errors)" ($shared.events -gt 100 -and $shared.req -gt 50 -and $shared.err -eq 0) $shared.errAt
  Check "no file write over 1 MB (biggest: $([math]::Round($maxGrow / 1KB)) KB, $maxGrowFile)" ($maxGrow -le 1MB)
  Check "no delete while the session was on ($($dels.Count))" ($dels.Count -eq 0) (($dels | ForEach-Object { $_.P.Substring($dir.Length + 1) }) -join '; ')
  Check "no process scan while the session was on ($($scans1 - $scans0); the perf sampler's 5 s read for the black box is the only one, outside the counter)" (($scans1 - $scans0) -eq 0) ($j1.proc.byName | ConvertTo-Json -Compress)
  Check "irdash under 3 % of one core on average ($([math]::Round($cpuPct, 2)) %; the process $([math]::Round($allPct, 2)) %, of which the test hook's replay and pump $([math]::Round($hookPct, 2)) %, threads $($hookIds -join '/'))" ($cpuPct -lt 3 -and $hook.Count -eq 2)
  Check "irdash under 40 threads (most: $maxThreads)" ($maxThreads -lt 40)
  Check "no job that waits for free ran during the session ($($whenFreeRan.Count))" ($whenFreeRan.Count -eq 0) ($whenFreeRan -join ', ')
  $queuedNow = @($j1.jobs.queued | ForEach-Object { $_.name })
  "  waiting for the session to end: " + $(if ($queuedNow.Count) { $queuedNow -join ', ' } else { '(nothing)' })
  Check 'work was held back for after the session (the recorder''s housekeeping at least)' ($queuedNow.Count -ge 1)
  Check 'KEEP mid-session: one line in marks.tsv now, the Vault''s full save held back' ($keepOk -and (Test-Path "$dir\vault\marks.tsv") -and ((Get-Content "$dir\vault\marks.tsv") -match "`tkeep`t") -and ($queuedNow -contains 'vault save'))
  Check 'the kept lap''s clip cut is held back too' (@($queuedNow | Where-Object { $_ -like 'recorder cut *' }).Count -ge 1) ($queuedNow -join ', ')
  $summary = "load: avg CPU $([math]::Round($cpuPct, 2)) % of one core (test hook $([math]::Round($hookPct, 2)) % more), max write $([math]::Round($maxGrow / 1KB)) KB, deletes $($dels.Count), scans $($scans1 - $scans0), threads max $maxThreads, disk writes $([math]::Round(($wb1 - $wb0) / 1KB)) KB in $([math]::Round($wall)) s, $($shared.req) page requests, $($shared.events) stream frames"

  # ---------------------------------------------------------------- 3. after the session
  Assert-RigFree -Where '3. after'
  'Section 3. the session ends: the held-back jobs run after the 20 s grace'
  $end = Get '/api/test/end'
  $endAt = [DateTime]::UtcNow
  $shared.stop = $true
  $after = $null
  for ($i = 0; $i -lt 150; $i++) {
    Start-Sleep 1
    $why = LiveBusy; if ($why) { throw "the rig got busy: $why" }
    $after = Json '/jobs'
    $finish = @($after.jobs.recent | Where-Object { $_.name -like 'recorder session file*' })
    if ($i -gt 25 -and $after.jobs.queued.Count -eq 0 -and -not $after.jobs.running -and ($finish.Count -gt 0 -or $i -gt 100)) { break }
  }
  $ranAfter = @($after.jobs.recent | Where-Object { [DateTime]::Parse($_.at).ToUniversalTime() -gt $endAt })
  foreach ($r in $ranAfter) { "  ran: $($r.name) - waited $($r.waitedS) s, took $($r.tookS) s$(if ($r.yielded) { ', paused for a session' })$(if ($r.error) { ', error: ' + $r.error })" }
  $firstFree = $ranAfter | Where-Object { $_.whenFree } | Sort-Object { [DateTime]::Parse($_.at) } | Select-Object -First 1
  $firstStart = if ($firstFree) { [DateTime]::Parse($firstFree.at).ToUniversalTime().AddSeconds(-[double]$firstFree.tookS) } else { $null }
  Check 'the held-back jobs ran after the session' ($ranAfter.Count -ge 1)
  Check "and not before the 20 s grace (first started $(if ($firstStart) { [math]::Round(($firstStart - $endAt).TotalSeconds, 1) } else { '-' }) s after the end)" ($firstStart -and ($firstStart - $endAt).TotalSeconds -ge 19)
  Check 'the recorder''s session file was written after the session (mock ffmpeg)' (@($ranAfter | Where-Object { $_.name -like 'recorder session file*' -and -not $_.error }).Count -ge 1 -and (Get-ChildItem "$dir\vault\sessions" -Filter *.mp4 -ErrorAction SilentlyContinue).Count -ge 1)
  Check 'the kept lap''s clip was cut after the session (mock ffmpeg), and the Vault saved' (@($ranAfter | Where-Object { $_.name -like 'recorder cut *' -and -not $_.error }).Count -ge 1 -and (Get-ChildItem "$dir\vault\clips" -Filter 'rec-*.mp4' -ErrorAction SilentlyContinue).Count -ge 1 -and @($ranAfter | Where-Object { $_.name -eq 'vault save' }).Count -ge 1)
  Check 'nothing is left waiting' ($after.jobs.queued.Count -eq 0)
  $log = Get-Content "$dir\dash\irdash.log" -Raw
  Check 'one log line per job ("jobs: <name> ran (waited x s, took y s)")' ($log -match 'jobs: recorder session file \S+ ran \(waited \d+\.\d s, took \d+\.\d s\)')
  ''
  $summary
}
catch { $script:fail++; "  FAIL  $($_.Exception.Message)" }
finally {
  if ($shared) { $shared.stop = $true }
  foreach ($x in $rs) { try { $x[0].Stop(); $x[0].Dispose() } catch { } }
  if ($p -and -not $p.HasExited) { try { [void](Get '/api/test/quit' 2000) } catch { }; Start-Sleep 2; if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
  # the mock ffmpeg children (irdash.exe --mock) die with their job object; any left are ours (same exe path)
  Get-Process irdash -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$dir*" } | Stop-Process -Force -ErrorAction SilentlyContinue
  try { [LoadProbe]::Stop() } catch { }
  Start-Sleep 1
  if ($env:W03_KEEP) { "  kept $dir" } else { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}
"$script:pass passed, $script:fail failed."
if ($script:fail -gt 0) { exit 1 }
