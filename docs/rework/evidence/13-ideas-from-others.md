# Ideas from other sim-racing rigs (research, 2026-11-13)

Method: web searches and a few page fetches (all worked; no downloads). Search summaries are not primary sources, so
anything marked "unverified" needs a check before we plan on it. Nothing here repeats items 1-37 of REWORK-LIST.md
except where I say "backs item N".

## What I found, by topic

### 1. Rig automation (SimHub, Stream Deck, Home Assistant, race-mode scripts)
- **SimHub can switch LED and matrix profiles by car** (it keys on car ID; older car-model profiles still work). I found
  no documented way to run an arbitrary action on car change, so per-car anything beyond lights is "build it
  ourselves" (irdash already sees the car).
- **iR2mqtt** is a Windows app that reads iRacing and publishes speed, RPM, fuel, incidents, all flags, start lights
  (ready/set/go) and a driving state (Driving / Spectating / Garage / Menu) over MQTT. A Home Assistant add-on turns
  these into sensors. Pit detection, flags and incidents sit behind the author's donation key. The author's own
  automations: a door light that shows "racing" vs "spectating", and a baby-monitor alert that notifies the partner
  mid-race. This is the closest thing the community has to "the room reacts to the sim". Paddock already has the same
  data in irdash, so we would copy the *ideas*, not the tool.
- **Stream Deck profiles for iRacing** (SideshowFX Pro Profiles with 53 live readouts, FlowKits PitDeck, StreamSpell,
  the free iRaceDeck plugin, Daniel Newman Racing control decks) all sell roughly the same thing: pit-stop keys, black-box
  keys, camera/replay keys, live telemetry on the keys, fuel +/- keys. Prices about $14-40. Peter's deck already covers
  these; the differentiator is that ours finishes whole jobs. The one thing I'd note: telemetry painted on keys
  (fuel laps left, position) is what buyers pay for.
- **Race-mode scripts**: iRacing's own support page now has a High CPU Usage Warning and says to close hogs, avoid
  Efficiency Mode and use a Performance power plan. RaceLab's Tools Manager "closes apps while driving" when the sim
  starts. Community guides stop Windows Update, Search and SysMain before sessions and set sim priority High (a claim of
  "97% fewer hard page faults" is self-reported, treat as unverified). Backs item 28; the new part is "restore
  afterwards" and a priority re-apply, since Windows resets it.

### 2. Immersion
- **Ambient lighting**: SimHub's Ambient Lights module drives Hue, WLED, Nanoleaf, Govee and addressable strips with a
  fixed colour, flag reaction, braking and event effects. Hue pairing is the common complaint (re-pair after
  reinstall). Peter already has two physical flag boxes, so a third light adds little for flags. The cheap win is a
  **room-light state**: dim/warm when idle, off during the race, full white when the race ends or in the garage.
