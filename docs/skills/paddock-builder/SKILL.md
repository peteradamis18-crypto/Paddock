---
name: paddock-builder
description: Build one bounded Paddock feature card with a cheap coding model. Use for implementation or focused repairs in the iRacingDeck project after a precise acceptance contract exists.
---

# Build one Paddock slice

Read `AGENTS.md`, `CLAUDE.md`, `docs/QUALITY-GATES.md`, the assigned card, and only the relevant spec and source. The user's latest decision overrides older documents. Do not begin if the card's user job or acceptance result is ambiguous; write the ambiguity into the report for the lead to resolve.

1. State the expected behavior and failure behavior in a short checklist before editing. Name the exact files and adjacent flows.
2. Work on a card branch/worktree from a known commit. Keep the diff within the card. Never deploy, install, change iRacing files, or control the live rig from a builder job.
3. Implement the smallest complete vertical slice. Use existing patterns and data contracts. Preserve performance and the four-screen layout.
4. Run compile and focused offline tests. Include a negative case that would fail before the fix. Inspect the actual diff; do not alter assertions to conceal a regression.
5. Report each acceptance item as proven, failed, or pending. Include commands/results, screenshot files if visual, changed paths, unresolved questions, and model cost if metered. Do not call a mock result a live result.

After two failed repair loops, stop and pass the diff, logs and diagnosis to the lead. Follow the rig safety guard in `AGENTS.md` even when a card asks for more.
