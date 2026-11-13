# 05 - The stutter: which race, what the data shows, what to record next time

Phase 1, evidence only. Nothing was changed, restarted or deployed. The sim was off when checked (`state`: sim=False, telemetry=off).
Old .ibt files were read at BelowNormal; the newest one (today 16:57) was only read from the summary table, not opened.

## Short answer
The freeze was in the **12 Nov 09:28 Road Atlanta GR86 race** (file `toyotagr86_roadatlanta full 2026-11-12 09-28-07.ibt`).
That is "two races ago" counting today's 16:57 race as the latest. It is the only race of the last two weeks with a real freeze.
**Cause is not proven.** The data rules out several things and points at "another program doing work at the start/finish line",
with Coach Dave Delta the only suspect that shows in the numbers. The current tools could not name the cause because they
sample too slowly and keep no per-second record of the dip.

## When, exactly
- Lap 9 to lap 10, on the start/finish straight, about **09:45:59 to 09:46:04 local** (19:35 into the race, session time 1145 to 1150 s).
- iRacing's own frame rate (1-second average) went: 112, 67, 44, 32, 27, 24 (worst), 51, then back to 110+ about 10 s later.
- Lap 9 was a personal best (1:33.832). Lap 10 was 1:34.996, so about 1.2 s lost to the freeze, no crash, no incident logged near it.
- The video lines up: lap 10 starts at video offset 1072.9 s in `vault\saved\20261112-142807-road-atlanta.mp4`. The freeze is roughly 1070 to 1076 s in.
  The picture in that stretch is the quickest way to see what Peter saw.

## What the data shows (for)
| Race | Avg fps | 1% low | Worst second | Dips |
|---|---|---|---|---|
| 6 Nov Road Atlanta Porsche (11:28) | 106 | 87 | 85 | 3.1% |
| 11 Nov Charlotte Legends (20:29) | 111 | 88 | 85 | 3.6% |
| 11 Nov Road Atlanta GR86 (20:57) | 108 | 91 | 84 | 1.4% |
| **12 Nov Road Atlanta GR86 (09:28)** | 114 | 92 | **23.7** | 2.0% |
| 12 Nov Road Atlanta GR86 (16:57, today) | 115 | 97 | 95 | 0.4% |

- Every other race's worst second is in the 80s. Only the 09:28 race fell to the 20s. The 1% low (92) hides it, because the freeze is about 4 s out of 1180 s (0.3%).
- During the freeze iRacing's own CPU and GPU "usage" channels read over 100% (peaks 389% and 394% in the table) while the car's physics stayed
  perfectly regular: the 60 Hz telemetry has **no missing ticks** at any point in the file. So the physics thread was fine; the **rendering / frame side stalled**.
  That fits Peter's description (picture froze) better than "the sim lagged".
- Ping 67 ms flat and connection quality 1.0 throughout. No network event.
- Page faults (hard memory loads from disk) were normal at the moment (2 to 8 per second, not the thousands seen in other sessions). **So it was not the sim being paged out.**
- The 20 min race had only this one event. Before 09:45:59 every second was above 100 fps; after 09:46:15 back to 106 to 115.

## The recorder did not cause it, probably
- Recorder log: one ffmpeg (hevc_nvenc, 60 fps), no errors, no gaps (`gaps: []`), no restarts, "picture check ok". Audio ran the whole time.
- The video itself has frames arriving at a steady 60 per second at 1070 to 1074 s (no capture stall, no encoder stall).
  Frames kept coming while the sim was frozen, which means the capture was healthy and the freeze is recorded in the picture.
- BUT the recorder did one thing near the time: the lap-9 personal-best clip cut (`rec-20261112-144427-l9`, 87 MB, 1271 ms) at about 09:46:03 to 09:46:10.
  That started **after** the freeze began (about 09:45:59), so it cannot be the start. It did the same cut after laps 0, 1, 2, 3 and 6 (PB laps) with no freeze.
  It could have lengthened the tail by a second or so. Not proven either way.
