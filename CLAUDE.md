# PADDOCK — Peter's sim rig software (project folder: iRacingDeck)

"Paddock" is the product name shown to Peter (top screen, deck, intro, docs). The folder, exes (irdeck, irdash),
process names, port 8199 and the add-on UUID keep their old names — paths are wired into the Stream Deck profile,
the logon task and irdash, so never rename them.

**Plan and work split (2026-10-10):** the master plan is `docs/ROADMAP.md`, the task cards are `docs/TASKS.md`, agent rules are `AGENTS.md`. Builders are Grok Build (`tools\grok-run.ps1 -Card C-xx` / `tools\grok-queue.ps1`, Peter's subscription, no API); Claude writes specs, reviews and runs live checks, and keeps its own token use low.

Read this first. Then `docs/ARCHITECTURE.md` (how it fits together), `docs/OPERATIONS.md` (build, deploy, test,
recover), `docs/SPEC-next.md` (what's planned and the rules for implementers), `docs/COMPETITIVE.md` (why).
Peter-facing guide: `docs/USER-GUIDE.md`.

## Who it's for
Peter races iRacing on a dedicated rig. He is disabled: everything must be one press on the Stream Deck or automatic.
He values substance (faster, less effort) over decoration; the look is premium black/gold broadcast style, never cheesy.
Explain things to him in plain English, short, no jargon.

## The rig
- Three 2560×1440 165 Hz race screens (Windows rotation 180°, physically upside down) at x −2560 / 0 / 2560, y 0; the
  **middle one is the Windows primary**. A 1920×1080 dashboard monitor above at 320,−1080. Find screens by POSITION,
  never by `\\.\DISPLAYn` (Windows renumbers them).
- RTX 4080, Ryzen 9800X3D, Simucube wheelbase, ButtKicker, Stream Deck XL (32 keys), CrewChief spotter, irdashies
  overlays. Graphics settled at ~104 fps in a full race (cap 160, Reflex off, 2 pre-rendered frames).

## The parts (details in docs/ARCHITECTURE.md)
| Part | Source | Output |
|---|---|---|
| irdeck — command tool behind every Stream Deck key | `src/*.cs` (one `static partial class Program`) | `irdeck.exe` (+ copies in `keys/`), `irdeck-cli.exe` |
| irdash — top-screen dashboard + local server `http://localhost:8199`, watchdog, data, delta bar, Rig Doctor | `dash/src/*.cs`, `dash/www/v2/*` | `dash/irdash.exe`, `dash/probe.exe` |
| Rig Intro — our Stream Deck add-on (startup animation, FRIENDS / OVERLAYS / MY DRIVE / REPLAY live screens) | `deck-intro/plugin.html`, `deck-intro/install.ps1` | installed into Stream Deck |
| Replay controls (SDK broadcast, no clicks) and the side-screen gallery | `dash/src/replay.cs`, `dash/src/gallery.cs` | part of irdash |
| MAIN deck page | `build-deck.ps1` | Stream Deck profile "iRacing GT3" |
| Settings/state | `guest/`, `overlays/`, `mydrive/`, `dash/irdash.ini` | |
| Tests | `tests/*.ps1` | ok/FAIL lines + `tests/shots/*.png` |

## Build (C# 5 with Windows' own csc — no SDK, no NuGet)
- irdeck: `build-irdeck.ps1` (both exes; updates every `keys\*.exe` copy).
- irdash: `dash\build.ps1` (`-NoDeploy` to only compile). Add new .cs files to its `$src` list.
- Add-on: bump `$ver` in `deck-intro\install.ps1`, run it once; **Peter must click Install** in Stream Deck.
- MAIN page: close Stream Deck, run `build-deck.ps1`, restart Stream Deck (`docs/OPERATIONS.md`).
C# 5 only: no `$"..."`, `?.`, `nameof`, expression-bodied members, `out var`.

## Rules that protect Peter's setup (non-negotiable)
1. **Never act while he is driving.** Run `irdeck-cli.exe state` first; `onTrack=True` or `telemetry=on` = wait.
   No clicks, keys, focus changes, app restarts, deploys or popups during a session.
2. **Never write iRacing's own files** (`Documents\iRacing\*.ini`, `controls.cfg`, the install folder) without Peter's
   yes. Graphics only via `gfx-set.ps1` (backs up; refuses while the sim runs).
3. **This Claude session is inside a packaged app**: processes it starts that CREATE new `%APPDATA%`/`%LOCALAPPDATA%`
   folders get redirected to `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\...`, invisible to everything
   else (this broke the overlays install once). Start installers and GUI apps with
   `Start-Process explorer.exe -ArgumentList '"<path>"'` (a `.cmd` for arguments). Exercise AppData-writing commands
   through irdash's HTTP API (irdash runs outside the package).
4. **iRacing UI automation**: verify the dialog/panel before every click (`DialogOpen` / `EnsurePanel` in
   `src/testdrive.cs`); only click rows that are on screen; never type outside a verified field. A blind click once
   opened iRacing news and a Steam sign-in.
5. No downloads/installs without Peter's yes. Never enter credentials. Never change Windows/security settings yourself —
   give Peter a one-click `.cmd` (+ UNDO) instead.
6. Stream Deck key presses can arrive 2–3 times: keys ignore repeats within 0.7 s; keep commands idempotent.
7. Every change gets a test in `tests/` and all tests pass before you report. Don't claim it works without a test or a
   screenshot.
8. **Tests never run while Peter races or is about to** (2026-10-09 a test's pretend race and app restarts hit two of
   his real sessions). Every test dot-sources `tests\guard.ps1` and calls `Assert-RigFree` at the start and before
   each section (`Section 'n. ...'`): it stops if the sim is running or a START key was pressed in the last 10 min.
   Tests that start the real sim or click in the iRacing app use `Assert-RigFree -NeedAway` (10 min with no keyboard/
   mouse input) — if Peter is at the PC, build and mock-test now and leave the live part for the lead. irdash refuses
   the test hook (HTTP 409) while a real session is on, and `dash\build.ps1` won't deploy then (exit 2) or while a
   test holds `dash\deploy.lock`.
   **Work does NOT stop while he races** (Peter 2026-10-10: "i want to progress, why can't you work while i race").
   During a session you may edit source/www/docs, research, compile with `-NoDeploy`, and run offline tests and bulk
   file jobs on OLD .ibt files — at BelowNormal priority, ≤ 2 cores; downloads one file at a time throttled to
   ~500 KB/s (his online ping). Not during a session: deploy/restart anything, install the add-on, build-deck, tests
   that use the test hook or touch live apps, opening/moving/clicking windows on his screens, sending keys, reading
   the newest .ibt. Queue those, run them when `state` shows sim=False. The top-screen dashboard postpones its
   auto-reload while he is driving, so editing www files mid-race is safe.

## Style
**Peter must never have to think** (2026-10-10: "just make it all easy and intuitive so i dont have to think"): automatic by default,
one obvious button per screen, plain words, big targets, safe defaults, nothing to configure, no questions the system can answer itself.
Short comments that say *why*; plain names; no frameworks or libraries; JSON by hand in irdash (`Json_.S`).
Logs: `irdeck.log`, `dash/irdash.log`. User-facing text: plain English.
