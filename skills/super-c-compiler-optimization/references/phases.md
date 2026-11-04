# Optimization Phases

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
  [references/compiler-patterns.md](compiler-patterns.md)).

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

**See [compiler-patterns.md](compiler-patterns.md) for the full catalogue.**

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
