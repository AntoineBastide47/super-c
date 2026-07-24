// The self-hosted super-c driver: parse args, load the package, run the global phases
// (resolve all -> type-check all -> flush deferred static_asserts -> propagate instances -> emit all),
// writing a `<root>/build/` tree (super_rt.h + one .c/.h per module). Ports src/main.c.
import stdio;
import stdlib;
import string as cstring;
import lexer::lexer as lex;
import ast::ast as *;
import ast::parser as par;
import fmt::builder as fbld;
import driver_shim as shim;
import module::loader as loader;
import resolver::resolver as resolver;
import typechecker::typechecker as tc;
import consteval::consteval as ce;
import codegen::codegen as cg;
import utils::errors as diag;
import driver::util as *;
import driver::extc as *;
import driver::test as *;
import driver::emit as *;
import build_system::manifest as bman;
import build_system::build as bsys;
import lsp::server as lsp_srv;

fn run_file(
    path: str,
    std_dir: *const char,
    ce_steps: u32,
    ce_mem: u64,
    topts: *const TestOpts,
    out_bin: str,
    target: i32,
    bootstrap_tags: bool,
    lint: bool,
) i32 {
    let mut p = loader::package_load(path, std_dir, bootstrap_tags);
    let mut rc: i32 = 1;
    if p.ok {
        let mut ceval = ce::ConstEval::new(&mut p, ce_steps, ce_mem);
        p.ceval = &mut ceval;
        rc = run_package(&mut p, topts, out_bin, target, lint);
    }
    return rc;
}

// "1024", "64K", "16M", "1G" -> bytes; 0 on malformed input.
fn parse_size(s: *const char) u64 {
    let mut endp: *mut char = null;
    let v = unsafe stdlib::strtoul(s, &mut endp, 10);
    if endp as usize == s as usize || v == 0 {
        return 0;
    }
    let mut mul: u64 = 1;
    let mut e = endp;
    let c = unsafe *endp;
    if c == 'K' as char || c == 'k' as char {
        mul = 1024;
        e = unsafe (endp + 1);
    } else if c == 'M' as char || c == 'm' as char {
        mul = (1024 * 1024) as u64;
        e = unsafe (endp + 1);
    } else if c == 'G' as char || c == 'g' as char {
        mul = (1024 * 1024 * 1024) as u64;
        e = unsafe (endp + 1);
    }
    if unsafe *e == 0 as char {
        return v * mul;
    }
    return 0;
}

// The std/ directory next to the running binary ("<exe dir>/std"), so the prelude is found regardless of cwd.
fn exe_std_dir(argv0: *const char) *mut char {
    let mut buf = PathBuf {};
    let mut path = argv0;
    if unsafe shim::sc_exe_path(&mut buf[0], 4096) == 0 {
        path = &buf[0];
    }
    // Last path separator, '/' or '\\' (Windows), whichever occurs later -- branch-free, no platform detection.
    let s1 = unsafe cstring::strrchr(path, '/');
    let s2 = unsafe cstring::strrchr(path, '\\');
    let slash = if s2 as usize > s1 as usize {
        s2;
    } else {
        s1;
    };
    let dirlen = if slash != null {
        slash as usize - path as usize;
    } else {
        1 as usize;
    };
    let out = (unsafe stdlib::malloc(dirlen + 5)) as *mut char;
    if out == null {
        return null;
    }
    if slash != null {
        unsafe cstring::memcpy(out, path, dirlen);
    } else {
        unsafe out[0] = '.' as char;
    }
    unsafe cstring::memcpy(out + dirlen, "/std".ptr(), 4);
    unsafe out[dirlen + 4] = 0 as char;
    return out;
}

fn read_stdin() Option<String> {
    let mut s = String::new();
    let cap: usize = 65536;
    let buf = (unsafe stdlib::malloc(cap)) as *mut u8;
    if buf == null {
        return Option::<String>::None;
    }
    let sin = stdio::stdin();
    loop {
        let n = unsafe stdio::fread(buf, 1, cap, sin);
        if n > 0 {
            s.push_bytes(buf, n);
        }
        if n < cap {
            break;
        }
    }
    unsafe stdlib::free(buf);
    return Option::<String>::Some(s);
}

