// The content-addressed object cache shared by the build engine and script builds: the cache root,
// the 128-bit unit key (compiler version, flags, the unit's text and its quoted-include closure), and
// the shared namespace script builds compile through (`compile_units`) and engine builds share. Entries are installed whole
// through a temp file and a rename, so a reader never sees a torn object, and an entry another build
// deleted is compiled again. The engine's per-tree namespaces and their retention live in
// build_system::build.
import stdlib;
import time;
import driver_shim as shim;
import module::loader as loader;
import ast::ast as *;
import driver::util as *;

/// A temp file an interrupted install left behind is removed after this many seconds.
pub const TMP_IDLE: i64 = 3600;
/// The script namespace holds at most this many objects after a trim; above it, a build that installed
/// an object deletes the least recently used ones down to SCRIPT_OBJ_KEEP. Sized above the working set
/// of a `super-c test` run (about 2.5k distinct units), so a suite run evicts only older runs' objects.
pub const SCRIPT_OBJ_MAX: usize = 4096;
const SCRIPT_OBJ_KEEP: usize = 3072;
static_assert(SCRIPT_OBJ_KEEP < SCRIPT_OBJ_MAX, "a trim frees room for later installs");

/// The object cache root: the build cache root, or empty when caching is disabled (SC_NO_CACHE set,
/// or no resolvable home).
pub fn object_cache_dir() String {
    let off = stdlib::getenv("SC_NO_CACHE");
    if off != null && unsafe *off != 0 as char {
        return String::new();
    }
    return cache_root();
}

/// The build cache root: $SC_CACHE_DIR, else <home>/.super-c/cache; empty when no home resolves.
/// Objects live under `o/<namespace>`, the linker's ThinLTO caches under `lto/<namespace>`.
pub fn cache_root() String {
    let dir = stdlib::getenv("SC_CACHE_DIR");
    if dir != null && unsafe *dir != 0 as char {
        return String::from_cstr(dir);
    }
    let mut home = stdlib::getenv("HOME");
    if home == null || unsafe *home == 0 as char {
        home = stdlib::getenv("USERPROFILE");
    }
    if home == null || unsafe *home == 0 as char {
        return String::new();
    }
    let mut out = String::from_cstr(home);
    out.push_str("/.super-c/cache");
    return out;
}

/// The real path of `p`; empty when it does not resolve.
pub fn real_path(p: str) String {
    let mut buf = PathBuf {};
    let mut pp = String::from_str(p);
    if unsafe shim::sc_realpath(pp.cstr(), &mut buf[0]) == null {
        return String::new();
    }
    return String::from_cstr(&buf[0]);
}

/// `name` starts with a cache key (32 lowercase hex digits) and a dot: `<key>.o`, `<key>.d`, or the
/// temp file of an install.
pub const fn key_prefixed(name: str) bool {
    if name.len() < 34 || name[32] != b'.' {
        return false;
    }
    for i in 0..32 {
        let c = name[i as usize];
        if !(c >= b'0' && c <= b'9' || c >= b'a' && c <= b'f') {
            return false;
        }
    }
    return true;
}

/// Mix `n` bytes at `p` into the two key lanes. Two independent lanes: an object served for the WRONG
/// key would be a silent mislink, so the key is 128 bits, not 64.
pub fn ch_mix_bytes(h1: &mut u64, h2: &mut u64, p: *const u8, n: usize) {
    let mut a = *h1;
    let mut b = *h2;
    let mut i: usize = 0;
    while i + 8 <= n {
        let mut w: u64 = 0;
        let mut k: usize = 0;
        while k < 8 {
            w = w | (unsafe p[i + k]) as u64 << (k * 8) as u64;
            k = k + 1;
        }
        a = skey_mix(a, w);
        b = skey_mix(b, ~w);
        i = i + 8;
    }
    let mut tail: u64 = 0;
    let mut k: usize = 0;
    while i < n {
        tail = tail | (unsafe p[i]) as u64 << (k * 8) as u64;
        i = i + 1;
        k = k + 1;
    }
    a = skey_mix(a, tail ^ n as u64);
    b = skey_mix(b, ~(tail ^ n as u64));
    *h1 = a;
    *h2 = b;
}

