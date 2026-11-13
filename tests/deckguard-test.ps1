# deckguard-test.ps1 - the repeat guard for every deck press (W0-1, src\deckguard.cs).
# The Stream Deck delivers one press 2-3 times (29 ms to 1.06 s apart). OFFLINE: deckguard.cs is compiled on its own and its rules
# are run with made-up times; then the real key exe path is checked by starting a key copy of the freshly built irdeck twice,
# in a temp folder with its own keys.map (a command that touches nothing: `state`), and reading what it logged.
#   1. key exes: 0.3 s apart = one run, 0.8 s apart = two; vol-up 0.3 s apart = two; the `key` verb 0.3 s apart = one; toggles 1.5 s
#   2. irdash /api/do: one guard by command + argument; steps and screen housekeeping are free
#   3. the real key exe: two starts 0.3 s apart log one run and one "repeat press ignored"
#   powershell -ExecutionPolicy Bypass -File tests\deckguard-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Section($s) { Assert-RigFree -Where $s; $s }
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$tmp = Join-Path $env:TEMP ('deckguard-test-' + $PID); New-Item -ItemType Directory -Force $tmp | Out-Null

Section '1-2. the rules (deckguard.cs compiled on its own)'
$unit = @'
using System;
using IRDeck;
static class T {
  static int bad;
  static void C(string what, bool ok) { Console.WriteLine((ok ? "ok " : "FAIL ") + what); if (!ok) bad++; }
  static long Ms(double ms) { return TimeSpan.FromMilliseconds(ms).Ticks; }
  static string[] A(string s) { return s.Split(' '); }
  // two starts of key `name` (command `cmd`) gapMs apart; the second finds the mutex free (the first run has ended)
  static int Runs(string name, string cmd, double gapMs) {
    long t0 = 638000000000000000L; int n = 0; long last = 0;
    foreach (long t in new long[] { t0, t0 + Ms(gapMs) }) { if (DeckGuard.KeyRuns(name, A(cmd), last, t, true)) { n++; last = t; } }
    return n;
  }
  static void Main() {
    C("two starts of the same key 0.3 s apart give one run", Runs("get-out", "getout", 300) == 1);
    C("... 0.8 s apart give two runs", Runs("get-out", "getout", 800) == 2);
    C("... exactly 0.7 s apart give two runs (the floor is 0.7 s)", Runs("get-out", "getout", 700) == 2);
    C("vol-up 0.3 s apart gives two runs (tapped quickly on purpose)", Runs("vol-up", "appvol game +5", 300) == 2);
    C("vol-down, spotter level and seat keys are fast keys too", Runs("vol-down", "appvol game -5", 300) == 2 && Runs("spot-up", "appvol spotter +5", 300) == 2 && Runs("spot-down", "appvol spotter -5", 300) == 2 && Runs("seat-up", "key --sim ctrl+]", 300) == 2 && Runs("seat-down", "key --sim ctrl+[", 300) == 2);
    C("... but a 50 ms bounce of vol-up is still one run", Runs("vol-up", "appvol game +5", 50) == 1);
    C("the `key` verb 0.3 s apart gives one run (GHOST no longer opens and closes)", Runs("ghost", "key --sim ctrl+c", 300) == 1);
    C("the `media` verb 0.3 s apart gives one run (MUTE no longer flips back)", Runs("mute", "media mute", 300) == 1);
    C("a sim box (RELATIVE, F3) 0.3 s apart gives one run", Runs("bb-f3", "key --sim f3", 300) == 1);
    C("on/off keys: MUTE SPOTTER 1.0 s apart is one run, 1.6 s apart two", Runs("mute-spotter", "appvol mute spotter", 1000) == 1 && Runs("mute-spotter", "appvol mute spotter", 1600) == 2);
    C("pit toggles and AC on/off keep 1.5 s", DeckGuard.GapMs("pit-tires", A("pittoggle tires")) == 1500 && DeckGuard.GapMs("ac", A("ac toggle")) == 1500);
    C("only names make a key fast: a key called something else running appvol game +5 is 0.7 s", DeckGuard.GapMs("other", A("appvol game +5")) == 700);
    C("a key still running (mutex taken) never runs twice", !DeckGuard.KeyRuns("get-out", A("getout"), 0, 638000000000000000L, false));
    C("fast keys do not wait for the mutex", DeckGuard.KeyRuns("vol-up", A("appvol game +5"), 0, 638000000000000000L, false) && !DeckGuard.UsesMutex("vol-up") && DeckGuard.UsesMutex("ghost"));
    C("a stamp from the future (clock went back) does not block", DeckGuard.KeyRuns("get-out", A("getout"), 638000000000000000L + Ms(5000), 638000000000000000L, true));
    C("the limits are 0.7 s, 1.5 s and 0.12 s", DeckGuard.RepeatMs == 700 && DeckGuard.ToggleMs == 1500 && DeckGuard.BounceMs == 120);

    DeckGuard.DoMemory m = new DeckGuard.DoMemory(); long t0 = 638000000000000000L;
    C("/api/do: the first shutdown runs", m.Allow("shutdown", null, t0));
    C("/api/do: shutdown again 0.3 s later is the same press", !m.Allow("shutdown", null, t0 + Ms(300)));
    C("/api/do: shutdown 0.8 s after the first runs", m.Allow("shutdown", null, t0 + Ms(800)));
    C("/api/do: same command, other argument = another press (racewatch r1, racewatch r2 0.1 s apart)", m.Allow("racewatch", "r1", t0) && m.Allow("racewatch", "r2", t0 + Ms(100)));
    C("/api/do: same command and argument 0.1 s apart = one", !m.Allow("racewatch", "r1", t0 + Ms(100)));
    C("/api/do: the command name is not case-sensitive", m.Allow("ovpreset", "race", t0) && !m.Allow("OVPRESET", "race", t0 + Ms(200)));
    C("/api/do: steps are free (deltaup, sndvol, actemp, rprew, wb-zoom-in twice 0.1 s apart)", m.Allow("deltaup", null, t0) && m.Allow("deltaup", null, t0 + Ms(100)) && m.Allow("sndvol", "game:+5", t0) && m.Allow("sndvol", "game:+5", t0 + Ms(100)) && m.Allow("actemp", "-1", t0) && m.Allow("actemp", "-1", t0 + Ms(100)) && m.Allow("rprew", null, t0) && m.Allow("rprew", null, t0 + Ms(100)) && m.Allow("wb-zoom-in", null, t0) && m.Allow("wb-zoom-in", null, t0 + Ms(100)));
    C("/api/do: screen housekeeping is free (mdopen, mddraft)", m.Allow("mdopen", null, t0) && m.Allow("mdopen", null, t0 + Ms(50)) && m.Allow("mddraft", "car:a", t0) && m.Allow("mddraft", "car:a", t0 + Ms(50)));
    C("/api/do: the phone's deck keys follow the key rule (key vol-up free, key get-out guarded)", m.Allow("key", "vol-up", t0) && m.Allow("key", "vol-up", t0 + Ms(100)) && m.Allow("key", "get-out", t0) && !m.Allow("key", "get-out", t0 + Ms(100)));
    C("/api/do: a START that runs irdeck (mdstart) pressed twice 0.4 s apart is one", m.Allow("mdstart", null, t0) && !m.Allow("mdstart", null, t0 + Ms(400)));
    Environment.Exit(bad);
  }
}
'@
$unitPath = Join-Path $tmp 'unit.cs'; Set-Content -LiteralPath $unitPath -Value $unit -Encoding ASCII
$exe = Join-Path $tmp 'unit.exe'
& $csc -nologo -target:exe "-out:$exe" (Join-Path $root 'src\deckguard.cs') $unitPath | Out-Null
Check 'src\deckguard.cs compiles on its own (C# 5, no irdeck or irdash around it)' ($LASTEXITCODE -eq 0)
if (Test-Path $exe) { foreach ($l in & $exe) { if ($l -match '^ok (.*)$') { Check $Matches[1] $true } elseif ($l -match '^FAIL (.*)$') { Check $Matches[1] $false } } }

