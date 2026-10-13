# Card B1 - fix four stale test checks (bake-off card)

Read AGENTS.md and CLAUDE.md first (rules: C# 5, PowerShell 5.1 tests that dot-source tests\guard.ps1, never touch
iRacing's files, keep edits minimal; test files with non-ASCII text must keep their UTF-8 BOM).

Context: today the HOME screen was redesigned (dash\www\v2\home.js / home.css / index.html). The redesign removed the
THIS WEEK block (element id="idleWeek") and the LAST OUTING footer. Also "short runs" (sessions where Peter never left
pit road or a test started the sim) no longer count toward THIS WEEK / seat time (dash\src\irdash.cs Rec.Short).
The Stream Deck ANALYSIS screen (deck-intro\plugin.html) now shows up to 7 page keys + a PAGES key when there are more
than 8 pages.

Fix exactly these failing checks:
1. tests\data-test.ps1 - "this week from the cache by hand": the hand count must leave out short runs the same way
   Rec.Short does (read the rule in dash\src\irdash.cs; the cache column is described there).
2. tests\data-test.ps1 - the check that index.html has id="idleWeek": THIS WEEK is gone by design; replace it with a
   check that HOME shows no THIS WEEK block and that the Sessions link exists (id idleSessions, text "Sessions").
3. tests\video-page-test.ps1 - the check of plugin.html "up to 8 page keys": update it to the current rule (more than
   8 pages = first 7 + PAGES key; 8 or fewer = all shown) by reading the layout code in deck-intro\plugin.html.
4. tests\video-page-test.ps1 - "the small video goes to the corner that covers the least" on the GRIP page failed
   (chosen corner covers 11 boxes, another covers 3). Find out whether the TEST measures wrongly or the PAGE chooses
   wrongly (the choice is in dash\www\v2\workbench-video.js). Fix the real cause; if it is the page, fix the page.

Before running a test, run `irdeck-cli.exe state`: if it shows sim=True, stop and say so. Run:
  powershell -ExecutionPolicy Bypass -File tests\data-test.ps1
  powershell -ExecutionPolicy Bypass -File tests\video-page-test.ps1
Both must end with "0 failed". Finish with a short report: what was wrong in each of the 4, which files you changed,
and each test's own summary line.
