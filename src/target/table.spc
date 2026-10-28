// The target table: the only source of target facts. A target is one row of `TARGETS`, made of five
// parts: its instruction set (`Isa`), calling convention (`CallConv`), object format (`ObjFormat`),
// operating system (`Os`) and debug format (`Debug`), plus the C data model and the default CPU
// features. Shared code reads a row or a part, never a target name or index: a new target is a row,
// and a new part is a row of its part table. The `@platform` axis is `OSES` (a name's index is its
// mask bit), the `@arch` axis `ISAS`.
import ir::cpu_features as cf;

/// An instruction set: one `@arch` name.
pub(package) struct Isa {
    pub(package) name: str<'static>, // `@arch`, `--arch`
    pub(package) variant: str<'static>, // the `std::target::Arch` variant
    pub(package) ptr_bytes: u8,
    /// A function may enable features its build lacks (`@target_feature`, run-time dispatch). False on
    /// wasm32: a module validates as a whole, so features are per build.
    pub(package) fn_features: bool,
    /// Its features come in the x86-64 psABI levels (`x86-64-v3`), and builds dispatch over them.
    pub(package) levels: bool,
    /// A feature's C flag is an extension of one `-march`/`-mcpu` flag (`+dotprod`), not a flag of its own.
    pub(package) ext_flags: bool,
    /// Naked functions (`@unsafe(naked)`): a function without prologue or epilogue.
    pub(package) naked: bool,
    /// `frame.return_address` has a value; else it is null.
    pub(package) return_address: bool,
    /// The vector unit sums mask lanes faster than it extracts lane bits (Neon has no lane-bits
    /// instruction), so `count` of a comparison folds lane masks.
    pub(package) mask_fold: bool,
    /// Every processor of it has a scalar fused multiply-add (else only one with its feature `fma`).
    pub(package) scalar_fma: bool,
    /// The C compiler vectorizes a merged loop of loads and stores through two slices it cannot prove
    /// apart (wasm's does), so a vector load and store over different slices may share one loop.
    pub(package) merge_apart: bool,
    /// The bytes of a vector the native backend computes in one register, 0 when it computes vectors
    /// lane by lane in memory (wasm32): the LIR vectorizer runs only with registers.
    pub(package) vector_bytes: u8,
    /// One instruction gives the high half of a 64-bit product (UMULH, MUL's rdx): the optimizer divides
    /// a 64-bit value by a constant with a product (`lir::ir::Package::mul_high`).
    pub(package) mul_high: bool,
    pub(package) simd_backend: str<'static>, // `std/simd/backend/<name>.spc`
    /// The C headers whose functions are the C compiler's intrinsics, space-separated: no object defines
    /// them, so a native backend expands each call from its template (`target::intrin`), and a call of
    /// one it has none for is a build error.
    pub(package) intrinsics: str<'static>,
}

/// A calling convention: how arguments and results pass, the callee-saved registers, varargs and
/// struct returns. The native backends lower LIR calls through it.
pub(package) struct CallConv {
    pub(package) name: str<'static>,
    pub(package) va_list_bytes: u8, // C `va_list`: a pointer, or the register save area's record
}

/// An object format: the object writer, relocations, section names and the linker.
pub(package) struct ObjFormat {
    pub(package) name: str<'static>,
    /// The rule of a `@unsafe(link_section)` name (`SEC_*`).
    pub(package) sections: u8,
    /// Symbols take hidden visibility.
    pub(package) hidden: bool,
    /// Shared-library code needs `-fPIC`.
    pub(package) pic: bool,
    /// The link flag that records a shared library's own name, which a program linking it loads it
    /// through; the name follows. Empty: none.
    pub(package) soname: str<'static>,
}

