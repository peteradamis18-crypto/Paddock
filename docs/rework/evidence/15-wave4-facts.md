# Evidence 15: the review family as it is (scouted 2026-11-14 for wave 4; file:line references are approximate)

## Server (`dash/src/`)
- Routes (irdash.cs ~556-590): `/analysis/lap?id&lap&ref` (analysis.cs Route ~199: corners with diffs + a cause),
  `/analysis/session?id|last&lap&corners=1` (sessionreview.cs ~33: lap list counted/OFF/INVALID, iRacing sectors, optimal,
  consistency, prev/ever best, notes, turns), `/analysis/coach?id` (coach.cs ~26), `/analysis/deep` (deepdive.cs ~952),
  `/analysis/raw` (rawdata.cs ~61), `/analysis/channels` (workbench.cs ~25: binary PWB1 = JSON header + Float32 arrays
  on a 1 m grid), `/analysis/career` (career.cs: per-session bests, best-5, per-corner bests/medians), `/analysis/race`
  (field.cs ~1011: the live field log `vault\field\f<ts>-<n>.json`), `/debrief?id|last` (debrief.cs ~75: result,
  positions by lap, pace vs field, costliest corners with clips cut by ffmpeg on a BelowNormal thread), `/corners`
  (corners.cs ~297), `/sessions`, `/ibt/laps`, `/ibt/lap` (data.cs ~146), `/workbench/cmd|state` (deck wb-* commands).
- Telemetry reading: `IbtFile.Open` (ibtfile.cs ~31; 60 records/s, read-only); `LapStore.ForFile` (lapstore.cs ~161:
  cuts and judges laps, cached in memory and in `dash\data\laps\<file>.json`; `Peek` never reads the .ibt);
  `Analysis.Load` (analysis.cs ~329) reads a whole file (~80 MB for a full session) into arrays and caches `Sess`/`LapTrace`
  (1 m grid: Tm, Spd/Brk/Thr, 24 Mini, SectorT, RecA/RecB). `Gather` (~888) loads up to 40 other sessions' traces per
  request (the thing PLAN wants replaced by the index). Everything runs on HTTP request threads (503 while driving,
  BelowNormal); only career.cs ~470 uses `Jobs.Run`.
