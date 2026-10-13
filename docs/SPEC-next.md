# Rig: next level — spec for implementers

Written 2026-10-09 by the lead (Opus) for Sonnet/Haiku implementers. Read all of section 1 and 2 before touching anything.
Owner: Peter. He is disabled: every feature must be one press (Stream Deck) or automatic. He loves the friends mode
(live Stream Deck screens, typing on the deck, gold = chosen) and wants the same feel everywhere.

---

## 1. What exists (architecture)

| Part | Where | What |
|---|---|---|
| **irdeck** | `src\irdeck.cs` + `src\guest.cs` + `src\testdrive.cs` (one `static partial class Program`) | Command tool. Builds to `irdeck.exe` (winexe, copied over every `keys\*.exe`) and `irdeck-cli.exe` (`-define:CLI`). Stream Deck keys are copies named after the key; `keys\keys.map` maps name → command. |
| **irdash** | `dash\src\irdash.cs` + `dash\www\v2\*` | Tray app, local web server `http://localhost:8199`, reads the iRacing SDK, serves the top-screen dashboard (Chrome kiosk), watchdog, career stats, friends mode endpoints. Page reloads itself when `/version` changes (any www file or the exe). |
| **Rig Intro add-on** | `deck-intro\plugin.html`, `deck-intro\install.ps1` | Our Stream Deck plugin (HTML, SDK 2). Bundled profiles `RigIntro` (startup flag animation) and `RigFriends` (live friends screen). Draws whole-deck screens on a 768×384 canvas sliced into 32 tiles; tiles carry `settings.p` = which profile. Presses → `GET /api/guest/do?c=..&a=..` on irdash, which runs irdeck (whitelisted). |
| **Deck profile** | `build-deck.ps1` | Builds the "iRacing GT3" MAIN page (32 keys). Stream Deck must be closed while it runs; restart with `Invoke-CimMethod Win32_Process Create '"C:\Program Files\Elgato\StreamDeck\StreamDeck.exe" --runinbk'`. |
| **Overlays** | irdashies 1.1.0, `%LOCALAPPDATA%\irdashies\app-1.1.0\irdashies.exe`, config `%APPDATA%\irdashies\config.json` | Electron overlay app. Widgets in `dashboards.default.widgets[]` with `id`, `enabled`, `layout{x,y,width,height}` in **desktop coordinates**. Our hotkeys moved to Ctrl+Alt+Shift+E/T/O. |
| **CrewChief** | 4.19.5.2, settings `%LOCALAPPDATA%\Britton_IT_Ltd\...\user.config` | Spotter/engineer voice. `PERSONALISATION_NAME` = name it says (needs a restart). |
| **Tests** | `tests\friends-test.ps1` (19 checks, pictures to `tests\shots`), `fps-report.ps1` (frame-rate report from newest .ibt) | Pattern to copy for every new feature. |
| **Settings helpers** | `gfx-set.ps1` (iRacing graphics, backs up, refuses while sim runs), `guest\guest.ini` | |

Screens (by POSITION, never by `\\.\DISPLAYn`): race screens 2560×1440 @165 Hz at x −2560 / 0 / 2560, y 0 (middle is
primary); dashboard monitor 1920×1080 at 320,−1080. Race screens are rotated 180° in Windows (physically upside down).

Useful endpoints (irdash): `/health`, `/stream` (SSE telemetry), `/career`, `/systems`, `/guest`, `/api/guest/do`,
`/api/guest/draft`, `/api/guest/lap`, `/showcase`, `/api/showcase`, `/trackmap`.
Useful irdeck commands: `state`, `go`, `getout`, `tow`, `quitmain`, `tdsetup "<car>" "<track>" ["<layout>"] [--damage-off] [--launch]`,
`tdfind car|track "<text>"`, `guest ...`, `overlays`, `key --sim <combo>`, `ffb`, `simclick <name> --dry`.

### Build commands (copy exactly)
```powershell
# irdeck (both exes) then update every key copy that matched the old exe
$r='C:\Users\peter\iRacingDeck'; $fw="$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"; $wpf="$fw\WPF"; $out=Join-Path $env:TEMP 'ird'
$refs=@('-r:System.dll','-r:System.Core.dll','-r:System.Drawing.dll','-r:System.Windows.Forms.dll','-r:System.Web.Extensions.dll',"-r:$wpf\UIAutomationClient.dll","-r:$wpf\UIAutomationTypes.dll","-r:$wpf\WindowsBase.dll")
$src=@("$r\src\irdeck.cs","$r\src\guest.cs","$r\src\testdrive.cs","$r\src\overlays.cs","$r\src\mydrive.cs","$r\src\actions.cs")   # add new src files here (and in build-irdeck.ps1, which is this block as a script)
& "$fw\csc.exe" -nologo -optimize+ -target:winexe "-out:$out\irdeck.exe" @refs @src
& "$fw\csc.exe" -nologo -optimize+ -target:exe -define:CLI "-out:$out\irdeck-cli.exe" @refs @src
# deploy: copy both to $r, and copy irdeck.exe over every keys\*.exe whose hash equals the OLD irdeck.exe
# irdash: dash\build.ps1  (compiles dash\src\irdash.cs + deltabar.cs + overlays.cs + doctor.cs, and probe.cs separately; refs include System.Management.dll and System.Web.Extensions.dll;
#         stops and restarts irdash only after a good build; -NoDeploy just compiles)
# add-on: bump $ver in deck-intro\install.ps1, run it; Stream Deck shows "install Rig Intro?" -> PETER must click Install
```
C# 5 only (Windows' csc): no `$"..."`, no `?.`, no `nameof`, no expression-bodied members, no `out var`.
JSON without libraries is fine (we build JSON by hand with `Json_.S()` in irdash); `System.Web.Extensions`
(`JavaScriptSerializer`) is available if you need to parse JSON in C#.

---

## 2. Ground rules (non-negotiable)

1. **Never click, type or send keys while Peter is driving.** Check `irdeck-cli state` (`onTrack=True` = driving) before
   anything that moves the mouse, focuses windows, restarts apps or rebuilds. irdash/irdeck code must do the same check.
2. **Never write iRacing's own files** (`Documents\iRacing\*.ini`, `controls.cfg`, install folder) without Peter's yes in
   chat. Only `gfx-set.ps1` touches the renderer ini, only with the sim closed, always with a backup.
3. **Claude AppData redirect:** this session is inside a packaged app. Processes you start create NEW `%APPDATA%` /
   `%LOCALAPPDATA%` folders inside `...\Packages\Claude_pzs8sxrjxfjjc\LocalCache` where nothing else can see them.
   Start installers and GUI apps with `Start-Process explorer.exe -ArgumentList '"<path>"'` (use a `.cmd` for args).
   To test what the real apps see, go through irdash's HTTP API (irdash runs outside the package) — e.g. press keys via
   `/api/guest/do`, not by running irdeck from your shell, when the command writes AppData.
4. **iRacing UI automation:** before every click, confirm the expected dialog/panel is on screen (see `DialogOpen` /
   `EnsurePanel` in `testdrive.cs`). A blind click once opened iRacing news and a Steam sign-in window. Never type into
   anything that is not the field you verified. Lists are virtual: only click rows that are on screen.
