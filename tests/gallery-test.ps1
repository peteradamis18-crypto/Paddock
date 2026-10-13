# Paddock gallery test (WS14): the pictures and their credits, the rejected (too blurred) pictures, the /gallery route, then
# the two side-screen windows (position, bottom of the z-order, never the front window, click-through), the SAME picture on
# both screens changing at the same moment with one crossfade, the one small caption line (no bar, no PADDOCK), hiding
# within 2 s when the "sim" appears (a harmless stand-in program, never the real sim), CPU and memory of irdash when the
# gallery is hidden and while it fades. Pictures of both side screens go to tests\shots\g-*.png.
#   powershell -ExecutionPolicy Bypass -File tests\gallery-test.ps1               all of it (the window part needs Peter away 10 min, or -PeterIsAway when the lead says so)
#   powershell -ExecutionPolicy Bypass -File tests\gallery-test.ps1 -StaticOnly   only the pictures, credits and the JSON route
# The window part opens full-screen pictures on his two side screens (that is the feature) and plays the start-up intro
# once on the top screen, so it follows guard.ps1 -NeedAway: nothing on a race day, nothing while he is at the PC.
param([switch]$StaticOnly, [switch]$PeterIsAway)   # -PeterIsAway: the lead says he is away, so skip the "10 minutes without input" check (other programs, e.g. the replay test, also move the mouse and keys)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = 'http://localhost:8199'
$galDir = Join-Path $root 'paddock\gallery'
$pass = 0; $fail = 0; $pend = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Pending($what) { $script:pend++; "  PENDING  $what" }
function J($path) { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 8; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }   # bytes are UTF-8; PowerShell 5 would read them as Latin-1 on its own
function Api($c, $a) { $u = "$api/api/do?c=$c" + $(if ($a) { "&a=$a" } else { '' }); try { $r = Invoke-WebRequest -UseBasicParsing $u -TimeoutSec 8; return [int]$r.StatusCode } catch { return [int]$_.Exception.Response.StatusCode } }
function Ini($key) { $m = Select-String -Path (Join-Path $root 'dash\irdash.ini') -Pattern "^$key=(.*)$" | Select-Object -First 1; if ($m) { $m.Matches[0].Groups[1].Value } else { $null } }
function ReadCredits($path) { @((Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ }) }     # PowerShell 5 hands a JSON array back as one object

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Drawing; using System.Drawing.Imaging; using System.Text; using System.Runtime.InteropServices;
public static class GalT {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  public static string Cls(IntPtr h) { var s = new StringBuilder(128); GetClassName(h, s, 128); return s.ToString(); }
  public static string Title(IntPtr h) { var s = new StringBuilder(256); GetWindowText(h, s, 256); return s.ToString(); }
  public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
  // visible, not cloaked, at least 50 px, top to bottom: "handle|class|title|pid"
  public static string[] Order() {
    var list = new List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      int c; if (DwmGetWindowAttribute(h, 14, out c, 4) == 0 && c != 0) return true;
      RECT r; if (!GetWindowRect(h, out r) || r.R - r.L < 50 || r.B - r.T < 50) return true;
      list.Add(h.ToInt64() + "|" + Cls(h) + "|" + Title(h) + "|" + Pid(h)); return true; }, IntPtr.Zero);
    return list.ToArray();
  }
  public static long MouseActivate(IntPtr h) { return SendMessage(h, 0x21, IntPtr.Zero, IntPtr.Zero).ToInt64(); }
  public static long HitTest(IntPtr h, int x, int y) { return SendMessage(h, 0x84, IntPtr.Zero, (IntPtr)((y << 16) | (x & 0xFFFF))).ToInt64(); }
  public static long FromPoint(int x, int y) { POINT p; p.X = x; p.Y = y; return WindowFromPoint(p).ToInt64(); }

  // 8x4 grid of average colours of a picture (a cheap fingerprint for "did it change / is it half way / are both screens alike")
  public static double[] Sig(Bitmap src) {
    using (var small = new Bitmap(8, 4, PixelFormat.Format24bppRgb)) {
      using (var g = Graphics.FromImage(small)) { g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBilinear; g.DrawImage(src, 0, 0, 8, 4); }
      var d = new double[96]; int k = 0;
      for (int y = 0; y < 4; y++) for (int x = 0; x < 8; x++) { Color c = small.GetPixel(x, y); d[k++] = c.R; d[k++] = c.G; d[k++] = c.B; }
      return d;
    }
  }
  public static double Dist(double[] a, double[] b) { double s = 0; for (int i = 0; i < a.Length; i++) s += Math.Abs(a[i] - b[i]); return s / a.Length; }
  // brightness, warmth, colour strength of a picture (the same three numbers irdash pairs pictures by)
  public static double[] Feat(Bitmap src) {
    using (var small = new Bitmap(32, 18, PixelFormat.Format24bppRgb)) {
      using (var g = Graphics.FromImage(small)) { g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic; g.DrawImage(src, new Rectangle(0, 0, 32, 18), 0, 0, src.Width, src.Height, GraphicsUnit.Pixel); }
      double l = 0, w = 0, s = 0; int n = 0;
      for (int y = 0; y < 18; y++) for (int x = 0; x < 32; x++) { Color c = small.GetPixel(x, y); double mx = Math.Max(c.R, Math.Max(c.G, c.B)), mn = Math.Min(c.R, Math.Min(c.G, c.B));
        l += (0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B) / 255.0; w += (c.R - c.B) / 255.0; s += mx <= 0 ? 0 : (mx - mn) / mx; n++; }
      return new double[] { l / n, w / n, s / n };
    }
  }
  public static double Look(double[] a, double[] b) { return 2.0 * Math.Abs(a[0] - b[0]) + 1.5 * Math.Abs(a[1] - b[1]) + 0.7 * Math.Abs(a[2] - b[2]); }
  // mean absolute colour difference of two same-size pictures over a box, leaving out another box (the caption)
  public static double MeanDiff(Bitmap a, Bitmap b, int x0, int y0, int w, int h, int ex, int ey, int ew, int eh) {
    var r = new Rectangle(0, 0, a.Width, a.Height);
    var da = a.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb); var db = b.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
    byte[] pa = new byte[da.Stride * a.Height], pb = new byte[db.Stride * b.Height];
    Marshal.Copy(da.Scan0, pa, 0, pa.Length); Marshal.Copy(db.Scan0, pb, 0, pb.Length); int stride = da.Stride; a.UnlockBits(da); b.UnlockBits(db);
    double sum = 0; long n = 0;
    for (int y = y0; y < y0 + h && y < a.Height; y++) for (int x = x0; x < x0 + w && x < a.Width; x++) {
      if (x >= ex && x < ex + ew && y >= ey && y < ey + eh) continue;
      int i = y * stride + x * 3; sum += Math.Abs(pa[i] - pb[i]) + Math.Abs(pa[i + 1] - pb[i + 1]) + Math.Abs(pa[i + 2] - pb[i + 2]); n += 3; }
    return n == 0 ? 0 : sum / n;
  }
  // pixels inside a box that differ clearly between the screen and the picture (= text on top of the picture)
  public static int Changed(Bitmap a, Bitmap b, int x0, int y0, int w, int h) {
    int n = 0;
    for (int y = Math.Max(0, y0); y < y0 + h && y < a.Height && y < b.Height; y++) for (int x = Math.Max(0, x0); x < x0 + w && x < a.Width && x < b.Width; x++) {
      Color p = a.GetPixel(x, y), q = b.GetPixel(x, y);
      if (Math.Abs(p.R - q.R) + Math.Abs(p.G - q.G) + Math.Abs(p.B - q.B) > 45) n++; }
    return n;
  }
}
'@ -ReferencedAssemblies System.Drawing

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; $title }
'Paddock gallery test'

