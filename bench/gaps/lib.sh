#!/bin/sh
# Builds the clang side of the code generation gap probes into build/gaps/<arch>/libgaps.a, the
# library gaps.spc links through `@link`. Run from the repository root before `super-c bench
# --filter=gaps`. $CC (else cc) compiles at -O2, the level gaps.spc compares against.
set -eu
cc=${CC:-cc}
ar=${AR:-ar}
case $($cc -dumpmachine) in
x86_64* | amd64*) arch=x86_64 ;;
aarch64* | arm64*) arch=aarch64 ;;
*) printf 'gaps: no probes for %s\n' "$($cc -dumpmachine)" >&2; exit 1 ;;
esac
out=build/gaps/$arch
mkdir -p "$out"
$cc -std=c11 -O2 -c bench/gaps/probes.c -o "$out/probes.o"
rm -f "$out/libgaps.a"
$ar rcs "$out/libgaps.a" "$out/probes.o"
