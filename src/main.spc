import stdio;
import stdlib;
import lexer::lexer as lex;
import ast::ast as *;
import ast::parser as par;
import fmt::builder as fbld;
import driver_shim as shim;
import std::platform::fs;
import std::platform::path;
import std::platform::process;
import std::parallel::runtime as prt;
import module::loader as loader;
import resolver::resolver as resolver;
import target::table as tgt;
import typechecker::typechecker as tc;
import ir::interp as iri;
import utils::errors as diag;
import driver::util as *;
import driver::extc as *;
import driver::test as *;
import driver::emit as *;
import build_system::manifest as bman;
import build_system::build as bsys;
import build_system::objcache as ocache;
import lsp::server as lsp_srv;
import bindgen::bindgen as bindgen;
import driver::taskctl as tctl;
import ir::cpu_features as cf;

fn run_file(
    path: str,
    std_dir: str,
    ce_steps: u32,
    ce_mem: u64,
    topts: *const TestOpts,
    out_bin: str,
    target: i32,
    arch: i32,
    features: cf::CpuFeatureSet,
    simd_width: u32,
    simd_dispatch: str,
    bootstrap_tags: bool,
    lint: bool,
    cflags: str,
    ccflags: str,
    jobs: u32,
    out_dir: str,
    cc: str,
    cstd: str,
    profile: str,
) i32 {
    // The modules whose bodies render though the native backend may take them: each run gets the names
    // every earlier one returned with RC_NATIVE_RETRY. A run names only modules that did not render, so
    // the runs end within one per module.
    let mut retry = Vector::<String>::new();
    let mut rc: i32 = 1;
    loop {
        loader::set_load_jobs(jobs);
        let tl0 = ticks_ms();
        // The build settings the prelude's build constants spell, set before the load.
        let mut p = loader::package_new(loader::dirname_of(path), "", std_dir);
        p.arch = arch;
        p.features = features;
        p.simd_width = pick(simd_width != 0, simd_width, 256);
        let bi = bman::builtins_only();
        p.simd_dispatch = String::from_str(bsys::dispatch_for(&bi, profile, simd_dispatch));
        p.mem_check = bsys::mem_checker(cflags);
        p.build_cfg = bsys::build_cfg(cflags);
        p.test_build = unsafe (*topts).enabled;
        p.profile = String::from_str(profile);
        p.profiles = bsys::profile_names(&bi);
        p.bootstrap = bootstrap_tags;
        let mut cirv = iri::interp_master((&mut p) as *mut loader::Package, ce_steps, ce_mem);
        let cdir = ocache::object_cache_dir("");
        if prelude_stage(&mut p, &mut cirv, std_dir, path, target, jobs, ce_steps, ce_mem, cdir.as_str()) {
            p.load_user(path, std_dir, target);
        }
        if stdlib::getenv("SC_CEMIT_STATS") != null {
            eprintln("phase load: {} ms", ticks_ms() - tl0);
        }
        loader::set_load_jobs(1);
        // `--out-dir`, `--cc` and `--cstd` apply to a bare build exactly as to a manifest one: the emitted tree
        // goes under the named directory, and the named compiler builds the program with the named base flags.
        if out_dir.len() != 0 {
            let mut g = String::from_str(out_dir);
            g.push_byte(b'/');
            g.push_str(p.profile_name());
            g.push_str("/raw");
            p.gen_root = g;
        }
        if cc.len() != 0 {
            p.cc = String::from_str(cc);
        }
        if cstd.len() != 0 {
            p.cstd = String::from_str(cstd);
        }
        // A standalone script is a binary with no test suite to count as callers: unreachable pub
        // functions are dead weight. Project trees get this from the whole-workspace lint instead,
        // where @test roots keep test-only helpers alive.
        let manf = stdio::fopen("build.toml", "rb");
        if manf != null {
            unsafe stdio::fclose(manf);
        } else {
            p.lint_pub = lint;
        }
        rc = 1;
        if !p.ok && jobs != 1 {
            prt::shutdown(); // parallel loading started the pool; the leak gate needs it gone
        }
        if p.ok {
            p.jobs = p.analysis_jobs(jobs);
            if p.jobs == 1 && jobs != 1 {
                prt::shutdown(); // parallel loading may have started the pool
                // A serial compile hands its slots back.
                unsafe shim::sc_jobserver_release_claim();
            }
            p.cir = &mut cirv;
            // One process builds a tree at a time, as in a manifest build.
            default_gen_root(&mut p);
            let lk = bsys::tree_lock(loader::dirname_of(p.gen_root.as_str()));
            if lk.held() {
                p.nat_retry = retry.clone();
                rc = run_package(&mut p, topts, out_bin, target, lint, cflags, ccflags, null);
                if rc == RC_NATIVE_RETRY {
                    while let Some(x) = p.nat_retry.pop() {
                        retry.push(x);
                    }
                    assert(retry.len() <= p.modules.len(), "native: each run renders a module no earlier one did");
                }
            }
        }
        if rc != RC_NATIVE_RETRY {
            break;
        }
    }
    return rc;
}

// Parse the one-based K/N used by --test-shard. Both numbers must consume the full argument.
fn parse_test_shard(s: *const char, topts: &mut TestOpts) bool {
    let mut slash: *mut char = null;
    let shard = unsafe stdlib::strtoul(s, &mut slash, 10);
    if slash as usize == s as usize || unsafe *slash != '/' as char {
        return false;
    }
    let next = unsafe (slash + 1);
    let mut endp: *mut char = null;
    let shards = unsafe stdlib::strtoul(next, &mut endp, 10);
    if endp as usize == next as usize || unsafe *endp != 0 as char || shard < 1 || shard > shards || shards > 2147483647 {
        return false;
    }
    topts.shard = shard as i32;
    topts.shards = shards as i32;
    return true;
}

fn parse_test_flag(arg: str, topts: &mut TestOpts, bad: &mut bool) bool {
    if arg.starts_with("--test-jobs=") {
        topts.jobs = unsafe stdlib::atoi(((&arg[12]) as *const u8) as *const char);
        if topts.jobs < 1 {
            *bad = true;
        }
    } else if arg.starts_with("--test-timeout=") {
        let digits = (unsafe (arg.ptr() + 15)) as *const char; // argv text: NUL-terminated
        let mut endp: *mut char = null;
        let v = unsafe stdlib::strtoul(digits, &mut endp, 10);
        if endp as usize == digits as usize || unsafe *endp != 0 as char || v > 2147483647 {
            *bad = true;
        } else {
            topts.timeout = v as i32;
        }
    } else if arg == "--test-record-durations" {
        topts.record = true;
    } else if arg.starts_with("--test-record-durations=") && arg.len() > 24 {
        topts.record = true;
        topts.record_to = ((&arg[24]) as *const u8) as *const char;
    } else if arg.starts_with("--test-durations=") && arg.len() > 17 {
        topts.durations = ((&arg[17]) as *const u8) as *const char;
    } else if arg == "--test-no-fork" {
        topts.no_fork = true;
    } else if arg == "--quiet" {
        topts.quiet = true;
    } else if arg.starts_with("--filter=") {
        topts.filter = ((&arg[9]) as *const u8) as *const char;
    } else if arg.starts_with("--test-shard=") {
        if !parse_test_shard(((&arg[13]) as *const u8) as *const char, topts) {
            *bad = true;
        }
    } else {
        return false;
    }
    return true;
}

