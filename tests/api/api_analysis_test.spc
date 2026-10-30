// Analyzers: declaration checks, prerequisite order, facts across imports, failures that stay local,
// budgets, cached results, and the command adapter.
import api::analysis as *;
import api::session as ses;
import api::syntax as syn;
import api::source as *;
import api::errors as *;
import tests::cli_harness as cli;

const MAIN: str = M"(import util;

// TODO: remove
fn main() i32 {
    return util::one() + util::two() - 3;
}
)";

const UTIL: str = M"(pub fn one() i32 {
    return 1;
}

pub fn two() i32 {
    return 2;
}
)";

// Flags every comment that holds "TODO", with a fix that removes it.
struct NoTodo {
    pub runs: u32,
}

extend NoTodo as Analyzer {
    pub fn id(self: &Self) str {
        return "test.no-todo";
    }

    pub fn version(self: &Self) u32 {
        return 1;
    }

    pub fn run(self: &mut Self, pass: &mut Pass) Result<Unit, ApiError> {
        self.runs += 1;
        let t = pass.tree();
        let mut hits = Vector::<syn::TextRange>::new();
        for k in t.tokens() {
            if k.kind() == syn::TokenKind::Comment && k.text().find("TODO") >= 0 {
                hits.push(k.range());
            }
        }
        for i in 0..hits.len() {
            let mut fix = Vector::<Edit>::new();
            fix.push(Edit { start: hits[i].start, end: hits[i].end, text: String::from_str("// done") });
            pass.report_fix(hits[i].start, hits[i].end, ses::SEV_WARNING, "todo", "a TODO is left", fix);
        }
        return Ok(Unit {});
    }
}

// Records the count of `pub fn` items of each module as a fact.
struct PubCount {}

extend PubCount as Analyzer {
    pub fn id(self: &Self) str {
        return "test.pub-count";
    }

    pub fn version(self: &Self) u32 {
        return 1;
    }

    pub fn run(self: &mut Self, pass: &mut Pass) Result<Unit, ApiError> {
        let mut n: u8 = 0;
        for c in pass.tree().root().children() {
            if c.as_fn().is_some() && c.text().starts_with("fn") && pass.tree().text().slice(
                0,
                c.range().start as usize,
            ).ends_with("pub ") {
                n += 1;
            }
        }
        let b: [u8; 1] = [n];
        pass.put_fact("pub_fns", b);
        return Ok(Unit {});
    }
}

// Reports, in each module, the `pub fn` count of the module `util` when it imports it.
struct ImportsCount {}

extend ImportsCount as Analyzer {
    pub fn id(self: &Self) str {
        return "test.imports-count";
    }

    pub fn version(self: &Self) u32 {
        return 1;
    }

    pub fn requires(self: &Self, out: &mut Vector<String>) {
        out.push(String::from_str("test.pub-count"));
    }

    pub fn run(self: &mut Self, pass: &mut Pass) Result<Unit, ApiError> {
        if let Some(b) = pass.fact("test.pub-count", "util", "pub_fns") {
            let msg = format("util has {} pub functions", b[0]);
            pass.report(0, 0, ses::SEV_WARNING, "count", &msg);
        }
        return Ok(Unit {});
    }
}

// Fails on every module.
struct Broken {}

extend Broken as Analyzer {
    pub fn id(self: &Self) str {
        return "test.broken";
    }

    pub fn version(self: &Self) u32 {
        return 1;
    }

    pub fn run(self: &mut Self, pass: &mut Pass) Result<Unit, ApiError> {
        pass.report(0, 0, ses::SEV_ERROR, "never", "dropped with the failure");
        return Err(ApiError::new(Code::PluginFailed, "broken"));
    }
}

// Requires `test.cycle-b`, which requires it.
struct CycleA {}

struct CycleB {}

extend CycleA as Analyzer {
    pub fn id(self: &Self) str {
        return "test.cycle-a";
    }

    pub fn version(self: &Self) u32 {
        return 1;
    }

    pub fn requires(self: &Self, out: &mut Vector<String>) {
        out.push(String::from_str("test.cycle-b"));
    }

    pub fn run(self: &mut Self, pass: &mut Pass) Result<Unit, ApiError> {
        return Ok(Unit {});
    }
}

extend CycleB as Analyzer {
    pub fn id(self: &Self) str {
        return "test.cycle-b";
    }

    pub fn version(self: &Self) u32 {
        return 1;
    }

    pub fn requires(self: &Self, out: &mut Vector<String>) {
        out.push(String::from_str("test.cycle-a"));
    }

    pub fn run(self: &mut Self, pass: &mut Pass) Result<Unit, ApiError> {
        return Ok(Unit {});
    }
}

struct Fx {
    pub proj: cli::Proj,
    pub main: String,
    pub s: ses::Session,
}

@test_init
fn fx() Fx {
    let proj = cli::proj_new();
    proj.mkfile("main.spc", MAIN);
    proj.mkfile("util.spc", UTIL);
    let main = format("{}/main.spc", proj.dir());
    let mut s = ses::Session::open_file(&main, ses::Config::host("std")).unwrap();
    assert(s.check().is_ok(), "checks");
    let real = String::from_str(s.root_file());
    return Fx { proj: proj, main: real, s: s };
}

