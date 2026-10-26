// The extensions of the running build: the hooks a tool compiler installed (`api::build::install`), the
// identity of the hooks and of the project's steps, the report an API request collects, and the process
// gate. The engine (`build_system::build`), the driver (`driver::emit`, `driver::tuc`) and the facade read
// them here, so neither imports the other. One build runs at a time in a process, on one thread; its
// subprocesses start from that thread.
import module::loader as loader;
import lir::ir as lir;

/// The stages a hook runs at, in build order: before the analysis, after the analysis and before the C
/// emission, after the emission with the program's verified LIR, and after the link.
pub(package) const STAGE_BEFORE_ANALYSIS: u32 = 0;
pub(package) const STAGE_BEFORE_EMISSION: u32 = 1;
pub(package) const STAGE_AFTER_IR: u32 = 2;
pub(package) const STAGE_AFTER_ARTIFACTS: u32 = 3;

/// What a stage hands the hooks: the build, and the stage's data (null where the stage has none).
pub(package) struct StageData {
    pub(package) stage: u32,
    pub(package) profile: *const String,
    pub(package) dir: *const String, // the profile's build directory (`<out-dir>/<profile>`)
    pub(package) os: i32,
    pub(package) isa: i32,
    pub(package) pkg: *const loader::Package, // BEFORE_EMISSION, AFTER_IR: the analyzed package
    pub(package) prog: *mut lir::Package, // AFTER_IR: the program's LIR, every body
    pub(package) artifacts: *const Vector<String>, // AFTER_ARTIFACTS: the files the build produced
}

/// The installed hooks: `run` runs every hook of a stage and returns false when one reported an error, which
/// fails the build. `id` is the hooks' identity (ids, versions, configurations); `reads_ir` makes every build
/// lower each body to LIR (and so replay no module from the per-TU cache) for STAGE_AFTER_IR.
pub(package) struct HookSet {
    pub(package) ctx: *mut void,
    pub(package) id: u64,
    pub(package) reads_ir: bool,
    pub(package) run: fn(*mut void, &StageData) bool,
}

static mut G_HOOKS: *const HookSet = null;

/// Install `h` for every later build of the process; `h` must stay valid.
pub(package) fn install(h: *const HookSet) {
    unsafe G_HOOKS = h;
}

/// The installed hooks; null for none.
pub(package) fn hooks() *const HookSet {
    return unsafe G_HOOKS;
}

/// Whether the installed hooks read the LIR.
pub(package) fn reads_ir() bool {
    return unsafe G_HOOKS != null && unsafe (*G_HOOKS).reads_ir;
}

/// The build in progress (`begin`): what the driver's stages hand the hooks.
pub(package) struct Current {
    pub(package) profile: String,
    pub(package) dir: String,
    pub(package) os: i32,
    pub(package) isa: i32,
    pub(package) id: u64, // the extension identity: the hooks' and the steps' (`build::ext_id`)
}

static mut G_CUR: *const Current = null;

/// Mark `c` as the build in progress until `end`; `c` must stay valid until then.
pub(package) fn begin(c: *const Current) {
    unsafe G_CUR = c;
}

pub(package) fn end() {
    unsafe G_CUR = null;
}

/// The extension identity of the build in progress: 0 without steps and hooks. The per-TU cache key and the
/// emit stamp include it.
pub(package) fn id() u64 {
    if unsafe G_CUR == null {
        return 0;
    }
    return unsafe (*G_CUR).id;
}

/// Run the hooks of driver stage `stage` (STAGE_BEFORE_EMISSION, STAGE_AFTER_IR) over `p` and `prog`
/// (null: none); true without hooks or a build in progress, false when a hook reported an error.
pub(package) fn run_stage(stage: u32, p: *const loader::Package, prog: *mut lir::Package) bool {
    let h = unsafe G_HOOKS;
    let c = unsafe G_CUR;
    if h == null || c == null {
        return true;
    }
    let d = StageData {
        stage: stage,
        profile: unsafe &(*c).profile,
        dir: unsafe &(*c).dir,
        os: unsafe (*c).os,
        isa: unsafe (*c).isa,
        pkg: p,
        prog: prog,
        artifacts: null,
    };
    return unsafe (*h).run((*h).ctx, &d);
}

/// One object of a build's link, and whether this build wrote it (false: the emission kept it).
pub(package) struct CompileUnit {
    pub(package) object: String,
    pub(package) compiled: bool,
}

/// What one target's build did, for an API request (`set_report`).
pub(package) struct TargetReport {
    pub(package) artifact: String, // the binary or library it builds
    pub(package) emitted: bool, // false: the emit stamp proved the generated tree current
    pub(package) units: Vector<CompileUnit>,
    pub(package) link: Vector<String>, // the link (or archive) argv; empty when nothing was linked
    pub(package) linked: bool,
    pub(package) steps_run: Vector<String>,
    pub(package) transpile_ms: i64,
    pub(package) link_ms: i64,
}

/// What an API request's build did: one record per target, and the processes it started.
pub(package) struct Report {
    pub(package) targets: Vector<TargetReport>,
    pub(package) processes: u32,
}

static mut G_REPORT: *mut Report = null;

/// Collect what the builds do into `r` (null: stop); `r` must stay valid until then.
pub(package) fn set_report(r: *mut Report) {
    unsafe G_REPORT = r;
}

/// The report being collected; null for none.
pub(package) fn report() *mut Report {
    return unsafe G_REPORT;
}

static mut G_NO_PROCESS: bool = false;

/// Forbid (`true`) or allow the start of subprocesses: a build without process authority.
pub(package) fn deny_processes(on: bool) {
    unsafe G_NO_PROCESS = on;
}

/// The gate every subprocess start of the compiler passes: false when processes are denied; else counts
/// the start in the report being collected.
pub(package) fn may_start_process() bool {
    if unsafe G_NO_PROCESS {
        return false;
    }
    if unsafe G_REPORT != null {
        unsafe (*G_REPORT).processes += 1;
    }
    return true;
}