/// `p` with every `seg/../` pair removed (`a/b/../c` -> `a/c`); a leading `..` stays.
pub fn norm_path(p: str, out: &mut String) {
    let mut segs = Vector::<str>::new();
    let mut i: usize = 0;
    let n = p.len();
    while i <= n {
        let mut e = i;
        while e < n && p[e] != b'/' {
            e = e + 1;
        }
        let seg = p.slice(i, e);
        if seg == ".." && segs.len() != 0 && segs[segs.len() - 1] != ".." {
            let _ = segs.pop();
        } else if seg != "." || segs.len() == 0 {
            segs.push(seg);
        }
        i = e + 1;
    }
    for k in 0..segs.len() {
        if k != 0 {
            out.push_byte(b'/');
        }
        out.push_str(segs[k]);
    }
}

/// Mix the transitive content hash of one file into the key lanes: its bytes, then the hash of every
/// file its `#include "..."` lines name (resolved the way the C compiler resolves them: relative to
/// the INCLUDING file). Memoized per build in `memo` (path FNV -> two words), so a header shared by
/// many units is read and hashed once; a file on the current include path counts once. False =
/// something was unreadable, and the unit is not cacheable: a header outside the key would mean
/// stale objects served as fresh.
pub fn ch_hash_file(path: str, h1: &mut u64, h2: &mut u64, depth: i32, memo: &mut Map<u64, u64>, pool: &mut Vector<u64>) bool {
    if depth > 64 {
        return false;
    }
    let pk = path.hash();
    let hit = switch memo.get(&pk) {
        Some(v) => *v,
        None => 0xFFFFFFFFFFFFFFFFu64,
    };
    if hit != 0xFFFFFFFFFFFFFFFFu64 {
        // 0 = in progress on this include path (counted where it was entered), else 1 + pool
        // index of its two words; an unreadable file is pool index with a zero pair.
        if hit != 0 {
            let a = pool[(hit - 1) as usize];
            let b = pool[hit as usize];
            if a == 0 && b == 0 {
                return false;
            }
            *h1 = skey_mix(*h1, a);
            *h2 = skey_mix(*h2, b);
        }
        return true;
    }
    memo.insert(pk, 0);
    let body = loader::read_file(path);
    let mut ok = !body.is_none();
    let mut a = FNV_BASIS;
    let mut b: u64 = 0x9e3779b97f4a7c15;
    if ok {
        let bd = body.unwrap();
        let s = bd.as_str();
        ch_mix_bytes(&mut a, &mut b, s.ptr(), s.len());
        let mut base = path.len();
        while base > 0 && path[base - 1] != b'/' && path[base - 1] != b'\\' {
            base = base - 1;
        }
        let mut i: usize = 0;
        let n = s.len();
        while i < n && ok {
            // start of line: `#` [ws] `include` [ws] `"..."`.
            let ls = i;
            while i < n && s[i] != b'\n' {
                i = i + 1;
            }
            let mut j = ls;
            while j < i && (s[j] == b' ' || s[j] == b'\t') {
                j = j + 1;
            }
            if j < i && s[j] == b'#' {
                j = j + 1;
                while j < i && (s[j] == b' ' || s[j] == b'\t') {
                    j = j + 1;
                }
                if j + 7 <= i && s.slice(j, j + 7) == "include" {
                    j = j + 7;
                    while j < i && (s[j] == b' ' || s[j] == b'\t') {
                        j = j + 1;
                    }
                    if j < i && s[j] == b'"' {
                        j = j + 1;
                        let hs = j;
                        while j < i && s[j] != b'"' {
                            j = j + 1;
                        }
                        if j < i {
                            let name = s.slice(hs, j);
                            let abs = name.len() > 0 && name[0] == b'/' || name.len() > 2 && name[1] == b':';
                            let cut = if base > 0 {
                                base - 1;
                            } else {
                                0 as usize;
                            };
                            let mut inc = String::new();
                            if abs {
                                inc.push_str(name);
                            } else {
                                // One memo entry per file: `dir/../x.h` from every including
                                // directory collapses to `x.h` (the generated tree has no links).
                                norm_path(loader::join2(path.slice(0, cut), name).as_str(), &mut inc);
                            }
                            ok = ch_hash_file(inc.as_str(), &mut a, &mut b, depth + 1, memo, pool);
                        }
                    }
                }
            }
            i = i + 1;
        }
    }
    if !ok {
        a = 0;
        b = 0;
    }
    pool.push(a);
    pool.push(b);
    memo.insert(pk, (pool.len() - 1) as u64);
    if !ok {
        return false;
    }
    *h1 = skey_mix(*h1, a);
    *h2 = skey_mix(*h2, b);
    return true;
}

