# 07 - Design research (phase 1, evidence only)

Date: 2026-11-12. Tools: web search worked; page fetch worked on some pages (Elgato, It's Nice That, MotorsportBroadcasting) and failed on others (NewscastStudio returned 403). No downloads. Anything marked **[mine]** is my own reasoning or prior knowledge, not something I verified in a source. Anything marked **[unverified]** came from a weak source.

## 1. What the evidence says

### 1.1 Broadcast motorsport graphics
- **F1 (2018 Liberty package, Drive Studio).** The brief was "man versus machine", done in a 3D style that suits the sport's technical side. The opening sting was about twice as long as the old one and cut to a new theme by Brian Tyler; its fast pace was meant to introduce the drivers to casual fans. A fan critic complained the package broke the rule of one consistent font set across the whole look. Lesson: one typeface family, used everywhere, is a rule people notice when you break it. I could not verify the exact fonts or hex colours (the detailed Q&A page blocked me). [mine: F1 uses a custom "Formula 1" type family and a red/black/white core with white and a single accent for timing; confirm before relying on it.]
- **Formula E (DixonBaxi, 2018; MOX rebrand announced 2026).** Chevron is the one repeated shape. Bold white numerals for stats, bold cyan labels, dark grey panels. Key motion idea: graphics are "discreet at times to show the race action in full, then filled with data when things hot up". Name cards slide in as the camera moves. A dedicated sound suite (String & Tins) supports the graphics. The 2026 refresh was built around a bespoke typeface and "equipment, not badge" thinking.
- **WEC / Le Mans.** The 2019 package (Promotheus) was rebuilt around classes: each class has its own identity, its own interval, even its own replay wipe, and per-class clocks. Split screens are used sparingly because rapid switching hurts understanding. WEC relaunched all graphics from scratch in July 2025 after five years, stating the aim as "easier to understand". Le Mans live timing uses one colour code per class on the car number. Lesson: colour carries meaning (class), not decoration.
- **Lights out.** The F1 start is five red lights, one per second, then all go out. The interval is fixed in the rules; the hold before lights-out is random so nobody can time it. In 2026 a five second pre-sequence (blue panels) was added in Melbourne. Lesson for us: the most dramatic moment in motorsport is five identical lights, a silence, then darkness. No explosion needed.

### 1.2 Ambient "home" screens
- **Porsche (Taycan and later).** Cockpit designed from scratch as all-digital, inspired by the clean 1963 911 dash. Reviewers praise restraint: "less is more". Analog controls kept alongside the digital. Porsche's newer welcome animation uses real-time 3D.
- **Mercedes MBUX.** Their designer frames every animation, transition and icon as part of a "digital signature". Big glass, brand-expressive. It is the busier of the two; Porsche is the better model for us.
- **Apple TV (tvOS).** Focus is shown by subtle depth/parallax that Apple says should be "almost unnoticeable"; leave safe-area margin because layers get cropped; for ten-foot viewing, "when in doubt, go larger" and avoid thin fonts and hairlines (the last two points are from secondary summaries **[unverified]**).
- **Watch faces (chronograph principles, retailer/journal sources, so treat as general).** Time first, then complications. Contrast between hands and dial. Subdials large enough to read and few enough not to clutter. Every extra logo or line of text takes surface from the hands, so a good face leaves room empty. Test at real size and arm's length, not zoomed on a monitor. This maps straight to our clock: one big dial, at most two small sub-readouts.
- **Smart-home wall displays and Steam Big Picture / Nintendo home:** my searches did not return usable sources for these. [mine: both rely on one large focused tile, a calm dark background, and full-bleed photography; I have not verified this.]

### 1.3 Schedules
- Official **iRacing Companion** app: upcoming races, filter by series and licence, session times, reminders.
- Community tools: **iRacePlan** (week planner, converts to local time, Discord), **StartLight Racing Widget** (home-screen widget showing your series this week plus a live countdown to the next green flag), **SimOS Hub** (lock-screen next-race countdown), **iMarshal** (upcoming races and alerts), plus community spreadsheets and boxthislap.org season guides.
- Pattern across all of them: a short list of *my* series, one big countdown to the next race, times in local timezone, reminders. Nobody wins by showing the whole catalogue. I did not get a usable source for the F1 app weekend schedule.

### 1.4 Start-up sequences
- Evidence on sound is thin. The Mac chime was designed to give relief that the hardware passed its self-test. Windows 95 (Brian Eno) was about six seconds; XP about three (these durations come from descriptive sources, not a standard). Windows 10/11 ship a startup sound but keep it off by default. No published guideline gives a target length.
- **[mine]** Good openers I know of work in three beats: a quiet anticipation (dark, one element), a build (a few elements arrive in rhythm), and a release (the final state locks in with one clean accent). Under about 6 to 8 seconds, and skippable by any key press.

### 1.5 Stream Deck keys
- Elgato's icon-pack docs: images must be **144 x 144 px**; SVG, PNG or JPEG static; GIF or WEBP animated; no low-resolution images or screenshots. Plugin guidelines: when you can only supply one image, give the higher-DPI one; "clear, simple image that is easily readable at smaller sizes". Help centre: 72 x 72 minimum, square.
- XL native key size is 96 x 96 according to a third-party guide **[unverified]**.
- Community advice: bold shapes on a solid background beat fine detail; white line icons on dark read well; avoid tiny detail. A high-contrast icon pack exists on RaceDepartment.

## 2. Design-system brief (proposal)

**Principle.** A premium timing wall, not a gaming dashboard: black, one metal accent, one typeface family, lots of empty space, real photographs, and motion that is slow and certain.

### Type scale (top screen 1920x1080, read at about 1 m) [mine; test on the real screen]
Rule: nothing smaller than 26 px. One family with a condensed bold for numerals and labels, a regular weight for sentences. No thin weights, no hairline strokes under 2 px.

| Role | Size | Use |
|---|---|---|
| Hero numerals | 220-280 px | clock digits / countdown |
| Display | 96 px | next race name |
| Title | 56 px | section headings |
| Body | 36 px | schedule rows |
| Label | 26 px, caps, +8% tracking | small headers, units |

Numerals are tabular (fixed width) so countdowns do not jitter.

### Palette (3 colours on black, plus one status exception)
1. **Black** `#050505` base, with panels at `#0E0E0E` (surface, not a fourth colour).
2. **Gold** `#C9A24B` accent: the clock hands' tip, active item, key numerals. Used on under 10 percent of the screen.
3. **Warm white** `#F2EEE4` for all text and the dial.
- Grey text is warm white at 55 percent opacity, not a new colour.
- Exception: real flag colours appear only when a real flag is shown (consistent with the existing flag rule). Class colours only inside a class chip.
- Never gradients on text, never glow on more than one element at a time.

### Grid
- 12 columns, 96 px outer margin (safe area), 24 px gutter, 8 px base unit. Left-aligned text; one hero object centred or on a strong third.
- Centre column (about 720 px wide) is the clock; left column "now/next"; right column "my races". Max three groups on screen.

### Motion
- Easing: slow-in, fast-out curves only; durations 400-700 ms for entrances, 200 ms for state changes. No bounce, no spin, no wipes with logos.
- Elements enter in a staggered order (120 ms apart), never all at once, and move at most 24 px.
- Idle: only the second hand, a slow photo cross-fade (very slow, per the owner's gallery preference), and a once-a-minute gold sweep. Everything else is still.
- Information escalates as the session nears (the Formula E idea): calm and sparse when idle, denser and louder only close to a start.

### Photography
- Real photographs only (no home-made drawings of cars), full-bleed, darkened to a flat 60-70 percent black overlay so text always passes contrast.
- Consistent grade: warm, slightly desaturated, high contrast. One caption line, no branding.
- Photo changes in pairs, every 120 s, cross-fade 3 s.

### Stream Deck keys (96 px native, author at 144)
- One white or gold glyph, 60-65 percent of the key height, centred, on solid black; one label of at most 8 characters in condensed bold at 20 px or larger on the 96 px render; no photos, no gradients, no screenshots; gold = the action Peter most likely wants.

## 3. Five concrete ideas, each tied to a reference

1. **Five-lights start-up (F1 start procedure).** Black screen. Five small gold lights appear left to right, one per second, with a soft low tone each. Hold one beat of silence. All lights vanish, and the clock face and photo fade up with the second hand already sweeping. Total about 7 s, any key skips. Ties to the lights-out sequence. Avoids cheese because nothing explodes.
2. **Hand-by-hand clock build (watch-face principles; Porsche welcome restraint).** Dial ticks around one at a time (index marks drawing in), then the hour and minute hands settle, then the gold seconds hand drops in. The photo stays dark until the clock is complete. Ties to "hours and minutes first, complications after".
3. **HOME: one clock, three zones (chronograph hierarchy; tvOS single focus).** Centre dial about 720 px, with at most two small readouts (session time left, next race countdown). Left: now/next. Right: my races. Everything else is empty on purpose. Ties to "a good face leaves room free" and the large-type advice for ten-foot viewing.
4. **HOME schedule as a short personal list (StartLight, iRacePlan, iRacing Companion).** Only the series Peter races, in his local time, with one big "NEXT GREEN FLAG in 02:14:09" countdown and a gold marker on the one he is entered in. Rows sit at 36 px; past rows fade out. Ties to what every successful iRacing planner does.
5. **Calm-to-busy escalation and class colour discipline (Formula E "discreet then data"; WEC class colours).** Idle HOME is nearly still. Within 30 minutes of a start the countdown grows and a gold ring closes around the clock. During a session, colour appears only for flags and class chips. Ties to both broadcast systems.

## 4. Gaps to close before building
- Exact fonts and hex values of F1 / WEC / Formula E packages could not be verified; do not copy, choose our own family.
- No usable sources found for smart-home displays, Steam Big Picture, or F1 app schedule.
- Type sizes and the 96 px key size should be checked on the real screen and the real XL before they are locked.

## Links
- F1 2018 plan, Bratches: https://www.motorsport.com/f1/news/bratches-tv-coverage-revamped-2018-1009385/
- F1 2018 graphics analysis and poll: https://motorsportbroadcasting.com/2018/03/25/poll-which-f1-graphics-set-do-you-prefer-2/
- Drive Studio Q&A (blocked, 403): https://www.newscaststudio.com/2018/11/02/formula-one-broadcast-design/
- Formula E rebrand (Prophet, DixonBaxi): https://itsnicethat.com/news/formula-e-rebrand-prophet-dixonbaxi-graphic-design-230118
- Formula E MOX 2026: https://www.itsnicethat.com/articles/mox-formula-e-graphic-design-project-011026
- Formula E opening titles (Maxon): https://www.maxon.net/en/article/creating-the-cg-opening-titles-for-formula-es-ninth-season
- WEC graphics 2019: https://motorsportbroadcasting.com/2019/09/30/a-year-in-the-making-the-development-of-wecs-new-graphics-package/
- WEC new TV graphics 2025: https://www.fiawec.com/en/news/new-tv-graphics-to-revolutionise-fia-wec-viewing-experience/8398
- F1 start lights: https://flowracers.com/blog/how-f1-start-lights-work/
- F1 2026 Melbourne start procedure: https://www.news.gp/en/modified-start-procedure-to-be-used-in-melbourne-for-the-australian-grand-prix
- Porsche digital cockpit: https://www.thedrive.com/news/why-porsches-digital-gauges-are-better-than-everyone-elses
- Porsche screens purposeful: https://insideevs.com/news/728607/porsche-small-infotainment-screens-purposeful/
- Car design news, screens and tactility: https://www.cardesignnews.com/ux/the-future-of-screens-balancing-tech-and-tactility/480214
- Apple HIG focus and selection: https://developer.apple.com/design/human-interface-guidelines/focus-and-selection.md
- tvOS HIG summary: https://github.com/BasThomas/tvOS-guidelines
- Chronograph dial hierarchy: https://definewatches.com.au/the-watch-journal/articles/the-subdial-story-how-chronographs-measure-more/
- Watch legibility (Mondaine): https://eu.mondaine.com/blogs/news/was-eine-uhr-wirklich-gut-ablesbar-macht
- Watch dials form vs function: https://www.watchprosite.com/digest/watch-dials-form-function-design-discussion/
- iRacing Companion: https://www.iracing.com/?p=260806
- iRacePlan: https://iraceplan.com
- StartLight widget: https://mwm.ai/apps/startlight-racing-widget/6757087743
- boxthislap planner roundup: https://boxthislap.org/iracing-best-apps-for-planning-your-season-2/
- Startup sound history: https://www.therevolverclub.com/blogs/the-revolver-club/the-story-of-apples-iconic-start-up-sound
- Elgato icon guidelines: https://docs.elgato.com/guidelines/stream-deck/icons
- Elgato plugin images and layouts: https://docs.elgato.com/guidelines/streamdeck/plugins/images-and-layouts
- Elgato help, key icons: https://help.elgato.com/hc/articles/360028237271-Elgato-Stream-Deck-Customizing-Key-Icons
- Stream Deck icon sizes per model (third party): https://sunbeamtech.com/hardware-guides/stream-deck-icons/
- High-contrast Stream Deck icons (RaceDepartment): https://www.racedepartment.com/downloads/high-contrast-stream-deck-icons.36516/
