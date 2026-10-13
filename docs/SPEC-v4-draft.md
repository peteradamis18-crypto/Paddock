# PADDOCK v4 â product and build specification

Date: 2026-10-11. Owner: Peter. Lead: Claude.

Ground truth for v4:

- Peter is disabled. Everything is one Stream Deck press or automatic. Premium black/gold broadcast look. Real assets only. Copy rules in `docs/COPY-RULES.md` apply to every visible word.
- `vault=1` and `recorder=1` are **ON** in `dash\irdash.ini` today. Treat SAVE RECORDING as done-in-progress, not as a future feature.
- Recording rules are fixed: auto-record in car; keep **last 3 sessions + PB laps + incident clips**; **SAVE** keeps a session forever; storage **30 GB recent / 150 GB saved**, never below **50 GB free**; encode **HEVC**.
- The iRacing members Data API is not usable. iRacing schedules come from iRacing's season PDFs/pages and the sources in `docs\research\calendars-2026-10.md`.
- R1 reviews are inventories, not the product vision. Market research is `docs\research\post-session-landscape.md`, `docs\research\pi-toolbox-features.md`, `docs\research\fourth-screen-tv.md`.
- The 19 items in `docs\HANDOFF-lead.md` are not forgotten. All land below.

---

## 1. Product in one page

Paddock is one product over five moments.

| Moment | Which screen | What Paddock does | Peter's press |
|---|---|---|---|
| Before driving | Top screen, deck | HOME shows **THIS WEEK**, **LAST OUTING**, a real hero shot of his car, PBs per track, and one big button: **RIG ON** / **LAST DRIVE** / **GET IN**. Deck offers LAST DRIVE, MY DRIVE/RACE SETUP, OVERLAYS, REPLAY. | One deck key: LAST DRIVE, MY DRIVE, or a preset. START is the only key that touches the sim. |
| Driving | Race screens, top screen, 4th screen | Clean race screens. Live dashboard on top. Delta bar on middle screen. Automatic recording. Optional safe commands: KEEP, pit keys, sound, delta mode. No popups, reloads or focus changes while he is driving. | Deck keys or learned wheel button for KEEP / CLIP only. |
| Straight after | Top screen | Session Review appears by itself: laps, sectors, optimal, consistency, incidents, saved clips. **SAVE RECORDING** keeps the whole session. **ANALYSIS** opens the Workbench on the best lap. | **SAVE RECORDING** on deck or phone, or ignore and default keeps the automatic set. |
| Later on the top screen or phone | Top screen, iPhone | Workbench replaces Cosworth-depth analysis: lap vs reference, lap vs lap, corner-by-corner time loss, video in sync, race field, career. Vault plays videos and compares clips. Sessions/career/stats are browsable. | **ANALYSIS**, **VAULT**, **SESSIONS**, **RACE**, and the same keys on the phone. |
| Sharing | Top screen, phone | **MAKE SHARE VIDEO** burns the optional data overlay into a clean MP4. **SAVE** copies it on the PC; **SHARE** opens the Windows share sheet on the PC. On the phone it saves to Photos / share sheet. **YOUTUBE** opens YouTube's upload page with the file ready. Paddock never posts, uploads or stores credentials itself. | One press on phone or top screen. |

No feature in v4 exists without a real data source. Where the source does not exist, this spec says **unknown** and the card asks Peter before building.

---

## 2. Feature areas

Each feature area covers purpose, surface, what best tools do, data sources, existing code and verdict, and acceptance as a user journey.

---

### A. Recording & Vault

**Purpose for Peter:** everything worth keeping is recorded and saved without him managing files. He presses SAVE only when he wants a whole session kept forever.

**Surface:** deck **SAVE**/KEEP/CLIP keys, top-screen Session Review saved bar, Vault page, phone Vault/Videos.

**What best tools do and what we take:** Garmin Catalyst auto-keeps important laps; RaceChrono/Pi Media sync video to data. We take: automatic keeper rules, lap clips with exact sync, one-press SAVE. We do not use NVIDIA Instant Replay, OBS, or iRacing's own video capture.