/// Append `v` as 16 lowercase hex digits.
pub fn hex64(v: u64, out: &mut String) {
    let d = "0123456789abcdef";
    let mut i = 16;
    while i > 0 {
        i = i - 1;
        out.push_byte(d.byte_at((v >> (i * 4) as u64 & 15u64) as usize));
    }
}

/// The first line `args` (a `--version` invocation) prints, captured through `<dir>/.ccver`: part of
/// every object key and command fingerprint, so a toolchain upgrade invalidates objects whose sources
/// and flags did not change. Empty when the command prints nothing.
pub fn cc_version_argv(args: &mut Vector<String>, dir: str) String {
    let mut vf = loader::join2(dir, ".ccver");
    let _ = exec_args(args, vf.cstr());
    return take_first_line(vf.as_str()).unwrap_or(String::new());
}

/// The first line of file `path`, which is then removed; None when it cannot be read.
pub fn take_first_line(path: str) Option<String> {
    let v = loader::read_file(path);
    let mut pc = String::from_str(path);
    unsafe shim::sc_unlink(pc.cstr());
    if v.is_none() {
        return Option::<String>::None;
    }
    let body = v.unwrap();
    let s = body.as_str();
    let mut e: usize = 0;
    while e < s.len() && s[e] != b'\n' && s[e] != b'\r' {
        e = e + 1;
    }
    return Option::<String>::Some(String::from_str(s.slice(0, e)));
}

/// The namespace every script build (`super-c build file.spc -o out`, `super-c --test file.spc`)
/// shares below cache root `root`: `<root>/o/script`. A unit's key holds its name relative to its tree,
/// not the tree's path, so a unit of the same text in another tree reuses its object (`records_dir`
/// names the flags that make the object depend on the tree's path).
pub fn script_ns(root: str) String {
    let mut out = loader::join2(root, "o/");
    out.push_str(SCRIPT_NS);
    return out;
}

/// The directory name of the script namespace below `<root>/o`.
pub const SCRIPT_NS: str<'static> = "script";

/// Whether `flags` make an object depend on the directory it was compiled in or on the object's path:
/// debug information (`-g` other than `-g0`, which records the compile directory) and coverage or
/// profile instrumentation (`instruments`). Such a unit's key holds its tree's path.
pub fn records_dir(flags: &Vector<String>) bool {
    return debug_info(flags) || instruments(flags);
}

/// Whether `flags` ask for debug information (`-g` other than `-g0`).
pub fn debug_info(flags: &Vector<String>) bool {
    for i in 0..flags.len() {
        let f = flags.at(i).as_str();
        if f.starts_with("-g") && f != "-g0" {
            return true;
        }
    }
    return false;
}

