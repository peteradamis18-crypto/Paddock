# One-press deck keys (2026-10-23): GET IN from any state, GET OUT waits for the car, RESTART in one press, NEXT SESSION / RACE NOW,
# the chat repeat guard, OFFICIAL as a hyperlink, the damage-switch fallback and kids mode that works while the sim runs.
# Offline: it compiles src\deckrules.cs on its own and runs every rule, reads the source for what the keys must do, and runs the
# irdeck CLI only in forms that cannot touch the sim (no session -> refusals, --dry, --fake). No clicks, no keys, no sim.
#   powershell -ExecutionPolicy Bypass -File tests\deck-behaviour-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$pass = 0; $fail = 0
function Section($s) { Assert-RigFree -Where $s; Write-Host $s }
function Check($n, $yes, $why) { if ($yes) { $script:pass++; Write-Host "  ok    $n" } else { $script:fail++; Write-Host "  FAIL  $n$(if ($why) { ' -> ' + $why })" } }
function Src($p) { [IO.File]::ReadAllText((Join-Path $root $p)) }
function Body($src, $sig) {   # from a method signature to the next 8-space-indented member
  $i = $src.IndexOf($sig); if ($i -lt 0) { return '' }
  $m = [regex]::Match($src.Substring($i + $sig.Length), "\r?\n        (static|// ----|const)")
  if ($m.Success) { return $src.Substring($i, $sig.Length + $m.Index) }
  return $src.Substring($i)
}
$ir = Src 'src\irdeck.cs'; $kids = Src 'src\kids.cs'; $td = Src 'src\testdrive.cs'; $rules = Src 'src\deckrules.cs'

# ---------------------------------------------------------------- 1. the rules, compiled and run
Section '1. the pure rules (src\deckrules.cs compiled on its own)'
$tmp = Join-Path $env:TEMP ('deck-behaviour-' + $PID)
New-Item -ItemType Directory -Force $tmp | Out-Null
$driver = Join-Path $tmp 'driver.cs'; $exe = Join-Path $tmp 'driver.exe'
@'
using System;
using System.Globalization;
using IRDeck;
class Driver {
  static bool B(string s) { return s == "1" || s == "true"; }
  static string S(string s) { return s == "<empty>" ? "" : s; }
  static void Main(string[] a) {
    CultureInfo c = CultureInfo.InvariantCulture;
    switch (a[0]) {
      case "plan": Console.WriteLine(DeckRules.GetInPlan(B(a[1]), B(a[2]), B(a[3]), B(a[4]), B(a[5]))); break;
      case "stop": Console.WriteLine(DeckRules.StopWait(B(a[1]), double.Parse(a[2], c), int.Parse(a[3]), int.Parse(a[4]))); break;
      case "kids": { string[] w = new string[a.Length - 1]; Array.Copy(a, 1, w, 0, w.Length); Console.WriteLine(DeckRules.KidsAllows(w)); break; }
      case "hook": Console.WriteLine(DeckRules.HookPasses(uint.Parse(a[1], c), B(a[2]), B(a[3]))); break;
      case "chat": Console.WriteLine(DeckRules.ChatIsRepeat(S(a[1]).Replace("<T>", "\t"), a[2], long.Parse(a[3], c), int.Parse(a[4]))); break;
      case "stamp": Console.WriteLine(DeckRules.ChatStamp(a[1], long.Parse(a[2], c)).Replace("\t", "<T>")); break;
      case "next": Console.WriteLine(DeckRules.SecondNextDue(B(a[1]), int.Parse(a[2]), int.Parse(a[3]), B(a[4]), a.Length > 5 ? int.Parse(a[5]) : 1)); break;
      case "qual": Console.WriteLine(DeckRules.IsQualify(a[1])); break;
      case "race": Console.WriteLine(DeckRules.IsRaceType(S(a[1]))); break;
      case "ahead": Console.WriteLine(DeckRules.RaceAhead(S(a[1]).Length == 0 ? new string[0] : a[1].Split('|'), int.Parse(a[2]))); break;
      case "totherace": Console.WriteLine(DeckRules.ToTheRacePlan(B(a[1]), B(a[2]), a.Length > 3 && B(a[3]))); break;
    }
  }
}
'@ | Set-Content -LiteralPath $driver -Encoding ASCII
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" -nologo -target:exe "-out:$exe" (Join-Path $root 'src\deckrules.cs') $driver
if ($LASTEXITCODE -ne 0) { throw 'could not compile src\deckrules.cs standalone' }
function Rule { (& $exe @args | Out-String).Trim() }

