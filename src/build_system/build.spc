// build.toml engine: transpile the root's module closure into <out-dir>/raw, content-sync it into
// <out-dir>/<profile>/gen (unchanged files keep their mtime), compile stale objects in parallel with
// -MMD dep tracking into <out-dir>/<profile>/obj, link, then optionally strip. This is the Makefile's
// sync-generated.sh + compile-generated.mk moved in-process; `super-c run <cmd>` and `super-c clean`
// live here too.
import stdio;
import stdlib;
import string as cstring;
import driver_shim as shim;
import module::loader as loader;
import consteval::consteval as ce;
import driver::emit as *;
import driver::util as *;
import build_system::manifest as mf;

// ---------------------------------------------------------------------------------------------------------
// small path/process helpers
// ---------------------------------------------------------------------------------------------------------
fn join2(a: str, b: str) String {
    let mut s = String::with_capacity(a.len() + 1 + b.len());
    s.push_str(a);
    s.push_byte(b'/');
    s.push_str(b);
    return s;
}

fn mkdirs(path: str) {
    let mut acc = String::with_capacity(path.len());
    for i in 0..path.len() {
        if path[i] == b'/' && acc.len() != 0 {
            unsafe shim::sc_mkdir(acc.cstr());
        }
        acc.push_byte(path[i]);
    }
    if acc.len() != 0 {
        unsafe shim::sc_mkdir(acc.cstr());
    }
}

fn shell(cmd: str) i32 {
    let rc = stdlib::system(cmd);
    if unsafe shim::sc_wifexited(rc) != 0 {
        return unsafe shim::sc_wexitstatus(rc);
    }
    return if rc == 0 {
        0;
    } else {
        1;
    };
}

fn cat_file(path: str) {
    let f = stdio::fopen(path, "rb");
    if f == null {
        return;
    }
    let mut buf = Array::<char, 4096>::new();
    loop {
        let n = unsafe stdio::fread(&mut buf[0], 1, 4096, f);
        if n == 0 {
            break;
        }
        unsafe stdio::fwrite(&buf[0], 1, n, stdio::stderr());
    }
    unsafe stdio::fclose(f);
}

// Recursively collect regular files under dir as paths relative to `base` (no leading '/').
fn walk_files(dir: str, base_len: usize, out: &mut Vector<String>) {
    let mut d = String::from_str(dir);
    let dh = unsafe shim::sc_opendir(d.cstr());
    if dh == null {
        return;
    }
    loop {
        let e = unsafe shim::sc_readdir(dh);
        if e == null {
            break;
        }
        let nm = unsafe shim::sc_dirent_name(e);
        if unsafe nm[0] == '.' as char {
            continue;
        }
        let mut p = join2(dir, str::from_cstr(nm));
        if unsafe shim::sc_stat_isdir(p.cstr()) == 1 {
            walk_files(p.as_str(), base_len, out);
        } else {
            let full = p.as_str();
            out.push(String::from_str(full.slice(base_len + 1, full.len())));
        }
    }
    unsafe shim::sc_closedir(dh);
}

const fn name_cmp(a: &String, b: &String) i32 {
    let la = a.len();
    let lb = b.len();
    let mn = if la < lb {
        la;
    } else {
        lb;
    };
    let c = unsafe cstring::memcmp(a.as_str().ptr(), b.as_str().ptr(), mn);
    if c != 0 {
        return c;
    }
    return la as i32 - lb as i32;
}

fn contains(v: &Vector<String>, s: str) bool {
    for i in 0..v.len() {
        if v.at(i).as_str() == s {
            return true;
        }
    }
    return false;
}

/// Recursive delete (files then directories); silently ignores a missing path.
pub fn rm_rf(path: str) {
    let mut p = String::from_str(path);
    let isdir = unsafe shim::sc_stat_isdir(p.cstr());
    if isdir == 1 {
        let dh = unsafe shim::sc_opendir(p.cstr());
        if dh != null {
            let mut names = Vector::<String>::new();
            loop {
                let e = unsafe shim::sc_readdir(dh);
                if e == null {
                    break;
                }
                let nm = unsafe shim::sc_dirent_name(e);
                if unsafe nm[0] == '.' as char && (unsafe nm[1] == 0 as char || unsafe nm[1] == '.' as char && unsafe nm[2] == 0 as char) {
                    continue;
                }
                names.push(String::from_cstr(nm));
            }
            unsafe shim::sc_closedir(dh);
            for i in 0..names.len() {
                let c = join2(path, names.at(i).as_str());
                rm_rf(c.as_str());
            }
        }
        unsafe shim::sc_rmdir(p.cstr());
    } else if isdir == 0 {
        if unsafe shim::sc_unlink(p.cstr()) != 0 {
            // Read-only file (a vendored repository's git objects): make it writable and retry.
            let _ = unsafe shim::sc_chmod_rw(p.cstr());
            unsafe shim::sc_unlink(p.cstr());
        }
    }
}

// ---------------------------------------------------------------------------------------------------------
// content-sync: <root_dir>/build -> <out>/gen. Unchanged files keep their mtime (the staleness anchor);
// orphans in gen are deleted so removed modules do not linger in the link.
// ---------------------------------------------------------------------------------------------------------
fn file_eq(a: str, b: &String) bool {
    let cur = loader::read_file(a);
    if cur.is_none() {
        return false;
    }
    let c = cur.unwrap();
    let same = c.len() == b.len() && c.as_str() == b.as_str();
    return same;
}

