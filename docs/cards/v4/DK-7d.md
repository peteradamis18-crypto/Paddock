# DK-7d Smart key v1 - small and safe (replaces the open parts of DK-7/7b)

Read AGENTS.md, CLAUDE.md, docs\cards\v4\DK-7.md, docs\tasks\log\DK-7b-fix.md, docs\tasks\log\cx\RV2-DK-7b.last.md (the findings you must
clear), then src\deckstate.cs, src\irdeck.cs (CmdGo, CmdConfirm, Snap, OnTrack), src\actions.cs (CmdTow, CmdSkip), dash\src\irdash.cs
(/deck/state), build-irdeck.ps1 and dash\build.ps1 (source lists). C# 5 only.

## v1 scope - exactly these states, nothing else
| State | Condition (all from ONE fresh snapshot: sim process present AND SDK tick advanced within the last 1 s) | Label | Action |
|---|---|---|---|
| WAIT | anything stale, unknown, loading, replay, or not matching a row below | WAIT | none |
| RIGON | iRacing UI not running | RIG ON | existing rigon |
| HOME | UI running, sim not running | HOME | top-screen home only (no iRacing clicks) |
| GETIN | connected, IsOnTrack=0, IsReplayPlaying=0 | GET IN | the existing in-sim Drive path ONLY if it can never press a setup wizard's Continue: split CmdGo so SMART calls a new `GoDriveOnly()` that presses only the sim's verified Drive control and refuses (WAIT) otherwise |
| DRIVE | IsOnTrack=1 and Speed >= 1 m/s | DRIVE | none |
| RESET | IsOnTrack=1 and Speed < 1 m/s | RESET | existing CmdTow (it has its own speed guard; keep it) |
| SKIP (offer only) | Test or AI session (verified from session YAML), IsOnTrack=0 | SKIP | NEVER call CmdSkip directly: run `confirm skip skip` (the x2 path with bounce protection), so one SMART press only ARMS |
No JOIN, no START, no RESULTS in v1 (the fixed keys cover them). Official sessions: SKIP never offered.

## Build
1. One shared pure resolver: `src\deckstate.cs` with `static DeckState Resolve(Snapshot s)` (no I/O inside). Compile the SAME file into
   irdeck (build-irdeck.ps1) and irdash (add to dash\build.ps1 `$src` by relative path) so /deck/state and SMART can never disagree.
2. `smart` in irdeck: take a snapshot, Resolve, run the row's action; `smart --dry` prints state + action without doing it.
3. `GET /deck/state` in irdash: Resolve on irdash's own latest frame (+ sim process check) and return
   `{"primary":"GETIN","label":"GET IN","reason":"","armed":{"quit":n,"restart":n,"skip":n}}` (armed = seconds left from armed-*.txt,
   0 if none). Read-only.
4. tests\deckstate-test.ps1 must EXECUTE the resolver: compile a tiny test exe with csc from src\deckstate.cs + a test driver (or call
   `irdeck-cli smart --dry --fake <json>`), feed one fake snapshot per row + stale tick + replay + official session, and compare the
   returned state/label/action. Also: SKIP via SMART produces an ARM (armed-skip.txt written), never a skip; RESET at 2 m/s -> DRIVE.
   No string-grep checks.
5. Update tests\keys-test.ps1 for the current MORE page (REPLAY moved there) so it passes.

## Files
src\deckstate.cs, src\irdeck.cs, src\actions.cs (only if a seam is needed), dash\src\irdash.cs, dash\build.ps1 ($src line),
build-irdeck.ps1, tests\deckstate-test.ps1, tests\keys-test.ps1, docs\tasks\log\DK-7d.md.

## Gate
build-irdeck.ps1 -NoDeploy and dash\build.ps1 -NoDeploy clean. If `irdeck-cli.exe state` shows sim=False: run deckstate-test and
keys-test -> 0 FAIL; else say so. Do not deploy irdeck, do not install the add-on. Report in AGENTS.md format.
