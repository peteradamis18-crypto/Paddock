=== FILE: docs\cards\v4\T-02.md ===
# T-02 Timing tower
**Phase / depends on / size / needs Peter:** Phase 4 / T-01 / M / none
## Why
The room reads the race at a glance: position, number, name, gap, interval, last lap, PIT. Peter's row is gold. This is the broadcast tower from the 3d wireframe, drawn from the frozen-frame data T-01 already produces.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\SPEC-v4.md` section 3d (the tower's exact columns and look) and section J.
- `dash\src\tv.cs` (the T-01 engine: what `/tv` returns per car - field names, units, the frozen-frame guarantee).
- `dash\www\v2\theme.css` (tokens: colours, type scale, hairlines, tabular numbers).
- `dash\www\v2\core.js` and `index.html` (how panels are hosted and swapped; the TV panel hook T-01 added).
- `tests\tv-test.ps1` (the T-01 sections; extend, do not replace).
- `docs\research\competitors-broadcast-timing.md` (tower conventions: tabular gap column, car numbers in livery colour).
## Build
1. Find out the exact JSON shape `/tv` returns (field names for position, class position, number, name, gap, interval, last lap, pit flag, class colour, Peter's car) in `dash\src\tv.cs`; write it in the report.
2. New `dash\www\v2\tvview.js` and `tvview.css`. The tower is a 560-px-wide column on the left of the TV panel, per the 3d wireframe.
3. Rows, top to bottom, one per car in race position order. Each row: position number, car number in the car's class colour, driver name, gap to leader, interval to the car ahead, last lap time, and a PIT word when `OnPitRoad` is true. Peter's row: gold background tint and gold text. Class strip: a 4-px vertical bar on the row's left edge in the class colour (multiclass only; hidden when one class).
4. Typography: Bahnschrift, tabular numbers, body >= 22 px, labels >= 14 px small caps. Gap and interval formatted as `+3.2` (one decimal, seconds); last lap as `1:19.9`. No text overlaps at 1920x1080 with 20 cars (the test measures).
5. The tower draws only from one `/tv` answer per tick (10 Hz); no per-car requests. Cap canvas redraws at 30 fps. No animation beyond the data changing.
6. Empty states: no session -> the panel shows nothing (the TV panel is hidden when there is no session, per T-01). Fewer than 2 cars -> tower shows the one row.
7. Copy-audit: every visible word is a number, a name, a state word, or a column label. No filler.
## Files
- new `dash\www\v2\tvview.js`
- new `dash\www\v2\tvview.css`
- `dash\www\v2\theme.css` (only if a token is missing; smallest edit, reported)
- `dash\www\v2\index.html` (only the script/link tags for the two new files, if T-01 did not already add them)
- `tests\tv-test.ps1` (extend)
- `docs\tasks\log\T-02.md` (report)
## Gate
`tests\tv-test.ps1` new sections, all with numbers:
- Tower rows equal the pretend race's position order; Peter's row is gold; PIT appears for the pitted car; gap and interval match the frozen-frame values to 0.1 s; last lap matches.
- 0 text overlaps at 1920x1080 with the 20-car pretend race (measure every visible text element's bounding box).
- Class strip present with 2 classes, absent with 1.
- Copy-audit-test passes for the TV panel's visible text.
- Compile: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0. Deploy only when `irdeck-cli.exe state` shows sim=False; exit 2 = stop.
- Pictures: `tests\shots\tv-tower-race.png`, `tv-tower-multiclass.png`.
## User journey
Peter presses TV while racing. A friend looks up and reads "P3 #4 PETER +3.8" and the gap to P4 in one glance. Peter fails it if his row is not gold, if a gap is wrong by more than 0.1 s, or if any text overlaps at 20 cars.
## Not in this card
The map (T-03), the director label and inputs lower-third (T-04), replay TV between stints (T-05), the deck TV key (K-02), design-token sweep (DS-03).
## Report
AGENTS.md format to `docs\tasks\log\T-02.md`.

=== FILE: docs\cards\v4\T-03.md ===
# T-03 Map with every car
**Phase / depends on / size / needs Peter:** Phase 4 / T-01, P0-05 / M / none
## Why
The room sees the whole race on the real track outline: every car a dot in its class colour, Peter gold with #4, the leader marked, battle pairs ringed. This is the right half of the 3d wireframe, flat, no invented hills.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\SPEC-v4.md` section 3d (map rules: real outline, class colours, Peter gold #4, leader marked, battle pair ringed, start/finish, sector ticks, pit lane) and section J.
- `dash\src\tv.cs` (the `/tv` per-car fields: LapDistPct, position, class position, class colour, number, battle state from T-01).
- `dash\www\v2\map.js` and `corners.js` (the real outline: `TrackMap`, `TrackInfo`, `Corners.draw`; how existing pages project LapDistPct to canvas points).
- `dash\www\v2\tvview.js` and `tvview.css` from T-02 (the panel layout the map joins).
- `tests\tv-test.ps1` (extend).
- `docs\corners.md` (the outline source and the projection API).
## Build
1. Find out the exact `/tv` JSON field names for each car's LapDistPct, class colour, number, position, and the battle pairs T-01 computed; write them in the report.
2. In `tvview.js`, add the map to the right of the tower: 1300x700 px, flat, the real outline from `TrackMap`/`Corners` (the same data the Workbench map uses). No perspective hills.
3. Every car is a dot at its LapDistPct on the outline, in its class colour. Peter's car: gold dot with `#4` beside it. The leader: a thin ring around its dot. Battle pairs (from T-01's battle list): a ring around both dots. Start/finish line, sector ticks, and pit lane drawn from `Corners.draw` with `ticks:true, pit:true, names:false, credit:false`.
4. Dots update from one `/tv` answer per tick (10 Hz); canvas capped at 30 fps. No per-car requests. No labels for every car (numbers only for Peter and the leader; the tower carries the names).
5. Empty states: no session -> panel hidden (T-01). No outline yet -> draw the bare lap bar with dots, no invented shape.
6. Copy-audit: the only words are the credit line when corners are shown (kept terse) and Peter's number. No filler.
## Files
- `dash\www\v2\tvview.js` (extend)
- `dash\www\v2\tvview.css` (extend)
- `tests\tv-test.ps1` (extend)
- `docs\tasks\log\T-03.md` (report)
## Gate
`tests\tv-test.ps1` new sections, all with numbers:
- With the pretend race: every car's dot is within 2 px of the outline point for its LapDistPct; Peter's dot is gold with #4; the leader has the ring; the battle pair from T-01 has rings on both.
- The map is flat: the outline's y coordinates equal the projection's y (no invented height).
- 30 fps cap: with 20 cars and 10 Hz data, the canvas redraws at most 30 times per second (count frames over 2 s).
- Copy-audit-test passes for the map's visible text.
- Compile: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0. Deploy only when `irdeck-cli.exe state` shows sim=False; exit 2 = stop.
- Pictures: `tests\shots\tv-map-race.png`, `tv-map-battle.png`.
## User journey
Peter presses TV. A friend sees the real Road Atlanta outline with every car on it, Peter's gold #4 in the battle ring. Peter fails it if a dot is on the wrong part of the track, if the map looks invented, or if the battle ring is missing when two cars are within 0.8 s.
## Not in this card
The director label and inputs lower-third (T-04), replay TV between stints (T-05), the deck TV key (K-02), design-token sweep (DS-03).
## Report
AGENTS.md format to `docs\tasks\log\T-03.md`.

=== FILE: docs\cards\v4\T-04.md ===
# T-04 Director label + inputs lower-third + cost
**Phase / depends on / size / needs Peter:** Phase 4 / T-02, T-03 / M / none
## Why
The room knows what it is watching: LEADER, BATTLE, CHASE or TRACK, chosen by rules, held 8-15 s. Peter's inputs sit in a broadcast lower-third. The whole TV panel costs at most 5 % of one core and never touches sim fps.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\SPEC-v4.md` section 3d (label rules and hold times; the lower-third contents; the cost budget) and section J.
- `dash\src\tv.cs` (the battle/chase data T-01 computed; where the label state should live - server or client).
- `dash\www\v2\tvview.js` and `tvview.css` from T-02/T-03 (the panel layout).
- `dash\www\v2\core.js` (how the live telemetry stream delivers Peter's gear, speed, throttle, brake, last lap, REC state).
- `dash\www\v2\index.html` (the panel swap hook; how other panels stay in place).
- `tests\tv-test.ps1` (extend).
- `docs\performance.md` (how Paddock measures its own cost; the Performance page).
## Build
1. Find out in `dash\src\tv.cs` whether the battle/chase state is already computed per tick and its exact field names; write them in the report. If it is not, add it there (one frozen frame, same tick as the tower/map data).
2. Label rules, evaluated per tick, held 8-15 s once chosen: LEADER (default), BATTLE (two same-class cars within 0.8 s for >= 5 s, Peter's first), CHASE (car behind Peter within 1.5 s), TRACK (wide shot, every 60 s for 10 s). The label text is one word, top-left of the panel, small caps, gold when it involves Peter.
3. Lower-third, bottom of the panel: `PETER  gear 4  212 km/h  throttle [bar]  brake [bar]  last 1:19.9  REC`. Bars are thin, gold for throttle, muted for brake. Data from the live stream, updated at the stream rate, drawn at most 30 fps.
4. Panel swap: the TV panel replaces exactly the map and pace/split panels; every other panel stays where it is. Take before/after pictures.
5. Cost: measure the dashboard Chrome's CPU with the TV panel on vs off using the Performance page's own sampler (or `/perf/status`). The TV panel's added cost must be <= 5 % of one core. If it is higher, reduce redraws (the 30 fps cap is the first lever) and re-measure.
6. Copy-audit: the only words are the label, PETER, gear, km/h, throttle, brake, last, REC. No filler.
## Files
- `dash\src\tv.cs` (only if the label state must be added)
- `dash\www\v2\tvview.js` (extend)
- `dash\www\v2\tvview.css` (extend)
- `dash\www\v2\index.html` (only the panel swap hook, if not already correct)
- `tests\tv-test.ps1` (extend)
- `docs\tasks\log\T-04.md` (report)
## Gate
`tests\tv-test.ps1` new sections, all with numbers:
- Label rules: a pretend race where two same-class cars sit within 0.8 s for 5 s -> BATTLE appears and holds at least 8 s; a car behind Peter within 1.5 s -> CHASE; otherwise LEADER; TRACK appears once per 60 s for 10 s.
- Lower-third shows Peter's gear, speed, throttle, brake, last lap and REC from the pretend stream; numbers match the stream values.
- Panel swap: before/after pictures show only the map and pace/split panels replaced; the other panels' bounding boxes are unchanged.
- Cost: the measured added CPU of the TV panel is <= 5 % of one core (number in the test output).
- Copy-audit-test passes for the panel's visible text.
- Compile: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0. Deploy only when `irdeck-cli.exe state` shows sim=False; exit 2 = stop.
- Pictures: `tests\shots\tv-label-battle.png`, `tv-label-chase.png`, `tv-lowerthird.png`, `tv-panel-swap-before.png`, `tv-panel-swap-after.png`.
## User journey
Peter presses TV. The label says BATTLE when two cars are close, and the lower-third shows his inputs like a broadcast. Peter fails it if the label flickers, if BATTLE does not appear when two cars are within 0.8 s for 5 s, or if the Performance page shows the TV panel costing more than 5 % of one core.
## Not in this card
Replay TV between stints (T-05), the deck TV key (K-02), design-token sweep (DS-03), the live race check (T-07).
## Report
AGENTS.md format to `docs\tasks\log\T-04.md`.

=== FILE: docs\cards\v4\T-05.md ===
# T-05 Replay TV between stints
**Phase / depends on / size / needs Peter:** Phase 4 / T-06 / M away / away window
## Why
Between stints, while Peter is out of the car, the sim screens show real replay pictures of his last two laps - the only real camera pictures the room gets without a second account. The panel reads REPLAY and stops the instant he is back on track.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\SPEC-v4.md` section 3d (between-stints rule: out of the car, tape present, AUTO TV on, UI hidden, last 2 laps, panel reads REPLAY, stops within 1 s of IsOnTrack) and section J.
- `dash\src\replay.cs` (the SDK messages: ReplaySearchSessionTime, CamSetState bits 0x10 AUTO TV and 0x08 HIDE UI, ReplaySetPlaySpeed; the existing replay command patterns).
- `dash\src\tv.cs` (where the between-stints state should live; the `/tv` JSON).
- `dash\www\v2\tvview.js` (the panel's REPLAY state).
- `tests\tv-test.ps1` and `tests\replay-test.ps1` (the mock patterns; extend tv-test).
- `docs\replay.md` (the exact message packing and the live-test facts).
## Build
1. Find out in `dash\src\tv.cs` how the current out-of-car/tape-present/IsOnTrack state is exposed; write the field names in the report.
2. In `dash\src\tv.cs`, add the between-stints logic: when Peter is out of the car, the replay tape is present, and the sim is not on track, send the SDK messages to start replay TV: AUTO TV on (CamSetState bit 0x10), HIDE UI on (bit 0x08), ReplaySearchSessionTime to the start of his last two laps, ReplaySetPlaySpeed 1. The panel's `/tv` JSON gains a `replayTv` state: `off`, `starting`, `playing`, `stopping`.
3. Stop condition: the instant `IsOnTrack` becomes true, send the messages to stop (AUTO TV off, HIDE UI off, back to live) and set `replayTv` to `off`. The stop must land within 1 s of IsOnTrack (the test measures with the pretend session).
4. In `tvview.js`, when `replayTv` is `playing`, the panel shows the word REPLAY in place of the director label; the tower and map keep updating from the live data.
5. Never send any camera or replay message while Peter is on track. The code refuses the same way `replay.cs` does.
6. Copy-audit: the only new word is REPLAY.
## Files
- `dash\src\tv.cs` (extend)
- `dash\www\v2\tvview.js` (extend)
- `tests\tv-test.ps1` (extend)
- `docs\tasks\log\T-05.md` (report)
## Gate
`tests\tv-test.ps1` new sections, all with numbers:
- Pretend session: out of the car with a tape -> the exact SDK messages for AUTO TV on, HIDE UI on, search to the last-two-laps start, play speed 1 are recorded (never broadcast under the test hook).
- IsOnTrack flips true -> the stop messages are recorded and `replayTv` is `off` within 1 s of the flip.
- While on track, no replay/camera message is ever recorded.
- The panel shows REPLAY when `replayTv` is `playing`.
- Copy-audit-test passes.
- Compile: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0. Deploy only when `irdeck-cli.exe state` shows sim=False; exit 2 = stop.
- The live part (real replay pictures, real stop timing) is run by the lead in an away window with `tests\tv-test.ps1 -Live`; if Peter is not away, leave it PENDING with the exact command in the report.
## User journey
Peter finishes a stint and gets out. The sim screens show his last two laps as a TV replay; the top panel says REPLAY. The moment he is back on track, the replay stops and his driving view is untouched. Peter fails it if the replay keeps playing after he is on track, or if any camera message fires while he is driving.
## Not in this card
The REPLAY live fixes themselves (T-06), the live race check (T-07), the deck TV key (K-02).
## Report
AGENTS.md format to `docs\tasks\log\T-05.md`.

=== FILE: docs\cards\v4\T-06.md ===
# T-06 REPLAY live fixes (C-03)
**Phase / depends on / size / needs Peter:** Phase 4 / none / M away / away window
## Why
The REPLAY screen's five live failures - COCKPIT, CHASE, CAMERA >, AUTO TV, HIDE UI, MY LAST INCIDENT - all share one cause class: camera/UI-state messages that transport but do not take. Fix them so Studio, replay TV and event jumps can trust the replay.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\replay.md` (the exact messages, the packing, the live-run facts, the "not confirmed in the sim yet" list).
- `dash\src\replay.cs` (the message packing: CamSetState msg 2 / var1, CamSwitchPos vs CamSwitchNum with group+camera, the optimistic holds, the timing after ReplaySearch).
- `tests\replay-test.ps1` (the mock sections and the `-Live` sections; the six FAIL checks).
- `tests\last\replay-live.txt` (the exact failures from the last live run).
- `docs\OPERATIONS.md` section 6 (how to run the live replay test safely).
## Build
1. Read `tests\last\replay-live.txt` and list the six FAIL lines and their observed values in the report.
2. In `dash\src\replay.cs`, find the shared cause. Check, in order: (a) CamSetState packing - msg 2, var1 = the full state word with bit 0x10/0x08 flipped, var2 = 0; (b) CamSwitchPos vs CamSwitchNum - the code uses CamSwitchNum with the raw car number for named cars; verify the group+camera packing into the high word; (c) the optimistic hold hiding the real value - the code answers with what was asked for 1.5 s; verify it re-reads `CamGroupNumber`/`CamCameraNumber`/`CamCameraState` after the hold; (d) timing after ReplaySearchSessionTime - the camera message may need to land after the search completes.
3. Fix the cause. Do not change the message numbers or the packing scheme documented in `docs\replay.md` unless the live test proves them wrong; if it does, update the doc with the measured facts.
4. Update `docs\replay.md` "Live run" with the measured facts after the fix.
5. The mock test must still pass unchanged (the recorded messages are the contract).
## Files
- `dash\src\replay.cs`
- `tests\replay-test.ps1` (only if a check was wrong; do not weaken it)
- `docs\replay.md` (live-run facts)
- `docs\tasks\log\T-06.md` (report)
## Gate
`tests\replay-test.ps1` (mock) 0 FAIL. Then the live gate, run by the lead in an away window:
`powershell -ExecutionPolicy Bypass -File tests\run-replay-live.ps1` -> `replay-test -Live` 0 FAIL: COCKPIT and CHASE change `CamGroupNumber`; CAMERA > changes the camera; AUTO TV (CamCameraState 0x10) and HIDE UI (0x08) take; MY LAST INCIDENT lands on the right moment. If Peter is not away, leave the live part PENDING with the exact command in the report.
Compile: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0. Deploy only when `irdeck-cli.exe state` shows sim=False; exit 2 = stop.
## User journey
Peter opens REPLAY, presses COCKPIT, and the picture is the cockpit with the key gold. He presses AUTO TV and the TV director takes over. Peter fails it if any of the six keys does not change what the sim shows.
## Not in this card
Studio (ST-01+), replay TV between stints (T-05), the hero shot (T-08), the deck batch (K-02).
## Report
AGENTS.md format to `docs\tasks\log\T-06.md`.

=== FILE: docs\cards\v4\T-07.md ===
# T-07 TV live check in a real race
**Phase / depends on / size / needs Peter:** Phase 4 / T-04 / S live / one real race
## Why
The TV view is only done when it matches iRacing's own standings in a real race and costs no frames. This card is the live gate: three moments checked against iRacing's tower, dots against the relative, fps unchanged.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\SPEC-v4.md` section 3d and the Phase 4 gate line.
- `docs\tasks\log\T-01.md` through `T-04.md` (what was built and the test numbers).
- `tests\tv-test.ps1` (the offline sections; the live section to add).
- `docs\performance.md` (how to read the Performance page's fps comparison).
- `docs\OPERATIONS.md` (guard rules for a live check).
## Build
1. Add a `-Live` section to `tests\tv-test.ps1` that runs only with `Assert-RigFree -NeedAway` and a real session: it waits for a race session with 2+ cars, then at three moments (spread over at least 2 laps) captures the TV panel's tower and map, and compares them with the sim's own `CarIdxPosition`, `CarIdxClassPosition`, `CarIdxLapDistPct`, `CarIdxF2Time`/`CarIdxEstTime` read from the same frozen frame. Each check prints the numbers.
2. The fps check: read the Performance page's last-session average with the TV panel on and compare with the same track/car/field baseline; the difference must be within the normal run-to-run wobble (the test prints both numbers and the verdict).
3. Write the live-run notes to `docs\tasks\log\T-07.md` with the three moments' numbers and the fps comparison.
4. No code changes to the TV engine unless the live check finds a real mismatch; if it does, fix the smallest thing and re-run the offline test first.
## Files
- `tests\tv-test.ps1` (extend with `-Live`)
- `docs\tasks\log\T-07.md` (report)
- (only if a mismatch is found) the smallest fix in `dash\src\tv.cs` or `dash\www\v2\tvview.js`, reported
## Gate
The live check, run by the lead during Peter's next real race (or a spectated AI race if Peter agrees): at three moments the tower equals iRacing's standings (position, gap, interval within 0.1 s) and the dots match the relative; the Performance page shows no fps change beyond normal wobble. Offline: `tests\tv-test.ps1` (without `-Live`) still 0 FAIL. Compile: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0.
## User journey
Peter races. At three moments the lead checks the TV tower against iRacing's own standings and the dots against the relative. Peter fails it if his position or gap is wrong at any check, or if the fps drops.
## Not in this card
The hero shot (T-08), the deck TV key (K-02), Studio (ST-01+), design-token sweep (DS-03).
## Report
AGENTS.md format to `docs\tasks\log\T-07.md`.

=== FILE: docs\cards\v4\T-08.md ===
# T-08 Hero shot capture (away)
**Phase / depends on / size / needs Peter:** Phase 4 / T-06 / M away / away window; iRacing screenshot setting must be on (ask if not)
## Why
HOME shows Peter's own car, captured from his replay with the UI hidden - the real asset the premium-visuals rule demands. The credited stand-in stays until this capture exists.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\SPEC-v4.md` section 3b (the hero slot: `paddock\home\hero.jpg`, 2560 wide, cropped 1060x480, no text over the car, credited stand-in until T-08) and section L.
- `dash\src\home.cs` (how HOME picks the hero: `hero.jpg` wins, stand-in with credit otherwise; the exact path and credit file).
- `dash\src\replay.cs` (the PHOTO path: HIDE UI, VideoCapture screenshot, wait for the new file, copy to a folder; reuse this logic).
- `docs\replay.md` (the PHOTO section: the exact messages, the wait, the size check).
- `paddock\home\credits.json` (the current stand-in credit entry; the shape to add).
- `tests\replay-test.ps1` (the PHOTO mock sections to copy).
## Build
1. Find out in `dash\src\home.cs` the exact hero selection order and the credit file shape; write them in the report.
2. In `dash\src\home.cs` (or a small new helper if cleaner), add the hero capture: when triggered (a test-only route or a lead command, never automatic while Peter is at the PC), open the replay of his last session, HIDE UI on, switch to a chase/TV camera on his car, send the VideoCapture screenshot message, wait up to 12 s for a new picture in `Documents\iRacing\screenshots` (size stops changing), HIDE UI back, and copy the picture to `paddock\home\hero.jpg` only when it is >= 2560 px wide and upright. Add a credit entry to `paddock\home\credits.json` (date, source "iRacing replay capture", car/track from the session).
3. The capture runs only out of the car, with the sim on the session, and only when Peter is away (`Assert-RigFree -NeedAway` in the test; the route refuses otherwise).
4. HOME's existing logic then picks `hero.jpg` automatically; no HOME layout change.
5. Copy-audit: the credit line is the only new visible text, and it is factual.
## Files
- `dash\src\home.cs` (extend; or new `dash\src\herocapture.cs` + `$src` in `dash\build.ps1`, reported)
- `paddock\home\credits.json` (add the entry)
- `tests\home-test.ps1` (extend with the capture mock)
- `docs\tasks\log\T-08.md` (report)
## Gate
`tests\home-test.ps1` new sections, all with numbers:
- Mock capture: the exact SDK messages (HIDE UI on, camera switch, screenshot, HIDE UI back) are recorded; a pretend screenshot >= 2560 px wide is copied to `paddock\home\hero.jpg`; a smaller one is not; the credit entry is written.
- HOME serves `hero.jpg` when it exists and the stand-in when it does not.
- The capture route refuses while the sim is on track or Peter is not away.
- Copy-audit-test passes.
- Compile: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0. Deploy only when `irdeck-cli.exe state` shows sim=False; exit 2 = stop.
- The real capture is run by the lead in an away window; if Peter is not away, leave it PENDING with the exact command in the report. If iRacing's screenshot setting is off, ask Peter once (never change it ourselves).
## User journey
Peter comes back to HOME and sees his own Corvette from the replay, no UI, upright, with a one-line credit. Peter fails it if the picture is a stand-in, upside down, or has iRacing menus over it.
## Not in this card
Studio films (ST-01+), the deck batch (K-02), design-token sweep (DS-03).
## Report
AGENTS.md format to `docs\tasks\log\T-08.md`.