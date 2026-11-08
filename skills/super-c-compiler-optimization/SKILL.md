---
name: super-c-compiler-optimization
description: "Guides performance optimization of the Super-C compiler itself: profiling protocol, hotspot analysis, struct compaction, allocation elimination, complexity reduction, assembly analysis, and the byte-identical fixpoint contract. Use when optimizing compiler passes, reducing build times, or investigating performance regressions."
allowed-tools: Bash Read
---

# Super-C Compiler Optimization

## Agent checklist

- Profile the release or bench binary before selecting a target.
- Check the build's optimizer (`lir::opt`) before keeping a micro-optimization.
- Measure the serial benchmark in interleaved A/B runs.
- Verify byte-identical self-hosting output after structural changes.

This skill covers optimizing the **compiler itself**. Generated-code changes can use
release self-builds or focused temporary benchmarks to measure their effect. Every
compiler change must preserve the byte-identical two-generation native fixpoint.
The correctness gate also checks deterministic C emission and native objects across worker counts.

## Hard Contracts

Before any optimization work, understand these non-negotiable constraints:

1. **Byte-identical fixpoint.** Every change must preserve the gen-1 vs gen-2 native
   binary comparison. A difference is a correctness failure. See
   [fixpoint.md](references/fixpoint.md) for the verification protocol.

2. **Optimizer gate.** Know which optimizer built the binary, and do not keep a
   micro-optimization it already performs. The `release` and `bench` profiles build
   natively: the LIR optimizer (`lir::opt`, super-c-compiler-internals, "LIR") inlines
   small bodies across modules, numbers values, forwards loads and stores, promotes the
   loads of private memory one store writes, moves invariant code out of loops and folds
   constants and branches, expands a `memcmp` of a known count (`memcmp_eq`: at most 32
   bytes, 64 for an equality), forwards copied arguments (`copied_args`), and forwards private-copy loads
   (`private_load`); at 2 and 3 it also vectorizes counted loops over slices, and every level's
   passes and flags are in the binary skill ("Optimization levels and code-generation
   flags"). If a target shows ~0 samples under the build's optimizer, the optimization will
   not produce a corpus-level win.

3. **Benchmark protocol.** Measure with `super-c bench --filter=self_compile` (25 rounds
   of a whole cold native build of the compiler at the release profile with one job, then
   25 with one job per core, each timed per build phase from setup to link, the backend's
   lower, optimize and codegen included); `--filter=self_transpile` times the front end
   and the C emission (`--emit-c`) in 100 serial rounds.
   Judge on **Mcyc/Kalloc**, not wall-clock ms (clock frequency varies 2.0–3.8 GHz
   between E/P cores and thermal state); the run prints min/median/p95/sd of every
   round, and a wide spread means the box was not quiet. First run after a rebuild is
   a cold outlier. Ignore it. Run 3x interleaved A/B on a quiet machine. A run that
   reports a compile or link failure exits nonzero and measures nothing.
   Run the benchmark binary directly (`build/bench-bin`). The lane's peak RSS is the process peak over all rounds, the
   jobs=18 rounds included: the macOS allocator keeps freed memory between rounds (no leak: flat under
   `SC_LEAK_CHECK=1`), so it reads about 1.1 to 1.2 GiB while one cold build of the compiler peaks near
   570 MiB at jobs=1 and 700 MiB at jobs=18. Of a build's peak, about 250 MiB is memory the allocator
   kept after frees (live bytes peak near 390 and 450 MiB, in borrowck); a trim at each phase boundary
   cut a jobs=18 build's peak by about 40 MiB but cost 0.5% cycles and raised the lane's peak.

## Rationalizations to Reject

- **"This function looks slow."** Profile it. Intuition is wrong more often than right.
- **"I'll optimize this loop later."** If it is not hot, do not touch it. If it is hot,
  fix it now.
- **"The benchmark is too small to show a difference."** The self-transpile benchmark
  corpus is the ground truth. Inspect its current size from `bench/` before judging a
  corpus-scale result.
- **"The optimizer will fix it."** Check. Profile the build the change targets (the release
  or bench profile). If its optimizer already optimizes the site, your
  change is dead weight.
- **"I'll add parallelism to make it faster."** Serial optimization first. The serial
  reference pipeline must be fast on its own.
- **"Allocations don't matter, the allocator is fast."** Every allocation is a cache
  pollution event. In hot loops, it is the dominant cost.

## Reference files

Read only the file the task needs. Section names are kept, so a pointer such as
"see Header Types" names a heading in one of these files.

- [phases.md](references/phases.md): phases 0 to 6: profile, hotspots and allocations, hot structs, complexity, stack over heap, assembly, compiler-specific work.
- [measurement.md](references/measurement.md): before starting, the A/B protocol, what to report, whole-build phases, transpile work count, SIMD baselines, borrow-check probe, instance budget, bench gate.
