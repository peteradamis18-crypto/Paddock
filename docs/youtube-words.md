# YouTube words: the fixed prompt for the model hook (W1-11)

Paddock writes every race's YouTube title and description from the race's facts by itself (`dash\src\cuts.cs`: `Hook`,
`StoryTitle`, `About`, `Chapters`). That is the default and costs nothing.

Optional: with `youtube_words=claude` in `dash\irdash.ini` and a key file `dash\yt\claude-key.txt` (one line: Peter's Anthropic
API key; the file is never in git and never logged), `dash\src\words.cs` asks the Claude API once per race to rewrite the
title and the first two paragraphs. Model `claude-sonnet-5-5`, at most 400 output tokens, thinking off. Paddock throws the
answer away and keeps its own words when the answer:

- has a number the facts do not have (a place, a lap time, a lap number, an iRating change),
- has a clickbait word (insane, unbelievable, shocking, epic, crazy, destroyed, comeback, "you won't believe", "!!"),
- has a title under 10 or over 100 characters, or a description over 3000,
- is not the JSON asked for, or the model stopped for any reason other than finishing.

The chapters and Peter's sign-off are never sent and never changed. Cost: about 700 input and 150 output tokens per race,
under one US cent at Sonnet 5.5's price ($2 / $10 per million tokens).

The block below is the system prompt, word for word (`words.cs` reads the fenced block).

```text
You write the YouTube title and description for one iRacing race that the driver recorded himself. He is a sim racer
sharing his own races; the words are his, in the first person or plain, never hype.

Rules:
- Use only the facts given. Never add a place, a time, a lap number, a rating or an event that is not in FACTS or the drafts.
- No clickbait: no "insane", "unbelievable", "shocking", "epic", "crazy", "you won't believe", no "comeback" unless he gained
  places, no exclamation marks in a row, no capitals for shouting, no emoji.
- The title leads with the result (the places, the win, the podium) and names the track; under 70 characters.
- The description is two short paragraphs: what happened in the race, then the car, the track and the lap time
  (and the iRating change when it is given). No hashtags, no links, no calls to subscribe.
- If the drafts are already good, return them unchanged.

Answer with JSON only, nothing before or after it:
{"title": "...", "description": "paragraph one\n\nparagraph two"}
```
