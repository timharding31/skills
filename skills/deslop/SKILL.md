---
name: deslop
description: Cut AI slop from any writing and any code change. Must always apply.
disable-model-invocation: false
---

# Deslop

Remove AI patterns from text and code. The goal is output that a careful human on this team would have written.

This applies to everything you produce: replies, commit messages, MR descriptions, docs, code comments, and code. Run it explicitly on a branch before you commit or open an MR.

## Process

1. Pick the scope.
   - Prose: the text you are writing, or the text you were asked to edit.
   - Code: the branch diff (`git diff main...HEAD`, or the working tree if uncommitted). Touch only lines the branch introduced.
2. Scan for the patterns below. The prose rules also apply to comments, docstrings, and commit messages.
3. Rewrite. Preserve meaning and behavior. Match the intended tone and the file's local style.
4. After code edits, re-run the project's tests and lint if a verify command exists.
5. When you ran this as an explicit pass, report what you removed and why in 1 to 3 sentences.

## Prose patterns

### Content

1. **Superficial -ing phrases.** "highlighting...", "ensuring...", "reflecting...", "showcasing...", "fostering...". Delete or expand with real sources.
2. **Vague attributions.** "Experts believe", "Industry reports suggest", "Some critics argue". Name the source or delete.

### Language

3. **AI vocabulary.** Additionally, crucial, delve, enduring, enhance, fostering, garner, interplay, intricate, landscape (abstract), pivotal, showcase, tapestry (abstract), testament, underscore, vibrant. Replace with plain words.
4. **Fancy ways to say "is".** "serves as", "stands as", "boasts", "features". Just say "is" or "has".
5. **"Not just X, but Y."** State the point directly instead.
6. **Rule of three.** Forcing ideas into groups of three. Use the natural number.
7. **Synonym cycling.** Protagonist, main character, central figure, hero all in one paragraph. Pick one, repeat it.
8. **False ranges.** "from X to Y" where X and Y aren't on a meaningful scale. List topics directly.

### Style

9. **Em dash overuse.** Avoid em dashes entirely. Use periods or commas only (no parentheses, no en dashes, no hyphen-as-dash substitutes). If a thought needs separation, end the sentence or use a comma.
10. **Colon overuse.** Colons are fine before a list or example. Not as mid-sentence connectors. "If you're coming from traditional automation: instead of registering event handlers, you describe conditions" adds nothing with the colon. Rewrite to let the point stand on its own without comparison framing. "Describing when the scheduler should fire works best as plain English." Same meaning, no crutch punctuation.
11. **Boldface overuse.** Don't bold every proper noun or acronym.
12. **Inline-header lists.** The tell is a bold label and colon that restates the line: "**Performance:** Performance improved...". Convert those to prose. A bold lead-in that ends in a period, names the item, and is followed by genuinely new detail ("**Schema in TypeScript.** Tables live in one file.") is fine, not a tell.
13. **Title case headings.** Use sentence case.
14. **Decorative emojis.** Remove from headings and bullets.
15. **Curly quotes.** Replace with straight quotes.

### Communication artifacts

16. **Chatbot phrases.** "I hope this helps!", "Let me know if...", "Of course!", "Certainly!", "Found the smoking gun!" Remove.
17. **Sycophantic tone.** "Great question! You're absolutely right!" Respond directly.

### Filler

18. **Filler phrases.** "In order to" becomes "To". "Due to the fact that" becomes "Because". "It is important to note that" gets deleted.
19. **Excessive hedging.** "could potentially possibly be argued that it might" becomes "may".
20. **Generic conclusions.** "The future looks bright." State specific plans or facts.

### Jargon

21. **Abstract metaphor nouns.** Substrate, wedge, vector, locus, vantage, nexus, primitive (as noun), harness (as metaphor), surface (as in "API surface"), bedrock, scaffolding (as metaphor), modality, paradigm, gold-plating, ratchet (as metaphor), evacuate (for moving code), endgame, north star, flywheel. These read as technical but usually have a plainer concrete word. "Substrate" becomes "base". "Wedge in" becomes "add". "Vector" becomes "way" or "method". "Gold-plating" becomes "more than the job needs". "Ratchet" becomes the mechanism's real name or "a limit that only tightens". "Evacuate" becomes "move out". "Endgame" becomes "the last phase". Pick the concrete word.

### Plain speech

22. **Say what it does, not how it feels.** "the database stays close at hand", "SQL you can read", "types that follow your schema" name a feeling. The fix names the mechanism or a number: "`.toSQL()` returns the exact string sent to the database", "a column rename fails the build". Ask what the sentence tells the reader to do or know, then write that. If you can't restate it as a concrete instruction, fact, or number, cut it. One more check: if the sentence could appear unchanged in another project's docs, it says nothing about this one. Cut it.
23. **Shorten or split dense sentences.** If the reader has to backtrack to parse a sentence, break it in two or drop clauses. One idea per sentence.
24. **Active voice.** Prefer it. Catch "is/are/was/were + past participle" and name the actor: "queries are validated" becomes "the compiler validates queries", "the file is parsed by the loader" becomes "the loader parses the file". Passive is fine only when the actor is unknown or genuinely doesn't matter.
25. **Cut adverbs, or use a stronger verb.** "runs quickly" becomes "is fast" or the number. "significantly improves" becomes the measured delta. An adverb propping up a weak verb means the verb is wrong.
26. **Prefer the plain word.** "utilize" becomes "use", "leverage" becomes "use", "facilitate" becomes "help", "numerous" becomes "many", "in the event that" becomes "if". The fancier synonym is rarely clearer.
27. **Mannered prose.** Metaphor or flourish where a literal phrase exists: aphorisms ("wire it or delete it"), rhetorical fragments for effect, personified code ("the plan holds it"), figurative verbs ("rides along", "stands on"), stock framing phrases. "A dial worth turning" becomes "a parameter worth varying". Say what you mean. Rule 21 covers the metaphor nouns.
28. **Over-compression.** Dropped articles, verbless fragments, symbol-speak, and abbreviations that make the reader decode instead of read. "Parser rejects bad date → exit 2, no write" becomes "The parser rejects a bad date, exits with code 2, and writes nothing." Write whole sentences with their articles and verbs, and spell out arrows and abbreviations.

## Code patterns

29. **Redundant comments.** Comments that restate the next line, narrate the change ("added to handle X"), or are denser than the file's local style. Keep only comments that state a constraint the code can't show. Comments you keep follow the prose rules.
30. **Defensive noise.** try/catch blocks, null checks, and validation on trusted internal code paths where the surrounding codebase doesn't do it.
31. **Type escape hatches.** Casts to `any` (or `as unknown as`, `# type: ignore`, `interface{}`) used only to silence the type checker. Fix the type instead.
32. **Over-nesting.** Deeply nested conditionals that early returns or guard clauses would flatten.
33. **Duplicate tests.** Tests that assert the same behavior as an existing test under a new name or with trivially different inputs, and tests that only exercise a mock. Merge them into one table-driven test or delete the copy.
34. **Style drift.** Naming, idioms, or patterns inconsistent with the file and surrounding codebase. Match what's there, not what's generically "best".

## Guardrails

- Keep behavior unchanged unless you fix a clear bug, and say so if you do.
- Prefer small, focused edits over broad rewrites.
- Don't rewrite quoted material, test fixtures, or strings that other code matches on.
