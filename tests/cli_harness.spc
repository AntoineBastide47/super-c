// CLI tests use $SUPERC (default ./super-c) and isolated temporary source trees.
// Run from the repository root so the default compiler path resolves.
import stdio;
import stdlib;
import string as cstring;
import driver_shim as shim;
import std::platform::fs;
import std::platform::env as penv;
import std::platform::process;
import driver::util as dutil;
import build_system::objcache as ocache;

// A `realpath` result buffer: PATH_MAX on Linux, and the size `sc_realpath` gives `_fullpath` on Windows.
type PathMax = Array<char, 4096>;

static mut C_SEQ: u64 = 0;
// The compiler path, resolved once (see `superc`).
static mut SUPERC_RESOLVED: PathMax = PathMax {};

/// Exit code and owned stdout/stderr from a CLI invocation.
pub struct CliResult {
    pub exit: i32,
    pub out: *mut char,
}

extend CliResult {
    /// True when the captured output contains `needle`.
    pub fn out_has(self: &CliResult, needle: str) bool {
        if self.out == null {
            return false;
        }
        return contains_str(self.out, needle);
    }
    /// The captured output (empty when none was captured).
    pub const fn text(self: &CliResult) str {
        if self.out == null {
            return "";
        }
        return unsafe str::from_cstr(self.out);
    }
    /// Check for `needle`; print the captured output if absent.
    pub fn out_shows(self: &CliResult, needle: str) bool {
        if self.out_has(needle) {
            return true;
        }
        eprintln("--- expected to find: {}", needle);
        self.show();
        return false;
    }
    /// Check for exit code 0; print the captured output on failure.
    pub fn ok(self: &CliResult) bool {
        if self.exit == 0 {
            return true;
        }
        eprintln("--- expected exit 0 ---");
        self.show();
        return false;
    }
    /// Print the exit code and the captured output to stderr.
    pub fn show(self: &CliResult) {
        eprintln("--- captured output (exit {}) follows ---", self.exit);
        if self.out == null {
            eprintln("(nothing captured)");
        } else {
            unsafe stdio::fputs(self.out, stdio::stderr());
        }
        eprintln("--- end of captured output ---");
    }
}
extend CliResult as Free {
    pub fn free(self: &mut Self) {
        if self.out != null {
            unsafe stdlib::free(self.out);
            self.out = null;
        }
    }
}

/// The whole file at `path` as text (empty when it cannot be opened).
pub fn read_text(path: str) String {
    let mut p = String::from_str(path);
    let buf = slurp(p.cstr());
    if buf == null {
        return String::new();
    }
    let text = unsafe String::from_cstr(buf);
    unsafe stdlib::free(buf);
    return text;
}

// Copy `needle` to provide the NUL terminator required by strstr.
pub fn contains_str(hay: *const char, needle: str) bool {
    if hay == null {
        return false;
    }
    let mut nb = String::from_str(needle);
    return unsafe cstring::strstr(hay, nb.cstr()) != null;
}

/// The system temp directory, without a trailing separator ('/' separators on Windows); "." when the
/// system names none.
pub fn tmp_dir() String {
    return fs::temp_dir().unwrap_or(String::from_str("."));
}

/// True when the host platform is Windows.
pub const fn on_windows() bool {
    return unsafe shim::sc_host_platform() == 0;
}

// True when the compiler under test is the wasm lane's shim (ci/wasm-superc.sh routes transpile-class
// commands into wasmtime). The wasm guest runs with a fixed --dir mount, so it does NOT inherit a
// test's chdir and cannot spawn subprocesses: a CLI test that depends on the working directory for a
// guest command (fmt/lint/clean of relative paths, project sweeps) or that runs `command` (a shell
// line) must early-return under this.
pub fn on_wasm() bool {
    return contains_str(superc(), "wasm");
}

// Resolve an absolute compiler path so child processes can change directories.
fn superc() *const char {
    // Process-local: the runner forks one process per test, so this resolve-once cache is never shared.
    if unsafe SUPERC_RESOLVED[0] != 0 as char {
        return &unsafe SUPERC_RESOLVED[0];
    }
    let sc = stdlib::getenv("SUPERC");
    let want = if sc == null || unsafe *sc == 0 as char {
        format("./super-c{}", unsafe str::from_cstr(binext()));
    } else {
        unsafe String::from_cstr(sc);
    };
    let slot = ((&mut unsafe SUPERC_RESOLVED) as *mut PathMax) as *mut char;
    let real = fs::realpath(want.as_str()).unwrap_or(want);
    assert(real.len() < 4096, "the compiler path fits");
    unsafe cstring::memcpy(slot, real.as_ptr(), real.len());
    unsafe slot[real.len()] = 0 as char;
    return slot;
}

/// Absolute path from $SUPERC, or ./super-c when unset.
pub fn superc_path() str<'static> {
    return unsafe str::from_cstr(superc());
}

/// C compiler from $CC, or gcc on Windows and cc elsewhere.
pub fn cc_name() *const char {
    let cc = stdlib::getenv("CC");
    if cc != null && unsafe *cc != 0 as char {
        return cc;
    }
    if on_windows() {
        return "gcc".ptr() as *const char;
    }
    return "cc".ptr() as *const char;
}

/// Whether the C compiler (`cc_name`) is installed. A test that compiles C itself or forces the C path
/// returns early without it: the lane with no C compiler runs the rest.
pub fn has_cc() bool {
    let mut path = String::new();
    return ocache::which_path(unsafe str::from_cstr(cc_name()), &mut path) != 0;
}

/// Whether the C compiler (`cc_name`) is clang: its `--version` says so.
pub fn cc_is_clang() bool {
    let out = format("{}/cc_version_{}.txt", tmp_dir().as_str(), process::pid().unwrap_or(1));
    let mut cmd = format("\"{}\" --version", unsafe str::from_cstr(cc_name()));
    let mut outp = out.clone();
    let ok = run_with(cmd.cstr(), null, outp.cstr(), null, "") == 0;
    let t = read_text(out.as_str());
    let _ = fs::unlink(out.as_str());
    return ok && t.contains("clang");
}