fn sync_tree(srcdir: str, dstdir: str) i32 {
    let mut rels = Vector::<String>::new();
    walk_files(srcdir, srcdir.len(), &mut rels);
    for i in 0..rels.len() {
        let rel = rels.at(i).as_str();
        let sp = join2(srcdir, rel);
        let dp = join2(dstdir, rel);
        let content = loader::read_file(sp.as_str());
        if content.is_none() {
            eprintln("build: cannot read '{}'", sp.as_str());
            return 1;
        }
        let body = content.unwrap();
        if !file_eq(dp.as_str(), &body) {
            // ensure parent dirs, then write
            let full = dp.as_str();
            let mut k = full.len();
            while k > 0 && full[k - 1] != b'/' {
                k = k - 1;
            }
            if k > 0 {
                let dir = String::from_str(full.slice(0, k - 1));
                mkdirs(dir.as_str());
            }
            let f = stdio::fopen(dp.as_str(), "wb");
            if f == null {
                eprintln("build: cannot write '{}'", dp.as_str());
                return 1;
            }
            unsafe stdio::fwrite(body.as_str().ptr(), 1, body.len(), f);
            unsafe stdio::fclose(f);
        }
    }
    // drop orphans
    let mut old = Vector::<String>::new();
    walk_files(dstdir, dstdir.len(), &mut old);
    for i in 0..old.len() {
        if !contains(&rels, old.at(i).as_str()) {
            let mut dp = join2(dstdir, old.at(i).as_str());
            unsafe shim::sc_unlink(dp.cstr());
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------------------------------------
// staleness: obj missing, or any dependency in its -MMD .d file newer than the object
// ---------------------------------------------------------------------------------------------------------
fn obj_stale(cpath: &mut String, opath: &mut String, dpath: str) bool {
    let omt = unsafe shim::sc_mtime(opath.cstr());
    if omt == 0 {
        return true;
    }
    let dep = loader::read_file(dpath);
    if dep.is_none() {
        return unsafe shim::sc_mtime(cpath.cstr()) > omt;
    }
    let d = dep.unwrap();
    let s = d.as_str();
    // skip "target:" then walk whitespace-separated deps, ignoring line-continuation backslashes
    let mut i: usize = 0;
    while i < s.len() && s[i] != b':' {
        i = i + 1;
    }
    i = i + 1;
    let mut stale = false;
    while !stale && i < s.len() {
        while i < s.len() && (s[i] == b' ' || s[i] == b'\t' || s[i] == b'\n' || s[i] == b'\r' || s[i] == b'\\') {
            i = i + 1;
        }
        let st = i;
        while i < s.len() && s[i] != b' ' && s[i] != b'\t' && s[i] != b'\n' && s[i] != b'\r' && s[i] != b'\\' {
            i = i + 1;
        }
        if i > st {
            let mut dep_path = String::from_str(s.slice(st, i));
            let mt = unsafe shim::sc_mtime(dep_path.cstr());
            if mt == 0 || mt > omt {
                stale = true;
            }
        }
    }
    return stale;
}

// ---------------------------------------------------------------------------------------------------------
// the build itself
// ---------------------------------------------------------------------------------------------------------
// The compiler named by manifest/$CC/default, WITHOUT the ccache decision (that probe costs a
// shell round-trip, so the engine runs it in the background -- see CcStream::ensure_cc).
fn resolve_cc_raw(m: &mf::Manifest) String {
    let mut cc = String::new();
    if m.cc.len() != 0 {
        cc.push_string(&m.cc);
        return cc;
    }
    // A cross target picks its own toolchain: an explicit `cc` in the manifest still wins, but nothing
    // else can name these compilers, and $CC on the host would be the wrong one.
    if m.sdk != 0 {
        sdk_cc(m.sdk, &mut cc);
        if cc.len() != 0 {
            return cc;
        }
    }
    let env = stdlib::getenv("CC");
    if env != null && unsafe *env != 0 as char {
        cc.push_str(str::from_cstr(env));
        return cc;
    }
    cc.push_str("cc");
    return cc;
}

// Double quotes: understood by both sh (macOS/Linux) and cmd.exe (Windows _popen/system).
fn push_quoted(cmd: &mut String, s: str) {
    cmd.push_str(" \"");
    cmd.push_str(s);
    cmd.push_str("\"");
}

fn push_all(cmd: &mut String, flags: &Vector<String>) {
    for i in 0..flags.len() {
        cmd.push_byte(b' ');
        cmd.push_string(flags.at(i));
    }
}

// Profile flags, minus what the target cannot honour. mingw ships no libasan/libubsan, so the built-in
// dev/debug profiles' `-fsanitize*` would fail the link on Windows -- there they are dropped instead
// (SC_LEAK_CHECK, being self-hosted, still covers leaks, double-frees and use-after-free there).
fn push_profile(cmd: &mut String, flags: &Vector<String>, target: i32, sdk: i32) {
    for i in 0..flags.len() {
        let f = flags.at(i).as_str();
        // mingw ships no libasan/libubsan, and neither do the iOS, Android or wasm toolchains as used
        // here: the sanitizer flags would fail the link, so they are dropped (SC_LEAK_CHECK still works).
        if (target == 0 || sdk != 0) && f.starts_with("-fsanitize") {
            continue;
        }
        cmd.push_byte(b' ');
        cmd.push_str(f);
    }
}

/// The built-in flags for profile `name`, as one command-line fragment (cflags then ldflags), for a build
/// with no manifest to read them from -- `super-c release foo.spc`, which compiles and links in one command.
/// Empty for an unknown name, so an unrecognised `--profile=` degrades to the plain build rather than
/// failing. `target` drops what that target cannot honour, exactly as a manifest build does.
pub fn profile_flags(name: str, target: i32, sdk: i32) String {
    let mut out = String::new();
    if name.len() == 0 {
        return out;
    }
    let m = mf::builtins_only();
    let pi = m.profile_index(name);
    if pi >= 0 {
        let prof = m.profiles.at(pi as usize);
        push_profile(&mut out, &prof.cflags, target, sdk);
        push_profile(&mut out, &prof.ldflags, target, sdk);
    }
    return out;
}

fn write_file(path: str, body: str) i32 {
    let f = stdio::fopen(path, "wb");
    if f == null {
        return 1;
    }
    unsafe stdio::fwrite(body.ptr(), 1, body.len(), f);
    unsafe stdio::fclose(f);
    return 0;
}

// First line of `<cc> --version`: part of every command fingerprint so a toolchain upgrade
// invalidates objects whose sources and flags did not change.
fn cc_version(cc: &String, dir: str) String {
    let mut vf = join2(dir, ".ccver");
    let mut cmd = cc.clone();
    cmd.push_str(" --version >");
    push_quoted(&mut cmd, vf.as_str());
    cmd.push_str(
        if unsafe shim::sc_host_platform() == 0 {
            " 2>nul";
        } else {
            " 2>/dev/null";
        },
    );
    shell(cmd.as_str());
    let mut out = String::new();
    let v = loader::read_file(vf.as_str());
    unsafe shim::sc_unlink(vf.cstr());
    if !v.is_none() {
        let body = v.unwrap();
        let s = body.as_str();
        let mut e: usize = 0;
        while e < s.len() && s[e] != b'\n' && s[e] != b'\r' {
            e = e + 1;
        }
        out.push_str(s.slice(0, e));
    }
    return out;
}

// A stale translation unit waiting for a worker slot.
struct Pend {
    pub cmd: String, // full compile command, log redirection included
    pub fp: String, // fingerprint: cc version + the command driving the object
    pub log: String,
    pub cmdpath: String, // <obj>.cmd: fingerprint + last duration
    pub prev_ms: i64, // last recorded duration; longest-first scheduling shrinks the tail
}

extend Pend as Free {
    pub fn free(self: &mut Self) {
        self.cmd.free();
        self.fp.free();
        self.log.free();
        self.cmdpath.free();
    }
}

// Longest previous compile first, so the slowest unit never starts last.
const fn pend_cmp(a: &Pend, b: &Pend) i32 {
    return if b.prev_ms > a.prev_ms {
        1;
    } else if b.prev_ms < a.prev_ms {
        -1;
    } else {
        0;
    };
}

// One in-flight compile job: its child pid plus what to record/cleanup on completion.
struct Job {
    pub pid: i64,
    pub fp: String,
    pub log: String,
    pub cmdpath: String,
    pub start: i64,
}

extend Job as Free {
    pub fn free(self: &mut Self) {
        self.fp.free();
        self.log.free();
        self.cmdpath.free();
    }
}

// On success, persist fingerprint + duration; on failure, surface the captured compiler output.
fn finish_job(j: &mut Job, code: i32) i32 {
    if code != 0 {
        cat_file(j.log.as_str());
    } else {
        let rec = format("{}\n{}", j.fp.as_str(), unsafe shim::sc_ticks_ms() - j.start);
        write_file(j.cmdpath.as_str(), rec.as_str());
    }
    unsafe shim::sc_unlink(j.log.cstr());
    return code;
}

fn dirname_of(p: str) str {
    let mut k = p.len();
    while k > 0 && p[k - 1] != b'/' {
        k = k - 1;
    }
    if k == 0 {
        return ".";
    }
    return p.slice(0, k - 1);
}

// The last path component of `p`.
const fn base_name(p: str) str {
    let mut k = p.len();
    while k > 0 && p[k - 1] != b'/' {
        k = k - 1;
    }
    return p.slice(k, p.len());
}

/// The name a linked binary must actually have on `target`: Windows executables carry `.exe`, and nothing
/// supplies it for us -- the engine links to `<bin>.tmp` and renames, so the C compiler never sees a name
/// without an extension to append one to. An extensionless PE cannot even be started: CreateProcess appends
/// `.exe` to a name that has none and then fails to find it. `pub` because the driver names binaries too.
/// Platform artifact name for a library target: static -> lib<name>.a everywhere (mingw uses ar
/// archives too); shared -> <name>.dll (windows) / lib<name>.dylib (macos) / lib<name>.so (linux).
pub fn lib_file(name: str, shared: bool, target: i32) String {
    let mut s = String::new();
    if shared && target == 0 {
        s.push_str(name);
        s.push_str(".dll");
        return s;
    }
    s.push_str("lib");
    s.push_str(name);
    if !shared {
        s.push_str(".a");
    } else if is_darwin(target) {
        s.push_str(".dylib");
    } else {
        s.push_str(".so");
    }
    return s;
}

// macOS and iOS are one platform family for artifact shape (Mach-O, .dylib), even though they are
// separate `@platform` values.
pub const fn is_darwin(target: i32) bool {
    return target == 1 || target == 4;
}

pub fn exe_name(base: str, target: i32) String {
    let mut s = String::from_str(base);
    if target == 0 && !base.ends_with(".exe") {
        s.push_str(".exe");
    }
    return s;
}

// Where a profile keeps its own copy of the manifest's binary: <out-dir>/<profile>/<name>. Each profile
// links its own, so a `dev` build can never end up standing in for the release artifact -- the manifest's
// `bin` is a copy INSTALLED from here, and only by the commands whose job is to produce it.
fn profile_bin(m: &mf::Manifest, prof_name: str, target: i32) String {
    let dir = join2(m.out_dir.as_str(), prof_name);
    let leaf = exe_name(base_name(m.bin.as_str()), target);
    return join2(dir.as_str(), leaf.as_str());
}

// Copy the profile's binary to `to`, the path the manifest calls the project's binary. A copy rather than a
// move, so the profile keeps the file its next build compares against. Written beside the target and
// renamed onto it, never written over it: truncating an executable that is currently running corrupts the
// image the OS is still paging from, and sc_rename knows how to displace a running one on Windows.
fn install_bin(from: str, to: str) i32 {
    let src = stdio::fopen(from, "rb");
    if src == null {
        eprintln("build: cannot read '{}'", from);
        return 1;
    }
    let mut tmp = String::from_str(to);
    tmp.push_str(".tmp");
    let dst = stdio::fopen(tmp.as_str(), "wb");
    if dst == null {
        unsafe stdio::fclose(src);
        eprintln("build: cannot write '{}'", tmp.as_str());
        return 1;
    }
    let mut buf = Array::<char, 8192>::new();
    let mut ok = true;
    loop {
        let n = unsafe stdio::fread(&mut buf[0], 1, 8192, src);
        if n == 0 {
            break;
        }
        if unsafe stdio::fwrite(&buf[0], 1, n, dst) != n {
            ok = false;
            break;
        }
    }
    unsafe stdio::fclose(src);
    unsafe stdio::fclose(dst);
    let mut tob = String::from_str(to);
    if !ok {
        let _ = unsafe shim::sc_unlink(tmp.cstr());
        eprintln("build: cannot write '{}'", to);
        return 1;
    }
    let _ = unsafe shim::sc_chmod_exec(tmp.cstr());
    if unsafe shim::sc_rename(tmp.cstr(), tob.cstr()) != 0 {
        eprintln("build: cannot replace '{}'", to);
        return 1;
    }
    return 0;
}

/// Profile name to build with: the CLI `--profile` flag, else the manifest's default-profile.
pub const fn resolve_profile<'a>(m: &'a mf::Manifest<'a>, cli: str<'a>) str<'a> {
    if cli.len() != 0 {
        return cli;
    }
    return m.default_profile.as_str();
}

// The streaming compile pipeline: run_package's EmitSink feeds every finished output file here, so
// a TU is content-synced into gen/ and its compile job spawned while later TUs are still being
// emitted. The emit pass writes all headers before the first source, so a source's compile can
// never miss an include. Reaping in-flight jobs uses sc_try_wait only: the blocking sc_wait_any
// (waitpid(-1)) would steal the emit workers' exit statuses while they are alive.
struct CcStream {
    pub src_len: usize, // gen_root prefix; rel = path[src_len+1..]
    pub gen: String,
    pub obj: String,
    pub pdir: String,
    pub cc_raw: String, // compiler without the ccache decision (see ensure_cc)
    pub cc_tail: String, // " <cstd> <cflags> <profile cflags> -MMD -c"
    pub probe_pid: i64, // background ccache+version probe; -1 = resolve synchronously on demand
    pub ccver_path: String, // <pdir>/.ccver, the probe's output file
    pub cc: String, // full compiler command (ccache-prefixed when available); empty until ensure_cc
    pub cmd_prefix: String, // "<cc><cc_tail>"; empty until ensure_cc
    pub ccver: String,
    pub cc_ready: bool,
    pub jobs: u32,
    pub objs: Vector<String>,
    pub pend: Vector<Pend>,
    pub window: Vector<Job>,
    pub total_c: usize,
    pub stale_n: usize,
    pub ret: i32,
}

extend CcStream {
    // Finish compiler resolution: collect the background probe (ccache presence + `cc --version`
    // first line, ~50ms of shell round-trips that overlap the transpile), or run both
    // synchronously when no probe was spawned (Windows, or spawn failure). Idempotent; called
    // before the first compile command is built and again before the link line.
    pub fn ensure_cc(self: &mut Self) {
        if self.cc_ready {
            return;
        }
        self.cc_ready = true;
        let mut done = false;
        if self.probe_pid >= 0 {
            let mut code: i32 = 0;
            let _ = unsafe shim::sc_waitpid(self.probe_pid, &mut code);
            let v = loader::read_file(self.ccver_path.as_str());
            let mut vp = String::from_str(self.ccver_path.as_str());
            unsafe shim::sc_unlink(vp.cstr());
            if !v.is_none() {
                let body = v.unwrap();
                let s = body.as_str();
                // line 1: "1"/"0" ccache presence; line 2: the compiler's version line
                let mut e: usize = 0;
                while e < s.len() && s[e] != b'\n' {
                    e = e + 1;
                }
                if e < s.len() {
                    if s.slice(0, e) == "1" {
                        self.cc.push_str("ccache ");
                    }
                    self.cc.push_string(&self.cc_raw);
                    let v0 = e + 1;
                    let mut v1 = v0;
                    while v1 < s.len() && s[v1] != b'\n' && s[v1] != b'\r' {
                        v1 = v1 + 1;
                    }
                    self.ccver.push_str(s.slice(v0, v1));
                    done = true;
                }
            }
        }
        if !done {
            let probe = if unsafe shim::sc_host_platform() == 0 {
                "ccache -V >nul 2>&1"; // cmd.exe has no /dev/null
            } else {
                "ccache -V >/dev/null 2>&1";
            };
            if shell(probe) == 0 {
                self.cc.push_str("ccache ");
            }
            self.cc.push_string(&self.cc_raw);
            self.ccver = cc_version(&self.cc, self.pdir.as_str());
        }
        self.cmd_prefix = self.cc.clone();
        self.cmd_prefix.push_string(&self.cc_tail);
    }

    // Sync one finished file raw -> gen (byte-compare keeps the mtime anchor); a source also gets
    // its compile planned and the pool pumped.
    pub fn on_file(self: &mut Self, path: str, kind: i32) {
        let rel = path.slice(self.src_len + 1, path.len());
        let content = loader::read_file(path);
        if content.is_none() {
            eprintln("build: cannot read '{}'", path);
            self.ret = 1;
            return;
        }
        let body = content.unwrap();
        let dp = join2(self.gen.as_str(), rel);
        if !file_eq(dp.as_str(), &body) {
            let full = dp.as_str();
            let mut k = full.len();
            while k > 0 && full[k - 1] != b'/' {
                k = k - 1;
            }
            if k > 0 {
                let dir = String::from_str(full.slice(0, k - 1));
                mkdirs(dir.as_str());
            }
            let f = stdio::fopen(dp.as_str(), "wb");
            if f == null {
                eprintln("build: cannot write '{}'", dp.as_str());
                self.ret = 1;
                return;
            }
            unsafe stdio::fwrite(body.as_str().ptr(), 1, body.len(), f);
            unsafe stdio::fclose(f);
        }
        if kind != 1 {
            return;
        }
        self.plan_c(rel);
        self.pump();
    }

    // Staleness + command construction for one gen-relative .c; stale units join pend, every unit's
    // object joins the link list.
    pub fn plan_c(self: &mut Self, rel: str) {
        self.ensure_cc();
        self.total_c = self.total_c + 1;
        let mut cpath = join2(self.gen.as_str(), rel);
        let mut opath = join2(self.obj.as_str(), rel.slice(0, rel.len() - 2));
        opath.push_str(".o");
        let stem = opath.as_str().slice(0, opath.len() - 2);
        let mut dpath = String::from_str(stem);
        dpath.push_str(".d");
        let mut cmdpath = String::from_str(stem);
        cmdpath.push_str(".cmd");
        let mut cmd = self.cmd_prefix.clone();
        push_quoted(&mut cmd, cpath.as_str());
        cmd.push_str(" -o");
        push_quoted(&mut cmd, opath.as_str());
        let mut fp = self.ccver.clone();
        fp.push_str(" | ");
        fp.push_string(&cmd);
        let mut fp_ok = false;
        let mut prev_ms: i64 = 0;
        let old = loader::read_file(cmdpath.as_str());
        if !old.is_none() {
            let ob = old.unwrap();
            let s = ob.as_str();
            let mut e: usize = 0;
            while e < s.len() && s[e] != b'\n' {
                e = e + 1;
            }
            fp_ok = s.slice(0, e) == fp.as_str();
            if e < s.len() {
                let ms = s.slice(e + 1, s.len()).parse_i64();
                if !ms.is_none() {
                    prev_ms = ms.unwrap();
                }
            }
        }
        if !fp_ok || obj_stale(&mut cpath, &mut opath, dpath.as_str()) {
            let full = opath.as_str();
            let mut k = full.len();
            while k > 0 && full[k - 1] != b'/' {
                k = k - 1;
            }
            let dir = String::from_str(full.slice(0, k - 1));
            mkdirs(dir.as_str());
            let mut log = opath.clone();
            log.push_str(".log");
            cmd.push_str(" > \"");
            cmd.push_str(log.as_str());
            cmd.push_str("\" 2>&1");
            self.pend.push(Pend { cmd: cmd, fp: fp, log: log, cmdpath: cmdpath, prev_ms: prev_ms });
            self.stale_n = self.stale_n + 1;
        }
        self.objs.push(opath.clone());
    }

    // Fill free slots (longest-known-first) and reap whatever already exited; never blocks.
    pub fn pump(self: &mut Self) {
        loop {
            while self.window.len() != 0 {
                let mut pids = Vector::<i64>::new();
                for i in 0..self.window.len() {
                    pids.push(self.window.at(i).pid);
                }
                let mut code: i32 = 0;
                let idx = unsafe shim::sc_try_wait(&pids[0], self.window.len() as i32, &mut code);
                if idx < 0 {
                    break;
                }
                let mut j = self.window.remove(idx as usize).unwrap();
                if finish_job(&mut j, code) != 0 {
                    self.ret = 1;
                }
            }
            if self.pend.len() == 0 || self.window.len() as u32 >= self.jobs {
                break;
            }
            self.pend.sort_by(pend_cmp);
            let mut w = self.pend.remove(0).unwrap();
            let pid = unsafe shim::sc_spawn(w.cmd.cstr());
            if pid < 0 {
                eprintln("build: cannot spawn compiler");
                self.ret = 1;
                unsafe shim::sc_unlink(w.log.cstr());
            } else {
                self.window.push(
                    Job {
                        pid: pid,
                        fp: w.fp.clone(),
                        log: w.log.clone(),
                        cmdpath: w.cmdpath.clone(),
                        start: unsafe shim::sc_ticks_ms(),
                    },
                );
            }
        }
    }

    // Run everything left to completion (blocking): only called once the emit workers are gone, so
    // sc_wait_any's waitpid(-1) cannot reap anything but our compile jobs. `discard` abandons units
    // not yet started -- the error path, which still must reap what is in flight.
    pub fn drain(self: &mut Self, discard: bool) {
        if discard {
            self.pend.truncate(0);
        }
        while self.pend.len() != 0 || self.window.len() != 0 {
            while self.pend.len() != 0 && self.window.len() as u32 < self.jobs {
                self.pend.sort_by(pend_cmp);
                let mut w = self.pend.remove(0).unwrap();
                let pid = unsafe shim::sc_spawn(w.cmd.cstr());
                if pid < 0 {
                    eprintln("build: cannot spawn compiler");
                    self.ret = 1;
                    unsafe shim::sc_unlink(w.log.cstr());
                } else {
                    self.window.push(
                        Job {
                            pid: pid,
                            fp: w.fp.clone(),
                            log: w.log.clone(),
                            cmdpath: w.cmdpath.clone(),
                            start: unsafe shim::sc_ticks_ms(),
                        },
                    );
                }
            }
            if self.window.len() == 0 {
                break;
            }
            let mut pids = Vector::<i64>::new();
            for i in 0..self.window.len() {
                pids.push(self.window.at(i).pid);
            }
            let mut code: i32 = 0;
            let idx = unsafe shim::sc_wait_any(&pids[0], self.window.len() as i32, &mut code);
            if idx < 0 {
                eprintln("build: wait failed");
                self.ret = 1;
                break;
            }
            let mut j = self.window.remove(idx as usize).unwrap();
            if finish_job(&mut j, code) != 0 {
                self.ret = 1;
            }
        }
    }
}

fn stream_notify(ctx: *mut void, path: str, kind: i32) {
    let s = ctx as *mut CcStream;
    s.on_file(path, kind);
}

// Build `root`'s closure with `prof_name`'s flags into <out-dir>/<sub>/{gen,obj}, linking `bin`;
// the transpiled C lands in <out-dir>/<raw> first.
// link_kind: 0 = executable, 1 = static library (ar), 2 = shared library (cc -shared).
fn engine_build(
    m: &mf::Manifest,
    prof_name: str,
    root: str,
    root_dir: str,
    alt: str,
    sub: str,
    raw: str,
    bin: str,
    jobs_override: u32,
    std_dir: *const char,
    ce_steps: u32,
    ce_mem: u64,
    target: i32,
    bootstrap_tags: bool,
    lint: bool,
    link_kind: i32,
) i32 {
    let pi = m.profile_index(prof_name);
    if pi < 0 {
        eprintln("build: unknown profile '{}'", prof_name);
        return 1;
    }
    let prof = m.profiles.at(pi as usize);
    let t0 = unsafe shim::sc_ticks_ms();

    // Compile-side setup happens BEFORE the transpile: the EmitSink streams each finished TU into
    // the worker pool, overlapping cc with the remainder of the emit pass.
    let srcgen = join2(m.out_dir.as_str(), raw);
    let pdir = join2(m.out_dir.as_str(), sub);
    let gen = join2(pdir.as_str(), "gen");
    let obj = join2(pdir.as_str(), "obj");
    mkdirs(gen.as_str());
    mkdirs(obj.as_str());
    let jobs: u32 = if jobs_override != 0 {
        jobs_override;
    } else if m.jobs != 0 {
        m.jobs;
    } else {
        (unsafe shim::sc_ncpu()) as u32;
    };
    let cc_raw = resolve_cc_raw(m);
    let mut tail = String::new();
    tail.push_byte(b' ');
    tail.push_string(&m.cstd);
    if m.lib_shared && target != 0 {
        tail.push_str(" -fPIC"); // shared-library objects need it; harmless for the exe targets
    }
    push_sdk_flags(&mut tail, m.sdk, m.arch); // the cross triple comes first; manifest flags can override
    push_all(&mut tail, &m.cflags);
    push_profile(&mut tail, &prof.cflags, target, m.sdk);
    tail.push_str(" -MMD -c");
    // The ccache probe and `cc --version` cost ~50ms of shell round-trips; a background process
    // resolves both while the transpile runs (ensure_cc collects it at first use). POSIX only:
    // the compound command below is sh syntax, so Windows resolves synchronously on demand.
    let ccver_path = join2(pdir.as_str(), ".ccver");
    let mut probe_pid: i64 = -1;
    if unsafe shim::sc_host_platform() != 0 {
        let mut pc = String::from_str("{ ccache -V >/dev/null 2>&1 && echo 1 || echo 0; ");
        pc.push_string(&cc_raw);
        pc.push_str(" --version; } >");
        push_quoted(&mut pc, ccver_path.as_str());
        pc.push_str(" 2>/dev/null");
        probe_pid = unsafe shim::sc_spawn(pc.cstr());
    }
    let mut stream = CcStream {
        src_len: srcgen.len(),
        gen: gen.clone(),
        obj: obj.clone(),
        pdir: pdir.clone(),
        cc_raw: cc_raw,
        cc_tail: tail,
        probe_pid: probe_pid,
        ccver_path: ccver_path,
        cc: String::new(),
        cmd_prefix: String::new(),
        ccver: String::new(),
        cc_ready: false,
        jobs: jobs,
        objs: Vector::<String>::new(),
        pend: Vector::<Pend>::new(),
        window: Vector::<Job>::new(),
        total_c: 0,
        stale_n: 0,
        ret: 0,
    };
    let mut sink = EmitSink { ctx: &mut stream, notify: stream_notify };

    // 1) transpile the closure to <out-dir>/<raw>, streaming each finished TU into the pool
    let mut p = loader::package_load_rooted(root, root_dir, alt, std_dir, bootstrap_tags, target);
    p.arch = m.arch; // the instruction-set axis `@arch` gates on
    if !p.ok {
        return 1;
    }
    p.gen_root = srcgen.clone();
    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, ce_steps, ce_mem);
    p.ceval = &mut ceval;
    let rc = run_package(&mut p, null, "", target, lint, "", &mut sink, jobs);
    if rc != 0 {
        stream.drain(true); // reap what is in flight; abandon what has not started
        return rc;
    }
    let t_transpile = unsafe shim::sc_ticks_ms();

    // 2) whole-tree content-sync as the safety net: every file was already synced when its
    // notification arrived, so this is a byte-compare no-op that (a) unlinks gen/ orphans and
    // (b) surfaces anything the stream never heard about -- planned below off the directory walk.
    let mut ret = stream.ret;
    if ret == 0 {
        ret = sync_tree(srcgen.as_str(), gen.as_str());
    }
    let t_sync = unsafe shim::sc_ticks_ms();
    let mut t_compile = t_sync;
    let mut t_link = t_sync;
    let mut total_c: usize = 0;
    let mut stale_n: usize = 0;
    let mut linked = false;

    if ret == 0 {
        // 3) plan any .c the stream did not see (none expected), then run the pool dry
        let mut rels = Vector::<String>::new();
        walk_files(gen.as_str(), gen.len(), &mut rels);
        for i in 0..rels.len() {
            let rel = rels.at(i).as_str();
            if !rel.ends_with(".c") {
                continue;
            }
            let mut opath = join2(obj.as_str(), rel.slice(0, rel.len() - 2));
            opath.push_str(".o");
            if !contains(&stream.objs, opath.as_str()) {
                stream.plan_c(rel);
            }
        }
        stream.drain(false);
        stream.ensure_cc(); // a build with zero .c files never planned one; the link still needs cc
        let cc = stream.cc.clone();
        let ccver = stream.ccver.clone();
        total_c = stream.total_c;
        stale_n = stream.stale_n;
        ret = stream.ret;
        let compiled = stale_n != 0;
        // The link list is sorted so its order never depends on notification arrival order --
        // the link fingerprint embeds the full command.
        let mut objs = replace(&mut stream.objs, Vector::<String>::new());
        objs.sort_by(name_cmp);
        t_compile = unsafe shim::sc_ticks_ms();
        t_link = t_compile;

        // 4) link when anything changed: a fresh object, a missing/out-of-date binary, or a link
        // command (flags, libs, __ldflags, linker version) differing from the recorded one
        if ret == 0 {
            let mut binb = String::from_str(bin);
            let bmt = unsafe shim::sc_mtime(binb.cstr());
            let mut tmp = String::from_str(bin);
            tmp.push_str(".tmp");
            let mut cmd = String::new();
            if link_kind == 1 {
                // a static library is an archive: no link flags, no libs
                cmd.push_str("ar rcs");
                push_quoted(&mut cmd, tmp.as_str());
                for i in 0..objs.len() {
                    push_quoted(&mut cmd, objs.at(i).as_str());
                }
            } else {
                cmd = cc.clone();
                if link_kind == 2 {
                    cmd.push_str(" -shared");
                    if target != 0 {
                        cmd.push_str(" -fPIC");
                    }
                }
                cmd.push_str(" -o");
                push_quoted(&mut cmd, tmp.as_str());
                for i in 0..objs.len() {
                    push_quoted(&mut cmd, objs.at(i).as_str());
                }
                push_sdk_flags(&mut cmd, m.sdk, m.arch);
                push_sdk_libs(&mut cmd, m.sdk);
                push_all(&mut cmd, &m.ldflags);
                push_profile(&mut cmd, &prof.ldflags, target, m.sdk);
                // @c.link flags recorded by the emitter
                let lfp = join2(gen.as_str(), "__ldflags");
                let lf = loader::read_file(lfp.as_str());
                if !lf.is_none() {
                    let body = lf.unwrap();
                    let s = body.as_str();
                    let mut a: usize = 0;
                    for b in 0..s.len() {
                        if s[b] == b'\n' {
                            if b > a {
                                cmd.push_byte(b' ');
                                cmd.push_str(s.slice(a, b));
                            }
                            a = b + 1;
                        }
                    }
                }
                push_all(&mut cmd, &m.ldlibs);
            }
            let mut fp = ccver.clone();
            fp.push_str(" | ");
            fp.push_string(&cmd);
            if prof.strip {
                fp.push_str(" +strip");
            }
            // the fingerprint is per-binary and profile-agnostic (out-dir root): profiles share
            // bin paths, so a dev binary left behind by a release link must read as out of date
            let mut fpname = String::from_str("__link-");
            for i in 0..bin.len() {
                fpname.push_byte(
                    if bin[i] == b'/' {
                        b'_';
                    } else {
                        bin[i];
                    },
                );
            }
            fpname.push_str(".cmd");
            let fppath = join2(m.out_dir.as_str(), fpname.as_str());
            let mut need = compiled || bmt == 0;
            for i in 0..objs.len() {
                if !need && unsafe shim::sc_mtime((&mut objs[i]).cstr()) > bmt {
                    need = true;
                }
            }
            if !need {
                let old = loader::read_file(fppath.as_str());
                need = if old.is_none() {
                    true;
                } else {
                    let ob = old.unwrap();
                    ob.as_str() != fp.as_str();
                };
            }
            if need {
                linked = true;
                if shell(cmd.as_str()) != 0 {
                    ret = 1;
                } else {
                    if unsafe shim::sc_rename(tmp.cstr(), binb.cstr()) != 0 {
                        eprintln("build: cannot move '{}' into place", bin);
                        ret = 1;
                    } else {
                        if prof.strip && link_kind == 0 {
                            let mut st = String::from_str("strip");
                            push_quoted(&mut st, bin);
                            shell(st.as_str());
                        }
                        write_file(fppath.as_str(), fp.as_str());
                    }
                }
            }
            t_link = unsafe shim::sc_ticks_ms();
        }
    }
    if stdlib::getenv("SC_TIMINGS") != null {
        eprintln(
            "timings[{}->{}]: transpile {}ms | sync {}ms | compile {}ms ({}/{} stale, jobs={}) | link {}ms ({}) | total {}ms",
            prof_name,
            bin,
            t_transpile - t0,
            t_sync - t_transpile,
            t_compile - t_sync,
            stale_n,
            total_c,
            jobs,
            t_link - t_compile,
            if linked {
                "relinked";
            } else {
                "cached";
            },
            t_link - t0,
        );
    }
    return ret;
}

