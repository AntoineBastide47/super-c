// The compiler API session: analysis of a project through the language server's entry points, buffers and
// edits checked before they apply, file providers, cancellation, budgets, and the vendored-package import
// rule a client of a vendored compiler depends on.
import api::session as *;
import api::source as *;
import api::errors as *;
import tests::cli_harness as cli;
import std::parallel::task as ptask;
import std::parallel::thread;
import std::platform::clock;
import stdlib;

const MAIN: str = M"(import util;

fn main() i32 {
    return util::twice(2) - 4;
}
)";

const UTIL: str = M"(pub fn twice(x: i32) i32 {
    return x + x;
}
)";

const UTIL_BAD: str = M"(pub fn twice(x: i32) i32 {
    let b: bool = 3;
    return x + x;
}
)";

struct Fx {
    pub proj: cli::Proj,
    pub main: String,
    pub util: String,
}

@test_init
fn fx() Fx {
    let proj = cli::proj_new();
    proj.mkfile("main.spc", MAIN);
    proj.mkfile("util.spc", UTIL);
    let main = format("{}/main.spc", proj.dir());
    let util = format("{}/util.spc", proj.dir());
    return Fx { proj: proj, main: main, util: util };
}

fn errors_of(s: &Session) usize {
    let mut n: usize = 0;
    for d in s.diagnostics().unwrap() {
        if d.severity() == SEV_ERROR {
            eprintln("{}:{}: {}", d.file(), d.start(), d.message());
            n += 1;
        }
    }
    return n;
}

fn has_message(s: &Session, file_end: str, needle: str) bool {
    for d in s.diagnostics().unwrap() {
        if d.file().ends_with(file_end) && d.message().find(needle) >= 0 {
            return true;
        }
    }
    return false;
}

fn check(s: &mut Session) {
    let r = s.check();
    assert(r.is_ok(), "the check runs");
}

@test
fn checks_a_project_and_reports_its_errors(fx: &mut Fx) {
    let mut s = Session::open_file(fx.main.as_str(), Config::host("std")).unwrap();
    assert(s.diagnostics().is_err(), "no diagnostics before a check");
    check(&mut s);
    assert(s.checked(), "checked");
    assert_eq(errors_of(&s), 0);
    let mut found = false;
    for m in s.modules().unwrap() {
        if m.file().ends_with("/util.spc") {
            assert_eq(m.path(), "util");
            assert(!m.prelude(), "a project module");
            found = true;
        }
    }
    assert(found, "the import is a module of the session");
    let v = s.set_text(fx.util.as_str(), UTIL_BAD);
    assert_eq(v, 0);
    assert(!s.checked(), "a change makes the analysis stale");
    check(&mut s);
    assert(has_message(&s, "/util.spc", "bool"), "the buffer's type error is reported");
    for d in s.diagnostics().unwrap() {
        if d.file().ends_with("/util.spc") && d.severity() == SEV_ERROR {
            assert_eq(d.code_name(), "mismatched_types_expected_found");
        }
    }
    assert(s.close(fx.util.as_str()), "the buffer closes");
    check(&mut s);
    assert_eq(errors_of(&s), 0);
}