@test
fn rejects_bad_declarations() {
    let mut cyc = Vector::<Box<dyn Analyzer>>::new();
    cyc.push(Box::new(CycleA {}));
    cyc.push(Box::new(CycleB {}));
    assert(Runner::new(cyc).unwrap_err().code == Code::InvalidArgument, "a cycle rejects");
    let mut missing = Vector::<Box<dyn Analyzer>>::new();
    missing.push(Box::new(ImportsCount {}));
    assert(Runner::new(missing).unwrap_err().code == Code::InvalidArgument, "an unknown requirement rejects");
    let mut twice = Vector::<Box<dyn Analyzer>>::new();
    twice.push(Box::new(PubCount {}));
    twice.push(Box::new(PubCount {}));
    assert(Runner::new(twice).unwrap_err().code == Code::InvalidArgument, "a repeated id rejects");
}

@test
fn runs_prerequisites_and_reads_their_facts(fx: &mut Fx) {
    let mut list = Vector::<Box<dyn Analyzer>>::new();
    list.push(Box::new(ImportsCount {}));
    list.push(Box::new(PubCount {}));
    list.push(Box::new(NoTodo { runs: 0 }));
    list.push(Box::new(Broken {}));
    let mut r = Runner::new(list).unwrap();
    let opts = ses::RequestOptions::none();
    let res = r.run(&fx.s, &opts).unwrap();
    let mut todo: usize = 0;
    let mut count: usize = 0;
    for i in 0..res.findings.len() {
        let f = &res.findings[i];
        assert(f.analyzer.as_str() != "test.broken", "a failed analyzer keeps no finding");
        if f.rule.as_str() == "todo" {
            todo += 1;
            assert(f.file.as_str() == fx.main.as_str() && f.fix.len() == 1, "the TODO of main, with its fix");
        }
        if f.rule.as_str() == "count" {
            count += 1;
            assert_eq(f.message.as_str(), "util has 2 pub functions");
        }
    }
    assert_eq(todo, 1);
    assert_eq(count, 1);
    assert_eq(res.failures.len(), 2);
    assert(res.failures[0].error.code == Code::PluginFailed, "each module's failure is reported");
}

@test
fn reuses_results_until_an_input_changes(fx: &mut Fx) {
    let mut list = Vector::<Box<dyn Analyzer>>::new();
    list.push(Box::new(NoTodo { runs: 0 }));
    let mut r = Runner::new(list).unwrap();
    let opts = ses::RequestOptions::none();
    let a = r.run(&fx.s, &opts).unwrap();
    let b = r.run(&fx.s, &opts).unwrap();
    assert_eq(a.findings.len(), b.findings.len());
    let _ = fx.s.set_text(&fx.main, "fn main() i32 {\n    return 0;\n}\n");
    assert(fx.s.check().is_ok(), "checks");
    let c = r.run(&fx.s, &opts).unwrap();
    assert_eq(c.findings.len(), 0);
}

@test
fn applies_its_budget(fx: &mut Fx) {
    let mut list = Vector::<Box<dyn Analyzer>>::new();
    list.push(Box::new(PubCount {}));
    let mut r = Runner::new(list).unwrap();
    r.set_budget(Budget { time_ns: 0, fact_bytes: 4 });
    let opts = ses::RequestOptions::none();
    let res = r.run(&fx.s, &opts).unwrap();
    assert(res.failures.len() >= 1 && res.failures[0].error.code == Code::Limit, "a fact budget applies");
}

@test
fn serves_as_a_command(fx: &mut Fx) {
    let mut list = Vector::<Box<dyn Analyzer>>::new();
    list.push(Box::new(NoTodo { runs: 0 }));
    let mut args = Vector::<str>::new();
    args.push("tool");
    args.push("--fix");
    args.push(&fx.main);
    assert_eq(main_with(&args, list), 1);
    assert(cli::read_text(&fx.main).as_str().find("// done") >= 0, "the fix is written");
}

// Reports its configuration text, read through the pass, and the root file of the session it sees.
struct Configured {}

extend Configured as Analyzer {
    pub fn id(self: &Self) str {
        return "test.configured";
    }

    pub fn version(self: &Self) u32 {
        return 1;
    }

    pub fn run(self: &mut Self, pass: &mut Pass) Result<Unit, ApiError> {
        if pass.file() == pass.session().root_file() {
            let msg = format("config {}", pass.config());
            pass.report(0, 0, ses::SEV_WARNING, "config", &msg);
        }
        return Ok(Unit {});
    }
}

@test
fn passes_configuration_and_the_session(fx: &mut Fx) {
    let mut list = Vector::<Box<dyn Analyzer>>::new();
    list.push(Box::new(Configured {}));
    let mut r = Runner::new(list).unwrap();
    assert(r.configure("test.configured", "level=2"), "the analyzer takes its configuration");
    assert(!r.configure("test.none", "x"), "an unknown analyzer takes none");
    let opts = ses::RequestOptions::none();
    let res = r.run(&fx.s, &opts).unwrap();
    assert_eq(res.findings.len(), 1);
    assert_eq(res.findings[0].message.as_str(), "config level=2");
}

@test
fn lints_a_project_with_its_tools() {
    let proj = cli::proj_new();
    proj.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    proj.mkfile("src/main.spc", MAIN);
    proj.mkfile("src/util.spc", UTIL);
    let mut list = Vector::<Box<dyn Analyzer>>::new();
    list.push(Box::new(NoTodo { runs: 0 }));
    assert_eq(lint_tools("std", proj.dir(), list), 1);
}