**Data sources that really exist:**
- `Documents\iRacing\telemetry\*.ibt` â his own car's 288 channels at 60 Hz.
- Session YAML from his own files.
- irdash's live all-cars race log: `vault\field\f<date>-<session>.json` (already built, W6/`docs\vault.md`).
- ffmpeg with `ddagrab`/NVENC from the middle screen: already installed in `vault\bin\`.

**Existing code:**
- `dash\src\recorder.cs`, `dash\src\vault.cs`, `dash\src\wheel.cs`, `dash\src\share.cs`
- `dash\www\v2\vault.*`, `dash\www\v2\debrief.js`, `dash\www\v2\workbench-video.js`
- Phone video screens.

**Verdict:** keep recorder/Vault core; fix SAVE; rewrite storage policy; fix Vault video compare; replace h264 with HEVC as Peter chose.

**Acceptance â user journey:**
1. Peter drives a real session. Recorder runs automatically, upright, on the middle screen.
2. He presses **SAVE** on the deck after the race.
3. Within 2 minutes the session appears in the Vault on the top screen and on the phone with its telemetry and video.
4. The 3 most recent sessions, every PB lap and every incident clip survive without SAVE.
5. Storage stays within 30 GB recent / 150 GB saved, never below 50 GB free.

---

### B. Post-session analysis â âPi Toolbox Ultra depthâ

**Purpose for Peter:** show precisely **where and why** time is lost: lap vs lap, lap vs reference, lap vs other drivers, over sessions, video in sync, real track map, corner names, weather.

**Surface:** top screen after every session; Workbench from **ANALYSIS**; Sessions/Vault detail; phone Session Review.

**What best tools do and what we take:** AiM, MoTeC, Pi Toolbox, Coach Dave, Track Titan, VRS all lead with a reference lap, delta first, traces on distance. We take:
- Distance-aligned overlays with one shared cursor.
- Corner table sorted by time lost.
- Map coloured by gained/lost.
- Data notes only when the data is unambiguous (Peter's rule).
- Video synced to the cursor.
- Race field and career across sessions.
- Real maps from `.ibt` **Lat/Lon/Alt**, not drawings.

**Data sources:**
- `.ibt` channels: speed, brake, throttle, steering, gear, G, ride height, shock velocity, wheel speeds, tyre surface temps, pressures, weather, `Lat/Lon/Alt`, incident/off-track.
- Corner model: Lovely Track Data (offline local) or corners detected from his own laps, `dash\src\corners.cs`.
- All-cars race log for competition.

**Existing code:**
- `dash\src\analysis.cs`, `deepdive.cs`, `career.cs`, `field.cs`, `sessionreview.cs`, `protools.cs`
- `dash\www\v2\workbench.js`, `workbench-*.js`, `sessionreview.js`

**Verdict:** keep and deepen. Fix scattered entry points so Sessions/Vault/Session Review all open the same Workbench. Rewrite the Pre/post map if it does not use real `.ibt` GPS.

**Acceptance â user journey:**
1. After a real race, the top screen shows Session Review within 1 s of session end.
2. Peter taps **ANALYSIS**.
3. Workbench opens on his best counted clean lap vs his best **other** lap.
4. He sees one delta-first screen. Clicking the biggest drop zooms every trace and the video there.
5. Corner table names each turn by its sourced name, or `T<n>` with source; no invented names.

---

### C. Cosworth Pi Toolbox integration

**Purpose for Peter:** one press opens the current lap/session in the free Pi Toolbox edition he has, already pointed at the right `.ibt`, with no file juggling. Paddock's own Workbench remains the primary deep tool.

**Surface:** deck ANALYSIS screen **OPEN IN COSWORTH**; Workbench/Session Review/Vault buttons.

**Best tools:** Pi Toolbox itself. We take its native `.ibt` opening, but not its setup ceremony.

**Data sources:** the `.ibt` file path Paddock already knows. Pi Toolbox Lite/installed edition is detected read-only on disk.

**Existing code:** `deck-intro\plugin.html` ANALYSIS key, `dash\src\deckfeed.cs`, `dash\src\vault.cs`, Workbench share/replay jump paths. The button exists but was âhiddenâ.

**Verdict:** keep and fix visibility plus one-press open. Do not reverse-engineer or write `.pds`.

**Acceptance â user journey:**
1. Peter opens his best lap in Workbench.
2. He presses **OPEN IN COSWORTH**.
3. Pi Toolbox opens that `.ibt` within a few seconds.
4. No dialog, file select or folder hunt.

---

### D. Pro comparison

**Purpose for Peter:** automatically find and fetch a real pro/fast onboard for the same car+track, align it to his lap, and render side-by-side locked by track position.

**Surface:** Workbench and Vault, output saved as a video in Vault.

**Best tools:** VRS, Coach Dave Delta pro-lap overlays. We take side-by-side locked-by-position with small typed labels.

**Data sources:**
- yt-dlp search for `<track> onboard <car/class> IMSA <year>` â Peter approved yt-dlp and YouTube downloads for personal viewing.
- `data\pro-refs.json` official reference times.
- His `.ibt` and recorder clip.
- ffmpeg for motion-energy alignment/render.

**Existing code:** none beyond `data\pro-refs.json` and lb. The previous cards C-16/C-17 were held.

**Verdict:** build in two cards: find/fetch; align/render. Do **not** ship partial downloader to Peter.

**Acceptance â user journey:**
1. Peter opens his Road Atlanta Corvette PB in Workbench.
2. He presses **PRO COMPARE** once.
3. Paddock finds a suitable official onboard, downloads it locally, aligns it to his lap, and renders a side-by-side video.
4. Peter watches it; no setup. If confidence is low, the card says âapproximateâ, never guesses a time.

---

### E. Studio â cinematic replays + editor

**Purpose for Peter:** one press makes a cinematic replay of his best lap or race, using iRacing's own replay cameras, without a mouse.

**Surface:** top screen, deck, Workbench; output saved to Vault.

**Best tools:** Track Titan Replay Deck, RaceChrono comparison video, professional replay cuts. We take efficient âedit the plan, not the pixelsâ: one real-time pass through iRacing's replay with SDK camera changes, filmed by Paddock's recorder.

**Data sources:**
- iRacing replay SDK broadcast messages (already proven/live-fixed in `docs\replay.md`).
- Corner model for shot cues.
- ffmpeg from `vault\bin\`.

**Existing code:** `dash\src\replay.cs`, `dash\src\recorder.cs`; editor is only designed, not built.

**Verdict:** build Studio in two phases: automatic S0/S1 first, then editor/combine. The replay must still exist â never assume unsaved replay survives; verify.

**Acceptance â user journey:**
1. Peter finishes a race and leaves the sim open.
2. Paddock films a 1-lap CINEMATIC film automatically when he is away.
3. It has at least 4 camera changes within 0.5 s of cues, no UI, upright.
4. It appears in the Vault with a thumbnail. Peter only presses play.

---

### F. Sharing â YouTube, iMessage, optional overlay

**Purpose for Peter:** send or publish a clean lap video quickly; Paddock never uploads or handles credentials.

**Surface:** phone LAPS/VIDEOS, top-screen Workbench **MAKE SHARE VIDEO**, Vault SHARE.

**Best tools:** RaceChrono comparison video, VRS video export, Windows share sheet. We take one-press local export with Windows/phone share as the transfer method.

**Data sources:**
- Paddock's recorder clip + lap `.ibt` records.
- Local share video overlay data, ffmpeg.
- Windows share sheet and phone share sheet.

**Existing code:** `dash\src\share.cs`, `dash\www\v2\workbench-share.js`, phone share UI. Windows share exists for files; YouTube upload page and iMessage handoff are not built.

**Verdict:** keep share studio; add the missing share-sheet/YouTube/iMessage journeys. Never automate posting.

**Acceptance â user journey:**
1. Peter opens a lap on the iPhone.
2. He presses **Make share video**.
3. Within ~2 min the phone says **Ready to share**.
4. **Save** puts the MP4 in Photos; **Share** opens the iOS share sheet for iMessage etc.
5. On PC, **YouTube** opens YouTube's upload page with the file selected; Paddock does not press Publish.

---

### G. 4th-screen TV view â no second account

**Purpose for Peter:** a premium, real-data-only broadcast view for people in the room while he drives. No fake cars, no invented hills, no second account, no changes to his driving view.

**Surface:** 4th screen = top dashboard monitor; toggle from deck.

**Best tools:** SDK Gaming Live Timing, EDR, iSimBroadcaster. We take their data-drawn timing tower, track map with every car, battle flags and automatic shots. We do **not** take a fake 3D world.

**Data sources:**
- Live SDK per-car arrays: `CarIdxLapDistPct`, positions, class positions, gaps, lap counts, pit/on-track.
- Real track outline from `TrackMap`/corner model.
- His own telemetry for the cockpit-style lower-third.
- Real camera images are **unknown** on one PC; no second live camera exists. A second PC/same-account spectating question remains unanswered â do not build on it without iRacing's written answer.

**Existing code:** `dash\www\v2\tv.js` is a flat data map Peter rejected. `TvView` in irdash toggles it.

**Verdict:** hide current TV view immediately; rewrite as a data-drawn broadcast view. No real camera feed until a second PC is approved by iRacing and Peter.

**Acceptance â user journey:**
1. Peter presses **TV** on the deck while driving.
2. The top screen replaces only the map + pace/split panels with a clean timing tower and a real-outline track map carrying every car.
3. The camera label switches between LEADER / BATTLE / CHASE / TRACK automatically every 8â15 s.
4. No second iRacing session, no fake 3D, no text lifts.

---

### H. Official racing + race weekend + real-world calendar

**Purpose for Peter:** see what he can race next in iRacing for his series/tracks, and see real-world session times and short previews, without opening the iRacing app or a search engine.

**Surface:** idle HOME; deck OFFICIAL screen; real-world panel next to race weekend.

**Best tools:** iRacing's own season PDF/schedule, official series pages, Jolpica/OpenF1, TheSportsDB. We take official published schedule data, local time, owned-track marker.

**Data sources:**
- iRacing official season PDFs/pages and `docs\research\calendars-2026-10.md` sources.
- iRacing special events page.
- Real-world official calendars and reputable free feeds: F1 via Jolpica/OpenF1, WEC/IMSA/GTWC via official pages where available; mark TBC when no session time is published.
- Ownership filter from `C:\Program Files (x86)\iRacing\cars` and `tracks` folder names (read-only) or Paddock's local owned map.

**Existing code:** `dash\src\official.cs`, `officialcore.cs`, `src\official.cs`, `dash\www\v2\official.js`. `official=0` in irdash.ini; the schedule panel is hidden.

**Verdict:** keep draft; fix parsing and ingestion; then enable behind tests. Never register/withdraw automatically. Scheduling data must be attributed and cached.

**Acceptance â user journey:**
1. Peter opens HOME at the weekend.
2. The Race weekend panel lists iRacing races for his owned series/tracks: series, car, track, local start, owned indicator.
3. Next to it, real-world IMSA/WEC/F1/GTWC sessions show in local time with **TBC** where not published.
4. The deck OFFICIAL screen shows the same schedule, one press opens the relevant iRacing page but never registers.

---

### I. Stats / career â iRating, SR, results history

**Purpose for Peter:** his own performance over time, without a closed API.

**Surface:** top-screen HOME/Career, phone, Workbench CAREER tab.

**Best tools:** iRacingReports, iRacingData, community userscripts; all depend on the Data API that is closed. We build from Paddock's own logs going forward.

**Data sources:**
- His own `.ibt` session YAML: his iRating, licence, SR, session type, results.
- Paddock's live race log and session cache.
- Data API is **not a source**.

**Existing code:** `dash\src\analysis.cs`/`career.cs`, `dash\src\data.cs`, some HOME career numbers. iRating/SR trend is not built.

**Verdict:** keep local career; add stats only from own logged sessions. Before Paddock existed, history is **unknown** unless Peter manually imports files.

**Acceptance â user journey:**
1. Peter opens Career after three Paddock-logged races.
2. He sees iRating/SR trend and results for those sessions.
3. No external API, no login, no scraped data.

---

### J. HOME â THIS WEEK, LAST OUTING, livery hero shot

**Purpose for Peter:** idle top screen shows his current reality in one glance: recent form, next drive, one big action.

**Surface:** top screen idle HOME.

**Best tools:** iRacing UI, F1 TV home; we take a single focused card, not a dashboard museum.

**Data sources:** his own `career-cache.tsv`, `dash\refs\`, `mydrive\state.ini`; real car pictures from his recorder stills / replay PHOTO / `paddock\home\hero.jpg`.

**Existing code:** `dash\src\home.cs`, `dash\www\v2\home.js`. THIS WEEK and LAST OUTING were removed in a previous redesign and must come back.

**Verdict:** keep and restore. Use real assets only; no drawn silhouettes.

**Acceptance â user journey:**
1. Peter sits down. HOME shows LAST OUTING, THIS WEEK, PB per track, and the one true big button.
2. The hero image is a real capture of his car; until one exists, the credited real Corvette photo remains, and a capture job fills `paddock\home\hero.jpg`.

---

### K. Deck

**Purpose for Peter:** one Stream Deck press per action; no dead keys, no thinking.

**Surface:** Stream Deck XL MAIN/More and live screens.

**Best tools:** Elgato profiles, iRaceDeck, SimHub Stream Deck. We take grouping by session phase and golden active state.

**Data sources:** `keys\keys.map`, `build-deck.ps1`, plugin `deck-intro\plugin.html`, irdash feedback.

**Existing code:** `build-deck.ps1`, plugin, `src\*.cs`. Deck v2 prepared needs final batch and Peter's Install click.

**Verdict:** keep; batch only after all commands are proven; never run `build-deck.ps1`/install.ps1 while Peter is driving.

**Acceptance â user journey:**
1. Every visible deck key has a real command; `tests\keys-test.ps1` finds no dead keys.
2. Peter presses a key once; the screen/state changes immediately and never repeats itself twice unexpectedly.

---

### L. Phone

**Purpose for Peter:** the same product on the phone while at the rig and, later, away.

**Surface:** iPhone PWA over local Wi-Fi; later Tailscale.

**Best tools:** RaceChrono phone, SDK Gaming remote timing. We take local-first, no public ports, same keys as deck.

**Data sources:** irdash API (`/phone/*`, `/vault/*`, `/analysis/session`, `/share/*`), with token pairing.

**Existing code:** `dash\src\phone.cs`, `dash\www\phone\*`. Car/track search has a known jank, and away-from-home is not built.

**Verdict:** keep; fix search; add SAVE/share/Vault video as part of recording/share cards; park away-from-home.

**Acceptance â user journey:**
1. Peter opens Paddock from the Home Screen.
2. He finds a car/track with two or three taps, watches a session, saves recording and shares.
3. The code never exposes the PC to the internet; access is local only until Tailscale is separately approved.

---

### M. Friends mode / racing line

**Purpose for Peter:** a guest can drive with one setup press; the racing line follows the chosen state.

**Surface:** deck FRIENDS screen, top screen guest map/times.

**Best tools:** none exactly, but the accessibility pattern is Paddock's own.

**Data sources:** `guest\guest.ini`, `guest\state.ini`, Telemetry SDK read-back, iRacing's own controls binding (read-only).

**Existing code:** `src\guest.cs`, `dash\src\guest.cs`, `dash\www\v2\guest.js`.

**Verdict:** keep Friends mode. The racing line remains **unproven on track**; do not claim it works until Peter confirms in a 30-second drive.

**Acceptance â user journey:**
1. A friend sits down. The friend uses the deck: car â track â strength â START. Peter does nothing.
2. The top screen shows the track map and three times; wheel strength returns to Peter's value after EXIT.
3. If racing line remains unproven, Paddock stops showing a line-on state it cannot verify, and asks Peter one plain question.

---

### N. Replay controls

**Purpose for Peter:** use iRacing's replay without reading iRacing's UI.

**Surface:** Stream Deck REPLAY screen; all messages are SDK broadcast, no clicks/focus.

**Best tools:** RobertsmaniaReplay, iRacing camera tool. We take instant one-press transport/camera/incident jumps.

**Data sources:** iRacing SDK broadcast messages and live telemetry; saved replay folder listing.

**Existing code:** `dash\src\replay.cs`, `deck-intro\plugin.html`, `docs\replay.md`. Live run had 6 failures: COCKPIT/CHASE camera group, CAMERA >, AUTO TV, HIDE UI, MY LAST INCIDENT.

**Verdict:** keep; fix the live failures and re-run `tests\replay-test.ps1 -Live` with Peter away.

**Acceptance â user journey:**
1. Peter opens REPLAY, selects a car, presses COCKPIT.
2. The sim's camera changes to Cockpit and the key reads gold.
3. Every transport key changes the correct telemetry value; `replay-test -Live` ends 0 FAIL.

---

### O. AI races

**Purpose for Peter:** one-press AI race with his own settings, no wizard.

**Surface:** deck NEXT-MODE/RACE SETUP keys.

**Best tools:** iRacing AI Single Player UI; we take a saved last-settings shortcut, not a new simulator.

**Data sources:** iRacing AI dialog mapped read-only in `docs\research\ai-dialog.md`; `mydrive\state.ini`, `mydrive\presets.ini`, Test Drive verified controls.

**Existing code:** `src\irdeck.cs` AI RACE, `src\testdrive.cs`, `src\mydrive.cs`, `dash\src\mydrive.cs`. Peter's AI settings were wiped by the earlier survey.

**Verdict:** rebuild one preset with Peter's yes. AI words on the deck stay off until each control is verified.

**Acceptance â user journey:**
1. Peter presses the AI preset key.
2. Paddock opens the AI wizard to the right page, sets saved car/track/field/weather, and puts Peter in the car.
3. No switching to the wrong control, no blind clicks.

---

### P. Design system & polish

**Purpose for Peter:** every screen belongs to one premium black/gold family; no filler and no fake assets.

**Surface:** all top-screen pages, deck, phone.

**Best tools:** F1 TV live timing, iRacing UI, premium broadcast packages. We take fixed colours, tabular numbers, small caps, hairlines, real assets.

**Data sources:** real data only; no stand-ins unless credited.

**Existing code:** `dash\www\v2\theme.css` (not yet applied); `cars.js` (drawn silhouettes, dormant); scattered old `dash\www` dead dashboard.

**Verdict:** apply design tokens across all surfaces; delete `dash\www` old dashboard and `cars.js` after verifying no live references; any new visual element goes through an independent critique before going onto Peter's screens.

**Acceptance â user journey:**
1. Peter opens Performance, Vault and Session Review.
2. They no longer look like duplicates; each has a clear first element.
3. Copy audit passes every visible screen; no "you", no filler, no emoji, no fake art.

---

### Q. Housekeeping

**Purpose for Peter:** the rig stays clean, fast and tested without Peter work.

**Surface:** internal but results visible in faster boot/deck and green tests.

**Data sources:** current file/folder layout, logon task, deck profile, tests.

**Existing code:** `tests\run-all.ps1`, `tests\deck-speed-test.ps1`, `tools\*`, root strays.

**Verdict:** move strays without breaking references; refresh timings; add every screen to click-through tests; fix flaky data/video-page checks; re-create hourly oversight only after a cost decision.

**Acceptance â user journey:** the lead can build, deploy, run all tests, and recover from `docs\OPERATIONS.md` without asking; no script silently breaks.

---

### R. Later â voice control, phone away from home

**Purpose for Peter:** future controls that must not block v4's core.

**Surface:** not built.

**Data sources:** unknown until a source is chosen.

**Verdict:** write open questions; no build until Peter chooses. For voice, recommend local dictation into Paddock's fixed actions; for phone away from home, recommend Tailscale only with no public ports and a pairing token.

---

## 3. The 19 missing items from `docs\HANDOFF-lead.md`

None are dropped silently.

| # | Missing item | Where it lands in v4 | Decision |
|---|---|---|---|
| 1 | Official racing + race weekend + real-world calendar | H | Keep, redesign schedule ingestion; behind `official=1` when tests pass. |
| 2 | HOME THIS WEEK and LAST OUTING | J | Keep/restore. |
| 3 | Studio â automatic cinematic replays + editor | E | Keep; build in two cards. |
| 4 | Pro comparison â find/fetch/align/render | D | Keep; build. |
| 5 | Cosworth Pi Toolbox integration | C | Keep/fix open flow; Pi is already installed. |
| 6 | Vault video player + compare two clips | A/B | Keep/finish in Vault. |
| 7 | Events list with PAUSE/JUMP into iRacing replay | B/N | Keep/finish; replay jump already partly built. |
| 8 | SHARE â overlay, YouTube, iMessage | F | Keep/finish share. |
| 9 | Live TV view on the 4th screen | G | Redesign; rewrite data-drawn broadcast view. |
| 10 | Racing line in friends mode | M | Ask Peter with a one-drive check before claiming. Recommended: do not leave a false state. |
| 11 | REPLAY live fixes â COCKPIT/CHASE etc. | N | Keep/fix live. |
| 12 | After-race review laps while still in sim + quick wins | A/B | Keep/fix; cards V-08. |
| 13 | AI races rebuild + deck choices | O | Keep/rebuild with Peter's yes. |
| 14 | Livery hero shot; phone car/track search; Vault vs Performance look alike | J/L/P | Keep/redesign each. |
| 15 | Design tokens + welcome driver card + visual polish + deck batch | P/J/K | Keep/build. |
| 16 | Stats/career iRating/SR/results history | I | Keep own-log stats; Data API is closed; pre-Paddock history is unknown unless files are imported. |
| 17 | Track data: real maps from `.ibt` Lat/Lon/Alt, corner names, weather | B | Keep/build from `.ibt`. |
| 18 | Housekeeping: deck timings, root tidy, click-through every screen, stale tests, oversight job | Q | Keep/schedule. |
| 19 | Later: voice control; phone away from home | R | Later/ask Peter. |

---

## 4. Build cards

Each card is one cheap-agent session. Gate includes both an automated test and a user journey. Token estimate is for one builder in an agent loop: **S â 300k in / 25k out, M â 900k / 60k, L â 2M / 120k** unless given differently. âAwayâ means the live part needs `Assert-RigFree -NeedAway`.

---

### Phase 0 â stop the bleeding (highest urgency, low risk)

| ID | Title | Files | Depends | Size | Gate (test + user journey) | Needs Peter | Tokens |
|---|---|---|---|---|---|---|---|
| V-01 | Hide fake TV view until redesigned | `dash\src\irdash.cs` toggle, `dash\www\v2\tv.js/.css`, `index.html` | none | S | Offline: `/tv` off state, no `tv.js` canvas, tests still pass. User: pressing TV shows âTV view is being rebuiltâ only, no fake map. | No | 300k / 25k |
| V-02 | HOME restore THIS WEEK + LAST OUTING | `dash\src\home.cs`, `dash\www\v2\home.js/.css` | none | S | home-test: correct last outing and this-week numbers from real cache. User: HOME shows both rows again. | No | 300k / 25k |
| V-03 | SAVE RECORDING finish | `dash\src\vault.cs`, `recorder.cs`, `wheel.cs`, `dash\www\v2\debrief.js`, `vault.js`, phone app | V-02? none | M | recorder/vault/review tests: SAVE marks session forever and survives restart. User: press SAVE on deck after a race -> session plays on phone within 2 min. | No | 900k / 60k |
| V-04 | Recorder storage policy + HEVC | `dash\src\recorder.cs`, `vault.cs`, ini | V-03 | M | Unit: budgets 30 GB recent / 150 GB saved / never below 50 GB free; HEVC in use. User: Paddock never fills disk below 50 GB. | No | 900k / 60k |
| V-05 | Vault video player + compare two clips | `dash\www\v2\vault.*`, `vault.cs` Range route | V-03 | M | Video sync <= 1 frame on generated clip; compare locks by track position. User: open a saved lap, video plays dot-on-map; choose second clip and both play same corner. | No | 900k / 60k |
| V-06 | Vault vs Performance visual identity | `theme.css`, vault/perf headers | none | S | Screenshots side-by-side; no duplicate look. User: Peter can tell which page he is on instantly. | No | 300k / 25k |
| V-07 | Phone car/track search fix | `dash\www\phone\app.js/.css`, `mydrive` endpoint | none | M | Phone search test: 2â3 taps finds Road Atlanta; no dead results. User: Peter finds car/track on phone. | No | 900k / 60k |
| V-08 | Quick wins finish + after-race review while sim still in | `dash\src\vault.cs`, `dash\www\v2\vault.js`, `debrief.js` | V-03, V-05 | M | quickwins/review tests 0 FAIL; review appears while sim process still running. User: after a race Peter sees â3 laps savedâ before leaving sim. | No | 900k / 60k |
| V-09 | REPLAY live fixes | `dash\src\replay.cs`, `tests\replay-test.ps1`, `docs\replay.md` | none | M | `tests\replay-test.ps1 -Live` 0 FAIL. User: COCKPIT/CHASE/AUTO TV/HIDE UI/MY LAST INCIDENT all work in spectate. | Yes: Peter away 10 min | 900k / 60k |
| V-10 | Deck batch: add SAVE, HOME, TV, VAULT etc | `deck-intro\plugin.html`, `install.ps1`, `build-deck.ps1` | V-03, V-06, V-01 | M | keys-test/deck-screens 0 FAIL. User: one press SAVE; one press VAULT; one press TV. | Yes: Peter clicks Install once | 900k / 60k |

---

### Phase 1 â trusted recording, auto review, analysis core

| ID | Title | Files | Depends | Size | Gate (test + user journey) | Needs Peter | Tokens |
|---|---|---|---|---|---|---|---|
| V-11 | Workbench as single analysis surface | `dash\www\v2\sessions.js`, `vault.js`, `workbench.js`, `sessionreview.js` | V-08 | M | Sessions/Vault both open Workbench with correct lap. User: no more four overlapping analysis screens. | No | 900k / 60k |
| V-12 | GPS track maps from `.ibt` Lat/Lon/Alt | `dash\src\analysis.cs`, map serving, `workbench-map` | V-11 | M | Map from `.ibt` matches outline within tolerance; no fake elevation. User: Workbench map is the real track shape he drove. | No | 900k / 60k |
| V-13 | Weather/session conditions in analysis | `dash\src\analysis.cs`, Workbench/Session Review | V-11 | S | Air/track temp, wind, wetness, skies appear. User: sees one line of real session conditions. | No | 300k / 25k |
| V-14 | Corner causes/thresholds and data notes | `dash\src\analysis.cs`, `sessionreview.cs` | V-11 | M | analysis-test: cause only when thresholds met; no-cause case included. User: note appears only with clear difference, always numbers. | No | 900k / 60k |
| V-15 | Events list with PAUSE/JUMP into iRacing replay | `dash\src\analysis.cs`, `replayjump.cs`, Workbench events | V-11, V-09 | L | Events from incidents/off-tracks/lockups/passes; JUMP sends correct replay message; video cursor follows. User: tap ABS event -> iRacing replay jumps 3 s before. | Yes: Peter away for live replay test | 2M / 120k |
| V-16 | Over-session CAREER complete | `dash\src\career.cs`, `workbench-career.js` | V-11 | M | Career test: PB by session, per-corner earliest vs latest, theoretical best. User: one car/track over weeks becomes a strip. | No | 900k / 60k |
| V-17 | Race centre field completeness | `dash\src\field.cs`, `workbench-race.js` | V-11 | M | Race field test: pit stops, passes, incidents, per-corner vs leader. User: after a race Peter reads the race story. | No | 900k / 60k |

---

### Phase 2 â Cosworth, Studio, Pro, Sharing

| ID | Title | Files | Depends | Size | Gate (test + user journey) | Needs Peter | Tokens |
|---|---|---|---|---|---|---|---|
| V-18 | Cosworth one-press open final | Workbench/Session Review/Vault COSWORTH; `deckfeed.cs`, `vault.cs` | V-11 | M | Detects Pi installed; opens `.ibt`. User: best lap -> OPEN IN COSWORTH -> Pi opens with no file search. | No | 900k / 60k |
| V-19 | Studio S0+S1 â automatic cinematic replay | `dash\src\studio.cs` maybe? or existing replay/recorder, Workbench | V-09, V-04 | L | One-lap CINEMATIC from real replay; >=4 camera changes <=0.5 s of cues; upright/no UI. User: after race, film appears in Vault without Peter pressing. | Yes: Peter away for real replay film | 2M / 120k |
| V-20 | Studio S2âS5 â editor and combine | studio page, Workbench/Vault; `dash\src\replayjump.cs`/ffmpeg | V-19 | L | Editor renders shot list, slow-mo/freeze, side-by-side/vs PB, race highlights. User: tap MAKE A REPLAY; preview; FILM IT. | No | 2M / 120k |
| V-21 | Pro comparison find + fetch | `dash\src\pro.cs` or same, `data\pro-videos.json` | V-04, V-22? no | M | yt-dlp search/score, fetch 720p, cache source URL. User: Road Atlanta Corvette yields one downloaded onboard. | No (yt-dlp approved) | 900k / 60k |
| V-22 | Pro comparison align + render | `dash\src\pro.cs`, share/ffmpeg | V-21 | M | Motion-energy/speed alignment; render side-by-side locked by position; label âreal car vs sim â guide onlyâ. User: watch Peter vs real driver. | No | 900k / 60k |
| V-23 | Share final â Windows/iMessage/YouTube | `dash\src\share.cs`, `workbench-share.js`, phone app | V-04 | M | Share test: overlay optional; file opens share sheet; YouTube upload page opens. User: save/share/share-to-YouTube from phone and PC. | No | 900k / 60k |

---

### Phase 3 â official racing, real-world calendar, stats

| ID | Title | Files | Depends | Size | Gate (test + user journey) | Needs Peter | Tokens |
|---|---|---|---|---|---|---|---|
| V-24 | Official schedule ingestion + ownership + race weekend panel | `dash\src\officialcore.cs`, `official.cs`, `dash\www\v2\official.js` | V-02 | L | Parser on S4 PDF/pages; ownership filter; local times; weekend panel. User: HOME shows upcoming races for his series/tracks. | No (Peter enables official after lead review) | 2M / 120k |
| V-25 | Official deck screen schedule + JOIN NEXT | `deck-intro\plugin.html`, `src\official.cs`, `dash\src\official.cs` | V-24, V-10 | L | Deck test: schedule tiles, no dead key; REGISTER/JOIN NEXT only with verified dialog and never automatic. User: one press opens next race schedule; joining waits for a verified second press. | Yes: Peter away for UI map test; one Install click | 2M / 120k |
| V-26 | Real-world calendar with session times + short previews | `dash\www\v2\official.js`, `dash\src\realworld.cs` | V-24 | M | Sources fetch politely; local times or TBC; no copyrighted text lift. User: IMSA/WEC/F1/GTWC weekend visible in local time. | No | 900k / 60k |
| V-27 | Stats/career â iRating/SR/results history | `dash\src\career.cs`, `home.cs`, Workbench CAREER | V-16 | M | Stats test from own session logs; no Data API. User: after Paddock-logged races, Peter sees his trend and results. | No | 900k / 60k |

---

### Phase 4 â HOME, deck/phone final, friends and AI

| ID | Title | Files | Depends | Size | Gate (test + user journey) | Needs Peter | Tokens |
|---|---|---|---|---|---|---|---|
| V-28 | HOME livery hero shot capture | `dash\src\home.cs`, replay PHOTO / recorder still | V-09, V-04 | M | Real capture is upright, no UI, >=2560 wide; fallback stays credited. User: HOME hero is his actual car after capture. | Yes: Peter away for replay/photo capture | 900k / 60k |
| V-29 | Final MAIN + live deck batch + speed | `build-deck.ps1`, `deck-intro\plugin.html`, `tests\deck-speed-test.ps1` | V-10, V-25 | M | keys-test 0; deck-speed numbers fresh. User: all keys useful, no dead keys. | Yes: Peter clicks Install once | 900k / 60k |
| V-30 | Phone final: review, video, SAVE, share | `dash\www\phone\*`, `dash\src\phone.cs` | V-03, V-23 | M | phone-test 0; PWA works after re-pair. User: Peter reviews a session on iPhone and saves/share. | No | 900k / 60k |
| V-31 | Racing line resolution | `src\guest.cs`, `dash\src\guest.cs`, `dash\www\v2\guest.js`, docs | V-10 | M | Either picture proof line on/off, or stop claiming it and ask Peter one question. User: line state matches sim or says unknown. | Yes: 30-second drive check or answer | 900k / 60k |
| V-32 | AI races rebuild + deck choices | `src\irdeck.cs`, `src\testdrive.cs`, `src\mydrive.cs`, plugin | V-10, V-25 | L | AI wizard map tests; presets verified; no blind clicks. User: one press to AI race with saved settings. | Yes: Peter chooses first settings; away for live test | 2M / 120k |

---

### Phase 5 â design, polish, housekeeping, later

| ID | Title | Files | Depends | Size | Gate (test + user journey) | Needs Peter | Tokens |
|---|---|---|---|---|---|---|---|
| V-33 | Design system across all screens + delete dead `dash/www`/`cars.js` | `theme.css`, all v2 pages, deck/phone | V-11, V-06 | L | Before/after screenshots every page; copy audit 0; no dead files referenced. User: every screen belongs to one family. | No | 2M / 120k |
| V-34 | Click-through every screen + stale data/video tests | `tests\clickthrough-test.ps1`, `tests\data-test.ps1`, `tests\run-all.ps1` | V-33 | M | Every visible screen clicked; no dead buttons; stale flags fixed or removed with reason. User: Peter cannot find a button that does nothing. | No | 900k / 60k |
| V-35 | Root tidy + deck timings + docs update | `tools\`, stray files, `docs\deck-speed.md`, `docs\USER-GUIDE.md` | V-34 | S | No referenced path breaks; run-all unchanged; timings written. User: guide matches the rig. | No | 300k / 25k |
| V-36 | Voice/phone away from home â decision only | none | V-34 | S | Questions answered; no code until Peter chooses. User: not built yet, clearly not shown. | Yes: voice/remote decision | 300k / 25k |

---

## 5. Cost table

Prices per million tokens:

- Hands `deepseek/deepseek-v4.1-flash`: input **$0.30**, output **$1.20**. With 60 % of input cache-hit at **$0.03**, the effective input price for this build is:  
  `0.6 Ã 0.03 + 0.4 Ã 0.30 = $0.138 / M`.
- Reviewer `z-ai/glm-5.3`: **$0.07 / M in** and **$4.80 / M out**.
- Spec/research `deepseek/deepseek-v4-pro`: **$0.66 / M in**, **$1.98 / M out**.

Assumptions: reviewer reads **60k in / 4k out per card**. Brain spec/research pass = **3M in / 200k out**. Reruns +20% on build/review/spec.

| Phase | Cards | Hands input (M) | Hands output (M) | Hands cost | Review cost | Total phase |
|---|---|---|---:|---:|---:|---:|---:|
| 0 | 10 | 7.2 | 0.495 | $1.59 | $0.23 | $1.82 |
| 1 | 7 | 6.8 | 0.445 | $1.47 | $0.16 | $1.64 |
| 2 | 6 | 7.6 | 0.480 | $1.62 | $0.14 | $1.77 |
| 3 | 4 | 5.8 | 0.360 | $1.23 | $0.09 | $1.33 |
| 4 | 5 | 5.6 | 0.360 | $1.21 | $0.12 | $1.32 |
| 5 | 4 | 3.5 | 0.230 | $0.76 | $0.09 | $0.85 |
| **Subtotal** | **36** | **36.5** | **2.370** | **$7.88** | **$0.84** | **$8.72** |
| Spec/research (Brain) | â | 3.0 | 0.200 | â | â | $2.37 |
| **Base total** | â | â | â | â | â | **$11.09** |
| **With 20 % reruns** | â | â | â | â | â | **$13.31** |

Lead checks: **36 card checks** plus **2 system-wide gate reviews** (after Phase 0 and Phase 3) = **38 lead checks**. Lead time is not token-costed here; it is a count only.

---

## 6. Open questions for Peter

Only the decisions the system cannot make; each has a recommended answer.

1. **Racing line (C-25).** Can you run one 30-second Test Drive once, press LINE as described, and tell us whether the line actually appears on track?  
   *Recommended: yes; until then Paddock stops pretending the line is on.*

2. **AI race first settings.** After rebuilding AI races, which one preset should be the first one-press key?  
   *Recommended: Corvette GT3, Road Atlanta, 20 cars, fair strength, unless you already have a saved setting to recover.*

3. **Stats/career source.** Confirm Paddock should build iRating/SR and results history only from sessions Paddock has logged itself, with no Data API/pre-Paddock scrape.  
   *Recommended: yes; pre-Paddock history is shown only if files are imported manually.*

4. **Voice control later.** When voice control is built, local iPhone dictation into fixed Paddock actions, or a cloud speech model?  
   *Recommended: local dictation into fixed actions, no cloud, no extra account.*

5. **Phone away from home.** When reached, should we install Tailscale for phone access away from home?  
   *Recommended: yes, with no public ports and pairing tokens; separate install click only when we get there.*

6. **Studio auto-run.** Should Studio automatically film a cinematic best lap after sessions when you are away, without asking each time?  
   *Recommended: yes; only when a valid replay is available and you have been away 10 minutes.*

7. **HOME hero shot.** May Paddock capture your car automatically from a replay with UI hidden while you are away?  
   *Recommended: yes; fallback stays the credited real Corvette photo until one exists.*

8. **TV view judgement.** After the data-drawn broadcast view is built, do you want to judge it side by side with the current fake view, or simply hide the fake view now?  
   *Recommended: hide now, build the new one, then show you once.*

---

## 7. Risks and what we do about each

1. **iRacing UI changes break irdeck/testdrive/actions.**  
   Mitigation: verify every dialog before clicks; keep screenshots; isolate UI automation to affected cards; no blind clicks.

2. **Recorder costs frame rate or captures black.**  
   Mitigation: measure with `tests\recorder-test.ps1` before enabling changes; HEVC, middle-screen only, explicit plain fix message if black.

3. **Storage/OneDrive conflicts.**  
   Mitigation: never put Vault in OneDrive; enforce 30/150/50 budgets; skip online-only files; never write iRacing telemetry.

4. **Schedule source drift (iRacing PDF/HTML and real-world pages).**  
   Mitigation: cache with timestamps, mark stale, mark TBC; verify one fetch per source in tests; no scraping behind logins.

5. **Cheap coding model produces weak C# 5 or false tests.**  
   Mitigation: bake-off before large build; every card tests first; a second model reviews each diff; lead gates by running/using it.

6. **Live tests interrupt real sessions.**  
   Mitigation: all tests guard with `Assert-RigFree`/`NeedAway`; offline work only while he drives; deploy only after `state` shows sim=False.

7. **Deck or add-on batches break the rig.**  
   Mitigation: one batch at a time; `keys-test` and `deck-screens-test` before; Peter clicks Install once; profile backups remain in `backup\`.

8. **Second-account/spectating policy for a real TV camera is unknown.**  
   Mitigation: do not build real-camera 4th-screen on one PC; ask iRacing in writing before any second PC/account use.

9. **Phone exposure/security.**  
   Mitigation: localhost-only by default; `tools\phone-allow.cmd`; token pairing; no shell from phone; Tailscale only if Peter later approves.

10. **Analysis overclaim or faux insights.**  
    Mitigation: data notes only with clear thresholds; every source recorded; âunknownâ rather than guessed; copy rules permit no filler.