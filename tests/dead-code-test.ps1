# dead-code-test.ps1 - offline (W0-4 "Delete the dead"): the files, routes and test entries that were deleted stay deleted,
# and nothing still points at them. Reads files only; touches no app.
#   powershell -ExecutionPolicy Bypass -File tests\dead-code-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }

'1. deleted files are gone'
$gone = @(
  'dash\www\index.html', 'dash\www\core.js', 'dash\www\ui.js', 'dash\www\map.js', 'dash\www\demo.js', 'dash\www\style.css',
  'dash\www\v2\preview.png', 'dash\www\v2\official.js', 'dash\www\v2\official.css', 'dash\www\v2\idle.js', 'dash\www\v2\cars.js',
  'dash\www\v2\debrief.js', 'dash\www\v2\debrief.css', 'dash\www\v2\sr-demo.json', 'dash\www\v2\tv.js', 'dash\www\v2\tv.css',
  'dash\src\tv.cs', 'tests\actions-test.ps1', 'tests\bench-test.ps1', 'tests\tv-test.ps1', 'tests\tv-live-race-test.ps1',
  # W2-2: the race screen (race.html, app\pages\race.js) replaced Drive v1, the old in-car grid and its SoF header
  'dash\www\v2\drive.js', 'dash\www\v2\drive.css', 'dash\www\v2\race.js', 'tests\drive-v1-test.ps1')
foreach ($g in $gone) { Check "$g does not exist" (-not (Test-Path (Join-Path $root $g))) }
Check 'dash\www\v2\sessionreview.html still exists (Coach''s ALL LAPS opens it)' (Test-Path (Join-Path $root 'dash\www\v2\sessionreview.html'))
Check 'dash\www\v2\sessionreview.js and .css still exist (that page uses them)' ((Test-Path (Join-Path $root 'dash\www\v2\sessionreview.js')) -and (Test-Path (Join-Path $root 'dash\www\v2\sessionreview.css')))

'2. no page under dash\www points at a missing file or a deleted one'
$deletedNames = @('official.js', 'official.css', 'idle.js', 'cars.js', 'debrief.js', 'debrief.css', 'tv.js', 'tv.css', 'sr-demo.json', 'preview.png', 'drive.js', 'drive.css')
$bad = @(); $n = 0
foreach ($h in Get-ChildItem (Join-Path $root 'dash\www') -Recurse -Include *.html) {
  $text = Get-Content -LiteralPath $h.FullName -Raw
  foreach ($m in [regex]::Matches($text, '(?:src|href)="([^"#?]+\.(?:js|css|png|json))(?:\?[^"]*)?"')) {
    $ref = $m.Groups[1].Value
    if ($ref -match '^(https?:|//|data:|/)' -or (Split-Path -Leaf $h.DirectoryName) -eq 'phone') { continue }   # the phone page's icon is served by irdash itself
    $n++
    $leaf = Split-Path -Leaf $ref
    if ($deletedNames -contains $leaf -and -not (Test-Path (Join-Path $h.DirectoryName $ref))) { $bad += "$($h.Name) -> $ref (deleted)" }
    elseif (-not (Test-Path (Join-Path $h.DirectoryName $ref))) { $bad += "$($h.Name) -> $ref (missing)" }
  }
}
Check "$n script/style/picture tags in html all point at files that exist" ($bad.Count -eq 0) ($bad -join '; ')
$idx = Get-Content (Join-Path $root 'dash\www\v2\index.html') -Raw
Check 'index.html loads demo.js only through the ?demo=1 loader' ($idx -match 'demo=1' -and $idx -notmatch '(?m)^<script src="demo\.js">')
Check 'index.html no longer mounts the old debrief or session review' ($idx -notmatch 'sessionreview\.(js|css)' -and $idx -notmatch 'debrief\.(js|css)')
$sess = Get-Content (Join-Path $root 'dash\www\v2\sessions.html') -Raw
Check 'sessions.html no longer loads map.js' ($sess -notmatch 'src="map\.js"')
$wwwJs = (Get-ChildItem (Join-Path $root 'dash\www') -Recurse -Include *.js | Get-Content -Raw) -join "`n"
Check 'index.html no longer loads drive.js, drive.css or the old race.js, and has no in-car grid (W2-2)' ($idx -notmatch 'src="(drive|race)\.js"' -and $idx -notmatch 'href="drive\.css"' -and $idx -notmatch 'id="(strip|pStand|drive)"')
Check 'no page script calls Drive v1, the old grid or the SoF header (W2-2)' ($wwwJs -notmatch '\bDrive\.(tick|onFrame|frame|shown|showRec)' -and $wwwJs -notmatch 'RaceExtras' -and $wwwJs -notmatch "\`$\('(sofBox|standings|rpmbar|dRows)'\)")
Check 'no page script calls the deleted debrief, tv or idle objects' ($wwwJs -notmatch 'Debrief\.(frame|show|hide)' -and $wwwJs -notmatch 'Tv\.(frame|on|poll)\b' -and $wwwJs -notmatch 'linkDebrief')
Check 'the dead idle rules are gone from style.css' ((Get-Content (Join-Path $root 'dash\www\v2\style.css') -Raw) -notmatch '\.idle-(glow|mark|mid|line)\b')

'3. dash\src has none of the deleted routes'
$src = (Get-ChildItem (Join-Path $root 'dash\src') -Filter *.cs | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
$routes = @('"/timings"', '/api/delta/preview', '"/cars/status"', '/corners/detect', '/corners/audit', '"/tv"', '"/tv/data"',
            '"/analysis/gain"', '"/field/status"', '"/official/import"', 'path.StartsWith("/maps/"', 'TvView', 'Tv.Start', 'Tv.Json')
foreach ($r in $routes) { Check "no .cs under dash\src contains $r" (-not $src.Contains($r)) }
Check 'the corner list route itself (/corners) is still there' ($src.Contains('path == "/corners"'))

'4. the build and the test list only name files that exist'
$bp = Get-Content (Join-Path $root 'dash\build.ps1') -Raw
$miss = @(); foreach ($m in [regex]::Matches($bp, '\$d\\src\\([A-Za-z0-9_]+\.cs)')) { if (-not (Test-Path (Join-Path $root ('dash\src\' + $m.Groups[1].Value)))) { $miss += $m.Groups[1].Value } }
Check 'dash\build.ps1 lists no .cs file that is missing' ($miss.Count -eq 0) ($miss -join ', ')
Check 'dash\build.ps1 does not list tv.cs' ($bp -notmatch 'tv\.cs')
$ra = Get-Content (Join-Path $root 'tests\run-all.ps1') -Raw
$missT = @(); foreach ($m in [regex]::Matches($ra, "f = '([^']+\.ps1)'")) { if (-not (Test-Path (Join-Path $root ('tests\' + $m.Groups[1].Value)))) { $missT += $m.Groups[1].Value } }
Check 'tests\run-all.ps1 lists no test that is missing' ($missT.Count -eq 0) ($missT -join ', ')
$unlisted = @(); foreach ($m in [regex]::Matches($ra, "f = '([^']+\.ps1)'")) { }
Check 'run-all.ps1 does not list the deleted tests' ($ra -notmatch "f = '(actions|bench|tv|tv-live-race)-test.ps1'")

"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
