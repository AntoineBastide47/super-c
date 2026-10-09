// CLI tests use $SUPERC (default ./super-c) and isolated temporary source trees.
// Run from the repository root so the default compiler path resolves.
import stdio;
import stdlib;
import string as cstring;
import driver_shim as shim;

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
    let text = String::from_cstr(buf);
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

/// True when the host platform is Windows.
pub fn on_windows() bool {
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
    let mut want = if sc == null || unsafe *sc == 0 as char {
        format("./super-c{}", str::from_cstr(binext()));
    } else {
        String::from_cstr(sc);
    };
    let slot = ((&mut unsafe SUPERC_RESOLVED) as *mut PathMax) as *mut char;
    if unsafe shim::sc_realpath(want.cstr(), slot) == null {
        assert(want.len() < 4096, "the compiler path fits");
        unsafe cstring::memcpy(slot, want.as_ptr(), want.len());
        unsafe slot[want.len()] = 0 as char;
    }
    return slot;
}

/// Absolute path from $SUPERC, or ./super-c when unset.
pub fn superc_path() str<'static> {
    return str::from_cstr(superc());
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

// The C standard the harness compiles emitted trees with. mingw hides POSIX prototypes behind
// `__STRICT_ANSI__` under a strict `-std=c11`, so the Windows leg asks for the GNU dialect instead.
/// The C standard the harness compiles with (c11, or gnu11 on Windows).
pub fn cstd() *const char {
    if on_windows() {
        return "-std=gnu11 -D_POSIX_C_SOURCE=200809L".ptr() as *const char;
    }
    return "-std=c11 -D_POSIX_C_SOURCE=200809L".ptr() as *const char;
}

// The same, as a `--cstd=` flag for a nested `super-c build`: EMPTY on POSIX, where the manifest default
// is already this exact string. Passing a partial override (`-std=c11` without the POSIX define) is worse
// than passing nothing: glibc then hides the prototypes the emitted C needs, which Darwin never does.
/// `cstd()` as a `-std=` flag.
pub fn cstd_flag() *const char {
    if on_windows() {
        return "\"--cstd=-std=gnu11 -D_POSIX_C_SOURCE=200809L\"".ptr() as *const char;
    }
    return "".ptr() as *const char;
}

// The executable suffix a linked test binary gets ("" or ".exe"). mingw's gcc appends `.exe` to an output
// name that has no extension, so the harness names its binaries with the suffix already on.
/// The executable suffix: `.exe` on Windows, empty elsewhere.
pub fn binext() *const char {
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
    let f = stdio::fopen(str::from_cstr(path), "rb");
    if f == null {
        return null;
    }
    let buf = read_stream(f);
    unsafe stdio::fclose(f);
    return buf;
}

