// The self-hosted super-c driver. The first argument selects the mode: build/release (emit + link,
// through build.toml when no root is given), fmt, lint, run/command/clean/test/bench (build.toml engine),
// lsp, or a bare <root.spc> (compile + run, MODE_DEFAULT). Compiling modes share CommonOpts
// (--const-eval-*, --target, --bootstrap-tags, --no-lint); manifest modes add BuildOpts
// (--profile/--out-dir/--cstd/--jobs). A compiled root runs the global phases (resolve all ->
// type-check all -> flush deferred static_asserts -> propagate instances -> emit all), writing a
// `<root>/build/` tree (super_rt.h + one .c/.h per module).
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
import bindgen::bindgen as bindgen;

fn run_file(
    path: str,
    std_dir: *const char,
    ce_steps: u32,
    ce_mem: u64,
    topts: *const TestOpts,
    out_bin: str,
    target: i32,
    arch: i32,
    bootstrap_tags: bool,
    lint: bool,
    cflags: str,
) i32 {
    let mut p = loader::package_load(path, std_dir, bootstrap_tags, target);
    p.arch = arch; // --arch= (else the host) is the axis `@arch` gates on
    // A standalone script is a binary with no test suite to count as callers: unreachable pub
    // functions are dead weight. Project trees get this from the whole-workspace lint instead,
    // where @test roots keep test-only helpers alive.
    let manf = stdio::fopen("build.toml", "rb");
    if manf != null {
        unsafe stdio::fclose(manf);
    } else {
        p.lint_pub = lint;
    }
    let mut rc: i32 = 1;
    if p.ok {
        let mut ceval = ce::ConstEval::new(&mut p, ce_steps, ce_mem);
        p.ceval = &mut ceval;
        rc = run_package(&mut p, topts, out_bin, target, lint, cflags, null, 0);
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
    // std lives beside the compiler -- but not always DIRECTLY beside it: a profile build sits two levels
    // down in <out-dir>/<profile>/, so try the parents before giving up. First 'std' directory wins.
    let mut cut = dirlen;
    for _up in 0..3 {
        unsafe cstring::memcpy(out + cut, "/std".ptr(), 4);
        unsafe out[cut + 4] = 0 as char;
        if unsafe shim::sc_stat_isdir(out) == 1 {
            return out;
        }
        let mut k = cut;
        while k > 0 && unsafe out[k - 1] != '/' as char {
            k = k - 1;
        }
        if k <= 1 {
            break;
        }
        cut = k - 1;
    }
    // Nothing found: answer with the one next to the binary, so a failure names the obvious place.
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

// The entries of `dir` in name order, without the dot-entries (".", "..", hidden); None when the
// directory cannot be read.
fn dir_entries(dir: str) Option<Vector<String>> {
    let mut d = String::from_str(dir);
    let dh = unsafe shim::sc_opendir(d.cstr());
    if dh == null {
        return Option::<Vector<String>>::None;
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
    return Option::<Vector<String>>::Some(names);
}

// `fmt`/`lint` with no path: every top-level entry of the project, minus the build output -- it
// holds the generated .spc roots of `test`/`bench`, which are not project source.
fn project_paths() Vector<String> {
    let mut out = Vector::<String>::new();
    let eo = dir_entries(".");
    if eo.is_none() {
        eprintln("cannot read the current directory");
        return out;
    }
    let names = eo.unwrap();
    let mut skip = String::from_str("build");
    for i in 0..names.len() {
        if names.at(i).as_str() == "build.toml" {
            let mo = bman::load("build.toml");
            if !mo.is_none() {
                let man = mo.unwrap();
                skip.clear();
                skip.push_string(&man.out_dir);
            }
            break;
        }
    }
    let mut probe = String::new();
    for i in 0..names.len() {
        let n = names.at(i).as_str();
        if n == skip.as_str() {
            continue;
        }
        probe.clear();
        probe.push_str(n);
        if unsafe shim::sc_stat_isdir(probe.cstr()) == 1 || n.ends_with(".spc") {
            out.push(String::from_str(n));
        }
    }
    return out;
}

// Recursively format every .spc under `dir` (sorted; dot-entries skipped). Returns 1 if any file
// failed or (--check) needs formatting, else 0.
fn fmt_dir(dir: str, write: bool, check: bool) i32 {
    let eo = dir_entries(dir);
    if eo.is_none() {
        eprintln("fmt: cannot read directory '{}'", dir);
        return 1;
    }
    let names = eo.unwrap();
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

// `super-c lint [<path>...]`: load each path as its own root (its import closure + prelude),
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
// kind 2 inserts 'const ' before start, kind 3 inserts fix_texts[text] before start, kind 4 replaces
// [start, end) with fix_texts[text]. An overlapping fix is skipped -- the next `--fix` re-lint pass
// records it against the patched source.
fn apply_lint_fixes(src: str, fixes: &mut Vector<diag::LintFix>, texts: &Vector<String>) String {
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
        } else if f.kind == 3 {
            if f.text as usize < texts.len() {
                out.push_str(texts.at(f.text as usize).as_str());
            }
            pos = f.start as usize;
        } else if f.kind == 4 {
            if f.text as usize < texts.len() {
                out.push_str(texts.at(f.text as usize).as_str());
            }
            pos = f.end as usize;
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
    // if the package has any error a machine fix cannot repair (when EVERY error carries a fix, e.g.
    // the generated-Free leak fix, applying is the way out); a final plain pass prints what remains
    // and sets the exit code.
    let mut pass = 0;
    loop {
        let mut pathc = String::from_str(path);
        let mut p = loader::package_from_source("".ptr() as *const char, 0, std_dir, target);
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
                loader::package_load_rooted(path, root, lint_alt(), std_dir, false, target);
            } else {
                loader::package_load(path, std_dir, false, target);
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
            let rc = lint_package(&mut p, target, lint_mod, null, null, sc);
            return rc;
        }
        let mut fixes = Vector::<diag::LintFix>::new();
        let mut ftexts = Vector::<String>::new();
        lint_package(&mut p, target, lint_mod, &mut fixes, &mut ftexts, sc);
        let errors = !p.ok && !(p.lint_errs != 0 && p.lint_errs == p.lint_fixable);
        let mut applied = false;
        let mut werr = false;
        if !errors && fixes.len() != 0 && pass < 8 {
            let out = apply_lint_fixes(p.modules[lint_mod].source.as_str(), &mut fixes, &ftexts);
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

// Collect every .spc under `dir` recursively (dir_entries order, matching lint_dir's walk).
fn lint_collect(dir: str, files: &mut Vector<String>) i32 {
    let eo = dir_entries(dir);
    if eo.is_none() {
        eprintln("lint: cannot read directory '{}'", dir);
        return 1;
    }
    let names = eo.unwrap();
    let mut rc = 0;
    for i in 0..names.len() {
        let mut p = String::from_str(dir);
        p.push_byte(b'/');
        p.push_string(names.at(i));
        if unsafe shim::sc_stat_isdir(p.cstr()) == 1 {
            if lint_collect(p.as_str(), files) != 0 {
                rc = 1;
            }
        } else if names.at(i).as_str().ends_with(".spc") {
            files.push(p);
        }
    }
    return rc;
}

// One-package load for the batch: prelude first (so std/ffi files keep their prelude identity), then
// each listed file joins the closure once, marked in lint_set.
fn lint_load_batch(files: &Vector<String>, root: str, alt: str, std_dir: *const char, target: i32) loader::Package {
    let mut p = loader::package_load_prelude(
        root,
        alt,
        std_dir,
        target,
        Vector::<String>::new(),
        Vector::<String>::new(),
    );
    let mut mids = Vector::<i32>::new();
    for k in 0..files.len() {
        let mut fc = String::from_str(files.at(k).as_str());
        // already present? (a prelude module, or pulled in by an earlier file's imports)
        let mut mid: i32 = -1;
        for m in 0..p.modules.len() {
            if p.modules[m].has_ast && unsafe shim::sc_same_file(fc.cstr(), p.modules[m].file.cstr()) == 1 {
                mid = m as i32;
                break;
            }
        }
        if mid < 0 {
            let mp = loader::batch_mod_path(files.at(k).as_str(), root, alt);
            mid = p.load_module(mp.as_str(), files.at(k).as_str(), false, target);
        }
        mids.push(mid);
    }
    let mut set = Vector::<bool>::new();
    for m in 0..p.modules.len() {
        set.push(false);
    }
    for k in 0..mids.len() {
        if mids[k] >= 0 {
            set.set(mids[k] as usize, true);
        }
    }
    p.lint_set = set;
    return p;
}

// Batch lint: ONE package shared by every listed file, and the pipeline runs once with the listed
// modules masked in lint_set. Replaces the per-file full-closure reload, which was quadratic in project
// size. `--fix` runs the same quiet fixpoint as lint_one -- one package per round, every module's fixes
// applied together (LintFix.module groups them) -- with the same reject rule: nothing is written while
// the package has an error a machine fix cannot repair.
fn lint_batch(
    files: &Vector<String>,
    root: str,
    std_dir: *const char,
    ce_steps: u32,
    ce_mem: u64,
    target: i32,
    fix: bool,
    sc: bool,
    lint_pub: bool,
) i32 {
    let alt = lint_alt();
    let mut pass = 0;
    loop {
        let mut p = lint_load_batch(files, root, alt, std_dir, target);
        p.lint_pub = lint_pub;
        if !p.ok {
            return 1;
        }
        let pkg = (&mut p) as *mut loader::Package;
        let mut ceval = ce::ConstEval::new(pkg, ce_steps, ce_mem);
        p.ceval = &mut ceval;
        if !fix {
            return lint_package(&mut p, target, 0, null, null, sc);
        }
        let mut fixes = Vector::<diag::LintFix>::new();
        let mut ftexts = Vector::<String>::new();
        lint_package(&mut p, target, 0, &mut fixes, &mut ftexts, sc);
        let errors = !p.ok && !(p.lint_errs != 0 && p.lint_errs == p.lint_fixable);
        let mut applied = false;
        let mut werr = false;
        if !errors && fixes.len() != 0 && pass < 8 {
            for m in 0..p.modules.len() {
                let mut mf = Vector::<diag::LintFix>::new();
                for k in 0..fixes.len() {
                    if fixes[k].module as usize == m {
                        mf.push(fixes[k]);
                    }
                }
                if mf.len() == 0 {
                    continue;
                }
                let out = apply_lint_fixes(p.modules[m].source.as_str(), &mut mf, &ftexts);
                let f = stdio::fopen(p.modules[m].file.as_str(), "wb");
                if f == null {
                    eprintln("lint: cannot write '{}'", p.modules[m].file.as_str());
                    werr = true;
                } else {
                    unsafe stdio::fwrite(out.as_str().ptr(), 1, out.len(), f);
                    unsafe stdio::fclose(f);
                    // reformat before re-linting: canonicalization can unlock paren-guarded fixes
                    fmt_one(p.modules[m].file.as_str(), false, true, false);
                    applied = true;
                }
            }
        }
        if errors || werr {
            return 1;
        }
        if !applied {
            break;
        }
        pass = pass + 1;
    }
    // a final plain pass prints what remains and sets the exit code
    return lint_batch(files, root, std_dir, ce_steps, ce_mem, target, false, sc, lint_pub);
}

fn run_lint(path: str, std_dir: *const char, ce_steps: u32, ce_mem: u64, target: i32, fix: bool, sc: bool) i32 {
    if unsafe shim::sc_stat_isdir(path.ptr() as *const char) == 1 {
        // every file under the directory resolves imports against the directory itself
        let droot = if lint_alt().len() != 0 {
            ".";
        } else {
            path;
        };
        let mut files = Vector::<String>::new();
        let crc = lint_collect(path, &mut files);
        let brc = lint_batch(&files, droot, std_dir, ce_steps, ce_mem, target, fix, sc, false);
        return if crc != 0 || brc != 0 {
            1;
        } else {
            0;
        };
    }
    let froot = if lint_alt().len() != 0 {
        ".";
    } else {
        "";
    };
    return lint_one(path, froot, std_dir, ce_steps, ce_mem, target, fix, sc);
}

// `super-c fmt [<path>...]`: canonical formatting. Rewrites files in place by default (only when they
// changed); --check writes nothing, prints the path, and exits 1 when a file is not already formatted.
// `-` reads stdin and formats to stdout. A directory recurses over its .spc files. A file the compiler
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
    MODE_FMT, // `super-c fmt [--check] [<path>...| -]` (no path: the whole project)
    MODE_LINT, // `super-c lint [--fix] [--suggest-const] [<path>...]` (no path: the whole project)
    MODE_COMMAND, // `super-c command <name>`: run a build.toml [command.NAME]
    MODE_RUN, // `super-c run [--profile=P]`: build the project, then execute its binary (cargo run)
    MODE_CLEAN, // `super-c clean`: drop build.toml outputs
    MODE_TEST, // `super-c test`: tests/ by convention
    MODE_BENCH, // `super-c bench`: bench/main.spc by convention
    MODE_LSP, // `super-c lsp`: language server over stdio
    MODE_NEW, // `super-c new <name>`: scaffold a project directory (cargo new)
    MODE_INIT, // `super-c init`: scaffold a project in the current directory (cargo init)
    MODE_VENDOR, // `super-c vendor <git-url|dir> [name]`: copy a dependency into vendor/
    MODE_BINDGEN, // `super-c bindgen <header.h>`: C header -> an `extern "C"` module
}

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
        "command" => {
            Mode::MODE_COMMAND;
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
        "new" => {
            Mode::MODE_NEW;
        },
        "init" => {
            Mode::MODE_INIT;
        },
        "vendor" => {
            Mode::MODE_VENDOR;
        },
        "bindgen" => {
            Mode::MODE_BINDGEN;
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
    pub target: i32, // --target=windows|macos|linux|ios|android|wasm: @platform gate (default: host)
    pub arch: i32, // --arch=x86_64|aarch64|wasm32: @arch gate (default: the host's instruction set)
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
        } else if t == "wasm" {
            o.target = 3;
            o.arch = 2; // wasm32
        } else if t == "ios" {
            o.target = 4;
            o.arch = 1; // aarch64
        } else if t == "android" {
            o.target = 5;
            o.arch = 1; // aarch64
        } else {
            o.bad = true;
        }
    } else if arg.starts_with("--arch=") {
        let a2 = arg[7..];
        if a2 == "x86_64" {
            o.arch = 0;
        } else if a2 == "aarch64" {
            o.arch = 1;
        } else if a2 == "wasm32" {
            o.arch = 2;
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
    pub cc: str<'a>, // --cc=BIN: override the C compiler (else manifest `cc`, else $CC, else cc)
    pub jobs: u32, // --jobs=N (0 = manifest / core count)
    pub bin_sel: str<'a>, // --bin=NAME: build/run only that binary target
    pub lib_sel: bool, // --lib: build only the [lib] target
}

fn build_flag(o: &mut BuildOpts, co: &mut CommonOpts, arg: str) bool {
    if arg.starts_with("--profile=") {
        o.profile = arg[10..];
    } else if arg.starts_with("--out-dir=") {
        o.out_dir = arg[10..];
    } else if arg.starts_with("--cstd=") {
        o.cstd = arg[7..];
    } else if arg.starts_with("--cc=") {
        o.cc = arg[5..];
    } else if arg.starts_with("--bin=") {
        o.bin_sel = arg[6..];
    } else if arg == "--lib" {
        o.lib_sel = true;
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

fn is_dir(path: str) bool {
    let mut p = String::from_str(path);
    return unsafe shim::sc_stat_isdir(p.cstr()) == 1;
}

fn canon_cwd() String {
    let mut dot = String::from_str(".");
    let mut buf = PathBuf {};
    if unsafe shim::sc_realpath(dot.cstr(), &mut buf[0]) != null {
        return String::from_cstr(&buf[0]);
    }
    return dot;
}

// Cargo-style manifest discovery: when the cwd has no build.toml, walk toward the filesystem root and
// chdir to the nearest directory that has one. A miss changes nothing -- the caller reports it.
fn chdir_to_manifest() {
    let probe = stdio::fopen("build.toml", "rb");
    if probe != null {
        unsafe stdio::fclose(probe);
        return;
    }
    let cwd = canon_cwd();
    let mut end = cwd.len();
    while end > 1 {
        while end > 1 && cwd.as_str()[end - 1] != b'/' {
            end = end - 1;
        }
        if end <= 1 {
            break;
        }
        end = end - 1; // drop the trailing '/'
        let mut dir = String::from_str(cwd.as_str().slice(0, end));
        let mut man = dir.clone();
        man.push_str("/build.toml");
        let f = stdio::fopen(man.as_str(), "rb");
        if f != null {
            unsafe stdio::fclose(f);
            let _ = unsafe shim::sc_chdir(dir.cstr());
            return;
        }
    }
}

fn main(argv: Vector<str>) i32 {
    unsafe shim::sc_trace_install();
    let argc = argv.len();
    let mut file = "";
    let mut out_bin = ""; // set by the `build` subcommand (via -o, or defaulted)
    let mut bg_link = ""; // bindgen: --link=NAME, the library the bindings need on the link line
    let mut bg_header = ""; // bindgen: --header=SPELLING, how the emitted module #includes it
    let mut bg_incs = Vector::<String>::new(); // bindgen: -I search paths
    let mut bg_from = Vector::<String>::new(); // bindgen: --from=, extra origin headers to accept
    let mut bg_cflags = Vector::<String>::new(); // bindgen: --cflag=, passed to the preprocessor verbatim
    let mut vendor_name = ""; // vendor: optional name override for vendor/<name>
    let mut vendor_dir = "."; // vendor: --dir=, the project root vendored into
    let mut vendor_ref = ""; // vendor: --ref=, the branch, tag or commit pinned for a git source
    let mut vendor_force = false; // vendor: --force, replace an existing vendor/<name>
    let mut clean_cache = false; // clean: --cache, also drop the machine-global object cache

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
        arch: unsafe shim::sc_host_arch(),
        bootstrap_tags: false,
        lint: true,
        bad: false,
    };
    let mut bo = BuildOpts { profile: "", out_dir: "", cstd: "", cc: "", jobs: 0, bin_sel: "", lib_sel: false };

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
        MODE_COMMAND => {
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
                co.bad = true; // `command` needs a command name
            }
        },
        MODE_RUN => {
            while i < argc {
                let arg = argv[i];
                let common = common_flag(&mut co, arg);
                if common || build_flag(&mut bo, &mut co, arg) {} else {
                    co.bad = true; // `run` takes only build flags; the binary is the manifest's `bin`
                }
                i = i + 1;
            }
        },
        MODE_CLEAN => {
            while i < argc {
                if argv[i].starts_with("--out-dir=") {
                    bo.out_dir = argv[i][10..];
                } else if argv[i] == "--cache" {
                    clean_cache = true;
                } else {
                    co.bad = true;
                }
                i = i + 1;
            }
        },
        MODE_TEST => {
            topts.enabled = true; // `super-c test` IS the test mode, which is what makes its flags legal
            while i < argc {
                let arg = argv[i];
                // The test flags belong here as much as in script mode (`file.spc --test`): `super-c test`
                // is how the suite is normally run, so it is where filtering one test out of it matters.
                if arg.starts_with("--test-jobs=") {
                    topts.jobs = unsafe stdlib::atoi((&arg[12]) as *const char);
                    if topts.jobs < 1 {
                        co.bad = true;
                    }
                } else if arg == "--test-no-fork" {
                    topts.no_fork = true;
                } else if arg.starts_with("--test-filter=") {
                    topts.filter = (&arg[14]) as *const char;
                } else {
                    let common = common_flag(&mut co, arg);
                    if !common && !build_flag(&mut bo, &mut co, arg) {
                        co.bad = true;
                    }
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
        MODE_NEW => {
            while i < argc {
                if !argv[i].starts_with("--") && file.len() == 0 {
                    file = argv[i]; // the project name
                } else {
                    co.bad = true;
                }
                i = i + 1;
            }
            if file.len() == 0 {
                co.bad = true; // `new` needs a project name
            }
        },
        MODE_INIT => {
            if i < argc {
                co.bad = true; // `init` scaffolds the current directory, no arguments
            }
        },
        MODE_VENDOR => {
            while i < argc {
                let arg = argv[i];
                if arg.starts_with("--dir=") {
                    vendor_dir = arg[6..];
                } else if arg.starts_with("--ref=") {
                    vendor_ref = arg[6..];
                } else if arg == "--force" {
                    vendor_force = true;
                } else if !arg.starts_with("--") && file.len() == 0 {
                    file = arg; // the source: a git url or a local directory
                } else if !arg.starts_with("--") && vendor_name.len() == 0 {
                    vendor_name = arg;
                } else {
                    co.bad = true;
                }
                i = i + 1;
            }
            if file.len() == 0 {
                co.bad = true; // `vendor` needs a source
            }
        },
        MODE_BINDGEN => {
            while i < argc {
                let arg = argv[i];
                if arg == "-o" && i + 1 < argc {
                    i = i + 1;
                    out_bin = argv[i];
                } else if arg.starts_with("--link=") {
                    bg_link = arg[7..];
                } else if arg.starts_with("--header=") {
                    bg_header = arg[9..];
                } else if arg.starts_with("--from=") {
                    bg_from.push(String::from_str(arg[7..]));
                } else if arg.starts_with("--cflag=") {
                    bg_cflags.push(String::from_str(arg[8..]));
                } else if arg.starts_with("-I") && arg.len() > 2 {
                    bg_incs.push(String::from_str(arg[2..]));
                } else if arg == "-I" && i + 1 < argc {
                    i = i + 1;
                    bg_incs.push(String::from_str(argv[i]));
                } else if arg.starts_with("--cc=") {
                    bo.cc = arg[5..];
                } else if !arg.starts_with("-") {
                    // Like fmt/lint: the first path lands in `file`, the rest in `extra`.
                    if file.len() == 0 {
                        file = arg;
                    } else {
                        extra.push(i);
                    }
                } else {
                    co.bad = true;
                }
                i = i + 1;
            }
            if file.len() == 0 {
                co.bad = true; // `bindgen` needs a header or a directory
            }
        },
    };
    if !topts.enabled && (topts.jobs != 0 || topts.no_fork || topts.filter != null) {
        co.bad = true;
    }
    // `build` with a .spc root is the direct emit+link mode; without one it reads build.toml
    let manifest_mode = (mode == Mode::MODE_BUILD || mode == Mode::MODE_RELEASE) && file.len() == 0 || mode == Mode::MODE_COMMAND || mode == Mode::MODE_RUN || mode == Mode::MODE_CLEAN || mode == Mode::MODE_TEST || mode == Mode::MODE_BENCH;
    // cargo-style manifest discovery: a manifest command run from a subdirectory walks up to the
    // nearest build.toml and works from there
    if manifest_mode {
        chdir_to_manifest();
    }
    // Only a script needs a path of its own: every other mode either reads build.toml, needs no
    // input at all (lsp), or discovers the project itself (fmt/lint).
    if co.bad || file.len() == 0 && mode == Mode::MODE_DEFAULT {
        unsafe stdio::fputs(
            r#"super-c — a systems language that compiles to readable C

USAGE:
    super-c <file.spc> [options]      compile and run a script
    super-c <command> [options]

COMMANDS:
    build   [<dir/file>]   emit C and link a binary (uses build.toml if no file)
    release [<dir/file>]   like build, with the release profile (-O3 -flto)
    run                    build the project and run its binary
    test                   build and run the test suite (tests/ by convention)
    bench                  build and run the benchmarks (bench/ by convention)
    command <name>         run a [command.NAME] from build.toml
    clean [--cache]        remove build outputs (--cache: the global object cache too)
    fmt  [<path>...]       format source in place (or verify with --check)
    lint [<path>...]       report lint warnings (apply fixes with --fix)
    lsp                    run the language server over stdio
    new <name>             scaffold a new project directory
    init                   scaffold a project in the current directory
    vendor <src> [name]    copy a git repository or a local folder into vendor/<name>
    bindgen <path>...      generate extern "C" modules from C headers (a directory recurses)

OPTIONS:
    -o <path>              output binary path (build/release with a file)
    --profile=P            build profile: debug|dev|release|bench, or a custom one
    --out-dir=D            output directory (default: build)
    --jobs=N               parallel C compile jobs (default: one per core)
    --cstd=F               C standard passed to the C compiler
    --cc=BIN               C compiler to use (else build.toml `cc`, else $CC, else cc)
    --bin=NAME             build/run only that binary target
    --lib                  build only the [lib] target
    --link=NAME            bindgen: library the generated bindings link against
    --header=SPELLING      bindgen: how the generated module spells the #include
    -I <dir>               bindgen: header search path
    --from=PART            bindgen: also take declarations from headers whose path contains PART
    --cflag=F              bindgen: extra flag for the preprocessor invocation (repeatable)
    --target=T             target: windows|macos|linux|ios|android|wasm
    --arch=A               instruction set: x86_64|aarch64|wasm32 (default: the target's)
    --const-eval-steps=N   compile-time evaluation step budget
    --const-eval-memory=B  compile-time evaluation memory budget (B, or NK/NM/NG)
    --no-lint              disable the on-by-default lints during a build
    --check                fmt: report unformatted files, write nothing
    --fix                  lint: apply machine-applicable fixes and re-lint
    --suggest-const        lint: also flag functions that could be 'const fn'
    --no-run               bench: build the bench binary but do not run it
    --dir=D                vendor: project root vendored into (default: the current directory)
    --ref=R                vendor: branch, tag or commit to pin (git sources)
    --force                vendor: replace an existing vendor/<name>
    --test                 script: collect @test functions, build, and run
    --test-filter=S        run only tests whose name contains S
    --test-jobs=N          bound the test process pool (default: one per core)
    --test-no-fork         run tests in-process (for a debugger)
"#.ptr() as *const char,
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
    // fmt/lint take any number of paths; with none, the project discovers itself.
    let mut paths = Vector::<String>::new();
    if mode == Mode::MODE_FMT || mode == Mode::MODE_LINT {
        if file.len() == 0 {
            paths = project_paths();
        } else {
            paths.push(String::from_str(file));
            for k in 0..extra.len() {
                paths.push(String::from_str(argv[*extra.at(k)]));
            }
        }
    }
    if mode == Mode::MODE_NEW {
        if is_dir(file) {
            eprintln("new: '{}' already exists", file);
            return 1;
        }
        return bsys::scaffold_project(file, file);
    }
    if mode == Mode::MODE_VENDOR {
        return bsys::vendor_dep(vendor_dir, file, vendor_name, vendor_ref, vendor_force);
    }
    if mode == Mode::MODE_BINDGEN {
        let mut bg_paths = Vector::<String>::new();
        bg_paths.push(String::from_str(file));
        for k in 0..extra.len() {
            bg_paths.push(String::from_str(argv[*extra.at(k)]));
        }
        let rc = bindgen::run(&bg_paths, out_bin, bg_link, bg_header, &bg_incs, &bg_from, &bg_cflags, bo.cc);
        bg_paths.free();
        bg_incs.free();
        bg_from.free();
        bg_cflags.free();
        return rc;
    }
    if mode == Mode::MODE_INIT {
        let cwd = canon_cwd();
        let name = cwd.as_str();
        let mut k = name.len();
        while k > 0 && name[k - 1] != b'/' {
            k = k - 1;
        }
        return bsys::scaffold_project(".", name.slice(k, name.len()));
    }
    if mode == Mode::MODE_FMT {
        let mut rc = 0;
        for k in 0..paths.len() {
            if run_fmt(paths.at(k).as_str(), fmt_check) != 0 {
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
        let mut rc = 0;
        if lint_alt().len() != 0 {
            // Manifest layout: every path resolves against the project root, so ALL listed paths share
            // one closure -- collect them into a single package and run the pipeline once.
            let mut files = Vector::<String>::new();
            for k in 0..paths.len() {
                let pa = paths.at(k).as_str();
                if unsafe shim::sc_stat_isdir(pa.ptr() as *const char) == 1 {
                    if lint_collect(pa, &mut files) != 0 {
                        rc = 1;
                    }
                } else {
                    files.push(String::from_str(pa));
                }
            }
            // whole-workspace lint of a lib-less manifest: unreachable pub functions are findings
            let mut lpub = false;
            let mo = bman::load("build.toml");
            if !mo.is_none() {
                let man = mo.unwrap();
                lpub = man.lib_name.len() == 0;
            }
            if files.len() != 0 && lint_batch(&files, ".", std_dir, ce_steps, ce_mem, target, lint_fix, lint_sc, lpub) != 0 {
                rc = 1;
            }
        } else {
            for k in 0..paths.len() {
                if run_lint(paths.at(k).as_str(), std_dir, ce_steps, ce_mem, target, lint_fix, lint_sc) != 0 {
                    rc = 1;
                }
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
            man.arch = co.arch; // --arch= (else the host) is the axis `@arch` gates on
            man.sdk = target_sdk(target); // --target=ios|android|wasm picks the cross toolchain
            // CLI --const-eval-* wins; else the manifest's value; else (0) the engine default.
            // Capture the CLI values under fresh names -- shadowing `ce_steps` with an initializer
            // that reads `ce_steps` would resolve to the new (uninitialized) binding.
            let cli_steps = ce_steps;
            let cli_mem = ce_mem;
            let ce_steps = if cli_steps != 0 {
                cli_steps;
            } else {
                man.ce_steps;
            };
            let ce_mem = if cli_mem != 0 {
                cli_mem;
            } else {
                man.ce_mem;
            };
            if out_dir.len() != 0 {
                man.out_dir = String::from_str(out_dir);
            }
            if cstd.len() != 0 {
                man.cstd = String::from_str(cstd);
            }
            if bo.cc.len() != 0 {
                man.cc = String::from_str(bo.cc);
            }
            if mode == Mode::MODE_CLEAN {
                rc = bsys::manifest_clean(&man);
                if clean_cache {
                    let cd = bsys::object_cache_dir();
                    if cd.len() != 0 {
                        bsys::rm_rf(cd.as_str());
                        println("removed {}", cd.as_str());
                    }
                }
            } else if mode == Mode::MODE_TEST {
                topts.enabled = true;
                rc = bsys::manifest_test(&man, profile, jobs, &topts, std_dir, ce_steps, ce_mem, target, bootstrap_tags);
            } else if mode == Mode::MODE_BENCH {
                rc = bsys::manifest_bench(
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
            } else if mode == Mode::MODE_COMMAND {
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
            } else if mode == Mode::MODE_RUN {
                // cargo run: build the manifest binary and exec it
                rc = bsys::manifest_run_bin(
                    &man,
                    profile,
                    out_bin,
                    bo.bin_sel,
                    jobs,
                    std_dir,
                    ce_steps,
                    ce_mem,
                    target,
                    bootstrap_tags,
                    lint,
                );
            } else if out_bin.len() != 0 {
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
            } else {
                rc = bsys::manifest_build_all(
                    &man,
                    profile,
                    bo.bin_sel,
                    bo.lib_sel,
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
    // No manifest here, so the profile the CLI asked for has to be resolved from the built-ins -- without
    // this a `super-c release foo.spc` linked with no -O at all while reporting success.
    let pflags = bsys::profile_flags(profile, target, target_sdk(target));
    let rc = run_file(
        file,
        std_dir,
        ce_steps,
        ce_mem,
        &topts,
        out_bin,
        target,
        co.arch,
        bootstrap_tags,
        lint,
        pflags.as_str(),
    );
    if std_dir != null {
        unsafe stdlib::free(std_dir);
    }
    return rc;
}