/// Whether `flags` ask for coverage or profile instrumentation, which records where its data goes.
pub fn instruments(flags: &Vector<String>) bool {
    for i in 0..flags.len() {
        let f = flags.at(i).as_str();
        if f == "--coverage" || f == "-ftest-coverage" || f == "-fprofile-arcs" || f.starts_with("-fprofile-generate") {
            return true;
        }
        if f.starts_with("-fprofile-instr-generate") || f.starts_with("-fcoverage-mapping") || f.starts_with(
            "-fcs-profile-generate",
        ) {
            return true;
        }
    }
    return false;
}

// Whether path `p` is absolute (POSIX, a Windows drive, or a UNC or root-relative Windows path).
const fn abs_path(p: str) bool {
    return p.len() > 0 && (p[0] == b'/' || p[0] == b'\\') || p.len() > 2 && p[1] == b':';
}

// Whether `w` names a path relative to the working directory: it has a separator and is not absolute.
fn rel_path(w: str) bool {
    return !abs_path(w) && (w.find("/") >= 0 || w.find("\\") >= 0);
}

// The flags whose path is the next word, and (as prefixes) the ones that take it attached.
const NPATH_FLAGS: usize = 12;
const PATH_FLAGS: [str<'static>; NPATH_FLAGS] = [
    "-I",
    "-L",
    "-B",
    "-F",
    "-isystem",
    "-iquote",
    "-idirafter",
    "-include",
    "-imacros",
    "-isysroot",
    "-iframework",
    "--sysroot",
];

/// Whether the command words `cc` then `flags` mean the same from any working directory: no word
/// names a path relative to it (the compiler itself, an include or library directory, a sysroot,
/// a response file, a `--flag=<path>` value). Only then may a unit compile from its object directory.
pub fn cwd_free(cc: &Vector<String>, flags: &Vector<String>) bool {
    let mut pending = false;
    for i in 0..cc.len() + flags.len() {
        let w = if i < cc.len() {
            cc.at(i).as_str();
        } else {
            flags.at(i - cc.len()).as_str();
        };
        if pending {
            if !abs_path(w) {
                return false;
            }
            pending = false;
            continue;
        }
        if i == 0 || !w.starts_with("-") {
            if rel_path(w) || w.starts_with("@") && !abs_path(w.slice(1, w.len())) {
                return false;
            }
            continue;
        }
        for k in 0..NPATH_FLAGS {
            let f = unsafe PATH_FLAGS[k];
            if w == f {
                pending = true;
            } else if w.starts_with(f) {
                let tail = w.slice(f.len(), w.len());
                let v = if tail.starts_with("=") {
                    tail.slice(1, tail.len());
                } else {
                    tail;
                };
                if !abs_path(v) {
                    return false;
                }
            }
        }
        let eq = w.find("=");
        if eq >= 0 && rel_path(w.slice(eq as usize + 1, w.len())) {
            return false;
        }
    }
    return !pending;
}

// One compile command of `compile_units`: the units `order[first..first + n]`. A command of several
// runs from its own directory `dir`, where each object is named after its unit's file, and moves
// them into place; a command of one names its object itself (`dir` empty).
struct CJob {
    pub dir: String,
    pub first: u32,
    pub n: u32,
}

