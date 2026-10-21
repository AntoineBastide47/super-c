# The settings of the correctness gate, sourced by ci/gate.sh.

# The installed binary every command below runs; `super-c build` installs the debug profile there,
# `super-c release` the release profile.
CONTRACT_BIN=./super-c

# Every built-in profile but test must build the compiler on the host (`super-c build --profile=P`).
# The `test` profile builds the test runner and the compiler under test, and `super-c test` exercises it.
CONTRACT_PROFILES="debug release bench race"
# The worker-count identity: gen2, `--jobs=1` (also compared with gen1's tree) against `--jobs=<max>` under
# every SC_TASK_DELAY seed below: the same tree comparison, the SC_TYPE_TABLE dumps, the SC_ITEM_STATS
# index digest and the diagnostics byte for byte. check.sh (the commit hook) runs these steps on each run
# (`ci/gate.sh --core`).
CONTRACT_WORKERS_MIN=1
CONTRACT_DELAY_SEEDS="1 2 3"

# ---- C compilation --------------------------------------------------------------------------------------
# The manifest's base C flags (build.toml `cstd` default) and the strict set the warnings gate adds when it
# compiles every emitted translation unit with `-fsyntax-only` (with -funsigned-char, -ffp-contract=off and
# the -fno-builtin list of each transcendental libm call, which the build engine passes to every compile:
# the language's char is unsigned, floats never fuse, a libm call runs as written; LIBM_AS_WRITTEN in
# src/build_system/build.spc).
CONTRACT_CSTD="-std=c11 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700"
CONTRACT_LIBM_CFLAGS=""
for f in sin cos tan asin acos atan atan2 sinh cosh tanh asinh acosh atanh exp exp2 expm1 log log2 log10 log1p pow cbrt hypot; do
    CONTRACT_LIBM_CFLAGS="$CONTRACT_LIBM_CFLAGS -fno-builtin-$f -fno-builtin-${f}f"
done
CONTRACT_STRICT_CFLAGS="-Wall -Wextra -Werror -funsigned-char -ffp-contract=off$CONTRACT_LIBM_CFLAGS"

# ---- readability of the emitted C tree (build/debug/raw) ------------------------------------------------
# Checked by the gate on the gen1 tree:
#   one <module>.h and <module>.c per emitted module (sharded modules add <module>__p<k>.c, a
#   module owning generic instances <module>__inst.c, one definition header per type __sc_t/<name>.h),
#   the shared __sc_fwd.h, the registry TU, the packs __sc_pack<k>.c of the small units, the manifest
#   and the runtime super_rt.h/super_rt.c,
#   every include relative (the tree compiles with no -I flag),
#   no #line directives, and symbols mangled by module path (lexer__Lexer__scan_tokens).
CONTRACT_READABLE_FORBIDDEN='^#line '
CONTRACT_READABLE_SHARED="super_rt.h super_rt.c __sc_fwd.h __sc_registry.c __sc_manifest __ldflags"

# ---- accepted nondeterminism ---------------------------------------------------------------------------
# Excluded from every byte comparison: the per-TU cache header hashes the compiler that wrote it, and the
# two generations are different binaries.
CONTRACT_NONDET_FILES=".tu_cache"
