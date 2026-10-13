# Performance: frame-rate report, what slowed it down, "did it help?"

Built 2026-10-09/10 (WS16 in `SPEC-next.md`). Peter: "definitely add frame rate report to our tool somewhere and performance
optimization". This is about **knowing** (how fast was the last session, what held it back, did my change help), never about changing
iRacing's graphics on its own.

Code: `dash\src\perf.cs` (all of it), `dash\www\v2\perf.html|css|js` (the page), `dash\www\v2\perflive.js` (small fps figure, amber line,
the page host on the dashboard; `FrameRate` added to `VARS` in `core.js`, one `<script>` line in `index.html`), `tools\perf-*.cmd` +
`tools\perf-tools.ps1` (Windows experiments, Peter runs them himself), `tests\perf-test.ps1` (`-Offline` = the parts that touch no live app).
Data (all in `data\`, plain tab-separated text): `perf.tsv`, `perf-procs.tsv`, `perf-changes.tsv`, `perf-state.tsv`, `perf-gfx-last.tsv`,
`perf-gfx-baseline.tsv`, `perf-prio.tsv`. The old hand-run `fps-report.ps1` still works and is what the numbers are checked against.

## What Peter sees
- **Performance page** (`/v2/perf.html`, also over the top screen): last-session card (big average / 1 % low / worst second, one plain
  sentence, "+6 fps against your usual 103 here", where on the track it was slowest by corner name, what else was running), the trend of
  average and 1 % low over sessions with a dotted gold line wherever something was changed, "Did it help?" for each change, the checklist.
- **Top-screen dashboard, live:** a small `104 fps` next to the track name. One quiet amber line only when the 10-second average is more
  than 15 % under his usual for this track and car and field size, with the likely cause ("OneDrive is busy (30 % of a core)", "the graphics card is full"). It is two short lines and takes the place of the small health dots for as long as it shows.
  It needs 20 s on track first (loading hitch), clears itself when the rate is back within 10 %, and never shows for a small dip.
  Nothing is ever drawn on the race screens.
- **Tap a dot** on the trend to see that session in the card (and what else was running then); "Back to the latest" returns.
  `perf.html?file=<name>.ibt` opens a given session's card (for links from the Sessions page and the lap analysis).
- **Opening the page:** `GET /api/do?c=perf` (a Stream Deck key, never while driving: HTTP 400) opens it over the top screen,
  `c=perfclose` closes it. `?perf=1` on the dashboard address opens it on load. The idle screen has a quiet "Performance ›" link next to
  "Sessions & laps ›" (added by `perflive.js`, the idle markup is untouched).
- **Rig Doctor / deck line:** `GET /perf/summary` -> `{"text":"Last session 108 fps average, 89 at the low end. Smooth. ..."}`.

## F1 The report for every session (`perf.tsv`)
One row per `.ibt` file (iRacing starts a new file each time he gets in the car). Computed in the background, newest first, lowest thread
priority, **only when the sim is not running** (menus, garage and pits count as running), never a file touched in the last 2 minutes,
never an OneDrive "online-only" file; read-only, `FileShare.ReadWrite`. A file is done once (name + size). The first pass did the 140
existing files in about 10 s. `GET /perf/scan` (or `c=perfscan`) runs a pass now.
The maths is the maths of `fps-report.ps1`: ten samples a second, only while on track, first 5 s after each time he gets in skipped,
`FrameRate` is iRacing's 1-second average. Average, 1 % low (the value 1 % of the way up the sorted samples), worst, `CpuUsageFG` and
`GpuUsage` average and peak, "limit seen" = the highest frame rate in the session and time below it, verdict. The test compares four
real files with the script: average, 1 % low, worst, CPU, GPU, seconds all within 1.
Extra to the script: dips (% of the time more than 15 % under the session's own median), `CpuUsageBG`, hard page faults per second
(`MemPageFaultSec`), cars on track (average count, only when the file has the `CarIdx*` channels; today's files do not, so the field size from
the session list is used), the iRacing build (`BuildVersion` in the session info), and for **online** sessions only (`SubSessionID > 0` or
official) the connection: ping (`ChanLatency`), quality, partner quality. Offline, iRacing reports a fixed 33 ms, so nothing is shown.
Missing channels are fine (columns read -1 / blank).
**Worst places:** the lap in 2 % pieces by `LapDistPct`; pieces with at least 2 s of samples that are 3 % or more under the session average,
neighbours joined, the three slowest kept. The page names them with the corner names the debrief and the lap analysis use
(Lovely Track Data via `TrackInfo`); without names it says "Lap 34-42 %".
**Verdict** (the script's thresholds, plain wording): held its limit with room to spare (average within 3 of the highest seen and GPU and CPU
under 70 %); graphics card is the limit (GPU >= 90 %); processor is the limit (CPU >= 85 %); otherwise "Smooth ..." (both under 70 %) or "Close to
the limit - leave the settings as they are".

`perf.tsv` columns: file, size, start (unix), dur, secs (driving time counted), track, config, trackKey, trackRaw, car, type, build, online,
field, cars, avg, low1, worst, cap, belowPct, dipPct, cpuAvg, cpuPeak, gpuAvg, gpuPeak, bgAvg, bgPeak, verdict, latMs, latMax, qual, partner,
pfAvg, pfPeak, worstPlaces (`from-to:avg:min:samples:gpu%:cpu%;...`), computed, v. A session "counts" (trend, usual, comparisons) when it has
at least 2 minutes of driving.

## F2 What else was running (`perf-procs.tsv`)
One low-priority thread (`PerfSampler`). Every 5 s, **only while the sim program runs**, it reads each program's CPU time
(`Process.GetProcesses` + `TotalProcessorTime` deltas, every `Process` disposed, protected system programs asked once and then ignored; no WMI per
sample, nothing per frame) and the sim's own `FrameRate`. Time on track is cut into **drives** (10 s off the track ends one; the first 15 s are
skipped). For each drive it keeps per program the average CPU use and the average during **dips** (frame rate 15 % under his usual here, or
under the drive's own median when there is no history). Programs are grouped under friendly names (OneDrive, Windows Defender, Windows Update,
Chrome, Steam, Xbox Game Bar, NVIDIA software, ...). Our own are always separate: the sim, Paddock (dashboard program, its browser, key presses),
the overlays (irdashies), CrewChief. Which Chrome is the dashboard's is found once, by its own profile folder (one WMI question, never while on
track). Units: percent of **one** core (100 = one whole core busy). A session row on the page is matched to the drive that overlaps it in time.
Drives are written to `perf-procs.tsv` when they end (one line, a few hundred bytes); nothing else is written while the sim runs.
**Cost**, measured with the thread's own CPU clock and shown on the page and `/perf/status`: the first run on the real PC (with the first-sample
warm-up included) was 4.8 ms per reading, 0.096 % of one core. Budget 0.2 %.

## F3 Change markers and "did it help?" (`perf-changes.tsv`)
Detected by Paddock itself, read-only, polled at start, at every sim start and exit, every 5 minutes otherwise (the NVIDIA driver once a day):
| Kind | Where it comes from |
|---|---|
| graphics | the backups `gfx-set.ps1` makes (`backup\rendererDX11Monitor-*.ini`, also `Documents\iRacing\rendererDX11Monitor.ini.bak-*`): each backup is the state *before* a change, so comparing it with the next backup (or the current file) gives that change and its exact time. A difference nobody backed up (made in iRacing's own menus) becomes "Graphics changed in iRacing". Only `[Graphics Options]`; iRacing's memory budgets are ignored. |
| priority | `irdash.ini sim_priority` |
| overlays | `/overlays`: how many widgets, which, which preset |
| delta bar | `irdash.ini delta_bar` |
| driver | NVIDIA driver version (WMI, once a day), shown the way NVIDIA writes it (617.42) |
| iracing | the build in the install folder (`version_system.txt`) and the `BuildVersion` of each session (an update shows up between two sessions) |
| windows | power plan, Game Mode, Game Bar recording, hardware GPU scheduling |
| paddock | our own priority trial starting or stopping |
The first look at a value is only remembered (`perf-state.tsv`), not a change.
**Episodes:** changes with no real drive (2 minutes or more) between them, or less than 20 minutes apart, are one tuning session, so an
afternoon of graphics tuning is one entry ("Graphics tuning (5 settings)": the net effect, a setting tried and put back is no change).
**"Did it help?"** for an episode: sessions that **count** (>= 2 min), at the **same track, same car, same kind of field** (alone / a few / up
to 20 / bigger), up to 8 before it (after the previous episode) and up to 8 after it (before the next). Needs **2 on each side**, otherwise it says
"Not enough sessions yet" and how many more. Medians of average and 1 % low; "helped" when the average is up 3 % or the 1 % low 4 % (and
beyond the wobble between the "before" sessions), "hurt" the same way down, "mixed" when one goes up and the other down, otherwise "no clear
change" with the wobble. Never a guess from different tracks or cars.

## F4 Checklist (measured items only)
Everything is **detected read-only** (the power plan, Game Mode and Game Bar come from registry reads; GPU scheduling is asked of
Windows' graphics kernel; iRacing's graphics file is read, never written). Items, each with its evidence:
- *Paddock's own programs* and *CrewChief*: their measured CPU over the last drives. CrewChief is **never touched**.
- *Lower our own programs' priority during sessions* (the one automatic fix that is ours): see below.
- *Other programs during dips* and *OneDrive*: which program was busy when the frame rate dipped, in how many drives.
- *Windows power plan*, *Game Mode*: the existing `RIG TUNE.cmd` fixes both (and `UNDO rig tune.cmd`).
- *Xbox Game Bar background recording*: if on, `tools\perf-gamebar-off.cmd` (+ `perf-gamebar-off-UNDO.cmd`).
- *Hardware GPU scheduling*: currently **on** (RTX 4080). Nothing in his numbers says to change it, so it is "info" with an experiment:
  `tools\perf-hags-off.cmd` (+ UNDO) (or `-on` if it is off); it needs administrator approval once and a restart, Paddock marks the change
  and the "Did it help?" list answers it.
- *iRacing graphics (compared, never changed)*: against the settled setup. The first time the file matches the settled setup (frame limit 160,
  Reflex off, 4 mirrors at high detail, 2 pre-rendered frames) all 104 values are remembered in `data\perf-gfx-baseline.tsv`; later any
  difference is listed ("frame limit is 120 (settled: 160)") with "ask Claude to put it back". An iRacing update can reset these.
- *Memory*: hard page faults per second in the last sessions (Windows fetching memory from disk).
- *Connection* (only when there are online sessions), *NVIDIA graphics driver*, *Paddock's frame-rate sampler* cost.
The `perf-*.cmd` tools **are never run by Paddock or Claude**; the page only has "Show the file" (opens Explorer with it selected, only for names
`perf-*.cmd`, never while driving). Each saves what it changed (`data\perf-tools-state.tsv`) and logs to `tools\perf-tools.log`; the UNDO puts it back.
`perf-tools.ps1 -Tool <name> -Preview` only says what would change.
Deliberately **not** offered: pausing OneDrive from a script (Windows has no safe command; the page tells him to use the cloud icon), Defender
exclusions (a security trade-off: explained, not done).

### The priority trial (`PerfPrio`)
Only `irdashies` (the overlays) and the browser the dashboard runs in; never CrewChief, the sim or anything else. States in `data\perf-prio.tsv`:
*watch* (default; nothing lowered), *trial*, *kept*, *rejected*. It moves to *trial* only when Paddock and the overlays together use 50 % of a core
or more on average over the last measured drives (so there is something to gain). While on trial they run at BelowNormal while the sim runs and
are put back when it exits. After 3 comparable sessions on each side the "Did it help?" maths decides: kept only if it **helped**, otherwise it
is switched off and written down. To stop it ever being tried, put `mode<TAB>off` in `data\perf-prio.tsv`. Needs a measured 50 % of a core from Paddock + the overlays: the first live
reading (2026-10-10) showed the overlays alone using about 48 % of a core during a race, so the trial may well start by itself after a few measured drives.

## F5 Live (`/perf/live`)
`{"on":true,"track":..,"car":..,"field":..,"normal":104.2|null,"cause":"...","causeKind":"program|gpu|cpu|","gpu":52,"cpu":46,"sampler":true}`.
"Usual" = the median average of the last 8 counting sessions at this track, in this car, with a similar number of cars; fewer than 2 = null
(no amber line ever without history). Cause: the busiest non-sim program in the last 15 s if it uses 20 % of a core or more, else "the graphics
card is full" (GPU >= 92 %), else "the processor is full" (CPU >= 88 %), else nothing.

## F6 Proposal only: PresentMon (needs Peter's yes to download)
`FrameRate` is a 1-second average, so it cannot show single-frame stutter. Intel's PresentMon (MIT licence, free, one small .exe,
github.com/GameTechDev/PresentMon) logs every frame's time. Proposal: Peter says yes; Paddock downloads the console build into
`tools\presentmon\`, runs it only on request ("MEASURE STUTTER" while he is *not* racing, 2-minute test lap in Test Drive), and shows 1 % / 0.1 % lows
and a frame-time graph on the page. Nothing is downloaded or installed until he agrees.

## Endpoints (GET, localhost only)
`/perf` (everything the page reads), `/perf/session?file=<name>.ibt` (one session; names are looked up in `perf.tsv`, never used as a path),
`/perf/status` (counts, backfill state, sampler cost, priority trial), `/perf/live`, `/perf/checklist`, `/perf/summary`, `/perf/nav`,
`/perf/scan`. `/api/do?c=perf|perfclose|perfscan|perfshow&a=<perf-name.cmd>`. Test-only (need `dash\test-hook.on`, refused while a real session is
on): `/perf/test/drives`, `/perf/test/clear`, `/perf/test/prio`.

## Testing
`tests\perf-test.ps1` (rig free): the four real files against `fps-report.ps1`; backfill complete with no duplicates and a second pass adds nothing;
the JSON shapes; markers checked against a separate comparison of the backups; "did it help?" on made-up sessions through the compiled code
(helped, hurt, same, mixed, not enough, different car, alone vs a grid, short drives, merging); the checklist looks twice and a before/after
snapshot of iRacing's files, the registry switches, the power plan, tools, backups and `irdash.ini` proves nothing changed; the sampler with a stand-in
"sim" and a busy-loop program (what it found, what it cost, nothing written to disk under the test hook); the live figure and amber line in
the real dashboard page; the page picture. `-Offline` runs the parts that need no live app, no test hook and no window, reading old files at low priority.
Pictures: `tests\shots\perf-page.png`, `perf-page-narrow.png`, `perf-live-fps.png`, `perf-live-amber.png`, `perf-top-open.png`.
