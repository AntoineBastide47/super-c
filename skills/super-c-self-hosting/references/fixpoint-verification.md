# Fixpoint Verification Protocol

The clean-room protocol for verifying the byte-identical two-generation fixpoint.
`sh ci/gate.sh` runs it (and, with generation two, the one-worker versus every-core
identity check under each `SC_TASK_DELAY` seed of `ci/contract.sh`: emitted tree, type
table, item index digest and diagnostics) as part of the correctness gate; the steps
below are the manual form.

The gate keeps the per-TU cache on and excludes the files in `CONTRACT_NONDET_FILES`
(`.tu_cache`) from every tree comparison (`same_tree` in `ci/gate.sh`). It excludes nothing
else and normalizes nothing: both generations build in one checkout, so the
files with absolute paths are identical. The manual form
below disables every cache and compares the two binaries.

Emission hashes include paths. Both generations must use the same source, output,
standard-library, and FFI paths. Place the bootstrap binary beside the copied `std/`
and `ffi/` directories so executable-relative library lookup stays consistent.

## Steps

Run from the repository root with a rebuilt `./super-c`.

```sh
set -eu
fix_dir=$(mktemp -d /tmp/super-c-fix.XXXXXX)
rsync -a --exclude=build src std ffi build.toml "$fix_dir/"
cp ./super-c "$fix_dir/bootstrap-bin"

export SC_NO_CACHE=1
export SC_NO_EMIT_CACHE=1
export SC_NO_TU_CACHE=1

# Both generations link under the same name: the binary records its output path.
(cd "$fix_dir" && ./bootstrap-bin build --profile=test)
mv "$fix_dir/build/test/super-c" "$fix_dir/gen1-bin"
rm -rf "$fix_dir/build"
(cd "$fix_dir" && SC_BC_VALIDATE=1 SC_TYPE_VALIDATE=1 ./gen1-bin build --profile=test)
cmp "$fix_dir/gen1-bin" "$fix_dir/build/test/super-c"
```

The binaries must be identical. For the additional worker-count checks of C trees,
native objects, type tables, item indexes and diagnostics, run `sh ci/gate.sh --core`.
To compile a C tree, use `ci/cc_tree.sh`, never a command over every `.c` file: a pack
or unity file includes its members, so compiling every file defines those members twice.

## Absolute Paths in the Emitted Tree

`__sc_fwd.h` embeds absolute include paths, `__sc_manifest` records their hashes, and every std TU that spells an assertion
location embeds the absolute std path (for example `__std/int__inst.c`). A bootstrap binary
outside the temporary tree can select a different `std/` and `ffi/` even when the source
and output paths match. Correct the library selection and repeat from clean output
trees; do not normalize or exclude these files. Never compare trees from two checkouts:
run both compilers in one tree (see the optimization skill's `references/fixpoint.md`).

## Do Not Trust the Cache

Disable build-record, emit-stamp, and per-TU caches for both generations with the three
environment variables above. Start each generation without a `build/` directory.
`touch` does not invalidate content-hash caches.

The per-TU cache header hashes the running compiler's content (`header_hash` in
`src/driver/tuc.spc`, through `compiler_id`). Gen-1 and gen-2 are different binaries, so
even a fresh cache file differs between generations.
`SC_NO_TU_CACHE=1` prevents that file from being written; deleting it after emission
would hide a difference instead of checking the complete output tree.

## Common Breakages

| Symptom | Cause |
|---------|-------|
| Non-deterministic symbol order | Hash map iteration order leaked into output |
| Different interning IDs | New interning entries from changed code |
| Missing or extra function | Dead code elimination changed |
| Different constant values | Compile-time evaluation order dependency |
| Whole-tree diff from a path change | Trees emitted at different paths (see above) |
| Different absolute include paths | Compilers selected different library roots |
| Only `.tu_cache` differs | Per-TU caching was not disabled |
| `super_rt.h` static assertion on `CHAR_MIN` | `-funsigned-char` is missing from the C compile |
