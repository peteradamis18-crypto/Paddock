# Evidence 08 - Catalogue of second-screen / pit-wall dashboards

Phase 1, research only. 2026-11-13. Plain English. Builds on 03-race-screen.md (not repeated).

**How reliable.** Tags: **[SRC]** = read on a page I fetched; **[SNIP]** = search snippet only; **[KNOWN]** = my own knowledge, unchecked; **[?]** = could not find out.
**Big limit:** my fetch tool returns text only. I could NOT look at any screenshot, so "what is biggest" and "what is colour-coded" are only known where a page's text says so. Screenshot links are given so a designer can look. Several sites blocked me (overtake.gg returned 403). Overtake.gg, the SimHub store and RaceDepartment pages did not give resolutions. Racing Insights and Kapps: no official page found (search returned nothing for Racing Insights). MAIRA turned out to be a force-feedback tool, not a display, so it is dropped.

## 1. SimHub dashboards on a second monitor

| Name | What it is | Widgets [source] | Screenshot / page |
|---|---|---|---|
| **Lovely Pit Wall** (Lovely Sim Racing) | "Made for larger screens" [SRC]. Four full-page screens: Idle, Leaderboard, Map, Telemetry. Landscape and portrait versions. Needs Lovely Plugin 3.0.0 and a paid (Pro/Gold) membership [SRC]. Resolution not stated [?]. | Page text lists only the four screens; contents of each must be read from the images [?] | Landscape images in links section. Closest thing to a purpose-built "big pit wall" SimHub dash. |
| **Lovely Dashboard** (free) | Car-dashboard style (wheel/phone/screen sizes), iRacing support since v1.5, variants XL, Curved. Needs Romainrob's iRacing Extra Properties DLL [SNIP]. | Not readable [?] | Overtake.gg "JUST A PICTURE" thread (blocked 403) |
| **Romainrob Universal iRacing Dash** | 2 screens: main (2 pages: normal cars; complex cars like F1/Indy/LMP1) plus a pit stop screen [SNIP]. Shows distance to pit box on the pit screen (iRacing only) [SNIP]. | Radar left/right, relative, gear, fuel (in the "Ultimate" variant) [SNIP] | overtake.gg/threads/universal-simhub-dash-for-iracing.165188 |
| **4th Monitor Overlay (iRacing only), by mgyr** | A genuine "extra monitor" dash [SRC]. Leaderboard up to 40 cars, multiclass, auto-switching, first seven sector times; track map with turn numbers; own lap-time table with track temp; pit box with a **pit window bar** [SRC]. | See left | simhubdash.com page. Resolution not stated. A user on a 32-inch screen said the text was too small [SRC] - a warning for us. |
| **Pit window bar colours** (from the above) | One bar per remaining lap: white = cannot finish on current fuel; red = not enough fuel; orange = too early to pit; green = pit window open [SRC]. | | Good, simple fuel colour code to copy. |
| **iRacing Pit Stop Tactics Dashboard v0.4** | Touch pit-service screen: fuel amount and buttons, tyres, windscreen, fast repair left [SRC]. | Not relevant to a read-only glance screen; Peter uses the deck for pit service | simhubdash.com page |
| **Dan Newman "Virtual Box"** | Paid set of sixteen full screens: Fuel, Tyres, iRacing Pit, Damage, Radar, Relative, Leaderboard, Opponents, Rivals, Sectors, Lap History, Lap Time, Speedo, Inputs, Map, NRG [SRC]. Designed for a small box screen you flick through. Resolution not stated [?]. | | webp images under trackthirtytwo.com/overlays/virtual-box/ |

Not found: a dash literally named "Z1", "DDU", "Race Element" for iRacing. Race Element is an ACC tool [KNOWN]. DDU-style dashes are wheel-size, not pit-wall [KNOWN]. I will not claim details for them.

## 2. Standalone second-screen apps

