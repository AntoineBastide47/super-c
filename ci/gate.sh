#!/bin/sh
# The correctness gate, one command, with the settings in ci/contract.sh. Run from the repository root
# (or through `super-c command gate`):
#   1. check.sh: canonical formatting, lint per target, the test corpus, the sanitizer lanes, and the
#      two-stage rebuild from the latest release (the compiler builds its own sources);
#   2. the two-generation fixpoint: gen1 and gen2 emit byte-identical C;
#   3. the worker-count identity, run by generation two: one worker and every core under each
#      task-delay seed emit byte-identical C, publish the same package type table and item index,
#      and print the same diagnostics;
#   4. every emitted translation unit compiles under the strict warning set, and the tree meets the
#      readability rules.
# Any failure stops the gate with a nonzero exit. Scratch trees live under $TMPDIR and are removed.
# `sh ci/gate.sh --core` skips step 1: check.sh runs it last, over the compiler its bootstrap step
# installed, and CI runs it after its own build and test steps. `sh ci/gate.sh --profiles` builds the
# compiler under every built-in profile but test (which the test command builds) with the installed
# compiler: CI runs it in a job of its own beside `--core`, whose fixpoint proves the two generations
# emit the same C. The release and bench profiles link with full LTO, so a local gate leaves it to CI.
# The generations build under the test profile (optimized, overflow checks kept): the C they emit does
# not depend on the profile, and every build they run is faster.
set -eu
cd "$(dirname "$0")/.."
. ci/contract.sh
mode=${1:-}
case "$mode" in
"" | --core | --profiles) ;;
*) printf 'usage: sh ci/gate.sh [--core | --profiles]\n' >&2; exit 2 ;;
esac

step() { printf '\ngate: %s\n' "$1"; }
fail() { printf 'gate: FAILED: %s\n' "$1" >&2; exit 1; }
ncpu=$(getconf _NPROCESSORS_ONLN)
# Windows (mingw-w64): binaries carry `.exe`, and the C standard is SC_CSTD (mingw hides POSIX prototypes
# under -std=c11); every build passes it, as the CI build and test steps do.
x=${BINEXT:-}
cstd=${SC_CSTD:+--cstd=$SC_CSTD}

if [ -z "$mode" ]; then
    step "check.sh (format, lint, tests, sanitizer lanes, release bootstrap)"
    SC_GATE_OUTER=1 ./check.sh
fi

# check.sh leaves ./super-c as the two-stage rebuild of the current source; every step below uses a copy
# of it inside a clean tree so std/ffi resolve there and no cache of this checkout takes part. The object
# cache stays on: every build after gen1 emits the same C, so it recompiles nothing.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tree="$tmp/tree"
mkdir -p "$tree"
cp -R src std ffi build.toml "$tree/"
rm -rf "$tree/src/build"
cp "$CONTRACT_BIN$x" "$tree/super-c$x"

# Step 5: every built-in profile but test builds the compiler, each with builder $1 (in the tree).
profiles() {
    step "profiles ($CONTRACT_PROFILES)"
    for p in $CONTRACT_PROFILES; do
        ( cd "$tree" && SC_LEAK_CHECK=fatal "./$1" build --profile="$p" --out-dir="build/gate-$p" -o "build/gate-$p/super-c$x" ${cstd:+"$cstd"} >/dev/null ) || fail "profile $p"
        echo "gate: profile $p builds"
    done
}

if [ "$mode" = --profiles ]; then
    profiles "super-c$x"
    printf '\ngate: OK (profiles)\n'
    exit 0
fi

# Byte comparison of two emitted trees, minus the accepted nondeterminism.
same_tree() {
    ex=""
    for n in $CONTRACT_NONDET_FILES; do ex="$ex --exclude=$n"; done
    diff -r $ex "$1" "$2"
}