- **Wind**: SimHub drives fans by speed. DIY (Arduino + motor shield) costs about 15-20 euro per fan or 120 pounds all in;
  Nitro Concepts Wind Box is about 43-50 pounds; AlphaSim about 200 euro; Clutch Kick about 300 dollars. Reliability
  evidence is anecdotal only (cheap boards that don't reach 100%). The Wind Box has a fan-stop when idle. For a
  one-press rig the risk is another box to fail, and Peter already has an AC. Medium value, not first.
- **Bass shakers / ButtKicker**: SimHub ShakeIt needs a dedicated sound card, goes through Windows audio (a vendor claims
  140-200 ms latency, unverified, vendor sells a rival), and iRacing exposes only one slip channel, so no per-corner
  effects. Peter owns a ButtKicker, so the question is only tuning (gear, kerbs, engine), not buying.
- **Sound cues**: Soundshift (shift beep), Jimmie Johnson spotter pack, Crew Chief. Free.

### 3. Pro and esports team setups
Public detail is thin. What is consistent: engineers sit apart with live data and talk to the driver by radio;
Penske used iRacing to practise driver-engineer communication; endurance teams (Red Bull's guide) prep about two weeks
out and want each driver to do two clean stints in practice. A general motorsport debrief method ends with **one next-
session plan: target corner, behaviour change, in-car cue, evidence to check afterwards**. That one is cheap to copy:
the post-race screen ends with a single sentence of focus, not a dashboard. Gap: I found no public photos of a driver
station layout worth copying.

### 4. Accessibility
- Team BRIT / eTeam BRIT: disabled drivers use the same radial hand controls as in the real car; their sim plan is a
  swap-in wheel and controls for sim centres. McGloin (FIA Disability commission president) had a Playseat modified to
  mirror her race car and has been working with Playseat on an accessible rig (early stage, no details). The-Race's
  article says the software side is the easy part: sims can be remapped (for example throttle to the left foot).
  Message: **hardware is bespoke per person; software remapping and one-press control is where products help.** That
  supports Paddock's direction. I found no tool built for a one-handed or press-limited user's *whole session flow*.
- **Voice**: Crew Chief has a long voice list (fuel: "how's my fuel", "how much fuel to the end"; pit: "do I have to
  pit", "what's the pitstop plan", iRacing "pitstop fuel to the end"; "spot / don't spot"; gaps on or off; "what's my
  incident count"; "how many laps to go"; "damage report"; "keep quiet / keep me informed"; "repeat last message").
  Peter runs Crew Chief already, so **turn on its speech recognition** costs nothing but a microphone and key setting.
  VoiceAttack (about 10 dollars, paid) has iRacing profiles: Digital Race Engineer (600+ commands incl. pit fuel/tyre
  changes), iRacingPitCrew, and a PitGirl plugin that talks to iRacing and OBS through the SDK instead of keystrokes.
  Windows Voice Access is built in, runs on-device, and lets you attach any key combination to a spoken phrase, but I
  found nothing about how well it works inside games (test before trusting). Backs item 32.

### 5. Streamer / YouTuber workflow
- OBS replay buffer plus a hotkey is the standard "clip that"; scripts (OBSAutoReplay, Smart Replays) react to the
  "replay saved" event to rename or move files; Replay Buffer Pro saves several clip lengths. Replay Director builds
  iRacing replay videos with leaderboard and fastest laps (source is a Google Doc; unverified). No off-the-shelf
  "result card plus title plus upload" exists, which is why Paddock's version has value. Backs items 9-12, 25, 26.

### 6. iRacing helpers worth copying
- **Companion app 3.0** (announced 2026-11-13; one source disagrees on the date): week-by-week series schedule,
  favourites for series/cars/tracks, reminders configured by steps, licences and stats. The **reminder** idea is the
  steal: a deck/phone nudge before a favourite series' next session.
- Free-app list (Coach Dave): Delta, Trading Paints, irFFB, Crew Chief, Soundshift, RaceLab (iRating predicted gain),
  iOverlay (relatives, multiclass traffic, Twitch chat), SIMRacingApps (web HUD for a tablet), Kutu's browser apps (fuel
  calculator). The one Paddock lacks: **predicted iRating/safety-rating change during the race**.
- **Data API** (third-party docs): results by subsession, series/season schedules, member summary and recap, yearly
  stats, driver stats by category, chart data (iRating history), series race results. 900 s cache. I could not confirm
  SOF or race-guide field names (check members-ng.iracing.com/data). Requires Peter's iRacing login via OAuth, so
  it needs his one-time sign-in.

### 7. Health and comfort
- Sports-science evidence: cold fluid reduces core temperature rise and discomfort in a hot simulated race, and may
  help most people whose sweating is impaired; practical advice is 200-250 ml every 20-30 minutes; reset posture and
  grip every few laps. **I found nothing on pressure-sore care or seating for wheelchair users** in sim contexts; that
  needs a medical source and Peter's own routine, not a guess.
- Nobody I found automates breaks. Pit stops and caution periods are the natural moments, so a gentle on-screen "drink"
  nudge in a long caution or a red flag is the smart version.

## 30 ideas, ranked (value to Peter vs effort, best first inside each group)
Legend: [$] needs money, [HW] needs hardware, [Y] needs Peter's yes or sign-in. Effort S/M/L.

### Automatic (no press)
1. Race-mode PC: pause Windows Update, indexing, OneDrive; set sim priority and re-apply when Windows resets it; hand back after (S-M; backs 28)
2. Room state follows the sim: lights bright in garage, dim in menu, off in race, up at the chequered flag; AC pre-cools when a session is about to start (M; [HW] if no smart bulbs; Home Assistant optional)
3. Pre-race nudge from the schedule: deck and top screen light up 10 minutes before his next favourite race; Companion-style reminder to the phone (S-M; [Y] data API sign-in)
4. Auto start of everything before the race: apps up, overlays on, recorder armed, AC set, no keys (M; mostly done, check gaps)
5. Hydration nudge in cautions and red flags only, never mid-green (S)
6. Break nudge after a long block (say 90 minutes), "good time to stop" after the chequered flag (S)
7. Automatic post-race one-line focus ("lost 0.4 s in turn 3 braking; try the 100 m board") ending the debrief, from the data we already have (M; copies the debrief method)
8. Auto-stop of mic, spotter and race mode at the end of the race, and reset of overlays for the next session (S)
9. Door/room signal for family: "racing now" light outside the room (S; [HW] cheap bulb or LED)
10. Per-car profile on car change: lights, ButtKicker preset, overlay layout (M; SimHub car ID helps lights only)

### One press
11. "Share last race": card + title + upload, one press (L; backs 9, 25; Google audit limits apply, item C3)
12. Voice: turn on Crew Chief speech recognition (fuel, pit plan, gaps, "keep quiet", "repeat") (S; [HW] headset or desk mic, and a push-to-talk or always-listening choice)
13. Voice for the rig itself via Windows Voice Access mapped to key combinations ("start race mode", "record that") (M; test inside the sim first)
14. VoiceAttack with Digital Race Engineer for pit-fuel and tyre changes by voice (M; [$] about 10 dollars, needs a yes; some overlap with Paddock's own pit keys)
15. Panic key: one press to pause recording, spotter on, set everything safe (S)
16. "Next race" key: shows the race, joins it, loads the saved setup (M-L; UI-automation risk)
17. Phone pad: big-button remote on the phone for the same top-10 keys, for days the deck is out of reach (M; page exists)
18. Telemetry on keys: fuel laps left, position, gap ahead painted on deck keys during the race (M; what other profiles sell)

### Immersion
19. ButtKicker presets per car type and gentle idle, tuned once (S-M; no new cost)
20. Ambient room light matched to flag colour as a third display (M; [HW] Hue/WLED strip, about 30-80; low value because two flag boxes exist)
21. Wind fan by speed with idle-off (M; [HW][$] about 45-50 pounds ready-made; one more box to fail; AC already covers comfort)
22. Soundshift or equivalent shift beep when the car has no shift lights (S; free)
23. NASCAR-style spotter voice pack as an option (S; free, taste)

### Data
24. Predicted iRating and safety-rating change shown during and after the race (RaceLab idea; M; uses API or live SOF)
25. Season planner: which tracks and cars he owns vs the week's schedule; flags the best-fit series (M; [Y] API)
26. Progress sheet per track from the API results: iRating curve, finishing position vs start (M; backs 33)
27. Fuel and stint plan on the briefing screen, with "laps of fuel left" live (M; backs 24)
28. Strength-of-field and expected finish line in the briefing (S; [Y] API)
29. Incident and contact markers on the race timeline for the debrief video (M; backs 26)
30. Shareable race card to Discord, one press, same image as YouTube thumbnail (S-M; [Y] webhook URL from Peter)

## Honest take
Top three for Peter: 1 (quiet PC, no cost), 12 (turn on the Crew Chief voice he already has), 3 (reminders so he never
misses the race he wants). The expensive immersion items (wind, hue strips) are fun but the evidence says
reliability is anecdotal and he already has flags, shaker and AC; let Peter choose, not the list.

## Links
- SimHub release notes: https://www.simhubdash.com/simhub-6-5-5/
- SimHub ambient lights (forum): https://www.simhubdash.com/community-2/simhub-support/ambient-lights/
- Daniel Newman Racing ambient lights FAQ: https://danielnewmanracing.com/support/faq/ambient-lights-overview
- iR2mqtt for Home Assistant: https://community.home-assistant.io/t/ir2mqtt-bring-iracing-live-telemetry-to-home-assistant/901589
- SimHub wind sim: https://github.com/zegreatclan/SimHub/wiki/Arduino-ShakeIt-Wind-simulation
- Nitro Concepts Wind Box: https://www.overclockers.co.uk/nitro-concepts-immersion-wind-box/GAM-NIT-04478.html
- Dayton Audio ShakeIt guide: https://www.daytonaudio.com/images/resources/325-510--SAB-1060-SimHub-ShakeIt-Bass-Shaker-Guide.pdf
- iRacing pro profiles on Elgato marketplace: https://marketplace.elgato.com/product/iracing-pro-profiles-for-stream-deck-xl-ebc528ad-21d9-4061-8b6c-f24b6f84626a
- PitDeck: https://marketplace.elgato.com/product/iracing-pitdeck-profile-plugin-for-stream-deck-12799413-19c4-4bc6-82b9-5cf464a62e23
- Stream Deck for simracers (SimRacingCockpit): https://simracingcockpit.gg/stream-deck-for-simracers/
- The Race, FIA push for disabled esports: https://www.the-race.com/gaming/the-fias-push-to-open-esports-up-to-disabled-racers/
- eTeam BRIT (GTPlanet): https://gtplanet.net/meet-eteam-brit-the-sim-racing-squad-for-drivers-with-disabilities
- Team BRIT blog: https://teambrit.co.uk/blog/the-revolution-has-started/
- Crew Chief voice commands: https://tonywhitley.github.io/Help/VoiceRecognition_VoiceCommandsAll.html
- Digital Race Engineer: https://www.bsimracing.com/iracing-the-digital-race-engineer-tool-v2-0-released/
- iRacingPitCrew: https://github.com/samkatakouzinosracing/iRacingPitCrew
- Windows Voice Access shortcuts: https://support.microsoft.com/en-us/Accessibility/windows/voice-access/use-voice-to-create-voice-access-shortcuts
- iRacing Companion App 3.0: https://www.iracing.com/iracing-companion-app-3-0-launches-today/
- Coach Dave, 10 free iRacing apps: https://coachdaveacademy.com/tutorials/10-must-have-free-apps-for-iracing/
- iRacing Data API wrapper docs: https://allymurray.github.io/iracing-data-client/getting-started/introduction
- iRacing high CPU usage warning: https://support.iracing.com/support/solutions/articles/31000176739-high-cpu-usage-warning
- RaceLab Tools Manager: https://garage.racelab.app/docs/advanced-features/tools-manager
- OBS Smart Replays: https://obsproject.com/forum/resources/smart-replays.2039/
- Debrief method: https://paddocklink-docs.pages.dev/lms/race-car-engineering-and-operations/debrief-and-continuous-improvement/the-post-session-debrief/
- Red Bull endurance prep: https://www.redbull.com/ca-en/sim-racing-how-to-get-into-team-based-endurance-races
- Cold-fluid / cooling study: https://www.frontiersin.org/articles/10.3389/fspor.2025.1514963/full
- Sim cooling and hydration guide: https://simxpro.com/blogs/guides/cooling-your-sim-rig-fans-clothing-and-staying-consistent-in-long-sessions
