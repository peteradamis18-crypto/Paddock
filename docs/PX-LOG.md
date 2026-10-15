# Paddock build log (lead: Claude Opus 5.5, from 2026-10-15)

Plan: `C:\Users\peter\Documents\Codex\2026-10-13\new-chat-2\outputs\Paddock-Claude-Build-Plan.md` (PX-00...PX-07).
Gates per `docs/QUALITY-GATES.md`: contract / engineering / experience / rig, each pass / fail / pending.

## Increment 1 — truth audit + recording identity, honest gaps, save truth, calendar (2026-10-15)

### Truth audit (observed in source and on the rig, 2026-10-15 ~11:00 ET)
- Git: 2 local commits, no remote configured; `git` exists only as Grok's bundled copy
  (`%LOCALAPPDATA%\grok\git\2.55.0.windows.5\cmd\git.exe`). GitHub repo `peteradamis18-crypto/Paddock` is **public**,
  holds only `.gitignore` (f63f5ea). Source NOT pushed (would publish it). Tracked tree scanned: no secrets.
- Rig: `sim=False`, Windows zone `Eastern Standard Time`. Deployed irdash predates this work.
- Real recordings on disk: 3 schema-1 sidecars (Road America, BMW Z4 GT3, "Race", 98 s / 222 s / 664 s, 10:43-11:02 ET)
  — no `uniqueId`/`sessionNum`, so the old debrief matched them by track name + nearest time (newest-wins with no time).
- Confirmed defects (source): sidecar lacks session identity; `WallToFile` snapped any moment in a missing segment to
  the next segment's picture; low-disk cleanup measured free space *before* deleting, so it queued **every** unsaved
  session; `MoveToSaved` reported success after a failed sidecar write and `WriteSessJson` deleted the old sidecar
  first; a SAVE blocked by the saved-video budget was withdrawn silently; calendar busy-gate `null` replaced the whole
  cache with only the providers that answered; date-only rows were grouped by midnight UTC (the evening before in ET);
  ICS all-day / unknown-TZID rows were dropped; display zone was `TimeZoneInfo.Local`.
- Audit finding **withdrawn**: "F1 practice/qualifying/sprint never arrive" — `ParseF1` already emits them (the audit
  read `WalkF1`); only Sprint Qualifying was missing.
- LLM preview lines: `RealWorld.PreviewLines` is never assigned (compiler CS0649) → off.

### Changes
- `dash/src/sessmatch.cs` (new, pure): `WallToFile` → NaN outside recorded spans; `MissingSpans`; `Pick` =
  verified (SessionUniqueID + SessionNum) / probable (legacy sidecar, same track/car/type ≤ 2 h) / none. No newest-wins.
- `recorder.cs`: sidecar schema 2 (`uniqueId`, `sessionNum`, `gaps`, `state` ready/partial, `durationSource`,
  `saveWhenDone`, `saveBlocked`); lap/incident offsets `null` inside a gap; temp → read-back → `File.Replace`;
  saved sidecar written before the video moves; sidecar failure keeps the segments and retries; blocked SAVE kept
  with a reason; disk cleanup deletes one, re-measures, never touches a session with a pending SAVE, stops on a locked
  file; `Save()` returns `SAVE FAILED` instead of `NOTHING` when the move fails.
- `debrief.cs`: the review resolves its recording once from the analysed lap's IBT identity; `bar.recording =
  {association, state, gaps, id}`; SAVE target only when `verified`; incidents inside a gap listed with `status:"gap"`.
- `realworld.cs`: providers independent (a failed or cut-off provider keeps its own rows; partial refresh keeps the old
  age so it retries); explicit New York display zone; date-only / all-day / unknown-zone rows kept as time TBC on their
  date; IANA→Windows table for the venues these series use; Sprint Qualifying.
- `home.js`: New York time, 12-hour, EST/EDT label; "time TBC" rows.

### Evidence
See the commit message for the test run of this increment.

## Increment 2 — independent review fixes, map off the request path, truthful REC, review trigger (2026-10-15)

Independent review (Opus, read-only, of commit 48fe856) found 9 defects; fixed here:
1. HIGH "verified" could pick another sim launch's recording (SessionUniqueID is a per-launch counter, seen = 2):
   verified now also requires the analysed lap's wall-clock time (IBT file-name start + lap session time) to fall
   inside the recording's span (new sidecar `endMs`, ±120 s). No nearest-in-time fallback.
2. HIGH Session Review and phone SAVE still used newest-in-window: both now ask `/api/rec/for?id=<ibt>` (same rule).
3. Sidecar retry turned incidents into gaps: wall-time incidents restored on every failed attempt.
4. Encoder start-up: a moment ≤ 3 s before a span shows that span's first picture; otherwise null.
5. Disk clean-up stops when freed bytes cover the shortfall or free space does not rise; skips sessions < 10 min old.
6. `recsave` deck key lit for SAVE FAILED/FULL: now only SAVED/SAVING; pages show SAVE FAILED; recState set at finish.
7. Durability: sidecar temp and finished mp4 flushed to disk (`Flush(true)`) before segments are deleted.
9. MoveToSaved no longer exposes "saved" before the move; review skips sidecars whose mp4 is gone; gap incidents shown.
Not fixed (recorded): a SAVE blocked as "full" keeps protecting its session from clean-up indefinitely (deliberate:
Peter asked to keep it; recording pauses with "Disk nearly full" if space runs out) — needs a product decision.

Map (PX-05 core): `/trackmap` is cache-only (+ the small offline-library file); IBT and network builds run on one
BelowNormal background thread with 1/5/15/60-min backoff, never reading an IBT written in the last 2 min (30 min while
the sim runs). 202 `{status:"building",retryAfter,lastError}`. The startup straight-bar placeholder came from
`BuildAll` holding the same lock for minutes; both map.js and tv.js now draw a status line and no invented car positions.

REC (PX-06 part): recorder status carries one `capture` verdict — recording only while segments keep landing
(`starting|recording|stalled|paused-disk|failed|idle|off`); the fourth screen shows `REC 41:12`, `REC PAUSED: DISK FULL`,
`NOT RECORDING`, or `RECORDING UNKNOWN` when irdash cannot be reached.

Review trigger (PX-03 core): the debrief reply names its session (`session.uniqueId/sessionNum/lap`); the page
remembers the live SessionUniqueID/SessionNum/LapCompleted, and after leaving the car polls for 90 s, accepting only
the matching session; no completed lap → no review; getting back in cancels.

Open failures: tv-test "CHASE replaces BATTLE" is pre-existing (also in tests\last\tv.txt). home-test has 3 state
checks failing that look unrelated to the schedule-text change (not verified against the old build) (START label with the iRacing UI open; PB/long-name fixtures
overwritten by the live refresh). Real-world data note: today's series name "SENSIT!" trips the copy rule on HOME.
