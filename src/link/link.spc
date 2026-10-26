// The project's own linker: it links the native backend's objects with the system's shared libraries,
// taking the C compiler's link command as its input so a build has one link command either way. It
// serves a target once its format's linker exists; a command with a flag it does not know (a sanitizer,
// LTO, a linker option) stays with the C compiler until step 17 removes it.
import stdlib;
import link::macho as lm;
import link::elf as le;
import link::pe;
import link::wasm as lw;
import link::ar;
import target::table as tgt;
import target::native as nat;
import bindgen::ctarget as ct;

/// Whether a link may take the own linker: unless SC_LINK=cc, which keeps every link with the C compiler.
pub fn enabled() bool {
    return stdlib::get_env("SC_LINK").unwrap_or(String::new()).as_str() != "cc";
}

/// Archive objects `objs` into static library `out` for target `os`; LINKED, or FAILED with the reason in
/// `why`.
pub fn archive(os: i32, out: str, objs: &Vector<String>, why: &mut String) i32 {
    if !ar::archive(nat::obj_kind(os), out, objs, why) {
        return FAILED;
    }
    return LINKED;
}

/// Outcomes of `link_args`.
pub const LINKED: i32 = 1;
pub const NOT_SERVED: i32 = 0;
pub const FAILED: i32 = -1;

// What a C compiler's link command asks for.
struct Cmd {
    pub out: String,
    pub objs: Vector<String>,
    pub libs: Vector<String>,
    pub dirs: Vector<String>,
    pub fworks: Vector<String>,
    pub fdirs: Vector<String>,
    pub sysroot: String,
    pub shared: bool,
    pub install: String,
    pub strip: bool,
    pub jobs: u32,
    pub stack: u64, // the main thread's stack reserve (PE), 0: the default
    pub wasm_stack: u64, // wasm: the stack's size (`-z stack-size=`), 0: the default
    pub stack_first: bool, // wasm: the stack before the data
}

/// Link for target `(os, isa)` what the C compiler's link command `args` names (its objects, libraries
/// and output), leaving out the local symbols and the debug information when `strip`, with `jobs` workers
/// (1: no task pool; else the caller shuts the pool down after). LINKED;
/// NOT_SERVED when the target or an argument is outside what this linker does (`why` names it);
/// FAILED with the reason in `why`.
pub fn link_args(os: i32, isa: i32, args: &Vector<String>, strip: bool, jobs: u32, why: &mut String) i32 {
    let fmt = nat::own_linker(os, isa);
    if fmt == nat::LINK_NONE {
        why.push_str("no own linker for the target");
        return NOT_SERVED;
    }
    let mut c = Cmd {
        out: String::new(),
        objs: Vector::<String>::new(),
        libs: Vector::<String>::new(),
        dirs: Vector::<String>::new(),
        fworks: Vector::<String>::new(),
        fdirs: Vector::<String>::new(),
        sysroot: String::new(),
        shared: false,
        install: String::new(),
        strip: strip,
        jobs: jobs,
        stack: 0,
        wasm_stack: 0,
        stack_first: false,
    };
    let r = parse(args, &mut c, why);
    if r != LINKED {
        return r;
    }
    if fmt == nat::LINK_MACHO {
        return macho(os, isa, &mut c, why);
    }
    if fmt == nat::LINK_PE {
        return coff(&mut c, why);
    }
    if fmt == nat::LINK_WASM {
        return wasm(&mut c, why);
    }
    if c.stack != 0 || c.wasm_stack != 0 || c.stack_first {
        why.push_str("a stack size");
        return NOT_SERVED;
    }
    return elf(os, isa, &mut c, fmt == nat::LINK_ELF_A64, why);
}

