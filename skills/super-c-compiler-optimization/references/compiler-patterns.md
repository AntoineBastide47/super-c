# Compiler-Specific Optimization Patterns

Patterns proven in this codebase. Each has been verified to preserve the byte-identical
fixpoint and measured against the self-build benchmark.

## Safe Cache Patterns

### Last-value cache, verified on every use

A one-entry cache holding the key just processed, checked against the current key before
reuse. Keys cluster in compiler workloads, so most probes hit; a mismatch falls through
to the full path and refreshes the entry, so the cache can never serve a stale answer.
Real instance: the mangler's `last_edge` (`src/emit/mangle.spc`: "the used_mods edge
just recorded: spellings cluster, so most repeat it"), re-verified with
`if edge != self.last_edge` at each use.

```superc
if edge != self.last_edge {
    self.last_edge = edge;
    // full path: record the edge
}
```

### Lazy cache via const-cast

When a `&Self` method needs to cache a computed result, const-cast the self pointer.
Legal because the compiler is single-threaded per compile. Do not use across thread
boundaries.

### Prefilter without reorder

When filtering items during emission, skip in-place rather than copying survivors to a
new container. This preserves interning/emit order, which is required for byte-identical
output.

### Spell in place without reorder

Rendering order is observable: demands, sentinels, static stubs and cross-TU edges
record in the order text is spelled. Replacing `let mut t = String::new(); render(&mut t);
dst.push_string(&t)` with `render(dst)` is byte-safe only when nothing side-effecting
sits between where `t` was rendered and where it was pushed (literal pushes are fine).
A spelling needed twice, or needed after later text, stays in its render position and
rides in the scratch pool (`sget`/`sput`); a wrapper around text already spelled
inserts its opener at a mark (`String::insert_str`) and appends the closer.

## Memo Grain and Memo Soundness

A memoization cache is only worth adding when the memo probe cost is less than the
recomputation cost. Never blanket-memo every node.

Memos also carry a soundness contract. The typechecker's memo maps (
`attributable_memo`, `free_derive_memo`, `free_ext_memo` in
`src/typechecker/typechecker.spc`) document theirs at the declaration: a TC memo must
not change type-pool interning, generic-dependent answers are excluded from the cache
(closure answers move under the walk), and recursive-type cycles get a defined resolution.
Copy that idiom: state at the field what makes the memo sound, and scope the key so
unsound entries cannot be created.

## Hot-Loop Value Caching

Cache repeated field accesses into a local when the C compiler cannot prove the pointer
is not aliased. The Super-C borrow checker guarantees no aliasing for `&mut`, but the
generated C uses raw pointers, so Clang may not hoist the load.

```superc
// Before: self.tokens.len() called 3 times, each is a pointer chase
fn scan(self: &mut Lexer) {
    while self.current < self.tokens.len() { .. }
}

// After: hoist the length
fn scan(self: &mut Lexer) {
    let len = self.tokens.len();
    while self.current < len { .. }
}
```

## Data-Plane / Control-Plane Separation

Keep diagnostics, error formatting, and recovery logic out of hot data-processing loops.
The cost is not the branch (predicted-not-taken is ~free) but the code size pollution: a
large error-handling block in the middle of a hot loop evicts the hot code from the
instruction cache.

Pattern: check a flag or error code in the hot loop, defer the formatting to after the
loop exits (or to a `@c.noinline` helper).

## Body Sharing for Generic Instances

When multiple monomorphizations of a generic function produce the same lowered C body
(common for pointer-width-independent code), emit the body once and reference it from
each instance. The instance propagation pass already handles this. New generic code
should not break the sharing.

## Scratch Pool Pattern

A pass context carries mutable scratch fields cleared per unit of work instead of
reallocated. Real instances, all in-tree:

- `CEmit.out` (`src/emit/cemit.spc`): "the reusable output buffer (caller-owned
  lifecycle, cleared per TU)". A body render takes it out of the emitter and threads it
  as `o: &mut String` so every renderer can write to it while `self` is borrowed; the
  wrapper asserts `self.out` stayed empty before putting it back.
- The C emitter's `scratch: Vector<String>`: per-function string buffers popped,
  cleared, and pushed back, plus `sx_*` per-body analysis arrays cleared with the
  comment "frees each String, keeps the Vector's capacity across functions".