- Encoding itself costs NVENC, not the 3D engine, so it is a low suspect. Cost of the recorder is not measured anywhere today (only ffmpeg's share of one CPU core, 2 to 3%).

## Other suspects, ranked
1. **Coach Dave Delta (overlay/analysis app).** The only program whose use jumps in the per-program sampler: 13% of a core on average, **36% during the dips** (`data\perf-procs.tsv`, row for this drive).
   Everything else stayed flat in the dips: SimHub 15, XboxService 8, Claude 8, Simucube tuner 3, audio 3. Coach Dave Delta also sits at 12 to 13% in the 16:57 race with no dips, so it is not always bad; it may be busy only at a lap crossing (lap data / upload).
   Caveat: the sampler only looks every 5 s and a 4 s freeze may hit only one or two samples. Moderate suspicion.
2. **Paddock's own start-of-lap work.** At each lap crossing irdash saves the lap, updates the personal-best reference (PB laps only), cuts a clip, and every 30 s runs "field laps". Lap 9 did PB reference plus clip plus field-laps within 18 s. Laps 3 and 6 did the same and were fine, so it is not enough alone. The timing (freeze first, then clip log line) argues against it as the starter.
3. **A one-off GPU / driver / shader hitch** (new car or track object streaming in at the start/finish straight). Peak "usage" over 100% on both CPU and GPU channels is typical of a render frame that took far longer than normal. No GPU driver reset or error was logged by Windows.
4. **Windows background work.** Checked the System, Application, Defender, Task Scheduler and Update logs 09:40 to 09:50: nothing logged in that window. No disk, display-driver (nvlddmkm), WHEA or Defender-scan events. Weakly ruled out, but Windows does not log every background burst.
5. **The Stream Deck app.** Its installer ran at 09:53, after the race. The deck watchdog (`deckwatch.cs`) logged nothing at 09:46. Ruled out for this event.
6. **AC script (`ac\ac.py`, every 120 s):** no log line in the window; could not be checked further. Low.

## Not the cause (checked)
Network (flat 67 ms), CrewChief (steady 2%), memory paging (low), the recorder stalling or dropping frames (video shows steady frames),
Windows Update or Defender (no events), a hardware error (none), Stream Deck restart (none).

## What is unknown
- What the PC was doing in those 4 seconds. Paddock samples programs every 5 s and keeps only a **per-drive average**, not per-second values.
- Whether GPU load or temperature, GPU clocks, VRAM, or disk latency spiked. None of these are recorded anywhere.
- Whether the freeze repeats at the same place. The track-position pattern is the best clue: the earlier 9 laps and today's races did not repeat it.
- The log line "Doctor: Frame rate: Last session 160 fps average, 153 at the low end" printed at 09:47:52 was about the earlier Nordschleife file, not this race.
  The doctor's "last session" picked the wrong file. A small bug to fix when rework starts, because it told Peter everything was fine right after the freeze.

## What the Performance page shows today and would it have caught this
- Last-session card: average, 1% low, worst second, a one-line verdict, the three slowest stretches of the lap (named corners), what else ran, trend over sessions, "did it help?".
- It does show **Worst second 23.7** on the card for this session, but:
  - the verdict still says "close to the limit" or "smooth", because it is driven by average and 1% low;
  - the "worst places" list averages every lap together, so a one-time freeze at the line is invisible (it listed `0.2-0.32`, `0.06-0.1`, `0.72-0.84`, the normal weak spots);
  - there is no time or lap for the worst second, so Peter cannot see "lap 9, start/finish";
  - the live amber warning needs a 10 s average 15% under usual and 20 s on track; a 4 s freeze probably slipped under it, and it never wrote anything down;
  - the program sampler is every 5 s with averages per drive, so the suspect (Coach Dave Delta) shows as a hint, not as a fact.
- Verdict: it recorded the number, but would not have **explained** the freeze, nor said when it happened.

## Proposed "performance black box" (always on, silent while driving)
Goal: after any freeze, one line like: "09:45:59, lap 9 start/finish: GPU at 100%, Coach Dave Delta jumped from 13% to 60% of a core, the recorder was cutting a clip."

Record, once per second while the sim runs (about 1.2 KB/s, 4 MB per 20 min race, nothing per frame):
- from the .ibt/SDK feed already read: FrameRate, CpuUsageFG, GpuUsage, MemPageFaultSec, lap, lap position, session time, speed;
- GPU from the driver (NVML, the call `nvidia-smi` uses): GPU load, memory used, clock, temperature, power, "throttle reason";
- CPU: total load, the busiest 3 programs with their CPU share (reusing the existing sampler but every 1 s, not 5 s);
- disk: queue length and latency of the drive holding the vault and the sim (performance counters);
- Paddock's own events: lap crossing, clip cut start/end, field-laps scan, file saves, ffmpeg process CPU, the capture's frames per second.

Add a fast mode: when FrameRate falls more than 25% in one second, switch to every 100 ms for the next 15 s (cost: tiny, about 150 samples), and snapshot the 3 busiest programs plus GPU state at that moment. That is the "freeze snapshot", the part that would have named the cause.

Cost estimate: 1 s sampling of counters and NVML is about 0.1 to 0.3 ms of one core per sample (the current 5 s sampler measured 7.8 ms per sample, 0.16% of one core, so 1 s would be about 0.8%, which can be cut by dropping per-process reads to every 5 s unless a dip starts). No effect on the render thread. Run at BelowNormal in irdash, as the sampler does now.

Storage: one small file per session next to the session file (`data\blackbox\<session>.tsv`), 8 weeks kept.
Show: in the debrief and on the Performance page as a timeline marker ("freeze at lap 9, 0.4 s lost, cause: ..."), never on the race screens. One-line cause rules: GPU at 95%+ means "graphics card"; one program 3x its normal means "that program"; clip cut or file save in the 3 s before the dip means "Paddock"; page faults over 1000/s means "memory"; nothing unusual means "inside the sim (likely a graphics hitch)", which is itself a useful answer.

Also fix while here: make the Performance verdict mention a freeze whenever the worst second is under 50% of the average, and put the time and lap on the card.

## Cheap check Peter or Claude can do next
Watch video offset 1068 to 1078 s of `vault\saved\20261112-142807-road-atlanta.mp4` (also copied to `Videos\Paddock\2026-11-12 09.28 Road Atlanta - Toyota GR86 - Race.mp4`). If the overlay widgets also froze, it points to the sim's render; if only the car froze, to the GPU or a stalled frame.
