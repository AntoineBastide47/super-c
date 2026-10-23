// The test runner of a `super-c test` build. The generated `__test_main.c` holds the test table (each
// test's display name, wrapper, `should_panic` flag and timeout) and a `main` that hands it to
// `sc_test_main`. The runner selects the tests (`--filter`, `--shard` balanced by recorded durations), runs
// each in its own process (POSIX forks, Windows runs this binary again with `--run-one`), or all in this
// process with `--no-fork`, enforces the timeouts and reports. Each test's output goes to its own capture
// file, replayed only when the test fails, in a `failures:` section after the run; `--quiet` also drops
// the per-test `ok` lines. The process tree shares one jobserver budget with the compiler that started it
// (`SC_JOBSERVER`, src/driver_shim.spc). The loader adds this module to test builds only
// (`Package::rt_test`).
import stdio;
import stdlib;
import errno;
import signal;
import unistd;
import sc_runtime;
@platform(macos | ios | linux | android)
import fcntl;
@platform(linux | android)
import filesystem;

// One test of the table: its wrapper runs it with the global env (null without one).
type TestFn = fn(*mut void);

// The test table of the generated `main`: entry `i` of each array describes test `i`.
struct Table {
    pub n: usize,
    pub names: *const *const char,
    pub fns: *const TestFn,
    pub panics: *const u8,
    pub timeouts: *const u32,
    pub genv_init: fn() *mut void,
    pub genv_free: fn(*mut void),
}

extend Table {
    fn name(self: &Table, i: usize) str<'static> {
        return unsafe str::from_cstr(self.names[i]);
    }

    fn run(self: &Table, i: usize, genv: *mut void) {
        let f = unsafe self.fns[i];
        f(genv);
    }

    fn should_panic(self: &Table, i: usize) bool {
        return unsafe self.panics[i] != 0;
    }

    @platform(!wasm)
    // The seconds test `i` may run: its own `@test(timeout = N)`, else the run's `--timeout` (0: none).
    fn limit(self: &Table, i: usize, timeout: i32) u32 {
        let own = unsafe self.timeouts[i];
        if own != 0 {
            return own;
        }
        return if timeout > 0 {
            timeout as u32;
        } else {
            0;
        };
    }
}

// The runner's options.
struct Opts {
    pub jobs: i32,
    pub no_fork: bool,
    pub quiet: bool,
    pub shard: i32,
    pub shards: i32,
    pub timeout: i32,
    pub filtered: bool,
    pub filter: str<'static>,
    pub weights: str<'static>,
    pub record: str<'static>,
    // Windows: the child mode (`--run-one=I`, -1: the parent) and its capture file.
    pub run_one: i32,
    pub capture: str<'static>,
}

// A failed test: its output and how its process ended.
struct Failure {
    pub test: usize,
    pub out: String,
    pub why: String,
}

// The exit code of a runner that cannot go on.
const BROKEN: i32 = 101;

extern "C" {
    // The runtime's entry points (std/rt/base.spc), by C symbol.
    fn sc_lk_fork_child_reset();
    fn sc_lk_report_now();
}

@platform(macos | ios | linux | android)
extern "C" {
    fn __sc_diag_install();
}

@platform(!windows)
extern "C" {
    // The environment: no header the build's POSIX level includes declares it.
    static mut environ: *mut *mut char;
}

@platform(windows)
extern "C" "stdlib.h" {
    // The C runtime's environment block, a macro over its accessor.
    @import("_environ")
    static mut environ: *mut *mut char;
}

extern "C" "stdio.h" {
    fn setvbuf(f: *mut stdio::FILE, buf: *mut char, mode: i32, size: usize) i32;
    const _IOFBF: i32;
    const _IOLBF: i32;
    const _IONBF: i32;
    const BUFSIZ: i32;
}

extern "C" "string.h" {
    fn strerror(code: i32) *mut char;
}

// A failing test aborts: its report adds the thread's last error code, which a failed open, spawn or write
// the test made often explains (errno is reset when the test starts; a code may still predate the
// failure). Then the default action runs: abort ends the process when the handler returns (POSIX by
// SIGABRT, Windows with exit code 3).
fn on_abort(_sig: i32) {
    let e = errno::errno();
    if e != 0 {
        eprintln("  last errno: {} ({})", e, unsafe str::from_cstr(strerror(e)));
    }
    unsafe stdio::fflush(stdio::stderr());
}

/// Run the tests of the table the generated `main` passes (`names`, `fns`, `panics` and `timeouts` hold
/// `n` entries each) with the command line `argv`; the exit code: the failures, at most 100, 2 for a bad
/// argument, 101 when the runner cannot go on.
@export("sc_test_main")
pub fn test_main(
    argc: i32,
    argv: *mut *mut char,
    n: u32,
    names: *const void,
    fns: *const void,
    panics: *const void,
    timeouts: *const void,
    genv_init: fn() *mut void,
    genv_free: fn(*mut void),
) i32 {
    let t = Table {
        n: n as usize,
        names: names as *const *const char,
        fns: fns as *const TestFn,
        panics: panics as *const u8,
        timeouts: timeouts as *const u32,
        genv_init: genv_init,
        genv_free: genv_free,
    };
    // Forked children must not inherit (and flush again) buffered lines.
    unsafe setvbuf(stdio::stdout(), null, _IOLBF, 0);
    prepare_stderr();
    unsafe signal::signal(signal::SIGABRT, on_abort);
    let mut o = Opts {
        jobs: 0,
        no_fork: false,
        quiet: false,
        shard: 1,
        shards: 1,
        timeout: 0,
        filtered: false,
        filter: "",
        weights: "",
        record: "",
        run_one: -1,
        capture: "",
    };
    for i in 1..argc as usize {
        let a = unsafe str::from_cstr(argv[i]);
        if !parse_arg(a, &mut o) {
            return 2;
        }
    }
    if o.jobs < 1 {
        o.jobs = sc_runtime::sc_rt_ncpu() as i32;
    }
    o.jobs = cap_jobs(o.jobs);
    if o.run_one >= 0 {
        return run_one(&t, &o);
    }
    if !js_init(o.jobs) {
        eprintln("test runner: cannot make a jobserver");
        return BROKEN;
    }
    let mut d = Durations { dur: Vector::<f64>::new(), known: Vector::<f64>::new(), by_name: Vector::<u32>::new() };
    for _ in 0..t.n {
        d.dur.push(-1.0);
        d.known.push(-1.0);
    }
    d.sort_names(&t);
    let sel = choose(&t, &o, &mut d);
    let s = if sel.len() == 1 {
        "";
    } else {
        "s";
    };
    if o.shards > 1 {
        println("running {} test{} (shard {}/{})", sel.len(), s, o.shard, o.shards);
    } else {
        println("running {} test{}", sel.len(), s);
    }
    let mut genv: *mut void = null;
    if sel.len() > 0 {
        genv = t.genv_init();
    }
    let mut r = Run {
        passed: 0,
        skipped: 0,
        fails: Vector::<Failure>::new(),
        slow_test: [0usize; SLOWEST],
        slow_secs: [0.0f64; SLOWEST],
        slow_n: 0,
    };
    let rc = if o.no_fork {
        run_in_process(&t, &o, &sel, genv, &mut r);
    } else {
        run_pool(&t, &o, &sel, genv, &mut r, &mut d);
    };
    if rc != 0 {
        return rc;
    }
    if genv != null {
        t.genv_free(genv);
    }
    if r.fails.len() != 0 {
        report_failures(&t, &r.fails);
    }
    r.report_slowest(&t);
    if o.record.len() != 0 {
        d.write(&t, o.record, o.filtered);
    }
    if r.skipped != 0 {
        println("\n{} passed, {} failed, {} skipped", r.passed, r.fails.len(), r.skipped);
    } else {
        println("\n{} passed, {} failed", r.passed, r.fails.len());
    }
    return if r.fails.len() > 100 {
        100;
    } else {
        r.fails.len() as i32;
    };
}