- `CFlow` (`src/emit/cflow.spc`): a dozen-plus per-body CFG vectors (`rpo`, `preds`,
  `idom`, `loop_of`, ...) all `.clear()`ed at body start, never reallocated.

```superc
// Per-body reset: capacity survives, allocation count stays flat.
self.sx_coal.clear();
self.sx_name.clear(); // frees each String, keeps the Vector's capacity across functions
```

The Vectors grow to their high-water mark and stay there.

## Fixed-Array Replacement

When the maximum element count is domain-bounded (not user-input-bounded), replace
`Vector<T>` with `Array<T, N>` or `[T; N]`. Proven instance: the resolver's `::` member
chain is `let mut chain: [NodeId; 32]` (`src/resolver/resolver.spc`): path nesting is
grammar-bounded, so the Vector it replaced was pure allocation overhead. The borrow
checker's `FlowState` save/restore likewise reuses stack locals instead of copied
containers.

## Interning Deduplication

The compiler interns strings, types, and symbols. Before building a new hash map for
lookup, check whether an existing interning table covers the data. A second map over
already-interned data doubles the memory and cache pressure for zero benefit.

## Worklist Order

The order in which a worklist processes items affects convergence speed. Check the seed
order before any micro-optimization. Seed in the direction of the problem: liveness flows
backward, so its LIFO seed pops reachable blocks in postorder (`src/borrowck/dataflow.spc`;
a forward seed cost 21 ms of borrowck). The move/init dataflow runs one exact-RPO sweep,
then a queue for the back-edge residue (`solve_moves`; a swap-with-last pop that scrambled
RPO cost 29 ms). Unreachable blocks must still run once after the ordered run, or the
converged state changes. Measure the current workload before claiming a speed improvement.

## Loop Safepoints

A preemption tick on every loop back-edge cost borrowck 22%, typecheck 14% and codegen
24%. The lowerer emits it only in a body a coroutine can execute (`Lowerer::loop_ticks`,
`Package::co_on` over `co_spans` in `src/module/loader.spc`). Keep new loop-level
instrumentation behind the same reachability gate.

## Hashing Packed Keys

Integer keys hash to themselves. A key that packs two ids (`m << 32 | id`) then clusters in
the low bits and builds long probe chains (measured: one function at 22% of a run, a 40%
codegen regression). `std::Map::slot` (`std/map.spc`) folds the high half in and multiplies.
A custom open-addressing table over packed or structured keys must hash through `skey_mix`
(`src/ast/ast.spc`).

## Shared Quadratics

One quadratic routine often has several callers. Bucketing kills and conflicts per base
(CSR) was neutral for borrowck but cut codegen from 2300 to 1287 Mcyc, because drop
elaboration ran the same code per instance. Profile every consumer of a changed routine,
not only the pass that motivated the change.

## Function Size and Typecheck Cost

Typecheck cost grows faster than function size. A 450-line block inline in
`cemit_package` cost +3.9% typecheck Mcyc; the same block as its own function cost +1.1%.
Put a large new stage in its own function.

## Per-Body Lowering

Lower each function body exactly once. `irl::Keep` (`src/ir/lower.spc`) is a
package-lifetime store of finished lowerings keyed by owner: borrowck adopts every body
it lowers, and the instance graph starts from those instead of lowering the package a
second time. Entries move out on first demand and never return. Redundant lowering was
the single largest waste before the keep existed.

## What to Avoid

- **Blanket memoization.** A memo whose probe cost exceeds the recomputation cost is a
  net loss.
- **Hash map for small N.** Below ~16 elements, linear scan on a flat array beats a hash
  map (the constant factor of hashing dominates).
- **Premature SIMD.** Let the C compiler auto-vectorize. Only hand-write SIMD if the
  profiler shows the auto-vectorizer failed on a hot loop and you understand why.
- **Parallelism as a substitute for serial efficiency.** Optimize the serial path first.
  A parallel version of a slow algorithm is still slow.
- **Speculative prefetch.** Modern CPUs have hardware prefetchers that handle sequential
  and strided access. Manual prefetch is almost never a win in compiler workloads.

### Rejected levers

Each lever was measured with interleaved A/B runs and rejected. Do not retry one without
new evidence.

Frontend and typecheck:
- Resolution stored inside `Node` (`res: DefId`, +8 B per node): +2.6 to 3% total cycles.
  The dense side vector (`Ast.resolutions`) stays the resolution store.
