# Evidence 14: direct YouTube upload pipeline

Researched 2026-11-13. Tags: **[checked]** = read on a Google page today (the fetch tool summarises pages, so quotes are as it returned them); **[background]** = my knowledge, not fetched; **[estimate]** = reasoning, not measured; **[local]** = read from this PC today. `irdeck-cli state` first: sim=False, telemetry=off, so local checks ran. Nothing was changed except this file.

## 1. Google side (one time, about 10 minutes, Peter's Google account)

1. Open console.cloud.google.com, create a project (name "Paddock"). [background]
2. APIs & Services > Library > "YouTube Data API v3" > Enable. Google: "Create or select a project in the Google Cloud console, open the API Library, and enable the YouTube Data API v3." [checked, registering_an_application]
3. OAuth consent screen (in 2026 the console calls this "Google Auth Platform": Branding, Audience, Data Access, Clients). [background; the registering page does not cover it]
   - App name "Paddock", support email and developer email = Peter's. User type **External** (a personal Gmail has no Internal option).
   - Data Access: add the scope `https://www.googleapis.com/auth/youtube.upload`.
   - Audience: add Peter's own address as a test user first, then press **Publish app** (status "In production").
4. Credentials > Create credentials > OAuth client ID > application type **Desktop app**. Google: "Use the OAuth 2.0 for Desktop Apps flow for macOS, Linux, Windows, or command-line applications." [checked] Then press Download JSON (client_secret_....json). The page did not describe the download button [background].

**Testing or In production, and verification.**
- Testing: "limited to up to 100 test users"; test-user authorisations "expire seven days from the time of consent", refresh token included. [checked, support.google.com/cloud/answer/15549945] So Testing is useless for a rig that must work unattended.
- In production: "available to any user with a Google Account." [checked] Verification is only triggered by the scope: the warning appears when the request "includes additional scopes that haven't been approved." `youtube.upload` is a sensitive scope, so Peter will see "Google hasn't verified this app" once; he clicks Advanced > Go to Paddock (unsafe) > Allow. [checked for the warning rule; that publishing itself needs no verification is my reading: nothing on the page makes verification a condition of pressing Publish]
- The 100-user cap: "100 new users in total, after the app presents the unverified app screen", and it "applies over the entire lifetime of the project, and it cannot be reset." [checked] One user = 1 of 100 used. Do not let anyone else sign in with this client.
- Exception noted by Google: only basic-profile scopes avoid the 7-day expiry. Not our case, so In production is mandatory.
- Risk: while unverified, Google may still revoke refresh tokens that go unused for about six months or after a password change [background]. Design for `invalid_grant` = one "Sign in to YouTube again" key.

