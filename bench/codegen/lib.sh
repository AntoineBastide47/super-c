#!/bin/sh
# Builds the clang side of the code generation kernels into build/codegen/<arch>/libcodegen.a, the library
# codegen.spc links through `@link`. Run from the repository root before `super-c bench --filter=codegen_`.
# $CC (else cc) compiles at -O2, the level codegen.spc compares against.
set -eu
cc=${CC:-cc}
ar=${AR:-ar}
case $($cc -dumpmachine) in
x86_64* | amd64*) arch=x86_64 ;;
aarch64* | arm64*) arch=aarch64 ;;
*) printf 'codegen: no kernels for %s\n' "$($cc -dumpmachine)" >&2; exit 1 ;;
esac
out=build/codegen/$arch
mkdir -p "$out"
$cc -std=c11 -O2 -c bench/codegen/kernels.c -o "$out/kernels.o"
rm -f "$out/libcodegen.a"
$ar rcs "$out/libcodegen.a" "$out/kernels.o"