# GET IN plan: ui, simProcess, session, onTrack, startedRecently
Check 'GET IN: in the car -> already' ((Rule plan 1 1 1 1 0) -eq 'already')
Check 'GET IN: session screen, car not on track -> go (press Drive)' ((Rule plan 1 1 1 0 0) -eq 'go')
Check 'GET IN: a session with a replay behind it is still go (the replay no longer says WAIT)' ((Rule plan 1 1 1 0 0) -eq 'go')
Check 'GET IN: no sim at all, UI open -> start the last drive' ((Rule plan 1 0 0 0 0) -eq 'start')
Check 'GET IN: sim preloaded silently (process, no session, no recent start) -> start' ((Rule plan 1 1 0 0 0) -eq 'start')
Check 'GET IN: sim loading after a start a moment ago -> wait-load, never a second start' ((Rule plan 1 1 0 0 1) -eq 'wait-load')
Check 'GET IN: iRacing app not open -> open it first' ((Rule plan 0 0 0 0 0) -eq 'open-then-start')
Check 'GET IN: recent start mark but no sim process does not wait' ((Rule plan 1 0 0 0 1) -eq 'start')

# waiting for a rolling car: inCar, speed, elapsedMs, limitMs
Check 'GET OUT wait: stopped car -> go on' ((Rule stop 1 0.4 0 15000) -eq '0')
Check 'GET OUT wait: exactly 1 m/s counts as stopped' ((Rule stop 1 1.0 0 15000) -eq '0')
Check 'GET OUT wait: rolling at 12 m/s -> keep waiting' ((Rule stop 1 12 3000 15000) -eq '1')
Check 'GET OUT wait: still rolling at 15 s -> time is up (refusal)' ((Rule stop 1 5 15000 15000) -eq '2')
Check 'GET OUT wait: out of the car already -> go on whatever the speed' ((Rule stop 0 30 0 15000) -eq '0')

# kids allow-list
$allowed = @(@('smart'), @('tow'), @('restartrace'), @('kids'), @('kids', 'off'), @('appvol', 'game', '-5'), @('appvol', 'game', '+5'), @('appvol', 'game', '-10'), @('appvol', 'game', '+10'))
$blocked = @(@('state'), @('getout'), @('confirm', 'restart-race', 'restartrace'), @('confirm', 'quit-main', 'quitmain'), @('confirm', 'sleep', 'power', 'sleep'), @('key', '--sim', 'f1'), @('chat', 'say', 'GG'), @('appvol', 'game', '+25'), @('appvol', 'music', '+10'),
             @('media', 'mute'), @('skip'), @('rigon'), @('startlast', 'td'), @('mydrive', 'start'), @('confirm', 'restart-race', 'quitmain'), @('confirm', 'restart-race'), @('power', 'off'))
foreach ($k in $allowed) { Check "kids lock lets '$($k -join ' ')' through" ((Rule kids @k) -eq 'True') }
foreach ($k in $blocked) { Check "kids lock still blocks '$($k -join ' ')'" ((Rule kids @k) -eq 'False') }

# injected-input test of the hooks (KBDLLHOOKSTRUCT.flags & 0x10, MSLLHOOKSTRUCT.flags & 0x01)
Check 'keyboard hook: injected key (flags 0x10) passes' ((Rule hook 16 0 0) -eq 'True')
Check 'keyboard hook: injected + lower-integrity (0x12) passes' ((Rule hook 18 0 0) -eq 'True')
Check 'keyboard hook: real key (flags 0) is swallowed' ((Rule hook 0 0 0) -eq 'False')
Check 'keyboard hook: extended-key bit alone (0x01) is not "injected"' ((Rule hook 1 0 0) -eq 'False')
Check 'mouse hook: injected click (flags 0x01) passes' ((Rule hook 1 1 0) -eq 'True')
Check 'mouse hook: real mouse (flags 0) is swallowed' ((Rule hook 0 1 0) -eq 'False')
Check 'mouse hook: the keyboard injected bit (0x10) is not the mouse one' ((Rule hook 16 1 0) -eq 'False')
Check 'test switch: injected input is swallowed too when asked' ((Rule hook 16 0 1) -eq 'False' -and (Rule hook 1 1 1) -eq 'False')

