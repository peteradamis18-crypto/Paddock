# 12 - Insights, review flow, Coach Dave Delta, and outside data

Date: 2026-11-13. Method: web search and page fetches (no downloads, no accounts). Read with 02 and 06; nothing from them is repeated.

## How much to trust this
- Almost every insight example below comes from the vendors' own pages. I found no independent hands-on review that shows real Delta output. Treat the wording as "what they choose to show off".
- Fetches that failed: garage61.net pages (they load with JavaScript and came back empty), Trophi's independent review (403), a Delta 2.0 article (bot check), the npm page for the Garage 61 client (503). The Garage 61 API facts come instead from its OpenAPI file, which loaded fine.
- Reddit and forums: searches returned nothing about Delta and iRacing performance. See section 3. That is a gap, not a clean bill of health.
- Quotes are short fragments only.

## 1. Insights, as the best tools word them

### Real example sentences (16)
Coach Dave Delta, Auto Insights (vendor pages):
1. "You coasted 0.6s more than the reference, you might be hesitating on the throttle"
2. "Your exit speed was 5 kmh slower than the reference"
3. "Your exit point was 2 m before the reference"
4. "You lost 0.4s after exiting the turn"
5. "Focus on SQ5, you could gain at least 1 position" (a lap-level line, by mini-sector)
6. "you're braking too early into turn 5"
7. "carrying too little speed through the entry of turn 8"
8. "getting on the throttle too late exiting turn 11"
9. COTA turn 1 walkthrough: braking "far too early", 30 km/h too slow, plus a late turn-in and wide exit "costing 0.5 seconds"

LapBrain (a smaller tool, but the only one that publishes a full card format):
10. "Hold trail brake into Turn 3"
11. "Move brake marker back 10m"
12. "Roll on throttle 0.3s earlier through T3"
13. "Entry speed 8 km/h too hot" (T5 card)
14. T3 card: "-0.18s available" when the apex is early

Track Titan Coaching Flows (its own blog):
15. "I'm overshooting my braking phase" (step 1), then the effect, then "my exit speed is compromised", then "That single entry mistake caused the majority of my time loss"
16. Skill scores on user pages, for example "B1 - Braking - The Braking Point" 75%, with a note to fix consistency first

Trophi.ai: only the style, not exact lines: "where you're braking differently, carrying less speed, or compromising your corner exit." The cards are per track section with a technique grade and a "clear recommendation" tied to a video moment. Multi-lap results are scored on a radar chart (braking, throttle, steering, control).

### How each tool structures an insight
| Tool | Unit | Order | Where on screen | How many |
|---|---|---|---|---|
| Delta Auto Insights | Every corner, split into 4 phases: braking, entry, apex, exit. Each phase gets a time delta and 1 to 3 sentences | Red (losing time, "focus here first") and green (matching reference) | An Analysis panel on the left of the app, opened in the garage or from Session History. The mock-up shows your time vs the reference, a sector list (SQ1 to SQ8) with deltas, then the insights grouped by phase under it | Not capped. Their own mock-up: 1 apex line plus 3 exit lines for one corner, plus 1 lap-level line. It analyses EVERY corner |
| Trophi debrief | Track section | Sort by time lost (default) or track order | Video with telemetry overlaid, narrated by the AI coach | All sections, jump to the costliest |
| LapBrain | Focus card: what to change, evidence from your data, what to do next session | By time you could gain; top card is the biggest | Cards | Few; "the rest give you options" |
| Track Titan | A chain: main problem, its effect, the result, a verdict, then a few examples from your best lap | One root cause per flow | A flow on the session page, toggle against the classic delta map | One at a time |
| VRS | A highlighted stretch of track, "biggest opportunity", no sentences | Single biggest first | Highlight on the analyser | 1 |
| Garage 61 | No insights. You read the traces | n/a | n/a | n/a |

What the best ones share: a corner name, a number in seconds or metres or km/h, a direction (earlier, later, slower) and a single next action. The weakest ones (Trophi marketing, VRS highlight) give a place and no number.

