=== FILE: docs\cards\v4\P0-01.md ===
# P0-01 S1 judged live: real session recording + SAVE
**Phase / depends on / size / needs Peter:** Phase 0 / S1 / S / Drive one session, press SAVE once

## Why
Peter gets a whole-session recording that actually survives, and one-press SAVE moves it to `vault\saved` forever. This is the recording-rules promise made real: one mp4, correct length, correct lap sidecar, no frame-rate cost beyond the allowed 3 fps.

## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\vault.md` - whole-session rules, SAVE route, sidecar, retention, encoder.
- `docs\tasks\log\S1.md` and `docs\tasks\log\C-06.md` - what S1 and the recorder already built and what is still unmeasured.
- `dash\src\recorder.cs` - recorder loop, session join, sidecar fields (`lapStartOffset`, `lapEndOffset`, incident entries).
- `dash\src\vault.cs` - `/api/rec/sessions`, `POST /api/rec/save`, saved totals.
- `tests\recorder-test.ps1` - existing unit tests.

## Build
1. Run `powershell -ExecutionPolicy Bypass -File tests\recorder-test.ps1` now. Record its exact ok/FAIL counts in the report.
2. Read S1 report first. Do NOT rewrite S1 or the recorder. This card only adds the missing live proof and the missing SAVE assertion if absent.
3. Add/extend `tests\recorder-test.ps1` with these sections, each printing ok/FAIL:
   - **10. SAVE path:** with a pretend finished session, `POST /api/rec/save?id=<id>` (the existing `recsave` deck command) answers SAVED and the file appears under `vault\saved` when the session ends.
   - **11. duration check:** for one real `vault\sessions\*.mp4`, `ffprobe` duration equals the in-car seconds in its sidecar within Â±2 %.
   - **12. lap and incident count check:** the sidecar's lap list count equals iRacing's own lap count from the session file, and incident entries match the incident count.
   - **13. cost trace:** check `/vault/recorder` and the Performance page's last session report both expose recorder-on fps; the test just proves the numbers exist, the judgement is the live gate below.
4. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy only when `irdeck-cli.exe state` shows `sim=False`; if `dash\build.ps1` exits 2, stop.
5. Update `docs\vault.md` with the measured numbers after Peter's real session (mp4 duration, lap count, recorder cost on the Performance page).

## Files
- `tests\recorder-test.ps1` (new sections 10-13)
- `docs\vault.md` (record measured facts)
- `dash\src\recorder.cs` (read only; smallest fix only if a test finds a real bug, reported)
- `dash\src\vault.cs` (read only; same rule)
- `docs\tasks\log\P0-01.md` (new; report)

## Gate
`powershell -ExecutionPolicy Bypass -File tests\recorder-test.ps1` -> all sections 0 FAIL. Compile: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exit 0. Deploy when sim=False only. Peter's real session gate: after his next in-car drive and one SAVE, exactly one session mp4 exists, ffprobe duration is the in-car time Â±2 %, the sidecar lap count equals iRacing's, the file is in `vault\saved`, and the Performance page reports recorder cost â¤ 3 fps.

## User journey
Peter drives a normal session. After getting out, he presses SAVE once on the phone; it says SAVED. Within 2 min the same session plays on the phone and the top screen. He fails this card if no mp4 appeared, SAVE did not put it in `vault\saved`, the length is clearly wrong, or the Performance page shows more than 3 fps lost to the recorder.

## Not in this card
iPhone playback quality (P0-02), Vault video player and compare (P0-10), retention tuning, story/incident video beyond S1's sidecar.

## Report
Write to `docs\tasks\log\P0-01.md` in AGENTS.md format:
```
CARD: P0-01 S1 judged live: real session recording + SAVE
RESULT: done | partly done | blocked
GATE: ... -> passed / failed (recorder-test: N ok, M FAIL)
FILES: ...
NEEDS PETER: drive one session and press SAVE once
NEEDS LEAD: deploy and run after the session
NOTES: ...
```
=== FILE: docs\cards\v4\P0-02.md ===
# P0-02 HEVC playback proven; h264 fallback
**Phase / depends on / size / needs Peter:** Phase 0 / P0-01 / S / Tap play once on the iPhone

