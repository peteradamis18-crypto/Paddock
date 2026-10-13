# HOME review gate (DS-1, builder's own critique; the lead adds the independent one)

Pictures: `tests\shots\home.png` (real data, 1920x1080), `home-states-nopb.png`, `home-states-longtrack.png`, `home-states-phone.png`,
`home-states-starting.png`. The design mock (same code as the live page, real data captured from irdash) is `docs\design\home-new.html`.
The rejected version is gone; its picture is described in HOME-brief.md.

## 1. Critique against three references (named in the brief; described, not downloaded)

**F1 TV / Formula 1 app driver page.** What it does: one driver, one big number, name in two weights, team line, a single row of
stats under it, the portrait bleeding off the right edge into black. What we match: the number (gold, 88 px, condensed) and the name
(88 px light) are one line with a hairline between them; the car line and the facts row sit on a grid; the picture bleeds off the right
and top edges and dissolves into black on the left, so there is no panel. What we do not match: F1 uses a portrait of the person; we
have a car photo, so the "face" is the car and the lit nose is the focal point. Weak spot: F1 stats are 3 to 4 big numbers; ours is
five groups (3 bests, career, last session), still quiet but busier.

**Porsche Motorsport / Chevrolet Corvette Racing web hero.** What they do: a full-width car shot, a very large title bottom-left, a
thin row of data under it, almost nothing else, the car never covered. What we match: the car is large (about 55 % of the width, 53 %
of the height), uncovered, well lit (no darkening layer; only an alpha fade at its left edge and foot), text lives only in the black
left side and in a strip under the car. The headlight glare and the Goodyear / WEC markings are left as photographed. What we do not
match: their photos are clean studio-grade; ours is a credited night photo of a Le Mans car (#33, "2nd" panel), not Peter's livery.
That is the largest gap and it cannot be closed in code: it needs his own capture (paddock\home\hero.jpg).

**Apple TV+ sports title screen.** What it does: black field, one image, title left, one filled button, quiet metadata line, a soft
long gradient, motion only on arrival. What we match: one gold filled button (the only fill on the screen), 560 px wide, 88 px tall,
arrow on the right; blocks arrive one after another (opacity and 10 px of travel, 1 s each, no loop); the gradient is eased
(smootherstep, 600 px long) so no band or edge shows; the metadata is one line of 14 px tracked labels. What we do not match: they
add a second ghost button; we do not (one obvious button is Peter's rule).

Verdict against all three: the composition (one image, one name, one action, one row) is at their level. Open points are the photo
(not his car) and the white studio tile of iRacing's own car picture, which is the brightest object on the left and repeats the car the
photo already shows. The tile was asked for by the lead (CP-1); if the real hero capture arrives, drop the tile.

## 2. Every fix made (rejected version -> this one)

1. Hard split gone: the dark panel and the vertical edge at x=740 are deleted. The picture is a masked image: a 600 px smootherstep
   alpha ramp on its left edge (x 700 to 1300), an eased top ramp (0 to 330 px) and an eased foot ramp (690 to 835 px). Measured on a
   flat grey picture in home-test: biggest single-pixel step 2 to 3 levels (a hard edge is 10 or more), never falls.
2. No text on the car: nothing sits right of x 700 except the top line, the pairing square and the facts row under the car. Test: the
   car is two boxes computed from the picture (cabin 920..1547 x 190..739, nose 1547..1842 x 356..739); no text, button, picture or
   square intersects them, in the main view and in four states.
3. First draft had the ramp at 560 to 1300 with a plain smoothstep: the "33" and the green "2nd" panel glowed behind the name and the
   button. Moved the ramp right, switched to smootherstep, and pushed the picture 257 px right / 163 px up so the nose ends on the right
   margin and the sky above the car is cut.
4. A teal lens flare at the top (x 800, y 40) read as a glitch next to the top line: the top ramp starts at 10 % alpha, so it is gone.
5. One composition: 3 levels. Level 1 name + number + car (88 px, one block); level 2 the one gold button; level 3 one row of facts.
6. Removed: greeting, big clock, idle quote, THIS WEEK, LAST OUTING line, rig timings sentence, "yesterday" chatter on every best, the
   "Race weekend" panel (hidden by CSS; its header countdown still works), the career "sessions" count, the big outline "4" behind
   everything, the drifting gold glow. (COPY-RULES: no greeting, no sentences, labels and numbers.)
7. Grid: 96 px side margins, 12 columns of 122 px, 24 px gutters. Left edges tested: 96 (name, number, picture, button, bests, foot),
   972 (career, column 7), 1410 (last session, column 10); right edges 1824. Chrome lines are 48 px from the edge.
8. Type: three sizes only (88 / 30 / 14 and 16), measured in the test across every text box. The first draft also had 28, 13, 12 px:
   unified to 30 and 14.
9. Gold only on the number and the button (and the REVIEW outline). The PADDOCK mark is now ink, not gold.
10. Headings crowded each other ("SINCE MAY 2023  LAST SESSION" read as one line): the dim words now sit directly after their heading.
    Career values were unevenly spaced: four equal columns now.
11. Status: rig, iRacing and phone state are one 14 px line at the foot (dots, no cards); the credit is tiny, bottom right, on black.
12. Phone: the white square shows only while no phone is paired (top right, over the dark sky, not on the car); paired = the words
    PHONE PAIRED; not allowed = `Phone: run tools\phone-allow.cmd` in amber. It no longer sits on the screen for ever.
13. THE BUTTON DOES WHAT IT SAYS (lead's rule). LAST DRIVE shows his last session's car and track. A press sends `mdpick <id>` (the id
    MY DRIVE gives that car + track), waits until `/mydrive` says that car and track are chosen, then `mdstart`. If it cannot be chosen
    it does not start and says CAR NOT CHOSEN. No last session = START (deck key test-drive-last) with no car or track named. Tested as
    a dry run: the label's car and track equal the command's, and the id resolves in `/mydrive` to that exact car and track.
14. Test seam measure: first version limited the step to 3.2 levels per 4 px and failed on the legitimate steep foot ramp; now it
    measures single-pixel jumps (limit 5) and direction over 4 px. The shot is taken after the button's colour has settled.

## 3. Left open for the lead's look

- The photo is a stand-in (credited, CC BY 4.0). A capture of his Corvette from a replay (paddock\home\hero.jpg) would lift this
  most; the page switches to it by itself and drops the credit. The masks assume the car sits in the right 55 % and the nose is near
  the right margin; a different capture needs `left/top/width` in home.css (three numbers) and the two boxes in `Home.carRegion()`.
- The studio tile (iRacing's own car image) is the brightest thing on the left. Keep or drop is the lead's call.
- No motion on the picture itself (no slow drift): deliberate, calm and cheap on the GPU.
