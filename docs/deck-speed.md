# Stream Deck speed (2026-10-09)

Peter: "make stream deck load more quickly". Two things were slow: (1) the screens of our add-on (FRIENDS, OVERLAYS, and now MY DRIVE) reacted late or not at
all, and (2) the deck after Windows starts. Measurements first, then what changed, then what is still open.

## 1. The screens (add-on `deck-intro\plugin.html`, version 1.5.0.0)

### Why they were slow
The add-on page is a hidden background page in the Stream Deck app. Chrome slows `setTimeout` / `setInterval` in such a page to **about once a second**
(reproduced: a 100 ms interval in a background tab fired 10 times in 7 s), and the lead saw once a minute after a long time hidden. Only OVERLAYS and the intro
had been moved to the worker's timer. FRIENDS still used `setInterval(700)` for its refresh and `setTimeout` for the press flash and the "look again after a press".
Found while measuring: the press flash of FRIENDS **never worked** (the white flash compared a region object that `draw()` had just thrown away), so a press
showed nothing at all until the next slow refresh.

### What changed
- **Every wait goes through the worker's timer** (`sleep()` / `later()`); the only `setTimeout` left is the worker's own and the fallback inside `sleep()`
  (`deck-speed-test.ps1` counts them: 2).
- **A screen is drawn at once from the last state it knew.** The pollLoop keeps `/guest`, `/overlays` and `/mydrive` fresh every 2 s and pre-makes the 32
  key pictures; the FRIENDS / OVERLAYS / MY DRIVE key sends the profile switch *first* (it no longer waits for irdash) and paints each key from the cache
  the moment the deck says it appeared.
- **Presses show immediately**: white flash on the key, and the choice (gold) switches at once; irdash confirms 0.2-0.7 s later. Follow-up looks after a press
  run every 0.22 s for 3 s.
- **No PNG work for unchanged screens**: every key has a "look" string; a PNG is encoded once per look and kept (max 400). An open screen that nothing changes
  makes **0** PNGs (old: 256 per 8 s on FRIENDS, 384 on OVERLAYS) and re-sends no key.
- **Timing lines in the plugin log** (`%APPDATA%\Elgato\StreamDeck\logs\com.peter.rigintro0.log`): `perf friends open: press -> profile switch sent .., first key
  appeared .., first picture sent .., all 32 pictures sent ..` and `perf friends screen closed: N refreshes in S s ..`.

