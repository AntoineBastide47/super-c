// A compiler session: one package analyzed from one root (a project's manifest root, or a lone file) through
// the analysis entry points the language server uses, updated in place on every change. It keeps the body
// syntax of every module outside std, which the positional queries read. Files come from a
// provider (the host's file system by default); editor buffers and generated text set with `set_text` or
// `apply` take precedence over it. Views borrow the session: a change takes `&mut Session`, so no view
// outlives the analysis it reads. A `check` that is cancelled or fails leaves the session unchecked, with its
// inputs kept; the next `check` analyzes from scratch.
import api::errors as *;
import api::source as *;
import module::loader as loader;
import lsp::analysis as an;
import build_system::manifest as bman;
import driver_shim as shim;
import std::parallel::task as ptask;
import std::platform::clock;
import utils::diag_codes as dc;

/// What a request may cost: `cancel` stops it, as does the monotonic clock passing `deadline_ns`
/// (`std::platform::clock::monotonic_ns`, 0: none); a result above `result_limit` bytes is `Limit` (0: none).
pub struct RequestOptions {
    pub cancel: Option<ptask::CancelToken>,
    pub deadline_ns: u64,
    pub result_limit: usize,
}

extend RequestOptions {
    /// No cancellation, no deadline, no result limit.
    pub fn none() RequestOptions {
        return RequestOptions { cancel: Option::<ptask::CancelToken>::None };
    }

    /// A request that ends `ms` milliseconds from now.
    pub fn within_ms(ms: u64) RequestOptions {
        return RequestOptions {
            cancel: Option::<ptask::CancelToken>::None,
            deadline_ns: clock::monotonic_ns() + ms * 1000000,
        };
    }
}

/// How a session reads its sources and what it analyzes.
pub struct Config {
    /// The std directory (`std/` of a compiler install; `SC_STD_DIR` names it to a test build).
    pub std_dir: String,
    /// The target operating system, a `target::table` index; -1: the host's.
    pub target: i32,
    /// The files the session reads; None: the host's file system.
    pub files: Option<Box<dyn FileProvider>>,
    /// A session whose retained analysis passes this many bytes after a `check` drops it and reports
    /// `Limit`; 0: no limit.
    pub memory_limit: usize,
}

extend Config {
    /// The host's files and target, and the std directory `std_dir`.
    pub fn host(std_dir: str) Config {
        return Config { std_dir: String::from_str(std_dir), target: -1, files: Option::<Box<dyn FileProvider>>::None };
    }

    /// The files of `files`, the host's target, and the std directory `std_dir`.
    pub fn with_files(std_dir: str, files: Box<dyn FileProvider>) Config {
        return Config {
            std_dir: String::from_str(std_dir),
            target: -1,
            files: Option::<Box<dyn FileProvider>>::Some(files),
        };
    }
}

// One editor buffer or generated text: it replaces the provider's text of `path`.
struct Buffer {
    pub path: String,
    pub text: String,
    pub version: i64,
}

/// One change of `apply`: file `path` gets `edits` (byte ranges of its current text), or its whole text
/// `text` when `edits` is empty and `replace` is set. With `expected_version` at 0 or above the change
/// applies only while the file's version (`Session::version`) is that one.
pub struct Change {
    pub path: String,
    pub edits: Vector<Edit>,
    pub replace: bool,
    pub text: String,
    pub expected_version: i64,
}

// Session states: no analysis, an analysis of older inputs, an analysis of the current inputs.
const S_NONE: u8 = 0;
const S_STALE: u8 = 1;
const S_CHECKED: u8 = 2;

pub struct Session {
    pub(file) files: Option<Box<dyn FileProvider>>,
    pub(file) std_dir: String,
    pub(file) target: i32,
    pub(file) memory_limit: usize,
    pub(file) root_file: String,
    pub(file) root_dir: String,
    pub(file) alt_dir: String,
    pub(file) lint_dir: String, // the project directory whose files report lints; "" for a lone file
    pub(file) bufs: Vector<Buffer>,
    pub(file) pkg: loader::Package,
    pub(file) diags: Vector<an::DiagRec>,
    pub(file) state: u8,
    pub(file) revision: u64,
}

