=== FILE: docs\cards\v4\W-01.md ===
# W-01 Workbench the single surface + conditions line
**Phase / depends on / size / needs Peter:** Phase 3 / P0-10 / M / none

## Why
Peter opens the same lap from Sessions, Vault or the Session Review and must land in the same Workbench screen with the same lap, not three different trace views. The Workbench also gains the conditions line (air/track temperature, wind, skies, wetness) so every deep dive starts with the session facts.

## Read first
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` â safety rules, C# 5, copy rules.
- `docs\ARCHITECTURE.md` â routes, build/deploy, page reload rules.
- `docs\DESIGN-workbench.md` â Workbench pages and interaction model.
- `docs\vault.md` â Vault lap ids, race log, career, video.
- `docs\data.md` â Sessions page and lap analysis endpoints.
- `docs\research\ibt-channels.md` â weather channel names and units.
- Code: `dash\www\v2\sessions.js`, `dash\www\v2\vault.js`, `dash\www\v2\sessionreview.js`, `dash\www\v2\workbench.js`, `dash\src\analysis.cs`, `dash\src\workbench.cs`, `tests\workbench-test.ps1`.

## Build
1. Find the three current entry points: Sessions row click in `sessions.js`, Vault card click in `vault.js`, and the ANALYSIS button in `sessionreview.js`. Write in the report exactly which functions open a lap today and what URL parameters they use.
2. Make all three open `workbench.html?id=<file-or-vault-lap-id>&lap=<n>` with the lap the user was looking at: Sessions row opens that sessionâs best lap; Vault card opens that cardâs lap; Review ANALYSIS opens the reviewâs best lap (or the selected lap if one is selected).
3. Remove the Sessions pageâs own trace view from `sessions.js`. Keep the session list and lap list; the row click now opens the Workbench. Delete only the trace rendering code, not the list.
4. Add a conditions line to the Workbench header. Extend the Workbench state JSON in `dash\src\analysis.cs` (or `workbench.cs`, whichever already returns the state) with a `conditions` object: `airC`, `trackC`, `windMs`, `windDirDeg`, `skies`, `wetness`. Use the `.ibt` reader already in `analysis.cs`. For numeric channels use the median over the lapâs records; for `Skies` and `TrackWetness` use the most common value. Units: Â°C, m/s, degrees, iRacingâs own `Skies` and `TrackWetness` codes.
5. Render the conditions line in `workbench.js` as one short line, e.g. `Air 24 Â°C Â· Track 31 Â°C Â· Wind 2.1 m/s Â· Skies 1 Â· Wet 0`. Every visible word must pass `copy-audit-test.ps1`.
6. C# 5 only: no `$"..."`, `?.`, `nameof`, expression-bodied members, `out var`. No frameworks. Never write iRacing files. Never act while he drives.

## Files
- `dash\www\v2\sessions.js`
- `dash\www\v2\vault.js`
- `dash\www\v2\sessionreview.js`
- `dash\www\v2\workbench.js`
- `dash\src\analysis.cs`
- `dash\src\workbench.cs` (only if the state JSON lives there)
- `tests\workbench-test.ps1` (new sections)

Anything not listed is off limits except the smallest edit, reported.

## Gate
`tests\workbench-test.ps1`, new sections:
1. Sessions row opens `workbench.html` with the correct `id` and `lap` (3 checks: one per entry point).
2. Vault card opens `workbench.html` with the correct `id` and `lap`.
3. Review ANALYSIS opens `workbench.html` with the correct `id` and `lap`.
4. `sessions.js` no longer contains its own trace view (grep for the removed function names).
5. Conditions line values hand-checked on 2 real `.ibt` copies: the test prints the computed values and compares them to hand-read values from the files.

Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows `sim=False` â exit 2 = stop. `copy-audit-test` passes for any visible text.

## User journey
Peter opens a lap from Sessions, then the same lap from the Vault, then presses ANALYSIS on the Session Review. All three land on the same Workbench screen showing that lap, with the conditions line at the top. He fails it if any entry point shows a different lap or a different trace view.

## Not in this card
Multi-lap overlay, offset slide, navigator, soft events, constants, PSD, aero balance, setup A/B, map-by-channel polish. Those are W-02 to W-10.

## Report
Write `docs\tasks\log\W-01.md` in AGENTS.md format and tick the card status in `docs\TASKS.md`.

=== FILE: docs\cards\v4\W-02.md ===
# W-02 Multi-lap overlay 3+
**Phase / depends on / size / needs Peter:** Phase 3 / W-01 / M / none

## Why
Pi Toolbox and MoTeC let an engineer overlay several laps on one distance axis to see consistency and where a lap loses time. Peter adds laps 7, 9 and 12 and sees lap 12âs loss immediately, instead of comparing only two laps.

## Read first
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` â safety, C# 5, copy rules.
- `docs\DESIGN-workbench.md` â Workbench interaction model, fixed colours, distance axis.
- `docs\research\pi-toolbox-features.md` â multi-outing overlay behaviour.
- `docs\vault.md` â lap ids and the Workbench data path.
- Code: `dash\www\v2\workbench.js`, `dash\src\workbench.cs`, `tests\workbench-test.ps1`.

