// Builds through the compiler's own build engine, as `super-c build` runs them, for the project in the
// current working directory. `plan` reads the manifest, the profile, the target, the steps and the package
// graph: it writes nothing and starts no process (the engine's process gate denies every start). `build`
// builds every target and reports each object of its link, the link argv, the steps it ran, the files it made
// and the processes it started; a build that changes nothing starts none.
//
// Hooks: code a tool compiler runs inside its builds (`[tools] hooks` in build.toml, or `install` in a tool of
// its own). A hook runs at four stages: before the analysis, before the emission (with the package graph),
// after the emission (with the program's verified LIR, every body), and after the link (with the files made).
// It adds diagnostics and artifacts (`HookOutput`); an error fails the build. It cannot change what an earlier
// stage made. Artifacts land in `<out-dir>/<profile>/hooks/<hook id>/`, rewritten only when their bytes
// change. A hook's id, version and configuration enter the per-TU cache key and the emit stamp, so output made
// under other hooks never replays; a build with a hook that
// reads the LIR lowers every body and replays no module. A build whose emit stamp proves its tree current runs
// no analysis: only the stages before the analysis and after the link run then.
import api::errors as *;
import api::lir as alir;
import api::backend as be;
import build_system::ext as ext;
import build_system::build as bsys;
import build_system::manifest as mf;
import driver::util as dutil;
import module::loader as loader;
import lir::ir as lir;
import target::table as tgt;
import ir::cpu_features as cf;

/// Diagnostic severities, as `api::session` numbers them.
pub const SEV_ERROR: u8 = 1;
pub const SEV_WARNING: u8 = 2;

/// The build a hook stage belongs to: its profile, its operating system and instruction set (`target::table`
/// names), and its directory (`<out-dir>/<profile>`, or the target's own directory).
pub struct BuildInfo {
    pub profile: String,
    pub os: String,
    pub isa: String,
    pub dir: String,
}

/// One module of the package graph: its path (`app::util`), its file, whether it is part of std's prelude,
/// and the modules it imports (indexes into the same list), in declaration order.
pub struct ModuleInfo {
    pub path: String,
    pub file: String,
    pub prelude: bool,
    pub imports: Vector<u32>,
}

/// A diagnostic a hook reported: the hook, the severity, the file it concerns (empty: the build) and the
/// message.
pub struct HookDiagnostic {
    pub hook: String,
    pub severity: u8,
    pub file: String,
    pub message: String,
}

/// What a hook adds at a stage.
pub struct HookOutput {
    pub(file) hook: String,
    pub(file) diags: Vector<HookDiagnostic>,
    pub(file) arts: Vector<be::Artifact>,
}

extend HookOutput {
    /// An error about the build: the build fails after this stage.
    pub fn error(self: &mut Self, message: str) {
        self.report(SEV_ERROR, "", message);
    }

    /// A warning about the build.
    pub fn warning(self: &mut Self, message: str) {
        self.report(SEV_WARNING, "", message);
    }

    /// A diagnostic of severity `severity` (`SEV_ERROR`, `SEV_WARNING`) about `file` (empty: the build).
    pub fn report(self: &mut Self, severity: u8, file: str, message: str) {
        self.diags.push(
            HookDiagnostic {
                hook: self.hook.clone(),
                severity: severity,
                file: String::from_str(file),
                message: String::from_str(message),
            },
        );
    }

    /// The artifact `name` (a file name without directories, unique per hook) with `bytes`.
    pub fn artifact(self: &mut Self, name: str, bytes: Vector<u8>) {
        self.arts.push(be::Artifact { name: String::from_str(name), bytes: bytes });
    }
}

/// Code a build runs at its stages. Every stage method does nothing by default; an `Err` is reported as an
/// error of the hook.
pub interface Hook {
    /// Its stable name, reverse-domain style (`org.example.sizes`): letters, digits, `.`, `-` and `_`.
    fn id(self: &Self) str;

    /// Its version: a new one makes every cached output of builds under the old one stale.
    fn version(self: &Self) u32;

    /// Its configuration, part of its identity as the version is.
    fn config(self: &Self) str {
        return "";
    }

    /// Whether it runs `after_ir`: the builds then lower every body to LIR and replay no module from the
    /// per-TU cache.
    fn reads_ir(self: &Self) bool {
        return false;
    }

    /// Before the analysis.
    fn before_analysis(self: &mut Self, b: &BuildInfo, out: &mut HookOutput) Result<Unit, ApiError> {
        return Result::<Unit, ApiError>::Ok(Unit {});
    }

