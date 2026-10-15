# HOME v3 layout spec (for home.js / home.css, plain HTML/CSS/JS)

Mockup: `home-v3.html` (states via `?state=normal|live|norace|stale|offline|recfail|first|long`), screenshots `home-v3-<state>.png`, re-render with `shoot.ps1`. The mockup's JS is the content logic; copy it, do not reinvent it.

## Canvas and grid
1920 x 1080. Margins 96 px. 12 columns of 122 px, 24 px gutters: column n starts at `96 + (n-1) * 146`. Three bands, hairlines between (`left 96, right 96, 1 px, var(--hair)`):

| Band | y | Content |
|---|---|---|
| Top line | 40 to 76 | wordmark, nav, date, clock |
| A drive | 128 to 440 | the one button, his car, READY panel |
| hairline | 476 | |
| B | 512 to 748 | next race (cols 1-7), last outing + this week (cols 8-12) |
| hairline | 784 | |
| C watch | 820 to 1040 | real-world events, three columns |

Remove: the hero photo and its credit (`#homeHero`, `#heroImg`, `#heroCredit`, `.hero` CSS, the `hero` field is ignored), `#homePbs`, `#homeCareer`, `.idle-foot` status line (its facts move into the READY panel), the `homeIn` animations are optional (keep at most the one fade).

## Tokens
Colours from `theme.css`: `--bg #060606`, `--text #f4f1ea` (ink), `--muted #8d8a82`, `--dim #5d5a54`, `--hairline rgba(244,241,234,.12)`, `--gold #f2c230`, `--gain #2fe07a` (ok dot only), `--loss #ff5a4d` (failure only). Add `--amber #ffb21e` (stale / warning, already used by `.foot-phone.ask`).
Background: `radial-gradient(80% 70% at 30% 20%, #0c0c0b, #070707 55%, #040404)`.
Font: Bahnschrift stack from theme.css, `font-variant-numeric: tabular-nums` on body.

Type scale (nothing else): glance 56 px; read 30 px; body 26 px; label 20 px uppercase, tracking .24em, muted; tiny 16 px uppercase, dim, **only** for the source-domain line. Nav 22 px.

Colour meaning: gold = the one button and his car number only. Amber = stale data, app off, disk low, not owned, time TBC. Red = recording failed. Green = the READY/LIVE dot and the app chips' dots. Unknown value = `—` (U+2014), never 0. Middle dot `·` (U+00B7) is the only separator. Dates absolute: `Thu 15 Oct`. Times `1:15 PM`, zone only on the clock and the race start (`ET`).

## Top line (`.idle-top`)
Flex, `left 96 right 96 top 40 height 36`, gap 48. `PADDOCK` 24 px 600 tracking .5em ink, `margin-right:auto`. `#idleSessions` plus Vault and Performance links 22 px tracking .26em `rgba(244,241,234,.6)`. `#idleDate` 26 px muted = `Thu 15 Oct` (New York). `#idleClock` 26 px ink = `12:55 PM ET` (`Home.nyTime` without the zone name, plus ` ET`; if the lead prefers EDT/EST keep `timeZoneName:'short'`).

## Band A
**`#homeNext` (the one button)**: `left 96 top 128 width 706 height 214`, radius 8, padding 0 40, gold gradient `#f6cd4c -> #e2b42a`, text `#0d0b05`, arrow svg 44 px right. Label `<b>` 56 px 600 uppercase tracking .12em; sub `<span>` 30 px, 2-line clamp, max-width 560. States (same decision order as `Home.next()`):
- iRacing UI not ok -> `RIG ON` / `iRacing UI off`
- sim live -> `GET IN` / `<car> · <track>`
- last drive known -> `LAST DRIVE` / `<car> · <track>`
- else -> `START` (no sub)
- busy -> label `STARTING`, class `.busy` (desaturated `#3a3324`, text `#b9ad8a`); failed pick -> sub `Car not chosen` for 6 s (existing logic).

**`#homeDriver` (secondary identity)**: `left 96 top 370 width 706`, one baseline row: number 30 px 600 gold, name 30 px ink, `Licence C 2.54 · 1308 iR` 26 px muted. Hidden when there is no car image (first state), because the name then takes the image slot.

