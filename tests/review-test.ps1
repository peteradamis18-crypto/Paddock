# review-test.ps1 - offline: the REVIEW engine (W4-1, dash\src\review.cs) on real telemetry.
#   1. the 12 Nov race: best 1:33.832 (lap 9), 7 counted of 10, reference lap 9, three cards ranked by loss that pass Lint, the plan
#      names card 1's corner, map.gain sums to about best - lap
#   2. a 2-lap session (a cut of that race): one card, no advice, the note; a cut with no full lap: "No full lap yet", no laps
#   3. the 13 Nov 16-27-02 race (Peter's telemetry, read-only, when the sim is not running): the race story from a field log
#      (a made-up log of that race's laps: the real one is on the rig, see the LIVE check), one clean-air card at most
#   4. "working" first, "ready" after the job; the cache written temp + move; a session on = the job waits; traces through a job
#   5. the corner table and its definitions; progress from the lap caches and the reviews; ref.kind "ever" with a conditions line
#   6. Lint on the never-say list
# A throw-away exe built from dash\src (the build.ps1 list) + tests\review-main.cs (the recorder-owner-test pattern). The
# telemetry files are only read, one at a time, at BelowNormal; everything written goes to %TEMP%. Nothing touches irdash or any app.
#   powershell -ExecutionPolicy Bypass -File tests\review-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$fx = Join-Path $root 'tests\fixtures'; $tools = Join-Path $root 'tests\tools'
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
$tele = 'C:\Users\peter\OneDrive\Documents\iRacing\telemetry'
$f12 = Join-Path $tele 'toyotagr86_roadatlanta full 2026-11-12 09-28-07.ibt'
$f13 = Join-Path $tele 'toyotagr86_roadatlanta full 2026-11-13 16-27-02.ibt'
$cut2 = Join-Path $fx 'review-12nov-2laps.ibt'; $cut0 = Join-Path $fx 'review-12nov-nolap.ibt'
$tmp = Join-Path $env:TEMP ('review-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$buildList = Get-Content (Join-Path $root 'dash\build.ps1') -Raw
$srcs = @([regex]::Matches($buildList, '"\$d\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('dash\src\' + $_.Groups[1].Value) }) +
        @([regex]::Matches($buildList, '"\.\.\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('src\' + $_.Groups[1].Value) }) +
        @((Join-Path $PSScriptRoot 'review-main.cs'))
$harness = Join-Path $tmp 'review.exe'

'W4-1 the review engine'
try {
  Assert-RigFree -Where '0. compile'
  'Section 0. the harness and the fixtures'
  $cout = & $csc /nologo /target:exe /optimize+ /platform:anycpu /main:IRDash.ReviewMain "/out:$harness" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll @srcs 2>&1 | Out-String
  ok 'the harness (dash\src + tests\review-main.cs) compiles' (Test-Path $harness) $cout
  if (-not (Test-Path $harness)) { throw 'no harness' }
  ok 'review.cs is in build.ps1''s list' ($buildList -match '\\src\\review\.cs')
  $rsrc = Get-Content (Join-Path $root 'dash\src\review.cs') -Raw
  ok 'the cache is written temp + move' ($rsrc.Contains('File.WriteAllBytes(tmp, b);') -and $rsrc.Contains('File.Move(tmp, path);'))
  ok 'the trace cache key carries the review''s Sig, and no error is ever written to a file' ($rsrc.Contains('key += "-" + Hash(Sig(file) + "|" + rf);') -and -not $rsrc.Contains('.err"'))
  ok 'a review is written down only when it is ready and has the track''s corners' ($rsrc.Contains('if (!Lasting(json))'))
  $ir = Get-Content (Join-Path $root 'dash\src\irdash.cs') -Raw
  ok 'irdash matches the four review paths exactly' ($ir.Contains('(path == "/api/review" || path == "/api/review/traces" || path == "/api/review/corners" || path == "/api/review/progress")') -and -not $ir.Contains('path.StartsWith("/api/review/"'))
  $sbs = Get-Content (Join-Path $root 'dash\src\statebuilder.cs') -Raw
  ok 'the review hook fires when the session ends and again when the sim closes' (([regex]::Matches($sbs, 'SessionEnded\(\)')).Count -ge 2)
  ok 'the build runs as a whenFree job (never on a request thread)' ($rsrc.Contains('Jobs.Run("review " + Path.GetFileName(f), delegate { BuildJob(f); }, true)'))
  $an = Get-Content (Join-Path $root 'dash\src\analysis.cs') -Raw
  ok 'LoadCorners never caches an empty set' ($an.Contains('if (cs.Turns.Count > 0) lock (gate) cornerCache[key] = cs;'))
  ok 'LoadCorners reads the Lovely file only when it exists' ($an.Contains('if (onDisk) cs = Corners.ParseLovely(') -and -not $an.Contains('else cs = Corners.ParseLovely('))
  if (-not (Test-Path $f12)) { throw 'the 12 Nov race file is not on this PC: nothing can run' }
  if (-not (Test-Path $cut2)) { & (Join-Path $tools 'ibt-cut.ps1') -Source $f12 -Out $cut2 -AroundLap 9 -Seconds 290 | Out-Null }
  if (-not (Test-Path $cut0)) { & (Join-Path $tools 'ibt-cut.ps1') -Source $f12 -Out $cut0 -AroundLap 5 -Seconds 60 | Out-Null }
  ok 'the two cuts of the 12 Nov race are there (2 laps; no full lap)' ((Test-Path $cut2) -and (Test-Path $cut0))
  # the Road Atlanta corners as Lovely gives them (the repo's copy of the /corners answer: docs\design\drive-v1\data\corners-127.json),
  # written as a Lovely file + index under the scratch data root (the rig's data\corners is not in the source repository)
  $ld = Join-Path $tmp 'data\corners\lovely'; New-Item -ItemType Directory -Force $ld | Out-Null
  $c127 = Get-Content (Join-Path $root 'docs\design\drive-v1\data\corners-127.json') -Raw | ConvertFrom-Json
  $turns = @($c127.turns | ForEach-Object { @{ name = $(if ($_.official) { 'Turn ' + $_.official } else { $_.name }); start = $_.pct0; end = $_.pct1; apex = $_.pctApex } })
  (@{ name = 'Road Atlanta'; turn = $turns } | ConvertTo-Json -Depth 5) | Set-Content -Encoding ascii (Join-Path $ld 'roadatlanta-full.json')
  (@{ tracks = @(@{ trackId = 'roadatlanta full'; trackName = 'Road Atlanta Full Course'; path = 'iracing/roadatlanta-full.json'; file = 'roadatlanta-full.json' }) } | ConvertTo-Json -Depth 5) | Set-Content -Encoding ascii (Join-Path $ld 'index.json')
  ok 'the Road Atlanta corner fixture (Lovely format, 14 turns or so)' ($turns.Count -ge 10) "$($turns.Count) turns"
  $use13 = '-'
  if (Test-Path $f13) { $use13 = $f13 }

  Assert-RigFree -Where '1-6. the engine'
  'Sections 1-6. the engine (one run: each file is read once)'
  $p = New-Object Diagnostics.ProcessStartInfo $harness
  $p.Arguments = '"' + $root + '" "' + $tmp + '" "' + $tele + '" "' + $f12 + '" "' + $use13 + '" "' + $cut2 + '" "' + $cut0 + '"'
  $p.UseShellExecute = $false; $p.RedirectStandardOutput = $true; $p.CreateNoWindow = $true
  $pr = [Diagnostics.Process]::Start($p); try { $pr.PriorityClass = 'BelowNormal' } catch { }
  $out = $pr.StandardOutput.ReadToEnd(); $pr.WaitForExit()
  $lines = $out -split "`r?`n"
  foreach ($l in $lines) {
    if ($l -match '^ok (.*)') { ok $Matches[1] $true }
    elseif ($l -match '^FAIL (.*)') { ok $Matches[1] $false }
    elseif ($l -match '^(skip|info|section) (.*)') { "  $l" }
    elseif ($l.Trim().Length -gt 0 -and $l -ne 'DONE') { "  .. $l" }
  }
  ok 'the harness ran to the end' ($lines -contains 'DONE')
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
"`n$($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