@test
fn applies_edits_together_or_not_at_all(fx: &mut Fx) {
    let mut s = Session::open_file(fx.main.as_str(), Config::host("std")).unwrap();
    assert_eq(s.open(fx.util.as_str()).unwrap(), 0);
    let rev = s.revision();
    let at = UTIL.find("x + x") as u32;
    let mut good = Vector::<Edit>::new();
    good.push(Edit { start: at, end: at + 5, text: String::from_str("x * 2") });
    let mut bad = Vector::<Edit>::new();
    bad.push(Edit { start: 0, end: 4, text: String::from_str("") });
    bad.push(Edit { start: 2, end: 6, text: String::from_str("") });
    let mut cs = Vector::<Change>::new();
    cs.push(Change { path: fx.util.clone(), edits: good, expected_version: 0 });
    cs.push(Change { path: fx.main.clone(), edits: bad, expected_version: -1 });
    let r = s.apply(cs.as_slice());
    assert(r.is_err(), "overlapping edits reject");
    assert(r.unwrap_err().code == Code::InvalidArgument, "as an invalid argument");
    assert_eq(s.revision(), rev);
    assert_eq(s.version(fx.util.as_str()), 0);
    assert_eq(s.text(fx.util.as_str()).unwrap().unwrap().as_str(), UTIL);
    let mut stale = Vector::<Change>::new();
    stale.push(Change { path: fx.util.clone(), replace: true, text: String::from_str(UTIL), expected_version: 7 });
    assert(s.apply(stale.as_slice()).unwrap_err().code == Code::InvalidArgument, "a stale version rejects");
    let mut ok = Vector::<Change>::new();
    let mut e = Vector::<Edit>::new();
    e.push(Edit { start: at, end: at + 5, text: String::from_str("x * 2") });
    ok.push(Change { path: fx.util.clone(), edits: e, expected_version: 0 });
    assert_eq(s.apply(ok.as_slice()).unwrap(), rev + 1);
    assert_eq(s.version(fx.util.as_str()), 1);
    assert(s.text(fx.util.as_str()).unwrap().unwrap().as_str().find("x * 2") >= 0, "the edit applied");
    check(&mut s);
    assert_eq(errors_of(&s), 0);
}

@test
fn edits_apply_by_byte_offset() {
    let mut out = String::new();
    let mut es = Vector::<Edit>::new();
    es.push(Edit { start: 4, end: 4, text: String::from_str("!") });
    es.push(Edit { start: 0, end: 1, text: String::from_str("A") });
    es.push(Edit { start: 4, end: 5, text: String::from_str("X") });
    assert(apply_edits("abcdef", es.as_slice(), &mut out).is_ok(), "applies");
    assert_eq(out.as_str(), "Abcd!Xf");
    let mut split = Vector::<Edit>::new();
    split.push(Edit { start: 1, end: 1, text: String::from_str("x") });
    assert(apply_edits("é", split.as_slice(), &mut out).is_err(), "an offset inside a character rejects");
    assert_eq(out.as_str(), "Abcd!Xf");
}

@test
fn reads_every_file_through_its_provider() {
    let mut files = MemoryFiles::over_disk();
    files.set("/virtual/app/main.spc", MAIN);
    files.set("/virtual/app/util.spc", UTIL_BAD);
    let mut s = Session::open_file("/virtual/app/main.spc", Config::with_files("std", Box::new(files))).unwrap();
    check(&mut s);
    assert(has_message(&s, "/virtual/app/util.spc", "bool"), "the provider's import is analyzed");
    let _ = s.set_text("/virtual/app/util.spc", UTIL);
    check(&mut s);
    assert_eq(errors_of(&s), 0);
}

// A provider whose every read of `fail` fails.
struct Failing {
    pub inner: MemoryFiles,
    pub fail: String,
}

extend Failing as FileProvider {
    pub fn read(self: &mut Self, path: str, out: &mut String) Result<bool, IoError> {
        if path == self.fail.as_str() {
            return Result::<bool, IoError>::Err(
                IoError { kind: IoErrorKind::PermissionDenied, code: 13, op: IoOp::Open },
            );
        }
        return self.inner.read(path, out);
    }

    pub fn list(self: &mut Self, dir: str, out: &mut Vector<String>) Result<bool, IoError> {
        return self.inner.list(dir, out);
    }
}

@test
fn reports_a_provider_failure() {
    let mut inner = MemoryFiles::over_disk();
    inner.set("/virtual/app/main.spc", MAIN);
    inner.set("/virtual/app/util.spc", UTIL);
    let f = Failing { inner: inner, fail: String::from_str("/virtual/app/util.spc") };
    let mut s = Session::open_file("/virtual/app/main.spc", Config::with_files("std", Box::new(f))).unwrap();
    let r = s.check();
    let e = r.unwrap_err();
    assert(e.code == Code::Io, "an I/O failure");
    assert_eq(e.file.as_str(), "/virtual/app/util.spc");
    assert(e.io.unwrap().kind == IoErrorKind::PermissionDenied, "with its cause");
    assert(!s.checked(), "and no analysis");
}

