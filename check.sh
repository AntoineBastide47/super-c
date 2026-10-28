#!/bin/sh
set -e

# Run as a git hook, this script inherits the repository-local GIT_* variables (GIT_DIR, GIT_INDEX_FILE, ...).
# Tests that run git in their own scratch repositories would act on THIS repository through them.
unset $(git rev-parse --local-env-vars)

# 1) Formatting must already be canonical (no auto-rewrite: the check fails instead).
printf 'check: formatting (fmt --check)\n'
if ! files=$(SC_LEAK_CHECK=fatal ./super-c fmt --check); then
    printf 'check: FAILED -- these files are not canonically formatted:\n' >&2
    printf '%s\n' "$files" | sed 's/^/  /' >&2
    printf 'fix with: ./super-c fmt\n' >&2
    exit 1
fi

# 2) Full lint, once per supported target (@platform gates differ); any warning fails the check.
for target in macos linux windows; do
    printf 'check: lint (--target=%s)\n' "$target"
    if ! SC_LEAK_CHECK=fatal ./super-c lint --target="$target"; then
        printf 'check: FAILED -- lint warnings above (--target=%s) must be fixed (or try: ./super-c lint --fix <file>)\n' "$target" >&2
        exit 1
    fi
done

# 3) Full test suite with the current compiler (built first if stale), leak-gated: every process in
# the run (compiler, harness, spawned servers, compiled fixtures) exits nonzero on leaks/double frees.
# SC_LIR checks both builds (the compiler under test and the suite) with LIR: every body lowers and
# passes the verifier (a module the per-TU cache replays passed it when recorded); the C is the same.
# The evaluator and the text form have their own tests (tests/codegen/lir_eval_test.spc, lir_test.spc).
printf 'check: tests\n'
if ! SC_LEAK_CHECK=fatal SC_LIR=1 ./super-c test --quiet; then
    printf 'check: FAILED -- test failures above\n' >&2
    exit 1
fi

# 3b) The concurrency exercisers, one after the other: each checks its counts and bounds its waits, so a
# lost wake or a broken count fails it with a nonzero exit.
printf 'check: concurrency exercisers\n'
runlog=$(mktemp)
for prog in parallel_smoke race_hunt cancel_hunt queue_hunt io_hunt blocking_hunt mutex_hunt; do
    if ! ./super-c build "ci/$prog.spc" -o ./hunt-bin >/dev/null 2>&1; then
        rm -f "$runlog" ./hunt-bin
        printf 'check: FAILED -- could not build ci/%s.spc\n' "$prog" >&2
        exit 1
    fi
    rc=0
    ./hunt-bin >/dev/null 2>"$runlog" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'check: FAILED -- ci/%s.spc (exit %s):\n' "$prog" "$rc" >&2
        cat "$runlog" >&2
        rm -f "$runlog" ./hunt-bin
        exit 1
    fi
done
rm -f "$runlog" ./hunt-bin

# 4) Bootstrap from the latest release binary; any failure fails the check.
# Stage 0: the release binary builds current source (`--bootstrap-tags`). Stage 0 then rebuilds itself:
# two generations from current source.
printf 'check: bootstrap rebuild from the latest release\n'
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if ! gh release download --pattern super-c-macos-arm64.tar.gz --dir "$tmp"; then
    printf 'check: FAILED -- could not download the release bootstrap binary (gh auth / network?)\n' >&2
    exit 1
fi
tar xzf "$tmp/super-c-macos-arm64.tar.gz" -C "$tmp" super-c-macos-arm64/super-c
mv "$tmp/super-c-macos-arm64/super-c" ./super-c
chmod +x ./super-c
if ! ./super-c build --bootstrap-tags -o stage0-super-c; then
    printf 'check: FAILED -- the release binary cannot build the current source\n' >&2
    exit 1
fi
# Under the test profile (optimized, overflow checks kept), in a tree of its own (the test runner's is
# build/test): every later step runs this compiler.
if ! SC_LEAK_CHECK=fatal ./stage0-super-c build --profile=test --out-dir=build/bootstrap; then
    rm -f stage0-super-c
    printf 'check: FAILED -- two-stage rebuild from the release bootstrap broke (see build output above)\n' >&2
    exit 1
fi
rm -f stage0-super-c

# 5) The correctness gate's own checks over the rebuilt compiler (ci/gate.sh --core): the two-generation
# fixpoint of the binaries under the validation switches, the one-worker and every-core identity under
# each task-delay seed (emitted C, type table, item index digest, diagnostics, native objects), and the
# readability of the emitted C and its compile under the strict warning set, by SC_TEST_CC, else by cc. The
# full gate runs them itself, so it skips this step.
if [ -z "${SC_GATE_OUTER:-}" ]; then
    printf 'check: correctness gate core (ci/gate.sh --core)\n'
    if ! SC_TEST_CC="${SC_TEST_CC:-cc}" sh ci/gate.sh --core; then
        printf 'check: FAILED -- ci/gate.sh --core (above)\n' >&2
        exit 1
    fi
fi
printf 'check: OK\n'
