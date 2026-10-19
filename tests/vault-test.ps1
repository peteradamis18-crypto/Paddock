# Vault test (WS17 V1 + V2, docs\vault.md): saving laps and races by the rules from real telemetry files, the budget, the KEEP and CLIP keys, a
# generated test video attached to the right lap with its sync checked, the routes, and the real page in headless Chrome.
# Nothing touches Peter's real Vault: irdash is switched to a scratch vault under vault-test\ (its own telemetry and "NVIDIA" folders).
# Real telemetry files are only COPIED (the copies are patched where a race must end on the podium); no video is ever recorded from a screen:
# the test clip is made by ffmpeg from a synthetic picture. Pictures go to tests\shots\v-*.png.
#   powershell -ExecutionPolicy Bypass -File tests\vault-test.ps1            (irdash on port 8199 must be the current build)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = if ($env:VAULT_TEST_API) { $env:VAULT_TEST_API } else { 'http://localhost:8199' }
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Note($what) { "  info  $what" }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
function J($path) { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 600; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
function Get-Raw($path, $headers) {
  $rq = [Net.HttpWebRequest]::Create("$api$path"); $rq.Timeout = 60000
  if ($headers) { foreach ($k in $headers.Keys) { if ($k -eq 'Range') { $null = $rq.AddRange('bytes', [long]($headers[$k] -replace '^bytes=(\d*)-.*$', '$1')) } else { $rq.Headers.Add($k, $headers[$k]) } } }
  try { $resp = $rq.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { return @{ code = 0; body = $_.Exception.Message; bytes = @() } } }
  $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms); $b = $ms.ToArray(); $c = [int]$resp.StatusCode
  $h = @{}; foreach ($k in $resp.Headers.AllKeys) { $h[$k] = $resp.Headers[$k] }; $resp.Close()
  return @{ code = $c; body = [Text.Encoding]::UTF8.GetString($b); bytes = $b; headers = $h }
}
function Q($s) { [uri]::EscapeDataString($s) }
# One card per lap: a lap and its video share a session file and a lap number, so they are one card.
function Count-Cards($moments) {
  $seen = @{}
  $n = 0
  foreach ($m in @($moments)) {
    $lapN = 0; if ($m.lap) { $lapN = [int]$m.lap }
    $k = ''
    if ("$($m.kind)" -ne 'race' -and $lapN -gt 0 -and "$($m.session)") { $k = "$($m.session)|$lapN" }
    if ($k) { if ($seen.ContainsKey($k)) { continue }; $seen[$k] = $true }
    $n++
  }
  return $n
}

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; $title }

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System; using System.IO; using System.Text;
public static class IbtPatch {
  // sets PlayerCarPosition / PlayerCarClassPosition (and SessionState when state > 0) in the last n records of a COPY of a real file,
  // so a real race ends where the test needs it (a podium, a win)
  public static string SetFinish(string path, int pos, int state, int n) {
    using (var fs = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) {
      byte[] h = new byte[144]; fs.Read(h,0,144);
      int nv=BitConverter.ToInt32(h,24), vo=BitConverter.ToInt32(h,28), bl=BitConverter.ToInt32(h,36), doff=BitConverter.ToInt32(h,52);
      byte[] vh = new byte[nv*144]; fs.Position=vo; fs.Read(vh,0,vh.Length); int o1=-1,o2=-1,o3=-1;
      for(int i=0;i<nv;i++){int b=i*144; int len=Array.IndexOf(vh,(byte)0,b+16,32)-(b+16); if(len<0)len=32; string nm=Encoding.ASCII.GetString(vh,b+16,len); int off=BitConverter.ToInt32(vh,b+4);
        if(nm=="PlayerCarPosition")o1=off; if(nm=="PlayerCarClassPosition")o2=off; if(nm=="SessionState")o3=off;}
      long recs=(fs.Length-doff)/bl; byte[] p = BitConverter.GetBytes(pos), s = BitConverter.GetBytes(state);
      for(long r=Math.Max(0,recs-n); r<recs; r++){ fs.Position=doff+r*bl+o1; fs.Write(p,0,4); fs.Position=doff+r*bl+o2; fs.Write(p,0,4); if(state>0){ fs.Position=doff+r*bl+o3; fs.Write(s,0,4);} }
      return "patched " + n + " records";
    }
  }
}
'@ -ErrorAction SilentlyContinue
# L-1: an independent reader of the raw records (nothing of Paddock's code): did iRacing count this lap? iRacing's own best lap of the session (LapBestLapTime) is the
# evidence, read at the last record of the lap and 1.5 to 2.5 s after the line: a lap quicker than the best so far that BECAME the best was counted (whatever the off-track
# record says), a quicker lap that left the best unchanged was not; a lap not quicker than the best so far gives no evidence and any off-track record (PlayerTrackSurface 0) decides.
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.IO; using System.Text;
public static class LapRaw {
  static Dictionary<string,int> Vars(byte[] b) {
    int nv = BitConverter.ToInt32(b, 24), vho = BitConverter.ToInt32(b, 28); var v = new Dictionary<string,int>();
    for (int i = 0; i < nv; i++) { int p = vho + 144 * i; v[Encoding.ASCII.GetString(b, p + 16, 32).Trim('\0')] = BitConverter.ToInt32(b, p + 4); }
    return v;
  }
  public static bool Counted(string file, int lap, double time) {
    byte[] b = File.ReadAllBytes(file); var v = Vars(b);
    int bl = BitConverter.ToInt32(b, 36), bo = BitConverter.ToInt32(b, 52), rc = (b.Length - bo) / bl, first = -1; bool off = false;
    for (int r = 0; r < rc; r++) { int s = bo + r * bl; if (BitConverter.ToInt32(b, s + v["Lap"]) == lap && b[s + v["IsOnTrack"]] != 0 && BitConverter.ToInt32(b, s + v["PlayerTrackSurface"]) == 0) { off = true; break; } }
    for (int r = 0; r < rc; r++) { int s = bo + r * bl; if (BitConverter.ToInt32(b, s + v["Lap"]) == lap + 1 && b[s + v["IsOnTrack"]] != 0) { first = r; break; } }
    if (first < 1) return false;
    double before = BitConverter.ToSingle(b, bo + (first - 1) * bl + v["LapBestLapTime"]); if (before <= 1) before = -1;
    double best = -1;
    for (int r = first + 90; r < Math.Min(rc, first + 150); r++) { double x = BitConverter.ToSingle(b, bo + r * bl + v["LapBestLapTime"]); if (x > 1 && (best < 0 || x < best)) best = x; }
    bool faster = before <= 0 || time < before - 0.0015;
    if (faster) return best > 0 && best <= time + 0.0015;
    return !off;
  }
  public static double BestLap(string file) {
    byte[] b = File.ReadAllBytes(file); var v = Vars(b);
    int bl = BitConverter.ToInt32(b, 36), bo = BitConverter.ToInt32(b, 52), rc = (b.Length - bo) / bl; double best = -1;
    for (int r = 0; r < rc; r++) { double x = BitConverter.ToSingle(b, bo + r * bl + v["LapBestLapTime"]); if (x > 15 && (best < 0 || x < best)) best = x; }
    return best;
  }
}
'@ -ErrorAction SilentlyContinue

# ---- cdp: headless Chrome with the DevTools protocol (no window) ----
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('vault-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9371
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', '--autoplay-policy=no-user-gesture-required', 'about:blank') -PassThru -WindowStyle Hidden
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0 }
  $null = Cdp 'Page.enable' @{}
  $null = Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = "window.__errs = []; window.addEventListener('error', function (e) { window.__errs.push(String(e.message)); });" }
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
    if ($o.id -eq $c.id) { return $o }
  }
}
function Cdp-Eval($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return "js error: " + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
function Cdp-Shot($path, $x, $y, $w, $h) {
  $s = Cdp 'Page.captureScreenshot' @{ format = 'png'; clip = @{ x = $x; y = $y; width = $w; height = $h; scale = 1 } }
  [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data))
}
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
function Gold-Pixels($path) {
  $bmp = New-Object System.Drawing.Bitmap $path; $n = 0
  for ($yy = 0; $yy -lt $bmp.Height; $yy += 2) { for ($xx = 0; $xx -lt $bmp.Width; $xx += 2) { $c = $bmp.GetPixel($xx, $yy); if ($c.R -gt 215 -and $c.G -gt 165 -and $c.G -lt 215 -and $c.B -lt 90) { $n++ } } }
  $bmp.Dispose(); return $n
}
function Wait-Page($expr, $secs = 30) { for ($i = 0; $i -lt ($secs * 4); $i++) { $v = Cdp-Eval $expr; if ($v -eq $true) { return $true }; Start-Sleep -Milliseconds 250 }; return $false }
# ---- end cdp ----

