#!/bin/sh
# The accepted-work ledger: one protocol over a chain of commits (the accepted baseline first, then
# every accepted change in landing order), each measured against the commit before it. The released
# bootstrap compiler (the same binary check.sh bootstraps from) builds each commit's benchmark binary
# from an export of its tree, so every row is compiled by one compiler and links that compiler's
# standard library (a std change is measured by ci/perf_gate.sh, whose binary the checkout's own
# compiler builds); the binary runs the 100-round self-transpile lane (ci/perf_gate.sh's lane) over the
# commit's sources and its cold real build. Run from the repository root:
#
#   sh ci/ledger.sh <baseline-commit> <commit>...
#
#   SC_LEDGER_OUT   directory for the exports and records (default build/ledger)
#   SC_LEDGER_BIN   the bootstrap compiler to build with (default: the latest release, downloaded)
#
# Writes ci/ledger.tsv: one row per (change, metric) with the value at the parent, the value after the
# change, the improvement and the regression it is accepted with, and its overlap owner (every row
# is measured against its direct parent, so the improvements of a chain never overlap: the owner is
# the change itself). ci/perf_gate.sh resolves the cutover limits from these rows.
set -eu
cd "$(dirname "$0")/.."
fail() { printf 'ledger: FAILED: %s\n' "$1" >&2; exit 1; }
[ $# -ge 2 ] || fail "usage: sh ci/ledger.sh <baseline-commit> <commit>..."
out=${SC_LEDGER_OUT:-build/ledger}
mkdir -p "$out"
out=$(cd "$out" && pwd)
bin=${SC_LEDGER_BIN:-}
if [ -z "$bin" ]; then
    gh release download --pattern super-c-macos-arm64.tar.gz --dir "$out" --clobber || fail "cannot download the release bootstrap binary"
    tar xzf "$out/super-c-macos-arm64.tar.gz" -C "$out"
    bin="$out/super-c-macos-arm64/super-c"
fi
ncpu=$(getconf _NPROCESSORS_ONLN)
for c in "$@"; do
    rec="$out/$c.json"
    [ -f "$rec" ] && continue # a record already measured under this protocol stands
    d="$out/$c"
    rm -rf "$d"; mkdir -p "$d"
    git archive "$c" | tar -x -C "$d"
    printf 'ledger: %s (%s)\n' "$c" "$(git log -1 --format=%s "$c" | cut -c1-72)"
    ( cd "$d" && SC_LEAK_CHECK= "$bin" bench --no-run >"$d/build.log" 2>&1 ) || fail "$c: the benchmark binary does not build (see $d/build.log)"
    ( cd "$d" && SC_BENCH_OUT="$rec" build/bench-bin --filter=self_transpile >"$out/$c.txt" 2>&1 ) || fail "$c: the benchmark reported a failure (see $out/$c.txt)"
    rm -rf "$d"
done
python3 - "$out" "$ncpu" "$@" <<'PY'
import json, subprocess, sys
out, ncpu, commits = sys.argv[1], sys.argv[2], sys.argv[3:]
def metrics(rec):
    ph, b = rec["phases"], rec["build"]
    m = {
        "serial_cpu_ms": rec["cpu_ms"]["median"],
        "serial_mcyc": rec["mcyc"]["median"],
        "serial_kalloc": ph["total"]["kalloc"],
        "heap_mib": rec["heap_mib"],
        "peak_rss_mib": rec["peak_rss_mib"],
        "frontend_mcyc": ph["parse"]["mcyc"] + ph["resolve"]["mcyc"] + ph["typecheck"]["mcyc"],
    }
    for k in ("parse", "resolve", "typecheck", "borrowck", "codegen"):
        m["phase_%s_mcyc" % k] = ph[k]["mcyc"]
    if b.get("ok"):
        m["parallel_transpile_ms"] = sum(b["ms"][k] for k in ("stamp", "load", "resolve", "typecheck", "borrowck", "checks", "prepare", "plan", "render", "publish"))
    return m
rows = []
prev = None
for c in commits:
    rec = json.load(open("%s/%s.json" % (out, c)))
    if not rec.get("ok"):
        sys.exit("ledger: FAILED: %s reports failure" % c)
    subj = subprocess.run(["git", "log", "-1", "--format=%s", c], capture_output=True, text=True).stdout.strip()[:72]
    m = metrics(rec)
    if prev is not None:
        pc, pm = prev
        for k in sorted(m):
            if k not in pm:
                continue
            d = m[k] - pm[k]
            rows.append((subj.replace("\t", " "), c, pc, k, pm[k], m[k], max(-d, 0.0), max(d, 0.0), c))
    prev = (c, m)
with open("ci/ledger.tsv", "w") as f:
    f.write("# Accepted-work ledger (ci/ledger.sh): every change of the chain against its parent under one protocol\n")
    f.write("# (bootstrap-built benchmark binaries, 100 serial self-transpile rounds and one cold real build, %s cores).\n" % ncpu)
    f.write("# baseline record: the first commit of the chain, measured under this protocol; the perf gate scales\n")
    f.write("# ci/baseline.env by the resolved limit over that value.\n")
    f.write("# work\tcommit\tparent\tmetric\tparent_value\tvalue\timprovement\tregression\towner\n")
    for r in rows:
        f.write("%s\t%s\t%s\t%s\t%.3f\t%.3f\t%.3f\t%.3f\t%s\n" % r)
print("ledger: wrote ci/ledger.tsv (%d rows over %d changes)" % (len(rows), len(commits) - 1))
PY
