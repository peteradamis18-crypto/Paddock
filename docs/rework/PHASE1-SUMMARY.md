# Phase 1: what we have, what the best have, what's missing (2026-11-12)

Seven reports in `docs/rework/evidence/` (01 screens with 23 pictures in `current/`, 02 telemetry tools, 03 race
screen, 04 video, 05 stutter, 06 data audit, 07 design). Claude checked the key claims: the YouTube rule change on
Google's own pages, and the race-screen and Vault pictures by eye.

## The big picture
Paddock has many good parts underneath (recording, telemetry reading, the deck plumbing), but on top it is **eight doors
into the same drives** (Sessions, Vault, My Races, Review, Session Review, All the Data, Analysis, Performance), each
with its own look, its own names and mostly 11 to 14 px text. The rework is mainly **fewer, clearer doors with one look**.

## Findings by area

**Look (01, 07)**
- No shared design: gold, navy, plain or no headers, and different close buttons. HOME has about 14 blocks for one real
  job, plus a developer command on screen.
- The best tools are restrained: one colour used sparingly, big type, real photos and slow motion. Race planners all
  show a short personal list in local time with one big countdown.

**In-race screen (01, 03)**
- Today: two standings lists side by side, a crowded car panel, and nothing on damage or incidents of note.
- The pros (F1 timing, pit boards, irdashies, RaceLab): the flag loudest, one standings window with your row
  centred, one gap number per row, and about 8 big facts.
- Tyre pressure: iRacing has no live pressures while driving, only garage settings and data after a stop.
- Damage: the honest signal is the repair time left. We still have to confirm it updates while driving.
- Incidents: available.

**Videos (04)**
- **YouTube changed its rules on 2 Nov 2026** (checked on Google's revision history): home-made apps may now publish
  public videos. One-press upload is possible.
- One-time setup: a Google project with a sign-in key, then Peter signs in once. It must be set to "production", or
  the sign-in expires every 7 days.
- Up to 100 uploads a day.
- Out-lap trim takes seconds (no re-encode).
- Commentary: one key records the microphone while the replay plays, and the game sound dips under the voice.
- Chapters are made by themselves from flags, incidents, pit stops and the finish.
- Delete: tick to select, one DELETE, a few seconds of UNDO, and no "click again".

**Data (02, 06)**
- The raw numbers are real (iRacing's own .ibt file, the same file Cosworth reads).
- Coaching, "most to gain" and the benchmark are Paddock's own maths, never checked against Cosworth.
- The Cosworth button only opens the whole file in Cosworth's stock layout.
- Every serious tool is built around **your lap on top of a better lap, with a time-gap line, and a linked track map**,
  plus a short "where you lose time" list. "Best lap over time" is not a real view, so it goes.
- The same charts appear on three pages; the overlap goes.

**Stutter (05)**
- The freeze was **today, 09:28 Road Atlanta race (the one Peter won)**, between laps 9 and 10. The frame rate fell from
  112 to 24 for about 10 s. Only the picture stalled: physics, internet and disk were fine.
- The recorder was not the cause.
- Main suspect: Coach Dave Delta, whose CPU use jumped about 3x during the dip. Not proven, because Paddock only samples
  every 5 s.
- It started right as Peter set his best lap.
- The Performance page would not have flagged it, and afterwards reported "all fine" from an older session (a bug).
- Needed: a black box that records every second (frame rate, CPU, GPU, top programs, disk, Paddock's own events),
  with a fast mode when the frame rate drops.

**Bugs found on the way**
- Best lap 1:33.639 on My Races against 1:33.919 in Vault and Sessions for the same race.
- Session Review says "No complete lap" beside a 10-lap table.
- The tyre charts are still on a page.
- The RACES deck page has 27 empty keys.
- The Performance verdict used the wrong session.
- 01's dead list: the old v1 www files, debrief.js, workbench.js (135 KB).

## Proposed shape (for Peter to react to; this starts phase 2)
Four doors, same names on the deck and the screens:
1. **HOME**: clock, next race with a countdown, rig ready. Nothing else.
2. **RACES**: the library. Races first; practice and laps a tab away. Tick to select, YouTube in one press, trim,
   commentary, storage gauge. Replaces Vault, My Races and Sessions' list.
3. **REVIEW**: after every drive. Your lap against your best (or a reference), a time-gap line, a track map and the top
   3 places you lose time. "All the data" leads to one workbench. Replaces Coach, Session Review, Debrief and the
   analysis duplicates.
4. **RIG**: health and the performance black box, with one plain sentence after any stutter.

Plus the in-race screen rebuilt: one standings window and about 8 big facts.

## Decisions Peter needs to make
1. Are these four doors right, and are the names right?
2. Should Coach Dave Delta be closed for one race as a test, to see if the stutter goes? (It may also be the reference-lap
   tool he wants to keep.)
3. YouTube: OK to make the Google project? Claude guides him click by click, and he signs in himself.
4. Design direction: keep today's bright gold (#f2c230), or the softer broadcast gold the research suggests (#C9A24B)?
   Phase 2 will show both.
