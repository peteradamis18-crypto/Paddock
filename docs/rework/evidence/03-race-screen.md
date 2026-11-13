# Evidence 03 - The third (top) race screen

Phase 1, research only. Date 2026-11-12. Plain English.

**How reliable this is.** I had web search and page fetch. Search results were thin, so every claim is tagged:
**[SRC]** = read on a page I fetched, **[SNIP]** = from a search snippet only, **[KNOWN]** = my general knowledge, not checked online, **[?]** = unknown.
I could not get useful pages for Kapps, Racing Insights, Crew Chief's display, iRacing's black boxes, WEC/IMSA/Al Kamel timing, or broadcast graphics packages. Treat those parts as leads, not proof.

## 1. What overlay and dash tools put on a second screen

- **irdashies** [SRC] (already on the rig). Widgets: Standings, Relative, Battle, Radar, Blind Spot, Faster Car From Behind, Slow Car Ahead, Fuel Calculator, Weather, Wind, Flag, Track Map, Pitlane Helper, Lap Timer, Sector Delta, Delta Speed, Information Bar, Input Trace, Car Systems. Also a separate "Gantry" race-control window (standings + incident feed + lap graph) and broadcast overlays (Tower, Ticker, Events). Layout: profiles switch by session type; each widget can show on/off by session and on-track state.
- **RaceLab** [SNIP]: about 29 iRacing overlays, led by Standings and Relative (multi-class, iRating/safety rating, flags, reorderable columns), a Fuel Calculator (average/min/max per lap; later fixed to ignore yellow-flag laps, plus a refuel-strategy chooser), Radar, Inputs, Track Map.
- **SimHub iRacing overlays (benofficial2)** [SNIP]: Relative, Spotter, Fuel Calculator, Track Map. **iRon** [SNIP]: relative with mini-map, fuel, input graph, standings.
- **Most used widgets** (inference from what every tool ships first): Relative, Standings, Fuel, Radar/spotter, Flags, Delta, Inputs, Track Map [KNOWN]. I found no published usage statistics.
- Two lessons: tools put **Relative** (cars around you) ahead of full standings, and fuel maths must ignore caution laps (RaceLab had to fix exactly that).

Kapps, Racing Insights, Crew Chief display, iRacing black boxes: no usable source found. [KNOWN]: iRacing's black boxes (F-keys) are small text panels (timing, standings, relative, fuel, tires, in-car adjustments, pit service) flicked through one at a time. Crew Chief speaks rather than displays; its value is telling you fuel, gaps, damage and penalties so you do not have to look.

## 2. Professional timing and pit-wall screens

- **F1 live timing** [SNIP]: one row per car in position order. Columns: position, driver, **gap to leader**, **interval to the car ahead**, last lap, best lap, three sector colours (purple = overall best, green = personal best, yellow = neither), tyre compound as a colour letter (S red, M yellow, H white, I green, W blue) with tyre age in laps, and pit stop count. Gap and interval are timed at track loops, so they update in steps. A source stresses that pit stops move positions without overtakes, so gaps matter more than position.
- **Pit-wall practice** [SNIP]: teams watch sector times, gaps, tyre and fuel on several screens, plus simple gap graphics. A **pit board** [SNIP] carries only position, laps remaining, gap ahead and behind, and one instruction code. That is the driver-glance subset and the best model for a third screen.
- **WEC/IMSA/Al Kamel** [KNOWN, not fetched]: one list in overall order with a class column, class position, class colour band, an "IN PIT" status with pit count, and a top banner for flag/session status. Multi-class timing is always colour-coded by class.
- **Broadcast tower / battle / gap graph** [KNOWN]: tower = narrow vertical list (position, short name, interval), roughly 10-20 rows; battle = two cars and one gap number; gap graph = a line per rival over laps. irdashies has Tower and Battle [SRC].
- **Hierarchy common to all:** (1) flag/session status is the loudest thing; (2) your own row is highlighted and the list centres on you; (3) one gap number per row (interval) for the fight, gap-to-leader only for strategy; (4) pit/tyre info small and coded; (5) class is colour, not text.

## 3. Glance rules

