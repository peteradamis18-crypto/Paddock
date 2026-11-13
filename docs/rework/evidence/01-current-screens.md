# Paddock today: every screen, and an honest critique (2026-11-12, evidence only, no code changed)

Pictures are in `docs\rework\evidence\current\`. Top-screen pictures are new, taken 12 Nov 2026 at 1920x1080 from the
live irdash in headless Chrome. The rig was idle (`state`: sim=False, telemetry=off, checked before every picture).
Every page request that could act was blocked (see "How the pictures were taken" at the end). Deck pictures are the
newest existing renders from `tests\shots` and `docs\deck`, because I may not rebuild or press anything.

Test data note: pages show Peter's real data (545 sessions, 4 race videos). The in-car view is the built-in demo
(`?demo=1`, a made-up 21-car field and a made-up track), so its numbers are not real.

## Top screen (1920x1080, dashboard monitor above the rig)

**top-home.png** - HOME. The "what now" screen when no session is running.
- On it: PADDOCK title, five top links (MY RACES in a gold box, SESSIONS, VAULT, PERFORMANCE, date and clock), a huge
  gold RIG ON button, driver card (16 Peter Adamis, licence C 2.66, 1465 iR), a car photo, four status lines (iRacing UI
  off, Recording, Phone, four coloured dots), NEXT RACE, LAST OUTING with REVIEW, THIS WEEK totals, WATCH / REAL WORLD
  (an F1 weekend schedule).
- Critique: about 14 separate things for a screen with one real job (press RIG ON). The car photo box is half empty
  (photo, then a black rectangle). The Phone line shows a developer instruction ("run tools\phone-allow.cmd") to a
  disabled user. NEXT RACE shows the word "starting" in huge type next to a Legends Ford race Peter does not drive;
  the real answer ("what am I racing next") is not there. LAST OUTING says "No timed lap" while the Vault shows a race
  from 5:18 PM that day. The four status dots and the REAL WORLD F1 block are small and cover roughly the lower third
  for something Peter did not ask for; the right half of that band is simply empty. MY RACES looks "selected" but is
  just a link. Nothing here is readable at 1 m except RIG ON and the clock.

**top-drive-demo.png** - in-car dashboard, default layout (`?demo=1`).
- On it: eight blocks at once: top strip (flag, time left, position, lap, incidents, fuel laps, track/weather, small
  status dots), standings (21 rows), relative, track map, delta, sector boxes, fuel/lap strip, car panel (rev bar,
  throttle/brake trace, ABS/TC/oil/water/volts/humidity).
- Critique: this is the classic overloaded telemetry wall. Standings and car-panel text is about 12-14 px, unreadable
  from the seat. The car panel is the worst offender: oil pressure, voltage, humidity are not things a driver acts on in
  a race. "Fuel laps" shows a dash. Standings and Relative both list the same drivers. Several empty boxes ("-", ":-.---").
  The corner names are fake demo text ("Demo corner names (synthetic)") printed on the screen.

**top-drive-demo-drive.png** - the calmer in-car layout (`?demo=1&drive=1`, `drive.js`).
- On it: track map with car dots, a battle list (the cars around Peter), class position, gap ahead, delta bar, time left,
  fuel, last/best lap.
- Critique: much better: big numbers, six things, readable. But it is a second, competing in-car design that sits next
  to the dense one with a hidden switch; nobody can tell which is "the" screen. Fuel is empty ("after one clean lap").
  Map labels are tiny. I could not tell from code which one Peter sees live by default; it must be confirmed.

**page-sessions.png** - SESSIONS (`sessions.html?embed=1`).
- On it: title and totals (545 sessions, 32.8 h, 794 laps), top-right buttons KM/H, CAR NO. 4, FRAME RATE >, VAULT >;
  two rows of filter chips (14 cars, 15 tracks = 4 rows of pills), a table of every session, and a "BENCHMARK" side
  panel (best lap, Top 5% / Top 25% / within 250 iRating, tick-bars, "next goal").
- Critique: about a quarter of the screen is filter pills with counts. The table is mostly junk: rows of "SHORT RUN 0
  laps, 7 s". Text is truncated ("Nordschleife Industr...", "LONE QUALI..."). Benchmark panel is cut off at the bottom and
  its "yardstick" tick-bars need a legend to read. The header buttons are a mix of settings (KM/H, CAR NO.) and
  navigation (FRAME RATE, VAULT), with no obvious primary action. Name overlap with Vault, Races, Review.

**page-vault.png** - VAULT (`vault.html?embed=1`).
- On it: gold banner (VAULT, 50.1 GB, 106 moments, storage bar 50.1 of 60 GB, SESSIONS >), filter tabs (All, Keepers 61,
  Races 30, Best laps 53, Videos 40), two dropdowns, a search box (typing), S/M/L size, then thumbnails grouped by day with
  labels (WIN, +90 IRATING, FASTEST EVER, TOP 3 EVER, stars).
- Critique: the storage bar is at 83 % and shown in the banner; that is useful. But every thumbnail is the same cockpit
  view so nothing is recognisable; a day group of two cards leaves the right two-thirds of the row empty; the badges
  (TOP 3 EVER on three neighbours) repeat rather than inform. Four different ways to filter the same 106 items, plus
  search, for a user who should never type. It overlaps with MY RACES (videos) and SESSIONS (laps). Name means nothing
  to Peter ("vault").

**page-perf.png** - PERFORMANCE (`perf.html?embed=1`).
- On it: header with "115 fps" in a navy band, last-session block (115 / 97 / 95 fps, GPU 49 %, CPU 37 %, ping, "where
  it was slowest" bars), "what else was running" table, an fps line chart by session with track and car chip rows, a
  "before and after" list of changes, and a checklist with AUTO badges.
- Critique: honest and useful in content, but it is a developer's engineering console: six panels, 11-13 px text,
  "1 % low", "% of one core". The fps line chart has two days of points and a legend entry "Change" that does not
  appear to draw anything: little information per pixel. Paddock itself is listed at 50 % of a core, which is awkward. The
  header style (navy band, white spaced letters) differs from Vault (gold band) and Sessions (gold small-caps).

**page-races.png** - MY RACES (`races.html`).
- On it: title, two instruction boxes ("SHARE ON YOUTUBE ... Drag the file onto YouTube", "DELETE FROM PC: click it, then
  click again"), Races / Practice tabs, four rows each with WATCH, SHARE ON YOUTUBE, DELETE FROM PC.
- Critique: the clearest screen Paddock has: big targets, plain words, one job. Problems: the two instruction boxes
  explain buttons that should be self-explanatory (and "drag the file onto YouTube" is a manual step); the double-click
  delete; identical buttons repeated on every row (12 buttons for 4 races); no thumbnail so rows are
  indistinguishable ("Road Atlanta ... Road Atlanta"); no CLOSE button visible in the page itself (PageHost supplies one);
  half the screen is empty. A data mismatch to check: the 09:28 race shows best 1:33.639 here, but Sessions and the
  Vault show 1:33.919 as that race's best.

**page-coach.png** - REVIEW / Coach (`coach.html?id=last`, opened by the deck's REVIEW / DEBRIEF).
- On it: venue and car (title truncated to "Road Atl..."), buttons KEEP VIDEO, ALL LAPS, ALL THE DATA, a warning line (only 1
  lap compared, "treat it as a hint"), BIGGEST LOSS "T10a 0.23 s", a one-sentence tip ("Brake later..."), a big gold
  WATCH button, SHOW ME IN THE DATA, six statistics tiles, a strip of 14 corner pills, and SHOW ALL THE DATA.
- Critique: the right idea (one finding, one tip, one WATCH button). Spoiled by: four different "go to the data" controls
  (ALL LAPS, ALL THE DATA, SHOW ME IN THE DATA, SHOW ALL THE DATA); the truncated track name; unexplained
  BRAKE / ENTRY / APEX / EXIT pills; "compared with the best lap ever" built from one lap, which the page itself calls a
  hint. Six stat tiles (pit lane time 0:05) are filler.

**page-sessionreview.png** - Session Review (`sessionreview.html?id=...`, also opened by the old debrief hand-off).
- On it: lap table with 24 grey mini-sector bars per lap, and in the centre the message "No complete lap: ALL THE DATA below
  has every second of the drive", three small buttons bottom right (SAVED, RACE, ALL THE DATA).
- Critique: broken-looking: a table of 10 laps next to a message saying there is no complete lap; all mini-sector bars are
  empty grey; low-contrast text; "below" points at nothing. Looks like a third review screen beside Coach and the debrief.

**page-rawdata.png** - ALL THE DATA (`rawdata.html?id=...`).
- On it: a whole-drive timeline of speed, pedals, steering, gear, RPM; lap strip; track map; readouts; ZOOM / arrow / WHOLE
  DRIVE buttons.
- Critique: a decent first look at a whole drive. Lap labels along the top overlap into each other ("LAP 2 1:38.1LAP 3").
  Big red block at the start is the pit-box time with no explanation. It duplicates the Analysis page's DRIVER tab in a
  worse, simpler form.

**page-workbench-driver / -grip / -braking / -tyres / -suspension / -splits / -career / -pro / -race.png** - ANALYSIS
(`workbench.html`, the "workbench"). Nine tabs in one screen: DRIVER, GRIP, BRAKING, TYRES, SUSP., RACE, CAREER, PRO
(+ VIDEO and share modes in code, not captured as they were blank).
- DRIVER: the one that looks like the pro tools (MoTeC / Garage 61 style): map coloured by gap, a cursor table (lap vs
  reference vs difference), gap/speed/throttle/brake/steering/wheel force/gear traces, events list. Good. Text is 11-14 px,
  so it is a lean-in screen, not a seat screen. The weather strip is overlapped by the OFFSET control (text collides).
- TYRES: the tyre-pressure and temperature grid with four wheel panels. Peter had the tyre panel taken out of the rig and
  the notes say the live feed has no surface temperatures; this page still shows the data. The charts on the right
  ("lap times over the stint", "fuel used per lap", "surface temperature") show only a text list: charts not drawn at
  all in this picture. Large blank gaps.
- CAREER: personal best by session (a 4-point step line), consistency band chart, 14-corner purple/red heat grid, totals
  tiles, races list. With 4 sessions of data these are near-empty charts; "best lap over time" is the kind of chart
  Peter called invented.
- PRO: lateral G against speed scatter with a regression line ("y = -0.00000587 x^2 ... R^2 0.184"), a speed histogram,
  "maths channels" with a formula box (typing), Excel / CSV export. Statistics for their own sake: an R^2 of 0.18 tells a
  driver nothing.
- RACE: timing tower with every driver and a car picture (identical for all 18), position-by-lap and gap-by-lap charts,
  a passes list, a per-corner comparison against the car ahead and the leader. The strongest page after DRIVER: it matches
  what race tools show.
- Critique overall: one 135 KB JavaScript file plus eleven more, nine tabs with different layouts and header text (a
  PADDOCK ANALYSIS yellow header, a different one from Vault and Perf), a lap picker row and a second lap-compare control
  that is easy to get lost in. Controls are tiny text links. There is no step-by-step path from "what should I fix"
  to the right tab; that job is Coach, which then links here. `page-workbench-braking`, `-grip`, `-suspension`, `-splits`
  are further variants that repeat the same header with panels of the same kind.

**Not captured (said plainly):** the HOME "intro" animation and the after-race debrief (`debrief-v4.js`) did not appear
with the query switches I tried (`?intro=1&hold=1`, `?debrief=demo`: both just gave HOME); no picture of the PageHost CLOSE
button; no picture of `phone/` (the phone app, 63 KB `app.js`, live; 161 older "phone-*" shots exist in `tests\shots`);
no side-screen gallery picture (it draws on the side screens, which I may not touch; `docs\gallery-preview.png` exists).
`top-home-design-v3-mock.png` is the design mock-up from 15 Oct, not a live picture.

## Stream Deck XL (32 keys)

Newest existing renders; I did not rebuild or press anything.

**deck-main.png** (made 12 Nov 09:57 from `build-deck.ps1`) - MAIN.
- On it: 8 x 4 grid, all gold words on black, no icons: HOME, AI RACE, AI LEVEL, CAR TRACK, OFFICIAL, FRIENDS, KIDS, MORE /
  GET IN, GET OUT, RESET CAR, RESTART, NEXT SESSION, RACE NOW, PAUSE, LEAVE / FUEL TO FINISH, TIRES, FAST REPAIR, CLEAR PIT,
  OVERLAYS, REVIEW, RACES, REPLAY / VOL -, VOL +, MUTE SPOTTER, SPOTTER -, SPOTTER +, SAVE SPOT, BACK TO SPOT, GHOST.
- Critique: no grouping by colour or shape, so everything has equal weight (the build file has colour groups, the preview
  does not show them): the most-used key (GET IN?) looks the same as KIDS. Mixed text sizes (OFFICIAL, OVERLAYS, RESTART, GET OUT
  smaller than the rest) look accidental. Three things mean "start": AI RACE, RACE NOW, NEXT SESSION. Five keys (VOL -, VOL +,
  MUTE SPOTTER, SPOTTER -, SPOTTER +) are one control. SAVE SPOT / BACK TO SPOT / GHOST are meaningless words to a new
  reader. REVIEW and RACES and OVERLAYS are three different openers for three different screens with similar names.
  No live state is visible (no sim on/off).

**MORE and LEAVE pages** - no picture exists in the repo. From `build-deck.ps1`: MORE holds SORRY, GOOD RACE, THANKS, MUTE,
SHOWCASE, SOUND, LOCK, RELATIVE, WIPE, SEAT LOWER/HIGHER, TIMING, STANDINGS, FUEL BOX, TIRE BOX, IN-CAR, WEATHER, ANALYSIS, VAULT, AC.
LEAVE holds BACK, QUIT TO MENU (twice), KIDS MODE, SHUT DOWN PC, SLEEP PC. Critique from the list alone: MORE is a
junk drawer (chat phrases, windscreen tear-off, seat height, six sim-box hotkeys F1 to F11 named like screens); VAULT sits
in MORE while RACES sits on MAIN; KIDS is on both MAIN and LEAVE.

**deck-races.png / deck-races-all.png** (12 Nov 09:58) - RACES page: two race keys at the top left, ALL SESSIONS, "298 GB FREE
ON DISK" and a red EXIT bottom right; the other 27 keys are empty black. Disk figure is stale versus 279 GB on HOME. A list
screen that could be one tall page.
**deck-analysis.png / deck-analysis-pages.png** (6 Nov) - the Analysis remote: lap and corner arrows, PLAY, ZOOM, SPEED,
COMPARE, OFFSET, MAP COLOUR. Dense (24 keys, 8 different greys); wide text ("LAP 7 1:19.549", PLAY) is cut across key bezels so
it reads "PL AY". This is the Stream Deck steering a screen that has its own mouse controls (duplication).
**deck-friends.png** (12 Oct, old) - FRIENDS: who, car, track and "4 START" in four rows. Each row label is one tiny key with
a coloured underline; the START key spans six keys and its text is cut by bezels. Reads as a form, not as one press.
**deck-ac.png, deck-ailevel.png, deck-sound.png, deck-overlays.png, deck-mydrive.png, deck-pick-home.png,
deck-smart-states.png** - the other add-on screens (rig-room air-conditioner, AI strength, sound, overlays, My Drive, pick
lists). Each is its own layout with its own vocabulary (EXIT, BACK, HOME, EXIT FRIENDS, EXIT RACES in different colours/positions).
Inconsistent: exits differ, red for some, grey for others.

## The 10 worst problems overall

1. **Nobody decided what each screen is for.** Sessions, Vault, My Races, Review/Coach, Session Review, All the data, Analysis,
   Performance all list the same drives from a different angle, so Peter has to learn which door to use.
2. **Names do not help.** Vault, Workbench/Analysis, Coach/Review/Debrief, Sessions vs Races, DEBRIEF vs REVIEW vs RACES.
3. **Three header styles, no shared grid.** Gold banner (Vault), navy banner (Performance), gold small-caps (Sessions),
   plain title (Races), no title (Coach), yellow bar (Analysis). Different font sizes, spacing, close-button handling.
4. **Text is too small for a seat 1 m away on most pages** (Sessions, Perf, Analysis, standings in the in-car view): 11 to 14 px.
5. **HOME has too many things and one broken meaning.** NEXT RACE "starting", empty photo box, a developer command shown to Peter,
   RIG ON competing with seven other blocks.
6. **Two in-car dashboards**, the dense 8-panel one and the calm `drive=1` one, with a hidden switch between them.
7. **Invented or low-value charts**: CAREER's best-lap-over-time and consistency charts, PRO's R^2 regression on 4000 dots,
   the fps line chart with a "Change" legend, six filler stat tiles on Coach.
8. **Four "show me the data" buttons on Coach, and three data screens (Session Review, All the data, Analysis) behind them.**
9. **Broken or empty states that look like bugs**: Session Review ("No complete lap" beside a 10 lap table), TYRES charts not
   drawn, Vault day groups with blank space, Races deck page 27 empty keys, deck pictures with text cut by bezels.
10. **The deck has no visual language**: equal gold text on black, three keys meaning "start", five keys for one volume control,
    inconsistent EXIT/BACK, MORE as a junk drawer, no live state on MAIN.

## Dead, duplicated or suspicious code (evidence, not yet verified by deletion)

- **`dash\www\*` v1 (core.js, demo.js, index.html, map.js, style.css, ui.js, about 85 KB) is almost certainly dead.** `dash\irdash.ini`
  has `page=v2/`; the v1 default only applies when no page is configured. Same file names exist in `v2\` (core, demo, map, style, ui).
  Check one more time with a test before deleting.
- **`debrief.js` (213 lines) vs `debrief-v4.js` (467 lines)**: both loaded by `v2\index.html`; the comment in `debrief.js` says the
  after-session screen "is debrief-v4.js now" and only the old stint tracker and sample stay. Plus `debrief.css` + `debrief-v4.css`.
- **Three review screens**: `coach.html` (+coach.js/css), `sessionreview.html` (37 KB js), debrief-v4. Plus `rawdata.html` (26 KB)
  duplicating Analysis DRIVER.
- **`workbench.js` is 135 KB (1521 lines)** and, with `workbench-career.js` 34 KB, `workbench-pro.js` 49 KB, `workbench-race.js` 30 KB,
  `workbench-video.js` 24 KB, `workbench-channels.js` 18 KB, `workbench-share.js`, `workbench.css` 21 KB and `workbench-pro.css`, makes
  roughly 330 KB for one page. `vault.js` is another 77 KB. Together these two are about 60 % of all v2 script.
- **`bench.js`/`bench.css`** (Sessions' benchmark panel), `official.*`, `guest.*`, `mydrive.*`, `rig.*`, `keymsg.*`, `intro.*`,
  `tv.*`, `perflive.js`, `vaultlive.js`, `race.js`, `brief.js` are all loaded by HOME; `brief.js` and `race.js` are small leftovers
  to check for use.
- **`dash\www\phone\`** (app.js 63 KB, app.css 21 KB): a full second front end on a phone; its screens were not reviewed here.
- **The TYRES page and its data** (`workbench.js` and `/analysis` tyre channels) against Peter's decision to have the tyre panel taken out.
- **Design folders**: `docs\design\home-new.*`, `docs\design\home-v3`, `drive-v1`, `docs\mockups`, `docs\design\deck-v2` hold old mock-ups
  and test shots; `tests\shots` has about 760 files (161 `phone-*`, 65 `live-*`, 59 `rp-*`, 50 `deck-*`, 48 `audit-*`).
- **`preview.png` (299 KB) in `dash\www\v2`** and `dash\www\v2\sr-demo.json` (47 KB sample data) ship with the live web root.

## How the pictures were taken

A throw-away script (in the Claude scratchpad, not in the repo) started headless Chrome at BelowNormal priority using the
`tests\deck-harness.ps1` helpers, no profile kept, no window shown, no input to the physical screens. Two layers of blocking: (a) CDP
`Network.setBlockedURLs` for `/api/do`, `/api/rec/delete`, `/api/rec/backfill`, `/api/nav`, `/api/test`, `/api/sessions`,
`/api/open`, `/api/keymsg`, `/api/spot`, `/api/showcase`, `/api/watch/open`, `/api/guest`, `/api/doctor`, anything with `test/`, `scan`, `delete`,
`c=`, `/share/` and `/phone/`; (b) a page-side `fetch`/XHR allow-list that returned `{}` for everything not in a short read-only list and
for every non-GET. Every request was logged; blocked reads were reviewed and the read-only ones (health, home, guest, mydrive,
overlays, showcase poll, keymsg, tv, realworld) were then allowed. The page sync command `/workbench/cmd` stayed blocked.
No temporary profile remains. No file outside `docs\rework\evidence\` was changed.
