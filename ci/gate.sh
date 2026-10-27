#!/bin/sh
# The correctness gate, one command, with the settings in ci/contract.sh. Run from the repository root
# (or through `super-c command gate`):
#   1. check.sh: canonical formatting, lint per target, the test corpus, the concurrency exercisers, and
#      the two-stage rebuild from the latest release (the compiler builds its own sources);
#   2. the std package rules (tools/std_packages over std/packages.toml): no undeclared package, no
#      upward or cyclic tier edge, and no platform FFI outside its exemptions;
#   3. the two-generation fixpoint: gen1 and gen2 are byte-identical binaries;
#   4. the worker-count identity, run by generation two: one worker and every core under each
#      task-delay seed emit byte-identical C (`--emit-c`), publish the same package type table and item
#      index, and print the same diagnostics; one worker and every core give byte-identical native objects;
#   5. the emitted C tree meets the readability rules, and with a C compiler in SC_TEST_CC (the
#      comparison job) every unit compiles under the strict warning set.
# Any failure stops the gate with a nonzero exit. Scratch trees live under $TMPDIR and are removed.
# `sh ci/gate.sh --core` skips step 1: check.sh runs it last, over the compiler its bootstrap step
# installed, and CI runs it after its own build and test steps.
# The generations build under the test profile (optimized, overflow checks kept): every build they run
# is faster.
set -eu
cd "$(dirname "$0")/.."
. ci/contract.sh
mode=${1:-}
case "$mode" in
"" | --core) ;;
*) printf 'usage: sh ci/gate.sh [--core]\n' >&2; exit 2 ;;
esac

step() { printf '\ngate: %s\n' "$1"; }
fail() { printf 'gate: FAILED: %s\n' "$1" >&2; exit 1; }
ncpu=$(getconf _NPROCESSORS_ONLN)
# Windows: binaries carry `.exe`.
x=${BINEXT:-}

if [ -z "$mode" ]; then
    step "check.sh (format, lint, tests, concurrency exercisers, release bootstrap)"
    SC_GATE_OUTER=1 ./check.sh
fi

# check.sh leaves ./super-c as the two-stage rebuild of the current source; every step below uses a copy
# of it inside a clean tree so std/ffi resolve there and no cache of this checkout takes part.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tree="$tmp/tree"
mkdir -p "$tree"
cp -R src std ffi build.toml "$tree/"
rm -rf "$tree/src/build"
cp "$CONTRACT_BIN$x" "$tree/super-c$x"

step "std packages (tiers, platform FFI)"
SC_LEAK_CHECK=fatal "$CONTRACT_BIN$x" build tools/std_packages --out-dir="$tmp/std-packages" -o "$tmp/std-packages/std-packages$x" >/dev/null || fail "the std package checker does not build"
SC_LEAK_CHECK=fatal "$tmp/std-packages/std-packages$x" std || fail "std package rules (above)"

# Byte comparison of two emitted trees, minus the accepted nondeterminism.
same_tree() {
    ex=""
    for n in $CONTRACT_NONDET_FILES; do ex="$ex --exclude=$n"; done
    diff -r $ex "$1" "$2"
}

step "fixpoint: gen1 vs gen2"
# Each generation links under one name (`build/test/super-c`): a binary records it.
( cd "$tree" && SC_LEAK_CHECK=fatal "./super-c$x" build --profile=test >/dev/null )
mv "$tree/build/test/super-c$x" "$tree/gen1-super-c$x"
rm -rf "$tree/build"
( cd "$tree" && SC_LEAK_CHECK=fatal SC_BC_VALIDATE=1 SC_TYPE_VALIDATE=1 "./gen1-super-c$x" build --profile=test >/dev/null )
cmp "$tree/gen1-super-c$x" "$tree/build/test/super-c$x" || fail "gen1 and gen2 are different binaries"
# Generation two runs every build below.
mv "$tree/build/test/super-c$x" "$tree/gen2-super-c$x"
echo "gate: byte-identical"

