# DK-2 New MAIN grid, keys.map, no dead keys, preview picture

Read AGENTS.md, CLAUDE.md, docs\COPY-RULES.md, docs\deck\DECK-v4.md, docs\deck\council-fable.md section 3 (the MAIN table and rules),
then build-deck.ps1, keys\keys.map, tests\keys-test.ps1 and docs\deck-speed.md.

## Build
1. Change the MAIN layout in build-deck.ps1 to council-fable.md section 3 MAIN exactly (row/col as written). New keys and their
   commands in keys\keys.map: `ai-race=airace start`, `test-drive=startlast td`, `save-rec=dash recsave`, `debrief=dash debrief`,
   `vault=dash vault`, `tv=dash tvview`; keep existing commands for kept keys. Labels <= 2 short words; no static "on / off"
   subtitles (leave subtitle empty where the add-on will draw live state in DK-4).
2. Keys removed from MAIN (SHOWCASE, SAVE RESET POINT, BACK TO RESET POINT, TEAR OFF, CLEAR PIT and anything else not in the grid)
   move to the MORE page list in build-deck.ps1 - nothing is lost.
3. Add `-Preview` to build-deck.ps1 if missing: renders the 8x4 MAIN grid to `docs\deck\main-preview.png` (black keys, gold labels,
   the same text as the real keys) WITHOUT touching the Stream Deck profile or closing Stream Deck.
4. tests\keys-test.ps1: every MAIN and MORE key maps to a real irdeck/dash command (0 dead), no duplicate key positions, every
   label passes the copy rules, key 0,0 is HOME.
`dash debrief` / `dash vault` may not exist yet in irdash: list them in NEEDS LEAD (the dash command set lives in dash\src\vault.cs
Commands); keys-test may mark them PENDING, not dead, with that reason.

## Files
build-deck.ps1, keys\keys.map, tests\keys-test.ps1, docs\deck\main-preview.png (generated), docs\tasks\log\DK-2.md.
NEVER run build-deck.ps1 without -Preview (the lead runs the real build when sim=False with Stream Deck closed).

## Gate
`powershell -ExecutionPolicy Bypass -File build-deck.ps1 -Preview` makes the picture; tests\keys-test.ps1 0 FAIL. Report in AGENTS.md
format to docs\tasks\log\DK-2.md.
