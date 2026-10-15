# Paddock Review: prescriptive on top, all the data underneath

Peter: "lot of data and hard to interpret... I just need a better layout and insights." Not fewer channels: one band that says what to change, computed from the same traces, every number one press away.

## What engineers and fast sim drivers look at first
In this order (Pi Toolbox / MoTeC i2 workflow; VRS and Garage 61 coaches use the same):
1. **Delta-time vs a reference lap** on a distance axis. Sudden drop = braked too early or entered too slow; slow slide = scrubbing speed or a worse line.
2. **Speed overlay** at the drop: entry, **minimum corner speed** and where it sits, exit.
3. **Brake**: braking point (metres), peak pressure, release shape.
4. **Throttle pick-up point**: one clean ramp or a lift.
5. **Gear** at the apex.
6. **Time lost per corner / sector**, sorted. The top rows are the session's agenda.
7. **Consistency**: best vs optimal (best sectors joined), spread of clean laps.
Steering, G, tyres and suspension come after; they are setup-day channels.

## How the tools differ
- **Pi Toolbox, MoTeC i2**: raw, engineer-driven, any channel, any maths, no opinion. Powerful, slow to read.
- **Garage 61, VRS, Track Titan, Coach Dave Delta**: prescriptive. A reference lap (your best, a coach, the field), corners ranked by loss, words for what differs, often with the reference onboard. Raw data hidden or paid. [verify: tiers change often]
- **Paddock**: both. The top band tells, the data below shows, linked by corner.

## The Review layout
**Band 1, identity** (exists): car, track, type, best lap vs PB, optimal lap, clean laps, spread.

**Band 2, "3 things to fix"**, one row per corner, biggest loss first:
- Corner and **time lost** at 56 px: `T5 Canada Corner   -0.31 s`
- Measured difference, numbers only: `brake 18 m earlier than your best · 7 mph lower minimum speed · throttle 24 m later`
- One instruction, one verb: `Brake later and carry speed to the apex.`
- **WATCH**: recorder video cued 3 s before the corner, reference lap beside it when both exist. **SHOW ME**: the Workbench zoomed to that corner, delta / speed / brake / throttle / gear under one cursor.
Fewer corners pass the rules -> fewer rows, never padding. None -> `Not enough clean laps to compare (2 of 3)`.

**Band 3, the data**: the Workbench unchanged, plus a per-corner table (time lost, brake point, entry / min / exit speed, throttle-on, gear) sorted by loss. A click on any row moves cursor and zoom there: advice and evidence are the same object.

## What must be computed
Per lap, resampled to 1 m by LapDistPct x track length: delta vs reference, speed, brake, throttle, gear. Per corner (Lovely Track Data corner model): braking point (first brake > 10 % before the apex), peak brake, minimum speed and position, throttle-on (first > 90 % after the apex), apex gear, exit speed 100 m after the apex, time lost in the corner window. Per session: optimal lap from iRacing sectors, spread of clean laps, corners ranked by loss.

## Confidence rules (no advice unless all hold)
- Reference = his own best **clean** lap, same car, track and config, never the lap itself.
- Clean = no off-track, incident or pit in/out; lap length within 0.5 % of the median.
- At least 3 clean laps; corner loss >= 0.05 s **and** present in at least 2 slower clean laps (not a one-off).
- Each difference clears its noise floor: brake point >= 5 m, speed >= 3 mph, throttle-on >= 10 m; below it the metric is left out.
- The instruction comes from a fixed table keyed on the metrics (early brake + lower minimum -> "brake later, carry speed"; same brake, lower minimum -> "turn in later, release smoother"; late throttle only -> "pick up throttle earlier"). No generated prose; the copy audit applies.
- Unsure: 1 m resampling at Le Mans length; whether every session YAML carries iRacing's sector splits [verify on real .ibt first].
