# Evidence 04: video library, upload, trim, commentary

Researched 2026-11-12. Web search and page fetch both worked. Each claim is tagged: **[checked]** = read on an official page today, **[secondary]** = blogs/forums only, **[my estimate]** = reasoning, not measured. Items from general knowledge with no source are marked **[background]**.

## 1. Upload to Peter's own YouTube channel

**Simplest honest path:** a Google Cloud project owned by Peter, a "Desktop app" OAuth client, the YouTube Data API v3, loopback sign-in once, then uploads with a stored refresh token. One person, one channel, so no company verification should be needed.

**Sign-in (installed app).** Google recommends the loopback flow for Windows desktop apps: the app listens on `http://127.0.0.1:<random port>`, opens the browser, gets the code back, and must use PKCE (S256). Client type must be "Desktop app". [checked: developers.google.com native-app guide]

**The 7-day trap.** While the OAuth consent screen is in "Testing" status, "Authorizations by a test user will expire seven days from the time of consent", and that includes offline refresh tokens. Up to 100 test users. [checked: Google Cloud help]
- Fix: press "Publish app" so status is "In production". A personal app then just shows the "unverified app" warning once; Peter clicks Advanced > continue. Google says verification is "especially" needed for sensitive/restricted scopes; the upload scope is sensitive, so the warning will appear. The 100-user cap is irrelevant for one user. [checked, but the page does not address personal use, so this reading is my inference]
- Production refresh tokens last until revoked, or are unused for about six months, or hit Google's per-user token cap. [secondary and background]
- Design consequence: the app must handle `invalid_grant` by showing one big "Sign in to YouTube again" key, never a failure.

**Private lock and audit (the key finding).** For years: videos uploaded via videos.insert from unverified API projects created after 28 July 2020 were forced to private until the project passed a compliance audit (the "YouTube API Services - Audit and Quota Extension Form"). The official revision history now has an entry dated **2 November 2026** saying videos from unverified projects "are no longer restricted", reversing the 2020 policy; the videos.insert page says privacy defaults to public if not set (some accounts may default private). [checked: revision history and videos.insert reference, fetched today]
- Caution: this is 10 days old. Several blog posts (including one dated August 2026) still describe the lock. One site cites a Google staff reply on 13 Oct 2026 that it "was recently lifted". [secondary] The fetch tool summarises pages, so Phase 2 should confirm the exact wording with one real test upload.
- If the lock still shows up in practice: upload as private, then Peter presses one button in YouTube Studio (Visibility > Public). Locked videos cannot be flipped by the API, but the owner changing visibility in Studio is a normal feature; some reports say a locked video cannot be made public at all and must be re-uploaded via the YouTube site. [secondary, conflicting; test it]
- Audit route, only if needed: submit the audit form (Google compliance review). Takes weeks; not worth it for one person.

**Quota.** Default 10,000 units/day for general endpoints. Since 1 June 2026 videos.insert has its own bucket: 100 calls/day, 1 unit each (the old 1,600-unit cost still appears on older pages). thumbnails.set = 50 units, playlistItems.insert = 50 units, from the 10,000 pool. Resets midnight Pacific. [checked: quota page, quota-audit page, revision history] Peter will never come near this.

**Resumable upload.** POST with `uploadType=resumable` and the JSON metadata, send `X-Upload-Content-Length/Type`, get a session URL in `Location`; PUT the file; if the link drops or a 500/502/503/504 appears, ask the session "bytes */TOTAL" (you get 308 plus a Range header), resume from the next byte; 404 means session expired, start over. Chunks (optional) must be multiples of 256 KB. Max file 256 GB. Plain `HttpWebRequest` in C# 5 can do this; no library needed. [checked]

**Metadata.** `snippet.title`, `snippet.description` (chapters go here as text), `status.privacyStatus` (set it explicitly), then a second call `thumbnails.set` (thumbnail limit was raised to 50 MB in Sept 2026) and `playlistItems.insert` to add to a playlist (e.g. one per series/season). [checked in revision history; thumbnail call may require the channel to be phone-verified, background]

**Alternative with no API at all:** the app opens the Videos\Paddock folder plus YouTube Studio's upload page, with title and description already on the clipboard. Costs Peter two extra steps and drag/drop, which is hard for him. API is better.

## 2. Trimming (cut out lap)

**Lossless (`-c copy`).** Instant (seconds; it is disk speed, [my estimate] 5-20 s for ~3-6 GB). But the cut can only start on a keyframe: ffmpeg snaps back to the nearest earlier keyframe, so the clip starts early by up to one GOP. [secondary, widely documented] HEVC adds nothing special beyond that; a GOP is whatever NVENC was told. Check with `ffprobe -skip_frame nokey -show_entries frame=pts_time`. If the recorder sets a keyframe every 1-2 s (common for NVENC), the out-lap trim error is 1-2 s early. For cutting out an out lap that is perfectly fine: start slightly early, never late. Audio can drift a few ms when keyframes differ; re-encode audio (AAC, cheap) to avoid that. [secondary]

