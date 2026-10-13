=== FILE: docs\cards\v4\D-01.md ===
# D-01 Debrief engine: result, position by lap, pace vs field
**Phase / depends on / size / needs Peter:** Phase 1 / depends on P0-05 / size M / needs Peter: none
## Why (2-4 lines: what Peter gets, which signature moment)
This is the data engine behind the signature "straight after a session" debrief. Peter gets his race result, his position lap by lap, and his pace against the field, all computed from the race log and lap analysis he already has. No screen yet; this card only produces the JSON.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `COPY-RULES.md` â safety rules, C# 5, no frameworks, no iRacing file writes.
- `docs\vault.md` section "The race log (every car of a session, W6)" â exact `vault\field\f*.json` fields and `RfSummary.Build` outputs.
- `docs\data.md` section D2 and `docs\corners.md` â lap analysis and corner model.
- `dash\src\field.cs` â `RaceField.Route`, `RfSummary.Build`, position-by-lap and pace data.
- `dash\src\analysis.cs` â `Analysis` lap metrics, reference store (PB/optimal), `LapRules.Judge`.
- `dash\src\irdash.cs` and `dash\build.ps1` â route registration pattern and `$src` list.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find out the exact route registration pattern in `dash\src\irdash.cs` and the `$src` line in `dash\build.ps1`; write both in the report.
2. Create new `dash\src\debrief.cs` with a `Debrief` class and route `GET /debrief?id=<field id | telemetry file name | Vault lap id>`. Reuse `RaceField.Route`/`RfSummary.Build` from `field.cs` to find the race log that ran inside the session time window (same logic as `/analysis/race`). If no race log exists, fall back to practice pace story.
3. JSON fields, all times in seconds to 3 decimals, gaps in seconds, iRating integer, n integer:
   - `result`: finish position, start position, positions gained, iRating change, gap to winner, incidents, clean laps / total laps.
   - `positionByLap`: array per lap `{lap, position, gapToLeader, pitStop, pass}` â take position per lap directly from `RfSummary.Build`, do not recompute.
   - `pace`: `{hisBest, hisMedian, classBest, classMedian, n, top5}` â his best and median vs class best and median with n from the field log.
   - `practice`: for practice sessions, pace story vs PB and optimal from `Analysis` reference store (`ref=pb` and `ref=optimal`); include best lap, PB, optimal, median.
