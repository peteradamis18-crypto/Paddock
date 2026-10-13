# Delta to your all-time best (O5) and the benchmark card (WS13)

Built 2026-10-09/10. Specs: `SPEC-next.md` (O5, WS13). Code: `dash\src\refs.cs` (the personal-best reference), `dash\src\bench.cs`
(other drivers' laps, real-world references, the card's data), `dash\src\deltabar.cs` (the bar), `dash\src\data.cs` (routes, `.ibt` lap
reading), `dash\www\v2\bench.js` + `bench.css` (the card), `sessions.*` and `debrief.*` (where it shows).
Tests: `tests\pbdelta-test.ps1`, `tests\bench-test.ps1`. Data: `dash\refs\`, `data\fieldlaps.tsv`, `data\pro-refs.json`.

## O5 - VS PB on the delta bar

**What it is.** iRacing's own `LapDeltaToBestLap` only knows this session. The bar now has a fourth reference, **PB**: the best lap you
ever drove in this car at this track and layout. It is the default whenever there is one; the VS key cycles
**PB > BEST > OPTIMAL > SESSION** (in a session with no PB for the car and track PB is skipped, so the key never lands on a mode that would show something else; with no session loaded
it is always offered, so the setting can be changed from the deck at any time).
With no PB for the car and track the bar says VS BEST, as before. A fresh `irdash.ini` without a `delta_ref` line starts on PB; a line that
says `best`, `optimal` or `session` is kept. (`irdash.ini` now says `delta_ref=pb`.)

**The reference.** For each combination, the time at every 0.05 % of the lap (2001 points) of the best lap, kept in
`dash\refs\<car>__<track>-<layout>.json` (names are lower-case words, e.g. `chevrolet-corvette-z06-gt3-r__road-atlanta-full-course.json`;
2001 numbers, 14 KB). Fields: `key, car, track, config, time, careerBest, set (local date and time of the lap), source ("ibt" or "live"),
file, lap, n, t[]`. It is made like this:
1. When a session loads, irdash reads the car and track from the session text and loads the cached reference.
2. The career cache says which `.ibt` files hold the best laps of that combination. If the cache is missing, or a faster lap has appeared
   since it was made, a low-priority background thread builds a new one from the best file (the first of up to six whose best lap is a full lap
   that never touched the pit lane). It waits while you are driving - a big file never competes with the sim - and a failed build is not
   retried for the same career best.
3. The lap's time at each point is worked out exactly as the lap analysis does it (interpolated between the 60 Hz samples, stretched a hair to
   iRacing's own lap time).

**The delta.** `current lap time - reference time at the same LapDistPct`, smoothed with a 0.12 s time constant; predicted lap = PB + delta.
It shows only when the lap began with a clean crossing of the line on track: a lap that begins on pit road (the out lap), a tow or a reset (a jump
in lap distance), or pit road during the lap, takes the delta away until the next crossing. The bar stays up on those laps with "-.---" and
the small line **"PB 1:19.600 - set 9 Oct"** under it, until the first flying lap is done. Around the line itself the lap counter, the distance and
the timer can disagree for a frame; that is handled (no spike).

**A new PB, no restart.** The bar records each clean lap (distance and lap time, up to 20 minutes, in two preallocated buffers). When a lap
ends and iRacing announces its time, the lap becomes the reference if it is faster than the current PB **and** iRacing's own `LapBestLapTime`
equals it (iRacing only counts valid laps there, so that is the validity check). The reference is rebuilt from those samples on a worker thread, saved,
and used for the next lap. The `.ibt` written later gives the same lap; the career cache catches up by itself.
Proved on a real race 2026-10-10 00:23 (a 1:19.549 was announced: "personal best reference updated from the live lap" in `irdash.log`). That run also showed
that **iRacing's lap timer can still show the last lap's time for a frame or two after the line**, which made the first reference from live samples jump to
56 s in its first 0.05 %. Fixed three ways: such samples are left out while recording and again when the reference is made, `PbRef.Sane` refuses any
reference that does not start at 0, go forward, end at its lap time, pass half way at about half the time and have no step over 1.5 s (a live lap
that fails keeps the old reference and the `.ibt` gives the right one later; a file that fails is ignored and rebuilt), and the tests feed the stale frame.

**Cost.** Everything per tick (30 Hz while driving) is arithmetic on preallocated arrays: no allocations, no disk, no regex. YAML parsing,
disk and JSON run on worker threads. The bar also redraws only when what it shows changes, and its pens, brushes and paths are made once
per surface. `fps-report.ps1` on a real run is the measurement still to do (see "pending" in the report); the code has nothing that runs per sim frame.

**Settings and JSON.** `/overlays` `delta` now carries `ref` (what the VS key chose: pb/best/optimal/session), `active` (what is really in
use: pb falls back to best), `label` ("VS PB"), `pb {time, text, source}` and the old `on, y, text`. The deck's OVERLAYS screen already draws
`'VS ' + delta.ref.toUpperCase()`, so it says **VS PB** with no add-on change (it could use `delta.label` to say VS BEST while no PB exists - optional).
`/pbref/state` is what the bar is working from now; `/pbref?car=&track=&config=&build=1&times=1` shows or builds one combination's reference.

## WS13 - the benchmark card

One card per car and track: **your best at the top** (gold), then each **yardstick** as a thin bar with its time, the gap to you (+1.84 s;
a minus sign and gold when you are quicker) and your pace as a percentage (103.2 % = your lap is 3.2 % longer), the **next goal** (the slowest
yardstick still ahead of you, and the gap), and your **best lap over time** (the running best through your sessions, a thin line). Every
yardstick says where it comes from and how many drivers it is based on; real-world ones link to the official timing. It lives on the
sessions page (right column; arrows step through your cars and tracks, the filters narrow them) and, smaller, on the debrief after a new PB
(`/bench?live=1`: only when this stint's best equals the all-time best here). `?bench=sample` on the sessions page and `?debrief=demo` show it
with clearly marked sample numbers.
Routes: `/bench?car=&track=&config=`, `/bench/list`, `/bench?sample=1`, `/bench?live=1`.

### B1 - the field database (other drivers' laps)

`data\fieldlaps.tsv`, append-only, tab separated, one line per **session and driver** (a faster time for the same session and driver may be
appended later; readers take the best). Columns: `sid` (`s<SubSessionID>`), `num` (session number in the weekend), `type`, `ts` (UTC seconds),
`car`, `track`, `config`, `uid` (iRacing customer id), `ir`, `lic`, `best`, `laps`, `me` (1 = your own row, left out of the numbers), `src`.
No driver names are kept. AI cars, the pace car and spectators are never recorded; a session with no other human driver records nothing.

**What the files can and cannot give (finding).** The `.ibt` telemetry files hold **only your own car's channels**: there is no `CarIdx*` array
in them, whatever `irsdkLogAllCars` says (that setting only lets the session text list more than 64 cars). So every other driver's best lap comes
from the **session text** (`SessionInfo.Sessions[].ResultsPositions[].FastestTime`, with `DriverInfo`: iRating, licence, car), which in an `.ibt` is
the text as it was when recording began - partial for a session you joined late. The **live** capture (below) has the whole session.
- **Backfill** (once, 150 s after irdash starts and never while driving; `fieldlaps.scanned.txt` remembers the files): 140 telemetry files read on
  2026-10-10, **1** had other human drivers (a 5-driver official practice at Tsukuba, BMW M2 Racing, 4 others of whom 2 had a lap at that moment),
  **2 driver laps** added. The other 139 are AI races and solo test drives. **No combination is anywhere near 30 drivers**, so the card shows no
  field yardstick yet and says "Nothing recorded yet" (or "n of 30").
- **Live**: while a session runs, the delta bar's timer notes `CarIdxBestLapTime` every 5 s (the sim keeps it for every car) and every 30 s
  and at the end of the session (disconnect, or the next session of the weekend) a worker thread saves each human driver's best, from the session
  text and, where the text has not caught up, from that telemetry (`src = live-telemetry`). Races with other people therefore fill it in by themselves.
- **Numbers per combination** (needs **30 other drivers** with a lap in the same car, track and layout, or nothing is shown): top 5 %, top 25 %,
  median (straight-line interpolation between ranks: `h = (n-1)p`; the time 5 % of drivers beat), each driver counted once with their best
  lap; and, as its own line, the median of drivers within **250 iRating** of yours (also needs 30 of them). Labelled "based on 64 drivers you've raced".

### B2 - does iRacing publish per-combo leaderboards? (research, 2026-10-10; public pages only)

**Short answer: nothing we can read automatically and legitimately today.** Not built; no scraper.
- *Time Attack* is in the iRacing app only (Go Racing > Time Attack): a leaderboard per track and an overall standings board per competition (about 12
  tracks, not per car + track + week). No web page and no public API for it. A 2023 preview mentions gap columns and a "TA Level" set by a "% Rank"
  (a native percentile; cut-offs not verified).
- *Data API* (`members-ng.iracing.com/data`): `stats/world_records` (car + track: the record holders' laps, no iRating, rank or count),
  `stats/member_bests` (your own), `stats/season_tt_results` / `season_tt_standings` (rank, best lap, licence for every driver, but only for the official Time Trial
  seasons, keyed by season, car class and week - not for an arbitrary car + track; no iRating), `time_attack/member_season_results` (your own only).
  A percentile is possible only from the Time Trial results by counting rows.
- *Access*: the old username/password login was removed on 9 Dec 2025; OAuth2 is required, and iRacing has **paused issuing client ids** (support
  article last changed 23 Mar 2026). The "Password Limited" flow is for headless clients with fewer than three users, each registered by contacting
  iRacing. The Conditions of Use ban data mining, robots and screen scraping without written consent. So even the sanctioned route needs Peter to
  get a client id from iRacing support first; nothing can be done with an assistant holding his credentials.
- *Third parties*: **Garage 61** has a real API (OpenAPI spec at garage61.net/api/openapi/v1.json; personal access token or OAuth2; `GET /laps` by track,
  car, rating range, with `total`) but by default only your own and teammates' laps - a global percentile needs approval from Garage 61.
  Coach Dave Delta has per car and track leaderboards (no API or percentile mentioned). Track Titan publishes "top 5 %" and "better than average" lap times
  per car and track (method unpublished, no API, pages looked sparse for rare combinations). LapLegends has leaderboards (no API found).
  Not verified: how iRacing's Time Attack board shows iRating; Track Titan numbers came from search snippets (its pages answered 403).
- *What would work*: (1) Peter asks iRacing for an OAuth client id once registration reopens; or (2) a hand-typed table of "top 5 %" and median times
  from Time Attack or Track Titan, labelled with where they came from (the card already accepts any such line, see below); or (3) just races with
  other people - the live capture builds the "drivers you've raced" numbers.
(Research done by a delegated pass over public pages; the claims above carry the sources it cited: iracing.com/new-racer-guide, support.iracing.com
(legacy authentication, OAuth client credentials, previous-season Time Attack results), oauth.iracing.com/oauth2/book, the community `iracingdataapi`
client, garage61.net, coachdaveacademy.com. Re-check before relying on any of it.)

### B3 - real-world references (`data\pro-refs.json`)

Hand-written, every number copied from IMSA's **official timing sheets** (`imsa.results.alkamelcloud.com`, 2025 season PDFs) and linked to the exact
PDF. Fetched and read on 2026-10-10; each link answers (a HEAD request in `tests\bench-test.ps1` checks them again). The card says "Real car,
real conditions - a guide only".
Matching uses iRacing's own identifiers, read from the telemetry file names (`<car folder>_<track and layout> <date>.ibt`): the entry's `carClass`
(`classes` in the file lists the iRacing car folders of GT3 and GTP) or one `carPath`, and the `trackName` ("roadatlanta full").

| Track (iRacing layout) | Event, 2025 | GT3 (IMSA GTD PRO; GTD at Long Beach) | GTP |
|---|---|---|---|
| Road Atlanta (`roadatlanta full`) | Motul Petit Le Mans | qualifying best 1:18.523 Dan Harper; race fastest 1:19.967 Albert Costa | 1:09.628 Tom Blomqvist; 1:12.276 Frederik Vesti |
| Sebring International (`sebring international`) | Mobil 1 Twelve Hours of Sebring | 1:59.225 Albert Costa; 2:00.451 Laurin Heinrich | 1:47.091 Dries Vanthoor; 1:49.120 Felipe Nasr |
| Long Beach (`longbeach`) | Acura Grand Prix of Long Beach | GTD: 1:17.877 Parker Thompson; 1:18.680 Laurens Vanthoor | 1:11.539 Dries Vanthoor; 1:12.708 Felipe Nasr |
| Laguna Seca (`lagunaseca`) | TireRack.com Monterey SportsCar Championship | 1:20.608 Giacomo Altoè; 1:21.650 Albert Costa | 1:12.854 Dries Vanthoor; 1:14.637 Mathieu Jaminet |
| Road America (`roadamerica full`) | Motul SportsCar Grand Prix | 2:03.904 Giacomo Altoè; 2:05.877 Andrea Caldarelli | 1:48.628 Nick Yelloly; 1:51.742 Tom Blomqvist |
| Virginia International (`virginia 2022 full`) | Michelin GT Challenge at VIR | 1:44.433 Giacomo Altoè; 1:46.592 Albert Costa | (no GTP at VIR) |
| Daytona road course (`daytona 2011 road`) | Rolex 24 at Daytona | race fastest 1:47.156 Madison Snow (no class qualifying sheet found) | pole 1:33.895 Dries Vanthoor; race fastest 1:35.868 Sheldon van der Linde |

Each pair is "qualifying best; race fastest lap" of the class. 25 entries. Of the combinations Peter has driven, the Corvette Z06 GT3.R at Road Atlanta and
the Ford Mustang GT3 at Sebring get lines. **Left out (no clean official source found):** Ferrari 296 Challenge and Porsche 911 Cup (992.2) at Sebring,
Toyota GR86 at Lime Rock, BMW M2 Racing at Tsukuba, BMW M4 GT4 at Okayama, Porsche 911 RSR at Sonoma; the WEC tracks (Spa, Monza, Le Mans - official timing
is on a different Al Kamel site); the Daytona class qualifying (the sheet's address could not be found); Laguna and VIR were not driven by Peter yet.
**Adding more:** open the event on Wikipedia, take the Al Kamel links from its references (qualifying: `...\<yyyymmddhhmm>_Qualifying\03_Results_Qualifying.PDF`, race:
`...\<session>_Race\03_Results_Race_Official.PDF`), read "Fastest Laps by Class" on the last page, and add an entry with the exact PDF address.
The time on the sheet is the class's quickest lap by any driver; "Circuit Best Laps by Class" on the same sheet gives the track record if one is wanted.

### Where else the real numbers could come from
iRacing keeps its own best lap per car and track in `Documents\iRacing\lapfiles\<track>\<userid>_<car>.blap` (and `.olap`, the optimal lap). The format is
closed, so the `.ibt` files remain the source; noted in case iRacing documents it one day.

## Tests (what they cover and what they could not)
- `tests\pbdelta-test.ps1`: reference from a real `.ibt` (right lap, 2001 monotone points, JSON fields, banner), the same lap through the live path
  (frames from the test hook, under a made-up "Test Car" so real reference files are never touched): delta 0 +- 0.01 s, VS key order, a faster counted lap
  becomes the reference and is saved, an uncounted one does not; pictures `pb-*.png`; the live logic on made-up frames straight from `dash\irdash.exe`
  (pit start, tow, line glitch, +-0.5 s offsets); the default reference.
- `tests\bench-test.ps1`: the field parser on a real session with other drivers and on an AI race, percentile maths and the 30-driver rule on scratch
  files, `/bench` against the sessions page, `pro-refs.json` well formed with every source link answering, the card as pictures and text, the live capture on made-up frames.
- `tests\overlays-test.ps1` was adjusted: the VS key now has four states, so it presses until the bar is on the wanted reference and puts the ini back as it found it.
