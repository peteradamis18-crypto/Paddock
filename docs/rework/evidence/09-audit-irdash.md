# 09 - Audit of the irdash server (dash\src\*.cs)

Phase 1 evidence, read only. Nothing was built, run, deployed or changed except this file. Written 2026-11-13.
Scope: the 50 files in `dash\build.ps1`'s `$src` list plus `probe.cs`, about 40,000 lines of C# 5.
Method: I read `irdash.cs` (server, SDK reader, guards, watchdog) and the two bug leads myself. Three helper reviews read the
other files in full: video and replay, analysis and data, rig and performance. I checked their headline claims against the code
and the log. Those are marked **(checked)**. The rest are from reading code, not from running it.

Severity words:
- **breaks Peter**: can hurt a race, lose his files, or do something on his screens he did not ask for.
- **wrong data**: a number or verdict on screen is wrong.
- **fragile**: works today, but breaks easily or hides its own failures.
- **cleanup**: duplication, dead code or size. Nothing breaks.

---

## 1. The two known bugs from phase 1

### 1a. Best lap 1:33.639 (My Races) against 1:33.919 (Vault, Sessions), 12 Nov 09:28 Road Atlanta race (checked)

**Both numbers are wrong. The real best lap is 1:33.832 (lap 9).**

The evidence is in `dash\irdash.log` lines 2273-2298, `vault\saved\20261112-142807-road-atlanta.json` and `vault\sessions.tsv` row 541:
- Lap 3 was 1:33.919. iRacing counted it, and the log says "personal best reference updated ... 1:33.919".
- Lap 6 was 1:33.639. There was an incident (+1) at 09:40:02, inside that lap. iRacing did not count the lap: the live PB reference was **not** updated. The recorder still logged it as "clean - a personal best".
- Lap 9 was 1:33.832. iRacing counted it: the log says "personal best reference updated ... 1:33.832". The reference only updates when iRacing's own `LapBestLapTime` equals the lap (`refs.cs:381-394`).

**Why My Races says 1:33.639.**
- `recorder.cs:1811-1812` (`RacesJson`) takes the smallest lap time in `LapRows`, with no other test.
- `LapRows` come from `FinishSession` (`recorder.cs:~1425`) and are every `LapLastLapTime` the sim announced.
- The recorder's "clean" (`!Pit && !Off && !Dirty && time > 15`) never looks at incidents or at whether iRacing counted the lap, so the incident lap 6 wins.

**Why the Vault and Sessions say 1:33.919.**
- The Vault's best is the smallest lap that is `Time > 15 && !Pit && Counted` (`vault.cs:121-165`). "Counted" comes from `LapRules.Judge` (`analysis.cs:1138-1190`).
- `sessions.tsv` shows only 3 of the 10 laps counted: laps 3, 8 and 5. Lap 9 was rejected, and so were laps 2, 4, 7 and 10.
- The rule for a lap quicker than the previous best checks iRacing's `LapBestLapTime` only 1.5-2.5 s after the line (records end+90 to end+150, `analysis.cs:1155-1158`). If the channel updates later than that in the .ibt, a real PB lap is thrown out.
- A slower lap is counted only when it has **zero** off-track records. One wheel over the line for a single 1/60 s record drops the lap.
- Seven rejected laps out of ten in a clean race says the rule is too strict.

**How to confirm.** With the sim off, dump `LapBestLapTime`, `LapLastLapTime` and `PlayerTrackSurface` for the 600 records after each line crossing in `toyotagr86_roadatlanta full 2026-11-12 09-28-07.ibt`.

**Fix.**
- Use one lap-truth function for every page.
- Decide "counted" from the live frame: the recorder already sees `LapBestLapTime` change. Store `counted` per lap in the session sidecar.
- For old files, widen the .ibt window to about 4 s and take the lowest `LapBestLapTime` in that window.
- Stop treating one off-track record as fatal.
- Drop lap 0 and uncounted laps from `RacesJson`.

### 1b. The doctor's "Last session 160 fps" verdict was about the wrong file (checked)

The log at 09:47:52, one second after Peter left the car, says "Frame rate: Last session 160 fps average, 153 at the low end".
That is the row for `bmwz4gt3_nurburgring nordschleife 2026-11-11 21-36-21.ibt` (avg 160.3, low 152.6). The race's own row (avg 113.9, low 91.8, **worst 23.7**) was only written at 09:51:53.

