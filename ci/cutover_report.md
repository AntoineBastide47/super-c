# Cutover report

The revised compiler is the only production self-hosting path. This report records the replaced-path
inventory, the bootstrap and determinism validation, the failure validation, the resolved performance
limits and the remaining findings. Reproduce with `sh ci/gate.sh`, `sh ci/perf_gate.sh`,
`sh ci/ledger.sh` and `sh ci/bench_matrix.sh`.

## Replaced-path inventory

Consumers by source search (`grep` over `src/`) and by the runtime counters of one serial build of the
compiler (`SC_CEMIT_STATS=1 SC_TYPE_STATS=1 ./super-c build --jobs=1`). An entry is removed only when both
are zero; a retained entry names the design that keeps it.

| Replaced path | Source consumers | Runtime count | State |
|---------------|-----------------:|--------------:|-------|
| module-order type check frontier (`typecheck_all_par`, `tc_frontier`, `tc_wait`, `tc_mod_done`) and per-module borrow frontier (`borrowck_all_par`) | 0 | 0 | removed: item jobs on `driver::sched` |
| shared generated declaration headers (`__sc_protos.h`, `__sc_types.h`) | 0 | 0 | removed: dependency-local headers |
| `SC_PROJ_DBG` trace in the lowerer | 0 | 0 | removed |
| per-module type pools and cross-module translation (`Ast::reintern`, `Package::map_type`) | 10 + 2 | 73 reinterns per transpile | retained by design: provisional ids live in the interning module's pool until the next publication checkpoint; the package table is the identity after it |
| syntax scan of a callee's returns (`tc_scan_returns_attributable`) | 1 fallback site | 0 in a batch build | retained for the harness and the language server (`ret_attr == 2`, unrecorded); the batch build records the verdict per item |
| emission dependency rows computed from syntax (`emit_dep_row` in `emit_order`) | 1 fallback site | 0 in a batch build | retained for the lint driver and the harness, which keep body syntax |
| ordinary bodies lowered from syntax after type checking (`Interp::body_of` fresh lowering of a kept-eligible body) | 1 | 16 of 699 fresh lowerings (683 are generic instances) | retained: a fold in one module's borrow job may need a body of a module whose job has not run; the kept body wins once published |
| render-time ownership analysis (`DropCtx::apply_drops_i` on a body emission lowered itself) | 2 | the per-instance re-lowerings (reflection 0, zero-size 14) and macro wrappers | retained by design: a body emission lowers is a new body, elaborated once before its splices |
| generic instance re-lowering (`relower-refl`, `relower-zst`) | 19 | 0 + 14 per build | retained: the symbolic generic IR was rejected by measurement; the counts stay visible |
| the borrow replay tape (`bc_replay`) | 4 | every body | retained: no event category met its removal gate |
| `SC_LSP_NO_INCR` (full rebuild instead of the incremental language-server round) | 1 | 0 outside the language server | retained: the language server is outside the cutover |

Dual-path and validation switches kept: `SC_BC_VALIDATE`, `SC_TYPE_VALIDATE`, `SC_TYPE_COLLIDE`,
`SC_FACTS_CHECK`, `SC_CORE_IR`, `SC_LAYOUT` (validation builds; the gate and `tests/cli_devcheck_test.spc`
run them), `SC_INLINE=0` and `SC_BCE_DISABLE` (the bounds-check and inliner oracle tests), the cache
switches (`SC_NO_CACHE`, `SC_NO_EMIT_CACHE`, `SC_NO_TU_CACHE`, `SC_NO_LTO_CACHE`) and the measurement
switches. The rejected designs (symbolic generic IR; in-frontier Core IR publication) appear in no
inventory line.

## Bootstrap sequence

