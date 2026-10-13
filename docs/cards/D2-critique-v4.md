You are a demanding second reviewer. The FIRST attached file, docs\SPEC-v4-draft.md, is a product + engineering spec
drafted by another model for PADDOCK v4 (Peter's iRacing sim-rig super app). Every other attached file is the source
material it was written from. Peter's bar: "an amazing product, nothing is off the table", premium (Cosworth Pi Toolbox
Ultra depth, F1 TV broadcast polish), disabled user - one press or automatic, never has to think.

Write a critique in markdown, ordered by impact:
1. **Missing or dropped**: anything in docs\HANDOFF-lead.md (the 19 items + Peter's answers), PLAN-v4.md, ROADMAP.md or
   the research that the draft forgot, weakened or dropped silently. Quote the source line.
2. **Not amazing enough**: where the draft is shallow vs the best tools in the research (Pi Toolbox, MoTeC i2, ATLAS,
   Garage 61, Track Titan, Coach Dave Delta, VRS, F1 TV, iRacing's own broadcast). Name the concrete feature it should
   have instead, with the data source that makes it possible.
3. **Wrong or impossible**: claims that conflict with facts in the sources (data that does not exist in .ibt/SDK,
   iRacing Data API closed, one sim = one camera, never write iRacing files, C# 5 / no frameworks, never act while he
   drives) or with Peter's answers.
4. **Card plan problems**: cards too big for a cheap model (should be split), missing dependencies, gates that test code
   not the user journey, wrong order (Peter should see big value early).
5. **Cost estimate**: is it realistic for agent loops (re-reads, failed test iterations, deploy/test cycles)? Give your
   own per-phase numbers if different, and why.
6. **Top 10 changes** you would make, each one line.
Be specific; no praise; no padding.