// The provider calls the loader makes during a check (`loader::FileSource`): `ctx` is a `SourceCtx`.
struct SourceCtx {
    pub files: *mut Box<dyn FileProvider>,
    pub err: Option<IoError>,
    pub err_path: String,
}

fn source_read(ctx: *mut void, path: str, out: &mut String) bool {
    let c = unsafe &mut *(ctx as *mut SourceCtx);
    return switch unsafe (*c.files).read(path, out) {
        Ok(b) => b,
        Err(e) => {
            c.note(e, path);
            false;
        },
    };
}

fn source_list(ctx: *mut void, dir: str, out: &mut Vector<String>) bool {
    let c = unsafe &mut *(ctx as *mut SourceCtx);
    return switch unsafe (*c.files).list(dir, out) {
        Ok(b) => b,
        Err(e) => {
            c.note(e, dir);
            false;
        },
    };
}

extend SourceCtx {
    // Keep the first failure: what the session reports.
    fn note(self: &mut Self, e: IoError, path: str) {
        if self.err.is_none() {
            self.err = Option::<IoError>::Some(e);
            self.err_path = String::from_str(path);
        }
    }
}

// The provider of a session lent to a scratch session (`Session::errors_with`), which ends before the call
// that made it returns.
struct Lent {
    pub files: *mut Box<dyn FileProvider>,
}

extend Lent as FileProvider {
    pub fn read(self: &mut Self, path: str, out: &mut String) Result<bool, IoError> {
        return unsafe (*self.files).read(path, out);
    }

    pub fn list(self: &mut Self, dir: str, out: &mut Vector<String>) Result<bool, IoError> {
        return unsafe (*self.files).list(dir, out);
    }
}

// The borrow round's stop poll: the request's cancellation.
fn bc_poll(_ctx: *mut void, _between: bool) bool {
    return loader::poll_stop();
}