- **SDK Gaming iRacing Live Timing** [SRC, best-documented]. Runs as its own window or a web page on any screen. One row per car; columns: P, positions gained/lost since start (green/orange), car number on class colour, car logo, name, iRating and predicted iRating change, licence, laps, **Gap** and **Int** (colour-coded versus last lap), best lap, last lap (dark green = personal best, dark pink = overall best), sectors, speed, top speed, **pit stops, lap of last stop, pit lane time**, off-track count (cell goes red). Pitting cars grey. A grey "virtual driver" shows where you will **rejoin after a stop** (needs a measured time-lost-in-pits). This is the strongest evidence for the "rejoin position" idea. Images: Live-Timing.png (below).
- **RaceLab** [SRC]: 33 overlays in nine groups (Standings, Relative, Horizontal Standings, Fuel Calculator, Pitbox Helper, Delta, Session Timer, Digiflag, Weather Monitor, Track Map...). They are on-top-of-sim layers; the page does not describe a full-page second-monitor mode [SRC]. Its Fuel Calculator shows pit window open (e.g. laps 21-25), fuel left, amount to add, how far the fuel lasts [SRC]. Relative variants include pit stops, lap times, flat map, tyres [SRC]. Screenshot paths in links.
- **irdashies** [SRC, on the rig]. Standings: position, number, name, gap, interval, best/last lap, lap deltas over 1-5 laps, status chips (PIT, OUT, TOW, DNF, repair, penalty), class headers with lap counts, "N cars around you plus pinned top", incident/off-track highlighting. Fuel Calculator: min, last, 3-lap and 10-lap averages, max, fuel required, earliest pit lap, fuel-to-add, fuel saving needed to gain one lap, histogram, **safety margin 0-20%** [SRC]. Screenshots in links. It is the best screenshot source, free, and what Peter already runs.
- **iSpeed (nessoft)**: lap/split/best-lap/speed display, built for a second PC or tablet [SNIP]. **SIMRacingApps**: web HUD for tablet/phone [SNIP, SRC]. **Kapps**: users say its fuel numbers are more accurate than iRacing's own and it shows the last-5-lap difference [SNIP]; no page read. **iOverlay**: relatives, standings, spotter, track map, Twitch chat [SRC via Coach Dave]; overlay, not a second screen.
- Which run as a separate full page: SDK Live Timing (yes, web page), SIMRacingApps (yes, web), SimHub dashes (yes, "second screen output"), iSpeed (yes). RaceLab, irdashies, iOverlay are overlays that can sit on any monitor but are not designed as a full page.

## 3. Pro references

- **F1 live timing** [SNIP, official article]: now combines the driver tracker map with the leaderboard; shows best lap, gap, lap time and tyre use for every car on one screen. Gap and Interval update by track segment (about every 200 m); F1 removed the flashing on those cells because it fired about 1,000 times a lap. Lesson: no flicker.
- **Timing tower fields** [SNIP, UndercutF1]: sector times, last and best lap, tyre and tyre age, interval to the car ahead, gap to leader.
- **Row design** [KNOWN, see 03]: your row highlighted; purple/green/yellow for lap and sector quality; class as colour.
- **Real pit-wall engineer screens**: no public image found [?]. Team accounts describe sector times, gaps, tyres and fuel across several screens [SNIP, see 03].
- **Al Kamel / WEC timing**: not fetched [KNOWN]: one overall list, class column and colour band, IN PIT status, flag banner on top.

## 4. The five best to mimic

1. **SDK Live Timing - the rejoin ghost and pit columns.**
   Copy: pit stops count, "in / pit / out" tag, grey pitting cars, and the ghost row "you rejoin here". Drop: iRating, licence, speed, top speed, sectors, off-track count, car logo. Keep five columns only.
2. **irdashies Fuel Calculator + Pitbox Helper (and RaceLab fuel).**
   Copy: laps of fuel, fuel to end, earliest pit lap, "save X to gain a lap", margin as a laps setting. Drop: histogram, min/max, 3 and 10 lap table, litres-to-add keypad.
3. **mgyr 4th Monitor pit-window bar.**
   Copy: one cell per remaining lap, coloured white/red/orange/green. Drop: leaderboard of 40, turn-number map, lap table. Note the complaint: text too small on a big screen.
4. **F1 live timing / tower.**
   Copy: interval as the main number, gap-to-leader as the second; purple only for session best; no flashing; update by segment, not every frame. Drop: three sector columns, tyre column (panel removed), mini-sectors.
5. **Lovely Pit Wall.**
   Copy: the idea of a few full-page screens with a large format, one clear "main" page plus an Idle page for garage. Look at the leaderboard and telemetry pages for spacing before copying anything more; I cannot confirm the contents without the images. Drop: the Map and Telemetry pages (not wanted at a glance).

(Honest note: items 1 to 4 are supported by text I read; item 5 rests on a four-page description only.)

## 5. Proposed layout, 1920 x 1080, read at about 1 m

Rules from 03: headline 48-72 px, supporting 32-40 px, nothing under 24 px. No tyres, no damage, no flag banner (Peter has physical flag lights). Frame: 24 px margin; zone boundaries are 8 px gaps. Black background, gold for your row and the one headline, purple only for session-best, red = danger, amber = caution / tight, green = good.

**Pixel map (x, y, w, h):**