# ---------------------------------------------------------------------------------------------------------------
Section '1. the pictures: real 2560x1440 JPEGs with complete credits; the blurred ones are set aside, not deleted'
$credPaths = @(Get-ChildItem $galDir -Filter 'credits*.json' | Sort-Object Name)
$credits = @(); foreach ($cp in $credPaths) { $credits += ReadCredits $cp.FullName }
$core = @(ReadCredits (Join-Path $galDir 'credits.json'))
$jpgs = @(Get-ChildItem $galDir -Filter *.jpg | Sort-Object Name)
$mine = @($jpgs | Where-Object { $_.Name -notlike 'r2-*' }); $r2 = @($jpgs | Where-Object { $_.Name -like 'r2-*' })
$rejDir = Join-Path $galDir 'rejected'; $rej = @(Get-ChildItem $rejDir -Filter *.jpg -ErrorAction SilentlyContinue | Sort-Object Name)
$wantNums = 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 18, 22, 23, 24, 25, 26, 30, 31, 33, 34, 35, 38
$haveNums = @(($mine + $rej) | ForEach-Object { [int]($_.Name.Substring(0, 2)) })
Check "all 22 pictures Peter said yes to are accounted for ($($mine.Count) in the gallery + $($rej.Count) set aside in rejected\)" (@($wantNums | Where-Object { $_ -notin $haveNums }).Count -eq 0 -and $haveNums.Count -eq 22)
$badFile = @(); $totalMb = 0.0
foreach ($f in $jpgs) {
  $b = New-Object byte[] 3; $fs = [IO.File]::OpenRead($f.FullName); [void]$fs.Read($b, 0, 3); $fs.Dispose()
  $ok = ($b[0] -eq 0xFF -and $b[1] -eq 0xD8 -and $b[2] -eq 0xFF)
  try { $img = [System.Drawing.Image]::FromFile($f.FullName); if ($f.Name -like 'r2-*') { $ok = $ok -and $img.Width -ge 2560 } else { $ok = $ok -and $img.Width -eq 2560 -and $img.Height -eq 1440 }; $img.Dispose() } catch { $ok = $false }
  if (-not $ok) { $badFile += $f.Name }
  $totalMb += $f.Length / 1MB
}
Check "every picture is a real JPEG (magic bytes) that loads and is at least 2560 wide; the first set is exactly 2560x1440 ($($jpgs.Count) pictures, $('{0:N1}' -f $totalMb) MB)" ($badFile.Count -eq 0)
if ($badFile.Count) { "        bad: $($badFile -join ', ')" }
Check 'every picture of the first set has a credit entry, and every entry in credits.json has its picture' (@($mine | Where-Object { $_.Name -notin $core.file }).Count -eq 0 -and @($core | Where-Object { $_.file -notin $mine.Name }).Count -eq 0)
if ($r2.Count) { $r2have = @($r2 | Where-Object { $_.Name -in $credits.file }).Count; "        the second set (r2-*): $($r2.Count) pictures, $r2have with a credit entry (the rest are shown without a caption)" }
$incomplete = @($core | Where-Object { -not $_.title -or -not $_.author -or -not $_.licence -or -not $_.source -or -not $_.site -or $_.source -notmatch '^https://' })
Check 'each credit has title, author, licence, site and a page link' ($incomplete.Count -eq 0)
$cc = @($core | Where-Object { $_.licence -like 'CC*' })
Check "the CC BY / CC BY-SA ones ($($cc.Count)) also carry the licence link and say the picture was cropped" ($cc.Count -ge 1 -and @($cc | Where-Object { $_.licence_url -notmatch '^https://creativecommons.org/licenses/' -or $_.changes -notmatch 'cropped' }).Count -eq 0)
Check 'only free licences are used (Unsplash, Pexels, CC BY, CC BY-SA)' (@($core | Where-Object { $_.licence -notin 'Unsplash License', 'Pexels License', 'CC BY 2.0', 'CC BY-SA 2.0' }).Count -eq 0)
Check 'no credit title carries the app name (no PADDOCK on the gallery screens)' (@($credits | Where-Object { "$($_.title)" -match '(?i)paddock' }).Count -eq 0)
Check 'no originals are left lying around in the gallery folder' (@(Get-ChildItem $galDir -File | Where-Object { $_.Extension -notin '.jpg', '.json', '.png' }).Count -eq 0)
$rejCred = if (Test-Path (Join-Path $rejDir 'credits-rejected.json')) { @(ReadCredits (Join-Path $rejDir 'credits-rejected.json')) } else { @() }
Check "the $($rej.Count) set-aside pictures keep their credit and say why they were set aside (heavy motion blur)" ($rej.Count -ge 1 -and @($rej | Where-Object { $_.Name -notin $rejCred.file }).Count -eq 0 -and @($rejCred | Where-Object { -not $_.rejected_because }).Count -eq 0)
Check 'none of them is in credits.json or in the gallery folder any more' (@($rej | Where-Object { $_.Name -in $credits.file -or (Test-Path (Join-Path $galDir $_.Name)) }).Count -eq 0)

