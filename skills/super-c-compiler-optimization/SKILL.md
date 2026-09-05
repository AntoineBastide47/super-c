---
name: super-c-compiler-optimization
description: "Guides performance optimization of the Super-C compiler itself: profiling protocol, hotspot analysis, struct compaction, allocation elimination, complexity reduction, assembly analysis, and the byte-identical fixpoint contract. Use when optimizing compiler passes, reducing build times, or investigating performance regressions."
allowed-tools: Bash Read
---

# Super-C Compiler Optimization

## Agent checklist

- Profile the release or bench binary before selecting a target.
- Check the LTO profile before keeping a micro-optimization.
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

2. **LTO gate.** Gate LTO first. Do not keep a micro-optimization that LTO already
   performs — at `-O3 -flto`, Clang inlines same-TU hot calls, CSEs `strlen` of literals,
   and lowers fixed-size `memcmp` to branchless compares. Check the LTO profile
   checkpoint before implementing. If a target shows ~0 samples under LTO, the
   optimization will not produce a corpus-level win.

3. **Benchmark protocol.** Measure with `super-c bench --bench-filter=self_transpile`
   (100 serial self-transpile rounds, then one cold real build through the engine).
   Judge on **Mcyc/Kalloc**, not wall-clock ms (clock frequency varies 2.0–3.8 GHz
   between E/P cores and thermal state); the run prints min/median/p95/sd of every
   round, and a wide spread means the box was not quiet. First run after a rebuild is
   a cold outlier — ignore it. Run 3x interleaved A/B on a quiet machine. A run that
   reports a C compiler or linker failure exits nonzero and measures nothing.
   `sh ci/perf_gate.sh` compares a run with the accepted constants in `ci/baseline.env`
   (every later percentage gate resolves against those); run the benchmark binary
   directly (`build/bench-bin`), never as a child of the ASan dev compiler, whose
   injected sanitizer runtime changes the allocator and the peak RSS it reports.

## Optimization Phases

Work through these phases in order. Each phase grounds the next: do not skip ahead.

### Phase 0 — Profile (grounded proof, not guesswork)

**Never guess what to optimize.** Every optimization must start from profiled evidence.

```sh
# Build the benchmark binary without running it
super-c bench --no-run

# Profile with samply (1000 Hz is samply's default rate; raise it for short runs)
samply record --rate 1000 build/bench-bin
```

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
sidecar — without it, native frames in the saved JSON are unsymbolicated hex addresses:

```sh
# Capture N runs headlessly (each run writes profile + symbol sidecar)
for i in $(seq 1 15); do
  samply record --save-only --unstable-presymbolicate \
    -o "prof-$i.profile.json.gz" build/bench-bin
done

# Aggregate all runs into one hotspot ranking (runs-present, then total samples)
python3 <skill_dir>/scripts/samply_top.py prof-*.profile.json.gz

# Reopen any saved profile in the UI later
samply load prof-1.profile.json.gz
```

`scripts/samply_top.py` resolves each frame address against the sidecar symbol tables and
ranks functions by how many runs they appear in, then by total samples — a one-run fluke
sorts below a hotspot that shows up everywhere.

Two macOS gotchas, both verified:
- samply cannot profile Apple-signed system binaries (it reports the DYLD restriction);
  the locally-built compiler profiles fine.
- **Profile the bench binary, never the dev build.** The dev profile carries
  ASan/UBSan, and sanitizer frames (`__asan_memcpy`, `StackDepotBase::Put`) dominate the
  profile, burying the real hotspots.

(`samply record --pid <PID>` attaches to a running process; run `samply setup` once
first on macOS to self-sign the samply binary.)

What to capture from each profile:
- Top functions by inclusive and exclusive sample counts
- Call chains into hot functions (who calls them, how often)
- Allocation sites (look for `malloc`/`realloc`/`calloc` in hot paths)
- Cache miss indicators (wide stride patterns, pointer chasing)

### Phase 1 — Analyze Hotspots and Eliminate Allocations

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

### Phase 2 — Compact Hot Structs

Smaller structs mean fewer cache misses. The target is the **next lower power of 2** in
bytes.