// Byte-lexicographic name order with a length tiebreak: deterministic directory walks.
const fn fmt_name_cmp(a: &String, b: &String) i32 {
    let la = a.len();
    let lb = b.len();
    let m = if la < lb {
        la;
    } else {
        lb;
    };
    let c = unsafe cstring::memcmp(a.as_str().ptr(), b.as_str().ptr(), m);
    if c != 0 {
        return c;
    }
    return la as i32 - lb as i32;
}

// Recursively format every .spc under `dir` (sorted; dot-entries skipped). Returns 1 if any file
// failed or (--check) needs formatting, else 0.
fn fmt_dir(dir: str, write: bool, check: bool) i32 {
    let mut d = String::from_str(dir);
    let dh = unsafe shim::sc_opendir(d.cstr());
    if dh == null {
        eprintln("fmt: cannot read directory '{}'", dir);
        return 1;
    }
    let mut names = Vector::<String>::new();
    loop {
        let e = unsafe shim::sc_readdir(dh);
        if e == null {
            break;
        }
        let nm = unsafe shim::sc_dirent_name(e);
        if unsafe nm[0] == '.' as char {
            continue;
        } // ".", "..", hidden entries
        names.push(String::from_cstr(nm));
    }
    unsafe shim::sc_closedir(dh);
    names.sort_by(fmt_name_cmp);
    let mut rc = 0;
    for i in 0..names.len() {
        let mut p = String::from_str(dir);
        p.push_byte(b'/');
        p.push_string(names.at(i));
        let isdir = unsafe shim::sc_stat_isdir(p.cstr());
        if isdir == 1 {
            if fmt_dir(p.as_str(), write, check) != 0 {
                rc = 1;
            }
        } else if names.at(i).as_str().ends_with(".spc") {
            if fmt_one(p.as_str(), false, write, check) != 0 {
                rc = 1;
            }
        }
    }
    return rc;
}

// `super-c lint <path> [<path2> ...]`: load each path as its own root (its import closure + prelude),
// resolve + typecheck with lints on for that root module, and print warnings. Lints files that are not
// part of any binary's import closure. A directory recurses over its .spc files.
const fn lint_fix_cmp(a: &diag::LintFix, b: &diag::LintFix) i32 {
    if a.start < b.start {
        return -1;
    }
    if a.start > b.start {
        return 1;
    }
    return 0;
}

// Apply machine fixes ascending: kind 0 deletes [start, end), kind 1 inserts '_' before start,
// kind 2 inserts 'const ' before start. An overlapping fix is skipped -- the next `--fix` re-lint
// pass records it against the patched source.
fn apply_lint_fixes(src: str, fixes: &mut Vector<diag::LintFix>) String {
    fixes.sort_by(lint_fix_cmp);
    let mut out = String::new();
    out.reserve(src.len() + fixes.len());
    let mut pos: usize = 0;
    for i in 0..fixes.len() {
        let f = fixes[i];
        if f.start as usize < pos {
            continue;
        }
        out.push_str(src.slice(pos, f.start as usize));
        if f.kind == 1 {
            out.push_byte(b'_');
            pos = f.start as usize;
        } else if f.kind == 2 {
            out.push_str("const ");
            pos = f.start as usize;
        } else {
            pos = f.end as usize;
        }
    }
    out.push_str(src.slice(pos, src.len()));
    return out;
}

// Convention fallback for rooted loads: when a src/ directory exists (manifest layout), it serves
// as the secondary import root so tests/ and bench/ files linted from the project root resolve
// their compiler-module imports.
fn lint_alt() str<'static> {
    if unsafe shim::sc_stat_isdir("src".ptr() as *const char) == 1 {
        return "src";
    }
    return "";
}

