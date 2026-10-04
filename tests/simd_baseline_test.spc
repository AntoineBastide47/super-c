// The C kernels of bench/simd_baseline give their scalar loops' results on every instruction set the host
// runs.
import bench::simd_baseline::kernels as sb;

@test
fn simd_baseline_kernels_match_the_scalar_loops() {
    assert(sb::isa_count() >= 1, "the host runs SSE2 or Neon");
    let m = sb::first_mismatch();
    if m.len() != 0 {
        eprintln("{}", m.as_str());
    }
    assert(m.len() == 0, "a C kernel differs from its scalar loop");
}
