# hud-flag-test.ps1 - tools\hud-flag.ps1 changes only the one section, keeps a backup, and undoes cleanly.
# Offline: works on a temp copy, touches no iRacing file, safe while Peter races.
#   powershell -ExecutionPolicy Bypass -File tests\hud-flag-test.ps1
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }
$tool = Join-Path $root 'tools\hud-flag.ps1'
$dir = Join-Path $env:TEMP ('hudflag-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $dir | Out-Null
$f = Join-Path $dir 'Baseline.ini'
$orig = "`r`n[Drive]`r`nopacity=80`r`n`r`n[Drive_LastSectorReport]`r`nvisibility=0`r`n`r`n[Drive_PriorityMessageBox]`r`nx=13`r`ny=34`r`n`r`n[Drive_Relative]`r`nlayout=1`r`npinned=1`r`n"
[IO.File]::WriteAllText($f, $orig)
function Run($a) { & powershell -NoProfile -ExecutionPolicy Bypass -File $tool @a -File $f -NoSimCheck; $script:code = $LASTEXITCODE }
$null = Run @('-Off'); $t = [IO.File]::ReadAllText($f)
Check 'off: the message box is hidden' ($t -match '\[Drive_PriorityMessageBox\]\r\nvisibility=0\r\nx=13\r\ny=34')
Check 'off: nothing else changed' ($t.Replace("[Drive_PriorityMessageBox]`r`nvisibility=0`r`n", "[Drive_PriorityMessageBox]`r`n") -ceq $orig)
Check 'off: a backup of the old file is kept' (@(Get-ChildItem $dir -Filter '*.bak-flag-*').Count -eq 1 -and [IO.File]::ReadAllText((Get-ChildItem $dir -Filter '*.bak-flag-*')[0].FullName) -ceq $orig)
$out = Run @('-Off')
Check 'off twice: no second change, no second backup' ([IO.File]::ReadAllText($f) -ceq $t -and @(Get-ChildItem $dir -Filter '*.bak-flag-*').Count -eq 1) "$out"
Start-Sleep -Milliseconds 1100
$null = Run @('-On')
Check 'on: the file is back exactly as it was' ([IO.File]::ReadAllText($f) -ceq $orig)
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File $tool -On -File (Join-Path $dir 'missing.ini') -NoSimCheck
Check 'a missing file changes nothing' ($LASTEXITCODE -eq 1 -and "$out" -match 'not found')
$src = [IO.File]::ReadAllText($tool)
Check 'the real run refuses while the sim is running' ($src -match "Get-Process iRacingSim64DX11" -and $src -match 'exit 2')
Check 'the undo button exists' (Test-Path (Join-Path $root 'tools\digital-flag-back-on.cmd'))
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
