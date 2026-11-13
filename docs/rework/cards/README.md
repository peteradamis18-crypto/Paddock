# Rework cards: rules for every builder

You are building ONE card of the Paddock rework. The plan of record is `docs/rework/PLAN.md` (read sections 1, 2, 5, 6
and your card's row in section 7 first), the evidence is in `docs/rework/evidence/`, and `CLAUDE.md` + `AGENTS.md`
apply to you exactly as written. Peter is disabled: everything must be one press or automatic, in plain English.

## Where you work
- You are in your **own git worktree** on your own branch (check with `git rev-parse --show-toplevel` and
  `git branch --show-current`). Everything you do happens inside that folder. **Never** `cd` into
  `C:\Users\peter\iRacingDeck` (the live checkout) and never write there.
- Commit your work on your branch as you go (small commits, plain messages, end each message with
  `Co-Authored-By: Claude <noreply@anthropic.com>`). Never push. Never merge. Never switch branch.
- Touch only the files your card names (plus new files and the tests you add). If you must touch another file, say
  so in your report and keep the change minimal: other builders are editing the other files right now.

## What you must never do (the rig is live while you work)
- Never deploy or restart anything: `dash\build.ps1 -NoDeploy` is the only way to compile irdash; never run
  `dash\build.ps1` without `-NoDeploy`, `build-deck.ps1`, `tools\deck-refresh.ps1`, `deck-intro\install.ps1`, or any
  installer. `build-irdeck.ps1` is allowed (it only writes exes inside your worktree).
- Never start or stop irdash, StreamDeck, iRacing, SimHub, CrewChief, irdashies or any GUI app. Never send keys,
  move windows or click. Never write `Documents\iRacing\*`.
- Never use the live irdash's test hook (`/api/test/*`, `/vault/test/*`, `/perf/test/*`, `/share/test/*`,
  `dash\test-hook.on`) and never call `/api/do` or any POST on `http://localhost:8199`. Read-only GETs on the live
  irdash are fine **only** when `irdeck-cli.exe state` (worktrees have no exes: run the live checkout's `C:SERSPETERIRACINGDECKIRDECK-CLI.EXE STATE`, READ-ONLY) shows `sim=False`.
- Never run `tests\run-all.ps1`. Run only offline tests: pure compile tests, headless Chrome with fixtures, pretend
  servers on ports other than 8199. Anything that needs the real rig goes in your report under **LIVE checks for
  the lead**, with the exact command.
- No downloads, installs, accounts or credentials. No new libraries or frameworks.

## How to build and test
- C# 5 only (Windows' own csc): no `$"..."`, `?.`, `nameof`, expression-bodied members, `out var`, no tuples.
  irdash: `dash\build.ps1 -NoDeploy` (add new .cs files to its `$src` list). irdeck: `build-irdeck.ps1`.
- PowerShell is 5.1: no `&&`, `||`, `?:`, `??`; `Set-Content -Encoding utf8` for files other tools read.
- Every new test is `tests\<name>-test.ps1`, dot-sources `tests\guard.ps1` and calls `Assert-RigFree` at the start,
  prints `ok ...` / `FAIL ...` lines and ends with a count. Headless Chrome pattern: `tests\races-page-test.ps1`
  (copy its `$chrome`, `$common`, fixture-stub and `--dump-dom` approach). Pure C# rule tests: `tests\deckrules-test.ps1`
  pattern (compile the one file with csc and run it).
- Pictures go to `tests\shots\rework\<page>-<state>.png` (gitignored). Look at every picture you make.
- Existing tests that cover the files you change must still pass (run them). If one can only run live, say so.

## Style
- Short comments that say *why*; plain names; JSON by hand in irdash (`Json_.S`); no emoji; user-facing text in plain
  English (a key or screen says what it does, in Peter's words: "Share on YouTube", not "Export").
- Nothing bigger than the card. Do not refactor around it. If the card's spec is wrong about the code, do what the
  code needs, and say so in the report.

## Your report (the last thing you write)
1. What changed: files, one line each.
2. Tests: the exact ok/FAIL counts as printed, per test script. Pictures: paths, one line per picture on what you saw.
3. LIVE checks for the lead: exact commands, what to expect.
4. What you could not do or were unsure about.
5. Branch name and worktree path (`git branch --show-current`, `git rev-parse --show-toplevel`).
