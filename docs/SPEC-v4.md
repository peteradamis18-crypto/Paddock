# PADDOCK v4 - final specification

Date: 2026-10-11. Owner: Peter. Lead: Claude. Builders: DeepSeek V4.1 Flash in OpenCode, one card per session. Reviewer: GLM-5.3 per card.

Ground truth (overrides the draft, the critique and older docs):
- Recording rules confirmed by Peter 2026-10-11: auto-record in car; keep last 3 sessions + PB laps + incident clips; SAVE keeps forever; 30 GB recent / 150 GB saved / never below 50 GB free; HEVC. `vault=1` and `recorder=1` are ON in `dash\irdash.ini`. Card S1 (`docs\cards\S1-save-recording.md`) is building SAVE RECORDING now; this spec starts from S1 and only adds follow-ups.
- The iRacing Data API is closed. Schedules come from iRacing's season PDF/pages; career history comes from his own .ibt files (session YAML carries IRating and LicString per driver, field names verified in P0-08) plus an optional one-time CSV import.
- Rules in CLAUDE.md / AGENTS.md / docs\COPY-RULES.md apply to every card as written: never act while he drives, never write iRacing files, C# 5, no frameworks, real assets only, no downloads or accounts without his yes.

---

## 1. Product in one page

Paddock is one product over five moments. Four of them get a signature screen, built first after Phase 0.

| Moment | Screen | What Paddock does | Peter's press |
|---|---|---|---|
| Before driving | Top screen HOME, deck | Next official race in his series with countdown and local start, owned/not, his PB and the field benchmark there; this weekend's real IMSA/WEC/F1/GTWC sessions in local time with a one-line factual preview; THIS WEEK; LAST OUTING; his own car as the hero shot; one big button | One press on the big button (LAST DRIVE / GET IN / RIG ON) |
| Driving | Race screens, top screen, 4th screen | Clean race screens, live dashboard, delta bar, automatic recording. On the 4th screen a data-drawn broadcast view the room can follow: timing tower, every car on the real GPS map, battles, his inputs; between stints, real replay pictures | KEEP / CLIP on the deck or wheel; TV on the deck |
| Straight after | Top screen | Within 60 s, no press: result and position story by lap, pace vs field, the 3 corners that cost most with looping video of his lap vs his best at that corner, incidents with video; SAVE / SHARE / OPEN IN COSWORTH / DEEP DIVE | One press |
| Later | Top screen + iPhone | Workbench at Pi Toolbox Ultra depth with video in sync: multi-lap overlay, offset slide, navigator 0.5-8x incl. reverse, soft events, maths/constants/lookup tables, PSD/FFT, aero balance, setup A/B, G-G/XY, histograms, map by any channel; fastest car in his session per corner; benchmark with a real next goal; career back to his first .ibt; Vault with video compare; Cosworth opens ready | ANALYSIS / VAULT / STATS, the same keys on the phone |
| Sharing | Top screen, phone | Share video with optional overlay; Windows share sheet, YouTube upload page, iPhone Photos / iMessage share sheet; Studio films cinematic replays and a race reel; pro onboard side-by-side. Paddock never posts or stores credentials | One press |

New versus today: whole-session recording with SAVE (S1); a broadcast-grade debrief instead of the summary; HOME that knows his next race and the real-world weekend; a TV view the room can watch; Workbench depth to Pi Ultra (today: Pi Lite level plus video); career years back; a benchmark with a next goal; real GPS maps on every page; Cosworth opening ready; Studio, pro comparison and share journeys finished; every screen in one visual family; no dead keys, no dead buttons.

---

## 2. Feature areas

Each area: purpose, best-tool references, real data sources, existing code and verdict, acceptance journey. Cards are in section 5.

