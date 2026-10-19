# Sound in the race videos (2026-10-18)

Peter asked: "audio for race recording?" Engine, tyres, kerbs and the CrewChief spotter are half of reviewing a lap. Until now the recorder (`dash\src\recorder.cs`) filmed the middle screen only.

## Decision

**Option B, with A as the fallback.** A small capture inside irdash (`dash\src\recaudio.cs`, C# 5, plain Windows calls, no library) records **only iRacing and CrewChief** with Windows "process loopback". Only when Windows cannot do that (older than build 19041) or neither program is running does it record the whole PC's output (A). The PC is Windows 11 26200, so B is what runs.

## The three options

- **A. Whole-PC loopback** (default output, shared mode). Simple, but records *everything* (music, Discord voices) and misses iRacing if it plays to another device.
- **B. Process loopback** (`ActivateAudioInterfaceAsync`, `VAD\Process_Loopback`, include the program's process tree). Only the game and the spotter, whatever device they play to. Same capture loop as A, one extra activation step. Two programs are mixed by time into one track.
- **C. ffmpeg does it.** `vault\bin\ffmpeg.exe` (9.0.2 essentials) has only `dshow` and `gdigrab` inputs, no `wasapi`; dshow lists no audio device. No other ffmpeg is on the PC. A newer build would be a download (Peter's yes needed) and would still record the whole PC. Not chosen.

## Why B is safe for the sim

- Shared mode, read only. It never opens a device exclusively, never changes a volume, default device or format. The game cannot tell.
- One BelowNormal thread, polling every 10 ms, a 1 s buffer so a busy moment loses nothing. Measured (tests\audio-test.ps1 1b): 16 ms of processor time in 6.6 s, 0.24 % of one core with the test player included; 192 kB/s of disk while recording (deleted with the video pieces). Each lap clip now also encodes its sound (AAC, one thread, BelowNormal, ~1-2 s of one core per clip) while he drives.
- It runs exactly while the video does (started and stopped with ffmpeg), so the same in-car / out-of-car / gap rules apply.
- The video path is untouched: ffmpeg still writes picture-only segments. If the sound fails, the video is exactly as before.

## How picture and sound stay together

- The video frames carry the wall clock (`setpts=RTCTIME`). Each sound packet carries Windows' own timestamp of when it was played (QPC); it is placed at that wall time. Packets that follow on are joined without a gap (no clicks); a jump over 20 ms is re-placed.
- Sound goes to `vault\rec\aud-<start µs>.pcm`, raw 48 kHz 16-bit stereo, ~10 s each. Nothing playing is written as silence; a hole means the capture was not running.
- When a file is written, the sound is built for **the same wall-clock spans** the picture is made of and encoded once: `-c:v copy -c:a aac -b:a 160k`. The picture is never re-encoded.
- Session join: every piece in the concat list now carries an exact `duration`, so the picture, the sound and the lap offsets all use one timeline (no rounding creep over an hour).
- Lap and incident clips get the sound of the same stretch; the Debrief corner clips are cut from the session file with `-c copy` and keep it.

## Truth on screen

- Sidecars say `audio: ok | partial | none` (and `audioSource`, e.g. "iRacing + CrewChief"). No capture = the file is picture only and says `none`.
- `/vault/recorder` `capture.audio`: ok / starting / failed / off / idle. HOME and the REC pill add **"no sound"** only when the capture failed while recording.
- Players: the Vault player and the Debrief incident player keep his volume and mute; the Workbench has SOUND (key U), off until he presses it once. Nothing plays with sound by itself. The reference clip and the two Coach clips stay quiet (two engines at once is noise).

Off switch (the lead's): `recorder_audio=0` in `dash\irdash.ini`. Not proven yet: real iRacing sound in a real session (the first Test Drive).
