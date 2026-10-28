#!/bin/sh
# dump.sh COMPILER DIR: a cold release build of the compiler by COMPILER, with its optimized LIR in
# DIR/lir.txt and the disassembly of every object the build wrote in DIR/asm.txt (the Debug workflow).
set -eu
sc=$1
out=$2
mkdir -p "$out"
rm -rf build-dump
if ! SC_NO_TU_CACHE=1 SC_NO_EMIT_CACHE=1 SC_LIR_PRINT=_ "$sc" build --profile=release --out-dir=build-dump -o build-dump/sc 2> "$out/lir.txt"; then
    tail -n 50 "$out/lir.txt"
    exit 1
fi
flags="-d -r --no-show-raw-insn"
case $(uname -m) in
    x86_64 | amd64) flags="$flags -M intel" ;;
esac
find build-dump -name '*.o' -o -name '*.obj' | LC_ALL=C sort > "$out/objects.txt"
while read -r f; do
    # shellcheck disable=SC2086
    objdump $flags "$f"
done < "$out/objects.txt" > "$out/asm.txt"
echo "objects: $(wc -l < "$out/objects.txt"), functions: $(grep -c '^fn @' "$out/lir.txt")"
ls -l "$out"
