#!/usr/bin/env bash
# The native backend against the emitted C built by the C compiler on this runner, from the compiler at
# ./super-c (BINEXT on Windows): cold self-builds with every worker and with one (the C side writes the C
# tree with `--emit-c` and builds it with $CC through ci/cc_tree.sh), the speed of the compiler each side
# produces (one serial C emission of the compiler's sources, the same work for both), and the transpile
# count of each side's work as .github/actions/transpile-counts takes it (the compiler's own code only).
# Each time is the fastest of RUNS runs, every cache off. The count needs CC_COUNTS (a clang with profile
# counters) and PROFDATA (its llvm-profdata); without them it is left out. Prints a Markdown table, also
# into GITHUB_STEP_SUMMARY when set.
set -eu
x=${BINEXT:-}
runs=${RUNS:-3}
w=${RUNNER_TEMP:-/tmp}/speed
rm -rf "$w" && mkdir -p "$w"
export SC_NO_EMIT_CACHE=1 SC_NO_TU_CACHE=1
TIMEFORMAT='%3R %3U %3S'

# The fastest wall time of `runs` runs of "$@" (after `env` words), with that run's user and system
# seconds: "wall user sys".
best() {
  local b="" t
  for _ in $(seq "$runs"); do
    t=$( { time "$@" > "$w/out.txt" 2>&1 || true; } 2>&1 | tail -1 )
    if [ -z "$b" ] || awk -v a="${t%% *}" -v c="${b%% *}" 'BEGIN { exit !(a < c) }'; then
      b=$t
    fi
  done
  echo "$b"
}

# A cold self-build into build/speed-$1 (its binary sc$x two levels under the checkout, so it finds
# std): native, or `c` through the emitted C and the C compiler ($cc_jobs units at a time, empty: one per
# core); the rest of the words are options.
cc_jobs=""
self_build() {
  local d="build/speed-$1" side=$1
  shift
  rm -rf "$d"
  if [ "$side" = native ]; then
    "./super-c$x" build --out-dir="$d" -o "$d/sc$x" "$@"
  else
    "./super-c$x" build --out-dir="$d" --emit-c "$@" && JOBS=$cc_jobs sh ci/cc_tree.sh "$d/debug/raw" "$d/sc$x"
  fi
}

row() {
  printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4"
}

ratio() {
  awk -v a="$1" -v b="$2" 'BEGIN { if (a > 0) printf "%.2fx", b / a; else print "-" }'
}

cc_v=$("${CC:-cc}" --version 2>/dev/null | head -1 || echo "${CC:-cc}")
out="$w/table.md"
{
  echo "### ${RUNNER_OS:-local} $(uname -m): native backend against the emitted C"
  echo
  echo "C compiler: \`$cc_v\`; ${runs} runs each, the fastest shown (wall s / user s / sys s)."
  echo
  echo "| Measure | Native | Emitted C | C / native (wall) |"
  echo "|---|---|---|---|"
} > "$out"

# The self-builds: the last run of each leaves its binary for the next measure. With one worker the C
# compiler runs one unit at a time too.
for jobs in "" "--jobs=1"; do
  label="cold self-build${jobs:+ ($jobs)}"
  n=$(best self_build native ${jobs:+"$jobs"})
  test -x "build/speed-native/sc$x" || { cat "$w/out.txt"; echo "::error::the native self-build failed"; exit 1; }
  cc_jobs=${jobs:+1}
  c=$(best self_build c ${jobs:+"$jobs"})
  test -x "build/speed-c/sc$x" || { cat "$w/out.txt"; echo "::error::the C self-build failed"; exit 1; }
  row "$label" "${n// / / }" "${c// / / }" "$(ratio "${n%% *}" "${c%% *}")" >> "$out"
done

# The produced compilers on the same work: one serial C emission.
transpile() {
  rm -rf "$w/tree"
  "$1" build --jobs=1 --emit-c --out-dir="$w/tree"
}
tn=$(best transpile "build/speed-native/sc$x")
test -s "$w/tree/debug/raw/__units" || { cat "$w/out.txt"; echo "::error::the native-built compiler's emission failed"; exit 1; }
tc=$(best transpile "build/speed-c/sc$x")
test -s "$w/tree/debug/raw/__units" || { cat "$w/out.txt"; echo "::error::the C-built compiler's emission failed"; exit 1; }
row "serial C emission by the compiler each built" "${tn// / / }" "${tc// / / }" "$(ratio "${tn%% *}" "${tc%% *}")" >> "$out"

# Code size of the two compilers.
size_of() {
  wc -c < "$1" | tr -d ' '
}
row "compiler binary bytes" "$(size_of "build/speed-native/sc$x")" "$(size_of "build/speed-c/sc$x")" "-" >> "$out"

# The transpile count of each side's work, by a counted build of the compiler under test: the native
# build (objects and link) and the C emission.
if [ -n "${CC_COUNTS:-}" ] && [ -n "${PROFDATA:-}" ]; then
  py=$(command -v python3 || command -v python)
  # The counters are the C compiler's: the counted compiler is the release profile's C tree.
  { "./super-c$x" build --profile=release --emit-c --out-dir="$w/counts-tree" &&
    CC="$CC_COUNTS" sh ci/cc_tree.sh "$w/counts-tree/release/raw" "build/counts/super-c-counts$x" -DNDEBUG -fprofile-instr-generate; } > "$w/counts-build.txt" 2>&1 || {
    cat "$w/counts-build.txt"
    echo "::error::the counted compiler did not build"
    exit 1
  }
  count() {
    local raw="$w/raw-$1"
    rm -rf "$raw" "$w/ctree"
    mkdir -p "$raw"
    # To stderr: the caller captures stdout.
    env LLVM_PROFILE_FILE="$raw/%p.profraw" "./build/counts/super-c-counts$x" build --profile=debug --jobs=1 --bootstrap-tags --out-dir="$w/ctree" $2 > "$w/count-$1.txt" 2>&1 || {
      cat "$w/count-$1.txt" >&2
      echo "::error::the counted build ($1) failed" >&2
      exit 1
    }
    "$PROFDATA" merge -o "$w/$1.profdata" "$raw"/*.profraw
    "$PROFDATA" merge --text -o "$w/$1.txt" "$w/$1.profdata"
    "$py" -I .github/actions/transpile-counts/counts.py summarize "$w/$1.txt" "$w/$1.tsv" "$1" "$CC_COUNTS"
    awk -F'\t' '$1 == "total" { print $2 }' "$w/$1.tsv"
  }
  kn=$(count native "-o $w/ctree/bin$x")
  kc=$(count c --emit-c)
  row "transpile count (compiler code only)" "$kn" "$kc" "$(ratio "$kn" "$kc")" >> "$out"
fi
cat "$out"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$out" >> "$GITHUB_STEP_SUMMARY"
fi
