# R1 - deep review of PADDOCK as it exists (brain model)

You are a principal engineer AND a product designer for professional motorsport software (Cosworth Pi Toolbox Ultra,
MoTeC i2 Pro, McLaren ATLAS, F1 TV graphics). Review the PADDOCK code below with brutal honesty. No praise padding.

## Who it is for
Peter races iRacing on a dedicated rig (three 2560x1440 race screens, a 1920x1080 "top screen" above, Stream Deck XL,
iPhone). He is disabled: everything must be one press on the Stream Deck or automatic. He wants ONE premium super app
(black/gold broadcast look, no filler words, real assets only) that brings together everything around his racing:
- start / control the rig and iRacing in one press (Stream Deck main control; voice later)
- live dashboard + a 4th-screen "TV view" for people in the room while he races (other perspectives + telemetry)
- after each session: a LOT of data - performance, stats, competition, drill-down, video analysis, track data - as deep
  as Cosworth Pi Toolbox Ultra (which he has free with iRacing and wants integrated in a beautiful harness)
- video recording of his sessions (auto + save button, must not fill his disk) and sharing (YouTube, iMessage, with
  optional data overlay)
- the same analysis on the iPhone.
He tested today's build and was very disappointed: QUIT didn't work, the TV view was a fake map instead of race
footage, Vault and Performance look the same, Cosworth is a hidden key, no video of his session, the analysis is
broad but shallow.

## What to deliver (Markdown, structured, specific - cite file names and functions)
1. **Module inventory**: every module/page/endpoint you see, one line each: what it does, who uses it, verdict
   KEEP / FIX / REWRITE / DELETE, and why.
2. **Product gaps vs Peter's goals**: for each goal above, what exists, what is missing, what is wrong.
3. **Depth gaps vs Pi Toolbox Ultra / MoTeC i2 Pro**: concrete missing analysis capabilities, in priority order.
4. **UX problems**: confusing, duplicated (e.g. Vault vs Performance), dead or hidden features; navigation model.
5. **Bugs and risks**: real defects you can see in the code (with file + function), fragile areas, things likely to
   break in real sessions, safety risks to iRacing or his PC.
6. **Architecture**: is irdash (C# HttpListener server + plain JS pages) a sound base? What to restructure; what to
   delete; data model for sessions/laps/video; how the phone and top screen should share code.
7. **Top 15 changes** that would most improve Peter's experience, each with effort (S/M/L).
Be concrete. Do not invent features that are not in the code; say "not found" when you cannot see something.
If the code files below are missing or empty, answer only "NO CODE RECEIVED" and stop.
Every claim about the code must name the file and the function/element it comes from.
