# Migration Phase 0 baseline

Comparison record for the transpiler architecture migration (plans/migration.md).
All later phase gates measure against this report. Recorded before any Phase 1+ change.

## Environment

- Compiler commit: `e274a7c0f64f2a5e08eb32266cb5441f961b5bb7`
- Bootstrap: self-built `./super-c` from the same commit (release profile)
- C compiler: Apple clang 21.0.0 (clang-2100.1.1.101), target arm64-apple-darwin25.5.0
- CPU: Apple M3 Max (14 cores), macOS 26.5
- Build profile: release; benchmark single-threaded, 100 iterations

## Self-transpile benchmark (`super-c bench`, transpile lane)

Corpus: src/main.spc — 58 modules, 1873 decls, 93493 lines, 681486 tokens,
3676.3 KiB source -> 7250.7 KiB C, 540338 AST nodes.

| phase     | avg ms | Mcyc | Kalloc | MiB   | share |
|-----------|--------|------|--------|-------|-------|
| lex       | 17.58  | 34   | 0.1    | 6.64  | (of parse) |
| parse     | 43.18  | 84   | 0.9    | 46.63 | 7.0%  |
| resolve   | 24.78  | 48   | 9.4    | 4.60  | 4.0%  |
| typecheck | 89.87  | 175  | 8.1    | 35.83 | 14.7% |
| borrowck  | 28.52  | 56   | 6.2    | 3.67  | 4.7%  |
| propagate | 227.55 | 439  | 2.5    | 4.09  | 37.1% |
| codegen   | 199.21 | 388  | 41.4   | 15.16 | 32.5% |
| total     | 613.11 | 1189 | 68.5   | 109.98| —     |

- codegen split: headers 70.75 ms + sources 126.90 ms
- heap: 110.0 MiB requested per iteration; peak RSS 144.8 MiB

Gate limits for every later phase (from the plan): end-to-end time +3%, peak RSS +5%
(post old-path removal), allocation count +10%, generated C size +1%; dual-path
temporary RSS at most +15%.

## Generated C output

- Serial emit (`SC_SERIAL_EMIT=1`), release build of src/main.spc: 107 files, 7388 KiB.
- Combined tree hash (sorted `shasum -a 256` of all .c/.h, hashed again, first 16):
  `98b023a3c9207215`
- Worker-count check: `--jobs=1`, `--jobs=2`, `--jobs=14` produce the identical tree
  hash `98b023a3c9207215` (byte-identical to serial).

## Diagnostics

Negative-diagnostic expectations live in the test suite (tests/) and are exercised by
`super-c test`; the suite at this commit is the recorded snapshot (424 passing tests).

## Repository gates at baseline

- `super-c fmt src std ffi tests bench ci --check`: canonical (OK)
- `super-c lint ... --target=macos|linux|windows` with SC_LEAK_CHECK=fatal: 0 warnings on all three
- `SC_LEAK_CHECK=fatal super-c test`: 424 passed, 0 failed
- Two-generation bootstrap (`super-c command bootstrap`): OK

## Retained-memory counters

The plan's per-structure retained-memory counters (syntax AST, type pools, HIR, Core IR,
instance data, CTFE objects, output buffers) are added incrementally as each new structure
appears in later phases; at Phase 0 the recorded totals are the benchmark's per-phase
MiB/alloc columns above.