/// An operating system: one `@platform` name.
pub(package) struct Os {
    pub(package) name: str<'static>, // `@platform`, `--target`
    pub(package) variant: str<'static>, // the `std::target::Platform` variant
    /// The instruction set a `--target` of this system picks without `--arch`: an `ISAS` index, or -1
    /// for the host's.
    pub(package) isa_default: i8,
    /// The cross toolchain its builds need (`SDK_*`).
    pub(package) sdk: u8,
    /// The layout of its C headers and libraries under a sysroot (`SYSROOT_*`).
    pub(package) sysroot: u8,
    /// One of Apple's systems: Mach-O tools (`ar`, `strip`, `xcrun`) serve every one of them.
    pub(package) darwin: bool,
    /// Its C library comes from std (`std::rt::libc`, `std::rt::libm`), not from the system.
    pub(package) own_libc: bool,
    pub(package) exe_suffix: str<'static>,
    pub(package) shared_prefix: str<'static>,
    pub(package) shared_suffix: str<'static>,
    pub(package) libm: str<'static>, // the link flag of the C math library, empty when the C library holds it
    /// The dialect its C headers are read and its emitted C compiles under, after the default one (after a
    /// space; empty: the default): mingw-w64 declares the POSIX functions only outside strict ISO C.
    pub(package) c_std: str<'static>,
    /// The defines every C compile for it has, each after a space: the API level the headers declare.
    pub(package) c_defines: str<'static>,
    /// The link flags of an executable, each after a space: the main thread's 8 MiB stack.
    pub(package) exe_link: str<'static>,
    /// The NDK's directory of prebuilt toolchains for a build on this system (one universal darwin
    /// toolchain on macOS).
    pub(package) ndk_host: str<'static>,
}

/// A debug-information format: the line tables, frame descriptions and type records.
pub(package) struct Debug {
    pub(package) name: str<'static>,
}

/// One target: its parts (indexes into `ISAS`, `CALLCONVS`, `OBJFORMATS`, `OSES`, `DEBUGS`), its C data
/// model and its build facts.
pub(package) struct Target {
    pub(package) isa: u8,
    pub(package) cc: u8,
    pub(package) obj: u8,
    pub(package) os: u8,
    pub(package) debug: u8,
    pub(package) triple: str<'static>, // the C compiler's `-target`
    pub(package) long_bytes: u8, // C `long`: 8 under LP64, 4 under LLP64 and ILP32
    /// C `long double`: 64 (an IEEE double), 80 (the x87 extended format) or 128 (IEEE quadruple).
    pub(package) long_double_bits: u8,
    pub(package) big_endian: bool,
    pub(package) red_zone: u16, // bytes below the stack pointer a leaf function may use
    pub(package) page_bytes: u32,
    /// The CPU features every build has, closed under `implies`.
    pub(package) features: cf::CpuFeatureSet,
    /// The features no machine of the target has.
    pub(package) never: cf::CpuFeatureSet,
    /// The `-mcpu` of a build with aarch64 features beyond the baseline, empty for `-march`.
    pub(package) mcpu: str<'static>,
    pub(package) apple_sdk: str<'static>, // the Apple SDK platform name of a `SYSROOT_APPLE` system
    pub(package) cenv: u8, // its C environment row (`bindgen::ctarget_data::ROWS`)
}

pub(package) const SDK_NONE: u8 = 0;
pub(package) const SDK_XCRUN: u8 = 1;
pub(package) const SDK_NDK: u8 = 2;
pub(package) const SDK_WASI: u8 = 3;

pub(package) const SYSROOT_APPLE: u8 = 0;
pub(package) const SYSROOT_LINUX: u8 = 1;
pub(package) const SYSROOT_ANDROID: u8 = 2;
pub(package) const SYSROOT_MINGW: u8 = 3;
pub(package) const SYSROOT_WASI: u8 = 4;

/// Any name of letters, digits, `_`, `.` and `$`.
pub(package) const SEC_PLAIN: u8 = 0;
/// `segment,section` with up to three more parts, each part at most 16 bytes.
pub(package) const SEC_MACHO: u8 = 1;
/// A plain name for data only: every function is in the code section.
pub(package) const SEC_DATA_ONLY: u8 = 2;

pub(package) const ISAS: [Isa; 3] = [
    Isa {
        name: "x86_64",
        variant: "X86_64",
        ptr_bytes: 8,
        fn_features: true,
        levels: true,
        ext_flags: false,
        naked: true,
        return_address: true,
        mask_fold: false,
        scalar_fma: false,
        merge_apart: false,
        vector_bytes: 16,
        mul_high: true,
        simd_backend: "x86_64",
        intrinsics: "immintrin.h x86intrin.h",
    },
    Isa {
        name: "aarch64",
        variant: "AArch64",
        ptr_bytes: 8,
        fn_features: true,
        levels: false,
        ext_flags: true,
        naked: true,
        return_address: true,
        mask_fold: true,
        scalar_fma: true,
        merge_apart: false,
        vector_bytes: 16,
        mul_high: true,
        simd_backend: "aarch64",
        intrinsics: "arm_neon.h arm_acle.h arm_sve.h arm_sme.h",
    },
    Isa {
        name: "wasm32",
        variant: "Wasm32",
        ptr_bytes: 4,
        fn_features: false,
        levels: false,
        ext_flags: false,
        naked: false,
        return_address: false,
        mask_fold: false,
        scalar_fma: false,
        merge_apart: true,
        vector_bytes: 0,
        mul_high: false,
        simd_backend: "wasm",
        intrinsics: "wasm_simd128.h",
    },
];

