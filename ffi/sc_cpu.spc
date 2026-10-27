// CPU feature detection, the project's one detector, for `std::cpu::detect` and the generated C (the
// run-time choice of `--simd-dispatch` copies calls `sc_cpu_words`). Bit `i` of a feature word is the
// `cpu::Feature` variant of discriminant `i`. Per OS, the one query each offers: CPUID and XGETBV on
// x86_64, `sysctlbyname` on macOS and iOS, the `getauxval` HWCAP bits on Linux and Android,
// `IsProcessorFeaturePresent` on Windows aarch64, none on wasm32. A failing or missing query means the
// feature is absent. Detection allocates nothing, takes no lock and runs once: an init-array entry runs
// it before `main`, and the first query runs it too. A feature the build enables counts as present.
import std::cpu;
import atomic;
import stdlib;

/// Detect the features; idempotent, safe before `main` and from any thread.
pub fn sc_cpu_init() {
    unsafe {
        if atomic::load_i32(&READY, 1) != 0 {
            return;
        }
        // The answer, then the state word: a reader that sees the state set sees the answer. Two first
        // callers store equal words.
        atomic::store_u64(&mut WORD, detect() | TARGET_FEATURES[0], 0);
        atomic::store_i32(&mut READY, 1, 2);
    }
}

/// 1 when feature `feature` (a `cpu::Feature` discriminant) is present (detected, or enabled by the
/// build), else 0.
@export("sc_cpu_has")
pub fn sc_cpu_has(feature: i32) i32 {
    sc_cpu_init();
    if feature < 0 || feature >= 64 {
        return 0;
    }
    return (unsafe atomic::load_u64(&WORD, 0) >> feature as u64 & 1) as i32;
}

/// The present features, two words, into `out[0]` and `out[1]`. C callers: `void sc_cpu_words(uint64_t
/// out[2])`.
@export("sc_cpu_words")
pub unsafe fn sc_cpu_words(out: *mut u64) {
    sc_cpu_init();
    out[0] = atomic::load_u64(&WORD, 0);
    out[1] = 0;
}

/// The features the OS query reports, without the build's: a new query on each call.
pub unsafe fn sc_cpu_detected_words(out: *mut u64) {
    out[0] = detect();
    out[1] = 0;
}

/// The features the build enables (`TARGET_FEATURES`), two words.
pub unsafe const fn sc_cpu_static_words(out: *mut u64) {
    out[0] = TARGET_FEATURES[0];
    out[1] = TARGET_FEATURES[1];
}

/// The x86 features (one word) of CPUID registers `r[0..7]` (leaf 1 ECX; leaf 7.0 EBX, ECX and EDX;
/// leaf 7.1 EDX; leaf 80000001h ECX; leaf 24h EBX), XCR0 `xcr0` and the OS's own report of the AVX-512
/// state `os_zmm` (macOS): the decision of the x86 query, a pure function on every host.
pub unsafe fn sc_cpu_x86_decide(r: *const u32, xcr0: u64, os_zmm: i32) u64 {
    // OSXSAVE and XCR0 bits 1 and 2 (SSE and AVX state); bits 5 to 7 (opmask and ZMM state), which macOS
    // enables per thread on first use, so there the OS's own answer stands for them.
    let ymm = (r[0] >> 27 & 1) != 0 && (xcr0 & 6) == 6;
    let zmm = ymm && (os_zmm != 0 || (xcr0 & 0xE0) == 0xE0);
    let mut w = bit(cpu::Feature::Sse2);
    let rows: [](u8, u8, cpu::Feature, u8) = X86_ROWS;
    for row in rows {
        let state_ok = row.3 == 0 || row.3 == 1 && ymm || row.3 == 2 && zmm;
        if (r[row.0 as usize] >> row.1 as u32 & 1) != 0 && state_ok {
            w |= bit(row.2);
        }
    }
    // AVX10: CPUID.(7,1):EDX bit 19, the version in CPUID.24h:EBX bits 0 to 7, the 512-bit form bit 18.
    if zmm && (r[4] >> 19 & 1) != 0 && (r[6] >> 18 & 1) != 0 && (r[6] & 0xFF) >= 1 {
        w |= bit(cpu::Feature::Avx101);
        if (r[6] & 0xFF) >= 2 {
            w |= bit(cpu::Feature::Avx102);
        }
    }
    return w;
}