## Build
1. Read `workbench.js` to find the current two-lap data flow (current lap + reference) and `workbench.cs` to find the route that returns channel arrays. Write in the report the exact route and JSON shape.
2. Extend the server route in `dash\src\workbench.cs` to accept a `laps` parameter: a comma-separated list of lap ids (Vault lap ids or `<file>.ibt:<lap>`). Return one array set per lap, reusing the existing resampling in `analysis.cs`. C# 5 only.
3. In `workbench.js` add a lap picker that allows up to 6 laps. Use a fixed colour ramp from the existing Workbench palette: lap 1 gold, lap 2 cool white, lap 3 gain green, lap 4 timing purple, lap 5 timing yellow, lap 6 muted grey. Show a legend with each lap number and its lap time.
4. Draw all selected laps on the existing distance-axis traces (gap, speed, throttle, brake, steering, gear, RPM). The current lap stays solid; other laps are thinner or dotted so they remain distinguishable.
5. Add readouts per lap at the shared cursor: lap number, time, and the channel value under the cursor for the active trace.
6. Keep the reference lap behaviour unchanged when only two laps are selected. No frameworks. Never write iRacing files. Never act while he drives.

## Files
- `dash\www\v2\workbench.js`
- `dash\src\workbench.cs`
- `tests\workbench-test.ps1` (new sections)

Anything not listed is off limits except the smallest edit, reported.

## Gate
`tests\workbench-test.ps1`, new sections:
1. Server returns arrays for 3, 4 and 6 laps; each lapâs length matches the existing resampled length.
2. The page renders 6 laps Ã 8 traces with no overlap and a legend showing all 6 lap numbers and times.
3. Headless Chrome measures at least 50 fps while moving the cursor with 6 laps Ã 8 traces.
4. Readouts per lap show the correct value at the cursor for one hand-checked lap.

Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows `sim=False` â exit 2 = stop. `copy-audit-test` passes for any visible text.

## User journey
Peter opens a lap, adds laps 7, 9 and 12 from the picker, and sees all four traces on the same distance axis. Lap 12âs loss is visible against the others. He fails it if the page slows below 50 fps or the legend does not name each lap.

## Not in this card
Time-offset slide and auto-align (W-03), navigator playback (W-04), map-by-channel polish (W-10).

## Report
Write `docs\tasks\log\W-02.md` in AGENTS.md format and tick the card status in `docs\TASKS.md`.

=== FILE: docs\cards\v4\W-03.md ===
# W-03 Time-offset slide with auto-align
**Phase / depends on / size / needs Peter:** Phase 3 / W-02 / M / none

## Why
Laps drift apart by distance, so a braking point can appear shifted. Pi Toolboxâs O key and MoTeCâs offset axis line laps up at one event. Peter presses OFFSET AUTO on the deck and the brake traces line up at the brake point in view.

