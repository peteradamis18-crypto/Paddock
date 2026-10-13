# P5 rig leftovers (docs\PLAN-v3.md): three small things that were left over.
#   1. The Simucube Tuner's blank grey box (Qt class Qt6103QWindowToolSaveBits, title "Tuner", 300x150, topmost) is HIDDEN automatically - never closed.
#      Stand-in programs (a tiny exe that makes windows with the same class, title, size and styles) prove: exactly that window of exactly that
#      program is hidden; the Tuner's other windows, a look-alike of another program and look-alikes of the same program are untouched;
#      nothing is closed or killed; the focus does not move; a second look hides nothing. Both the shipped irdash code (Rig Doctor) and irdeck's RIG ON code.
#      A read-only look at the REAL Tuner's windows checks the rule against what is on this PC.
#   2. MOST TO GAIN: irdash.exe --analysis --gain over scratch copies of real sessions (some with a patched car name or layout, so there are
#      several combinations); every number against an independent computation from the career cache files (vault\career\c-*.json) and
#      against the Career page's own figures (--career); the live /analysis/gain and the "gain" object of /mydrive when the deployed irdash has them.
#   3. The iRacing UI window is found without Process.MainWindowHandle: the window titled "iRacing", else the largest visible window, even
#      with a tiny untitled strip window on top (stand-in program), and no irdash code asks MainWindowHandle about the UI any more.
# Out of the car only (guard.ps1). Needs dash\build.ps1 -NoDeploy and build-irdeck.ps1 -NoDeploy to compile; the live parts need the deployed irdash.
#   powershell -ExecutionPolicy Bypass -File tests\rig-leftovers-test.ps1
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
$me = Get-Process -Id $PID
$me.PriorityClass = 'BelowNormal'
$cores = [Environment]::ProcessorCount
if ($cores -gt 2) { $mask = [int64]0; for ($i = 0; $i -lt 2; $i++) { $mask = $mask -bor ([int64]1 -shl ($cores - 1 - $i)) }; $me.ProcessorAffinity = [IntPtr]$mask }

$work = Join-Path $env:TEMP ('p5-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$apiBase = 'http://localhost:8199'
$ownerFile = Join-Path $root 'dash\tuner-owner.txt'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$procs = New-Object System.Collections.Generic.List[object]
$WS_POPUP = [uint32]2147483648     # PowerShell reads the literal 0x80000000 as a negative number

# ---- an independent look at windows (nothing of Paddock's code) ----
Add-Type @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class RlWin {
  public class Info { public IntPtr H; public string Class, Title; public bool Visible; public int W, Ht, X, Y; public uint Style, Ex; public uint Pid; }
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
  public static List<Info> Of(int[] pids) {
    var set = new HashSet<uint>(); foreach (int p in pids) set.Add((uint)p);
    var list = new List<Info>();
    EnumWindows(delegate (IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid); if (!set.Contains(pid)) return true;
      var i = new Info(); i.H = h; i.Pid = pid;
      var c = new StringBuilder(128); GetClassName(h, c, 128); i.Class = c.ToString();
      var t = new StringBuilder(256); GetWindowText(h, t, 256); i.Title = t.ToString();
      RECT r; GetWindowRect(h, out r); i.X = r.L; i.Y = r.T; i.W = r.R - r.L; i.Ht = r.B - r.T;
      i.Visible = IsWindowVisible(h); i.Style = unchecked((uint)GetWindowLong(h, -16)); i.Ex = unchecked((uint)GetWindowLong(h, -20));
      list.Add(i); return true;
    }, IntPtr.Zero);
    return list;
  }
}
public static class IbtPatch {
  // Same-length text replacement inside the session YAML of a COPY of an .ibt (the telemetry records are never touched)
  public static int Replace(string path, string from, string to) {
    if (from.Length != to.Length) throw new Exception("same length only");
    byte[] f = Encoding.ASCII.GetBytes(from), t = Encoding.ASCII.GetBytes(to);
    using (var fs = new System.IO.FileStream(path, System.IO.FileMode.Open, System.IO.FileAccess.ReadWrite)) {
      byte[] h = new byte[32]; fs.Read(h, 0, 32);
      int len = BitConverter.ToInt32(h, 16), off = BitConverter.ToInt32(h, 20);
      byte[] y = new byte[len]; fs.Position = off; fs.Read(y, 0, len);
      int n = 0;
      for (int i = 0; i + f.Length <= len; i++) {
        bool ok = true; for (int k = 0; k < f.Length && ok; k++) if (y[i + k] != f[k]) ok = false;
        if (!ok) continue;
        fs.Position = off + i; fs.Write(t, 0, t.Length); n++; i += f.Length - 1;
      }
      return n;
    }
  }
}
'@

