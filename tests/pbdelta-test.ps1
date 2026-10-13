# O5 test: the delta bar against the best lap you ever drove (VS PB). Out of the car; no iRacing session needed.
# Real telemetry files are only read. Pretend sessions (the test hook) are seen by irdash and its bar only; the pretend car and
# track are called "Test Car" / "Test Track", so Peter's real reference files in dash\refs are never touched.
#   1. a reference built from a real .ibt: the right lap, 2001 monotone points, the JSON fields, the banner text
#   2. the same lap driven through the live path (frames): delta 0 +- 0.01 s, the VS key order, a new best lap becomes the reference
#   3. pictures of the bar (tests\shots\pb-*.png)
#   4. the live logic on made-up frames, straight from the built program (pit start, tow, line glitch, an uncounted lap)
#   5. defaults: no delta_ref in the ini means PB; an explicit best stays best
# Pictures: pb-ahead.png, pb-behind.png, pb-outlap.png, pb-best-ahead.png (drawn in memory), pb-live.png, pb-live-outlap.png (the real bar on the middle screen).
#   powershell -ExecutionPolicy Bypass -File tests\pbdelta-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = 'http://localhost:8199'
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
function J($path) { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 20; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
function Get-Raw($path) {
  try { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 20; return @{ code = [int]$r.StatusCode; body = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) } }
  catch { $resp = $_.Exception.Response; if (-not $resp) { return @{ code = 0; body = $_.Exception.Message } }
    $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $b = $sr.ReadToEnd(); $sr.Dispose(); return @{ code = [int]$resp.StatusCode; body = $b } }
}
function Api($c, $a) { $u = "$api/api/do?c=$c" + $(if ($a) { "&a=$a" } else { '' }); $null = Invoke-WebRequest -UseBasicParsing $u -TimeoutSec 8 }
function Fake($q) { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?$q" -TimeoutSec 8 }
function Q($s) { [uri]::EscapeDataString($s) }
function Ini($key) { $m = Select-String -Path (Join-Path $root 'dash\irdash.ini') -Pattern "^$key=(.*)$" | Select-Object -First 1; if ($m) { $m.Matches[0].Groups[1].Value } else { $null } }
function Set-Ref($want) { for ($i = 0; $i -lt 6; $i++) { if ((J '/overlays').delta.ref -eq $want) { return }; Api 'deltaref'; Start-Sleep -Milliseconds 500 } }
function State { J '/pbref/state' }
$minus = [string][char]0x2212

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
}
'@ -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class PbT {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static IntPtr Find(string title) { IntPtr found = IntPtr.Zero; EnumWindows(delegate(IntPtr h, IntPtr l) { var t = new StringBuilder(256); GetWindowText(h, t, 256); if (t.ToString() == title) { found = h; return false; } return true; }, IntPtr.Zero); return found; }
}
'@
function Shot($name, $x, $y, $w, $h) {
  $bmp = New-Object System.Drawing.Bitmap $w, $h; $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h)); $path = Join-Path $shots "$name.png"; $bmp.Save($path); $g.Dispose(); $bmp.Dispose(); return $path
}
# green and red pixels of a picture (the bar's tone colours)
function Hot($path) {
  $bm = New-Object System.Drawing.Bitmap $path; $g = 0; $rd = 0
  for ($yy = 0; $yy -lt $bm.Height; $yy += 2) { for ($xx = 0; $xx -lt $bm.Width; $xx += 2) { $c = $bm.GetPixel($xx, $yy); if ($c.R -gt 200 -and $c.G -lt 110 -and $c.B -lt 110) { $rd++ } elseif ($c.G -gt 190 -and $c.R -lt 90 -and $c.B -lt 150) { $g++ } } }
  $bm.Dispose(); return @{ green = $g; red = $rd }
}

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; $title }
Enter-TestLock 'pbdelta'   # one live test at a time (tests\guard.ps1); released in finally
$lock = Join-Path $root 'dash\deploy.lock'
for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock (' + (Get-Content $lock) + ')'; Start-Sleep -Seconds 60 }
Set-Content $lock ('pbdelta ' + (Get-Date).ToString('HH:mm:ss'))
$hook = Join-Path $root 'dash\test-hook.on'
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$refOrig = Ini 'delta_ref'; $onOrig = Ini 'delta_bar'
$logN = (Get-Content (Join-Path $root 'dash\irdash.log') | Measure-Object).Count
$testRef = Join-Path $root 'dash\refs\test-car__test-track-test-layout.json'
'PB delta test'
try {

Section '0. irdash has the new code'
$st = Get-Raw '/pbref/state'
if ($st.code -ne 200) { Check 'irdash is running the build with /pbref (run dash\build.ps1 once, then this test)' $false; throw 'irdash is still the old build' }
Check 'irdash answers /pbref/state' $true

Section '1. a reference built from a real .ibt'
$s = J '/sessions'
$pb = @($s.pbs | Where-Object { $_.best -gt 15 } | Sort-Object { -[int]$_.sessions })[0]
Check "there is a timed combination to test with ($($pb.car) at $($pb.track), best $($pb.best))" ($pb -ne $null)
$u = "/pbref?car=$(Q $pb.car)&track=$(Q $pb.track)&config=$(Q $pb.config)&build=1&times=1"
$b = J $u; $ref = $b.ref
Check 'a reference came back' ($ref -ne $null -and $ref.t.Count -eq 2001)
Check "its time is your best lap from the sessions page ($($ref.time) / $($pb.best))" (Near $ref.time $pb.best 0.0011)
Check '2001 points (every 0.05 % of the lap), starting at 0 and ending at the lap time, never going backwards' ((Near $ref.t[0] 0 1e-9) -and (Near $ref.t[2000] $ref.time 0.002) -and (-not (1..2000 | Where-Object { $ref.t[$_] -lt $ref.t[$_ - 1] })))
Check 'no step is longer than a quarter second (a straight, no gap in the data)' (-not (1..2000 | Where-Object { $ref.t[$_] - $ref.t[$_ - 1] -gt 0.25 }))
Check 'the JSON has key, car, track, layout, source, file, lap, set, careerBest and banner' ((@('key','car','track','config','source','file','lap','set','careerBest','banner') | Where-Object { $ref.PSObject.Properties.Name -notcontains $_ }).Count -eq 0)
Check "the banner reads like 'PB 1:19.600 - set 9 Oct' ($($ref.banner))" ($ref.banner -match '^PB \d+:\d\d\.\d{3}\s+\S\s+set \d{1,2} [A-Z][a-z]{2}$')
Check 'the file name is <car>__<track>-<layout>.json in dash\refs' ((Test-Path (Join-Path $root "dash\refs\$($ref.key).json")) -and $ref.key -match '^[a-z0-9-]+__[a-z0-9-]+$')
if ($ref.source -eq 'ibt') {
  $lap = J "/ibt/lap?file=$(Q $ref.file)&lap=$($ref.lap)"
  $worst = 0.0; for ($g = 0; $g -le 1000; $g++) { $d = [math]::Abs($lap.t[$g] - $ref.t[2 * $g]); if ($d -gt $worst) { $worst = $d } }
  Check "the reference is that lap: against the lap analysis traces of the same lap the worst difference is $([math]::Round($worst, 4)) s (limit 0.01)" ($worst -lt 0.01)
} else { "  (the reference came from a live lap; the .ibt comparison is skipped)" }
# L-1: the reference is a lap iRacing COUNTED, checked against the raw records of its file (nothing of Paddock's code in the reader)
if ($ref.source -eq 'ibt') {
  $refFile = Join-Path $tel $ref.file
  Check "the reference lap ($($ref.file) lap $($ref.lap), $($ref.time)) is a lap iRacing counted, decided from the raw records of its file by iRacing's own best lap" ((Test-Path -LiteralPath $refFile) -and [LapRaw]::Counted($refFile, [int]$ref.lap, [double]$ref.time))
  Check "and its time is the career's best counted lap ($($pb.best)); a file from before the rule (rules $($ref.rules)) is kept only when it is that lap" ((Near $ref.time $pb.best 0.0011) -and ($ref.rules -ge 3 -or (Near $ref.time $pb.best 0.0006)))
  if ($ref.file -like '*2026-10-10 00-13-18*') { Check 'with the real files the PB reference is 1:19.549, lap 7 of the 2026-10-10 00:13:18 session' ($ref.lap -eq 7 -and (Near $ref.time 79.549 0.0006)) }
}

Section '2. the same lap through the live path (a pretend session: only irdash sees it)'
$origFile = if ($ref.source -eq 'ibt') { $ref.file } else { (J '/sessions').sessions | Where-Object { $_.file } | Select-Object -First 1 -ExpandProperty file }
$origLap = if ($ref.source -eq 'ibt') { $ref.lap } else { 2 }
$lapT = (J "/ibt/lap?file=$(Q $origFile)&lap=$origLap").t
Set-Content $hook 'on for the test'
$m = J "/api/test/pbref?file=$(Q $origFile)&lap=$origLap"
Check "a test reference was made for 'Test Car' (lap time $($m.ref.time))" ($m.ref.key -eq 'test-car__test-track-test-layout' -and (Test-Path $testRef))
$refT = $m.ref.time
Fake 'IsOnTrack=0&OnPitRoad=1&Lap=1&LapDistPct=0.5&Speed=0'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/session?file=$(Q $origFile)&rename=1" -TimeoutSec 10
Start-Sleep -Milliseconds 2500
$stt = State
Check 'the pretend session loads the reference of its own car and track' ($stt.hasRef -eq $true -and $stt.key -eq 'test-car__test-track-test-layout' -and (Near $stt.time $refT 0.001))
Set-Ref 'pb'
$ov = J '/overlays'
Check 'the deck/overlays JSON says the bar is on PB (ref, active, label, pb, y, text)' ($ov.delta.ref -eq 'pb' -and $ov.delta.active -eq 'pb' -and $ov.delta.label -eq 'VS PB' -and (Near $ov.delta.pb.time $refT 0.001) -and $ov.delta.pb.text -match '^PB ' -and $ov.delta.PSObject.Properties.Name -contains 'y' -and $ov.delta.PSObject.Properties.Name -contains 'text')
# the out lap: on track, no clean crossing yet -> no delta, but the bar is up with the PB line
Fake 'IsOnTrack=1&OnPitRoad=0&Lap=3&LapDistPct=0.5&LapCurrentLapTime=40&Speed=40'
Start-Sleep -Milliseconds 900
$stt = State
$hb = [PbT]::Find('irdash delta bar')
Check 'on the out lap there is no delta yet' ($stt.ok -eq $false -and $stt.flying -eq $false)
Check 'but the bar is up, with "-.---" and the PB line' ($hb -ne [IntPtr]::Zero -and [PbT]::IsWindowVisible($hb) -and (J '/overlays').delta.text -match "^\u2013\.")
$r = New-Object PbT+RECT; [void][PbT]::GetWindowRect($hb, [ref]$r)
$null = Shot 'pb-live-outlap' ($r.L - 20) ($r.T - 10) (($r.R - $r.L) + 40) (($r.B - $r.T) + 20)
# the line, then the whole lap
Fake 'Lap=3&LapDistPct=0.99&LapCurrentLapTime=80'; Start-Sleep -Milliseconds 250
Fake 'Lap=4&LapDistPct=0.002&LapCurrentLapTime=0.17'; Start-Sleep -Milliseconds 250
Check 'a clean crossing of the line starts the flying lap' ((State).flying -eq $true)
$worst = 0.0; $n = 0; $bad = 0; $shotDone = $false
for ($g = 10; $g -le 980; $g += 10) {
  Fake ("LapDistPct=" + ($g / 1000.0).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) + "&LapCurrentLapTime=" + $lapT[$g].ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))
  Start-Sleep -Milliseconds 150
  if ($g -lt 60) { continue }
  $x = State
  if (-not $x.ok) { $bad++; continue }
  $d = [math]::Abs([double]$x.delta); if ($d -gt $worst) { $worst = $d }; $n++
  if (-not $shotDone -and $g -ge 500) { $shotDone = $true; [void][PbT]::GetWindowRect($hb, [ref]$r); $null = Shot 'pb-live' ($r.L - 20) ($r.T - 10) (($r.R - $r.L) + 40) (($r.B - $r.T) + 20) }
}
Check "replaying the reference lap itself: the delta stays within 0.01 s (worst $([math]::Round($worst, 4)) s over $n samples, $bad without a value)" ($worst -lt 0.01 -and $bad -eq 0 -and $n -gt 30)
Check 'the bar text is a signed delta and the predicted lap, about the reference time' ((J '/overlays').delta.text -match "^[+$minus]0\.0\d\d \d:\d\d\.\d{3}$")
Check 'the real bar window is not the front window' ([PbT]::GetForegroundWindow() -ne $hb)

