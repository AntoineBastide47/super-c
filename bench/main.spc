// Root of the self-hosted benchmark suite (`super-c bench`): rooted at the project root, so
// bench:: modules resolve directly and compiler modules resolve through the src/ alt root.
import bench::transpile_bench as bench;
import bench::concurrency_bench as conc;

fn main() i32 {
    let rc = bench::run();
    if rc != 0 {
        return rc;
    }
    return conc::run();
}
