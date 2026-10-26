// Analyzers: checks a tool declares once and runs over the modules of a checked session. An analyzer reads
// the session and the module's syntax tree, reports findings with optional fixes, and records facts that the
// analyzers which require it read when they analyze the modules importing this one. Modules run imports
// first; the analyzers of one module run in prerequisite order. A finding, a fact or a failure is a result,
// never a change of the session. Results are sorted, so they do not depend on the order work finished in.
import api::errors as *;
import api::session as ses;
import api::syntax as syn;
import api::source as *;
import module::loader as loader;
import driver::util as dutil;
import std::platform::clock;
import stdlib;

/// One finding: a range of a file, its severity (`ses::SEV_ERROR`, `ses::SEV_WARNING`), the analyzer and
/// its rule (both stable names), a message, and the edits of its fix (none: no fix).
pub struct Finding {
    pub file: String,
    pub start: u32,
    pub end: u32,
    pub severity: u8,
    pub analyzer: String,
    pub rule: String,
    pub message: String,
    pub fix: Vector<Edit>,
}

/// A check a tool runs over a session's modules.
pub interface Analyzer {
    /// Its stable name, reverse-domain style: `org.example.no-unwrap`.
    fn id(self: &Self) str;

    /// Its version: a new one makes every cached result and fact of it stale.
    fn version(self: &Self) u32;

    /// The analyzers whose facts it reads, by id.
    fn requires(self: &Self, out: &mut Vector<String>) {}

    /// Analyze the module of `pass`.
    fn run(self: &mut Self, pass: &mut Pass) Result<Unit, ApiError>;
}

/// What one analyzer sees of one module, and where it reports.
pub struct Pass<'p> {
    pub(file) s: &'p ses::Session,
    pub(file) tree: &'p syn::SyntaxTree,
    pub(file) module: u32,
    pub(file) id: str<'p>,
    pub(file) config: str<'p>,
    pub(file) reads: Slice<'p, u32>, // the analyzers whose facts it reads (`Runner.list` indexes)
    pub(file) run: &'p mut Run,
    pub(file) out: Vector<Finding>,
    pub(file) facts: Vector<Fact>,
    pub(file) fact_bytes: usize,
}

// One fact: an analyzer, a module, a key, and its bytes.
struct Fact {
    pub analyzer: u32,
    pub module: String,
    pub key: String,
    pub bytes: Vector<u8>,
}