# ---- the stand-in program: windows with the Tuner's class, title, size and styles (or the iRacing UI's strip), nothing else ----
$standSrc = @'
using System; using System.Runtime.InteropServices; using System.Threading;
class Fake {
  delegate IntPtr WndProc(IntPtr h, uint m, IntPtr w, IntPtr l);
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct WNDCLASS { public uint style; public WndProc proc; public int cbCls, cbWnd; public IntPtr inst, icon, cursor, brush; public string menu, cls; }
  [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassW(ref WNDCLASS c);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
  [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern int GetMessageW(out MSG m, IntPtr h, uint a, uint b);
  [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
  [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string n);
  static WndProc wp = delegate (IntPtr h, uint m, IntPtr w, IntPtr l) { return DefWindowProcW(h, m, w, l); };
  const uint POPUP = 0x80000000u, VIS = 0x10000000u, OVERLAPPED = 0x00CF0000u, TOP = 0x8u, TOOL = 0x80u, NOACT = 0x08000000u;
  static void Reg(string cls) { WNDCLASS c = new WNDCLASS(); c.proc = wp; c.inst = GetModuleHandleW(null); c.cls = cls; RegisterClassW(ref c); }
  static IntPtr Make(string cls, string title, uint style, uint ex, int x, int y, int w, int h) { return CreateWindowExW(ex | NOACT, cls, title, style, x, y, w, h, IntPtr.Zero, IntPtr.Zero, GetModuleHandleW(null), IntPtr.Zero); }
  static int Main(string[] a) {
    string kind = a[0]; int x = int.Parse(a[1]), y = int.Parse(a[2]); string mode = a.Length > 3 ? a[3] : "";
    Reg("Qt6103QWindowToolSaveBits"); Reg("Qt6103QWindowIcon"); Reg("Qt6103QWindowPopup"); Reg("StripClass"); Reg("BigClass");
    if (kind == "tuner") {
      // the blank box itself
      Make("Qt6103QWindowToolSaveBits", "Tuner", POPUP | VIS, TOP | TOOL, x, y, 300, 150);
      // the Tuner's own main window: hidden (it lives in the tray) or open on screen
      Make("Qt6103QWindowIcon", "Simucube Tuner", OVERLAPPED | (mode == "openmain" ? VIS : 0), 0, x, y + 200, 1016, 601);
      // look-alikes in the same program that must stay
      Make("Qt6103QWindowToolSaveBits", "Tuner Notice", POPUP | VIS, TOP | TOOL, x + 320, y, 300, 150);      // other title
      Make("Qt6103QWindowPopup", "Tuner", POPUP | VIS, TOP | TOOL, x + 640, y, 300, 150);                      // other class
      Make("Qt6103QWindowToolSaveBits", "Tuner", POPUP | VIS, TOOL, x + 960, y, 300, 150);                     // not topmost
      Make("Qt6103QWindowToolSaveBits", "Tuner", POPUP | VIS, TOP | TOOL, x, y + 170, 900, 500);              // far too big for the box
    } else if (kind == "ui") {
      // like the iRacing UI: the big window, the window titled "iRacing", and (made last, so on top) a tiny untitled strip
      if (mode != "strip") Make("BigClass", "", OVERLAPPED | VIS, 0, x + 20, y + 20, 1500, 900);
      if (mode == "titled") Make("BigClass", "iRacing", OVERLAPPED | VIS, 0, x, y, 1280, 720);
      Make("StripClass", "", POPUP | VIS, 0, x + 500, y + 700, 459, 25);
    }
    new Thread(delegate () { Thread.Sleep(240000); Environment.Exit(0); }) { IsBackground = true }.Start();   // never outlives a forgotten test
    MSG msg; while (GetMessageW(out msg, IntPtr.Zero, 0, 0) > 0) { TranslateMessage(ref msg); DispatchMessageW(ref msg); }
    return 0;
  }
}
'@

function Start-Stand($exe, $kind, $x, $y, $mode = '') {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe; $psi.Arguments = "$kind $x $y $mode"; $psi.UseShellExecute = $false
  $p = [Diagnostics.Process]::Start($psi); $procs.Add($p); Start-Sleep -Milliseconds 600
  return $p
}
function Stop-Stand($p) { try { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force; $null = $p.WaitForExit(3000) } } catch { } }
function WinsOf($p) { return @([RlWin]::Of(@($p.Id))) }
function Pick($wins, $cls, $title, $minW = 0) { return @($wins | Where-Object { $_.Class -eq $cls -and $_.Title -eq $title -and $_.W -ge $minW })[0] }
function Invoke-Exe($exe, $argLine, $timeoutMs = 120000) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe; $psi.Arguments = $argLine; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $false
  $sw = [Diagnostics.Stopwatch]::StartNew(); $proc = [Diagnostics.Process]::Start($psi)
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  if (-not $proc.WaitForExit($timeoutMs)) { try { $proc.Kill() } catch { }; throw "$exe timed out" }
  return @{ exit = $proc.ExitCode; ms = $sw.ElapsedMilliseconds; out = $outTask.Result }
}
function Json-Out($path) { if (Test-Path -LiteralPath $path) { return ([IO.File]::ReadAllText($path) | ConvertFrom-Json) } return $null }
function Get-Raw($path) {
  $rq = [Net.HttpWebRequest]::Create("$apiBase$path"); $rq.Timeout = 60000
  try { $resp = $rq.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { return @{ code = 0; body = $_.Exception.Message } } }
  $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8); $b = $sr.ReadToEnd(); $sr.Dispose(); $c = [int]$resp.StatusCode; $resp.Close()
  return @{ code = $c; body = $b }
}
function Round3($x) { return [math]::Round([double]$x, 3, [MidpointRounding]::AwayFromZero) }
# the same short id irdeck and irdash give a recent drive (FNV-1a over the lower-case text)
function Md-Id($kind, $text) { [uint32]$h = 2166136261; foreach ($c in $text.ToLowerInvariant().ToCharArray()) { $h = [uint32](([uint64]($h -bxor [uint32]$c) * 16777619) % 4294967296) }; return $kind + $h.ToString('x8') }

# ---- MOST TO GAIN worked out again from the career cache files, with none of Paddock's gain code ----
function Independent-Gain($careerDir) {
  $js = New-Object Web.Script.Serialization.JavaScriptSerializer; $js.MaxJsonLength = [int]::MaxValue
  $sess = New-Object System.Collections.Generic.List[object]
  # the cache file name carries its format version (c3-...); only the newest format counts
  $objs = foreach ($f in Get-ChildItem -LiteralPath $careerDir -Filter 'c*-*.json' -ErrorAction SilentlyContinue) { $x = $js.DeserializeObject([IO.File]::ReadAllText($f.FullName)); if ($x -and $x['v']) { $x } }
  $vmax = ($objs | ForEach-Object { [int]$_['v'] } | Measure-Object -Maximum).Maximum
  foreach ($o in @($objs | Where-Object { [int]$_['v'] -eq $vmax })) {
    $sess.Add([pscustomobject]@{ car = [string]$o['car']; track = [string]$o['track']; cfg = [string]$o['config']; ticks = [long]$o['ticks']; at = @($o['sectorAt'] | ForEach-Object { [double]$_ }); laps = @($o['laps']) })
  }
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($g in ($sess | Where-Object { $_.car -and $_.track } | Group-Object { $_.car + '|' + $_.track + '|' + $_.cfg })) {
    $ss = @($g.Group | Where-Object { $_.laps.Count -gt 0 } | Sort-Object ticks)
    if ($ss.Count -eq 0) { continue }
    $pb = 1e9; $n = 0; foreach ($s in $ss) { foreach ($l in $s.laps) { $n++; $t = [double]$l[1]; if ($t -lt $pb) { $pb = $t } } }
    $ref = $ss[0].at; $nS = $ref.Count
    if ($nS -lt 2 -or $n -lt 2) { continue }
    $best = New-Object 'double[]' $nS; for ($k = 0; $k -lt $nS; $k++) { $best[$k] = 1e9 }
    foreach ($s in $ss) {
      $same = ($s.at.Count -eq $nS); for ($k = 0; $same -and $k -lt $nS; $k++) { if ([math]::Abs($s.at[$k] - $ref[$k]) -gt 1e-5) { $same = $false } }
      if (-not $same) { continue }
      # L-1b: only laps with no off-track record are joined (the 5th number of a lap in the cache is 1 for such a lap; the PB above still counts every counted lap)
      foreach ($l in $s.laps) { if (@($l).Count -ge 5 -and [int]$l[4] -eq 0) { continue }; for ($k = 0; $k -lt $nS; $k++) { $ms = Round3 $l[2][$k]; if ($ms -lt $best[$k]) { $best[$k] = $ms } } }
    }
    $theo = 0.0; $okTh = $true; for ($k = 0; $k -lt $nS; $k++) { if ($best[$k] -ge 1e9) { $okTh = $false } else { $theo += $best[$k] } }
    if (-not $okTh -or $theo -gt $pb + 0.0005) { continue }      # nothing to join, or the PB lap is quicker than anything that can be joined: no row
    $car = $ss[0].car; $track = $ss[0].track; $cfg = $ss[0].cfg
    # the newest session of this car and track (any layout, with or without laps) decides which layout a pick would start on
    $newest = @($sess | Where-Object { $_.car -eq $car -and $_.track -eq $track } | Sort-Object ticks -Descending)[0]
    $rows.Add([pscustomobject]@{ car = $car; track = $track; cfg = $cfg; pb = $pb; theo = $theo; gap = $pb - $theo; sessions = $ss.Count; laps = $n; newest = ($newest.cfg -eq $cfg) })
  }
  return @($rows | Sort-Object @{ e = { $_.gap }; Descending = $true }, @{ e = { $_.car + '|' + $_.track + '|' + $_.cfg } })
}
function Compare-Gain($J, $ind, $tag) {
  $c = @($J.combos)
  Check "${tag}: the same number of combinations as the independent computation ($($ind.Count))" ($c.Count -eq $ind.Count)
  $same = $c.Count -eq $ind.Count; $why = ''
  for ($i = 0; $same -and $i -lt $c.Count; $i++) {
    $a = $c[$i]; $b = $ind[$i]
    if ($a.car -ne $b.car -or $a.track -ne $b.track -or $a.config -ne $b.cfg) { $same = $false; $why = "row $i is $($a.car) / $($a.track) / $($a.config), expected $($b.car) / $($b.track) / $($b.cfg)" }
    elseif (-not (Near $a.pb $b.pb 0.0006) -or -not (Near $a.theoretical $b.theo 0.0006) -or -not (Near $a.gap $b.gap 0.0011)) { $same = $false; $why = "row $i numbers: pb $($a.pb)/$($b.pb) theo $($a.theoretical)/$($b.theo) gap $($a.gap)/$($b.gap)" }
    elseif ($a.sessions -ne $b.sessions -or $a.laps -ne $b.laps) { $same = $false; $why = "row $i counts: sessions $($a.sessions)/$($b.sessions) laps $($a.laps)/$($b.laps)" }
    elseif ([bool]$a.newest -ne [bool]$b.newest) { $same = $false; $why = "row $i newest $($a.newest)/$($b.newest)" }
  }
  if ($why) { Note $why }
  Check "${tag}: every combination, in the same order (biggest gap first), with the same PB, theoretical best, gap, session and lap counts and newest-layout flag" $same
  $wantBest = @($ind | Where-Object { $_.gap -ge 0.01 })[0]
  if ($wantBest) { Check "${tag}: 'best' is the biggest gap: $($wantBest.car) at $($wantBest.track), $([math]::Round($wantBest.gap, 3)) s" ($J.best -and $J.best.car -eq $wantBest.car -and $J.best.track -eq $wantBest.track -and (Near $J.best.gap $wantBest.gap 0.0011)) }
  else { Check "${tag}: no combination has a gap of 10 ms or more, so 'best' is null" ($null -eq $J.best) }
}

