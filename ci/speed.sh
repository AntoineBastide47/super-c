#!/usr/bin/env bash
# The native backend against the C pipeline on this runner, from the compiler at ./super-c (BINEXT on
# Windows): cold self-builds with every worker and with one, the speed of the compiler each pipeline
# produces (one serial transpile of the compiler's sources), and the transpile count of each pipeline
# as .github/actions/transpile-counts takes it (its `--cc=true` run counts the compiler's own code, not
# the C compile). Each time is the fastest of RUNS runs, every cache off. The count needs CC_COUNTS (a
# clang with profile counters) and PROFDATA (its llvm-profdata); without them it is left out. SC_CSTD,
# when set, is every C compile's base flags (`--cstd`). Prints a Markdown table, also into
# GITHUB_STEP_SUMMARY when set.
set -eu
x=${BINEXT:-}
cstd=${SC_CSTD:+--cstd=$SC_CSTD}
runs=${RUNS:-3}
w=${RUNNER_TEMP:-/tmp}/speed
rm -rf "$w" && mkdir -p "$w"
export SC_NO_CACHE=1 CCACHE_DISABLE=1 SC_NO_EMIT_CACHE=1 SC_NO_TU_CACHE=1
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
# std), with SC_NATIVE=$2 and the rest of the words as options.
self_build() {
  local d="build/speed-$1" n=$2
  shift 2
  rm -rf "$d"
  env SC_NATIVE="$n" "./super-c$x" build --out-dir="$d" -o "$d/sc$x" ${cstd:+"$cstd"} "$@"
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
  echo "### ${RUNNER_OS:-local} $(uname -m): native backend against the C pipeline"
  echo
  echo "C compiler: \`$cc_v\`; ${runs} runs each, the fastest shown (wall s / user s / sys s)."
  echo
  echo "| Measure | Native | C pipeline | C / native (wall) |"
  echo "|---|---|---|---|"
} > "$out"

# The self-builds: the last run of each leaves its binary for the next measure.
for jobs in "" "--jobs=1"; do
  label="cold self-build${jobs:+ ($jobs)}"
  n=$(best self_build native 1 ${jobs:+"$jobs"})
  test -x "build/speed-native/sc$x" || { cat "$w/out.txt"; echo "::error::the native self-build failed"; exit 1; }
  # The modules a native build still sends through C.
  grep '^native:' "$w/out.txt" > "$w/native-note.txt" || true
  c=$(best self_build c 0 ${jobs:+"$jobs"})
  test -x "build/speed-c/sc$x" || { cat "$w/out.txt"; echo "::error::the C self-build failed"; exit 1; }
  row "$label" "${n// / / }" "${c// / / }" "$(ratio "${n%% *}" "${c%% *}")" >> "$out"
done

# The produced compilers on the same work: one serial transpile (`--cc=true` compiles and links
# nothing, so the build ends at the binary it never made).
transpile() {
  rm -rf "$w/tree"
  env SC_NATIVE=0 SC_LINK=cc "$1" build --jobs=1 --cc=true --out-dir="$w/tree"
}
tn=$(best transpile "build/speed-native/sc$x")
grep -q "cannot move" "$w/out.txt" || { cat "$w/out.txt"; echo "::error::the native-built compiler's transpile failed"; exit 1; }
tc=$(best transpile "build/speed-c/sc$x")
grep -q "cannot move" "$w/out.txt" || { cat "$w/out.txt"; echo "::error::the C-built compiler's transpile failed"; exit 1; }
row "serial transpile by the compiler each built" "${tn// / / }" "${tc// / / }" "$(ratio "${tn%% *}" "${tc%% *}")" >> "$out"

# Code size of the two compilers.
size_of() {
  wc -c < "$1" | tr -d ' '
}
row "compiler binary bytes" "$(size_of "build/speed-native/sc$x")" "$(size_of "build/speed-c/sc$x")" "-" >> "$out"

# The transpile count of each pipeline, by a counted build of the compiler under test.
if [ -n "${CC_COUNTS:-}" ] && [ -n "${PROFDATA:-}" ]; then
  py=$(command -v python3 || command -v python)
  "./super-c$x" build --profile=counts --cc="$CC_COUNTS" ${cstd:+"$cstd"} -o "build/counts/super-c-counts$x" > "$w/counts-build.txt" 2>&1 || {
    cat "$w/counts-build.txt"
    echo "::error::the counted compiler did not build"
    exit 1
  }
  count() {
    local raw="$w/raw-$1"
    rm -rf "$raw" "$w/ctree"
    mkdir -p "$raw"
    # SC_LINK=cc keeps the link with `true`, which makes nothing: the count is the transpile's.
    env SC_NATIVE="$2" SC_LINK=cc LLVM_PROFILE_FILE="$raw/%p.profraw" "./build/counts/super-c-counts$x" build --profile=debug --jobs=1 --cc=true --bootstrap-tags --out-dir="$w/ctree" > "$w/count-$1.txt" 2>&1 || true
    # To stderr: the caller captures stdout.
    grep -q "cannot move" "$w/count-$1.txt" || { cat "$w/count-$1.txt" >&2; echo "::error::the counted transpile ($1) failed" >&2; exit 1; }
    "$PROFDATA" merge -o "$w/$1.profdata" "$raw"/*.profraw
    "$PROFDATA" merge --text -o "$w/$1.txt" "$w/$1.profdata"
    "$py" -I .github/actions/transpile-counts/counts.py summarize "$w/$1.txt" "$w/$1.tsv" "$1" "$CC_COUNTS"
    awk -F'\t' '$1 == "total" { print $2 }' "$w/$1.tsv"
  }
  kn=$(count native 1)
  kc=$(count c 0)
  row "transpile count (compiler code only)" "$kn" "$kc" "$(ratio "$kn" "$kc")" >> "$out"
fi
{
  echo
  echo "Native build: $(tail -1 "$w/native-note.txt" 2>/dev/null || echo "every module native")."
} >> "$out"
cat "$out"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$out" >> "$GITHUB_STEP_SUMMARY"
fi