extend<'p> Pass<'p> {
    /// The checked session.
    pub fn session(self: &Self) &'p ses::Session {
        return self.s;
    }

    /// The module's file.
    pub fn file(self: &Self) str<'p> {
        return self.s.package().modules[self.module as usize].file.as_str();
    }

    /// The module's path (`app::util`).
    pub fn module_path(self: &Self) str<'p> {
        return self.s.package().modules[self.module as usize].path.as_str();
    }

    /// The module's syntax tree.
    pub fn tree(self: &Self) &'p syn::SyntaxTree {
        return self.tree;
    }

    /// The analyzer's configuration text (`[tools.<id>]` of the project's build.toml, or what the runner
    /// was given); empty when none.
    pub fn config(self: &Self) str<'p> {
        return self.config;
    }

    /// Report `message` at bytes `[start, end)` of the module's file, under rule `rule`.
    pub fn report(self: &mut Self, start: u32, end: u32, severity: u8, rule: str, message: str) {
        self.report_fix(start, end, severity, rule, message, Vector::<Edit>::new());
    }

    /// `report`, with the edits of the module's file that fix it.
    pub fn report_fix(self: &mut Self, start: u32, end: u32, severity: u8, rule: str, message: str, fix: Vector<Edit>) {
        self.out.push(
            Finding {
                file: String::from_str(self.file()),
                start: start,
                end: end,
                severity: severity,
                analyzer: String::from_str(self.id),
                rule: String::from_str(rule),
                message: String::from_str(message),
                fix: fix,
            },
        );
    }

    /// Record fact `key` of this module: `bytes`, which the analyzers that require this one read when they
    /// analyze a module that imports this one. A second fact of one key replaces the first.
    pub fn put_fact(self: &mut Self, key: str, bytes: Slice<u8>) {
        for i in 0..self.facts.len() {
            if self.facts[i].key.as_str() == key {
                self.fact_bytes = self.fact_bytes - self.facts[i].bytes.len() + bytes.len();
                self.facts[i].bytes.clear();
                self.facts[i].bytes.extend_from_slice(bytes);
                return;
            }
        }
        let mut b = Vector::<u8>::with_capacity(bytes.len());
        b.extend_from_slice(bytes);
        self.fact_bytes += bytes.len() + key.len();
        self.facts.push(
            Fact { analyzer: NONE, module: String::from_str(self.module_path()), key: String::from_str(key), bytes: b },
        );
    }

    /// Fact `key` that analyzer `analyzer` (this one, or one it requires) recorded for module `module`, which
    /// this module imports, directly or through others; None when there is none or the module is no import.
    pub fn fact(self: &Self, analyzer: str, module: str, key: str) Option<Slice<u8>> {
        let mut ai = NONE;
        for i in 0..self.reads.len() {
            if self.run.ids[self.reads[i] as usize].as_str() == analyzer {
                ai = self.reads[i];
            }
        }
        if ai == NONE || !self.run.reaches(self.module, module) {
            return Option::<Slice<u8>>::None;
        }
        for i in 0..self.run.facts.len() {
            let f = &self.run.facts[i];
            if f.analyzer == ai && f.module.as_str() == module && f.key.as_str() == key {
                return Option::<Slice<u8>>::Some(f.bytes.as_slice());
            }
        }
        return Option::<Slice<u8>>::None;
    }
}

const NONE: u32 = 0xFFFFFFFF;

/// An analyzer that failed on a module: its error, and nothing it reported there is kept.
pub struct Failure {
    pub analyzer: String,
    pub file: String,
    pub error: ApiError,
}

/// The results of one run, sorted: findings by file, start, end, analyzer, rule and message; failures by
/// analyzer then file.
pub struct Results {
    pub findings: Vector<Finding>,
    pub failures: Vector<Failure>,
}

/// Limits of one run, per analyzer and module: its time in nanoseconds and its fact bytes (0: none).
pub struct Budget {
    pub time_ns: u64,
    pub fact_bytes: usize,
}

// The state the passes of one run share.
struct Run {
    pub ids: Vector<String>,
    pub facts: Vector<Fact>,
    pub closure: Vector<Vector<bool>>, // per module: the modules it imports, directly or not
    pub paths: Vector<String>,
}

extend Run {
    // Whether module `m` imports the module of path `path`.
    fn reaches(self: &Self, m: u32, path: str) bool {
        for k in 0..self.paths.len() {
            if self.paths[k].as_str() == path {
                return self.closure[m as usize][k];
            }
        }
        return false;
    }
}

// A cached result of one analyzer on one module: what made it, and what it produced.
struct Cached {
    pub analyzer: u32,
    pub module: String,
    pub key: u64,
    pub findings: Vector<Finding>,
    pub facts: Vector<Fact>,
}

/// A set of analyzers, checked once, run over sessions. It keeps each analyzer's results per module and
/// reuses them while the module's text, the analyzer's version and configuration, and the facts it reads
/// stay the same.
pub struct Runner {
    pub(file) list: Vector<Box<dyn Analyzer>>,
    pub(file) order: Vector<u32>, // prerequisites first
    pub(file) reads: Vector<Vector<u32>>, // per analyzer: itself and the analyzers it requires, transitively
    pub(file) config: Vector<String>,
    pub(file) budget: Budget,
    pub(file) cache: Vector<Cached>,
}

