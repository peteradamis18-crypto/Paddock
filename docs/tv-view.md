# Live TV view — can iRacing show a second camera while you drive?

Short answer: no. One running sim draws one camera. Nothing in the 2026 sim adds a second live view that leaves the driving picture and iRacing's own files alone. Paddock draws its own view from telemetry (task C-22, step 2).

## What was checked

The iRacing SDK camera and replay messages (`CamSwitchPos`, `CamSwitchNum`, `CamSetState`, and the replay controls) only work when the player is out of the car. The SDK header says camera and replay controls are for when you are not driving; pit commands are the ones that work in the car. The same note is quoted by SIMRacingApps (`BroadcastMsg`) and by the kerb project's `broadcast.rs`. Those messages retarget the one sim camera. They do not open a second one.

Replay plays in the same window. `IsReplayPlaying` is that window showing the replay instead of the drive. It takes over the picture Peter is driving with.

"Render scene using 3 projections" is the driving view spread across three monitors. It is still the driver's camera, not a spectator camera beside it.

The iRacing Camera Tool has one live view. The camera you drive with is that view.

The 2026 Season 4 build notes (support article 2026.10.01.01) do not add a second viewport, a broadcast window, or a multi-view.

iRacing Arcade's four-player split screen is a different console game, not a window inside the sim Peter drives.

A broadcast overlay such as EDR (July 2026) draws graphics from SDK data. It does not open a second iRacing camera. A real spectator picture needs another iRacing connection in the session: another PC and another account, watching.

The reference-car billboard is a flat widget inside the driving view, and only in time trial or a test drive. Using it would change what Peter sees. It is not a TV feed for the top screen.

## What Paddock does

The top screen draws the track from the real outline (`TrackMap` / the corner list) and every car from `CarIdxLapDistPct`. The picture is flat, in perspective, with no invented hills. Peter's driving view is not touched, and no iRacing file is written. A real cinematic camera remains a second PC running Studio, as the roadmap says.
