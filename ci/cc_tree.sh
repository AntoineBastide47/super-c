#!/bin/sh
# Build the C tree `super-c build --emit-c` wrote at $1 into the program $2 with $CC (default cc): each
# C unit of `__units` compiled with the tree's `__cflags` and the remaining arguments, $JOBS at a time
# (default: one per core), then the objects linked with the same arguments and the tree's `__ldflags`.
# The C pipeline of ci/speed.sh and .github/actions/transpile-counts.
set -eu
raw=$1
out=$2
shift 2
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN)}
obj=$(mktemp -d)
trap 'rm -rf "$obj"' EXIT
CCT_CC=${CC:-cc}
CCT_FLAGS="$(cat "$raw/__cflags") $*"
export CCT_CC CCT_FLAGS
[ -s "$raw/__units" ] || { echo "cc_tree: no unit in $raw" >&2; exit 1; }
# One object per C unit, named by its line: units in different directories share base names. An object
# unit (the constant-time functions' `__sc_ct.o`) goes to the link as it is.
i=0
while IFS= read -r u; do
    i=$((i + 1))
    case $u in
    *.o) cp "$raw/$u" "$obj/$i.o" ;;
    *) printf '%s\0%s\0' "$u" "$obj/$i.o" ;;
    esac
done <"$raw/__units" | (cd "$raw" && xargs -0 -n 2 -P "$jobs" sh -c '$CCT_CC $CCT_FLAGS -c "$0" -o "$1"')
ldflags=""
if [ -f "$raw/__ldflags" ]; then
    ldflags=$(cat "$raw/__ldflags")
fi
mkdir -p "$(dirname "$out")"
# shellcheck disable=SC2086 # the flags are words
$CCT_CC $CCT_FLAGS "$obj"/*.o $ldflags -o "$out"
