# build-irdeck-test.ps1 - build-irdeck.ps1 updates EVERY key named in keys.map and says loudly which copy is still old (W0-1).
# It used to update only copies whose hash matched the old irdeck.exe: one busy copy never matched again and stayed old for ever.
# OFFLINE: a temp folder with a keys.map of 3 names and a pretend "new exe" (any file); the script's -KeysOnly step is run on it.
# Nothing in the real keys folder is touched.
#   1. none locked: all 3 copies become the new exe (also a name that had no exe yet, and one that was a different old exe), exit 0
#   2. one copy locked (opened without sharing for the whole run): it is named, the other 2 are new, exit code 3 (not 0)
#   powershell -ExecutionPolicy Bypass -File tests\build-irdeck-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Section($s) { Assert-RigFree -Where $s; $s }
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
$tmp = Join-Path $env:TEMP ('build-irdeck-test-' + $PID); $keys = Join-Path $tmp 'keys'; New-Item -ItemType Directory -Force $keys | Out-Null
$new = Join-Path $tmp 'new-irdeck.exe'; [IO.File]::WriteAllBytes($new, [Text.Encoding]::ASCII.GetBytes('NEW BUILD ' + [guid]::NewGuid()))
$want = (Get-FileHash $new).Hash
[IO.File]::WriteAllText((Join-Path $keys 'keys.map'), "get-out=getout`r`nvol-up=appvol game +5`r`n# a comment line`r`nghost=key --sim ctrl+c`r`n", (New-Object Text.UTF8Encoding $false))
function Reset { [IO.File]::WriteAllText((Join-Path $keys 'get-out.exe'), 'OLD A'); [IO.File]::WriteAllText((Join-Path $keys 'vol-up.exe'), 'OLD B, a copy that once was busy'); Remove-Item (Join-Path $keys 'ghost.exe') -ErrorAction SilentlyContinue }
function Step { $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build-irdeck.ps1') -KeysOnly -From $new -KeysDir $keys 2>&1 | ForEach-Object { "$_" }; [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join ' | ') } }
function IsNew($n) { $f = Join-Path $keys "$n.exe"; (Test-Path $f) -and (Get-FileHash $f).Hash -eq $want }

Section '1. nothing locked'
Reset
$r = Step
Check "exit 0 and it says 3 of 3 ($($r.out))" ($r.rc -eq 0 -and $r.out -match 'updated 3 of 3 key copies')
Check 'all 3 names are the new exe: one that differed from the old exe, one with no exe yet; the comment line is ignored' ((IsNew 'get-out') -and (IsNew 'vol-up') -and (IsNew 'ghost') -and -not (Test-Path (Join-Path $keys '# a comment line.exe')))

Section '2. one copy locked'
Reset
$lockFile = [IO.File]::Open((Join-Path $keys 'vol-up.exe'), 'Open', 'Read', 'None')   # like a key that is running: nobody can write it
$t0 = Get-Date
try { $r = Step } finally { $lockFile.Dispose() }
$secs = ((Get-Date) - $t0).TotalSeconds
Check "exit code is not 0 (got $($r.rc)) and the locked one is named ($($r.out))" ($r.rc -ne 0 -and $r.out -match 'STILL OLD.*vol-up' -and $r.out -match 'updated 2 of 3')
Check 'the other two are the new exe; the locked one kept its old bytes' ((IsNew 'get-out') -and (IsNew 'ghost') -and -not (IsNew 'vol-up'))
Check "a busy copy is tried again three times, a second apart (took $([math]::Round($secs, 1)) s)" ($secs -ge 3)
$r = Step
Check 'the next run (copy free again) brings it up to date: 3 of 3, exit 0' ($r.rc -eq 0 -and (IsNew 'vol-up'))

Section '3. the script'
$b = [IO.File]::ReadAllText((Join-Path $root 'build-irdeck.ps1'))
Check 'the deploy uses the same step on keys\ (no hash-of-the-old-exe filter left)' ($b -match 'Update-KeyCopies "\$r\\irdeck\.exe" "\$r\\keys"' -and $b -notmatch 'Hash -eq \$old')
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