- **Visual angle** [SNIP, US DOT/FHWA]: minimum character height 0.50 deg for key items, 0.33 deg for dynamic/critical, 0.266 deg for static. At 1 m that is about **8.7 mm, 5.8 mm, 4.7 mm** tall (arithmetic from the snippet). ISO 9241-3 [SNIP]: 20-22 arcmin preferred, 16 minimum.
- **Glance study** [SNIP, MIT AgeLab / Dobres]: 4 mm type was clearly more legible than 3 mm at a glance; the legibility threshold roughly doubles across the adult age range; a humanist (open, rounded) sans cut glance time about 10% versus a square grotesque. Choose an open face with clear digits.
- **Rule of thumb** [KNOWN; one calculator source says the same]: design at about twice the minimum. At 1 m that is key numbers about 12-18 mm cap height. On a 1080p panel that is very roughly **48-72 px for the headline fact, 32-40 px for supporting facts, nothing under 24 px**. These pixel figures are my estimate and depend on panel size and distance; measure on the rig.
- **Count and colour** [KNOWN]: about 5-7 things at once; 3-4 meaningful colours at most; each colour means one thing (red = danger/loss, yellow = caution, green = good, purple = best, class colours for class); never colour alone; motion only for what needs action.
- **What drivers look at** [KNOWN, forum consensus, not fetched]: gap ahead/behind, fuel, flags/incidents, "am I in trouble". Full tables are for cautions and the pits.

## 4. iRacing SDK facts

