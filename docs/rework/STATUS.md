# Rework status (kept by the lead; one line per card)

Legend: spec = written in `docs/rework/cards/`; built = builder reported done; merged = on `main` (commit);
deployed = on the rig; live = the live checks in the card were run by the lead; Peter = needs his yes or his click.

## Wave 0
| Card | State | Notes |
|---|---|---|
| W0-1 deck safety | building (Opus) | confirm screen, MAIN on wake, 0.7 s guard, fetch timeouts, state line, build-irdeck copy, dead deck paths |
| W0-2 RigState + guards | building (Opus) | launched 2026-11-13 after W0-4 merged |
| W0-3 stop work in sessions | spec | starts after W0-2 merges |
| W0-4 delete the dead | merged cfc09cd | dead-code 49/0, home-v3 88/0, drive-v1 94/0, pagehost 17/0; kept /analysis/lap, /gallery, CLI test modes, ShadowPlay (own card later); irdeck dry probe → W0-1 |
| W0-5 state push | spec | starts after W0-1 and W0-4 merge |
| W0-6 lap truth | building (Opus) | launched 2026-11-13 |
| W0-7 design.css + lint | merged c715ace, deployed 2026-11-13 | lint 13/0, format 36/0, races-page 21/0; contact sheet sent to Peter (gold A or B: **Peter**) |
| W0-8 test tools | merged 23dc889 | tools-test 65/0; .ibt has no CarIdx arrays (field fixtures need a recorded live stream: wave 2); live replay deferred to the W0-3 sandbox server (a pretend session on the live irdash wakes the recorder and the deck) |
| W0-9 black box v1 | building (Opus) | launched 2026-11-13 |
| W0-10 photos / YouTube guide / Delta | merged faf561d, deployed 2026-11-13 | photo-order 4/0, youtube-guide 14/0; cause: gallery sorted by name then shuffled; live: watch the side screens (pending); Delta: real-race method added as primary |

## Live checks still owed by the lead
- Side screens step through `r2-001`, `r2-002`… after the deploy (120 s each).
- MY RACES on the real top screen with `design.css` (served: yes, 2026-11-13).
- Pages after the W0-4 deploy (2026-11-13, browser pane): HOME, Sessions, Coach, Vault, MY RACES, Analysis, in-car demo load with no
  console error except the browser's own `/favicon.ico` 404 (never existed; harmless).