- `resolutions` split into parallel u32/u16 arrays: saved 0.78 MiB and slowed
  `resolution_def`, the hottest lookup.
- An unconditional memo for foreign type lowering: 32% slower than no memo. Memoize only
  type paths with arguments.
- Removing `fdecl_memo`: typecheck 232 to 249 Mcyc.
- Substituted-signature memo, CTFE success memo, prepared-signature replay: 0 to 0.6% of
  the profile, or flat cycles and +3.1 Kalloc.
- A prelude `str` type cache: no change; the probes are not hot.
- A second round of `@c.always_inline` on small hot functions: at most 1 Mcyc per phase
  for +165 KB of text.
- Parser micro-optimizations (double `raw_peek`, duplicate range checks, token re-reads):
  LTO already removes them.
- A hand-written word compare in `Ty::eq`: +2.5% typecheck. Clang lowers the fixed 16 B
  `memcmp` branchless. Word-wise FNV hashing did win: no builtin does it.
- Single-block storage for `std::Map`: blocked. The CTFE heap cannot evaluate byte-offset
  interior pointers, and `Map` folds are a language feature.

Borrow check:
- `MoveForest` subtree CSR cache, per-block gen/kill transfer masks (revisit ratio about
  2, the mask build costs 2 replays, +18 MiB), direct leaf step, speculative in-sweep
  reporting: neutral or worse.
- A "slim" fact-generation class: net -2%, reverted. Any `&self` receiver is a carrier
  local, so the class was almost empty while its guards taxed every body.
- Allocation churn: the remaining borrowck allocations are about 0.2% of cycles.

Emission and emitted C:
- Folding `const` value reads to literals at emission: `const Z = 0; if Z != 0 && 10/Z > 1`
  becomes a compile-time `10/0` that clang rejects. A fold needs divisor and shift context
  and must exclude `static mut`.
- Per-instance `method_used`, hash-compressed instance names, a body topological sort to
  drop private prototypes: unsound or bad for debugging.
- Guards for constant division and shift operands, `match` as a C `switch`, copies of
  operator-overload operands: `-O2` removes them already.
- A parallel instance drain with one shard per demand: 9x slower than serial (shard
  construction dominates). Waves use `2 * jobs` contiguous slices (`src/driver/emit.spc`).
- A parallel `InstGraph.collect`: its first-discovery order defines the canonical output
  order, so it stays serial.
- Copying every viewed kept body for readers after release: +76 MiB RSS.

Toolchain and tests:
- PGO (`-fprofile-use`): borrowck and typecheck regressed about 9%, measured twice. The
  `pgogen` profile stays; never ship a profile.
- Test pool size (5, 7, 10, 14 workers): no signal above noise; the default stays the CPU
  count.
- Nested test compilers run the ASan+UBSan dev build on purpose, as a correctness check.
  Do not swap them for a release build to save time or energy.

Architecture:
- A compiler API snapshot database: rejected. The only client is the LSP (serial
  requests, queries 0.1 to 3 ms, no concurrent reader), and one immutable generation costs
  at least 44 MiB. Reopen only when a concurrent reader exists (indexer, build tool,
  embedder), and measure again first.

## Pre-size vectors of large records (no doubling chains through the large allocator)

The borrow-check `Keep` and the instance graph's `kept` once stored a whole `Lowerer` per
body (about 1.8 KiB) and reached 7 MiB each for the compiler's own sources; they now store
`KeptBody` records (the body and its closures), but the rule stands. Growing such a vector by
doubling frees a 3.5 MiB block into a 7 MiB one on every build; macOS malloc kept those freed
large regions mapped and resident (`vmmap --summary`: `MALLOC_LARGE (empty)`), and the
100-round serial benchmark climbed from 288 to 445 MiB peak RSS once the surrounding
allocation sequence changed. `Keep::reserve_bodies` (one node-kind count over the
package) and `InstGraph::collect` (the keep's length) size them once; peak RSS returned
to 285 MiB. Sample a growing process with `vmmap` and `malloc_history` under
`MallocStackLogging=1` before bisecting source changes: the empty region sizes name the
vector. `MallocStackLogging` works on `build/bench-bin`, not on the ASan dev compiler,
whose sanitizer runtime replaces the allocator.

