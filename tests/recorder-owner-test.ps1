# recorder-owner-test.ps1 - offline: a recorded segment belongs to one session (W0-11).
# 2026-11-13 16:48: the session file waits for the sim to close (W0-3), the static run outlived ffmpeg, and each new
# session re-pointed the old run to itself: Qualify swallowed Practice 2, the Race chased Qualify's deleted segments.
#   1-3. a throw-away exe built from dash\src (the build.ps1 list) + tests\recorder-owner-main.cs calls Recorder.AdoptRun
#   4.   source checks: the gap line and the post-write segs.Remove are unchanged
# Nothing touches irdash or any app.
#   powershell -ExecutionPolicy Bypass -File tests\recorder-owner-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
$tmp = Join-Path $env:TEMP ('rec-owner-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$buildList = Get-Content (Join-Path $root 'dash\build.ps1') -Raw
$srcs = @([regex]::Matches($buildList, '"\$d\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('dash\src\' + $_.Groups[1].Value) }) +
        @([regex]::Matches($buildList, '"\.\.\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('src\' + $_.Groups[1].Value) }) +
        @((Join-Path $PSScriptRoot 'recorder-owner-main.cs'))
$harness = Join-Path $tmp 'recorder-owner.exe'

'W0-11 recorder: a segment belongs to one session'
try {
  Assert-RigFree -Where '1. compile'
  'Section 1. the harness'
  $cout = & $csc /nologo /target:exe /platform:anycpu /main:IRDash.RecorderOwnerMain "/out:$harness" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll @srcs 2>&1 | Out-String
  ok 'the harness (dash\src + tests\recorder-owner-main.cs) compiles' (Test-Path $harness) $cout
  if (-not (Test-Path $harness)) { throw 'no harness' }

  Assert-RigFree -Where '2. adopt'
  'Section 2. AdoptRun: cases 1-3'
  $lines = & $harness
  foreach ($l in $lines) { if ($l -match '^ok (.*)') { ok $Matches[1] $true } elseif ($l -match '^FAIL (.*)') { ok $Matches[1] $false } }
  ok 'the harness ran to the end' ($lines -contains 'DONE')

  Assert-RigFree -Where '3. source'
  'Section 3. source checks (FinishSession and the gap marking left alone)'
  $rec = Get-Content (Join-Path $root 'dash\src\recorder.cs') -Raw
  ok '4. the "partial - N gap(s)" line is unchanged' ($rec.Contains('Log.W("recorder: session " + s.Id + " is partial - " + s.Gaps.Count + " gap(s) where segments were missing; laps inside a gap have no video");'))
  ok '4. the post-write segs.Remove is unchanged' ($rec.Contains('lock (gate) { foreach (RecSeg g in sel) segs.Remove(g); sessions.RemoveAll(delegate (RecSess x) { return x.Id == s.Id; }); sessions.Add(s); finishing.Remove(s); }'))
  ok '4. BeginSession goes through AdoptRun and no longer re-points the run itself' ($rec -match 'lock \(gate\) openSess = s;\s+AdoptRun\(s\);' -and -not $rec.Contains('if (g.Owner == run && !s.Segs.Contains(g)) s.Segs.Add(g);'))
  ok '4. AdoptRun leaves a run that already has a session alone' ($rec.Contains('if (run == null || run.Sess != null) return;'))
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
"`n$($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
