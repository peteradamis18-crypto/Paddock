# Paddock — architecture

How the rig is put together. For build, deploy, test and recover, use `docs\OPERATIONS.md`. What Peter sees is `docs\USER-GUIDE.md`. Feature detail stays in the other docs (`data.md`, `benchmark.md`, `performance.md`, `corners.md`, `replay.md`).

The product name is **Paddock**. The folder, the exe names, port **8199** and the add-on UUID stay as they are. They are wired into the Stream Deck profile, the logon task and irdash.

## The rig

Three 2560×1440 race screens at x −2560 / 0 / 2560, y 0. The middle one (x 0) is the Windows primary. A 1920×1080 dashboard monitor sits above at 320,−1080. Find screens by position. Windows renumbers `\\.\DISPLAYn`. The race screens are rotated 180° in Windows (physically upside down). The sim is one window across the three race screens.

## Parts

| Part | Source | What runs | What it does |
|---|---|---|---|
| irdeck | `src\irdeck.cs`, `guest.cs`, `testdrive.cs`, `overlays.cs`, `mydrive.cs`, `actions.cs`, `official.cs`, `sound.cs` (one `static partial class Program`) | `irdeck.exe` (no console) and `irdeck-cli.exe` (`-define:CLI`) | One command per launch. Stream Deck MAIN keys are copies of `irdeck.exe` in `keys\`. With no arguments, a copy looks up its own file name in `keys\keys.map`. |
| irdash | `dash\src\` (the `$src` list in `dash\build.ps1`) and `dash\www\v2\` | `dash\irdash.exe`, `dash\probe.exe` | Tray app. Local web server. Reads the iRacing SDK. Draws the top-screen dashboard, the delta bar and the side-screen gallery. Watchdog, Rig Doctor, career cache, sessions, benchmark, performance, corners. |
| Paddock add-on | `deck-intro\plugin.html`, `deck-intro\install.ps1` | Stream Deck plugin UUID `com.peter.rigintro` | Display name Paddock. SDK 2. Live screens: intro, FRIENDS, OVERLAYS, MY DRIVE (race setup), REPLAY, ANALYSIS, SOUND. Source version in `install.ps1` is `$ver` (1.7.0.0 adds ANALYSIS and SOUND; installed only after Peter clicks Install, C-42). ANALYSIS reads `/workbench/state` (the workbench page reports itself, `dash\src\deckfeed.cs`) and sends `wb-*` commands; SOUND reads `/sound` (`dash\src\sound.cs`, which runs `irdeck sound ...`, `src\sound.cs`). The deck runs a new build only after Peter clicks Install. |
| MAIN page | `build-deck.ps1` | Stream Deck profile "iRacing GT3" | 32 keys, one row per stage of a session. Profile id `65E017A2-2219-43EE-A4E4-44D505F5B406` under `%APPDATA%\Elgato\StreamDeck\ProfilesV3`. |
| Overlays | irdashies, newest `%LOCALAPPDATA%\irdashies\app-*\irdashies.exe` | that exe | In-car widgets. Our presets are `overlays\presets\*.json`. irdashies does not reload `config.json` by itself; a change restarts it, and never while the car is moving. |
| CrewChief | `C:\Program Files (x86)\Britton IT Ltd\CrewChiefV4\CrewChiefV4.exe` | CrewChiefV4 | Spotter. Friends mode can change the name it says, and puts Peter's name back on exit. |
| Tests | `tests\*.ps1` | — | Each one dot-sources `tests\guard.ps1`. `tests\run-all.ps1` runs the safe set. |

`dash\src\vault.cs` and `dash\src\official.cs` compile into irdash. Both stay off until `dash\irdash.ini` says `vault=1` or `official=1`. Today both are `0`. They are not part of what Peter uses.

## Processes and who starts them

Logon task **iRacing Rig** (state Ready) runs:

```
C:\Users\peter\iRacingDeck\irdeck.exe rigon --boot
```

`rigon` starts programs in this order. At boot (`--boot`) it starts Stream Deck, waits until the pipe `\\.\pipe\com.elgato.streamdeck.local` exists (or 30 seconds), then starts the rest. An empty file `boot-stagger.off` in the repo root skips that pipe wait. Logon then waits only until the Stream Deck process exists, up to 15 seconds. The RIG ON key is `rigon` without `--boot`: it still starts Stream Deck first, waits up to 3 seconds for the process, then the rest.

| Order | Process | Path | If it is already running |
|---|---|---|---|
| 1 | StreamDeck | `C:\Program Files\Elgato\StreamDeck\StreamDeck.exe --runinbk` | left alone |
| 2 | irdash | `dash\irdash.exe` | started again; the new process only asks the running one to open the dashboard |
| 3 | sc-tuner | `C:\Program Files\SimucubeTuner\sc-tuner.exe --tray` | left alone |
| 4 | bk-connect | `C:\Program Files\ButtKicker\connect\bk-connect.exe --minimized` | left alone |
| 5 | irdashies | newest `app-*` folder under `%LOCALAPPDATA%\irdashies` | left alone |
| 6 | CrewChiefV4 | the path above | left alone |
| 7 | iRacingUI | `C:\Program Files (x86)\iRacing\ui\iRacingUI.exe` | left alone, then moved onto the centre screen |

Windows also starts Stream Deck from the user Run key. The second start quits at once. Leave that Run entry.

irdash then starts:

- Chrome, or Edge if Chrome is missing, in a kiosk on the top screen. Window title **iRacing Dash** (irdash finds that window by the title). Page `http://localhost:8199/v2/` because `irdash.ini` has `page=v2/`. Profile data is `dash\browser-profile\`.
- The delta bar, a click-through window on the middle race screen. No extra process.
- The gallery, click-through windows on the left and right race screens. No extra process. Destroyed while the sim runs.
- `dash\probe.exe`, only when Rig Doctor needs to see what a normal program sees (AppData is wrong for a process started inside a packaged app). Started through Explorer. It writes `dash\probe.txt`.
- A background SDK thread, a career scan, map building, performance scan. All in the irdash process.

