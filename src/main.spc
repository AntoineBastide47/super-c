// The self-hosted super-c driver: parse args, load the package, run the global phases
// (resolve all -> type-check all -> flush deferred static_asserts -> propagate instances -> emit all),
// writing a `<root>/build/` tree (super_rt.h + one .c/.h per module). Ports src/main.c.
import stdio;
import stdlib;
import string as cstring;
import lexer::token as tok;
import lexer::lexer as lex;
import lexer::token_type as ltt;
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
        let pkg = (&mut p) as *mut loader::Package;
        let mut ceval = ce::ConstEval::new(pkg, ce_steps, ce_mem);
        p.ceval = &mut ceval;
        rc = run_package(&mut p, topts, out_bin, target, lint);
        ceval.free();
    }
    p.free();
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
    let s1 = unsafe cstring::strrchr(path, '/' as i32);
    let s2 = unsafe cstring::strrchr(path, '\\' as i32);
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
            s.push_bytes(buf as *const u8, n);
        }
        if n < cap {
            break;
        }
    }
    unsafe stdlib::free(buf);
    return Option::<String>::Some(s);
}

// Byte-lexicographic name order with a length tiebreak: deterministic directory walks.
fn fmt_name_cmp(a: &String, b: &String) i32 {
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
        d.free();
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
        p.free();
    }
    names.free();
    d.free();
    return rc;
}

// `super-c lint <path> [<path2> ...]`: load each path as its own root (its import closure + prelude),
// resolve + typecheck with lints on for that root module, and print warnings. Lints files that are not
// part of any binary's import closure. A directory recurses over its .spc files.
fn lint_one(path: str, root: str, std_dir: *const char, ce_steps: u32, ce_mem: u64, target: i32) i32 {
    // A std/ffi file must keep its prelude identity (module path, builtin seeding, load order):
    // loading it as a root would invent errors. Load an empty root -- the prelude comes along as
    // always -- and if the requested file IS one of those modules, lint it in place.
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
        p.free();
        p = if root.len() != 0 {
            loader::package_load_rooted(path, root, std_dir, false);
        } else {
            loader::package_load(path, std_dir, false);
        };
        lint_mod = 0;
    }
    pathc.free();
    if !p.ok {
        p.free();
        return 1;
    }
    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, ce_steps, ce_mem);
    p.ceval = &mut ceval;
    let rc = lint_package(&mut p, target, lint_mod);
    ceval.free();
    p.free();
    return rc;
}

fn lint_dir(dir: str, root: str, std_dir: *const char, ce_steps: u32, ce_mem: u64, target: i32) i32 {
    let mut d = String::from_str(dir);
    let dh = unsafe shim::sc_opendir(d.cstr());
    if dh == null {
        eprintln("lint: cannot read directory '{}'", dir);
        d.free();
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
            if lint_dir(p.as_str(), root, std_dir, ce_steps, ce_mem, target) != 0 {
                rc = 1;
            }
        } else if names.at(i).as_str().ends_with(".spc") {
            if lint_one(p.as_str(), root, std_dir, ce_steps, ce_mem, target) != 0 {
                rc = 1;
            }
        }
        p.free();
    }
    names.free();
    d.free();
    return rc;
}

fn run_lint(path: str, std_dir: *const char, ce_steps: u32, ce_mem: u64, target: i32) i32 {
    if unsafe shim::sc_stat_isdir(path.ptr() as *const char) == 1 {
        // every file under the directory resolves imports against the directory itself
        return lint_dir(path, path, std_dir, ce_steps, ce_mem, target);
    }
    return lint_one(path, "", std_dir, ce_steps, ce_mem, target);
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
    let mut src = src_opt.unwrap();

    // Reject sources that do not parse -- never rewrite something the compiler cannot read.
    // Lexed with trivia so the doc pipeline can count comments; the parser gets a filtered stream.
    let mut vsrc = String::from_str(src.as_str());
    let mut lx = lex::Lexer::new(&mut vsrc, path);
    lx.keep_trivia = true;
    lx.scan_tokens();
    if lx.has_errors() {
        lx.log_errors();
        lx.free();
        vsrc.free();
        src.free();
        return 1;
    }
    let mut toks = lx.take_tokens();
    lx.free();
    let mut ncomments: usize = 0;
    let mut sig = Vector::<tok::Token>::new();
    for i in 0..toks.len() {
        let t = *toks.at(i);
        let k = t.kind();
        if k == ltt::TokenType::LineComment || k == ltt::TokenType::BlockComment || k == ltt::TokenType::DocLineComment || k == ltt::TokenType::DocBlockComment {
            ncomments = ncomments + 1;
        } else {
            sig.push(t);
        }
    }
    toks.free();
    let mut ps = par::Parser::new(sig, vsrc.as_str(), path);
    ps.build_ast();
    let perr = ps.has_errors();
    if perr {
        ps.errors.log();
    }
    if perr {
        ps.free();
        vsrc.free();
        src.free();
        return 1;
    }

    let mut out = String::new();
    let ast = ps.take_ast();
    ps.free();
    let emitted = fbld::format_program((&ast) as *const Ast, src.as_str(), 120, &mut out);
    let mut ast2 = ast;
    ast2.free();
    vsrc.free();
    if emitted != ncomments {
        eprintln(
            "fmt: internal error: {} of {} comments would be dropped in '{}'; refusing",
            ncomments - emitted,
            ncomments,
            path,
        );
        out.free();
        src.free();
        return 1;
    }
    let src_view = src.as_str();
    let same = out.len() == src.len() && out.as_str().eq(&src_view);
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
    out.free();
    src.free();
    return rc;
}