# chat repeat guard: ticks are 100 ns; 3 s = 30,000,000
$t0 = 639000000000000000
$stamp = Rule stamp '  Thanks! ' $t0
Check 'chat stamp is ticks, a tab and the lower-case trimmed text' ($stamp -eq "$t0<T>thanks!")
Check 'chat: the same text 0.96 s later is a repeat (THANKS sent twice)' ((Rule chat $stamp 'Thanks!' ($t0 + 9600000) 3000) -eq 'True')
Check 'chat: the same text in other letters/spacing is the same message' ((Rule chat $stamp ' THANKS! ' ($t0 + 9600000) 3000) -eq 'True')
Check 'chat: 2.9 s later is still a repeat' ((Rule chat $stamp 'Thanks!' ($t0 + 29000000) 3000) -eq 'True')
Check 'chat: 3.0 s later is a new message' ((Rule chat $stamp 'Thanks!' ($t0 + 30000000) 3000) -eq 'False')
Check 'chat: a different message right away goes out' ((Rule chat $stamp 'GG' ($t0 + 1000000) 3000) -eq 'False')
Check 'chat: no stamp yet goes out' ((Rule chat '<empty>' 'GG' $t0 3000) -eq 'False')
Check 'chat: a stamp from the future (clock change) does not block' ((Rule chat $stamp 'Thanks!' ($t0 - 5000000) 3000) -eq 'False')