extend Runner {
    /// A runner of `list`. `InvalidArgument` for an empty or repeated id, a requirement no analyzer of the
    /// list has, or a cycle of requirements.
    pub fn new(list: Vector<Box<dyn Analyzer>>) Result<Runner, ApiError> {
        let n = list.len();
        let mut ids = Vector::<String>::with_capacity(n);
        for i in 0..n {
            let id = list[i].id();
            if id.len() == 0 {
                return Result::<Runner, ApiError>::Err(
                    ApiError::new(Code::InvalidArgument, "an analyzer has an empty id"),
                );
            }
            for k in 0..ids.len() {
                if ids[k].as_str() == id {
                    return Result::<Runner, ApiError>::Err(
                        ApiError::new(Code::InvalidArgument, "two analyzers share an id"),
                    );
                }
            }
            ids.push(String::from_str(id));
        }
        let mut deps = Vector::<Vector<u32>>::with_capacity(n);
        for i in 0..n {
            let mut req = Vector::<String>::new();
            list[i].requires(&mut req);
            let mut d = Vector::<u32>::new();
            for r in 0..req.len() {
                let mut k: usize = 0;
                while k < n && ids[k].as_str() != req[r].as_str() {
                    k += 1;
                }
                if k == n {
                    return Result::<Runner, ApiError>::Err(
                        ApiError::new(Code::InvalidArgument, "an analyzer requires one the runner does not have"),
                    );
                }
                d.push(k as u32);
            }
            deps.push(d);
        }
        // Prerequisites first, by depth-first post-order; a node seen on the path is a cycle.
        let mut order = Vector::<u32>::with_capacity(n);
        let mut state = Vector::<u8>::new();
        state.resize_default(n);
        for i in 0..n {
            if !visit(&deps, i as u32, &mut state, &mut order) {
                return Result::<Runner, ApiError>::Err(
                    ApiError::new(Code::InvalidArgument, "the analyzers' requirements form a cycle"),
                );
            }
        }
        let mut reads = Vector::<Vector<u32>>::with_capacity(n);
        for i in 0..n {
            let mut seen = Vector::<bool>::new();
            seen.resize_default(n);
            let mut stack = Vector::<u32>::new();
            stack.push(i as u32);
            let mut r = Vector::<u32>::new();
            // Each analyzer enters the stack once.
            while let Some(k) = stack.pop() {
                if seen[k as usize] {
                    continue;
                }
                seen[k as usize] = true;
                r.push(k);
                for j in 0..deps[k as usize].len() {
                    stack.push(deps[k as usize][j]);
                }
            }
            r.sort();
            reads.push(r);
        }
        let mut config = Vector::<String>::with_capacity(n);
        config.resize_default(n);
        return Result::<Runner, ApiError>::Ok(
            Runner { list: list, order: order, reads: reads, config: config, budget: Budget {} },
        );
    }

    /// Give analyzer `id` the configuration text `text`; false when no analyzer has that id.
    pub fn configure(self: &mut Self, id: str, text: str) bool {
        for i in 0..self.list.len() {
            if self.list[i].id() == id {
                self.config[i] = String::from_str(text);
                return true;
            }
        }
        return false;
    }

    /// Limit each analyzer's time and fact bytes per module.
    pub fn set_budget(self: &mut Self, b: Budget) {
        self.budget = b;
    }

    /// Run every analyzer over every module of the checked session `s` outside std and `ffi/`. An analyzer
    /// that fails, or passes its budget, on a module is a failure there; the others go on. `NotChecked`
    /// before a check; `Cancelled` or `Deadline` when `opts` stops the run between two passes.
    pub fn run(self: &mut Self, s: &ses::Session, opts: &ses::RequestOptions) Result<Results, ApiError> {
        if !s.checked() {
            return Result::<Results, ApiError>::Err(
                ApiError::new(Code::NotChecked, "the session holds no analysis of its current inputs"),
            );
        }
        let p = s.package();
        let nm = p.modules.len();
        let mut run = Run {
            ids: Vector::<String>::new(),
            facts: Vector::<Fact>::new(),
            closure: closures(p),
            paths: Vector::<String>::new(),
        };
        for i in 0..self.list.len() {
            run.ids.push(String::from_str(self.list[i].id()));
        }
        for m in 0..nm {
            run.paths.push(p.modules[m].path.clone());
        }
        let mut res = Results { findings: Vector::<Finding>::new(), failures: Vector::<Failure>::new() };
        let mods = import_order(p);
        for mi in 0..mods.len() {
            let m = mods[mi];
            let md = &p.modules[m as usize];
            if md.pkg == loader::PKG_STD || md.pkg == loader::PKG_FFI || md.file.len() == 0 || !md.has_ast {
                continue;
            }
            let tree = syn::SyntaxTree::parse(md.file.as_str(), md.source.as_str());
            for oi in 0..self.order.len() {
                if let Some(e) = stopped(opts) {
                    return Result::<Results, ApiError>::Err(e);
                }
                let a = self.order[oi];
                let key = self.cache_key(&run, m, a, md.src_id);
                let ci = self.cached(a, md.path.as_str(), key);
                if ci >= 0 {
                    let c = &self.cache[ci as usize];
                    for k in 0..c.findings.len() {
                        res.findings.push(c.findings[k].clone());
                    }
                    for k in 0..c.facts.len() {
                        run.facts.push(c.facts[k].clone());
                    }
                    continue;
                }
                let t0 = clock::monotonic_ns();
                let aid = run.ids[a as usize].clone();
                let mut pass = Pass {
                    s: s,
                    tree: &tree,
                    module: m,
                    id: aid.as_str(),
                    config: self.config[a as usize].as_str(),
                    reads: self.reads[a as usize].as_slice(),
                    run: &mut run,
                    out: Vector::<Finding>::new(),
                    facts: Vector::<Fact>::new(),
                    fact_bytes: 0,
                };
                let r = self.list[a as usize].run(&mut pass);
                let spent = clock::monotonic_ns() - t0;
                let out = replace(&mut pass.out, Vector::<Finding>::new());
                let mut facts = replace(&mut pass.facts, Vector::<Fact>::new());
                let fb = pass.fact_bytes;
                let mut err = switch r {
                    Ok(_) => Option::<ApiError>::None,
                    Err(e) => Option::<ApiError>::Some(e),
                };
                if err.is_none() && self.budget.time_ns != 0 && spent > self.budget.time_ns {
                    err = Option::<ApiError>::Some(ApiError::new(Code::Limit, "the analyzer passed its time budget"));
                }
                if err.is_none() && self.budget.fact_bytes != 0 && fb > self.budget.fact_bytes {
                    err = Option::<ApiError>::Some(ApiError::new(Code::Limit, "the analyzer passed its fact budget"));
                }
                if let Some(e) = err {
                    res.failures.push(
                        Failure { analyzer: run.ids[a as usize].clone(), file: md.file.clone(), error: e },
                    );
                    continue;
                }
                for k in 0..facts.len() {
                    facts[k].analyzer = a;
                }
                facts.sort_by(|x: &Fact, y: &Fact| x.key.cmp(&y.key));
                for k in 0..out.len() {
                    res.findings.push(out[k].clone());
                }
                for k in 0..facts.len() {
                    run.facts.push(facts[k].clone());
                }
                self.store(a, md.path.as_str(), key, out, facts);
            }
        }
        res.findings.sort_by(|x: &Finding, y: &Finding| finding_cmp(x, y));
        res.failures.sort_by(
            |x: &Failure, y: &Failure| {
                let c = x.analyzer.cmp(&y.analyzer);
                if c != 0 {
                    return c;
                }
                return x.file.cmp(&y.file);
            },
        );
        return Result::<Results, ApiError>::Ok(res);
    }

    // The key of analyzer `a`'s result on module `m` whose text has identity `src`: the analyzer's id,
    // version and configuration, the text, and every fact it can read (its own and its prerequisites',
    // of the modules `m` imports).
    fn cache_key(self: &Self, run: &Run, m: u32, a: u32, src: u64) u64 {
        let mut h = fnv_str(0xcbf29ce484222325, run.ids[a as usize].as_str());
        h = fnv_u64(h, self.list[a as usize].version());
        h = fnv_str(h, self.config[a as usize].as_str());
        h = fnv_u64(h, src);
        for i in 0..run.facts.len() {
            let f = &run.facts[i];
            if !self.reads[a as usize].contains(&f.analyzer) || !run.reaches(m, f.module.as_str()) {
                continue;
            }
            h = fnv_u64(h, f.analyzer);
            h = fnv_str(h, f.module.as_str());
            h = fnv_str(h, f.key.as_str());
            h = fnv_bytes(h, f.bytes.as_slice());
        }
        return h;
    }

    fn cached(self: &Self, a: u32, module: str, key: u64) i64 {
        for i in 0..self.cache.len() {
            let c = &self.cache[i];
            if c.analyzer == a && c.key == key && c.module.as_str() == module {
                return i as i64;
            }
        }
        return -1;
    }

    // Keep analyzer `a`'s result on `module`, replacing an older one.
    fn store(self: &mut Self, a: u32, module: str, key: u64, findings: Vector<Finding>, facts: Vector<Fact>) {
        for i in 0..self.cache.len() {
            if self.cache[i].analyzer == a && self.cache[i].module.as_str() == module {
                self.cache[i] = Cached {
                    analyzer: a,
                    module: String::from_str(module),
                    key: key,
                    findings: findings,
                    facts: facts,
                };
                return;
            }
        }
        self.cache.push(
            Cached { analyzer: a, module: String::from_str(module), key: key, findings: findings, facts: facts },
        );
    }
}

