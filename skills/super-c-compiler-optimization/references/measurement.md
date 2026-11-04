# Measurement Protocol

## Measurement Protocol

### Before starting

```sh
# Clean build from scratch (cache can serve stale data): removes build/ and the global cache
super-c clean --full
super-c build
```

### The A/B protocol

1. Build the **before** binary from a clean tree.
2. Run `super-c bench` 3 times, record Mcyc and Kalloc for each.
3. Apply the optimization.
4. Build the **after** binary from a clean tree.
5. Run `super-c bench` 3 times, record Mcyc and Kalloc for each.
6. Interleave: run before, after, before, after, before, after (on a quiet machine).

Rules for a valid A/B:
- Build both binaries with the same gates and switches. A binary with runtime counters
  compiled in against one without them gave 300 to 800% false regressions.
- A change is a regression only when the median moves more than its own three-run spread
  (about 5%).
- On macOS the cycle counts come from `proc_pid_rusage` (`std/testing/bench_sys.spc`) and
  include kernel time of every thread.
- For clean C-compile timings, set `SC_NO_CACHE=1 SC_NO_EMIT_CACHE=1 SC_NO_TU_CACHE=1`;
  otherwise a cache makes the "clean" build fast.
- Never pipe a gate into another command (`./check.sh | tail`): the pipeline returns the
  status of the last command. Write the output to a file, then read it.

Between steps, check byte identity on a fixed reference tree before the full gate: copy
each compiler in turn to the same path beside `std`/`ffi`, build the reference sources
with `--jobs=1` and again with every core into separate `--out-dir`s
(`SC_NO_CACHE=1 SC_NO_TU_CACHE=1`), and `diff -rq` each `<out-dir>/<profile>/raw` tree
against the baseline compiler's tree. The emitted tree does not depend on the out-dir,
so require an empty diff. This takes seconds and localizes a reordering to the change
that caused it; `ci/gate.sh` confirms at the end.

### What to report

- Mcyc change (cycles, not wall-clock), with the run's median and p95
- Kalloc change (allocation count), and for emitter work the probe table's per-region
  allocation calls (`SC_CEMIT_STATS=1 SC_BUILD_STATS=- SC_BUILD_MEM=1`)
- Heap delta (peak RSS if available)
- Whether the fixpoint holds (gen-1 vs gen-2 diff)
- Whether tests pass

### Whole-build phases

`SC_BUILD_STATS=- super-c build` prints one JSON record for the real build path: every
phase of the partition (setup, stamp, load, resolve, typecheck, borrowck, checks, prepare,
plan, render, publish, sync, compile, link; their sum is `total`), the streamed C
compile that overlapped emission (`cc`, never added to the total), and peak RSS at
the frontend, borrowck, plan, publish and build boundaries. `SC_BUILD_MEM=1` adds the
allocation tracker's counts, requested and live bytes, and the survivors of each
phase (slower: only for memory questions).

### Transpile work count (CI)

Hosted runners are VMs without hardware counters (Linux `perf stat` reports `<not supported>`,
macOS prints no instructions retired, Windows lists only the `Timer` source), so CI counts work
in the compiler itself. The Release workflow's `counts` jobs (`.github/actions/transpile-counts`)
build two compilers with clang from their release profile's C (`--emit-c`, `ci/cc_tree.sh`, with
`-DNDEBUG -fprofile-instr-generate`; llvm-mingw's clang on Windows, whose mingw profile runtime the
preinstalled LLVM lacks): this commit's, and the last release's from its tag by its own binary.
Both run a cold `build --jobs=1 --emit-c --bootstrap-tags` of this commit's sources, and
`llvm-profdata` totals the counters. The same input makes the change the compiler's alone: the
compiler's sources grow every release, which moves a count of one compiler across releases by
0.1 to 1%. A total repeats within 0.0001% on every runner and does not move with the
optimization level or the CPU. It counts only the compiler's frontend and C emission: libc, the
kernel and the native backend are outside it, and so is a change that makes the code slower without
changing which code runs. One worker is required: the counters are not atomic, and a multi-threaded run
loses increments (1.2% spread). The totals differ by platform (different platform code), so
compare a platform only with itself.

A growth of 0.1% or more is a warning annotation. 1% or more, or a count that failed, is an
error annotation and a caution box in the summary: the release is still packaged, and its
publishing waits in the `counts approval` job for the owner's approval in the `release-approval`
environment (its required reviewer makes the wait; a missing environment is created without one
and does not wait). The job summary lists the modules that moved most (a module is the mangled
prefix before the first `__`). The `transpile counts` job keeps one `transpile-counts` artifact
with each platform's `.tsv` and `.profdata` files.

### SIMD baselines

