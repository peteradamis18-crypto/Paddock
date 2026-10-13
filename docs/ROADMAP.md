# PADDOCK — master roadmap (single source of truth)

Owner: Peter. Lead/spec: Claude (reviews every result). Builders: Grok Build (`grok-4.7-build-fast` for normal cards,
`grok-4.7` for hard ones), one task card per session — see `docs/TASKS.md` and `AGENTS.md`.
Written 2026-10-10 from: the whole build conversation of 2026-10-09/10, `docs/SPEC-next.md` (detailed specs WS1–WS19,
still the reference for detail), and Peter's "Paddock Roadmap and Handoff Note" (2026-10-10), adjusted by his answers.

## 0. What Paddock is, and the rules that make it great
Paddock turns a three-screen iRacing rig into a one-press experience for a disabled driver: the Stream Deck drives
everything, the top screen is a broadcast-style dashboard, the side screens show a calm photo gallery, and everything
about his driving (laps, clips, PBs, how he compares with the field and with real IMSA drivers) is saved and shown
without him ever having to think.
- **No thinking:** automatic first; one obvious button; plain words; nothing to configure; never ask what the system
  can work out. Optional controls live behind one EDIT / MORE button.
- **Never in the way while driving:** no popups, focus changes, restarts or deploys during a session. After the race is
  the time for questions — and even then a default happens if he ignores it.
- **Premium, not cheesy:** black/gold timing-screen look, Bahnschrift small caps, tabular numbers, hairlines; gold =
  his / chosen / best. No emoji, no gimmicks; the only glow is the flag glow.
- **Local first, cheap:** everything works offline on this PC; no paid APIs; downloads only with Peter's yes; cloud is
  a later, optional extra.
- **Proof, not claims:** every feature ships with a guarded test and screenshots; the lead looks at them.