5. **No popups mid-session.** Nothing may steal focus from the sim. New windows: `ShowWithoutActivation`, `WS_EX_NOACTIVATE`.
6. **Downloads / installs need Peter's yes** (say file, source, size). Never enter credentials.
7. **Stream Deck add-on updates need Peter's Install click** — batch add-on changes, bump `$ver` once per batch.
8. Every feature gets a test in `tests\` (PowerShell, prints `ok`/`FAIL`, saves screenshots) and is run before you report.
9. Match the existing code style: short comments that say *why*, plain names, no frameworks.
10. Log what you do in `irdeck.log` / `irdash.log` style; user-facing text is plain English, no jargon.

---

## 3. Workstreams

Priority: **A** = now, **B** = next, **C** = later/needs Peter. Model: **S** = Sonnet, **H** = Haiku is fine.

### WS1 — Overlays you can tune in seconds (A, S)
Goal: "the perfect setup" — add/remove/move overlays from the Stream Deck, presets per situation, a proper delta bar.

**O1 OVERLAYS screen on the deck** (copy the friends screen pattern; new plugin action `com.peter.rigintro.overlays`,
new bundled profile `RigOverlays` with tiles `p='overlays'`, MAIN key replaces `OVERLAYS ON/OFF` at (4,1)).
- Row 1–2: one tile per irdashies widget Peter would use (relative, standings, blindspotmonitor, deltaspeed, sectordelta,
  flag, fuel, input, map/flatmap, pitlanehelper, cornername, laptimelog, weather, battle, slowcarahead). Gold = on.
  Labels in plain words ("RELATIVE", "BLIND SPOT", "DELTA", "INPUTS"...).
- Row 3: presets — RACE, PRACTICE, QUALI, MINIMAL, FRIENDS — and SAVE AS (saves current set+positions into the
  selected preset). Presets live in `overlays\presets\<name>.json` (copies of the widgets array).
- Row 4: EDIT LAYOUT (irdashies drag mode — find its real hotkey/IPC; verify), ALL OFF, DELTA BAR options (see O2),
  EXIT.
- Backend: `irdeck ovl list|set <id> on|off|preset <name>|save <name>`; edits config.json with a backup in
  `backup\irdashies\`; then reloads irdashies. **Test first whether irdashies live-reloads config.json**; if not, restart
  it (kill + start via the logon-launcher path, then `FocusWindow(SimWindow())` if a session runs). Measure and log
  the restart time; target < 3 s visible gap.
- irdash `/overlays` JSON for the plugin and the top screen; whitelist new commands in `Guest.Do`-style dispatcher
  (generalise it to `/api/do`, keep the whitelist).
- Acceptance: test toggles 3 widgets via the API and reads the real config back; preset round-trip; works while a
  session is running without focus loss (verify with foreground-window check).

**O2 Native delta bar in irdash** (zero-cost overlay, no Electron).
- A WinForms layered, click-through, no-activate, topmost window on the **middle race screen, top centre** (just under
  the iRacing session bar), drawn with GDI+ at 30 Hz from irdash's own SDK frames.
- Shows: big signed delta (−0.214 green / +0.180 red), a horizontal bar (±1.0 s full scale), predicted lap time, and a
  small "vs BEST / vs OPTIMAL / vs SESSION" label. Sources: `LapDeltaToBestLap(_OK)`, `LapDeltaToOptimalLap(_OK)`,
  `LapDeltaToSessionBestLap(_OK)`, `LapCurrentLapTime`.
- Only visible while `IsOnTrack`; fades out in the pits. Must stay above the sim (sim is topmost while driving — reuse
  `RaiseOverlays` timing) and must never take focus.
- Settings in `irdash.ini`: `delta_bar=1`, `delta_ref=best|optimal|session`, `delta_pos=x,y` (relative to the middle
  screen), `delta_scale=1.0`. Deck O1 row 4: DELTA ON/OFF, VS BEST/OPTIMAL/SESSION (cycles), MOVE ↑ ↓ (nudges 10 px,
  saved).
- Acceptance: fps-report on one of Peter's runs shows no measurable change with the bar on vs off (≤1 fps); window
  never in the foreground (`GetForegroundWindow` check every second while driving logged).

**O3 iRacing's own UI widgets** (research, B). The new in-sim "Edit UI" lets iRacing draw its own widgets inside the sim
(zero extra windows). Document which exist (delta? relative? standings?) — only while Peter is out of the car, read-only
screenshots — and propose which irdashies widgets they could replace. Don't change iRacing settings.

**O4 Overlay cost** (B, needs Peter's laps). With fps-report, compare a run with irdashies on vs off; write the result
into `docs\overlays.md` with a recommendation (which widgets are worth their frames).

### WS2 — Cosworth Pi Toolbox (C, S) — after Peter installs Pi Toolbox Lite
Pi Toolbox Lite is free for iRacing members and opens `.ibt` natively (Plus, £5/month, adds real-time and ghost laps).
Peter downloads it from the Cosworth portal himself (needs his account).
- C1 Find the install and how to open a file (command line argument or `.ibt` association). Document in `docs\cosworth.md`.
- C2 **ANALYSE** key (MAIN page) and a tap target on the post-race debrief: opens the session that just ended in Pi
  Toolbox. Start it like a normal program (not from the Claude session — see rule 3). Not while driving.
- C3 **Best-lap library**: when a session contains a new personal best for that car+track, copy its `.ibt` to
  `Documents\iRacing\telemetry\best\<car>\<track>\` (keep the 3 best). ANALYSE BEST opens best + latest together if
  Toolbox supports two files.
- Acceptance: with a known .ibt, the key opens Toolbox on it; library copy test with fixture files.

### WS3 — "My Drive": friends-mode ease for Peter (B, S)
- Q1 **MY DRIVE** deck screen (plugin action `com.peter.rigintro.mydrive`, profile `RigMyDrive`):
  row 1 RECENT (last 7 distinct car+track pairs from `/career` — extend Career with per-file car/track already stored),
  row 2 FAVOURITES (`mydrive\favourites.ini`, ★ key while in a session saves the current combo),
  row 3 SESSION TYPE (TEST DRIVE / AI RACE [C]) + damage on/off + wheel (own),
  row 4 START (big) / SEARCH CAR / SEARCH TRACK / EXIT.
- Q2 **Search on the deck**: SEARCH CAR → A–Z keyboard (reuse friends keyboard) → `tdfind`-style lookup returns ≤7
  matches as JSON (new irdeck command writing to a file irdash serves, or an irdash endpoint calling irdeck) → tap one.
  Same for tracks, then layout list.
- Q3 Start = `tdsetup ... --launch`, then wait for the session and `go` (as `guest start` does). Log and show
  "START → in the car: 41 s" on the top screen.
- Q4 AI race with the chosen car/track (C): map the AI Single Player wizard exactly like `testdrive.cs` (verify each
  panel before clicking; Peter out of the car), then add AI RACE as a session type.
- Acceptance: test drives a combo from RECENT end to end (Peter out of the car), screenshots.

### WS4 — Data tool (irdash) (B, S unless marked H)
- D1 **Sessions page** `www/v2/sessions.html` (open from the idle screen and a deck key): every session from the career
  cache — date, car, track, type, laps, best lap, seat time; filters by car/track; a PB table (best per car+track).
  Extend Career to store per-file best lap (min completed `LapLastLapTime`) — bump the cache format with a migration.
- D2 **Lap analysis**: pick a session → lap list → compare best vs any lap: speed, throttle/brake, gear traces over lap
  distance; delta trace; corner list with time lost (reuse debrief corner segmentation). New endpoints
  `/ibt/laps?file=` and `/ibt/lap?file=&lap=` returning downsampled arrays (~1000 points). Canvas, no libraries.
- D3 **Race extras on the live dashboard**: strength of field and live iRating gain/loss estimate (standard community
  formula from session YAML iRatings), shown only in races. (H can do the formula + UI once D-endpoints exist.)
- D4 **Pre-session brief** on the top screen when a session loads and Peter is not yet in the car: track map, his PB
  here, last time driven, typical fuel per lap from history, weather. Fades when he gets in.
- D5 **Weekly progress** on the idle screen: hours, laps, PBs set this week (H).

### WS5 — Faster and smoother (A/B, S + Peter)
- S1 **Timing log** (A, H): record boot → UI ready, START → sim running → session loaded → in the car, and sim exit time,
  into `dash\timings.tsv`; show the last values in Rig Doctor and on the idle screen footer.
- S2 **Sim priority** (B): irdash sets `iRacingSim64DX11` to High priority when a session starts (ini switch
  `sim_priority=high|normal`, default high). Verify with fps-report on Peter's next run; keep only if it helps.
- S3 **OneDrive** (B): `Documents\iRacing` lives in OneDrive. Mark it always-local (`attrib +P` on the folder, recursive) so
  settings/telemetry are never online-only. Telemetry upload exclusion is Peter's decision — just recommend it.
- S4 **Peter's list** (doc only): NVIDIA shader cache Unlimited; Windows Defender exclusion for the iRacing folders is a
  security trade-off — explain, don't do.

### WS6 — Rig Doctor (A, S)
One key (and automatic at boot, results on the idle screen): checks and plain-English fixes for
overlays app visible to normal programs (helper launched via explorer — see rule 3), irdashies running, CrewChief
running + its name, Stream Deck + add-on version, irdash version, race screens 165 Hz + rotation + layout, iRacing
frame limit/Reflex/mirrors values (read-only), free disk space on the iRacing drive, telemetry logging on, last
timings (S1). Shows a green/amber/red list on the top screen; amber/red items say what to press or do.

**WS6 follow-up (found 2026-10-10 02:10):** a Windows launcher error dialog (class `#32770`, only an OK button, title =
`...\irdashies\app-1.1.0\irdashies.exe`, owned by explorer.exe) had been sitting on the MIDDLE screen since ~00:11, hidden
behind the sim. Starting apps through `explorer.exe` can leave such a dialog when the launch fails (for example while the
exe is being replaced). The Doctor should (a) look for visible `#32770` windows owned by explorer.exe whose title is a
path to one of our apps (irdashies, irdash, CrewChief, StreamDeck) and close them with WM_CLOSE (no focus change),
logging the title and the text it could read, and (b) find out why the launch failed (first guess: a start attempt while
the overlays app was updating/in use) so it doesn't repeat. Fix without telling Peter.