/// `super-c build` from build.toml: run the engine on the manifest's root under the resolved profile
/// (see `resolve_profile`), linking `bin_override` when non-empty, else the manifest's `bin`.
pub fn manifest_build(
    m: &mf::Manifest,
    profile: str,
    bin_override: str,
    jobs_override: u32,
    std_dir: *const char,
    ce_steps: u32,
    ce_mem: u64,
    target: i32,
    bootstrap_tags: bool,
    lint: bool,
) i32 {
    let prof_name = resolve_profile(m, profile);
    if bin_override.len() != 0 {
        // `-o` names an exact path: link straight there, no profile copy and nothing installed.
        let ob = exe_name(bin_override, target);
        return engine_build(
            m,
            prof_name,
            m.root.as_str(),
            dirname_of(m.root.as_str()),
            "",
            prof_name,
            "raw",
            ob.as_str(),
            jobs_override,
            std_dir,
            ce_steps,
            ce_mem,
            target,
            bootstrap_tags,
            lint,
            0,
        );
    }
    let mut path = String::new();
    let rc = build_into_profile(
        m,
        prof_name,
        jobs_override,
        std_dir,
        ce_steps,
        ce_mem,
        target,
        bootstrap_tags,
        lint,
        &mut path,
    );
    if rc != 0 {
        return rc;
    }
    let dest = exe_name(m.bin.as_str(), target);
    return install_bin(path.as_str(), dest.as_str());
}

