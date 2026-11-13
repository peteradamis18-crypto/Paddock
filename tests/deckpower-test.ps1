# deckpower-test.ps1 - SHUT DOWN / SLEEP can only happen through the CONFIRM screen, end to end (W0-1 review, findings 1, 2, 6, 8).
# Runs the REAL rules and the REAL irdeck, never the real power step: every irdeck run here has PADDOCK_POWER_DRYRUN=1, so CmdPower
# logs "dry run - would ..." instead of quitting iRacing, stopping Stream Deck or turning anything off.
# A pretend irdash (C#, compiled with src\deckguard.cs: the same DoMemory + PowerGate the real /api/do uses) listens on port 9397
# (never 8199) and starts the freshly built irdeck-cli in an isolated folder, exactly as irdash's StartIrdeck does
# ("power off --confirmed"). Nothing touches the real irdash, Stream Deck, the real kids lock or the real keys folder.
#   1. the arm window: no arm -> refused; arm without the header -> refused; YES without the header -> refused;
#      arm then YES within 5 s -> ok once (irdeck: power off dry run); the same YES again -> refused (arm used up);
#      arm, wait 6 s, YES -> refused; the old c=key&a=shutdown -> refused
#   2. kids lock: the pretend irdash answers "kids"; irdeck-cli power off --confirmed itself refuses (rc 3)
#   3. irdeck: plain `power off` (no --confirmed) refuses; a key copy (keys\shutdown.exe whose keys.map line says power off --confirmed)
#      refuses too - so a stale key exe or keys.map can never end the PC in one press
#   powershell -ExecutionPolicy Bypass -File tests\deckpower-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Section($s) { Assert-RigFree -Where $s; $s }
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
$env:PADDOCK_POWER_DRYRUN = '1'      # every irdeck started from here (and its children) only says what it would do
$env:PADDOCK_KEYMSG_OFF = '1'        # and never puts words on the real top screen
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$tmp = Join-Path $env:TEMP ('deckpower-test-' + $PID); $iso = Join-Path $tmp 'rig'
New-Item -ItemType Directory -Force (Join-Path $iso 'keys'), (Join-Path $iso 'dash') | Out-Null

