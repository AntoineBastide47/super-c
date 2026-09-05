#!/bin/sh
# The whole-build benchmark matrix: the compiler self-build through the real engine, one case per row of
# the table below, each case SC_MATRIX_REPS times (default 5), every run an SC_BUILD_STATS record. The
# compiler measured is a release-profile build of this checkout (what users run), placed under
# build/matrix so std/ffi resolve from the repository. Run from the repository root on a quiet box
# (or `super-c command matrix`); it takes tens of minutes.
#
#   case            workers  caches  what it measures
#   clean           1, all   cold    reference semantics and CPU cost / parallel scaling
#   unchanged       1, all   warm    fixed overhead and cache validation (emit stamp)
#   body            1, all   warm    a private function body edit: body invalidation, TU impact
#   signature       1, all   warm    a public signature edit: dependent interface invalidation
#   layout          1, all   warm    a by-value type layout edit: header and type fanout
#   release_relink  1, all   warm    the body edit under the release profile: LTO relink cost
#   tucache_on/off  all      warm    the body edit with the per-TU emit cache on and off, interleaved
#
# The three edits are fixed, reversible text substitutions (below); the exact source bytes are restored
# and verified with cmp after every run. Records land in build/matrix/<case>_j<workers>.jsonl, the
# summary (median and p95 of every phase) in build/matrix/report.md, and one memory-tracked run per
# case (SC_BUILD_MEM) in build/matrix/<case>_j<workers>_mem.jsonl. SC_MATRIX_RECORD=1 also copies the
# summary to ci/baseline_report.md and the constants to ci/baseline_matrix.env (the accepted whole-build
# baseline).
set -eu
cd "$(dirname "$0")/.."
. ci/contract.sh

fail() { printf 'matrix: FAILED: %s\n' "$1" >&2; exit 1; }
reps=${SC_MATRIX_REPS:-5}
ncpu=$(getconf _NPROCESSORS_ONLN)
m=build/matrix
out="$m/out"
rm -rf "$m"
mkdir -p "$m"

# The three reversible edits: file, the text to replace, its replacement.
BODY_FILE=src/build_system/build.spc
BODY_FROM='build: cannot spawn compiler"'
BODY_TO='build: cannot spawn compiler."'
SIG_FILE=src/module/loader.spc
SIG_FROM='osp'
SIG_TO='osp9'
LAYOUT_FILE=src/lexer/token.spc
LAYOUT_FROM='    pub start: u32,
    pub end: u32,'
LAYOUT_TO='    pub end: u32,
    pub start: u32,'

for f in $BODY_FILE $SIG_FILE $LAYOUT_FILE; do
    cp "$f" "$m/orig_$(basename "$f")"
done
[ "$(grep -c "$BODY_FROM" $BODY_FILE)" = 2 ] || fail "body edit anchor drifted in $BODY_FILE"
[ "$(grep -cw "$SIG_FROM" $SIG_FILE)" = 3 ] || fail "signature edit anchor drifted in $SIG_FILE"
grep -q 'pub start: u32,' $LAYOUT_FILE || fail "layout edit anchor drifted in $LAYOUT_FILE"

apply_edit() { # body|signature|layout
    case "$1" in
    body) python3 -c 'import sys;p,a,b=sys.argv[1:];s=open(p).read();assert s.count(a)==2;open(p,"w").write(s.replace(a,b))' "$BODY_FILE" "$BODY_FROM" "$BODY_TO" ;;
    signature) python3 -c 'import re,sys;p,a,b=sys.argv[1:];s=open(p).read();t=re.sub(r"\b%s\b"%a,b,s);assert t!=s;open(p,"w").write(t)' "$SIG_FILE" "$SIG_FROM" "$SIG_TO" ;;
    layout) python3 -c 'import sys;p,a,b=sys.argv[1:];s=open(p).read();assert s.count(a)==1;open(p,"w").write(s.replace(a,b))' "$LAYOUT_FILE" "$LAYOUT_FROM" "$LAYOUT_TO" ;;
    esac
}
restore() {
    for f in $BODY_FILE $SIG_FILE $LAYOUT_FILE; do
        cp "$m/orig_$(basename "$f")" "$f"
        cmp -s "$m/orig_$(basename "$f")" "$f" || fail "could not restore $f"
    done
}
trap restore EXIT

