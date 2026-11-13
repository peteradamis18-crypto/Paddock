# Regression for two recorder bugs found from Peter's real logs (2026-10-18):
#  1. The recorder's test picture used drawtext without a font file -> "Fontconfig error: Cannot load default config file" -> ffmpeg died
#     (25 log lines, 10-12 / 10-15 / 10-18, all in test runs).
#  2. Retention deleted Peter's REAL session videos while a test had the scratch vault on: the in-memory session list kept the real
#     files, a pretend session pushed the count past "keep 3" and the oldest REAL file was deleted (10-15 11:20 and 11:21, 10-18 08:53 and
#     08:54: four real race videos gone).
# Offline: reads source, runs ffmpeg for 4 s on a made-up picture in a temp folder. Touches no vault, no screens, no irdash.
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Section($title) { Assert-RigFree -Where $title; $title }
function Check($name, $ok) { if ($ok) { Write-Host "ok   $name" } else { Write-Host "FAIL $name"; $script:fail++ } }

Section '1. the test picture needs no fontconfig'
Assert-RigFree -Where 'ffmpeg test picture'
$rec = Get-Content (Join-Path $root 'dash\src\recorder.cs') -Raw
Check 'drawtext in recorder.cs names a font file' ($rec -match "drawtext=fontfile='C\\\\\\\\:/Windows/Fonts/arial\.ttf'" -or $rec -match 'drawtext=fontfile=')
Check 'the font file exists on this PC' (Test-Path 'C:\Windows\Fonts\arial.ttf')
$ff = Join-Path $root 'vault\bin\ffmpeg.exe'
$tmp = Join-Path $env:TEMP ('rec-safety-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
if (-not (Test-Path $ff)) { Write-Host "SKIP the ffmpeg run: no $ff here (a git worktree has no vault\bin; the live checkout does)" }
else { try {
  $base = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000
  $fc = "testsrc2=size=1280x720:rate=60,realtime,settb=1/1000000,setpts=RTCTIME-$base,split=2[a][b];[b]crop=640:32:0:0,format=yuv420p,geq=lum='255*mod(floor(floor(T*1000)/pow(2,floor(X/20))),2)':cb=128:cr=128[c];[a][c]overlay=0:0,drawtext=fontfile='C\:/Windows/Fonts/arial.ttf':text='%{pts\:hms}':x=10:y=60:fontsize=48:fontcolor=white:box=1:boxcolor=black@0.7,hflip,vflip"
  $psi = New-Object Diagnostics.ProcessStartInfo $ff
  $psi.Arguments = "-hide_banner -y -loglevel error -t 4 -threads 1 -filter_complex `"$fc`" -c:v libx264 -preset ultrafast -pix_fmt yuv420p -b:v 4M -g 60 -bf 0 -enc_time_base 1/1000000 -fps_mode passthrough -f segment -segment_time 2 -segment_format mpegts `"$tmp\t-%05d.ts`""
  $psi.UseShellExecute = $false; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $p = [Diagnostics.Process]::Start($psi); try { $p.PriorityClass = 'BelowNormal' } catch { }
  $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
  $bytes = (Get-ChildItem $tmp -Filter *.ts | Measure-Object Length -Sum).Sum
  Check 'ffmpeg exits 0 on the exact test-picture filter' ($p.ExitCode -eq 0)
  Check 'no Fontconfig message' ($err -notmatch 'Fontconfig')
  Check 'video was written' ($bytes -gt 100000)
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } }

Section '2. retention never deletes files outside the active vault'
Assert-RigFree -Where 'retention source checks'
Check 'RetainSessions only lists sessions inside the active vault' ($rec -match 'InActiveVault\(s\.File\)\) un\.Add\(s\)')
Check 'disk-pressure clean-up only picks sessions inside the active vault' ($rec -match 'InActiveVault\(s\.File\) && WallMs\(\) - s\.Created > 600000')
$vault = Get-Content (Join-Path $root 'dash\src\vault.cs') -Raw
Check 'the sandbox switch re-reads the recorder sessions' ($vault -match 'Recorder\.VaultRootChanged\(\)')
Check 'the recorder re-read leaves an open session alone' ($rec -match 's\.Open \|\| s\.Saving\) return')

Section '3. a blip does not take a last-3 slot from a real race'
Assert-RigFree -Where 'blip source checks'
Check 'a closed session under 90 s with no lap is removed first and not counted toward the last few' ($rec -match 's\.Duration < 90 && s\.LapRows\.Count == 0 && WallMs\(\) - s\.Created > 600000\) del\.Add\(s\)' -and $rec -match 'int n = real\.Count;')

Section '4. a recorder test leaves the REAL defaults behind (W0-2)'
Assert-RigFree -Where 'TestOff source checks'
$i4 = $rec.IndexOf('static void TestOff()'); $testOff = if ($i4 -ge 0) { $rec.Substring($i4, $rec.IndexOf('public static string TestRoute', $i4) - $i4) } else { '' }
Check 'the real default is one constant: 8 unsaved sessions' ($rec -match 'const int DefaultKeepSessions = 8;' -and $rec -match 'static int keepSessions = DefaultKeepSessions;')
Check 'TestOff puts keepSessions back to 8 (it set 3: retention then deleted down to 3 until a restart)' ($testOff -match 'keepSessions = DefaultKeepSessions;' -and $testOff -notmatch 'keepSessions = 3')
Check 'TestOff reads the clip list back from disk (it was left empty)' ($testOff -match 'LoadClips\(\);')

Section '5. a renamed or moved YouTube copy never deletes the race (W0-2): SyncExports run for real on pretend files'
Assert-RigFree -Where 'SyncExports harness'
# The real SyncExports text from recorder.cs, compiled with a pretend session list and a Delete that only counts.
$a5 = $rec.IndexOf('static string ExportedList'); $b5 = $rec.IndexOf('static RecSess FindDone')
$body = if ($a5 -ge 0 -and $b5 -gt $a5) { $rec.Substring($a5, $b5 - $a5) } else { '' }
Check 'SyncExports found in recorder.cs' ($body -match 'static void SyncExports\(\)')
Check 'it has no delete in it any more' ($body -notmatch 'Delete\(' -and $body -notmatch 'LinkCount')
$h = Join-Path $env:TEMP ('sync-exports-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force $h | Out-Null
try {
  $cs = @"
using System; using System.Collections.Generic; using System.IO;
namespace IRDash {
  static class Log { public static List<string> Lines = new List<string>(); public static void W(string m) { Lines.Add(m); } }
  class RecSess { public string Id = "", File = ""; }
  static class Recorder {
    static readonly object gate = new object();
    static readonly List<RecSess> sessions = new List<RecSess>();
    public static string VaultRoot = "", ExportDir = "";
    static string ExportName(RecSess s) { return "race " + s.Id; }
    public static double Clock; static double WallMs() { return Clock; }
    public static int Deletes; static string Delete(string id) { Deletes++; return "DELETED"; }
$body
    static int Main(string[] a) {
      VaultRoot = Path.Combine(a[0], "vault"); ExportDir = Path.Combine(a[0], "Videos"); Directory.CreateDirectory(VaultRoot); Directory.CreateDirectory(ExportDir);
      RecSess s = new RecSess(); s.Id = "r1"; s.File = Path.Combine(VaultRoot, "r1.mp4"); File.WriteAllText(s.File, "video"); sessions.Add(s);
      string exp = Path.Combine(ExportDir, "race r1.mp4"); File.WriteAllText(exp, "video");
      Clock = 100000; SyncExports();
      bool seen = File.ReadAllText(Path.Combine(VaultRoot, "exported.txt")).Contains("r1");
      File.Move(exp, Path.Combine(ExportDir, "My great race at Road Atlanta.mp4"));       // Peter titles it for YouTube
      Clock += 16000; SyncExports();
      bool marked = exportMissing.Contains("r1");
      Directory.Delete(ExportDir, true);                                                   // OneDrive: the whole folder is gone for a moment
      Clock += 16000; SyncExports();
      bool still = exportMissing.Contains("r1") && File.Exists(s.File);
      Directory.CreateDirectory(ExportDir); File.WriteAllText(exp, "video");               // it is back
      Clock += 16000; SyncExports();
      bool cleared = !exportMissing.Contains("r1");
      Console.WriteLine("seen=" + seen + " marked=" + marked + " still=" + still + " cleared=" + cleared + " deletes=" + Deletes + " file=" + File.Exists(s.File) + " inList=" + sessions.Contains(s) + " logged=" + Log.Lines.Exists(l => l.Contains("export missing")));
      return 0;
    }
  }
}
"@
  Set-Content (Join-Path $h 'sync.cs') $cs -Encoding UTF8
  $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  $o = & $csc /nologo /target:exe "/out:$h\sync.exe" /r:System.dll /r:System.Core.dll (Join-Path $h 'sync.cs') 2>&1
  Check 'the real SyncExports compiles in the harness' (Test-Path "$h\sync.exe")
  if (-not (Test-Path "$h\sync.exe")) { $o | Where-Object { $_ -match 'error' } | Select-Object -First 5 }
  $res = if (Test-Path "$h\sync.exe") { & "$h\sync.exe" $h } else { '' }
  Write-Host "  $res"
  Check 'a race put in Videos\Paddock is remembered (vault\exported.txt)' ($res -match 'seen=True')
  Check 'renamed export: the race stays in the list, marked "export missing"' ($res -match 'marked=True' -and $res -match 'inList=True' -and $res -match 'logged=True')
  Check 'Videos\Paddock briefly gone (OneDrive): still kept, still marked' ($res -match 'still=True')
  Check 'NO delete happened, the video file is still there' ($res -match 'deletes=0' -and $res -match 'file=True')
  Check 'the export back in place clears the mark' ($res -match 'cleared=True')
} finally { Remove-Item $h -Recurse -Force -ErrorAction SilentlyContinue }
Check 'the RACES list carries the mark in words ("export missing") and the top-screen page shows it' ($rec -match 'exportMissing\.Contains\(s\.Id\) \? ",\\"exportMissing\\":true,\\"note\\":\\"export missing\\""' -and ([IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\races.js')) -match 'if \(r\.exportMissing\) facts\.push\(''<b>no longer in Videos'))

if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'all ok' }
