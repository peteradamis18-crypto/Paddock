# PADDOCK task cards

One card = one Grok session (run by `tools\grok-run.ps1 <card>`). Read `AGENTS.md` first ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â its rules and report format
apply to every card. Phases and the "why" are in `docs/ROADMAP.md`; detailed specs in `docs/SPEC-next.md`.
Models: **fast** = `grok-4.7-build-fast`, **strong** = `grok-4.7`. "Live" = needs the rig free (`sim=False`);
"Away" = needs Peter away 10 minutes (`tests\guard.ps1 -NeedAway`). If a live/away part can't run now, do everything
else, leave the live part clearly listed under NEEDS LEAD, and finish.

---
## C-01 Stabilise the paused drafts (Vault + Official) ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: done 2026-10-10 (Grok; vault=0/official=0, deployed 10:48, both routes answer enabled:false, no log errors - verified by the lead; Grok ended before writing its report, gate tests to be covered by run-all)
Goal: the half-written `dash\src\vault.cs`, `dash\src\officialcore.cs`, `dash\src\official.cs`, `src\official.cs`,
`dash\www\v2\vault.*`, `official.*` were cut off mid-work on 2026-10-10. Make them safe and dormant until their own
cards finish them.
Steps: read them fully; list what is complete vs stubbed in `docs\tasks\log\C-01.md`; check every rule in AGENTS.md
(no iRacing file writes, no UI automation or network at startup, background work only at BelowNormal and never while
the sim runs, no work during a session); add ini switches in `dash\irdash.ini` ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â `vault=0` and `official=0` (default
OFF; Init/Start do nothing when off; routes answer `{"enabled":false}`); fix compile warnings that hide bugs; build
(`dash\build.ps1 -NoDeploy`), then deploy with `dash\build.ps1` when it allows.
Files: the files above, `dash\src\irdash.cs` (only the Init/Start/route lines), `dash\irdash.ini`.
Gate: irdash builds, deploys and runs for 5 minutes with both switches off, no new errors in `dash\irdash.log`;
`tests\run-all.ps1 -Only corners,perf,pbdelta,bench,replay,gallery` ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ no new FAIL vs `tests\run-all.last.txt`.
Do not: finish the features here; delete the drafts.

## C-02 Fix the failing tests ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â fast ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: done 2026-10-10 (Grok; cause: tests sharing one pretend session + the new VS PB default, test fixes only; gate run-all 11:28: perf 97/0, bench 49/0, data 137/0, overlays 74/0 - verified by the lead)
Goal: last sweep: `data-test` 3 FAIL (pre-session brief not shown: 'with a session loaded and you not in the car, the
brief is up', 'it shows the trackÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¦', 'it ignores the mouse'), `overlays-test` 9 FAIL (section 7 pretend session:
START timing, delta bar values/colours, restart gate; and 'the doctor starts the overlays app by itself'), `bench-test`
1 FAIL ('all 13 source links answer with a PDF' ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â network flake?). For each: find whether the TEST or the CODE is wrong
(recent changes: `www\v2\brief.js` now draws corners via `Corners.draw`; the delta bar default became VS PB with a
taller window; the Doctor gained a 'performance' check; tests now run at BelowNormal; stand-ins inherit priority).
Fix the real cause; keep tests honest (never weaken a check to pass).
Files: `tests\data-test.ps1`, `tests\overlays-test.ps1`, `tests\bench-test.ps1`, and the code at fault (smallest fix).
Gate: `tests\run-all.ps1 -Only data,overlays,bench,perf` ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ 0 FAIL (bench links: retry once before failing).

## C-03 REPLAY screen live fixes ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· away
Status: open
Goal: live run 2026-10-10 08:31 (`tests\last\replay-live.txt`): 242 ok, 6 FAIL ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â COCKPIT and CHASE don't change
`CamGroupNumber`; CAMERA > doesn't change the camera; AUTO TV (CamCameraState 0x10) and HIDE UI (0x08) don't take;
MY LAST INCIDENT check fails. All camera/UI-state messages failed while transport passed ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ find the shared cause in
`dash\src\replay.cs` (CamSetState packing msg 2 / var1; CamSwitchPos vs CamSwitchNum with group+camera; scenic/
camera-tool state; timing after ReplaySearch; optimistic holds hiding the real value). Test single messages by hand
through `/api/do` in a spectated AI race. Update `docs\replay.md` 'Live run' with measured facts.
Files: `dash\src\replay.cs`, `tests\replay-test.ps1`, `docs\replay.md` (plugin.html only if a label is wrong: list it).
Gate: `tests\run-replay-live.ps1` ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ `replay-test -Live` 0 FAIL.

## C-04 Rig Doctor clears stray launcher dialogs ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â fast ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: done 2026-10-10
Goal: an explorer-owned error box (class `#32770`, title = `...\irdashies\app-1.1.0\irdashies.exe`, one OK button) sat
hidden behind the sim on the middle screen from ~00:11 to 02:10 on 2026-10-10. Doctor: every check, find visible
`#32770` windows owned by explorer.exe whose title is a path to irdashies / irdash / CrewChief / StreamDeck, read
their text if possible, log it, close with WM_CLOSE (no focus change). Find why the launch failed (look at how the
Doctor/overlays start irdashies through explorer and what happens if it is already starting/updating) and prevent it.
Files: `dash\src\doctor.cs` (+ `dash\src\overlays.cs` if the cause is there), a test section in a new
`tests\doctor-test.ps1` (a fake `#32770` window created by the test, owned by a stand-in, NOT explorer: make the
owner check injectable for the test).
Gate: doctor-test 0 FAIL; the fake dialog is closed within one check, focus unchanged.

