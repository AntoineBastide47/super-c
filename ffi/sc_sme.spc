// FFI bindings for the SME matrix kernels in ffi/sc_sme.c (auto-discovered from "sc_sme.h"). Prefer
// `std::simd::matrix`, which checks the shapes and chooses a kernel by the CPU.
import std::cpu;

extern "C" "sc_sme.h" {
    /// 1 when ffi/sc_sme.c was built with the kernels (an aarch64 C compiler with <arm_sme.h>), else 0.
    @unsafe(safe)
    pub fn sc_sme_built() i32;
    /// `c` (m x n) = `a` (m x k) * `b` (k x n), row-major: 0, or -1 (`c` untouched) when the kernels are
    /// not built or their scratch cannot be allocated. The caller guarantees the three extents.
    @arch(aarch64)
    @target_feature([cpu::Feature::Sme2])
    pub fn sc_sme_mul_f32(c: *mut f32, a: *const f32, b: *const f32, m: usize, k: usize, n: usize) i32;
    /// The same for `f64`.
    @arch(aarch64)
    @target_feature([cpu::Feature::SmeF64f64])
    pub fn sc_sme_mul_f64(c: *mut f64, a: *const f64, b: *const f64, m: usize, k: usize, n: usize) i32;
    /// `c` (m x n, i32) = `a` (m x k) * `b` (k x n), i8: each element the sum of the products modulo 2^32.
    @arch(aarch64)
    @target_feature([cpu::Feature::Sme2])
    pub fn sc_sme_mul_i8(c: *mut i32, a: *const i8, b: *const i8, m: usize, k: usize, n: usize) i32;
}