/// How many times the OS query ran in this process (`sc_cpu_detected_words` included).
pub fn sc_cpu_query_count() i32 {
    return unsafe atomic::load_i32(&QUERIES, 0);
}

// The published answer, the state word that publishes it, and the OS queries made: one per process
// unless two first callers race before `main`.
static mut WORD: u64 = 0;
static mut READY: i32 = 0;
static mut QUERIES: i32 = 0;

// The init-array entry of the platform's executable format: the loader calls it before `main`.
@platform(macos | ios)
@unsafe(link_section = "__DATA,__mod_init_func,mod_init_funcs")
static mut INIT_ENTRY: fn() = sc_cpu_init;
@platform(linux | android)
@unsafe(link_section = ".init_array")
static mut INIT_ENTRY: fn() = sc_cpu_init;
@platform(windows)
@unsafe(link_section = ".CRT$XCU")
static mut INIT_ENTRY: fn() = sc_cpu_init;

const fn bit(f: cpu::Feature) u64 {
    return 1u64 << f as u64;
}

// SC_CPU_OFF (a test switch): a mask of detected features to report absent, read as `strtoull` reads
// it (base 0).
extern "C" "stdlib.h" {
    @import("getenv")
    fn c_getenv(name: *const char) *const char;
    fn strtoull(s: *const char, end: *mut void, base: i32) u64;
}

// The OS query's answer.
fn detect() u64 {
    let mut w = query();
    let off = unsafe c_getenv("SC_CPU_OFF".ptr() as *const char);
    if off != null {
        w &= ~unsafe strtoull(off, null, 0);
    }
    unsafe atomic::add_i32(&mut QUERIES, 1, 0);
    return w;
}

// The CPUID bit of each x86 feature: register `r[reg]`, bit `bit`, the feature, and `state` 1 when it
// needs the AVX register state, 2 when the AVX-512 state too.
const X86_ROWS: [(u8, u8, cpu::Feature, u8); 31] = [
    (0, 0, cpu::Feature::Sse3, 0),
    (0, 9, cpu::Feature::Ssse3, 0),
    (0, 19, cpu::Feature::Sse41, 0),
    (0, 20, cpu::Feature::Sse42, 0),
    (0, 23, cpu::Feature::Popcnt, 0),
    (0, 13, cpu::Feature::Cx16, 0),
    (5, 0, cpu::Feature::LahfSahf, 0),
    (0, 28, cpu::Feature::Avx, 1),
    (1, 5, cpu::Feature::Avx2, 1),
    (0, 12, cpu::Feature::Fma, 1),
    (1, 3, cpu::Feature::Bmi1, 0),
    (1, 8, cpu::Feature::Bmi2, 0),
    (0, 29, cpu::Feature::F16c, 1),
    (5, 5, cpu::Feature::Lzcnt, 0),
    (0, 22, cpu::Feature::Movbe, 0),
    (1, 16, cpu::Feature::Avx512f, 2),
    (1, 30, cpu::Feature::Avx512bw, 2),
    (1, 28, cpu::Feature::Avx512cd, 2),
    (1, 17, cpu::Feature::Avx512dq, 2),
    (1, 31, cpu::Feature::Avx512vl, 2),
    (2, 1, cpu::Feature::Avx512vbmi, 2),
    (2, 6, cpu::Feature::Avx512vbmi2, 2),
    (2, 12, cpu::Feature::Avx512bitalg, 2),
    (2, 14, cpu::Feature::Avx512vpopcntdq, 2),
    (2, 11, cpu::Feature::Avx512vnni, 2),
    (3, 23, cpu::Feature::Avx512fp16, 2),
    (2, 8, cpu::Feature::Gfni, 0),
    (2, 9, cpu::Feature::Vaes, 1),
    (2, 10, cpu::Feature::Vpclmulqdq, 1),
    (0, 25, cpu::Feature::Aesni, 0),
    (0, 1, cpu::Feature::Pclmulqdq, 0),
];

