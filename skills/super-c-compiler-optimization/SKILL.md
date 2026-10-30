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

This skill covers optimizing the **compiler itself** (the self-hosting Super-C transpiler),
not the code it generates. Every optimization must preserve the byte-identical
two-generation fixpoint: the emitted C from gen-1 and gen-2 must be identical byte for
byte.

## Hard Contracts

Before any optimization work, understand these non-negotiable constraints:

1. **Byte-identical fixpoint.** Every change must preserve the gen-1 vs gen-2 emitted-C
   diff. A non-empty diff is a semantic regression. See
   [fixpoint.md](references/fixpoint.md) for the verification protocol.

2. **Optimizer gate.** Know which optimizer built the binary, and do not keep a
   micro-optimization it already performs. The `release` and `bench` profiles build
   natively: the LIR optimizer (`lir::opt`, super-c-compiler-internals, "LIR") inlines
   small bodies across modules, numbers values, forwards loads and stores, promotes the
   loads of private memory one store writes, moves invariant code out of loops and folds
   constants and branches; it does not lower fixed-size `memcmp` or forward copies
   between slots; at 2 and 3 it also vectorizes counted loops over slices, and every level's
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
   Run the benchmark binary directly (`build/bench-bin`). The lane's peak RSS is the process peak over all rounds: the macOS allocator keeps about
   12 MiB more after each round until it trims (no leak: flat under `SC_LEAK_CHECK=1`),
   so it reads 630 to 730 MiB while one serial build peaks near 190 MiB.

## Optimization Phases

Work through these phases in order. Each phase grounds the next: do not skip ahead.

### Phase 0: Profile (grounded proof, not guesswork)

**Never guess what to optimize.** Every optimization must start from profiled evidence.

```sh
# Build the transpile lane alone, without running it
super-c bench --no-run --filter=self_transpile

# Profile with samply (1000 Hz is samply's default rate; raise it for short runs)
samply record --rate 1000 build/bench-bin --in-process --filter=self_transpile
```

`build/bench-bin` runs each benchmark in a forked child unless given `--in-process`, and samply on
macOS follows an exec, not a fork: without the flag a capture holds the parent's few samples alone.
Build the lane alone: the coroutine and cancellation reachability is package-wide, so a binary
that also holds the concurrency benchmarks (they cancel tasks) emits a cancellation tick in
every task-reachable loop of the compiler (3,590 against 2) and a probe after 229 calls (against 6),
and its compiler code is not the code a build runs.
`build/bench-bin` runs every benchmark it holds unless filtered: unfiltered, concurrency I/O and
scheduler idle time took about 44% of the samples. Filter the run or the profile before
you conclude. `super-c bench` builds `bench-bin` with the compiler that runs it, so an
emitter change shows in the benchmark only when the new compiler runs `bench`.

**Run samply 10–15 times minimum** to capture stable, statistically significant data.
Single-run profiles miss intermittent hotspots and are skewed by cache state. A function
that is hot in 12/15 runs is a real target; one that appears in 2/15 is noise.

If `[command.profile]` is defined in `build.toml`:

```sh
super-c command profile
```

**Headless capture (required for agents, useful for scripted runs):** by default samply
opens the Firefox Profiler UI in a browser, which cannot be read programmatically.
`--save-only` skips the UI, and `--unstable-presymbolicate` writes a `.syms.json`
sidecar. Without it, native frames in the saved JSON are unsymbolicated hex addresses:

```sh
# Capture N runs headlessly (each run writes profile + symbol sidecar)
for i in $(seq 1 15); do
  samply record --save-only --unstable-presymbolicate \
    -o "prof-$i.profile.json.gz" build/bench-bin --in-process --filter=self_transpile
done

# Aggregate all runs into one hotspot ranking (runs-present, then total samples)
python3 <skill_dir>/scripts/samply_top.py prof-*.profile.json.gz

# Reopen any saved profile in the UI later
samply load prof-1.profile.json.gz
```

`scripts/samply_top.py` resolves each frame address against the sidecar symbol tables and
ranks functions by how many runs they appear in, then by total samples: a one-run fluke
sorts below a hotspot that shows up everywhere.

Two macOS gotchas, both verified:
- samply cannot profile Apple-signed system binaries (it reports the DYLD restriction);
  the locally-built compiler profiles fine.
- **Profile the bench binary, never a debug build.** The debug profile is unoptimized, so its
  hotspots are not the release build's.
- To profile a compiler run directly, build the compiler under the `bench` profile (the
  `release` profile strips symbols) and make it samply's root process: no `env` or `sh`
  wrapper between them.

(`samply record --pid <PID>` attaches to a running process; run `samply setup` once
first on macOS to self-sign the samply binary.)