fn main(argv: Vector<str>) i32 {
    let argc = argv.len();
    let mut ce_steps: u32 = 0;
    let mut ce_mem: u64 = 0;
    let mut file = "";
    let mut out_bin = ""; // set by the `build` subcommand (via -o, or defaulted)
    let mut lint = true; // on by default; --no-lint disables (unused vars/params/items, casts, unsafe)
    let mut build_mode = false;
    let mut fmt_mode = false;
    let mut fmt_check = false;

    let mut fmt_extra = Vector::<usize>::new(); // argv indices of extra `fmt` paths
    let mut lint_mode = false; // `super-c lint <path> [<path2> ...]`
    let mut lint_extra = Vector::<usize>::new(); // argv indices of extra `lint` paths
    let mut topts = TestOpts { enabled: false, jobs: 0, no_fork: false, filter: null };
    let mut bad = false;
    let mut target: i32 = unsafe shim::sc_host_platform(); // @platform gate target; --target= overrides
    let mut bootstrap_tags = false; // --bootstrap-tags: accept unknown @attributes (build across a new tag)
    let mut i: usize = 1;
    while i < argc {
        let arg = argv[i];
        if !build_mode && file.len() == 0 && arg == "build" {
            build_mode = true; // `super-c build <root.spc> [-o out]`: emit + link a program
        } else if !build_mode && !fmt_mode && !lint_mode && file.len() == 0 && arg == "fmt" {
            fmt_mode = true; // `super-c fmt [--check] <path...| ->`
        } else if !build_mode && !fmt_mode && !lint_mode && file.len() == 0 && arg == "lint" {
            lint_mode = true;
        } else if fmt_mode && arg == "--check" {
            fmt_check = true;
        } else if arg == "-o" {
            if i + 1 < argc {
                i = i + 1;
                out_bin = argv[i];
            } else {
                bad = true;
            }
        } else if arg.starts_with("--const-eval-steps=") {
            let v = parse_size((&arg[19]) as *const char);
            if v == 0 || v > 4294967295u64 {
                bad = true;
            } else {
                ce_steps = v as u32;
            }
        } else if arg.starts_with("--const-eval-memory=") {
            ce_mem = parse_size((&arg[20]) as *const char);
            if ce_mem == 0 {
                bad = true;
            }
        } else if arg == "--test" {
            topts.enabled = true;
        } else if arg.starts_with("--test-jobs=") {
            topts.jobs = unsafe stdlib::atoi((&arg[12]) as *const char);
            if topts.jobs < 1 {
                bad = true;
            }
        } else if arg == "--no-lint" {
            lint = false;
        } else if arg == "--test-no-fork" {
            topts.no_fork = true;
        } else if arg.starts_with("--test-filter=") {
            topts.filter = (&arg[14]) as *const char;
        } else if arg.starts_with("--target=") {
            let t = arg[9..];
            if t == "windows" {
                target = 0;
            } else if t == "macos" {
                target = 1;
            } else if t == "linux" {
                target = 2;
            } else {
                bad = true;
            }
        } else if arg == "--bootstrap-tags" {
            bootstrap_tags = true;
        } else if arg.starts_with("--") {
            bad = true;
        } else if file.len() == 0 {
            file = arg;
        } else if fmt_mode {
            fmt_extra.push(i); // `fmt` accepts any number of paths
        } else if lint_mode {
            lint_extra.push(i); // `lint` accepts any number of paths
        } else {
            file = "";
        }
        i = i + 1;
    }
    if !topts.enabled && (topts.jobs != 0 || topts.no_fork || topts.filter != null) {
        bad = true;
    }
    if out_bin.len() != 0 && !build_mode {
        bad = true;
    } // -o is only meaningful for `build`
    if build_mode && topts.enabled {
        bad = true;
    } // `build` and `--test` are mutually exclusive
    if fmt_mode && (build_mode || topts.enabled) {
        bad = true;
    }
    // -w and --check are mutually exclusive
    if build_mode && out_bin.len() == 0 {
        out_bin = "a.out";
    }
    if bad || file.len() == 0 {
        unsafe stdio::fputs(
            "Usage: super-c [--const-eval-steps=N] [--const-eval-memory=BYTES[K|M|G]] [--target=windows|macos|linux] [--bootstrap-tags]\n       [--test [--test-jobs=N] [--test-no-fork] [--test-filter=S]] <path/to/script>\n       super-c build [-o <out>] <path/to/script>\n       super-c fmt [-w | --check] <path/to/script | ->\n".ptr() as *const char,
            stdio::stderr(),
        );
        return 1;
    }
    if fmt_mode {
        let mut rc = run_fmt(file, fmt_check);
        for k in 0..fmt_extra.len() {
            if run_fmt(argv[*fmt_extra.at(k)], fmt_check) != 0 {
                rc = 1;
            }
        }
        fmt_extra.free();
        return rc;
    }
    fmt_extra.free();
    let arg0: *const char = if argc > 0 {
        argv[0].ptr() as *const char;
    } else {
        "super-c".ptr() as *const char;
    };
    let std_dir = exe_std_dir(arg0);
    if lint_mode {
        let mut rc = run_lint(file, std_dir as *const char, ce_steps, ce_mem, target);
        for k in 0..lint_extra.len() {
            if run_lint(argv[*lint_extra.at(k)], std_dir as *const char, ce_steps, ce_mem, target) != 0 {
                rc = 1;
            }
        }
        lint_extra.free();
        if std_dir != null {
            unsafe stdlib::free(std_dir);
        }
        return rc;
    }
    lint_extra.free();
    let rc = run_file(
        file,
        std_dir,
        ce_steps,
        ce_mem,
        (&topts) as *const TestOpts,
        out_bin,
        target,
        bootstrap_tags,
        lint,
    );
    if std_dir != null {
        unsafe stdlib::free(std_dir);
    }
    return rc;
}