// The C standard the harness compiles emitted trees with. mingw hides POSIX prototypes behind
// `__STRICT_ANSI__` under a strict `-std=c11`, so the Windows leg asks for the GNU dialect instead.
/// The C standard the harness compiles with (c11, or gnu11 on Windows).
pub const fn cstd() *const char {
    if on_windows() {
        return "-std=gnu11 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700".ptr() as *const char;
    }
    return "-std=c11 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700".ptr() as *const char;
}

// The same, as a `--cstd=` flag for a nested `super-c build`: EMPTY on POSIX, where the manifest default
// is already this exact string. Passing a partial override (`-std=c11` without the POSIX define) is worse
// than passing nothing: glibc then hides the prototypes the emitted C needs, which Darwin never does.
/// `cstd()` as a `-std=` flag.
pub const fn cstd_flag() *const char {
    if on_windows() {
        return "\"--cstd=-std=gnu11 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700\"".ptr() as *const char;
    }
    return "".ptr() as *const char;
}

// The executable suffix a linked test binary gets ("" or ".exe"). mingw's gcc appends `.exe` to an output
// name that has no extension, so the harness names its binaries with the suffix already on.
/// The executable suffix: `.exe` on Windows, empty elsewhere.
pub const fn binext() *const char {
    if on_windows() {
        return ".exe".ptr() as *const char;
    }
    return "".ptr() as *const char;
}

// Read a whole stream into a fresh NUL-terminated heap buffer (caller frees). Seeks to the end for length.
fn read_stream(f: *mut stdio::FILE) *mut char {
    unsafe stdio::fflush(f);
    let _ = unsafe stdio::fseek(f, 0, stdio::SEEK_END);
    let sz = unsafe stdio::ftell(f);
    if sz < 0 {
        return null;
    }
    unsafe stdio::rewind(f);
    let buf = (unsafe stdlib::malloc(sz as usize + 1)) as *mut char;
    if buf == null {
        return null;
    }
    let got = unsafe stdio::fread(buf, 1, sz as usize, f);
    unsafe buf[got] = 0 as char;
    return buf;
}

// Read a whole file into a fresh NUL-terminated buffer (caller frees); null if it cannot be opened.
fn slurp(path: *const char) *mut char {
    let f = stdio::fopen(unsafe str::from_cstr(path), "rb");
    if f == null {
        return null;
    }
    let buf = read_stream(f);
    unsafe stdio::fclose(f);
    return buf;
}

// Run `basecmd` with stdout+stderr captured into `outpath` and read back. The redirection is the runner's
// (`run_with`), not the shell's, so `basecmd` is a plain command line that means the same thing to
// /bin/sh and to CreateProcess.
fn exec(basecmd: *const char, outpath: *const char) CliResult {
    return exec_env(basecmd, outpath, "");
}

// `exec`, with `env` ("NAME=VALUE" pairs, space separated) applied to the child only.
fn exec_env(basecmd: *const char, outpath: *const char, env: str) CliResult {
    let rc = run_with(basecmd, null, outpath, null, env);
    let mut r = CliResult { exit: rc, out: null };
    r.out = slurp(outpath);
    return r;
}

/// Run `cmd` shell-free with stdin, stdout and stderr bound to the given paths (a null stdin reads
/// nothing, a null stdout is discarded, a null stderr joins stdout) and `env` ("NAME=VALUE" pairs, space
/// separated) applied to it alone; its exit code. SC_LEAK_CHECK=fatal applies unless `env` sets
/// SC_LEAK_CHECK: a process a test runs fails on a leak whatever the suite's own environment.
pub fn run_with(cmd: *const char, in_path: *const char, out_path: *const char, err_path: *const char, env: str) i32 {
    let mut e = String::new();
    if env.find("SC_LEAK_CHECK=") < 0 {
        e.push_str("SC_LEAK_CHECK=fatal ");
    }
    e.push_str(env);
    let mut sets = Vector::<String>::new();
    if !env_parse(e.as_str(), &mut sets) {
        return -1;
    }
    // The child's whole environment: this process's, each assigned name replaced by its last assignment.
    let vars = penv::vars().unwrap();
    let mut it = vars.iter();
    let mut kept = Vector::<String>::new();
    while let Some((name, value)) = it.next() {
        if !env_assigns(sets[0..sets.len()], name) {
            kept.push(format("{}={}", name, value));
        }
    }
    let mut all = Vector::<str>::new();
    for i in 0..kept.len() {
        all.push(kept.at(i).as_str());
    }
    for i in 0..sets.len() {
        let s = sets.at(i).as_str();
        let eq = s.find_byte(b'=') as usize;
        // An empty value removes the variable on Windows, as the C runtime's `_putenv_s` does.
        let removed = on_windows() && eq + 1 == s.len();
        if !removed && !env_assigns(sets[i + 1..sets.len()], s.slice(0, eq)) {
            all.push(s);
        }
    }
    let line = unsafe str::from_cstr(cmd);
    let sh: [str; 3] = ["sh", "-c", line];
    let none: [str; 0] = [];
    let mut c = if on_windows() {
        process::Command::new(none);
    } else {
        process::Command::new(sh);
    };
    // POSIX runs the line through /bin/sh; Windows hands it to CreateProcess as written, with no shell.
    if on_windows() {
        c.command_line = Option::<str>::Some(line);
    } else {
        c.program = Option::<str>::Some("/bin/sh");
    }
    c.env = Option::<Slice<str>>::Some(all[0..all.len()]);
    c.stdin = redirect_of(in_path, process::Redirect::Null);
    c.stdout = redirect_of(out_path, process::Redirect::Null);
    c.stderr = redirect_of(err_path, process::Redirect::Stdout);
    let started = process::spawn(c);
    if started.is_err() {
        eprint("cannot start {}: OS error {}\n", line, started.unwrap_err().code);
        // A quoted program path: what its directory holds.
        if line.starts_with("\"") {
            let e = line.slice(1, line.len()).find_byte(b'"');
            let prog = line.slice(1, 1 + e as usize);
            let mut d = prog.len();
            while d > 0 && prog.byte_at(d - 1) != b'/' {
                d -= 1;
            }
            let dir = prog.slice(0, d);
            let names = dutil::list_dir(dir, true).unwrap_or(Vector::<String>::new());
            eprint("{} holds:", dir);
            for i in 0..names.len() {
                eprint(" {}", names[i].as_str());
            }
            eprint("\n");
        }
        return -1;
    }
    let mut child = started.unwrap();
    let w = child.wait();
    if w.is_err() {
        eprint("cannot wait for {}: OS error {}\n", line, w.unwrap_err().code);
        return -1;
    }
    return switch w.unwrap() {
        Code(code) => code,
        _ => -1,
    };
}