Section '3. the real key exe (a copy of the new irdeck.exe, its own keys.map, command `state`)'
$build = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build-irdeck.ps1') -NoDeploy 2>&1
$built = Join-Path $env:TEMP 'ird\irdeck.exe'
Check 'irdeck builds (build-irdeck.ps1 -NoDeploy)' ($LASTEXITCODE -eq 0 -and (Test-Path $built)) ($build -join ' ')
$env:PADDOCK_KEYMSG_OFF = "1"   # the key copies must not put words on the real top screen
if (Test-Path $built) {
  $iso = Join-Path $tmp 'rig'; $keys = Join-Path $iso 'keys'; New-Item -ItemType Directory -Force $keys | Out-Null
  # the key copies log to <folder above keys>\irdeck.log; `state` only reads processes and the SDK map
  [IO.File]::WriteAllText((Join-Path $keys 'keys.map'), "guardprobe=state`r`nvol-up=state`r`n", (New-Object Text.UTF8Encoding $false))
  Copy-Item $built (Join-Path $keys 'guardprobe.exe'); Copy-Item $built (Join-Path $keys 'vol-up.exe')
  Remove-Item (Join-Path $env:TEMP 'irdeck-guardprobe.last'), (Join-Path $env:TEMP 'irdeck-vol-up.last') -Force -ErrorAction SilentlyContinue
  function Twice($name, $gapMs) {
    $log = Join-Path $iso 'irdeck.log'; Remove-Item $log -Force -ErrorAction SilentlyContinue
    $p1 = Start-Process (Join-Path $keys "$name.exe") -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds $gapMs
    $p2 = Start-Process (Join-Path $keys "$name.exe") -PassThru -WindowStyle Hidden
    $p1.WaitForExit(15000) | Out-Null; $p2.WaitForExit(15000) | Out-Null
    $t = if (Test-Path $log) { [IO.File]::ReadAllText($log) } else { '' }
    [pscustomobject]@{ runs = ([regex]::Matches($t, '\] > state')).Count; ignored = ([regex]::Matches($t, 'repeat press ignored')).Count; log = $t }
  }
  $r = Twice 'guardprobe' 300
  Check "a key exe started twice 0.3 s apart runs once and logs the second as a repeat (runs $($r.runs), ignored $($r.ignored))" ($r.runs -eq 1 -and $r.ignored -eq 1) $r.log
  Start-Sleep -Milliseconds 900
  $r = Twice 'guardprobe' 900
  Check "... 0.9 s apart it runs twice (runs $($r.runs))" ($r.runs -eq 2 -and $r.ignored -eq 0) $r.log
  Start-Sleep -Milliseconds 900
  $r = Twice 'vol-up' 300
  Check "vol-up started twice 0.3 s apart runs twice (runs $($r.runs))" ($r.runs -eq 2 -and $r.ignored -eq 0) $r.log
  Remove-Item (Join-Path $env:TEMP 'irdeck-guardprobe.last'), (Join-Path $env:TEMP 'irdeck-vol-up.last') -Force -ErrorAction SilentlyContinue
}