Why it happened, in order:
1. `perf.cs:530` (`PerfReports.Pass`) does nothing while the sim process exists. None of the morning's .ibt files had a report yet.
2. `doctor.cs:83-87` (`Doctor.Tick`) runs a full check the first moment `IsDriving` turns false, if the last run was over 30 minutes ago. That was 09:47:52, with the sim still connected until 09:47:56.
3. `perf.cs:135-143` (`Perf.Summary`) returns `PerfJson.LastRow(PerfStore.All())`, the newest row that already exists. It never checks whether newer files are waiting (`SimBusy`, `Pending`, the newest .ibt, or the 5 s sampler's own "drive over - 114 fps" figure). The sentence names no track or date, so a stale row looks current.
4. Even after the sim closed, the 120 s file-age rule (`perf.cs:539`) held the race file for about 4 more minutes.

The verdict also cannot see a freeze:
- It uses the average and the 1 % low of the 1-second `FrameRate` channel (`perf.cs:402-416`). "Worst" is stored but never used in the sentence.
- "Held its limit" compares the average with the **highest sample** (`cap = max`, `perf.cs:404`), so one menu spike sets the "limit".

Fix:
- `Summary()` says "latest session still being processed" when any file or sampler drive is newer than the row.
- Put track, date and the worst second (with its lap) in the sentence.
- Don't run the periodic doctor while `Connected`.
- Take the fps cap from the sim's own setting.

---

## 2. Findings by file

### irdash.cs (3,126 lines: SDK reader, HTTP server, track maps, watchdog, career cache, friends, guards, Program)

| Sev | Lines | Finding | Fix |
|---|---|---|---|
| breaks Peter | 1140-1143, 1252-1254 | `TrackMaps.ActiveIbt` runs `Process.GetProcessesByName` once per .ibt file (about 590 files) every time a map build runs. A build is triggered by a `/trackmap` request at session start on a track with no telemetry map, with no driving gate. On top, it opens the header of every .ibt it has not seen. (checked) | Look up the sim once per build. Don't build while `Connected`. |
| breaks Peter | 2766-2783, 2990-3000 | The guard timer runs on the **UI thread**, the same thread as the 33 ms delta-bar timer. Every 2 s it runs `PlaceSim`, `KeepDash` (enumerates every chrome/msedge process and reads `MainWindowTitle`), `Watch.Tick` (3+ process scans, a Stream Deck log-tail read, sometimes a WMI query), `Doctor.Tick`, `SimPriority.Tick` and `Guest.Tick`. One slow tick freezes the delta bar. | Move the checks to a background thread and post only the window moves to the UI. |
| breaks Peter | 2990-3000, 3009-3022 | While driving, `RaiseOverlays` re-sets TOPMOST on every irdashies window every 5 s (`EnumWindows` + `SetWindowPos`). `OverTaskbar` flips the sim and dashboard windows to TOPMOST the moment he gets in the car. These are z-order changes on his screens during a session, and they are not tested. Low but real stutter suspect: a z-order change makes the desktop compositor redo work. | Raise once when driving starts, then only when a check sees an overlay below the sim. |
| breaks Peter | 1655-1705 | The Stream Deck restart (kill and start) after a USB blip or a wake has no driving check. CLAUDE.md rule 1 says no app restarts during a session. | Decide with Peter. Probably allow it (the deck is his controls), but log it as "restarted during a session" and test it. |
| fragile | 1641-1645, 1703 | `DeckPresent()` is a WMI `Win32_PnPEntity` query on the UI thread. It runs every 2 s whenever the Stream Deck log tail is not clearly "connected". WMI calls can take 50-300 ms and wake WmiPrvSE. | Cache it for 30 s and run it off the UI thread. |
| fragile | 82-98 | `Log.W` **deletes** irdash.log when it passes 2 MB (all history gone). It writes synchronously from every thread, including the lap-crossing thread and the UI thread. All errors inside it are swallowed. | Roll the log to `irdash.1.log`, and write through one background queue. |
| fragile | 137-152, 495-497, 2600, 2608-2611 | Seven different "is he busy" tests: `IsDriving` (IsOnTrack only), `CarMoving`, `RealBusy` (connected, sim process, START mark), `Sdk.Latest.Connected`, `GetProcessesByName("iRacingSim64DX11")` inline (many files), `Busy()` in official, `BusyWhy` by reflection in realworld. Each file picked one. Several that click or launch use only `IsDriving`, which is false in the garage (see mydrive, ailevel, spotterguard below). | One `RigState` with three answers: `Driving`, `SessionOn`, `SimRunning`, updated by the SDK thread. |
| fragile | 457-468 | One new thread per HTTP connection with no limit. Each `/stream` client holds a thread forever. Each page polls several routes. | Thread pool or a fixed set of workers. Keep `/stream` on its own thread. |
| fragile | 2000-2027 (Career) | A file written in the last 30 s is skipped, but `lastCount` is still set to `files.Length`. The "count changed" rescan never fires again, so a just-finished session is missing from HOME, Sessions and "last" until the next .ibt appears or irdash restarts. | Count only the files actually read, or rescan on mtime. |
| wrong data | 2004-2027 (Career) | The cache key is `name|length`. A file read while the sim was up in the garage, which then grows, gets a second row. The partial row is never removed, so the session counts twice in hours, laps and km. | Key on name, replace the row when the length changes. |
| wrong data | 2121-2145 (Career) | When `CountedBest` throws or returns -1, best falls back to the quickest announced lap, including pit laps and off-tracks. That is a different "best" again. | One lap-truth module (section 4). |
| fragile | 2153 | `Career.Json()` runs `Directory.GetFiles` under `gate` on every `/career` poll. | Use the scan's own list. |
| fragile | 495-498 | `/deck/state` is answered **before** the phone gate, so a LAN client gets it without a token (when LAN listening is on). It also does 2 process scans per call. | Move it after the gate and use `RigState`. |
| fragile | 600-606 | `/api/do` is a chain of 15+ `Handles()`/`Do()` pairs. One command name could be claimed by two modules (first wins). Special cases are patched in (`tvview` refused, `vault` renamed to `vkopen`). | A single command table: name, module, "allowed while driving", "allowed from phone". |
| fragile | 536-541 (with phone.cs) | Every `/api/*` action is a GET with `Access-Control-Allow-Origin: *`. The Host check stops DNS rebinding but not a web page's blind `fetch('http://localhost:8199/api/do?c=...')`. | Require a custom header (`X-Paddock: 1`) on state-changing routes, or check `Origin`. |
| fragile | 2639-2650 | `CentreScreen()` finds the screens by position (good), but `PickScreen` still honours `cfg.Screen` by `\\.\DISPLAYn` name if set. | Drop the name option. |
| fragile | 2683-2692 | Port-bind failure shows a `MessageBox`. If that happens at logon while the sim starts, a popup lands on his screens. | Tray balloon or HOME message, not a modal box. |
| fragile | (no line) | No `AppDomain.UnhandledException` handler anywhere in dash\src (grep). One exception on a bare `new Thread` (ac.cs, recaudio.cs and others) ends irdash with no log line. | Add one handler that logs and keeps the tray alive. |
| cleanup | 414-438, 1765 | Two JSON escapers (`Json.Str`, `Json_.S`) plus `Js` in realworld and others. JSON is built by hand in every file (as CLAUDE.md asks). | Keep hand JSON, but have one small `JsonWriter` with `Str`/`Num`/`Arr`. |
| cleanup | 1022-1535 | `TrackMaps` holds the only shared .ibt header parser (`OpenIbt`, 1172). Every other file has its own record decoder. | Make it the `IbtFile` module (section 4). |
| cleanup | 1770-1900 | `TvView` and `/tv` stay in although the TV view is turned off (`tv_view=0`, and `tvview` is refused at line 603). | Remove, or move to the TV rewrite. |
| cleanup | 841-870 | `PUT /maps/<name>.json` writes a track map. Nothing calls it. | Remove. |
| cleanup | whole file | One file holds 12 classes: Native, Log, Sdk, Json, Server, TrackMaps, Watch, TvView, Career, Guest, Showcase, Systems, Program. | Split per section 4. |

### recorder.cs (2,200 lines)

| Sev | Lines | Finding | Fix |
|---|---|---|---|
| breaks Peter | 353-680, 831-1039 | Work at each lap crossing during the race. On the BelowNormal Loop thread it runs `FinishLap`, `Decide` and a synchronous log write. 1-11 s later the worker cuts the clip: ffprobe over a segment, audio PCM build, ffmpeg copy and an AAC encode, writing 87-94 MB. This happened at laps 1, 2, 3, 6 and 9 of the stutter race, and at lap 9 right in the freeze window. BelowNormal lowers CPU priority only, **not disk priority**. | Cut PB clips after the session from the whole-session file, or run the cut at background I/O priority. |
| breaks Peter | 675, 1728, 1881 | `Housekeeping` every 5 s on the Loop thread runs `RetainSessions` (deletes multi-GB videos), `SyncExports`, `PruneSegs` and `PruneAudio`. It is not gated on driving. Log: "removed the oldest unsaved session" at 09:48:15, right after the race. | Housekeeping only while `!SessionOn`, on its own thread. |
| breaks Peter | 1297-1351 | `FinishSession` (about 1.1 GB concat, AAC encode of the whole session, retention deletes) starts the moment a session ends. With practice, qualifying and race in one visit, it runs while he drives the next session. | Queue it until `!SessionOn` plus a grace period. |
| breaks Peter | 1728 (+ 1802) | `SyncExports` deletes a race when its file in `Videos\Paddock` disappears and the hard-link count is 1. It runs on every `/api/rec/races` call and every 5 s. Renaming or moving the exported file (to title it for YouTube), or a briefly missing Videos folder (OneDrive), deletes the race. | Never delete on a missing export. Mark it "export missing" and ask. |
| fragile | 2106-2114 | `TestOff()` sets `keepSessions = 3`, while the real default is 8 (line 234). It also clears the clip list. After any recorder test on the live irdash, retention keeps only 3 unsaved sessions and deletes the rest, until irdash restarts. (checked) | Restore the real defaults and reload clips. |
| fragile | 1039, 1324-1351 | There is one FIFO worker. `FinishSession` sleep-polls for up to 120 s while the probes and cuts that would unblock it wait behind it. It can only time out (`FinishStalled`), then retry 60 s later. | Wait on events, or use a separate worker for the finish. |
| wrong data | 1425, 1811 | `LapRows` include lap 0 (the formation lap, 3:40.946). The `laps` count is `LapRows.Count`, so a 10-lap race says 11. Best has no counted or incident filter (see 1a). | Store `counted`. Skip lap 0. |
| wrong data | 1436 and the RunCut `pb` flag | `pb` compares with the reference at the lap's end and ignores iRacing's counted rule. Laps 6 and 9 were both marked `pb:true`, and lap 6 was not a real PB. | Use the same counted flag. |
| wrong data | 934 | `RunCut` writes a blank encoder name once the run has ended. | Use `first.Enc`. |
| fragile | 850, 2001 | `RunCut` and `RunIncident` are about 60 near-identical lines. Magic numbers: 20 s before and 10 s after, ±1 s, 10 s segments, 180000 ms timeouts, 0.004. | One cut function with (start, end, id, meta). |
| cleanup | ~324 | `Recorder.Enabled` has no callers. `InfoJson` is used once. | Remove. |
| cleanup | whole file | God class: DXGI capture, job object, ffmpeg, lap detector, cuts, session files, retention, exports, incidents, recovery and test routes. The lap detector duplicates the live PB logic in refs.cs. | Split per section 4. |

### recaudio.cs (575)

| Sev | Lines | Finding | Fix |
|---|---|---|---|
| fragile | 222 | `Process.GetProcesses()` every 5 s while recording. About 200 Process objects, never disposed. | Look up only the sim and CrewChief by name, and dispose. |
| fragile | 115 | `Stop()` joins for 4 s and is called on the recorder's Loop thread, so the lap tracker can stall. | Signal, and join on a background task. |
| fragile | 138-179 area | Capture runs on a bare thread with no try/catch around `Process`/COM calls, and there is no global handler. | Wrap. |
| cleanup | | `LastError`, `LastRunState` have no callers. The `refused` dictionary is never cleared. | Remove. |

### vault.cs (2,455)

Note: `irdash.ini` has `vault=1`, `official=1` and `recorder=1`. `docs\ARCHITECTURE.md` still says vault and official are 0 and "not part of what Peter uses". That is out of date.

| Sev | Lines | Finding | Fix |
|---|---|---|---|
| breaks Peter | 838-870, 1325-1420 | `EnsureCopy`, `AttachClip` and `LinkClips` copy 45-78 MB videos and parse .ibt files while holding `lock(gate)`. Every `/vault*` request waits behind them. | Do the work outside the lock, publish under it. |
| breaks Peter | 901-940, 1589-1700 | `StatusJson` holds `gate` while it walks the whole vault tree (`UsedBytes`), the process list (`Nv`) and the registry, plus a recursive `*.exe` search (`Cosworth`). It runs on every status poll, including while driving. `Prune` recounts the tree once per item it removes. | Cache sizes for 60 s. Recount once. |
| fragile | 1181-1184, 1564-1565, 1726 | Routes that change files have no driving check: `/api/rec/backfill` (save and export every race), `/api/rec/delete`, `/api/rec/save`, `recsave`, `racedelete`, and `EditRoute star=1` (a 78 MB copy). | One driving guard at the top of every changing route. |
| fragile | 1238, 1257, 367 | `KeepPress` and `ClipPress` call `SaveAll()`, which rewrites 7 files (moments.json, sessions.tsv, marks.tsv, pins, deleted.txt, clips-seen.tsv, settings.json) mid-lap. | Append one line now, save the rest after the session. |
| fragile | 1455 | `static uint mvScale` in `VaultMp4` is shared between threads. | Pass it as a parameter. |
| fragile | 830 | `FileForId` reads `moments` without the lock. | Take the lock. |
| fragile | 1539 | The recorder's routes (`/api/rec/*`, the deck's RACES list) are gated by `Vault.Serving`. Turning the Vault off kills RACES. | Route the recorder separately. |
| wrong data | 121-165 | The Vault best uses the over-strict `Counted` rule (see 1a). | One lap-truth module. |
| fragile | 410-430 | The worker scans every 20 s, with magic 4000/20000/30000 ms. There are dozens of `catch { }` (for example 1336, 2160, 2370). | Log what is swallowed. |
| fragile | 2065, 2135 | `SessionSidecars` re-parses every session JSON every 30 s. `FrameMap` runs `FrameSource` for every moment on `/vault/list`. | One index, rebuilt on change. |
| cleanup | 276, ~190-215, 1525, 2160 | Duplicates: the 4th ini reader (`ReadIni`), the 3rd YAML DriverInfo parser, the 2nd HTTP reply helper, and the 3rd ffmpeg runner (`MakeFrame`). | Shared helpers. |
| cleanup | 1788-1980, 1234-1284 | About 200 lines of Cosworth/Pi launcher. The NVIDIA ShadowPlay hotkey clip path (`ClipPress`, `Nv`, `SendHotkey`) is legacy next to Paddock's own recorder. `Vault.Enabled` has no callers. | Drop the NVIDIA path. Move Cosworth to its own small file or drop it (phase-1 06 says the button over-promises). |
| cleanup | whole file | God class: .ibt reader, moment rules, telemetry copy, budget, NVIDIA clips, mp4 box parser, HTTP, Cosworth, frames, thumbnails, test routes. | Split per section 4. |