    /// After the analysis, before the emission: the package graph.
    fn before_emission(self: &mut Self, b: &BuildInfo, modules: Slice<ModuleInfo>, out: &mut HookOutput) Result<
        Unit,
        ApiError
    > {
        return Result::<Unit, ApiError>::Ok(Unit {});
    }

    /// After the emission: the program's LIR, verified, every concrete function (generic instances
    /// included) and data definition the build emits. Runs only when `reads_ir`.
    fn after_ir(self: &mut Self, b: &BuildInfo, prog: &alir::Program, out: &mut HookOutput) Result<Unit, ApiError> {
        return Result::<Unit, ApiError>::Ok(Unit {});
    }

    /// After the link: the files the build made.
    fn after_artifacts(self: &mut Self, b: &BuildInfo, artifacts: Slice<String>, out: &mut HookOutput) Result<
        Unit,
        ApiError
    > {
        return Result::<Unit, ApiError>::Ok(Unit {});
    }
}

/// A custom backend as a hook: after the emission it runs the backend over the program's LIR
/// (`api::backend::run`) and adds its artifacts.
pub struct BackendHook {
    pub(file) id: String,
    pub(file) b: Box<dyn be::Backend>,
}

extend BackendHook {
    /// The hook `id` that runs backend `b`.
    pub fn new(id: str, b: Box<dyn be::Backend>) BackendHook {
        return BackendHook { id: String::from_str(id), b: b };
    }
}

extend BackendHook as Hook {
    pub fn id(self: &Self) str {
        return self.id.as_str();
    }

    pub fn version(self: &Self) u32 {
        return self.b.api_version();
    }

    pub fn reads_ir(self: &Self) bool {
        return true;
    }

    pub fn after_ir(self: &mut Self, b: &BuildInfo, prog: &alir::Program, out: &mut HookOutput) Result<Unit, ApiError> {
        out.arts = be::run(&mut self.b, prog, b.os.as_str(), b.isa.as_str())?;
        return Result::<Unit, ApiError>::Ok(Unit {});
    }
}

// The installed hooks, sorted by id, and what their stages reported.
struct Hooks {
    pub list: Vector<Box<dyn Hook>>,
    pub set: ext::HookSet,
    pub diags: Vector<HookDiagnostic>,
    pub written: Vector<String>,
}

/// Hooks installed for the builds of this process (`install`) until this value drops.
pub struct Installed {
    pub(file) h: Box<Hooks>,
}

extend Installed as Free {
    pub fn free(self: &mut Self) {
        ext::install(null);
        self.h.free();
    }
}

// Whether `id` is a hook id: letters, digits, `.`, `-` and `_`, not empty and not `.` or `..`.
fn valid_id(id: str) bool {
    if id.len() == 0 || id == "." || id == ".." {
        return false;
    }
    for i in 0..id.len() {
        let c = id.byte_at(i);
        if !(c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9' || c == b'.' || c == b'-' || c == b'_') {
            return false;
        }
    }
    return true;
}

/// Install `hooks` for every build this process runs while the result lives. `InvalidArgument` for an id
/// that is not valid or repeats, or when hooks are installed already.
pub fn install(hooks: Vector<Box<dyn Hook>>) Result<Installed, ApiError> {
    if ext::hooks() != null {
        return Result::<Installed, ApiError>::Err(ApiError::new(Code::InvalidArgument, "hooks are installed already"));
    }
    let mut list = hooks;
    list.sort_by(
        |x: &Box<dyn Hook>, y: &Box<dyn Hook>| {
            let yi = y.id();
            return x.id().cmp(&yi);
        },
    );
    let mut ident = String::new();
    let mut reads = false;
    for i in 0..list.len() {
        let id = list[i].id();
        if !valid_id(id) || i > 0 && list[i - 1].id() == id {
            return Result::<Installed, ApiError>::Err(
                ApiError::new(Code::InvalidArgument, format("'{}' is not a hook id, or it repeats", id).as_str()),
            );
        }
        ident.format_into("{}\t{}\t{}\n", id, list[i].version(), list[i].config());
        reads = reads || list[i].reads_ir();
    }
    let mut h = Box::new(
        Hooks {
            list: list,
            set: ext::HookSet { ctx: null, id: dutil::str_id(ident.as_str()) | 1, reads_ir: reads, run: run_stage },
            diags: Vector::<HookDiagnostic>::new(),
            written: Vector::<String>::new(),
        },
    );
    let hp = h.deref_mut() as *mut Hooks;
    unsafe (*hp).set.ctx = hp;
    ext::install(unsafe &(*hp).set);
    return Result::<Installed, ApiError>::Ok(Installed { h: h });
}

