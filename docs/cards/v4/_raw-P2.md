=== FILE: docs\cards\v4\H-01.md ===
# H-01 Official schedule source + parser hardening
**Phase / depends on / size / needs Peter:** Phase 2 / none / M / none
## Why (2-4 lines: what Peter gets, which signature moment)
Peter gets a reliable iRacing season schedule source so HOME can later name his next official race with the right local time. This is the data foundation for the signature "before driving" HOME moment.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
Read AGENTS.md, CLAUDE.md, COPY-RULES.md, docs\OPERATIONS.md, docs\ARCHITECTURE.md, docs\research\calendars-2026-10.md, dash\src\officialcore.cs, dash\src\official.cs, src\official.cs, tests\official-test.ps1. Look for PdfText.Extract, OfficialCore.ParseSeason, ParsePattern, BuildOwned, Upcoming; the `official=0` switch in dash\irdash.ini; current network rules (BelowNormal, one request at a time, never while Sdk.RealBusy() true). C# 5 only: no `$"..."`, `?.`, `nameof`, expression-bodied members, `out var`; no frameworks.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find out the current parser entry points and data shapes in `dash\src\officialcore.cs` and `dash\src\official.cs`; write the exact function names and current JSON fields to the report.
2. Add a source acquisition step in `officialcore.cs`: from the iRacing season page URL (`https://www.iracing.com/seasons/2026-s4/`) find the PDF link; if no PDF link, parse the HTML season table. Use `HttpWebRequest`, BelowNormal priority, one request at a time, never while `Sdk.RealBusy()` is true. Cache the downloaded source in `data\official\source-cache\` with an `asOf` timestamp.
3. Add fixture files under `data\official\fixtures\`: one S4 PDF/HTML fixture (real S4 schedule, 10 series hand-checked for car, track, cadence) and one 2027 S1 absent fixture.
4. Harden `ParseSeason` / `ParsePattern`: parse car, track, cadence from the S4 fixture; when 2027 S1 is absent return `"not published"` and do not crash.
5. Extend `tests\official-test.ps1` with new sections: source step (3 checks), S4 fixture parse (10 series hand-checked), 2027 S1 absent (1 check).
6. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; run the test; deploy with `dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop).
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
`dash\src\officialcore.cs`, `dash\src\official.cs`, `src\official.cs`, `tests\official-test.ps1`, `docs\official.md`, new `data\official\fixtures\` (S4 fixture, 2027 absent fixture), new `data\official\source-cache\` (cache).
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
`tests\official-test.ps1` new sections: source step 3 ok, S4 fixture parse 10 ok, 2027 S1 absent 1 ok. Compile `-NoDeploy` exit 0. Deploy only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop). `copy-audit-test` passes for any visible text.
## User journey (what Peter does and sees; how he would fail it)
Peter does nothing in this card. He would fail it if the parser crashes on a missing season or a later HOME shows a wrong start time.
## Not in this card (what to leave for later cards)
Turning `official=1` on, HOME UI, real-world calendar, deck screen, registration.
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\H-01.md` in AGENTS.md format (CARD/RESULT/GATE/FILES/NEEDS PETER/NEEDS LEAD/NOTES).