/// Compile the C units `units` (paths of the form `<root>/<rel>`) of a script build's tree `root` with
/// the compiler argv `cc` and compile flags `flags`, through the object namespace `ns` (not empty): a
/// unit whose key names an installed object copies it, the others compile and install their objects.
/// Objects land in `<root>/../obj/<rel>.o`, appended to `objs` in unit order; the copy, not the cached
/// entry, is what the link reads, so a concurrent trim cannot remove an input of the link.
///
/// A compiler start costs about as much as a small unit, so the units to compile run as few commands
/// as the process tree's free worker slots allow, all at once: `cc <flags> -c <units>` from a scratch
/// directory, then each object moves to its place. A unit whose file name another unit to compile
/// shares, every unit when a command word names a path relative to the working directory
/// (`cwd_free`), and every unit of a command the platform cannot start in another directory compiles
/// alone as `cc <flags> -c <unit> -o <obj>`. The `--version` probe whose first line keys the objects
/// runs beside the compiles when the namespace does not exist yet: nothing can hit then.
///
/// The compiler's diagnostics go to the inherited stderr. Returns 0, or the exit code of a failing
/// compile (1 when a compiler did not start or `root` does not resolve).
pub fn compile_units(
    cc: &Vector<String>,
    flags: &Vector<String>,
    root: str,
    units: &Vector<String>,
    ns: str,
    objs: &mut Vector<String>,
) i32 {
    assert(ns.len() != 0);
    let aroot = real_path(root);
    if aroot.len() == 0 {
        eprintln("build: cannot resolve '{}'", root);
        return 1;
    }
    let objdir = loader::join2(loader::dirname_of(aroot.as_str()), "obj");
    mkdir_p(objdir.as_str());
    let mut nsb = String::from_str(ns);
    let fresh = unsafe shim::sc_mtime(nsb.cstr()) == 0;
    mkdir_p(ns);
    // The version probe, started first: its line joins every key.
    let mut va = Vector::<String>::with_capacity(cc.len() + 1);
    for i in 0..cc.len() {
        va.push(cc.at(i).clone());
    }
    va.push(String::from_str("--version"));
    let mut vf = loader::join2(objdir.as_str(), ".ccver");
    let mut vptrs = Vector::<usize>::with_capacity(va.len() + 1);
    for i in 0..va.len() {
        vptrs.push(va[i].cstr() as usize);
    }
    vptrs.push(0);
    let mut vpid = unsafe shim::sc_spawn_argv(vptrs.as_ptr() as *const *const char, vf.cstr());
    // Per unit: its object path and the hash of its relative name and its text with its includes
    // (`ok` false: something unreadable, not cacheable).
    let mut memo = Map::<u64, u64>::new();
    let mut pool = Vector::<u64>::new();
    let mut opaths = Vector::<String>::with_capacity(units.len());
    let mut hs = Vector::<u64>::with_capacity(units.len() * 2);
    let mut ok = Vector::<bool>::with_capacity(units.len());
    for i in 0..units.len() {
        let unit = units.at(i).as_str();
        assert(unit.len() > root.len() + 3 && unit.starts_with(root) && unit.ends_with(".c"));
        let rel = unit.slice(root.len() + 1, unit.len());
        let mut opath = loader::join2(objdir.as_str(), rel.slice(0, rel.len() - 2));
        opath.push_str(".o");
        mkdir_p(loader::dirname_of(opath.as_str()));
        let mut h1 = FNV_BASIS;
        let mut h2: u64 = 0x9e3779b97f4a7c15;
        ch_mix_bytes(&mut h1, &mut h2, rel.ptr(), rel.len());
        ok.push(ch_hash_file(unit, &mut h1, &mut h2, 0, &mut memo, &mut pool));
        hs.push(h1);
        hs.push(h2);
        opaths.push(opath);
    }
    let mut cobjs = Vector::<String>::new();
    let mut miss = Vector::<u32>::new();
    if fresh {
        for i in 0..units.len() {
            miss.push(i as u32);
        }
    } else {
        cache_keys(&mut vpid, vf.as_str(), flags, aroot.as_str(), ns, &hs, &ok, &mut cobjs);
        for i in 0..units.len() {
            let cobj = cobjs.at(i);
            if cobj.len() != 0 && copy_file(cobj.as_str(), opaths.at(i).as_str()) {
                // The mtime is the entry's last use: the trim deletes the least recently used.
                let mut cp = cobj.clone();
                let _ = unsafe shim::sc_touch(cp.cstr());
            } else {
                miss.push(i as u32);
            }
        }
    }
    let rc = run_jobs(cc, flags, aroot.as_str(), units, root, objdir.as_str(), &opaths, &miss, &mut vpid);
    if rc != 0 {
        return rc;
    }
    if fresh {
        cache_keys(&mut vpid, vf.as_str(), flags, aroot.as_str(), ns, &hs, &ok, &mut cobjs);
    }
    let mut installed = false;
    for i in 0..miss.len() {
        let u = miss[i] as usize;
        let cobj = cobjs.at(u);
        if cobj.len() == 0 {
            continue;
        }
        // A temp of this process, then a rename: concurrent builds installing the same key each
        // move a whole object into place, and a reader opens either one.
        let mut tmp = format("{}.{}.tmp", cobj.as_str(), unsafe shim::sc_getpid());
        let mut dst = cobj.clone();
        if copy_file(opaths.at(u).as_str(), tmp.as_str()) && unsafe shim::sc_rename(tmp.cstr(), dst.cstr()) == 0 {
            installed = true;
        } else {
            let _ = unsafe shim::sc_unlink(tmp.cstr());
        }
    }
    for i in 0..opaths.len() {
        objs.push(opaths.at(i).clone());
    }
    if installed {
        script_trim(ns, time::now());
    }
    return 0;
}

