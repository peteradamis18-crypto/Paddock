# Coach Dave Delta test: three races, one evening

For the lead. Run it when the rig is free and Peter is away. Question: does Coach Dave Delta cost Peter frames or
cause the freeze seen in the 12 Nov 09:28 race (evidence `docs/rework/evidence/05-stutter.md`: Delta was the only
program that jumped, 13% of a core on average, 36% in the dips; Delta's own FAQ admits FPS drops from resource
contention; its Video Capture is the likely heavy part, which is a reading, not a fact). This test settles it.
No promise about the result.

## The honest way to run it: Peter's own races, automatically (primary method)
An evening run has no driver: with Peter away the car sits in the pit box, iRacing renders a parked view, and Delta
sees a car that never moves. That is not the load that froze lap 9. So the decisive comparison is Peter's real
races: the black box (card W0-9) writes one row a second with Delta's process present or absent and its CPU share,
and after about three races with Delta running and three without (Peter closes it from its tray icon, nothing
else changes) the RIG sentence compares them (average fps, worst second, seconds under 60, freezes). Nobody has to
do anything on an evening. The three-run protocol below is the fallback for a quick answer when Peter wants one
sooner; its result is weaker and the verdict must say "with the car parked".

## The three runs (everything else identical)
Same 20-minute AI race each time: Toyota GR86, Road Atlanta (full), same AI count, same weather and time of day as
the 12 Nov race (read them from that race's `.ibt` header or from `ai\level.json` and write them in the log first).
Order: A, then B, then C, with the PC left alone for a minute between runs.
- **A. Delta not running.** Delta's process is closed (check Task Manager shows no Delta process).
- **B. Delta running, video capture off.** Delta open, signed in, Video Capture switched off in its settings.
- **C. Delta running, video capture on.** Same, Video Capture on.
Do not change graphics, overlays, SimHub, CrewChief or irdash between runs. Delta's own settings are the only change.

## Before you start (guard rules)
1. `irdeck-cli.exe state` must say `sim=False`, `onTrack=False`, `telemetry=off`.
2. The test script must call `Assert-RigFree -NeedAway` (sim not running, no START key in 10 min, and 10 minutes with
   no keyboard or mouse input). If Peter is at the PC, stop; do the build and mock work now and this test later.
3. Do not touch the iRacing UI by hand. Do not deploy or restart anything during the three runs.

## Starting each AI race without clicking by hand
`irdeck-cli.exe airace start` (same as the AI RACE key; code in `src/testdrive.cs`, `CmdAiraceStart`). It drives
iRacing's own New Race wizard with the checked clicks and uses the saved AI settings from `ai\level.json`. Use
`irdeck-cli.exe airace start --dry` first to see that the UI is ready (it presses nothing). When it says it is in the
car, let the AI race run for 20 minutes (drive the car with the usual test driver, or let the replay-free AI run if the
test driver is not available; the same method every time). If the wizard fails or shows Something went wrong, stop and
read `irdeck.log`; do not retry blindly.

## What to record each time
1. The `.ibt` (in `Documents\iRacing\telemetry`; read it only after the run, at BelowNormal): per second `FrameRate`,
   `CpuUsageFG`, `GpuUsage`.
2. The black box rows (card W0-9 builds it). Until it exists: the Performance page report for the run and the files
   `dash\data\perf.tsv` (one row per session) and `dash\data\perf-procs.tsv` (every program's CPU, every 5 s).
3. Delta's CPU % and private bytes every second, started just before the race and stopped after it. Example, in a
   second PowerShell window at BelowNormal:
   `Get-Counter '\Process(*Delta*)\% Processor Time','\Process(*Delta*)\Private Bytes' -SampleInterval 1 -Continuous | Export-Counter -Path run-B-delta.blg`
   (divide `% Processor Time` by the number of logical cores to get the share of the whole PC). For run A the counter
   finds nothing: write "Delta absent".
4. Disk queue length every second: `Get-Counter '\PhysicalDisk(_Total)\Current Disk Queue Length' -SampleInterval 1 -Continuous`.
5. A note for each run: start time, lap of any freeze you saw or that the black box shows.

## How to decide
For each run work out, from the `.ibt` per-second FrameRate (skip the first 60 s and the formation lap):
- the average fps,
- the worst second (lowest FrameRate and the lap and time it was at),
- the number of seconds under 60 fps.
Then one sentence per run, for example: "A: average 104, worst 88, 0 seconds under 60. B: average 103, worst 85, 0.
C: average 95, worst 12 at lap 9, 4 seconds under 60."
A difference counts when it is more than a few fps in the average, or any second under 60 that A does not have, or
the same freeze at the same place in two runs. If the three runs agree within the run-to-run noise (A against a second
A run if in doubt), the answer is "no difference".

## The verdict goes on RIG, in Peter's words
One plain sentence, no jargon, stating what to do. For example:
- "Coach Dave Delta cost you 9 fps and one freeze at lap 9. Leave it off for races." (when C is the bad run, add "Its video recording was the cause" and say Delta is fine with recording off).
- "Delta made no difference."
Write the numbers behind it (the three lines above) into `docs\tasks\log\oversight.md`, not on Peter's screens.
