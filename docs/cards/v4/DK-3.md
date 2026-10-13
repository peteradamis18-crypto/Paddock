# DK-3 x2 confirm that never eats the 2nd tap + MY DRIVE keeps his choices + no blind 40 s hunt

Read AGENTS.md, CLAUDE.md, docs\deck\DECK-v4.md (root causes 3 and 4), docs\deck\council-fable.md section 2 and section 4 items 3
and 5, docs\deck\irdeck-log-recent.txt (13:26 quit presses; 11:10 MY DRIVE START), then src\irdeck.cs (Main, keyMutex, repeat
check, CmdConfirm, armed-*.txt, CmdGo, SessionActive), src\mydrive.cs, dash\src\mydrive.cs (fast/slow lanes, MdStart). C# 5 only.

## Build
1. Confirm: when a fresh `armed-<id>.txt` exists (armed < 3 s ago), the confirming press skips the mutex wait and the 0.7 s repeat
   rule and confirms; the arming process releases keyMutex BEFORE it beeps. Presses < 0.12 s apart are still one press.
   Arming writes the expiry time so the add-on can show ARMED 3-2-1 (DK-4 reads it).
2. MY DRIVE: `mydrive pick` of a car after `clear` must not silently keep an old track - the state shows "track: choose" until a
   track is picked (or the explicit "same track" key); START refuses with `CHOOSE TRACK`. mddamage / mdpick are refused while a
   START is running (slow lane busy) and MdStart re-reads state.ini AFTER taking the lane lock (the 11:10:31 damage on/off race).
3. CmdGo / SessionActive: require the sim process (iRacingSim64DX11) alongside the telemetry flag; with no sim process log
   "sim not running" and stop instead of hunting the green button for 40 s.
4. tests\confirm-test.ps1 (guard, Assert-RigFree, Sections): two irdeck processes 0.2 s apart -> confirmed; 0.05 s apart -> one
   press; 4 s apart -> re-armed, not confirmed. Extend the MY DRIVE mock test (find it under tests\) for 2 and 3 with fake state.
   No live clicks.

## Files
src\irdeck.cs, src\mydrive.cs, dash\src\mydrive.cs, new tests\confirm-test.ps1, the existing MY DRIVE test file, docs\tasks\log\DK-3.md.

## Gate
Compile irdeck to a TEMP folder (not build-irdeck.ps1) while sim=True; `dash\build.ps1 -NoDeploy` clean; the new/extended tests'
offline sections 0 FAIL. NEEDS LEAD: run build-irdeck.ps1 + dash deploy when sim=False. Report to docs\tasks\log\DK-3.md.