// The stop of a request: its token or its deadline.
fn stopped(opts: &ses::RequestOptions) Option<ApiError> {
    if let Some(t) = &opts.cancel {
        if t.is_cancelled() {
            return Option::<ApiError>::Some(ApiError::new(Code::Cancelled, "the request was cancelled"));
        }
    }
    if opts.deadline_ns != 0 && clock::monotonic_ns() >= opts.deadline_ns {
        return Option::<ApiError>::Some(ApiError::new(Code::Deadline, "the request passed its deadline"));
    }
    return Option::<ApiError>::None;
}

// Depth-first post-order of the requirement graph `deps` from `i`: false on a cycle. `state`: 0 new, 1 on
// the path, 2 done.
fn visit(deps: &Vector<Vector<u32>>, i: u32, state: &mut Vector<u8>, order: &mut Vector<u32>) bool {
    if state[i as usize] == 2 {
        return true;
    }
    if state[i as usize] == 1 {
        return false;
    }
    state[i as usize] = 1;
    for k in 0..deps[i as usize].len() {
        if !visit(deps, deps[i as usize][k], state, order) {
            return false;
        }
    }
    state[i as usize] = 2;
    order.push(i);
    return true;
}

// The modules in import order: a module after every module it imports (an import cycle in load order).
fn import_order(p: &loader::Package) Vector<u32> {
    let n = p.modules.len();
    let mut state = Vector::<u8>::new();
    state.resize_default(n);
    let mut out = Vector::<u32>::with_capacity(n);
    for m in 0..n {
        if state[m] != 0 {
            continue;
        }
        // An explicit stack of (module, next import): import chains can be as long as the module count.
        let mut stack = Vector::<(u32, u32)>::new();
        stack.push((m as u32, 0));
        state[m] = 1;
        while stack.len() != 0 {
            let top = stack.len() - 1;
            let (cur, k) = stack[top];
            let lo = p.idx.mod_imports[cur as usize];
            let hi = p.idx.mod_imports[cur as usize + 1];
            if lo + k < hi {
                stack[top] = (cur, k + 1);
                let c = p.idx.imports[(lo + k) as usize];
                if state[c as usize] == 0 {
                    state[c as usize] = 1;
                    stack.push((c, 0));
                }
            } else {
                let _ = stack.pop();
                out.push(cur);
            }
        }
    }
    return out;
}