pub(package) const CALLCONVS: [CallConv; 6] = [
    CallConv { name: "sysv", va_list_bytes: 24 },
    CallConv { name: "win64", va_list_bytes: 8 },
    CallConv { name: "aapcs64", va_list_bytes: 32 },
    CallConv { name: "apple-aapcs64", va_list_bytes: 8 },
    CallConv { name: "win-aapcs64", va_list_bytes: 8 },
    CallConv { name: "wasm-c", va_list_bytes: 4 },
];

pub(package) const OBJFORMATS: [ObjFormat; 4] = [
    ObjFormat { name: "elf", sections: SEC_PLAIN, hidden: true, pic: true, soname: "-Wl,-soname," },
    ObjFormat { name: "macho", sections: SEC_MACHO, hidden: true, pic: true, soname: "-Wl,-install_name,@rpath/" },
    ObjFormat { name: "coff", sections: SEC_PLAIN, hidden: false, pic: false, soname: "" },
    ObjFormat { name: "wasm", sections: SEC_DATA_ONLY, hidden: true, pic: true, soname: "" },
];

// The `@platform` bit order: append only, since a mask bit and a `Platform` discriminant are an index.
pub(package) const OSES: [Os; 6] = [
    Os {
        name: "windows",
        variant: "Windows",
        isa_default: -1,
        sdk: SDK_NONE,
        sysroot: SYSROOT_MINGW,
        darwin: false,
        own_libc: false,
        exe_suffix: ".exe",
        shared_prefix: "",
        shared_suffix: ".dll",
        libm: "",
        c_std: " -std=gnu11",
        c_defines: " -D_WIN32_WINNT=0x0A00",
        exe_link: " -Wl,--stack,8388608",
        ndk_host: "windows-x86_64",
    },
    Os {
        name: "macos",
        variant: "MacOS",
        isa_default: -1,
        sdk: SDK_NONE,
        sysroot: SYSROOT_APPLE,
        darwin: true,
        own_libc: false,
        exe_suffix: "",
        shared_prefix: "lib",
        shared_suffix: ".dylib",
        libm: "-lm",
        c_std: "",
        c_defines: "",
        exe_link: "",
        ndk_host: "darwin-x86_64",
    },
    Os {
        name: "linux",
        variant: "Linux",
        isa_default: -1,
        sdk: SDK_NONE,
        sysroot: SYSROOT_LINUX,
        darwin: false,
        own_libc: false,
        exe_suffix: "",
        shared_prefix: "lib",
        shared_suffix: ".so",
        libm: "-lm",
        c_std: "",
        c_defines: "",
        exe_link: "",
        ndk_host: "linux-x86_64",
    },
    Os {
        name: "wasm",
        variant: "Wasm",
        isa_default: 2,
        sdk: SDK_WASI,
        sysroot: SYSROOT_WASI,
        darwin: false,
        own_libc: true,
        exe_suffix: "",
        shared_prefix: "lib",
        shared_suffix: ".so",
        libm: "",
        c_std: "",
        c_defines: "",
        exe_link: " -Wl,-z,stack-size=8388608 -Wl,--stack-first",
        ndk_host: "linux-x86_64",
    },
    Os {
        name: "ios",
        variant: "IOS",
        isa_default: 1,
        sdk: SDK_XCRUN,
        sysroot: SYSROOT_APPLE,
        darwin: true,
        own_libc: false,
        exe_suffix: "",
        shared_prefix: "lib",
        shared_suffix: ".dylib",
        libm: "-lm",
        c_std: "",
        c_defines: "",
        exe_link: "",
        ndk_host: "linux-x86_64",
    },
    Os {
        name: "android",
        variant: "Android",
        isa_default: 1,
        sdk: SDK_NDK,
        sysroot: SYSROOT_ANDROID,
        darwin: false,
        own_libc: false,
        exe_suffix: "",
        shared_prefix: "lib",
        shared_suffix: ".so",
        libm: "-lm",
        c_std: "",
        c_defines: "",
        exe_link: "",
        ndk_host: "linux-x86_64",
    },
];

