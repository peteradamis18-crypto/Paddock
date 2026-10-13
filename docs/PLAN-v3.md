# PADDOCK v3 - the plan (lead, 2026-10-11 09:20)

Peter: "think through an amazing project plan for all first. You have $100 to make this incredible and hit every action
item, including an image of the Corvette on the homepage. And an iPhone app to control all of Paddock."

## Budget (real numbers)
- The account's weekly Claude allowance is used up until **2026-10-14 23:00 UTC**; everything now runs on **extra usage**,
  which stood at **$705.94** at 09:10 today. Peter's $100 = stop at **$805** on that meter. The lead checks it after
  every job (`get_usage`) and writes it in docs\tasks\log\oversight.md.
- Free capacity comes back soon: Claude's weekly reset (Wed 2026-10-14 evening) and Grok Build (Thu 2026-10-15).
  Work that is not needed today waits for those - same quality, no extra cost.
- Spend where taste decides the result (Fable: the look of Home and the phone app), Sonnet for well-specified building,
  Haiku for reading/research, the lead (Opus) only specs, reviews pictures and runs live checks - in few, batched steps.

## What Peter asked for, and where each one lands
| # | Peter's ask | Status 09:20 | Plan |
|---|---|---|---|
| 1 | Stream Deck redesign, VOL = game + SOUND page, RACE SETUP, all buttons used, organised | add-on 1.7 installed + MAIN rebuilt 09:13; keys 94/0, screens 194/0 | done; he tries them today |
| 2 | Reset car after a crash | built, tow tested 26/0 | his next crash = the real check |
| 3 | Analysis like Cosworth Pi Toolbox Pro or better | DRIVER, GRIP, BRAKING, TYRES, SUSPENSION, SPLITS, RACE, VIDEO, channel picker; CAREER building | **P3** adds the Pro tools Pi charges for |
| 4 | Video recording | on since 09:06 (~1.5 fps cost) | check after his first drive |
| 5 | Events list with PAUSE and JUMP (incl. iRacing's replay) | events + jump in the workbench; no replay jump | **P2** |
| 6 | SHARE via text / social / YouTube | not built | **P2** (+ phone share in **P1**) |
| 7 | Visuals of cars and teams | class-coloured plates only | **P4** real car pictures from iRacing's own files on this PC |
| 8 | Corvette on Paddock's home page | - | **P1** |
| 9 | iPhone app to control all of Paddock | - | **P1** |
| 10 | Car balance (understeer) | hidden: no sourced steering ratio | **P8** research; shown only with a sourced number |
| 11 | Cosworth working + shown | installed, OPEN IN COSWORTH key | **P9** 2-minute demo with Peter |
| 12 | AI races from the deck | AI last settings wiped by the lead's survey | **P6** rebuild (Peter said yes) + AI choices on RACE SETUP |
| 13 | Racing line on track | not working | **P7** find the cause, 30-second check with Peter |
| 14 | Grey Simucube Tuner box on the left screen | - | **P5** hide it automatically (Peter said yes) |
| 15 | MOST TO GAIN, small leftovers | - | **P5** |

## The pieces
**P1 Paddock Home + iPhone app (Fable, ~$30-40) - the flagship.**
- Home = the top screen when no session runs: a hero picture of HIS Corvette (from his own iRacing screenshots, or a
  hero shot the lead captures from a replay when he is away - never a picture taken from the web), his name and number,
  PB per track, last session, career numbers, one obvious button. Black/gold broadcast look, not cheesy.
- iPhone app = a web app served by irdash on the home Wi-Fi, added to the iPhone Home Screen (no App Store, no Mac).
  Pairing: scan a QR code on the top screen once. Screens: HOME (rig state + the one big button), DRIVE (every deck
  action), SOUND, RACE SETUP (search cars / tracks), ANALYSIS (review, laps, video, race, career on the phone), CLIPS
  (watch, save to Photos, share). Same irdeck commands as the deck - same safety rules (nothing while he drives that the
  deck would refuse). Windows must allow the phone in: a one-click `.cmd` (+ UNDO) for Peter, because Paddock never
  changes Windows security settings itself. Later option: Tailscale for use away from home and the iPhone share sheet
  (needs his own sign-in).

**P2 Share studio + replay jump (Sonnet, ~$8).** *P2 status 2026-10-11: built, deployed, tested (share-test 54/0, replay-jump-test 30/0) - docs\tasks\log\P2-share.md; the look and the first real jump wait for the lead.* After a session, his kept lap videos get a broadcast-style data overlay
(speed, gear, pedals, gap, mini-map) burned in with the graphics card (ffmpeg NVENC, nothing while he drives).
SHARE = one press: to the phone (Photos / Messages / YouTube app). Events in the workbench and RACE page jump iRacing's
own replay to that moment while that session's replay is loaded (SDK broadcast, no clicks).

**P3 Pro analysis tools (Sonnet, ~$8).** X/Y scatter with fit and a colour channel (Pi's most-used Pro display),
histogram of any channel, maths channels with plain names and the formula shown, CSV / Excel export of any lap.

**P4 Cars and teams (Haiku research ~$0.5, then Sonnet ~$4).** Research 09:40: iRacing keeps no car pictures as image
files on this PC (they are packed in .dat files - not to be unpacked). So: Paddock draws its own clean car silhouettes
per car type (GT3, GT4, prototype, open-wheel, stock car, road car) and paints each one in that driver's REAL livery
colours from iRacing's session data (CarDesignStr), with the car number and team name - in the RACE tower, CAREER and
Home. Facts from iRacing's data, no downloads, no licences.

**P5 Rig leftovers (Sonnet, ~$4).** Hide the Tuner's blank box (hide, never close - the wheel keeps working); MOST TO
GAIN on RACE SETUP; irdash's remaining MainWindowHandle uses -> the safe window finder.

**P6 AI races (lead + Sonnet, ~$5, only when Peter is away).** Rebuild iRacing's AI 'Last Settings' from his last AI
race's file, then map the remaining wizard steps through Last Settings (never New Race), then AI choices on RACE SETUP.

**P7 Racing line (Sonnet, ~$3).** Find why the line does not show; one 30-second check with Peter.

**P8 Car balance (Haiku, ~$0.5).** Look for a published steering ratio / wheelbase for his cars; shown only if sourced.

**P9 With Peter (lead, ~$1).** Cosworth demo; look at Home and the phone app together.

## Order
1. Now: P1 (Fable), P3 and P5 (Sonnet), P4/P8 research (Haiku) - separate files, one deploy at a time.
2. Then: P2, P4 build, P7. P6 when Peter is away from the PC. CAREER (running) lands first.
3. After Peter's first drive today: the lead checks video, race log, RACE button, Session Review, RESET CAR.
4. Anything left when the meter reaches $805 waits for the free reset (Wed) / Grok (Thu).

## Rules for every builder (unchanged)
CLAUDE.md rules 1-8; tests in tests\ with guard.ps1; pictures reviewed by the lead before anything counts as done;
facts only (no invented insights); one obvious button per screen; plain words.