// The redirect of a child stream to the file `path` names, or `none` for a null `path`.
const fn redirect_of<'a>(path: *const char, none: process::Redirect<'a>) process::Redirect<'a> {
    if path == null {
        return none;
    }
    return process::Redirect::Path(unsafe str::from_cstr(path));
}

// The most assignments one `run_with` environment takes, and the longest name.
const ENV_MAX: usize = 8;
const ENV_NAME_MAX: usize = 63;

// Parse `env`: NAME=VALUE assignments, space separated (a VALUE in double quotes may hold spaces), into
// `out` as NAME=VALUE: false when one is malformed or there are more than ENV_MAX, so a child never runs
// with part of the environment its caller asked for.
fn env_parse(env: str, out: &mut Vector<String>) bool {
    let n = env.len();
    let mut p: usize = 0;
    // Bounded: each assignment consumes at least its '='.
    loop {
        while p < n && (env.byte_at(p) == b' ' || env.byte_at(p) == b'\t') {
            p += 1;
        }
        if p == n {
            return true;
        }
        let mut eq = p;
        while eq < n && env.byte_at(eq) != b'=' && env.byte_at(eq) != b' ' && env.byte_at(eq) != b'\t' {
            eq += 1;
        }
        if eq == n || env.byte_at(eq) != b'=' || out.len() == ENV_MAX {
            return false;
        }
        let mut v0 = eq + 1;
        let mut v1 = v0;
        let mut end = v0;
        if v0 < n && env.byte_at(v0) == b'"' {
            v0 += 1;
            v1 = v0;
            while v1 < n && env.byte_at(v1) != b'"' {
                v1 += 1;
            }
            if v1 == n {
                return false;
            }
            end = v1 + 1;
        } else {
            while v1 < n && env.byte_at(v1) != b' ' && env.byte_at(v1) != b'\t' {
                v1 += 1;
            }
            end = v1;
        }
        if end < n && env.byte_at(end) != b' ' && env.byte_at(end) != b'\t' {
            return false;
        }
        let nl = eq - p;
        if nl == 0 || nl > ENV_NAME_MAX {
            return false;
        }
        let mut a = String::from_str(env.slice(p, eq + 1));
        a.push_str(env.slice(v0, v1));
        out.push(a);
        p = end;
    }
}

// Whether one of the NAME=VALUE assignments `sets` names variable `name` (any case on Windows, whose
// names are case-insensitive).
const fn env_assigns(sets: []String, name: str) bool {
    for i in 0..sets.len() {
        let s = sets[i].as_str();
        let k = s.slice(0, s.find_byte(b'=') as usize);
        if k == name || on_windows() && k.len() == name.len() && ascii_eq_nocase(k, name) {
            return true;
        }
    }
    return false;
}

const fn ascii_eq_nocase(a: str, b: str) bool {
    for i in 0..a.len() {
        if (a.byte_at(i) | 0x20) != (b.byte_at(i) | 0x20) {
            return false;
        }
    }
    return true;
}

// Run a command with its output discarded and return its exit code: the escape hatch for the few checks
// that drive a C compiler or a helper binary directly.
/// Run `cmd` shell-free with all output discarded; its exit code.
pub fn run_quiet(cmd: *const char) i32 {
    return run_with(cmd, null, null, null, "");
}

// Run a command with stdin, stdout and stderr each bound to a file. What the LSP tests need, and the one
// shape a shell would have written as `< in > out 2> err`.
/// Run `cmd` shell-free with stdin/stdout/stderr redirected to the given paths (see `run_with`).
pub fn run_io(cmd: *const char, in_path: *const char, out_path: *const char, err_path: *const char) i32 {
    return run_with(cmd, in_path, out_path, err_path, "");
}

// A temp project root with helpers to write a source tree, compile it, and cc+run the emitted build/ tree.
/// A scratch project directory (its absolute path, NUL-terminated), removed with its files when the
/// value is dropped.
pub struct Proj {
    root: Array<char, 256>,
}

/// A fresh empty scratch project under the system temp directory, named by pid.
pub fn proj_new() Proj {
    return Proj::fresh();
}

