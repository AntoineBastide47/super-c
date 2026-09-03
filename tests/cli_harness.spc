// CLI test harness: drives $SUPERC as a subprocess over on-disk source trees; the analog of
// tests/cli_test.c's run_cmd / write_file / mkfile. A `Proj` is a temp project root under the system temp
// directory; write a
// source tree into it with `mkfile`, compile it with `compile` (compile-only mode, which emits a build/
// tree next to the root file), then cc the emitted tree -Werror with `cc_build` and run it with `run_bin`.
// Generated C is inspected via `gen_has` / `gen_exists`. The compiler is $SUPERC (default "./super-c",
// matching the CWD=repo-root that `make selfhost-test` runs), so the suite dogfoods the self-hosted driver.
import stdio;
import stdlib;
import string as cstring;
import driver_shim as shim;

type Path512 = Array<char, 512>;
type Cmd8192 = Array<char, 8192>;

static mut C_SEQ: u64 = 0;
// The compiler path, resolved once (see `superc`).
static mut SUPERC_RESOLVED: Path512 = Path512 {};

// The captured result of a subprocess: its exit code and combined stdout+stderr (`out`, owned).
/// Outcome of a CLI invocation: exit code and captured output.
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
    /// `out_has`, but it DUMPS what was captured when the answer is no. A remote CI failure that says only
    /// "expected `right: 7`" cannot be diagnosed: it does not say whether the line was absent, truncated, or
    /// interleaved with a concurrent test's output. Use this wherever a missed expectation would otherwise
    /// have to be investigated by guessing.
    pub fn out_shows(self: &CliResult, needle: str) bool {
        if self.out_has(needle) {
            return true;
        }
        eprintln("--- expected to find: {}", needle);
        eprintln("--- captured output (exit {}) follows ---", self.exit);
        if self.out == null {
            eprintln("(nothing captured)");
        } else {
            unsafe stdio::fputs(self.out, stdio::stderr());
        }
        eprintln("--- end of captured output ---");
        return false;
    }
    /// `exit == 0`, but it DUMPS what was captured when the answer is no: out_shows' sibling for
    /// exit codes: a remote crash otherwise reports nothing beyond the number.
    pub fn ok(self: &CliResult) bool {
        if self.exit == 0 {
            return true;
        }
        eprintln("--- expected exit 0, got {}; captured output follows ---", self.exit);
        if self.out == null {
            eprintln("(nothing captured)");
        } else {
            unsafe stdio::fputs(self.out, stdio::stderr());
        }
        eprintln("--- end of captured output ---");
        return false;
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

// Does the NUL-terminated `hay` contain `needle`? `needle` is a `str` (a VIEW with no terminator) so it
// is copied before it reaches C. Passing `needle.ptr()` to a C string function reads past its end until it
// finds a zero byte, which is exactly the kind of bug that only shows up on one platform.
pub fn contains_str(hay: *const char, needle: str) bool {
    if hay == null {
        return false;
    }
    let mut nb = Cmd8192 {};
    unsafe stdio::snprintf(&mut nb[0], 8192, "%.*s".ptr() as *const char, needle.len() as i32, needle.ptr());
    return unsafe cstring::strstr(hay, &nb[0]) != null;
}

// True on Windows: the executable suffix, the default C compiler and a few path habits differ there.
/// True when the host platform is Windows.
pub fn on_windows() bool {
    return unsafe shim::sc_host_platform() == 0;
}

// $SUPERC, or the built compiler beside the CWD when unset (gen1 for the self-hosted check). Resolved to an
// ABSOLUTE path: Windows' CreateProcess does not take a `./`-relative program the way a POSIX shell does.
fn superc() *const char {
    // Process-local: the runner forks one process per test, so this resolve-once cache is never shared.
    if unsafe SUPERC_RESOLVED[0] != 0 as char {
        return &unsafe SUPERC_RESOLVED[0];
    }
    let sc = stdlib::getenv("SUPERC");
    let mut want = Path512 {};
    if sc == null || unsafe *sc == 0 as char {
        unsafe stdio::snprintf(
            &mut want[0],
            512,
            "./super-c%s".ptr() as *const char,
            if on_windows() {
                ".exe".ptr() as *const char;
            } else {
                "".ptr() as *const char;
            },
        );
    } else {
        unsafe stdio::snprintf(&mut want[0], 512, "%s".ptr() as *const char, sc);
    }
    let slot = ((&mut unsafe SUPERC_RESOLVED) as *mut Path512) as *mut char;
    if unsafe shim::sc_realpath(&want[0], slot) == null {
        unsafe stdio::snprintf(slot, 512, "%s".ptr() as *const char, &want[0]);
    }
    return slot;
}

// The compiler under test, as an absolute path: what a test needs when it builds its own command line.
/// Path of the compiler under test (SC_TEST_SUPERC, else the binary beside the test runner).
pub fn superc_path() str<'static> {
    return str::from_cstr(superc());
}