fn lint_one(path: str, root: str, std_dir: *const char, ce_steps: u32, ce_mem: u64, target: i32, fix: bool, sc: bool) i32 {
    // A std/ffi file must keep its prelude identity (module path, builtin seeding, load order):
    // loading it as a root would invent errors. Load an empty root -- the prelude comes along as
    // always -- and if the requested file IS one of those modules, lint it in place.
    // `--fix`: quiet fixpoint loop (re-lint after each write, capped) that REJECTS -- writes nothing --
    // if the package has any error; a final plain pass prints what remains and sets the exit code.
    let mut pass = 0;
    loop {
        let mut pathc = String::from_str(path);
        let mut p = loader::package_from_source("".ptr() as *const char, 0, std_dir);
        let mut lint_mod = p.modules.len(); // the appended empty root; replaced below
        let mut found = false;
        for m in 0..p.modules.len() {
            if p.modules[m].has_ast && unsafe shim::sc_same_file(pathc.cstr(), p.modules[m].file.cstr()) == 1 {
                lint_mod = m;
                found = true;
                break;
            }
        }
        if !found {
            p = if root.len() != 0 {
                loader::package_load_rooted(path, root, lint_alt(), std_dir, false);
            } else {
                loader::package_load(path, std_dir, false);
            };
            lint_mod = 0;
        }
        if !p.ok {
            return 1;
        }
        let pkg = (&mut p) as *mut loader::Package;
        let mut ceval = ce::ConstEval::new(pkg, ce_steps, ce_mem);
        p.ceval = &mut ceval;
        if !fix {
            let rc = lint_package(&mut p, target, lint_mod, null, sc);
            return rc;
        }
        let mut fixes = Vector::<diag::LintFix>::new();
        lint_package(&mut p, target, lint_mod, &mut fixes, sc);
        let errors = !p.ok;
        let mut applied = false;
        let mut werr = false;
        if !errors && fixes.len() != 0 && pass < 8 {
            let out = apply_lint_fixes(p.modules[lint_mod].source.as_str(), &mut fixes);
            let f = stdio::fopen(p.modules[lint_mod].file.as_str(), "wb");
            if f == null {
                eprintln("lint: cannot write '{}'", path);
                werr = true;
            } else {
                unsafe stdio::fwrite(out.as_str().ptr(), 1, out.len(), f);
                unsafe stdio::fclose(f);
                applied = true;
            }
        }
        if errors || werr {
            return 1;
        }
        if !applied {
            break;
        }
        // Reformat before re-linting: canonicalization can unlock paren-guarded fixes.
        fmt_one(path, false, true, false);
        pass = pass + 1;
    }
    return lint_one(path, root, std_dir, ce_steps, ce_mem, target, false, sc);
}

fn lint_dir(dir: str, root: str, std_dir: *const char, ce_steps: u32, ce_mem: u64, target: i32, fix: bool, sc: bool) i32 {
    let mut d = String::from_str(dir);
    let dh = unsafe shim::sc_opendir(d.cstr());
    if dh == null {
        eprintln("lint: cannot read directory '{}'", dir);
        return 1;
    }
    let mut names = Vector::<String>::new();
    loop {
        let e = unsafe shim::sc_readdir(dh);
        if e == null {
            break;
        }
        let nm = unsafe shim::sc_dirent_name(e);
        if unsafe nm[0] == '.' as char {
            continue;
        }
        names.push(String::from_cstr(nm));
    }
    unsafe shim::sc_closedir(dh);
    names.sort_by(fmt_name_cmp);
    let mut rc = 0;
    for i in 0..names.len() {
        let mut p = String::from_str(dir);
        p.push_byte(b'/');
        p.push_string(names.at(i));
        let isdir = unsafe shim::sc_stat_isdir(p.cstr());
        if isdir == 1 {
            if lint_dir(p.as_str(), root, std_dir, ce_steps, ce_mem, target, fix, sc) != 0 {
                rc = 1;
            }
        } else if names.at(i).as_str().ends_with(".spc") {
            if lint_one(p.as_str(), root, std_dir, ce_steps, ce_mem, target, fix, sc) != 0 {
                rc = 1;
            }
        }
    }
    return rc;
}

fn run_lint(path: str, std_dir: *const char, ce_steps: u32, ce_mem: u64, target: i32, fix: bool, sc: bool) i32 {
    if unsafe shim::sc_stat_isdir(path.ptr() as *const char) == 1 {
        // every file under the directory resolves imports against the directory itself
        let droot = if lint_alt().len() != 0 {
            ".";
        } else {
            path;
        };
        return lint_dir(path, droot, std_dir, ce_steps, ce_mem, target, fix, sc);
    }
    let froot = if lint_alt().len() != 0 {
        ".";
    } else {
        "";
    };
    return lint_one(path, froot, std_dir, ce_steps, ce_mem, target, fix, sc);
}

