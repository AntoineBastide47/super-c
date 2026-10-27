#!/bin/sh
# Measures the SIMD baselines of this machine and the C compiler of the hand-written kernels, and replaces
# their rows in baseline.tsv. Run from the repository root with ./super-c built from the commit under
# measurement, on a quiet machine. The arguments go to `super-c bench` and `super-c build`:
#
#   sh bench/simd_baseline/record.sh                 # the host's instruction sets, C compiler $CC (else cc)
#   sh bench/simd_baseline/record.sh --target=wasm   # SIMD128 under wasmtime, C compiler $WASI_SDK_PATH/bin/clang
#   sh bench/simd_baseline/record.sh --target-cpu=x86-64-v3   # the portable kernels at AVX2 (v4: AVX-512)
set -eu
dir=bench/simd_baseline
sc=./super-c${BINEXT:-}
cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || sed -n 's/^model name[^:]*: //p' /proc/cpuinfo | head -n 1)
machine="$(uname -s | sed 's/[-_].*//') $(uname -m) $cpu"
case " $* " in
*" --target-cpu="*) machine="$machine, $(printf ' %s' "$*" | sed 's/.* --target-cpu=\([^ ]*\).*/\1/')" ;;
esac
case " $* " in
*" --target=wasm "*)
    cc=${WASI_SDK_PATH:+$WASI_SDK_PATH/bin/}clang
    machine="wasmtime $(wasmtime --version | cut -d' ' -f2), $machine"
    run="wasmtime build/bench-bin"
    ;;
*)
    cc=${CC:-cc}
    run=build/bench-bin${BINEXT:-}
    ;;
esac
# The C compiler of the hand-written kernels.
version=$($cc --version | head -n 1)

# replace FILE HEADER KEY ROWS: FILE with its rows whose first two columns are KEY replaced by ROWS.
replace() {
    [ -n "$4" ] || { printf 'record: no rows for %s\n' "$1" >&2; exit 1; }
    { printf '%s\n' "$2"; tail -n +2 "$1" 2>/dev/null | awk -F'\t' -v k="$3" '$1 "\t" $2 != k'; printf '%s\n' "$4"; } >"$1.tmp"
    mv "$1.tmp" "$1"
}


sh $dir/kernels.sh "$@"
"$sc" bench --no-run --filter=simd_baseline "$@"
$run >build/simd_baseline.out
profile=$(sed -n 's/^running benchmarks (build [^;]*; \([^ ]*\).*/\1/p' build/simd_baseline.out)
rows=$(awk -F'\t' -v m="$machine" -v v="$version" -v p="$profile" '$1 == "simd" { print m "\t" v "\t" p "\t" $2 "\t" $3 "\t" $4 "\t" $5 }' build/simd_baseline.out)
replace $dir/baseline.tsv "$(printf 'machine\tcompiler\tprofile\tkernel\tisa\tbytes\tns_per_element')" "$(printf '%s\t%s' "$machine" "$version")" "$rows"