extend Session {
    /// A session over the project in directory `dir`: its `build.toml` names the root file and gives the
    /// build settings, and every project file reports lints.
    pub fn open_project(dir: str, cfg: Config) Result<Session, ApiError> {
        let mut s = Session::make(cfg);
        let mp = loader::join2(dir, "build.toml");
        let mut root = String::new();
        let mut text = String::new();
        let read = s.read_file(mp.as_str(), &mut text)?;
        if !read {
            return Result::<Session, ApiError>::Err(
                ApiError::new(Code::InvalidArgument, "the directory holds no build.toml"),
            );
        }
        let (mo, errs) = bman::parse_check(text.as_str(), "", false);
        if mo.is_none() || errs.has_errors() {
            return Result::<Session, ApiError>::Err(
                ApiError::at(Code::ParseFailed, "build.toml does not load", mp.as_str(), 0, 0),
            );
        }
        let m = mo.unwrap();
        root = loader::join2(dir, m.root.as_str());
        s.lint_dir = s.canon(dir);
        s.root_file = s.canon(root.as_str());
        s.root_dir = String::from_str(loader::dirname_of(s.root_file.as_str()));
        return Result::<Session, ApiError>::Ok(s);
    }

    /// A session over the lone file `path`: its directory is its import root.
    pub fn open_file(path: str, cfg: Config) Result<Session, ApiError> {
        let mut s = Session::make(cfg);
        s.root_file = s.canon(path);
        s.root_dir = String::from_str(loader::dirname_of(s.root_file.as_str()));
        return Result::<Session, ApiError>::Ok(s);
    }

    fn make(cfg: Config) Session {
        let mut c = cfg;
        return Session {
            files: replace(&mut c.files, Option::<Box<dyn FileProvider>>::None),
            std_dir: replace(&mut c.std_dir, String::new()),
            target: if c.target < 0 {
                unsafe shim::sc_host_platform();
            } else {
                c.target;
            },
            memory_limit: c.memory_limit,
            pkg: loader::Package::new(),
            state: S_NONE,
        };
    }

    // `path` canonical: the host's real path for the host's files, the provider's name otherwise.
    fn canon(self: &Self, path: str) String {
        if self.files.is_none() {
            return an::canon_path(path);
        }
        return String::from_str(path);
    }

    // The provider's text of `path` into `out`: false when it names no file.
    fn read_file(self: &mut Self, path: str, out: &mut String) Result<bool, ApiError> {
        let mut disk = DiskFiles {};
        let r = switch &mut self.files {
            Some(f) => f.read(path, out),
            None => disk.read(path, out),
        };
        return switch r {
            Ok(b) => Result::<bool, ApiError>::Ok(b),
            Err(e) => Result::<bool, ApiError>::Err(ApiError::io(e, path)),
        };
    }

    // The buffer of `path`, or -1.
    fn buffer(self: &Self, path: str) i64 {
        for i in 0..self.bufs.len() {
            if self.bufs[i].path.as_str() == path {
                return i as i64;
            }
        }
        return -1;
    }

    /// The root file's canonical path.
    pub fn root_file(self: &Self) str {
        return self.root_file.as_str();
    }

    /// The number of input changes so far: every `set_text`, `apply`, `open` and `close` that changed an
    /// input adds one.
    pub fn revision(self: &Self) u64 {
        return self.revision;
    }

    /// The version of file `path`: its buffer's (each change adds one), or -1 for a file the session reads
    /// from its provider.
    pub fn version(self: &Self, path: str) i64 {
        let b = self.buffer(self.canon(path).as_str());
        if b < 0 {
            return -1;
        }
        return self.bufs[b as usize].version;
    }

    /// The text of file `path`: its buffer, else the provider's, else None.
    pub fn text(self: &mut Self, path: str) Result<Option<String>, ApiError> {
        let cp = self.canon(path);
        let b = self.buffer(cp.as_str());
        if b >= 0 {
            return Result::<Option<String>, ApiError>::Ok(Option::<String>::Some(self.bufs[b as usize].text.clone()));
        }
        let mut t = String::new();
        if self.read_file(cp.as_str(), &mut t)? {
            return Result::<Option<String>, ApiError>::Ok(Option::<String>::Some(t));
        }
        return Result::<Option<String>, ApiError>::Ok(Option::<String>::None);
    }

    /// Give file `path` the text `text` (an editor buffer or generated text), version 0 when new. Returns
    /// the new version.
    pub fn set_text(self: &mut Self, path: str, text: str) i64 {
        let cp = self.canon(path);
        let b = self.buffer(cp.as_str());
        self.changed();
        if b < 0 {
            self.bufs.push(Buffer { path: cp, text: String::from_str(text), version: 0 });
            return 0;
        }
        let bb = self.bufs.index_mut(b as usize);
        bb.text = String::from_str(text);
        bb.version += 1;
        return bb.version;
    }

    /// Hold file `path` as a buffer of the provider's current text: the analysis keeps its function bodies
    /// between checks, as it keeps every buffer's. Returns its version.
    pub fn open(self: &mut Self, path: str) Result<i64, ApiError> {
        let cp = self.canon(path);
        let b = self.buffer(cp.as_str());
        if b >= 0 {
            return Result::<i64, ApiError>::Ok(self.bufs[b as usize].version);
        }
        let mut t = String::new();
        if !self.read_file(cp.as_str(), &mut t)? {
            return Result::<i64, ApiError>::Err(ApiError::at(Code::InvalidArgument, "no such file", cp.as_str(), 0, 0));
        }
        self.changed();
        self.bufs.push(Buffer { path: cp, text: t, version: 0 });
        return Result::<i64, ApiError>::Ok(0);
    }

    /// Drop the buffer of `path`: the provider's text applies again. False when it has none.
    pub fn close(self: &mut Self, path: str) bool {
        let cp = self.canon(path);
        let b = self.buffer(cp.as_str());
        if b < 0 {
            return false;
        }
        let gone = self.bufs.remove(b as usize).unwrap();
        self.changed();
        // The analysis updates in place only from buffers: a module whose text goes back to the
        // provider's is analyzed again from scratch.
        let mut t = String::new();
        let same = switch self.read_file(cp.as_str(), &mut t) {
            Ok(b) => b && t.as_str() == gone.text.as_str(),
            Err(_) => false,
        };
        if !same {
            self.reload();
        }
        return true;
    }

    /// Analyze from scratch at the next `check`: the provider's files changed.
    pub fn reload(self: &mut Self) {
        self.revision += 1;
        if self.state != S_NONE {
            self.drop_analysis();
        }
    }

    /// Apply `changes` together: each is checked against the current texts and versions first, and the
    /// first that fails (`InvalidArgument`) leaves every file unchanged. Returns the new revision.
    pub fn apply(self: &mut Self, changes: Slice<Change>) Result<u64, ApiError> {
        let mut texts = Vector::<String>::with_capacity(changes.len());
        let mut paths = Vector::<String>::with_capacity(changes.len());
        for i in 0..changes.len() {
            let c = &changes[i];
            let cp = self.canon(c.path.as_str());
            for k in 0..paths.len() {
                if paths[k].as_str() == cp.as_str() {
                    return Result::<u64, ApiError>::Err(
                        ApiError::at(Code::InvalidArgument, "two changes name one file", cp.as_str(), 0, 0),
                    );
                }
            }
            if c.expected_version >= 0 && self.version(cp.as_str()) != c.expected_version {
                return Result::<u64, ApiError>::Err(
                    ApiError::at(Code::InvalidArgument, "the file is not at the expected version", cp.as_str(), 0, 0),
                );
            }
            if c.edits.len() == 0 && c.replace {
                texts.push(c.text.clone());
            } else {
                let cur = switch self.text(cp.as_str())? {
                    Some(t) => t,
                    None => {
                        return Result::<u64, ApiError>::Err(
                            ApiError::at(Code::InvalidArgument, "no such file", cp.as_str(), 0, 0),
                        );
                    },
                };
                let mut out = String::new();
                if let Err(e) = apply_edits(cur.as_str(), c.edits.as_slice(), &mut out) {
                    let mut ee = e;
                    ee.file = cp.clone();
                    return Result::<u64, ApiError>::Err(ee);
                }
                texts.push(out);
            }
            paths.push(cp);
        }
        for i in 0..paths.len() {
            let _ = self.set_text(paths[i].as_str(), texts[i].as_str());
        }
        return Result::<u64, ApiError>::Ok(self.revision);
    }

    fn changed(self: &mut Self) {
        self.revision += 1;
        if self.state == S_CHECKED {
            self.state = S_STALE;
        }
    }

    /// Whether the analysis is of the current inputs.
    pub fn checked(self: &Self) bool {
        return self.state == S_CHECKED;
    }

    /// Analyze the current inputs: parse, resolve, type check, evaluate constants, borrow check and lint,
    /// as `super-c lint` does, updating the previous analysis in place where the changes allow it. A
    /// cancelled request (`Cancelled`, `Deadline`), a provider failure (`Io`) or a retained analysis over
    /// `Config.memory_limit` (`Limit`) drops the analysis. Diagnostics of the source are results, not
    /// errors: read them with `diagnostics`.
    pub fn check(self: &mut Self) Result<Unit, ApiError> {
        let opts = RequestOptions::none();
        return self.check_with(&opts);
    }

    /// `check` under the cancellation, deadline and limits of `opts`.
    pub fn check_with(self: &mut Self, opts: &RequestOptions) Result<Unit, ApiError> {
        if self.state == S_CHECKED {
            return Result::<Unit, ApiError>::Ok(Unit {});
        }
        let mut req = loader::StopReq {
            tok: switch &opts.cancel {
                Some(t) => t,
                None => null,
            },
            deadline: opts.deadline_ns,
            stopped: false,
        };
        let mut sc = SourceCtx { files: null, err: Option::<IoError>::None };
        let fsrc = loader::FileSource { ctx: &mut sc, read: source_read, list: source_list };
        if let Some(f) = &mut self.files {
            sc.files = f;
            loader::set_files(&fsrc);
        }
        // Load errors reach the client as diagnostics (an import) or as the error below (the root file).
        let mut log = String::new();
        loader::set_load_log(&mut log);
        loader::set_stop(&mut req);
        self.analyze();
        loader::set_stop(null);
        loader::set_load_log(null);
        loader::set_files(null);
        if req.stopped || sc.err.is_some() {
            self.drop_analysis();
            if let Some(e) = sc.err {
                return Result::<Unit, ApiError>::Err(ApiError::io(e, sc.err_path.as_str()));
            }
            let cancelled = switch &opts.cancel {
                Some(t) => t.is_cancelled(),
                None => false,
            };
            return Result::<Unit, ApiError>::Err(
                if cancelled {
                    ApiError::new(Code::Cancelled, "the request was cancelled");
                } else {
                    ApiError::new(Code::Deadline, "the request passed its deadline");
                },
            );
        }
        if log.len() != 0 && !self.root_loaded() {
            self.drop_analysis();
            return Result::<Unit, ApiError>::Err(
                ApiError::at(Code::InvalidArgument, "the root file does not read", self.root_file.as_str(), 0, 0),
            );
        }
        if self.memory_limit != 0 && self.pkg.retained_bytes() > self.memory_limit {
            self.drop_analysis();
            return Result::<Unit, ApiError>::Err(
                ApiError::new(Code::Limit, "the analysis retains more than the session's memory limit"),
            );
        }
        self.state = S_CHECKED;
        return Result::<Unit, ApiError>::Ok(Unit {});
    }

    // Whether the analysis holds the root file's module.
    fn root_loaded(self: &Self) bool {
        for i in 0..self.pkg.modules.len() {
            if self.pkg.modules[i].file.as_str() == self.root_file.as_str() {
                return true;
            }
        }
        return false;
    }

    fn drop_analysis(self: &mut Self) {
        self.pkg = loader::Package::new();
        self.diags = Vector::<an::DiagRec>::new();
        self.state = S_NONE;
    }

    // The analysis of the current inputs: in place when the previous one allows it, else from scratch;
    // then every borrow check it owes.
    fn analyze(self: &mut Self) {
        let mut ovf = Vector::<str>::with_capacity(self.bufs.len());
        let mut ovt = Vector::<str>::with_capacity(self.bufs.len());
        for i in 0..self.bufs.len() {
            ovf.push(self.bufs[i].path.as_str());
            ovt.push(self.bufs[i].text.as_str());
        }
        let mut done = false;
        if self.state == S_STALE && self.pkg.modules.len() != 0 {
            let mut st = an::RecompileStats {};
            let mut d = replace(&mut self.diags, Vector::<an::DiagRec>::new());
            done = an::recompile(
                &mut self.pkg,
                self.target,
                self.root_file.as_str(),
                self.lint_dir.as_str(),
                &ovf,
                &ovt,
                &mut d,
                &mut st,
            );
            self.diags = d;
        }
        if loader::poll_stop() {
            return;
        }
        if !done {
            let mut of = Vector::<String>::with_capacity(self.bufs.len());
            let mut ot = Vector::<String>::with_capacity(self.bufs.len());
            for i in 0..self.bufs.len() {
                of.push(self.bufs[i].path.clone());
                ot.push(self.bufs[i].text.clone());
            }
            // Drop the previous analysis first: holding both doubles the peak.
            self.pkg = loader::Package::new();
            self.diags = Vector::<an::DiagRec>::new();
            self.pkg = an::compile_keeping(
                self.root_file.as_str(),
                self.root_dir.as_str(),
                self.alt_dir.as_str(),
                self.std_dir.as_str(),
                self.target,
                of,
                ot,
                self.lint_dir.as_str(),
                true,
                &mut self.diags,
            );
        }
        // Each round finishes at least one owed check unless stopped.
        for _ in 0..self.pkg.modules.len() + 1 {
            if loader::poll_stop() || !an::borrowck_runnable(&mut self.pkg, &self.diags) {
                return;
            }
            let r = an::borrowck_pending(&mut self.pkg, &mut self.diags, &ovf, bc_poll, null);
            if r.canceled {
                return;
            }
        }
    }

    /// The number of errors the analysis reports with each file `paths[i]` holding `texts[i]` in place of its
    /// current text: a scratch session over the same files and buffers is checked, then dropped. The session
    /// itself does not change.
    pub fn errors_with(self: &mut Self, paths: Slice<String>, texts: Slice<String>) Result<usize, ApiError> {
        let files = switch &mut self.files {
            Some(f) => Option::<Box<dyn FileProvider>>::Some(Box::new(Lent { files: f })),
            None => Option::<Box<dyn FileProvider>>::None,
        };
        let mut scratch = Session {
            files: files,
            std_dir: self.std_dir.clone(),
            target: self.target,
            root_file: self.root_file.clone(),
            root_dir: self.root_dir.clone(),
            alt_dir: self.alt_dir.clone(),
            lint_dir: self.lint_dir.clone(),
            pkg: loader::Package::new(),
            state: S_NONE,
        };
        for i in 0..self.bufs.len() {
            let _ = scratch.set_text(self.bufs[i].path.as_str(), self.bufs[i].text.as_str());
        }
        for i in 0..paths.len() {
            let _ = scratch.set_text(paths[i].as_str(), texts[i].as_str());
        }
        scratch.check()?;
        let mut n: usize = 0;
        for k in 0..scratch.diags.len() {
            if scratch.diags[k].severity == SEV_ERROR {
                n += 1;
            }
        }
        return Result::<usize, ApiError>::Ok(n);
    }

    /// The bytes the analysis retains.
    pub fn retained_bytes(self: &Self) usize {
        return self.pkg.retained_bytes();
    }

    /// The diagnostics of the last `check`, by file then position; `NotChecked` before one.
    pub fn diagnostics(self: &Self) Result<Diagnostics, ApiError> {
        if self.state != S_CHECKED {
            return Result::<Diagnostics, ApiError>::Err(
                ApiError::new(Code::NotChecked, "the session holds no analysis of its current inputs"),
            );
        }
        let mut order = Vector::<u32>::with_capacity(self.diags.len());
        for i in 0..self.diags.len() {
            order.push(i as u32);
        }
        order.sort_stable_by(|a: &u32, b: &u32| self.diag_cmp(*a, *b));
        return Result::<Diagnostics, ApiError>::Ok(Diagnostics { s: self, order: order, at: 0 });
    }

    // Diagnostic order: file path, start, end, severity, then message bytes.
    fn diag_cmp(self: &Self, a: u32, b: u32) i32 {
        let x = &self.diags[a as usize];
        let y = &self.diags[b as usize];
        let c = self.pkg.modules[x.module as usize].file.cmp(&self.pkg.modules[y.module as usize].file);
        if c != 0 {
            return c;
        }
        if x.start != y.start {
            return if x.start < y.start {
                -1;
            } else {
                1;
            };
        }
        if x.len != y.len {
            return if x.len < y.len {
                -1;
            } else {
                1;
            };
        }
        if x.severity != y.severity {
            return x.severity as i32 - y.severity as i32;
        }
        return x.msg.cmp(&y.msg);
    }

    /// The analyzed modules, in load order; `NotChecked` before a `check`.
    pub fn modules(self: &Self) Result<Modules, ApiError> {
        if self.state != S_CHECKED {
            return Result::<Modules, ApiError>::Err(
                ApiError::new(Code::NotChecked, "the session holds no analysis of its current inputs"),
            );
        }
        return Result::<Modules, ApiError>::Ok(Modules { s: self, at: 0 });
    }

    /// The analyzed module of file `path`, or None.
    pub fn module_of(self: &Self, path: str) Option<Module> {
        if self.state != S_CHECKED {
            return Option::<Module>::None;
        }
        let cp = self.canon(path);
        for i in 0..self.pkg.modules.len() {
            if self.pkg.modules[i].file.as_str() == cp.as_str() {
                return Option::<Module>::Some(Module { s: self, i: i as u32 });
            }
        }
        return Option::<Module>::None;
    }

    /// The analysis, for the facade modules that read it. Not part of the API.
    pub(package) fn package(self: &Self) &loader::Package {
        return &self.pkg;
    }

    /// The analysis, for the facade modules that parse bodies back into it. Not part of the API.
    pub(package) fn package_mut(self: &mut Self) &mut loader::Package {
        return &mut self.pkg;
    }
}

