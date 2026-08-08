#!/bin/sh
# The compiler under test, as wasm. Transpile-class commands run inside wasmtime; the subcommands
# that must spawn processes (the build engine's cc, bindgen's preprocessor, the test runner) fall
# back to the native binary -- WASI has no processes, so this split IS the wasm lane. Used through
# SC_TEST_SUPERC, which `super-c test` installs as the harness's compiler under test.
R="$(cd "$(dirname "$0")/.." && pwd)"
WASM="${SC_WASM_MODULE:-$R/super-c.wasm}"
NATIVE="${SC_WASM_NATIVE:-$R/super-c}"
case "$1" in
build | release | run | vendor | bindgen | test | bench | new | init | lsp | --test)
  exec "$NATIVE" "$@"
  ;;
esac
# The wasm host would otherwise emit FOR wasm (32-bit layouts the host cc rejects): pin the host
# target unless the caller chose one. Flags parse anywhere, so appending keeps the subcommand first.
HOST_TARGET=macos
HOST_ARCH=aarch64
if [ "$(uname -s)" = Linux ]; then HOST_TARGET=linux; fi
if [ "$(uname -m)" = x86_64 ]; then HOST_ARCH=x86_64; fi
PIN="--target=$HOST_TARGET --arch=$HOST_ARCH"
case "$*" in *--target=*) PIN="" ;; esac
# A precompiled sibling skips the per-invocation module JIT (CI compiles it once; see release.yml).
CWASM="${SC_WASM_CWASM:-${WASM%.wasm}.cwasm}"
if [ -f "$CWASM" ]; then
  exec wasmtime run --allow-precompiled --dir=/ --argv0 "$WASM" \
    ${SC_LEAK_CHECK:+--env SC_LEAK_CHECK="$SC_LEAK_CHECK"} \
    -- "$CWASM" "$@" $PIN
fi
exec wasmtime run --dir=/ --argv0 "$WASM" \
  ${SC_LEAK_CHECK:+--env SC_LEAK_CHECK="$SC_LEAK_CHECK"} \
  -- "$WASM" "$@" $PIN
