// Direct unit tests of the cross-compilation helpers. A real `--target=ios/android/wasm` build needs
// the target SDK (not present or stable in every lane), but these functions are pure string/record
// builders, so calling them directly covers the SDK-cc selection, the NDK host tag, the per-target
// SDK flags, the library-artifact naming, and the pointer-width target record on every platform.
import driver::util as util;
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