Variable list: the goirsdk table (a copy of iRacing's list) [SRC]. The SDK docs "contexts" page [SRC] says only that replay-from-disk gives partial or wrong values and that variables behaving differently should be noted on their own pages.

| Question | Answer | Confidence |
|---|---|---|
| Live tyre pressures? | No hot-pressure channel in the list. `LFcoldPressure` etc. are pressures "as set in the garage" (kPa). `LFtempCL/CM/CR` and `LFwear*` exist, but Coach Dave and a SimHub user say iRacing gives no real-time tyre info while driving for most cars; numbers appear after pitting. | Cold = confirmed [SRC]. Pit-only = [SNIP], community, may vary by car [?]. Peter's tyre panel is removed, so this does not block anything. |
| Damage variables | No "damage percent" channel. Available: `PitRepairLeft` (seconds, "time left for mandatory pit repairs, if repairs are active"), `PitOptRepairLeft` (seconds, optional repairs), `FastRepairAvailable`, `FastRepairUsed`, `PlayerFastRepairsUsed`, `CarIdxFastRepairsUsed`, `PlayerCarTowTime`, `PitstopActive`, `PlayerCarInPitStall`. | Names and meanings confirmed [SRC]. |
| Are repair times live while driving? | "If repairs are active" hints they fill only when a repair is pending or in service. SimHub users read `PitOptRepairLeft` in seconds [SNIP]. Whether they show the estimated repair time during a lap after contact is NOT confirmed by any source I read. [KNOWN, memory]: dashboards use `PitRepairLeft > 0` on track as a "car is damaged" signal. | Uncertain [?]. Needs a crash test. |
| Incident counts | `PlayerCarMyIncidentCount` (you), `PlayerCarTeamIncidentCount`, `PlayerCarDriverIncidentCount` (current team driver). Integers per session; SimHub lists the first as an iRacing property [SNIP]. | Existence confirmed [SRC]. "Updates live" is likely (ordinary frame value) but no source states it [?]. |
| Other useful live channels | `CarIdxOnPitRoad`, `CarIdxClassPosition`, `CarIdxEstTime`, `CarIdxF2Time`, `CarIdxTireCompound`, `SessionFlags`, `FuelLevel`, `FuelUsePerHour`, `LapDeltaToBestLap` / `SessionBestLap` (+ `_OK` validity flags), `PitSvFlags`, `PlayerCarPitSvStatus`. | Exist [SRC]. |

Bottom line for damage: build a damage state from "repair time pending" + "fast repair used" + incident count change, and verify with a crash test before promising it.

## 5. Recommended third-screen layout (1920x1080)

One standings view only (replacing the two lists). Source product noted per choice.

**Left 60% = one standings window. Right 40% = key facts. Top strip = flag.**

**Standings** - irdashies Standings/Relative [SRC], F1 timing [SNIP], RaceLab multi-class [SNIP]:
- About 11 rows in one list: your class leader pinned on top, then you in the middle with the 4 cars ahead and 4 behind (Relative practice). One list, not two.
- Row content: class position (40 px), car number on a class-colour band (WEC [KNOWN]), short name (32 px), **one number: interval to the car in front** (36 px; F1 interval [SNIP]), PIT tag when on pit road. Your row 1.3x bigger, gold.
- No tyre column (panel removed). Full result tables stay off this screen (pit-board principle [SNIP]).

**Key facts, biggest first (8):**
1. **Flag / session banner**, full-width, about 100 px, loudest item (irdashies Flag widget [SRC]; matches the project's existing single-source flag table).
2. **Position and laps left**, e.g. "P4 / CLASS P2 / 12 TO GO", 72 px (pit board [SNIP]).
3. **Gap ahead and gap behind**, 64 px; green when closing, red when losing (pit board [SNIP]; irdashies Battle [SRC]).
4. **Fuel: laps of fuel vs laps to go, and the +/- to the end**, 56 px; red when short; caution laps excluded (RaceLab [SNIP]; irdashies Fuel Calculator [SRC]).
5. **Damage**: hidden when clean; when hurt, big amber/red "DAMAGE - REPAIR 38 s" from `PitRepairLeft` (pending crash test). Crew Chief speaks this [KNOWN]; this is the silent twin.
6. **Incidents**: "4x" beside the session limit, 40 px, turns amber near the limit (irdashies Gantry incident feed [SRC]; `PlayerCarMyIncidentCount` [SRC]).
7. **Delta bar** to best or session best, 32 px (irdashies Sector Delta [SRC]; `LapDeltaTo*` [SRC]).
8. **Last / best lap**, 32 px, purple when session best (F1 sector colours [SNIP]).

Nothing under 24 px. Radar and input traces stay off this screen (radar belongs near the race view; the spotter already speaks).

**Variants**
- **In race (green):** as above; gaps and fuel dominate.
- **Under caution:** banner turns yellow. The standings switch from interval to gap-to-leader and show who is on pit road (`CarIdxOnPitRoad`). Fuel shows "to the end" with laps frozen. Delta and lap times fade out. Pit decision aids come up: "pit now?" and fuel needed (irdashies Pitlane Helper [SRC]; WEC/IMSA pit-or-stay logic [KNOWN]).
- **Pit-in / on pit road:** the right side collapses to three items: pit-limiter state, repair/service time left (`PitRepairLeft`, `PitSvFlags`), and "you will rejoin P7" with a ghost row in the list (as F1 timing shows after a stop [KNOWN]). Everything else dims (irdashies Pitlane Helper [SRC]).

## 6. To verify before building

1. Offline crash test logging `PitRepairLeft`, `PitOptRepairLeft`, incident counts, in a GT3 car and a prototype: does damage show while still driving?
2. Measure the real panel size and eye distance, then convert the visual-angle sizes to pixels.
3. Read Kapps and Racing Insights from their own pages (not reachable here).

## Links

- https://github.com/mpapenbr/goirsdk/blob/v0.6.0/variables.md
- https://sajax.github.io/irsdkdocs/contexts.html
- https://github.com/tariknz/irdashies
- https://coachdaveacademy.com/tutorials/understanding-tire-pressures-in-iracing/
- https://www.simhubdash.com/community-2/simhub-support/problem-with-iracing-tire-temperatures-and-other-tire-numbers-not-updating-in-dashboard
- https://simhubdash.com/community-2/simhub-support/can-i-get-the-number-of-incidents-from-iracing
- https://www.simhubdash.com/community-2/projects/time-in-ss-and-mm/
- https://racelab.app/iracing
- https://docs.racelab.app/release-notes/page/2
- https://simracingcockpit.gg/iracing-overlay-racelabapps/
- https://www.simhubdash.com/community-2/dashboard-templates/benofficial2s-official-overlays-for-iracing
- https://gh.r-mj.com/frmjar/iRon
- https://flowracers.com/blog/what-does-interval-mean-in-f1/
- https://multiviewer.dev/docs/getting-started/understanding-telemetry
- https://www.formula1.com/en/latest/article.you-speak-we-listen-the-latest-f1-live-timing-improvements.G9HzG04abEZ7wSosVjUfg.html
- https://redbullracing.com/int-en/bulls-guide-to-the-pit-wall
- https://f1chronicle.com/what-are-the-pit-boards-in-formula-1/
- https://www.fhwa.dot.gov/publications/research/safety/98057/ch03.cfm
- https://www.uxmatters.com/mt/archives/2009/01/text-treatment-and-the-user-interface.php
- https://agelab.mit.edu/transportation-and-livable-communities/projects/glance-based-legibility
- https://pubs.lib.uiowa.edu/driving/article/id/28591/