// `super-c fmt`: canonical formatting. Rewrites files in place by default (only when they changed);
// --check writes nothing, prints the path, and exits 1 when a file is not already formatted. `-`
// reads stdin and formats to stdout. A directory recurses over its .spc files. A file the compiler
// cannot lex or parse is never rewritten: diagnostics are printed and the exit code is 1.
fn run_fmt(path: str, check: bool) i32 {
    let is_stdin = path == "-";
    if is_stdin {
        return fmt_one(path, true, false, check);
    }
    if unsafe shim::sc_stat_isdir(path.ptr() as *const char) == 1 {
        return fmt_dir(path, !check, check);
    }
    return fmt_one(path, false, !check, check);
}

fn fmt_one(path: str, is_stdin: bool, write: bool, check: bool) i32 {
    let src_opt = if is_stdin {
        read_stdin();
    } else {
        loader::read_file(path);
    };
    if src_opt.is_none() {
        eprintln("fmt: cannot read '{}'", path);
        return 1;
    }
    let src = src_opt.unwrap();

    let mut out = String::new();
    if format_source(&src, path, 120, &mut out) != 0 {
        return 1;
    }
    let src_view = src.as_str();
    let same = out.len() == src.len() && out.as_str() == src_view;
    let mut rc = 0;
    if check {
        if !same {
            print("{}\n", path);
            rc = 1;
        }
    } else if write {
        if !same {
            let f = stdio::fopen(path, "wb");
            if f == null {
                eprintln("fmt: cannot write '{}'", path);
                rc = 1;
            } else {
                unsafe stdio::fwrite(out.as_str().ptr(), 1, out.len(), f);
                unsafe stdio::fclose(f);
            }
        }
    } else {
        unsafe stdio::fwrite(out.as_str().ptr(), 1, out.len(), stdio::stdout());
    }
    return rc;
}

// CLI mode: `super-c <subcommand> <flags|args...>` -- the subcommand is always the first argument;
// a non-keyword first argument means MODE_DEFAULT (compile + run a script).
enum Mode {
    MODE_DEFAULT, // `super-c <root.spc>`: compile + run
    MODE_BUILD, // `super-c build [<root.spc>] [-o out]`: emit + link a program (or build.toml)
    MODE_RELEASE, // `super-c release [<root.spc>] [-o out]`: emit + link a release profile program (or build.toml)
    MODE_FMT, // `super-c fmt [--check] <path...| ->`
    MODE_LINT, // `super-c lint [--fix] [--suggest-const] <path> [<path2> ...]`
    MODE_RUN, // `super-c run <command>`: build.toml command
    MODE_CLEAN, // `super-c clean`: drop build.toml outputs
    MODE_TEST, // `super-c test`: tests/ by convention
    MODE_BENCH, // `super-c bench`: bench/main.spc by convention
    MODE_LSP, // `super-c lsp`: language server over stdio
}

// NOTE: an if-chain until a RELEASE ships the string-pattern switch lowering (the bootstrap binary
// must be able to emit this file); convert back to `switch arg { "build" => .. }` after that release.
fn subcommand(arg: str) Mode {
    return switch arg {
        "build" => {
            Mode::MODE_BUILD;
        },
        "release" => {
            Mode::MODE_RELEASE;
        },
        "fmt" => {
            Mode::MODE_FMT;
        },
        "lint" => {
            Mode::MODE_LINT;
        },
        "run" => {
            Mode::MODE_RUN;
        },
        "clean" => {
            Mode::MODE_CLEAN;
        },
        "test" => {
            Mode::MODE_TEST;
        },
        "bench" => {
            Mode::MODE_BENCH;
        },
        "lsp" => {
            Mode::MODE_LSP;
        },
        _ => {
            Mode::MODE_DEFAULT;
        },
    };
}

// Flags accepted by every compiling mode.
struct CommonOpts {
    pub ce_steps: u32, // --const-eval-steps=N
    pub ce_mem: u64, // --const-eval-memory=BYTES[K|M|G]
    pub target: i32, // --target=windows|macos|linux: @platform gate (default: host)
    pub bootstrap_tags: bool, // --bootstrap-tags: accept unknown @attributes (build across a new tag)
    pub lint: bool, // on by default; --no-lint disables (unused vars/params/items, casts, unsafe)
    pub bad: bool, // malformed argument list: print usage and exit 1
}

