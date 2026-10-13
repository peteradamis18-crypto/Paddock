# PADDOCK v4 - step back, re-plan, rebuild cheaply (lead, 2026-10-11 14:10)

Peter: "I told you to make telemetry analysis software but you thought surface level, not deeply ... TV view is for my
fourth screen ... what do you think I want Cosworth for? ... share recording - didn't build that either ... we need a huge
step back to plan this whole thing from scratch for pennies on the dollar ... Fable intelligence at a fraction of the
price ... I will clarify assumptions, you research great tools on the market and build after that ... don't forget any
detail."

## 1. What went wrong (the lead's own diagnosis, no excuses)
1. **Features before understanding.** I turned one-line wishes into builds without asking what Peter actually does with
   them (TV view became a fake map; Cosworth became a hidden key; "recording" kept only best laps; QUIT x2 fought the
   anti-bounce rule).
2. **Tests proved code, not the product.** Pixel/layout/data tests passed while nothing was clickable, QUIT never fired and
   no video was there to watch. Nobody used it like Peter (tap twice, drive, quit, look).
3. **Breadth over depth.** Ten analysis pages, each shallow, instead of one deep engineering workflow.
4. **Expensive operating model.** Up to 7 Claude builders in parallel + a lead with a huge context: ~$900 of extra usage,
   much of it on reruns caused by builders colliding.
5. **Assumed designs** (silhouettes, filler text, layout seams) that a premium product would never ship.