- Corners (corners.cs): `CornerSet.Turns` (N, Name, Official, P0/Pa/P1 lap fractions, Source lovely|auto); `Resolve`
  (~573): Lovely (`data\corners\lovely\roadatlanta-full.json` exists) → auto from the best clean lap's yaw rate (~818,
  saved in `data\corners\auto\`) → outline library. `Analysis.LoadCorners` (~243) still caches empty sets (~255).
  Per corner per lap (`Met`, analysis.cs ~38-45, `MeasureOne` ~593): Time, InTime/OutTime, BrakeM (brake through 10 %),
  Entry, Min/MinM, Pickup (throttle through 90 % after the apex), Exit (100 m after the apex). `CompareMet` (~790):
  dTime etc. and ONE cause (rules in the file header ~6-13: ≥ 0.05 s, exactly one metric clearly different).
- Coach (coach.cs): reference = the counted best lap with a clean trace; rhythm laps within 2 %; a habit needs ≥ 3 rhythm
  laps, median loss ≥ 0.05 s in at least half the laps; fixed instruction table (`AppendFocus` ~209-215); facts templated
  in mph (`units:"imperial"`); JSON focus[] (n, label, loss, lost, laps, phase, code, say, facts[], example, best),
  inconsistent[], ref, summary, mode (habit|two|pb|partial|drive; `CoachFew` for < 3 laps).
- References: Session Review's reference = best valid lap of OTHER sessions else the second-best of this one (differs
  from PLAN: this session's best clean counted lap); `BuildOptimal` (analysis.cs ~703) joins 24 mini-sectors of Pure
  laps; iRacing sectors from `SplitTimeInfo` (statebuilder.cs ~437 live; the YAML in the file). The time gap is computed
  client-side from the two laps' time arrays (workbench.js ~202, 427); refs.cs is the delta bar's PB (not for review).
- Lap truth (W0-6, lapstore.cs, `LapRules.Version=4`): `Judge` ~45, `LapRec` (N, Time, Counted, Why, Pit, Off, Incident,
  Start, StartRecord/EndRecord, SessionNum), `FileLaps` (BestLap, CountedLaps, Car, Track, Config, TrackId, StartUtc),
  `LapStore.Best` ~148, `OfSession` ~398. 12 Nov 09:28 race: 10 laps, 7 counted, best lap 9 = 1:33.832.
- sessmatch.cs: pure moment→video mapping; partial.cs: out/in/part laps on the 1 m grid (never a reference);
  rawdata.cs: `DriveSummary`, `StillWriting`.

## Web (`dash/www/`)
- Shell contract (app/shell.js ~13): `export default { name, title, mount(el, ctx), unmount(), onState(state, changed) }`,
  `ctx = { data, Fmt, go, close, banner, kidsOn(), driving(), opts }`; pages never poll; Esc goes HOME unless the page
  preventDefault's; `app/pages/review.js` is a 12-line host of `v2/sessions.html?embed=1&at=` today; the deck's
  sessions/coach/review requests all map to `review`. `app/lib/data.js` (`data.json(url, ttl)`, `data.fetch`, `data.on`,
  `data.onList`), `format.js` (`Fmt.lap/delta/dur`), `design.css` tokens (`--gold`, `--gain`, `--loss`, `--purple`,
  `--cyan`, `--t-hero 240 … --t-label 20`, `.btn`, `.hdr`, `.tbl`, `.empty`, `.banner`). No `lib/chart.js`, no `lib/map.js` yet.
- Old pages to replace: coach.* (corner cards, WATCH side by side via `/api/rec/for` + `/api/rec/session-video`, SHOW ME →
  workbench), sessionreview.* (timing screen, SVG map, hard-coded MY name/number, a 1 s timer), sessions.* (list + `/ibt/*`
  traces, nested workbench/rawdata frames, 20 s and 15 s pollers), debrief-v4.* (after-session race screen from `/debrief`,
  5 s poller), rawdata.* (ALL THE DATA, 800 ms timer), workbench.js + 6 companions (274 KB: pages DRIVER, GRIP & BALANCE,
  BRAKING, TYRES & STINT, SUSPENSION, SPLITS + CAREER, RACE, PRO, VIDEO; `Display` canvas engine, `MapView`; pollDeck
  POSTs `/workbench/cmd` ≤ every 2 s; Esc = zoom reset), corners.js (`Corners.load/get/at/draw`), map.js (`TrackMap`:
  the layered renderer PLAN keeps; outline from `/trackmap`; retries while no outline), vault.js detail view (openWorkbench).
- `v2/map.js` is the one map renderer to wrap; `data/iracing-maps` holds iRacing's own drawings by track id.

## Fixtures and real data
- `tests/fixtures/race-12nov*.ibt` (12 Nov 09:28 Road Atlanta GR86: laps 0-1; lap 9; lap 9 whole; ends 1 s after lap 10),
  `race-12nov-sidecar.json`; `tests/fixtures/race/*.json` (field logs: caution, pit, qualifying, practice, multiclass).
- Telemetry (`C:\Users\peter\OneDrive\Documents\iRacing\telemetry\`, read-only, one file at a time, BelowNormal, only with
  sim=False): 13 Nov `toyotagr86_roadatlanta full 2026-11-13 16-27-02.ibt` (83 MB, Practice + Lone Qualify + Race P4 of 19),
  `20-27-08.ibt` (84 MB, the evening race), `16-19-00.ibt` (qualifying, 21 MB); 12 Nov `09-28-07.ibt` (the lap-truth race);
  11 Nov Nordschleife/Snetterton/Charlotte files. Lap caches in `dash/data/laps/*.json` (13 Nov 16-27-02: 10 laps, 6 counted,
  best lap 8 = 95.106). Field logs `vault\field\f20261113-*.json`. Sidecars in `vault\saved` (13 Nov race
  `20261113-212702`, uniqueId 3, laps with clean/counted/pb, incidents) and `vault\sessions`.
- Tests today: coach-test (COPY-RULES wording lint on real files), corners-test (38), analysis-test (110), session-review-test
  (96), lap-truth-test, laprules-test, workbench-test (209), raw-data-test (22), debrief-test (103), career-test (110),
  identity-test (sessmatch), shell-test (103), races-page-test.

## Open items touching REVIEW
- Coach Dave Delta: not integrated (decided); an "Open Delta" link only if installed (no code yet); the Delta test protocol
  (`docs/rework/DELTA-TEST.md`) waits for a yes. Units on cards: the coach says mph, the review pages km/h: Peter's
  iRacing is imperial (DisplayUnits): follow it. The Pi Toolbox comparison (06 §4) is W4-6's write-up.