**Accurate cut, "smart cut".** Re-encode only the first GOP and copy the rest, then join. Frame-exact start, takes seconds, but is fiddly to build. [secondary]

**Full NVENC re-encode.** `hevc_nvenc -preset p5` on an RTX 4080. No clean benchmark found for 1440p on a 4080 (forum figures: ~30-40 fps at 4K with heavy settings, 100+ fps at lighter settings; GPU often unstated). [secondary] [my estimate] 1440p at 60 fps, 20 min = 72,000 frames; at 150-300 fps that is about 4-8 min, and it costs quality (second generation encode) and fights the game for the encoder if Peter is driving.

**Recommendation:** stream copy, start at the keyframe at or before "out lap ends" (use the iRacing lap data the app already has), no re-encode. Nothing to wait for, no quality loss. Never cut the original until Peter confirms; write a new file or just store trim points and cut at upload time.

## 3. Commentary

**Recording the voice-over (simplest for Peter).** One Stream Deck key "COMMENTARY": the app plays the race in the replay/player, records the default microphone to a WAV (NAudio is not allowed; use `ffmpeg -f dshow -i audio="Mic"` or Windows' own capture) and the same key stops. Because recording starts when the video starts, the WAV lines up with time zero. Stop = auto mix.

**Mix with ducking (ffmpeg).** Game audio is lowered while he speaks, using `sidechaincompress` (game audio first input, voice as the key), then `amix=inputs=2:duration=longest` and a re-encode of audio only; video stays `-c:v copy`. Tune threshold/ratio/attack/release by ear; the examples online are starting points. [secondary: ffmpeg-cookbook, ffmpeg-user list; verify commands in Phase 2]
- Simpler alternative: no ducking, game audio at about -12 dB while the voice is on. Fewer failure modes.

**Local speech-to-text (whisper.cpp).** Use it for subtitles/description drafts of his own commentary, never for the race audio (engine noise). Models run from tiny (about 75 MB) up to large-v3 (about 3 GB in fp16, about 1.1-1.5 GB quantised); a 16 GB RTX 4080 holds large-v3 easily (VRAM 3-4 GB fp16). [background + secondary] No whisper.cpp number for a 4080 found. Tom's Hardware ranked the 4080 second of 18 GPUs (about 3,000 words/minute, original OpenAI Whisper). One 4070 report gives roughly 8x real-time for large-v3 on whisper.cpp CUDA (faster-whisper roughly 12x). [secondary] [my estimate] a 5-minute voice-over transcribes in well under a minute with the "small" or "medium" model on a 4080; "small" is plenty for clear speech from a close mic. Needs a download of the model (about 500 MB for small/medium): ask Peter first.

## 4. Highlights and chapters

**Chapters on YouTube.** In the description: first timestamp `0:00`, at least 3 timestamps in ascending order, each chapter at least 10 seconds. Manual chapters override automatic ones. [checked: YouTube help] Example: `0:00 Start`, `2:10 Lap 1`, `9:40 Pit stop`...

**How others make highlights.** NVIDIA Highlights/Instant Replay, Medal and Outplayed work from in-game event hooks (kills, wins) plus a rolling buffer, then tag the moment on a timeline. [background; vendor docs not fetched] For sim racing no such hook exists, but iRacing telemetry has the equivalents, so Paddock can mark them itself: green flag, start/first lap, incident count increases, position gained or lost, pit in/out, fastest lap, safety car/yellow, final lap, checkered flag. I did not find a credible source for how sim-racing YouTubers pick highlights beyond cutting by hand in an editor. [no evidence found]
- Use the same marker list for both chapters and optional "best moments" jump keys. Do not auto-cut a highlight reel in v1.

## 5. Title and description conventions (5 templates)

I could not retrieve real YouTube titles through search (results were articles and event pages). The pattern from Dave Cam's sets ("Zero to Hero - Week 9, Ferrari GT3 at Spa") confirms: series/week, car, track. [secondary] The templates below follow common practice [background] and fill from data the app already has:

1. `{Car} at {Track} | iRacing {Series} {Season} Week {Week}`
2. `P{Finish} from P{Start} | {Car} at {Track} | iRacing`
3. `{Series}: {Track}, {Car} - P{Finish}, {iRatingChange} iRating, {SafetyRatingChange} SR`
4. `{Track} {Car} Race Replay | {Date} | {Series}`
5. `Full Race: {Series} at {Track} ({Car}) - Class P{ClassFinish}`

Description: first line = title facts; then Series / Track / Car / Date / Start / Finish / Best lap / iRating change; then chapters; then fixed footer (gear, channel links). Default privacy: private, then Peter presses Publish.
Tip: trim "iRacing" to once; keep titles under about 70 characters so they do not cut off in search. [background]

## 6. Library UX

Sources compared: Medal, Steam recordings, NVIDIA app gallery, Plex, Google Photos. I did not fetch their docs; this part is **[background] design judgement, not tested evidence**.
- **Grouping:** by session type then date (Today, This week, Older), a card per race with track, car, finish; Plex/Photos use date headers and big thumbnails.
- **Multi-select:** Google Photos and Medal use a tick on the thumbnail; once one is ticked the whole screen becomes a selection mode with a bar "3 selected - Upload / Delete / Cancel". Shift-click for ranges on mouse.
- **Delete:** Google Photos uses Trash with 30-60 days and an "undo" toast; no confirm dialog. Windows Recycle Bin is the same. Confirm dialogs ("Are you sure?") get clicked through and are worse for a one-press user.
- **Storage gauge:** a single bar "412 GB used by races, 280 GB free, about 38 more races" and a one-key "free up space" suggestion (oldest already-uploaded races first).
- **Retention:** keep until uploaded plus N days; never auto-delete something never uploaded or marked Keep.
- **For mouse + Stream Deck:** the deck shows 4-6 race cards per page with big NEXT/PREV; one key tick/untick; fixed bottom keys UPLOAD SELECTED, DELETE SELECTED (to Trash), SELECT ALL OLD, DONE. Mouse screen mirrors the same state exactly.

## Recommended design for Races / Library

1. Rename "Vault" to **Races**. One list, newest first, one card per race (thumbnail, track, car, finish, length, size, uploaded badge).
2. A card has a single obvious state line: "Not uploaded", "Uploading 62%", "On YouTube (private)", "On YouTube (public)".
3. Tick any number of cards; a bar appears with only three actions: UPLOAD, DELETE, CANCEL. Same on the Stream Deck.
4. Delete moves files to a Paddock trash folder (kept 14 days) with a top "Deleted 3 races - UNDO" toast and no confirm dialog; the trash empties itself. Permanent delete only via "free up space".
5. Storage bar at top, with "Clear the oldest uploaded races" as one key when under 15% free.
6. Retention default: keep everything until it has been uploaded, then offer to delete after 30 days; never auto-delete un-uploaded or Kept races.
7. One-time "Connect YouTube" key: Google Cloud project owned by Peter, Desktop client, loopback + PKCE, status set to In production to avoid the 7-day token death; on `invalid_grant` show one big "Sign in again" key.
8. Upload with the resumable protocol, survives sleep/network drops, and is paused while he is driving (existing rule 1); show a progress bar.
9. Upload as **private**, with title/description filled in. After the 2 Nov 2026 policy change it should be possible to publish directly; verify with one test upload in Phase 2 and keep the "Make public" button ("PUBLISH" opens Studio at that video) as a fallback.
10. Title templates: 5 presets above, chosen once in Settings, filled from session data; Peter never types. Chapters are generated from flags, pit stops, incidents and written into the description starting `0:00` (min 3, each at least 10 s).
11. Auto-trim: stream copy, start at the keyframe before the out lap ends, so no quality loss and no waiting. Original stays untouched until upload succeeds.
12. Commentary: one COMMENT key records the microphone while the replay plays, one press stops, auto-mix with ducking into a new copy (video copied, audio re-encoded). Optional later: whisper.cpp "small" for a text draft of the description (download needs Peter's yes).
13. Each race also shows its markers (start, incidents, pits, best lap, finish) so a jump key takes him to the moment to talk over.
14. Test plan for Phase 2: one real private upload of a short clip, token expiry handling, resumable upload with network cut, keyframe check on a real recording, ducking mix listened to, quota/privacy behaviour logged.

## Links

- YouTube API revision history (2 Nov 2026 reversal, quota buckets): https://developers.google.com/youtube/v3/revision_history
- videos.insert reference: https://developers.google.com/youtube/v3/docs/videos/insert
- Quota and compliance audits: https://developers.google.com/youtube/v3/guides/quota_and_compliance_audits
- Quota costs: https://developers.google.com/youtube/v3/determine_quota_cost
- Resumable upload protocol: https://developers.google.com/youtube/v3/guides/using_resumable_upload_protocol
- OAuth for installed apps: https://developers.google.com/identity/protocols/oauth2/native-app
- Testing-status 7-day expiry: https://support.google.com/cloud/answer/15549945
- YouTube chapters: https://support.google.com/youtube/answer/9884579
- ffmpeg audio ducking cookbook (third party): https://ffmpeg-cookbook.pages.dev/en/articles/audio-ducking/
- Stream-copy keyframe discussion: https://forum.videohelp.com/threads/402038-Clipping-Video-Using-FFMPEG-and-KeyFrames-Need-More-KeyFrames
- Whisper GPU benchmark (Tom's Hardware): https://www.tomshardware.com/news/whisper-audio-transcription-gpus-benchmarked
- Private-lock reports (secondary): https://singhamandeep.com/?p=1462 and https://www.ayrshare.com/solutions/google-api-error-403-unverified-app-how-to-fix-the-audit-pipeline/
- Dave Cam title pattern: https://traxion.gg/dave-cams-zero-to-hero-week-9-ferrari-gt3-at-spa/