extend Proj {
    // The scratch directory `proj_new` hands out.
    fn fresh() Proj {
        // Process-local: one forked process per test, and the name carries the pid, the sequence and
        // the clock; a directory an aborted test left under a reused pid is cleared before use, so a
        // fixture never reads another test's files.
        unsafe C_SEQ = unsafe C_SEQ + 1;
        let mut p = Proj { root: Array::<char, 256> {} };
        let root = format(
            "{}/sccli_{}_{}_{}",
            tmp_dir().as_str(),
            process::pid().unwrap_or(1),
            unsafe C_SEQ,
            dutil::ticks_ms() as u64,
        );
        assert(root.len() < 256, "the scratch path fits");
        unsafe p.root.copy_from(root.as_ptr(), root.len());
        let _ = fs::remove_all(root.as_str());
        let _ = fs::mkdir_all(root.as_str());
        return p;
    }

    /// The project root as a C string.
    pub const fn rootp(self: &Proj) *const char {
        return &self.root[0];
    }

    /// The project root.
    pub const fn dir(self: &Proj) str {
        return str::from_cbuf(self.root.as_slice());
    }

    // Write <root>/rel (creating parent dirs); rel may contain a subdirectory (e.g. "lib/lib.spc").
    /// Write `content` to `rel` under the root, creating directories.
    pub fn mkfile(self: &Proj, rel: str, content: str) {
        let path = format("{}/{}", self.dir(), rel);
        // Everything up to the last separator is the directory to create.
        let mut cut: usize = 0;
        for i in 0..path.len() {
            let b = path.as_str().byte_at(i);
            if b == b'/' || b == b'\\' {
                cut = i;
            }
        }
        if cut > 0 {
            let dir = String::from_str(path.as_str().slice(0, cut));
            let _ = fs::mkdir_all(dir.as_str()); // a failure shows as the open's below
        }
        let f = stdio::fopen(path.as_str(), "wb"); // binary: no Windows CRLF in emitted test files
        if f == null {
            eprintln("--- cannot open {} for writing", path.as_str());
        }
        assert(f != null, "mkfile opens its file");
        let wrote = if content.len() == 0 {
            0;
        } else {
            unsafe stdio::fwrite(content.ptr(), 1, content.len(), f);
        };
        let closed = unsafe stdio::fclose(f);
        assert(wrote == content.len() && closed == 0, "mkfile writes its file");
    }

    // Copy a repository file into this isolated project. This keeps large end-to-end fixtures in
    // normal source files instead of duplicating them inside matchertext literals.
    /// Copy `source` to `rel` under the root; false on failure.
    pub fn copyfile(self: &Proj, rel: str, source: str) bool {
        let mut path = String::from_str(source);
        let content = slurp(path.cstr());
        if content == null {
            return false;
        }
        self.mkfile(rel, unsafe str::from_cstr(content));
        unsafe stdlib::free(content);
        return true;
    }

    // Compile <root>/mainrel with the given extra flags (compile-only mode: emits <root>/build/, no link).
    /// Run the compiler on `mainrel` with extra `flags`, capturing output.
    pub fn compile_flags(self: &Proj, flags: str, mainrel: str) CliResult {
        return self.compile_flags_env(flags, mainrel, "");
    }

    /// `compile_flags` with `env` ("NAME=VALUE" pairs, space separated) applied to the compiler and
    /// everything it runs, so a check never depends on the suite's own environment.
    pub fn compile_flags_env(self: &Proj, flags: str, mainrel: str, env: str) CliResult {
        let root = self.dir();
        let mut base = format("\"{}\" {} \"{}/{}\"", superc_path(), flags, root, mainrel);
        let mut op = format("{}/.out", root);
        return exec_env(base.cstr(), op.cstr(), env);
    }

    /// Run the compiler on `mainrel`, capturing output.
    pub fn compile(self: &Proj, mainrel: str) CliResult {
        return self.compile_flags("", mainrel);
    }

    // Run `$SUPERC <args>` verbatim (for flag-only invocations like usage checks); no path is appended.
    /// Run the compiler with `args` verbatim from the project root, capturing output.
    pub fn run_raw(self: &Proj, args: str) CliResult {
        let root = self.dir();
        let mut base = format("\"{}\" {}", superc_path(), args);
        let mut op = format("{}/.out", root);
        return exec_env(base.cstr(), op.cstr(), "");
    }

    // Every `*.c` under `dir` (recursively) into `out`: the `find` a shell command would run.
    fn c_files(self: &Proj, dir: str, out: &mut Vector<String>) {
        let names = dutil::list_dir(dir, true).unwrap_or(Vector::<String>::new());
        for i in 0..names.len() {
            let nm = names.at(i).as_str();
            let child = format("{}/{}", dir, nm);
            if dutil::is_dir(child.as_str()) {
                self.c_files(child.as_str(), out);
                continue;
            }
            if nm.ends_with(".c") {
                out.push(child);
            }
        }
    }

    // The `@link` flags the emit wrote to build/debug/raw/__ldflags, space separated (empty when there are
    // none): the `cat` a shell command would run.
    fn append_ldflags(self: &Proj, out: &mut String) {
        let flags = read_text(format("{}/build/debug/raw/__ldflags", self.dir()).as_str());
        if flags.len() == 0 {
            return;
        }
        out.push_byte(b' ');
        for i in 0..flags.len() {
            let b = flags.as_str().byte_at(i);
            out.push_byte(
                if b == b'\n' {
                    b' ';
                } else {
                    b;
                },
            );
        }
    }

    // Compile the whole emitted build/ tree (plus any `extra` flags; its `-l`, `-L` and `-Wl,` words join
    // the link) and link <root>/bin with the @link __ldflags. `strict` adds -Wall -Wextra -Werror;
    // without it this is the plain build (the analog of cli_test's `cc -std=c11`, where a tree
    // containing @test functions compiles as an ordinary program). The units compile through the object
    // cache's script namespace (`objcache::compile_units`): a unit reuses an object only when the same
    // compiler and flags compiled the same text and includes before, so every check is a compile's own.
    // The compiler's diagnostics go to the test's stderr.
    fn cc_tree(self: &Proj, extra: str, strict: bool) CliResult {
        return self.cc_tree_with(extra, strict, "");
    }

    // `cc_tree` that also links the C files `csrcs` (paths under the root, space separated), each compiled
    // alone with the plain flags into `<file>.o`: the prebuilt C library a program takes through `@link`.
    fn cc_tree_with(self: &Proj, extra: str, strict: bool, csrcs: str) CliResult {
        let root = self.dir();
        let raw = format("{}/build/debug/raw", root);
        let mut ccv = Vector::<String>::new();
        dutil::split_args(&mut ccv, unsafe str::from_cstr(cc_name()));
        let mut cfv = Vector::<String>::new();
        dutil::split_args(&mut cfv, unsafe str::from_cstr(cstd()));
        dutil::split_args(&mut cfv, "-funsigned-char -ffp-contract=off");
        if strict {
            dutil::split_args(&mut cfv, "-Wall -Wextra -Werror");
        }
        let mut ex = Vector::<String>::new();
        dutil::split_args(&mut ex, extra);
        let mut link = String::from_str(unsafe str::from_cstr(cc_name()));
        for i in 0..ex.len() {
            let w = ex.at(i).as_str();
            if w.starts_with("-l") || w.starts_with("-L") || w.starts_with("-Wl,") {
                link.format_into(" {}", w);
            } else {
                cfv.push(String::from_str(w));
            }
        }
        let mut all = Vector::<String>::new();
        self.c_files(raw.as_str(), &mut all);
        // The members of `__sc_unity.c` compile through it, not alone.
        let mut members = Set::<String>::new();
        dutil::unity_members(raw.as_str(), &mut members);
        let mut units = Vector::<String>::new();
        for i in 0..all.len() {
            let rel = String::from_str(all.at(i).as_str().slice(raw.len() + 1, all.at(i).len()));
            if !members.contains(&rel) {
                units.push(all.at(i).clone());
            }
        }
        // Without a cache root the namespace is the project's own: every unit compiles.
        let croot = ocache::cache_root("");
        let ns = if croot.len() != 0 {
            ocache::script_ns(croot.as_str());
        } else {
            format("{}/.objcache", root);
        };
        let mut objs = Vector::<String>::new();
        let rc = ocache::compile_units(&ccv, &cfv, raw.as_str(), &units, ns.as_str(), &mut objs);
        // The compile claimed the suite's free job slots, which a claim keeps until its process exits:
        // give them back now, so the test's later builds and the other tests run in parallel.
        unsafe shim::sc_jobserver_release_claim();
        if rc != 0 {
            return CliResult { exit: rc, out: null };
        }
        for i in 0..objs.len() {
            link.format_into(" \"{}\"", objs.at(i).as_str());
        }
        let mut cs = Vector::<String>::new();
        dutil::split_args(&mut cs, csrcs);
        for i in 0..cs.len() {
            let mut c = String::from_str(unsafe str::from_cstr(cc_name()));
            c.format_into(
                " {} -funsigned-char -c \"{}/{}\" -o \"{}/{}.o\"",
                unsafe str::from_cstr(cstd()),
                root,
                cs.at(i).as_str(),
                root,
                cs.at(i).as_str(),
            );
            let mut cop = format("{}/.ccout", root);
            let r = exec(c.cstr(), cop.cstr());
            if r.exit != 0 {
                return r;
            }
            link.format_into(" \"{}/{}.o\"", root, cs.at(i).as_str());
        }
        self.append_ldflags(&mut link);
        link.format_into(" -o \"{}/bin{}\"", root, unsafe str::from_cstr(binext()));
        let mut op = format("{}/.ccout", root);
        return exec(link.cstr(), op.cstr());
    }

    /// Compile every generated C file with the harness flags and link `bin`; the C compiler's result.
    pub fn cc_build(self: &Proj, extra: str) CliResult {
        return self.cc_tree(extra, true);
    }

    /// `cc_build` that also compiles the C files `csrcs` (paths under the root, space separated) and links
    /// their objects: a C library the program binds comes prebuilt, never from the program's tree.
    pub fn cc_build_with(self: &Proj, extra: str, csrcs: str) CliResult {
        return self.cc_tree_with(extra, true, csrcs);
    }

    /// Compile the C files `csrcs` (paths under the root, space separated) with the plain flags and archive
    /// them into `<root>/lib<name>.a` with `$AR` (else `ar`): the prebuilt C library a program the build
    /// engine links names with `@link("-L<root> -l<name>")`. Whether every step succeeded.
    pub fn c_lib(self: &Proj, name: str, csrcs: str) bool {
        let root = self.dir();
        let a = stdlib::getenv("AR");
        let ar = if a != null && unsafe *a != 0 as char {
            unsafe str::from_cstr(a);
        } else {
            "ar";
        };
        let mut arc = format("{} rcs \"{}/lib{}.a\"", ar, root, name);
        let mut cs = Vector::<String>::new();
        dutil::split_args(&mut cs, csrcs);
        for i in 0..cs.len() {
            let mut c = String::from_str(unsafe str::from_cstr(cc_name()));
            c.format_into(
                " {} -funsigned-char -c \"{}/{}\" -o \"{}/{}.o\"",
                unsafe str::from_cstr(cstd()),
                root,
                cs.at(i).as_str(),
                root,
                cs.at(i).as_str(),
            );
            if run_quiet(c.cstr()) != 0 {
                return false;
            }
            arc.format_into(" \"{}/{}.o\"", root, cs.at(i).as_str());
        }
        return run_quiet(arc.cstr()) == 0;
    }

    /// `cc_build` without the pedantic warning set.
    pub fn cc_build_plain(self: &Proj, extra: str) CliResult {
        return self.cc_tree(extra, false);
    }

    // Run the linked <root>/bin with `env` ("VAR=v " assignments, trailing space; a literal) prefixed,
    // capturing its exit code and output.
    /// Run the linked binary with `env` applied, capturing output.
    pub fn run_bin_env(self: &Proj, env: str) CliResult {
        let root = self.dir();
        let mut base = format("\"{}/bin{}\"", root, unsafe str::from_cstr(binext()));
        let mut op = format("{}/.runout", root);
        return exec_env(base.cstr(), op.cstr(), env);
    }

    // Run the linked <root>/bin and return its exit code.
    /// Run the linked binary; its exit code.
    pub fn run_bin(self: &Proj) i32 {
        return self.run_bin_env("").exit;
    }

    // The path of generated file `rel` under <root>/build/debug/raw.
    fn raw_path(self: &Proj, rel: str) String {
        return format("{}/build/debug/raw/{}", self.dir(), rel);
    }

    // True if the generated <root>/build/rel contains `needle` (the `grep -q` analog).
    /// True when generated file `rel` (under build/debug/raw) contains `needle`.
    pub fn gen_has(self: &Proj, rel: str, needle: str) bool {
        let mut path = self.raw_path(rel);
        let buf = slurp(path.cstr());
        if buf == null {
            return false;
        }
        let found = contains_str(buf, needle);
        unsafe stdlib::free(buf);
        return found;
    }

    /// True when the generated file of an `extern "C" "<header>"` header (`__sc_t/__scx<k>.h`: the
    /// header's include and the checks of its blocks) contains `needle`.
    pub fn xhdr_has(self: &Proj, needle: str) bool {
        // The files are numbered from 0 without a gap.
        for k in 0usize..10000 {
            let mut rel = String::from_str("__sc_t/__scx");
            let mut w: usize = 1000;
            while w > 1 && k < w {
                rel.push_str("0");
                w /= 10;
            }
            rel.push_u64(k as u64);
            rel.push_str(".h");
            let mut path = self.raw_path(rel.as_str());
            let buf = slurp(path.cstr());
            if buf == null {
                return false;
            }
            let found = contains_str(buf, needle);
            unsafe stdlib::free(buf);
            if found {
                return true;
            }
        }
        return false;
    }

    /// True when the definition of C function `name` in generated file `rel` (under build/debug/raw)
    /// contains `needle`.
    pub fn gen_fn_has(self: &Proj, rel: str, name: str, needle: str) bool {
        return self.gen_fn_count(rel, name, needle) > 0;
    }

    /// How many times the definition of C function `name` in generated file `rel` (under
    /// build/debug/raw) contains `needle`, or -1 without that definition: the text from the line that
    /// defines it to its closing brace at column 0.
    pub fn gen_fn_count(self: &Proj, rel: str, name: str, needle: str) i32 {
        let mut path = self.raw_path(rel);
        let buf = slurp(path.cstr());
        if buf == null {
            return -1;
        }
        let mut n: i32 = -1;
        let text = unsafe str::from_cstr(buf);
        let mut head = String::from_str(" ");
        head.push_str(name);
        head.push_str("(");
        // A prototype ends its line with `;`, the definition with `{`.
        let mut at: usize = 0;
        while at < text.len() {
            let i = text.slice(at, text.len()).find(head.as_str());
            if i < 0 {
                break;
            }
            let st = at + i as usize;
            let rest = text.slice(st, text.len());
            let eol = rest.find("\n");
            if eol > 0 && rest.slice(0, eol as usize).ends_with("{") {
                let end = rest.find("\n}\n");
                if end > 0 {
                    let mut body = rest.slice(0, end as usize);
                    n = 0;
                    loop {
                        let k = body.find(needle);
                        if k < 0 {
                            break;
                        }
                        n += 1;
                        body = body.slice(k as usize + needle.len(), body.len());
                    }
                }
                break;
            }
            at = st + head.len();
        }
        unsafe stdlib::free(buf);
        return n;
    }

    // How many entries under <root>/build/debug/raw start with `prefix`: the `find ... | wc -l` analog, which
    // asserts that generated wrapper TUs are pruned.
    /// Number of entries under build/debug/raw whose name starts with `prefix`.
    pub fn gen_count(self: &Proj, prefix: str) i32 {
        let raw = format("{}/build/debug/raw", self.dir());
        let names = dutil::list_dir(raw.as_str(), true).unwrap_or(Vector::<String>::new());
        let mut n: i32 = 0;
        for i in 0..names.len() {
            if names.at(i).starts_with(prefix) {
                n = n + 1;
            }
        }
        return n;
    }

    // True if <root>/build/rel exists (the `access(.., F_OK)` analog).
    /// True when `rel` exists under build/debug/raw.
    pub fn gen_exists(self: &Proj, rel: str) bool {
        let f = stdio::fopen(self.raw_path(rel).as_str(), "rb");
        if f == null {
            return false;
        }
        unsafe stdio::fclose(f);
        return true;
    }

    // Compile <root>/mainrel and assert a nonzero exit with a diagnostic containing `want` (expect_fail).
    /// Assert that compiling `mainrel` fails with output containing `want`.
    pub fn expect_fail(self: &Proj, mainrel: str, want: str) {
        let r = self.compile(mainrel);
        assert(r.exit != 0, "expected nonzero exit on a bad program");
        assert(r.out_has(want), "diagnostic missing expected text");
    }

    /// Check every case of `b` (see `Batch`) through `compile_flags` with `b.flags`.
    pub fn expect_batch(self: &Proj, mut b: Batch) {
        while b.next() {
            let r = self.compile_flags(b.flags.as_str(), b.write(self, "case_root.spc"));
            b.take(r.exit, r.text());
        }
    }
}

