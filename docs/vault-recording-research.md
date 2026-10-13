# VAULT recording: how to get video of a lap / race out of iRacing (research, 2026-10-10)

Read-only research. Nothing on this PC was changed. Tags: **[C]** confirmed (read on this PC, or in iRacing's own pages / SDK wrapper source),
**[K]** community knowledge (named source, not tested here), **[G]** guess. Feeds WS17 in `docs\SPEC-next.md`.

## 1. Answer in plain English
Yes, iRacing can record video itself, and Paddock can start/stop it. But it is a weak recorder, it is switched off, and on this rig it would
record the 3-screen surface (7680x1440), not the middle screen. The smartest plan: **Paddock runs its own small hidden recorder (ffmpeg, GPU
encoder) on the middle screen. The same recorder films iRacing's *replay* when Paddock wants a perfect, UI-free re-shoot of a lap.**
iRacing's own video capture stays as the no-download fallback.

## 2. Findings
| # | Finding | Tag | Source |
|---|---|---|---|
| 1 | SDK broadcast msg 13 `VideoCapture`: var1 = 0 screenshot, 1 start, 2 end, 3 toggle, 4 show timer, 5 hide timer | C (wrapper source of the SDK header) | https://raw.githubusercontent.com/kutu/pyirsdk/master/irsdk.py ; same message is already used by PHOTO (`docs\replay.md`) |
| 2 | Hotkeys: Ctrl+Alt+Shift+V start/stop video, Ctrl+Alt+Shift+S screenshot; files go to `[documents]\iRacing\videos\` and `\screenshots\`. SPACE hides the UI | C | https://www.iracing.com/keyboard-shortcuts-replay-camera-controls/ |
| 3 | The module only loads if `[Video] vidCaptureEnable=1`, and the sim must be restarted after turning it on. App.ini here: `vidCaptureEnable=0`. **Screenshots (PHOTO key) very probably need it too** (the one tool that documents it says "Enable video and screen capture" gates both) | C for ini text, K for restart + screenshot | https://github.com/GetUpKidAK/iRacingSequenceDirector ; this PC `app.ini` |
| 4 | Values (from the comments in this PC's `app.ini`): `videoImgSize` 0 auto, 1 = 1920x1080, 2 = 1280x720 (now), 3 = 854x480. `videoFramerate` 0 = 60 fps, 1 = 30 fps (now). `videoFileFrmt` 0 mp4, 1 wmv, 2 avi2, 3 avi. `videoCaptureMic` 0/1 (microphone only). **No 1440p, no 4K, max 1080p60.** Default 720p30 | C | this PC `app.ini` [Video]; SequenceDirector README |
| 5 | Engine: the sim loads `d3dgear\irvidcap64.dll` (built on the D3DGear "raw frame capture" SDK) and Windows Media Foundation (`mfreadwrite.dll`) to write the file. Bitrate/codec are not user settings. Telemetry variables `VidCapEnabled` and `VidCapActive` exist, so Paddock can see whether capture is on | C (strings in the exe and dll) | `C:\Program Files (x86)\iRacing\iRacingSim64DX11.exe`, `d3dgear\irvidcap64.dll` |
| 6 | Audio: only an optional microphone. No game/engine sound in the mp4 | C (key name/comment); K for "no game audio" | `app.ini` |
| 7 | Quality opinion: in-sim recorder "works" but OBS gives "much finer controls"; replay graphics are a separate setting from driving ([Replay Graphics]) and should be max | K | https://reticulated.net/posts/how-to-record-better-iracing-replays/ |
| 8 | Cost while racing live: not measured by anyone I could find | G | - |
| 9 | Capturing while *playing a replay*: runs at the replay's play speed (real time at x1). Nothing says it is slower, faster or higher quality than live capture; replay graphics settings apply. SequenceDirector (open source, author left iRacing) records replays this way (Rewind, then Record) and says **replay spooling can make frame skips delay or stop short**. Spooling is ON here (`spoolingEnabled=1`) | K | SequenceDirector README |
| 10 | UI hiding by SDK: `CamSetState` (msg 2) with bit 0x08 `ui_hidden`; Paddock's REPLAY screen already does this (`replay.cs`) | C | pyirsdk; `docs\replay.md` |
| 11 | Replay jump by SDK: `ReplaySearchSessionTime` (msg 12, session number + ms), `ReplaySearch` (msg 5: lap +/- , incident +/- , start, end), `ReplaySetPlaySpeed` (3), `CamSwitchNum` (1). **Gotcha**: `IsReplayPlaying` reads false for ~300 ms after every seek, so wait/debounce before trusting it. `ReplaySetState` (6) only does "erase tape", never send | C (messages), K (300 ms) | pyirsdk; https://github.com/niklam/iracedeck/issues/1324 |
| 12 | Saving a replay: UI only (Replay tools > Save, or the scissors to cut). **No SDK message, no app.ini auto-save.** The only automatic thing is `askToSaveOnQuit=1`, which shows a question that someone must answer (here 0). Saved to `Documents\iRacing\replay\`; "replays must be saved prior to exiting the sim" | C (support), C (no auto key in app.ini [Replay]) | https://support.iracing.com/support/solutions/articles/31000147317-how-to-cut-and-save-a-replay ; https://traxion.gg/your-guide-to-utilizing-saving-iracing-replays/ |
| 13 | Loading a saved .rpy: UI only (Replay screen). No file association and no command-line switch found (`docs\replay.md`). Needs the same cars/track installed. Same-build limit: iRacing replay files are tied to the sim build that wrote them | K (build limit; no iRacing page found), C (no CLI) | `docs\replay.md` |
| 14 | `replayPatchRemoteCars=1` ("update remote car positions in replay based on server data") is ON, so other cars in a replay of a live race are corrected from server data | C (ini text); how well it works: K | `app.ini` |
| 15 | Tape lifetime: while the sim stays on the session, the tape (whole session, spooled to disk/RAM) is playable after the race, and earlier sessions of the same weekend are on it. Leaving the session / quitting the sim loses it unless saved. `playSecondsFromReplayEndOnCarExit=20` shows the replay is available the moment he leaves the car | C for ini text, K for the loss-on-quit rule | `app.ini`; support article above |
| 16 | `.rpy` size: nobody documents it; `SPEC-next` says 50-300 MB per race [G]. There are 0 `.rpy` files here. | G | - |

## 3. Facts from this PC (read-only)
- Sim 2.61.5.25, UI 8.17.0 (both built 2026-10-05). GPU **RTX 4080** (driver 32.0.16.1742); `nvidia-smi` present. The 4080 has hardware NVENC (H.264, HEVC, AV1) by spec [K]; encoder shows 0 % idle. Real test is `ffmpeg -encoders` after the download. AMD iGPU also present (not used).
- `Documents\iRacing` = `C:\Users\peter\OneDrive\Documents\iRacing`: **inside OneDrive**. `replay\` has 0 files (empty 2024 folders only), `videos\` 0, `screenshots\` 0, `telemetry\` 152 .ibt = 1.2 GB (oldest 2023-05, newest today). Anything iRacing writes to `videos\` would be uploaded by OneDrive: another reason not to use it for clips. C: has **368 GB** free.
- Sim window: `fullScreen=0`, one **windowed 7680x1440** triple surface at x -2560 (`rendererDX11Monitor.ini`), `EnableSMPSurround=1`. Good for desktop-duplication capture (windowed borderless is the case that works) [K]. It also means iRacing's own recorder sees a 5.33:1 picture: `videoImgSize=1` will give 1080p *at most*, so the middle screen alone would be tiny (about 640 px wide if it simply scales the whole surface) [G]. Test E1.
- No ffmpeg, no OBS on this PC. NVIDIA app is installed.

## 4. Options compared
| | Cost to race fps | Quality | Effort / new software | Risk | Peter must |
|---|---|---|---|---|---|
| **A. iRacing's own capture, live** | unknown, likely noticeable (frames are copied from the 3-screen render) [G] | 720p/1080p max, 30/60 fps, mp4, no sound, wide strip | small (SDK msg 13) | triple surface not cropped; module off; OneDrive folder | approve app.ini change + restart |
| **B. iRacing's own capture, on replay after the race** ("re-shoot") | **zero during the race** | same limits as A, but UI hidden, TV camera, chosen car | medium: drive replay by SDK | tape lost if sim quit; spooling can break seeks; capture size on triple unknown; needs "Peter away" | approve app.ini change; leave sim open; press MAKE CLIPS and walk away |
| **C. Paddock-run ffmpeg (`ddagrab` + `h264_nvenc`/`hevc_nvenc`) on the middle screen, rolling 10 s segments** (WS17 plan) | small, hardware encoder; expected 1-3 fps of 104 [G]; **must be measured** | 1440p60 at 12-16 Mbps, upright, any codec, can add audio later | medium (already specified) | rotated screen must come out upright (test E3); Windows can show a black frame in some fullscreen modes; ffmpeg crash needs a restart | approve one ~90 MB download |
| **D. C used on the replay (re-shoot)** | zero during the race | best: 1440p60, UI hidden, TV cameras, exact lap | C + the replay driver (SDK messages from section 6) | same tape and spooling risks as B | download yes (as C) + "Peter away" press |
| **E. OBS driven by its websocket** | like C | like C | bigger: a GUI app, scenes, its own settings | more moving parts than C; anti-cheat folder exists, game-capture hook behaviour with iRacing is community lore | download + install |
| **F. NVIDIA app Instant Replay** | hardware encoder, small [K] | good if it handles the wide window [G] | none to install; Peter's one-time overlay setup; hotkey (Alt+F10 save is the common default [K]) | no API: clip = "last N minutes" by hotkey only; no lap awareness; file naming/folder by NVIDIA; behaviour with a 7680-wide window unknown | one-time setup, press hotkey |

Sources for the tool facts: ffmpeg `ddagrab` + NVENC on-GPU path https://trac.ffmpeg.org/wiki/Capture/Desktop ; Instant Replay hotkeys are from consumer guides, not NVIDIA docs.

## 5. Recommendation
**Primary: C, with D as its premium mode.** Paddock's own hidden ffmpeg recorder on the middle screen (exactly WS17's "CHANGE 2026-10-10"), with telemetry sync by the wall clock.
Why: it captures *everything* as it happens (no dependence on the replay tape surviving, no app.ini change, no iRacing quirks), it is the best quality available (1440p60), and the same recorder
films replays, so "re-shoot my best lap with TV camera and no UI" costs nothing extra and needs no `vidCaptureEnable`.
**Fallback: B (iRacing's own capture on replays)** if Peter says no to the download or if C costs frame rate: needs one app.ini yes, nothing downloaded, zero cost while racing, but 1080p max and the wide-strip question.
(F, the NVIDIA app, is the no-download variant of "record live" but cannot cut a lap; use only if both fail.)

## 6. Flow (primary)
1. Peter says yes to the ffmpeg download once (Paddock does the rest).
2. When the sim runs and he is on track, irdash starts the recorder: middle screen, `ddagrab` -> NVENC, 10 s segments named by start time, BelowNormal priority, last ~3 min kept; stops when the sim exits. No keys, no focus.
3. On lap complete / finish irdash already knows the lap and `.ibt` time. For a PB, a top-3 or a KEEP press it cuts the segments covering the lap (no re-encode) into `vault\clips\` with start/end times in the moment record.
4. Optional **RE-SHOOT** (deck key "MAKE CLIPS", only when Peter presses it and walks away; sim must still be on the session): for each wanted lap irdash sends `12` (jump to the lap start minus 3 s) -> `1` (CamSwitchNum to his car, TV or chosen camera) -> `2` (hide UI) -> `3,1,0` (speed 1) -> recorder marks start -> wait until `ReplaySessionTime` passes the lap end (not `IsReplayPlaying`, see gotcha) -> pause `3,0,0` -> mark end -> UI back. Result replaces or sits beside the live clip.
5. Vault page plays the clip next to the track map; position = `LapDistPct` from the `.ibt`.

## 7. Exact requests for Peter (nothing was done)
- **Download** (primary): ffmpeg for Windows, ~90-100 MB, to `vault\bin\ffmpeg.exe`. "Okay to download ffmpeg (free video tool, ~90 MB) so Paddock can record your best laps?"
- **iRacing setting** (only for the fallback, and the real PHOTO key): "Okay to change iRacing's app.ini: `[Video] vidCaptureEnable=1` (and for fallback `videoImgSize=1`, `videoFramerate=0`, 1080p at 60 fps), then restart the sim?" Backup first via the existing `gfx-set.ps1` style.
- Optional: `askToSaveOnQuit=1` so a good race can be kept as .rpy (he answers a Yes box).

## 8. Risks
- Rotated screens: desktop duplication may give an upside-down or sideways picture; fix by a flip filter (CPU copy, small cost) [G].
- Tape lost when the sim is quit; spooling can break replay seeking; `IsReplayPlaying` blips after seeks.
- Rule 1: any re-shoot touches the sim; only on an explicit "Peter away" press, and not while `onTrack`.
- iRacing capture of a 7680x1440 surface: unknown crop/size.
- OneDrive: never point recordings into `Documents`.

## 9. Experiments for when Peter is away (all safe; reuse the `replay-test.ps1 -Live` AI race; log to `tests\`)
- **E0 (no app.ini change)**: AI race, spectate; record the tape, send `12` to a lap start, `3,1,0`, read `ReplaySessionTime` every 100 ms: how exact is the jump, how long until time moves, what does spooling do to it. Messages: 12, 5, 3, 1, 2.
- **E1 (needs app.ini yes)**: with `vidCaptureEnable=1`: `13,1,0` for 20 s in the live AI race, `13,2,0`, then the same on replay; check `VidCapEnabled/VidCapActive`, file in `videos\`, its size, resolution, fps, bitrate (ffprobe after download), picture content (full strip or one screen).
- **E2 (fps cost)**: 2-lap baseline vs recorder on (FrameView/`perf.cs` numbers), same car/track; stop if the 1 % low drops more than a few fps.
- **E3 (rotation + black frames)**: after the ffmpeg yes: 10 s `ddagrab` capture of the middle screen, check upright, correct colour, not black; also while the sim is on its replay screen and with HIDE UI.
- **E4 (re-shoot loop)**: record the section 6 step 4 loop on one lap; check start/end accuracy vs the `.ibt` lap times (target within 0.5 s).
- **E5 (tape after the race)**: finish an AI race, leave the car, wait 5 min, jump back to lap 1; then quit-to-menu and check whether the tape is gone.
