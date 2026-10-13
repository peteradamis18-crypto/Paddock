# Corner model: every turn labelled on every track map

Built 2026-10-10 (WS18 in `SPEC-next.md`). Peter: "need turns labeled on track map".
Code: `dash\src\corners.cs` (server), `dash\www\v2\corners.js` (drawing and lookup, shared by every page), `dash\www\v2\map.js` (live map, `TrackInfo`).
Data: `data\corners\lovely\` (offline copy of Lovely Track Data), `data\corners\library\` (offline copies of SIMRacingApps track outlines), `data\corners\auto\` (corners found in Peter's own laps or from an outline).
Tests: `tests\corners-test.ps1` (pictures in `tests\shots\c-*.png`). Tools: `data\corners\fetch-lovely.ps1`, `data\corners\fetch-library.ps1`, `data\corners\audit.ps1`.

## In one paragraph
Every turn of a track gets a number, **T1 ... Tn in lap order from the start/finish line**, the same on every page. Where Lovely Track Data has
names ("The Esses", "Eau Rouge") they are shown beside the number. Where Lovely has no corner list for a track Peter has driven, irdash finds the
corners in his own best lap (and keeps them). A track he has never driven and Lovely has nothing for gets numbered bends from the shape of its outline where we hold one (no names); with no outline at all it is drawn bare. Nothing is guessed.
The map needs no internet: irdash keeps its own copy of Lovely's files and the page only ever talks to irdash.

## Where the corners come from (first one that has a list wins)
1. **Lovely Track Data** (CC BY-NC-SA 4.0, https://github.com/Lovely-Sim-Racing/lovely-track-data), read from `data\corners\lovely\<layout>.json`.
   The copy holds every iRacing layout Lovely lists for a track folder Peter has installed (85 files, 95 KB, plus `index.json` = Lovely's manifest for iRacing
   and `README.txt` with the credit and licence). Files are kept exactly as published. irdash goes to GitHub only to fetch a file that is missing (a track
   bought later) or to refresh a file older than 45 days, quietly, one tiny file at a time, never while he is in the sim. `fetch-lovely.ps1 -Refresh` does it by hand.
2. **Found in his own driving** (`data\corners\auto\<trackkey>.json`, trackkey = the same key as `dash\maps\`, e.g. `t98-sonoma-long`):
   - *telemetry*: the quickest clean full lap in his `.ibt` files (no pit lane, under 0.7 s off the track, both line crossings seen; files written in the last
     2 minutes are skipped). Curvature = yaw rate / speed, binned by lap distance, smoothed over 30 m. A corner starts where curvature passes 1/1100 m and ends
     below 1/1700 m; it must turn the car at least 10 degrees and be tight (1/550 m) somewhere, or turn it 18 degrees. Same-direction pieces with a shallow dip
     are one corner; one long piece with two clear peaks and a deep valley is cut in two. The apex is the tightest point.
   - *outline*: when no clean lap exists yet, the same maths on the outline irdash already holds for the track (`dash\maps\<key>.json`). No new download.
   Pit entry and exit are the median of where the car entered and left the pit lane in the files read.
3. **The shape of the track** (SIMRacingApps outline copies, Apache 2.0, `data\corners\library\<TrackName>.json`; Peter said yes to these 2026-10-10):
   where neither of the above has a list, the same maths runs on the outline (curvature of the 720-point loop). The bends are numbered `T1..Tn`, marked
   `source auto / basis outline`, never given names, and shown without a credit line. Checked against Lovely on seven tracks that have both: every Lovely
   stretch but one holds a bend found from the outline, plus a few real extra bends (Monza 13 against Lovely's 8, Oulton 19 against 13). An oval comes out as
   two long bends, so each is cut in half: Turns 1-2 and 3-4 (`OvalSplit`, only for exactly two long bends on opposite sides of the lap).
   irdash's own map reads the same copies first (`TrackMaps.FromLibrary`), so the outline needs no internet either.
4. Nothing: outline only (or the lap bar when there is no outline). The map asks again every minute, so labels appear by themselves once corners exist.

**Lovely names win; numbers are ours.** Lovely's own numbering ("Turn 5") has gaps and mixed names, so it is kept only as `official` and the lap-order number
is `n`. Road Atlanta: The Esses is T5, Lovely's "Turn 5" is T6, "Turn 10A" is T11. A plain "Turn N" is not shown as a name; a real name is.
The title of a corner on a list is its name if it has one, else `T<n>` (`turn.label` in the browser).

## When irdash looks for corners itself
Only when a page asks about a track that has no corner list and Peter has driven it. A background thread (below normal priority) waits until the sim is
closed (`Program.IsDriving` and the SDK link both off), reads at most 4 telemetry files for that track (quickest known lap first), writes the auto file and logs
`corners: <key> - 18 corners from ...`. A failed try is not repeated for 15 minutes. `GET /corners?...&build=1` does it now (refused with 503 while he drives).
Lovely tracks are never built (Lovely wins).

## The endpoint
`GET /corners?track=<TrackName or display name>&config=<layout name>&id=<TrackID>&key=<map key>` (all but `track` optional; the key is made from id and track,
and the id from a key like `t127-roadatlanta-full`).
```
{ "source": "lovely" | "auto" | "none", "basis": "" | "telemetry" | "outline", "track", "config", "key", "lovely": "roadatlanta-full.json",
  "lovelyListed": true, "pending": false, "updated", "detail",
  "turns": [ { "n": 5, "name": "The Esses", "official": "", "pct0": 0.26, "pctApex": 0.2757, "pct1": 0.332, "source": "lovely" }, ... ],
  "pitIn": 0.94, "pitOut": 0.131, "pitSource": "lovely", "sf": 0, "sectors": [0, 0.168, 0.443, 0.787],
  "credit": "Corner names: Lovely Track Data · CC BY-NC-SA 4.0" }