extend Proj as Free {
    pub fn free(self: &mut Self) {
        let _ = fs::remove_all(self.dir());
    }
}

/// An environment variable a test set, restored to its previous value (or removed) when the guard drops:
/// under `--test-no-fork` every test shares one process, so no setting may outlive its test.
pub struct EnvGuard {
    name: String,
    had: bool,
    old: String,
}

/// Set `name` to `value` in this process until the returned guard drops.
pub fn set_env(name: str, value: str) EnvGuard {
    return EnvGuard::set(name, value);
}

extend EnvGuard {
    fn set(name: str, value: str) EnvGuard {
        let prev = stdlib::getenv(name);
        let mut g = EnvGuard { name: String::from_str(name), had: prev != null, old: String::new() };
        if prev != null {
            g.old = unsafe String::from_cstr(prev);
        }
        assert(unsafe penv::set(name, value).is_ok(), "the variable is set");
        return g;
    }
}

extend EnvGuard as Free {
    pub fn free(self: &mut Self) {
        let rc = if self.had {
            unsafe penv::set(self.name.as_str(), self.old.as_str());
        } else {
            unsafe penv::unset(self.name.as_str());
        };
        assert(rc.is_ok(), "the variable is restored");
        self.name.free();
        self.old.free();
    }
}

/// Copy the std tree `SC_STD_DIR` names and the ffi tree beside it to `<root>/sc/std` and `<root>/sc/ffi`:
/// a std of the test's own, which `SC_STD_DIR=<root>/sc/std` selects.
pub fn copy_std(root: str) {
    let std_dir = stdlib::get_env("SC_STD_DIR").unwrap();
    let mut d = String::new();
    d.format_into("{}/sc/std", root);
    copy_tree(std_dir.as_str(), d.as_str());
    d.clear();
    d.format_into("{}/sc/ffi", root);
    let mut ffi = String::new();
    ffi.format_into("{}/../ffi", std_dir.as_str());
    copy_tree(ffi.as_str(), d.as_str());
}