# One measured build. $1 record file, $2 workers, $3 profile, the rest: extra environment (NAME=VALUE).
build() {
    rec=$1; jobs=$2; profile=$3; shift 3
    env "$@" SC_BUILD_STATS="$rec" "$sc" build --profile="$profile" --jobs="$jobs" --out-dir="$out" -o "$out/super-c" >"$m/last.log" 2>&1 || {
        cat "$m/last.log" >&2
        fail "build failed (record $rec)"
    }
}

printf 'matrix: release-profile compiler of this checkout\n'
./super-c build --profile=release -o "$m/super-c" >/dev/null || fail "cannot build the release compiler"
sc="$m/super-c"
commit=$(git rev-parse --short=12 HEAD)
printf 'matrix: build %s, %s cores, %s reps per case\n' "$commit" "$ncpu" "$reps"

# The global object cache and ccache stay off for every run: a warm case measures the project's own
# stamp and fingerprints, and a repeated edit must compile its unit again rather than fetch rep 1's object.
warm="SC_NO_CACHE=1 CCACHE_DISABLE=1"
i=0
while [ "$i" -lt "$reps" ]; do
    i=$((i + 1))
    printf 'matrix: rep %s/%s\n' "$i" "$reps"
    for jobs in 1 "$ncpu"; do
        rm -rf "$out"
        build "$m/clean_j$jobs.jsonl" "$jobs" dev $warm
        build "$m/unchanged_j$jobs.jsonl" "$jobs" dev $warm
        apply_edit body
        build "$m/body_j$jobs.jsonl" "$jobs" dev $warm
        restore
        build "$m/scratch.jsonl" "$jobs" dev $warm # back to the unedited tree, untimed
        apply_edit signature
        build "$m/signature_j$jobs.jsonl" "$jobs" dev $warm
        restore
        build "$m/scratch.jsonl" "$jobs" dev $warm
        apply_edit layout
        build "$m/layout_j$jobs.jsonl" "$jobs" dev $warm
        restore
        # Release relink: a warm release tree, then the body edit under the release profile.
        build "$m/scratch.jsonl" "$jobs" release $warm
        apply_edit body
        build "$m/release_relink_j$jobs.jsonl" "$jobs" release $warm
        restore
    done
    # The per-TU emit cache, interleaved on/off on the body edit with every core.
    rm -rf "$out"
    build "$m/scratch.jsonl" "$ncpu" dev $warm
    apply_edit body
    build "$m/tucache_on_j$ncpu.jsonl" "$ncpu" dev $warm
    restore
    build "$m/scratch.jsonl" "$ncpu" dev $warm
    apply_edit body
    build "$m/tucache_off_j$ncpu.jsonl" "$ncpu" dev $warm SC_NO_TU_CACHE=1
    restore
done

# One memory-tracked run per case with every core (the tracker inflates times, so these are separate).
printf 'matrix: memory-tracked runs\n'
rm -rf "$out"
build "$m/clean_j${ncpu}_mem.jsonl" "$ncpu" dev $warm SC_BUILD_MEM=1
build "$m/unchanged_j${ncpu}_mem.jsonl" "$ncpu" dev $warm SC_BUILD_MEM=1
apply_edit body
build "$m/body_j${ncpu}_mem.jsonl" "$ncpu" dev $warm SC_BUILD_MEM=1
restore

