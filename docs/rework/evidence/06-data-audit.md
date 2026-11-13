# 06 - Data audit: is what Paddock shows what Cosworth shows?

Read-only audit, 2026-11-12. Evidence from `dash\src`, `dash\www\v2`, `docs\cosworth.md`, `docs\cosworth-addin-findings.md`. I read headers, comments and the key calculations. I did not run the pages or open real .ibt files.

## Short answer for Peter

1. **Not made up, but not Cosworth either.** The raw numbers (speed, throttle, brake, steering, g, wheel speeds, GPS, gear, RPM, lap times, sectors) are read straight from iRacing's own .ibt telemetry file. Cosworth Pi Toolbox reads the same file. So a speed trace in Paddock and a speed trace in Pi come from the same samples. Paddock does its own maths on top: lining laps up by distance, finding corners, the coach advice, the "most to gain" figure, the benchmark. None of those come from Cosworth, and Cosworth does not check them.
2. **Paddock never gets anything back from Cosworth.** It opens Pi and drops the .ibt file in. That is all (section below).
3. **Best way to show it?** For the detailed traces (workbench, vault trace panel, sessions lap analysis): yes, these are standard engineering views. For the summary layers (coach, benchmark, "best lap over time", "most to gain"): they are reasonable but built on thresholds I would call judgment calls, and several overlap. Details below.

## Table of views

"Standard" means a view a motorsport data engineer would recognise (Pi Toolbox, MoTeC i2, Atlas, VBOX). "Own" means Paddock-built logic. Keep / cut / fix is my recommendation for the rework.

