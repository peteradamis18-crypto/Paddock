# Lead handoff (2026-10-11 16:20) - start the next lead session from here

Read in this order: CLAUDE.md, AGENTS.md (premium visuals rule at the end), docs\PLAN-v4.md (the plan + Peter's
answers below), docs\COPY-RULES.md, this file, then the last 80 lines of docs\tasks\log\oversight.md.

## Why a fresh session
The old lead session reached ~590k tokens of context; every lead turn re-read it and cost real money (Claude extra usage
went $921 -> $969 in about an hour while only cheap models worked). Keep the lead small: delegate reading to cheap models,
read summaries, check results by their numbers.

## Money
- Claude: weekly allowance used up until 2026-10-14 23:00 UTC; extra usage meter $969.29 at 16:15 (Peter's caps were
  exceeded today - see memory budget-pacing.md). Ask Peter before any Claude subagent work until the reset.
- OpenRouter: key saved by Peter as user env var OPENROUTER_API_KEY (never print it; never ask for it in chat). Key limit
  $50; ACCOUNT balance only ~$15 (bought $2170, used $2154) -> Peter must top up for the main build.

## Tools now
- tools\or-run.ps1: cheap-model runner. -Ask <card> -FileList <txt> -Model <id> -Out <md> for reviews (aborts on
  missing files, logs tokens sent vs seen, WARNS if the model saw far fewer). -Card/-Files/-Test for edit loops.
  Costs logged in docs\tasks\log\or\.
- tools\opencode\opencode.exe v1.18.32 (official, signed, sha256 checked) + opencode.json (DeepSeek V4.1 Flash default,
  edits allowed, shell only tests\*, dash\build.ps1 -NoDeploy, irdeck-cli state; no web, no outside folders). Run:
  `$env:OPENROUTER_API_KEY=[Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY','User'); .\tools\opencode\opencode.exe run --model openrouter/<id> "Do the card in docs\cards\X.md"`
  Deploys stay with the lead (dash\build.ps1, build-irdeck.ps1, install.ps1, build-deck.ps1).
- Models (OpenRouter prices 2026-10-11): Brain deepseek/deepseek-v4-pro-0813 $0.66/$1.98; Hands
  deepseek/deepseek-v4.1-flash $0.30/$1.20; 2nd opinion z-ai/glm-5.3 $0.07/$4.80. Fable 5.1 is $10/$50.

## Results so far
- R1 deep review (DeepSeek V4 Pro, code really attached: 575k + 341k tokens seen, $0.38 total):
  docs\review\R1-server-deepseek.md, R1-screens-deepseek.md. Verdict on quality: good inventory and some real points
  (analysis scattered over 4 surfaces: Session Review / Sessions / Workbench / Vault; v1 dashboard dash\www\*.js is dead
  code; cars.js dormant -> delete; EnsureLogAllCars/EnsureSimIni write iRacing files when switched on - keep off),
  but shallow product judgment and some stale facts (it thinks vault/recorder are off - both are ON in irdash.ini).
  Use it as an inventory, not as the product vision.
- B1 bake-off (DeepSeek V4.1 Flash via OpenCode, 4 stale test checks): FINISHED 16:40. It changed only test files; its
  reasoning was good (the PIP corner "failure" was the test counting boxes while the page correctly minimises covered
  text AREA - test fixed, page untouched). It ran the tests directly, so tests\last\*.txt still show the old 12:49 runs:
  VERIFY with `tests\run-all.ps1 -Only data,video-page` (both must be 0 failed) and look at its diff before accepting.
  Its own note: the x4 playback check is borderline (failed once by 0.003 s) - add a small margin if it flaps.
- Research: docs\research\models-and-tv-2026-10.md, post-session-landscape.md, fourth-screen-tv.md.

## Peter's answers (14:55) - the product direction
- Paddock = one-stop super app bringing his tools together; premium; Stream Deck is the main control (voice later).
- Cosworth: emulate Pi Toolbox at its top tier (called "Ultra", not "Ultimate") as closely as possible inside a beautiful
  Paddock harness, AND integrate the free iRacing edition he has (one press opens the session in Pi Toolbox).
- After a session: a LOT of data - performance, stats, competition, drill-down, video analysis, track data. Research the
  many motorsport tools online and imitate the best; don't assume. Analyse on the top screen mostly, phone too.
- 4th screen TV view: live other perspectives of HIS race for people in the room, alongside telemetry, WITHOUT a second
  iRacing account. Research says: no second live camera from one client; only route to real footage is ghost-spectating
  on a 2nd PC with the same account (policy unknown - Peter should ask iRacing in writing); otherwise a data-drawn
  broadcast view (timing tower, every car on the map, battles, his telemetry) - ours or SDK Gaming Live Timing.
