# W5 VIDEO page (dash\www\v2\workbench-video.js, docs\DESIGN-workbench.md 3 and 4): his own lap clip inside the analysis workbench, in sync with every display.
# A pretend clip (ffmpeg testsrc2, 60 fps h264, a 32-block binary clock and a readable clock burned into every picture = the picture says which video time it is)
# is placed in the SCRATCH vault (vault-test\, the recorder's test path, never Peter's Vault) with a sidecar tied to a REAL lap: lap 7 (79.549, the PB) of
# "chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt". Headless Chrome 1920x1080 opens the workbench against the running irdash and checks:
#   the tab exists only with a clip - the video time = lapStartOffset + the lap's time at the cursor (5 points, T1's brake point among them, to 1/60 s, and the
#   picture on screen says the same) - a click on a trace, a corner jump and an event jump seek it - playing 3 s at 1x and 2x moves the cursor the right distance and
#   the cursor equals the video - the deck's PLAY works - outside the clip the nearest picture is shown and says so - two-up with the reference's clip - the small
#   video (key V) on the other pages - no overlaps, no JS errors. Pictures: tests\shots\wb-video.png, wb-video-two.png, wb-video-pip.png.
# Out of the car only (guard.ps1). The file-name form of the lap id ("<file>.ibt:<lap>") needs an irdash built after dash\src\recorder.cs / vault.cs were last
# changed; if the shipped irdash.exe is older, that part says so and is skipped.
#   powershell -ExecutionPolicy Bypass -File tests\video-page-test.ps1 [-Keep]
param([switch]$Keep)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = if ($env:VAULT_TEST_API) { $env:VAULT_TEST_API } else { 'http://localhost:8199' }
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Note($what) { "  info  $what" }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
function J($path) { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 120; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
function Q($s) { [uri]::EscapeDataString($s) }
function NowMs { [long](([DateTime]::UtcNow - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalMilliseconds) }
function Code($path) { try { return [int](Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 30).StatusCode } catch [Net.WebException] { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } return 0 } }

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; $title }
$me = Get-Process -Id $PID; $me.PriorityClass = 'BelowNormal'
$cores = [Environment]::ProcessorCount
if ($cores -gt 2) { $mask = [int64]0; for ($i = 0; $i -lt 2; $i++) { $mask = $mask -bor ([int64]1 -shl ($cores - 1 - $i)) }; $me.ProcessorAffinity = [IntPtr]$mask }

