// The std package checker (`tools/std_packages`) over small std trees: a clean tree passes, and each violation
// alone fails with its diagnostic: an upward import, an import of a platform ffi module, a platform extern "C"
// function under a gate, an import cycle across packages, an undeclared package and a manifest without a
// required key. The repository's own
// std is the gate's to check (ci/gate.sh).
import tests::cli_harness as cli;

// The rows: `os` and `io` (tier 3) import each other's packages without a cycle of modules.
const TOML: str = M"(# The rows of the test tree.
[ffi]
modules = ["string"]
functions = ["memcpy"]

[package.prelude]
tier = 0
targets = { macos = "full", ios = "full", linux = "full", android = "full", windows = "full", wasm = "full" }
capabilities = []
accelerations = []
allocator = "None."
thread_safety = "Pure."
blocking = "Never."
errors = "None."
c_functions = ["sc_*"]

[package.low]
tier = 1
targets = { macos = "full", ios = "full", linux = "full", android = "full", windows = "full", wasm = "reduced" } # a comment
limits = "No \"wasm\"."
capabilities = ["a | b"]
accelerations = [
    "x",
    "y",
]
allocator = "None."
thread_safety = "Pure."
blocking = "Never."
errors = "None."

[package.os]
tier = 3
targets = { macos = "full", ios = "full", linux = "full", android = "full", windows = "full", wasm = "unavailable" }
limits = "No wasm."
capabilities = ["processes"]
accelerations = []
allocator = "None."
thread_safety = "Pure."
blocking = "Blocks."
errors = "Results."
platform_ffi = ["sys"]

[package.io]
tier = 3
targets = { macos = "full", ios = "full", linux = "full", android = "full", windows = "full", wasm = "full" }
capabilities = []
accelerations = []
allocator = "None."
thread_safety = "Pure."
blocking = "Never."
errors = "None."
)";

// A prelude module: the text in comments and strings is no item, and an `@import` pin is the C symbol.
const CORE: str = M"(// import unistd;
/* extern "C" { fn getpid() i32; } /* nested */ */
const TEXT: str = "import unistd; extern \"C\" { fn getpid() i32; }";

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
    @import("sc_core_helper")
    fn helper() i32;
}
)";

// Character literals with quotes in them and a lifetime.
const LOW_A: str = M"(import std::core;
import string as cstring;

const QUOTE: u8 = b'\'';
const DOUBLE: char = '"';

fn id<'a>(s: str<'a>) str<'a> {
    return s;
}
)";

// The exempt module of `os`.
const OS_SYS: str = M"(import unistd;

extern "C" {
    fn getpid() i32;
}
)";

const OS_A: str = M"(import std::low::a;
import std::io::b;
)";

// A directory without an index imports every file in it.
const IO_B: str = M"(import std::os::sys;
import std::low;
)";

// The clean tree under `<p>/<name>/std`.
fn write_tree(p: &cli::Proj, name: str) {
    p.mkfile(format("{}/std/packages.toml", name).as_str(), TOML);
    p.mkfile(format("{}/std/core.spc", name).as_str(), CORE);
    p.mkfile(format("{}/std/low/a.spc", name).as_str(), LOW_A);
    p.mkfile(format("{}/std/os/sys.spc", name).as_str(), OS_SYS);
    p.mkfile(format("{}/std/os/a.spc", name).as_str(), OS_A);
    p.mkfile(format("{}/std/io/b.spc", name).as_str(), IO_B);
}

// The checker `exe` on `<p>/<name>/std`, with `args` first.
fn run(p: &cli::Proj, exe: &String, name: str, args: str) cli::CliResult {
    let dir = format("{}/{}", p.dir(), name);
    return cli::exe_env_in(exe.as_str(), dir.as_str(), "SC_LEAK_CHECK", "fatal", format("{} std", args).as_str());
}

// The clean tree with `text` written at `rel`: the checker exits with `exit` and prints `want`.
fn expect_case(p: &cli::Proj, exe: &String, name: str, rel: str, text: str, exit: i32, want: str) {
    write_tree(p, name);
    p.mkfile(format("{}/std/{}", name, rel).as_str(), text);
    let r = run(p, exe, name, "");
    if r.exit != exit {
        r.show();
    }
    assert(r.exit == exit, name);
    assert(r.out_shows(want), name);
}

@test(timeout = 300)
fn checker_cases() {
    let p = cli::proj_new();
    for f in ["build.toml", "main.spc", "files.spc", "scan.spc", "manifest.spc"] {
        let src = format("tools/std_packages/{}", f);
        assert(p.copyfile(format("tool/{}", f).as_str(), src.as_str()), "the checker's source copies");
    }
    let exe = format("{}/std-packages{}", p.dir(), unsafe str::from_cstr(cli::binext()));
    let tool = format("{}/tool", p.dir());
    let b = cli::superc_in(tool.as_str(), format("build -o \"{}\"", exe.as_str()).as_str());
    assert(b.ok(), "the checker builds");

    write_tree(&p, "clean");
    let c = run(&p, &exe, "clean", "");
    assert(c.ok(), "a clean tree passes");
    assert(c.out_shows("std-packages: 5 files in 4 packages, no violation"), "a clean tree passes");

    expect_case(
        &p,
        &exe,
        "upward",
        "low/up.spc",
        "import std::os::sys;\n",
        1,
        "std/low/up.spc:1: upward tier edge: std::low::up (package low, tier 1) imports std::os::sys (package os, tier 3)",
    );
    expect_case(
        &p,
        &exe,
        "ffi_import",
        "low/ffi.spc",
        "import std::core;\nimport unistd;\n",
        1,
        "std/low/ffi.spc:2: platform FFI outside std::platform: import of the ffi module 'unistd'",
    );
    expect_case(
        &p,
        &exe,
        "ffi_extern",
        "low/ext.spc",
        "@platform(linux)\nextern \"C\" \"unistd.h\" {\n    fn getpid() i32;\n}\n",
        1,
        "std/low/ext.spc:3: platform FFI outside std::platform: the extern \"C\" function 'getpid'",
    );
    expect_case(
        &p,
        &exe,
        "cycle",
        "io/b.spc",
        "import std::os::a;\n",
        1,
        "std/io/b.spc:1: cyclic tier edge: std::io::b (package io) imports std::os::a (package os), which imports it back",
    );
    expect_case(
        &p,
        &exe,
        "undeclared",
        "extra/x.spc",
        "const X: i32 = 1;\n",
        1,
        "std/extra/x.spc:1: undeclared package",
    );
    expect_case(
        &p,
        &exe,
        "manifest",
        "packages.toml",
        "[ffi]\nmodules = []\nfunctions = []\n[package.prelude]\ntier = 0\n",
        2,
        "std/packages.toml:4: [package.prelude] has no 'targets'",
    );
}