fn parse(args: &Vector<String>, c: &mut Cmd, why: &mut String) i32 {
    let n = args.len();
    let mut i: usize = 0;
    // Each step consumes one argument, or a flag and its value.
    while i < n {
        let a = args[i].as_str();
        i += 1;
        let next = if i < n {
            args[i].as_str();
        } else {
            "";
        };
        if !a.starts_with("-") {
            if a.ends_with(".o") {
                c.objs.push(String::from_str(a));
            } else if a.ends_with(".a") || a.ends_with(".dylib") || a.ends_with(".tbd") || a.ends_with(".so") || a.ends_with(
                ".c",
            ) {
                why.format_into("input '{}'", a);
                return NOT_SERVED;
            }
            // Any other word is the C compiler's own command.
            continue;
        }
        if a == "-o" {
            c.out = String::from_str(next);
            i += 1;
        } else if a == "-isysroot" || a == "--sysroot" || a == "-target" || a == "-isystem" || a == "-include" || a == "-arch" {
            if a == "-isysroot" || a == "--sysroot" {
                c.sysroot = String::from_str(next);
            }
            i += 1;
        } else if a.starts_with("--sysroot=") {
            c.sysroot = String::from_str(a.slice(10, a.len()));
        } else if a == "-framework" {
            c.fworks.push(String::from_str(next));
            i += 1;
        } else if a.starts_with("-l") && a.len() > 2 {
            c.libs.push(String::from_str(a.slice(2, a.len())));
        } else if a == "-L" || a == "-F" {
            if a == "-L" {
                c.dirs.push(String::from_str(next));
            } else {
                c.fdirs.push(String::from_str(next));
            }
            i += 1;
        } else if a.starts_with("-L") {
            c.dirs.push(String::from_str(a.slice(2, a.len())));
        } else if a.starts_with("-F") {
            c.fdirs.push(String::from_str(a.slice(2, a.len())));
        } else if a == "-shared" || a == "-dynamiclib" {
            c.shared = true;
        } else if a.starts_with("-Wl,-install_name,") {
            c.install = String::from_str(a.slice(18, a.len()));
        } else if a.starts_with("-Wl,-soname,") {
            c.install = String::from_str(a.slice(12, a.len()));
        } else if a.starts_with("-Wl,--stack,") {
            let v = a.slice(12, a.len());
            for k in 0..v.len() {
                let d = v.byte_at(k);
                if d < b'0' || d > b'9' {
                    why.format_into("flag '{}'", a);
                    return NOT_SERVED;
                }
                c.stack = c.stack * 10 + (d - b'0') as u64;
            }
        } else if a.starts_with("-Wl,-z,stack-size=") {
            let v = a.slice(18, a.len());
            for k in 0..v.len() {
                let d = v.byte_at(k);
                if d < b'0' || d > b'9' {
                    why.format_into("flag '{}'", a);
                    return NOT_SERVED;
                }
                c.wasm_stack = c.wasm_stack * 10 + (d - b'0') as u64;
            }
        } else if a == "-Wl,--stack-first" {
            c.stack_first = true;
        } else if a == "-nostdlib" || a == "--target=wasm32-wasip1" {
            // wasm's: no C library or start files (`std::rt::libc` is both).
        } else if a == "-Wl,--strip-all" {
            c.strip = true;
        } else if a == "-Wl,-reproducible" {
            // Always: the output is a function of the inputs.
        } else if a.starts_with("-Wl,-O") && a.len() == 7 && a.byte_at(6) >= b'0' && a.byte_at(6) <= b'9' {
            // lld's string tail merging: an output size level only.
        } else if compile_only(a) {
            // A compile flag the link command carries along.
        } else {
            why.format_into("flag '{}'", a);
            return NOT_SERVED;
        }
    }
    if c.out.len() == 0 || c.objs.len() == 0 {
        why.push_str("no output or no object");
        return NOT_SERVED;
    }
    return LINKED;
}

fn macho(os: i32, isa: i32, c: &mut Cmd, why: &mut String) i32 {
    let mut o = lm::Opts {
        out: replace(&mut c.out, String::new()),
        kind: if c.shared {
            lm::K_DYLIB;
        } else {
            lm::K_EXE;
        },
        install: replace(&mut c.install, String::new()),
        objs: replace(&mut c.objs, Vector::<String>::new()),
        libs: replace(&mut c.libs, Vector::<String>::new()),
        dirs: replace(&mut c.dirs, Vector::<String>::new()),
        fworks: replace(&mut c.fworks, Vector::<String>::new()),
        fdirs: replace(&mut c.fdirs, Vector::<String>::new()),
        sdk: replace(&mut c.sysroot, String::new()),
        strip: c.strip,
        jobs: c.jobs,
    };
    if o.kind == lm::K_DYLIB && o.install.len() == 0 {
        o.install = o.out.clone();
    }
    if o.sdk.len() == 0 {
        let t = tgt::target_of(os, isa).unwrap();
        if !ct::apple_sdk(&t, &mut o.sdk) {
            why.push_str("no macOS SDK (set SDKROOT or DEVELOPER_DIR)");
            return FAILED;
        }
    }
    // A static library is a third-party archive (step 15): the C compiler's linker reads it.
    for i in 0..o.libs.len() {
        let mut path = String::new();
        if lm::find_lib(&o, o.libs[i].as_str(), &mut path) == lm::LIB_ARCHIVE {
            why.format_into("static library '{}'", path.as_str());
            return NOT_SERVED;
        }
    }
    if !lm::link(&o, why) {
        return FAILED;
    }
    return LINKED;
}

