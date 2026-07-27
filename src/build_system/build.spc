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
        unsafe shim::sc_unlink(p.cstr());
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
fn resolve_cc(m: &mf::Manifest) String {
    let mut cc = String::new();
    // ccache makes fixpoint rebuilds (bootstrap stage 2) nearly free
    let probe = if unsafe shim::sc_host_platform() == 0 {
        "ccache -V >nul 2>&1"; // cmd.exe has no /dev/null
    } else {
        "ccache -V >/dev/null 2>&1";
    };
    if shell(probe) == 0 {
        cc.push_str("ccache ");
    }
    if m.cc.len() != 0 {
        cc.push_string(&m.cc);
        return cc;
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
fn push_profile(cmd: &mut String, flags: &Vector<String>, target: i32) {
    for i in 0..flags.len() {
        let f = flags.at(i).as_str();
        if target == 0 && f.starts_with("-fsanitize") {
            continue;
        }
        cmd.push_byte(b' ');
        cmd.push_str(f);
    }
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

// Where a profile keeps its own copy of the manifest's binary: <out-dir>/<profile>/<name>. Each profile
// links its own, so a `dev` build can never end up standing in for the release artifact -- the manifest's
// `bin` is a copy INSTALLED from here, and only by the commands whose job is to produce it.
fn profile_bin(m: &mf::Manifest, prof_name: str) String {
    let dir = join2(m.out_dir.as_str(), prof_name);
    return join2(dir.as_str(), base_name(m.bin.as_str()));
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
pub fn resolve_profile<'a>(m: &'a mf::Manifest<'a>, cli: str<'a>) str<'a> {
    if cli.len() != 0 {
        return cli;
    }
    return m.default_profile.as_str();
}

// Build `root`'s closure with `prof_name`'s flags into <out-dir>/<sub>/{gen,obj}, linking `bin`;
// the transpiled C lands in <out-dir>/<raw> first.
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
) i32 {
    let pi = m.profile_index(prof_name);
    if pi < 0 {
        eprintln("build: unknown profile '{}'", prof_name);
        return 1;
    }
    let prof = m.profiles.at(pi as usize);
    let t0 = unsafe shim::sc_ticks_ms();

    // 1) transpile the closure to <out-dir>/<raw>
    let mut p = loader::package_load_rooted(root, root_dir, alt, std_dir, bootstrap_tags);
    if !p.ok {
        return 1;
    }
    let srcgen = join2(m.out_dir.as_str(), raw);
    p.gen_root = srcgen.clone();
    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, ce_steps, ce_mem);
    p.ceval = &mut ceval;
    let rc = run_package(&mut p, null, "", target, lint);
    if rc != 0 {
        return rc;
    }
    let t_transpile = unsafe shim::sc_ticks_ms();

    // 2) content-sync into <out-dir>/<sub>/gen (unchanged files keep their mtime -- the
    // staleness anchor); objects mirror it under <out-dir>/<sub>/obj.
    let pdir = join2(m.out_dir.as_str(), sub);
    let gen = join2(pdir.as_str(), "gen");
    let obj = join2(pdir.as_str(), "obj");
    mkdirs(gen.as_str());
    mkdirs(obj.as_str());
    let mut ret = sync_tree(srcgen.as_str(), gen.as_str());
    let t_sync = unsafe shim::sc_ticks_ms();
    let mut t_compile = t_sync;
    let mut t_link = t_sync;
    let mut total_c: usize = 0;
    let mut stale_n: usize = 0;
    let mut jobs: u32 = 0;
    let mut linked = false;

    if ret == 0 {
        // 3) compile stale objects: longest-first, wait-any worker pool
        let mut rels = Vector::<String>::new();
        walk_files(gen.as_str(), gen.len(), &mut rels);
        let cc = resolve_cc(m);
        let ccver = cc_version(&cc, pdir.as_str());
        jobs = if jobs_override != 0 {
            jobs_override;
        } else if m.jobs != 0 {
            m.jobs;
        } else {
            (unsafe shim::sc_ncpu()) as u32;
        };
        let mut objs = Vector::<String>::new();
        let mut pend = Vector::<Pend>::new();
        for i in 0..rels.len() {
            let rel = rels.at(i).as_str();
            if !rel.ends_with(".c") {
                continue;
            }
            total_c = total_c + 1;
            let mut cpath = join2(gen.as_str(), rel);
            let mut opath = join2(obj.as_str(), rel.slice(0, rel.len() - 2));
            opath.push_str(".o");
            let stem = opath.as_str().slice(0, opath.len() - 2);
            let mut dpath = String::from_str(stem);
            dpath.push_str(".d");
            let mut cmdpath = String::from_str(stem);
            cmdpath.push_str(".cmd");
            let mut cmd = cc.clone();
            cmd.push_byte(b' ');
            cmd.push_string(&m.cstd);
            push_all(&mut cmd, &m.cflags);
            push_profile(&mut cmd, &prof.cflags, target);
            cmd.push_str(" -MMD -c");
            push_quoted(&mut cmd, cpath.as_str());
            cmd.push_str(" -o");
            push_quoted(&mut cmd, opath.as_str());
            let mut fp = ccver.clone();
            fp.push_str(" | ");
            fp.push_string(&cmd);
            // an object is stale when a dependency is newer OR the command that produced it
            // (compiler version, flags, paths) is not the one we are about to run
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
                pend.push(Pend { cmd: cmd, fp: fp, log: log, cmdpath: cmdpath, prev_ms: prev_ms });
            }
            objs.push(opath.clone());
        }
        pend.sort_by(pend_cmp);
        stale_n = pend.len();
        let compiled = stale_n != 0;
        let mut window = Vector::<Job>::new();
        while pend.len() != 0 || window.len() != 0 {
            while pend.len() != 0 && window.len() as u32 < jobs {
                let mut w = pend.remove(0).unwrap();
                let pid = unsafe shim::sc_spawn(w.cmd.cstr());
                if pid < 0 {
                    eprintln("build: cannot spawn compiler");
                    ret = 1;
                    unsafe shim::sc_unlink(w.log.cstr());
                } else {
                    window.push(
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
            if window.len() == 0 {
                break;
            }
            let mut pids = Vector::<i64>::new();
            for i in 0..window.len() {
                pids.push(window.at(i).pid);
            }
            let mut code: i32 = 0;
            let idx = unsafe shim::sc_wait_any(&pids[0], window.len() as i32, &mut code);
            if idx < 0 {
                eprintln("build: wait failed");
                ret = 1;
                break;
            }
            let mut j = window.remove(idx as usize).unwrap();
            if finish_job(&mut j, code) != 0 {
                ret = 1;
            }
        }
        t_compile = unsafe shim::sc_ticks_ms();
        t_link = t_compile;

        // 4) link when anything changed: a fresh object, a missing/out-of-date binary, or a link
        // command (flags, libs, __ldflags, linker version) differing from the recorded one
        if ret == 0 {
            let mut binb = String::from_str(bin);
            let bmt = unsafe shim::sc_mtime(binb.cstr());
            let mut tmp = String::from_str(bin);
            tmp.push_str(".tmp");
            let mut cmd = cc.clone();
            cmd.push_str(" -o");
            push_quoted(&mut cmd, tmp.as_str());
            for i in 0..objs.len() {
                push_quoted(&mut cmd, objs.at(i).as_str());
            }
            push_all(&mut cmd, &m.ldflags);
            push_profile(&mut cmd, &prof.ldflags, target);
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
                        if prof.strip {
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
        return engine_build(
            m,
            prof_name,
            m.root.as_str(),
            dirname_of(m.root.as_str()),
            "",
            prof_name,
            "raw",
            bin_override,
            jobs_override,
            std_dir,
            ce_steps,
            ce_mem,
            target,
            bootstrap_tags,
            lint,
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
    return install_bin(path.as_str(), m.bin.as_str());
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
    let path = profile_bin(m, prof_name);
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
    let rc = if bin_override.len() != 0 {
        built = String::from_str(bin_override);
        engine_build(
            m,
            prof_name,
            m.root.as_str(),
            dirname_of(m.root.as_str()),
            "",
            prof_name,
            "raw",
            bin_override,
            jobs_override,
            std_dir,
            ce_steps,
            ce_mem,
            target,
            bootstrap_tags,
            lint,
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

/// `super-c test`: build the project, then discover tests/**/*.spc by convention, synthesize an
/// aggregating root, and run the @test pipeline on it (SUPERC points at the fresh binary).
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
    if unsafe shim::sc_stat_isdir("tests".ptr() as *const char) != 1 {
        eprintln("test: no tests/ directory next to src/");
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
    walk_files("tests", 5, &mut rels);
    rels.sort_by(name_cmp);
    let mut src = String::new();
    src.push_str("// generated by `super-c test` -- do not edit\n");
    let mut n = 0;
    for i in 0..rels.len() {
        let rel = rels.at(i).as_str();
        if !rel.ends_with(".spc") {
            continue;
        }
        src.push_str("import tests::");
        let stem = rel.slice(0, rel.len() - 4);
        for k in 0..stem.len() {
            if stem[k] == b'/' {
                src.push_str("::");
            } else {
                src.push_byte(stem[k]);
            }
        }
        src.push_str(";\n");
        n = n + 1;
    }
    if n == 0 {
        eprintln("test: no .spc files under tests/");
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
    let mut p = loader::package_load_rooted(rootp.as_str(), ".", dirname_of(m.root.as_str()), std_dir, bootstrap_tags);
    if !p.ok {
        return 1;
    }
    p.gen_root = join2(m.out_dir.as_str(), "raw-test");
    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, ce_steps, ce_mem);
    p.ceval = &mut ceval;
    return run_package(&mut p, topts, "", target, false);
}

/// `super-c bench`: build bench/main.spc under the bench profile (by default) into
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
    let probe = stdio::fopen("bench/main.spc", "rb");
    if probe == null {
        eprintln("bench: no bench/main.spc next to src/");
        return 1;
    }
    unsafe stdio::fclose(probe);
    let rootp = "bench/main.spc";
    let prof_name = if profile.len() != 0 {
        profile;
    } else {
        "bench";
    };
    let sub = join2("bench", prof_name);
    let bin = join2(m.out_dir.as_str(), "bench-bin");
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
    // Nested `super-c` invocations inside the lines skip command overrides (SC_CMD).
    unsafe shim::sc_setenv("SC_CMD".ptr() as *const char, "1".ptr() as *const char);
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

/// A [command.NAME] entry shadows the built-in NAME subcommand -- unless we are already inside a
/// command's lines (SC_CMD), which is how the override's own nested `super-c build` reaches the
/// real engine.
pub fn command_overrides(m: &mf::Manifest, name: str) bool {
    if stdlib::getenv("SC_CMD") != null {
        return false;
    }
    return m.command_index(name) >= 0;
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
