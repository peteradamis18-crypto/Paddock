# CARD S1 - SAVE RECORDING (whole-session video, kept by rules, one press keeps it forever)

Read AGENTS.md and docs\COPY-RULES.md first. C# 5 only. Stay inside the Files list.

## Why
Peter drove a session, pressed nothing, and found only best-lap clips: the recorder (dash\src\recorder.cs) keeps a rolling
~3 min of 10 s MPEG-TS segments and cuts lap clips. He wants the WHOLE session kept. Rules confirmed by Peter 2026-10-11:
- Record whenever he is in the car (already so: ShouldRecord).
- Keep his last 3 sessions, every personal-best lap clip (already kept) and incident clips, without any press.
- SAVE (Stream Deck key, phone, Session Review screen) keeps a session forever.
- Budgets: recent (unsaved) sessions <= 30 GB, saved sessions <= 150 GB, the disk never below 50 GB free.
- HEVC to halve the size.

## What to build (dash\src\recorder.cs unless said)
1. **Encoder.** Default `hevc_nvenc -preset p4 -rc vbr -b:v 8M -maxrate 12M -bufsize 16M` (the ffmpeg in vault\bin has
   it). Fallback chain on start failure (same detection as today's OnExit): hevc_nvenc -> h264_nvenc -> libx264. Every
   mp4 we write with HEVC gets `-tag:v hvc1` (iPhone/Safari need it) and `-movflags +faststart`; keep the rotation flag
   exactly as the lap cut does today. The test source stays libx264. Check BuildArgs' `enc == "h264_nvenc"` tests: ddagrab
   stays on the GPU for any *_nvenc encoder.
2. **A session.** One recording = one iRacing session: starts at the first in-car segment, ends when the sim closes,
   SessionNum or SessionUniqueID changes, or irdash stops. Several stints (in/out of the car) in one session go into one
   file (the gaps are simply skipped). While a session is open its segments are NOT pruned by KeepMs (lap/incident cuts
   still work as now).
3. **Finish a session** (worker thread, BelowNormal): concat the session's segments in time order WITHOUT re-encoding
   (ffmpeg concat demuxer, `-c copy`) into `vault\sessions\<yyyyMMdd-HHmmss>-<track short>.mp4` plus a `.json` sidecar:
   id, track, config, car, sessionType (Practice/Qualify/Race/...), startMs (wall clock of the first frame), durationSec,
   bytes, encoder, saved (bool), laps [{n, offset (s into the file), time, clean, pb}], incidents [{offset, count}].
   Then delete that session's .ts files. Write via a temp name + rename so a half file is never listed.
4. **Salvage after a crash/deploy.** Start() today wipes vault\rec. Instead: if leftover segments exist, finish them as
   one session first (sidecar `recovered: true`, laps empty), then wipe.
5. **Incident clips.** When `PlayerCarMyIncidentCount` rises while recording, cut 20 s before to 10 s after (wait until
   +10 s is on disk) into `vault\clips\inc-<stamp>.mp4` + sidecar (kind "incident", points added, session id), no
   re-encode, same rotation handling. Also list the incident in the session sidecar.
6. **Retention** (Housekeeping, at most once a minute, and after every finish):
   - unsaved sessions: keep the newest 3 AND total <= 30 GB; delete the oldest unsaved first;
   - saved sessions are never deleted by the program; a SAVE that would pass 150 GB is refused (state "SAVED FULL");
   - free space < 50 GB (change MinFreeGb 20 -> 50; the test knob freeOverride stays): delete oldest unsaved sessions,
     then incident clips whose session is not saved and older than 30 days, then today's TrimClips order; if still below
     50 GB stop recording with note "Disk nearly full: recording paused";
   - incident clips of unsaved sessions older than 30 days are deleted; PB clips are kept as today.
   Test knobs (sandbox only, like keepOverrideSec): keepSessions, recentBudgetBytes, savedBudgetBytes.
7. **SAVE.**
   - `Recorder.Save(string id)`: id empty = the open session (flag saveWhenDone, applied at finish) or else the newest
     finished one. Saving = sidecar saved=true and move mp4+json to `vault\saved\`. Idempotent (a second press = no-op,
     still answers saved). Returns a short state word: SAVED / SAVING (session still open) / SAVED FULL / NOTHING.
   - Deck: add `"recsave"` to the Commands set in dash\src\vault.cs and route it to Recorder.Save("") (irdeck's
     `dash recsave` reaches it; the deck key itself is the lead's job - write the line for build-deck.ps1 in NEEDS LEAD).
   - HTTP (add next to the existing recorder routes in vault.cs): `GET /api/rec/sessions` (JSON list: id, track, car,
     sessionType, startMs, durationSec, bytes, saved, laps count, incidents count), `POST /api/rec/save?id=`,
     `GET /api/rec/session-video?id=` (Range support - reuse ServeVideo's code path), status fields in StatusJson
     (open session id + seconds + bytes + saveWhenDone, recentGb, savedGb, freeGb, encoder).
   - Session Review screen (dash\www\v2\sessionreview.js): one SAVE button for that session's recording (matched by
     time window), turns to SAVED; hidden when there is no recording. Phone app: the same button on its session screen
     (find the phone page that lists sessions). Copy: `SAVE`, `SAVED`, `SAVED FULL` only.
8. Logs in today's recorder style (plain English, one line per event).

## Files
dash\src\recorder.cs, dash\src\vault.cs (Commands + routes only), dash\www\v2\sessionreview.js (+ its css if needed),
the phone session page, tests\recorder-test.ps1, docs\vault.md (update the plain-English notes).

## Gate (all must pass, rig free: `irdeck-cli.exe state` sim=False)
- `powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy` compiles clean.
- Deploy with `powershell -ExecutionPolicy Bypass -File dash\build.ps1` (it refuses while unsafe; exit 2 = stop and report).
- tests\recorder-test.ps1: every old section still passes, plus new sections using the test source:
  11. a pretend session of ~40 s with two stints -> one session mp4 in vault\sessions, ffprobe duration = recorded seconds
      +-1 s, sidecar laps/offsets right, the .ts files gone;
  12. an incident bump -> inc-*.mp4 of ~30 s and the incident in the sidecar;
  13. SAVE during the session -> after finish the files are in vault\saved with saved=true; second SAVE is a no-op;
      `dash recsave` path via the command route works;
  14. retention with small budgets: 4th unsaved session deletes the oldest; saved never deleted; SAVED FULL refusal;
      freeOverride below 50 GB pauses recording with the note;
  15. salvage: leftover segments at Start become a recovered session;
  16. /api/rec/session-video serves Range requests.
- tests\copy-audit-test.ps1 passes.
- Report in the AGENTS.md format to docs\tasks\log\S1.md.
