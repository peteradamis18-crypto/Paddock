 . (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$pass = 0; $fail = 0
function Section([string]$name) { Assert-RigFree -Where $name; "Section $name" }
function Check([string]$name, [bool]$good) { if ($good) { $script:pass++; "  ok    $name" } else { $script:fail++; "  FAIL  $name" } }
$assemblyPath = Join-Path $env:TEMP 'ird\irdeck-cli.exe'
if (-not (Test-Path $assemblyPath)) { throw 'Build irdeck with -NoDeploy before airace-test.' }
$assembly = [Reflection.Assembly]::LoadFrom($assemblyPath)
$program = $assembly.GetType('IRDeck.Program', $true)
function Prod([string]$name, [object[]]$invokeArgs) { $method = $program.GetMethod($name, [Reflection.BindingFlags]'NonPublic,Static'); return $method.Invoke($null, $invokeArgs) }

Section '1. fixture dumps identify only the wizard subtree'
$base = Join-Path $PSScriptRoot '..\docs\research\ai-newrace-elements-090429'
$main = Get-Content ($base + '.txt')
$car = Get-Content ($base + '-car.txt')
$track = Get-Content ($base + '-track.txt')
$ai = Get-Content ($base + '-ai.txt')
Check 'main dump contains wizard id plus sidebar endpoints' (Prod 'AiFixtureWizard' @($main -join "`n"))
Check 'car dump has wizard structure' (Prod 'AiFixtureWizard' @($car -join "`n"))
Check 'track dump has wizard structure' (Prod 'AiFixtureWizard' @($track -join "`n"))
Check 'AI dump has wizard structure' (Prod 'AiFixtureWizard' @($ai -join "`n"))
$continueTrack = New-Object object[] 2; $continueTrack[0] = $track -join "`n"; $continueTrack[1] = $true
$continueAi = New-Object object[] 2; $continueAi[0] = $ai -join "`n"; $continueAi[1] = $true
$continueOutside = New-Object object[] 2; $continueOutside[0] = $main -join "`n"; $continueOutside[1] = $false
Check 'Continue exists inside modal fixtures' ((Prod 'AiFixtureContinue' $continueTrack) -and (Prod 'AiFixtureContinue' $continueAi))
Check 'Continue is rejected outside modal' (-not (Prod 'AiFixtureContinue' $continueOutside))

Section '2. modal matching ignores background cards'
Check 'background element cannot match a modal element' (-not (Prod 'AiCandidateMatches' @('background','modal','DataItem','Hyperlink','Race Sessions','Race Sessions')))
Check 'wizard element in modal matches' (Prod 'AiCandidateMatches' @('modal','modal','Hyperlink','Hyperlink','Race Sessions','Race Sessions'))
Check 'modal lookup requires wizard list and both sidebar endpoints' (Prod 'AiFixtureWizard' @($main -join "`n"))

Section '3. New Race allowlist is start-only and Continue is start-only'
$script:dummy = $false
Check 'New Race blocked by default' (-not (Prod 'AiPressAllowed' @('','New Race')))
Check 'Continue blocked by default' (-not (Prod 'AiPressAllowed' @('','Continue')))
$field = $program.GetField('aiAllowNew', [Reflection.BindingFlags]'NonPublic,Static'); $field.SetValue($null,$true)
Check 'New Race enabled on start path' (Prod 'AiPressAllowed' @('','New Race'))
$field.SetValue($null,$false)
$field = $program.GetField('aiAllowContinue', [Reflection.BindingFlags]'NonPublic,Static'); $field.SetValue($null,$true)
Check 'Continue enabled on start path' (Prod 'AiPressAllowed' @('','Continue'))
$field.SetValue($null,$false)
$layoutField = $program.GetField('aiLayoutName', [Reflection.BindingFlags]'NonPublic,Static'); $layoutField.SetValue($null,'Full Course')
$layoutFlag = $program.GetField('aiAllowLayout', [Reflection.BindingFlags]'NonPublic,Static'); $layoutFlag.SetValue($null,$true)
Check 'chosen layout enabled only for exact requested layout' (Prod 'AiPressAllowed' @('','Full Course'))
Check 'other layout remains blocked' (-not (Prod 'AiPressAllowed' @('','Grand Prix')))
$layoutFlag.SetValue($null,$false); $layoutField.SetValue($null,'')
Check 'New Race remains blocked after start path' (-not (Prod 'AiPressAllowed' @('','New Race')))

Section '4. mismatch statuses are exact deck reasons'
Check 'missing car reason' ((Prod 'AiMismatch' @($false,$true)) -eq 'CAR NOT FOUND')
Check 'missing track reason' ((Prod 'AiMismatch' @($true,$false)) -eq 'TRACK NOT FOUND')
Check 'both found has no mismatch' ((Prod 'AiMismatch' @($true,$true)) -eq '')

Section '5. command path and compatibility alias'
$source = Get-Content (Join-Path $PSScriptRoot '..\src\irdeck.cs') -Raw
$drive = Get-Content (Join-Path $PSScriptRoot '..\src\testdrive.cs') -Raw
Check 'airace start reaches race starter' ($drive.Contains('if (op == "start") return CmdAiraceStart(dry);'))
Check 'startlast ai remains an alias' ($source.Contains('CmdAiRace(new string[] { "start" })'))
Check 'chooser permits New Race only when start toggles its allow flag' ($drive.Contains('aiAllowNew = true; bool opened = AiPress(fresh); aiAllowNew = false;'))

Section '6. live UI (lead only)'
'  live: lead runs airace start with Assert-RigFree -NeedAway; this test performs no clicks'
"SUMMARY: $pass ok, $fail FAIL"
if ($fail) { exit 1 }
