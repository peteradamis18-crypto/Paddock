# W6c CAREER (docs\DESIGN-workbench.md 2.4 "history across sessions"): one car at one track over EVERY session, not one outing at a time.
# What it proves, on COPIES of real Road Atlanta Corvette files (the vault's own copies, never Documents\iRacing, never the newest file):
#   - every session's best lap is iRacing's own lap time to 0.001 (3 sessions hand-checked against the raw .ibt, every valid lap of them against LapLastLapTime;
#     iRacing's own LapBestLapTime is never beaten), invalid laps never count, the PB and its evolution, an original and the Vault's copy of it are ONE session,
#     a file that exists only in the Vault still counts, another car or track is left out;
#   - every number (best lap, best-5 average and spread, every valid lap, each corner's best and median, theoretical best, totals) against the Session Review
#     engine (the corner engine's own per-lap times) for ALL sessions;
#   - the cache: the second call reads no .ibt, a damaged cache file is read again, the answer is the same;
#   - races: from vault\field when the log is Peter's car at this track (a pretend log, no real one exists yet) and only then;
#   - the page headless at 1920x1080 (numbers equal the reply, colours, no overlaps, 2+ sessions rule, a click opens the best lap) with pictures
#     tests\shots\wb-career*.png; and, when the deployed irdash has the route, the live endpoint: building -> ready, the second call fast, the cache from disk,
#     503 "after your session" while he drives (test hook), the real telemetry folder.
# Out of the car only (guard.ps1). The live part needs dash\irdash.exe newer than dash\src\career.cs; otherwise it says so and is skipped.
#   powershell -ExecutionPolicy Bypass -File tests\career-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree

$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "  ok    $what" } else { $script:fail++; Write-Host "  FAIL  $what" } }
function Note($what) { Write-Host "  info  $what" }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
function Section($title) { Assert-RigFree -Where $title; Write-Host $title }
$inv = [Globalization.CultureInfo]::InvariantCulture
$t0 = Get-Date
# the page's typographic characters, made here so this file stays plain ASCII (PowerShell 5.1 reads a BOM-less file as ANSI)
$MINUS = [string][char]0x2212; $PM = [string][char]0xB1; $DASH = [string][char]0x2013; $DOT = [string][char]0xB7

$me = Get-Process -Id $PID
$me.PriorityClass = 'BelowNormal'
$cores = [Environment]::ProcessorCount
if ($cores -gt 2) { $mask = [int64]0; for ($i = 0; $i -lt 2; $i++) { $mask = $mask -bor ([int64]1 -shl ($cores - 1 - $i)) }; $me.ProcessorAffinity = [IntPtr]$mask }

$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$vaultSrc = Join-Path $root 'vault\telemetry\chevrolet-corvette-z06-gt3-r\road-atlanta-full-course'
$vaultFerrari = Join-Path $root 'vault\telemetry\ferrari-296-gt3\sebring-international-raceway-international'
$prefix = 'chevyvettez06rgt3_roadatlanta full '
# six sessions in the telemetry folder (iRacing's own names), one of them (13-28-11) ALSO as the Vault's copy, one (21-31-29) ONLY as the Vault's copy
$tel = @('2026-10-06 21-20-59', '2026-10-07 09-34-52', '2026-10-09 14-58-37', '2026-10-09 23-23-41', '2026-10-10 00-13-18', '2026-10-10 13-28-11')
$vaultBoth = '2026-10-10 13-28-11'; $vaultOnly = '2026-10-07 21-31-29'
$pbStamp = '2026-10-10 00-13-18'; $pbName = $prefix + $pbStamp + '.ibt'
$work = Join-Path $env:TEMP ('career-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$apiBase = 'http://localhost:8199'
$hook = Join-Path $root 'dash\test-hook.on'; $lock = Join-Path $root 'dash\deploy.lock'
$hookMade = $false; $lockMade = $false

# an independent reader (straight from the .ibt, nothing of Paddock's): the lap time iRacing wrote for a lap, and iRacing's own best lap of the file
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.IO; using System.Text;
public static class CrRaw {
  static Dictionary<string,int[]> Vars(byte[] b) {
    int nv = BitConverter.ToInt32(b, 24), vho = BitConverter.ToInt32(b, 28); var v = new Dictionary<string,int[]>();
    for (int i = 0; i < nv; i++) { int p = vho + 144 * i; v[Encoding.ASCII.GetString(b, p + 16, 32).Trim('\0')] = new int[] { BitConverter.ToInt32(b, p), BitConverter.ToInt32(b, p + 4) }; }
    return v;
  }
  // LapLastLapTime as it stands during the first 5 s of lap+1 (on-track records): the median of those values; -1 when there are none or iRacing wrote none
  public static double Official(string file, int lap) {
    byte[] b = File.ReadAllBytes(file); var v = Vars(b);
    int bl = BitConverter.ToInt32(b, 36), bo = BitConverter.ToInt32(b, 52), rc = (b.Length - bo) / bl;
    var vals = new List<double>();
    for (int r = 0; r < rc && vals.Count < 300; r++) {
      int s = bo + r * bl;
      if (BitConverter.ToInt32(b, s + v["Lap"][1]) != lap + 1 || b[s + v["IsOnTrack"][1]] == 0) continue;
      vals.Add(BitConverter.ToSingle(b, s + v["LapLastLapTime"][1]));
    }
    if (vals.Count == 0) return -1; vals.Sort(); return vals[vals.Count / 2];
  }
  // iRacing's own best lap in the file: the smallest LapBestLapTime it ever wrote (it counts down inside a session and starts again with the next session of the file); -1 when none
  public static double BestLap(string file) {
    byte[] b = File.ReadAllBytes(file); var v = Vars(b);
    int bl = BitConverter.ToInt32(b, 36), bo = BitConverter.ToInt32(b, 52), rc = (b.Length - bo) / bl; double best = -1;
    for (int r = 0; r < rc; r++) { double x = BitConverter.ToSingle(b, bo + r * bl + v["LapBestLapTime"][1]); if (x > 15 && (best < 0 || x < best)) best = x; }
    return best;
  }
  // Did iRacing count this lap? (L-1) iRacing's own best lap of the session (LapBestLapTime) is the evidence, read at the last record of the lap and 1.5 to 2.5 s after the
  // line. A lap quicker than the best so far (or when it had none) that BECAME the best was counted, whatever the off-track record says; a quicker lap that left the best
  // unchanged was not. A lap that is not quicker than the best so far gives no evidence: then any record of the lap with PlayerTrackSurface 0 (off track) decides.
  public static bool Counted(string file, int lap, double time) {
    byte[] b = File.ReadAllBytes(file); var v = Vars(b);
    int bl = BitConverter.ToInt32(b, 36), bo = BitConverter.ToInt32(b, 52), rc = (b.Length - bo) / bl, first = -1; bool off = false;
    for (int r = 0; r < rc; r++) { int s = bo + r * bl; if (BitConverter.ToInt32(b, s + v["Lap"][1]) == lap && b[s + v["IsOnTrack"][1]] != 0 && BitConverter.ToInt32(b, s + v["PlayerTrackSurface"][1]) == 0) { off = true; break; } }
    for (int r = 0; r < rc; r++) { int s = bo + r * bl; if (BitConverter.ToInt32(b, s + v["Lap"][1]) == lap + 1 && b[s + v["IsOnTrack"][1]] != 0) { first = r; break; } }
    if (first < 1) return false;
    double before = BitConverter.ToSingle(b, bo + (first - 1) * bl + v["LapBestLapTime"][1]); if (before <= 1) before = -1;
    double best = -1;
    for (int r = first + 90; r < Math.Min(rc, first + 150); r++) { double x = BitConverter.ToSingle(b, bo + r * bl + v["LapBestLapTime"][1]); if (x > 1 && (best < 0 || x < best)) best = x; }
    bool faster = before <= 0 || time < before - 0.0015;
    if (faster) return best > 0 && best <= time + 0.0015;
    return !off;
  }
  // the session start the file header says (unix seconds)
  public static long Start(string file) { using (var fs = File.OpenRead(file)) { var h = new byte[144]; fs.Read(h, 0, 144); return BitConverter.ToInt64(h, 112); } }
}
'@

# ---- headless Chrome with the DevTools protocol (the same harness as workbench-test, its own port) ----
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('career-test-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9371
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', '--allow-file-access-from-files', 'about:blank') -PassThru -WindowStyle Hidden
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
    if ($o.method -eq 'Runtime.exceptionThrown') { $c.errors.Add($o.params.exceptionDetails.exception.description) }
    if ($o.id -eq $c.id) { return $o }
  }
}
function Cdp-Eval($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return "js error: " + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
function Cdp-Json($expr) { return (Cdp-Eval "JSON.stringify($expr)") | ConvertFrom-Json }
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
function FxUrl($f) { return 'file:///' + ($f -replace '\\', '/') }
function Wait-Page() { $ready = $false; for ($i = 0; $i -lt 80 -and -not $ready; $i++) { Start-Sleep -Milliseconds 250; $ready = (Cdp-Eval 'window.WB && (WB.extras || WB.error) ? 1 : 0') -eq 1 }; Start-Sleep -Milliseconds 700; return $ready }

# panels (the boxes of the page, not just their text) that overlap each other
$panelOverlapJs = '(function(){var r=[];Array.prototype.forEach.call(document.querySelectorAll(".panel"),function(p){var b=p.getBoundingClientRect(),h=p.querySelector(".ph");if(b.width&&b.height)r.push([(h?h.textContent:p.className).slice(0,18),b])});var bad=[];for(var i=0;i<r.length;i++)for(var j=i+1;j<r.length;j++){var a=r[i][1],c=r[j][1];if(a.left<c.right-1&&c.left<a.right-1&&a.top<c.bottom-1&&c.top<a.bottom-1)bad.push(r[i][0]+" x "+r[j][0])}return bad})()'
# status code and body of a request that may fail (HttpWebRequest, so the body of a 404 or 503 can be read)
function Get-Raw($path) {
  $rq = [Net.HttpWebRequest]::Create("$apiBase$path"); $rq.Timeout = 60000
  try { $resp = $rq.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { return @{ code = 0; body = $_.Exception.Message } } }
  $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8); $b = $sr.ReadToEnd(); $sr.Dispose(); $c = [int]$resp.StatusCode; $resp.Close()
  return @{ code = $c; body = $b }
}
function Q($s) { [uri]::EscapeDataString($s) }
function Fake($q) { $null = Invoke-WebRequest -UseBasicParsing "$apiBase/api/test/frame?$q" -TimeoutSec 8 }
# the reply without its timing/counters (the answer must not depend on where it was read from)
function NoStats($json) { return [regex]::Replace($json, ',"stats":\{[^}]*\}\}$', '}') }