## Read first
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` â safety, C# 5, copy rules.
- `docs\DESIGN-workbench.md` â offset slide and auto-align requirement.
- `docs\research\pi-toolbox-features.md` â time offset (O) behaviour.
- `docs\research\competitors-pro-engineering.md` â MoTeC offset axis.
- Code: `dash\www\v2\workbench.js`, `deck-intro\plugin.html` (ANALYSIS screen), `tests\workbench-test.ps1`.

## Build
1. Read `workbench.js` to find the current reference lap drawing and any existing offset state. Read `deck-intro\plugin.html` to find the ANALYSIS screenâs OFFSET key label. Write in the report the current key label and its command.
2. Add offset state to `workbench.js`: `S.offsetM` (metres) and `S.offsetS` (seconds). The reference lap is shifted by `S.offsetM` along the distance axis before drawing and before delta calculation.
3. Add manual controls: an offset row with `â` and `+` buttons (1 m steps) and a readout `OFFSET +12 m Â· +0.31 s`. Keyboard `O` toggles offset mode; left/right arrows nudge by 1 m.
4. Add AUTO align: find the first sample in the current zoom range where `Brake > 0.10` before the corner apex (reuse the brake-point threshold from `analysis.cs`). Compute the distance difference between the reference lap and the current lap at that brake point, set `S.offsetM` to that difference, and recompute `S.offsetS` using the average speed in the zoom range.
5. Update `deck-intro\plugin.html` only the OFFSET key label to `OFFSET AUTO` and its command to the new auto-align action. Do not run `install.ps1` or `build-deck.ps1`; report the change for the lead.
6. No C# changes expected. No frameworks. Never write iRacing files. Never act while he drives.

## Files
- `dash\www\v2\workbench.js`
- `deck-intro\plugin.html` (one key label/command only)
- `tests\workbench-test.ps1` (new sections)

Anything not listed is off limits except the smallest edit, reported.

## Gate
`tests\workbench-test.ps1`, new sections:
1. Manual offset shifts the reference trace by exactly the chosen metres and shows offset in m and s.
2. AUTO align on a synthetic lap with a known 30 m shift recovers the shift within 2 m.
3. The deck key label in `plugin.html` reads `OFFSET AUTO` and its command is the new action.
4. No visible text fails `copy-audit-test`.

Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows `sim=False` â exit 2 = stop.

## User journey
Peter opens two laps, presses OFFSET AUTO on the deck, and the brake traces line up at the brake point in view. He fails it if the offset is wrong by more than 2 m or the key does nothing.

## Not in this card
Navigator playback (W-04), soft events (W-05), map-by-channel polish (W-10).

## Report
Write `docs\tasks\log\W-03.md` in AGENTS.md format and tick the card status in `docs\TASKS.md`.

=== FILE: docs\cards\v4\W-04.md ===
# W-04 Navigator 0.5-8x incl. reverse
**Phase / depends on / size / needs Peter:** Phase 3 / W-01 / S / none

## Why
Pi Toolboxâs navigator plays laps at 0.5x to 8x, forward and reverse, so an engineer can scrub a corner slowly. Peter scrubs a corner backwards at half speed and the map, traces and video stay in step.

## Read first
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` â safety, C# 5, copy rules.
- `docs\DESIGN-workbench.md` â navigator playback requirement.
- `docs\research\pi-toolbox-features.md` â Navigator section (0.5, 1, 2, 4, 8x, reverse).
- `docs\vault.md` â video sync and `lapStartOffset`.
- Code: `dash\www\v2\workbench.js`, `dash\www\v2\workbench-video.js`, `tests\workbench-test.ps1`.

## Build
1. Read `workbench.js` to find the current playback loop and cursor advance. Read `workbench-video.js` to find how video time is set from the cursor. Write in the report the current speed values and video sync method.
2. Add speed control to `workbench.js`: buttons or keys for `0.5x`, `1x`, `2x`, `4x`, `8x`, and a reverse toggle. Reverse uses negative speeds.
3. Cursor advance: at each animation frame, advance the cursor by `speed Ã elapsed Ã 60` samples (or the equivalent distance/time step). For reverse, advance negatively. Keep the cursor within the lap bounds.
4. Video sync: for forward playback, set video time from the cursor as today. For reverse, do not rely on HTML5 reverse playback; seek the video to the cursor time every 100 ms (10 Hz seeks). Use the existing `lapStartOffset` mapping from `workbench-video.js`.
5. Ensure the map dot, every trace and the video all use the same cursor time/distance. No frameworks. Never write iRacing files. Never act while he drives.