`bench/simd_baseline/` holds the reference numbers for vector code. `kernels.spc` has eleven
kernels as plain scalar loops (`saxpy_f32`, `dot_f32_ordered`, `dot_f32_tree`, `count_eq_u8`,
`sum_i32`, `min_max_f32`, `filter_gt_f32`, `gather_sum_f32`, `tail_load_f32`, `mix_width`,
`abs_diff_u8`); each instruction set has the same kernels in C intrinsics (`sse2.c`, `avx2.c`,
`avx512.c`, `neon.c`, `simd128.c`), each behind an `@arch`-gated `extern "C" "<name>.h"` block
that returns its table (`sb.h`). The C kernels come prebuilt: `sh bench/simd_baseline/kernels.sh`
(record.sh runs it; `--target=wasm` for SIMD128) archives the target's files into
`build/simd_baseline/<arch>/libsimd_baseline.a`, which the blocks' `@link` names; a benchmark build
of `simd_baseline` without it fails to link. The AVX2 and AVX-512 tables are null on a CPU without the
features. The scalar loop defines each result: every implementation gives its bits (any NaN
counts as one value). `first_mismatch` checks that on inputs of every tail length, in modes that
put NaNs, zeros of both signs in both orders and all-equal bytes into every lane; the
`simd_baseline` benchmark runs it before it times anything, so the wasm run checks SIMD128,
and `tests/simd/simd_baseline_test.spc` runs it on the host's instruction sets: it archives the host's
kernels and builds a program over the module in a scratch project, so the suite links no kernel. Every round
repeats one input: at 4 KiB and 64 KiB its branches fit the branch predictor, so a
scalar loop that compiles to a data-dependent branch (`filter_gt_f32`, and `mix_width` and
`min_max_f32` under gcc) reads faster there than at 4 MiB.

- `baseline.tsv`: the median ns per element of each kernel, instruction set and input size
  (4 KiB, 64 KiB, 4 MiB), per machine and C compiler, under the `bench` profile.

`sh bench/simd_baseline/record.sh` measures the current machine and the C compiler of the kernels
and replaces their rows in `baseline.tsv`; its arguments go to `super-c bench` and `super-c build`
(`--target=wasm` for SIMD128 under wasmtime). Run it with `./super-c` built from the measured
commit. The SIMD workflow (`.github/workflows/simd.yml`) runs only on dispatch from the Actions tab:
it runs it on every CI platform and uploads the file per platform; merge their rows into the
committed file.

### Borrow-check probe and budget

`SC_BORROW_STATS=1 SC_BUILD_STATS=- super-c build --jobs=1 --out-dir=<fresh>` prints the
borrow probe (regions, skip tallies, sizes, slowest bodies, retained scratch); add
`--emit-c` for a frontend-plus-emission run with no native compile or link.
Always a fresh out-dir: the emit stamp otherwise reports `borrowck: 0`. The regions sum to
the build record's `borrowck` phase less a few ms of loop overhead (the stage's prologue
is `publish` and `reach`, the kept copies `keep`). Measured split on the reference sources
(serial release, macOS): at 4,100 bodies (2026-09) lowering 18 ms, replay 13 ms and the
analyses (forest, facts, cfg, liveness, moves, solver, rules) about 64 ms and 15k
allocations, down from 76 ms and 129k; at 7,300 bodies (2026-10) lowering about 43 ms and
replay about 24 ms (required work), the analyses about 108 ms and 8k allocations (facts
45, solver 35, moves 11, liveness 6, rules 5, forest 3, cfg 3): the same 15 us per body,
so the corpus growth, not a per-body regression, moved the totals. Budget for the
analyses, gate the row before accepting a change: analysis time <= 115 ms (16 us per
body: rescale it with the `bodies` count of the probe), analysis allocations <= 20k,
retained scratch <= `BC_SCRATCH_BUDGET` after any body, the borrow probe's `drops` region
(the elaboration of every kept body) <= 12 ms and <= 2k allocations (measured 2026-10:
10.7 ms and 103), the emission `drops` region (bounds-check elimination plus the
elaboration of the bodies emission lowers itself, with the `ir/facts.spc` effect and version
service) <= 36 ms and <= 600 allocations serial (measured 2026-10: 32-34 ms and 575), and
`SC_BC_VALIDATE=1` builds (serial and every core) clean. The parallel path adds slot pooling, so its allocation count sits
near the serial one plus one stack per worker.

### Instance discovery and re-lowering budget

The emission probe's `graph` region and the `cemit-stage collect` line (records by kind,
bodies walked, rounds, a budget stop) are the instance discovery numbers; the
`relower-refl`/`relower-zst` regions and the re-lowering census are the specialization
numbers ([instance-specialization.md](../../super-c-compiler-internals/references/instance-specialization.md)).
Budget on the reference sources, serial release: `graph` <= 34 ms and <= 50k
allocations, 3 rounds, no budget stop (measured 2026-10: 32 ms, 27k allocations, 32k
records. The older 20 ms budget predates the corpus growth and exact const-generic folding,
which keeps 6 more width-doubling levels of the speculative `UInt`/`IntBits` chain alive,
until a limb array leaves the array length range; the same sources take 27-28 ms with the
compiler from before exact folding); both re-lowering regions together <= 1 ms; the
type-stats probe steps within 2x of the intern hits. The test target of `super-c test`
is the generic-heavy corpus: its collect line reports a budget stop today (the
width-generic integer's closure), so a change there is judged by its record count and
`graph` time against the record's table, never by the self-build alone. `super-c test`
first builds the compiler with the invoking binary, so its second stats record and probe
table are the test corpus.

### Bench gate policy

Keep changes that:
- Reduce asymptotic complexity (even if the current corpus shows no immediate win)
- Reduce memory usage (even if cycle count is flat)
- Reduce allocation count (even if cycles are flat)

Revert changes that:
- Win nowhere (no cycle, memory, or allocation improvement)
- Break the fixpoint
- Regress another metric more than they improve their target
