# 16 - The Pi check (W4-6)

Written 2026-11-14 for PLAN section 6 ("one lap through Paddock and Pi Toolbox, delta, minimum speed and g-g compared and
written down") and evidence 06 section 4 (Paddock's numbers and Cosworth's come from the same .ibt samples; Paddock's maths on
top is its own and nobody checks it). Builder: W4-6. The numbers below are written by `tests\pi-check-test.ps1`; the words are
by hand.

## The lap
The 12 Nov 09:28 race, lap 9, 1:33.832 (iRacing's own time), Toyota GR86 at Road Atlanta. File:
`tests\fixtures\race-12nov-lap9-whole.ibt` (laps 8 to 11 of that race; git ignores `*.ibt`, so it sits in the live checkout
`C:\Users\peter\iRacingDeck\tests\fixtures\`). The reference for the delta is lap 10 (1:34.996), the other whole lap in the
file. The three metre marks are 1000 m, 2028 m (half way) and 3000 m. The four corners for Pi's minimum speed are T1, T5, T7 and
T10a (a fast one, a medium one, the slowest, and the heavy-braking one before the last complex).

## What was compared, and with what
Pi Toolbox cannot be run from a builder's session (it is a GUI app on the rig; nothing may be started while Peter may race).
So there are two comparisons:

1. **Done: Paddock against an independent read of the raw file.** Paddock's side is irdash's own engine run headless
   (`irdash.exe --analysis`, the code behind `/analysis/lap` and `/analysis/channels`, which W4-1 puts behind
   `/api/review/corners` and `/api/review/traces`): per-corner time, entry, minimum speed and where, exit, throttle pick-up,
   brake point, and the 1 m trace grid (time, speed, lateral and longitudinal acceleration). The raw side is
   `tests\fixtures\rawibt.cs`: its own header parse, its own lap cut from the lap-distance wrap, its own corner maths, plus a
   brake-press scan in the test. The corner windows and apexes are Paddock's (they are Paddock's definitions, not something the
   raw file contains). Numbers are in the first table.
2. **For the lead: Paddock against Pi Toolbox.** The steps and the table to fill in are at the end.

What this proves and does not: the raw reader and Paddock read the same samples, so agreement shows Paddock's lap cutting, 1 m
resampling, distance alignment and corner measures do not distort the file. It does not show that the corner windows or the apex
are "right" (Pi has no corners), and it does not replace Pi as an outside check of speed, g and delta.

## What matched
- Lap time: the raw reader's line-crossing time for lap 9 is 93.832 s and for lap 10 94.996 s, the same as iRacing's and
  Paddock's. Track length is 4056.9 m in the file header and in Paddock.
- All 14 corners, time, entry speed, exit speed, minimum speed, where the minimum is, throttle pick-up: within 0.02 s (the worst
  is T12, 0.013 s, explained below), 0.16 km/h (T2's minimum, the worst) and 1.0 m. One record at 60 Hz is about 0.7 m at 40 m/s.
- The three marks: time into the lap within 0.002 s, delta against lap 10 identical to the millisecond, speed within 0.1 km/h,
  lateral and longitudinal g within 0.01 g.

## What did not match, or needs care
1. **Brake point in linked corners (a real Paddock issue).** T7's brake point is reported at 1861 m, 266 m before the apex.
   That press belongs to T6 (it is still on at the start of T7's 250 m window); T7's own press starts at 2044 m, 83 m before the
   apex (speed drops to 83 km/h). A card on T7 would say "braked N m earlier" about the wrong press. The same happens, less
   badly, for T10b (the press that began 201 m before the apex is T10a's). The code already knows the case (analysis.cs, the
   comment about linked corners: the deep dive looks for a separate press after the previous apex). **Change for W4-1:** when the
   winning press began before the previous corner's apex and another press starts after it, use that second press for the
   card's brake point.
2. **The apex moves when the saved track map is missing (a trap, not a bug in the lap).** Run without `dash\maps\*roadatlanta*`,
   the engine puts several corners' apexes elsewhere (T12 moves from 0.9632 to 0.9795 of the lap, 66 m; its exit speed then reads
   183.5 km/h instead of 178.5; T6's exit reads 115.6 instead of 95.5). The test copies the real maps beside the engine for exactly
   that reason. **Change for W4-1:** keep a corner set's apex with the corner set (saved per track) so a missing map file cannot
   silently change a card's numbers, or refuse to build the review with a plain word.
3. **T12 ends at the line.** Its stored end is 0.0000 (the lap start). Paddock's time (3.349 s) runs to the line; a reader that
   clamps at the last record gives 3.336 s (0.013 s short, under one record). Paddock is right; no change, but anything new that
   reads `p1` must treat 0.0 as "1.0".
4. **Units.** The 1 m trace carries iRacing's own units: speed m/s, lateral and longitudinal acceleration m/s^2 (the file's
   description says "including gravity"). The marks below divide by 9.80665 to give g. W4-2's chart rows must say g, km/h or
   mph (Peter's iRacing is imperial: follow DisplayUnits), not show raw m/s^2.
5. **The old raw reader's "official time" is not usable.** `rawibt.cs` `Official` reads 94.136 s for lap 9 (that is lap 8's time:
   it looks at LapLastLapTime too early after the line). The test uses the crossing time instead. Only matters if someone reuses
   that field.

## Steps for the lead: the same lap in Pi Toolbox (only when `irdeck-cli.exe state` shows `sim=False`)
Pi is a GUI app: do this yourself at the PC, not from a builder. Do not copy the .ibt into iRacing's own folders (CLAUDE.md rule 2).
1. Check Pi Toolbox is installed (Paddock's OPEN IN PI button knows, `vault.cs Cosworth()`; the builder looked only in
   `C:\Program Files\Cosworth` and `C:\Program Files (x86)\Cosworth` and did not find it there).
2. Open Pi Toolbox and import `C:\Users\peter\iRacingDeck\tests\fixtures\race-12nov-lap9-whole.ibt` with Pi's own import (menu
   wording differs between versions: "Open outing" or "Import"). Pi's iRacing Lite template is fine.
3. Pick lap 9 (1:33.832) as the lap and lap 10 (1:34.996) as the reference (datum / comparison lap). Set the x axis to distance.
4. At 1000 m, 2028 m and 3000 m put the cursor on the line and write down: the time into the lap (lap 9); the delta against
   lap 10 (Pi's time-delta math channel; if the template has none, read the time at the same distance on each lap and subtract);
   speed (Pi may show mph: 1 mph = 1.60934 km/h); lateral g and longitudinal g. Note Pi's sign convention for each g (which way is
   positive) and say if it differs from Paddock's.
5. Minimum speed in T1, T5, T7, T10a: Pi has no corners, so read the lowest speed on the trace between the corner's start and end
   distance (Lovely windows: T1 199 m to 629 m, T5 1351 m to 1513 m, T7 2089 m to 2211 m, T10a 3347 m to 3513 m).
6. Fill the "Pi" and "Difference" columns of the second table. Expect: time 0.02 s, delta 0.03 s, speed 0.5 km/h, g 0.05 g. A bigger
   gap is a finding: write what you think causes it (Pi's lap cut, its smoothing, its distance basis). If Pi is not installed, say
   so here and leave the table empty: the raw-file comparison above stands on its own.
   (`pi-check-test.ps1` never overwrites the Pi columns once any are filled in.)

## Paddock against the raw file (written by the test)
<!-- PADDOCK-RAW:BEGIN -->
Run: 2026-11-14 15:00 by `tests\pi-check-test.ps1` (Paddock = irdash's own engine; Raw = `tests\fixtures\rawibt.cs` on the same file). Tolerances: time 0.02 s, speed 0.3 km/h, distance 2 m.

| Corner | Time s: Paddock | Raw | Min km/h: Paddock | Raw | Min at m: Paddock | Raw | Pick-up m: Paddock | Raw | Brake point m: Paddock | Raw |
|---|---|---|---|---|---|---|---|---|---|---|
| T1 | 8.972 | 8.972 | 156.42 | 156.38 | 431.8 | 431.6 | 432.8 | 433.1 | 317.8 | 317.2 |
| T2 | 3.604 | 3.604 | 132.77 | 132.93 | 790.9 | 790.7 | 713.0 | 712.0 | none | none |
| T3 | 2.000 | 2.000 | 119.58 | 119.54 | 826.2 | 826.0 | 855.6 | 855.3 | 748.6 | 748.2 |
| T4 | 3.622 | 3.622 | 127.55 | 127.63 | 868.2 | 868.5 | 940.2 | 939.5 | 749.2 | 748.2 |
| The Esses | 6.187 | 6.187 | 158.24 | 158.25 | 1,054.8 | 1,054.8 | 1,201.8 | 1,200.9 | none | none |
| T5 | 4.131 | 4.131 | 138.32 | 138.31 | 1,398.9 | 1,399.2 | 1,433.1 | 1,432.5 | 1,318.1 | 1,317.4 |
| T6 | 4.049 | 4.049 | 132.77 | 132.70 | 1,966.5 | 1,967.1 | 1,970.6 | 1,969.6 | 1,861.6 | 1,860.8 |
| T7 | 4.615 | 4.615 | 83.06 | 83.00 | 2,123.3 | 2,123.1 | 2,151.2 | 2,150.2 | 2,044.2 | 2,043.8 |
| T8 | 6.954 | 6.954 | 127.91 | 127.92 | 2,271.9 | 2,271.9 | 2,414.9 | 2,414.3 | none | none |
| T9 | 4.697 | 4.697 | 184.98 | 184.99 | 2,957.5 | 2,957.8 | 3,082.2 | 3,081.5 | none | none |
| T10a | 4.342 | 4.342 | 102.98 | 102.91 | 3,488.9 | 3,489.6 | 3,514.1 | 3,514.1 | 3,349.1 | 3,348.6 |
| T10b | 3.786 | 3.786 | 106.06 | 106.12 | 3,517.3 | 3,517.6 | 3,579.2 | 3,578.5 | 3,349.2 | 3,348.6 |
| T11 | 3.292 | 3.292 | 131.38 | 131.45 | 3,683.7 | 3,683.9 | 3,751.6 | 3,750.7 | none | none |
| T12 | 3.349 | 3.336 | 172.42 | 172.43 | 3,890.6 | 3,890.7 | 3,974.7 | 3,974.4 | none | none |

Worst gaps: time 0.013 s, speed 0.16 km/h, distance 1.0 m. The Raw brake-point column is the nearest press start (pedal through 10 %) the test itself finds in the raw records.

The brake point, wherever it is not a plain match:
- T7: rawibt.cs picks the press at 1,861 m, Paddock 2,044 m (rawibt weighs the whole press, Paddock the part inside the 250 m window)
- T10a: rawibt.cs says no brake, Paddock brake (rawibt skips a press still on at the apex)
- T10b: Paddock's brake point is 229 m before the apex: the press that began in the corner before (a linked corner), still on 250 m out; the raw records show 1 press start(s) in the window (3,349 m)

| Mark | Time into lap s: Paddock | Raw | Delta vs lap 10 s: Paddock | Raw | Speed km/h: Paddock | Raw | Lateral g: Paddock | Raw | Longitudinal g: Paddock | Raw |
|---|---|---|---|---|---|---|---|---|---|---|
| 1000 m | 22.074 | 22.074 | -0.490 | -0.490 | 151.0 | 151.0 | 1.10 | 1.10 | 0.14 | 0.14 |
| 2028 m | 45.381 | 45.383 | -0.609 | -0.609 | 133.7 | 133.7 | -1.31 | -1.32 | 0.17 | 0.17 |
| 3000 m | 69.671 | 69.672 | -0.749 | -0.749 | 186.4 | 186.4 | -0.28 | -0.28 | 0.07 | 0.07 |
<!-- PADDOCK-RAW:END -->

## Paddock against Pi Toolbox (the lead fills the Pi and Difference columns)
<!-- PI-FILL-IN:BEGIN -->
| What | Paddock | Pi | Difference |
|---|---|---|---|
| Time into the lap at 1000 m (s) | 22.074 | | |
| Delta at 1000 m, lap 9 minus lap 10 (s) | -0.490 | | |
| Speed at 1000 m (km/h) | 151.0 | | |
| Lateral g at 1000 m | 1.10 | | |
| Longitudinal g at 1000 m | 0.14 | | |
| Time into the lap at 2028 m (s) | 45.381 | | |
| Delta at 2028 m, lap 9 minus lap 10 (s) | -0.609 | | |
| Speed at 2028 m (km/h) | 133.7 | | |
| Lateral g at 2028 m | -1.31 | | |
| Longitudinal g at 2028 m | 0.17 | | |
| Time into the lap at 3000 m (s) | 69.671 | | |
| Delta at 3000 m, lap 9 minus lap 10 (s) | -0.749 | | |
| Speed at 3000 m (km/h) | 186.4 | | |
| Lateral g at 3000 m | -0.28 | | |
| Longitudinal g at 3000 m | 0.07 | | |
| Minimum speed in T1 (km/h) | 156.42 | | |
| Minimum speed in T5 (km/h) | 138.32 | | |
| Minimum speed in T7 (km/h) | 83.06 | | |
| Minimum speed in T10a (km/h) | 102.98 | | |
| Lap time (s) | 93.832 | | |
<!-- PI-FILL-IN:END -->