// Wait for the version probe `vpid` (spawned into file `vf`; -1 = not started or already waited for)
// and fill `cobjs` with every unit's cache entry under namespace `ns`: the key of the version line,
// the compile `flags`, the tree path `aroot` when the flags record it, and the unit's hash pair in
// `hs`; empty for a unit whose `ok` is false.
fn cache_keys(
    vpid: &mut i64,
    vf: str,
    flags: &Vector<String>,
    aroot: str,
    ns: str,
    hs: &Vector<u64>,
    ok: &Vector<bool>,
    cobjs: &mut Vector<String>,
) {
    if *vpid >= 0 {
        let mut code: i32 = 0;
        let _ = unsafe shim::sc_waitpid(*vpid, &mut code);
        *vpid = -1;
    }
    let ccver = take_first_line(vf).unwrap_or(String::new());
    let mut b1 = FNV_BASIS;
    let mut b2: u64 = 0x9e3779b97f4a7c15;
    ch_mix_bytes(&mut b1, &mut b2, ccver.as_str().ptr(), ccver.len());
    for i in 0..flags.len() {
        let f = flags.at(i).as_str();
        ch_mix_bytes(&mut b1, &mut b2, f.ptr(), f.len());
        ch_mix_bytes(&mut b1, &mut b2, " ".ptr(), 1);
    }
    if records_dir(flags) {
        ch_mix_bytes(&mut b1, &mut b2, aroot.ptr(), aroot.len());
    }
    cobjs.truncate(0);
    for i in 0..ok.len() {
        let mut cobj = String::new();
        if ok[i] {
            let h1 = skey_mix(skey_mix(b1, hs[2 * i]), hs[2 * i + 1]);
            let h2 = skey_mix(skey_mix(b2, hs[2 * i + 1]), hs[2 * i]);
            cobj = String::from_str(ns);
            cobj.push_byte(b'/');
            hex64(h1, &mut cobj);
            hex64(h2, &mut cobj);
            cobj.push_str(".o");
        }
        cobjs.push(cobj);
    }
}

// The base name of path `p` (after its last separator).
fn base_name(p: str) str {
    let mut i = p.len();
    while i > 0 && p[i - 1] != b'/' && p[i - 1] != b'\\' {
        i -= 1;
    }
    return p.slice(i, p.len());
}

// The argv of compile job `j`: from its directory, `cc <flags> -c <absolute units>`; alone,
// `cc <flags> -c <unit> -o <object>`.
fn job_args(
    cc: &Vector<String>,
    flags: &Vector<String>,
    aroot: str,
    units: &Vector<String>,
    root: str,
    opaths: &Vector<String>,
    order: &Vector<u32>,
    j: &CJob,
    args: &mut Vector<String>,
) {
    args.truncate(0);
    for k in 0..cc.len() {
        args.push(cc.at(k).clone());
    }
    for k in 0..flags.len() {
        args.push(flags.at(k).clone());
    }
    args.push(String::from_str("-c"));
    if j.dir.len() == 0 {
        let u = order[j.first as usize] as usize;
        args.push(units.at(u).clone());
        args.push(String::from_str("-o"));
        args.push(opaths.at(u).clone());
        return;
    }
    for k in j.first..j.first + j.n {
        let unit = units.at(order[k as usize] as usize).as_str();
        args.push(loader::join2(aroot, unit.slice(root.len() + 1, unit.len())));
    }
}

