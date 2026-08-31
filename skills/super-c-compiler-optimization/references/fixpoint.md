# Byte-Identical Fixpoint Verification

The self-hosting contract requires that the compiler, when compiled by itself, produces
byte-identical output across two generations. Every optimization must be verified against
this contract.

## The Protocol

`super-c build` (default `dev` profile) puts the binary at `build/dev/super-c` and the
generated C under `build/dev/gen/`.

```sh
# 1. Clean state — the content-hash cache can serve stale bytes; never verify
#    incrementally, and do not rely on `touch` (hashes ignore timestamps).
rm -rf /tmp/fix
mkdir /tmp/fix

# 2. Copy the source tree (no build/ directory, no caches)
cp -R . /tmp/fix/tree

# 3. Build gen-1: the current compiler builds itself
cd /tmp/fix/tree
super-c build
cp -R build/dev/gen /tmp/fix/gen1
cp build/dev/super-c /tmp/fix/gen1-bin

# 4. Build gen-2: the gen-1 binary builds the same source
rm -rf build
/tmp/fix/gen1-bin build
cp -R build/dev/gen /tmp/fix/gen2

# 5. Diff gen-1 vs gen-2 emitted C
diff -r /tmp/fix/gen1 /tmp/fix/gen2
```

An empty diff means the fixpoint holds. **Any** non-empty diff is a semantic regression
unless the contract itself is intentionally changed.

## Absolute Paths in the Generated Tree

Three generated files embed absolute `#include` paths to the repo's `ffi/` and
`driver_shim` headers: `__ext0_sc_rt.c`, `__ext1_driver_shim.c`, and `__sc_types.h`.

- **Gen-1 vs gen-2 in the same tree** (the protocol above): both generations embed the
  same paths, so no exclusion is needed — diff everything.
- **A/B comparison across two different tree copies** (before-change vs after-change):
  the embedded paths differ by construction. Exclude or normalize those three files:

```sh
diff -r --exclude='__ext0_sc_rt.c' --exclude='__ext1_driver_shim.c' \
        --exclude='__sc_types.h' /tmp/a/gen /tmp/b/gen
# then compare the three excluded files with the path prefix normalized out
```

## Common Fixpoint Breakages

| Symptom | Cause |
|---------|-------|
| Non-deterministic symbol order | Hash map iteration order leaked into output |
| Different interning IDs | New interning entries from optimization code |
| Missing or extra function | Dead code elimination changed by optimization |
| Different constant values | Compile-time evaluation order dependency |
| Different line/column in emitted comments | Formatter or emitter position tracking changed |

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