// Build one named target through the engine into its own <out-dir>/<profile><suffix> tree (per-target
// gen/obj caches: different closures must not thrash one another's sync). `out` receives the artifact.
fn target_build(
    m: &mf::Manifest,
    prof_name: str,
    root: str,
    suffix: str,
    raw: str,
    leaf: str,
    link_kind: i32,
    jobs_override: u32,
    std_dir: *const char,
    ce_steps: u32,
    ce_mem: u64,
    target: i32,
    bootstrap_tags: bool,
    lint: bool,
    out: &mut String,
) i32 {
    let mut sub = String::from_str(prof_name);
    sub.push_str(suffix);
    let dir = join2(m.out_dir.as_str(), sub.as_str());
    let path = join2(dir.as_str(), leaf);
    let rc = engine_build(
        m,
        prof_name,
        root,
        dirname_of(m.root.as_str()),
        "",
        sub.as_str(),
        raw,
        path.as_str(),
        jobs_override,
        std_dir,
        ce_steps,
        ce_mem,
        target,
        bootstrap_tags,
        lint,
        link_kind,
    );
    *out = path;
    return rc;
}

/// `super-c build`/`release` over every manifest target (cargo-style): the [lib] section's static and/or
/// shared artifacts, the primary `bin` (installed onto the manifest's `bin` path), and each [bin.NAME].
/// `sel_bin`/`sel_lib` restrict to one target (`--bin=NAME` / `--lib`).
pub fn manifest_build_all(
    m: &mf::Manifest,
    profile: str,
    sel_bin: str,
    sel_lib: bool,
    jobs_override: u32,
    std_dir: *const char,
    ce_steps: u32,
    ce_mem: u64,
    target: i32,
    bootstrap_tags: bool,
    lint: bool,
) i32 {
    let prof_name = resolve_profile(m, profile);
    let selected = sel_bin.len() != 0 || sel_lib;
    let mut matched = false;
    if m.lib_name.len() != 0 && (!selected || sel_lib) {
        matched = true;
        if m.lib_static {
            let leaf = lib_file(m.lib_name.as_str(), false, target);
            let mut path = String::new();
            let rc = target_build(
                m,
                prof_name,
                m.lib_root.as_str(),
                "-lib",
                "raw-lib",
                leaf.as_str(),
                1,
                jobs_override,
                std_dir,
                ce_steps,
                ce_mem,
                target,
                bootstrap_tags,
                lint,
                &mut path,
            );
            if rc != 0 {
                return rc;
            }
            println("built {}", path.as_str());
        }
        if m.lib_shared {
            let leaf = lib_file(m.lib_name.as_str(), true, target);
            let mut path = String::new();
            let rc = target_build(
                m,
                prof_name,
                m.lib_root.as_str(),
                "-lib",
                "raw-lib",
                leaf.as_str(),
                2,
                jobs_override,
                std_dir,
                ce_steps,
                ce_mem,
                target,
                bootstrap_tags,
                false, // the static pass already linted this closure
                &mut path,
            );
            if rc != 0 {
                return rc;
            }
            println("built {}", path.as_str());
        }
    }
    if m.bin.len() != 0 && (!selected || sel_bin == m.bin.as_str()) {
        matched = true;
        let rc = manifest_build(m, profile, "", jobs_override, std_dir, ce_steps, ce_mem, target, bootstrap_tags, lint);
        if rc != 0 {
            return rc;
        }
    }
    for i in 0..m.bins.len() {
        let bt = m.bins.at(i);
        if selected && sel_bin != bt.name.as_str() {
            continue;
        }
        matched = true;
        let mut suffix = String::from_str("-bin-");
        suffix.push_string(&bt.name);
        let mut raw = String::from_str("raw-bin-");
        raw.push_string(&bt.name);
        let leaf = exe_name(bt.name.as_str(), target);
        let mut path = String::new();
        let rc = target_build(
            m,
            prof_name,
            bt.root.as_str(),
            suffix.as_str(),
            raw.as_str(),
            leaf.as_str(),
            0,
            jobs_override,
            std_dir,
            ce_steps,
            ce_mem,
            target,
            bootstrap_tags,
            lint,
            &mut path,
        );
        if rc != 0 {
            return rc;
        }
        println("built {}", path.as_str());
    }
    if !matched {
        if sel_lib {
            eprintln("build: this manifest declares no [lib] target");
        } else {
            eprintln("build: no target named '{}' (check `bin` and [bin.NAME] sections)", sel_bin);
        }
        return 1;
    }
    return 0;
}

