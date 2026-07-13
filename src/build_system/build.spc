// build.toml engine: transpile the root's module closure, content-sync the emitted C into
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
        let n = unsafe stdio::fread((&mut buf[0]) as *mut void, 1, 4096, f);
        if n == 0 {
            break;
        }
        unsafe stdio::fwrite((&buf[0]) as *const void, 1, n, stdio::stderr());
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

fn contains(v: &Vector<String>, s: str) bool {
    for i in 0..v.len() {
        if v.at(i).as_str() == s {
            return true;
        }
    }
    return false;
}

// Recursive delete (files then directories); silently ignores a missing path.
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
                let mut c = join2(path, names.at(i).as_str());
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
    let mut c = cur.unwrap();
    let same = c.len() == b.len() && c.as_str() == b.as_str();
    return same;
}

fn sync_tree(srcdir: str, dstdir: str) i32 {
    let mut rels = Vector::<String>::new();
    walk_files(srcdir, srcdir.len(), &mut rels);
    for i in 0..rels.len() {
        let rel = rels.at(i).as_str();
        let mut sp = join2(srcdir, rel);
        let mut dp = join2(dstdir, rel);
        let content = loader::read_file(sp.as_str());
        if content.is_none() {
            eprintln("build: cannot read '{}'", sp.as_str());
            return 1;
        }
        let mut body = content.unwrap();
        if !file_eq(dp.as_str(), &body) {
            // ensure parent dirs, then write
            let full = dp.as_str();
            let mut k = full.len();
            while k > 0 && full[k - 1] != b'/' {
                k = k - 1;
            }
            if k > 0 {
                let mut dir = String::from_str(full.slice(0, k - 1));
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
    let mut d = dep.unwrap();
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
    if shell("ccache -V >/dev/null 2>&1") == 0 {
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

fn push_quoted(cmd: &mut String, s: str) {
    cmd.push_str(" '");
    cmd.push_str(s);
    cmd.push_str("'");
}

fn push_all(cmd: &mut String, flags: &Vector<String>) {
    for i in 0..flags.len() {
        cmd.push_byte(b' ');
        cmd.push_string(flags.at(i));
    }
}

// One in-flight compile job: its popen handle plus what to report/cleanup on completion.
struct Job {
    pub h: *mut void,
    pub log: String,
}

fn drain_job(j: &mut Job) i32 {
    let rc = unsafe shim::sc_pclose(j.h);
    if rc != 0 {
        cat_file(j.log.as_str());
    }
    unsafe shim::sc_unlink(j.log.cstr());
    return rc;
}

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
    let prof_name = if profile.len() != 0 {
        profile;
    } else {
        m.default_profile.as_str();
    };
    let pi = m.profile_index(prof_name);
    if pi < 0 {
        eprintln("build: unknown profile '{}'", prof_name);
        return 1;
    }
    let prof = m.profiles.at(pi as usize);
    let bin = if bin_override.len() != 0 {
        bin_override;
    } else {
        m.bin.as_str();
    };

    // 1) transpile the closure to <root_dir>/build
    let mut p = loader::package_load(m.root.as_str(), std_dir, bootstrap_tags);
    if !p.ok {
        return 1;
    }
    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, ce_steps, ce_mem);
    p.ceval = &mut ceval;
    let rc = run_package(&mut p, null, "", target, lint);
    let mut root_dir = p.root_dir.clone();
    if rc != 0 {
        return rc;
    }

    // 2) content-sync into <out-dir>/<profile>/gen (unchanged files keep their mtime -- the
    // staleness anchor); objects mirror it under <out-dir>/<profile>/obj.
    let mut pdir = join2(m.out_dir.as_str(), prof_name);
    let mut gen = join2(pdir.as_str(), "gen");
    let mut obj = join2(pdir.as_str(), "obj");
    let mut srcgen = join2(root_dir.as_str(), "build");
    mkdirs(gen.as_str());
    mkdirs(obj.as_str());
    let mut ret = sync_tree(srcgen.as_str(), gen.as_str());

    if ret == 0 {
        // 3) compile stale objects, window-parallel
        let mut rels = Vector::<String>::new();
        walk_files(gen.as_str(), gen.len(), &mut rels);
        let cc = resolve_cc(m);
        let jobs = if jobs_override != 0 {
            jobs_override;
        } else if m.jobs != 0 {
            m.jobs;
        } else {
            (unsafe shim::sc_ncpu()) as u32;
        };
        let mut objs = Vector::<String>::new();
        let mut window = Vector::<Job>::new();
        let mut compiled = false;
        for i in 0..rels.len() {
            let rel = rels.at(i).as_str();
            if !rel.ends_with(".c") {
                continue;
            }
            let mut cpath = join2(gen.as_str(), rel);
            let mut opath = join2(obj.as_str(), rel.slice(0, rel.len() - 2));
            opath.push_str(".o");
            let mut dpath = String::from_str(opath.as_str().slice(0, opath.len() - 2));
            dpath.push_str(".d");
            if obj_stale(&mut cpath, &mut opath, dpath.as_str()) {
                let full = opath.as_str();
                let mut k = full.len();
                while k > 0 && full[k - 1] != b'/' {
                    k = k - 1;
                }
                let mut dir = String::from_str(full.slice(0, k - 1));
                mkdirs(dir.as_str());
                print("  CC    {}\n", rel);
                let mut log = opath.clone();
                log.push_str(".log");
                let mut cmd = cc.clone();
                cmd.push_byte(b' ');
                cmd.push_string(&m.cstd);
                push_all(&mut cmd, &m.cflags);
                push_all(&mut cmd, &prof.cflags);
                cmd.push_str(" -MMD -c");
                push_quoted(&mut cmd, cpath.as_str());
                cmd.push_str(" -o");
                push_quoted(&mut cmd, opath.as_str());
                cmd.push_str(" > '");
                cmd.push_str(log.as_str());
                cmd.push_str("' 2>&1");
                if window.len() as u32 >= jobs {
                    let mut j0 = window.remove(0).unwrap();
                    if drain_job(&mut j0) != 0 {
                        ret = 1;
                    }
                }
                let h = unsafe shim::sc_popen(cmd.cstr());
                if h == null {
                    eprintln("build: cannot spawn compiler");
                    ret = 1;
                } else {
                    window.push(Job { h: h, log: log });
                }
                compiled = true;
            }
            objs.push(opath.clone());
        }
        while window.len() != 0 {
            let mut j0 = window.remove(0).unwrap();
            if drain_job(&mut j0) != 0 {
                ret = 1;
            }
        }

        // 4) link when anything changed (or the binary is missing/older than its objects)
        if ret == 0 {
            let mut binb = String::from_str(bin);
            let bmt = unsafe shim::sc_mtime(binb.cstr());
            let mut need = compiled || bmt == 0;
            for i in 0..objs.len() {
                if !need && unsafe shim::sc_mtime((&mut objs[i]).cstr()) > bmt {
                    need = true;
                }
            }
            if need {
                print("  LINK  {}\n", bin);
                let mut tmp = String::from_str(bin);
                tmp.push_str(".tmp");
                let mut cmd = cc.clone();
                cmd.push_str(" -o");
                push_quoted(&mut cmd, tmp.as_str());
                for i in 0..objs.len() {
                    push_quoted(&mut cmd, objs.at(i).as_str());
                }
                push_all(&mut cmd, &m.ldflags);
                push_all(&mut cmd, &prof.ldflags);
                // @c.link flags recorded by the emitter
                let mut lfp = join2(gen.as_str(), "__ldflags");
                let lf = loader::read_file(lfp.as_str());
                if !lf.is_none() {
                    let mut body = lf.unwrap();
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
                if shell(cmd.as_str()) != 0 {
                    ret = 1;
                } else {
                    let mut mv = String::from_str("mv -f");
                    push_quoted(&mut mv, tmp.as_str());
                    push_quoted(&mut mv, bin);
                    if shell(mv.as_str()) != 0 {
                        ret = 1;
                    } else if prof.strip {
                        let mut st = String::from_str("strip");
                        push_quoted(&mut st, bin);
                        shell(st.as_str());
                    }
                }
            }
        }
    }
    return ret;
}

// `super-c run <name>`: run a manifest command, building first when it asks for it.
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

// `super-c clean`: drop the manifest's outputs (out-dir + the emitted <root_dir>/build tree).
pub fn manifest_clean(m: &mf::Manifest) i32 {
    rm_rf(m.out_dir.as_str());
    let r = m.root.as_str();
    let mut k = r.len();
    while k > 0 && r[k - 1] != b'/' {
        k = k - 1;
    }
    let mut b = String::new();
    if k > 0 {
        b.push_str(r.slice(0, k));
    }
    b.push_str("build");
    rm_rf(b.as_str());
    return 0;
}