// Per module, the modules it imports directly or through others.
fn closures(p: &loader::Package) Vector<Vector<bool>> {
    let n = p.modules.len();
    let mut out = Vector::<Vector<bool>>::with_capacity(n);
    for m in 0..n {
        let mut seen = Vector::<bool>::new();
        seen.resize_default(n);
        let mut stack = Vector::<u32>::new();
        stack.push(m as u32);
        // Each module enters the stack once.
        while let Some(cur) = stack.pop() {
            for e in p.idx.mod_imports[cur as usize]..p.idx.mod_imports[cur as usize + 1] {
                let c = p.idx.imports[e as usize];
                if !seen[c as usize] {
                    seen[c as usize] = true;
                    stack.push(c);
                }
            }
        }
        out.push(seen);
    }
    return out;
}

fn finding_cmp(x: &Finding, y: &Finding) i32 {
    let c = x.file.cmp(&y.file);
    if c != 0 {
        return c;
    }
    if x.start != y.start {
        return x.start.cmp(&y.start);
    }
    if x.end != y.end {
        return x.end.cmp(&y.end);
    }
    let c2 = x.analyzer.cmp(&y.analyzer);
    if c2 != 0 {
        return c2;
    }
    let c3 = x.rule.cmp(&y.rule);
    if c3 != 0 {
        return c3;
    }
    return x.message.cmp(&y.message);
}