/// Scaffold a project in `dir` named `name` (cargo new/init): build.toml, src/main.spc, .gitignore,
/// and a best-effort `git init` when no repository is present. Refuses to overwrite an existing manifest.
pub fn scaffold_project(dir: str, name: str) i32 {
    let man = join2(dir, "build.toml");
    let probe = stdio::fopen(man.as_str(), "rb");
    if probe != null {
        unsafe stdio::fclose(probe);
        eprintln("init: '{}' already exists", man.as_str());
        return 1;
    }
    let srcdir = join2(dir, "src");
    mkdirs(srcdir.as_str());
    let mut toml = String::new();
    toml.push_str("bin = \"");
    toml.push_str(name);
    toml.push_str("\"\nroot = \"src/main.spc\"\n");
    if write_file(man.as_str(), toml.as_str()) != 0 {
        eprintln("init: cannot write '{}'", man.as_str());
        return 1;
    }
    let mainp = join2(srcdir.as_str(), "main.spc");
    let mut mains = String::new();
    mains.push_str("fn main() i32 {\n    println(\"Hello from ");
    mains.push_str(name);
    mains.push_str("!\");\n    return 0;\n}\n");
    if write_file(mainp.as_str(), mains.as_str()) != 0 {
        eprintln("init: cannot write '{}'", mainp.as_str());
        return 1;
    }
    let gi = join2(dir, ".gitignore");
    let gprobe = stdio::fopen(gi.as_str(), "rb");
    if gprobe != null {
        unsafe stdio::fclose(gprobe);
    } else {
        let _ = write_file(gi.as_str(), "/build\n");
    }
    let gitdir = join2(dir, ".git");
    let mut gd = gitdir.clone();
    if unsafe shim::sc_stat_isdir(gd.cstr()) != 1 {
        let mut cmd = String::from_str("git init -q");
        push_quoted(&mut cmd, dir);
        let _ = shell(cmd.as_str()); // best-effort: no git, no repository, no error
    }
    println("created {} project at {}", name, dir);
    return 0;
}

