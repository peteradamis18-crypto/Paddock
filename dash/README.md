# iRacing Dash (top monitor)

`irdash.exe` reads iRacing's live telemetry and shows a dashboard full screen on monitor 4.
It also keeps the iRacing sim window stretched across monitors 1 to 3.
It starts with Windows and lives in the tray (checkered-flag icon).

## Panels
- **Header:** flag state, session and time or laps left, track, position, class position, lap, incidents, temperatures, clock.
- **Standings:** position, class color, license and iRating, last and best laps, gap. Click "All classes" to show only your class.
- **Track map:** real track outlines with every car placed by lap position, plus pit lane where known. See "Track maps" below.
- **Telemetry:** gear, speed, shift lights, pedal bars, 10-second input trace, steering, tires, brake bias, ABS, TC, temperatures.
- **Relative:** cars around you on track with time gaps. Red names are a lap ahead of you, blue are a lap behind.
- **Timing and fuel:** current lap, delta to best, sectors, recent laps, fuel per lap, laps of fuel, fuel to add to finish.

## Track maps
iRacing does not send GPS in its live data. GPS only exists in the `.ibt` telemetry files it saves to `Documents\iRacing\telemetry`.
irdash picks a map for each track in this order and saves it in `maps\`:
1. **Your telemetry.** Every clean on-track stretch from your last 15 sessions at that track is combined. Exact for your car's racing line.
2. **SIMRacingApps library.** Downloaded on first visit when it has a lap-keyed outline. Checked against Road Atlanta: within about 4 to 13 m of real GPS.
3. **Lap bar.** A straight line with cars on it, until one of the above exists.
A library map is replaced by your own automatically once you have driven enough of the track. Delete a file in `maps\` to rebuild it.
Library data: SIMRacingApps by Jeffrey Gilliam, Apache License 2.0, https://github.com/SIMRacingApps/SIMRacingAppsServer.
iRacing's official map drawings need a Data API client ID, which iRacing has paused issuing.

## Tray menu
- Open dashboard / Open demo (fake race) / Start with Windows / Open folder / Exit.

## Settings: `irdash.ini`
- `screen` is the dashboard monitor. If it is missing, irdash uses the highest monitor.
- `keep_dash=1` moves the dashboard back if it leaves its monitor, and reopens it if closed. It never opens a window while you are on track.
- `place_sim=1` stretches the sim window over every other monitor. `sim_rect=x,y,width,height` overrides that.
- `log_all_cars=1` keeps iRacing's `irsdkLogAllCars=1` set in app.ini, with a backup first. It only edits while the sim is closed.
- `delta_bar=1`, `delta_ref=best|optimal|session`, `delta_pos=auto` (or `x,y` / `center,y`), `delta_scale=1.0`: the delta bar irdash draws itself on the middle race screen (`src\deltabar.cs`). It shows only while you are on track and not in the pits, never takes focus, and fades out in the pits. The Stream Deck OVERLAYS screen changes the first three live and saves them here.
- Screens in the wrong order: run `..\swap-screens.ps1` (or `-Undo`).

## Changing it
- The dashboard is plain HTML/JS in `www\`. Edit and press F5 on the dashboard.
- The C# side is `src\irdash.cs`. Run `build.ps1` to rebuild; it restarts irdash if it was running.
- Preview without the sim: `http://localhost:8199/?demo=1` (add `&speed=8` to fast-forward).

## iRacing display settings changed on 2026-10-06
`Documents\iRacing\rendererDX11Monitor.ini` was set to a fixed borderless window across monitors 1 to 3.
It used to center on the main display, which is the top monitor.
The original is in `..\backup\rendererDX11Monitor-20261006-2047.ini`.

## Overlays screen, Rig Doctor, timings (2026-10-09)
- `/overlays` (JSON) and `/api/do?c=<command>&a=<arg>` serve the Stream Deck OVERLAYS screen. Commands are a whitelist (`ovtoggle`, `ovpreset`, `ovsave`, `ovalloff`, `ovedit`, `ovapply`, `deltaon`, `deltaref`, `deltaup`, `deltadown`, `doctor`, plus the friends ones); irdash hands the overlay ones to `irdeck ovl ...` one at a time. irdashies never re-reads `config.json` by itself, so a change restarts it (about 1 s), once, 1.5 s after the last tap, and never while the car is moving.
- Presets live in `..\overlays\presets\*.json`; every config change is backed up to `..\backup\irdashies\`.
- Rig Doctor: `/doctor` (JSON), `/api/doctor/run` (add `?quiet=1` to check without showing the list). It runs by itself 100 s and 5 minutes after irdash starts and every 30 minutes out of the car. `probe.exe` is started through Explorer to see what normal programs see (programs started from the Claude app get private AppData copies).
- `timings.tsv`: boot to iRacing UI, START to session loaded and to in the car, sim exit time. `/timings` (JSON). The last values show in Rig Doctor and on the idle screen.

## Data tool (2026-10-09): sessions, lap analysis, race extras, brief, flag glow
See `..\docs\data.md`. In short: `/v2/sessions.html` lists every session and personal best and analyses laps (`/ibt/laps`, `/ibt/lap`); open it from the idle
screen or with `GET /api/sessions/open` (a Stream Deck key); `/race` (strength of field, iRating estimate), `/brief` (before a session), the idle
screen's weekly progress (`/career` -> `week`), a flag-coloured glow round the dashboard, `sim_priority=high|normal` in `irdash.ini`, and Rig Doctor
fixing what it safely can (overlays, CrewChief, Stream Deck, OneDrive pin) when no session is running. `src\data.cs` holds the new C#; test: `..\tests\data-test.ps1`.