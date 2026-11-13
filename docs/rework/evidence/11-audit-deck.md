# Audit 11: the deck side (irdeck, the add-on, the deck layout, the tests)

2026-11-13. Read-only audit. No file was changed except this one. Live checks were read-only: `irdeck-cli state`
(sim=False, ui=True, telemetry=off), timed GETs of the add-on's poll routes on irdash, the installed add-on's version
and hash, the live Stream Deck profile's manifests, `irdeck.log` (2026-10-20 to 2026-11-12) and `tests\last\`.

Severity words used below:
- **BREAKS** - Peter can press a key and get the wrong result, or no result, in normal use.
- **WRONG** - the code or the docs say one thing and do another; no harm seen yet.
- **FRAGILE** - works today, breaks on a small change, a timing, or an iRacing update.
- **CLEANUP** - dead or duplicated code, stale words. Costs time, not presses.

## Top findings

1. **BREAKS (likely)** - The Stream Deck saved the LEAVE page as the "current" page (profile manifest rewritten 12 Nov
   21:09, `Pages.Current` = the LEAVE page id). SHUT DOWN PC and SLEEP PC are one press with no confirm there; opening
   LEAVE used to be "the check". If the app opens on the saved page after a wake or a watchdog restart, the first
   stray press turns the PC off. Fix: SHUT DOWN / SLEEP on their own confirm screen (add-on, hold or second key), and
   send the deck back to MAIN on every Stream Deck start and every wake.
2. **WRONG** - The "0.7 s repeat guard" in CLAUDE.md and ARCHITECTURE.md does not exist. The real rule is: a repeat is
   dropped while the same key is still running (named mutex) or within **0.12 s** (1.5 s for three on/off keys). A key
   that finishes fast runs again. The log has 26 double runs within 1.5 s since 20 Oct (RESTART x11, GET IN x4, VAULT x4,
   GET OUT, QUIT TO MENU, FUEL TO FINISH, THANKS). All harmless so far only because the commands refuse or are idempotent.
   Fix: 0.7 s floor for every key except VOL / SPOTTER level / SEAT; correct the docs.
3. **BREAKS** - `key` commands skip the repeat guard completely (`verb != "media" && verb != "key"`). That covers GHOST
   (Ctrl+C toggle) and the seven sim boxes (RELATIVE, TIMING, STANDINGS, FUEL BOX, TIRE BOX, IN-CAR, WEATHER: F-key toggles).
   A doubled press opens and closes the box: the key "does nothing". Fix: exempt the two SEAT keys by name only.
4. **FRAGILE** - AI RACE and OFFICIAL never write `dash\start-mark.txt`, so `tests\guard.ps1` does not see "Peter is
   about to race" for the 10-40 s before the sim process appears. Only GET IN (mydrive start / startlast) and FRIENDS
   START mark it. Fix: `MarkStart` at the top of `airace start` and the official join.
5. **FRAGILE** - `irdeck state` says `telemetry=on` from the SDK header's "connected" bit only. It never checks that the
   tick moves (that code exists: `DeckTelemetryFresh`, used only by `smart`), prints no replay / session type, and
   prints telemetry without the sim process. After a sim crash the memory map can stay "connected" while CrewChief,
   irdash or irdashies hold it, which blocks deploys forever (safe side, but confusing). Fix: one `state` line with
   `fresh=`, `replay=`, `event=` and `telemetry=on` only when the sim process exists.
6. **FRAGILE** - The add-on never stops polling: on MAIN, 6 GETs every ~2.1 s (≈ 2.9 requests a second, ≈ 12 KB a cycle)
   to irdash, all day, also while Peter races. `/mydrive` is fetched every cycle even with no MY DRIVE key on screen.
   No `fetch` has a timeout: an irdash that accepts but does not answer freezes every opener key and every open screen
   (the "DASHBOARD NOT ANSWERING" message only appears when a fetch throws). Fix: one `/deck/summary` route, 5 s idle,
   2 s `AbortController` on every fetch.
7. **FRAGILE** - `build-irdeck.ps1` updates only the `keys\*.exe` copies whose hash equals the OLD `irdeck.exe`. A copy
   that was busy once (warning only) never matches again and stays old for ever. Today all 48 copies match. Fix: copy to
   every name in `keys.map`, retry busy ones, exit non-zero if any is left.
8. **WRONG** - Messages name keys that no longer exist: "press RIG ON" (the key says HOME), "use TOW TO PITS" (RESET CAR),
   "use QUIT x2 first" (QUIT TO MENU, one press). The top-screen table maps "press RIG ON" to "iRacing is not open", but
   `TdWhy` texts with "(press RIG ON)" reach the MY DRIVE screen as they are.
9. **CLEANUP** - Dead paths: the whole `confirm` / x2 arming path (no deck key uses it; its `ConfirmArmedFresh` reads
   `armed-confirm.txt`, a file that is never written, so it was always false), the add-on's ARMED 3-2-1 "state keys"
   (`smart`, `quit`, `restart`, `skip` are not in the add-on manifest, so `pollDeckState` and `/deck/state` never run),
   `DeckStateResolver` (used only by `smart --fake` in tests), `_csc-official.ps1` ("delete after gate").
10. **Tests**: 103 scripts, 41 in `run-all`, the newest full sweep on record is 12 Oct with about 120 FAILs across bench,
    phone, home, review, quickwins, video-page; `run-all.last.txt` is from 11 Oct. Most deck checks read the source with
    regexes rather than running it. Nothing tests the real add-on against the real irdash, a real Stream Deck restart, a
    real wake, YouTube export, or the deck's page after a restart.