`sh ci/gate.sh` (contract v3): the latest release binary builds the current sources (`check.sh`, two
stages), that compiler builds generation one, generation one emits generation two at the same path,
the trees are byte-identical, and generation two is compiled and run: it builds the tree with one
worker (compared with generation one's every-core tree) and with every core under three task-delay
seeds (`CONTRACT_DELAY_SEEDS`), each compared with the one-worker record on the emitted tree, the
package type table, the item index digest and the diagnostics; then the strict C set, every target
and every profile, and the benchmark.

## Determinism validation

Compared per worker count and seed by the gate: the generated C and headers, the output manifest
(`__sc_manifest`, inside the tree comparison), the package type table (`SC_TYPE_TABLE`), the item index
digest (keys, signature hashes, edges, components, states: `SC_ITEM_STATS`), the diagnostics (stderr
without the measurement lines). Body and ownership artifacts and instance keys, owners and order are
inside the generated C. Nothing is normalized; only `.tu_cache` is excluded (the compiler's own path
and mtime).

## Failure validation

| Boundary | Injection | Verified |
|----------|-----------|----------|
| C compilation | a unit that no C compiler accepts (`failed_c_compile_reports_status_and_keeps_the_log`) | the build fails with the child's status and a bounded replay, the log is kept, the corrected unit builds and removes it |
| link | an unresolvable library after a source edit (`build_link_failure_keeps_artifact`) | no binary or link record is published; the previous binary stays; the next build links |
| link with a rejected LTO flag | a wrapper that refuses `-flto=thin` (`build_lto_probe_fallback`) | the probe records the fallback; the build succeeds in the automatic mode |
| file publication | an unwritable generated file after a source edit (`build_publication_failure_keeps_artifact`) | the build fails at the sync, the previous binary stays, no emit stamp records the failed emission, the next build publishes the edit |
| task cancellation | the runtime's cancellation contract (`tests/cancel_test.spc`, `ci/cancel_hunt.spc` under ThreadSanitizer) | every wait kind releases its registration, credits and payload ownership; the batch driver itself has no cancellation requester, so no compiler state can become partially visible through one |
| allocation | none injectable: an allocation failure is fatal by contract (`Global::alloc` aborts), and the records that survive a process death are the atomic ones (temporary file and rename: manifest, build records, binary, emit stamp written last) | a build interrupted before its stamp re-emits and re-syncs every file on the next run |

Every failure test runs under `SC_LEAK_CHECK=fatal` in the suite, so a leaked block, file or child on
a failure path fails the test.

## Performance acceptance

Baseline record: `ci/baseline.env` (`0f61514303ca`, the 100-round lane at load 5.10) and the whole-build
matrix recorded with it (`fcf8f50`, load 5.1 to 12.2). Ledger: `ci/ledger.tsv`, every accepted change
against its parent under one protocol (`ci/ledger.sh`: the released bootstrap compiler builds the
commit's benchmark binary; 14 cores). Final runs on this tree: `sh ci/perf_gate.sh` at load 4.51
(`build cf6c798b7aba-dirty`), `sh ci/bench_matrix.sh` at load 4.16 (5 repetitions per case, caches off).

### Named constants and resolved limits

`CUTOVER_LIMIT = BASELINE - ACCEPTED_IMPROVEMENTS + ACCEPTED_REGRESSIONS`, resolved under the ledger
protocol and applied to the recorded constant as a ratio (`ci/perf_gate.sh`); a constant the ledger does
not scale keeps its baseline.

| Constant | Source | Baseline | Limit | Measured | Result |
|----------|--------|---------:|------:|---------:|--------|
| `B_SERIAL_MS` | `BASE_TRANSPILE_SERIAL_CPU_MS_MEDIAN` | 579.002 | 499.828 | 423.738 | pass |
| `B_PARALLEL_MS` | `BASE_BUILD_PARALLEL_TRANSPILE_MS` (14 workers, cold) | 434.924 | 521.589 | 360.870 | pass |
| `B_MCYC` | `BASE_TRANSPILE_SERIAL_MCYC_MEDIAN` | 2086.512 | 1788.807 | 1598.666 | pass |
| `B_KALLOC` | `BASE_TRANSPILE_SERIAL_KALLOC` | 717.950 | 324.215 | 323.880 | pass |
| `B_RSS_BYTES` | `BASE_TRANSPILE_SERIAL_PEAK_RSS_MIB` (not ledger-scaled, see findings) | 288.062 | 288.062 | 286.141 | pass |
| `B_FRONTEND_MCYC` | parse + resolve + typecheck Mcyc, 105 percent | 367.650 | 386.032 | 379.470 | pass (103.2 percent) |
| `B_SMALL_PACKAGE_MS` | emit-only transpile of `examples/language_demo.spc`, median wall of 15 interleaved runs, baseline compiler against this one, 105 percent | 44.448 | 46.670 | 46.336 | pass (104.2 percent; 103.7 in the run before) |
| `B_DEV_PRIVATE_MS` | matrix `body`, 14 workers, total | 1192.058 | 1192.058 | 1118.183 | pass |
| `B_DEV_TYPE_EDIT_MS` | matrix `layout`, 14 workers, total | 6914.791 | 6914.791 | 8088.199 | **117.0 percent** (the accepted output layout: 93 of 155 units recompile against 69 to 87 of 91) |
| `B_RELEASE_RELINK_MS` | matrix `release_relink`, 14 workers, total | 20997.875 | 20997.875 | 20176.423 | pass (ThinLTO with the linker cache, opt-in: 597.484) |

Unconditional gates: every accepted change meets the numeric targets of its own record (the per-change
references under `skills/super-c-compiler-internals/references/` and `skills/super-c-binary/SKILL.md`);
the serial and parallel totals meet the resolved ledger limits (above); frontend cycles 103.2 percent;
a private body edit rewrites 1 of 155 units (matrix `body`: 1/155 stale, 1118 ms); the rejected designs
are absent from the inventory. The small-package gate first measured 108 percent: the smallest
package pays the fixed costs of the accepted designs (engine record, one worker, the C compiler
replaced by `true`: resolve 1.3 to 2.4 ms for the item index, typecheck 3.6 to 5.8 ms for the item jobs
over 558 components, plan 0.7 to 2.0 ms for the inline store, publish 3.3 to 5.7 ms and sync 2.0 to
2.6 ms for 32 output files against 17, against render 5.3 to 3.5 ms), and the profile of forty such
builds showed no hot function. Six fixed costs were then cut: the index's CSR layout is a counting
layout with an in-place dedupe instead of a sort, the inline vetting scans each module once for its
static asserts instead of once per generic callee, the build engine's safety-net sync compares only the
files the stream never synced, the sink creates each output directory once, the output hash reads
each word with one copy instead of eight byte loads, and a tree that did not exist before the build
skips the orphan sweep. The package's engine phases went to resolve 1.9, typecheck 5.6, plan 0.9,
publish 5.7 to 6.1 and sync 1.8 to 2.1 ms; the emit-only latency to 104 percent (two interleaved runs
of 15 pairs: 103.7 and 104.2 percent, on a box at load 6 to 7). The remaining difference is the number
of files the accepted layout writes (about 150 us per created file on this filesystem).

### The performance gate (`sh ci/perf_gate.sh`, every constant)

| Constant | Baseline | Limit | Now | vs limit |
|----------|---------:|------:|----:|---------:|
| `BASE_TRANSPILE_SERIAL_CPU_MS_MEDIAN` | 579.002 | 499.828 | 423.738 | -15.22% |
| `BASE_TRANSPILE_SERIAL_CPU_MS_P95` | 583.712 | 583.712 | 435.678 | -25.36% |
| `BASE_TRANSPILE_SERIAL_WALL_MS_MEDIAN` | 593.406 | 593.406 | 437.366 | -26.30% |
| `BASE_TRANSPILE_SERIAL_MCYC_MEDIAN` | 2086.512 | 1788.807 | 1598.666 | -10.63% |
| `BASE_TRANSPILE_SERIAL_MCYC_P95` | 2102.535 | 2102.535 | 1629.736 | -22.49% |
| `BASE_TRANSPILE_SERIAL_KALLOC` | 717.950 | 324.215 | 323.880 | -0.10% |
| `BASE_TRANSPILE_SERIAL_HEAP_MIB` | 465.091 | 410.294 | 408.887 | -0.34% |
| `BASE_TRANSPILE_SERIAL_PEAK_RSS_MIB` | 288.062 | 288.062 | 286.141 | -0.67% |
| `BASE_PHASE_PARSE_MCYC` | 117.500 | 130.036 | 112.790 | -13.26% |
| `BASE_PHASE_RESOLVE_MCYC` | 61.270 | 71.763 | 52.880 | -26.31% |
| `BASE_PHASE_TYPECHECK_MCYC` | 188.880 | 234.919 | 213.800 | -8.99% |
| `BASE_PHASE_BORROWCK_MCYC` | 589.780 | 520.175 | 457.050 | -12.14% |
| `BASE_PHASE_CODEGEN_MCYC` | 1129.740 | 829.423 | 767.810 | -7.43% |
| `BASE_PHASE_PARSE_KALLOC` | 2.630 | 2.630 | 3.410 | +29.66% |
| `BASE_PHASE_RESOLVE_KALLOC` | 3.100 | 3.100 | 3.330 | +7.42% |
| `BASE_PHASE_TYPECHECK_KALLOC` | 26.490 | 26.490 | 28.950 | +9.29% |
| `BASE_PHASE_BORROWCK_KALLOC` | 225.520 | 225.520 | 116.550 | -48.32% |
| `BASE_PHASE_CODEGEN_KALLOC` | 460.210 | 460.210 | 171.650 | -62.70% |
| `BASE_BUILD_PARALLEL_JOBS` | 14.000 | 14.000 | 14.000 | +0.00% |
| `BASE_BUILD_PARALLEL_TRANSPILE_MS` | 434.924 | 521.589 | 360.870 | -30.81% |
| `BASE_BUILD_PARALLEL_STAMP_MS` | 2.281 | 2.281 | 1.361 | -40.33% |
| `BASE_BUILD_PARALLEL_LOAD_MS` | 12.860 | 12.860 | 14.185 | +10.30% |
| `BASE_BUILD_PARALLEL_RESOLVE_MS` | 7.547 | 7.547 | 8.623 | +14.26% |
| `BASE_BUILD_PARALLEL_TYPECHECK_MS` | 46.796 | 46.796 | 36.310 | -22.41% |
| `BASE_BUILD_PARALLEL_BORROWCK_MS` | 65.217 | 65.217 | 40.802 | -37.44% |
| `BASE_BUILD_PARALLEL_CHECKS_MS` | 55.032 | 55.032 | 18.179 | -66.97% |
| `BASE_BUILD_PARALLEL_PREPARE_MS` | 5.010 | 5.010 | 4.091 | -18.34% |
| `BASE_BUILD_PARALLEL_PLAN_MS` | 14.353 | 14.353 | 17.234 | +20.07% |
| `BASE_BUILD_PARALLEL_RENDER_MS` | 121.380 | 121.380 | 73.747 | -39.24% |
| `BASE_BUILD_PARALLEL_PUBLISH_MS` | 104.448 | 104.448 | 146.338 | +40.11% |
| `BASE_BUILD_PARALLEL_SYNC_MS` | 15.515 | 15.515 | 3.748 | -75.84% |
| `BASE_BUILD_PARALLEL_COMPILE_MS` | 6274.865 | 6274.865 | 9352.396 | +49.05% |
| `BASE_BUILD_PARALLEL_LINK_MS` | 83.798 | 83.798 | 75.737 | -9.62% |
| `BASE_BUILD_PARALLEL_TOTAL_MS` | 6809.102 | 6809.102 | 9792.751 | +43.82% |
| `BASE_BUILD_PARALLEL_CC_SPAN_MS` | 6531.544 | 6531.544 | 9595.476 | +46.91% |
| `BASE_BUILD_PARALLEL_CC_OVERLAP_MS` | 243.278 | 243.278 | 239.762 | -1.45% |
| `BASE_FRONTEND_MCYC` | 367.650 | 386.032 | 379.470 | -1.70% |

The gated constants (the median cycles, allocations, heap, peak RSS, the phase cycles and the frontend
sum) pass; the build constants are recorded, not gated (the cold C compile: see findings).

### The accepted-work ledger by change

Every row is the change against its direct parent (so the overlap owner is the change itself and no
improvement is counted twice); the deltas telescope to the final row.

| change | Mcyc | frontend Mcyc | typecheck Mcyc | borrowck Mcyc | codegen Mcyc | Kalloc | heap MiB | peak RSS MiB | 14-worker transpile ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline `fcf8f50` (the `0f61514` sources) | 1984.9 | 359.9 | 185.5 | 562.6 | 1071.3 | 718.0 | 465.1 | 687.2 | 355.6 |
| render bodies straight into the TU buffer `90409c8` | -34.6 | +11.5 | +5.5 | +1.7 | -59.2 | -214.6 | -59.6 | -400.6 | +26.1 |
| skip borrow analysis from typed IR feature bits `ecc1e7f` | -233.8 | +8.4 | +5.4 | -130.3 | -104.9 | -188.0 | -11.1 | -3.8 | -54.4 |
| dependency-local headers and hash-sharded units `f5f587a` | -16.0 | -5.7 | -3.6 | -7.2 | -5.2 | +3.9 | +4.5 | +0.9 | +95.8 |
| profile lto keys and the ThinLTO probe `778b66f` | +0.1 | +1.0 | +0.6 | +3.4 | +1.6 | +0.5 | +1.2 | +1.4 | -21.1 |
| the package type table `2e18816` | +35.6 | +2.0 | -0.2 | +19.1 | +24.5 | +10.2 | +18.5 | -28.9 | +0.9 |
| output shard counts from the emitted size, constant-condition lints `b61848d` | +45.8 | +4.9 | +3.2 | +2.9 | +15.7 | +0.4 | +0.8 | +5.8 | -2.2 |
| release function body syntax after emission planning `32aea8e` | +30.0 | +29.9 | +23.0 | +39.3 | -28.4 | -5.9 | +16.9 | +23.7 | +48.3 |
| the item index `f96e880` | +24.3 | +7.1 | +4.8 | +4.5 | +4.9 | +1.8 | +5.5 | -3.4 | -0.8 |
| free each module's body syntax after its borrow pass `baf68a3` | +0.4 | -1.3 | -1.5 | +1.8 | +3.6 | -4.0 | -29.8 | +5.6 | -28.7 |
| the unused-item lint from the post-typecheck edges `aa93fb3` | +18.8 | +3.5 | +1.8 | +4.1 | +10.3 | +0.0 | -0.8 | +0.4 | +33.3 |
| drops elaborated in the borrow pass `cdccc20` | -113.1 | +0.9 | -0.2 | +24.4 | -136.7 | -1.9 | -10.5 | -14.0 | -25.3 |
| instance re-lowering census, paired demand, mixed hashes `95f9648` | -26.8 | +0.1 | +3.6 | -5.1 | -18.6 | +0.6 | +1.0 | +3.8 | -2.0 |
| the item scheduler `cf6c798` | -13.9 | +5.2 | +2.8 | -24.9 | +7.6 | +3.2 | +8.7 | +12.0 | +0.9 |
| final `cf6c798` | 1701.7 | 427.5 | 230.7 | 496.2 | 786.5 | 324.2 | 410.3 | 290.2 | 426.5 |

The baseline row's peak RSS (687 MiB) is the benchmark binary run directly at that commit (the large
allocation regions the borrow-storage change removed); `ci/baseline.env` recorded 288 MiB for the same
binary under the sanitizer compiler. This tree's frontend pass (the map slot, the vector fill, the alias
peel, the prelude name map, the prelude publication at the gate, the memoized signature nodes: uncommitted
at the time of the runs) is what the performance gate measured over the final row: frontend 427.5 to
379.5 Mcyc, total 1701.7 to 1598.7.