Section '4. wiring'
$ir = [IO.File]::ReadAllText((Join-Path $root 'src\irdeck.cs'))
$dash = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
Check 'irdeck: no verb is exempt any more (the old `verb != "media" && verb != "key"` is gone) and the guard is DeckGuard' ($ir -notmatch 'verb != "media"' -and $ir -match 'DeckGuard\.KeyRuns\(self, a, last, now, true\)' -and $ir -match 'DeckGuard\.UsesMutex\(self\)')
Check 'irdash /api/do asks DeckGuard before it dispatches anything' ($dash -match 'if \(!DeckDo\.Allow\(dc, da, DateTime\.UtcNow\.Ticks\)\)' -and $dash.IndexOf('DeckDo.Allow(dc') -lt $dash.IndexOf('bool ok = TvView.Handles'))
Check 'both builds compile deckguard.cs' (([IO.File]::ReadAllText((Join-Path $root 'build-irdeck.ps1'))) -match 'deckguard\.cs' -and ([IO.File]::ReadAllText((Join-Path $root 'dash\build.ps1'))) -match 'deckguard\.cs')
$cl = [IO.File]::ReadAllText((Join-Path $root 'CLAUDE.md')); $ar = [IO.File]::ReadAllText((Join-Path $root 'docs\ARCHITECTURE.md'))
Check 'CLAUDE.md rule 6 and ARCHITECTURE.md say what the code does (0.7 s, VOL / SPOTTER / SEAT exempt, /api/do)' ($cl -match '0\.7 s' -and $cl -match 'SEAT' -and $ar -match 'deckguard\.cs' -and $ar -match '/api/do')

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