// Byte-for-byte file copy, streamed: read_file would also work for source text, but a vendored tree
// can carry anything (test fixtures, images), so nothing here may assume text.
fn copy_file(srcp: str, dstp: str) i32 {
    let fi = stdio::fopen(srcp, "rb");
    if fi == null {
        return 1;
    }
    let fo = stdio::fopen(dstp, "wb");
    if fo == null {
        unsafe stdio::fclose(fi);
        return 1;
    }
    let mut buf = Array::<char, 4096>::new();
    let mut rc = 0;
    loop {
        let n = unsafe stdio::fread(&mut buf[0], 1, 4096, fi);
        if n == 0 {
            break;
        }
        if unsafe stdio::fwrite(&buf[0], 1, n, fo) != n {
            rc = 1;
            break;
        }
    }
    unsafe stdio::fclose(fi);
    unsafe stdio::fclose(fo);
    return rc;
}

/// Recursive directory copy. Any `.git` entry is dropped AT EVERY LEVEL: vendored source belongs to
/// the project's own history, and a nested repository (the dependency's, or a submodule's) would be
/// invisible to -- and shadow files from -- the repository the project lives in.
fn copy_tree(srcd: str, dstd: str) i32 {
    mkdirs(dstd);
    let mut sp = String::from_str(srcd);
    let dh = unsafe shim::sc_opendir(sp.cstr());
    if dh == null {
        return 1;
    }
    let mut names = Vector::<String>::new();
    loop {
        let e = unsafe shim::sc_readdir(dh);
        if e == null {
            break;
        }
        let nm = unsafe shim::sc_dirent_name(e);
        let s = str::from_cstr(nm);
        if s == "." || s == ".." || s == ".git" {
            continue;
        }
        names.push(String::from_str(s));
    }
    unsafe shim::sc_closedir(dh);
    let mut rc = 0;
    for i in 0..names.len() {
        let s = join2(srcd, names.at(i).as_str());
        let d = join2(dstd, names.at(i).as_str());
        let mut sc = s.clone();
        if unsafe shim::sc_stat_isdir(sc.cstr()) == 1 {
            if copy_tree(s.as_str(), d.as_str()) != 0 {
                rc = 1;
            }
        } else if copy_file(s.as_str(), d.as_str()) != 0 {
            rc = 1;
        }
    }
    return rc;
}

/// `super-c vendor <src> [name]`: copy a dependency's source into `<root>/vendor/<name>`, where the
/// module loader already resolves it -- `import vendor::<name>::<module>;` -- so vendoring records
/// nothing in the manifest. A git source (a scheme, a `git@` remote, or a `.git` suffix) is cloned;
/// anything else must be a local directory and is copied. No `.git` survives either way.
pub fn vendor_dep(root: str, src: str, name_arg: str) i32 {
    let mut base = src;
    if base.ends_with(".git") {
        base = base.slice(0, base.len() - 4);
    }
    while base.len() > 0 && base[base.len() - 1] == b'/' {
        base = base.slice(0, base.len() - 1);
    }
    let mut k = base.len();
    while k > 0 && base[k - 1] != b'/' && base[k - 1] != b':' {
        k = k - 1;
    }
    let name = if name_arg.len() != 0 {
        name_arg;
    } else {
        base.slice(k, base.len());
    };
    if name.len() == 0 {
        eprintln("vendor: cannot derive a name from '{}' (name one: super-c vendor <src> <name>)", src);
        return 1;
    }
    let vdir = join2(root, "vendor");
    let dest = join2(vdir.as_str(), name);
    let mut dp = dest.clone();
    if unsafe shim::sc_stat_isdir(dp.cstr()) == 1 {
        eprintln("vendor: '{}' already exists (remove it to vendor again)", dest.as_str());
        return 1;
    }
    let is_git = src.starts_with("git@") || src.ends_with(".git") || scheme_len(src) != 0;
    mkdirs(vdir.as_str());
    if is_git {
        let mut cmd = String::from_str("git clone -q");
        push_quoted(&mut cmd, src);
        push_quoted(&mut cmd, dest.as_str());
        if shell(cmd.as_str()) != 0 {
            eprintln("vendor: git clone failed for '{}'", src);
            return 1;
        }
        let g = join2(dest.as_str(), ".git");
        rm_rf(g.as_str());
    } else {
        let mut sp = String::from_str(src);
        if unsafe shim::sc_stat_isdir(sp.cstr()) != 1 {
            eprintln("vendor: '{}' is not a directory (a git source needs a scheme, git@, or .git)", src);
            return 1;
        }
        if copy_tree(src, dest.as_str()) != 0 {
            eprintln("vendor: copy failed for '{}'", src);
            rm_rf(dest.as_str());
            return 1;
        }
    }
    println("vendored {} at {} (import vendor::{}::<module>;)", name, dest.as_str(), name);
    return 0;
}

// Length of a URL scheme prefix ("https://...") including the separator, 0 when there is none.
fn scheme_len(s: str) usize {
    for i in 0..s.len() {
        let c = s[i];
        if c == b':' {
            if i + 2 < s.len() && s[i + 1] == b'/' && s[i + 2] == b'/' {
                return i + 3;
            }
            return 0;
        }
        if !(c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9' || c == b'+' || c == b'-' || c == b'.') {
            return 0;
        }
    }
    return 0;
}

// Build the manifest's binary for `prof_name` into that profile's own directory; `out` receives its path.
// Nothing is installed: the commands whose job is to PRODUCE the project binary (build, release) copy it
// into place afterwards, and the ones that merely need to run it (test, run) use it where it lies -- which
// is what keeps a `test` run from quietly leaving a dev binary where a release one was.
fn build_into_profile(
    m: &mf::Manifest,
    prof_name: str,
    jobs_override: u32,
    std_dir: *const char,
    ce_steps: u32,
    ce_mem: u64,
    target: i32,
    bootstrap_tags: bool,
    lint: bool,
    out: &mut String,
) i32 {
    let path = profile_bin(m, prof_name, target);
    let rc = engine_build(
        m,
        prof_name,
        m.root.as_str(),
        dirname_of(m.root.as_str()),
        "",
        prof_name,
        "raw",
        path.as_str(),
        jobs_override,
        std_dir,
        ce_steps,
        ce_mem,
        target,
        bootstrap_tags,
        lint,
        0,
    );
    *out = path;
    return rc;
}