// Copy the files and directories under `src` to `dst`.
fn copy_tree(src: str, dst: str) {
    dutil::mkdir_p(dst);
    let names = dutil::list_dir(src, false).unwrap();
    for i in 0..names.len() {
        let mut s = String::new();
        s.format_into("{}/{}", src, names.at(i).as_str());
        let mut d = String::new();
        d.format_into("{}/{}", dst, names.at(i).as_str());
        if dutil::is_dir(s.as_str()) {
            copy_tree(s.as_str(), d.as_str());
        } else {
            assert(dutil::copy_file(s.as_str(), d.as_str()), "the file copies");
        }
    }
}

/// Run the compiler under test FROM `dir` with one environment variable set: the shape the global
/// object-cache tests need: the engine resolves build.toml from its working directory and the cache
/// from its environment. No shell syntax: Windows' sc_run hands the line to CreateProcess verbatim,
/// so the directory moves via chdir (the runner restores it after the test) and the
/// variable rides sc_run's env parameter. superc_path() resolves before the chdir moves ".".
pub fn superc_env_in(dir: str, key: str, val: str, args: str) CliResult {
    return exe_env_in(superc_path(), dir, key, val, args);
}

/// `superc_env_in` with the compiler binary `exe` (an absolute path) instead of the one under test.
pub fn exe_env_in(exe: str, dir: str, key: str, val: str, args: str) CliResult {
    let mut kv = String::new();
    kv.format_into("{}={}", key, val);
    return exe_in(exe, dir, kv.as_str(), args);
}

