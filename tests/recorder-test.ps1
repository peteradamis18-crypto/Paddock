# Recorder test (C-06, dash\src\recorder.cs, docs\vault.md "Video"): Paddock's own ffmpeg recorder.
# Offline part: a made-up screen (ffmpeg testsrc2, upside down like ddagrab's, with a 32-block binary clock and a readable clock burned into every
# frame) goes through the SAME recorder code as the real screen, driven by a pretend session. It checks the segment bookkeeping (names = exact start
# times, the rolling window), lap detection from telemetry, the clips cut without re-encoding, the sidecar offset to 1/60 s (the burned clock is read
# back from the clip), HTTP Range on /vault/video (also seen by headless Chrome, seeking), 404s, the 50 GB rule, the black-picture warning, the
# restart limit, the ini switch and that ffmpeg is hidden and BelowNormal.
# Real-screen part (section 10, only when Peter has been away 10 minutes): the same recorder films the REAL middle screen for a few seconds
# (screen capture only: no clicks, keys or focus changes) - upright, not black, the right size, the encoder's cost - and the output number is
# matched to the monitor by looking at the pictures. Pictures: tests\shots\rec-*.png
# Nothing touches Peter's real Vault or his files: irdash is switched to the scratch vault under vault-test\.
#   powershell -ExecutionPolicy Bypass -File tests\recorder-test.ps1            (irdash on port 8199 must be the current build)
param([string]$Only = '', [switch]$Keep)   # e.g. -Only 1,2 (a comma list in one string: -File passes it that way)
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

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; $title }
$onlySet = @($Only -split '[ ,]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
function Want($n) { return ($onlySet.Count -eq 0) -or ($onlySet -contains $n) }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System; using System.Diagnostics; using System.Drawing; using System.Drawing.Drawing2D; using System.IO; using System.Runtime.InteropServices; using System.Text; using System.Threading;
public sealed class RecRes { public byte[] Out = new byte[0]; public string Err = ""; public int Code = -1; }
public static class RecTool {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
  // wakes a display that Windows has put to sleep (it is not input: no key, no mouse, no focus); desktop duplication gets no picture from a sleeping display
  public static void WakeDisplays() { IntPtr r; SendMessageTimeout((IntPtr)0xFFFF, 0x0112, (IntPtr)0xF170, (IntPtr)(-1), 2, 2000, out r); }
  public static RecRes Run(string exe, string args, int timeoutMs) {
    RecRes res = new RecRes();
    ProcessStartInfo psi = new ProcessStartInfo(exe, args); psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
    using (Process p = Process.Start(psi)) {
      try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
      MemoryStream ms = new MemoryStream(); StringBuilder se = new StringBuilder();
      Thread t = new Thread(delegate() { try { p.StandardOutput.BaseStream.CopyTo(ms); } catch { } }); t.IsBackground = true; t.Start();
      p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) lock (se) se.AppendLine(e.Data); };
      p.BeginErrorReadLine();
      if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } res.Err = "timed out"; return res; }
      p.WaitForExit(); t.Join(3000); res.Out = ms.ToArray(); lock (se) res.Err = se.ToString(); res.Code = p.ExitCode; return res;
    }
  }
  static Bitmap Small(string path, bool rot180) {
    using (Bitmap src = new Bitmap(path)) {
      Bitmap r = new Bitmap(64, 36);
      using (Graphics g = Graphics.FromImage(r)) { g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.PixelOffsetMode = PixelOffsetMode.HighQuality; g.DrawImage(src, new Rectangle(0, 0, 64, 36)); }
      if (rot180) r.RotateFlip(RotateFlipType.Rotate180FlipNone);
      return r;
    }
  }
  static double Gray(Color c) { return 0.299 * c.R + 0.587 * c.G + 0.114 * c.B; }
  // mean absolute grey difference (0..255) of two pictures at 64x36; rotateB turns the second one upside down first
  public static double Diff(string a, string b, bool rotateB) {
    using (Bitmap A = Small(a, false)) using (Bitmap B = Small(b, rotateB)) {
      double s = 0; for (int y = 0; y < 36; y++) for (int x = 0; x < 64; x++) s += Math.Abs(Gray(A.GetPixel(x, y)) - Gray(B.GetPixel(x, y)));
      return s / (64.0 * 36.0);
    }
  }
  // { mean, max } grey level of a picture at 64x36
  public static double[] Stats(string a) {
    using (Bitmap A = Small(a, false)) { double s = 0, m = 0; for (int y = 0; y < 36; y++) for (int x = 0; x < 64; x++) { double g = Gray(A.GetPixel(x, y)); s += g; if (g > m) m = g; } return new double[] { s / (64.0 * 36.0), m }; }
  }
  public static void Shot(string path, int x, int y, int w, int h) {
    using (Bitmap b = new Bitmap(w, h)) using (Graphics g = Graphics.FromImage(b)) { g.CopyFromScreen(x, y, 0, 0, new Size(w, h)); b.Save(path, System.Drawing.Imaging.ImageFormat.Png); }
  }
  public static void Scale(string src, string dst, int w) {
    using (Bitmap a = new Bitmap(src)) using (Bitmap b = new Bitmap(w, a.Height * w / a.Width)) using (Graphics g = Graphics.FromImage(b)) { g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.DrawImage(a, 0, 0, b.Width, b.Height); b.Save(dst, System.Drawing.Imaging.ImageFormat.Png); }
  }
}
'@ -ReferencedAssemblies System.Drawing

