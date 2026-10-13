=== FILE: docs\cards\v4\DS-01.md ===
# DS-01 Tokens: dashboard, debrief, review
**Phase 7 / depends on D-03 / size M / needs Peter:** none
## Why
Peter gets one visual family across the screens he sees most: the live dashboard, the debrief and the Session Review. The signature moment is opening the debrief after a race and it looking like the same product as the dashboard he just drove with.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\DESIGN-analysis.md` section 8 (the token values: black #0b0b0c, panels #121214, hairlines #26262a, warm white #ece8df, muted #8b877d, gold #f2c230, reference #cfd8e3, gain #3ccf7e, loss #e5534b, timing purple #b46cff, green #3ccf7e, yellow #e8c547; Bahnschrift, tabular numbers).
- `dash\www\v2\theme.css` (exists; read what tokens are already defined and which pages use them).
- `dash\www\v2\index.html` (the dashboard page; find the CSS files it loads).
- `dash\www\v2\debrief-v4.css` and `dash\www\v2\debrief-v4.js` (the debrief built in D-03; find every raw hex colour and every font/size declaration).
- `dash\www\v2\sessionreview.css` and `sessionreview.js` (the Session Review; same).
- The dashboard CSS files loaded by index.html (likely `core.css`, `ui.css`, `style.css` or similar - find them and list every raw hex colour).
- `tests\copy-audit-test.ps1` (how visible text is checked; your changes must keep it passing).
- `tests\run-all.ps1` (how tests are run; you will add a new test or extend an existing one).
## Build
1. **Find out the exact list of CSS files** loaded by `index.html` for the dashboard, and the exact CSS files for debrief-v4 and sessionreview. Write the list in your report.
2. **Define the tokens in `theme.css`** if they are not already there: `--bg`, `--panel`, `--hairline`, `--text`, `--muted`, `--gold`, `--ref`, `--gain`, `--loss`, `--purple`, `--green`, `--yellow`, plus font tokens `--font` (Bahnschrift) and `--mono` (tabular numbers via `font-variant-numeric: tabular-nums`). Use the exact values from DESIGN-analysis.md section 8.
3. **Replace every raw hex colour** in the dashboard CSS, `debrief-v4.css` and `sessionreview.css` with `var(--token)`. Do not change any layout, spacing, or behaviour. Do not touch other files.
4. **Check for overlaps** at 1920x1080 in headless Chrome with real data (the debrief and Session Review already have fixtures in their tests; reuse them). Fix only overlaps caused by your token change (there should be none; if there are, report them).
5. **Run copy-audit** and fix any new failures (there should be none; your change is colours only).
6. **Take before/after pictures** of the dashboard, debrief and Session Review into `tests\shots\` named `ds1-dash-before.png`, `ds1-dash-after.png`, `ds1-debrief-before.png`, `ds1-debrief-after.png`, `ds1-review-before.png`, `ds1-review-after.png`. The "before" pictures are the current state before your change; take them first.
7. **Side-by-side with F1 TV timing**: find a screenshot of F1 TV timing (the docs reference it; if none exists locally, use the description in DESIGN-analysis.md section 8 and note in your report that no local reference image exists). Put the side-by-side in `tests\shots\ds1-sidebyside.png` (your after picture next to the reference, or a note if no reference image is available).
## Files
- `dash\www\v2\theme.css` (edit)
- `dash\www\v2\debrief-v4.css` (edit)
- `dash\www\v2\sessionreview.css` (edit)
- The dashboard CSS files loaded by index.html (edit; list them in your report)
- `tests\copy-audit-test.ps1` (only if a new pattern is needed; otherwise do not touch)
- `tests\run-all.ps1` (only to add your new test section if you create one; otherwise do not touch)
- New: `tests\ds1-token-test.ps1` (the gate test)
- `docs\tasks\log\DS-01.md` (new report)
Anything not listed is off limits except the smallest edit, reported.
## Gate
`tests\ds1-token-test.ps1` with these sections, each with numbers:
1. **No raw hex outside theme.css**: grep every CSS file in the dashboard, debrief-v4 and sessionreview for `#[0-9a-fA-F]{3,8}`. Count = 0 in all of them. Print the count.
2. **Tokens defined**: `theme.css` contains `--bg`, `--panel`, `--hairline`, `--text`, `--muted`, `--gold`, `--ref`, `--gain`, `--loss`, `--purple`, `--green`, `--yellow`, `--font`, `--mono`. Count = 14.
3. **No overlaps**: reuse the debrief and Session Review fixtures; measure every visible text element's bounding box; count overlaps = 0.
4. **Copy-audit passes**: run the copy-audit test; count FAIL = 0.
5. **Pictures exist**: the six before/after pictures and the side-by-side exist and are non-empty.
Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` (exit 0). Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop.
## User journey
Peter drives a race, gets out, and the debrief appears. He looks at the dashboard, the debrief and the Session Review and sees the same black/gold family, the same fonts, the same hairlines. He would fail it if the debrief used a different gold or a different font from the dashboard, or if any text overlapped another.
## Not in this card
Workbench tokens (DS-02), HOME/Vault/Performance/Sessions/TV tokens (DS-03), phone and deck tokens (DS-04), deleting dead files (DS-05).
## Report
AGENTS.md format to `docs\tasks\log\DS-01.md`.

=== FILE: docs\cards\v4\DS-02.md ===
# DS-02 Tokens: workbench
**Phase 7 / depends on W-10 / size M / needs Peter:** none
## Why
Peter gets the Workbench - the deepest analysis screen - in the same black/gold family as the rest of Paddock. The signature moment is opening the Workbench from the debrief and it feeling like the same product, not a separate tool.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\DESIGN-analysis.md` section 8 (the token values).
- `docs\DESIGN-workbench.md` (the Workbench spec; understand the pages and displays).
- `dash\www\v2\theme.css` (the tokens from DS-01; reuse them).
- `dash\www\v2\workbench.css` and every `workbench-*.css` file (find them all; list every raw hex colour and every font/size declaration).
- `dash\www\v2\workbench.js` and `workbench-*.js` (to understand which CSS classes are used; do not change behaviour).
- `tests\workbench-test.ps1` (the existing Workbench test; reuse its fixtures for the overlap check).
- `tests\copy-audit-test.ps1` (how visible text is checked).
## Build
1. **Find out the exact list of Workbench CSS files.** Write the list in your report.
2. **Replace every raw hex colour** in those files with `var(--token)` from theme.css. Do not change any layout, spacing, or behaviour. Do not touch other files.
3. **Check for overlaps** at 1920x1080 in headless Chrome with real data (reuse the Workbench test fixtures). Fix only overlaps caused by your token change (there should be none; if there are, report them).
4. **Run copy-audit** and fix any new failures (there should be none).
5. **Take before/after pictures** of the Workbench DRIVER page and one other page (your choice) into `tests\shots\` named `ds2-wb-driver-before.png`, `ds2-wb-driver-after.png`, `ds2-wb-other-before.png`, `ds2-wb-other-after.png`.
6. **Side-by-side with Pi Toolbox**: find a screenshot of Pi Toolbox (the docs reference it; if none exists locally, use the description in DESIGN-workbench.md and note in your report that no local reference image exists). Put the side-by-side in `tests\shots\ds2-sidebyside.png`.
## Files
- `dash\www\v2\workbench.css` and every `workbench-*.css` file (edit; list them in your report)
- `tests\workbench-test.ps1` (only to add your new test section if you create one; otherwise do not touch)
- New: `tests\ds2-token-test.ps1` (the gate test)
- `docs\tasks\log\DS-02.md` (new report)
Anything not listed is off limits except the smallest edit, reported.
## Gate
`tests\ds2-token-test.ps1` with these sections, each with numbers:
1. **No raw hex outside theme.css**: grep every Workbench CSS file for `#[0-9a-fA-F]{3,8}`. Count = 0. Print the count.
2. **No overlaps**: reuse the Workbench test fixtures; measure every visible text element's bounding box; count overlaps = 0.
3. **Copy-audit passes**: run the copy-audit test; count FAIL = 0.
4. **Pictures exist**: the four before/after pictures and the side-by-side exist and are non-empty.
Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` (exit 0). Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop.
## User journey
Peter opens the Workbench from the debrief's DEEP DIVE button. He sees the same black/gold family, the same fonts, the same hairlines as the debrief he just left. He would fail it if the Workbench used a different gold or a different font, or if any text overlapped another.
## Not in this card
HOME/Vault/Performance/Sessions/TV tokens (DS-03), phone and deck tokens (DS-04), deleting dead files (DS-05).
## Report
AGENTS.md format to `docs\tasks\log\DS-02.md`.

=== FILE: docs\cards\v4\DS-03.md ===
# DS-03 Tokens: HOME, Vault, Performance, Sessions, TV
**Phase 7 / depends on H-07, T-04 / size M / needs Peter:** none
## Why
Peter gets the remaining top-screen pages - HOME, Vault, Performance, Sessions and the TV view - in the same black/gold family. The signature moment is opening HOME and seeing the same visual language as the debrief and the Workbench.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\DESIGN-analysis.md` section 8 (the token values).
- `dash\www\v2\theme.css` (the tokens from DS-01; reuse them).
- `dash\www\v2\home.css`, `vault.css`, `perf.css`, `sessions.css`, `tvview.css` (find them all; list every raw hex colour and every font/size declaration).
- `dash\www\v2\home.js`, `vault.js`, `perf.js`, `sessions.js`, `tvview.js` (to understand which CSS classes are used; do not change behaviour).
- `tests\home-test.ps1`, `tests\vault-test.ps1`, `tests\perf-test.ps1`, `tests\data-test.ps1`, `tests\tv-test.ps1` (the existing tests; reuse their fixtures for the overlap check).
- `tests\copy-audit-test.ps1` (how visible text is checked).
## Build
1. **Find out the exact list of CSS files** for HOME, Vault, Performance, Sessions and TV. Write the list in your report.
2. **Replace every raw hex colour** in those files with `var(--token)` from theme.css. Do not change any layout, spacing, or behaviour. Do not touch other files.
3. **Check for overlaps** at 1920x1080 in headless Chrome with real data (reuse the existing test fixtures). Fix only overlaps caused by your token change (there should be none; if there are, report them).
4. **Run copy-audit** and fix any new failures (there should be none).
5. **Take before/after pictures** of HOME and one other page (your choice) into `tests\shots\` named `ds3-home-before.png`, `ds3-home-after.png`, `ds3-other-before.png`, `ds3-other-after.png`.
## Files
- `dash\www\v2\home.css`, `vault.css`, `perf.css`, `sessions.css`, `tvview.css` (edit; list them in your report)
- New: `tests\ds3-token-test.ps1` (the gate test)
- `docs\tasks\log\DS-03.md` (new report)
Anything not listed is off limits except the smallest edit, reported.
## Gate
`tests\ds3-token-test.ps1` with these sections, each with numbers:
1. **No raw hex outside theme.css**: grep every CSS file in this card's list for `#[0-9a-fA-F]{3,8}`. Count = 0. Print the count.
2. **No overlaps**: reuse the existing test fixtures; measure every visible text element's bounding box; count overlaps = 0.
3. **Copy-audit passes**: run the copy-audit test; count FAIL = 0.
4. **Pictures exist**: the four before/after pictures exist and are non-empty.
Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` (exit 0). Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop.
## User journey
Peter opens HOME, then Vault, then Performance, then Sessions, then the TV view. He sees the same black/gold family, the same fonts, the same hairlines everywhere. He would fail it if any page used a different gold or a different font, or if any text overlapped another.
## Not in this card
Phone and deck tokens (DS-04), deleting dead files (DS-05).
## Report
AGENTS.md format to `docs\tasks\log\DS-03.md`.

=== FILE: docs\cards\v4\DS-04.md ===
# DS-04 Tokens: phone + deck screens
**Phase 7 / depends on PH-01 / size M / needs Peter:** none
## Why
Peter gets the phone app and the Stream Deck screens in the same black/gold family as the top screen. The signature moment is opening the phone on the sofa and seeing the same visual language as the top screen at the rig.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\DESIGN-analysis.md` section 8 (the token values).
- `dash\www\v2\theme.css` (the tokens from DS-01; reuse the values, not the file - the phone and deck have their own CSS).
- `dash\www\phone\app.css` (the phone app CSS; list every raw hex colour and every font/size declaration).
- `dash\www\phone\app.js` (to understand which CSS classes are used; do not change behaviour).
- `deck-intro\plugin.html` (the deck add-on; find every colour used in the screens - look for hex colours, `rgb(`, `rgba(`, and named colours like `gold`, `black`, `white`; list them).
- `tests\phone-test.ps1` and `tests\deck-screens-test.ps1` (the existing tests; reuse their fixtures).
- `tests\copy-audit-test.ps1` (how visible text is checked; note the deck screens are also scanned).
## Build
1. **Find out the exact list of colours** in `app.css` and `plugin.html`. Write the list in your report.
2. **Replace every colour** in `app.css` with the token values from DESIGN-analysis.md section 8 (hard-code the values in app.css - the phone does not load theme.css). Do not change any layout, spacing, or behaviour.
3. **Replace every colour** in `plugin.html` with the same values. The deck rule: one gold, one black. Do not change any layout, spacing, or behaviour. Do not touch other files.
4. **Check for overlaps** on the phone (390 wide) and the deck screens (768x384) with the existing test fixtures. Fix only overlaps caused by your colour change (there should be none; if there are, report them).
5. **Run copy-audit** and fix any new failures (there should be none).
6. **Take before/after pictures** of the phone home screen and one deck screen (your choice) into `tests\shots\` named `ds4-phone-before.png`, `ds4-phone-after.png`, `ds4-deck-before.png`, `ds4-deck-after.png`.
## Files
- `dash\www\phone\app.css` (edit)
- `deck-intro\plugin.html` (edit colours only)
- New: `tests\ds4-token-test.ps1` (the gate test)
- `docs\tasks\log\DS-04.md` (new report)
Anything not listed is off limits except the smallest edit, reported.
## Gate
`tests\ds4-token-test.ps1` with these sections, each with numbers:
1. **No raw hex outside the allowed files**: grep `app.css` and `plugin.html` for `#[0-9a-fA-F]{3,8}`. Count = 0 in both. Print the count.
2. **Deck one gold, one black**: grep `plugin.html` for the gold value `#f2c230` and the black value `#0b0b0c`. Count each >= 1.
3. **No overlaps**: reuse the existing test fixtures; measure every visible text element's bounding box; count overlaps = 0.
4. **Copy-audit passes**: run the copy-audit test; count FAIL = 0.
5. **Pictures exist**: the four before/after pictures exist and are non-empty.
Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` (exit 0). Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop. Do NOT run `deck-intro\install.ps1` or `build-deck.ps1` - the lead batches those.
## User journey
Peter opens the phone on the sofa and sees the same black/gold family as the top screen. He opens a deck screen and sees the same. He would fail it if the phone or deck used a different gold or a different font, or if any text overlapped another.
## Not in this card
Deleting dead files (DS-05).
## Report
AGENTS.md format to `docs\tasks\log\DS-04.md`.

=== FILE: docs\cards\v4\DS-05.md ===
# DS-05 Delete dead `dash\www` v1 + `cars.js`
**Phase 7 / depends on none / size S / needs Peter:** none
## Why
Peter gets a cleaner codebase with no dead files that could confuse a future builder. The signature moment is a future card not accidentally editing the old v1 dashboard instead of the real one.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\ARCHITECTURE.md` (the folders section: `dash\www\` is the older dashboard, `page=v2/` means it is not the one on the top screen).
- `docs\review\R1-screens-deepseek.md` section 1 (the verdicts: root dashboard DELETE, `cars.js` DELETE).
- `dash\www\` (list every file in the root, not v2).
- `dash\www\v2\` (list every file; find which v2 files reference `cars.js` or any root file).
- `dash\irdash.ini` (confirm `page=v2/`).
- `tests\run-all.ps1` (how tests are run; you will run it after the move).
## Build
1. **Find out the exact list of files** in `dash\www\` (root, not v2) and which v2 files reference `cars.js` or any root file. Write the list in your report.
2. **Move every root file** in `dash\www\` (not v2) to `backup\www-v1\`. Do not delete them. Do not move `dash\www\v2\` or `dash\www\phone\`.
3. **Move `dash\www\v2\cars.js`** to `backup\www-v1\cars.js`. Do not delete it.
4. **Remove the script tag** for `cars.js` from any v2 HTML file that loads it (find them; the smallest edit - just the one line). Report which files you edited.
5. **Run `tests\run-all.ps1`** and confirm no new FAIL vs `tests\run-all.last.txt`. If any test references a moved file, fix the test (the smallest edit) and report it.
## Files
- `dash\www\*.js`, `*.html`, `*.css` (move to `backup\www-v1\`; list them in your report)
- `dash\www\v2\cars.js` (move to `backup\www-v1\cars.js`)
- The v2 HTML files that load `cars.js` (edit the script tag only; list them in your report)
- `tests\run-all.ps1` (only if a test references a moved file; otherwise do not touch)
- `docs\tasks\log\DS-05.md` (new report)
Anything not listed is off limits except the smallest edit, reported.
## Gate
`tests\run-all.ps1` with these checks:
1. **grep 0 references**: grep the whole repo for `cars.js` and for each moved root file name. Count = 0 references outside `backup\www-v1\`. Print the count.
2. **run-all unchanged**: run `tests\run-all.ps1`; compare with `tests\run-all.last.txt`; no new FAIL. Print the before and after FAIL counts.
Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` (exit 0). Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop.
## User journey
Peter sees no change. He would fail it if any page broke or any test failed.
## Not in this card
Nothing - this is the last DS card.
## Report
AGENTS.md format to `docs\tasks\log\DS-05.md`.

=== FILE: docs\cards\v4\HK-01.md ===
# HK-01 Click-through every screen
**Phase 7 / depends on DS-03 / size M / needs Peter:** none
## Why
Peter gets a guarantee that every visible button on every served page does something. The signature moment is him pressing any button and never finding a dead one.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\ARCHITECTURE.md` (the routes table: every page irdash serves).
- `dash\www\v2\` (list every HTML page; for each, find every button and link).
- `dash\www\phone\` (the phone app; same).
- `deck-intro\plugin.html` (the deck screens; same - but note the deck screens are tested by `deck-screens-test.ps1` already).
- `tests\run-all.ps1` (how tests are run; you will add a new test).
- `tests\guard.ps1` (the guard; your test must use it).
## Build
1. **Find out the exact list of served pages** and, for each, every visible button and link. Write the list in your report.
2. **Write `tests\clickthrough-test.ps1`** (new). It must:
   - Dot-source `tests\guard.ps1` and call `Assert-RigFree` at the start and before each section.
   - Open each served page in headless Chrome at 1920x1080 (reuse the pattern from `tests\data-test.ps1` or `tests\quickwins-test.ps1`).
   - For every visible button and link, click it and check that something happens: a page changes, a route answers, a state changes, or the button is disabled with a clear reason. A button that does nothing and is not disabled = FAIL.
   - Print `ok`/`FAIL` lines with the page name and button text.
   - Save pictures of any failure to `tests\shots\`.
3. **Run the test** and fix any dead buttons you find (the smallest fix; report each one).
4. **Add `clickthrough` to `tests\run-all.ps1`** (the smallest edit; follow the existing pattern).
## Files
- New: `tests\clickthrough-test.ps1`
- `tests\run-all.ps1` (add the test)
- The pages with dead buttons (smallest fix; list them in your report)
- `docs\tasks\log\HK-01.md` (new report)
Anything not listed is off limits except the smallest edit, reported.
## Gate
`tests\clickthrough-test.ps1` with these sections, each with numbers:
1. **Every visible button on every served page clicked**: count of pages checked, count of buttons clicked, count of dead buttons = 0. Print all three.
2. **Screen list = all pages**: the test prints the list of pages it checked; compare with the list from step 1 of Build. Count of missing pages = 0.
Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` (exit 0). Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop.
## User journey
Peter opens every page and presses every button. Nothing is dead. He would fail it if any button did nothing.
## Not in this card
Stale tests and flaps (HK-02), root tidy and docs refresh (HK-03), oversight job decisions (HK-04).
## Report
AGENTS.md format to `docs\tasks\log\HK-01.md`.

=== FILE: docs\cards\v4\HK-02.md ===
# HK-02 Stale tests and flaps
**Phase 7 / depends on none / size S / needs Peter:** none
## Why
Peter gets a test suite that passes three times in a row, so a green run means the product works, not that a flaky test happened to pass. The signature moment is the lead running run-all three times and getting 0 FAIL every time.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `tests\run-all.ps1` (how tests are run; the list of tests).
- `tests\run-all.last.txt` (the last result; find any FAIL or SKIPPED lines).
- `tests\data-test.ps1` (the stale checks mentioned in the handoff: data-test and video-page).
- `tests\video-page-test.ps1` if it exists (find it; if it does not, find where the video-page checks live).
- `tests\friends-live-test.ps1` (the x4 margin mentioned in the handoff).
- `docs\HANDOFF-lead.md` (the B1 note: the x4 playback check is borderline, failed once by 0.003 s - add a small margin if it flaps).
## Build
1. **Find out which tests have stale checks or flaps.** Run `tests\run-all.ps1` three times in a row. For each run, note any FAIL or SKIPPED. Write the list in your report.
2. **Fix each stale check**: if a check tests something that no longer exists or has changed, update the check to match the current product (never weaken a check to pass - if the product is wrong, fix the product, not the test). Report each fix.
3. **Fix each flap**: if a check fails intermittently by a tiny margin (like the x4 playback check by 0.003 s), add a small, documented margin (e.g. 0.01 s) and a comment saying why. Report each fix.
4. **Run `tests\run-all.ps1` three times in a row** and confirm 0 FAIL each time.
## Files
- The test files with stale checks or flaps (edit; list them in your report)
- `docs\tasks\log\HK-02.md` (new report)
Anything not listed is off limits except the smallest edit, reported.
## Gate
`tests\run-all.ps1` run three times in a row:
1. **Run 1**: count FAIL = 0. Print the count.
2. **Run 2**: count FAIL = 0. Print the count.
3. **Run 3**: count FAIL = 0. Print the count.
Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` (exit 0). Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop.
## User journey
Peter sees no change. He would fail it if the lead could not get three clean runs in a row.
## Not in this card
Root tidy and docs refresh (HK-03), oversight job decisions (HK-04).
## Report
AGENTS.md format to `docs\tasks\log\HK-02.md`.

=== FILE: docs\cards\v4\HK-03.md ===
# HK-03 Root tidy + docs refresh
**Phase 7 / depends on HK-01 / size S / needs Peter:** none
## Why
Peter gets a tidy repo where every referenced path works and the guide describes what he actually sees. The signature moment is the lead following OPERATIONS.md to build, deploy and test without asking anything.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\OPERATIONS.md` (the build, deploy, test and recover commands; check every path it references).
- `docs\ARCHITECTURE.md` (the folders table; check every path).
- `docs\USER-GUIDE.md` (the guide; check every screen and key it describes against the current product).
- `docs\deck-speed.md` (the deck speed doc; check it is current).
- `docs\ROADMAP.md` and `docs\TASKS.md` (the plan; check the status lines are current).
- The repo root (list every stray file; check which are referenced by `keys\keys.map`, build scripts, irdash, irdeck, the logon task "iRacing Rig", or Stream Deck profiles).
- `tests\run-all.ps1` (how tests are run; you will run it after the tidy).
## Build
1. **Find out which root files are strays** (not referenced anywhere) and which are referenced. Write the list in your report.
2. **Move strays** to `tools\` or `backup\` (never delete). Do not move anything referenced. Report every move.
3. **Check every path** in OPERATIONS.md, ARCHITECTURE.md and USER-GUIDE.md against the real repo. Fix any broken path in the docs (the smallest edit). Report each fix.
4. **Update USER-GUIDE.md** to match the current product: every screen, every key, every button. Read the code to be accurate. Report each change.
5. **Update the status lines** in TASKS.md for the cards you know are done (the smallest edit; only the cards you are sure about). Report each change.
6. **Run `tests\run-all.ps1`** and confirm no new FAIL.
## Files
- The stray root files (move; list them in your report)
- `docs\OPERATIONS.md`, `docs\ARCHITECTURE.md`, `docs\USER-GUIDE.md`, `docs\deck-speed.md` (edit; list them in your report)
- `docs\TASKS.md` (status lines only; list them in your report)
- `docs\tasks\log\HK-03.md` (new report)
Anything not listed is off limits except the smallest edit, reported.
## Gate
`tests\run-all.ps1` plus these checks:
1. **No referenced path breaks**: grep the repo for `keys.map`, the logon task command, and the profile paths. Count of broken references = 0. Print the count.
2. **run-all unchanged**: run `tests\run-all.ps1`; compare with `tests\run-all.last.txt`; no new FAIL. Print the before and after FAIL counts.
3. **Guide matches the rig**: the lead reads USER-GUIDE.md and confirms it describes what Peter sees. Count of mismatches found by the lead = 0 (the lead checks this, not the test).
Compile with `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` (exit 0). Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` only when `irdeck-cli.exe state` shows sim=False - exit 2 = stop.
## User journey
Peter reads the guide and it describes what he sees. He would fail it if the guide mentioned a screen or key that no longer exists, or if a path in the docs was broken.
## Not in this card
Oversight job decisions (HK-04).
## Report
AGENTS.md format to `docs\tasks\log\HK-03.md`.

=== FILE: docs\cards\v4\HK-04.md ===
# HK-04 Oversight job, voice, Tailscale decisions
**Phase 7 / depends on all / size S / needs Peter:** two yes/no
## Why
Peter gets written decisions on the three open items - the hourly oversight job, local voice control, and phone access away from home - so nothing is built on an assumption. The signature moment is the lead reading the decisions and knowing exactly what to build next.
## Read first
AGENTS.md, CLAUDE.md, COPY-RULES.md. Then:
- `docs\HANDOFF-lead.md` (the oversight job was deleted to save money; the note says re-create it after the Wednesday reset if Peter wants it).
- `docs\PLAN-v4.md` section 5 (the questions for Peter; voice and Tailscale are among them).
- `docs\SPEC-v4.md` section 7 (the options that need Peter's yes: Tailscale rank 5, local speech rank 6).
- `docs\ROADMAP.md` (the parked items: voice control, phone away from home).
- `docs\ARCHITECTURE.md` (the phone section: LAN only, pairing token, no public ports).
## Build
1. **Write `docs\decisions-later.md`** (new). It must contain three sections, each with:
   - The question in plain English.
   - What Peter said (ask him; if he has not answered, write "not answered yet" and the exact question to ask).
   - The decision (build / do not build / later).
   - What would be built if yes, and what is deliberately not built.
   - The cost and the risk.
2. **Do not build anything.** This card is docs only.
3. **Ask Peter the two questions** (voice, Tailscale) and write his answers in the doc. If he is not available, write the questions and mark them unanswered.
## Files
- New: `docs\decisions-later.md`
- `docs\tasks\log\HK-04.md` (new report)
Anything not listed is off limits except the smallest edit, reported.
## Gate
`docs\decisions-later.md` exists and contains:
1. **Three sections**: oversight job, voice, Tailscale. Count = 3.
2. **Each section has a decision**: build / do not build / later. Count of sections without a decision = 0.
3. **Nothing built**: the only files changed are the two listed. Count of other files changed = 0.
No compile or deploy needed (docs only).
## User journey
Peter reads the decisions and knows what will be built and what will not. He would fail it if a decision was missing or if something was built without his yes.
## Not in this card
Nothing - this is the last card.
## Report
AGENTS.md format to `docs\tasks\log\HK-04.md`.