=== FILE: docs\cards\v4\H-02.md ===
# H-02 His series, ownership, next race
**Phase / depends on / size / needs Peter:** Phase 2 / H-01 / M / none
## Why (2-4 lines: what Peter gets, which signature moment)
Peter gets a filtered official schedule: only series he has raced in the last 90 days or favourited, with owned car/track markers and the next start with a countdown. This is the data HOME needs to name his next race.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
Read AGENTS.md, CLAUDE.md, COPY-RULES.md, docs\OPERATIONS.md, docs\ARCHITECTURE.md, docs\data.md (career cache columns), dash\src\official.cs, dash\src\officialcore.cs, src\official.cs, tests\official-test.ps1. Look for OfScanOwned, BuildOwned, favourites storage, `dash\career-cache.tsv` columns (car, track, date), `official\favourites.ini`. C# 5 only; no frameworks; never write iRacing files.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find out the current ownership scan and favourites storage; write the exact function names and file paths to the report.
2. His series = series raced in the last 90 days âª favourites. Use `dash\career-cache.tsv` (car, track, date columns) to find series; favourites from `official\favourites.ini`.
3. Owned from car/track folders read-only: `C:\Program Files (x86)\iRacing\cars` and `C:\Program Files (x86)\iRacing\tracks`. Map folder names to display names using the existing name map or `tdfind`; cache in `official\owned.json`.
4. Next start and countdown: from the parsed cadence and local time, compute the next start for 3 hand-worked cadences across DST; countdown in minutes/seconds.
5. Extend the `/official` JSON with `series`, `car`, `track`, `localStart`, `countdown`, `owned`, `cadence`.
6. Extend `tests\official-test.ps1` with new sections: his series (3 checks), ownership (3 checks), next start/countdown (3 hand-worked cadences across DST).
7. After tests pass, set `official=1` in `dash\irdash.ini` (smallest edit) and report it.
8. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; run the test; deploy with `dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop).
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
`dash\src\official.cs`, `dash\src\officialcore.cs`, `src\official.cs`, `tests\official-test.ps1`, `dash\irdash.ini` (one line `official=1` after tests), `official\favourites.ini`, new `official\owned.json` (cache).
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
`tests\official-test.ps1` new sections: his series 3 ok, ownership 3 ok, next start/countdown 3 ok. Compile `-NoDeploy` exit 0. Deploy only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop). `copy-audit-test` passes for any visible text.
## User journey (what Peter does and sees; how he would fail it)
Peter does nothing in this card. He would fail it if HOME later names a series he does not own or a wrong start time.
## Not in this card (what to leave for later cards)
HOME UI, real-world calendar, deck screen, registration.
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\H-02.md` in AGENTS.md format (CARD/RESULT/GATE/FILES/NEEDS PETER/NEEDS LEAD/NOTES).