What Delta itself warns about: it needs 2 to 3 clean laps, traffic or a spin skews it, it works best when the reference is 0.5 to 1.5 s faster than you (much further ahead "flags nearly everything red"), and one reviewer found a suggested braking point "felt too risky in an actual race situation". Track Titan's tips "can feel generic at higher skill levels" (a competitor's article, so partial).

### Style guide for Paddock insights
**Screen:** one screen straight after a drive. Three cards at most, ranked by seconds lost. Fewer is fine. Never pad to three.

**Each card has four lines:**
1. Corner: its name or number, and where on the lap ("Turn 5, Tower Hairpin").
2. What happened: one plain sentence, in the driver's own terms. "You braked 14 m earlier than your best lap."
3. The number: seconds lost at this corner, large and gold, one figure. A second small figure (metres or km/h) may sit beside the sentence, not another sentence.
4. Try this: one action, small. "Brake at the 100 m board next lap." "Wait until the car points straight, then full throttle."

**Wording rules**
- Compare to something he drove. Say "your best lap today" or "your best lap here" (the card says which). Never "the optimal line" or "the reference".
- Lead with the thing that is different and measurable, not the guess about why. Delta's "you might be hesitating" is a guess; make the guess a small second line, marked "likely".
- Metres, km/h and tenths of a second. No phase jargon ("trail braking", "apex phase", "rotation") unless he already uses it.
- One cause per card. If two things differ, show the bigger one.
- Say the sample size: "in 6 of your 8 clean laps". A one-off becomes "once, on lap 4".
- Be quiet when unsure. Under about 3 clean laps, show the single costliest corner with its numbers and no advice.
- Praise only with a number: "Turn 9 is faster than your best by 0.06 s." No "great job".

**What NOT to say**
- Anything with no corner and no number ("Work on your braking").
- Percentages that look like a score ("Pace 96.5 %").
- Anything about other drivers' laps we cannot supply, or a "pro" line that is not like for like (06 finding 2).
- Cause statements as fact when the rule is a correlation (06 finding 4).
- Advice that needs a setup change or a wheel setting; he is not going to open a menu.
- Fear or scolding ("mistake", "wasted"). Use "lost" and "gained".
- More than one idea per sentence, anything over about 14 words, anything that needs the traces open to understand.

## 2. How a review is organised

### The flow all of them use
Session list, then lap list, then compare two laps, then a corner. Delta and Track Titan add a step 0: an automatic summary. Details seen:
- **Delta:** the Analysis panel (insights) opens after a drive; Session History holds old sessions; a "load reference" widget picks the comparison lap; you can drag a lap time into the main or reference column; a switch in the centre of the map flips between your fastest lap and the reference. Whether any reference is pre-selected is NOT stated in its docs. The insights analysis starts at the first flying lap, after the out-lap.
- **Track Titan:** a toggle decides whether a session opens with the Coaching Flow or the classic delta map.
- **Trophi:** the debrief is built when the session ends; sort by time lost or track order; combine several laps to see repeated mistakes.
- **Garage 61:** a lap list per session, then the analyser, compare to any shared lap of the same car. Its founder said in 2024 that "compare every lap to your best valid lap" was not possible. Not confirmed since.
- **VRS:** the free tier allows about one comparison session a week; a data pack gives the coach lap, setup, replay and walkthrough videos.
- **Race Engineering Center (a free analyser, as a plain example):** lap list shows name, time, delta to the best loaded lap and delta to the best in the stint; one lap is pinned "always show" as reference.

### Which lap is the reference by default
| Tool | Default | Evidence |
|---|---|---|
| Delta | NOT STATED. You choose pro, leaderboard, friend or own lap | Docs say nothing about a default |
| Trophi | You choose: expert benchmark or fast community lap | Its page |
| Track Titan | Own laps and community laps; theoretical best on paid | See 02 |
| VRS | A datapack lap (coach), or your own | Its model |
| Garage 61 | Another shared driver's lap in the same car | Pitch and API |
| RE Center | Best lap loaded | Its manual |
So nobody I found defaults to "your all-time best at this track and car". The common practice is: you pick. For Paddock, with no other drivers' laps, the best default is the quietest honest one: his best clean lap of THIS session, falling back to his best at this car and track when the session has under 3 clean laps. State which one on the card. (06 already warns that a best lap with a lucky tow is a poor reference; the all-time best has the opposite risk, a different fuel load or setup.)

