# Working Rules

This file has two parts:

- [Part 1: General Rules](#part-1-general-rules) apply to every project. Copy Part 1 unchanged to reuse it.
- [Part 2: Project Rules](#part-2-project-rules-super-c) apply only to Super-C. They add to Part 1. Where a Part 2 rule is more specific than a Part 1 rule, follow Part 2.

Follow these rules for all tasks unless the current user message gives a more specific instruction.

---

# Part 1: General Rules

## 1. Priorities

- Optimize for correctness, then performance, then developer experience, in that order.
- Treat readability as a tool for correctness and maintenance, not as an end by itself.
- Prefer simple designs that satisfy all three priorities.
- Spend design effort before implementation when it can prevent complexity or production cost.
- Do not accept known technical debt in changed code.
- Do not ship undefined behavior, unsound ownership or borrow rules, or avoidable exponential work.

## 2. Scope of the Task

- When the user asks a question, answer it. Do not change code unless asked.
- Complete the full requested task.
- Do not stop mid-task to report progress. Continue until the task is complete or blocked on input only the user can provide.
- Do not defer a sub-item silently. List anything not done, with the reason.
- When a plan's gate conflicts with the request, finish the independent work, then ask one question with a current, after, and delta table.
- Change only the files and code that are necessary for the task.
- Preserve existing behavior unless the task requires a behavior change.

## 3. Design and Code Changes

- Do not overengineer. Follow YAGNI principles.
- Prefer the smallest correct change. Prefer one-liner solutions.
- Minimize added code, complexity, maintenance cost, latency, allocations, and unnecessary work.
- Do not trade correctness or readability for meaningless code-size reduction.
- Prefer existing abstractions when they are suitable.
- Add an abstraction only when it makes the domain clearer or removes real duplication.
- Do not add abstractions for hypothetical future use.
- Do not add defensive code for conditions that cannot occur under the existing contract.
- Check related code and behavior when needed to make the requested change correct.
- Remove dead code that becomes unnecessary because of the requested change when removal is safe and directly related to the task.

## 4. Correctness

- Use simple, explicit control flow.
- Give every loop and queue a fixed upper bound.
- Assert the intended non-termination of loops that are designed to run forever.
- Handle every operating error.
- Treat assertion failures as programmer errors and corrupt state as fatal.
- Treat all compiler warnings at the strictest supported setting as errors.
- Fix root causes. Do not hide defects with workarounds. A symptom that recurs after your fix means the fix was wrong: trace to the origin.
- A host-specific output difference is a defect where the bytes are produced. Never normalize it in tests.

## 5. Performance

- Consider performance during design, not only after implementation.
- Estimate network, disk, memory, and CPU costs when they can affect the design.
- Consider both bandwidth and latency.
- Optimize the slowest or most frequently used resources first.
- Keep performance-sensitive paths efficient.
- Prefer flat data and predictable access over unnecessary pointer chasing.
- Amortize allocation cost.
- Grow dynamic containers geometrically instead of one element at a time.

## 6. Tools and Dependencies

- Prefer existing project tools before adding new tools.
- Do not add a tool when the existing project tool can solve the problem well.
- Keep dependencies minimal.
- Treat every new dependency as a supply-chain, versioning, build, and maintenance cost and risk.

## 7. Defects, Verification, and Completion

- Verify a checkable fact (git state, API signature, numbers, environment) before you state it.
- Fix every defect you find, also minor ones and ones CI does not hit. Leave a found defect unfixed only when the user decides so.
- Do not suggest, create, or request smoke tests.
- Run heavy verification once, at the end. The coordinator runs it. Part 2 lists the project's heavy verification.
- Never pipe a gate into `tail` or another filter: the pipeline returns the last command's status.
- Never run parallel stress loops of thread- or process-spawning programs on the developer's machine. Use CI or a container with `--pids-limit`.
- Before reporting completion, verify every sub-item against the files, builds, and tests, not against your recollection.

### Defects in a Tool, Compiler, or Dependency That We Control

If natural and correct code fails because of such a defect:

1. Treat that defect as part of the task.
2. Fix the root cause when the fix is clear and reasonably scoped.
3. Keep the natural code instead of adding a workaround.
4. If the root-cause fix is unclear, unsafe, or too large, or if a correct solution requires a large or unclear workaround, stop and ask before you add the workaround.

## 8. Subagents

- State in every agent brief that the coordinator runs heavy verification at the end.
- Send a subagent's "too large" or shortcut result back for the full implementation. Never present the shortcut to the user as an option.
- Never spawn subagents unless the user asks for it.
- Always spawn the exact number of subagents the user asks for, no more and no less

## 9. Communication

- Use concise ASD-STE100 Simplified Technical English.
- Use direct statements.
- Prefer short, common words when they are precise.
- Remove every word that does not add useful information.
- Prefer active voice.
- Avoid metaphors, idioms, figures of speech, and unnecessary jargon.
- Use technical terms when they are more precise than common words.
- Do not add unnecessary explanation.

## 10. Git

### Permission

- Never run `git commit` unless the current user message explicitly asks for a commit.
- Never run `git push` unless the current user message explicitly asks for a push.
- "Fix it" or "fix CI" is not permission to commit, push, dispatch a workflow, or cut a release. Every remote action needs an explicit ask.
- Do not open a pull request unless asked.
- Permission to commit or push applies only to the current user message. It does not carry to later messages.
- If asked to commit, create exactly one commit unless the user asks for more.

### Safety

- Run `git status` before any `checkout`, `restore`, `reset`, or `clean`. Never revert paths you did not create.
- After any git action, verify with `git status` or `git log` that it happened before reporting it.
- Never use `git commit --no-verify`, `git commit -n`, or any method that disables or skips hooks.
- If a Git hook fails, fix the cause. Do not bypass the hook.

### Commit Messages

- Use only a short subject line unless the user explicitly asks for a body.
- Write the subject as one clause under about 72 characters that names the main change.
- Make the subject describe the change clearly enough to remain useful in `git blame`.
- Do not use `--` punctuation or em dashes.
- Do not mention session-local identifiers such as phase numbers, bug numbers, or increment numbers unless they are real project identifiers required by the user.
- Do not mention tests, checks, benchmarks, or validation results.
- Do not mention yourself, the assistant, or AI.
- Do not add `Co-authored-by:` lines.

## 11. Web Search

- Use web search when the task needs current external facts, a referenced page or paper, precise quotations, external recommendations, or information that is uncertain or likely to change.
- Do not use web search for repository facts that source inspection can answer.
- For technical claims, use primary sources such as official documentation, standards, source repositories, or research papers.
- Compare publication or update dates when recency matters.
- Cite every web-derived claim with a direct Markdown link.
- State when the conclusion is an inference.
- Search may support design work for algorithms, implementations, performance data, and similar systems. It does not replace local benchmarks, source review, tests, or the project checks in Part 2.
- Do not add external dependencies based only on a search result. Review license, maintenance, and supply-chain impact first.

---

# Part 2: Project Rules (Super-C)

## 1. Rules That Bind Every Task

1. Every compiler change must preserve the byte-identical two-generation fixpoint documented in `super-c-self-hosting`.
2. Before reporting any task complete, apply the completion contract in `super-c-task-discipline`: every sub-item verified against reality, nothing silently deferred, every found defect fixed.
3. After you complete a change to the compiler, language, build system, or standard library, apply `super-c-skill-maintenance`: tell the user which skills the change made stale and why, or state that none did.

## 2. Skills

The `skills/` directory is the project's reference documentation, packaged as agent skills. Read [skills/README.md](skills/README.md) for precedence, validation, and maintenance rules. Before working in an area, read the matching skill and its required references. The skills are authoritative for their areas. This file keeps only the working rules no skill covers.

| Area | Skill |
|------|-------|
| Start of every task and before reporting done: failure-mode checklists | `super-c-task-discipline` |
| End of every change task: report stale skills | `super-c-skill-maintenance` |
| Any compiler change: fixpoint contract, bootstrap, porting patterns | `super-c-self-hosting` |
| Invoking the compiler, build.toml, flags, environment variables | `super-c-binary` |
| Writing or reviewing `.spc` code, naming, style, file organization | `super-c-language` |
| Optimizing the compiler (profiling, benchmarks, fixpoint gate) | `super-c-compiler-optimization` |
| Modifying compiler passes, pipeline order, Core IR, HIR | `super-c-compiler-internals` |
| Writing or running tests, fixtures, leak gates | `super-c-testing` |
| Designing tests: oracle choice, batching, cache and energy cost | `super-c-test-design` |
| C interop, extern bindings, link flags | `super-c-ffi` |
| Concurrent code: launch, channels, data parallelism | `super-c-concurrency` |
| Targets: platforms, instruction sets, object formats, linkers | `super-c-targets` |
| Comments and documentation rules | `super-c-documentation` |

## 3. Verification

- Heavy verification is: full suite, fixpoint, `ci/gate.sh`, release bootstrap. Run it once, at the end (Part 1, section 7).
- Web search does not replace the self-hosting fixpoint check.
- Before any test, fixpoint, or commit claim, confirm which binary is at `./super-c`:
  - After a plain build: run `cmp super-c build/debug/super-c`.
  - After `check.sh`: run `cmp super-c build/bootstrap/test/super-c`.

## 4. Code

- An unsatisfied interface bound in your own snippet means the snippet is wrong. Do not add std conformances unasked.

## 5. Tooling

- Use Super-C's own compiler, formatter, test runner, build system, LSP server, and benchmark harness when they fit the task.

## 6. Dependencies

- Keep compiler dependencies minimal. The compiler may depend on libc and no third-party library unless the project policy changes explicitly.
- Do not add build-system generators, parser generators, or third-party compiler code.
- Prefer direct POSIX and Win32 integration through the standard library.

## 7. Git

- Commit on `main`. Create a branch only to fix CI.
- After the co-author check in the commit hook, the local commit-msg hook runs the full `check.sh`. `check.sh` moves the release binary onto `./super-c` and ends with its own rebuild there (`build/bootstrap/test/super-c`). See section 3 for the `cmp` check.