$ffmpeg = Join-Path $root 'vault\bin\ffmpeg.exe'; $ffprobe = Join-Path $root 'vault\bin\ffprobe.exe'
$tdir = Join-Path $root 'vault-test'; $recDir = Join-Path $tdir 'vault\rec'; $clipDir = Join-Path $tdir 'vault\clips'
$sessDir = Join-Path $tdir 'vault\sessions'; $savedDir = Join-Path $tdir 'vault\saved'
$hook = Join-Path $root 'dash\test-hook.on'; $lock = Join-Path $root 'dash\deploy.lock'; $logFile = Join-Path $root 'dash\irdash.log'
$tmp = Join-Path $env:TEMP ('rec-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'

function Tool($exe, $argLine, $timeout = 60000) { $r = [RecTool]::Run($exe, $argLine, $timeout); return $r }
function Probe($argLine) { $r = Tool $ffprobe $argLine 60000; return ([Text.Encoding]::UTF8.GetString($r.Out)) }
function Log-Since($n) { $all = @(Get-Content $logFile -ErrorAction SilentlyContinue); if ($all.Count -lt $n) { return $all }; return @($all | Select-Object -Skip $n) }   # irdash.log starts again from empty at 2 MB: then everything in it is newer
function Fake($h) { $q = ($h.Keys | ForEach-Object { "$_=" + ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $h[$_])) }) -join '&'; $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?$q" -TimeoutSec 8 }
function St { J '/vault/test/rec?cmd=status' }
function Wait-For($scriptBlock, $secs, $everyMs = 300) { $until = (Get-Date).AddSeconds($secs); while ((Get-Date) -lt $until) { if (& $scriptBlock) { return $true }; Start-Sleep -Milliseconds $everyMs }; return $false }
# the 32-block clock of a picture: milliseconds since the run's base, one value per decoded frame (the clip is decoded upright: the rotation flag is applied by ffmpeg)
function Read-Clock($clip, $ss, $n, [switch]$Raw) {
  $pre = if ($Raw) { 'hflip,vflip,' } else { '' }      # a segment has no rotation flag: it is still upside down, like ddagrab's picture
  $r = Tool $ffmpeg ("-v error -ss " + ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.000}', [math]::Max(0.0, [double]$ss))) + " -i `"$clip`" -frames:v $n -vf ${pre}crop=640:32:0:0,scale=32:1:flags=neighbor,format=gray -fps_mode passthrough -f rawvideo -") 60000
  $vals = @(); $b = $r.Out
  for ($k = 0; $k + 32 -le $b.Length; $k += 32) { $ms = 0.0; for ($i = 0; $i -lt 32; $i++) { if ($b[$k + $i] -gt 128) { $ms += [math]::Pow(2, $i) } }; $vals += $ms }
  return $vals
}
# decodes a file completely and returns the error lines (the null muxer complains about frames closer than 1/60 s in a variable-rate recording: that is its clock, not a bad picture)
function Decode-Errors($path) { $r = Tool $ffmpeg "-v error -i `"$path`" -f null -" 180000; $bad = @($r.Err -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch 'non monotonically increasing dts to muxer' -and $_ -notmatch 'Last message repeated' -and $_ -notmatch '^\s*\d+\s*$' }); if ($r.Code -ne 0) { $bad += "exit $($r.Code)" }; return $bad }
# the sync proof for one moment of a clip: decode the frames from just before the sidecar's offset, read the clock burned into them, and compare
# (a) with the moment the sidecar names (nearest frame; a frame the sim-less test source skipped can widen the gap) and
# (b) with the clip's own time axis: every decoded frame's burned clock must equal clipStart + (its packet time - videoStart), within 2 ms
$script:ptsCache = @{}
function Sync-Check($c, $offset, $expWall, $baseMs) {
  $f = Lap-Clip $c
  if (-not $script:ptsCache.ContainsKey($f)) { $script:ptsCache[$f] = @((Probe "-v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 `"$f`"").Split("`n") | Where-Object { $_.Trim() } | ForEach-Object { [double]($_.Split(',')[0]) }) }
  $pts = $script:ptsCache[$f]; $ss = [math]::Max(0.0, $offset - 0.05)
  $v = Read-Clock $f $ss 7
  $exp = $expWall - $baseMs; $mapErr = 0.0
  $wallOfPacket = [double[]]@($pts | ForEach-Object { ($c.clipStartMs - $baseMs) + ($_ - $c.videoStart) * 1000.0 })       # what the clip's time axis says each packet shows
  for ($i = 0; $i -lt $v.Count; $i++) {
    $ix = [Array]::BinarySearch($wallOfPacket, $v[$i]); if ($ix -lt 0) { $ix = -bnot $ix }
    $d = 1e9; if ($ix -lt $wallOfPacket.Length) { $d = [math]::Abs($wallOfPacket[$ix] - $v[$i]) }; if ($ix -gt 0) { $d = [math]::Min($d, [math]::Abs($wallOfPacket[$ix - 1] - $v[$i])) }
    if ($d -gt $mapErr) { $mapErr = $d }
  }
  $best = 999.0; $spacing = 0.0
  if ($v.Count) { $best = ($v | ForEach-Object { [math]::Abs($_ - $exp) } | Measure-Object -Minimum).Minimum }
  for ($i = 0; $i + 1 -lt $v.Count; $i++) { if ($v[$i] -le $exp + 0.5 -and $v[$i + 1] -ge $exp - 0.5) { $spacing = $v[$i + 1] - $v[$i] } }
  return @{ ok = ($v.Count -ge 5 -and $mapErr -le 2.0 -and ($best -le 16.7 -or ($spacing -gt 0 -and $spacing -le 50))); best = $best; mapErr = $mapErr; spacing = $spacing; vals = $v; exp = $exp }
}
function Lap-Clip($c) { Join-Path $clipDir ($c.id + '.mp4') }

# ---- the pretend lap driver: laps of a few seconds, with the wall-clock time of every line (the test's own clock) ----
$script:lineAt = @{}
function Drive-Laps($spec, $keepLap) {
  # LapCurrentLapTime counts from the line, as the sim's does: the recorder takes "the line was crossed LapCurrentLapTime ago" from it.
  # Optional per lap: stepMs (how often the pretend telemetry changes, default 250), hitchAt (no telemetry at all from this many seconds into the lap,
  # then the last value and the line arrive together: a hitch in the sim or a busy moment), tow = @{ at = s; pct = p } (a jump in lap distance).
  $sw = [Diagnostics.Stopwatch]::StartNew(); $prevN = 0; $prevSecs = 0.0
  foreach ($lp in $spec) {
    $lapT0 = $sw.Elapsed.TotalSeconds
    $call = NowMs
    Fake @{ Lap = $lp.n; LapDistPct = 0.003; LapCurrentLapTime = 0.0; OnPitRoad = [int][bool]$lp.pit; PlayerTrackSurface = 3 }
    $script:lineAt[$lp.n] = $call
    $step = if ($lp.stepMs) { [int]$lp.stepMs } else { 250 }
    $tEnd = $lapT0 + $lp.secs; $announced = ($prevN -eq 0); $keptDone = $false; $offDone = $false; $pitFlick = $false; $towDone = $false
    while ($sw.Elapsed.TotalSeconds -lt $tEnd - 0.05) {
      $el = $sw.Elapsed.TotalSeconds - $lapT0
      if ($lp.hitchAt -and $el -ge $lp.hitchAt) { Start-Sleep -Milliseconds 20; continue }
      $h = @{ LapDistPct = [math]::Min(0.97, $el / $lp.secs); LapCurrentLapTime = $el }
      if ($lp.tow -and -not $towDone -and $el -ge $lp.tow.at) { $h.LapDistPct = $lp.tow.pct; $towDone = $true }
      if (-not $announced -and $el -ge 0.8) { $h.LapLastLapTime = $prevSecs; $announced = $true }          # the sim announces the last lap a moment after the line
      if ($lp.off -and $el -ge 1.0 -and $el -lt 3.2) { $h.PlayerTrackSurface = 0 } elseif ($lp.off -and $el -ge 3.2 -and -not $offDone) { $h.PlayerTrackSurface = 3; $offDone = $true }
      if ($lp.flick -and $el -ge 1.0 -and $el -lt 2.2) { $h.OnPitRoad = 1 } elseif ($lp.flick -and $el -ge 2.2 -and -not $pitFlick) { $h.OnPitRoad = 0; $pitFlick = $true }
      Fake $h
      if ($lp.keepAt -and -not $keptDone -and $el -ge $lp.keepAt) { $keptDone = $true; $null = Invoke-WebRequest -UseBasicParsing "$api/api/do?c=vkkeep" -TimeoutSec 8 }
      Start-Sleep -Milliseconds $step
    }
    Fake @{ LapDistPct = 0.99; LapCurrentLapTime = $sw.Elapsed.TotalSeconds - $lapT0 }
    if (-not $lp.hitchAt) { while ($sw.Elapsed.TotalSeconds -lt $tEnd) { Start-Sleep -Milliseconds 2 } }      # after a hitch the line follows at once
    $prevN = $lp.n; $prevSecs = $lp.secs
  }
}
# ---- headless Chrome with the DevTools protocol (the player's own eyes) ----
$script:cdp = $null
function Cdp-Open($url, $w = 1280, $h = 800) {
  $prof = Join-Path $env:TEMP ('rec-test-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9373
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', '--autoplay-policy=no-user-gesture-required', 'about:blank') -PassThru -WindowStyle Hidden
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0 }
  $null = Cdp 'Page.enable' @{}
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
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# ---- one raw HTTP request (Range, status, headers) ----
function Http($path, $from, $to, $suffix) {
  $rq = [Net.HttpWebRequest]::Create("$api$path"); $rq.Timeout = 60000
  if ($suffix) { $null = $rq.AddRange('bytes', - [int64]$suffix) } elseif ($null -ne $from -and $null -ne $to) { $null = $rq.AddRange('bytes', [int64]$from, [int64]$to) } elseif ($null -ne $from) { $null = $rq.AddRange('bytes', [int64]$from) }
  try { $resp = $rq.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { return @{ code = 0; bytes = @(); headers = @{} } } }
  $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms); $h = @{}; foreach ($k in $resp.Headers.AllKeys) { $h[$k] = $resp.Headers[$k] }
  $r = @{ code = [int]$resp.StatusCode; bytes = $ms.ToArray(); headers = $h }; $resp.Close(); return $r
}

$logN = @(Get-Content $logFile).Count
$swAll = [Diagnostics.Stopwatch]::StartNew()
'Recorder test'
$fgBefore = [RecTool]::GetForegroundWindow()
Enter-TestLock 'recorder'   # one live test at a time (tests\guard.ps1); released in finally
try {

# the deploy lock: nobody rebuilds irdash while this test needs it (same rule as the other tests)
for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock (' + (Get-Content $lock) + ')'; Start-Sleep -Seconds 60 }
Set-Content $lock ('recorder ' + (Get-Date).ToString('HH:mm:ss'))
Set-Content $hook 'recorder test'
if (Test-Path $tdir) { Remove-Item $tdir -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $tdir 'src') | Out-Null
$null = J '/vault/test/sandbox?on=1&reset=1'

# =====================================================================================================
if (Want 1) {
Section '1. the ini switch and the shipped setting'
$sw1 = J ('/vault/test/recswitch?text=' + (Q "recorder=1"))
Check 'recorder=1 turns it on' ($sw1.on -eq $true)
Check 'recorder=0 is off' ((J ('/vault/test/recswitch?text=' + (Q "recorder=0"))).on -eq $false)
Check 'no recorder line is off' ((J ('/vault/test/recswitch?text=' + (Q "vault=1`r`nofficial=0"))).on -eq $false)
Check 'anything but 1 is off (2, yes, on)' ((J ('/vault/test/recswitch?text=' + (Q "recorder=2"))).on -eq $false -and (J ('/vault/test/recswitch?text=' + (Q "recorder=yes"))).on -eq $false -and (J ('/vault/test/recswitch?text=' + (Q "recorder=on"))).on -eq $false)
Check 'a commented line does not count (;recorder=1)' ((J ('/vault/test/recswitch?text=' + (Q ";recorder=1`r`n; recorder=1"))).on -eq $false)
Check 'spaces around the = and the key in capitals still work (Recorder = 1)' ((J ('/vault/test/recswitch?text=' + (Q "Recorder = 1"))).on -eq $true)
$ini = Get-Content (Join-Path $root 'dash\irdash.ini')
$inOn = @($ini | Where-Object { $_ -match '^\s*recorder\s*=\s*1\s*$' }).Count -eq 1
$inOff = @($ini | Where-Object { $_ -match '^\s*recorder\s*=\s*0\s*$' }).Count -eq 1
Check 'the real irdash.ini has a recorder line (0 = off until the lead turns it on, 1 = on)' ($inOn -or $inOff)
Check 'the running irdash matches that setting and films nothing with no session on' ((St).enabled -eq $inOn -and (St).running -eq $false)
Check 'ffmpeg and ffprobe are in vault\bin' ((Test-Path $ffmpeg) -and (Test-Path $ffprobe))
}

# =====================================================================================================
if (Want 2) {
Section '2. which capture output is the middle screen (by position)'
$map = J '/vault/test/recmap'
$screens = [Windows.Forms.Screen]::AllScreens
Note ("Windows sees: " + (($screens | ForEach-Object { "$($_.DeviceName) $($_.Bounds.X),$($_.Bounds.Y) $($_.Bounds.Width)x$($_.Bounds.Height)" }) -join ' | '))
Note ("DXGI outputs:  " + (($map.outputs | ForEach-Object { "idx$($_.index) $($_.x),$($_.y) $($_.w)x$($_.h) rot$($_.rotation)" }) -join ' | '))
$allMatch = $true
foreach ($s in $screens) { $m = @($map.outputs | Where-Object { $_.x -eq $s.Bounds.X -and $_.y -eq $s.Bounds.Y -and $_.w -eq $s.Bounds.Width -and $_.h -eq $s.Bounds.Height }); if ($m.Count -ne 1) { $allMatch = $false } }
Check 'every Windows screen has exactly one capture output at the same place and size (matched by position, not by the DISPLAY number)' ($allMatch -and @($map.outputs).Count -eq @($screens).Count)
$mid = $map.middle
Check "the middle race screen is output $($mid.index) at 0,0 2560x1440 (the Windows primary)" ($mid -and $mid.x -eq 0 -and $mid.y -eq 0 -and $mid.w -eq 2560 -and $mid.h -eq 1440)
$prim = $screens | Where-Object { $_.Primary }
Check 'it is the same screen Windows calls primary on this rig' ($prim -and $prim.Bounds.X -eq $mid.x -and $prim.Bounds.Y -eq $mid.y)
Check 'the screen above the rig (the dashboard, 1920x1080) and the two side screens are not picked' (@($map.outputs | Where-Object { $_.index -ne $mid.index -and $_.x -eq 0 -and $_.y -eq 0 }).Count -eq 0)
Check 'that screen is rotated 180 degrees in Windows (DXGI rotation 3), so its picture needs the rotation flag' ($mid.rotation -eq 3)
Check 'the adapter is the first one (ddagrab needs no -init_hw_device then)' ($mid.adapter -eq 0)
}

# =====================================================================================================
if (Want 3) {
Section '3. segments: names are exact start times, a rolling window of the last seconds'
$l0 = (Log-Since $logN).Count + $logN
$r = J '/vault/test/rec?cmd=on&keep=25&seg=5&grace=3&minlap=3'
Check 'the test recorder is on in the scratch vault, with the made-up screen' ($r.test -eq $true -and $r.source -eq 'test' -and $r.running -eq $false)
Fake @{ IsOnTrack = 1; Lap = 1; LapDistPct = 0.003; LapCurrentLapTime = 0.0; LapLastLapTime = 0.0; OnPitRoad = 0; PlayerTrackSurface = 3; SessionNum = 0; SessionTime = 100.0 }
$t0 = Get-Date
$ok = Wait-For { (St).running } 10
Check "ffmpeg starts about a second after he is in the car ($([math]::Round(((Get-Date) - $t0).TotalSeconds, 1)) s)" $ok
$s = St
$p = Get-Process -Id $s.ffmpegPid -ErrorAction SilentlyContinue
Check 'ffmpeg runs at BelowNormal priority' ($p -and $p.PriorityClass -eq 'BelowNormal')
Check 'ffmpeg has no window (hidden, never takes focus)' ($p -and $p.MainWindowHandle -eq 0 -and [RecTool]::GetForegroundWindow() -eq $fgBefore)
Check 'the command line stamps frames with the wall clock and keeps microsecond times (setpts=RTCTIME, enc_time_base 1/1000000)' ($s.lastRunArgs -match 'setpts=RTCTIME' -and $s.lastRunArgs -match 'enc_time_base 1/1000000')
Check 'the rolling files are segments of about 5 s in the scratch vault, not in iRacing or OneDrive' ($s.lastRunArgs -match 'vault-test\\vault\\rec' -and $s.lastRunArgs -match 'segment_time 4\.9')
# let it run for a minute with nothing happening, sampling the window as it rolls
$samples = @(); $seenNames = @{}; $firstSeen = @{}
$until = (Get-Date).AddSeconds(58)
while ((Get-Date) -lt $until) {
  Start-Sleep -Milliseconds 1500
  $s = St; $nowMs = NowMs
  foreach ($g in $s.segList) { if (-not $firstSeen.ContainsKey($g.name)) { $firstSeen[$g.name] = $nowMs } ; $seenNames[$g.name] = $g }
  $samples += @{ at = $nowMs; n = @($s.segList).Count; oldestEnd = $(if (@($s.segList).Count) { ($s.segList | Measure-Object -Property endMs -Minimum).Minimum } else { 0 }); keep = $s.keepSecs }
}
$s = St; $segs = @($s.segList | Sort-Object { [double]$_.startMs })
Note ("run time 58 s, segments kept now: $($segs.Count), ever seen: $($seenNames.Count)")
Check 'more segments were written than are kept (the window rolls)' ($seenNames.Count -ge 9 -and $seenNames.Count -gt $segs.Count + 3)
Check 'about keep/seg segments are kept (25 s of 5 s segments: 4 to 8)' ($segs.Count -ge 4 -and $segs.Count -le 8)
$late = @($samples | Where-Object { $_.at -gt ($t0.ToUniversalTime() - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalMilliseconds + 35000 })
$stale = @($late | Where-Object { $_.oldestEnd -gt 0 -and $_.oldestEnd -lt $_.at - 25000 - 4000 })
Check 'after the first 35 s no segment older than the window (25 s + 4 s) was still held' ($late.Count -ge 5 -and $stale.Count -eq 0)
$files = @(Get-ChildItem $recDir -Filter *.ts -ErrorAction SilentlyContinue)
Check 'the files on disk are the kept segments (plus at most the one being written), all named rec-<UTC start>.ts' ($files.Count -ge $segs.Count -and $files.Count -le $segs.Count + 2 -and @($files | Where-Object { $_.Name -notmatch '^(rec-\d{8}-\d{6}-\d{3}|r\d+-\d{5})\.ts$' }).Count -eq 0)
$named = @($segs | Where-Object { $_.name -match '^rec-\d{8}-\d{6}-\d{3}\.ts$' })
Check 'every kept segment is named by its start time to the millisecond' ($named.Count -eq $segs.Count -and $segs.Count -gt 0)
$bad = 0; $maxd = 0.0
foreach ($g in $segs) {
  if ($g.name -match '^rec-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-(\d{3})\.ts$') {
    $dt = New-Object DateTime ([int]$Matches[1]), ([int]$Matches[2]), ([int]$Matches[3]), ([int]$Matches[4]), ([int]$Matches[5]), ([int]$Matches[6]), ([DateTimeKind]::Utc)
    $nameMs = (($dt - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalMilliseconds) + [int]$Matches[7]
    # the name must agree with the first frame inside the file (an independent read: ffprobe), and with the binary clock burned into that frame
    $first = [double]((Probe "-v error -select_streams v:0 -read_intervals %+#1 -show_entries packet=pts_time -of csv=p=0 `"$(Join-Path $recDir $g.name)`"").Trim().Split("`n")[0].Trim().Split(',')[0])
    $fileMs = [double]$s.baseMs + $first * 1000.0
    $d = [math]::Abs($nameMs - $fileMs); if ($d -gt $maxd) { $maxd = $d }; if ($d -gt 1.5 -or [math]::Abs($g.startMs - $fileMs) -gt 0.5) { $bad++ }
  } else { $bad++ }
}
Check "each name equals the first frame's time in the file and the index (worst gap $([math]::Round($maxd, 2)) ms; a name rounds to the ms)" ($bad -eq 0 -and $segs.Count -gt 0)
$gaps = 0; for ($i = 1; $i -lt $segs.Count; $i++) { if ([math]::Abs($segs[$i - 1].endMs - $segs[$i].startMs) -gt 2) { $gaps++ } }
Check 'the kept segments follow each other with no gap and no overlap (end = next start, within 2 ms)' ($gaps -eq 0)
$lens = @($segs | ForEach-Object { ($_.endMs - $_.startMs) / 1000.0 }); Note ("segment lengths (s): " + (($lens | ForEach-Object { [math]::Round($_, 3) }) -join ' '))
Check 'each segment is about 5 s long (3.5 to 6.5 s: a segment is cut at the first keyframe after the set time)' (@($lens | Where-Object { $_ -lt 3.5 -or $_ -gt 6.5 }).Count -eq 0 -and $lens.Count -gt 0)
if ($segs.Count) {
  $g = $segs[[math]::Min(1, $segs.Count - 1)]
  $kf = (Probe "-v error -select_streams v:0 -show_entries packet=pts_time,flags -of csv=p=0 `"$(Join-Path $recDir $g.name)`"").Split("`n") | Where-Object { $_ -match ',K' } | ForEach-Object { [double]($_.Split(',')[0]) }
  $ks = @($kf); $span = ($g.endMs - $g.startMs) / 1000.0
  Check "a keyframe about every second inside a segment ($($ks.Count) in $([math]::Round($span, 1)) s)" ($ks.Count -ge [math]::Floor($span) - 1 -and $ks.Count -le [math]::Ceiling($span) + 2)
  # the burned clock of the first frame agrees with the segment's start (the wall clock the file was stamped with)
  $clk = Read-Clock (Join-Path $recDir $g.name) 0 1 -Raw
  $exp = $g.startMs - [double]$s.baseMs
  Check "the clock burned into the first frame reads the segment's start ($([math]::Round($clk[0], 0)) ms vs $([math]::Round($exp, 0)) ms since the run's base)" ($clk.Count -eq 1 -and (Near $clk[0] $exp 20))
  Copy-Item (Join-Path $recDir $g.name) (Join-Path $tmp 'seg-sample.ts')
}
Check 'the picture check ran on the first segment: not black, and logged' ($s.blackChecked -eq $true -and $s.black -eq $false -and @(Log-Since $l0 | Where-Object { $_ -match 'recorder: picture check ok' }).Count -ge 1)
# PX-06: the REC pill's one verdict. "recording" only while segments keep landing; a frozen ffmpeg (process alive, no
# output) must turn into "stalled" (NOT RECORDING on the fourth screen), and back once video lands again.
$s = St
Check "capture verdict while segments land: recording ($($s.capture.state), last segment $($s.capture.lastSegAgoS) s ago)" ($s.capture.state -eq 'recording')
if (-not ('RecSusp' -as [type])) { Add-Type 'using System; using System.Runtime.InteropServices; public static class RecSusp { [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h); [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h); }' }
$fp = Get-Process -Id $s.ffmpegPid -ErrorAction SilentlyContinue
if ($fp -and $fp.Path -match 'ffmpeg') {
  [void][RecSusp]::NtSuspendProcess($fp.Handle)
  try { $stalled = Wait-For { (St).capture.state -eq 'stalled' } 30 } finally { [void][RecSusp]::NtResumeProcess($fp.Handle) }
  Check 'a frozen ffmpeg (alive, writing nothing) is reported as stalled, not recording' $stalled
  Check 'once video lands again the verdict is recording again' (Wait-For { (St).capture.state -eq 'recording' } 25)
} else { Check 'the test ffmpeg process is there to freeze' $false }
Fake @{ IsOnTrack = 0 }
$ok = Wait-For { -not (St).running } 15
Check 'ffmpeg stops a few seconds after he leaves the car (grace 3 s in the test; 20 s for real)' $ok
Check 'and the log says why' (@(Log-Since $l0 | Where-Object { $_ -match 'recorder: stopping \((you )?left the car\)' }).Count -ge 1 -and @(Log-Since $l0 | Where-Object { $_ -match 'recorder: started ffmpeg #\d+' }).Count -ge 1)
$null = J '/vault/test/rec?cmd=off'
}

# =====================================================================================================
if (Want 4) {
Section '4. laps from telemetry: the session best, KEEP, cut without re-encoding, the offset to 1/60 s'
$l0 = @(Get-Content $logFile).Count
$r = J '/vault/test/rec?cmd=on&keep=60&seg=5&grace=4&minlap=3'
Fake @{ IsOnTrack = 1; Lap = 1; LapDistPct = 0.003; LapCurrentLapTime = 0.0; LapLastLapTime = 0.0; OnPitRoad = 1; PlayerTrackSurface = 3; SessionNum = 0; SessionTime = 100.0 }
$ok = Wait-For { (St).running } 10
Check 'the recorder runs while he is in the car' $ok
$s = St; $baseMs = [double]$s.baseMs
Start-Sleep -Seconds 4
$spec = @(
  @{ n = 1; secs = 3.0; pit = $true },                      # the lap he leaves the pits on: not clean
  @{ n = 2; secs = 8.0 },                                   # first clean lap: the session best so far -> clip
  @{ n = 3; secs = 7.0 },                                   # faster -> clip
  @{ n = 4; secs = 9.0 },                                   # slower: nothing
  @{ n = 5; secs = 6.0; flick = $true },                    # fast but touched the pit road: not clean
  @{ n = 6; secs = 8.5; keepAt = 3.0 },                     # slower, but the KEEP key is pressed -> clip, kept for good
  @{ n = 7; secs = 6.5 },                                   # faster than lap 3 -> clip
  @{ n = 8; secs = 5.0; off = $true },                      # fastest, but 2.2 s off the track: not clean
  @{ n = 9; secs = 7.5 },                                   # slower than 6.5: nothing
  @{ n = 10; secs = 3.0 }
)
Drive-Laps $spec
$null = Wait-For { $q = St; $q.pendingCuts -eq 0 -and $q.probing -eq 0 -and $q.busy -eq 0 -and @($q.clipList).Count -ge 4 } 40
$s = St
$ids = @($s.clipList | Sort-Object { $_.lap } | ForEach-Object { $_.lap })
Check "clips exist for exactly laps 2, 3, 6 and 7 (got: $($ids -join ', '))" (($ids -join ',') -eq '2,3,6,7')
$lg = Log-Since $l0
Check 'lap 1 (pits), lap 5 (touched the pit road) and lap 8 (off the track) were not clean, and the log says why' (@($lg | Where-Object { $_ -match 'lap 1 .*not clean \(pits\)' }).Count -ge 1 -and @($lg | Where-Object { $_ -match 'lap 5 .*not clean \(pits\)' }).Count -ge 1 -and @($lg | Where-Object { $_ -match 'lap 8 .*not clean \(off track\)' }).Count -ge 1)
Check 'laps 4 and 9 (slower than the best) got no clip, and the log says so' (@($lg | Where-Object { $_ -match 'lap 4 .*no clip' }).Count -ge 1 -and @($lg | Where-Object { $_ -match 'lap 9 .*no clip' }).Count -ge 1)
$cl = @{}; foreach ($c in $s.clipList) { $cl[[int]$c.lap] = $c }
Check 'lap 2 and 3 and 7 are "best of the session", lap 6 is "keep" and kept for good' ($cl[2].why -eq 'best' -and $cl[3].why -eq 'best' -and $cl[7].why -eq 'best' -and $cl[6].why -eq 'keep' -and $cl[6].keep -eq $true -and $cl[3].keep -eq $false)
Check 'the lap times are the sim''s announced times' ((Near $cl[2].lapTime 8.0 0.001) -and (Near $cl[3].lapTime 7.0 0.001) -and (Near $cl[6].lapTime 8.5 0.001) -and (Near $cl[7].lapTime 6.5 0.001))
Copy-Item (Lap-Clip $cl[3]) (Join-Path $tmp 'clip-l3.mp4')
$shotMade = $false
foreach ($n in 2, 3, 6, 7) {
  $c = $cl[$n]; $f = Lap-Clip $c
  Check "lap $n : the clip and its sidecar are on disk, named rec-<lap start UTC>-l$n" ((Test-Path $f) -and (Test-Path ($f -replace '\.mp4$', '.json')) -and $c.id -match "^rec-\d{8}-\d{6}-l$n$")
  $call = $script:lineAt[$n]
  Check "lap $n : the lap start found from telemetry is the line the test sent (within 150 ms; got $([math]::Round($c.lapStartMs - $call, 0)) ms)" (Near $c.lapStartMs $call 150)
  $dur = [double]$c.duration
  Check "lap $n : the clip runs from 1 to 3 s before the lap to 1 to 3 s after it ($([math]::Round($c.lapStartOffset, 2)) s in, $([math]::Round($dur - $c.lapEndOffset, 2)) s after)" ($c.lapStartOffset -ge 0.9 -and $c.lapStartOffset -le 3.1 -and ($dur - $c.lapEndOffset) -ge 0.7 -and ($dur - $c.lapEndOffset) -le 1.1 -and -not $c.truncated)
  $sy = Sync-Check $c $c.lapStartOffset $c.lapStartMs $baseMs
  Check "lap $n : the frame at lapStartOffset shows the lap start to 1/60 s (nearest frame $([math]::Round($sy.best, 1)) ms away; the clip's clock matches its time axis to $([math]::Round($sy.mapErr, 2)) ms)" $sy.ok
  if (-not $sy.ok) { Note "debug lap $n start: expected $($sy.exp), decoded $($sy.vals -join ' ')" }
  $sy2 = Sync-Check $c $c.lapEndOffset $c.lapEndMs $baseMs
  Check "lap $n : and the frame at lapEndOffset shows the lap end (nearest frame $([math]::Round($sy2.best, 1)) ms away, time axis $([math]::Round($sy2.mapErr, 2)) ms)" $sy2.ok
  if (-not $sy2.ok) { Note "debug lap $n end: expected $($sy2.exp), decoded $($sy2.vals -join ' ')" }  if ($n -eq 3 -and -not $shotMade) {
    $shotMade = $true
    $null = Tool $ffmpeg ("-v error -y -ss " + ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.000}', $c.lapStartOffset)) + " -i `"$f`" -frames:v 1 `"$(Join-Path $shots 'rec-test-lapstart.png')`"")
  }
}
$c = $cl[3]; $f = Lap-Clip $c
$info = (Probe "-v error -show_streams -show_format -of json `"$f`"") | ConvertFrom-Json
$vs = $info.streams | Where-Object { $_.codec_type -eq 'video' }
Check 'the clip is H.264 in an mp4, 1280x720 (the test picture), 60 fps' ($vs.codec_name -eq 'h264' -and $vs.width -eq 1280 -and $vs.height -eq 720 -and $info.format.format_name -match 'mp4')
$rot = (Probe "-v error -select_streams v:0 -show_entries stream_side_data=rotation -of default=nw=1:nk=1 `"$f`"").Trim()
Check "the picture is turned upright by the mp4's rotation flag (rotation $rot), not by a re-encode" ($rot -match '^-?180')
$s = St
Check 'the clip was cut with -c copy (no re-encode) and the rotation flag set on the input' ($s.lastCutArgs -match '-c copy' -and $s.lastCutArgs -match '-display_rotation 180' -and $s.lastCutArgs -notmatch 'libx264|-vf|-filter')
# the packets of the clip are the packets of the segments: same count and the same times, shifted by one constant
$k0 = [double]$c.clipStartMs; $vstart = [double]$c.videoStart
$clipPk = @((Probe "-v error -select_streams v:0 -show_entries packet=pts_time,size -of csv=p=0 `"$f`"").Split("`n") | Where-Object { $_.Trim() })
$sumDur = [double]$c.duration
Check "the clip holds every frame of its stretch: $($clipPk.Count) packets for $([math]::Round($sumDur, 2)) s (about 60 a second)" ($clipPk.Count -ge $sumDur * 50 -and $clipPk.Count -le $sumDur * 66)
$segNames = @((St).segList | Where-Object { $_.endMs -gt $k0 -and $_.startMs -lt $k0 + $sumDur * 1000 } | Sort-Object { [double]$_.startMs })
if ($segNames.Count -ge 1) {
  $cat = 'concat:' + (($segNames | ForEach-Object { Join-Path $recDir $_.name }) -join '|')
  $srcPk = @((Probe "-v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 `"$cat`"").Split("`n") | Where-Object { $_.Trim() } | ForEach-Object { [double]($_.Split(',')[0]) })
  $clipT = @($clipPk | ForEach-Object { [double]($_.Split(',')[0]) })
  $shift = ($k0 - [double]$s.baseMs) / 1000.0 - $vstart          # clip time t is source time t + shift
  $maxErr = 0.0; $matched = 0; $srcArr = [double[]]@($srcPk | Sort-Object)
  foreach ($t in $clipT) {
    $want = $t + $shift; $ix = [Array]::BinarySearch($srcArr, $want); if ($ix -lt 0) { $ix = -bnot $ix }
    $m = 1e9; if ($ix -lt $srcArr.Length) { $m = [math]::Abs($srcArr[$ix] - $want) }; if ($ix -gt 0) { $m = [math]::Min($m, [math]::Abs($srcArr[$ix - 1] - $want)) }
    if ($m -gt $maxErr) { $maxErr = $m }; if ($m -lt 0.0006) { $matched++ }
  }
  Check "every packet of the clip is a packet of the recording at the same time (worst gap $([math]::Round($maxErr * 1000, 2)) ms) - it was copied, not re-encoded" ($matched -eq $clipT.Count -and $clipT.Count -gt 100)
} else { Check 'the source segments of the clip were found' $false }
$kfc = @($clipPk | Where-Object { $true }).Count
$decErr = Decode-Errors $f
Check "the whole clip decodes with no error $($decErr | Select-Object -First 1)" ($decErr.Count -eq 0)
# KEEP: the Vault key marked the lap and the recorder kept its clip
$ev = J '/vault/test/events'
Check 'the KEEP key (vkkeep) marked lap 6 in the Vault and the recorder was told' ($ev.events -match 'keep lap 6' -and @($lg | Where-Object { $_ -match 'lap 6 .*kept \(KEEP key\)' }).Count -ge 1)
# KEEP on the lap he has just finished (just over the line) keeps that lap's clip: lap 3's clip is not a keeper until then
$kp = J '/vault/test/rec?cmd=keep&lap=3'
$kc = @((St).clipList | Where-Object { $_.lap -eq 3 })
Check 'KEEP for a lap whose clip already exists marks that clip as kept for good (sidecar rewritten)' ($kp.ok -eq $true -and $kc.Count -eq 1 -and $kc[0].keep -eq $true -and ((Get-Content ((Lap-Clip $kc[0]) -replace '\.mp4$', '.json') -Raw) | ConvertFrom-Json).keep -eq $true)
$none = J '/vault/test/rec?cmd=keep&lap=77'
Check 'KEEP for a lap the recorder never saw says so and cuts nothing' ($none.ok -eq $false -and @((St).clipList).Count -eq 4)

Section '5. the 50 GB rule'
$now = NowMs
$null = J ('/vault/test/rec?cmd=free&bytes=' + [int64](49 * 1GB))
$l1 = @(Get-Content $logFile).Count
$rr = J ("/vault/test/rec?cmd=lap&n=31&start=$($now - 14000)&end=$($now - 7000)&time=6.0")
$null = Wait-For { $q = St; $q.pendingCuts -eq 0 -and $q.busy -eq 0 } 40
$s = St
Check 'with 49 GB free the lap is worth a clip (a new best) but no clip is made' ($rr.why -eq 'best' -and @($s.clipList | Where-Object { $_.lap -eq 31 }).Count -eq 0 -and -not (Test-Path (Join-Path $clipDir ($rr.clipId + '.mp4'))))
Check 'irdash.log says so in plain words (only 49.0 GB is free; Paddock keeps 50 GB free)' (@(Log-Since $l1 | Where-Object { $_ -match 'recorder: not keeping the clip of lap 31 - only 49\.0 GB is free .* keeps 50 GB free' }).Count -eq 1)
$null = J ('/vault/test/rec?cmd=free&bytes=' + [int64](51 * 1GB))
$rr2 = J ("/vault/test/rec?cmd=lap&n=32&start=$($now - 14000)&end=$($now - 7000)&time=5.5")
$null = Wait-For { $q = St; $q.pendingCuts -eq 0 -and $q.busy -eq 0 -and @($q.clipList | Where-Object { $_.lap -eq 32 }).Count -eq 1 } 40
Check 'with 21 GB free the same kind of lap is cut' (@((St).clipList | Where-Object { $_.lap -eq 32 }).Count -eq 1 -and (Test-Path (Join-Path $clipDir ($rr2.clipId + '.mp4'))))
$null = J '/vault/test/rec?cmd=free&bytes=-1'
# a lap that began before the recording did: the clip says it is cut short
$rr3 = J ("/vault/test/rec?cmd=lap&n=33&start=$($baseMs - 600000)&end=$($baseMs - 560000)&time=4.0")
Start-Sleep -Seconds 3
Check 'a lap from before the video existed gets no clip and the log says no video' (@((St).clipList | Where-Object { $_.lap -eq 33 }).Count -eq 0 -and @(Log-Since $l1 | Where-Object { $_ -match 'recorder: no video of lap 33' }).Count -ge 1)
Fake @{ IsOnTrack = 0 }
$ok = Wait-For { -not (St).running } 15
Check 'ffmpeg stopped after he left the car, and the segments that held no clip are still only the last seconds' $ok
Check 'no ffmpeg of the recorder is left running' (@(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" | Where-Object { $_.CommandLine -like '*vault-test*' }).Count -eq 0)
Section '4b. a hitch in the telemetry before the line must not lose the lap (the lead''s failed run: a lap vanished without a word)'
$l0 = @(Get-Content $logFile).Count
$null = J '/vault/test/rec?cmd=on&keep=60&seg=5&grace=4&minlap=3'
Fake @{ IsOnTrack = 1; Lap = 1; LapDistPct = 0.003; LapCurrentLapTime = 0.0; LapLastLapTime = 0.0; OnPitRoad = 1; PlayerTrackSurface = 3; SessionNum = 0; SessionTime = 100.0 }
$ok = Wait-For { (St).running } 10
Check 'the recorder runs while he is in the car' $ok
$base4b = [double](St).baseMs
Start-Sleep -Seconds 3
$script:lineAt = @{}
$spec = @(
  @{ n = 1; secs = 2.0; pit = $true; stepMs = 100 },
  @{ n = 2; secs = 8.0; stepMs = 100; hitchAt = 5.4 },        # the telemetry stops at 67 % of the lap for 2.6 s; the last value (99 %) and the line arrive together
  @{ n = 3; secs = 6.0; stepMs = 100 },                       # then the lap counter jumps from 3 to 5: not a line crossing
  @{ n = 5; secs = 6.0; stepMs = 100; tow = @{ at = 1.0; pct = 0.35 } },    # towed forward a third of a lap: not a fair lap
  @{ n = 6; secs = 5.5; stepMs = 100 },                       # quicker than lap 2: a clip
  @{ n = 7; secs = 3.0; stepMs = 100 }
)
Drive-Laps $spec
$null = Wait-For { $q = St; $q.pendingCuts -eq 0 -and $q.probing -eq 0 -and $q.busy -eq 0 -and @($q.clipList).Count -ge 2 } 40
$s = St; $lg = Log-Since $l0
$ids = @($s.clipList | Sort-Object { $_.lap } | ForEach-Object { $_.lap })
Check "clips exist for exactly laps 2 and 6 (got: $($ids -join ', '))" (($ids -join ',') -eq '2,6')
Check 'lap 2 (the hitch before the line) was decided: clean, the session''s best, cut' (@($lg | Where-Object { $_ -match 'recorder: lap 2 8\.000 .* clean - the session''s best so far, cutting its clip' }).Count -eq 1)
$cl2 = @($s.clipList | Where-Object { $_.lap -eq 2 })[0]
Check 'its clip starts at the line the test sent, within 150 ms, and the offsets are in the sidecar' ($cl2 -and (Near $cl2.lapStartMs $script:lineAt[2] 150) -and $cl2.lapStartOffset -ge 0.9 -and (Near ($cl2.lapEndMs - $cl2.lapStartMs) 8000 250))
$sy = if ($cl2) { Sync-Check $cl2 $cl2.lapStartOffset $cl2.lapStartMs $base4b } else { @{ ok = $false; best = 999; mapErr = 999 } }
Check "and the frame at its lapStartOffset shows the lap start (nearest frame $([math]::Round($sy.best, 1)) ms away)" $sy.ok
Check 'the lap counter jumping from 3 to 5 is reported ("dropped"), not swallowed' (@($lg | Where-Object { $_ -match 'recorder: lap 3 dropped \(the lap counter went from 3 to 5' }).Count -eq 1)
Check 'a tow forward is not a fair lap: lap 5 is reported as reset or tow' (@($lg | Where-Object { $_ -match 'recorder: lap 5 .* not clean \(reset or tow\)' }).Count -eq 1)
Check 'lap 6 is cut' (@($s.clipList | Where-Object { $_.lap -eq 6 }).Count -eq 1)
Fake @{ IsOnTrack = 0 }
$null = Wait-For { -not (St).running } 15
$null = J '/vault/test/rec?cmd=off'
}

# =====================================================================================================
if (Want 6) {
Section '6. /vault/video: Range, 404, and a real browser seeking'
$s = St
if (-not (@($s.clipList).Count)) { $null = J '/vault/test/rec?cmd=reindex'; $s = St }
if (-not (@($s.clipList).Count) -and (Test-Path (Join-Path $tmp 'clip-l3.mp4'))) { Note 'clips from section 4 are not in the scratch vault (section 4 not run); using the saved copy' }
$c = @($s.clipList | Where-Object { $_.lap -eq 3 })[0]
if (-not $c) { $c = @($s.clipList)[0] }
if ($c) {
  $f = Lap-Clip $c; $len = (Get-Item $f).Length; $id = $c.id
  $full = Http "/vault/video?id=$id"
  Check "GET /vault/video?id=<clip> answers 200 with the whole file ($len bytes) and says it accepts ranges" ($full.code -eq 200 -and $full.bytes.Length -eq $len -and $full.headers['Accept-Ranges'] -eq 'bytes' -and $full.headers['Content-Type'] -eq 'video/mp4')
  $disk = [IO.File]::ReadAllBytes($f); $same = $true; if ($disk.Length -eq $full.bytes.Length) { for ($i = 0; $i -lt $disk.Length; $i += 997) { if ($disk[$i] -ne $full.bytes[$i]) { $same = $false; break } } } else { $same = $false }
  Check 'and it is the file itself, byte for byte' $same
  $r1 = Http "/vault/video?id=$id" 0 99
  Check 'Range bytes=0-99 answers 206 with exactly 100 bytes and the right Content-Range' ($r1.code -eq 206 -and $r1.bytes.Length -eq 100 -and $r1.headers['Content-Range'] -eq "bytes 0-99/$len")
  $mid = [int64]($len / 2); $r2 = Http "/vault/video?id=$id" $mid $null
  Check 'Range bytes=<middle>- (what a seeking player sends) answers 206 with the rest of the file' ($r2.code -eq 206 -and $r2.bytes.Length -eq ($len - $mid) -and $r2.headers['Content-Range'] -eq "bytes $mid-$($len - 1)/$len")
  $r2ok = $true; for ($i = 0; $i -lt 200; $i++) { if ($r2.bytes[$i] -ne $disk[$mid + $i]) { $r2ok = $false } }
  Check 'and those bytes are the bytes at that place in the file' $r2ok
  $r3 = Http "/vault/video?id=$id" $null $null 500
  Check 'Range bytes=-500 (the last 500 bytes, where an mp4 without faststart keeps its index) answers 206 with 500 bytes' ($r3.code -eq 206 -and $r3.bytes.Length -eq 500 -and $r3.headers['Content-Range'] -eq "bytes $($len - 500)-$($len - 1)/$len")
  $r4 = Http "/vault/video?id=$id" ($len + 10) ($len + 20)
  Check 'a range beyond the end answers 416' ($r4.code -eq 416)
  Check 'an unknown clip id answers 404' ((Http '/vault/video?id=rec-20200101-000000-l1').code -eq 404)
  Check 'a lap id that has no clip answers 404' ((Http '/vault/video?id=l20200101-000000-4').code -eq 404)
  Check 'a bad id (path tricks, empty) answers 404, never a file' ((Http '/vault/video?id=..%2f..%2fdash%2firdash.ini').code -eq 404 -and (Http '/vault/video').code -eq 404 -and (Http '/vault/video?id=rec-20200101-000000-l1.mp4').code -eq 404)
  $vi = J "/vault/videoinfo?id=$id"
  Check '/vault/videoinfo gives the sidecar: lap, offsets and the clip start time' ($vi.id -eq $id -and $vi.lap -eq $c.lap -and (Near $vi.lapStartOffset $c.lapStartOffset 0.0001) -and $vi.rotation -eq 180 -and $vi.fps -eq 60)
  Check '/vault/videoinfo answers 404 for no clip' ((Http '/vault/videoinfo?id=nothing-here').code -eq 404)
  if (Test-Path $chrome) {
    $s = St
    Cdp-Open "$api/vault/recorder"
    $null = Cdp-Eval "document.body.innerHTML = ''; 1"
    $js = @"
(async function(){
  var v = document.createElement('video'); v.muted = true; v.preload = 'auto'; v.src = '/vault/video?id=$id'; v.style.width = '640px'; document.body.appendChild(v);
  await new Promise(function(res, rej){ v.onloadeddata = res; v.onerror = function(){ rej('video error ' + (v.error && v.error.code)); }; setTimeout(function(){ rej('timeout'); }, 20000); });
  var out = { w: v.videoWidth, h: v.videoHeight, d: v.duration };
  function bits(){ var c = document.createElement('canvas'); c.width = 1280; c.height = 720; var x = c.getContext('2d'); x.drawImage(v, 0, 0, 1280, 720); var px = x.getImageData(0, 16, 640, 1).data; var ms = 0; for (var i = 0; i < 32; i++) { if (px[(i * 20 + 10) * 4] > 128) ms += Math.pow(2, i); } return ms; }
  out.t0 = v.currentTime; out.ms0 = bits();
  v.currentTime = $([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.000}', $c.lapStartOffset));
  await new Promise(function(res){ v.onseeked = res; setTimeout(res, 15000); });
  out.t1 = v.currentTime; out.ms1 = bits();
  return JSON.stringify(out);
})()
"@
    $res = Cdp-Eval $js
    $o = $null; try { $o = $res | ConvertFrom-Json } catch { }
    if ($o) {
      Note "Chrome: $($o.w)x$($o.h), $([math]::Round($o.d, 2)) s, first frame clock $($o.ms0) ms, after the seek to $([math]::Round($o.t1, 3)) s clock $($o.ms1) ms"
      $expClip0 = ([double]$c.clipStartMs - [double]$s.baseMs) + ($o.t0 - [double]$c.videoStart) * 1000
      $expSeek = ([double]$c.clipStartMs - [double]$s.baseMs) + ($o.t1 - [double]$c.videoStart) * 1000
      Check 'Chrome plays the clip from /vault/video and sees it upright (it honours the rotation flag: the clock in the top-left corner can be read)' ($o.w -eq 1280 -and $o.h -eq 720 -and (Near $o.ms0 $expClip0 40))
      Check "Chrome seeks (Range requests): after seeking to the lap start the frame shows the lap start ($([math]::Round($o.ms1 - ($c.lapStartMs - [double]$s.baseMs), 1)) ms off)" ((Near $o.ms1 $expSeek 40) -and (Near $o.ms1 ($c.lapStartMs - [double]$s.baseMs) 40))
      $null = Cdp-Eval "document.querySelector('video').style.cssText='width:1280px'; 1"
      $sh = Cdp 'Page.captureScreenshot' @{ format = 'png' }
      [IO.File]::WriteAllBytes((Join-Path $shots 'rec-browser-seek.png'), [Convert]::FromBase64String($sh.result.data))
    } else { Check "Chrome could play the clip ($res)" $false }
    Cdp-Close
  } else { Note 'Chrome is not installed here: the browser part is skipped' }
} else { Check 'there is a clip to serve (run section 4 first)' $false }
}

# =====================================================================================================
if (Want 7) {
Section '7. a Vault lap finds its own clip (by car, track, lap and when it was driven)'
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$f1 = 'chevyvettez06rgt3_roadatlanta full 2026-10-06 21-20-59.ibt'
$srcDir = Join-Path $tdir 'src'
if (Test-Path (Join-Path $tel $f1)) {
  Copy-Item (Join-Path $tel $f1) (Join-Path $srcDir $f1) -Force; (Get-Item (Join-Path $srcDir $f1)).LastWriteTime = (Get-Item (Join-Path $tel $f1)).LastWriteTime
  $null = J '/vault/test/scan'; $lst = J '/vault/list'
  $laps = @($lst.moments | Where-Object { $_.kind -eq 'lap' -and $_.lap -gt 0 -and $_.lapTime -gt 0 })
  $m = $laps[0]
  if ($m) {
    $s = St
    $src = @($s.clipList)[0]
    if (-not $src) { $null = J '/vault/test/rec?cmd=reindex'; $src = @((St).clipList)[0] }
    if ($src) {
      # a clip of that lap: the same file and sidecar under a new id, with the lap's car, track, lap number and a start time inside the session
      $newId = "rec-20261006-212300-l$($m.lap)"
      Copy-Item (Lap-Clip $src) (Join-Path $clipDir "$newId.mp4") -Force
      $j = Get-Content ((Lap-Clip $src) -replace '\.mp4$', '.json') -Raw | ConvertFrom-Json
      $j.id = $newId; $j.car = $m.car; $j.track = $m.track; $j.config = $m.config; $j.lap = [int]$m.lap; $j.lapTime = [double]$m.lapTime; $j.lapStartMs = [double]$m.startMs + 60000; $j.keep = $false; $j.created = (NowMs)
      ($j | ConvertTo-Json -Compress) | Set-Content (Join-Path $clipDir "$newId.json") -Encoding UTF8
      $ri = J '/vault/test/rec?cmd=reindex'
      Check 'a new clip with that lap''s car, track, lap number and time inside its session is picked up (reindex)' ($ri.ok -eq $true)
      $v1 = Http "/vault/video?id=$($m.id)"
      Check "/vault/video?id=<the Vault's lap id $($m.id)> serves that lap's clip" ($v1.code -eq 200 -and $v1.bytes.Length -eq (Get-Item (Join-Path $clipDir "$newId.mp4")).Length)
      $vi = J "/vault/videoinfo?id=$($m.id)"
      Check '/vault/videoinfo on the lap id gives the same sidecar' ($vi.id -eq $newId -and $vi.lap -eq $m.lap)
      $other = @($laps | Where-Object { $_.lap -ne $m.lap -and [math]::Abs($_.lapTime - $m.lapTime) -gt 0.5 })[0]
      if ($other) { Check 'another lap of the same session (other lap number, other time) has no clip: 404' ((Http "/vault/video?id=$($other.id)").code -eq 404) }
      Remove-Item (Join-Path $clipDir "$newId.mp4"), (Join-Path $clipDir "$newId.json") -Force; $null = J '/vault/test/rec?cmd=reindex'
    } else { Note 'no clip to copy (section 4 not run): the lap link is not tested' }
  } else { Note 'no lap moment in the scratch vault' }
} else { Note "telemetry file $f1 is not on this PC: the lap link is not tested" }
}

# =====================================================================================================
if (Want 8) {
Section '8. a black picture is noticed and said in plain words'
$l0 = @(Get-Content $logFile).Count
$null = J '/vault/test/rec?cmd=on&black=1&seg=5&grace=3&minlap=3'
Fake @{ IsOnTrack = 1; Lap = 1; LapDistPct = 0.003; LapCurrentLapTime = 0.0; LapLastLapTime = 0.0; OnPitRoad = 0; PlayerTrackSurface = 3; SessionNum = 0; SessionTime = 100.0 }
$ok = Wait-For { $q = St; $q.blackChecked -eq $true -or $q.black -eq $true } 40
$s = St
Check 'a black screen is detected in the first segment' ($ok -and $s.black -eq $true)
Check 'the status says so for the Rig Doctor' ($s.note -match 'black')
Check 'irdash.log says what to change in plain English (exclusive full screen, choose Windowed or Borderless)' (@(Log-Since $l0 | Where-Object { $_ -match 'recorder: the recording is BLACK.*full-screen exclusive.*Windowed or Borderless' }).Count -eq 1)
Fake @{ IsOnTrack = 0 }
$null = Wait-For { -not (St).running } 15
$null = J '/vault/test/rec?cmd=off'
}

# =====================================================================================================
if (Want 9) {
Section '9. ffmpeg dies: restarted at most 3 times, then it gives up; the sim closing stops it'
$l0 = @(Get-Content $logFile).Count
$inCar = @{ IsOnTrack = 1; Lap = 1; LapDistPct = 0.003; LapCurrentLapTime = 0.0; LapLastLapTime = 0.0; OnPitRoad = 0; PlayerTrackSurface = 3; SessionNum = 0; SessionTime = 100.0 }
$null = J '/vault/test/rec?cmd=on&seg=5&grace=30&minlap=3'
Fake $inCar
$ok = Wait-For { (St).running } 10
Check 'the recorder is running' $ok
# the sim exits (grace is 30 s, so only "the sim closed" can stop it this fast)
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
$ok = Wait-For { -not (St).running } 12
Check 'when the sim exits ffmpeg stops at once, not after the grace time' $ok
Check 'and the log says so' (@(Log-Since $l0 | Where-Object { $_ -match 'recorder: stopping \(the sim closed\)' }).Count -ge 1)
Fake $inCar
$ok = Wait-For { (St).running } 12
Check 'a new session starts it again' $ok
for ($k = 1; $k -le 4; $k++) {
  $s = St
  if ($k -le 3) {
    $runBefore = $s.run
    try { Stop-Process -Id $s.ffmpegPid -Force } catch { }
    $ok = Wait-For { $q = St; $q.running -and $q.run -gt $runBefore } 12
    Check "kill $k : ffmpeg is started again by itself (restart $k of 3)" ($ok -and (St).restarts -eq $k)
  } else {
    try { Stop-Process -Id $s.ffmpegPid -Force } catch { }
    $ok = Wait-For { $q = St; $q.gaveUp -eq $true } 10
    Start-Sleep -Seconds 4
    Check 'kill 4 : it does not start again (gives up for this session)' ($ok -and (St).running -eq $false -and (St).gaveUp -eq $true)
  }
}
$lg = Log-Since $l0
Check 'the log has each restart ("restart 1 of 3" ... "restart 3 of 3") and then the give-up in plain words' (@($lg | Where-Object { $_ -match 'starting it again, restart 1 of 3' }).Count -eq 1 -and @($lg | Where-Object { $_ -match 'restart 3 of 3' }).Count -eq 1 -and @($lg | Where-Object { $_ -match 'recorder: ffmpeg keeps stopping .*giving up until the next session' }).Count -eq 1)
# "until the next session": the sim closes and opens again
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
Start-Sleep -Seconds 1
Fake $inCar
$ok = Wait-For { $q = St; $q.running -and $q.gaveUp -eq $false -and $q.restarts -eq 0 } 12
Check 'the next session starts with a clean slate: it records again' $ok
Fake @{ IsOnTrack = 0 }
$null = J '/vault/test/rec?cmd=off'
$null = Wait-For { @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" | Where-Object { $_.CommandLine -like '*vault-test*' }).Count -eq 0 } 10
Check 'no ffmpeg of the recorder is left running' (@(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" | Where-Object { $_.CommandLine -like '*vault-test*' }).Count -eq 0)
}
# =====================================================================================================
if (Want 10) {
$idle = [RigGuard]::IdleMinutes()
if ($idle -lt 10) {
  Section '10. the real middle screen (skipped)'
  Note "skipped: Peter used the PC $([math]::Round($idle, 1)) minutes ago. This section films the real screen for a minute (screen capture only); the lead runs it when he is away."
} else {
Assert-RigFree -NeedAway -Where '10. the real middle screen'
'10. the real middle screen (screen capture only: no clicks, keys or focus changes)'
[RecTool]::WakeDisplays(); Start-Sleep -Seconds 2
$l0 = @(Get-Content $logFile).Count
$map = J '/vault/test/recmap'; $mid = $map.middle
# 10a. which output is which monitor, proved by the pictures: one frame from every output against a Windows screenshot of every screen
$caps = @{}
foreach ($o in $map.outputs) {
  $png = Join-Path $tmp "out$($o.index).png"
  $r = Tool $ffmpeg ("-v error -y -filter_complex `"ddagrab=output_idx=$($o.index):framerate=10:draw_mouse=0,hwdownload,format=bgra`" -frames:v 1 `"$png`"") 20000
  if ((Test-Path $png) -and $r.Code -eq 0) { $caps[$o.index] = $png }
}
$gdi = @{}; $i = 0
foreach ($sc in [Windows.Forms.Screen]::AllScreens) { $png = Join-Path $tmp "gdi$i.png"; [RecTool]::Shot($png, $sc.Bounds.X, $sc.Bounds.Y, $sc.Bounds.Width, $sc.Bounds.Height); $gdi[$i] = @{ png = $png; sc = $sc }; $i++ }
Check "one frame was grabbed from every output ($($caps.Count) of $(@($map.outputs).Count))" ($caps.Count -eq @($map.outputs).Count)
$mapOk = $true
foreach ($o in $map.outputs) {
  if (-not $caps.ContainsKey($o.index)) { continue }
  $bestK = -1; $bestD = 1e9; $ds = @()
  foreach ($k in $gdi.Keys) { $sc = $gdi[$k].sc; if ($sc.Bounds.Width -ne $o.w -or $sc.Bounds.Height -ne $o.h) { continue }; $d = [RecTool]::Diff($gdi[$k].png, $caps[$o.index], ($o.rotation -eq 3)); $ds += $d; if ($d -lt $bestD) { $bestD = $d; $bestK = $k } }
  $match = $gdi[$bestK].sc.Bounds
  $byPos = ($match.X -eq $o.x -and $match.Y -eq $o.y)
  Note ("output $($o.index) ($($o.x),$($o.y)): picture best matches the screen at $($match.X),$($match.Y) (difference $([math]::Round($bestD, 1)) of 255; by position: $byPos)")
  if ($o.index -eq $mid.index) { Check "the middle output's picture is the picture of the middle screen, not a side screen (difference $([math]::Round($bestD, 1)))" ($byPos -and $bestD -lt 25); if ($caps[$o.index]) { Copy-Item $caps[$o.index] (Join-Path $shots 'rec-real-output-raw.png') } }
}
# 10b. the recorder itself on the real screen (the pretend session only says "in the car"): 25 s, with a lap handed in so a clip is cut
$null = J '/vault/test/rec?cmd=on&source=screen&seg=5&keep=40&grace=2&minlap=1'
$fgR = [RecTool]::GetForegroundWindow()
Fake @{ IsOnTrack = 1; Lap = 1; LapDistPct = 0.003; LapCurrentLapTime = 0.0; LapLastLapTime = 0.0; OnPitRoad = 0; PlayerTrackSurface = 3; SessionNum = 0; SessionTime = 100.0 }
$ok = Wait-For { $q = St; $q.running -and @($q.segList).Count -ge 1 } 40
$null = Wait-For { (St).blackChecked -eq $true } 20
$s = St
Check "the recorder films the real screen: output $($s.outputIdx) at $($s.outputRect), segments are being written" ($ok -and $s.source -eq 'screen' -and ($s.encoderUsed -eq 'hevc_nvenc' -or $s.encoderUsed -eq 'h264_nvenc'))
$hwEnc = $s.encoderUsed
Check "the NVIDIA hardware encoder is used (HEVC first, h264 if it refuses; got $hwEnc)" (($hwEnc -eq 'hevc_nvenc' -or $hwEnc -eq 'h264_nvenc') -and $s.lastRunArgs -match $hwEnc -and $s.lastRunArgs -match 'ddagrab=output_idx=' + $mid.index)
Check 'the real screen is not black (picture check on the first segment)' ($s.blackChecked -eq $true -and $s.black -eq $false)
$pf = Get-Process -Id $s.ffmpegPid -ErrorAction SilentlyContinue
# the cost: GPU and encoder load from nvidia-smi, ffmpeg's CPU time, for 8 s of recording
$gpu = @(); $enc = @(); $cpu0 = if ($pf) { $pf.TotalProcessorTime.TotalSeconds } else { 0 }; $tc0 = Get-Date
for ($i = 0; $i -lt 8; $i++) { $o = (& nvidia-smi --query-gpu=utilization.gpu,utilization.encoder --format=csv,noheader,nounits 2>$null); if ($o) { $p = $o.Split(','); $gpu += [double]$p[0]; $enc += [double]$p[1] }; Start-Sleep -Milliseconds 900 }
$pf = Get-Process -Id $s.ffmpegPid -ErrorAction SilentlyContinue
$cpuPct = if ($pf) { ($pf.TotalProcessorTime.TotalSeconds - $cpu0) / ((Get-Date) - $tc0).TotalSeconds * 100 } else { -1 }
$cpuAll = [Environment]::ProcessorCount
Note ("cost of the NVENC recorder on a mostly still desktop: ffmpeg " + [math]::Round($cpuPct, 1) + " % of one core (of $cpuAll logical cores), GPU " + [math]::Round(($gpu | Measure-Object -Average).Average, 1) + " % (max " + ($gpu | Measure-Object -Maximum).Maximum + "), video encoder " + [math]::Round(($enc | Measure-Object -Average).Average, 1) + " % (max " + ($enc | Measure-Object -Maximum).Maximum + ")")
Check 'ffmpeg uses very little CPU with the hardware encoder (under 25 % of one core on a still desktop)' ($cpuPct -ge 0 -and $cpuPct -lt 25)
Check 'recording the screen did not change the foreground window (no focus change)' ([RecTool]::GetForegroundWindow() -eq $fgR -and $fgR -eq $fgBefore)
# a Windows screenshot of the same screen, taken now, and a lap that covers that moment
$shotMs = NowMs; [RecTool]::Shot((Join-Path $shots 'rec-real-gdi.png'), $mid.x, $mid.y, $mid.w, $mid.h)
Start-Sleep -Seconds 3
$rr = J ("/vault/test/rec?cmd=lap&n=7&start=$($shotMs - 3000)&end=$($shotMs + 1800)&time=4.8")
$null = Wait-For { $q = St; $q.pendingCuts -eq 0 -and $q.busy -eq 0 -and @($q.clipList | Where-Object { $_.lap -eq 7 }).Count -eq 1 } 40
$s = St; $c = @($s.clipList | Where-Object { $_.lap -eq 7 })[0]
Check 'a clip of the real screen was cut' ($c -ne $null)
if ($c) {
  $f = Lap-Clip $c
  $info = (Probe "-v error -show_streams -show_format -of json `"$f`"") | ConvertFrom-Json; $vs = $info.streams | Where-Object { $_.codec_type -eq 'video' }
  $codecOK = ($vs.codec_name -eq 'hevc' -and $hwEnc -eq 'hevc_nvenc') -or ($vs.codec_name -eq 'h264' -and $hwEnc -eq 'h264_nvenc')
  Check "the clip is 2560x1440 and matches the encoder ($($vs.codec_name) for $hwEnc)" ($vs.width -eq 2560 -and $vs.height -eq 1440 -and $codecOK)
  if ($hwEnc -eq 'hevc_nvenc') { Check 'the HEVC clip carries the hvc1 tag (Safari and iPhones need it)' ($vs.codec_tag_string -eq 'hvc1') }
  $rot = (Probe "-v error -select_streams v:0 -show_entries stream_side_data=rotation -of default=nw=1:nk=1 `"$f`"").Trim()
  Check "the rotation flag is 180 degrees ($rot): the screen is upside down in ddagrab's picture and the flag turns it upright with no CPU" ($rot -match '^-?180')
  $fps = [double]$vs.nb_frames / [double]$info.format.duration
  Note ("clip: $([math]::Round([double]$info.format.duration, 2)) s, $($vs.nb_frames) frames ($([math]::Round($fps, 1)) a second), $([math]::Round([double]$info.format.bit_rate / 1e6, 1)) Mbit/s, lap start $([math]::Round($c.lapStartOffset, 2)) s into it")
  Check 'about 60 frames a second' ($fps -ge 40 -and $fps -le 66)
  $kfs = @((Probe "-v error -select_streams v:0 -show_entries packet=flags -of csv=p=0 `"$f`"").Split("`n") | Where-Object { $_ -match 'K' }).Count
  Check "a keyframe about every second ($kfs in $([math]::Round([double]$info.format.duration, 1)) s)" ($kfs -ge [math]::Floor([double]$info.format.duration) - 1 -and $kfs -le [math]::Ceiling([double]$info.format.duration) * 2)
  # the frame at the moment of the Windows screenshot, with the flag applied and without it
  $tAt = ($shotMs - [double]$c.clipStartMs) / 1000.0 + [double]$c.videoStart
  $up = Join-Path $shots 'rec-real-frame.png'; $raw = Join-Path $tmp 'raw.png'
  $null = Tool $ffmpeg ("-v error -y -ss " + ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.000}', $tAt)) + " -i `"$f`" -frames:v 1 `"$up`"") 30000
  $null = Tool $ffmpeg ("-v error -y -noautorotate -ss " + ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.000}', $tAt)) + " -i `"$f`" -frames:v 1 `"$raw`"") 30000
  $gd = Join-Path $shots 'rec-real-gdi.png'
  $dUp = [RecTool]::Diff($gd, $up, $false); $dRaw = [RecTool]::Diff($gd, $raw, $false); $dTurn = [RecTool]::Diff($gd, $raw, $true)
  Note ("difference from the Windows screenshot (0 = identical, 255 = opposite): upright frame $([math]::Round($dUp, 1)), frame without the flag $([math]::Round($dRaw, 1)), that frame turned by hand $([math]::Round($dTurn, 1))")
  Check 'the clip''s picture is upright: it matches the Windows screenshot of the same screen and the same moment' ($dUp -lt 15 -and $dUp -lt $dRaw * 0.6)
  Check 'without the rotation flag the same frame is upside down (so the flag is what makes it right, at no CPU cost)' ($dRaw -gt $dUp * 1.5 -and $dTurn -lt 15)
  $st = [RecTool]::Stats($up)
  Check "the picture is not black (average brightness $([math]::Round($st[0], 0)), brightest $([math]::Round($st[1], 0)) of 255)" ($st[0] -gt 8 -and $st[1] -gt 60)
  $sz = New-Object Drawing.Bitmap $up; Check "the grabbed frame is 2560x1440" ($sz.Width -eq 2560 -and $sz.Height -eq 1440); $sz.Dispose()
  # one picture for the lead to look at: the Windows screenshot, the upright frame and the raw frame side by side
  $a = New-Object Drawing.Bitmap $gd; $b = New-Object Drawing.Bitmap $up; $d = New-Object Drawing.Bitmap $raw
  $sheet = New-Object Drawing.Bitmap 1920, 360; $g = [Drawing.Graphics]::FromImage($sheet); $g.Clear([Drawing.Color]::Black); $g.InterpolationMode = 'HighQualityBicubic'
  $g.DrawImage($a, 0, 0, 640, 360); $g.DrawImage($b, 640, 0, 640, 360); $g.DrawImage($d, 1280, 0, 640, 360)
  $fnt = New-Object Drawing.Font 'Segoe UI', 14, ([Drawing.FontStyle]::Bold); $br = [Drawing.Brushes]::Gold
  $g.DrawString('Windows screenshot', $fnt, $br, 8, 4); $g.DrawString('clip frame, rotation flag applied', $fnt, $br, 648, 4); $g.DrawString('same frame without the flag', $fnt, $br, 1288, 4)
  $sheet.Save((Join-Path $shots 'rec-real-compare.png')); $g.Dispose(); $sheet.Dispose(); $a.Dispose(); $b.Dispose(); $d.Dispose()
  Check 'the sync offset on the real clip: the frame at lapStartOffset is the lap start (the sidecar says where; the clock is the wall clock)' ($c.lapStartOffset -ge 0.9 -and $c.lapStartOffset -le 3.1 -and (Near $c.lapStartMs ($shotMs - 3000) 1))
}
$ok = $true
Fake @{ IsOnTrack = 0 }
$null = Wait-For { -not (St).running } 15
# 10c. the CPU fallback (libx264) also records, with its cost
$null = J '/vault/test/rec?cmd=on&source=screen&enc=libx264&seg=5&grace=2&minlap=1'
Fake @{ IsOnTrack = 1; Lap = 1; LapDistPct = 0.003; LapCurrentLapTime = 0.0; LapLastLapTime = 0.0; OnPitRoad = 0; PlayerTrackSurface = 3; SessionNum = 0; SessionTime = 100.0 }
$ok = Wait-For { $q = St; $q.running -and @($q.segList).Count -ge 1 } 40
$s = St; $pf = Get-Process -Id $s.ffmpegPid -ErrorAction SilentlyContinue
$cpu0 = if ($pf) { $pf.TotalProcessorTime.TotalSeconds } else { 0 }; $tc0 = Get-Date; Start-Sleep -Seconds 5
$pf = Get-Process -Id $s.ffmpegPid -ErrorAction SilentlyContinue
$cpuPct2 = if ($pf) { ($pf.TotalProcessorTime.TotalSeconds - $cpu0) / ((Get-Date) - $tc0).TotalSeconds * 100 } else { -1 }
Note ("cost of the libx264 fallback (veryfast, 1440p60) on a mostly still desktop: ffmpeg " + [math]::Round($cpuPct2, 0) + " % of one core")
Check 'the libx264 fallback also films the real screen (a segment was written with the CPU encoder)' ($ok -and $s.encoderUsed -eq 'libx264' -and @($s.segList).Count -ge 1)
if (@($s.segList).Count) { $g0 = @($s.segList)[0]; Check 'and that segment decodes cleanly' ((Decode-Errors (Join-Path $recDir $g0.name)).Count -eq 0) }
Fake @{ IsOnTrack = 0 }
$null = Wait-For { -not (St).running } 15
$null = J '/vault/test/rec?cmd=off'
Check 'no ffmpeg of the recorder is left running' (@(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" | Where-Object { $_.CommandLine -like '*vault-test*' }).Count -eq 0)
}
}

# =====================================================================================================
if (Want 11) {
Section '11. one session (two stints) -> one file; laps with offsets; the .ts files gone'
$null = J '/vault/test/rec?cmd=on&keep=120&seg=5&grace=2&minlap=3'
$null = J '/vault/test/yaml'
Fake @{ IsOnTrack = 1; SessionUniqueID = 701; SessionNum = 0; Lap = 1; LapDistPct = 0.5; LapCurrentLapTime = 5.0; LapLastLapTime = 0.0; OnPitRoad = 0; PlayerTrackSurface = 3; SessionTime = 100.0; PlayerCarMyIncidentCount = 0 }
$stintWatch = [Diagnostics.Stopwatch]::StartNew()
$ok = Wait-For { (St).running } 12
Check 'the recorder runs in the session' $ok
Start-Sleep -Seconds 10
$lapStart = NowMs - 5000
$null = J ("/vault/test/rec?cmd=lap&n=1&start=$lapStart&end=$($lapStart + 5000)&time=6.000")
$os = @((J '/api/rec/sessions').sessions | Where-Object { $_.open -eq $true })
Check 'the open session is listed with its id and no SAVE yet' ($os.Count -eq 1 -and $os[0].id -and $os[0].saveWhenDone -eq $false)
$sid = if ($os.Count -eq 1) { $os[0].id } else { '' }
Start-Sleep -Seconds 8
$stintWatch.Stop(); $recordedSeconds = $stintWatch.Elapsed.TotalSeconds
Fake @{ IsOnTrack = 0 }
$ok = Wait-For { -not (St).running } 12
Check 'leaving the car stops the video but keeps the session open' ($ok -and (St).session -eq $sid)
Start-Sleep -Seconds 3
$stintWatch = [Diagnostics.Stopwatch]::StartNew()
Fake @{ IsOnTrack = 1; SessionUniqueID = 701; SessionNum = 0 }
$ok = Wait-For { (St).running } 12
Check 'getting back in the car records into the same session' ($ok -and (St).session -eq $sid)
Start-Sleep -Seconds 14
$stintWatch.Stop(); $recordedSeconds += $stintWatch.Elapsed.TotalSeconds
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
$ok = Wait-For { Test-Path (Join-Path $sessDir ($sid + '.mp4')) } 45
Check 'when the sim closes the session is written as one file' $ok
Check 'the sessions list shows it finished' (@((J '/api/rec/sessions').sessions | Where-Object { $_.id -eq $sid -and $_.open -eq $false }).Count -eq 1)
$mp4 = Join-Path $sessDir ($sid + '.mp4'); $json = Join-Path $sessDir ($sid + '.json')
Check 'the session mp4 and its sidecar are on disk' ((Test-Path $mp4) -and (Test-Path $json))
$side = Get-Content $json -Raw | ConvertFrom-Json
$dur = [double]((Probe "-v error -show_entries format=duration -of default=nw=1:nk=1 `"$mp4`"").Trim())
Check "ffprobe duration matches measured in-car time ($([math]::Round($dur,1)) s recorded $([math]::Round($recordedSeconds,1)) s)" ((Near $dur $recordedSeconds 2.5) -and (Near $dur $side.durationSec 2.5))
Check "the sidecar names the track, car and session type ($($side.track) / $($side.sessionType))" ($side.track -eq 'Road Atlanta' -and $side.sessionType -eq 'Practice')
Check 'the .ts files of the session are gone' (@(Get-ChildItem $recDir -Filter *.ts -ErrorAction SilentlyContinue).Count -eq 0)
$lr = @($side.laps)
$expOff = ($lapStart - [double]$side.startMs) / 1000.0
Check "the sidecar has the lap with the right offset ($([math]::Round($lr[0].offset,1)) s, expected about $([math]::Round($expOff,1)) s)" ($lr.Count -eq 1 -and $lr[0].n -eq 1 -and (Near $lr[0].offset $expOff 2.0) -and $lr[0].clean -eq $true)
$null = J '/vault/test/rec?cmd=off'
}

# =====================================================================================================
if (Want 12) {
Section '12. an incident bump cuts a ~30 s clip and lands in the session sidecar'
$null = J '/vault/test/rec?cmd=on&keep=120&seg=5&grace=2&minlap=3'
$null = J '/vault/test/yaml'
Fake @{ IsOnTrack = 1; SessionUniqueID = 702; SessionNum = 0; PlayerCarMyIncidentCount = 0; SessionTime = 100.0 }
$ok = Wait-For { (St).running } 12
Check 'the recorder runs' $ok
Start-Sleep -Seconds 24
$sid = (St).session
Fake @{ PlayerCarMyIncidentCount = 1 }
$ok = Wait-For { @(Get-ChildItem $clipDir -Filter 'inc-*.mp4' -ErrorAction SilentlyContinue).Count -ge 1 } 45
Check 'the incident makes a clip' $ok
if ($ok) {
  $inc = @(Get-ChildItem $clipDir -Filter 'inc-*.mp4' | Sort-Object LastWriteTime)[-1]
  $idur = [double]((Probe "-v error -show_entries format=duration -of default=nw=1:nk=1 `"$($inc.FullName)`"").Trim())
  Check "the incident clip is about 30 s (20 before, 10 after; got $([math]::Round($idur,1)) s)" ($idur -ge 20 -and $idur -le 34)
  $ij = Get-Content ($inc.FullName -replace '\.mp4$', '.json') -Raw | ConvertFrom-Json
  Check 'its sidecar says incident, one point and the session id' ($ij.kind -eq 'incident' -and $ij.points -eq 1 -and $ij.session -eq $sid)
}
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
$null = Wait-For { Test-Path (Join-Path $sessDir ($sid + '.json')) } 45
$sj = Get-Content (Join-Path $sessDir ($sid + '.json')) -Raw | ConvertFrom-Json
Check 'the session sidecar lists the incident' (@($sj.incidents).Count -ge 1 -and $sj.incidents[0].count -eq 1)
$null = J '/vault/test/rec?cmd=off'
}

# =====================================================================================================
if (Want 13) {
Section '13. SAVE during the session keeps it; a second SAVE is a no-op; the deck key works'
$null = J '/vault/test/rec?cmd=on&keep=120&seg=5&grace=2&minlap=3'
$null = J '/vault/test/yaml'
Fake @{ IsOnTrack = 1; SessionUniqueID = 703; SessionNum = 0; PlayerCarMyIncidentCount = 0; SessionTime = 100.0 }
$ok = Wait-For { (St).running } 12
Check 'the recorder runs' $ok
Start-Sleep -Seconds 8
$sid = (St).session
$r1 = Invoke-WebRequest -UseBasicParsing "$api/api/rec/save" -Method POST -TimeoutSec 20
$s1 = ([Text.Encoding]::UTF8.GetString($r1.RawContentStream.ToArray()) | ConvertFrom-Json).state
Check 'SAVE during the session answers SAVING' ($s1 -eq 'SAVING')
Check 'the open session remembers the SAVE' ((St).saveWhenDone -eq $true)
$dr = Invoke-WebRequest -UseBasicParsing "$api/api/do?c=recsave" -TimeoutSec 20
Check 'the deck command recsave is accepted' ($dr.StatusCode -eq 200)
Start-Sleep -Seconds 10
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
$ok = Wait-For { Test-Path (Join-Path $savedDir ($sid + '.mp4')) } 45
Check 'after the session the video is in vault\saved' $ok
Check 'and it is no longer in vault\sessions' (-not (Test-Path (Join-Path $sessDir ($sid + '.mp4'))))
$sj = Get-Content (Join-Path $savedDir ($sid + '.json')) -Raw | ConvertFrom-Json
Check 'its sidecar says saved' ($sj.saved -eq $true)
$r2 = Invoke-WebRequest -UseBasicParsing "$api/api/rec/save?id=$sid" -Method POST -TimeoutSec 20
$s2 = ([Text.Encoding]::UTF8.GetString($r2.RawContentStream.ToArray()) | ConvertFrom-Json).state
Check 'a second SAVE is a no-op that still answers SAVED' ($s2 -eq 'SAVED')
$null = J '/vault/test/rec?cmd=off'
}

# =====================================================================================================
if (Want 14) {
Section '14. retention: keep the last 3, budgets, SAVED FULL, and a full disk pauses recording'
# Remove only this section's fixtures; a session may still be finishing in the shared sandbox.
New-Item -ItemType Directory -Force $sessDir,$savedDir | Out-Null
$fixtureIds = @('sess-a','sess-b','sess-c','sess-d','sess-saved','sess-overflow')
foreach ($id in $fixtureIds) { foreach ($dir in @($sessDir,$savedDir)) { Remove-Item (Join-Path $dir ($id + '.mp4')),(Join-Path $dir ($id + '.json')) -Force -ErrorAction SilentlyContinue } }
function Fake-Sess($id, $startMs, $bytes, $saved) {
  $mp4 = Join-Path $sessDir ($id + '.mp4'); $jf = Join-Path $sessDir ($id + '.json')
  [IO.File]::WriteAllBytes($mp4, (New-Object byte[] $bytes))
  (@{ id = $id; track = 'Test Track'; config = ''; car = 'Test Car'; sessionType = 'Practice'; startMs = [double]$startMs; durationSec = 10.0; bytes = $bytes; encoder = 'libx264'; saved = [bool]$saved; recovered = $false; created = [double]$startMs; laps = @(); incidents = @() } | ConvertTo-Json -Compress -Depth 5) | Set-Content -Encoding UTF8 $jf
}
$now = NowMs
Fake-Sess 'sess-a' ($now - 40000) 2000000 $false
Fake-Sess 'sess-b' ($now - 30000) 2000000 $false
Fake-Sess 'sess-c' ($now - 20000) 2000000 $false
$null = J '/vault/test/rec?cmd=reload'
$listed = @((J '/vault/test/rec?cmd=sessions').sessions | Where-Object { -not $_.saved -and $_.id -in $fixtureIds })
Check 'three unsaved sessions are listed' ($listed.Count -eq 3 -and @($listed | Where-Object { $_.id -in @('sess-a','sess-b','sess-c') }).Count -eq 3)
Fake-Sess 'sess-d' ($now - 10000) 2000000 $false
$null = J '/vault/test/rec?cmd=reload'
$null = J '/vault/test/rec?cmd=budgets&keep=3'
$s = J '/vault/test/rec?cmd=retain'
Check 'the 4th unsaved session deletes the oldest' ((@($s.sessions | Where-Object { $_.id -eq 'sess-a' }).Count -eq 0) -and (@($s.sessions | Where-Object { $_.id -eq 'sess-d' }).Count -eq 1))
Fake-Sess 'sess-saved' ($now - 50000) 2000 $true
$null = J '/vault/test/rec?cmd=reload'
$null = J '/vault/test/rec?cmd=budgets&keep=10&recent=1500'
$s = J '/vault/test/rec?cmd=retain'
$fixtureSessions = @($s.sessions | Where-Object { $_.id -in $fixtureIds })
Check 'saved MP4 and JSON survive while byte budget prunes unsaved files' ((@($fixtureSessions | Where-Object { $_.id -eq 'sess-saved' }).Count -eq 1) -and (Test-Path (Join-Path $sessDir 'sess-saved.mp4')) -and (Test-Path (Join-Path $sessDir 'sess-saved.json')) -and (@($fixtureSessions | Where-Object { -not $_.saved }).Count -le 1) -and (@(Get-ChildItem $sessDir -Filter 'sess-*.mp4').Count -le 2))
$null = J '/vault/test/rec?cmd=budgets&saved=1500'
$overflowAt = NowMs
Fake-Sess 'sess-overflow' ($overflowAt) 2000000 $false
$null = J '/vault/test/rec?cmd=reload'
$s = J '/vault/test/rec?cmd=sessions'
$sv = J '/vault/test/rec?cmd=save&id=sess-saved'
Check 'SAVE of a session already saved answers SAVED' ($sv.state -eq 'SAVED')
$u = @($s.sessions | Where-Object { $_.id -eq 'sess-overflow' -and -not $_.saved })
if ($u.Count -eq 1) { $sv2 = J ('/vault/test/rec?cmd=save&id=' + $u[0].id); Check 'a SAVE that would pass the saved budget is refused (SAVED FULL)' ($sv2.state -eq 'SAVED FULL') }
else { Check 'a SAVE that would pass the saved budget is refused (SAVED FULL)' $false }
$null = J '/vault/test/rec?cmd=budgets&saved=-1&keep=3&recent=-1'
$null = J '/vault/test/rec?cmd=on&keep=120&seg=5&grace=2&minlap=3'
$null = J '/vault/test/yaml'
Fake @{ IsOnTrack = 1; SessionUniqueID = 704; SessionNum = 0; PlayerCarMyIncidentCount = 0; SessionTime = 100.0 }
$ok = Wait-For { (St).running } 12
Check 'recording runs before the disk fills' $ok
$null = J ('/vault/test/rec?cmd=free&bytes=' + [int64](40 * 1GB))
$ok = Wait-For { $q = St; $q.running -eq $false -and $q.note -match 'Disk nearly full' } 15
Check 'with less than 50 GB free recording pauses with the note' $ok
$null = J '/vault/test/rec?cmd=free&bytes=-1'
$ok = Wait-For { (St).running } 15
Check 'when the space is back recording starts again' $ok
Fake @{ IsOnTrack = 0 }
$null = Wait-For { -not (St).running } 15
$null = J '/vault/test/rec?cmd=off'
}

# =====================================================================================================
if (Want 15) {
Section '15. leftover segments at start become one recovered session'
$seed = Join-Path $tmp 'seg-sample.ts'
if (-not (Test-Path $seed)) {
  $null = J '/vault/test/rec?cmd=on&seg=5&grace=2'
  Fake @{ IsOnTrack = 1; SessionUniqueID = 705; SessionNum = 0; SessionTime = 100.0 }
  $null = Wait-For { $q = St; @($q.segList).Count -ge 1 } 30
  $g = @((St).segList)[0]
  if ($g) { Copy-Item (Join-Path $recDir $g.name) $seed -Force }
  Fake @{ IsOnTrack = 0 }
  $null = Wait-For { -not (St).running } 15
  $null = J '/vault/test/rec?cmd=off'
}
if (Test-Path $seed) {
  if (Test-Path $sessDir) { Remove-Item $sessDir -Recurse -Force }
  New-Item -ItemType Directory -Force $recDir | Out-Null
  New-Item -ItemType Directory -Force $sessDir | Out-Null
  $stamp = [DateTime]::UtcNow.AddMinutes(-5).ToString('yyyyMMdd-HHmmss')
  Copy-Item $seed (Join-Path $recDir ("rec-$stamp-500.ts")) -Force
  $null = J '/vault/test/rec?cmd=reload'
  $null = J ('/vault/test/rec?cmd=free&bytes=' + [int64](40 * 1GB))
  $null = J '/vault/test/rec?cmd=start'
  Check 'low free space at startup leaves leftover segment on disk' (Test-Path (Join-Path $recDir ("rec-$stamp-500.ts")))
  $null = J '/vault/test/rec?cmd=off'
  $null = J '/vault/test/rec?cmd=free&bytes=-1'
  Remove-Item (Join-Path $recDir ("rec-$stamp-500.ts")) -Force -ErrorAction SilentlyContinue
  Copy-Item $seed (Join-Path $recDir ("rec-$stamp-500.ts")) -Force
  $null = J '/vault/test/rec?cmd=reload'
  $rs = J '/vault/test/rec?cmd=start'
  $rec = @($rs.sessions | Where-Object { $_.recovered -eq $true })
  Check 'the leftover segment becomes one recovered session' ($rec.Count -eq 1 -and $rec[0].laps -eq 0)
  Check 'its sidecar says recovered:true with no laps' ((Get-Content (Join-Path $sessDir ($rec[0].id + '.json')) -Raw | ConvertFrom-Json).recovered -eq $true)
  Check 'the leftover .ts is gone' (@(Get-ChildItem $recDir -Filter *.ts -ErrorAction SilentlyContinue).Count -eq 0)
} else { Note 'no source segment available for the salvage test' }
}

# =====================================================================================================
if (Want 16) {
Section '16. /api/rec/session-video serves Range requests'
$all = @((J '/vault/test/rec?cmd=reload').sessions | Where-Object { -not $_.open })
if (-not $all.Count) {
  New-Item -ItemType Directory -Force $sessDir | Out-Null
  $dst = Join-Path $sessDir 'sess-range.mp4'
  $src = @(Get-ChildItem $clipDir -Filter *.mp4 -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($src) { Copy-Item $src.FullName $dst -Force } else { $null = Tool $ffmpeg ("-v error -y -f lavfi -i testsrc=size=320x180:rate=30 -t 2 -c:v libx264 -pix_fmt yuv420p `"$dst`"") }
  if (Test-Path $dst) {
    (@{ id = 'sess-range'; track = 'Test'; car = 'Test'; sessionType = 'Practice'; startMs = [double](NowMs); durationSec = 2.0; bytes = (Get-Item $dst).Length; saved = $false; recovered = $false; created = [double](NowMs); laps = @(); incidents = @() } | ConvertTo-Json -Compress -Depth 5) | Set-Content -Encoding UTF8 (Join-Path $sessDir 'sess-range.json')
    $all = @((J '/vault/test/rec?cmd=reload').sessions | Where-Object { -not $_.open })
  }
}
$one = @($all | Where-Object { $_.id -eq 'sess-range' })[0]; if (-not $one) { $one = $all[-1] }
if ($one) {
  $id = $one.id
  $file = Join-Path $sessDir ($id + '.mp4'); if (-not (Test-Path $file)) { $file = Join-Path $savedDir ($id + '.mp4') }
  $len = (Get-Item $file).Length
  $full = Http "/api/rec/session-video?id=$id"
  Check "GET /api/rec/session-video answers 200 with the whole file ($len bytes) and accepts ranges" ($full.code -eq 200 -and $full.bytes.Length -eq $len -and $full.headers['Accept-Ranges'] -eq 'bytes')
  $rr1 = Http "/api/rec/session-video?id=$id" 0 99
  Check 'Range bytes=0-99 answers 206 with 100 bytes and the right Content-Range' ($rr1.code -eq 206 -and $rr1.bytes.Length -eq 100 -and $rr1.headers['Content-Range'] -eq "bytes 0-99/$len")
  $mid = [int64]($len / 2); $rr2 = Http "/api/rec/session-video?id=$id" $mid $null
  Check 'Range bytes=<middle>- answers 206 with the rest of the file' ($rr2.code -eq 206 -and $rr2.bytes.Length -eq ($len - $mid))
  Check 'an unknown session id answers 404' ((Http '/api/rec/session-video?id=nope-nope').code -eq 404)
} else { Check 'there is a session video to serve' $false }
}

# =====================================================================================================
if (Want 17) {
Section '17. ending a session then immediately SAVE keeps that session, not the prior one'
$null = J '/vault/test/rec?cmd=on&keep=120&seg=5&grace=2&minlap=3'
$null = J '/vault/test/yaml'
$prior = @((J '/api/rec/sessions').sessions | Sort-Object startMs | Select-Object -Last 1)[0]
Fake @{ IsOnTrack = 1; SessionUniqueID = 717; SessionNum = 0; PlayerCarMyIncidentCount = 0; SessionTime = 100.0 }
$ok = Wait-For { (St).running } 12
Check 'the new session is recording' $ok
$sid = (St).session
Start-Sleep -Seconds 8
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
$resp = Invoke-WebRequest -UseBasicParsing "$api/api/rec/save" -Method POST -TimeoutSec 20
$state = ([Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json).state
Check 'SAVE immediately after end answers SAVING for the finishing session' ($state -eq 'SAVING')
$ok = Wait-For { Test-Path (Join-Path $savedDir ($sid + '.mp4')) } 60
Check 'the just-ended session, not the previous session, is saved' ($ok -and (Test-Path (Join-Path $savedDir ($sid + '.json'))) -and (-not $prior -or $sid -ne $prior.id))
if ($prior -and $prior.saved -eq $false) { Check 'the previous session remains unsaved' (Test-Path (Join-Path $sessDir ($prior.id + '.mp4'))) }
$null = J '/vault/test/rec?cmd=off'
}

# =====================================================================================================
if (Want 18) {
Section '18. session identity change cuts two files whose durations cover the recorded time'
$null = J '/vault/test/rec?cmd=on&keep=120&seg=5&grace=2&minlap=3'
$null = J '/vault/test/yaml'
Fake @{ IsOnTrack = 1; SessionUniqueID = 718; SessionNum = 0; PlayerCarMyIncidentCount = 0; SessionTime = 100.0 }
$null = Wait-For { (St).running } 12
$oneStatus = St; $one = $oneStatus.session; $baseOne = [double]$oneStatus.baseMs
Start-Sleep -Seconds 12
$boundaryMs = NowMs
Fake @{ SessionUniqueID = 719; SessionNum = 0; SessionTime = 112.0 }
$ok = $false; $until = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $until -and -not $ok) {
  Fake @{ IsOnTrack = 1; SessionUniqueID = 719; SessionNum = 0; SessionTime = 112.5 }
  $q = St; $ok = $q.running -and $q.session -and $q.session -ne $one
  if (-not $ok) { Start-Sleep -Milliseconds 500 }
}
$twoStatus = St; $two = $twoStatus.session
# The old ffmpeg process drains its final GOP before the new run starts; sample the new run base after that handoff.
$baseTwo = 0; $until = (Get-Date).AddSeconds(12)
while ((Get-Date) -lt $until -and $baseTwo -le $baseOne) { Start-Sleep -Milliseconds 300; $twoStatus = St; if ($twoStatus.session -eq $two) { $baseTwo = [double]$twoStatus.baseMs } }
Start-Sleep -Seconds 12
$endMs = NowMs
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
$expectedOne = ($boundaryMs - $baseOne) / 1000.0; $expectedTwo = ($endMs - $baseTwo) / 1000.0; $expected = $expectedOne + $expectedTwo
$ok1 = Wait-For { Test-Path (Join-Path $sessDir ($one + '.mp4')) } 60
$ok2 = Wait-For { Test-Path (Join-Path $sessDir ($two + '.mp4')) } 60
Check "the new identity started a second recording (old=$one new=$two, running=$ok)" ($ok -and $one -ne $two)
Check 'the old session file was written' $ok1
Check 'the new session file was written' $ok2
if ($ok1 -and $ok2) {
  $d1 = [double]((Probe "-v error -show_entries format=duration -of default=nw=1:nk=1 `"$(Join-Path $sessDir ($one + '.mp4'))`"").Trim())
  $d2 = [double]((Probe "-v error -show_entries format=duration -of default=nw=1:nk=1 `"$(Join-Path $sessDir ($two + '.mp4'))`"").Trim())
  Check "each file matches its measured capture interval (first $([math]::Round($d1,1))/$([math]::Round($expectedOne,1)) s; second $([math]::Round($d2,1))/$([math]::Round($expectedTwo,1)) s)" ((Near $d1 $expectedOne 2.5) -and (Near $d2 $expectedTwo 2.5))
}
$null = J '/vault/test/rec?cmd=off'
}

# =====================================================================================================
if (Want 19) {
Section '19. ten-second real middle-screen capture writes video packets (no clicks or focus changes)'
$built = J '/vault/test/rec?cmd=buildargs'
$s = @{ lastRunArgs = $built.args; outputIdx = $built.outputIdx; outputRect = $built.outputRect }
Check 'the recorder produced its live-screen ffmpeg command' ($s.lastRunArgs -match ('ddagrab=output_idx=' + $s.outputIdx))
if ($s.lastRunArgs) {
  [RecTool]::WakeDisplays()
  $capDir = Join-Path $tmp 's1e-direct'; New-Item -ItemType Directory -Force $capDir | Out-Null
  $capArgs = $s.lastRunArgs
  $capArgs = $capArgs.Replace($recDir, $capDir)
  $capArgs = $capArgs.Replace(' -f segment ', ' -t 10 -f segment ')
  $direct = Tool $ffmpeg $capArgs 15000
  $packets = 0; $files = @(Get-ChildItem $capDir -Filter '*.ts' -ErrorAction SilentlyContinue)
  foreach ($f in $files) { $p = (Probe "-v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets -of csv=p=0 `"$($f.FullName)`"").Trim(); foreach ($line in ($p -split '\s+')) { $n = 0; if ([int]::TryParse($line, [ref]$n) -and $n -gt $packets) { $packets = $n } } }
  $sizes = @($files | ForEach-Object { $_.Length }) -join ','
  Note ("direct ffmpeg exit $($direct.Code), output $($s.outputIdx) at $($s.outputRect), segments $($files.Count) [$sizes bytes], decoded video packets $packets; $($direct.Err.Trim())")
  Check 'the ten-second direct ddagrab run produced segment files with video packets' ($direct.Code -eq 0 -and $files.Count -ge 1 -and $packets -gt 0)
}
$null = J '/vault/test/rec?cmd=off'
}

# =====================================================================================================
if (Want 20) {
Section '20. an identity change cannot stop a run in its first five seconds'
$null = J '/vault/test/rec?cmd=on&source=test&keep=40&seg=5&grace=2'
Fake @{ IsOnTrack = 1; Lap = 1; LapDistPct = 0.003; LapCurrentLapTime = 0.0; SessionUniqueID = 720; SessionNum = 0; SessionTime = 100.0 }
$running = Wait-For { (St).running } 8
$before = St; Start-Sleep -Seconds 1
Fake @{ IsOnTrack = 1; Lap = 1; LapDistPct = 0.004; LapCurrentLapTime = 1.0; SessionUniqueID = 721; SessionNum = 0; SessionTime = 101.0 }
Start-Sleep -Milliseconds 700
$after = St
Check 'the early identity change leaves the ffmpeg run alive' ($running -and $after.running -and $after.lastRunArgs -match 'testsrc2')
Start-Sleep -Seconds 4
Check 'the run is still alive after its first five seconds' ((St).running)
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
$null = J '/vault/test/rec?cmd=off'
}

# =====================================================================================================
if (Want 21) {
Section '21. a 45-second two-stint session outlives the rolling window and retention'
$null = J '/vault/test/rec?cmd=on&source=test&keep=10&seg=5&grace=2'
Fake @{ IsOnTrack = 1; SessionUniqueID = 721; SessionNum = 0; SessionTime = 100.0 }
$started = Wait-For { (St).running } 8
Start-Sleep -Seconds 23
Fake @{ IsOnTrack = 0 }
Start-Sleep -Seconds 3
Fake @{ IsOnTrack = 1; SessionUniqueID = 721; SessionNum = 0; SessionTime = 126.0 }
$restarted = Wait-For { (St).running } 10
Start-Sleep -Seconds 19
Fake @{ IsOnTrack = 0 }
$stopped = Wait-For { -not (St).running } 8
$endStatus = St
$expectedDuration = 0.0
foreach ($seg in @($endStatus.segList)) { $expectedDuration += ([double]$seg.endMs - [double]$seg.startMs) / 1000.0 }
$beforeEnd = @(Get-ChildItem $recDir -Filter '*.ts' -ErrorAction SilentlyContinue)
$ret = J '/vault/test/rec?cmd=retain'
$afterRetain = @(Get-ChildItem $recDir -Filter '*.ts' -ErrorAction SilentlyContinue)
Check 'retention leaves every segment of the open session in place' ($beforeEnd.Count -gt 0 -and $afterRetain.Count -eq $beforeEnd.Count)
Check 'the two-stint session exceeds three times its 10-second keep window' ($started -and $restarted -and $stopped -and ((St).sessionSecs -ge 44))
$sid = $endStatus.session
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
$ok = Wait-For { Test-Path (Join-Path $sessDir ($sid + '.mp4')) } 60
Check 'the long session is joined into one MP4' $ok
if ($ok) {
  $dur = [double]((Probe "-v error -show_entries format=duration -of default=nw=1:nk=1 `"$(Join-Path $sessDir ($sid + '.mp4'))`"").Trim())
  Check "the MP4 duration matches the measured $([math]::Round($expectedDuration,1)) seconds (got $([math]::Round($dur,1)) s)" (Near $dur $expectedDuration 1)
  Check 'its source TS files are removed only after the MP4 is written' (@(Get-ChildItem $recDir -Filter '*.ts' -ErrorAction SilentlyContinue).Count -eq 0)
}
$null = J '/vault/test/rec?cmd=off'
}

# =====================================================================================================
if (Want 22) {
Section '22. a missing middle segment does not prevent the session video'
$null = J '/vault/test/rec?cmd=on&source=test&keep=10&seg=5&grace=2'
Fake @{ IsOnTrack = 1; SessionUniqueID = 722; SessionNum = 0; SessionTime = 200.0 }
$null = Wait-For { (St).running } 8
Start-Sleep -Seconds 18
$listed = @((St).segList)
$mid = if ($listed.Count -ge 3) { $listed[[int]($listed.Count / 2)] } else { $null }
if ($mid -and $mid.name) { Remove-Item (Join-Path $recDir $mid.name) -Force -ErrorAction SilentlyContinue }
$sid = (St).session
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
$ok = Wait-For { Test-Path (Join-Path $sessDir ($sid + '.mp4')) } 60
Check 'the remaining segments still produce the session MP4' ($ok -and $mid -ne $null)
$logNow = @(Get-Content $logFile -ErrorAction SilentlyContinue)
Check 'the missing middle segment is named in the recorder log' (@($logNow | Where-Object { $_ -match 'session ' + [regex]::Escape($sid) + ' is missing segment ' + [regex]::Escape($mid.name) }).Count -gt 0)
$null = J '/vault/test/rec?cmd=off'
}

}
finally {
  try { Cdp-Close } catch { }
  try { $null = J '/vault/test/rec?cmd=off' } catch { }
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8 } catch { }
  try { $null = J '/vault/test/sandbox?on=0' } catch { }
  Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*vault-test*' } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Remove-Item $hook -Force -ErrorAction SilentlyContinue
  Remove-Item $lock -Force -ErrorAction SilentlyContinue
  Exit-TestLock
  if (-not $Keep) {
    try { if (Test-Path $tdir) { Remove-Item $tdir -Recurse -Force } } catch { }
    try { if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force } } catch { }
  } else { "  info  -Keep: the scratch vault stays in $tdir (delete it when done)" }
  $newLog = @(Log-Since $logN | Where-Object { $_ -match 'recorder' -and $_ -match 'rror|exception|could not|failed' -and $_ -notmatch 'ffmpeg stopped by itself|ffmpeg keeps stopping' })      # the killed-on-purpose lines of section 9 are the test's own
  if ($newLog.Count) { "  info  irdash.log lines to look at:"; $newLog | Select-Object -First 8 | ForEach-Object { "        $_" } }
}
"$pass passed, $fail failed. Pictures in $shots (rec-*.png). $([math]::Round($swAll.Elapsed.TotalSeconds, 0)) s"
if ($fail -gt 0) { exit 1 }
