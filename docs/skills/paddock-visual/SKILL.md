---
name: paddock-visual
description: Review or design Paddock dashboard, phone, Stream Deck, and analysis screens for premium sim-racing quality. Use before implementing a new screen and before accepting a visual change.
---

# Inspect the screen from Peter's seat

Read `docs/DESIGN-analysis.md`, `docs/COPY-RULES.md`, and the feature contract. Use real session data and licensed/local assets; do not invent cars, liveries or drivers.

1. Pick one or two relevant reference products and state the specific information hierarchy to borrow.
2. Mock the target at 1920x1080 for the top display, or the real Stream Deck/phone size. Show primary, empty, loading and error states.
3. Inspect rendered screenshots for legibility, truncation, spacing, alignment, hierarchy, color meaning, believable data and clear next action. Check at seated viewing distance, not just a zoomed browser.
4. Compare the implementation screenshot side by side with its approved mock and reference. Record concrete defects and fixes. Reinspect the new capture after changes.
5. Do not accept a screen with a dead control, fabricated insight, unlabeled metric, decorative chart, or copy that asks Peter to configure what Paddock can infer.

Report the screenshot paths inspected and the remaining differences. A text-only review cannot pass the visual gate.