### The whole-build matrix (`sh ci/bench_matrix.sh`, 14 cores, medians in ms)

| Case | Workers | Baseline (`0f61514`) | Now | Stale units now |
|------|--------:|---------------------:|----:|----------------:|
| clean transpile | 1 | 748.5 | 611.0 | 155/155 |
| clean transpile | 14 | 398.9 | 362.0 | 155/155 |
| clean total | 1 | 59753.5 | 59228.6 | 155/155 |
| clean total | 14 | 7224.5 | 10370.4 | 155/155 |
| unchanged total | 14 | 17.5 | 23.2 | 0/155 |
| private body edit total | 14 | 1192.1 | 1118.2 | 1/155 |
| public signature edit total | 14 | 7017.6 | 4406.1 | 40/155 |
| by-value layout edit total | 14 | 6914.8 | 8088.2 | 93/155 |
| release relink total (full LTO, the default) | 14 | 20997.9 | 20176.4 | 1/155 |
| release relink total (ThinLTO with the linker cache, `SC_LTO=thin`) | 14 | | 597.5 | 1/155 |
| peak RSS, body edit, 14 workers (MiB) | 14 | 310.8 | 241.7 | |

## Findings

- **Runtime data race (open).** The `race` profile compiler (ThreadSanitizer) building the
  compiler's own benchmark binary reports, in every run, a race between `spawn_coroutine`
  writing a recycled or fresh task block (`std/parallel/runtime.spc`, the `co[0] = Coroutine {..}`
  store) and a worker's completion path spinning on that block's `handoff` word
  (`worker_main`, the wait before `free_coroutine`). The trigger is the job runner's pattern
  of a completing task launching its successors from inside a coroutine. The released
  compiler panicked once in about twenty-four builds of one source tree under load
  (`Vector::at: index out of bounds` on a worker task) and zero times in a loop of twenty;
  the runtime's own sanitizer lanes (`ci/race_hunt.spc`, `ci/cancel_hunt.spc`) do not report
  it. The runtime is outside this cutover (the scheduler coordination plans are pending);
  the report records the reproduction: `./super-c build --profile=race -o build/race/super-c`,
  then `TSAN_OPTIONS=halt_on_error=0 build/race/super-c bench --no-run` over any export of the
  compiler's sources.