// A root file that does not read fails the check; an import that does not resolve is a diagnostic. Neither
// prints.
@test
fn reports_files_that_do_not_load() {
    let mut files = MemoryFiles::over_disk();
    files.set("/virtual/app/other.spc", MAIN);
    files.set("/virtual/app/main.spc", MAIN);
    assert(files.remove("/virtual/app/main.spc") && !files.remove("/virtual/app/main.spc"), "a file removes once");
    let mut s = Session::open_file("/virtual/app/main.spc", Config::with_files("std", Box::new(files))).unwrap();
    let e = s.check().unwrap_err();
    assert(e.code == Code::InvalidArgument, "the root does not read");
    assert_eq(e.file.as_str(), "/virtual/app/main.spc");
    assert(!s.checked(), "and no analysis");
    let _ = s.set_text("/virtual/app/main.spc", "import gone;\n\nfn main() i32 {\n    return 0;\n}\n");
    check(&mut s);
    let mut found = false;
    let mut ds = s.diagnostics().unwrap();
    while let Some(d) = ds.next() {
        found = found || d.code_name() == "cannot_open_module";
    }
    assert(found, "the missing import is a diagnostic");
}

@test
fn stops_a_cancelled_or_late_check(fx: &mut Fx) {
    let mut s = Session::open_file(fx.main.as_str(), Config::host("std")).unwrap();
    let (src, tok) = ptask::CancelSource::new();
    src.cancel(1);
    let r = s.check_with(
        &RequestOptions { cancel: Option::<ptask::CancelToken>::Some(tok), deadline_ns: 0, result_limit: 0 },
    );
    assert(r.unwrap_err().code == Code::Cancelled, "a cancelled token stops the check");
    assert(!s.checked(), "unchecked");
    let late = s.check_with(
        &RequestOptions { cancel: Option::<ptask::CancelToken>::None, deadline_ns: 1, result_limit: 0 },
    );
    assert(late.unwrap_err().code == Code::Deadline, "a past deadline stops the check");
    check(&mut s);
    assert_eq(errors_of(&s), 0);
}

@test
fn drops_an_analysis_over_its_memory_limit(fx: &mut Fx) {
    let mut c = Config::host("std");
    c.memory_limit = 1024;
    let mut s = Session::open_file(fx.main.as_str(), c).unwrap();
    assert(s.check().unwrap_err().code == Code::Limit, "over the limit");
    assert(!s.checked(), "dropped");
}

const VENDOR_TOML: str = M"(bin = "lib"
root = "src/lib.spc"
std_internals = true
)";

// A vendored package whose modules import each other by their paths at home, and name std's internals
// (`heap_restore_top` is `pub(package)` in std).
const VENDOR_API: str = M"(import core::calc;

pub fn answer() i32 {
    let mut v = Vector::<i32>::new();
    v.push(3);
    heap_restore_top(v.as_mut_slice());
    return calc::base() + 1;
}
)";

const VENDOR_CALC: str = M"(pub fn base() i32 {
    return 41;
}

pub(package) fn hidden() i32 {
    return 0;
}
)";

const CLIENT: str = M"(import vendor::lib::src::api::entry;

fn main() i32 {
    return entry::answer() - 42;
}
)";

const CLIENT_HIDDEN: str = M"(import vendor::lib::src::api::entry;
import vendor::lib::src::core::calc;

fn main() i32 {
    return entry::answer() - 42 + calc::hidden();
}
)";

const CLIENT_INTERNALS: str = M"(import vendor::lib::src::api::entry;

fn main() i32 {
    let mut v = Vector::<i32>::new();
    v.push(3);
    heap_restore_top(v.as_mut_slice());
    return entry::answer() - 42;
}
)";

