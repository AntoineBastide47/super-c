---
name: super-c-self-hosting
description: "Documents the Super-C self-hosting contract: the byte-identical two-generation fixpoint, the bootstrap workflow, @platform tags, recurring porting-bug patterns, and the natural-code principle. Use when modifying the compiler, porting a pass to Super-C, or debugging fixpoint failures."
allowed-tools: Bash Read
---

# Super-C Self-Hosting

## Agent checklist

- Treat any gen-1 versus gen-2 diff as a correctness failure.
- Follow the clean-room fixpoint reference: identical source and library paths, caches disabled.
- Fix compiler defects instead of adding source workarounds.
- Follow the new-syntax cadence when parser, attribute, or manifest syntax changes.

The Super-C compiler is self-hosting: it compiles itself. This is a hard correctness
contract, not a development convenience.

## The Fixpoint Contract

Gen-1 (the compiler built by itself) compiles its own source to produce gen-2. The
native binaries produced at the same path with the same options must be
**byte-identical**. The gate also compares C emission and native objects across
worker counts. Any difference is a correctness failure.

The current documentation baseline is recorded in `skills/README.md` as a git tag.

## The Bootstrap Workflow

```sh
super-c command bootstrap
```

This runs three steps:
1. Current compiler builds stage-1 with bootstrap tags (`--bootstrap-tags`)
2. Stage-1 builds stage-2
3. Stage-1 is removed

The verified binary is stage-2.

See [fixpoint-verification.md](references/fixpoint-verification.md) for the clean-room
diff protocol.

## The Natural-Code Principle

A workaround for natural Super-C code **is** a compiler bug. The correct response is:

1. Fix the compiler.
2. Write the natural code.

If the root-cause fix is unclear, unsafe, or too large, **stop and ask** before adding a
workaround. Do not ship a workaround and move on.

This principle is what makes self-hosting a correctness tool: every language feature the
compiler uses must work correctly, because the compiler is the most exercised user of its
own language.

## Recovery from a Broken Compiler

A compiler that over-rejects valid source cannot rebuild itself, and reverting the source does
not help. Download the release binary as `check.sh` does
(`gh release download --pattern super-c-macos-arm64.tar.gz`), build the source with it as
`check.sh` does (`build --bootstrap-tags`), then continue with the rebuilt compiler.

## Single Compilation Path

Only the multi-file `build/` tree emitter exists. The single-TU emitter and REPL were
deleted. One path eliminates divergence bugs: every output path that exists must be
correct, and maintaining two doubles the surface area.

## Reference files

Read only the file the task needs. Section names are kept, so a pointer such as
"see Header Types" names a heading in one of these files.

- [bootstrap.md](references/bootstrap.md): bootstrap sequence and rollback boundary, @platform bootstrap tags, new syntax cadence, runtime helpers called by std, platform lanes.
- [porting-bugs.md](references/porting-bugs.md): porting-bug patterns and cosmetic deltas.
