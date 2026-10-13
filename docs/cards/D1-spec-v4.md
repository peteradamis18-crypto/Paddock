You are the product + engineering lead drafting **PADDOCK v4**, the spec a team of cheap coding models will build from,
card by card. All project documents and reviews are attached below. Read them all. Today is 2026-10-11.

## Ground truth (overrides anything older in the attached docs)
- Peter is disabled; everything is one Stream Deck press or automatic; he must never have to think. Premium black/gold
  broadcast look, real assets only (AGENTS.md premium visuals rule), copy rules in COPY-RULES.md.
- Peter's answers (docs\HANDOFF-lead.md "Peter's answers") are the product direction. Also confirmed 2026-10-11 evening:
  recording rules exactly as in the handoff (auto-record in car, last 3 sessions + PB laps + incident clips, SAVE keeps
  forever, 30 GB recent / 150 GB saved / never below 50 GB free, HEVC) - card S1 is building SAVE RECORDING now, treat it
  as done-in-progress; HOME gets THIS WEEK and LAST OUTING back.
- vault=1 and recorder=1 are ON in irdash.ini (R1 thought they were off - wrong). official=0 today.
- The iRacing members Data API is not usable. Schedules come from iRacing's season PDFs/pages and the sources in
  docs\research\calendars-2026-10.md.
- R1 reviews are an inventory, not the product vision. post-session-landscape.md, pi-toolbox-features.md and
  fourth-screen-tv.md are the market research.

## What to write (markdown, English, plain, no filler)
1. **Product in one page**: the five moments of Peter's day (before driving / driving / straight after / later on the top
   screen or phone / sharing) and what Paddock does in each, which screen, which press.
2. **Feature areas**, each with: purpose for Peter; the screen/deck/phone surface; what the best tools do (name them) and
   what we take; data sources; what exists in code today (file names) and the verdict keep / fix / rewrite / delete;
   acceptance tests written as USER JOURNEYS (e.g. "press SAVE on the deck after a race -> the session plays on the phone
   within 2 min"). Areas at least: Recording & Vault; Post-session analysis (Pi Toolbox Ultra depth: time loss where and
   why, lap vs lap / reference / other drivers, over sessions, video in sync, track maps from .ibt Lat/Lon/Alt, corner
   names, weather); Cosworth Pi Toolbox integration (one press opens the session in his free edition) ; Pro comparison;
   Studio (cinematic replays + editor); Sharing (YouTube, iMessage, overlay optional); 4th-screen TV view (no second
   account; data-drawn broadcast view, real assets only); Official racing + race weekend + real-world calendar (upcoming
   iRacing races for HIS series and tracks: what's on, when, owned or not; real-world series schedules with session times
   and short previews); Stats/career (iRating/SR/results history); HOME (incl. THIS WEEK, LAST OUTING, livery hero shot);
   Deck; Phone; Friends mode / racing line; Replay controls; AI races; Design system & polish; Housekeeping; Later (voice,
   phone away from home).
3. **The 19 missing items** from docs\HANDOFF-lead.md: a table, one row each, item -> where it lands in this spec ->
   keep / redesign / "drop? ask Peter". None may be missing; never drop silently.
4. **Build cards**: every card the full build needs, grouped in phases (Phase 0 fixes first, then highest value for Peter).
   Per card: id (V-01...), title, files, depends on, size S/M/L, gate (test + user journey), needs Peter (yes/no + what),
   and an estimate of input/output tokens for a cheap coding model working in an agent loop (count re-reads and test
   iterations realistically: S ~ 300k in / 25k out, M ~ 900k / 60k, L ~ 2M / 120k unless you have a reason to differ).
5. **Cost table** from the card estimates at these prices per million tokens: Hands deepseek-v4.1-flash $0.30 in /
   $1.20 out (assume 60 % of input is cache-hit at $0.03 if it re-reads the same files); review of every diff by
   z-ai/glm-5.3 $0.07 / $4.80 (~60k in / 4k out per card); spec/research work by deepseek-v4-pro $0.66 / $1.98. Add
   20 % for reruns. Show per phase and total. Separately list Claude lead time as "lead checks per card" (count only).
6. **Open questions for Peter**: only what the system cannot decide itself, max 8, each with a recommended answer.
7. **Risks** (max 10) and what we do about each.

Rules: no feature without a data source that really exists; say "unknown" rather than guess; respect every rule in
CLAUDE.md/AGENTS.md (never act while he drives, never write iRacing files, no downloads/accounts without his yes).
Length: as long as needed, but no padding.