- **Type checker data race (fixed).** The same runs reported `decl_type_in` reading a foreign
  declaration's type slot while the owning item's job wrote it. The read is now taken only
  when the owner's item is visible to the reader (`gitems::visible`: the job dependency is
  the happens-before edge), after the per-checker memo.
- **Map slot clustering (fixed).** `Map::slot` placed a key at `hash & (cap - 1)`; the
  integer keys hash to themselves, and the compiler packs two ids into one key
  (`module << 32 | node`), so keys of different modules with equal node ids shared a slot
  and probed in long chains. The slot now folds the high half in and spreads through a
  multiply; the borrow-check phase alone lost about 30 Mcyc per transpile.
- **Cold parallel C compile (open).** The cold build's C compile at 14 workers takes 9.7 to 10.4 s
  against 6.3 s in the baseline record and 8.5 to 9.1 s in the ledger rows before `baf68a3`, while the
  C compiler's total CPU is unchanged or lower (85 to 95 s over 151 to 155 units): the ledger's
  `parallel_transpile_ms` rows carry the engine record's compile span, and the ratio of CPU to span at
  14 workers falls from 0.73 to 0.60 at `baf68a3` (the release of body syntax after the borrow pass)
  and stays there. The transpile is not the cause (it ends 170 ms into the build); the streaming
  compile's schedule is (largest units first, one job per landed file). Not diagnosed here; the build
  constants are recorded, not gated.
- **Ledger protocol caveat.** `ci/ledger.sh` builds every commit's benchmark binary with the
  released bootstrap compiler, so a row links that release's standard library: a change to
  `std/` (the map slot, the vector fill) shows in `ci/perf_gate.sh`, whose binary the
  checkout's own compiler builds, and not in a ledger row.
