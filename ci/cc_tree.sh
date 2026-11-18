#!/bin/sh
# Build the C tree `super-c build --emit-c` wrote at $1 into the program $2 with $CC (default cc): each
# C unit of `__units` compiled with the tree's `__cflags` and the remaining arguments, $JOBS at a time
# (default: one per core), each unit of `__units_nobuiltin` (wasm32's C library) with `-fno-builtin` too,
# then the objects linked with the same arguments and the tree's `__ldflags`.
# The C pipeline of ci/speed.sh.
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
# cc_units <list> <letter> <flags>: one object per C unit of the list, compiled with the flags too and
# named by the letter and the unit's line: units in different directories share base names. An object
# unit (the constant-time functions' `__sc_ct.o`) goes to the link as it is.
cc_units() {
    i=0
    while IFS= read -r u; do
        i=$((i + 1))
        case $u in
        *.o) cp "$raw/$u" "$obj/$2$i.o" ;;
        *) printf '%s\0%s\0' "$u" "$obj/$2$i.o" ;;
        esac
    done <"$raw/$1" | (cd "$raw" && CCT_UNIT=$3 xargs -0 -n 2 -P "$jobs" sh -c '$CCT_CC $CCT_FLAGS $CCT_UNIT -c "$0" -o "$1"')
}
cc_units __units u ""
if [ -f "$raw/__units_nobuiltin" ]; then
    cc_units __units_nobuiltin b -fno-builtin
fi
ldflags=""
if [ -f "$raw/__ldflags" ]; then
    ldflags=$(cat "$raw/__ldflags")
fi
mkdir -p "$(dirname "$out")"
# shellcheck disable=SC2086 # the flags are words
$CCT_CC $CCT_FLAGS "$obj"/*.o $ldflags -o "$out"