## Why
Paddock promises video everywhere. If HEVC files do not play on the top-screen Chrome or iPhone Safari, Peter sees a black frame. This card proves the encoder choice before it matters, and flips the default to h264 if either screen fails.

## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\vault.md` - HEVC/h264 rules, mp4 tags, soft fallback path.
- `dash\src\recorder.cs` - encode procedure, fallback order, sidecar rotation/flags; find exactly where `hevc_nvenc`, `h264_nvenc`, `libx264` are chosen.
- `dash\www\phone\app.js` - session video player (`<video>`), error handling.
- `tests\recorder-test.ps1` - existing recorder tests, generated clips.

## Build
1. Find the current fallback chain in `recorder.cs`: before this card it chooses HEVC first. Note the exact method and field name in the report.
2. Add a `tests\recorder-test.ps1` section **14. HEVC top-screen playback:** use `vault\bin\ffmpeg.exe` to produce a 2-second test file `vault\test-hvc1.mp4` (`-c:v hevc_nvenc -tag:v hvc1 -movflags +faststart`); open it in headless Chrome the same way the dashboard runs, wait for `readyState >= 2` and `error` event; PASS only if it reaches the end.
3. Add a printable iPhone Safari instruction in the test output and `docs\vault.md`: create the same `test-hvc1.mp4`, serve it from a session, tap play once on the iPhone; PASS is picture + sound to the end, FAIL is a black frame/no play.
4. If either step 2 or 3 fails, change the default encoder in `recorder.cs` to `h264_nvenc` (fall back to `libx264 -preset veryfast` if the chip refuses). Update `docs\vault.md` so "h264 default" is the shipped fact. Re-run the test and assert h264.
5. In `dash\www\phone\app.js`, do NOT add new UI; only ensure the existing video element reports a codec error clearly enough for the test to read. If no change is needed, say so.
6. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 = stop.

## Files
- `dash\src\recorder.cs` (default encoder change only if HEVC fails)
- `dash\www\phone\app.js` (read; smallest error-handling edit only)
- `tests\recorder-test.ps1` (new section 14)
- `docs\vault.md` (record playback result and default)
- `docs\tasks\log\P0-02.md` (new; report)

## Gate
`powershell -ExecutionPolicy Bypass -File tests\recorder-test.ps1` -> new section 14 prints PASS and 0 FAIL overall. If the iPhone Safari result is not yet known, do not flip the encoder; mark the live iPhone check in NEEDS PETER. With a failing HEVC check, after the flip the test must assert the new default is h264 and PASS. `dash\build.ps1 -NoDeploy` exit 0.

## User journey
Peter taps a saved session on the iPhone; it plays, no black frame. If HEVC failed on the top screen, Paddock switched itself to h264 and future sessions play everywhere. He fails this card if the iPhone tap still produces a black frame after the fallback.

## Not in this card
Recorder live judgement beyond P0-01, retention, share/render output.

## Report
Write to `docs\tasks\log\P0-02.md` in AGENTS.md format:
```
CARD: P0-02 HEVC playback proven; h264 fallback
RESULT: done | partly done | blocked
GATE: ... -> passed / failed (recorder-test: N ok, M FAIL)
FILES: ...
NEEDS PETER: tap play once on the iPhone on the served test file
NEEDS LEAD: deploy recorder change if any
NOTES: ...
```
=== FILE: docs\cards\v4\P0-03.md ===
# P0-03 Hide the fake TV view
**Phase / depends on / size / needs Peter:** Phase 0 / none / S / none

## Why
The current TV view is a flat data-drawn map Peter rejected. It must not be reachable while the real TV rewrite (T-01..T-05) is not built. Hiding it removes a dead end and stops anyone showing a misleading screen.

## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `dash\src\irdash.cs` - find `TvView` state and `/api/do?c=tvview` dispatch.
- `dash\www\v2\index.html` - see how `tv.js`/`tv.css` are loaded.
- `dash\www\v2\core.js` - see if the TV panel toggler also loads them at runtime.
- `tests\tv-test.ps1` - current draw/render tests.