/// Severities of a diagnostic.
pub const SEV_ERROR: u8 = 1;
pub const SEV_WARNING: u8 = 2;

/// A diagnostic of a checked session.
pub struct Diag<'s> {
    pub(file) s: &'s Session,
    pub(file) i: u32,
}

extend<'s> Diag<'s> {
    fn rec(self: &Self) &'s an::DiagRec {
        return &self.s.diags[self.i as usize];
    }

    /// The file it concerns.
    pub fn file(self: &Self) str<'s> {
        return self.s.pkg.modules[self.rec().module as usize].file.as_str();
    }

    /// Its byte range in the file's analyzed text.
    pub fn start(self: &Self) u32 {
        return self.rec().start;
    }

    pub fn end(self: &Self) u32 {
        return self.rec().start + self.rec().len;
    }

    /// `SEV_ERROR` or `SEV_WARNING`.
    pub fn severity(self: &Self) u8 {
        return self.rec().severity;
    }

    /// Its stable code (`utils::diag_codes`), what a client branches on; message text is not identity.
    pub fn code(self: &Self) u16 {
        return self.rec().code;
    }

    /// The stable name of its code (`use_of_moved`).
    pub fn code_name(self: &Self) str<'static> {
        return dc::name(self.rec().code);
    }

    /// The message: its first line, then one `= note: ` line per note.
    pub fn message(self: &Self) str<'s> {
        return self.rec().msg.as_str();
    }

    /// The machine-applicable fix, when there is one: the byte range it replaces and the replacement.
    pub fn fix(self: &Self) Option<Edit> {
        let r = self.rec();
        if r.fix_kind < 0 {
            return Option::<Edit>::None;
        }
        let text = switch r.fix_kind {
            1 => String::from_str("_"),
            2 => String::from_str("const "),
            4 => r.fix_text.clone(),
            _ => String::new(),
        };
        let end = if r.fix_kind == 1 || r.fix_kind == 2 {
            r.fix_start;
        } else {
            r.fix_end;
        };
        return Option::<Edit>::Some(Edit { start: r.fix_start, end: end, text: text });
    }
}