## 1. What exists and works today (verified 2026-10-10)
| Area | What | Where | Tests |
|---|---|---|---|
| Deck MAIN page | 32 keys, one row per session phase | `build-deck.ps1` | actions-test |
| Paddock add-on 1.6.0.0 | intro, FRIENDS, OVERLAYS, MY DRIVE, REPLAY live screens; display name Paddock | `deck-intro\plugin.html` | friends/mydrive/replay/deck-speed |
| Action keys | QUIT TO MAIN (whole race), SKIP (with 2nd confirm), RESTART x2, GO, GET OUT, TOW, pit toggles | `src\actions.cs`, `irdeck.cs` | actions-test 29/0 |
| Friends mode | names typed on the deck, car/track/wheel, leaderboard | `src\guest.cs` | friends 19/0 |
| My Drive | pick car+track (recent, favourites, search), START → in the car | `src\mydrive.cs`, `dash\src\mydrive.cs` | mydrive 71/0 — **no MAIN key yet** |
| Overlays | irdashies control from the deck, presets, EDIT LAYOUT | `src\overlays.cs`, `dash\src\overlays.cs` | overlays-test (9 FAIL to investigate) |
| Delta bar | native, click-through; VS PB (all-time, default) / BEST / OPTIMAL / SESSION | `dash\src\deltabar.cs`, `refs.cs` | pbdelta 54/0 |
| Data tool | sessions page, lap analysis, pre-race brief, race extras (SoF, iRating), weekly progress, flag glow, sim priority High | `dash\src\data.cs`, `www\v2\sessions.*` | data-test (3 FAIL brief) |
| Benchmark | PB vs field (needs ≥30 drivers) and vs real IMSA (25 official refs) | `dash\src\bench.cs`, `data\pro-refs.json` | bench 49/0 |
| Performance | fps report every session, what stole frames, change markers, "did it help?", checklist, live fps | `dash\src\perf.cs`, `www\v2\perf.*` | perf 97/0 |
| Corners | numbered/named turns on every map, 32/43 owned tracks, offline | `dash\src\corners.cs`, `www\v2\corners.js` | corners 75/0 |
| Rig Doctor | checks + fixes itself (overlays, CrewChief, Stream Deck, OneDrive pin), frame-rate line | `dash\src\doctor.cs` | in overlays/data tests |
| REPLAY screen | SDK-driven replay control (no clicks) | `dash\src\replay.cs` | mock 188/0; **live 242 ok / 6 FAIL** (cameras, UI bits, MY LAST INCIDENT) |
| Side-screen gallery | 118 photos, SAME picture on both side screens, 120 s, 5 s fade, one small caption line, no branding, hidden while the sim runs | `dash\src\gallery.cs`, `paddock\gallery\` | gallery 85/0 |
| Safety | test guard, irdash test-hook refusal, deploy lock + mutex, dashboard defers reload while driving | `tests\guard.ps1`, `dash\build.ps1` | all tests |
| Test runner | `tests\run-all.ps1` (sequential, waits for a free rig), `tests\run-replay-live.ps1` | | |
| Tools | ffmpeg 9.0.2 (gyan essentials, verified) in `vault\bin\` | | |

## 2. Half-built (paused 2026-10-10 09:15 — compiles, NOT tested, NOT trusted)
| Item | State | Files |
|---|---|---|
| Vault V1 (saved laps/races) | large draft, unreviewed | `dash\src\vault.cs`, `www\v2\vault.*`, `tests\vault-test.ps1` |
| Official racing + race weekend + real-world calendar | draft | `dash\src\official*.cs`, `src\official.cs`, `www\v2\official.*`, `tests\official-test.ps1` |
| Recorder (ffmpeg) | designed only | spec WS17 'CHANGE 2026-10-10'; research `docs\vault-recording-research.md` |
| Studio (multi-camera replays) | designed only | spec WS19 |

## 3. Decisions (don't revisit without Peter)
- Recording = **Paddock's own ffmpeg recorder** (middle screen, GPU encoder, rolling buffer), not OBS, not the NVIDIA
  app. Re-shoots / beautiful multi-camera films come from **iRacing's own replay** driven by SDK messages (Studio).
- **Saving laps:** automatic (PB, top 10% for car+track, best 3 per combo, race top-3/win, big iRating gain). No
  popup while driving. **After the race** a calm review appears on the top screen ("3 laps saved — KEEP ALL / CHOOSE"
  with deck keys and a wheel button); ignoring it keeps them. A **wheel button** can be taught to mean KEEP / CLIP.
- **Storage:** local only for now (`vault\` on the SSD, budget 60 GB, keepers never pruned). Cloud (R2/B2) later,
  optional. Not in OneDrive (uploads would cost frame rate).
- **Pro comparison:** fully automatic — Paddock finds the closest real onboard video (IMSA, same track, same or
  closest car/class), aligns it to Peter's lap, and renders a side-by-side. Peter does nothing. Uses yt-dlp (approved
  in principle by Peter: "you pull in youtube and do cutting and rendering, I do nothing"); videos stay on this PC for
  his personal viewing, never re-uploaded. Labelled "real car vs sim — guide only".
- **Cosworth = Pi Toolbox** (Cosworth's analysis software; Lite is free for iRacing members and opens .ibt). Peter: "yes
  install cosworth and integrate with replay — it needs to be better than what we have now".
- **No headshot** for now. **No popups during a session.** **Gallery:** same picture both screens, very slow, no Paddock
  branding, minimal caption, no heavy motion blur.
- Graphics stay as settled (~104 fps race); performance work only measures and offers.
- Not wanted: lap art, results cards, live TV graphics, night mode, ambient lights, looping video, quotes gimmicks.
  Parked: coaching engine (WS10), racecraft (WS11), history (WS12).

## 4. The plan — phases and features (each phase has a gate; cards in docs/TASKS.md)

### Phase 1 — Make what exists solid (stability first)
1. **Green build + review the paused drafts** — decide keep/fix for vault.cs and official*.cs (C-01).
2. **Fix the failing tests** — data-test brief (3), overlays-test pretend-session block (9), bench link flake (C-02).
3. **REPLAY live fixes** — camera group switch (COCKPIT/CHASE/CAMERA >), CamSetState bits (AUTO TV 0x10, HIDE UI 0x08),
   MY LAST INCIDENT; confirm SDK facts in `docs\replay.md` (C-03, needs Peter away).
4. **Rig Doctor clears stray launcher error dialogs** (explorer-owned `#32770` titled with our app paths) and finds the
   cause (C-04).
Gate: `tests\run-all.ps1` all green; `replay-test.ps1 -Live` 0 FAIL.