# the VS key: pb > best > optimal > session > pb (a personal best exists here)
$seq = @(); for ($i = 0; $i -lt 4; $i++) { Api 'deltaref'; Start-Sleep -Milliseconds 450; $seq += (J '/overlays').delta.ref }
Check "the VS key cycles $($seq -join ' > ')" (($seq -join ',') -eq 'best,optimal,session,pb')
Check 'and the choice is saved in irdash.ini' ((Ini 'delta_ref') -eq 'pb')
Api 'deltaref'; Start-Sleep -Milliseconds 400; $ovb = J '/overlays'
Check 'on BEST the label and the active reference change, the PB is still listed' ($ovb.delta.ref -eq 'best' -and $ovb.delta.label -eq 'VS BEST' -and $ovb.delta.pb -ne $null)
Set-Ref 'pb'

# a new best lap: the reference follows, no restart (needs iRacing's own best-lap time to say it was counted)
$fast = [math]::Round($refT - 0.8, 3)
Fake 'Lap=4&LapDistPct=0.99&LapCurrentLapTime=80'; Start-Sleep -Milliseconds 250
# iRacing's lap timer can still show the last lap's time for a frame or two after the line: that must not spoil the reference
Fake 'Lap=5&LapDistPct=0.0007&LapCurrentLapTime=79.4'; Start-Sleep -Milliseconds 150
Fake 'LapDistPct=0.002&LapCurrentLapTime=0.17'; Start-Sleep -Milliseconds 250
for ($g = 10; $g -le 990; $g += 10) {
  Fake ("LapDistPct=" + ($g / 1000.0).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) + "&LapCurrentLapTime=" + ($lapT[$g] * $fast / $refT).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))
  Start-Sleep -Milliseconds 70
}
Fake ("Lap=6&LapDistPct=0.003&LapCurrentLapTime=0.2&LapLastLapTime=$fast&LapBestLapTime=$fast"); Start-Sleep -Milliseconds 2500
$stt = State
Check "after the line the faster lap is the reference ($($stt.time), source $($stt.source))" ((Near $stt.time $fast 0.002) -and $stt.source -eq 'live')
$saved = Get-Content $testRef -Raw | ConvertFrom-Json
Check 'and it is saved to the reference file (source live, 2001 points)' ($saved.source -eq 'live' -and $saved.t.Count -eq 2001 -and (Near $saved.time $fast 0.002))
$jump = 0.0; for ($i = 1; $i -le 2000; $i++) { $d = [double]$saved.t[$i] - [double]$saved.t[$i - 1]; if ($d -gt $jump) { $jump = $d } }
Check "the saved reference has no jump or hole (its largest step between two points is $([math]::Round($jump, 3)) s; a lap of this length has steps of about 0.04 s)" ($jump -lt 0.3)
Check 'the banner and the bar JSON follow, without restarting anything' ((J '/overlays').delta.pb.text -match [regex]::Escape(([TimeSpan]::FromSeconds($fast)).ToString('m\:ss\.fff')))
# against the new reference the same fast lap reads about zero
Fake 'Lap=6&LapDistPct=0.99&LapCurrentLapTime=80'; Start-Sleep -Milliseconds 250
Fake 'Lap=7&LapDistPct=0.002&LapCurrentLapTime=0.17'; Start-Sleep -Milliseconds 250
$w2 = 0.0
for ($g = 100; $g -le 900; $g += 100) {
  Fake ("LapDistPct=" + ($g / 1000.0).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) + "&LapCurrentLapTime=" + ($lapT[$g] * $fast / $refT).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)); Start-Sleep -Milliseconds 250
  $d = [math]::Abs([double](State).delta); if ($d -gt $w2) { $w2 = $d }
}
Check "driving that lap again against the new reference: about 0 (worst $([math]::Round($w2, 3)) s; the samples are 10 % apart, so a few hundredths are fair)" ($w2 -lt 0.05)
# a lap iRacing did not count (its best-lap time says something else) must not replace it
$slow = [math]::Round($fast - 0.5, 3)
Fake 'Lap=7&LapDistPct=0.99&LapCurrentLapTime=80'; Start-Sleep -Milliseconds 250
Fake 'Lap=8&LapDistPct=0.002&LapCurrentLapTime=0.17'; Start-Sleep -Milliseconds 250
for ($g = 10; $g -le 990; $g += 10) { Fake ("LapDistPct=" + ($g / 1000.0).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) + "&LapCurrentLapTime=" + ($lapT[$g] * $slow / $refT).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)); Start-Sleep -Milliseconds 70 }
Fake ("Lap=9&LapDistPct=0.003&LapCurrentLapTime=0.2&LapLastLapTime=$slow&LapBestLapTime=$fast"); Start-Sleep -Milliseconds 2200
Check 'a fast lap that iRacing did not count (its session best is another time) leaves the reference alone' (Near (State).time $fast 0.002)