// Compile the units `miss` (indices into `units`) as `compile_units` describes, with the version
// probe `vpid` (-1: none running) reaped among the compiles and waited for before returning, so no
// child outlives the call. Returns 0, or the exit code of the first command that failed (1 when a
// compiler did not start or an object could not move into place); after a failure no command starts
// and the running ones are waited for.
fn run_jobs(
    cc: &Vector<String>,
    flags: &Vector<String>,
    aroot: str,
    units: &Vector<String>,
    root: str,
    objdir: str,
    opaths: &Vector<String>,
    miss: &Vector<u32>,
    vpid: &mut i64,
) i32 {
    // Batch the units whose file name no other unit to compile shares; the rest compile alone.
    let mut order = Vector::<u32>::with_capacity(miss.len());
    let mut alone = Vector::<u32>::new();
    let batch = cwd_free(cc, flags);
    for i in 0..miss.len() {
        let bi = base_name(opaths.at(miss[i] as usize).as_str());
        let mut dup = false;
        for k in 0..miss.len() {
            dup = dup || k != i && base_name(opaths.at(miss[k] as usize).as_str()) == bi;
        }
        if batch && !dup {
            order.push(miss[i]);
        } else {
            alone.push(miss[i]);
        }
    }
    let nb = order.len();
    for i in 0..alone.len() {
        order.push(alone[i]);
    }
    let want = pick(miss.len() < 64, miss.len(), 64) as i32;
    let slots = (unsafe shim::sc_jobserver_claim(pick(want > 0, want, 1))) as usize;
    let mut jobs = Vector::<CJob>::new();
    // The batch splits into one command per slot the single-unit commands leave free, in contiguous
    // runs of about equal length; a run of one unit compiles alone.
    let free = if slots > alone.len() {
        slots - alone.len();
    } else {
        1 as usize;
    };
    let nbatch = pick(nb < free, nb, free);
    for c in 0..nbatch {
        let first = (nb * c / nbatch) as u32;
        let last = (nb * (c + 1) / nbatch) as u32;
        let dir = if last - first > 1 {
            format("{}/.b{}", objdir, c);
        } else {
            String::new();
        };
        jobs.push(CJob { dir: dir, first: first, n: last - first });
    }
    for k in nb..order.len() {
        jobs.push(CJob { dir: String::new(), first: k as u32, n: 1 });
    }
    let cap = pick(slots > 0, slots, 1);
    // The running children, the version probe included, and per entry its job (-1: the probe).
    let mut pids = Vector::<i64>::with_capacity(cap + 1);
    let mut pjob = Vector::<i64>::with_capacity(cap + 1);
    if *vpid >= 0 {
        pids.push(*vpid);
        pjob.push(-1);
    }
    let mut args = Vector::<String>::new();
    let mut next: usize = 0;
    let mut running: usize = 0;
    let mut rc: i32 = 0;
    // Bounded: every job starts at most once, and a split adds one single-unit job per unit of a
    // multi-unit job, which never splits again.
    while next < jobs.len() && rc == 0 || pids.len() != 0 {
        while rc == 0 && next < jobs.len() && running < cap {
            let mut j = CJob { dir: jobs.at(next).dir.clone(), first: jobs.at(next).first, n: jobs.at(next).n };
            next += 1;
            if j.dir.len() != 0 {
                mkdir_p(j.dir.as_str());
            }
            job_args(cc, flags, aroot, units, root, opaths, &order, &j, &mut args);
            let mut ptrs = Vector::<usize>::with_capacity(args.len() + 1);
            for k in 0..args.len() {
                ptrs.push(args[k].cstr() as usize);
            }
            ptrs.push(0);
            let dirp: *const char = if j.dir.len() != 0 {
                j.dir.cstr();
            } else {
                null;
            };
            let pid = unsafe shim::sc_spawn_argv_in(ptrs.as_ptr() as *const *const char, null, dirp);
            if pid >= 0 {
                pids.push(pid);
                pjob.push((next - 1) as i64);
                running += 1;
            } else if j.dir.len() != 0 {
                for k in j.first..j.first + j.n {
                    jobs.push(CJob { dir: String::new(), first: k, n: 1 });
                }
            } else {
                eprintln("build: cannot start '{}'", cc.at(0).as_str());
                rc = 1;
            }
        }
        if pids.len() == 0 {
            continue;
        }
        let mut code: i32 = 0;
        let w = unsafe shim::sc_wait_any(pids.as_ptr(), pids.len() as i32, &mut code);
        if w < 0 {
            // No child can be waited for: none of the running ones will report.
            *vpid = -1;
            return pick(rc != 0, rc, 1);
        }
        let ji = pjob[w as usize];
        let _ = pids.swap_remove(w as usize);
        let _ = pjob.swap_remove(w as usize);
        if ji < 0 {
            *vpid = -1;
            continue;
        }
        running -= 1;
        if code != 0 {
            if rc == 0 {
                rc = code;
            }
            continue;
        }
        // A batch's objects move from its directory into place.
        let jb = jobs.at(ji as usize);
        if jb.dir.len() == 0 {
            continue;
        }
        for k in jb.first..jb.first + jb.n {
            let op = opaths.at(order[k as usize] as usize);
            let bn = base_name(op.as_str());
            let mut from = format("{}/{}", jb.dir.as_str(), bn);
            let mut to = op.clone();
            if unsafe shim::sc_rename(from.cstr(), to.cstr()) != 0 && rc == 0 {
                eprintln("build: cannot move '{}' into place", from.as_str());
                rc = 1;
            }
        }
    }
    return rc;
}