### WS7 — MAIN page refresh (C, after WS1/WS3; Peter approves the layout first)
Usage today: QUIT TO MAIN 54, VOL± 46, AI RACE 10, DRIVE 10, RESTART 10, SEAT ↑ 9, SLEEP 6.
Never pressed: RIG ON, TEST DRIVE LAST, OFFICIAL, SHOWCASE, TOW, SAVE/BACK RESET POINT, REPLAY, FAST REPAIR, TEAR-OFF,
CLEAR PIT, SEAT ↓. Proposal to put to Peter: MY DRIVE, OVERLAYS (O1), ANALYSE (C2), RIG DOCTOR, DELTA mode, SESSIONS (D1)
in place of the never-pressed navigation keys; keep pit keys (races need them even if unused today).

### WS8 — Official racing, filtered to what Peter owns (C, S) — Peter asked for this 2026-10-09
Goal: see and join official races without browsing the iRacing app.
- R1 **Map the iRacing app's Official pages** (UI Automation, read-only first; same safety rules as `testdrive.cs`:
  verify the page before every click, never type outside a verified field, Peter out of the car). Find: the series list
  (licence-eligible), each series' car(s), this week's track + layout, session times / next race start, and the
  Register / Join / Withdraw controls. Document the element names in `docs\iracing-ui-map.md`.
- R2 **Ownership filter**: owned cars = folders in `C:\Program Files (x86)\iRacing\cars`, owned tracks =
  `...\iRacing\tracks` (map folder names to display names — the UI and `tdfind` show display names; build and cache a
  name map, `official\owned.json`). Only show series where Peter owns at least one eligible car AND this week's track.
- R3 **Favourites**: Peter flags series as favourites on the deck (★). Stored in `official\favourites.ini`.
- R4 **Top screen**: on the idle screen a calm "Next races" panel — favourites first: series, car, track, starts in
  12 min / at 20:45, licence class colour, registered count if the UI shows it. Updates every few minutes (scrape only
  when Peter is not in a session; cache in `official\schedule.json`).
- R5 **Deck screen OFFICIAL** (plugin action + profile, friends look): rows = favourite series then the rest (owned only),
  each tile shows track + "in 12m"; tap selects; ★ toggles favourite; REGISTER (registers for the next session of the
  selected series); JOIN NEXT (registers, waits, and when the session opens launches the sim and gets in the car — the
  same chain as `guest start`, logging timings). WITHDRAW. EXIT.
- R6 Never register/withdraw without the key press; never pay or change anything account-related.
- R7 **Race weekend on the home (idle) screen** — Peter's favourite ask (2026-10-09). A calm schedule panel: TODAY,
  then SATURDAY and SUNDAY (Friday evening onwards the weekend is the default view), listing upcoming official races for
  series he can enter with cars/tracks he owns, favourites first: start time, series, car, track + layout, length,
  licence colour. Times come from what the iRacing app shows per series (next session time and its repeat pattern,
  e.g. "every 2 h at :15", or listed session times); times projected from a pattern are marked "est". Also show special
  events (endurance / special event series) when the app lists them. Refresh from the app at most every 30 min and
  only when Peter is not in a session; cache in `official\schedule.json` with when it was read, and say "as of 18:40"
  when it's older than an hour. A "next race" countdown for the top favourite sits in the idle header. Deck OFFICIAL
  screen (R5) uses the same data; JOIN NEXT works from any listed race.
