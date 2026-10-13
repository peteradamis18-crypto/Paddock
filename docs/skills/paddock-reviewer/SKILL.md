---
name: paddock-reviewer
description: Independently review a Paddock feature diff and its evidence before integration. Use after a cheap model builds a card or fixes a regression in iRacingDeck.
---

# Review the result, not the report

Read `AGENTS.md`, `CLAUDE.md`, `docs/QUALITY-GATES.md`, the source requirement and the actual Git diff. Treat the builder's report as a claim.

1. Map every acceptance item to code and evidence. Flag missing or narrowed behavior.
2. Trace safety paths: driving guard, focus changes, iRacing files, FFB, session transitions, deployment and recovery.
3. Check data correctness, real timing, empty/error states, and neighboring flows. Look for stale state, duplicate events and tests that pass without exercising production logic.
4. Run appropriate offline checks when safe. For each new test, identify the mutation or pre-fix behavior that would make it fail.
5. For UI, inspect screenshots at the actual display size against `docs/DESIGN-analysis.md`; a passing selector/pixel assertion is insufficient.

Return `ACCEPT`, `ACCEPT WITH FIXES`, or `REJECT`, with file/line evidence and a specific repair. Mark live-only evidence pending. Do not merge or deploy merely because the builder returned exit 0.