Before sampling, read the emitter's own region table: `SC_CEMIT_STATS=1 SC_BUILD_STATS=-
SC_BUILD_MEM=1 build/<release-compiler> build --jobs=1` prints per-region wall time,
calls, allocation calls and bytes for C generation (graph, acquire, relower-refl, relower-zst, inline,
drops, sym, decl, render, assemble, publish, sync) plus the repeated-work tallies. It
names the region to profile and records allocation counts a sampler cannot.

What to capture from each profile:
- Top functions by inclusive and exclusive sample counts
- Call chains into hot functions (who calls them, how often)
- Allocation sites (look for `malloc`/`realloc`/`calloc` in hot paths)
- Cache miss indicators (wide stride patterns, pointer chasing)

### Phase 1: Analyze Hotspots and Eliminate Allocations

With profiled hotspots in hand, attack the highest-impact targets first.

**Allocation elimination in hot paths:**

- **Preallocate.** Replace per-call `Vector::new()` with a scratch field on the pass
  context, cleared between uses. The compiler already uses this pattern:
  `CEmit`/`CFlow`/`Lowerer`/`DropCtx` all carry pooled scratch fields cleared per body.

- **Stack over heap.** Replace `Vector<T>` with `Array<T, N>` for bounded data. The
  resolver already uses `[NodeId; 32]` fixed arrays for chain lookups. Identify the
  maximum bound from the domain, not from test inputs.

- **Out-parameters over return allocations.** Pass a `&mut` to an existing buffer instead
  of returning a new allocation. The borrow checker validates this pattern is safe.

- **Spell into the destination.** A renderer that builds a temporary string and copies
  it into its destination allocates once the text passes the 23-byte inline capacity.
  Write the pieces into the destination in order; keep a temporary only when the text is
  needed twice or after later text, and take it from the pass's scratch pool. The
  render order must not move (see "Spell in place without reorder" in
  [references/compiler-patterns.md](references/compiler-patterns.md)).

- **Arena/pool reuse.** When a phase processes many items (bodies, types, nodes), allocate
  a single arena or scratch pool at phase start and reset it per item. Do not
  allocate/free per item.

Hot-path allocation checklist:
1. Find every `Vector::new()`, `String::from_str()`, `Map::new()` in the profiled hot
   functions.
2. For each: can the container be hoisted to the parent scope or the pass context?
3. For each: is the maximum size bounded? If yes, use a fixed array.
4. For each: is the allocation only used within a single loop iteration? If yes, clear
   and reuse instead of create and destroy.

### Phase 2: Compact Hot Structs

Smaller structs mean fewer cache misses. The target is the **next lower power of 2** in
bytes.

**Why compaction:** Decompacting (a shift or mask to recover a field) is cheaper than
the cache miss a larger struct causes. The compiler already uses this: `Token` is a
packed `u64`, not a struct: bits 0–31 start offset, 32–55 length, 56–63 kind
(`src/lexer/token.spc`). `Node` is kept dense (currently 32 bytes, align 4: the payloads
larger than 20 bytes live in the arena's `NodeExt` table; the generated C carries
`_Static_assert(sizeof(ast__Node) == 32 && _Alignof(ast__Node) == 4)` so any drift is a
build error).

**How to compact:**

1. **Measure current size.** Use `static_assert(sizeof(T) == N, "...")` or grep the
   emitted layout asserts in `build/<profile>/raw/` (`_Static_assert(sizeof(<mangled>) == N`).
   Never hand-compute: padding and alignment are target-dependent.

2. **Identify waste.** Look for:
   - Booleans stored as full bytes or words (pack into a flags bitfield)
   - Enum discriminants wider than necessary (a 4-variant enum needs 2 bits, not 32)
   - Pointer-sized fields that could be indices into a pool (32-bit index = 4 bytes
     vs 8-byte pointer)
   - Padding holes in a type that keeps its declared order (`@ordered`, `@packed`, a header
     type, a C-reachable struct): reorder its fields by hand. The compiler orders the others by
     alignment, so a hole there is only the tail padding to the largest alignment
   - Fields that are mutually exclusive (overlap in a union)

3. **Pack the bits.** Use bitfields, byte-width fields, or manual bit packing:
   ```superc
   // Before: 3 bools + padding = 4-8 bytes of waste
   struct Flags { is_pub: bool, is_mut: bool, is_used: bool }
   
   // After: all three in one u8
   // bit 0 = pub, bit 1 = mut, bit 2 = used
   ```

4. **Verify.** Add a `static_assert` for the new size. Run the benchmark. Confirm the
   fixpoint holds.

**Do not unpack something already packed.** `Token` is a 64-bit packed value by design:
unpacking it into a struct would regress every pass that touches tokens.

### Phase 3: Reduce Algorithmic Complexity

Even constant-factor improvements matter at compiler scale. The ordering:

```
... → O(n²) → O(n log n) → O(n log log n) → O(n) → O(log n) → O(1)
```

**Constant factors matter too.** `O(5n)` is slower than `O(3n)` in practice, even though
theory treats them as equivalent. When lowering the big-O class is not possible, reduce
the constant factor.

Common patterns in the compiler:

| Pattern | Problem | Fix |
|---------|---------|-----|
| Linear scan for name lookup | O(n) per lookup, O(n²) total | Hash map or sorted + binary search |
| Nested loop over all pairs | O(n²) | Sort + merge, or hash-based grouping |
| Repeated linear search in a list | O(n) per search | Index or hash the list once |
| String comparison for type identity | O(len) per compare | Intern strings, compare pointers |
| Rebuilding a set every iteration | O(n) per iter | Incremental update |
| Full container copy for filtering | O(n) allocation | In-place `retain` or swap-remove |

The compiler already interns strings and uses hash maps for symbol tables. When adding a
new lookup, check whether an existing interning table covers it.

**Overload resolution** and **instance propagation** are the passes most likely to harbor
hidden quadratic behavior. Profile them specifically on large generic-heavy inputs.

### Phase 4: Stack Over Heap

The stack is faster than the heap: no allocator overhead, no fragmentation, perfect
spatial locality, automatic cleanup.

**When to use the stack:**
- Temporary buffers with a known maximum size
- Small fixed-size containers (< 256 bytes)
- Scratch space that lives only within a single function call
- Out-parameters that replace returned heap allocations

**Proven patterns in the compiler:**
- `[NodeId; 32]` fixed arrays for resolver chain lookups
- `FlowState` out-param: save/clear into uninitialized stack locals instead of `memset`
  copies
- Pooled scratch fields on pass contexts (`CEmit`, `CFlow`, `Lowerer`, `DropCtx`),
  cleared per body instead of reallocated

**When NOT to use the stack:**
- Data whose size depends on user input with no tight bound
- Large allocations (> 4 KB) that risk stack overflow
- Data that must outlive the current scope
- Data shared across threads (use `Arc`)

### Phase 5: Analyze Generated Assembly

When all higher-level theories are exhausted and the profiler still shows a hot function,
inspect the native assembly the backend generates.

```sh
# Build the release binary
super-c release

# Disassemble a specific function
objdump -d build/super-c | grep -A 100 '<function_name>'

# Or use the samply profile's assembly view
```

What to look for:
- **Scalar loops**: `SC_VEC_REPORT=1` gives the reason the vectorizer left a loop scalar; a
  hot loop it cannot take uses `std::simd` explicitly
- **Branch misprediction**: a hot branch with poor prediction (reorder to put the common
  case first, or convert to branchless with conditional moves)
- **Redundant loads**: the same memory loaded repeatedly because the optimizer cannot
  prove no aliasing (cache the value in a local)
- **Unnecessary sign/zero extensions**: type mismatches between 32-bit and 64-bit values
  causing extension instructions on every use
- **Unaligned accesses**: struct fields crossing cache lines (fix with field reordering
  or `@align`)
- **Spill-heavy functions**: too many live variables forcing register spills to the stack
  (split the function, reduce live variable count)

### Phase 6: Compiler-Specific Optimizations

Beyond the general phases, these patterns are specific to the Super-C compiler's
architecture.

**See [compiler-patterns.md](references/compiler-patterns.md) for the full catalogue.**

Summary:
- **Safe cache patterns:** index-over-truncatable-Vector (store index + verify), lazy
  cache via const-cast (single-threaded per compile), prefilter-without-reorder
  (preserves interning/emit order → byte-identical)
- **Memo grain:** must exceed probe cost. Gate by node shape, never blanket.
- **Hot-loop value caching:** cache repeated accesses explicitly when aliasing or
  compiler limits block hoisting.
- **Data-plane / control-plane separation:** keep diagnostics, recovery, and error
  reporting out of the hot data-processing loops.
- **Interning deduplication:** reuse existing interning tables. Do not build a second
  hash map for data already interned elsewhere.
- **Compute once, pass on:** a fact the compiler already holds is reused, never rebuilt.
  Each of these was a measured cost: the emit stamp read and hashed again the sources the
  loader had read (now `Module.src_id`), the C tree was written twice (raw, then gen),
  `IMPLIED` was evaluated five times, the gen tree was listed twice on a no-op build, and
  the object-cache key read back files the sink had just written. Before you add a walk,
  hash, file read, or evaluation, find the stage that already has the value and take it
  from there: apply the procedure in `super-c-task-discipline` section 10 and check the
  analysis inventory (`super-c-compiler-internals`, `references/analyses.md`). The forms of
  duplicate work to look for are in compiler-patterns.md, "Duplicate Analysis and Work".
- **Body-sharing for generic instances:** when multiple monomorphizations share the same
  lowered body, emit once and reference.
- **Rejected levers:** read the measured list in "What to Avoid" before you try a lever.

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
numbers ([instance-specialization.md](../super-c-compiler-internals/references/instance-specialization.md)).
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