4. Hand-check 3 numbers on a real race log fixture and write those exact numbers into the test.
5. Add `debrief.cs` to the `$src` line in `dash\build.ps1`.
6. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. C# 5 only: no `$"..."`, `?.`, `nameof`, expression-bodied members, `out var`.
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- new `dash\src\debrief.cs`
- read `dash\src\field.cs`, `dash\src\analysis.cs`, `dash\src\irdash.cs`, `dash\build.ps1`
- new `tests\debrief-test.ps1`
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
`tests\debrief-test.ps1` new sections:
1. On a real race log fixture: position per lap equals the log (0 mismatches).
2. Pace numbers equal the 3 hand-checked values.
3. Practice fallback: pace story vs PB/optimal is present and correct.
4. `GET /debrief?id=` answers in â¤ 5 s.
5. Returns 503 while driving.
Compile with `-NoDeploy`; deploy only when `irdeck-cli.exe state` shows `sim=False` (exit 2 = stop). No visible text in this card, but copy-audit-test must still pass if any string is added.
## User journey (what Peter does and sees; how he would fail it)
None yet. This card only produces the JSON the next cards render.
## Not in this card (what to leave for later cards)
Corner video pairs (D-02), the debrief screen (D-03), incidents and buttons (D-04), deck/phone (D-05), live check (D-06).
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\D-01.md` with CARD, RESULT, GATE, FILES, NEEDS PETER, NEEDS LEAD, NOTES. Tick the card status in `docs\TASKS.md` if present.

=== FILE: docs\cards\v4\D-02.md ===
# D-02 Corner video pairs
**Phase / depends on / size / needs Peter:** Phase 1 / depends on D-01, P0-01 / size M / needs Peter: none
## Why (2-4 lines: what Peter gets, which signature moment)
For the three corners that cost the most time, Peter will see his lap and his best other lap side by side, looping. This card cuts those video pairs from the session recording and the reference clip, so the debrief screen has real moving pictures of exactly where time went.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `COPY-RULES.md` â safety rules, C# 5, no frameworks, no iRacing file writes.
- `docs\vault.md` sections "Whole sessions (S1)" and "For the next card (video player, C-08)" â sidecar fields `lapStartOffset`, `lapEndOffset`, `videoStart`, `clipStartMs`, `lapStartMs`, `lapEndMs`, `truncated`, clip id naming.
- `docs\corners.md` â corner start/end pct and names.
- `dash\src\recorder.cs` â sidecar read only; do not modify recorder.
- `dash\src\debrief.cs` from D-01 â extend its `/debrief?id=` response.
- `dash\src\analysis.cs` â corner metrics and worst-corner sorting.
- `vault\bin\ffmpeg.exe` â already installed, use `-c copy`.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find out the exact sidecar JSON field names and clip id naming in `dash\src\recorder.cs` and `docs\vault.md`; write them in the report.
2. Extend `dash\src\debrief.cs` `/debrief?id=` to add a `corners` array. For the 3 worst corners from `Analysis` (sorted by time lost), include: corner name/number, corner start/end pct, this lap video id, reference lap video id, cut status.
3. For each worst corner, cut two clips with `vault\bin\ffmpeg.exe -ss <start> -to <end> -i <source> -c copy <out>`:
   - This lap: from the session mp4 `vault\sessions\<date-time>-<track>.mp4`, using sidecar `lapStartOffset`/`lapEndOffset` to locate the corner.
   - Reference lap: from its clip `vault\clips\rec-<UTC lap start>-l<lap>.mp4` if it has video.
   - Cut from corner start â 2 s to corner end + 1 s. Both clips must have durations within 0.5 s of each other, and the player will start both at the corner start marker.
4. Use `-c copy` only, no re-encode. Run ffmpeg at BelowNormal priority, only when `irdeck-cli.exe state` shows `sim=False` and he is out of the car; never while driving.
5. If the reference lap has no video, return only this lap clip and set `referenceVideo: null`.
6. Write cut files to `vault\clips\debrief-<session>-<lap>-<corner>.mp4` and include the paths in the JSON.
7. Add tests to `tests\debrief-test.ps1` for the new sections.
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- `dash\src\debrief.cs`
- read `dash\src\recorder.cs` (sidecar read only)
- `tests\debrief-test.ps1`
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
`tests\debrief-test.ps1` new sections:
1. For the 3 worst corners: both clips exist and durations are within 0.5 s.
2. Both clips start at the corner start (check via ffprobe or sidecar).
3. No reference video â this lap alone, `referenceVideo: null`.
4. ffmpeg runs BelowNormal and refuses while driving.
Compile with `-NoDeploy`; deploy only when `irdeck-cli.exe state` shows `sim=False` (exit 2 = stop). No visible text in this card, but copy-audit-test must still pass if any string is added.
## User journey (what Peter does and sees; how he would fail it)
None yet. This card only produces the video files the next card renders.
## Not in this card (what to leave for later cards)
The debrief screen (D-03), incidents and buttons (D-04), deck/phone (D-05), live check (D-06).
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\D-02.md` with CARD, RESULT, GATE, FILES, NEEDS PETER, NEEDS LEAD, NOTES. Tick the card status in `docs\TASKS.md` if present.

