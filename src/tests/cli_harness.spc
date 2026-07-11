// CLI test harness: drives $SUPERC as a subprocess over on-disk source trees -- the analog of
// tests/cli_test.c's run_cmd / write_file / mkfile. A `Proj` is a temp project root under /tmp; write a
// source tree into it with `mkfile`, compile it with `compile` (compile-only mode, which emits a build/
// tree next to the root file), then cc the emitted tree -Werror with `cc_build` and run it with `run_bin`.
// Generated C is inspected via `gen_has` / `gen_exists`. The compiler is $SUPERC (default "./super-c",
// matching the CWD=repo-root that `make selfhost-test` runs), so the suite dogfoods the self-hosted driver.
import stdio;
import stdlib;
import string as cstring;
import driver_shim as shim;

struct Path512 { pub b: [char; 512] }
struct Cmd8192 { pub b: [char; 8192] }

static mut C_SEQ: u64 = 0;

// The captured result of a subprocess: its exit code and combined stdout+stderr (`out`, owned).
pub struct CliResult { pub exit: i32, pub out: *mut char }

extend CliResult {
    pub fn out_has(self: &CliResult, needle: str) bool {
        if self.out == null {
            return false;
        }
        return unsafe cstring::strstr(self.out, needle.ptr() as *const char) != null;
    }
}
extend CliResult as Free {
    pub fn free(self: &mut Self) void {
        if self.out != null {
            unsafe stdlib::free(self.out as *mut void);
            self.out = null;
        }
    }
}

