# Drive v1: the in-car fourth screen ("eye-line pit wall")

Plan: Paddock-Claude-Build-Plan.md section 2.3 and PX-06. Mockup: `drive-v1.html?state=practice|race|pit|stale|norec`,
screenshots `drive-v1-<state>.png`, re-render with `shoot.ps1`. Implementation: `dash/www/v2/drive.js` + `drive.css`,
checks `tests/drive-v1-test.ps1` (offline, headless Chrome on the page as a file) and `tests/tv-test.ps1`.

## When it shows
In the car (live frame, `IsOnTrack`) the Drive layer covers the old five-panel grid. Garage or replay (sim live, not in
the car) shows the old grid, which keeps tyres, oil and wear ("garage state"). `?grid=1` keeps the old grid for old tests.
TV VIEW (deck key, `/tv`) swaps only the map slot for the broadcast camera; band and tower stay.

## Canvas
1920 x 1080, margins 64 (the in-car screen gives the map the width HOME spends on margins). HOME v3 tokens and type
scale: glance 56, read 30, body 26, label 20 uppercase tracking .24em muted. Nothing under 20 px.

| Area | Box | Content |
|---|---|---|
| Top line | 64..1856, y 28, 36 tall | session type (20 label, ink), track and config (26 muted), stale age (amber), clock `8:21 PM ET` |
| Map | 64, 96, 1108 x 620 | complete outline, corners as 20 px text on the outside of the bend, class-coloured dots, the 3 ahead and 3 behind on track numbered in dark chips, Peter gold dot + ring, credit line 20 px dim |
| Tower | 1220, 96, 636 wide | head row 36: `BATTLE · GT3` / `GAP`; 7 rows x 76 px centred on Peter (clamped at the ends); race: own class in multiclass, unsigned gap in seconds; practice: `BEST LAPS`, best lap time |
| Hairline | y 752 | |
| Band | 64, 784, five cells | POSITION · GAP AHEAD · DELTA (centred 544 wide) · TIME/LAPS LEFT · FUEL |
| Footer | y 1000, 48 tall | `Last 1:25.100 · Best 1:24.902`, REC pill right |

## Cells
- Position: race single class `P5` / `of 23`; multiclass label `CLASS POSITION`, `P5 GT3`, sub `P16 overall · 23 cars`; practice `P4` / `of 18 · best lap`.
- Gap ahead (race): seconds to the car one place ahead in class from F2 times, sub `#8 · closing 0.3 a lap` (green), `losing 0.2 a lap`, `steady`; first lap of data: `#8 · Patel`. Leading: `GAP BEHIND`, sub `leading`. Practice: `BEST LAP` + `+0.591 to fastest` / `fastest here`.
- Delta: iRacing `LapDeltaToBestLap` only when `_OK` and the lap is clean (not out lap, not pit, not off). Faster green, slower ink; bar +-1 s from the centre. Otherwise `—` and the reason (`out lap · no delta`, `off track · no delta`, `no best lap yet`).
- Pit lane (on pit road): the delta cell becomes `PIT LANE`, speed in iRacing's units, bar = speed / limit, sub `limit 45 mph · limiter on` (`limiter off` amber).
- Left: race by laps `12` / `lap 9 of 20`; timed `18:42` / `lap 9`; unknown `—`.
- Fuel: laps of fuel from the clean-lap average; race sub `+1.7 gal to finish` (amber) or `enough to finish`; practice `3.1 gal · 0.33 a lap`; no clean lap yet `—` / `after one clean lap`.
- REC pill: `/vault/recorder` `capture` verdict (same words as tv.js): `REC 41:12` red dot; `REC STARTING`, `REC PAUSED: DISK FULL` amber; `NOT RECORDING` red text; unreachable `RECORDING UNKNOWN` amber.

## Colour
Gold: Peter only (map dot, tower row). Green: faster delta, closing trend. Amber: stale age, fuel short, limiter off, REC warnings. Red: REC failure only. Unknown: `—`, never 0.
Stale (no frame for 2 s or more): every value and Peter's gold turn dim grey, top line shows `NO DATA FOR 9 S` in amber.

## Cost
No network on the render path: the band and tower are built from the frames already in the page (`L`, `S`,
`computeStandings`) at 4 Hz; the map copies one cached outline layer and draws dots at no more than 30 fps; the recorder
poll stays every 2 s. Units come from iRacing's `DisplayUnits` (`Units.metric`).
