# Data Parallelism

## Data Parallelism

```superc
// Parallel for loop
parallel for i in 0..1000 {
    process(i);
}

// Parallel iteration over a slice (range-index a Vector to get one)
parallel::each(v[0..n], fn(x: &i64) { process(x); });
parallel::each_mut(v.index_range_mut(0..n), fn(x: &mut i64) { *x += 1; });

// Reduce: identity is a CLOSURE (a copied init value would double-free owning
// accumulators); per-worker results merge through a separate combine closure.
let total = parallel::reduce(v[0..n], fn() i64 { return 0; },
    fn(a: i64, x: &i64) i64 { return a + *x; },
    fn(a: i64, b: i64) i64 { return a + b; });
```

`parallel for` is a sugar keyword lowered to `std::parallel::data::range(...)`; the
index binder is `usize`. The parser wraps the body in a closure node so the resolver
fills captures. The body's `fn(..) + Send + Sync` bound prevents data races: the plain `fn(..)`
bound makes the body borrow its `Free` captures, a mutated capture is a `&mut` borrow, and a
closure that holds one is not `Sync`, so the classic parallel data race does not compile. The functions come from `import std::parallel::data as parallel;`.

Also available: `parallel::chunks_mut`, `parallel::sections` (fork-join via a builder
closure that calls `Sections::add`), and `*_with` variants (`range_with`, `each_with`,
`reduce_with`, ...) taking an `Options` for schedule and grain.

### inline for

```superc
inline for i in 0..4 {
    process(i);   // unrolled at compile time to 4 copies
}
```

Requires a const-foldable closed range. `break`/`continue` targeting it are rejected.
Each iteration emits `{ const T i = k; <block> }`.
