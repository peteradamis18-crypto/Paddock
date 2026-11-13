# Rework status (kept by the lead; one line per card)

Legend: spec = written in `docs/rework/cards/`; built = builder reported done; merged = on `main` (commit);
deployed = on the rig; live = the live checks in the card were run by the lead; Peter = needs his yes or his click.

## Wave 0
| Card | State | Notes |
|---|---|---|
| W0-1 deck safety | merged 609d766, exes + irdash deployed 2026-11-13; add-on 1.9.1.0 installed by Peter 2026-11-13 16:00 (Stream Deck log: "[com.peter.rigintro] Plugin connected"); `tools\deck-refresh.ps1` built MAIN 32 / MORE 23 / LEAVE 6 keys first try, 0 import errors, no "LEFT OFF" warning, `keys.map` lost `power off`/`power sleep`; live: StreamDeck.exe killed → the watchdog brought it back in 12 s on MAIN, and again with the profile left on MORE ("watchdog: deck page before the start of Stream Deck: set"); `state` prints the new line and guard.ps1/build.ps1 read it. Still owed: Peter presses SHUT DOWN PC once (the YES must vanish by itself; that first command also moves `deck-secret-new.txt` to `deck-secret.txt`) | review: 8 findings fixed (arm window + header on shutdown/sleep, key copies refuse power, doubled-press, hung on every screen, kids feedback, atomic manifest, end-to-end power test); 8 new tests pass (deckguard 35, confirm 18, hung 11, profile 21, layout 16, build-irdeck 7, state-line 21, deckwatch 23); confirm screen, MAIN on wake, 0.7 s guard, fetch timeouts, state line, build-irdeck copy, dead deck paths |
| W0-2 RigState + guards | merged 2d89b81, deployed 2026-11-13 | review: 8 findings fixed (null-origin secret, more guards, phone token, adapters); rigstate 44/0, session-guards 146/0; add-on secret arms after Peter's Install click |
| W0-3 stop work in sessions | merged, deployed 2026-11-13 | review: 9 findings fixed (z-order raise, second PB, raw scans via Proc, write ceiling, yields, FinishSession re-queue, drain at exit, mydrive cache, Held race); jobs 39/0, load test 25/0 (avg CPU 1.2 % of a core, max write 1 KB, 0 deletes, 0 scans in a replayed session) |
| W0-4 delete the dead | merged cfc09cd | dead-code 49/0, home-v3 88/0, drive-v1 94/0, pagehost 17/0; kept /analysis/lap, /gallery, CLI test modes, ShadowPlay (own card later); irdeck dry probe → W0-1 |
| W0-5 state push | merged, deployed 2026-11-13 | review: 8 findings fixed (stream self-reconnect, version hash, HEAD, watcher, trace, guest, recorder lag, reconnect count); state-push 37/0, request-rate 19/0: HOME idle 0.03/s (was 15.7), driving 0.7/s (was 11.4), Analysis 0.87/s (was 19), deck 0.17/s (was 2.9); add-on part = last commit (1.9.1.0) |
| W0-6 lap truth | merged, deployed 2026-11-13 | review: 8 findings fixed (live judge harness reproduced the PB-reference miss first); laprules 61/0, lap-truth 64/0; laprules 53/0, lap-truth 30/0; 12 Nov = 10 laps, 7 counted (not 9: lap 1 never taken by iRacing, laps 6 and 7 incidents), best 1:33.832 lap 9 everywhere |
| W0-7 design.css + lint | merged c715ace, deployed 2026-11-13 | lint 13/0, format 36/0, races-page 21/0; Peter chose B, the broadcast gold #C9A24B: default everywhere since 2026-11-13; deck keys follow at the next deck rebuild (W0-1) |
| W0-8 test tools | merged 23dc889 | tools-test 65/0; .ibt has no CarIdx arrays (field fixtures need a recorded live stream: wave 2); live replay deferred to the W0-3 sandbox server (a pretend session on the live irdash wakes the recorder and the deck) |
| W0-9 black box v1 | merged 4a19186, deployed 2026-11-13 | review: 7 findings fixed (UI-thread refresh, snapshot noise, GPU rule, old caps, v1 honesty, lock, test); blackbox 24/0, perf-verdict 41/0; verdict names lap 9, 23.7 fps; cost 0.1-0.4 % of a core; sentence shown twice on Performance (tidy in W5-1) |
| W0-10 photos / YouTube guide / Delta | merged faf561d, deployed 2026-11-13 | photo-order 4/0, youtube-guide 14/0; cause: gallery sorted by name then shuffled; live: watch the side screens (pending); Delta: real-race method added as primary |

## Live checks still owed by the lead
- DONE 2026-11-13 16:07–16:11 (log): the side screens showed `r2-001`, `r2-002`, `r2-003` on both screens, 120 s apart.
- MY RACES on the real top screen with `design.css` (served: yes, 2026-11-13).
- Pages after the W0-4 deploy (2026-11-13, browser pane): HOME, Sessions, Coach, Vault, MY RACES, Analysis, in-car demo load with no
  console error except the browser's own `/favicon.ico` 404 (never existed; harmless).

## Peter does
- Sign in to Codex again (its session expired 2026-11-13: "Please log out and sign in again"); until then the Opus cards get an
  independent Opus reviewer instead of Codex.
- DONE 2026-11-13 16:00: Peter clicked **Install** (add-on 1.9.1.0); the lead ran `tools\deck-refresh.ps1` and the watchdog checks (W0-1 row).
- Peter: on the deck go to LEAVE and press **SHUT DOWN PC** once, then press nothing: the gold YES must disappear by itself after
  5 s and the PC must stay on. That one press is also what tells irdash the new add-on is installed (`dash\deck-secret.txt` appears;
  log: "the Stream Deck add-on is installed with its secret"). Until then a page with no origin is still let through (logged hourly).
- `tests\kids-test.ps1` and the other `-NeedAway` live tests wait for 10 min with no keyboard or mouse (Peter away from the PC).
- 2026-11-13 16:07 small fix deployed: the every-minute passes (perf reports, gain, field laps backfill) are `Jobs.Routine` now, so
  `irdash.log` no longer gets two "jobs: … ran (waited 0.0 s, took 0.0 s)" lines a minute (they still log when they wait or take ≥ 1 s);
  the watchdog line read "before the start start" (jobs-test 58/0). Seen in the log, not wave 0: the gallery stops and restarts itself
  within 2 s when Windows briefly reports 1 race screen instead of 3 (8 times since 11 Nov, also 15:59 today during the deck rebuild).
- Live checkout tests 2026-11-13 after W0-5: keys-test 136/0, mydrive-test -DeckOnly -Offline 27/0 (its log slice was bytes-vs-chars, fixed),
  photo-order 4/0, dead-code 49/0, design-lint 14/0; perf-test -Offline 51/1: the one failure is the 2 Nov "Overlays changed" marker
  tripping an old check (pre-existing, not wave 0). HOME idle in the browser pane after the deploy: one stream, no polling at all.