// The package graph of `p`.
fn modules_of(p: &loader::Package) Vector<ModuleInfo> {
    let n = p.modules.len();
    let mut out = Vector::<ModuleInfo>::with_capacity(n);
    for i in 0..n {
        let mut imps = Vector::<u32>::new();
        if i + 1 < p.idx.mod_imports.len() {
            for k in p.idx.mod_imports[i]..p.idx.mod_imports[i + 1] {
                imps.push(p.idx.imports[k as usize]);
            }
        }
        out.push(
            ModuleInfo {
                path: p.modules[i].path.clone(),
                file: p.modules[i].file.clone(),
                prelude: p.modules[i].prelude,
                imports: imps,
            },
        );
    }
    return out;
}

// The engine's stage `d` over every installed hook (`ext::HookSet.run`): their diagnostics printed and kept,
// their artifacts written. False when one reported an error.
fn run_stage(ctx: *mut void, d: &ext::StageData) bool {
    let hs = unsafe &mut *(ctx as *mut Hooks);
    let b = BuildInfo {
        profile: unsafe (*d.profile).clone(),
        os: String::from_str(tgt::os(d.os).name),
        isa: String::from_str(tgt::isa(d.isa).name),
        dir: unsafe (*d.dir).clone(),
    };
    let mods = if d.stage == ext::STAGE_BEFORE_EMISSION {
        modules_of(unsafe &*d.pkg);
    } else {
        Vector::<ModuleInfo>::new();
    };
    let mut prog = Option::<alir::Program>::None;
    if d.stage == ext::STAGE_AFTER_IR {
        let pb = unsafe (*d.prog).ptr_bytes;
        prog = Option::<alir::Program>::Some(
            alir::Program::of_package(replace(unsafe &mut *d.prog, lir::Package::new(pb))),
        );
    }
    let mut ok = true;
    for i in 0..hs.list.len() {
        let h = &mut hs.list[i];
        let mut out = HookOutput {
            hook: String::from_str(h.id()),
            diags: Vector::<HookDiagnostic>::new(),
            arts: Vector::<be::Artifact>::new(),
        };
        let r = if d.stage == ext::STAGE_BEFORE_ANALYSIS {
            h.before_analysis(&b, &mut out);
        } else if d.stage == ext::STAGE_BEFORE_EMISSION {
            h.before_emission(&b, mods.as_slice(), &mut out);
        } else if d.stage == ext::STAGE_AFTER_IR && h.reads_ir() {
            h.after_ir(&b, prog.as_ref().unwrap(), &mut out);
        } else if d.stage == ext::STAGE_AFTER_IR {
            Result::<Unit, ApiError>::Ok(Unit {});
        } else {
            h.after_artifacts(&b, unsafe (*d.artifacts).as_slice(), &mut out);
        };
        if let Err(e) = r {
            out.error(format("the hook failed: {}", e.message.as_str()).as_str());
        }
        if let Err(e) = be::sort_artifacts(&mut out.arts) {
            out.error(e.message.as_str());
        } else {
            let dir = loader::join2(loader::join2(b.dir.as_str(), "hooks").as_str(), out.hook.as_str());
            for k in 0..out.arts.len() {
                let path = loader::join2(dir.as_str(), out.arts[k].name.as_str());
                if !publish(dir.as_str(), path.as_str(), &out.arts[k].bytes) {
                    out.error(format("cannot write '{}'", path.as_str()).as_str());
                }
                hs.written.push(path);
            }
        }
        for k in 0..out.diags.len() {
            let dg = &out.diags[k];
            let sev = if dg.severity == SEV_ERROR {
                "error";
            } else {
                "warning";
            };
            if dg.file.len() != 0 {
                eprintln("{}: {}: hook '{}': {}", dg.file.as_str(), sev, dg.hook.as_str(), dg.message.as_str());
            } else {
                eprintln("{}: hook '{}': {}", sev, dg.hook.as_str(), dg.message.as_str());
            }
            ok = ok && dg.severity != SEV_ERROR;
        }
        out.diags.reverse();
        while let Some(dg) = out.diags.pop() {
            hs.diags.push(dg);
        }
    }
    if let Some(pg) = &mut prog {
        // The empty package the stage left in its place drops here.
        let _ = replace(unsafe &mut *d.prog, pg.take_package());
    }
    return ok;
}