Section '3. pictures of the bar (drawn in memory, nothing appears on a screen)'
$dot = [string][char]0xB7
$cases = @(
  @{ n = 'pb-ahead';      q = "name=pb-ahead&delta=-0.214&pred=79.386&ref=0&banner=$(Q ("PB 1:19.600  $dot  set 9 Oct"))"; green = $true },
  @{ n = 'pb-behind';     q = "name=pb-behind&delta=0.412&pred=80.012&ref=0"; red = $true },
  @{ n = 'pb-outlap';     q = "name=pb-outlap&ref=0&banner=$(Q ("PB 1:19.600  $dot  set 9 Oct"))" },
  @{ n = 'pb-best-ahead'; q = "name=pb-best-ahead&delta=-0.068&pred=79.9&ref=1"; green = $true })
foreach ($c in $cases) {
  $o = J "/api/delta/snapshot?$($c.q)"; $f = Join-Path $shots "$($c.n).png"
  $im = [System.Drawing.Image]::FromFile($f); $wh = "$($im.Width)x$($im.Height)"; $im.Dispose()
  $hot = Hot $f
  $okTone = if ($c.green) { $hot.green -gt 150 -and $hot.red -lt 60 } elseif ($c.red) { $hot.red -gt 150 -and $hot.green -lt 60 } else { $hot.green -lt 60 -and $hot.red -lt 60 }
  Check "$($c.n).png is $wh and has the right colour (green $($hot.green), red $($hot.red))" ($wh -eq '560x156' -and $okTone)
}
$bm = New-Object System.Drawing.Bitmap (Join-Path $shots 'pb-outlap.png'); $bm2 = New-Object System.Drawing.Bitmap (Join-Path $shots 'pb-behind.png')
$lower = 0; for ($xx = 150; $xx -lt 410; $xx += 4) { if ($bm.GetPixel($xx, 145).R -ne $bm2.GetPixel($xx, 145).R) { $lower++ } }
Check 'the out-lap picture carries the "PB ... set ..." line under the bar; the others do not' ($lower -gt 20)
$bm.Dispose(); $bm2.Dispose()

