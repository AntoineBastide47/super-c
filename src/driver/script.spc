// A script compile (`super-c <file.spc>`): load the file and its imports with the build settings the
// command line gives, then emit and link through the one compile entry point (`run_package`). Shared by
// the command line and the compiler API, which asks for the program's LIR (`lir_out`).
import stdio;
import stdlib;
import driver_shim as shim;
import std::parallel::runtime as prt;
import module::loader as loader;
import ast::ast as *;
import ir::interp as iri;
import ir::cpu_features as cf;
import driver::util as *;
import driver::test as *;
import driver::emit as *;
import build_system::manifest as bman;
import build_system::build as bsys;
import build_system::objcache as ocache;

/// Compile script `path` with std from `std_dir` and the command line's settings (see `super-c --help`);
/// the exit status. With `lir_out` set, the program's LIR text form lands there.
pub(package) fn run_script(
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
    jobs: u32,
    out_dir: str,
    sysroot: str,
    profile: str,
    lir_out: *mut String,
) i32 {
    loader::set_load_jobs(jobs);
    let tl0 = ticks_ms();
    // The build settings the prelude's build constants spell, set before the load.
    let mut p = loader::package_new(loader::dirname_of(path), "", std_dir);
    p.arch = arch;
    p.features = features;
    p.simd_width = pick(simd_width != 0, simd_width, 256);
    let bi = bman::builtins_only();
    p.simd_dispatch = String::from_str(bsys::dispatch_for(&bi, profile, simd_dispatch));
    bsys::apply_profile(&bi, profile, &mut p);
    p.sysroot = String::from_str(sysroot);
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
    // `--out-dir` applies to a bare build exactly as to a manifest one: the emitted tree goes under the
    // named directory.
    if out_dir.len() != 0 {
        let mut g = String::from_str(out_dir);
        g.push_byte(b'/');
        g.push_str(p.profile_name());
        g.push_str("/raw");
        p.gen_root = g;
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
    let mut rc: i32 = 1;
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
            p.lir_out = lir_out;
            rc = run_package(&mut p, topts, out_bin, target, lint, null);
        }
    }
    return rc;
}
