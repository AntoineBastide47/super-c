#!/bin/sh
# Builds the hand-written C kernels into build/simd_baseline/<arch>/libsimd_baseline.a, the library
# kernels.spc links through `@link`: a C library comes prebuilt, so `super-c bench` compiles no C file of
# this directory. Run from the repository root before a benchmark build of the same target; record.sh runs
# it. The arguments are record.sh's: `--target=wasm` builds the SIMD128 kernels with
# $WASI_SDK_PATH/bin/clang, else the host's kernels build with $CC (else cc).
set -eu
dir=bench/simd_baseline
case " $* " in
*" --target=wasm "*)
    bin=${WASI_SDK_PATH:+$WASI_SDK_PATH/bin/}
    cc="${bin}clang --target=wasm32-wasip1"
    ar=${bin}llvm-ar
    arch=wasm32
    ;;
*)
    cc=${CC:-cc}
    ar=${AR:-ar}
    case $($cc -dumpmachine) in
    x86_64* | amd64*) arch=x86_64 ;;
    aarch64* | arm64*) arch=aarch64 ;;
    *) printf 'kernels: no C kernels for %s\n' "$($cc -dumpmachine)" >&2; exit 1 ;;
    esac
    ;;
esac
case $arch in
x86_64) srcs="sse2 avx2 avx512" ;;
aarch64) srcs="neon" ;;
wasm32) srcs="simd128" ;;
esac
out=build/simd_baseline/$arch
mkdir -p "$out"
objs=
for s in $srcs; do
    $cc -std=c11 -O3 -funsigned-char -ffp-contract=off -c "$dir/$s.c" -o "$out/$s.o"
    objs="$objs $out/$s.o"
done
rm -f "$out/libsimd_baseline.a"
$ar rcs "$out/libsimd_baseline.a" $objs
