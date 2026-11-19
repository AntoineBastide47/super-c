# The settings of the correctness gate, sourced by ci/gate.sh.

# The installed binary every command below runs; `super-c build` installs the debug profile there,
# `super-c release` the release profile.
CONTRACT_BIN=./super-c

# The worker-count identity: gen2, `--jobs=1` against `--jobs=<max>` under every SC_TASK_DELAY seed below: the same tree comparison, the SC_TYPE_TABLE dumps, the SC_ITEM_STATS
# index digest and the diagnostics byte for byte. check.sh (the commit hook) runs these steps on each run
# (`ci/gate.sh --core`).
CONTRACT_WORKERS_MIN=1
CONTRACT_DELAY_SEEDS="1 2 3"

# ---- C compilation --------------------------------------------------------------------------------------
# The strict set the warnings gate adds to the tree's own `__cflags` (the dialect, the unsigned char, no
# float contraction and the libm calls as written) when the comparison job's C compiler (SC_TEST_CC)
# compiles every emitted translation unit with `-fsyntax-only`.
CONTRACT_STRICT_CFLAGS="-Wall -Wextra -Werror"

# ---- readability of the emitted C tree (build/debug/raw, `--emit-c`) -----------------------------------
# Checked by the gate on generation two's one-worker tree:
#   one <module>.h and <module>.c per emitted module (sharded modules add <module>__p<k>.c, a
#   module owning generic instances <module>__inst.c, one definition header per type __sc_t/<name>.h),
#   the shared __sc_fwd.h, the registry TU, the packs __sc_pack<k>.c of the small units, the manifest
#   and the runtime header super_rt.h,
#   every include relative (the tree compiles with no -I flag),
#   no #line directives, and symbols mangled by module path (lexer__Lexer__scan_tokens).
CONTRACT_READABLE_FORBIDDEN='^#line '
CONTRACT_READABLE_SHARED="super_rt.h __sc_fwd.h __sc_registry.c __sc_manifest __ldflags"

# ---- accepted nondeterminism ---------------------------------------------------------------------------
# Excluded from every byte comparison of emitted trees: the per-TU cache image, a cache rather than output.
CONTRACT_NONDET_FILES=".tu_cache"