| Zone | Box | Content | Copied from | iRacing channels |
|---|---|---|---|---|
| A. Top strip | 24, 24, 1872, 96 | Left: "P4 of 22 · CLASS P2". Middle: "LAP 31 / 52 · 12 TO GO" or time left. Right: session clock. 56 px type. | Pit board [SNIP], irdashies info bar [SRC] | `CarIdxPosition`, `CarIdxClassPosition`, `Lap`/`CarIdxLap`, `SessionLapsRemainEx`, `SessionTimeRemain`, `SessionTime` |
| B. Gap pair | 24, 136, 912, 288 | Two stacked rows, 96 px digits: AHEAD -1.4 (green if closing, red if losing) and BEHIND +0.6, with each car's number and name in 32 px. Gap trend arrow from last 3 laps. | F1 interval [SNIP], irdashies Battle [SRC] | `CarIdxF2Time` (player vs car ahead/behind by `CarIdxPosition`/class position), `CarIdxLapDistPct` and `CarIdxEstTime` as fallback |
| C. Fuel | 24, 440, 912, 360 | Top line 72 px: "FUEL +1.8 LAPS" (green) or "-0.6 LAPS" (red), plus laps of fuel and laps to go in 40 px. Below: pit-window bar, one 24-px cell per remaining lap (white/red/orange/green). | irdashies Fuel Calc [SRC], mgyr bar [SRC] | `FuelLevel`, `FuelLevelPct`, `FuelUsePerHour`, `SessionLapsRemainEx`, `LapLastLapTime`, `OnPitRoad` |
| D. Lap and delta | 24, 816, 912, 240 | Last lap 56 px (purple if session best); best lap 40 px; delta bar 912 x 48 from `LapDeltaToBestLap` (green ahead, red behind), `_OK` flag hides it when not valid. | irdashies sector delta [SRC], SDK timing colours [SRC] | `LapLastLapTime`, `LapBestLapTime`, `LapDeltaToBestLap`, `LapDeltaToBestLap_OK`, `LapDeltaToSessionBestLap` |
| E. One standings list | 952, 136, 944, 920 | 11 rows, 80 px each: class leader pinned on top (gold thin line under), then 4 ahead, YOU, 4 behind. Columns: class pos (40), number on class colour band, short name (32), **interval to the car in front** (40), PIT chip. Your row gold and 1.3x. Class-header rows only if multiclass. | SDK Live Timing [SRC], irdashies Standings [SRC] | `CarIdxClassPosition`, `CarIdxPosition`, `CarIdxF2Time`, `CarIdxOnPitRoad`, `CarIdxClass`, driver list from session info |
| F. Incident chip | 24, 24 area right end of A (or 952, 1000, 944, 56 under list) | "4x / limit 17"; amber when 3 or fewer from the limit | irdashies Gantry [SRC] | `PlayerCarMyIncidentCount`, session `IncidentLimit` |

(Zone F is a small chip, not a zone of its own; put it at the end of strip A so the screen has five main blocks.)

**Under caution** (banner not needed; flag lights do it): strip A shows "CAUTION" in amber 56 px. Zone B switches to gap-to-leader and your class position. Zone C shows fuel to the end with laps frozen (see maths) and the line "PIT NOW? needs 14 L / have 22 L" using the pit-window bar. Zone D fades. Zone E switches to gap to leader and shows PIT chips for everyone on pit road (grey, SDK style). `SessionFlags` caution bits and `CarIdxOnPitRoad` drive it.

**On pit road**: A stays. B and D collapse. C becomes "PIT LIMITER" state and fuel in tank. E shows the rejoin ghost row: "YOU WILL REJOIN P7" placed in the list by `time lost in pits` (SDK method [SRC]; the time lost must be measured per track, same as SDK asks for). `OnPitRoad`, `PitSvFlags`, `PlayerCarInPitStall`, `PitstopActive`.

## 6. Fuel maths used by the best tools

Sources agree on shape [SNIP/SRC]; no official iRacing formula. Suggested:

1. **Burn per lap** = average of the last N clean laps, N = 3 to 5 minimum, 10 for the long view (irdashies shows 3 and 10 [SRC]; one source says wait for at least 5 laps [SNIP]). A clean lap is green, no pit in or out, no off-track. Drop caution laps [SRC: RaceLab fixed this; SDK's Fuel Calc also resets after a stop [SNIP]]. Reset after a pit stop.
2. **Laps of fuel** = `FuelLevel` / burn per lap.
3. **Laps to go** = `SessionLapsRemainEx`; for timed races = (`SessionTimeRemain` / average clean lap time) rounded up, plus 1 for the lap after the flag. If under caution, estimate green laps left as total minus expected caution laps, and let a "caution laps" setting (e.g. 3, off by default) absorb them [my assumption; RaceLab and others expose laps to add].
4. **Fuel to end** = laps to go x burn x (1 + margin) - `FuelLevel`. Margin 5-10 per cent or 1-2 laps (sources suggest 2-3 laps or 5-12 per cent [SNIP]; irdashies allows 0-20 per cent [SRC]). Pick laps: 1.0 lap fixed, to be shown, not set.
5. **Display** = laps of fuel minus laps to go = "+1.8" or "-0.6". Negative = red. "SAVE 0.12 L/LAP to gain a lap" (irdashies [SRC]).
6. **Pit window** = earliest pit lap is the lap where tank-capacity still covers the rest (fuel to end <= tank space); latest pit lap = last lap with fuel left. Bar colours as mgyr [SRC].

## 7. Things to check before building

1. Are `LapDeltaToBestLap` and `CarIdxF2Time` smooth enough to read at 10 Hz? [?]
2. The time lost in the pits needs one measured value per track/car.
3. Look at the Lovely Pit Wall, SDK and irdashies images with eyes and compare with the table above (I could not).

## Links (URLs only)

Lovely Pit Wall page: https://store.lsr.gg/pages/lovely-pit-wall
Lovely Pit Wall images (landscape):
https://store.lsr.gg/cdn/shop/files/lovely-pitwall-1lrg_9ca6772f-45c7-4fab-af63-a78629d61776.png
https://store.lsr.gg/cdn/shop/files/lovely-pitwall-2lrg_30d67861-5449-4362-8b20-37e028243427.png
https://store.lsr.gg/cdn/shop/files/lovely-pitwall-3lrg_738dd7da-a2a4-4c60-b9b9-7a4c9aed4100.png
https://store.lsr.gg/cdn/shop/files/lovely-pitwall-4lrg_3d8e1ab0-0f3b-4706-9c7e-8b9eefad456a.png
Portrait: https://store.lsr.gg/cdn/shop/files/lovely-pitwall-portrait-2lrg.png
Lovely Dashboard picture thread: https://overtake.gg/threads/lovely-dashboard-just-a-picture.232431/page-2
Lovely Dashboard releases: https://newreleases.io/project/github/Lovely-Sim-Racing/lovely-dashboard/release/v3.0.0
Universal iRacing dash: https://www.overtake.gg/threads/universal-simhub-dash-for-iracing.165188/
4th Monitor Overlay: https://www.simhubdash.com/community-2/dashboard-templates/4th-monitor-overlay-iracing-only/
Pit Stop Tactics dash: https://www.simhubdash.com/community-2/dashboard-templates/iracing-pit-stop-tactics-da
Pit Stop Tactics images: https://yourimageshare.com/ib/H3obW6WOMO.webp , https://i.imgur.com/ZoLpZpu.png
SDK Live Timing manual: https://www.sdk-gaming.co.uk/?p=1285
SDK Live Timing image: https://www.sdk-gaming.co.uk/wp-content/uploads/2019/10/Live-Timing.png
SDK header image: https://www.sdk-gaming.co.uk/wp-content/uploads/2019/06/Timing1.png
SDK fuel calculator page: https://www.sdk-gaming.co.uk/?p=10333
Virtual Box: https://www.trackthirtytwo.com/products/overlays (images: /overlays/virtual-box/iracing-pit.webp, fuel.webp, relative.webp, leaderboard.webp)
RaceLab: https://racelab.app/iracing (images: /img/home/overlays/standings.webp, relative-pit-info.webp, fuelCalculator.webp, horizontalStandings-wide.webp)
irdashies: https://github.com/tariknz/irdashies
irdashies images: https://github.com/tariknz/irdashies/raw/main/docs/assets/standings.png , https://github.com/tariknz/irdashies/raw/main/docs/assets/fuelcalculator.png , https://github.com/tariknz/irdashies/raw/main/docs/assets/fuelcalculator-default.png
iSpeed: https://www.nessoft.com/ispeed/
SIMRacingApps: https://simracingapps.com/
iOverlay: https://ioverlay.app
Coach Dave free apps: https://coachdaveacademy.com/tutorials/10-must-have-free-apps-for-iracing/
Fuel calculator guide: https://simracingcockpit.gg/fuel-and-tyre-stint-calculator/
Auto fuel (margin of laps): https://traxion.gg/everything-you-need-to-know-about-iracings-new-auto-fuel-feature/
F1 live timing update: https://www.formula1.com/en/latest/article.you-speak-we-listen-the-latest-f1-live-timing-improvements.G9HzG04abEZ7wSosVjUfg.html
UndercutF1 timing tower: https://github.com/JustAman62/undercut-f1