# one run of the shipped code (the build of section 2) over a folder
function Invoke-Exe($argLine, $tag, $timeoutMs = 300000) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:exe; $psi.Arguments = $argLine; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $sw = [Diagnostics.Stopwatch]::StartNew(); $proc = [Diagnostics.Process]::Start($psi)
  if (-not $proc.WaitForExit($timeoutMs)) { try { $proc.Kill() } catch { }; throw "$tag timed out" }
  return @{ exit = $proc.ExitCode; ms = $sw.ElapsedMilliseconds }
}
function Invoke-Career($tag, $vault, $idOrNull, $extra = '', $dir = $null) {
  $out = Join-Path $work "$tag.json"
  if (-not $dir) { $dir = $script:telDir }
  $a = "--analysis --career --root `"$root`" --dir `"$dir`" --vault `"$vault`" --out `"$out`" $extra"
  if ($idOrNull) { $a += " --id `"$idOrNull`"" }
  $r = Invoke-Exe $a $tag
  $txt = if (Test-Path -LiteralPath $out) { [IO.File]::ReadAllText($out) } else { '' }
  return @{ exit = $r.exit; ms = $r.ms; text = $txt; json = if ($txt) { $txt | ConvertFrom-Json } else { $null }; path = $out }
}
function Invoke-Session($tag, $dir, $name) {
  $out = Join-Path $work "$tag.json"
  $r = Invoke-Exe "--analysis --session --corners --root `"$root`" --dir `"$dir`" --id `"$name`" --lap 0 --ref pb --out `"$out`"" $tag
  return @{ exit = $r.exit; ms = $r.ms; json = ([IO.File]::ReadAllText($out) | ConvertFrom-Json) }
}
function Median($v) { $a = @($v | Sort-Object); $n = $a.Count; if ($n -eq 0) { return $null }; if ($n % 2 -eq 1) { return $a[($n - 1) / 2] }; return ($a[$n / 2 - 1] + $a[$n / 2]) / 2 }
function Round3($x) { return [math]::Round([double]$x, 3, [MidpointRounding]::AwayFromZero) }

Enter-TestLock 'career'   # one live test at a time (tests\guard.ps1); released in finally
try {
  New-Item -ItemType Directory -Force $work | Out-Null
  $script:telDir = Join-Path $work 'tel'; $vaultDir = Join-Path $work 'vault'; $vcopy = Join-Path $vaultDir 'telemetry\chevrolet-corvette-z06-gt3-r\road-atlanta-full-course'
  $vferr = Join-Path $vaultDir 'telemetry\ferrari-296-gt3\sebring-international-raceway-international'
  New-Item -ItemType Directory -Force $script:telDir, $vcopy, $vferr | Out-Null

  Section '1. copies of real sessions (the vault''s own copies)'
  $docTel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
  $newestDoc = $null
  if (Test-Path -LiteralPath $docTel) { $newestDoc = Get-ChildItem -LiteralPath $docTel -Filter '*.ibt' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
  function Copy-Keep($from, $to) { Copy-Item -LiteralPath $from -Destination $to; (Get-Item -LiteralPath $to).LastWriteTime = (Get-Item -LiteralPath $from).LastWriteTime }
  $allStamps = @($tel + $vaultOnly)
  # L-1: the Vault now keeps copies only of laps iRacing counted, so a copy can disappear when its session has none; the same untouched file is then taken from the telemetry folder
  function Fix($stamp) { $v = Join-Path $vaultSrc "$stamp.ibt"; if (Test-Path -LiteralPath $v) { return $v }; return (Join-Path $docTel ($prefix + $stamp + '.ibt')) }
  foreach ($s in $allStamps) { Check "the real file is there (the vault's copy, else the original): $s" (Test-Path -LiteralPath (Fix $s)) }
  Check 'none of them is the newest telemetry file (nothing here is being written)' (-not $newestDoc -or -not ($allStamps | Where-Object { $newestDoc.Name -like "*$_.ibt" }))
  foreach ($s in $tel) { Copy-Keep (Fix $s) (Join-Path $script:telDir ($prefix + $s + '.ibt')) }
  Copy-Keep (Fix $vaultBoth) (Join-Path $vcopy "$vaultBoth.ibt")          # the same session twice: the original and the Vault's copy of it
  Copy-Keep (Fix $vaultOnly) (Join-Path $vcopy "$vaultOnly.ibt")          # the original is gone: only the Vault's copy
  $ferr = Get-ChildItem -LiteralPath $vaultFerrari -Filter '*.ibt' | Select-Object -First 1
  Check 'a Ferrari file from another track is there as the decoy' ($null -ne $ferr)
  Copy-Keep $ferr.FullName (Join-Path $script:telDir ('ferrari296gt3_sebring international ' + $ferr.Name))
  Note ("{0} MB copied into {1}" -f [math]::Round(((Get-ChildItem $work -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB), $work)

  Section '2. compile without deploying'
  $build = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'dash\build.ps1') -NoDeploy | Out-String
  $m = [regex]::Match($build, 'built in (.+?) \(not deployed\)')
  Check 'dash\build.ps1 -NoDeploy compiled (career.cs is in its source list)' ($LASTEXITCODE -eq 0 -and $m.Success -and (Get-Content (Join-Path $root 'dash\build.ps1') -Raw) -match 'career\.cs')
  if (-not $m.Success) { throw $build }
  $script:exe = Join-Path $m.Groups[1].Value.Trim() 'irdash.exe'

  Section '3. the career of the Corvette at Road Atlanta over the copies'
  $c1 = Invoke-Career 'career1' $vaultDir $pbName
  Check 'the career answers, exit 0, no error' ($c1.exit -eq 0 -and $c1.json -and -not $c1.json.error)
  if (-not $c1.json -or $c1.json.error) { throw "career failed: $($c1.text)" }
  $J = $c1.json; $ss = @($J.sessions)
  Note ("first call: {0} ms (process start included), {1} sessions, {2} laps, {3} clean, reply {4} KB" -f $c1.ms, $ss.Count, $J.totals.laps, $J.totals.valid, [math]::Round($c1.text.Length / 1KB, 1))
  Check 'it is the Corvette at Road Atlanta (full course) with 14 numbered corners and 4 iRacing sectors' ($J.car -eq 'Chevrolet Corvette Z06 GT3.R' -and $J.track -eq 'Road Atlanta' -and @($J.turns).Count -eq 14 -and @($J.sectorAt).Count -eq 4)
  Check 'every one of the 7 sessions has a clean timed lap (6 in the telemetry folder, 1 only in the Vault); the Ferrari decoy is not in it' ($ss.Count -eq 7 -and @($ss | Where-Object { $_.file -like 'ferrari*' }).Count -eq 0)
  Check 'files found: 7 (the original and the Vault''s copy of 13-28-11 are one session, the decoy is another car)' ($J.totals.files -eq 7 -and $J.totals.skipped -eq 0)
  $both = @($ss | Where-Object { $_.file -like '*13-28-11*' }); $only = @($ss | Where-Object { $_.file -like '*21-31-29*' })
  Check 'the session in both places counts once, as the original (not a vault copy)' ($both.Count -eq 1 -and $both[0].vault -eq $false)
  Check 'the session that exists only in the Vault counts, and says so' ($only.Count -eq 1 -and $only[0].vault -eq $true -and $only[0].file -eq "$vaultOnly.ibt")
  $ordered = $true; for ($i = 1; $i -lt $ss.Count; $i++) { if ([long]$ss[$i].startMs -le [long]$ss[$i - 1].startMs) { $ordered = $false } }
  Check 'the sessions run oldest to newest by their own start time' $ordered
  $startOk = $true; foreach ($s in $ss) { $stamp = [regex]::Match($s.file, '(\d{4}-\d\d-\d\d \d\d-\d\d-\d\d)').Groups[1].Value; $dt = [datetime]::ParseExact($stamp, 'yyyy-MM-dd HH-mm-ss', $inv); $ms = ([DateTimeOffset]$dt).ToUnixTimeMilliseconds(); if ([math]::Abs([long]$s.startMs - $ms) -gt 2000) { $startOk = $false } }
  Check 'each session''s start is the time in its file name (to the second)' $startOk

  Section '4. PB evolution: official times only, the current PB marked'
  $best = @($ss | ForEach-Object { [double]$_.best })
  $pbT = ($best | Measure-Object -Minimum).Minimum
  Check 'the personal best is the quickest session best: 1:19.549, lap 7, in the 2026-10-10 00:13:18 session' ((Near $J.pb.time $pbT 0.0005) -and (Near $J.pb.time 79.549 0.0005) -and $J.pb.lap -eq 7 -and $J.pb.file -eq $pbName -and $ss[$J.pb.i].file -eq $pbName)
  $run = 1e9; $evo = $true
  for ($i = 0; $i -lt $ss.Count; $i++) {
    $isNew = ([double]$ss[$i].best -lt $run - 1e-9); if ($isNew) { $run = [double]$ss[$i].best }
    if ([bool]$ss[$i].newPb -ne $isNew -or -not (Near $ss[$i].pbSoFar $run 0.0005)) { $evo = $false }
  }
  Check 'newPb and the running best of every session are what the lap times say (a PB only when strictly better than every session before)' $evo
  Check 'the first session is always a PB and the quickest (current) one is marked newPb' ($ss[0].newPb -eq $true -and $ss[$J.pb.i].newPb -eq $true)
  Check 'the afternoon session (13-28-11) is 1:19.575 lap 7: the next best, not a PB' ((Near $both[0].best 79.575 0.0005) -and $both[0].bestLap -eq 7 -and $both[0].newPb -eq $false)
  Check '13-28-11: iRacing timed laps 2 to 6 but each had a brief off-track and its own best lap stayed empty until lap 7 (79.575): the 5 laps are left out, lap 7 is the one lap counted' ($both[0].valid -eq 1 -and $both[0].uncounted -eq 5 -and (@($both[0].lapN) -join ',') -eq '7' -and $both[0].laps -eq 7)
  Note ('PB evolution: ' + (($ss | ForEach-Object { ('{0}{1}' -f ([datetime]'1970-01-01').AddMilliseconds([long]$_.startMs).ToLocalTime().ToString('d MMM'), ' ' + [math]::Round($_.best, 3) + $(if ($_.newPb) { '*' } else { '' })) }) -join ' | '))

  Section '5. hand checks against the raw .ibt (nothing of Paddock''s code in the reader)'
  $byFile = @{}; foreach ($s in $ss) { $byFile[$s.file] = $s }
  function Path-Of($s) { if ($s.vault) { return (Join-Path $vcopy $s.file) }; return (Join-Path $script:telDir $s.file) }
  $hand = @($pbName, ($prefix + $tel[3] + '.ibt'), ($prefix + $tel[1] + '.ibt'))
  foreach ($nm in $hand) {
    $s = $byFile[$nm]; $p = Path-Of $s
    $raw = [CrRaw]::Official($p, [int]$s.bestLap)
    Note ("HAND CHECK {0}: best lap {1} = {2} s in the reply, LapLastLapTime in the raw records during lap {3} = {4:N4} s" -f $nm.Substring($prefix.Length), $s.bestLap, $s.best, ([int]$s.bestLap + 1), $raw)
    Check "$($nm.Substring($prefix.Length)): the best lap equals iRacing's own lap time to 0.001 (raw LapLastLapTime)" (Near $s.best $raw 0.0005)
    $allOk = $true; for ($k = 0; $k -lt @($s.lapN).Count; $k++) { $rw = [CrRaw]::Official($p, [int]$s.lapN[$k]); if (-not ($rw -gt 0 -and (Near $s.lapT[$k] $rw 0.0005))) { $allOk = $false; Note "lap $($s.lapN[$k]): reply $($s.lapT[$k]) raw $rw" } }
    Check "$($nm.Substring($prefix.Length)): all $(@($s.lapN).Count) clean laps carry iRacing's own time, and none of them is a lap iRacing gave no time (-1)" $allOk
    $cntOk = $true; for ($k = 0; $k -lt @($s.lapN).Count; $k++) { if (-not [CrRaw]::Counted($p, [int]$s.lapN[$k], [double]$s.lapT[$k])) { $cntOk = $false; Note "lap $($s.lapN[$k]) was not counted by iRacing" } }
    Check "$($nm.Substring($prefix.Length)): iRacing counted every one of them (no off-track in them; its own best lap of the session is never slower than a lap that is listed)" $cntOk
  }
  $never = $true; $eq2 = 0
  foreach ($s in $ss) {
    $ib = [CrRaw]::BestLap((Path-Of $s))
    if ($ib -gt 0 -and [double]$s.best -lt $ib - 0.0005) { $never = $false; Note "$($s.file): reply best $($s.best) is quicker than iRacing's own best $ib" }
    if ($ib -gt 0 -and (Near $s.best $ib 0.0005)) { $eq2++ }
  }
  Check "no session's best is quicker than the best lap iRacing itself wrote into that file (LapBestLapTime): an invalid lap never counts; $eq2 of 7 are exactly it" ($never -and $eq2 -ge 4)
  Check 'the PB session''s best (79.549) is exactly iRacing''s own best lap of that file' (Near $J.pb.time ([CrRaw]::BestLap((Join-Path $script:telDir $pbName))) 0.0005)

  Section '6. every number against the Session Review engine (the corner engine''s own lap times), all 7 sessions'
  $srAll = @{}; $thSec = $null; $sumLaps = 0; $sumValid = 0; $sumUnc = 0; $sumSec = 0.0; $cornerWorst = 0.0; $cornerCells = 0; $cornerBad = 0
  foreach ($s in $ss) {
    $dir = if ($s.vault) { $vcopy } else { $script:telDir }
    $sr = Invoke-Session ('sr-' + $s.i) $dir $s.file
    $sj = $sr.json; $srAll[$s.file] = $sj
    # L-1: the Session Review keeps only laps iRacing counted - the same rule as the career (LapRules). The raw reader decides again from the file, not from Paddock's code:
    # every lap the Session Review calls valid is one it counts, and every lap iRacing timed but the Session Review does not call valid is one it does not count
    $pRaw = Path-Of $s
    $vl = @($sj.laps | Where-Object { $_.valid })
    $notCounted = @($sj.laps | Where-Object { $_.timed -and -not $_.valid })
    $agree = (@($vl | Where-Object { -not [CrRaw]::Counted($pRaw, [int]$_.n, [double]$_.time) }).Count -eq 0) -and (@($notCounted | Where-Object { [CrRaw]::Counted($pRaw, [int]$_.n, [double]$_.time) }).Count -eq 0)
    $unc = $notCounted.Count; $sumUnc += $unc
    $times = @($vl | ForEach-Object { [double]$_.time } | Sort-Object); $n5 = [math]::Min(5, $times.Count); $avg = 0.0; for ($q = 0; $q -lt $n5; $q++) { $avg += $times[$q] }; $avg /= $n5; $sd = 0.0; for ($q = 0; $q -lt $n5; $q++) { $sd += ($times[$q] - $avg) * ($times[$q] - $avg) }; $sd = [math]::Sqrt($sd / $n5)
    $bestRow = $vl | Sort-Object { [double]$_.time } | Select-Object -First 1
    $ok = ($sr.exit -eq 0 -and $agree -and $vl.Count -eq [int]$s.valid -and $unc -eq [int]$s.uncounted -and $sj.validLaps -eq [int]$s.valid -and (Near $bestRow.time $s.best 0.0005) -and $bestRow.n -eq $s.bestLap -and $sj.type -eq $s.type -and [long]$sj.startMs -eq [long]$s.startMs)
    $ok = $ok -and (Near $avg $s.avg5 0.0011) -and (Near $sd $s.sd5 0.0011) -and $n5 -eq $s.n5
    $lapsOk = ($vl.Count -eq @($s.lapN).Count); for ($k = 0; $lapsOk -and $k -lt $vl.Count; $k++) { if ($vl[$k].n -ne $s.lapN[$k] -or -not (Near $vl[$k].time $s.lapT[$k] 0.0006)) { $lapsOk = $false } }
    if ($unc -gt 0) { Note "$($s.file.Substring($s.file.Length - 23)): $unc lap(s) iRacing timed but did not count: the Session Review flags them ($((@($notCounted | ForEach-Object { $_.flag } | Group-Object | ForEach-Object { $_.Name + ' ' + $_.Count })) -join ', ')) and leaves them out, like the career" }
    if (-not ($ok -and $lapsOk)) { Note ("detail: exit {0} valid {1}/{2} unc {3}/{4} validLaps {5} best {6}/{7} lap {8}/{9} type {10}/{11} start {12}/{13} avg {14}/{15} sd {16}/{17} n5 {18}/{19} lapsOk {20}" -f $sr.exit, $vl.Count, $s.valid, $unc, $s.uncounted, $sj.validLaps, $bestRow.time, $s.best, $bestRow.n, $s.bestLap, $sj.type, $s.type, $sj.startMs, $s.startMs, $avg, $s.avg5, $sd, $s.sd5, $n5, $s.n5, $lapsOk) }
    Check "$($s.file.Substring($s.file.Length - 23)): valid laps (iRacing-counted, agreeing with the raw reader), best, best-5 average and spread, type and start equal the Session Review's" ($ok -and $lapsOk)
    # corners: each corner's best and median over the valid laps, from the per-lap corner times of the Session Review reply
    $nT = @($sj.turns).Count
    for ($k = 0; $k -lt $nT; $k++) {
      $vals = @($vl | ForEach-Object { [double]$_.cornerT[$k] }); $c = $s.c[$k]
      if ($vals.Count -eq 0) { if ($c) { $cornerBad++ }; continue }
      $cornerCells++
      $mn = ($vals | Measure-Object -Minimum).Minimum; $md = Median $vals
      $d = [math]::Max([math]::Abs([double]$c[0] - $mn), [math]::Abs([double]$c[1] - $md)); if ($d -gt $cornerWorst) { $cornerWorst = $d }
      if ($d -gt 0.0006 -or [int]$c[2] -ne $vals.Count) { $cornerBad++ }
    }
    $sumLaps += @($sj.laps | Where-Object { $null -ne $_.time }).Count; $sumValid += $vl.Count; $sumSec += [double]$sj.seconds
    if (-not $thSec) { $thSec = New-Object 'double[]' @($sj.sectorAt).Count; for ($q = 0; $q -lt $thSec.Count; $q++) { $thSec[$q] = 1e9 } }
    # L-1b: the theoretical best joins only counted laps with NO off-track record (offTrack false, skip not "off"); a counted lap with a record still counts for the PB and the lists
    foreach ($l in $vl) { if ($l.offTrack -or $l.skip -eq 'off') { continue }; for ($q = 0; $q -lt $thSec.Count; $q++) { $v = Round3 $l.sectors[$q]; if ($v -lt $thSec[$q]) { $thSec[$q] = $v } } }
  }
  Check "every corner's best and median time of every session equals the corner engine's ($cornerCells corner cells in 7 sessions, worst difference $([math]::Round($cornerWorst, 5)) s, lap counts equal)" ($cornerBad -eq 0 -and $cornerCells -gt 60)
  $thSum = 0.0; foreach ($x in $thSec) { $thSum += $x }
  Check "theoretical best $(Round3 $thSum) = the best iRacing sector ever of those sessions joined (sectors $(($thSec | ForEach-Object { $_ }) -join ' '))" ($J.theoretical -and (Near $J.theoretical.time $thSum 0.0006) -and (@($J.theoretical.sectors) | ForEach-Object { $_.time }).Count -eq 4)
  $secOk = $true; for ($q = 0; $q -lt 4; $q++) { if (-not (Near $J.theoretical.sectors[$q].time $thSec[$q] 0.0006)) { $secOk = $false } }
  Check 'each of the 4 sectors is the quickest one of any session, with the session and lap it came from' ($secOk -and (@($J.theoretical.sectors | Where-Object { $_.i -ge 0 -and $_.lap -gt 0 }).Count -eq 4))
  Check 'the theoretical best is quicker than the PB by the gap that is shown, and the PB lap''s own 4 sectors add up to the PB' ((Near $J.theoretical.gap ($J.pb.time - $J.theoretical.time) 0.0006) -and $J.theoretical.gap -gt 0.2 -and (Near ((@($J.pb.sectors) | Measure-Object -Sum).Sum) $J.pb.time 0.004))
  Check "totals: $($ss.Count) sessions, $sumLaps timed laps, $sumValid clean laps ($sumUnc more that iRacing timed but did not count), $([math]::Round($sumSec / 60, 1)) minutes driven = the sums of the Session Review figures" ($J.totals.sessions -eq 7 -and $J.totals.laps -eq $sumLaps -and $J.totals.valid -eq $sumValid -and $J.totals.uncounted -eq $sumUnc -and (Near $J.totals.seconds $sumSec 7) -and [long]$J.totals.firstMs -eq [long]$ss[0].startMs -and [long]$J.totals.lastMs -eq [long]$ss[6].startMs)
  Check 'no races are listed (there is no race log in this vault)' (@($J.races).Count -eq 0)

  Section '7. the cache: files never change, so the second call reads no .ibt'
  $cacheDir = Join-Path $vaultDir 'career'
  $cf = @(Get-ChildItem -LiteralPath $cacheDir -Filter 'c*-*.json' -ErrorAction SilentlyContinue)
  Check 'the first call kept one small file per session in vault\career (7 files)' ($cf.Count -eq 7 -and ($cf | Measure-Object Length -Maximum).Maximum -lt 60KB)
  Check 'the first call read all 7 files' ($J.stats.computed -eq 7 -and $J.stats.disk -eq 0)
  $c2 = Invoke-Career 'career2' $vaultDir $pbName
  Check 'the second call (a new process, so from disk) read no .ibt at all' ($c2.exit -eq 0 -and $c2.json.stats.computed -eq 0 -and $c2.json.stats.disk -eq 7)
  Note ("first call {0} ms, second call {1} ms (process start included); the engine itself {2} ms then {3} ms" -f $c1.ms, $c2.ms, $J.stats.ms, $c2.json.stats.ms)
  Check 'the second call is much quicker (under half the first inside the engine) and under 1.5 s with the process start' ($c2.json.stats.ms * 2 -lt $J.stats.ms -and $c2.ms -lt 1500)
  Check 'the answer is the same, byte for byte, apart from the counters' ((NoStats $c1.text) -eq (NoStats $c2.text))
  Set-Content -LiteralPath $cf[0].FullName -Value 'this is not json {' -Encoding ASCII
  Remove-Item -LiteralPath $cf[1].FullName
  $c3 = Invoke-Career 'career3' $vaultDir $pbName
  Check 'a damaged cache file and a missing one are read again (2 files), nothing else, and the answer does not change' ($c3.exit -eq 0 -and $c3.json.stats.computed -eq 2 -and $c3.json.stats.disk -eq 5 -and (NoStats $c3.text) -eq (NoStats $c1.text))
  $byName = Invoke-Career 'career4' $vaultDir $null ('--car "' + $J.car + '" --track "' + $J.track + '" --config "' + $J.config + '"')
  Check 'by car + track + layout names it is the same answer; a car that was never driven here is a 404 error' ($byName.exit -eq 0 -and (NoStats $byName.text) -eq (NoStats $c1.text) -and (Invoke-Career 'career5' $vaultDir $null '--car "Nonexistent Car" --track "Road Atlanta" --config "Full Course"').exit -eq 1)
  $viaVault = Invoke-Career 'career6' $vaultDir "$vaultOnly.ibt"
  Check 'a file that only the Vault has can be the one asked for (by its own name) and gives the same career' ($viaVault.exit -eq 0 -and (NoStats $viaVault.text) -eq (NoStats $c1.text))

  Section '8. races: only from a log that is his car at this track'
  $fieldDir = Join-Path $vaultDir 'field'; New-Item -ItemType Directory -Force $fieldDir | Out-Null
  $eStart = [CrRaw]::Start((Join-Path $script:telDir $pbName)) * 1000 + 60000
  function RaceJson($id, $startMs, $sessType, $track, $trackName, $trackId, $carName, $config) {
    $mine = "[[1,0,80.5,80.5,2,2,0,0],[2,80.5,160.9,80.4,2,2,0,0],[3,160.9,242.345,81.445,2,2,0,0]]"
    $win = "[[1,0,80,80,1,1,0,0],[2,80,160,80,1,1,0,0],[3,160,240,80,1,1,0,0]]"
    $slow = "[[1,0,82,82,3,3,0,0],[2,82,165,83,3,3,0,0]]"
    $car = { param($i, $num, $name, $cn, $me, $fp, $L2, $ri, $rb) "{`"i`":$i,`"num`":`"$num`",`"name`":`"$name`",`"team`":`"`",`"car`":`"$cn`",`"cls`":`"4011`",`"cn`":`"GT3`",`"col`":`"#f2c230`",`"path`":`"chevyvettez06rgt3`",`"dz`":`"17,391c83,111111,ccff00`",`"ir`":2500,`"lic`":`"A 3.0`",`"me`":$me,`"gone`":0,`"fin`":1,`"fp`":$fp,`"fcp`":$fp,`"rp`":$fp,`"rl`":3,`"ri`":$ri,`"rbl`":1,`"rb`":$rb,`"rs`":`"`",`"off`":0,`"offS`":0,`"bs`":null,`"L`":$L2,`"P`":[]}" }
    $cars = (& $car 0 '7' 'Peter Test' $carName 1 2 $mine 2 80.4) + ',' + (& $car 1 '9' 'Winner Test' 'Chevrolet Corvette Z06 GT3.R' 0 1 $win 0 80.0) + ',' + (& $car 2 '3' 'Slow Test' 'Chevrolet Corvette Z06 GT3.R' 0 3 $slow 1 82.0)
    return "{`"v`":1,`"id`":`"$id`",`"startMs`":$startMs,`"endMs`":$($startMs + 600000),`"track`":`"$track`",`"config`":`"$config`",`"trackName`":`"$trackName`",`"trackId`":`"$trackId`",`"key`":`"t$trackId-$trackName`",`"lengthM`":4100.0,`"sessNum`":2,`"sessType`":`"$sessType`",`"sessName`":`"RACE`",`"sessLaps`":`"3`",`"official`":0,`"isRace`":1,`"me`":0,`"t0`":0.0,`"endT`":242.345,`"greenT`":0.0,`"flagT`":240.0,`"samples`":100,`"complete`":1,`"cornerSrc`":`"lovely`",`"corners`":[],`"cars`":[$cars],`"passes`":[]}"
  }
  $car1 = $J.car; $trk = $J.track; $cfg = $J.config
  $rwId = 'f20261010-001400-2'
  [IO.File]::WriteAllText((Join-Path $fieldDir "$rwId.json"), (RaceJson $rwId $eStart 'Race' $trk 'roadatlanta full' '127' $car1 $cfg), (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $fieldDir 'f20261010-001400-1.json'), (RaceJson 'f20261010-001400-1' ($eStart - 5000) 'Practice' $trk 'roadatlanta full' '127' $car1 $cfg), (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $fieldDir 'f20261010-001400-3.json'), (RaceJson 'f20261010-001400-3' $eStart 'Race' 'Sebring International Raceway' 'sebring international' '240' $car1 'International'), (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $fieldDir 'f20261010-001400-4.json'), (RaceJson 'f20261010-001400-4' $eStart 'Race' $trk 'roadatlanta full' '127' 'Ferrari 296 GT3' $cfg), (New-Object Text.UTF8Encoding($false)))
  Set-Content -LiteralPath (Join-Path $fieldDir 'f20261010-001400-5.json') -Value '{ not a race log' -Encoding ASCII
  $c6 = Invoke-Career 'career-races' $vaultDir $pbName
  $rc = @($c6.json.races)
  Check 'five logs are there (a race at this track, a practice, a race at another track, a race in another car, a broken file): only the race of his Corvette at this track is listed' ($c6.exit -eq 0 -and $rc.Count -eq 1 -and $rc[0].id -eq $rwId)
  if ($rc.Count -eq 1) {
    $r = $rc[0]
    Check 'his result: P2 of 3 cars (all in his class), 3 laps, 2.345 s behind the winner, who took 240.000 s; his total 242.345, best lap 1:20.4, 2 incidents' ($r.pos -eq 2 -and $r.cpos -eq 2 -and $r.field -eq 3 -and $r.classCars -eq 3 -and $r.laps -eq 3 -and (Near $r.gap 2.345 0.0006) -and (Near $r.winTotal 240.0 0.0006) -and (Near $r.total 242.345 0.0006) -and (Near $r.best 80.4 0.0006) -and $r.inc -eq 2 -and $r.out -eq $false)
    Check 'the race is tied to the telemetry session that ran at that time (the 00:13:18 PB session), so a click can open its RACE page' ($r.session -ge 0 -and $c6.json.sessions[$r.session].file -eq $pbName)
    Check 'P4: the race carries his car as the log has it: CarPath chevyvettez06rgt3, livery 17,391c83,111111,ccff00, number 7, class colour #f2c230' ($r.cpath -eq 'chevyvettez06rgt3' -and $r.dz -eq '17,391c83,111111,ccff00' -and $r.num -eq '7' -and $r.col -eq '#f2c230')
  } else { Check 'his result (skipped: the race is not listed)' $false; Check 'the race is tied to its session (skipped)' $false; Check 'P4: his car in the race (skipped)' $false }
  Check 'everything except the races is the same as without the logs' (((NoStats $c6.text) -replace '"races":\[.*\]\}$', '"races":[]}') -eq (NoStats $c1.text))
  Remove-Item -LiteralPath $fieldDir -Recurse -Force
  $c1text = $c1.text

  Section '9. the CAREER page in headless Chrome (1920x1080) against the reply'
  # the page needs a lap to open on: the same channel reply the workbench test uses (the PB lap), made by the same engine
  $chp = ([regex]::Match((Get-Content (Join-Path $root 'dash\www\v2\workbench.js') -Raw), 'var CHANS = \[(.*?)\];', 'Singleline').Groups[1].Value -replace "[\s']", '')
  $lapBin = Join-Path $work 'lap7.bin'
  $rr = Invoke-Exe "--analysis --channels --root `"$root`" --dir `"$($script:telDir)`" --id `"$pbName`" --lap 7 --ref pb --ch `"$chp`" --out `"$lapBin`"" 'channels'
  Check 'the lap the page opens on (PB lap 7 with its reference) was made' ($rr.exit -eq 0 -and (Test-Path $lapBin))
  $fxBase = 'file:///' + ($root -replace '\\', '/') + '/dash/www/v2/workbench.html?data=' + (FxUrl $lapBin)
  # a career of ONE session: a folder with a single Corvette file (the page must not offer a tab for it)
  $tel1 = Join-Path $work 'tel1'; New-Item -ItemType Directory -Force $tel1 | Out-Null
  Copy-Keep (Fix $tel[2]) (Join-Path $tel1 ($prefix + $tel[2] + '.ibt'))
  $c1one = Invoke-Career 'career-one' (Join-Path $work 'vault1') ($prefix + $tel[2] + '.ibt') '' $tel1
  $one = $c1one.path
  Check 'a folder with one Corvette session gives a career of one session (the reply is fine; the page offers no tab for it)' ($c1one.exit -eq 0 -and @($c1one.json.sessions).Count -eq 1 -and $c1one.json.totals.sessions -eq 1)
  # L-1b: 2026-10-06 21-10-08 has 3 counted laps, but laps 2 and 3 (42 and 34 off-track records) are not clean and lap 3 (1:20.695) is the PB: the sectors that could be joined (lap 1
  # alone, 1:22.436) are slower than the PB, so there is NO theoretical best - the PB is still the counted lap
  $telO = Join-Path $work 'telO'; New-Item -ItemType Directory -Force $telO | Out-Null
  $nameO = $prefix + '2026-10-06 21-10-08.ibt'
  Copy-Keep (Join-Path $docTel $nameO) (Join-Path $telO $nameO)
  $cO = Invoke-Career 'career-offtrack' (Join-Path $work 'vaultO') $nameO '' $telO
  Check 'a career whose PB lap has an off-track record (21-10-08, PB 1:20.695 = lap 3, a counted lap): 3 counted laps, the PB is shown, and there is no theoretical best (what can be joined from its clean laps is slower than the PB)' ($cO.exit -eq 0 -and $cO.json.totals.valid -eq 3 -and (Near $cO.json.pb.time 80.695 0.0005) -and $cO.json.pb.lap -eq 3 -and $null -eq $cO.json.theoretical)
  $racesFx = Join-Path $work 'career-races.json'; [IO.File]::WriteAllText($racesFx, $c6.text, (New-Object Text.UTF8Encoding($false)))
  $building = Join-Path $work 'career-building.json'; [IO.File]::WriteAllText($building, '{"building":true,"done":3,"of":12,"file":"x.ibt","same":true}', (New-Object Text.UTF8Encoding($false)))
  $careerFx = $c1.path

  # --- one session only: no tab ---
  Cdp-Open ($fxBase + '&careerdata=' + (FxUrl $one))
  $ready = Wait-Page
  Check 'one session only: the page loads, there is NO career tab (2 or more sessions needed)' ($ready -and ((Cdp-Json 'WB.pages()') -notcontains 'career') -and ((Cdp-Eval 'document.getElementById("tabs").textContent') -notmatch 'CAREER'))
  Cdp-Close
  # --- nothing asked: no tab ---
  Cdp-Open $fxBase
  $ready = Wait-Page
  Check 'no career data at all (an old fixture): no tab and no error' ($ready -and ((Cdp-Json 'WB.pages()') -notcontains 'career') -and $script:cdp.errors.Count -eq 0)
  Cdp-Close
  # --- still reading: no tab, unless the page was asked for by name ---
  Cdp-Open ($fxBase + '&careerdata=' + (FxUrl $building))
  $ready = Wait-Page
  Check 'the server is still reading the files: the rest of the page opens at once and there is no tab yet' ($ready -and ((Cdp-Json 'WB.pages()') -notcontains 'career'))
  Cdp-Close
  Cdp-Open ($fxBase + '&page=career&careerdata=' + (FxUrl $building))
  $ready = Wait-Page
  $w1 = Cdp-Json 'WB.career()'
  Check 'asked for by name while it is reading: the page says so with the count (3 of 12) and has a tab' ($ready -and $w1.state -eq 'building' -and $w1.text -like '*Reading sessions*3 / 12*' -and ((Cdp-Json 'WB.pages()') -contains 'career'))
  Cdp-Shot (Join-Path $shots 'wb-career-wait.png')
  Cdp-Close

  # --- the full page ---
  Cdp-Open ($fxBase + '&page=career&careerdata=' + (FxUrl $careerFx))
  $ready = Wait-Page
  Check 'the page loads the reply with no JavaScript error and opens on CAREER' ($ready -and -not (Cdp-Eval 'WB.error || ""') -and $script:cdp.errors.Count -eq 0 -and (Cdp-Json 'WB.state').page -eq 'career')
  Check '7 sessions: the CAREER tab is there next to DRIVER and GRIP & BALANCE' ((Cdp-Json 'WB.pages()') -contains 'career' -and (Cdp-Eval 'document.getElementById("tabs").textContent') -match 'CAREER')
  $pg = Cdp-Json 'WB.career()'
  $kinds = Cdp-Json 'WB.displays().map(function(d){return d.kind})'
  Check 'the page has the PB chart, the consistency chart, the corner grid, the tiles, the theoretical-best table, the totals and the corner table; no races panel (there are none)' (($kinds -contains 'careerpb') -and ($kinds -contains 'careercons') -and ($kinds -contains 'careergrid') -and ($kinds -contains 'careertiles') -and ($kinds -contains 'careertheo') -and ($kinds -contains 'careertotals') -and ($kinds -contains 'careertrend') -and -not ($kinds -contains 'careerraces'))
  function Fmt($t) { $m = [math]::Floor($t / 60); $s = $t - $m * 60; return ('{0}:{1}' -f $m, $s.ToString('00.000', $inv)) }
  $tiles = @($pg.tiles)
  Check "tiles: PB $(Fmt $J.pb.time), theoretical $(Fmt $J.theoretical.time), gap $($J.theoretical.gap.ToString('0.000', $inv)) s - the reply's numbers" ($tiles.Count -eq 3 -and $tiles[0] -like "*$(Fmt $J.pb.time)*LAP 7*" -and $tiles[1] -like "*$(Fmt $J.theoretical.time)*" -and $tiles[2] -like "*$($J.theoretical.gap.ToString('0.000', $inv)) s*")
  $th = @($pg.theo); $thOk = ($th.Count -eq 5)
  for ($q = 0; $thOk -and $q -lt 4; $q++) { $row = $th[$q]; if ($row[0] -ne "S$($q + 1)" -or $row[1] -ne $J.pb.sectors[$q].ToString('0.000', $inv) -or $row[2] -ne $J.theoretical.sectors[$q].time.ToString('0.000', $inv)) { $thOk = $false } }
  Check 'theoretical-best table: S1..S4 with the PB lap''s sector and the best ever, then the lap row' ($thOk -and $th[4][1] -eq (Fmt $J.pb.time) -and $th[4][2] -eq (Fmt $J.theoretical.time))
  $tot = @($pg.totals)
  Check "totals tiles: $($J.totals.sessions) sessions, $($J.totals.laps) laps, $($J.totals.valid) clean laps, the time driven" ($tot[0] -like "$($J.totals.sessions)*SESSIONS" -and $tot[1] -like "$($J.totals.laps)*LAPS" -and $tot[1] -notlike '*CLEAN*' -and $tot[2] -like "$($J.totals.valid)*CLEAN LAPS" -and $tot[3] -like '*DRIVEN')
  $driven = [int][math]::Round($J.totals.seconds / 60); $dh = [math]::Floor($driven / 60); $dm = $driven % 60
  Check "time driven reads $dh h $dm m (the reply's $($J.totals.seconds) s)" ($tot[3] -like "*$(if ($dh -gt 0) { "${dh}h ${dm}m" } else { "${dm}m" })*")

  # the corner table (EARLY, RECENT, CHANGE, BEST EVER, LEFT) recomputed here from the reply's per-session corner times, best and then median
  function Trend-Expect($j, $mode) {
    $idx = if ($mode -eq 'best') { 0 } else { 1 }; $out = @()
    for ($k = 0; $k -lt @($j.turns).Count; $k++) {
      $vals = @(); $ever = 1e9; $ei = -1; $i = 0
      foreach ($s in $j.sessions) { $c = $s.c[$k]; if ($c) { $vals += [double]$c[$idx]; if ([double]$c[$idx] -lt $ever) { $ever = [double]$c[$idx]; $ei = $i } }; $i++ }
      $m = $vals.Count; if ($m -eq 0) { continue }
      $g = [math]::Max(1, [math]::Min(3, [math]::Floor($m / 2)))
      $row = @{ k = $k; ever = $ever }
      if ($m -ge 2) { $row.early = ($vals[0..($g - 1)] | Measure-Object -Minimum).Minimum; $row.recent = ($vals[($m - $g)..($m - 1)] | Measure-Object -Minimum).Minimum; $row.change = $row.recent - $row.early; $row.left = $row.recent - $ever }
      $out += $row
    }
    return $out
  }
  function Sg($d) { if ([math]::Abs($d) -lt 0.0005) { return $PM + '0.000' }; return $(if ($d -gt 0) { '+' } else { $MINUS }) + ([math]::Abs($d)).ToString('0.000', $inv) }
  function Trend-Check($pgNow, $j, $mode) {
    $exp = Trend-Expect $j $mode; $rows = @($pgNow.corners); $bad = 0; $up = 0; $dn = 0
    if ($rows.Count -ne $exp.Count) { return @{ ok = $false; why = "rows $($rows.Count) expected $($exp.Count)"; up = 0; dn = 0 } }
    for ($q = 0; $q -lt $exp.Count; $q++) {
      $e = $exp[$q]; $r = $rows[$q]
      $earlyT = if ($e.early -ne $null) { ([double]$e.early).ToString('0.000', $inv) } else { $DASH }
      $recT = if ($e.recent -ne $null) { ([double]$e.recent).ToString('0.000', $inv) } else { $DASH }
      $chT = if ($e.change -ne $null) { Sg $e.change } else { $DASH }
      $leftT = if ($e.left -eq $null) { $DASH } elseif ($e.left -lt 0.0005) { 'AT BEST' } else { '+' + ([double]$e.left).ToString('0.000', $inv) }
      if ($e.change -ne $null) { if ($e.change -le -0.02) { $up++ } elseif ($e.change -ge 0.02) { $dn++ } }
      if ($r[1] -ne $earlyT -or $r[2] -ne $recT -or $r[3] -ne $chT -or $r[4] -notlike ("$(([double]$e.ever).ToString('0.000', $inv))*") -or $r[5] -ne $leftT) { $bad++; Write-Host "      row $q $($r -join ' | ') expected $earlyT $recT $chT $($e.ever) $leftT" }
    }
    return @{ ok = ($bad -eq 0); why = "$bad rows differ"; up = $up; dn = $dn }
  }
  $tc = Trend-Check $pg $J 'best'
  Check 'corner table, BEST: EARLY / RECENT / CHANGE / BEST EVER / LEFT of all 14 corners equal what the reply''s per-session corner times give' $tc.ok
  Check 'the counts under the totals say how many corners are faster, slower and the same' ($pg.trend.up -eq $tc.up -and $pg.trend.down -eq $tc.dn -and (@($pg.totals) | Where-Object { $_ -like "EARLY TO RECENT*$($tc.up) FASTER*$($tc.dn) SLOWER*" }).Count -eq 1)
  # a corner whose recent best is better than its early best is green, worse red, within 0.02 s grey
  $cls = Cdp-Json '(function(){return Array.prototype.map.call(document.querySelectorAll("table.cc tbody tr"),function(tr){return [tr.children[3].className, tr.children[3].textContent]})})()'
  $colOk = $true; foreach ($c in $cls) { $v = $c[1]; $isGain = $c[0] -eq 'gain'; $isLoss = $c[0] -eq 'loss'; if ($v -ne $DASH) { $d = [double](($v -replace $MINUS, '-' -replace $PM, '') -replace '\+', ''); if (($d -le -0.02) -ne $isGain -or ($d -ge 0.02) -ne $isLoss) { $colOk = $false } } }
  Check 'CHANGE is green at 0.02 s or more faster, red at 0.02 s or more slower, grey inside that' $colOk
  Check 'the title says BEST and a corner is never listed twice' ((@($pg.titles | Where-Object { $_.kind -eq 'careertrend' })[0].text) -like '*best*' -and (@($pg.corners | ForEach-Object { $_[0] } | Select-Object -Unique)).Count -eq @($pg.corners).Count)

  # the picture on the PB chart: gold where a session set a new PB, cool white where not, the purple ring on the PB
  $dots = @()
  for ($i = 0; $i -lt $ss.Count; $i++) { $pt = Cdp-Json "WB.careerPoint('pb', $i)"; $col = Cdp-Json "WB.careerColour('pb', $i)"; $dots += @{ i = $i; y = $pt.y; x = $pt.x; col = $col; clip = $pt.clip } }
  function Gold($p) { return ($p[0] -gt 200 -and $p[1] -gt 150 -and $p[1] -lt 230 -and $p[2] -lt 110 -and $p[3] -gt 200) }
  function CoolWhite($p) { return ($p[0] -gt 170 -and $p[1] -gt 180 -and $p[2] -gt 190 -and $p[3] -gt 200) }
  $dotOk = $true; foreach ($d in $dots) { $s = $ss[$d.i]; if (-not $d.clip) { if ($s.newPb) { if (-not (Gold $d.col)) { $dotOk = $false; Note "PB chart session $($d.i): $($d.col -join ',')" } } else { if (-not (CoolWhite $d.col)) { $dotOk = $false; Note "PB chart session $($d.i): $($d.col -join ',')" } } } }
  Check 'PB chart: each session''s best lap is a gold dot when it set a new PB and a cool white one when not (pixel colours read back)' $dotOk
  $pbDot = $dots[$J.pb.i]; $minY = ($dots | Where-Object { -not $_.clip } | ForEach-Object { $_.y } | Measure-Object -Minimum).Minimum
  Check 'PB chart: the PB is the highest dot (quickest at the top) and its x is that session''s column' ((Near $pbDot.y $minY 0.5) -and (Near $pbDot.x (84 + ($J.pb.i + 0.5) * (1264 - 84 - 24) / 7) 1.0))
  $ringPx = Cdp-Json ("(function(){var d=WB.displays().filter(function(q){return q.kind==='careerpb'})[0],p=d.point($($J.pb.i)),r=devicePixelRatio||1;var v=d.cs.getImageData(Math.round((p.x+11)*r),Math.round(p.y*r),1,1).data;return [v[0],v[1],v[2],v[3]]})()")
  Check 'PB chart: the personal best has a purple ring around it' ($ringPx[2] -gt 200 -and $ringPx[0] -gt 140 -and $ringPx[1] -lt 150 -and $ringPx[3] -gt 200)
  # the order of the dots is the order of the lap times: a quicker session is higher
  $ordOk = $true; for ($a = 0; $a -lt $ss.Count; $a++) { for ($b = 0; $b -lt $ss.Count; $b++) { if ($a -ne $b -and -not $dots[$a].clip -and -not $dots[$b].clip -and [double]$ss[$a].best -lt [double]$ss[$b].best - 0.01 -and $dots[$a].y -ge $dots[$b].y) { $ordOk = $false } } }
  Check 'PB chart: whenever one session is 0.01 s or more quicker than another its dot is higher' $ordOk
  # the consistency chart: the best lap of a session is gold, other laps cool white; the heights follow the lap times
  $consOk = $true; $consN = 0
  for ($i = 0; $i -lt $ss.Count; $i++) {
    $s = $ss[$i]; $bi = [array]::IndexOf(@($s.lapN), [int]$s.bestLap)
    for ($lj = 0; $lj -lt @($s.lapT).Count; $lj++) {      # (not $j: PowerShell names are not case sensitive and $J is the reply)
      $pt = Cdp-Json "WB.careerPoint('cons', $i, $lj)"; if (-not $pt) { continue }
      $col = Cdp-Json "WB.careerColour('cons', $i, $lj)"; $consN++
      if ($lj -eq $bi) { if (-not (Gold $col)) { $consOk = $false; Note "cons best $i/$lj $($col -join ',')" } }
      elseif (Gold $col) { $consOk = $false; Note "cons lap $i/$lj is gold $($col -join ',')" }
    }
  }
  Check "consistency chart: the best lap of each session is the gold dot and the other $consN laps are not ($($ss.Count) sessions)" ($consOk -and $consN -ge 8)
  $hid = (Cdp-Json "WB.displays().filter(function(q){return q.kind==='careercons'})[0].hidden()")
  Note "consistency chart: $hid laps above the top of the scale are not drawn (the chart says how many)"
  # the corner grid: purple where that session holds the corner's best ever, red-tinted elsewhere, dark where there is no time
  $gridOk = $true; $purple = 0; $cells = 0
  $rowsK = Cdp-Json 'WB.displays().filter(function(q){return q.kind==="careergrid"})[0].rows'
  for ($r = 0; $r -lt @($rowsK).Count; $r++) {
    $k = [int]@($rowsK)[$r]; $ever = 1e9; foreach ($s in $ss) { if ($s.c[$k] -and [double]$s.c[$k][0] -lt $ever) { $ever = [double]$s.c[$k][0] } }
    for ($i = 0; $i -lt $ss.Count; $i++) {
      $col = Cdp-Json "WB.careerColour('grid', $i, $r)"; $cells++
      $c = $ss[$i].c[$k]
      if (-not $c) { if ($col[0] -gt 40 -or [math]::Abs($col[0] - $col[2]) -gt 12) { $gridOk = $false; Note "grid $r/$i should be dark: $($col -join ',')" } }
      elseif ([double]$c[0] -lt $ever + 0.0005) { $purple++; if (-not ($col[2] -gt 200 -and $col[0] -gt 140 -and $col[1] -lt 140)) { $gridOk = $false; Note "grid $r/$i should be purple: $($col -join ',')" } }
      else { if (-not ($col[0] -gt 35 -and $col[0] -gt $col[2] + 15 -and $col[2] -lt 200)) { $gridOk = $false; Note "grid $r/$i should be red: $($col -join ',')" } }
    }
  }
  Check "corner grid: $cells cells - purple exactly where a session holds the corner's best ever ($purple of them, at least one per corner), red-tinted elsewhere" ($gridOk -and $purple -ge @($rowsK).Count)
  # redder = further from the best: a bigger gap is a redder cell
  $a = Cdp-Json '(function(){var d=WB.displays().filter(function(q){return q.kind==="careergrid"})[0],best=null,worst=null;for(var r=0;r<d.rows.length;r++){var k=d.rows[r];for(var i=0;i<WB.career().n;i++){var c=d.colour(i,r);if(!c||c.indexOf("rgba")!==0)continue;var al=parseFloat(c.split(",")[3]);if(!best||al<best)best=al;if(!worst||al>worst)worst=al}}return [best,worst]})()'
  Check 'corner grid: the redness runs from faint (close to the best) to strong (far from it)' ($a[1] -gt $a[0] + 0.3)
  # layout
  $ov = Cdp-Json 'WB.overlaps()'
  Note "text boxes measured on CAREER: $($ov.boxes)"; if ($ov.bad.Count) { Note ('overlapping: ' + ($ov.bad -join '; ')) }
  Check 'no text overlaps another (canvas and DOM boxes measured)' ($ov.boxes -gt 120 -and $ov.bad.Count -eq 0)
  $pov = @(@(Cdp-Json $panelOverlapJs) | ForEach-Object { $_ } | Where-Object { "$_" -ne '' })
  Check 'no panel overlaps another panel (their boxes, not only their text)' ($pov.Count -eq 0)
  if ($pov.Count) { Note ('panels overlap: ' + (($pov | ForEach-Object { "$_" }) -join '; ')) }
  $small = Cdp-Json '(function(){var out=[];WB.textBoxes().forEach(function(b){if(b.h<12)out.push(b.s)});Array.prototype.forEach.call(document.querySelectorAll(".panel *, .top *"),function(e){if(!e.children.length&&e.textContent.trim()&&parseFloat(getComputedStyle(e).fontSize)<14)out.push(e.textContent.trim().slice(0,20)+" "+getComputedStyle(e).fontSize)});return out})()'
  Check 'every label is 14 px or larger (canvas and DOM)' (@($small).Count -eq 0)
  if (@($small).Count) { Note ('small: ' + (@($small) -join '; ')) }
  $clip = @($pg.titles | Where-Object { $_.clipped })
  Check 'no panel title is cut off' ($clip.Count -eq 0 -and @($pg.titles).Count -ge 6)
  $inside = Cdp-Json '(function(){var bad=[];Array.prototype.forEach.call(document.querySelectorAll(".panel"),function(p){var r=p.getBoundingClientRect();if(r.right>1888.5||r.left<31.5||r.bottom>1060||r.top<100)bad.push(p.className+" "+Math.round(r.left)+","+Math.round(r.top)+","+Math.round(r.right)+","+Math.round(r.bottom))});return bad})()'
  Check 'every panel is inside the screen margins and below the header (bottom at 1060 or less)' (@($inside).Count -eq 0)
  if (@($inside).Count) { Note ('outside: ' + (@($inside) -join '; ')) }
  $clipDom = Cdp-Json '(function(){var bad=[];Array.prototype.forEach.call(document.querySelectorAll("table.cc td, table.cth td, .cr-tile div, .cr-tc div, .cr-line"),function(e){if(e.scrollWidth>e.clientWidth+1)bad.push(e.textContent.trim().slice(0,24)+" "+e.scrollWidth+">"+e.clientWidth)});return bad})()'
  Check 'no table cell or tile text is clipped' (@($clipDom).Count -eq 0)
  if (@($clipDom).Count) { Note ('clipped: ' + (@($clipDom) -join '; ')) }
  # nothing rendered when asked for fewer than 5 points (rule 6): the charts are only drawn with 2 or more sessions, the tab rule covers it; a click opens that session's best lap
  $o = Cdp-Eval "WB.careerClick($($J.pb.i))"
  $enc = { param($s) [uri]::EscapeDataString($s).Replace('%20', '+') }      # URLSearchParams writes a space as +
  if ($o -ne ('workbench.html?id=' + (& $enc $pbName) + '&lap=7&page=driver')) { Note "click gave: $o" }
  Check 'a click on the PB session opens its best lap in the workbench (id = the file, lap 7)' ($o -eq ('workbench.html?id=' + (& $enc $pbName) + '&lap=7&page=driver'))
  $o3 = Cdp-Eval 'WB.careerClick(3)'
  Check 'a click on another session opens THAT session''s best lap' ($o3 -like ('workbench.html?id=' + (& $enc $ss[3].file) + '&lap=' + $ss[3].bestLap + '&*'))
  # hover: a guide on all three, a sentence about the session or the corner cell
  $null = Cdp-Eval "WB.careerHover(4, 2)"; Start-Sleep -Milliseconds 250
  $tb = Cdp-Json 'WB.textBoxes().map(function(b){return b.s})'
  $dayWord = ([datetime]'1970-01-01').AddMilliseconds([long]$ss[4].startMs).ToLocalTime().ToString('d MMM', [Globalization.CultureInfo]::GetCultureInfo('en-US')).ToUpper()
  $k2 = [int]@($rowsK)[2]
  Check 'hover on a corner cell of session 5: a sentence with the corner, the session, its time, the distance from the best ever and the laps' (@($tb | Where-Object { $_ -like "*$DOT*" -and $_ -like "*$dayWord*" -and ($_ -like '*FROM BEST*' -or $_ -like '*BEST EVER*') -and $_ -like '*LAP*' }).Count -ge 1)
  Check 'hover on a session: the PB chart says its best lap and lap number, the consistency chart the best-5 average with the spread (both name the clean laps)' (@($tb | Where-Object { $_ -like '*BEST 1:*LAP *CLEAN LAP*' }).Count -eq 1 -and @($tb | Where-Object { $_ -like '*BEST 5 AVERAGE 1:*SPREAD *CLEAN LAP*' }).Count -eq 1)
  Cdp-Shot (Join-Path $shots 'wb-career-hover.png')
  $null = Cdp-Eval 'WB.careerHover(null, null)'
  Start-Sleep -Milliseconds 200
  Cdp-Shot (Join-Path $shots 'wb-career.png')
  # MEDIAN
  $null = Cdp-Eval 'document.querySelector(".chip[data-m=med]").click()'; Start-Sleep -Milliseconds 300
  $pgm = Cdp-Json 'WB.career()'
  $tcm = Trend-Check $pgm $J 'med'
  if (-not $tcm.ok) { Note "median table: $($tcm.why)" }
  Check 'MEDIAN: the corner table and the grid follow (the same 14 rows, now each session''s median time through the corner)' ($pgm.mode -eq 'med' -and $tcm.ok -and (@($pgm.titles | Where-Object { $_.kind -eq 'careertrend' })[0].text) -like '*median*')
  $mcol = Cdp-Json "WB.careerColour('grid', 0, 0)"
  Check 'MEDIAN: the grid is redrawn (purple marks the best median ever)' ($null -ne $mcol)
  Cdp-Shot (Join-Path $shots 'wb-career-median.png')
  Cdp-Eval 'document.querySelector(".chip[data-m=best]").click()' | Out-Null
  # keyboard: B toggles, 9 opens the page
  $null = Cdp-Eval 'WB.cmd("page","driver")'; Start-Sleep -Milliseconds 200
  $null = Cdp-Eval 'document.dispatchEvent(new KeyboardEvent("keydown",{key:"9"}))'; Start-Sleep -Milliseconds 250
  Check 'the key 9 opens CAREER from another page' ((Cdp-Json 'WB.state').page -eq 'career')
  $null = Cdp-Eval 'document.dispatchEvent(new KeyboardEvent("keydown",{key:"b"}))'; Start-Sleep -Milliseconds 200
  Check 'the key B switches BEST / MEDIAN' ((Cdp-Json 'WB.career()').mode -eq 'med')
  $null = Cdp-Eval 'document.dispatchEvent(new KeyboardEvent("keydown",{key:"b"}))'
  Check 'cost: the page''s overlay frame stays under 8 ms (3 charts + grid)' ((Cdp-Eval 'WB.bench(60)') -lt 8)
  Check 'no JavaScript error on any of it' ($script:cdp.errors.Count -eq 0)
  # nine tabs (DRIVER GRIP BRAKING TYRES SUSP SPLITS VIDEO RACE CAREER) must fit the header with room left for the mode words
  $fit = Cdp-Json '(function(){var t=document.getElementById("tabs");t.className="tabs many";t.innerHTML=["DRIVER","GRIP","BRAKING","TYRES","SUSP.","SPLITS","VIDEO","RACE","CAREER"].map(function(n,i){return "<span class=\""+(n==="CAREER"?"on":"")+"\">"+n+"</span>"}).join("");var r=t.getBoundingClientRect(),vs=document.getElementById("vs").getBoundingClientRect(),br=document.querySelector(".brand").getBoundingClientRect();return {right:r.right,vsLeft:vs.left,width:r.width}})()'
  Note "nine tabs: they end at $([math]::Round($fit.right)) px, the lap times start at $([math]::Round($fit.vsLeft)) px"
  Check 'nine tabs fit the header with at least 120 px before the lap times (room for the mode words)' ($fit.right + 120 -lt $fit.vsLeft)
  Cdp-Shot (Join-Path $shots 'wb-career-tabs9.png')
  Cdp-Close

  # --- with races ---
  Cdp-Open ($fxBase + '&page=career&careerdata=' + (FxUrl $racesFx) + '&carbase=' + $apiBase)      # CP-1: the page is a file here, so the pictures come from the running irdash (carpics.js ?carbase=)
  $ready = Wait-Page
  $pr = Cdp-Json 'WB.career()'
  Check 'with a race log the RACES panel appears: 1 logged, 0 won, P2 OF 3, +2.345 s, 3 cars' ($ready -and @($pr.races).Count -eq 1 -and $pr.races[0][1] -eq 'P2 OF 3' -and $pr.races[0][2] -eq '+2.345 s' -and $pr.races[0][3] -like '3 CARS*3 LAPS' -and (@($pr.titles | Where-Object { $_.kind -eq 'careerraces' })[0].text) -like "Races $DOT 1 logged $DOT 0 won*")
  $ov = Cdp-Json 'WB.overlaps()'
  $low = @(@(Cdp-Json '(function(){var bad=[];Array.prototype.forEach.call(document.querySelectorAll(".panel"),function(p){var r=p.getBoundingClientRect();if(r.bottom>1060)bad.push(p.className+" "+Math.round(r.left)+","+Math.round(r.top)+","+Math.round(r.right)+","+Math.round(r.bottom))});return bad})()') | ForEach-Object { $_ } | Where-Object { "$_" -ne '' })
  if ($ov.bad.Count -or $low.Count) { Note ("races page: overlapping " + (($ov.bad | ForEach-Object { "$_" }) -join "; ") + " / low panels " + (($low | ForEach-Object { "$_" }) -join "; ")) }
  $pov2 = @(@(Cdp-Json $panelOverlapJs) | ForEach-Object { $_ } | Where-Object { "$_" -ne '' }); if ($pov2.Count) { Note ('panels overlap: ' + (($pov2 | ForEach-Object { "$_" }) -join '; ')) }
  Check 'with the races panel nothing overlaps (text or panels) and nothing is outside' ($ov.bad.Count -eq 0 -and $low.Count -eq 0 -and $pov2.Count -eq 0)
  # CP-1: the race row shows iRacing's own picture of his car in its first column (no drawn car: cars.js CARS_DRAWN = false), the four text cells keep their order
  $rowJs = '(function(){var row=document.querySelector(".cr-race"),d=row.querySelector(".d"),f=row.querySelector(".crcar .cpic"),im=f&&f.querySelector("img"),rr=row.getBoundingClientRect(),fr=f?f.getBoundingClientRect():null,dr=d.getBoundingClientRect();return {pcars:document.querySelectorAll("svg.pcar").length,api:typeof window.PCars,dormant:typeof window.PCarsDormant,pic:row.className.indexOf("pic")>=0,kids:row.children.length,cols:getComputedStyle(row).gridTemplateColumns,hasF:!!f,nat:im?im.naturalWidth:0,src:im?im.getAttribute("src"):"",w:fr?fr.width:0,h:fr?fr.height:0,inRow:fr?(fr.left>=rr.left-0.5&&fr.right<=dr.left+0.5&&fr.top>=rr.top&&fr.bottom<=rr.bottom):false,off:d.getBoundingClientRect().left-rr.left,broken:[].filter.call(document.querySelectorAll("img"),function(i){return i.complete&&i.naturalWidth===0}).length,text:row.textContent.replace(/\s+/g," ").trim()}})()'
  for ($w = 0; $w -lt 40; $w++) { if ((Cdp-Eval '[].every.call(document.querySelectorAll(".crcar img"), function (i) { return i.complete; }) && document.querySelectorAll(".crcar img").length >= 1') -eq $true) { break }; Start-Sleep -Milliseconds 250 }
  $cv = Cdp-Json $rowJs
  Check "CP-1: the race row has iRacing's own picture of his Corvette in the first column: loaded ($($cv.nat) px wide, $($cv.src)), $([math]::Round($cv.w)) x $([math]::Round($cv.h)) px, inside the row and left of the date ($($cv.inRow)); five cells, columns $($cv.cols); no drawn car (svg.pcar $($cv.pcars), window.PCars is $($cv.api)), no broken image ($($cv.broken))" ($cv.hasF -and $cv.nat -eq 480 -and $cv.src -like '*/cars/chevyvettez06rgt3.jpg' -and [math]::Abs($cv.w - 64) -lt 0.6 -and [math]::Abs($cv.h - 23.3) -lt 0.8 -and $cv.inRow -and $cv.pic -and $cv.kids -eq 5 -and $cv.pcars -eq 0 -and $cv.api -eq 'undefined' -and $cv.dormant -eq 'object' -and $cv.cols -match '^76px 66px 168px' -and $cv.broken -eq 0)
  Cdp-Shot (Join-Path $shots 'cars-career.png')
  $null = Cdp-Eval 'document.querySelector(".cr-race.go").click()'
  Check 'a click on the race opens that session''s RACE page (page=race and the race log id)' ((Cdp-Json 'WB.career()').opened -like '*page=race*race=f20261010-001400-2*')
  Cdp-Shot (Join-Path $shots 'wb-career-races.png')
  Check 'no JavaScript error' ($script:cdp.errors.Count -eq 0)
  Cdp-Close
  # CP-1: a race in a car iRacing has no picture of, and a race log from before CarPath was logged: NO picture, no empty frame, no broken image, the row as it was
  foreach ($variant in @(@('a car without a picture on iRacing''s server', '"cpath":"unknowncar99"'), @('a race log with no CarPath', '"cpath":""'))) {
    $nopicFx = Join-Path $work 'career-races-nopic.json'
    $txt = [regex]::Replace($c6.text, '"cpath":"[^"]*"', $variant[1]); [IO.File]::WriteAllText($nopicFx, $txt, (New-Object Text.UTF8Encoding($false)))
    Cdp-Open ($fxBase + '&page=career&careerdata=' + (FxUrl $nopicFx) + '&carbase=' + $apiBase)
    $ready = Wait-Page; Start-Sleep -Milliseconds 800
    $cv = Cdp-Json $rowJs
    $frames = [int](Cdp-Eval 'document.querySelectorAll(".cpic").length')
    Check "CP-1: $($variant[0]): the race row has no picture and no empty frame ($frames), four cells starting at the left edge ($([math]::Round($cv.off)) px in; columns $($cv.cols)), no broken image ($($cv.broken))" ($ready -and -not $cv.hasF -and $frames -eq 0 -and -not $cv.pic -and $cv.kids -eq 4 -and $cv.off -le 2 -and $cv.cols -match '^74px 170px 150px' -and $cv.broken -eq 0)
    Check 'no JavaScript error' ($script:cdp.errors.Count -eq 0)
    Cdp-Close
  }

  Section '10. the live endpoint (the deployed irdash)'
  $depl = Get-Item (Join-Path $root 'dash\irdash.exe')
  $src = Get-Item (Join-Path $root 'dash\src\career.cs')
  $probe = $null; try { $probe = Get-Raw '/analysis/career' } catch { }
  if (-not $probe -or $probe.code -ne 400) {
    Note "SKIPPED: the running irdash does not have /analysis/career yet (irdash.exe $($depl.LastWriteTime), career.cs $($src.LastWriteTime), probe code $(if ($probe) { $probe.code } else { 'none' })). Deploy with dash\build.ps1 when the sim is off, then run this test again."
  } else {
    Check 'the route exists: without id= or car= it answers 400 with an error' ($probe.code -eq 400 -and $probe.body -like '*need id=*')
    $logN = @(Get-Content (Join-Path $root 'dash\irdash.log')).Count
    for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { Write-Host ('  waiting for the deploy lock (' + (Get-Content $lock) + ')'); Start-Sleep -Seconds 30 }
    Assert-RigFree -Where 'before the live part'
    Set-Content $lock 'career-test'; $lockMade = $true
    Set-Content $hook 'on for the test'; $hookMade = $true
    Start-Sleep -Milliseconds 400
    # a fresh scratch vault for the live run, so the first call really has to read the files
    $liveV = Join-Path $work 'vault-live'; New-Item -ItemType Directory -Force (Join-Path $liveV 'telemetry\chevrolet-corvette-z06-gt3-r') | Out-Null
    Copy-Item -Recurse -Force (Join-Path $vaultDir 'telemetry\*') (Join-Path $liveV 'telemetry')
    $u = "/analysis/career?id=$(Q $pbName)&dir=$(Q $script:telDir)&vault=$(Q $liveV)"
    $sw = [Diagnostics.Stopwatch]::StartNew(); $first = Get-Raw ($u + '&drop=1'); $sawBuilding = $false; $polls = 0      # drop=1 once: the running irdash may still hold these files in memory from an earlier run of this test
    while ($first.code -eq 200 -and $first.body -like '{"building":true*' -and $sw.Elapsed.TotalSeconds -lt 120) { $sawBuilding = $true; $polls++; Start-Sleep -Milliseconds 500; $first = Get-Raw $u }
    $firstMs = $sw.ElapsedMilliseconds
    Note "live: first call answered ready after $firstMs ms ($polls polls while building: $sawBuilding)"
    Check 'the first call starts the work in the background (answers building with the count) and then answers the career' ($sawBuilding -and $first.code -eq 200 -and $first.body -like '{"v":1,*')
    Check 'the live answer is the same career as the offline one (the same 7 sessions, the same numbers)' ((NoStats $first.body) -eq (NoStats $c1text))
    $sw.Restart(); $second = Get-Raw $u; $secondMs = $sw.ElapsedMilliseconds
    $j2 = $second.body | ConvertFrom-Json
    Note "live: second call $secondMs ms (the engine says $($j2.stats.ms) ms), from memory: $($j2.stats.mem), read from disk $($j2.stats.disk), read from the files $($j2.stats.computed)"
    Check 'the second call reads nothing (all 7 from memory) and is fast' ($second.code -eq 200 -and $j2.stats.mem -eq 7 -and $j2.stats.computed -eq 0 -and $j2.stats.disk -eq 0 -and $secondMs -lt 600)
    $third = Get-Raw ($u + '&drop=1'); $j3 = $third.body | ConvertFrom-Json
    Check 'with the memory dropped the answer comes from the files on disk (7), no .ibt is read, same career' ($third.code -eq 200 -and $j3.stats.disk -eq 7 -and $j3.stats.computed -eq 0 -and (NoStats $third.body) -eq (NoStats $first.body))
    Start-Sleep -Milliseconds 500
    $log = @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logN)
    Check 'irdash.log says what it did: "career: read 7 of 7 sessions ... in N s"' (@($log | Where-Object { $_ -match 'career: read 7 of 7 sessions' }).Count -ge 1 -and @($log | Where-Object { $_ -match 'career.*(Exception|failed)' }).Count -eq 0)
    Check 'a file that is not there is a 404 with an error; a request with nothing to go on is a 400' ((Get-Raw '/analysis/career?id=no-such-file.ibt').code -eq 404 -and (Get-Raw '/analysis/career?car=x').code -eq 400)
    $byCar = Get-Raw ("/analysis/career?car=$(Q $J.car)&track=$(Q $J.track)&config=$(Q $J.config)&dir=$(Q $script:telDir)&vault=$(Q $liveV)")
    Check 'by car and track names (what a page without a file would use) it is the same career' ($byCar.code -eq 200 -and (NoStats $byCar.body) -eq (NoStats $first.body))
    # the page against the live endpoint (still fixtures for the lap)
    Cdp-Open ($fxBase + '&page=career&careerdata=' + [uri]::EscapeDataString("$apiBase$u"))
    $ready = Wait-Page
    $pl = Cdp-Json 'WB.career()'
    Check 'the page can read the live endpoint across origins (CORS) and shows the same career: 7 sessions, the PB tile' ($ready -and $pl.n -eq 7 -and $pl.tiles[0] -like "*$(Fmt $J.pb.time)*" -and $script:cdp.errors.Count -eq 0)
    Cdp-Close
    # 503 while he drives: the test hook pretends he is on track
    Fake 'IsOnTrack=1&OnPitRoad=0&SessionNum=2&PlayerCarIdx=0&Lap=4&LapDistPct=0.4&Speed=45&Gear=4&SessionFlags=0'
    Start-Sleep -Milliseconds 2600
    $drv = Get-Raw $u
    Check 'while he drives (pretend, test hook) the career is refused with 503 and says "Not while driving"' ($drv.code -eq 503 -and $drv.body -like '*Not while driving*')
    Cdp-Open ($fxBase + '&page=career&careerdata=' + [uri]::EscapeDataString("$apiBase$u"))
    $ready = Wait-Page
    $pw = Cdp-Json 'WB.career()'
    Check 'the page says so: "Not while driving" (and keeps asking in the background)' ($ready -and $pw.state -eq 'wait' -and $pw.text -like '*Not while driving*')
    Cdp-Shot (Join-Path $shots 'wb-career-driving.png')
    Cdp-Close
    Fake 'IsOnTrack=0&Speed=0'; Start-Sleep -Milliseconds 800
    $after = Get-Raw $u
    Check 'out of the car again: the same call answers the career' ($after.code -eq 200 -and $after.body -like '{"v":1,*')
    # the reader stops the moment he gets in the car and goes on where it was when he is out again (test hook: slow= pauses after every file)
    $slowV = Join-Path $work 'vault-slow'; New-Item -ItemType Directory -Force (Join-Path $slowV 'telemetry') | Out-Null
    Copy-Item -Recurse -Force (Join-Path $vaultDir 'telemetry\*') (Join-Path $slowV 'telemetry')
    $us = "/analysis/career?id=$(Q $pbName)&dir=$(Q $script:telDir)&vault=$(Q $slowV)&slow=700"
    $logN2 = @(Get-Content (Join-Path $root 'dash\irdash.log')).Count
    $sb1 = Get-Raw ($us + '&drop=1')
    Check 'a slow first call starts the reader and answers building with 0 of 7 done' ($sb1.code -eq 200 -and $sb1.body -like '{"building":true,"done":*,"of":7,*')
    Start-Sleep -Milliseconds 1500
    Fake 'IsOnTrack=1&OnPitRoad=0&SessionNum=2&PlayerCarIdx=0&Lap=4&LapDistPct=0.4&Speed=45&Gear=4&SessionFlags=0'
    Start-Sleep -Milliseconds 1800
    $sb2 = Get-Raw $us
    Check 'he is in the car: the career answers 503, and the reader has stopped by itself' ($sb2.code -eq 503 -and $sb2.body -like '*Not while driving*')
    $log2 = @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logN2)
    $stopLine = @($log2 | Where-Object { $_ -match 'career: read (\d+) of 7 sessions .*stopped: you got in the car' })
    $doneBefore = if ($stopLine.Count -eq 1) { [int]([regex]::Match($stopLine[0], 'read (\d+) of 7').Groups[1].Value) } else { -1 }
    Check "irdash.log says it stopped after $doneBefore of 7 files (some done, not all)" ($stopLine.Count -eq 1 -and $doneBefore -ge 1 -and $doneBefore -le 6)
    Fake 'IsOnTrack=0&Speed=0'; Start-Sleep -Milliseconds 800
    $sb3 = Get-Raw $us; $guard = 0
    while ($sb3.code -eq 200 -and $sb3.body -like '{"building":true*' -and $guard -lt 120) { Start-Sleep -Milliseconds 500; $sb3 = Get-Raw $us; $guard++ }
    Start-Sleep -Milliseconds 1500      # the reader writes its log line after its last pause (slow=700)
    $log3 = @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logN2)
    $left = 7 - $doneBefore
    if (-not ($sb3.code -eq 200 -and (NoStats $sb3.body) -eq (NoStats $c1text))) { Note ("resume: code {0}, same answer {1}, body starts {2}" -f $sb3.code, ((NoStats $sb3.body) -eq (NoStats $c1text)), $sb3.body.Substring(0, [math]::Min(120, $sb3.body.Length))) }
    Note ("resume: log lines: " + ((@($log3 | Where-Object { $_ -match 'career' }) | ForEach-Object { $_.Substring(20) }) -join ' || '))
    Check "out of the car again it goes on with the $left files that were left (not all 7 again) and answers the same career" ($sb3.code -eq 200 -and (NoStats $sb3.body) -eq (NoStats $c1text) -and @($log3 | Where-Object { $_ -match "career: read $left of $left sessions" -and $_ -notmatch 'stopped' }).Count -eq 1)
    # a real request cannot point irdash at another folder: without the hook dir= and vault= are ignored
    Remove-Item $hook -ErrorAction SilentlyContinue; $hookMade = $false; Start-Sleep -Milliseconds 400
    $real = Get-Raw "/analysis/career?id=$(Q $pbName)&dir=$(Q $script:telDir)&vault=$(Q $liveV)"
    $guard = 0; while ($real.code -eq 200 -and $real.body -like '{"building":true*' -and $guard -lt 120) { Start-Sleep -Milliseconds 500; $real = Get-Raw "/analysis/career?id=$(Q $pbName)&dir=$(Q $script:telDir)&vault=$(Q $liveV)"; $guard++ }
    $rj = if ($real.code -eq 200) { $real.body | ConvertFrom-Json } else { $null }
    Check 'without the test hook dir= and vault= are ignored: the real telemetry folder answers (more than the 7 copies)' ($real.code -eq 200 -and $rj.totals.files -gt 20)
    if ($rj) {
      Note ("REAL DATA: {0} sessions, {1} laps, {2} clean, PB {3} (lap {4}), theoretical {5}, {6} h driven" -f $rj.totals.sessions, $rj.totals.laps, $rj.totals.valid, $rj.pb.time, $rj.pb.lap, $rj.theoretical.time, [math]::Round($rj.totals.seconds / 3600, 1))
      Check 'the real Corvette career: 12 or more sessions, the PB is 1:19.549 or better, the theoretical best is quicker than the PB' ($rj.totals.sessions -ge 12 -and $rj.pb.time -le 79.5495 -and $rj.theoretical.time -lt $rj.pb.time)
    }
  }
} finally {
  Cdp-Close
  if ($hookMade) { Remove-Item $hook -ErrorAction SilentlyContinue }
  if ($lockMade) { Remove-Item $lock -ErrorAction SilentlyContinue }
  Exit-TestLock
  try { $null = Invoke-WebRequest -UseBasicParsing "$apiBase/api/test/end" -TimeoutSec 5 } catch { }
  try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
$secs = [math]::Round(((Get-Date) - $t0).TotalSeconds)
Write-Host ("career-test: {0} passed, {1} failed. Pictures in {2} (wb-career*.png). {3} s" -f $pass, $fail, $shots, $secs)
if ($fail -gt 0) { exit 1 }
