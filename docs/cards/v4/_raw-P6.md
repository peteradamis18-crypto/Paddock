=== FILE: docs\cards\v4\K-01.md ===
# K-01 MAIN 32-key layout proposal
**Phase 6 / depends on D-05, T-04 / size S / needs Peter: one yes**
## Why
Peter gets SAVE, DEBRIEF, VAULT, TV and HOME on the MAIN page without losing any key he uses. The five keys that make room are the ones he never presses (SHOWCASE, SAVE RESET POINT, BACK TO RESET POINT, TEAR OFF, CLEAR PIT). One picture, one yes, then K-02 installs it.
## Read first
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` (all rules apply; the proposal picture is a visible word, so copy-audit applies).
- `docs\OPERATIONS.md` section 10 (the lead runs `build-deck.ps1 -Preview`; agents never run the real build).
- `build-deck.ps1` (the MAIN grid and `-Preview` path; find where the five displaced keys are defined and how the preview PNG is written).
- `keys\keys.map` (the command names the five displaced keys run today; the proposal must name them exactly).
- `tests\keys-test.ps1` (what "0 dead" means; the proposal must not break it).
- `docs\deck-speed.md` (the MAIN page is built by `build-deck.ps1`; the preview is the only safe deck command while he is in the car).
## Build
1. **Find out the exact current MAIN layout** in `build-deck.ps1`: read the grid definition and write the 8Ã4 table (key label, command, position) into the report. Do not guess.
2. **Write `docs\deck-main-proposal.md`** (new file). It contains:
   - One 8Ã4 ASCII picture of the proposed MAIN page, with the five new keys in their positions and the five displaced keys named.
   - The exact mapping: `SHOWCASE` â `SAVE`, `SAVE RESET POINT` â `DEBRIEF`, `BACK TO RESET POINT` â `VAULT`, `TEAR OFF` â `TV`, `CLEAR PIT` â `HOME` (the proposal in the spec; if the grid in step 1 shows a different order, use the spec's order and note the difference).
   - The command each new key runs: `SAVE` = `recsave` (from S1), `DEBRIEF` = the debrief open command (find the exact command name in `dash\src\irdash.cs` or `keys\keys.map`; if it does not exist yet, write `debrief` and mark it "to be wired in K-02"), `VAULT` = the Vault open command (find it; if missing, write `vault` and mark it), `TV` = `tvview` (from T-04), `HOME` = the HOME open command (find it; if missing, write `home` and mark it).
   - A note that the five displaced keys are never pressed (from the usage data in `docs\TASKS.md` C-31: SHOWCASE, SAVE RESET POINT, BACK TO RESET POINT, TEAR OFF, CLEAR PIT).
3. **Run `build-deck.ps1 -Preview`** (safe while he is in the car; it writes `C:\Temp\preview\`). Check the preview PNG exists and shows the proposed layout. If the preview does not reflect the proposal (because the proposal is a doc, not a code change), write the picture from the doc's ASCII table instead: the gate is the doc picture, not the preview.
4. **Run `tests\keys-test.ps1`** and confirm 0 FAIL (the proposal must not change `keys\keys.map` or `build-deck.ps1`, so keys-test must still pass unchanged).
5. **Write the report** to `docs\tasks\log\K-01.md` in the AGENTS.md format.
## Files
- New: `docs\deck-main-proposal.md`
- Read only: `build-deck.ps1`, `keys\keys.map`, `tests\keys-test.ps1`, `docs\OPERATIONS.md`, `docs\deck-speed.md`
- Anything not listed is off limits except the smallest edit, reported.
## Gate
`tests\keys-test.ps1` â 0 FAIL (unchanged). The proposal doc contains one 8Ã4 picture with the five new keys and the five displaced keys named, and the exact command each new key runs. `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0 (no code changed, but the compile must still pass). Deploy only when `irdeck-cli.exe state` shows sim=False; exit 2 = stop. Copy-audit passes for any visible text in the proposal picture (the doc itself is not a screen, but the picture's labels must follow COPY-RULES).
## User journey
Peter opens the proposal picture, sees SAVE, DEBRIEF, VAULT, TV and HOME in place of the five keys he never presses, and says yes or marks changes. He fails it if any key he uses is displaced or if a new key's label is unclear.
## Not in this card
- Installing the layout (K-02).
- Wiring the new keys' commands if they do not exist yet (K-02).
- The official deck screen (K-03) and the UI map check (K-04).
## Report
Write `docs\tasks\log\K-01.md` in the AGENTS.md format (CARD, RESULT, GATE, FILES, NEEDS PETER, NEEDS LEAD, NOTES) and print the same as the last message.

=== FILE: docs\cards\v4\K-02.md ===
# K-02 Deck batch: add-on 1.8 + MAIN per yes
**Phase 6 / depends on K-01 / size M live / needs Peter: one Install click**
## Why
Peter gets SAVE, DEBRIEF, VAULT, TV and HOME as one-press keys on the MAIN page, and the add-on's ANALYSIS row gets the debrief keys. One Install click, then every key answers.
## Read first
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` (all rules apply; the add-on and MAIN labels are visible words).
- `docs\OPERATIONS.md` section 10 (the lead runs `deck-intro\install.ps1` and `build-deck.ps1`; agents never run them).
- `docs\deck-main-proposal.md` (the K-01 proposal Peter approved; the exact key positions and commands).
- `deck-intro\plugin.html` (the ANALYSIS row; find where the debrief row goes and how keys are defined).
- `deck-intro\install.ps1` (the `$ver` line; bump it once).
- `build-deck.ps1` (the MAIN grid; apply the K-01 mapping).
- `keys\keys.map` (the command names; add the new keys' commands if they do not exist).
- `tests\keys-test.ps1`, `tests\deck-screens-test.ps1`, `tests\deck-speed-test.ps1` (the gates).
## Build
1. **Find out the exact current state** of `deck-intro\plugin.html` (the ANALYSIS row and the debrief row if it exists), `build-deck.ps1` (the MAIN grid), and `keys\keys.map` (which of `recsave`, `debrief`, `vault`, `tvview`, `home` exist). Write the findings in the report.
2. **Add the debrief row to the ANALYSIS screen** in `deck-intro\plugin.html`: the four debrief keys (SAVE, SHARE, OPEN IN COSWORTH, DEEP DIVE) from D-05, using the same key style as the existing ANALYSIS keys. Each key sends the command D-05 defined. If D-05 did not define the exact commands, use the spec's names: `recsave`, `share`, `cosworth`, `deepdive` and mark them "to be wired" if the server does not answer them yet.
3. **Bump `$ver` in `deck-intro\install.ps1`** to 1.8.0.0 (the file says why: Stream Deck treats a higher version as an update).
4. **Apply the K-01 mapping in `build-deck.ps1`**: replace the five displaced keys with SAVE, DEBRIEF, VAULT, TV, HOME at the positions in the proposal. Each new key runs the command from the proposal (`recsave`, the debrief command, the Vault command, `tvview`, the HOME command). If a command does not exist in `keys\keys.map`, add it there with the exact command name the server answers.
5. **Run `tests\keys-test.ps1`** and `tests\deck-screens-test.ps1` â 0 FAIL. Run `tests\deck-speed-test.ps1 -Live` only when the rig is free and Peter is away; if not, leave it PENDING with the exact command.
6. **Do not run `deck-intro\install.ps1` or `build-deck.ps1`.** Write the exact steps for the lead in the report: close Stream Deck, run `build-deck.ps1`, restart Stream Deck, run `deck-intro\install.ps1`, Peter clicks Install.
7. **Write the report** to `docs\tasks\log\K-02.md` in the AGENTS.md format.
## Files
- `deck-intro\plugin.html` (ANALYSIS debrief row)
- `deck-intro\install.ps1` (`$ver` bump only)
- `build-deck.ps1` (MAIN grid per K-01)
- `keys\keys.map` (only if a new command is missing)
- Read only: `docs\deck-main-proposal.md`, `tests\keys-test.ps1`, `tests\deck-screens-test.ps1`, `tests\deck-speed-test.ps1`, `docs\OPERATIONS.md`
- Anything not listed is off limits except the smallest edit, reported.
## Gate
`tests\keys-test.ps1` â 0 FAIL. `tests\deck-screens-test.ps1` â 0 FAIL. `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0. Deploy with `dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False; exit 2 = stop. `tests\deck-speed-test.ps1 -Live` timings written when the rig is free and Peter is away (or PENDING with the exact command). Copy-audit passes for any visible text.
## User journey
Peter clicks Install once. Then SAVE, VAULT, TV and DEBRIEF are one press each on the MAIN page, and the ANALYSIS screen has the debrief row. He fails it if any key is dead, if a displaced key he uses is gone, or if the Install click does not update the add-on.
## Not in this card
- The official deck screen (K-03) and the UI map check (K-04).
- The racing line resolution (F-01) and AI cards (A-01, A-02).
- The phone final (PH-01).
## Report
Write `docs\tasks\log\K-02.md` in the AGENTS.md format and print the same as the last message.

=== FILE: docs\cards\v4\K-03.md ===
# K-03 Official deck screen
**Phase 6 / depends on H-02 / size M / needs Peter: none**
## Why
Peter sees what official races are on for his series, with a countdown, on the deck. One press shows what's on; nothing registers.
## Read first
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` (all rules apply; the deck screen labels are visible words).
- `docs\OPERATIONS.md` section 10 (agents never run `deck-intro\install.ps1` or `build-deck.ps1`).
- `deck-intro\plugin.html` (the existing live screens; copy the FRIENDS/OVERLAYS pattern for a new OFFICIAL screen).
- `src\official.cs` and `dash\src\official.cs` (the official racing code H-02 built; find the JSON the deck screen reads and the commands it sends).
- `tests\deck-screens-test.ps1` (the gate; add the OFFICIAL screen checks).
- `docs\official.md` (the data shape and the "no REGISTER" rule).
## Build
1. **Find out the exact JSON** `/official` returns after H-02 (fields for series, car, track, local start, countdown, owned) and the exact commands the deck screen must send (open the iRacing Official page, select a series, back). Write them in the report.
2. **Add an OFFICIAL screen** to `deck-intro\plugin.html`: tiles for his series (favourites first, then the rest), each tile showing the series name and "in 12m" (the countdown from H-02). Tap a tile selects it; a REGISTER key exists but is dimmed with "NO REGISTER" (the spec says no REGISTER; the key must never send a registration). A key opens iRacing's Official page by the verified UI path from H-02, only out of a session. BACK returns.
3. **Wire the screen** to the `/official` JSON and the commands from step 1. The screen must answer every key (0 dead keys).
4. **Extend `tests\deck-screens-test.ps1`** with the OFFICIAL screen: every key answers, the tiles show the right series and countdown, REGISTER is dimmed and sends nothing, the open key sends the verified UI command only out of a session.
5. **Run the test** â 0 FAIL. Run `tests\keys-test.ps1` â 0 FAIL.
6. **Do not run `deck-intro\install.ps1`.** Write the exact steps for the lead in the report (bump `$ver`, run install, Peter clicks Install).
7. **Write the report** to `docs\tasks\log\K-03.md` in the AGENTS.md format.
## Files
- `deck-intro\plugin.html` (OFFICIAL screen)
- `tests\deck-screens-test.ps1` (OFFICIAL checks)
- Read only: `src\official.cs`, `dash\src\official.cs`, `docs\official.md`, `tests\keys-test.ps1`, `docs\OPERATIONS.md`
- Anything not listed is off limits except the smallest edit, reported.
## Gate
`tests\deck-screens-test.ps1` â 0 FAIL (OFFICIAL screen: every key answers, tiles correct, REGISTER dimmed and sends nothing). `tests\keys-test.ps1` â 0 FAIL. `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0. Deploy only when `irdeck-cli.exe state` shows sim=False; exit 2 = stop. Copy-audit passes for any visible text.
## User journey
Peter presses OFFICIAL on the deck, sees his series with "in 12m", taps one, and the iRacing Official page opens. He fails it if a tile is wrong, if REGISTER does anything, or if a key is dead.
## Not in this card
- The UI map check (K-04).
- Installing the add-on (the lead batches it).
- The racing line (F-01) and AI cards (A-01, A-02).
## Report
Write `docs\tasks\log\K-03.md` in the AGENTS.md format and print the same as the last message.

=== FILE: docs\cards\v4\K-04.md ===
# K-04 Official page UI map check (away)
**Phase 6 / depends on K-03 / size S away / needs Peter: away window**
## Why
The OFFICIAL deck screen's open key must land on the right page without a blind click. This card verifies the UI path once, read-only, and stops at the Register control.
## Read first
- `AGENTS.md`, `CLAUDE.md` (rule 4: verify before every click; never type outside a verified field; never register).
- `docs\OPERATIONS.md` section 6 (away tests: `Assert-RigFree -NeedAway`).
- `src\official.cs` (the `OfMap` function and the UI path K-03 uses).
- `docs\iracing-ui-map.md` (the element names from the earlier mapping; if it does not exist, this card creates it).
- `tests\guard.ps1` (the away guard).
## Build
1. **Find out the exact UI path** in `src\official.cs` (`OfMap`): the elements it reads and the clicks it would send. Write them in the report.
2. **Run the UI map check** with the rig free and Peter away 10 minutes: `Assert-RigFree -NeedAway`, then run the read-only part of `OfMap` (or the equivalent dry run) that reads the Official page elements. Verify the page is the Official page, the series list is present, and the Register control is found. Stop at the Register control: no click.
3. **Write `docs\iracing-ui-map.md`** (new or updated) with the exact element names, positions, and the verified path, plus a note that the dry run stopped at the Register control.
4. **If the UI has changed** and the path no longer matches, do not guess: write the differences in the report and mark the card blocked for the lead.
5. **Write the report** to `docs\tasks\log\K-04.md` in the AGENTS.md format.
## Files
- New or updated: `docs\iracing-ui-map.md`
- Read only: `src\official.cs`, `tests\guard.ps1`, `docs\OPERATIONS.md`
- Anything not listed is off limits except the smallest edit, reported.
## Gate
The dry run reads the Official page elements and stops at the verified Register control with no click. The doc records the exact element names and the verified path. `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0 (no code changed). The away guard passes (`Assert-RigFree -NeedAway`). Copy-audit passes for any visible text in the doc (docs are not screens, but keep it clean).
## User journey
Peter gives an away window. The check reads the Official page and stops before Register. He fails it if anything is clicked, if the page is wrong, or if the doc does not match what the UI shows.
## Not in this card
- Registering for any race.
- The racing line (F-01) and AI cards (A-01, A-02).
- The phone final (PH-01).
## Report
Write `docs\tasks\log\K-04.md` in the AGENTS.md format and print the same as the last message.

=== FILE: docs\cards\v4\F-01.md ===
# F-01 Racing line resolution
**Phase 6 / depends on none / size M live / needs Peter: 30-second drive check**
## Why
The racing line state must match the sim or not be shown. Peter's 30-second check decides: if the line shows, START sends it and the state persists; if not, the LINE state is removed and START stops sending.
## Read first
- `AGENTS.md`, `CLAUDE.md` (rule 1: never act while he drives; rule 2: never write iRacing files).
- `docs\OPERATIONS.md` section 6 (live tests: `Assert-RigFree -NeedAway`).
- `src\guest.cs` (the `ApplyLine` function and the `racing_line_key` from `guest\guest.ini`).
- `dash\www\v2\guest.js` (the LINE state on the top screen).
- `docs\USER-GUIDE.md` (the Friends section; update it with the outcome).
- `tests\friends-live-test.ps1` (the existing line checks; extend or reduce them per the outcome).
- `docs\TASKS.md` C-25 (the history: the line never showed on track; ctrl+alt keys DO reach the sim).
## Build
1. **Find out the exact current line logic** in `src\guest.cs` (`ApplyLine`, `state.line`, `racing_line_key`) and `dash\www\v2\guest.js` (what the top screen shows). Write it in the report.
2. **Prepare the 30-second check for Peter**: the exact presses (START, press LINE, say whether the line shows) and what he should see. Write it in the report and in `docs\USER-GUIDE.md` (the Friends section).
3. **Run the offline parts** of `tests\friends-live-test.ps1` â 0 FAIL. The live part (the 30-second check) is Peter's; leave it PENDING with the exact command.
4. **If Peter says the line shows**: make START send the line key and the state persist per iRacing's toggle (the current logic may already do this; verify and fix only what is wrong). Update `docs\USER-GUIDE.md` to say the line state matches the sim.
5. **If Peter says the line does not show**: remove the LINE state from `src\guest.cs` and `dash\www\v2\guest.js`, and make START stop sending the line key. Update `docs\USER-GUIDE.md` to say the line is not shown.
6. **Write the report** to `docs\tasks\log\F-01.md` in the AGENTS.md format.
## Files
- `src\guest.cs` (line logic per the outcome)
- `dash\www\v2\guest.js` (LINE state per the outcome)
- `docs\USER-GUIDE.md` (Friends section)
- `tests\friends-live-test.ps1` (line checks per the outcome)
- Read only: `guest\guest.ini`, `docs\OPERATIONS.md`, `docs\TASKS.md` C-25
- Anything not listed is off limits except the smallest edit, reported.
## Gate
`tests\friends-live-test.ps1` offline parts â 0 FAIL. The live 30-second check is Peter's; the outcome is recorded in the report and `docs\USER-GUIDE.md`. `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0. Deploy only when `irdeck-cli.exe state` shows sim=False; exit 2 = stop. Copy-audit passes for any visible text.
## User journey
Peter does the 30-second check: START, press LINE, say whether the line shows. He fails it if the state Paddock shows does not match the sim, or if the line is shown when it should not be.
## Not in this card
- The AI cards (A-01, A-02).
- The phone final (PH-01).
- Any iRacing file change (if a binding is needed, stop and write NEEDS PETER).
## Report
Write `docs\tasks\log\F-01.md` in the AGENTS.md format and print the same as the last message.

=== FILE: docs\cards\v4\A-01.md ===
# A-01 AI dialog survey finish (away)
**Phase 6 / depends on none / size M away / needs Peter: away window**
## Why
The AI race wizard's remaining pickers (opponents, time of day, track conditions) get mapped so A-02 can build one preset without blind clicks.
## Read first
- `AGENTS.md`, `CLAUDE.md` (rule 4: verify before every click; never type outside a verified field).
- `docs\OPERATIONS.md` section 6 (away tests: `Assert-RigFree -NeedAway`).
- `docs\research\ai-dialog.md` (the existing survey: 9 steps mapped, pickers = Test Drive pickers, the three unmapped pickers).
- `src\testdrive.cs` (the picker code to reuse; read only).
- `tests\guard.ps1` (the away guard).
## Build
1. **Find out the exact state** of `docs\research\ai-dialog.md`: which pickers are mapped, which three are not (opponents, time of day, track conditions), and the exact AutomationIds already known. Write them in the report.
2. **Run the survey** with the rig free and Peter away 10 minutes: `Assert-RigFree -NeedAway`, then open the AI wizard (read-only, no launch) and map the three unmapped pickers. For each: the exact AutomationId, the rows/controls, and the values. Scope every lookup to the modal (the background page has matching rows).
3. **Update `docs\research\ai-dialog.md`** with the three pickers' mappings, the scoped lookups, and pictures if possible. Leave iRacing on Home with nothing over it (take a picture as proof).
4. **If a picker cannot be mapped safely**, write what is missing in the doc and the report; do not guess.
5. **Write the report** to `docs\tasks\log\A-01.md` in the AGENTS.md format.
## Files
- `docs\research\ai-dialog.md` (updated)
- Read only: `src\testdrive.cs`, `tests\guard.ps1`, `docs\OPERATIONS.md`
- Anything not listed is off limits except the smallest edit, reported.
## Gate
The doc maps the three pickers with exact AutomationIds and scoped lookups, and iRacing is left on Home with nothing over it (picture). `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0 (no code changed). The away guard passes. Copy-audit passes for any visible text in the doc.
## User journey
Peter gives an away window. The survey maps the pickers and leaves iRacing on Home. He fails it if anything is launched, if a picker is mapped blind, or if iRacing is not left on Home.
## Not in this card
- Building the AI preset (A-02).
- The racing line (F-01) and the phone final (PH-01).
## Report
Write `docs\tasks\log\A-01.md` in the AGENTS.md format and print the same as the last message.

=== FILE: docs\cards\v4\A-02.md ===
# A-02 AI preset one press
**Phase 6 / depends on A-01 / size M away / needs Peter: chooses the preset; away window**
## Why
Peter gets one press to his usual AI race, with every control verified and read back before launch. No blind clicks.
## Read first
- `AGENTS.md`, `CLAUDE.md` (rule 4: verify before every click; never type outside a verified field).
- `docs\OPERATIONS.md` section 6 (away tests: `Assert-RigFree -NeedAway`).
- `docs\research\ai-dialog.md` (the A-01 mappings; the exact AutomationIds for every control).
- `src\irdeck.cs` (the AI RACE command; find where the wizard steps are driven).
- `src\mydrive.cs` and `mydrive\presets.ini` (the preset storage; find the format).
- `deck-intro\plugin.html` (the RACE SETUP screen; the AI words go here).
- `tests\mydrive-test.ps1` (the gate; add the AI preset checks).
## Build
1. **Find out the exact current AI RACE path** in `src\irdeck.cs` and the preset format in `mydrive\presets.ini`. Write them in the report.
2. **Ask Peter for the preset** (the spec's recommendation: Corvette Z06 GT3.R, Road Atlanta, 20 cars, fair strength, 20 min, day, clear). If he has not chosen, use the recommendation and mark it "Peter to confirm".
3. **Build the preset**: store Peter's choice in `mydrive\presets.ini` (or the existing format). The AI RACE command reads the preset, sets every control by the A-01 mappings (verify each dialog before clicking), and reads back every control before launch. One press â in the car. No blind clicks.
4. **Add the AI words to the RACE SETUP screen** in `deck-intro\plugin.html`: only for the verified controls (opponents, time of day, track conditions, strength, length). Each word shows the preset value.
5. **Extend `tests\mydrive-test.ps1`** with the AI preset: the preset is read, every control is verified and read back, and the launch is refused if any control is unverified. Offline parts â 0 FAIL. The live part (real AI race) is PENDING for an away window.
6. **Do not run `deck-intro\install.ps1`.** Write the exact steps for the lead in the report.
7. **Write the report** to `docs\tasks\log\A-02.md` in the AGENTS.md format.
## Files
- `src\irdeck.cs` (AI RACE preset path)
- `mydrive\presets.ini` (Peter's preset)
- `deck-intro\plugin.html` (RACE SETUP AI words)
- `tests\mydrive-test.ps1` (AI preset checks)
- Read only: `docs\research\ai-dialog.md`, `src\mydrive.cs`, `docs\OPERATIONS.md`
- Anything not listed is off limits except the smallest edit, reported.
## Gate
`tests\mydrive-test.ps1` offline parts â 0 FAIL (preset read, every control verified and read back, launch refused if unverified). `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0. Deploy only when `irdeck-cli.exe state` shows sim=False; exit 2 = stop. The live AI race is PENDING for an away window. Copy-audit passes for any visible text.
## User journey
Peter presses AI RACE once and gets his usual AI race. He fails it if any control is clicked blind, if the read-back does not match the preset, or if the race is not his usual one.
## Not in this card
- The racing line (F-01).
- The phone final (PH-01).
- Installing the add-on (the lead batches it).
## Report
Write `docs\tasks\log\A-02.md` in the AGENTS.md format and print the same as the last message.

=== FILE: docs\cards\v4\PH-01.md ===
# PH-01 Phone final
**Phase 6 / depends on SH-02, W-17, D-05 / size M / needs Peter: none**
## Why
The phone becomes the same product as the top screen: review, save and share from the sofa, with the LAPS tab renamed REVIEW and re-pairing working.
## Read first
- `AGENTS.md`, `CLAUDE.md`, `docs\COPY-RULES.md` (all rules apply; the phone text is visible).
- `docs\OPERATIONS.md` section 6 (phone tests).
- `dash\www\phone\app.js` and `app.css` (the phone app; find the LAPS tab, the session review, the save/share buttons).
- `dash\src\phone.cs` (the phone routes; find the pairing and the session data).
- `tests\phone-test.ps1` (the gate; extend it).
- `docs\ARCHITECTURE.md` (the phone section: pairing, tokens, LAN only).
## Build
1. **Find out the exact current phone state**: the LAPS tab, the session review, the save/share buttons, and the pairing flow. Write them in the report.
2. **Rename LAPS to REVIEW** in `dash\www\phone\app.js` (and any label in `app.css` or `index.html`).
3. **Add the debrief mirror** from D-05: the phone shows the same debrief within 60 s of a session end (the data from `/analysis/session` or the D-05 route). The save/share buttons work as on the top screen.
4. **Add the session review + corner table** from W-16 and the channel picker + XY/histogram from W-17 if they are not already on the phone. The numbers must equal the top screen.
5. **Verify re-pairing works**: revoke a phone, pair again, the token flow completes.
6. **Extend `tests\phone-test.ps1`**: phone-test 0 FAIL; re-pair works; LAPS â REVIEW; sessions listed with SAVE/SAVED; copy-audit 0.
7. **Run the test** â 0 FAIL. Run `tests\copy-audit-test.ps1` â 0 FAIL.
8. **Write the report** to `docs\tasks\log\PH-01.md` in the AGENTS.md format.
## Files
- `dash\www\phone\app.js`, `app.css`, `index.html` (REVIEW tab, debrief mirror, review + corner table, channel picker)
- `dash\src\phone.cs` (only if a route is missing)
- `tests\phone-test.ps1` (extended)
- Read only: `docs\ARCHITECTURE.md`, `docs\OPERATIONS.md`, `tests\copy-audit-test.ps1`
- Anything not listed is off limits except the smallest edit, reported.
## Gate
`tests\phone-test.ps1` â 0 FAIL (re-pair works; LAPS â REVIEW; sessions listed with SAVE/SAVED; numbers equal the top screen). `tests\copy-audit-test.ps1` â 0 FAIL. `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` exits 0. Deploy only when `irdeck-cli.exe state` shows sim=False; exit 2 = stop.
## User journey
Peter reviews, saves and shares a session from the sofa. He fails it if the REVIEW tab is missing, if the numbers differ from the top screen, if SAVE/SAVED is wrong, or if re-pairing fails.
## Not in this card
- The racing line (F-01) and AI cards (A-01, A-02).
- The design tokens (DS-04) and housekeeping (HK-01..04).
## Report
Write `docs\tasks\log\PH-01.md` in the AGENTS.md format and print the same as the last message.