```
`pending` = a search for corners is queued. Where Lovely gives only a stretch, the apex is moved to the tightest bend inside it when irdash holds an outline
(Lovely's own apex marker is kept where the file has one). Other routes: `GET /corners/detect?file=<name>.ibt[&lap=n]` (dry run on one file, nothing written;
telemetry folder names only; 503 while driving), `GET /corners/audit` (the coverage list below).

## In the browser
`corners.js` (loaded by `map.js` itself if the page did not include it, so every page that has the map has it):
- `Corners.load(track, config)` -> promise of the answer above; `track` may be `S.track`. Cached (10 min; a "none" answer is asked again after 45 s, 5 s while pending).
- `Corners.at(pct)` -> `{ turn, next, ahead, prev }`: the corner a lap fraction is in, the next apex and how far.
- `Corners.draw(ctx, project, opts)`: `project(pct)` returns the canvas `[x, y]` of a lap fraction. Draws start/finish and sector ticks, pit in/out marks,
  a gold ring with the corner number at each apex (a ring, not a solid dot, so it is never mistaken for a car), the name in small caps beside it where it does not
  touch the road, another label or a disc, and the credit line. `opts`: `data` (default the last answer), `w`, `h`, `scale`, `names`, `ticks`, `pit`, `credit`,
  `sectors`, `avoid` (rectangles to keep clear). Returns `{ discs, names }` for hover use. Sizes follow the canvas (readable at 300 px and at 1500 px).
- `TrackInfo` (in `map.js`) keeps its old shape for the debrief, brief, guest and sessions pages: `TrackInfo.data.turns[] = { pct (apex), label, n, name, pct0, pct1 }`,
  `pitIn`, `pitOut`, `credit`; plus `TrackInfo.raw` (the whole answer) and `TrackInfo.version`.
- Pages that draw their own outline: `Corners.draw(g, pct => myProject(TrackMap.at(pct)), { data: TrackInfo.raw, w, h, ticks: false, credit: false })`.

## Updating the offline copy
`powershell -ExecutionPolicy Bypass -File data\corners\fetch-lovely.ps1 [-Refresh]` (plain GETs of `manifest.json` and the track files for the folders in
`C:\Program Files (x86)\iRacing\tracks`; every file is parsed as JSON and checked before it is kept; nothing is run). `fetch-library.ps1` does the same for the SIMRacingApps outlines (one file per owned track, one at a time, throttled, each checked for 150+ lap-keyed points and a closed loop). Run `audit.ps1` afterwards to redo the tables below.

## Limits
- Lovely lists 35 of the 85 layouts it covers with sectors and pit lane only (no corner names): those are "Lovely: yes, 0 turns" and use detection once driven (or the outline copy where there is one).
- SIMRacingApps keeps outlines under older track names for several of Peter's tracks (Barber, Charlotte, Silverstone, Sonoma 2025 ...) and only a placeholder for others; a copy is only used when the name matches iRacing's TrackName exactly. 11 owned tracks have no outline copy and no Lovely list (listed below).
- The library's pit road is keyed over the whole lap, so it says nothing about pit entry and exit; pit marks come from Lovely or from his own laps only.
- Ovals: Lovely has no ovals; an oval is found as two long bends and cut into Turns 1-2 and 3-4 (see above). Tracks with more than two long bends are left as found.
- Detection cannot find a corner that is flat-out and almost straight, and may cut a long sweeper in two. Compare with Lovely on Road Atlanta in the test.
- Lovely's files come in three shapes (start+end, start+end+marker, marker only); all three are read. One file spells `name` as `naem`.

## Coverage of what Peter owns
<!-- coverage:start -->
_Generated 2026-10-10 00:51 by `data\corners\audit.ps1`._

### The 43 tracks Peter owns

A track counts as covered when at least one installed layout has numbered corners. "Best layout" is the layout with the most corners.

| Track (folder) | Layouts installed | With corners | Best layout | Turns | Source used |
|---|---|---|---|---|---|
| Algarve International Circuit (`algarve`) | 4 | 1 | gp | 15 | Lovely |
| Barber Motorsports Park (`barber`) | 1 | 0 | - | 0 | none: not in Lovely; no outline copy under his installed layout names; not driven yet |
| Charlotte Motor Speedway (`charlotte`) | 9 | 0 | - | 0 | none: not in Lovely; no outline copy under his installed layout names; not driven yet |
| Concordhalf (`concordhalf`) | 1 | 0 | - | 0 | none: not in Lovely; no outline copy under his installed layout names; not driven yet |
| Daytona International Speedway (`daytona`) | 12 | 2 | (single layout) | 12 | Lovely |
| Laguna Seca (`lagunaseca`) | 2 | 2 | (single layout) | 15 | Lovely |
| Lakeland (`lakeland`) | 1 | 1 | dirt | 4 | from the track outline (SIMRacingApps copy) |
| Langley (`langley`) | 1 | 0 | - | 0 | none: not in Lovely; no outline copy under his installed layout names; not driven yet |
| Lanier (`lanier`) | 1 | 1 | dirt | 4 | from the track outline (SIMRacingApps copy) |
| Circuit de Ledenon (`ledenon`) | 1 | 1 | (single layout) | 8 | Lovely |
| Circuit des 24 Heures du Mans (`lemans`) | 2 | 2 | full | 21 | Lovely |
| Limaland (`limaland`) | 1 | 0 | - | 0 | none: not in Lovely; no outline copy under his installed layout names; not driven yet |
| Lime Rock Park (`limerock`) | 5 | 2 | 2019/classic | 8 | Lovely |
| Long Beach (`longbeach`) | 1 | 1 | (single layout) | 11 | Lovely |
| Autodromo Nazionale Monza (`monza`) | 9 | 1 | full | 13 | Lovely |
| Mount Washington (`mtwashington`) | 2 | 0 | - | 0 | none: not in Lovely; no outline copy under his installed layout names; not driven yet |
| Mugello (`mugello`) | 2 | 2 | gp | 15 | Lovely |
| Circuito de Navarra (`navarra`) | 3 | 1 | speedlong | 15 | Lovely |
| Nuerburgring (`nurburgring`) | 2 | 1 | nordschleife | 32 | Lovely |
| Okayama International Circuit (`okayama`) | 2 | 1 | full | 11 | Lovely |
| Oran Park Raceway (`oran`) | 6 | 1 | gp | 12 | Lovely |
| Motorsport Arena Oschersleben (`oschersleben`) | 4 | 4 | alt | 14 | Lovely |
| Oulton Park (`oulton`) | 8 | 2 | international | 19 | Lovely |
| Oxford (`oxford`) | 2 | 1 | oval | 4 | from the track outline (SIMRacingApps copy) |
| Phoenix (`phoenix`) | 3 | 1 | road | 9 | from the track outline (SIMRacingApps copy) |
| Pocono (`pocono`) | 5 | 1 | international | 11 | from the track outline (SIMRacingApps copy) |
| Road America (`roadamerica`) | 4 | 2 | 2026/full | 13 | Lovely |
| Road Atlanta (`roadatlanta`) | 3 | 1 | full | 14 | Lovely |
| Rudskogen (`rudskogen`) | 1 | 1 | (single layout) | 14 | Lovely |
| Sebring International Raceway (`sebring`) | 3 | 1 | international | 17 | Lovely |
| Silverstone (`silverstone`) | 5 | 0 | - | 0 | none: not in Lovely; no outline copy under his installed layout names; not driven yet |
| Skidpad (`skidpad`) | 1 | 0 | - | 0 | none: not in Lovely; no outline copy under his installed layout names; not driven yet |
| Snetterton (`snetterton`) | 3 | 1 | 300 | 11 | Lovely |
| Sonoma Raceway (`sonoma`) | 10 | 0 | - | 0 | none: not in Lovely; no outline copy under his installed layout names; not driven yet |
| Southboston (`southboston`) | 1 | 1 | (single layout) | 4 | from the track outline (SIMRacingApps copy) |
| Southernnational (`southernnational`) | 1 | 0 | - | 0 | none: not in Lovely; no outline copy under his installed layout names; not driven yet |
| Spa-Francorchamps (`spa`) | 7 | 6 | combined | 15 | Lovely |
| Summit Point Raceway (`summit`) | 6 | 1 | summit/raceway | 10 | Lovely |
| Thompson (`thompson`) | 1 | 1 | (single layout) | 4 | from the track outline (SIMRacingApps copy) |
| Tsukuba Circuit (`tsukuba`) | 8 | 2 | 1kfull | 10 | Lovely |
| Virginia International Raceway (`virginia`) | 5 | 5 | 2022/grand | 35 | Lovely |
| Wildwest (`wildwest`) | 1 | 0 | - | 0 | none: not in Lovely; no outline copy under his installed layout names; not driven yet |
| Winton Motor Raceway (`winton`) | 3 | 2 | national | 10 | Lovely |

**32 of 43 owned tracks have numbered corners** (25 from Lovely Track Data, 0 found in his own laps, 7 from the shape of the track outline). The others are drawn as an outline without labels until he drives a clean lap there (then irdash finds the corners itself) or Lovely adds them.

### Layouts he has driven (from the session text of his .ibt files: TrackID / TrackName / TrackConfigName)

| iRacing TrackName | Layout name | Telemetry files | Lovely | Turns | Source used |
|---|---|---|---|---|---|
| `limerock 2019 gp` | Lime Rock Park Grand Prix | 9 | yes | 5 | Lovely |
| `okayama full` | Okayama International Circuit Full Course | 4 | yes | 11 | Lovely |
| `roadatlanta full` | Road Atlanta Full Course | 111 | yes | 14 | Lovely |
| `sebring international` | Sebring International Raceway International | 15 | yes | 17 | Lovely |
| `sonoma long` (older layout, no longer installed) | Sonoma Raceway Long | 2 | no | 18 | found in his laps (outline) |
| `tsukuba 2kfull` | Tsukuba Circuit 2k Full  | 1 | yes | 9 | Lovely |

### Every installed layout

| Track folder | Layout | Lovely | Turns | Source used | Driven |
|---|---|---|---|---|---|
| `algarve` | gp | yes | 15 | Lovely |  |
| `algarve` | gpchicane | no | 0 | none |  |
| `algarve` | moto | no | 0 | none |  |
| `algarve` | motochicane | no | 0 | none |  |
| `barber` | 2026 | no | 0 | none |  |
| `charlotte` | 2025/legendsoval | no | 0 | none |  |
| `charlotte` | 2025/legendsrc2025 | no | 0 | none |  |
| `charlotte` | 2025/legendsrclong | no | 0 | none |  |
| `charlotte` | 2025/legendsrcshort | no | 0 | none |  |
| `charlotte` | 2025/oval | no | 0 | none |  |
| `charlotte` | 2025/rallycrosslong/nojoker | no | 0 | none |  |
| `charlotte` | 2025/roval2019 | no | 0 | none |  |
| `charlotte` | 2025/roval2025 | no | 0 | none |  |
| `charlotte` | 2025/rovalnochicanes | no | 0 | none |  |
| `concordhalf` | (single layout) | no | 0 | none |  |
| `daytona` | (single layout) | yes | 12 | Lovely |  |
| `daytona` | 2011/bike | no | 0 | none |  |
| `daytona` | 2011/oval | no | 0 | none |  |
| `daytona` | 2011/road | yes | 12 | Lovely |  |
| `daytona` | 2011/roadnascar2020 | no | 0 | none |  |
| `daytona` | 2011/short | no | 0 | none |  |
| `daytona` | bike | no | 0 | none |  |
| `daytona` | oval | no | 0 | none |  |
| `daytona` | rallycross/long/nojoker | no | 0 | none |  |
| `daytona` | rallycross/short/nojoker | no | 0 | none |  |
| `daytona` | road | no | 0 | none |  |
| `daytona` | short | no | 0 | none |  |
| `lagunaseca` | (single layout) | yes | 15 | Lovely |  |
| `lagunaseca` | school | yes | 10 | Lovely |  |
| `lakeland` | dirt | no | 4 | from the track outline (SIMRacingApps copy) |  |
| `langley` | (single layout) | no | 0 | none |  |
| `lanier` | dirt | no | 4 | from the track outline (SIMRacingApps copy) |  |
| `ledenon` | (single layout) | yes | 8 | Lovely |  |
| `lemans` | full | yes | 21 | Lovely |  |
| `lemans` | nochicane | yes | 19 | Lovely |  |
| `limaland` | (single layout) | no | 0 | none |  |
| `limerock` | 2019/chicanes | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `limerock` | 2019/chicanewestb | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `limerock` | 2019/classic | yes | 8 | Lovely |  |
| `limerock` | 2019/gp | yes | 5 | Lovely | yes |
| `limerock` | 2019/school | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `longbeach` | (single layout) | yes | 11 | Lovely |  |
| `monza` | combinedchicanes | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `monza` | full | yes | 13 | Lovely |  |
| `monza` | gpSecondChicane | no | 0 | none |  |
| `monza` | historic | no | 0 | none |  |
| `monza` | historicSecondChicane | no | 0 | none |  |
| `monza` | junior | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `monza` | nochicane | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `monza` | oval | no | 0 | none |  |
| `monza` | ovalLeft | no | 0 | none |  |
| `mtwashington` | climb | no | 0 | none |  |
| `mtwashington` | reverse | no | 0 | none |  |
| `mugello` | gp | yes | 15 | Lovely |  |
| `mugello` | short | yes | 7 | Lovely |  |
| `navarra` | speedlong | yes | 15 | Lovely |  |
| `navarra` | speedmedium | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `navarra` | speedshort | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `nurburgring` | nordschleife | yes | 32 | Lovely |  |
| `nurburgring` | nordschleifetourist | no | 0 | none |  |
| `okayama` | full | yes | 11 | Lovely | yes |
| `okayama` | short | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `oran` | gp | yes | 12 | Lovely |  |
| `oran` | moto | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `oran` | north | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `oran` | northa | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `oran` | northb | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `oran` | south | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `oschersleben` | alt | yes | 14 | Lovely |  |
| `oschersleben` | bcourse | yes | 8 | Lovely |  |
| `oschersleben` | ccourse | yes | 8 | Lovely |  |
| `oschersleben` | gp | yes | 10 | Lovely |  |
| `oulton` | fosters | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `oulton` | fosterswithhislop | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `oulton` | intbrittens | no | 0 | none |  |
| `oulton` | international | yes | 19 | Lovely |  |
| `oulton` | inthislop | yes | 12 | Lovely |  |
| `oulton` | intnochicane | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `oulton` | island | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `oulton` | islandhistoric | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `oxford` | oval | no | 4 | from the track outline (SIMRacingApps copy) |  |
| `oxford` | short | no | 0 | none |  |
| `phoenix` | oval | no | 0 | none |  |
| `phoenix` | rallycross/nojoker | no | 0 | none |  |
| `phoenix` | road | no | 9 | from the track outline (SIMRacingApps copy) |  |
| `pocono` | east | no | 0 | none |  |
| `pocono` | international | no | 11 | from the track outline (SIMRacingApps copy) |  |
| `pocono` | north | no | 0 | none |  |
| `pocono` | oval | no | 0 | none |  |
| `pocono` | south | no | 0 | none |  |
| `roadamerica` | 2026/bend | yes | 13 | Lovely |  |
| `roadamerica` | 2026/east | no | 0 | none |  |
| `roadamerica` | 2026/full | yes | 13 | Lovely |  |
| `roadamerica` | 2026/west | no | 0 | none |  |
| `roadatlanta` | club | no | 0 | none |  |
| `roadatlanta` | full | yes | 14 | Lovely | yes |
| `roadatlanta` | short | no | 0 | none |  |
| `rudskogen` | (single layout) | yes | 14 | Lovely |  |
| `sebring` | club | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `sebring` | international | yes | 17 | Lovely | yes |
| `sebring` | modified | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `silverstone` | gp | no | 0 | none |  |
| `silverstone` | historicgp | no | 0 | none |  |
| `silverstone` | international | no | 0 | none |  |
| `silverstone` | national | no | 0 | none |  |
| `silverstone` | southern | no | 0 | none |  |
| `skidpad` | (single layout) | no | 0 | none |  |
| `snetterton` | 100 | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `snetterton` | 200 | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `snetterton` | 300 | yes | 11 | Lovely |  |
| `sonoma` | 2025/irl05 | no | 0 | none |  |
| `sonoma` | 2025/irl08 | no | 0 | none |  |
| `sonoma` | 2025/irl12 | no | 0 | none |  |
| `sonoma` | 2025/nascarlong | no | 0 | none |  |
| `sonoma` | 2025/nascarshort | no | 0 | none |  |
| `sonoma` | 2025/oval | no | 0 | none |  |
| `sonoma` | 2025/short | no | 0 | none |  |
| `sonoma` | 2025/sportscar | no | 0 | none |  |
| `sonoma` | 2025/sportscaralt | no | 0 | none |  |
| `sonoma` | rallycross | no | 0 | none |  |
| `southboston` | (single layout) | no | 4 | from the track outline (SIMRacingApps copy) |  |
| `southernnational` | (single layout) | no | 0 | none |  |
| `spa` | 2024/bike | no | 0 | none |  |
| `spa` | 2024/combined | yes | 15 | Lovely |  |
| `spa` | 2024/low | yes | 15 | Lovely |  |
| `spa` | 2024/up | yes | 15 | Lovely |  |
| `spa` | combined | yes | 15 | Lovely |  |
| `spa` | low | yes | 15 | Lovely |  |
| `spa` | up | yes | 15 | Lovely |  |
| `summit` | jefferson | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `summit` | jefferson/rev | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `summit` | summit/oval | no | 0 | none |  |
| `summit` | summit/raceway | yes | 10 | Lovely |  |
| `summit` | summit/raceway/school | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `summit` | summit/short | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `thompson` | (single layout) | no | 4 | from the track outline (SIMRacingApps copy) |  |
| `tsukuba` | 1kchicane | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `tsukuba` | 1kfull | yes | 10 | Lovely |  |
| `tsukuba` | 1kfullreverse | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `tsukuba` | 1kouter | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `tsukuba` | 2kchicane | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `tsukuba` | 2kfull | yes | 9 | Lovely | yes |
| `tsukuba` | 2kshort | yes | 0 | none (Lovely lists sectors / pit lane only) |  |
| `tsukuba` | jumptrucks | no | 0 | none |  |
| `virginia` | 2022/full | yes | 16 | Lovely |  |
| `virginia` | 2022/grand | yes | 35 | Lovely |  |
| `virginia` | 2022/north | yes | 21 | Lovely |  |
| `virginia` | 2022/patriot | yes | 10 | Lovely |  |
| `virginia` | 2022/south | yes | 10 | Lovely |  |
| `wildwest` | full | no | 0 | none |  |
| `winton` | club | yes | 10 | Lovely |  |
| `winton` | national | yes | 10 | Lovely |  |
| `winton` | rallycross | no | 0 | none |  |
<!-- coverage:end -->
