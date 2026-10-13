# What other sim telemetry / coaching tools do better — and what we adopt

Researched 2026-10-09 (web; most sources are the vendors' own pages, so treat claims as marketing). Decisions are the
lead's judgement against Peter's taste: features that make him faster or save effort; premium, never gimmicky.
Two of these tools are already installed on the rig (Coach Dave Delta, trophi.ai) — we don't replace them, we take the
ideas that fit our system and his Stream Deck-first, top-screen-first setup.

## The landscape

| Tool | What it is best at | Price (as found) |
|---|---|---|
| **Track Titan** | "Coaching Flows": finds the single biggest root cause of time loss and explains it across the lap instead of a corner-by-corner data dump; auto-installed setups; 1:1 pro coaching | subscription |
| **Coach Dave Delta** | Auto Insights (braking, entry, apex, exit tips), compare your line/inputs against pro laps, 2,500+ setups that auto-install, leaderboards | ~£11.99/mo |
| **trophi.ai** | Live voice coach ("Mansell AI") that, after each lap, tells you on the next lap what to change at specific corners; audio brake tones; live input overlays; corner-by-corner post-session report | premium tier, free trial |
| **VRS** | iRacing-only, automatic telemetry sync, detailed side-by-side comparison with pro Data Pack laps (inputs, line), coaching marketplace | free tier (1 comparison/week) + paid |
| **Garage 61** | Free iRacing telemetry: lap comparison, community reference laps, leaderboards | free + ~$7/mo Pro |
| **RaceLab / iOverlay** | Overlays: standings/relative with configurable columns (iRating + gain, positions gained, pit status, last lap, interval, licence), fuel calculator, head-to-head, race schedule, team fuel sharing | ~€2.50–5/mo |
| **Cosworth Pi Toolbox / MoTeC** | Professional analysis: multi-lap overlays, math channels, histograms, corner/track reports | Toolbox Lite free for iRacing |

## Where we are already ahead
- One-press everything from the Stream Deck (friends mode, My Drive, overlays control) — none of them do this.
- Everything is local and free, runs from Peter's own telemetry, no uploads.
- Live per-car data for the whole field (iRacing gives every car's track position many times a second): we can benchmark
  Peter against the fastest car **in the same session**, which reference-lap tools can't do live.
- Rig Doctor, startup intro, friends mode with leaderboard and CrewChief speaking the guest's name.

## What we adopt (and why)

### Coaching engine (highest value) — spec WS10
1. **Corner report card** (from MoTeC/Pi Toolbox, Delta Auto Insights, trophi reports): for each corner — brake point
   (metres before the apex), peak brake, minimum speed, coasting time (neither pedal), throttle pick-up point, exit speed.
   Best lap vs typical lap and vs all-time PB. This is the data the coaching tools turn into advice.
2. **"Your three fixes"** (Track Titan Coaching Flows): rank corners by time lost and name the root cause in plain
   English — "T10a: you brake 12 m earlier than your PB and carry 6 km/h less to the apex — 0.21 s". Shown on the
   debrief and the sessions page. Biggest single cause first.
3. **Brake-point cues** (trophi audio brake tones): optional practice aid — a short tone a moment before your PB's brake
   point for each corner. On/off from the deck. Learning a new track with your own best lap as the guide.
4. **Live benchmark vs the fastest car in the session** (our own advantage): corner-by-corner time against the class
   leader from live position data — in the debrief, and between laps.
5. **Between-lap spoken tip** (trophi Mansell) — *maybe*: one short spoken correction after each lap ("Turn 1: brake
   later"), only in practice, off by default. Depends on a voice that doesn't sound robotic (Windows voices are basic;
   CrewChief can't speak custom text). Build only if a test clip sounds good to Peter.

### Racecraft on the dashboard — spec WS11
6. **Richer standings/relative on the top screen** (RaceLab/iOverlay): iRating gain/loss for every driver (not only
   Peter), positions gained, pit stops, last lap, interval, and a gap-trend arrow (closing / pulling away).
7. **Fuel-save target** (RaceLab fuel calculator): when fuel to finish is short, show the per-lap target to make it
   without a stop, and how many laps of lift-and-coast it takes.
8. **Head-to-head**: car ahead / behind — their last three laps vs yours, who is faster where (sector).

### History — spec WS12
9. **iRating / safety rating trend** (stats sites): read from Peter's own telemetry files (each .ibt's session info has
   his iRating and licence), chart over time on the sessions page. No API needed.

### Not adopted
- Pro reference laps and paid setup catalogues (VRS, Delta, Track Titan): paid content we can't generate; Peter already
  has Coach Dave Delta installed if he wants them.
- Cloud sync, leaderboards against strangers, team fuel sharing: Peter races solo with friends at home.
- AI chat coach: low value vs the concrete fixes above.

## Sources
- Coach Dave Academy: Delta vs VRS — https://coachdaveacademy.com/tutorials/coach-dave-delta-vs-vrs-which-one-is-best-for-you/
- Coach Dave Academy: Delta vs Garage 61 — https://coachdaveacademy.com/tutorials/coach-dave-delta-vs-garage-61-which-is-best-for-you/
- Delta Auto Insights — https://coachdaveacademy.com/announcements/sim-racing-ai-coaching-with-delta-auto-insights/
- Track Titan Coaching Flows (Nov 2025) — https://www.tracktitan.io/post/november-2025-update-coaching-flows
- trophi.ai iRacing coaching — https://www.trophi.ai/sim-racing-coaching/iracing
- trophi.ai review (SimRacingHub) — https://www.simracinghub.nl/en/?p=27217
- RaceLab iRacing overlays — https://racelab.app/iracing
- iOverlay — https://ioverlay.app
- RB Telemetry Coach (Garage 61 add-on) — https://addons.mozilla.org/firefox/addon/rb-telemetry-coach/