// Run `basecmd` with stdout+stderr captured into `outpath` and read back. The redirection is the runner's
// (shim::sc_run), not the shell's, so `basecmd` is a plain command line that means the same thing to
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
    return unsafe shim::sc_run(cmd, in_path, out_path, err_path, e.cstr());
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
        let pid = unsafe shim::sc_getpid();
        let mut p = Proj { root: Array::<char, 256> {} };
        let n = unsafe stdio::snprintf(
            &mut p.root[0],
            256,
            "%s/sccli_%d_%llu_%llu".ptr() as *const char,
            unsafe shim::sc_tmpdir(),
            pid,
            unsafe C_SEQ,
            (unsafe shim::sc_ticks_ms()) as u64,
        );
        assert(n > 0 && n < 256, "the scratch path fits");
        let _ = unsafe shim::sc_rm_rf(&p.root[0]);
        let _ = unsafe shim::sc_mkdir_p(&p.root[0]);
        return p;
    }

    /// The project root as a C string.
    pub const fn rootp(self: &Proj) *const char {
        return &self.root[0];
    }

    // Write <root>/rel (creating parent dirs); rel may contain a subdirectory (e.g. "lib/lib.spc").
    /// Write `content` to `rel` under the root, creating directories.
    pub fn mkfile(self: &Proj, rel: str, content: str) {
        let path = format("{}/{}", str::from_cstr(self.rootp()), rel);
        // Everything up to the last separator is the directory to create.
        let mut cut: usize = 0;
        for i in 0..path.len() {
            let b = path.as_str().byte_at(i);
            if b == b'/' || b == b'\\' {
                cut = i;
            }
        }
        if cut > 0 {
            let mut dir = String::from_str(path.as_str().slice(0, cut));
            let _ = unsafe shim::sc_mkdir_p(dir.cstr()); // a failure shows as the open's below
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
        self.mkfile(rel, str::from_cstr(content));
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
        let root = str::from_cstr(self.rootp());
        let mut base = format("\"{}\" {} \"{}/{}\"", superc_path(), flags, root, mainrel);
        let mut op = format("{}/.out", root);
        let envb = cache_env(root, env);
        return exec_env(base.cstr(), op.cstr(), envb.as_str());
    }

    /// Run the compiler on `mainrel`, capturing output.
    pub fn compile(self: &Proj, mainrel: str) CliResult {
        return self.compile_flags("", mainrel);
    }

    // Run `$SUPERC <args>` verbatim (for flag-only invocations like usage checks); no path is appended.
    /// Run the compiler with `args` verbatim from the project root, capturing output.
    pub fn run_raw(self: &Proj, args: str) CliResult {
        let root = str::from_cstr(self.rootp());
        let mut base = format("\"{}\" {}", superc_path(), args);
        let mut op = format("{}/.out", root);
        let envb = cache_env(root, "");
        return exec_env(base.cstr(), op.cstr(), envb.as_str());
    }

    // Append every `*.c` under `dir` (recursively) to `out`, each double-quoted: the `find` a shell
    // command would run. Doing it here keeps the command shell-free, and a shell-free command is
    // the same command on Windows.
    fn append_c_files(self: &Proj, dir: str, out: &mut String) {
        let mut dirb = String::from_str(dir);
        let d = unsafe shim::sc_opendir(dirb.cstr());
        if d == null {
            return;
        }
        loop {
            let e = unsafe shim::sc_readdir(d);
            if e == null {
                break;
            }
            let nm = str::from_cstr(unsafe shim::sc_dirent_name(e));
            if nm == "." || nm == ".." {
                continue;
            }
            let mut child = format("{}/{}", dir, nm);
            if unsafe shim::sc_stat_isdir(child.cstr()) == 1 {
                self.append_c_files(child.as_str(), out);
                continue;
            }
            if nm.ends_with(".c") {
                out.format_into(" \"{}\"", child.as_str());
            }
        }
        let _ = unsafe shim::sc_closedir(d);
    }

    // The `@c.link` flags the emit wrote to build/dev/raw/__ldflags, space separated (empty when there are
    // none): the `cat` a shell command would run.
    fn append_ldflags(self: &Proj, out: &mut String) {
        let flags = read_text(format("{}/build/dev/raw/__ldflags", str::from_cstr(self.rootp())).as_str());
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

    // Cc the whole emitted build/ tree -Werror (plus any `extra` flags and @c.link __ldflags) into
    // <root>/bin. `strict` adds -Wall -Wextra -Werror; without it this is the plain build (the analog of
    // cli_test's `cc -std=c11`, where a tree containing @test functions compiles as an ordinary program).
    fn cc_tree(self: &Proj, extra: str, strict: bool) CliResult {
        let root = str::from_cstr(self.rootp());
        let mut base = format(
            "{} {} -funsigned-char -ffp-contract=off{}",
            str::from_cstr(cc_name()),
            str::from_cstr(cstd()),
            if strict {
                " -Wall -Wextra -Werror";
            } else {
                "";
            },
        );
        self.append_c_files(format("{}/build/dev/raw", root).as_str(), &mut base);
        base.format_into(" {}", extra);
        self.append_ldflags(&mut base);
        base.format_into(" -o \"{}/bin{}\"", root, str::from_cstr(binext()));
        let mut op = format("{}/.ccout", root);
        return exec(base.cstr(), op.cstr());
    }

    /// Compile every generated C file with the harness flags and link `bin`; the C compiler's result.
    pub fn cc_build(self: &Proj, extra: str) CliResult {
        return self.cc_tree(extra, true);
    }

    /// `cc_build` without the pedantic warning set.
    pub fn cc_build_plain(self: &Proj, extra: str) CliResult {
        return self.cc_tree(extra, false);
    }

    // Run the linked <root>/bin with `env` ("VAR=v " assignments, trailing space; a literal) prefixed,
    // capturing its exit code and output.
    /// Run the linked binary with `env` applied, capturing output.
    pub fn run_bin_env(self: &Proj, env: str) CliResult {
        let root = str::from_cstr(self.rootp());
        let mut base = format("\"{}/bin{}\"", root, str::from_cstr(binext()));
        let mut op = format("{}/.runout", root);
        return exec_env(base.cstr(), op.cstr(), env);
    }

    // Run the linked <root>/bin and return its exit code.
    /// Run the linked binary; its exit code.
    pub fn run_bin(self: &Proj) i32 {
        return self.run_bin_env("").exit;
    }

    // The path of generated file `rel` under <root>/build/dev/raw.
    fn raw_path(self: &Proj, rel: str) String {
        return format("{}/build/dev/raw/{}", str::from_cstr(self.rootp()), rel);
    }

    // True if the generated <root>/build/rel contains `needle` (the `grep -q` analog).
    /// True when generated file `rel` (under build/dev/raw) contains `needle`.
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

    /// True when the definition of C function `name` in generated file `rel` (under build/dev/raw)
    /// contains `needle`.
    pub fn gen_fn_has(self: &Proj, rel: str, name: str, needle: str) bool {
        return self.gen_fn_count(rel, name, needle) > 0;
    }

    /// How many times the definition of C function `name` in generated file `rel` (under
    /// build/dev/raw) contains `needle`, or -1 without that definition: the text from the line that
    /// defines it to its closing brace at column 0.
    pub fn gen_fn_count(self: &Proj, rel: str, name: str, needle: str) i32 {
        let mut path = self.raw_path(rel);
        let buf = slurp(path.cstr());
        if buf == null {
            return -1;
        }
        let mut n: i32 = -1;
        let text = str::from_cstr(buf);
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

    // How many entries under <root>/build/dev/raw start with `prefix`: the `find ... | wc -l` analog, which
    // asserts that generated wrapper TUs are pruned.
    /// Number of entries under build/dev/raw whose name starts with `prefix`.
    pub fn gen_count(self: &Proj, prefix: str) i32 {
        let mut raw = format("{}/build/dev/raw", str::from_cstr(self.rootp()));
        let d = unsafe shim::sc_opendir(raw.cstr());
        if d == null {
            return 0;
        }
        let mut n: i32 = 0;
        let pl = prefix.len();
        loop {
            let e = unsafe shim::sc_readdir(d);
            if e == null {
                break;
            }
            let nm = unsafe shim::sc_dirent_name(e);
            if unsafe cstring::strncmp(nm, prefix.ptr() as *const char, pl) == 0 {
                n = n + 1;
            }
        }
        let _ = unsafe shim::sc_closedir(d);
        return n;
    }

    // True if <root>/build/rel exists (the `access(.., F_OK)` analog).
    /// True when `rel` exists under build/dev/raw.
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
}

extend Proj as Free {
    pub fn free(self: &mut Self) {
        let _ = unsafe shim::sc_rm_rf(self.rootp());
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
            g.old = String::from_cstr(prev);
        }
        let mut v = String::from_str(value);
        assert(unsafe shim::sc_setenv(g.name.cstr(), v.cstr()) == 0, "the variable is set");
        return g;
    }
}

extend EnvGuard as Free {
    pub fn free(self: &mut Self) {
        let rc = if self.had {
            unsafe shim::sc_setenv(self.name.cstr(), self.old.cstr());
        } else {
            unsafe shim::sc_unsetenv(self.name.cstr());
        };
        assert(rc == 0, "the variable is restored");
        self.name.free();
        self.old.free();
    }
}

/// `env` ("NAME=VALUE" pairs, space separated) with the build cache set under the scratch directory
/// `root` unless `env` sets one: a compiler the harness runs never writes into the user's global
/// cache, and the cache goes away with the scratch directory.
pub fn cache_env(root: str, env: str) String {
    let mut out = String::new();
    if env.find("SC_CACHE_DIR=") < 0 {
        out.format_into("SC_CACHE_DIR=\"{}/.sccache\"", root);
        if env.len() != 0 {
            out.push_byte(b' ');
        }
    }
    out.push_str(env);
    return out;
}

/// `cache_env` for a fixture build in scratch directory `root`: the suite's shared fixture cache when
/// `super-c test` named one (SC_TEST_CACHE_DIR), so the runtime and std units fixtures emit identically
/// compile once per suite run; else the cache under `root`.
pub fn fixture_cache_env(root: str) String {
    let fx = stdlib::getenv("SC_TEST_CACHE_DIR");
    if fx != null && unsafe *fx != 0 as char {
        return format("SC_CACHE_DIR=\"{}\"", str::from_cstr(fx));
    }
    return cache_env(root, "");
}

/// Run the compiler under test FROM `dir` with one environment variable set (and the build cache under
/// `dir`, see `cache_env`): the shape the global object-cache tests need: the engine resolves build.toml from its working directory and the cache
/// from its environment. No shell syntax: Windows' sc_run hands the line to CreateProcess verbatim,
/// so the directory moves via chdir (the runner restores it after the test) and the
/// variable rides sc_run's env parameter. superc_path() resolves before the chdir moves ".".
pub fn superc_env_in(dir: str, key: str, val: str, args: str) CliResult {
    return exe_env_in(superc_path(), dir, key, val, args);
}

/// `superc_env_in` with the compiler binary `exe` (an absolute path) instead of the one under test.
pub fn exe_env_in(exe: str, dir: str, key: str, val: str, args: str) CliResult {
    let mut cmd = String::new();
    cmd.format_into("\"{}\" {}", exe, args);
    let mut kv = String::new();
    kv.format_into("{}={}", key, val);
    let env = cache_env(dir, kv.as_str());
    let mut op = String::new();
    op.format_into("{}/.envout", dir);
    let mut d = String::from_str(dir);
    if unsafe shim::sc_chdir(d.cstr()) != 0 {
        return CliResult { exit: -1, out: null };
    }
    return exec_env(cmd.cstr(), op.cstr(), env.as_str());
}

/// How many entries of `dir` end with `suffix`.
pub fn dir_count_suffix(dir: str, suffix: str) i32 {
    let mut d = String::from_str(dir);
    let dh = unsafe shim::sc_opendir(d.cstr());
    if dh == null {
        return 0;
    }
    let mut n = 0;
    loop {
        let e = unsafe shim::sc_readdir(dh);
        if e == null {
            break;
        }
        let nm = str::from_cstr(unsafe shim::sc_dirent_name(e));
        if nm.ends_with(suffix) {
            n = n + 1;
        }
    }
    unsafe shim::sc_closedir(dh);
    return n;
}

/// Overwrite every `suffix`-named entry of `dir` with junk; how many were hit. What proves a cache is
/// really READ: a later consumer must choke on the junk.
pub fn dir_corrupt_suffix(dir: str, suffix: str) i32 {
    let mut d = String::from_str(dir);
    let dh = unsafe shim::sc_opendir(d.cstr());
    if dh == null {
        return 0;
    }
    let mut names = Vector::<String>::new();
    loop {
        let e = unsafe shim::sc_readdir(dh);
        if e == null {
            break;
        }
        let nm = str::from_cstr(unsafe shim::sc_dirent_name(e));
        if nm.ends_with(suffix) {
            names.push(String::from_str(nm));
        }
    }
    unsafe shim::sc_closedir(dh);
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