# NEXT SESSION second click: qualify, clicks, ms since click, advanced
Check 'NEXT: AI Qualify, one click, nothing moved after 10 s -> click again' ((Rule next 1 1 10000 0) -eq 'True')
Check 'NEXT: not yet 10 s -> wait' ((Rule next 1 1 9000 0) -eq 'False')
Check 'NEXT: already advanced -> no second click' ((Rule next 1 1 12000 1) -eq 'False')
Check 'NEXT: only one extra click, never a third' ((Rule next 1 2 30000 0) -eq 'False')
Check 'NEXT: practice is not retried when the sim did ask (a question was answered)' ((Rule next 0 1 30000 0 1) -eq 'False')
Check 'NEXT: a click that never brought up the sim''s question is repeated after 6 s, in any session type' ((Rule next 0 1 6000 0 0) -eq 'True' -and (Rule next 1 1 6000 0 0) -eq 'True')
Check 'NEXT: ... but not before 6 s, not after it advanced, and never a fourth click' ((Rule next 0 1 5000 0 0) -eq 'False' -and (Rule next 0 1 9000 1 0) -eq 'False' -and (Rule next 0 3 30000 0 0) -eq 'False')
Check 'qualify names: Open Qualify / Lone Qualify / Qualify' ((Rule qual 'Open Qualify') -eq 'True' -and (Rule qual 'Lone Qualify') -eq 'True' -and (Rule qual 'Qualify') -eq 'True')
Check 'qualify names: Practice and Race are not' ((Rule qual 'Practice') -eq 'False' -and (Rule qual 'Race') -eq 'False')
Check 'RACE NOW: Race is the race; Practice, Open Qualify, Warmup are not' ((Rule race 'Race') -eq 'True' -and (Rule race ' race ') -eq 'True' -and (Rule race 'Practice') -eq 'False' -and (Rule race 'Open Qualify') -eq 'False' -and (Rule race 'Warmup') -eq 'False' -and (Rule race '<empty>') -eq 'False')
# TO THE RACE (W3-4): NEXT SESSION and RACE NOW on one key
Check 'TO THE RACE: an AI weekend in practice with its race still to come -> race now' ((Rule ahead '0:Practice|1:Qualify|2:Race' 0) -eq 'True' -and (Rule totherace 1 1) -eq 'racenow')
Check 'TO THE RACE: already in the race session -> race now (it only gets him in the car)' ((Rule ahead '0:Practice|1:Race' 1) -eq 'True')
Check 'TO THE RACE: the race is over (a session after it is on) -> no race ahead -> next session' ((Rule ahead '0:Practice|1:Race|2:Heat' 2) -eq 'False' -and (Rule totherace 1 0) -eq 'skip')
Check 'TO THE RACE: a Test Drive (no race in the event) -> refused (none): one green press must not quit the drive (W3-4 review)' ((Rule ahead '0:Testing' 0) -eq 'False' -and (Rule totherace 0 0 1) -eq 'none')
Check 'TO THE RACE: an AI race weekend is never treated as a Test Drive' ((Rule totherace 1 1 1) -eq 'racenow')
Check 'TO THE RACE: an official race is not an AI weekend -> next session, which refuses it in plain words' ((Rule totherace 0 1) -eq 'skip')
Check 'TO THE RACE: no session list at all -> next session' ((Rule ahead '<empty>' 0) -eq 'False')
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- 2. the source does what the rules say
Section '2. GET IN (smart)'
$smart = Body $ir 'static int CmdSmart(string[] args)'
$getIn = Body $ir 'static int SmartGetIn()'
$plan = Body $ir 'static string SmartPlan()'
Check 'smart real path does not use the deck-face resolver (a replay can no longer say WAIT)' ($smart -notmatch 'CurrentDeckState|CurrentDeckSnapshot|DeckStateResolver' -and $getIn -notmatch 'CurrentDeckState|CurrentDeckSnapshot|DeckStateResolver|\.Replay' -and $plan -notmatch 'Replay|CurrentDeckState')
Check 'smart plan comes from DeckRules.GetInPlan with the sim process, session and on-track facts' ($plan -match 'DeckRules\.GetInPlan\(ui, simProc, session' -and $plan -match 'SessionActive\(\)' -and $plan -match 'OnTrack\(\)')
Check 'smart: already in the car -> logs and returns 0' ($getIn -match 'if \(plan == "already"\) \{ Log\("smart: already in the car"\); return 0; \}')
Check 'smart: a session on any screen -> CmdGo (presses the sim''s green button until on track)' ($getIn -match 'plan == "go"' -and $getIn -match 'CmdGo\(\)')
Check 'smart: no session -> MY DRIVE start (mydrive start) with the chosen car and track, else startlast td' ($getIn -match 'MdStart\(new string\[\] \{ "start" \}\)' -and $getIn -match 'CmdStartLast\(new string\[\] \{ "td" \}\)' -and $getIn -match 'c\.Car\.Length > 0 && c\.Track\.Length > 0')
Check 'smart: waits for a session that is already loading instead of starting twice' ($getIn -match 'plan == "wait-load"' -and $getIn -match 'SessionActive\(\)')
Check 'smart: iRacing app closed -> RIG ON first' ($getIn -match 'plan == "open-then-start"' -and $getIn -match 'CmdRigOn\(new string\[0\]\)')
Check 'the dead deck paths are gone (W0-1): no smart --fake, no deck-face resolver, no CmdConfirm / ConfirmArmedFresh, no GoDriveOnly' ($ir -notmatch 'SmartFake|DeckStateResolver|CmdConfirm|ConfirmArmedFresh|GoDriveOnly|CurrentDeckSnapshot' -and (Src 'src\deckstate.cs') -notmatch 'DeckStateResolver')
Check 'smart runs one at a time (a doubled press finds the lock taken)' ($smart -match 'WithNamedLock\("Local\\\\irdeck-getin"')
Check 'smart never arms a confirm and has no moving-car refusal that could block a GET IN' ($smart + $getIn -notmatch 'CmdConfirm|GoDriveOnly')

