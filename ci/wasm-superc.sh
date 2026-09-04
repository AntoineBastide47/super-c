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
# `fmt` takes no target/arch flags (it neither emits C nor gates on platform), so pinning them would
# make it reject its own command line: the one guest subcommand that must not be pinned.
case "$1" in fmt) PIN="" ;; esac
# wasmtime forwards only the env it is told to, so a test that sets an SC_* compiler switch
# (SC_INLINE, SC_BCE, SC_CONST_EVAL_*, SC_LEAK_CHECK ...) would otherwise have no effect in the
# guest -- its assertions on emitted C would silently test the default path. Forward every SC_*
# except this shim's own plumbing, whose values are host paths that may contain spaces (the
# compiler switches themselves are space-free, so word-splitting ENVF into flags is safe).
ENVF=""
while IFS='=' read -r k v; do
  case "$k" in
  SC_WASM_MODULE | SC_WASM_NATIVE | SC_TEST_SUPERC) ;;
  SC_*) ENVF="$ENVF --env $k=$v" ;;
  esac
done <<EOF
$(env)
EOF
exec wasmtime run --dir=/ --argv0 "$WASM" $ENVF -- "$WASM" "$@" $PIN
