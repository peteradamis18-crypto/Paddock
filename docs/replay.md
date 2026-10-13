# REPLAY screen (WS15) - iRacing's replay without its menus

Peter, 2026-10-09: "a whole expanded and dedicated replay section bc the iracing nav is very confusing ... super intuitive".
Built 2026-10-10 (add-on 1.6.0.0). Spec: `docs\SPEC-next.md` WS15. Code: `dash\src\replay.cs` (irdash), `deck-intro\plugin.html`
(the screen, class `Replay`), `deck-intro\install.ps1` (profile `RigReplay`, action `com.peter.rigintro.replay`), MAIN key `5,1` in
`build-deck.ps1`. Test: `tests\replay-test.ps1`.

## What Peter sees (plain English)
Press **REPLAY** on the MAIN page. The deck turns into the replay screen. **BACK** (top left) returns to his keys.
Everything says what it does *now*; **gold = on / chosen**, green = "go", grey = nothing to do here.

| Row | Keys |
|---|---|
| 1 | **BACK** - the **timeline** (five keys wide: the session, the lap, how far from live, the speed, a marker; tap a fifth to jump there) - **SESSION** (practice / qualify / race on the tape) - **LIVE** (back to now) |
| 2 | **START** of the session - **LAP back** - **REWIND** (taps: x1, x2, x4, x8, x16 back, then normal; **one frame back** while paused) - **PLAY / PAUSE** - **FAST** (x2, x4, x8, x16, then normal; **one frame on** while paused) - **LAP on** - **SLOW MO** (1/2, 1/4, 1/8, then normal) - **BACK 10 S** (watch what just happened) |
| 3 | **INCIDENT back** - **INCIDENT on** - **MY CAR** - **CAR AHEAD** - **CAR BEHIND** (of the car being watched) - **LEADER** - **PICK CAR** (a list of all cars by position, tap one) - **MY LAST INCIDENT** |
| 4 | **CAMERA** (left half = previous, right half = next, the name is shown big) - **TV** - **COCKPIT** - **CHASE** - **AUTO TV** (iRacing's TV director) - **HIDE UI** - **PHOTO** (no menus, saved for the side screens) |

* **PICK CAR** shows 24 cars a page by position ("P3 #22 SMITH"); Peter is gold, the car being watched is dark gold, class colour on the key edge in multiclass.
* **While he is driving** (in the car and not watching a replay) every key is dim, the timeline says "GET OUT OF THE CAR TO WATCH REPLAYS" and irdash
  refuses the commands too. BACK always works.
* **Out of a session** the screen is **MY REPLAYS** (saved replays, newest first) with a plain note: iRacing opens those itself (see below).
* TV / COCKPIT / CHASE dim ("NOT HERE") when the track/car has no such camera group.

## How it works
* No clicks, no keys, no focus changes, no exe start per press. Each press is `GET /api/do?c=rp...` on irdash; `Replay.Do` sends iRacing SDK broadcast
  messages (`IRSDK_BROADCASTMSG`, `SendNotifyMessage(HWND_BROADCAST, id, MAKELONG(msg, var1), var2)`, packed like irdeck's `Bcast`) from a single worker thread
  (order kept, the answer to the deck is instant).
* `/replay` (JSON) is everything the deck draws: mode, speed, slow flag, session (name, number, length, marker, lap, laps, time from live), sessions on the
  tape, camera (group name, view number, count, auto TV, UI hidden, which of TV/COCKPIT/CHASE exist), watched car / my car / car ahead / car behind / leader,
  all cars by position, the PHOTO state, saved replays. The add-on keeps the last answer ready (while the REPLAY key is on the deck) and draws the screen at once
  when it opens; while open it asks every 0.6 s (0.22 s for 3 s after a press).
* **A press shows at once**: irdash answers `/replay` with what was just asked for (ReplayPlaySpeed, camera ...) for 1.5 s until the sim confirms, so the
  second tap of REWIND / FAST / SLOW MO builds on the first and the keys do not flicker.
* The same press again within 0.25 s is an echo and counts once (a deck can repeat a press).
* **Never sent**: `ReplaySetState` (message 6, erases the tape) - refused in the code. Only messages 0-5, 12, 13 can go out. Nothing writes iRacing's files or settings.
* While the test hook's pretend session is on, messages are **recorded** (`/api/test/replaylog`), never broadcast; PHOTO then uses `replay\test\shots` and
  `replay\test\mine` instead of the real folders.

## The messages (exact; `msg,var1,var2`; var1 is packed into the high word of wParam)
| Key | Sends |
|---|---|
| LIVE | `5,1,0` (ReplaySearch ToEnd) then `3,1,0` (speed 1) |
| START | `12,<session>,0` (ReplaySearchSessionTime, session time 0) |
| timeline fifth i (0-4) | `12,<session>,<ms>` where ms = session length x (i + 0.5) / 5 (the middle of that fifth) |
| SESSION | `12,<next session on the tape>,0` (wraps round) |
| LAP back / on | `5,4,0` / `5,5,0` |
| REWIND | playing: `3,-1,0` then -2, -4, -8, -16, then `3,1,0`; paused: `5,6,0` (PrevFrame) |
| FAST | playing: `3,2,0` then 4, 8, 16, then `3,1,0`; paused: `5,7,0` (NextFrame) |
| SLOW MO | `3,1,1` (1/2), `3,3,1` (1/4), `3,7,1` (1/8), then `3,1,0` |
| PLAY / PAUSE | paused: `3,1,0`; otherwise `3,0,0` |
| BACK 10 S | `12,<session>,<now - 10 s in ms>` then `3,1,0` (now = the replay time, or the live session time when live) |
| INCIDENT back / on | `5,8,0` / `5,9,0`, then `3,1,0` (play) |
| MY CAR / CAR AHEAD / CAR BEHIND / PICK CAR | `1,<car number raw>,<group + camera << 16>` (CamSwitchNum), keeping the camera on now (or TV1 when it is a scenic one) |
| LEADER | `0,-2,<group + camera << 16>` (CamSwitchPos, the SDK's "follow the leader") |
| MY LAST INCIDENT | (replaying: `5,1,0`) `5,8,0`, `1,<my number>,<group+camera>`, `3,1,0` - what the old REPLAY key did, on my car |
| CAMERA left / right | `1,<number of the car watched>,<group + camera << 16>` (CamSwitchNum), stepping through every view except the suspension / gearbox / roll-bar / gyro ones |
| TV / COCKPIT / CHASE | the same, with the group named TV1 / Cockpit / Chase in the session YAML |
| AUTO TV / HIDE UI | `2,<CamCameraState & 0x1FC with bit 0x10 / 0x08 flipped>,0` (CamSetState; the other bits stay as they are) |
| PHOTO | `2,<bits | 8>,0` (if the UI was not hidden), `13,0,0` (VideoCapture screenshot), then `2,<bits>,0` |

"Car number raw" is `CarNumberRaw` from `DriverInfo.Drivers` (iRacing's padded number: `#00` is 2000). Cars come from the session YAML, so the list, names and numbers are always the ones in this session.

## SDK facts: confirmed and not
Confirmed (from the SDK header as quoted by community wrappers, and by the mock test with a real race's YAML): message numbers and the packing; `CamSetState` bits
(0x08 UI hidden, 0x10 auto shot selection); `CarNumberRaw` is what CamSwitchNum wants; the YAML camera groups of this install (Nose ... Cockpit 9, Scenic 10, TV1-3 11-13, TV Static, TV Mixed,
Pit Lane 1/2, Blimp, Chopper, Chase 20, Far Chase, Rear Chase).
* **Slow motion**: raw value N with the slow-motion flag plays at **1 / (N + 1)**, and `ReplayPlaySpeed` reads back N (reported and verified by another Stream Deck
  plugin's author in the sim; matches what the spec guessed: 1 = 1/2, 3 = 1/4, 7 = 1/8). Normal speeds are not offset. **`replay-test.ps1 -Live` measures it again** (frames moved per second) and prints the numbers.
* **Not confirmed in the sim yet - the live test checks each and prints what it saw**:
  * Negative `ReplayPlaySpeed` rewinds (x1 ... x16) and `3,0,0` pauses; `5,6,0` / `5,7,0` step one frame while paused.
  * `ReplaySearchSessionTime` for START, the timeline, SESSION and BACK 10 S, and whether a session that is not on the tape is ignored.
  * **Incident search**: `PrevIncident` / `NextIncident` jump between incidents; in a calm AI race there may be none to find (the test then only says "accepted").
  * **CamSwitchPos vs CamSwitchNum**: CamSwitchNum with the raw car number is used for every named car. LEADER uses CamSwitchPos with -2 (follow the leader). **If LEADER
    does not land on the car in P1, change it in `replay.cs` (`case "rpleader"`) to `q.M(0, 1, Pack(g, cm))` (position 1) - the live test prints both numbers.**
  * Group 0 / camera 0 are never sent: every camera message carries the current group and camera (or TV1 view 1 when the current one is a scenic camera).
  * `ReplayFrameNumEnd` = frames from the end of the tape at 60 a second (used for "-2:14 from live"). Whether `IsReplayPlaying` is false at the live edge when you are out of the car is not known: irdash
    treats "replay playing at x1, in the live session, 5 frames or fewer from the end" as live too (the LIVE key goes gold, the strip says LIVE). The live test prints what the sim says after LIVE.

## The timeline
The strip shows the session being watched (RACE / PRACTICE / QUALIFY), "LAP 7 / 15" for the car being watched, "LIVE" or "-2:14 FROM LIVE" (or "12:30 INTO PRACTICE" in an older
session), the speed (x4, PAUSED, 1/2 SLOW ...), the watched car, and a bar of five pieces with a marker. Session length: the live session = the time it has now; an older one = the
longest time irdash saw while it was live; last resort = its time limit when it has a real one (not 24 h). If none of these is known the bar says "LENGTH NOT KNOWN YET" and the fifths do nothing.

## PHOTO
Hides the UI (unless it is already hidden), asks iRacing for a screenshot (`VideoCapture` 0), waits up to 12 s for a **new** picture in `Documents\iRacing\screenshots`
(png / jpg / bmp / tga; the file is done when its size stops changing), puts the UI back whatever happened, and **copies** the picture to `paddock\gallery\mine\me-<date>-<time>.<ext>`
when it is 2560 pixels wide or more. The original stays where iRacing put it. The key shows SNAP (working), SAVED (in the gallery), TAKEN (too small for the side screens) or NO PHOTO for ~5 s.
The size depends on iRacing's own screenshot setting (`[Video] screenshotFileFormat`, read only; the screenshots folder was empty on 2026-10-10, so the real size of one is not known yet).

## Saved replays (out of a session): how a .rpy opens
Researched 2026-10-10 (read-only):
* The sim's own **Replay screen** loads and saves them through its file dialog (strings in `iRacingSim64DX11.exe`: `IDS_RFDLG_SAVE_REPLAY`, `IDS_FD_ReplayFiles` = `*.rpy`, default folder `replay\`).
* **No Windows file association**: there is no `.rpy` key in the registry (only an Explorer "open with" history entry for Media Player, not an association).
* **No command-line switch found**: nothing about opening a replay in the sim's strings; `iRacingUI.exe`'s `app.asar` never mentions `.rpy`. The `iracing://` protocol is registered (`iRacingUI.exe "%1"`) but nothing documents a replay address; web searches found no documented way either.
* So the only way is iRacing's own Replay screen with a click path, which needs the sim running and UI automation (rule 4: not safe or reliable to guess blind). **Decision: MY REPLAYS lists them
  (name, date, folder: `Documents\iRacing\replay\<driver>\<series>\<week>\*.rpy`) and says "start iRacing and open it from the sim's own Replay screen". Tapping a replay does nothing.**
* The replay folder had no `.rpy` files on 2026-10-10 (only empty folders from 2024). `app.ini` has `askToSaveOnQuit=0`: iRacing does not keep a replay unless it is saved. **Recommendation for Peter (not changed by us):
  in iRacing's options, turn on "ask to save the replay when quitting" if he wants to keep races.** Date, track and car are not read from the file header (no sample file to study); the list shows the file name, its date and its folder.

## Tests
`tests\replay-test.ps1` (guard-protected; irdash must be the new build):
1. irdash with the pretend session (a real race's YAML, 20 cars, `CarIdxPosition_n=` style array values through the test hook): every key's exact message(s); labels' data for paused / fast / rewind / slow / live / driving / older session;
   refusals (driving, no session, bad arguments, pace car); optimistic cycling; echo guard; PHOTO with pretend folders; ReplaySetState never sent.
2. The deck screen drawn by the real add-on code in headless Chrome with the real `/replay` answers of part 1: all 32 keys in every view, every key's request, labels/gold per state, PICK CAR with two pages, MY REPLAYS; pictures `tests\shots\rp-deck-*.png`.
3. `-Live` (Peter away 10 minutes): `AI RACE LAST`, SKIP to the race, spectate without getting in, two minutes of racing, then every key through irdash, each checked by reading the sim's telemetry back
   (speed, slow flag, frame, session time, CamCarIdx, camera group, camera-state bits), measured playback speeds, a middle-screen picture per key (`tests\shots\rp-live-*.png`), a real PHOTO, then into the car to see the refusal, then QUIT TO MAIN.
Result 2026-10-10 00:35 (irdash rebuilt and restarted at 00:31, add-on code read from `deck-intro\plugin.html`): parts 1 and 2 **181 passed, 0 failed**. Part 3 (`-Live`) **not run yet**: Peter was racing / at the PC (the guard needs him away 10 minutes).
The multiclass rule (CAR AHEAD / BEHIND by class position) has no multi-class .ibt to test with, so it was checked in a scratch program that compiles `replay.cs` with a patched YAML (two classes: ahead / behind follow the class position, the class leader has no car ahead).
Also re-run after the changes: `tests\mydrive-test.ps1 -DeckOnly` 24 passed, `tests\deck-speed-test.ps1` 11 passed.

## Also changed (same add-on, same install)
* The add-on's display name is now **Paddock** (manifest, page title, profile tile labels). UUID, folder, action UUIDs and profile names are unchanged.
* The FRIENDS and MY DRIVE screens had **garbled signs** (the file had been saved with the wrong encoding: "Â·" instead of "·", "â˜…" instead of the star, the delete key, the minus, arrows, ...).
  Repaired in `plugin.html` (22 places); the new screen writes its signs as `\u` escapes.
* `Screen` (the base class of the live screens) learned `paint` (a screen draws a region itself: the timeline and the camera key), `extra` / `size` / `strip` (look key, bigger label, class edge colour), `noflash`, and passes the key column to `act`.

## Commands for the lead
```powershell
dash\build.ps1                          # only if irdash.exe is older than dash\src\replay.cs / irdash.cs (the 23:59 build already has WS15)
deck-intro\install.ps1                  # version 1.6.0.0 -> Stream Deck asks once: Peter clicks Install (adds the REPLAY screen profile, the name Paddock, the repaired signs)
# close Stream Deck, then:
build-deck.ps1                          # MAIN key (5,1) becomes REPLAY SCREEN; then start Stream Deck again (docs\OPERATIONS.md)
tests\replay-test.ps1                   # parts 1-2, any time the sim is not running
tests\replay-test.ps1 -Live             # part 3 too: only with Peter away 10 minutes; starts the real sim (AI race), ends with QUIT TO MAIN
```
