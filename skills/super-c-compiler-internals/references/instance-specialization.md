# Instance specialization: the re-lowering census, the decision on symbolic generic IR, the discovery closure

A generic body lowers once and every instance renders that shared lowering under its
substitution chain, except a body whose shape depends on the instance: an unexpanded
reflection binder (`CoreBody.has_reflect`: `inline for` over `fields`/`variants`/
`payloads` of a symbolic owner, or an `inline for` bound by a const parameter) re-lowers
per instance, and an unfolded zero-size condition (`CoreBody.has_zst_cond`: a
`sizeof(T) <op> <const>` branch with `T` unbound) re-lowers once per zero-size signature
of the instance's arguments. The alternative is a symbolic generic IR: keep those
operations symbolic in one body and substitute per instance without reopening syntax.
This is the record of the measurement that decides between the two, the instrumentation
that keeps the numbers visible, and what the measurement found in the instance discovery
closure next to them.

## The census

`SC_CEMIT_STATS=1` prints, after the instance drain, one line per marked template and a
summary per reason in the emission probe report (`src/emit/probe.spc`,
`driver::emit::cemit_relower_census`):

```
cemit-relower __std::vector::free (zero-size): 178 instances, 4 re-lowerings, 3 identical, 12 KiB retained
  relower-refl      0.00          0          0  0.00
  relower-zst       0.78         14        684  0.19
  instance discovery and specialization (graph, acquire, re-lowering)      81.34 ms
  re-lowering for reflection: 0 templates, 0 instances, 0 re-lowerings (0 identical, 0 KiB retained)
  re-lowering for zero-size: 7 templates, 388 instances, 14 re-lowerings (7 identical, 82 KiB retained)
```

- A **template** is a generic body whose shared lowering carries the flag (tallied when
  the drain lowers the base slot: `count_template`).
- An **instance** is a distinct symbol emitted from that template.
- A **re-lowering** is one more `lower_fn` of the template under a demand env: one per
  instance for reflection, one per zero-size signature (`lw_cache` keyed by the signature
  bits) for zero-size conditions. The two probe regions `relower-refl` and `relower-zst`
  hold their wall time, calls, allocation calls and requested bytes.
- **Identical** counts re-lowerings whose printed IR (`ir::print::print_body`) equals an
  earlier re-lowering of the same template: a zero-size template with several parameters
  folds the same way for signatures that differ only in a parameter its conditions never
  test.