### No complete lap, practice vs race
- **No complete lap:** no tool I found shows anything useful; Delta needs 2 to 3 clean laps and starts after the out-lap. Paddock's "ALL THE DATA over time" (06) is already a better fallback than most. Say plainly "No full lap yet" and show what a partial lap does give: top speed, braking marks, time on throttle.
- **Practice vs race:** the vendor pages do not separate them. Delta says "work best with a few laps, return to the garage, review, go back out", so it is built for practice. In a race, lap-by-lap insight is mostly traffic. The sensible split for Paddock: practice and qualifying get corner cards; a race gets the race story (position by lap, pace vs field, the three costliest corners with clips, 06) and at most one corner card, clearly marked "in a clean-air lap".

## 3. Coach Dave Delta facts

**Plain answer on "will it destroy my PC":** I cannot prove it will or will not. No hard evidence either way for iRacing. What exists:
- Delta's FAQ admits users reported FPS drops running Delta with Le Mans Ultimate "from background processes or resource contention". Its fixes: close unnecessary apps, exclude Delta from real-time antivirus scanning, keep Delta in the background.
- No system requirements are published on its pages.
- A competitor's article (Sim Coaches, which sells TrackPro) says Trophi has "documented CPU overhead" on mid-range rigs and gives no figures for Delta.
- iRacing's own support says third-party overlay apps can cause stutter, and since 2025 Season 3 it shows a High CPU Usage warning. Season 4 2026 notes say it freed CPU in the physics loop, most visible in sessions with many cars.
- Delta has no in-game overlays (on its roadmap), so it does not draw on top of the sim. Its windows can be dragged to a second monitor.
- I found no setting named telemetry rate, pause during race or overlay off. Its settings mentioned: Leaderboards, Video Capture, "open Delta when your PC starts". **Video Capture is the likely heavy part** (it records onboard video). That is my reading, not a published fact.
- Peter-specific warning from Delta's own FAQ: if it shows "Waiting for session", close SimHub, CrewChief and wheel software first. Peter runs SimHub (flag box), CrewChief and irdash. That implies a possible conflict with other telemetry readers. iRacing's own shared-memory feed allows several readers, so I would test it, not assume it.

**Cheap way to settle it** (for the lead, never during a session): run one 20 minute AI race with Delta off and one with it on (video capture off, then on), and compare the fps the rig already logs per session (the performance page in 06). His baseline is about 104 fps; a drop of more than a few fps, or a High CPU warning, is the answer.

**Data access**
- **API:** none mentioned anywhere. **Local HTTP:** none mentioned.
- **Export:** sessions export only as Delta's own `.delta` file. Not CSV. It cannot import `.ibt`, MoTeC or VRS files either (its FAQ).
- **Storage:** session data is "stored both locally on your PC and synced to the cloud", no hard storage limit. I did not find the folder path, and the format is proprietary, so Paddock cannot read it. Treat Delta as a closed box.
- **Setups and datapacks:** it installs the week's pro setups automatically (1,000+ iRacing, LMU, ACC, AC Evo setups), per car and track, when you join a session. Those are iRacing `.sto` files going into iRacing's own setup folder, which CLAUDE.md rule 2 says Paddock never writes without Peter's yes. Delta doing it is Delta's affair; Paddock must not mimic it.
- **Pricing (cached pages disagree on currency):** $12.49 per month; $10.50 per month billed quarterly; $9.08 per month billed $109 a year. One subscription covers setups, telemetry, Auto Insights. No free tier or trial found on the comparison page, though one reviewer cites a 7-day trial for Trophi, not Delta.
- **Needs:** an account, Discord login, an installer to unzip and run, antivirus whitelisting.
- **Native iRacing telemetry (Delta 3.0)**: records laps in the background. How it reads iRacing (shared memory, .ibt) is NOT stated.

**Read of the owner's question.** Delta cannot feed Paddock, so "integrating" it means two apps side by side. The strongest part of Delta, Auto Insights, is the corner/phase table Paddock already builds in `analysis.cs`. The part Paddock cannot match is the pro reference lap and the video of it. A middle road: Paddock keeps its own review (own laps only) and shows a plain link "Open in Delta" if installed. That is cheap, and it keeps Delta's cost out of Peter's race unless he starts it.