Section '3. GET OUT, RESTART, NEXT SESSION, RACE NOW'
$out = Body $ir 'static int CmdGetOut()'
Check 'GET OUT waits for a rolling car (15 s) instead of refusing at once, logs it, then holds Esc' ($out -match 'WaitCarStopped\("getout", DeckRules\.StopWaitMs' -and $out -match 'SendCombo\("esc", 1800\)' -and $out.IndexOf('WaitCarStopped') -lt $out.IndexOf('SendCombo'))
Check 'GET OUT: a car that does not stop in 15 s gets a plain refusal (rc 3)' ($out -match 'getout refused: the car is still moving' -and $out -match 'slow down and press again')
$wait = Body $ir 'static int WaitCarStopped('
Check 'the wait polls every 200 ms, logs "waiting for the car to stop", shows the top-screen line, uses DeckRules.StopWait' ($wait -match 'Thread\.Sleep\(200\)' -and $wait -match 'waiting for the car to stop' -and $wait -match 'TowWaitFlag\(true\)' -and $wait -match 'DeckRules\.StopWait\(' -and $wait -match 'finally \{ TowWaitFlag\(false\)')
Check 'the stop limit is 15 s' ($rules -match 'StopWaitMs = 15000')
$rr = Body $ir 'static int CmdRestartRaceBody()'
Check 'restartrace is one-at-a-time and the doubled press is dropped' ((Body $ir 'static int CmdRestartRace()') -match 'WithNamedLock\("Local\\\\irdeck-restartrace"')
Check 'restartrace with no session says so in plain words (rc 3)' ($rr -match '!SessionActive\(\)\) \{ Log\("restartrace: no session is running')
Check 'restartrace, Test Drive: tow (waits for a rolling car), then makes sure he is in the car' ($rr -match 'EventType:\\s\*Test' -and $rr -match 'CmdTow\(\)' -and $rr -match 'trc = CmdGo\(\)' -and $rr -match 'restart: test drive - back in the car in the pits')
Check 'restartrace, AI race: waits for a rolling car, Prev + confirm dialogs, waits for the start over, then CmdGo and logs "restart: back in the car"' ($rr -match 'WaitCarStopped\("restartrace"' -and $rr -match 'ClickPrevNext\(-1, "restartrace"\)' -and $rr -match 'ConfirmDialogs\(restarted' -and $rr -match 'rc = CmdGo\(\)' -and $rr -match 'restart: back in the car')
Check 'restartrace falls back to the whole relaunch (CmdRestart) when Prev is not measured, and still ends in the car' ($rr -match 'rc = CmdRestart\(new string\[0\]\)' -and (Body $ir 'static int CmdRestart(string[] a)') -match 'return CmdGo\(\)')
$pn = Body $ir 'static int ClickPrevNext('
Check 'the session-bar click waits for a rolling car (GET OUT rule) instead of refusing at once' ($pn -match 'WaitCarStopped\(tag' -and $pn -notmatch 'refused: the car is moving')
$sk = Body $ir 'static int CmdSkip()'
Check 'NEXT SESSION in an AI Qualify: a second Next after 10 s, then up to 40 s; logs which Next did it' ($sk -match 'DeckRules\.IsQualify\(s0\.Type\)' -and $sk -match 'DeckRules\.SecondNextDue\(qualify, clicks' -and $sk -match 'clicking Next once more' -and $sk -match 'AddSeconds\(40\)' -and $sk -match 'the second Next did it' -and $sk -match 'the first Next did it')
Check 'NEXT SESSION in a Test Drive is unchanged (ends it like QUIT)' ($sk -match 'testSession && !s0\.Ai' -and $sk -match 'return CmdQuitMain\(\)')
Check 'NEXT SESSION still refuses official sessions, and waits for a rolling car instead of refusing it' ($sk -match 'official sessions cannot be skipped' -and $sk -match 'WaitCarStopped\("skip"' -and $sk -notmatch 'skip refused: the car is moving"')
$qm = [IO.File]::ReadAllText((Join-Path $root 'src\actions.cs')); $qm = $qm.Substring($qm.IndexOf('static int CmdQuitMain()'), 1500)
Check 'QUIT TO MENU waits for a rolling car (15 s) instead of refusing at once' ($qm -match 'WaitCarStopped\("quitmain"' -and $qm -notmatch 'quitmain refused: the car is moving"')
$rn = Body $ir 'static int CmdRaceNowBody()'
Check 'racenow is a command' ($ir -match 'case "racenow": return CmdRaceNow\(\)')
Check 'racenow: skips until the session is the race (at most DeckRules.RaceHopsMax = 3), then CmdGo' ($rn -match 'hop <= DeckRules\.RaceHopsMax' -and $rn -match 'CmdSkip\(\)' -and $rn -match 'DeckRules\.IsRaceType\(s\.Type\)' -and $rn -match 'CmdGo\(\)' -and $rules -match 'RaceHopsMax = 3')
Check 'racenow: refuses test drives and official sessions in plain words; waits for a rolling car' ($rn -match '!s\.Ai' -and $rn -match 'Test Drive has no race' -and $rn -match 'WaitCarStopped\("racenow"')
Check 'racenow runs one at a time' ((Body $ir 'static int CmdRaceNow()') -match 'WithNamedLock\("Local\\\\irdeck-racenow"')
$ttr = Body $ir 'static int CmdToTheRace(string[] a)'
Check 'to-the-race is a command: the plan from DeckRules on the loaded event''s sessions, then the existing RACE NOW or NEXT SESSION path' ($ir -match 'case "to-the-race": return CmdToTheRace\(Slice\(a, 1\)\)' -and $ttr -match 'DeckRules\.ToTheRacePlan\(s\.Ai, DeckRules\.RaceAhead\(s\.Sessions\.ToArray\(\), s\.Num\), test\)' -and $ttr -match 'if \(plan == "none"\) \{[^}]*Say\("no", "A Test Drive has no race\. QUIT TO MENU is on LEAVE\."\); return 3; \}' -and $ttr -match 'plan == "racenow" \? CmdRaceNow\(\) : CmdSkip\(\)')
Check 'spotter-tap is a command: the spotter mute toggle (CrewChief''s own mixer entry), with a dry form' ($ir -match 'case "spotter-tap": return CmdSpotterTap\(Slice\(a, 1\)\)' -and (Body $ir 'static int CmdSpotterTap(string[] a)') -match 'AppMuteToggle\("spotter", Array\.IndexOf\(a, "--dry"\) >= 0\)' -and $ir -match 'if \(!dry\) \{ Guid g = Guid\.Empty; v\.SetMute\(target, ref g\); \}')