// Apply one command-line argument to `o`; false (after a message) for a malformed or unknown one: a
// misspelled option must not quietly run the whole suite.
fn parse_arg(a: str<'static>, o: &mut Opts) bool {
    if a.starts_with("--jobs=") {
        o.jobs = leading_int(a.slice(7, a.len()));
    } else if a == "--no-fork" {
        o.no_fork = true;
    } else if a == "--quiet" {
        o.quiet = true;
    } else if a.starts_with("--timeout=") {
        o.timeout = leading_int(a.slice(10, a.len()));
    } else if a.starts_with("--weights=") {
        o.weights = a.slice(10, a.len());
    } else if a.starts_with("--record=") {
        o.record = a.slice(9, a.len());
    } else if a.starts_with("--filter=") {
        o.filtered = true;
        o.filter = a.slice(9, a.len());
    } else if a.starts_with("--shard=") {
        let v = a.slice(8, a.len());
        let k = v.find_byte(b'/');
        let ok = k > 0 && (switch v.slice(0, k as usize).parse_i32() {
            Some(x) => {
                o.shard = x;
                true;
            },
            None => false,
        }) && (switch v.slice(k as usize + 1, v.len()).parse_i32() {
            Some(x) => {
                o.shards = x;
                true;
            },
            None => false,
        });
        if !ok || o.shard < 1 || o.shard > o.shards {
            eprintln("invalid test shard: expected K/N with 1 <= K <= N");
            return false;
        }
    } else if win_arg(a, o) {
        return true;
    } else {
        eprintln(
            "unknown test runner argument '{}': expected --filter=S, --shard=K/N, --jobs=N, --timeout=S, --weights=F, --record=F, --quiet or --no-fork",
            a,
        );
        return false;
    }
    return true;
}

// The decimal integer `s` starts with, 0 without one (as C's atoi).
fn leading_int(s: str) i32 {
    let mut e: usize = 0;
    if e < s.len() && (s.byte_at(0) == b'-' || s.byte_at(0) == b'+') {
        e = 1;
    }
    while e < s.len() && s.byte_at(e) >= b'0' && s.byte_at(e) <= b'9' {
        e += 1;
    }
    return s.slice(0, e).parse_i32().unwrap_or(0);
}

// ---- selection and durations ----------------------------------------------------------------------------

// Test durations, one `<seconds>\t<name>` line per test (`#` starts a comment): read by `--weights` to
// balance the shards, merged by `--record` with what this run measured (`dur`, -1: not run).
struct Durations {
    pub dur: Vector<f64>,
    pub known: Vector<f64>,
    // The test indexes sorted by name, for `find`.
    pub by_name: Vector<u32>,
}

// A test index with its name, sorted by name.
struct Named {
    pub name: str<'static>,
    pub i: u32,
}

fn named_cmp(a: &Named, b: &Named) i32 {
    return a.name.cmp(&b.name);
}