// Write `bytes` to `path` in directory `dir` unless the file holds them already; false when it cannot.
fn publish(dir: str, path: str, bytes: &Vector<u8>) bool {
    let text = unsafe str::from_raw(bytes.as_ptr(), bytes.len());
    if let Some(old) = loader::read_file(path) {
        if old.as_str() == text {
            return true;
        }
    }
    dutil::mkdir_p(dir);
    return dutil::write_file_atomic(path, text);
}

/// What a build request names: the profile (empty: the manifest's default), the std tree, and the worker
/// count (0: the manifest's `jobs`, else one per core). The build is for the host.
pub struct Request {
    pub profile: String,
    pub std_dir: String,
    pub jobs: u32,
}

/// A profile as the build resolves it: its name, its `opt-level` (-1: the build's default), its linker flags,
/// its linker arguments, whether it strips, and whether integer overflow traps.
pub struct ProfileInfo {
    pub name: String,
    pub opt_level: i32,
    pub ldflags: Vector<String>,
    pub link_args: Vector<String>,
    pub strip: bool,
    pub overflow_checks: bool,
}

/// A step (`[step.NAME]`) and whether its record shows it current: a build would not run it.
pub struct StepInfo {
    pub name: String,
    pub argv: Vector<String>,
    pub inputs: Vector<String>,
    pub outputs: Vector<String>,
    pub env: Vector<String>,
    pub cache: bool,
    pub current: bool,
}

/// What a build of the project would do, read without writing or running anything.
pub struct Plan {
    pub profile: ProfileInfo,
    pub os: String,
    pub isa: String,
    pub features: Vector<String>, // the CPU features beyond the baseline (`--target-feature` names)
    pub artifacts: Vector<String>, // in build order: library files, the primary binary, each [bin.NAME]
    pub steps: Vector<StepInfo>,
    pub modules: Vector<ModuleInfo>, // the package graph of the primary root
    pub hooks: Vector<String>, // the installed hooks' ids
}

/// One object of the link, and whether this build wrote it (false: the emission kept it).
pub struct CompileUnit {
    pub object: String,
    pub compiled: bool,
}

/// One target's build: the file it makes, whether the emission ran (false: the emit stamp proved the tree
/// current), its units, its link argv (empty: nothing linked), the steps it ran, and its stage times.
pub struct TargetBuild {
    pub artifact: String,
    pub emitted: bool,
    pub units: Vector<CompileUnit>,
    pub link: Vector<String>,
    pub linked: bool,
    pub steps_run: Vector<String>,
    pub transpile_ms: i64,
    pub link_ms: i64,
}

/// A build's result: whether it succeeded (the compiler printed the diagnostics of a failure), each target
/// built, the processes it started, the hooks' diagnostics, and the hooks' artifacts.
pub struct Report {
    pub ok: bool,
    pub targets: Vector<TargetBuild>,
    pub processes: u32,
    pub diagnostics: Vector<HookDiagnostic>,
    pub hook_artifacts: Vector<String>,
}

// The manifest of the current directory for the host; `InvalidArgument` when it does not load (its
// diagnostics are printed).
fn manifest<'a>() Result<mf::Manifest<'a>, ApiError> {
    return switch mf::load("build.toml", false) {
        Some(m) => Result::<mf::Manifest, ApiError>::Ok(m),
        None => Result::<mf::Manifest, ApiError>::Err(
            ApiError::new(Code::InvalidArgument, "the current directory holds no usable build.toml"),
        ),
    };
}

// The engine context of request `req` over manifest `m`.
fn context<'a>(m: &mf::Manifest, req: &'a Request) bsys::BuildCtx<'a> {
    return bsys::BuildCtx {
        jobs: req.jobs,
        std_dir: req.std_dir.as_str(),
        ce_steps: m.ce_steps,
        ce_mem: m.ce_mem,
        target: m.target,
        bootstrap_tags: false,
        lint: false,
        transpiler: "",
        target_features: "",
        simd_width: 0,
        simd_dispatch: "",
    };
}