### Numbers (harness: `tests\deck-speed-test.ps1`)
The real add-on page runs in headless Chrome inside a **background tab** (real Chrome timer slowing) with a pretend Stream Deck app around it
(`tests\deck-mock.js`) that takes **150 ms** to show a profile after being asked. **150 ms is an assumption** - the real app's time is not known until the new
add-on is installed (then `deck-speed-test.ps1 -Live` / `-Log` read it from the real deck). Old = the installed 1.4.0.0 (kept in `tests\deck-speed-baseline\`).

| measured in a background tab | old 1.4.0.0 | new 1.5.0.0 |
|---|---:|---:|
| FRIENDS: press -> profile switch asked | 27 ms | 0 ms |
| FRIENDS: press -> first key picture | 214 ms | 152 ms |
| FRIENDS: press -> all 32 key pictures | 217 ms | 168 ms |
| OVERLAYS: press -> all 32 key pictures | 186 ms | 170 ms |
| MY DRIVE: press -> all 32 key pictures | (new) | 171 ms |
| FRIENDS: a press first changes its key | 895 ms | 1 ms |
| FRIENDS: white press flash | never | 1 ms, ends 316 ms |
| FRIENDS: the chosen wheel turns gold | 895 ms | 316 ms |
| FRIENDS: looks again, per 8 s open (biggest gap) | 8 (1011 ms) | 16 (715 ms) |
| OVERLAYS: looks again, per 8 s open (biggest gap) | 12 (671 ms) | 18 (609 ms) |
| PNG key pictures made per 8 s open, FRIENDS / OVERLAYS | 256 / 384 | 0 / 0 |

Reading it (run-to-run variation is about 20 ms): the first picture is dominated by the Stream Deck app's own profile switch (the 150 ms); our part shrank from ~40-60 ms to 2-20 ms. The big gains are what
you feel after the screen is up: a press shows at once instead of after the next slow timer tick, and an idle open screen no longer burns CPU re-encoding pictures.
**Not reproduced:** Chrome's "once a minute" slowing after 5+ minutes hidden did not appear in headless Chrome 154 (the old add-on's press was answered 513 ms after the press even after 5.5 minutes hidden: `-Long`), so the table is the 1 s case; with the 1 per minute slowing the old add-on would be much worse, the new one
is not affected (worker timers).

## 2. Windows start -> Stream Deck keys usable

### Measured (3 boots of 2026-10-09, from `irdeck.log` and the Stream Deck logs)
| | 12:28 boot | 12:36 boot | 19:52 boot |
|---|---:|---:|---:|
| Windows started -> `rigon --boot` begins (logon task) | 12.4 s | 12.5 s | 10.2 s |
| `rigon` begins -> Stream Deck process created | 3.8 s | 3.6 s | 3.9 s |
| process created -> deck connection up ("Application event loop start") | 27.9 s | 27.4 s | 25.2 s |
| ... of which: process start -> its own log opens | 8.1 s | 8.4 s | 7.9 s |
| deck keys usable (device attached) after Windows start | 44.6 s | 43.8 s | 40.1 s |
| our add-on connected (intro can play) | - | - | 46.0 s |
When the same app is restarted alone, with everything else already running, it is up in **1.0-3.5 s** (restarts at 15:50, 16:27, 16:39, 16:45, 17:32, 20:49).
So about 25 of the 27 s are boot-time contention: `rigon` starts irdash (+ its Chrome kiosk), Simucube Tuner, ButtKicker, irdashies, CrewChief and the iRacing UI
(Chromium) within 0.5 s of the Stream Deck app, all loading from a cold disk at once, on top of what Windows itself starts (OneDrive, the Elgato volume plugin).

### Changed (in our control): `rigon --boot` gives the Stream Deck app the machine first
After starting Stream Deck, `rigon --boot` now waits for its pipe `\\.\pipe\com.elgato.streamdeck.local` (the app opens it the moment it is ready for keys and
plugins; max 30 s), then 1.2 s more, and only then starts irdash, the wheel/haptics apps, irdashies, CrewChief and the iRacing UI. Logged as
`rigon: Stream Deck is ready after N s - starting the other programs` (or `... not ready after 30 s - starting the other programs anyway`).
Kill switch: create an empty file `boot-stagger.off` in `C:\Users\peter\iRacingDeck` and the old all-at-once start is back.
**Unverified**: this needs a Windows restart to measure and I must not restart the PC. What to expect: deck up after ~5-10 s instead of 27 s (cold disk, nothing
else loading); the iRacing UI then appears about when it did before or somewhat later. After the next boot run `tests\deck-speed-test.ps1 -Boot`: it prints the
timeline (Windows start, rigon, Stream Deck ready, add-on connected) from the logs. If it turns out worse, add `boot-stagger.off`.

### Not changed: the startup intro
It starts when the add-on connects (46 s after Windows start in the boot above) and runs 7.2 s; any key press ends it at once. That is deliberate and unchanged.

### Recommendations for the lead (Windows / startup; I changed none of these)
1. **Defender exclusions** for `C:\Program Files\Elgato\StreamDeck` and `%APPDATA%\Elgato\StreamDeck`: the app spends 8 s between "process created" and its first log
   line even when nothing else runs yet, which looks like a cold read and scan of its Qt/Chromium files. A security trade-off; only worth it if `-Boot` still shows
   > 15 s after the stagger. (Hypothesis, not measured.)
2. **Two starters**: Stream Deck is in `HKCU\...\Run` ("Stream Deck", `--runinbk`, enabled) *and* started by `rigon`. The second instance quits at once
   ("Another Stream Deck instance is running ... Quit!"), so it is harmless; leave it.
3. Still enabled in `HKCU\...\Run`: OneDrive and the Elgato "Volume Controller" watcher. Teams, Edge and Copilot are already disabled (StartupApproved).
4. `rigon` begins 10-12 s after Windows starts: that is the Windows logon itself; nothing to gain in our scripts.

## 3. Tests and how to re-measure
- `tests\deck-speed-test.ps1` - harness above (12 checks), `-Long` (5.5 min hidden), `-Boot` (boot timeline from the logs), `-Log` (your own presses'
  timing lines), `-Live` (asks the installed add-on, through irdash `/api/do?c=mdspeedtest&a=friends|overlays|mydrive`, to open each screen once; the deck flips to
  it for ~6 s and back; reads the real timing lines from the plugin log).
- Needs after the Install click (Peter or the lead): `deck-speed-test.ps1 -Live`, then paste the three `perf ... open` lines under section 1 as the real numbers.
