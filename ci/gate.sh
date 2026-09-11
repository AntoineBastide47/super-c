#!/bin/sh
# The correctness gate, one command: every check the compatibility contract (ci/contract.sh) names, in
# this order. Run from the repository root (or through `super-c command gate`):
#   0. the tree matches the contract's input lists;
#   1. check.sh: canonical formatting, lint per target, the test corpus, the sanitizer lanes, and the
#      two-stage rebuild from the latest release (the compiler builds its own sources);
#   2. the two-generation fixpoint: gen1 and gen2 emit byte-identical C;
#   3. the worker-count identity, run by generation two: one worker and every core under each
#      task-delay seed emit byte-identical C, publish the same package type table and item index,
#      and print the same diagnostics;
#   4. every emitted translation unit compiles under the strict warning set, and the tree meets the
#      readability rules;
#   5. every supported target transpiles the compiler and every built-in profile builds it;
#   6. the self-transpile benchmark runs with a successful compiler, C compiler and linker.
# Any failure stops the gate with a nonzero exit. Scratch trees live under $TMPDIR and are removed.
set -eu
cd "$(dirname "$0")/.."
. ci/contract.sh

step() { printf '\ngate: %s\n' "$1"; }
fail() { printf 'gate: FAILED: %s\n' "$1" >&2; exit 1; }
ncpu=$(getconf _NPROCESSORS_ONLN)

# Sorted set comparison of a contract list against a shell glob (the glob only detects unlisted files).
same_set() {
    listed=$(printf '%s\n' "$1" | sort)
    present=$(for f in $2; do [ -e "$f" ] && printf '%s\n' "$f"; done | sort)
    [ "$listed" = "$present" ]
}

step "contract v$CONTRACT_VERSION: input lists"
for f in $CONTRACT_ROOT $CONTRACT_MANIFEST $CONTRACT_TESTS $CONTRACT_EXAMPLES $CONTRACT_CI_PROGRAMS $CONTRACT_BENCH_FILES; do
    [ -f "$f" ] || fail "listed input missing: $f"
done
[ -d "$CONTRACT_STD" ] || fail "missing $CONTRACT_STD/"
[ -d "$CONTRACT_FFI" ] || fail "missing $CONTRACT_FFI/"
same_set "$CONTRACT_TESTS" 'tests/*.spc' || fail "tests/ does not match CONTRACT_TESTS (update ci/contract.sh, bump CONTRACT_VERSION)"
same_set "$CONTRACT_EXAMPLES" 'examples/*.spc' || fail "examples/ does not match CONTRACT_EXAMPLES"
same_set "$CONTRACT_CI_PROGRAMS" 'ci/*.spc' || fail "ci/ does not match CONTRACT_CI_PROGRAMS"
same_set "$CONTRACT_BENCH_FILES" 'bench/*.spc' || fail "bench/ does not match CONTRACT_BENCH_FILES"
echo "gate: ok"

step "check.sh (format, lint, tests, sanitizer lanes, release bootstrap)"
./check.sh

# check.sh leaves ./super-c as the two-stage rebuild of the current source; every step below uses a copy
# of it inside a clean tree so std/ffi resolve there and no cache of this checkout takes part. The object
# cache stays on: every build after gen1 emits the same C, so it recompiles nothing.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tree="$tmp/tree"
mkdir -p "$tree"
cp -R src std ffi build.toml "$tree/"
rm -rf "$tree/src/build"
cp "$CONTRACT_BIN" "$tree/super-c"

# Byte comparison of two emitted trees, minus the accepted nondeterminism.
same_tree() {
    ex=""
    for n in $CONTRACT_NONDET_FILES; do ex="$ex --exclude=$n"; done
    diff -r $ex "$1" "$2"
}

