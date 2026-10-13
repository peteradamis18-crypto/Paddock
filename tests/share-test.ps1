# P2 SHARE STUDIO (dash\src\share.cs, docs\PLAN-v3.md): a kept lap video gets a broadcast-style data overlay burned in (speed, gear, pedals, lap time, gap to the
# reference, track map, name / car / track, Paddock mark), 1080p60, upright, encoded on the graphics card.
# A pretend clip (1280x720, 60 fps, STORED UPSIDE DOWN with the 180 degree rotation flag like the recorder's real clips, a 32-block binary clock and orientation
# markers burned in) is tied to REAL lap 7 (the PB) of "chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt" in the SCRATCH vault (vault-test\, never Peter's Vault).
# The share video is made in test mode, which adds a machine-readable stripe (speed, gear, pedals, lap time, gap as black / white blocks) along the bottom edge.
# Checked: refusal while "driving", the queue (one at a time, a second job waits), the finished file (1920x1080, 60 fps, every clip picture, same length, no rotation
# flag left, upright by the markers), the burned-in clock agrees with the stripe's lap time (picture and data are the same instant), the stripe's numbers at 3 times
# against an independent reader of the .ibt (and the gap against the workbench's own channels route), the visible speed digits against the picture the overlay
# draws for that time, Range serving, the folder opener (this PC only), the phone gate, the workbench button and the phone's clip screen headless.
# Pictures: tests\shots\share-*.png.
# Out of the car only (guard.ps1). Needs the deployed irdash (dash\build.ps1).
#   powershell -ExecutionPolicy Bypass -File tests\share-test.ps1 [-Keep]
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
function Code($path) { try { return [int](Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 60).StatusCode } catch [Net.WebException] { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } return 0 } }
function JCode($path) { try { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 60; return @{ code = [int]$r.StatusCode; j = ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json) } } catch [Net.WebException] { $resp = $_.Exception.Response; if ($resp) { $txt = "$($_.ErrorDetails.Message)"; $j = $null; try { $j = $txt | ConvertFrom-Json } catch { }; return @{ code = [int]$resp.StatusCode; j = $j } } return @{ code = 0; j = $null } } }
function Fake($q) { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?$q" -TimeoutSec 8 }

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; $title }
$me = Get-Process -Id $PID; $me.PriorityClass = 'BelowNormal'