// $SUPERC, or "./super-c" when unset -- the compiler under test (may be gen1 for the self-hosted check).
fn superc() *const char {
    let mut sc = stdlib::getenv("SUPERC");
    if sc == null || (unsafe *sc) == (0 as char) {
        sc = "./super-c".ptr() as *const char;
    }
    return sc;
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
    let buf = unsafe stdlib::malloc((sz as usize) + 1) as *mut char;
    if buf == null {
        return null;
    }
    let got = unsafe stdio::fread(buf as *mut void, 1, sz as usize, f);
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

// Run `basecmd` with stdout+stderr redirected to `outpath`, capturing its exit code and that output.
fn exec(basecmd: *const char, outpath: *const char) CliResult {
    let mut full = Cmd8192 {};
    unsafe stdio::snprintf((&mut full.b[0]) as *mut char, 8192, "%s > '%s' 2>&1".ptr() as *const char, basecmd, outpath);
    let rc = stdlib::system(str::from_cstr((&full.b[0]) as *const char));
    let mut r = CliResult { exit: -1, out: null };
    if unsafe shim::sc_wifexited(rc) != 0 {
        r.exit = unsafe shim::sc_wexitstatus(rc);
    }
    r.out = slurp(outpath);
    return r;
}

// Run an arbitrary shell command (no capture) and return its exit code -- the escape hatch for the few
// checks that need a custom cc invocation or a `find`/`test` pipeline.
pub fn run_shell(cmd: *const char) i32 {
    let rc = stdlib::system(str::from_cstr(cmd));
    if unsafe shim::sc_wifexited(rc) != 0 {
        return unsafe shim::sc_wexitstatus(rc);
    }
    return -1;
}

// A temp project root with helpers to write a source tree, compile it, and cc+run the emitted build/ tree.
pub struct Proj { pub root: [char; 256] }

pub fn proj_new() Proj {
    unsafe C_SEQ = unsafe C_SEQ + 1;
    let pid = unsafe shim::sc_getpid();
    let mut p = Proj {};
    unsafe stdio::snprintf((&mut p.root[0]) as *mut char, 256, "/tmp/sccli_%d_%llu".ptr() as *const char, pid, unsafe C_SEQ);
    let _ = unsafe shim::sc_mkdir((&p.root[0]) as *const char);
    return p;
}

extend Proj {
    pub fn rootp(self: &Proj) *const char {
        return (&self.root[0]) as *const char;
    }

    // Write <root>/rel (creating parent dirs); rel may contain a subdirectory (e.g. "lib/lib.spc").
    pub fn mkfile(self: &Proj, rel: str, content: str) void {
        let mut cmd = Cmd8192 {};
        unsafe stdio::snprintf((&mut cmd.b[0]) as *mut char, 8192, "mkdir -p \"$(dirname '%s/%s')\"".ptr() as *const char, self.rootp(), rel.ptr() as *const char);
        let _ = stdlib::system(str::from_cstr((&cmd.b[0]) as *const char));
        let mut path = Path512 {};
        unsafe stdio::snprintf((&mut path.b[0]) as *mut char, 512, "%s/%s".ptr() as *const char, self.rootp(), rel.ptr() as *const char);
        let f = stdio::fopen(str::from_cstr((&path.b[0]) as *const char), "wb"); // binary: no Windows CRLF in emitted test files
        if f != null {
            if content.len() > 0 {
                let _ = unsafe stdio::fwrite(content.ptr(), 1, content.len(), f);
            }
            unsafe stdio::fclose(f);
        }
    }

    // Compile <root>/mainrel with the given extra flags (compile-only mode: emits <root>/build/, no link).
    pub fn compile_flags(self: &Proj, flags: str, mainrel: str) CliResult {
        let mut base = Cmd8192 {};
        unsafe stdio::snprintf((&mut base.b[0]) as *mut char, 8192, "%s %s '%s/%s'".ptr() as *const char, superc(), flags.ptr() as *const char, self.rootp(), mainrel.ptr() as *const char);
        let mut op = Path512 {};
        unsafe stdio::snprintf((&mut op.b[0]) as *mut char, 512, "%s/.out".ptr() as *const char, self.rootp());
        return exec((&base.b[0]) as *const char, (&op.b[0]) as *const char);
    }

    pub fn compile(self: &Proj, mainrel: str) CliResult {
        return self.compile_flags("", mainrel);
    }

    // Run `$SUPERC <args>` verbatim (for flag-only invocations like usage checks); no path is appended.
    pub fn run_raw(self: &Proj, args: str) CliResult {
        let mut base = Cmd8192 {};
        unsafe stdio::snprintf((&mut base.b[0]) as *mut char, 8192, "%s %s".ptr() as *const char, superc(), args.ptr() as *const char);
        let mut op = Path512 {};
        unsafe stdio::snprintf((&mut op.b[0]) as *mut char, 512, "%s/.out".ptr() as *const char, self.rootp());
        return exec((&base.b[0]) as *const char, (&op.b[0]) as *const char);
    }

    // cc the whole emitted build/ tree -Werror (plus any `extra` flags and @c.link __ldflags) into <root>/bin.
    pub fn cc_build(self: &Proj, extra: str) CliResult {
        let mut base = Cmd8192 {};
        unsafe stdio::snprintf((&mut base.b[0]) as *mut char, 8192,
            "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') %s $(cat '%s/build/__ldflags' 2>/dev/null) -o '%s/bin'".ptr() as *const char,
            self.rootp(), extra.ptr() as *const char, self.rootp(), self.rootp());
        let mut op = Path512 {};
        unsafe stdio::snprintf((&mut op.b[0]) as *mut char, 512, "%s/.ccout".ptr() as *const char, self.rootp());
        return exec((&base.b[0]) as *const char, (&op.b[0]) as *const char);
    }

    // cc the emitted tree WITHOUT -Werror (the analog of cli_test's plain `cc -std=c11` normal build, where
    // a tree containing @test functions is compiled as an ordinary program).
    pub fn cc_build_plain(self: &Proj, extra: str) CliResult {
        let mut base = Cmd8192 {};
        unsafe stdio::snprintf((&mut base.b[0]) as *mut char, 8192,
            "cc -std=c11 $(find '%s/build' -name '*.c') %s $(cat '%s/build/__ldflags' 2>/dev/null) -o '%s/bin'".ptr() as *const char,
            self.rootp(), extra.ptr() as *const char, self.rootp(), self.rootp());
        let mut op = Path512 {};
        unsafe stdio::snprintf((&mut op.b[0]) as *mut char, 512, "%s/.ccout".ptr() as *const char, self.rootp());
        return exec((&base.b[0]) as *const char, (&op.b[0]) as *const char);
    }

    // Run the linked <root>/bin and return its exit code.
    pub fn run_bin(self: &Proj) i32 {
        let mut base = Path512 {};
        unsafe stdio::snprintf((&mut base.b[0]) as *mut char, 512, "'%s/bin'".ptr() as *const char, self.rootp());
        let mut op = Path512 {};
        unsafe stdio::snprintf((&mut op.b[0]) as *mut char, 512, "%s/.runout".ptr() as *const char, self.rootp());
        let mut r = exec((&base.b[0]) as *const char, (&op.b[0]) as *const char);
        let e = r.exit;
        return e;
    }

    // True if the generated <root>/build/rel contains `needle` (the `grep -q` analog).
    pub fn gen_has(self: &Proj, rel: str, needle: str) bool {
        let mut path = Path512 {};
        unsafe stdio::snprintf((&mut path.b[0]) as *mut char, 512, "%s/build/%s".ptr() as *const char, self.rootp(), rel.ptr() as *const char);
        let buf = slurp((&path.b[0]) as *const char);
        if buf == null {
            return false;
        }
        let found = unsafe cstring::strstr(buf, needle.ptr() as *const char) != null;
        unsafe stdlib::free(buf as *mut void);
        return found;
    }

    // True if <root>/build/rel exists (the `access(.., F_OK)` analog).
    pub fn gen_exists(self: &Proj, rel: str) bool {
        let mut path = Path512 {};
        unsafe stdio::snprintf((&mut path.b[0]) as *mut char, 512, "%s/build/%s".ptr() as *const char, self.rootp(), rel.ptr() as *const char);
        let f = stdio::fopen(str::from_cstr((&path.b[0]) as *const char), "rb");
        if f == null {
            return false;
        }
        unsafe stdio::fclose(f);
        return true;
    }

    // Compile <root>/mainrel and assert a nonzero exit with a diagnostic containing `want` (expect_fail).
    pub fn expect_fail(self: &Proj, mainrel: str, want: str) void {
        let mut r = self.compile(mainrel);
        assert(r.exit != 0, "expected nonzero exit on a bad program");
        assert(r.out_has(want), "diagnostic missing expected text");
    }
}

extend Proj as Free {
    pub fn free(self: &mut Self) void {
        let mut cmd = Path512 {};
        unsafe stdio::snprintf((&mut cmd.b[0]) as *mut char, 512, "rm -rf '%s'".ptr() as *const char, self.rootp());
        let _ = stdlib::system(str::from_cstr((&cmd.b[0]) as *const char));
    }
}