**Scopes.**
- `youtube.upload`: enough for videos.insert; thumbnails.set accepts it too (the page lists youtubepartner, youtube.upload, youtube, youtube.force-ssl). [checked]
- playlistItems.insert does **not** accept youtube.upload; it needs `youtube` or `youtube.force-ssl` (or youtubepartner). [checked] So playlist adding means requesting the broader `https://www.googleapis.com/auth/youtube` scope, which lets the app manage the whole channel. Recommendation: ask only for youtube.upload in v1 (playlist = skip, or Peter's own "auto playlist" via YouTube Studio rules) and add `youtube` only if he wants playlists.

## 2. Loopback sign-in in C# 5 (.NET Framework 4.x)

All from Google's native-app page [checked]:

1. Make `code_verifier`: 43-128 random chars of `A-Za-z0-9-._~` (use `RNGCryptoServiceProvider`, base64url of 32 bytes = 43 chars). `code_challenge` = base64url(SHA256(verifier)) with `=` stripped, `+`->`-`, `/`->`_`. Make a random `state`.
2. `HttpListener` on `http://127.0.0.1:{port}/` with a free random port (bind a `TcpListener` on port 0, read the port, close it, then start the HttpListener; retry if taken).
3. Open in browser (`Process.Start` of the URL via explorer.exe, per CLAUDE.md rule 3):
   `https://accounts.google.com/o/oauth2/v2/auth?client_id=...&redirect_uri=http%3A%2F%2F127.0.0.1%3A{port}&response_type=code&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fyoutube.upload&code_challenge=...&code_challenge_method=S256&state=...&access_type=offline&prompt=consent`
   (`access_type=offline` and `prompt=consent` are [background]; Google says "refresh tokens are always returned for installed applications" [checked], but they do no harm.)
4. Listener gets `GET /?code=...&state=...` (or `error=access_denied`). Check `state`; reply with a small page "You can close this window"; stop the listener.
5. Token exchange: `POST https://oauth2.googleapis.com/token`, form-encoded: `client_id`, `client_secret`, `code`, `code_verifier`, `grant_type=authorization_code`, `redirect_uri` (identical string). Answer: `access_token`, `expires_in` (3600), `refresh_token`, `scope`, `token_type`.
6. Refresh (before each upload, or when a call returns 401): same URL with `client_id`, `client_secret`, `grant_type=refresh_token`, `refresh_token`. Answer gives a new `access_token` only. `invalid_grant` = signed out.
7. Google says the secret is optional for desktop clients: "Desktop apps are public clients and cannot keep secrets confidential." [checked] Send it anyway (the JSON has it) but do not treat it as private; keep the JSON out of git (the repo is public).
8. Storage: `System.Security.Cryptography.ProtectedData.Protect(bytes, entropy, DataProtectionScope.CurrentUser)` into `yt\token.bin`, same as the cloud sign-in idea. I could not confirm in the source how `ac\cloud.bin` is written (grep for ProtectedData found nothing; `cloud.bin` appears only as an existence check in `dash\src\ac.cs` and `src\irdeck.cs`), so reuse whatever that code does if it exists elsewhere, else DPAPI as above. Store client_secret JSON beside it (also protected). Needs `System.Security.dll` reference in the csc line.
9. Run the sign-in through irdash's HTTP API (irdash runs outside the Claude package, rule 3) and only while the sim is off.

## 3. Resumable upload [checked, using_resumable_upload_protocol]

1. **Start:** `POST https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status`
   Headers: `Authorization: Bearer <token>`, `Content-Type: application/json; charset=UTF-8`, `X-Upload-Content-Length: <file bytes>`, `X-Upload-Content-Type: video/mp4`.
   Body:
   `{"snippet":{"title":"...","description":"...\n0:00 Start\n...","tags":["iRacing","sim racing","Road Atlanta"],"categoryId":"20"},"status":{"privacyStatus":"private","selfDeclaredMadeForKids":false}}`
   `categoryId` 20 = Gaming [background; the invalidCategoryId error says to check videoCategories.list]. Title max 100 chars, description max 5000 bytes, tags total about 500 chars [background]. Always send `privacyStatus`: without it "defaults to public." [checked]. `status.containsSyntheticMedia` exists too; set false.
   Reply `200 OK` with `Location:` = session URL. Save it to disk (`yt\session.json`) so a restart can resume.
2. **Send:** `PUT <Location>` with `Content-Length: <file>` and `Content-Type: video/mp4`, body = the file streamed. Google prefers one request; "success: 201 Created" with the video resource (the `id` is the link `https://youtu.be/<id>`).
3. **Resume** after a dropped link or 500/502/503/504 (exponential backoff 1, 2, 4... up to ~10 min): `PUT <Location>`, `Content-Length: 0`, `Content-Range: bytes */<total>`. `308 Resume Incomplete` + `Range: bytes=0-N` means the next byte is N+1; no Range header = nothing received. Then `PUT` with `Content-Range: bytes N+1-(total-1)/total`. "You cannot upload a noncontinuous block." `404` = session expired; start over. Other 4xx = permanent. If already finished, the server returns the final response again.
4. **Chunks:** only for progress bars; "a multiple of 256 KB", all equal except the last. Plan: 8 MiB chunks (32 x 256 KB) so progress is drawn every 8 MB and a failed chunk costs little; each non-last chunk answers 308. Use `HttpWebRequest` with `AllowWriteStreamBuffering=false`, `SendChunked` off, `ContentLength` set.
5. **Access token** lives 1 hour; a 1.2 GB upload may outlast it on a slow line. The upload URL needs the header on each PUT, so refresh between chunks (another reason for chunks).
6. **Thumbnail:** `POST https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId=<id>&uploadType=media`, body JPEG/PNG up to 50 MB, `Content-Type: image/jpeg`. Cost about 50 quota units. Errors: 403 `forbidden` (no permission to set custom thumbnails), 429 `uploadRateLimitExceeded`. [checked] YouTube help: "upload your own if your account is verified" [checked]; the page does not say phone, but verification is by phone in practice [background]. Treat a 403 as "skip thumbnail, tell Peter once", never as an upload failure.
7. **Playlist:** `POST https://www.googleapis.com/youtube/v3/playlistItems?part=snippet` body `{"snippet":{"playlistId":"PL...","resourceId":{"kind":"youtube#video","videoId":"<id>"}}}`, 50 units, needs the `youtube` scope (see section 1). [checked for scope and cost; body from background]
8. **Chapters:** description lines `0:00 Start`, `2:10 Lap 1`...; first stamp must be 0:00, at least 3, ascending, each at least 10 s. [checked in evidence 04]
9. **Errors to handle** (videos.insert table, [checked]):
   - 400 `uploadLimitExceeded`: daily/channel upload cap (new or unverified channels get a limit of a few dozen per day [background]). Tell Peter "YouTube says you've reached today's upload limit", retry after midnight Pacific; keep file queued.
   - 403 `forbidden`: no description; usually auth problem; try refresh once, then ask to sign in again. 403 `forbiddenPrivacySetting`: fall back to private and show it.
   - 400 `invalidTitle / invalidDescription / invalidTags / invalidCategoryId`: our bug; strip `<` `>`, trim to limits, retry once with a plain title, else log.
   - 403 `quotaExceeded`: not in the videos.insert table [checked: absent]; it comes from the shared quota bucket (10,000/day; videos.insert has its own bucket of 100 calls/day since June 2026 per evidence 04). Retry after midnight Pacific.
   - 401: refresh the token and retry. `invalid_grant` on refresh: sign-in key.
   - Unverified-project private lock: videos.insert page now says "Videos uploaded from unverified API projects are not restricted to private viewing mode." [checked today]; "certain uploads might default to private based on creator account settings." So send the setting explicitly, then read back `status.privacyStatus` of the response and show the real state on the deck.

## 4. Local checks (read only)

- **State:** `sim=False ui=True telemetry=off`.
- **ffmpeg: yes.** `C:\Users\peter\iRacingDeck\vault\bin\ffmpeg.exe` and `ffprobe.exe`, version 9.0.2 gyan essentials. It has `hevc_nvenc`, `h264_nvenc`, `av1_nvenc`, `aac`, `sidechaincompress`, `amix`, `loudnorm`, and the `dshow` capture device. Not in PATH, not in `tools\`, none in Program Files. (winget search returned nothing for ffmpeg, whisper or obs.)
- **Recorder settings** (`dash\src\recorder.cs` lines 508-512 and 971): `hevc_nvenc -preset p4 -rc vbr -b:v 8M -maxrate 12M -bufsize 16M -forced-idr 1`, `-g 60 -bf 0 -force_key_frames expr:gte(t,n_forced*1)`, 60 fps, no B-frames; sound AAC 160 kbit/s stereo 48 kHz (iRacing + CrewChief). Falls back to h264_nvenc 16M, then libx264. Last finished race checked with ffprobe: HEVC 2560x1440, 60 fps, 7.9 Mbit/s video, AAC 160 kbit/s, 1282 s long, 1.30 GB. **Keyframes land about every 1.0 s** (0.00, 1.01, 2.01, 3.01, 4.00...).
- **Race files today:** `C:\Users\peter\Videos\Paddock`, 4 files, 1.15 to 1.30 GB each (about 4.8 GB). C: has 282 GB free of 919 GB.
- **Microphone:** one live capture endpoint: "Headset (Peter's AirPods Max - Find My Hands-Free)" (status OK; dshow lists it). A "Microphone (2- Arctis Nova 7P)" exists but status Unknown (headset not connected right now). So a real mic exists only when the Arctis is plugged in; the AirPods hands-free mic is Bluetooth narrowband quality (16 kHz at best) and switching it to hands-free also drops the AirPods' playback quality [background]. Recommend the Arctis Nova 7P mic for commentary; check at use time by name.
- **Whisper / speech tool:** none found (searched the home folder and Program Files to depth 5 for `*whisper*` and `ggml-*`; none).
- **Replay API:** yes. `dash\src\replay.cs` and `replayjump.cs` already drive the iRacing replay through SDK broadcast messages (no clicks): `ReplaySearchSessionTime` (jump to session number + time), `ReplaySearch` (previous/next lap, start, end), `ReplaySetPlaySpeed`, `CamSwitchNum`; live `ReplayPlay`-type keys `rpjump`, `rpsession`, `rplapprev/next`, `rpplay`, `rpback10` etc. exist. It deliberately never sends `ReplaySetState` (it erases the tape). So Paddock can put iRacing to a session time at 1x speed and start recording the mic at that moment. Limit: the iRacing replay exists only while the sim is open (or a saved replay is loaded) and only after the race; this also means commentary cannot be recorded "from the file": see option B below. Whether the replay can be locked at exactly 1.0x in sync with a video file is the open point (section 5).

## 5. Pipeline design

**A. Record (already built).** Whole session = one HEVC mp4 with audio. Race markers (lap rows, flags, pit, incidents) already exist in the recorder (`LapRows`).

**B. Race ends -> auto trim (lossless).**
Keyframes about every 1.0 s, no B-frames, so a stream-copy cut starts at the keyframe at or before the requested time: **at most about 1 second early**, never late. Cut start = (race green flag time, or end of out lap minus 3 s) from the lap data; cut end = checkered flag + 20 s (cool-down lap shortened), end snaps to the next keyframe (up to 1 s late). Command:

`vault\bin\ffmpeg.exe -hide_banner -y -ss 95.0 -to 1245.0 -i "in.mp4" -c copy -map 0:v:0 -map 0:a:0 -tag:v hvc1 -movflags +faststart -avoid_negative_ts make_zero "out.mp4"`

`-ss` before `-i` seeks to the keyframe; timestamps stay in sync with the audio (audio is AAC, cut on frame edges, error under 25 ms). Time: disk-bound, about 1.3 GB at 1-2 GB/s = 2-10 s on the NVMe [estimate]. Disk: the cut is a second copy (up to 1.3 GB) until upload succeeds; delete it after. Keep the original per the existing retention rules.

**C. Title and chapters.** Template picked once in Settings (evidence 04 list). Chapters from markers, starting `0:00 Start`, offset by the trim start (marker time minus the real start of the cut, the keyframe time, not the requested time; get it from `ffprobe -select_streams v:0 -show_entries packet=pts_time -read_intervals ...` or just use the requested time minus up to 1 s: stamps will then be at most 1 s late, acceptable). Drop any chapter closer than 10 s to the previous one.

**D. Upload.** Setting "Uploads are: private / public" (default private; public after the first checked real upload). Run only when the sim is off (rule 1), at low priority, with a 1.2 GB file. Time: depends entirely on his upload speed, which I could not measure. [estimate] at 20 Mbit/s up, 1.2 GB = about 8 min; at 5 Mbit/s = 33 min; his online speed was noted earlier as about 500 KB/s (CLAUDE.md, downloads), which would be about 40 min. Show "Uploading 41%" and, when done, the link (`https://youtu.be/<id>`) in the card, copied to clipboard, with a QR/open-in-browser key.

**E. Failure handling.**
- Network drop or app/PC restart: keep `yt\session.json` (session URL, file path, size, started time, video params). On next start with sim off, ask `Content-Range: bytes */total`, continue from the byte. Sessions live about a week [background]; on 404 restart from zero.
- Token dead: card shows "Sign in to YouTube again" (one key); the queue is kept.
- Quota/limit: card shows "YouTube limit reached, will try after midnight Pacific"; retry automatically once a day.
- Process after success: read back the video resource (`status.uploadStatus`, `privacyStatus`); only then mark the race as "On YouTube" and allow deleting the local cut. Never delete the original automatically on upload success; only per the retention rule.
- Idempotent: before starting a new session, check `yt\uploads.json` for that race id; never upload twice. A mid-way crash with a lost session id means YouTube may have an unfinished upload, which it discards after a day; no cleanup needed.

**F. Optional commentary pass.**
Two ways to get a voice-over in time with the video:
1. **Play the video file** (recommended; reliable sync). Paddock plays the finished mp4 in a window (or just uses ffplay, shipped? not in vault\bin: only ffmpeg and ffprobe; use the Windows media player or a small own HTML `<video>` page in irdash's top screen) and records the mic with `ffmpeg -f dshow -i audio="Microphone (2- Arctis Nova 7P)" -ar 48000 -ac 1 -c:a pcm_s16le voice.wav` started at the same click as playback. Offset is the click-to-play lag (about 100-300 ms) [estimate]; correct it with one "talk starts at" nudge, or have a fixed latency setting measured once. Works with no iRacing running, no 3D replay, and no Peter's PC load.
2. **iRacing replay** with `ReplaySearchSessionTime` plus speed 1: gives the iRacing camera view live, but you would be recording the screen again (second-generation capture, and sync is only as good as the replay sync), and it needs the sim open. Not recommended except to re-film a moment with different cameras; the existing recorder can already capture that.
- Mix with ducking and a re-encoded audio track, video untouched:
  `vault\bin\ffmpeg.exe -y -i trimmed.mp4 -i voice.wav -filter_complex "[1:a]asplit=2[vkey][vmix];[0:a][vkey]sidechaincompress=threshold=0.04:ratio=8:attack=20:release=400[duck];[duck][vmix]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.95[a]" -map 0:v:0 -map "[a]" -c:v copy -c:a aac -b:a 192k -tag:v hvc1 -movflags +faststart commentary.mp4`
  (`amix ... normalize=0` exists in ffmpeg 8.0+; this build is 9.0.2. Threshold/ratio are starting values to tune by ear.) Time: audio-only re-encode of 20 min = about 10-20 s [estimate]. Disk: another 1.3 GB.
- Publish as a **second video** ("... with commentary") rather than replacing the first: replacing the file of an existing video id is not possible through the API (videos.update does not take media) [background], so "re-upload" always means a new video id. Default: upload the commentary version only if made, link both on the card.
- Subtitles/draft description with whisper.cpp: not present; needs a download (about 500 MB model for "small") and Peter's yes. Skip in v1.

**G. Disk summary.** Per race: original 1.3 GB, cut 1.3 GB (temporary), commentary 1.3 GB (optional, temporary). Keep at least 10 GB free before a trim.

**H. Build order.** (1) sign-in + one test upload of a 10-second private clip, read back `privacyStatus`; (2) trim with chapters; (3) resumable with a real network cut (unplug test); (4) title templates; (5) commentary mix by ear. Tests must obey guard.ps1; the real upload test needs Peter's Google sign-in click (he does the "unverified app" screen himself).

## Open points I could not settle

- Whether pressing Publish with an unverified sensitive scope works with zero Google review today: the cap page implies yes (warning + 100-user cap), but no page says it plainly. First real test decides.
- Whether the thumbnail call needs a phone-verified channel for Peter: help page says "verified"; try once, treat 403 as skip.
- Peter's real upload speed (not measured).
- How `ac\cloud.bin` is protected (not found in source by grep).

## Links

- Resumable upload: https://developers.google.com/youtube/v3/guides/using_resumable_upload_protocol
- videos.insert: https://developers.google.com/youtube/v3/docs/videos/insert
- thumbnails.set: https://developers.google.com/youtube/v3/docs/thumbnails/set
- playlistItems.insert: https://developers.google.com/youtube/v3/docs/playlistItems/insert
- Upload guide (scope, API enable): https://developers.google.com/youtube/v3/guides/uploading_a_video
- Registering an application: https://developers.google.com/youtube/registering_an_application
- OAuth for desktop (loopback, PKCE): https://developers.google.com/identity/protocols/oauth2/native-app
- Testing vs production, 100-user cap, 7-day expiry: https://support.google.com/cloud/answer/15549945
- Thumbnails help: https://support.google.com/youtube/answer/72431
- Quota and compliance audits: https://developers.google.com/youtube/v3/guides/quota_and_compliance_audits
- YouTube chapters: https://support.google.com/youtube/answer/9884579
- Local: dash\src\recorder.cs, dash\src\replay.cs, dash\src\replayjump.cs, vault\bin\ffmpeg.exe