// One object of the script namespace: its last use and its name's index in the listing.
struct ObjUse {
    pub mt: i64,
    pub at: usize,
}

const fn obj_use_older(a: &ObjUse, b: &ObjUse) i32 {
    if a.mt < b.mt {
        return -1;
    }
    if a.mt > b.mt {
        return 1;
    }
    return 0;
}

// Keep namespace `ns` within SCRIPT_OBJ_MAX objects: above it, delete the least recently used down to
// SCRIPT_OBJ_KEEP, and every temp file older than TMP_IDLE. Builds may trim at once: an object one of
// them deletes is compiled again by the next build that needs it, never read torn.
pub fn script_trim(ns: str, now: i64) {
    let names = list_dir(ns, false).unwrap_or(Vector::<String>::new());
    let mut objs = Vector::<ObjUse>::new();
    for i in 0..names.len() {
        let n = names.at(i).as_str();
        let mut p = loader::join2(ns, n);
        if n.ends_with(".tmp") {
            if now - unsafe shim::sc_mtime(p.cstr()) >= TMP_IDLE {
                let _ = unsafe shim::sc_unlink(p.cstr());
            }
        } else if n.len() == 34 && key_prefixed(n) && n.ends_with(".o") {
            objs.push(ObjUse { mt: 0, at: i });
        }
    }
    if objs.len() <= SCRIPT_OBJ_MAX {
        return;
    }
    for i in 0..objs.len() {
        let mut p = loader::join2(ns, names.at(objs[i].at).as_str());
        objs.index_mut(i).mt = unsafe shim::sc_mtime(p.cstr());
    }
    objs.sort_by(obj_use_older);
    for i in 0..objs.len() - SCRIPT_OBJ_KEEP {
        let mut p = loader::join2(ns, names.at(objs[i].at).as_str());
        let _ = unsafe shim::sc_unlink(p.cstr());
    }
}
