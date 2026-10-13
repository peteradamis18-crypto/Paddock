# Rig Doctor clears a stray launcher error box (C-04).
# A real #32770 (the same class as the Explorer box that sat behind the sim) is owned by a stand-in process,
# not by explorer. dash\stray-owner.txt tells the doctor to treat that process as the launcher for this run.
# One doctor check must close the matching box, leave the others, and not move the focus.
#   powershell -ExecutionPolicy Bypass -File tests\doctor-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree

$shots = Join-Path $root 'tests\shots'
New-Item -ItemType Directory -Force $shots | Out-Null
$api = 'http://localhost:8199'
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Section($title) { Assert-RigFree -Where $title; Write-Output $title }
function J($path) { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 8; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class DocT {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static IntPtr Find(string title, int pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate (IntPtr h, IntPtr l) {
      uint p; GetWindowThreadProcessId(h, out p);
      if ((int)p != pid || !IsWindowVisible(h)) return true;
      var t = new StringBuilder(512); GetWindowText(h, t, 512);
      if (t.ToString() == title) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static string ClassOf(IntPtr h) { var s = new StringBuilder(64); GetClassName(h, s, 64); return s.ToString(); }
}
'@

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP 'paddock-c04'
New-Item -ItemType Directory -Force $tmp | Out-Null
$ownExe = Join-Path $tmp 'stray-own.exe'
$otherExe = Join-Path $tmp 'stray-other.exe'
$ownerFile = Join-Path $root 'dash\stray-owner.txt'
$title = 'C:\Users\peter\AppData\Local\irdashies\app-1.1.0\irdashies.exe'
$text = 'Windows cannot access the specified device, path, or file. The overlays app was updating.'
$decoyTitle = 'C:\Windows\System32\notepad.exe'
$src = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
class Stand {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int MessageBox(IntPtr h, string text, string cap, uint type);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("kernel32.dll")] static extern uint GetCurrentProcessId();
  static IntPtr Find(string title) {
    IntPtr found = IntPtr.Zero; uint me = GetCurrentProcessId();
    EnumWindows(delegate (IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != me) return true;
      StringBuilder t = new StringBuilder(512); GetWindowText(h, t, 512);
      if (t.ToString() == title) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  static void Show(string title, string text, int x, int y, IntPtr prev) {
    Thread box = new Thread(delegate () { MessageBox(IntPtr.Zero, text, title, 0); });
    box.IsBackground = true; box.SetApartmentState(ApartmentState.STA); box.Start();
    IntPtr h = IntPtr.Zero;
    for (int i = 0; i < 100 && h == IntPtr.Zero; i++) { Thread.Sleep(30); h = Find(title); }
    if (h != IntPtr.Zero) SetWindowPos(h, IntPtr.Zero, x, y, 0, 0, 0x0001 | 0x0004 | 0x0010);
    for (int i = 0; i < 10; i++) { SetForegroundWindow(prev); Thread.Sleep(30); if (GetForegroundWindow() == prev) break; }
    box.Join();
  }
  static int Main(string[] args) {
    if (args.Length < 4) return 2;
    int x = int.Parse(args[0]), y = int.Parse(args[1]);
    IntPtr prev = GetForegroundWindow();
    Thread decoy = null;
    if (args.Length > 4 && args[4] == "decoy") {
      decoy = new Thread(delegate () { Show(@"C:\Windows\System32\notepad.exe", "leave this window", x, y + 200, prev); });
      decoy.IsBackground = true; decoy.SetApartmentState(ApartmentState.STA); decoy.Start();
      Thread.Sleep(200);
    }
    Show(args[2], args[3], x, y, prev);
    if (decoy != null) decoy.Join();
    return 0;
  }
}
'@
$own = $null; $other = $null; $err = $null
try {
  Section '1. one doctor check closes the stray launcher box and leaves the focus where it was'
  [IO.File]::WriteAllText((Join-Path $tmp 'stand.cs'), $src)
  & $csc /nologo /target:winexe /optimize+ ('/out:' + $ownExe) (Join-Path $tmp 'stand.cs')
  if ($LASTEXITCODE -ne 0) { throw 'stand-in did not compile' }
  Copy-Item $ownExe $otherExe -Force
  $fg0 = [DocT]::GetForegroundWindow()
  # One quoted command line. Start-Process -ArgumentList splits on spaces, which cut the message down to "Windows".
  function Start-Stand($exe, $tail) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $tail
    $psi.UseShellExecute = $false
    return [Diagnostics.Process]::Start($psi)
  }
  $own = Start-Stand $ownExe ('40 1000 "' + $title + '" "' + $text + '" decoy')
  $other = Start-Stand $otherExe ('640 1000 "' + $title + '" "' + $text + '"')
  $hMatch = [IntPtr]::Zero; $hDecoy = [IntPtr]::Zero; $hOther = [IntPtr]::Zero
  for ($i = 0; $i -lt 50; $i++) {
    if ($hMatch -eq [IntPtr]::Zero) { $hMatch = [DocT]::Find($title, $own.Id) }
    if ($hDecoy -eq [IntPtr]::Zero) { $hDecoy = [DocT]::Find($decoyTitle, $own.Id) }
    if ($hOther -eq [IntPtr]::Zero) { $hOther = [DocT]::Find($title, $other.Id) }
    if ($hMatch -ne [IntPtr]::Zero -and $hDecoy -ne [IntPtr]::Zero -and $hOther -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 100
  }
  Check 'the stand-in showed three dialogs' ($hMatch -ne [IntPtr]::Zero -and $hDecoy -ne [IntPtr]::Zero -and $hOther -ne [IntPtr]::Zero)
  Check 'the fake error is a real dialog (class #32770)' ($hMatch -ne [IntPtr]::Zero -and [DocT]::ClassOf($hMatch) -eq '#32770')
  # the box takes the focus when it opens; the stand-in puts it back. Give that a moment, then put it back ourselves if needed.
  $fgBack = $false
  for ($i = 0; $i -lt 20; $i++) {
    $fg = [DocT]::GetForegroundWindow()
    if ($fg -ne $hMatch -and $fg -ne $hDecoy -and $fg -ne $hOther) { $fgBack = $true; break }
    [DocT]::SetForegroundWindow($fg0) | Out-Null
    Start-Sleep -Milliseconds 50
  }
  Check 'the fake dialog is not the focus before the check' $fgBack
  $rect = New-Object DocT+RECT
  if ($hMatch -ne [IntPtr]::Zero -and [DocT]::GetWindowRect($hMatch, [ref]$rect)) {
    $w = [Math]::Max(1, $rect.R - $rect.L); $hh = [Math]::Max(1, $rect.B - $rect.T)
    $bmp = New-Object System.Drawing.Bitmap $w, $hh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($rect.L, $rect.T, 0, 0, (New-Object System.Drawing.Size $w, $hh))
    $bmp.Save((Join-Path $shots 'c04-stray.png'))
    $g.Dispose(); $bmp.Dispose()
  }
  $fgBefore = [DocT]::GetForegroundWindow().ToInt64()
  [IO.File]::WriteAllText($ownerFile, "stray-own`r`n")
  for ($i = 0; $i -lt 40; $i++) { $d = J '/doctor'; if (-not $d.running) { break }; Start-Sleep -Milliseconds 250 }
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/doctor/run?quiet=1" -TimeoutSec 8
  $goneAt = $null
  for ($i = 0; $i -lt 80; $i++) {
    if (-not [DocT]::IsWindow($hMatch)) { $goneAt = $i; break }
    Start-Sleep -Milliseconds 100
  }
  $fgAfter = [DocT]::GetForegroundWindow().ToInt64()
  Check 'the fake dialog is closed within one check' ($hMatch -ne [IntPtr]::Zero -and $goneAt -ne $null -and $goneAt -lt 30)
  Check 'focus unchanged' ($fgAfter -eq $fgBefore)
  Check 'a box with the wrong title is left open' ([DocT]::IsWindow($hDecoy) -and [DocT]::IsWindowVisible($hDecoy))
  Check 'the same title owned by a different process is left open' ([DocT]::IsWindow($hOther) -and [DocT]::IsWindowVisible($hOther))
  $log = ''
  try { $log = [IO.File]::ReadAllText((Join-Path $root 'dash\irdash.log')) } catch { }
  $tail = if ($log.Length -gt 4000) { $log.Substring($log.Length - 4000) } else { $log }
  Check 'the doctor logged the title and the text it read' ($tail -match [regex]::Escape($title) -and $tail -match 'updating' -and $tail -match 'closed a launcher error')
} catch {
  $err = $_.Exception.Message
  Check "stopped: $err" $false
} finally {
  Remove-Item -LiteralPath $ownerFile -Force -ErrorAction SilentlyContinue
  foreach ($p in @($own, $other)) { try { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } } catch { } }
  Start-Sleep -Milliseconds 200
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Section '2. nothing is left behind'
Check 'the stand-in processes are gone' (@(Get-Process stray-own, stray-other -ErrorAction SilentlyContinue).Count -eq 0)
Check 'the test owner file is gone' (-not (Test-Path $ownerFile))
''
"$pass passed, $fail failed. Pictures in $shots"
exit $fail
