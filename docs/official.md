# Official racing schedule

Paddock reads iRacing's published season schedule so HOME / OFFICIAL can show weeks and cadence. It never registers, never writes iRacing's files, and never invents a start time.

## Source

- Season page: `https://www.iracing.com/seasons/2026-s4/` (or another `https://www.iracing.com/seasons/20xx-sN/` URL Peter puts in `data\official\profile.ini` as `scheduleurl`).
- If that page links to an iRacing `.pdf`, that PDF is the schedule.
- If there is no PDF link, the page's own HTML season table is parsed for the same fields (series, cars, week, track, cadence).
- No default URL. No download unless `autodownload=yes` in `profile.ini`. At most once per 24 hours. Never while the sim is busy. Cached under `data\official\source-cache\` (`season.pdf` / `season.html` / `asof.txt` with source URL and UTC `asOf`).
- 2027 Season 1 is not published: state is `not published`. A prior season is not treated as current.

## Use terms

iRacing's public season pages and PDFs are used only on this PC, for Peter, to display the published weeks and cadence. Paddock does not republish the PDF, does not scrape behind login, and does not use third-party calendars to fill missing iRacing data.

Fixtures in `data\official\fixtures\` are minimum text for tests (2026 S4 shape; 2027 S1 absent page). They are not a substitute for iRacing's file.

`official=0` in `dash\irdash.ini` keeps the live feature off until it is switched on after tests.

## Real-world calendars (H-05)

Published session times for the next 7 local days, cached in `data\official\realworld.json` with `asOf`. TBC when the source has no time. No live request until Peter says yes for that URL. Never while the sim is busy. `official=0` does not authorise these requests.

| Source | URL | Terms |
|---|---|---|
| F1 (Jolpica / OpenF1) | https://api.jolpi.ca/ergast/f1/current.json | Public, no key. Session times shown only on this PC. |
| IMSA | https://www.imsa.com/schedule/ | Public calendar page. Personal local display of published times. |
| FIA WEC | https://www.fiawec.com/en/calendar | Public calendar page. Personal local display of published times. |
| GT World Challenge Europe | https://www.gt-world-challenge-europe.com/calendar | Public calendar page. Personal local display of published times. |

TheSportsDB is not used (key + third-party logos). No logos or stand-in art.
