# Instance specialization: the re-lowering census, the decision on symbolic generic IR, the discovery closure

A generic body lowers once and every instance renders that shared lowering under its
substitution chain, except a body whose shape depends on the instance: an unexpanded
reflection binder (`CoreBody.has_reflect`: `inline for` over `fields`/`variants`/
`payloads` of a symbolic owner, or an `inline for` bound by a const parameter) or a vector index
list over a parameter (`has_lists`, counted with reflection in the census) re-lowers
per instance, and an unfolded zero-size condition (`CoreBody.has_zst_cond`: a
`sizeof(T) <op> <const>` branch with `T` unbound) re-lowers once per zero-size signature
of the instance's arguments. The alternative is a symbolic generic IR: keep those
operations symbolic in one body and substitute per instance without reopening syntax.
This is the record of the measurement that decides between the two, the instrumentation
that keeps the numbers visible, and the rules of the instance discovery closure next to them.

## The census

`SC_CEMIT_STATS=1` prints, after the instance drain, one line per marked template and a
summary per reason in the emission probe report (`src/emit/probe.spc`,
`driver::emit::cemit_relower_census`):

```
cemit-relower <template> (zero-size): <n> instances, <n> re-lowerings, <n> identical, <n> KiB retained
  relower-refl      <ms>   <calls>   <allocations>  <MiB>
  relower-zst       <ms>   <calls>   <allocations>  <MiB>
  instance discovery and specialization (graph, acquire, re-lowering)      <ms> ms
  re-lowering for reflection: <n> templates, <n> instances, <n> re-lowerings (<n> identical, <n> KiB retained)
  re-lowering for zero-size: <n> templates, <n> instances, <n> re-lowerings (<n> identical, <n> KiB retained)
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

A past measurement, kept because it decides the next section: release compiler, one worker,
`--cc=true` (a C compile that did nothing; `--emit-c` now) for the compiler's own sources and the test target of `super-c test` (the test
suite over the compiler and the standard library, the generic-heavy corpus) with the
allocation tracker on. Re-measure with the commands at the end of this file.

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

The instance graph (`graph/instances.spc`, probe region `graph`) walks bodies from the
concrete roots and adds records speculatively too: the signature propagation (`expand_signatures`, every method signature of
every extend on every reached instance) and the demand cross product (each demanded method
declaration with every instance of its target) create records no rendered body may need.

What the graph feeds: only an aggregate record with a concrete pool anchor (`InstRec.aty`)
enters the planned definition headers, and every aggregate a rendered body or a field chain
names beyond them is defined by the late replay of the mangler's spellings
(`Mangler::agg_reqs`, `TuEmit::emit_agg_inst`). The closure's breadth therefore decides
where an aggregate's definition lands, never whether it exists; a truncated closure moves
definitions to the late section. Constants and statics do not come from the closure: the
emitter demands each one where a body spells it (`CEmit::stat_demand`), and a parallel seed
shard passes its demands to the master with its capture (`cemit_seed_merge_range`), so a
constant only a seed shard demands is defined too (regression test
`generic_extend_constant_from_a_parallel_seed`, `tests/codegen/codegen_run_test.spc`).

Two costs were byte-preserving by construction and are fixed:

- The demand cross product paired every demanded method declaration with every instance
  of its target again on every round. `InstGraph.pair_cur` keeps, per declaration and per
  interface default, how many records of the target's group it has paired; groups only grow
  in record order, so a round pairs the new records alone and the insertion order equals a
  full re-pairing's.
- The `Ty` and `TyInstance` hashes were multiply-only chains, so the index slot was a
  function of the payload's low bits alone and records that differ above them (an array's
  length, a projection's binder, a nominal type's module) probed one chain. Both hashes now
  mix every word through `skey_mix`.

Width-generic code made the speculative part unbounded. A record whose signatures or method
bodies fold a computed const argument (`UInt<{BITS * 2}>`, `UInt<{(BITS + 7) / 8}>`,
`Vec<T, {N + 1}>` from `append`) creates the next width, whose signatures fold the width
after it, until the walk budget (64 million units) stops the graph: the width-generic integer
reached thousands of widths, and every program that imports `std::math::all` exhausted the
budget. So a speculative walk (the signature propagation, the demand cross product and the
expansion of a record either created) creates no aggregate record through a computed const
argument (`InstGraph::note_type`, `folds_const`; an identity form `{N}` is not computed). A
demanded body that names the width still creates its record. The regression test is
`computed_width_signature_does_not_chain` (`tests/cli/cli_stats_test.spc`): a `grow` that returns
`V<{N + 1}>` builds without a budget stop and its called width is defined.

Two other trims were measured and rejected: narrowing the per-declaration pairing to
interface members and `free` gave byte-identical C only by observation (a conforming
extend's uncalled method may still spell an aggregate that the planned headers would
otherwise leave to the late section), and removing the signature propagation and the
default pairing moved definitions. A closure that equals the emitted set needs the emitter's
demand model in the graph (dispatch resolved per receiver through the conformance records,
defaults and glue per instance on demand), which is the design the rejected symbolic path
would have required and the place a future change starts. Until then the collect line of
`SC_CEMIT_STATS=1` reports the shape every build:

```
cemit-stage collect: <ms> ms, <n> records (<n> aggregates, <n> functions, <n> methods), <n> bodies walked in <n> rounds
```

with `, budget exhausted` appended when the walk budget stopped it.

## How to re-measure

```sh
./super-c build --profile=release -o build/sc-rel
SC_CEMIT_STATS=1 SC_BUILD_STATS=- SC_BUILD_MEM=1 SC_NO_CACHE=1 SC_NO_TU_CACHE=1 \
  build/sc-rel build --jobs=1 --emit-c --out-dir=build/m1
SC_CEMIT_STATS=1 SC_BUILD_STATS=- SC_BUILD_MEM=1 SC_NO_CACHE=1 SC_NO_TU_CACHE=1 SC_LEAK_CHECK=fatal \
  build/sc-rel test --quiet --jobs=1 --out-dir=build/m2 --test-shard=100000/100000
```

The test run builds the compiler first and the test target second, and its shard holds no
test, so it runs none (a `--filter` would also drop test files from the build); the second
`emit-probe` table and the second build record are the corpus. `SC_TYPE_STATS=1` adds the
graph's `add` and hit counts and the type table's probe steps. Byte identity is the old
binary against the new one over the same sources; the test corpus includes the compiler's
own modules, so an edited module's own C differs by construction.
