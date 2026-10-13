You are researching data sources for a Windows sim-racing app (no server, plain HTTP from C# 5, no API keys or accounts
if at all possible). Today is 2026-10-11. Answer in English markdown, concise, every claim with its source URL. Say
plainly when something is not found or uncertain; never invent URLs or formats.

## A. Upcoming iRacing races (official series) without the iRacing Data API
The user races mostly GT3 (IMSA iRacing Series, GT Sprint/GT3 Fanatec Challenge, GT Endurance, etc.). The members Data API
(members-ng.iracing.com/data) is not usable for this app. We already parse the season schedule PDF iRacing publishes.
1. Where does iRacing publish the 2026 Season 4 and 2027 Season 1 schedules (PDF URLs, forum posts, web pages)? When does
   2027 S1 start and when is its schedule normally published?
2. Race START TIMES per series: where are the session time patterns published (e.g. "every 2 hours at :15", "Sat 14:00
   GMT")? Is it in the PDF, on iracing.com series pages, or only in the members site?
3. Third-party free sources that list iRacing schedules with times: sites, calendars (ICS), community spreadsheets,
   GitHub projects (name, URL, update frequency, machine-readable?). Rate how reliable/maintained each is.
4. Special events (Daytona 24, Spa 24, Bathurst 12, Petit Le Mans, Sebring 12, Nürburgring 24) 2026-2027 dates on
   iRacing and where they are announced.

## B. Real-world racing calendars with SESSION times (practice, qualifying, race), machine-readable and free
Series: Formula 1, FIA WEC, IMSA WeatherTech, GT World Challenge Europe and America, Intercontinental GT Challenge,
Nürburgring Langstrecken-Serie / N24, DTM, Super GT, Supercars (Bathurst), IndyCar, MotoGP (nice to have).
For each: an official or well-maintained ICS/JSON feed or page (URL), whether it carries session times with time zones,
whether free without a key, how reliable. Mention aggregators that cover many series at once (e.g. motorsport calendar
ICS projects on GitHub, jolpica/ergast for F1, OpenF1, TheSportsDB) with their licence/usage terms and rate limits.
Also: free sources for a short race PREVIEW (official series news pages / RSS feeds) and for track images or logos that
may legally be shown in a private personal app.

## C. iRating / Safety Rating / results history without the Data API
Any free public source of a member's iRating/SR history and race results (e.g. iracingreports, iRacing stats sites,
the member's own CSV exports from the members site, Garage 61, the iRacing UI's local cache files). Which are usable for a
private personal app on his own PC without scraping behind a login he would have to give us?

End with a table: need | best source | format | key needed? | risk.