## 2. New operating model (cheap brain, cheap hands, strict judge)
| Role | Who | Why |
|---|---|---|
| Brain: whole-codebase review, product + tech specs | best long-context reasoning model on OpenRouter (research: docs\research\models-and-tv-2026-10.md) | reads ~1.1M tokens for cents to a few dollars |
| Hands: code changes | best cheap coding model on OpenRouter, via `tools\or-run.ps1` (PowerShell, no installs) | small cards, tests first, iterate on failures |
| Second opinion | a different cheap model reviews every spec and every diff | catches one model's blind spots |
| Judge / orchestrator | Claude, in a FRESH small-context session (Sonnet by default, Opus only for hard calls) | decides, verifies by hand, never bulk-reads |
| Free capacity | Grok Build (Peter's subscription, from Thu) and Claude's weekly allowance (from Wed evening) | used first, before paid |
- **Model choice (prices read from OpenRouter's own model list 2026-10-11 14:30, per million tokens in/out):**
  Brain = deepseek/deepseek-v4-pro-0813 ($0.66 / $1.98, 1M context); second opinion = z-ai/glm-5.3 ($0.07 / $4.80, 1M);
  Hands = deepseek/deepseek-v4.1-flash ($0.30 / $1.20, 1M). For scale: Claude Sonnet 5.5 $2 / $10, Opus 5.5 $4 / $20,
  Fable 5.1 $10 / $50. Benchmarks are mostly vendor-reported (docs\research\models-and-tv-2026-10.md), so a bake-off on
  3 real Paddock cards (same card to each model, the lead scores the result) decides before any big spend.
  A whole-codebase review (~1.1M tokens, split in 2 calls) costs about $1-2 with the Brain; a coding card ~$0.05-0.25.
- **Spending cap:** OpenRouter is prepaid; Peter loads e.g. $20 - it cannot spend more. Claude extra usage: the lead
  stops at 70 % of any cap Peter sets and reads the meter every 15 minutes while anything runs.
- **One builder at a time** on shared files (no collisions, no reruns).

## 3. Phases
**Phase 0 - stop the bleeding (now, small).** QUIT fixed (deployed 13:55). Click-through bug fixed. Next: SAVE RECORDING
(keep the whole session's video, one press on deck / phone / review). Hide the fake TV-view screen until it is redesigned.

**Phase 1 - Peter clarifies (questions in section 5).** Nothing is built on an assumption again.

**Phase 2 - market research (cheap Brain + web).** What the best tools do and how they present it, in depth: Cosworth Pi
Toolbox (Pro), MoTeC i2 Pro, McLaren ATLAS, AiM Race Studio, VRS, Garage 61, Track Titan, Coach Dave Delta, trophi.ai,
iRacing's telemetry, broadcast tools (iRacing spectating, Kapps, Racelab, SimHub, overlay suites). Output: the engineer's
workflow, screen by screen, with what each tool does best. Existing docs\research\*.md is the starting point.

**Phase 3 - deep review of what exists (cheap Brain, two models).** Every module rated: does it work for Peter, depth vs
the best tools, bugs, UX, dead weight (keep / fix / rewrite / delete). Plus a hands-on user-journey audit on the real rig
by the lead (rig on -> drive -> quit -> review -> analysis -> video -> phone -> every deck key), with screenshots.

**Phase 4 - Paddock v4 spec from scratch (Brain drafts, second model critiques, lead edits, Peter approves).** Product
first (who, when, which screen, which press), then the engineering spec with acceptance tests that are USER journeys.

**Phase 5 - build in small cards (Hands via or-run.ps1, Grok, free Claude).** Tests first; every card ends with the lead
using it like Peter and a picture; nothing counts as done otherwise.

## 4. The lead's current understanding (to be corrected by Peter)
- **Analysis depth:** Peter wants a real engineering tool - find exactly where and why time is lost (braking point and
  pressure, release, minimum speed, throttle pick-up, line, gear, balance, tyres), lap vs lap / vs reference / vs other
  drivers, over sessions, with video in sync - Cosworth Pi Toolbox Pro level or better, presented beautifully.
- **Cosworth:** most likely: every session should open in Pi Toolbox automatically, already set up with the iRacing
  workbook, his lap vs his best, ready to dig in - one press, no file juggling; and/or Paddock should match its depth.
  (Question 6.)
- **TV view (4th screen = the top monitor):** while Peter races, people in the room watch the race from other angles
  (TV cameras, other cars) next to live telemetry/timing. Hard limit: one iRacing instance renders one camera - the
  view on his screens. Other live angles need a second iRacing session (spectator account) on a second PC, or come from
  replays between his laps/sessions. (Question 4; research section B.)
- **Recording:** record everything automatically; one press saves the session (or the last minutes) for good; share
  to phone / YouTube / socials from there.

## 5. Questions for Peter (short answers are enough)
1. Analysis: what do you want to SEE after a session - "where am I losing time and why", "compare me to a faster
   driver", "set-up effects", "consistency", all of it? Which first?
2. Comparisons: against your own best only, or against other drivers' laps (Garage 61 / Track Titan style, needs their
   data), or AI/aliens?
3. Where do you analyse: the top screen, a desk PC, the iPhone, all?
4. TV view: is a second PC + second iRacing account acceptable? If not: race timing + track map + battles + your
   telemetry live, plus replays of key moments between sessions?
5. Who watches the 4th screen - friends in the room, or an online stream (Twitch/YouTube)?
6. Cosworth: do you want Paddock to drive Cosworth Pi Toolbox (open each session in it, ready), or to replace it, or
   both? Which Pi Toolbox edition do you have?
7. Recording: keep every session, or only when you press SAVE? How much disk may it use?
8. Sharing: where to - YouTube, Instagram, TikTok, messages? With the data overlay?
9. Stream Deck vs phone vs voice: which is the main control while driving?
10. Must-keep from today's Paddock (what you actually like)?
11. Monthly budget for AI work (OpenRouter + Claude)?

## 6. Do not forget (open items carried over)
Livery photo from iRacing (hero shot); AI race settings rebuild + AI choices on the deck; racing line; phone car/track
search; click-through test on every screen; data-test + video-page-test stale checks; real-session checks (race log,
RACE button, replay jump, share video, RESET CAR); TOWER_PICS off; hourly oversight job re-created when work resumes.