python3 - "$m" "$commit" "$ncpu" "$reps" <<'EOF'
import json, glob, os, statistics, sys
m, commit, ncpu, reps = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
transpile = ("stamp", "load", "resolve", "typecheck", "borrowck", "checks", "prepare", "plan", "render", "publish")
def med_p95(v):
    v = sorted(v)
    return statistics.median(v), v[(len(v) * 95 + 99) // 100 - 1]
lines = ["# Build matrix report", "", "build %s, %s cores, %s reps per case, dev profile unless noted; global object cache and ccache off throughout." % (commit, ncpu, reps), "",
         "| case | workers | runs | transpile ms med / p95 | compile ms med / p95 | link ms med / p95 | total ms med / p95 | units stale | cc span ms | cc overlap ms |", "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
consts = []
for path in sorted(glob.glob(os.path.join(m, "*.jsonl"))):
    name = os.path.basename(path)[:-6]
    if name == "scratch" or name.endswith("_mem"):
        continue
    recs = [json.loads(l) for l in open(path) if l.strip()]
    if not recs:
        continue
    bad = [r for r in recs if not r["ok"]]
    if bad:
        sys.exit("matrix: FAILED: %s has %d failed run(s)" % (name, len(bad)))
    t = [sum(r["ms"][k] for k in transpile) for r in recs]
    c = [r["ms"]["compile"] for r in recs]
    l = [r["ms"]["link"] for r in recs]
    tot = [r["ms"]["total"] for r in recs]
    span = [r["cc"]["span_ms"] for r in recs]
    ov = [r["cc"]["overlap_ms"] for r in recs]
    case, jobs = name.rsplit("_j", 1)
    tm, tp = med_p95(t); cm, cp = med_p95(c); lm, lp = med_p95(l); om, op = med_p95(tot)
    lines.append("| %s | %s | %d | %.1f / %.1f | %.1f / %.1f | %.1f / %.1f | %.1f / %.1f | %s/%s | %.1f | %.1f |" % (
        case, jobs, len(recs), tm, tp, cm, cp, lm, lp, om, op, recs[-1]["stale"], recs[-1]["units"], statistics.median(span), statistics.median(ov)))
    tag = "%s_J%s" % (case.upper(), "ALL" if jobs == ncpu else jobs)
    consts.append(("MATRIX_%s_TRANSPILE_MS_MEDIAN" % tag, tm))
    consts.append(("MATRIX_%s_TRANSPILE_MS_P95" % tag, tp))
    consts.append(("MATRIX_%s_TOTAL_MS_MEDIAN" % tag, om))
    consts.append(("MATRIX_%s_TOTAL_MS_P95" % tag, op))
lines += ["", "## Memory (one tracked run each, every core)", "", "| case | boundary | peak RSS MiB | alloc calls | requested MiB | live MiB | survivors from earlier phases |", "|---|---|---:|---:|---:|---:|---|"]
for path in sorted(glob.glob(os.path.join(m, "*_mem.jsonl"))):
    name = os.path.basename(path)[:-10]
    for r in (json.loads(l) for l in open(path) if l.strip()):
        for b in r["mem"]["boundaries"]:
            surv = ", ".join("%s %d/%.1f MiB" % (s["from"], s["n"], s["mib"]) for s in b["survivors"][:-1]) or "-"
            lines.append("| %s | %s | %.1f | %d | %.1f | %.1f | %s |" % (name, b["at"], b["rss_mib"], b["alloc_n"], b["alloc_mib"], b["live_mib"], surv))
        consts.append(("MATRIX_%s_PEAK_RSS_MIB" % name.upper(), r["mem"]["boundaries"][4]["rss_mib"]))
open(os.path.join(m, "report.md"), "w").write("\n".join(lines) + "\n")
with open(os.path.join(m, "constants.env"), "w") as f:
    f.write("# Whole-build constants from ci/bench_matrix.sh (build %s, %s cores, %s reps): medians and p95 in ms.\n" % (commit, ncpu, reps))
    for k, v in consts:
        f.write("%s=%.3f\n" % (k, v))
print("\n".join(lines))
print("\nmatrix: report in %s/report.md, constants in %s/constants.env" % (m, m))
EOF
if [ "${SC_MATRIX_RECORD:-0}" = 1 ]; then
    cp "$m/report.md" ci/baseline_report.md
    cp "$m/constants.env" ci/baseline_matrix.env
    printf 'matrix: recorded ci/baseline_report.md and ci/baseline_matrix.env\n'
fi