| View | Page | Source (channels / data) | Standard or invented | Rec. |
|---|---|---|---|---|
| Speed, throttle, brake traces on one cursor, two laps | `workbench.js` DRIVER page; `vault.js` detail; `sessions.js` lap analysis | `Speed`, `Throttle`, `Brake`, resampled to a 1 m distance grid (`LapDistPct` x track length) | Standard (speed/pedal overlay) | Keep. Three pages draw the same thing: pick one home |
| Time difference (delta-T) | same three | Time at each metre on both laps, pinned to iRacing's official lap time | Standard (delta-T by distance) | Keep |
| Steering, gear, RPM, ABS active | workbench DRIVER; `rawdata.js` | `SteeringWheelAngle`, `Gear`, `RPM`, `BrakeABSactive` | Standard | Keep |
| Grip and balance: g-g plot, lateral g | workbench GRIP & BALANCE | `LatAccel`, `LongAccel` (g = value / 9.81); G total = sqrt(lat^2 + long^2) | Standard (g-g / traction circle) | Keep |
| Chassis slip angle (beta) | workbench GRIP | `atan(VelocityY / VelocityX)` | Standard derived channel | Keep |
| Wheel slip per corner | workbench GRIP/BRAKING | Wheel speed vs car speed, above 8 m/s | Standard-style, own threshold | Keep |
| Understeer/oversteer "car balance" | workbench GRIP via `deepdive.cs` | Steering needed for a 100 m radius, steering per g, yaw gain. Cosworth-style understeer angle only if wheelbase and steering ratio known | Partly standard. The steering-ratio-based number is hidden because the ratio is unknown (a fit gave 26 to 47 for one car) | Fix: keep what is measured, label the rest "relative to reference lap" |
| Lock-up / wheelspin events | BRAKING page (`deepdive.cs`) | Wheel 8 % slower than car with brake > 10 %; rear 8 % faster on throttle; min 0.05 s | Standard idea, 8 % and 10 % are chosen thresholds | Keep, state the thresholds |
| ABS share of braking | BRAKING | `BrakeABSactive`, `BrakeABScutPct` | Standard | Keep |
| Braking profile (peak, rise time, release, trail, coast) | BRAKING | `Brake`, `SteeringWheelAngle`, `Throttle` | Standard in spirit; "trail = release with 5 degrees of wheel" is own | Keep |
| Wheel force clipping | BRAKING / DRIVER | `SteeringWheelPctTorque` >= 0.98 | Own, but useful for a Simucube driver | Keep |
| Racing line offset | BRAKING/map | `Lat`/`Lon` (GPS), offset to reference line | Standard (line overlay) | Keep |
| Tyres and stint, setting changes | TYRES & STINT | Tyre surface/carcass temps and pressures from the .ibt; `dcBrakeBias`, `dcTractionControl`, `dcABS` | Standard. Peter asked for tyre panel to be removed from live; this is recorded data only | Keep, hidden by default |
| Suspension (ride height, damper position and speed) | SUSPENSION | `*rideHeight`, `*shockDefl`, `*shockVel` | Standard | Keep, advanced |
| Histogram, X/Y scatter, maths channels, xlsx/CSV export | `workbench-pro.js` | Any channel | Standard (these are Pi/MoTeC features); curve fit with R2 | Keep, advanced |
| Sectors and corners table with purple/green/yellow | workbench SPLITS; `sessionreview.js` | iRacing's own sectors (`SplitTimeInfo`), 24 equal mini-sectors, corner model | Standard colours. Corner times are own (corner list from Lovely Track Data or detected from yaw rate) | Keep |
| Rolling best | workbench SPLITS | 24 mini-sectors joined across two laps, "Cosworth's fastest rolling lap" | Copied idea, own mini-sector cut | Fix: it is made from 24 equal slices, not Cosworth's method; rename or explain |
| Corner table: brake point, entry, minimum, throttle-on, exit speed, time | `sessions.js`, `vault.js`, workbench | Same grid; "brake point" = brake over 10 %, "throttle-on" = throttle through 90 % | Standard measures, own definitions | Keep, show definitions |
| Cause sentence per corner | `sessions.js`, review "notes" | Fixed rule in `analysis.cs`: time differs 0.05 s AND exactly one metric differs (5 m brake, 3 km/h, 10 m throttle) and moved the right way | Invented rule. Honest (no sentence when unsure) but thresholds are arbitrary | Fix: show the numbers first, sentence second |
| Timing table of a session | `sessionreview.js` | `LapLastLapTime`, iRacing sectors; valid = counted by iRacing AND no off-track | Standard timing screen | Keep |
| Optimal lap | `sessionreview.js`, `sessions.js` | Best iRacing sectors joined, only from clean laps | Standard "theoretical best" | Keep. Only 3 to 4 sectors, so it is coarse |
| Consistency | `sessionreview.js`, `sessions.js` | Average of best 5 laps and standard deviation | Common engineering stat, but not a Cosworth view | Keep, small |
| Coach: "what to fix next" | `coach.js`, `coach.cs` | Each corner vs the SAME session's best clean lap; advice if median loss >= 0.05 s in at least half the laps and >= 3 clean laps; instruction from a fixed table | Invented layer. Not Cosworth. Honest about sample size | Fix: see findings 3 and 5 |
| Debrief v4: race result, position by lap, pace vs field | `debrief-v4.js`, `debrief.cs` | Paddock's own race log (`field.cs`, every car's lap crossings) | Standard race data. iRating change uses "the community formula", an estimate | Keep; label iRating as estimate |
| Debrief v4: three costliest corners with video | same | Corner times vs his best lap + recorder clips | Own ranking, real clips | Keep |
| Practice pace story | `debrief.cs` | Median counted lap vs PB and optimal | Own | Keep, small |
| Race workbench: timing tower, gap trace, position by lap, corner-by-corner vs car ahead, passes | `workbench-race.js` | `field.cs` log of every car; corner time = median of clean laps | Standard race analysis. "Which corner" for a pass is inferred | Keep |
| Career: PB evolution, consistency, corner heatmap, theoretical, totals | `workbench-career.js`, `career.cs` | All .ibt files for the car, track, layout | Not in Pi (Pi holds one outing). Own, factual | Keep |
| MOST TO GAIN | Stream Deck RACE SETUP, `gain.cs` | PB minus best iRacing sectors ever, joined; gaps under 10 ms ignored | Own. Sectors from different days, setups, fuel loads are joined | Fix: show it with the dates |
| Benchmark card: PB vs yardsticks | `bench.js`, `bench.cs` on sessions and (compact) debrief | `data\pro-refs.json` (real IMSA timing sheets, hand-copied with URL); other drivers' best laps from session results (`fieldlaps.tsv`, hidden under 30 drivers); "drivers within 250 iRating" | Own. Yardsticks are not like-for-like (see findings) | Fix or cut the pro line; keep the field line with its mix stated |
| "Best lap over time" | `bench.js` `history()` | Running personal best per session date | Invented chart. See findings | Cut or replace |
| Sessions list, short runs, short tags | `sessions.js` | Career cache from .ibt files | Own bookkeeping | Keep |
| ALL THE DATA over time | `rawdata.js`, `rawdata.cs` | Every channel against time, laps as blocks, GPS dot; works for a drive with no full lap | Standard time-based trace | Keep. Its a good fallback for partial laps |
| Vault (laps, races, clips worth keeping) | `vault.js`, `vault.cs` | Same lap engine on kept copies, plus video locked to the telemetry clock | Standard (video sync) | Keep |
| Corner map and names | `corners.js`, `corners.cs` | Lovely Track Data (CC BY-NC-SA) names, else corners detected from his own yaw rate, else outline | Own detection for tracks Lovely lacks | Fix: mark detected corners as detected |
| Live: Drive (battle tower, gap trend, delta) | `drive.js` | Live telemetry frames. Gap trend per lap computed from the last lap's samples | Standard live overlay; the trend is own | Keep, not part of debrief |
| HOME (PB per track, last outing, this week) | `home.js`, `home.cs` | Career cache | Summary, not analysis | Keep |
| Performance (frame rates, "did it help?") | `perf.js`, `perf.cs` | fps and CPU/GPU per session | Not driving data. Verdict ("gpu"/"cpu"/"held") from thresholds ported from a script; "helped/hurt" needs 3 like-for-like sessions each side | Keep separate; do not mix into driver debriefs |

