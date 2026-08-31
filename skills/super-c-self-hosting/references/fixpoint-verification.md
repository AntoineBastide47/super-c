# Fixpoint Verification Protocol

The clean-room protocol for verifying the byte-identical two-generation fixpoint.

**Emission is path-dependent** — emitted hashes mix path strings — so gen-1 and gen-2
must emit at the **same path**. One work tree, two generations; never compare trees
built at two different locations.

## Steps (mirrors the CI fixpoint job)

```sh
set -eu
# 1. Clean work tree: sources only, no build/ dirs, no build.toml, no caches
rm -rf /tmp/fix && mkdir /tmp/fix
cp -R src std ffi /tmp/fix/ && rm -rf /tmp/fix/src/build

# 2. Gen-1: the current compiler emits the whole compiler
super-c build /tmp/fix/src/main.spc -o /tmp/fix/gen1-bin
mv /tmp/fix/src/build /tmp/fix/gen1          # C tree is under gen1/raw/

# 3. Gen-2 binary: compile gen-1's emitted C directly
cc -O1 -std=gnu11 $(find /tmp/fix/gen1/raw -name '*.c') \
   $(cat /tmp/fix/gen1/raw/__ldflags) -o /tmp/fix/gen2-bin

# 4. Gen-2 emits the SAME input at the SAME path
/tmp/fix/gen2-bin build /tmp/fix/src/main.spc -o /tmp/fix/discard-bin

# 5. Diff the two emissions — expect empty, no exclusions
diff -r /tmp/fix/gen1 /tmp/fix/src/build
```

An empty diff means the fixpoint holds. **Any** difference is a semantic regression
unless the contract itself is intentionally changed.

## Absolute Paths in the Emitted Tree

Three emitted files embed absolute `#include` paths (the ExtC wrappers and the types
header): `__ext0_sc_rt.c`, `__ext1_driver_shim.c`, `__sc_types.h`. In this protocol both
generations emit in the same tree, so the paths are identical and **no exclusion is
needed**. Only a comparison across two different tree copies would need those three
files normalized — and path-dependent emission makes such a comparison invalid anyway.

## Do Not Trust the Cache

The build engine's content-hash cache can serve stale bytes. Never verify the fixpoint
with an incremental build; always start from a tree with no `build/` directory. Do not
use `touch` to invalidate — content hashes ignore timestamps.

## Common Breakages

| Symptom | Cause |
|---------|-------|
| Non-deterministic symbol order | Hash map iteration order leaked into output |
| Different interning IDs | New interning entries from changed code |
| Missing or extra function | Dead code elimination changed |
| Different constant values | Compile-time evaluation order dependency |
| Whole-tree diff from a path change | Trees emitted at different paths (see above) |
