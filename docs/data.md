# Data tool: sessions, lap analysis, race extras, brief, weekly progress, flag glow, sim priority, OneDrive, Rig Doctor fixes

Built 2026-10-09 (WS4, WS5 S2/S3 in `SPEC-next.md`, plus the flag glow and the Rig Doctor "fix it yourself" change).
Code: `dash\src\data.cs` (new), `dash\src\irdash.cs` (Career), `dash\src\doctor.cs`, `dash\www\v2\` (`sessions.*`, `nav.js`, `brief.js`,
`race.js`, `flaglow.js`, `data.css`, `idle.js`, `rig.js`), `tools\keep-iracing-local*.cmd`. Test: `tests\data-test.ps1` (pictures in `tests\shots\d-*.png`).

**Also built on this data (2026-10-10):** the delta bar's VS PB reference and the benchmark card (your best against other drivers and real-world
pros), the field database and the pro references - see `benchmark.md`. `dash\src\data.cs` gained `Career.BestFor/BestFiles/HistoryFor/IdsFor/LatestIr`,
`IbtLaps.Reference` and the routes `/bench`, `/bench/list`, `/pbref`, `/pbref/state`, `/fieldlaps`, `/fieldlaps/scan`, `/api/delta/snapshot`
(and the test routes `/api/test/pbref`, `/api/test/pbclear`; `/api/test/session?rename=1` gives the pretend session its own "Test Car" and "Test Track").

## What the data comes from
Everything is read from the `.ibt` files iRacing saves in `Documents\iRacing\telemetry` (read-only, never written) and from the live
session. irdash keeps a small cache of what it learned from each file in `dash\career-cache.tsv`.

**Cache format 2.** Each row now also holds the file's best lap, typical fuel per lap (and how many laps that is from), track layout, track id,
the real start time of the session and the session type (Practice / Qualify / Race ...). Rows from the old format are read again once, in the
background, at the lowest thread priority, never while you are on track, and only the rows that need it (the old exe still reads the new file:
the extra columns are just ignored). 90 files took about 8 seconds. OneDrive files that are "online-only" are left alone (reading them would
start a download); `tools\keep-iracing-local.cmd` fixes that for good.
- *Best lap* = the quickest time iRacing announced during the file (`LapLastLapTime` changes when a lap ends), ignoring anything iRacing did not
  count (faster than its own `LapBestLapTime`) or that is far too short to be a lap. Checked by hand against the .ibt in the test.
- *Fuel per lap* = the median fuel burnt on laps that stayed out of the pit lane, at the line itself (interpolated between samples), within 107 %
  of the quickest of those laps.

## D1 Sessions page
`/v2/sessions.html` (also shown over the idle screen). Every session: date, car, track and layout, type, laps, best lap, seat time; filters by car and
track (gold = chosen); a personal-best table (best lap per car + track + layout, with the session it came from); short runs (under 30 s) are
hidden until you ask. Tapping a row opens the lap analysis for that session. JSON: `GET /sessions`.

**Opening it**
- Idle screen: a quiet "Sessions & laps ›" link top centre.
- **Stream Deck key (for the lead to map):** `GET http://localhost:8199/api/sessions/open` (and `/api/sessions/close`). The same two are
  `GET /api/do?c=sessions` and `c=sessionsclose`. The dashboard page asks `/nav` every 1.5 s and puts the page over itself as an iframe: no
  window opens or moves in Windows. Refused with HTTP 409 while you are driving, and closed by itself the moment you are in the car.
  A key that only needs to open a URL can be an irdeck command that does an HTTP GET to that address.
- Also `http://localhost:8199/v2/?sessions=1` opens it on page load, and `http://localhost:8199/v2/sessions.html` works in any browser.

**Units.** The page shows km/h or mph (and km or miles) as iRacing last reported them (the dashboard keeps that in the browser: irdash-units); the KM/H button at the top changes it and remembers your choice.

## D2 Lap analysis
`GET /ibt/laps?file=<name>.ibt` -> the laps of one file; `GET /ibt/lap?file=<name>.ibt&lap=<n>` -> one lap as 1001 points on an even grid of
lap distance (0.1 % steps): speed (m/s), throttle %, brake %, gear, steering (degrees) and elapsed time. Two laps line up point for point, so
the difference trace is just one time array minus the other.
- **File names are checked strictly:** letters, digits, space, `_ . -` and a `.ibt` ending only, and the name must then equal a file the
  telemetry folder really holds (the path is built from the folder listing, never from the request). Anything else is HTTP 404; a bad lap
  number 400; an online-only file 409.