### share.cs (860), sessmatch.cs (90), replay.cs (790), replayjump.cs (81), gallery.cs (1,107), tv.cs (147)

| Sev | File:lines | Finding | Fix |
|---|---|---|---|
| breaks Peter | tv.cs:33 | The TV worker rebuilds every 100 ms for the whole session, whether anyone is listening or not. Each pass re-parses the session YAML with regexes: about 300 regex matches per 0.1 s for a 40-car field. The TV view is switched off. | Parse once per `SessionVersion`. Build only when `/tv/data` was asked for in the last 5 s. Or remove it. |
| fragile | share.cs:546 | `/share/make` (a GPU render) is allowed from a paired phone. Only `open` and `jump` are local-only. | Local only. |
| fragile | share.cs:649, 686 | `Allowed()` checks processes every 32 frames. `busySince` starts at class load. Process objects are not disposed. | Use `RigState`. |
| wrong data | share.cs (ShareCollect) | It picks the lap by `lap.Clean` and rejects a mismatch over 0.5 s against the clip. If the recorder and the Vault disagree on laps, a share is refused. | One lap-truth module. |
| cleanup | share.cs:69, 113-251, 371, ~520 | Duplicates: the 2nd file-name date regex, the 2nd .ibt record reader, the 2nd lap-time formatter, the 3rd HTTP reply helper. | Shared helpers. |
| fragile | replay.cs:689 | `ReplaysJson` does a recursive `GetFiles("*.rpy")` while holding `gate`, which every replay key press also needs. It re-runs every 20 s while polled. | Scan outside the lock, cache. |
| fragile | replay.cs:637 | `PhotoWork` sends replay broadcasts with no driving re-check after the first 500 ms. Its paths are hard-coded. | Re-check before each send. |
| cleanup | replay.cs, tv.cs, vault.cs, Combo | Five copies of the YAML `Section`/`Val` helpers. | One session-info cache. |
| fragile | gallery.cs:407-423 | `IniGet` re-reads irdash.ini once per key (5 reads on load). `Save` writes irdash.ini with no driving check (small). | Shared `Config`. |
| fragile | gallery.cs:633 | `Scan()` runs on the UI thread every 30 s when the gallery is idle, opening every picture header. The `MeasureAll` thread can outlive the sim starting. | Background thread, stop when the sim starts. |
| fragile | gallery.cs (FindSides) | Hard-coded "3 screens, 2560x1440, dashboard above". It fails closed, which is good. `FindSides` repeats the recorder's `RecDxgi.Middle` rule. | One `Screens` helper. |
| ok | replayjump.cs, sessmatch.cs | Small, pure, gated (`JumpRoute` returns 409 while driving). `sessmatch.SameName`/`Alnum` are a second name-matching rule next to `Combo.Key`. | Keep. |

