You polish build cards for PADDOCK v4 so a cheap coding model (DeepSeek V4.1 Flash) can build each one without guessing.
Read AGENTS.md, CLAUDE.md, docs\COPY-RULES.md, then docs\SPEC-v4.md (sections 1, 3 and the card rows in section 5).

Cards to polish: K-01 to K-04, F-01, A-01, A-02, PH-01, DS-01 to DS-05, HK-01 to HK-04 (K-01/K-02 must now follow docs\deck\DECK-v4.md and cards DK-1..DK-3 - mark overlaps) (files docs\cards\v4\<ID>.md).

For each card, read the REAL code and docs it names, then rewrite the card file in place (same section headings) so that:
- every file path, function, class, route, JSON field, ini key, test file and test section it names really exists (or
  is clearly marked "new"); fix wrong names; add the exact existing functions to reuse with file:line;
- the Build steps are concrete and ordered (units, thresholds, data formats, coordinate conversions, edge cases);
- it agrees with SPEC-v4.md (the wireframes in section 3 and the decisions) - e.g. real GPS maps are what is drawn;
- garbled words and contradictions are removed;
- the Gate names a test with numeric checks that would FAIL on broken code, and a user journey Peter could fail;
- the Files list is exhaustive; it stays one OpenCode session (split into <ID>a / <ID>b files if too big, and say so);
- safety rules stay (never act while he drives, never write iRacing files, C# 5, real assets only, copy rules).
Edit ONLY files under docs\cards\v4\. Do not change code. At the end print one line per card: ID - what you changed.
