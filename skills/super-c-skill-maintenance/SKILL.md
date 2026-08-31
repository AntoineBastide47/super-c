---
name: super-c-skill-maintenance
description: "Keeps the Super-C skills directory accurate after compiler or language changes. Fires at the END of a task: reviews what changed and tells the user which skills need updating and why. Only flags meaningful or breaking changes, not cosmetic ones. Use proactively after completing any change to the compiler, language, build system, or standard library."
allowed-tools: Bash Read
---

# Super-C Skill Maintenance

## Agent checklist

- Inspect the completed diff and map changed paths to skills.
- Run `python3 skills/scripts/validate_skills.py --report`.
- Flag only claims that are wrong, contradictory, or materially incomplete.
- Name the affected section and corrected claim in the handoff.

This skill runs **after** a task is complete. It does not modify skills itself — it
identifies which skills are stale and reports them to the user with reasons. The
validator supplies source-reference and changed-path evidence; human review decides
whether behavior changed.

## When to Fire

At the end of every task that changes the compiler, language semantics, build system,
standard library, or tooling. Do not fire during the task — wait until the change is
done and verified.

## What to Check

Read the completed changes (the diff or the files touched), then evaluate each skill
against the change. A skill needs updating only when the change **breaks, contradicts, or
materially extends** what the skill documents.

### The Threshold

**Update** when the change:
- Adds, removes, or renames a subcommand, flag, or environment variable
- Changes the syntax or semantics of a language construct the skill documents
- Alters the compiler pipeline order, adds or removes a pass
- Changes the self-hosting contract, fixpoint protocol, or bootstrap workflow
- Adds a new concurrency primitive, FFI mechanism, or test harness feature
- Changes a documented invariant (freeze contract, determinism, ownership rules)
- Changes the comment/documentation policy
- Adds a new optimization pattern or invalidates a documented one

**Do NOT update** when the change:
- Fixes a bug without changing documented behavior
- Refactors internals without changing the pipeline architecture
- Improves performance without changing the optimization protocol
- Adds a lint or diagnostic message
- Changes code style in ways the formatter already enforces
- Touches files not covered by any skill

### The Skills and Their Scope

| Skill | Covers | Update when |
|-------|--------|-------------|
| `super-c-binary` | CLI subcommands, flags, build.toml, env vars, profiles | A subcommand/flag/env var is added, removed, renamed, or changes behavior |
| `super-c-language` | Syntax, semantics, type system, ownership, generics | A language construct is added, changed, or removed |
| `super-c-compiler-optimization` | Profiling protocol, optimization phases, bench gate, fixpoint | The benchmarking protocol, optimization patterns, or fixpoint contract changes |
| `super-c-compiler-internals` | Pipeline stages, Core IR, HIR, identity model, freeze contract | A pass is added/removed/reordered, Core IR representation changes, identity model changes |
| `super-c-testing` | @test lifecycle, fixtures, assert builtins, leak tracker, harness | Test attribute behavior, fixture mechanics, or harness architecture changes |
| `super-c-ffi` | extern blocks, @c.source/@c.link, str/NUL, bindgen | FFI mechanism, attribute behavior, or string interop changes |
| `super-c-self-hosting` | Fixpoint contract, bootstrap, porting patterns | The bootstrap workflow, fixpoint protocol, or a new porting-bug pattern is discovered |
| `super-c-concurrency` | launch, scheduler, Send/Sync, channels, data parallelism | A concurrency primitive is added/changed, scheduler behavior changes |
| `super-c-documentation` | Comment rules, doc tiers, delete-test, banned filler | The documentation policy changes |
| `super-c-task-discipline` | Recurring agent failure modes and their prevention checklists | The user corrects a NEW recurring failure mode, or lifts a standing rule the skill encodes |

## How to Report

At the end of the task, after all changes are verified:

1. List each skill that needs updating.
2. For each, state **what changed** and **what in the skill is now wrong or incomplete**.
3. Be specific: name the section, the outdated claim, and what the correct information is.

Format:

```
Skills that need updating after this change:

1. super-c-binary — The new `--target-cpu` flag is not documented.
   Section: "Common flags" table. Add a row for `--target-cpu=NAME`.

2. super-c-compiler-internals — The resolver now runs after desugar, not before.
   Section: "Pipeline Overview" diagram and references/stages.md stage 5.
   The current text says resolver runs before desugar.
```

If no skills need updating, say so explicitly:

```
No skills need updating — this change does not affect any documented behavior.
```

## Rules

- **Do not update skills yourself.** Report what needs changing. The user decides when
  and how to update.
- **Do not flag cosmetic changes.** A renamed internal variable, a reworded error
  message, or a performance improvement that does not change the optimization protocol
  does not require a skill update.
- **Do not flag additions the skills already cover at the right abstraction level.** If
  the skill says "lints: unused imports, members, labels, ..." and a new lint is added,
  the ellipsis already covers it. Flag it only if the new lint changes the documented
  categories or severity model.
- **Be conservative.** A skill that is slightly incomplete is better than one that is
  constantly churning. Only flag changes where a reader following the skill would get
  wrong information or miss something important.
- **Group related updates.** If one change affects three sections of the same skill, that
  is one update with three points, not three separate updates.
- **Prioritize correctness over completeness.** A skill that says something wrong is
  urgent. A skill that omits a new feature is less urgent — the feature works whether
  or not the skill mentions it.
