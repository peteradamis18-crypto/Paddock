# Paddock quality gates

This is the release contract for work done by any model. `AGENTS.md` and `CLAUDE.md` remain the rig safety rules. A card marked `done` in `docs/TASKS.md` is a claim to verify, not evidence by itself.

## One requirement, one proof trail

For each feature slice, record in its card or report:

| Field | Required content |
|---|---|
| User job | What Peter can accomplish with one obvious action, or automatically. |
| Source | Exact roadmap/spec section and any newer decision from Peter. Resolve conflicts before implementation. |
| Contract | Inputs, outputs, states, failure behavior, and integrations touched. |
| Acceptance | Observable results for normal, empty, stale, and failed states. |
| Visual target | Reference screen and screenshot size; what should be legible from the seat. |
| Evidence | Test command/result, screenshot path inspected, real-session result if applicable. |
| Cost | Model, tokens/cost where metered, run time, and any rework. |

Keep the slice small enough to review as one diff. A cheaper builder gets only the relevant files, contract and examples. Do not feed the entire roadmap as a substitute for a precise card.

## The four gates

1. **Contract:** Compare the change to every acceptance item and to the adjacent flows it can affect. Do not silently narrow a requirement or replace real behavior with a placeholder. Mark uncertainty explicitly.
2. **Engineering:** Compile without deployment, run focused tests and negative cases, inspect the diff. A test must fail when the behavior it protects is broken. Never weaken an assertion or change a fixture merely to make a red suite green. Investigate a red suite's cause before changing code or test.
3. **Experience:** Inspect actual 1920x1080 and Stream Deck screenshots, including normal, empty, loading and error states. Compare with `docs/DESIGN-analysis.md` and a relevant real racing product. Check hierarchy, typography, copy, truncation, navigation and whether the primary action is clear from the seat. A CSS assertion alone does not pass this gate.
4. **Rig:** Test the full journey on the real rig when the guard permits it, including the Stream Deck, iRacing, telemetry, recorder and recovery as relevant. Verify timing, focus, frame cost and no interference while driving. A mock pass is not a live pass. Keep the feature pending if the live gate cannot run.

The release report names each gate `pass`, `fail`, or `pending`, with evidence. Only `pass` across applicable gates permits a feature to be described as shipped. Preserve the last known good deployed version until the real journey passes.

## Model routing

- **Cheap builder:** bounded source change, fixture, parser, isolated UI component, documentation, or test implementation from a precise contract. One branch or worktree per card. No shared-tree parallel writes.
- **Strong reviewer:** independent diff review against the source requirement; safety, data correctness, integration and test validity. Reviewer sees the diff and evidence, not the builder's claimed verdict alone.
- **Human/lead visual and live sign-off:** novel screen, complex navigation, wheel/FFB, iRacing automation, recorder, deployment and anything that can interrupt Peter's session.

Stop a cheap-model attempt after two unsuccessful repair loops or when it changes unrelated files, guesses an API/UI state, weakens a test, or cannot explain a failure. Escalate the evidence and diff rather than paying for more blind retries. Record actual model spend per card; subscription use is not assumed free of limits.

## Change sequence

1. Start from a clean Git commit. Create a card branch/worktree and list the files it may touch.
2. Write the acceptance checklist and expected screenshots before implementation.
3. Build and test offline. Require an independent review and fix its findings.
4. Integrate one change at a time. Run affected suites plus the core journeys; inspect screenshots.
5. Deploy only through the guarded path when the rig is free. Run the live journey. Record what was observed and keep rollback ready.

No broad autonomous queue, automatic merge, or `done` status based on exit code alone while the integrated suite remains red. The first stabilization target is: start a session, drive/record it, review it, open lap analysis, and recover cleanly. Subsequent requirements join only after that path remains sound.