## Cosworth: what Paddock really does

- **Launches only.** Button OPEN IN COSWORTH (debrief, Session Review, vault, workbench, Stream Deck ANALYSIS). Code: `vault.cs StartCosworth`.
- **Method:** copies Pi's iRacing Lite template to `cosworth\Paddock.pwb` once, starts `Pi Toolbox.exe` with that workbook, waits until the window title starts "Paddock - Pi Toolbox", then starts Pi again with the .ibt path so Pi's own pipe imports the file as an outing.
- **Channels passed:** none chosen. Paddock hands over the whole .ibt file. Pi decides what to read. Paddock does not export a Pi file, does not write a Pi workbook, and does not import anything back.
- **Not possible:** the Pi workbook is binary OLE2 and undocumented, so Paddock cannot pre-set displays or make the best lap the reference (datum). The tool `tools\cosworth-workbook.ps1` reports NOT SUPPORTED. Pi Lite has no automation, and nothing records which outing is loaded. The only success signal is the window title changing (a trailing `*`).
- **What the user sees:** the button says "OPENING IN PI". It does not name the lap, and it opens the whole file, not the lap on screen. So after the click he sees Pi's stock iRacing Lite layout, not the lap he was reviewing. This is a mismatch with the button's promise.
- **Does any view claim to mirror Cosworth?** Not on screen. In code comments only:
  - `workbench-pro.js`: "what Cosworth's Pi Toolbox charges for, free and local" (histogram, X/Y fit, maths channels, export). These are equivalents, not copies.
  - `workbench.js`: "Cosworth's formulas where the workbook states them" (derived channels); the pedal-state channel follows "Cosworth Lite pedal state"; "rolling best" is named after a Pi feature.
  - `deepdive.cs`: "Cosworth's gate" for car balance (lat g > 0.3, speed > 30 km/h, yaw > 0.02) and "Cosworth's understeer angle".
  The headline: the formulas are borrowed from Pi's own workbook and help text, so the results should agree in kind, but nobody has ever put the same lap through both and compared the numbers. There is no such test in the repo.
- Version mismatch to tidy: `docs\cosworth.md` says Pi 14.0.2752.2, the findings file says exe 5.193 (product 14.0). Same install, two names.

## Findings

### Invented or misleading

1. **"Best lap over time"** (`bench.js history()`). It is a stepped line of his running personal best, one step per session, with only the first and last date and time as labels. Because it is a running best it can only go down. It cannot show a bad day, and a flat line looks like "stuck". It tells the driver "you have got faster since Oct", which he knows from the PB. It ignores car updates, setups, fuel load and grip, so a drop can be a track-state or season change. It tells him nothing about what to do. Recommend cutting it, or replacing it with the Career page's per-session best/average-of-5 chart, which at least shows consistency.
2. **Benchmark yardsticks are not like-for-like.**
   - "Pro" times are IMSA qualifying laps on real cars (hand copied from timing sheets with a link). The note says "a guide only", but a gap of "+3 s, 96.5 %" implies a meaningful distance.
   - "Top 5 % / 25 % / middle of drivers raced" are the best laps of every driver in sessions Peter's PC logged. Those mix Practice, Race, and Lone Qualify (in `fieldlaps.tsv`: 325 practice, 140 race, 75 qualify rows), different fuel, tyre wear, tow and setups. Percentile of "drivers who were in my sessions" is not percentile of iRacing. It is hidden under 30 drivers, which is the right guard.
   - "Pace %" (PB / yardstick x 100) is a ratio of lap times, which a driver reads as a rating. It is neither.