fn common_flag(o: &mut CommonOpts, arg: str) bool {
    if arg.starts_with("--const-eval-steps=") {
        let v = parse_size((&arg[19]) as *const char);
        if v == 0 || v > 4294967295u64 {
            o.bad = true;
        } else {
            o.ce_steps = v as u32;
        }
    } else if arg.starts_with("--const-eval-memory=") {
        o.ce_mem = parse_size((&arg[20]) as *const char);
        if o.ce_mem == 0 {
            o.bad = true;
        }
    } else if arg.starts_with("--target=") {
        let t = arg[9..];
        if t == "windows" {
            o.target = 0;
        } else if t == "macos" {
            o.target = 1;
        } else if t == "linux" {
            o.target = 2;
        } else {
            o.bad = true;
        }
    } else if arg == "--bootstrap-tags" {
        o.bootstrap_tags = true;
    } else if arg == "--no-lint" {
        o.lint = false;
    } else {
        return false;
    }
    return true;
}

// build.toml engine flags, shared by build/run/test/bench (`clean` takes only --out-dir).
struct BuildOpts<'a> {
    pub profile: str<'a>, // --profile=NAME (default: manifest default-profile)
    pub out_dir: str<'a>, // --out-dir=PATH: override the manifest's out-dir
    pub cstd: str<'a>, // --cstd=FLAGS: override the manifest's base C flags (CI: gnu11 on Windows)
    pub jobs: u32, // --jobs=N (0 = manifest / core count)
}

fn build_flag(o: &mut BuildOpts, co: &mut CommonOpts, arg: str) bool {
    if arg.starts_with("--profile=") {
        o.profile = arg[10..];
    } else if arg.starts_with("--out-dir=") {
        o.out_dir = arg[10..];
    } else if arg.starts_with("--cstd=") {
        o.cstd = arg[7..];
    } else if arg.starts_with("--jobs=") {
        let v = unsafe stdlib::atoi((&arg[7]) as *const char);
        if v < 1 {
            co.bad = true;
        } else {
            o.jobs = v as u32;
        }
    } else {
        return false;
    }
    return true;
}