## Build
1. Find where `/api/do?c=tvview` is handled in `irdash.cs`.
2. Change it to answer HTTP 400 with the exact body `TV view rebuild`. Do not delete `TvView` data structure unless it is the simplest safe edit.
3. In `dash\www\v2\index.html`, remove the `<script>` tag for `tv.js` and the `<link>`/`<style>` tag for `tv.css`. Do not delete the files themselves.
4. If `core.js` loads `tv.js` dynamically, remove that loader line too; list it in the report. No other JS changes.
5. Rewrite `tests\tv-test.ps1` to the off state:
   - calling `/api/do?c=tvview` returns 400 and body equals `TV view rebuild`.
   - serving `/v2/index.html` contains no reference to `tv.js`/`tv.css`.
   - any old draw/render sections are removed or reduced to "off state, no draw".
6. `keys-test.ps1` must remain unchanged because no TV key exists today.
7. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 = stop.
8. Run copy-audit-test because the error body is visible text; it must pass.

## Files
- `dash\src\irdash.cs` (tvview route)
- `dash\www\v2\index.html` (remove loader)
- `dash\www\v2\core.js` (only if it loads tv.js; smallest edit)
- `tests\tv-test.ps1` (off-state rewrite)
- `docs\tasks\log\P0-03.md` (new; report)

## Gate
`powershell -ExecutionPolicy Bypass -File tests\tv-test.ps1` -> 0 FAIL, including 400 body `TV view rebuild` and no tv.js reference in served index.html. `keys-test.ps1` unchanged: still 0 dead keys added/removed. `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exit 0. Copy-audit-test passes for the visible error text.

## User journey
Peter cannot press anything that opens the flat fake TV map now. If he somehow calls the old toggle, he reads `TV view rebuild`. He fails this card if the fake map still appears or a dead toggle remains visible.

## Not in this card
Building the real TV view (T-01..T-05), changing deck keys, deleting `tv.js`/`tv.css`.

## Report
Write to `docs\tasks\log\P0-03.md` in AGENTS.md format:
```
CARD: P0-03 Hide the fake TV view
RESULT: done | partly done | blocked
GATE: ... -> passed / failed (tv-test: N ok, M FAIL)
FILES: ...
NEEDS PETER: none
NEEDS LEAD: deploy after sim=False
NOTES: ...
```
=== FILE: docs\cards\v4\P0-04.md ===
# P0-04 HOME THIS WEEK + LAST OUTING back
**Phase / depends on / size / needs Peter:** Phase 0 / none / S / none

## Why
Peter's HOME should answer "what did I do this week, and what did I do last?" with real numbers. These rows were removed and Peter noticed. Restoring them is a cheap, visible win.

## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\USER-GUIDE.md` - what THIS WEEK and LAST OUTING must show.
- `dash\src\home.cs` - current `/home` JSON assembly.
- `dash\www\v2\home.js` and `home.css` - render and layout slots.
- `docs\data.md` - weekly progress already exists in `data.cs`/`/career` as `week`; reuse it.
- `docs\ARCHITECTURE.md` - `career-cache.tsv` column 22: short run = did not leave pit road; short runs excluded.
- `tests\home-test.ps1` - current checks.

## Build
1. Find `/home` in `home.cs` and the existing `Career`/`DataApi` call that already builds week numbers in `data.cs`.
2. Add a `week` object to the `/home` JSON from that same data, with hours, laps, PBs, and last week's hours/laps.
3. Add a `lastOuting` object: the newest cache row that is a real outing (not a short run). Include date, car, track, session type, finish position when known, best lap, incidents.
4. In `home.js`, render two rows: "THIS WEEK" and "LAST OUTING", using real numbers only. Keep layout inside HOME; 0 overlaps.
5. Reuse the test's hand-worked fixture or real `career-cache.tsv`: choose rows by hand before coding, put those exact expected numbers in `tests\home-test.ps1` sections:
   - week numbers equal the hand calculation,
   - last outing is the latest real outing and skips short runs,
   - 0 text overlaps at 1920x1080,
   - copy-audit 0 for all visible text.
6. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 = stop.

## Files
- `dash\src\home.cs` (week + lastOuting JSON)
- `dash\www\v2\home.js` (render rows)
- `dash\www\v2\home.css` (layout only)
- `tests\home-test.ps1` (new checks with hand numbers)
- `docs\tasks\log\P0-04.md` (new; report)

## Gate
`powershell -ExecutionPolicy Bypass -File tests\home-test.ps1` -> 0 FAIL with the hand numbers. `dash\build.ps1 -NoDeploy` exit 0. Deploy when sim=False only; copy-audit-test 0.

## User journey
Peter opens HOME while the rig is idle. He sees THIS WEEK with hours, laps and PBs, and LAST OUTING with the last real date, car, track, result and incidents. He fails if either row is blank, wrong, or counts a test/short run as an outing.

## Not in this card
HOME v4 full layout (H-07), next-race panel (H-04), hero capture (T-08), welcome driver card (H-08).

## Report
Write to `docs\tasks\log\P0-04.md` in AGENTS.md format:
```
CARD: P0-04 HOME THIS WEEK + LAST OUTING back
RESULT: done | partly done | blocked
GATE: ... -> passed / failed (home-test: N ok, M FAIL)
FILES: ...
NEEDS PETER: none
NEEDS LEAD: deploy and look at the HOME row from the rig
NOTES: ...
```
=== FILE: docs\cards\v4\P0-05.md ===
# P0-05 Real GPS track maps from .ibt Lat/Lon/Alt
**Phase / depends on / size / needs Peter:** Phase 0 / none / M / none

## Why
Paddock must draw the shape Peter actually drove, from his own telemetry GPS, not an invented map. Road Atlanta must match the known outline tightly; Sonoma (no library copy) must still get a real map.

## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `dash\src\irdash.cs` - existing `TrackMaps` hook and `/trackmap` route.
- `dash\www\v2\map.js` - how outlines are projected and drawn.
- `dash\src\corners.cs` and `docs\corners.md` - library outline paths, Lovely apex pct values.
- `docs\research\ibt-channels.md` - Lat/Lon/Alt real doubles; subtract lap start before float use.
- `dash\build.ps1` - `$src` line to add a new source file.
- `tests\corners-test.ps1` and `tests\gpsmap-test.ps1` if present.