step "fixpoint: gen1 ($CONTRACT_FIXPOINT_GEN1) vs gen2 ($CONTRACT_FIXPOINT_GEN2)"
( cd "$tree" && SC_LEAK_CHECK=fatal ./super-c build >/dev/null )
cp -R "$tree/build/raw" "$tmp/gen1-raw"
cp "$tree/build/dev/super-c" "$tree/gen1-super-c"
rm -rf "$tree/build"
( cd "$tree" && SC_LEAK_CHECK=fatal SC_BC_VALIDATE=1 SC_TYPE_VALIDATE=1 ./gen1-super-c build >/dev/null )
same_tree "$tmp/gen1-raw" "$tree/build/raw" || fail "gen1 and gen2 emitted different C (above)"
# Generation two is compiled and run: every build below is its own.
cp "$tree/build/dev/super-c" "$tree/gen2-super-c"
echo "gate: byte-identical"

# One build of the tree by gen2: $1 workers, $2 the SC_TASK_DELAY seed (empty = none), $3 the record
# name under $tmp (<name>-raw, <name>-types, <name>-err).
gen2_build() {
    rm -rf "$tree/build"
    ( cd "$tree" && SC_LEAK_CHECK=fatal SC_BC_VALIDATE=1 SC_TYPE_VALIDATE=1 SC_ITEM_STATS=1 SC_TYPE_TABLE="$tmp/$3-types" env ${2:+SC_TASK_DELAY=$2} ./gen2-super-c build --jobs="$1" >/dev/null 2>"$tmp/$3-err" ) || { cat "$tmp/$3-err" >&2; fail "gen2 build $3 (--jobs=$1${2:+, SC_TASK_DELAY=$2}) failed (above)"; }
    cp -R "$tree/build/raw" "$tmp/$3-raw"
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

step "strict C warnings ($CONTRACT_CSTD $CONTRACT_STRICT_CFLAGS) and readability"
raw="$tree/build/raw"
units=0
for c in $(find "$raw" -name '*.c' | sort); do
    cc $CONTRACT_CSTD $CONTRACT_STRICT_CFLAGS -fsyntax-only "$c" || fail "strict warnings: $c"
    units=$((units + 1))
done
if grep -rln "$CONTRACT_READABLE_FORBIDDEN" "$raw" >/dev/null; then
    fail "readability: a #line directive in the emitted tree"
fi
for n in $CONTRACT_READABLE_SHARED; do [ -f "$raw/$n" ] || fail "readability: missing shared file $n"; done
for c in $(find "$raw" -name '*.c' | sort); do
    case "$(basename "$c")" in
    __ext*|__sc_registry.c|super_rt.c|*__p[0-9]*.c|*__inst.c) continue ;;
    esac
    h="${c%.c}.h"
    [ -f "$h" ] || fail "readability: $c has no header beside it"
done
echo "gate: $units units clean"

step "targets ($CONTRACT_TARGETS) and profiles ($CONTRACT_PROFILES)"
host=$(uname -s)
for t in $CONTRACT_TARGETS; do
    case "$host:$t" in
    Darwin:macos|Linux:linux) continue ;; # the host target is what every build above linked
    esac
    ( cd "$tree" && SC_LEAK_CHECK=fatal ./gen2-super-c src/main.spc --target="$t" >/dev/null ) || fail "target $t"
    rm -rf "$tree/src/build"
    echo "gate: target $t transpiles"
done
for p in $CONTRACT_PROFILES; do
    ( cd "$tree" && SC_LEAK_CHECK=fatal ./gen2-super-c build --profile="$p" --out-dir="build/gate-$p" -o "build/gate-$p/super-c" >/dev/null ) || fail "profile $p"
    echo "gate: profile $p builds"
done

step "benchmark ($CONTRACT_CMD_BENCH)"
./super-c bench --bench-filter=self_transpile || fail "the benchmark reported a failure (compiler, C compiler or linker)"

printf '\ngate: OK (contract v%s)\n' "$CONTRACT_VERSION"