Section '4. chat, OFFICIAL, Test Drive setup'
$chat = Body $ir 'static int CmdChat(string[] a)'
$rep = Body $ir 'static bool ChatRepeat('
Check 'chat say drops the same message within 3 s (file stamp, mutex around check+write)' ($chat -match 'if \(ChatRepeat\(string\.Join\(" ", Slice\(a, 1\)\)\)\) return 0;' -and $rep -match 'irdeck-chat-say\.last' -and $rep -match 'DeckRules\.ChatIsRepeat\(' -and $rep -match 'irdeck-chat-stamp' -and $rules -match 'ChatRepeatMs = 3000')
Check 'the repeat check comes after the no-session check and before the sim is focused' ($chat.IndexOf('no sim session running') -lt $chat.IndexOf('ChatRepeat(') -and $chat.IndexOf('ChatRepeat(') -lt $chat.IndexOf('FocusWindow'))
$nav = Body $ir 'static int CmdNav(string[] a)'
Check 'nav --button X: with no Button, the same exact name as a Hyperlink, then a TabItem; says which' ($nav -match '"hyperlink", "tabitem"' -and $nav -match '--type=" \+ alt' -and $nav -match 'is a " \+ alt \+ " in this iRacing, not a button')
Check 'nav never falls back for "Test Drive" (inside its dialog that Hyperlink launches the drive)' ($nav -match 'Equals\("Test Drive"' -and $nav -match 'names\.Clear\(\)')
Check 'OFFICIAL still goes through nav --button Official' ((Src 'src\official.cs') -match 'CmdNav\(new string\[\] \{ "--button", "Official" \}\)')
$tds = Body $td 'static int CmdTdSetup(string[] a)'
Check 'tdsetup: the damage switch panel failing no longer stops the start; it logs and goes on to the track' ($tds -match "damage switch not reachable - starting with iRacing's current damage setting" -and $tds -match '3\. damage off / on' -and $tds.IndexOf('damage switch not reachable') -lt $tds.IndexOf('// 4. track and layout'))
Check 'tdsetup: it still stops when the Test Drive window itself is gone (not just the switch)' ($tds -match 'if \(!DialogOpen\(els\) \|\| ReadCards\(els\) == null\) return 1;')
Check 'tdsetup: the CAR step and the track step still stop on failure' ($tds -match 'if \(EnsurePanel\(root, true\) == null\) return 1;' -and $tds -match 'if \(EnsurePanel\(root, false\) == null\) return 1;')

$rc = Body $td 'static Cards ReadCards('
Check 'Test Drive cards: the name is the text NEAREST each info button (a news headline behind the dialog was read as the car, 2026-10-23)' ($rc -match 'u\.R\.X > c\.CarName\.R\.X' -and $rc -match 'u\.R\.X > c\.TrackName\.R\.X' -and $rc -notmatch 'c\.CarName == null\) c\.CarName = u')
Check 'AI RACE saves a picture of the screen when it stops' ((Body $td 'static int AiStop(') -match 'SaveSimArea\("fail-airace"\)')