## Build
1. Create new `dash\src\gpsmap.cs` (C# 5). Read only Peter's own `.ibt` files, never iRacing config files.
2. For a given track key, use the cleanest full lap from old `.ibt` files at BelowNormal, never the newest file while the sim runs. Subtract the lap's first `Lat`/`Lon`/`Alt` from all points before storing floats. Accumulate all lap samples and store a GPS outline keyed by lap pct, plus raw `Alt`.
3. Fit the GPS outline to the existing library outline by translation + rotation where a library copy exists. Report mean and max point error in the JSON.
4. Wire into `irdash.cs`: when `/trackmap` or `TrackMaps` asks for a track, use the library outline for display where it exists, and expose the GPS-outline fields; when no library copy exists (e.g. Sonoma), return the GPS outline from his laps.
5. In `dash\www\v2\map.js`, add the projection path for the GPS outline. Alt are stored and returned, but the renderer must stay flat: **never draw hills**.
6. Add `gpsmap.cs` to the `$src` list in `dash\build.ps1`.
7. Create `tests\gpsmap-test.ps1`: fit Road Atlanta against the library outline -> mean â¤ 5 m, max â¤ 15 m; every Lovely apex within 20 m of the GPS line; Sonoma build from his laps succeeds; 6 pictures `tests\shots\gps-*.png`.
8. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 = stop.

## Files
- `dash\src\gpsmap.cs` (new)
- `dash\build.ps1` (`$src` line)
- `dash\src\irdash.cs` (TrackMaps hook)
- `dash\www\v2\map.js` (projection)
- `tests\gpsmap-test.ps1` (new)
- `docs\tasks\log\P0-05.md` (new; report)

## Gate
`powershell -ExecutionPolicy Bypass -File tests\gpsmap-test.ps1` -> 0 FAIL with the Road Atlanta fit numbers (mean â¤ 5 m, max â¤ 15 m), Rowets? every Lovely apex within 20 m, Sonoma map present, 6 pictures. `dash\build.ps1 -NoDeploy` exit 0. Deploy when sim=False only.

## User journey
Peter opens the Workbench map for Road Atlanta or Sonoma; the outline is the line he actually drove. He fails if the map looks invented, tilted, or hills appear.

## Not in this card
TiRST? maps; drawing hills; corner detection improvement; live GPS extraction; Google/satellite tiles.

## Report
Write to `docs\tasks\log\P0-05.md` in AGENTS.md format:
```
CARD: P0-05 Real GPS track maps from .ibt Lat/Lon/Alt
RESULT: done | partly done | blocked
GATE: ... -> passed / failed (gpsmap-test: N ok, M FAIL)
FILES: ...
NEEDS PETER: none
NEEDS LEAD: deploy and visually check the map pictures
NOTES: ...
```
=== FILE: docs\cards\v4\P0-06.md ===
# P0-06 Vault vs Performance identity
**Phase / depends on / size / needs Peter:** Phase 0 / none / S / none

## Why
Peter said Vault and Performance look the same. They are not the same product; the top of each page must say which one it is and give its headline number.

## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `dash\www\v2\vault.html`, `vault.css`, `perf.html`, `perf.css`, `theme.css`.
- `docs\USER-GUIDE.md` - Vault vs Performance purpose.
- `tests\quickwins-test.ps1` - place new pixel/identity checks here.

## Build
1. Read both pages in headless Chrome, capture `tests\shots\qw-vault-old.png` and `qw-perf-old.png` before changing.
2. Add a page-identifying first element to each page:
   - `vault.html`: "VAULT" plus headline number = GB used + item count, from the real Vault data already served.
   - `perf.html`: "PERFORMANCE" plus headline number = last average fps, from the real Performance data already served.
3. In CSS, make the top 160 px visually distinct enough that a pixel comparison of the two page headers differs in â¥ 40 % of pixels. Prefer real information text and a distinct top-border/background token from `theme.css`, not decoration.
4. Run the existing `tests\quickwins-test.ps1` and add a section:
   - top 160 px pixel difference â¥ 40 %,
   - each page's first visible header text contains the page name and the correct headline number,
   - copy-audit 0.
5. No C# changes expected.
6. Deploy is not needed for www changes, but still run `dash\build.ps1 -NoDeploy` for compile hygiene. No restart while driving.

## Files
- `dash\www\v2\vault.html`
- `dash\www\v2\vault.css`
- `dash\www\v2\perf.html`
- `dash\www\v2\perf.css`
- `dash\www\v2\theme.css` (tokens only)
- `tests\quickwins-test.ps1` (new section)
- `docs\tasks\log\P0-06.md` (new; report)

## Gate
`powershell -ExecutionPolicy Bypass -File tests\quickwins-test.ps1` -> new identity section 0 FAIL; pixel difference â¥ 40 %; copy-audit-test 0. `dash\build.ps1 -NoDeploy` exit 0. Two pictures `qw-vault-old.png`/`qw-vault-new.png`, `qw-perf-old.png`/`qw-perf-new.png` saved.

## User journey
Peter opens each page from HOME; without reading small text, the top line tells him Vault (GB used + count) or Performance (last average fps). He fails if the two tops still look indistinguishable.

## Not in this card
Vault video player, Vault cards layout, Performance content changes, design-token application across all pages (DS-01..04).

## Report
Write to `docs\tasks\log\P0-06.md` in AGENTS.md format:
```
CARD: P0-06 Vault vs Performance identity
RESULT: done | partly done | blocked
GATE: ... -> passed / failed (quickwins-test: N ok, M FAIL)
FILES: ...
NEEDS PETER: none
NEEDS LEAD: compare old/new pictures
NOTES: ...
```
=== FILE: docs\cards\v4\P0-07.md ===
# P0-07 Phone car/track search fix
**Phase / depends on / size / needs Peter:** Phase 0 / none / M / none

## Why
The phone search is janky. Peter must reach Corvette + Road Atlanta in 3 taps and START must be lit, without seeing rows that lead nowhere.

## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `dash\www\phone\app.js` - current car/track picker and search.
- `dash\www\phone\app.css` - dead/dim key styles.
- `dash\src\phone.cs` - what `/phone/state` or setup route already serves.
- `docs\USER-GUIDE.md` - phone SETUP tab description.
- `tests\phone-test.ps1` - current phone checks.

## Build
1. Find the current search path in `app.js`. Identify which fields are searched, whether a keystroke waits on the PC, and how result rows lead to START.
2. If `phone.cs` does not already serve a complete car and track list, add a small cache of exact names from `career-cache.tsv` (read-only, below normal) to the phone state. Never call iRacing UI.
3. In `app.js`, implement local fragment filtering:
   - case-insensitive match on letter groups (e.g. "atl" matches Road Atlanta),
   - dead letters dimmed, matching result rows shown on screen,
   - one exact unique match becomes the selected row,
   - every result row has a direct START path; no row rendered without one,
   - a search must settle within 1.5 s.
4. In `app.css`, keep result rows and START large enough for phone, and dim dead keys.
5. Extend `tests\phone-test.ps1`:
   - 10 common combos as a fixed list (e.g. `atl` -> Road Atlanta, `cor` -> Corvette Z06 GT3.R),
   - "atl" reaches Road Atlanta in â¤ 3 taps and â¤ 1.5 s,
   - no result row without START path,
   - copy-audit 0 for visible new text.
6. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy only when `irdeck-cli.exe state` shows `sim=False`, if irdash code changed; exit 2 = stop.

## Files
- `dash\www\phone\app.js`
- `dash\www\phone\app.css`
- `dash\src\phone.cs` (only if the search data is missing)
- `tests\phone-test.ps1` (new sections)
- `docs\tasks\log\P0-07.md` (new; report)

## Gate
`powershell -ExecutionPolicy Bypass -File tests\phone-test.ps1` -> 0 FAIL, including the 10 combos and the "atl" 3-tap / 1.5 s check, and no START-less result row. `dash\build.ps1 -NoDeploy` exit 0. Copy-audit-test 0.

## User journey
On the iPhone SETUP tab, Peter types "atl"; Road Atlanta appears first. He taps it, taps the Corvette result or its search, and START is lit. He fails if the search stalls, misses the truncation, or shows a result he cannot start.

## Not in this card
Phone REVIEW/W-16/W-17, pairing changes, away-from-home Tailscale, share flows.

## Report
Write to `docs\tasks\log\P0-07.md` in AGENTS.md format:
```
CARD: P0-07 Phone car/track search fix
RESULT: done | partly done | blocked
GATE: ... -> passed / failed (phone-test: N ok, M FAIL)
FILES: ...
NEEDS PETER: none
NEEDS LEAD: deploy if phone.cs changed
NOTES: ...
```
=== FILE: docs\cards\v4\P0-08.md ===
# P0-08 Session YAML field names for iRating/SR/results
**Phase / depends on / size / needs Peter:** Phase 0 / none / S / none

## Why
Career and stats (W-14/W-15) need proven field names from Peter's own `.ibt` session YAML. This card produces the exact facts, not assumptions.

## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\research\ibt-channels.md` - channels and current YAML questions; section 5 of SPEC says fields must be verified here.
- `dash\src\analysis.cs` - how irdash reads the session YAML/session string from `.ibt` files; find the exact method before writing the tool.
- `docs\vault.md` - the `DriverInfo.Drivers[]` and results block windows.

## Build
1. First step: find out the exact `.ibt` header/YAML extraction in `dash\src\analysis.cs` (or `career.cs`) and write its method name and file offset strategy in the report before writing `tools\yaml-fields.ps1`.
2. Create new `tools\yaml-fields.ps1` (PowerShell 5.1 only):
   - takes five old `.ibt` file paths in `Documents\iRacing\telemetry`, copies them if needed, reads at BelowNormal priority;
   - extracts the session YAML block;
   - prints, for the `PlayerCarIdx` index of `DriverInfo.Drivers`, the exact field names and sample values:
     - `IRating`
     - `LicString`
     - `LicLevel`
     - `LicSubLevel`
     - `LicColor`
   - prints the results block field names and one sample row;
   - never writes iRacing files; no C# changes.
3. Append a short "Session YAML field names verified" section to `docs\research\ibt-channels.md` with the exact field names and one sample row.

## Files
- `tools\yaml-fields.ps1` (new)
- `docs\research\ibt-channels.md` (append)
- `docs\tasks\log\P0-08.md` (new; report)

## Gate
`powershell -ExecutionPolicy Bypass -File tools\yaml-fields.ps1` exits 0 and prints all requested `DriverInfo.Drivers[]` field names and one sample row from each of 5 old `.ibt`, plus the results block names. The appended doc section contains those exact names and one sample row. no code compile needed; run the script on copies.

## User journey
None here; this is a fact list for W-14/W-15. A later card consumes it.

## Not in this card
Career backfill (W-14), stats screen (W-15), CSV import, any live field extraction.

## Report
Write to `docs\tasks\log\P0-08.md` in AGENTS.md format:
```
CARD: P0-08 Session YAML field names for iRating/SR/results
RESULT: done | partly done | blocked
GATE: ... -> passed / failed (yaml-fields.ps1: printed ...)
FILES: ...
NEEDS PETER: none
NEEDS LEAD: none
NOTES: exact method found, field names, sample values
```
=== FILE: docs\cards\v4\P0-09.md ===
# P0-09 After-race laps while sim still in + quick wins deployed (C-27/C-29)
**Phase / depends on / size / needs Peter:** Phase 0 / none / M / none

## Why
After a race Peter is often still in the sim looking at results. The laps must appear in the strip within 30 s, not after 120 s. This also lands two already-fixed quick wins: lap page stall after clip attach and stale self-comparison label.

## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `dash\src\vault.cs` - reader timing, after-race strip, clip attach, self-compare reference.
- `dash\www\v2\debrief.js` and `vault.js` - strip rendering and lap page comparison.
- `tests\review-test.ps1` and `tests\quickwins-test.ps1`.
- `docs\vault.md` sections "After-race review" and "Whole sessions"; `docs\data.md` for newest-file and short-run rules.

## Build
1. Find the current `vault.cs` rule that waits 120 s and always skips the newest `.ibt` while `iRacingSim64DX11` is running.
2. Change it to: still never read the newest `.ibt` while `IsOnTrack` or a live session is running; once the session is over (`SessionState` finished or SDK link down) and the file size is stable for 3 s, read it at BelowNormal even though the sim process is up. Log `vault: after-race read` with the file and elapsed time.
3. In `debrief.js`, make the laps-saved strip appear in whichever debrief view is showing when the laps become ready.
4. Fix the two C-29 quick wins in `vault.js`:
   - clear `V.refInfo` when a lap page opens, so the comparison label never shows the previous page's lap;
   - fix the lap page stall after a clip is attached (the lap column and empty comparison state must render).
5. Run `tests\review-test.ps1` and add the pretend case: session over, sim process still running -> laps within 30 s; picture `tests\shots\c27-strip.png`.
6. Run `tests\quickwins-test.ps1`; all existing quick-wins checks, including stall and stale ref, must pass.
7. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 = stop.

## Files
- `dash\src\vault.cs`
- `dash\www\v2\debrief.js`
- `dash\www\v2\vault.js`
- `tests\review-test.ps1` (new section)
- `tests\quickwins-test.ps1` (run only; add assertions if needed)
- `docs\tasks\log\P0-09.md` (new; report)

## Gate
`powershell -ExecutionPolicy Bypass -File tests\review-test.ps1` -> 0 FAIL including "session over, sim process still running -> laps within 30 s". `powershell -ExecutionPolicy Bypass -File tests\quickwins-test.ps1` -> 0 FAIL. `dash\build.ps1 -NoDeploy` exit 0. Deploy when sim=False only. Picture `tests\shots\c27-strip.png` exists.

## User journey
Peter finishes a race and stays in the sim to see the results. Within 30 s the top-screen strip says "3 laps saved" before he leaves the sim. He fails if it never appears while the sim is still open or says the wrong lap count.

## Not in this card
Debrief v4 wireframe (D-03), incidents video (D-04), full Vault video compare (P0-10).

## Report
Write to `docs\tasks\log\P0-09.md` in AGENTS.md format:
```
CARD: P0-09 After-race laps while sim still in + quick wins deployed
RESULT: done | partly done | blocked
GATE: ... -> passed / failed (review-test / quickwins-test: ...)
FILES: ...
NEEDS PETER: none
NEEDS LEAD: deploy and watch after next real session
NOTES: ...
```
=== FILE: docs\cards\v4\P0-10.md ===
# P0-10 Vault video player + compare two clips (C-08)
**Phase / depends on / size / needs Peter:** Phase 0 / P0-01 / M / none

## Why
A saved lap should play with the map dot and traces locked to the video, and two laps should compare locked by track position. This makes the Vault watchable and useful, not just a list.

## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\vault.md` - `/vault/video` and `/vault/videoinfo` Range routes, sidecar `lapStartOffset`, lap naming.
- `dash\src\vault.cs` - existing Range serving and clip matching.
- `dash\www\v2\vault.js` and `vault.css` - detail view, map, traces.
- `dash\www\v2\workbench-video.js` - existing two-up video handling and cursor-video sync.
- `tests\vault-test.ps1` - current tests and generated clip fixtures.

## Build
1. Add/confirm the HTML5 `<video>` player on the Vault lap page using `GET /vault/video?id=<lap id>`; it uses HTTP Range.
2. Sync cursor to video using the sidecar: `video.currentTime = lapStartOffset + lapTimeAtCursor`. Moving the map dot or trace cursor seeks the video; playing moves the dot and cursor.
3. Add compare two clips of the same car+track:
   - choose a second lap, never the same lap/session file (no self-compare);
   - lock by `LapDistPct`; if one lap is ahead in track position, it waits so both show the same corner;
   - use `workbench-video.js` existing clip handling where possible.
4. Extend `tests\vault-test.ps1` with a generated clip and sidecar:
   - cursor-video sync â¤ 1 frame at 10 points;
   - two clips locked by LapDistPct are â¤ 0.1 s apart at 3 corners;
   - no self-compare (same lap/session file excluded).
5. Compile only: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Deploy only when `irdeck-cli.exe state` shows `sim=False`; exit 2 = stop.

## Files
- `dash\www\v2\vault.js`
- `dash\www\v2\vault.css`
- `dash\www\v2\workbench-video.js`
- `dash\src\vault.cs` (read; smallest edit if Range route has a real bug)
- `tests\vault-test.ps1` (new sections)
- `docs\tasks\log\P0-10.md` (new; report)

## Gate
`powershell -ExecutionPolicy Bypass -File tests\vault-test.ps1` -> 0 FAIL including: cursor-video sync â¤ 1 frame at 10 points; compare two clips locked by LapDistPct with â¤ 0.1 s at 3 corners; no self-compare. `dash\build.ps1 -NoDeploy` exit 0. Deploy when sim=False only. Pictures for lead: `tests\shots\v-player-*.png`.

## User journey
Peter opens a saved lap; the video plays and the dot on the map follows it. He adds a second lap of the same car/track; at T1 both videos show T1 at the same moment. He fails if the video is black, the dot drifts by more than a frame, or a lap compares with itself.

## Not in this card
Recorder live judgement beyond P0-01, share video, pro comparison, Vault full redesign.

## Report
Write to `docs\tasks\log\P0-10.md` in AGENTS.md format:
```
CARD: P0-10 Vault video player + compare two clips
RESULT: done | partly done | blocked
GATE: ... -> passed / failed (vault-test: N ok, M FAIL)
FILES: ...
NEEDS PETER: none
NEEDS LEAD: deploy and review v-player pictures
NOTES: ...
```