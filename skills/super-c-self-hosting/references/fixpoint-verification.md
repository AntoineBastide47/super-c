# Fixpoint Verification Protocol

The clean-room protocol for verifying the byte-identical two-generation fixpoint.
`sh ci/gate.sh` runs it (and the one-worker versus every-core identity check) as part
of the correctness gate; the steps below are the manual form.

Emission hashes include paths. Both generations must use the same source, output,
standard-library, and FFI paths. Place the bootstrap binary beside the copied `std/`
and `ffi/` directories so executable-relative library lookup stays consistent.

## Steps

Run from the repository root with a rebuilt `./super-c`.

```sh
set -eu
# Fresh sources, no build directories or manifest.
fix_dir=$(mktemp -d /tmp/super-c-fix.XXXXXX)
rsync -a --exclude=build src std ffi "$fix_dir/"
cp ./super-c "$fix_dir/bootstrap-bin"

export SC_NO_CACHE=1
export SC_NO_EMIT_CACHE=1
export SC_NO_TU_CACHE=1

# Gen-1 emits the compiler using the copied libraries.
"$fix_dir/bootstrap-bin" build "$fix_dir/src/main.spc" -o "$fix_dir/gen1-bin"
mv "$fix_dir/src/build" "$fix_dir/gen1"

# Compile gen-1's emitted C directly.
cc -O1 -std=gnu11 -Wall -Wextra -Werror $(rg --files "$fix_dir/gen1/raw" -g '*.c') \
   $(cat "$fix_dir/gen1/raw/__ldflags") -o "$fix_dir/gen2-bin"

# Gen-2 uses the same inputs and output path, with no previous build tree.
"$fix_dir/gen2-bin" build "$fix_dir/src/main.spc" -o "$fix_dir/discard-bin"

# Require an empty diff, with no exclusions or normalization.
diff -r "$fix_dir/gen1" "$fix_dir/src/build"
```

An empty diff means the fixpoint holds. **Any** difference is a semantic regression
unless the contract itself is intentionally changed.

## Absolute Paths in the Emitted Tree

External-C wrappers and `__sc_types.h` embed absolute include paths. A bootstrap binary
outside the temporary tree can select a different `std/` and `ffi/` even when the source
and output paths match. Correct the library selection and repeat from clean output
trees; do not normalize or exclude these files.

## Do Not Trust the Cache

Disable build-record, emit-stamp, and per-TU caches for both generations with the three
environment variables above. Start each generation without a `build/` directory.
`touch` does not invalidate content-hash caches.

The per-TU cache header includes the running compiler's path and modification time
(`src/driver/tuc.spc:header_hash`). Even a fresh cache file can differ between generations.
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
