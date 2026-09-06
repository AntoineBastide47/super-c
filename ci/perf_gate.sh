#!/bin/sh
# The performance gate, one command: build the benchmark binary from the current checkout, run the
# 100-round self-transpile lane (its cold real build included), and compare the record with the accepted
# baseline constants in ci/baseline.env. Run from the repository root (or `super-c command perf`).
#
#   SC_PERF_TOL       allowed regression in percent over a baseline constant (default 3)
#   SC_PERF_MAX_LOAD  highest 1-minute load average the run accepts (default: a quarter of the cores)
#   SC_PERF_OUT       directory for the record and the report (default build/perf)
#   SC_PERF_RECORD=1  write the run as the new ci/baseline.env instead of comparing
#
# The gate refuses a busy box, a benchmark that reports any failure, and a benchmark binary that does not
# carry the checkout's commit; it exits nonzero on any constant past the tolerance.
set -eu
cd "$(dirname "$0")/.."
. ci/contract.sh

fail() { printf 'perf: FAILED: %s\n' "$1" >&2; exit 1; }
ncpu=$(getconf _NPROCESSORS_ONLN)
tol=${SC_PERF_TOL:-3}
out=${SC_PERF_OUT:-build/perf}
mkdir -p "$out"

# A quiet box: the 1-minute load average must be small next to the core count.
if [ -r /proc/loadavg ]; then
    load=$(awk '{print $1}' /proc/loadavg)
else
    load=$(sysctl -n vm.loadavg | awk '{print $2}')
fi
maxload=${SC_PERF_MAX_LOAD:-$(awk -v n="$ncpu" 'BEGIN { printf "%.2f", n / 4 }')}
awk -v l="$load" -v m="$maxload" 'BEGIN { exit !(l <= m) }' || fail "background load $load exceeds $maxload (SC_PERF_MAX_LOAD)"

commit=$(git rev-parse --short=12 HEAD)
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    build_id="$commit-dirty"
else
    build_id="$commit"
fi
ccver=$(cc --version | head -1)
if [ -r /proc/cpuinfo ]; then
    cpu=$(awk -F': ' '/model name/ { print $2; exit }' /proc/cpuinfo)
else
    cpu=$(sysctl -n machdep.cpu.brand_string)
fi
printf 'perf: contract v%s, build %s, %s, %s, %s cores, load %s\n' "$CONTRACT_VERSION" "$build_id" "$cpu" "$ccver" "$ncpu" "$load"

# The benchmark binary, fresh from this checkout; the generated runner must carry the checkout's identity.
./super-c bench --no-run || fail "the benchmark binary does not build"
grep -q "__bench::begin(\"$build_id\")" build/bench_root.spc || fail "build/bench_root.spc does not carry build id $build_id"

record="$out/self_transpile.json"
rm -f "$record"
SC_BENCH_OUT="$record" build/bench-bin --filter=self_transpile | tee "$out/self_transpile.txt" || fail "the benchmark reported a failure"
[ -f "$record" ] || fail "no record written to $record"

python3 - "$record" "$build_id" "$tol" "${SC_PERF_RECORD:-0}" "$cpu" "$ccver" "$ncpu" "$load" <<'EOF'
import json, sys
rec = json.load(open(sys.argv[1]))
build_id, tol, record_mode, cpu, ccver, ncpu, load = sys.argv[2], float(sys.argv[3]), sys.argv[4] == "1", sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8]
if not rec.get("ok"):
    sys.exit("perf: FAILED: the record reports failure")
if rec["build_id"] != build_id:
    sys.exit("perf: FAILED: the measured binary carries build %s, the checkout is %s" % (rec["build_id"], build_id))
b = rec["build"]
if not b.get("ok"):
    sys.exit("perf: FAILED: the real build failed")