/// `super-c run`: build the manifest binary (like `manifest_build`), then execute it (cargo run).
/// Returns the build's failure code, or the binary's exit code. The binary is `bin_override` if
/// given, else the manifest's `bin`; a bare name is run cwd-relative (`./bin`), never through PATH.
pub fn manifest_run_bin(
    m: &mf::Manifest,
    profile: str,
    bin_override: str,
    sel_bin: str,
    jobs_override: u32,
    std_dir: *const char,
    ce_steps: u32,
    ce_mem: u64,
    target: i32,
    bootstrap_tags: bool,
    lint: bool,
) i32 {
    let prof_name = resolve_profile(m, profile);
    let mut built = String::new();
    if sel_bin.len() != 0 && sel_bin != m.bin.as_str() {
        // `run --bin=NAME`: build and execute that [bin.NAME] target
        let mut bi: i64 = -1;
        for i in 0..m.bins.len() {
            if m.bins.at(i).name.as_str() == sel_bin {
                bi = i as i64;
            }
        }
        if bi < 0 {
            eprintln("run: no binary target named '{}'", sel_bin);
            return 1;
        }
        let bt = m.bins.at(bi as usize);
        let mut suffix = String::from_str("-bin-");
        suffix.push_string(&bt.name);
        let mut raw = String::from_str("raw-bin-");
        raw.push_string(&bt.name);
        let leaf = exe_name(bt.name.as_str(), target);
        let mut path = String::new();
        let trc = target_build(
            m,
            prof_name,
            bt.root.as_str(),
            suffix.as_str(),
            raw.as_str(),
            leaf.as_str(),
            0,
            jobs_override,
            std_dir,
            ce_steps,
            ce_mem,
            target,
            bootstrap_tags,
            lint,
            &mut path,
        );
        if trc != 0 {
            return trc;
        }
        let mut cmd0 = String::new();
        push_quoted(&mut cmd0, path.as_str());
        return unsafe shim::sc_exec(cmd0.cstr());
    }
    let rc = if bin_override.len() != 0 {
        built = exe_name(bin_override, target);
        engine_build(
            m,
            prof_name,
            m.root.as_str(),
            dirname_of(m.root.as_str()),
            "",
            prof_name,
            "raw",
            built.as_str(),
            jobs_override,
            std_dir,
            ce_steps,
            ce_mem,
            target,
            bootstrap_tags,
            lint,
            0,
        );
    } else {
        // Run the profile's own binary where it was linked; `run` builds to run, it does not install.
        build_into_profile(
            m,
            prof_name,
            jobs_override,
            std_dir,
            ce_steps,
            ce_mem,
            target,
            bootstrap_tags,
            lint,
            &mut built,
        );
    };
    if rc != 0 {
        return rc;
    }
    let mut path = String::new();
    if built.as_str().find_byte(b'/') < 0 {
        path.push_str("./");
    }
    path.push_string(&built);
    let mut cmd = String::new();
    push_quoted(&mut cmd, path.as_str());
    return unsafe shim::sc_exec(cmd.cstr()); // a built binary: never through a shell (see sc_exec)
}

/// `super-c test`: build the project, then discover <test-dir>/**/*.spc (default tests/), synthesize
/// an aggregating root, and run the @test pipeline on it (SUPERC points at the fresh binary).
pub fn manifest_test(
    m: &mf::Manifest,
    profile: str,
    jobs_override: u32,
    topts: *const TestOpts,
    std_dir: *const char,
    ce_steps: u32,
    ce_mem: u64,
    target: i32,
    bootstrap_tags: bool,
) i32 {
    let mut tdir = m.test_dir.clone();
    if unsafe shim::sc_stat_isdir(tdir.cstr()) != 1 {
        eprintln("test: no {}/ directory next to src/", tdir.as_str());
        return 1;
    }
    // The profile's own binary, left where it was linked: `test` must not stand in for `build`, or a run of
    // the suite would replace whatever the manifest's binary currently is (a release artifact, say).
    let prof_name = resolve_profile(m, profile);
    let mut binp = String::new();
    let rc = build_into_profile(
        m,
        prof_name,
        jobs_override,
        std_dir,
        ce_steps,
        ce_mem,
        target,
        bootstrap_tags,
        false,
        &mut binp,
    );
    if rc != 0 {
        return rc;
    }
    let mut rels = Vector::<String>::new();
    walk_files(tdir.as_str(), tdir.len(), &mut rels);
    rels.sort_by(name_cmp);
    let mut src = String::new();
    src.push_str("// generated by `super-c test` -- do not edit\n");
    let mut n = 0;
    for i in 0..rels.len() {
        let rel = rels.at(i).as_str();
        if !rel.ends_with(".spc") {
            continue;
        }
        src.push_str("import ");
        push_module_path(&mut src, tdir.as_str());
        src.push_str("::");
        push_module_path(&mut src, rel.slice(0, rel.len() - 4));
        src.push_str(";\n");
        n = n + 1;
    }
    if n == 0 {
        eprintln("test: no .spc files under {}/", tdir.as_str());
        return 1;
    }
    src.push_str("\nfn main() i32 {\n    return 0;\n}\n");
    mkdirs(m.out_dir.as_str());
    let rootp = join2(m.out_dir.as_str(), "test_root.spc");
    let f = stdio::fopen(rootp.as_str(), "wb");
    if f == null {
        eprintln("test: cannot write '{}'", rootp.as_str());
        return 1;
    }
    unsafe stdio::fwrite(src.as_str().ptr(), 1, src.len(), f);
    unsafe stdio::fclose(f);
    // the harness compiles+runs snippets through the binary we just built ("./" so it never
    // resolves through PATH when the bin name is bare)
    let mut binb = String::new();
    if binp.as_str().find_byte(b'/') < 0 {
        binb.push_str("./");
    }
    binb.push_string(&binp);
    unsafe shim::sc_setenv("SUPERC".ptr() as *const char, binb.cstr());
    let mut p = loader::package_load_rooted(
        rootp.as_str(),
        ".",
        dirname_of(m.root.as_str()),
        std_dir,
        bootstrap_tags,
        target,
    );
    p.arch = m.arch;
    if !p.ok {
        return 1;
    }
    p.gen_root = join2(m.out_dir.as_str(), "raw-test");
    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, ce_steps, ce_mem);
    p.ceval = &mut ceval;
    return run_package(
        &mut p,
        topts,
        "",
        target,
        false,
        "",
        null,
        if jobs_override != 0 {
            jobs_override;
        } else {
            m.jobs;
        },
    );
}

// Every .spc under <bench-dir>, as `import <bench-dir>::<path>;` lines. Returns how many were found.
// This is the same convention `super-c test` uses: a file is part of the suite because of where it lives.
fn bench_import_root(bdir: str, out: &mut String) usize {
    let mut rels = Vector::<String>::new();
    walk_files(bdir, bdir.len(), &mut rels);
    rels.sort_by(name_cmp);
    out.push_str("// generated by `super-c bench` -- do not edit\n");
    let mut n: usize = 0;
    for i in 0..rels.len() {
        let rel = rels.at(i).as_str();
        if !rel.ends_with(".spc") {
            continue;
        }
        out.push_str("import ");
        push_module_path(out, bdir);
        out.push_str("::");
        push_module_path(out, rel.slice(0, rel.len() - 4));
        out.push_str(";\n");
        n = n + 1;
    }
    return n;
}

// "a/b" -> "a::b", the module path a file's location implies.
fn push_module_path(out: &mut String, stem: str) {
    for k in 0..stem.len() {
        if stem[k] == b'/' {
            out.push_str("::");
        } else {
            out.push_byte(stem[k]);
        }
    }
}

// Load the import-only root and collect every `@bench` function as "<module path>::<name>". Parsing is all
// this needs -- an attribute is recorded by the parser -- so nothing here resolves or typechecks.
fn bench_collect(
    rootp: str,
    prefix: str,
    src_dir: str,
    std_dir: *const char,
    bootstrap_tags: bool,
    target: i32,
    out: &mut Vector<String>,
) bool {
    let p = loader::package_load_rooted(rootp, ".", src_dir, std_dir, bootstrap_tags, target);
    if !p.ok {
        return false;
    }
    let n = p.modules.len();
    for m in 0..n {
        if !p.modules[m].has_ast || p.modules[m].prelude {
            continue;
        }
        let mid = m as ModuleId;
        let path = p.modules[m].path.as_str();
        if !path.starts_with(prefix) {
            continue; // the generated root itself, and anything it pulled in from elsewhere
        }
        let src = p.modules[m].source.as_str();
        let a = mod_ast_c(&p, mid);
        let nattr = unsafe a.attrs.len();
        for ai in 0..nattr {
            let at = unsafe a.attrs[ai];
            if at.kind != AttrKind::ATTR_BENCH as u8 {
                continue;
            }
            let fnode = a.at_const(at.owner);
            if fnode.kind != NodeKind::NODE_FUNCTION {
                continue; // the parser already reported this
            }
            if !fnode.as_data.function.is_public {
                let sp = fnode.span;
                eprintln(
                    "bench: '@bench' function at {}:{} must be 'pub' -- the generated runner calls it from another module",
                    path,
                    sp.start,
                );
                return false;
            }
            let nm = a.at_const(fnode.as_data.function.name).as_data.name.text;
            let mut entry = String::new();
            if at.arg != 0 {
                entry.push_byte(b'-'); // `@bench(log_results = false)`: it prints for itself
            }
            entry.push_str(path);
            entry.push_str("::");
            entry.push_str(src.slice(nm.start as usize, nm.end as usize));
            out.push(entry);
        }
    }
    return true;
}