pub(package) const DEBUGS: [Debug; 1] = [Debug { name: "dwarf" }];

const ISA_X86: u8 = 0;
const ISA_A64: u8 = 1;
const ISA_WASM: u8 = 2;
const CC_SYSV: u8 = 0;
const CC_WIN64: u8 = 1;
const CC_AAPCS: u8 = 2;
const CC_APPLE: u8 = 3;
const CC_WIN_A64: u8 = 4;
const CC_WASM: u8 = 5;
const OBJ_ELF: u8 = 0;
const OBJ_MACHO: u8 = 1;
const OBJ_COFF: u8 = 2;
const OBJ_WASM: u8 = 3;
const OS_WINDOWS: u8 = 0;
const OS_MACOS: u8 = 1;
const OS_LINUX: u8 = 2;
const OS_WASI: u8 = 3;
const OS_IOS: u8 = 4;
const OS_ANDROID: u8 = 5;
const NO_FEATURES: cf::CpuFeatureSet = cf::CpuFeatureSet { w: [0, 0] };

// The features `names` (space-separated) of instruction set `isa`, closed under `implies`.
const fn feats(names: str<'static>, isa: u8) cf::CpuFeatureSet {
    return cf::close(named(names, isa));
}

// The features `names` (space-separated) of instruction set `isa`.
const fn named(names: str<'static>, isa: u8) cf::CpuFeatureSet {
    let mut s = NO_FEATURES;
    let mut a: usize = 0;
    for i in 0..names.len() + 1 {
        if i < names.len() && names.byte_at(i) != b' ' {
            continue;
        }
        if i > a {
            let k = cf::find(names.slice(a, i), isa);
            assert(k >= 0 && cf::row(k as usize).arch == isa as i32, "a target names features of its instruction set");
            s = cf::with(s, k as usize);
        }
        a = i + 1;
    }
    return s;
}

// A row with the facts most targets share: no `-mcpu`, no Apple SDK.
const fn row(isa: u8, cc: u8, obj: u8, os: u8, triple: str<'static>, cenv: u8) Target {
    return Target {
        isa: isa,
        cc: cc,
        obj: obj,
        os: os,
        debug: 0,
        triple: triple,
        long_bytes: 8,
        long_double_bits: 128,
        big_endian: false,
        red_zone: 0,
        page_bytes: 4096,
        features: NO_FEATURES,
        never: NO_FEATURES,
        mcpu: "",
        apple_sdk: "",
        cenv: cenv,
    };
}

const fn x86(t: Target, features: str<'static>) Target {
    let mut r = t;
    r.long_double_bits = 80;
    r.red_zone = 128;
    r.features = feats(features, ISA_X86);
    return r;
}

const fn a64(t: Target, features: str<'static>) Target {
    let mut r = t;
    r.features = feats(features, ISA_A64);
    return r;
}

// An Apple system's row: Apple's SDK, no SVE on any of its machines.
const fn apple(t: Target, sdk: str<'static>) Target {
    let mut r = t;
    r.apple_sdk = sdk;
    if r.isa == ISA_A64 {
        r.long_double_bits = 64;
        r.red_zone = 128;
        r.page_bytes = 16384;
        r.never = named("sve sve2", ISA_A64);
    }
    return r;
}