// The std/ directory next to the running binary ("<exe dir>/std"), so the prelude is found regardless of cwd;
// `SC_STD_DIR` names it instead (`super-c test` sets it for the compiler under test, see build.spc).
fn exe_std_dir(argv0: *const char) String {
    let ov = stdlib::get_env("SC_STD_DIR").unwrap_or(String::new());
    if ov.len() != 0 {
        return ov;
    }
    let exe = exe_path();
    let path = if exe.len() != 0 {
        exe.as_str();
    } else {
        unsafe str::from_cstr(argv0);
    };
    // Last path separator, '/' or '\\' (Windows), whichever occurs later.
    let mut slash = path.len();
    while slash > 0 && path.byte_at(slash - 1) != b'/' && path.byte_at(slash - 1) != b'\\' {
        slash -= 1;
    }
    let mut base = String::new();
    if slash != 0 {
        base.push_str(path.slice(0, slash - 1));
    } else {
        base.push_str(".");
    }
    // Std lives beside the compiler, but not always DIRECTLY beside it: a profile build sits two levels
    // down in <out-dir>/<profile>/, so try the parents before giving up. First 'std' directory wins.
    let mut cut = base.len();
    for _up in 0..3 {
        let mut probe = String::with_capacity(cut + 4);
        probe.push_str(unsafe str::from_raw(base.as_str().ptr(), cut));
        probe.push_str("/std");
        if is_dir(probe.as_str()) {
            return probe;
        }
        let mut k = cut;
        while k > 0 && base.as_str().byte_at(k - 1) != b'/' {
            k = k - 1;
        }
        if k <= 1 {
            break;
        }
        cut = k - 1;
    }
    // Nothing found: answer with the one next to the binary, so a failure names the obvious place.
    base.push_str("/std");
    return base;
}

fn read_stdin() String {
    let mut s = String::new();
    let cap: usize = 65536;
    let mut buf = Vector::<u8>::new();
    buf.resize_default(cap);
    let sin = stdio::stdin();
    loop {
        let n = unsafe stdio::fread(buf.as_ptr() as *mut u8, 1, cap, sin);
        if n > 0 {
            s.push_bytes(buf[0..n]);
        }
        if n < cap {
            break;
        }
    }
    return s;
}

// The entries of `dir` in name order, without the dot-entries (".", "..", hidden); None when the
// directory cannot be read.
fn dir_entries(dir: str) Option<Vector<String>> {
    let lo = list_dir(dir, false);
    if lo.is_none() {
        return lo;
    }
    let mut names = lo.unwrap();
    names.sort();
    return Option::<Vector<String>>::Some(names);
}

// `fmt`/`lint` with no path: every top-level entry of the project, minus the build output; it
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
            let mo = bman::load("build.toml", false);
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
        if is_dir(probe.as_str()) || n.ends_with(".spc") {
            out.push(String::from_str(n));
        }
    }
    return out;
}

// `lint` of `paths` from the working directory: build.toml's target settings, then the command line's.
// `whole`: the paths are the whole project (`project_paths`), so every caller of an item is loaded.
fn lint_project(
    paths: &Vector<String>,
    whole: bool,
    co: &CommonOpts,
    bo: &BuildOpts,
    cpu_set: cf::CpuFeatureSet,
    std_dir: str,
    fix: bool,
    sc: bool,
) i32 {
    // The instruction set's gates and the features' rules apply as in a build: build.toml's, when
    // there is one, then the command line's.
    let mut lf = cpu_set;
    let mut lerr = String::new();
    let lm = if has_manifest(".") {
        bman::load("build.toml", false);
    } else {
        Option::<bman::Manifest>::None;
    };
    if !lm.is_none() {
        let mut man = lm.unwrap();
        man.arch = co.arch;
        man.target = co.target;
        if co.target_cpu.len() != 0 {
            man.target_cpu = co.target_cpu.clone();
        }
        if !bsys::check_features(&man, co.target_features.as_str()) {
            return 1;
        }
        lf = bsys::features_for(&man, bo.profile, co.target_features.as_str());
    } else if !cf::apply(co.target_features.as_str(), co.target, co.arch, true, &mut lf, &mut lerr) {
        eprintln("error: {}", lerr.as_str());
        return 1;
    }
    loader::set_load_target(co.arch, cf::close(lf));
    let mut rc = 0;
    // A directory with its own build.toml, listed or found below a listed one, is another project:
    // it lints below, from its own directory.
    let mut nested = Vector::<String>::new();
    if lint_alt().len() != 0 {
        // Manifest layout: every path resolves against the project root, so ALL listed paths share
        // one closure: collect them into a single package and run the pipeline once.
        let mut files = Vector::<String>::new();
        for k in 0..paths.len() {
            let pa = paths.at(k).as_str();
            if is_dir(pa) && pa != "." && has_manifest(pa) {
                nested.push(String::from_str(pa));
            } else if is_dir(pa) {
                if spc_collect_in(pa, "lint", &mut files, &mut nested) != 0 {
                    rc = 1;
                }
            } else {
                files.push(String::from_str(pa));
            }
        }
        // Whole-workspace lint of a lib-less manifest: unreachable pub functions are findings. Listed
        // files load without the modules that import them, so their pub items stay roots there.
        let mut lpub = false;
        let mo = bman::load("build.toml", false);
        if whole && !mo.is_none() {
            let man = mo.unwrap();
            lpub = man.lib_name.len() == 0;
        }
        // A file whose imports a load rooted at the project does not find is a standalone program
        // (`tools/x/main.spc` importing its sibling `util`): its imports resolve beside it, as
        // `super-c build <file>` resolves them, so its directory, the siblings it imports included,
        // lints as its own batch.
        let mut alone_dirs = Vector::<String>::new();
        for k in 0..files.len() {
            let f = files.at(k).as_str();
            let d = String::from_str(loader::dirname_of(f));
            if !loader::imports_resolve(f, ".", lint_alt(), std_dir) && !alone_dirs.contains(&d) {
                alone_dirs.push(d);
            }
        }
        let mut rooted = Vector::<String>::new();
        let mut alone = Vector::<Vector<String>>::new();
        alone.resize_default(alone_dirs.len());
        for k in 0..files.len() {
            let f = files.at(k).as_str();
            let mut g = alone_dirs.len();
            for j in 0..alone_dirs.len() {
                if alone_dirs.at(j).as_str() == loader::dirname_of(f) {
                    g = j;
                }
            }
            if g == alone_dirs.len() {
                rooted.push(String::from_str(f));
            } else {
                alone.index_mut(g).push(String::from_str(f));
            }
        }
        if rooted.len() != 0 && lint_batch(
            &rooted,
            ".",
            lint_alt(),
            std_dir,
            co.ce_steps,
            co.ce_mem,
            co.target,
            fix,
            sc,
            lpub,
        ) != 0 {
            rc = 1;
        }
        for g in 0..alone_dirs.len() {
            if lint_batch(
                alone.at(g),
                alone_dirs.at(g).as_str(),
                "",
                std_dir,
                co.ce_steps,
                co.ce_mem,
                co.target,
                fix,
                sc,
                lpub,
            ) != 0 {
                rc = 1;
            }
        }
    } else {
        // No `src/`: each listed path lints alone, a directory as one batch rooted at itself, a file
        // with its imports beside it.
        for k in 0..paths.len() {
            let pa = paths.at(k).as_str();
            if is_dir(pa) && pa != "." && has_manifest(pa) {
                nested.push(String::from_str(pa));
            } else if is_dir(pa) {
                let mut files = Vector::<String>::new();
                if spc_collect_in(pa, "lint", &mut files, &mut nested) != 0 {
                    rc = 1;
                }
                if lint_batch(&files, pa, "", std_dir, co.ce_steps, co.ce_mem, co.target, fix, sc, false) != 0 {
                    rc = 1;
                }
            } else if lint_one(pa, "", std_dir, co.ce_steps, co.ce_mem, co.target, fix, sc) != 0 {
                rc = 1;
            }
        }
    }
    // A nested project lints as from its own directory: its manifest, its imports.
    let home = canon_cwd();
    for k in 0..nested.len() {
        let nd = nested.at(k).clone();
        if process::set_current_dir(nd.as_str()).is_err() {
            eprintln("lint: cannot enter '{}'", nd.as_str());
            rc = 1;
            continue;
        }
        let np = project_paths();
        if lint_project(&np, true, co, bo, cpu_set, std_dir, fix, sc) != 0 {
            eprintln("lint: the findings above are in the project '{}'", nd.as_str());
            rc = 1;
        }
        assert(process::set_current_dir(home.as_str()).is_ok(), "lint: cannot return to the working directory");
    }
    return rc;
}