=== FILE: docs\cards\v4\D-03.md ===
# D-03 Debrief screen to the 3a wireframe
**Phase / depends on / size / needs Peter:** Phase 1 / depends on D-01, D-02 / size M / needs Peter: none
## Why (2-4 lines: what Peter gets, which signature moment)
This is the signature "straight after a session" screen. Within 60 seconds of getting out, the top screen tells Peter the race result, his position lap by lap, his pace against the field, and the three corners that cost the most, with looping video pairs. No press needed.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `COPY-RULES.md` â safety rules, C# 5, no frameworks, no iRacing file writes, premium visuals rule.
- `docs\DESIGN-analysis.md` section 2 â fixed colours, distance axis, data notes, readable from seat, no dead buttons.
- `dash\www\v2\index.html` and `core.js` â how `debrief.js` is loaded and how session end triggers the debrief.
- `dash\www\v2\debrief.js` â existing debrief to replace (do not delete).
- `dash\www\v2\sessionreview.js` â existing Session Review; disable its auto-show, keep it for DEEP DIVE.
- `dash\src\debrief.cs` from D-01/D-02 â the `/debrief?id=` JSON.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find out how `debrief.js` is loaded and triggered on session end in `index.html`/`core.js`; write the exact hook in the report.
2. Create new `dash\www\v2\debrief-v4.js` and `dash\www\v2\debrief-v4.css`. Implement the 3a wireframe exactly:
   - 1920Ã1080, black `#0b0b0c`, warm white `#ece8df`, gold `#f2c230`, Bahnschrift, tabular numbers, body â¥ 22 px, labels â¥ 14 px small caps.
   - Header band y 0â110: `#4 PETER Â· PRATT MILLER MOTORSPORTS`, `RACE Â· Road Atlanta Â· Corvette Z06 GT3.R`, `Sat 11 Oct Â· 20:45 Â· 18 laps Â· 20 cars Â· SOF 2,233 Â· air 24 Â°C Â· track 31 Â°C`.
   - Three columns y 110â410: RESULT (P3 start P4 +1, iRating +64, gap to winner 8.4 s, 2x incidents, 15 clean / 18), POSITION BY LAP chart (his line gold, leader grey, two cars around him dotted, pit stops as drops, passes as dots from `vault\field`), PACE VS FIELD (best 1:19.549 PB, class best 1:18.912 #22, his median 1:20.3, field median 1:20.9 (n=19), top 5 % 1:18.7).
   - WHERE THE TIME WENT y 410â850: three corner cards (T10a â0.21 s, T1 â0.12 s, T5 Esses â0.09 s), each with two video thumbnails 560Ã210 (this lap / best lap) and fact lines (brake 12 m earlier Â· apex 141 vs 146 km/h; throttle 10 m later).
   - INCIDENTS y 850â940: `lap 6 Â· T7 Â· 2x Â· â¶ 30 s`, `lap 14 Â· T12 Â· 1x off track Â· â¶ 30 s`.
   - Buttons y 940â1080: SAVE, SHARE, OPEN IN COSWORTH, DEEP DIVE (inert in D-03).
3. Fetch `/debrief?id=<newest session>` and render. Use real data from D-01/D-02. Position chart uses `positionByLap`; corner cards use `corners` with video paths.
4. Ensure the screen appears automatically within 60 s of session end with no press. Replace the old `debrief.js` auto-show trigger with `debrief-v4.js`.
5. Modify `sessionreview.js` hand-off: disable its auto-show after session; keep it available for DEEP DIVE. Do not change its data logic; existing `session-review-test.ps1` must still pass when the page is opened directly.
6. Add `debrief-v4.js`/`debrief-v4.css` to `index.html`; ensure old `debrief.js` is not loaded or its auto-show is disabled.
7. No frameworks, no drawn cars, real assets only.
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- new `dash\www\v2\debrief-v4.js`
- new `dash\www\v2\debrief-v4.css`
- `dash\www\v2\index.html` (hook)
- `dash\www\v2\sessionreview.js` (hand-off only)
- `tests\debrief-test.ps1`
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
`tests\debrief-test.ps1` new sections:
1. Pretend session end with a real fixture: screen up â¤ 60 s, no press.
2. Boxes within 20 px of the wireframe (measure each box).
3. 0 overlaps (measure every visible text element bounding box).
4. copy-audit 0 on the rendered screen.
5. Pictures `tests\shots\db-*.png` compared by the lead with the mockup.
Compile with `-NoDeploy`; deploy only when `irdeck-cli.exe state` shows `sim=False` (exit 2 = stop). copy-audit-test passes for any visible text.
## User journey (what Peter does and sees; how he would fail it)
Peter gets out after a race. Within 60 s the top screen shows the race result, position by lap, pace vs field, and the three corners looping. He fails it if the screen does not appear, a clip shows the wrong corner, text overlaps, or copy-audit fails.
## Not in this card (what to leave for later cards)
Incident video clips and button actions (D-04), deck/phone (D-05), live check (D-06).
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\D-03.md` with CARD, RESULT, GATE, FILES, NEEDS PETER, NEEDS LEAD, NOTES. Tick the card status in `docs\TASKS.md` if present.

=== FILE: docs\cards\v4\D-04.md ===
# D-04 Incidents with video + one-press bar
**Phase / depends on / size / needs Peter:** Phase 1 / depends on D-03 / size M / needs Peter: none
## Why (2-4 lines: what Peter gets, which signature moment)
The debrief screen becomes fully usable. Peter can watch incident clips, press SAVE once to keep the session forever, queue a share video, open Cosworth when installed, and jump straight into the Workbench on the corner that cost the most.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `COPY-RULES.md` â safety rules, C# 5, no frameworks, no iRacing file writes.
- `docs\vault.md` sections "Whole sessions (S1)" and "Share video and the replay jump" â SAVE route, sidecar incidents, share routes.
- `docs\ARCHITECTURE.md` â `/share/make`, `/vault/list` cosworth installed flag, Workbench open URL.
- `dash\src\debrief.cs` from D-01/D-02 â extend `/debrief?id=` with incidents.
- `dash\src\share.cs` â route reuse for SHARE.
- `dash\src\vault.cs` â `recsave` route for SAVE.
- `dash\www\v2\debrief-v4.js` from D-03 â wire buttons and incident rows.
- `dash\www\v2\workbench.html`/`workbench.js` â DEEP DIVE target.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find out the exact SAVE route (`POST /api/rec/save?id=`), SHARE route (`GET /share/make?id=`), Cosworth installed flag (`/vault/list` `cosworth.installed`), and Workbench open URL pattern in existing code; write them in the report.
2. Extend `dash\src\debrief.cs` `/debrief?id=` to include `incidents` array: `{lap, corner, type, time, videoId}`. Cut incident clips from the session mp4 using sidecar incident times, same `-c copy` method as D-02.
3. In `debrief-v4.js`, wire INCIDENTS rows with `â¶ 30 s` buttons that play the incident clip.
4. Wire SAVE button to `POST /api/rec/save?id=<session id>` and show SAVED idempotently (if already saved, still SAVED, no duplicate move).
5. Wire SHARE button to `GET /share/make?id=<clip id or lap id>` and show queued status.
6. Wire COSWORTH button only when `/vault/list` says installed; otherwise hide it.
7. Wire DEEP DIVE button to open `workbench.html?id=<file or lap>&lap=<n>&page=driver` on the worst corner from `/debrief`.
8. Ensure buttons are large, one press, no dead buttons.
9. Add tests to `tests\debrief-test.ps1`.
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- `dash\www\v2\debrief-v4.js`
- `dash\src\debrief.cs`
- read `dash\src\share.cs` (route reuse)
- read `dash\src\vault.cs` (recsave)
- `tests\debrief-test.ps1`
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
`tests\debrief-test.ps1` new sections:
1. Incident clips with lap/corner present and playable.
2. SAVE â SAVED idempotent (second press still SAVED, no duplicate file).
3. SHARE queues `/share/make`.
4. COSWORTH button only when installed.
5. DEEP DIVE opens Workbench on the worst corner.
Compile with `-NoDeploy`; deploy only when `irdeck-cli.exe state` shows `sim=False` (exit 2 = stop). copy-audit-test passes for any visible text.
## User journey (what Peter does and sees; how he would fail it)
Peter presses SAVE once and sees SAVED. He presses DEEP DIVE and lands on T10a. He fails it if SAVE is not idempotent, SHARE does not queue, COSWORTH shows when not installed, or DEEP DIVE opens the wrong corner.
## Not in this card (what to leave for later cards)
Deck/phone debrief (D-05), live check (D-06).
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\D-04.md` with CARD, RESULT, GATE, FILES, NEEDS PETER, NEEDS LEAD, NOTES. Tick the card status in `docs\TASKS.md` if present.

=== FILE: docs\cards\v4\D-05.md ===
# D-05 Debrief deck row + phone debrief
**Phase / depends on / size / needs Peter:** Phase 1 / depends on D-04 / size S / needs Peter: none (Install later)
## Why (2-4 lines: what Peter gets, which signature moment)
The four debrief actions become one press on the Stream Deck and on the iPhone. Peter can SAVE, SHARE, OPEN IN COSWORTH, and DEEP DIVE from the deck or the sofa, with the same debrief data on both.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `COPY-RULES.md` â safety rules, C# 5, no frameworks, no iRacing file writes.
- `docs\ARCHITECTURE.md` â add-on and phone sections, `/api/do` whitelist.
- `deck-intro\plugin.html` â ANALYSIS screen structure and how keys send commands.
- `dash\src\deckfeed.cs` â existing `wb-*` command relay.
- `dash\src\irdash.cs` â `/api/do` whitelist.
- `dash\www\phone\app.js` â phone LAPS tab and session review patterns.
- `dash\src\phone.cs` â phone state JSON.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find out the exact existing command names for SAVE/SHARE/COSWORTH/DEEP DIVE in `/api/do` whitelist and `deckfeed.cs`; write them in the report. If a command is missing, add it to the whitelist in `dash\src\irdash.cs` and `deckfeed.cs`.
2. In `deck-intro\plugin.html`, add four keys to the ANALYSIS row (or a new DEBRIEF row) labelled SAVE, SHARE, COSWORTH, DEEP DIVE. They send the commands found in step 1 with the current debrief session id. Keys must be dimmed when no debrief is showing.
3. In `dash\www\phone\app.js`, add a debrief view to the LAPS tab: when `/phone/state` reports a just-ended session, fetch `/debrief?id=<newest>` and render the same result/position/pace/corners/incidents and four buttons as the top screen, within 60 s of session end. Reuse existing phone session review patterns.
4. Do NOT run `deck-intro\install.ps1` or `build-deck.ps1`; prepare only. If `plugin.html` changes, bump `$ver` in `deck-intro\install.ps1` and note it.
5. Add tests: `tests\deck-screens-test.ps1` new section for the four keys; `tests\phone-test.ps1` new section phone shows same debrief within 60 s.
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- `deck-intro\plugin.html` (ANALYSIS row)
- `dash\www\phone\app.js`
- `tests\deck-screens-test.ps1`
- `tests\phone-test.ps1`
- smallest edit: `deck-intro\install.ps1` version bump only (report it)
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
`tests\deck-screens-test.ps1` new section: keys-test 0 dead for the four new keys.
`tests\phone-test.ps1` new section: phone shows the same debrief within 60 s.
Compile with `-NoDeploy`; deploy only when `irdeck-cli.exe state` shows `sim=False` (exit 2 = stop). copy-audit-test passes for any visible text.
## User journey (what Peter does and sees; how he would fail it)
Peter presses SAVE, SHARE, OPEN IN COSWORTH, or DEEP DIVE on the deck or phone; each works in one press. He fails it if any key is dead or the phone debrief does not appear within 60 s.
## Not in this card (what to leave for later cards)
Actual add-on install and MAIN build (K-02), live check (D-06).
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\D-05.md` with CARD, RESULT, GATE, FILES, NEEDS PETER, NEEDS LEAD, NOTES. Tick the card status in `docs\TASKS.md` if present.

=== FILE: docs\cards\v4\D-06.md ===
# D-06 Debrief live check
**Phase / depends on / size / needs Peter:** Phase 1 / depends on D-05 / size S live / needs Peter: One real race
## Why (2-4 lines: what Peter gets, which signature moment)
The debrief is proven on a real race, not just a fixture. Peter watches the screen after his next race and confirms the corners, videos, and position story are right. This is the Phase 1 gate.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md`, `CLAUDE.md`, `COPY-RULES.md` â safety rules, never act while he drives.
- `docs\SPEC-v4.md` Phase 1 gate and D-06 row.
- `tests\debrief-test.ps1` â existing debrief tests.
- `dash\src\debrief.cs` and `dash\www\v2\debrief-v4.js` â the code to fix if the live check fails.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. After Peter's next real race, when he is out of the car and `irdeck-cli.exe state` shows `sim=False` (or at least not driving), observe the debrief screen. Do not act while he drives.
2. Record in `docs\tasks\log\D-06.md`: time from session end to screen up (must be â¤ 60 s), corner names shown vs actual corners, videos loop correctly, position story vs iRacing's results page.
3. If any clip is the wrong corner or the result is off by one place, fix the smallest code/test issue in `dash\src\debrief.cs` or `debrief-v4.js` and re-run `tests\debrief-test.ps1`.
4. If all checks pass, mark D-06 done and write the report.
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- `docs\tasks\log\D-06.md`
- test fixes only (if needed)
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
After his real race: screen up â¤ 60 s; corners named right; videos loop; position story matches iRacing's results. If fixes are made, compile with `-NoDeploy` and deploy only when `irdeck-cli.exe state` shows `sim=False` (exit 2 = stop). copy-audit-test passes for any visible text.
## User journey (what Peter does and sees; how he would fail it)
Peter gets out after a real race and sees the debrief within 60 s. He fails it if any clip is the wrong corner or the result is off by one place.
## Not in this card (what to leave for later cards)
Phase 2 (HOME before driving).
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\D-06.md` with CARD, RESULT, GATE, FILES, NEEDS PETER, NEEDS LEAD, NOTES. Tick the card status in `docs\TASKS.md` if present.