## 4. APIs

### Garage 61 (verified from its OpenAPI file)
- Real, documented API. Auth: personal access token (bearer) or OAuth2 authorisation code. Scopes include `driving_data` (own and teammates), `analyses`, `datapacks_subscriptions`, team scopes.
- Own and team laps: `GET /laps` (a track is required; car and user filters), `GET /laps/{id}`, `GET /laps/{id}/csv` (telemetry as CSV), `GET /laps/{id}/ghost.bin` (iRacing ghost file), `GET /events` and `/events/{id}` (sessions and every lap, valid or not), `GET /me/statistics`, `GET /analyses`.
- **Other drivers' laps: no by default.** "By default, apps can only access laps driven by the authenticated user or their teammates. Some apps may be approved for all visible laps." Filters to see telemetry or ghost availability need a Pro plan. A third-party analyser (REC) confirms the same limit.
- Data packs: you can subscribe an account to a datapack by API and read a team's pack laps (CSV, ghost, replay, setup `.sto`), if the account has telemetry viewing permission.
- Rate limits: applied since 25 Aug 2026; a 429 with retry; a small burst then steady. No numbers published in what I could read. Cost: no separate API fee found; account tiers are free or Pro at EUR 5 a month billed yearly (Delta's comparison article).
- **Could Paddock pull a reference lap for the same track and car?** Only a lap Peter himself or a teammate drove, or a team datapack he belongs to. A top-driver reference needs Garage 61's approval for the app. A realistic use: a friend or team-mate in a Garage 61 team uploads a good lap, Peter's Paddock fetches the CSV. That needs an OAuth sign-in or token pasted once, and a team. Nothing automatic for a stranger's lap.
- Telemetry in Garage 61 is less detailed than `.ibt` (REC's manual says import `.ibt` where possible).

### VRS
- No public API found in anything I read. Pack contents (setup, coach telemetry trace, replay, walkthrough videos) are only through the VRS site and apps. Nothing for Paddock.

### iRacing's own data API (members-ng)
- Nothing in `dash\src` calls it (my grep found no match there or anywhere in code). `docs\benchmark.md` (B2) and `docs\cards\R2-calendars.md` say it is not usable now.
- Access today: the password login ended 9 Dec 2025; OAuth2 is required; iRacing paused issuing client ids (support article, March 2026). The Password Limited grant is for an unattended app but needs the client to be registered by iRacing, a maximum of 3 users, strict rate limits (headers `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`; breach returns 400 and locks the client for a while) and should be used "once at client start-up". Two-factor is not enforced for that grant. The Conditions of Use ban scraping.
- What would exist if access arrived: `member/chart_data` (iRating, TT rating or licence history, by category; from a third-party doc, unverified), `stats/member_bests`, `stats/world_records`, results per session.
- Verdict: do not plan the rework around this API. Everything in the rework should run from the `.ibt` files and the live feed, with the data API as a later bonus once Peter gets a client id from iRacing.

## 5. Progress views done right
I could not reach SimRacingStats or iRacing's member pages, so this part is thin and partly from the docs already in this repo.
- **iRating / licence history:** iRacing's own site draws it as one line per category (oval, road, dirt) over time. Third-party sites copy this. The chart is the standard for ratings, and the only one in the evidence with a clear shape: one line, one point per ranked race, plus the safety rating beside it. Needs the data API (above) or Peter's own race log. Paddock's own race log already holds each race's iRating estimate; 06 says it is an estimate from "the community formula", so label it.
- **Pace vs field per track:** needs other drivers' times. Paddock only has the drivers in sessions it logged (06 finding 2). Show "vs the cars you raced", with the count, or not at all.
- **Personal progress that is honest:** per car and track, best lap per session and average of the best 5 (06 recommends this instead of "best lap over time"). A dot per session, not a stepped line. Add the dates of setup or car changes if known.
- **Consistency:** spread of the best 5 laps per session, shown as a bar, not a histogram (02).
- **Corner trend across sessions:** the one view that no tool shows well and 06 listed as a gap: the same corner's time lost, session after session. "Turn 5: lost 0.31, 0.22, 0.12 s over three sessions" is a progress statement that points at something.
- Skip: pie charts, big totals, anything from Track Titan's skill score (it is a vendor-defined number).

## 6. What to do, in order
1. Build the one post-drive screen to the style guide above, from own laps only (reference = best clean lap of this session; fall back to best at car and track; say which).
2. Treat Delta as optional: no integration to build, no API, nothing to read. Offer an "Open Delta" link only.
3. Test Delta's load once with the same AI race, Video Capture off then on, and log fps. Until then, do not tell Peter it is safe.
4. Do not plan around Garage 61 for strangers' laps. Consider a later opt-in "import a team-mate lap" if he has a friend on Garage 61.
5. Keep iRacing's data API out of the rework until a client id exists.

## Links
- Delta Auto Insights page: https://coachdaveacademy.com/delta/auto-insights/
- Delta Auto Insights how-to (docs): https://coachdaveacademy.com/documentation/how-to-use-auto-insights-ai-coaching-in-delta/
- Delta AI coaching tutorial: https://coachdaveacademy.com/tutorials/ai-sim-racing-coaching-unlock-faster-lap-times-with-delta-ai-auto-insights/
- Delta 6.0 summary and pricing: https://coachdaveacademy.com/delta/
- Delta help centre and FAQ: https://coachdaveacademy.com/documentation/coach-dave-delta-help-centre-the-complete-faq-guide/
- How to compare laps in Delta: https://coachdaveacademy.com/documentation/how-to-compare-laps-in-delta/
- How to install Delta: https://coachdaveacademy.com/documentation/how-to-install-coach-dave-delta
- Delta vs Garage 61: https://coachdaveacademy.com/tutorials/coach-dave-delta-vs-garage-61-which-is-best-for-you/
- Delta vs VRS: https://coachdaveacademy.com/tutorials/coach-dave-delta-vs-vrs-which-one-is-best-for-you/
- Delta native telemetry news (Traxion): https://traxion.gg/native-telemetry-tracking-and-analysis-added-to-coach-daves-delta-service/
- Trophi lap analysis: https://www.trophi.ai/sim-racing-features/lap-analysis
- Trophi review (sponsored): https://simracingcockpit.gg/i-got-an-ai-sim-racing-coach-and-found-2-seconds-a-lap/
- Track Titan Coaching Flows: https://www.tracktitan.io/post/november-2025-update-coaching-flows
- LapBrain debrief help: https://lapbrain-help.pages.dev/getting-started/reading-your-debrief/
- AI coaches comparison (vendor): https://simcoaches.com/blogs/best-hydraulic-sim-racing-pedals-2025/best-ai-sim-racing-coaches-in-2026-complete-comparison
- VRS FAQ and pricing: https://virtualracingschool.com/faq/ and https://virtualracingschool.com/pricing/
- Garage 61 OpenAPI spec: https://garage61.net/api/openapi/v1.json
- Garage 61 what's new feed: https://de.garage61.net/api/whatsnew.rss
- Garage 61 permissions page (did not load): https://garage61.net/developer/permissions
- Race Engineering Center, Garage 61 import: https://race-engineering-center.github.io/rec-user-manual/analyzer/cloud_db
- iRacing OAuth token endpoint: https://oauth.iracing.com/oauth2/book/token_endpoint.html
- iRacing OAuth client credentials (support): https://support.iracing.com/support/solutions/articles/31000177790-oauth-client-credentials
- iRacing high CPU warning: https://support.iracing.com/support/solutions/articles/31000176739-high-cpu-usage-warning
- iRacing stutter guidance: https://support.iracing.com/support/solutions/articles/31000141916-dealing-with-freezing-and-or-stuttering-issues
- iRacing Season 4 2026 notes via Delta: https://coachdaveacademy.com/announcements/iracing-season-4-2026-news/
- Third-party iRacing data API doc (chart_data): https://glama.ai/mcp/servers/@emilioSp/iracing-data-mcp-server/blob/39cfc82ef5b1bb13ad8fa1724ee4644d42a4f5b0/README_API_Documentation.md
- Repo: docs\benchmark.md (B2 data API and Garage 61 notes), docs\cards\R2-calendars.md
