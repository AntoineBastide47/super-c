// The link step: the link record's name, the archiver of a static library, the response file of a long
// Windows command line (pure builders, called directly on every host), and the strip and spawn paths
// of a real link.
import stdlib;
import build_system::build as bsys;
import driver_shim as shim;
import tests::cli_harness as cli;

@test
fn link_record_names_fit_and_differ() {
    let mut deep = String::new();
    for _ in 0..100 {
        deep.push_str("dir/");
    }
    deep.push_str("app");
    let rec = bsys::link_record("out", deep.as_str());
    assert(rec.as_str().starts_with("out/__link-"), "the record lies in the out-dir");
    assert(rec.len() - 4 < 255, "a 400-byte path gives a name under NAME_MAX");
    let a = bsys::link_record("out", "a/b_c");
    let b = bsys::link_record("out", "a_b/c");
    assert(a.as_str() != b.as_str(), "paths that flatten alike have their own records");
    assert(a.as_str() == bsys::link_record("out", "a/b_c").as_str(), "one path has one record");
}

@test
fn a_cross_static_library_uses_the_target_archiver() {
    // wasm and Android are never the host.
    assert(bsys::archiver("/opt/wasi/bin/clang", 3).as_str() == "/opt/wasi/bin/llvm-ar", "the wasi-sdk's llvm-ar");
    assert(
        bsys::archiver("/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/clang", 5).as_str() == "/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar",
        "the NDK's llvm-ar",
    );
    assert(bsys::archiver("clang -target wasm32", 3).as_str() == "llvm-ar", "a clang from PATH: llvm-ar from PATH");
    let foreign = if PLATFORM == Platform::Windows {
        2;
    } else {
        0;
    };
    assert(
        bsys::archiver("/opt/x/bin/x86_64-w64-mingw32-gcc-posix", foreign).as_str() == "/opt/x/bin/x86_64-w64-mingw32-ar",
        "a cross gcc's own ar",
    );
    let host = unsafe shim::sc_host_platform();
    assert(bsys::archiver("/opt/x/bin/clang", host).as_str() == "ar", "the host's format: the host ar");
    if host == 1 {
        assert(bsys::archiver("xcrun --sdk iphoneos clang", 4).as_str() == "ar", "iOS objects are Mach-O");
    }
}

@test
fn a_long_command_line_moves_its_objects_into_a_response_file() {
    let p = cli::proj_new();
    let rsp = format("{}/link.rsp", p.dir());
    let mut args = Vector::<String>::new();
    let words: [str; 6] = ["gcc", "-o", "app.tmp", "obj\\a b.o", "obj/c.o", "-lm"];
    for w in words {
        args.push(String::from_str(w));
    }
    assert_eq(bsys::fit_cmdline(&mut args, 3, 2, rsp.as_str(), 1000), 0);
    assert(args.len() == 6, "a line that fits stays as it is");
    assert(cli::read_text(rsp.as_str()).len() == 0, "and writes no response file");
    assert_eq(bsys::fit_cmdline(&mut args, 3, 2, rsp.as_str(), 40), 1);
    assert(args.len() == 5, "the objects leave the line");
    assert(args[2].as_str() == "app.tmp", "the arguments before the objects stay");
    assert(args[4].as_str() == "-lm", "and so do the ones after them");
    assert(args[3].as_str() == format("@{}", rsp.as_str()).as_str(), "the response file takes the objects' place");
    assert(
        cli::read_text(rsp.as_str()).as_str() == "\"obj/a b.o\"\n\"obj/c.o\"\n",
        "one quoted object per line, with forward slashes",
    );
    let bad = format("{}/missing/link.rsp", p.dir());
    assert_eq(bsys::fit_cmdline(&mut args, 0, 1, bad.as_str(), 1), -1);
}

// A stripped macOS binary runs the host `strip` on the linked temp (the other targets strip at link):
// a failed strip installs nothing and records no link, so the next build links and strips again. Stubs
// stand for the C compiler (it writes empty outputs) and `strip`.
@test
fn a_failed_strip_installs_nothing() {
    if PLATFORM != Platform::MacOS {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n\n[profile.debug]\nstrip = true\n");
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    p.mkfile(
        "cc.sh",
        "#!/bin/sh\no=\"\"; prev=\"\"\nfor a in \"$@\"; do [ \"$prev\" = -o ] && o=\"$a\"; prev=\"$a\"; done\n[ -n \"$o\" ] && : > \"$o\"\nexit 0\n",
    );
    p.mkfile("bin/strip", "#!/bin/sh\nexit 3\n");
    let root = p.dir();
    let mut cmd = String::new();
    cmd.format_into("chmod +x \"{}/cc.sh\" \"{}/bin/strip\"", root, root);
    assert(cli::run_quiet(cmd.cstr()) == 0, "chmod");
    let path = stdlib::get_env("PATH").unwrap_or(String::new());
    let _path = cli::set_env("PATH", format("{}/bin:{}", root, path.as_str()).as_str());
    let build = format("build --cc={}/cc.sh", root);
    let r = cli::superc_env_in(root, "SC_NO_CACHE", "1", build.as_str());
    assert(!r.ok() && r.out_has("strip failed (exit 3)"), "the failed strip fails the build");
    let mut bin = format("{}/build/debug/app", root);
    assert(unsafe shim::sc_mtime(bin.cstr()) == 0, "nothing is installed");
    let mut rec = bsys::link_record(format("{}/build", root).as_str(), "build/debug/app");
    rec.push_str(".cmd");
    assert(unsafe shim::sc_mtime(rec.cstr()) == 0, "no link is recorded");
    p.mkfile("bin/strip", "#!/bin/sh\nexit 0\n");
    let r2 = cli::superc_env_in(root, "SC_NO_CACHE", "1", build.as_str());
    assert(r2.ok(), "the next build links and strips");
    assert(unsafe shim::sc_mtime(bin.cstr()) != 0, "and installs the binary");
    assert(unsafe shim::sc_mtime(rec.cstr()) != 0, "and records the link");
}

// The compiles and the link start the compiler PATH names by its path; a PATH match that cannot start
// (a file without the execute bit) falls back to the search, which skips it.
@test
fn a_compiler_path_match_that_cannot_start_falls_back_to_the_search() {
    if cli::on_wasm() || cli::on_windows() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile("main.spc", "fn main() i32 {\n    return 5;\n}\n");
    p.mkfile("shadow/cc", "not a program\n");
    let root = p.dir();
    let path = stdlib::get_env("PATH").unwrap_or(String::new());
    let _path = cli::set_env("PATH", format("{}/shadow:{}", root, path.as_str()).as_str());
    assert_eq(cli::superc_in(root, "run --cc=cc").exit, 5);
}
