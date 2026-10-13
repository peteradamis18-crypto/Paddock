=== FILE: docs\cards\v4\T-01.md ===
# T-01 TV data engine
**Phase / depends on / size / needs Peter:** Phase 4 / none / M / none
## Why (2-4 lines: what Peter gets, which signature moment)
The TV view's data engine: every car's position, gap, interval, pit state and laps, read from one frozen frame at 10 Hz. This is the foundation for the timing tower, the map with every car, and the director label. Without it, the 4th screen cannot show a broadcast the room can follow.
## Read first (AGENTS.md, CLAUDE.md, COPY-RULES.md + the exact docs/code files to read, with what to look for)
- `AGENTS.md` and `CLAUDE.md`: the hard safety rules, C# 5 only, never act while he drives, tests are the definition of done.
- `docs\SPEC-v4.md` section 3d (the TV wireframe) and section 5 Phase 4 table (T-01 gate).
- `docs\research\fourth-screen-tv.md` section 2.6: which `CarIdx*` arrays to read, the one-frozen-frame rule, Max Cars 63 caveat.
- `docs\ARCHITECTURE.md`: how irdash reads the SDK (`Sdk.Latest`), how routes are added, the `$src` list in `dash\build.ps1`.
- `dash\src\irdash.cs`: how `Sdk` is read, how routes answer JSON, how `Program.IsDriving` is checked.
- `dash\src\field.cs`: the existing 10 Hz sampler that reads `CarIdx*` arrays for the race log - reuse its reading pattern and its `CarIdx` array names.
- `tests\race-field-test.ps1`: how the pretend race feeds `CarIdx*` arrays through the test hook, and how the test checks numbers.
- `docs\vault.md` "The race log": the exact `CarIdx*` arrays already read and the precision notes.
## Build (numbered steps, concrete: functions/routes/JSON fields/file names/units/thresholds; existing code to reuse by name; C# 5 only; no frameworks; real assets only; never write iRacing files; never act while he drives)
1. **Find out the exact `CarIdx*` array names and their units in `dash\src\field.cs`** (the race log sampler) and write them in the report. The spec names `LapDistPct`, `Position`, `ClassPosition`, `OnPitRoad`, `F2Time/EstTime`, `Lap`, `LastLapTime`; verify which of these `field.cs` already reads and how it freezes one frame.
2. Create `dash\src\tv.cs` (new file) with a `Tv` static class. Add `tv.cs` to the `$src` list in `dash\build.ps1`.
3. In `Tv`, add a `Tick()` method that runs at 10 Hz (reuse the timer pattern from `field.cs`). Each tick: freeze one SDK frame (read all `CarIdx*` arrays from the same frame, exactly as `field.cs` does), then build a snapshot list of every car: `idx`, `number` (from session YAML `DriverInfo.Drivers[].CarNumberRaw`), `name`, `class`, `classColor`, `pct` (`CarIdxLapDistPct`), `pos` (`CarIdxPosition`), `classPos` (`CarIdxClassPosition`), `pit` (`CarIdxOnPitRoad`), `lap` (`CarIdxLap`), `last` (`CarIdxLastLapTime`), `gap` (seconds to the leader, computed from `pct` and the leader's `pct` using the track length from the session YAML, or from `CarIdxF2Time` if that array exists - find out which in step 1 and write it in the report), `interval` (seconds to the car ahead in class, same method).
4. Add a `Battle` detection: two cars of the same class within 0.8 s of each other for at least 5 consecutive ticks (0.5 s at 10 Hz). Store the battle pair (car idxs) in the snapshot.
5. Add a route `GET /tv` in `irdash.cs` (or in `Tv.Route`) that returns the latest snapshot as JSON: `{ "tick": <n>, "cars": [ ... ], "battles": [ { "a": <idx>, "b": <idx> } ], "track": "<track name>", "config": "<layout>", "length": <m> }`. Answer 503 while `Program.IsDriving` is true (the TV view is for the room, not for him while he drives - but the data engine itself may run; the route refusal matches the existing pattern in `field.cs`).
6. Add a test-only route `GET /tv/test/feed` (only when `dash\test-hook.on` exists) that lets the test push a pretend frame of `CarIdx*` arrays, exactly like `race-field-test.ps1` does for the race log. Reuse the same test-hook pattern.
7. Write `tests\tv-test.ps1` (new file): dot-source `tests\guard.ps1`, `Assert-RigFree` at the start, `Section` before each part. Sections: (a) the pretend race from `race-field-test.ps1` feeds a frame, `/tv` returns every car with the right `pct`, `pos`, `classPos`, `pit`, `lap`, `last`; (b) gap and interval are hand-checked for 3 cars (the test computes the expected values from the pretend `pct` values and the track length); (c) a battle appears after 5 ticks of two same-class cars within 0.8 s and disappears when they separate; (d) `/tv` answers 503 while the pretend session says he is driving; (e) the route answers 404 without the test hook.
8. Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`. Fix all C# 5 errors (no `$"..."`, no `?.`, no `nameof`, no expression-bodied members, no `out var`).
9. Run `powershell -ExecutionPolicy Bypass -File tests\tv-test.ps1`. All sections must print `ok` lines and 0 `FAIL`.
## Files (exhaustive; "new" marked; anything not listed is off limits except the smallest edit, reported)
- `dash\src\tv.cs` (new)
- `dash\build.ps1` (add `tv.cs` to `$src`)
- `dash\src\irdash.cs` (add the `/tv` route and the test route, smallest edit)
- `tests\tv-test.ps1` (new)
- `docs\tasks\log\T-01.md` (new report)
## Gate (the named test file and its new sections, each with numbers; compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy`; deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop; copy-audit-test passes for any visible text)
`tests\tv-test.ps1`:
- Section 1: pretend frame -> `/tv` returns all cars, 3 hand-checked `pct`/`pos`/`classPos`/`pit`/`lap`/`last` values.
- Section 2: gap and interval hand-checked for 3 cars (within 0.01 s of the test's own computation).
- Section 3: battle appears after 5 ticks within 0.8 s, disappears when separated.
- Section 4: `/tv` answers 503 while driving.
- Section 5: `/tv` answers 404 without the test hook.
- Compile: `dash\build.ps1 -NoDeploy` exit 0.
- Deploy only when `irdeck-cli.exe state` shows sim=False; if exit 2, stop and report.
## User journey (what Peter does and sees; how he would fail it)
Peter presses TV on the deck (later card). The top screen shows the timing tower and the map with every car. He fails it if a car's position or gap is wrong at any moment, or if the tower freezes while the race runs. This card alone shows nothing on screen yet - it is the data behind T-02/T-03/T-04.
## Not in this card (what to leave for later cards)
The timing tower (T-02), the map (T-03), the director label and inputs bar (T-04), replay TV between stints (T-05), the deck key (K-02), the live check in a real race (T-07).
## Report (AGENTS.md format to docs\tasks\log\<ID>.md)
Write `docs\tasks\log\T-01.md` with the AGENTS.md report format, including the exact `CarIdx*` array names found in step 1 and which gap source (`F2Time` or computed from `pct`) was used.