// The C compiler for the emitted trees: $CC, else `cc` (POSIX) / `gcc` (mingw ships no `cc`).
/// The C compiler name: $CC, else `cc`.
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
    return exec_env(basecmd, outpath, null);
}

// `exec`, with `env` ("NAME=VALUE" pairs, space separated) applied to the child only.
fn exec_env(basecmd: *const char, outpath: *const char, env: *const char) CliResult {
    let rc = unsafe shim::sc_run(basecmd, null, outpath, null, env);
    let mut r = CliResult { exit: rc, out: null };
    r.out = slurp(outpath);
    return r;
}

// Run a command with its output discarded and return its exit code: the escape hatch for the few checks
// that drive a C compiler or a helper binary directly.
/// Run `cmd` shell-free with all output discarded; its exit code.
pub fn run_quiet(cmd: *const char) i32 {
    return unsafe shim::sc_run(cmd, null, null, null, null);
}

// Run a command with stdin, stdout and stderr each bound to a file (null: nothing / discarded). What the
// LSP tests need, and the one shape a shell would have written as `< in > out 2> err`.
/// Run `cmd` shell-free with stdin/stdout/stderr redirected to the given paths (null = discard/none).
pub fn run_io(cmd: *const char, in_path: *const char, out_path: *const char, err_path: *const char) i32 {
    return unsafe shim::sc_run(cmd, in_path, out_path, err_path, null);
}

// A temp project root with helpers to write a source tree, compile it, and cc+run the emitted build/ tree.
/// A scratch project directory (its absolute path, NUL-terminated).
pub type Proj = Array<char, 256>;

/// A fresh empty scratch project under the system temp directory, named by pid.
pub fn proj_new() Proj {
    // Process-local: one forked process per test, and the name carries the pid.
    unsafe C_SEQ = unsafe C_SEQ + 1;
    let pid = unsafe shim::sc_getpid();
    let mut p = Proj {};
    unsafe stdio::snprintf(
        &mut p[0],
        256,
        "%s/sccli_%d_%llu".ptr() as *const char,
        unsafe shim::sc_tmpdir(),
        pid,
        unsafe C_SEQ,
    );
    let _ = unsafe shim::sc_mkdir_p(&p[0]);
    return p;
}

