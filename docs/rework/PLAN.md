# Paddock rework: the build plan (v1, 2026-11-13)

This is the plan Claude abides by. It comes from 14 evidence reports in `docs/rework/evidence/` (7 research, 3 code
audits, 23 pictures of today's screens) and Peter's decisions in `docs/REWORK-LIST.md`. Nothing in it is built yet.
Every claim here traces to a report; every card ends with a test and a picture.

**Status:** waiting for Peter's answers to section 10, then wave 0 starts.

---

## 1. What we are fixing, in one paragraph

Paddock's engine room is sound: the recorder, the telemetry reader, the deck plumbing and the raw numbers (which come
straight from iRacing's own file, the same one Cosworth reads). What is broken is everything Peter touches: eight doors
into the same drives with names that mean nothing (Vault, Sessions, Review, Session Review, All the Data, Analysis,
Performance, My Races); four different looks, 203 colours and 51 text sizes; text as small as 10 px on the screen he
reads from the seat; the dense 8-panel race screen live by mistake while the readable one hides behind a switch; eight
different ideas of "best lap" (all three numbers shown for his 12 Nov race are wrong); constant chatter and disk work
on the race PC during races; a Stream Deck that can wake up on the SHUT DOWN page; and a test suite that mostly greps
source text. The rework is mostly **removing**: four doors, one look, one truth for each number, nothing heavy while he
drives, and a test with a picture for every screen in every state.

## 2. Rules (non-negotiable, on top of CLAUDE.md)

1. **Copy, don't invent.** Every screen is laid out after a named real tool or pro screen (section 4 names them).
   Where we have no reference we keep it plain.
2. **Nothing heavy while he drives.** No file writes over 1 MB, no deletes, no encodes, no process scans, no window
   z-order changes, no clicks. All of that waits for "session over" (`RigState.SessionOn == false`). Enforced by a
   test that measures irdash's own CPU, disk and request rate during a recorded session.
3. **One truth per number.** One lap store, one session index, one rig state, one format helper. A page may not
   compute a "best lap" itself.
4. **Seat text is 24 px or bigger** on the top screen (27-inch 1080p at about 1 m: 24 px = 7.5 mm letters, the research
   minimum); headline facts 48–72 px. Lean-in pages (deep data) may go to 20 px, never under. A test fails the build
   on smaller text.
5. **One look.** One stylesheet with 16 colour tokens and one type scale. A page may not declare its own colours.
   A test fails the build on a hex colour outside `design.css`.
6. **Never type, never hunt.** No search boxes, no formula boxes, no dropdowns with more than 4 items. One obvious
   action per screen; the deck and the screen use the same words.
7. **Honest numbers.** Estimates say "estimate". Comparisons across days show the conditions. No percentages that
   look like scores. No praise without a number.
8. **A picture for every state.** Every screen has a fixture per state and a headless screenshot in `tests/shots/rework/`.
   Claude reviews the pictures first, then Peter sees them, then it goes to the rig.
9. **Dead code goes first.** Nothing is rebuilt on top of something that should be deleted.
10. **Peter does three things by hand, once each:** signs in to Google for YouTube, clicks Install in Stream Deck
    (batched, at most once a week), and tells us which gold he likes. Everything else is automatic.

## 3. The new shape

Four doors on the top screen, the same four words on the deck. Everything else is a step behind one of them.

| Door | Job | Replaces |
|---|---|---|
| **HOME** | Clock, next race with a countdown, is the rig ready, one RIG ON. Nothing else. | HOME v3 (14 blocks), idle.js, official.js block, real-world block |
| **RACES** | Every drive, races first. Pick, watch, share to YouTube, trim, commentary, delete with undo, storage gauge. | Vault, My Races, Sessions' list, the deck's RACES/VAULT/REVIEW keys |
| **REVIEW** | After every drive: three cards (corner, what happened, seconds, try this), your lap on your best with the time-gap line and map, lap list. One "More data" page behind it. | Coach, Session Review, Debrief v4, All the Data, Analysis (9 tabs), Sessions' lap analysis, Vault's detail view |
| **RIG** | Is everything running, the performance black box, one sentence after any stutter, quiet-PC mode, AC. | Performance page, Rig Doctor screen, the AC screen |

Plus the two screens that are not doors: the **RACE SCREEN** (shown by itself while he drives) and the **start-up
sequence**. The phone app follows the same shell last.

**What goes (with the evidence):** the old v1 www root (10), `preview.png`, `official.js`, `idle.js`, `cars.js`,
`debrief.js`, `sr-demo.json`, the Vault detail view (50 KB of a second Analysis), Analysis PRO (formula box, R² 0.18),
CAREER's "best lap over time", the TYRES page, the TV worker and `/tv` (TV view is off), the NVIDIA ShadowPlay clip
path, 9 unused real-world parsers, 11 dead routes (09 §3), the deck's dead x2-confirm path and state keys (11), the
seven sim-box F-keys, SORRY/GOOD RACE/WIPE/SEAT/MUTE/SHOWCASE keys (0 presses in 3 weeks), the Cosworth launcher as a
button (stays as a plain "Open in Pi Toolbox" link with honest words), Coach Dave Delta integration (none possible:
no API, no export we can read; 12).

**What stays as it is:** the recorder's capture path, the SDK reader, `map.js`'s layered renderer, `spotcore`,
`deckwatch`, `keymsg`, the AC control, friends mode, replay keys, the flag table (lights, Paddock and glow share it).

## 4. The screens, ten levels deep

Each screen: purpose; the reference it copies; zones (pixel boxes on 1920×1080); states; data and where it comes
from; what it never shows; deck keys; failure cases; tests.

### 4.1 Start-up and HOME

**Copies:** F1 start lights (five lights, silence, dark; 07), Porsche cockpit restraint and watch-face hierarchy
("time first, few complications, empty space on purpose"; 07), StartLight/iRacePlan ("my series only, local time, one
countdown"; 07), Formula E "quiet, then data as it heats up" (07).

**Start-up (7 s, any key skips).** Black. Five gold lights appear left to right, one per second, each with a soft low
tone. One beat of silence. Lights out; the clock face fades up with the second hand already sweeping; the photo on the
side screens fades in. Sound through the existing sound module; off between 23:00 and 07:00.

**HOME zones.**
- Centre (600–1320 x, 120–840 y): the clock. A 720 px analog dial, warm-white indices, gold second hand, one small
  readout under 12 o'clock: the next-race countdown ("NEXT GREEN FLAG 1:42:09", 56 px) when a race is within 24 h.
  No brand, no logo. Within 30 min of a start a thin gold ring closes around the dial (the Formula E escalation).
- Left (96–560 x): **NOW / NEXT.** The session he is entered in or the next race in his series (series, track, car,
  local time, 36 px rows; the next one 96 px). At most 4 rows. Past rows fade.
- Right (1360–1824 x): **MY RACES.** His last three drives as three rows (date, track, result, 36 px) and one 64 px
  button "LAST RACE" that opens REVIEW. (This is also the door to RACES.)
- Bottom band (96–1824 x, 900–1000 y): **RIG.** One line: "Rig ready" in green with the four things it checked
  (iRacing, deck, spotter, overlays) as words, or one plain sentence of what is wrong and the one key that fixes it.
  Nothing technical.
- Top (y 40): PADDOCK · date · the four doors as four 32 px words (HOME is the current one, gold).
- One button only: **RIG ON** (already the one action; 240×96 px, gold) sits in the RIG band when the rig is off; it
  becomes **DRIVE** when the rig is on and a session is loaded.

**States** (one fixture and picture each): rig off; rig on, idle; race within 30 min (ring, countdown large); session
loaded, in garage (DRIVE); offline (irdash not reachable: the banner says "Paddock is not running. Press HOME on the
deck." in 48 px; RIG ON disabled); kids mode; after a drive (the REVIEW card is offered for 10 minutes: "Your race:
P3 from P9. REVIEW").

**Data.** Clock: local. Next race: the series Peter races (from his own results in the session index: the last 10
race series), their schedules from the OFFICIAL data irdash already reads (`official.cs`); **W0 confirms** that this
covers his series; if not, the countdown shows the next session he has a car and track for. iRacing's data API is
not used (paused client ids; 12). Rig line: the doctor's cached result (never a fresh run while a session is on).

**Never shows:** F1/real-world TV schedule (gone, Peter did not ask for it), developer text, phone pairing
instructions (moves to RIG), statistics tiles, "starting".

**Deck:** HOME key = the door; the deck's MAIN mirrors the RIG line state on the HOME key (green dot / red dot).

**Tests:** `home-test` rewritten: the 7 states at 1920×1080, one gold fill only, no text under 24 px, no overlap,
offline banner visible when the stream says `noserver`, RIG ON disabled when offline, countdown maths against a
fixed clock. Start-up: a 7 s capture (frames at 1 s) and a "skipped by key" check.

### 4.2 The RACE SCREEN

**Copies:** irdashies Standings (one list, class-grouped, your row highlighted; seen by Claude) and its fuel
calculator maths (08 §6); SDK Live Timing's pit columns and "you will rejoin here" ghost row (08); F1 live timing
(interval first, gap-to-leader second, purple only for session best, **no flashing**; 08); the pit board (position,
laps left, gap ahead and behind, one instruction; 03); mgyr's pit-window bar colours (08). Peter's decisions: no
tyres, no damage, flags only as a brief flash.

**One layout, 24 px margin, black.** Sizes from the research, checked against the real 27-inch panel (section 2.4).

| Zone | Box (x, y, w, h) | Content | Channels |
|---|---|---|---|
| A top strip | 24, 24, 1872, 96 | "P4 of 22 · CLASS P2" (64 px) · "LAP 31/52 · 12 TO GO" or time left · incidents chip "4x / 17" (amber within 3 of the limit) · session clock | CarIdxPosition, CarIdxClassPosition, Lap, SessionLapsRemainEx, SessionTimeRemain, PlayerCarMyIncidentCount, session IncidentLimit |
| B gaps | 24, 136, 912, 288 | AHEAD −1.4 and BEHIND +0.6, 96 px digits, green closing / red losing, each with number and short name (32 px), trend arrow from the last 3 laps | CarIdxF2Time, CarIdxLapDistPct, CarIdxEstTime |
| C fuel | 24, 440, 912, 360 | "FUEL +1.8 LAPS" (72 px, green) or "−0.6 LAPS" (red); laps of fuel and laps to go (40 px); pit-window bar, one 24 px cell per remaining lap: white = can't finish, red = short, orange = too early, green = window open; "SAVE 0.12 L/LAP to gain a lap" when within a lap | FuelLevel, FuelUsePerHour, LapLastLapTime, OnPitRoad, SessionFlags |
| D lap | 24, 816, 912, 240 | Last lap 56 px (purple if session best), best 40 px, delta bar 912×48 from iRacing's own LapDeltaToBestLap (hidden when `_OK` is false) | LapLastLapTime, LapBestLapTime, LapDeltaToBestLap(+_OK) |
| E standings | 952, 136, 944, 920 | 11 rows × 80 px: class leader pinned, then 4 ahead, YOU (gold, 1.3×), 4 behind. Columns: class position (40 px), number on a class-colour band, short name (32 px), **interval to the car in front** (40 px), PIT chip (grey row when on pit road). Class header rows only if multiclass | CarIdxClassPosition, CarIdxF2Time, CarIdxOnPitRoad, CarIdxClass, driver list from SessionInfo (parsed once per SessionVersion in irdash, not in the page) |

**Fuel maths (08 §6):** burn = average of the last 3 clean laps (5 for the long view); clean = green, no pit in/out,
no off-track; caution laps excluded; reset after a stop. Laps to go = SessionLapsRemainEx, or time left / average lap
+ 1 for timed races. Fuel to end = laps to go × burn × 1.05 − level (margin shown as "+1 lap kept back", not a
setting). Before 3 clean laps the zone says "FUEL: measuring (2 of 3 laps)".

**States:** green (above); **under caution** (strip shows CAUTION in amber 56 px for the whole caution, B switches to
gap-to-leader, C shows "PIT NOW? needs 14 L, have 22 L", E shows gap-to-leader and PIT chips, D fades); **on pit
road** (B and D collapse; C shows pit limiter state and fuel in tank; E shows the ghost row "YOU REJOIN P7", from a
measured time-lost-in-pits per track, learned from his own stops and shown only once measured); **practice /
qualifying** (E becomes the lap list of the session: lap, time, delta to best; B becomes "best 1:33.832 · optimal
1:33.4"); **flag flash** (any new flag: the strip takes the flag colour for 2 s, then returns; the physical boxes do
the rest); **no data yet** (every zone shows "—" in its own place, never blank).

**Refresh:** the page subscribes to one stream at 15 Hz carrying only the 24 channels above (today: 85 variables at
30 Hz plus 11 polls a second). Interval and gap numbers update at most 4 times a second and only when the tenth
changes (F1's "no flicker" lesson).

**Never shows:** tyre anything, damage, oil/water/voltage/humidity, a second standings list, radar, input traces, a
track map (the map stays on the side screen gallery or off; it was decoration at a glance), corner names.

**Deck:** no change while driving. `drive.js` and `ui.js` both go; this is the one in-car layout (`pages/race.js`).

**Tests:** a **telemetry replay harness** (new, W0): feeds a recorded `.ibt` into the page at 1× or 20× through the
same stream format, so every state above gets a picture from real data (the 12 Nov race has a caution and a pit
stop? W0 checks; otherwise an older file). Checks: nothing under 24 px, no flashing (a value may change at most 4×/s),
fuel maths against hand-computed values for 3 laps of a known file, standings order against iRacing's own
CarIdxPosition, the caution and pit variants, the "no data" state, and the request-rate ceiling (≤ 1 request/s
besides the stream).

### 4.3 RACES (the library)

**Copies:** Google Photos / Medal selection model (tick a card, a bar appears with 2–3 actions, delete goes to a
trash with undo, no "are you sure"; 04 §6), a storage bar with "free up space", Steam-recording style cards with a
real thumbnail and one state line. YouTube: Google's own loopback + resumable protocol (14).

**Layout.** Top (y 40): title RACES, the storage line "412 GB used · 280 GB free · about 38 more races" with a thin
bar, and the tabs RACES · PRACTICE & QUALIFYING · ALL (one row, 32 px). Below: cards in a grid, 3 per row,
600×300 each: a real thumbnail (a frame 60 s into the race, made once by ffmpeg between sessions), date (Today /
Yesterday / Wed 6 Nov · 11:28, 26 px gold), track (40 px), car · length · laps · best (counted) · size (26 px), and
**one state line** (32 px): "Not shared" · "Sharing 41%" · "On YouTube (private)" · "On YouTube" · "Kept" tag.
Every card has one gold button **OPEN** (64 px) and a tick box (56 px) top-left.

**Select mode.** Ticking any card: a bottom bar (full width, 120 px) with **SHARE TO YOUTUBE (3)**, **DELETE (3)**,
**CANCEL**. SHIFT-click selects a range; a "SELECT ALL SHARED" key for freeing space.

**OPEN a race:** a full-screen card: the thumbnail big, the facts, and five buttons in one row (each 72 px high):
**WATCH** (Windows' player, middle screen), **SHARE TO YOUTUBE**, **TALK OVER IT** (commentary), **REVIEW** (the
REVIEW door for this drive), **DELETE**. Under them the race's markers as a timeline (start, incidents, pits, best
lap, finish) so WATCH can jump to a moment. Chapters and the YouTube link, when shared, are shown here with a
COPY LINK key.

**Delete.** Moves the files to `vault\trash\` (kept 14 days, emptied by itself between sessions) and shows "Deleted
3 races · UNDO" for 8 s. No "click again". Space is freed when the trash empties; the storage line says "14 GB in
trash · EMPTY NOW" when it matters. Never deletes an unshared race by itself; never deletes a Kept race.

**Share to YouTube (the pipeline, 14 §5).**
1. One-time: Peter makes the Google project and signs in (section 10, decision 3; Claude writes the click-by-click).
   Tokens stored with DPAPI in `yt\token.bin`; the client JSON stays out of git.
2. On SHARE: trim by stream copy (out lap off: start at the keyframe before the green flag; end 20 s after the
   chequered flag; keyframes are every 1 s so the cut is within 1 s), title from the chosen template, description
   with chapters from the markers (first `0:00`, ≥ 3, ≥ 10 s apart), category Gaming, privacy from one setting
   (default **private** until the first checked upload, then Peter's choice), resumable upload in 8 MiB chunks, a
   progress line on the card and on the deck, runs only while the sim is off and at low priority, survives a network
   drop or restart (session URL kept on disk), never uploads the same race twice.
3. After: read back the real privacy state and show it; COPY LINK; thumbnail from the race frame (a 403 means "skip,
   tell once"); no playlists in v1 (needs the whole-channel scope).
4. Errors in plain words: "YouTube says today's upload limit is reached, I'll try after midnight" · "Sign in to YouTube
   again" (one key) · "No internet, waiting".

**Title templates (5, picked once in RIG settings; never typed):**
`{Car} at {Track} · iRacing {Series} · {Date}` · `P{Finish} from P{Start} · {Car} at {Track}` ·
`{Series}: {Track} in the {Car} · P{Finish}` · `{Track} {Car} full race · {Date}` · `Full race: {Series} at {Track} ({Car})`.
Kept under 70 characters; `{Series}` only when known.

**Talk over it (commentary).** Needs a real microphone (today only the AirPods hands-free mic is live; the Arctis
headset mic when plugged in; 14). One press: the race plays in Paddock's own player on the middle screen (so sync is
exact: the mic record starts on the same click, a measured fixed offset corrects the lag); the deck shows one key
STOP and a "talking 03:12" counter; STOP mixes by itself (game sound ducks under his voice, `sidechaincompress`,
audio-only re-encode, video copied, 10–20 s) and offers SHARE as a second video "… with commentary". Speech-to-text
(whisper) is not in v1 (download needs Peter's yes).

**Storage and retention (automatic, visible):** races kept until shared, then offered for deletion after 30 days
(never deleted by themselves); practice and qualifying kept 14 days unless Kept; a 15 %-free line triggers "Free up
space: delete the 6 oldest shared races (7 GB)" as one key. The recorder's own retention stops deleting during
sessions and never deletes because an export went missing (09).

**Deck:** RACES key opens a RigRaces screen that mirrors the list: 6 cards per page with real thumbnails (one key is
the picture, one the name), NEXT/PREV, a tick key, SHARE SELECTED / DELETE SELECTED / DONE at the bottom; EXIT at 7,3.
"27 empty keys" never again: pages fill or shrink.

**Underneath (must-fix from 09):** laps carry a `counted` flag from the live SDK (`LapBestLapTime` changes), lap 0
dropped, `RacesJson` uses the lap store's `Best()`; `SyncExports` never deletes; housekeeping and `FinishSession` wait
for the session to end; PB clips are cut from the whole file after the session (or at background disk priority);
`TestOff` restores the real retention; recorder routes gated by `RigState`, not `Vault.Serving`.

**Tests:** `races-page-test` grows to: every state (not shared / sharing / shared private / shared / kept / in trash /
offline / no mic), select mode and the bar, delete → trash → undo → empty, storage line maths, template rendering for
5 fixtures, chapter rules (0:00, ≥3, ≥10 s), the trim's start within 1 s of the green flag on a real recording
(ffprobe), resumable upload against a pretend Google (HttpListener) with a cut at 40 %, token expiry → the sign-in key,
"never twice", the deck mirror with 1, 6, 7 and 40 races. One real private upload of a 10-second clip, with Peter's
sign-in, is the acceptance test (then one public one if he wants public).

### 4.4 REVIEW

**Copies:** Coach Dave Delta's screen shape (map as the hero, your lap and the reference in two colours, insights as
few clickable items; 02, 12), LapBrain's card format (what to change, the evidence, what next; 12), VRS's "biggest
opportunity" (one highlighted stretch; 02), MoTeC/Garage 61 trace stack (speed, throttle, brake, steering on one
distance axis with a shared cursor and the delta-T line; 02), Track Titan's "one root cause" (12). The engineering
debrief method: end with one next-session plan (13).

**Screen 1: the card (shown by itself after every drive, and from RACES → REVIEW).**
- Top: track, car, session type, date; the result for a race ("P3 from P9 · +41 iRating (estimate)").
- Left half: the track map (the one renderer, `lib/map.js`) coloured by where he lost time against the reference,
  with the three corners marked 1, 2, 3.
- Right half: **three cards at most, ranked by seconds lost**, each four lines (12 style guide): corner name/number;
  what happened in his terms ("You braked 14 m earlier than your best lap"); the seconds, big and gold ("0.31 s");
  "Try this" in one line ("Brake at the 100 m board"). Sample size on the card ("in 6 of 8 clean laps"). Under 3
  clean laps: the one costliest corner with numbers and no advice. A race gets the **race story** instead
  (position by lap, pace against the field with the count of cars, the three costliest corners each with its clip)
  and at most one corner card marked "clean-air lap".
- Bottom: one line, the next-session plan ("Next time: Turn 5, brake at the 100 m board, check the entry speed"),
  and two buttons: **SHOW ME** (opens screen 2 at that corner) and **WATCH** (the clip).
- Reference lap: his best clean counted lap of this session; under 3 clean laps, his best at this car and track; the
  card says which. A conditions line when comparing across days: "Your best here was 6 Nov, track 31°, 42 L fuel".

**Screen 2: the laps (one trace page, replaces three).** The Delta/MoTeC stack: track map top-left with the cursor;
lap picker as two rows of lap chips (this lap, reference) with times; the traces stacked on one distance axis: delta-T
(gold line, the one that tells him where to look), speed, throttle and brake together, steering, gear. One cursor,
readouts in 32 px. The corner table under it: corner, brake point (m), minimum speed, throttle-on point, time, each
"this lap vs reference" with the definitions shown once ("brake point = brake over 10 %"). Theoretical best from
mini-sectors with its date spread shown. Zoom by the deck (lap/corner arrows) or wheel; **no mouse-only tooltips**:
the readout column shows the cursor values always. No typing anywhere.

**Screen 3: MORE DATA (one workbench, lean-in, 20 px floor).** Kept tabs only: DRIVER (the stack with every channel),
RACE (timing tower, position by lap, gaps, passes), BRAKING (lock-ups, ABS share, profile), SPLITS. Gone: PRO,
CAREER, TYRES, SUSPENSION (data stays readable through the channel picker, no page). One "Open in Pi Toolbox" link
with the words "opens the whole file in Cosworth's standard layout". One "Open Delta" link if Delta is installed.
Export CSV stays.

**Progress (a small section inside REVIEW, not a page):** per car and track, one dot per session for best and
average-of-5, and the **corner trend** ("Turn 5: lost 0.31 → 0.22 → 0.12 s over three sessions"), which no tool shows
well (12). iRating/SR line from his own race log, labelled estimate. "Best lap over time" is gone.

**Underneath:** one lap store with one counted rule (09 §1a: widen the `LapBestLapTime` window to 4 s for old files,
one off-track record is not fatal, live `counted` from the SDK), one session index, one review engine
(`analysis + corners + deepdive + field + coach + debrief` merged behind one API), corner names marked "detected" when
not from Lovely's list, conditions stored per session, cornerCache no longer caches empty sets, `LoadCorners` only if
the file exists, `Gather` reads the index not 40 files.

**Tests:** the three screens at 1920×1080 for: practice with 8 clean laps, practice with 2 laps, a race, no complete
lap ("No full lap yet" plus what a partial lap gives), offline. **Lap truth:** the 12 Nov 09:28 race must report
1:33.832 (lap 9) as best on every page and in the deck's list; 9 of 10 laps counted (what iRacing counted, from the
log). **Pi check:** one lap through Paddock and Pi Toolbox, delta, minimum speed and g-g compared and written down
(06 §4). Card wording: a lint for the "never say" list (no percentages, no "mistake", under 14 words, a corner and a
number on every card).

### 4.5 RIG

**Copies:** a car's single warning line (one sentence, one action), not a console. The black box from 05.

**Screen.** Top: "Rig ready" or the one sentence of what is wrong with its one key. Then four plain rows: iRacing ·
Stream Deck · Spotter · Overlays, each green/red with a word. Then **LAST RACE** performance in three numbers (average
fps, worst second **with its lap and place**, and the verdict sentence, which now names a freeze whenever the worst
second is under half the average: "Lap 9, start/finish: the picture froze for 4 s. Likely cause: Coach Dave Delta
(3× its usual CPU)."). Then **QUIET PC** state (on while a session is on: Windows Update, search indexing and OneDrive
paused, sim priority re-applied when Windows resets it; handed back after) and the **AC** controls (today's screen,
restyled). Settings that exist nowhere else live here as big switches: YouTube privacy, title template, sound on
start-up, the mic to use.

**The black box (05 §"Proposed"):** one row per second while the sim runs (frame rate, CPU/GPU from the SDK, GPU load,
memory, clocks, temperature and throttle reason from NVML, the 3 busiest programs, disk latency, Paddock's own
events: lap crossing, cut, save, scan); a 100 ms mode for 15 s when the frame rate drops 25 %; about 4 MB a race,
kept 8 weeks; costs under 1 % of a core at BelowNormal. The one-line cause rules from 05. Shown on RIG and on the
REVIEW card's top line only when something happened; never on the race screen.

**Doctor fixes (09):** no fresh run while a session is on (cached result shown); `Perf.Summary` says "still being
processed" instead of naming an older file; the sentence carries track and date; the fps cap comes from the sim's
setting; one owner for starting CrewChief.

**Delta test (one evening, Claude runs it, rig free):** the same 20-minute AI race three times: Delta off, Delta on
with video capture off, Delta on with capture on; the black box decides; the answer goes on RIG as a sentence.

**Tests:** the RIG states (ready, one fault, two faults, offline, quiet-PC on, AC off), the verdict sentence for the
12 Nov file (must mention lap 9 and 23.7 fps), black-box row rate and size over a replayed session, the fast mode
triggering on a synthetic drop, quiet-PC on/off leaving the services as they were, no doctor run while `SessionOn`.

### 4.6 The Stream Deck

**Copies:** Elgato's own guidance (one simple glyph, readable at small size, author at 144 px; 07), the colour-by-job
idea from the broadcast research (one meaning per colour).

**Key language.** Black key, one white glyph at 60 % height, one label of at most 8 characters at 20 px or larger,
gold = the one action he most likely wants now, green = starts something, red = ends something, grey = settings. The
same renderer draws the opener keys and the add-on screens (today: six copied colour tables and a different
renderer for the preview).

**MAIN (from 11, with Peter's decisions):**

| Row | Keys |
|---|---|
| 0 before | HOME (door; rig state dot) · DRIVE (GET IN; starts the last drive when nothing is loaded) · AI RACE (one screen: car/track/level/START; folds AI LEVEL and CAR TRACK) · OFFICIAL · FRIENDS · KIDS · AC · MORE |
| 1 in session | GET OUT · RESET CAR · RESTART · TO THE RACE (NEXT SESSION + RACE NOW merged) · PAUSE · SAVE SPOT · BACK TO SPOT · LEAVE |
| 2 pit | FUEL TO FINISH · TIRES · FAST REPAIR · CLEAR PIT · BEST LAP CAR (was GHOST) · REPLAY · spare · spare |
| 3 sound + after | VOL − · VOL + · SPOTTER (tap = mute/unmute; level on SOUND) · SOUND · OVERLAYS · RACES (door) · REVIEW (door, last drive) · RIG (door) |

MORE: THANKS, LOCK, ANALYSIS→ gone (REVIEW's More data is on screen), VAULT → gone, AC COOLER/WARMER, spare. LEAVE:
QUIT TO MENU (big, 2 cells, one exe), SLEEP PC and SHUT DOWN PC behind a **confirm screen** (press, then a 3-2-1 key
that must be pressed again within 5 s), BACK. Every add-on screen: EXIT at 7,3, same red, same word.

**Safety and reliability (11, all W0):** the deck is sent to MAIN on every Stream Deck start and wake (the add-on
does it on `willAppear` of any key after a restart); the repeat guard becomes a real 0.7 s floor for every key except
VOL/SPOTTER level/SEAT, and the `key` verb loses its exemption (sim boxes gone anyway); every add-on fetch has a 2 s
timeout and a hung irdash shows DASHBOARD NOT ANSWERING within 3 s; opener keys grey out after 3 failed ticks; the
add-on polls one `/deck/summary` route every 5 s when idle (today 6 routes every 2 s) and nothing while a page is
hidden; MY DRIVE never switches the deck by itself; `build-irdeck.ps1` copies to every name in `keys.map` and fails
loudly; AI RACE and OFFICIAL write the start mark; `irdeck state` reports `fresh=`, `replay=`, `event=` and ties
`telemetry=on` to the sim process; messages name keys that exist.

**Later (not v1):** live facts painted on keys during a race (fuel laps, position), what buyers of paid profiles pay
for (13).

**Tests:** a layout contract file (`deck/layout.json`) read by `build-deck.ps1`, the add-on and the test: every key
has a known command, no duplicates, labels fit, no PC-ending key reachable without the confirm screen; the repeat
guard (two starts 0.3 s apart → one run); the hung-irdash case (pretend irdash that accepts and never answers →
message within 3 s); request-rate ceiling; a real Stream Deck restart in the nightly check: the deck opens on MAIN.

### 4.7 Side screens and photos

Keep the gallery as it is (120 s pairs, one caption, no branding), fix the car-photo order (the newest set first, a
stable order within a set; W0 finds the cause), add more real photos only from iRacing's own assets or ones Peter
supplies (no drawings). The start-up sequence fades the first pair in with the clock.

### 4.8 Phone

Last. Same shell, same `design.css`, same `data.js`; the top-10 keys as big buttons; RACES read-only plus SHARE; the
LAN gate becomes an allow-list (09: today a paired phone can run quit, restart, shutdown mid-race).

## 5. Underneath: the engine-room fixes

From 09 (server), 10 (web), 11 (deck). Grouped by what Peter would notice.

**Could hurt a race or lose files (W0, before anything visual):**
- S1 Deck can open on LEAVE; power keys one press (11). S2 Phone can quit/restart/shutdown mid-race (09). S3 My Drive
  find keys, AI Level start, Rig Doctor run, overlays restart act while a session is on (09). S4 `SyncExports` deletes a
  race when its export is renamed (09). S5 Recorder retention drops to 3 after any test (09). S6 No crash handler: one
  bad thread ends irdash (09). S7 `irdash.log` deleted at 2 MB (09). S8 Map builder scans processes 590 times and opens
  every file, no driving gate (09). S9 Guard timer, WMI and window z-order work on the UI thread during sessions (09).
- H1 Recorder cuts 90 MB clips at the lap line at normal disk priority; housekeeping deletes GB files every 5 s;
  `FinishSession` encodes 1.1 GB during the next session (09). H2 TV worker re-parses YAML every 100 ms for a view that
  is off (09). H3 `/home` can trigger a recursive scan of the iRacing install mid-race (09). H4 The top screen's 16
  requests/s and the deck's 2.9/s, each a new TCP connection and thread (10, 11). H5 AC python call every 120 s while
  driving, unmeasured (09). H6 `PerfPrio` experiment changing other apps' priority every 5 s (09; Peter decides).

**Wrong numbers (W0–W1):**
- N1 Eight "best lap" rules; the counted rule rejects 7 of 10 laps; lap 0 counted (09). N2 Five "last session" pickers,
  four wrong (09). N3 Doctor verdict from the wrong file, ignores the worst second (09). N4 Career cache double rows and
  never-rescan (09). N5 HOME's "PB here" across all cars (09). N6 `Gather` sees only 40 files (09). N7 Two lat/lon
  scales (09). N8 HTML entities left in series names (09).

**Structure (W0 and alongside each door):**
- Server: `RigState`, `SdkReader` (+ one SessionInfo parse), `IbtFile`, `LapStore`, `SessionIndex`, `Jobs` (waits
  for `!SessionOn`, BelowNormal CPU and background disk), `Proc`, `Config/Json/Log`, `Http` (one route table with
  "allowed while driving" and "allowed from phone", a thread pool, keep-alive, cacheable static files, `/version` in
  memory). Then the god files split: irdash.cs (12 classes), recorder.cs, vault.cs, perf.cs, the analysis family →
  `Review`. Dead routes out. Order as 09 §7.
- Web: `app/index.html` (one shell: header, main, one banner), `design.css` (the only `:root`), `lib/data.js` (one
  stream + one state push replacing 14 pollers; `rig.driving`, `rig.online`), `lib/format.js`, `lib/map.js`,
  `lib/chart.js`, `pages/*.js` as ES modules with `mount/unmount`; the router owns one-page-at-a-time, CLOSE, Esc and
  the driving guard. Dead files out first. Order as 10 §"Migration order".
- Deck: the shared key renderer, one colour table, `deck/layout.json`, one `/deck/summary`, a thin `Screen` base.

## 6. Testing and quality gates

**Pyramid (11 §5, 09 §6, 10):**
1. **Fast offline, every build, under 60 s, safe while Peter races:** pure C# rules compiled on their own (repeat guard,
   kids, rig state, click pre-checks, lap counted rule, fuel maths, chapter rules, title templates); `design.css` lint
   (no hex outside it, no font-size under 24 on seat pages / 20 on lean-in pages); layout contract; format helpers.
2. **Headless screen tests with fixtures, a few minutes, no rig:** every page, every state, one picture each into
   `tests/shots/rework/<page>-<state>.png`; the telemetry replay harness for the race screen; the pretend irdash
   (`HttpListener`) with fault modes (500, slow, hung, down) for the deck add-on and the pages; a pretend Google for the
   upload; request-rate counters with ceilings (HOME idle ≤ 2/s, driving ≤ 1/s besides the stream, deck idle ≤ 0.3/s).
3. **Server load test:** irdash's own CPU, disk writes and thread count measured while the replay harness drives a
   20-minute session through the real server with the recorder in mock mode; ceilings: no file write over 1 MB, no
   delete, no process scan while `SessionOn`.
4. **Nightly self-check on the real rig, 03:00, only when `Assert-RigFree -NeedAway`, ≤ 10 min:** `irdeck state`,
   5 key exes in dry mode, a Test Drive start/out/reset/quit loop, the deck profile opens on MAIN after a Stream Deck
   restart, one recorder minute, one line to `tests/nightly.txt` that RIG shows ("Rig check 03:00: all good").
5. **Acceptance with Peter:** he presses the keys on the real deck; one real YouTube upload; one real race on the new
   race screen; one real sleep/wake.

**Visual review loop (rule 8):** a card is not done until Claude has looked at every picture it produced, written one
line per picture in the card's log, and fixed what it saw; then Peter sees a contact sheet (all states of one screen
on one image) and says yes or no before it is deployed.

**Definition of done for a card:** tests in layers 1–3 pass; pictures reviewed; no new hex colour, no new font size,
no new poller, no new "best lap" rule; `docs/USER-GUIDE.md` updated in plain words; the deck and screen words match;
deployed only with `state` showing sim=False; the next nightly check passes.

**Old tests:** the 103 scripts are triaged in W0: those that grep source text are replaced by layer-1 tests as each
area is rebuilt; `actions-test`, `bench-test`, `confirm-test`, `deckstate-test` and the tests of deleted features go;
`run-all` is rebuilt to layers 1–3 and runs on every deploy.

## 7. Waves and cards

Waves run in order. Inside a wave, cards marked ∥ run in parallel (different files). Sizes: S = a few hours of a
helper, M = a day, L = several days. Builder: **O** = Opus sub-agent (design-heavy, C# core), **S** = Sonnet sub-agent
(mechanical, tests, deletions), **R** = independent review by Codex (`tools\cx-run.ps1`) before merge, always for O cards.
Claude writes each card's spec from this plan, reviews, runs the live checks.

### Wave 0: safety and foundation (about 1 week)
| Card | What | Done when | Builder |
|---|---|---|---|
| W0-1 | Deck safety: MAIN on start/wake, power-key confirm screen, 0.7 s guard, `key` exemption removed, fetch timeouts, start mark from AI RACE/OFFICIAL, `irdeck state` fields, `build-irdeck` copies by map | 11's S1, guard and timeout tests pass; a real Stream Deck restart opens MAIN | O, R |
| W0-2 ∥ | `RigState` + session guards (S2, S3), phone allow-list, crash handler, log rollover, `TestOff` retention, `SyncExports` never deletes | 09 §7 step 1 tests; the recorder-safety test extended | O, R |
| W0-3 ∥ | Stop work during sessions (H1–H3, S8, S9, H5 measured): `Jobs` queue, housekeeping/finish/cuts deferred, TV worker out, official build off `/home`, guard timer off the UI thread | server load test ceilings pass on a replayed session | O, R |
| W0-4 ∥ | Delete the dead (10 §1, 09 §3, 11 §9): v1 www, dead js/css/png, dead routes, dead deck paths, dead tests; README fixed | every remaining test passes; `/version` unchanged behaviour | S |
| W0-5 ∥ | `lib/data.js` state push + stream slimming (H4): 14 pollers → 1 push; `/deck/summary`; keep-alive and cacheable static | request-rate tests: HOME idle ≤ 2/s, driving ≤ 1/s, deck ≤ 0.3/s | O, R |
| W0-6 ∥ | Lap truth: `IbtFile`, `LapStore`, one counted rule, live `counted`, lap 0 out; every page and the deck list use `Best()` (N1, N5, N6) | 12 Nov race = 1:33.832 everywhere; 7/10 counted (the file: lap 1 untaken, laps 6 and 7 incidents) | O, R |
| W0-7 ∥ | `design.css` + `lib/format.js` + the lint tests (rules 4, 5); both golds as two token sets for Peter's pick | lint passes on `races.html` converted as the first page | S |
| W0-8 ∥ | Telemetry replay harness + pretend irdash + pretend Google (test tools only) | the race screen fixture plays the 12 Nov file at 20× | S |
| W0-9 ∥ | Black box v1 (per-second rows, fast mode, cause rules) + doctor fixes (N3) | the 12 Nov verdict names lap 9 and 23.7 fps; row rate/size test | O, R |
| W0-10 | Photos order fix; YouTube Google setup guide for Peter (click by click); the Delta three-race test protocol | guide reviewed by Claude; order test | S |

### Wave 1: RACES and YouTube (Peter's #1; about 1–2 weeks)
| Card | What | Builder |
|---|---|---|
| W1-1 | `SessionIndex` + `Library` module (trash, retention, thumbnails between sessions, storage maths) | O, R |
| W1-2 ∥ | YouTube sign-in (loopback + PKCE + DPAPI) and resumable upload with resume, errors in words, "never twice" | O, R |
| W1-3 ∥ | Trim + chapters + title templates (`Cuts` module) | S, R |
| W1-4 | RACES page (list, cards, select bar, open card, delete/undo, storage line, states) on the new shell | O, R |
| W1-5 ∥ | Deck RigRaces mirror (6-card pages, tick, share/delete selected) | S |
| W1-6 | Commentary (player + mic + mix + second upload); mic check with a plain message when none | O, R |
| W1-7 | Acceptance: one real private upload with Peter; then public if he wants; USER-GUIDE | Claude |

### Wave 2: the race screen (about 1 week)
| Card | What | Builder |
|---|---|---|
| W2-1 | `SdkReader` SessionInfo once per version; the 24-channel 15 Hz stream; fuel maths and pit-window module in C# with tests | O, R |
| W2-2 | `pages/race.js` zones A–E, states, no-flicker rule, flag flash; `ui.js`/`drive.js` retired | O, R |
| W2-3 ∥ | Time-lost-in-pits learning per track (for the rejoin ghost) | S |
| W2-4 | Pictures of every state from the replay harness; Claude review; Peter's contact sheet; one real race | Claude |

### Wave 3: HOME, start-up, deck (about 1 week)
| Card | What | Builder |
|---|---|---|
| W3-1 | The shell + router (replaces PageHost/HomeHost/nested hosts), offline banner, Esc everywhere | O, R |
| W3-2 ∥ | Clock (canvas, hand by hand) + start-up sequence + sound | O |
| W3-3 ∥ | HOME zones and states; next-race source confirmed; RIG line from cached doctor | O, R |
| W3-4 ∥ | Deck: `layout.json`, shared renderer, new MAIN/MORE/LEAVE, AI RACE folded screen, one EXIT; one Install click | O, R |
| W3-5 | Pictures, contact sheet, deck preview with the real renderer, Peter's yes, deck-refresh | Claude |

### Wave 4: REVIEW (about 2 weeks)
| Card | What | Builder |
|---|---|---|
| W4-1 | `Review` engine behind one API (merge analysis/corners/deepdive/field/coach/debrief; conditions per session; corner names marked) | O, R |
| W4-2 ∥ | `lib/chart.js` (one trace engine) + `lib/map.js` reuse; readout column, deck zoom | O, R |
| W4-3 | Screen 1: the card (three cards, race story, next-session plan, wording lint) | O, R |
| W4-4 ∥ | Screen 2: the laps (stack, corner table with definitions, theoretical best with dates) | O, R |
| W4-5 ∥ | Screen 3: MORE DATA (DRIVER/RACE/BRAKING/SPLITS only; Pi and Delta links; export) from today's workbench, trimmed | S, R |
| W4-6 | Progress section (dots, corner trend, iRating estimate line); the Pi comparison test written down | S |
| W4-7 | Pictures for practice 8 laps / 2 laps / race / no lap / offline; Peter's yes | Claude |

### Wave 5: RIG and quiet PC (about 1 week)
| Card | What | Builder |
|---|---|---|
| W5-1 | RIG page (ready line, four rows, last race in three numbers, verdict sentence, settings switches, AC restyled) | O, R |
| W5-2 ∥ | Quiet-PC mode (pause/resume Windows Update, indexing, OneDrive; sim priority re-apply) as one-click `.cmd` + UNDO per CLAUDE.md rule 5, driven by `RigState` | O, R |
| W5-3 ∥ | Black box v2 (NVML, disk latency) + the Delta three-race test run by Claude | O |
| W5-4 | Nightly self-check (layer 4) + RIG shows its line | S |

### Wave 6: cleanup, phone, docs (about 1 week)
| Card | What | Builder |
|---|---|---|
| W6-1 | Split the god files, delete the merged duplicates (6 lap splitters, 9 map drawers, 12 formatters…), ARCHITECTURE.md rewritten | S, R |
| W6-2 ∥ | Phone on the shell with the allow-list | S, R |
| W6-3 | USER-GUIDE rewritten in Peter's words; `run-all` rebuilt; old shots archived | S |

**Later, if Peter wants (13):** live facts on deck keys, Crew Chief voice on (needs the mic), reminders to the phone,
a "racing now" room light, predicted iRating during the race, Garage 61 team-mate laps, whisper subtitles.

## 8. Who builds, cost, pacing

- Claude (this session) writes each card as a spec file `docs/rework/cards/<id>.md` from this plan, launches the
  helper, reads every picture and test line it returns, runs the live checks when the rig is free, and keeps this
  plan's status table current. Claude does not hand-write large code.
- Helpers: Opus for anything design-heavy or in the C# core; Sonnet for mechanical cards (deletions, tests, mirrors,
  docs). Every Opus card gets an independent Codex review before merge (it is cheap and it catches the "works on my
  fixture" bugs). Grok Build stays available for well-specified mechanical cards if Peter wants to spread the load.
- Pacing: usage checked every ~15 minutes while helpers run; stop launching at 80 % of any window; nothing deploys
  while `state` shows a session; add-on installs batched to one Install click a week.
- Rough size: about 45 cards, roughly 7 weeks of calendar time if waves follow each other, less where Peter is away
  from the rig for the live parts.

## 9. Facts still to confirm (each is a W0 task, none blocks the plan)

- C1 The next-race source: does `official.cs`'s data cover Peter's series with times? (If not: next session he has a
  car and track for.)
- C2 Does the 12 Nov file contain a caution and a pit stop for the race-screen fixtures? (Else an older file.)
- C3 `LapDeltaToBestLap` and `CarIdxF2Time` smoothness at 15 Hz (08).
- C4 Google "Publish app" with no review for a personal unverified app: the first real sign-in decides (14).
- C5 Thumbnail call on Peter's channel (403 = skip).
- C6 Why the car photos are out of order.
- C7 The real time-lost-in-pits per track (learned, shown only once measured).

## 10. Decisions for Peter

1. **Gold:** DECIDED 2026-11-13: the softer broadcast `#C9A24B` (Peter picked B from the W0-7 contact sheet). The bright `#f2c230` stays only as `data-gold="bright"` for comparison.
2. **The deck MAIN map** in 4.6 (what goes: the seven sim boxes, SORRY/GOOD RACE, SEAT keys, MUTE, SHOWCASE, VAULT,
   ANALYSIS; what merges: NEXT SESSION + RACE NOW, AI LEVEL + CAR TRACK into AI RACE, SPOTTER −/+ into SOUND).
3. **YouTube:** the 10-minute Google setup, when? And default privacy after the first checked upload: private or
   public?
4. **Coach Dave Delta:** OK to run the three-race test one evening when he is away (Delta off / on / on with capture)?
5. **`PerfPrio`** (Paddock lowering irdashies' and the browser's priority every 5 s during races): keep or stop?
   Recommendation: stop until the black box says it helps.
6. **Real-world race fetch** (`realworld.cs` fetching F1/IMSA calendars every 6 h, forced on): keep or drop?
   Recommendation: drop with the HOME real-world block.
7. **Commentary mic:** will he plug in the Arctis headset (or another mic) for commentary? Otherwise v1 ships without
   TALK OVER IT.
8. **Wave order:** W0 (safety, 1 week) then W1 RACES+YouTube, as above? Or RACES first with the W0 safety items only?

## 11. Out of scope (decided)

Tyre data on any live screen (SimHub later), damage, flags beyond a 2 s flash, Coach Dave Delta integration, iRacing's
data API, Garage 61 strangers' laps, wind fans and Hue strips, whisper speech-to-text (until Peter says yes to the
download), drawn car art, a TV view.