fn elf(os: i32, isa: i32, c: &mut Cmd, a64: bool, why: &mut String) i32 {
    // A cross link finds the target's C library only under the sysroot its command names.
    if c.sysroot.len() == 0 && (os != tgt::host_os() || isa != tgt::host_isa()) {
        why.push_str("a cross link without a sysroot");
        return NOT_SERVED;
    }
    // A shared library's name: the one its command gives it, else its file's.
    let mut soname = replace(&mut c.install, String::new());
    if c.shared && soname.len() == 0 {
        let p = c.out.as_str();
        let mut i = p.len();
        while i > 0 && p.byte_at(i - 1) != b'/' {
            i -= 1;
        }
        soname.push_str(p.slice(i, p.len()));
    }
    let o = le::Opts {
        out: replace(&mut c.out, String::new()),
        kind: if c.shared {
            le::K_SHARED;
        } else {
            le::K_EXE;
        },
        soname: soname,
        objs: replace(&mut c.objs, Vector::<String>::new()),
        libs: replace(&mut c.libs, Vector::<String>::new()),
        dirs: replace(&mut c.dirs, Vector::<String>::new()),
        sysroot: replace(&mut c.sysroot, String::new()),
        a64: a64,
        strip: c.strip,
    };
    for i in 0..o.libs.len() {
        let mut path = String::new();
        if le::find(&o, o.libs[i].as_str(), &mut path) == le::LIB_ARCHIVE {
            why.format_into("static library '{}'", path.as_str());
            return NOT_SERVED;
        }
    }
    if !le::link(&o, why) {
        return FAILED;
    }
    return LINKED;
}

// The C library's parts on wasm, which `std::rt::libc` is: a link that names them needs nothing more.
const WASM_OWN_LIBS: []str = ["c", "m", "pthread", "dl", "rt"];

fn wasm(c: &mut Cmd, why: &mut String) i32 {
    c.libs.retain(
        fn(l: &String) bool {
            for j in 0..WASM_OWN_LIBS.len() {
                if l.as_str() == WASM_OWN_LIBS[j] {
                    return false;
                }
            }
            return true;
        },
    );
    if c.shared || c.libs.len() != 0 {
        why.push_str(
            if c.shared {
                "a shared library";
            } else {
                "a library";
            },
        );
        return NOT_SERVED;
    }
    let o = lw::Opts {
        out: replace(&mut c.out, String::new()),
        objs: replace(&mut c.objs, Vector::<String>::new()),
        stack: c.wasm_stack,
        stack_first: c.stack_first,
        strip: c.strip,
    };
    if !lw::link(&o, why) {
        return FAILED;
    }
    return LINKED;
}

fn coff(c: &mut Cmd, why: &mut String) i32 {
    let o = pe::Opts {
        out: replace(&mut c.out, String::new()),
        shared: c.shared,
        objs: replace(&mut c.objs, Vector::<String>::new()),
        libs: replace(&mut c.libs, Vector::<String>::new()),
        dirs: replace(&mut c.dirs, Vector::<String>::new()),
        strip: c.strip,
        stack: c.stack,
    };
    // The system's DLLs: on a Windows host, or in a directory the command names.
    if !pe::has_dlls(&o, why) {
        return NOT_SERVED;
    }
    if !pe::link(&o, why) {
        return FAILED;
    }
    return LINKED;
}

// Whether `a` is a flag only a C compile reads: the language, warnings, code generation, defines and
// include paths, the target's minimum OS version and CPU.
fn compile_only(a: str) bool {
    if a.starts_with("-Wl,") || a.starts_with("-fsanitize") || a.starts_with("-fprofile") || a.starts_with("-fcoverage") || a.starts_with(
        "-flto",
    ) || a.starts_with("-fuse-ld") {
        return false;
    }
    return a.starts_with("-O") || a.starts_with("-g") || a.starts_with("-std=") || a.starts_with("-D") || a.starts_with(
        "-U",
    ) || a.starts_with("-I") || a.starts_with("-W") || a.starts_with("-f") || a.starts_with("-m") || a == "-pthread" || a.starts_with(
        "--target=",
    ) || a == "-c" || a == "-pipe";
}