// The baselines: a macOS aarch64 machine is at least the M1 (Apple clang's default CPU, `apple-m1`), an
// iOS one the A7 the iOS 13 floor allows; macOS x86_64 and the iOS simulator are `core2` (Apple clang's
// default `penryn` adds SSE4.1, but GCC on Darwin and clang for deployment targets before 10.12 stop at
// `core2`); Android x86_64 has its ABI's SSE4.2 and POPCNT.
const fn targets() [Target; 11] {
    let mut mac_a64 = apple(
        a64(
            row(ISA_A64, CC_APPLE, OBJ_MACHO, OS_MACOS, "arm64-apple-macos11.0", 1),
            "neon fp16 dotprod rdm aes sha2 sha3 crc lse",
        ),
        "MacOSX",
    );
    mac_a64.mcpu = "apple-m1";
    let ios_x86 = apple(
        x86(
            row(ISA_X86, CC_SYSV, OBJ_MACHO, OS_IOS, "x86_64-apple-ios13.0-simulator", 2),
            "sse2 sse3 ssse3 cx16 lahf-sahf",
        ),
        "iPhoneSimulator",
    );
    let ios_a64 = apple(
        a64(row(ISA_A64, CC_APPLE, OBJ_MACHO, OS_IOS, "arm64-apple-ios13.0", 3), "neon aes sha2"),
        "iPhoneOS",
    );
    let linux_a64 = a64(row(ISA_A64, CC_AAPCS, OBJ_ELF, OS_LINUX, "aarch64-unknown-linux-gnu", 5), "neon");
    let mut android_x86 = x86(
        row(ISA_X86, CC_SYSV, OBJ_ELF, OS_ANDROID, "x86_64-linux-android24", 6),
        "sse2 sse3 ssse3 sse4.1 sse4.2 popcnt cx16",
    );
    android_x86.long_double_bits = 128;
    let android_a64 = a64(row(ISA_A64, CC_AAPCS, OBJ_ELF, OS_ANDROID, "aarch64-linux-android24", 7), "neon");
    let mut win_x86 = x86(row(ISA_X86, CC_WIN64, OBJ_COFF, OS_WINDOWS, "x86_64-w64-mingw32", 8), "sse2");
    win_x86.long_bytes = 4;
    win_x86.red_zone = 0;
    let mut win_a64 = a64(row(ISA_A64, CC_WIN_A64, OBJ_COFF, OS_WINDOWS, "aarch64-w64-mingw32", 9), "neon");
    win_a64.long_bytes = 4;
    win_a64.long_double_bits = 64;
    let mut wasm = row(ISA_WASM, CC_WASM, OBJ_WASM, OS_WASI, "wasm32-wasip1", 10);
    wasm.long_bytes = 4;
    wasm.page_bytes = 65536;
    return [
        apple(
            x86(
                row(ISA_X86, CC_SYSV, OBJ_MACHO, OS_MACOS, "x86_64-apple-macos11.0", 0),
                "sse2 sse3 ssse3 cx16 lahf-sahf",
            ),
            "MacOSX",
        ),
        mac_a64,
        ios_x86,
        ios_a64,
        x86(row(ISA_X86, CC_SYSV, OBJ_ELF, OS_LINUX, "x86_64-unknown-linux-gnu", 4), "sse2"),
        linux_a64,
        android_x86,
        android_a64,
        win_x86,
        win_a64,
        wasm,
    ];
}

/// Every target, one row per (`Os`, `Isa`) pair the compiler builds for.
pub(package) const TARGETS: [Target; 11] = targets();

/// The index of the `TARGETS` row of operating system `os` and instruction set `isa` (`OSES` and
/// `ISAS` indexes), or -1 when the pair is no target.
pub(package) const fn find(os: i32, isa: i32) i32 {
    let t: []Target = TARGETS;
    for i in 0..t.len() {
        if t[i].os as i32 == os && t[i].isa as i32 == isa {
            return i as i32;
        }
    }
    return -1;
}

/// The `TARGETS` row of `os` and `isa`; none when the pair is no target.
pub(package) const fn target_of(os: i32, isa: i32) Option<Target> {
    let k = find(os, isa);
    if k < 0 {
        return Option::<Target>::None;
    }
    let t: []Target = TARGETS;
    return Option::<Target>::Some(t[k as usize]);
}

// An unknown instruction set (`--arch` absent where no host decides it): 64-bit, no features of its own.
const UNKNOWN_ISA: Isa = Isa {
    name: "",
    variant: "",
    ptr_bytes: 8,
    fn_features: true,
    levels: false,
    ext_flags: false,
    naked: true,
    return_address: true,
    mask_fold: false,
    merge_apart: false,
    vector_bytes: 0,
    mul_high: false,
    simd_backend: "",
    intrinsics: "",
};

/// Instruction set `isa` (an `ISAS` index, or -1 for an unknown one).
pub(package) const fn isa(isa: i32) Isa {
    if isa < 0 {
        return UNKNOWN_ISA;
    }
    let t: []Isa = ISAS;
    return t[isa as usize];
}

/// Operating system `os` (an `OSES` index).
pub(package) const fn os(os: i32) Os {
    let t: []Os = OSES;
    return t[os as usize];
}

