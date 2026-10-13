# DK-1 One-press AI RACE from Peter's own saved preset

Read AGENTS.md, CLAUDE.md, docs\deck\DECK-v4.md, docs\deck\council-fable.md (sections 2 and 4 item 1), docs\research\ai-dialog.md,
docs\research\iracing UI notes in docs\deck\peter-needs.md, and the code: src\irdeck.cs (CmdStartLast, CmdAiRace, Main dispatch),
src\testdrive.cs (DialogOpen, EnsurePanel, PickRow, TdMenuItems, TdWhy, IracingUiHandle). C# 5 only.

## Why
Peter cannot jump into an AI race: no key exists and the old path relies on iRacing's AI 'Last settings', which was wiped and
which the code clicks through blindly. He must get ONE press -> in the car in his usual AI race, or a 3-word reason on the key.

## Build
1. `airace save`: open the AI Racing chooser, press Last settings (or read the wizard he has open), VERIFY the AI modal, read
   each wizard step through the stable `wizard-sidebar-link-set-*` AutomationIds (read-only, scoped to the modal): car, track +
   layout, field size, strength, race length, time of day, weather - whatever is readable; write `mydrive\ai-preset.ini`
   (plain key=value, a `saved=` timestamp). Never press New Race. Never write iRacing files.
2. `airace start`: refuse if a session is running (`state`) or the iRacing UI is not up (one reason line). Open Last settings,
   verify the modal, step by sidebar link (not blind Continue), compare every step with the preset; where car/track differ,
   fix them with PickRow/TdMenuItems scoped to the modal; log one read-back line per step; press Race only when all match,
   then the existing get-in path. Any mismatch that cannot be fixed -> stop, log `airace: <reason>` and write the short reason
   to `mydrive\ai-status.txt` (`NO RACE SAVED`, `CAR NOT FOUND`, `UI CHANGED`) for the deck key.
3. `airace start --dry` and `airace save --dry`: print the plan from the current UI element list without clicking.
4. Keep `startlast ai` working as an alias of `airace start`. Ignore repeats within 0.7 s as every command does.
5. Fixture test `tests\airace-test.ps1` (dot-source tests\guard.ps1, Assert-RigFree, Section ...): feed saved `uilist`-style
   element dumps (make fixtures from ai-dialog.md and the AutomationIds) through the matcher: a full wizard -> plan ends in
   Race; a "0 cars / 0 tracks" wizard -> refuses with NO RACE SAVED; a renamed link -> UI CHANGED, no click; preset read/write
   round-trip. No live clicks in this test. Mark a `-Live` section that needs `Assert-RigFree -NeedAway` (the lead runs it).

## Files
src\irdeck.cs, src\testdrive.cs, new mydrive\ai-preset.ini (only written by `airace save`), new tests\airace-test.ps1,
docs\research\ai-dialog.md (append what you learned), docs\tasks\log\DK-1.md.

## Gate
`powershell -ExecutionPolicy Bypass -File build-irdeck.ps1` must NOT be run while `irdeck-cli.exe state` shows sim=True (it replaces
key exes) - while he races, compile-check by running csc the same way build-irdeck.ps1 does but to a temp output folder.
tests\airace-test.ps1 offline sections 0 FAIL. Report in AGENTS.md format to docs\tasks\log\DK-1.md with NEEDS LEAD = the live
-NeedAway section and Peter's one-time `airace save`.