## Files
- `dash\www\v2\workbench.js`
- `dash\www\v2\workbench-video.js`
- `tests\workbench-test.ps1` (new sections)

Anything not listed is off limits except the smallest edit, reported.

## Gate
`tests\workbench-test.ps1`, new sections:
1. Cursor rate for 0.5x, 1x, 2x, 4x, 8x forward is within 5% of the expected rate.
2. Cursor rate for reverse is within 5% of the expected rate.
3. Map dot, trace cursor and video time agree within 0.1 s at 3 checkpoints during reverse playback.
4. Reverse video uses 10 Hz seeks (test observes at least one seek per 100 ms window).

Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows `sim=False` â exit 2 = stop. `copy-audit-test` passes for any visible text.

## User journey
Peter opens a lap, sets 0.5x reverse, and scrubs a corner backwards. The map dot, traces and video move together. He fails it if the video lags the traces by more than 0.1 s or the cursor rate is off by more than 5%.

## Not in this card
Soft events (W-05), constants and lookup tables (W-06), PSD/FFT (W-07).

## Report
Write `docs\tasks\log\W-04.md` in AGENTS.md format and tick the card status in `docs\TASKS.md`.

=== FILE: docs\cards\v4\W-05.md ===
# W-05 Soft events (equation-defined)
**Phase / depends on / size / needs Peter:** Phase 3 / W-01 / M / none

## Why
Pi Toolbox lets an engineer define soft events by equation and jump to them. Peter types `Brake > 0.9 && Speed > 60` once, and every lap lists those moments; clicking one moves the cursor there.

## Read first
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` â safety, C# 5, copy rules.
- `docs\DESIGN-workbench.md` â events list and soft events requirement.
- `docs\research\pi-toolbox-features.md` â Soft Events section (equation, rises/falls/min/max).
- `docs\research\ibt-channels.md` â channel names and units.
- Code: `dash\src\protools.cs` (expression parser), `dash\src\analysis.cs` (existing events), `dash\www\v2\workbench.js` (events list), `tests\analysis-test.ps1`.

## Build
1. Read `protools.cs` to find the expression parser and its supported operators. Read `analysis.cs` to find existing event generation (ABS, lock-ups, off-track, incidents, passes). Write in the report the parser entry points and the existing event JSON shape.
2. Extend `protools.cs` to parse soft event definitions. A definition has: `name`, `equation` (using the same channel names and operators as the expression parser), and `kind` (`rises`, `falls`, `min`, `max`). Save definitions per car in `vault\events\<car>.json` (new folder; new file per car).
3. Evaluate each definition on the lapâs raw `.ibt` records at 60 Hz. For `rises`/`falls`, emit an event when the equation value crosses from false to true (or true to false for `falls`). For `min`/`max`, emit an event at the sample where the equation value reaches its minimum or maximum over the lap.
4. Add a route in `analysis.cs` (or `protools.cs`) that returns soft events for a lap: `{lap, time, distPct, corner, name}`. Reuse the corner lookup from `analysis.cs`.
5. In `workbench.js`, list soft events with the existing events list. Clicking an event moves the shared cursor to that time/distance.
6. C# 5 only. No frameworks. Never write iRacing files. Never act while he drives.

## Files
- `dash\src\protools.cs`
- `dash\src\analysis.cs`
- `dash\www\v2\workbench.js`
- `vault\events\` (new folder; new `<car>.json` files)
- `tests\analysis-test.ps1` (new sections)

Anything not listed is off limits except the smallest edit, reported.

## Gate
`tests\analysis-test.ps1`, new sections:
1. The definition `Brake > 0.9 && Speed > 60` with `kind=rises` produces the expected events on a real lap; 3 events hand-checked against the raw records.
2. `kind=falls`, `kind=min`, `kind=max` each produce the expected event for a synthetic channel.
3. Definitions are saved per car and reloaded for the next lap.
4. The Workbench events list shows the soft events and clicking one moves the cursor.

Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows `sim=False` â exit 2 = stop. `copy-audit-test` passes for any visible text.

## User journey
Peter types the equation once on the PRO page, opens any lap of that car, and sees the events listed. He taps one and the cursor jumps there. He fails it if the event list is empty or the cursor lands at the wrong time.

## Not in this card
Constants and lookup tables (W-06), events with PAUSE/JUMP into iRacing replay (W-11/W-12).

## Report
Write `docs\tasks\log\W-05.md` in AGENTS.md format and tick the card status in `docs\TASKS.md`.

=== FILE: docs\cards\v4\W-06.md ===
# W-06 Constants + lookup tables
**Phase / depends on / size / needs Peter:** Phase 3 / W-05 / M / none

## Why
Pi Toolbox uses constants and lookup tables so equations can use car-specific values and curves. Peter loads a gear table and a formula turns RPM into wheel speed, without retyping values.

## Read first
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` â safety, C# 5, copy rules.
- `docs\DESIGN-workbench.md` â PRO page and expression channels.
- `docs\research\pi-toolbox-features.md` â Constants and Lookup Tables sections (CONST(), 1D/2D, snap/interpolate).
- Code: `dash\src\protools.cs` (expression parser), `dash\www\v2\workbench-pro.js` (PRO page), `tests\analysis-test.ps1`.