extend Proj {
    /// The project root as a C string.
    pub const fn rootp(self: &Proj) *const char {
        return &self[0];
    }

    // Write <root>/rel (creating parent dirs); rel may contain a subdirectory (e.g. "lib/lib.spc").
    /// Write `content` to `rel` under the root, creating directories.
    pub fn mkfile(self: &Proj, rel: str, content: str) {
        let mut dir = Path512 {};
        unsafe stdio::snprintf(
            &mut dir[0],
            512,
            "%s/%.*s".ptr() as *const char,
            self.rootp(),
            rel.len() as i32,
            rel.ptr(),
        );
        // Everything up to the last separator is the directory to create.
        let mut cut: i32 = -1;
        let mut i: i32 = 0;
        while dir[i as usize] != 0 as char {
            if dir[i as usize] == '/' as char || dir[i as usize] == '\\' as char {
                cut = i;
            }
            i = i + 1;
        }
        if cut > 0 {
            dir[cut as usize] = 0 as char;
            let _ = unsafe shim::sc_mkdir_p(&dir[0]);
        }
        let mut path = Path512 {};
        unsafe stdio::snprintf(
            &mut path[0],
            512,
            "%s/%.*s".ptr() as *const char,
            self.rootp(),
            rel.len() as i32,
            rel.ptr(),
        );
        let f = stdio::fopen(str::from_cstr(&path[0]), "wb"); // binary: no Windows CRLF in emitted test files
        if f != null {
            if content.len() > 0 {
                let _ = unsafe stdio::fwrite(content.ptr(), 1, content.len(), f);
            }
            unsafe stdio::fclose(f);
        }
    }

    // Copy a repository file into this isolated project. This keeps large end-to-end fixtures in
    // normal source files instead of duplicating them inside matchertext literals.
    /// Copy `source` to `rel` under the root; false on failure.
    pub fn copyfile(self: &Proj, rel: str, source: str) bool {
        let mut path = Path512 {};
        unsafe stdio::snprintf(&mut path[0], 512, "%.*s".ptr() as *const char, source.len() as i32, source.ptr());
        let content = slurp(&path[0]);
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
        let mut base = Cmd8192 {};
        unsafe stdio::snprintf(
            &mut base[0],
            8192,
            "\"%s\" %.*s \"%s/%.*s\"".ptr() as *const char,
            superc(),
            flags.len() as i32,
            flags.ptr(),
            self.rootp(),
            mainrel.len() as i32,
            mainrel.ptr(),
        );
        let mut op = Path512 {};
        unsafe stdio::snprintf(&mut op[0], 512, "%s/.out".ptr() as *const char, self.rootp());
        return exec(&base[0], &op[0]);
    }

    /// Run the compiler on `mainrel`, capturing output.
    pub fn compile(self: &Proj, mainrel: str) CliResult {
        return self.compile_flags("", mainrel);
    }

    // Run `$SUPERC <args>` verbatim (for flag-only invocations like usage checks); no path is appended.
    /// Run the compiler with `args` verbatim from the project root, capturing output.
    pub fn run_raw(self: &Proj, args: str) CliResult {
        let mut base = Cmd8192 {};
        unsafe stdio::snprintf(
            &mut base[0],
            8192,
            "\"%s\" %.*s".ptr() as *const char,
            superc(),
            args.len() as i32,
            args.ptr(),
        );
        let mut op = Path512 {};
        unsafe stdio::snprintf(&mut op[0], 512, "%s/.out".ptr() as *const char, self.rootp());
        return exec(&base[0], &op[0]);
    }

    // Append every `*.c` under `dir` (recursively) to `out`, each double-quoted: the `find` a shell
    // command would run. Doing it here keeps the command shell-free, and a shell-free command is
    // the same command on Windows.
    fn append_c_files(self: &Proj, dir: *const char, out: *mut char, cap: usize) {
        let d = unsafe shim::sc_opendir(dir);
        if d == null {
            return;
        }
        loop {
            let e = unsafe shim::sc_readdir(d);
            if e == null {
                break;
            }
            let nm = unsafe shim::sc_dirent_name(e);
            if unsafe cstring::strcmp(nm, ".".ptr() as *const char) == 0 || unsafe cstring::strcmp(
                nm,
                "..".ptr() as *const char,
            ) == 0 {
                continue;
            }
            let mut child = Path512 {};
            unsafe stdio::snprintf(&mut child[0], 512, "%s/%s".ptr() as *const char, dir, nm);
            if unsafe shim::sc_stat_isdir(&child[0]) == 1 {
                self.append_c_files(&child[0], out, cap);
                continue;
            }
            let dot = unsafe cstring::strrchr(nm, '.');
            if dot == null || unsafe cstring::strcmp(dot, ".c".ptr() as *const char) != 0 {
                continue;
            }
            let used = unsafe cstring::strlen(out);
            unsafe stdio::snprintf(out + used, cap - used, " \"%s\"".ptr() as *const char, &child[0]);
        }
        let _ = unsafe shim::sc_closedir(d);
    }

    // The `@c.link` flags the emit wrote to build/raw/__ldflags, space separated (empty when there are
    // none): the `cat` a shell command would run.
    fn append_ldflags(self: &Proj, out: *mut char, cap: usize) {
        let mut path = Path512 {};
        unsafe stdio::snprintf(&mut path[0], 512, "%s/build/raw/__ldflags".ptr() as *const char, self.rootp());
        let buf = slurp(&path[0]);
        if buf == null {
            return;
        }
        let mut i: usize = 0;
        while unsafe buf[i] != 0 as char {
            if unsafe buf[i] == '\n' as char {
                unsafe buf[i] = ' ' as char;
            }
            i = i + 1;
        }
        let used = unsafe cstring::strlen(out);
        unsafe stdio::snprintf(out + used, cap - used, " %s".ptr() as *const char, buf);
        unsafe stdlib::free(buf);
    }

    // Cc the whole emitted build/ tree -Werror (plus any `extra` flags and @c.link __ldflags) into
    // <root>/bin. `strict` adds -Wall -Wextra -Werror; without it this is the plain build (the analog of
    // cli_test's `cc -std=c11`, where a tree containing @test functions compiles as an ordinary program).
    fn cc_tree(self: &Proj, extra: str, strict: bool) CliResult {
        let mut base = Cmd8192 {};
        unsafe stdio::snprintf(
            &mut base[0],
            8192,
            "%s %s%s".ptr() as *const char,
            cc_name(),
            cstd(),
            if strict {
                " -Wall -Wextra -Werror".ptr() as *const char;
            } else {
                "".ptr() as *const char;
            },
        );
        let mut raw = Path512 {};
        unsafe stdio::snprintf(&mut raw[0], 512, "%s/build/raw".ptr() as *const char, self.rootp());
        self.append_c_files(&raw[0], &mut base[0], 8192);
        let used = unsafe cstring::strlen(&base[0]);
        let tail = (&mut base[0]) as *mut char;
        unsafe stdio::snprintf(tail + used, 8192 - used, " %.*s".ptr() as *const char, extra.len() as i32, extra.ptr());
        self.append_ldflags(&mut base[0], 8192);
        let used2 = unsafe cstring::strlen(&base[0]);
        unsafe stdio::snprintf(
            tail + used2,
            8192 - used2,
            " -o \"%s/bin%s\"".ptr() as *const char,
            self.rootp(),
            binext(),
        );
        let mut op = Path512 {};
        unsafe stdio::snprintf(&mut op[0], 512, "%s/.ccout".ptr() as *const char, self.rootp());
        return exec(&base[0], &op[0]);
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
        let mut base = Path512 {};
        unsafe stdio::snprintf(&mut base[0], 512, "\"%s/bin%s\"".ptr() as *const char, self.rootp(), binext());
        let mut op = Path512 {};
        unsafe stdio::snprintf(&mut op[0], 512, "%s/.runout".ptr() as *const char, self.rootp());
        // `env` is a view too: copy it NUL-terminated before it crosses into C.
        let mut envb = Path512 {};
        unsafe stdio::snprintf(&mut envb[0], 512, "%.*s".ptr() as *const char, env.len() as i32, env.ptr());
        return exec_env(&base[0], &op[0], &envb[0]);
    }

    // Run the linked <root>/bin and return its exit code.
    /// Run the linked binary; its exit code.
    pub fn run_bin(self: &Proj) i32 {
        let mut base = Path512 {};
        unsafe stdio::snprintf(&mut base[0], 512, "\"%s/bin%s\"".ptr() as *const char, self.rootp(), binext());
        let mut op = Path512 {};
        unsafe stdio::snprintf(&mut op[0], 512, "%s/.runout".ptr() as *const char, self.rootp());
        let r = exec(&base[0], &op[0]);
        let e = r.exit;
        return e;
    }

    // True if the generated <root>/build/rel contains `needle` (the `grep -q` analog).
    /// True when generated file `rel` (under build/raw) contains `needle`.
    pub fn gen_has(self: &Proj, rel: str, needle: str) bool {
        let mut path = Path512 {};
        unsafe stdio::snprintf(
            &mut path[0],
            512,
            "%s/build/raw/%.*s".ptr() as *const char,
            self.rootp(),
            rel.len() as i32,
            rel.ptr(),
        );
        let buf = slurp(&path[0]);
        if buf == null {
            return false;
        }
        let found = contains_str(buf, needle);
        unsafe stdlib::free(buf);
        return found;
    }

    // How many entries under <root>/build/raw start with `prefix`: the `find ... | wc -l` analog, which
    // asserts that generated wrapper TUs are pruned.
    /// Number of entries under build/raw whose name starts with `prefix`.
    pub fn gen_count(self: &Proj, prefix: str) i32 {
        let mut raw = Path512 {};
        unsafe stdio::snprintf(&mut raw[0], 512, "%s/build/raw".ptr() as *const char, self.rootp());
        let d = unsafe shim::sc_opendir(&raw[0]);
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
    /// True when `rel` exists under build/raw.
    pub fn gen_exists(self: &Proj, rel: str) bool {
        let mut path = Path512 {};
        unsafe stdio::snprintf(
            &mut path[0],
            512,
            "%s/build/raw/%.*s".ptr() as *const char,
            self.rootp(),
            rel.len() as i32,
            rel.ptr(),
        );
        let f = stdio::fopen(str::from_cstr(&path[0]), "rb");
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

/// Run the compiler under test FROM `dir` with one environment variable set: the shape the global
/// object-cache tests need: the engine resolves build.toml from its working directory and the cache
/// from its environment. No shell syntax: Windows' sc_run hands the line to CreateProcess verbatim,
/// so the directory moves via chdir (safe: the runner gives every test its own process) and the
/// variable rides sc_run's env parameter. superc_path() resolves before the chdir moves ".".
pub fn superc_env_in(dir: str, key: str, val: str, args: str) CliResult {
    let mut cmd = String::new();
    cmd.format_into("\"{}\" {}", superc_path(), args);
    let mut env = String::new();
    env.format_into("{}={}", key, val);
    let mut op = String::new();
    op.format_into("{}/.envout", dir);
    let mut d = String::from_str(dir);
    if unsafe shim::sc_chdir(d.cstr()) != 0 {
        return CliResult { exit: -1, out: null };
    }
    return exec_env(cmd.cstr(), op.cstr(), env.cstr());
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
