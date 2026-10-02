# Byte-Identical Fixpoint Verification

The self-hosting contract requires that the compiler, when compiled by itself, produces
byte-identical output across two generations. Every optimization must be verified against
this contract.

## The Protocol

`sh ci/gate.sh` runs the contract (`sh ci/gate.sh --core` skips `check.sh` and the
profile builds). The manual clean-room form is
[fixpoint-verification.md](../../super-c-self-hosting/references/fixpoint-verification.md)
in the self-hosting skill.

The emitted C tree is `gen_root`: `<root>/build/<profile>/raw` for a bare build,
`<out-dir>/<profile>/raw` for a manifest build. A manifest build also content-syncs it into
`<out-dir>/<profile>/gen` for the C compile; compare `raw`, the emitter's output.

The gate's form (`ci/gate.sh`, `ci/contract.sh`):

1. Copy `src`, `std`, `ffi` and `build.toml` into a clean tree, and the compiler beside
   them, so `std`/`ffi` resolve inside the copy.
2. Gen-1: `./super-c build` in the tree; keep `build/dev/raw` and `build/dev/super-c`.
3. Remove `build/`. Gen-2: the gen-1 binary, copied into the tree root, builds again.
4. `diff -r` the two `raw` trees, excluding only `CONTRACT_NONDET_FILES` (`.tu_cache`).

The per-TU cache header hashes the running compiler's content (`header_hash` in
`src/driver/tuc.spc`, `compiler_id` in `src/driver/util.spc`), so `.tu_cache` differs
between two generations by construction. Exclude it, or set `SC_NO_TU_CACHE=1` for both
generations: then the file is not written and the diff needs no exclusion. Any other
difference is a semantic regression unless the contract itself is intentionally changed.

## Absolute Paths in the Emitted Tree

Emission spells absolute paths: the include paths in `__sc_fwd.h` and the `@c.source`
wrappers (`__ext<N>_<stem>.c`), the content hash of `__sc_fwd.h` in `__sc_manifest`, and
the source location of every assertion in a `std` module (std paths resolve beside the
compiler binary, for example `__std/int__inst.c`).

- **Gen-1 vs gen-2, or an A/B of two compilers, in one tree:** both builds see the same
  paths when each compiler sits at the same place beside the same `std`/`ffi`. Diff
  everything (minus `.tu_cache` when the TU cache is on). The out-dir does not change the
  emitted tree.
- **Two different tree copies:** the paths differ by construction, in the files above and
  in every std TU that spells an assertion location. Do not compare across copies. Run
  both compilers in one tree instead.

## Common Fixpoint Breakages

| Symptom | Cause |
|---------|-------|
| Non-deterministic symbol order | Hash map iteration order leaked into output |
| Different interning IDs | New interning entries from optimization code |
| Missing or extra function | Dead code elimination changed by optimization |
| Different constant values | Compile-time evaluation order dependency |
| Different line/column in emitted comments | Formatter or emitter position tracking changed |
| Only `.tu_cache` differs | Per-TU cache on and not excluded |
| Path-only diffs in `__sc_fwd.h`, `__ext*`, `__sc_manifest`, std TUs | Builds ran in different trees or with different `std`/`ffi` roots |

## Prevention

- Never leak hash map iteration order into emitted output. Use sorted iteration or a
  deterministic insertion-order map.
- Prefilter without reordering: if you skip items during emission, skip them in-place
  rather than copying to a new container.
- Test the fixpoint after every structural change, not just at the end of a batch.

## The Bootstrap Command

The `build.toml` shortcut runs the full two-stage bootstrap:

```sh
super-c command bootstrap
```

This builds stage-1 with bootstrap tags, then uses stage-1 to build stage-2, and removes
stage-1. The output is the verified compiler binary.
