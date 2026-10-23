# ac-test.ps1 - the rig room's Midea AC: ac\ac.py (msmart-ng in tools\python), irdeck's `ac` command (src\ac.cs), the four
# MORE keys, auto-cool in irdash (dash\src\ac.cs) and the secret key file staying out of the public repo.
#   1. offline: the auto-cool rule and the °F/°C steps, run from ac.py itself
#   2. offline: ac.py and irdeck without a key say "not connected" and change nothing
#   3. offline: wiring (builds, command, irdash start, deck keys, .gitignore)
#   4. live, only once ac\ac.json exists (after "ac\Connect AC.cmd"): `ac status` reads the real AC. Read-only.
#   powershell -ExecutionPolicy Bypass -File tests\ac-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$py = Join-Path $root 'tools\python\python.exe'
$pass = 0; $fail = 0
function Section($s) { Assert-RigFree -Where $s; $s }
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }

Section '1. the auto-cool rule'
Check 'portable Python and msmart-ng are in tools\python' ((Test-Path $py) -and (Test-Path (Join-Path $root 'tools\python\Lib\site-packages\msmart\device\AC\device.py')))
$probe = @'
import runpy, sys
m = runpy.run_path(sys.argv[1])
d, f2c, c2f = m["auto_decision"], m["f2c"], m["c2f"]
s = dict(m["DEFAULTS"])
cases = [
 ("warm room, AC off -> on",               d(False, False, 77, s, False), "on"),
 ("exactly 76 F -> on",                    d(False, False, 76, s, False), "on"),
 ("75 F, AC off -> leave it",              d(False, False, 75, s, False), None),
 ("cool room, auto turned it on -> off",   d(True, True, 72, s, False), "off"),
 ("cool room, Peter turned it on -> leave",d(True, False, 70, s, False), None),
 ("warm room, already on -> leave",        d(True, True, 80, s, False), None),
 ("paused after a manual OFF -> leave",    d(False, False, 85, s, True), None),
 ("no room reading -> leave",              d(False, False, None, s, False), None),
 ("auto switched off -> leave",            d(False, False, 85, dict(s, auto=False), False), None),
 ("70 F is 21.0 C", f2c(70), 21.0),
 ("76 F is 24.5 C (nearest half degree)", f2c(76), 24.5),
 ("21 C shows as 70 F", c2f(21.0), 70),
 ("no reading shows as nothing", c2f(None), None),
]
for name, got, want in cases:
    print(("ok " if got == want else "FAIL ") + name + ("" if got == want else " (got %r)" % (got,)))
'@
$pf = Join-Path $env:TEMP ('ac-probe-' + $PID + '.py'); [IO.File]::WriteAllText($pf, $probe)
$out = & $py -I -X utf8 $pf (Join-Path $root 'ac\ac.py') 2>&1 | ForEach-Object { "$_" }
Remove-Item $pf -ErrorAction SilentlyContinue
foreach ($l in $out) { if ($l -match '^ok (.+)') { Check $Matches[1] $true } elseif ($l -match '^FAIL (.+)') { Check $Matches[1] $false } else { Check "probe line: $l" $false } }

Section '2. without a key nothing is touched'
$tmp = Join-Path $env:TEMP ('ac-nokey-' + $PID); New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item (Join-Path $root 'ac\ac.py') $tmp
$o = & $py -I -X utf8 (Join-Path $tmp 'ac.py') on 2>&1 | ForEach-Object { "$_" }
Check 'ac.py with no ac.json says so and exits 2 (no AC traffic)' ($LASTEXITCODE -eq 2 -and ($o -join ' ') -match 'not connected yet') ($o -join ' ')
Check 'and writes no state file' (-not (Test-Path (Join-Path $tmp 'state.json')))
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
$cli = Join-Path $root 'irdeck-cli.exe'
$null = & $cli ac bogus 2>&1; Check 'irdeck ac with an unknown word refuses (exit 1)' ($LASTEXITCODE -eq 1)

Section '3. wiring'
$bi = [IO.File]::ReadAllText((Join-Path $root 'build-irdeck.ps1')); $ir = [IO.File]::ReadAllText((Join-Path $root 'src\irdeck.cs'))
$db = [IO.File]::ReadAllText((Join-Path $root 'dash\build.ps1')); $id = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
$bd = [IO.File]::ReadAllText((Join-Path $root 'build-deck.ps1')); $gi = [IO.File]::ReadAllText((Join-Path $root '.gitignore'))
$acs = [IO.File]::ReadAllText((Join-Path $root 'src\ac.cs')); $dac = [IO.File]::ReadAllText((Join-Path $root 'dash\src\ac.cs'))
Check 'irdeck builds src\ac.cs and has the ac command' ($bi -match 'src\\ac\.cs' -and $ir -match 'case "ac": return CmdAc')
Check 'irdeck waits at most 20 s for the AC and never blocks on its output' ($acs -match 'WaitForExit\(20000\)' -and $acs -match 'BeginOutputReadLine' -and $acs -notmatch 'ReadToEnd')
Check 'SLEEP PC / SHUT DOWN PC stop the cooling auto-cool started' ($ir -match '"pcoff"')
Check 'irdash builds dash\src\ac.cs and starts auto-cool' ($db -match 'src\\ac\.cs' -and $id -match 'AcAuto\.Init\(RootDir\); AcAuto\.Start\(\)')
Check 'auto-cool runs every 2 min, BelowNormal, idle until the AC is connected' ($dac -match 'EveryMs = 120000' -and $dac -match 'BelowNormal' -and $dac -match 'ac\\ac\.json')
Check 'MORE has AC, AC COOLER, AC WARMER, AC FAN' ($bd -match "'ac toggle'" -and $bd -match "'ac cooler'" -and $bd -match "'ac warmer'" -and $bd -match "'ac fan'")
Check 'the AC key file and portable Python are kept out of the public repo' ($gi -match '(?m)^/ac/ac\.json' -and $gi -match '(?m)^/tools/python/')
$git = 'C:\Users\peter\AppData\Local\grok\git\2.55.0.windows.5\cmd\git.exe'
if (Test-Path $git) { $tracked = & $git -C $root ls-files ac/ac.json tools/python; Check 'git tracks neither' ([string]::IsNullOrEmpty(($tracked -join ''))) ($tracked -join ', ') }
Check 'Connect AC.cmd asks for the email itself and never stores it' ([IO.File]::ReadAllText((Join-Path $root 'ac\Connect AC.cmd')) -match 'set ACMAIL=\s*\r?\n')

Section '4. live (read-only)'
if (-not (Test-Path (Join-Path $root 'ac\ac.json'))) { '  (skipped: the AC is not connected yet - run ac\Connect AC.cmd)' }
else {
  $o = & $py -I -X utf8 (Join-Path $root 'ac\ac.py') status 2>&1 | ForEach-Object { "$_" }
  $last = $o[-1]
  Check 'the real AC answers status with its state and the room temperature' ($LASTEXITCODE -eq 0 -and $last -match '^AC (on|off)' -and $last -match 'room \d+°F') $last
  Check 'state.json written for the top screen' ((Get-Item (Join-Path $root 'ac\state.json')).LastWriteTime -gt (Get-Date).AddMinutes(-1))
}
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