# One C emission of the tree by gen2 (`--emit-c`): $1 workers, $2 the SC_TASK_DELAY seed (empty = none),
# $3 the record name under $tmp (<name>-build/debug/raw, <name>-types, <name>-err).
gen2_build() {
    ( cd "$tree" && SC_LEAK_CHECK=fatal SC_BC_VALIDATE=1 SC_TYPE_VALIDATE=1 SC_ITEM_STATS=1 SC_TYPE_TABLE="$tmp/$3-types" env ${2:+SC_TASK_DELAY=$2} "./gen2-super-c$x" build --jobs="$1" --emit-c --out-dir="$tmp/$3-build" >/dev/null 2>"$tmp/$3-err" ) || {
        cat "$tmp/$3-err" >&2
        fail "gen2 build $3 (--jobs=$1${2:+, SC_TASK_DELAY=$2}) failed (above)"
    }
}
# The identity of two records: the emitted tree, the type table, the item index digest, the
# diagnostics (stderr without the measurement lines).
same_record() {
    same_tree "$tmp/$1-build/debug/raw" "$tmp/$2-build/debug/raw" || fail "$1 and $2 emitted different C (above)"
    cmp "$tmp/$1-types" "$tmp/$2-types" || fail "$1 and $2 published different type tables"
    da=$(grep -o 'digest [0-9]*' "$tmp/$1-err") ; db=$(grep -o 'digest [0-9]*' "$tmp/$2-err")
    [ -n "$da" ] && [ "$da" = "$db" ] || fail "$1 and $2 built different item indexes ($da vs $db)"
    grep -v '^item-stats' "$tmp/$1-err" >"$tmp/$1-diag" || true
    grep -v '^item-stats' "$tmp/$2-err" >"$tmp/$2-diag" || true
    diff "$tmp/$1-diag" "$tmp/$2-diag" || fail "$1 and $2 printed different diagnostics (above)"
}

step "worker identity: --jobs=$CONTRACT_WORKERS_MIN vs --jobs=$ncpu under SC_TASK_DELAY seeds $CONTRACT_DELAY_SEEDS"
gen2_build "$CONTRACT_WORKERS_MIN" "" j1
for seed in $CONTRACT_DELAY_SEEDS; do
    gen2_build "$ncpu" "$seed" "jn$seed"
    same_record j1 "jn$seed"
    echo "gate: seed $seed byte-identical"
done

step "native worker identity: --jobs=$CONTRACT_WORKERS_MIN vs --jobs=$ncpu"
for j in "$CONTRACT_WORKERS_MIN" "$ncpu"; do
    ( cd "$tree" && SC_LEAK_CHECK=fatal "./gen2-super-c$x" build --jobs="$j" --out-dir="$tmp/nat$j-build" -o "$tmp/nat$j-bin$x" >/dev/null ) || fail "gen2 native build (--jobs=$j) failed"
done
same_tree "$tmp/nat$CONTRACT_WORKERS_MIN-build/debug/raw" "$tmp/nat$ncpu-build/debug/raw" || fail "one worker and every core built different native objects (above)"
echo "gate: native objects byte-identical"

step "readability and strict C warnings"
# The one-worker tree: every record above equals it. `__units` names its compile units (a pack or unity
# file is the only unit of the member files it includes) and `__cflags` their flags.
raw="$tmp/j1-build/debug/raw"
[ -s "$raw/__units" ] || fail "strict warnings: no unit in $raw"
if [ -n "${SC_TEST_CC:-}" ]; then
    # BSD xargs runs nothing on empty input and exits 0: the list is checked above.
    ( cd "$raw" && while IFS= read -r c; do printf '%s\0' "$c"; done <__units |
        xargs -0 -n 8 -P "$ncpu" $SC_TEST_CC $(cat __cflags) $CONTRACT_STRICT_CFLAGS -fsyntax-only ) || fail "strict warnings (above)"
    echo "gate: $(wc -l <"$raw/__units" | tr -d ' ') units clean"
else
    echo "gate: strict C warnings skipped: SC_TEST_CC names no C compiler (the comparison job's step)"
fi
if grep -rq "$CONTRACT_READABLE_FORBIDDEN" "$raw"; then
    fail "readability: a #line directive in the emitted tree"
fi
for n in $CONTRACT_READABLE_SHARED; do [ -f "$raw/$n" ] || fail "readability: missing shared file $n"; done
for c in $(find "$raw" -name '*.c' | sort); do
    case "${c##*/}" in
    __ext*|__sc_registry.c|__sc_pack*|*__p[0-9]*.c|*__inst.c) continue ;;
    esac
    [ -f "${c%.c}.h" ] || fail "readability: $c has no header beside it"
done
printf '\ngate: OK\n'