$ffmpeg = Join-Path $root 'vault\bin\ffmpeg.exe'; $ffprobe = Join-Path $root 'vault\bin\ffprobe.exe'
$tdir = Join-Path $root 'vault-test'; $srcDir = Join-Path $tdir 'src'; $clipDir = Join-Path $tdir 'vault\clips'
$hook = Join-Path $root 'dash\test-hook.on'; $lock = Join-Path $root 'dash\deploy.lock'
$tmp = Join-Path $env:TEMP ('share-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$pbName = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt'

# a second, independent reader of the .ibt (never Paddock's own code) + the readers of the pictures
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Collections.Generic; using System.Drawing; using System.IO; using System.Text;
public static class ShareRaw {
  public static Dictionary<string,double[]> All(string file, string[] names) {
    byte[] b = File.ReadAllBytes(file);
    int bl = BitConverter.ToInt32(b, 36), bo = BitConverter.ToInt32(b, 52), rc = BitConverter.ToInt32(b, 140), nv = BitConverter.ToInt32(b, 24), vho = BitConverter.ToInt32(b, 28);
    var vars = new Dictionary<string,int[]>();
    for (int i = 0; i < nv; i++) { int p = vho + 144 * i; vars[Encoding.ASCII.GetString(b, p + 16, 32).Trim('\0')] = new int[] { BitConverter.ToInt32(b, p), BitConverter.ToInt32(b, p + 4) }; }
    var cols = new Dictionary<string,double[]>(); foreach (var k in names) cols[k] = new double[rc];
    for (int r = 0; r < rc; r++) {
      int bs = bo + r * bl;
      foreach (var k in names) { var v = vars[k]; double x = 0; switch (v[0]) { case 0: case 1: x = b[bs + v[1]]; break; case 2: case 3: x = BitConverter.ToInt32(b, bs + v[1]); break; case 4: x = BitConverter.ToSingle(b, bs + v[1]); break; case 5: x = BitConverter.ToDouble(b, bs + v[1]); break; } cols[k][r] = x; }
    }
    return cols;
  }
}
public static class SharePic {
  static double Luma(Color c) { return 0.299 * c.R + 0.587 * c.G + 0.114 * c.B; }
  // the 80-block stripe along the bottom edge -> speed km/h, gear, throttle, brake, lap time s, gap s (NaN none)
  public static double[] Stripe(string png) {
    using (Bitmap b = new Bitmap(png)) {
      ulong[] f = new ulong[6]; int[] n = { 17, 4, 10, 10, 20, 16 }; int idx = 0;
      for (int i = 0; i < 6; i++) for (int k = 0; k < n[i]; k++) { Color c = b.GetPixel(8 + idx * 18 + 9, b.Height - 5); f[i] = (f[i] << 1) | (Luma(c) > 128 ? 1UL : 0UL); idx++; }
      return new double[] { f[0] / 100.0, (double)f[1] - 1, f[2] / 1000.0, f[3] / 1000.0, f[4] / 1000.0 - 20, f[5] == 65535UL ? double.NaN : f[5] / 1000.0 - 30 };
    }
  }
  // the burned-in clock: 32 blocks of 20 px (source pixels, 1.5x here) = the picture's own time in ms
  public static long Clock(string png, double scale) {
    using (Bitmap b = new Bitmap(png)) { long v = 0; for (int i = 0; i < 32; i++) { Color c = b.GetPixel((int)((i * 20 + 10) * scale), (int)(16 * scale)); if (Luma(c) > 128) v |= (1L << i); } return v; }
  }
  public static string Pix(string png, int x, int y) { using (Bitmap b = new Bitmap(png)) { Color c = b.GetPixel(x, y); return c.R + "," + c.G + "," + c.B + "," + c.A; } }
  // white-pixel masks of a region of the video frame (text on the dark panel) and of the overlay picture (opaque white); intersection over union
  public static double Iou(string frame, string overlay, int x, int y, int w, int h, int oy) {
    using (Bitmap f = new Bitmap(frame)) using (Bitmap o = new Bitmap(overlay)) {
      long inter = 0, uni = 0;
      for (int j = 0; j < h; j++) for (int i = 0; i < w; i++) {
        Color a = f.GetPixel(x + i, y + j), c = o.GetPixel(x + i, y + j - oy);
        bool fa = Luma(a) > 170 && Math.Abs(a.R - a.B) < 40, ob = c.A > 170 && c.R > 200 && c.G > 200 && c.B > 200;
        if (fa && ob) inter++; if (fa || ob) uni++;
      }
      return uni == 0 ? 1.0 : (double)inter / uni;
    }
  }
}
'@

function Cut-Frame($mp4, [double]$sec, [string]$png) { & $ffmpeg -hide_banner -loglevel error -y -ss $sec -i $mp4 -frames:v 1 $png; return (Test-Path $png) }
function Probe($mp4, $entries) { (& $ffprobe -v error -select_streams v:0 -show_entries $entries -of default=nw=1 $mp4) -join ';' }

$logFile = Join-Path $root 'dash\irdash.log'
$swAll = [Diagnostics.Stopwatch]::StartNew()
'Share studio test'
Enter-TestLock 'share'   # one live test at a time (tests\guard.ps1); released in finally
try {
  for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock (' + (Get-Content $lock) + ')'; Start-Sleep -Seconds 60 }
  Set-Content $lock ('share-test ' + (Get-Date).ToString('HH:mm:ss'))
  Set-Content $hook 'share test'
  $probe = Code '/share/status?id=nothing'
  if ($probe -ne 404) { 'irdash is running, but it is not the new build (/share/status is not answering). Run dash\build.ps1, then this test again.'; exit 1 }
  if (Test-Path $tdir) { Remove-Item $tdir -Recurse -Force }
  New-Item -ItemType Directory -Force $srcDir | Out-Null
  $null = J '/vault/test/sandbox?on=1&reset=1'

  # =====================================================================================================
  Section '1. a pretend clip tied to a real lap (lap 7 of the PB session), stored upside down with the rotation flag, in the scratch vault'
  Check 'the PB session telemetry file is on this PC' (Test-Path (Join-Path $tel $pbName))
  Check 'ffmpeg and ffprobe are on this PC (vault\bin)' ((Test-Path $ffmpeg) -and (Test-Path $ffprobe))
  Copy-Item (Join-Path $tel $pbName) (Join-Path $srcDir $pbName) -Force; (Get-Item (Join-Path $srcDir $pbName)).LastWriteTime = (Get-Item (Join-Path $tel $pbName)).LastWriteTime
  $null = J '/vault/test/scan'; $lst = J '/vault/list'
  $m7 = @($lst.moments | Where-Object { $_.kind -eq 'lap' -and $_.lap -eq 7 -and $_.lapTime -gt 0 })[0]
  $m6 = @($lst.moments | Where-Object { $_.kind -eq 'lap' -and $_.lap -eq 6 -and $_.lapTime -gt 0 })[0]
  Check 'the scratch vault has laps 6 and 7 of that session as Vault laps' (($null -ne $m7) -and ($null -ne $m6))
  if (-not $m7 -or -not $m6) { throw 'no laps in the scratch vault' }
  $lapTime = [double]$m7.lapTime; $lt6 = [double]$m6.lapTime
  Note "Vault lap $($m7.id): lap 7, $lapTime s, $($m7.car) / $($m7.track)"
  $lead = 2.1; $dur = [math]::Round($lead + $lapTime + 1.5, 2); $durB = 14.0
  # what the screen shows (upright): dark grey, a green marker top right, a red marker left, the 32-block clock top left; stored rotated by 180 degrees
  $graph = "color=c=0x202020:s=1280x720:r=60,drawbox=x=1160:y=0:w=120:h=70:color=0x00cc44:t=fill,drawbox=x=0:y=500:w=120:h=60:color=0xdd2222:t=fill,split=2[a][b];[b]crop=640:32:0:0,format=yuv420p,geq=lum='255*mod(floor(floor(T*1000)/pow(2,floor(X/20))),2)':cb=128:cr=128[c];[a][c]overlay=0:0,drawtext=text='%{pts\:hms}':x=10:y=60:fontsize=48:fontcolor=white:box=1:boxcolor=black@0.7,hflip,vflip"
  [IO.File]::WriteAllText((Join-Path $tmp 'graph.txt'), $graph, (New-Object Text.UTF8Encoding($false)))
  $raw = Join-Path $tmp 'stored.mp4'; $mp4 = Join-Path $tmp 'pretend.mp4'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $ErrorActionPreference = 'Continue'   # (ffmpeg's drawtext writes a harmless fontconfig line to stderr)
  & $ffmpeg -hide_banner -y -loglevel error -/filter_complex (Join-Path $tmp 'graph.txt') -t $dur -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 30 -bf 0 -crf 28 -an $raw 2>$null; $ErrorActionPreference = 'Stop'
  & $ffmpeg -hide_banner -y -loglevel error -display_rotation 180 -i $raw -c copy -movflags +faststart $mp4
  Check "ffmpeg made a $dur s pretend clip with the 180 degree flag ($([math]::Round((Get-Item $mp4).Length / 1MB, 1)) MB, $([math]::Round($sw.Elapsed.TotalSeconds, 0)) s)" ((Test-Path $mp4) -and ((& $ffprobe -v error -select_streams v:0 -show_entries stream_side_data=rotation -of default=nw=1 $mp4) -join ';') -match 'rotation=-?180')
  $mpB = Join-Path $tmp 'pretendB.mp4'
  & $ffmpeg -hide_banner -y -loglevel error -i $mp4 -t $durB -c copy -movflags +faststart $mpB
  function Put-Clip([string]$id, [string]$file, [int]$lap, [double]$lt, [double]$startOff, [long]$startMs, [double]$d, [bool]$trunc) {
    Copy-Item $file (Join-Path $clipDir "$id.mp4") -Force
    $j = [ordered]@{ id = $id; lap = [int]$lap; lapTime = [math]::Round($lt, 3); lapStartMs = [long]$startMs; lapEndMs = [long]($startMs + $lt * 1000); clipStartMs = [long]($startMs - $startOff * 1000); lapStartOffset = [double]$startOff; lapEndOffset = [double]($startOff + $lt);
      videoStart = 0.0; duration = [double]$d; fps = 60; rotation = 180; encoder = 'libx264'; car = [string]$m7.car; track = [string]$m7.track; config = [string]$m7.config; sessionTime = 0.0; why = 'test'; keep = $false; pb = $true; truncated = [bool]$trunc; created = (NowMs); size = (Get-Item (Join-Path $clipDir "$id.mp4")).Length }
    ($j | ConvertTo-Json -Compress) | Set-Content (Join-Path $clipDir "$id.json") -Encoding UTF8
  }
  New-Item -ItemType Directory -Force $clipDir | Out-Null
  $id7 = 'rec-20261010-001500-l7'; $id6 = 'rec-20261010-001400-l6'
  Put-Clip $id7 $mp4 7 $lapTime $lead ([long]$m7.startMs) $dur $false
  Put-Clip $id6 $mpB 6 $lt6 $lead ([long]$m6.startMs) $durB $true
  $ri = J '/vault/test/rec?cmd=reindex'
  Check 'the recorder picked both clips up (reindex)' ($ri.ok -eq $true -and $ri.clips -eq 2)
  $nPics = [int]((& $ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 $mp4) -join '')
  Note "the clip has $nPics pictures ($([math]::Round($nPics / 60, 2)) s)"
  $spec7 = "$pbName`:7"

  # =====================================================================================================
  Section '2. refusal while driving, the queue, the job'
  Fake 'IsOnTrack=1&IsReplayPlaying=0&SessionNum=1&SessionTime=100'; Start-Sleep -Milliseconds 400
  $r = JCode "/share/make?id=$(Q $spec7)"
  Check 'asking for a share video while he is "driving" is refused (409, plain words, nothing queued)' ($r.code -eq 409 -and "$($r.j.error)" -match 'driving')
  $st = J "/share/status?id=$(Q $spec7)"
  Check '... and the status says nothing was queued' ($st.state -eq 'none')
  Fake 'IsOnTrack=0&IsReplayPlaying=0&SessionNum=1&SessionTime=100'; Start-Sleep -Milliseconds 400
  # (the pretend session stays on but he is out of the car; the sim itself is not running, so the job may start)
  $r = JCode "/share/make?id=$(Q $spec7)&stripe=1"
  Check 'asking when he is out of the car is accepted: queued or already making' ($r.code -eq 200 -and ($r.j.state -eq 'queued' -or $r.j.state -eq 'making'))
  $r2 = JCode "/share/make?id=$(Q $id6)&stripe=1"
  Check 'a second request (the short clip) is accepted and waits its turn behind the first (queue position 1)' ($r2.code -eq 200 -and $r2.j.state -eq 'queued' -and $r2.j.queue -eq 1)
  $r3 = JCode "/share/make?id=$(Q $id7)&stripe=1"
  Check 'asking again for the same lap does not add a second job (same status, still queue 0)' ($r3.code -eq 200 -and $r3.j.queue -eq 0 -and $r3.j.id -eq $id7)
  $sawMaking = $false; $pcts = New-Object System.Collections.Generic.List[int]; $sw = [Diagnostics.Stopwatch]::StartNew(); $s7 = $null; $s6q = $null
  while ($sw.Elapsed.TotalSeconds -lt 600) {
    Start-Sleep -Milliseconds 700
    $s7 = J "/share/status?id=$(Q $id7)"
    if ($s7.state -eq 'making') { $sawMaking = $true; $pcts.Add([int]$s7.pct); if (-not $s6q) { $s6q = J "/share/status?id=$(Q $id6)" } }
    if ($s7.state -eq 'done' -or $s7.state -eq 'error') { break }
    if ($pcts.Count -gt 0 -and $pcts.Count % 20 -eq 0) { Assert-RigFree -Where 'share render' }
  }
  Check "the first job ran and finished in $([math]::Round($sw.Elapsed.TotalSeconds, 0)) s: state $($s7.state) ($($s7.reason))" ($s7.state -eq 'done')
  Check 'it reported progress while making (percent rose from low to high over several polls)' ($sawMaking -and $pcts.Count -ge 3 -and $pcts[0] -lt $pcts[$pcts.Count - 1] -and (($pcts | Sort-Object) -join ',') -eq ($pcts -join ','))
  Check 'while it made lap 7 the short clip waited (queued, position 1) - one render at a time' ($s6q -and $s6q.state -eq 'queued' -and $s6q.queue -eq 1)
  Check 'the status of the finished one: ready, h264_nvenc (or the processor fallback), a download name, a size' ($s7.ready -eq $true -and $s7.size -gt 100000 -and $s7.name -match '^paddock-.*-share\.mp4$' -and $s7.encoder -match 'nvenc|libx264')
  Note "encoder $($s7.encoder), $([math]::Round($s7.size / 1MB, 1)) MB, made in $($s7.seconds) s ($([math]::Round($nPics / [math]::Max(1, [double]$s7.seconds), 0)) pictures a second)"
  $sw = [Diagnostics.Stopwatch]::StartNew(); $s6 = $null
  while ($sw.Elapsed.TotalSeconds -lt 300) { Start-Sleep -Milliseconds 700; $s6 = J "/share/status?id=$(Q $id6)"; if ($s6.state -eq 'done' -or $s6.state -eq 'error') { break } }
  Check "the queued short clip ran after it ($($s6.state))" ($s6.state -eq 'done')
  $out7 = Join-Path $clipDir "share-$id7.mp4"; $side7 = Join-Path $clipDir "share-$id7.json"
  Check 'the result sits next to the clip as share-<clip id>.mp4 with a sidecar .json' ((Test-Path $out7) -and (Test-Path $side7))
  $sd = Get-Content $side7 -Raw | ConvertFrom-Json
  Check 'the sidecar: 1920x1080, upright, frames = the clip''s pictures, overlay v1, km/h' ($sd.width -eq 1920 -and $sd.height -eq 1080 -and $sd.upright -eq $true -and $sd.frames -eq $nPics -and $sd.overlay -eq 'v1' -and $sd.units -eq 'kmh')
  $ri = J '/vault/test/rec?cmd=reindex'
  Check 'the recorder did not take the share sidecar for a clip (still 2 clips)' ($ri.clips -eq 2)

  # =====================================================================================================
  Section '3. the finished file'
  $pr = Probe $out7 'stream=codec_name,width,height,r_frame_rate,nb_frames,duration,pix_fmt,profile:stream_side_data=rotation'
  Note $pr
  Check '1920x1080, h264, 60 fps, yuv420p' ($pr -match 'codec_name=h264' -and $pr -match 'width=1920' -and $pr -match 'height=1080' -and $pr -match 'r_frame_rate=60/1' -and $pr -match 'pix_fmt=yuv420p')
  Check 'as many pictures as the clip, the same length (within one picture)' ($pr -match "nb_frames=$nPics" -and (Near ([regex]::Match($pr, 'duration=([\d.]+)').Groups[1].Value) ($nPics / 60.0) 0.02))
  Check 'no rotation flag left: it is upright without relying on a flag' ($pr -notmatch 'rotation=')
  $fr = @{}
  foreach ($t in @(12.0, 41.3, 70.0)) {
    $K = [math]::Round(($lead + $t) * 60); $png = Join-Path $shots ("share-frame-" + [int]$t + ".png")
    $null = Cut-Frame $out7 (($K - 0.5) / 60.0) $png; $fr[[string]$t] = @{ K = $K; png = $png }
  }
  # ---- orientation: the markers burned into the UPRIGHT picture (green top right, red left) must be there, the clock readable
  $p0 = $fr['12'].png
  $gp = [SharePic]::Pix($p0, 1905, 60).Split(','); $rp = [SharePic]::Pix($p0, 60, 790).Split(',')
  Check 'upright: the green marker is top right and the red marker is left (the clip was stored upside down with the flag; the copy has no flag)' ([int]$gp[1] -gt 150 -and [int]$gp[0] -lt 80 -and [int]$rp[0] -gt 180 -and [int]$rp[1] -lt 80)
  # ---- the data: an independent reader of the .ibt, and the workbench's own channels for the gap
  $raw = [ShareRaw]::All((Join-Path $tel $pbName), @('SessionTime', 'LapDistPct', 'Lap', 'Speed', 'Throttle', 'Brake', 'Gear'))
  $ST = $raw['SessionTime']; $LAP = $raw['Lap']; $PCT = $raw['LapDistPct']
  $i0 = -1; for ($i = 1; $i -lt $LAP.Length; $i++) { if ([int]$LAP[$i] -eq 7 -and [int]$LAP[$i - 1] -eq 6) { $i0 = $i; break } }
  $p0v = $PCT[$i0 - 1]; $p1v = $PCT[$i0]; $T0 = $ST[$i0 - 1] + ($ST[$i0] - $ST[$i0 - 1]) * (1 - $p0v) / ((1 - $p0v) + $p1v)
  function Raw-At([double]$t) {
    $s = $T0 + $t; $j = $i0; while ($j + 1 -lt $ST.Length -and $ST[$j + 1] -le $s) { $j++ }
    $f = ($s - $ST[$j]) / ($ST[$j + 1] - $ST[$j])
    return @{ spd = ($raw['Speed'][$j] + ($raw['Speed'][$j + 1] - $raw['Speed'][$j]) * $f) * 3.6; thr = $raw['Throttle'][$j] + ($raw['Throttle'][$j + 1] - $raw['Throttle'][$j]) * $f; brk = $raw['Brake'][$j] + ($raw['Brake'][$j + 1] - $raw['Brake'][$j]) * $f; gear = [int]$raw['Gear'][$j] }
  }
  $cr = Invoke-WebRequest -UseBasicParsing "$api/analysis/channels?id=$(Q $pbName)&lap=7&ref=pb&ch=Speed" -TimeoutSec 60
  $cb = $cr.RawContentStream.ToArray(); $hl = [BitConverter]::ToInt32($cb, 4); $hd = [Text.Encoding]::UTF8.GetString($cb, 8, $hl) | ConvertFrom-Json; $nn = [int]$hd.n; $base = 8 + $hl
  function Arr($k) { $o = New-Object 'single[]' $nn; [Buffer]::BlockCopy($cb, $base + 4 * $nn * $k, $o, 0, 4 * $nn); return $o }
  $lapT = Arr 0; $refT = Arr 2
  Check "the workbench's channels route has a reference lap for lap 7 ($($hd.ref.kind), lap $($hd.ref.lap), $($hd.ref.time) s)" ($null -ne $hd.ref -and $refT[$nn - 1] -gt 60)
  function Gap-At([double]$t) { $lo = 0; $hi = $nn - 1; while ($lo + 1 -lt $hi) { $m = [int](($lo + $hi) / 2); if ($lapT[$m] -le $t) { $lo = $m } else { $hi = $m } }; $f = ($t - $lapT[$lo]) / ($lapT[$hi] - $lapT[$lo]); return $t - ($refT[$lo] + ($refT[$hi] - $refT[$lo]) * $f) }
  foreach ($t in @(12.0, 41.3, 70.0)) {
    $f = $fr[[string]$t]; $K = $f.K; $tf = $K / 60.0 - $lead; $sd2 = [SharePic]::Stripe($f.png); $clk = [SharePic]::Clock($f.png, 1.5); $e = Raw-At $tf; $gx = Gap-At $tf
    Check ("t=$t s (picture $K): the lap time in the data ($([math]::Round($sd2[4], 3)) s) is the picture's own time minus the sidecar's lapStartOffset (exact to 1 ms), and the clock burned into the picture says the same instant ($clk ms)") ((Near $sd2[4] $tf 0.0011) -and (Near $clk (($tf + $lead) * 1000) 2.0))
    Check ("t=$t s: speed $([math]::Round($sd2[0], 2)) km/h = the raw .ibt $([math]::Round($e.spd, 2)); gear $($sd2[1]) = $($e.gear); throttle $($sd2[2]) / brake $($sd2[3]) = $([math]::Round($e.thr, 3)) / $([math]::Round($e.brk, 3))") ((Near $sd2[0] $e.spd 0.3) -and $sd2[1] -eq $e.gear -and (Near $sd2[2] $e.thr 0.003) -and (Near $sd2[3] $e.brk 0.003))
    Check ("t=$t s: the gap to the reference $([math]::Round($sd2[5], 3)) s = the workbench's own gap $([math]::Round($gx, 3)) s (within 12 ms)") (-not [double]::IsNaN($sd2[5]) -and (Near $sd2[5] $gx 0.012))
  }
  # ---- the visible digits: the picture the overlay draws for that time against the video frame
  $iou = @{}
  foreach ($t in @(12.0, 41.3, 70.0)) {
    $f = $fr[[string]$t]; $tf = $f.K / 60.0 - $lead
    $ov = Join-Path $tmp "ov$([int]$t).png"; Invoke-WebRequest -UseBasicParsing "$api/share/test/frame?id=$(Q $id7)&t=$tf" -OutFile $ov -TimeoutSec 60
    $ovFar = Join-Path $tmp "ovf$([int]$t).png"; Invoke-WebRequest -UseBasicParsing "$api/share/test/frame?id=$(Q $id7)&t=$($tf + 4.0)" -OutFile $ovFar -TimeoutSec 60
    $iou[$t] = @{ same = [SharePic]::Iou($f.png, $ov, 225, 976, 180, 84, 880); far = [SharePic]::Iou($f.png, $ovFar, 225, 976, 180, 84, 880) }
  }
  Check ("the speed digits on the video frame are the digits the overlay draws for that time (overlap $(@(12.0, 41.3, 70.0 | ForEach-Object { [math]::Round($iou[$_].same, 2) }) -join ' / ')), not those of 4 s later ($(@(12.0, 41.3, 70.0 | ForEach-Object { [math]::Round($iou[$_].far, 2) }) -join ' / '))") (@(12.0, 41.3, 70.0 | Where-Object { $iou[$_].same -gt 0.8 -and $iou[$_].same -gt $iou[$_].far + 0.25 }).Count -eq 3)
  Copy-Item (Join-Path $shots 'share-frame-41.png') (Join-Path $shots 'share-overlay.png') -Force

  # =====================================================================================================
  Section '4. serving (Range), the folder opener and the phone gate'
  $sz = (Get-Item $out7).Length
  $rq = [Net.HttpWebRequest]::Create("$api/share/video?id=$(Q $id7)"); $rq.AddRange(100, 1123); $rs = $rq.GetResponse()
  Check '/share/video answers a Range request with 206 and the right bytes' ([int]$rs.StatusCode -eq 206 -and $rs.ContentLength -eq 1024 -and $rs.Headers['Content-Range'] -match "bytes 100-1123/$sz"); $rs.Close()
  Check '... the whole file with 200; the vault lap id and the file:lap names find the same video; an unknown id is a 404' ((Code "/share/video?id=$(Q $id7)") -eq 200 -and (Code "/share/video?id=$(Q $spec7)") -eq 200 -and (Code "/share/video?id=$(Q $m7.id)") -eq 200 -and (Code '/share/video?id=rec-nothing') -eq 404)
  $o = JCode "/share/open?id=$(Q $id7)&dry=1"
  Check '/share/open (dry run) finds the file and would open the folder with it selected (this PC)' ($o.code -eq 200 -and $o.j.ok -eq $true -and $o.j.name -eq "share-$id7.mp4")
  Check 'from the phone side (?asphone=1) /share/open, /share/jump and the test route are not there (404), and /share/make needs the pairing token (401)' ((Code "/share/open?id=$(Q $id7)&dry=1&asphone=1") -eq 404 -and (Code "/share/jump?id=x&t=1&asphone=1") -eq 404 -and (Code "/share/test/frame?id=x&t=1&asphone=1") -eq 404 -and (Code "/share/make?id=$(Q $id7)&asphone=1") -eq 401)

  # =====================================================================================================
  Section '5. he starts driving while it is being made: it stops, waits, and finishes afterwards'
  $r = JCode "/share/make?id=$(Q $id7)&stripe=1&force=1"
  $sw = [Diagnostics.Stopwatch]::StartNew(); $s = $null
  while ($sw.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 400; $s = J "/share/status?id=$(Q $id7)"; if ($s.state -eq 'making' -and $s.pct -ge 8) { break } }
  Check "a remake is under way ($($s.state) $($s.pct) %)" ($s.state -eq 'making')
  Fake 'IsOnTrack=1&IsReplayPlaying=0&SessionNum=1&SessionTime=100'
  $sw.Restart(); while ($sw.Elapsed.TotalSeconds -lt 12) { Start-Sleep -Milliseconds 400; $s = J "/share/status?id=$(Q $id7)"; if ($s.state -eq 'waiting') { break } }
  Check "within a few seconds of him driving the job stops and waits ($($s.state): $($s.reason))" ($s.state -eq 'waiting' -and "$($s.reason)" -match 'driving')
  Start-Sleep -Seconds 3; $s = J "/share/status?id=$(Q $id7)"
  Check 'it stays waiting while he drives (no progress)' ($s.state -eq 'waiting')
  Fake 'IsOnTrack=0&IsReplayPlaying=0&SessionNum=1&SessionTime=100'
  $sw.Restart(); while ($sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 700; $s = J "/share/status?id=$(Q $id7)"; if ($s.state -eq 'done' -or $s.state -eq 'error') { break } }
  Check "when he is out of the car again it finishes ($($s.state))" ($s.state -eq 'done' -and $s.ready -eq $true)

  # =====================================================================================================
  Section '6. the workbench button and the phone clip screen, headless'
  $script:cdp = $null
  function Cdp-Open($url, $w, $h) {
    $prof = Join-Path $env:TEMP ('share-test-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9377
    $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', '--autoplay-policy=no-user-gesture-required', 'about:blank') -PassThru -WindowStyle Hidden
    try { $p.PriorityClass = 'BelowNormal' } catch { }
    $page = $null
    for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
    if (-not $page) { throw 'headless Chrome did not start' }
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
    $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0; errors = New-Object System.Collections.Generic.List[string] }
    $null = Cdp 'Page.enable' @{}; $null = Cdp 'Runtime.enable' @{}
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
  function Wait-Until($expr, $secs) { $sw2 = [Diagnostics.Stopwatch]::StartNew(); while ($sw2.Elapsed.TotalSeconds -lt $secs) { if ((Cdp-Eval "!!($expr)") -eq $true) { return $true }; Start-Sleep -Milliseconds 300 }; return $false }
  function Cdp-Close() {
    $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
    try { $c.ws.Dispose() } catch { }
    try { $c.proc | Stop-Process -Force } catch { }
    Start-Sleep -Milliseconds 400
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
    Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }
  # --- the workbench, lap 6 (its share video is removed first: the button starts at MAKE SHARE VIDEO)
  Remove-Item (Join-Path $clipDir "share-$id6.mp4"), (Join-Path $clipDir "share-$id6.json") -Force
  Check 'a clip whose share video was not made (or was removed) is a 404 on /share/video: the plain clip is never served in its place' ((Code "/share/video?id=$(Q $id6)") -eq 404)
  Cdp-Open "$api/v2/workbench.html?id=$(Q $pbName)&lap=6&page=video" 1920 1080
  $up = Wait-Until "window.WB && WB.extras && !WB.error" 40
  $wbErr = [string](Cdp-Eval 'WB.error || ""'); Check "the workbench opens lap 6 on the VIDEO page ($wbErr)" ($up -and $wbErr -eq '')
  $null = Wait-Until "WB.share && WB.share().chip && WB.share().chip.shown && WB.share().st" 15
  $ch = Cdp-Obj 'WB.share()'
  Check 'the VIDEO page shows the chip MAKE SHARE VIDEO (nothing made yet for this lap)' ($ch.chip.shown -and $ch.chip.text -eq 'MAKE SHARE VIDEO')
  $null = Cdp-Eval "document.getElementById('sharebtn').click(); true"
  $seen = New-Object System.Collections.Generic.List[string]; $sw2 = [Diagnostics.Stopwatch]::StartNew()
  while ($sw2.Elapsed.TotalSeconds -lt 90) { Start-Sleep -Milliseconds 400; $tx = [string](Cdp-Eval "document.getElementById('sharebtn').textContent"); if ($seen.Count -eq 0 -or $seen[$seen.Count - 1] -ne $tx) { $seen.Add($tx) }; if ($tx -eq 'SHOW SHARE VIDEO') { break } }
  Check "pressing it shows the progress and ends at SHOW SHARE VIDEO ($($seen -join ' > '))" ($seen[$seen.Count - 1] -eq 'SHOW SHARE VIDEO' -and $seen.Count -ge 2)
  Cdp-Shot (Join-Path $shots 'share-workbench.png')
  $wbw = Cdp-Obj '(function(){ var b = document.getElementById("sharebtn").getBoundingClientRect(), m = document.getElementById("mode").getBoundingClientRect(); return { right: b.right, mode: m.width, vis: b.width > 0 }; })()'
  Check "the chip fits the header and the words next to it keep room ($([math]::Round($wbw.mode)) px)" ($wbw.vis -and $wbw.right -lt 1900 -and $wbw.mode -gt 120)
  $null = Cdp-Eval 'WB.cmd("page", "driver"); true'; Start-Sleep -Milliseconds 800
  Check 'on the other pages the chip is not shown' ((Cdp-Eval "document.getElementById('sharebtn').style.display") -eq 'none')
  Check 'no JS error in the workbench' ($script:cdp.errors.Count -eq 0)
  Cdp-Close
  # --- the phone's clip screen (393 x 852)
  $mC = @($lst.moments | Where-Object { $_.kind -eq 'lap' -and $_.lap -notin @(6, 7) -and $_.lapTime -gt 0 })[0]
  $idC = 'rec-20261010-001300-l' + $mC.lap
  Put-Clip $idC $mpB ([int]$mC.lap) ([double]$mC.lapTime) $lead ([long]$mC.startMs) $durB $true
  $null = J '/vault/test/rec?cmd=reindex'
  Cdp-Open "$api/phone/" 393 852
  $up = Wait-Until "typeof PhoneApp !== 'undefined' && !!PhoneApp.st" 15
  $null = Cdp-Eval "PhoneApp.show('clips'); true"
  $null = Wait-Until "PhoneApp.clips && PhoneApp.clips.length >= 3" 15
  $cl = Cdp-Obj '(PhoneApp.clips || []).map(function (c) { return c.id; })'
  Check "the phone's CLIPS list shows Paddock's own lap videos ($(@($cl).Count) here)" (@($cl) -contains $id7 -and @($cl) -contains $id6 -and @($cl) -contains $idC)
  $null = Cdp-Eval "PhoneApp.openClip('$idC'); true"
  $null = Wait-Until "document.querySelector('#shareBox [data-share-make]')" 10
  $btn = Cdp-Obj "(function(){ var b = document.querySelector('#shareBox [data-share-make]'); if (!b) return null; var r = b.getBoundingClientRect(); return { text: b.textContent, h: r.height, w: r.width }; })()"
  Check 'a lap without a share video offers MAKE SHARE VIDEO as a big button (44 px or more)' ($btn -and $btn.text -eq 'Make share video' -and $btn.h -ge 44)
  Cdp-Shot (Join-Path $shots 'share-phone-make.png')
  $null = Cdp-Eval "document.querySelector('#shareBox [data-share-make]').click(); true"
  $seen2 = New-Object System.Collections.Generic.List[string]; $sw2.Restart()
  while ($sw2.Elapsed.TotalSeconds -lt 90) { Start-Sleep -Milliseconds 400; $tx = [string](Cdp-Eval "(document.querySelector('#shareBox b.h') || {}).textContent"); if ($seen2.Count -eq 0 -or $seen2[$seen2.Count - 1] -ne $tx) { $seen2.Add($tx) }; if ($tx -eq 'Ready to share') { break } }
  Check "pressing it shows progress and ends at Ready to share ($($seen2 -join ' > '))" ($seen2[$seen2.Count - 1] -eq 'Ready to share' -and $seen2.Count -ge 2)
  $dl = Cdp-Obj "(function(){ var a = document.querySelector('#shareBox a[download]'), s = document.querySelector('#shareBox [data-share-send]'), ra = a.getBoundingClientRect(), rs = s.getBoundingClientRect(); return { href: a.getAttribute('href'), name: a.getAttribute('download'), text: a.textContent, ha: ra.height, hs: rs.height, scroll: document.documentElement.scrollWidth - window.innerWidth }; })()"
  Check 'then Save share video (a download of /share/video, a proper file name) and Share, both 44 px or more, no sideways scroll' ($dl.href -eq "/share/video?id=$idC" -and $dl.name -match '^paddock-.*-share\.mp4$' -and $dl.ha -ge 44 -and $dl.hs -ge 44 -and $dl.scroll -le 0)
  $null = Cdp-Eval "Object.defineProperty(navigator, 'canShare', { value: undefined, configurable: true }); document.querySelector('#shareBox [data-share-send]').click(); true"
  $null = Wait-Until "document.getElementById('toast') && !document.getElementById('toast').hidden && /Saved to Files/.test(document.getElementById('toast').textContent)" 20
  Check 'on plain http (no share sheet) Share saves the file and says so in plain words: "Saved to Files"' ((Cdp-Eval "document.getElementById('toast').textContent") -match 'Saved to Files')
  Cdp-Shot (Join-Path $shots 'share-phone-ready.png')
  Check 'no JS error in the phone app' ($script:cdp.errors.Count -eq 0)
  Cdp-Close
  #@@TAIL@@
}
finally {
  Remove-Item $hook -Force -ErrorAction SilentlyContinue; Remove-Item $lock -Force -ErrorAction SilentlyContinue
  Exit-TestLock
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8 } catch { }
  try { $null = J '/vault/test/sandbox?on=0' } catch { }
  if (-not $Keep) { try { Remove-Item $tdir -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
  try { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
"share-test: $pass passed, $fail failed. Pictures in $shots (share-*.png). $([math]::Round($swAll.Elapsed.TotalSeconds, 0)) s"
if ($fail -gt 0) { exit 1 }
