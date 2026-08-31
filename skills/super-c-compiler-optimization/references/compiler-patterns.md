# Compiler-Specific Optimization Patterns

Patterns proven in this codebase. Each has been verified to preserve the byte-identical
fixpoint and measured against the self-build benchmark.

## Safe Cache Patterns

### Last-value cache, verified on every use

A one-entry cache holding the key just processed, checked against the current key before
reuse. Keys cluster in compiler workloads, so most probes hit; a mismatch falls through
to the full path and refreshes the entry, so the cache can never serve a stale answer.
Real instance: the mangler's `last_edge` (`src/emit/mangle.spc` — "the used_mods edge
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

## Memo Grain and Memo Soundness

A memoization cache is only worth adding when the memo probe cost is less than the
recomputation cost — never blanket-memo every node.

Memos also carry a soundness contract. The typechecker's memo maps (`arity_memo`,
`attributable_memo`, `free_derive_memo`, `free_ext_memo` in
`src/typechecker/typechecker.spc`) document theirs at the declaration: a TC memo must
not change type-pool interning, generic-dependent answers are excluded from the cache
(closure answers move under the walk), and recursive-type cycles get a defined resolution.
Copy that idiom — state at the field what makes the memo sound, and scope the key so
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
each instance. The instance propagation pass already handles this — new generic code
should not break the sharing.

## Scratch Pool Pattern

A pass context carries mutable scratch fields cleared per unit of work instead of
reallocated. Real instances, all in-tree:

- `CEmit.out` (`src/emit/cemit.spc`) — "the reusable output buffer (caller-owned
  lifecycle, cleared per TU)".
- The C emitter's `scratch: Vector<String>` — per-function string buffers popped,
  cleared, and pushed back, plus `sx_*` per-body analysis arrays cleared with the
  comment "frees each String, keeps the Vector's capacity across functions".
- `CFlow` (`src/emit/cflow.spc`) — a dozen-plus per-body CFG vectors (`rpo`, `preds`,
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
chain is `let mut chain: [NodeId; 32]` (`src/resolver/resolver.spc`) — path nesting is
grammar-bounded, so the Vector it replaced was pure allocation overhead. The borrow
checker's `FlowState` save/restore likewise reuses stack locals instead of copied
containers.

## Interning Deduplication

The compiler interns strings, types, and symbols. Before building a new hash map for
lookup, check whether an existing interning table covers the data. A second map over
already-interned data doubles the memory and cache pressure for zero benefit.

## Worklist Order

The order in which a worklist processes items affects convergence speed. For dataflow
analyses (borrow checking, liveness), reverse-postorder often converges faster than
arbitrary order. Measure the current workload before claiming a speed improvement.

## Per-Body Lowering

Lower each function body exactly once. `irl::Keep` (`src/ir/lower.spc`) is a
package-lifetime store of finished lowerings keyed by owner: borrowck adopts every body
it lowers, and the instance graph starts from those instead of lowering the package a
second time. Entries move out on first demand and never return. Redundant lowering was
the single largest waste in the pre-Phase-14 compiler.

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