/// The diagnostics of a checked session, in order.
pub struct Diagnostics<'s> {
    pub(file) s: &'s Session,
    pub(file) order: Vector<u32>,
    pub(file) at: usize,
}

extend<'s> Diagnostics<'s> as Iterator<Diag<'s>> {
    pub fn next(self: &mut Self) Option<Diag<'s>> {
        if self.at >= self.order.len() {
            return Option::<Diag<'s>>::None;
        }
        self.at += 1;
        return Option::<Diag<'s>>::Some(Diag { s: self.s, i: self.order[self.at - 1] });
    }

    pub fn size_hint(self: &Self) (usize, Option<usize>) {
        let n = self.order.len() - self.at;
        return n, Option::<usize>::Some(n);
    }
}

/// A module of a checked session.
pub struct Module<'s> {
    pub(file) s: &'s Session,
    pub(file) i: u32,
}

extend<'s> Module<'s> {
    /// Its module path (`std::vector`, `api::session`).
    pub fn path(self: &Self) str<'s> {
        return self.s.pkg.modules[self.i as usize].path.as_str();
    }

    /// Its file.
    pub fn file(self: &Self) str<'s> {
        return self.s.pkg.modules[self.i as usize].file.as_str();
    }

    /// Its analyzed text.
    pub fn text(self: &Self) str<'s> {
        return self.s.pkg.modules[self.i as usize].source.as_str();
    }

    /// Whether std's prelude loads it into every program.
    pub fn prelude(self: &Self) bool {
        return self.s.pkg.modules[self.i as usize].prelude;
    }

    /// Its index in load order. Not part of the API.
    pub fn index(self: &Self) u32 {
        return self.i;
    }
}

/// The modules of a checked session, in load order.
pub struct Modules<'s> {
    pub(file) s: &'s Session,
    pub(file) at: u32,
}

extend<'s> Modules<'s> as Iterator<Module<'s>> {
    pub fn next(self: &mut Self) Option<Module<'s>> {
        if self.at as usize >= self.s.pkg.modules.len() {
            return Option::<Module<'s>>::None;
        }
        self.at += 1;
        return Option::<Module<'s>>::Some(Module { s: self.s, i: self.at - 1 });
    }

    pub fn size_hint(self: &Self) (usize, Option<usize>) {
        let n = self.s.pkg.modules.len() - self.at as usize;
        return n, Option::<usize>::Some(n);
    }
}