- **Retained** is what the re-lowerings hold until emission ends (`Lowerer::
  retained_bytes`: the body's pools at capacity plus the replay tape). One worker retains
  every re-lowering in `lws`; the parallel frontier drops a slice's reflection
  re-lowerings with the slice, so a many-worker census counts fewer.
- The **instance discovery and specialization** line is the graph, acquire and both
  re-lowering regions together.

The two re-lowering counts fold into the build record (`SC_BUILD_STATS`:
`"relower":{"reflect":N,"zst":N}`), so every performance report carries them. The probe's
tallies merge across shards and pooled contexts even when its regions are off (`Probe::
merge`); the regions still cost one branch when off.

## Numbers

Release compiler, one worker, `--cc=true` for the compiler's own sources (153 units) and
the test target of `super-c test` (240 units: the test suite over the compiler and the
standard library, the generic-heavy corpus) with the allocation tracker on.

| Measure | Compiler | Test corpus |
|---------|--------:|------------:|
| transpile (stamp to sync) | 725 ms | 1,628 ms |
| allocation calls, whole build | 588,174 | 2,032,220 |
| reflection templates / instances / re-lowerings | 0 / 0 / 0 | 0 / 0 / 0 |
| zero-size templates / instances / re-lowerings | 7 / 388 / 14 | 9 / 358 / 18 |
| identical zero-size re-lowerings | 7 | 9 |
| `relower-zst` region | 0.18 ms, 684 allocations, 0.19 MiB requested | 0.20 ms, 938 allocations, 0.28 MiB |
| retained by the re-lowerings | 82 KiB | 134 KiB |
| `acquire` region | 1.1 ms | 1.6 ms |
| `graph` region (before this change) | 15.1 ms, 44,192 allocations, 18.7 MiB | 854.7 ms, 1,049,774 allocations, 529.9 MiB |

The zero-size templates are the container primitives that branch on `sizeof(T) == 0`
(`Vector::free`, `Vector::reserve`, `Vector::with_capacity_in`, `Map::free`, `Map::grow`,
`Box::free`, `Box::new_in`, the channel's `grow`). No template in either corpus is marked
for reflection: every reflection binder's owner is concrete where it is written, so it
expands in the shared lowering.

## Decision

The threshold is the one the type table was gated on: a category is worth a symbolic
operation set when removing its re-lowering saves 5 percent of the transpile's cycles or
10 percent of its allocations or memory. Measured: the zero-size re-lowering is under
0.03 percent of the transpile's wall time and under 0.12 percent of its allocation calls
on either corpus, with 134 KiB retained on the larger one; the reflection re-lowering is
zero. Both categories are
rejected. The per-instance re-lowering stays as the lowering path for both, with its
counts in every report; no symbolic reflection, layout or zero-size operation is added
to the Core IR, no typed substitution engine, and the evaluator, the ownership analyses,
the cleanup elaboration and the renderer keep reading the bodies they read now.

Two observations bound what the retained path could still save. Half of the zero-size
re-lowerings are identical to another one of their template (7 of 14, 9 of 18): a
signature keyed on the parameters a template's conditions actually test would lower each
once, for less than 0.1 ms per build. And every re-lowering runs before the inliner and
elaborates its own drops, so a symbolic body would have had to carry the elaborated
drops and the flag temps through substitution to keep the emitted C.

## Instance identity and ownership

The instance graph's record key is the one the decision leaves in place: the record
kind, the declaration `DefId`, and the final package `TypeId` of every argument, with a
const argument's folded value riding along for frame evaluation (`ArgKey`); hashes select
the index slot, the key compares field by field. The graph runs after the second type
publication, so every argument id is final when the key is built and no work key is
needed before it. An instance's definition owner is its generic's declaring module
(`<module>__inst.c` and the owner shards, [output-layout.md](output-layout.md)); the
worker-count identity gate compares the whole output tree of one worker and every core
under `SC_TASK_DELAY`, so neither identity nor ownership depends on which caller
discovered an instance first.

## The discovery closure

The measurement's largest line is not the re-lowering. On the test corpus the instance
graph (`graph/instances.spc`) took 855 ms, 1.05 million allocations and 530 MiB
requested, held 80.9 MB of records, grew the package type table from 8,381 to 25,185
records, and stopped on its walk budget: 1,055,233 records (26,220 aggregates, 88,447
functions, 940,566 methods) over 774,001 body walks in 8 rounds, for 3,170 emitted
instances and 345 anchored aggregates. The compiler's own sources produce 17,311 records
(1,246 aggregates) in 2 rounds.

What the graph feeds: only an aggregate record with a concrete pool anchor (`InstRec.aty`)
enters the planned type headers, and every aggregate a rendered body or a field chain
names beyond them is defined by the late replay of the mangler's spellings
(`Mangler::agg_reqs`, `TuEmit::emit_agg_inst`). The closure's breadth therefore decides
where a definition lands, never whether it exists; a truncated closure moves definitions
to the late section.

Two costs were byte-preserving by construction and are fixed:

- The demand cross product paired every demanded method declaration with every instance
  of its target again on every round (10,308,005 `add` calls, 9,342,174 of them hits,
  562 ms). `InstGraph.pair_cur` keeps, per declaration and per interface default, how
  many records of the target's group it has paired; groups only grow in record order,
  so a round pairs the new records alone and the insertion order equals a full
  re-pairing's. 7,014,366 calls remain, from the body walks.
- The `Ty` and `TyInstance` hashes were multiply-only chains, so the index slot was a
  function of the payload's low bits alone and records that differ above them (an
  array's length, a projection's binder, a nominal type's module) probed one chain:
  310,571,557 probe steps for 1,251,970 hits on the test corpus. Both hashes now mix
  every word through `skey_mix`; 1,654,547 probe steps for the same lookups.

Release compilers built by one compiler from the same sources, one worker, three
interleaved runs each, medians:

| Measure | Before | After |
|---------|-------:|------:|
| compiler: `graph` region | 16.6 ms | 14.7 ms |
| compiler: transpile (stamp to sync) | 806 ms | 707 ms (the runs spread 688 to 922 ms; the region is the attributable part) |
| test corpus: `graph` region | 802 ms | 445 ms |
| test corpus: `plan` phase | 805 ms | 449 ms |
| test corpus: transpile | 1,552 ms | 1,231 ms |
| test corpus: peak RSS | 388 MiB | 369 MiB |
| test corpus: allocation calls, whole build | 2,033,647 | 2,034,054 |
| test corpus: graph records, bytes requested | 1,055,233, 530 MiB | unchanged (byte-identical closure) |

The rest is the closure's breadth, and the record histogram names it: `interfaces::ne`
17,689 records, `int::from_bits` 15,752, `Option` 8,811 and each of its methods as many,
`int::UInt` 7,888 with fifteen methods each. The width-generic integer reaches thousands
of widths because the signature propagation (`expand_signatures`, every method signature
of every extend on every reached instance) and the method bodies fold `UInt<{BITS*2}>`,
`UInt<{(BITS+7)/8}>` and their kin into new instances, each of which repeats the step
until the const bound bails. The emitter demands 3,170 of them. Two trims were measured:

| Closure | Compiler records / walks | Test corpus records | Emitted C |
|---------|-------------------------:|--------------------:|-----------|
| as is | 17,311 / 19,710 | 1,055,233 (budget exhausted) | reference |
| per-declaration pairing narrowed to interface members and `free` | 9,576 / 11,975 | 860,614 (budget exhausted) | byte-identical on both corpora |
| plus no signature propagation and no default pairing | 6,053 / 9,840 | 1,127,292 (the budget moved to the width chain) | differs: the forward header, one types header, five TUs |

Neither trim is in: the first is byte-identical only by observation (a conforming
extend's uncalled method may still spell an aggregate that the planned headers would
otherwise leave to the late section), and the second moves definitions. A closure that equals the emitted set needs the
emitter's demand model in the graph (dispatch resolved per receiver through the
conformance records, defaults and glue per instance on demand, a bound on const-argument
folding), which is the design the rejected symbolic path would have required and the
place a future change starts. Until then the collect line reports the shape every build:

```
cemit-stage collect: 12 ms, 17311 records (1246 aggregates, 1641 functions, 14424 methods), 19710 bodies walked in 2 rounds
```

with `, budget exhausted` appended when the walk budget (64 million units) stopped it.

## How to re-measure

```sh
./super-c build --profile=release -o build/sc-rel
SC_CEMIT_STATS=1 SC_BUILD_STATS=- SC_BUILD_MEM=1 SC_NO_CACHE=1 SC_NO_TU_CACHE=1 \
  build/sc-rel build --jobs=1 --cc=true --out-dir=build/m1 -o build/m1_bin
SC_CEMIT_STATS=1 SC_BUILD_STATS=- SC_BUILD_MEM=1 SC_NO_CACHE=1 SC_NO_TU_CACHE=1 SC_LEAK_CHECK=fatal \
  build/sc-rel test --quiet --jobs=1 --out-dir=build/m2 --test-filter=no_such_test
```

The test run builds the compiler first and the test target second; the second
`emit-probe` table and the second build record are the corpus. `SC_TYPE_STATS=1` adds the
graph's `add` and hit counts and the type table's probe steps. Byte identity is the old
binary against the new one over the same sources; the test corpus includes the compiler's
own modules, so an edited module's own C differs by construction.