$ap = Body $td 'static UEl AiPickRow('
Check 'AI RACE opens the car list with Add a Car when the car step shows that button instead (2nd AI race in a row, 2026-10-23)' ($ap -match 'Same\(u\.Name, "Add a Car"\)' -and $td -match 'Same\(name, "Add a Car"\)')
Check 'AI RACE tells the top screen when it starts and why it stopped' ((Body $td 'static int AiStop(') -match 'Say\("no", "AI race stopped: "' -and $td -match 'Say\("wait", "Starting the AI race: "')
Check 'HOME after KIDS says Kids mode off on the top screen' ($ir -match 'KidsUnlockByHome\(\); Say\("ok", "Kids mode off"\)')

Section '5. kids mode while the sim runs'
Check 'kids: KidsDriving is gone, arming never checks the sim or the car' ($kids -notmatch 'KidsDriving' -and (Body $kids 'static int KidsTurnOn(') -notmatch 'iRacingSim64DX11|IsOnTrack|refused')
Check 'kids: the keyboard and mouse hooks let injected input through (DeckRules.HookPasses with the hook flags)' ($kids -match 'DeckRules\.HookPasses\(k\.flags, false' -and $kids -match 'DeckRules\.HookPasses\(m\.flags, true' -and $kids -match 'struct KidsMouse' -and $rules -match 'KbdInjected = 0x10' -and $rules -match 'MouseInjected = 0x01')
Check 'kids: the mouse hook struct is MSLLHOOKSTRUCT (pt, mouseData, flags, time, extra)' ($kids -match '(?s)struct KidsMouse.*?int x, y;.*?uint mouseData, flags, time;.*?IntPtr extra;')
Check 'kids: real input is still swallowed (return 1) and the wheel is still not hooked' ($kids -match '\(IntPtr\)1' -and $kids -notmatch 'BlockInput|RegisterRawInputDevices')
Check 'kids: deck keys use the allow-list; ignored keys still log "kids mode: ignored"' ($ir -match 'KidsLocked\(\) && !DeckRules\.KidsAllows\(a\)' -and $ir -match 'kids mode: ignored')
Check 'kids: the injected-input test switch is an environment variable, off by default' ($kids -match 'IRDECK_KIDS_BLOCK_INJECTED' -and $kids -match 'kidsBlockInjected = !string\.IsNullOrEmpty')
Check 'kids: irdeck sends all of its own input through injected APIs only (SendInput, keybd_event, mouse_event)' (($ir -match 'Native\.SendInput') -and ($ir -match 'Native\.mouse_event') -and ($ir -match 'Native\.keybd_event') -and ($ir -notmatch 'SendMessage|PostMessage|WriteFile'))

