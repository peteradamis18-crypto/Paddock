# Paddock data, video and Cosworth - the design, version 2 (lead, 2026-10-10 20:40)

**What Peter asked for (his words, 2026-10-10 evening):** "Cosworth doesn't work and I don't see video recording. Best lap
and random bar charts are not how car racing software should look." "The yardstick sucks, next goal and other drivers not
thought out." "I think the insights will be underwhelming. I just want a lot of data... only provide insights if natural
and reliable and data driven, not just your imagination. Make it like other racing software but beautiful, intuitive,
allows us to dive deeper and see visuals like cars, teams." "Don't spend a fortune, but an amazing product."

**Built on research, not assumptions:** four sourced reports in `docs\research\` (sim coaching tools, professional
engineering tools, broadcast/live timing, iRacing ecosystem). Every builder reads the relevant report before a card.

Tags: **[fact]** checked on this PC or in a cited source, **[verify]** check before building on it.

---

## 0. What went wrong (so it does not happen again)
- Screens were designed as piles of numbers and built card by card; "done" meant "the test passes", not "it looks and
  works like real racing software". Example: the debrief showed a giant best lap and a one-bar chart; the benchmark card's
  "yardsticks / next goal / other drivers" were abstract rankings; OPEN IN COSWORTH and CLIP were dead buttons.
- Fix: this design, mockups from real data that Peter approves before building, and the lead checking screenshots
  against the mockups (section 9).

## 1. What the research says (the short version)
- **Engineers' workflow** [fact, research 2]: pick a reference lap -> read the **delta first** (sudden drop = braked too
  early / too slow; gradual = scrubbing or line) -> look at the inputs at that spot (brake point and release, entry /
  minimum / exit speed, throttle on exit, steering) -> trace shapes -> consistency (best lap vs ideal lap).
- **Metrics they trust:** delta vs reference, entry/min/exit speed, braking point and deceleration, throttle application,
  consistency (best vs ideal). **They distrust automatic advice** - no vendor publishes evidence that its AI tips are
  reliable (research 1 and 2). -> Paddock shows **data notes (facts), not coaching**.
- **Presentation that works** [fact, research 1-3]: everything on a **distance axis**; delta on top, speed, throttle,
  brake, steering, gear stacked under one cursor; a **track map coloured by time gained/lost** (or by speed with a colour
  bar); a per-corner table sorted by time lost; click a corner -> zoom; reference laps dotted, yours solid; video synced
  to the cursor (Coach Dave, Track Titan, VRS top tier).
- **Timing colour language** [fact, research 3]: **purple = best overall, green = personal best, yellow = slower**, on lap
  times and mini-sectors, learnt once and used everywhere (F1 apps, MultiViewer, FastF1). Restraint is premium (F1
  removed animations "to reduce visual clutter"); tabular numbers.
- **Cars and teams as visuals** [fact, research 3-4]: broadcasts use car numbers in livery colours, team colours and
  logos; WEC 2025 matches car-number artwork to each real livery. iRacing's Data API is closed to new apps (OAuth client
  IDs paused, password access ended 9 Dec 2025) and there is no public car-render source -> Paddock uses **his own
  pictures**: stills from his recorder and Studio, screenshots of his car, his number and team name as typed text.
- **Cosworth** [fact, research 2]: Pi Toolbox **Lite is free**, opens .ibt natively, needs a members.cosworth.com account
  to download. **Video sync is Plus (paid) and above** - Lite cannot show video. Command-line opening is not documented
  [verify]. -> Paddock's own Lap Analysis (with video) is the main tool; Cosworth Lite is the "open in the pro tool" option.

## 2. Rules for every data screen (builders follow; the lead checks screenshots against them)
1. **Lead with the data a driver checks first** (lap times, delta), then let him dive deeper. Every number has a reference
   and a unit ("141 km/h (best 146)").
2. **Distance on the x-axis** for traces; laps aligned by track position (careful alignment: per-lap distance drift
   distorts deltas - research 2).
3. **Colours, fixed everywhere:** his lap = gold solid; reference = cool white, dotted; time gained = green, lost = red;
   timing cells: purple = his best ever, green = best of this session, yellow = slower; grey = out/in/invalid laps.
   Never use red for anything neutral (F1 2025 lesson).
4. **The track map is the index:** coloured by time gained/lost (default) or speed (toggle, with a colour bar); clicking a
   corner zooms all traces and the video there.
5. **Data notes, not coaching:** a note is a computed fact next to its trace ("T10a: -0.18 s, braking starts 12 m earlier,
   apex 141 vs 146 km/h"). No advice verbs. A note only appears when the difference is clear (thresholds in section 7).
6. **No chart for fewer than 5 points; no one-bar charts.** Empty states say what will appear and when.
7. **Only show what works** - no button for missing software or unbuilt features.
8. **Readable from the seat:** top-screen body text >= 22 px, labels >= 14 px small caps; nothing overlaps at 1920x1080
   (screenshot checks measure text boxes). Tabular numbers everywhere.
9. **Beautiful and calm:** black, warm white, one gold; hairlines; no decorative motion; one smooth transition at most.
10. **Fast and safe:** ready within 1 s after a session; heavy work in the background, BelowNormal, never on the newest
    .ibt while he drives.

## 3. Information architecture - five places
| Place | Where | Purpose |
|---|---|---|
| **A. Session Review** | top screen, automatically after every session; also from Sessions | "the timing screen of my session" - all laps, sectors, best/optimal, where time was gained/lost |
| **B. Lap Analysis** | from A, the Vault, or a deck key | "the engineer's screen": two laps on one distance axis, map, corner table, video |
| **C. Race Centre** | races only, from A | the field: final timing tower, race trace, positions, field strength, per-corner vs the leader/car ahead |
| **D. Garage & Career** | idle top screen / a page | his cars and tracks, PBs over time, iRating/licence history from his own sessions, his car pictures |
| **E. Vault** | page | every saved lap/race with video; the library behind A-D |

### A. Session Review (replaces the debrief and the benchmark card)
1920x1080, top screen. Data-rich, readable from the seat, nothing to press.
- **Identity band (top):** his car number as artwork (gold on black, his number from the session) - "PETER - PRATT MILLER
  MOTORSPORTS" (typed text) - car name - track (+ length) - session type, date, duration - air/track temperature from the
  session. Right: a still of his car from this session when the recorder has one.
- **Timing table (left half):** every lap: lap, time, S1/S2/S3, a mini-sector strip (e.g. 24 slices coloured
  purple/green/yellow), gap to the session best, fuel used (if logged), flags (OUT/IN/OFF/INC). Best lap row in gold.
- **Map (centre-right):** the track drawn from his own GPS, coloured by time gained/lost of the best lap vs his
  reference (his PB; the session best if this was the PB), corner names; the three biggest differences labelled with
  their time.
- **Numbers (right column):** best lap (vs PB, purple if a new PB), **optimal lap** (best mini-sectors joined), consistency
  (best vs average of the best 5, spread), laps / clean laps, time in the seat.
- **Lap-time chart (bottom right):** dots per lap with the PB and optimal as thin rules - only with 5+ laps.
- **Data notes (bottom):** at most three, each a fact with its numbers (rule 5), only when clear.
- **Saved bar (existing):** "3 laps saved - KEEP ALL / CHOOSE".
- **Race sessions:** a "RACE CENTRE" tile with finish position, field, SOF, iRating change (from the session data).

### B. Lap Analysis (the main analysis screen; "better than Cosworth Lite" because it has video)
- **Header:** lap vs reference (picker: his PB (default, never itself), session best, optimal, any kept lap, later a pro
  onboard), both times and the gap.
- **Traces (centre, one cursor, distance axis):** delta (filled green/red) on top; speed; throttle; brake; steering;
  gear (and RPM on demand). Corner bands shaded and named. Scroll/click to zoom; a slide control to line up one event
  (MoTeC idea).
- **Map (left):** coloured by delta (default) or speed (toggle with colour bar); both cars' positions at the cursor.
- **Corner table (left, under the map):** per corner: time lost/gained, brake point, entry / minimum / exit speed,
  throttle-on point - each vs the reference, sorted by time lost; click = zoom.
- **Video (top right):** his lap synced to the cursor; two-up (his lap | reference) when both have video.
- **More (behind one MORE button):** g-g plot, throttle/brake/coasting share of the lap, gear usage, consistency over the
  session's laps.

### C. Race Centre (races)
- **Final timing tower:** position, car number (artwork), driver, class, best lap, gap, pits, incidents - his row gold.
- **Race trace:** gap to the leader over laps for the top cars and him (pit stops as drops).
- **Position chart:** his position lap by lap with the cars around him.
- **Per corner vs the leader / car ahead:** from Paddock's own live log of every car's track position (section 7.6) -
  "the leader was 0.4 s quicker through T1-T3" as a fact with a small chart.
- **Field strength and iRating:** SOF, his iRating and licence before/after (from the session data, not the Data API).

### D. Garage & Career
- **His identity:** number artwork, team name, his car pictures (his own stills/screenshots), cars he owns and drives.
- **Per car + track:** PB, PB history (dots over time), laps, last driven, best video.
- **Career:** iRating and licence/safety history charted from Paddock's own session records (each session's YAML has his
  iRating and licence) [verify field names], races, wins, podiums, incidents per race, hours.

### E. Vault (exists - tidy)
Cards show lap time, gap to PB, date, tags, a video still when there is video; one card per lap (merge clip moments);
default view = best lap per car + track; filters behind MORE.

## 4. While driving and before driving
- **While driving:** no change now (live dashboard, delta bar, TV view). Later the delta bar can use the reference lap.
- **Before driving (idle top screen):** "Road Atlanta - Corvette GT3 - PB 1:19.549 - optimal 1:19.21" plus his last
  session's biggest difference as a fact.

## 5. Video
- **Recorder** (WS17, `docs\vault-recording-research.md`): ffmpeg `ddagrab` of the middle screen, NVENC, rolling segments,
  cut for keepers, upright (screens rotated 180 degrees), black-capture detection, cost measured (target <= 3 fps).
  [fact] ffmpeg is already on the PC (`vault\bin\`); nothing for Peter to do.
- **Where video appears:** Lap Analysis (synced), Session Review (car still), Vault (still on the card), Race Centre
  (later: highlight of a battle). Never a video button before a video exists.
- **Later:** Studio re-shoots from iRacing's replay (cinematic stills and films of his car), pro onboard side-by-side.

## 6. Cosworth
- **Peter's one step:** sign in at members.cosworth.com and download Pi Toolbox (the lead prepares a one-click link and
  says exactly what to press; the agent never types credentials). Paddock installs it through explorer.exe.
- **Then:** OPEN IN COSWORTH opens the lap's .ibt in Pi Toolbox Lite (file association or a documented switch [verify]).
  Video stays in Paddock (Lite has no video sync).
- **Until then:** no button (rule 7).

## 7. Engines (build first; all offline-testable with real .ibt copies)
1. **Distance alignment:** resample laps to 1 m by LapDistPct x track length; detect and drop pit/out/in/invalid laps;
   check drift (lap length within 0.5 %).
2. **Corners and mini-sectors:** corner segments from the corner model (names from Lovely Track Data, attribution kept);
   24 equal-distance mini-sectors for the timing strip; S1/S2/S3 from iRacing's sector split points if the session YAML
   has them [verify], else thirds.
3. **Per-corner metrics:** time, brake point (first brake > 10 % before the apex), entry speed, minimum speed and where,
   throttle-on (first throttle > 90 % after the apex), exit speed 100 m after the apex.
4. **Data-note thresholds:** a note appears only when the corner's time difference >= 0.05 s AND a metric differs
   clearly (brake point >= 5 m, a speed >= 3 km/h, throttle-on >= 10 m) in the part of the corner where the time went.
5. **Reference store:** per car + track: PB lap (never the lap itself), session best, optimal = **best iRacing sectors joined** (C-30 measured on real data: 24-slice optimal 1:18.125 is 1.4 s under the 1:19.549 PB - over-optimistic, so mini-sectors only colour the strip; iRacing sectors 1:19.152, thirds 1:19.269),
   consistency (best vs average of best 5, spread).
6. **All-cars live log (races):** while a race runs, irdash writes every car's `CarIdxLapDistPct` + session time at 10 Hz
   to `vault\field\<session>.bin` [fact: the live SDK has it; .ibt files do not - checked on this PC]; per-corner times for
   every car after the race. Cost measured on the Performance page.
7. **Session facts:** weather/temperatures, his iRating/licence, SOF, results from the session YAML [verify field names].

## 8. Visual identity
- Black #0b0b0c, panels #121214, hairlines #26262a, warm white #ece8df, muted #8b877d, gold #f2c230 (his / Paddock),
  reference cool white #cfd8e3 (dotted), gain #3ccf7e, loss #e5534b, timing purple #b46cff, green #3ccf7e, yellow #e8c547.
- Bahnschrift (small caps labels, tabular numbers), hairlines, generous black space; maps drawn with a dark underlay.
- Car number artwork: his number in gold, heavy condensed italic, on black - the same everywhere (A, C, D, Vault).
- Track maps from his own GPS, corner numbers in small gold circles, names from Lovely Track Data with attribution.

## 9. Process - quality without Fable prices
1. **Mockups from real data first** (the lead): A and B rendered from his Road Atlanta laps -> Peter says yes/no on the
   pictures. Then C and D the same way.
2. **Small test-first cards** for Grok (grok-4.7): the lead writes the checks; each screen card must reproduce its
   approved mockup (the lead compares screenshots side by side).
3. **One away window a day** for live tests.
4. **Models:** Grok builds (subscription), Haiku for research (cents), Opus (lead) designs and reviews, Fable only if Peter
   rejects the same mockup twice.

## 10. Order of work
1. C-29 quick wins (queued) - no dead buttons, no empty charts, no overlaps, no self-compare.
2. C-30 engines 7.1-7.5 (queued; updated to data notes + thresholds).
3. Mockups A and B from real data -> Peter yes/no. (The lead; rendering waits until the sim is off.)
4. Build A, then B (one card each, checked against the mockups).
5. Engine 7.6 + 7.7, then Race Centre (C).
6. Recorder (5) + video in B and stills in A/D/E.
7. Garage & Career (D).
8. Cosworth (6) with Peter's one step.
9. Vault tidy (E), then Studio and pro onboard (later phases).

## 11. What Peter does
- Look at the mockup pictures and say yes or no (A and B first).
- Cosworth: one sign-in + download when we reach step 8 (prepared for him).
- Optional: leave the PC on overnight with iRacing closed so live tests can run.