/// What a build of the project in the current directory would do. Reads the manifest, the steps' records
/// and the sources; writes nothing and starts no process.
pub fn plan(req: &Request) Result<Plan, ApiError> {
    let m = manifest()?;
    let prof = bsys::resolve_profile(&m, req.profile.as_str());
    let pi = m.profile_index(prof);
    if pi < 0 {
        return Result::<Plan, ApiError>::Err(
            ApiError::new(Code::InvalidArgument, format("unknown profile '{}'", prof).as_str()),
        );
    }
    let pr = m.profiles.at(pi as usize);
    let mut feats = Vector::<String>::new();
    let fs = bsys::features_for(&m, prof, "");
    let base = tgt::baseline(m.target, m.arch);
    for i in 0..cf::FEATURE_COUNT {
        if cf::has(fs, i) && !cf::has(base, i) {
            feats.push(String::from_str(cf::row(i).name));
        }
    }
    let mut out = Plan {
        profile: ProfileInfo {
            name: String::from_str(prof),
            opt_level: pr.opt,
            ldflags: pr.ldflags.clone(),
            link_args: pr.link_args.clone(),
            strip: pr.strip,
            overflow_checks: !pr.arith_wraps(),
        },
        os: String::from_str(tgt::os(m.target).name),
        isa: String::from_str(tgt::isa(m.arch).name),
        features: feats,
        artifacts: Vector::<String>::new(),
        steps: Vector::<StepInfo>::new(),
        modules: Vector::<ModuleInfo>::new(),
        hooks: Vector::<String>::new(),
    };
    bsys::artifact_paths(&m, prof, m.target, &mut out.artifacts);
    ext::deny_processes(true);
    defer {
        ext::deny_processes(false);
    }
    for i in 0..m.steps.len() {
        let st = &m.steps[i];
        out.steps.push(
            StepInfo {
                name: st.name.clone(),
                argv: st.argv.clone(),
                inputs: st.inputs.clone(),
                outputs: st.outputs.clone(),
                env: st.env.clone(),
                cache: st.cache,
                current: bsys::step_current(&m, i),
            },
        );
    }
    let mut p = loader::package_load_rooted(
        m.root.as_str(),
        loader::dirname_of(m.root.as_str()),
        "",
        req.std_dir.as_str(),
        false,
        m.target,
    );
    p.ensure_index();
    out.modules = modules_of(&p);
    let h = ext::hooks();
    if h != null {
        let hs = unsafe &*((*h).ctx as *const Hooks);
        for i in 0..hs.list.len() {
            out.hooks.push(String::from_str(hs.list[i].id()));
        }
    }
    return Result::<Plan, ApiError>::Ok(out);
}

/// Build every target of the project in the current directory, as `super-c build` does, with the installed
/// hooks. Writes the build trees and runs the steps, the compiles and the link. `InvalidArgument` when the
/// manifest does not load or a CPU feature is not valid; a failed build is a `Report` with `ok` false.
pub fn build(req: &Request) Result<Report, ApiError> {
    let m = manifest()?;
    if !bsys::check_features(&m, "") {
        return Result::<Report, ApiError>::Err(
            ApiError::new(Code::InvalidArgument, "the manifest names a CPU feature the target does not have"),
        );
    }
    let cx = context(&m, req);
    let mut rep = ext::Report { targets: Vector::<ext::TargetReport>::new(), processes: 0 };
    ext::set_report(&mut rep);
    let rc = bsys::manifest_build_all(&m, req.profile.as_str(), "", false, &cx);
    ext::set_report(null);
    let mut out = Report {
        ok: rc == 0,
        targets: Vector::<TargetBuild>::with_capacity(rep.targets.len()),
        processes: rep.processes,
        diagnostics: Vector::<HookDiagnostic>::new(),
        hook_artifacts: Vector::<String>::new(),
    };
    for i in 0..rep.targets.len() {
        let t = &mut rep.targets[i];
        let mut units = Vector::<CompileUnit>::with_capacity(t.units.len());
        for k in 0..t.units.len() {
            let u = &mut t.units[k];
            units.push(CompileUnit { object: replace(&mut u.object, String::new()), compiled: u.compiled });
        }
        units.sort_by(
            |x: &CompileUnit, y: &CompileUnit| {
                let yo = y.object.as_str();
                return x.object.as_str().cmp(&yo);
            },
        );
        out.targets.push(
            TargetBuild {
                artifact: replace(&mut t.artifact, String::new()),
                emitted: t.emitted,
                units: units,
                link: replace(&mut t.link, Vector::<String>::new()),
                linked: t.linked,
                steps_run: replace(&mut t.steps_run, Vector::<String>::new()),
                transpile_ms: t.transpile_ms,
                link_ms: t.link_ms,
            },
        );
    }
    let h = ext::hooks();
    if h != null {
        let hs = unsafe &mut *((*h).ctx as *mut Hooks);
        out.diagnostics = replace(&mut hs.diags, Vector::<HookDiagnostic>::new());
        out.hook_artifacts = replace(&mut hs.written, Vector::<String>::new());
        out.hook_artifacts.sort();
        out.hook_artifacts.dedup();
    }
    return Result::<Report, ApiError>::Ok(out);
}