- **Never while driving:** HTTP 503 ("Lap analysis waits until you are out of the car"), so a big file never competes with the sim for the disk.
- A lap is "full" when it started and ended with a clean crossing of the line (not the first lap after getting in, tows or resets). Its time is
  iRacing's own time when that agrees with the samples, else computed. Laps through the pit lane, off the track and incident points are flagged.
- The page (canvas, no libraries): speed, throttle, brake, gear and difference traces over lap distance, reference lap (gold, default the best
  lap) against a compared lap (cyan); hover for a crosshair and read-out; click a lap to compare it, REF to make it the reference; up/down keys
  step through laps. **Where the time went:** the lap is cut halfway between corner apexes (the debrief's idea); corner names and numbers come from
  docs\corners.md (Lovely Track Data kept locally in data\corners\lovely, or corners detected from your own laps), without them the slow points of the reference lap are used. The list says how many seconds
  each corner cost, and the track outline is coloured red where time was lost and green where it was gained.

## D3 Race extras (strength of field and iRating estimate)
`GET /race`, shown in the standings header ("SoF 2,233 · iRating +64"), only in a Race session, only for your class, only when the field has real
iRatings (two or more drivers at 100+; AI cars have 0 so AI races show nothing). The iRating change is shown for official races only
(`WeekendInfo: Official`); in an unofficial race with real ratings it says "unrated".
The community formula (iRacing has not published theirs; this one matches it closely):

    BR1 = 1600 / ln 2 = 2308.3
    chance A beats B = (1 - a)·b / ((1 - a)·b + a·(1 - b)),   a = e^(-Ra/BR1), b = e^(-Rb/BR1)
    expected score = sum of that chance against every other driver in your class
    change = (starters - your place - expected score) × 200 / starters
    strength of field = -BR1 × ln( average of e^(-R/BR1) )

Your place is your **current** class position, so the number is "what you would gain or lose if the race ended now". It assumes nobody retires
(iRacing's fudge factor for retirements is not applied). Worked by hand in the test: drivers at 3200 and 1600 -> the favourite wins 3 times in 4
(0.75); winning is (2 - 1 - 0.75) × 200 / 2 = +25, being second -75; the other driver gets +75 / -25; strength of field 2264.07. All the changes
in a race add up to zero. `GET /irating?irs=3200,1600&me=0&pos=1` runs the sums for any numbers (used by the test).

## D4 Pre-session brief (top screen)
From the moment a session is loaded until you are in the car (and not in friends mode, a replay, the debrief or Rig Doctor): track name and
outline with corner names, your best lap here, when you last drove here, the fuel one lap takes (and how many laps a full tank is), and the
weather. Data from `GET /brief`. It fades as you get in, never comes back for that session, ignores the mouse, and is capped at 10 minutes for
a session that is only watched. It is hidden by the first frame with you on track, so it can never cover anything while you drive.

## D5 Weekly progress (idle screen)
"This week": hours in the seat, laps and personal bests since Monday 00:00, with last week's hours and laps underneath. A "personal best"
is a car + track + layout whose best lap was set this week and beat an earlier one; a first lap on a new combination is counted separately
("+1 new combination"). In `/career` as `week`.

## Flag glow (top screen)
A soft coloured edge round the dashboard while a session is live, from `SessionFlags`: yellow (full-course or local yellow, debris), blue (let
the car behind through), white (last lap), green for 8 seconds when the green flag is shown (not for a page that just loaded into a running
race), red (slow pulse), black flag (white frame, pulsing), and a slow chequered sweep at the finish. Most important first: black, red,
chequered, yellow, blue, white, green. It sits under every overlay (brief, debrief, Rig Doctor), ignores the mouse and never shows anything else.

## S2 Sim priority
`irdash.ini`: `sim_priority=high` (default) or `normal`. When a session starts (irdash sees the sim link up) `iRacingSim64DX11` is raised to High
priority once per sim process, and logged ("sim priority: iRacingSim64DX11 (pid) raised from Normal to High"). Only the priority class
changes. `normal` leaves the sim alone. Rig Doctor has a "Sim priority" check.
**Finding (2026-10-09 21:25):** on Peter's first session after this went in, the log said the sim was **already High** when irdash looked, so
on this PC the setting changes nothing today (iRacing or another program sets it itself). Keep it as a safety net, or set `sim_priority=normal`.
To judge any frame-rate effect, compare `fps-report.ps1` runs; there is nothing to compare while the sim is already High.

## S3 OneDrive (`Documents\iRacing` is in OneDrive)
Windows' "always keep on this device" is the *pinned* file attribute. Without it OneDrive may turn old files (1 GB of telemetry, settings,
setups) into online-only placeholders; opening one downloads it, and the lap data would skip it.
- `tools\keep-iracing-local.cmd` runs `attrib +P` on `Documents\iRacing` and everything inside it, writes `tools\keep-iracing-local.log`
  ("pinned: N of M") and closes itself. `tools\keep-iracing-local-UNDO.cmd` runs `attrib -P`. It changes one attribute, never file contents.
  Run it by double-clicking (it works started through Explorer; irdash starts it the same way, hidden, when Rig Doctor sees it is needed).
- It looks up your Documents folder from Windows itself (`GetFolderPath`), so a moved Documents folder is found.
- Rig Doctor has an "iRacing files on this PC" check (read-only): pinned = green; not pinned, or any telemetry file online-only, = amber.
- Recommendation (Peter's decision): also stop OneDrive uploading the telemetry folder, since those files are big and never needed elsewhere.

## Rig Doctor fixes things itself
Rig Doctor (`/doctor`, `dash\src\doctor.cs`) now applies safe fixes and re-checks. Rules: **only when no sim session is running and you are not
driving**; each fix is tried at most 3 times (one try a minute at most; after 3 failed tries it stops for 2 hours and puts one short line on the
idle screen); every fix is logged in `irdash.log` as `Rig Doctor fixed: <what> - <what it did> (it was: ...)`; a failed attempt as
`Rig Doctor tried to fix ...`. The idle screen runs a cheap look every 20 s: a program missing for 45 s (so not just restarting) brings the check forward.

| Problem | What the doctor does |
|---|---|
| Overlays app (irdashies) not running | starts it with the same restart the OVERLAYS screen uses (`irdeck ovl apply`) |
| CrewChief not running | starts CrewChief |
| CrewChief calling you by another name with friends mode off | `irdeck guest voice` (a change that was waiting for the car to stop) or `guest off` (puts your remembered own name back) |
| Stream Deck app not running | starts it (`--runinbk`) |
| `Documents\iRacing` not pinned in OneDrive | runs `tools\keep-iracing-local.cmd` (not while the sim program is running) |

Not fixed (listed when you open Rig Doctor, never on the idle screen): a missing race screen or wrong refresh/rotation, the overlays app not
visible to normal programs (`tools\fix-overlay-install.cmd`), graphics not the settled ones, telemetry saving off (it is iRacing's own `app.ini`),
a Stream Deck add-on update waiting (not a warning at all now: the lead installs those), the add-on silent for minutes. The idle line says
"All good", or one short line for the few things only you can do (today: disk nearly full) or a fix that would not work after 3 tries.

## Testing
`tests\data-test.ps1` (run out of the car): cache format and migration evidence, weekly numbers worked by hand from the cache, best lap and fuel
per lap worked by hand from the .ibt, the sessions list and PB table, the lap analysis (and refusing `..\`, `C:\`, `a/b.ibt`, long, empty and
missing names), the page in headless Chrome, opening and closing the sessions page (and refusing while driving), the iRating formula worked by
hand, the live race numbers, the brief appearing and fading, every flag, the sim priority with a stand-in program (the real sim is never
touched), Rig Doctor's checks and fixes, and the OneDrive tool on a scratch folder (never on your real Documents).
Pictures: `d-sessions.png`, `d-analysis.png`, `d-sessions-from-key.png`, `d-top-sessions-open.png`, `d-race-extras.png`, `d-brief.png`,
`d-brief-gone.png`, `d-flag-yellow|blue|white|red|black|checkered|green.png`.
