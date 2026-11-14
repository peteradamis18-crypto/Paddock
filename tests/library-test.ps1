# library-test.ps1 - offline: the RACES library (W1-1, dash\src\library.cs): SessionIndex + Library.
#   1. the index (newest first, IsRace, Best from the sidecar, markers)   2. trash and undo   3. retention (and nothing while a session is on)
#   4. free up space   5. storage maths   6. the /api/library and /deck/summary JSON contract   7. thumbnails (RecMock), yielding to a session
#   8. source checks: the routes and the deck part are wired in irdash.cs
#   9. W1-4 SHARE TO YOUTUBE: raceshare (queued from the press, cut by the pretend ffmpeg, YouTube.Enqueue with title/description/privacy),
#      never twice, the cut tidy, a failed cut, ytprivacy / yttemplate / ytsignin, the five titles, storage.freeUp
# A throw-away exe built from dash\src (the build.ps1 list) + tests\library-main.cs runs in tests\library-scratch\bin against a scratch
# vault of 1-KB pretend videos with real schema-2 sidecars. Nothing touches irdash, Peter's vault or any app.
#   powershell -ExecutionPolicy Bypass -File tests\library-test.ps1 [-Only 2,3] [-Keep]
param([string]$Only = '', [switch]$Keep)
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
function Section($t) { Assert-RigFree -Where $t; $t }
$scratch = Join-Path $PSScriptRoot 'library-scratch'
$bin = Join-Path $scratch 'bin'
Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $bin | Out-Null

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$buildList = Get-Content (Join-Path $root 'dash\build.ps1') -Raw
$srcs = @([regex]::Matches($buildList, '"\$d\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('dash\src\' + $_.Groups[1].Value) }) +
        @([regex]::Matches($buildList, '"\.\.\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('src\' + $_.Groups[1].Value) }) +
        @((Join-Path $PSScriptRoot 'library-main.cs'))
$harness = Join-Path $bin 'library-harness.exe'

'W1-1 the RACES library: SessionIndex + Library'
try {
  Section 'Section 0. the harness'
  $cout = & $csc /nologo /target:exe /platform:anycpu /main:IRDash.LibraryMain "/out:$harness" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll /r:System.Security.dll @srcs 2>&1 | Out-String
  ok 'the harness (dash\src + tests\library-main.cs) compiles' (Test-Path $harness) ($cout | Select-String 'error' | Out-String)
  if (-not (Test-Path $harness)) { throw 'no harness' }

  Section 'Sections 1-7. the library (one run of the harness)'
  $argList = @(); if ($Only) { $argList = @($Only) }
  $sp = @{ FilePath = $harness; NoNewWindow = $true; PassThru = $true }; if ($argList.Count -gt 0) { $sp.ArgumentList = $argList }
  $p = Start-Process @sp -RedirectStandardOutput (Join-Path $scratch 'out.txt') -RedirectStandardError (Join-Path $scratch 'err.txt')
  $p.PriorityClass = 'BelowNormal'
  if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch { }; ok 'the harness finished within 3 minutes' $false }
  $lines = @(Get-Content (Join-Path $scratch 'out.txt'))
  foreach ($l in $lines) { if ($l -match '^ok (.*)') { ok $Matches[1] $true } elseif ($l -match '^FAIL (.*)') { ok $Matches[1] $false } elseif ($l -match '^-- ') { $l } }
  ok 'the harness ran to the end' ($lines -contains 'DONE') (Get-Content (Join-Path $scratch 'err.txt') -Raw)

  Section 'Section 8. source checks (wiring)'
  $ir = Get-Content (Join-Path $root 'dash\src\irdash.cs') -Raw
  $rs = Get-Content (Join-Path $root 'dash\src\rigstate.cs') -Raw
  $va = Get-Content (Join-Path $root 'dash\src\vault.cs') -Raw
  $rc = Get-Content (Join-Path $root 'dash\src\recorder.cs') -Raw
  ok '8. /deck/summary''s races part comes from Library.DeckJson' ($ir.Contains('StateBuilder.AddDeck("races", 10000, Library.DeckJson);') -and -not $ir.Contains('AddDeck("races", 10000, Recorder.RacesJson)'))
  ok '8. GET /api/library and /api/library/thumb are routed' ($ir.Contains('path == "/api/library")') -and $ir.Contains('path == "/api/library/thumb"') -and $ir.Contains('"Cache-Control: max-age=86400'))
  ok '8. /api/do sends the library commands to Library.Do after the session guard' ($ir -match '(?s)Gate\.GuardDo\(dc, da\).*if \(Library\.Handles\(dc\)\)')
  ok '8. Library.Start runs at start-up after the recorder' ($ir -match '(?s)Recorder\.Init\(RootDir\); Recorder\.Start\(\);.*Library\.Start\(\);')
  ok '8. racedelete and /api/rec/delete trash instead of deleting for good' ($va.Contains('Library.TrashOne(a) == "DELETED"') -and $va.Contains('Library.TrashOne(Q(q, "id"))') -and -not $va.Contains('Recorder.Delete('))
  ok '8. the guarded list has the four new commands' ($rs.Contains('"racetrash", "raceundo", "raceempty", "racefree"'))
  ok '8. the recorder''s count/budget rule runs only in its sandbox now' ($rc.Contains('if (testOn) lock (gate)') -and $rc.Contains('testOn && guard < 1000'))
} finally {
  if (-not $Keep) { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
"`n$($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
