# Paddock rework: the list (started 2026-11-12)

Peter's words, tidied, then Claude's additions. Nothing is built until Peter has seen the evidence (phase 1) and
approved the designs (phase 2). The rule for every item: **copy what the best tools do, don't invent.** Every design
goes next to real screenshots of the tools it learns from.

## A. What Peter asked for

### Look and feel (the whole front end)
1. **One big design upgrade.** Too much of it is filler. Every screen gets fewer things, shown better.
2. **Start-up with real pizzazz.** When the rig wakes, something worth watching on the deck and the top screen, without
   being cheesy.
3. **A proper clock.** A premium analog clock face in the middle of HOME, in the style of the timing clocks at Le Mans
   or F1 (not the Rolex logo: that's a trademark).
4. **HOME rethought.** RIG ON / iRacing UI OFF and the other parts: keep only what earns its place.
5. **The schedule laid out properly**: what's on, when, and what Peter is racing next.
6. **Side-screen photos**: many more of them, and the car photos are out of order. Fix the order.

### Race videos
7. **Pick many races at once** (multi-select), then one action for all of them.
8. **Delete without the double click.** Replace "click, then click again" with something cleaner, such as select
   then one DELETE with an undo that lasts a few seconds.
9. **Straight to YouTube.** One press uploads to Peter's channel. He signs in to Google himself, once.
10. **Title templates.** For example "GR86 Cup · Road Atlanta · P3 from P9 · 12 Nov 2026". Never type.
11. **Quick trim.** Cut the out lap (and the cool-down) by itself before upload.
12. **Talk over the race.** One press to start the commentary, one to stop, and it's added to the video.

### The library (today's "Vault")
13. **New name and new layout.** "Vault" goes. Races, practice, moments and laps are organised the way people expect:
    easy to browse, clean, with a sensible storage plan behind it.

### Data and coaching
14. **Benchmark against the real tools** (Garage 61, VRS, Coach Dave Delta, Track Titan, MoTeC, Cosworth Pi Toolbox and
    others) using their published screenshots. Keep the charts the pros use and drop the ones we made up (for example
    "best lap over time" says little).
15. **Cosworth: be honest about what's real.** Write down exactly which data Paddock pulls in, which Cosworth views it
    matches, and what is ours. If it matches Cosworth, show it as Cosworth does.
16. **Sessions**: Peter tries it, then it gets the same benchmark treatment.

### Performance (the stutter)
17. **Find out why it froze two races ago,** and make the performance data ten times more useful: what happened, when,
    and why, in plain words.

### The in-race top screen
18. **Rebuild the screen he looks at while racing.** Today there are two standings lists side by side. There's nothing
    about damage, and the key facts are hard to see. Learn from coach tools and the pros' timing screens: one standings
    list, and the key facts big.
19. **Tyre pressure** (see C1) and **damage** (see C2).

### Stream Deck
20. **Refine it** after the screens are settled, so the deck and the screens use the same words.

### How we work
21. **Plan first, then a detailed build plan,** then delegate to the most capable models that are also efficient.

## B. Claude's additions (beyond what Peter said)

22. **One design system** for the top screen, the deck and every page: one type scale sized for reading at a glance
    from the seat, one set of colours, one grid. That is what makes it look premium; most of today's mess is ten pages
    each doing their own thing.
23. **Screens that change by themselves with the moment**: before the race, in the car, after the race. Fewer menus,
    and Peter never hunts.
24. **Race briefing before every race**, shown by itself: the track map, the weather, his past results there, a fuel
    plan, and how strong the field is.
25. **A race card after every race**, made by itself: result, places gained, incidents, best lap against the field. The
    video is already trimmed, the title already written, and one press publishes it.
26. **Highlights found by themselves**: overtakes, close calls and incidents from the data become YouTube chapters
    and a 60-second Short.
27. **A performance black box**: always records frame times alongside what the PC was doing. After a stutter it says
    in one line what caused it (another app, the recorder, the CPU, a shader, the network). It is silent while he
    drives and shows in the debrief.
28. **A quiet PC during races**: Windows Update, OneDrive, indexing and other hogs paused for the session, and handed
    back afterwards.
29. **Network watch**: ping, lost packets and jitter to iRacing, logged per race. It shows only when it was bad.
30. **Storage that looks after itself**: rules like "races kept forever, practice kept 14 days", a clear gauge of disk
    space, and nothing silently deleted.
31. **A reference lap to compare against** (Garage 61 style): where in each corner time is lost, using the standard
    traces (speed, throttle, brake, delta) rather than invented charts.
32. **Voice control**: "record that", "share my last race", "how much fuel". A big help on top of the deck, because
    some days pressing is harder than talking.
33. **Progress that means something**: iRating and safety history, and pace against the field at each track, where
    iRacing's data allows.
34. **Phone**: watch and share races from the phone (the phone page exists already).
35. **A self-check every night** while the rig is idle: every key, every screen, every service tested, with a plain
    report in the morning, so nothing broken waits for Peter to find it.
36. **One vocabulary**: the same name for the same thing on the deck, the screens and the guide.
37. **Delete the dead weight**: old v1 pages, half-used pages and duplicate code go. A rework is mostly removing.

## Peter's decisions after phase 1 (2026-11-13)
- The four doors (HOME, RACES, REVIEW, RIG) are roughly right. Go ten levels deeper under each.
- **Lean on the real tools**, paywalled or not: thousands of screenshots exist. Copy how they lay things out and
  plug our data into the same places. Find the best in-race dashboards and mimic them.
- **YouTube direct upload: yes.**
- **Drop from the plan:** damage, tyre pressure (the tyre template doesn't update; Peter will sort tyres with SimHub
  later), and flags as a priority (two physical flag boxes do that; on screen a brief flash is enough).
- **Data:** it is about how it is presented, organised, and the insights. Decide later whether Coach Dave Delta and
  better tools are integrated; if Delta is killing the PC, that must be found out.
- **Everything must be clean, beautiful, accurate and work well.** Test everything. Full review, not a patch.

## C. Facts to check before designing
- **C1 Tyre pressure:** iRacing only updates tyre pressures in the pits, not while driving (to be confirmed with the
  live data). The screen can show "pressures at your last stop" honestly, but no live numbers.
- **C2 Damage:** iRacing gives no damage map, but it does give the repair time left, which is a good, honest damage
  gauge (to be confirmed).
- **C3 YouTube direct upload:** an app that Google has not audited may only be allowed to upload private videos.
  Check this before promising one-press public uploads; "upload private, then one press to publish" may be the answer.
- **C4 Stutter:** the logs from the race two races ago, the recorder's load and the frame-time data we already keep.
- **C5 Commentary by voice:** recording the microphone is simple; turning speech into text needs a speech model
  download (Peter's yes first).

## D. How we'll do it
1. **Evidence (no building).** Screenshots of every current screen (only while Peter is away from the rig).
   Helpers gather the real screenshots of the tools above and write what each does well. A stutter investigation.
   Claude reports back: what we have, what the best have, what's missing.
2. **Design.** One design system, then mock-ups of each screen next to the tools they learn from. Peter picks.
   Real iRacing assets only.
3. **Build plan.** One card per job (docs/TASKS.md style): files, tests, what "done" looks like. Cards that can run
   side by side do; nothing deploys while Peter drives.
4. **Build in waves.** The video and library first (his #1), then the in-race screen, then HOME and start-up, then
   data and coaching, then the deck. Every wave: tests pass, screenshots reviewed by Claude, then Peter.
- **Who does what:** cheap fast models gather research and screenshots; strong models build; Claude writes the specs,
  reviews everything and checks it live. Spending is checked as we go, against Peter's cap.

## Peter's decisions during wave 0 (2026-11-13)
- Gold: B, the softer broadcast gold `#C9A24B`, everywhere (top screen, phone, deck keys at the next deck rebuild).

- 2026-11-13 20:50, asked "Will you plug in a microphone (Arctis or another) for the talk-over-the-race feature?": **"Yes, with a mic"** -> W1-6 commentary is on.

- 2026-11-14 07:58: **"build everything without me touching the computer including installs"** -> no step waits for a click or a yes from Peter: the add-on installs itself through irdash (card W1-8), screens are deployed after the lead's review and he sees the contact sheet afterwards (PLAN rule 8 amended). Only the Google sign-in (his account) and plugging in the mic stay his.
- 2026-11-14 09:30 Peter: Google setup "Later" (W1-7 waits).