### Phase 2 — The Vault: every great lap saved, with its data and video
Detail: SPEC WS17 (+ 'CHANGE 2026-10-10'), research doc. Cards C-05..C-09.
- **V1 data:** moments (lap / race / clip), auto-save rules above, untouched .ibt copy per keeper
  (`vault\telemetry\<car>\<track>\`), budget pruning, Vault page (grid with labelled-map thumbnails, filters, detail
  view: map + speed/throttle/brake/delta traces on one cursor, corner table vs PB, notes, OPEN IN COSWORTH, SHARE,
  DELETE x2), compare two laps.
- **V2 recorder:** ffmpeg `ddagrab` of the middle screen (x=0,y=0; the sim is one 7680×1440 window — capture the
  middle monitor only; screens are rotated 180° in Windows — output must be upright), `hevc_nvenc`, rolling 10-s
  segments with exact start times, only while the sim runs, BelowNormal; CLIP = last 30 s, KEEP = current lap; exact
  video↔telemetry sync; black-capture detection (exclusive fullscreen) with a plain-English fix; quality test with 3
  presets (contact sheet) and cost measured on the Performance page (recorder on/off per session).
- **After-race review** on the top screen (debrief area) + deck keys + **wheel button learning** (irdash reads the
  wheel's buttons via winmm `joyGetPosEx`; deck key "TEACH WHEEL BUTTON" → press the button → saved; that button then
  = KEEP while driving and = KEEP ALL after the race). Never a popup window; part of the existing top-screen page.
- **Player:** HTML5 video with Range streaming, map dot + trace cursor locked to the video, click a turn → seek.
Gate: a real practice session (Peter driving) produces a kept lap with clip + data; the Vault shows it; the player stays
in sync (≤ 0.1 s by the exact segment times); recorder costs ≤ 3 fps (Performance page).

### Phase 3 — Welcome screen and the visual system
- **Design tokens** (`www\v2\theme.css`): colours, type scale, spacing, card component — used by every page (SPEC WS9 P1–P3).
- **Driver card / welcome:** "PETER" (from the session YAML / Career), car number (read live — his number is 4 on the
  sessions page today; verify), team **Pratt Miller Motorsports**, the car he is driving now (live from the session)
  with a **car render**. Car art source, in order: (1) what is already on this PC (iRacing install / iRacing UI cache —
  read-only, research), (2) iRacing's public static images if reachable without login, (3) the Data API `car/assets`
  needs his login → ask Peter first (he signs in himself). Cache locally, no network after the first time.
- **WS9 polish** of the live dashboard and data pages (before/after screenshots for Peter).
Gate: with iRacing running, the welcome shows the right car render, name, number, team, offline after first launch.

### Phase 3b — Live TV view on the top screen (card C-22)
A deck key swaps the track map + pace/split panels for a live broadcast-style TV view drawn from telemetry (rotating
helicopter / chase / battle / leader shots, real car positions), other panels untouched. A real second iRacing camera
while driving is not possible from one sim (research confirms first). Real cinematic footage stays with Studio.

### Phase 4 — Studio: beautiful replays (SPEC WS19)
- **S0 automatic:** after a session (Peter away, sim still on it), Paddock films the best lap (race: short highlight
  reel) from iRacing's replay in CINEMATIC style → Vault "ready to watch".
- S1 auto-director presets (CINEMATIC / ONBOARD / BROADCAST) from the corner model; S2 mini editor (camera chips per
  segment, slow-mo, freeze, preview on the map, FILM IT); S3 optional burned-in overlays; S4 combine (side-by-side,
  PiP, this lap vs PB, title/end cards, crossfades); S5 race highlight reels (start, overtakes, incidents, finish).
Gate: a 1-lap CINEMATIC film of Road Atlanta from a real replay, ≥ 4 camera changes within 0.5 s of their cues,
upright, no UI.

### Phase 5 — Cosworth (Pi Toolbox) integration, better than today
- **Install:** find the official Pi Toolbox Lite download for iRacing members (Cosworth portal). If it needs Peter's
  login, he does that one step; the agent never enters credentials. Install through explorer.exe.
- **Integrate:** OPEN IN COSWORTH from the Vault/sessions/debrief opens the lap's .ibt (+ PB lap for comparison if the
  Toolbox can load two); a Paddock workbook/layout preset (channels: speed, throttle, brake, steering, gear, delta) set up
  for Peter so it opens ready (in the Toolbox's own user folder, never iRacing's).
- **Video with Cosworth:** research whether the Toolbox Lite can sync video (Pi Toolbox has a video sync feature in
  some editions); if yes, export the Vault clip + sync file so the clip plays inside the Toolbox; if not, Paddock's
  own analysis page becomes the "better than Cosworth" view: video + traces + map + corner table + PB + pro, all synced.
- **Better than today:** auto best-lap library (`Documents\iRacing\telemetry\best\` copy kept by the Vault), one press.
Gate: one press opens Peter's best lap ready to read (in the Toolbox, or Paddock's analysis with video).

### Phase 6 — Official racing, race weekend and the real-world calendar (SPEC WS8 R1–R8)
- Owned-only series (owned cars + this week's track), favourites (★), idle "Race weekend" panel (today, Sat, Sun;
  "est" for projected times; countdown to the top favourite), deck OFFICIAL screen (REGISTER / JOIN NEXT — never
  without his press). Source: public iRacing season schedule if reachable without login, else the iRacing app read
  via UI automation while he is away. Real-world calendar (IMSA first, WEC, F1, NASCAR, IndyCar, Formula E, GTWC) from
  official public calendars, local time, "you own this track" marker. Reuse the paused draft after review.
Gate: the idle screen shows this weekend's races he can enter + the real IMSA/WEC weekend, correct local times.

### Phase 7 — Pro comparison (automatic)
- **Find:** yt-dlp search (no API key; Google API only if yt-dlp fails — ask first) for "<track> onboard <car/class>
  IMSA <year>", prefer official IMSA/WEC/team channels, pole/qualifying laps, same car else same class (GTD/GTD Pro for
  GT3, GTP for prototypes), newest year; score and pick automatically; cache results; never spam requests.
- **Fetch:** download a 720p copy (video only) to `vault\pro\` for personal viewing; keep the source URL; never upload.
- **Align automatically:** compute a motion-energy curve of the onboard (ffmpeg frame differences at low res) and
  cross-correlate it with Peter's lap speed/brake trace (time-warped by track position) to find the lap start and the
  mapping; sanity-check with the pro's official lap time (`data\pro-refs.json`). If confidence is low, try the next
  candidate video; show "approximate" when unsure.
- **Render:** side-by-side (his clip | pro onboard) locked by track position (piecewise speed adjust so both reach each
  corner together), labels "PETER · 1:19.549 sim" / "<driver> · <time> real car", gap per corner, title card; saved in
  the Vault next to his lap. Black/gold, small type.
Gate: for Road Atlanta in the Corvette GT3 (his PB), Paddock produces the comparison video with no input, aligned
within ~0.5 s at three corners.

### Phase 8 — iPhone companion (PWA over Tailscale) and voice
- PWA served by irdash: rig/session status, live lap, Vault playback, save/keep, iRacing SDK commands (pit, replay,
  camera) from a fixed list, after-race review. Tailscale only (install needs Peter's yes), pairing token, no public
  ports, no shell, confirmation on anything destructive. Wake-on-LAN + launch rig (needs wired Ethernet + BIOS/adapter
  setting: Peter). **Never make the wheelbase live remotely** — the Simucube torque-off stays physical.
- Voice: iOS keyboard dictation into a Paddock text box → typed on the PC; short phrases ("save replay", "show last
  lap") matched to the fixed action list by rules (no paid model).
Gate: on cellular, open Paddock from the iPhone Home Screen, see live lap status, keep a lap, dictate a sentence.

### Always-on housekeeping (small cards between phases)
- **Deck batch** (lead runs the add-on install + build-deck once per batch; Peter clicks Install): REPLAY fixes,
  Vault keys (KEEP, CLIP, VAULT), PERFORMANCE, OFFICIAL screen, MY DRIVE key, TEACH WHEEL BUTTON, Studio "MAKE A
  REPLAY". **MAIN page has no free key** → WS7 MAIN refresh: the lead proposes one layout (never-pressed keys: RIG ON,
  OFFICIAL nav, SHOWCASE, TOW, SAVE/BACK RESET POINT, FAST REPAIR, TEAR-OFF, CLEAR PIT, SEAT ↓) and asks Peter once.
- **Docs:** `docs\ARCHITECTURE.md`, `docs\OPERATIONS.md` (build, deploy, test, recover), `docs\USER-GUIDE.md` (update:
  VS PB, benchmark, performance, gallery, replay, vault, studio) — Haiku/fast-model card.
- **Root tidy:** move one-click scripts and strays (`bktest.exe`, `irlearn.exe`, `lappcheck.txt`, `fail-go.png`,
  `learn-probe.txt`, `current-bindings.csv`) into `tools\` / `backup\` without breaking `keys\`, the irdeck path, the
  logon task "iRacing Rig" or Stream Deck profile paths.
- **Deck speed:** `tests\deck-speed-test.ps1 -Live` (and `-Boot` after a reboot) → timings into `docs\deck-speed.md`.
- **Performance:** confirm VS PB delta bar and the recorder cost on real races (Performance page before/after).
- **Gallery:** pick up Peter's own photos from the REPLAY PHOTO key (`paddock\gallery\mine\`).

## 5. Things only Peter can do (ask once, plainly, when the phase needs it)
- Install click for each deck add-on batch; approve the MAIN page layout (WS7).
- iRacing settings, if a feature needs them (each asked separately, never written by us): `[Replay] askToSaveOnQuit=1`
  (keeps replays when quitting), `[Video] vidCaptureEnable=1` (only if the PHOTO key or iRacing capture is needed).
- Cosworth portal login for the Pi Toolbox download (if required).
- Downloads already approved: ffmpeg (done), photos (done), yt-dlp + YouTube onboards for personal use (Phase 7).
  Still to approve when reached: Tailscale (Phase 8), any iRacing sign-in for car art (Phase 3, only if local art fails).
- Wake-on-LAN BIOS/adapter setting; wired Ethernet (Phase 8).

## 6. Open questions (lead resolves or asks)
- Is his car number 4 in every series, and should the welcome show "PETER" or his full name? (read from session YAML)
- Pi Toolbox Lite video support — research in Phase 5.
- Does the iRacing replay survive after the race until the sim closes? (research doc experiment E5 — Studio depends on it)