## Build
1. Read `protools.cs` to find the expression parser and whether `CONST` or table functions already exist. Read `workbench-pro.js` to find the PRO page UI. Write in the report the current parser function names and the PRO page structure.
2. Add a constants store per car: `vault\tables\<car>.constants.json` (new folder `vault\tables\`, new file per car). Each constant is `{name, value, unit}`.
3. Extend the expression parser in `protools.cs` to support `CONST(name)` and `TABLE(name, x)` / `TABLE2(name, x, y)`. C# 5 only.
4. Add lookup table loading from `vault\tables\*.csv`. Define CSV format: 1D table has two columns `input,output`; 2D table has first row as column inputs and first column as row inputs, with output cells in the body. Support `snap` and `interpolate` modes; default `interpolate`.
5. In `workbench-pro.js`, add a small editor: list constants and tables for the current car, add/edit/delete constants, and add/remove table files. Save to the paths above.
6. Test a hand calculation: a gear table that maps RPM to wheel speed, and a formula using `CONST` and `TABLE`. No frameworks. Never write iRacing files. Never act while he drives.

## Files
- `dash\src\protools.cs`
- `dash\www\v2\workbench-pro.js`
- `vault\tables\` (new folder; new `<car>.constants.json` and `*.csv` files)
- `tests\analysis-test.ps1` (new sections)

Anything not listed is off limits except the smallest edit, reported.

## Gate
`tests\analysis-test.ps1`, new sections:
1. `CONST(name)` returns the saved value for the current car.
2. A 1D table with `interpolate` returns the hand-calculated value at a midpoint.
3. A 2D table with `snap` returns the hand-calculated value at a grid point.
4. The PRO page lists constants and tables and can save a new constant.
5. The gear-table formula produces the expected wheel speed for one hand-checked RPM.

Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows `sim=False` â exit 2 = stop. `copy-audit-test` passes for any visible text.

## User journey
Peter opens the PRO page, adds a gear table CSV, and types a formula using `TABLE`. The trace shows wheel speed from RPM. He fails it if the table value is wrong or the formula does not evaluate.

## Not in this card
PSD/FFT display (W-07), aero balance (W-08), setup A/B (W-09).

## Report
Write `docs\tasks\log\W-06.md` in AGENTS.md format and tick the card status in `docs\TASKS.md`.

=== FILE: docs\cards\v4\W-07.md ===
# W-07 PSD/FFT display
**Phase / depends on / size / needs Peter:** Phase 3 / W-01 / M / none

## Why
Pi Toolbox and MoTeC show power spectral density so an engineer can see damper and vertical acceleration frequencies. Peter opens the SUSPENSION page and sees a damper frequency peak per corner of the car.

## Read first
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` â safety, C# 5, copy rules.
- `docs\DESIGN-workbench.md` â SUSPENSION page and PSD requirement.
- `docs\research\pi-toolbox-features.md` â PSD Chart section.
- `docs\research\ibt-channels.md` â `*shockVel` and `VertAccel` channel names and units.
- Code: `dash\src\analysis.cs` (channel arrays), `dash\www\v2\workbench.js` (SUSP block), `dash\www\v2\workbench-pro.js`, `dash\build.ps1` (`$src` list), `tests\analysis-test.ps1`.

## Build
1. Read `analysis.cs` to find how channel arrays are returned for a lap. Read `workbench.js` SUSP block and `workbench-pro.js` to find where a new display belongs. Write in the report the route and JSON shape for channel arrays.
2. Create new `dash\src\psd.cs` (C# 5 only). Implement a Radix-2 FFT, a Hann window, and a PSD function: input `float[]` samples at 60 Hz, output frequency bins (Hz) and dB values. Add `psd.cs` to the `$src` line in `dash\build.ps1`.
3. Add a route `GET /analysis/psd?file=<file>&lap=<n>&channel=<shockVel|VertAccel>&range=<lap|zoom>&start=<distPct>&end=<distPct>`. Use the existing `.ibt` reader. For `shockVel`, compute PSD for each corner channel (`LFshockVel`, `RFshockVel`, `LRshockVel`, `RRshockVel`); for `VertAccel`, one PSD. Return `{freqHz[], db[], corners:{...}}`.
4. In `workbench.js` SUSP block, add a PSD display: frequency on the x-axis, dB on the y-axis, one trace per corner for shock velocity. Add a log/linear y-axis toggle.
5. Test with a synthetic 3 Hz sine: the PSD peak must be at 3.0 Â± 0.1 Hz. Also test on a real lap.
6. No frameworks. Never write iRacing files. Never act while he drives.

## Files
- `dash\src\psd.cs` (new)
- `dash\build.ps1` (`$src` line only)
- `dash\www\v2\workbench.js`
- `dash\www\v2\workbench-pro.js` (only if the display lives there)
- `tests\analysis-test.ps1` (new sections)

Anything not listed is off limits except the smallest edit, reported.

## Gate
`tests\analysis-test.ps1`, new sections:
1. Synthetic 3 Hz sine: PSD peak at 3.0 Â± 0.1 Hz.
2. Radix-2 FFT returns the correct bin count for a 1024-sample input.
3. `/analysis/psd` returns frequency and dB arrays for `shockVel` and `VertAccel` on a real lap.
4. The SUSPENSION page renders the PSD display with one trace per corner and a log/linear toggle.

Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows `sim=False` â exit 2 = stop. `copy-audit-test` passes for any visible text.

## User journey
Peter opens the SUSPENSION page and sees a frequency peak per corner of the car. He fails it if the PSD is blank or the peak is at the wrong frequency.

## Not in this card
Aero balance (W-08), setup A/B (W-09), map-by-channel polish (W-10).

## Report
Write `docs\tasks\log\W-07.md` in AGENTS.md format and tick the card status in `docs\TASKS.md`.

=== FILE: docs\cards\v4\W-08.md ===
# W-08 Aero balance
**Phase / depends on / size / needs Peter:** Phase 3 / W-01 / M / none

## Why
Pi Toolbox Plus shows aero balance as a front share percentage. Peter sees a front-share number per lap on the SUSPENSION page, and it is blank when the carâs spring rates are not sourced.

## Read first
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` â safety, C# 5, copy rules.
- `docs\DESIGN-workbench.md` â SUSPENSION page and aero balance requirement.
- `docs\research\pi-toolbox-features.md` â Aero load balance section (front share %, lap average above 200 km/h).
- `docs\research\ibt-channels.md` â ride height channels and units.
- `docs\research\car-assets-steering.md` â CarTable constants and missing values.
- Code: `dash\src\deepdive.cs` (CarTable, ride height), `dash\www\v2\workbench.js` (SUSP block), `tests\analysis-test.ps1`.

## Build
1. Find out in `dash\src\deepdive.cs` whether front and rear spring rates exist in `CarTable` for the current car, and whether any source is recorded. Write the exact finding in the report. If absent, the aero balance block must show blank and the report must say which car lacks values.
2. Add aero balance computation to `deepdive.cs`. Use the Cosworth Plus formula from `pi-toolbox-features.md` section 5.1: front share % = `100 Ã (ÎrideHeightF Ã kF) / (ÎrideHeightF Ã kF + ÎrideHeightR Ã kR)`, where `ÎrideHeight` is the change from the lapâs static ride height (median of the first 10 samples or the garage value) and `kF`/`kR` are front/rear spring rates from `CarTable`. Units: ride height in metres, spring rate in N/m.
3. Compute the lap average only while `Speed > 200 km/h` (convert from m/s: `Speed * 3.6 > 200`). Return `frontSharePct` per lap.
4. Add a route or extend the existing deep-dive route to include `aeroBalance: {frontSharePct, sourced: true|false}`.
5. In `workbench.js` SUSP block, show `AERO BALANCE Â· Front 47.2 %` when sourced; show `AERO BALANCE Â· â` when unsourced. No visible text may claim a value without a source.
6. C# 5 only. No frameworks. Never write iRacing files. Never act while he drives.

## Files
- `dash\src\deepdive.cs`
- `dash\www\v2\workbench.js`
- `tests\analysis-test.ps1` (new sections)

Anything not listed is off limits except the smallest edit, reported.

## Gate
`tests\analysis-test.ps1`, new sections:
1. On a real file with sourced spring rates, the front share % matches one hand-calculated value within 0.5 percentage points.
2. The lap average uses only samples above 200 km/h.
3. On a car without sourced spring rates, the route returns `sourced:false` and the page shows a blank value, not a guessed number.
4. No visible text fails `copy-audit-test`.

Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows `sim=False` â exit 2 = stop.

## User journey
Peter opens the SUSPENSION page and sees a front-share number per lap. He fails it if the number appears for a car without sourced spring rates, or if the value is wrong.

## Not in this card
Setup A/B from logged changes (W-09), map-by-channel polish (W-10).

## Report
Write `docs\tasks\log\W-08.md` in AGENTS.md format and tick the card status in `docs\TASKS.md`.

=== FILE: docs\cards\v4\W-09.md ===
# W-09 Setup A/B from logged changes
**Phase / depends on / size / needs Peter:** Phase 3 / W-01 / M / none

## Why
Engineers compare setup changes against lap time. Peter sees `Bias 56.0 â 55.0 Â· T1 â0.06 Â· T10a +0.04 (4 vs 5 laps)` and knows whether a change helped, with the sample size.

## Read first
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` â safety, C# 5, copy rules.
- `docs\DESIGN-workbench.md` â TYRES/SETUP block and data-note thresholds.
- `docs\research\ibt-channels.md` â `dcBrakeBias`, `dcTractionControl`, `dcABS` channels.
- `docs\vault.md` â career and session grouping.
- Code: `dash\src\deepdive.cs` (ChangesJson), `dash\src\career.cs` (session grouping), `dash\src\analysis.cs` (C-30 thresholds), `dash\www\v2\workbench.js` (TYRES/SETUP block), `tests\analysis-test.ps1`.

## Build
1. Read `deepdive.cs` to find the existing `ChangesJson` and how it detects setting changes. Read `career.cs` to find how sessions of one car+track+layout are grouped. Read `analysis.cs` to find the C-30 thresholds. Write in the report the exact function names and JSON shapes.
2. Extend `deepdive.cs` to detect changes in `dcBrakeBias`, `dcTractionControl`, `dcABS` within a session and between sessions of the same car+track+layout. Use the raw `.ibt` records. For each change, record the old and new values.
3. For each change, compute lap medians before and after using clean laps only (reuse `LapRules.Judge` from `analysis.cs`). Compute per-corner medians using the existing corner metrics. Include `nBefore` and `nAfter`.
4. Add a route `GET /analysis/setup-ab?file=<file>&car=<car>&track=<track>&config=<config>` returning changes with `{setting, old, new, lapBefore, lapAfter, corners:[{name, delta}], nBefore, nAfter}`.
5. In `workbench.js` TYRES/SETUP block, show one row per change. Show the sentence only when the C-30 thresholds are met (corner time difference â¥ 0.05 s and a metric differs clearly); otherwise show the numbers without a sentence.
6. C# 5 only. No frameworks. Never write iRacing files. Never act while he drives.

## Files
- `dash\src\deepdive.cs`
- `dash\src\career.cs` (only if session grouping needs a small change)
- `dash\www\v2\workbench.js`
- `tests\analysis-test.ps1` (new sections)

Anything not listed is off limits except the smallest edit, reported.

## Gate
`tests\analysis-test.ps1`, new sections:
1. A change in `dcBrakeBias` within a session is detected with the correct old and new values.
2. Lap medians before/after and per-corner medians match hand-checked values on a real file.
3. The sentence appears only when C-30 thresholds are met; otherwise only numbers appear.
4. The example row `Bias 56.0 â 55.0 Â· T1 â0.06 Â· T10a +0.04 (4 vs 5 laps)` renders correctly with real data.

Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows `sim=False` â exit 2 = stop. `copy-audit-test` passes for any visible text.

## User journey
Peter changes brake bias during a session, then opens the TYRES/SETUP page and sees the before/after lap and corner differences with the sample size. He fails it if the change is missed or the sentence appears without clear data.

## Not in this card
Map-by-channel polish (W-10), fastest car per corner (W-13).

## Report
Write `docs\tasks\log\W-09.md` in AGENTS.md format and tick the card status in `docs\TASKS.md`.

=== FILE: docs\cards\v4\W-10.md ===
# W-10 Map by any channel + XY/histogram polish
**Phase / depends on / size / needs Peter:** Phase 3 / W-02 / M / none

## Why
Pi Toolbox colours the track map by any channel and shows X/Y fits and histograms. Peter colours the map by ABS cut and sees exactly where ABS works, with the fit equation and histogram units clear.

## Read first
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` â safety, C# 5, copy rules.
- `docs\DESIGN-workbench.md` â map colour, X/Y fit, histogram requirements.
- `docs\research\pi-toolbox-features.md` â Map, X/Y, Histogram sections.
- `docs\research\ibt-channels.md` â channel names and units.
- Code: `dash\www\v2\workbench.js` (map colour), `dash\www\v2\workbench-pro.js` (X/Y, histogram), `tests\workbench-test.ps1`.

## Build
1. Read `workbench.js` to find the current map colour options (gap, speed) and the colour bar. Read `workbench-pro.js` to find the X/Y and histogram displays. Write in the report the current colour scale and the X/Y/histogram code paths.
2. Extend the map colour picker in `workbench.js` to accept any channel from the existing `/analysis/channels` list. Add a colour bar with the channel name and unit. Default remains gap; speed is second; any other channel is selectable from the channel picker.
3. In `workbench-pro.js`, ensure the X/Y display shows the polynomial fit equation and goodness of fit (reuse the existing fit code). If the equation is not currently visible, add it as a small line under the plot.
4. In the histogram display, add a toggle for the y-axis: `time` (seconds) or `%` (percentage of lap). The current default is time; the toggle must switch the axis label and scaling.
5. Add pictures to `tests\workbench-test.ps1`: map coloured by ABS cut, X/Y with fit equation, histogram in time and % modes.
6. No C# changes expected. No frameworks. Never write iRacing files. Never act while he drives.

## Files
- `dash\www\v2\workbench.js`
- `dash\www\v2\workbench-pro.js`
- `tests\workbench-test.ps1` (new sections and pictures)

Anything not listed is off limits except the smallest edit, reported.

## Gate
`tests\workbench-test.ps1`, new sections:
1. Map colour can be set to gap, speed, and any channel from `/analysis/channels`; the colour bar shows the channel name and unit.
2. Map coloured by ABS cut shows the expected high/low regions on a real lap (picture `tests\shots\wb-map-abscut.png`).
3. X/Y display shows the polynomial fit equation and goodness of fit (picture `tests\shots\wb-xy-fit.png`).
4. Histogram y-axis toggles between time and % with correct labels (pictures `tests\shots\wb-hist-time.png`, `wb-hist-pct.png`).
5. No visible text fails `copy-audit-test`.

Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows `sim=False` â exit 2 = stop.

## User journey
Peter opens the map, picks ABS cut, and sees where ABS works. He opens X/Y and reads the fit equation; he opens the histogram and switches between time and percent. He fails it if the colour bar is missing or the equation is not shown.

## Not in this card
Events with PAUSE/JUMP (W-11/W-12), fastest car per corner (W-13).

## Report
Write `docs\tasks\log\W-10.md` in AGENTS.md format and tick the card status in `docs\TASKS.md`.