The sim process is `iRacingSim64DX11`. iRacing starts it. The anti-cheat launcher process is `start_protected_game`. irdash does not start either.

The watchdog inside irdash (on unless `irdash.ini` turns it off; the default is on):

- Stream Deck process gone for 10 seconds: start it again, at most once a minute.
- Stream Deck log shows a USB disconnect and the device is still plugged in: restart the Stream Deck app, at most every 2 minutes.
- Sim not connected, launcher sat alone for 60 seconds, or the sim is over 2 minutes old with no window and almost no CPU: end those processes and start the iRacing UI again. Never when the SDK is connected. At most 3 times an hour. Logged as `watchdog:`.

## Port

**8199**, localhost only, from `port=` in `dash\irdash.ini`. The add-on, the tests and the dashboard all call `http://localhost:8199`. Do not change it.

One irdash at a time: mutex `Local\IRDashSingleInstance`. A second start calls `GET /api/open` on the running copy and exits. If the port will not bind, irdash shows a message and exits. Recover in `OPERATIONS.md`. The page reloads itself when `GET /version` changes (newest write time of the exe or any file under `dash\www`, png files ignored). While he is on track and not in a replay, the page keeps the old version and tries again in 15 seconds.

Useful routes (all GET):

| Route | Who uses it |
|---|---|
| `/v2/` | the dashboard |
| `/health` | watchdog JSON |
| `/version` | the page, to decide when to reload |
| `/stream` | live telemetry (server-sent events) |
| `/api/do?c=<command>&a=<arg>` | add-on screens. Whitelisted. Friends, overlays, My Drive, replay, gallery, performance, and the same friends commands as below. |
| `/api/guest/do?c=&a=` | friends screen |
| `/guest`, `/overlays`, `/replay`, `/gallery`, `/mydrive`, `/doctor`, `/career` | JSON for those screens |
| `/api/doctor/run` | run Rig Doctor (`?quiet=1` checks without showing the list) |
| `/api/test/...` | pretend session. Answers only while `dash\test-hook.on` exists and `Sdk.RealBusy()` is null. Otherwise 409 if he is racing or about to, else 404. `/api/test/end` always stops a pretend session. Never reachable from the LAN. |
| `/cars/<carpath>.jpg`, `/cars/manifest.json`, `/cars/need?path=` | iRacing's OWN car pictures (CP-1; `dash\src\cars.cs`, `dash\www\v2\carpics.js`, `paddock\cars\`): the small picture (480x270) iRacing's image server shows for each car, kept on disk, one file per CarPath (`manifest.json` has source URL + CarID, `catalog.json` every car the server has). RACE tower + header chips, CAREER race rows and HOME show them; a car with no picture shows nothing. `need` fetches a missing one in the background, one file at a time, NEVER while a session is on (`Sdk.RealBusy`); `tools\cars-build.ps1` makes the first set from his telemetry. |
| `/home`, `/home/hero` | Paddock HOME on the top screen (`dash\src\home.cs`, `dash\www\v2\home.js`): name, number, PB per track, last session, the hero picture (`paddock\home\hero.jpg` wins; stand-in with credit until then). |
| `/share/make`, `/share/status`, `/share/video` (Range), `/share/open`, `/share/jump`, `/share/test/frame` | the share studio (`dash\src\share.cs`: overlay drawing, ffmpeg/NVENC job queue, `Analysis.ShareCollect` reads the lap's own .ibt records) and the replay jump (`dash\src\replayjump.cs`, SDK broadcast through `Replay`). `/share/open`, `/share/jump` and `/share/test/*` are this PC only (404 for the phone, `Phone.Hidden`). Docs: `docs\vault.md` "Share video". |
| `/phone/`, `/phone/state`, `/phone/qr`, `/phone/pair`, `/phone/devices`, `/phone/revoke` | the iPhone app (`dash\www\phone`, `dash\src\phone.cs`). `/api/do?c=key&a=<name>` runs `keys\<name>.exe`, the deck's own key. |

**The phone.** irdash listens on the LAN address only while `dash\phone-allowed.txt` exists (written by `tools\phone-allow.cmd`, Peter's double-click: firewall rule `Paddock phone (irdash 8199 in)`, Private profile, local subnet, `irdash.exe` only; `phone-undo.cmd` reverses it). Checked every 30 s, no restart. A request that is not from this PC needs a pairing token (cookie `pt`, header `X-Paddock-Token` or `?t=`), except the app's own files and `/phone/pair`. Tokens are SHA-256 hashes in `dash\phone-tokens.txt`; the one-time code (10 min, single use) comes from `/phone/qr`, localhost only, drawn as a QR on HOME (writer in `phone.cs`, decoder check in `tests\phone-test.ps1`). `?asphone=1` makes any local request go through the same gate (stricter only) for tests. The Host check also accepts the bound LAN address, nothing else. |

A command the whitelist does not know gets HTTP 400 and the body `no`.

## Folders

| Path | Holds |
|---|---|
| `src\` | irdeck C# |
| `keys\` | one exe per MAIN key, plus `keys.map` (`name=command`) |
| `dash\` | `irdash.exe`, `probe.exe`, `irdash.ini`, `irdash.log`, `build.ps1`, `career-cache.tsv` (column 22 = did the car leave pit road; a session with no lap that never left it, or that a test started, is a "short run": not an outing, seat time or the HOME car), `timings.tsv`, `start-mark.txt` (label TEST when a test that owns the sim pressed START), `test-sessions.txt` (the runs a test started: start and end, UTC ticks), `deploy.lock` (only while a test holds it), `test-hook.on` (only while a test holds it) |
| `dash\src\` | irdash C# |
| `dash\www\v2\` | the dashboard Peter sees |
| `dash\www\` | the older dashboard. `page=v2/` means it is not the one on the top screen. |
| `dash\maps\` | track outlines built from his telemetry or the local library copy |
| `dash\refs\` | all-time best-lap traces for the delta bar (`<car>__<track>-<layout>.json`) |
| `dash\browser-profile\` | the kiosk browser. Leave it. |
| `deck-intro\` | add-on source. `install.ps1` is for the lead, and Peter clicks Install. |
| `guest\` | friends names, wheel, leaderboard (`guest.ini`, `state.ini`, `board.tsv`) |
| `mydrive\` | his favourites |
| `overlays\presets\` | race, practice, quali, minimal, friends |
| `paddock\gallery\` | side-screen photos and `credits.json`. `mine\` is photos from the replay PHOTO key. |
| `data\` | `perf*.tsv`, `corners\` (offline corner lists), `pro-refs.json`, `fieldlaps.tsv` |
| `data\official\` | official-racing draft data. The feature is off. |
| `replay\` | replay working files |
| `vault\bin\` | ffmpeg and ffprobe (already installed, for later recording) |
| `tests\` | tests, `guard.ps1`, `run-all.ps1`, `shots\`, `last\`, `run-all.last.txt` |
| `tools\` | one-click commands for Peter (`phone-allow.cmd` / `phone-undo.cmd` for the iPhone), and the Grok queue |
| `paddock\home\` | HOME's hero picture: `hero.jpg` (Peter's own, when captured), the credited stand-in, `credits.json` |
| `dash\www\phone\` | the iPhone app (installable web app) |
| `backup\` | old copies. Do not delete them to tidy up. |
| `docs\` | this file, the roadmap, the task cards |

iRacing's own files stay where iRacing put them: `Documents\iRacing\` (telemetry `.ibt` files are read, never written) and `C:\Program Files (x86)\iRacing\`. irdash will not edit them while `log_all_cars=0` and `sync_sim_ini=0`, which is how `irdash.ini` is set.

## Data flows

1. **Boot.** Windows logs on. Task "iRacing Rig" runs `irdeck.exe rigon --boot`. Stream Deck comes up, then irdash, wheel and haptics apps, overlays, CrewChief, and the iRacing UI on the centre screen. irdash opens the top-screen dashboard.

2. **A MAIN key.** Stream Deck runs `keys\<name>.exe`. That process reads `keys\keys.map`, ignores a repeat of the same key within 0.7 seconds (volume and seat keys are exempt), runs one command, appends a line to `irdeck.log`, and exits. A key that ends something and is marked x2 (`confirm` in `keys.map`) needs a second press within 3 seconds. The first press beeps twice.

3. **A live deck screen** (FRIENDS, OVERLAYS, MY DRIVE, REPLAY). The add-on draws the 32 keys. A press is `GET http://localhost:8199/api/do?c=...` or, for friends, `/api/guest/do`. irdash runs a whitelisted command. Overlay and friends actions that must change another app call `irdeck.exe`. Replay actions send iRacing SDK broadcast messages from irdash. No mouse click for those.

4. **Driving.** The sim maps its SDK into memory. irdash's reader publishes a frame. The dashboard listens on `/stream`. The delta bar reads the same frames plus `dash\refs\` for VS PB. Career, performance and corner scans read `Documents\iRacing\telemetry\*.ibt` in the background, read-only, and wait while he is on track. The gallery windows are destroyed while the sim process is up.

5. **After the session.** The new `.ibt` is picked up into `dash\career-cache.tsv` (not while he is on track). The sessions page, the benchmark card, the performance page and the delta-bar reference are built from that cache and from the file. Nothing is uploaded.

6. **A test.** The script calls `Assert-RigFree`, writes `dash\deploy.lock`, and for a pretend session creates `dash\test-hook.on`. irdash then accepts `/api/test/...` and does not broadcast replay messages. The script deletes both files when it finishes. `dash\build.ps1` will not replace irdash while the lock is under 15 minutes old or while the rig is busy.

## Names that stay

Do not rename: folder `iRacingDeck`, `irdeck.exe`, `irdeck-cli.exe`, `irdash.exe`, port 8199, add-on UUID `com.peter.rigintro`, profile names `RigIntro`, `RigFriends`, `RigOverlays`, `RigMyDrive`, `RigReplay`, logon task "iRacing Rig", dashboard window title "iRacing Dash".