## 1. A key press, end to end

```
Stream Deck "Open" action -> keys\<name>.exe (copy of irdeck.exe, no arguments)
  -> reads keys\keys.map line "<name>=<command>"
  -> kids-mode gate (DeckRules.KidsAllows)
  -> repeat guard (Local\irdeck-key-<name> mutex + %TEMP%\irdeck-<name>.last stamp)
  -> Run(command): iRacing SDK broadcast / memory map, UI Automation in iRacingUI, pixel clicks in the sim,
     SendInput keys, Core Audio, HTTP to irdash 127.0.0.1:8199
  -> irdeck.log line; LastLog -> SayResult -> /api/keymsg (top-screen one-liner); beep on rc != 0
Add-on live screens: plugin.html -> GET /api/do?c=... -> irdash whitelist -> irdash acts or starts irdeck.exe <args>
```

| # | Where a press can go wrong | Severity | One-line fix |
|---|---|---|---|
| 1.1 | Repeat guard is 0.12 s + "while running", not 0.7 s (see top finding 2). 175 repeats were dropped, 26 got through. | WRONG | 0.7 s floor; keep mutex. |
| 1.2 | `key` and `media` verbs have no guard at all: GHOST, 7 sim boxes, MUTE (media mute toggles Windows' master mute). | BREAKS | Exempt only `seat-up` / `seat-down`. |
| 1.3 | `irdeck.exe <args>` (from irdash, add-on, tests) never runs the guard; `tag` is only set for key copies. The add-on has its own 0.7 s filter, but only for 11 listed toggle actions (`ONCE_ACTS`); everything else on a live screen can double. | FRAGILE | One guard in irdash's `/api/do` for every command, by command + argument. |
| 1.4 | `keys.map` unreadable or name missing: beeps 300 Hz and returns 1. No top-screen message (no `KeyId`). | FRAGILE | Say "This key is not set up" through `/api/keymsg`. |
| 1.5 | Kids mode on: every key but 5 says "Kids mode is on". HOME within 4 s of KIDS unlocks. Covered by `kids-test`. | ok | - |
| 1.6 | Stream Deck delivers presses 2-3 times (seen 29 ms to 1.06 s apart). Toggle keys (`appvol mute`, `pittoggle`, `ac toggle`) get 1.5 s. | ok | - |
| 1.7 | A key exe is busy when `build-irdeck` runs: that copy keeps the old exe and is never updated again (top finding 7). | FRAGILE | Copy by `keys.map` names. |
| 1.8 | `WithNamedLock` keys (restartrace, tow) return rc 4 for a second press, no beep: correct. | ok | - |
| 1.9 | irdash down: keys that only talk to irdash (`dash vault`, `dash debrief`, `showcase`, `spot`) log "not reachable" and beep; the top-screen message cannot show (it goes through irdash). | FRAGILE | A two-tone "dashboard is down" beep pattern. |
| 1.10 | Wrong window: every sim keystroke (`SendCombo`) is sent to the foreground window after `FocusWindow`; `CmdKey` refuses unless the foreground process is the one asked for. GET OUT / TOW / RESTART check `FocusWindow` returned true. | ok | - |
| 1.11 | Wrong window: `Press()` falls back to a raw mouse click at the element's rectangle with no foreground check when the control has no Invoke/Select pattern. 0 such clicks in the log (85 presses, all Invoke). | FRAGILE | Route the fallback through `TdClick` (foreground + point check). |
| 1.12 | QUIT TO MENU clicks Quit at a pixel offset (no foreground re-check before each of up to 3 clicks); `CancelStrayDialogs` clicks Cancel pixels with no foreground check; `ConfirmDialogs` re-focuses but does not re-check. `ClickPrevNext` does it right. | FRAGILE | One `SimClick(x, y)` that checks: sim in front, car not on track, then clicks. |
| 1.13 | Messages naming old keys (top finding 8). | WRONG | Replace the three strings. |

### Every UI-automation click path (CLAUDE.md rule 4: verify before every click)

"Invoke" = UI Automation InvokePattern (no mouse). "Pixel" = mouse click at a computed screen point.

| Command (key) | File:line | What it presses | How | Verified first? | Notes |
|---|---|---|---|---|---|
| `tdsetup` card click (GET IN with a new car/track) | testdrive.cs:987 `EnsurePanel` | Car or Track card picture | Pixel via `TdClick` | Yes: `DialogOpen` (Last settings + Close/Back + Test Drive links), cards read, then `TdClick` checks sim not running and the UI owns the point | Offsets −60/−110 and −200/−110 from the info buttons: breaks if iRacing moves the cards. |
| `tdsetup` search box | testdrive.cs:1008, 1097 | Search edit | Pixel `ClickEl` + typing after `TdFront` | Yes: panel title "Set Car/Set Track" found; typing only if iRacing is in front | - |
| `tdsetup` row Select | testdrive.cs:1025 | "Select" cell of the matching row | Pixel `ClickEl` | Yes: row must be within 400 px under the search box (on screen), owned, matching name | - |
| `tdsetup` damage switch | testdrive.cs:1259 | toggle-switch | Invoke, falls back to `ClickEl` | Yes: panel open; switch state read from screen pixels (green) | Invoke path skips `TdClick`'s "sim not running" check. |
| `tdsetup` layout menu item | testdrive.cs:1328 | layout menu item | Invoke, falls back to `ClickEl` | Yes: menu read after the track card shows the track | Same as above. |
| `TdOpenDialog` | testdrive.cs:1051 | sidebar "Test Drive" button | `CmdNav` (Invoke by name, whole UI) | Partly: only pressed when "Last settings" is not visible; dialog verified after | - |
| `ClearBlockingPopup` | testdrive.cs:922 | Esc key | key | Yes: only when the UI tree has < 10 controls, only once, only with iRacing in front | - |
| `airace` (AI RACE) every press | testdrive.cs:148 `AiPress` | AI Single Player, Single Race, Last Settings / New Race, wizard steps, Select, Continue, Race, Close/Back | Invoke, falls back to `ClickEl` | Yes, the strictest path: an allow-list of ids/names (`AiPressAllowed`), New Race / Race / Continue only when a flag is raised for that step, modal scoped (`AiModal`), sim-not-running check before each press | Good model for the rest. |
| `airace` search typing | testdrive.cs:213 | car/track search box | `SetFocus` + typed keys | Yes: the Search box inside the car/track select panel only (3 exist), `TdFront` | - |
| `airace level` slider drag | testdrive.cs:464 | skill slider handle | Raw mouse drag | Yes: modal present, track wider than 100 px, sim not running, UI owns both points | - |
| `smart` GET IN (session screen) | irdeck.cs:829 `GoDriveOnly` | sim's "Drive" button | Invoke | Yes: state re-read twice, exactly one enabled Drive + a Garage button, no Continue modal, sim in front | Good. |
| `go` (TOW, RESTART in Test Drive, startlast) | irdeck.cs:809 `CmdGo` | sim's green button | Pixel from colour search (`FindGreen`) | Partly: sim focused, session active, not on track; no "is it the session screen" check | Clicks the first big green blob on the centre screen. |
| `go` with no session | irdeck.cs:862 `GoUi` | "Test Drive" link, or any button named Join / Race / Start / Drive / Continue | Invoke by name, whole UI tree | **No dialog check for the Join/Race/Continue branch** | Not on a deck key today (deck uses `smart`), but reachable through `irdeck go`. Generic names could hit the wrong control. |
| `nav` / `ui` (OFFICIAL, startlast) | irdeck.cs:501 `CmdUi`, 936 `CmdNav` | a control by name anywhere in the UI | Invoke, raw-click fallback | **No dialog check** (by design: page links) | Raw-click fallback has no foreground check (1.11). |
| `startlast` | irdeck.cs:1033 | Test Drive button, then "Last settings" link | Invoke by name | Partly: the link name is unique to the dialog | - |
| `testdrive` | irdeck.cs:1948 | "Test Drive" launch link | Invoke | Yes: dialog = Last settings + Close/Back links | - |
| `quitmain` (QUIT TO MENU, SHUT DOWN, SLEEP) Quit button | actions.cs:319 | session bar "Quit" | Pixel offset from the bar anchor | Partly: sim focused once before the loop, `EnsureBar`, screenshot; no foreground check before each try | 1.12. |
| `quitmain` / `restartrace` / `skip` dialogs | actions.cs:254, 265 `ConfirmDialogs` | "Restart current session" option, the coloured confirm button | Pixel at the detected button | Yes: dialog recognised from screen pixels (shape, dark panel, Cancel label), car not on track; re-focus without re-check | Recognition is by pixels; a theme change breaks it. |
| `CancelStrayDialogs` | actions.cs:282-283 | Cancel of a left-over question | Pixel (−108 px from the found button; fixed +43/+98 for the select dialog) | Partly: dialog recognised; **no foreground check** | 1.12. |
| `LeaveToHome` | actions.cs:443-461 | results Back / X, dialog Close/Back, Home link | Invoke | Yes for results (`SafeResultsClose`); dialog Close/Back picked from the whole tree ("last" match) | - |
| `restartrace` / `skip` Prev / Next | irdeck.cs:1272 `ClickPrevNext` | session bar Prev / Next | Pixel offsets from `irdeck.prevnext` | Yes: car stopped or out, sim focused, foreground re-checked right before the click, screenshot saved | Good. Offsets measured once by hand. |
| `simclick` | irdeck.cs:2291-2296 | bar buttons, dialog Yes/Cancel | Pixel | Partly: session active, car not on track, focused; no dialog check for `quitnow`'s blind "Yes" click 0.9 s later | Not on the deck; test/manual tool. |
| `spot save/back`, `pause`, `getout`, `tow` | spot.cs:70-118, irdeck.cs | Ctrl+Shift+F1/F2, Pause, Esc hold | keys | Yes: sim focused | - |
| `guest` (FRIENDS) keys | guest.cs:143, 565 | sim keys through `CmdKey --sim` | keys | Yes: foreground must be the sim | - |

Log evidence: 85 Invoke presses, 0 raw-click fallbacks, 0 "covers the click spot" refusals since 20 Oct.

## 2. How irdeck decides the state

| Signal | How it is read | Where it can be wrong or stale |
|---|---|---|
| `sim` | `iRacingSim64DX11` process exists | The UI pre-loads the sim in the background, so sim=True does not mean a session. |
| `ui` | `iRacingUI` process exists | A hidden or minimised UI still counts; `CmdUi` restores it. |
| `telemetry` | `Local\IRSDKMemMapFileName` opens and header status bit 1 is set (`Tele.Open`) | No tick check in `state`. The map lives as long as any reader holds it (irdash, CrewChief, irdashies, SimHub). A crash can leave the bit set. |
| `onTrack`, `speed`, `onPitRoad`, fuel | the newest of the 4 buffers by tick | Read once; no re-read if iRacing writes that buffer during the read (torn read possible, rare). |
| session type / AI | session YAML regex (`EventType: Test|AI`, `CarIsAI: 1`) | YAML can lag the session change by a second or two; RESTART refuses ("only AI races") in hosted sessions. |
| fresh | tick moves within 0.9 s (`DeckTelemetryFresh`) | Only used by `smart` (GET IN). Costs up to 0.9 s per call. |
| replay | `IsReplayPlaying` | Only read by `smart`. |
| "about to race" | `dash\start-mark.txt` < 10 min old (guard.ps1) | Not written by AI RACE, OFFICIAL, RACE NOW, the phone. |

`state` is the single thing every safety rule depends on (CLAUDE.md rule 1, `build-irdeck.ps1`, `install.ps1`,
`deck-speed-test`), yet it is the least careful reader: one line, no freshness, no replay, no session type, telemetry
not tied to the process. `guard.ps1` does not call `state` at all (process + start mark only). Two definitions of
"busy" exist: `Sdk.RealBusy()` in irdash and `Get-RigBusy` in guard.ps1. They should be one rule served at
`/rig/busy` and used by both.

## 3. The add-on (deck-intro\plugin.html, install.ps1)

**Size and shape.** One file, 1855 lines, 120.7 KB, plain JS, SDK 2. Installed version 1.8.9.0, byte-identical to the
source. One base class `Screen` (layout from regions, look-string cache, PNG per key, poll loop, offline message,
press flash, 0.7 s toggle filter) and 9 screens as singleton subclasses: Friends (≈155 lines), Overlays (≈90),
MyDrive (≈340), Replay (≈215), Analysis (≈190), Sound (≈100), Ac (≈90), AiLevel (≈60), Races (≈100); plus `RigDoctor`
(object, no key on any page), the intro animation and the dead state keys. Shared drawing is real (the base class
draws every key). Copied: six colour tables (`FCOLORS`, `OCOLORS`, `MCOLORS`, `RCOLORS`, `ACOLORS`, `SNDCOLORS`) with
the same `sel/go/stop/amber/grey/banner` entries; every screen repeats `keyTick/open/exit/poll` boilerplate; the
opener-key icon drawing is repeated per screen.

**Exit keys differ by screen:** FRIENDS: EXIT top-right (7,0). REPLAY, ANALYSIS: BACK TO KEYS top-left (0,0), grey.
OVERLAYS, SOUND, AC, AI LEVEL, RACES: EXIT bottom-right (7,3), red. MY DRIVE: BACK (0,0) and EXIT (7,3) and sometimes
EXIT at (7,0). The offline screen always offers EXIT at 7,3. Fix: one EXIT at 7,3 on every screen.

**Polling (requests to irdash).**

| Situation | Requests | Rate |
|---|---|---|
| Idle, MAIN showing | `/showcase`, `/overlays`, `/guest`, `/mydrive`, `/replay`, `/api/rec/races` | 6 per ~2.1 s ≈ 2.9 /s; ≈ 12 KB per cycle (measured sizes 38 B to 6.5 KB, 12-43 ms each) |
| Idle, MORE showing | `/showcase`, `/mydrive`, `/workbench/state`, `/sound?peek=1`, `/ac` | 5 per ~2.1 s ≈ 2.4 /s |
| Idle, LEAVE showing | `/showcase`, `/mydrive` | ≈ 1 /s |
| Screen open | its own `poll()` every `interval` (Analysis 500 ms, Overlays/Replay 600, others 700, Races 1500) and 220 ms for 3 s after any press; the 2 s loop keeps running for the other keys | Analysis: `/workbench/state` + `/debrief/state` every 0.5 s, + `/vault/item` + `/vault` every 6 s ≈ 4 /s, ≈ 9 /s after a press |
| While Peter drives | same as idle; nothing pauses | - |

`/mydrive` is fetched every cycle even when no MY DRIVE / CAR TRACK key is visible (it carries the speed-test trigger
and the auto-open flag). `AiLevel` has no `keyTick` in the loop. All waits run on a worker timer (good: the hidden
page's own timers are throttled).

**Key-picture cost.** Each look is drawn once on a 768x384 canvas, cut into 96 px tiles, PNG-encoded, kept (max 400
looks). Measured in the plugin log: AC first open 401 ms to all 32 pictures (32 drawn), second open 42 ms (all cached);
Overlays 118 ms from cache. Replay's timeline changes every second, so its keys are re-encoded continuously while open.
Opener keys are redrawn only when their text changes.

**When irdash is down.** Opener keys keep their last picture with no sign that it is stale. An open screen shows
DASHBOARD NOT ANSWERING after 4 failed polls (about 3 s) with EXIT at 7,3, and recovers by itself. A hung irdash (TCP
accepted, no reply) is not caught: `fetch` has no timeout, `await` never returns, the whole 2 s loop and the open
screen freeze. Presses on a screen log "irdash not reachable" and do nothing visible.

**When the Stream Deck app restarts.** The page reloads: all screen state, caches and the intro `seq` are lost (the
intro does not replay, `seq` starts null). If the deck was on a `Rig*` profile the tiles reappear and the screen redraws
from its first poll. If it was on `RigIntro`, any key returns to the previous profile. MY DRIVE may auto-open itself
(see below). Stream Deck restarts on the saved page of "iRacing GT3": today that is LEAVE (top finding 1).

**After PC sleep.** `dash\src\deckwatch.cs` + `irdash.cs Watch`: a wake (wall clock minus unbiased clock > 15 s) waits
up to 20 s for the deck on USB, then kills and starts StreamDeck.exe, then waits up to 20 s for "Device connected". A
"Device disconnected" that is the last log word for 2 s also restarts it; "never connected after 25 s" too; 30 s
cooldown; skipped while `dash\deck-build.lock` is fresh. Not gated on driving (correct: a dead deck mid-race is worse).
Covered by `deckwatch-test.ps1` (rules only, no real restart).

**Other add-on findings.**

| # | Finding | Severity | Fix |
|---|---|---|---|
| A1 | MY DRIVE switches the whole deck to its screen by itself when `/mydrive` says `aiStatus = NO CHOICE` (AI RACE with no car chosen). A screen that moves without a press; no driving check in the add-on. | FRAGILE | Only irdash decides, and never while `RealBusy`. |
| A2 | No fetch timeout (above). | FRAGILE | `AbortController` 2 s. |
| A3 | Opener keys show stale state when irdash is down. | FRAGILE | Grey the opener key after 3 failed ticks. |
| A4 | State keys (`smart`, `quit`, `restart`, `skip`), `paintStateKey`, `pollDeckState`, `/deck/state`: not in the manifest, never on a page. `RigDoctor` action: in the manifest, on no page. | CLEANUP | Delete or put on the deck. |
| A5 | `build-deck.ps1` writes add-on keys with plugin name "Rig Intro" version 1.1.0.0 (installed is "Paddock" 1.8.9.0). Stream Deck tolerates it today. | CLEANUP | Write the real name and `$ver`. |
| A6 | `install.ps1` refuses only on `telemetry=on`, not on sim running or a recent START. | FRAGILE | Use the shared busy rule. |
| A7 | Every add-on change needs Peter to click Install in Stream Deck, and the install restarts Stream Deck. | process | Batch add-on changes; one Install a week at most. |

## 4. The deck layout (build-deck.ps1, tools\deck-refresh.ps1)

**How it is built.** `build-deck.ps1` writes three pages (LEAVE, MAIN, MORE, in that page order) of profile
`65E017A2-...` plus a hidden empty Default page, one exe per key in `keys\`, `keys\keys.map`, and deletes key exes not in
the map. It refuses while Stream Deck runs. `tools\deck-refresh.ps1` (guarded) holds `dash\deck-build.lock`, kills
Stream Deck, builds, restarts it, and checks the log for "Prune orphaned page" / import errors; up to 4 tries, because
Stream Deck has pruned MAIN after a build before (18 and 23 Oct). `-Preview` renders pictures to `%TEMP%` and **also
overwrites `docs\deck\main-preview.png`** (a tracked file) on every `keys-test` run.

**What Peter must do by hand after a change.** MAIN/MORE/LEAVE: nothing, if the lead runs `deck-refresh.ps1` while the
rig is free (Stream Deck is closed and reopened for him). Add-on: click Install in Stream Deck (Stream Deck restarts).
AI LEVEL appears on MAIN only once the installed add-on has that action, so a deck rebuild must follow an add-on
install. Key exes: `build-irdeck.ps1` while no session runs.

**Stale words in build-deck.ps1:** "Keys that end something ... need a second press (x2)" (no key does), "-Preview
only renders C:\Temp\preview" (it is `%TEMP%\PaddockPreview-*`), "MORE page (MORE / BACK keys switch pages)" (three
pages now), comment "iRaceDeck plugin (Session Info)" live keys (none used).

### Key map today, with press counts

Counts are runs in `irdeck.log` from 20 Oct to 12 Nov (they include test presses, e.g. `deck-v2-live`); add-on keys
are not in that log (n/a).

**MAIN** (32 of 32 cells used)

| Row | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| 0 start | HOME `rigon` (3) | AI RACE (12) | AI LEVEL (add-on) | CAR TRACK (add-on) | OFFICIAL (1) | FRIENDS (add-on) | KIDS (19) | MORE (page) |
| 1 session | GET IN `smart` (95) | GET OUT (93) | RESET CAR `tow` (11) | RESTART (82) | NEXT SESSION (40) | RACE NOW (5) | PAUSE (3) | LEAVE (page) |
| 2 pit / screens | FUEL TO FINISH (3) | TIRES (2) | FAST REPAIR (1) | CLEAR PIT (2) | OVERLAYS (add-on) | REVIEW `dash debrief` (**0**) | RACES (add-on) | REPLAY (add-on) |
| 3 sound / practice | VOL − (128) | VOL + (116) | MUTE SPOTTER (15) | SPOTTER − (27) | SPOTTER + (24) | SAVE SPOT (2) | BACK TO SPOT (1) | GHOST `key --sim ctrl+c` (3) |

**MORE** (23 keys): BACK, SORRY (0), GOOD RACE (0), MUTE `media mute` (0), SHOWCASE (0), SOUND (add-on), LOCK (1) /
RELATIVE F3 (0), THANKS (2), WIPE (0), SEAT LOWER (0), SEAT HIGHER (0) / TIMING F1 (1), STANDINGS F2 (0), FUEL BOX F4
(0), TIRE BOX F5 (0), IN-CAR F8 (0), WEATHER F11 (0), ANALYSIS (add-on) / AC (add-on), AC COOLER (4), AC WARMER (3),
VAULT (8).

**LEAVE** (6 keys): BACK, QUIT TO MENU x2 cells (40 + 7), KIDS MODE (0), SHUT DOWN PC (9), SLEEP PC (8). 26 empty cells.

**Add-on profiles** (each a 32-tile page drawn by plugin.html): RigIntro (animation), RigFriends, RigOverlays,
RigMyDrive (opened by CAR TRACK), RigReplay, RigAnalysis, RigSound, RigAC, RigAiLevel, RigRaces. RigRaces lists 24
races a page; with 2 races, 27 keys are black (phase 1 picture).

### Duplicated or confusing keys

| Problem | Keys | Evidence |
|---|---|---|
| Three "start" keys | GET IN, AI RACE, RACE NOW (+ NEXT SESSION moves toward the race) | GET IN already starts the last drive with no session. RACE NOW = NEXT SESSION repeated until Race (5 presses). |
| One volume control on five keys | VOL −, VOL +, MUTE SPOTTER, SPOTTER −, SPOTTER + | Plus a SOUND screen on MORE that does all of it, plus MUTE on MORE (Windows master, 0 presses). |
| Four doors to "after the drive" | REVIEW (0 presses), RACES, REPLAY, and on MORE: ANALYSIS, VAULT | Phase 1: names do not tell them apart. |
| Same key twice | KIDS (MAIN 19, LEAVE 0), QUIT TO MENU (two cells, same command, two exes) | - |
| Names that mean nothing to a new reader | GHOST, SAVE SPOT, BACK TO SPOT, CLEAR PIT, WIPE, IN-CAR | - |
| Sim hotkeys named like screens | RELATIVE, TIMING, STANDINGS, FUEL BOX, TIRE BOX, IN-CAR, WEATHER | 1 press in 3 weeks; double-press toggles them back (finding 3). Tire box against Peter's "no tyres" decision. |
| Ending keys without a check | SHUT DOWN PC, SLEEP PC, LOCK | One press; deck may reopen on LEAVE. |
| Mixed exits | BACK (MORE, LEAVE), EXIT / BACK TO KEYS / BACK (add-on screens) | - |
| Colour groups not visible | build-deck draws six colours; phase-1 preview shows gold on black only | `main-preview.png` uses a different renderer from the real icons. |

### Proposed MAIN after the rework (cuts and merges)

Principle: one key per job, grouped by when Peter needs it, and nothing that ends the PC on any page he can land on.

| Row | Proposal |
|---|---|
| 0 before | HOME/RIG ON - **DRIVE** (GET IN, also starts the last drive) - **AI RACE** (one add-on screen: car/track + AI level + START; folds AI LEVEL and CAR TRACK) - OFFICIAL - FRIENDS - KIDS - (spare) - MORE |
| 1 in session | GET OUT - RESET CAR - RESTART - **TO THE RACE** (NEXT SESSION and RACE NOW merged: practice -> qualify -> race; in Test Drive it ends the drive) - PAUSE - SAVE SPOT - BACK TO SPOT - LEAVE |
| 2 pit | FUEL TO FINISH - TIRES - FAST REPAIR - CLEAR PIT - BEST LAP CAR (was GHOST) - (spare) - (spare) - (spare) |
| 3 sound + after | VOL − - VOL + - **SPOTTER** (one key: tap mutes/unmutes, the SOUND screen has the level) - SOUND (screen) - OVERLAYS - REPLAY - **MY RACES** (RACES + REVIEW: list of drives, each with REVIEW / WATCH / SHARE) - (spare) |

Cuts: REVIEW key (0 presses; folded into MY RACES), SPOTTER −/+ (into SOUND), MUTE (Windows master), SHOWCASE,
SORRY/GOOD RACE (0 presses; keep THANKS if wanted), seven sim-box F-keys (1 press total; keep one RELATIVE if Peter
asks), SEAT LOWER/HIGHER (0; move to SOUND-style "SETTINGS" screen if wanted), WIPE (0), KIDS MODE on LEAVE, the second
QUIT exe (a Stream Deck key cannot span two cells, so keep the two-cell target but point both cells at one exe).
Move: ANALYSIS and VAULT off the deck (top-screen doors); AC to MORE only. LEAVE: QUIT TO MENU big, SHUT DOWN and SLEEP
behind a confirm screen; BACK. Every add-on screen: EXIT at 7,3.

## 5. Tests

### Inventory

Columns: in `run-all`; rig needs (none = offline; hook = uses irdash's test hook, needs irdash deployed and no session;
away = `-NeedAway` / Peter idle 10 min, starts the sim or clicks in iRacing); last recorded result in `tests\last`
(most are from 12 Oct, the last full sweep); time where recorded. "src-grep" = most checks are regexes on source text.

| Test | Covers | run-all | Rig needs | Last result / time | Notes |
|---|---|---|---|---|---|
| ac-screen-test | AC add-on screen, headless Chrome + pretend irdash | no | none | - | deck-harness |
| ac-test | Midea AC: ac.py, `irdeck ac`, keys | no | none (reads files) | - | src-grep for build-deck / install |
| actions-test | every deck ACTION key end to end in real sessions | yes | **away**, starts the sim | 12 Oct: 0 passed, 1 failed | Stale; never green on record. |
| ailevel-screen-test | AI LEVEL add-on screen, headless | no | none | - | - |
| ailevel-test | AI LEVEL data + wiring | no | none | - | src-grep |
| airace-live | AI RACE wizard on the real UI | no | **away** | - | live helper |
| airace-test | AI RACE wizard pieces | no | **away** | - | - |
| analysis-test | lap analysis engines on .ibt copies | yes | none | 130/0 | - |
| audio-test | recorder sound | no | away, hook | - | - |
| bench-test | benchmark panel | yes | none (deploy) | 12 Oct: 58/32 FAIL | broken on record |
| brakepoint-test | brake point rule | no | none | - | - |
| bugsweep-static-test | 18 Oct bug sweep | no | none | - | src-grep, no guard (by design) |
| career-test | CAREER page | yes | hook | 129/0, 52 s | - |
| cars-test | car pictures | yes | hook | 42/2, 20 s | - |
| coach-test | coach route on old .ibt | no | none | - | - |
| confirm-test | x2 arming / bounce | no | none | - | **dead feature** |
| copy-audit-test | banned words on every screen | yes | none | 37/0, 121 s | - |
| corners-test | corner model | yes | hook | 75/0 | - |
| cosworth-test | Pi Toolbox open button | no | hook | - | - |
| dash-perf-test | dashboard frame cost | no | none | - | - |
| data-test | sessions page, lap analysis | yes | hook | 130/0 | - |
| data-truth-test | numbers vs raw .ibt | no | none | - | - |
| debrief-test | debrief engine + page | no | none | - | not in run-all |
| deck-behaviour-test | one-press keys: rules compiled from `deckrules.cs`, `irdeck-cli` dry runs, source checks | no | none | - | half src-grep; tests the dead confirm path ("quit-main still arms") |
| deck-screens-test | ANALYSIS, SOUND, RACE SETUP screens headless + irdash side | yes | none | 220/0 | - |
| deck-speed-test | add-on open speed (`-Live` opens real screens) | yes | none / live | 11/0 | **no guard.ps1** (own `state` check only) |
| deckstate-test | DeckStateResolver | no | none | - | tests code used only by tests |
| deck-v2-live | every one-press key through its real key exe | no | **away**, starts the sim | - | the only true end-to-end deck test; not in run-all |
| deckwatch-test | wake / USB-blip rules | no | none | - | rules only |
| df8-flags-test, df8-simhub-engine-test | flag box script | no | none | - | no guard (offline) |
| dialog-links-test | Test Drive dialog Close vs Back | yes | none | 7/0 | - |
| doctor-test | Rig Doctor | yes | none | 10/0 | - |
| drive-v1-test | calm in-car screen | no | none | - | - |
| friends-live-test | friends mode, live part | yes | **away**, hook | - | - |
| friends-test | friends mode | yes | none | 19/0 | - |
| gallery-test | side-screen gallery | yes | **away**, hook | 85/0 (11 Oct) | - |
| gpsmap-test | GPS track maps | yes | none | 15/1 FAIL | - |
| guard-lock-test | test lock | yes | none | 6/0 | - |
| harness-check-test | Check helper | yes | none | 4/0 | - |
| home-test | HOME page | yes | hook | 99/6 FAIL | - |
| home-v3-test | HOME v3 states | no | none | - | - |
| hud-flag-test | `tools\hud-flag.ps1` | no | none | - | no guard |
| identity-test | recording <-> session | no | none | - | - |
| iracing-maps-test | iRacing track drawings | no | none | - | no guard |
| journey-check | after a real session: drive -> recording -> review -> video | no | none (reads results) | - | manual, after Peter drives |
| keymsg-test | top-screen key message | no | none | - | - |
| keys-test | every key answers; layout via `-Preview` | yes | none | **101/0, 12 Nov** | the only deck test run this month; src-grep heavy; rewrites `docs\deck\main-preview.png` |
| kids-test | kids mode | no | none | - | - |
| lockup-test, log-bugs-test | analysis fixes | no | none | - | - |
| mydrive-test | My Drive (`-DeckOnly` in run-all) | yes | away for live part | 27/0 | - |
| official-test | official racing | yes | none | 191/0 | - |
| overlays-test | overlays screen, delta bar | yes | hook | 74/0 | - |
| page-audit-test | top pages vs running irdash | no | none | - | - |
| pagehost-test | page open/close | no | none | - | - |
| pbdelta-test | VS PB delta | yes | hook | 59/0 | - |
| perf-test | frame-rate report | yes | hook | 95/2 FAIL | - |
| phone-test | iPhone app | yes | hook | 200/1 (218/32 in INT run) | - |
| pickname-test | car name matching (compiles `BestRow` cut out of testdrive.cs by regex) | no | none | - | **no guard**; breaks if the code is reformatted |
| pro-tools-test | PRO page | yes | none | 109/1, 51 s | - |
| quickwins-test | C-29 fixes | yes | hook | 36/8 FAIL | - |
| race-field-test | race field log | yes | hook | 112/1, 127 s | - |
| races-page-test | MY RACES page | no | none | - | - |
| races-screen-test | RACES add-on screen | no | none | - | - |
| race-truth-test, raw-data-test | race numbers, ALL THE DATA | no | none | - | - |
| realworld-test | F1 calendar | no | none | - | - |
| recorder-fps | recorder frame cost | no | **away**, starts the sim | - | - |
| recorder-safety-test | two recorder bugs | no | none | - | - |
| recorder-test | recorder with a made-up screen | yes | hook; real-screen part away | 192/1, 522 s | slowest test |
| reload-test | dashboard reload rules | no | none | - | - |
| replay-jump-test | SEE IN iRACING | yes | hook | 30/0 | - |
| replay-test | REPLAY screen (`-Live` real AI race) | yes | hook; live away | 188/0 | - |
| restart-spotter-test | RESTART retry + spotter | no | none | - | src-grep |
| review-test | after-race review | yes | hook | 57/9 FAIL | - |
| rig-leftovers-test | P5 leftovers | yes | hook | 73/0, 23 s | - |
| session-review-test | Session Review | yes | none | - | no tally line on record |
| share-test | share studio (ffmpeg overlay) | yes | hook | 54/0, 91 s | - |
| spot-test | practice loop | no | none | - | - |
| spotter-guard-test | spotter guard | no | none | - | no guard; src-grep |
| tow-wait-test | RESET CAR waits for the car | yes | **away** | 26/0 | - |
| trackmap-test | /trackmap | no | none | - | - |
| tv-live-race-test, tv-test | TV view | tv-test yes | hook | 46/1 FAIL | - |
| units-test | mph / km/h | no | none | - | - |
| vault-test | Vault | yes | hook | no tally on record | - |
| video-page-test | VIDEO page | yes | hook | 93/6 FAIL, 99 s | - |
| workbench-test | Analysis workbench | yes | none | no tally on record | 121 KB, largest |
| helpers | guard.ps1, run-all.ps1, deck-harness.ps1, deck-mock.js, deck-fixtures.ps1, drive-fixtures.js, phone-layout.js, shot.ps1, run-replay-live.ps1, _csc-official.ps1 | - | - | - | `_csc-official.ps1` says "delete after gate" |

Totals: 103 `.ps1` + 3 `.js` files, 41 in `run-all`. Recorded run time of the sweep is not stored; the recorded parts
add up to well over 20 minutes (recorder alone 522 s, 1138 s in the lead's run).

**Flaky or stale.** actions-test (never green on record), bench (32 FAIL), quickwins (8), review (9), video-page (6),
home (6) on the last sweep; `run-all.last.txt` is from 11 Oct; deck-behaviour and confirm-test still test the x2 arming
nobody uses; deck-v2-live and pickname name "LAST DRIVE"; keys-test's own header says "writes only C:\Temp\preview";
deck-mock.js only knows the FRIENDS / OVERLAYS / MY DRIVE profiles (the newer screens use the same harness with their
own fixtures). About 180 regex-on-source checks in the five deck tests alone (keys 35, deck-behaviour 59, deck-screens
31, kids 35, keymsg 16 `-match` / `Get-Content -Raw` sites): they fail on a rename and pass on a behaviour bug.

**No test at all for:**
- the add-on against the **real** irdash (every screen test uses pretend answers), including irdash slow or hung;
- a real Stream Deck restart, a real wake from sleep, the page the deck opens on afterwards;
- `build-deck.ps1` for real + `deck-refresh.ps1` (only `-Preview` is tested), and `install.ps1`;
- the repeat guard itself (a doubled `keys\x.exe` start 0.3 s apart), the `key` exemption;
- `irdeck state` (crash-left map, frozen tick, replay);
- `build-irdeck.ps1`'s key-copy update;
- recorder end to end on a real session (only after the fact: `journey-check`), YouTube export (`raceexport` is only
  checked as "the add-on sent the command");
- QUIT TO MENU / SHUT DOWN / SLEEP on the real sim (only in `actions-test`, never green).

### Proposed test pyramid for the rework

1. **Fast offline, every build (< 60 s total, safe while Peter races).**
   - Pure C# rules compiled on their own (the `deckrules.cs` pattern): repeat guard decision, kids allow-list, state
     resolver, click-path pre-checks as pure functions (`CanClick(simFront, onTrack, dialogSeen)`), message table.
     Move logic out of `Program` into small static classes so tests compile files, not regex-cut snippets.
   - `keys.map` / layout contract: one JSON layout file read by `build-deck.ps1`, the add-on and the test (no regex on
     the build script). Checks: every key has a command irdeck knows, labels fit, no duplicates, no PC-ending key on a
     page reachable without a confirm.
   - Add-on unit tests: load `plugin.html` in headless Chrome with `deck-mock.js`, drive `build()` of each screen from
     fixture JSON, assert regions (EXIT at 7,3 everywhere), and snapshot the 32 PNGs.
2. **Mock-irdash screen tests (a few minutes, no rig).** A tiny pretend irdash (PowerShell `HttpListener` on a
   different port) serving recorded real JSON from every route, plus fault modes: 500, slow (5 s), hung, down. Run every
   add-on screen through open -> press every key -> exit, and assert the request rate (idle ≤ 1 /s after the fix) and
   that a hung irdash shows DASHBOARD NOT ANSWERING within 3 s. Same pretend irdash for `irdeck dash ...` commands.
3. **Nightly self-check on the real rig, only when idle** (`Assert-RigFree -NeedAway`, 03:00, at most 10 minutes):
   `irdeck state` sanity; press 5 real key exes in dry mode (`--dry`) including GET IN, QUIT TO MENU, RESTART;
   start a Test Drive with `smart`, GET OUT, RESET CAR, QUIT TO MENU (the `deck-v2-live` path); check the deck profile
   still has its pages and opens on MAIN; one recorder minute and its file; write one line to `tests\nightly.txt`
   that HOME can show as "Rig check: all good / 2 to look at". Everything else stays in layers 1-2.

## Files read

`CLAUDE.md`, `AGENTS.md`, `docs\ARCHITECTURE.md`, `docs\rework\evidence\01-current-screens.md`, `src\irdeck.cs`,
`src\testdrive.cs`, `src\actions.cs`, `src\deckrules.cs`, `src\deckstate.cs`, `src\keymsg.cs` (parts), `src\overlays.cs`
(parts), `deck-intro\plugin.html`, `deck-intro\install.ps1`, `build-deck.ps1`, `build-irdeck.ps1`,
`tools\deck-refresh.ps1`, `dash\src\deckwatch.cs`, `dash\src\irdash.cs` (watchdog part), `tests\guard.ps1`,
`tests\run-all.ps1`, `tests\deck-harness.ps1`, `tests\deck-mock.js`, headers of every test, `keys\keys.map`,
`irdeck.log`, `tests\last\*`, the plugin logs, the live profile manifests.
