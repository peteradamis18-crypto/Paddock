# Rework status (kept by the lead; one line per card)

Legend: spec = written in `docs/rework/cards/`; built = builder reported done; merged = on `main` (commit);
deployed = on the rig; live = the live checks in the card were run by the lead; Peter = needs his yes or his click.

## Wave 0
| Card | State | Notes |
|---|---|---|
| W0-1 deck safety | merged 609d766, exes + irdash deployed 2026-11-13; add-on 1.9.0.0 waits for Peter's Install click, then build-deck | review: 8 findings fixed (arm window + header on shutdown/sleep, key copies refuse power, doubled-press, hung on every screen, kids feedback, atomic manifest, end-to-end power test); 8 new tests pass (deckguard 35, confirm 18, hung 11, profile 21, layout 16, build-irdeck 7, state-line 21, deckwatch 23); confirm screen, MAIN on wake, 0.7 s guard, fetch timeouts, state line, build-irdeck copy, dead deck paths |
| W0-2 RigState + guards | merged 2d89b81, deployed 2026-11-13 | review: 8 findings fixed (null-origin secret, more guards, phone token, adapters); rigstate 44/0, session-guards 146/0; add-on secret arms after Peter's Install click |
| W0-3 stop work in sessions | built, under review | jobs 39/0, load test 25/0 (avg CPU 1.2 % of a core, max write 1 KB, 0 deletes, 0 scans in a replayed session) |
| W0-4 delete the dead | merged cfc09cd | dead-code 49/0, home-v3 88/0, drive-v1 94/0, pagehost 17/0; kept /analysis/lap, /gallery, CLI test modes, ShadowPlay (own card later); irdeck dry probe → W0-1 |
| W0-5 state push | building (Opus) | launched 2026-11-13; its add-on part is a separate final commit |
| W0-6 lap truth | merged, deployed 2026-11-13 | review: 8 findings fixed (live judge harness reproduced the PB-reference miss first); laprules 61/0, lap-truth 64/0; laprules 53/0, lap-truth 30/0; 12 Nov = 10 laps, 7 counted (not 9: lap 1 never taken by iRacing, laps 6 and 7 incidents), best 1:33.832 lap 9 everywhere |
| W0-7 design.css + lint | merged c715ace, deployed 2026-11-13 | lint 13/0, format 36/0, races-page 21/0; Peter chose B, the broadcast gold #C9A24B: default everywhere since 2026-11-13; deck keys follow at the next deck rebuild (W0-1) |
| W0-8 test tools | merged 23dc889 | tools-test 65/0; .ibt has no CarIdx arrays (field fixtures need a recorded live stream: wave 2); live replay deferred to the W0-3 sandbox server (a pretend session on the live irdash wakes the recorder and the deck) |
| W0-9 black box v1 | merged 4a19186, deployed 2026-11-13 | review: 7 findings fixed (UI-thread refresh, snapshot noise, GPU rule, old caps, v1 honesty, lock, test); blackbox 24/0, perf-verdict 41/0; verdict names lap 9, 23.7 fps; cost 0.1-0.4 % of a core; sentence shown twice on Performance (tidy in W5-1) |
| W0-10 photos / YouTube guide / Delta | merged faf561d, deployed 2026-11-13 | photo-order 4/0, youtube-guide 14/0; cause: gallery sorted by name then shuffled; live: watch the side screens (pending); Delta: real-race method added as primary |

## Live checks still owed by the lead
- Side screens step through `r2-001`, `r2-002`… after the deploy (120 s each).
- MY RACES on the real top screen with `design.css` (served: yes, 2026-11-13).
- Pages after the W0-4 deploy (2026-11-13, browser pane): HOME, Sessions, Coach, Vault, MY RACES, Analysis, in-car demo load with no
  console error except the browser's own `/favicon.ico` 404 (never existed; harmless).

## Peter does
- Sign in to Codex again (its session expired 2026-11-13: "Please log out and sign in again"); until then the Opus cards get an
  independent Opus reviewer instead of Codex.
- Peter: click **Install** when Stream Deck asks (add-on 1.9.0.0: the CONFIRM screen for SHUT DOWN / SLEEP, timeouts, grey keys).
  Until then SHUT DOWN PC and SLEEP PC on the deck do nothing (the new irdeck refuses power from a bare key), on purpose.
  After the click the lead runs `build-deck.ps1` with Stream Deck closed, then the live deck checks in W0-1.
