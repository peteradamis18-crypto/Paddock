# restart-spotter-test.ps1 - RESTART finishes the job when the sim ignores the first Prev click, and the spotter is always on
# (2026-10-24 evening: two RESTARTs clicked Prev and the sim never asked "Restart Session?", so there was no second press;
# MUTE SPOTTER muted and unmuted itself, a press reaching irdeck twice 1 s apart). OFFLINE: reads the source. The live part
# (a real AI race restart, CrewChief muted then GET IN) is in the lead's live loop.
#   powershell -ExecutionPolicy Bypass -File tests\restart-spotter-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
function Body($src, $sig) { $i = $src.IndexOf($sig); if ($i -lt 0) { return '' }; $m = [regex]::Match($src.Substring($i + $sig.Length), "\r?\n        (static|// ----)"); if ($m.Success) { return $src.Substring($i, $sig.Length + $m.Index) }; return $src.Substring($i) }
$ir = [IO.File]::ReadAllText((Join-Path $root 'src\irdeck.cs'))

'1. RESTART when the first Prev click got no answer'
$rs = Body $ir 'static int CmdRestartRaceBody()'
$pn = Body $ir 'static int ClickPrevNext('
Check 'it waits 4 s for "Restart Session?" and clicks Prev again when the sim did not ask (up to 3 clicks)' ($rs -match 'int seen = ConfirmDialogs\(restarted, 4000' -and $rs -match 'for \(int k = 2; k <= 3 && seen == 0 && !restarted\(\); k\+\+\)')
Check 'the second click measures the bar from the screen''s fixed place' ($rs -match 'ClickPrevNext\(-1, "restartrace", k == 2\)' -and $pn -match 'if \(fixedPlace && green\) \{ s = LoadScale\(\)')
Check 'a click that brought up the question is never repeated (seen > 0 stops the loop)' ($rs -match 'seen == 0 &&')
Check 'a second question (which session) after the first is still answered' ($rs -match 'if \(seen > 0\) ConfirmDialogs\(restarted, 4000')
Check 'Prev / Next are clicked only while iRacing is in front, otherwise it says so' ($pn -match 'GetForegroundWindow\(\) != SimWindow\(\) && !FocusWindow\(SimWindow\(\)\)\) \{ Log\(tag \+ ": iRacing is not in front - not clicking"\); return 3; \}' -and $pn.IndexOf('iRacing is not in front') -lt $pn.IndexOf('Click(cx'))
Check 'the screen at every Prev / Next click is kept (last-restartrace-bar.png, last-skip-bar.png)' ($pn -match 'SaveSimArea\("last-" \+ tag \+ "-bar"\)')

''; '2. on/off keys ignore a press that arrives twice'
Check 'MUTE SPOTTER, the pit toggles and AC on/off ignore a second press within 1.5 s; other keys keep 0.12 s' ($ir -match 'a\[1\]\.Equals\("mute", StringComparison\.OrdinalIgnoreCase\)\) \|\| verb == "pittoggle"' -and $ir -match 'int gapMs = toggle \? 1500 : 120;')

''; '3. the spotter is on every time'
$es = Body $ir 'static void EnsureSpotter()'
Check 'every key that puts Peter in a session checks the spotter (GET IN, RESTART, RACE NOW, NEXT SESSION, LAST DRIVE, RESET CAR)' ($ir -match 'SpotterVerbs = \{ "smart", "go", "restartrace", "racenow", "skip", "mydrive", "startlast", "tow" \}' -and $ir -match 'Array\.IndexOf\(SpotterVerbs, a\[0\]\.ToLowerInvariant\(\)\) >= 0\) \{ string keep = LastLog; EnsureSpotter\(\); LastLog = keep; \}')
Check 'CrewChief not running: it is started' ($es -match 'GetProcessesByName\("CrewChiefV4"\)\.Length == 0' -and $es -match 'StartApp\("CrewChiefV4"')
Check 'CrewChief muted in the Windows mixer: sound back on' ($es -match 'AppMuteSet\("CrewChiefV4", false\)')
Check 'only during a session, and it never changes the top-screen message of the key itself' ($es -match 'if \(!SessionActive\(\)\) return;' -and $es -match 'Log\("\[spotter\]')
Check 'AppMuteSet only changes entries that differ, and reports how many' ((Body $ir 'static int AppMuteSet(') -match 'if \(m != mute\) \{ Guid g = Guid\.Empty; v\.SetMute\(mute, ref g\); changed\+\+; \}')
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