// x86_64: CPUID leaves 1, (7,0), (7,1) when (7,0) reports it, 80000001h and 24h, a leaf past the maximum
// reading as zeros; XGETBV(0) when OSXSAVE is set; on macOS the OS's report of the AVX-512 state.
@arch(x86_64)
fn query() u64 {
    let mut r: [u32; 7] = [0; 7];
    let (_, _, c1, _) = cpuid(1, 0);
    r[0] = c1;
    let (a7, b7, c7, d7) = cpuid(7, 0);
    r[1] = b7;
    r[2] = c7;
    r[3] = d7;
    if a7 >= 1 {
        let (_, _, _, d71) = cpuid(7, 1);
        r[4] = d71;
    }
    let (_, _, ce, _) = cpuid(0x80000001, 0);
    r[5] = ce;
    let (_, b24, _, _) = cpuid(0x24, 0);
    r[6] = b24;
    let mut xcr0: u64 = 0;
    if (r[0] >> 27 & 1) != 0 {
        let mut lo: u32 = 0;
        let mut hi: u32 = 0;
        unsafe {
            asm("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0u32));
        }
        xcr0 = hi as u64 << 32 | lo as u64;
    }
    return unsafe sc_cpu_x86_decide(&r[0], xcr0, os_zmm());
}

// Whether CPUID leaf `leaf` exists: its range's maximum leaf (CPUID 0 or 80000000h) reaches it.
@arch(x86_64)
fn leaf_ok(leaf: u32) bool {
    let (max, _, _, _) = cpuid_raw(leaf & 0x80000000, 0);
    return max != 0 && max >= leaf;
}

// CPUID leaf `leaf`, subleaf `sub`: EAX, EBX, ECX and EDX, zeros past the maximum leaf.
@arch(x86_64)
fn cpuid(leaf: u32, sub: u32) (u32, u32, u32, u32) {
    if !leaf_ok(leaf) {
        return 0, 0, 0, 0;
    }
    return cpuid_raw(leaf, sub);
}

@arch(x86_64)
fn cpuid_raw(leaf: u32, sub: u32) (u32, u32, u32, u32) {
    let mut a: u32 = 0;
    let mut b: u32 = 0;
    let mut c: u32 = 0;
    let mut d: u32 = 0;
    unsafe {
        asm("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(leaf), "c"(sub));
    }
    return a, b, c, d;
}

@platform(macos | ios)
@arch(x86_64)
fn os_zmm() i32 {
    return sysctl_flag("hw.optional.avx512f") as i32;
}

@platform(windows | linux | android)
@arch(x86_64)
fn os_zmm() i32 {
    return 0;
}

// The Apple queries: hw.optional.arm.FEAT_* is 1 when present; a missing key (no SVE key exists) means
// absent.
@platform(macos | ios)
@arch(aarch64)
const APPLE_ROWS: [(str<'static>, cpu::Feature); 13] = [
    ("hw.optional.arm.FEAT_FP16", cpu::Feature::Fp16),
    ("hw.optional.arm.FEAT_DotProd", cpu::Feature::Dotprod),
    ("hw.optional.arm.FEAT_RDM", cpu::Feature::Rdm),
    ("hw.optional.arm.FEAT_I8MM", cpu::Feature::I8mm),
    ("hw.optional.arm.FEAT_BF16", cpu::Feature::Bf16),
    ("hw.optional.arm.FEAT_AES", cpu::Feature::Aes),
    ("hw.optional.arm.FEAT_SHA256", cpu::Feature::Sha2),
    ("hw.optional.arm.FEAT_SHA3", cpu::Feature::Sha3),
    ("hw.optional.arm.FEAT_CRC32", cpu::Feature::Crc),
    ("hw.optional.arm.FEAT_LSE", cpu::Feature::Lse),
    ("hw.optional.arm.FEAT_SME", cpu::Feature::Sme),
    ("hw.optional.arm.FEAT_SME2", cpu::Feature::Sme2),
    ("hw.optional.arm.FEAT_SME_F64F64", cpu::Feature::SmeF64f64),
];

@platform(macos | ios)
@arch(aarch64)
fn query() u64 {
    let mut w = bit(cpu::Feature::Neon);
    let rows: [](str<'static>, cpu::Feature) = APPLE_ROWS;
    for row in rows {
        if sysctl_flag(row.0) {
            w |= bit(row.1);
        }
    }
    return w;
}

// <sys/sysctl.h> needs the Darwin extensions, which the build's `_POSIX_C_SOURCE` hides: the binding
// has no header, so this declaration is its whole prototype.
@platform(macos | ios)
extern "C" {
    fn sysctlbyname(name: *const char, oldp: *mut void, oldlenp: *mut usize, newp: *mut void, newlen: usize) i32;
}

// Whether the integer sysctl `key` (a string literal, so NUL-terminated) is nonzero.
@platform(macos | ios)
fn sysctl_flag(key: str<'static>) bool {
    let mut v: i32 = 0;
    let mut n = sizeof(i32);
    let r = unsafe sysctlbyname(key.ptr() as *const char, &mut v, &mut n, null, 0);
    return r == 0 && n == sizeof(i32) && v != 0;
}

// The PF_ARM_* values of the IsProcessorFeaturePresent documentation (older MinGW headers lack some
// names). A V8 crypto bit covers AES and SHA-2; no constant exists for RDM.
@platform(windows)
@arch(aarch64)
const WINDOWS_ROWS: [(u32, cpu::Feature); 14] = [
    (67, cpu::Feature::Fp16),
    (43, cpu::Feature::Dotprod),
    (66, cpu::Feature::I8mm),
    (68, cpu::Feature::Bf16),
    (30, cpu::Feature::Aes),
    (30, cpu::Feature::Sha2),
    (64, cpu::Feature::Sha3),
    (31, cpu::Feature::Crc),
    (34, cpu::Feature::Lse),
    (46, cpu::Feature::Sve),
    (47, cpu::Feature::Sve2),
    (70, cpu::Feature::Sme),
    (71, cpu::Feature::Sme2),
    (85, cpu::Feature::SmeF64f64),
];

// kernel32's `BOOL IsProcessorFeaturePresent(DWORD)`. Its header declares it: a prototype of
// Super-C's own (`unsigned int` for `DWORD`, an `unsigned long`) would conflict with that declaration
// in a unit that includes <windows.h> for another binding.
@platform(windows)
@arch(aarch64)
extern "C" "windows.h" {
    fn IsProcessorFeaturePresent(feature: u32) i32;
}

@platform(windows)
@arch(aarch64)
fn query() u64 {
    let mut w = bit(cpu::Feature::Neon);
    let rows: [](u32, cpu::Feature) = WINDOWS_ROWS;
    for row in rows {
        if unsafe IsProcessorFeaturePresent(row.0) != 0 {
            w |= bit(row.1);
        }
    }
    return w;
}

// The HWCAP (word 0) and HWCAP2 (word 1) bits of the kernel's arch/arm64/include/uapi/asm/hwcap.h; older
// libc headers lack some names. fp16 needs both its scalar and its vector bit (HWCAP bits 9 and 10).
@platform(linux | android)
@arch(aarch64)
const HWCAP_ROWS: [(u8, u8, cpu::Feature); 15] = [
    (0, 1, cpu::Feature::Neon),
    (0, 20, cpu::Feature::Dotprod),
    (0, 12, cpu::Feature::Rdm),
    (1, 13, cpu::Feature::I8mm),
    (1, 14, cpu::Feature::Bf16),
    (0, 3, cpu::Feature::Aes),
    (0, 6, cpu::Feature::Sha2),
    (0, 17, cpu::Feature::Sha3),
    (0, 7, cpu::Feature::Crc),
    (0, 8, cpu::Feature::Lse),
    (0, 22, cpu::Feature::Sve),
    (1, 1, cpu::Feature::Sve2),
    (1, 23, cpu::Feature::Sme),
    (1, 37, cpu::Feature::Sme2),
    (1, 25, cpu::Feature::SmeF64f64),
];

// getauxval gives 0 for an entry the kernel does not supply.
@platform(linux | android)
@arch(aarch64)
extern "C" "sys/auxv.h" {
    const AT_HWCAP: stdlib::c_ulong = 16;
    const AT_HWCAP2: stdlib::c_ulong = 26;
    fn getauxval(kind: stdlib::c_ulong) stdlib::c_ulong;
}

@platform(linux | android)
@arch(aarch64)
fn query() u64 {
    let hw: [u64; 2] = [(unsafe getauxval(AT_HWCAP)) as u64, (unsafe getauxval(AT_HWCAP2)) as u64];
    let mut w: u64 = 0;
    let rows: [](u8, u8, cpu::Feature) = HWCAP_ROWS;
    for row in rows {
        if (unsafe hw[row.0 as usize] >> row.1 as u64 & 1) != 0 {
            w |= bit(row.2);
        }
    }
    if (hw[0] >> 9 & 1) != 0 && (hw[0] >> 10 & 1) != 0 {
        w |= bit(cpu::Feature::Fp16);
    }
    return w;
}

// wasm32: no query; an engine rejects a module whose features it lacks.
@arch(wasm32)
fn query() u64 {
    return 0;
}