- Recording: lead recommended auto-record whenever in the car; keep last 3 sessions + every PB lap + incident clips
  automatically; SAVE (deck/phone/review) keeps a session forever; budgets ~30 GB recent / 150 GB saved, never below
  50 GB free; HEVC to halve size. Peter has not confirmed - confirm, then build SAVE RECORDING first.
- Sharing: YouTube and iMessage, data overlay optional.
- "REA on GitHub - reverse engineering to inspire our build": only morluto/rea (general RE agent) found - ask which.
- Today's Paddock is an OK framework (keep it, fix and deepen).
- Budget flexible but he wants a FULL BUILD ESTIMATE. Rough: cheap-model review/spec ~$5, build ~60-100 cards
  ~$10-20 on OpenRouter, lead oversight ~$20-40 (or free after the Wednesday reset). Firm it up from the v4 spec.

## Bugs fixed today that came from his first real use
QUIT x2 (anti-bounce ate the 2nd tap; confirm keys now 0.12 s); HOME click-through (invisible #homeHost layer);
recorder kept only best laps (needs SAVE). Still open: phone car/track search janky; TV view (fake map) to be replaced or
hidden; Vault vs Performance look alike; Cosworth key hidden.

## Missing, dropped or held - Peter noticed these are gone; none may be forgotten again
Every item below goes into the v4 spec (keep / redesign / drop only with Peter's yes):
1. **Official racing + race weekend + real-world calendar (C-15, ROADMAP Phase 6, SPEC WS8 R1-R8): Peter wants it.**
   Upcoming iRacing races for his preferred series and tracks (what's on, when, which he owns), AND previews/schedules of
   real-world big series (IMSA, WEC, F1, GT World Challenge... with session times). Code exists (official.cs,
   officialcore.cs PDF season parser, official.js) but irdash.ini has official=0, and the HOME redesign (DS-1) hid the
   "Race weekend" panel with CSS. The iRacing Data API is closed, so schedules come from iRacing's season PDFs/pages.
2. HOME redesign also removed THIS WEEK and the LAST OUTING footer - ask Peter if he wants them back.
3. Studio - automatic cinematic replays + editor (C-12, C-13, ROADMAP Phase 4): held, not built.
4. Pro comparison - find and fetch pro/fast drivers' laps, align and render vs his (C-16, C-17, Phase 7): held.
5. Cosworth Pi Toolbox integration (C-14, Phase 5): only a hidden OPEN IN COSWORTH key; Peter wants Pi Toolbox Ultra
   depth emulated in Paddock + one-press open in his free edition.
6. Vault video player + compare two clips (C-08): held; Workbench VIDEO page exists but no clip-vs-clip compare.
7. Events list with PAUSE/JUMP into iRacing's replay (C-37): replay jump built in P2 (SEE IN iRACING), not proven live.
8. SHARE (C-38): share video with overlay built (P2), not proven; YouTube upload and iMessage not built.
9. Live TV view on the 4th screen (C-22, Phase 3b): current tv.js is a data-drawn 3D map Peter rejected.
10. Racing line in friends mode (C-25): never showed on track.
11. REPLAY screen live fixes - COCKPIT / CHASE cameras don't change (C-03).
12. After-race review laps while still in the sim (C-27, partly), quick wins (C-29, partly).
13. AI races: AI 'Last Settings' wiped by the lead's survey (rebuild with Peter's yes); AI choices on the deck (C-33/C-35).
14. Livery hero shot of HIS car from a replay for HOME; phone car/track search jank; Vault vs Performance look alike.
15. Design tokens + welcome driver card (C-10), visual polish (C-11), deck batch (C-09): held since 2026-10-10.
16. Stats/career beyond his own files: iRating / SR history, results history (API closed - needs another source).
17. Track data: real track maps from the .ibt Lat/Lon/Alt (research found them), corner names, weather.
18. Housekeeping: deck speed timings (C-21), root folder tidy (C-19), click-through tests on EVERY screen,
    copy-audit leftovers, data-test/video-page stale checks (B1), hourly oversight job (deleted to save money).
19. Later: voice control; phone away from home (Tailscale, C-20).

## Next steps (in order)
1. Finish/judge B1 (diff review). Run 2 more bake-off cards on DeepSeek V4.1 Flash vs GLM-5.3 (phone search; SAVE
   RECORDING once Peter confirms the recording rules). Pick the Hands model.
2. A vision-model UX critique of the real screens (screenshots in tests\shots) - cheap (Gemini Flash / Qwen VL).
3. Draft the v4 product spec from post-session-landscape.md + Peter's answers + R1, have GLM-5.3 critique it, then the
   lead edits; send Peter a picture-led summary to approve; then cards.
4. Re-create the hourly oversight job after the Wednesday reset if Peter wants it.

## Session 2 stop (2026-10-11 14:40)
- 14:40 CAP PASSED: Claude meter $1008.20 vs hard stop $996.76 (this lead session's own turns, ~$31 in ~30 min). Lead stopped all Claude work. Done before stopping: B1 verified (data 137/0, video-page 99/0) and accepted; tools\or-web.ps1 (OpenRouter web research) + R2 calendars research -> docs\research\calendars-2026-10.md ($0.07); card docs\cards\S1-save-recording.md running in OpenCode/DeepSeek V4.1 Flash via tools\oc-card.ps1 (log docs\tasks\log\or\S1-opencode.txt, .done when finished; opencode.json now allows dash\build.ps1 deploy - guarded); D1 v4 spec draft running on DeepSeek V4 Pro -> docs\SPEC-v4-draft.md (card docs\cards\D1-spec-v4.md, inputs D1-files.txt). NEXT LEAD: judge S1 (read S1.md report, run tests\recorder-test.ps1 yourself, look at a real session file), have GLM-5.3 critique SPEC-v4-draft.md, edit, firm the cost, send Peter the summary.

## Session 2 later (2026-10-11 20:34)
Cap lifted by Peter. Operating model now: DeepSeek V4.1 Flash builds (tools\oc-card.ps1), OpenAI Codex on Peter's Pro plan reviews/fixes hard cards and polishes cards (tools\cx-run.ps1), Claude judges at gates. Spec: docs\SPEC-v4.md; cards docs\cards\v4\*.md (79).
- 20:34 Peter: replace paid-Claude checking with his OpenAI ChatGPT **Pro** plan + clear specs + cheap Chinese models; OpenRouter topped up ($45 at 16:05); yes to preview lines, SDK Gaming trial, freeing 5 MAIN keys (picture first), away filming; comparisons incl. Garage 61 (he signs in himself). Codex CLI rust-v0.162.1 downloaded with his yes (sha256 = GitHub digest, all exes signed OpenAI OpCo) -> tools\codex\; he signed in (tools\codex-login.cmd). tools\cx-run.ps1 runs Codex jobs: per-run overrides windows.sandbox=unelevated (his app config says elevated - untouched) and computer-use/browser plugins + node_repl OFF (a first run tried computer use). 79 v4 cards written by DeepSeek V4 Pro ($2.04) -> docs\cards\v4\; Codex polishing them against the real code per phase (CP-*). Codex reviewed S1: REJECT (session-boundary segment race, finish deletes segments in use, unlocked state, SAVE right after a session saves the PREVIOUS one - lead confirmed recorder.cs:1081/1281, 20 GB clip floor, budget race, weak tests 11/14/15). S1b fix card running on Codex (workspace-write). P0-08 running on DeepSeek/OpenCode.

## STATE AT 2026-10-11 23:25 (lead session 2) - start here
- Model: DeepSeek V4.1 Flash builds (tools\oc-card.ps1, tools\build-queue.ps1 = build -> Codex review -> auto fix); Codex on Peter's
  ChatGPT Pro reviews/fixes (tools\cx-run.ps1, tools\fix-from-review.ps1); Fable 5.1 via OpenRouter for councils/specs (>= 32k out).
  **Codex jobs must never deploy irdash** (an irdash started from a Codex job filmed 0 frames) - build.ps1 refuses via PADDOCK_NO_DEPLOY.
- Spec docs\SPEC-v4.md (79 cards in docs\cards\v4, polished by Codex against the code). Deck: docs\deck\DECK-v4.md + council files.
- LIVE tonight: deck v3 (MAIN rebuilt, add-on 1.8.0.0 installed by Peter): smart key (deckstate.cs shared by irdeck+irdash,
  /deck/state), SKIP SESSION x2, OFFICIAL, CAR TRACK; confirm bounce fix (lead); MY DRIVE fixes; AI RACE fails closed.
  HOME THIS WEEK + LAST OUTING (home 95/0); fake TV view hidden (P0-03); GPS maps (P0-05 + fix: no reads while connected).
- BROKEN: recorder filmed nothing in Peter's real sessions tonight (see oversight.md 23:2x). Proof pending: docs\tasks\log\away-runner.log
  (section 10 through the lead-started irdash). If it still fails -> debug ddagrab in irdash's own context.
- OPEN: P0-09 / P0-06 fixes done (re-review + lead check owed); P0-01/02 live checks; DK-1s live survey in an away window, then
  airace save/start (Peter sets up his usual AI race once); DK-7c add-on render test; JOIN for the smart key (v2); P0-07, P0-10, Phase 1 debrief.
- OpenRouter balance 32.61. Claude cap lifted by Peter (still keep the lead small).