// The real root: a `main` that runs each discovered benchmark in turn. It imports only the modules that
// actually contributed one -- NOT everything under bench/ -- so a file that merely lives there (a helper, or
// a standalone comparison program with a `main` of its own) is never linked into the runner. Anything a
// benchmark genuinely needs arrives through that benchmark's own imports.
fn bench_run_root(found: &Vector<String>, prefix: str, out: &mut String) {
    out.push_str("// generated by `super-c bench` -- do not edit\n");
    let mut seen = Vector::<String>::new();
    for i in 0..found.len() {
        let raw = found.at(i).as_str();
        let full = if raw[0] == b'-' {
            raw.slice(1, raw.len());
        } else {
            raw;
        };
        let mut cut: usize = 0;
        for k in 0..full.len() {
            if k + 1 < full.len() && full[k] == b':' && full[k + 1] == b':' {
                cut = k;
            }
        }
        if cut == 0 {
            continue;
        }
        let modpath = full.slice(0, cut);
        if contains(&seen, modpath) {
            continue;
        }
        seen.push(String::from_str(modpath));
        out.push_str("import ");
        out.push_str(modpath);
        out.push_str(";\n");
    }

    out.push_str("import std::testing::bench as __bench;\n");
    // Unconditional, because a benchmark that launches anything leaves the scheduler and its pooled stacks
    // behind and the runner is what owns the exit. Both are no-ops when nothing ever started them, so the
    // cost of naming them here is a link edge, not work at run time.
    out.push_str("import std::parallel::runtime as __rt;\n");
    out.push_str("import std::parallel::blocking as __blk;\n\nfn main() i32 {\n    __bench::begin();\n");
    for i in 0..found.len() {
        let raw = found.at(i).as_str();
        let quiet = raw[0] == b'-';
        let full = if quiet {
            raw.slice(1, raw.len());
        } else {
            raw;
        };
        out.push_str("    {\n        let mut b = __bench::Bencher::new(\"");
        // The `<bench-dir>::` every one of these starts with says nothing: strip it from the name.
        out.push_str(
            if full.starts_with(prefix) {
                full.slice(prefix.len(), full.len());
            } else {
                full;
            },
        );
        out.push_str("\");\n        ");
        out.push_str(full);
        out.push_str("(&mut b);\n");
        if !quiet {
            out.push_str("        b.report();\n");
        }
        out.push_str("        b.free();\n    }\n");
    }
    // The blocking pool has threads of its own that `__rt::shutdown` does not join, so it goes first.
    out.push_str("    __blk::shutdown();\n    __rt::shutdown();\n    return __bench::end(");
    out.push_i64(found.len() as i64);
    out.push_str(");\n}\n");
}

/// `super-c bench`: discover `@bench` functions under <bench-dir> (default bench/), build a runner
/// for them under the bench profile (by default) into
/// <out-dir>/bench-bin and run it (skipped when `no_run`).
pub fn manifest_bench(
    m: &mf::Manifest,
    profile: str,
    no_run: bool,
    jobs_override: u32,
    std_dir: *const char,
    ce_steps: u32,
    ce_mem: u64,
    target: i32,
    bootstrap_tags: bool,
) i32 {
    let mut bdir = m.bench_dir.clone();
    if unsafe shim::sc_stat_isdir(bdir.cstr()) != 1 {
        eprintln("bench: no {}/ directory next to src/", bdir.as_str());
        return 1;
    }
    // the module-path prefix the discovery root gives every bench module ("<bench-dir>::")
    let mut bpref = String::new();
    push_module_path(&mut bpref, bdir.as_str());
    bpref.push_str("::");
    // Two passes, because a benchmark is DISCOVERED rather than registered. The first root imports every
    // module under bench/ so they all get parsed; walking those ASTs for `@bench` gives the list; the second
    // root is written with a call to each one. Loading twice is cheap -- the first pass only parses -- and it
    // is what keeps a bench file from having to be wired into a hand-maintained `main`.
    let mut listing = String::new();
    let nmods = bench_import_root(bdir.as_str(), &mut listing);
    if nmods == 0 {
        eprintln("bench: no .spc files under {}/", bdir.as_str());
        return 1;
    }
    mkdirs(m.out_dir.as_str());
    let scanp = join2(m.out_dir.as_str(), "bench_scan.spc");
    if write_file(scanp.as_str(), listing.as_str()) != 0 {
        eprintln("bench: cannot write '{}'", scanp.as_str());
        return 1;
    }
    let mut found = Vector::<String>::new();
    if !bench_collect(
        scanp.as_str(),
        bpref.as_str(),
        dirname_of(m.root.as_str()),
        std_dir,
        bootstrap_tags,
        target,
        &mut found,
    ) {
        return 1;
    }
    if found.len() == 0 {
        eprintln("bench: no '@bench' functions under {}/", bdir.as_str());
        return 1;
    }
    let mut rootsrc = String::new();
    bench_run_root(&found, bpref.as_str(), &mut rootsrc);
    let genp = join2(m.out_dir.as_str(), "bench_root.spc");
    if write_file(genp.as_str(), rootsrc.as_str()) != 0 {
        eprintln("bench: cannot write '{}'", genp.as_str());
        return 1;
    }
    let rootp = genp.as_str();
    let prof_name = if profile.len() != 0 {
        profile;
    } else {
        "bench";
    };
    let sub = join2("bench", prof_name);
    // Bound, not inlined: a `str` taken from a TEMPORARY String dangles the moment the statement ends, and
    // a short name lives inside the String itself, so the borrow points at a dead stack slot.
    let leaf = exe_name("bench-bin", target);
    let bin = join2(m.out_dir.as_str(), leaf.as_str());
    // rooted at the project root (like tests), so `import bench::x;` works for lint AND build
    let rc = engine_build(
        m,
        prof_name,
        rootp,
        ".",
        dirname_of(m.root.as_str()),
        sub.as_str(),
        "raw-bench",
        bin.as_str(),
        jobs_override,
        std_dir,
        ce_steps,
        ce_mem,
        target,
        bootstrap_tags,
        false,
        0,
    );
    if rc != 0 || no_run {
        return rc;
    }
    let mut cmd = String::new();
    push_quoted(&mut cmd, bin.as_str());
    return unsafe shim::sc_exec(cmd.cstr()); // a built binary: never through a shell (see sc_exec)
}

/// `super-c run <name>`: run a manifest command, building first when it asks for it. Lines run in
/// order; the first nonzero exit stops and is returned.
pub fn manifest_run(
    m: &mf::Manifest,
    name: str,
    profile: str,
    jobs_override: u32,
    std_dir: *const char,
    ce_steps: u32,
    ce_mem: u64,
    target: i32,
    bootstrap_tags: bool,
    lint: bool,
) i32 {
    let ci = m.command_index(name);
    if ci < 0 {
        eprintln("run: no command '{}' in build.toml", name);
        return 1;
    }
    let c = m.commands.at(ci as usize);
    if c.needs_build {
        let rc = manifest_build(m, profile, "", jobs_override, std_dir, ce_steps, ce_mem, target, bootstrap_tags, lint);
        if rc != 0 {
            return rc;
        }
    }
    for i in 0..c.run.len() {
        let mut cmd = String::new();
        for e in 0..c.env_k.len() {
            cmd.push_string(c.env_k.at(e));
            cmd.push_str("='");
            cmd.push_string(c.env_v.at(e));
            cmd.push_str("' ");
        }
        cmd.push_string(c.run.at(i));
        let rc = shell(cmd.as_str());
        if rc != 0 {
            return rc;
        }
    }
    return 0;
}

/// `super-c clean`: drop the manifest's outputs -- out-dir (raw*/ + per-profile gen/obj) plus the
/// trees bare `super-c <root.spc>` invocations and pre-raw layouts left next to the sources.
pub fn manifest_clean(m: &mf::Manifest) i32 {
    rm_rf(m.out_dir.as_str());
    let b = join2(dirname_of(m.root.as_str()), "build");
    rm_rf(b.as_str());
    rm_rf("bench/build");
    rm_rf("build");
    return 0;
}