/// The object format of operating system `os`: every target of one system shares it.
/// The calling convention of `(os, isa)`; the first one when the pair is no target.
pub(package) const fn callconv_of(os: i32, isa: i32) CallConv {
    let c: []CallConv = CALLCONVS;
    let i = find(os, isa);
    if i < 0 {
        return c[0];
    }
    let t: []Target = TARGETS;
    return c[t[i as usize].cc as usize];
}

pub(package) const fn obj_of(os: i32) ObjFormat {
    let t: []Target = TARGETS;
    let f: []ObjFormat = OBJFORMATS;
    for i in 0..t.len() {
        if t[i].os as i32 == os {
            return f[t[i].obj as usize];
        }
    }
    return f[OBJ_ELF as usize];
}

const fn os_words(variant: bool) [str<'static>; 6] {
    let t: []Os = OSES;
    let mut r: [str<'static>; 6] = [""; 6];
    for i in 0..t.len() {
        unsafe r[i] = if variant {
            t[i].variant;
        } else {
            t[i].name;
        };
    }
    return r;
}

const fn isa_words(variant: bool) [str<'static>; 3] {
    let t: []Isa = ISAS;
    let mut r: [str<'static>; 3] = [""; 3];
    for i in 0..t.len() {
        unsafe r[i] = if variant {
            t[i].variant;
        } else {
            t[i].name;
        };
    }
    return r;
}

const OS_NAMES: [str<'static>; 6] = os_words(false);
const OS_VARIANTS: [str<'static>; 6] = os_words(true);
const ISA_NAMES: [str<'static>; 3] = isa_words(false);
const ISA_VARIANTS: [str<'static>; 3] = isa_words(true);

/// The `@arch` names (`is_isa`) or the `@platform` names: a name's index is its bit in the attribute's
/// mask, and the index of its `std::target` variant.
pub(package) const fn axis_names(is_isa: bool) Slice<'static, str<'static>> {
    if is_isa {
        return ISA_NAMES;
    }
    return OS_NAMES;
}

/// The `std::target` enum variants of the `@arch` axis (`is_isa`) or the `@platform` axis, in
/// `axis_names` order.
pub(package) const fn axis_variants(is_isa: bool) Slice<'static, str<'static>> {
    if is_isa {
        return ISA_VARIANTS;
    }
    return OS_VARIANTS;
}

/// The index of the `@platform` name (`is_isa` false) or `@arch` name `name`, -1 for an unknown name.
pub(package) const fn axis_index(name: str, is_isa: bool) i32 {
    let ns = axis_names(is_isa);
    for i in 0..ns.len() {
        if ns[i] == name {
            return i as i32;
        }
    }
    return -1;
}

/// The names of one axis for a diagnostic: `a, b, or c`.
pub(package) fn axis_list(is_isa: bool) String {
    let ns = axis_names(is_isa);
    let n = ns.len();
    let mut s = String::new();
    for i in 0..n {
        if i != 0 {
            s.push_str(
                if n > 2 {
                    ", ";
                } else {
                    " ";
                },
            );
        }
        if i + 1 == n && n > 1 {
            s.push_str("or ");
        }
        s.push_str(ns[i]);
    }
    return s;
}

/// The CPU features every build for `os` and `isa` has, none when the pair is no target.
pub(package) const fn baseline(os: i32, isa: i32) cf::CpuFeatureSet {
    return switch target_of(os, isa) {
        Some(t) => t.features,
        None => NO_FEATURES,
    };
}

/// Whether every target of instruction set `isa` has feature `k` in its baseline.
pub(package) const fn baseline_everywhere(k: usize, isa: i32) bool {
    let t: []Target = TARGETS;
    for i in 0..t.len() {
        if t[i].isa as i32 == isa && !cf::has(t[i].features, k) {
            return false;
        }
    }
    return true;
}

/// The predefined C macros outside the implementation's namespace, which a strict `-std=cN` removes on
/// every target that defines them.
pub(package) const STRICT_UNDEFINED: [str<'static>; 5] = ["linux", "unix", "WIN32", "WIN64", "WINNT"];

/// The operating system the compiler runs on (an `OSES` index).
pub(package) const fn host_os() i32 {
    return PLATFORM as i32;
}

/// The instruction set the compiler runs on (an `ISAS` index).
pub(package) const fn host_isa() i32 {
    return ARCH as i32;
}
