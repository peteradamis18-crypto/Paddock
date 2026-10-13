# CARD S1b - fix the S1 recorder review findings

Read AGENTS.md, CLAUDE.md, docs\cards\S1-save-recording.md (the original card), docs\tasks\log\S1.md (builder's report) and
docs\tasks\log\cx\RV-S1.last.md (the review - 9 findings with file:line). C# 5 only.

## Fix all of these (dash\src\recorder.cs unless said)
1. Session boundary: when SessionUniqueID/SessionNum changes or the sim closes, close the running segment at the boundary
   (stop ffmpeg cleanly or force a segment cut) and assign every segment to exactly one session by its start/end time;
   a segment that spans the boundary belongs to the session it mostly covers. No segment in two files, none lost.
2. Finishing: serialize session finishing with the worker (or reference-count segments) so a .ts is deleted only after
   every consumer (probe, lap cut, incident cut, concat) is done. Never continue past a timeout into deletion; on timeout
   keep the segments and retry at the next housekeeping.
3. Shared state: every read/write of openSess, sessions, a session's Segs/Laps/Incidents, cuts and clips under `gate`
   (or take a locked snapshot before background work). Keep lock scopes short; never run ffmpeg/ffprobe inside the lock.
4. SAVE right after a session (the most common press!): a finishing session must be visible to Save("") and to
   /api/rec/sessions (state "finishing"), and Save("") must choose the most recent session - open, finishing or finished -
   never an older one. A SAVE during finishing sets SaveWhenDone and returns SAVING; the finish applies it.
   sessionreview.js and the phone button must show SAVE (not hide) while a session is finishing.
5. One disk floor: every recorder output (lap clips, incident clips, sessions) respects MinFreeGb = 50 (test knob
   freeOverride stays). Update old test section 5 to 50 GB.
6. Saved budget: reserve the bytes atomically under the lock before moving; release on failure. Two SAVEs at once can
   never pass 150 GB.
7. Test section 15: seed leftover segments, then go through the REAL startup path (Recorder.Start / the same code the
   service start uses, via a test route that calls Start's leftover step exactly, not a separate salvage function) and
   assert the recovered session.
8. Test section 14: assert saved session files (mp4 + json) still exist on disk after retention; use fixture sizes that
   force pruning by BYTES against a small recentBudgetBytes, not only by count.
9. Test section 11: compare ffprobe duration with the seconds actually recorded (sum of in-car stint time measured by the
   test), within +-1 s.
Add a test for 4: end a session and immediately SAVE -> the just-ended session is saved, never the previous one.
Add a test for 1: a session change while recording -> two files, durations add up to the recorded time +-1 s.

## Files
dash\src\recorder.cs, dash\src\vault.cs (only if a route must change), dash\www\v2\sessionreview.js, dash\www\phone\app.js
(only the SAVE button state), tests\recorder-test.ps1, docs\vault.md, docs\tasks\log\S1b.md (report).

## Gate
- `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` compiles clean.
- If your sandbox allows it and `.\irdeck-cli.exe state` shows sim=False: deploy with
  `powershell -ExecutionPolicy Bypass -File dash\build.ps1` and run `powershell -ExecutionPolicy Bypass -File
  tests\recorder-test.ps1` -> 0 FAIL (section 10 may skip). If the sandbox blocks deploy or localhost, say so in the report;
  the lead deploys and runs the tests.
- Never act on Peter's screens; never touch iRacing files.
- Report in the AGENTS.md format to docs\tasks\log\S1b.md, listing each of the 9 findings + 2 new tests: fixed how, line.