## C-05 Vault V1 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â saved laps and races with their data ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: done 2026-10-10 (lead: vault-test 87 passed / 0 failed 18:32, pictures v-grid/v-detail/v-compare checked, vault=1 deployed 18:33; compare default bug noted on C-08)
Spec: ROADMAP Phase 2 'V1', SPEC WS17. Start from the C-01 review of `dash\src\vault.cs`.
Goal: moments (lap/race), auto-save (PB, top 10% of his laps for car+track, best 3 per combo, race top-3/win, iRating
+40), untouched .ibt copy per keeper in `vault\telemetry\<car>\<track>\`, one-time backfill from his old .ibt files
(BelowNormal, never the newest file while the sim runs, skip OneDrive online-only files), budget `vault_gb=60`
(keepers never pruned), Vault page: grid (thumbnail = labelled track map with the lap trace, via `corners.js`), filters,
detail (map + speed/throttle/brake/delta traces on one cursor via `/ibt/lap`, corner table vs PB and vs best in Vault,
notes, OPEN IN COSWORTH ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ opens the folder until C-14, SHARE ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ folder, DELETE asks twice), compare two laps (delta
trace). Turn `vault=1` on when the gate passes. Links: Sessions page 'Vault ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Âº' (exists), debrief after a PB.
Files: `dash\src\vault.cs`, `dash\www\v2\vault.*`, `tests\vault-test.ps1`, `docs\vault.md`.
Gate: vault-test 0 FAIL incl. backfill of 3 real .ibt (PB, race, ordinary), pruning unit test, pictures
`tests\shots\v-*.png` (grid, detail, compare) that look premium (lead reviews).
Review: FIXED 2026-10-10 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â hand-added tags survive a re-scan, recent laps no longer take a keeper's telemetry path, the corner table stays on this car and track. Gate still not run (sim on). Lead: deploy, run tests\vault-test.ps1, review v-*.png, then set vault=1.

## C-06 Recorder (ffmpeg) ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live + away for the quality part
Status: partly 2026-10-11 (coding agent): the recorder is built, tested and deployed with `recorder=0` (tests\recorder-test.ps1: 135 passed, 0 failed three times in a row via run-all, incl. the real middle screen; log docs\tasks\log\C-06.md). Left for the lead: measure the frame-rate cost in the sim, then `recorder=1` (steps in the log). Not done: tests\vault-quality.ps1 (3-preset contact sheet; this brief did not ask for it) and hevc_nvenc (h264_nvenc chosen on purpose: browsers and YouTube play it); CLIP (last 30 s) and the moment-record attach are not built (the clip is found by matching, `/vault/videoinfo`). Was: held 2026-10-10 by the lead - design first.
Spec: ROADMAP Phase 2 'V2', SPEC WS17 'CHANGE 2026-10-10', `docs\vault-recording-research.md`.
Goal: irdash runs `vault\bin\ffmpeg.exe` hidden at BelowNormal only while the sim runs: `ddagrab` of the MIDDLE monitor
(x=0,y=0, 2560ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â1440; screens rotated 180ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â° in Windows ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â picture must be upright), `hevc_nvenc` (fallback h264_nvenc,
libx264 veryfast), rolling 10-s segments named with exact start times, keep ~3 min; CLIP (last 30 s) / KEEP (current
lap) cut without re-encode; attach to the moment with exact sync; detect a black capture (exclusive fullscreen) and say
in plain words what to change; restart ffmpeg if it dies; log recorder on/off per session for the Performance page.
`tests\vault-quality.ps1` (Away): 10 s with 3 presets ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ contact sheet of frames + sizes for the lead.
Files: `dash\src\vault.cs` (or new `dash\src\recorder.cs` + `$src`), `tests\vault-recorder-test.ps1`,
`tests\vault-quality.ps1`, `docs\vault.md`.
Gate: unit tests of segment bookkeeping/cutting/sync 0 FAIL; quality sheet produced (Away); upright picture verified.

## C-07 After-race review + wheel button ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â fast ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: done 2026-10-10 (lead: review-test 40 passed / 0 failed 18:33, deployed; the two gaps from its review are C-27)
Goal: when a session ends (or he gets out after a race), the top-screen page shows a calm panel inside the debrief:
"3 laps saved ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â lap 14 1:19.8 (PB), lap 9 (top 6%) ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¦", KEEP ALL (default after 60 s), CHOOSE (opens the Vault on the
top screen). Never a separate popup window; never while driving. Wheel button: irdash reads joystick buttons with winmm
`joyGetPosEx` (no libraries) for all connected devices; `/api/do?c=wheelteach` waits 10 s for the next button press
and saves `wheel_keep=<device>:<button>` in irdash.ini; while driving that button = KEEP (marks the lap, soft beep, no
focus change); after the race = KEEP ALL. Deck keys are added in C-09.
Files: `dash\src\vault.cs` (or `dash\src\wheel.cs`), `dash\www\v2\debrief.js`/`.css` (small), tests.
Gate: test with a pretend session end (test hook) shows the panel and the default; wheel-button logic unit-tested with
a stub device; no focus change.
Review: NEEDS LEAD 2026-10-10 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â pretend session 40 ok, 0 failed. A real session's laps are still unread for 120s, and not at all while the sim process is up, so the strip never gets the sentence.

## C-08 Vault video player and compare ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â fast ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: held 2026-10-10 by the lead - design first (Peter: charts and screens must look like real racing software; Cosworth and video do not work yet). Waits for docs\DESIGN-analysis.md. Was: open (after C-06)
Lead note 2026-10-10 18:34 (from tests\shots\v-detail.png): the lap page's default "Next best in the Vault" is the SAME lap (lap 7 1:19.549 against lap 7 1:19.549, via its CLIP moment), so the time difference is flat. Exclude moments of the same lap/session file from "next best".
Goal: detail view plays the clip (HTML5 video, irdash route with HTTP Range), map dot + trace cursor follow the video,
click a turn or a trace point ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ seek; compare two laps side by side locked by track position (the one ahead waits).
Files: `dash\www\v2\vault.*`, `dash\src\vault.cs` (Range route), tests.
Gate: with a generated test clip (ffmpeg testsrc + fake times) sync error ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â°ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¤ 1 frame; pictures `v-player-*.png`.

## C-09 Deck batch (prepare only) ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â fast ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· offline
Status: held 2026-10-10 by the lead - design first (Peter: charts and screens must look like real racing software; Cosworth and video do not work yet). Waits for docs\DESIGN-analysis.md. Was: open (after C-03, C-05, C-07)
Goal: in `deck-intro\plugin.html` + `install.ps1` (bump `$ver` once): a VAULT screen (latest moments, KEEP/CLIP,
TEACH WHEEL BUTTON, MAKE A REPLAY placeholder), any REPLAY label fixes from C-03, PERFORMANCE entry. Prepare (do NOT
run) the MAIN layout change in `build-deck.ps1` as a proposal file `docs\deck-main-proposal.md` with a picture of the
32 keys (deck harness) ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â the lead asks Peter. Test everything in the deck harness (`tests\deck-harness.ps1`).
Gate: deck tests 0 FAIL; proposal picture made. Do not: run install.ps1 or build-deck.ps1.

## C-10 Design tokens + welcome driver card ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â fast ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: held 2026-10-10 by the lead - design first (Peter: charts and screens must look like real racing software; Cosworth and video do not work yet). Waits for docs\DESIGN-analysis.md. Was: open
Spec: ROADMAP Phase 3, SPEC WS9 P1.
Goal: `dash\www\v2\theme.css` tokens (colours, type scale, spacing, card) used by idle/welcome first; welcome/idle
header: name, car number, team Pratt Miller Motorsports, the car he is driving now (live from the session; last car when
idle) with its render. Car art: research local sources first (iRacing install folder, iRacing UI cache ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â read-only),
cache in `paddock\cars\`; if only the Data API (login) has it, STOP and write the request. No network after the first
fetch. No headshot.
Gate: screenshots `tests\shots\w-*.png` (idle, session loaded) with the right car; offline second launch.

## C-11 Visual polish WS9 (P2ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦ÃƒÂ¢Ã¢â€šÂ¬Ã…â€œP3) ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â fast ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: held 2026-10-10 by the lead - design first (Peter: charts and screens must look like real racing software; Cosworth and video do not work yet). Waits for docs\DESIGN-analysis.md. Was: open (after C-10)
Goal: apply tokens to the live dashboard, sessions/lap analysis, perf, benchmark, vault pages; before/after screenshots
`tests\shots\p-*.png`; no behaviour change; all tests still pass.

## C-12 Studio S0+S1 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â automatic cinematic replays ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· away
Status: held 2026-10-10 by the lead - design first (Peter: charts and screens must look like real racing software; Cosworth and video do not work yet). Waits for docs\DESIGN-analysis.md. Was: open (after C-06, C-03)
Spec: SPEC WS19 S0ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦ÃƒÂ¢Ã¢â€šÂ¬Ã…â€œS1, research E5.
Goal: verify the replay survives after the race while the sim stays on the session; then shot-list engine (corners ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢
cameras), one real-time pass driving the replay by SDK (ReplaySearchSessionTime, camera switches, slow-mo, HIDE UI)
while the recorder films the middle screen; output into the Vault as 'ready to watch'; auto-run after a session when
Peter is away.
Gate: ROADMAP Phase 4 gate.

## C-13 Studio S2ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦ÃƒÂ¢Ã¢â€šÂ¬Ã…â€œS5 editor and combine ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: held 2026-10-10 by the lead - design first (Peter: charts and screens must look like real racing software; Cosworth and video do not work yet). Waits for docs\DESIGN-analysis.md. Was: open (after C-12)
Goal: `studio.html` mini editor (camera chips per segment, slow-mo, freeze, preview on the map, FILM IT), optional
overlays (burned in, clean copy kept), side-by-side/PiP/vs-PB, title/end cards, crossfades, race highlight reels.

## C-14 Cosworth Pi Toolbox ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live (download may need Peter)
Status: held 2026-10-10 by the lead - design first (Peter: charts and screens must look like real racing software; Cosworth and video do not work yet). Waits for docs\DESIGN-analysis.md. Was: open
Spec: ROADMAP Phase 5.
Goal: find the official Pi Toolbox Lite download for iRacing (Cosworth); if a login is needed STOP and write the
one-line request for Peter (he logs in and downloads; you install via explorer.exe). Then: detect the install
(read-only), OPEN IN COSWORTH opens the lap .ibt (and PB for comparison if possible), a ready workbook/layout for
Peter, video sync if the Toolbox edition supports it (research and document), else make Paddock's analysis the better
view. Write `docs\cosworth.md`.
Gate: one press opens his best lap ready to read.

## W-18b Cosworth open: live failures
Status: partly 2026-10-12 (direct Pi launch, workbook-title wait and docs updated; no-deploy build passed; lead must run the guarded live Cosworth checks).
Gate: lead-run `tests\cosworth-test.ps1`; confirm Untitled Pi loads the workbook before forwarding and the forwarded lap appears as a new outing.

## W-18c Use the proven Pi open method
Status: done 2026-10-12 (Paddock workbook copy, title-based readiness/forward confirmation, docs and live checks updated; no-deploy compile passed).
Gate: `dash\build.ps1 -NoDeploy` -> passed; title-based live checks updated but not run (card requested compile only).

## W-19 Cosworth ready workbook in Pi's user folder
Status: done 2026-10-12 (review fixes: unsupported text/XML/ZIP/OLE2 formats all fail closed; status 3; workbook tests 11 passed / 0 failed. No-deploy builds passed. Full cosworth-test stopped in its earlier W-18 browser section with Access denied, before W-19 ran. Report: `docs\tasks\log\W-19-fix.md`.)
Gate: `tests\cosworth-test.ps1 -W19Only` -> 11 passed / 0 failed; `dash\build.ps1 -NoDeploy` and `build-irdeck.ps1 -NoDeploy` passed.

## C-15 Official racing + race weekend + real-world calendar ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live (UI part: away)
Status: held 2026-10-10 by the lead - design first (Peter: charts and screens must look like real racing software; Cosworth and video do not work yet). Waits for docs\DESIGN-analysis.md. Was: open
Spec: ROADMAP Phase 6, SPEC WS8 R1ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦ÃƒÂ¢Ã¢â€šÂ¬Ã…â€œR8 (R8 = real-world calendar). Start from the C-01 review of the official drafts.
Gate: ROADMAP Phase 6 gate; `tests\official-test.ps1` 0 FAIL; idle screenshots.

## C-16 Pro comparison ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â find and fetch ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: held 2026-10-10 by the lead - design first (Peter: charts and screens must look like real racing software; Cosworth and video do not work yet). Waits for docs\DESIGN-analysis.md. Was: open (after C-05)
Spec: ROADMAP Phase 7. Peter approved yt-dlp + YouTube onboard downloads for personal viewing (no Google key needed).
Goal: download yt-dlp (official GitHub release, verify the checksum) to `vault\bin\`; search + score + cache
candidates (`data\pro-videos.json`), fetch 720p video-only to `vault\pro\` (throttled; never while he races online).
Gate: Road Atlanta Corvette GT3 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ a ranked list with the chosen onboard downloaded.

## C-17 Pro comparison ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â align and render ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: held 2026-10-10 by the lead - design first (Peter: charts and screens must look like real racing software; Cosworth and video do not work yet). Waits for docs\DESIGN-analysis.md. Was: open (after C-16, C-06)
Goal: motion-energy vs speed-trace alignment, confidence check against `data\pro-refs.json`, side-by-side render locked
by track position, labels 'real car vs sim ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â guide only', saved in the Vault next to his lap.
Gate: ROADMAP Phase 7 gate.

## C-18 Documentation set ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â fast ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· offline
Status: done 2026-10-10
Goal: `docs\ARCHITECTURE.md` (parts, processes, ports, folders, data flows, who starts what), `docs\OPERATIONS.md`
(build, deploy, test, recover, logs, the guard/lock/mutex), update `docs\USER-GUIDE.md` for everything in ROADMAP ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â§1
(plain English for Peter). Read the code to be accurate; no code changes.
Gate: the lead can follow OPERATIONS.md to build, deploy and run run-all without asking anything.
Review: FIXED 2026-10-10 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â docs match the build, deploy and run-all scripts. User guide: COACH shows the map (it starts on), the four delta modes are named apart, the tyres key does not turn gold.

## C-19 Root folder tidy ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â fast ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: open
Goal: move one-click .cmd/.ps1 pairs and strays (`bktest.exe`, `irlearn.exe`, `lappcheck.txt`, `fail-go.png`,
`learn-probe.txt`, `current-bindings.csv`) into `tools\` / `backup\`; first grep every reference (keys\keys.map,
build scripts, irdash, irdeck, the logon task "iRacing Rig", Stream Deck profiles under %APPDATA%\Elgato) and keep
anything referenced in place. List every move in the report.
Gate: run-all unchanged; the keys still work (deck harness); logon task path unchanged.

## C-20 iPhone companion (PWA over Tailscale) ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· later
Status: parked until Phases 1ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦ÃƒÂ¢Ã¢â€šÂ¬Ã…â€œ7 pass; needs Peter's yes for Tailscale.

## C-21 Deck speed live timings ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â fast ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live (Stream Deck must be free)
Status: open
Goal: `tests\deck-speed-test.ps1 -Live` ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ timings into `docs\deck-speed.md` (and `-Boot` after the next reboot).

## C-22 Live TV view on the top screen ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: done 2026-10-10 (Peter 2026-10-10: "a live TV view on top during iRacing: hit a button on the Stream Deck and it replaces
the track map and pacing/split panels with live TV and rotating camera views of my race, so friends can see a TV view
above while I drive. Preserve the other data on screen for me around the live TV view.")
Step 1 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â research (read-only, 1 page in docs\tv-view.md): can iRacing show a SECOND live camera while the player drives
(any 2026 feature: spectator/broadcast window, secondary view, multi-view; SDK camera messages affect only the single
main view)? Known: one sim instance renders one camera; the replay takes over the driver's view; a real TV feed needs a
second PC + second iRacing account spectating. If a real second view exists without changing iRacing files or Peter's
driving view, document it and STOP for the lead. Otherwise:
Step 2 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â build Paddock's own live TV view (premium broadcast look, never cheesy): a canvas/WebGL panel on the top-screen
dashboard drawing the real track outline (corners.js / TrackMap outline; gentle fake elevation is NOT allowed ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â flat but
in perspective) with every car in its live position (CarIdxLapDistPct, class colours, Peter's car gold), driver tags,
gaps, and an automatic director that rotates "cameras" every 8ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦ÃƒÂ¢Ã¢â€šÂ¬Ã…â€œ15 s: HELICOPTER (high orbit over his car), CHASE (low
behind his car), BATTLE (the closest pair on track, his first), LEADER, and a wide TRACK shot; smooth eased camera moves,
a small "LIVE" + camera name lower-third, no flashing. Toggle: `/api/do?c=tvview` (on/off, remembered), deck key added in
the next deck batch (C-09). When ON it takes the space of the track map panel and the pace/split panel; every other
panel stays exactly where it is (lead reviews before/after screenshots). Cost: GPU/CPU of the dashboard Chrome measured
with the Performance page (target: no measurable sim fps change; cap the panel at 30 fps; pause when the sim is not on track).
Files: new dash\www\v2\tv.js/.css, small hooks in index.html/core.js (re-read first), irdash command whitelist (one line).
Gate: test with the pretend session (test hook) + a real race YAML: panel replaces exactly the two panels, cars move,
director rotates, screenshots tests\shots\tv-*.png; no new FAIL in data/overlays tests.
Review: FIXED 2026-10-10 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â tv-test 28/0, data-test 137/0, overlays-test 74/0. Picture now stops when telemetry drops. Deck key stays with C-09.
Review: FIXED 2026-10-10 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â wide TRACK shot stroked the outline in screen pixels (an 11 m road was one pixel). Re-run tests\tv-test.ps1 when the rig is free.

## C-23 Friends mode fixes - wheel strength, top-screen track map + times, racing line, a real end-to-end test - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live + away
Status: done 2026-10-10 (verified by the lead: Peter drove it 13:27/14:08/14:30 - wheel steps felt different, map showed; live test 17:27 friends-live 36 passed / 0 failed after C-24. Racing line did not show -> C-25)
Already fixed by the lead today (do not redo): START stopped with "Test Drive dialog is not showing" because iRacing renamed the dialog's Close link to Back (src\testdrive.cs, irdeck.cs, actions.cs; tests\dialog-links-test.ps1). The guest sessions then ran (logs: irdeck.log 12:18-12:27). Read those logs first.
Goal: Friends mode that works for a friend with Peter not touching anything, proven by a test that really starts a session.
1. WHEEL STRENGTH. irdeck.log shows `guest: wheel medium = 14.0 Nm (yours 46.2)`, light = 8, full = 46.2, restore OK (quitmain saw ffb=46.2). Peter says it is "messed up" (no detail). Find out what is wrong, do not guess: read how `ApplyWheel`/`RestoreWheel` (src\guest.cs) use the SDK FFB broadcast (`Bcast(11, ...)`, SteeringWheelMaxForceNm) against the iRacing SDK docs (irsdk_BroadcastFFBCommand); check what iRacing really does with a max force far below the wheel's (clipping, feel, does it persist or reset on car/session change, does it also touch the Simucube side); check the values 8 / 14 / full and when they are applied (the log shows several presses in a row and 'will apply when you are in a session'); check the deck/top-screen shows the real value. Prove with the SDK read-back (SteeringWheelMaxForceNm, and SteeringWheelPctTorque / SteeringWheelTorque while rolling if a drive is possible) that each step really changes what the wheel does and that EXIT/NEXT/reset always puts Peter's own value back, even after a crash (store it on disk, restore at the next start). Fix what is wrong. If the right fix needs iRacing's own files or Peter's Simucube settings: do NOT touch them, write NEEDS PETER with the exact one-line ask.
2. TOP SCREEN IN THE CAR (dash\www\v2\guest.js + css, state from irdash /guest). Today it shows a big lap timer, best, "Next corner" (a corner name and distance bar) and pedals. Replace the corner-name block with the TRACK MAP: the real track outline (same data as map.js / corners.js, flat, premium black and gold, no corner names), the driver's car as a gold dot moving by lap distance, start/finish mark, a faint trail for the lap; big and readable from the seat. Time: show the CURRENT LAP time live (counting up, tenths), LAST lap and BEST lap clearly, and the session clock; they must keep running and change colour on a PB/session best (purple/green rules from the rest of Paddock). Keep the leaderboard and the lap celebrations; keep `guest coach` working (it now hides/shows the map block; the deck key label stays COACH until the next deck batch C-09 - do NOT edit deck-intro\plugin.html here, an add-on change needs Peter's Install click). Check at 1920x1080 in headless Chrome with a pretend session AND against a real telemetry feed.
3. RACING LINE. `guest line` sends the key from guest.ini (racing_line_key = ctrl+alt+l) with `CmdKey --sim`, but START never applies racing_line_default (state.line=1 is only a flag; nothing is sent when the session begins) and nothing proves the key is bound in iRacing or that the line really shows. Find how iRacing really toggles the driving line (controls binding? an in-sim setting? Test Drive option?) by reading, not clicking blindly. Make START put the line in the wanted state and read it back (a screenshot of the sim window while sitting in the pits is allowed when the rig is free and Peter is away; compare to the expected line). If it needs a binding in iRacing's controls or any iRacing file, DO NOT write it: report NEEDS PETER with the exact steps and prepare everything else so one yes finishes it.
4. TEST. New tests\friends-live-test.ps1 (Assert-RigFree -NeedAway): START a real Test Drive by name (BMW GT4, Lime Rock), check car/track from the iRacing UI cards, wheel value by SDK read-back for light/medium/full and back, line state, the top-screen view (screenshot tests\shots\friends-live-*.png showing map + times), EXIT puts everything back and returns to the main screen. Keep the offline parts as a separate section that always runs. Add it to tests\run-all.ps1 with away = $true.
Files: src\guest.cs, src\testdrive.cs (only if needed), dash\src (guest state/endpoint only if needed), dash\www\v2\guest.js/guest.css (+ index.html hook only if needed), tests\friends-test.ps1, new tests\friends-live-test.ps1, tests\run-all.ps1, docs\USER-GUIDE.md (Friends section, plain English).
Gate: friends-test 0 FAIL; friends-live-test 0 FAIL when Peter is away (if he is not, finish everything else, mark the live part PENDING with the exact command, and say so in NEEDS PETER); screenshots show the track map and the three times; log lines prove the wheel read-back; nothing written to iRacing's own files.
Review: FIXED 2026-10-10 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â friends-test 19/0, friends-live offline 21/0. Live Test Drive PENDING until Peter has been away 10 minutes: powershell -ExecutionPolicy Bypass -File tests\friends-live-test.ps1. Wheel read-back and the racing line are still unproven in the sim.

## C-24 Friends mode - make the live test truthful (it hid failures and judged by a read-back that real driving contradicts) - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live + away
Status: done 2026-10-10 (live part run by the lead 17:27: friends-live 36 passed / 0 failed - real-session map within 30 s, three times, wheel feel sent for Light/Medium/Full, EXIT restore 46.2 read back; racing line not proven -> C-25)
Facts:
1. Peter DROVE real sessions with the C-23 build (Test Drive 14:08-14:10, races 13:27 and 14:30) and reports: the guest wheel strength WORKED (Light / Medium / Full felt different) and the track map SHOWED on the top screen. So do NOT change the wheel values or formula (feel 8 / 14 Nm -> max force 266.8 / 152.5 Nm, Full = his own 46.2) and do NOT rewrite the map code. Anything that works for him stays as it is.
2. tests\friends-live-test.ps1 (pits only, 14:38-14:55) reported failures that real driving contradicts:
 a. irdeck.log: `guest: wheel did not stick (wanted 266.8 Nm, sim reads 46.2)`. SteeringWheelMaxForceNm read 46.2 whatever was sent (also in Peter's own drive at 14:09, where the torque values in the log do change per step), so that variable is NOT proof of the applied strength (it may show the device maximum).
 b. tests\shots\friends-live-top.png was taken seconds after "in the car" and shows no map; in Peter's drives the map showed. The map probably appears a few seconds into the session (first frame / outline load).
3. The test hid its own failures: `Assert-Wheel` calls `Check` inside a function that returns `$m`, so its ok/FAIL text went into the return value or Out-Null. The script ended "32 passed, 2 failed" while tests\last\friends-live.txt and run-all showed "31 ok, 0 FAIL (exit 1)".
Do:
A. Harness first: make `Check` print with Write-Host (or anything that cannot be captured) in friends-live-test.ps1 and every other test with the same shape (grep for functions that call Check and also return a value); make tests\run-all.ps1 count a non-zero exit code as at least 1 FAIL and print the test's own "N passed, M failed" line instead of counting ok/FAIL text; add a tiny offline test proving a failing Check inside a value-returning function still shows up.
B. Wheel honesty, not wheel changes: stop treating the SDK read-back of SteeringWheelMaxForceNm as proof. Find what really shows the applied strength (the per-step torque numbers in irdeck.log, SteeringWheelTorque against steering input, any other SDK variable, iRacing's FFB manual; web search allowed, no downloads) and make the "did not stick" / "drifted" warnings and the test checks use it, or remove them if nothing in the pits can prove it. The top-screen line must not say "wheel reads 46 Nm" under a Medium feel: show the feel name only unless a real proven read exists. Keep the restore proof (after EXIT the sim reads Peter's own 46.2 - that one is valid and stays).
C. Map in the live test: wait (poll up to 30 s after "in the car") for the map to appear, then take the picture and pixel-check it; fail with the picture if it never does. If the map really takes several seconds to appear after START, make it appear as early as possible (outline loaded at session start) WITHOUT changing what works.
D. Racing line: state what can be proven out of the car (key sent, state) and put one plain question for Peter in NEEDS PETER: did the line show on track in his drives? Do not claim it works until he says so.
Files: tests\friends-live-test.ps1, tests\friends-test.ps1, tests\run-all.ps1 (+ any other test with the same shape), src\guest.cs (only the warning text/checks), dash\www\v2\guest.js (only the wheel text line and map timing if needed), docs\USER-GUIDE.md.
Gate: the harness test proves a hidden failure now shows; friends-live-test live part 0 FAIL (restore proven, map found, three times shown); wheel values and formula unchanged (diff shows no change to the numbers); the report lists exactly what is proven and what waits for Peter.
Review: NEEDS LEAD 2026-10-10 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â code matches the card. Live Test Drive not run (sim on track). When Peter has been away 10 minutes: powershell -ExecutionPolicy Bypass -File tests\friends-live-test.ps1

## C-25 Friends racing line - it never showed on track - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live + away
Status: open (2026-10-10 20:07 lead: build + review could not prove the line out of the car - pit cockpit shots differ <1%, track shots confounded by camera cuts; ctrl+alt keys DO reach the sim (mirror, wipers); binding ctrl+alt+l unchanged. WAITING for Peter's 30-second drive check before re-queueing.)
Facts (irdeck.log 2026-10-10): 14:08:12 `go: in the car`, 14:08:13 START sent `key ctrl+alt+l sent to iRacingSim64DX11` ("racing line on"); Peter then pressed LINE twice (14:08:38 "off", 14:08:39 "on"); 14:10:14 sent again on leaving ("off"). Same pattern at 14:54 in the live test. tests\last\friends-live.txt: "Toggle Driving Line is bound to ctrl+alt+l (type=6 bound=4 vk=76 mod=60)". Other combos sent the same way DO work in the sim (ctrl+shift+f2 reset-run, esc for tow). The line state Paddock shows is only a flag it flips itself: there is no read-back.
Likely causes, check each with evidence (do not guess): (1) the START press 1 s after "in the car" is ignored (car not ready / sim not focused), so Paddock's flag and the sim disagree from then on - Peter's two presses then end where they started; (2) the toggle state persists in iRacing between sessions, so "send once at START" can turn it OFF; (3) ctrl+alt is read as AltGr on his keyboard layout, or the binding (mod=60) needs left/right modifiers or scancodes that SendCombo does not give; (4) iRacing only draws the driving line in some sessions / with an option enabled (read iRacing's docs and forums - web search allowed, no downloads). Never write iRacing's files or controls: if a binding or an iRacing option must change, stop and write NEEDS PETER with the exact steps.
Goal: one press (or START itself) reliably shows the line, and the deck/top-screen state matches what the sim really draws. Prove it with pictures of the sim while the rig is free and Peter is away (a Test Drive; find a camera/view or spot where the line is visible from the pit box, or compare before/after screenshots of the same view, both directions). If the line truly cannot be seen without driving, say so plainly and write a 30-second check for Peter (exact presses, what he should see).
Files: src\guest.cs, src\irdeck.cs (SendCombo / CmdKey only if the send is the cause), tests\friends-live-test.ps1, docs\USER-GUIDE.md.
Gate: picture proof of line on AND off in the sim (tests\shots\line-*.png), friends-live-test 0 FAIL by its own summary line, or a plain "cannot be proven without driving" plus Peter's check.
Review: NEEDS LEAD 2026-10-10 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â no code change; line shots do not show the line on and off; friends-live offline 22/0, live PENDING (Peter not away). Test Drive dialog still open.

## C-26 RESET CAR finishes the job after a crash (waits for the car to stop) - fast ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: done 2026-10-10 (lead: deployed irdeck + irdash 23:31; tow-wait-test 26 passed / 0 failed after the lead fixed the test's unquoted comma lists; real tow in a session still to be seen on Peter's next crash)
Goal: one press right after a crash always ends with the car back in the pits: if the car is moving, wait (up to about 20 s, polling Speed) until it is nearly stopped, then do the normal tow; repeat presses during the wait do nothing (the key holds its mutex; Stream Deck sends 2-3 presses); if it never stops, give up quietly with a log line. Show it on the top screen while waiting (Friends drive view and the normal dashboard: one calm line such as "Back to the pits when the car stops", no popup on the race screens). Do NOT change the deck add-on (plugin.html) - that needs Peter's Install click. Keep the existing stationary path exactly as it is.
Files: src\irdeck.cs (CmdTow), src\guest.cs (reset), dash (status line only), tests (offline: the wait logic with a pretend speed; live with Peter away: stationary tow still works).
Gate: offline test 0 FAIL by its own summary line; live stationary tow still "back in the car in the pits"; the moving case written as a one-line drive check for Peter in NEEDS PETER.
Review: NEEDS LEAD 2026-10-10 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â irdeck and the 26 keys are deployed. irdash is not, and tow-wait-test was not run: the sim process started as the irdeck build finished (telemetry still off). When the sim is off: dash\build.ps1, then tests\tow-wait-test.ps1. Live tow only after he has been away 10 minutes with the car stopped.

## C-27 After-race review: laps must appear while he is still in the sim (C-07 follow-up) - fast ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: partly 2026-10-11 - code written and compiled with -NoDeploy (not deployed). Problem 2 and the restart check are proven (review-test sections 4 and 6 pass: 50 passed, 1 failed - the 1 is section 5, which needs the new irdash). Problem 1 (read the finished session's file while the sim is still open) is NOT proven live: deploy dash\build.ps1, then run tests\review-test.ps1 and look at tests\shots\c27-strip.png. (was: open, lead 2026-10-10 17:12, from the C-07 review: VERDICT NEEDS LEAD. C-07 itself is deployed and review-test passed 40 / 0.)
Also (lead 18:34): right after an irdash restart the log says "vault: after-race review is up (60000 ms, 0 laps)" with no race just finished - check the strip does not appear after a restart / with no session.
Problem 1: the Vault reader waits 120 s and skips the newest .ibt while iRacingSim64DX11 is running. After a real race Peter is usually still in the sim (results / replay), so the after-race strip stays on "Checking which laps were saved" and the laps never show before the debrief closes. Fix: once the session is over (not on track, session state finished / the SDK session link down) and the newest .ibt has stopped growing (same size for a few seconds), read it at BelowNormal priority - never while he is on track or in a running session (CLAUDE.md: no newest-.ibt reads during a session).
Problem 2: if he closes the practice summary first and only then leaves the session, the strip does not come back. Make it appear in whichever debrief view is showing when the laps are ready.
Files: dash\src\vault.cs, dash\src\wheel.cs (only if needed), dash\www\v2\debrief.js, tests\review-test.ps1 (+ a pretend "session over but sim still running" case).
Gate: review-test 0 FAIL by its own summary line, including the new case: pretend session ends with the sim process still running -> laps appear in the strip within 30 s; picture tests\shots\c27-strip.png.

## C-28 Fix what the lead's full test run found (results window over Home, outdated actions checks, bench and gallery FAILs) - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live + away
Status: done 2026-10-10 (lead: results modal reports its unselected tabs as not enabled - lead fixed UiResultsOpen 21:57; actions-test 29 passed / 0 failed 22:02 with a real AI race; gallery 85/0; bench 49/0)
Clean: perf, pbdelta, overlays, dialog, friends, harness, replay, mydrive, deckspeed, doctor, official, tv, vault, review, corners, data (rerun 136/0), friends-live 36/0.
1. RESULTS WINDOW OVER HOME (real, new iRacing UI - the same update renamed the Test Drive dialog's Close to Back). After QUIT TO MAIN from an AI race (18:42) irdeck logged "quitmain: back on the main screen" at 18:42:27, but iRacing then showed a modal "Results" window (AI Race, Results / Event Log / Lap Graph / Lap Chart tabs, an X at its top right, a greyed "Back" at the bottom right) and it was STILL over Home at 18:56 after two more sessions. Picture: tests\shots\lead-results-over-home.png. `irdeck-cli uilist` (read-only) shows the tabs and `Hyperlink Back [2409,1294]`; the X is not in the named list. actions-test failed 4 checks on it ("the iRacing UI shows Home with nothing over it", "the sim is not running a session any more"). Fix LeaveToHome (src\actions.cs): after a race/AI session wait long enough for that window, close it by its real close control (find it in the accessibility tree; verify the window before any click, CLAUDE.md rule 4), then confirm Home. Keep the older results page path working.
2. tests\actions-test.ps1 is outdated: line 152 expects the old log "wheel light = 8 Nm (yours N)"; C-23 changed it to "guest: wheel light feel 8.0 Nm -> max force 266.8 Nm, sim reads 46.2 (yours 46.2 ...)". Update the check (not the product). Update its UiHome to the current UI if needed (it must still fail when a results window or dialog is over Home).
3. bench-test: FAIL "the real card shows your real best lap, and a real-world line with its official source" in both runs today (18:12 and 18:35), so it is not the session clash. Find out why (data changed today? Vault? real-world source missing?) and fix the product or make the check honest - do not weaken it.
4. gallery-test: FAIL "the screens fade rather than cut: 39 in-between steps, 3 big ones, largest step 9.1" (18:55; the Vault backfill had finished at 18:46, so not that). Rerun it a few times with Peter away; if the fade really stutters on the side screens, fix it; if the check is too tight for normal timing, say so with numbers before changing it.
Files: src\actions.cs, tests\actions-test.ps1, tests\bench-test.ps1 (+ the product file if the cause is there), dash\www (gallery) only if the fade really stutters.
Gate: run-all -Only actions,bench,gallery with Peter away: each 0 failed by its own summary line, plus a picture of Home with nothing over it after QUIT TO MAIN from an AI race.
Review: NEEDS LEAD 2026-10-10 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â results close and the checks look right; bench 49/0. Actions and gallery were not run (Peter on track). When he has been away 10 minutes: tests\run-all.ps1 -Only actions,gallery, then a picture of Home with nothing over it after QUIT TO MAIN.

## C-29 Quick wins from the design review: no dead buttons, no empty charts, no overlaps, no self-compare - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: partly 2026-10-11 - both failures fixed in dash\www\v2\vault.js (served live, no deploy needed) and proven: quickwins-test 35 passed, 3 failed; the 3 are the Pi Toolbox checks, which need the new irdash (Pi Toolbox is really installed now, so the test pretends it is absent with /vault/test/cosworth?on=0, a route change that is compiled but not deployed). After the deploy: quickwins-test, vault-test (86 passed, 1 failed - the same Cosworth check) and review-test must show 0 failed. (was: open, lead 22:58: review NEEDS LEAD - quickwins-test 33 ok / 2 failed after the reviewer deployed: (1) after a clip is attached the Vault lap page never finishes loading (qw-lap.png shows only the title and the map; the lap column never appears, so "No other lap to compare yet" never shows); (2) the comparison label shows the PREVIOUS lap page's comparison ("Your best - lap 7 - 1:19.549") because V.refInfo is kept until /vault/laps returns - clear it when a page opens. Everything else in C-29 passed; fix only these two, rerun quickwins-test, vault-test, review-test.)
Checks first (write them into a new tests\quickwins-test.ps1 before changing code; headless Chrome at 1920x1080, real irdash, test hook / scratch vault):
1. Vault lap page: with Pi Toolbox not installed (/vault/list "cosworth":{"installed":false}) there is NO "OPEN IN COSWORTH" button in the DOM. With a pretend installed flag it is there.
2. Vault: no CLIP / video control or "clip" wording anywhere while no recorder exists (no clip files); the same lap is ONE card (a lap and its clip moment merge into one card with a video badge when video exists).
3. Lap page: the default comparison is never the lap itself (not the same session file + lap number); with no other lap of that car+track it says "No other lap to compare yet" and shows no delta trace.
4. After-race debrief (debrief.js): no text box overlaps another (measure every visible text element's bounding box, 0 overlaps); the LAP TIMES chart only appears with 5 or more laps; with fewer than 3 clean laps the "WHERE THE TIME IS" area says "Drive 3 clean laps to see where the time is" instead of "Very consistent".
5. Pictures: tests\shots\qw-lap.png, qw-grid.png, qw-debrief-1lap.png, qw-debrief-race.png (the lead looks at them).
Files: dash\www\v2\vault.js/vault.css, dash\www\v2\debrief.js/debrief.css, dash\src\vault.cs only if the merge needs it, tests\quickwins-test.ps1, tests\run-all.ps1 (add 'quickwins').
Gate: quickwins-test 0 failed by its own summary line; vault-test and review-test still 0 failed.
Review: NEEDS LEAD 2026-10-10 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â quickwins 33 ok, 2 failed. After a clip is attached the lap page stalls (qw-lap.png is title and map only, so the empty-state sentence never shows). vault-test and review-test not run.

## C-30 Analysis engines: distance alignment, corner metrics, cause words, reference + optimal + goal (offline) - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· offline
Status: done 2026-10-10. LEAD NOTE 21:20 from the mockups on real data: (a) /vault/lap sends throttle/brake in % and steering in degrees - raw .ibt Throttle/Brake are 0..1 and SteeringWheelAngle is radians; never mix them; (b) lap distance wraps a few samples late/early at the start/finish line, which made the first/last 2 % of single laps look up to 0.1 s quick: handle the wrap before mini-sectors or optimal; (c) the optimal lap must be checked against best S1+S2+S3 (Road Atlanta 10 Oct: 1:19.269 vs best 1:19.549).
Build in a new dash\src\analysis.cs (C# 5, no libraries), callable from irdash, plus a JSON route /analysis/lap?id=..&lap=..&ref=pb|optimal|<id:lap>.
1. Resample any lap of an .ibt to 1 m steps by LapDistPct x track length (track length from the session YAML); skip pit/out/in laps and laps with off-track/invalid flags; same lap twice = identical arrays.
2. Corner segments from the existing corner model (dash\src\corners.cs names); per corner: time, brake point (first Brake > 0.10 before the apex), minimum speed and its distance, throttle pickup (first Throttle > 0.90 after the apex), exit speed 100 m after the apex.
3. Per corner vs the reference: time gained/lost and every metric difference as NUMBERS (brake point m, min speed km/h, pickup m, exit speed km/h). A cause sentence ONLY when the data is unambiguous (Peter 20:45: "only insights if natural, reliable and data-driven, not imagination"): one metric differs clearly (brake point >= 5 m, min speed >= 3 km/h, pickup >= 10 m, exit >= 3 km/h) AND the loss sits in that part of the corner; otherwise no sentence. The test must include a corner where no sentence is produced.
4. Reference store per car+track: the PB lap (never the lap itself), the optimal lap (best segments joined, with its total), and the goal of section 3.1 ("Next: 1:19.4 - in your best corners (T10a 0.18, T1 0.09)").
Checks (write first, tests\analysis-test.ps1, on COPIES of 3+ real .ibt from Documents\iRacing\telemetry - never the newest while the sim runs, BelowNormal): sum of corner times + straights = lap time within 0.05 s; resampling the same lap twice is identical; the lap vs itself has 0.00 everywhere; for Peter's Road Atlanta Corvette PB (1:19.549) vs his 1:19.878 lap the biggest loss corner, its time and cause are printed and the lead checks them once by hand (write the checked numbers into the test); optimal <= PB; the goal string is produced.
Gate: analysis-test 0 failed by its own summary line; nothing on screen changes.
Review: FIXED 2026-10-10 ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â analysis-test 43 ok, 0 failed. Thirds 79.269 and iRacing sectors 79.152 are locked. The 24-slice optimal stays 78.125. Not deployed.

## C-31 Stream Deck v2 MAIN + MORE (prepare only) - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· offline
Status: done 2026-10-10 (prepared only - build-deck.ps1 + irdeck changes; NOT built into the profile: the lead runs build-deck.ps1 with Peter. Pictures tests\shots\deck-v2-main.png / deck-v2-more.png; keys-test 82 passed, 0 failed; report docs\tasks\log\C-31.md) (Peter approved the Stream Deck 2026-10-10 23:30. Build the CORRECTED MAIN grid in docs\research\deck-v2-review.md (C-36) with one lead change: RESET CAR waits for the car to stop (C-26, Peter's ask) and its key shows WAITING meanwhile. VOL = iRacing + spotter (appvol game); a SOUND details page (C-39) sits behind it. Prepare + -Preview only; the lead runs the real build with Peter.)
Gate: build-deck.ps1 -Preview pictures match deck-v2.png key by key (the lead compares); keys-test (C-32) 0 failed.

## C-32 keys-test: every Stream Deck key answers, no dead keys - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· offline
Status: done 2026-10-10 (tests\keys-test.ps1: 82 passed, 0 failed, 2 warnings = the add-on's dead AI RACE tile and one over-long label; table in tests\last\keys.txt; in run-all as 'keys'; report docs\tasks\log\C-32.md) (lead 2026-10-10 22:40; Peter: "make sure all tested ... use all buttons maximally and organized")
New tests\keys-test.ps1 (no clicks, no sim): read keys\keys.map and build-deck.ps1 (MAIN + MORE) and deck-intro\plugin.html (FRIENDS, OVERLAYS, MY DRIVE, REPLAY screens): every key has a command; every irdeck command exists in src (the switch in irdeck.cs / its handlers); every add-on action is handled by irdash (/api/do whitelist or the guest/mydrive/replay routes); every live key's data field exists in irdash's JSON; no two keys on one page do the same thing; every label is at most 2 short lines; a dry run (`irdeck-cli <cmd> --dry` where supported, or the command's refusal when no session) returns without an exception. List any key that does nothing. Add to run-all.
Gate: keys-test 0 failed by its own summary line; a table of all keys with page, position, command, status in tests\last\keys.txt.

## C-33 RACE SETUP deck screen (MY DRIVE v2) - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live (add-on: Peter clicks Install)
Status: partly 2026-10-11 (built in C-42, offline: LAST DRIVE, USUAL, SURPRISE, FAVOURITES, SAME CAR, SAME TRACK, search, damage, layout, star, START; tests\deck-screens-test.ps1 + mydrive-test -DeckOnly -Offline 0 failed, pictures tests\shots\deck-racesetup-*.png; NOT installed yet - lead + Peter's Install click. Still off: MOST TO GAIN (waits for irdash to send "gain"), CLASS, MAPS, THIS WEEK, AI words (C-35). Report docs\tasks\log\C-42.md). Was: held - waits for Peter's yes (lead 2026-10-10 22:40). Spec: docs\research\deck-race-config-ideas.md "Best five" + the RACE SETUP grid, with the lead's changes: BEAT PB becomes MOST TO GAIN (car+track with the biggest optimal-vs-PB gap from /analysis, never a real-car time); AI words only after C-35 verifies each control; THIS WEEK off until official racing is trusted.
Gate: mydrive-test + a new race-setup section 0 failed; pictures of every page; START still the only key that touches the sim.

## C-34 Corner deep-dive engines from the full .ibt channel list - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· offline
Status: done 2026-10-11 (all 9 engines in dash\src\deepdive.cs, route GET /analysis/deep, tests\analysis-test.ps1 116 passed, 0 failed; NOT deployed - the route goes live with the next dash\build.ps1 deploy; the road-wheel understeer angle and balance flags stay hidden until a sourced steering ratio is put in CarTable; log docs\tasks\log\C-34.md). Was: open (lead 2026-10-10 22:40). Channels exist (docs\research\ibt-channels.md, checked on Peter's files). Extend dash\src\analysis.cs + /analysis routes, offline tests on COPIES of 3+ real .ibt, BelowNormal:
1. Lock-up / wheelspin per corner: each wheel speed (LFspeed..RRspeed) vs car Speed; events with distance, wheel, duration.
2. ABS activity per corner (BrakeABSactive, BrakeABScutPct): share of braking zone, peak cut.
3. Braking profile: peak brake, time to peak, release (trail) duration while steering, brake-to-throttle coast time.
4. Wheel clipping: share of each corner with SteeringWheelPctTorque >= 0.98 (and SteeringWheelMaxForceNm).
5. Racing line: Lat/Lon of two laps resampled by distance; lateral offset (m) per corner; turn-in and apex positions.
6. g-g points (LatAccel, LongAccel) per corner.
7. Tyres per stint: surface (L/M/R) and carcass temps, pressures, wear at stint end; 8. car-setting changes during the session (dcBrakeBias, dcTractionControl, dcABS) with lap times before/after. 9. Car balance per corner (what pro engineers check): steering angle vs the steering the car needs for its yaw rate at that speed (understeer / oversteer estimate from SteeringWheelAngle, YawRate, Speed, LatAccel), entry / mid / exit, shown as numbers vs the reference lap (Peter 22:55 asked what pro teams look at).
Numbers only; a sentence only by the C-30 thresholds. Each item has a test that checks one hand-verified number on a real file.
Gate: analysis-test (extended) 0 failed by its own summary line.

## C-35 AI race setup survey - what iRacing's AI dialog lets us set (read-only) - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· away
Status: partly (lead 2026-10-11 00:20: wizard mapped - 9 steps with stable AutomationIds, sessions / weather / race options read, pickers = Test Drive pickers; AI Opponents / Time of Day / Track Conditions need a car+track chosen with lookups SCOPED TO THE MODAL (the background page has matching rows). See docs\research\ai-dialog.md. iRacing left on Home, nothing started.)
Gate: the doc + pictures; iRacing left on Home with nothing over it (picture).

## C-36 Stream Deck v2 sense-check against real products (research, Grok) - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· offline
Status: done 2026-10-10 (Peter 2026-10-10 22:55: "stream deck confirm with grok, reference real products and sense check usability and value"). Review: docs\research\deck-v2-review.md. No deck files changed. Read docs\mockups\deck-v2.html (the proposal), build-deck.ps1, deck-intro\plugin.html, docs\research\user-wishlist.md, docs\research\deck-race-config-ideas.md. Research (web, sources required, no downloads): real sim-racing Stream Deck products and profiles (Elgato marketplace iRacing profiles, iRaceDeck, SimHub Stream Deck plugin, Fanatec plugin, popular button-box layouts, RobertsmaniaReplay controller profile) - which keys they put first, how they group them, what users praise or complain about. Then sense-check the proposal key by key for usability (one press, no dead keys, readable, muscle memory, dangerous keys guarded) and value (used every session vs rarely). Write docs\research\deck-v2-review.md: what to keep, change, move, add, drop, each with the reason and a source where possible, plus a corrected 8x4 MAIN grid. Do NOT change build-deck.ps1 or plugin.html.
Gate: the review doc; the lead decides and shows Peter the final picture.

## C-37 Events list with PAUSE and JUMP (analysis + replay) - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: held until the Session Review / Lap Analysis screens are approved (lead 2026-10-10 22:55; Peter asked for it).
Every session gets an EVENTS list built from data that exists: incidents (PlayerCarMyIncidentCount steps), off-tracks (PlayerTrackSurface), lock-ups / wheelspin and ABS events (C-34), spins (yaw rate), pit stops, PB / best laps, and in races position changes and overtakes from Paddock's all-cars live log. Each event: time, lap, corner, type. Deck keys on the ANALYSIS screen: ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚ÂÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ EVENT, EVENT ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã¢â‚¬Å“ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¶, PLAY / PAUSE, JUMP (moves the analysis cursor and the video there; if the session's replay tape is still loaded in iRacing, jumps iRacing's replay there by SDK ReplaySearchSessionTime with a chosen camera). Tests on real .ibt + a pretend session; live replay jump with Peter away.

## C-38 SHARE a lap or clip - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: held until the recorder (C-06) exists (lead 2026-10-10 22:55; Peter asked for text, social media and YouTube).
SHARE (deck key, outside sessions only): export the clip as MP4 (1080p, his lap, optional small overlay: car, track, lap time, gap) and a still picture into vault\share\; then open Windows' own Share panel for that file (Phone Link / text, mail, apps) - or, for YouTube, open YouTube's upload page in his browser with the file ready. Paddock NEVER posts or uploads by itself and never handles his passwords: he presses the final Publish/Send himself. No popup while driving.

## C-39 SOUND page on the Stream Deck - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live (add-on: Peter clicks Install)
Status: done offline 2026-10-11 (C-42: SOUND screen on MORE at 5,0, irdeck `sound` command, irdash /sound; tested on a pretend audio list, 0 failed in tests\deck-screens-test.ps1; real devices only read, nothing changed. NOT installed yet: lead runs build-irdeck + dash\build + install.ps1, Peter clicks Install; check the ButtKicker column by ear. Report docs\tasks\log\C-42.md). Was: open - Peter approved 23:30 ("vol for game sound but secondary details screen behind it")
A live SOUND screen: per-app volume with a level shown on the key (iRacing game, CrewChief spotter, Spotify music - `appvol` already exists in irdeck), mute per app, master volume of the speakers device (Speakers, Realtek USB2.0 - iRacing and CrewChief play there), ButtKicker level (its own output device), presets (RACE: spotter up, music off; CRUISE: music on, spotter low; NIGHT: everything lower), and which device is in use. Never change Windows' default device or any Windows setting by itself. Test with a pretend audio session list.

## C-40 Session Review v2 - replaces the old debrief, on the workbench engine - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live
Status: deployed 2026-10-11 (irdash 00:59 + 02:19 fix: IsDriving read a 2 s cached flag so the review was dropped right after a session - now live, docs\tasks\log\regressions-20261011.md; session-review-test 108 passed / 0 failed 03:2x). Still to see: the review appearing after Peter's next real session. Was: partly done - built and tested offline (tests\session-review-test.ps1: 108 passed, 0 failed, pictures tests\shots\sr-*.png); the lead deploys, then runs the live checks in docs\tasks\log\C-40.md (lead 2026-10-11 00:15; design approved in principle - docs\mockups\session-review.png; engine = Fable's W1 dash\www\v2\workbench.js + /analysis/channels).
After every session the top screen shows the Session Review of docs\mockups\session-review.html (A in DESIGN-analysis.md), built from real data through the workbench data path: identity band (car number plate, PETER, team, car, track + length, session, date), timing table (lap, time, S1-S3 from iRacing's sectors, a mini-sector strip coloured purple / green / yellow, gap, OUT/IN/OFF), map coloured by gain/loss of the best lap vs his reference (never itself), optimal = best iRacing sectors joined, consistency (best-5 average, spread), lap chart only with 5+ laps, at most 3 data notes by the C-30 thresholds, the existing "laps saved - KEEP ALL / CHOOSE" bar (C-07/C-27 code), and ANALYSIS (opens workbench.html on this session's best lap). Fewer than 3 clean laps: best lap + "Drive 3 clean laps to see where the time is". Nothing appears while he drives; it replaces debrief.js's summary (keep the race extras).
Checks first (tests\session-review-test.ps1, offline fixture from a real .ibt + live page): every number equals iRacing's (lap times to 0.001, sectors), no text overlaps, purple/green/yellow rule, no self-compare, empty state; picture tests\shots\sr-*.png compared by the lead with session-review.png.

## C-41 Workbench pages BRAKING, TYRES & STINT, SUSPENSION, SPLITS + channel picker - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· offline then live
Status: done 2026-10-11 (workbench-test 166 passed / 0 failed via tests\run-all.ps1 -Only workbench; pictures tests\shots\wb-braking / wb-tyres / wb-suspension / wb-splits / wb-picker.png; deployed with dash\build.ps1 and checked live; analysis-test 116 / session-review-test 108 still 0 failed; report docs\tasks\log\C-41.md. NOT built: real bump-stop contact (no bump-stop channel and no sourced per-car value; SUSPENSION shows 'on the ground' = ride height 1 mm or less instead) - lead decides, see NEEDS LEAD 1). Was: open (lead 2026-10-11 00:15). Spec: docs\DESIGN-workbench.md section 3 + docs\research\pi-toolbox-features.md (Cosworth's iRacing Plus worksheets: Throttle/Brake Analysis, Tyre Data, Tyre/Fuel Usage/Pit Lane, Damper Displacement/Velocity, Roll/Pitch/Ride Height/Aero, Splits). Build on dash\www\v2\workbench.js (PAGES entries + buildPage branches) and the C-34 engines. Add the searchable channel picker (initials search like Pi: 'LG' = Lateral G; any of the 288 channels as a new trace row). Tabs appear only for pages that work (no dead tabs).
Checks: workbench-test extended (each page renders from a real lap, numbers hand-checked once, no overlaps, cursor/zoom shared), pictures wb-*.png for the lead.

## C-41b Workbench fixes after the lead's review of the C-41 pictures (lap 4 INVALID, BEST row colours, dim carcass/tread, LOWEST AT, deck page keys)
Status: done 2026-10-11 (workbench-test 178 / 0, session-review-test 110 / 0, deck-screens-test 194 / 0, analysis-test 116 / 0, keys-test -StaticOnly 61 / 0). Log: docs\tasks\log\C-41b.md. The add-on change (WB_PAGES + page-key layout in deck-intro\plugin.html) is NOT installed: the lead batches it with 1.7.0.0.

## C-42 Add-on batch: ANALYSIS deck screen, SOUND page, RACE SETUP, two fixes - strong ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â· live (Peter clicks Install once)
Status: done offline 2026-10-11 (keys-test -StaticOnly 61 passed / 0 failed, no warnings; deck-screens-test 187 passed / 0 failed; mydrive-test -DeckOnly -Offline 24 / 0; pictures tests\shots\deck-*.png; add-on 1.7.0.0 prepared, NOT installed, MAIN not rebuilt: the lead deploys irdeck + irdash, runs install.ps1 (Peter clicks Install) and build-deck.ps1 - exact steps in docs\tasks\log\C-42.md). Was: open (lead 2026-10-11 00:15). In deck-intro\plugin.html: (1) ANALYSIS live screen driving the workbench through /api/do?c=wb-<cmd> (Fable's command list in docs\tasks\log\W1-fable.md): BACK, pages, ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚ÂÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ LAP ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã¢â‚¬Å“ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¶, ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚ÂÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ CORNER ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã¢â‚¬Å“ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¶, ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚ÂÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ EVENT ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã¢â‚¬Å“ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¶, PLAY/PAUSE, speed, ZOOM ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â±, REF cycle, TILE, OFFSET AUTO, MAP colour, OPEN IN COSWORTH (only when Pi Toolbox is installed - it is), KEEP; (2) SOUND page = card C-39; (3) RACE SETUP = card C-33 (only Test Drive parts; AI words wait for C-35); (4) fix keys-test's two warnings: remove the dim 'AI RACE coming later' tile on MY DRIVE, shorten the PHOTO key's long line. Bump $ver in deck-intro\install.ps1. Do NOT run install.ps1 (the lead does, Peter clicks Install). Then the MAIN ANALYSIS cell gets its real action in build-deck.ps1.
Checks: keys-test 0 failed with the new screens (no dead keys), mydrive/replay/friends tests still 0 failed, pictures of each screen.

## DK-1 One-press AI RACE from Peter's saved preset
Status: partly 2026-10-11 (removed the blind Continue loop; `airace` now routes through a fail-closed command; offline fixtures were not run because state reports sim=True. Wizard values and scoped modal behavior still need an away-time survey; no preset exists until Peter runs `airace save`.)
Gate: `tests\airace-test.ps1` offline 0 FAIL; lead-run live section with `Assert-RigFree -NeedAway`; Peter's one-time `airace save`.

## DK-1s Scoped AI wizard survey command
Status: partly 2026-10-11 (review fixes applied: chooser cleanup is scoped to a verified chooser, every UI press rechecks sim absence, and offline tests call production matching/allowlist helpers. irdeck + dash no-deploy builds passed; guarded airace-test deferred because state reports sim=True. Lead runs the test and live survey in an away window. `airace save` and `start` remain fail-closed pending review of survey evidence.) Fix report: `docs\tasks\log\DK-1s-fix.md`; original: `docs\tasks\log\DK-1s.md`.
Gate: `build-irdeck.ps1 -NoDeploy`; `tests\airace-test.ps1` offline 0 FAIL; lead-run `irdeck-cli airace survey` with `Assert-RigFree -NeedAway`.

## DK-1t Airace survey refuses on a real UI
Status: done 2026-10-11 (unique page lookup counts enabled/on-screen candidates and logs all matching bounds on refusal; survey skips AI Single Player when Single Race is already visible. Offline tests 16/0; irdeck no-deploy build passed. No live UI presses or deploy.) Report: `docs\tasks\log\DK-1t.md`.
Gate: `build-irdeck.ps1 -NoDeploy` and `tests\airace-test.ps1` -> passed.

## DK-1u AI RACE that actually starts a race
Status: partly 2026-10-12 (start path implemented using MY DRIVE/recent combo, scoped modal finder, New Race, exact owned picker rows, scoped Continue flow and four mismatch statuses. No-deploy build passed; offline dump fixtures 20/0. Live wizard run remains for the lead with -NeedAway.) Report: `docs\tasks\log\DK-1u.md`.
Gate: `build-irdeck.ps1 -NoDeploy` and `tests\airace-test.ps1` -> passed; live lead run pending.

## DK-1v AI RACE robust waits + live end-to-end loop
Status: partly 2026-10-12 (AI start path now polls exact UI/session milestones and logs measured wait durations; no-deploy compile passed. Added guarded two-round live harness, not run here per card; lead runs it with Peter away.) Report: `docs\tasks\log\DK-1v.md`.
Gate: `build-irdeck.ps1 -NoDeploy` -> passed; lead-run `tests\airace-live.ps1` pending (writes `tests\last\airace-live-timings.txt`).

## DK-2 New MAIN grid, keys.map, no dead keys, preview picture
Status: done 2026-10-11 (offline: `build-deck.ps1 -Preview` wrote docs\deck\main-preview.png; `tests\keys-test.ps1 -StaticOnly` 66 passed / 0 failed, 0 warnings. MAIN = council-fable section 3; new keys AI RACE, TEST DRIVE, SAVE, TV, HOME, DEBRIEF, VAULT; ANALYSIS moved to MORE; no static on/off subtitles. DEBRIEF/VAULT marked PENDING until DK-5 wires `dash debrief` / `dash vault`. The lead runs the real build-deck.ps1 (Stream Deck closed) when sim=False; Peter gives one yes on the picture. report docs\tasks\log\DK-2.md).
Gate: `build-deck.ps1 -Preview` makes the picture; `tests\keys-test.ps1` 0 FAIL.

## DK-2b Peter's grid changes: OFFICIAL + CAR TRACK
Status: done 2026-10-11 (`build-deck.ps1 -Preview` re-rendered docs\deck\main-preview.png; `tests\keys-test.ps1` full run
104 passed / 0 failed - sim=False so the live sections ran too). MAIN 6,0 (row 1 col 7) = OFFICIAL (`official` command
irdeck already has; K-03 adds the on-deck screen). MAIN 6,2 (row 3 col 7) = CAR TRACK, the MY DRIVE add-on action re-used
(its home screen IS the car/track step; no deeper step can be opened). Everything else unchanged from DK-2. The lead runs
the real build-deck.ps1 (Stream Deck closed) when sim=False to write official.exe; Peter says yes to the picture.
report docs\tasks\log\DK-2b.md).
Gate: `build-deck.ps1 -Preview` makes the picture; `tests\keys-test.ps1` 0 FAIL.

## DK-7 Smart primary key, SKIP SESSION, MY DRIVE START
Status: partly 2026-10-12 (DK-7e uses a same-process SDK tick pair with rollover-safe freshness; deckstate-test 23/0 and build-irdeck -NoDeploy passed. Live AI garage check is in tests\airace-live.ps1 and remains for lead. Reports: docs\tasks\log\DK-7d.md, docs\tasks\log\DK-7d-fix.md, docs\tasks\log\DK-7e.md.)
Gate: `tests\deckstate-test.ps1`, `tests\keys-test.ps1`, `tests\mydrive-test.ps1` 0 FAIL; preview rendered; both -NoDeploy builds pass.

## DK-8 Stream Deck car and track lists with AI no-choice prompt
Status: partly 2026-10-12 (catalog route, list picker, car/track/layout state writes, and automatic NO CHOICE open implemented. Both no-deploy builds pass. Guarded browser tests could not start Chrome; route/test evidence and screenshots remain for lead follow-up. Report: docs\tasks\log\DK-8.md.)
Gate: `tests\deck-screens-test.ps1`, `tests\mydrive-test.ps1`, copy-audit 0 FAIL; `dash\build.ps1 -NoDeploy`.

## DK-8b Picker catalog layouts and debrief deck actions
Status: done 2026-10-12 (recent entries now include cached TrackConfigName layouts; picker paging and return to RACE SETUP pass; debrief actions are registered through Vault; test harness expectations corrected. All requested gates pass. Dash deployed while sim=False. Report: docs\tasks\log\DK-8b.md.)

## DK-8c Deck picker premium layout, list-first car and track flow
Status: partly 2026-10-12 (deck-screens 219/0; mydrive -DeckOnly -Offline 27/0; mydrive -NoSearch -NoStart 57/0; dash build -NoDeploy passed. RECENT/FAVOURITES screenshot appearance of BACK/EXIT remains unresolved; guarded rerun refused while sim=True. Report: docs\tasks\log\DK-8c.md.)
Gate: `tests\deck-screens-test.ps1` and `tests\mydrive-test.ps1 -DeckOnly -Offline` 0 FAIL; `dash\build.ps1 -NoDeploy`.
Gate: `tests\deck-screens-test.ps1` 237/0; `tests\keys-test.ps1` 104/0; `tests\mydrive-test.ps1 -DeckOnly -Offline` 29/0; `tests\copy-audit-test.ps1` 37/0; `dash\build.ps1 -NoDeploy` passed.

## H-01 Official schedule source + parser hardening
Status: done 2026-10-12
Gate: tests\official-test.ps1 source/S4/2027 sections; dash\build.ps1 -NoDeploy. Report: docs\tasks\log\H-01.md

## H-02 His series, ownership, next race
Status: done 2026-10-12
Gate: tests\official-test.ps1 series eligibility / ownership / next race; dash\build.ps1 -NoDeploy. Report: docs\tasks\log\H-02.md

## H-03 Benchmark (yardstick) fix
Status: partly 2026-10-12 (review fix: four benchmark paths now use distinct controlled career-cache combos and assert exact PB seconds, Unix-millisecond timestamps, and history values. No-deploy builds passed. Guarded `tests\bench-test.ps1` was refused by its guard after state changed to sim=True; no deploy. Report: `docs\tasks\log\H-03-fix.md`.)
Gate: `tests\bench-test.ps1` 0 FAIL; `dash\build.ps1 -NoDeploy`; `build-irdeck.ps1 -NoDeploy`; deploy via broker.

## H-05 Real-world calendar fetch
Status: done 2026-10-12
Gate: tests\realworld-test.ps1 offline 0 FAIL; dash\build.ps1 -NoDeploy. Report: docs\tasks\log\H-05.md

## H-06 Preview lines by a cheap model at fetch time
Status: done 2026-10-12
Gate: tests\realworld-test.ps1 preview sections 0 FAIL; dash\build.ps1 -NoDeploy. Report: docs\tasks\log\H-06.md. Live provider left off.

## SCHED-2 Race schedules visible on HOME, end to end
Status: partly 2026-10-12 (HOME schedule data/layout and official/real-world adapters implemented; deployment broker returned exit 0. Official 191/0, realworld 49/0, copy audit 37/0. HOME run reported 96 passed / 1 failed despite its browser assertions all passing; rerun was held by another live test lock. Visual review caught literal entity separators; source corrected and needs a fresh screenshot. Only one real-world event fell inside the specified seven-day window. Report: docs\tasks\log\SCHED-2.md.)
Gate: home-test, official-test, realworld-test, copy-audit-test all 0 FAIL; screenshots tests\shots\home-v4*.png.

## SCHED-3 Real-world calendar sessions
Status: partly 2026-10-12 (TLS startup, Jolpica F1 session parsing, Windows local time, 15-day filtering, HOME session rows and class labels changed. C# build passed; realworld-test 50/0; copy-audit source-only 12/0. HOME test failed its real-event block because the live cache only has a WEC `Event` placeholder, now suppressed. Live source probe: Jolpica 200; IMSA 403; WEC/GTWC Europe/GTWC America 200. Not deployed; premium visual sign-off and complete official session adapters remain.) Report: docs\tasks\log\SCHED-3.md.
Gate: realworld-test, home-test, copy-audit-test 0 FAIL; live fetch returns this weekend/next 14 days' real sessions; tests\shots\home-v4-idle.png with real events; dash\build.ps1 deploy after visual review.

## SCHED-4 WEC, IMSA, GTWC session times
Status: partly 2026-10-12 (added separate GTWC America parsing/fetch path and fixture coverage; `realworld-test.ps1` 52/0; `dash\build.ps1 -NoDeploy` passed. Live source review found WEC Barcelona session times for Oct 16-18, but IMSA COTA is Oct 23-25 and the available IMSA page has no matching upcoming session-time table; GTWC Europe and America seasons are complete. SRO session timetables are on event pages, not calendars. Existing WEC parser still only reads calendar event dates. No deploy/cache deletion.) Report: `docs\tasks\log\SCHED-4.md`.
Gate: realworld-test per-source fixtures and live current/next-weekend checks; deploy via broker after fresh source data is parsed.

## SCHED-5 WEC / IMSA / GTWC sessions via public ICS calendars
Status: done 2026-10-12 (public RaceTagger ICS feeds parsed and live checked; realworld-test 56/0 offline and 57/0 live; fresh HOME cache retained Jolpica F1; deploy broker exit 0. HOME browser check awaits shared test lock.) Report: `docs\tasks\log\SCHED-5.md`.
Gate: `tests\realworld-test.ps1` offline and `-Live` -> 0 FAIL; `dash\build.ps1 -NoDeploy`; deploy via broker; `/realworld` returns timed sessions.

## DK-3 Confirm, MY DRIVE choices, and GO process check
Status: partly 2026-10-11 (source changes and compile gates complete; guarded tests not run because `state` reported sim=True and onTrack=True; lead runs tests and deploy when sim=False).
Gate: `tests\confirm-test.ps1` and the focused MY DRIVE checks 0 FAIL; `build-irdeck.ps1 -NoDeploy`; `dash\build.ps1 -NoDeploy`.

## T-01 TV data engine
Status: done 2026-10-12 (review fixes: battle timers now reset across class changes; sampler-synchronized regression coverage 19/0; both no-deploy builds passed. Redeploy blocked because `dash\irdash.exe` was in use. Report: `docs\tasks\log\T-01-fix.md`.)
Gate: `tests\tv-test.ps1` 0 FAIL; `dash\build.ps1 -NoDeploy`; `build-irdeck.ps1 -NoDeploy`.

## T-01b TV ordering and live-race timing
Status: partly 2026-10-12 (derived running order and adjacent/disjoint battles implemented; dash no-deploy compile passed. Guarded fixture replay was not run because state reports sim=True / onTrack=True. Report: `docs\tasks\log\T-01b.md`.)
Gate: `tests\tv-live-race-test.ps1` 0 FAIL; `dash\build.ps1 -NoDeploy`.

## T-01c TV live-race regression uses the new engine
Status: done 2026-10-12 (raw fixture fields now feed the guarded test hook and assertions read `/tv/data`; deployed engine passed all 93 frames. Pit-lane gaps are kept monotonic with the derived order. Report: `docs\tasks\log\T-01c.md`.)
Gate: `tests\tv-live-race-test.ps1` 3 ok, 0 FAIL; `dash\build.ps1` deployed through broker.

## T-02 Timing tower
Status: partly 2026-10-12 (review fixes: invalid class colors use a neutral strip fallback; long names are constrained with ellipsis; browser checks now cover those cases, tower labels/sizes, and empty/disconnected states. `dash\build.ps1 -NoDeploy` passed. Guarded `tv-test.ps1`, irdeck build, copy audit, and deploy deferred because state reports sim=True / telemetry=on. Report: `docs\tasks\log\T-02-fix.md`.)
Gate: `tests\tv-test.ps1` 0 FAIL; `dash\build.ps1 -NoDeploy`; `build-irdeck.ps1 -NoDeploy`; deploy through broker; copy audit 0 FAIL.


## W-01 Workbench single surface and conditions
Status: partly 2026-10-12 (review fixes removed the old Sessions trace renderer, added a selected-lap Review regression case, and moved the lap navigator below the conditions line; dash no-deploy compile passed. Card tests and final deploy are deferred because state reports sim=True / telemetry=on. Report: docs\tasks\log\W-01-fix.md.)
Gate: `tests\workbench-test.ps1` and `tests\copy-audit-test.ps1` 0 FAIL; deploy with `dash\build.ps1` when sim=False.

## W-02 Multi-lap overlay 3+
Status: partly 2026-10-12 (review fixes: differing source grid restriction removed, active lap cursor readout added, multi-lap GAP overlays added; workbench-test 212 passed / 0 failed; both no-deploy builds passed. Deployment/live check waits for required visual sign-off; running irdash is older than source. Report: `docs\tasks\log\W-02-fix.md`.)
Gate: `tests\workbench-test.ps1` 0 FAIL; `tests\copy-audit-test.ps1`; both no-deploy builds; deploy through `dash\build.ps1` when safe and signed off.

## W-03 Time-offset slide with auto-align
Status: partly 2026-10-12 (review fixes align corner/GRIP reference summaries, show offset-mode and AUTO-unavailable state, and strengthen fixture coverage; `workbench-test.ps1` 220/0 and source copy audit 13/0. Live deck polling/API check skipped after irdash refused its test hook with HTTP 409/503; deployment waits for required visual sign-off. Report: `docs\tasks\log\W-03-fix.md`.)
Gate: `tests\workbench-test.ps1` and `tests\copy-audit-test.ps1` 0 FAIL; both no-deploy builds; deploy via `dash\build.ps1` after visual sign-off.
## DS-PERF Dashboard rendering cost and pre-green standings order
Status: partly 2026-10-12 (shared render cadence, change-gated map/trace drawing, hidden-tab work suppression, and derived pre-green standings implemented; `dash\build.ps1 -NoDeploy` passed. Guarded 30-second Chrome CPU/profile and zero-position fixture test deferred because state reports sim=True / onTrack=True. Report: `docs\tasks\log\DS-PERF.md`.)
Gate: `tests\dash-perf-test.ps1` -> Chrome CPU <=20% of one core, trace metrics present, zero-position order and unique Leader; dash no-deploy compile; deploy via `dash\build.ps1` when sim=False.
## H-08 Welcome driver card
Status: partly 2026-10-12 (review fixes: production YAML parser fixtures cover same-row selection, empty/malformed fields; unverified team fallback removed; unavailable image asserts no frame; 144 px picture size documented for HOME's shared column. Dash no-deploy build passed. Guarded home-test passed 96 / 9 failed on existing schedule/calendar, layout/state and phone checks; final rerun waited behind live-test mutex, deploy refused by recorder's dash\deploy.lock. Report: docs\tasks\log\H-08-fix.md.)

## D-05 Debrief deck row + phone debrief
Status: partly 2026-10-12 (review fix: explicit dashboard lease gates deck availability/actions; phone discovers the latest session after opening already disconnected; copy labels removed. Deck screens passed 220/0 and both no-deploy compiles passed. Phone/debrief tests not run (phone test wait stopped behind the live-test mutex); deploy broker exit 2 while `dash\deploy.lock` named phone-test. Report: `docs\tasks\log\D-05-fix.md`.)




## T-03 Map with every car
Status: partly 2026-10-12 (review fixes: TV camera annotations now use `Corners.draw`; GPS projection expectation is independent; invalid pct and missing battle cases added. `tv-test.ps1` 38/0, both no-deploy builds passed, deploy broker exit 0, HOME-focused copy audit 14/0 and source audit 12/0. Full copy audit reached HOME and multiple screens without banned text but DevTools disconnected before completion. Report: `docs\tasks\log\T-03-fix.md`; live relative-overlay comparison remains for T-07.)
Gate: `tests\tv-test.ps1` and `tests\copy-audit-test.ps1` 0 FAIL; both no-deploy builds; deploy via broker.




## INT-2b Integration fixes
Status: partly 2026-10-12 (data-test 130/0; HOME improved from 99/6 to 102/3, with action-state and fixture-render failures outstanding; dash no-deploy build passed. Deployment deferred until HOME passes. Report: docs\tasks\log\INT-2b.md.)
Gate: tests\home-test.ps1 and tests\data-test.ps1 -> 0 FAIL; deploy through dash\build.ps1 when sim=False.

## INT-2c Integration fixes
Status: partly 2026-10-12 (broker deploy exit 0; named suites remain red: phone 218/32, video-page 93/6, race-field 112/1, pro-tools 106/4, cars 42/2, tv 46/1, perf 95/2, gpsmap 15/1. `run-all.ps1` invoked once; still waiting at the friends-live away gate. Report: `docs\tasks\log\INT-2c.md`.)
Gate: named suites and `tests\run-all.ps1` -> 0 FAIL; deploy through `dash\build.ps1` when sim=False.

## K-01 Kids mode (one Stream Deck key locks the rig)
Status: partly 2026-10-20 (lock, hook, flag, top-screen line and MAIN key at 7,3 are in the source. Both no-deploy builds passed. kids-test stopped at the guard: sim on track. Deploy and the test wait until sim=False. Report: docs\tasks\log\K-01.md.)
Goal: one key on the MAIN page turns KIDS MODE on/off. On: the keyboard and mouse are blocked system-wide (low-level hook in irdeck, started by the key, stopped by the same key or by a long press on the Deck) and every other Deck key except the KIDS key is ignored by irdeck (keys check a lock flag file first). Off by default after every reboot. Plain on-screen state on the top screen ("KIDS MODE - locked"). Wheel buttons are NOT blocked (he races with the wheel).
Rules: never turn on while sim=True/onTrack; never write iRacing files; the unlock must work with one Deck press even if irdeck crashes (hook dies with the process).
Gate: new tests/kids-test.ps1 (flag file, key ignore logic, hook start/stop via irdeck-cli), 0 FAIL; build-irdeck.ps1; MAIN-page change needs Peter's Install/restart steps (docs/OPERATIONS.md).
