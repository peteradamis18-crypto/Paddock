# laprules-test.ps1 - offline: the ONE counted rule (W0-6, dash\src\lapstore.cs) on made-up laps, the live judge on made-up frames,
# and the lint that no other place keeps its own lap rule, rules version or best-lap sum.
#   1. lapstore.cs + ibtfile.cs compiled on their own with tests\lapstore-unit.cs: one case per rule (lap 0, slower clean lap, new best,
#      incident, quicker lap iRacing did not take, one off-track record, pit, no time, short lap, no best channel), Best()
#   2. the live judge: same-frame time + best, a time announced in the same frame as the lap counter, a quicker lap that is not counted,
#      an incident lap, no time within the 4 s window
#   3. lint: one rules version, the old window helpers gone, every caller reads counted / best from the lap store, no page sums a best itself
#   powershell -ExecutionPolicy Bypass -File tests\laprules-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'dash\src'; $www = Join-Path $root 'dash\www\v2'
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
function Src($name) { [IO.File]::ReadAllText((Join-Path $src $name)) }

'W0-6 the counted rule'
# ---------------------------------------------------------------- 1 + 2. compiled on their own
Assert-RigFree -Where '1. unit'
'Section 1. the rule on made-up laps / 2. the live judge'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP ('laprules-unit-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  $cout = & $csc /nologo /target:exe "/out:$tmp\unit.exe" /r:System.dll /r:System.Core.dll /r:System.Web.Extensions.dll (Join-Path $src 'ibtfile.cs') (Join-Path $src 'lapstore.cs') (Join-Path $PSScriptRoot 'lapstore-unit.cs') | Out-String
  ok 'ibtfile.cs + lapstore.cs compile on their own (no other irdash code needed)' (Test-Path "$tmp\unit.exe") $cout
  if (Test-Path "$tmp\unit.exe") {
    foreach ($mode in 'judge', 'live') {
      $u = & "$tmp\unit.exe" $mode
      foreach ($l in $u) { if ($l -match '^ok (.*)') { ok $Matches[1] $true } elseif ($l -match '^FAIL (.*)') { ok $Matches[1] $false } }
      ok "unit run '$mode' finished" ($u -contains 'UNIT-DONE')
    }
  }
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- 3. lint
Assert-RigFree -Where '3. lint'
'Section 3. one rule, one version, one best'
$all = @{}; foreach ($f in Get-ChildItem $src -Filter *.cs) { $all[$f.Name] = [IO.File]::ReadAllText($f.FullName) }
$ls = $all['lapstore.cs']
ok 'LapRules lives in lapstore.cs only' (($all.Keys | Where-Object { $all[$_] -match 'static class LapRules\b' }) -join ',' -eq 'lapstore.cs') (($all.Keys | Where-Object { $all[$_] -match 'static class LapRules\b' }) -join ',')
ok 'one rules version: LapRules.Version = 4' ($ls -match 'public const int Version = 4;')
ok 'the window is 4 s and the minimum lap 15 s, in one constant set' ($ls -match 'WindowSec = 4\.0' -and $ls -match 'MinLap = 15')
ok 'the career cache version is made from LapRules.Version' ($all['career.cs'] -match 'const int CrVersion = 100 \+ LapRules\.Version;')
$oldHelpers = $all.Keys | Where-Object { $all[$_] -match 'LapRules\.(BestAfter|BestBefore|Counted)\(' }
ok 'the old 1.5-2.5 s window helpers (LapRules.BestAfter / BestBefore / Counted) are gone' (-not $oldHelpers) ($oldHelpers -join ',')
$versions = $all.Keys | Where-Object { $all[$_] -match '\.Rules\s*=\s*\d' -or $all[$_] -match 'Rules\s*=\s*[1-9];' }
ok 'no rules version is a bare number anywhere (Rec / RefData / VSession all store LapRules.Version)' (-not $versions) ($versions -join ',')
ok 'TrackMaps.OpenIbt is a wrapper over IbtFile.Open (one header parser)' ($all['irdash.cs'] -match 'IbtFile f = IbtFile\.Open\(path, wantVars\)' -and $all['irdash.cs'] -notmatch 'infoLen = BitConverter\.ToInt32\(h, 16\)')
ok 'VarDef is declared once, in ibtfile.cs' (($all.Keys | Where-Object { $all[$_] -match 'sealed class VarDef' }) -join ',' -eq 'ibtfile.cs')
$dec = $all.Keys | Where-Object { $_ -ne 'ibtfile.cs' -and $all[$_] -match 'static double (At|AtVar|Read)\(byte\[\] b, (int o, )?VarDef d\)\s*\{\s*(if|int|switch)' }
ok 'the .ibt record decoders in analysis, data, corners and TrackMaps call IbtFile.At' (-not ($dec | Where-Object { $_ -in 'analysis.cs', 'data.cs', 'corners.cs', 'irdash.cs' })) ($dec -join ',')
ok 'analysis.cs: Counted() is the lap store''s verdict' ($all['analysis.cs'] -match 'static bool Counted\(LapTrace lap\) \{ return Timed\(lap\) && lap\.Truth != null && lap\.Truth\.Counted; \}')
ok 'analysis.cs: CountedBest is LapStore.BestTime' ($all['analysis.cs'] -match 'LapStore\.BestTime\(f\.Laps\)')
ok 'analysis.cs: Gather has no 40-file cap on what it sees (the lap cache sees every file)' ($all['analysis.cs'] -match 'LapStore\.Peek\(f\)' -and $all['analysis.cs'] -notmatch 'if \(extra >= 40\) break;\s*string full')
ok 'data.cs: IbtLaps takes counted and the best from the lap store (no fallback to a lap iRacing did not count)' ($all['data.cs'] -match 'LapStore\.LapAt\(truth, r\.Start\)' -and $all['data.cs'] -notmatch 'r\.Counted != b\.Counted')
ok 'data.cs: IbtLaps loads a file outside its lock' ($all['data.cs'] -match 'Chan n = Load\(path\); n\.Sig = sig;\s+// loaded outside the lock')
ok 'irdash.cs: the career row best is LapStore.Best, no "quickest announced lap" fallback' ($all['irdash.cs'] -match 'FileLaps fl = LapStore\.ForFile\(path\)' -and $all['irdash.cs'] -notmatch 'c < med \* 0\.7')
ok 'vault.cs: the Vault best and counted laps come from the lap store' ($all['vault.cs'] -match 'LapRec tb = truth != null \? truth\.BestLap : null;')
ok 'recorder.cs: laps are judged live by LiveJudge, lap 0 is never a lap row, pb only on counted laps' ($all['recorder.cs'] -match 'judge\.Poll\(' -and $all['recorder.cs'] -match 'if \(l\.N < 1\) continue;' -and $all['recorder.cs'] -match 'c2\.Pb = L\.Why == "pb" \|\| \(L\.Counted')
ok 'recorder.cs: /api/rec/races best, laps and counted come from RaceLaps (LapStore.Best)' ($all['recorder.cs'] -match 'static void RaceLaps\(RecSess s, bool telemetry, out int laps, out int counted, out double best, out int bestN\)' -and $all['recorder.cs'] -notmatch 'r\[0\] >= 1 && r\[2\] > 0 && \(best == 0')
ok 'refs.cs: the PB reference adopts only a lap the live judge counted' ($all['refs.cs'] -match 'if \(!jr\.Counted \|\|' -and $all['refs.cs'] -notmatch 'penLastBefore')
ok 'review 1: LiveJudge takes the last time from the frame before the line (no stale lastSeen after an unjudged lap)' ($ls -match 'lastSeen = lltBefore;' -and $ls -notmatch 'public void Seen\(')
ok 'review 2: laps are matched by their first record, never by lap number (numbers repeat in a two-session file)' (-not ($all.Keys | Where-Object { $all[$_] -match 'LapStore\.Lap\(' }) -and $all['analysis.cs'] -match 'LapStore\.LapAt\(truth, a\)' -and $all['data.cs'] -match 'LapStore\.LapAt\(truth, r\.Start\)' -and $ls -match 'sn\[j\] == sn\[k\]')
ok 'review 3: a PB reference built from a file under an older lap rule is built again' ($all['refs.cs'] -match '!\(have\.Rules < LapRules\.Version && have\.Source == "ibt"\)')
ok 'review 4: Coach never anchors its rhythm on an uncounted lap while a counted best exists' ($all['coach.cs'] -match 'if \(best == null\) anchored = false;')
ok 'review 5: a file the sim never closed is cached after 10 quiet minutes with the sim off' ($ls -match 'finished = t\.IsFinished \|\| Abandoned\(fi\)')
ok 'review 7: an old sidecar alone never counts lap 1 of a race or an incident lap' ($all['recorder.cs'] -match 'l\.N == 1 && Regex\.IsMatch\(s\.Type')
ok 'home.cs: PB here is per car AND track (N5)' ($all['home.cs'] -match 'string key = r\.Car \+ "\|" \+ r\.Track \+ "\|" \+ r\.Config;')
ok 'coach.cs: the reference is LapStore.Best' ($all['coach.cs'] -match 'LapRec tb = truth != null \? truth\.BestLap : null;' -and $all['coach.cs'] -notmatch 'PureOf\(all\)')
ok 'deepdive.cs: a stint best is a counted lap' ($all['deepdive.cs'] -match 'if \(Counted\(lp\) && \(double\.IsNaN\(cur\.Best\)')
ok 'build.ps1 compiles ibtfile.cs and lapstore.cs' ((Get-Content (Join-Path $root 'dash\build.ps1') -Raw) -match 'ibtfile\.cs' -and (Get-Content (Join-Path $root 'dash\build.ps1') -Raw) -match 'lapstore\.cs')
# pages: none works out a best lap itself (grep for Math.min over lap times in the pages that show a best)
$js = @{}; foreach ($n in 'sessions.js', 'races.js', 'home.js', 'coach.js') { $p = if ($n -eq 'races.js') { Join-Path $root 'dash\www\app\pages\races.js' } else { Join-Path $www $n }; $js[$n] = [IO.File]::ReadAllText($p) }   # W3-1: RACES moved into the shell
$sums = @(); foreach ($n in $js.Keys) { foreach ($m in [regex]::Matches($js[$n], '[^\r\n]*Math\.min\([^)]*\.time[^\r\n]*')) { $sums += "$n : $($m.Value.Trim())" } }
ok 'no page computes a best lap itself (Math.min over lap times in sessions/races/home/coach.js)' ($sums.Count -eq 0) ($sums -join ' | ')
ok 'races.js says "no clean lap" when nothing counted' ($js['races.js'] -match "'no clean lap'")

"`n$($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
