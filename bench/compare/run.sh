#!/bin/sh
# Build and run every lane of the blocking-I/O fan-out comparison (see README.md), then print one table.
# A lane whose toolchain is missing or whose build fails is reported as such, never silently dropped; a
# lane that fails its own validation (a short write, a failed durability call, a lost task) is FAILED.
set -u
cd "$(dirname "$0")/../.."
ITERS=${ITERS:-5}
TASKS=${TASKS:-1000}
LIMIT=${LIMIT:-64}
export ITERS TASKS LIMIT
out=$(mktemp -d)
dirs="$out"
trap 'rm -rf $dirs' EXIT
status=0

row() { printf '  %-22s %9s %9s %9s %9s %8s %6s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }
skip() { printf '  %-22s %s\n' "$1" "$2"; }

# Run one lane binary in a directory of its own (created here, removed with the others at exit) and print
# its row; a nonzero exit or a short result is a failure of the run.
lane() {
  name=$1; shift
  d=$(mktemp -d); dirs="$dirs $d"
  if res=$(SC_COMPARE_DIR="$d" "$@"); then
    set -- $res
    if [ "$5" = "$6" ]; then
      row "$name" "$1" "$2" "$3" "$4" "$5/$6" "$7"
    else
      row "$name" "$1" "$2" "$3" "$4" "$5/$6" "$7"; printf '  %-22s FAILED: %s of %s units validated\n' "" "$5" "$6"; status=1
    fi
  else
    skip "$name" "FAILED: the lane exited nonzero (see above)"; status=1
  fi
}

printf 'blocking-I/O fan-out: %s iterations x %s tasks, %s units blocking at once (LIMIT)\n' "$ITERS" "$TASKS" "$LIMIT"
printf '  each unit: create a file, write 4 KiB of zeros, sync it to the device, close; every call checked\n'
printf '  %s, %s cores\n\n' "$(uname -sm)" "$(getconf _NPROCESSORS_ONLN)"
row "lane" "cold ms" "median ms" "p95 ms" "ns/op" "ok" "limit"
printf '  %s\n' "----------------------------------------------------------------------------------"

# --- Super-C: the release profile, never the script path (which compiles the C with no -O flag) ----------
if ./super-c release bench/compare/super_c.spc -o "$out/sc" >"$out/sc.log" 2>&1; then
  lane "super-c-blocking" env MODE=blocking "$out/sc"
  lane "super-c-direct" env MODE=direct "$out/sc"
else
  skip "super-c-*" "FAILED: build failed ($out/sc.log)"; status=1
fi

# --- Go ---------------------------------------------------------------------------------------------
if ! command -v go >/dev/null 2>&1; then
  skip "go-goroutines" "skipped: no go toolchain"
elif ( cd bench/compare/go && go build -o "$out/go" . ) >"$out/go.log" 2>&1; then
  lane "go-goroutines" "$out/go"
else
  skip "go-goroutines" "FAILED: build failed ($out/go.log)"; status=1
fi

# --- Rust: threads and both tokio strategies --------------------------------------------------------
if ! command -v cargo >/dev/null 2>&1; then
  skip "rust-*" "skipped: no cargo toolchain"
elif ( cd bench/compare/rust && cargo build --release ) >"$out/cargo.log" 2>&1; then
  b=bench/compare/rust/target/release
  lane "rust-threads" "$b/threads"
  lane "tokio-spawn-blocking" "$b/tokio_spawn_blocking"
  lane "tokio-block-in-place" "$b/tokio_block_in_place"
else
  skip "rust-*" "FAILED: build failed ($out/cargo.log)"; status=1
fi
printf '\n'
if [ "$status" != 0 ]; then
  printf 'compare: FAILED\n'
  trap - EXIT # keep the logs
  printf 'logs under %s\n' "$out"
fi
exit $status