step "fixpoint: gen1 vs gen2"
( cd "$tree" && SC_LEAK_CHECK=fatal "./super-c$x" build --profile=test ${cstd:+"$cstd"} >/dev/null )
cp -R "$tree/build/test/raw" "$tmp/gen1-raw"
cp "$tree/build/test/super-c$x" "$tree/gen1-super-c$x"
rm -rf "$tree/build"
( cd "$tree" && SC_LEAK_CHECK=fatal SC_BC_VALIDATE=1 SC_TYPE_VALIDATE=1 "./gen1-super-c$x" build --profile=test ${cstd:+"$cstd"} >/dev/null )
same_tree "$tmp/gen1-raw" "$tree/build/test/raw" || fail "gen1 and gen2 emitted different C (above)"
# Generation two is compiled and run: every build below is its own.
cp "$tree/build/test/super-c$x" "$tree/gen2-super-c$x"
echo "gate: byte-identical"

# One build of the tree by gen2: $1 workers, $2 the SC_TASK_DELAY seed (empty = none), $3 the record
# name under $tmp (<name>-raw, <name>-types, <name>-err).
gen2_build() {
    rm -rf "$tree/build"
    ( cd "$tree" && SC_LEAK_CHECK=fatal SC_BC_VALIDATE=1 SC_TYPE_VALIDATE=1 SC_ITEM_STATS=1 SC_TYPE_TABLE="$tmp/$3-types" env ${2:+SC_TASK_DELAY=$2} "./gen2-super-c$x" build --jobs="$1" ${cstd:+"$cstd"} >/dev/null 2>"$tmp/$3-err" ) || { cat "$tmp/$3-err" >&2; fail "gen2 build $3 (--jobs=$1${2:+, SC_TASK_DELAY=$2}) failed (above)"; }
    cp -R "$tree/build/debug/raw" "$tmp/$3-raw"
}
# The identity of two records: the emitted tree, the type table, the item index digest, the
# diagnostics (stderr without the measurement lines).
same_record() {
    same_tree "$tmp/$1-raw" "$tmp/$2-raw" || fail "$1 and $2 emitted different C (above)"
    cmp "$tmp/$1-types" "$tmp/$2-types" || fail "$1 and $2 published different type tables"
    da=$(grep -o 'digest [0-9]*' "$tmp/$1-err") ; db=$(grep -o 'digest [0-9]*' "$tmp/$2-err")
    [ -n "$da" ] && [ "$da" = "$db" ] || fail "$1 and $2 built different item indexes ($da vs $db)"
    grep -v '^item-stats' "$tmp/$1-err" >"$tmp/$1-diag" || true
    grep -v '^item-stats' "$tmp/$2-err" >"$tmp/$2-diag" || true
    diff "$tmp/$1-diag" "$tmp/$2-diag" || fail "$1 and $2 printed different diagnostics (above)"
}

step "worker identity: --jobs=$CONTRACT_WORKERS_MIN vs --jobs=$ncpu under SC_TASK_DELAY seeds $CONTRACT_DELAY_SEEDS"
gen2_build "$CONTRACT_WORKERS_MIN" "" j1
same_tree "$tmp/gen1-raw" "$tmp/j1-raw" || fail "gen2 with one worker and gen1 emitted different C (above)"
for seed in $CONTRACT_DELAY_SEEDS; do
    gen2_build "$ncpu" "$seed" "jn$seed"
    same_record j1 "jn$seed"
    echo "gate: seed $seed byte-identical"
done

strict_cstd=${SC_CSTD:-$CONTRACT_CSTD}
step "strict C warnings ($strict_cstd $CONTRACT_STRICT_CFLAGS) and readability"
raw="$tree/build/debug/raw"
units=0
for c in $(find "$raw" -name '*.c' | sort); do
    ${CC:-cc} $strict_cstd $CONTRACT_STRICT_CFLAGS -fsyntax-only "$c" || fail "strict warnings: $c"
    units=$((units + 1))
done
if grep -rln "$CONTRACT_READABLE_FORBIDDEN" "$raw" >/dev/null; then
    fail "readability: a #line directive in the emitted tree"
fi
for n in $CONTRACT_READABLE_SHARED; do [ -f "$raw/$n" ] || fail "readability: missing shared file $n"; done
for c in $(find "$raw" -name '*.c' | sort); do
    case "$(basename "$c")" in
    __ext*|__sc_registry.c|__sc_pack*|super_rt.c|*__p[0-9]*.c|*__inst.c) continue ;;
    esac
    h="${c%.c}.h"
    [ -f "$h" ] || fail "readability: $c has no header beside it"
done
echo "gate: $units units clean"
printf '\ngate: OK\n'