// Format every .spc under `dir` (spc_collect order). Returns 1 if a directory could not be read, a
// file failed, or (--check) a file needs formatting, else 0.
fn fmt_dir(dir: str, write: bool, check: bool) i32 {
    let mut files = Vector::<String>::new();
    let mut rc = spc_collect(dir, "fmt", &mut files);
    for i in 0..files.len() {
        if fmt_one(files.at(i).as_str(), false, write, check) != 0 {
            rc = 1;
        }
    }
    return rc;
}

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
// kind 2 inserts 'const ' before start, kind 4 replaces [start, end) with fix_texts[text]. An overlapping fix is skipped: the next `--fix` re-lint pass
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
// The directory `super-c test` discovers the suite in: build.toml's `test-dir`, else `tests`.
fn lint_test_dir() String {
    if has_manifest(".") {
        let mo = bman::load("build.toml", false);
        if !mo.is_none() {
            return mo.unwrap().test_dir.clone();
        }
    }
    return String::from_str("tests");
}

// Whether path `f` lies under directory `d` (both relative to the working directory, `./` aside).
const fn in_dir(f: str, d: str) bool {
    let fp = pick(f.starts_with("./"), f.slice(2, f.len()), f);
    let dp = pick(d.starts_with("./"), d.slice(2, d.len()), d);
    return dp.len() != 0 && fp.len() > dp.len() && fp.starts_with(dp) && fp.byte_at(dp.len()) == b'/';
}

fn lint_alt() str<'static> {
    if is_dir("src") {
        return "src";
    }
    return "";
}

// The manifest settings of a lint run on `p`: the profiles a PROFILE comparison may name (the manifest's,
// else the built-ins) and `std_internals`.
fn lint_settings(p: &mut loader::Package) {
    let manf = stdio::fopen("build.toml", "rb");
    if manf != null {
        unsafe stdio::fclose(manf);
        let mo = bman::load("build.toml", false);
        if !mo.is_none() {
            let man = mo.unwrap();
            p.profiles = bsys::profile_names(&man);
            p.std_internals = man.std_internals;
            return;
        }
    }
    let bi = bman::builtins_only();
    p.profiles = bsys::profile_names(&bi);
}

// One lint pass over the loaded package `p`, reporting as lint_package with `lint_mod`. Without
// `fix`: the exit code. With `fix` (quiet): 1 on an error or a failed write; else, when `apply`, the
// machine fixes are written (each fixed file reformatted: canonicalization can unlock paren-guarded
// fixes) and the result is 2 if any was written; else 0.
fn lint_pass(
    p: &mut loader::Package,
    target: i32,
    lint_mod: usize,
    ce_steps: u32,
    ce_mem: u64,
    fix: bool,
    apply: bool,
    sc: bool,
) i32 {
    // Parallel analysis; resolves to 1 on wasm.
    p.jobs = p.analysis_jobs(bsys::cpu_count());
    if p.jobs == 1 {
        prt::shutdown(); // parallel loading may have started the pool
    }
    lint_settings(p);
    let mut cirv = iri::interp_master(p as *mut loader::Package, ce_steps, ce_mem);
    p.cir = &mut cirv;
    let mut rc = 0;
    let mut fixes = Vector::<diag::LintFix>::new();
    let mut ftexts = Vector::<String>::new();
    if !fix {
        rc = lint_package(p, target, lint_mod, null, null, sc);
    } else {
        lint_package(p, target, lint_mod, &mut fixes, &mut ftexts, sc);
        if !p.ok {
            rc = 1;
        }
    }
    let mut written = false;
    let mut werr = false;
    for m in 0..p.modules.len() {
        if rc != 0 || !apply {
            break;
        }
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
        if write_source(p.modules[m].file.as_str(), out.as_str()) {
            fmt_one(p.modules[m].file.as_str(), false, true, false);
            written = true;
        } else {
            eprintln("lint: cannot write '{}'", p.modules[m].file.as_str());
            werr = true;
        }
    }
    p.cir = null; // `cirv` ends here
    if werr {
        return 1;
    }
    if written {
        return 2;
    }
    return rc;
}