fn fnv_u64(h: u64, v: u64) u64 {
    let mut x = h;
    for i in 0..8 {
        x = (x ^ v >> (i * 8) as u64 & 0xFF).wrapping_mul(0x100000001b3);
    }
    return x;
}

fn fnv_bytes(h: u64, b: Slice<u8>) u64 {
    let mut x = fnv_u64(h, b.len() as u64);
    for i in 0..b.len() {
        x = (x ^ b[i] as u64).wrapping_mul(0x100000001b3);
    }
    return x;
}

fn fnv_str(h: u64, s: str) u64 {
    let mut x = fnv_u64(h, s.len() as u64);
    for i in 0..s.len() {
        x = (x ^ s.byte_at(i) as u64).wrapping_mul(0x100000001b3);
    }
    return x;
}

/// `Finding` and `Fact` copies for the cache.
extend Finding as Clone {
    pub fn clone(self: &Self) Finding {
        let mut fx = Vector::<Edit>::with_capacity(self.fix.len());
        for i in 0..self.fix.len() {
            fx.push(Edit { start: self.fix[i].start, end: self.fix[i].end, text: self.fix[i].text.clone() });
        }
        return Finding {
            file: self.file.clone(),
            start: self.start,
            end: self.end,
            severity: self.severity,
            analyzer: self.analyzer.clone(),
            rule: self.rule.clone(),
            message: self.message.clone(),
            fix: fx,
        };
    }
}

extend Fact as Clone {
    pub fn clone(self: &Self) Fact {
        let mut b = Vector::<u8>::with_capacity(self.bytes.len());
        b.extend_copy(&self.bytes);
        return Fact { analyzer: self.analyzer, module: self.module.clone(), key: self.key.clone(), bytes: b };
    }
}

/// Run `analyzers` as a command: `<tool> [--fix] [<project directory or file>]` (default: the current
/// directory, a project when it holds a build.toml). Prints each finding as `file:line:col: severity: message
/// [analyzer/rule]` and each failure, and with `--fix` applies every fix to the files. The std directory is
/// `SC_STD_DIR`, else `std` beside the working directory. Exit status: 0 without findings, 1 with findings or
/// failures, 2 when the input does not check.
pub fn main_with(args: Slice<str>, analyzers: Vector<Box<dyn Analyzer>>) i32 {
    let mut fix = false;
    let mut target = ".";
    for i in 1..args.len() {
        if args[i] == "--fix" {
            fix = true;
        } else {
            target = args[i];
        }
    }
    let std_dir = stdlib_env("SC_STD_DIR", "std");
    let manifest = loader::join2(target, "build.toml");
    let opened = if dutil::file_mtime(manifest.as_str()) != 0 {
        ses::Session::open_project(target, ses::Config::host(std_dir.as_str()));
    } else {
        ses::Session::open_file(target, ses::Config::host(std_dir.as_str()));
    };
    let mut s = switch opened {
        Ok(s) => s,
        Err(e) => {
            eprintln("error: {}", e.message.as_str());
            return 2;
        },
    };
    return run_and_print(&mut s, analyzers, fix);
}