**Car image** (new node, e.g. `#homeCar`): `left 826 top 128`, 480 x 270 exactly (the asset's native size; never scale up), radius 6, 1 px border `rgba(244,241,234,.22)`, `filter: brightness(.9) contrast(1.04)`. Source `/paddock/cars/<me.path>.jpg` via `PCarPic` as today, at `w: 480`. No image for that path -> the slot shows `64 Peter Adamis` at 56 px (number gold) and the licence line at 26 px muted; no drawing, no stock photo.

**READY panel (`#idleRig`)**: `left 1410 top 128 width 414`.
- Head row, 64 px tall: 14 px dot + one word at 56 px weight 300 uppercase (40 px when longer than 9 characters). Word and dot colour: `READY` green dot, ink text; `LIVE` when sim is live (green dot with soft ring); otherwise the first problem, text in its colour: `iRACING UI OFF` / `OVERLAYS OFF` / `DISK LOW` amber, `RECORDING FAILED` red.
- Rows, 40 px each, hairline between, key 26 px muted left, value 26 px right, ellipsis:
  - `Recording`: from `/vault/recorder` (vault-recorder.json): `enabled:false` -> `Not available` muted; `gaveUp` or `capture.state=failed` -> `Failed · 41 GB free` red; `capture.state=recording` -> `On 0:40 · 333 GB` green; `off` -> `Off · 333 GB free` muted; `freeGb < minFreeGb` -> `Disk low · 41 GB free` amber; else `Ready · 333 GB free` ink.
  - `Phone`: from `/phone/qr`: not allowed -> `run tools\phone-allow.cmd` amber; no LAN -> `no home network` muted; else `2 paired` ink or `none paired` muted. The pairing square (`#homePhone`) is no longer on HOME; it moves behind the Phone row (press = show the square in the car-image slot) or stays on the deck add-on. [lead decides]
- App chips, 16 px under the rows, flex-wrap gap 6/26, 22 px muted: Stream Deck, iRacing UI, CrewChief, Overlays, each with an 8 px dot; an app that is not `ok` reads `<name> off` in amber with an amber dot. `Sim` is never a chip (off is normal between sessions; live shows in the head).

## Band B
**`#homeRace` (next race)**: `left 96 top 512 width 998`.
- Label 20 px `NEXT RACE`; when the schedule is older than 6 h append `· schedule as of Tue 13 Oct 9:11 AM` in amber.
- Row at +12: countdown 56 px weight 300 ink (`in 20 min`; `in 1 h 13` from 60 min; `starting` under 1 min; never gold), then 26 px muted `1:15 PM ET · every hour at :15 & :45`.
- Series 30 px 500 ink, 2-line clamp.
- `<car> · <track>` 26 px ink, 2-line clamp, then one trailing marker 20 px uppercase: `owned` muted, or `track not owned` / `car not owned` / `car and track not owned` amber.
- No `nextRace` -> label + `No race published` 30 px muted. PB and field median are not shown on HOME.

**`#homeLast` (last outing + this week)**: `left 1118 top 512 width 706`.
- Label `LAST OUTING · Thu 15 Oct`.
- Row at +12, 64 px: best lap 56 px weight 300 ink + `best lap` 26 px muted; `REVIEW` button right (`#homeReview`, 56 px tall, padding 0 30, 1 px border `rgba(244,241,234,.22)`, ink text 26 px tracking .22em, not gold; opens the Session Review as today).
- Detail 26 px ink, 2-line clamp: `Road America · Race · 4 laps · BMW Z4 GT3` (track, type, laps, short car).
- This week row: margin-top 22, hairline above, baseline flex: label `THIS WEEK`, then `3.7 h`, `84 laps`, `0 PBs` as 30 px numbers with 20 px unit labels, then `last week 7.5 h · 213 laps` 22 px muted right-aligned. `#homeWeek` can become this row (same id, moved inside).
- No last outing -> `—` at 56 px and `No drive recorded yet` 26 px muted; no week -> `—`.

## Band C `#homeWeekend`
`left 96 right 96 top 820 height 220`. Label row: `WATCH · REAL WORLD` + (stale: `· as of Tue 13 Oct 9:11 AM` amber) + source domains right-aligned at 16 px dim (`racetagger.cloud · jolpi.ca`).
Columns at +44: grid `560 560 560`, gap 24. Events grouped by `series + event`, first three groups by first session time. Per group:
- header 20 px: series left, date range right in dim (`16–17 Oct`, unspaced en dash);
- event name 30 px 500 ink, one line, ellipsis. Name rule: text after the last ` - ` if present (`...Endurance Cup - Portimão` -> `Portimão`), else the event name;
- three rows of 36 px, 26 px: the `Race` and the two sessions before it (no Race -> first three). Session name left, `Sat 1:00 PM` right (weekday + time, New York). Race row ink, others muted. `tbc` or no time -> `Sat · time TBC` amber. Never the word `Live`.
No events -> `No events published` 30 px muted. Empty feed with `fresh:false` -> amber `as of` only.

## Loading
Until `/home` answers: top line and hairlines only, button hidden (as today). Every value that is still unknown renders `—`; no spinners, no skeletons.

## Checks for the test (`tests/`)
Screenshot each state at 1920x1080 and assert: exactly one gold-filled element; no text box below 20 px except `.tiny`; no element overlaps another; Band C shows three rows per column with the Race row present; the long-name state has no clipped glyphs; copy audit passes (no em dash asides, no `you`, no `!` except inside iRacing series names).