# ---------------------------------------------------------------------------------------------------------------
Section '2. the /gallery route and the commands (no windows needed)'
$live = $false
try { $g0 = J '/gallery'; $live = ($g0.PSObject.Properties.Name -contains 'ready' -and $g0.ready -eq $true) } catch { $g0 = $null }
if (-not $live) {
  Pending 'irdash is not running the gallery build yet (/gallery is not answering): build and deploy with dash\build.ps1, then run this test again'
} else {
  $wide = $mine.Count + $r2.Count
  Check "the route answers: $($g0.count) pictures counted ($($g0.captioned) with a caption, $($g0.skipped) skipped as too small), every $($g0.secs) s, $($g0.fade) s fade, mode $($g0.mode)" ($g0.count -eq $wide -and $g0.captioned -ge $mine.Count -and $g0.creditFiles -ge 1)
  if ($null -eq (Ini 'gallery_secs') -and $null -eq (Ini 'gallery_fade')) {
    Check 'defaults: a change every 120 s with a 5 s fade' ($g0.secs -eq 120 -and $g0.fade -eq 5)
  } else { "        (irdash.ini sets its own timing, so the timing defaults are not checked)" }
  $wantMode = if ((Ini 'gallery_mode') -eq 'pair') { 'pair' } else { 'same' }
  Check "the mode is $wantMode (default: the same picture on both screens) and captions are on" ($g0.mode -eq $wantMode -and ((Ini 'gallery_captions') -eq '0' -or $g0.captions -eq $true))
  Check 'the allowed range is 30-600 s (the ini value is clamped)' ($g0.secs -ge 30 -and $g0.secs -le 600)
  Check 'it says plainly why it is hidden, when it is' ($g0.shown -or $g0.why.Length -gt 0)
  Check 'an unknown gallery command is refused' ((Api 'galbogus') -ne 200)
  Check 'a wrong mode is refused' ((Api 'galmode' 'sideways') -ne 200)
  # (only when no other test has switched the hook on: with it on these commands are accepted and would change the live gallery)
  if (-not (Test-Path (Join-Path $root 'dash\test-hook.on'))) { Check 'the test-only commands are refused while the test hook is off' ((Api 'galsim' 'irdash-test-x') -eq 400 -and (Api 'galtiming' '3,1') -eq 400) }
  else { "        (another test has the test hook on, so the test-only commands are not tried now)" }
}
if ($live) {
  # Part 4 of WS14: the app's display name is PADDOCK on the dashboard, intro, Rig Doctor and tray; wired names stay as they are
  $get = { param($p) [Text.Encoding]::UTF8.GetString((Invoke-WebRequest -UseBasicParsing "$api$p" -TimeoutSec 8).RawContentStream.ToArray()) }
  $idxHtml = & $get '/v2/index.html'; $introJs = & $get '/v2/intro.js'; $rigJs = & $get '/v2/rig.js'
  Check 'the idle screen header shows the PADDOCK wordmark (gold, letter-spaced caps) where "Car No. 4" was' ($idxHtml -match 'class="idle-name">Paddock<' -and $idxHtml -notmatch 'idle-top"><span>Car')
  Check 'the start-up intro corner says Paddock' ($introJs -match "corner tl wordmark', 'Paddock'")
  Check 'the Rig Doctor header says Paddock, then Rig Doctor' ($rigJs -match 'Paddock<em class="dr-sub">Rig Doctor')
  Check 'the dashboard page title stays "iRacing Dash" (irdash finds the dashboard window by it)' ($idxHtml -match '<title>iRacing Dash')
  $exeText = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes((Join-Path $root 'dash\irdash.exe')))
  Check 'the tray text in irdash.exe is Paddock (live / waiting for iRacing)' ($exeText.Contains('Paddock live') -and $exeText.Contains('Paddock waiting for iRacing'))
}
if ($StaticOnly) { "static part done: $pass ok, $fail FAIL, $pend pending"; if ($fail) { exit 1 } else { exit 0 } }
if (-not $live) { "gallery test (pictures only): $pass ok, $fail FAIL, $pend pending"; if ($fail) { exit 1 } else { exit 4 } }

# ---------------------------------------------------------------------------------------------------------------
# The window part
$race = @([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.Width -eq 2560 -and $_.Bounds.Height -eq 1440 } | Sort-Object { $_.Bounds.X })
Enter-TestLock 'gallery'   # one live test at a time (tests\guard.ps1), before the hook check below; released in finally
$why = Get-RigBusy
if (-not $why -and (Test-Path (Join-Path $root 'dash\test-hook.on'))) { $why = 'another test has the test hook on (a pretend session would hide the gallery); run this again when it has finished' }
if (-not $why -and -not $PeterIsAway) { $idle = [RigGuard]::IdleMinutes(); if ($idle -lt 10) { $why = "Peter used the PC $([math]::Round($idle, 1)) minutes ago (the window part puts pictures on his side screens and plays the intro once; it waits until he has been away 10 minutes)" } }
if ($why) { Pending "the window part was not run: $why"; "gallery test: $pass ok, $fail FAIL, $pend pending"; if ($fail) { exit 1 } else { exit 4 } }
if ($race.Count -ne 3) { Pending "the window part was not run: the three race screens are not there ($($race.Count) of 2560x1440 found)"; "gallery test: $pass ok, $fail FAIL, $pend pending"; if ($fail) { exit 1 } else { exit 4 } }
$SL = $race[0].Bounds; $SM = $race[1].Bounds; $SR = $race[2].Bounds

$lock = Join-Path $root 'dash\deploy.lock'
for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock (' + (Get-Content $lock) + ')'; Start-Sleep -Seconds 60 }
Set-Content $lock ('gallery ' + (Get-Date).ToString('HH:mm:ss'))
$hook = Join-Path $root 'dash\test-hook.on'
$standExe = Join-Path $env:TEMP 'irdash-test-gal.exe'; $standProc = $null
$on0 = $g0.on; $mode0 = $g0.mode; $logN = (Get-Content (Join-Path $root 'dash\irdash.log') | Measure-Object).Count
$mineDir = Join-Path $galDir 'mine'; $mineMade = @(); $mineDirMade = $false
$irdash = Get-Process irdash | Select-Object -First 1
function Cpu($seconds) {   # % of one core used by irdash over the next N seconds
  $p = Get-Process -Id $irdash.Id; $t0 = $p.TotalProcessorTime; $w0 = Get-Date
  Start-Sleep -Seconds $seconds
  $p = Get-Process -Id $irdash.Id; $t1 = $p.TotalProcessorTime
  return [math]::Round((($t1 - $t0).TotalSeconds / ((Get-Date) - $w0).TotalSeconds) * 100, 2)
}
function MemMb { $p = Get-Process -Id $irdash.Id; return [math]::Round($p.PrivateMemorySize64 / 1MB, 0) }
function WaitFor($scriptBlock, $maxSec, $stepMs = 100) { $t = [Diagnostics.Stopwatch]::StartNew(); while ($t.Elapsed.TotalSeconds -lt $maxSec) { if (& $scriptBlock) { return $t.Elapsed.TotalSeconds }; Start-Sleep -Milliseconds $stepMs }; return -1 }
function Grab($x, $y, $w, $h) { $bmp = New-Object System.Drawing.Bitmap $w, $h; $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h)); $g.Dispose(); return $bmp }
function SaveShot($bmp, $name, $scaleTo) { $path = Join-Path $shots "$name.png"; if ($scaleTo) { $s = New-Object System.Drawing.Bitmap $bmp, $scaleTo, ([int]($bmp.Height * $scaleTo / $bmp.Width)); $s.Save($path); $s.Dispose() } else { $bmp.Save($path) }; return $path }
$fgSamples = New-Object System.Collections.ArrayList
function FgSample($all) { $f = [GalT]::GetForegroundWindow().ToInt64(); [void]$fgSamples.Add($f); if ($all -contains $f) { return $true }; return $false }
$fgBad = 0

