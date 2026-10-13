You are writing the FINAL **PADDOCK v4** specification: the document a team of cheap coding models (DeepSeek V4.1 Flash
in OpenCode, one card per session, 1M-token context) builds from, and that Peter approves. Attached: the first draft
(docs\SPEC-v4-draft.md), a hard critique of it (docs\review\D2-spec-critique-glm.md), and all source documents.
Peter, 2026-10-11 evening: **"give me an amazing product. nothing is off the table."** Today is 2026-10-11.

## The lead's decisions (these override the draft, the critique and older docs)
1. Recording rules WERE confirmed by Peter on 2026-10-11 (auto-record in car; last 3 sessions + PB laps + incident clips;
   SAVE keeps forever; 30 GB recent / 150 GB saved / never below 50 GB free; HEVC). vault=1 and recorder=1 are ON in
   irdash.ini (lead checked the file). Critique points 1.1 and 1.2 are wrong; ignore them. Card **S1** (docs\cards\
   S1-save-recording.md) is building SAVE RECORDING now: the spec starts from S1 and only adds follow-ups (live check in a
   real session, HEVC playback proven on the top-screen Chrome and the iPhone with an h264 fallback if not, deck key).
2. Accept every other critique point: benchmark/yardstick (fix, not drop), welcome driver card, the TV-view REWRITE card,
   replay TV between stints, MAIN-page 32-key layout proposal with Peter's one yes, Cosworth ready workbook in Pi's own
   user folder + verified open method (test first; explorer.exe file association fallback) + video-sync research, the REA
   question, own-laps vs other drivers' laps question, the explicit Pi-depth list (soft events, math channels, lookup
   tables/constants, multi-lap 3+ overlay, time-offset slide, navigator playback 0.5-8x incl. reverse, PSD/FFT, aero
   balance, setup A/B from logged dcBrakeBias/TC/ABS, G-G/XY scatter, histograms, track map coloured by any channel),
   phone analysis depth, fastest-car-in-my-session comparison from vault\field, splitting big cards, failable gates,
   corrected cost model, and a visible win in the first phase.
3. **Career history goes back years, not "unknown"**: every old .ibt holds the session YAML DriverInfo with IRating and
   LicString for each driver (verify exact field names in a first step). Back-fill Peter's iRating/SR/results history
   from all his old .ibt files offline, plus an optional one-time CSV import from the members site.
4. **Nothing is off the table** - you may propose paid or hardware options, each marked "needs Peter's yes + cost":
   SDK Gaming Live Timing trial (TV view benchmark), a free Garage 61 account for other drivers' laps, a second PC that
   ghost-spectates for real TV pictures (only after iRacing confirms in writing - Peter asks them), local speech model for
   voice control, Tailscale. Rank them by value per pound.
5. **Signature moments** - design these to be the best in sim racing, with exact screen layouts (what is where, sizes,
   which real data), and make them the first things built after Phase 0:
   a) **Straight after a session** (top screen, within 60 s, no press): broadcast-grade debrief - result and position
      story by lap, pace vs field, the 3 corners costing the most time each with a looping video of his lap vs his best
      at that corner, incidents with video, one press SAVE / SHARE / OPEN IN COSWORTH / DEEP DIVE.
   b) **Before driving** (HOME): next official race in HIS series with countdown and local start, owned/not, his PB and
      the field benchmark there; this weekend's real-world races (IMSA/WEC/F1/GTWC) with session times and a short
      factual preview; THIS WEEK; LAST OUTING; his real car hero shot; one big button.
   c) **Deep dive** (Workbench, top screen + phone): Pi Toolbox Ultra-grade engineering with video in sync.
   d) **While racing** (4th screen): a TV view the room enjoys - data-drawn broadcast (timing tower, every car on the
      real GPS track map, battles, his inputs) and, between stints, real replay pictures.
6. **Real-world previews**: short factual preview lines may be generated from official series news/RSS by a cheap model
   at fetch time, with source and date, obeying COPY-RULES.md (no hype, no "you"). Cache everything; mark TBC.
7. **Cost model** (show the maths): Hands deepseek/deepseek-v4.1-flash $0.30 in / $1.20 out, cache hit $0.006 peak /
   $0.003 off-peak, assume 60 % cache hits. Calibration: the first real M-size card (S1) cost about $0.40 after 45 min
   and was still iterating - use **$0.60 per M card, $0.25 per S card, L cards are not allowed (split to <= M)**, then
   +25 % reruns for offline cards and +70 % for live-gated cards. Reviewer z-ai/glm-5.3 ~$0.03 per card. Research/spec
   work: list each research job and its cost. **Lead oversight** (Claude Opus as judge): ~$1.50 per card check and ~$5 per
   phase gate while paid; FREE inside Claude's weekly allowance after the reset on Wednesday 2026-10-14 23:00 UTC - show
   both totals. Give one firm number per phase and a firm grand total (paid-lead and allowance-lead), plus the number of
   live away-windows (10 min each) Peter must give us.
8. Card count: as many as the product needs (expect 50-80). Every card is small enough for one OpenCode session, has a
   Files list (real paths from the docs; say "new file" when new), depends-on, gate = a named test with numbers AND a user
   journey Peter could fail, needs-Peter (none / away window / Install click / a yes). Sequence live-gated cards into
   batched away windows.

## Output (markdown, plain English, no filler, no praise)
1. One-page product summary (the five moments, the signature moments, what is new vs today).
2. Feature areas (as in the draft, deepened per the decisions above), each with best-tool references, real data sources,
   existing code + keep/fix/rewrite/delete, acceptance journeys.
3. Signature-moment screen layouts (ASCII wireframes are fine; real assets only - no drawn cars).
4. The 19 handoff items + benchmark + driver card + every critique item: table item -> section -> card(s) -> decision.
5. Build phases and cards (table per phase).
6. Cost: per phase and total, both lead variants, with the maths.
7. Options that need Peter's yes (ranked, with cost).
8. Questions for Peter (max 10, each with a recommended answer) and **"Where Peter can help"** (concrete one-line actions:
   e.g. email iRacing about ghost-spectating, CSV export, top up OpenRouter, give away windows, click Install).
9. Risks (max 10) with mitigations.
Respect every rule in CLAUDE.md/AGENTS.md (never act while he drives, never write iRacing files, no downloads/accounts
without his yes, C# 5, no frameworks, real assets only, copy rules).
