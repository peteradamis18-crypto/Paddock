# deckstate-line-test.ps1 - the `irdeck state` line every safety rule reads (W0-1, src\deckstate.cs RigState).
# OFFLINE: deckstate.cs is compiled on its own and fed made-up facts; the lines it makes are read with the very patterns the scripts
# use today (build-irdeck.ps1, deck-intro\install.ps1, tests, tools). Then the freshly built irdeck-cli prints the real line once.
#   1. telemetry=on is never printed without the sim process (a map left by a crashed sim is not a session)
#   2. the old fields keep their names and order; fresh= replay= event= are added at the end
#   3. event= : Test / AI / Race / Practice / Qualify / none
#   4. every consumer's pattern reads the new line the same way as the old one
#   powershell -ExecutionPolicy Bypass -File tests\deckstate-line-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Section($s) { Assert-RigFree -Where $s; $s }
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$tmp = Join-Path $env:TEMP ('deckstate-line-test-' + $PID); New-Item -ItemType Directory -Force $tmp | Out-Null

Section '1-3. the rules (deckstate.cs compiled on its own)'
$unit = @'
using System;
using IRDeck;
static class T {
  static RigState.Facts F(bool sim, bool map, bool onTrack, string ev, bool ai, string type) {
    RigState.Facts f = new RigState.Facts(); f.Sim = sim; f.Ui = true; f.MapConnected = map; f.OnTrack = onTrack; f.Fresh = true; f.Replay = false;
    f.EventType = ev; f.Ai = ai; f.SessionType = type; f.FuelLevel = 41.25; f.PitSvFuel = 10; f.Foreground = "iRacingSim64DX11"; return f;
  }
  static void Main(string[] a) {
    // name|line, one per case; the PowerShell side checks them
    Console.WriteLine("idle|" + RigState.Line(F(false, false, false, "", false, "")));
    Console.WriteLine("crashmap|" + RigState.Line(F(false, true, true, "Race", false, "Race")));
    Console.WriteLine("test|" + RigState.Line(F(true, true, true, "Test", false, "Offline Testing")));
    Console.WriteLine("ai|" + RigState.Line(F(true, true, false, "Race", true, "Practice")));
    Console.WriteLine("race|" + RigState.Line(F(true, true, true, "Race", false, "Race")));
    Console.WriteLine("prac|" + RigState.Line(F(true, true, false, "Race", false, "Practice")));
    Console.WriteLine("qual|" + RigState.Line(F(true, true, false, "Race", false, "Open Qualify")));
    Console.WriteLine("lobby|" + RigState.Line(F(true, true, false, "", false, "")));
    RigState.Facts st = F(true, true, true, "Race", false, "Race"); st.Fresh = false; st.Replay = true;
    Console.WriteLine("stale|" + RigState.Line(st));
    Console.WriteLine("ton|" + RigState.TelemetryOn(true, true) + "," + RigState.TelemetryOn(false, true) + "," + RigState.TelemetryOn(true, false));
    Console.WriteLine("tick|" + RigState.TelemetryAdvanced(10, 11) + "," + RigState.TelemetryAdvanced(10, 10) + "," + RigState.TelemetryAdvanced(-1, 5) + "," + RigState.TelemetryAdvanced(int.MaxValue, int.MinValue));
  }
}
'@
$unitPath = Join-Path $tmp 'unit.cs'; Set-Content -LiteralPath $unitPath -Value $unit -Encoding ASCII
$exe = Join-Path $tmp 'unit.exe'
& $csc -nologo -target:exe "-out:$exe" (Join-Path $root 'src\deckstate.cs') $unitPath | Out-Null
Check 'src\deckstate.cs compiles on its own (C# 5)' ($LASTEXITCODE -eq 0)
$L = @{}; if (Test-Path $exe) { foreach ($ln in & $exe) { $p = $ln.Split('|', 2); $L[$p[0]] = $p[1] } }

