// Direct unit tests of the cross-compilation helpers. A real `--target=ios/android/wasm` build needs
// the target SDK (not present or stable in every lane), but these functions are pure string/record
// builders, so calling them directly covers the SDK-cc selection, the NDK host tag, the per-target
// SDK flags, the library-artifact naming, and the pointer-width target record on every platform.
import driver::util as util;
import driver::taskctl as tctl;
import driver::tuc as tuc;
import emit::mangle as mbe;
import module::loader as loader;
import build_system::build as bsys;
import ir::layout as lay;
import ir::cpu_features as cf;
import driver_shim as shim;
import tests::cli_harness as cli;

@test
fn sdk_cc_selects_a_toolchain_per_sdk() {
    // iOS: xcrun-selected clang.
    let mut ios = String::new();
    util::sdk_cc(1, &mut ios);
    assert(ios.as_str().contains("xcrun"), "ios uses xcrun clang");
    assert(ios.as_str().contains("iphoneos"), "ios names the iphoneos sdk");
    // Android: the NDK prebuilt clang, located from ANDROID_NDK_HOME (covers the host-tag path).
    let _env1 = cli::set_env("ANDROID_NDK_HOME", "/opt/ndk");
    let mut andr = String::new();
    util::sdk_cc(2, &mut andr);
    assert(andr.as_str().contains("/opt/ndk"), "android roots at the NDK home");
    assert(andr.as_str().contains("prebuilt/"), "android uses the prebuilt toolchain");
    assert(andr.as_str().contains("bin/clang"), "android ends at clang");
    // Wasm: wasi-sdk clang when WASI_SDK_PATH is set, else plain clang.
    let _env2 = cli::set_env("WASI_SDK_PATH", "/opt/wasi");
    let mut w = String::new();
    util::sdk_cc(3, &mut w);
    assert(w.as_str().contains("/opt/wasi"), "wasm uses the wasi-sdk clang");
}

@test
fn sdk_flags_carry_the_triple() {
    // Each SDK contributes its own leading flags; the iOS triple carries the TLS-capable floor.
    let mut ios = String::new();
    util::push_sdk_flags(&mut ios, 4, 1, 1, cf::baseline(4, 1));
    assert(ios.as_str().contains("-target"), "ios sdk flags include a target triple");
    let mut wasm = String::new();
    util::push_sdk_flags(&mut wasm, 3, 3, 2, cf::baseline(3, 2));
    assert(!wasm.as_str().contains("-msimd128"), "wasm32 has no feature by default");
    // The features' flags follow the triple, in table order.
    let mut rel = String::new();
    util::push_sdk_flags(&mut rel, 3, 3, 2, cf::close(cf::with(cf::baseline(3, 2), cf::F_RELAXED_SIMD)));
    assert(rel.as_str().ends_with(" -msimd128 -mrelaxed-simd"), "relaxed-simd implies simd128");
}

@test
fn wasi_sysroot_is_one_unquoted_argument() {
    // The flag string is split on whitespace into argv, so a quote would reach the compiler verbatim.
    let _env3 = cli::set_env("WASI_SDK_PATH", "/opt/wasi");
    let mut fl = String::new();
    util::push_sdk_flags(&mut fl, 3, 3, 2, cf::baseline(3, 2));
    let mut args = Vector::<String>::new();
    util::split_args(&mut args, fl.as_str());
    let mut found = false;
    for i in 0..args.len() {
        assert(!args[i].as_str().contains("\""), "no argument carries a quote");
        found = found || args[i].as_str() == "--sysroot=/opt/wasi/share/wasi-sysroot";
    }
    assert(found, "the sysroot is one argument");
    assert(fl.as_str().contains("-target wasm32-wasip1 "), "the wasi triple is the current wasip1 one");
}

// wasm-ld's default 64 KiB stack is far below a native main thread's: every wasm link asks for 8 MiB,
// placed first so an overflow traps.
@test
fn wasm_links_with_the_native_stack_size() {
    let mut ld = String::new();
    util::push_sdk_libs(&mut ld, 3);
    assert(ld.as_str().contains(" -Wl,-z,stack-size=8388608 "), "an 8 MiB stack");
    assert(ld.as_str().contains(" -Wl,--stack-first"), "the stack below static data");
}

@test
fn build_mem_budget_suffixes() {
    let _env4 = cli::set_env("SC_BUILD_MEM_BUDGET", "64M");
    assert_eq(tctl::budget_from_env(), 64u64 << 20);
    let _env5 = cli::set_env("SC_BUILD_MEM_BUDGET", "2g");
    assert_eq(tctl::budget_from_env(), 2u64 << 30);
    let _env6 = cli::set_env("SC_BUILD_MEM_BUDGET", "4096");
    assert_eq(tctl::budget_from_env(), 4096u64);
}

// The one size parser behind SC_BUILD_MEM_BUDGET and --const-eval-memory: a value past u64 is
// rejected, never wrapped.
@test
fn size_parser_rejects_overflow() {
    assert_eq(tctl::parse_size("16m").unwrap(), 16u64 << 20);
    assert_eq(tctl::parse_size("18446744073709551615").unwrap(), 0xFFFFFFFFFFFFFFFFu64);
    assert(tctl::parse_size("18446744073709551616").is_none(), "one past u64");
    assert(tctl::parse_size("99999999999G").is_none(), "the suffix overflows");
    assert(tctl::parse_size("17179869184G").is_none(), "exactly 2^64 bytes");
    assert(tctl::parse_size("-1").is_none(), "a sign");
    assert(tctl::parse_size(" 5").is_none(), "a space");
    assert(tctl::parse_size("5KB").is_none(), "a two-letter suffix");
    assert(tctl::parse_size("").is_none(), "empty");
}

@test
fn library_artifact_names_per_platform() {
    // Static is lib<name>.a everywhere; shared is platform-shaped (targets: 0 windows, 1 macos,
    // 2 linux, 4 ios, 5 android).
    assert(bsys::lib_file("mylib", false, 1).as_str() == "libmylib.a", "static on macos");
    assert(bsys::lib_file("mylib", false, 0).as_str() == "libmylib.a", "static on windows");
    assert(bsys::lib_file("mylib", true, 1).as_str() == "libmylib.dylib", "shared on macos");
    assert(bsys::lib_file("mylib", true, 4).as_str() == "libmylib.dylib", "shared on ios");
    assert(bsys::lib_file("mylib", true, 2).as_str() == "libmylib.so", "shared on linux");
    assert(bsys::lib_file("mylib", true, 5).as_str() == "libmylib.so", "shared on android");
    assert(bsys::lib_file("mylib", true, 0).as_str() == "mylib.dll", "shared on windows");
}

// A per-TU cache event whose type-table ref lies outside its section's table rejects the section instead
// of replaying with no type; an absent ref (all ones) is valid.
@test
fn tu_cache_event_ref_outside_the_table_rejects() {
    let p = loader::package_from_source("", "std", unsafe shim::sc_host_platform());
    let tab = Vector::<tuc::TtEnt>::new();
    let mut ids = Map::<u64, u64>::new();
    let mut ev = mbe::RecEv::blank(mbe::RK_STAT);
    ev.d = 0;
    assert(!tuc::ev_patch(&p, &tab, &mut ids, &mut ev), "a ref past the table is a mismatch");
    ev.d = 0xFFFFFFFFu32;
    assert(tuc::ev_patch(&p, &tab, &mut ids, &mut ev), "an absent ref patches to no type");
}
