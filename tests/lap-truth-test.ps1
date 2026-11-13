# lap-truth-test.ps1 - offline: the 12 Nov Road Atlanta race says the same best lap everywhere (W0-6, docs\rework\evidence\09 section 1a).
# What iRacing's own channels say about that race (LapLastLapTime / LapBestLapTime / PlayerCarMyIncidentCount in the file):
#   laps 1-10 (lap 0 = the formation lap, never a lap); lap 1 101.580 but iRacing's best stayed empty (-1): not counted;
#   lap 6 93.639 with an incident (+1 at 09:40:02) and iRacing kept 93.919: not counted; lap 7 94.831 with an incident (+1 at 09:41:51):
#   not counted; laps 2, 3, 4, 5, 8, 9, 10 counted; best = lap 9, 1:33.832 (iRacing's best became 93.832 after it).
#   1. fast: the W0-8 fixture cut race-12nov.ibt (lap 0 -> lap 1) and a cut around lap 9 (built here from the source when missing)
#   2. once per run: the full file, the lap store
#   3. every JSON that shows a best for that session, from a throw-away exe built from dash\src (tests\lap-truth-main.cs):
#      /ibt/laps (Vault lap list), the Vault card + sessions.tsv row, the Sessions page row (career cache), CountedBest,
#      /api/rec/races (with the .ibt and from the sidecar alone), Session Review, Coach, Career
# The source is only read (BelowNormal), and only while the sim is not running (Assert-RigFree). Nothing touches irdash or any app.
#   powershell -ExecutionPolicy Bypass -File tests\lap-truth-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$fx = Join-Path $root 'tests\fixtures'; $tools = Join-Path $root 'tests\tools'
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
$source = 'C:\Users\peter\OneDrive\Documents\iRacing\telemetry\toyotagr86_roadatlanta full 2026-11-12 09-28-07.ibt'
$fileName = Split-Path -Leaf $source
$race = Join-Path $fx 'race-12nov.ibt'; $lap9 = Join-Path $fx 'race-12nov-lap9-whole.ibt'
$sidecar = Join-Path $fx 'race-12nov-sidecar.json'
$tmp = Join-Path $env:TEMP ('lap-truth-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null

# the harness: dash\src (the build.ps1 list) + tests\lap-truth-main.cs, its own Main
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$srcs = @([regex]::Matches((Get-Content (Join-Path $root 'dash\build.ps1') -Raw), '"\$d\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('dash\src\' + $_.Groups[1].Value) }) + @((Join-Path $root 'src\deckstate.cs'), (Join-Path $PSScriptRoot 'lap-truth-main.cs'))
$harness = Join-Path $tmp 'lap-truth.exe'
$cout = & $csc /nologo /target:exe /optimize+ /platform:anycpu /main:IRDash.LapTruthMain "/out:$harness" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll @srcs 2>&1 | Out-String
function Run($ibt, $cacheName, $teleDir) {
  $cache = Join-Path $tmp $cacheName; New-Item -ItemType Directory -Force $cache | Out-Null
  $p = New-Object Diagnostics.ProcessStartInfo $harness
  $p.Arguments = '"' + $ibt + '" "' + $cache + '" "' + $root + '" "' + $sidecar + '" "' + $teleDir + '"'
  $p.UseShellExecute = $false; $p.RedirectStandardOutput = $true; $p.CreateNoWindow = $true
  $pr = [Diagnostics.Process]::Start($p); try { $pr.PriorityClass = 'BelowNormal' } catch { }
  $out = $pr.StandardOutput.ReadToEnd(); $pr.WaitForExit()
  $h = @{}; foreach ($l in ($out -split "`r?`n")) { if ($l -match '^(\S+) (.*)$') { $h[$Matches[1]] = $Matches[2] } }
  return $h
}

'W0-6 lap truth: the 12 Nov race'
try {
  ok 'the harness (dash\src + tests\lap-truth-main.cs) compiles' (Test-Path $harness) $cout
  if (-not (Test-Path $harness)) { throw 'no harness' }
  $haveSource = Test-Path $source
  if (-not $haveSource) { '  skip the 12 Nov telemetry file is not on this PC: sections 1b, 2 and 3 cannot run' }

  # ---------------------------------------------------------------- 1. fast: the fixture cuts
  Assert-RigFree -Where '1. fixtures'
  'Section 1. the fixture cuts'
  if (-not (Test-Path $race) -and $haveSource) { & (Join-Path $tools 'ibt-cut.ps1') -Source $source -Out $race -From 200 -To 380 | Out-Null }
  if (-not (Test-Path $lap9) -and $haveSource) { & (Join-Path $tools 'ibt-cut.ps1') -Source $source -Out $lap9 -AroundLap 10 -Seconds 200 | Out-Null }
  if (Test-Path $race) {
    $d1 = Join-Path $tmp 'fx1'; New-Item -ItemType Directory -Force $d1 | Out-Null; Copy-Item $race (Join-Path $d1 $fileName)
    $a = Run (Join-Path $d1 $fileName) 'c1' $d1
    ok 'race-12nov.ibt (formation lap into lap 1): lap 0 is never a lap' (-not $a.ContainsKey('store.lap0')) $a['store.lap0']
    ok 'race-12nov.ibt: lap 1 is iRacing''s 101.580 and not counted (its best stayed empty)' ($a['store.lap1'] -eq '101.580 not-counted not-best') $a['store.lap1']
    ok 'race-12nov.ibt: one lap, none counted, no best (shown as "no clean lap")' ($a['store.laps'] -eq '1' -and $a['store.counted'] -eq '0' -and $a['store.best'] -eq 'none') "$($a['store.laps']) / $($a['store.counted']) / $($a['store.best'])"
  } else { '  skip race-12nov.ibt is missing and cannot be built here' }
  if (Test-Path $lap9) {
    $d2 = Join-Path $tmp 'fx2'; New-Item -ItemType Directory -Force $d2 | Out-Null; Copy-Item $lap9 (Join-Path $d2 $fileName)
    $b = Run (Join-Path $d2 $fileName) 'c2' $d2
    ok 'the cut around lap 9: lap 9 is 93.832 and counted (iRacing''s best became it 2 s after the line)' ($b['store.lap9'] -match '^93\.832 counted -') $b['store.lap9']
    ok 'the cut around lap 9: Best() = lap 9, 1:33.832' ($b['store.best'] -eq '93.832' -and $b['store.bestLap'] -eq '9') "$($b['store.best']) lap $($b['store.bestLap'])"
    ok 'the cut around lap 9: the lap list (/ibt/laps) says the same' ($b['ibtlaps.best'] -eq '93.832' -and $b['ibtlaps.bestLap'] -eq '9') "$($b['ibtlaps.best']) lap $($b['ibtlaps.bestLap'])"
    ok 'the lap store wrote its cache file (dash\data\laps\<file>.json)' ($b['store.cacheFile'] -eq '1')
  } else { '  skip the lap 9 cut is missing and cannot be built here' }

  if ($haveSource) {
    # ---------------------------------------------------------------- 2. the full file
    Assert-RigFree -Where '2. full file'
    'Section 2. the full race (lap store)'
    $d3 = Join-Path $tmp 'full'; New-Item -ItemType Directory -Force $d3 | Out-Null
    Copy-Item $source (Join-Path $d3 $fileName)       # a private copy: the Career report reads every file in its folder
    $f = Run (Join-Path $d3 $fileName) 'c3' $d3
    "  12 Nov as the lap store reads it:"
    for ($n = 0; $n -le 11; $n++) { if ($f.ContainsKey("store.lap$n")) { "     lap $n  $($f["store.lap$n"])" } }
    ok '10 laps (lap 0, the formation lap, is not one)' ($f['store.laps'] -eq '10' -and -not $f.ContainsKey('store.lap0')) "laps $($f['store.laps'])"
    ok '7 counted: laps 2, 3, 4, 5, 8, 9, 10' ($f['store.counted'] -eq '7') "counted $($f['store.counted'])"
    $cnt = @(); for ($n = 1; $n -le 10; $n++) { if ($f["store.lap$n"] -match ' counted ') { $cnt += $n } }
    ok '... exactly those laps' (($cnt -join ',') -eq '2,3,4,5,8,9,10') ($cnt -join ',')
    ok 'lap 6 (1:33.639) had an incident and is not counted' ($f['store.lap6'] -match '^93\.639 not-counted incident incident') $f['store.lap6']
    ok 'lap 7 had an incident too (+1 at 09:41:51) and is not counted' ($f['store.lap7'] -match '^94\.831 not-counted incident incident') $f['store.lap7']
    ok 'lap 1 is not counted: iRacing''s best lap stayed empty after it' ($f['store.lap1'] -eq '101.580 not-counted not-best') $f['store.lap1']
    ok 'laps 3 and 9 had one off-track record each and still count (iRacing''s own verdict)' ($f['store.lap3'] -eq '93.919 counted - off' -and $f['store.lap9'] -eq '93.832 counted - off') "$($f['store.lap3']) | $($f['store.lap9'])"
    ok 'Best() = lap 9, 1:33.832' ($f['store.best'] -eq '93.832' -and $f['store.bestLap'] -eq '9') "$($f['store.best']) lap $($f['store.bestLap'])"

    # ---------------------------------------------------------------- 3. every JSON with a best for that session
    Assert-RigFree -Where '3. every page'
    'Section 3. every page that shows a best for the 12 Nov race'
    function Same($what, $pre, $wantCounted = '7') {
      if ($f.ContainsKey("$pre.error")) { ok "$what says 1:33.832 and $wantCounted counted" $false ("error: " + $f["$pre.error"]); return }
      ok "$what says 1:33.832 (lap 9) and $wantCounted counted" ($f["$pre.best"] -eq '93.832' -and ($f["$pre.bestLap"] -eq '9' -or -not $f.ContainsKey("$pre.bestLap")) -and $f["$pre.counted"] -eq $wantCounted) "best $($f["$pre.best"]) lap $($f["$pre.bestLap"]) counted $($f["$pre.counted"])"
    }
    Same 'Vault lap list (/ibt/laps)' 'ibtlaps'
    ok 'Vault lap list: no lap 0 row' ($f['ibtlaps.lap0'] -eq '0') "lap 0 rows $($f['ibtlaps.lap0'])"
    Same 'Vault card (VSession)' 'vault'
    ok 'sessions.tsv row: best 93.832, lap 9, 7 counted' ($f['vault.row'] -eq '93.832/9/7') $f['vault.row']
    Same 'Sessions page row and HOME (career cache row)' 'sessions'
    ok 'Sessions page row: 10 laps, not 11' ($f['sessions.laps'] -eq '10') "laps $($f['sessions.laps'])"
    ok 'CountedBest (the PB reference build): 93.832' ($f['countedBest'] -eq '93.832') $f['countedBest']
    Same 'My Races and the deck RACES list (/api/rec/races, from the .ibt)' 'races'
    ok 'My Races: 10 laps, not 11 (lap 0 out)' ($f['races.laps'] -eq '10') "laps $($f['races.laps'])"
    ok 'My Races without the .ibt (old sidecar alone): still 1:33.832, lap 0 out, the two incident laps out' ($f['racesNoIbt.best'] -eq '93.832' -and $f['racesNoIbt.laps'] -eq '10' -and $f['racesNoIbt.counted'] -eq '8') "best $($f['racesNoIbt.best']) laps $($f['racesNoIbt.laps']) counted $($f['racesNoIbt.counted'])"
    Same 'Session Review' 'review'
    Same 'Coach' 'coach'
    if ($f.ContainsKey('career.error')) { ok 'Career says 1:33.832 and 7 counted' $false ("error: " + $f['career.error']) }
    else { ok 'Career says 1:33.832 (lap 9) and 7 counted' ($f['career.best'] -eq '93.832' -and $f['career.bestLap'] -eq '9' -and $f['career.counted'] -eq '7') "best $($f['career.best']) lap $($f['career.bestLap']) counted $($f['career.counted'])" }
    ok 'the harness ran to the end' ($f['DONE'] -eq '1')
  }
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
"`n$($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
