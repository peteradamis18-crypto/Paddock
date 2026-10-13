# Paddock Analysis Workbench - the "Pi Toolbox Pro, but better" spec (lead, 2026-10-11)

Peter: "take heavy inspiration from Cosworth Pi Toolbox Pro and build it, even better than their product - that is the
standard. Use the best model for the value. Huge bar." This spec replaces sections 3-4 of DESIGN-analysis.md for the
analysis screens. The rules of DESIGN-analysis.md section 2 (distance axis, fixed colours, data notes only when clear, no
dead buttons, readable from the seat) still apply.

**Sources (read before building):** docs\research\pi-toolbox-features.md (Pi Toolbox 14's own help files + Cosworth's
iRacing workbooks, authoritative), pi-toolbox-web.md (tiers, iRacing templates), competitors-*.md, user-wishlist.md,
ibt-channels.md (288 channels at 60 Hz in Peter's files). Mockups from real data: docs\mockups\workbench.html
(?page=driver, ?page=grip) -> workbench-driver.png, workbench-grip.png.

## 1. What Pi Toolbox is (the bar)
Workbook -> worksheets (pages) -> displays; tasks hold outings (sessions); one shared task cursor across all displays;
linked zoom; overlay or tile; datum (reference) outing; time offset to line laps up; navigator playback 0.5-8x; events
display that moves the cursor; maths channels (equations, registers, lookup tables, filters); soft events; split report
(laps x sectors, theoretical best, rolling best); tabular outing report (telltales per lap); histogram; X/Y with polynomial
fit and a colour channel; GPS / standard maps with colour bands; media (video) with offset sync (paid tiers); Excel export.
Cosworth's iRacing Plus workbook: Driver, Tyre Data, Grip Data, Throttle/Brake Analysis, Splits/Web/Setup, Damper
Displacement, Damper Velocity, Roll/Pitch/Ride Height/Aero, Gears/Differential, Tyre/Fuel Usage/Pit Lane - ~150 derived
channels (wheel slip, understeer angle, slip angles, balance flags, coast, brake on/off, aero balance, bump stop, damper
velocity, G total, curvature, yaw gain, grip factors).

## 2. Where Paddock beats it (each must be true when shipped)
1. **Zero setup:** every session is already loaded and analysed; the reference (your best, never itself) is chosen; the
   page opens on the top screen by itself after a session. Pi needs tasks, outings, workbooks, channel picking.
2. **Video of his own laps** in sync with every display (Pi: paid tiers, manual offset).
3. **Stream Deck control:** pages, laps, corners, events, play/pause, zoom, reference - one press each, no mouse.
4. **History across sessions:** each corner's time and metrics over weeks; PB evolution; not one outing at a time.
5. **Race field:** Paddock's own live log of every car's position -> per-corner comparison with the leader / car ahead.
6. **Events you can jump to,** including iRacing's replay of that moment while the tape is loaded.
7. **Data notes only when the data is unambiguous** (facts with numbers, never coaching guesses).
8. **Beautiful and readable from the seat;** Pi is dense and "pretty complicated to get going" (user quotes).
9. **Everything Pi charges for, free and local:** ghost/reference laps, histograms, stints, video, balance, Excel/CSV export.
10. **Plain-English channel names** with units, and the formulas shown on request (Pi hides them in workbooks).

## 3. Pages (worksheets) - presets, no configuration
| Page | Displays |
|---|---|
| DRIVER | map coloured by gap + events; readouts at the cursor (lap / reference / difference); traces on distance: gap, speed, throttle, brake + ABS shading, steering, wheel force, gear (+RPM); pedal-use bars; events list |
| GRIP & BALANCE | g-g skidpad (both laps, 1/2/3 g rings); corner table (gap, min speed, peak lateral g, peak slip angle, ABS metres); slip-angle trace; wheel slip per wheel (lock-up / rear-slip bands); time in each gear; balance: understeer angle and yaw gain (car constants per car, see 5.3) |
| BRAKING | per corner: brake point, peak pressure, time to peak, release (trail) length while steering, ABS share, lock-ups; brake trace zoomed per corner (both laps); coast time |
| TYRES & STINT | surface (L/M/R) and carcass temps per tyre over the stint, pressures, wear at stint end; lap times over the stint; fuel per lap; brake-bias / TC / ABS setting changes with lap times before / after |
| SUSPENSION | ride heights, rake, damper displacement and velocity (histograms per corner of the car), bump-stop hits |
| SPLITS | laps x sectors (iRacing's sectors) purple / green / yellow; theoretical best; rolling best; lap x corner heat map (consistency); best-5 average and spread |
| RACE | final timing tower, race trace (gap to leader over laps), positions, per-corner vs leader / car ahead, incidents, overtakes with replay jump |
| CAREER | one car + track over every session: PB by session, every clean lap with the best-5 average and spread, corner x session grid (best / median), early against recent per corner, theoretical best vs PB, races, totals |
| VIDEO | his clip with the trace cursor; two-up with the reference when both have video |

## 4. Interaction model (the core engine)
- One **cursor** shared by every display on the page and across pages; one **zoom** range (linked); overlay of lap +
  reference by default; tile/overlay toggle; reference cursor (differences from a fixed point); time-offset slide to line
  laps up at an event (auto-aligned at the braking point of the corner in view).
- **Playback** (navigator): play / pause at 0.5, 1, 2, 4x; the map dot, every trace and the video move together.
- **Keyboard and mouse** like Pi (D distance/time, T tile/overlay, Z zoom at cursor, Backspace zoom out, R reference cursor,
  O offset), and the **Stream Deck ANALYSIS screen** (deck-v2.png) for everything one press.
- Any channel of the 288 can be added to a trace row from a searchable list (initials search like Pi: "LG" = Lateral G).
- Rendering: canvas, decimated by zoom level, 60 fps cursor movement on the top screen with 20+ traces x 2 laps; never
  slows the sim (the page only runs heavy work when the sim is not on track).

## 5. Data and maths (server side, dash\src\analysis.cs)
1. **Lap store:** any channel of any lap of any session as Float32 arrays, aligned by distance (1 m) and by time, official
   lap time pinned (first sample is up to 1/60 s after the line - the mockup measured 1:19.523 for a 1:19.549 lap).
2. **Derived channel library** (Cosworth formulas where the workbook states them): G total, wheel slip per wheel, chassis
   slip angle (atan VelocityY/VelocityX), yaw gain, understeer angle (needs steering ratio + wheelbase per car), pedal state
   (Cosworth Lite: coast / part throttle / >98 % / part brake / >65 %), coast time, brake on/off points, damper velocity,
   bump-stop flags, corner state, tyre averages, fuel per lap. Each has a test on a real lap with a hand-checked value.
3. **Car constants** per car (steering ratio, wheelbase) - a small table; channels that need them are hidden for cars
   without values (never guessed).
4. **Events:** ABS zones (pulses < 30 m apart merged), lock-ups (a wheel 8 % slower under braking), rear slip (> 8 % on
   throttle, labelled as traction-control range), off-track (PlayerTrackSurface), incidents (PlayerCarMyIncidentCount),
   pit, PB laps, position changes / overtakes (race log). **No "slide" events** - a GT3 runs 3-5 deg slip in normal
   corners, so a threshold would invent incidents (lead review of the mockup).
5. **Expression channels** (Pro feature, later): Pi-Math-like equations over channels, saved per car.

## 6. Build plan and who builds what (best value)
| Step | What | Builder | Why |
|---|---|---|---|
| W0 | Lap store + derived library + events (extends C-30/C-34) | Grok (grok-4.7) | well specified, testable on real files |
| W1 | **Workbench core engine** in dash\www\v2: page/display framework, shared cursor, linked zoom, overlay/tile, offset, playback, channel picker, canvas trace renderer at 60 fps, deck/keyboard control | **Claude Fable** (one job) | hardest part; quality and speed of rendering decide whether it feels pro; estimated 10-30 USD |
| W2 | Displays: map (colour by gap / speed / any channel), readouts, events list, split report, lap x corner heat map | Grok | on top of the engine |
| W3 | Displays: X/Y with fit + colour channel, histogram, g-g, bars | Grok | X/Y + histogram done 2026-10-11 (P3: `workbench-pro.js`, the PRO tab; `docs\tasks\log\P3-pro.md`); g-g and bars were already on GRIP |
| W4 | Preset pages (section 3) | Grok | |
| W5 | Video display + recorder hook (C-06) | Grok | done 2026-10-11 (agent; `docs\tasks\log\W5-video.md`): VIDEO tab, two-up, small video (V), exact sync both ways |
| W6 | RACE page + all-cars live log; CAREER / history | Grok | done 2026-10-11 (agent; `docs\tasks\log\W6-race.md`, `docs\vault.md` "The race log"): the log (`field.cs`), `/analysis/race`, the RACE tab. CAREER / history done 2026-10-11 (agent W6c; `docs\tasks\log\W6c-career.md`, `docs\vault.md` "The career"): the CAREER tab |
| W7 | Expression channels, CSV/Excel export, SHARE (C-38) | Grok | expression (maths) channels + CSV / .xlsx export done 2026-10-11 (P3: `dash\src\protools.cs`, `/analysis/pro/*`); SHARE (C-38) is P2 |
The lead (Opus) writes each card with its checks first, makes the mockup from real data, and compares every screenshot
with the mockup before a card counts as done. Haiku does research. Fable only for W1 unless a later step fails twice.

## 7. Acceptance (the whole workbench)
- Opens after a session with his lap vs his best in under 1 s; every number matches iRacing (lap times to the 1/1000).
- Cursor and zoom stay in sync on all displays and the video; 60 fps on the top screen with 20 traces.
- Every derived channel has a hand-checked test value on a real lap; no event type without a test that shows it is real.
- One-press deck control for every action in section 4; no mouse needed.
- Side by side with Pi Toolbox Lite on the same .ibt: every Lite display has an equal or better Paddock page.