extend Durations {
    fn sort_names(self: &mut Durations, t: &Table) {
        let mut v = Vector::<Named>::new();
        for i in 0..t.n {
            v.push(Named { name: t.name(i), i: i as u32 });
        }
        v.sort_by(named_cmp);
        for k in 0..v.len() {
            self.by_name.push(v[k].i);
        }
    }

    // The index of the test named `name`, or -1 when this binary does not have it.
    fn find(self: &Durations, t: &Table, name: str) isize {
        let mut lo: isize = 0;
        let mut hi = self.by_name.len() as isize - 1;
        while lo <= hi {
            let mid = (lo + hi) / 2;
            let i = self.by_name[mid as usize] as usize;
            let c = t.name(i).cmp(&name);
            if c == 0 {
                return i as isize;
            }
            if c < 0 {
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }
        return -1;
    }

    // Fill `known` from the file at `path` (-1 for a test it does not name); false when it cannot be read.
    fn read(self: &mut Durations, t: &Table, path: str) bool {
        for i in 0..t.n {
            self.known.set(i, -1.0);
        }
        if path.len() == 0 {
            return false;
        }
        let text = switch read_file(path) {
            Some(s) => s,
            None => {
                return false;
            },
        };
        let mut it = text.as_str().lines();
        while let Some(line) = it.next() {
            let (secs, name) = switch duration_line(line) {
                Some(p) => p,
                None => {
                    continue;
                },
            };
            let i = self.find(t, name);
            if i >= 0 {
                self.known.set(i as usize, secs);
            }
        }
        return true;
    }

    // Merge this run's durations into the file at `path`: a test that ran gets its new time, one that did
    // not keeps its old one, and a name the suite no longer has is dropped. A filtered run's binary has
    // only the files with a match, so there a name the binary does not have keeps its line. Written whole
    // through a temp file, sorted by name so the file diffs line by line.
    fn write(self: &mut Durations, t: &Table, path: str, filtered: bool) {
        let _ = self.read(t, path);
        let mut lines = Vector::<Line>::new();
        for i in 0..t.n {
            let s = if self.dur[i] >= 0.0 {
                self.dur[i];
            } else {
                self.known[i];
            };
            if s >= 0.0 {
                lines.push(Line { name: String::from_str(t.name(i)), secs: s });
            }
        }
        if filtered {
            switch read_file(path) {
                Some(text) => {
                    let mut it = text.as_str().lines();
                    while let Some(line) = it.next() {
                        switch duration_line(line) {
                            Some(p) => {
                                if self.find(t, p.1) < 0 {
                                    lines.push(Line { name: String::from_str(p.1), secs: p.0 });
                                }
                            },
                            None => {},
                        };
                    }
                },
                None => {},
            };
        }
        lines.sort_by(line_cmp);
        let mut body = String::from_str(
            "# super-c test --test-record-durations: seconds per test, read to balance --test-shard\n",
        );
        for k in 0..lines.len() {
            body.push_f64_prec(lines[k].secs, 2);
            body.push_byte(b'\t');
            body.push_string(&lines[k].name);
            body.push_byte(b'\n');
        }
        let mut tmp = format("{}.tmp", path);
        if !write_file(tmp.as_str(), body.as_str()) {
            unsafe stdio::perror(tmp.cstr());
            let _ = unsafe stdio::remove(tmp.cstr());
            return;
        }
        let mut p = String::from_str(path);
        // A rename over an existing file fails on Windows.
        let _ = unsafe stdio::remove(p.cstr());
        if unsafe stdio::rename(tmp.cstr(), p.cstr()) != 0 {
            unsafe stdio::perror(p.cstr());
        }
    }
}

// One line of a durations file.
struct Line {
    pub name: String,
    pub secs: f64,
}

fn line_cmp(a: &Line, b: &Line) i32 {
    let bn = b.name.as_str();
    return a.name.as_str().cmp(&bn);
}

// The seconds and the name of one `<seconds>\t<name>` line; None for a comment or a line without a tab.
fn duration_line<'a>(line: str<'a>) Option<(f64, str<'a>)> {
    if line.starts_with("#") {
        return Option::<(f64, str<'a>)>::None;
    }
    let tab = line.find_byte(b'\t');
    if tab < 0 {
        return Option::<(f64, str<'a>)>::None;
    }
    let mut name = line.slice(tab as usize + 1, line.len());
    let mut e: usize = 0;
    while e < name.len() && name.byte_at(e) != b'\r' && name.byte_at(e) != b'\n' {
        e += 1;
    }
    name = name.slice(0, e);
    return Option::<(f64, str<'a>)>::Some((leading_f64(line.slice(0, tab as usize)), name));
}

// The decimal number `s` starts with, 0 without one (as C's atof on the files this runner writes).
fn leading_f64(s: str) f64 {
    let mut e: usize = 0;
    while e < s.len() && (s.byte_at(e) >= b'0' && s.byte_at(e) <= b'9' || s.byte_at(e) == b'.' || e == 0 && s.byte_at(e) == b'-') {
        e += 1;
    }
    return s.slice(0, e).parse_f64().unwrap_or(0.0);
}

// The tests of shard `o.shard` of `o.shards` among those the filter matches, in table order. Without
// durations the matches are dealt round-robin; with them (`o.weights`) each match, the longest first, goes
// to the shard with the least time so far (ties: the lowest shard), and a test the file does not name
// counts as the median known duration. Every shard computes the same assignment.
fn choose(t: &Table, o: &Opts, d: &mut Durations) Vector<usize> {
    let mut m = Vector::<usize>::new();
    for i in 0..t.n {
        if t.name(i).find(o.filter) >= 0 {
            m.push(i);
        }
    }
    let mut sel = Vector::<usize>::new();
    if o.shards <= 1 || !d.read(t, o.weights) {
        for k in 0..m.len() {
            if k % o.shards as usize == (o.shard - 1) as usize {
                sel.push(m[k]);
            }
        }
        return sel;
    }
    let mut known = Vector::<f64>::new();
    for k in 0..m.len() {
        if d.known[m[k]] >= 0.0 {
            known.push(d.known[m[k]]);
        }
    }
    let mut median: f64 = 1.0;
    if known.len() > 0 {
        known.sort_by(f64_cmp);
        median = known[known.len() / 2];
    }
    let mut w = Vector::<Weighted>::new();
    for k in 0..m.len() {
        if d.known[m[k]] < 0.0 {
            d.known.set(m[k], median);
        }
        w.push(Weighted { i: m[k], secs: d.known[m[k]] });
    }
    w.sort_by(weighted_cmp);
    let mut load = Vector::<f64>::new();
    for _ in 0..o.shards {
        load.push(0.0);
    }
    let mut mine = Vector::<bool>::new();
    for _ in 0..t.n {
        mine.push(false);
    }
    for k in 0..w.len() {
        let mut best: usize = 0;
        for s in 1..o.shards as usize {
            if load[s] < load[best] {
                best = s;
            }
        }
        load.set(best, load[best] + w[k].secs);
        mine.set(w[k].i, best == (o.shard - 1) as usize);
    }
    for k in 0..m.len() {
        if mine[m[k]] {
            sel.push(m[k]);
        }
    }
    return sel;
}

// A test index with its weight.
struct Weighted {
    pub i: usize,
    pub secs: f64,
}

// The longest first; equal ones in table order.
fn weighted_cmp(a: &Weighted, b: &Weighted) i32 {
    if a.secs != b.secs {
        return if a.secs < b.secs {
            1;
        } else {
            -1;
        };
    }
    return if a.i < b.i {
        -1;
    } else {
        1;
    };
}

fn f64_cmp(a: &f64, b: &f64) i32 {
    return if *a < *b {
        -1;
    } else if *a > *b {
        1;
    } else {
        0;
    };
}

// ---- the run's results ------------------------------------------------------------------------------------

// The slowest tests a forked run reports, longest first: what a timeout (`--timeout`, `@test(timeout = N)`)
// must leave room for on the machine that ran them.
const SLOWEST: usize = 5;

struct Run {
    pub passed: u32,
    pub skipped: u32,
    pub fails: Vector<Failure>,
    pub slow_test: [usize; SLOWEST],
    pub slow_secs: [f64; SLOWEST],
    pub slow_n: usize,
}

extend Run {
    @platform(!wasm)
    // Record test `ti`'s run time `secs`.
    fn note(self: &mut Run, d: &mut Durations, ti: usize, secs: f64) {
        d.dur.set(ti, secs);
        let mut k: usize = 0;
        if self.slow_n < SLOWEST {
            k = self.slow_n;
            self.slow_n += 1;
        } else if secs <= self.slow_secs[SLOWEST - 1] {
            return;
        } else {
            k = SLOWEST - 1;
        }
        while k > 0 && unsafe self.slow_secs[k - 1] < secs {
            unsafe {
                self.slow_test[k] = self.slow_test[k - 1];
                self.slow_secs[k] = self.slow_secs[k - 1];
            }
            k -= 1;
        }
        unsafe {
            self.slow_test[k] = ti;
            self.slow_secs[k] = secs;
        }
    }

    fn report_slowest(self: &Run, t: &Table) {
        if self.slow_n == 0 {
            return;
        }
        println("\nslowest tests:");
        for k in 0..self.slow_n {
            let mut s = String::new();
            s.push_f64_prec(unsafe self.slow_secs[k], 2);
            let mut line = String::from_str("  ");
            for _ in s.len()..7 {
                line.push_byte(b' ');
            }
            line.push_string(&s);
            line.push_str(" s  ");
            line.push_str(t.name(unsafe self.slow_test[k]));
            line.println();
        }
    }

    @platform(!wasm)
    // A test that ended as declared.
    fn pass(self: &mut Run, t: &Table, o: &Opts, ti: usize) {
        if !o.quiet {
            let how = if t.should_panic(ti) {
                " (panicked as expected)";
            } else {
                "";
            };
            println("test {} ... ok{}", t.name(ti), how);
        }
        self.passed += 1;
    }

    @platform(!wasm)
    // A failed test, its captured output `out` and `why` it failed.
    fn fail(self: &mut Run, ti: usize, out: String, why: String) {
        self.fails.push(Failure { test: ti, out: out, why: why });
    }
}

// The failures, together, after the run: each test's captured output under its own header, how the process
// ended, then the bare list of names.
fn report_failures(t: &Table, fails: &Vector<Failure>) {
    println("\nfailures:");
    for k in 0..fails.len() {
        println("\n---- {} ----", t.name(fails[k].test));
        let out = &fails[k].out;
        if out.len() > 0 {
            out.print();
            if out.as_str().byte_at(out.len() - 1) != b'\n' {
                println("");
            }
        }
        fails[k].why.println();
    }
    println("\nfailures:");
    for k in 0..fails.len() {
        println("    {}", t.name(fails[k].test));
    }
    unsafe stdio::fflush(stdio::stdout());
}

@platform(!wasm)
// `why` of a timed-out test.
fn timed_out_why(limit: u32) String {
    return format("timed out after {} s", limit);
}

// ---- the in-process run -----------------------------------------------------------------------------------

// Run every selected test in this process: nothing is captured, and a failure ends the run where it
// happens, so no `should_panic` test can run. There is no per-test process, so the run restores the
// environment and the working directory itself: tests set compiler switches (SC_INLINE, SC_BCE, ...) and
// rely on the fork for isolation.
fn run_in_process(t: &Table, o: &Opts, sel: &Vector<usize>, genv: *mut void, r: &mut Run) i32 {
    for k in 0..sel.len() {
        let i = sel[k];
        if t.should_panic(i) {
            if !o.quiet {
                println("test {} ... skipped (should_panic needs fork)", t.name(i));
            }
            r.skipped += 1;
            continue;
        }
        let env = env_snapshot();
        let mut cwd = [0u8; 4096];
        if unsafe unistd::getcwd(((&mut cwd[0]) as *mut u8) as *mut char, 4096) == null {
            unsafe stdio::perror("getcwd".ptr() as *const char);
            return BROKEN;
        }
        errno::set_errno(0);
        t.run(i, genv);
        env_restore(&env);
        if unsafe chdir_to(((&cwd[0]) as *const u8) as *const char) != 0 {
            unsafe stdio::perror("chdir".ptr() as *const char);
            return BROKEN;
        }
        if !o.quiet {
            println("test {} ... ok", t.name(i));
        }
        r.passed += 1;
    }
    return 0;
}

// The environment's entries, copied.
fn env_snapshot() Vector<String> {
    let mut v = Vector::<String>::new();
    let e = unsafe environ;
    let mut i: usize = 0;
    while unsafe e[i] != null {
        v.push(unsafe String::from_cstr(e[i]));
        i += 1;
    }
    return v;
}

// Make the environment equal `snap` again: unset each variable it lacks, then set each one whose value
// changed.
fn env_restore(snap: &Vector<String>) {
    // Unsetting a variable compacts the environment, so the index advances only past kept entries.
    let mut i: usize = 0;
    loop {
        let e = unsafe environ;
        let p = unsafe e[i];
        if p == null {
            break;
        }
        let entry = unsafe str::from_cstr(p);
        let eq = entry.find_byte(b'=');
        let name = if eq < 0 {
            entry;
        } else {
            entry.slice(0, eq as usize);
        };
        let mut keep = false;
        for k in 0..snap.len() {
            let s = snap[k].as_str();
            if s.len() > name.len() && s.starts_with(name) && s.byte_at(name.len()) == b'=' {
                keep = true;
                break;
            }
        }
        if keep {
            i += 1;
            continue;
        }
        let mut n = String::from_str(name);
        env_unset(&mut n);
    }
    for k in 0..snap.len() {
        let s = snap[k].as_str();
        let eq = s.find_byte(b'=');
        if eq < 0 {
            continue;
        }
        let mut n = String::from_str(s.slice(0, eq as usize));
        let v = s.slice(eq as usize + 1, s.len());
        let cur = stdlib::get_env(n.as_str());
        if cur.is_none() || cur.unwrap().as_str() != v {
            let mut vv = String::from_str(v);
            env_set(&mut n, &mut vv);
        }
    }
}

// ---- files --------------------------------------------------------------------------------------------------

// The whole file at `path`, None when it cannot be read.
fn read_file(path: str) Option<String> {
    let mut p = String::from_str(path);
    let mut mode = String::from_str("rb");
    return switch stdio::File::open(&mut p, &mut mode) {
        Some(mut f) => {
            let s = f.read_all();
            f.close();
            Option::<String>::Some(s);
        },
        None => Option::<String>::None,
    };
}

// Write `text` to the file at `path`, whole; false when it cannot be written.
fn write_file(path: str, text: str) bool {
    let f = stdio::fopen(path, "wb");
    if f == null {
        return false;
    }
    let n = unsafe stdio::fwrite(text.ptr(), 1, text.len(), f);
    return unsafe stdio::fclose(f) == 0 && n == text.len();
}

@platform(!wasm)
// The output a test wrote to the capture file at `path` (empty when it wrote nothing).
fn slurp(path: str) String {
    return read_file(path).unwrap_or(String::new());
}

// ---- the process-tree jobserver -----------------------------------------------------------------------------

// The most slots a jobserver may have.
const JS_MAX: i32 = 1024;
// The number of slots of the active jobserver (-1: none yet) and the slot bytes this runner holds.
static mut JS_SLOTS: i32 = -1;
static mut JS_OWN: [u8; 1024] = [0u8; 1024];

// A runner started without an inherited jobserver makes its own of `capacity` slots, one implicit, as the
// compiler does (src/driver_shim.spc): the tests and every process they start share one budget. True when
// a jobserver is active.
fn js_init(capacity: i32) bool {
    if js_active() {
        return true;
    }
    let n = if capacity < 1 {
        0;
    } else if capacity - 1 > JS_MAX {
        JS_MAX;
    } else {
        capacity - 1;
    };
    return js_make(n);
}

@platform(!wasm)
// Take a free slot: true, or false when every slot is held. A lock error aborts: the tree's budget is gone.
fn js_try_acquire() bool {
    if !js_active() {
        return false;
    }
    for i in 0..(unsafe JS_SLOTS) as usize {
        if unsafe JS_OWN[i] != 0 {
            continue;
        }
        let r = js_lock(i as i32, true);
        if r < 0 {
            stdlib::abort();
        }
        if r == 1 {
            unsafe {
                JS_OWN[i] = 1;
            }
            return true;
        }
    }
    return false;
}

@platform(!wasm)
// Give back one held slot. A token the runner cannot hand back would shrink the process tree's budget for
// good: stop, and say why.
fn js_give_back() {
    if js_active() {
        for i in 0..(unsafe JS_SLOTS) as usize {
            if unsafe JS_OWN[i] != 0 {
                if js_lock(i as i32, false) == 1 {
                    unsafe {
                        JS_OWN[i] = 0;
                    }
                    return;
                }
                break;
            }
        }
    }
    eprintln("test runner: cannot return a jobserver token");
    unsafe stdlib::exit(BROKEN);
}

@platform(!wasm)
// The slot count and the rest of an `SC_JOBSERVER` value `<n>,<rest>`, None when malformed.
fn js_parse(v: str<'static>) Option<(i32, str<'static>)> {
    let c = v.find_byte(b',');
    if c <= 0 {
        return Option::<(i32, str<'static>)>::None;
    }
    let n = switch v.slice(0, c as usize).parse_i32() {
        Some(x) => x,
        None => {
            return Option::<(i32, str<'static>)>::None;
        },
    };
    if n < 0 || n > JS_MAX {
        return Option::<(i32, str<'static>)>::None;
    }
    return Option::<(i32, str<'static>)>::Some((n, v.slice(c as usize + 1, v.len())));
}

@platform(!wasm)
// The jobserver's tokens for one pool slot: `implicit` is the one slot this process owns without a token.
struct Tokens {
    pub shared: bool,
    pub implicit: bool,
}

@platform(!wasm)
extend Tokens {
    fn new() Tokens {
        return Tokens { shared: js_active(), implicit: true };
    }

    // Take the budget for one more test: 1 with a token, 0 with the implicit slot, -1 when none is free.
    fn take(self: &mut Tokens) i32 {
        if !self.shared {
            return 0;
        }
        if self.implicit {
            self.implicit = false;
            return 0;
        }
        return if js_try_acquire() {
            1;
        } else {
            -1;
        };
    }

    // Return what `take` gave (`token`).
    fn give(self: &mut Tokens, token: i32) {
        if !self.shared {
            return;
        }
        if token == 1 {
            js_give_back();
        } else {
            self.implicit = true;
        }
    }
}

// ---- POSIX ----------------------------------------------------------------------------------------------------

@platform(macos | ios | linux | android)
fn prepare_stderr() {}

@platform(macos | ios | linux | android)
fn cap_jobs(jobs: i32) i32 {
    return jobs;
}

@platform(macos | ios | linux | android)
fn win_arg(_a: str<'static>, _o: &mut Opts) bool {
    return false;
}

@platform(macos | ios | linux | android)
fn run_one(_t: &Table, _o: &Opts) i32 {
    return 2;
}

@platform(macos | ios | linux | android)
unsafe fn chdir_to(dir: *const char) i32 {
    return unsafe unistd::chdir(dir);
}

@platform(macos | ios | linux | android)
fn env_set(name: &mut String, value: &mut String) {
    let _ = unsafe setenv(name.cstr(), value.cstr(), 1);
}

@platform(macos | ios | linux | android)
fn env_unset(name: &mut String) {
    let _ = unsafe unsetenv(name.cstr());
}

@platform(macos | ios | linux | android)
extern "C" "stdlib.h" {
    fn setenv(name: *const char, value: *const char, overwrite: i32) i32;
    fn unsetenv(name: *const char) i32;
    fn mkstemp(template: *mut char) i32;
}

@platform(macos | ios | linux | android)
extern "C" "unistd.h" {
    fn unlink(path: *const char) i32;
    fn alarm(seconds: u32) u32;
    @import("_exit")
    fn exit_now(code: i32);
}

@platform(macos | ios | linux | android)
extern "C" "sys/wait.h" {
    fn wait(status: *mut i32) i32;
}

@platform(macos | ios | linux | android)
extern "C" "errno.h" {
    const EINTR: i32;
    const EACCES: i32;
    const EAGAIN: i32;
}

@platform(macos | ios | linux | android)
extern "C" "fcntl.h" {
    @platform(macos | ios)
    struct flock {
        pub l_start: i64,
        pub l_len: i64,
        pub l_pid: i32,
        pub l_type: i16,
        pub l_whence: i16,
    }
    @platform(linux | android)
    struct flock {
        pub l_type: i16,
        pub l_whence: i16,
        pub l_start: i64,
        pub l_len: i64,
        pub l_pid: i32,
    }
    const F_SETLK: i32;
    const F_WRLCK: i32;
    const F_UNLCK: i32;
    const SEEK_SET: i32;
}

@platform(macos | ios)
type sigset_t = u32;

@platform(macos | ios | linux | android)
extern "C" "signal.h" {
    @platform(linux | android)
    @import("sigset_t")
    struct sigset_t {
        @import("__val")
        pub val: [u64; 16],
    }
    @platform(macos | ios)
    struct sigaction {
        @import("sa_handler")
        pub handler: fn(i32),
        pub sa_mask: sigset_t,
        pub sa_flags: i32,
    }
    @platform(linux | android)
    struct sigaction {
        @import("sa_handler")
        pub handler: fn(i32),
        pub sa_mask: sigset_t,
        pub sa_flags: i32,
        pub sa_restorer: fn(),
    }
    @import("sigaction")
    fn c_sigaction(sig: i32, act: *const sigaction, old: *mut sigaction) i32;
    fn sigemptyset(set: *mut sigset_t) i32;
    fn kill(pid: i32, sig: i32) i32;
    const SIGALRM: i32;
    const SIGKILL: i32;
    @platform(macos | ios)
    const SIGURG: i32 = 16;
    @platform(linux | android)
    const SIGURG: i32 = 23;
}

@platform(macos | ios | linux | android)
extern "C" "string.h" {
    fn strsignal(sig: i32) *mut char;
}

@platform(macos | ios | linux | android)
extern "C" "time.h" {
    struct timespec {
        pub tv_sec: i64,
        pub tv_nsec: isize,
    }
    fn nanosleep(req: *const timespec, rem: *mut timespec) i32;
}

@platform(macos | ios)
extern "C" {
    // <libproc.h>: the children of `ppid` into `buf`, a count of pids.
    fn proc_listchildpids(ppid: i32, buf: *mut void, size: i32) i32;
}

@platform(linux | android)
extern "C" "dirent.h" {
    struct dirent {
        pub d_ino: u64,
        pub d_off: i64,
        pub d_reclen: u16,
        pub d_type: u8,
        pub d_name: [char; 256],
    }
}

// The slot file whose descriptor every process of the tree inherits.
@platform(macos | ios | linux | android)
static mut JS_FD: i32 = -1;

// The process-tree jobserver the compiler made (src/driver_shim.spc): each slot is one byte of the unlinked
// slot file whose descriptor every process inherits, held by an fcntl record lock, which the system drops
// when the holder ends and a forked child does not inherit.
@platform(macos | ios | linux | android)
fn js_active() bool {
    if unsafe JS_SLOTS >= 0 {
        return true;
    }
    let v = stdlib::getenv("SC_JOBSERVER");
    if v == null {
        return false;
    }
    let (n, rest) = switch js_parse(unsafe str::from_cstr(v)) {
        Some(p) => p,
        None => {
            return false;
        },
    };
    let fd = switch rest.parse_i32() {
        Some(x) => x,
        None => {
            return false;
        },
    };
    if fd < 0 || unsafe fcntl::fcntl(fd, fcntl::F_GETFD) < 0 {
        return false;
    }
    unsafe {
        JS_FD = fd;
        JS_SLOTS = n;
    }
    return true;
}

// Lock (`lock`) or unlock slot byte `i`: 1 done, 0 another process holds it, -1 an error.
@platform(macos | ios | linux | android)
fn js_lock(i: i32, lock: bool) i32 {
    let mut fl = unsafe zeroed::<flock>();
    fl.l_type = if lock {
        F_WRLCK as i16;
    } else {
        F_UNLCK as i16;
    };
    fl.l_whence = SEEK_SET as i16;
    fl.l_start = i;
    fl.l_len = 1;
    loop {
        if unsafe fcntl::fcntl(unsafe JS_FD, F_SETLK, &mut fl) == 0 {
            return 1;
        }
        let e = errno::errno();
        if e == EINTR {
            continue;
        }
        return if lock && (e == EACCES || e == EAGAIN) {
            0;
        } else {
            -1;
        };
    }
}

// A jobserver of `n` slots, made by this runner: an unlinked temp file, no FD_CLOEXEC, so every process
// the tree starts inherits the descriptor.
@platform(macos | ios | linux | android)
fn js_make(n: i32) bool {
    let mut path = tmp_template("super-c-jobs-XXXXXX");
    let fd = unsafe mkstemp(path.cstr() as *mut char);
    if fd < 0 {
        return false;
    }
    if unsafe unlink(path.cstr()) != 0 {
        let _ = unsafe unistd::close(fd);
        return false;
    }
    let mut name = String::from_str("SC_JOBSERVER");
    let mut text = format("{},{}", n, fd);
    if unsafe setenv(name.cstr(), text.cstr(), 1) != 0 {
        let _ = unsafe unistd::close(fd);
        return false;
    }
    unsafe {
        JS_FD = fd;
        JS_SLOTS = n;
    }
    return true;
}

// `$TMPDIR/<leaf>` (else /tmp), a mkstemp template.
@platform(macos | ios | linux | android)
fn tmp_template(leaf: str) String {
    let d = stdlib::get_env("TMPDIR").unwrap_or(String::new());
    if d.len() == 0 {
        return format("/tmp/{}", leaf);
    }
    return format("{}/{}", d.as_str(), leaf);
}

// Timeout diagnostics. Each test's capture file is a named file, and the test's process carries its path
// in SC_TEST_DIAG, which every process it starts inherits: the runtime of every Super-C program in the tree
// answers SIGURG by appending its own threads' stacks there (__sc_diag_install, std/rt/base.spc), and a
// library chains its state dump in front (std's reactor). Past a test's deadline the runner asks each
// process of the test's tree in turn, adds the kernel's view of each thread on Linux, then kills the whole
// tree DIAG_GRACE seconds later. SIGURG is ignored by default: cc, ld and the like are left running.
const DIAG_GRACE: f64 = 3.0;
const DIAG_TREE: usize = 64;

// A named capture file in $TMPDIR (else /tmp): its descriptor, -1 when it cannot be made. Every writer
// appends (the test, and the dumps the runner asks for), so none overwrites another.
@platform(macos | ios | linux | android)
fn cap_open(path: &mut String) i32 {
    *path = tmp_template("sc-test-XXXXXX");
    let fd = unsafe mkstemp(path.cstr() as *mut char);
    if fd < 0 {
        return -1;
    }
    let fl = unsafe fcntl::fcntl(fd, fcntl::F_GETFL);
    let _ = unsafe fcntl::fcntl(fd, fcntl::F_SETFL, fl | fcntl::O_APPEND);
    return fd;
}

// The process tree under `root`, root first, breadth first: at most DIAG_TREE processes.
@platform(macos | ios)
fn tree(root: i32) Vector<i32> {
    let mut out = Vector::<i32>::new();
    out.push(root);
    let mut k: usize = 0;
    while k < out.len() && out.len() < DIAG_TREE {
        let mut kids = [0i32; 64];
        // A count of pids, not bytes.
        let nk = unsafe proc_listchildpids(out[k], (&mut kids[0]) as *mut i32, 256);
        for i in 0..nk.max(0i32) as usize {
            if i >= DIAG_TREE || out.len() >= DIAG_TREE {
                break;
            }
            out.push(unsafe kids[i]);
        }
        k += 1;
    }
    return out;
}

@platform(linux | android)
fn tree(root: i32) Vector<i32> {
    let mut out = Vector::<i32>::new();
    out.push(root);
    let mut k: usize = 0;
    while k < out.len() && out.len() < DIAG_TREE {
        let d = unsafe filesystem::opendir("/proc".ptr() as *const char);
        if d == null {
            break;
        }
        loop {
            if out.len() >= DIAG_TREE {
                break;
            }
            let e = (unsafe filesystem::readdir(d)) as *mut dirent;
            if e == null {
                break;
            }
            let p = leading_int(unsafe str::from_cstr(&(*e).d_name[0]));
            if p <= 0 {
                continue;
            }
            let stat = slurp(format("/proc/{}/stat", p).as_str());
            // The last close paren: the command name may hold spaces and parens.
            let s = stat.as_str();
            let rp = last_byte(s, b')');
            if rp < 0 {
                continue;
            }
            // `) <state> <ppid> ...`
            let rest = s.slice(rp as usize + 1, s.len()).trim_start();
            let sp = rest.find_byte(b' ');
            if sp < 0 {
                continue;
            }
            if leading_int(rest.slice(sp as usize + 1, rest.len())) == out[k] {
                out.push(p);
            }
        }
        let _ = unsafe filesystem::closedir(d);
        k += 1;
    }
    return out;
}

// Ask every process of the test's tree for its dump, one after the other, into the capture file at `path`;
// on Linux append each thread's state and kernel wait channel too.
@platform(macos | ios | linux | android)
fn diag_request(root: i32, path: str, limit: u32) {
    append_file(
        path,
        format("\n--- the test ran past its timeout ({} s): the state of each of its processes\n", limit).as_str(),
    );
    let tr = tree(root);
    let pause = timespec { tv_sec: 0, tv_nsec: 400000000 };
    for k in 0..tr.len() {
        let _ = unsafe kill(tr[k], SIGURG);
        let _ = unsafe nanosleep(&pause, null);
    }
    kernel_view(&tr, path);
}

@platform(macos | ios)
fn kernel_view(_tr: &Vector<i32>, _path: str) {}

@platform(linux | android)
fn kernel_view(tr: &Vector<i32>, path: str) {
    let mut o = String::new();
    for k in 0..tr.len() {
        let comm = slurp(format("/proc/{}/comm", tr[k]).as_str());
        let cn = first_line(comm.as_str());
        o.format_into("--- kernel: process {} ({}), thread state and wait channel\n", tr[k], cn);
        let mut tp = format("/proc/{}/task", tr[k]);
        let d = unsafe filesystem::opendir(tp.cstr());
        if d == null {
            continue;
        }
        loop {
            let e = (unsafe filesystem::readdir(d)) as *mut dirent;
            if e == null {
                break;
            }
            let tid = leading_int(unsafe str::from_cstr(&(*e).d_name[0]));
            if tid <= 0 {
                continue;
            }
            let st = slurp(format("/proc/{}/task/{}/stat", tr[k], tid).as_str());
            let wc = slurp(format("/proc/{}/task/{}/wchan", tr[k], tid).as_str());
            let s = first_line(st.as_str());
            let rp = last_byte(s, b')');
            // The last close paren, as in `tree`.
            let state = if rp >= 0 && rp as usize + 2 < s.len() && s.byte_at(rp as usize + 1) == b' ' {
                s.slice(rp as usize + 2, rp as usize + 3);
            } else {
                "?";
            };
            let w = first_line(wc.as_str());
            o.format_into(
                "  {} {} {}\n",
                tid,
                state,
                if w.len() != 0 {
                    w;
                } else {
                    "-";
                },
            );
        }
        let _ = unsafe filesystem::closedir(d);
    }
    append_file(path, o.as_str());
}

@platform(linux | android)
// The index of the last byte `b` of `s`, -1 without one.
fn last_byte(s: str, b: u8) isize {
    let mut i = s.len();
    while i > 0 {
        i -= 1;
        if s.byte_at(i) == b {
            return i as isize;
        }
    }
    return -1;
}

@platform(linux | android)
// The text of `s` up to its first newline.
fn first_line(s: str) str {
    let n = s.find_byte(b'\n');
    return if n < 0 {
        s;
    } else {
        s.slice(0, n as usize);
    };
}

@platform(macos | ios | linux | android)
// Append `text` to the file at `path`; nothing when it cannot be opened.
fn append_file(path: str, text: str) {
    let f = stdio::fopen(path, "ab");
    if f == null {
        return;
    }
    let _ = unsafe stdio::fwrite(text.ptr(), 1, text.len(), f);
    let _ = unsafe stdio::fclose(f);
}

// Kill the test's whole tree: a hung grandchild would otherwise outlive the run.
@platform(macos | ios | linux | android)
fn kill_tree(root: i32) {
    let tr = tree(root);
    let mut k = tr.len();
    while k > 0 {
        k -= 1;
        let _ = unsafe kill(tr[k], SIGKILL);
    }
}

// The parent's tick: SIGALRM every second while a timeout applies, without SA_RESTART, so wait(2) returns
// and the runner checks the deadlines.
@platform(macos | ios | linux | android)
fn tick(_sig: i32) {
    let _ = unsafe alarm(1);
}

// Install `h` for SIGALRM, no flags (`h` null: the default action).
@platform(macos | ios | linux | android)
fn on_alarm(h: fn(i32), dfl: bool) {
    let mut sa = unsafe zeroed::<sigaction>();
    if !dfl {
        sa.handler = h;
    }
    let _ = unsafe sigemptyset(&mut sa.sa_mask);
    let _ = unsafe c_sigaction(SIGALRM, &sa, null);
}

@platform(macos | ios | linux | android)
// The seconds since an unspecified start.
fn now() f64 {
    return sc_runtime::sc_rt_now_ns() as f64 / 1e9;
}

// One line on how a failed test's process ended, from its wait status.
@platform(macos | ios | linux | android)
fn why_posix(st: i32, should_panic: bool) String {
    if signaled(st) {
        return format("terminated by signal {} ({})", st & 0x7f, unsafe str::from_cstr(strsignal(st & 0x7f)));
    }
    if exited(st) && exit_code(st) != 0 {
        return format("exited with code {}", exit_code(st));
    }
    return String::from_str(
        if should_panic {
            "did not panic as expected";
        } else {
            "exited with code 0";
        },
    );
}

@platform(macos | ios | linux | android)
// The wait status macros: the low 7 bits are the terminating signal (0: exited, 0x7f: stopped), the next
// byte the exit code.
fn exited(st: i32) bool {
    return (st & 0x7f) == 0;
}

@platform(macos | ios | linux | android)
fn exit_code(st: i32) i32 {
    return st >> 8 & 0xff;
}

@platform(macos | ios | linux | android)
fn signaled(st: i32) bool {
    return (st & 0x7f) != 0 && (st & 0x7f) != 0x7f;
}

// One running test of the fork pool.
@platform(macos | ios | linux | android)
struct Child {
    pub pid: i32,
    pub test: usize,
    pub path: String,
    pub token: i32,
    pub start: f64,
    // 0 before the deadline, the time the dump was asked for after it, -1 once the tree is killed.
    pub diag: f64,
    pub limit: u32,
}

// Fork-per-test isolation with a wait(2) pool bounded by the process-tree jobserver. Each forked child
// writes to its own capture file, so a test's output is attributed to that test rather than interleaved
// with the pool's.
@platform(macos | ios | linux | android)
fn run_pool(t: &Table, o: &Opts, sel: &Vector<usize>, genv: *mut void, r: &mut Run, d: &mut Durations) i32 {
    let mut kids = Vector::<Child>::new();
    let mut tokens = Tokens::new();
    let mut ticking = false;
    let mut next: usize = 0;
    let mut active: i32 = 0;
    while next < sel.len() || active > 0 {
        while active < o.jobs && next < sel.len() {
            let token = tokens.take();
            if token < 0 {
                break;
            }
            let ti = sel[next];
            let mut path = String::new();
            let fd = cap_open(&mut path);
            if fd < 0 {
                tokens.give(token);
                unsafe stdio::perror("mkstemp".ptr() as *const char);
                return BROKEN;
            }
            let pid = unsafe unistd::fork();
            if pid == 0 {
                if unsafe unistd::dup2(fd, 1) < 0 || unsafe unistd::dup2(fd, 2) < 0 {
                    unsafe stdio::perror("dup2".ptr() as *const char);
                    unsafe exit_now(BROKEN);
                }
                // The parent's tick.
                on_alarm(tick, true);
                let mut dn = String::from_str("SC_TEST_DIAG");
                let _ = unsafe setenv(dn.cstr(), path.cstr(), 1);
                unsafe __sc_diag_install();
                unsafe sc_lk_fork_child_reset();
                errno::set_errno(0);
                t.run(ti, genv);
                unsafe stdio::fflush(null);
                unsafe sc_lk_report_now();
                unsafe stdio::fflush(null);
                unsafe exit_now(0);
            }
            let _ = unsafe unistd::close(fd);
            if pid < 0 {
                tokens.give(token);
                unsafe stdio::perror("fork".ptr() as *const char);
                return BROKEN;
            }
            let limit = t.limit(ti, o.timeout);
            kids.push(Child { pid: pid, test: ti, path: path, token: token, start: now(), diag: 0.0, limit: limit });
            if limit != 0 && !ticking {
                on_alarm(tick, false);
                let _ = unsafe alarm(1);
                ticking = true;
            }
            next += 1;
            active += 1;
        }
        // Past its deadline a child is asked for its state (diag > 0), then killed DIAG_GRACE seconds later
        // (diag < 0); either way it has timed out, also when it ends inside the grace.
        let tn = now();
        for k in 0..kids.len() {
            let c = &mut kids[k];
            if c.pid < 0 || c.limit == 0 || c.diag < 0.0 {
                continue;
            }
            if c.diag == 0.0 && tn - c.start >= c.limit as f64 {
                diag_request(c.pid, c.path.as_str(), c.limit);
                c.diag = now();
            } else if c.diag > 0.0 && tn - c.diag >= DIAG_GRACE {
                kill_tree(c.pid);
                c.diag = -1.0;
            }
        }
        let mut st: i32 = 0;
        let done = unsafe wait(&mut st);
        if done < 0 {
            if errno::errno() == EINTR {
                continue;
            }
            unsafe stdio::perror("wait".ptr() as *const char);
            return BROKEN;
        }
        let mut found = kids.len();
        for k in 0..kids.len() {
            if kids[k].pid == done {
                found = k;
                break;
            }
        }
        // A child the global env started, not a test.
        if found == kids.len() {
            continue;
        }
        let c = kids.swap_remove(found).unwrap();
        active -= 1;
        tokens.give(c.token);
        let ti = c.test;
        r.note(d, ti, now() - c.start);
        // A panic aborts (SIGABRT) and the stack-overflow report exits 134. Any other end of a should_panic
        // test, a SIGSEGV or a leak report's exit 23 included, fails it.
        let as_declared = if t.should_panic(ti) {
            signaled(st) && (st & 0x7f) == signal::SIGABRT || exited(st) && exit_code(st) == 134;
        } else {
            exited(st) && exit_code(st) == 0;
        };
        // Past its deadline, killed or not.
        if c.diag != 0.0 {
            println("test {} ... FAILED (timed out)", t.name(ti));
            r.fail(ti, slurp(c.path.as_str()), timed_out_why(c.limit));
        } else if as_declared {
            r.pass(t, o, ti);
        } else {
            let how = if t.should_panic(ti) {
                " (expected a panic)";
            } else {
                "";
            };
            println("test {} ... FAILED{}", t.name(ti), how);
            r.fail(ti, slurp(c.path.as_str()), why_posix(st, t.should_panic(ti)));
        }
        let mut cp = c.path.clone();
        let _ = unsafe stdio::remove(cp.cstr());
        unsafe stdio::fflush(stdio::stdout());
    }
    if ticking {
        let _ = unsafe alarm(0);
    }
    return 0;
}

// ---- Windows ----------------------------------------------------------------------------------------------------
//
// Windows has no fork(): each test runs in its own subprocess (`self --run-one=<i> --capture=<file>`), so a
// should_panic or crashing test is caught by the child's exit code. The PARENT runs the global
// @test_init/@test_free pair once, exactly as POSIX does: that pair's output is the visible one, since every
// child's stdout goes to its capture file (deleted for passing tests). Each child then builds a private env
// for its own test: no fork means the parent's pointer cannot cross the process boundary. The child
// redirects its own stdout and stderr into the capture file; the parent reads it back for a failed test and
// deletes it.

@platform(windows)
extern "C" "windows.h" {
    fn CreateFileA(name: *const char, access: u32, share: u32, sa: *mut void, disp: u32, flags: u32, tmpl: *mut void) *mut void;
    // The OVERLAPPED argument passes as `void *`: its offset words sit behind a union.
    fn LockFileEx(h: *mut void, flags: u32, reserved: u32, lo: u32, hi: u32, ov: *mut void) i32;
    fn UnlockFileEx(h: *mut void, reserved: u32, lo: u32, hi: u32, ov: *mut void) i32;
    fn GetLastError() u32;
    fn GetTempPathA(n: u32, buf: *mut char) u32;
    fn GetCurrentProcessId() u32;
    fn GetTickCount64() u64;
    fn CloseHandle(h: *mut void) i32;
    fn WaitForMultipleObjects(n: u32, handles: *const *mut void, all: i32, ms: u32) u32;
    // `LPDWORD` points to an `unsigned long`, which no Super-C type spells: the 4-byte object passes as
    // `void *`.
    fn GetExitCodeProcess(h: *mut void, code: *mut void) i32;
    fn TerminateProcess(h: *mut void, code: u32) i32;
    const GENERIC_READ: u32;
    const GENERIC_WRITE: u32;
    const FILE_SHARE_READ: u32;
    const FILE_SHARE_WRITE: u32;
    const FILE_SHARE_DELETE: u32;
    const OPEN_EXISTING: u32;
    const CREATE_NEW: u32;
    const FILE_ATTRIBUTE_NORMAL: u32;
    const FILE_ATTRIBUTE_TEMPORARY: u32;
    const FILE_FLAG_DELETE_ON_CLOSE: u32;
    const LOCKFILE_EXCLUSIVE_LOCK: u32;
    const LOCKFILE_FAIL_IMMEDIATELY: u32;
    const ERROR_LOCK_VIOLATION: u32;
    const MAXIMUM_WAIT_OBJECTS: u32;
    const WAIT_OBJECT_0: u32;
    const WAIT_TIMEOUT: u32;
    const WAIT_FAILED: u32;
    const INFINITE: u32;
    const MAX_PATH: u32;
}

@platform(windows)
extern "C" "stdlib.h" {
    fn _putenv_s(name: *const char, value: *const char) i32;
    fn _get_pgmptr(out: *mut *mut char) i32;
}

@platform(windows)
extern "C" "process.h" {
    fn _spawnv(mode: i32, path: *const char, argv: *const *const char) isize;
    const _P_NOWAIT: i32;
}

@platform(windows)
extern "C" "io.h" {
    fn _dup2(from: i32, to: i32) i32;
}

@platform(windows)
extern "C" "direct.h" {
    fn _chdir(dir: *const char) i32;
}

@platform(windows)
extern "C" "stdio.h" {
    fn _fileno(f: *mut stdio::FILE) i32;
}

// The slot file of the jobserver.
@platform(windows)
static mut JS_H: *mut void = null;

@platform(windows)
const INVALID_HANDLE: usize = 0xFFFFFFFFFFFFFFFF;

// Keep each child's flushed diagnostic in one append.
@platform(windows)
fn prepare_stderr() {
    unsafe setvbuf(stdio::stderr(), null, _IOFBF, BUFSIZ as usize);
}

// WaitForMultipleObjects cannot watch more than MAXIMUM_WAIT_OBJECTS handles at once.
@platform(windows)
fn cap_jobs(jobs: i32) i32 {
    return jobs.min(MAXIMUM_WAIT_OBJECTS as i32);
}

@platform(windows)
fn win_arg(a: str<'static>, o: &mut Opts) bool {
    if a.starts_with("--run-one=") {
        o.run_one = leading_int(a.slice(10, a.len()));
        return true;
    }
    if a.starts_with("--capture=") {
        o.capture = a.slice(10, a.len());
        return true;
    }
    return false;
}

@platform(windows)
unsafe fn chdir_to(dir: *const char) i32 {
    return unsafe _chdir(dir);
}

@platform(windows)
fn env_set(name: &mut String, value: &mut String) {
    let _ = unsafe _putenv_s(name.cstr(), value.cstr());
}

@platform(windows)
fn env_unset(name: &mut String) {
    let _ = unsafe _putenv_s(name.cstr(), "".ptr() as *const char);
}

// The process-tree jobserver the compiler made (src/driver_shim.spc): each slot is one byte of a slot file,
// held by a LockFileEx byte lock, which the system drops when the holder ends.
@platform(windows)
fn js_active() bool {
    if unsafe JS_SLOTS >= 0 {
        return true;
    }
    let v = stdlib::getenv("SC_JOBSERVER");
    if v == null {
        return false;
    }
    let (n, rest) = switch js_parse(unsafe str::from_cstr(v)) {
        Some(p) => p,
        None => {
            return false;
        },
    };
    let mut path = String::from_str(rest);
    let h = unsafe CreateFileA(
        path.cstr(),
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        null,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if h as usize == INVALID_HANDLE {
        return false;
    }
    unsafe {
        JS_H = h;
        JS_SLOTS = n;
    }
    return true;
}

// Lock (`lock`) or unlock slot byte `i`: 1 done, 0 another process holds it, -1 an error.
@platform(windows)
fn js_lock(i: i32, lock: bool) i32 {
    // OVERLAPPED: two pointer-sized words, then the offset's low and high words, then the event handle.
    let mut ov = [0u32; 8];
    ov[4] = i as u32;
    let p = ((&mut ov[0]) as *mut u32) as *mut void;
    if !lock {
        return if unsafe UnlockFileEx(unsafe JS_H, 0, 1, 0, p) != 0 {
            1;
        } else {
            -1;
        };
    }
    if unsafe LockFileEx(unsafe JS_H, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, p) != 0 {
        return 1;
    }
    return if unsafe GetLastError() == ERROR_LOCK_VIOLATION {
        0;
    } else {
        -1;
    };
}

// The temp directory with its trailing separator, None when the system has none.
@platform(windows)
fn temp_dir() Option<String> {
    let mut b = [0u8; 300];
    let n = unsafe GetTempPathA(MAX_PATH, ((&mut b[0]) as *mut u8) as *mut char);
    if n == 0 || n >= MAX_PATH {
        return Option::<String>::None;
    }
    return Option::<String>::Some(String::from_str(unsafe str::from_raw(&b[0], n as usize)));
}

// A jobserver of `n` slots, made by this runner: a temp file deleted when its last handle closes.
@platform(windows)
fn js_make(n: i32) bool {
    let dir = switch temp_dir() {
        Some(d) => d,
        None => {
            return false;
        },
    };
    let mut path = format("{}super-c-jobs-{}-{}", dir.as_str(), unsafe GetCurrentProcessId(), unsafe GetTickCount64());
    let h = unsafe CreateFileA(
        path.cstr(),
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        null,
        CREATE_NEW,
        FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE,
        null,
    );
    if h as usize == INVALID_HANDLE {
        return false;
    }
    // _putenv_s sets the C runtime's copy, which getenv and _spawnv read, and the process's own.
    let mut name = String::from_str("SC_JOBSERVER");
    let mut text = format("{},{}", n, path.as_str());
    if unsafe _putenv_s(name.cstr(), text.cstr()) != 0 {
        let _ = unsafe CloseHandle(h);
        return false;
    }
    unsafe {
        JS_H = h;
        JS_SLOTS = n;
    }
    return true;
}

// The child: run exactly one test in this process; the exit status reports a crash or a panic. Both streams
// go into the one capture file, UNBUFFERED: a panic aborts without flushing, and freopen resets stdout to
// full buffering (Windows has no line buffering at all), so any buffered output would die with the
// crashing test.
@platform(windows)
fn run_one(t: &Table, o: &Opts) i32 {
    if o.capture.len() != 0 {
        let mut p = String::from_str(o.capture);
        let mut mode = String::from_str("wb");
        if unsafe stdio::freopen(p.cstr(), mode.cstr(), stdio::stdout()) == null {
            unsafe stdio::perror(p.cstr());
            return BROKEN;
        }
        if unsafe _dup2(unsafe _fileno(stdio::stdout()), unsafe _fileno(stdio::stderr())) != 0 {
            unsafe stdio::perror("dup2".ptr() as *const char);
            return BROKEN;
        }
        unsafe setvbuf(stdio::stdout(), null, _IONBF, 0);
        unsafe setvbuf(stdio::stderr(), null, _IONBF, 0);
    }
    let genv = t.genv_init();
    errno::set_errno(0);
    t.run(o.run_one as usize, genv);
    if genv != null {
        t.genv_free(genv);
    }
    return 0;
}

// The capture file of test `i` in this run: deterministic, so the parent can name it again at reap time.
@platform(windows)
fn cap_path(tmp: &String, i: usize) String {
    return format("{}sc-test-{}-{}.txt", tmp.as_str(), unsafe GetCurrentProcessId(), i);
}

// One line on how a failed test's process ended, from its exit code.
@platform(windows)
fn why_win(code: u32, should_panic: bool) String {
    if code != 0 {
        let mut s = format("exited with code {} (0x", code);
        let mut h = String::new();
        h.push_hex(code, true);
        for _ in h.len()..8 {
            s.push_byte(b'0');
        }
        s.push_string(&h);
        s.push_byte(b')');
        return s;
    }
    return String::from_str(
        if should_panic {
            "did not panic as expected";
        } else {
            "exited with code 0";
        },
    );
}

// This image's path to run again: argv[0] is whatever the caller typed and need not name a file the loader
// can open (`./__tests` from a shell has no .exe), so the C runtime's real path, else `fallback`.
@platform(windows)
fn self_path() String {
    let mut p: *mut char = null;
    if unsafe _get_pgmptr(&mut p) == 0 && p != null && unsafe p[0] != 0 as char {
        return unsafe String::from_cstr(p);
    }
    return String::from_str("__tests.exe");
}

// One running test of the subprocess pool.
@platform(windows)
struct Child {
    pub h: *mut void,
    pub test: usize,
    pub token: i32,
    pub start: u64,
    pub limit: u32,
    pub late: bool,
}

// A pool of subprocesses, `jobs` at a time, the same shape as the POSIX fork pool: _P_NOWAIT hands back a
// process handle instead of blocking, and WaitForMultipleObjects reaps whichever finishes first. A late
// child is terminated (no state dump: no signals here).
@platform(windows)
fn run_pool(t: &Table, o: &Opts, sel: &Vector<usize>, _genv: *mut void, r: &mut Run, d: &mut Durations) i32 {
    let tmp = switch temp_dir() {
        Some(x) => x,
        None => {
            eprintln("cannot locate the temp directory");
            return BROKEN;
        },
    };
    let mut me = self_path();
    let mut kids = Vector::<Child>::new();
    let mut handles = Vector::<*mut void>::new();
    let mut tokens = Tokens::new();
    let mut next: usize = 0;
    while next < sel.len() || kids.len() > 0 {
        while kids.len() as i32 < o.jobs && next < sel.len() {
            let token = tokens.take();
            if token < 0 {
                break;
            }
            let ti = sel[next];
            next += 1;
            let mut id = format("--run-one={}", ti);
            // _spawnv joins the arguments with spaces and quotes nothing; the temp path may hold spaces.
            let mut cap = format("--capture=\"{}\"", cap_path(&tmp, ti).as_str());
            let args: [*const char; 4] = [me.cstr(), id.cstr(), cap.cstr(), null];
            let ph = unsafe _spawnv(_P_NOWAIT, me.cstr(), &args[0]);
            if ph == -1 {
                tokens.give(token);
                println("test {} ... FAILED (could not start)", t.name(ti));
                r.fail(ti, String::new(), String::from_str("could not start"));
                unsafe stdio::fflush(stdio::stdout());
                continue;
            }
            kids.push(
                Child {
                    h: ph as *mut void,
                    test: ti,
                    token: token,
                    start: unsafe GetTickCount64(),
                    limit: t.limit(ti, o.timeout),
                    late: false,
                },
            );
            handles.push(ph as *mut void);
        }
        if kids.len() == 0 {
            continue;
        }
        let mut limited = false;
        for k in 0..kids.len() {
            limited = limited || kids[k].limit != 0;
        }
        let w = unsafe WaitForMultipleObjects(
            kids.len() as u32,
            &handles[0],
            0,
            if limited {
                1000;
            } else {
                INFINITE;
            },
        );
        if w == WAIT_TIMEOUT {
            let tn = unsafe GetTickCount64();
            for k in 0..kids.len() {
                let c = &mut kids[k];
                if c.limit != 0 && !c.late && tn - c.start >= c.limit as u64 * 1000 {
                    let _ = unsafe TerminateProcess(c.h, 1);
                    c.late = true;
                }
            }
            continue;
        }
        let slot = w - WAIT_OBJECT_0;
        if w == WAIT_FAILED || slot as usize >= kids.len() {
            eprintln("WaitForMultipleObjects failed (error {})", unsafe GetLastError());
            return BROKEN;
        }
        let mut code: u32 = 1;
        let _ = unsafe GetExitCodeProcess(kids[slot as usize].h, (&mut code) as *mut u32);
        let _ = unsafe CloseHandle(kids[slot as usize].h);
        // The pool is unordered: backfill from the end.
        let c = kids.swap_remove(slot as usize).unwrap();
        let _ = handles.swap_remove(slot as usize);
        tokens.give(c.token);
        let ti = c.test;
        r.note(d, ti, (unsafe GetTickCount64() - c.start) as f64 / 1000.0);
        // A panic aborts: exit code 3, or 0xC0000409 when the CRT fails fast; the stack-overflow report
        // exits 134. Any other code fails a should_panic test.
        let as_declared = if t.should_panic(ti) {
            code == 3 || code == 134 || code == 0xC0000409;
        } else {
            code == 0;
        };
        let mut cp = cap_path(&tmp, ti);
        if !c.late && as_declared {
            r.pass(t, o, ti);
        } else {
            let how = if c.late {
                " (timed out)";
            } else if t.should_panic(ti) {
                " (expected a panic)";
            } else {
                "";
            };
            println("test {} ... FAILED{}", t.name(ti), how);
            let why = if c.late {
                timed_out_why(c.limit);
            } else {
                why_win(code, t.should_panic(ti));
            };
            r.fail(ti, slurp(cp.as_str()), why);
        }
        let _ = unsafe stdio::remove(cp.cstr());
        unsafe stdio::fflush(stdio::stdout());
    }
    return 0;
}

// ---- wasm: one thread, no processes ----------------------------------------------------------------------------

@platform(wasm)
fn prepare_stderr() {}

@platform(wasm)
fn cap_jobs(jobs: i32) i32 {
    return jobs;
}

@platform(wasm)
fn win_arg(_a: str<'static>, _o: &mut Opts) bool {
    return false;
}

@platform(wasm)
fn run_one(_t: &Table, _o: &Opts) i32 {
    return 2;
}

@platform(wasm)
unsafe fn chdir_to(dir: *const char) i32 {
    return unsafe unistd::chdir(dir);
}

@platform(wasm)
fn env_set(_name: &mut String, _value: &mut String) {}

@platform(wasm)
fn env_unset(_name: &mut String) {}

@platform(wasm)
fn js_active() bool {
    return false;
}

@platform(wasm)
fn js_make(_n: i32) bool {
    return true;
}

// wasm has no process to isolate a test in: the tests run in this process.
@platform(wasm)
fn run_pool(t: &Table, o: &Opts, sel: &Vector<usize>, genv: *mut void, r: &mut Run, _d: &mut Durations) i32 {
    return run_in_process(t, o, sel, genv, r);
}
