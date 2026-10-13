# DK-1s Scoped AI wizard survey command (read-only, modal-scoped) - so AI RACE can be finished safely

Read AGENTS.md, CLAUDE.md, docs\research\ai-dialog.md (all of it, incl. WARNING and DK-1 note), docs\cards\v4\DK-1.md,
docs\tasks\log\DK-1.md, then src\irdeck.cs (CmdUi, Scan, Pick, Press, FindUiWindow, CmdAiRace) and src\testdrive.cs (DialogOpen,
EnsurePanel, PickRow, TdMenuItems). C# 5 only.

## Why
The only generic click tool (`irdeck ui <name>`) searches the WHOLE iRacing window; the AI page behind the wizard has the same
kinds of rows, so a click could land on the background page (a blind click once opened iRacing news and a Steam sign-in).
The lead needs one safe command that reads the AI wizard inside its modal only.

## Build
1. `airace survey [--out <file>]`: refuse unless `state` shows sim=False and the iRacing UI is up. Navigate: sidebar `AI Single
   Player` -> `Single Race` -> chooser; VERIFY the chooser (it has `Last Settings` + `New Race` + `Close`); press ONLY
   `Last Settings` (case-insensitive). **Never press New Race. Never press Continue/Race.**
2. Find the modal: the element whose subtree contains the "AI Racing" title; every later lookup is scoped to that element.
3. For each sidebar link `wizard-sidebar-link-set-*` (AutomationId) that is enabled: press it (scoped), wait, dump every element in
   the modal content (ControlType, Name, AutomationId, enabled, toggle/value/selection state where the pattern exists) to the
   output file (default `docs\research\ai-wizard-dump-<stamp>.txt`) and take a screenshot of the iRacing UI window only to
   `tests\shots\ai-survey-<step>.png`. Locked steps: record "locked".
4. Leave cleanly: the modal's ` Back` close link (AutomationId `default-close-modal-btn-...`), then the chooser's `Close`. Verify
   the UI is back on the AI page. If anything is not as expected at any point: stop, log `airace survey: <what>`, leave via Back/Close
   only, never guess a click.
5. `airace survey --dry`: plan only from the current element list, no clicks.
6. Extend tests\airace-test.ps1 offline: a fixture with a background page row named like a wizard row -> the scoped finder never
   returns the background element; a chooser fixture without `Last Settings` -> refuses; `New Race` is never in any press list.

## Files
src\irdeck.cs (and/or src\testdrive.cs), tests\airace-test.ps1, docs\research\ai-dialog.md (append the command), docs\tasks\log\DK-1s.md.

## Gate
Compile irdeck to a temp folder (build-irdeck.ps1 -NoDeploy); airace-test offline sections 0 FAIL. Do NOT run the live survey
yourself - NEEDS LEAD: run `irdeck-cli airace survey` in an away window (Assert-RigFree -NeedAway). Report to docs\tasks\log\DK-1s.md.
