# 10 - Code audit: the top-screen web app (`dash\www\v2`, and the old `dash\www` root)

Read-only audit, 2026-11-13. No file was changed except this one. Evidence: every `*.html`, `*.js` and `*.css` in `dash\www\v2`
and `dash\www`, `dash\irdash.ini`, and the server code in `dash\src\irdash.cs` (`Server.Handle`, `Stream`, `Send`, `OpenDashboard`).
Nothing was run. Counts come from grep over the files, so treat them as close, not exact.

Severity words used:
- **breaks Peter**: he sees something wrong, cannot read it, or a press does nothing.
- **wrong**: the code does not do what its comment or name says, or does needless work.
- **fragile**: works today but one small change or one bad day will break it.
- **cleanup**: dead or copied code. Safe to remove once a test proves it.

## Short answer

1. **The in-car screen Peter actually sees is the dense 8-panel one (`ui.js`), not the calm one (`drive.js`).** irdash opens
   `http://localhost:8199/v2/` with no query (`irdash.cs` `OpenDashboard("")`). `Drive.want()` returns false unless the URL has
   `?drive=1` or TV VIEW is on, and `tv_view=0` in `irdash.ini`. So the readable design is only a test preview. The live one has
   10-13 px labels.
2. **The top screen asks irdash for something about 16 times a second while idle, and about 11 times a second while he drives**,
   on top of a 30 Hz telemetry stream. Each of those is a new TCP connection and a new thread in irdash (`Connection: close`).
   About 14 separate timers each poll their own endpoint. Not proven to cause the stutter, but it is steady work on the race PC.
3. **About 40 % of HOME's JavaScript is dormant** (134 KB of 332 KB): `official.js` (its element no longer exists), `idle.js`
   (writes to elements that no longer exist, still fetches `/career` every minute), `cars.js` (switched off by `CARS_DRAWN = false`),
   `debrief.js` + `sessionreview.js` (only for `?debrief=demo`), `tv.js` and `drive.js` (off by default), `demo.js` (only `?demo=1`).
4. **There is no shell.** Nine different "full-screen iframe with a close button" hosts live in eight files. Pages nest up to four
   iframes deep (HOME > after-session Coach > Session Review > Analysis), each loading its own helper copies and its own pollers.
5. **Four design systems, 203 different hex colours, 51 different font sizes, 9 files with their own `:root`.** Only `home.css`
   has a type scale.
6. **When irdash is down, HOME says nothing.** The "Paddock program not running" line exists in code but its container is hidden twice
   (`hidden` attribute in `index.html` and `display:none !important` in `home.css`). HOME keeps its old numbers and RIG ON looks pressable.
7. The old root files `dash\www\*.js/.css/.html` are dead (details below).

## Is `dash\www` (v1, the root files) dead?

Yes, for Peter. Evidence:
- `dash\irdash.ini` has `page=v2/`. `irdash.cs` builds the window address as `"http://localhost:" + port + "/" + cfg.Page + query`,
  so the kiosk opens `/v2/`.
- The server serves any file under `dash\www` (`Server.Handle`: a path ending in `/` gets `index.html`; paths outside `www` are refused).
  So `/` still serves the v1 page, but nothing asks for it: no test, no C# code, no deck key. The only mention is
  `dash\README.md` line 39 ("Preview without the sim: `http://localhost:8199/?demo=1`"), which is out of date.
- `/version` reads every file under `dash\www` (all subfolders), so editing a v1 file still reloads the live v2 page.