/// Run the compiler under test FROM `dir` with the suite's environment: its builds share the suite's
/// object cache, so a unit any earlier build compiled is not compiled again.
pub fn superc_in(dir: str, args: str) CliResult {
    return exe_in(superc_path(), dir, "", args);
}

// Run `exe <args>` from `dir` with `env` ("NAME=VALUE" pairs, space separated) applied to it.
fn exe_in(exe: str, dir: str, env: str, args: str) CliResult {
    let mut cmd = String::new();
    cmd.format_into("\"{}\" {}", exe, args);
    let mut op = String::new();
    op.format_into("{}/.envout", dir);
    if process::set_current_dir(dir).is_err() {
        return CliResult { exit: -1, out: null };
    }
    return exec_env(cmd.cstr(), op.cstr(), env);
}

/// How many entries of `dir` end with `suffix`.
pub fn dir_count_suffix(dir: str, suffix: str) i32 {
    let names = dutil::list_dir(dir, true).unwrap_or(Vector::<String>::new());
    let mut n = 0;
    for i in 0..names.len() {
        if names.at(i).ends_with(suffix) {
            n = n + 1;
        }
    }
    return n;
}

/// Overwrite every `suffix`-named entry of `dir` with junk; how many were hit. What proves a cache is
/// really READ: a later consumer must choke on the junk.
pub fn dir_corrupt_suffix(dir: str, suffix: str) i32 {
    let mut names = dutil::list_dir(dir, true).unwrap_or(Vector::<String>::new());
    names.retain(|n: &String| n.ends_with(suffix));
    for i in 0..names.len() {
        let mut fp = String::from_str(dir);
        fp.push_str("/");
        fp.push_string(names.at(i));
        let f = stdio::fopen(fp.as_str(), "wb");
        if f != null {
            let junk = "not an object file";
            unsafe stdio::fwrite(junk.ptr(), 1, junk.len(), f);
            unsafe stdio::fclose(f);
        }
    }
    return names.len() as i32;
}

/// A family of negative cases checked in few compiles. Case k, named by its label, is the program
/// `head`, `src`, `tail`, and its check is that a diagnostic holds `want`, at `at` ("L:C" in that program) when `at` is not
/// empty, and under `one` that the program reports exactly one error. A round compiles every case not
/// yet verified at once: case k is module `case_k` (file `case_k.spc`, the case's program unchanged)
/// of a root that imports them all, so the cases share no names. A round verifies a case only by an
/// error the compiler locates in the case's own file, so one case's message never satisfies another's
/// check. The errors of a stage stop the compiler before the next stage, so each round verifies the
/// cases of one more stage. After a round that verifies none, each remaining case compiles alone, as
/// file `file`, and takes the check of its own program: `want` anywhere in the output, or in the
/// diagnostic at `at`. Drive it with `next`, `write` and `take` (`Proj::expect_batch`,
/// `h::expect_build_errs`).
pub struct Batch {
    head: String,
    tail: String,
    /// The file a case compiled alone is written to.
    pub file: String,
    /// The compiler flags of `Proj::expect_batch`.
    pub flags: String,
    /// Each case reports exactly one error.
    pub one: bool,
    forbid: Vector<String>,
    labels: Vector<String>,
    srcs: Vector<String>,
    wants: Vector<String>,
    ats: Vector<String>,
    // The verified cases, the cases of the current program, the case it holds alone (-1: a round),
    // whether the rounds have ended, and the programs handed out.
    done: Vector<bool>,
    sel: Vector<bool>,
    alone: isize,
    solo: bool,
    programs: usize,
}

// One rendered diagnostic of a compiler's output: whether it is an error, the base name of the file
// of its primary location and that location ("L:C"; both empty without one), and the byte range of
// its text, from its kind to the next diagnostic.
struct Diag {
    pub error: bool,
    pub file: String,
    pub loc: String,
    pub start: usize,
    pub end: usize,
}

// The diagnostics of `out`. Each starts at a line `error: ` or `warning: `; its first `--> PATH:L:C`
// line is its primary location.
fn diags_of(out: str) Vector<Diag> {
    let mut ds = Vector::<Diag>::new();
    let mut located = false;
    let mut at: usize = 0;
    while at < out.len() {
        let nl = out.slice(at, out.len()).find("\n");
        let end = if nl < 0 {
            out.len();
        } else {
            at + nl as usize + 1;
        };
        let line = out.slice(at, end);
        if line.starts_with("error: ") || line.starts_with("warning: ") {
            if ds.len() > 0 {
                ds.index_mut(ds.len() - 1).end = at;
            }
            let d = Diag {
                error: line.starts_with("error: "),
                file: String::new(),
                loc: String::new(),
                start: at,
                end: out.len(),
            };
            ds.push(d);
            located = false;
        } else if line.starts_with("--> ") && ds.len() > 0 && !located {
            located = true;
            let l = line.slice(4, line.len()).trim_end();
            // PATH:L:C, where PATH may hold a drive colon: split at the last two colons.
            let mut cuts: usize = 0;
            let mut k = l.len();
            while k > 0 && cuts < 2 {
                k -= 1;
                if l.byte_at(k) == b':' {
                    cuts += 1;
                }
            }
            if cuts == 2 {
                let mut base: usize = 0;
                for i in 0..k {
                    if l.byte_at(i) == b'/' || l.byte_at(i) == b'\\' {
                        base = i + 1;
                    }
                }
                let d = ds.index_mut(ds.len() - 1);
                d.file = String::from_str(l.slice(base, k));
                d.loc = String::from_str(l.slice(k + 1, l.len()));
            }
        }
        at = end;
    }
    return ds;
}