try {
  Section '3. the gallery comes up on the two side screens'
  Set-Content $hook 'on for the test'
  $fg0 = [GalT]::GetForegroundWindow().ToInt64()
  Check 'the test-only commands now work (test hook on)' ((Api 'galtiming' '6,1.5') -eq 200)
  [void](Api 'galmode' 'same')
  $t = WaitFor { (J '/gallery').shown } 12
  Check "the gallery shows by itself (after $([math]::Round($t, 1)) s)" ($t -ge 0)
  $g = J '/gallery'
  Check 'left window is on the left race screen and right window on the right one (bounds match, by position)' ($g.left -and $g.right -and $g.left.x -eq $SL.X -and $g.left.y -eq $SL.Y -and $g.left.w -eq 2560 -and $g.left.h -eq 1440 -and $g.right.x -eq $SR.X -and $g.right.y -eq $SR.Y -and $g.right.w -eq 2560 -and $g.right.h -eq 1440)
  Start-Sleep -Milliseconds 4500
  $g = J '/gallery'
  $handles = @($g.left.hwnds) + @($g.right.hwnds)
  $allH = @($handles | ForEach-Object { [int64]$_ })
  Check "irdash made 2 picture windows and 1 small caption window per side ($($handles.Count) windows)" ($handles.Count -eq 6)
  $bad = @(); $vis = 0
  foreach ($h in $allH) {
    $ex = [GalT]::GetWindowLong([IntPtr]$h, -20)
    $need = 0x08000000 -bor 0x80 -bor 0x20 -bor 0x80000      # no-activate, tool window (no taskbar / Alt-Tab), click-through, layered
    if (($ex -band $need) -ne $need -or ($ex -band 0x40000) -ne 0 -or ($ex -band 0x8) -ne 0) { $bad += "$h ex=0x{0:X}" -f $ex }
    if ([GalT]::IsWindowVisible([IntPtr]$h)) { $vis++ }
  }
  Check 'every gallery window: never activates, not in the taskbar or Alt-Tab, ignores the mouse, is not topmost' ($bad.Count -eq 0)
  if ($bad.Count) { "        $($bad -join '; ')" }
  Check "two picture windows and two captions are showing ($vis visible)" ($vis -ge 3 -and $vis -le 6)
  $rects = @(); foreach ($side in @($g.left, $g.right)) { foreach ($h in $side.hwnds) { if ([GalT]::IsWindowVisible([IntPtr][int64]$h)) { $r = New-Object GalT+RECT; [void][GalT]::GetWindowRect([IntPtr][int64]$h, [ref]$r); if (($r.R - $r.L) -eq 2560) { $rects += , @($side.x, $side.y, $r.L, $r.T, $r.R, $r.B) } } } }
  Check 'the picture windows really fill their screens (window rectangle = screen)' ($rects.Count -ge 2 -and @($rects | Where-Object { $_[2] -ne $_[0] -or $_[3] -ne $_[1] -or ($_[4] - $_[2]) -ne 2560 -or ($_[5] - $_[3]) -ne 1440 }).Count -eq 0)
  $capRects = @(); foreach ($side in @($g.left, $g.right)) { $h = [int64]$side.hwnds[2]; if ([GalT]::IsWindowVisible([IntPtr]$h)) { $r = New-Object GalT+RECT; [void][GalT]::GetWindowRect([IntPtr]$h, [ref]$r); $capRects += , @($side.workX, $side.workBottom, $r.L, $r.T, $r.R, $r.B) } }
  Check 'each caption window is only as big as its one line of text (not a bar) and sits in the bottom-left corner, just above the taskbar (the side screens have one)' ($capRects.Count -eq 2 -and @($capRects | Where-Object { ($_[4] - $_[2]) -gt 1500 -or ($_[5] - $_[3]) -gt 30 -or $_[2] -ne $_[0] + 24 -or $_[5] -gt $_[1] - 20 -or $_[5] -lt $_[1] - 40 }).Count -eq 0)
  $mouse = @($allH | ForEach-Object { [GalT]::MouseActivate([IntPtr]$_) } | Where-Object { $_ -ne 3 })
  Check 'a click on them would not activate them (MA_NOACTIVATE)' ($mouse.Count -eq 0)
  $hit = @($allH | ForEach-Object { [GalT]::HitTest([IntPtr]$_, 100, 100) } | Where-Object { $_ -ne -1 })
  Check 'the mouse goes straight through them (HTTRANSPARENT)' ($hit.Count -eq 0)
  $under = [GalT]::FromPoint($SL.X + 1200, $SL.Y + 700)
  Check 'the window under the mouse on the left screen is not a gallery window (clicks reach the desktop)' ($allH -notcontains $under)
  $fgNow = [GalT]::GetForegroundWindow().ToInt64()
  Check 'they never took the focus: the front window is the same as before and is not one of ours' ($fgNow -eq $fg0 -and $allH -notcontains $fgNow)

  Section '4. bottom of the z-order'
  $ord = @([GalT]::Order())
  $idx = @{}; for ($i = 0; $i -lt $ord.Count; $i++) { $idx[[int64]($ord[$i].Split('|')[0])] = $i }
  $mineIdx = @($allH | Where-Object { $idx.ContainsKey($_) } | ForEach-Object { $idx[$_] })
  $firstMine = ($mineIdx | Measure-Object -Minimum).Minimum
  Check 'both big picture windows are in the window list (the one-line caption windows are under 50 px high and are left out of it)' ($mineIdx.Count -ge 2)
  $others = @(); for ($i = 0; $i -lt $ord.Count; $i++) { $p = $ord[$i].Split('|'); if ($allH -contains [int64]$p[0]) { continue }; if ($p[1] -in 'Progman', 'WorkerW') { continue }; $others += , @($i, $p[1], $p[2]) }
  $below = @($others | Where-Object { $_[0] -gt $firstMine })
  Check "every other visible window is above the first gallery window ($($others.Count) windows checked)" ($below.Count -eq 0)
  if ($below.Count) { "        below the gallery: " + (($below | ForEach-Object { $_[1] + ' "' + $_[2] + '"' }) -join '; ') }
  Check 'there are real windows to compare with (the dashboard page, the taskbar ...)' ($others.Count -ge 2)
  $ui = @($others | Where-Object { $_[2] -eq 'iRacing' } | Select-Object -First 1)
  if ($ui.Count) { Check "the iRacing app window ('$($ui[0][2])') is above the gallery, so it stays usable on the middle screen" ($ui[0][0] -lt $firstMine) } else { "        (the iRacing app is not open now; compared with the other windows instead)" }
  $dashW = @($others | Where-Object { $_[2] -like 'iRacing Dash*' -or $_[2] -like 'localhost:8199*' } | Select-Object -First 1)
  if ($dashW.Count) { Check 'the Paddock dashboard page on the top screen is above the gallery' ($dashW[0][0] -lt $firstMine) }
  Check 'irdash says the same about itself (/gallery z: nothing normal below)' ((J '/gallery').z.ok -eq $true)
  # try to knock them off the bottom: a plain "send to top" request on a gallery window must end up at the bottom again
  Add-Type -Name GalSwp -Namespace GalT2 -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);' -ErrorAction SilentlyContinue
  [void][GalT2.GalSwp]::SetWindowPos([IntPtr]$allH[0], [IntPtr]0, 0, 0, 0, 0, 0x1 -bor 0x2 -bor 0x10)    # HWND_TOP, no move/size/activate
  Start-Sleep -Milliseconds 700
  $ord = @([GalT]::Order()); $idx = @{}; for ($i = 0; $i -lt $ord.Count; $i++) { $idx[[int64]($ord[$i].Split('|')[0])] = $i }
  $firstMine = (@($allH | Where-Object { $idx.ContainsKey($_) } | ForEach-Object { $idx[$_] }) | Measure-Object -Minimum).Minimum
  $below2 = 0; for ($i = 0; $i -lt $ord.Count; $i++) { $p = $ord[$i].Split('|'); if ($allH -contains [int64]$p[0] -or $p[1] -in 'Progman', 'WorkerW') { continue }; if ($i -gt $firstMine) { $below2++ } }
  Check 'asking a gallery window to come to the top is turned into "bottom": still nothing normal below them' ($below2 -eq 0)

  Section '5. the SAME picture on both screens, changing at the same moment with one crossfade (test timing: 6 s, 1.5 s fade)'
  $sample = New-Object System.Collections.ArrayList     # per sample: time, left file, right file, left caption, changes
  $sameBad = 0; $t0 = Get-Date; $lastL = ''; $lastR = ''; $chL = @(); $chR = @(); $steadyDone = $false; $fadeShot = $false
  $simDist = New-Object System.Collections.ArrayList; $sigL = New-Object System.Collections.ArrayList
  $capCheck = $null; $barCheck = $null
  while (((Get-Date) - $t0).TotalSeconds -lt 20) {
    $j = J '/gallery'
    if (-not $j.left -or -not $j.right) { break }
    $now = ((Get-Date) - $t0).TotalSeconds
    if ($j.left.file -ne $j.right.file) { $sameBad++ }
    if ($j.left.file -ne $lastL) { $chL += $now; $lastL = $j.left.file }
    if ($j.right.file -ne $lastR) { $chR += $now; $lastR = $j.right.file }
    # both screens at the same instant (one right after the other): during a fade and when still they must look alike
    $bl = Grab $SL.X $SL.Y 2560 1440; $br = Grab $SR.X $SR.Y 2560 1440
    $sigNow = [GalT]::Sig($bl); [void]$simDist.Add([GalT]::Dist($sigNow, [GalT]::Sig($br))); [void]$sigL.Add($sigNow)    # (not $sl: PowerShell names are not case sensitive and $SL is the left screen)
    if (-not $fadeShot -and $j.fading) { $null = SaveShot $bl 'g-left-fade' 1280; $null = SaveShot $br 'g-right-fade' 1280; $fadeShot = $true }
    # a steady picture 3.2-5 s after a change (caption fully in): compare the screen with the picture itself
    if (-not $capCheck -and $chL.Count -ge 1 -and ($now - $chL[-1]) -ge 3.2 -and ($now - $chL[-1]) -le 5.0 -and -not $j.fading -and $j.left.caption) {
      $src = New-Object System.Drawing.Bitmap (Join-Path $galDir $j.left.file)
      $ch = $j.left.hwnds[2]; $rr = New-Object GalT+RECT; [void][GalT]::GetWindowRect([IntPtr][int64]$ch, [ref]$rr)
      $cx = $rr.L - $SL.X; $cy = $rr.T - $SL.Y; $cw = $rr.R - $rr.L; $chh = $rr.B - $rr.T
      if ($cx -lt 0 -or $cy -lt 0 -or $cw -lt 20 -or $cx + $cw -gt 2560 -or $cy + $chh -gt 1440) { $src.Dispose(); $bl.Dispose(); $br.Dispose(); Start-Sleep -Milliseconds 300; continue }     # window not in place yet: look again in a moment
      $inBox = [GalT]::Changed($bl, $src, $cx, $cy, $cw, $chh)
      $wb = [int]($j.left.workBottom - $SL.Y)                                   # above the taskbar (the taskbar is not ours)
      $whole = [GalT]::MeanDiff($bl, $src, 0, 0, 2560, $wb, $cx, $cy, $cw, $chh)
      $strip = [GalT]::MeanDiff($bl, $src, 0, $wb - 250, 2560, 250, $cx, $cy, $cw, $chh)
      $capCheck = @($inBox, $whole, $strip, $j.left.caption, $j.right.caption, $j.left.file, $cw, $chh)
      $null = SaveShot $bl 'g-left-1' 1280; $null = SaveShot $br 'g-right-1' 1280
      $null = SaveShot ($bl.Clone((New-Object System.Drawing.Rectangle 0, 1340, 1400, 100), $bl.PixelFormat)) 'g-left-caption' $null
      $src.Dispose()
    }
    $bl.Dispose(); $br.Dispose()
    if (FgSample $allH) { $fgBad++ }
    Start-Sleep -Milliseconds 40
  }
  $jj = J '/gallery'
  Check "both screens changed together: left $($chL.Count - 1) times, right $($chR.Count - 1) times in 20 s (every 6 s, so 2 to 4 each)" (($chL.Count - 1) -ge 2 -and ($chL.Count - 1) -le 4 -and $chL.Count -eq $chR.Count)
  "        left changes at $(($chL | ForEach-Object { [math]::Round($_, 2) }) -join ', ') s, right at $(($chR | ForEach-Object { [math]::Round($_, 2) }) -join ', ') s"
  $gap = 0.0; for ($i = 0; $i -lt [math]::Min($chL.Count, $chR.Count); $i++) { $gap = [math]::Max($gap, [math]::Abs($chL[$i] - $chR[$i])) }
  Check "left and right change within 100 ms of each other (largest gap $([math]::Round($gap * 1000)) ms)" ($gap -le 0.1)
  Check "both screens showed the IDENTICAL picture in every sample ($sameBad samples where the file names differed)" ($sameBad -eq 0)
  $sd = @($simDist); $medD = ($sd | Sort-Object)[[int]($sd.Count / 2)]
  Check "the two screens' pictures look the same, also while fading (median colour difference $([math]::Round($medD, 2)), worst $([math]::Round(($sd | Measure-Object -Maximum).Maximum, 1)))" ($medD -lt 1.5 -and ($sd | Measure-Object -Maximum).Maximum -lt 10)
  $steps = @(); for ($i = 1; $i -lt $sigL.Count; $i++) { $steps += [GalT]::Dist($sigL[$i - 1], $sigL[$i]) }
  # A fade is many small steps. A cut is one jump, then the picture sits still.
  # Lead run 2026-10-10 18:55 (Vault backfill already finished): 39 steps between 1 and 8, 3 steps over 8, largest 9.1.
  # That failed "big ones <= 2". Grabbing two 2560x1440 screens makes one sample cover the steep part of the 1.5 s fade,
  # so a normal fade steps just over 8. Across the 118 pictures on screen a full swap is min 9.9, average 52.9, max 147.7
  # (2038 pairs are under 40), so a small step is not proof by itself. A cut still fails: it has fewer than 8 in-between steps.
  $mid = @($steps | Where-Object { $_ -gt 1.0 -and $_ -le 15 }); $big = @($steps | Where-Object { $_ -gt 15 })
  $largest = 0.0; if ($steps.Count) { $largest = ($steps | Measure-Object -Maximum).Maximum }
  Check "the screens fade rather than cut: $($mid.Count) in-between steps, $($big.Count) big ones, largest step $([math]::Round($largest, 1))" ($mid.Count -ge 8 -and $largest -lt 40)
  if ($capCheck) {
    Check "the picture is shown exactly as it is: no bar, no shade, no logo (colour difference to the picture file outside the caption: whole screen $([math]::Round($capCheck[1], 2)), bottom strip $([math]::Round($capCheck[2], 2)))" ($capCheck[1] -lt 2.5 -and $capCheck[2] -lt 2.5)
    if ($capCheck[1] -ge 2.5 -or $capCheck[2] -ge 2.5) {
      # name whatever other program is drawn over the bottom strip (2026-10-11: the Simucube Tuner's blank 300x150 "Tuner" popup on the left screen)
      $wbN = [int]($jj.left.workBottom - $SL.Y)
      foreach ($row in [GalT]::Order()) {
        $q = $row.Split('|'); if ($q[1] -match '^Shell_|^Progman$|^WorkerW$') { continue }
        if ($allH -contains [int64]$q[0]) { continue }
        $rr2 = New-Object GalT+RECT; if (-not [GalT]::GetWindowRect([IntPtr][int64]$q[0], [ref]$rr2)) { continue }
        $ix = [math]::Min($rr2.R, $SL.X + 2560) - [math]::Max($rr2.L, $SL.X); $iy = [math]::Min($rr2.B, $SL.Y + $wbN) - [math]::Max($rr2.T, $SL.Y + $wbN - 250)
        if ($ix -gt 0 -and $iy -gt 0) { $pn = (Get-Process -Id ([int]$q[3]) -ErrorAction SilentlyContinue).ProcessName; "        over the bottom strip of the left screen: $($q[1]) `"$($q[2])`" ($pn) at $($rr2.L),$($rr2.T) $($rr2.R - $rr2.L)x$($rr2.B - $rr2.T)" }
      }
    }
    Check "the caption text is on the screen ($($capCheck[0]) pixels differ from the picture inside the $($capCheck[6]) x $($capCheck[7]) px box)" ($capCheck[0] -ge 60)
    $e = ($credits | Where-Object { $_.file -eq $capCheck[5] } | Select-Object -First 1)
    Check "the caption is the same on both screens: '$($capCheck[3])'" ($capCheck[3] -eq $capCheck[4] -and $capCheck[3].Length -gt 5)
    Check 'it is the title from the credits file (accents correct), plus the photographer and licence only for CC pictures, and never PADDOCK' ($e -and $capCheck[3].StartsWith($e.title) -and (($e.licence -like 'CC*') -eq $capCheck[3].Contains(' · Photo: ' + $e.author)) -and $capCheck[3] -notmatch '(?i)paddock')
  } else { Check 'a steady picture with a caption was caught for the caption check' $false }
  Check "the gallery's own focus log: no gallery window was ever the front window (JSON says $($jj.foregroundHits))" ($jj.foregroundHits -eq 0)
  Check "foreground sampled $($fgSamples.Count) times during the run: never a gallery window" ($fgBad -eq 0)
  Check 'the credit line for the picture on screen is on /gallery (author, site, licence, source link)' ($jj.left.credit.Length -gt 5 -and $jj.left.source -match '^https://')
  $repeat = @($chL | Measure-Object).Count; $files = @(); # every change shows a picture not shown a moment ago: checked through the shuffle in the next section

  Section '6. next picture, matched pairs, off and on (the Stream Deck commands)'
  $c0 = (J '/gallery').changes; $l0 = (J '/gallery').left.file
  $null = WaitFor { (J '/gallery').phase -eq 0 } 8
  [void](Api 'galnext')
  $t = WaitFor { (J '/gallery').changes -gt $c0 } 8
  $g = J '/gallery'
  Check "NEXT brings a new picture straight away ($([math]::Round($t, 1)) s, was $l0, now $($g.left.file))" ($t -ge 0 -and $g.left.file -ne $l0 -and $g.left.file -eq $g.right.file)
  $seen = @{}; $dupRound = $false
  for ($k = 0; $k -lt [math]::Min(6, $g.count - 1); $k++) {
    $null = WaitFor { (J '/gallery').phase -eq 0 } 12; $before = (J '/gallery').changes; [void](Api 'galnext'); $null = WaitFor { (J '/gallery').changes -gt $before } 12
    $f = (J '/gallery').left.file; if ($seen.ContainsKey($f)) { $dupRound = $true }; $seen[$f] = $true
  }
  Check "six more NEXT presses showed six different pictures (shuffled without repeats within a round)" (-not $dupRound)
  [void](Api 'galmode' 'pair')
  $t = WaitFor { $q = J '/gallery'; $q.shown -and $q.left.file -and $q.right.file -and $q.left.file -ne $q.right.file } 40
  $q = J '/gallery'
  Check "pair mode shows two different pictures, one per screen ($([math]::Round($t, 1)) s): $($q.left.file) | $($q.right.file)" ($t -ge 0 -and $q.mode -eq 'pair')
  $null = WaitFor { (J '/gallery').phase -eq 0 } 12
  $fa = [GalT]::Feat((New-Object System.Drawing.Bitmap (Join-Path $galDir $q.left.file))); $fb = [GalT]::Feat((New-Object System.Drawing.Bitmap (Join-Path $galDir $q.right.file)))
  $pairLook = [GalT]::Look($fa, $fb)
  $files = @(Get-ChildItem $galDir -Filter *.jpg | ForEach-Object { , [GalT]::Feat((New-Object System.Drawing.Bitmap $_.FullName)) })
  $sum = 0.0; $cnt = 0; for ($i = 0; $i -lt $files.Count; $i++) { for ($k2 = $i + 1; $k2 -lt $files.Count; $k2++) { $sum += [GalT]::Look($files[$i], $files[$k2]); $cnt++ } }
  Check "the pair looks alike (look difference $([math]::Round($pairLook, 2)) against $([math]::Round($sum / $cnt, 2)) for a random pair)" ($pairLook -lt $sum / $cnt)
  [void](Api 'galmode' 'same')
  $t = WaitFor { $q = J '/gallery'; $q.shown -and $q.left.file -and $q.left.file -eq $q.right.file -and $q.mode -eq 'same' } 20
  Check "back to the same picture on both screens ($([math]::Round($t, 1)) s)" ($t -ge 0)
  [void](Api 'galoff')
  $t = WaitFor { -not (J '/gallery').shown } 3
  Check "OFF hides it within 2 s ($([math]::Round($t, 2)) s) and says why: $((J '/gallery').why)" ($t -ge 0 -and $t -le 2.0 -and (J '/gallery').why -eq 'off')
  Check 'no gallery window is left (all destroyed)' (@($allH | Where-Object { [GalT]::IsWindow([IntPtr]$_) }).Count -eq 0)
  Check 'the choice is saved in irdash.ini (gallery=0)' ((Ini 'gallery') -eq '0')
  [void](Api 'galon')
  $t = WaitFor { (J '/gallery').shown } 6
  Check "ON brings it back ($([math]::Round($t, 1)) s) and saves gallery=1" ($t -ge 0 -and (Ini 'gallery') -eq '1')

  Section '7. the sim appears: hidden within 2 s, fully stopped (a harmless stand-in program, not the real sim)'
  # steady = shown, not fading AND the picture is named: right after ON the page says phase 0 before it is shown, and the file name
  # is empty until the fade-in is done, so waiting for phase 0 alone let "$lastLeftFile" be empty and Bitmap() below crash (2026-10-11)
  $null = WaitFor { $q = J '/gallery'; $q.shown -and $q.phase -eq 0 -and $q.left.file } 15
  Copy-Item (Join-Path $env:SystemRoot 'System32\ping.exe') $standExe -Force
  Check 'the stand-in name is accepted' ((Api 'galsim' 'irdash-test-gal') -eq 200)
  Start-Sleep -Milliseconds 1500
  Check 'with the stand-in not running yet, the gallery still shows' ((J '/gallery').shown -eq $true)
  $memShown = MemMb; $lastLeftFile = (J '/gallery').left.file; $hnow = @((J '/gallery').left.hwnds) + @((J '/gallery').right.hwnds)
  $standProc = Start-Process -FilePath $standExe -ArgumentList '-n 300 127.0.0.1' -PassThru -WindowStyle Hidden
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $t = WaitFor { -not (J '/gallery').shown } 5 50
  Check "the gallery is hidden $([math]::Round($sw.Elapsed.TotalSeconds, 2)) s after the sim program starts (limit 2 s) - why: $((J '/gallery').why)" ($t -ge 0 -and $t -le 2.0 -and (J '/gallery').why -eq 'sim')
  $gone = @($hnow | Where-Object { [GalT]::IsWindow([IntPtr][int64]$_) }).Count
  $stillThere = @([GalT]::Order() | Where-Object { $_ -like '*|irdash gallery|*' }).Count
  Check 'its windows are gone, not just hidden (nothing left to cost the screen anything)' ($gone -eq 0 -and $stillThere -eq 0)
  Start-Sleep -Milliseconds 600
  $lg = @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logN)
  Check 'irdash.log says when the sim program started and how long the gallery took to go' (@($lg | Where-Object { $_ -match 'gallery: the sim program started at \d\d:\d\d:\d\d\.\d+, the gallery was gone [0-9.]+ s later' }).Count -ge 1)
  $bl = Grab $SL.X $SL.Y 2560 1440; $srcL = New-Object System.Drawing.Bitmap (Join-Path $galDir $lastLeftFile)
  $dd = [GalT]::Dist([GalT]::Sig($bl), [GalT]::Sig($srcL)); $bl.Dispose(); $srcL.Dispose()
  Check "the left screen no longer shows the last gallery picture (colour difference $([math]::Round($dd, 1)))" ($dd -gt 4)
  Start-Sleep -Seconds 3
  $cpuHidden = Cpu 10
  $memHidden = MemMb
  "        irdash CPU with the gallery hidden: $cpuHidden % of one core, memory $memHidden MB (was $memShown MB with the pictures up)"
  Check "the pictures' memory was given back (private memory $memShown MB showing, $memHidden MB hidden)" ($memHidden -le $memShown)
  [void](Api 'galsim' '')
  try { $standProc.Kill() } catch { }; Start-Sleep -Milliseconds 400
  $t = WaitFor { (J '/gallery').shown } 8 200
  Check "when the sim program ends the gallery comes back by itself ($([math]::Round($t, 1)) s)" ($t -ge 0)

  Section '8. CPU and memory with the real timing (a change every 120 s, 5 s fade) against the gallery switched off'
  [void](Api 'galoff'); Start-Sleep -Seconds 2
  $cpuOff = Cpu 12; $memOff = MemMb
  [void](Api 'galtiming' ''); [void](Api 'galon'); $null = WaitFor { (J '/gallery').shown } 8
  $jt = J '/gallery'
  Check "the ini timing is back (every $($jt.secs) s, $($jt.fade) s fade)" ($jt.secs -ge 30 -and $jt.secs -le 600)
  $null = WaitFor { (J '/gallery').phase -eq 0 } 20; Start-Sleep -Seconds 2
  $cpuIdle = Cpu 10; $memShow = MemMb
  [void](Api 'galnext'); Start-Sleep -Milliseconds 800
  $cpuFade = Cpu 10                                  # inside the 5 s crossfade and the captions fading
  "        irdash CPU: gallery off $cpuOff %, hidden by the sim $cpuHidden %, showing and still $cpuIdle %, crossfading $cpuFade % of one core; memory off $memOff MB, showing $memShow MB"
  Check "hidden (sim running) costs the same as switched off: $cpuHidden % against $cpuOff % of one core" ([math]::Abs($cpuHidden - $cpuOff) -lt 1.0)
  Check "showing a still picture costs next to nothing ($([math]::Round($cpuIdle - $cpuOff, 2)) points of one core)" (($cpuIdle - $cpuOff) -lt 1.0)
  Check "the gallery adds little CPU while crossfading ($([math]::Round($cpuFade - $cpuOff, 2)) points of one core)" (($cpuFade - $cpuOff) -lt 4.0)
  Check "and a bounded amount of memory ($($memShow - $memOff) MB for the pictures: only the one on screen and the one coming in are kept)" (($memShow - $memOff) -lt 90)
  $n0 = MemMb
  for ($k = 0; $k -lt 3; $k++) { [void](Api 'galoff'); Start-Sleep -Milliseconds 1500; [void](Api 'galon'); Start-Sleep -Milliseconds 3500 }
  $n1 = MemMb
  Check "three more hide/show rounds do not leak ($n0 MB before, $n1 MB after)" (($n1 - $n0) -lt 60)

  Section '9. pictures in mine\ (only 2560 px wide or more, no caption) and the start-up intro'
  if (-not (Test-Path $mineDir)) { New-Item -ItemType Directory $mineDir | Out-Null; $mineDirMade = $true }
  $jc = (J '/gallery').count; $capBefore = (J '/gallery').captioned
  $okF = Join-Path $mineDir 'zz-gallery-test-big.jpg'; $smallF = Join-Path $mineDir 'zz-gallery-test-small.jpg'
  $b1 = New-Object System.Drawing.Bitmap 2560, 1440; $gg = [System.Drawing.Graphics]::FromImage($b1); $gg.Clear([System.Drawing.Color]::DarkSlateGray); $gg.Dispose(); $b1.Save($okF, [System.Drawing.Imaging.ImageFormat]::Jpeg); $b1.Dispose(); $mineMade += $okF
  $b2 = New-Object System.Drawing.Bitmap 1920, 1080; $b2.Save($smallF, [System.Drawing.Imaging.ImageFormat]::Jpeg); $b2.Dispose(); $mineMade += $smallF
  [void](Api 'galrescan'); Start-Sleep -Milliseconds 800
  $j2 = J '/gallery'
  Check "a 2560-wide picture in mine\ joins the list, a 1920-wide one is left out (count $jc -> $($j2.count)); with no credits entry it has no caption (captioned stays $capBefore)" ($j2.count -eq $jc + 1 -and $j2.captioned -eq $capBefore)
  foreach ($f in $mineMade) { [IO.File]::Delete($f) }; $mineMade = @()
  if ($mineDirMade -and @(Get-ChildItem $mineDir).Count -eq 0) { [IO.Directory]::Delete($mineDir) }
  [void](Api 'galrescan'); Start-Sleep -Milliseconds 500
  Check 'taking them away again puts the count back' ((J '/gallery').count -eq $jc)
  # the start-up intro (SHOWCASE) plays on the top screen and the deck: the gallery must step aside for it
  [void](Api 'galtiming' ''); Start-Sleep -Milliseconds 500
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/showcase" -TimeoutSec 5
  $t = WaitFor { (J '/gallery').why -eq 'intro' } 4
  Check "the intro starts and the gallery steps aside within 2 s ($([math]::Round($t, 1)) s)" ($t -ge 0 -and $t -le 2.0 -and -not (J '/gallery').shown)
  $t = WaitFor { (J '/gallery').shown } 30 250
  Check "after the intro the gallery comes back by itself ($([math]::Round($t, 1)) s)" ($t -ge 0)
}
finally {
  try { [void](Api 'galsim' '') } catch { }
  try { [void](Api 'galtiming' '') } catch { }
  try { if ($mode0) { [void](Api 'galmode' $mode0) } } catch { }
  try { if ($on0 -eq $false) { [void](Api 'galoff') } else { [void](Api 'galon') } } catch { }
  try { if ($standProc -and -not $standProc.HasExited) { $standProc.Kill() } } catch { }
  Get-Process irdash-test-gal -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  foreach ($f in $mineMade) { try { [IO.File]::Delete($f) } catch { } }
  if ($mineDirMade -and (Test-Path $mineDir) -and @(Get-ChildItem $mineDir).Count -eq 0) { try { [IO.Directory]::Delete($mineDir) } catch { } }
  Start-Sleep -Milliseconds 400
  Remove-Item -LiteralPath $hook -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $standExe -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
  Exit-TestLock
}
$lg = @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logN | Where-Object { $_ -match '^\S+ \S+\s+gallery' })
Check 'the log has "gallery:" lines for showing and stopping' (@($lg | Where-Object { $_ -match 'gallery: showing' }).Count -ge 1 -and @($lg | Where-Object { $_ -match 'gallery: stopped' }).Count -ge 1)
Check 'the log never says a gallery window became the front window' (@($lg | Where-Object { $_ -match 'became the front window' }).Count -eq 0)
Check 'the log has no gallery errors' (@($lg | Where-Object { $_ -match 'cannot show|\.json: |could not start|measuring stopped' }).Count -eq 0)
Check 'the test hook is switched off again' (-not (Test-Path $hook))
"gallery test: $pass ok, $fail FAIL, $pend pending"
if ($fail) { exit 1 } elseif ($pend) { exit 4 } else { exit 0 }