# ---------------------------------------------------------------- 6. offline CLI (no session => nothing to click)
Section '6. irdeck-cli, forms that cannot touch the sim'
$build = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-irdeck.ps1') -NoDeploy 2>&1
if ($LASTEXITCODE -ne 0) { throw ('irdeck no-deploy compile failed: ' + ($build -join ' ')) }
$cli = Join-Path $env:TEMP 'ird\irdeck-cli.exe'
function Ir { $o = & $cli @args 2>&1 | ForEach-Object { "$_" }; [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join "`n") } }
$state = (Ir state).out
Check 'the rig is free (state shows sim=False)' ($state -match 'sim=False') $state
if ($state -match 'sim=False') {
  Assert-RigFree -Where 'offline CLI'
  $r = Ir smart --dry
  Check 'smart --dry names a plan and does nothing else' ($r.rc -eq 0 -and $r.out -match 'smart --dry: get in plan = (start|open-then-start)') $r.out
  $r = Ir restartrace
  Check 'restartrace with no session: plain message, rc 3, nothing clicked' ($r.rc -eq 3 -and $r.out -match 'restartrace: no session is running') $r.out
  Check 'no armed-restart-race.txt was written' (-not (Test-Path (Join-Path (Split-Path $cli) 'armed-restart-race.txt')))
  $r = Ir confirm quit-main quitmain
  Check 'the old x2 `confirm` verb is gone (W0-1): unknown command, nothing armed' ($r.rc -ne 0 -and $r.out -match 'unknown command confirm' -and -not (Test-Path (Join-Path (Split-Path $cli) 'armed-quit-main.txt'))) $r.out
  $r = Ir racenow
  Check 'racenow with no session: plain message, rc 3' ($r.rc -eq 3 -and $r.out -match 'racenow: no session is running') $r.out
  $r = Ir getout
  Check 'getout with no session: rc 3 and says so' ($r.rc -eq 3 -and $r.out -match 'getout: no sim session running') $r.out
  $r = Ir skip
  Check 'skip with no session: rc 3 and says so' ($r.rc -eq 3 -and $r.out -match 'skip: no session is running') $r.out
  $r = Ir chat say 'Thanks!'
  Check 'chat say with no session: rc 3, nothing typed, no stamp written' ($r.rc -eq 3 -and $r.out -match 'chat say: no sim session running') $r.out
  $r = Ir to-the-race
  Check 'to-the-race with no session: rc 3 and says so' ($r.rc -eq 3 -and $r.out -match 'to-the-race: no session is running') $r.out
  $r = Ir to-the-race --dry
  Check 'to-the-race --dry with no session: rc 3 too, nothing done' ($r.rc -eq 3 -and $r.out -match 'no session is running') $r.out
  $r = Ir to-the-race --fake '0:Practice,1:Qualify,2:Race' 0 1
  Check 'to-the-race --fake: an AI weekend in practice -> RACE NOW' ($r.rc -eq 0 -and $r.out -match 'to-the-race \(fake\): RACE NOW') $r.out
  $r = Ir to-the-race --fake '0:Testing' 0 0 1
  Check 'to-the-race --fake: a Test Drive -> refused (it never quits the drive)' ($r.rc -eq 0 -and $r.out -match 'A Test Drive has no race \(refused\)') $r.out
  $r = Ir to-the-race --fake '0:Practice,1:Race' 1 0 0
  Check 'to-the-race --fake: an official race (not AI, not a Test Drive) -> NEXT SESSION, which refuses it' ($r.rc -eq 0 -and $r.out -match 'to-the-race \(fake\): NEXT SESSION') $r.out
  $r = Ir spotter-tap --dry
  Check 'spotter-tap --dry says what a tap would do and changes nothing (or that the spotter is not making sound)' (($r.rc -eq 0 -and $r.out -match 'a tap would (mute|turn the sound back on for) CrewChiefV4.*nothing changed') -or ($r.rc -eq 3 -and $r.out -match 'CrewChiefV4 is not making sound right now')) $r.out
  # HOME (rigon) tells the top screen to go HOME (W3-4 review): a pretend dashboard on a spare port records the request
  $tl = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $tl.Start(); $port = $tl.LocalEndpoint.Port
  $env:IRDECK_DASH = "http://127.0.0.1:$port"
  $psi = New-Object Diagnostics.ProcessStartInfo($cli, 'rigon --nav-only'); $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
  $proc = [Diagnostics.Process]::Start($psi)
  $req = ''; $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not $tl.Pending() -and $sw.ElapsedMilliseconds -lt 8000) { Start-Sleep -Milliseconds 50 }
  if ($tl.Pending()) {
    $cl = $tl.AcceptTcpClient(); $ns = $cl.GetStream(); $ns.ReadTimeout = 3000; $buf = New-Object byte[] 4096; $n = $ns.Read($buf, 0, $buf.Length); $req = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
    $resp = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: 11`r`nConnection: close`r`n`r`n{`"ok`":true}"); $ns.Write($resp, 0, $resp.Length); $ns.Flush(); $cl.Close()
  }
  $null = $proc.WaitForExit(8000); $nout = $proc.StandardOutput.ReadToEnd(); $tl.Stop(); Remove-Item Env:\IRDECK_DASH -ErrorAction SilentlyContinue
  Check 'HOME (rigon) asks the dashboard for /api/nav?to=home with X-Paddock, and logs it' ($req -match '^GET /api/nav\?to=home HTTP' -and $req -match '(?im)^X-Paddock: 1' -and $proc.ExitCode -eq 0 -and $nout -match 'rigon: the top screen goes HOME') ($req.Split("`n")[0] + ' | ' + $nout)
  $rg = Body $ir 'static int CmdRigOn(string[] a)'
  Check 'HOME never tells the top screen anything in a session (the session check comes first)' ($rg.IndexOf('!boot && SessionActive()') -ge 0 -and $rg.IndexOf('!boot && SessionActive()') -lt $rg.IndexOf('NavHome()'))
  $r = Ir tow --pretend 0.4
  Check 'tow --pretend still works (the tow wait is untouched)' ($r.rc -eq 0 -and $r.out -match 'stationary') $r.out
}
Write-Host "$pass ok, $fail FAIL"
if ($fail) { exit 1 }