- R8 **Public racing schedule - real races** (Peter 2026-10-10: "and public racing schedule - real races"). The home (idle)
  screen also shows the upcoming REAL-WORLD races from public calendars, next to the iRacing race weekend (R7). Series, in
  order: IMSA WeatherTech (GTP / LMP2 / GTD Pro classes), WEC, then F1, NASCAR, IndyCar, Formula E, GT World Challenge, and
  the Le Mans / Daytona / Sebring / Petit Le Mans events. Each line: session start in HIS local time (this PC's time zone),
  event / track, session type (race / qualifying), and "LIVE NOW" / "in 2 h 10 m". Weekend view like R7 (today, Saturday,
  Sunday); the next race of each favourite series first. Where the same iRacing series/track exists, a small marker "you own
  this track" (reuse the R2 owned filter) so he can drive the same race in the sim.
  - Source rules: official public calendars only, read politely and cached (refresh at most every 6 h, only when he is not
    in a session; no logins, no scraping loops, no copying of copyrighted articles): the series' own published
    calendars / iCal feeds, or free public APIs for F1 (Jolpica/Ergast-style). Check each source's terms in one line in
    `docs\official.md` and drop any source that forbids this use.
  - Show "as of HH:MM" when stale; never invent times (mark "TBC" when the series has not published a session time).
  - Store in `data\official\realworld.json`; favourites for real series in `official\favourites.ini` section `[real]`; the
    same data feeds the future deck screen. Premium, calm, small caps, same panel style as R7.
  - Test with fixtures plus one live fetch per source; pictures in `tests\shots`. Same network and priority rules as the
    rest (BelowNormal, one request at a time, throttled). Not started (needs R2 owned filter and the R7 panel first).
- Acceptance: owned-filter unit test from the folder lists; a screenshot of the idle "Next races" panel; a dry-run of
  REGISTER that stops at the verified Register control (no click) plus one real registration only when Peter asks.

### O5 — Delta to the all-time personal best (C, S) — Peter approved
- iRacing's `LapDeltaToBestLap` is only this session. Build a reference from Peter's best lap ever for the current
  car + track (+ layout): from the best `.ibt` (Career/D1 already know best laps per file), extract time vs
  `LapDistPct` (~2000 points, interpolated), cache in `dash\refs\<car>__<track>.json`.
- The delta bar (deltabar.cs) gets a 4th reference: **VS PB** (all-time) — delta = current lap time − reference time at
  the same LapDistPct, smoothed; predicted lap = PB + delta. Default reference becomes VS PB when one exists.
  The cycle key order: PB → BEST (session) → OPTIMAL → SESSION.
- Show "PB 1:24.312 · set 3 Oct" small under the bar on the first lap. When a new PB is set, the reference updates
  after the lap (no restart).
- Acceptance: unit test with a real .ibt (reference built, delta at the same lap = 0 ± 0.01 s), fps-report shows no cost.

### WS9 — Visual polish of the dashboard and data tool (C, S) — "more visually appealing but not cheesy"
Direction: one coherent premium look — the existing black/gold, Bahnschrift, broadcast timing-screen style of the
intro/idle/debrief screens applied consistently to the LIVE dashboard (v2 panels), sessions/analysis pages, Rig Doctor
and friends/My Drive cards. No gimmicks, no animations for their own sake, no emoji, no glow except the approved flag glow.
- P1 Audit every screen at 1920×1080 (screenshots), list inconsistencies (fonts, sizes, colours, spacing, panel
  borders, number alignment), then fix them via shared CSS variables/tokens in one file (`www\v2\theme.css`).
- P2 Live dashboard: hierarchy — the 3–4 numbers that matter while driving (position, gap ahead/behind, laps/time left,
  fuel to finish, delta) larger and calmer; secondary data smaller and dimmer; tabular numerals everywhere; consistent
  1 px hairlines; gold only for "yours / chosen / best".
- P3 Data pages (sessions, lap analysis): clean tables, aligned columns, charts with thin lines, hairline grids, gold for
  the best lap, muted grey for comparisons, labels in small caps; readable from the seat.
- Acceptance: before/after screenshots of every screen (`tests\shots\p-*.png`) for the lead to review with Peter; no
  data or behaviour changes; all tests still pass.

### WS13 — Benchmark: "how good am I?" (C, S) — Peter 2026-10-09: "some way to measure myself... has to be very clean"
For each car + track (+ layout) Peter drives, compare his all-time PB with three yardsticks, all labelled with where the
number comes from and how many drivers it's based on. No numbers without a source.
- B1 **Field database (automatic, local)**: at the end of every session with other human drivers (official, hosted;
  skip AI), record each driver's best lap (`CarIdxBestLapTime`), their iRating and licence (session info), car, track,
  layout, session type, date → `data\fieldlaps.tsv` (append-only, de-duplicated by session + driver). Backfill from
  the existing .ibt files first: `irsdkLogAllCars=1` means every car's `CarIdx*` channels are in them. From it compute
  per combo: **top 5%**, **top 25%**, **median**, and the pace of drivers at similar iRating to Peter — only when the
  sample is ≥ 30 drivers ("based on 64 drivers you've raced"); otherwise show nothing for that yardstick.
- B2 **iRacing app sources** (research first, read-only UI mapping like WS8): find whether the app shows per-combo lap
  leaderboards (Time Attack leaderboards, series results with fastest laps). If yes, read the top-5% / record laps for
  Peter's combos into the same store, labelled "iRacing time attack, week 4". If no reliable source, skip — don't guess.
- B3 **Real-world pros**: a small curated `data\pro-refs.json` for combos Peter owns where a real series races the same
  car class on the same track (e.g. IMSA GTD/GTD Pro at Road Atlanta — Petit Le Mans; IMSA at Lime Rock). Each entry:
  series, event, year, session (qualifying best / race fastest lap), driver, time, source URL to official timing.
  Only official timing sources; note "real car, real conditions — guide only". Research and fill for Peter's owned
  combos; leave out combos without a clean source.
- B4 **Presentation (very clean)**: one "Benchmark" card on the sessions page per combo and on the debrief after a new
  PB: Peter's PB at the top, then each yardstick as a thin horizontal bar with the time, the gap (+1.84 s) and his pace
  as a percentage (103.2%), plus "next goal" = the next yardstick up and the gap to it. History line of his PB over
  time (from career data) so improvement is visible. Black/gold, no badges, no emoji.
- Acceptance: fieldlaps parser test on a real race .ibt; percentile maths unit test; screenshot of the card with
  sample data; every pro reference has a working source URL.

### WS14 — PADDOCK: the name, and the side-screen gallery (C, S) — Peter 2026-10-09
**Name:** the app (dashboard, deck screens, intro, docs — everything we built) is **PADDOCK**. Show it in the gold
timing-screen style (letter-spaced caps) in the idle header, the intro, Rig Doctor, the deck add-on's name ("Paddock"),
and the docs. Do NOT rename exes, folders, process names, ports or the add-on UUID (paths are wired into the Stream
Deck profile, the logon task and irdash) — display names only.
**Side-screen gallery:** when iRacing's sim is not running, the LEFT and RIGHT race screens show a premium slideshow of
racing at beautiful tracks at sunset; the MIDDLE screen keeps the iRacing app; the top screen keeps Paddock.
- A borderless window per side screen owned by irdash (or a small separate exe started by it), always at the BOTTOM of
  the z-order (never covers anything, never takes focus, not in the taskbar/Alt-Tab), filling the screen.
- **Peter 2026-10-09/10, supersedes the 8 s idea** ("slow down the image cycling dramatically and align photos
  together... really slow it down", then "actually i like the photo descriptions but dont brand paddock there and i
  want to minimize bar on bottom as much as possible. slow down images a bit more") → pictures change every **120 s**
  (`gallery_secs`, 30–600) with a slow 5 s crossfade (`gallery_fade`); BOTH sides change at the same moment and show a
  matched pair (similar light/colour), never the same image; **captions stay** (track · car/event, credit only where the
  licence needs it) as ONE line of small, soft text tucked bottom-left (~16 px, ~70 % opacity, no band/gradient/box);
  **no PADDOCK wordmark or app name on the gallery screens.** The app name stays on the dashboard/deck.
  (Old text below about 8 s, offsets and the wordmark no longer applies.)
  **Update 2026-10-10:** "remember to align the pics so its the same on both screens at the same time" → default
  `gallery_mode=same`: the IDENTICAL picture on left and right, crossfading in lockstep (`pair` = two matched pictures,
  kept as an option). And "i dont like the super heavy motion photos, a bit is ok but not too much" → no picture with
  the whole frame smeared/streaked or the car itself blurred; light panning blur is fine. Rejected pictures go to
  `paddock\gallery\rejected\`.
- ~~Images change every 8 s (setting 7–10 s) with a slow 1.5 s crossfade; the two sides change offset by half a cycle and
  never show the same image. Subtle "PADDOCK" wordmark small in a corner, optional caption (track · car · credit) in the
  same small caps, fading in after the image.~~
- **As built (`dash\src\gallery.cs`, tests `tests\gallery-test.ps1`):** `irdash.ini` keys `gallery=1`, `gallery_secs=120`
  (30–600), `gallery_fade=5` (never more than half of `gallery_secs`), `gallery_captions=1`, `gallery_mode=same|pair`
  (default `same`). Both sides share ONE timer and ONE crossfade (same start, same length, same easing; in `same` mode
  one picture is made once and both screens show it). Pictures are shuffled so every one is shown once before any comes
  round again, and never the same one twice running. `pair` mode: the whole library is planned a round at a time into
  pairs of pictures that look alike (brightness, warm/cool, colour strength). The caption is one small line (16 px,
  light grey ~70 %, very soft shadow) in a window only as big as the text, 28 px from the bottom-left corner; it fades out
  first (0.6 s) and fades in 1.6 s after the new picture is fully in. Text = title from the credits file; the
  photographer and licence are added only where the credits file says `creditRequired` (or, when it does not say, for
  CC licences). A picture with no credits entry is shown with no caption. Credits are read from `credits.json` and from
  every `credits-*.json` in `paddock\gallery\` (keyed by file name). `/gallery` JSON: on/shown/why, `mode`, `secs`,
  `fade`, counts (`count`, `captioned`, `creditFiles`, `skipped`), per side the file, caption, credit, window handles and
  bounds, and a `z` self-check (nothing normal below the gallery windows). Commands (`/api/do?c=`): `galon`, `galoff`,
  `galnext` (waits for a change in progress), `galmode` (`same`|`pair`), `galrescan`; tests only (need the test hook):
  `galtiming` (`secs,fade`), `galsim` (a stand-in sim program name). Hides within 2 s of the sim starting and says in
  `irdash.log` how long it took ("gallery: the sim program started at ..., the gallery was gone N s later").
- **Motion-blur rule applied (Peter 2026-10-10):** the 22 approved pictures were judged by eye at 2560×1440 (plus a
  sharpness number); 9 went to `paddock\gallery\rejected\` with their credits and the reason in
  `rejected\credits-rejected.json` (6 heavy: 12, 23, 24, 25, 34, 35; 3 borderline with a sharp car but a fully streaked
  background: 05, 06, 33). 13 remain. Moving a picture back into `paddock\gallery\` and its entry into `credits.json` puts
  it back.
- Hidden and fully stopped (no GPU work) while the sim runs, during the startup intro, and while Peter is in a session.
- Images from `paddock\gallery\` (any .jpg/.png ≥ 2560×1440, cropped to fill, never stretched); credits for licensed
  photos in `paddock\gallery\credits.json` (photographer, licence, source URL) shown in the caption.
- Sources (Peter chose both): (1) free-licence photos (Unsplash/Pexels/CC) — shortlist in `docs\gallery-sources.md`,
  downloaded ONLY after Peter approves the list; (2) later, **his own iRacing captures**: his cars at his tracks at
  sunset, taken automatically while he is away (Test Drive/replay at dusk, cinematic cameras, UI hidden, iRacing's
  high-res screenshot), never while he's at the rig without asking.
- **Peter 2026-10-09: "yes download"** for the 22 picks (5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 18, 22, 23, 24, 25, 26, 30,
  31, 33, 34, 35, 38 in `docs\gallery-sources.md`). He also wants **celebration pictures** (podiums, champagne, a team on
  the pit wall at the flag, a winner's lap) and **IMSA multiclass — GTP (Porsche 963, Cadillac V-Series.R, BMW M Hybrid
  V8, Acura ARX-06, Lamborghini SC63) and LMP2 (ORECA 07)**, ideally at dusk/night (Daytona Rolex 24, Sebring, Petit Le
  Mans): "need to evoke emotion and be high quality". Same licence rules (free licence, credited; no ND licences);
  shortlist + contact sheet first, download only after Peter's yes. Also `paddock\gallery\mine\` = his own captures
  (the REPLAY screen's PHOTO key puts them there).
- Acceptance: both side windows verified at the bottom of the z-order (iRacing app in the middle stays usable and on top),
  no focus change logged, hides within 2 s of the sim starting, CPU/GPU near zero when hidden; screenshots.

### WS15 — REPLAY screen: iRacing's replay without its menus (A, S) — Peter 2026-10-09
Peter: "a whole expanded and dedicated replay section bc the iracing nav is very confusing... super intuitive".
Everything is driven by **iRacing SDK broadcast messages sent from irdash** (`RegisterWindowMessage("IRSDK_BROADCASTMSG")`,
`SendNotifyMessage(HWND_BROADCAST, id, MAKELONG(msg, var1), var2)` — irdeck's `Bcast` in `src\irdeck.cs` is the
reference): no clicks, no keys, no focus changes, instant (no exe start per press). State comes from irdash's own SDK
frames (`Sdk.Latest`) and session YAML.

**SDK facts** (irsdk_defines.h; verify each live and note results in `docs\replay.md`):
msg 0 CamSwitchPos (position, MAKELONG(group, camera)) · 1 CamSwitchNum (car number *raw* — DriverInfo `CarNumberRaw`,
MAKELONG(group, camera)) · 2 CamSetState (state bits) · 3 ReplaySetPlaySpeed (speed, slowMotion 0/1) ·
4 ReplaySetPlayPosition (posMode 0 begin/1 current/2 end, frame as the full var2) · 5 ReplaySearch (0 ToStart, 1 ToEnd,
2 PrevSession, 3 NextSession, 4 PrevLap, 5 NextLap, 6 PrevFrame, 7 NextFrame, 8 PrevIncident, 9 NextIncident) ·
12 ReplaySearchSessionTime (sessionNum, sessionTime ms) · 13 VideoCapture (0 screenshot, 1 start, 2 end, 3 toggle).
Camera group 0 / camera 0 = keep the current one; focus specials −3 incident, −2 leader, −1 exiting.
CamSetState bits: 0x08 UIHidden, 0x10 UseAutoShotSelection (iRacing's TV director); read current bits from
`CamCameraState`. Telemetry: `IsReplayPlaying`, `ReplayFrameNum`, `ReplayFrameNumEnd` (frames from live), `ReplayPlaySpeed`,
`ReplayPlaySlowMotion`, `ReplaySessionNum`, `ReplaySessionTime`, `CamCarIdx`, `CamGroupNumber`, `CamCameraNumber`,
`CarIdxPosition`, `CarIdxClassPosition`, `CarIdxLap`. YAML: `CameraInfo.Groups` (GroupNum/GroupName), `DriverInfo.Drivers`
(CarIdx, CarNumberRaw, UserName, CarClassShortName), `SessionInfo.Sessions` (SessionNum, SessionType). Slow-motion speed
values (e.g. 1 → ½, 3 → ¼, 7 → ⅛?) must be confirmed by reading `ReplayPlaySpeed`/`SlowMotion` back.
**Never** send ReplaySetState (6 = erase tape).

**Deck screen** (plugin action `com.peter.rigintro.replay`, bundled profile `RigReplay`, friends look: black, gold =
active/chosen, big plain words, live labels that say what the key will do *now*). MAIN key (5,1) `REPLAY LAST INCIDENT`
becomes the REPLAY screen key (the last-incident jump stays on the screen). 8×4 layout:
- Row 1 — where am I: `BACK` · a 5-key **timeline** (1,0–5,0) drawn as one strip: session name (RACE), lap n / total,
  "LIVE" or "−2:14 from live", speed (×1, ×4, ½), a gold marker where you are on the tape; **tap a fifth to jump there**
  (ReplaySearchSessionTime) · `SESSION` (cycles practice / qualify / race that are on the tape) · `LIVE` (back to live, ×1).
- Row 2 — transport: `START` (of this session) · `◀ LAP` · `REWIND` (taps cycle −1 → −2 → −4 → −8 → −16; when paused it
  is `◀ FRAME`) · `PLAY / PAUSE` (big) · `FAST` (×2 → ×4 → ×8 → ×16; when paused `FRAME ▶`) · `LAP ▶` · `SLOW MO`
  (½ → ¼ → ⅛ → off) · `BACK 10 s` (instant replay of what just happened).
- Row 3 — what to watch: `◀ INCIDENT` · `INCIDENT ▶` · `MY CAR` · `CAR AHEAD` · `CAR BEHIND` (relative to the car being
  watched, by class position in multiclass) · `LEADER` · `PICK CAR` (sub-view: 24 tiles by position, "P3 #22 SMITH",
  Peter in gold, class colour strip, PREV/NEXT pages, BACK) · `MY LAST INCIDENT` (what the old key did).
- Row 4 — how it looks: `CAMERA ◀` · `CAMERA ▶` (the current camera's name big across both) · three direct cameras
  `TV` · `COCKPIT` · `CHASE` (by group name from the YAML; hidden if the track has none) · `AUTO TV` (toggle the TV
  director, gold when on) · `HIDE UI` (toggle, gold when hidden) · `PHOTO` (hides the UI for the shot, iRacing
  screenshot, UI back; copies the new file into `paddock\gallery\mine\` so it joins the side-screen gallery (WS14) when it
  is ≥ 2560 wide; key flashes SAVED).
- **Out of a session** the screen shows **MY REPLAYS**: the newest saved replays from `Documents\iRacing\replay\*.rpy`
  (date, track, car — read from the file header/name), tap = open it. *Research first* how a saved .rpy opens (file
  association in the registry, read-only; sim command line; or the iRacing app — UI automation rules apply) and
  document it; if it needs the iRacing app and it isn't safe/reliable, show the list with "open from the iRacing app"
  and stop there. Never write iRacing settings (e.g. auto-save replays) — recommend to Peter instead.
- **While driving** (`IsOnTrack` and not `IsReplayPlaying`) every key is dimmed and the strip says "GET OUT OF THE CAR TO
  WATCH REPLAYS"; irdash refuses the commands too. BACK always works.
- irdash: `dash\src\replay.cs` (stub wired in irdash.cs: `/replay` JSON, `/api/do` whitelist `rp*` commands, Init).
  `/replay` gives everything the deck draws (live/replay, session list, lap, time from live, speed, slow-mo, camera group
  name + list, watched car (number, name, position), my car, UI hidden, auto TV, saved replays list) — drawn instantly
  from cached state; presses update the cache optimistically. While the test hook's pretend session is on, commands are
  **recorded** (`/api/test/replaylog`) instead of broadcast, so tests check the exact SDK messages per key.
- Acceptance: mock test (deck harness, every key → exact message recorded, labels change with state: paused shows
  FRAME keys, driving dims all); live test `tests\replay-test.ps1 -Live` in a spectated AI race (Peter away, guard
  `-NeedAway`): every key verified by telemetry read-back (speed, frame moved, camera group, CamCarIdx, UI bit),
  screenshots of the middle screen per key (`tests\shots\rp-*.png`); one add-on install for Peter.

### WS16 — Performance: frame-rate report and "did it help?" (A, S) — Peter 2026-10-09
Peter: "definitely add frame rate report to our tool somewhere and performance optimization". Today `fps-report.ps1`
(root) does it by hand from one .ibt. Graphics are settled (~104 fps full race, cap 160) — this is about *knowing*,
catching what steals frames, and proving whether a change helped; never about changing iRacing graphics on our own.
- F1 **Automatic report per session** (`dash\src\perf.cs`, stub wired: `Perf.Init(<root>\data)`, `Perf.Start()`,
  `GET /perf` + `/perf/*` via `Perf.Route`, `/api/do` via `Perf.Handles/Do`): when a session's .ibt is complete,
  compute (port the fps-report.ps1 logic to C#, reuse irdash's .ibt reader read-only): average fps, 1% low and worst
  (of iRacing's 1-s `FrameRate`), % of driving time below the cap, `CpuUsageFG`/`CpuUsageBG`/`GpuUsage` avg + peak,
  the verdict (GPU-limited / CPU-limited / headroom), the worst places on track (LapDistPct buckets → corner names the
  debrief already uses), cars on track, and for online sessions the connection (`ChanLatency`, `ChanQuality`,
  `ChanPartnerQuality` if present). Append to `data\perf.tsv`; backfill all existing .ibt files once.
- F2 **What else was running**: while the sim runs, sample every process's CPU time every 5 s (cheap — no WMI per
  sample, no per-frame work) and, when fps dips below normal, note the top non-sim CPU users (e.g. OneDrive uploading
  telemetry, Defender scan, Windows Update, Chrome, irdashies, CrewChief). Also record Paddock's own cost (irdash +
  dashboard Chrome + delta bar) and the overlays' cost per session. Store with the session.
- F3 **Performance page** `www\v2\perf.html` (opened from the Sessions page, the debrief and a deck key; same premium
  look, readable from the seat): last session card (big avg / 1% low, verdict in one plain sentence, worst corners,
  "what else was running"), a trend of avg and 1% low over sessions grouped by track and field size, with **change
  markers** from `data\perf-changes.tsv` (graphics changes via gfx-set.ps1, sim priority, overlays on/off, driver
  updates detected from the NVIDIA driver version, iRacing build) so "did it help?" is answered with like-for-like
  numbers (same track ± field size), and Paddock's own cost.
- F4 **Optimisation checklist** (on the page; Rig Doctor gets one summary line later): measured items only, each with
  the evidence. Fix automatically what is ours (e.g. lower irdashies' and the dashboard Chrome's priority during a
  session, back after — only if F1/F2 numbers show it helps; never CrewChief, its spotter calls must stay on time;
  keep the dashboard's update rate modest while
  driving; gallery stopped while the sim runs). Windows-level items (power plan, Game Mode, Xbox Game Bar background
  recording, OneDrive pausing sync during sessions / excluding telemetry from sync, HAGS) are only **detected** and
  offered as a one-click `tools\perf-*.cmd` + UNDO for Peter to run himself — never run them. iRacing settings:
  read-only drift check against the settled baseline (an update can reset them) — report, never write.
- F5 **Live, calm**: the top-screen dashboard shows the current fps small; a quiet amber line only when the 10-s average
  is > 15 % below his normal at this track (with the likely cause from F2). Nothing on the race screens.
- F6 *(optional, needs Peter's yes for the download)*: PresentMon for true frame times/stutter — propose only.
- Deck: the MORE page is parked (build-deck.ps1), so a PERFORMANCE key needs a MAIN slot Peter approves (WS7); until
  then the page opens from the Sessions page, the debrief and `/api/do?c=perf` (never while driving).
- Acceptance: per-session numbers equal fps-report.ps1 on the same .ibt (± 1 fps); backfill count; sampler CPU cost
  measured (< 0.2 % of one core); page screenshots `tests\shots\perf-*.png`; checklist detection unit-tested on this PC
  without changing anything; `tests\perf-test.ps1` with the guard.

### WS18 — Corner model: every turn labelled on every track map (A, S) — Peter 2026-10-09: "need turns labeled on track map"
One source of truth for corners, used by the live map, brief, debrief, lap analysis, Vault, benchmark, brake cues.
- The live map (`www\v2\map.js`, `TrackInfo`) already names turns from **Lovely Track Data** (CC BY-NC-SA 4.0, fetched
  from GitHub at run time, cached in the browser) — only where the dataset has the track, and only when online.
- C1 **Coverage audit**: Peter owns 43 track folders (`C:\Program Files (x86)\iRacing\tracks`). Match each owned
  track + layout to Lovely's manifest (and to the track id/name in his .ibt session YAML: `WeekendInfo.TrackID`,
  `TrackName`, `TrackConfigName`); write `docs\corners.md` with a table: track, layout, Lovely yes/no, how many turns.
- C2 **Offline copy**: keep a permanent copy of the Lovely files for his owned tracks in `data\corners\lovely\` (tiny;
  credit kept; personal use). The map reads the local copy first, GitHub only to refresh. (Fetching ~43 small JSON
  files = the same thing irdash already does at run time; mention it to Peter in the report.)
- C3 **Fallback = detect from his own driving**: where Lovely has nothing, find corners in his best lap's telemetry
  (yaw rate / lateral g / steering above a threshold, merged and numbered in lap order, apex = max curvature; the
  debrief already segments corners — reuse it) and store `data\corners\auto\<trackkey>.json` with `T1…Tn` + `pct` start/
  apex/end. Lovely names win when both exist; the numbers stay consistent (T1…Tn by lap order) so "T5" means the same
  everywhere. Pit in/out and start/finish line marked too.
- C4 **`/corners?track=&config=`** (irdash, new `dash\src\corners.cs`): `[{n, name, pct0, pctApex, pct1, source}]`
  plus pit in/out, sectors. One JS module `www\v2\corners.js` (`Corners.load(track, config)`, `.at(pct)`, `.draw(ctx, layout)`).
- C5 **Drawing (premium, calm)**: small gold numbered discs on the racing line at the apex, name in small caps beside
  it only when there is room (no overlaps — reuse `put()` placement from map.js), numbers always; track outline thin
  white, start/finish line, sector ticks. Same look on every page; readable from the seat on the 1920×1080 top
  screen. The live map keeps working offline.
- Acceptance: 43/43 owned tracks have numbered corners (named or detected); screenshots of 6 tracks incl. a
  Lovely-less one (`tests\shots\c-*.png`); `tests\corners-test.ps1` (guarded): endpoint shape, detection on a real .ibt
  gives a plausible corner count (e.g. Road Atlanta 12), local copy used with the network blocked.

### WS17 — VAULT: keep your best races, laps and clips; replay them with the data (B, S/Opus design) — Peter 2026-10-09
Peter: "a whole save system for best races, where can I store clips cheaply and integrate with lap analysis and
Cosworth and replay. I want a full blown amazing system."
**Idea:** a *moment* = a lap, a race or a clip, saved with everything about it, one click from any other part of Paddock.
- **Moment record** (`vault\moments.json`, one JSON per moment in `vault\items\<id>\moment.json`): id, kind
  (lap / race / clip), date, car, track, layout, session type, lap number, lap time, finish position + field size,
  gap to PB, tags (PB, WIN, PODIUM, BEST RACE, INCIDENT, OVERTAKE, CLEAN), ★ keeper flag, note, files:
  `ibt` (the session's telemetry + lap range), `video` (clip file + the moment it starts), `replay` (.rpy + time),
  `thumb`, corner times (from WS18).
- **Saves itself** (no effort): new PB for a car+track; the best 3 laps per car+track; every race finish in the top 3,
  a win, a best-ever result or a big iRating gain; each marked keeper so it is never pruned. Everything else from
  the last 30 days stays as "recent" and is pruned by the budget below.
- **One-press keys while racing** (deck, only these two; Peter presses them, we never press anything for him):
  `★ KEEP` = marks the current lap/race (instant, no window, no focus change) and `CLIP` = saves the last ~30 s of
  video (see Recording) tagged with the current lap and track position. Both beep softly and flash green on the key.
- **CHANGE 2026-10-10 (Peter: "no, not nvidia app - integrated with iracing, save and watch via paddock, super easy and
  intuitive") - supersedes the NVIDIA text below.** Paddock records by itself: irdash starts/stops a small hidden recorder
  (**ffmpeg**, `vault\bin\ffmpeg.exe`, needs Peter's yes to download, ~90-100 MB) when a session is on track and stops it
  when the sim exits. It captures the middle race screen with `ddagrab` (desktop duplication, GPU) and encodes with the
  GPU's hardware encoder (`hevc_nvenc` or `h264_nvenc`, ~12-16 Mbps; fall back to `libx264 -preset veryfast`) into a
  **rolling buffer of 10-second segments** (last ~3 minutes kept; segment names carry the exact start time, so the
  video/telemetry sync is exact - no SYNC nudge). Keys: `CLIP` (last 30 s) and `KEEP` (keeps the current lap's video + data);
  the auto-save rules (PB, podium, win) also cut the best lap's clip from the buffer when it is still there. Peter sets
  nothing up. No audio in V2. Recorder at BelowNormal priority; its cost is measured (Performance page, recorder-off vs
  on); it records only while the sim runs and only the middle screen. Must handle: the 180-degree rotated screen (the
  picture must come out upright), borderless vs exclusive fullscreen (duplication shows nothing in exclusive fullscreen:
  detect an empty capture and tell Peter in plain words), and recovery if ffmpeg dies. Replaces the NVIDIA hotkey plan.- **Recording — cheapest first, no new software:** the NVIDIA app is already installed (`C:\Program Files\NVIDIA
  Corporation\NVIDIA app`): its **Instant Replay** records the last minutes with the GPU's hardware encoder (almost no
  frame-rate cost) and saves a clip on a hotkey (default Alt+F10 — verify). `CLIP` sends that hotkey (same method as
  our other key presses; pressed by Peter, so allowed in the car); irdash watches its output folder (default
  `%USERPROFILE%\Videos\NVIDIA\...`), waits until the file is complete, attaches it to the moment by time (file end ≈
  press time, duration from the file), and moves/copies it to `vault\clips\`. Peter's one-time setup (documented
  step by step in `docs\vault.md`, with a screenshot-checked checklist; we do not edit NVIDIA's settings):
  Instant Replay on, last 1 min, 1080p60 or 1440p at ~12-16 Mbps HEVC, save to the NVIDIA folder.
  *Optional later (needs Peter's yes to download, ~90 MB):* **ffmpeg** for small thumbnails, exact trimming to a lap
  and HEVC compression (about 40-60 % smaller). Playback needs neither (the page seeks to the right second).
  iRacing's own video capture is poor (`vidCaptureEnable=0`, capped 1280x720 30 fps, app.ini): not used; the PHOTO key
  of WS15 covers stills.
- **Where it lives / cost:** `vault\` inside the project folder (local SSD, **not** in OneDrive: a synced video
  folder would upload during races and hurt frame rate). The SSD has ~370 GB free. Typical sizes: a 30 s 1080p60 clip
  at 12 Mbps ≈ 45 MB; one session's telemetry ≈ 8 MB (141 files = 1.1 GB so far); a race replay `.rpy` ≈ 50-300 MB
  and only works on the iRacing build that made it. So 100 clips ≈ 4.5 GB, 500 keeper laps' telemetry ≈ 4 GB:
  **a year of racing is a few tens of GB.** Budget `vault_gb=60` (irdash.ini): keepers are never deleted; unpinned
  recent clips go oldest-first beyond the budget; the page shows size used. Backup (all optional, Peter's accounts/
  purchases, we only prepare the one-click tool): (a) external USB drive: `tools\vault-backup.cmd` copies new files
  whenever it is plugged in (about £50 for 1-2 TB, one-off); (b) cloud: roughly $6 per TB per month for Backblaze B2
  (30 GB ≈ 20 cents a month; Peter makes the account, we never enter credentials); (c) YouTube unlisted for sharing
  a clip with friends (Peter uploads from the page's SHARE button, which opens the file location). Prices are rough;
  check before buying.
- **Vault page** (`www\v2\vault.html`, opens on the top screen from the Sessions page and a deck key; also usable in
  any browser at `localhost:8199/v2/vault.html`): thumbnail grid (car · track · time · +gap to PB, gold ★ keepers, tag
  chips), filter by car / track / tag / year, search; sort by date, time, gap. **Detail view:** video player with the
  **labelled track map** (WS18) beside it and a dot that moves with the video; speed / throttle / brake / delta traces
  underneath on one shared cursor; corner table (time in each turn vs PB, vs the best lap in the Vault for the car +
  track); notes; buttons: PLAY IN IRACING (replay), OPEN IN COSWORTH, COMPARE, SHARE, DELETE (asks twice).
- **Telemetry ↔ video sync:** the .ibt has the session start wall-clock time and `SessionTime` per sample; the clip has
  its end time (file time) and length, so every `LapDistPct` maps to a video second. Click a turn on the map or a
  point on a trace → the video jumps there; play → the dot and cursor follow. Accuracy is ±1 s (hotkey delay), so the
  detail view has a one-time SYNC nudge (−3…+3 s, remembered per recorder) — learn it once.
- **Compare:** pick two moments of the same car + track → two videos side by side, **locked by track position** (the
  one ahead waits, so both always show the same corner), delta trace between them. This is the "amazing" bit.
- **Cosworth (WS2):** every keeper's `.ibt` is also kept untouched in `vault\telemetry\<car>\<track>\<date> <time>.ibt`
  (Pi Toolbox Lite opens .ibt natively); OPEN IN COSWORTH starts Toolbox on it (after Peter installs Pi Toolbox Lite;
  until then the button copies the path / opens the folder). ANALYSE BEST (C3) = the Vault's best laps.
- **Replay (WS15):** for keeper races the system offers to keep iRacing's own replay file. **Research first** (read-only,
  Peter out of the car): can a replay be saved without the iRacing UI (SDK, a key, sim command line; the sim's
  `[Replay]` settings in app.ini are read-only to us — rule 2)? If saving needs the replay UI, the REPLAY screen gets a
  `SAVE REPLAY` key that does the UI steps with the usual verify-before-click rules, only when the sim is in a
  replay/out of the car. Saved replays are listed in MY REPLAYS and in the Vault with the moment's time, and PLAY IN
  IRACING jumps the replay to it (ReplaySearchSessionTime) once opened. Replays only open in the same iRacing build:
  show a warning chip when the build differs.
- **Phases:** V1 index + auto-save of laps/races + Vault page without video (uses WS18 map, Benchmark card, PB
  delta); V2 clips (NVIDIA hotkey + attach) + video player + sync; V3 compare + Cosworth button + export; V4 replay
  save/play; V5 storage budget + backup tools. Each ships and is tested before the next (tests guarded, mock clips are
  generated test videos of a few seconds, never recorded from his screen).
- Acceptance: auto-save from three real .ibt files (PB, podium race, ordinary session); budget pruning unit test;
  fake clip attaches to the right lap with sync within 0.5 s on a synthetic file; page screenshots
  (`tests\shots\v-*.png`); the two keys press-tested through the deck harness; `docs\vault.md` for Peter.

### WS19 - STUDIO: beautiful replays from several camera views, edited into one recording (C, S) - Peter 2026-10-10
Peter: "no cloud, but let's try local for now. Think of beautiful replays after, being able to get different views and
combine into a nice recording. So a mini video editor but efficient." Storage = local only (vault\ on the SSD; no cloud
for now; the external-drive copy tool stays optional). Builds on WS17 (Vault, recorder, ffmpeg in vault\bin), WS15
(replay control by SDK messages), WS18 (corner names) and the research in docs\vault-recording-research.md.
**The efficient idea: edit the PLAN, not the pixels.** A *shot list* says which camera to use for which part of a lap
(by LapDistPct / corner / time) - e.g. TV at the start, chase through T1-T3, cockpit in the Esses, helicopter on the back
straight, slow motion over the apex of T11, hold on the finish line. Paddock then films it in ONE real-time pass of
iRacing's own replay (SDK: ReplaySearchSessionTime to the lap start, CamSwitchPos/CamSwitchNum with the wanted camera
group at each cue, ReplaySetPlaySpeed for slow-mo ramps, HIDE UI) while the Paddock recorder (ffmpeg, GPU encoder) films
the middle screen. Result: a finished multi-angle clip in about the length of the lap, GPU-cheap, nothing to cut afterwards.
- S0 **No thinking (Peter: "just make it all easy and intuitive so I don't have to think")**: the default is that nothing
  needs to be pressed. After a session, when Peter is away and the sim is still on it, Paddock films the best lap (and for a
  race, a short highlight reel) by itself in the CINEMATIC style and puts it in the Vault as "ready to watch" with a
  thumbnail; he only opens the Vault and taps play. Everything else (changing cameras, slow-mo, combining) is optional and
  lives behind one EDIT button. Never ask a question the system can answer; no settings screens; sensible defaults.- S1 **Auto-director**: one press (`MAKE A REPLAY` on a Vault moment, or the deck) builds a shot list for the lap from the
  corner model (WS18): wide/TV cameras on straights, chase or cockpit in technical sections, slow motion on the
  biggest time-gain or time-loss corner (from lap analysis), a short opening on the grid/pit and a final hold on the
  finish; 3 presets: CINEMATIC (more cuts, slow-mo, helicopter), ONBOARD (cockpit + chase only), BROADCAST (TV style).
- S2 **Mini editor** (page `studio.html`, opened from a Vault moment): a timeline of the lap with the corner names; each
  segment shows its camera as a gold chip - tap to change camera (TV / chase / cockpit / roof / helicopter / pit lane /
  whatever the track offers, from the replay's camera groups), drag the cut points, add/remove SLOW-MO, FREEZE at the apex,
  set START and END, tap PREVIEW (plays the plan on the map, no filming), then FILM IT. Plain words, big targets,
  no jargon, works with the Stream Deck too (next/previous segment, camera, slow-mo, FILM).
- S3 **Overlays burned in (optional, off by default)**: lap time, delta to PB, speed, a thin labelled track map with the
  car dot, the corner name as it is passed - drawn by ffmpeg from the telemetry (drawtext/overlay from a generated
  subtitle or PNG sequence), premium black/gold, small. A clean version without overlays is always kept.
- S4 **Combine**: side-by-side or picture-in-picture of two takes (e.g. cockpit + chase, or this lap vs the PB lap
  locked by track position, from WS17 Compare), title card (track, car, lap time, date) and end card, crossfades
  between shots (ffmpeg xfade), a hold-and-slow-down at the finish. Export MP4 (HEVC or H.264, 1080p/1440p), tidy file
  name, thumbnail, saved into the Vault with the moment. Music: none by default (a local file picker is allowed later).
- S5 **Races**: a whole-race highlight reel from a saved/open replay: the start, each of Peter's overtakes and incidents
  (from telemetry: position changes, incident count), the last laps, the finish - cut by the same shot list engine.
- Constraints: the replay must still exist - an unsaved replay is only playable while the sim stays on that session
  (community knowledge, experiment E5 in the research doc), so the flow is: finish the race, leave the sim open, press
  MAKE A REPLAY (the system waits until Peter is away 10 minutes unless he presses FILM IT himself); saved .rpy files
  can be opened only through iRacing's own menus (not automated). It never runs while he is driving; he is told in
  plain words what is happening and the screen shows "FILMING" on the deck while it runs; the sim keeps its normal window.
  All camera cues are SDK messages (no clicks). Render in real time, GPU encode, BelowNormal ffmpeg for exports.
- Acceptance: a 1-lap CINEMATIC film of Road Atlanta from a real AI race replay (Peter away): >= 4 camera changes
  landing within 0.5 s of their cues, slow-mo segment at the right corner, upright picture, no UI, file < 150 MB;
  shot-list maths and the editor page tested with mock data and screenshots (`tests\shots\st-*.png`); `tests\studio-test.ps1`
  guarded; docs\studio.md for Peter.
### WS10 — Coaching engine (C, S) — from docs\COMPETITIVE.md
Builds on D2 (lap analysis endpoints) and O5 (PB reference). All local, from Peter's .ibt files; never during a session
except the cues in T3.
- T1 **Corner report card**: per corner (debrief segmentation, Lovely corner names): brake point (m before the apex),
  peak brake, min speed, coasting time (throttle < 5% and brake < 5%), throttle pick-up point, exit speed. Best lap vs
  typical lap and vs PB. Endpoint `/coach/corners?file=&lap=&ref=pb|best`. Table on the lap-analysis page.
- T2 **Your three fixes**: rank corners by time lost vs the reference; classify the main cause per corner from T1
  (brakes early / over-brakes / low min speed / late throttle / coasting / poor exit) with thresholds documented in code;
  plain-English sentence + time. Shown on the debrief (top) and sessions page. Unit tests on synthetic laps for each cause.
- T3 **Brake-point cues** (practice aid): irdash plays a short soft tone ~0.6 s (speed-scaled) before the PB reference
  brake point of each corner; only in practice/test sessions; deck toggle BRAKE CUES on the OVERLAYS or MY DRIVE screen;
  default off. Use a tiny WAV via System.Media / winmm; never steal focus. Measure latency.
- T4 **Benchmark vs the fastest car**: from live `CarIdxLapDistPct` + `SessionTime`, time every car through every corner
  segment (same segmentation); after each lap compare Peter's segments with the session's fastest car in his class
  (their best per segment). Debrief section "Where the fastest car gains" + `/coach/benchmark`.
- T5 *(optional, ask Peter first)* between-lap spoken tip from T2 in practice — only if a test clip with the best
  installed Windows voice sounds good to him.

### WS11 — Racecraft on the dashboard (C, S)
- K1 Standings/relative on the top screen: iRating gain/loss per driver (D3 formula), positions gained since the start,
  pit stop count, last lap, interval, gap-trend arrow (5-lap trend). Columns configurable in irdash.ini.
- K2 Fuel-save target: when fuel to finish is short, per-lap fuel target to avoid a stop and the lift-and-coast laps needed.
- K3 Head-to-head panel (car ahead / behind): last 3 laps each, sector comparison, who is faster where.

### WS12 — History (C, H/S)
- H1 iRating / licence trend chart on the sessions page from each .ibt's session info (Peter's own entry; skip AI
  sessions where his iRating reads 1).

---

## 4. Order of work
1. Phase A (one Sonnet agent, sequential, files owned: `src\*`, `dash\*`, `deck-intro\*`, `build-deck.ps1`, `tests\*`,
   `docs\*`): O1, O2, WS6, S1. One add-on install at the end (Peter clicks Install). Report what Peter must do.
2. Phase B: Q1–Q3, D1–D4, S2–S3, O3–O4.
3. Phase C (next, Peter's picks 2026-10-09): WS8 official racing (incl. R7 race weekend), O5 delta to all-time PB,
   WS13 benchmark, WS9 visual polish,
   then documentation of the whole project (CLAUDE.md + docs\ARCHITECTURE.md + docs\OPERATIONS.md + docs\USER-GUIDE.md).
   **WS10 coaching engine, WS11 racecraft, WS12 history are PARKED** (Peter 2026-10-09: "forget the other tools...
   let's get the basics") — keep docs\COMPETITIVE.md as the record, don't build them unless he asks.
   Rig Doctor principle (Peter): it FIXES things automatically; it only tells him about things only he can do.
   **2026-10-09 late, running now:** WS15 REPLAY screen (deck owner: plugin.html, build-deck.ps1, the add-on's
   "Paddock" display name), WS14 gallery + Paddock name (everything except plugin.html), O5 + WS13 (deltabar.cs, data
   side). WS8 waits for a time Peter is away (R1 maps the live iRacing app); its deck screen R5 waits until WS15 has
   released plugin.html. WS9 polish goes last (it touches every page).
4. Later: Cosworth (after Peter installs Pi Toolbox Lite), AI race mapping (Q4), MAIN refresh (WS7, Peter approves).
   Not wanted (Peter, 2026-10-09): lap art, results cards, live TV graphics, night mode, ambient lights.

## 5. Already decided — don't revisit
- irdashies stays the overlay engine (25+ widgets, drag-to-place); we add control + a native delta bar.
- No looping video. No phone/QR features (Peter wants control on the Stream Deck).
- Quotes on the idle screen are from real racers, attributed.
- Graphics are settled (~104 fps race baseline): don't change iRacing graphics without Peter.