// Check `s`, run `analyzers` over it, and print what they find; `fix` applies the fixes to the files.
fn run_and_print(s: &mut ses::Session, analyzers: Vector<Box<dyn Analyzer>>, fix: bool) i32 {
    if let Err(e) = s.check() {
        eprintln("error: {}", e.message.as_str());
        return 2;
    }
    let mut runner = switch Runner::new(analyzers) {
        Ok(r) => r,
        Err(e) => {
            eprintln("error: {}", e.message.as_str());
            return 2;
        },
    };
    let opts = ses::RequestOptions::none();
    let res = switch runner.run(s, &opts) {
        Ok(r) => r,
        Err(e) => {
            eprintln("error: {}", e.message.as_str());
            return 2;
        },
    };
    let mut edits = syn::WorkspaceEdit::new();
    for i in 0..res.findings.len() {
        let f = &res.findings[i];
        let text = s.text(f.file.as_str()).unwrap_or(Option::<String>::None).unwrap_or(String::new());
        let (line, col) = line_col(text.as_str(), f.start);
        println(
            "{}:{}:{}: {}: {} [{}/{}]",
            f.file.as_str(),
            line,
            col,
            if f.severity == ses::SEV_ERROR {
                "error";
            } else {
                "warning";
            },
            f.message.as_str(),
            f.analyzer.as_str(),
            f.rule.as_str(),
        );
        for k in 0..f.fix.len() {
            edits.replace(f.file.as_str(), f.fix[k].start, f.fix[k].end, f.fix[k].text.as_str());
        }
    }
    for i in 0..res.failures.len() {
        let e = &res.failures[i];
        println("{}: error: analyzer {} failed: {}", e.file.as_str(), e.analyzer.as_str(), e.error.message.as_str());
    }
    if fix && edits.edits.len() != 0 {
        switch edits.preview(s) {
            Ok(files) => {
                for i in 0..files.len() {
                    if !dutil::write_file_atomic(files[i].file.as_str(), files[i].text.as_str()) {
                        eprintln("error: cannot write '{}'", files[i].file.as_str());
                        return 2;
                    }
                }
            },
            Err(e) => {
                eprintln("error: the fixes do not apply: {}", e.message.as_str());
                return 2;
            },
        };
    }
    return if res.findings.len() != 0 || res.failures.len() != 0 {
        1;
    } else {
        0;
    };
}

// Environment variable `name`, else `default`.
fn stdlib_env(name: str, default: str) String {
    let v = stdlib::get_env(name).unwrap_or(String::new());
    if v.len() == 0 {
        return String::from_str(default);
    }
    return v;
}

// The 1-based line and byte column of offset `off` in `text`.
fn line_col(text: str, off: u32) (u32, u32) {
    let mut line: u32 = 1;
    let mut ls: usize = 0;
    let end = (off as usize).min(text.len());
    for i in 0..end {
        if text.byte_at(i) == b'\n' {
            line += 1;
            ls = i + 1;
        }
    }
    return line, (end - ls) as u32 + 1;
}

/// The analyzers of a project's tool compiler (`api::cli::LintTools`): `analyzers` over the project in directory
/// `project`, std read from `std_dir`; each finding and failure printed as `main_with` prints them. Exit
/// status: 0 without findings, 1 with findings or failures, 2 when the project does not check.
pub fn lint_tools(std_dir: str, project: str, analyzers: Vector<Box<dyn Analyzer>>) i32 {
    let mut s = switch ses::Session::open_project(project, ses::Config::host(std_dir)) {
        Ok(s) => s,
        Err(e) => {
            eprintln("error: {}", e.message.as_str());
            return 2;
        },
    };
    return run_and_print(&mut s, analyzers, false);
}
