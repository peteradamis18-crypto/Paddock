=== FILE: docs\cards\v4\W-11.md ===
# W-11 Events list with PAUSE/JUMP (offline)
**Phase / depends on / size / needs Peter:** Phase 3 / depends W-05 / M / none

## Why (2-4 lines: what Peter gets, which signature moment)
The Workbench gets one events list with every real incident, off-track, lock-up, ABS zone and pass. Deck keys step through them, pause, and JUMP the cursor/video to the event. This is the missing "events you can jump to" piece of signature screen 3c, without touching the live replay yet.

## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` - safety and copy rules.
- `dash\src\analysis.cs`, `dash\src\deepdive.cs` - what `/analysis/deep` already returns; find existing event detection and exact JSON fields.
- `dash\src\replayjump.cs` - how `/share/jump` packs and records the 3 SDK messages; look for `dry=1` and `lead`.
- `dash\www\v2\workbench.js` - the existing events list if any, cursor `S.cur`, playback controls.
- `deck-intro\plugin.html` - ANALYSIS screen action handling for `wb-*` commands; note this file is changed only, never installed by the builder.
- `docs\DESIGN-workbench.md` section 5.4 - listed event types and the rule "no slide events".
- `docs\vault.md` "Replay jump" - exact three messages: `ReplaySearchSessionTime`, `CamSwitchNum`, `ReplaySetPlaySpeed(1)`.

## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find out the existing event output in `analysis.cs` / `deepdive.cs` and write its exact JSON field names in the report. Do not guess thresholds. If already there, extend; if absent, add an `events` array to the lap JSON this page consumes.
2. Event types to include, reusing existing detectors by name where possible: incidents from `PlayerCarMyIncidentCount` steps, off-track from `PlayerTrackSurface`, lock-ups from wheel-speed vs car speed, ABS zones from `BrakeABSactive`/`BrakeABScutPct`, passes from the race log (`vault\field` via `field.cs`). Do not add slide events.
3. Each event object must contain at least: `type` (plain word), `lap`, `corner` (or blank), `ia` (cursor index into the lap grid, integer), `st` (seconds into lap), `label` (short fact with units). Units: time in s, brake/ABS as in `docs\research\ibt-channels.md`.
4. In `workbench.js`, render the events list sorted by lap then `ia`; a tap sets `S.cur` to `ia` and moves the video cursor if present. Add playback state and EVENT next/previous.
5. Add deck command handlers in `workbench.js`/`deck-intro\plugin.html` for `wb-eventprev`, `wb-eventnext`, `wb-playpause`, `wb-jump`, with labels `EVENT <`, `EVENT >`, `PLAY/PAUSE`, `JUMP`. Existing ANALYSIS screen label style; no new add-on version, just the code.
6. For JUMP use the existing `/share/jump` route with `&t=<st>&car=me&lead=3&dry=1`; the test hook records the three SDK messages via `/api/test/replaylog`. Do not send any replay message during a real session.
7. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`.

## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- `dash\src\analysis.cs`
- `dash\src\replayjump.cs` (only if route shape must change)
- `dash\www\v2\workbench.js`
- `deck-intro\plugin.html` (EVENT keys; never run install.ps1)
- `tests\replay-jump-test.ps1`

## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
- `dash\build.ps1 -NoDeploy` passes.
- `tests\replay-jump-test.ps1` new section **W-11 event list + dry-run messages**: **14 ok / 0 FAIL**. Checks: event types/labels/cursor movement; PAUSE toggles; EVENT next/prev order; dry-run records exactly 3 messages (`ReplaySearchSessionTime`, `CamSwitchNum`, `ReplaySetPlaySpeed(1)`); no `ReplaySetState`.
- Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 means stop and report.

## User journey (what Peter does and sees; how he would fail it)
Peter opens a lap in the Workbench. The events list shows incidents, lock-ups, ABS zones and passes. Pressing `EVENT >` moves the cursor and video to the next event; `PLAY/PAUSE` controls it; `JUMP` moves the cursor without any live sim action. He fails it if a listed event shows the wrong corner or the dry-run messages are not exactly the three allowed.

## Not in this card (what to leave for later cards)
Live replay jump into the real sim is **W-12**. Deck add-on install is batched later by the lead.

## Report (AGENTS.md format to docs\tasks\log\W-11.md)
```
CARD: W-11 Events list with PAUSE/JUMP (offline)
RESULT: done | partly done | blocked
GATE: replay-jump-test.ps1 W-11 14 ok / 0 FAIL -> passed / failed
FILES: <list>
NEEDS PETER: none
NEEDS LEAD: add-on labels in deck-intro\plugin.html - batch with the next install
NOTES: <max 8 lines>
```

=== FILE: docs\cards\v4\W-12.md ===
# W-12 Events live replay jump (away)
**Phase / depends on / size / needs Peter:** Phase 3 / depends W-11, T-06 / S away / needs Peter away 10 min

## Why (2-4 lines: what Peter gets, which signature moment)
Tapping an ABS or lock-up event takes iRacing's own replay to that moment, 3 seconds before, on his car. It closes the loop between the Workbench event list and the live iRacing replay. This is the live acceptance of W-11, run once in a spectated AI race.

## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md`.
- `dash\src\replayjump.cs` - exact packing of the three messages and the session comparison logic.
- `tests\replay-jump-test.ps1` - current offline sections and what `-Live` already does.
- `docs\vault.md` "Replay jump" - the three allowed messages and the session uniqueness rule.
- `docs\replay.md` - `ReplaySearchSessionTime` read-back and camera state variables.
- `docs\OPERATIONS.md` section 6 - how to run a live test only when Peter is away 10 min.

## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Read `dash\src\replayjump.cs` and write in the report exactly which three broadcasts it sends and how it decides the session matches. Do not change the three-message rule.
2. Confirm `T-06` is done (replay live fixes) before running anything live; if not, this card stops with `NEEDS LEAD: T-06 first`.
3. In `tests\replay-jump-test.ps1 -Live`, add or extend a section that: starts a spectated AI race, opens the Workbench or fetches an event time, calls `/share/jump?...&car=me&lead=3`, then reads `ReplaySessionTime` and `CamCarIdx`/camera state back to prove the jump.
4. The test must check: the jump lands within **1.0 s** of the requested session time, the camera is on Peter's car, and no `ReplaySetState` is ever sent.
5. If Peter has not been away 10 minutes, run only offline parts and print `PENDING live:` with the exact command to repeat. Do not start the sim.
6. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. No deploy unless already needed and the rig is free.

## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- `dash\src\replayjump.cs` (only if the live test finds a fault)
- `tests\replay-jump-test.ps1`

## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
- `dash\build.ps1 -NoDeploy` passes.
- `tests\replay-jump-test.ps1 -Live` new section **W-12 live replay jump**: **8 ok / 0 FAIL**. If Peter is not away, the line may be `PENDING live:` and this card is partly done; the exact command must be in the report.
- Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 means stop and report.

## User journey (what Peter does and sees; how he would fail it)
Peter is out of the car, iRacing is on the same session, and the replay tape is open. He taps an ABS event. iRacing's replay shows his own car 3 seconds before the event, playing. He fails it if the moment is more than 1 second off, the camera is on the wrong car, or the live section was never run.

## Not in this card (what to leave for later cards)
No new event types, no deck changes, no Studio work. Studio (`ST-01`) comes later and depends on this replay path.

## Report (AGENTS.md format to docs\tasks\log\W-12.md)
```
CARD: W-12 Events live replay jump (away)
RESULT: done | partly done | blocked
GATE: replay-jump-test.ps1 -Live W-12 8 ok / 0 FAIL -> passed / failed / pending live
FILES: <list>
NEEDS PETER: away 10 min for the live section, or none if already run
NEEDS LEAD: run the pending live command if the agent could not
NOTES: <max 8 lines>
```

=== FILE: docs\cards\v4\W-13.md
=== FILE: docs\cards\v4\W-13.md
# W-13 Fastest car in my session per corner
**Phase / depends on / size / needs Peter:** Phase 3 / depends D-01 / M / none

## Why (2-4 lines: what Peter gets, which signature moment)
The RACE page says exactly where the fastest car in his class gained time, corner by corner. It uses Paddock's own 10 Hz race log, so it is free and local, not another driver's telemetry. This is the "fastest car in his session per corner" block added to signature screen 3c.

## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md`.
- `dash\src\field.cs` - how the race log writes `vault\field\f*.json` and what `/analysis/race` already returns.
- `dash\www\v2\workbench-race.js` - the RACE page layout and where a new section goes.
- `dash\src\debrief.cs` - the debrief result/pace block from D-01; where one new factual line may fit.
- `docs\vault.md` "The race log" - clean-lap rule, per-corner medians, n per car, and precision `+-0.02 s per lap`.

## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Read the current `/analysis/race` JSON and `RaceField.Snapshot`/`Build` in `field.cs`. Write the exact existing per-corner block field names in the report.
2. Add a new block to `/analysis/race`, named `fastestGains`. For Peter's class only, choose the **class-fastest car** as the car with the lowest median of its clean-lap times. Use the same clean-lap rules as the rest of the race log (not lap 1, not pit laps, not off-track laps, within 107 % of the car's median).
3. Per corner, compute Peter's median time and the fastest car's median time across their clean laps. Each entry must include: `corner`, `hisMedian`, `fastCarMedian`, `gain` (fastCarMedian - hisMedian, seconds, negative = faster), `fastCarIdx`, `fastCarNumber`, `nHis`, `nFast`. Sort by largest gain (most loss for Peter) ascending.
4. Reuse the same corner list the race log already holds. If fewer than 2 clean laps for either car, use the best clean lap instead and set `n` accordingly; mark `median:false` when not a median.
5. In `workbench-race.js`, render **WHERE THE FASTEST CAR GAINS** with the top 3 corners and the numbers above. Include a small note `Peter median vs #<number> fastest car median Â· n a/b`.
6. In `debrief.cs`, add only one factual line to the race extras if the data is present, using the same top corner and numbers.
7. Extend `tests\race-field-test.ps1` with a pretend race whose known answer is hand-checked; assert within **0.02 s**.
8. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`.

## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- `dash\src\field.cs`
- `dash\src\debrief.cs`
- `dash\www\v2\workbench-race.js`
- `tests\race-field-test.ps1`

## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
- `dash\build.ps1 -NoDeploy` passes.
- `tests\race-field-test.ps1` new section **W-13 per-corner fastest gains**: **10 ok / 0 FAIL**. Hand-check at least three corners against the pretend race within 0.02 s; n per car shown; wrong fastest car is a fail.
- Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 means stop and report.

## User journey (what Peter does and sees; how he would fail it)
Peter opens the RACE page after a race. It shows the top three corners where the class-fastest car gained on him, each with both medians and the number of laps used. He fails it if the fastest car is not the true class-fastest, a number is off by more than 0.02 s, or n is missing.

## Not in this card (what to leave for later cards)
Garage 61 named-driver comparison remains optional and needs Peter's yes; Pro onboard comparison is Phase 5 (`PR-01..03`).

## Report (AGENTS.md format to docs\tasks\log\W-13.md)
```
CARD: W-13 Fastest car in my session per corner
RESULT: done | partly done | blocked
GATE: race-field-test.ps1 W-13 10 ok / 0 FAIL -> passed / failed
FILES: <list>
NEEDS PETER: none
NEEDS LEAD: none
NOTES: <max 8 lines>
```

=== FILE: docs\cards\v4\W-14.md
# W-14 Career back-fill from old .ibt
**Phase / depends on / size / needs Peter:** Phase 3 / depends P0-08 / M / none

## Why (2-4 lines: what Peter gets, which signature moment)
Every old `.ibt` file becomes a career row: iRating, licence string/level/sub-level, session type, finish, SOF and incidents. That gives the stats screen years of history instead of starting today. This is the data foundation for W-15, not yet a screen.

## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md`.
- `docs\research\ibt-channels.md` appendix from P0-08 - exact verified field names and samples; do not use unverified names.
- `dash\src\career.cs`, `dash\src\data.cs` - how .ibt files are read and how `dash\career-cache.tsv` rows are written and migrated.
- `dash\build.ps1` - the `$src` list to add `stats.cs`.
- `docs\data.md` "Cache format 2" and `docs\vault.md` "Which laps count" - existing cache columns and lap rules.

## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. First build step: find out the exact YAML field names from P0-08 in `docs\research\ibt-channels.md` and write them in the report. Do not hardcode a name that P0-08 has not verified.
2. Create new `dash\src\stats.cs` with `Stats.Init(string root)`, `Stats.Scan()` and a status route `GET /stats/status` returning `{scanned, rows, errors, running}`. It uses the same .ibt text/YAML reader as `career.cs` and runs at `ProcessPriorityClass.BelowNormal`.
3. Add columns to `dash\career-cache.tsv` (append; do not break old readers): `irating`, `licstring`, `liclevel`, `licsublevel`, `type`, `finish`, `sof`, `incidents`, `statsVersion`. Migrate old rows by reading them with defaults (`-1` or blank).
4. Scan every old `.ibt`: capture the player's `IRating`, `LicString`, `LicLevel`, `LicSubLevel`, session type, finish position from the results block, SOF and incident count. AI sessions are excluded when iRating is **0 or 1**, as the spec says.
5. Safety: skip OneDrive online-only files, never read the newest `.ibt` while the sim process is running, and stop/pause when he is on track. Write rows to `dash\career-cache.tsv` exactly like `career.cs` does, with a backup of the old file first.
6. Add `dash\src\stats.cs` to the `$src` list in `dash\build.ps1`.
7. Create `tests\stats-test.ps1` with copies of at least three real old `.ibt` files; hand-check three rows and assert them.
8. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`.

## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- new `dash\src\stats.cs`
- `dash\src\career.cs` (cache migration/route hook only)
- `dash\src\data.cs` (only if the YAML reader is here and must be reused)
- `dash\career-cache.tsv`
- `dash\build.ps1` (`$src` line)
- new `tests\stats-test.ps1`

## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
- `dash\build.ps1 -NoDeploy` passes.
- `tests\stats-test.ps1` new section **W-14 back-fill**: **12 ok / 0 FAIL**. Checks: every old .ibt row has the new fields; 3 hand-checked rows match raw .ibt values; AI sessions with iRating 0/1 excluded; online-only skipped; newest skipped while sim runs.
- Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 means stop and report.

## User journey (what Peter does and sees; how he would fail it)
No visible screen yet. He fails this card if W-15 cannot later show his iRating curve because rows are missing or wrong, or if an AI session pollutes the data.

## Not in this card (what to leave for later cards)
The stats screen and CSV import are **W-15**.

## Report (AGENTS.md format to docs\tasks\log\W-14.md)
```
CARD: W-14 Career back-fill from old .ibt
RESULT: done | partly done | blocked
GATE: stats-test.ps1 W-14 12 ok / 0 FAIL -> passed / failed
FILES: <list>
NEEDS PETER: none
NEEDS LEAD: none
NOTES: <max 8 lines>
```

=== FILE: docs\cards\v4\W-15.md
# W-15 Stats screen + CSV import
**Phase / depends on / size / needs Peter:** Phase 3 / depends W-14 / M / needs Peter: optional drop one CSV export into `vault\import\`

## Why (2-4 lines: what Peter gets, which signature moment)
A single STATS screen shows iRating and safety-rating trends back to his first `.ibt`, plus every result with SOF, finish, wins, podiums and incidents. Dropping a members-site CSV adds races Paddock never saw, without duplicates. This is the career/history moment Peter asked for.

## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md`.
- `dash\src\stats.cs` from W-14 - the new columns and status route; extend here.
- `dash\src\home.cs` - how HOME lists links, to add a STATS link with no dead buttons.
- `dash\www\v2\home.js`, `dash\www\v2\workbench-career.js` - visual style and chart patterns to match.
- `docs\data.md`, `docs\vault.md` "The career" - chart rules and data sources.
- `docs\research\calendars-2026-10.md` section C - the CSV export is the only accepted external source.

## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. First build step: find out the exact CSV columns in a members-site export if any file exists in `vault\import\`; write those column names in the report. If no sample exists, implement a header-mapped parser with a strict dry-run and do not claim import works until a sample is recognized.
2. Extend `stats.cs` with `GET /stats` returning `{sessions, trendIr, trendSr, totals, imported}`. Every session row includes date, car, track, type, finish, SOF, incidents, iRating, licence.
3. Trend arrays contain only sessions with valid values. **No chart may render with fewer than 5 points.** Return `trendIr: []` and `trendSr: []` until there are 5.
4. Totals: wins, podiums, incidents, starts. Use the same definitions as the career screen (official counted laps/results only).
5. Create new `dash\www\v2\stats.js` and `stats.css`, premium black/gold using `theme.css` tokens; two trend charts and a results table with SOF. No decorative filler.
6. CSV import: scan `vault\import\*.csv` in the background, merge by a key derived from the sample (date + car + track + type + finish + SOF if present). Duplicate rows already in `stats.cs` data are skipped. Write one log line per file.
7. Add a **STATS** link to HOME only when the page exists and the data has at least one session; no dead link.
8. Extend `tests\stats-test.ps1` with a fixture CSV matching the documented sample columns.
9. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`.

## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- `dash\src\stats.cs`
- new `dash\www\v2\stats.js`
- new `dash\www\v2\stats.css`
- `dash\src\home.cs` (STATS link only)
- `dash\www\v2\home.js` (link render only)
- `dash\www\v2\workbench-career.js` (only if shared chart helper is reused)
- `tests\stats-test.ps1`

## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
- `dash\build.ps1 -NoDeploy` passes.
- `tests\stats-test.ps1` new section **W-15 stats screen + CSV merge**: **14 ok / 0 FAIL**. Checks: no chart below 5 points; totals match hand-checked session data; a fixture CSV merges with no duplicates; second identical import adds 0 rows; copy-audit 0.
- Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 means stop and report.

## User journey (what Peter does and sees; how he would fail it)
Peter opens STATS from HOME. He sees his iRating curve back to his first `.ibt`, SR by licence class, and a results table with finish, SOF and incidents. He drops one CSV export into `vault\import\` and the years he missed appear once. He fails it if a chart shows with fewer than 5 points or a CSV row appears twice.

## Not in this card (what to leave for later cards)
Phone stats is not built; Garage 61 and Data API are out. Further career screens are later.

## Report (AGENTS.md format to docs\tasks\log\W-15.md)
```
CARD: W-15 Stats screen + CSV import
RESULT: done | partly done | blocked
GATE: stats-test.ps1 W-15 14 ok / 0 FAIL -> passed / failed
FILES: <list>
NEEDS PETER: optional - drop one members-site CSV into vault\import\ when ready
NEEDS LEAD: none
NOTES: <max 8 lines>
```

=== FILE: docs\cards\v4\W-16.md
# W-16 Phone session review + corner table
**Phase / depends on / size / needs Peter:** Phase 3 / depends D-04 / M / none

## Why (2-4 lines: what Peter gets, which signature moment)
The iPhone REVIEW session screen matches the top-screen Session Review: timing table, gap map, corner table sorted by loss, and the conditions line. Peter reads where the time went from the sofa. This is the phone-depth card for signature 3a/3c.

## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md`.
- `dash\www\phone\app.js` - the current LAPS/REVIEW detail and how sessions are rendered; find the existing session-detail fetch.
- `dash\www\phone\app.css` - phone layout tokens and touch targets.
- `dash\src\sessionreview.cs` or `analysis.cs` - the `/analysis/session` JSON shape and numbers; the phone must match them exactly.
- `docs\vault.md` "Which laps count" and `docs\USER-GUIDE.md` phone section - the user-visible words.
- `tests\phone-test.ps1` - current phone checks and how screenshots are taken.

## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find the existing phone session-detail view and write its current fields in the report. Reuse the same `/analysis/session` request; do not create a new server route unless a field is missing.
2. In `app.js`, replace the shallow session detail with: identity line, conditions line (air/track temperature, wind, skies, wetness) using the same medians as the top screen, a timing table (lap, time, S1-S3, gap, valid/OUT/IN/OFF), a track map coloured by gap (reuse the map renderer already in the phone app, or fetch the outline and draw the line), and a corner table sorted by time lost with per-corner time and gap.
3. All numbers must come from the same JSON reply the top screen Session Review uses. Round only for display, never for the table values; show lap times to the 1/1000 exactly as the top screen.
4. Style in `app.css`: tap targets at least 44 px, small caps labels, tabular numbers, one gold accent. No frameworks.
5. Extend `tests\phone-test.ps1` with a real Road Atlanta fixture; assert the phone numbers equal the top-screen `/analysis/session` reply for three chosen cells, and take a screenshot.
6. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` (no server code may be needed, but run to ensure no accidental C# break).

## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- `dash\www\phone\app.js`
- `dash\www\phone\app.css`
- `tests\phone-test.ps1`

## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
- `dash\build.ps1 -NoDeploy` passes.
- `tests\phone-test.ps1` new section **W-16 phone session review**: **14 ok / 0 FAIL**. Checks: timing table equals top screen for 3 cells; conditions line present with numbers; corner table sorted by loss; map by gap draws; no overlap at 390 px width; copy-audit 0.
- Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 means stop and report.

## User journey (what Peter does and sees; how he would fail it)
Peter sits on the sofa, opens REVIEW on the iPhone, and reads the lap times, the worst corners and the track map coloured by loss. He fails it if any number differs from the top-screen Session Review, the corner table is unordered, or the conditions line is missing.

## Not in this card (what to leave for later cards)
Phone channel picker + XY/histogram is **W-17**. Phone share is later (`SH-02`).

## Report (AGENTS.md format to docs\tasks\log\W-16.md)
```
CARD: W-16 Phone session review + corner table
RESULT: done | partly done | blocked
GATE: phone-test.ps1 W-16 14 ok / 0 FAIL -> passed / failed
FILES: <list>
NEEDS PETER: none
NEEDS LEAD: none
NOTES: <max 8 lines>
```

=== FILE: docs\cards\v4\W-17.md
# W-17 Phone channel picker + XY/histogram
**Phase / depends on / size / needs Peter:** Phase 3 / depends W-16 / M / none

## Why (2-4 lines: what Peter gets, which signature moment)
On the iPhone he picks any two channels, plots them as traces or X-Y, pinches to zoom and reads the value at the cursor. This is the phone half of the Workbench depth, using the same `/analysis/channels` data as the top screen.

## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md`.
- `dash\www\phone\app.js` from W-16 - current session detail and canvas patterns to extend.
- `dash\www\phone\app.css` - touch controls and layout.
- `dash\src\workbench.cs` and `dash\src\analysis.cs` - exact `/analysis/channels` response shape and channel names/units.
- `docs\DESIGN-workbench.md` section 2.5 and `docs\research\pi-toolbox-features.md` section 2 - channel picker and X/Y/histogram behaviour to imitate.

## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find the exact `/analysis/channels` response shape and write it in the report. If the phone needs parameters the route does not support (for example a decimated array), extend the route minimally in `dash\src\workbench.cs`/`analysis.cs` with C# 5, no new libraries.
2. In `app.js`, add a channel picker: initials search like Pi (`LG` = Lateral G), any two channels, and a trace view whose x-axis is lap distance. Use the same units and names as the top screen.
3. Add an XY toggle: first channel on x, second on y, with a sensible auto-fit. No polynomial fit on the phone.
4. Add pinch-zoom and pan to the trace and XY canvases using existing touch helpers; add a readout line at the cursor with both values and units.
5. Add a histogram toggle for a single selected channel: time-in-band on x, percentage on y; bins reuse a simple fixed count (no non-linear bins).
6. Ensure a Road Atlanta lap renders in **under 2 seconds** on the phone test fixture.
7. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`.

## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- `dash\www\phone\app.js`
- `dash\www\phone\app.css`
- `dash\src\workbench.cs` (only if `/analysis/channels` must change)
- `dash\src\analysis.cs` (only if the route is implemented here)
- `tests\phone-test.ps1`

## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
- `dash\build.ps1 -NoDeploy` passes.
- `tests\phone-test.ps1` new section **W-17 phone channel picker + XY/histogram**: **12 ok / 0 FAIL**. Checks: two channels selected and drawn; XY toggle; pinch zoom changes range; readout shows unit; histogram shows percentage; Road Atlanta fixture renders under 2 s.
- Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 means stop and report.

## User journey (what Peter does and sees; how he would fail it)
Peter opens REVIEW on the phone, taps CHANNELS, types `LG`, picks Lateral G and Speed, toggles X-Y, pinches to zoom and sees the readout. He fails it if the units are wrong, the canvas is slow, or the phone cannot select two channels in 4 taps.

## Not in this card (what to leave for later cards)
Top-screen Workbench visually remains the primary deep tool; no phone maths/formula channels, CSV export or share here.

## Report (AGENTS.md format to docs\tasks\log\W-17.md)
```
CARD: W-17 Phone channel picker + XY/histogram
RESULT: done | partly done | blocked
GATE: phone-test.ps1 W-17 12 ok / 0 FAIL -> passed / failed
FILES: <list>
NEEDS PETER: none
NEEDS LEAD: none
NOTES: <max 8 lines>
```

=== FILE: docs\cards\v4\W-18.md
# W-18 Cosworth open method + button everywhere
**Phase / depends on / size / needs Peter:** Phase 3 / depends none / S live / needs Peter none (rig free)

## Why (2-4 lines: what Peter gets, which signature moment)
OPEN IN COSWORTH appears on every analysis surface when Pi Toolbox is installed and opens the lap's `.ibt` in one press. The open method is verified on this PC before anything else is claimed. This is the first half of Cosworth integration, with no password handling.

## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md`.
- `dash\src\vault.cs` - current Cosworth/open route and any `installed` flag.
- `dash\www\v2\workbench.js`, `sessionreview.js`, `debrief-v4.js` - where each surface's buttons live.
- `docs\vault.md` "OPEN IN COSWORTH" and `docs\ARCHITECTURE.md` route table.
- `docs\research\pi-toolbox-features.md` and `docs\research\post-session-landscape.md` section 4 - Pi reads `.ibt` natively; Lite has no video sync.
- `CLAUDE.md` rule 3 - start GUI apps via Explorer where needed.

## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. First build step: find out the exact Pi Toolbox executable name, install path and its main window title on this PC. Write these in `docs\cosworth.md` and the report. Do not guess.
2. Verify the open method: first try starting the executable with the lap's `.ibt` path as the argument, then fall back to `explorer.exe "<ibt>"`. Confirm Pi shows a window whose title contains the file name or path. Record exactly what worked.
3. In `dash\src\vault.cs`, update the Cosworth route to use the verified method. It must be refused while he drives (HTTP 409). Add an `installed` field to the existing status JSON so pages can decide.
4. Add the button to the three listed JS surfaces only when `installed` is true, hidden otherwise. The existing Vault button is the fourth surface; do not edit `vault.js` unless its button is missing.
5. `docs\cosworth.md` must record: install path, executable, working argument or fallback, window-title check, and the video-sync fact (Pi Toolbox Lite has no video sync; Plus and above only).
6. Create `tests\cosworth-test.ps1`. If Pi Toolbox is installed, run the real check; if not, the test skips with a clear line and this card is partly done.
7. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`.

## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- `dash\src\vault.cs`
- new `docs\cosworth.md`
- new `tests\cosworth-test.ps1`
- `dash\www\v2\workbench.js`
- `dash\www\v2\sessionreview.js`
- `dash\www\v2\debrief-v4.js`

## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
- `dash\build.ps1 -NoDeploy` passes.
- `tests\cosworth-test.ps1` new section **W-18 open method + buttons**: **10 ok / 0 FAIL**. Checks: path and executable recorded; open method returns success or documented fallback; window title confirms file; button visible on all four surfaces when installed; hidden when not; refusal while driving; copy-audit 0.
- Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 means stop and report.

## User journey (what Peter does and sees; how he would fail it)
Peter opens any lap in Workbench, Session Review or the Debrief and presses OPEN IN COSWORTH. Pi Toolbox opens that `.ibt` without a file dialog. He fails it if the button is hidden while Pi is installed, or Pi opens the wrong file.

## Not in this card (what to leave for later cards)
The Paddock-ready workbook inside Pi is **W-19**. Cosworth video sync is deliberately not attempted because Lite has none.

## Report (AGENTS.md format to docs\tasks\log\W-18.md)
```
CARD: W-18 Cosworth open method + button everywhere
RESULT: done | partly done | blocked
GATE: cosworth-test.ps1 W-18 10 ok / 0 FAIL -> passed / failed / skipped
FILES: <list>
NEEDS PETER: none
NEEDS LEAD: none
NOTES: <max 8 lines>
```

=== FILE: docs\cards\v4\W-19.md
# W-19 Cosworth ready workbook in Pi's user folder
**Phase / depends on / size / needs Peter:** Phase 3 / depends W-18 / M live / needs Peter none (rig free)

## Why (2-4 lines: what Peter gets, which signature moment)
Pi Toolbox opens Peter's lap with Paddock's ready worksheets: speed, throttle, brake, steering, gear, delta and PB as datum where the free edition supports it. If the workbook format is binary and undocumented, this card stops and documents that plainly. This is the failable second half of Cosworth setup.

## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md`.
- `docs\cosworth.md` from W-18 - verified Pi install path and open method.
- `docs\research\pi-toolbox-features.md` - workbook `.pwb`, worksheet/display model, datum outing concept, Lite limits.
- `dash\src\vault.cs` - the Cosworth open route to hook workbook preparation.
- `docs\vault.md` "OPEN IN COSWORTH" - current button wording.

## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. First build step: find Pi's user folder and the iRacing **Lite** workbook file that Pi Toolbox actually reads. Write the exact path and file extension in `docs\cosworth.md`. Do not touch anything under `Documents\iRacing` or the iRacing install folder.
2. Inspect the workbook file format. If it is text, XML, or a ZIP containing readable XML/text, create `tools\cosworth-workbook.ps1` that makes a Paddock copy containing the prescribed displays: speed, throttle, brake, steering, gear, delta; set PB as the datum outing only where the format supports it. If the format is binary or undocumented, the script writes `NOT SUPPORTED` and this card's gate becomes failable with a documented stop.
3. If text/XML, the copied workbook must carry a plain `Paddock` name and the same display set. It must never write over Pi's own workbook; write a new file in Pi's user folder.
4. In `dash\src\vault.cs`, after a successful OPEN IN COSWORTH, ensure the Paddock workbook exists. If not supported, the button still opens the file exactly as W-18 did.
5. `tools\cosworth-workbook.ps1 -Check` prints the format decision and the path it would write, without changing anything.
6. Extend `tests\cosworth-test.ps1` with a section that runs `-Check` and asserts no iRacing folder is written.
7. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` if `vault.cs` changed.

## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- `docs\cosworth.md`
- new `tools\cosworth-workbook.ps1`
- `dash\src\vault.cs` (workbook hook only)
- `tests\cosworth-test.ps1`

## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
- `dash\build.ps1 -NoDeploy` passes.
- `tests\cosworth-test.ps1` new section **W-19 workbook**: **8 ok / 0 FAIL**. Checks: Pi user folder found; Lite workbook inspected; if text/XML, Paddock workbook exists with the six displays and datum where supported; if binary, `docs\cosworth.md` contains the stop and the script returns `NOT SUPPORTED`; no write under `Documents\iRacing` or `Program Files (x86)\iRacing`.
- Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 means stop and report.

## User journey (what Peter does and sees; how he would fail it)
Peter presses OPEN IN COSWORTH. Pi opens the lap with Paddock's worksheets ready (speed, throttle, brake, steering, gear, delta, PB datum where supported). He fails it if Pi shows an empty or stock workbook when the format supports a copy, or if any iRacing folder was touched.

## Not in this card (what to leave for later cards)
No live telemetry, no video sync in Pi, no Pi Toolbox Plus/Pro integration.

## Report (AGENTS.md format to docs\tasks\log\W-19.md)
```
CARD: W-19 Cosworth ready workbook in Pi's user folder
RESULT: done | partly done | blocked
GATE: cosworth-test.ps1 W-19 8 ok / 0 FAIL -> passed / failed / failable-documented-stop
FILES: <list>
NEEDS PETER: none
NEEDS LEAD: none
NOTES: <max 8 lines>
```