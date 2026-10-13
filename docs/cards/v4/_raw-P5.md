=== FILE: docs\cards\v4\ST-01.md ===
# ST-01 Studio S0a: replay survival + one fixed-camera lap
**Phase / depends on / size / needs Peter:** Phase 5 / T-06, P0-01 / M away / Away window
## Why
Peter gets the first automatic film of his best lap with no press. It proves the replay tape survives after the flag and that Paddock can film one lap from TV1, upright, UI hidden. This is the foundation for Studio.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Read `docs\replay.md` (SDK messages, ReplaySearchSessionTime, CamSwitchNum, CamSetState bits), `docs\vault.md` (recorder, sidecar, upright rotation), `dash\src\replay.cs` (Replay.Do, Replay.Json), `dash\src\recorder.cs` (Recorder.Loop, Recorder.RunCut, Recorder.StatusJson), `dash\src\analysis.cs` (Analysis.Load for lap start/end times), `dash\build.ps1` ($src list). Look for exact method names and how a take is started/stopped.
## Build
1. Find out in `dash\src\recorder.cs` the exact API to start/stop a named take and in `dash\src\replay.cs` the exact packing for ReplaySearchSessionTime, CamSwitchNum, CamSetState; write findings in the report.
2. New `dash\src\studio.cs` (C# 5, no frameworks). Add `studio.cs` to `$src` in `dash\build.ps1`.
3. Implement `Studio.S0a(string ibtFile, int lap)`:
   - Read lap start/end session times from `Analysis.Load` (or `IbtLaps`) for the best clean lap.
   - Send `ReplaySearchSessionTime(session, lapStartMs)`, then `CamSwitchNum` to TV1 (group 11, camera 1 from YAML), then `CamSetState` with UI hidden bit 0x08.
   - Start a recorder take named `studio-s0a-<session>-<lap>` for lap duration + 1 s pre/post; stop it.
   - Log `studio: S0a filmed lap <n> <duration>s`.
4. Add `Studio.ProbeReplay()` that reads `IsReplayPlaying`, `ReplaySessionNum`, `ReplaySessionTime`, `CamGroupNumber`, `CamCameraNumber`, `CamCameraState` and logs them; used by the live test.
5. New `docs\studio.md`: record the replay-survival fact (tape still loaded 10 min after the flag) and the S0a flow.
6. New `tests\studio-test.ps1` (guard, `Assert-RigFree`; live section `Assert-RigFree -NeedAway`).
7. All work: C# 5 only, no frameworks, real assets only, never write iRacing files, never act while he drives.
## Files
- new `dash\src\studio.cs`
- `dash\build.ps1` ($src line only)
- `dash\src\recorder.cs` (smallest edit: named take if missing)
- `dash\src\replay.cs` (read only)
- new `tests\studio-test.ps1`
- new `docs\studio.md`
- `docs\tasks\log\ST-01.md` (report)
## Gate
`tests\studio-test.ps1` new sections: 1 offline mock (10 ok, 0 FAIL): S0a sends the three messages in order, take duration = lap Â± 1 s, UI hidden bit set; 2 live away (6 ok, 0 FAIL): after a real AI race, tape still loaded 10 min after flag, one lap filmed, ffprobe duration = lap Â± 1 s, upright, UI hidden. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop. copy-audit-test passes for any visible text (none).
## User journey
Peter leaves the sim open after a race and walks away. 10 minutes later a film of his best lap is in the Vault with no press. He fails it if the film is missing, shows the wrong corner, is upside down, has UI visible, or its duration is off by more than 1 s.
## Not in this card
Shot-list engine, presets, editor page, combine, race highlights, pro comparison, sharing.
## Report
Write `docs\tasks\log\ST-01.md` in AGENTS.md format (CARD/RESULT/GATE/FILES/NEEDS PETER/NEEDS LEAD/NOTES). If Peter is not away, leave the live section PENDING with the exact command.

=== FILE: docs\cards\v4\ST-02.md ===
# ST-02 Shot-list engine + presets
**Phase / depends on / size / needs Peter:** Phase 5 / ST-01 / M / none
## Why
Peter gets three one-press film styles (CINEMATIC, ONBOARD, BROADCAST) built from the corner model, with slow motion at the corner that cost the most. This turns a lap into a plan before any filming.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Read `docs\corners.md` (corner model, pct0/pctApex/pct1), `docs\vault.md` (analysis lap times), `dash\src\corners.cs` (Corners), `dash\src\analysis.cs` (Analysis.Measure, corner metrics, worst corner), `dash\src\studio.cs` (from ST-01), `dash\build.ps1`. Look for how corner pct maps to lap time and how the worst corner is identified.
## Build
1. In `dash\src\studio.cs`, add `Studio.ShotList BuildShotList(string ibtFile, int lap, string preset)` returning a list of shots: `{cameraGroup, camera, startPct, endPct, slowMo}`.
2. Use `Corners` for corner segments; map each corner's `pct0`/`pctApex`/`pct1` to lap time via the lap's own time-at-pct from `Analysis.Load`.
3. Presets:
   - CINEMATIC: wide/TV on straights, chase or cockpit in technical sections, slow motion at the worst corner (from `Analysis.Measure`), opening on grid/pit, final hold on finish.
   - ONBOARD: cockpit + chase only.
   - BROADCAST: TV style, no slow motion.
4. Cue times are the lap's own time at pct, never guessed. Slow-mo only at the worst corner.
5. Add `Studio.ShotListJson` for later use by ST-03/ST-04.
6. Extend `tests\studio-test.ps1` with offline sections.
7. All work: C# 5 only, no frameworks, real assets only, never write iRacing files, never act while he drives.
## Files
- `dash\src\studio.cs`
- `tests\studio-test.ps1`
- `docs\tasks\log\ST-02.md` (report)
## Gate
`tests\studio-test.ps1` new sections: 3 shot-list checks (12 ok, 0 FAIL): CINEMATIC/ONBOARD/BROADCAST each produce a list for Road Atlanta, Sebring, Lime Rock; cue times equal the lap's own time at pct within 0.05 s; slow-mo appears only at the worst corner. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop. copy-audit-test passes for any visible text (none).
## User journey
None yet. Peter will later press MAKE A REPLAY and the plan is built; he fails if a cue is at the wrong corner or slow motion is on the wrong corner.
## Not in this card
Live filming, editor page, combine, race highlights, pro comparison, sharing.
## Report
Write `docs\tasks\log\ST-02.md` in AGENTS.md format.

=== FILE: docs\cards\v4\ST-03.md ===
# ST-03 S1 live film
**Phase / depends on / size / needs Peter:** Phase 5 / ST-02 / S away / Away window
## Why
Peter gets a real CINEMATIC film of his best lap, filmed in one real-time pass through iRacing's replay, with camera changes landing on the plan. This is the Studio signature moment.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Read `docs\replay.md` (SDK messages, ReplaySearchSessionTime, CamSwitchNum, CamSetState), `docs\vault.md` (recorder, upright), `dash\src\studio.cs` (ST-02 shot list), `dash\src\replay.cs`, `dash\src\recorder.cs`, `tests\studio-test.ps1`. Look for how to send camera changes and read back CamGroupNumber/ReplaySessionTime.
## Build
1. In `dash\src\studio.cs`, add `Studio.FilmShotList(string ibtFile, int lap, string preset)`:
   - Build the shot list with `BuildShotList`.
   - For each shot: send `ReplaySearchSessionTime(session, startMs)`, `CamSwitchNum` to the shot's camera group/camera, `CamSetState` UI hidden, set slow-mo via `ReplaySetPlaySpeed` when the shot has slowMo.
   - Start one recorder take for the whole lap; stop at the end.
   - Log each cue: `studio: cue <i> <camera> at <sessionTime>ms`.
2. Keep the take under 150 MB; use the recorder's existing encoder settings.
3. Extend `tests\studio-test.ps1` with a live section.
4. All work: C# 5 only, no frameworks, real assets only, never write iRacing files, never act while he drives.
## Files
- `dash\src\studio.cs`
- `tests\studio-test.ps1`
- `docs\tasks\log\ST-03.md` (report)
## Gate
`tests\studio-test.ps1` new live section (8 ok, 0 FAIL): in a real AI race replay with Peter away, film a CINEMATIC lap; â¥4 camera changes land within 0.5 s of cues (read CamGroupNumber vs ReplaySessionTime); file < 150 MB; upright; UI hidden. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop. copy-audit-test passes for any visible text (none).
## User journey
Peter leaves the sim open after a race and walks away. Later the Vault has a CINEMATIC film of his best lap; the film cuts where the plan says. He fails if a cut is off by more than 0.5 s, the file is over 150 MB, upside down, or UI is visible.
## Not in this card
Editor page, combine, race highlights, pro comparison, sharing.
## Report
Write `docs\tasks\log\ST-03.md` in AGENTS.md format. If Peter is not away, leave the live section PENDING with the exact command.

=== FILE: docs\cards\v4\ST-04.md ===
# ST-04 S2 editor page
**Phase / depends on / size / needs Peter:** Phase 5 / ST-02 / M / none
## Why
Peter can change one camera chip and film it, without a mouse. The editor page shows the lap timeline with corner names and camera chips, so he can adjust the plan before filming.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Read `docs\DESIGN-workbench.md` (interaction model, deck control), `docs\corners.md` (corner names), `dash\www\v2\workbench.js` (page framework, canvas, deck commands), `dash\www\v2\map.js` and `corners.js` (map drawing), `dash\src\studio.cs` (ST-02 shot list), `dash\src\deckfeed.cs` (deck relay pattern), `dash\build.ps1`. Look for how pages open over the dashboard and how deck keys send commands.
## Build
1. New `dash\www\v2\studio.html`, `studio.js`, `studio.css` (plain HTML/CSS/JS, no frameworks, real assets only: the track map from `map.js`, corner names from `corners.js`).
2. Add routes in `dash\src\studio.cs`: `GET /studio/state?id=<ibt>&lap=<n>` returns the shot list; `POST /studio/plan` saves an edited plan; `POST /studio/film` queues `Studio.FilmShotList`.
3. Editor page: timeline with corner names, camera chips per segment, drag cut points, slow-mo/freeze toggles, PREVIEW draws the plan on the map, FILM IT queues filming.
4. Deck next/prev: reuse `deckfeed.cs` pattern; add `wb-` style commands `studio-next`, `studio-prev`, `studio-film` to the whitelist in `dash\src\irdash.cs` (smallest edit).
5. Extend `tests\studio-test.ps1` with headless Chrome sections and pictures `tests\shots\st-*.png`.
6. All work: C# 5 only, no frameworks, real assets only, never write iRacing files, never act while he drives.
## Files
- new `dash\www\v2\studio.html`
- new `dash\www\v2\studio.js`
- new `dash\www\v2\studio.css`
- `dash\src\studio.cs`
- `dash\src\irdash.cs` (smallest edit: route/whitelist)
- `tests\studio-test.ps1`
- `docs\tasks\log\ST-04.md` (report)
## Gate
`tests\studio-test.ps1` new sections: 4 editor page (10 ok, 0 FAIL): timeline shows corner names; camera chips render; drag cuts update the plan; PREVIEW draws on the map; FILM IT queues; deck next/prev commands answered; pictures `tests\shots\st-editor.png`, `st-preview.png`. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop. copy-audit-test passes for any visible text.
## User journey
Peter opens the editor from a Vault moment, changes T10a to cockpit, presses FILM IT. He fails if the timeline has no corner names, a chip cannot be changed, PREVIEW is blank, or FILM IT does nothing.
## Not in this card
Combine, race highlights, pro comparison, sharing.
## Report
Write `docs\tasks\log\ST-04.md` in AGENTS.md format.

=== FILE: docs\cards\v4\ST-05.md ===
# ST-05 S4 combine + optional overlays
**Phase / depends on / size / needs Peter:** Phase 5 / ST-03 / M / none
## Why
Peter can combine two takes (cockpit + chase, or his lap vs PB) into one file with title and end cards, crossfades, and optional data overlays. This is the Studio editor's output step.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Read `docs\vault.md` (share overlay, ffmpeg, upright), `dash\src\share.cs` (Share.Render, ShareDraw, overlay drawing), `dash\src\studio.cs` (ST-03 film), `dash\src\analysis.cs` (lap time at pct), `vault\bin\ffmpeg.exe` and `ffprobe.exe` (available). Look for how share.cs draws overlays and how ffmpeg filters are invoked.
## Build
1. In `dash\src\studio.cs`, add `Studio.Combine(string takeA, string takeB, string mode, string title, string end)`:
   - Modes: side-by-side, picture-in-picture, vs PB locked by pct (use lap time at pct from `Analysis.Load`).
   - Use `vault\bin\ffmpeg.exe` with xstack/xfade filters; title and end cards as generated PNGs or drawtext (text follows COPY-RULES).
   - Keep a clean copy without overlays; optional overlays reuse `share.cs` overlay drawing.
   - Run ffprobe checks: duration, resolution, no rotation side data.
2. Add `Studio.CombineJson` for status.
3. Extend `tests\studio-test.ps1` with offline sections using generated test clips.
4. All work: C# 5 only, no frameworks, real assets only, never write iRacing files, never act while he drives.
## Files
- `dash\src\studio.cs`
- `dash\src\share.cs` (read only, reuse)
- `tests\studio-test.ps1`
- `docs\tasks\log\ST-05.md` (report)
## Gate
`tests\studio-test.ps1` new sections: 5 combine (8 ok, 0 FAIL): side-by-side and PiP outputs play; vs PB locked by pct within 0.1 s at 3 corners; title/end cards present; xfade applied; clean copy kept; ffprobe shows no rotation side data. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop. copy-audit-test passes for any visible text in cards.
## User journey
Peter selects cockpit + chase and gets one file with both, title and end cards. He fails if the two pictures are not locked by track position, a card text is filler, or the clean copy is missing.
## Not in this card
Race highlights, pro comparison, sharing.
## Report
Write `docs\tasks\log\ST-05.md` in AGENTS.md format.

=== FILE: docs\cards\v4\ST-06.md ===
# ST-06 S5 race highlights
**Phase / depends on / size / needs Peter:** Phase 5 / ST-05 / M / none
## Why
Peter gets a short race reel of the start, every pass and incident, the last lap and the finish, cut automatically from the race log. This is the Studio race story.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Read `docs\vault.md` (race log, field.cs passes/incidents), `dash\src\field.cs` (RaceField.Route, RfSummary.Build, passes, incidents), `dash\src\studio.cs` (ST-05 combine), `dash\src\analysis.cs` (lap times), `tests\studio-test.ps1`. Look for how passes and incidents are stored with session times.
## Build
1. In `dash\src\studio.cs`, add `Studio.RaceHighlights(string fieldId)`:
   - Read the race log via `RaceField.Route` or `RfSummary.Build`.
   - Build a shot list: start, each pass/incident (3 s before to 2 s after), last lap, finish.
   - Film or cut from the session replay/recorder using the ST-03 film path; combine with ST-05.
   - Keep total â¤ 3 min.
2. Add `Studio.RaceHighlightsJson` for status.
3. Extend `tests\studio-test.ps1` with a real race log fixture.
4. All work: C# 5 only, no frameworks, real assets only, never write iRacing files, never act while he drives.
## Files
- `dash\src\studio.cs`
- `dash\src\field.cs` (read only)
- `tests\studio-test.ps1`
- `docs\tasks\log\ST-06.md` (report)
## Gate
`tests\studio-test.ps1` new sections: 6 race highlights (6 ok, 0 FAIL): with a real race log fixture, the reel includes start, each pass/incident, last lap, finish; total â¤ 3 min; no segment missing. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop. copy-audit-test passes for any visible text (none).
## User journey
Peter opens a race in the Vault and gets a 2-minute reel of his race. He fails if a pass or incident is missing, the reel is over 3 minutes, or the finish is cut.
## Not in this card
Pro comparison, sharing.
## Report
Write `docs\tasks\log\ST-06.md` in AGENTS.md format.

=== FILE: docs\cards\v4\PR-01.md ===
# PR-01 Pro find + fetch
**Phase / depends on / size / needs Peter:** Phase 5 / none / M / none (approved)
## Why
Peter gets a real onboard of the same car/class at the same track, found and downloaded automatically, for the pro comparison. This is the first step of the pro comparison signature moment.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Read `docs\research\competitors-pro-engineering.md` (pro comparison), `docs\vault.md` (vault\pro, throttling), `dash\src\perf.cs` (network throttling pattern), `dash\src\irdash.cs` (Sdk.RealBusy), `data\pro-refs.json` (official lap times), `vault\bin\` (ffmpeg present). Look for how background work is throttled and how online sessions are detected.
## Build
1. Find out the exact yt-dlp release URL and checksum for the approved version; write it in the report. Download `vault\bin\yt-dlp.exe` only from the official GitHub release, verify the checksum, no other downloads.
2. New `dash\src\pro.cs` (C# 5, no frameworks). Add `pro.cs` to `$src` in `dash\build.ps1`.
3. Implement `Pro.FindAndFetch(string car, string track)`:
   - Run `vault\bin\yt-dlp.exe` search for "<track> onboard <car/class> IMSA <year>".
   - Score candidates: official channels first, pole/qualifying, newest year; cache in `data\pro-videos.json`.
   - Download 720p video-only to `vault\pro\`, throttled to ~500 KB/s, BelowNormal, never while `Sdk.RealBusy()` or an online session is active.
4. Add `Pro.StatusJson` and route `GET /pro/status`.
5. New `tests\pro-test.ps1` (guard, `Assert-RigFree`).
6. All work: C# 5 only, no frameworks, real assets only, never write iRacing files, never act while he drives.
## Files
- new `dash\src\pro.cs`
- `dash\build.ps1` ($src line only)
- `vault\bin\yt-dlp.exe` (downloaded, checksum verified)
- `data\pro-videos.json` (new cache)
- new `tests\pro-test.ps1`
- `docs\tasks\log\PR-01.md` (report)
## Gate
`tests\pro-test.ps1` new sections: 1 scoring (8 ok, 0 FAIL): fixture candidates scored correctly (official, pole/quali, newest); 2 fetch (4 ok, 0 FAIL): one real fetch to `vault\pro\`, 720p video-only, throttled, refused while online session. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop. copy-audit-test passes for any visible text (none).
## User journey
Peter opens Road Atlanta Corvette and later finds one onboard in `vault\pro`. He fails if the video is the wrong car/track, downloaded during an online session, or not throttled.
## Not in this card
Align, render, sharing.
## Report
Write `docs\tasks\log\PR-01.md` in AGENTS.md format.

=== FILE: docs\cards\v4\PR-02.md ===
# PR-02 Pro align
**Phase / depends on / size / needs Peter:** Phase 5 / PR-01 / M / none
## Why
Peter's lap and the pro onboard are aligned by track position, so the comparison is honest. This is the alignment engine behind the pro comparison.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Read `docs\vault.md` (share sync, lap time at pct), `dash\src\analysis.cs` (speed/brake traces, TAt), `dash\src\pro.cs` (PR-01), `data\pro-refs.json` (official lap time), `vault\bin\ffmpeg.exe` (filters). Look for how lap time maps to pct and how cross-correlation can be computed.
## Build
1. Find out in `vault\bin\ffmpeg.exe -filters` the exact filter for motion energy (e.g. signalstats or frame difference) and write it in the report.
2. In `dash\src\pro.cs`, add `Pro.Align(string proVideo, string ibtFile, int lap)`:
   - Compute a motion-energy curve of the pro video with ffmpeg at low resolution.
   - Cross-correlate with Peter's speed/brake trace from `Analysis.Load`, time-warped by track position.
   - Confidence check against `data\pro-refs.json` official lap time; output `{offsetMs, confidence, corners}`.
3. Add `Pro.AlignJson` and route `GET /pro/align`.
4. Extend `tests\pro-test.ps1` with a time-warped copy of his own clip.
5. All work: C# 5 only, no frameworks, real assets only, never write iRacing files, never act while he drives.
## Files
- `dash\src\pro.cs`
- `tests\pro-test.ps1`
- `docs\tasks\log\PR-02.md` (report)
## Gate
`tests\pro-test.ps1` new sections: 3 align (6 ok, 0 FAIL): a time-warped copy of his own clip aligns within 0.3 s at 3 corners; confidence is high for the known warp and low for a mismatched clip. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop. copy-audit-test passes for any visible text (none).
## User journey
None yet. Peter will later see the two laps locked by track position; he fails if a corner is off by more than 0.3 s.
## Not in this card
Render, sharing.
## Report
Write `docs\tasks\log\PR-02.md` in AGENTS.md format.

=== FILE: docs\cards\v4\PR-03.md ===
# PR-03 Pro render
**Phase / depends on / size / needs Peter:** Phase 5 / PR-02 / M / none
## Why
Peter sees his lap beside a real driver's onboard, locked by track position, with honest labels and per-corner gaps. This is the pro comparison signature moment.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Read `docs\vault.md` (share overlay, ffmpeg, labels), `dash\src\share.cs` (Share.Render, overlay drawing), `dash\src\pro.cs` (PR-02 align), `dash\src\analysis.cs` (corner times), `data\pro-refs.json`. Look for how share.cs draws text and how ffmpeg xstack is used.
## Build
1. In `dash\src\pro.cs`, add `Pro.Render(string proVideo, string ibtFile, int lap, string alignJson)`:
   - Side-by-side locked by pct using the PR-02 offset.
   - Labels: "PETER Â· 1:19.549 sim" and "<driver> Â· <time> real car Â· guide only"; gap per corner from `Analysis.Measure`.
   - When confidence is low, add "approximate".
   - Use `vault\bin\ffmpeg.exe` with xstack; reuse `share.cs` overlay drawing for text.
2. Add `Pro.RenderJson` and route `GET /pro/render`.
3. Extend `tests\pro-test.ps1` with a rendered output check.
4. All work: C# 5 only, no frameworks, real assets only, never write iRacing files, never act while he drives.
## Files
- `dash\src\pro.cs`
- `dash\src\share.cs` (read only, reuse)
- `tests\pro-test.ps1`
- `docs\tasks\log\PR-03.md` (report)
## Gate
`tests\pro-test.ps1` new sections: 4 render (6 ok, 0 FAIL): side-by-side output plays; labels correct; gap per corner shown; "approximate" appears when confidence low; no guessed time. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop. copy-audit-test passes for any visible text in labels.
## User journey
Peter opens the pro comparison and sees each corner together, him beside a real driver. He fails if the two pictures drift apart, a label is wrong, or a guessed time appears without "approximate".
## Not in this card
Sharing.
## Report
Write `docs\tasks\log\PR-03.md` in AGENTS.md format.

=== FILE: docs\cards\v4\SH-01.md ===
# SH-01 Share: Windows share sheet + YouTube upload page
**Phase / depends on / size / needs Peter:** Phase 5 / P0-01 / M live / none (rig free)
## Why
Peter can send a finished share video to the Windows share sheet or the YouTube upload page in two presses, without Paddock ever posting or storing credentials. This finishes the PC sharing journey.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Read `docs\vault.md` (share video, `/share/open`), `dash\src\share.cs` (Share.Handle, Share.Render, routes), `dash\www\v2\workbench-share.js` (buttons), `docs\OPERATIONS.md` (explorer.exe start rule), `tools\` (one-click .cmd pattern). Look for how `/share/open` opens Explorer and how buttons are wired.
## Build
1. Find out the exact Windows share sheet invocation on this PC (e.g. `explorer.exe /share,<file>` or a shell verb) and write it in the report; do not guess.
2. New `tools\share-sheet.cmd` that takes a file path and opens the Windows share sheet via `explorer.exe` (started through Explorer, never from the packaged app directly).
3. In `dash\src\share.cs`, add routes: `GET /share/sheet?id=<id>` runs `tools\share-sheet.cmd` with the finished file; `GET /share/youtube?id=<id>` opens `https://www.youtube.com/upload` in the default browser and Explorer with the file selected. Both refused with 409 while driving.
4. In `dash\www\v2\workbench-share.js`, add SHARE and YOUTUBE buttons that call the new routes.
5. Extend `tests\share-test.ps1` with new sections.
6. All work: C# 5 only, no frameworks, real assets only, never write iRacing files, never act while he drives.
## Files
- `dash\src\share.cs`
- `dash\www\v2\workbench-share.js`
- new `tools\share-sheet.cmd`
- `tests\share-test.ps1`
- `docs\tasks\log\SH-01.md` (report)
## Gate
`tests\share-test.ps1` new sections: 5 Windows share (6 ok, 0 FAIL): SHARE opens the share sheet for the file; YOUTUBE opens youtube.com/upload and Explorer with the file selected; both refused while driving (409). Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop. copy-audit-test passes for any visible text.
## User journey
Peter presses SHARE on the PC and the Windows share sheet opens; or presses YOUTUBE and the upload page opens with the file selected. He fails if a press does nothing, opens while driving, or Paddock posts by itself.
## Not in this card
Phone share, codec enforcement.
## Report
Write `docs\tasks\log\SH-01.md` in AGENTS.md format.

=== FILE: docs\cards\v4\SH-02.md ===
# SH-02 Share: phone Photos / share sheet / codec
**Phase / depends on / size / needs Peter:** Phase 5 / SH-01, P0-02 / M / none
## Why
Peter can make a share video on the phone and send it to iMessage or save it to Photos, with the video always h264 so it plays everywhere. This finishes the phone sharing journey.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Read `docs\vault.md` (share video, h264, phone CLIPS screen), `dash\www\phone\app.js` (CLIPS screen, share buttons), `dash\src\share.cs` (Share.Handle, job queue), `dash\src\phone.cs` (phone routes), `tests\phone-test.ps1`, `tests\share-test.ps1`. Look for how the phone currently saves/shares and how share jobs report status.
## Build
1. In `dash\src\share.cs`, ensure every share video is h264 (NVENC `p5` or libx264 veryfast); add a check that refuses to keep a non-h264 output.
2. Add route `GET /share/phone?id=<id>` that returns the finished file with the correct MIME and Content-Disposition for the phone.
3. In `dash\www\phone\app.js`, on the CLIPS screen: Make share video â progress â when ready, Share uses the Web Share API share sheet when available; otherwise Save to Files with the message "Saved - share it from Photos". Whole-session SHARE cuts the last lap or chosen clip.
4. Extend `tests\phone-test.ps1` and `tests\share-test.ps1` with new sections.
5. All work: C# 5 only, no frameworks, real assets only, never write iRacing files, never act while he drives.
## Files
- `dash\www\phone\app.js`
- `dash\src\share.cs`
- `tests\phone-test.ps1`
- `tests\share-test.ps1`
- `docs\tasks\log\SH-02.md` (report)
## Gate
`tests\phone-test.ps1` new sections: 6 phone share (5 ok, 0 FAIL): share video is h264; share sheet used when available; Save to Files with message otherwise; whole-session SHARE cuts last lap or chosen clip. `tests\share-test.ps1` new section: 6 codec (3 ok, 0 FAIL): non-h264 output refused. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop. copy-audit-test passes for any visible text.
## User journey
Peter taps Make share video on the phone, then Share, and sends it to iMessage. He fails if the video is black on the iPhone, the share sheet never appears, or a whole-session share cuts the wrong lap.
## Not in this card
None.
## Report
Write `docs\tasks\log\SH-02.md` in AGENTS.md format.