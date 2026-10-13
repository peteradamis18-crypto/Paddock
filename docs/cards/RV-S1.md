You are the independent reviewer for card S1 of PADDOCK (read AGENTS.md and CLAUDE.md first). Do NOT edit anything.

The card is docs\cards\S1-save-recording.md. The builder's report is docs\tasks\log\S1.md. The code is in
dash\src\recorder.cs (main), dash\src\vault.cs (Commands "recsave", /api/rec/* routes), dash\src\irdash.cs (route guard),
dash\www\v2\sessionreview.js, dash\www\phone\app.js (SAVE buttons), tests\recorder-test.ps1 (sections 11-16).
There is no git history; judge the current code against the card.

Check, with file:line evidence:
1. Every numbered requirement of the card: met / partly / missing.
2. Real bugs: thread safety (Loop vs worker vs finish thread), files deleted that should be kept (saved sessions, PB clips,
   segments still needed by a pending cut), a SAVE pressed during a session being lost, salvage on start, the 50 GB free
   rule (the report says lap-clip cuts still use 20 GB - is that a conflict?), retention counting, HEVC fallback chain,
   hvc1 tag only for HEVC, temp-file + rename, Range serving, C# 5 compliance (no $"", ?., nameof, =>, out var).
3. Does the test really prove the behaviour, or could it pass with broken code? Name weak checks.
4. Anything that could hurt Peter: frame-rate cost, disk filling, irdash crash, acting while he drives.
Answer: a verdict line (ACCEPT / ACCEPT WITH FIXES / REJECT), then findings ordered by severity, each with file:line and a
concrete fix. Max 60 lines.
