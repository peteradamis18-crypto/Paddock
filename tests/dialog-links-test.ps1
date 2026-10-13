# iRacing's Test Drive window: START / GO / Leave-to-Home must recognise it whether its last link says Close or Back.
# (2026-10-10 iRacing's UI renamed Close to Back; Friends START stopped with "the Test Drive dialog is not showing".)
# Offline: only reads source files and compiles into a temp folder. Nothing touches the sim, iRacing's app or the screens.
#   powershell -ExecutionPolicy Bypass -File tests\dialog-links-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'tests\guard.ps1')
Assert-RigFree
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
$td = Get-Content "$root\src\testdrive.cs" -Raw; $ir = Get-Content "$root\src\irdeck.cs" -Raw; $ac = Get-Content "$root\src\actions.cs" -Raw
'Dialog links test'
Check 'testdrive.cs DialogOpen accepts a Back link as well as Close' ($td -match 'u\.Name == "Close" \|\| u\.Name == "Back"')
Check 'testdrive.cs layout menu skips the dialog''s own Back link' ($td -match 'u\.Name != "Close" && u\.Name != "Back"')
Check 'GO (irdeck.cs GoUi) accepts Close or Back' ($ir -match 'L\("Close", "Back"\), "hyperlink", false\) != null;\s*\r?\n\s*if \(dialog\)')
Check 'testdrive command (irdeck.cs) accepts Close or Back' ($ir -match '"Close", "Back" \}\), "hyperlink"')
Check 'Leave-to-Home sees the Test Drive window by Last settings + Back and presses Close or Back' ($ac -match 'Pick\(c, L\("Last settings"\), "hyperlink", false\) != null && Pick\(c, L\("Back"\), "hyperlink", false\) != null' -and $ac -match 'L\("Close", "Back"\), "hyperlink", true')
Check 'the results page is still told apart (Back + Event Log + Lap Graph) and checked before the window' ($ac.IndexOf('if (UiResultsOpen(c))') -ge 0 -and $ac.IndexOf('if (UiResultsOpen(c))') -lt $ac.IndexOf('if (UiDialogOpen(c))'))
Check 'the results modal counts even though iRacing reports its unselected tabs as not enabled (FindNamed ..., false)' ($ac -match 'FindNamed\(c, "Event Log", "TabItem", false\) != null && FindNamed\(c, "Lap Graph", "TabItem", false\)')
"$pass passed, $fail failed."
exit $(if ($fail) { 1 } else { 0 })