3. **Coach compares him with his own best lap of the same session.** If his best lap had a mistake or a lucky tow, the reference is wrong. A "habit" needs 3+ laps and a repeated 0.05 s loss: reasonable, but 0.05 s, 5 m, 3 mph, 10 m are chosen, not derived. Fewer than 3 laps falls back to "hints" (the code says so). This is honest, but a coach with no ground truth for "right" lines.
4. **Cause sentences** (`analysis.cs`) use "exactly one metric differs" thresholds (5 m, 3 km/h, 10 m). When it stays silent, that is right; when it speaks, the cause is a correlation, not a measured cause.
5. **MOST TO GAIN and THEORETICAL best** join best iRacing sectors from different sessions. A sector lap can come from a different setup, fuel load or grip level. The gap is real arithmetic but presented as "the time on the table". It is only valid when sectors were driven in similar conditions. (Mitigation in code: only laps with no off-track record are joined.)
6. **iRating change** in the debrief uses "the community formula" (`data.cs Race.Change`), an estimate, not iRacing's number.
7. **Corners detected from his own yaw** (where Lovely has no list) appear next to official names with equal weight on the same T1..Tn numbers, even though the boundaries are inferred.

### Duplicated across pages

- Speed / throttle / brake / delta plus a corner table appears in `sessions.js`, `vault.js` and `workbench.js`. Three drawing implementations, one lap engine. The workbench is the superset; the other two are older.
- Optimal lap, consistency, best 5: Session Review, Sessions page, Career, and the Stream Deck MOST TO GAIN each show a version.
- Three entry screens after a session: Debrief v4 (automatic), Session Review (`DEEP DIVE` target), Coach. Each ranks the "worst corners" in its own way (cost vs best lap; repeated loss; notes).
- `debrief.js` and `debrief-v4.js` both exist; the old one remains for a demo and a hand-off.
- Corner model and names are in `corners.cs` and also built per session in analysis; mostly consistent but two sources.

### Computed from too little data

- Coach with fewer than 3 clean laps: hints only (flagged). Cause notes from one lap pair.
- Corner "typical" values use medians of the clean laps of ONE session; an hour session may have 8 clean laps.
- Benchmark field: under 30 drivers the field bars hide (OK), but with 30-ish drivers from 1-3 sessions the percentile is thin.
- "Did it help?" on the performance page waits for 3 sessions each side: good.
- Understeer/oversteer flags need wheelbase and steering ratio; ratio unknown, so hidden. Good.

### Available telemetry that coaches value but Paddock does not surface by default

| Channel | Why a coach wants it | Status |
|---|---|---|
| `LFbrakeLinePress` etc. (brake line pressure, bar) | Peak pressure and modulation; real pedal feel | In the 288-channel picker only. Not in `CHANS` list loaded by default, not in the braking profile. Braking profile uses pedal `Brake` instead |
| `BrakeRaw` (raw pedal) | Separates driver input from ABS/assist | Not used. `Brake` is used |
| Steering angle | Steering smoothness, corrections, turn-in point | Plotted; only used for "trail" and turn-in. No "steering corrections count" or smoothness |
| Minimum corner speed | The core coaching number | Computed (corner table). Is shown. |
| Lateral g peak per corner | Grip used | In deep dive, not on the main table |
| Tyre temps, wear, pressure per stint | Setup and tyre management | In deep dive TYRES page (recorded, not live). Peter asked not to show tyres; hidden |
| `LapDeltaToBestLap` and optimal/session variants (iRacing's own live delta) | Cross-check of Paddock's delta | Not used: Paddock computes its own from distance |
| `TrackTempCrew`, `AirTemp`, `WindVel`, `WindDir`, `Skies`, `TrackWetness` | Conditions for fair comparison | Read in `analysis.cs` but not used to qualify any comparison (benchmark, theoretical, coach) |
| Fuel level / burn | Weight effect on pace | In deep dive, not used to correct lap times |
| `dcBrakeBias` etc. | Setting changes | Shown (setting changes) |
| ERS / hybrid and `PushToPass` | GTP and hybrid cars | Not used |
| Engine `OilTemp`, `WaterTemp` | Reliability | Not used |

Biggest gaps for a coach: brake line pressure, conditions-aware comparison, steering-smoothness, a rolling per-corner trend across sessions.

## What to do in the rework (for the next phase)

1. Make one trace-and-corner page and retire the two older copies.
2. Cut "best lap over time"; keep the per-session best/average-of-5 chart.
3. Keep pro and field yardsticks only with a plain "not like for like" line, or drop them.
4. Run one lap through Pi and Paddock and write down whether delta, minimum speed and g-g agree.
5. Make OPEN IN COSWORTH honest: say "opens the whole file in Pi's standard layout".
6. Show conditions (track temp, fuel, setup change) beside any comparison across sessions.