### analysis.cs (1,191), data.cs (956), career.cs (729), gain.cs (234), refs.cs (523), bench.cs (541)

| Sev | File:lines | Finding | Fix |
|---|---|---|---|
| breaks Peter | analysis.cs:248-252 | `LoadCorners` reads the Lovely file even when it is not on disk. For a track Lovely lists but that is not downloaded, Session Review, workbench, deep dive and Career all answer 500. | Use the file only if it exists. |
| wrong data | analysis.cs:1138-1190 | `LapRules.Judge` is too strict (see 1a). Its `LapBestLapTime` window is 1.5-2.5 s, and a single off-track record kills a lap. | Fix it once, in the lap-truth module. |
| wrong data | analysis.cs:33-34, 255 | `cornerCache` caches an empty corner set while corners are still being built, and never invalidates it. Corners stay missing until restart. | Don't cache empty, key on mtime. |
| fragile | analysis.cs:582-588 | `Measure` publishes `lap.Corners` before filling it. Shared `LapTrace` objects, no lock. | Build locally, publish last. |
| wrong data | analysis.cs:904-932 | `Gather` stops after 40 matching files, so "PB" and "previous best" in lap analysis, Session Review and Coach cover only the newest 40 files. Career and HOME use all files, so the numbers differ. | Use the session index. |
| fragile | analysis.cs:886-915 | `Gather` opens the header of every .ibt on every request, and its sort calls `GetLastWriteTimeUtc` O(n log n) times. One debrief runs it 4+ times. | Session index. |
| wrong data | analysis.cs:1125-1136 | `CountedBest` loads a whole file (about 74 MB) uncached and returns -1 on any error, which triggers the rough fallback in irdash.cs:2121. | Lap-truth module, cached. |
| fragile | analysis.cs:411, 426 | Magic numbers: 45 off-track records, and the official time read 90 records after the line. corners.cs uses 40. If the next run is shorter than 90 records, the lap loses its official time and drops out of every "best". | One constant set. |
| fragile | analysis.cs | `LapRules.Version` (3), `CrVersion` (5), `Rec.Rules`, `RefData.Rules`, `VSession.Rules` are separate version numbers that must all be bumped by hand, or old caches keep an old "best". | One rules version. |
| wrong data | data.cs:521-534 | `IbtLaps.Get` holds `gate` while it loads a whole file. Every other caller (PB build, `/ibt/lap`, `/pbref`) waits. | Load outside the lock. |
| wrong data | data.cs:614-639 | `IbtLaps.Segment` keeps laps without an official time. `LapsJson.best` falls back to the quickest non-pit lap when none counted, so the Vault card and the lap list can disagree. | Lap-truth module. |
| wrong data | data.cs:334-368 | `BriefJson` includes short runs and matches layouts loosely, while Sessions does not. `LatestIr` uses file mtime as "newest". | Session index. |
| fragile | data.cs:266-272 | `SessionsJson` lists the telemetry folder under the Career lock. | Session index. |
| fragile | career.cs:469, gain.cs:59, 129-133 | The career job and the gain job can compute the same file at once, and both write the same `.json.tmp`. | One job queue. |
| fragile | career.cs:55-56, 261 | `CrFile` is cached on ticks, size and version only, and a stale JSON on disk is trusted. | Add mtime. |
| wrong data | career.cs:270-273 | "Seconds" means three different things: Career sums run lengths, Sessions samples `IsOnTrack` at 1 Hz, and the Vault uses file length. | One definition. |
| fragile | gain.cs:44-62 | `GainPoke(now)` from `/analysis/gain` skips the `Connected` check and can start the whole career scan with the sim in the garage. `/mydrive` (polled every 1.2 s) pokes it too. Its statics have no lock. | `RigState.SessionOn` gate, lock. |
| wrong data | gain.cs | MOST TO GAIN joins sectors from different days (phase-1 06). | Show the dates. |
| fragile | refs.cs:395-405 | `Adopt` writes `dash\refs\<combo>.json` at the lap line during the race (small file, but a write in a session). | Write after the session. |
| fragile | refs.cs:447-465 | `OnCombo` builds the reference when the session loads (garage, connected): up to 6 .ibt files at about 74 MB each, holding the `IbtLaps` lock. It waits only on `IsDriving`. | Build between sessions. |
| fragile | refs.cs:378-395 | `CheckPending` misses a PB if the sim updates `LapLastLapTime` in the same frame as the lap counter. | Compare with the last lap seen, not the previous frame. |
| fragile | bench.cs:57-63, 220-270 | `FieldLaps`: a Lowest-priority thread lists the telemetry folder every 10 min. During a multi-car session it regex-parses the whole session YAML every 30 s and appends to `fieldlaps.tsv`. The log shows a line every 30 s through the stutter race. | Read the drivers once per SessionVersion, write after the session. |
| wrong data | bench.cs:207-232 | `ScanFile` marks a file as done after one read, so a file read while still growing is never re-read. | Key on length. |
| cleanup | analysis.cs:134-198 | Test command lines (`--career`, `--gain`, `--pro`, `--rigwin`, `--gpsmap`) ship in the product. | Separate test exe or `#if TEST`. |

### corners.cs (1,159), deepdive.cs (1,108), field.cs (1,102), debrief.cs (964), coach.cs (381), workbench.cs (381), sessionreview.cs (358), partial.cs (206), rawdata.cs (375), gpsmap.cs (399), home.cs (386), cars.cs (210)

