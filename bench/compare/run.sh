#!/bin/sh
# Build and run every lane of the blocking-I/O fan-out comparison (see README.md), then print one table.
# Lanes whose toolchain is missing are reported as skipped rather than silently dropped.
set -eu
cd "$(dirname "$0")/../.."
ITERS=${ITERS:-5}
TASKS=${TASKS:-1000}
export ITERS TASKS
out=$(mktemp -d)
# The workload writes here; every lane uses the same directory and the same device.
data=/tmp/sc-compare
rm -rf "$data"; mkdir -p "$data"
trap 'rm -rf "$out" "$data"' EXIT

row() { printf '  %-24s %10s %14s\n' "$1" "$2" "$3"; }

printf 'blocking-I/O fan-out: %s iterations x %s tasks (%s operations per lane)\n' \
  "$ITERS" "$TASKS" "$((ITERS * TASKS))"
printf '  each task: create a file, write 4 KiB, fsync it to the device, close\n\n'
row "lane" "ms/iter" "ns/op"
printf '  %s\n' "------------------------------------------------------"

# --- Super-C: the release profile, never the script path (which compiles the C with no -O flag) ----------
if ./super-c release bench/compare/super_c.spc -o "$out/sc" >/dev/null 2>&1; then
  set -- $(MODE=blocking "$out/sc"); row "super-c-blocking" "$1" "$2"
  set -- $(MODE=direct   "$out/sc"); row "super-c-direct"   "$1" "$2"
else
  row "super-c" "skipped" "build failed"
fi

# --- Go ---------------------------------------------------------------------------------------------
if command -v go >/dev/null 2>&1 && ( cd bench/compare/go && go build -o "$out/go" . ) >/dev/null 2>&1; then
  set -- $("$out/go"); row "go-goroutines" "$1" "$2"
else
  row "go-goroutines" "skipped" "no go toolchain, or the build failed"
fi

# --- Rust: threads and both tokio strategies --------------------------------------------------------
if command -v cargo >/dev/null 2>&1 && ( cd bench/compare/rust && cargo build --release ) >/dev/null 2>&1; then
  b=bench/compare/rust/target/release
  set -- $("$b/threads");              row "rust-threads" "$1" "$2"
  set -- $("$b/tokio_spawn_blocking"); row "tokio-spawn-blocking" "$1" "$2"
  set -- $("$b/tokio_block_in_place"); row "tokio-block-in-place" "$1" "$2"
else
  row "rust-*" "skipped" "no cargo toolchain, or the build failed"
fi
printf '\n'