extend Batch {
    /// An empty batch whose case programs start with `head` and end with `tail`.
    pub fn new(head: str, tail: str) Batch {
        return Batch {
            head: String::from_str(head),
            tail: String::from_str(tail),
            file: String::from_str("main.spc"),
            flags: String::new(),
            one: false,
            forbid: Vector::<String>::new(),
            labels: Vector::<String>::new(),
            srcs: Vector::<String>::new(),
            wants: Vector::<String>::new(),
            ats: Vector::<String>::new(),
            done: Vector::<bool>::new(),
            sel: Vector::<bool>::new(),
            alone: -1,
            solo: false,
            programs: 0,
        };
    }

    /// Add the case `label` whose diagnostic holds `want`, located anywhere in its program.
    pub fn add(self: &mut Batch, label: str, src: str, want: str) {
        self.add_at(label, src, want, "");
    }

    /// Add the case `label` whose diagnostic holds `want` at `at` ("L:C" in its program).
    pub fn add_at(self: &mut Batch, label: str, src: str, want: str, at: str) {
        self.labels.push(String::from_str(label));
        self.srcs.push(String::from_str(src));
        self.wants.push(String::from_str(want));
        self.ats.push(String::from_str(at));
        self.done.push(false);
    }

    /// Fail every check whose output contains `text`.
    pub fn forbid(self: &mut Batch, text: str) {
        self.forbid.push(String::from_str(text));
    }

    // The program of case `k`.
    fn program(self: &Batch, k: usize) String {
        let mut s = self.head.clone();
        s.push_string(self.srcs.at(k));
        s.push_string(&self.tail);
        return s;
    }

    /// Choose the next program and return true, or return false when every case is verified. `write`
    /// writes the program, and the result of its compile goes to `take`.
    pub fn next(self: &mut Batch) bool {
        self.programs += 1;
        // Each round verifies a case or ends the rounds, and each program after them verifies a case.
        assert(self.programs <= self.srcs.len() + 2, "each program verifies a case or ends the rounds");
        self.sel.clear();
        self.alone = -1;
        let mut n: usize = 0;
        if !self.solo {
            for j in 0..self.srcs.len() {
                let s = !*self.done.at(j);
                self.sel.push(s);
                n += s as usize;
            }
            // A last case compiles alone at once: a round would cost as much and might not verify it.
            self.solo = n <= 1;
        }
        if self.solo {
            self.sel.clear();
            for j in 0..self.srcs.len() {
                let s = !*self.done.at(j) && self.alone < 0;
                if s {
                    self.alone = j as isize;
                }
                self.sel.push(s);
            }
            if self.alone < 0 {
                return false;
            }
            eprintln("--- case {} ({}) compiles alone", self.alone, self.labels.at(self.alone as usize).as_str());
        }
        return true;
    }

    /// Write the program `next` chose into `p` and return the file to compile: in a round each
    /// case's file and the root `root` that imports them, else the case's program as `file`.
    pub fn write<'a>(self: &'a Batch, p: &Proj, root: str<'a>) str<'a> {
        if self.alone >= 0 {
            p.mkfile(self.file.as_str(), self.program(self.alone as usize).as_str());
            return self.file.as_str();
        }
        let mut main = String::new();
        for j in 0..self.srcs.len() {
            if *self.sel.at(j) {
                p.mkfile(format("case_{}.spc", j).as_str(), self.program(j).as_str());
                main.format_into("import case_{};\n", j);
            }
        }
        main.push_str("fn main() i32 {\n    return 0;\n}\n");
        p.mkfile(root, main.as_str());
        return root;
    }

    /// Record the compile of the program `next` chose: its exit status and output. Asserts the check
    /// of a case compiled alone.
    pub fn take(self: &mut Batch, exit: i32, out: str) {
        if self.alone >= 0 {
            let k = self.alone as usize;
            assert(self.alone_ok(k, exit, out), self.labels.at(k).as_str());
            self.done.set(k, true);
            return;
        }
        let ds = diags_of(out);
        // The case of each diagnostic (-1: none).
        let mut of = Vector::<isize>::new();
        for d in ds.iter() {
            let mut c: isize = -1;
            if d.file.starts_with("case_") && d.file.ends_with(".spc") {
                let k = d.file.as_str().slice(5, d.file.len() - 4).parse_usize().unwrap_or(self.srcs.len());
                if k < self.srcs.len() && *self.sel.at(k) {
                    c = k as isize;
                }
            }
            of.push(c);
        }
        let mut stray = exit == 0;
        for i in 0..ds.len() {
            stray = stray || self.one && ds.at(i).error && *of.at(i) < 0;
        }
        for f in self.forbid.iter() {
            stray = stray || out.contains(f.as_str());
        }
        let mut verified: usize = 0;
        for j in 0..self.srcs.len() {
            if !*self.sel.at(j) {
                continue;
            }
            let at = self.ats.at(j).as_str();
            let mut errors: usize = 0;
            let mut found = false;
            for i in 0..ds.len() {
                if *of.at(i) != j as isize {
                    continue;
                }
                let d = ds.at(i);
                if d.error {
                    errors += 1;
                }
                let held = out.slice(d.start, d.end).contains(self.wants.at(j).as_str());
                found = found || held && (at.len() == 0 || d.loc.eq_str(at));
            }
            if !stray && found && errors >= 1 && (!self.one || errors == 1) {
                self.done.set(j, true);
                verified += 1;
            }
        }
        self.solo = verified == 0;
    }

    // Whether `out`, the output of a compile of case `k` alone that exited `exit`, passes the case's
    // check; prints the case and the output when it does not.
    fn alone_ok(self: &Batch, k: usize, exit: i32, out: str) bool {
        let want = self.wants.at(k).as_str();
        let at = self.ats.at(k).as_str();
        let mut ok = exit != 0;
        for f in self.forbid.iter() {
            ok = ok && !out.contains(f.as_str());
        }
        if at.len() == 0 {
            ok = ok && out.contains(want);
        } else {
            let mut found = false;
            for d in diags_of(out).iter() {
                found = found || d.file.equals(&self.file) && d.loc.eq_str(at) && out.slice(d.start, d.end).contains(
                    want,
                );
            }
            ok = ok && found;
        }
        if self.one {
            let mut errors: usize = 0;
            for line in out.lines() {
                if line.starts_with("error: ") {
                    errors += 1;
                }
            }
            ok = ok && errors == 1;
        }
        if !ok {
            eprintln(
                "--- case {} ({}): expected '{}' at '{}', exit {}; program:",
                k,
                self.labels.at(k).as_str(),
                want,
                at,
                exit,
            );
            eprintln("{}--- output:\n{}", self.program(k).as_str(), out);
        }
        return ok;
    }
}