=== FILE: docs\cards\v4\H-03.md ===
# H-03 Benchmark (yardstick) fix
**Phase / depends on / size / needs Peter:** Phase 2 / none / M / none
## Why (2-4 lines: what Peter gets, which signature moment)
Peter gets a benchmark card that tells him his next goal in 5 seconds: PB, field percentiles with sample size, similar-iRating pace, IMSA reference with source, and the nearest yardstick above with the gap. This fixes the "yardstick sucks" complaint.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
Read AGENTS.md, CLAUDE.md, COPY-RULES.md, docs\OPERATIONS.md, docs\ARCHITECTURE.md, docs\data.md (benchmark card), dash\src\bench.cs, dash\www\v2\bench.js, bench.css, data\fieldlaps.tsv, data\pro-refs.json, tests\bench-test.ps1. Look for FieldLaps, ProRefs, Bench, current yardstick logic and JSON shape. C# 5 only; no frameworks; never write iRacing files.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find out the current `bench.cs` JSON shape and `data\fieldlaps.tsv` columns; write the exact fields to the report.
2. Compute per combo: PB from career cache; top 5%, top 25%, median from `fieldlaps.tsv` only when n â¥ 30, n shown; similar-iRating pace (use the existing definition if present; if absent use drivers within Â±200 iRating of Peter's current iRating, n shown, hide if n < 30); IMSA ref from `pro-refs.json` with source URL; NEXT = nearest yardstick above PB with gap; PB history from career cache.
3. Update `bench.js` / `bench.css` to render PB, yardsticks with n, source, NEXT line, PB history dots; no yardstick shown without n.
4. Extend `tests\bench-test.ps1` with new sections: 4 combos hand-checked (each PB, top 5/25/median, similar-iRating, IMSA ref, NEXT, PB history), n<30 hides yardstick (1 check).
5. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; run the test; deploy with `dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop).
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
`dash\src\bench.cs`, `dash\www\v2\bench.js`, `dash\www\v2\bench.css`, `data\fieldlaps.tsv`, `data\pro-refs.json`, `tests\bench-test.ps1`.
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
`tests\bench-test.ps1` new sections: 4 combos hand-checked (4 ok each), n<30 hides yardstick (1 ok). Compile `-NoDeploy` exit 0. Deploy only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop). `copy-audit-test` passes for any visible text.
## User journey (what Peter does and sees; how he would fail it)
Peter opens the Road Atlanta Corvette card and sees PB 1:19.549, field top 5% / 25% / median with n, similar-iRating pace, IMSA ref with source, NEXT line with gap, PB history dots. He fails it if any yardstick appears without n or the next goal is wrong.
## Not in this card (what to leave for later cards)
HOME UI, real-world calendar, Garage 61, pro comparison.
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\H-03.md` in AGENTS.md format (CARD/RESULT/GATE/FILES/NEEDS PETER/NEEDS LEAD/NOTES).

=== FILE: docs\cards\v4\H-04.md ===
# H-04 HOME next-race data
**Phase / depends on / size / needs Peter:** Phase 2 / H-02, H-03 / S / none
## Why (2-4 lines: what Peter gets, which signature moment)
Peter gets the `/home` JSON carrying his next official race with series, car, track, local start, countdown, owned marker, PB there, and field median with n. This is the data H-07 lays out on HOME.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
Read AGENTS.md, CLAUDE.md, COPY-RULES.md, docs\OPERATIONS.md, docs\ARCHITECTURE.md, dash\src\home.cs, dash\src\official.cs, dash\src\bench.cs, tests\home-test.ps1. Look for Career.HomeJson, Home.HeroPath, current `/home` JSON fields. C# 5 only; no frameworks; never write iRacing files.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find out the current `/home` JSON fields in `home.cs`; write the exact fields to the report.
2. Add a `nextRace` object to the `/home` JSON: `series`, `car`, `track`, `localStart`, `countdown`, `owned`, `pb`, `fieldMedian`, `fieldN`. Pull series/car/track/localStart/countdown/owned from `official.cs`; pb from career cache; fieldMedian/fieldN from `bench.cs`.
3. Ensure countdown is local time and the absolute date sits beside it.
4. Extend `tests\home-test.ps1` with a new section: `/home` next-race data (6 checks: series, car, track, localStart, countdown, owned, pb, fieldMedian, fieldN).
5. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; run the test; deploy with `dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop).
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
`dash\src\home.cs`, `tests\home-test.ps1`.
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
`tests\home-test.ps1` new section: `/home` next-race data 6 ok. Compile `-NoDeploy` exit 0. Deploy only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop). `copy-audit-test` passes for any visible text.
## User journey (what Peter does and sees; how he would fail it)
Peter does nothing in this card. He would fail it if `/home` lacks any next-race field or the countdown is wrong.
## Not in this card (what to leave for later cards)
HOME layout, real-world calendar, driver card.
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\H-04.md` in AGENTS.md format (CARD/RESULT/GATE/FILES/NEEDS PETER/NEEDS LEAD/NOTES).

=== FILE: docs\cards\v4\H-05.md ===
# H-05 Real-world calendar fetch
**Phase / depends on / size / needs Peter:** Phase 2 / none / M / none
## Why (2-4 lines: what Peter gets, which signature moment)
Peter gets the real-world racing weekend (IMSA, WEC, F1, GTWC) in local time with TBC and "as of" markers. This is the data for the THIS WEEKEND panel on HOME.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
Read AGENTS.md, CLAUDE.md, COPY-RULES.md, docs\OPERATIONS.md, docs\ARCHITECTURE.md, docs\research\calendars-2026-10.md, docs\official.md, dash\src\official.cs (for network patterns), tests\official-test.ps1. Look for Sdk.RealBusy, BelowNormal, one request at a time, throttled ~500 KB/s. C# 5 only; no frameworks; never write iRacing files.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find out any current real-world data in `official.cs`; write the exact fields to the report.
2. Create new `dash\src\realworld.cs` and add it to the `$src` line in `dash\build.ps1`. Define a `RealWorld` class with Init/Route/Do.
3. Implement fixture parsers for F1 (Jolpica/OpenF1 JSON), IMSA, WEC, GTWC (official calendar pages HTML/PDF). Use `HttpWebRequest`, BelowNormal priority, one request at a time throttled to ~500 KB/s, never while `Sdk.RealBusy()` is true.
4. Cache in `data\official\realworld.json` with events: `series`, `event`, `track`, `session`, `localStart`, `tbc`, `source`, `asOf`. Local times from this PC's time zone; TBC when unpublished; "as of" when stale (>6 h).
5. One live fetch per source in tests; cache 6 h.
6. Write one terms line per source in `docs\official.md`.
7. Extend `tests\realworld-test.ps1` with new sections: fixture parsers (4 sources), live fetch (4 sources), local times/TBC/asOf (3 checks).
8. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; run the test; deploy with `dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop).
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
new `dash\src\realworld.cs`, `dash\build.ps1` (`$src` line), new `data\official\realworld.json`, new `tests\realworld-test.ps1`, `docs\official.md`.
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
`tests\realworld-test.ps1` new sections: fixture parsers 4 ok, live fetch 4 ok, local times/TBC/asOf 3 ok. Compile `-NoDeploy` exit 0. Deploy only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop). `copy-audit-test` passes for any visible text.
## User journey (what Peter does and sees; how he would fail it)
Peter does nothing in this card. He would fail it if a real-world line shows a wrong local time or lacks TBC/source.
## Not in this card (what to leave for later cards)
Preview lines, HOME UI, iRacing official schedule.
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\H-05.md` in AGENTS.md format (CARD/RESULT/GATE/FILES/NEEDS PETER/NEEDS LEAD/NOTES).

=== FILE: docs\cards\v4\H-06.md ===
# H-06 Preview lines by a cheap model at fetch time
**Phase / depends on / size / needs Peter:** Phase 2 / H-05 / M / A yes; ~Â£1 a year
## Why (2-4 lines: what Peter gets, which signature moment)
Peter gets one factual preview line per real-world race, generated by a cheap model at fetch time, with source and date, filtered by copy rules. This makes the THIS WEEKEND panel informative without filler.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
Read AGENTS.md, CLAUDE.md, COPY-RULES.md, docs\OPERATIONS.md, docs\ARCHITECTURE.md, docs\research\calendars-2026-10.md, dash\src\realworld.cs, tests\realworld-test.ps1, docs\COPY-RULES.md. Look for OpenRouter key env var `OPENROUTER_API_KEY`, copy-audit regexes, cost logging. C# 5 only; no frameworks; never write iRacing files.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find out the current `realworld.cs` event shape and where a preview line would attach; write the exact fields to the report.
2. Add `preview_lines=0` default in `dash\irdash.ini`; only run when Peter says yes and the key is present.
3. Implement in `realworld.cs`: for each real-world event, one call per event per week to OpenRouter DeepSeek V4.1 Flash via `HttpWebRequest` POST to `https://openrouter.ai/api/v1/chat/completions`, Authorization Bearer from user env var `OPENROUTER_API_KEY`, fixed prompt: "Write at most 2 factual lines for this race: series, event, track, session, local start, classes, source, date. No advice, no filler." Parse JSON by hand.
4. Run copy-audit regexes on the output and reject if any pattern matches; keep source + date; cache in `data\official\realworld.json` preview field.
5. Log cost from response usage to `docs\tasks\log\or\preview-cost.tsv`.
6. Add one rule to `docs\COPY-RULES.md`: generated preview lines must be facts only, source and date, no filler.
7. Extend `tests\realworld-test.ps1` with a new section: preview lines (3 checks: one call per event per week, copy-audit reject, source/date kept, off without key/yes).
8. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; run the test; deploy with `dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop).
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
`dash\src\realworld.cs`, `dash\irdash.ini` (`preview_lines=0`), `data\official\realworld.json`, `tests\realworld-test.ps1`, `docs\COPY-RULES.md`, new `docs\tasks\log\or\preview-cost.tsv`.
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
`tests\realworld-test.ps1` new section: preview lines 3 ok. Compile `-NoDeploy` exit 0. Deploy only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop). `copy-audit-test` passes for any visible text.
## User journey (what Peter does and sees; how he would fail it)
Peter says yes once; on HOME he sees "IMSA Â· Petit Le Mans Â· Sat 12:10 Â· 10 h Â· GTP LMP2 GTD Pro GTD Â· imsa.com 6 Oct". He fails it if the line is not factual, lacks source/date, or appears without his yes.
## Not in this card (what to leave for later cards)
HOME UI, other series, voice.
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\H-06.md` in AGENTS.md format (CARD/RESULT/GATE/FILES/NEEDS PETER/NEEDS LEAD/NOTES).

=== FILE: docs\cards\v4\H-07.md ===
# H-07 HOME v4 layout (3b)
**Phase / depends on / size / needs Peter:** Phase 2 / H-04, H-05, P0-04 / M / none
## Why (2-4 lines: what Peter gets, which signature moment)
Peter gets the before-driving HOME screen: next race and countdown readable in 3 seconds, real-world weekend, THIS WEEK, LAST OUTING, and one big button that starts his usual drive. This is signature moment b.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
Read AGENTS.md, CLAUDE.md, COPY-RULES.md, docs\OPERATIONS.md, docs\ARCHITECTURE.md, docs\SPEC-v4.md section 3b, dash\www\v2\home.js, home.css, dash\src\home.cs, tests\home-test.ps1. Look for current home layout, hero image, big button state. C# 5 only; no frameworks; real assets only; never write iRacing files.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find out the current `home.js` / `home.css` structure and `home.cs` JSON fields; write the exact current boxes to the report.
2. Rewrite `home.js` / `home.css` to the 3b wireframe: header (PADDOCK, date/time, Rig OK/fps), NEXT RACE box, hero image (`paddock\home\hero.jpg`, credited stand-in until T-08), driver card area (H-08 fills), THIS WEEKEND real-world, THIS WEEK, LAST OUTING, big button (RIG ON / LAST DRIVE / GET IN by state), footer links Sessions & laps Â· Vault Â· Performance Â· Stats and QR phone.
3. Use real assets only: hero.jpg, iRacing car pictures from `/cars`; no drawn cars. Owned/not as a word, not a colour. Countdown "in 1 h 03" plus absolute date.
4. Ensure one big button by state; no overlaps; body â¥22 px, labels â¥14 px small caps.
5. Extend `tests\home-test.ps1` with new sections: boxes within 20 px of wireframe (8 checks), one big button by state (3 checks), 0 overlaps (1 check), copy-audit 0 (1 check), pictures idle/rig up/session open (3 pictures).
6. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; run the test; deploy with `dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop).
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
`dash\www\v2\home.js`, `dash\www\v2\home.css`, `dash\src\home.cs`, `tests\home-test.ps1`.
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
`tests\home-test.ps1` new sections: boxes 8 ok, big button 3 ok, overlaps 1 ok, copy-audit 1 ok; pictures `tests\shots\home-idle.png`, `home-rigup.png`, `home-session.png`. Compile `-NoDeploy` exit 0. Deploy only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop). `copy-audit-test` passes for any visible text.
## User journey (what Peter does and sees; how he would fail it)
Peter sits down, reads the next race and countdown in 3 seconds; one press on the big button starts his usual drive. He fails it if any box overlaps, the countdown is wrong, or the button does not match the state.
## Not in this card (what to leave for later cards)
Driver card content (H-08), hero capture (T-08), real-world fetch (H-05), preview lines (H-06).
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\H-07.md` in AGENTS.md format (CARD/RESULT/GATE/FILES/NEEDS PETER/NEEDS LEAD/NOTES).

=== FILE: docs\cards\v4\H-08.md ===
# H-08 Welcome driver card
**Phase / depends on / size / needs Peter:** Phase 2 / H-07 / S / none
## Why (2-4 lines: what Peter gets, which signature moment)
Peter gets a welcome driver card on HOME showing his name, number 4, team, and the live car picture of the car he is in now. This restores the driver card that was dropped.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
Read AGENTS.md, CLAUDE.md, COPY-RULES.md, docs\OPERATIONS.md, docs\ARCHITECTURE.md, dash\www\v2\home.js, dash\src\home.cs, dash\www\v2\carpics.js, tests\home-test.ps1. Look for name/number/team fields, `/cars` manifest, local cache. C# 5 only; no frameworks; real assets only; never write iRacing files.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. Find out the current name/number/team fields in `home.cs` and the `carpics.js` API; write the exact fields to the report.
2. In `home.cs`, add driver card fields to the `/home` JSON: name from session YAML `DriverInfo.Drivers[PlayerCarIdx].UserName`, number live (verify 4), team text "Pratt Miller Motorsports", carPath for the live car picture.
3. In `home.js`, render the driver card in the H-07 area: name, number, team, live car picture from `/cars` via `carpics.js`; if no picture, typography only.
4. Cache the car picture locally in `paddock\cars\` so the second launch is offline; no network after the first fetch.
5. Extend `tests\home-test.ps1` with a new section: driver card (4 checks: name, number 4, team, car picture or typography only, offline second launch).
6. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; run the test; deploy with `dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop).
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
`dash\www\v2\home.js`, `dash\src\home.cs`, `dash\www\v2\carpics.js`, `tests\home-test.ps1`, `paddock\cars\` (cache).
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
`tests\home-test.ps1` new section: driver card 4 ok. Compile `-NoDeploy` exit 0. Deploy only when `irdeck-cli.exe state` shows sim=False (exit 2 = stop). `copy-audit-test` passes for any visible text.
## User journey (what Peter does and sees; how he would fail it)
Peter sees the card show the car he is in now with his name, number 4, team, and the car picture. He fails it if the number is wrong, the picture is missing without typography, or it needs network on second launch.
## Not in this card (what to leave for later cards)
Hero shot capture, other HOME changes, car art from iRacing .dat.
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\H-08.md` in AGENTS.md format (CARD/RESULT/GATE/FILES/NEEDS PETER/NEEDS LEAD/NOTES).