fn lint_one(path: str, root: str, std_dir: str, ce_steps: u32, ce_mem: u64, target: i32, fix: bool, sc: bool) i32 {
    // A std/ffi file must keep its prelude identity (module path, builtin seeding, load order):
    // loading it as a root would invent errors. Load an empty root (the prelude comes along as
    // always) and if the requested file IS one of those modules, lint it in place.
    // `--fix`: quiet fixpoint loop (re-lint after each write, capped) that REJECTS (writes nothing)
    // if the package has any error a machine fix cannot repair (when EVERY error carries a fix, e.g.
    // the generated-Free leak fix, applying is the way out); a final plain pass prints what remains
    // and sets the exit code.
    let mut pass = 0;
    loop {
        let mut p = loader::package_from_source("", std_dir, target);
        let mut lint_mod = p.modules.len(); // the appended empty root; replaced below
        let mut found = false;
        for m in 0..p.modules.len() {
            if p.modules[m].has_ast && same_file(path, p.modules[m].file.as_str()) {
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
        let rc = lint_pass(&mut p, target, lint_mod, ce_steps, ce_mem, fix, pass < 8, sc);
        if rc == 1 || !fix {
            return rc;
        }
        if rc == 0 {
            break;
        }
        pass = pass + 1;
    }
    return lint_one(path, root, std_dir, ce_steps, ce_mem, target, false, sc);
}

// Collect every .spc under `dir` recursively, in dir_entries order (dot-entries skipped). Returns 1
// when a directory cannot be read (reported as a `cmd` error), else 0.
fn spc_collect(dir: str, cmd: str, files: &mut Vector<String>) i32 {
    return spc_collect_in(dir, cmd, files, null);
}

// Directory `dir` holds a build.toml: it is a project of its own.
fn has_manifest(dir: str) bool {
    let mut man = String::from_str(dir);
    man.push_str("/build.toml");
    return fs::stat(man.as_str()).map(|m: fs::Metadata| m.kind != fs::FileKind::Dir).unwrap_or(false);
}

// `spc_collect`; with `nested`, a subdirectory holding its own build.toml is another project: its path
// goes to `nested` and its files are not collected (its imports resolve against itself).
fn spc_collect_in(dir: str, cmd: str, files: &mut Vector<String>, nested: *mut Vector<String>) i32 {
    let eo = dir_entries(dir);
    if eo.is_none() {
        eprintln("{}: cannot read directory '{}'", cmd, dir);
        return 1;
    }
    let names = eo.unwrap();
    let mut rc = 0;
    for i in 0..names.len() {
        let mut p = String::from_str(dir);
        p.push_byte(b'/');
        p.push_string(names.at(i));
        if is_dir(p.as_str()) {
            if nested != null && has_manifest(p.as_str()) {
                unsafe (*nested).push(p);
            } else if spc_collect_in(p.as_str(), cmd, files, nested) != 0 {
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
fn lint_load_batch(files: &Vector<String>, root: str, alt: str, std_dir: str, target: i32, test_build: bool) loader::Package {
    let mut p = loader::package_load_prelude_as(
        root,
        alt,
        std_dir,
        target,
        test_build,
        Vector::<String>::new(),
        Vector::<String>::new(),
    );
    let mut mids = Vector::<i32>::new();
    for k in 0..files.len() {
        let fc = files.at(k).as_str();
        let base = loader::basename_of(fc);
        // Already present? (a prelude module, or pulled in by an earlier file's imports). The basename
        // compare needs no syscall, so the file-identity check runs only on the rare collisions.
        let mut mid: i32 = -1;
        for m in 0..p.modules.len() {
            if p.modules[m].has_ast && loader::basename_of(p.modules[m].file.as_str()) == base && same_file(
                fc,
                p.modules[m].file.as_str(),
            ) {
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
    set.resize_default(p.modules.len());
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
// size. `--fix` runs the same quiet fixpoint as lint_one (one package per round, every module's fixes
// applied together, LintFix.module groups them) with the same reject rule: nothing is written while
// the package has an error a machine fix cannot repair.
fn lint_batch(
    files: &Vector<String>,
    root: str,
    alt: str,
    std_dir: str,
    ce_steps: u32,
    ce_mem: u64,
    target: i32,
    fix: bool,
    sc: bool,
    lint_pub: bool,
) i32 {
    // A batch with a file of the test suite lints as `super-c test` builds it: with TEST set.
    let mut test_build = false;
    let td = lint_test_dir();
    let cwd = canon_cwd();
    for k in 0..files.len() {
        let f = files.at(k).as_str();
        let rel = if f.starts_with(cwd.as_str()) && f.len() > cwd.len() && f.byte_at(cwd.len()) == b'/' {
            f.slice(cwd.len() + 1, f.len());
        } else {
            f;
        };
        test_build = test_build || in_dir(rel, td.as_str());
    }
    let mut pass = 0;
    loop {
        let mut p = lint_load_batch(files, root, alt, std_dir, target, test_build);
        p.lint_pub = lint_pub;
        if !p.ok {
            return 1;
        }
        let rc = lint_pass(&mut p, target, 0, ce_steps, ce_mem, fix, pass < 8, sc);
        if rc == 1 || !fix {
            return rc;
        }
        if rc == 0 {
            break;
        }
        pass = pass + 1;
    }
    // A final plain pass prints what remains and sets the exit code.
    return lint_batch(files, root, alt, std_dir, ce_steps, ce_mem, target, false, sc, lint_pub);
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
    if is_dir(path) {
        return fmt_dir(path, !check, check);
    }
    return fmt_one(path, false, !check, check);
}

// Replace a source file through a temp file and a rename, so a failed write leaves it intact. The link
// target is replaced when `path` is a symlink, never the link itself.
fn write_source(path: str, body: str) bool {
    if let Ok(abs) = fs::realpath(path) {
        return write_file_atomic(abs.as_str(), body);
    }
    return write_file_atomic(path, body);
}

fn fmt_one(path: str, is_stdin: bool, write: bool, check: bool) i32 {
    let mut src = String::new();
    if is_stdin {
        src = read_stdin();
    } else {
        let r = loader::read_file(path);
        if r.is_none() {
            eprintln("fmt: cannot read '{}'", path);
            return 1;
        }
        src = r.unwrap();
    }

    let mut out = String::new();
    if !format_source(&src, path, 120, &mut out) {
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
        if !same && !write_source(path, out.as_str()) {
            eprintln("fmt: cannot write '{}'", path);
            rc = 1;
        }
    } else {
        unsafe stdio::fwrite(out.as_str().ptr(), 1, out.len(), stdio::stdout());
    }
    return rc;
}

// CLI mode: `super-c <subcommand> <flags|args...>`; the subcommand is always the first argument;
// a non-keyword first argument means MODE_DEFAULT (compile a script).
// Declaration order is bman::subcommand_index order, shifted by one for MODE_DEFAULT.
enum Mode {
    MODE_DEFAULT, // `super-c <root.spc>`: compile (emit C; `--test` runs tests instead)
    MODE_BUILD, // `super-c build [<root.spc>] [-o out]`: emit + link a program (or build.toml)
    MODE_RELEASE, // `super-c release [<root.spc>] [-o out]`: emit + link a release profile program (or build.toml)
    MODE_FMT, // `super-c fmt [--check] [<path>...| -]` (no path: the whole project)
    MODE_LINT, // `super-c lint [--fix] [--const] [<path>...]` (no path: the whole project)
    MODE_COMMAND, // `super-c command <name>`: run a build.toml [command.NAME]
    MODE_RUN, // `super-c run [--profile=P]`: build the project, then execute its binary (cargo run)
    MODE_CLEAN, // `super-c clean [--full]`: sweep the global cache and build.toml outputs, or remove them
    MODE_TEST, // `super-c test`: tests/ by convention
    MODE_BENCH, // `super-c bench`: a generated runner over bench/'s `pub @bench` fns
    MODE_LSP, // `super-c lsp`: language server over stdio
    MODE_NEW, // `super-c new <name>`: scaffold a project directory (cargo new)
    MODE_INIT, // `super-c init`: scaffold a project in the current directory (cargo init)
    MODE_VENDOR, // `super-c vendor <git-url|dir> [name]`: copy a dependency into vendor/
    MODE_BINDGEN, // `super-c bindgen <header.h>`: C header -> an `extern "C"` module
}

const fn subcommand(arg: str) Mode {
    return (bman::subcommand_index(arg) + 1) as Mode;
}

// Flags accepted by every compiling mode.
struct CommonOpts {
    pub ce_steps: u32, // --const-eval-steps=N
    pub ce_mem: u64, // --const-eval-memory=BYTES[K|M|G]
    pub target: i32, // --target=windows|macos|linux|ios|android|wasm: @platform gate (default: host)
    pub arch: i32, // --arch=x86_64|aarch64|wasm32: @arch gate (default: the host's instruction set)
    pub bootstrap_tags: bool, // --bootstrap-tags: accept unknown @attributes and std intrinsics (build across a new tag)
    pub lint: bool, // on by default; --no-lint disables (unused vars/params/items, casts, unsafe)
    pub bad: bool, // malformed argument list: print usage and exit 1
    pub rejected: String, // the first argument the command does not take, named before the usage
    pub target_features: String, // --target-feature=+a,-b (repeated flags join in order)
    pub target_cpu: String, // --target-cpu=L: an x86-64 level before every feature list (the last flag wins)
    pub simd_width: u32, // --simd-width=256|512 (0: the manifest's)
    pub simd_dispatch: String, // --simd-dispatch=off|<x86-64 levels> (empty: the manifest's)
}

extend CommonOpts {
    fn reject(self: &mut Self, arg: str) {
        if self.rejected.len() == 0 {
            self.rejected.push_str(arg);
        }
        self.bad = true;
    }

    fn common_flag(self: &mut Self, arg: str) bool {
        if arg.starts_with("--const-eval-steps=") {
            let v = tctl::parse_size(arg[19..]).unwrap_or(0);
            if v == 0 || v > 4294967295u64 {
                self.bad = true;
            } else {
                self.ce_steps = v as u32;
            }
        } else if arg.starts_with("--const-eval-memory=") {
            self.ce_mem = tctl::parse_size(arg[20..]).unwrap_or(0);
            if self.ce_mem == 0 {
                self.bad = true;
            }
        } else if arg.starts_with("--target=") {
            let t = tgt::axis_index(arg[9..], false);
            if t < 0 {
                self.bad = true;
            } else {
                self.target = t;
                // A system with one usual instruction set picks it; another one keeps the host's, or takes
                // its first one where the host's is not one of its (a wasm-hosted compiler for Windows).
                let d = tgt::os(t).isa_default;
                if d >= 0 {
                    self.arch = d;
                } else if tgt::target_of(t, self.arch).is_none() {
                    for i in 0..tgt::axis_names(true).len() as i32 {
                        if tgt::target_of(t, i).is_some() {
                            self.arch = i;
                            break;
                        }
                    }
                }
            }
        } else if arg.starts_with("--arch=") {
            let a2 = tgt::axis_index(arg[7..], true);
            if a2 < 0 {
                self.bad = true;
            } else {
                self.arch = a2;
            }
        } else if arg.starts_with("--target-feature=") {
            if self.target_features.len() != 0 {
                self.target_features.push_byte(b',');
            }
            self.target_features.push_str(arg[17..]);
        } else if arg.starts_with("--target-cpu=") {
            self.target_cpu = String::from_str(arg[13..]);
        } else if arg.starts_with("--simd-width=") {
            self.simd_width = pick(arg[13..] == "512", 512u32, pick(arg[13..] == "256", 256u32, 0));
            self.bad = self.bad || self.simd_width == 0;
        } else if arg.starts_with("--simd-dispatch=") {
            self.simd_dispatch = String::from_str(arg[16..]);
            let mut e9 = String::new();
            if !cf::dispatch_ok(arg[16..], &mut e9) {
                eprintln("error: {}", e9.as_str());
                self.bad = true;
            }
        } else if arg == "--bootstrap-tags" {
            self.bootstrap_tags = true;
        } else if arg == "--no-lint" {
            self.lint = false;
        } else {
            return false;
        }
        return true;
    }
}

// build.toml engine flags, shared by build/run/test/bench (`clean` takes only --out-dir and --full).
struct BuildOpts<'a> {
    pub profile: str<'a>, // --profile=NAME (default: manifest default-profile)
    pub out_dir: str<'a>, // --out-dir=PATH: override the manifest's out-dir
    pub cstd: str<'a>, // --cstd=FLAGS: override the manifest's base C flags (CI: gnu11 on Windows)
    pub cc: str<'a>, // --cc=BIN: override the C compiler (else manifest `cc`, else $CC, else cc)
    pub jobs: u32, // --jobs=N (0 = manifest / core count)
    pub bin_sel: str<'a>, // --bin=NAME: build/run only that binary target
    pub lib_sel: bool, // --lib: build only the [lib] target
    pub sanitizers: bool, // --sanitizers: AddressSanitizer and UndefinedBehaviorSanitizer in every C build
}

extend<'a> BuildOpts<'a> {
    fn build_flag(self: &mut Self, co: &mut CommonOpts, arg: str<'a>) bool {
        if arg.starts_with("--profile=") {
            self.profile = arg[10..];
        } else if arg.starts_with("--out-dir=") {
            self.out_dir = arg[10..];
        } else if arg.starts_with("--cstd=") {
            self.cstd = arg[7..];
        } else if arg.starts_with("--cc=") {
            self.cc = arg[5..];
        } else if arg.starts_with("--bin=") {
            self.bin_sel = arg[6..];
        } else if arg == "--lib" {
            self.lib_sel = true;
        } else if arg == "--sanitizers" {
            self.sanitizers = true;
        } else if arg.starts_with("--jobs=") {
            let v = unsafe stdlib::atoi(((&arg[7]) as *const u8) as *const char);
            if v < 1 {
                co.bad = true;
            } else {
                self.jobs = v as u32;
            }
        } else {
            return false;
        }
        return true;
    }
}

fn canon_cwd() String {
    return fs::realpath(".").unwrap_or(String::from_str("."));
}

// Cargo-style manifest discovery: when the cwd has no build.toml, walk toward the filesystem root and
// chdir to the nearest directory that has one. A miss changes nothing: the caller reports it.
fn chdir_to_manifest() {
    if let Some(dir) = nearest_manifest() {
        let _ = process::set_current_dir(dir.as_str());
    }
}

// The nearest directory at or above the cwd that holds a build.toml ("." for the cwd), or None.
fn nearest_manifest() Option<String> {
    let probe = stdio::fopen("build.toml", "rb");
    if probe != null {
        unsafe stdio::fclose(probe);
        return Option::<String>::Some(String::from_str("."));
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
        // Drop the trailing '/'.
        end = end - 1;
        let dir = String::from_str(cwd.as_str().slice(0, end));
        let mut man = dir.clone();
        man.push_str("/build.toml");
        let f = stdio::fopen(man.as_str(), "rb");
        if f != null {
            unsafe stdio::fclose(f);
            return Option::<String>::Some(dir);
        }
    }
    return Option::<String>::None;
}

// The command-line usage, written to `out`.
fn print_usage(out: *mut stdio::FILE) {
    unsafe stdio::fputs(
        M"(super-c — a systems language that compiles to readable C

USAGE:
    super-c <file.spc> [options]      compile a script (emit C into build/)
    super-c <command> [options]

COMMANDS:
    build   [<dir/file>]   compile and link a binary (uses build.toml if no file)
    release [<dir/file>]   like build, with the release profile (-O3, link-time optimization)
    run                    build the project and run its binary
    test                   build and run the test suite (tests/ by convention)
    bench                  build and run the benchmarks (bench/ by convention)
    command <name>         run a [command.NAME] from build.toml
    clean [--full]         sweep the global cache and build/ (--full: delete both instead)
    fmt  [<path>...]       format source in place (or verify with --check)
    lint [<path>...]       report lint warnings (apply fixes with --fix)
    lsp                    run the language server over stdio
    new <name>             scaffold a new project directory
    init                   scaffold a project in the current directory
    vendor <src> [name]    copy a git repository or a local folder into vendor/<name>
    bindgen <path>...      generate extern "C" modules from C headers (a directory recurses)

OPTIONS:
    -h, --help             print this usage and exit
    -o <path>              output binary path (build/release with a file)
    --profile=P            build profile: debug|release|bench|test|race, or a custom one
    --sanitizers           add AddressSanitizer and UndefinedBehaviorSanitizer to every C build
    --out-dir=D            output directory (default: build)
    --jobs=N               workers: the compiler's own threads, the parallel C compile jobs and the
                           jobserver nested builds share (default: build.toml `jobs`, else one per core)
    --cstd=F               base C flags, in place of build.toml `cstd` (default:
                           -std=c11 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700)
    --cc=BIN               C compiler to use (else build.toml `cc`, else $CC, else cc)
    --bin=NAME             build/run only that binary target
    --transpiler=CMD       build/release: run CMD (words, no shell) as the transpile step
    --print-probes         build/release: print the C toolchain probe results for the target and profile
    --lib                  build only the [lib] target
    --link=NAME            bindgen: library the generated bindings link against
    --header=SPELLING      bindgen: how the generated module spells the #include
    -I <dir>               bindgen: header search path
    --from=PART            bindgen: also take declarations from headers whose path contains PART
    --cflag=F              bindgen: C flag for the target's C environment: -std=, -D, -U, -f[un]signed-char (repeatable)
    --sysroot=DIR          bindgen: the target's C library tree (default: discovered as the build does)
    --target=T             target: windows|macos|linux|ios|android|wasm
    --arch=A               instruction set: x86_64|aarch64|wasm32 (default: the target's)
    --target-feature=L     CPU features: +name enables, -name disables (wasm32: simd128, relaxed-simd)
    --target-cpu=C         x86_64 level whose features come first: x86-64, x86-64-v2, x86-64-v3, x86-64-v4
    --simd-width=W         vector width the planner prefers on AVX-512: 256 (default) or 512
    --simd-dispatch=L      x86_64: run-time copies of the functions with vector code for levels L
                           (comma-separated x86-64-v2..v4; default x86-64-v3 at opt-level 2 or more), or off
    --const-eval-steps=N   compile-time evaluation step budget
    --const-eval-memory=B  compile-time evaluation memory budget (B, or NK/NM/NG)
    --no-lint              disable the on-by-default lints during a build
    --check                fmt: report unformatted files, write nothing
    --fix                  lint: apply machine-applicable fixes and re-lint
    --const                lint: also flag functions that could be 'const fn'
    --no-run               bench: build the bench binary but do not run it
    --dir=D                vendor: project root vendored into (default: the current directory)
    --ref=R                vendor: branch, tag or commit to pin (git sources)
    --force                vendor: replace an existing vendor/<name>
    --test                 script: collect @test functions, build, and run
    --filter=S             test, bench: run only tests or benchmarks whose name contains S (the
                           test and bench subcommands also build only the files that hold them)
    --test-shard=K/N       run shard K of N (one-based, balanced by the durations file)
    --test-jobs=N          bound the test process pool (default: one per core)
    --test-timeout=S       fail a test that runs longer than S seconds (default 90, 0: none)
    --test-record-durations[=F]  test: merge each test's time into F, else into the durations file
    --test-durations=F     test: the durations file that balances --test-shard and that
                           --test-record-durations writes (default: tests/durations.tsv)
    --test-no-fork         run tests in-process (for a debugger)
    --quiet                test: print only the failures, the tally and the slowest tests
)".ptr() as *const char,
        out,
    );
}

fn main(argv: Vector<str>) i32 {
    unsafe shim::sc_trace_install();
    let argc = argv.len();
    if argc > 0 {
        // Each element views its NUL-terminated argv string, which lives as long as the process.
        unsafe shim::sc_set_argv0(argv[0].ptr() as *const char);
    }
    let mut file = "";
    let mut out_bin = ""; // set by the `build` subcommand (via -o, or defaulted)
    let mut proj_dir = ""; // `build <dir>`, `release <dir>`: the project of that directory
    let mut out_abs = String::new(); // a relative -o of `build <dir>`, from the caller's directory
    let mut bg_link = ""; // bindgen: --link=NAME, the library the bindings need on the link line
    let mut bg_header = ""; // bindgen: --header=SPELLING, how the emitted module #includes it
    let mut bg_incs = Vector::<String>::new(); // bindgen: -I search paths
    let mut bg_from = Vector::<String>::new(); // bindgen: --from=, extra origin headers to accept
    let mut bg_cflags = Vector::<String>::new(); // bindgen: --cflag=, applied to the target's C environment
    let mut bg_sysroot = ""; // bindgen: --sysroot=DIR, the target's C library tree (empty: discover it)
    let mut vendor_name = ""; // vendor: optional name override for vendor/<name>
    let mut vendor_dir = "."; // vendor: --dir=, the project root vendored into
    let mut vendor_ref = ""; // vendor: --ref=, the branch, tag or commit pinned for a git source
    let mut vendor_force = false; // vendor: --force, replace an existing vendor/<name>
    let mut clean_full = false; // clean: --full, remove the out-dir and the global cache instead of sweeping
    let mut transpiler = ""; // build/release: --transpiler=CMD, the command that runs the transpile step
    let mut print_probes = false; // build/release: --print-probes, print the toolchain probe table
    let mut emit_sub = ""; // script: --emit-sub=SUB, the transpile form an engine's --transpiler runs
    let mut manifest_dir = ""; // transpile form: --manifest-dir=DIR, the project directory
    let mut emit_id: u64 = 0; // transpile form: --emit-id=N, the identity its emit stamp records
    let mut cc_found = false; // transpile form: --cc-found, the engine found the C compiler

    let mode = if argc > 1 {
        subcommand(argv[1]);
    } else {
        Mode::MODE_DEFAULT;
    };
    let mut fmt_check = false; // fmt --check: report unformatted files, write nothing
    let mut lint_fix = false; // lint --fix: apply machine fixes, re-lint to fixpoint
    let mut lint_sc = false; // lint --const: warn on functions the deep CTFE scan proves always evaluable
    let mut bench_norun = false; // bench --no-run: build the bench binary only
    let mut bench_filter: str = ""; // bench --filter=S: build and run only benchmarks whose name contains S
    let mut extra = Vector::<usize>::new(); // argv indices of extra `fmt`/`lint` paths
    let mut topts = TestOpts {
        enabled: false,
        jobs: 0,
        no_fork: false,
        quiet: false,
        filter: null,
        shard: 0,
        shards: 0,
        timeout: -1,
        durations: null,
        record: false,
        record_to: null,
    };
    let mut co = CommonOpts {
        ce_steps: 0,
        ce_mem: 0,
        target: unsafe shim::sc_host_platform(),
        arch: unsafe shim::sc_host_arch(),
        bootstrap_tags: false,
        lint: true,
        bad: false,
    };
    let mut bo = BuildOpts {
        profile: "",
        out_dir: "",
        cstd: "",
        cc: "",
        jobs: 0,
        bin_sel: "",
        lib_sel: false,
        sanitizers: false,
    };

    let mut i: usize = if mode == Mode::MODE_DEFAULT {
        1usize;
    } else {
        2usize;
    };
    switch mode {
        MODE_DEFAULT => {
            while i < argc {
                let arg = argv[i];
                if co.common_flag(arg) {} else if arg == "--test" {
                    topts.enabled = true;
                } else if arg.starts_with("--emit-sub=") {
                    emit_sub = arg[11..];
                } else if arg.starts_with("--manifest-dir=") {
                    manifest_dir = arg[15..];
                } else if arg.starts_with("--emit-id=") {
                    emit_id = arg[10..].parse_u64().unwrap_or(0);
                    co.bad = co.bad || emit_id == 0;
                } else if arg == "--cc-found" {
                    cc_found = true;
                } else if arg.starts_with("--profile=") || arg.starts_with("--out-dir=") {
                    let _ = bo.build_flag(&mut co, arg);
                } else if parse_test_flag(arg, &mut topts, &mut co.bad) {} else if arg.starts_with("--") || file.len() != 0 {
                    co.reject(arg);
                } else {
                    file = arg;
                }
                i = i + 1;
            }
            // The transpile form's own flags are meaningless without it; it never runs tests.
            let emit_flags = manifest_dir.len() != 0 || emit_id != 0 || bo.profile.len() != 0 || bo.out_dir.len() != 0;
            if emit_sub.len() == 0 && emit_flags || emit_sub.len() != 0 && topts.enabled {
                co.bad = true;
            }
        },
        MODE_BUILD | MODE_RELEASE => {
            while i < argc {
                let arg = argv[i];
                let common = co.common_flag(arg);
                if common || bo.build_flag(&mut co, arg) {} else if arg == "-o" {
                    if i + 1 < argc {
                        i = i + 1;
                        out_bin = argv[i];
                    } else {
                        co.bad = true;
                    }
                } else if arg.starts_with("--transpiler=") && arg.len() > 13 {
                    transpiler = arg[13..];
                } else if arg == "--print-probes" {
                    print_probes = true;
                } else if arg.starts_with("--") || file.len() != 0 {
                    co.reject(arg);
                } else {
                    file = arg;
                }
                i = i + 1;
            }
            // The transpiler replaces the manifest engine's frontend: a bare build has no engine. The probe
            // table belongs to a manifest profile and builds nothing.
            if transpiler.len() != 0 && file.len() != 0 || print_probes && (file.len() != 0 || out_bin.len() != 0) {
                co.bad = true;
            }
            if file.len() != 0 && is_dir(file) {
                proj_dir = file;
                file = "";
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
                    co.reject(arg);
                } else if file.len() == 0 {
                    file = arg;
                } else {
                    // Any number of paths.
                    extra.push(i);
                }
                i = i + 1;
            }
        },
        MODE_LINT => {
            while i < argc {
                let arg = argv[i];
                if co.common_flag(arg) {} else if arg == "--fix" {
                    lint_fix = true;
                } else if arg == "--const" {
                    lint_sc = true;
                } else if arg.starts_with("--") {
                    co.reject(arg);
                } else if file.len() == 0 {
                    file = arg;
                } else {
                    // Any number of paths.
                    extra.push(i);
                }
                i = i + 1;
            }
        },
        MODE_COMMAND => {
            while i < argc {
                let arg = argv[i];
                let common = co.common_flag(arg);
                if common || bo.build_flag(&mut co, arg) {} else if file.len() == 0 && !arg.starts_with("--") {
                    // The build.toml command name.
                    file = arg;
                } else {
                    co.reject(arg);
                }
                i = i + 1;
            }
            if file.len() == 0 {
                // `command` needs a command name.
                co.bad = true;
            }
        },
        MODE_RUN => {
            while i < argc {
                let arg = argv[i];
                let common = co.common_flag(arg);
                if common || bo.build_flag(&mut co, arg) {} else {
                    // `run` takes only build flags; the binary is the manifest's `bin`.
                    co.reject(arg);
                }
                i = i + 1;
            }
        },
        MODE_CLEAN => {
            while i < argc {
                if argv[i].starts_with("--out-dir=") {
                    bo.out_dir = argv[i][10..];
                } else if argv[i] == "--full" {
                    clean_full = true;
                } else {
                    co.reject(argv[i]);
                }
                i = i + 1;
            }
        },
        MODE_TEST => {
            topts.enabled = true;
            while i < argc {
                let arg = argv[i];
                if !parse_test_flag(arg, &mut topts, &mut co.bad) {
                    let common = co.common_flag(arg);
                    if !common && !bo.build_flag(&mut co, arg) {
                        co.reject(arg);
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
                } else if arg.starts_with("--filter=") {
                    bench_filter = arg[9..];
                } else {
                    let common = co.common_flag(arg);
                    if !common && !bo.build_flag(&mut co, arg) {
                        co.reject(arg);
                    }
                }
                i = i + 1;
            }
        },
        MODE_LSP => {
            while i < argc {
                if argv[i] == "--capabilities" || argv[i] == "--version" {
                    // Handled at dispatch: print the capability/version JSON and exit.
                } else if !co.common_flag(argv[i]) {
                    co.reject(argv[i]);
                }
                i = i + 1;
            }
        },
        MODE_NEW => {
            while i < argc {
                if !argv[i].starts_with("--") && file.len() == 0 {
                    // The project name.
                    file = argv[i];
                } else {
                    co.reject(argv[i]);
                }
                i = i + 1;
            }
            if file.len() == 0 {
                // `new` needs a project name.
                co.bad = true;
            }
        },
        MODE_INIT => {
            if i < argc {
                // `init` scaffolds the current directory, no arguments.
                co.reject(argv[i]);
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
                    // The source: a git url or a local directory.
                    file = arg;
                } else if !arg.starts_with("--") && vendor_name.len() == 0 {
                    vendor_name = arg;
                } else {
                    co.reject(arg);
                }
                i = i + 1;
            }
            if file.len() == 0 {
                // `vendor` needs a source.
                co.bad = true;
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
                } else if arg.starts_with("--sysroot=") {
                    bg_sysroot = arg[10..];
                } else if arg.starts_with("--target=") || arg.starts_with("--arch=") {
                    let _ = co.common_flag(arg);
                } else if !arg.starts_with("-") {
                    // Like fmt/lint: the first path lands in `file`, the rest in `extra`.
                    if file.len() == 0 {
                        file = arg;
                    } else {
                        extra.push(i);
                    }
                } else {
                    co.reject(arg);
                }
                i = i + 1;
            }
            if file.len() == 0 {
                // `bindgen` needs a header or a directory.
                co.bad = true;
            }
        },
    };
    if !topts.enabled && (topts.jobs != 0 || topts.no_fork || topts.filter != null || topts.shards != 0 || topts.durations != null || topts.record) {
        co.bad = true;
    }
    // `--help` or `-h`, in any position: the usage on stdout, and success.
    for k in 1..argc {
        if argv[k] == "--help" || argv[k] == "-h" {
            print_usage(stdio::stdout());
            return 0;
        }
    }
    // `super-c test` records into its suite's `durations.tsv`; a script has no suite directory to hold one.
    if mode == Mode::MODE_DEFAULT && topts.record && topts.record_to == null && topts.durations == null {
        eprintln(
            "error: a script's --test-record-durations needs a file: --test-record-durations=F or --test-durations=F",
        );
        return 1;
    }
    // `build <dir>` and `release <dir>`: the project of that directory, as from inside it; a relative -o
    // still names a path from here.
    if proj_dir.len() != 0 {
        if out_bin.len() != 0 && !path::is_absolute(out_bin) {
            out_abs = canon_cwd();
            out_abs.push_byte(b'/');
            out_abs.push_str(out_bin);
            out_bin = out_abs.as_str();
        }
        if process::set_current_dir(proj_dir).is_err() {
            eprintln("error: cannot enter '{}'", proj_dir);
            return 1;
        }
    }
    // `build` with a .spc root is the direct emit+link mode; without one it reads build.toml.
    let manifest_mode = (mode == Mode::MODE_BUILD || mode == Mode::MODE_RELEASE) && file.len() == 0 || mode == Mode::MODE_COMMAND || mode == Mode::MODE_RUN || mode == Mode::MODE_CLEAN || mode == Mode::MODE_TEST || mode == Mode::MODE_BENCH;
    // Cargo-style manifest discovery: a manifest command run from a subdirectory walks up to the
    // nearest build.toml and works from there.
    if manifest_mode {
        chdir_to_manifest();
    }
    // Only a script needs a path of its own: every other mode either reads build.toml, needs no
    // input at all (lsp), or discovers the project itself (fmt/lint).
    if co.bad || file.len() == 0 && mode == Mode::MODE_DEFAULT {
        if co.rejected.len() != 0 {
            eprintln("error: unexpected argument '{}'", co.rejected);
        }
        print_usage(stdio::stderr());
        return 1;
    }
    // resolve "0 = core count" HERE: the p.jobs != 1 frontier gates need a real number, and a
    // single-threaded host (wasm) must resolve to the serial path.
    let jobs_wanted = if bo.jobs != 0 {
        bo.jobs;
    } else {
        bsys::cpu_count();
    };
    // Waiting test parents transfer their slots to nested compilers. One process-tree slot per core keeps
    // independent tests parallel while nested compilers run serially instead of competing for the same cores.
    // WASI has no processes, so no jobserver.
    if PLATFORM != Platform::Wasm {
        unsafe shim::sc_jobserver_init(jobs_wanted as i32);
    }
    let jobs = (unsafe shim::sc_jobserver_claim(jobs_wanted as i32)) as u32;
    // Fmt/lint take any number of paths; with none, the project discovers itself.
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
        // The project is named after the directory's last component: `new apps/demo` builds `demo`.
        let mut e = file.len();
        while e > 0 && file[e - 1] == b'/' {
            e = e - 1;
        }
        return bsys::scaffold_project(file, loader::basename_of(file.slice(0, e)));
    }
    if mode == Mode::MODE_VENDOR {
        return bsys::vendor_dep(vendor_dir, file, vendor_name, vendor_ref, vendor_force);
    }
    if mode == Mode::MODE_BINDGEN {
        // The project's `cstd`, so the headers see the dialect and POSIX level its build compiles with.
        let mut bg_cstd = String::from_str(bman::DEFAULT_CSTD);
        if let Some(dir) = nearest_manifest() {
            switch bman::load(format("{}/build.toml", dir.as_str()).as_str(), false) {
                Some(m) => {
                    bg_cstd = m.cstd.clone();
                },
                None => {
                    return 1;
                },
            };
        }
        let mut bg_paths = Vector::<String>::new();
        bg_paths.push(String::from_str(file));
        for k in 0..extra.len() {
            bg_paths.push(String::from_str(argv[*extra.at(k)]));
        }
        let rc = bindgen::run(
            &bg_paths,
            out_bin,
            bg_link,
            bg_header,
            &bg_incs,
            &bg_from,
            &bg_cflags,
            co.target,
            co.arch,
            bg_sysroot,
            bg_cstd.as_str(),
        );
        return rc;
    }
    if mode == Mode::MODE_INIT {
        let cwd = canon_cwd();
        return bsys::scaffold_project(".", loader::basename_of(cwd.as_str()));
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
    // `--target-cpu` names a level of the build's instruction set.
    let mut cerr = String::new();
    let mut cpu_set = tgt::baseline(co.target, co.arch);
    if !cf::level(co.target_cpu.as_str(), co.arch, true, &mut cpu_set, &mut cerr) {
        eprintln("error: {}", cerr.as_str());
        return 1;
    }
    if mode == Mode::MODE_LINT {
        return lint_project(&paths, file.len() == 0, &co, &bo, cpu_set, std_dir.as_str(), lint_fix, lint_sc);
    }
    if emit_sub.len() != 0 {
        // The transpile form works from the project directory, as the engine that runs it does.
        if manifest_dir.len() != 0 {
            if process::set_current_dir(manifest_dir).is_err() {
                eprintln("error: cannot enter '{}'", manifest_dir);
                return 1;
            }
        }
        let mo = bman::load("build.toml", co.bootstrap_tags);
        if mo.is_none() {
            return 1;
        }
        let mut man = mo.unwrap();
        man.arch = co.arch;
        man.target = co.target;
        if co.target_cpu.len() != 0 {
            man.target_cpu = co.target_cpu.clone();
        }
        if !bsys::check_features(&man, co.target_features.as_str()) {
            return 1;
        }
        if bo.sanitizers {
            man.add_sanitizers();
        }
        if bo.out_dir.len() != 0 {
            man.out_dir = String::from_str(bo.out_dir);
        }
        let cx = bsys::BuildCtx {
            jobs: jobs,
            std_dir: std_dir.as_str(),
            ce_steps: if co.ce_steps != 0 {
                co.ce_steps;
            } else {
                man.ce_steps;
            },
            ce_mem: if co.ce_mem != 0 {
                co.ce_mem;
            } else {
                man.ce_mem;
            },
            target: co.target,
            bootstrap_tags: co.bootstrap_tags,
            lint: co.lint,
            transpiler: "",
            target_features: co.target_features.as_str(),
            simd_width: co.simd_width,
            simd_dispatch: co.simd_dispatch.as_str(),
            cc_found: cc_found,
        };
        return bsys::manifest_emit(&man, bo.profile, file, emit_sub, &cx, emit_id);
    }
    if mode == Mode::MODE_LSP {
        // `super-c lsp --capabilities`: print the advertised capability JSON and exit (machine-
        // readable; editors and tests read it without a protocol session).
        for i in 2..argv.len() {
            if argv[i] == "--capabilities" {
                let caps = lsp_srv::capabilities_with(true, true, true);
                println("{}", caps.as_str());
                return 0;
            }
            if argv[i] == "--version" {
                println("{}", M"({"name":"super-c lsp","version":"0.3"})");
                return 0;
            }
        }
        let rc = lsp_srv::run(std_dir.as_str(), co.target);
        return rc;
    }
    if manifest_mode {
        let mo = bman::load("build.toml", co.bootstrap_tags);
        let mut rc = 1;
        if !mo.is_none() {
            let mut man = mo.unwrap();
            if bo.sanitizers {
                man.add_sanitizers();
            }
            // --arch= (else the host) is the axis `@arch` gates on.
            man.arch = co.arch;
            man.target = co.target;
            if co.target_cpu.len() != 0 {
                man.target_cpu = co.target_cpu.clone();
            }
            if !bsys::check_features(&man, co.target_features.as_str()) {
                return 1;
            }
            let cx = bsys::BuildCtx {
                jobs: jobs,
                std_dir: std_dir.as_str(),
                // CLI --const-eval-* wins; else the manifest's value; else (0) the engine default.
                ce_steps: if co.ce_steps != 0 {
                    co.ce_steps;
                } else {
                    man.ce_steps;
                },
                ce_mem: if co.ce_mem != 0 {
                    co.ce_mem;
                } else {
                    man.ce_mem;
                },
                target: co.target,
                bootstrap_tags: co.bootstrap_tags,
                lint: co.lint,
                transpiler: transpiler,
                target_features: co.target_features.as_str(),
                simd_width: co.simd_width,
                simd_dispatch: co.simd_dispatch.as_str(),
                cc_found: false,
            };
            if bo.out_dir.len() != 0 {
                man.out_dir = String::from_str(bo.out_dir);
            }
            if bo.cstd.len() != 0 {
                man.cstd = String::from_str(bo.cstd);
            }
            if bo.cc.len() != 0 {
                man.cc = String::from_str(bo.cc);
            }
            if mode == Mode::MODE_CLEAN {
                rc = bsys::manifest_clean(&man, clean_full);
            } else if mode == Mode::MODE_TEST {
                topts.enabled = true;
                rc = bsys::manifest_test(&man, bo.profile, &cx, &topts);
            } else if mode == Mode::MODE_BENCH {
                rc = bsys::manifest_bench(&man, bo.profile, bench_norun, bench_filter, &cx);
            } else if mode == Mode::MODE_COMMAND {
                rc = bsys::manifest_run(&man, file, bo.profile, &cx);
            } else if mode == Mode::MODE_RUN {
                // Cargo run: build the manifest binary and exec it.
                rc = bsys::manifest_run_bin(&man, bo.profile, out_bin, bo.bin_sel, &cx);
            } else if print_probes {
                rc = bsys::manifest_print_probes(&man, bo.profile, &cx);
            } else if out_bin.len() != 0 && bo.lib_sel {
                eprintln("error: -o names one binary; --lib builds the library targets");
                rc = 1;
            } else if out_bin.len() != 0 {
                rc = bsys::manifest_build(&man, bo.profile, out_bin, bo.bin_sel, &cx);
            } else {
                rc = bsys::manifest_build_all(&man, bo.profile, bo.bin_sel, bo.lib_sel, &cx);
            }
        }
        return rc;
    }
    // No manifest here, so the profile the CLI asked for has to be resolved from the built-ins: without
    // this a `super-c release foo.spc` linked with no -O at all while reporting success.
    // A script build has no manifest: the baseline of the instruction set and the command line's list.
    let mut feats = cpu_set;
    let mut ferr = String::new();
    if !cf::apply(co.target_features.as_str(), co.target, co.arch, true, &mut feats, &mut ferr) {
        eprintln("error: {}", ferr.as_str());
        return 1;
    }
    // The target selectors and the engine's own steps act on build.toml's targets; a file has none.
    if bo.bin_sel.len() != 0 || bo.lib_sel || transpiler.len() != 0 || print_probes {
        eprintln("error: --bin, --lib, --transpiler and --print-probes need build.toml; '{}' builds alone", file);
        return 1;
    }
    let pflags = bsys::profile_flags(bo.profile, co.target, false, bo.sanitizers);
    let pcflags = bsys::profile_flags(bo.profile, co.target, true, bo.sanitizers);
    let rc = run_file(
        file,
        std_dir.as_str(),
        co.ce_steps,
        co.ce_mem,
        &topts,
        out_bin,
        co.target,
        co.arch,
        cf::close(feats),
        co.simd_width,
        co.simd_dispatch.as_str(),
        co.bootstrap_tags,
        co.lint,
        pflags.as_str(),
        pcflags.as_str(),
        jobs,
        bo.out_dir,
        bo.cc,
        bo.cstd,
        bo.profile,
    );
    return rc;
}