Section '0. build'
$null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build-irdeck.ps1') -NoDeploy 2>&1
Check 'irdeck builds' ($LASTEXITCODE -eq 0)
Copy-Item (Join-Path $env:TEMP 'ird\irdeck-cli.exe') (Join-Path $iso 'irdeck-cli.exe')
Copy-Item (Join-Path $env:TEMP 'ird\irdeck.exe') (Join-Path $iso 'keys\shutdown.exe')
$pretend = @'
using System; using System.Diagnostics; using System.IO; using System.Net; using System.Text; using IRDeck;
static class P {
  static void Main(string[] a) {
    string cli = a[0]; int port = int.Parse(a[1]);
    if (Environment.GetEnvironmentVariable("PADDOCK_POWER_DRYRUN") != "1") { Console.WriteLine("refusing: not a dry run"); return; }
    DeckGuard.DoMemory mem = new DeckGuard.DoMemory(); DeckGuard.PowerGate gate = new DeckGuard.PowerGate();
    HttpListener l = new HttpListener(); l.Prefixes.Add("http://localhost:" + port + "/"); l.Start();
    while (true) {
      HttpListenerContext ctx = l.GetContext();
      string c = ctx.Request.QueryString["c"] ?? "", ar = ctx.Request.QueryString["a"] ?? "", body;
      bool xp = ctx.Request.Headers["X-Paddock"] == "1";
      bool kids = File.Exists(Path.Combine(Path.GetDirectoryName(cli), @"dash\kids.lock"));
      long now = DateTime.UtcNow.Ticks;
      if (c == "quit") { Reply(ctx, "bye"); return; }
      // the same order as dash\src\irdash.cs /api/do
      if (!mem.Allow(c, ar, now)) body = "ok (repeat ignored)";
      else if (c == "key" && (ar == "shutdown" || ar == "sleep")) body = "no";
      else if (c == "confirmarm") body = xp && gate.Arm(ar, now) ? "ok" : "no";
      else if (DeckGuard.IsPowerCommand(c)) {
        string why = gate.Check(c, xp, true, kids, now);
        if (why != "ok") body = why == "kids" ? "kids" : "no:" + why;
        else {
          ProcessStartInfo psi = new ProcessStartInfo(cli, c == "shutdown" ? "power off --confirmed" : "power sleep --confirmed");
          psi.UseShellExecute = false; psi.RedirectStandardOutput = true; psi.CreateNoWindow = true;
          psi.EnvironmentVariables["PADDOCK_POWER_DRYRUN"] = "1"; psi.EnvironmentVariables["PADDOCK_KEYMSG_OFF"] = "1";
          using (Process p = Process.Start(psi)) { string o = p.StandardOutput.ReadToEnd(); p.WaitForExit(20000); body = "ok|" + p.ExitCode + "|" + o.Replace("\r", "").Replace("\n", " ").Trim(); }
        }
      }
      else body = "unknown";
      Reply(ctx, body);
    }
  }
  static void Reply(HttpListenerContext ctx, string s) { byte[] b = Encoding.UTF8.GetBytes(s); ctx.Response.ContentType = "text/plain; charset=utf-8"; ctx.Response.OutputStream.Write(b, 0, b.Length); ctx.Response.Close(); }
}
'@
$pp = Join-Path $tmp 'pretend.cs'; Set-Content -LiteralPath $pp -Value $pretend -Encoding ASCII
$pexe = Join-Path $tmp 'pretend-irdash.exe'
& $csc -nologo -target:exe "-out:$pexe" (Join-Path $root 'src\deckguard.cs') $pp | Out-Null
Check 'the pretend irdash compiles with the real src\deckguard.cs' ($LASTEXITCODE -eq 0)
$port = 9397
$proc = Start-Process $pexe -ArgumentList "`"$(Join-Path $iso 'irdeck-cli.exe')`"", $port -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 1200
function Do_($c, $a, [switch]$H) {
  $u = "http://localhost:$port/api/do?c=$c" + $(if ($a) { "&a=$a" } else { '' })
  $hd = @{}; if ($H) { $hd['X-Paddock'] = '1' }
  try { (Invoke-WebRequest -UseBasicParsing $u -Headers $hd -TimeoutSec 30).Content } catch { "error: $($_.Exception.Message)" }
}
try {
  Section '1. the arm window'
  $r = Do_ shutdown -H; Check "YES with no arm is refused ($r)" ($r -eq 'no:not-armed')
  Start-Sleep -Milliseconds 800
  $r = Do_ confirmarm shutdown; Check "an arm without X-Paddock is refused ($r)" ($r -eq 'no')
  $r = Do_ shutdown -H; Check "... so YES is still refused ($r)" ($r -eq 'no:not-armed')
  Start-Sleep -Milliseconds 800
  $r = Do_ confirmarm shutdown -H; Check "the CONFIRM screen's arm (with X-Paddock) is taken ($r)" ($r -eq 'ok')
  $r = Do_ shutdown; Check "YES without X-Paddock is refused, even when armed (an <img> or a link cannot end the PC) ($r)" ($r -eq 'no:no-header')
  Start-Sleep -Milliseconds 800
  $r = Do_ shutdown -H; Check "arm, then YES within 5 s: ok, and irdeck ran power off --confirmed (dry run) ($r)" ($r -match '^ok\|0\|.*power off: dry run - would quit iRacing, send the deck to MAIN and turn the PC off')
  Start-Sleep -Milliseconds 800
  $r = Do_ shutdown -H; Check "the same YES again: refused, the arm was used up ($r)" ($r -eq 'no:not-armed')
  Start-Sleep -Milliseconds 800
  $r = Do_ confirmarm sleep -H; $r2 = Do_ shutdown -H; Check "an arm for SLEEP does not let SHUT DOWN through ($r2)" ($r -eq 'ok' -and $r2 -eq 'no:not-armed')
  Start-Sleep -Milliseconds 800
  $r = Do_ sleep -H; Check "... but SLEEP itself goes (dry run) ($r)" ($r -match '^ok\|0\|.*power sleep: dry run')
  Start-Sleep -Milliseconds 800
  $r = Do_ confirmarm shutdown -H; Start-Sleep -Seconds 6; $r2 = Do_ shutdown -H
  Check "arm, wait 6 s, YES: refused ($r2)" ($r -eq 'ok' -and $r2 -eq 'no:not-armed')
  $r = Do_ key shutdown -H; $r2 = Do_ key sleep -H; Check "the old one-press path c=key&a=shutdown / sleep is refused ($r, $r2)" ($r -eq 'no' -and $r2 -eq 'no')

  Section '2. kids lock'
  # the same lock file irdeck writes (src\kids.cs): this boot's id and an end time
  $bootSrc = @'
using System; using System.Runtime.InteropServices;
public static class KB {
  [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, byte[] info, int len, out int ret);
  [DllImport("kernel32.dll")] static extern void GetSystemTimeAsFileTime(out long t);
  [DllImport("kernel32.dll")] static extern ulong GetTickCount64();
  public static long Id() { byte[] buf = new byte[64]; int ret; int st = NtQuerySystemInformation(3, buf, 48, out ret); if (st != 0) st = NtQuerySystemInformation(3, buf, 64, out ret);
    if (st == 0) { long b = BitConverter.ToInt64(buf, 0); if (b != 0) return b; } long now; GetSystemTimeAsFileTime(out now); long raw = now - (long)GetTickCount64() * 10000L; return raw == 0 ? 0 : raw / 600000000L; }
}
'@
  Add-Type $bootSrc -ErrorAction SilentlyContinue
  $lock = Join-Path $iso 'dash\kids.lock'
  [IO.File]::WriteAllText($lock, "boot=$([KB]::Id())`r`nuntil=$([DateTime]::UtcNow.AddMinutes(5).Ticks)`r`n")
  Start-Sleep -Milliseconds 800
  $r = Do_ confirmarm shutdown -H; $r2 = Do_ shutdown -H
  Check "kids lock on: irdash answers kids (the CONFIRM screen then says KIDS MODE IS ON) ($r2)" ($r -eq 'ok' -and $r2 -eq 'kids')
  $o = (& (Join-Path $iso 'irdeck-cli.exe') power off --confirmed 2>&1 | Out-String).Trim(); $rc = $LASTEXITCODE
  Check "irdeck-cli power off --confirmed with the kids lock: refused, rc 3 ($o)" ($rc -eq 3 -and $o -match 'power off: kids mode is on - nothing was done')
  Remove-Item $lock -Force

  Section '3. irdeck refuses everything but the confirmed path'
  $o = (& (Join-Path $iso 'irdeck-cli.exe') power off 2>&1 | Out-String).Trim(); $rc = $LASTEXITCODE
  Check "plain power off (no --confirmed): refused, rc 3 ($o)" ($rc -eq 3 -and $o -match 'refused - only the CONFIRM screen')
  $o = (& (Join-Path $iso 'irdeck-cli.exe') power sleep 2>&1 | Out-String).Trim(); $rc = $LASTEXITCODE
  Check "plain power sleep: refused, rc 3" ($rc -eq 3 -and $o -match 'refused - only the CONFIRM screen')
  [IO.File]::WriteAllText((Join-Path $iso 'keys\keys.map'), "shutdown=power off --confirmed`r`n", (New-Object Text.UTF8Encoding $false))
  Remove-Item (Join-Path $env:TEMP 'irdeck-shutdown.last') -Force -ErrorAction SilentlyContinue
  $log = Join-Path $iso 'irdeck.log'; Remove-Item $log -Force -ErrorAction SilentlyContinue
  $p = Start-Process (Join-Path $iso 'keys\shutdown.exe') -PassThru -WindowStyle Hidden; $p.WaitForExit(20000) | Out-Null
  $t = if (Test-Path $log) { [IO.File]::ReadAllText($log) } else { '' }
  Check 'a key copy (keys\shutdown.exe, even with --confirmed in keys.map) refuses: an old key exe can never end the PC' ($t -match 'power off: refused - only the CONFIRM screen' -and $t -notmatch 'dry run') $t
  Remove-Item (Join-Path $env:TEMP 'irdeck-shutdown.last') -Force -ErrorAction SilentlyContinue
}
finally {
  try { $null = Invoke-WebRequest -UseBasicParsing "http://localhost:$port/api/do?c=quit" -TimeoutSec 3 } catch { }
  try { $proc | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
}

Section '4. the real irdash uses the same rules'
$dash = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
Check 'irdash /api/do: key shutdown|sleep refused, confirmarm needs X-Paddock from this PC, shutdown/sleep go through PowerGate.Check and start irdeck with --confirmed' ($dash -match 'dc == "key" && \(da == "shutdown" \|\| da == "sleep"\)' -and $dash -match 'dc == "confirmarm"\) \{ bool ak = local && xpOk && PowerGate\.Arm' -and $dash -match 'PowerGate\.Check\(dc, xpOk, local, KidsLockOn\(\)' -and $dash -match '"power off --confirmed" : "power sleep --confirmed"')
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