fn main(argv: Vector<str>) i32 {
    let argc = argv.len();
    let mut file = "";
    let mut out_bin = ""; // set by the `build` subcommand (via -o, or defaulted)

    let mode = if argc > 1 {
        subcommand(argv[1]);
    } else {
        Mode::MODE_DEFAULT;
    };
    let mut fmt_check = false; // fmt --check: report unformatted files, write nothing
    let mut lint_fix = false; // lint --fix: apply machine fixes, re-lint to fixpoint
    let mut lint_sc = false; // lint --suggest-const: warn on functions the deep CTFE scan proves always evaluable
    let mut bench_norun = false; // bench --no-run: build the bench binary only
    let mut extra = Vector::<usize>::new(); // argv indices of extra `fmt`/`lint` paths
    let mut topts = TestOpts { enabled: false, jobs: 0, no_fork: false, filter: null };
    let mut co = CommonOpts {
        ce_steps: 0,
        ce_mem: 0,
        target: unsafe shim::sc_host_platform(),
        bootstrap_tags: false,
        lint: true,
        bad: false,
    };
    let mut bo = BuildOpts { profile: "", out_dir: "", cstd: "", jobs: 0 };

    let mut i: usize = if mode == Mode::MODE_DEFAULT {
        1usize;
    } else {
        2usize;
    };
    switch mode {
        MODE_DEFAULT => {
            while i < argc {
                let arg = argv[i];
                if common_flag(&mut co, arg) {} else if arg == "--test" {
                    topts.enabled = true;
                } else if arg.starts_with("--test-jobs=") {
                    topts.jobs = unsafe stdlib::atoi((&arg[12]) as *const char);
                    if topts.jobs < 1 {
                        co.bad = true;
                    }
                } else if arg == "--test-no-fork" {
                    topts.no_fork = true;
                } else if arg.starts_with("--test-filter=") {
                    topts.filter = (&arg[14]) as *const char;
                } else if arg.starts_with("--") {
                    co.bad = true;
                } else if file.len() == 0 {
                    file = arg;
                } else {
                    co.bad = true;
                }
                i = i + 1;
            }
        },
        MODE_BUILD | MODE_RELEASE => {
            while i < argc {
                let arg = argv[i];
                let common = common_flag(&mut co, arg);
                if common || build_flag(&mut bo, &mut co, arg) {} else if arg == "-o" {
                    if i + 1 < argc {
                        i = i + 1;
                        out_bin = argv[i];
                    } else {
                        co.bad = true;
                    }
                } else if arg.starts_with("--") {
                    co.bad = true;
                } else if file.len() == 0 {
                    file = arg;
                } else {
                    co.bad = true;
                }
                i = i + 1;
            }
            if file.len() != 0 && out_bin.len() == 0 {
                out_bin = "a.out";
            }
            if mode == Mode::MODE_RELEASE {
                bo.profile = "release";
            }
        },
        MODE_FMT => {
            while i < argc {
                let arg = argv[i];
                if arg == "--check" {
                    fmt_check = true;
                } else if arg.starts_with("--") {
                    co.bad = true;
                } else if file.len() == 0 {
                    file = arg;
                } else {
                    extra.push(i); // any number of paths
                }
                i = i + 1;
            }
        },
        MODE_LINT => {
            while i < argc {
                let arg = argv[i];
                if common_flag(&mut co, arg) {} else if arg == "--fix" {
                    lint_fix = true;
                } else if arg == "--suggest-const" {
                    lint_sc = true;
                } else if arg.starts_with("--") {
                    co.bad = true;
                } else if file.len() == 0 {
                    file = arg;
                } else {
                    extra.push(i); // any number of paths
                }
                i = i + 1;
            }
        },
        MODE_RUN => {
            while i < argc {
                let arg = argv[i];
                let common = common_flag(&mut co, arg);
                if common || build_flag(&mut bo, &mut co, arg) {} else if file.len() == 0 && !arg.starts_with("--") {
                    file = arg; // the build.toml command name
                } else {
                    co.bad = true;
                }
                i = i + 1;
            }
            if file.len() == 0 {
                co.bad = true; // `run` needs a command name
            }
        },
        MODE_CLEAN => {
            while i < argc {
                if argv[i].starts_with("--out-dir=") {
                    bo.out_dir = argv[i][10..];
                } else {
                    co.bad = true;
                }
                i = i + 1;
            }
        },
        MODE_TEST => {
            while i < argc {
                let arg = argv[i];
                let common = common_flag(&mut co, arg);
                if !common && !build_flag(&mut bo, &mut co, arg) {
                    co.bad = true;
                }
                i = i + 1;
            }
        },
        MODE_BENCH => {
            while i < argc {
                let arg = argv[i];
                if arg == "--no-run" {
                    bench_norun = true;
                } else {
                    let common = common_flag(&mut co, arg);
                    if !common && !build_flag(&mut bo, &mut co, arg) {
                        co.bad = true;
                    }
                }
                i = i + 1;
            }
        },
        MODE_LSP => {
            while i < argc {
                if !common_flag(&mut co, argv[i]) {
                    co.bad = true;
                }
                i = i + 1;
            }
        },
    };
    if !topts.enabled && (topts.jobs != 0 || topts.no_fork || topts.filter != null) {
        co.bad = true;
    }
    // `build` with a .spc root is the direct emit+link mode; without one it reads build.toml
    let manifest_mode = (mode == Mode::MODE_BUILD || mode == Mode::MODE_RELEASE) && file.len() == 0 || mode == Mode::MODE_RUN || mode == Mode::MODE_CLEAN || mode == Mode::MODE_TEST || mode == Mode::MODE_BENCH;
    if co.bad || file.len() == 0 && !manifest_mode && mode != Mode::MODE_LSP {
        unsafe stdio::fputs(
            "Usage: super-c [--const-eval-steps=N] [--const-eval-memory=BYTES[K|M|G]] [--target=windows|macos|linux] [--bootstrap-tags]\n       [--test [--test-jobs=N] [--test-no-fork] [--test-filter=S]] <path/to/script>\n       super-c build|release [<path/to/script>] [-o <out>] [--profile=P] [--jobs=N] [--out-dir=D] [--cstd=F]\n       super-c test | super-c bench [--no-run] | super-c run <command> [--profile=P] | super-c clean\n       super-c fmt [-w | --check] <path/to/script | -> | super-c lsp\n".ptr() as *const char,
            stdio::stderr(),
        );
        return 1;
    }
    let ce_steps = co.ce_steps;
    let ce_mem = co.ce_mem;
    let target = co.target;
    let bootstrap_tags = co.bootstrap_tags;
    let lint = co.lint;
    let profile = bo.profile;
    let out_dir = bo.out_dir;
    let cstd = bo.cstd;
    let jobs = bo.jobs;
    if mode == Mode::MODE_FMT {
        let mut rc = run_fmt(file, fmt_check);
        for k in 0..extra.len() {
            if run_fmt(argv[*extra.at(k)], fmt_check) != 0 {
                rc = 1;
            }
        }
        return rc;
    }
    let arg0: *const char = if argc > 0 {
        argv[0].ptr() as *const char;
    } else {
        "super-c".ptr() as *const char;
    };
    let std_dir = exe_std_dir(arg0);
    if mode == Mode::MODE_LINT {
        let mut rc = run_lint(file, std_dir, ce_steps, ce_mem, target, lint_fix, lint_sc);
        for k in 0..extra.len() {
            if run_lint(argv[*extra.at(k)], std_dir, ce_steps, ce_mem, target, lint_fix, lint_sc) != 0 {
                rc = 1;
            }
        }
        if std_dir != null {
            unsafe stdlib::free(std_dir);
        }
        return rc;
    }
    if mode == Mode::MODE_LSP {
        let rc = lsp_srv::run(std_dir, target);
        if std_dir != null {
            unsafe stdlib::free(std_dir);
        }
        return rc;
    }
    if manifest_mode {
        let mo = bman::load("build.toml");
        let mut rc = 1;
        if !mo.is_none() {
            let mut man = mo.unwrap();
            if out_dir.len() != 0 {
                man.out_dir = String::from_str(out_dir);
            }
            if cstd.len() != 0 {
                man.cstd = String::from_str(cstd);
            }
            if mode == Mode::MODE_CLEAN {
                rc = if bsys::command_overrides(&man, "clean") {
                    bsys::manifest_run(
                        &man,
                        "clean",
                        profile,
                        jobs,
                        std_dir,
                        ce_steps,
                        ce_mem,
                        target,
                        bootstrap_tags,
                        lint,
                    );
                } else {
                    bsys::manifest_clean(&man);
                };
            } else if mode == Mode::MODE_TEST {
                if bsys::command_overrides(&man, "test") {
                    rc = bsys::manifest_run(
                        &man,
                        "test",
                        profile,
                        jobs,
                        std_dir,
                        ce_steps,
                        ce_mem,
                        target,
                        bootstrap_tags,
                        lint,
                    );
                } else {
                    topts.enabled = true;
                    rc = bsys::manifest_test(
                        &man,
                        profile,
                        jobs,
                        &topts,
                        std_dir,
                        ce_steps,
                        ce_mem,
                        target,
                        bootstrap_tags,
                    );
                }
            } else if mode == Mode::MODE_BENCH {
                rc = if bsys::command_overrides(&man, "bench") {
                    bsys::manifest_run(
                        &man,
                        "bench",
                        profile,
                        jobs,
                        std_dir,
                        ce_steps,
                        ce_mem,
                        target,
                        bootstrap_tags,
                        lint,
                    );
                } else {
                    bsys::manifest_bench(
                        &man,
                        profile,
                        bench_norun,
                        jobs,
                        std_dir,
                        ce_steps,
                        ce_mem,
                        target,
                        bootstrap_tags,
                    );
                };
            } else if mode == Mode::MODE_RUN {
                rc = bsys::manifest_run(
                    &man,
                    file,
                    profile,
                    jobs,
                    std_dir,
                    ce_steps,
                    ce_mem,
                    target,
                    bootstrap_tags,
                    lint,
                );
            } else if bsys::command_overrides(&man, "build") {
                rc = bsys::manifest_run(
                    &man,
                    "build",
                    profile,
                    jobs,
                    std_dir,
                    ce_steps,
                    ce_mem,
                    target,
                    bootstrap_tags,
                    lint,
                );
            } else {
                rc = bsys::manifest_build(
                    &man,
                    profile,
                    out_bin,
                    jobs,
                    std_dir,
                    ce_steps,
                    ce_mem,
                    target,
                    bootstrap_tags,
                    lint,
                );
            }
        }
        if std_dir != null {
            unsafe stdlib::free(std_dir);
        }
        return rc;
    }
    let rc = run_file(file, std_dir, ce_steps, ce_mem, &topts, out_bin, target, bootstrap_tags, lint);
    if std_dir != null {
        unsafe stdlib::free(std_dir);
    }
    return rc;
}
