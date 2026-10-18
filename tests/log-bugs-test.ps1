# Fixes from the 2026-10-18 log review. Source checks only (no sim, no screens, no irdash call), so it is safe at any time.
#   1. a web path with a colon ("/v2/a:b") must be a 404, not an unanswered request plus "http: The given path's format is not supported."
#   2. the phone pairing code is cancelled after a few wrong tries (6 digits could be guessed by anything on the home network)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree -Where 'log-bugs source checks'
$root = Split-Path -Parent $PSScriptRoot
$script:ok = 0; $script:fail = 0
function Check($name, $cond) { if ($cond) { $script:ok++; Write-Output "  ok    $name" } else { $script:fail++; Write-Output "  FAIL  $name" } }

$srv = Get-Content (Join-Path $root 'dash\src\irdash.cs') -Raw
Check 'static file path: GetFullPath is guarded (NotSupportedException -> 404)' ($srv -match 'try \{ full = Path\.GetFullPath\(Path\.Combine\(www, rel\)\); \}\s*catch \(ArgumentException\)[^\r\n]*404[^\r\n]*\s*catch \(NotSupportedException\)[^\r\n]*404')

$ph = Get-Content (Join-Path $root 'dash\src\phone.cs') -Raw
Check 'phone: wrong tries are counted' ($ph -match '\+\+codeFails >= MaxCodeFails')
Check 'phone: the cancelled code is not reusable (code = null)' ($ph -match 'MaxCodeFails\) \{ code = null;')
Check 'phone: a fresh code starts with zero wrong tries' ($ph -match 'codeUsed = false; codeUses = 0; codeFails = 0;')
Check 'phone: at most 10 wrong tries per code' ($ph -match 'const int MaxCodeFails = (\d|10);')

Write-Output ''; Write-Output "$script:ok ok, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
