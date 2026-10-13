# DK-7 Smart primary key (state machine), SKIP SESSION on MAIN, MY DRIVE START always visible

Read AGENTS.md, CLAUDE.md, docs\COPY-RULES.md, docs\deck\DECK-v4.md, docs\tasks\log\cx\council2-codex.last.md (THE design - follow
it), docs\deck\council-fable.md section 3, then src\irdeck.cs (Snap, SessionActive, OnTrack, CmdGo, CmdState), src\actions.cs
(CmdTow, CmdSkip, restartrace, session guards ~line 998), src\mydrive.cs, deck-intro\plugin.html (MY DRIVE screen, buildResults,
key drawing), dash\src\irdash.cs (/state-like routes), build-deck.ps1, keys\keys.map. Re-read any file right before editing (other
cards edit irdash.cs and irdeck.cs). C# 5 only.

## Build
1. **State resolver** (new src\deckstate.cs or inside irdeck.cs; also usable by irdash): from sim process presence + a FRESH SDK
   snapshot (+ verified UI only where telemetry can't tell) return one of: RIGON, HOME, START, JOIN, WAIT, GETIN, DRIVE, RESET, SKIP,
   RESULTS, LIVE - plus a <= 2-word refusal reason when an action is not allowed (SLOW DOWN, NOT ALLOWED, SESSION ON, WAIT). Use only
   SDK fields you verify exist in this SDK (read the variable header list; log it once). Unknown or stale -> WAIT. SKIP only for
   Test/AI (and hosted admin if detectable); official -> NOT ALLOWED. RESET only when speed < 1 m/s.
2. **`smart` command** in irdeck: resolves the state and runs the matching existing action (rigon, startlast td / airace start,
   CmdGo, CmdTow, CmdSkip with x2 confirm, debrief, replay live). JOIN: only if a verified Official UI join control is present
   (reuse testdrive verification helpers); otherwise refuse with WAIT. Never registers automatically. Idempotent; repeats ignored.
3. **irdash** `GET /deck/state` -> `{"primary":"GETIN","label":"GET IN","reason":"","armed":{"quit":0,"restart":0,"skip":0}}`
   (read-only, never triggers anything; armed = seconds left from the armed-*.txt files).
4. **MAIN grid** (build-deck.ps1 + keys.map): row1 col8 = SMART (command `smart`); row2 col6 = SKIP SESSION (`confirm skip skip`),
   REPLAY moves to MORE; keep the rest of the current preview (incl. OFFICIAL and CAR TRACK). Re-render docs\deck\main-preview.png
   with `build-deck.ps1 -Preview`, drawing the SMART key as "GET IN" (and a strip of its other labels under the picture is welcome).
5. **Add-on** (deck-intro\plugin.html): the SMART key polls /deck/state every 1 s and shows label (+ reason small); QUIT/RESTART/
   SKIP show ARMED 3-2-1 from `armed`. MY DRIVE: after a pick, return to the MY DRIVE home with START visible and the chosen
   car + track on it; the results list also gets START in a fixed cell. Do NOT run install.ps1 (the lead bumps $ver and installs).
6. **Tests** (offline, guard + Sections): new tests\deckstate-test.ps1 with fake snapshots for every row of the council table
   (idle, loading, garage, moving, stopped, stuck, tow/unknown, practice->qualify->race transitions, replay, results, sim closed)
   -> expected primary + reason; `smart --dry` prints the action it would run for each; official SKIP -> NOT ALLOWED; moving RESET
   -> SLOW DOWN. Extend tests\keys-test.ps1 (0 dead) and tests\mydrive-test.ps1 (pick -> START visible -> start command sent, as a
   fake flow). No live clicks.

## Files
src\irdeck.cs, new src\deckstate.cs (add to build-irdeck.ps1 sources if separate), src\actions.cs, src\mydrive.cs, dash\src\irdash.cs
(one route), deck-intro\plugin.html, build-deck.ps1, keys\keys.map, tests\deckstate-test.ps1 (new), tests\keys-test.ps1,
tests\mydrive-test.ps1, docs\deck\main-preview.png, docs\tasks\log\DK-7.md.

## Gate
Compile irdeck to a TEMP folder (build-irdeck.ps1 -NoDeploy) and `dash\build.ps1 -NoDeploy`; deckstate-test 0 FAIL; keys-test 0 FAIL;
preview rendered. Do not deploy irdeck, do not install the add-on, never run build-deck.ps1 without -Preview. Report in AGENTS.md
format to docs\tasks\log\DK-7.md (NEEDS LEAD: deploys, add-on $ver + install, live check list).