@test
fn resolves_a_vendored_package_against_its_own_roots() {
    let proj = cli::proj_new();
    proj.mkfile("vendor/lib/build.toml", VENDOR_TOML);
    proj.mkfile("vendor/lib/src/api/entry.spc", VENDOR_API);
    proj.mkfile("vendor/lib/src/core/calc.spc", VENDOR_CALC);
    proj.mkfile("main.spc", CLIENT);
    let main = format("{}/main.spc", proj.dir());
    let mut s = Session::open_file(main.as_str(), Config::host("std")).unwrap();
    check(&mut s);
    assert_eq(errors_of(&s), 0);
    let mut paths = Vector::<String>::new();
    for m in s.modules().unwrap() {
        if m.path().starts_with("vendor::") {
            paths.push(String::from_str(m.path()));
        }
    }
    paths.sort();
    assert_eq(paths.len(), 2);
    assert_eq(paths[0].as_str(), "vendor::lib::src::api::entry");
    assert_eq(paths[1].as_str(), "vendor::lib::src::core::calc");
    let _ = s.set_text(main.as_str(), CLIENT_HIDDEN);
    check(&mut s);
    assert(has_message(&s, "/main.spc", "hidden"), "the client cannot name the package's pub(package) item");
    let _ = s.set_text(main.as_str(), CLIENT_INTERNALS);
    check(&mut s);
    assert(has_message(&s, "/main.spc", "heap_restore_top"), "the vendored key does not reach the client");
    let r = proj.compile("main.spc");
    assert(r.ok(), "the client builds against the vendored package");
}

// A tool built against a vendored copy of the compiler: it opens a session over a project and reports its
// error count as its exit status.
const TOOL: str = M"(import vendor::superc::src::api::session as *;
import stdlib;

fn main() i32 {
    let app = stdlib::get_env("APP_MAIN").unwrap();
    let std_dir = stdlib::get_env("SC_STD_DIR").unwrap();
    let mut s = Session::open_file(app.as_str(), Config::host(std_dir.as_str())).unwrap();
    if s.check().is_err() {
        return 100;
    }
    let mut n: i32 = 0;
    for d in s.diagnostics().unwrap() {
        if d.severity() == SEV_ERROR {
            n += 1;
        }
    }
    return n;
}
)";

// A view kept across a change of its session: the borrow check rejects it, so no stale view runs.
const STALE_VIEW: str = M"(import vendor::superc::src::api::session as *;

fn main() i32 {
    let mut s = Session::open_file("a.spc", Config::host("std")).unwrap();
    let _ = s.check();
    let ds = s.diagnostics().unwrap();
    let _ = s.set_text("a.spc", "");
    let mut n: i32 = 0;
    for d in ds {
        n += d.start() as i32;
    }
    return n;
}
)";

// A backend that tries to change the program it is given: it gets the program shared, so this does not
// compile.
const FROZEN: str = M"(import vendor::superc::src::api::backend as be;
import vendor::superc::src::api::lir as lir;
import vendor::superc::src::api::errors as *;

struct Sneaky {}

extend Sneaky as be::Backend {
    pub fn api_version(self: &Self) u32 {
        return be::BACKEND_API;
    }

    pub fn supports(self: &Self, _os: str, _isa: str) bool {
        return true;
    }

    pub fn emit(self: &mut Self, prog: &lir::Program, _os: str, _isa: str, _out: &mut Vector<be::Artifact>) Result<Unit, ApiError> {
        let other = lir::Program::new(8);
        prog.absorb(&other)?;
        return Result::<Unit, ApiError>::Ok(Unit {});
    }
}

fn main() i32 {
    return 0;
}
)";

// A client of the vendored compiler names `src/api/` items only: a compiler item outside it is invisible
// through a qualified path, through a glob import of its module, and through the glob import of a facade
// module that imports it.
const BOUNDARY: [str; 3] = [
    M"(import vendor::superc::src::module::loader as l;

fn main() i32 {
    let _ = l::read_file("x");
    return 0;
}
)",
    M"(import vendor::superc::src::module::loader as *;

fn main() i32 {
    let _ = read_file("x");
    return 0;
}
)",
    M"(import vendor::superc::src::api::session as *;

fn main() i32 {
    let _ = read_file("x");
    return 0;
}
)",
];

