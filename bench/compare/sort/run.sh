#!/bin/sh
# Build the libc++ and Super-C sides of the sort comparison (see README.md) and print one table: the best
# ns per element of each lane and the ratio. A lane whose checksums differ is FAILED: the two sides did not
# do the same work.
set -u
cd "$(dirname "$0")/../../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
CXX=${CXX:-clang++}
if ! "$CXX" -O2 -std=c++20 -o "$out/cpp" bench/compare/sort/sort.cpp; then
    echo "sort: the C++ side does not build with $CXX" >&2
    exit 1
fi
if ! ${SUPERC:-./super-c} build bench/compare/sort/sort.spc -o "$out/sc" --profile=release >/dev/null; then
    echo "sort: the Super-C side does not build" >&2
    exit 1
fi
"$out/cpp" > "$out/cpp.txt" || exit 1
"$out/sc" > "$out/sc.txt" || exit 1
printf '%-10s %-9s %8s %10s %10s %7s\n' lane input n libc++ super-c ratio
status=0
paste -d ' ' "$out/cpp.txt" "$out/sc.txt" > "$out/both.txt"
while read -r op kind n c csum _ _ _ s ssum; do
    ratio=$(awk -v a="$s" -v b="$c" 'BEGIN { printf "%.2f", a / b }')
    printf '%-10s %-9s %8s %10s %10s %7s' "$op" "$kind" "$n" "$c" "$s" "$ratio"
    if [ "$csum" != "$ssum" ]; then
        printf '  FAILED: checksums differ'
        status=1
    fi
    printf '\n'
done < "$out/both.txt"
exit $status