$ffmpeg = Join-Path $root 'vault\bin\ffmpeg.exe'
$tdir = Join-Path $root 'vault-test'; $srcDir = Join-Path $tdir 'src'; $clipDir = Join-Path $tdir 'vault\clips'
$hook = Join-Path $root 'dash\test-hook.on'; $lock = Join-Path $root 'dash\deploy.lock'
$tmp = Join-Path $env:TEMP ('video-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$pbName = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt'
$shipped = Join-Path $root 'dash\irdash.exe'
$srcNew = (@('recorder.cs', 'vault.cs', 'workbench.cs') | ForEach-Object { (Get-Item -LiteralPath (Join-Path $root ('dash\src\' + $_))).LastWriteTimeUtc } | Sort-Object -Descending | Select-Object -First 1)
$fileForm = (Get-Item -LiteralPath $shipped).LastWriteTimeUtc -ge $srcNew       # does the running irdash know "<file>.ibt:<lap>"?

# a second, independent reader of the .ibt (never Paddock's own code): for the hand check of the lap's time at two places
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.IO; using System.Text;
public static class VidRaw {
  public static Dictionary<string,double[]> All(string file, string[] names) {
    byte[] b = File.ReadAllBytes(file);
    int bl = BitConverter.ToInt32(b, 36), bo = BitConverter.ToInt32(b, 52), rc = BitConverter.ToInt32(b, 140), nv = BitConverter.ToInt32(b, 24), vho = BitConverter.ToInt32(b, 28);
    var vars = new Dictionary<string,int[]>();
    for (int i = 0; i < nv; i++) { int p = vho + 144 * i; vars[Encoding.ASCII.GetString(b, p + 16, 32).Trim('\0')] = new int[] { BitConverter.ToInt32(b, p), BitConverter.ToInt32(b, p + 4) }; }
    var want = new List<string>(names); if (!want.Contains("Lap")) want.Add("Lap"); if (!want.Contains("IsOnTrack")) want.Add("IsOnTrack");
    var cols = new Dictionary<string,double[]>(); foreach (var k in want) cols[k] = new double[rc];
    for (int r = 0; r < rc; r++) {
      int bs = bo + r * bl;
      foreach (var k in want) { var v = vars[k]; double x = 0; switch (v[0]) { case 0: case 1: x = b[bs + v[1]]; break; case 2: case 3: x = BitConverter.ToInt32(b, bs + v[1]); break; case 4: x = BitConverter.ToSingle(b, bs + v[1]); break; case 5: x = BitConverter.ToDouble(b, bs + v[1]); break; } cols[k][r] = x; }
    }
    return cols;
  }
}
'@
function Lap-Idx($raw, $lap) { $a = $raw['Lap']; $o = $raw['IsOnTrack']; $ix = New-Object System.Collections.Generic.List[int]; for ($i = 0; $i -lt $a.Length; $i++) { if ($o[$i] -ne 0 -and [int]$a[$i] -eq $lap) { $ix.Add($i) } }; return , $ix.ToArray() }
function Time-At($raw, $ix, $target) {
  $p = $raw['LapDistPct']; $t = $raw['SessionTime']
  for ($k = 1; $k -lt $ix.Length; $k++) { $a = $ix[$k - 1]; $b = $ix[$k]; if ($p[$a] -lt $target -and $p[$b] -ge $target) { return $t[$a] + ($t[$b] - $t[$a]) * ($target - $p[$a]) / ($p[$b] - $p[$a]) } }
  return $null
}

# ---- headless Chrome with the DevTools protocol (JS errors are collected) ----
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('video-test-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9376
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
function Cdp-Key($key, $code, $text) { $null = Cdp 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = $key; code = $code; text = $text; windowsVirtualKeyCode = 0 }; $null = Cdp 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = $key; code = $code } }
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Cdp-Mouse($type, $x, $y) { $null = Cdp 'Input.dispatchMouseEvent' @{ type = $type; x = $x; y = $y; button = $(if ($type -eq 'mouseMoved') { 'none' } else { 'left' }); clickCount = $(if ($type -eq 'mouseMoved') { 0 } else { 1 }) } }
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# the helpers the page-side steps use: move the cursor and wait until every picture has arrived, play for a while and measure
$helperJs = @'
window.T = (function () {
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function raf() { return new Promise(function (r) { requestAnimationFrame(function () { requestAnimationFrame(r); }); }); }
  function D() { return WB.data(); }
  function busy() { var v = WB.video(); return !!((v.lap && v.lap.seeking) || (v.ref && v.ref.seeking)); }
  async function settle() { await raf(); var t0 = performance.now(); while (performance.now() - t0 < 8000) { if (!busy()) { await raf(); if (!busy()) break; } await sleep(30); } await sleep(160); }
  function tat(arr, fi) { var i = Math.floor(fi); if (i < 0) return arr[0]; if (i >= arr.length - 1) return arr[arr.length - 1]; return arr[i] + (arr[i + 1] - arr[i]) * (fi - i); }
  function snap(i) {       // i may be fractional (a click puts the cursor between two samples)
    var v = WB.video(), d = D(), o = { i: i, t: tat(d.A.t, i), off: v.lap.off, time: v.lap.time, target: v.lap.target, dur: v.lap.dur, range: v.lap.range, clock: WB.videoClock('lap'), cur: v.cur, curT: v.curT };
    if (v.ref) o.ref = { time: v.ref.time, target: v.ref.target, off: v.ref.off, rt: tat(d.R.t, Math.max(0, Math.min(d.n - 1, i - (WB.state.offsetM || 0) / d.step))), clock: WB.videoClock('ref'), range: v.ref.range };
    return o;
  }
  async function go(i) { WB.cmd('cursor', i); await settle(); return snap(i); }
  function here() { return snap(WB.state.cur); }
  function t1() { var b = D().A.c.Brake; for (var i = 100; i < D().n; i++) if (b[i] > 0.1 && b[i - 1] <= 0.1) return i; return -1; }
  function idxAtTime(t) { var a = D().A.t, lo = 0, hi = a.length - 1; while (lo + 1 < hi) { var m = (lo + hi) >> 1; if (a[m] <= t) lo = m; else hi = m; } return lo + (a[hi] > a[lo] ? (t - a[lo]) / (a[hi] - a[lo]) : 0); }
  // play at speed sp for secs of wall time starting at lap index i0; measure wall time, video time and where the cursor ended
  async function play(sp, secs, i0) {
    WB.cmd('speed', String(sp)); WB.cmd('cursor', i0); await settle();
    var v0 = WB.video(), c0 = v0.cur, t0 = v0.lap.time, w0 = performance.now(), first = null, maxLag = 0, maxPic = 0, maxClk = 0, nClk = 0, n = 0, nPic = 0;
    WB.cmd('play');
    while (performance.now() - w0 < secs * 1000) {
      await raf(); var v = WB.video(); n++;
      if (v.lap.running && first === null) first = performance.now() - w0;
      if (v.lap.running && performance.now() - w0 > 600) {
        var lag = Math.abs((v.curT + v.lap.off) - v.lap.time); if (lag > maxLag) maxLag = lag;                       // cursor vs video.currentTime, every frame
        if (v.lap.rvOn && v.lap.media === v.lap.media) { nPic++; var pl = Math.abs((v.curT + v.lap.off) - v.lap.media); if (pl > maxPic) maxPic = pl; }   // cursor vs the picture really on screen
        var ck = WB.videoClock("lap"); if (ck !== null) { nClk++; var cl = Math.abs(ck - (v.curT + v.lap.off) * 1000); if (cl > maxClk) maxClk = cl; }          // cursor vs the clock burned into the picture that is in the video element right now
      }
    }
    var w1 = performance.now(), mid = WB.video(), midState = { playing: WB.state.playing, running: mid.lap.running, paused: mid.lap.paused, drives: mid.drives, rvOn: mid.lap.rvOn, rate: mid.lap.rate };
    WB.cmd('pause'); await raf(); await sleep(250); var end = WB.video(), refLag = null;
    var o = { wall: (w1 - w0) / 1000, dv: mid.lap.time - t0, startedMs: first, maxLag: maxLag, maxPic: maxPic, nPic: nPic, maxClk: maxClk, nClk: nClk, frames: n, mid: midState, c0: c0, c1: mid.cur, t0: D().A.t[Math.round(c0)], t1: mid.curT, midTime: mid.lap.time, midOff: mid.lap.off, endTime: end.lap.time, endTarget: end.lap.target, endPaused: end.lap.paused, endRunning: end.lap.running, step: D().step, playing: WB.state.playing, n: D().n };
    if (mid.ref) o.refErr = Math.abs(mid.ref.time - mid.ref.target);
    if (end.ref) o.refEndErr = Math.abs(end.ref.time - end.ref.target);
    return o;
  }
  return { sleep: sleep, raf: raf, settle: settle, go: go, snap: snap, here: here, t1: t1, play: play, idxAtTime: idxAtTime };
})(); 1
'@

function Open-Wb($query) {
  $url = "$api/v2/workbench.html?$query"
  if (-not $script:cdp) { Cdp-Open $url } else { $null = Cdp-Eval 'window.__old = 1; 1'; $null = Cdp 'Page.navigate' @{ url = $url } }
  for ($i = 0; $i -lt 200; $i++) { Start-Sleep -Milliseconds 250; if ((Cdp-Eval '(!window.__old && window.WB && (WB.extras || WB.error)) ? 1 : 0') -eq 1) { break } }
  Start-Sleep -Milliseconds 600
  $null = Cdp-Eval $helperJs
}
function Pages() { return @(Cdp-Obj 'WB.pages()') }

$logFile = Join-Path $root 'dash\irdash.log'
$swAll = [Diagnostics.Stopwatch]::StartNew()
'Video page test'
Enter-TestLock 'video-page'   # one live test at a time (tests\guard.ps1); released in finally
try {
  for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock (' + (Get-Content $lock) + ')'; Start-Sleep -Seconds 60 }
  Set-Content $lock ('video-page ' + (Get-Date).ToString('HH:mm:ss'))
  Set-Content $hook 'video page test'
  if (Test-Path $tdir) { Remove-Item $tdir -Recurse -Force }
  New-Item -ItemType Directory -Force $srcDir | Out-Null
  $null = J '/vault/test/sandbox?on=1&reset=1'

  # =====================================================================================================
  Section '1. a pretend clip tied to a real lap (lap 7 of the PB session), placed in the scratch vault'
  Check 'the PB session telemetry file is on this PC' (Test-Path (Join-Path $tel $pbName))
  Check 'ffmpeg is on this PC (vault\bin)' (Test-Path $ffmpeg)
  Copy-Item (Join-Path $tel $pbName) (Join-Path $srcDir $pbName) -Force; (Get-Item (Join-Path $srcDir $pbName)).LastWriteTime = (Get-Item (Join-Path $tel $pbName)).LastWriteTime
  $null = J '/vault/test/scan'; $lst = J '/vault/list'
  $m7 = @($lst.moments | Where-Object { $_.kind -eq 'lap' -and $_.lap -eq 7 -and $_.lapTime -gt 0 })[0]
  Check 'the scratch vault has lap 7 of that session as a Vault lap' ($null -ne $m7)
  if (-not $m7) { throw 'no lap 7 in the scratch vault' }
  $lapTime = [double]$m7.lapTime; $car = [string]$m7.car; $track = [string]$m7.track; $config = [string]$m7.config
  Note "Vault lap $($m7.id): lap 7, $lapTime s, $car / $track / $config"
  $lead = 2.1; $dur = [math]::Round($lead + $lapTime + 1.5, 2)
  # the pretend screen: testsrc2 at 60 fps; the 32-block clock at the top-left is the picture's own video time in ms (what the recorder's test source does)
  $graph = "testsrc2=size=960x540:rate=60,split=2[a][b];[b]crop=640:32:0:0,format=yuv420p,geq=lum='255*mod(floor(floor(T*1000)/pow(2,floor(X/20))),2)':cb=128:cr=128[c];[a][c]overlay=0:0,drawtext=text='%{pts\:hms}':x=10:y=60:fontsize=48:fontcolor=white:box=1:boxcolor=black@0.7"
  [IO.File]::WriteAllText((Join-Path $tmp 'graph.txt'), $graph, (New-Object Text.UTF8Encoding($false)))
  $mp4 = Join-Path $tmp 'pretend.mp4'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $pr = Start-Process -FilePath $ffmpeg -ArgumentList @('-hide_banner', '-y', '-loglevel', 'error', '-/filter_complex', (Join-Path $tmp 'graph.txt'), '-t', "$dur", '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-g', '30', '-bf', '0', '-crf', '30', '-movflags', '+faststart', '-an', $mp4) -WindowStyle Hidden -Wait -PassThru
  Check "ffmpeg made a $dur s pretend clip ($([math]::Round((Get-Item $mp4).Length / 1MB, 1)) MB, $([math]::Round($sw.Elapsed.TotalSeconds, 0)) s)" ($pr.ExitCode -eq 0 -and (Test-Path $mp4))
  function Put-Clip([string]$id, [int]$lap, [double]$lt, [double]$startOff, [long]$startMs, [bool]$trunc) {
    Copy-Item $mp4 (Join-Path $clipDir "$id.mp4") -Force
    $j = [ordered]@{ id = $id; lap = [int]$lap; lapTime = [math]::Round($lt, 3); lapStartMs = [long]$startMs; lapEndMs = [long]($startMs + $lt * 1000); clipStartMs = [long]($startMs - $startOff * 1000); lapStartOffset = [double]$startOff; lapEndOffset = [double]($startOff + $lt);
      videoStart = 0.0; duration = [double]$dur; fps = 60; rotation = 0; encoder = 'libx264'; car = $car; track = $track; config = $config; sessionTime = 0.0; why = 'test'; keep = $false; pb = $true; truncated = [bool]$trunc; created = (NowMs); size = (Get-Item (Join-Path $clipDir "$id.mp4")).Length }
    ($j | ConvertTo-Json -Compress) | Set-Content (Join-Path $clipDir "$id.json") -Encoding UTF8
  }
  New-Item -ItemType Directory -Force $clipDir | Out-Null
  $id7 = 'rec-20261010-001500-l7'
  Put-Clip $id7 7 $lapTime $lead ([long]$m7.startMs) $false
  $ri = J '/vault/test/rec?cmd=reindex'
  Check 'the recorder picked the clip up (reindex)' ($ri.ok -eq $true -and $ri.clips -eq 1)
  $vi = J "/vault/videoinfo?id=$($m7.id)"
  Check '/vault/videoinfo on the Vault lap id gives the sidecar: lap 7, lapStartOffset 2.1, lapEndOffset = start + lap time' ($vi.id -eq $id7 -and $vi.lap -eq 7 -and (Near $vi.lapStartOffset $lead 0.0001) -and (Near ($vi.lapEndOffset - $vi.lapStartOffset) $lapTime 0.002))
  Check '/vault/video?id=<the Vault lap id> serves the mp4' ((Code "/vault/video?id=$($m7.id)") -eq 200)
  if ($fileForm) {
    $vf = J ("/vault/videoinfo?id=" + (Q "$pbName`:7"))
    Check 'the lap named by its telemetry FILE ("<file>.ibt:7") finds the same clip (what the Session Review and the Workbench open)' ($vf.id -eq $id7)
    Check '... lap 8 of that file has no clip: 404' ((Code ("/vault/videoinfo?id=" + (Q "$pbName`:8"))) -eq 404)
    Check '... an unknown file, a path and a bad lap number answer 404, never a file' ((Code ("/vault/videoinfo?id=" + (Q 'nothing 2020-01-01 00-00-00.ibt:7'))) -eq 404 -and (Code ("/vault/videoinfo?id=" + (Q '..\..\dash\irdash.ini.ibt:7'))) -eq 404 -and (Code ("/vault/videoinfo?id=" + (Q "$pbName`:x"))) -eq 404 -and (Code ("/vault/videoinfo?id=" + (Q "$pbName`:0"))) -eq 404)
  } else { Note 'dash\irdash.exe is older than recorder.cs / vault.cs: the "<file>.ibt:<lap>" lookup is not in the running build yet - the lead deploys with dash\build.ps1; the page then opens by the Vault lap id instead' }
  $openId = if ($fileForm) { $pbName } else { [string]$m7.id }
  $q7 = "id=$(Q $openId)&lap=7"

  # =====================================================================================================
  Section '2. the VIDEO tab: only when the lap has a clip'
  Open-Wb "$q7&page=driver"
  $err = Cdp-Eval 'WB.error || ""'
  Check "the workbench opened lap 7 with no error ($err)" ($err -eq '')
  $pg = Pages
  $pgNoCareer = @($pg | Where-Object { $_ -ne 'career' -and $_ -ne 'pro' })      # W6c: a CAREER tab follows the others when this car and track have 2 or more sessions (the real telemetry has); P3: the PRO tab is always the last
  Check 'VIDEO is the last of the tabs when the lap has a clip (the 7th page; CAREER, when there is one, and PRO come after it)' (($pgNoCareer -join ',') -eq 'driver,grip,braking,tyres,suspension,splits,video' -or ($pgNoCareer[-1] -eq 'video' -and $pgNoCareer.Count -ge 3))
  $tabs = [string](Cdp-Eval 'document.getElementById("tabs").innerText')
  Check 'the tab row shows VIDEO' ($tabs -match 'VIDEO')
  $v = Cdp-Obj 'WB.video()'
  Check 'the clip loaded: it plays in Chrome (960x540, the length of the pretend clip) and the sidecar offset is the one in the sidecar' ($v.lap.ok -and $v.lap.w -eq 960 -and $v.lap.h -eq 540 -and (Near $v.lap.dur $dur 0.1) -and (Near $v.lap.off $lead 0.0001))
  Check 'the SMALL VIDEO chip is offered on DRIVER (and not on the VIDEO page)' ((Cdp-Eval 'document.getElementById("pipbtn").style.display') -eq '')
  # deck: the page list the ANALYSIS screen builds its page keys from
  Start-Sleep -Milliseconds 900
  $ds = Invoke-RestMethod "$api/workbench/state" -TimeoutSec 8
  Check 'the deck is told about the 7th page (/workbench/state pages)' (@($ds.pages) -contains 'video')
  $plug = Get-Content (Join-Path $root 'deck-intro\plugin.html') -Raw
  Check 'deck-intro\plugin.html lays out the ANALYSIS page row by the current rule (more than 8 pages: the first 7 + a PAGES key; 8 or fewer: all shown, filled to 8 keys) and names an unknown page by its upper-case id (VIDEO)' ($plug -match 'const all = a\.pages \|\| \[\]' -and $plug -match 'more = all\.length > WB_ROW' -and $plug -match 'pages = more \? all\.slice\(0, WB_ROW - 1\) : all' -and $plug -match 'wide = more \? 0 : Math\.min\(pages\.length, 8 - pages\.length\)' -and $plug -match "add\(WB_ROW - 1, 3, 1, 1, 'PAGES'" -and $plug -match 'WB_PAGES\[id\] \|\| String\(id\)\.toUpperCase\(\)')
  # a lap WITHOUT a clip: no tab, no chip, no dead button
  Open-Wb "id=$(Q $openId)&lap=8&page=driver"
  $err8 = Cdp-Eval 'WB.error || ""'
  if ($err8 -eq '') {
    $pg8 = Pages; $tabs8 = [string](Cdp-Eval 'document.getElementById("tabs").innerText')
    Check 'lap 8 has no clip: no VIDEO tab, no SMALL VIDEO chip, key 7 / V do nothing' (($pg8 -notcontains 'video') -and $tabs8 -notmatch 'VIDEO' -and (Cdp-Eval 'document.getElementById("pipbtn").style.display') -eq 'none' -and (Cdp-Obj 'WB.video()').lap -eq $null)
    $null = Cdp-Eval 'WB.cmd("page","video"); 1'; Start-Sleep -Milliseconds 300
    Check 'asking for the VIDEO page on a lap without a clip stays on the page it was on' ((Cdp-Obj 'WB.state.page') -eq 'driver')
  } else { Note "lap 8 is not a full lap here ($err8): the no-clip check uses the first lap of the file that opens"; Check 'a lap without a clip was found' $false }

  # =====================================================================================================
  Section '3. sync: video time = lapStartOffset + the lap''s time at the cursor (5 points, T1''s brake point among them)'
  Open-Wb "$q7&page=video&ref=pb"
  Check 'the page opened on VIDEO (page=video) and one video is shown (the reference has no clip: not two-up)' ((Cdp-Obj 'WB.state.page') -eq 'video' -and (Cdp-Obj 'WB.video().lap.shown') -eq $true -and (Cdp-Obj 'WB.video().ref') -eq $null)
  $n = [int](Cdp-Eval 'WB.data().n'); $step = [double](Cdp-Eval 'WB.data().step'); $lenM = [double](Cdp-Eval 'WB.data().L')
  $iT1 = [int](Cdp-Eval 'T.t1()')
  Note "the lap has $n distance samples, the line to line time is $lapTime; T1's brake point is at sample $iT1 ($([math]::Round($iT1 * $step)) m)"
  $pts = @(0, $iT1, [int]($n * 0.5), [int]($n * 0.75), ($n - 1))
  $snaps = @(); foreach ($i in $pts) { $snaps += , (Cdp-Obj "T.go($i)") }
  foreach ($s in $snaps) {
    $exp = $lead + $s.t
    Check ("cursor at sample $($s.i) ($([math]::Round($s.i * $step)) m, lap time $([math]::Round($s.t, 3)) s): video.currentTime $([math]::Round($s.time, 4)) = lapStartOffset + t = $([math]::Round($exp, 4)) (within 1/60 s)") (Near $s.time $exp (1 / 60))
    Check ("   ... and the picture on screen says $($s.clock) ms (expected $([math]::Round($exp * 1000)) ms, one frame = 17 ms)") ($null -ne $s.clock -and (Near $s.clock ($exp * 1000) 18))
  }
  Check 'the lap time at the last sample is the official lap time (the end of the lap is the end of the line-to-line time)' (Near $snaps[-1].t $lapTime 0.01)
  # hand check from the raw records: the time between T1's brake point and mid-lap, read from the .ibt itself, equals the video time between those two cursor places
  $raw = [VidRaw]::All((Join-Path $tel $pbName), @('SessionTime', 'LapDistPct'))
  $ix7 = Lap-Idx $raw 7
  $tA = Time-At $raw $ix7 (($pts[1] * $step) / $lenM); $tB = Time-At $raw $ix7 (($pts[2] * $step) / $lenM)
  if ($null -ne $tA -and $null -ne $tB) {
    $rawDt = $tB - $tA; $vidDt = $snaps[2].time - $snaps[1].time
    Note "HAND CHECK: raw .ibt says $([math]::Round($rawDt, 3)) s from T1's brake point to the middle; the video moved $([math]::Round($vidDt, 3)) s between those two cursor places"
    Check 'the video time between two places equals the time the raw telemetry records between them (to 25 ms: the engine puts the lap on a 1 m grid)' (Near $rawDt $vidDt 0.025)
  } else { Check 'raw records found for the hand check' $false }

  # clicking a trace, a corner and an event jump
  Section '3b. a click on a trace, a corner jump and an event jump seek the video'
  $info = Cdp-Obj '(function(){ var d = WB.displays().filter(function(x){ return x.kind === "traces"; })[0]; return { x: d.box.x, y: d.box.y, top: d.top, x0: d.X0, w: d.W, z0: WB.state.z0, z1: WB.state.z1 }; })()'
  $tgt = [int]($n * 0.62)
  $px = [double]$info.x + [double](Cdp-Eval "WB.displays().filter(function(x){return x.kind==='traces'})[0].xOf($tgt)"); $py = [double]$info.y + [double]$info.top + 40
  Cdp-Mouse 'mouseMoved' ($px - 200) $py; Start-Sleep -Milliseconds 150
  Cdp-Mouse 'mouseMoved' $px $py; Start-Sleep -Milliseconds 100; Cdp-Mouse 'mousePressed' $px $py; Cdp-Mouse 'mouseReleased' $px $py
  $null = Cdp-Eval 'T.settle()'; $s = Cdp-Obj 'T.here()'
  Check "a click on the speed trace at sample $tgt puts the cursor there (it is at $([math]::Round($s.cur, 1))) and the video at lapStartOffset + t = $([math]::Round($lead + $s.t, 3)) (it shows $([math]::Round($s.time, 3)))" ((Near $s.cur $tgt 3) -and (Near $s.time ($lead + $s.t) (1 / 60)) -and (Near $s.clock (($lead + $s.t) * 1000) 18))
  $null = Cdp-Eval 'WB.cmd("cursor", 5); 1'; $null = Cdp-Eval 'T.settle()'
  $null = Cdp-Eval 'WB.cmd("next-corner"); 1'; $null = Cdp-Eval 'T.settle()'; $s = Cdp-Obj 'T.here()'
  Check "the deck's NEXT CORNER moves the cursor to sample $([math]::Round($s.cur)) (the first apex) and the video follows: $([math]::Round($s.time, 3)) = $([math]::Round($lead + $s.t, 3))" ($s.cur -gt 100 -and (Near $s.time ($lead + $s.t) (1 / 60)) -and (Near $s.clock (($lead + $s.t) * 1000) 18))
  $null = Cdp-Eval 'WB.cmd("next-event"); 1'; $null = Cdp-Eval 'T.settle()'; $s2 = Cdp-Obj 'T.here()'
  Check "the deck's NEXT EVENT jumps to sample $([math]::Round($s2.cur)) and the video follows: $([math]::Round($s2.time, 3)) = $([math]::Round($lead + $s2.t, 3))" ($s2.cur -ne $s.cur -and (Near $s2.time ($lead + $s2.t) (1 / 60)) -and (Near $s2.clock (($lead + $s2.t) * 1000) 18))
  Cdp-Key 'ArrowRight' 'ArrowRight' ''; $null = Cdp-Eval 'T.settle()'; $s3 = Cdp-Obj 'T.here()'
  Check "a keyboard step (right arrow) moves the video by one sample's worth of time: $([math]::Round($s3.time - $s2.time, 4)) s" ((Near $s3.time ($lead + $s3.t) (1 / 60)) -and $s3.time -gt $s2.time)

  # =====================================================================================================
  Section '4. playing: the video is the clock and the cursor follows it (1x and 2x), the cursor equals the video every frame'
  $i0 = [int](Cdp-Eval 'Math.round(T.idxAtTime(10))')
  foreach ($sp in 1, 2) {
    $p = Cdp-Obj "T.play($sp, 3, $i0)"
    $expDt = $p.wall * $sp
    Note "x$sp : $([math]::Round($p.wall, 2)) s of wall time, video moved $([math]::Round($p.dv, 2)) s, cursor $($p.c0) -> $([math]::Round($p.c1)) ($([math]::Round(($p.c1 - $p.c0) * $p.step)) m), first frame played after $([math]::Round($p.startedMs)) ms, largest cursor-vs-video gap $([math]::Round($p.maxLag * 1000, 1)) ms, $($p.frames) frames"
    Check "x$sp : the video ran (it was playing, the video was the clock)" ($p.mid.running -eq $true -and $p.mid.paused -eq $false -and $p.mid.drives -eq $true -and (Near $p.mid.rate $sp 0.01))
    Check "x$sp : 3 s of wall time moved the video by $([math]::Round($expDt, 2)) s (+- 0.6 s start-up): it moved $([math]::Round($p.dv, 2)) s" (Near $p.dv $expDt 0.6)
    $dLap = $p.t1 - $p.t0
    Check "x$sp : the cursor moved the same lap time as the video ($([math]::Round($dLap, 2)) s vs $([math]::Round($p.dv, 2)) s) = $([math]::Round(($p.c1 - $p.c0) * $p.step)) m of track" (Near $dLap $p.dv 0.06)
    $lo = [double](Cdp-Eval "T.idxAtTime($($p.t0) + $expDt - 0.6)"); $hi = [double](Cdp-Eval "T.idxAtTime($($p.t0) + $expDt + 0.6)")
    Check "x$sp : the cursor is at sample $([math]::Round($p.c1)), inside the $([math]::Round($lo))..$([math]::Round($hi)) window that $([math]::Round($expDt, 1)) s +- 0.6 s of this lap covers" ($p.c1 -ge $lo -and $p.c1 -le $hi)
    Check "x$sp : every frame the cursor was exactly where the picture on screen is ($($p.nPic) frames read, largest gap $([math]::Round($p.maxPic * 1000, 2)) ms)" ($p.nPic -gt 20 -and $p.maxPic -lt 0.001)
    Check "x$sp : ... and the clock burned into the picture in the video element agrees with the cursor to $([math]::Round($p.maxClk)) ms over $($p.nClk) frames (one frame is 17 ms, 2x moves 33 ms per frame)" ($p.nClk -gt 20 -and $p.maxClk -lt (40 * $sp))
    Check "x$sp : ... and within 0.1 s of video.currentTime, which runs ahead of the picture by the frames in flight ($([math]::Round($p.maxLag * 1000, 1)) ms)" ($p.maxLag -lt 0.1)
    Check "x$sp : paused again: the video is paused, and the picture is the cursor's ($([math]::Round($p.endTime, 4)) vs $([math]::Round($p.endTarget, 4)))" ($p.endPaused -eq $true -and $p.endRunning -eq $false -and $p.playing -eq $false -and (Near $p.endTime $p.endTarget (1 / 60)))
  }
  foreach ($sp in 0.5, 4) {
    $p = Cdp-Obj "T.play($sp, 2, $i0)"; $expDt = $p.wall * $sp
    Check "x$sp : 2 s of wall time moved the video by $([math]::Round($expDt, 2)) s (+- 0.6 s): it moved $([math]::Round($p.dv, 2)) s, the cursor the same lap time to within one presented frame ($([math]::Round($p.t1 - $p.t0, 2)) s = $([math]::Round(($p.c1 - $p.c0) * $p.step)) m), exactly on the picture ($([math]::Round($p.maxPic * 1000, 2)) ms)" ((Near $p.dv $expDt 0.6) -and (Near ($p.t1 - $p.t0) $p.dv (0.02 + $sp / 60)) -and $p.maxPic -lt 0.001 -and $p.endPaused -eq $true)
  }
  # zoomed in: the playing cursor pages the window on (the engine's rule), the video still is the clock
  $null = Cdp-Eval "WB.cmd('speed','2'); WB.cmd('zoom-reset'); WB.cmd('cursor', 1500); WB.cmd('zoom-in'); WB.cmd('zoom-in'); WB.cmd('zoom-in'); T.settle()"
  $zz = Cdp-Obj "(async function(){ var s0 = { z0: WB.state.z0, z1: WB.state.z1 }; WB.cmd('play'); await T.sleep(3200); WB.cmd('pause'); await T.raf(); var v = WB.video(); return { z0: s0.z0, z1: s0.z1, n0: WB.state.z0, n1: WB.state.z1, cur: WB.state.cur, dt: v.curT - WB.data().A.t[1500], vt: v.lap.time }; })()"
  Check "playing zoomed in (window $([math]::Round($zz.z0))..$([math]::Round($zz.z1)) samples): the window pages on with the cursor ($([math]::Round($zz.n0))..$([math]::Round($zz.n1)), cursor at $([math]::Round($zz.cur))) and keeps its width" ($zz.n0 -gt $zz.z0 + 50 -and $zz.cur -ge $zz.n0 -and $zz.cur -le $zz.n1 -and (Near ($zz.n1 - $zz.n0) ($zz.z1 - $zz.z0) 1))
  $null = Cdp-Eval "WB.cmd('zoom-reset'); WB.cmd('speed','1'); 1"
  $rv = Cdp-Obj 'WB.video().lap.rvfc'
  Note "requestVideoFrameCallback in this Chrome: $rv"
  # a click while playing jumps the video there and it plays on
  $null = Cdp-Eval "WB.cmd('speed','1'); WB.cmd('cursor', 300); T.settle()"; $null = Cdp-Eval "WB.cmd('play'); T.sleep(700)"
  $tgt2 = [int]($n * 0.70)
  $px2 = [double]$info.x + [double](Cdp-Eval "WB.displays().filter(function(x){return x.kind==='traces'})[0].xOf($tgt2)")
  Cdp-Mouse 'mouseMoved' $px2 $py; Cdp-Mouse 'mousePressed' $px2 $py; Cdp-Mouse 'mouseReleased' $px2 $py
  $null = Cdp-Eval 'T.sleep(900)'; $sj = Cdp-Obj '(function(){ var v = WB.video(); return { cur: v.cur, curT: v.curT, time: v.lap.time, off: v.lap.off, running: v.lap.running, playing: WB.state.playing }; })()'
  Check "a click on the trace while it plays jumps there (sample $tgt2) and it plays on (cursor now $([math]::Round($sj.cur)), video $([math]::Round($sj.time, 2)) s = lapStartOffset + $([math]::Round($sj.curT, 2)))" ($sj.cur -ge $tgt2 -and $sj.cur -lt $tgt2 + 900 -and $sj.running -eq $true -and $sj.playing -eq $true -and (Near ($sj.curT + $sj.off) $sj.time 0.05))
  $null = Cdp-Eval "WB.cmd('pause'); 1"
  # the deck's PLAY / PAUSE key (/api/do?c=wb-toggle-play -> the page polls it): it drives the video too
  $null = Cdp-Eval "WB.cmd('cursor', 400); T.settle()"
  $t0v = [double](Cdp-Eval 'WB.video().lap.time')
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/do?c=wb-toggle-play" -TimeoutSec 8; Start-Sleep -Milliseconds 2200
  $dv = Cdp-Obj '(function(){ var v = WB.video(); return { time: v.lap.time, running: v.lap.running, playing: WB.state.playing }; })()'
  Check "the deck's PLAY key starts it: the video is running and has moved $([math]::Round($dv.time - $t0v, 2)) s in about 2 s" ($dv.running -eq $true -and $dv.playing -eq $true -and ($dv.time - $t0v) -gt 0.8)
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/do?c=wb-toggle-play" -TimeoutSec 8; Start-Sleep -Milliseconds 1200
  $dv2 = Cdp-Obj '(function(){ var v = WB.video(); return { time: v.lap.time, target: v.lap.target, paused: v.lap.paused, running: v.lap.running, playing: WB.state.playing }; })()'
  Check "the deck's PAUSE key stops it: video paused on the cursor's picture ($([math]::Round($dv2.time, 3)) vs $([math]::Round($dv2.target, 3)))" ($dv2.paused -eq $true -and $dv2.playing -eq $false -and (Near $dv2.time $dv2.target (1 / 60)))
  # the end of the lap: it stops by itself at the line
  $null = Cdp-Eval "WB.cmd('speed','1'); WB.cmd('cursor', Math.round(T.idxAtTime(WB.data().A.t[WB.data().n - 1] - 1.2))); T.settle(); WB.cmd('play'); T.sleep(2600)"
  $en = Cdp-Obj '(function(){ var v = WB.video(); return { cur: v.cur, n: WB.data().n, playing: WB.state.playing, paused: v.lap.paused, time: v.lap.time, target: v.lap.target }; })()'
  Check "playing off the end of the lap stops at the line by itself (cursor $([math]::Round($en.cur)) of $($en.n - 1), video paused)" ($en.playing -eq $false -and $en.cur -ge $en.n - 2 -and $en.paused -eq $true)

  # =====================================================================================================
  Section '5. outside the clip: the nearest picture is shown and the page says so'
  Put-Clip $id7 7 $lapTime -2.0 ([long]$m7.startMs) $true
  $null = J '/vault/test/rec?cmd=reindex'
  Open-Wb "$q7&page=video"
  $sA = Cdp-Obj 'T.go(0)'
  $warnA = [string](Cdp-Eval '(document.querySelector(".ph .warn") || {}).textContent || ""')
  Check "a clip that begins after the lap began (lapStartOffset -2 s, truncated): at the line the page shows the first picture (video at $([math]::Round($sA.time, 3)) s, wanted -2) and says so in small words ('$warnA')" ($sA.range -eq -1 -and $sA.time -lt 0.05 -and $warnA -match 'before the video')
  $sA2 = Cdp-Obj "T.go($([int]($n * 0.5)))"; $warnA2 = [string](Cdp-Eval '(document.querySelector(".ph .warn") || {}).textContent || ""')
  Check 'further into the lap the clip covers it again: no warning, the picture follows' ($sA2.range -eq 0 -and $warnA2 -eq '' -and (Near $sA2.time (-2.0 + $sA2.t) (1 / 60)))
  Put-Clip $id7 7 $lapTime 20.0 ([long]$m7.startMs) $true
  $null = J '/vault/test/rec?cmd=reindex'
  Open-Wb "$q7&page=video"
  $sB = Cdp-Obj "T.go($($n - 1))"; $warnB = [string](Cdp-Eval '(document.querySelector(".ph .warn") || {}).textContent || ""')
  Check "a clip that ends before the lap does (lap ends at 99.5 s of an $dur s clip): at the finish the page shows the last picture (video at $([math]::Round($sB.time, 2)) s) and says so ('$warnB')" ($sB.range -eq 1 -and (Near $sB.time $sB.dur 0.05) -and $warnB -match 'after the video')
  Put-Clip $id7 7 $lapTime $lead ([long]$m7.startMs) $false
  $null = J '/vault/test/rec?cmd=reindex'
  # a sidecar for a different lap length is not shown (a wrong clip is worse than none)
  $bad = Get-Content (Join-Path $clipDir "$id7.json") -Raw | ConvertFrom-Json; $bad.lapEndOffset = $bad.lapStartOffset + $lapTime + 9.0; $bad.truncated = $false
  ($bad | ConvertTo-Json -Compress) | Set-Content (Join-Path $clipDir "$id7.json") -Encoding UTF8; $null = J '/vault/test/rec?cmd=reindex'
  Open-Wb "$q7&page=driver"
  Check 'a clip whose sidecar is 9 s longer than the lap (not this lap''s clip) gets no tab' ((Pages) -notcontains 'video')
  # a file that is not a playable video (a cut-off or damaged mp4): no tab either, never a dead button
  Put-Clip $id7 7 $lapTime $lead ([long]$m7.startMs) $false
  [IO.File]::WriteAllBytes((Join-Path $clipDir "$id7.mp4"), ([byte[]](1..4000 | ForEach-Object { ($_ * 37) % 251 }))); $null = J '/vault/test/rec?cmd=reindex'
  Open-Wb "$q7&page=video"
  Check 'a clip file that does not play (damaged) gets no tab, and asking for the page stays on DRIVER' ((Pages) -notcontains 'video' -and (Cdp-Obj 'WB.state.page') -eq 'driver' -and (Cdp-Obj 'document.getElementById("pipbtn").style.display') -eq 'none')
  Put-Clip $id7 7 $lapTime $lead ([long]$m7.startMs) $false; $null = J '/vault/test/rec?cmd=reindex'

  # =====================================================================================================
  Section '6. the layout: one clip (large) and two-up with the reference''s clip'
  Open-Wb "$q7&page=video&ref=pb"
  $null = Cdp-Eval 'WB.cmd("cursor", T.t1()); 1'; $null = Cdp-Eval 'T.settle()'
  $lay = Cdp-Obj '(function(){
    var r = function (e) { var b = e.getBoundingClientRect(); return { x: b.left, y: b.top, w: b.width, h: b.height, r: b.right, b: b.bottom }; };
    var panels = [].map.call(document.querySelectorAll("#page .panel"), function (p) { var o = r(p); o.kind = (p.querySelector("video") ? "video" : p.querySelector(".vt") ? "tiles" : p.querySelector("canvas") ? "canvas" : "other"); return o; });
    var top = [].map.call(document.querySelectorAll(".top > *"), function (e) { var o = r(e); o.id = e.id || e.className; o.shown = getComputedStyle(e).display !== "none"; return o; });
    var v = document.querySelector("#page video"); return { panels: panels, top: top, video: r(v), ov: WB.overlaps(), vw: v.videoWidth, vh: v.videoHeight };
  })()'
  $vp = @($lay.panels | Where-Object { $_.kind -eq 'video' })[0]
  Check "the video is large and keeps its aspect: $([math]::Round($lay.video.w)) x $([math]::Round($lay.video.h)) px on a 1920 x 1080 screen (the clip is $($lay.vw) x $($lay.vh) = 16:9)" ($lay.video.w -ge 1000 -and (Near ($lay.video.w / $lay.video.h) ($lay.vw / $lay.vh) 0.02))
  $overl = @(); $pn = @($lay.panels)
  for ($a = 0; $a -lt $pn.Count; $a++) { for ($b = $a + 1; $b -lt $pn.Count; $b++) { $p1 = $pn[$a]; $p2 = $pn[$b]; if ($p1.x + 1 -lt $p2.r - 1 -and $p2.x + 1 -lt $p1.r - 1 -and $p1.y + 1 -lt $p2.b - 1 -and $p2.y + 1 -lt $p1.b - 1) { $overl += "$($p1.kind)/$($p2.kind)" } } }
  Check "the panels (video, map, numbers, traces) are inside the screen and do not overlap each other ($($pn.Count) panels)" ($overl.Count -eq 0 -and (@($pn | Where-Object { $_.x -lt 0 -or $_.y -lt 0 -or $_.r -gt 1920.5 -or $_.b -gt 1080.5 }).Count -eq 0))
  Check "no text overlaps any other text on the VIDEO page ($($lay.ov.boxes) text boxes measured)" (@($lay.ov.bad).Count -eq 0)
  $vsr = @($lay.top | Where-Object { $_.id -eq 'vs' })[0]
  Check "the header still fits with 7 tabs and the SMALL VIDEO chip: the lap / reference times end at $([math]::Round($vsr.r)) px (screen margin 1888)" ($vsr.r -le 1889)
  $kinds = Cdp-Obj 'WB.displays().map(function(d){ return d.kind; })'
  Check 'the page has the video, the map with the cursor dot, the numbers at the cursor and the shared trace stack' (($kinds -contains 'video') -and ($kinds -contains 'map') -and ($kinds -contains 'vtiles') -and ($kinds -contains 'traces'))
  $tiles = Cdp-Obj '[].map.call(document.querySelectorAll(".vt"), function(t){ return t.children[0].textContent + "=" + t.children[1].textContent; })'
  Note ("numbers at the cursor (T1 brake point): " + ($tiles -join ' | '))
  Check 'six numbers at the cursor: speed, gear, throttle, brake, steering and the gap' (@($tiles).Count -eq 6 -and ($tiles -join ' ') -match 'SPEED' -and ($tiles -join ' ') -match 'GAP')
  Cdp-Shot (Join-Path $shots 'wb-video.png')
  Note 'picture: tests\shots\wb-video.png'

  # two-up: a clip for the reference too. Pick another clean lap of the same file as the reference (the clip is for that lap).
  $other = Cdp-Obj '(function(){ var h = WB.data().head, best = null; h.laps.forEach(function (l) { if (l.clean && l.n !== 7 && l.time && (!best || l.time < best.time)) best = l; }); return best; })()'
  Check "the session has another full lap to use as the reference ($($other.n), $($other.time) s)" ($null -ne $other)
  if (-not $fileForm) { Note 'two-up needs the "<file>.ibt:<lap>" lookup (see section 1): skipped until irdash is deployed' }
  if ($fileForm) {
  $refStart = 3.25
  $idR = "rec-20261010-002500-l$($other.n)"
  Put-Clip $idR $other.n $other.time $refStart ([long]$m7.startMs + 30000) $false
  $null = J '/vault/test/rec?cmd=reindex'
  $refSpec = "$pbName`:$($other.n)"
  Open-Wb "$q7&page=video&ref=$(Q $refSpec)"
  $v2 = Cdp-Obj 'WB.video()'
  Check 'with the reference lap''s clip too the page shows both side by side (two-up)' ($v2.lap.shown -and $v2.ref -and $v2.ref.shown -and $v2.ref.ok -and (Near $v2.ref.off $refStart 0.0001))
  $lay2 = Cdp-Obj '(function(){
    var r = function (e) { var b = e.getBoundingClientRect(); return { x: b.left, y: b.top, w: b.width, h: b.height, r: b.right, b: b.bottom }; };
    var panels = [].map.call(document.querySelectorAll("#page .panel"), function (p) { var o = r(p); o.kind = (p.querySelector("video") ? "video" : p.querySelector(".vt") ? "tiles" : p.querySelector("canvas") ? "canvas" : "other"); return o; });
    var vids = [].map.call(document.querySelectorAll("#page video"), r); return { panels: panels, vids: vids, ov: WB.overlaps() };
  })()'
  Check "two videos of the same size (each $([math]::Round($lay2.vids[0].w)) x $([math]::Round($lay2.vids[0].h)) px), side by side, aspect kept" (@($lay2.vids).Count -eq 2 -and (Near $lay2.vids[0].w $lay2.vids[1].w 1) -and $lay2.vids[0].w -ge 640 -and $lay2.vids[1].x -gt $lay2.vids[0].r)
  $overl2 = @(); $pn2 = @($lay2.panels)
  for ($a = 0; $a -lt $pn2.Count; $a++) { for ($b = $a + 1; $b -lt $pn2.Count; $b++) { $p1 = $pn2[$a]; $p2 = $pn2[$b]; if ($p1.x + 1 -lt $p2.r - 1 -and $p2.x + 1 -lt $p1.r - 1 -and $p1.y + 1 -lt $p2.b - 1 -and $p2.y + 1 -lt $p1.b - 1) { $overl2 += "$($p1.kind)/$($p2.kind)" } } }
  Check "two-up: the panels are inside the screen and do not overlap ($($pn2.Count) panels)" ($overl2.Count -eq 0 -and (@($pn2 | Where-Object { $_.x -lt 0 -or $_.y -lt 0 -or $_.r -gt 1920.5 -or $_.b -gt 1080.5 }).Count -eq 0))
  Check "two-up: no text overlaps any other text ($($lay2.ov.boxes) text boxes measured)" (@($lay2.ov.bad).Count -eq 0)
  foreach ($i in $pts) {
    $s = Cdp-Obj "T.go($i)"
    Check ("two-up, sample $($s.i): lap video $([math]::Round($s.time, 3)) = $([math]::Round($lead + $s.t, 3)); reference video $([math]::Round($s.ref.time, 3)) = $refStart + the reference's time at the same distance = $([math]::Round($refStart + $s.ref.rt, 3)); both pictures agree ($($s.clock) / $($s.ref.clock) ms)") ((Near $s.time ($lead + $s.t) (1 / 60)) -and (Near $s.ref.time ($refStart + $s.ref.rt) (1 / 60)) -and (Near $s.clock (($lead + $s.t) * 1000) 18) -and (Near $s.ref.clock (($refStart + $s.ref.rt) * 1000) 18))
  }
  $p2 = Cdp-Obj "T.play(1, 3, $i0)"
  Note "two-up x1: video moved $([math]::Round($p2.dv, 2)) s in $([math]::Round($p2.wall, 2)) s; reference video was $([math]::Round($p2.refErr * 1000)) ms from its place while playing and $([math]::Round($p2.refEndErr * 1000, 1)) ms after pausing"
  Check 'two-up playing: the lap video drives the cursor as before (3 s moved 3 s +- 0.6)' ((Near $p2.dv ($p2.wall) 0.6) -and $p2.maxPic -lt 0.001 -and $p2.maxLag -lt 0.1)
  Check 'two-up playing: the reference video is kept at its place by distance (within 0.15 s while playing, 1/60 s after the pause)' ($p2.refErr -lt 0.15 -and $p2.refEndErr -lt (1 / 60))
  Cdp-Shot (Join-Path $shots 'wb-video-two.png')
  Note 'picture: tests\shots\wb-video-two.png'
  }

  # =====================================================================================================
  Section '7. the small video on the other pages (key V)'
  Open-Wb "$q7&page=driver&ref=pb"
  $null = Cdp-Eval 'WB.cmd("cursor", T.t1()); 1'
  Check 'the video is not shown on DRIVER until asked for' ((Cdp-Obj 'WB.video().pipOn') -eq $false -and (Cdp-Obj 'WB.video().lap.shown') -eq $false)
  Cdp-Key 'v' 'KeyV' 'v'; Start-Sleep -Milliseconds 700
  $pv = Cdp-Obj 'WB.video()'
  Check "key V shows the small video on DRIVER ($([math]::Round($pv.pipRect.w)) x $([math]::Round($pv.pipRect.h)) px at $([math]::Round($pv.pipRect.x)),$([math]::Round($pv.pipRect.y)), corner $($pv.spot))" ($pv.pip -eq $true -and $pv.pipOn -eq $true -and $pv.lap.shown -eq $true -and $pv.pipRect.w -ge 300 -and $pv.pipRect.r -le 1921)
  $null = Cdp-Eval 'T.settle()'; $ps = Cdp-Obj 'T.here()'
  Check "it follows the cursor: video $([math]::Round($ps.time, 3)) = lapStartOffset + t = $([math]::Round($lead + $ps.t, 3)), picture says $($ps.clock) ms" ((Near $ps.time ($lead + $ps.t) (1 / 60)) -and (Near $ps.clock (($lead + $ps.t) * 1000) 18))
  $ps2 = Cdp-Obj 'T.go(Math.round(WB.data().n * 0.4))'
  Check "... and a new cursor place moves it: sample $($ps2.i) -> video $([math]::Round($ps2.time, 3)) = $([math]::Round($lead + $ps2.t, 3))" (Near $ps2.time ($lead + $ps2.t) (1 / 60))
  # the page picks the corner that covers the least text, measured as the text area it overlaps (a count of boxes is a poor proxy:
  # on GRIP the chosen top-right corner clips 11 boxes only slightly, 2108 px2, while bottom-right covers 3 boxes by 4670 px2)
  $pvArea = Cdp-Obj '(function(){ var v = WB.video(), w = v.pipRect.w, h = v.pipRect.h, spots = [[1888-w,1056-h],[32,1056-h],[1888-w,126],[32,126]], b = WB.textBoxes().concat(WB.domBoxes()), a = []; spots.forEach(function(s){ var t = 0; b.forEach(function(q){ var ox = Math.min(s[0]+w, q.x+q.w) - Math.max(s[0], q.x), oy = Math.min(s[1]+h, q.y+q.h) - Math.max(s[1], q.y); if (ox > 0 && oy > 0) t += ox*oy; }); a.push(Math.round(t)); }); return a; })()'; $sp0 = [int]$pv.spot
  Check "the small video went to the corner that covers the least text on DRIVER (corner $sp0 overlaps the least text area $($pvArea[$sp0]) px2; the other corners: $($pvArea -join ', '))" ($pvArea[$sp0] -eq (($pvArea | Measure-Object -Minimum).Minimum))
  $hdr = Cdp-Obj '(function(){ var m = document.getElementById("mode"), vs = document.querySelector(".vs").getBoundingClientRect(); return { modeW: m.clientWidth, vsR: vs.right, tabs: document.getElementById("tabs").innerText.replace(/\s+/g, " ") }; })()'
  Check "the header keeps at least the room for the mode words it had before there was a VIDEO tab (155 px with 6 tabs and + CHANNEL), now with 7 tabs, + CHANNEL and SMALL VIDEO ($([math]::Round($hdr.modeW)) px free; the right end of the times is at $([math]::Round($hdr.vsR)) px; tabs: $($hdr.tabs))" ($hdr.modeW -ge 155 -and $hdr.vsR -le 1889)
  Cdp-Shot (Join-Path $shots 'wb-video-pip.png'); Note 'picture: tests\shots\wb-video-pip.png'
  Cdp-Key 'V' 'KeyV' 'V'; Start-Sleep -Milliseconds 700
  $pc = Cdp-Obj 'WB.video()'
  Check "Shift+V moves it to the next corner (corner $sp0 -> $($pc.spot)) and it still follows the cursor" ($pc.pipOn -eq $true -and $pc.spot -eq (($sp0 + 1) % 4) -and (Near $pc.lap.time $pc.lap.target (1 / 60)))
  Cdp-Key 'V' 'KeyV' 'V'; Start-Sleep -Milliseconds 500; Cdp-Key 'V' 'KeyV' 'V'; Start-Sleep -Milliseconds 500; Cdp-Key 'V' 'KeyV' 'V'; Start-Sleep -Milliseconds 700
  Check 'Shift+V four times is back where it started' ((Cdp-Obj 'WB.video().spot') -eq $sp0)
  Cdp-Key 'v' 'KeyV' 'v'; Start-Sleep -Milliseconds 400; Cdp-Key 'v' 'KeyV' 'v'; Start-Sleep -Milliseconds 700          # off and on again: back to the automatic corner
  $null = Cdp-Eval 'WB.cmd("page","grip"); 1'; Start-Sleep -Milliseconds 700
  $pg2 = Cdp-Obj 'WB.video()'
  $gArea = Cdp-Obj '(function(){ var v = WB.video(), w = v.pipRect.w, h = v.pipRect.h, spots = [[1888-w,1056-h],[32,1056-h],[1888-w,126],[32,126]], b = WB.textBoxes().concat(WB.domBoxes()), area = [], n = []; spots.forEach(function(s){ var a = 0, k = 0; b.forEach(function(t){ var ox = Math.min(s[0]+w, t.x+t.w) - Math.max(s[0], t.x), oy = Math.min(s[1]+h, t.y+t.h) - Math.max(s[1], t.y); if (ox > 0 && oy > 0) { a += ox*oy; k++; } }); area.push(Math.round(a)); n.push(k); }); return { spot: v.spot, cover: v.cover, area: area, n: n, boxes: b.length }; })()'
  Note "GRIP corners: chosen $($gArea.spot); page reports cover $($gArea.cover -join ', '); measured count $($gArea.n -join ', '); measured overlap area px2 $($gArea.area -join ', ') of $($gArea.boxes) text boxes"
  Check "it stays on when the page changes (GRIP & BALANCE) at the corner that covers the least text there (corner $($pg2.spot) overlaps the least text area $($gArea.area[$pg2.spot]) px2; all: $($gArea.area -join ', '))" ($pg2.pipOn -eq $true -and $pg2.lap.shown -eq $true -and $pg2.forced -eq -1 -and $gArea.area[$pg2.spot] -eq (($gArea.area | Measure-Object -Minimum).Minimum))
  # playing with the small video: it is the clock there too, and the mode words show it
  $pp = Cdp-Obj 'T.play(1, 2, Math.round(T.idxAtTime(12)))'
  Check "playing with the small video: the video drives the cursor (2 s moved $([math]::Round($pp.dv, 2)) s, cursor and picture within $([math]::Round($pp.maxPic * 1000, 2)) ms)" ((Near $pp.dv 2 0.6) -and $pp.maxPic -lt 0.001 -and $pp.maxLag -lt 0.1)
  $null = Cdp-Eval 'WB.cmd("play"); T.sleep(500)'; $mw = Cdp-Obj '(function(){ var m = document.getElementById("mode"); return { t: m.innerText, fits: m.scrollWidth <= m.clientWidth }; })()'
  $null = Cdp-Eval 'WB.cmd("pause"); 1'
  Check "while it plays the header says PLAY and the words fit ('$($mw.t)')" ($mw.t -match 'PLAY' -and $mw.fits -eq $true)
  Cdp-Key 'v' 'KeyV' 'v'; Start-Sleep -Milliseconds 400
  $po = Cdp-Obj 'WB.video()'
  Check 'key V again hides it (and the video stops being shown); the next time it comes back at the automatic corner' ($po.pip -eq $false -and $po.pipOn -eq $false -and $po.lap.shown -eq $false -and $po.forced -eq -1)
  $null = Cdp-Eval 'document.getElementById("pipbtn").click(); 1'; Start-Sleep -Milliseconds 600
  Check 'the SMALL VIDEO chip does the same as the key' ((Cdp-Obj 'WB.video().pipOn') -eq $true)
  $null = Cdp-Eval 'document.getElementById("pipbtn").click(); 1'; Start-Sleep -Milliseconds 300
  $null = Cdp-Eval 'WB.cmd("page","video"); 1'; Start-Sleep -Milliseconds 800
  Check 'on the VIDEO page the small video is not shown (the big one is), and V does nothing there' ((Cdp-Obj 'WB.video().pipOn') -eq $false -and (Cdp-Obj 'WB.video().lap.shown') -eq $true)
  Cdp-Key 'v' 'KeyV' 'v'; Start-Sleep -Milliseconds 400
  Check '... V on the VIDEO page changed nothing (the big video is still there, the small one is off)' ((Cdp-Obj 'WB.video().pip') -eq $false -and (Cdp-Obj 'WB.video().lap.shown') -eq $true)
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/do?c=wb-page&a=driver" -TimeoutSec 8; Start-Sleep -Milliseconds 1200
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/do?c=wb-video-pip" -TimeoutSec 8; Start-Sleep -Milliseconds 1500
  Check 'the deck can show the small video too (/api/do?c=wb-video-pip is let through and the page does it)' ((Cdp-Obj 'WB.video().pipOn') -eq $true -and (Cdp-Obj 'WB.state.page') -eq 'driver')

  # =====================================================================================================
  Section '8. no JavaScript errors, nothing left running'
  $errs = @($script:cdp.errors)
  Check "no JavaScript error in the page ($($errs.Count))" ($errs.Count -eq 0)
  if ($errs.Count) { $errs | Select-Object -First 5 | ForEach-Object { Note $_ } }
}
finally {
  try { Cdp-Close } catch { }
  try { $null = J '/vault/test/sandbox?on=0' } catch { }
  Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*video-test-*' -or $_.CommandLine -like '*vault-test*' } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Remove-Item $hook -Force -ErrorAction SilentlyContinue
  Remove-Item $lock -Force -ErrorAction SilentlyContinue
  Exit-TestLock
  if (-not $Keep) {
    try { if (Test-Path $tdir) { Remove-Item $tdir -Recurse -Force } } catch { }
    try { if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force } } catch { }
  } else { "  info  -Keep: the scratch vault stays in $tdir and the pretend clip in $tmp (delete them when done)" }
}
"video-page-test: $pass passed, $fail failed. Pictures in $shots (wb-video*.png). $([math]::Round($swAll.Elapsed.TotalSeconds, 0)) s"
if ($fail -gt 0) { exit 1 }
