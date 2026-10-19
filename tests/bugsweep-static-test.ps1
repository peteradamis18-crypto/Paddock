# Static (source-reading) checks for the 2026-10-18 bug sweep. Reads files only: no irdash, no sim, no rig, so it is safe while Peter races
# (that is why it does not call Assert-RigFree). Each check failed on the code before the fixes.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:ok = 0; $script:fail = 0
function Check($name, $cond) { if ($cond) { $script:ok++; Write-Output "  ok    $name" } else { $script:fail++; Write-Output "  FAIL  $name" } }
$app = Get-Content -Raw (Join-Path $root 'dash\www\phone\app.js')
$phone = Get-Content -Raw (Join-Path $root 'dash\src\phone.cs')
$vault = Get-Content -Raw (Join-Path $root 'dash\src\vault.cs')
$irdash = Get-Content -Raw (Join-Path $root 'dash\src\irdash.cs')

Write-Output 'phone app'
# Phone.Hidden() 404s every non-GET from a phone, so a POST from app.js can never work
Check 'phone.cs hides non-GET requests from phones' ($phone -match 'method != "GET"')
Check 'app.js sends no POST' ($app -notmatch "method:\s*'POST'")
Check 'app.js shows times in 12-hour America/New_York' ($app -match "America/New_York" -and $app -match 'hour12:\s*true' -and $app -notmatch "en-GB")
Check 'app.js requests time out (a sleeping phone must not freeze the poll)' ($app -match 'AbortController')
Check 'a failed debrief is a message, not a blank page' ($app -notmatch "if \(d\.failed\) return '';")
# every route the phone JS calls exists in the C# (path only)
$paths = [regex]::Matches($app, "['""](/(?:phone|api|share|vault|debrief|analysis|sessions|overlays|replay|sound|mydrive)[A-Za-z0-9/_-]*)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$src = (Get-ChildItem (Join-Path $root 'dash\src') -Filter *.cs | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
foreach ($p in $paths) { if ($p -in '/phone/','/api/do') { continue }; Check "route exists: $p" ($src.Contains('"' + $p + '"') -or $src.Contains('"' + $p)) }

Write-Output 'Pi Toolbox open'
Check 'vault.cs lets only one Pi launch run at a time' ($vault -match 'static volatile bool cwOpening' -and $vault -match 'if \(cwOpening\)')
Check 'a missing Pi template is an error the button can show' ($vault -match 'code = 424')
foreach ($f in 'workbench.js','sessionreview.js','debrief.js','debrief-v4.js') {
  $t = Get-Content -Raw (Join-Path $root "dash\www\v2\$f")
  Check "$f shows why OPEN IN COSWORTH failed" ($t -match 'NOT WHILE DRIVING' -and $t -match '_busy')
}

Write-Output 'start-up'
Check 'opening the dashboard stamps lastAutoOpen (no second window from KeepDash)' ($irdash -match '(?s)Process\.Start\(exe, args\);\s*//[^\r\n]*\r?\n\s*//[^\r\n]*\r?\n\s*//?[^\r\n]*\r?\n?\s*lastAutoOpen = DateTime\.Now' -or $irdash -match '(?s)Process\.Start\(exe, args\);.{0,400}lastAutoOpen = DateTime\.Now')
Check 'irdash waits for a busy port instead of giving up at once' ($irdash -match 'attempt < 20')
Check 'the dashboard is never put on a race screen when the dashboard monitor is missing' ($irdash -match 'static bool DashScreenFound')
Write-Output ''
Write-Output ("{0} ok, {1} FAIL" -f $script:ok, $script:fail)
if ($script:fail -gt 0) { exit 1 }
