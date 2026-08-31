---
name: super-c-task-discipline
description: "The recurring agent failure modes observed across this repo's session history, with the checkable procedures that prevent each one: completion contract, delivery verification, claim verification, root-cause discipline, question handling, destructive-action safety, and prose rules. Read at the start of every task and before reporting any task complete."
allowed-tools: Bash Read
---

# Task Discipline

This skill encodes the recurring failure modes mined from 37 past agent sessions in
this repository (~1,370 user turns, ~185 corrections). Each section is a failure mode,
ranked by frequency, with the procedure that prevents it. These are not style
preferences: every rule below exists because an agent violated it and the user had to
correct it — several repeatedly.

The meta-finding that shapes this file: **vague reminders did not work**. Rules that
were already written down were still violated. What works is a checkable procedure
applied at a decision point. Apply each section's checklist at the moment it names.

## 1. Completion Contract (~35 incidents — the #1 failure)

Agents stopped at checkpoints to report, deferred sub-items without saying so, and
claimed completion that did not survive an audit.

**At every point where you consider stopping:**
- Do not stop mid-task to report progress. Continue until the full request is done or
  you are blocked on input only the user can provide.
- Never silently defer a sub-item. Anything deliberately out of scope goes in an
  explicit "not done" list with the reason. (One silently deferred item turned out to
  be a 4–6% performance win.)
- A pause to ask "should I continue?" on work already requested is itself a failure.

**Before saying "done":**
- Enumerate every sub-item of the original request.
- Verify each against reality — files on disk, builds, test runs — not against your
  recollection of having done it.
- Surface every defect discovered along the way. Never bury a known issue; fix it or
  report it prominently.
- Never declare a goal impossible without exhausting the approaches. Two "unsound /
  unreachable" declarations in past sessions were implemented soundly once challenged.

## 2. Ignored Standing Instructions (~22 incidents)

The same explicit instructions were violated repeatedly across sessions: manual
`.free()` calls despite RAII, parallelism used after it was declared off-limits,
em-dashes after a ban, phase references in docs, wrong binary names, deleted
workflow files.

**Before acting:**
- Treat every instruction in AGENTS.md, the skills, and the current conversation as
  binding until the user lifts it. "It seemed better this time" is not a lift.
- The user's reaction is harshest on the *second* violation of the same instruction.
  If you catch yourself about to repeat something the user has corrected before, stop.

## 3. Unverified Claims (~18 incidents)

Agents stated git state, API signatures, environment facts, and numbers without
checking: "unpushed" branches that were pushed, debugging at `-O0` an optimization-
dependent bug, stale function signatures, tables whose numbers did not sum, credit
taken for improvements another agent caused.

**Before stating any checkable fact:**
- Git state → run the git command first.
- API or signature → read the current source first.
- Numbers → recompute totals and cross-check internal consistency.
- Bug reproduction → same compiler, same flags, same optimization level, same
  platform as the report.
- A metric you did not move → say so; never absorb external causes into your narrative.
- Prefer "I checked X: Y" phrasing — it forces the check.

## 4. Letter-Not-Spirit and Shallow Fixes (~16 incidents)

Literal requests satisfied while their purpose was defeated (a strict-mode API built
but the pipeline never adapted to use it), and the same defect "fixed" cosmetically
2–3 rounds before the real fix.

**Before implementing:** state what the change is FOR. **After implementing:** verify
the purpose is achieved end to end, not just that the named artifact exists.

**When a symptom recurs after your fix:** your fix was wrong. Stop patching symptoms;
trace the mechanism to its origin and fix there. If natural user-level code needs an
unnatural workaround, the compiler is the bug — see `super-c-self-hosting`.

## 5. Overreach on Questions (~14 incidents)

Code was deleted during an *explain* request; work was done when the user asked *how*
to do it; unrequested docs and defensive code were added. The user now defensively
writes "No code changes, just answer" — each such guard marks a past failure.

- A question ("why / how / what / is it true that") gets an answer and **zero edits**,
  even when the fix is obvious. Offer the fix in one line; wait for the ask.
- When asked to change X, touch exactly X. Do not improve neighboring code in passing.
- Do not add doc comments, READMEs, or explanatory files unless requested.

## 6. Undelivered "Fixes" (~13 incidents)

Work was completed but never reached the user's environment: a stale `./super-c`
measured twice, changes stranded in an unauthorized /tmp worktree, an amend that never
happened, edits not propagated to a paired directory.

**Before claiming a fix is live:**
- Know which binary the user runs (`./super-c` at repo root vs `build/dev/super-c`);
  rebuild before any measurement claim and say when the deployed binary is stale.
- Work in the repo the user works in. Never move work to a worktree or temp clone
  unless asked.
- After any git action (commit, amend, revert), verify with `git status` / `git log`
  that it happened before reporting it.
- When two locations mirror content, change both or say which one was left.

## 7. Destructive Actions (~11 incidents — highest severity)

The rarest but worst failures: a broad `git checkout -- .` reverting the user's live
edits, a bisection checkout losing new tests, deleted derived files breaking a build
with a false recovery claim on top, Python patch scripts silently no-op'ing after the
formatter moved their anchors, unauthorized commits and pushes to main.

- Never run `git checkout/restore/reset/clean` over paths you did not just create;
  check `git status` first and stash anything present.
- A scripted text patch (python/sed) that matches zero occurrences is a **failure to
  report**, never a silent success. Prefer targeted editor changes.
- Never delete files you did not create without confirming their role.
- Review `git status` after any broad `git add`; commit only what the task touched.
- Commits and pushes happen only on explicit instruction in the current message.
- After a recovery attempt, verify the build and tests pass before claiming recovery.

## 8. Performance-Work Hygiene (~11 incidents)

Unmeasured claims (a "2407ms → 1120ms" that was a cold/warm cache artifact), a 10x
regression accumulating untracked across a session, and the user having to supply the
techniques themselves (samply, generated asm, struct packing, complexity classes).

- Follow `super-c-compiler-optimization` unprompted for any perf work: profile first,
  then hotspots/allocations, compaction, complexity, asm — in that order.
- Every claim: interleaved A/B on clean builds, cycles/allocations not wall-clock,
  discard the first post-rebuild run, confirm the measured binary contains the change.
- Track the headline metric across the whole session and report cumulative drift.
- When stuck, broaden the toolbox yourself (web search, asm, alternative algorithms)
  before reporting "no progress".

## 9. Prose Failures (~9 incidents)

Docs and papers called "not understandable by anyone" (one rewrite failed the same
test twice), concession-first framing, self-narration tics, the same fact stated three
times, em-dashes after a ban.

- Lead with the claim; caveats come after, once.
- State each fact once, at its strongest location.
- No self-narration ("we now turn to…", "having established…").
- No em-dashes or `--` punctuation anywhere.
- If told a text is unreadable, change its structure (sentence length, term choice,
  order) — not just individual words.

## Rationalizations to Reject

- "I'll report progress and let the user decide." — The user decided when they asked.
  Continue.
- "This sub-item is minor, I'll skip it quietly." — Deferred items have turned out to
  be wins. List it or do it.
- "The fix is obviously right, no need to rebuild/measure." — Two sessions measured a
  stale binary.
- "The question implies they want it fixed." — It implies they want an answer.
- "The instruction probably doesn't apply here." — It applies until lifted.
- "The patch script ran without errors." — Zero matches also runs without errors.
