// Root of the self-hosted benchmark suite. Like selfhost/run_tests.spc, this file sits at selfhost/ root so
// module imports inside the benchmark resolve absolutely from here (root_dir).
//   Run: super-c selfhost/run_bench.spc  (emit) + cc -O2, or `make bench`.
import benchmark::transpile_bench as bench;

fn main() i32 {
    return bench::run();
}
