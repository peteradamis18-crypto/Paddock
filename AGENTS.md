# AGENTS.md — rules for every coding agent on PADDOCK (Grok Build, Claude, anyone)

You are working on **PADDOCK**, Peter's iRacing sim-rig software (folder `iRacingDeck`). Read, in this order, before
touching anything:
1. `CLAUDE.md` — the rig, the parts, the build commands and the **non-negotiable rules** (they apply to you exactly as
   written; "Claude" there means "any agent").
2. `docs/ROADMAP.md` — the master plan: what exists, what is half-built, every feature, the phases, the decisions.
3. `docs/TASKS.md` — the task cards. **You do exactly ONE card per session** (the one named in your prompt).
4. The detailed spec section(s) your card points to (mostly `docs/SPEC-next.md`), and the existing code you will touch.

## Who it's for
Peter is disabled. Everything must be automatic or one press on the Stream Deck (or a wheel button). He must **never
have to think**: one obvious button per screen, plain words, big targets, sensible defaults, no settings to configure,
no questions the system can answer itself. The look is premium black/gold broadcast style — never cheesy, no emoji,
no gimmicks. User-facing text is plain English.

## Hard safety rules (short version of CLAUDE.md — the full text wins)
- **Never act while Peter is driving or about to.** Check `irdeck-cli.exe state` (onTrack/telemetry) and use
  `tests\guard.ps1` (`Assert-RigFree`, `-NeedAway` for anything that starts the sim or clicks in the iRacing app).
  No clicks, keys, focus changes, app restarts, deploys or popups during a session.
- **Never write iRacing's own files** (`Documents\iRacing\*.ini`, `controls.cfg`, the install folder) — read-only.
  If a feature needs an iRacing setting changed, stop and write the exact request in your report.
- **No downloads, installs, accounts, credentials, paid APIs** unless your card says Peter already approved that exact
  item. Never enter or store passwords/tokens. Never change Windows or security settings (prepare a one-click `.cmd`
  + UNDO in `tools\` instead). Never bypass the Simucube / Control Box torque-off or e-stop.
- **Packaged-app redirect:** start GUI apps and installers through `explorer.exe` (see CLAUDE.md rule 3).
- **iRacing UI automation:** verify the page/dialog before every click; never type outside a verified field.
- **Deck add-on and MAIN page:** never run `deck-intro\install.ps1` or `build-deck.ps1` yourself — Peter must click
  Install and the lead batches these. Write the exact change in your report.
- **Deploying irdash:** only `dash\build.ps1` (it refuses while unsafe — exit 2 means "not now, try later").
  Never kill irdash, irdashies, CrewChief or Stream Deck by hand.
- **Work while he races is fine** (edit code, compile with `-NoDeploy`, offline tests on OLD .ibt files) at BelowNormal
  priority, ≤ 2 cores, downloads throttled. Everything live waits until `state` shows `sim=False`.

## How to work (cheap, focused, verifiable)
- For new work, read `docs/QUALITY-GATES.md` and the relevant role playbook in `docs/skills/`.
  A card's `done` status is not a release gate: record contract, engineering, visual and real-rig evidence separately.
  A builder may leave live evidence pending; only the lead can call a feature shipped after that check.
- One card = one session. Stay inside the card's **Files** list; if you must touch another file, keep it to the
  smallest edit, re-read it right before editing (other agents may have changed it) and list it in your report.
- C# 5 only (Windows' own csc): no `$"..."`, `?.`, `nameof`, expression-bodied members, `out var`. No NuGet, no
  frameworks, no npm. Web pages are plain HTML/CSS/JS served by irdash from `dash\www\v2`.
- Match the code around you: short comments that say *why*, plain names, logs in `irdeck.log` / `dash\irdash.log`
  style.
- **Tests are the definition of done.** Every card has a gate. Write or extend a PowerShell test in `tests\` (dot-source
  `tests\guard.ps1`, `Assert-RigFree` at the start, `Section '...'` before each part, `ok`/`FAIL` lines, pictures to
  `tests\shots\`). Run it. Never claim something works without a test result or a screenshot you looked at.
- Compile check: `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` and, for irdeck,
  `build-irdeck.ps1` (it updates `keys\*.exe` — only when the rig is free).
- Don't refactor what your card doesn't ask for. Don't delete files you didn't create (move to `backup\` instead).
- If you are blocked (needs Peter, needs a download, a rule would be broken), stop and say so in the report.

## Your final report (always, short)
Write it to `docs\tasks\log\<card-id>.md` AND print the same as your last message:
```
CARD: <id> <title>
RESULT: done | partly done | blocked
GATE: <the gate> -> passed / failed (test name: N ok, M FAIL)
FILES: <every file you changed or created>
NEEDS PETER: <none, or the exact one-line request>
NEEDS LEAD: <deck/add-on changes, deploys refused, follow-ups>
NOTES: <max 8 lines: surprises, risks, what the next card should know>
```
Then tick the card's status line in `docs/TASKS.md` (`Status: done YYYY-MM-DD` or `partly: ...`).

## Premium visuals rule (Peter, 2026-10-11 - non-negotiable)
- Cars, liveries, drivers, tracks and logos are shown ONLY with real assets: iRacing's own official images or pictures
  captured inside iRacing (replay camera, UI hidden). Never drawings, clip-art, generic silhouettes or stand-ins.
- No real asset available = clean typography only, and write in NEEDS PETER what is needed. Do not improvise.
- Any new visual element: picture side by side with a reference product (iRacing UI, F1 TV, Pi Toolbox), an independent
  critique "would this ship in a premium product?", and the lead's look - before it goes live on Peter's screens.
