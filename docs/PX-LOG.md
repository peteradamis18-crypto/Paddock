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
