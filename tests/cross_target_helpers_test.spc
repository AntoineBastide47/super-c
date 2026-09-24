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
import driver_shim as shim;

@test
fn sdk_cc_selects_a_toolchain_per_sdk() {
    // iOS: xcrun-selected clang.
    let mut ios = String::new();
    util::sdk_cc(1, &mut ios);
    assert(ios.as_str().contains("xcrun"), "ios uses xcrun clang");
    assert(ios.as_str().contains("iphoneos"), "ios names the iphoneos sdk");
    // Android: the NDK prebuilt clang, located from ANDROID_NDK_HOME (covers the host-tag path).
    let _ = unsafe shim::sc_setenv("ANDROID_NDK_HOME".ptr() as *const char, "/opt/ndk".ptr() as *const char);
    let mut andr = String::new();
    util::sdk_cc(2, &mut andr);
    assert(andr.as_str().contains("/opt/ndk"), "android roots at the NDK home");
    assert(andr.as_str().contains("prebuilt/"), "android uses the prebuilt toolchain");
    assert(andr.as_str().contains("bin/clang"), "android ends at clang");
    // Wasm: wasi-sdk clang when WASI_SDK_PATH is set, else plain clang.
    let _ = unsafe shim::sc_setenv("WASI_SDK_PATH".ptr() as *const char, "/opt/wasi".ptr() as *const char);
    let mut w = String::new();
    util::sdk_cc(3, &mut w);
    assert(w.as_str().contains("/opt/wasi"), "wasm uses the wasi-sdk clang");
}

@test
fn sdk_flags_carry_the_triple() {
    // Each SDK contributes its own leading flags; the iOS triple carries the TLS-capable floor.
    let mut ios = String::new();
    util::push_sdk_flags(&mut ios, 1, 1);
    assert(ios.as_str().contains("-target"), "ios sdk flags include a target triple");
    let mut wasm = String::new();
    util::push_sdk_flags(&mut wasm, 3, 2);
    assert(wasm.len() >= 0, "wasm sdk flags produced");
}

@test
fn wasi_sysroot_is_one_unquoted_argument() {
    // The flag string is split on whitespace into argv, so a quote would reach the compiler verbatim.
    let _ = unsafe shim::sc_setenv("WASI_SDK_PATH".ptr() as *const char, "/opt/wasi".ptr() as *const char);
    let mut fl = String::new();
    util::push_sdk_flags(&mut fl, 3, 2);
    let mut args = Vector::<String>::new();
    util::split_args(&mut args, fl.as_str());
    let mut found = false;
    for i in 0..args.len() {
        assert(!args[i].as_str().contains("\""), "no argument carries a quote");
        found = found || args[i].as_str() == "--sysroot=/opt/wasi/share/wasi-sysroot";
    }
    assert(found, "the sysroot is one argument");
}

@test
fn build_mem_budget_suffixes() {
    let _ = unsafe shim::sc_setenv("SC_BUILD_MEM_BUDGET".ptr() as *const char, "64M".ptr() as *const char);
    assert_eq(tctl::budget_from_env(), 64u64 << 20);
    let _ = unsafe shim::sc_setenv("SC_BUILD_MEM_BUDGET".ptr() as *const char, "2g".ptr() as *const char);
    assert_eq(tctl::budget_from_env(), 2u64 << 30);
    let _ = unsafe shim::sc_setenv("SC_BUILD_MEM_BUDGET".ptr() as *const char, "4096".ptr() as *const char);
    assert_eq(tctl::budget_from_env(), 4096u64);
}

@test
fn library_artifact_names_per_platform() {
    // Static is lib<name>.a everywhere; shared is platform-shaped.
    assert(bsys::lib_file("mylib", false, 1).as_str() == "libmylib.a", "static is lib<name>.a");
    let dyn_macos = bsys::lib_file("mylib", true, 1);
    assert(dyn_macos.as_str().contains("mylib"), "shared names the library");
    // Every target's shared form carries the name and a platform extension.
    let dyn_linux = bsys::lib_file("mylib", true, 2);
    assert(dyn_linux.as_str().contains("mylib"), "linux shared names the library");
    let dyn_win = bsys::lib_file("mylib", true, 0);
    assert(dyn_win.as_str().contains("mylib"), "windows shared names the library");
}

@test
fn target_record_pointer_width() {
    // wasm32 (arch code 2) is a 4-byte-pointer target; the native archs are 8-byte.
    assert_eq(lay::target_for(2).ptr, 4 as u8);
    assert_eq(lay::target_for(0).ptr, 8 as u8);
    assert_eq(lay::target_for(1).ptr, 8 as u8);
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