Enter-TestLock 'rig-leftovers'   # one live test at a time (tests\guard.ps1); released in finally
try {
  New-Item -ItemType Directory -Force $work | Out-Null

  Section '1. compile without deploying (irdash, irdeck) and make the stand-in programs'
  $build = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'dash\build.ps1') -NoDeploy | Out-String
  $mb = [regex]::Match($build, 'built in (.+?) \(not deployed\)')
  Check 'dash\build.ps1 -NoDeploy compiled (gain.cs and rigwin.cs are in its source list)' ($LASTEXITCODE -eq 0 -and $mb.Success -and ((Get-Content (Join-Path $root 'dash\build.ps1') -Raw) -match 'gain\.cs') -and ((Get-Content (Join-Path $root 'dash\build.ps1') -Raw) -match 'rigwin\.cs'))
  if (-not $mb.Success) { throw $build }
  $binDir = Join-Path $work 'bin'; New-Item -ItemType Directory -Force $binDir | Out-Null
  Copy-Item (Join-Path $mb.Groups[1].Value.Trim() 'irdash.exe') (Join-Path $binDir 'irdash.exe')      # a private copy: other agents compile at the same time
  $irdash = Join-Path $binDir 'irdash.exe'
  $build2 = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build-irdeck.ps1') -NoDeploy | Out-String
  $m2 = [regex]::Match($build2, 'built in (.+?) \(not deployed\)')
  Check 'build-irdeck.ps1 -NoDeploy compiled (tunerbox.cs is in its source list)' ($LASTEXITCODE -eq 0 -and $m2.Success -and ((Get-Content (Join-Path $root 'build-irdeck.ps1') -Raw) -match 'tunerbox\.cs'))
  if (-not $m2.Success) { throw $build2 }
  $cliDir = Join-Path $work 'cli'; New-Item -ItemType Directory -Force $cliDir | Out-Null
  Copy-Item (Join-Path $m2.Groups[1].Value.Trim() 'irdeck-cli.exe') (Join-Path $cliDir 'irdeck-cli.exe')
  $irdeckCli = Join-Path $cliDir 'irdeck-cli.exe'
  [IO.File]::WriteAllText((Join-Path $work 'stand.cs'), $standSrc)
  & $csc /nologo /target:winexe /optimize+ ('/out:' + (Join-Path $work 'tunerfake.exe')) (Join-Path $work 'stand.cs')
  Check 'the stand-in program compiled' ($LASTEXITCODE -eq 0)
  foreach ($n in 'tunerother', 'tunerfake2', 'iracingfake') { Copy-Item (Join-Path $work 'tunerfake.exe') (Join-Path $work "$n.exe") }

  Section '2. the Tuner box: irdash (the shipped Rig Doctor code) hides exactly the blank box of the Tuner program'
  $fg0 = [RlWin]::GetForegroundWindow()
  $ta = Start-Stand (Join-Path $work 'tunerfake.exe') 'tuner' 340 (-1040)          # the Tuner: hidden main window
  $tb = Start-Stand (Join-Path $work 'tunerother.exe') 'tuner' 340 (-300)           # another program with the very same windows (not named as the Tuner)
  $wa = WinsOf $ta; $wb = WinsOf $tb
  $box = Pick $wa 'Qt6103QWindowToolSaveBits' 'Tuner' 250
  $boxSmall = @($wa | Where-Object { $_.Class -eq 'Qt6103QWindowToolSaveBits' -and $_.Title -eq 'Tuner' -and $_.W -eq 300 -and ($_.Ex -band 8) })[0]
  $main = Pick $wa 'Qt6103QWindowIcon' 'Simucube Tuner'
  $other = @($wb | Where-Object { $_.Class -eq 'Qt6103QWindowToolSaveBits' -and $_.Title -eq 'Tuner' -and $_.W -eq 300 })[0]
  $lookTitle = Pick $wa 'Qt6103QWindowToolSaveBits' 'Tuner Notice'; $lookClass = Pick $wa 'Qt6103QWindowPopup' 'Tuner'
  $lookTop = @($wa | Where-Object { $_.Class -eq 'Qt6103QWindowToolSaveBits' -and $_.Title -eq 'Tuner' -and $_.W -eq 300 -and -not ($_.Ex -band 8) })[0]
  $lookBig = @($wa | Where-Object { $_.Class -eq 'Qt6103QWindowToolSaveBits' -and $_.Title -eq 'Tuner' -and $_.W -gt 800 })[0]
  Check 'the stand-in shows the box (class Qt6103QWindowToolSaveBits, title Tuner, 300x150, visible, popup, topmost, tool window) and its main window is hidden' ($boxSmall -and $boxSmall.Visible -and $boxSmall.W -eq 300 -and $boxSmall.Ht -eq 150 -and ($boxSmall.Style -band $WS_POPUP) -and ($boxSmall.Ex -band 8) -and ($boxSmall.Ex -band 0x80) -and $main -and -not $main.Visible)
  Check 'and five look-alikes: other title, other class, not topmost, far too big (same program), the same box in another program' ($lookTitle.Visible -and $lookClass.Visible -and $lookTop.Visible -and $lookBig.Visible -and $other.Visible)
  # the box is the one that is topmost + small + exact title/class; the not-topmost look-alike is a second 300x150 "Tuner"
  $boxH = @($wa | Where-Object { $_.Class -eq 'Qt6103QWindowToolSaveBits' -and $_.Title -eq 'Tuner' -and $_.W -eq 300 -and ($_.Ex -band 8) })[0].H
  $before = @($wa | ForEach-Object { $_.H }) + @($wb | ForEach-Object { $_.H })

  $dry = Invoke-Exe $irdash "--analysis --rigwin tunerbox --dry --owner tunerfake --out `"$(Join-Path $work 'tb-dry.json')`""
  $dj = Json-Out (Join-Path $work 'tb-dry.json')
  Check 'a dry look finds exactly one window to hide (and hides nothing)' ($dry.exit -eq 0 -and $dj.count -eq 1 -and [RlWin]::IsWindowVisible($boxH))
  Check 'the dry look says where it is: 300x150' ($dj.boxes[0] -like '300x150 at 340,*')

  $run1 = Invoke-Exe $irdash "--analysis --rigwin tunerbox --owner tunerfake --out `"$(Join-Path $work 'tb-run.json')`""
  $rj = Json-Out (Join-Path $work 'tb-run.json')
  $gone = $false; for ($i = 0; $i -lt 40 -and -not $gone; $i++) { if (-not [RlWin]::IsWindowVisible($boxH)) { $gone = $true } else { Start-Sleep -Milliseconds 100 } }
  Check 'one look hides the blank box (within 4 s)' ($run1.exit -eq 0 -and $rj.count -eq 1 -and $gone)
  Check 'it was hidden, not closed: the window still exists, the program is still running' ([RlWin]::IsWindow($boxH) -and -not $ta.HasExited)
  $wa2 = WinsOf $ta; $wb2 = WinsOf $tb
  $stay = @($wa2 | Where-Object { $_.H -ne $boxH })
  Check 'every other window of the Tuner program is as it was (same windows, same visibility): hidden main window, other title, other class, not topmost, too big' ($stay.Count -eq ($wa.Count - 1) -and (@($stay | Where-Object { $_.Visible }).Count -eq @($wa | Where-Object { $_.H -ne $boxH -and $_.Visible }).Count) -and (WinsOf $ta).Count -eq $wa.Count)
  Check 'the same window set in the other program (not the Tuner) is untouched' ($wb2.Count -eq $wb.Count -and $other.Visible -and [RlWin]::IsWindowVisible($other.H) -and (@($wb2 | Where-Object { $_.Visible }).Count -eq @($wb | Where-Object { $_.Visible }).Count))
  Check 'no window of any stand-in was destroyed' (@($before | Where-Object { -not [RlWin]::IsWindow($_) }).Count -eq 0)
  Check 'the focus did not move' ([RlWin]::GetForegroundWindow() -eq $fg0)
  $run2 = Invoke-Exe $irdash "--analysis --rigwin tunerbox --owner tunerfake --out `"$(Join-Path $work 'tb-run2.json')`""
  Check 'a second look hides nothing more (count 0)' ((Json-Out (Join-Path $work 'tb-run2.json')).count -eq 0)
  # the Tuner's own window open on screen = someone is using the Tuner: its pop-ups are left alone
  $tc = Start-Stand (Join-Path $work 'tunerfake2.exe') 'tuner' 340 (-700) 'openmain'
  $wc = WinsOf $tc; $boxC = @($wc | Where-Object { $_.Class -eq 'Qt6103QWindowToolSaveBits' -and $_.Title -eq 'Tuner' -and $_.W -eq 300 -and ($_.Ex -band 8) })[0]
  $mainC = Pick $wc 'Qt6103QWindowIcon' 'Simucube Tuner'
  Check 'second stand-in: its Tuner main window is open on screen' ($mainC.Visible -and $boxC.Visible)
  $run3 = Invoke-Exe $irdash "--analysis --rigwin tunerbox --owner tunerfake2 --out `"$(Join-Path $work 'tb-run3.json')`""
  Start-Sleep -Milliseconds 700
  Check 'with the Tuner''s main window open, nothing is hidden (it is being used)' ((Json-Out (Join-Path $work 'tb-run3.json')).count -eq 0 -and [RlWin]::IsWindowVisible($boxC.H) -and [RlWin]::IsWindowVisible($mainC.H))
  Stop-Stand $tc; Stop-Stand $ta; Stop-Stand $tb

  Section '3. the Tuner box: irdeck (RIG ON) does the same'
  $fg0 = [RlWin]::GetForegroundWindow()
  $ta = Start-Stand (Join-Path $work 'tunerfake.exe') 'tuner' 340 (-1040)
  $tb = Start-Stand (Join-Path $work 'tunerother.exe') 'tuner' 340 (-300)
  $wa = WinsOf $ta; $wb = WinsOf $tb
  $boxH = @($wa | Where-Object { $_.Class -eq 'Qt6103QWindowToolSaveBits' -and $_.Title -eq 'Tuner' -and $_.W -eq 300 -and ($_.Ex -band 8) })[0].H
  $otherH = @($wb | Where-Object { $_.Class -eq 'Qt6103QWindowToolSaveBits' -and $_.Title -eq 'Tuner' -and $_.W -eq 300 -and ($_.Ex -band 8) })[0].H
  $before = @($wa | ForEach-Object { $_.H }) + @($wb | ForEach-Object { $_.H })
  $d2 = Invoke-Exe $irdeckCli 'tunerbox --dry --owner tunerfake'
  Check 'irdeck tunerbox --dry finds the box and hides nothing' ($d2.exit -eq 0 -and $d2.out -match 'blank box is here: 300x150' -and [RlWin]::IsWindowVisible($boxH))
  $r2 = Invoke-Exe $irdeckCli 'tunerbox --owner tunerfake'
  $gone = $false; for ($i = 0; $i -lt 40 -and -not $gone; $i++) { if (-not [RlWin]::IsWindowVisible($boxH)) { $gone = $true } else { Start-Sleep -Milliseconds 100 } }
  Check 'irdeck tunerbox hides the box (within 4 s) and says so' ($r2.exit -eq 0 -and $gone -and $r2.out -match 'hid the Simucube Tuner')
  Check 'and nothing else: the other program''s identical box is still there, every window still exists, the focus did not move' ([RlWin]::IsWindowVisible($otherH) -and (@($before | Where-Object { -not [RlWin]::IsWindow($_) }).Count -eq 0) -and [RlWin]::GetForegroundWindow() -eq $fg0 -and -not $ta.HasExited)
  $r3 = Invoke-Exe $irdeckCli 'tunerbox'
  Check 'without a stand-in name it looks only at sc-tuner: the stand-ins are left alone' ($r3.exit -eq 0 -and [RlWin]::IsWindowVisible($otherH))
  Check 'RIG ON calls it at its end (irdeck.cs CmdRigOn) and the key table knows the command' (((Get-Content (Join-Path $root 'src\irdeck.cs') -Raw) -match 'HideTunerBox\(false, ""\)') -and ((Get-Content (Join-Path $root 'src\irdeck.cs') -Raw) -match 'case "tunerbox"'))
  Stop-Stand $ta; Stop-Stand $tb

  Section '4. the REAL Simucube Tuner: read only'
  $real = @(Get-Process sc-tuner -ErrorAction SilentlyContinue)
  if ($real.Count -eq 0) { Note 'sc-tuner is not running now: nothing to look at (the rules above were proved on the stand-ins)' }
  else {
    $rw = @([RlWin]::Of(@($real | ForEach-Object { $_.Id })))
    $exact = @($rw | Where-Object { $_.Visible -and $_.Class -match '^Qt\d+QWindowToolSaveBits$' -and $_.Title -eq 'Tuner' -and $_.W -ge 100 -and $_.W -le 400 -and $_.Ht -ge 50 -and $_.Ht -le 250 -and ($_.Style -band $WS_POPUP) -and ($_.Ex -band 8) -and ($_.Ex -band 0x80) })
    $mainOpen = @($rw | Where-Object { $_.Visible -and $_.Class -match '^Qt\d+QWindowIcon$' }).Count
    Note ("the Tuner (pid {0}) has {1} windows, {2} of them visible: {3}" -f $real[0].Id, $rw.Count, @($rw | Where-Object { $_.Visible }).Count, ((@($rw | Where-Object { $_.Visible } | ForEach-Object { "$($_.Class) '$($_.Title)' $($_.W)x$($_.Ht)" })) -join '; '))
    $rd = Invoke-Exe $irdash "--analysis --rigwin tunerbox --dry --out `"$(Join-Path $work 'tb-real.json')`""
    $rrj = Json-Out (Join-Path $work 'tb-real.json')
    $wantCount = if ($mainOpen -gt 0) { 0 } else { $exact.Count }
    Check "the rule finds the same blank box(es) as an independent look at the real Tuner's windows: $wantCount$(if ($exact.Count -gt 0) { ' (the grey 300x150 box is on screen now)' } else { ' (no blank box on screen: already hidden)' })" ($rd.exit -eq 0 -and $rrj.count -eq $wantCount)
    if ($exact.Count -gt 0) { Check 'the real box is a different window from the Tuner''s main window ("Simucube Tuner", class Qt..QWindowIcon), which the rule never matches' (@($rw | Where-Object { $_.Class -match 'QWindowIcon$' -and $exact.H -contains $_.H }).Count -eq 0) }
    Check 'looking changed nothing: the Tuner is still running' (-not $real[0].HasExited)
  }

  Section '5. the iRacing UI window finder (a tiny untitled strip window on top must not win)'
  $ui1 = Start-Stand (Join-Path $work 'iracingfake.exe') 'ui' 340 (-1040) 'titled'
  $wu = WinsOf $ui1
  $titled = Pick $wu 'BigClass' 'iRacing'; $strip = Pick $wu 'StripClass' ''
  Check 'the stand-in has the window titled "iRacing" (1280x720), a bigger untitled window and a 459x25 strip made last' ($titled.W -eq 1280 -and $strip.W -eq 459 -and $strip.Ht -eq 25 -and @($wu | Where-Object { $_.Class -eq 'BigClass' -and $_.Title -eq '' -and $_.W -eq 1500 }).Count -eq 1)
  $mw = $null; try { $mw = $ui1.MainWindowHandle } catch { }
  Note ("Process.MainWindowHandle of the stand-in is {0} ({1}); the strip is {2}, the titled window {3}" -f $mw, $(if ($mw -eq $strip.H) { 'the strip: the trap' } elseif ($mw -eq $titled.H) { 'the titled window' } else { 'some other window' }), $strip.H, $titled.H)
  Invoke-Exe $irdash "--analysis --rigwin uiwindow --proc iracingfake --out `"$(Join-Path $work 'ui1.json')`"" | Out-Null
  $u1 = Json-Out (Join-Path $work 'ui1.json')
  Check 'the finder picks the window titled "iRacing", not the strip and not the bigger untitled window' ($u1.found -and $u1.hwnd -eq $titled.H.ToInt64() -and $u1.title -eq 'iRacing' -and $u1.w -eq 1280)
  Stop-Stand $ui1
  $ui2 = Start-Stand (Join-Path $work 'iracingfake.exe') 'ui' 340 (-1040) 'untitled'
  $wu = WinsOf $ui2; $big = @($wu | Where-Object { $_.Class -eq 'BigClass' })[0]; $strip = Pick $wu 'StripClass' ''
  Invoke-Exe $irdash "--analysis --rigwin uiwindow --proc iracingfake --out `"$(Join-Path $work 'ui2.json')`"" | Out-Null
  $u2 = Json-Out (Join-Path $work 'ui2.json')
  Check 'with no window titled "iRacing", the largest visible window wins (1500x900), never the 459x25 strip' ($u2.found -and $u2.hwnd -eq $big.H.ToInt64() -and $u2.w -eq 1500 -and $u2.hwnd -ne $strip.H.ToInt64())
  Stop-Stand $ui2
  Invoke-Exe $irdash "--analysis --rigwin uiwindow --proc iracingfake --out `"$(Join-Path $work 'ui3.json')`"" | Out-Null
  Check 'with no such program running, nothing is found (no crash)' ((Json-Out (Join-Path $work 'ui3.json')).found -eq $false)
  $realUi = @(Get-Process iRacingUI -ErrorAction SilentlyContinue)
  if ($realUi.Count -gt 0) {
    $ru = @([RlWin]::Of(@($realUi | ForEach-Object { $_.Id }))) | Where-Object { $_.Visible }
    $rt = @($ru | Where-Object { $_.Title -eq 'iRacing' })
    Invoke-Exe $irdash "--analysis --rigwin uiwindow --proc iRacingUI --out `"$(Join-Path $work 'ui4.json')`"" | Out-Null
    $u4 = Json-Out (Join-Path $work 'ui4.json')
    if ($rt.Count -gt 0) { Check "the REAL iRacing UI (read only): the finder returns its window titled ""iRacing"" ($($rt[0].W)x$($rt[0].Ht))" ($u4.found -and $u4.hwnd -eq $rt[0].H.ToInt64()) }
    else { Check 'the REAL iRacing UI has no window titled "iRacing" now: the finder returns its largest visible window' ($u4.found -and $u4.hwnd -eq (@($ru | Sort-Object { $_.W * $_.Ht } -Descending)[0]).H.ToInt64()) }
  } else { Note 'the iRacing UI is not running now: the real window is not looked at' }
  $uiLines = @(Select-String -CaseSensitive -Path (Join-Path $root 'dash\src\*.cs') -Pattern 'iRacingUI' | Where-Object { $_.Line -match 'MainWindow' -and $_.Line -notmatch '^\s*//' })
  Check 'no irdash code asks Process.MainWindowHandle / MainWindowTitle about the iRacing UI any more' ($uiLines.Count -eq 0)
  $docLines = @(Select-String -CaseSensitive -Path (Join-Path $root 'dash\src\doctor.cs') -Pattern 'MainWindowHandle|MainWindowTitle' | Where-Object { $_.Line -notmatch '^\s*//' })
  Check 'the Rig Doctor timing log (boot_ui) and the watchdog''s UI restart use the safe finder (RigWin)' ($docLines.Count -eq 0 -and ((Get-Content (Join-Path $root 'dash\src\irdash.cs') -Raw) -match 'RigWin\.CloseIracingUi') -and ((Get-Content (Join-Path $root 'dash\src\doctor.cs') -Raw) -match 'RigWin\.IracingUiReady'))

  Section '6. MOST TO GAIN over scratch copies of real sessions'
  $tel = Join-Path $work 'tel'; $vault = Join-Path $work 'vault'
  New-Item -ItemType Directory -Force $tel, $vault | Out-Null
  $vs = Join-Path $root 'vault\telemetry\chevrolet-corvette-z06-gt3-r\road-atlanta-full-course'
  $pre = 'chevyvettez06rgt3_roadatlanta full '
  $docTel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
  $newestDoc = Get-ChildItem -LiteralPath $docTel -Filter '*.ibt' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  function Copy-Keep($from, $to) { Copy-Item -LiteralPath $from -Destination $to; (Get-Item -LiteralPath $to).LastWriteTime = (Get-Item -LiteralPath $from).LastWriteTime }
  $setA = @('2026-10-07 09-34-52', '2026-10-09 14-58-37', '2026-10-10 00-13-18')               # the Corvette at Road Atlanta, as it is
  $setB = @('2026-10-07 21-31-29', '2026-10-09 10-28-32', '2026-10-09 23-23-41')               # the same files' kind, car name patched in the copy: a second combination
  $setC = @('2026-10-06 21-26-58')                                                             # one older session, layout name patched in the copy: a layout his newest session was not on
  # L-1: the Vault keeps copies only of laps iRacing counted, so a copy can disappear; the same untouched file then comes from the telemetry folder
  function Src($s) { $v = Join-Path $vs "$s.ibt"; if (Test-Path -LiteralPath $v) { return $v }; return (Join-Path $docTel ($pre + $s + '.ibt')) }
  foreach ($s in ($setA + $setB + $setC)) { Check "the real file is there (the vault's copy, else the original): $s" (Test-Path -LiteralPath (Src $s)) }
  foreach ($s in $setA) { Copy-Keep (Src $s) (Join-Path $tel ($pre + $s + '.ibt')) }
  function Patch-Copy($to, $from, $new) { $n = [IbtPatch]::Replace($to, $from, $new); (Get-Item -LiteralPath $to).LastWriteTime = (Get-Item -LiteralPath (Src ((Split-Path $to -Leaf).Substring($pre.Length) -replace '\.ibt$', ''))).LastWriteTime; return $n }
  $nB = 0; foreach ($s in $setB) { $to = Join-Path $tel ($pre + $s + '.ibt'); Copy-Keep (Src $s) $to; $nB += Patch-Copy $to 'CarScreenName: Chevrolet Corvette Z06 GT3.R' 'CarScreenName: Chevrolet Corvette Z06 GT3.X' }
  $to = Join-Path $tel ($pre + $setC[0] + '.ibt'); Copy-Keep (Src $setC[0]) $to
  $nC = Patch-Copy $to 'TrackConfigName: Full Course' 'TrackConfigName: Short Track'
  Check "the copies were patched in their session text only (car name in $nB places, layout name in $nC places)" ($nB -ge 3 -and $nC -ge 1)
  $fer = @('ferrari296gt3_sebring international 2026-10-10 22-29-06.ibt', 'ferrari296gt3_sebring international 2026-10-10 22-54-33.ibt')   # real Ferrari files: two laps, no gain
  foreach ($n in $fer) { Copy-Keep (Join-Path $docTel $n) (Join-Path $tel $n) }
  Check 'none of the copied real files is the newest telemetry file (nothing here is being written)' (-not $newestDoc -or -not ($fer | Where-Object { $newestDoc.Name -eq $_ }))
  Note ("{0} MB copied into {1}" -f [math]::Round(((Get-ChildItem $work -Recurse -File -Filter '*.ibt' | Measure-Object Length -Sum).Sum) / 1MB), $tel)

  $g1 = Invoke-Exe $irdash "--analysis --gain --root `"$root`" --dir `"$tel`" --vault `"$vault`" --out `"$(Join-Path $work 'gain1.json')`""
  $G = Json-Out (Join-Path $work 'gain1.json')
  Check 'the gain engine answers (exit 0, no error)' ($g1.exit -eq 0 -and $G -and -not $G.error)
  if (-not $G -or $G.error) { throw "gain failed: $($g1.out)" }
  Note ("first run {0} ms; combinations: {1}" -f $g1.ms, ((@($G.combos) | ForEach-Object { "$($_.car) / $($_.track) / $($_.config): gap $($_.gap)" }) -join ' | '))
  $ind = @(Independent-Gain (Join-Path $vault 'career'))
  Check "the independent computation (from the career cache files the run wrote) finds the same kind of rows: $($ind.Count)" ($ind.Count -ge 3)
  Compare-Gain $G $ind 'scratch'
  $gaps = @($G.combos | Where-Object { $_.gap -ge 0.01 })
  Check 'at least two combinations have a real gap, so the ranking means something' ($gaps.Count -ge 2)
  $A = @($G.combos | Where-Object { $_.car -eq 'Chevrolet Corvette Z06 GT3.R' -and $_.config -eq 'Full Course' })[0]
  Check 'the Corvette at Road Atlanta from the 3 real sessions: PB 79.549 (the quickest counted lap of the PB session, lap 7)' ($A -and (Near $A.pb 79.549 0.0006) -and $A.sessions -eq 3)
  $sh = @($G.combos | Where-Object { $_.config -eq 'Short Track' })[0]
  Check 'the layout his newest session of this car and track was NOT on is listed but marked newest=false (a pick of that drive would start on the other layout)' ($sh -and $sh.newest -eq $false -and $A.newest -eq $true)
  $fe = @($G.combos | Where-Object { $_.car -eq 'Ferrari 296 GT3' })[0]
  Check 'the Ferrari with two clean laps and the same sectors has no gain (0.000) and is last' ($fe -and $fe.gap -lt 0.01 -and ($G.combos[-1].car -eq 'Ferrari 296 GT3'))
  # the Career page's own figures for the same combinations (CrAggregate, checked against the raw files by career-test)
  foreach ($cmb in @($G.combos | Where-Object { $_.gap -ge 0.01 })) {
    $o = Join-Path $work ('cr-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    $cr = Invoke-Exe $irdash "--analysis --career --root `"$root`" --dir `"$tel`" --vault `"$vault`" --car `"$($cmb.car)`" --track `"$($cmb.track)`" --config `"$($cmb.config)`" --out `"$o`""
    $C = Json-Out $o
    Check "the Career page says the same for $($cmb.car) / $($cmb.config): PB $($cmb.pb), theoretical $($cmb.theoretical), gap $($cmb.gap)" ($cr.exit -eq 0 -and $C.theoretical -and (Near $C.pb.time $cmb.pb 0.0006) -and (Near $C.theoretical.time $cmb.theoretical 0.0006) -and (Near $C.theoretical.gap $cmb.gap 0.0011))
  }
  $g2 = Invoke-Exe $irdash "--analysis --gain --root `"$root`" --dir `"$tel`" --vault `"$vault`" --out `"$(Join-Path $work 'gain2.json')`""
  $GJ2 = Json-Out (Join-Path $work 'gain2.json')
  $sameAns = ($g2.exit -eq 0 -and (($GJ2.combos | ConvertTo-Json -Compress -Depth 5) -eq ($G.combos | ConvertTo-Json -Compress -Depth 5)))
  if (-not $sameAns) { Note ("second run: exit {0}; first {1}; second {2}" -f $g2.exit, (($G.combos | ConvertTo-Json -Compress -Depth 5) + ''), (($GJ2.combos | ConvertTo-Json -Compress -Depth 5) + '')) }
  Check "the second run reads no .ibt (all from the cache files) and gives the same answer ($($g2.ms) ms)" $sameAns
  # an empty folder is not an error
  $emptyTel = Join-Path $work 'empty'; New-Item -ItemType Directory -Force $emptyTel | Out-Null
  $g3 = Invoke-Exe $irdash "--analysis --gain --root `"$root`" --dir `"$emptyTel`" --vault `"$(Join-Path $work 'vault-empty')`" --out `"$(Join-Path $work 'gain3.json')`""
  $GJ3 = Json-Out (Join-Path $work 'gain3.json')
  $emptyOk = ($g3.exit -eq 0 -and $GJ3 -and @($GJ3.combos).Count -eq 0 -and $null -eq $GJ3.best)
  if (-not $emptyOk) { Note ("empty folder: exit {0}; reply {1}" -f $g3.exit, $(if (Test-Path (Join-Path $work 'gain3.json')) { [IO.File]::ReadAllText((Join-Path $work 'gain3.json')) } else { '(no file)' })) }
  Check 'no sessions at all: no combinations, best is null' $emptyOk

  Section '7. the deployed irdash: /analysis/gain and the "gain" object of /mydrive'
  $deployed = Get-Item (Join-Path $root 'dash\irdash.exe')
  $newer = ($deployed.LastWriteTime -gt (Get-Item (Join-Path $root 'dash\src\gain.cs')).LastWriteTime) -and ($deployed.LastWriteTime -gt (Get-Item (Join-Path $root 'dash\src\mydrive.cs')).LastWriteTime) -and ($deployed.LastWriteTime -gt (Get-Item (Join-Path $root 'dash\src\rigwin.cs')).LastWriteTime)
  $probe = $null; try { $probe = Get-Raw '/analysis/gain' } catch { }
  if (-not $newer -or -not $probe -or $probe.code -ne 200) {
    Note "SKIPPED: the running irdash does not have /analysis/gain yet (irdash.exe $($deployed.LastWriteTime), probe code $(if ($probe) { $probe.code } else { 'none' })). Deploy with dash\build.ps1 when the sim is off, then run this test again."
  } else {
    Assert-RigFree -Where 'before the live part'
    # the real tuner box: the deployed Rig Doctor hides it by itself (what Peter sees)
    $realTuner = @(Get-Process sc-tuner -ErrorAction SilentlyContinue)
    # A. the Tuner box through the running irdash (a stand-in named in dash\tuner-owner.txt), the way Rig Doctor runs it
    $fg0 = [RlWin]::GetForegroundWindow()
    $ta = Start-Stand (Join-Path $work 'tunerfake.exe') 'tuner' 340 (-1040)
    $tb = Start-Stand (Join-Path $work 'tunerother.exe') 'tuner' 340 (-300)
    $wa = WinsOf $ta; $wb = WinsOf $tb
    $boxH = @($wa | Where-Object { $_.Class -eq 'Qt6103QWindowToolSaveBits' -and $_.Title -eq 'Tuner' -and $_.W -eq 300 -and ($_.Ex -band 8) })[0].H
    $otherH = @($wb | Where-Object { $_.Class -eq 'Qt6103QWindowToolSaveBits' -and $_.Title -eq 'Tuner' -and $_.W -eq 300 -and ($_.Ex -band 8) })[0].H
    $all0 = @($wa | ForEach-Object { $_.H }) + @($wb | ForEach-Object { $_.H })
    $logN = @(Get-Content (Join-Path $root 'dash\irdash.log')).Count
    [IO.File]::WriteAllText($ownerFile, "tunerfake`r`n")
    for ($i = 0; $i -lt 40; $i++) { $dr = Get-Raw '/doctor'; if ($dr.code -eq 200 -and -not ($dr.body | ConvertFrom-Json).running) { break }; Start-Sleep -Milliseconds 250 }
    $null = Invoke-WebRequest -UseBasicParsing "$apiBase/api/doctor/run?quiet=1" -TimeoutSec 8
    $gone = $false; for ($i = 0; $i -lt 250 -and -not $gone; $i++) { if (-not [RlWin]::IsWindowVisible($boxH)) { $gone = $true } else { Start-Sleep -Milliseconds 100 } }
    Check 'live: one Rig Doctor run in the deployed irdash hides the stand-in Tuner''s blank box (within 25 s: the run itself, or the 20-second look)' $gone
    Check 'live: nothing else moved: the other program''s box and every window are there, the focus is where it was' ([RlWin]::IsWindowVisible($otherH) -and (@($all0 | Where-Object { -not [RlWin]::IsWindow($_) }).Count -eq 0) -and [RlWin]::GetForegroundWindow() -eq $fg0 -and -not $ta.HasExited)
    $log = @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logN)
    Check 'live: irdash.log says it once: "Rig Doctor: hid the Simucube Tuner''s blank box (300x150 at 340,-1040)"' (@($log | Where-Object { $_ -match "hid the Simucube Tuner's blank box \(300x150 at 340,-1040\)" }).Count -eq 1)
    Remove-Item -LiteralPath $ownerFile -Force -ErrorAction SilentlyContinue
    Stop-Stand $ta; Stop-Stand $tb
    # A2. the same while he drives (pretend, test hook): the 20-second look still hides it, and posting the hide moves no focus
    $hook = Join-Path $root 'dash\test-hook.on'; $lock = Join-Path $root 'dash\deploy.lock'
    Set-Content $lock 'rig-leftovers-test'; Set-Content $hook 'on for the test'; Start-Sleep -Milliseconds 400
    $td = $null
    try {
      $null = Invoke-WebRequest -UseBasicParsing "$apiBase/api/test/frame?IsOnTrack=1&OnPitRoad=0&SessionNum=2&PlayerCarIdx=0&Lap=4&LapDistPct=0.4&Speed=45&Gear=4&SessionFlags=0" -TimeoutSec 8
      Start-Sleep -Milliseconds 2600
      $drvNow = (Get-Raw '/mydrive').body | ConvertFrom-Json
      $fg0 = [RlWin]::GetForegroundWindow()
      $td = Start-Stand (Join-Path $work 'tunerfake.exe') 'tuner' 340 (-1040)
      $boxD = @((WinsOf $td) | Where-Object { $_.Class -eq 'Qt6103QWindowToolSaveBits' -and $_.Title -eq 'Tuner' -and $_.W -eq 300 -and ($_.Ex -band 8) })[0].H
      [IO.File]::WriteAllText($ownerFile, "tunerfake`r`n")
      $gone = $false; for ($i = 0; $i -lt 300 -and -not $gone; $i++) { if (-not [RlWin]::IsWindowVisible($boxD)) { $gone = $true } else { Start-Sleep -Milliseconds 100 } }
      Check 'live: even while he drives (pretend: /mydrive says driving) the 20-second look hides the Tuner box (within 30 s)' ($drvNow.driving -eq $true -and $gone)
      Check 'live: while driving, the hide moved no focus, closed nothing' ([RlWin]::GetForegroundWindow() -eq $fg0 -and [RlWin]::IsWindow($boxD) -and -not $td.HasExited)
    } finally {
      try { $null = Invoke-WebRequest -UseBasicParsing "$apiBase/api/test/frame?IsOnTrack=0&Speed=0" -TimeoutSec 8 } catch { }
      Start-Sleep -Milliseconds 600
      try { $null = Invoke-WebRequest -UseBasicParsing "$apiBase/api/test/end" -TimeoutSec 5 } catch { }
      Remove-Item $hook -ErrorAction SilentlyContinue; Remove-Item $lock -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $ownerFile -Force -ErrorAction SilentlyContinue
      if ($td) { Stop-Stand $td }
    }
    # B. the real box on this PC, if it is still there: the 20-second look hides it by itself
    if ($realTuner.Count -gt 0) {
      $rw = @([RlWin]::Of(@($realTuner | ForEach-Object { $_.Id })))
      $realBox = @($rw | Where-Object { $_.Class -match '^Qt\d+QWindowToolSaveBits$' -and $_.Title -eq 'Tuner' -and $_.W -le 400 -and ($_.Ex -band 8) })
      $before = @($rw | ForEach-Object { $_.H })
      if (@($realBox | Where-Object { $_.Visible }).Count -gt 0) {
        $gone = $false; for ($i = 0; $i -lt 300 -and -not $gone; $i++) { if (@($realBox | Where-Object { [RlWin]::IsWindowVisible($_.H) }).Count -eq 0) { $gone = $true } else { Start-Sleep -Milliseconds 100 } }
        Check 'live: the real Tuner box (grey, 300x150, always on top) is hidden by the deployed irdash within 30 s' $gone
      } else { Note 'live: the real Tuner box is already hidden' }
      Check 'live: the real Tuner still runs with all of its windows (hidden, not closed)' (-not $realTuner[0].HasExited -and (@($before | Where-Object { -not [RlWin]::IsWindow($_) }).Count -eq 0))
    }

    # C. MOST TO GAIN live
    $sw = [Diagnostics.Stopwatch]::StartNew(); $L = Get-Raw '/analysis/gain'; $polls = 0
    while ($L.code -eq 200 -and $L.body -like '{"building":true*' -and $sw.Elapsed.TotalSeconds -lt 600) { $polls++; Start-Sleep -Seconds 2; $L = Get-Raw '/analysis/gain' }
    Note ("live: /analysis/gain ready after {0} s ({1} polls)" -f [math]::Round($sw.Elapsed.TotalSeconds), $polls)
    Check 'live: /analysis/gain answers the list (ready)' ($L.code -eq 200 -and $L.body -like '{"v":1,"ready":true,*')
    $LJ = $L.body | ConvertFrom-Json
    $indReal = @(Independent-Gain (Join-Path $root 'vault\career'))
    Compare-Gain $LJ $indReal 'live'
    $sw.Restart(); $r2 = Get-Raw '/analysis/gain'
    Check 'live: asked again it answers at once from memory' ($r2.code -eq 200 -and $sw.ElapsedMilliseconds -lt 500 -and $r2.body -like '{"v":1,"ready":true,*')
    # /mydrive
    $mdRaw = Get-Raw '/mydrive'; $M = $mdRaw.body | ConvertFrom-Json
    $wantG = $null
    $ids = @{}; foreach ($x in @($M.all) + @($M.recent)) { if ($x) { $ids[$x.id] = $true } }
    $r0 = @($M.recent)[0]
    Check 'this test''s short-id function gives the id irdash gives the newest recent drive (so the checks below mean something)' ($r0 -and $r0.id -eq (Md-Id 'r' ($r0.car + '|' + $r0.track)))
    foreach ($row in $indReal) { if ($row.gap -lt 0.01) { break }; if ($row.newest -and $ids.ContainsKey((Md-Id 'r' ($row.car + '|' + $row.track)))) { $wantG = $row; break } }
    if ($wantG) {
      Note ("live: MOST TO GAIN is {0} at {1} ({2}), PB {3}, theoretical {4}, gap {5} s" -f $wantG.car, $wantG.track, $wantG.cfg, (Round3 $wantG.pb), (Round3 $wantG.theo), (Round3 $wantG.gap))
      Check '/mydrive carries gain = that drive, with the fields the add-on reads (id, car, carShort, track, trackShort, layout)' ($M.gain -and $M.gain.car -eq $wantG.car -and $M.gain.track -eq $wantG.track -and $M.gain.layout -eq $wantG.cfg -and $M.gain.id -eq (Md-Id 'r' ($wantG.car + '|' + $wantG.track)) -and $M.gain.carShort -and $M.gain.trackShort)
      Check '/mydrive gain: the id is one of his recent drives (so the MOST TO GAIN key can fill the choice) and the numbers are the list''s' ($ids.ContainsKey($M.gain.id) -and (Near $M.gain.gap $wantG.gap 0.0011) -and (Near $M.gain.pb $wantG.pb 0.0006))
    } else { Check '/mydrive carries gain = null because no recent drive has a gap of 10 ms or more' ($null -eq $M.gain) }
    # while he drives: 503 from the route, /mydrive still answers, nothing is started
    $hook = Join-Path $root 'dash\test-hook.on'; $lock = Join-Path $root 'dash\deploy.lock'
    Set-Content $lock 'rig-leftovers-test'; Set-Content $hook 'on for the test'; Start-Sleep -Milliseconds 400
    try {
      $null = Invoke-WebRequest -UseBasicParsing "$apiBase/api/test/frame?IsOnTrack=1&OnPitRoad=0&SessionNum=2&PlayerCarIdx=0&Lap=4&LapDistPct=0.4&Speed=45&Gear=4&SessionFlags=0" -TimeoutSec 8
      Start-Sleep -Milliseconds 800
      $drv = Get-Raw '/analysis/gain'
      Check 'live: while he drives (pretend, test hook) /analysis/gain says 503 "Not while driving"' ($drv.code -eq 503 -and $drv.body -like '*Not while driving*')
      $mdd = Get-Raw '/mydrive'
      $mddj = if ($mdd.code -eq 200) { $mdd.body | ConvertFrom-Json } else { $null }
      Check 'live: while he drives /mydrive still answers (the deck does not break), says driving, and keeps the gain it already knew' ($mddj -and $mddj.driving -eq $true -and (($null -eq $M.gain) -eq ($null -eq $mddj.gain)))
    } finally {
      try { $null = Invoke-WebRequest -UseBasicParsing "$apiBase/api/test/frame?IsOnTrack=0&Speed=0" -TimeoutSec 8 } catch { }
      Start-Sleep -Milliseconds 600
      try { $null = Invoke-WebRequest -UseBasicParsing "$apiBase/api/test/end" -TimeoutSec 5 } catch { }
      Remove-Item $hook -ErrorAction SilentlyContinue; Remove-Item $lock -ErrorAction SilentlyContinue
    }
    $after = Get-Raw '/analysis/gain'
    Check 'live: out of the car again the route answers the list' ($after.code -eq 200 -and $after.body -like '{"v":1,"ready":true,*')
    $logG = @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Last 400 | Where-Object { $_ -match 'gain:' })
    Check 'live: irdash.log says what it did ("gain: N car and track combinations worked out ...") and has no error' (@($logG | Where-Object { $_ -match 'worked out' }).Count -ge 1 -and @($logG | Where-Object { $_ -match 'gain:.*(Exception|failed)' }).Count -eq 0)
  }
} finally {
  foreach ($p in $procs) { Stop-Stand $p }
  Remove-Item -LiteralPath $ownerFile -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 300
  try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  Exit-TestLock
}
Section '8. nothing is left behind'
Check 'the stand-in programs are gone' (@(Get-Process tunerfake, tunerother, tunerfake2, iracingfake -ErrorAction SilentlyContinue).Count -eq 0)
Check 'the test owner file is gone' (-not (Test-Path $ownerFile))
$secs = [math]::Round(((Get-Date) - $t0).TotalSeconds)
''
"$pass passed, $fail failed. ($secs s)"
exit $fail