**Why compaction:** Decompacting (a shift or mask to recover a field) is cheaper than
the cache miss a larger struct causes. The compiler already uses this: `Token` is a
packed `u64`, not a struct — bits 0–31 start offset, 32–55 length, 56–63 kind
(`src/lexer/token.spc`). `Node` is kept dense (currently 60 bytes, align 4 — the
generated C carries `_Static_assert(sizeof(ast__Node) == 60 && _Alignof(ast__Node) == 4)`
so any drift is a build error).

**How to compact:**

1. **Measure current size.** Use `static_assert(sizeof(T) == N, "...")` or grep the
   emitted layout asserts in `build/*/gen/` (`_Static_assert(sizeof(<mangled>) == N`).
   Never hand-compute — padding and alignment are target-dependent.

2. **Identify waste.** Look for:
   - Booleans stored as full bytes or words (pack into a flags bitfield)
   - Enum discriminants wider than necessary (a 4-variant enum needs 2 bits, not 32)
   - Pointer-sized fields that could be indices into a pool (32-bit index = 4 bytes
     vs 8-byte pointer)
   - Padding holes from field ordering (reorder fields by alignment, largest first)
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

**Do not unpack something already packed.** `Token` is a 64-bit packed value by design —
unpacking it into a struct would regress every pass that touches tokens.

### Phase 3 — Reduce Algorithmic Complexity

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

### Phase 4 — Stack Over Heap

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

### Phase 5 — Analyze Generated Assembly

When all higher-level theories are exhausted and the profiler still shows a hot function,
inspect the native assembly the C compiler generates.

```sh
# Build the release binary
super-c release

# Disassemble a specific function
objdump -d build/super-c | grep -A 100 '<function_name>'

# Or use the samply profile's assembly view
```

What to look for:
- **Missed vectorization** — a loop the compiler should have auto-vectorized but did not
  (check for data dependencies or aliasing that block it)
- **Branch misprediction** — a hot branch with poor prediction (reorder to put the common
  case first, or convert to branchless with conditional moves)
- **Redundant loads** — the same memory loaded repeatedly because the C compiler cannot
  prove no aliasing (cache the value in a local, use `restrict` via the emitter)
- **Unnecessary sign/zero extensions** — type mismatches between 32-bit and 64-bit values
  causing extension instructions on every use
- **Unaligned accesses** — struct fields crossing cache lines (fix with field reordering
  or `@c.align`)
- **Spill-heavy functions** — too many live variables forcing register spills to the stack
  (split the function, reduce live variable count)

### Phase 6 — Compiler-Specific Optimizations

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
- **Body-sharing for generic instances:** when multiple monomorphizations share the same
  lowered body, emit once and reference.

## Measurement Protocol

### Before starting

```sh
# Clean build from scratch (cache can serve stale data)
super-c clean
super-c build
```

### The A/B protocol

1. Build the **before** binary from a clean tree.
2. Run `super-c bench` 3 times, record Mcyc and Kalloc for each.
3. Apply the optimization.
4. Build the **after** binary from a clean tree.
5. Run `super-c bench` 3 times, record Mcyc and Kalloc for each.
6. Interleave: run before, after, before, after, before, after — on a quiet machine.

### What to report

- Mcyc change (cycles, not wall-clock), with the run's median and p95
- Kalloc change (allocation count)
- Heap delta (peak RSS if available)
- Whether the fixpoint holds (gen-1 vs gen-2 diff)
- Whether tests pass

### Whole-build phases

`SC_BUILD_STATS=- super-c build` prints one JSON record for the real build path: every
phase of the partition (stamp, load, resolve, typecheck, borrowck, checks, prepare,
plan, render, publish, sync, compile, link; their sum is `total`), the streamed C
compile that overlapped emission (`cc`, never added to the total), and peak RSS at
the frontend, borrowck, plan, publish and build boundaries. `SC_BUILD_MEM=1` adds the
allocation tracker's counts, requested and live bytes, and the survivors of each
phase (slower: only for memory questions). `sh ci/bench_matrix.sh` runs the clean /
unchanged / body-edit / signature-edit / layout-edit / release-relink matrix with
those records and writes `build/matrix/report.md`.

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
- **"LTO will fix it."** Check. Run the LTO profile. If LTO already optimizes the site,
  your change is dead weight.
- **"I'll add parallelism to make it faster."** Serial optimization first. The serial
  reference pipeline must be fast on its own.
- **"Allocations don't matter, the allocator is fast."** Every allocation is a cache
  pollution event. In hot loops, it is the dominant cost.