Safe to delete: `dash\www\core.js`, `demo.js`, `index.html`, `map.js`, `style.css`, `ui.js` (about 78 KB). Fix the README line in the
same change. `dash\www\phone\` is live (the iPhone app) and was not audited here.

## Dead-file list (v2)

| File | Why dead | Severity |
|---|---|---|
| `v2\preview.png` (299 KB) | Referenced by no html, js, css, test or C# file. Ships in the web root. | cleanup |
| `v2\official.js` + `official.css` | `Official.init()` returns at once: it needs `#idleOfficial`, which HOME v3 no longer has. Loaded on every HOME start for nothing. `tests\official-test.ps1` still refers to it. | cleanup |
| `v2\idle.js` | Writes `#idleLast` and `#idleWeek`, which no longer exist. Still fetches `/career` every 60 s and runs a 1 s timer that only calls `Home.clock()` (Home has its own). | wrong |
| `v2\cars.js` | `CARS_DRAWN = false` (Peter turned the drawn cars down, PL-1). Only `window.PCarsDormant` is set, for `tests\race-field-test.ps1`. Loaded by HOME and Analysis. | cleanup |
| `v2\debrief.js` + `debrief.css` | The after-session trigger moved to `debrief-v4.js` (D-03). `Debrief.show()` is only called for `?debrief=demo`. `Debrief.frame()` still runs on every telemetry frame to track a stint nobody reads. | cleanup |
| `v2\sessionreview.js` + `.css` **inside index.html** | Only `debrief.js` mounts it in HOME, and only for the demo. (The standalone `sessionreview.html` is live: Coach's ALL LAPS opens it.) | cleanup |
| `v2\sr-demo.json` (47 KB) | Sample data for `?debrief=demo` only. | cleanup |
| `vaultlive.js` `linkDebrief()` | Every 700 ms looks for `#debrief .db-bench`, which only the dead `debrief.js` makes. | cleanup |
| `style.css` idle rules (`.idle-line`, `.idle-mark` at 860 px, `.idle-glow`, `.idle-week`, `.idle-official`, `.idle-foot`, `.hero`, `.idle-mid`) | `home.css` line 14 hides them all with `display:none !important`. | cleanup |
| `map.js` in `sessions.html` | Sessions uses nothing from it (its comment says "for TrackInfo", but `sessions.js` never calls TrackInfo). It also pulls in `corners.js`. | cleanup |
| `demo.js` in `index.html` (14 KB) | Only used with `?demo=1`. Keep for tests; load it only when asked. | cleanup |
| `tv.js` (26 KB) | TV VIEW is off (`tv_view=0`) and has no key on MAIN. Its `/tv` poll still runs every 700 ms. `Tower.recorder()` (the REC pill) lives here and is only used by `drive.js`. | wrong |
| Unused functions | `vault.js isKeeper`, `workbench-race.js who0`, `home.js nyWd`, `tv.js fmtTime`. Small. | cleanup |

Not dead, but flagged: `brief.js` (pre-session brief, live), `race.js` (SoF line, live), `drive.js` (only via `?drive=1` or TV VIEW; see finding 1).

## URL switches and which in-car dashboard is live

| Switch | Read by | What it does | Used live? |
|---|---|---|---|
| `?demo=1` (`&speed=`, `&track=`, `&trackid=`) | `core.js Conn.start`, `demo.js`, `map.js` | made-up 21-car race | irdash tray menu "Open demo" only |
| `?drive=1` | `drive.js want()` | the calm in-car layout | **no** (tests and pictures only) |
| `?grid=1` | `drive.js want()` | forces the old grid even with TV on | no |
| `?hz=` | `core.js` | stream rate (default 30) | no |
| `?intro=1`, `?hold=1` | `intro.js` | force the startup animation, keep last frame | no |
| `?debrief=demo` | `debrief.js` | sample session review | no |
| `?debrief4=<id>` | `debrief-v4.js` | open the after-race screen for an id | no |
| `?sessions=1`, `?vault=1`, `?perf=1`, `?races=1` | `pagehost.js` | open that page at start | no |
| `?onow=` | `official.js` | pretend time | dead file |
| `?carbase=` | `carpics.js` | picture server base | tests |
| `?embed=1` | sessions, vault, perf | page is inside the HOME host | yes |

**Live in the car = `ui.js`** (strip + standings + relative + timing + map + car panel). Both layouts run: `ui.js`'s loop calls
`Drive.tick()` 10 times a second, which checks `want()` and returns. Fix: make `drive.js` the default (or delete it), not both.

## Polling table (the stutter question)

Counted from the source: each timer, its interval and its guard.

### HOME idle (sim off, no page open)

| Endpoint | Who asks | Every | Per second | Guard |
|---|---|---|---|---|
| `/keymsg` | `keymsg.js` | 400 ms | 2.50 | page hidden |
| `/api/kids` | `ui.js KidsMode` | 500 ms | 2.00 | page hidden |
| `/api/tow-wait` | `ui.js TowWait` | 500 ms | 2.00 | page hidden |
| `/tv` | `ui.js` loop calls `Tv.poll()` | 700 ms | 1.43 | none (runs while driving too) |
| `/nav`, asked **twice** (the `sessions` and `coach` entries share it) | `pagehost.js` | 1.5 s | 1.33 | stops while driving |
| `/vault/nav`, asked **twice** (PageHost and VaultLive) | `pagehost.js`, `vaultlive.js` | 1.5 s | 1.33 | stops while driving |
| `/perf/nav` | `pagehost.js` | 1.5 s | 0.67 | stops while driving |
| `/guest` | `guest.js` | 1 s | 1.00 | page hidden |
| `/mydrive` | `mydrive.js` | 1.2 s | 0.83 | page hidden |
| `/doctor` | `rig.js` | 1.5 s | 0.67 | stops while driving |
| `/overlays` | `rig.js` | 1.5 s (6 s driving) | 0.67 | |
| `/health` | `ui.js` (3 s) + `home.js` (5 s) | | 0.53 | |
| `/showcase?who=page` | `intro.js` | 3 s | 0.33 | |
| `/vault/recorder` | `home.js next()` | 5 s | 0.20 | |
| `/version` | `core.js` | 15 s | 0.07 | |
| `/home`, `/career` (twice: home + dead idle.js), `/realworld`, `/watch/coverage`, `/phone/qr` | `home.js`, `idle.js` | 30-60 s | 0.12 | |
| `/stream` (SSE) | `core.js` | one open connection | about 1 status event/s | |
| **Total** | | | **about 15.7 requests/s** | |

### While he drives (session live, in the car, no page open)

`/keymsg` 2.5, `/api/kids` 2, `/api/tow-wait` 2, `/tv` 1.43, `/guest` 1, `/mydrive` 0.83, `/race` 0.5 (races only), `/health` 0.33,
`/showcase` 0.33, `/perf/live` 0.25, `/overlays` 0.17, `/version` 0.07 = **about 11.4 requests/s**, plus the stream at **30 frames/s**
carrying about 85 variables including 13 per-car arrays of 64 values (`core.js VARS`), JSON-parsed in the page each frame. The whole
session YAML is re-sent and re-parsed (main thread, own YAML parser) every time iRacing bumps the session version.

### With a page open over HOME

HOME's own pollers keep running underneath (the page is not hidden, and `home.js shown()` stays true behind the iframe). Add:

| Page | Its own requests |
|---|---|
| Sessions | list every 20 s, `/version` every 15 s (+0.12/s) |
| Vault | list every 15 s, `/version` every 15 s (+0.13/s) |
| Performance | `/perf` 8 s, `/perf/checklist` 20 s (+0.18/s) |
| My Races | list every 10 s (+0.1/s) |
| Coach (REVIEW) | loads only |
| After-session Coach (`debrief-v4.js`) | `/debrief/active` 5 s + `/debrief/nav` 1.2 s (+1.0/s) |
| **Analysis (`workbench.html`), from any of the above** | **`/workbench/cmd` every 300 ms (+3.3/s)**, no hidden or driving guard; `/share/jump` every 5 s |

So with Analysis open: **about 19-20 requests/s.**

### Server side (makes each request dearer)

- `Send()` writes `Connection: close` and `Cache-Control: no-store` on **every** reply, including static `.js` and `.css`: one TCP
  connection and one new thread (`new Thread(... Handle(c))`) per request. Opening Analysis re-downloads and re-parses about 330 KB
  of script every time.
- `/version` walks every file under `dash\www` (`Directory.GetFiles(..., AllDirectories)`) on each call. The main page, Sessions and
  Vault each call it every 15 s.

Fix (one line each): one `state` reply or `event: state` on the existing stream carrying kids, tow-wait, keymsg, tv, nav seqs, guest,
mydrive, doctor, overlays, recorder and health, pushed when something changes; cache static files with a version query; keep-alive.

## Findings by file

### `index.html` (the HOME + in-car document)
- **breaks Peter** - Offline message never shows: `#ovTitle` ("Paddock program not running") sits in `.idle-foot`, which has `hidden`
  and is also `display:none !important` in `home.css`. Fix: one visible banner owned by the shell.
- **wrong** - Loads 13 stylesheets and 26 scripts (332 KB JS + 95 KB CSS), about 134 KB of it dormant (list above). Fix: delete the dead ones.
- **fragile** - Every script is a classic script with top-level `const` (`const DASH`, `const Home` ...). They share one global scope:
  a new file that declares an existing name throws and that whole file stops. Fix: ES modules.
- **cleanup** - Inline `style="top:476px"` dividers; HOME is laid out by absolute pixel positions for exactly 1920x1080.

### `core.js` (data model + connection)
- **fragile** - The stream asks for 30 Hz and about 85 variables whatever is on screen (HOME, the grid, Drive). Fix: ask only for what
  the visible layout needs; 10-15 Hz is plenty for a glance screen.
- **wrong** - `setSession()` parses the full YAML on the main thread at each session-version change; with 60 cars it is large. Fix: let
  irdash send the parsed fields the page needs.
- **cleanup** - Holds the shared helpers (`$`, `esc`, `fmtLap`, `fmtDelta`, `fmtDur`, `setText`, `store`, `Units`), but Sessions and
  Performance load all 25 KB (YAML parser, live model) to use 6-8 of them, and Vault, Coach, Races, Raw data and Analysis copy them instead.
- Good: the `/version` reload waits while he is on track and only counts a fresh frame.

### `ui.js` (the live in-car grid)
- **breaks Peter** - This is the live in-car layout. Smallest text: car-panel labels 10 px (`.kv label`), table headers and sector labels
  11 px, badges and iRating 12-13 px, standings rows 19 px. Unreadable from the seat. Fix: retire it for one large-type layout.
- **wrong** - `TowWait` and `KidsMode` each poll every 500 ms (4 requests/s together) for two banners that change a few times a day.
- **wrong** - The loop calls `Tv.poll()` every 700 ms with TV VIEW off.
- **cleanup** - `health()` and `home.js next()` both fetch `/health` on their own timers.

### `drive.js` (the calm in-car layout)
- **wrong** - Not live (see above), yet ticked 10 times a second. Has its own lap formatter and its own map renderer.
- Good: no network on its render path; big type (smallest 20 px).

### `pagehost.js`, `nav.js`, `vaultlive.js` (pages over HOME)
- **wrong** - `poll()` fetches `/nav` twice per round (sessions and coach share it), then `/vault/nav` and `/perf/nav`, one after another;
  `vaultlive.js` fetches `/vault/nav` again on its own 1.5 s timer just for an on/off flag. Fix: one nav state, one request.
- **fragile** - Esc is caught on the HOME document only. Once the focus is inside the iframe (after any click), Esc goes to the page.
  Sessions, Vault, Perf, Races and Coach post a close message on Esc; Analysis (`workbench.js`) uses Esc for "zoom reset" and never
  closes, so inside a nested Analysis Esc does not get him out.
- **cleanup** - `nav.js` is a 15-line shim "so old names work". `vaultlive.js` injects a VAULT link into HOME's top bar at run time.
- Good: one page at a time, follows irdash only on a new request, closes the page when he gets in the car, big CLOSE (56 px).

### `home.js`
- **breaks Peter** (from 01, confirmed in code) - `drawLast()` shows "No timed lap" from `/home`'s `lastOuting`; the phone line can show a
  developer instruction; about 14 separate things for one job.
- **fragile** - `go()`: on the plain RIG ON / START path it ignores a failed `send()` (returns false, `go` just returns). Peter sees
  "Starting" for 25 s and nothing happens. Fix: say "Could not reach Paddock" when the send fails.
- **wrong** - `tick()` rebuilds every band with `innerHTML` every 60 s and re-attaches the REVIEW listener each time (harmless today
  because the element is new; it leaks the day someone switches that band to `setHTML`).
- **cleanup** - Own lap formatter (`lap()`), own clock (which `idle.js` also calls every second), `/career` fetched again by `idle.js`.

### `debrief-v4.js` (after the session)
- **wrong** - 29 KB + 7 KB CSS, but its own race screen is only a fallback now (`showCoach()` opens Coach whenever there is a telemetry
  file). Polls `/debrief/active` every 5 s and `/debrief/nav` every 1.2 s while up.
- **cleanup** - Own iframe host (Coach) and own nested Analysis host; own copies of `fmt`, `esc`, `isN`.

### `sessionreview.js` / `.html`
- **breaks Peter** (from 01) - "No complete lap: ALL THE DATA below" beside a 10-lap table, with nothing below.
- **cleanup** - 38 KB; also loaded into HOME for the dead demo; own SVG map; own iframe host for Analysis. Overlaps Coach and Analysis SPLITS.

### `coach.js` / `.html`
- **wrong** (from 01) - Four routes into the data (ALL LAPS, ALL THE DATA, SHOW ME IN THE DATA, SHOW ALL THE DATA), each opening a
  different page in its own nested host.
- Good: smallest text 20 px; its CSS is the closest to a "seat" style.

### `sessions.js` / `.html`, `bench.js`
- **fragile** - Opens Analysis in its own nested host with a "Back to Sessions" button top-left (16 px text) while PageHost's CLOSE sits
  top-right: two exits that mean different things.
- **wrong** - Switches its own iframe to `perf.html` / `vault.html` (`location.href`), so PageHost still believes "sessions" is open.
- **cleanup** - Loads `map.js` and `corners.js` for nothing; own `/version` reload; `typeTxt()` copied in `vault.js`.
- Smallest text: 10 px (lap tags), 11 px (PB mark, flags), 12 px table headers; `bench.css` 11-12 px.

### `vault.js` / `.html` (77 KB)
- **wrong** - Two programs in one file. Lines 1-385: the library grid with four ways to filter (tabs, two dropdowns, a search box that
  needs typing) and an S/M/L size switch. Lines 387-1150 (about 770 lines, about 50 KB): a detail view with its own trace plot, map,
  corner table, video player and a two-video lock-step compare, repeating Analysis DRIVER and `workbench-video.js`, while also offering
  "open in Analysis" (`openWorkbench`). Fix: the card opens Analysis; delete the detail view, the search box and the size switch.
- **cleanup** - Copies `$`, `setHTML`, `setText`, `fmtLap`, `fmtDelta`, `fmtDur`, `isNum`, `clamp` (does not load `core.js`); two own
  iframe hosts; own `/version` reload.

### `workbench.js` + 6 companions (Analysis, about 330 KB with CSS)
What `workbench.js` (135 KB, 1521 long lines) holds, by section: helpers (line 51), data loading (64-183), shared state (184-251),
the display engine - TRACE STACK, MAP, READOUTS, EVENTS, PEDALS, G-G, CORNER TABLE, TIME IN GEAR (252-585), the C-41 pages BRAKING,
TYRES & STINT, SUSPENSION, SPLITS (586-956), the channel picker (957-1097), page presets (1098-1254), the frame loop (1255-1274),
commands for keyboard / deck / tests (1275-1400), the deck poll `pollDeck` (1404) and empty states. Companions: `workbench-pro.js`
49 KB (histogram, X/Y scatter with curve fit and R², a maths-channel formula box, Excel/CSV export), `workbench-career.js` 34 KB,
`workbench-race.js` 30 KB, `workbench-video.js` 24 KB, `workbench-channels.js` 18 KB (channel catalogue), `workbench-share.js` 5 KB.
- **wrong** - `pollDeck()` fetches `/workbench/cmd` every **300 ms** with no `document.hidden` and no driving guard, also when Analysis
  is nested 3-4 iframes deep: 3.3 requests/s on its own.
- **fragile** - Tabs and most controls are `<span>`s with `cursor:pointer` (15 pointer rules, 2 real buttons): not focusable, 14 px text,
  chips about 20 px tall. Smallest text 11 px.
- **could go** - PRO (49 KB: an R² of 0.18, a formula box that needs typing), CAREER charts built from 4 points (34 KB), the TYRES page
  against Peter's "tyre panel out" decision (keep the data, hide the page), the deck remote (`pollDeck` + `/workbench/state`) if Analysis
  is simplified, the second "SHOW ALL THE DATA" button. Keeping DRIVER, RACE and BRAKING keeps what 01 calls the strongest views.
- Mixed dialect: the workbench files are ES5 IIFEs with `var`; everything else is ES2017 globals.

### `rawdata.js` / `.html` (ALL THE DATA)
- **wrong** - A third trace engine (time axis) and another map renderer; repeats Analysis DRIVER in a simpler form. Lap labels overlap (01).
- Good: works for drives with no full lap. Smallest text 16 px.

### `perf.js` / `.html`, `perflive.js`
- **cleanup** - Loads `core.js` + `map.js` (+ `corners.js`) for helpers and corner names. An 800 ms timer re-checks corner names forever
  while the page is open. Posts both `perf-close` and `sessions-close`. Smallest text 11 px.
- Good: `perflive.js` only asks `/perf/live` while driving, every 4 s.

### `races.js` / `.html` (MY RACES)
- Closest to the target already: big buttons, plain words, one job. Smallest text 13 px (meta line). Own lap formatter, own `kind()`
  session naming. Polls every 10 s, paused while busy.

### `guest.js`, `mydrive.js`, `rig.js`, `intro.js`, `keymsg.js`, `flaglow.js`, `brief.js`, `race.js`
- **wrong** - `guest.js` polls `/guest` every second forever (friends mode is rare), `mydrive.js` every 1.2 s, `keymsg.js` every 400 ms,
  `intro.js` every 3 s. Each is reasonable alone; together they are most of the 16/s. Fix: the one `state` push.
- `guest.js` has its own map renderer (`mapFit`, `drawMap`).
- Good: `rig.js` stops `/doctor` while driving; `flaglow.js` and `brief.js` use frames already in the page.

### `map.js`, `corners.js`, `carpics.js`
- **fragile** - `map.js` loads `corners.js` itself by injecting a script tag, so any page that includes `map.js` silently gets 11 KB more.
- Good: `map.js` draws the outline once into an offscreen layer and only the cars each frame. This is the renderer to keep.

### `theme.css`
- Its comment calls it "the single place" for tokens, but only `perf.html` and `vault.html` load it, and both redefine `:root` anyway.

## Duplication count

| Thing | Copies | Where |
|---|---|---|
| Lap-time formatter | 12 | `core.js fmtLap`, `bench.js`, `coach.js`, `debrief-v4.js`, `drive.js`, `home.js`, `races.js`, `sessionreview.js`, `vault.js`, `workbench.js`, plus `mm:ss` copies in `rawdata.js`, `tv.js`, `coach.js`. Four different "no value" marks: `–`, `—`, `–:––.–––`, empty. |
| `esc()` | 11 | carpics, coach, core, debrief-v4, races, rawdata, sessionreview, vault, workbench-career, workbench-pro, workbench-race (+ `official.js`) |
| `clamp()` | 7 | core, vault, workbench, -career, -pro, -race, -video |
| `$()` | 5 | coach, core, races, rawdata, vault |
| Track map renderer | 9 | `map.js TrackMap`, `drive.js drawMap`, `guest.js drawMap`, `brief.js drawMap`, `rawdata.js drawMap`, `sessionreview.js mapSvg` (SVG), `tv.js drawFieldMap` (+3D), `vault.js drawMap`, `workbench.js MapView` |
| Lap trace (speed/pedals vs distance or time) | 3 | `workbench.js` TRACE STACK, `vault.js drawPlot`, `rawdata.js` |
| Other hand-written chart engines | 7 | `ui.js trace` (live inputs), `perf.js` fps chart, `bench.js` tick bars, `workbench-career.js`, `workbench-pro.js`, `workbench-race.js`, `sessionreview.js` SVG |
| Corner tables / corner lists | 7 | Analysis GRIP corner table, Analysis SPLITS lap x corner, `vault.js renderCorners`, `coach.js` corner pills, `workbench-career.js` heat grid, `workbench-race.js` per-corner vs car ahead, `debrief-v4.js` three costliest corners |
| Session naming ("Test drive", "Qualifying", "Short run") | 4 | `sessions.js typeTxt`, `vault.js typeTxt`, `races.js kind`, `core.js sessionType/isRace` (+ `home.js watchKind` for real-world sessions) |
| Full-screen iframe host + close/back | 9 | `pagehost.js`, `home.js HomeHost`, `debrief-v4.js` (2), `sessionreview.js`, `sessions.js`, `vault.js` (2), `coach.js` |
| `/version` auto-reload | 3 | `core.js`, `sessions.js`, `vault.js` |

## Robustness

- **irdash down**: every poller catches and returns quietly and the stream sets `Conn.status = 'noserver'`, but the only words for it are
  hidden (see `index.html`). The page keeps the last HOME; buttons fire fetches that fail silently. **breaks Peter.**
- **Empty data**: HOME handles no last session ("No drive recorded yet"). Session Review contradicts itself with no full lap (01).
  Analysis only offers tabs whose data exists (`avail()`), which is good. TYRES charts were seen empty in 01.
- **Session with no laps**: Coach and Analysis fall back to ALL THE DATA (good). `drive.js` fuel stays blank "after one clean lap".
- **Memory over days** (the kiosk runs for days): no leak found. Every `setInterval` is made once at start; iframe hosts are removed on close;
  `L.trace`, `perf.last` and the fps ring are capped. Never-stopping costs: the `ui.js` requestAnimationFrame loop at screen rate even on
  HOME, `Drive.tick` 10/s, `vaultlive.linkDebrief` 1.4/s, `FlagGlow` 5/s. Each is cheap.
- **Driving guards**: `PageHost`, `HomeHost`, the Session Review host, `Brief`, `Rig`, the `MyDrive` overlay, `perflive` and the `/version`
  reload all check "on track". Not guarded: the 2 Hz kids and tow pollers, `/keymsg`, `/tv`, `/guest`, `/mydrive`, Analysis's 300 ms
  deck poll (its host is closed when he drives, so in practice it stops) and the stream itself.

## CSS inventory

**Fonts.** One family really: Bahnschrift with Segoe UI fallbacks, written 6 ways (`Bahnschrift, "Segoe UI Variable Display", "Segoe UI", sans-serif`
16 times; `Bahnschrift, "Segoe UI", sans-serif`; `"Bahnschrift", "DIN Alternate", ...`; `var(--font)`; `var(--cond)` = Bahnschrift SemiCondensed;
plus canvas strings in JS `FONT` / `MAP_FONT`). Keep Bahnschrift; define it once.

**Font sizes in CSS (px: number of rules).** 51 different sizes:
10:2, 11:14, 12:28, 13:31, **14:70**, 15:54, 16:25, 17:20, 18:41, 19:11, **20:61**, 21:5, **22:53**, 23:2, 24:14, 25:1, 26:32, 27:1, 28:10, 29:3,
30:17, 32:2, 34:7, 36:8, 38:4, 40:8, 42:2, 44:6, 46:2, 48:3, 52:4, 54:1, 56:8, 58:2, 60:3, 62:1, 64:6, 72:1, 74:1, 86:1, 92:2, 96:1,
104:2, 112:1, 128:1, 130:1, 150:1, 170:2, 190:1, 300:1, 860:1 (dead).
Plus `var(--glance|--read|--body|--label|--tiny)` from `home.css` (32 uses). About 175 rules (a quarter) are 14 px or smaller.
Canvas text set from JS: 12-28 px, mostly 15 px.

**Colours.** 203 different hex values in v2 (138 in CSS alone). Most used: gold `#f2c230` (66), ink `#f4f1ea` (34), `#000` (29),
muted `#8d8a82` (26), surface `#060606` (26). Same meaning, different values:
- gain / good green: `#2fe07a`, `#3ccf7e`, `#1fbf5f`, `#4fe08c`, `#52b36a`
- loss / bad red: `#ff5a4d`, `#e5534b`, `#ff3d3d`, `#ff6b6b`, `#ff4d4d`, `#d81f1f`
- purple (fastest): `#c46cff`, `#b46cff`, `#a77bff`
- amber: `#ffb21e`, `#e0a23a`, `#ff9f43`
- ink: `#f4f1ea`, `#ece8df`, `#f3f6f9`, `#d8d4ca`
- background: `#060606`, `#030405`, `#0b0b0c`, `#020202`, `#040404`, `#09090a`, `#101010`, `#111` and about 30 more near-blacks
- cyan accent `#29d3f5` (live grid, Sessions compare) against gold everywhere else.

**Files with their own `:root`**: `style.css`, `theme.css`, `coach.css`, `perf.css`, `races.css`, `rawdata.css`, `sessions.css`, `vault.css`,
`workbench.css`. Token blocks scoped elsewhere: `home.css` (`--h-*` copies), `drive.css`, `intro.css`, `debrief-v4.css`, `sessionreview.css`.
Inline styles written from JS: `workbench.js` 31 places, `vault.js` 14, `ui.js` 13, `workbench-race.js` 12, `workbench-career.js` 12;
`pagehost.js` injects its own stylesheet as a string.

**How many design systems: four.**
1. **Cool telemetry** (`style.css`): blue-grey blacks `#030405`, cyan accent, white text, 10-19 px. The live in-car grid.
2. **Paddock gold** (`theme.css`, `coach.css`, `races.css`, `rawdata.css`, `perf.css`, `sessions.css`, `vault.css`, `home.css`, `drive.css`,
   `intro.css`): `#060606` / `#f4f1ea` / `#f2c230`, the same 6 values retyped in 10 files, each slightly different (`vault.css` has its own muted `#a29e94`).
3. **Workbench grey** (`workbench.css`, `sessionreview.css`, `debrief-v4.css`): `#0b0b0c` / `#ece8df`, gain `#3ccf7e`, loss `#e5534b`.
4. **Identity bands** (`theme.css --id-vault-*`, `--id-perf-*`): a navy band for Performance, a gold band for Vault, different on purpose (P0-06).

Only `home.css` has a type scale (56 / 30 / 26 / 20 / 16).

## Readability: smallest text in regular use, per page

| Page | Smallest regular text | Where |
|---|---|---|
| In-car grid (`ui.js` / `style.css`), **live** | 10 px | car-panel labels; 11 px headers and sector labels; 12-13 px badges, iRating |
| In-car Drive (`drive.css`) | 20 px | labels |
| HOME (`home.css`) | 16 px (`--tiny`), mostly 20 px | the top links are 15 px (`style.css .idle-top`) |
| Sessions | 10-11 px | lap tags, PB mark, flags; benchmark 11-12 px |
| Performance | 11-12 px | labels, chip counts |
| Vault | 14 px | |
| Analysis | 11-12 px | event tags, split marks, picker counts |
| Coach | 20 px | |
| ALL THE DATA | 16 px | |
| MY RACES | 13 px | meta line |
| Session Review | 14 px | (SVG text 14 px) |
| After-session (`debrief-v4`) | 14 px | |

The top screen is 1920x1080 at about 1 m: 20 px should be the floor for anything read from the seat, 16 px for lean-in pages.

## Accessibility for a mouse and Stream Deck user

- **Targets**: good on HOME (RIG ON), MY RACES, Coach and the PageHost CLOSE (56 x 168 px). Small on Analysis (tabs about 37 px tall with
  14 px text, chips about 20 px), Sessions buttons (about 31 px), Vault S/M/L and dropdowns, the nested "Back to ..." links.
- **Not real buttons**: Analysis tabs and most of its controls, HOME's top links (`span role=button`), the injected VAULT link. They work
  with a mouse, not with Tab.
- **Hover-only**: Vault, Sessions and Perf tooltips (`#tip`) show values only under the pointer; the rig-health dots and the SoF line keep
  their meaning in `title=` tooltips; Analysis cursor readouts follow the mouse (the deck can also move the cursor).
- **Typing**: Vault search box, Analysis PRO formula box. Peter should never have to type.
- **Keyboard traps**: Esc in a nested Analysis does not close it (see `pagehost.js`). Two exits in one view (Back top-left, CLOSE top-right).
- **Wheel**: Analysis and ALL THE DATA zoom with the mouse wheel; zoom-out is only WHOLE DRIVE or the deck.

## Proposed structure for the rewrite

One document, no nested iframes, four kinds of file:

```
dash\www\app\
  index.html        the shell: one header (title, clock, one CLOSE/BACK), one <main>, one banner line
                    (offline, kids, tow, key message)
  design.css        the only :root: about 16 colour tokens (bg, panel, line, ink, muted, dim, gold, gain, loss, purple, amber, cyan),
                    one type scale (glance 56 / read 30 / body 24 / label 20 / small 16; seat pages nothing under 20),
                    one button (at least 64 px tall), one header, one table, one empty state
  lib\data.js       ONE connection: the telemetry stream (only while a live layout is on screen, 15 Hz, only its variables)
                    + one "state" push from irdash (kids, tow, keymsg, tv, nav, guest, mydrive, doctor, overlays, recorder,
                    health, driving) + cached JSON helpers for the analysis endpoints. Exposes rig.driving and rig.online.
  lib\format.js     lap, delta, duration, date (New York), session name, one "no value" mark
  lib\map.js        the one track renderer (today's map.js layer approach): outline, corners, cars, coloured line
  lib\chart.js      the one trace engine (distance or time axis, cursor, zoom) for Analysis, All the data and Review
  pages\home.js  pages\drive.js  pages\races.js  pages\review.js  pages\analysis\*.js  pages\perf.js  pages\library.js
                    each exports mount(el, params) and unmount(); timers only through ctx.every(), so unmount clears them
```

Rules: the router owns "one page at a time", the CLOSE button, Esc and the driving guard (on track only `drive` may be mounted; the router
unmounts the rest). Pages never poll; they subscribe to `data.js`. ES modules (`<script type="module">`), so no shared global names.
Server side: static files cacheable (`?v=<version>`), keep-alive, and `/version` kept in memory instead of walking the folder each call.

## Migration order

1. **Delete the dead (low risk, tests first)**: v1 root files and the README line, `preview.png`, `official.*`, `idle.js`, `cars.js` (move or
   drop its dormant drawing test), `debrief.js` / `sessionreview.*` / `sr-demo.json` from HOME, the dead `style.css` idle rules, `map.js` from
   Sessions, `vaultlive.linkDebrief`. Update `tests\official-test.ps1`, `race-field-test.ps1`, `session-review-test.ps1`, `bench-test.ps1`.
2. **Cut the requests**: add the `state` push in irdash and move the 14 pollers onto it; stop `/tv` unless TV is on; one `/nav`; guard
   `pollDeck` (hidden + driving, 1 s). Add a headless test that counts requests per second on idle HOME and asserts a ceiling (target: under 2/s).
   Do this before any visual work: it is the part that runs during races.
3. **Make the offline banner visible**, and make RIG ON say so when Paddock cannot be reached.
4. **Pick one in-car layout** (`drive.js` is the readable one) and make it the default; retire the `ui.js` grid; trim `VARS` and the stream rate.
5. **`design.css` + `lib\format.js`**, then convert pages one at a time: MY RACES first (smallest, closest to target), then HOME, then Coach.
6. **Shell + router**: replace PageHost, HomeHost, the Debrief4 host and the nested hosts in Sessions, Vault, Coach and Session Review.
7. **Analysis**: one chart engine and one map; Vault's detail view goes (cards open Analysis); ALL THE DATA becomes Analysis's time mode;
   Session Review folds into Review; split `workbench.js` into page modules; PRO, CAREER, TYRES and SUSPENSION behind one "More data" step, or out.
8. **Phone app** (`dash\www\phone`) last, on the same `data.js` and `design.css`.
