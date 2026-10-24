# deckwatch-test.ps1 - the Stream Deck stays alive after a wake / USB blip (dash\src\deckwatch.cs + Watch in dash\src\irdash.cs).
# 2026-10-24 18:32: the PC woke, Windows reset the deck's USB, the Stream Deck app kept the dead connection for 36 s and the old
# watchdog waited 25 s more: 67 s of a dead deck. OFFLINE: deckwatch.cs is compiled on its own and fed the real log lines of that
# evening; nothing touches the Stream Deck app.
#   1. a real sleep is a wake; irdash freezing (both clocks run) never is
#   2. today's sequence: "connected" right after the wake is no reason; "disconnected" restarts at once (one tick later)
#   3. no restart while the deck is unplugged, within the cooldown, or for an app that is still starting
#   4. wiring: the watchdog uses Windows' awake clock, restarts on its own thread, reads the whole log, respects deck-build.lock
#   powershell -ExecutionPolicy Bypass -File tests\deckwatch-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Section($s) { Assert-RigFree -Where $s; $s }
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }

Section '1-3. the rules (deckwatch.cs compiled on its own)'
$unit = @'
using System;
namespace IRDash {
  static class T {
    static int bad;
    static void C(string what, bool ok) { Console.WriteLine((ok ? "ok " : "FAIL ") + what); if (!ok) bad++; }
    static void Main() {
      const string WOKE = "18:32:34 ESDAppController::onDeviceStatusChanged Device connected, id: @(1)[4057/143/A00NA52730IYXG]\n18:32:37 DeviceDockManager rescan dock services\n";
      const string DEAD = WOKE + "18:33:10 DeviceComm err Read Keys Returns: DISCONNECTED\n18:33:10 ESDAppController::onDeviceStatusChanged Device disconnected, id: @(1)[4057/143/A00NA52730IYXG]\n";
      const string BACK = DEAD + "18:33:41 ESDAppController::onDeviceStatusChanged Device connected, id: @(1)[4057/143/A00NA52730IYXG]\n";
      const string STARTING = "18:33:38 DeviceManager bootstrapping\n18:33:39 DeviceHIDNotifier resuming\n";
      C("a night asleep (wall 29880 s, awake 4 s) is a wake", DeckWatch.IsWake(29880, 4));
      C("a 20 s sleep is a wake", DeckWatch.IsWake(22, 2));
      C("irdash frozen for 40 s (both clocks ran) is NOT a wake - never restart the deck mid-race for that", !DeckWatch.IsWake(40, 40));
      C("a normal 2 s tick is not a wake", !DeckWatch.IsWake(2, 2));
      C("right after the wake the app says connected: no restart from the log (the wake restart handles it)", DeckWatch.Action(WOKE, true, 600, true, 0, 9999) == "");
      C("'Device disconnected' seen on two ticks (2 s): restart at once ('lost')", DeckWatch.Action(DEAD, true, 600, true, 2, 9999) == "lost");
      C("'Device disconnected' on the first tick: wait one more tick", DeckWatch.Action(DEAD, true, 600, true, 0, 9999) == "");
      C("deck unplugged (not on USB): no restart - it cannot help", DeckWatch.Action(DEAD, true, 600, false, 30, 9999) == "");
      C("within 30 s of the last restart: no second restart", DeckWatch.Action(DEAD, true, 600, true, 30, 10) == "");
      C("connected again after the restart: nothing to do", DeckWatch.Action(BACK, true, 600, true, 0, 9999) == "" && DeckWatch.Connected(BACK));
      C("an app still starting (10 s, no device line yet): wait", DeckWatch.Action(STARTING, true, 10, true, 0, 9999) == "");
      C("an app running 30 s that never found the deck: restart ('never')", DeckWatch.Action(STARTING, true, 30, true, 0, 9999) == "never");
      C("app not running: the 'not running' rule starts it, not this one", DeckWatch.Action(DEAD, false, 0, true, 30, 9999) == "");
      C("Connected(): false while the last word is 'disconnected'", !DeckWatch.Connected(DEAD) && DeckWatch.Connected(WOKE) && !DeckWatch.Connected(null));
      Console.WriteLine("UNIT-DONE " + bad);
    }
  }
}
'@
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP ('deckwatch-' + $PID); New-Item -ItemType Directory -Force $tmp | Out-Null
[IO.File]::WriteAllText("$tmp\unit.cs", $unit)
& $csc /nologo /target:exe "/out:$tmp\unit.exe" (Join-Path $root 'dash\src\deckwatch.cs') "$tmp\unit.cs" | Out-Null
if (-not (Test-Path "$tmp\unit.exe")) { Check 'deckwatch.cs and the unit compile (C# 5)' $false }
else {
  $u = & "$tmp\unit.exe"
  foreach ($l in $u) { if ($l -match '^ok (.+)') { Check $Matches[1] $true } elseif ($l -match '^FAIL (.+)') { Check $Matches[1] $false } }
  Check 'unit run finished' (@($u | Where-Object { $_ -like 'UNIT-DONE*' }).Count -eq 1)
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Section '4. wiring in the watchdog'
$ir = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs')); $bp = [IO.File]::ReadAllText((Join-Path $root 'dash\build.ps1'))
$i = $ir.IndexOf('static void CheckDeckDevice('); $body = if ($i -ge 0) { $ir.Substring($i, 1800) } else { '' }
Check 'dash\build.ps1 compiles deckwatch.cs' ($bp -match 'deckwatch\.cs')
Check 'a wake is told apart from a freeze with QueryUnbiasedInterruptTime (stops while asleep)' ($ir -match 'QueryUnbiasedInterruptTime\(out ulong' -and $body -match 'DeckWatch\.IsWake\(gap, awake\)')
Check 'the check runs on every 2 s tick (no 10 s throttle, no 15 s grace)' ($body -notmatch 'TotalSeconds < 10' -and $body -notmatch '< 15')
Check 'restarts run on their own thread, one at a time (the 2 s timer never blocks)' ($ir -match 'Interlocked\.CompareExchange\(ref deckWork, 1, 0\)' -and $ir -match 't\.Name = "DeckRestart"')
Check 'a wake waits for the deck to be back on USB before restarting the app' ($ir -match 'for \(int i = 0; i < 40 && !DeckPresent\(\); i\+\+\)')
Check 'after a restart it checks the deck really came back, and says so (or to replug it)' ($ir -match 'deck back after' -and $ir -match 'unplug and replug')
Check 'never during a deck rebuild (deck-build.lock)' ($body -match 'DeckBuilding\(\)' -and $ir -match 'if \(DeckBuilding\(\)\) return;')
Check 'the whole current Stream Deck log is read (a tail could lose the connected line on a long day)' ($ir -match 'fs\.Length - 4000000')
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