ph = rec["phases"]
# The named constants: every later percentage gate resolves against these.
consts = [
    ("BASE_TRANSPILE_SERIAL_CPU_MS_MEDIAN", rec["cpu_ms"]["median"], True),
    ("BASE_TRANSPILE_SERIAL_CPU_MS_P95", rec["cpu_ms"]["p95"], False),
    ("BASE_TRANSPILE_SERIAL_WALL_MS_MEDIAN", rec["wall_ms"]["median"], False),
    ("BASE_TRANSPILE_SERIAL_MCYC_MEDIAN", rec["mcyc"]["median"], True),
    ("BASE_TRANSPILE_SERIAL_MCYC_P95", rec["mcyc"]["p95"], False),
    ("BASE_TRANSPILE_SERIAL_KALLOC", ph["total"]["kalloc"], True),
    ("BASE_TRANSPILE_SERIAL_HEAP_MIB", rec["heap_mib"], True),
    ("BASE_TRANSPILE_SERIAL_PEAK_RSS_MIB", rec["peak_rss_mib"], True),
    ("BASE_PHASE_PARSE_MCYC", ph["parse"]["mcyc"], True),
    ("BASE_PHASE_RESOLVE_MCYC", ph["resolve"]["mcyc"], True),
    ("BASE_PHASE_TYPECHECK_MCYC", ph["typecheck"]["mcyc"], True),
    ("BASE_PHASE_BORROWCK_MCYC", ph["borrowck"]["mcyc"], True),
    ("BASE_PHASE_CODEGEN_MCYC", ph["codegen"]["mcyc"], True),
    ("BASE_PHASE_PARSE_KALLOC", ph["parse"]["kalloc"], False),
    ("BASE_PHASE_RESOLVE_KALLOC", ph["resolve"]["kalloc"], False),
    ("BASE_PHASE_TYPECHECK_KALLOC", ph["typecheck"]["kalloc"], False),
    ("BASE_PHASE_BORROWCK_KALLOC", ph["borrowck"]["kalloc"], False),
    ("BASE_PHASE_CODEGEN_KALLOC", ph["codegen"]["kalloc"], False),
    ("BASE_BUILD_PARALLEL_JOBS", b["jobs"], False),
    ("BASE_BUILD_PARALLEL_TRANSPILE_MS", sum(b["ms"][k] for k in ("stamp", "load", "resolve", "typecheck", "borrowck", "checks", "prepare", "plan", "render", "publish")), False),
]
# Every engine phase of the real build, one constant each (the partition of BASE_BUILD_PARALLEL_TOTAL_MS).
consts += [("BASE_BUILD_PARALLEL_%s_MS" % k.upper(), v, False) for k, v in b["ms"].items()]
consts.append(("BASE_BUILD_PARALLEL_CC_SPAN_MS", b["cc"]["span_ms"], False))
consts.append(("BASE_BUILD_PARALLEL_CC_OVERLAP_MS", b["cc"]["overlap_ms"], False))
if record_mode:
    with open("ci/baseline.env", "w") as f:
        f.write("# Accepted performance baseline: written by `SC_PERF_RECORD=1 ci/perf_gate.sh`, compared by ci/perf_gate.sh.\n")
        f.write("# In-process constants: 100 serial self-transpile rounds (CPU ms, on-core Mcyc, Kalloc = allocator calls in\n")
        f.write("# thousands); BUILD constants: one cold dev build of the compiler through the engine with every core.\n")
        f.write("BASE_COMMIT=%s\nBASE_CPU=\"%s\"\nBASE_CC=\"%s\"\nBASE_CORES=%s\nBASE_ROUNDS=%d\nBASE_LOAD_1MIN=%s\n" % (build_id, cpu, ccver, ncpu, rec["rounds"], load))
        for name, value, _ in consts:
            f.write("%s=%.3f\n" % (name, value))
    print("perf: recorded ci/baseline.env from build %s" % build_id)
    sys.exit(0)
base = {}
try:
    for line in open("ci/baseline.env"):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            base[k] = v.strip('"')
except FileNotFoundError:
    sys.exit("perf: FAILED: no ci/baseline.env (record one with SC_PERF_RECORD=1)")
print("perf: baseline %s on %s (recorded at load %s, this run at %s)" % (base.get("BASE_COMMIT"), base.get("BASE_CPU"), base.get("BASE_LOAD_1MIN", "?"), load))
if base.get("BASE_CPU") != cpu:
    print("perf: WARNING: the baseline was recorded on %s, this box is %s: wall and cycle constants do not transfer" % (base.get("BASE_CPU"), cpu))
print("%-42s %12s %12s %8s" % ("constant", "baseline", "now", "delta"))
bad = 0
for name, value, gated in consts:
    if name not in base:
        continue
    ref = float(base[name])
    delta = (value - ref) / ref * 100 if ref else 0.0
    flag = ""
    if gated and delta > tol:
        flag = "  REGRESSION"
        bad += 1
    print("%-42s %12.3f %12.3f %+7.2f%%%s" % (name, ref, value, delta, flag))
if bad:
    sys.exit("perf: FAILED: %d constant(s) regressed past %.1f%% (SC_PERF_TOL)" % (bad, tol))
print("perf: OK within %.1f%%" % tol)
EOF
