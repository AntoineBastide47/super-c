# Phase 14 re-baseline (single-threaded performance pass)

Post-migration serial baseline for the finished pipeline (plans/migration.md Phase 14, work
item 1). Phase 15 measures against this record. Same machine class as `baseline-phase0.md`.

## Environment

- CPU: Apple M3 Max (14 cores), macOS 26.5; release profile, single-threaded, 100 iterations
- Corpus: src/main.spc — 80 modules, 2431 decls, 111420 lines, 796441 tokens,
  4336.1 KiB source -> 6430.2 KiB C, 634338 AST nodes

## Self-transpile benchmark (`super-c bench`, transpile lane)

| phase     | avg ms | Mcyc | Kalloc | MiB    | share |
|-----------|--------|------|--------|--------|-------|
| lex       | 8.45   | 32   | 0.1    | 7.78   | (of parse) |
| parse     | 21.18  | 80   | 1.3    | 52.21  | 6.1%  |
| resolve   | 12.26  | 46   | 11.8   | 6.33   | 3.5%  |
| typecheck | 42.93  | 161  | 15.7   | 43.13  | 12.4% |
| borrowck  | 96.65  | 363  | 199.6  | 107.56 | 27.8% |
| codegen   | 174.31 | 654  | 345.2  | 106.26 | 50.2% |
| total     | 347.33 | 1304 | 573.7  | 315.50 | —     |

- heap: 315.5 MiB requested per iteration; bench-process peak RSS 235.6 MiB (the max over
  100 iterations; a single real `super-c build` transpile peaks at 151.9 MiB)
- generated C compiles at 3843.7 ms (cc compile-only, 66 files, 5947.0 KiB)

## Against Phase 0 (corpus +17.9% source, different pipeline shape)

- Per line the pipeline is 2.1x faster (152.5 -> 320.8 kloc/s); per token 1.745 -> 1.637
  cyc/token (-6.2%).
- Real-build peak RSS 144.8 -> 151.9 MiB (+4.9%, inside the +5% gate) on +17.9% source.
- Requested heap and allocation count exceed the Phase 0 gate absolutely (110 -> 315.5 MiB,
  68.5 -> 573.7 Kalloc): the Core IR stages (lowering, facts, dataflow, loan solver,
  instance graph) did not exist at Phase 0; their cost was accepted phase by phase. Within
  Phase 14 itself the pass recovered -5.7% cycles, -7.9% allocations, and -13.5% requested
  heap against the Phase 13 endpoint, with byte-identical C.

## Within-phase ledger (vs the Phase 13 endpoint, same session A/B)

| change | effect |
|---|---|
| shared lowering store (borrowck -> backend, one lowering per body) | codegen -12% Mcyc, -35 MiB |
| package-level ownership oracle + borrow pipeline (one per build) | -49 Kalloc, -55 MiB heap |
| persistent CTFE interpreter over the const loop | callee bodies lower once per build |
| whole build | 1383 -> 1304 Mcyc, 623 -> 574 Kalloc, 365 -> 315 MiB heap |

## AST census (SC_AST_STATS, post-HIR)

648759 nodes / 59.3 MiB retained arenas; sizeof(Node)=60. Top kinds: IDENTIFIER 44.1%,
MEMBER 12.8%, CALL 6.3%, TYPE_PATH 4.5%, LITERAL 4.3%. ~83k identifier nodes exist only to
carry a member-access name, but resolutions and deref_uses are keyed on those node ids (and
path members carry a second DefId), so inlining them is fact-relocation surgery, not a
deletion — recorded as designed follow-up work, not done in this pass.
