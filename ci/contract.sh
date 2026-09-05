# Super-C compatibility contract, version 1.
#
# Sourced by ci/gate.sh (correctness) and ci/perf_gate.sh / ci/bench_matrix.sh (performance). Every
# input file, option and command a gate uses is named here, in the order the gates apply it; no gate
# derives its inputs from a directory listing (a listing is only ever compared AGAINST this file).
# Change a value here and bump CONTRACT_VERSION; a gate that finds the tree and this file disagreeing
# fails.
CONTRACT_VERSION=1

# ---- the compiler under contract --------------------------------------------------------------------
CONTRACT_ROOT=src/main.spc
CONTRACT_MANIFEST=build.toml
CONTRACT_STD=std
CONTRACT_FFI=ffi
# The installed binary every command below runs; `super-c build` installs the dev profile there,
# `super-c release` the release profile.
CONTRACT_BIN=./super-c

# ---- targets, profiles, commands -----------------------------------------------------------------------
# Every target must complete a transpile of the compiler (`super-c src/main.spc --target=T`, emit only);
# the host target is also compiled and linked.
CONTRACT_TARGETS="macos linux windows wasm"
# Every built-in profile must build the compiler on the host (`super-c build --profile=P`). The `test`
# profile builds only the test runner and is exercised by CONTRACT_CMD_TEST.
CONTRACT_PROFILES="dev debug release bench race"
# The commands, exactly as the gates run them (<T> is one of CONTRACT_TARGETS).
CONTRACT_CMD_BUILD="./super-c build"
CONTRACT_CMD_FMT="SC_LEAK_CHECK=fatal ./super-c fmt src std ffi tests bench ci --check"
CONTRACT_CMD_LINT="SC_LEAK_CHECK=fatal ./super-c lint src std ffi tests bench ci examples --target=<T>"
CONTRACT_CMD_TEST="SC_LEAK_CHECK=fatal ./super-c test --quiet"
CONTRACT_CMD_BENCH="./super-c bench --bench-filter=self_transpile"
# The two-generation self-hosting fixpoint, in a clean copy of src/, std/, ffi/ and build.toml:
#   gen1: ./super-c build            (copied beside the tree, so std/ffi resolve inside the copy)
#   gen2: build/dev/super-c build    (the gen1 binary, after removing build/)
# and the two emitted build/raw trees must be byte-identical except CONTRACT_NONDET_FILES.
CONTRACT_FIXPOINT_GEN1="./super-c build"
CONTRACT_FIXPOINT_GEN2="./gen1-super-c build"
# The worker-count identity: the same gen1 binary, `--jobs=1` against `--jobs=<max>`, same comparison.
CONTRACT_WORKERS_MIN=1

# ---- C compilation --------------------------------------------------------------------------------------
# The manifest's base C flags (build.toml `cstd` default) and the strict set the warnings gate adds when it
# compiles every emitted translation unit with `-fsyntax-only`.
CONTRACT_CSTD="-std=c11 -D_POSIX_C_SOURCE=200809L"
CONTRACT_STRICT_CFLAGS="-Wall -Wextra -Werror"

# ---- readability of the emitted C tree (build/raw) ------------------------------------------------------
# Checked by the gate on the gen1 tree:
#   one <module>.h and <module>.c per emitted module (split TUs add <module>__p<k>.c),
#   the shared __sc_types.h and __sc_protos.h and the runtime super_rt.h/super_rt.c beside them,
#   every include relative (the tree compiles with no -I flag),
#   no #line directives, and symbols mangled by module path (lexer__Lexer__scan_tokens).
CONTRACT_READABLE_FORBIDDEN='^#line '
CONTRACT_READABLE_SHARED="super_rt.h super_rt.c __sc_types.h __sc_protos.h __sc_inst.c __ldflags"

# ---- accepted nondeterminism ---------------------------------------------------------------------------
# Excluded from every byte comparison: the per-TU cache embeds the compiler executable's path and mtime.
CONTRACT_NONDET_FILES=".tu_cache"
# Identical between generations in ONE checkout, different between checkouts (absolute #include paths to
# ffi/ and src/): excluded only when two checkouts are compared.
CONTRACT_PATH_FILES="__sc_types.h __ext0_sc_rt.c __ext1_driver_shim.c"

# ---- language fixtures and expected diagnostics --------------------------------------------------------
# The test corpus, one file per entry, sorted; every expected diagnostic is asserted inside the file that
# provokes it. The gate fails when tests/ holds a file not listed here or lacks one that is.
CONTRACT_TESTS="tests/ast_fprint_test.spc
tests/ast_test.spc
tests/bce_test.spc
tests/borrow_diff_test.spc
tests/borrow_gen_test.spc
tests/borrow_ir_test.spc
tests/cancel_test.spc
tests/cemit_test.spc
tests/cli_build_variants_test.spc
tests/cli_codegen_paths_test.spc
tests/cli_conv_widen_test.spc
tests/cli_devcheck_test.spc
tests/cli_fmt_test.spc
tests/cli_harness.spc
tests/cli_project_test.spc
tests/cli_stats_test.spc
tests/cli_subcommands_test.spc
tests/cli_test.spc
tests/codegen_run_test.spc
tests/codegen_test.spc
tests/core_ir_test.spc
tests/cross_target_helpers_test.spc
tests/ctfe_reflect_test.spc
tests/doc_test.spc
tests/drops_test.spc
tests/errors_test.spc
tests/float_test.spc
tests/fmt_test.spc
tests/harness.spc
tests/infer_test.spc
tests/infer_unit_test.spc
tests/int_test.spc
tests/layout_test.spc
tests/lexer_test.spc
tests/lint_test.spc
tests/lsp_incr_test.spc
tests/lsp_json_test.spc
tests/lsp_server_test.spc
tests/lsp_text_test.spc
tests/lsp_transport_test.spc
tests/lsp_v2_test.spc
tests/map_test.spc
tests/parser_test.spc
tests/pattern_test.spc
tests/raii_gen_test.spc
tests/resolver_test.spc
tests/token_test.spc
tests/toml_test.spc
tests/typechecker_test.spc
tests/vector_test.spc
tests/zst_test.spc"
CONTRACT_EXAMPLES="examples/language_demo.spc"
# Sanitizer-lane programs (ThreadSanitizer under the race profile) and the benchmark sources.
CONTRACT_CI_PROGRAMS="ci/parallel_smoke.spc
ci/race_hunt.spc
ci/cancel_hunt.spc"
CONTRACT_BENCH_FILES="bench/bench_shim.spc
bench/concurrency_bench.spc
bench/macro_bench.spc
bench/micro_bench.spc
bench/transpile_bench.spc"