### A. Recording and Vault
Purpose: everything worth keeping is recorded and kept by rules; SAVE keeps a session forever.
Best tools: Garmin Catalyst (auto-keeps important laps), RaceChrono / Pi Media (video synced to data). Taken: keeper rules, exact segment-time sync, one press SAVE.
Data: `vault\rec\*.ts`, `vault\sessions\*.mp4+json`, `vault\saved\`, `vault\clips\`, recorder sidecars (`lapStartOffset`), `.ibt` records, `vault\field\*.json`, ffmpeg in `vault\bin\`.
Existing: `dash\src\recorder.cs`, `vault.cs`, `wheel.cs`, `dash\www\v2\vault.*`, `workbench-video.js`, phone session screen. Verdict: KEEP; S1 finishes SAVE, sessions, incidents, retention, HEVC. Follow-ups only: live check in a real session (P0-01), HEVC playback proven on the top-screen Chrome and the iPhone with h264 fallback (P0-02), deck key (K-02), Vault video compare (P0-10), after-race laps while still in the sim (P0-09).
Journey: Peter drives, presses SAVE once on the phone after the session, sees SAVED; within 2 min the session plays on the phone and the top screen; the last 3 sessions, PB laps and incident clips survive without SAVE; free space never drops below 50 GB.

### B. Debrief - straight after a session (signature a)
Purpose: tell him what happened and where the time went before he has left the seat.
Best tools: F1 TV / MultiViewer race trace and position chart, trophi.ai ranked findings, Garmin Catalyst top three, Coach Dave corner video. Taken: position story, pace vs field, ranked corners, looping corner video. Not taken: coaching sentences.
Data: `.ibt` (laps, sectors, incidents, conditions), `vault\field\*.json` (positions, gaps, passes, class best/median), S1 session mp4 + sidecar (corner clips cut `-c copy`), `analysis.cs` corner metrics and thresholds (C-30), Lovely/auto corner names.
Existing: `sessionreview.cs/.js` (timing table, map, optimal, notes), `debrief.js` (laps-saved bar, race extras), `field.cs`, `share.cs`, `replayjump.cs`. Verdict: KEEP the engines; REWRITE the screen as `debrief-v4.js` to the wireframe in section 3a; the Session Review's timing table moves behind DEEP DIVE.
Journey: he gets out after a race; within 60 s the screen shows P3 (+1), position by lap, pace vs the field, three corners looping his lap against his best, two incidents with clips, and four buttons. He presses nothing, or one of the four. He fails it if a clip shows the wrong corner or the position story is off by one place.

### C. Workbench - deep dive (signature c)
Purpose: Pi Toolbox Ultra depth, zero setup, video in sync, on the top screen and the phone.
Best tools: Pi Toolbox 14 (tasks, datum, reference cursor R, offset O, navigator 0.5-8x reverse, soft events, maths, constants, lookup tables, X/Y with fit, histogram, PSD, split report), MoTeC i2 Pro (offset axis, multi-lap overlay), AiM RS3 (consistency gap). Taken: all of the above as presets with no configuration.
Data: 288 channels at 60 Hz (`docs\research\ibt-channels.md`): shockVel/VertAccel (PSD), ride heights + CFSRrideHeight (aero), dcBrakeBias/TC/ABS (setup A/B), wheel speeds, ABS, Lat/Lon/Alt (GPS map), weather channels; `vault\field` (fastest car); `CarTable` constants (hidden where unsourced).
Existing: `workbench.js` + `workbench-*.js` (10 pages, PRO with X/Y, histogram, maths, export), `analysis.cs`, `deepdive.cs`, `protools.cs`, `career.cs`, `field.cs`, `workbench.cs`, `deckfeed.cs`. Verdict: KEEP and deepen. FIX the four entry points (Sessions/Vault/Review all open the Workbench). Explicit Pi-depth list, each a card: multi-lap overlay 3+ (W-02), offset slide with auto-align (W-03), navigator 0.5-8x incl. reverse (W-04), soft events (W-05), constants and lookup tables (W-06), PSD/FFT (W-07), aero balance (W-08), setup A/B (W-09), map coloured by any channel + XY/histogram polish (W-10), events with PAUSE/JUMP (W-11/12), fastest car in his session per corner (W-13). Phone depth: session review + corner table (W-16), channel picker + XY/histogram (W-17). Deliberately out: tyre model fitting (no calibrated data), understeer angle until a sourced steering ratio exists.
Journey: from the debrief he presses DEEP DIVE; the Workbench opens on the corner that cost most, his lap vs his best other lap, video beside the traces. He adds two more laps, presses OFFSET AUTO on the deck and the brake traces line up at the brake point. The SUSPENSION page shows a damper frequency peak per corner of the car; the RACE page shows where the fastest car in his class gained.

### D. Benchmark - how good am I
Purpose: his PB against three yardsticks and one real next goal, every number with a source and n.
Best tools: Garage 61 leaderboards, VRS Data Packs, iRacing time attack. Taken: percentiles with sample size, next goal as the nearest yardstick above.
Data: `data\fieldlaps.tsv` (every driver's best lap, iRating, licence per session; back-filled from `.ibt` with `CarIdx*`), `data\pro-refs.json` (official IMSA timing), career cache (PB history).
Existing: `bench.cs`, `bench.js/.css`, bench-test 49/0. Verdict: FIX, not drop (Peter: "the yardstick sucks, next goal and other drivers not thought out"). Card H-03.
Journey: Road Atlanta Corvette card reads PB 1:19.549 at the top, then field top 5 % / top 25 % / median with n, similar-iRating pace, the IMSA reference with its source, one NEXT line (next yardstick up, gap), PB history dots. He can say his next goal in 5 s. No yardstick is shown with n < 30.

### E. Career and stats - years back
Purpose: iRating, SR, results history from his own files, back to his first .ibt.
Best tools: iRacingReports, iRacingData (closed API). Taken: trend charts, results table with SOF.
Data: session YAML in every .ibt - `DriverInfo.Drivers[PlayerCarIdx].IRating`, `LicString`, `LicLevel`, `LicSubLevel` and the results block (exact names verified in P0-08 first); `SessionInfo` results; `vault\field`; optional CSV from the members site dropped in `vault\import\`.
Existing: `career.cs` (one combo over sessions), `data.cs` Career cache, `workbench-career.js`. Verdict: KEEP; ADD `stats.cs` back-fill and a stats screen (W-14, W-15). AI sessions (iRating 0/1) excluded.
Journey: STATS shows his iRating curve from his first .ibt to today, SR by licence class, every race with finish, SOF, incidents; dropping the members CSV adds races Paddock never saw, without duplicates.

### F. Cosworth Pi Toolbox
Purpose: one press opens the lap in his free Pi Toolbox with Paddock's worksheets ready; Paddock's Workbench stays the primary tool.
Best tools: Pi Toolbox itself. Taken: native .ibt open, datum outing, a ready workbook.
Data: the `.ibt` path; Pi's install (read-only) and Pi's own user folder (never iRacing's).
Existing: hidden OPEN IN COSWORTH on Vault/ANALYSIS deck screen, `deckfeed.cs`, `vault.cs` cosworth route. Verdict: FIX visibility; verify the open method first (command line, then explorer.exe file association) - the acceptance is gated on a verified method (W-18); ready workbook in Pi's user folder with speed/throttle/brake/steering/gear/delta and the PB as datum where the edition supports two outings, failable if the workbook format is binary (W-19); video-sync research recorded (Lite has none; Plus+ only).
Journey: OPEN IN COSWORTH on any surface; Pi opens that .ibt with the Paddock worksheets; no file dialog. If the workbook cannot be written, the button still opens the file and the card says so.

### G. Pro comparison
Purpose: a real onboard of the same car/class at the same track, aligned and rendered beside his lap.
Best tools: VRS / Coach Dave pro overlays. Taken: side-by-side locked by track position.
Data: yt-dlp (approved, checksum verified), `data\pro-refs.json`, his clip + `.ibt`, ffmpeg.
Existing: none beyond pro-refs. Verdict: BUILD in three cards (find/fetch, align, render); nothing shipped until render passes. Telemetry of other drivers: own + field-in-session now (free, W-13); Garage 61 free account is an option needing his yes (section 7).
Journey: PRO COMPARE on his Road Atlanta Corvette PB; one onboard is found, fetched, aligned (three corners within 0.5 s), rendered with "real car vs sim Â· guide only"; "approximate" when confidence is low; never a guessed time.

### H. Studio - cinematic replays and editor
Purpose: a film of his best lap and a race reel without a mouse.
Best tools: Track Titan Replay Deck, broadcast replay cuts. Taken: edit the plan, one real-time pass through iRacing's replay with SDK camera cues, filmed by the recorder.
Data: SDK broadcast messages (`docs\replay.md`), corner model, recorder, `vault\field` (passes, incidents).
Existing: `replay.cs`, `recorder.cs`; editor designed only (WS19). Verdict: BUILD after the REPLAY live fixes; S0a verifies the replay survives (experiment E5) before anything else.
Journey: he leaves the sim open after a race and walks away; 10 min later a CINEMATIC film of his best lap is in the Vault, â¥ 4 cuts within 0.5 s of cues, upright, no UI. Later: MAKE A REPLAY, change one camera chip, FILM IT.

### I. Sharing
Purpose: send or publish a clean lap video; Paddock never uploads.
Best tools: RaceChrono comparison video, Windows share sheet. Taken: local export, OS share sheets.
Data: recorder clip or session, `.ibt`, `share.cs` overlay, Windows share (explorer), iOS share sheet.
Existing: `share.cs`, `workbench-share.js`, phone CLIPS card. Verdict: KEEP; ADD Windows share sheet, YouTube upload page, iPhone Photos/iMessage; share videos stay h264 (plays everywhere).
Journey: on the phone: Make share video â Ready to share â Share â iMessage. On the PC: YOUTUBE opens youtube.com/upload with the file selected in Explorer; he presses Publish himself.

### J. TV view - 4th screen (signature d)
Purpose: a broadcast the room enjoys while he drives, no second account, his driving view untouched.
Best tools: SDK Gaming Live Timing (rank 1 in `fourth-screen-tv.md`, trial as the benchmark, needs his yes), EDR, iSimBroadcaster, F1 TV timing tower, WEC 2025 car-number artwork in livery colours. Taken: tower with gaps/intervals, every car on the real map, battle detection, automatic shot labels; between stints real replay pictures (rank 6, zero cost). Not taken: fake 3D world.
Data: live `CarIdx*` arrays read from one frozen frame (LapDistPct, Position, ClassPosition, OnPitRoad, F2Time/EstTime, Lap, LastLapTime), session YAML (numbers, class colours, names), real GPS map (P0-05), his telemetry; replay via `replay.cs` (AUTO TV, HIDE UI after C-03 fixes).
Existing: `tv.js/.css` (flat data map Peter rejected), `TvView` toggle. Verdict: HIDE now (P0-03), REWRITE as `tv.cs` + `tvview.js` (T-01..T-05), deck key only when the rewrite passes (K-02).
Journey: he presses TV; the top screen's map and pace/split panels become a timing tower and a real-outline map with every car; the label changes LEADER / BATTLE / CHASE / TRACK on rules; a friend reads who is P3 and the gap; between stints the sim screens show the replay of his last two laps and stop the moment he is on track. Sim fps unchanged.

### K. Official racing + race weekend + real-world calendar (signature b data)
Purpose: what he can race next in his series, and what the real world races this weekend, without opening the iRacing app.
Best tools: iRacing season PDF (GridSherpa parses it), Jolpica/OpenF1, official series pages. Taken: published cadence, local time, owned marker, TBC.
Data: iRacing season PDF/page with an HTML fallback and a season-rollover rule; owned cars/tracks folders (read-only); his series = series raced in the last 90 days âª favourites; F1 via Jolpica/OpenF1; IMSA/WEC/GTWC official calendar pages with fixture parsers; official RSS for preview lines; cache with "as of".
Existing: `official.cs`, `officialcore.cs` (PDF parser), `src\official.cs`, `official.js`; `official=0`. Verdict: KEEP, FIX parser and source acquisition (H-01), ADD his-series/ownership/next race (H-02), real-world fetch (H-05), preview lines by a cheap model at fetch time, copy-rules filtered, with source and date (H-06, needs his yes). Never register automatically.
Journey: HOME on a Saturday names the IMSA iRacing Series race at 20:45 local in 1 h 03, owned, PB and field median there; beside it Petit Le Mans Sat 12:10 local with one factual line and its source; TBC where not published.

### L. HOME (signature b)
Purpose: his current reality in one glance and one big button.
Data: `/home`, `/official`, `/bench`, `realworld.json`, career cache, `paddock\home\hero.jpg` (his own car via replay PHOTO, credited stand-in until then), `/cars/*.jpg` (iRacing's own car pictures).
Existing: `home.cs`, `home.js/.css`. Verdict: KEEP, RESTORE THIS WEEK and LAST OUTING (P0-04), REWRITE layout to section 3b (H-07), ADD welcome driver card (H-08), hero capture (T-08).
Journey: he sits down and reads the next race and countdown in 3 s; one press on the big button starts his usual drive.

### M. Deck
Purpose: one press per action, no dead keys.
Data: `keys\keys.map`, `build-deck.ps1`, `deck-intro\plugin.html`, keys-test.
Existing: add-on 1.7.0.0 prepared (ANALYSIS, SOUND, RACE SETUP), MAIN v2 prepared. Verdict: KEEP; MAIN has no free key, so K-01 is a 32-key layout picture naming the displaced never-pressed keys; Peter says yes once; K-02 batches SAVE, DEBRIEF, VAULT, TV, HOME and the debrief row on ANALYSIS; one Install click.
Journey: every key answers (keys-test 0 dead); SAVE, VAULT, TV, DEBRIEF are one press.

### N. Phone
Purpose: the same product at the rig and on the sofa.
Data: `/phone/*`, `/analysis/*`, `/api/rec/*`, `/share/*`, token pairing, LAN only.
Existing: `phone.cs`, `dash\www\phone\*`. Verdict: KEEP; FIX search (P0-07); ADD SAVE/SAVED, debrief mirror (D-05), session review + corner table (W-16), channel picker (W-17), share (SH-02); LAPS tab renamed REVIEW (PH-01). Away from home parked (Tailscale, needs yes).
Journey: 3 taps to Corvette + Road Atlanta with START lit; a session reviewed, saved and shared from the sofa; nothing reaches the internet.

### O. Friends mode and racing line
Existing: `src\guest.cs`, `dash\www\v2\guest.js`; wheel and map proven live (C-24). Verdict: KEEP; the racing line is unproven - F-01 ends with Peter's 30-second check or the LINE state removed. Journey: the line state matches the sim or is not shown.

### P. Replay controls
Existing: `replay.cs`, REPLAY screen; live 242 ok / 6 FAIL (COCKPIT/CHASE, CAMERA >, AUTO TV, HIDE UI, MY LAST INCIDENT). Verdict: KEEP, FIX live (T-06); Studio, hero shot, replay TV and event jumps depend on it. Journey: COCKPIT turns gold and the picture is the cockpit; replay-test -Live 0 FAIL.

### Q. AI races
Existing: `src\irdeck.cs` AI RACE, wizard mapped 9 steps (`docs\research\ai-dialog.md`), three pickers unmapped; Peter's Last Settings wiped. Verdict: finish the survey (A-01), one preset with Peter's choice, read back every control before launch (A-02); AI words on the deck only after. Journey: one press, his usual AI race, no blind clicks.

### R. Design system and polish
Best tools: F1 TV timing, iRacing UI, Pi Toolbox (side-by-side pictures required by the premium visuals rule). Data: `theme.css` tokens (section 8 of DESIGN-analysis). Existing: `theme.css` not applied; `cars.js` dormant; `dash\www` v1 dead. Verdict: APPLY tokens by page group (DS-01..04), DELETE dead files (DS-05); any new visual element gets a side-by-side picture and an independent critique before it goes live. Journey: every screen in one family; copy-audit 0; 0 raw hex colours outside theme.css.

### S. Housekeeping
Click-through test on every screen, stale tests fixed, root tidy, docs refreshed, oversight job decision (HK-01..04). Journey: Peter cannot find a button that does nothing; the lead can build, deploy, test and recover from `docs\OPERATIONS.md`.

### T. Later - voice, phone away from home
Decision cards only (HK-04): local speech into fixed actions; Tailscale with no public ports and a pairing token. Nothing built without his yes.

---

## 3. Signature-moment screen layouts

All top-screen layouts are 1920Ã1080, black #0b0b0c, warm white, one gold, Bahnschrift, tabular numbers, body â¥ 22 px, labels â¥ 14 px small caps. Real assets only: his own captures, iRacing's own car pictures from `/cars`, his GPS map. No drawn cars.

### 3a. Straight after a session - debrief (top screen, â¤ 60 s after session end, no press)

```
âââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ 0
â #4  PETER Â· PRATT MILLER MOTORSPORTS      RACE Â· Road Atlanta Â· Corvette Z06 GT3.Râ
â     Sat 11 Oct Â· 20:45 Â· 18 laps Â· 20 cars Â· SOF 2,233 Â· air 24 Â°C Â· track 31 Â°C â 110
ââââââââââââââââââââââââââââââ¬âââââââââââââââââââââââââââââ¬ââââââââââââââââââââââââ¤
â RESULT                     â POSITION BY LAP            â PACE VS FIELD         â
â P3   start P4   +1         â chart 18 laps: his line    â best 1:19.549  PB     â
â iRating +64                â gold, leader grey, the two â class best 1:18.912 #22â
â gap to winner 8.4 s        â cars around him dotted,    â his median 1:20.3     â
â 2x incidents               â pit stops as drops, passes â field median 1:20.9   â
â 15 clean / 18              â as dots (vault\field)      â (n=19)  top 5 % 1:18.7â
ââââââââââââââââââââââââââââââ´âââââââââââââââââââââââââââââ´ââââââââââââââââââââââââ¤ 410
â WHERE THE TIME WENT   best lap vs his best other lap with video                 â
â â T10a  â0.21 s âââââââââââ â T1  â0.12 s âââââââââââââ â T5 Esses â0.09 s âââ â
â â â¶ this lap   (560x210)  â â â¶ this lap               â â â¶ this lap          â â
â â â¶ best lap   (560x210)  â â â¶ best lap               â â â¶ best lap          â â
â â brake 12 m earlier Â·    â â apex 141 vs 146 km/h     â â throttle 10 m later â â
â â apex 141 vs 146 km/h    â â                          â â                     â â
â âââââââââââââââââââââââââââ ââââââââââââââââââââââââââââ âââââââââââââââââââââââ â 850
âââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ¤
â INCIDENTS   lap 6 Â· T7 Â· 2x Â· â¶ 30 s        lap 14 Â· T12 Â· 1x off track Â· â¶ 30 sâ 940
âââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ¤
â      SAVE            SHARE            OPEN IN COSWORTH            DEEP DIVE     â 1080
âââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
```
Data: header from session YAML and `.ibt` weather medians; RESULT and POSITION BY LAP from `vault\field\f*.json` (practice: PACE STORY = lap times vs PB/optimal instead); PACE VS FIELD from the same log (class best, medians, n); corners from `/analysis/lap` thresholds (C-30), video pairs cut `-c copy` from the S1 session mp4 and the reference lap's clip (if the reference has no video, this lap plays alone); incidents from the S1 sidecar; SAVE = `/api/rec/save`, SHARE = `/share/make`, COSWORTH only when installed, DEEP DIVE = workbench on the worst corner. Timing: `.ibt` read starts when the file stops growing (P0-09), engine â¤ 5 s, cuts â¤ 10 s, screen up â¤ 60 s.

### 3b. Before driving - HOME

```
âââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ 0
â PADDOCK                          Sat 11 Oct 2026 Â· 19:42            Rig OK Â· 104 fpsâ 60
âââââââââââââââââââââââââââââââââââââ¬ââââââââââââââââââââââââââââââââââââââââââââââ¤
â NEXT RACE                         â hero: paddock\home\hero.jpg, his car from   â
â IMSA iRacing Series               â the replay, 2560 wide, cropped 1060x480,    â
â Corvette Z06 GT3.R  OWNED         â no text over the car (credited stand-in     â
â Road Atlanta  OWNED               â until T-08 captures one)                    â
â Sat 20:45 local Â· in 1 h 03       â                                             â
â every 2 h (:45) Â· 45 min          âââââââââââââââââââââââââââââââââââââââââââââââ¤ 540
â PB 1:19.549                       â #4  PETER Â· PRATT MILLER MOTORSPORTS         â
â field median 1:20.9 (n=64)        â Corvette Z06 GT3.R  [iRacing car picture    â
â top 5 % 1:18.7 Â· NEXT top 25 % â0.6â 480x270 from /cars]   last driven Fri 10 Octâ 640
âââââââââââââââââââââââââââââââââââââ¼âââââââââââââââââââââââ¬âââââââââââââââââââââââ¤
â THIS WEEKEND Â· REAL WORLD         â THIS WEEK            â LAST OUTING          â
â IMSA Â· Petit Le Mans  Sat 12:10   â 4 h 12 Â· 118 laps    â Fri 10 Oct Â· Race P3 â
â  10 h Â· GTP LMP2 GTD Pro GTD      â 1 PB                 â Road Atlanta Corvetteâ
â  imsa.com Â· 6 Oct                 â last week 2 h 40     â 1:19.549 PB Â· 2x inc â
â WEC Â· Bahrain 8 h     Sat 11:00   â                      â REVIEW               â
â F1 Â· US GP quali      Sat 23:00   â                      â                      â
â GTWC Â· Barcelona race TBC         â                      â                      â 920
âââââââââââââââââââââââââââââââââââââ´âââââââââââââââââââââââ´âââââââââââââââââââââââ¤
â                    ââââ  LAST DRIVE Â· Corvette Â· Road Atlanta  ââââ              â
â Sessions & laps Â· Vault Â· Performance Â· Stats                        [QR phone] â 1080
âââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
```
Data: NEXT RACE from `official.cs` (his series, cadence, local start, owned folders), PB from career cache, field from `bench.cs`; real-world lines from `realworld.json` (local time, TBC, one preview line with source and date); THIS WEEK and LAST OUTING from career cache (short runs excluded); big button = RIG ON / LAST DRIVE / GET IN by state. Owned/not is a word, not a colour. "in 1 h 03" is a countdown, absolute date beside it.

### 3c. Deep dive - Workbench (top screen) and phone

Top screen DRIVER page (existing frame, deepened):
```
ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
â DRIVER GRIP BRAKES TYRES SUSP SPLITS VIDEO RACE CAREER PRO     lap 14 vs best 9 (+0.33)â
ââââââââââââââââââââ¬ââââââââââââââââââââââââââââââââââââââââââââ¬ââââââââââââââââââââ¤
â GPS map 480x480  â gap (filled green/red)                    â video this lap    â
â coloured by gap  â speed  lap14 gold Â· lap9 dotted Â· lap12 2ndâ 420x236           â
â (or any channel, â throttle / brake + ABS shading            â video best lap    â
â colour bar)      â steering Â· wheel force                    â 420x236           â
â events marks     â gear Â· RPM                                â cursor readouts   â
ââââââââââââââââââââ¤ shared cursor Â· linked zoom Â· OFFSET +12 mâ lap/ref/diff      â
â CORNERS by loss  â ââ â â¶ â¶â¶ 0.5x 1x 2x 4x 8x  REV            â events list       â
â T10a â0.21 ...   â                                           â ABS T1 Â· lockup T7â
ââââââââââââââââââââ´ââââââââââââââââââââââââââââââââââââââââââââ´ââââââââââââââââââââ
```
Added pages/blocks: SUSPENSION gets PSD (shockVel/VertAccel, Hz vs dB, per corner of the car) and AERO BALANCE (front share %, lap average above 200 km/h); TYRES gets SETUP A/B (bias/TC/ABS changes, lap and per-corner medians before/after, n); PRO gets soft events, constants, lookup tables; RACE gets WHERE THE FASTEST CAR GAINS (per corner, his median vs the class-fastest car's median). Every added number has a hand-checked test value.

Phone (REVIEW âº session, 390 wide):
```
âââââââââââââââââââââââââââ
â Race Â· Road Atlanta     â
â P3 Â· 1:19.549 PB        â
â map coloured by gap     â
â T10a â0.21  T1 â0.12 â¦  â
â laps table (time S1-S3) â
â CHANNELS: pick two â    â
â trace / X-Y, pinch zoom â
â SAVE  SHARE             â
âââââââââââââââââââââââââââ
```

### 3d. While racing - TV view (4th screen = top monitor)

```
ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
â LIVE Â· BATTLE  P3 #4 PETER  vs  P4 #22 SMITH  0.6 s        lap 12 / 18   (label) â 70
ââââââââââââââââââââââââââ¬ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ¤
â TIMING TOWER 560 wide  â REAL GPS MAP 1300x700, flat, no hills                   â
â P1 #7  LEE     leader  â every car a dot in class colour, number beside it,      â
â P2 #22 SMITH   +3.2    â Peter gold with #4, leader marked, battle pair ringed,  â
â P3 #4  PETER   +3.8 â  â start/finish, sector ticks, pit lane                    â
â P4 #11 KHAN    +4.4    â                                                         â
â â¦ pos Â· number Â· name  â                                                         â
â gap Â· interval Â· last  â                                                         â
â Â· PIT flag Â· class stripâ                                                        â
ââââââââââââââââââââââââââ´ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ¤
â PETER  gear 4  212 km/h  throttle ââââââââââ  brake ââââââââââ  last 1:19.9  REC â 1080
ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
```
Rules: label LEADER (default) / BATTLE (two same-class cars within 0.8 s for â¥ 5 s, his first) / CHASE (car behind him within 1.5 s) / TRACK (wide, every 60 s for 10 s); a label holds 8-15 s. All arrays read from one frozen frame at 10 Hz; canvas capped at 30 fps; measured cost â¤ 5 % of one core; sim fps unchanged on the Performance page. Between stints (out of the car, tape present): AUTO TV on, UI hidden, replay of his last two laps on the sim screens; the panel reads REPLAY; stops the instant IsOnTrack. The 2560-wide race screens are not touched while he drives.

---

## 4. Handoff items, benchmark, driver card and every critique point

| Item | Section | Card(s) | Decision |
|---|---|---|---|
| H1 Official racing + race weekend + real-world calendar | K, L | H-01, H-02, H-04, H-05, H-06, H-07, K-03, K-04 | Keep; parser hardened with source step and HTML fallback; `official=1` after tests; never registers |
| H2 HOME THIS WEEK + LAST OUTING | L | P0-04, H-07 | Restore in Phase 0 |
| H3 Studio | H | ST-01..ST-06 | Build after REPLAY fixes; S0a first |
| H4 Pro comparison | G | PR-01..PR-03 | Build in three cards |
| H5 Cosworth integration | F | W-18, W-19 | Open method verified first; ready workbook in Pi's user folder; video-sync researched |
| H6 Vault video player + compare | A | P0-10 | Phase 0 |
| H7 Events list PAUSE/JUMP | C | W-11, W-12 | Offline then live |
| H8 SHARE overlay / YouTube / iMessage | I | SH-01, SH-02 | Finish |
| H9 Live TV view 4th screen | J | P0-03, T-01..T-05, T-07 | Hide now; rewrite |
| H10 Racing line | O | F-01 | Peter's 30 s check or remove the state |
| H11 REPLAY live fixes | P | T-06 | Fix live |
| H12 After-race review while in sim + quick wins | A | P0-09 | Phase 0 |
| H13 AI races rebuild + deck choices | Q | A-01, A-02 | Rebuild one preset with his choice |
| H14 Hero shot / phone search / Vault vs Performance | L, N, R | T-08, P0-07, P0-06 | Capture; fix; differentiate |
| H15 Design tokens + welcome driver card + polish + deck batch | R, L, M | DS-01..05, H-08, K-01, K-02 | Build; driver card restored |
| H16 Stats/career iRating/SR/results | E | P0-08, W-14, W-15 | Back-fill from old .ibt years back + CSV import |
| H17 Real maps from .ibt, corner names, weather | C | P0-05, W-01 (conditions line inside) | Phase 0 maps; conditions line |
| H18 Housekeeping | S | HK-01..04, DS-05 | Schedule |
| H19 Voice, phone away | T | HK-04 | Decision only |
| Benchmark (ROADMAP Â§1, Peter "yardstick sucks") | D | H-03 | Fix, not drop |
| Welcome driver card (C-10) | L | H-08 | Build |
| C1.1 recording rules unconfirmed | - | - | Wrong: confirmed 2026-10-11; ignore |
| C1.2 vault/recorder on unverified | - | - | Wrong: lead checked irdash.ini; ignore |
| C1.3 benchmark dropped | D | H-03 | Accepted |
| C1.4 driver card dropped | L | H-08 | Accepted |
| C1.5 TV rewrite has no card | J | T-01..T-05 | Accepted |
| C1.6 MAIN 32-key constraint | M | K-01, K-02 | Accepted: layout picture, one yes |
| C1.7 Cosworth ready workbook dropped | F | W-19 | Accepted, failable |
| C1.8 which REA | Â§8 Q1 | - | Asked |
| C1.9 PLAN Q2 (other drivers) and Q11 (budget) | Â§8 Q2, Q10 | - | Asked |
| C1.10 bake-off, vision critique, judge S1 | Â§6 research; P0-01 | R-04; P0-01 | S1 is the bake-off calibration; vision critique is R-04 |
| C1.11 replay TV between stints | J | T-05 | Accepted |
| C2.1 Pi depth asserted not specified | C | W-02..W-13 | Explicit list, each a card |
| C2.2 Cosworth more than file open | F | W-19 | Accepted |
| C2.3 SDK Gaming trial first | J, Â§7 | - | Option 2, needs yes; Paddock view built to beat it |
| C2.4 phone analysis shallow | N | W-16, W-17 | Accepted |
| C2.5 career gives up too early | E | W-14, W-15 | Years back from old .ibt + CSV import |
| C2.6 pro data half / fastest car in session | C, G | W-13; Â§7 Garage 61 | Fastest-car comparison built from vault\field; Garage 61 as option |
| C3.1 Pi opens "in seconds" unproven | F | W-18 | Gated on verified method, explorer.exe fallback |
| C3.2 cache price wrong | Â§6 | - | Corrected ($0.006/$0.003) |
| C3.3 L cards exceed context | Â§5 | all | No L cards; every card â¤ M |
| C3.4 iRating from YAML asserted | E | P0-08 | Field names verified first |
| C3.5 S4 PDF parser assumption | K | H-01 | Source acquisition step, HTML fallback, rollover rule |
| C3.6 TV key with hidden view | M | K-02 after T-04 | Key only when the view exists |
| C3.7 "none dropped" wrong | Â§4 | - | This table is complete |
| C3.8 recorder "done-in-progress" overstated | A | P0-01 | Live check is the first card |
| C4.1 V-03 too big / duplicates S1 | A | S1 + P0-01/02 | S1 is the build; follow-ups only |
| C4.2 V-19 undefined files | H | ST-01..03 | Files named; split |
| C4.3 V-24 mixes parser and UI | K | H-01 / H-02 / H-07 | Split |
| C4.4 V-33 one L design card | R | DS-01..04 | Split by page group |
| C4.5 gates test code not journey | Â§5 | all | Every gate has numbers and a journey Peter could fail |
| C4.6 no visible win in Phase 0 | Â§5 | P0-05, P0-04 | GPS maps and HOME rows in Phase 0 |
| C4.7 missing dependencies | Â§5 | all | Dependencies resolved in the tables |
| C4.8 no cards for TV/benchmark/driver card/phone depth/FFT/Cosworth workbook | - | T-*, H-03, H-08, W-16/17, W-07, W-19 | All present |
| C5 cost unrealistic, lead excluded | Â§6 | - | Rebuilt with the lead's calibration; lead shown paid and free |
| C6 top 10 | - | - | All accepted except #1 (recording rules) |

---

## 5. Build phases and cards

Rules for every card: one OpenCode session; Files list is exhaustive ("new file" marked); gate = named test with numbers AND a journey Peter could fail; needs-Peter stated; no L cards. "Live" = rig free; "away" = `Assert-RigFree -NeedAway`. Live-gated cards are batched into the away windows listed after Phase 6. Each phase ends with a lead gate: run-all green plus the phase journey on the real rig.

### Phase 0 - stop the bleeding, first visible win (starts from S1)

| ID | Title | Files | Depends | Size | Gate (test + journey) | Needs Peter |
|---|---|---|---|---|---|---|
| P0-01 | S1 judged live: real session recording + SAVE | `dash\src\recorder.cs`, `tests\recorder-test.ps1`, `docs\vault.md`, `docs\tasks\log\P0-01.md` | S1 | S | After his next real session: one mp4 in `vault\sessions`, ffprobe duration = in-car seconds Â± 2 %, sidecar lap count = iRacing's; `dash recsave` â SAVED, file in `vault\saved`; recorder cost â¤ 3 fps on the Performance page. Journey: he presses SAVE on the phone after the session, sees SAVED, the session plays on the phone within 2 min | Drive one session, press SAVE once |
| P0-02 | HEVC playback proven; h264 fallback | `dash\src\recorder.cs`, `dash\www\phone\app.js`, `tests\recorder-test.ps1` | P0-01 | S | Headless Chrome (top screen) and Safari on the iPhone play a hvc1 test mp4 to the end; if either fails the default encoder becomes h264_nvenc and the test asserts it. Journey: he taps a saved session on the iPhone and it plays, no black frame | Tap play once on the iPhone |
| P0-03 | Hide the fake TV view | `dash\src\irdash.cs` (TvView), `dash\www\v2\tv.js`, `tv.css`, `index.html`, `tests\tv-test.ps1` | none | S | `/api/do?c=tvview` answers 400 "TV view rebuild"; tv.js not loaded; tv-test reduced to the off state; keys-test unchanged (no TV key exists today). Journey: pressing anything cannot show the fake map | none |
| P0-04 | HOME THIS WEEK + LAST OUTING back | `dash\src\home.cs`, `dash\www\v2\home.js`, `home.css`, `tests\home-test.ps1` | none | S | THIS WEEK hours/laps/PBs equal numbers worked by hand from `career-cache.tsv`; LAST OUTING is the last real outing (short runs excluded); 0 overlaps; copy-audit 0. Journey: HOME shows both rows with his real numbers | none |
| P0-05 | Real GPS track maps from .ibt Lat/Lon/Alt | new `dash\src\gpsmap.cs` (+ `$src` in `dash\build.ps1`), `dash\src\irdash.cs` (TrackMaps hook), `dash\www\v2\map.js`, new `tests\gpsmap-test.ps1` | none | M | Road Atlanta GPS outline vs library outline after scale/rotation fit: mean â¤ 5 m, max â¤ 15 m; every Lovely apex within 20 m of the GPS line; Sonoma (no library) gets a map from his laps; Alt stored, never drawn as hills; 6 pictures `tests\shots\gps-*.png`. Journey: the Workbench map is the shape he drove | none |
| P0-06 | Vault vs Performance identity | `dash\www\v2\theme.css`, `vault.css`, `vault.html`, `perf.css`, `perf.html`, `tests\quickwins-test.ps1` | none | S | Top 160 px of the two pages differ in â¥ 40 % of pixels; each page's first element names the page and its headline number (Vault: GB used + count; Performance: last average fps). Journey: he opens each from HOME and says which he is on without reading small text | none |
| P0-07 | Phone car/track search fix | `dash\www\phone\app.js`, `app.css`, `dash\src\phone.cs`, `tests\phone-test.ps1` | none | M | "atl" â Road Atlanta in â¤ 3 taps and â¤ 1.5 s; 10 common combos; no result row without a START path. Journey: Corvette + Road Atlanta in 3 taps, START lit | none |
| P0-08 | Session YAML field names for iRating/SR/results | new `tools\yaml-fields.ps1`, `docs\research\ibt-channels.md` (append) | none | S | Reads 5 old .ibt at BelowNormal; prints the player's `DriverInfo.Drivers[]` IRating, LicString, LicLevel, LicSubLevel, LicColor and the results block names; writes exact names and one sample row to the doc. Journey: none (fact list for W-14) | none |
| P0-09 | After-race laps while sim still in + quick wins deployed (C-27/C-29) | `dash\src\vault.cs`, `dash\www\v2\debrief.js`, `vault.js`, `tests\review-test.ps1`, `tests\quickwins-test.ps1` | none | M | review-test and quickwins-test 0 FAIL incl. "session over, sim process still running â laps within 30 s". Journey: after a race he sees "3 laps saved" before leaving the sim | none |
| P0-10 | Vault video player + compare two clips (C-08) | `dash\www\v2\vault.js`, `vault.css`, `workbench-video.js`, `dash\src\vault.cs`, `tests\vault-test.ps1` | P0-01 | M | Generated clip: cursor-video sync â¤ 1 frame at 10 points; two clips locked by LapDistPct (the one ahead waits), â¤ 0.1 s apart at 3 corners; no self-compare. Journey: a saved lap plays with the dot on the map; a second lap added shows T1 at the same moment | none |

Phase 0 gate: run-all 0 FAIL; his next session recorded and saved; GPS map and HOME rows seen on the rig by the lead.

### Phase 1 - signature a: the debrief

| ID | Title | Files | Depends | Size | Gate | Needs Peter |
|---|---|---|---|---|---|---|
| D-01 | Debrief engine: result, position by lap, pace vs field | new `dash\src\debrief.cs` (+`$src`), read `field.cs`, `analysis.cs`; new `tests\debrief-test.ps1` | P0-05 | M | On a real race log: position per lap equals the log; pace = his best and median vs class best and median with n; practice â pace story vs PB/optimal; 3 numbers hand-checked; `GET /debrief?id=` in â¤ 5 s. Journey: none yet | none |
| D-02 | Corner video pairs | `dash\src\debrief.cs`, `dash\src\recorder.cs` (sidecar read only), `tests\debrief-test.ps1` | D-01, P0-01 | M | For the 3 worst corners: this lap and the reference lap cut `-c copy` from the session mp4 / reference clip, 2 s before the corner start to 1 s after its end, durations within 0.5 s; both start at the corner start; BelowNormal, out of the car only; no reference video â this lap alone. Journey: none yet | none |
| D-03 | Debrief screen to the 3a wireframe | new `dash\www\v2\debrief-v4.js`, `debrief-v4.css`, `index.html` hook, `sessionreview.js` (hand-off), `tests\debrief-test.ps1` | D-01, D-02 | M | Pretend session end with a real fixture: screen up â¤ 60 s, no press; boxes within 20 px of the wireframe; 0 overlaps; copy-audit 0; pictures `tests\shots\db-*.png` compared by the lead with the mockup. Journey: he gets out; 60 s later the screen tells the race and the three corners loop | none |
| D-04 | Incidents with video + one-press bar | `debrief-v4.js`, `dash\src\debrief.cs`, `dash\src\share.cs` (route reuse), `dash\src\vault.cs` (recsave), tests | D-03 | M | Incident clips with lap/corner; SAVE â SAVED idempotent; SHARE queues `/share/make`; COSWORTH only when installed; DEEP DIVE opens the Workbench on the worst corner. Journey: SAVE once â SAVED; DEEP DIVE lands on T10a | none |
| D-05 | Debrief deck row + phone debrief | `deck-intro\plugin.html` (ANALYSIS row), `dash\www\phone\app.js`, `tests\deck-screens-test.ps1`, `tests\phone-test.ps1` | D-04 | S | keys-test 0 dead; phone shows the same debrief within 60 s. Install batched in K-02. Journey: the four presses work on deck and phone | none (Install later) |
| D-06 | Debrief live check | `docs\tasks\log\D-06.md`, test fixes only | D-05 | S live | After his real race: up â¤ 60 s; corners named right; videos loop; position story matches iRacing's results. Journey: he fails it if any clip is the wrong corner or the result is off by one place | One real race |

Phase 1 gate: D-06 passed; Peter says the three corners match what he felt.

### Phase 2 - signature b: HOME before driving

| ID | Title | Files | Depends | Size | Gate | Needs Peter |
|---|---|---|---|---|---|---|
| H-01 | Official schedule source + parser hardening | `dash\src\officialcore.cs`, `official.cs`, `tests\official-test.ps1`, `docs\official.md`, fixtures in `data\official\fixtures\` | none | M | Source step: season page â PDF link, else HTML season table; S4 fixture parsed, 10 series hand-checked (car, track, cadence); 2027 S1 absent â "not published", no crash. Journey: none | none |
| H-02 | His series, ownership, next race | `dash\src\official.cs`, `officialcore.cs`, `src\official.cs`, `tests\official-test.ps1` | H-01 | M | His series = raced in 90 days âª favourites; owned from car/track folders (read-only); next start and countdown correct for 3 hand-worked cadences across DST. Journey: none | none |
| H-03 | Benchmark (yardstick) fix | `dash\src\bench.cs`, `dash\www\v2\bench.js`, `bench.css`, `data\fieldlaps.tsv`, `data\pro-refs.json`, `tests\bench-test.ps1` | none | M | Per combo: PB, top 5 % / 25 % / median (n â¥ 30, n shown), similar-iRating pace, IMSA ref with source, NEXT = nearest yardstick above with gap, PB history; 4 combos hand-checked; nothing shown without n. Journey: Road Atlanta card tells him the next goal in 5 s | none |
| H-04 | HOME next-race data | `dash\src\home.cs`, `tests\home-test.ps1` | H-02, H-03 | S | `/home` carries series, car, track, local start, countdown, owned, PB there, field median there with n. Journey: none | none |
| H-05 | Real-world calendar fetch | new `dash\src\realworld.cs` (+`$src`), `data\official\realworld.json`, new `tests\realworld-test.ps1`, `docs\official.md` | none | M | Fixture parsers for F1 (Jolpica/OpenF1), IMSA, WEC, GTWC + one live fetch each (cached 6 h, BelowNormal, never in a session); local times; TBC when unpublished; "as of" when stale; one terms line per source. Journey: none | none |
| H-06 | Preview lines by a cheap model at fetch time | `dash\src\realworld.cs`, `tests\realworld-test.ps1`, `docs\COPY-RULES.md` (one rule) | H-05 | M | Official RSS â one call per event per week (DeepSeek V4.1 Flash, fixed prompt, â¤ 2 lines, facts only); copy-audit regexes run on the output and reject; source + date kept; off without the key or his yes; cost logged. Journey: "IMSA Â· Petit Le Mans Â· Sat 12:10 Â· 10 h Â· GTP LMP2 GTD Pro GTD Â· imsa.com 6 Oct" | A yes; ~Â£1 a year |
| H-07 | HOME v4 layout (3b) | `dash\www\v2\home.js`, `home.css`, `dash\src\home.cs`, `tests\home-test.ps1` | H-04, H-05, P0-04 | M | Boxes within 20 px of the wireframe; one big button by state; 0 overlaps; copy-audit 0; pictures idle / rig up / session open. Journey: next race and countdown read in 3 s; one press starts his usual drive | none |
| H-08 | Welcome driver card | `dash\www\v2\home.js`, `dash\src\home.cs`, `carpics.js` | H-07 | S | Name from YAML, number live (verify 4), team text, live car picture from `/cars` or typography only; offline on second launch. Journey: the card shows the car he is in now | none |

Phase 2 gate: HOME on a weekend names a real next race with the right local time (lead checks against iRacing's UI) and the real-world weekend.

### Phase 3 - signature c: deep dive, career, Cosworth, phone depth

| ID | Title | Files | Depends | Size | Gate | Needs Peter |
|---|---|---|---|---|---|---|
| W-01 | Workbench the single surface + conditions line | `dash\www\v2\sessions.js`, `vault.js`, `sessionreview.js`, `workbench.js`, `dash\src\analysis.cs`, `tests\workbench-test.ps1` | P0-10 | M | Sessions row, Vault card, Review ANALYSIS open `workbench.html?id&lap` with the right lap (3 tests); sessions.js own trace view removed; conditions line (air/track temp, wind, skies, wetness) hand-checked on 2 files. Journey: the same screen with the same lap from anywhere | none |
| W-02 | Multi-lap overlay 3+ | `workbench.js`, `dash\src\workbench.cs` | W-01 | M | Up to 6 laps, fixed colour ramp, legend, readouts per lap; â¥ 50 fps in headless Chrome with 6 laps Ã 8 traces. Journey: laps 7, 9, 12 added; lap 12's loss visible | none |
| W-03 | Time-offset slide with auto-align | `workbench.js`, `deck-intro\plugin.html` (OFFSET key label) | W-02 | M | O slides the reference; AUTO aligns at the brake point in view; offset shown in m and s; a known 30 m shift recovered within 2 m. Journey: OFFSET AUTO on the deck lines the brake traces up | none |
| W-04 | Navigator 0.5-8x incl. reverse | `workbench.js`, `workbench-video.js`, `tests\workbench-test.ps1` | W-01 | S | 0.5/1/2/4/8 forward and reverse; map, traces and video in step (reverse video by 10 Hz seeks); cursor rate within 5 %. Journey: a corner scrubbed backwards at half speed | none |
| W-05 | Soft events (equation-defined) | `dash\src\protools.cs`, `analysis.cs`, `workbench.js`, `tests\analysis-test.ps1`; events saved in `vault\events\` | W-01 | M | "Brake > 0.9 && Speed > 60" with rises/falls/min/max; saved per car; events listed and move the cursor; 3 hand-checked. Journey: typed once, listed on every lap | none |
| W-06 | Constants + lookup tables | `dash\src\protools.cs`, `workbench-pro.js`; tables in `vault\tables\*.csv` | W-05 | M | CONST() per car; 1D/2D tables with snap/interpolate; values match hand calc. Journey: a gear table turns RPM into wheel speed | none |
| W-07 | PSD/FFT display | new `dash\src\psd.cs` (+`$src`), `workbench-pro.js`, `workbench.js` (SUSP block), `tests\analysis-test.ps1` | W-01 | M | Radix-2 FFT, Hann, 60 Hz on shockVel/VertAccel per lap or zoom range; synthetic 3 Hz sine peaks at 3.0 Â± 0.1 Hz; log/linear axes. Journey: a damper frequency peak per corner of the car | none |
| W-08 | Aero balance | `dash\src\deepdive.cs`, `workbench.js` (SUSP), `tests` | W-01 | M | Cosworth Plus formula: ride-height change Ã spring rate (car constant, hidden where unknown) â front share %, lap average above 200 km/h; one hand value on a real file. Journey: a front-share number per lap, blank when unsourced | none |
| W-09 | Setup A/B from logged changes | `dash\src\deepdive.cs`, `career.cs`, `workbench.js` (TYRES/SETUP block), tests | W-01 | M | dcBrakeBias/TC/ABS changes within a session and between sessions of one combo; lap and per-corner medians before/after with n; sentence only by C-30 thresholds. Journey: "Bias 56.0 â 55.0 Â· T1 â0.06 Â· T10a +0.04 (4 vs 5 laps)" | none |
| W-10 | Map by any channel + XY/histogram polish | `workbench.js`, `workbench-pro.js` | W-02 | M | Map colour = gap / speed / any channel with colour bar; XY shows the fit equation; histogram time or %; pictures. Journey: map by ABS cut shows where ABS works | none |
| W-11 | Events list with PAUSE/JUMP (offline) | `dash\src\analysis.cs`, `replayjump.cs`, `workbench.js`, `deck-intro\plugin.html` (EVENT keys), `tests\replay-jump-test.ps1` | W-05 | M | Events from incidents/off-track/lock-ups/ABS/passes; â EVENT / EVENT â¶ / PLAY-PAUSE / JUMP; dry run proves the 3 SDK messages, recorded by the test. Journey: none live yet | none |
| W-12 | Events live replay jump (away) | `dash\src\replayjump.cs`, `tests\replay-jump-test.ps1 -Live` | W-11, T-06 | S away | In a spectated AI race the jump lands within 1 s (ReplaySessionTime read back), camera on his car. Journey: tap an ABS event; the replay shows it 3 s before | Away window |
| W-13 | Fastest car in my session per corner | `dash\src\field.cs`, `workbench-race.js`, `debrief.cs` | D-01 | M | Per corner his median vs the class-fastest car's median, sorted, n per car; pretend race within 0.02 s. Journey: RACE page "where the fastest car gains", top 3 corners | none |
| W-14 | Career back-fill from old .ibt | new `dash\src\stats.cs` (+`$src`), `career.cs`, `dash\career-cache.tsv` (new columns, migration), new `tests\stats-test.ps1` | P0-08 | M | Every old .ibt â iRating, LicString, type, finish, SOF, incidents; AI sessions excluded; 3 rows hand-checked; BelowNormal, skips online-only, never the newest while the sim runs. Journey: none yet | none |
| W-15 | Stats screen + CSV import | `workbench-career.js`, new `dash\www\v2\stats.js`, `stats.css`, `dash\src\stats.cs`, `home.cs`, tests; import from `vault\import\*.csv` | W-14 | M | iRating and SR trends (no chart < 5 points), results table with SOF, wins/podiums/incidents; a members CSV merges without duplicates. Journey: his iRating curve back to his first .ibt | Optional: drop a CSV export |
| W-16 | Phone session review + corner table | `dash\www\phone\app.js`, `app.css`, `tests\phone-test.ps1` | D-04 | M | Timing table, map by gap, corner table by loss, conditions line; numbers equal the top screen. Journey: on the sofa he reads where the time went | none |
| W-17 | Phone channel picker + XY/histogram | `dash\www\phone\app.js`, `/analysis/channels` | W-16 | M | Any two channels, trace or XY, pinch zoom, readout; a Road Atlanta lap renders in < 2 s. Journey: lateral g vs speed in 4 taps | none |
| W-18 | Cosworth open method + button everywhere | `dash\src\vault.cs`, new `docs\cosworth.md`, new `tests\cosworth-test.ps1`, `workbench.js`, `sessionreview.js`, `debrief-v4.js` | none | S live | Try `PiToolbox.exe "<ibt>"`, else `explorer.exe "<ibt>"`; Pi's window title confirms the file; button visible on four surfaces when installed, hidden when not; video-sync fact recorded (Lite none). Journey: OPEN IN COSWORTH â Pi shows the lap; no dialog | none (rig free) |
| W-19 | Cosworth ready workbook in Pi's user folder | `docs\cosworth.md`, new `tools\cosworth-workbook.ps1`, `dash\src\vault.cs` | W-18 | M live | Pi's user folder found; its iRacing Lite workbook inspected; text/XML â Paddock copy with speed/throttle/brake/steering/gear/delta and PB as datum where supported; binary â documented stop (failable); nothing in iRacing's folders. Journey: Pi opens with Paddock's worksheets | none (rig free) |

Phase 3 gate: the deep-dive journey of section 2C on the real rig; Pi opens a lap one press.

### Phase 4 - signature d: TV view, replay fixes, hero shot

| ID | Title | Files | Depends | Size | Gate | Needs Peter |
|---|---|---|---|---|---|---|
| T-01 | TV data engine | new `dash\src\tv.cs` (+`$src`), `dash\src\irdash.cs` (`/tv`), `tests\tv-test.ps1` | none | M | One frozen frame per tick: pct, pos, class pos, gap, interval, pit, laps for every car; battles = same class within 0.8 s â¥ 5 s; 10 Hz; pretend race + real YAML. Journey: none | none |
| T-02 | Timing tower | new `dash\www\v2\tvview.js`, `tvview.css`, `theme.css` | T-01 | M | Per 3d: pos, number in class colour, name, gap, interval, last, PIT; his row gold; tabular; 0 overlaps. Journey: a friend reads P3 and the gap | none |
| T-03 | Map with every car | `tvview.js`, `map.js` | T-01, P0-05 | M | Real outline, every car dot, class colour, Peter gold #4; 30 fps cap; flat. Journey: dots match the relative overlay | none |
| T-04 | Director label + inputs lower-third + cost | `tvview.js`, `dash\src\tv.cs`, `index.html` (panel swap) | T-02, T-03 | M | Label rules of 3d; his inputs bar; dashboard Chrome â¤ 5 % of one core; sim fps unchanged (Performance page); panel swap leaves other panels in place (before/after pictures). Journey: BATTLE appears when two cars close up | none |
| T-05 | Replay TV between stints | `dash\src\tv.cs`, `replay.cs`, `tvview.js` | T-06 | M away | Out of the car with a tape: AUTO TV on, UI hidden, last 2 laps play; panel reads REPLAY; stops within 1 s of IsOnTrack. Journey: real pictures of his race between stints | Away window |
| T-06 | REPLAY live fixes (C-03) | `dash\src\replay.cs`, `tests\replay-test.ps1`, `docs\replay.md` | none | M away | replay-test -Live 0 FAIL: COCKPIT/CHASE, CAMERA >, AUTO TV 0x10, HIDE UI 0x08, MY LAST INCIDENT. Journey: COCKPIT gold and the picture is the cockpit | Away window |
| T-07 | TV live check in a real race | `docs\tasks\log\T-07.md`, test notes | T-04 | S live | At 3 moments the tower equals iRacing's standings and the dots match the relative; fps unchanged. Journey: he fails it if his position or gap is wrong at any check | One real race |
| T-08 | Hero shot capture (away) | `dash\src\home.cs`, `replay.cs` (PHOTO path), `paddock\home\hero.jpg`, `paddock\home\credits.json` | T-06 | M away | Replay of his last session, UI hidden, chase/TV camera on his car, screenshot â¥ 2560 wide, upright, saved with a credit entry. Journey: HOME shows his own car | Away window; iRacing screenshot setting must be on (ask if not) |

Phase 4 gate: T-07 passed; replay-test -Live 0 FAIL.

### Phase 5 - Studio, pro comparison, sharing

| ID | Title | Files | Depends | Size | Gate | Needs Peter |
|---|---|---|---|---|---|---|
| ST-01 | Studio S0a: replay survival + one fixed-camera lap | new `dash\src\studio.cs` (+`$src`), `recorder.cs` (named take), `replay.cs`, new `tests\studio-test.ps1`, `docs\studio.md` | T-06, P0-01 | M away | Tape still loaded 10 min after the flag (fact in docs); one lap filmed from TV1 by ReplaySearchSessionTime + a recorder take; duration = lap Â± 1 s; upright; UI hidden. Journey: a film of his best lap in the Vault with no press | Away window |
| ST-02 | Shot-list engine + presets | `dash\src\studio.cs`, `tests\studio-test.ps1` | ST-01 | M | CINEMATIC/ONBOARD/BROADCAST from the corner model; cue times from the lap's own time at pct; 3 tracks; slow-mo at the worst corner. Journey: none | none |
| ST-03 | S1 live film | `dash\src\studio.cs`, tests | ST-02 | S away | â¥ 4 camera changes within 0.5 s of cues (CamGroupNumber vs ReplaySessionTime); < 150 MB. Journey: the film cuts where the plan says | Away window |
| ST-04 | S2 editor page | new `dash\www\v2\studio.html`, `studio.js`, `studio.css`, `dash\src\studio.cs` | ST-02 | M | Timeline with corner names, camera chips, drag cuts, slow-mo/freeze, PREVIEW on map, FILM IT queues; deck next/prev; pictures. Journey: T10a changed to cockpit, FILM IT | none |
| ST-05 | S4 combine + optional overlays | `dash\src\studio.cs`, `share.cs` (overlay reuse), tests | ST-03 | M | Side-by-side / PiP / vs PB locked by pct; title and end cards; xfade; clean copy kept; ffprobe checks. Journey: cockpit + chase in one file | none |
| ST-06 | S5 race highlights | `dash\src\studio.cs`, `field.cs` (passes, incidents) | ST-05 | M | Start, each pass/incident, last lap, finish; â¤ 3 min; real race log. Journey: a 2-minute reel of his race | none |
| PR-01 | Pro find + fetch | new `dash\src\pro.cs` (+`$src`), `vault\bin\yt-dlp.exe` (checksum), `data\pro-videos.json`, new `tests\pro-test.ps1` | none | M | yt-dlp fetched and verified (approved); search + score (official channels, pole/quali, newest); 720p video-only, throttled, never during an online session. Journey: Road Atlanta Corvette â one onboard in `vault\pro` | none (approved) |
| PR-02 | Pro align | `dash\src\pro.cs`, `tests\pro-test.ps1` | PR-01 | M | Motion-energy vs speed/brake cross-correlation; confidence vs pro-refs; a time-warped copy of his own clip aligns within 0.3 s at 3 corners. Journey: none | none |
| PR-03 | Pro render | `dash\src\pro.cs`, `share.cs`, tests | PR-02 | M | Side-by-side locked by pct; labels "PETER Â· 1:19.549 sim" / "<driver> Â· <time> real car Â· guide only"; gap per corner; "approximate" when low. Journey: each corner together, him beside a real driver | none |
| SH-01 | Share: Windows share sheet + YouTube upload page | `dash\src\share.cs`, `workbench-share.js`, new `tools\share-sheet.cmd` | P0-01 | M live | SHARE opens the Windows share sheet for the file via explorer; YOUTUBE opens youtube.com/upload in the default browser and Explorer with the file selected; refused while driving. Journey: two presses to the upload page; Paddock never posts | none (rig free) |
| SH-02 | Share: phone Photos / share sheet / codec | `dash\www\phone\app.js`, `dash\src\share.cs` | SH-01, P0-02 | M | Share videos always h264; share sheet when available, Save to Files with the message otherwise; whole-session SHARE cuts the last lap or chosen clip. Journey: Make share video â Share â iMessage | none |

Phase 5 gate: a CINEMATIC film and a pro comparison in the Vault; a share video sent from the phone.

### Phase 6 - deck, official deck, friends, AI, phone final

| ID | Title | Files | Depends | Size | Gate | Needs Peter |
|---|---|---|---|---|---|---|
| K-01 | MAIN 32-key layout proposal | `build-deck.ps1 -Preview`, new `docs\deck-main-proposal.md`, `tests\keys-test.ps1` | D-05, T-04 | S | One 8Ã4 picture: new keys SAVE, DEBRIEF, VAULT, TV, HOME in place of never-pressed keys (proposal: SHOWCASE, SAVE RESET POINT, BACK TO RESET POINT, TEAR OFF, CLEAR PIT); keys-test 0 dead. Journey: Peter says yes or marks changes once | One yes |
| K-02 | Deck batch: add-on 1.8 + MAIN per yes | `deck-intro\plugin.html`, `install.ps1` ($ver), `build-deck.ps1`, `keys\keys.map`, `tests\deck-speed-test.ps1 -Live` | K-01 | M live | keys-test / deck-screens-test 0 FAIL; lead runs install + build-deck; deck-speed timings written. Journey: SAVE, VAULT, TV, DEBRIEF one press each | Install click |
| K-03 | Official deck screen | `deck-intro\plugin.html`, `src\official.cs`, `dash\src\official.cs`, `tests\deck-screens-test.ps1` | H-02 | M | Tiles for his series with "in 12m"; tap opens iRacing's Official page by verified UI only out of a session; no REGISTER; 0 dead keys. Journey: one press shows what's on; nothing registers | none |
| K-04 | Official page UI map check (away) | `src\official.cs` (OfMap), new `docs\iracing-ui-map.md` | K-03 | S away | UIA reads the Official page elements; dry run stops at the verified Register control, no click. Journey: none | Away window |
| F-01 | Racing line resolution | `src\guest.cs`, `dash\www\v2\guest.js`, `docs\USER-GUIDE.md`, `tests\friends-live-test.ps1` | none | M live | Peter's 30 s check says the line shows â START sends it and the state persists per iRacing's toggle; else the LINE state is removed and START stops sending. Journey: the line state matches the sim or is not shown | 30-second drive check |
| A-01 | AI dialog survey finish (away) | `docs\research\ai-dialog.md`, `src\testdrive.cs` (read) | none | M away | Opponents / time of day / track conditions pickers mapped, scoped to the modal; iRacing left on Home (picture). Journey: none | Away window |
| A-02 | AI preset one press | `src\irdeck.cs`, `src\mydrive.cs`, `mydrive\presets.ini`, `deck-intro\plugin.html` (RACE SETUP AI words) | A-01 | M away | Peter's preset set on every verified control and read back before launch; one press â in the car; no blind clicks; words only for verified controls. Journey: one press, his usual AI race | Chooses the preset; away window |
| PH-01 | Phone final | `dash\www\phone\*`, `dash\src\phone.cs`, `tests\phone-test.ps1` | SH-02, W-17, D-05 | M | phone-test 0 FAIL; re-pair works; LAPS â REVIEW; sessions listed with SAVE/SAVED; copy-audit 0. Journey: review, save, share from the sofa | none |

Away windows (10 min each, batched; Peter gives them when `state` shows sim=False and he is away):
1. T-06 REPLAY fixes (plan 2 windows)
2. W-12 events jump + T-05 replay TV (one spectated AI race)
3. T-08 hero shot + ST-01 replay survival and first take
4. ST-03 Studio live film
5. K-04 Official UI map
6. A-01 AI survey
7. A-02 AI preset
Planned: 8 windows; budget 12 (reruns). Peter actions outside windows: one session + SAVE (P0-01), one tap on the iPhone (P0-02), one real race watched (D-06), one real race watched (T-07), 30 s line check (F-01), one yes on the MAIN picture (K-01), one Install click (K-02), one preset choice (A-02), one yes on preview lines (H-06).

### Phase 7 - design system, housekeeping, later

| ID | Title | Files | Depends | Size | Gate | Needs Peter |
|---|---|---|---|---|---|---|
| DS-01 | Tokens: dashboard, debrief, review | `theme.css`, `index.html`, `debrief-v4.css`, `sessionreview.css`, dashboard css | D-03 | M | 0 raw hex outside theme.css in these files; 0 overlaps; copy-audit 0; before/after pictures `p-*.png`; side-by-side with F1 TV timing. Journey: dashboard and debrief look like one family | none |
| DS-02 | Tokens: workbench | `workbench*.css` | W-10 | M | Same gate; side-by-side with Pi Toolbox | none |
| DS-03 | Tokens: HOME, Vault, Performance, Sessions, TV | `home.css`, `vault.css`, `perf.css`, `sessions.css`, `tvview.css` | H-07, T-04 | M | Same gate | none |
| DS-04 | Tokens: phone + deck screens | `dash\www\phone\app.css`, `deck-intro\plugin.html` colours | PH-01 | M | Same gate; deck one gold, one black | none |
| DS-05 | Delete dead `dash\www` v1 + `cars.js` | `dash\www\*.js/.html/.css` â `backup\`, v2 script tags | none | S | grep 0 references; run-all unchanged. Journey: none | none |
| HK-01 | Click-through every screen | new `tests\clickthrough-test.ps1`, `tests\run-all.ps1` | DS-03 | M | Every visible button on every served page clicked; 0 no-ops; screen list = all pages. Journey: he cannot find a button that does nothing | none |
| HK-02 | Stale tests and flaps | `tests\data-test.ps1`, `video-page`, `friends-live-test.ps1` (x4 margin), others | none | S | run-all 3Ã in a row 0 FAIL. Journey: none | none |
| HK-03 | Root tidy + docs refresh | `tools\`, `backup\`, `docs\USER-GUIDE.md`, `OPERATIONS.md`, `ARCHITECTURE.md`, `deck-speed.md` | HK-01 | S | No referenced path breaks (keys.map, logon task, profile paths); the guide matches the rig. Journey: the guide describes what he sees | none |
| HK-04 | Oversight job, voice, Tailscale decisions | docs only | all | S | Decisions written; nothing built. Journey: not shown | Two yes/no |

Card totals: 79 cards - 58 M, 21 S; 20 live-gated (M 11, S 9).

---

## 6. Cost

Prices: Hands DeepSeek V4.1 Flash $0.30 in / $1.20 out, cache hit $0.006 peak / $0.003 off-peak, 60 % cache hits. Blended input: peak 0.6Ã0.006 + 0.4Ã0.30 = $0.1236/M; off-peak 0.6Ã0.003 + 0.4Ã0.30 = $0.1218/M. Sanity check of the calibration: an M card at ~3 M tokens in and 150 k out costs 3Ã0.124 + 0.15Ã1.20 = $0.55, consistent with S1 ($0.40 at 45 min, still iterating) â **$0.60 per M card, $0.25 per S card**, no L cards. Reruns: +25 % offline, +70 % live-gated. Reviewer GLM-5.3 $0.03 per card.

Per card:
- M offline 0.60Ã1.25 + 0.03 = **$0.78** Â· M live 0.60Ã1.70 + 0.03 = **$1.05**
- S offline 0.25Ã1.25 + 0.03 = **$0.34** Â· S live 0.25Ã1.70 + 0.03 = **$0.455**

Lead (Claude Opus as judge): $1.50 per card check, $5 per phase gate while paid; free inside the weekly allowance after 2026-10-14 23:00 UTC.

| Phase | Cards | M off / M live / S off / S live | Hands + review | Lead (paid) | Phase total paid-lead |
|---|---:|---|---:|---:|---:|
| 0 | 10 | 4 / 0 / 4 / 2 | 3.12 + 0 + 1.36 + 0.91 = **$5.39** | 15.00 + 5 = $20.00 | $25.39 |
| 1 | 6 | 4 / 0 / 1 / 1 | 3.12 + 0.34 + 0.455 = **$3.92** | 9.00 + 5 = $14.00 | $17.92 |
| 2 | 8 | 6 / 0 / 2 / 0 | 4.68 + 0.68 = **$5.36** | 12.00 + 5 = $17.00 | $22.36 |
| 3 | 19 | 15 / 1 / 1 / 2 | 11.70 + 1.05 + 0.34 + 0.91 = **$14.00** | 28.50 + 5 = $33.50 | $47.50 |
| 4 | 8 | 4 / 3 / 0 / 1 | 3.12 + 3.15 + 0.455 = **$6.73** | 12.00 + 5 = $17.00 | $23.73 |
| 5 | 11 | 8 / 2 / 0 / 1 | 6.24 + 2.10 + 0.455 = **$8.80** | 16.50 + 5 = $21.50 | $30.30 |
| 6 | 8 | 2 / 4 / 1 / 1 | 1.56 + 4.20 + 0.34 + 0.455 = **$6.56** | 12.00 + 5 = $17.00 | $23.56 |
| 7 | 9 | 5 / 0 / 4 / 0 | 3.90 + 1.36 = **$5.26** | 13.50 + 5 = $18.50 | $23.76 |
| **Build subtotal** | **79** | 48 / 10 / 13 / 8 | **$56.02** | **$158.50** | **$214.52** |

Research and spec work (cheap models via `tools\or-run.ps1` / `or-web.ps1`):

| Job | Model | Cost |
|---|---|---:|
| Already spent: R1 review ($0.38), R2 calendars ($0.07), D1 draft (~$0.45), D2 critique (~$0.03) | mixed | $0.93 |
| R-01 Official S4 PDF/HTML source map for H-01 | DeepSeek V4.1 Flash + web | $0.10 |
| R-02 Real-world sources per series + terms lines for H-05 | same | $0.15 |
| R-03 Pi Toolbox workbook format, user folder, command line for W-18/19 | same | $0.10 |
| R-04 Vision critique of real screens (~40 shots) | Qwen VL / Gemini Flash | $0.50 |
| R-05 yt-dlp scoring + official onboard channel list for PR-01 | same | $0.10 |
| R-06 pro-refs refresh (2026 official timing) for H-03 | same | $0.15 |
| R-07 This spec critiqued once more | GLM-5.3 | $0.05 |
| R-08 Mockups from real data: debrief, HOME, TV (3 jobs) | DeepSeek V4 Pro | $0.60 |
| R-09 79 card files written from this spec into `docs\cards\` | DeepSeek V4 Pro | $2.40 |
| **Research to come** | | **$4.15** |
| Runtime: preview lines (H-06) | V4.1 Flash | ~$0.02/week |

Firm totals:
- **Allowance-lead (lead free after Wednesday): $56.02 + $4.15 = $60.17 â $61.** OpenRouter balance needed: $61 (account holds ~$15 today: top up $50).
- **Paid-lead: $60.17 + $158.50 = $218.67 â $219.**
- Away windows Peter must give: **8 planned, 12 budgeted** (10 min each), plus the nine one-off actions listed under Phase 6.

---

## 7. Options that need Peter's yes (ranked by value per pound)

| Rank | Option | Cost | What it gives | Recommendation |
|---|---|---|---|---|
| 1 | Preview lines by a cheap model at fetch time (H-06) | ~Â£1 a year, OpenRouter key already on the PC | Factual one-liners for real-world races, source and date, copy-rules filtered | Yes |
| 2 | Members-site CSV export, one time, dropped into `vault\import\` | Â£0, 5 minutes of his time | Results Paddock never saw, merged into the stats screen (W-15) | Yes when W-15 lands |
| 3 | SDK Gaming Live Timing 14-day trial (new customers) | Â£0 for 14 days, then Â£8.33/month if kept | The benchmark Paddock's TV view must beat; vendor-maintained tower and map; installed and tested only in away windows; Max Cars 63 effect measured | Yes to the trial, no subscription until T-07 is judged |
| 4 | Garage 61 free account (Peter signs in himself; Paddock reads exported laps only) | Â£0 | Other drivers' community reference laps for the Workbench overlay | Only if he wants named faster drivers beyond the fastest car in his own sessions (W-13 is free) |
| 5 | Tailscale (personal) for the phone away from home | Â£0; Install click | Review and save from anywhere; no public ports, pairing token | Later (HK-04), yes in principle |
| 6 | Local speech model (Windows speech or whisper.cpp binary) into fixed actions | Â£0 software, CPU cost measured | Voice control without cloud | Later; Windows speech first, no download |
| 7 | PresentMon (console build) | Â£0 download | True frame times for stutter | Low value now; only if he sees stutter |
| 8 | Pi Toolbox Plus | Â£5/month | Video sync inside Pi, ghost laps | No: Paddock already syncs video |
| 9 | Second PC ghost-spectating the same account | Â£300-800 + iRacing's written yes | Real live TV pictures of his race | Not before iRacing answers in writing (he emails the five questions in `fourth-screen-tv.md` Â§6) |

---

## 8. Questions for Peter and where Peter can help

Questions (each with the recommended answer):
1. **Which REA?** `morluto/rea` (general reverse-engineering agent) is the only one found. Recommended: use its method only on files Paddock owns (.ibt, .ld); never on Cosworth or MoTeC binaries.
2. **Compare against own laps only, or other drivers too?** Recommended: own laps plus the fastest car in each of his sessions now (free, W-13); Garage 61 later if he wants named drivers.
3. **SDK Gaming 14-day trial as the TV benchmark?** Recommended: yes, installed in an away window, judged next to T-07, no subscription unless it wins.
4. **Preview lines generated by a cheap model (~Â£1/year)?** Recommended: yes.
5. **MAIN layout: may SHOWCASE, SAVE RESET POINT, BACK TO RESET POINT, TEAR OFF and CLEAR PIT make room for SAVE, DEBRIEF, VAULT, TV, HOME?** Recommended: yes; he marks any key he wants kept on the K-01 picture.
6. **First AI preset?** Recommended: Corvette Z06 GT3.R, Road Atlanta, 20 cars, fair strength, 20 min, day, clear.
7. **Racing line 30-second check (START, press LINE, say whether the line shows)?** Recommended: yes once; until then Paddock shows no line state.
8. **Studio may film his best lap when he is away 10 min with the sim still on the session?** Recommended: yes.
9. **Hero shot captured from his replay with UI hidden while he is away?** Recommended: yes.
10. **Monthly budget?** Recommended: one $50 OpenRouter top-up covers the whole build at allowance-lead ($61 total); the paid-lead variant ($219) only if he wants it finished before Wednesday's reset.

Where Peter can help (one line each):
- Email iRacing support the five questions in `docs\research\fourth-screen-tv.md` Â§6 and ask for a written answer.
- Top up OpenRouter by $50 (account holds ~$15).
- Drive one session and press SAVE once (P0-01); tap one saved session on the iPhone (P0-02).
- Export his results/history CSV from the members site and drop it in `vault\import\` (W-15).
- Give 8-12 away windows of 10 min (sim closed, away from the PC); say when the next one is.
- Say yes/no on the MAIN picture (K-01) and click Install once (K-02).
- Choose the AI preset (A-02); do the 30-second line check (F-01).
- Confirm iRacing's screenshot setting is on if T-08 asks (never changed by us).
- Leave the sim open on the session after a race once so Studio can film (ST-01).

---

## 9. Risks and mitigations

1. **iRacing UI or build changes break UI automation (official page, AI wizard, Test Drive).** Verify every dialog before a click; screenshots on failure; UI cards isolated (K-03/04, A-01/02); no blind clicks; HTML/PDF parsers behind fixtures.
2. **The debrief misses the 60 s target or shows the wrong corner.** Engine budget â¤ 5 s, cuts `-c copy` â¤ 10 s, measured in D-03; corner clips keyed by the sidecar's lap offsets, tested on a generated clip; D-06 live gate.
3. **Recorder frame-rate cost or black capture.** Measured in P0-01 (â¤ 3 fps); black detection with the plain fix line already built; HEVC falls back to h264 if playback fails (P0-02).
4. **Disk and OneDrive.** Budgets 30/150/50 GB in S1; Vault never in OneDrive; online-only files skipped; iRacing files never written.
5. **Schedule sources drift (iRacing PDF layout, series pages, season rollover).** Fixtures per source, "as of" and TBC, one live fetch per test, rollover rule in H-01; nothing behind a login.
6. **Live-gated cards eat away windows (history: 6 live replay failures).** +70 % budget, batched windows, mock tests first, every live card leaves a PENDING command when the window is missed.
7. **Cheap model writes C# 6+, weak tests or claims without proof.** C# 5 rule in every card, `-NoDeploy` compile in the gate, GLM review of every diff, the lead judges by running the test and looking at the picture.
8. **Analysis overclaim.** Sentences only by C-30 thresholds; every derived channel has a hand-checked value; unsourced constants hide the channel; copy-audit on every screen.
9. **TV view costs frames or reads inconsistent arrays.** One frozen frame per tick, 30 fps canvas cap, CPU measured in T-04, fps compared on the Performance page in T-07; no camera message ever sent while he drives.
10. **Second PC / same-account spectating policy unknown; preview text copyright.** No second PC until iRacing answers in writing; preview lines are generated facts with source and date, never lifted text, filtered by the copy-audit regexes.