| Sev | File:lines | Finding | Fix |
|---|---|---|---|
| wrong data | corners.cs:851-929 | `ReadBestLap` (corner detection) is a 3rd lap splitter. It uses no `LapRules` and a 40-record off-track limit, so it can use a lap iRacing did not count. | Lap-truth module. |
| fragile | corners.cs:594-628 | `Resolve` calls `FetchLater`, a GitHub download, from HTTP threads. It waits up to 30 minutes for a quiet moment and gives up silently. | One download queue, logged. |
| cleanup | corners.cs:1084+ | `DetectLibrary` is never called. `AuditJson` hard-codes the iRacing install path. | Remove. |
| wrong data | deepdive.cs:714-731 | Stint "best" uses `Clean`, not `Counted`. | Lap-truth module. |
| wrong data | deepdive.cs:278-292 vs gpsmap.cs:112 | Two lat/lon-to-metres scales (111195 against 111320/110540), so line offsets and the GPS map disagree by up to 0.6 %. | One geo helper. |
| fragile | deepdive.cs:211-896 | Four more ad-hoc .ibt readers with different record caps (400k, 800k, 2M). `ReadSessionChannels` can silently cut a long file short. | `IbtFile`. |
| cleanup | deepdive.cs | About 150 lines of per-car constants (`CarTable`) hand-written in code. | A data file. |
| wrong data | field.cs:266-273 | The race page's "his best" is iRacing's `ResultsPositions.FastestTime`, then `CarIdxBestLapTime`, then the logged minimum. That is a 4th best-lap definition. | Lap-truth module (it can keep iRacing's number as "official"). |
| wrong data | field.cs:1030-1102 | `RaceRoute`/`WindowOf` matches a field log to a file by ±2 min time overlap using the name stamp and mtime. A multi-session file can get the practice log. A touched mtime gets none. | Match on `SessionUniqueID`, as `debrief.cs:589` already does. |
| fragile | field.cs:1062-1076 | `Files()` re-lists and re-parses changed field logs under `gate` on the HTTP thread. | Index. |
| fragile | debrief.cs:270-300, 468-500 | Debrief calls `SessionRoute` and `Route`, turns the result into JSON, then parses it back. One debrief means 4+ `Gather` scans and 3 full file loads. | Call the builders directly. |
| fragile | debrief.cs (CvLoop/CvTool) | Runs ffmpeg cuts whenever `!IsDriving`, which includes the garage with the sim up. | Gate on `!SessionOn`. |
| wrong data | coach.cs:51-76 | The coach's reference is the quickest Pure lap, else the quickest Clean lap, not necessarily counted. | Lap-truth module. |
| fragile | coach.cs:26-35, 258-269 | No BelowNormal. A full `RawLoad` plus `Gather` run 3 times per request. | Lower priority, session index. |
| wrong data | sessionreview.cs:56-66 | `NewestTelemetry` means "newest .ibt by write time". After a race, a fresh garage file, a Test Drive or a OneDrive-touched file wins. vault.cs:1937-1946 `OpenTarget("last")` is a copy of the same rule. | One `LastSession()` by start time, with laps. |
| fragile | partial.cs:23-34 | Two threads can build the same view, and each call re-reads the whole file. | Lock per id. |
| fragile | rawdata.cs:78-86 | `StillWriting` only refuses the newest file, so an older file that is still open (multi-session) is read. | `IbtFile.IsFinished`. |
| fragile | workbench.cs:135-216 | `LapChannels` reopens the file for each lap and silently returns zeros past 400k records. | `IbtFile`. |
| wrong data | gpsmap.cs:213-260 | The GPS sidecar is built once from the quickest Clean lap among the newest 4 files, and a bad first pick is frozen forever. | Rebuild when a better lap exists. |
| fragile | gpsmap.cs:147-170, cars.cs:59-66 | JSON parsed with regexes that depend on key order. They fail silently. | Tiny real JSON reader (`JavaScriptSerializer` is already used in sound.cs). |
| wrong data | home.cs:36-47 | HOME's "PB here" is the best of Track+Config across **all cars**, so it can show another car's lap. | Key on car too. |
| fragile | home.cs:77-142 | `HomeJson` reads a telemetry header inside `lock(gate)`. `TestRuns` can hide real sessions if a test marker is left over. | Read outside the lock. Expire markers. |
| cleanup | cars.cs | `tried` is never cleared, so a failed picture is never retried until restart. | Retry daily. |

### perf.cs (2,192), doctor.cs (834)

| Sev | File:lines | Finding | Fix |
|---|---|---|---|
| wrong data | perf.cs:135-143, 530, 539; doctor.cs:83-87 | Wrong-session verdict (see 1b). (checked) | As in 1b. |
| wrong data | perf.cs:402-416, 485-494 | The verdict ignores the worst second and dips. "Held" is measured against the highest sample. The sentence has no track or date. | As in 1b. |
| wrong data | perf.cs:241, 347 | If the header time is bad, Start falls back to `CreationTimeUtc`, and a copy or restore then becomes "last". | Header time, then file-name time. |
| fragile | perf.cs:975, 1720, 1744 | `StatusJson` reads lists without the lock. `/perf/status` lists about 590 .ibt files on every call, and `Overview()` calls it again. | Cache. |
| fragile | perf.cs:2095-2116 | `PerfPrio.Lower`/`Maintain` change the priority of irdashies and the dashboard browser every 5 s during a session, mode kept in `perf-prio.tsv`. This is an experiment still running on his race PC. | Confirm with Peter. If kept, set it once at session start. |
| fragile | perf.cs:~800-845 | The process sampler (5 s, BelowNormal) runs `Process.GetProcesses()` plus `TotalProcessorTime` on every process. The log measured 4.9-7.8 ms per tick. Processes it cannot read are skipped silently (`catch{}`). It keeps only a per-drive average, which is why the stutter's cause is unknown (phase-1 05). | Keep it cheap, but write per-second rows for the black box (phase-1 05). |
| cleanup | perf.cs:1215-1224, 1263-1374, 1953; doctor.cs:336, 402-425 | Three parsers of `[Graphics Options]` (perf diff, `PerfCheck.Graphics`, `Doctor.CheckGraphics`), plus two more ini readers. | One `SimSettings` reader. |
| cleanup | perf.cs:2132-2190 | `PerfTest` and `SetNamed` are test code in the product. | `#if TEST`. |
| breaks Peter | doctor.cs:38-45, irdash.cs:701, overlays.cs:66 | `Doctor.Run()` has no session check. A deck "doctor" press or `/api/doctor/run` during a race runs every check, including starting `probe.exe` through Explorer (line 293) and telemetry folder scans. Fixes can start CrewChief or overlays. | Refuse fixes while `SessionOn`. Show the cached result. |
| fragile | doctor.cs:76-82 | Every 20 s, even while driving, it runs `ClearStrayDialogs` (EnumWindows plus a process lookup per dialog) and `TunerBox.HideNow` (hides a window on his screens). Small, but it changes windows during a session. | Once at session start. |
| fragile | doctor.cs:153, 211-247; spotterguard.cs:15, 42, 70 | Both the doctor and SpotterGuard can start CrewChief. Each has its own hard-coded path, so two copies can start within seconds of each other. | One owner for CrewChief. |
| fragile | doctor.cs:214-236 | Fixes block the doctor thread for up to 50-60 s, and the screen shows "Checking the rig" all that time. | Report per step. |
| fragile | doctor.cs:263, 729, 753 and others | `"iRacingSim64DX11"` is written out in about 15 places, while tests override `SimPriority.ProcName`, so the copies can disagree. | One constant in `RigState`. |
| fragile | doctor.cs:508-524, rigwin.cs:128 | `stray-owner.txt` and `tuner-owner.txt` are test back doors that tell product code which windows to close or hide. | Test hook only. |
| cleanup | doctor.cs:646-833 | `Timings` lives inside doctor.cs, and its startup trim rewrites the whole file. | Own file. |

### deltabar.cs (491), wheel.cs (616), spot.cs (161), spotcore.cs (148), keymsg.cs (56), deckfeed.cs (93), deckwatch.cs (39), rigwin.cs (218)

| Sev | File:lines | Finding | Fix |
|---|---|---|---|
| fragile | deltabar.cs:119, 271-291 | The 33 ms UI-thread timer also runs `PbRef.Tick` and `FieldLaps.Tick`, so lap-file work lands on the UI thread. It repaints whenever the delta's milliseconds change (up to 30 Hz): a GDI+ 58 px `DrawString` plus `UpdateLayeredWindow` plus a screen query each time. | Move the ticks off the UI thread. Repaint on a 10 ms change, at most 20 Hz. |
| fragile | deltabar.cs:123-137, 207, 363 | `IniHas` re-reads irdash.ini. `Save` rewrites irdash.ini when a deck key is pressed mid-session. It runs its own sim-process lookup every 5 s. | `Config`, `RigState`. |
| fragile | wheel.cs:270-293, 519-526 | A 40 ms loop for the whole session. Once a button is taught, it polls all 16 joystick ids every loop (400 calls a second). | Poll only the taught id, slower when not needed. |
| fragile | wheel.cs:342-455, 175-183 | `Pump()` runs from both the wheel thread and an HTTP thread, and both can read the newest .ibt at once. Its statics have no lock. | Lock, one caller. |
| wrong data | spot.cs:49-61 | A saved spot survives a track or session change while the sim stays connected. | Clear on `SessionVersion` or track change. |
| fragile | spot.cs:32-43 | Consumes every telemetry frame (60 Hz) all session, even outside Test Drive. | Idle until a spot is saved. |
| fragile | deckfeed.cs:82-86 | A synchronous `WebClient` call to its own server with no timeout (100 s default) on the `/api/do` thread. An env var can redirect it. | Call the code directly. |
| fragile | rigwin.cs:46-55, 156-183 | Process objects never disposed. `TunerBox` hides a window during a session every 20 s. | Dispose. Once per session. |
| ok | spotcore.cs, deckwatch.cs, keymsg.cs | Pure and tested. | Keep. |

### mydrive.cs (535), overlays.cs (301), ailevel.cs (148), sound.cs (106), ac.cs (243), spotterguard.cs (90)

| Sev | File:lines | Finding | Fix |
|---|---|---|---|
| breaks Peter | mydrive.cs:123-129 | `mdfindcar`, `mdfindtrack`, `mdfindlayout` and `mdstart` run irdeck's **iRacing UI automation (clicks)** when `!IsDriving`. That is true in the garage with a session connected. CLAUDE.md rule 1 says `telemetry=on` means wait. | Gate on `!SessionOn`. |
| breaks Peter | ailevel.cs:100-111 | `Start()` launches `irdeck airace start` (UI automation) with no driving or session check, and never waits on or disposes the process. | Gate, and use the shared irdeck runner. |
| breaks Peter | overlays.cs:187 | `CarMoving` (`IsOnTrack && Speed>1`) allows `ovl apply` to restart irdashies while he sits still in the pit box with the session live. | Only when `!SessionOn`, or in the garage. |
| fragile | spotterguard.cs:35-68 | Every 2 s, 1-2 process scans, never disposed (about 43,000 undisposed arrays a day). It can launch or kill CrewChief while connected in the garage (it uses `IsDriving` only). | `RigState`, dispose. |
| fragile | mydrive.cs:477-533 (+ mydrive.js:10) | The top screen polls `/mydrive` every 1.2 s **even while driving**. Each call reads 4 files, parses JSON and runs `GainPoke`. | Cache by file stamps, and slow down while driving. |
| fragile | overlays.cs:42, 287 | A 500 ms timer reads state.ini all session (it can overlap itself). `/overlays` does a process scan per poll. | File watcher, cache. |
| fragile | ac.cs:46-92 | Every 120 s, **including in a race**, it spawns `python.exe` (BelowNormal, no CPU-core limit) for a TLS call to the air-con cloud that takes 7-30 s, while holding a lock. A suspect for small hitches; not measured. | Skip while driving, or measure it first. |
| breaks Peter | ac.cs:138, 179 | `new Thread(... RunPy ...)` and `Send()` have no try/catch. With no global handler, a `Process.Start` failure ends irdash. | Wrap. |
| fragile | ac.cs:150, 231 | `double.Parse` on missing or bad values throws. | `TryParse`. |
| cleanup | mydrive.cs:36-84, overlays.cs, sound.cs:56-84, official.cs (RunIrdeck), ailevel.cs | Five copies of the "run irdeck one at a time" queue. | One `IrdeckRunner`. |
| cleanup | mydrive.cs:148-158 and overlays.cs:103-113 | Identical `State()` ini readers. | `Config`. |

### official.cs (892), officialcore.cs (735), realworld.cs (749), coverage.cs (113)

| Sev | File:lines | Finding | Fix |
|---|---|---|---|
| breaks Peter | official.cs:202-209, 580-604 | `EnsureData` → `BuildOwned` runs a recursive `GetFiles(cars, "*.dat")` over the iRacing install, under `lock(gate)`. It is called from `/home` (polled every 5 s) and `/official`, with no driving gate. It reruns every 6 h, so it can land mid-race and block `/home`. | Build only in the loop when idle. |
| fragile | realworld.cs:2, 91 | The header says "No live HTTP unless AllowLive (Peter's yes)", but `Init` sets `AllowLive = true` always. It fetches third-party sites every 6 h with a spoofed Chrome user agent. (checked) | Confirm with Peter. Gate on a written yes, like `autodownload`. |
| cleanup | realworld.cs:44-48, 181-196, 261-545, 663-747 | The preview and cost machinery and 9 parsers (`ParseOpenF1`, `ParseImsa`, `ParseWec`, `ParseGtwc*`, `ParseSro`, `ParseWecProgram`, `ParseTable`) are only used by tests. The live list uses `ParseF1` and `ParseIcs`. | Remove. |
| wrong data | officialcore.cs:235, 244 | The HTML-entity `Replace` calls are no-ops (the entity text got lost), so `&amp;` and others stay in series and track names. | `WebUtility.HtmlDecode`. |
| fragile | official.cs:449-461 | Hard-coded 2026 special events go stale after 20 Dec 2026. | Data file. |
| fragile | official.cs:93, realworld.cs:62 | They call `Sdk.RealBusy` through reflection so an offline test compiles. | `RigState` interface. |
| cleanup | official.cs:535-652, mydrive.cs:196-368 | Four parsers of career-cache.tsv with hard-coded column numbers. Brands and short-name tables duplicated with mydrive. | Session index. |
| fragile | coverage.cs:104 | Starts a browser from inside `lock(gate)`. `/api/watch/open` is reachable from a paired phone (opens a browser on the rig, sim closed only). | Outside the lock. Local only. |

### phone.cs (684), protools.cs (984), probe.cs (34)

| Sev | File:lines | Finding | Fix |
|---|---|---|---|
| breaks Peter | phone.cs:449-458 | While driving, the phone blocks only rig-on, test-drive-last, showcase, sleep and lock. A paired phone can still run `shutdown`, `quit-main`, `restart-race`, `skip-session`, `race-now`, `ai-race`, `pause` and `kids` mid-race. | An allow-list while driving (audio, pit, chat). |
| fragile | phone.cs:198-202 + irdash.cs:552-556 | The LAN gate is a deny-list (`Hidden`). A paired phone reaches every `/api/do` command, `/api/guest/*`, `/perf/*` and `/api/watch/open`. | A path allow-list for non-local callers. |
| fragile | phone.cs:209-244, 263-343 | The token is accepted in `?t=` (it leaks into logs and history). The cookie has no HttpOnly. The 6-digit code allows 8 tries per code, but a new code is made on the next poll, so there is no global lockout. `/phone/revoke?all=1` is open to any paired phone. | Header or cookie only, a 60 s lockout, revoke-all from the PC only. |
| fragile | phone.cs:123-173 | It listens on every private IPv4, including Hyper-V, WSL and VPN adapters. | The default-route adapter only. |
| fragile | protools.cs:598-668 | `/analysis/pro/save` and `/delete` are state-changing GETs with CORS `*`, allowed while driving. Save is `Delete` then `Move` (a crash loses the formulas). | `File.Replace`, header check. |
| fragile | probe.cs:19-21 | Picks the irdashies folder by string sort (`app-0.9.9` sorts after `app-0.10.0`). `overlays.cs:153` sorts by version. | Share `Overlays.Exe`. |

---

## 3. Dead routes and dead features

I compared every route string in dash\src against `dash\www\v2\*.js/html`, `dash\www\phone`, `deck-intro\plugin.html`, irdeck (`src\*.cs`), `build-deck.ps1` and `tools\`. Test-only routes (`/api/test/*`, `/vault/test/*`, `/perf/test/*`, `/share/test/*`, about 35 of them) are all gated by `test-hook.on` and answer 409 while a session is on. That part is correct.

**No caller except tests (or none at all):**

| Route | Where | Note |
|---|---|---|
| `GET/PUT /maps/<name>.json` | irdash.cs:821, 841-870 | Old v1 map saving. Nothing calls it. Remove. |
| `/timings` | irdash.cs:776 | Only tests. rig.js reads `timings` from another reply. |
| `/api/delta/preview` | irdash.cs:705 | Tests only. |
| `/cars/status` | cars.cs | Tests only. |
| `/corners/` sub-routes, `/corners/audit`, `/corners/detect` | corners.cs | Tests and tools only. |
| `/gallery` (JSON) | irdash.cs:629 | Tests only. The deck drives the gallery through `/api/do`. |
| `/analysis/lap` | analysis.cs Route | Tests only (the old lap analysis; Session Review and workbench replaced it). |
| `/analysis/gain` | gain.cs | Tests only. MY DRIVE pokes gain internally. |
| `/field/status` | field.cs | Tests only. |
| `/official/import` | official.cs | Tests only. |
| `/tv`, `/tv/data` and the `Tv` worker | tv.cs, irdash.cs:695-696 | The TV view is off (`tv_view=0`, `tvview` refused), but the 100 ms worker still runs (see tv.cs). |
| `/api/open` | irdash.cs:583 | Used by a second irdash start, so it is live. Keep. |

**Live only through irdeck (keep, but they belong in the command table):** `/official/owned`, `/official/refresh`, `/api/keymsg`, `/api/spot`.

**Dead or legacy features inside live files:**
- The old v1 dashboard: `dash\www\index.html`, `core.js`, `ui.js`, `map.js`, `demo.js`, `style.css`. irdash.ini has `page=v2/`.
- The NVIDIA ShadowPlay clip path in vault.cs.
- The Cosworth launcher (vault.cs:1788-1980). It works, but phase-1 06 says it over-promises.
- The realworld preview, cost machinery and 9 unused parsers.
- `Corners.DetectLibrary`, `Vault.Enabled`, `Recorder.Enabled`, `RecAudio.LastError`/`LastRunState`, `SrCli`.
- The test command lines in analysis.cs, career.cs, protools.cs and rigwin.cs.
- The `*-owner.txt` back doors.
- `PADDOCK_DECKFEED_BASE`.

I did not check the 150+ `/api/do` command names one by one against the deck and page senders. That is a mechanical job for the rewrite, once there is a command table to check against.

---

## 4. Duplication, in numbers

- **.ibt reading:**
  - One shared header parser (`TrackMaps.OpenIbt`, irdash.cs:1172).
  - **5** separate record decoders.
  - About **14** ad-hoc record-range readers.
  - **6 lap splitters**: `Analysis.Load`, `IbtLaps.Segment`, `Corners.ReadBestLap`, `Career.Read`, `RawEvents`, `BuildPartial`. The recorder's live lap detector and the PB reference's live logic make 8.
- **"Best lap":** at least **8** different definitions:
  - My Races: any lap.
  - Vault and Sessions: counted.
  - Career fallback: announced laps.
  - Race page: iRacing's FastestTime.
  - Coach: Pure, else Clean.
  - Deep dive: Clean.
  - HOME: any car.
  - Live PB reference: iRacing's best.
- **"Last session":** 5 pickers, and 4 of them can pick the wrong session. `debrief.cs:589` (by `SessionUniqueID`) is the only correct one.
- **"Is he busy":** 7 different tests. Several that click or launch use the weakest one (`IsOnTrack`).
- **ini readers:** 6. **Graphics-ini parsers:** 3. **YAML session-info helpers:** 5 copies, plus the car-block regex 8 times. **ffmpeg runners:** 3. **irdeck runner queues:** 5. **JSON escapers:** 3. **Median:** 5. **HTTP reply helpers:** 3.
- **Process objects:** `GetProcessesByName` is called in about 40 places and almost never disposed.

---

## 5. Cost while he drives (stutter-relevant)

Everything below runs during a race today. The rough costs are mine or the logs'. Nothing was profiled under load.

| What | Interval | Thread | Cost / risk |
|---|---|---|---|
| Recorder PB-clip cut (ffprobe + ffmpeg copy + AAC, 87-94 MB write) | each PB or session-best lap, 1-11 s after the line | BelowNormal CPU, **normal disk priority** | High suspect for disk contention at the line. It ran at lap 9 in the freeze window. |
| Recorder incident clip (30 s, about 28 MB) | each incident | same | as above |
| Recorder housekeeping (retention deletes, export sync, segment prune) | 5 s | recorder Loop | Multi-GB deletes possible mid-session. |
| `FinishSession` of the previous session | on session change | worker | About 1.1 GB concat and an AAC encode while he drives the next session. |
| Field laps (YAML regex parse + append to fieldlaps.tsv) | 30 s in multi-car sessions | thread pool | Small write each time (seen all race in the log). |
| PB reference write (`refs\*.json`) | each PB lap | thread pool | Small write at the line. |
| Vault `KeepPress`/`ClipPress` → `SaveAll` (7 files) | per press | HTTP | Small burst. |
| Delta bar repaint | up to 30 Hz | **UI thread** | GDI+ text + layered window. Shares its thread with the 2 s guard. |
| Guard timer (PlaceSim, KeepDash process scans, watchdog, doctor 20 s window sweep) | 2 s | **UI thread** | Process enumeration, sometimes WMI. Can delay the delta bar. |
| RaiseOverlays (TOPMOST on irdashies windows) | 5 s | UI thread | Z-order change during the session. |
| TV builder (YAML regex parse) | **100 ms** | worker | Wasted: the TV view is off. |
| Process sampler | 5 s | BelowNormal | 5-8 ms per tick (measured). |
| `PerfPrio.Maintain` (re-lowers irdashies and the browser) | 5 s | sampler | Priority changes on other apps during the session. |
| Wheel button poll | 40 ms, 16 joystick ids | worker | About 400 calls a second. |
| Spot | every frame (60 Hz) | worker | Small. |
| SpotterGuard | 2 s | worker | 1-2 process scans. |
| Overlays state.ini read | 500 ms | timer pool | Small file read twice a second. |
| AC (python.exe + cloud TLS call) | 120 s | child process | A CPU burst every 2 minutes, not measured. |
| Page polls: `/keymsg` 400 ms, `/mydrive` 1.2 s (4 file reads + gain poke), `/home` 5 s (can trigger the official `.dat` scan), `/overlays` 6 s, `/perf/live` | | HTTP threads | 0.5-1 % of a core combined (guess). `/home` → `BuildOwned` is the risky one. |
| Map builder on a new track | per `/trackmap` request | BelowNormal | A process scan per .ibt (about 590) plus header opens. |
| Reference build when a session loads | once per combo | Lowest | Up to 6 × 74 MB file reads in the garage. |
| Doctor `Run` from deck or HTTP | on demand | any | Full checks, probe.exe launch, folder scans. No session guard. |

What is safe: the SDK reader itself (allocates one buffer per frame, fine), `/stream` (per client), keymsg, spotcore, deckwatch.

---

## 6. Test coverage

There are 96 scripts in `tests\`. Most modules have at least one: recorder (6), vault (22 route hits), bench, analysis, data-truth, race-truth, perf, doctor, phone, official, mydrive, overlays, replay, spot, spotcore, deckwatch, keymsg, share and others.

**Not covered by any test**, and these are exactly where the bugs above live:
- **Best lap agreeing across pages** (My Races, Vault, Sessions, Debrief, Race, HOME, Coach). `data-truth-test` checks one lap time against the raw file, not the "best" of a race. `races-screen-test` does not check the best lap.
- **`LapRules` against real race files:** how many laps of a clean race are counted. Today 3 of 10.
- **`Perf.Summary`** staleness, or naming the right session after a race.
- **Recorder retention** after a test (`TestOff` keepSessions 3), and `SyncExports` deleting a race when the export is renamed.
- **The watchdog's sim recovery** (`Watch.Tick` / `Recover`). Only the pure deck logic is tested.
- **The UI-thread window jobs:** `PlaceSim`, `KeepDash`, `RaiseOverlays`, `OverTaskbar`.
- **Session guards on actions:** mydrive `mdfind*`, ailevel `Start`, `Doctor.Run`, overlays `ovl apply`, phone keys while driving, vault and recorder changing routes.
- **Cost while driving:** nothing measures irdash's own CPU, disk and UI-thread time during a session. `dash-perf-test.ps1` covers the page, not the server.
- **`Log` rollover**, the HTTP server under many connections, `/version`.
- **No tests at all:** coverage.cs, probe.cs, `Systems`, `/timings`, tv.cs data, `TrackMaps.FromIbt` with a new track, realworld's live fetch switch.

---

## 7. Proposed module map for the rewrite

Principle: one owner for each truth (rig state, files, laps, sessions, video), small modules, no module over about 1,000 lines, slow work only between sessions.

### Core (new, everything else uses these)

| Module | Replaces / takes from | Job |
|---|---|---|
| `RigState` | `IsDriving`, `CarMoving`, `RealBusy`, `Busy()`, `BusyWhy`, 15 inline sim-name lookups | `Driving`, `SessionOn`, `SimRunning`, `StartPressed`, updated by the SDK thread. Every action, job and route asks it. |
| `SdkReader` | irdash.cs `Sdk` (keep the reader, it is sound), the test pump | Frames + one `SessionInfo` cache parsed once per SessionVersion (drivers, car, track, session type). Replaces the 5 YAML helper copies and tv.cs's re-parse. |
| `IbtFile` | `TrackMaps.OpenIbt` + 5 decoders + 14 readers | Open, header, var lookup, read a channel range, "is finished". |
| `LapStore` (lap truth) | `Analysis.Load`, `IbtLaps.Segment`, `Corners.ReadBestLap`, `Career.Read` laps, `RawEvents`, `BuildPartial`, recorder `TrackLaps`, `PbRef.CheckPending` | One lap record {n, time, counted, pit, off, incident, start}. Live laps come from the SDK, old laps from `IbtFile`. One `Best()`, one rules version. |
| `SessionIndex` | Career cache, `CrFile`, `fieldlaps` scan, perf store's file list, gain, `LastSession` pickers, 4 career-cache.tsv parsers | One row per file and session (start, car, track, type, laps, counted best, seat time, `SessionUniqueID`), built between sessions. |
| `Jobs` | recorder worker, career job, gain job, map builder, refs build, perf reports, debrief cuts, official build | One background queue with "wait until `!SessionOn`", BelowNormal CPU **and** background disk priority, one log line per job. |
| `Proc` | 3 ffmpeg runners, 5 irdeck queues, the CrewChief and Stream Deck launchers | Start, timeout, priority, dispose, log. |
| `Config`, `Json`, `Log` | 6 ini readers, 3 escapers, `Log.W` | Rolled log on a background queue. |
| `Http` | the `Server` class + `/api/do` chain + `Phone.Hidden` | One route table: path, handler, "allowed while driving", "allowed from phone", "changes state" (needs header). One command table for `/api/do`. Thread pool. |

### Features (keep, slimmed, on top of the core)

| Module | From | Notes |
|---|---|---|
| `Live` (top screen feed, delta bar, keymsg, spot) | deltabar, keymsg, spot, spotcore, deckfeed | Delta bar keeps the UI thread to itself. |
| `RigGuard` (windows, watchdog, deck watch, spotter guard) | irdash.cs `Watch`, `PlaceSim`/`KeepDash`/`RaiseOverlays`, deckwatch, rigwin, spotterguard | Background thread; posts only window moves to the UI. One CrewChief owner. |
| `Recorder` split into `Capture` / `Cuts` / `Library` | recorder, recaudio | Cuts and finishes run as `Jobs`. Library owns Videos\Paddock export and deletion (never on a missing export). |
| `Review` (the one review engine) | analysis, sessionreview, coach, debrief, deepdive, workbench, partial, rawdata, field, corners, gpsmap | Reads `LapStore` and `SessionIndex`. One trace-and-corner engine (phase-1 06). |
| `Rig health` (doctor + perf + black box) | doctor, perf | Split perf into report, sampler, checks. Add the per-second black box (phase-1 05). One graphics-ini reader. |
| `Replay`, `Share`, `Gallery`, `Phone`, `MyDrive`, `Overlays`, `Friends` (Guest), `AiLevel`, `Sound`, `AC` | same files | Use `RigState`, `Proc`, `Http` tables. Phone moves to an allow-list. |
| `Vault` | vault.cs | Keep moments, telemetry copy and thumbnails. Drop the NVIDIA path. Cosworth goes to its own small file (or out). |

### Goes

The TV worker and `TvView` (until a real TV view is designed), `PUT /maps`, the old v1 www, the realworld preview and unused parsers, `DetectLibrary`, the dead `Enabled` flags, the test command lines and back doors in the product (move them behind `#if TEST` or the one test hook). Also the `PerfPrio` experiment, unless Peter wants it, and possibly the AC 120 s python poll while driving.

### Order to do it in

1. **Safety first, small patches before the rewrite** (each with a test):
   - `RigState` plus session guards on mydrive `mdfind*`/`mdstart`, `AiLevel.Start`, `Doctor.Run`, `ovl apply`, the phone's while-driving list, and the vault and recorder changing routes.
   - `TestOff` keepSessions.
   - `SyncExports` deleting on a missing export.
   - A global exception handler.
   - Log rollover.
2. **Stop work during sessions:**
   - Recorder housekeeping, `FinishSession` and PB cuts wait for `!SessionOn` (or run at background disk priority).
   - Stop the TV worker.
   - Move the official `BuildOwned` off `/home`.
   - Fix the map builder's per-file process scan.
   - Move the guard timer off the UI thread.

   Then compare one race's fps with the per-second black box.
3. **Lap truth:** `IbtFile` + `LapStore` + one counted rule, with a test that the best lap agrees on every page for the 12 Nov race (expect 1:33.832).
4. **SessionIndex + Jobs**, and move Career, gain, perf reports, field laps and refs onto them. Fix `Perf.Summary` staleness here.
5. **Http route table + command table.** Delete the dead routes. Make the phone an allow-list.
6. **Split the god files:** irdash.cs, recorder.cs, vault.cs, perf.cs, then the analysis family into `Review`, following the phase-2 screen plan (HOME / RACES / REVIEW / RIG).
7. **Cleanup pass:** duplicates, test code out of the product, ARCHITECTURE.md brought up to date (vault, official and recorder are on).