Check 'nothing running: the old three fields, then fresh=False replay=False event=none' ($L.idle -eq 'state: sim=False ui=True telemetry=off fresh=False replay=False event=none') $L.idle
Check 'a map left behind by a crashed sim (no sim process): telemetry=off, never onTrack=True, says map=left-over' ($L.crashmap -match 'telemetry=off' -and $L.crashmap -notmatch 'telemetry=on|onTrack=True' -and $L.crashmap -match 'map=left-over' -and $L.crashmap -match 'event=none') $L.crashmap
Check 'TelemetryOn needs both the sim process and the map' ($L.ton -eq 'True,False,False') $L.ton
Check 'a session: the old fields in the old order, then the new ones' ($L.race -match '^state: sim=True ui=True telemetry=on onTrack=True onPitRoad=False units=imperial fuelLevel=41\.3L pitSvFuel=10\.0L pitSvFlags=0 foreground=iRacingSim64DX11 fresh=True replay=False event=Race$') $L.race
Check 'event=Test for a Test Drive, AI for an AI race (whatever the session), Race / Practice / Qualify by session' ($L.test -match 'event=Test$' -and $L.ai -match 'event=AI$' -and $L.race -match 'event=Race$' -and $L.prac -match 'event=Practice$' -and $L.qual -match 'event=Qualify$')
Check 'a session with no session type yet says event=none' ($L.lobby -match 'event=none$') $L.lobby
Check 'a frozen tick says fresh=False; a replay says replay=True' ($L.stale -match 'fresh=False replay=True') $L.stale
Check 'the tick rule: forward is fresh, the same is not, -1 is not, the wrap from max to min is forward' ($L.tick -eq 'True,False,False,True') $L.tick

Section '4. the patterns the scripts use read the new line as before'
$cases = @(
  @{ who = 'build-irdeck.ps1 / install.ps1 / data-test / mydrive-test'; re = 'telemetry=on' },
  @{ who = 'deck-speed-test / mydrive live'; re = 'onTrack=True' },
  @{ who = 'perf-test'; re = 'telemetry=on|onTrack=True' },
  @{ who = 'df8-apply / or-run / build-queue / tv-sampler'; re = 'sim=True|telemetry=on' },
  @{ who = 'mydrive-test after QUIT'; re = 'telemetry=off' }
)
$old = @{ idle = 'state: sim=False ui=True telemetry=off'; race = 'state: sim=True ui=True telemetry=on onTrack=True onPitRoad=False units=imperial fuelLevel=41.3L pitSvFuel=10.0L pitSvFlags=0 foreground=iRacingSim64DX11'
          prac = 'state: sim=True ui=True telemetry=on onTrack=False onPitRoad=False units=imperial fuelLevel=41.3L pitSvFuel=10.0L pitSvFlags=0 foreground=iRacingSim64DX11' }
foreach ($c in $cases) {
  $same = $true; foreach ($k in $old.Keys) { if (($old[$k] -match $c.re) -ne ($L[$k] -match $c.re)) { $same = $false } }
  Check "'$($c.re)' ($($c.who)) gives the same answer on the old and the new line" $same
}
Check "the crash-left map no longer looks like a session to 'telemetry=on' (it did before: the old line came from the map alone)" (-not ($L.crashmap -match 'telemetry=on'))
foreach ($f in 'build-irdeck.ps1', 'deck-intro\install.ps1', 'tests\deck-speed-test.ps1') {
  $t = [IO.File]::ReadAllText((Join-Path $root $f))
  $ms = @([regex]::Matches($t, "state\)?\s*-match\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
  Check "$f still reads the line with patterns this test covers ($($ms -join ', '))" ($ms.Count -gt 0 -and @($ms | Where-Object { $p = $_; -not ($cases | Where-Object { $_.re -eq $p }) }).Count -eq 0)
}
$inst = [IO.File]::ReadAllText((Join-Path $root 'deck-intro\install.ps1'))
Check 'install.ps1 also refuses on the shared busy rule (Get-RigBusy from tests\guard.ps1), not only telemetry=on' ($inst -match "\. \(Join-Path \(Split-Path -Parent \`$here\) 'tests\\guard\.ps1'\)" -and $inst -match '\$busy = Get-RigBusy' -and $inst -match 'if \(\$busy\)')

Section '5. the real irdeck-cli prints the new line'
$null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build-irdeck.ps1') -NoDeploy 2>&1
$cli = Join-Path $env:TEMP 'ird\irdeck-cli.exe'
$own = Join-Path $tmp 'irdeck-cli.exe'; Copy-Item $cli $own   # its own copy: other builders compile into %TEMP%\ird too
$line = (& $own state | Select-Object -Last 1)
Check "irdeck-cli state: one line with fresh= replay= event= ($line)" ($line -match '^state: sim=(True|False) ui=(True|False) telemetry=(on|off).* fresh=(True|False) replay=(True|False) event=(Test|AI|Race|Practice|Qualify|none)$')
$simUp = [bool](Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue)
Check 'telemetry=on only if the sim process exists right now' (-not ($line -match 'telemetry=on') -or $simUp)

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
