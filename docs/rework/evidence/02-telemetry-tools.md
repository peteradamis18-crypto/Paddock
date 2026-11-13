# 02 - What the real telemetry tools show (evidence only, no code)

Date: 2026-11-12. Method: web search plus page fetches. Many vendor pages are marketing, and some pages
(garage61.net, Cosworth's own docs) would not load or do not list features. Where I could not confirm
something it says NOT CONFIRMED. I did not open the tools themselves and saw no screenshots. Layout
notes come from written descriptions, not pictures.

## Short answer

Every serious tool is built around ONE thing: your lap overlaid on a reference lap, plotted against
distance around the lap, with a time-gap line (delta) on top. Everything else is secondary. I found no
tool with a "best lap over time" chart as a main screen; progress over time is a minor list or trend.

## Tool by tool

### Garage 61 (free; paid adds other drivers' laps)
- Lap comparison: browser analyser; compare your lap with any shared lap in the same car, corner by corner. CSV export. Shows line distance, fuel and tyre stats (Coach Dave's comparison page).
- Session overview: lap list per session; a live timing page with track map, gaps and stints. No dedicated session-stats dashboard found.
- Progress: no dedicated view found. Free accounts keep one year of laps.
- Coaching: none. You read the data yourself.
- Reference model: any shared lap from a huge database (other drivers, same car), plus ghost laps. A staff member said in Nov 2024 that comparing every lap to your own best valid lap was not possible. May have changed.
- Standard charts (per third-party tools that import its CSV): speed, brake, throttle, steering, gear, RPM, long/lat G, delta.
- NOT CONFIRMED: exact layout. The official site would not load.

### VRS - Virtual Racing School (free tier; $4.99 / $9.99 a month for data packs)
- Lap comparison: "Driving Analyzer". Highlights the track section where you have most room to improve. Compare your own laps, or load a coach's telemetry (Data Pack) as the reference. Packs include a .rpy replay of the coach hotlap.
- Session overview and progress: telemetry uploads to the cloud; racing statistics and performance trends tracked over time.
- Coaching: the "biggest gain" highlight; the rest is lessons and setups.
- Reference model: coach lap (data pack), teammates (Teams), own laps.
- Layout: VRS says its UI is for "drivers rather than engineers". NOT CONFIRMED: chart list.

### Coach Dave Delta (about $12-13 a month; Delta 3.0 added native iRacing telemetry)
- Lap comparison: a track map in the centre with a moving car marker; an overview bar underneath that you drag to scrub the lap; two columns above, blue = you, yellow = reference, each showing throttle, brake, gear, speed, steering. Turn colour overlays off and you see just the racing line (yours solid, reference dotted).
- Session overview: session history, share and export.
- Progress: goals, ranks, leaderboards.
- Coaching: "Auto Insights". Red buttons on the timeline, each tied to a map location, explain one mistake (too much brake, late throttle, etc.). Side-by-side video of your lap versus the reference.
- Reference model: a pro-driver lap in the same car and setup; leaderboard laps can be added as a second reference.
- Layout: the map is the hero; traces are columns. Insights are few and clickable.

### Track Titan (free community plan; about $7.99 paid)
- Lap comparison: "delta map" (the traditional view) plus charts such as the brake chart, now showing distance driven in each segment.
- Coaching: "Coaching Flows" (Nov 2025) replace corner-by-corner reading. They name the root cause of your biggest time loss, explain the main mistake and knock-on effects, and show a few examples from your best lap. This is a vendor claim; no independent review found.
- Reference model: community laps (people you follow first), own laps, theoretical best (paid).
- Free plan has unlimited laps and telemetry without AI tips.
- NOT CONFIRMED: full chart list.

### Trophi.ai (Premium about $99.99 a year)
- A post-session "debrief" is made automatically: ranks every track section by time lost and grades technique per section. Telemetry overlaid on video.
- Live voice coach (Mansell) gives instructions on specific turns, based on your previous lap. Brake point assist.
- Progress: consistency, repeated mistakes, gains session over session (vendor claim).
- Reference model: a reference lap; the exact source is NOT CONFIRMED.
- Evidence quality: mostly marketing; one independent review (simracinghub.nl).

### MoTeC i2 Pro (iRacing workflow)
- i2 Standard is free; Pro is needed for the time-delta function. iRacing .ibt files first need converting (Coach Dave's guide describes a conversion step before i2 can read them).
- Standard engineer layout: many channels stacked on a distance axis, with a cursor and a track map. Overlay laps, add a time-delta math channel, build your own channels.
- Reference: whatever lap you choose. Steep learning curve; paid courses (HP Academy) teach it.
- Not a coaching product. It is the engineers' benchmark for what the charts look like.

### Cosworth Pi Toolbox (free for iRacing)
- The free version is called "Lite". Free to all iRacing users from members.cosworth.com. Reads .ibt natively, no converter. Plus (about GBP 5 a month at launch; Pro and Ultra above that) adds pro templates, live remote telemetry and data sharing.
- Default workbook: a file named "iRacing Lite Workbook v1.2". You create it, then right-click iRacing and choose "Add Outing" to load the session. Cosworth calls the layout "highly accessible ... tailored for sim sessions". I could NOT find a published list of its tabs. One guide mentions a "Driver Braking Data" tab where a lock-up shows as 1 on the brake channel. A map view shows brake or throttle around the track (secondhand, unverified). The newer Plus workbook adds actual yaw rate versus the neutral yaw rate the car's geometry predicts (a balance number through a corner).
- Answer to the owner's question: yes, there is a free iRacing version (Lite) with a default workbook. Its exact tab list is not documented anywhere I could reach. Someone should open it once and screenshot the tabs.

### Atlas
Not researched in depth. Atlas (Bosch) is a general motorsport analysis suite, not an iRacing consumer tool. Not relevant to this rework.

### iRacing's own telemetry users (guides and YouTube)
The recurring advice (Trophi guide, Coach Dave): look at brake, throttle and steering traces first, use delta to decide WHERE to look, overlay speed for minimum corner speed, then gear/RPM, then tyre and yaw data as advanced. The overlay checklist is four things: braking point, brake release, minimum speed, throttle reapplication. I did not find specific YouTube videos to cite.

## Standard chart checklist (what appears across tools)

| Chart | Seen in |
|---|---|
| Speed trace vs distance | all |
| Throttle and brake overlay vs distance | all |
| Delta time (gain/loss vs reference) | MoTeC Pro, Track Titan delta map, G61 import tools, guides |
| Steering | all |
| Gear, RPM | Delta, MoTeC, Pi, G61 |
| Track map with position marker | Delta (hero), Track Titan, Pi, MoTeC |
| Track map coloured by brake/throttle | Pi, Track Titan |
| Section time-loss ranking | Trophi, VRS (biggest gain), Delta (Auto Insights) |
| Min corner speed table | guides and engineer tools, as a check not a headline |
| Lap-time consistency histogram | not seen as a standard view; Trophi mentions consistency in words only |
| Tyre / fuel | G61 stats; tyre data is "advanced" in guides |

## Reference lap models
- Fastest laps of other drivers: Garage 61, Track Titan community, Delta leaderboards.
- Coach or pro lap: Delta, VRS data packs.
- Own best lap: all tools allow it. Track Titan paid also offers theoretical best (best sectors stitched together).
- Own best is the only model that needs no other driver's data.

## What a disciplined app should show (ranked)

OWN = needs only the player's own .ibt. OTHERS = needs other drivers' data.

1. **Two-lap overlay vs distance: speed, throttle, brake, steering, stacked, shared cursor.** The core of every tool. OWN (lap vs your own best).
2. **Delta-T line (time gained/lost vs reference) along the lap.** Tells you where to look. OWN.
3. **Track map with a cursor linked to the traces, coloured by delta or by brake/throttle.** Delta's hero view. OWN, if the map exists.
4. **Biggest time loss by section/corner (top 3 ranked).** What Trophi, VRS and Delta all lead with. OWN (this lap vs your best).
5. **Corner table: braking point, min speed, throttle reapply point, this lap vs best.** The four-point checklist. OWN.
6. **Theoretical best (best of each mini-sector) vs actual best.** Shows what is already in the car. OWN.
7. **Session lap list: times, valid/invalid, in/out laps flagged, fuel per lap.** The basic session overview. OWN.
8. **Gear and RPM trace under the main stack.** Supporting context. OWN.
9. **Consistency: lap-by-lap line or bars over a stint, not a fancy histogram.** Useful in practice and races. OWN.
10. **Fuel use per lap and stint estimate.** Race-relevant. OWN.
11. **Plain-English "top 3 things to fix"** built from items 4 and 5. Coaching without a human. OWN.
12. **Compare against community or coach laps.** Valuable but OTHERS. Not possible with this app.

## Mostly pointless or weak
- A "best lap over time" headline chart. No tool leads with it. It is a trend, not a diagnosis. Keep it small (per track and car) or drop it.
- Pie charts, gauges, big session totals (laps driven, distance). Not used by any tool I found.
- Averages with no reference (average speed, average throttle). They tell the driver nothing.
- Lap-time histograms for short sessions (under about 15 laps). Too few points.
- Tyre temperature and pressure panels. Also removed by the owner, and the feed has no surface temps.
- Generic AI praise text. Coaching must point at a corner and a number.

## Layout rules that repeat
- Traces share one distance axis and one cursor; the chart area gets most of the screen. The track map sits next to or above them.
- Fixed colours: you in one colour (blue in Delta), reference in another (yellow). Brake red and throttle green is the common convention.
- Few labels; units on the axis; the delta line sits under the speed trace.
- Coaching is a short list of clickable items tied to map points, not paragraphs.

## Open gaps
- No screenshots viewed. Tools need to be opened, or screenshots saved from the URLs below, to confirm layout.
- Pi Toolbox Lite default workbook tab list: unconfirmed.
- Garage 61 and Track Titan chart lists: partly inferred from third parties.

## Links
- Cosworth iRacing page: https://cosworth.com/motorsport/iracing/
- Cosworth and iRacing announcement: https://cosworth.com/news/cosworth-and-iracing-unite-to-redefine-data-analysis-in-sim-racing/
- iRacing 101 Pi Toolbox: https://www.iracing.com/?p=284574
- Pi Toolbox Plus trial and yaw-rate feature: https://www.iracing.com/cosworth-pi-toolbox-plus-free-trial-returns-updated-features-for-iracing-spa-24/
- Pi Toolbox tiers (Box This Lap): https://boxthislap.org/cosworth-enhances-pi-toolbox-for-iracing-with-paid-membership-levels/
- Pi Toolbox manual (Scribd): https://www.scribd.com/document/336683990/Pi-Toolbox-Manual
- Delta vs Garage 61: https://coachdaveacademy.com/tutorials/coach-dave-delta-vs-garage-61-which-is-best-for-you/
- Delta vs VRS: https://coachdaveacademy.com/tutorials/coach-dave-delta-vs-vrs-which-one-is-best-for-you/
- Using Delta (screens described): https://coachdaveacademy.com/tutorials/save-seconds-in-lap-time-using-coach-dave-delta/
- Delta Auto Insights: https://coachdaveacademy.com/announcements/sim-racing-ai-coaching-with-delta-auto-insights/
- MoTeC data in iRacing: https://coachdaveacademy.com/tutorials/how-to-use-motec-data-in-iracing/
- MoTeC i2 feature guide: https://www.motec.com.au/hessian/uploads/i2_V1_1_4_Feature_Guide_0d03b00fa8.pdf
- HP Academy time delta lesson (paid): https://www.hpacademy.com/courses/data-analysis-fundamentals/practical-skills-analysing-the-time-delta-lap-gainloss-channel-advanced-sensors
- Open-source iRacing .ibt analyser: https://github.com/racer-coder/TrackDataAnalysis
- VRS FAQ: https://virtualracingschool.com/faq/
- Track Titan coaching flows: https://www.tracktitan.io/post/november-2025-update-coaching-flows
- Track Titan pricing: https://app.tracktitan.io/pricing
- Trophi lap analysis: https://www.trophi.ai/sim-racing-features/lap-analysis
- Trophi telemetry guide: https://www.trophi.ai/post/how-to-use-iracing-telemetry-to-find-faster-lap-times-a-practical-guide
- Trophi independent review: https://www.simracinghub.nl/en/?p=27217
- Garage 61: https://garage61.net/