# the deploy lock: nobody rebuilds irdash while this test needs it (same rule as the other tests)
Enter-TestLock 'vault'   # one live test at a time (tests\guard.ps1); released in finally
$lock = Join-Path $root 'dash\deploy.lock'
for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock (' + (Get-Content $lock) + ')'; Start-Sleep -Seconds 60 }
Set-Content $lock ('vault ' + (Get-Date).ToString('HH:mm:ss'))
$hook = Join-Path $root 'dash\test-hook.on'
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$tdir = Join-Path $root 'vault-test'; $src = Join-Path $tdir 'src'; $nv = Join-Path $tdir 'nvidia'
$ffmpeg = Join-Path $root 'vault\bin\ffmpeg.exe'
$epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
$logN = (Get-Content (Join-Path $root 'dash\irdash.log') | Measure-Object).Count
'Vault test'
try {
Set-Content $hook 'vault test'

Section '1. the scratch vault and the real telemetry copies'
if (Test-Path $tdir) { Remove-Item $tdir -Recurse -Force }
New-Item -ItemType Directory -Force $src, $nv | Out-Null
function Fx($name, $pos, $state) {
  $s = Join-Path $tel $name; $d = Join-Path $src $name; Copy-Item $s $d -Force; $t = (Get-Item $s).LastWriteTime; (Get-Item $d).LastWriteTime = $t
  if ($pos) { $null = [IbtPatch]::SetFinish($d, $pos, $state, 3000); (Get-Item $d).LastWriteTime = $t }
}
$f1 = 'chevyvettez06rgt3_roadatlanta full 2026-10-06 21-20-59.ibt'     # 3 clean laps, best 80.191
$f2 = 'chevyvettez06rgt3_roadatlanta full 2026-10-07 09-20-50.ibt'     # best 80.532: slower, no personal best
$f3 = 'chevyvettez06rgt3_roadatlanta full 2026-10-07 21-31-29.ibt'     # an AI race, 80.082 (a PB); the copy is patched to finish P1 = a WIN
$f4 = 'chevyvettez06rgt3_roadatlanta full 2026-10-09 14-58-37.ibt'     # 79.600 (a PB)
$f5 = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt'     # the real 79.549 race; the copy is patched to finish P2 of 22 = a PODIUM
$f6 = 'toyotagr86_limerock 2019 gp 2026-10-09 18-08-37.ibt'            # an ordinary test drive with no clean lap
Fx $f1; Fx $f3 1 6; Fx $f4; Fx $f5 2 0; Fx $f6      # $f2 comes later, for the KEEP key
Check 'five real telemetry files copied into the scratch folder (the originals are only read)' (@(Get-ChildItem $src -Filter *.ibt).Count -eq 5)
$r = J '/vault/test/sandbox?on=1&reset=1'
$null = J '/vault/test/rec?cmd=reindex'      # a fresh run must not inherit the recorder clips of the last one (in-memory list)
Check 'irdash switched to the scratch vault (the real Vault is untouched)' ($r.sandbox -eq $true -and $r.root -like '*vault-test*')
$st0 = J '/vault'
Check 'the status says it is a test vault and starts empty' ($st0.sandbox -eq $true -and $st0.keepers -eq 0 -and $st0.sessions -eq 0)

Section '2. automatic saving from real files (V1)'
$sw = [Diagnostics.Stopwatch]::StartNew(); $r = J '/vault/test/scan'; $secs = $sw.Elapsed.TotalSeconds
Check "all five files were read in $([math]::Round($secs, 1)) s ($($r.sessions) sessions)" ($r.sessions -eq 5)
$l = J '/vault/list'
$byId = @{}; foreach ($m in $l.moments) { $byId[$m.id] = $m }
function Tags($id) { if ($byId.ContainsKey($id)) { (@($byId[$id].tags) -join ',') } else { 'none' } }
function Has($obj, $t) { $null -ne $obj -and @($obj.tags) -contains $t }   # one JSON tag comes back as a string, not a one-item list
$wallIds = @($l.moments | ForEach-Object { $_.id })
Check 'a new personal best is kept: 79.549 (the race''s lap 7) and 79.600 carry PB' ((Tags 'l20261010-041318-7') -match 'PB' -and (Tags 'l20261009-185837-2') -match 'PB')
Check 'the best three laps ever on this car and track carry BEST LAP: 79.549, 79.600, and 79.878' ((Tags 'l20261010-041318-7') -match 'BEST LAP' -and (Tags 'l20261009-185837-2') -match 'BEST LAP' -and (Tags 'l20261010-041318-8') -match 'BEST LAP')
$top10 = @($l.moments | Where-Object { Has $_ 'TOP 10' })
Check "the fastest tenth is kept ($($top10.Count) laps marked TOP 10), including the personal best, and each one is a keeper" ($top10.Count -ge 1 -and ($top10 | Where-Object { $_.id -eq 'l20261010-041318-7' }) -and @($top10 | Where-Object { -not $_.keeper }).Count -eq 0)
Check 'a slower lap that beat nothing (80.191) is not a keeper and is outside the fastest tenth; it stays as a recent item' ($byId['l20261007-012059-2'].keeper -eq $false -and (Tags 'l20261007-012059-2') -notmatch 'TOP 10')
$pbBefore = $byId['l20261010-041318-7'].pbBefore
Check "the PB remembers what it beat (79.600): pbBefore $pbBefore" (Near $pbBefore 79.600 0.002)
$race = $byId['r20261010-041318']
Check 'a race finished P2 of 20 (the file lists 20 drivers and the pace car; it used to say 22) is a PODIUM keeper with its place and field' ($race -and $race.kind -eq 'race' -and $race.pos -eq 2 -and $race.field -eq 20 -and (Has $race 'PODIUM') -and $race.keeper -eq $true)
$win = @($l.moments | Where-Object { $_.kind -eq 'race' -and $_.pos -eq 1 })
Check 'a race finished P1 is a WIN keeper' ($win.Count -eq 1 -and (Has $win[0] 'WIN') -and $win[0].keeper -eq $true)
$bigMiss = @($l.moments | Where-Object { $_.kind -eq 'race' -and $_.irDelta -ge 40 -and -not (Has $_ 'BIG IR') })
$bigExtra = @($l.moments | Where-Object { $_.kind -eq 'race' -and $_.irDelta -lt 40 -and (Has $_ 'BIG IR') })
Check 'an iRating gain of 40 or more is marked BIG IR, and a smaller gain is not' ($bigMiss.Count -eq 0 -and $bigExtra.Count -eq 0)
Check 'the ordinary test drive (no clean lap) saves nothing' (@($l.moments | Where-Object { $_.car -match 'Toyota' }).Count -eq 0)
# Windows will not set OneDrive's recall bit on a normal file, so the sandbox names one file as online-only. The scanner uses the same skip as a real online-only file.
$onPath = Join-Path $src 'online-only-cloud.ibt'
Set-Content -LiteralPath $onPath -Value 'not telemetry' -Encoding ascii
$null = J '/vault/test/online?name=online-only-cloud.ibt'
$beforeS = (J '/vault').sessions
$null = J '/vault/test/scan'
$afterS = (J '/vault').sessions
Check 'an online-only file is not read (it would start a OneDrive download)' ($afterS -eq $beforeS)
# keepers have an untouched copy of the telemetry; recent items have none
$vroot = $l.root
$keeperOk = $true; $copies = @()
foreach ($m in $l.moments | Where-Object { $_.keeper }) {
  if (-not $m.ibt) { $keeperOk = $false; continue }
  $c = Join-Path $vroot $m.ibt; $o = Join-Path $src $m.ibtSrc
  if (-not (Test-Path $c)) { $keeperOk = $false; continue }
  if ((Get-Item $c).Length -ne (Get-Item $o).Length) { $keeperOk = $false }
  $copies += $c
}
$sample = $copies | Select-Object -Unique | Select-Object -First 1
Check "every keeper has a copy of its .ibt in vault\telemetry\<car>\<track>\<date time>.ibt, the same size as the file it came from ($(@($copies | Select-Object -Unique).Count) files)" ($keeperOk -and @($copies | Where-Object { $_ -match 'telemetry\\chevrolet-corvette-z06-gt3-r\\road-atlanta-full-course\\\d{4}-\d\d-\d\d \d\d-\d\d-\d\d\.ibt$' }).Count -eq $copies.Count)
$h1 = (Get-FileHash $sample -Algorithm SHA256).Hash; $o1 = $l.moments | Where-Object { $_.ibt -and (Join-Path $vroot $_.ibt) -eq $sample } | Select-Object -First 1
$h2 = (Get-FileHash (Join-Path $src $o1.ibtSrc) -Algorithm SHA256).Hash
Check 'the copy is byte for byte the same file (SHA-256)' ($h1 -eq $h2)
Check 'recent items keep no copy (they point at the original file)' (@($l.moments | Where-Object { -not $_.keeper -and $_.ibt }).Count -eq 0)
$shared = @($l.moments | Where-Object { $_.ibt -eq $race.ibt }).Count
Check "laps and the race of one session share one copy ($shared moments, one file)" ($shared -ge 3)
$moves = (J '/vault').keepers
Check "the status counts $moves keepers and shows the size used" ($moves -ge 5 -and (J '/vault').usedBytes -gt 100MB)

Section '3. again, delete, restart'
$r = J '/vault/test/scan'; $l2 = J '/vault/list'
Check 'reading again changes nothing (no duplicates)' (@($l2.moments).Count -eq @($l.moments).Count)
$null = J '/vault/test/sandbox?on=1'          # a restart of the scratch vault without a reset: everything comes back from disk
$l3 = J '/vault/list'
Check 'the index survives a reload from disk (moments, tags, copies)' (@($l3.moments).Count -eq @($l.moments).Count -and (@($l3.moments | Where-Object { $_.keeper }).Count -eq @($l.moments | Where-Object { $_.keeper }).Count))
$del = Get-Raw '/vault/delete?id=l20261008-013129-10'
Check 'DELETE without confirm=yes is refused (the page asks twice before it sends it)' ($del.code -eq 400)
$del = Get-Raw '/vault/delete?id=l20261008-013129-10&confirm=yes'
$null = J '/vault/test/scan'; $l4 = J '/vault/list'
Check 'a deleted moment is gone, and reading the sessions again does not bring it back' ($del.code -eq 200 -and -not (@($l4.moments | Where-Object { $_.id -eq 'l20261008-013129-10' }).Count))
$bad = Get-Raw '/vault/item?id=..%5C..%5Cwindows'
Check 'a path in an id is refused (400)' ($bad.code -eq 400)
$bad2 = Get-Raw '/vault/thumb?id=..%2F..%2Fx'; Check 'a path in a thumbnail id is refused (404)' ($bad2.code -eq 404)
$bad3 = Get-Raw '/vault/clip?id=nothere123'; Check 'a clip that does not exist is a 404' ($bad3.code -eq 404)

Section '4. older than the recent window, and the budget'
$null = J '/vault/test/sandbox?on=1&days=1'; $null = J '/vault/test/reconcile'; $l5 = J '/vault/list'
Check 'with a 1-day window the older recent items go but every keeper stays' (@($l5.moments | Where-Object { -not $_.keeper }).Count -eq 0 -and @($l5.moments | Where-Object { $_.keeper }).Count -eq @($l4.moments | Where-Object { $_.keeper }).Count)
$null = J '/vault/test/sandbox?on=1&days=30'; $null = J '/vault/test/reconcile'
$l6 = J '/vault/list'; $recentBack = @($l6.moments | Where-Object { -not $_.keeper }).Count
Check 'with the 30-day window the recent laps come back as recent items' ($recentBack -ge 1)

Section '5. the KEEP and CLIP keys (pretend session, nothing is pressed)'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/session?file=$(Q $f5)&rename=0" -TimeoutSec 60
$fr = "IsOnTrack=0&OnPitRoad=0&Lap=7&LapDistPct=0.45&SessionTime=500&SessionNum=1&Speed=40"
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?$fr" -TimeoutSec 8
Start-Sleep -Milliseconds 700
$null = J '/vault/test/events?clear=1'
$k1 = Get-Raw '/api/do?c=vkkeep'; Start-Sleep -Milliseconds 100; $k1b = Get-Raw '/api/do?c=vkkeep'
$ev = J '/vault/test/events'
Check 'KEEP answers ok, and a repeated press within 0.7 s counts once' ($k1.code -eq 200 -and $k1b.code -eq 200 -and ([regex]::Matches($ev.events, 'keep lap')).Count -eq 1)
Check 'KEEP marks the lap he was on (lap 7)' ($ev.events -match 'keep lap 7')
Start-Sleep -Milliseconds 800
$c1 = Get-Raw '/api/do?c=vkclip'; $ev = J '/vault/test/events'
Check 'CLIP answers ok and (in the test) would press the NVIDIA hotkey Alt+F10, no real key is sent' ($c1.code -eq 200 -and $ev.events -match 'clip hotkey Alt\+F10')
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
Start-Sleep -Milliseconds 400
$nope = Get-Raw '/api/do?c=vkdelete&a=nothere123'
Check 'the command list is whitelisted: an unknown moment is refused' ($nope.code -eq 400)
# a KEEP press during a session turns into a pinned lap once that session's file is complete: the press is replayed with a time inside an older session
Fx $f2
$f2start = ([DateTime]::ParseExact('2026-10-07 09-20-50', 'yyyy-MM-dd HH-mm-ss', $null)).ToUniversalTime()
$null = J ('/vault/test/mark?kind=keep&ms=' + [long](($f2start - $epoch).TotalMilliseconds + 100000) + '&lap=2&pct=0.4&car=' + (Q 'Chevrolet Corvette Z06 GT3.R') + '&track=' + (Q 'Road Atlanta') + '&config=' + (Q 'Full Course'))
$null = J '/vault/test/scan'; $lk = J '/vault/list'; $pin = @($lk.moments | Where-Object { $_.id -eq 'l20261007-132050-2' })
Check 'a lap marked with KEEP is kept for good once its session file is read: pinned, a keeper, its own copy of the telemetry (even though it is a slow lap)' ($pin.Count -eq 1 -and $pin[0].pinned -eq $true -and $pin[0].keeper -eq $true -and $pin[0].ibt)

Section '6. a test clip: attach, copy, sync (V2)'
Check 'ffmpeg is on this PC (vault\bin), used only to make the synthetic test video' (Test-Path $ffmpeg)
# the race's lap 7: where is the line, in wall-clock time?
$laps = J ('/vault/laps?id=r20261010-041318'); $lap7 = @($laps.laps | Where-Object { $_.n -eq 7 })[0]
$tr7 = J ('/vault/lap?id=r20261010-041318&lap=7')
$wall0 = $laps.startMs + ($lap7.t0 - $laps.st0) * 1000          # ms: lap 7 starts
$wallMid = $wall0 + $tr7.t[500] * 1000                            # ms: the middle of the lap's distance grid (g = 500)
Note ("lap 7 starts at {0:HH:mm:ss.fff} local, the 50 % point is {1:HH:mm:ss.fff}" -f ($epoch.AddMilliseconds($wall0).ToLocalTime()), ($epoch.AddMilliseconds($wallMid).ToLocalTime()))
# a 12 s video: the picture's red level is the time in the video (20 levels a second), so a frame says where it is
$clipDir = Join-Path $nv 'iRacing'; New-Item -ItemType Directory -Force $clipDir | Out-Null
$clip = Join-Path $clipDir 'iRacing Simulator 2026.10.10 - 00.20.00.00.DVR.mp4'
$ff = Start-Process -FilePath $ffmpeg -ArgumentList @('-y', '-loglevel', 'error', '-f', 'lavfi', '-i', "color=c=black:s=640x360:r=30:d=12,geq=r='min(255\,floor(T*20))':g=60:b=60", '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', "`"$clip`"") -Wait -PassThru -WindowStyle Hidden
Check "the test video was made: 12 s, $([int]((Get-Item $clip).Length / 1KB)) KB (synthetic, nothing recorded from a screen)" ($ff.ExitCode -eq 0 -and (Test-Path $clip))
$mp4b = J ('/vault/test/mp4?file=' + (Q 'iRacing\iRacing Simulator 2026.10.10 - 00.20.00.00.DVR.mp4'))
Check "the mp4 reader finds the length from the file's own boxes: $($mp4b.seconds) s" ($mp4b.ok -and (Near $mp4b.seconds 12 0.1))
# the file ends 6 s after the middle of lap 7; the press mark is 2 s before the file's end
$endMs = $wallMid + 6000
[IO.File]::SetLastWriteTimeUtc($clip, $epoch.AddMilliseconds($endMs))
$car = $race.car; $track = $race.track; $cfg = $race.config
$null = J ('/vault/test/mark?kind=clip&ms=' + [long]($endMs - 2000) + '&lap=7&pct=0.5&car=' + (Q $car) + '&track=' + (Q $track) + '&config=' + (Q $cfg))
$r = J '/vault/test/clips'
Check 'the watcher found the complete mp4 and attached it' ($r.attached -eq 1)
$l7 = J '/vault/list'; $cm = @($l7.moments | Where-Object { $_.kind -eq 'clip' })
Check 'one clip moment: its car, track and lap come from the press mark and the telemetry' ($cm.Count -eq 1 -and $cm[0].lap -eq 7 -and $cm[0].car -eq $car -and $cm[0].track -eq $track)
$cid = $cm[0].id
Check 'the clip is copied into vault\clips (the original stays in the NVIDIA folder, vault_clip_mode=copy)' ((Test-Path (Join-Path $l7.root $cm[0].video)) -and (Test-Path $clip) -and (Near $cm[0].videoDur 12 0.1))
Check 'it is linked to its session file (a copy of the telemetry kept for it)' ($cm[0].session -like '*00-13-18*' -and $cm[0].ibt)
$it = J "/vault/item?id=$cid"; $ls = @($it.sync.laps | Where-Object { $_.n -eq 7 })[0]
$vMid = $ls.v0 + $tr7.t[500] + $it.sync.nudge
Check "sync: the middle of lap 7 is at video second $([math]::Round($vMid, 2)) (the file's end is 6 s later, so 6.0; within 0.5 s)" ($ls -and (Near $vMid 6.0 0.5))
$vStart = $ls.v0
Check "sync: lap 7 starts at video second $([math]::Round($vStart, 2)) (expected $([math]::Round(($wall0 - ($endMs - 12000)) / 1000, 2)))" (Near $vStart (($wall0 - ($endMs - 12000)) / 1000) 0.5)
# a clip with no press mark: found by its end time alone
$clip2 = Join-Path $clipDir 'iRacing Simulator 2026.10.10 - 00.25.00.00.DVR.mp4'; Copy-Item $clip $clip2
[IO.File]::SetLastWriteTimeUtc($clip2, $epoch.AddMilliseconds($wall0 + 30000 + 6000))
$r = J '/vault/test/clips'; $l8 = J '/vault/list'; $cm2 = @($l8.moments | Where-Object { $_.kind -eq 'clip' -and $_.id -ne $cid })
Check 'a clip with no press mark is placed by its end time: lap 7, the same session' ($r.attached -eq 1 -and $cm2.Count -eq 1 -and $cm2[0].lap -eq 7 -and $cm2[0].session -like '*00-13-18*')
# a file that is still being written is left alone
$part = Join-Path $clipDir 'iRacing Simulator 2026.10.10 - 00.30.00.00.DVR.mp4'
$bytes = [IO.File]::ReadAllBytes($clip); [IO.File]::WriteAllBytes($part, $bytes[0..([int]($bytes.Length / 2))])
$r = J '/vault/test/clips'
Check 'a half-written mp4 is not attached (it waits until complete)' ($r.attached -eq 0)
Remove-Item $part -Force

Section '7. the video route (byte ranges) and the actions'
$full = Get-Raw "/vault/clip?id=$cid"
Check 'GET /vault/clip answers 200 with Accept-Ranges and the exact file' ($full.code -eq 200 -and $full.headers['Accept-Ranges'] -eq 'bytes' -and $full.bytes.Length -eq (Get-Item (Join-Path $l7.root $cm[0].video)).Length)
$rg = Get-Raw "/vault/clip?id=$cid" @{ Range = 'bytes=1000-' }
$ref = [IO.File]::ReadAllBytes((Join-Path $l7.root $cm[0].video))
Check 'a Range request answers 206 with Content-Range and the right bytes' ($rg.code -eq 206 -and $rg.headers['Content-Range'] -match "^bytes 1000-$($ref.Length - 1)/$($ref.Length)$" -and $rg.bytes.Length -eq $ref.Length - 1000 -and $rg.bytes[0] -eq $ref[1000] -and $rg.bytes[-1] -eq $ref[-1])
$rq = [Net.HttpWebRequest]::Create("$api/vault/clip?id=$cid"); $null = $rq.AddRange('bytes', 500, 999); $resp = $rq.GetResponse(); $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms); $resp.Close()
Check 'a closed range (bytes 500-999) gives exactly those 500 bytes' ($ms.Length -eq 500 -and $ms.ToArray()[0] -eq $ref[500])
$rq = [Net.HttpWebRequest]::Create("$api/vault/clip?id=$cid"); $null = $rq.AddRange('bytes', -300); $resp = $rq.GetResponse(); $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms); $resp.Close()
Check 'a suffix range (the last 300 bytes, how players find the movie box) works' ($ms.Length -eq 300 -and $ms.ToArray()[299] -eq $ref[-1])
$rq = [Net.HttpWebRequest]::Create("$api/vault/clip?id=$cid"); $null = $rq.AddRange('bytes', [long]($ref.Length + 10)); try { $resp = $rq.GetResponse(); $code416 = [int]$resp.StatusCode } catch [Net.WebException] { $code416 = [int]$_.Exception.Response.StatusCode }
Check 'a range past the end is 416' ($code416 -eq 416)
$null = J '/vault/test/cosworth?on=0'     # Pi Toolbox IS installed on this PC since 2026-10-10: pretend it is not
$o1 = J "/vault/open?id=$cid&how=cosworth&dry=1"
Check 'OPEN IN COSWORTH when Pi Toolbox is not installed opens the folder with the file instead (dry run, nothing started)' ($o1.dry -eq $true -and $o1.action -eq 'folder' -and $o1.cosworthInstalled -eq $false -and $o1.target -like '*.ibt')
$null = J '/vault/test/cosworth?on=auto'
$o2 = J "/vault/open?id=$cid&how=share&dry=1"
Check 'SHARE points at the clip file' ($o2.action -eq 'folder' -and $o2.target -like '*.mp4')
$e1 = J "/vault/edit?id=$cid&note=$(Q 'the apex at T6 - brake later')&tag=$(Q '+OVERTAKE')&star=1&nudge=0.7"
Check 'notes, a tag, the star and the SYNC nudge are saved' ($e1.m.note -like '*brake later*' -and (Has $e1.m 'OVERTAKE') -and $e1.m.pinned -eq $true -and (Near $e1.m.nudge 0.7 0.001))
$e2 = J "/vault/edit?id=$cid&nudge=9"; Check 'the nudge is limited to -3 .. +3 s' (Near $e2.m.nudge 3 0.001)
$null = J "/vault/edit?id=$cid&nudge=0.7"
$e3 = J "/vault/edit?id=$cid&tag=$(Q '+PB')"; Check 'the automatic tags cannot be added by hand' (-not (Has $e3.m 'PB'))
$null = J '/vault/test/reconcile'
$e4 = J "/vault/item?id=$cid"
Check 'a note and a hand-added tag are still there after the rules run again' ($e4.m.note -like '*brake later*' -and (Has $e4.m 'OVERTAKE'))
$st = J '/vault'
Check 'the status counts the clip and its size, and says the NVIDIA settings were only read (Instant Replay is off on this PC today)' ($st.withVideo -ge 1 -and $st.clipBytes -gt 10000 -and $st.nvidia.hotkey -eq 'Alt+F10' -and $st.nvidia.found -eq $true)

Section '8. the budget'
$st = J '/vault'; $keepersBefore = $st.keepers; $vsize = $st.usedBytes
$null = J "/vault/edit?id=$($cm2[0].id)&star=0"
$null = J "/vault/test/prune?bytes=$($vsize - 1000)"
$l10 = J '/vault/list'
Check 'a little over the budget: the oldest unstarred clip goes first (its video file too); recent laps, the starred clip and all keepers stay' (@($l10.moments | Where-Object { $_.id -eq $cm2[0].id }).Count -eq 0 -and @($l10.moments | Where-Object { $_.id -eq $cid }).Count -eq 1 -and @($l10.moments | Where-Object { $_.keeper }).Count -eq $keepersBefore -and @($l10.moments | Where-Object { -not $_.keeper -and $_.kind -ne 'clip' }).Count -ge 1)
Check 'the removed clip''s file is gone from vault\clips' (-not (Test-Path (Join-Path $l10.root $cm2[0].video)))
$pr = J '/vault/test/prune?bytes=1'
$l9 = J '/vault/list'
Check 'over a tiny budget every unstarred item goes and every keeper stays (keepers are never deleted)' (@($l9.moments | Where-Object { $_.keeper }).Count -eq $keepersBefore -and @($l9.moments | Where-Object { -not $_.keeper }).Count -eq 0)
Check 'the message says the keepers alone are over the budget' ($pr.message -match 'keepers alone')
Check 'the starred clip survived the prune (a starred item is a keeper)' (@($l9.moments | Where-Object { $_.id -eq $cid }).Count -eq 1)
$null = J '/vault/test/prune'

Section '9. thumbnails and refusing while driving'
$th = J '/vault/test/thumbs'; $l11 = J '/vault/list'
$withThumb = @($l11.moments | Where-Object { $_.thumb }).Count
Check "thumbnails are drawn by irdash (the labelled map with the lap's colour trace): $withThumb of $(@($l11.moments).Count)" ($withThumb -ge 5)
$tb = Get-Raw "/vault/thumb?id=l20261010-041318-7"
Check 'a thumbnail is a 640 x 400 PNG with gold on it' ($tb.code -eq 200 -and $tb.bytes[1] -eq 80 -and $tb.bytes.Length -gt 5000)
$pngFile = Join-Path $shots 'v-thumb.png'; [IO.File]::WriteAllBytes($pngFile, $tb.bytes)
$bm = New-Object System.Drawing.Bitmap $pngFile; Check "the thumbnail is 640 x 400 with the gold of the trace and the corner rings ($(Gold-Pixels $pngFile) gold pixels)" ($bm.Width -eq 640 -and $bm.Height -eq 400 -and (Gold-Pixels $pngFile) -gt 250); $bm.Dispose()
# driving: the lap routes wait until he is out of the car
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/session?file=$(Q $f5)" -TimeoutSec 60
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?IsOnTrack=1&Lap=3&LapDistPct=0.3&Speed=50" -TimeoutSec 8
$drv = $false; for ($i = 0; $i -lt 12 -and -not $drv; $i++) { Start-Sleep -Milliseconds 500; $drv = (J '/vault').driving }
$lp = Get-Raw '/vault/lap?id=l20261010-041318-7&lap=7'; $op = Get-Raw "/vault/open?id=$cid&how=share&dry=1"; $nv1 = Get-Raw '/api/do?c=vkopen'
Check 'while he is driving the lap data and the open buttons are refused (503 / 409) and the page cannot be opened from a key' ($drv -and $lp.code -eq 503 -and $op.code -eq 409 -and $nv1.code -eq 400)
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8; Start-Sleep -Milliseconds 2500
$no = Get-Raw '/api/do?c=vkopen'; $nav = J '/vault/nav'; $null = Get-Raw '/api/do?c=vkclose'; $nav2 = J '/vault/nav'
Check 'the VAULT key (vkopen) asks the dashboard to show the page; vkclose takes it away again' ($no.code -eq 200 -and $nav.to -eq 'vault' -and $nav2.to -eq '')

Section '10. the page in headless Chrome (pictures v-*.png)'
$null = J '/vault/test/sandbox?on=1&days=30'; $null = J '/vault/test/reconcile'; $null = J '/vault/test/thumbs'
$null = J "/vault/edit?id=$cid&nudge=0.7"
$lg = J '/vault/list'
Cdp-Open "$api/v2/vault.html"
$ok = Wait-Page "document.querySelectorAll('.card').length > 3 && document.querySelectorAll('.card img').length > 3 && Array.from(document.querySelectorAll('.card img')).every(function (i) { return i.complete && i.naturalWidth > 0; })"
$cards = Cdp-Eval "document.querySelectorAll('.card').length"
$expectCards = Count-Cards $lg.moments
Check "the grid shows one card per lap ($cards cards, $(@($lg.moments).Count) moments) with its thumbnail loaded" ($ok -and $cards -eq $expectCards)
$info = (Cdp-Eval "JSON.stringify({ stars: document.querySelectorAll('.card .star').length, tabs: document.querySelectorAll('.filters .tab').length, drops: document.querySelectorAll('.filters .drop').length, meter: document.getElementById('meter').textContent, totals: document.getElementById('totals').textContent, errs: (window.__errs || []).length })") | ConvertFrom-Json
Check "gold stars on the keepers ($($info.stars)), view tabs ($($info.tabs)) and big lists ($($info.drops)), the size meter ('$($info.meter)'), no script errors" ($info.stars -ge 5 -and $info.tabs -ge 3 -and $info.drops -ge 1 -and $info.meter -match 'MB|GB' -and $info.errs -eq 0)
Cdp-Shot (Join-Path $shots 'v-grid.png') 0 0 1920 1080
Check 'v-grid.png saved' (Test-Path (Join-Path $shots 'v-grid.png'))
# filters
$null = Cdp-Eval "Array.from(document.querySelectorAll('#fKind .tab')).find(function (b) { return /Keepers/.test(b.textContent); }).click()"
$nk = Cdp-Eval "document.querySelectorAll('.card').length"
$null = Cdp-Eval "document.getElementById('q').value = 'podium'; document.getElementById('q').dispatchEvent(new Event('input'))"
$np = Cdp-Eval "document.querySelectorAll('.card').length"
$expectKeep = Count-Cards @($lg.moments | Where-Object { $_.keeper })
Check "filters work: ★ Keepers shows $nk, searching 'podium' shows $np" ($nk -eq $expectKeep -and $np -eq 1)
$null = Cdp-Eval "document.getElementById('q').value = ''; document.getElementById('q').dispatchEvent(new Event('input')); document.querySelector('#fKind .tab').click()"

# 2026-10-18 redesign ("vault is a disaster ... hard to interpret"): grouped by day then session, readable at arm's length, S / M / L sizes that are remembered
$grp = (Cdp-Eval "JSON.stringify({ days: document.querySelectorAll('#grid .day').length, sess: document.querySelectorAll('#grid .sgrp .sess').length, loose: Array.from(document.querySelectorAll('#grid .card')).filter(function (c) { return !c.closest('.sgrp'); }).length, first: (document.querySelector('#grid .day') || {}).textContent || '', sess1: (document.querySelector('#grid .sess') || {}).textContent || '' })") | ConvertFrom-Json
Check "the cards are grouped by day ($($grp.days) day headers, the first '$($grp.first)') and by session ($($grp.sess) session headers, the first '$($grp.sess1)'); no card outside a session" ($grp.days -ge 2 -and $grp.sess -ge $grp.days -and $grp.loose -eq 0 -and $grp.sess1 -match '\d{1,2}:\d{2}\s?(AM|PM)')
$null = Cdp-Eval "document.querySelector('#gridScroll').scrollTop = 900; 1"; Start-Sleep -Milliseconds 300
$stk = Cdp-Eval "(function () { var s = document.getElementById('gridScroll').getBoundingClientRect(), hit = document.elementFromPoint(300, s.top + 12); return !!(hit && hit.closest('.day')); })()"
Check 'scrolled down, a day header stays pinned at the top of the list (sticky)' ($stk -eq $true)
$null = Cdp-Eval "document.querySelector('#gridScroll').scrollTop = 0; 1"
# readable at arm's length: measured on the SMALLEST size. Lap time >= 36 px, title >= 24 px, nothing under 20 px; no text runs out of its card; no two cards overlap
$null = Cdp-Eval "document.querySelector('.sz[data-size=S]').click(); 1"; Start-Sleep -Milliseconds 400
$fs = (Cdp-Eval @"
(function () {
  var cards = Array.from(document.querySelectorAll('#grid .card')).filter(function (c) { var r = c.getBoundingClientRect(); return r.bottom > 0 && r.top < innerHeight; });
  var px = function (e) { return parseFloat(getComputedStyle(e).fontSize); }, minAll = 99, minTm = 99, minT1 = 99, out = 0, small = [];
  cards.forEach(function (c) {
    var cr = c.getBoundingClientRect();
    c.querySelectorAll('.tm b').forEach(function (e) { minTm = Math.min(minTm, px(e)); });
    c.querySelectorAll('.t1').forEach(function (e) { minT1 = Math.min(minT1, px(e)); });
    var w = document.createTreeWalker(c, NodeFilter.SHOW_TEXT), n;
    while ((n = w.nextNode())) { if (!n.textContent.trim()) continue; var e = n.parentElement, f = px(e); if (f < minAll) minAll = f; if (f < 20) small.push(n.textContent.trim() + ' ' + f); var r = e.getBoundingClientRect(); if (r.width && (r.right > cr.right + 1 || r.left < cr.left - 1)) out++; }
  });
  var ov = 0; for (var i = 0; i < cards.length; i++) for (var j = i + 1; j < cards.length; j++) { var a = cards[i].getBoundingClientRect(), b = cards[j].getBoundingClientRect(); if (a.left < b.right - 1 && b.left < a.right - 1 && a.top < b.bottom - 1 && b.top < a.bottom - 1) ov++; }
  return JSON.stringify({ n: cards.length, minAll: minAll, minTm: minTm, minT1: minT1, out: out, ov: ov, small: small.slice(0, 4), cls: document.getElementById('grid').className });
})()
"@) | ConvertFrom-Json
Check "size S: $($fs.n) cards on screen, lap time $($fs.minTm) px (>= 36), title $($fs.minT1) px (>= 24), smallest text $($fs.minAll) px (>= 20) $($fs.small -join '; ')" ($fs.n -ge 3 -and $fs.minTm -ge 36 -and $fs.minT1 -ge 24 -and $fs.minAll -ge 20 -and $fs.cls -match 's-S')
Check "size S: no text runs out of its card ($($fs.out)), no two cards overlap ($($fs.ov))" ($fs.out -eq 0 -and $fs.ov -eq 0)
Cdp-Shot (Join-Path $shots 'vault-grid-S.png') 0 0 1920 1080
# the size is remembered (this browser's own storage) and comes back after a reload
$null = Cdp-Eval "location.reload(); 1"; Start-Sleep -Milliseconds 300
$okS = Wait-Page "document.querySelectorAll('#grid .card').length > 3 && document.getElementById('grid').classList.contains('s-S') && document.querySelector('.sz.on').dataset.size === 'S'" 20
Check 'the S size is remembered after the page is opened again' $okS
$cols = Cdp-Eval "(function () { var g = document.querySelector('#grid .dgrid'); return g ? getComputedStyle(g).gridTemplateColumns.split(' ').length : 0; })()"
$null = Cdp-Eval "document.querySelector('.sz[data-size=L]').click(); 1"; Start-Sleep -Milliseconds 400
$colsL = Cdp-Eval "(function () { var g = document.querySelector('#grid .dgrid'); return g ? getComputedStyle(g).gridTemplateColumns.split(' ').length : 0; })()"
$wL = Cdp-Eval "Math.round(document.querySelector('#grid .card').getBoundingClientRect().width)"
Check "L makes the cards bigger: $cols columns at S, $colsL at L, a card $wL px wide" ($cols -eq 5 -and $colsL -eq 3 -and $wL -ge 540)
$null = Cdp-Eval "document.querySelector('.sz[data-size=M]').click(); 1"
# a list (car / track / tag) is a big drop-down (58 px rows, nothing to type) and choosing a row filters the cards
$dd = (Cdp-Eval "(function () { var d = document.querySelector('.drop'); if (!d) return JSON.stringify({ none: true }); var kind = d.dataset.drop, before = document.querySelectorAll('#grid .card').length; d.click(); var p = document.getElementById('pop'), b = p.querySelectorAll('button'); var h = b.length > 1 ? b[1].getBoundingClientRect().height : 0; var name = b.length > 1 ? b[1].querySelector('span').textContent : ''; if (b.length > 1) b[1].click(); var d2 = document.querySelector('.drop[data-drop=' + kind + ']'); return JSON.stringify({ kind: kind, rows: b.length, h: h, name: name, before: before, n: document.querySelectorAll('#grid .card').length, shows: d2 ? d2.textContent : '', on: d2 ? d2.classList.contains('on') : false, hidden: p.hidden }); })()") | ConvertFrom-Json
Check "the $($dd.kind) list opens with $($dd.rows) rows of $([math]::Round($dd.h)) px; choosing '$($dd.name)' shows $($dd.n) of $($dd.before) cards and the button now says '$($dd.shows)'" (-not $dd.none -and $dd.rows -ge 2 -and $dd.h -ge 56 -and $dd.n -ge 1 -and $dd.n -le $dd.before -and $dd.shows -eq $dd.name -and $dd.on -and $dd.hidden)
$null = Cdp-Eval "(function () { var d = document.querySelector('.drop.on'); if (d) { d.click(); document.querySelector('#pop button').click(); } return 1; })()"# arrows walk the cards, Enter opens one
$null = Cdp-Eval "document.querySelector('#grid .card').focus(); document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true })); 1"
$kf = Cdp-Eval "document.activeElement === document.querySelectorAll('#grid .card')[1]"
Check 'the right arrow moves to the next card' ($kf -eq $true)

# the detail of the best lap: a lap with telemetry opens straight into the analysis workbench (vault.js openWorkbench),
# which has the labelled map, the corner table and the traces on one cursor (their own checks are in workbench-test)
$null = Cdp-Eval "location.hash = 'm=l20261010-041318-7'"
$ok = Wait-Page "(function () { var f = document.querySelector('#wbHost iframe'); try { return !!(f && f.contentWindow.WB && f.contentWindow.WB.data() && f.contentWindow.WB.data().corners.length); } catch (e) { return false; } })()" 40
Start-Sleep -Milliseconds 1500
$d = (Cdp-Eval "(function () { var f = document.querySelector('#wbHost iframe'), w = f ? f.contentWindow : null, dd = w && w.WB ? w.WB.data() : null; return JSON.stringify({ src: f ? f.getAttribute('src') : '', corners: dd ? dd.corners.length : 0, back: !!document.getElementById('wbBack'), errs: (window.__errs || []).length }); })()") | ConvertFrom-Json
Check "detail: lap 7 opens in the analysis workbench ($($d.src)) with all $($d.corners) corners of Road Atlanta" ($ok -and $d.src -match 'lap=7' -and $d.corners -eq 14)
Check "detail: a 'Back to the Vault' button is on it, no script errors" ($d.back -and $d.errs -eq 0)
Cdp-Shot (Join-Path $shots 'v-detail.png') 0 0 1920 1080
$png = Join-Path $shots 'v-detail.png'
Check "v-detail.png saved: the workbench carries gold ($(Gold-Pixels $png) gold pixels)" ((Gold-Pixels $png) -gt 1500)
# compare two laps with a delta trace
# (the lap-against-lap difference trace of a plain lap now lives in the workbench, tested in workbench-test; here: the Vault serves both laps' traces)
$tA = J '/vault/lap?id=l20261010-041318-7&lap=7'; $tB = J '/vault/lap?id=l20261009-185837-2&lap=2'
Check "compare: the Vault serves the traces of both laps; the end times differ by $([math]::Round($tA.t[1000] - $tB.t[1000], 3)) s (lap times differ by -0.051)" ($tA.t -and $tB.t -and (Near ($tA.t[1000] - $tB.t[1000]) (79.549 - 79.600) 0.01))
$null = Cdp-Eval "document.getElementById('wbBack').click(); 1"; $null = Wait-Page "!document.getElementById('wbHost')" 4
Check 'BACK on a lap opened from a card goes back to the cards (it used to uncover a half-built detail page)' ((Wait-Page "V.id === '' && !document.getElementById('viewGrid').hidden && document.querySelectorAll('#grid .card').length > 3" 6) -eq $true)

# the clip: video and telemetry on one cursor
$null = Cdp-Eval "location.hash = 'm=$cid'"
$ok = Wait-Page "!!(V.trace && V.sync && V.vid && V.vid.readyState >= 2 && V.discs.length > 0)" 40
Start-Sleep -Milliseconds 800
$vc = (Cdp-Eval "JSON.stringify({ rs: V.vid.readyState, dur: V.vid.duration, lap: V.lap, nudge: V.sync.nudge, err: V.vid.error ? V.vid.error.code : 0, errs: (window.__errs || []).length })") | ConvertFrom-Json
Check "the clip player loads the clip through the Range route: ready, $([math]::Round($vc.dur, 1)) s long, lap $($vc.lap), nudge $($vc.nudge)" ($ok -and $vc.rs -ge 2 -and (Near $vc.dur 12 0.2) -and $vc.lap -eq 7 -and $vc.err -eq 0)
# click T6 in the table: the video jumps to that corner's time and the picture's red level (= time in video) says so
$ti = Cdp-Eval "(function () { var d = V.corners.turns, best = -1, bd = 1e9; d.forEach(function (t, i) { var r = videoRawAt(Math.round(t.pctApex * 1000)); if (r > 1.5 && r < 10.5 && Math.abs(r - 6) < bd) { bd = Math.abs(r - 6); best = i; } }); return best; })()"
Check "the clip covers a turn of lap 7 (turn index $ti), so there is something to click" ($ti -ge 0)
$null = Cdp-Eval "document.querySelector('.ct[data-i=\""$ti\""]').click()"
Start-Sleep -Milliseconds 1200
$exp = Cdp-Eval "(function () { var t = V.corners.turns[$ti]; return videoTimeAt(Math.round(t.pctApex * 1000)); })()"
$cur = Cdp-Eval "V.vid.currentTime"
$red = Cdp-Eval "(function () { var c = document.createElement('canvas'); c.width = 8; c.height = 8; var g = c.getContext('2d'); g.drawImage(V.vid, 0, 0, 8, 8); return g.getImageData(4, 4, 1, 1).data[0]; })()"
Check "clicking that turn seeks the video to second $([math]::Round($exp, 2)) (it is at $([math]::Round($cur, 2))), and the frame itself says $([math]::Round($red / 20, 2)) s" (Near $cur $exp 0.15 -and (Near ($red / 20) $cur 0.3))
Check 'the cursor follows the video: after the seek it sits on that turn''s apex' (Near (Cdp-Eval "V.g") (Cdp-Eval "Math.round(V.corners.turns[$ti].pctApex * 1000)") 6)
# play for a moment: the dot and the cursor move with it
$g0 = Cdp-Eval "V.g"
$null = Cdp-Eval "V.vid.muted = true; V.vid.currentTime = Math.max(0, videoTimeAt(300)); V.vid.play().then(function () { return 1; })"
Start-Sleep -Milliseconds 2500
$g1 = Cdp-Eval "V.g"; $t1 = Cdp-Eval "V.vid.currentTime"
$expG = Cdp-Eval "(function () { var A = V.trace, t = V.vid.currentTime - V.sync.nudge - lapSync(V.lap).v0, i = 0; while (i < 1000 && A.t[i] < t) i++; return i; })()"
Check "playing: the cursor ran from grid 300 to $g1 as the video went to second $([math]::Round($t1, 2)) (the telemetry says grid ~$expG there)" ($g1 -gt 300 -and (Near $g1 $expG 40))
$null = Cdp-Eval "V.vid.pause(); 1"
# the nudge moves where the video is for the same point
$before = Cdp-Eval "videoTimeAt(500)"
$null = Cdp-Eval "document.querySelector('#sync [data-n=\""0.5\""]').click()"
Start-Sleep -Milliseconds 600
$after = Cdp-Eval "videoTimeAt(500)"
Check "SYNC +0.5 s moves the video time of the same corner by 0.5 s ($([math]::Round($before, 2)) to $([math]::Round($after, 2)))" (Near ($after - $before) 0.5 0.01)
$kept = (J "/vault/item?id=$cid").m.nudge
Check "the nudge is remembered by irdash ($kept s)" (Near $kept 1.2 0.001)
Cdp-Shot (Join-Path $shots 'v-clip.png') 0 0 1920 1080
Check 'v-clip.png saved' (Test-Path (Join-Path $shots 'v-clip.png'))
# the two-step delete in the page
$null = Cdp-Eval "document.getElementById('bDel').click()"; Start-Sleep -Milliseconds 300
$a1 = Cdp-Eval "!!document.getElementById('askYes')"
$null = Cdp-Eval "document.getElementById('askYes').click()"; Start-Sleep -Milliseconds 300
$a2 = Cdp-Eval "!!document.getElementById('askYes2')"
Check 'DELETE asks twice in the page (the second question says it cannot be undone), and nothing is deleted yet' ($a1 -and $a2 -and (@((J '/vault/list').moments | Where-Object { $_.id -eq $cid }).Count -eq 1))
$null = Cdp-Eval "document.getElementById('askNo').click()"
# RACE (W6b): a moment whose session has a race log gets a RACE button; no log, no button. The answer of /analysis/race is pretended
# here (the scratch vault has no race log; the endpoint itself is tested in tests\race-field-test.ps1); everything else is the real page and the real irdash.
$null = Cdp-Eval "window.__raceAnswer = 404; window.__raceAsked = []; if (!window.__realFetch) { window.__realFetch = window.fetch; window.fetch = function (u) { if (/\/analysis\/race/.test(String(u))) { window.__raceAsked.push(String(u)); return Promise.resolve(new Response(window.__raceAnswer === 200 ? '{`"ok`":1}' : '{`"error`":`"none`"}', { status: window.__raceAnswer })); } return window.__realFetch.apply(this, arguments); }; } 1"
$null = Cdp-Eval "location.hash = 'm=l20261010-041318-7'"
$ok = Wait-Page "V.id === 'l20261010-041318-7' && !!V.laps && window.__raceAsked.length >= 1" 40
Start-Sleep -Milliseconds 700
$noR = (Cdp-Eval "JSON.stringify({ btn: !!document.getElementById('bRace'), acts: document.getElementById('dActs').innerText, asked: window.__raceAsked })") | ConvertFrom-Json
Check "a lap with no race log: irdash is asked (/analysis/race?id=l20261010-041318-7, answer 404) and there is no RACE button (buttons: $($noR.acts -replace '\s+', ' '))" ($ok -and -not $noR.btn -and @($noR.asked | Where-Object { $_ -match '^/analysis/race\?id=l20261010-041318-7$' }).Count -ge 1)
$null = Cdp-Eval "window.__raceAnswer = 200; window.__raceAsked = []; location.hash = 'm=r20261010-041318'"
$ok = Wait-Page "V.id === 'r20261010-041318' && !!document.getElementById('bRace')" 40
$auto = (Cdp-Eval "(function () { var h = document.getElementById('wbHost'), f = h ? h.querySelector('iframe') : null; return JSON.stringify({ src: f ? f.getAttribute('src') : '', grid: h ? h.dataset.grid : '' }); })()") | ConvertFrom-Json
Check "a race card with a race log opens its RACE page straight away ($($auto.src))" ($auto.src -match 'page=race' -and $auto.grid -eq '1')
$rb = (Cdp-Eval "(function () { var b = document.getElementById('bRace'); if (!b) return JSON.stringify({}); var r = b.getBoundingClientRect(); return JSON.stringify({ text: b.innerText, h: r.height, w: r.width, shown: r.width > 0, first: b === document.querySelectorAll('#dActs .btn')[0], lap: V.lap, asked: window.__raceAsked }); })()") | ConvertFrom-Json
Check "the race of that session has a log: a RACE button is on the detail page (text '$($rb.text)', first of the buttons, $([math]::Round($rb.w)) x $([math]::Round($rb.h)) px)" ($ok -and $rb.text -eq 'RACE' -and $rb.shown -and $rb.first -and $rb.lap -gt 0 -and @($rb.asked | Where-Object { $_ -match '^/analysis/race\?id=r20261010-041318$' }).Count -ge 1)
$null = Cdp-Eval "document.getElementById('bRace').click(); 1"
$okW = Wait-Page "!!document.querySelector('#wbHost iframe')" 5
$srcR = Cdp-Eval "(document.querySelector('#wbHost iframe') || {getAttribute: function () { return ''; }}).getAttribute('src')"
Check "RACE opens the workbench on the RACE page over the Vault: iframe $srcR" ($okW -and $srcR -eq ('workbench.html?id=r20261010-041318&lap=' + $rb.lap + '&page=race'))
$okL = Wait-Page "(function () { var f = document.querySelector('#wbHost iframe'); try { return !!(f.contentWindow.WB && f.contentWindow.WB.ready); } catch (e) { return false; } })()" 60
Check 'the workbench inside it loads that lap of the Vault race (the id form is accepted by /analysis/channels)' $okL
$null = Cdp-Eval "document.getElementById('wbBack').click(); 1"
$gone = Wait-Page "!document.getElementById('wbHost')" 4
Check 'the back bar closes it and the Vault detail is still there' ($gone -and (Cdp-Eval "V.id") -eq 'r20261010-041318')
$null = Cdp-Eval "document.getElementById('bRace').click(); 1"; $null = Wait-Page "!!document.querySelector('#wbHost iframe')" 5
$null = Cdp-Eval "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); 1"
$gone2 = Wait-Page "!document.getElementById('wbHost')" 4
Check 'Escape puts the race page away first (the detail stays open)' ($gone2 -and (Cdp-Eval "V.id") -eq 'r20261010-041318')
Check 'no script errors from the RACE button' ((Cdp-Eval "(window.__errs || []).length") -eq 0)
# the debrief after a personal best is the Session Review (C-40); it offers ANALYSIS (the old In the Vault link went with the benchmark card; CHOOSE in the laps-saved bar opens the Vault)
$null = Cdp 'Page.navigate' @{ url = "$api/v2/index.html?debrief=demo" }
$okDb = Wait-Page "!!document.getElementById('srAnalysis') && !document.getElementById('srAnalysis').hidden" 25
Check 'after a personal best the debrief (Session Review) offers ANALYSIS' $okDb
Cdp-Close

# L-1: the Vault's personal best, best laps and fastest tenth are laps iRacing COUNTED (one rule everywhere: LapRules in analysis.cs). Before, a timed lap with a short
# off-track could be a PB: 2026-10-06 21-26-58 has 10 timed laps; the quickest (79.897, lap 3) has an off-track record and iRacing did not count it (its own best of the
# file stays 80.228, lap 14). Under the old rule that lap was the session's best, beat the 80.191 before it and was kept as a PB.
Section '11. L-1: the Vault''s PB, best laps and fastest tenth are laps iRacing counted'
$f7 = 'chevyvettez06rgt3_roadatlanta full 2026-10-06 21-26-58.ibt'
Fx $f7
$null = J '/vault/test/sandbox?on=1&days=30'
$null = J '/vault/test/scan'; $null = J '/vault/test/reconcile'
$lq = J '/vault/list'
$p7 = Join-Path $src $f7
Check 'the raw records agree: lap 3 (79.897) has an off-track record and iRacing did not count it, lap 14 (80.228) it counted and it is iRacing''s own best of the file' (-not [LapRaw]::Counted($p7, 3, 79.897) -and [LapRaw]::Counted($p7, 14, 80.228) -and (Near ([LapRaw]::BestLap($p7)) 80.228 0.001))
Check 'that session is no personal best: its quickest counted lap (80.228) does not beat the 80.191 before it, and the uncounted 79.897 lap is not kept' (@($lq.moments | Where-Object { $_.session -eq $f7 -and (Has $_ 'PB') }).Count -eq 0 -and @($lq.moments | Where-Object { $_.id -eq 'l20261007-012658-3' }).Count -eq 0)
$m14 = @($lq.moments | Where-Object { $_.session -eq $f7 })
Note ('moments of that session: ' + (($m14 | ForEach-Object { "$($_.id) lap $($_.lap) $($_.lapTime) tags [$(@($_.tags) -join ',')] keeper=$($_.keeper)" }) -join ' | '))
Check 'what the Vault keeps from that session (a recent item, it is a race) shows its quickest COUNTED lap, lap 14, 1:20.228 - not the uncounted lap 3 (1:19.897)' ($m14.Count -eq 1 -and $m14[0].lap -eq 14 -and (Near $m14[0].lapTime 80.228 0.001))
$tagged = @($lq.moments | Where-Object { $_.kind -eq 'lap' -and ((Has $_ 'PB') -or (Has $_ 'BEST LAP') -or (Has $_ 'TOP 10')) })
$allCounted = $true
foreach ($mt in $tagged) { $pp = Join-Path $src $mt.ibtSrc; if (-not (Test-Path -LiteralPath $pp) -or -not [LapRaw]::Counted($pp, [int]$mt.lap, [double]$mt.lapTime)) { $allCounted = $false; Note "tagged but not counted by iRacing: $($mt.id) lap $($mt.lap) $($mt.lapTime)" } }
Check "every lap the Vault tags PB, BEST LAP or TOP 10 ($($tagged.Count) laps) is one iRacing counted, checked against the raw records of its file" ($tagged.Count -ge 3 -and $allCounted)
$pbm = @($lq.moments | Where-Object { $_.id -eq 'l20261010-041318-7' })
Check 'the Vault''s personal best of the car and track is still 1:19.549 (lap 7 of the race), a counted lap' ($pbm.Count -eq 1 -and (Near $pbm[0].pb 79.549 0.001) -and [LapRaw]::Counted((Join-Path $src $pbm[0].ibtSrc), 7, 79.549))
# a Vault row made before the rule (no rules column, and the old best 79.897) is read again, replaced, and the PB tag it gave is gone
$tsv = Join-Path $lq.root 'sessions.tsv'
$rows = @(Get-Content -LiteralPath $tsv -Encoding UTF8)
$new = @(); $had = 0
foreach ($ln in $rows) {
  $c = $ln.Split("`t")
  if ($c[0] -eq $f7) { $had++; $c[11] = '79.897'; $c[12] = '3'; $c[13] = '10'; $c[14] = '3:79.897;15:80.161;14:80.228'; $c = $c[0..19] }
  $new += ($c -join "`t")
}
[IO.File]::WriteAllText($tsv, (($new -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
$null = J '/vault/test/sandbox?on=1'
$null = J '/vault/test/scan'
$rows2 = @(Get-Content -LiteralPath $tsv -Encoding UTF8 | Where-Object { $_.StartsWith($f7 + "`t") })
$c2 = if ($rows2.Count -eq 1) { $rows2[0].Split("`t") } else { @() }
Check 'a session row from before the rule (best 79.897, no rules column) is read again: one row, best 80.228 at lap 14, 3 valid laps, marked with the rule version' ($had -eq 1 -and $rows2.Count -eq 1 -and $c2.Count -ge 21 -and (Near $c2[11] 80.228 0.001) -and $c2[12] -eq '14' -and $c2[13] -eq '3' -and $c2[20] -eq '3')
$lq2 = J '/vault/list'
Check 'and the moments follow: still no PB and no lap 3 for that session' (@($lq2.moments | Where-Object { $_.session -eq $f7 -and (Has $_ 'PB') }).Count -eq 0 -and @($lq2.moments | Where-Object { $_.id -eq 'l20261007-012658-3' }).Count -eq 0)

Section '12. the recorder clip player and the two-clip position lock (P0-10)'
# Paddock's own recorder clip (rec-<...>.mp4 + its sidecar) played from /vault/video, and two such clips of the same car+track
# kept at the same track position. A longer synthetic clip is made here: the recorder's clock is the wall clock, so a lap needs ~80 s.
$longMp4 = Join-Path $nv 'rec-test-long.mp4'
$ffl = Start-Process -FilePath $ffmpeg -ArgumentList @('-y', '-loglevel', 'error', '-f', 'lavfi', '-i', "color=c=black:s=640x360:r=60:d=90,geq=r='min(255\,floor(T*2.8))':g=60:b=60", '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', "`"$longMp4`"") -Wait -PassThru -WindowStyle Hidden
Check "a 90 s synthetic clip was made (used only as the recorder's pictures, nothing recorded from a screen)" ($ffl.ExitCode -eq 0 -and (Test-Path $longMp4))
$laps = J ('/vault/laps?id=r20261010-041318')
$lap7 = @($laps.laps | Where-Object { $_.n -eq 7 })[0]; $lap8 = @($laps.laps | Where-Object { $_.n -eq 8 })[0]
$m7 = $byId['l20261010-041318-7']
$recDir = Join-Path $l7.root 'clips'; New-Item -ItemType Directory -Force $recDir | Out-Null
$wall7 = $laps.startMs + ($lap7.t0 - $laps.st0) * 1000
$wall8 = $laps.startMs + ($lap8.t0 - $laps.st0) * 1000
function Make-RecClip($id, $lapN, $lapTime, $wall0) {
  Copy-Item $longMp4 (Join-Path $recDir "$id.mp4") -Force
  $c = [ordered]@{ id = $id; lap = $lapN; lapTime = [double]$lapTime; lapStartMs = [long]$wall0; lapEndMs = [long]($wall0 + $lapTime * 1000); clipStartMs = [long]($wall0 - 1000)
    lapStartOffset = 1.0; lapEndOffset = 1.0 + [double]$lapTime; videoStart = 0.0; duration = 90.0; fps = 60; rotation = 180; encoder = 'libx264'
    car = $m7.car; track = $m7.track; config = $m7.config; sessionTime = 0.0; why = 'test'; keep = $false; pb = $false; truncated = $false; created = [long]0; size = (Get-Item (Join-Path $recDir "$id.mp4")).Length }
  ($c | ConvertTo-Json -Compress) | Set-Content (Join-Path $recDir "$id.json") -Encoding UTF8
}
Make-RecClip 'rec-20261010-042000-l7' 7 $lap7.time $wall7
Make-RecClip 'rec-20261010-042000-l8' 8 $lap8.time $wall8
$ri = J '/vault/test/rec?cmd=reindex'
Check "the recorder indexes the two test clips as rec-<start>-l<n> ($($ri.clips) clips)" ($ri.ok -eq $true -and $ri.clips -ge 2)
$vi7 = J '/vault/videoinfo?id=l20261010-041318-7'
Check "a Vault lap finds its recorder clip and sidecar from its own id (not the lap id): $($vi7.id), lap $($vi7.lap), lapStartOffset $($vi7.lapStartOffset) s" ($vi7.id -eq 'rec-20261010-042000-l7' -and $vi7.lap -eq 7 -and (Near $vi7.lapStartOffset 1.0 0.0001) -and (Near $vi7.lapEndOffset (1.0 + $lap7.time) 0.001))
Check 'the recorder clip serves from /vault/video with byte ranges (206)' ((Get-Raw "/vault/video?id=rec-20261010-042000-l7").code -eq 200 -and (Get-Raw "/vault/video?id=rec-20261010-042000-l7" @{ Range = 'bytes=0-99' }).code -eq 206)

# 2026-10-18: a lap that was RECORDED opens on the Vault's own player (the video big first, the traces under it on one cursor, SYNC);
# a lap without video still opens the analysis workbench (section 10). The workbench's own VIDEO page is tested in video-page-test.
$lgv = J '/vault/list'
if ($lgv.PSObject.Properties.Name -contains 'frames') {
  $mv = @($lgv.moments | Where-Object { $_.id -eq 'l20261010-041318-7' })[0]
  Check "the list names the lap's recorder clip ($($mv.vid), $($mv.vidDur) s) so the card can show its length" ($mv.vid -eq 'rec-20261010-042000-l7' -and (Near $mv.vidDur 90 0.5))
  $fr = $false; for ($i = 0; $i -lt 40 -and -not $fr; $i++) { Start-Sleep -Milliseconds 500; $fr = @((J '/vault/list').moments | Where-Object { $_.id -eq 'l20261010-041318-7' -and $_.frame }).Count -eq 1 }
  $fj = Get-Raw '/vault/frame?id=l20261010-041318-7'
  Check "a real picture of the recording is made in the background for the card (a JPEG, $($fj.bytes.Length) bytes$(if ($fj.bytes.Length -lt 200) { ': ' + [Text.Encoding]::ASCII.GetString($fj.bytes) }); frame flag in the list: $fr)" ($fr -and $fj.code -eq 200 -and $fj.bytes[0] -eq 0xFF -and $fj.bytes[1] -eq 0xD8 -and $fj.bytes.Length -gt 500)
  $fn = Get-Raw '/vault/frame?id=l20261009-185837-2'
  Check 'a lap with no recording has no picture route answer (404, the card shows its map)' ($fn.code -eq 404)
} else { '  skip  irdash is the build from before the picture route (run dash\build.ps1 to deploy it), the frame checks wait for that' }
Cdp-Open "$api/v2/vault.html#m=l20261010-041318-7"
$okR = Wait-Page "!!(V.cur && V.rec && V.vid && V.vid.readyState >= 1 && V.trace)" 60
Check 'the recorded lap opens on the Vault''s player (no workbench over it), its clip loaded and the traces drawn' ($okR -and -not (Cdp-Eval "!!document.getElementById('wbHost')") -and (Cdp-Eval "V.lap") -eq 7)
# the player: EXPAND fills the page, Escape makes it smaller again (not back to the cards), Space plays, sound is remembered
$null = Cdp-Eval "document.getElementById('pExpand').click(); 1"; Start-Sleep -Milliseconds 300
$th = (Cdp-Eval "JSON.stringify({ on: document.getElementById('viewDetail').classList.contains('theater'), vw: Math.round(document.getElementById('vidBox').getBoundingClientRect().width), side: getComputedStyle(document.getElementById('cSide')).display, label: document.getElementById('pExpand').textContent })") | ConvertFrom-Json
Check "EXPAND: the video fills the page ($($th.vw) px wide, the side column $($th.side)), the button now says '$($th.label)'" ($th.on -and $th.vw -ge 1700 -and $th.side -eq 'none' -and $th.label -eq 'Smaller')
$null = Cdp-Eval "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); 1"; Start-Sleep -Milliseconds 300
Check 'Escape takes EXPAND away and stays on the lap' ((Cdp-Eval "!document.getElementById('viewDetail').classList.contains('theater') && V.id === 'l20261010-041318-7'") -eq $true)
$null = Cdp-Eval "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'e', bubbles: true })); 1"
Check 'the E key does the same as EXPAND' ((Cdp-Eval "document.getElementById('viewDetail').classList.contains('theater')") -eq $true)
$null = Cdp-Eval "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'e', bubbles: true })); 1"
$fsb = Cdp-Eval "typeof toggleFull === 'function' && !!document.getElementById('pFull') && document.getElementById('pFull').getBoundingClientRect().height >= 48"
Check 'a FULL SCREEN button is there, 48 px or taller (the browser allows full screen only from a real press, so it is pressed by hand)' ($fsb -eq $true)
$p0 = Cdp-Eval "V.vid.paused"
$null = Cdp-Eval "V.vid.muted = true; document.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true })); 1"; Start-Sleep -Milliseconds 800
$p1 = Cdp-Eval "V.vid.paused"
$null = Cdp-Eval "document.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true })); 1"; Start-Sleep -Milliseconds 300
Check "Space plays and pauses the clip (paused $p0, then $p1, then $(Cdp-Eval 'V.vid.paused'))" ($p0 -eq $true -and $p1 -eq $false -and (Cdp-Eval "V.vid.paused") -eq $true)
$null = Cdp-Eval "V.vid.muted = false; V.vid.volume = 0.3; 1"; Start-Sleep -Milliseconds 200
$null = Cdp-Eval "location.reload(); 1"; Start-Sleep -Milliseconds 300
$okV = Wait-Page "!!(V.vid && V.rec && Math.abs(V.vid.volume - 0.3) < 0.01 && !V.vid.muted && document.getElementById('pVol').value === '0.3')" 40
Check 'the sound level (0.3, not muted) is remembered for the next clip' $okV
$null = Cdp-Eval "document.getElementById('pMute').click(); 1"; Start-Sleep -Milliseconds 200
Check 'SOUND ON / MUTED: one press mutes, and the button says so' ((Cdp-Eval "V.vid.muted && document.getElementById('pMute').textContent === 'Muted' && JSON.parse(localStorage.getItem('vault-vol')).m === true") -eq $true)
$null = Cdp-Eval "document.getElementById('pMute').click(); 1"
Cdp-Shot (Join-Path $shots 'vault-player.png') 0 0 1920 1080
$cg = @(200, 500, 800)
# the lock: both clips kept at the same LapDistPct; the one ahead waits (> 0.2 % gap) and they resume within 0.1 %
$tA = (J '/vault/lap?id=l20261010-041318-7&lap=7').t
$tB = (J '/vault/lap?id=l20261010-041318-8&lap=8').t
Check 'the two laps'' telemetry grids were read for the lock (1001 points each)' ($tA.Count -eq 1001 -and $tB.Count -eq 1001)
$jA = @{ off = 1.0; dur = 90.0; nudge = 0.0; t = $tA } | ConvertTo-Json -Compress -Depth 4
$jB = @{ off = 1.0; dur = 90.0; nudge = 0.0; t = $tB } | ConvertTo-Json -Compress -Depth 4
$lr = (Cdp-Eval "JSON.stringify(V.lockRun($jA, $jB, 0.0166667, 90, [$($cg -join ',')]))") | ConvertFrom-Json
$worst = ($lr.corners | Measure-Object -Property secs -Maximum).Maximum
Check "two clips locked by LapDistPct: at 3 corners the laps are within $([math]::Round($worst*1000,0)) ms (<= 100 ms); the gap is paused as soon as it passes 0.2 % and never runs away ($([math]::Round($lr.maxDelta/10,2)) % at 60 Hz, one step over the deadband)" ($lr.corners.Count -eq 3 -and $worst -le 0.1 -and $lr.maxDelta -le 2.8)
# no self-compare: the same session file + lap number is never offered, and choosing it falls back to another lap
$ir7 = J '/vault/item?id=l20261010-041318-7'
Check 'the comparison list excludes the lap itself (same session file + lap number)' (@($ir7.others | Where-Object { $_.session -eq $ir7.m.session -and $_.lap -eq $ir7.m.lap }).Count -eq 0 -and @($ir7.others).Count -ge 1)
$null = Cdp-Eval "location.hash = 'm=l20261010-041318-7&c=l20261010-041318-7'"
Start-Sleep -Milliseconds 1600
$self = (Cdp-Eval "JSON.stringify({ isSame: V.sameLap({ id: 'l20261010-041318-7', lap: 7, session: V.cur.m.session }, V.cur.m, 7), other: V.sameLap({ id: 'l20261010-041318-8', lap: 8, session: V.cur.m.session }, V.cur.m, 7) })") | ConvertFrom-Json
Check "choosing the lap itself as the comparison is refused (sameLap=$($self.isSame)), another lap is not ($($self.other))" ($self.isSame -eq $true -and $self.other -eq $false)
Check 'no script errors on the recorder player' ((Cdp-Eval "(window.__errs || []).length") -eq 0)
Cdp-Close
Remove-Item (Join-Path $recDir 'rec-20261010-042000-l7.mp4'), (Join-Path $recDir 'rec-20261010-042000-l7.json'), (Join-Path $recDir 'rec-20261010-042000-l8.mp4'), (Join-Path $recDir 'rec-20261010-042000-l8.json') -Force -ErrorAction SilentlyContinue
$null = J '/vault/test/rec?cmd=reindex'      # leave the recorder's in-memory list clean for the next test/session

}
finally {
  try { Cdp-Close } catch { }
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8 } catch { }
  try { $null = J '/vault/test/sandbox?on=0' } catch { }
  Remove-Item $hook -Force -ErrorAction SilentlyContinue
  Remove-Item $lock -Force -ErrorAction SilentlyContinue
  Exit-TestLock
  try { if (Test-Path $tdir) { Remove-Item $tdir -Recurse -Force } } catch { }
  $newLog = @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logN | Where-Object { $_ -match 'vault' -and $_ -match 'rror|exception|could not|failed' })
  if ($newLog.Count) { "  info  irdash.log lines to look at:"; $newLog | Select-Object -First 8 | ForEach-Object { "        $_" } }
}
"$pass passed, $fail failed. Pictures in $shots (v-*.png)"
if ($fail -gt 0) { exit 1 }