@test(timeout = 900)
fn serves_the_facade_of_a_vendored_compiler() {
    let proj = cli::proj_new();
    cli::copy_tree("src", format("{}/vendor/superc/src", proj.dir()).as_str());
    assert(proj.copyfile("vendor/superc/build.toml", "build.toml"), "the manifest copies");
    proj.mkfile("app/main.spc", MAIN);
    proj.mkfile("app/util.spc", UTIL_BAD);
    proj.mkfile("tool.spc", TOOL);
    proj.mkfile("build.toml", "bin = \"bin\"\nroot = \"tool.spc\"\nout-dir = \"out\"\n");
    let r = cli::superc_env_in(proj.dir(), "SC_NONE", "", "build");
    if !r.ok() {
        r.show();
    }
    assert(r.ok(), "the tool builds against the vendored compiler");
    let std_dir = stdlib::get_env("SC_STD_DIR").unwrap();
    let mut cmd = format("\"{}/out/debug/bin\"", proj.dir());
    let mut op = format("{}/.runout", proj.dir());
    let run = cli::exec_env(
        cmd.cstr(),
        op.cstr(),
        format("APP_MAIN={}/app/main.spc SC_STD_DIR={}", proj.dir(), std_dir.as_str()).as_str(),
    );
    assert_eq(run.exit, 1);
    proj.mkfile("stale.spc", STALE_VIEW);
    let st = proj.compile("stale.spc");
    assert(!st.ok(), "a view kept across a change does not compile");
    assert(st.out_has("borrowed"), "the borrow check names the conflict");
    proj.mkfile("frozen.spc", FROZEN);
    let fr = proj.compile("frozen.spc");
    assert(!fr.ok() && fr.out_has("'&mut self' method"), "a backend cannot change its program");
    let cases: []str = BOUNDARY;
    let wants: [str; 3] = [
        "no visible item 'read_file'",
        "cannot find value 'read_file'",
        "cannot find value 'read_file'",
    ];
    for i in 0..cases.len() {
        proj.mkfile(format("boundary{}.spc", i).as_str(), cases[i]);
        let b = proj.compile(format("boundary{}.spc", i).as_str());
        assert(!b.ok() && b.out_has(unsafe wants[i]), "a compiler item outside src/api is invisible to a client");
    }
}

// A cancel stops a check of this repository wherever it lands (before the check, or in load, resolve, the
// type check or the borrow check), and leaves the session unchecked: the next check rebuilds it. The
// latency limit (50 ms) is measured by the `api_cancel` bench lane, not here: a test runner shares the
// machine.
@test(timeout = 300)
fn a_cancel_stops_the_check() {
    let mut stopped = Option::<Session>::None;
    for delay_ms in [0u64, 20, 150, 400, 900] {
        let mut s = Session::open_project(".", Config::host("std")).unwrap();
        let (src, tok) = ptask::CancelSource::new();
        if delay_ms == 0 {
            src.cancel(1);
        }
        let canceller = thread::spawn(
            move (|| {
                if delay_ms != 0 {
                    clock::sleep_ns(delay_ms * 1000000);
                    src.cancel(1);
                }
            }),
        );
        let r = s.check_with(
            &RequestOptions { cancel: Option::<ptask::CancelToken>::Some(tok), deadline_ns: 0, result_limit: 0 },
        );
        canceller.join();
        if r.is_ok() {
            assert(delay_ms != 0, "a cancel before the check stops it");
            continue;
        }
        assert(r.unwrap_err().code == Code::Cancelled, "the check stops");
        assert(!s.checked(), "a stopped check leaves the session unchecked");
        stopped = Option::<Session>::Some(s);
    }
    let mut s = stopped.unwrap();
    assert(s.check().is_ok() && s.checked(), "the next check rebuilds the session");
}

@test
fn reports_fixes_texts_and_retained_bytes(fx: &mut Fx) {
    let mut s = Session::open_file(fx.main.as_str(), Config::host("std")).unwrap();
    let _ = s.set_text(fx.util.as_str(), "pub fn twice(x: i32) i32 {\n    let unused = 1;\n    return x + x;\n}\n");
    check(&mut s);
    assert(s.retained_bytes() > 0, "an analysis retains its package");
    let mut fixed = false;
    for d in s.diagnostics().unwrap() {
        if let Some(f) = d.fix() {
            assert(f.start == f.end && f.text.as_str() == "_", "the unused binding's fix inserts '_'");
            fixed = true;
        }
    }
    assert(fixed, "a warning carries its fix");
    let m = s.module_of(fx.util.as_str()).unwrap();
    assert(m.text().find("let unused") >= 0, "a module's analyzed text is its buffer");
    let late = RequestOptions::within_ms(0);
    let _ = s.set_text(fx.util.as_str(), UTIL);
    assert(s.check_with(&late).unwrap_err().code == Code::Deadline, "a request within 0 ms passes its deadline");
}