Section '4. the live logic on made-up frames (the built program, no irdash needed)'
$exe = Join-Path $root 'dash\irdash.exe'
$asm = [Reflection.Assembly]::LoadFile($exe); $bf = [Reflection.BindingFlags]'Static,Public,NonPublic'
function T($name) { $asm.GetType("IRDash.$name") }
function Call($type, $method, [object[]]$a) { (T $type).GetMethod($method, $bf).Invoke($null, $a) }
function SetStatic($type, $field, $value) { (T $type).GetField($field, $bf).SetValue($null, $value) }
function GetStatic($type, $field) { (T $type).GetField($field, $bf).GetValue($null) }
SetStatic 'Log' 'FilePath' (Join-Path $env:TEMP 'pbdelta-test-harness.log')
SetStatic 'TrackMaps' 'TelemetryDir' $tel; SetStatic 'Career' 'TelemetryDir' $tel; SetStatic 'Career' 'CacheFile' (Join-Path $root 'dash\career-cache.tsv')
$scratch = Join-Path $env:TEMP 'pbdelta-test-refs'; Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $scratch | Out-Null
SetStatic 'PbRef' 'Dir' $scratch
# maths
$n2 = 400; $p = [float[]]::new($n2); $tt = [float[]]::new($n2)
for ($i = 0; $i -lt $n2; $i++) { $p[$i] = [float](0.001 + $i * 0.0025); $tt[$i] = [float](84 * $p[$i]) }
$arr = (T 'PbRef').GetMethod('FromSamples', $bf).Invoke($null, [object[]]@($p, $tt, [int]$n2, [double]84.0))
Check 'samples of a lap at even speed make the straight-line reference (0 at the line, the lap time at the end, 42 s at half way)' ((Near $arr[0] 0 1e-9) -and (Near $arr[2000] 84 1e-9) -and (Near $arr[1000] 42 0.001))
$pS = [float[]]::new(60); $tS = [float[]]::new(60); for ($i = 0; $i -lt 60; $i++) { $pS[$i] = [float](0.0007 + $i * 0.0166); $tS[$i] = [float](84 * $pS[$i]) }; $tS[0] = [float]79.4     # the first frame after the line still shows the last lap's time
$arrS = (T 'PbRef').GetMethod('TestFromSamples', $bf).Invoke($null, [object[]]@($pS, $tS, [int]60, [double]84.0))
Check 'a stale lap timer in the first frame after the line is dropped: the reference stays believable (no jump in its first 0.05 %)' ($arrS -ne $null -and $arrS[1] -lt 0.2 -and (Near $arrS[1000] 42 0.05))
$tB = [float[]]::new(60); for ($i = 0; $i -lt 60; $i++) { $tB[$i] = [float](84 - $i) }       # a timer running backwards is no lap
$arrB = (T 'PbRef').GetMethod('TestFromSamples', $bf).Invoke($null, [object[]]@($pS, $tB, [int]60, [double]84.0))
Check 'samples whose timer runs backwards give no reference at all (the old one stays)' ($arrB -eq $null)
Check 'At() reads between two points in a straight line' ((Near ((T 'PbRef').GetMethod('At', $bf).Invoke($null, [object[]]@($arr, [double]0.7777))) (84 * 0.7777) 0.002))
# a made-up PB reference from the best real lap, then frames
$a = [object[]]@($pb.car, $pb.track, $pb.config, '')
$refObj = (T 'PbRef').GetMethod('BuildFromIbt', $bf).Invoke($null, $a)
Check 'the program itself builds the reference from the best .ibt (same lap time)' ($refObj -ne $null -and (Near $refObj.Time $pb.best 0.0011))
# L-1: the program never picks a lap iRacing did not count. 2026-10-06 21-26-58: lap 3 (79.897) is its quickest timed lap but has off-track records and iRacing's best lap
# never became it (it stayed 80.228, lap 14): asking for the lap at 79.897 finds nothing (no reference from that file), asking for 80.228 finds lap 14.
$f7p = [string](Join-Path $tel 'chevyvettez06rgt3_roadatlanta full 2026-10-06 21-26-58.ibt')
if (Test-Path -LiteralPath $f7p) {
  $ibtT = T 'IbtLaps'
  $rUn = $ibtT.GetMethod('Reference', $bf).Invoke($null, [object[]]@($f7p, [double]79.897, [double]0.011, [int]2000))
  $rOk = $ibtT.GetMethod('Reference', $bf).Invoke($null, [object[]]@($f7p, [double]80.228, [double]0.011, [int]2000))
  Check 'IbtLaps.Reference will not pick a lap iRacing did not count: the 79.897 lap (off-track, its best never became it) gives no reference; the 80.228 lap (lap 14, counted) does' ($rUn -eq $null -and $rOk -ne $null -and $rOk.Lap -eq 14 -and (Near $rOk.Time 80.228 0.0011) -and [LapRaw]::Counted($f7p, 14, 80.228) -and -not [LapRaw]::Counted($f7p, 3, 79.897))
}
# a reference file from before the lap rule that is quicker than the quickest lap iRacing counted is not used; live references, newer files and the made-up test car are kept
$rdT = $asm.GetType('IRDash.RefData'); $nc = (T 'PbRef').GetMethod('NotCounted', $bf)
function Legacy($time, $src, $rules) { $r = [Activator]::CreateInstance($rdT); $r.Time = $time; $r.Source = $src; $r.Rules = $rules; return $r }
Check 'an old ibt reference quicker than the best counted lap (79.0 against 79.549) is "not counted" and is built again; a live one, a new one, a slower one, and any when the career knows no best are kept' ($nc.Invoke($null, [object[]]@((Legacy 79.0 'ibt' 0), [double]79.549)) -eq $true -and $nc.Invoke($null, [object[]]@((Legacy 79.0 'live' 0), [double]79.549)) -eq $false -and $nc.Invoke($null, [object[]]@((Legacy 79.0 'ibt' 3), [double]79.549)) -eq $false -and $nc.Invoke($null, [object[]]@((Legacy 79.549 'ibt' 0), [double]79.549)) -eq $false -and $nc.Invoke($null, [object[]]@((Legacy 80.1 'ibt' 0), [double]79.549)) -eq $false -and $nc.Invoke($null, [object[]]@((Legacy 79.0 'ibt' 0), [double]0)) -eq $false)
$ciT = $asm.GetType('IRDash.Combo+Info'); $ci = [Activator]::CreateInstance($ciT); $ci.Car = $refObj.Car; $ci.Track = $refObj.Track; $ci.Config = $refObj.Config
$ibtPath = [IO.Path]::Combine($tel, [string]$refObj.File)
$lapJson = (T 'IbtLaps').GetMethod('LapJson', $bf).Invoke($null, [object[]]@($ibtPath, [int]$refObj.Lap)) | ConvertFrom-Json
$tr = $lapJson.t
$vNames = 'IsOnTrack', 'OnPitRoad', 'Lap', 'LapDistPct', 'LapCurrentLapTime', 'LapLastLapTime', 'LapBestLapTime'; $types = 1, 1, 2, 4, 4, 4, 4
$script:seq = 0
function MakeFrame($vals) {
  $f = [Activator]::CreateInstance((T 'Frame')); $f.Connected = $true; $f.SessionVersion = 1; $f.SessionYaml = ''; $f.Data = New-Object byte[] 128
  $dict = [Activator]::CreateInstance(([System.Collections.Generic.Dictionary`2]).MakeGenericType([string], $asm.GetType('IRDash.VarDef')))
  for ($i = 0; $i -lt $vNames.Count; $i++) {
    $d = [Activator]::CreateInstance((T 'VarDef')); $d.Name = $vNames[$i]; $d.Type = $types[$i]; $d.Offset = $i * 8; $d.Count = 1; $dict.Add($vNames[$i], $d)
    $v = [double]$vals[$vNames[$i]]
    switch ($types[$i]) { 1 { $f.Data[$d.Offset] = [byte]($v -ne 0) } 2 { [BitConverter]::GetBytes([int]$v).CopyTo($f.Data, $d.Offset) } 4 { [BitConverter]::GetBytes([single]$v).CopyTo($f.Data, $d.Offset) } }
  }
  $f.Vars = $dict; $script:seq++; $f.Seq = $script:seq; return $f
}
$tick = (T 'PbRef').GetMethod('Tick', $bf)
function Tick($vals, $now) { $f = MakeFrame $vals; $on = [bool]($vals.IsOnTrack -ne 0); $pit = $on -and ($vals.OnPitRoad -ne 0); [void]$tick.Invoke($null, [object[]]@($f, $on, $pit, $now)) }
function V($lap, $pct, $cur, $pit = 0, $last = 0, $best = 0) { @{ IsOnTrack = 1; OnPitRoad = $pit; Lap = $lap; LapDistPct = $pct; LapCurrentLapTime = $cur; LapLastLapTime = $last; LapBestLapTime = $best } }
function St($nm) { GetStatic 'PbRef' $nm }
$base = [DateTime]::Now
Tick @{ IsOnTrack = 0; OnPitRoad = 0; Lap = 0; LapDistPct = 0; LapCurrentLapTime = 0; LapLastLapTime = 0; LapBestLapTime = 0 } $base      # the connection
SetStatic 'PbRef' 'current' $refObj; SetStatic 'PbRef' 'curKey' $refObj.Key; SetStatic 'PbRef' 'combo' $ci

Tick (V 1 0.995 80.0) $base; Tick (V 2 0.002 0.04) $base.AddSeconds(0.1)
$worst = 0.0; $notOk = 0
for ($g = 1; $g -le 1000; $g++) { Tick (V 2 ($g / 1000.0) $tr[$g]) $base.AddSeconds(0.1 + $tr[$g]); if ($g -lt 6 -or $g -gt 996) { continue }; if (-not (St 'Ok')) { $notOk++; continue }; $d = [math]::Abs([double](St 'Delta')); if ($d -gt $worst) { $worst = $d } }
Check "frames of the reference lap itself, 1001 of them: delta within 0.01 s (worst $([math]::Round($worst, 4)) s)" ($worst -lt 0.01 -and $notOk -eq 0)
Tick (V 3 0.003 0.05) $base.AddSeconds(1000); Check 'a finished clean lap counts (the first-lap line stops after it)' ((St 'FlyingDone') -ge 1)
foreach ($off in @(-1.0, 0.5)) {
  Tick (V 5 0.995 80.0) $base.AddSeconds(2000); Tick (V 6 0.002 0.04) $base.AddSeconds(2000.1); $w = 0.0
  for ($g = 20; $g -le 900; $g += 20) { Tick (V 6 ($g / 1000.0) ([math]::Max(0.1, $tr[$g] + $off))) $base.AddSeconds(2000.1 + $tr[$g]); if ($g -lt 120) { continue }; $e = [math]::Abs([double](St 'Delta') - $off); if ($e -gt $w) { $w = $e } }
  Check "a lap $off s from the reference reads $off s (worst error $([math]::Round($w, 3)) s)" ($w -lt 0.05)
}
Tick (V 9 0.5 40.0 1) $base.AddSeconds(3000); Tick (V 10 0.001 0.02 1) $base.AddSeconds(3000.1); Tick (V 10 0.02 3.0 0) $base.AddSeconds(3003)
Check 'a lap that began on pit road (the out lap) gets no delta' ((St 'Ok') -eq $false)
Tick (V 10 0.99 80.0 0) $base.AddSeconds(3080); Tick (V 11 0.002 0.04 0) $base.AddSeconds(3080.1)
Check 'the next lap, started on track, does' ((St 'Flying') -eq $true)
Tick (V 11 0.30 24.0) $base.AddSeconds(3100); Tick (V 11 0.70 30.0) $base.AddSeconds(3100.1)
Check 'a jump in lap distance (tow, reset) takes the delta away for the rest of that lap' ((St 'Flying') -eq $false -and (St 'Ok') -eq $false)
Tick (V 12 0.99 80.0) $base.AddSeconds(3200); Tick (V 13 0.002 0.04) $base.AddSeconds(3200.1)
for ($g = 20; $g -le 60; $g += 20) { Tick (V 13 ($g / 1000.0) $tr[$g]) $base.AddSeconds(3200.1 + $tr[$g]) }
$before = [double](St 'Delta'); Tick (V 13 0.9999 0.02) $base.AddSeconds(3200.2 + $tr[60])
Check 'the line glitch (distance says end of lap, the timer says a moment after the line) makes no spike' ([math]::Abs([double](St 'Delta') - $before) -lt 0.5)
# the defaults
$cfgT = T 'DeltaBar'; $conf = $cfgT.GetMethod('Configure', $bf)
$iniScratch = Join-Path $env:TEMP 'pbdelta-test.ini'; $pgm = T 'Program'
Section '5. which reference a fresh install starts on'
Set-Content $iniScratch "port=8199`r`ndelta_bar=1`r`n"; $pgm.GetField('IniFile', $bf).SetValue($null, $iniScratch)
[void]$conf.Invoke($null, [object[]]@($true, 'best', 'center,160', 1.0))
Check 'an ini that never named a reference starts on PB' ((GetStatic 'DeltaBar' 'Ref') -eq 'pb')
Set-Content $iniScratch "port=8199`r`ndelta_ref=best`r`n"
[void]$conf.Invoke($null, [object[]]@($true, 'best', 'center,160', 1.0))
Check 'an ini that says best stays on best' ((GetStatic 'DeltaBar' 'Ref') -eq 'best')
Set-Content $iniScratch "delta_ref=optimal`r`n"; [void]$conf.Invoke($null, [object[]]@($true, 'optimal', 'center,160', 1.0))
Check 'optimal and session are kept as chosen' ((GetStatic 'DeltaBar' 'Ref') -eq 'optimal')
Remove-Item $iniScratch -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue

Section '6. nothing is left behind'
}
finally {
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/pbclear" -TimeoutSec 5 } catch { }
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 5 } catch { }
  Start-Sleep -Milliseconds 600
  try { if ($refOrig) { Set-Ref $refOrig } } catch { }
  Remove-Item -LiteralPath $hook -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
  Exit-TestLock
}
Check 'the test reference file is gone (your real reference files were never touched)' (-not (Test-Path $testRef))
Check 'the test hook is switched off again' (-not (Test-Path $hook))
Check 'the deploy lock is released' (-not (Test-Path $lock))
Check 'the delta settings are as they were' ((Ini 'delta_ref') -eq $refOrig -and (Ini 'delta_bar') -eq $onOrig)
$lg = @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logN)
Check 'the log says the bar was never the front window' (@($lg | Where-Object { $_ -match 'delta bar: the bar is the front window' }).Count -eq 0)
''
"$pass passed, $fail failed. Pictures in $shots"
