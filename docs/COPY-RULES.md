# COPY RULES - every word Peter sees (AU-1, 2026-10-11)

Peter: "get rid of all the filler AI text ... everything needs to mean something or else omit." Applies to every
string on a screen: top-screen pages, iPhone app, Stream Deck add-on (key labels and screen texts), overlays Paddock
draws, Rig Doctor and notice lines. Not to docs or code comments. **If unsure: cut.**

## Allowed
- Short labels and titles (`PERSONAL BESTS`, `Race weekend`).
- Numbers with units (`79.549`, `104 fps`, `-0.21 s`).
- State words (`LIVE`, `OFF`, `INVALID`, `PIT`, `SAVED`) and button verbs (`KEEP`, `SHARE`, `MAKE VIDEO`).
- A colour key only where a colour has to be decoded, terse: `PURPLE BEST · GREEN SESSION · YELLOW SLOWER`.
- An error or status line ONLY when it names an action he must take or a fact he needs
  (`Phone: run tools\phone-allow.cmd`, `Get out of the car first`).
- A data note with real numbers if one line, factual, no "you" (`6 clean laps · spread ±0.18 s`).
- iRacing's own words (channel names and descriptions from the SDK, series and track names).

## Cut
- Greetings, pleasantries, encouragement (`Good morning, Peter.`, `Ready when you are`, `Get in when you are ready`).
- Sentences that address him: `you`, `your`, `yours`, `you're`, `when you are ready`.
- How a number is computed or where data comes from (`outline from your own telemetry`, `Two line crossings sampled
  10 times a second...`, `the curve explains 19 % of the spread`, `Surface = mean over...`). Precision rules live in
  docs, not on the glass.
- Captions that restate what the chart shows; hints and tips; instructions for obvious controls.
- Relative-time chatter (`last time here yesterday`), decorative quotes, idle lines, motivational text.
- Filler subtitles under buttons that repeat the button.
- Anything whose removal loses no information.
- AI tells: em-dash asides, `Here's`, `Let's`, `just`, `simply`, `quietly`, `by itself`, `automatically`,
  title-case taglines, three-item rhetorical lists, emoji, exclamation marks, `insight`, `journey`, `story`.

## Layout follows the cut
When text goes, the block closes up: no empty box, no orphan heading, no half-filled row. Keep every number and
every needed control.

## How it is enforced
`tests\copy-audit-test.ps1` (in `tests\run-all.ps1`) opens every screen in headless Chrome with real data, reads
the visible text, and also scans every text string in the served pages, the phone app and the add-on. It fails on:

| Pattern | Catches |
|---|---|
| `you`, `your`, `yours`, `you're`, `you've`, `you'll` | sentences addressing him |
| `good morning/afternoon/evening`, `ready when`, `when you are`, `welcome` | greetings |
| `just`, `simply`, `quietly`, `by itself`, `automatically`, `let's`, `here's`, `insight`, `journey`, `story` | AI tells |
| `!`, em dash, a spaced en dash or ` - ` between two words, emoji | punctuation tells (a lone `–` is the empty-value mark and stays) |
| `outline from`, `from your own`, `sampled`, `explains`, `is the mean`, `worked out from`, `last time here` | how-computed / chatter |
| `Â`, `Ã` | a broken character: raw UTF-8 in a `.cs` file is read as ANSI. In C# write `·`, `−`, `°` ..., never the character itself |

Dates are absolute (`Sat 10 Oct`), never `yesterday` / `3 days ago`. The test also decodes the server's JSON replies as UTF-8 and fails on a broken character.

## Generated preview lines (H-06)
Facts only, from the supplied event fields and the matching official RSS item. Source URL and absolute date are attached by Paddock, not by the model. No advice, no filler. The banned-pattern list above is run on the complete generated text; any match rejects the whole line. Do not add a generated-string exception to the audit.

Add a pattern here AND in the test when a new tell shows up. Exceptions are listed in the test with a reason
(iRacing's SDK channel descriptions; demo-only data).

## Rig Doctor, notices, errors
One line: what is wrong, then the action (`Phone: run tools\phone-allow.cmd`). No apology, no "please", no "try again
in a moment" unless a retry is the only action.
