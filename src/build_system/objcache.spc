// The content-addressed object cache shared by the build engine and script builds: the cache root,
// the 128-bit unit key (compiler version, flags, the unit's text and its quoted-include closure), and
// the shared namespace script builds compile through (`compile_units`) and engine builds share. Entries are installed whole
// through a temp file and a rename, so a reader never sees a torn object, and an entry another build
// deleted is compiled again. The engine's per-tree namespaces and their retention live in
// build_system::build.
import stdlib;
import driver_shim as shim;
import module::loader as loader;
import ast::ast as *;
import driver::util as *;
import string as cstring;

/// A temp file an interrupted install left behind is removed after this many seconds.
pub const TMP_IDLE: i64 = 3600;
/// The script builds' cache root (SCRIPTS_DIR) holds at most this many objects after a sweep; above it,
/// the sweep deletes the least recently used unused ones down to SCRIPT_OBJ_KEEP (`trim_objects`). A
/// `super-c test` run uses about 4.8k objects (its fixtures and the builds its harnesses run, 323 MiB).
pub const SCRIPT_OBJ_MAX: usize = 16384;
pub const SCRIPT_OBJ_KEEP: usize = 12288;
static_assert(SCRIPT_OBJ_KEEP < SCRIPT_OBJ_MAX, "a trim frees room for later installs");

/// The object cache root of project `project` (`cache_root`), or empty when caching is disabled
/// (SC_NO_CACHE set, or no resolvable home).
pub fn object_cache_dir(project: str) String {
    let off = stdlib::getenv("SC_NO_CACHE");
    if off != null && unsafe *off != 0 as char {
        return String::new();
    }
    return cache_root(project);
}

/// The build cache base: $SC_CACHE_DIR, else <home>/.super-c/cache; empty when no home resolves.
pub fn cache_base() String {
    let dir = stdlib::get_env("SC_CACHE_DIR").unwrap_or(String::new());
    if dir.len() != 0 {
        return dir;
    }
    let mut out = stdlib::get_env("HOME").unwrap_or(String::new());
    if out.len() == 0 {
        out = stdlib::get_env("USERPROFILE").unwrap_or(String::new());
    }
    if out.len() == 0 {
        return out;
    }
    out.push_str("/.super-c/cache");
    return out;
}

/// The cache directory of script builds below the cache base.
pub const SCRIPTS_DIR: str<'static> = ".scripts";

/// The cache root of project `project` (its `bin`, else its `[lib]` name; empty for a script build):
/// `<base>/<project>` (`project_dir`), so each project's sweep and budget see only its own files;
/// empty when no base resolves. Objects live under `o/<namespace>`, the linker's ThinLTO caches under
/// `lto/<namespace>`, the prelude images under `prelude`.
pub fn cache_root(project: str) String {
    let base = cache_base();
    if base.len() == 0 {
        return base;
    }
    return loader::join2(base.as_str(), project_dir(project).as_str());
}

/// The directory name of project `project` below the cache base: SCRIPTS_DIR for a script build (an
/// empty name); else the name with each byte outside `[A-Za-z0-9._-]` and a leading `.` made `_`, and
/// a `_` after a name of the layout before project directories (`o`, `lto`, `prelude`, `ccver`), which
/// older compilers still use.
pub fn project_dir(project: str) String {
    if project.len() == 0 {
        return String::from_str(SCRIPTS_DIR);
    }
    let mut out = String::with_capacity(project.len() + 1);
    for i in 0..project.len() {
        let c = project[i];
        let ok = c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9' || c == b'-' || c == b'_' || c == b'.' && i != 0;
        out.push_byte(pick(ok, c, b'_'));
    }
    let o = out.as_str();
    if o == "o" || o == "lto" || o == "prelude" || o == "ccver" {
        out.push_byte(b'_');
    }
    return out;
}

/// The real path of `p`; empty when it does not resolve.
pub fn real_path(p: str) String {
    return loader::real_path_of(p);
}

/// `name` starts with a cache key (32 lowercase hex digits) and a dot: `<key>.o`, `<key>.d`, the packed
/// `<key>.z` of older compilers, or the temp file of an install.
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

// `dir/name` into `out` (cleared first) as `norm_path` spells it, with no intermediate string: each
// segment is appended, `.` dropped past the first, and `..` removes the last segment unless that is
// `..` too.
fn norm_join(dir: str, name: str, out: &mut String) {
    out.clear();
    let mut nseg: usize = 0;
    for part in 0..2 {
        let p = if part == 0 {
            dir;
        } else {
            name;
        };
        let n = p.len();
        let mut i: usize = 0;
        while i <= n {
            let mut e = i;
            while e < n && p[e] != b'/' {
                e = e + 1;
            }
            let seg = p.slice(i, e);
            i = e + 1;
            if seg == ".." && nseg != 0 {
                // The last segment of `out`: everything past its last '/' (segments hold none).
                let mut ls = out.len();
                let mut up = false;
                {
                    let o = out.as_str();
                    while ls > 0 && o[ls - 1] != b'/' {
                        ls = ls - 1;
                    }
                    up = o.slice(ls, o.len()) == "..";
                }
                if !up {
                    out.truncate(
                        if nseg == 1 {
                            0;
                        } else {
                            ls - 1;
                        },
                    );
                    nseg = nseg - 1;
                    continue;
                }
            }
            if seg != "." || nseg == 0 {
                if nseg != 0 {
                    out.push_byte(b'/');
                }
                out.push_str(seg);
                nseg = nseg + 1;
            }
        }
    }
}

/// Mix the transitive content hash of one file into the key lanes: its bytes, then the hash of every
/// file its `#include "..."` lines name (resolved the way the C compiler resolves them: relative to
/// the INCLUDING file). `text` is the file's content when the caller holds it (empty: `texts` by path,
/// else read from disk); `texts` holds the files the build has in memory, by normalized path. Memoized
/// per build in `memo` (path -> 1 + index of its two words in `pool`, 0 while the file is on the
/// include path being hashed), so a header shared by many units is hashed once; a file on the
/// current include path counts once. False = something was unreadable, and the unit is not cacheable:
/// a header outside the key would mean stale objects served as fresh.
pub fn ch_hash_file(
    path: &String,
    text: str,
    h1: &mut u64,
    h2: &mut u64,
    depth: i32,
    memo: &mut Map<String, u64>,
    pool: &mut Vector<u64>,
    texts: &Map<String, String>,
) bool {
    if depth > 64 {
        return false;
    }
    let hit = switch memo.get(path) {
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
    memo.insert(path.clone(), 0);
    let held = text.len() != 0 || texts.contains_key(path);
    let mut read = String::new();
    let mut ok = held;
    if !held {
        switch loader::read_file(path.as_str()) {
            Some(b) => {
                read = b;
                ok = true;
            },
            None => {},
        };
    }
    let mut a = FNV_BASIS;
    let mut b: u64 = 0x9e3779b97f4a7c15;
    if ok {
        let s = if text.len() != 0 {
            text;
        } else if held {
            texts.get(path).unwrap().as_str();
        } else {
            read.as_str();
        };
        ch_mix_bytes(&mut a, &mut b, s.ptr(), s.len());
        let ps = path.as_str();
        let mut base = ps.len();
        while base > 0 && ps[base - 1] != b'/' && ps[base - 1] != b'\\' {
            base = base - 1;
        }
        let cut = if base > 0 {
            base - 1;
        } else {
            0 as usize;
        };
        // The include path being hashed, reused for every include of this file.
        let mut inc = String::new();
        let n = s.len();
        let mut i: usize = 0;
        while i < n && ok {
            // A `#` that starts a line after blanks: `#` [ws] `include` [ws] `"..."`.
            let hp = unsafe cstring::memchr(s.ptr() + i, b'#', n - i);
            if hp == null {
                break;
            }
            let h = hp as usize - s.ptr() as usize;
            let mut ls = h;
            while ls > 0 && (s[ls - 1] == b' ' || s[ls - 1] == b'\t') {
                ls = ls - 1;
            }
            i = h + 1;
            if ls > 0 && s[ls - 1] != b'\n' {
                continue;
            }
            let lp = unsafe cstring::memchr(s.ptr() + i, b'\n', n - i);
            let le = if lp == null {
                n;
            } else {
                lp as usize - s.ptr() as usize;
            };
            let mut j = i;
            while j < le && (s[j] == b' ' || s[j] == b'\t') {
                j = j + 1;
            }
            if j + 7 <= le && s.slice(j, j + 7) == "include" {
                j = j + 7;
                while j < le && (s[j] == b' ' || s[j] == b'\t') {
                    j = j + 1;
                }
                if j < le && s[j] == b'"' {
                    j = j + 1;
                    let hs = j;
                    while j < le && s[j] != b'"' {
                        j = j + 1;
                    }
                    if j < le {
                        let name = s.slice(hs, j);
                        let abs = name.len() > 0 && name[0] == b'/' || name.len() > 2 && name[1] == b':';
                        if abs {
                            inc.clear();
                            inc.push_str(name);
                        } else {
                            // One memo entry per file: `dir/../x.h` from every including
                            // directory collapses to `x.h` (the generated tree has no links).
                            norm_join(ps.slice(0, cut), name, &mut inc);
                        }
                        ok = ch_hash_file(&inc, "", &mut a, &mut b, depth + 1, memo, pool, texts);
                    }
                }
            }
            i = le;
        }
    }
    if !ok {
        a = 0;
        b = 0;
    }
    pool.push(a);
    pool.push(b);
    switch memo.get_mut(path) {
        Some(v) => {
            *v = (pool.len() - 1) as u64;
        },
        None => {},
    };
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

/// The executable the first word of `cmd` names: as given when it has a directory part, else the
/// first PATH entry holding it (`.exe` too on a Windows host). Returns its mtime; 0 when unresolved
/// (`out` then holds the bare word).
pub fn which_path(cmd: str, out: &mut String) i64 {
    let mut e: usize = 0;
    while e < cmd.len() && cmd[e] != b' ' {
        e += 1;
    }
    let name = cmd.slice(0, e);
    let win = unsafe shim::sc_host_platform() == 0;
    let mut cand = String::new();
    let mut has_dir = false;
    for i in 0..name.len() {
        if name[i] == b'/' || name[i] == b'\\' {
            has_dir = true;
        }
    }
    if !has_dir {
        let pe = stdlib::get_env("PATH");
        if pe.is_some() {
            let pv = pe.unwrap();
            let path = pv.as_str();
            let sep = if win {
                b';';
            } else {
                b':';
            };
            let mut a: usize = 0;
            for i in 0..path.len() + 1 {
                if i == path.len() || path[i] == sep {
                    if i > a {
                        for x in 0..2 {
                            cand.clear();
                            cand.push_str(path.slice(a, i));
                            cand.push_byte(b'/');
                            cand.push_str(name);
                            if x == 1 {
                                cand.push_str(".exe");
                            }
                            let mt = unsafe shim::sc_mtime(cand.cstr());
                            if mt != 0 {
                                out.push_string(&cand);
                                return mt;
                            }
                            if !win {
                                break;
                            }
                        }
                    }
                    a = i + 1;
                }
            }
        }
    }
    out.push_str(name);
    cand.clear();
    cand.push_str(name);
    return unsafe shim::sc_mtime(cand.cstr());
}

/// The identity of compiler command `cc` that a recorded version line stands for: the command, and
/// the path and modification time of the program it runs. On macOS a compiler in `/usr/bin` is an
/// xcrun stub that runs a developer directory's toolchain: `DEVELOPER_DIR`, else the xcode-select
/// link's target, else the Command Line Tools. The identity adds those settings (`TOOLCHAINS` too)
/// and the modification time of each candidate's clang, so an upgrade or a switch of toolchains is
/// a new identity.
fn cc_identity(cc: str) String {
    let mut path = String::new();
    let mt = which_path(cc, &mut path);
    let mut id = format("{}\t{}\t{}", cc, path.as_str(), mt);
    if unsafe shim::sc_host_platform() == 1 && path.as_str().starts_with("/usr/bin/") {
        let env = stdlib::get_env("DEVELOPER_DIR").unwrap_or(String::new());
        let mut lb = PathBuf {};
        let mut link = String::new();
        if unsafe shim::sc_readlink("/var/db/xcode_select_link".ptr() as *const char, &mut lb[0], 4096) > 0 {
            link.push_str(str::from_cbuf(lb.as_slice()));
        }
        id.format_into(
            "\t{}\t{}\t{}",
            env.as_str(),
            link.as_str(),
            stdlib::get_env("TOOLCHAINS").unwrap_or(String::new()).as_str(),
        );
        let devs: [str; 3] = [env.as_str(), link.as_str(), "/Library/Developer/CommandLineTools"];
        let clangs: [str; 2] = ["usr/bin/clang", "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"];
        for d in devs {
            for c in clangs {
                if d.len() != 0 {
                    let mut cp = loader::join2(d, c);
                    id.format_into("\t{}", unsafe shim::sc_mtime(cp.cstr()));
                }
            }
        }
    }
    return id;
}

// The record of compiler command `cc`'s version line: an entry of the script builds' `script` namespace
// (every project's builds read it) named by the hash of the compiler's identity `id`, holding the
// identity, then the line. It follows the
// namespace's rules (`trim_objects`, `touch_entry`). Empty when the object cache is off.
fn ccver_record_path(id: &String) String {
    let root = object_cache_dir("");
    if root.len() == 0 {
        return root;
    }
    let mut h1 = FNV_BASIS;
    let mut h2: u64 = 0x9e3779b97f4a7c15;
    ch_mix_bytes(&mut h1, &mut h2, id.as_str().ptr(), id.len());
    let mut name = String::new();
    hex64(h1, &mut name);
    hex64(h2, &mut name);
    name.push_str(".o");
    return script_entry(script_ns(root.as_str()).as_str(), name.as_str());
}

/// The version line recorded for compiler command `cc` (its words space-joined) while the
/// compiler's identity (`cc_identity`) is unchanged; None when no record matches. A `--version`
/// probe costs a process (about 10 ms of CPU through the xcrun stub), once per compiler instead
/// of once per build.
pub fn ccver_recorded(cc: str) Option<String> {
    let id = cc_identity(cc);
    let rp = ccver_record_path(&id);
    if rp.len() == 0 {
        return Option::<String>::None;
    }
    let body = loader::read_file(rp.as_str());
    if body.is_none() {
        return Option::<String>::None;
    }
    let b = body.unwrap();
    let s = b.as_str();
    let nl = s.find_byte(b'\n');
    if nl < 0 || s.slice(0, nl as usize) != id.as_str() {
        return Option::<String>::None;
    }
    let rest = s.slice(nl as usize + 1, s.len());
    let e = rest.find_byte(b'\n');
    if e < 0 {
        return Option::<String>::None;
    }
    touch_entry(rp.as_str());
    return Option::<String>::Some(String::from_str(rest.slice(0, e as usize)));
}

/// Record version line `line` of compiler command `cc` (`ccver_recorded` reads it); an empty line
/// (the probe printed nothing) is not recorded. A failed write only makes the next build probe again.
pub fn ccver_record(cc: str, line: &String) {
    if line.len() == 0 {
        return;
    }
    let id = cc_identity(cc);
    let rp = ccver_record_path(&id);
    if rp.len() == 0 {
        return;
    }
    mkdir_p(loader::dirname_of(rp.as_str()));
    let mut body = id.clone();
    body.format_into("\n{}\n", line.as_str());
    let _ = write_file_atomic(rp.as_str(), body.as_str());
}

/// Compiler command `cc` for target `target` with the macOS xcrun stub it starts with (`/usr/bin/cc`,
/// `clang` or `gcc`, about 5 ms of CPU per run) replaced by the compiler the stub runs, and the SDK
/// the stub passes (as SDKROOT) given as `-isysroot`; for a macOS target on a macOS host only. The
/// pair is recorded under the stub's identity (`cc_identity`) and SDKROOT, so `xcrun` runs once per
/// toolchain; with the object cache off, once per call, its output captured in directory `dir`. `cc`
/// unchanged otherwise: a lookup that fails, or a path with a space (the command is split at spaces).
pub fn direct_cc(cc: String, target: i32, dir: str) String {
    if target != 1 || unsafe shim::sc_host_platform() != 1 {
        return cc;
    }
    let mut path = String::new();
    let _ = which_path(cc.as_str(), &mut path);
    let p = path.as_str();
    if p != "/usr/bin/cc" && p != "/usr/bin/clang" && p != "/usr/bin/gcc" {
        return cc;
    }
    let ci = cc_identity(cc.as_str());
    let id = format("xcrun\t{}\t{}", stdlib::get_env("SDKROOT").unwrap_or(String::new()).as_str(), ci.as_str());
    let rp = ccver_record_path(&id);
    let mut tool = String::new();
    let mut sdk = String::new();
    let body = if rp.len() != 0 {
        loader::read_file(rp.as_str());
    } else {
        Option::<String>::None;
    };
    if body.is_some() {
        let b = body.unwrap();
        let s = b.as_str();
        let n1 = s.find_byte(b'\n');
        if n1 >= 0 && s.slice(0, n1 as usize) == id.as_str() {
            let r1 = s.slice(n1 as usize + 1, s.len());
            let n2 = r1.find_byte(b'\n');
            let r2 = r1.slice(pick(n2 < 0, r1.len(), n2 as usize + 1), r1.len());
            let n3 = r2.find_byte(b'\n');
            if n2 >= 0 && n3 >= 0 {
                tool.push_str(r1.slice(0, n2 as usize));
                sdk.push_str(r2.slice(0, n3 as usize));
                touch_entry(rp.as_str());
            }
        }
    }
    if tool.len() == 0 {
        // The two lookups run at once, their output captured beside the record (in `dir` without one).
        let base = if rp.len() != 0 {
            mkdir_p(loader::dirname_of(rp.as_str()));
            rp.clone();
        } else {
            loader::join2(dir, ".xcrun");
        };
        let pid = unsafe shim::sc_getpid();
        let mut tout = format("{}.{}t", base.as_str(), pid);
        let mut sout = format("{}.{}s", base.as_str(), pid);
        let mut fa = Vector::<String>::new();
        fa.push(String::from_str("xcrun"));
        fa.push(String::from_str("-f"));
        fa.push(String::from_str(p.slice(9, p.len())));
        let mut sa = Vector::<String>::new();
        sa.push(String::from_str("xcrun"));
        sa.push(String::from_str("--show-sdk-path"));
        let xcrun = "/usr/bin/xcrun".ptr() as *const char;
        let tpid = spawn_at(xcrun, &mut fa, tout.cstr());
        let spid = spawn_at(xcrun, &mut sa, sout.cstr());
        let mut code: i32 = 0;
        if tpid >= 0 {
            let _ = unsafe shim::sc_waitpid(tpid, &mut code);
        }
        if spid >= 0 {
            let _ = unsafe shim::sc_waitpid(spid, &mut code);
        }
        tool = take_first_line(tout.as_str()).unwrap_or(String::new());
        sdk = take_first_line(sout.as_str()).unwrap_or(String::new());
        let _ = unsafe shim::sc_unlink(tout.cstr());
        let _ = unsafe shim::sc_unlink(sout.cstr());
        if !tool.as_str().starts_with("/") || unsafe shim::sc_mtime(tool.cstr()) == 0 || !is_dir(sdk.as_str()) {
            return cc;
        }
        if rp.len() != 0 {
            let mut rec = id.clone();
            rec.format_into("\n{}\n{}\n", tool.as_str(), sdk.as_str());
            let _ = write_file_atomic(rp.as_str(), rec.as_str());
        }
    }
    if tool.as_str().find_byte(b' ') >= 0 || sdk.as_str().find_byte(b' ') >= 0 {
        return cc;
    }
    let mut e: usize = 0;
    while e < cc.len() && cc.as_str()[e] != b' ' {
        e += 1;
    }
    return format("{} -isysroot {}{}", tool.as_str(), sdk.as_str(), cc.as_str().slice(e, cc.len()));
}

/// `cc --version`'s first line for compiler command `cc`: the record when it matches, else the
/// probe through `<dir>/.ccver`, then recorded.
pub fn cc_version(cc: str, dir: str) String {
    let rec = ccver_recorded(cc);
    if rec.is_some() {
        return rec.unwrap();
    }
    let mut va = Vector::<String>::new();
    split_args(&mut va, cc);
    va.push(String::from_str("--version"));
    let line = cc_version_argv(&mut va, dir);
    ccver_record(cc, &line);
    return line;
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

/// The path of entry `name` (`<key>.o`, `<key>.d` or `<key>.z`) in a namespace `ns` of the script
/// layout (`compile_units`, the engine's shared entries): below the subdirectory named by the key's first
/// two hex digits, so no directory holds more than about a 256th of the namespace.
pub fn script_entry(ns: str, name: str) String {
    return loader::join2(loader::join2(ns, name.slice(0, 2)).as_str(), name);
}

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
/// unit whose key names an installed object links it (`link_or_copy`), the others compile and install
/// their objects the same way. Objects land in `<root>/../obj/<rel>.o`, appended to `objs` in unit
/// order; the link reads the tree's name of each object, not the cache's, so a concurrent trim (which
/// removes only the cache's name) cannot remove an input of the link.
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
    // The version line joins every key: the line recorded for this compiler, else the probe, started
    // first.
    let mut ccs = String::new();
    for i in 0..cc.len() {
        if i != 0 {
            ccs.push_byte(b' ');
        }
        ccs.push_string(cc.at(i));
    }
    let known = ccver_recorded(ccs.as_str()).unwrap_or(String::new());
    let mut vf = loader::join2(objdir.as_str(), ".ccver");
    let mut vpid: i64 = -1;
    if known.len() == 0 {
        let mut va = Vector::<String>::with_capacity(cc.len() + 1);
        for i in 0..cc.len() {
            va.push(cc.at(i).clone());
        }
        va.push(String::from_str("--version"));
        let mut vptrs = Vector::<usize>::with_capacity(va.len() + 1);
        for i in 0..va.len() {
            vptrs.push(va[i].cstr() as usize);
        }
        vptrs.push(0);
        vpid = unsafe shim::sc_spawn_argv(null, vptrs.as_ptr() as *const *const char, vf.cstr());
    }
    // Per unit: its object path and the hash of its relative name and its text with its includes
    // (`ok` false: something unreadable, not cacheable).
    let mut memo = Map::<String, u64>::new();
    let mut pool = Vector::<u64>::new();
    let texts = Map::<String, String>::new();
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
        ok.push(ch_hash_file(units.at(i), "", &mut h1, &mut h2, 0, &mut memo, &mut pool, &texts));
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
        cache_keys(&known, ccs.as_str(), &mut vpid, vf.as_str(), cc, flags, aroot.as_str(), ns, &hs, &ok, &mut cobjs);
        for i in 0..units.len() {
            let cobj = cobjs.at(i);
            if cobj.len() != 0 && link_or_copy(cobj.as_str(), opaths.at(i).as_str()) {
                touch_entry(cobj.as_str());
            } else {
                miss.push(i as u32);
            }
        }
    }
    // An object of an earlier build may be a name of a cache entry: a compiler that writes its output
    // in place would rewrite the entry.
    for i in 0..miss.len() {
        let mut op = opaths.at(miss[i] as usize).clone();
        let _ = unsafe shim::sc_unlink(op.cstr());
    }
    let rc = run_jobs(cc, flags, aroot.as_str(), units, root, objdir.as_str(), &opaths, &miss, &mut vpid);
    if rc != 0 {
        return rc;
    }
    if fresh {
        cache_keys(&known, ccs.as_str(), &mut vpid, vf.as_str(), cc, flags, aroot.as_str(), ns, &hs, &ok, &mut cobjs);
    }
    for i in 0..miss.len() {
        let u = miss[i] as usize;
        let cobj = cobjs.at(u);
        if cobj.len() == 0 {
            continue;
        }
        // A temp of this process, then a rename: concurrent builds installing the same key each
        // move a whole object into place, and a reader opens either one.
        mkdir_p(loader::dirname_of(cobj.as_str()));
        let mut tmp = format("{}.{}.tmp", cobj.as_str(), unsafe shim::sc_getpid());
        let mut dst = cobj.clone();
        if !link_or_copy(opaths.at(u).as_str(), tmp.as_str()) || unsafe shim::sc_rename(tmp.cstr(), dst.cstr()) != 0 {
            let _ = unsafe shim::sc_unlink(tmp.cstr());
        }
    }
    for i in 0..opaths.len() {
        objs.push(opaths.at(i).clone());
    }
    return 0;
}

// Take the version line: `known` (recorded for compiler command `ccs`), else the probe `vpid`'s
// (spawned into file `vf`; -1 = not started or already waited for), then recorded. Fill `cobjs` with every unit's cache entry under namespace `ns`: the key of the version line,
// the compiler command `cc` (its own arguments, `-arch x86_64` say, change the output and not the
// version line), the compile `flags`, the tree path `aroot` when the flags record it, and the unit's
// hash pair in `hs`; empty for a unit whose `ok` is false.
fn cache_keys(
    known: &String,
    ccs: str,
    vpid: &mut i64,
    vf: str,
    cc: &Vector<String>,
    flags: &Vector<String>,
    aroot: str,
    ns: str,
    hs: &Vector<u64>,
    ok: &Vector<bool>,
    cobjs: &mut Vector<String>,
) {
    let mut ccver = known.clone();
    if ccver.len() == 0 {
        if *vpid >= 0 {
            let mut code: i32 = 0;
            let _ = unsafe shim::sc_waitpid(*vpid, &mut code);
            *vpid = -1;
        }
        ccver = take_first_line(vf).unwrap_or(String::new());
        ccver_record(ccs, &ccver);
    }
    let mut b1 = FNV_BASIS;
    let mut b2: u64 = 0x9e3779b97f4a7c15;
    ch_mix_bytes(&mut b1, &mut b2, ccver.as_str().ptr(), ccver.len());
    for i in 0..cc.len() {
        let w = cc.at(i).as_str();
        ch_mix_bytes(&mut b1, &mut b2, w.ptr(), w.len());
        ch_mix_bytes(&mut b1, &mut b2, "\n".ptr(), 1);
    }
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
            let mut name = String::new();
            hex64(h1, &mut name);
            hex64(h2, &mut name);
            name.push_str(".o");
            cobj = script_entry(ns, name.as_str());
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

/// Record a use of cache entry `cobj`: the trims delete the least recently used entries first.
pub fn touch_entry(cobj: str) {
    let mut o = String::from_str(cobj);
    let _ = unsafe shim::sc_touch(o.cstr());
}

// One object entry `<key>.o` of the cache, as `trim_objects` lists it.
struct Entry {
    pub path: String,
    pub id: u64, // the file's identity: one object is one file under every name (`link_or_copy`)
    pub links: i32,
    pub size: i64,
    pub mt: i64, // its install or last use (`touch_entry`)
}

// One object of a trim: its last use and its index in the listing.
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

/// Trim the object namespaces below `od` (`<root>/o` of one cache root). An entry is unused when no
/// build tree links it: every name of its file is a cache entry (an engine build installs one file as
/// its tree's entry and the shared one). `clean` (`super-c clean`) deletes every unused file. Otherwise
/// the unused files go, least recently used first, each with all its names, only beyond two limits:
/// the root's files hold at most `budget` bytes (a project's `cache-size`), and once there are more
/// than `max` of them, at most `keep` (the script builds' root). A deleted entry takes its dependency
/// list; a list whose object is gone goes too, as do the packed `<key>.z` entries of older compilers
/// and temp files older than TMP_IDLE. An entry deleted under a build is compiled again by the next
/// build that needs it, never read torn.
pub fn trim_objects(od: str, now: i64, budget: u64, max: usize, keep: usize, clean: bool) {
    let mut es = Vector::<Entry>::new();
    let nss = list_dir(od, false).unwrap_or(Vector::<String>::new());
    for i in 0..nss.len() {
        let nm = nss.at(i).as_str();
        if nm.starts_with(".") {
            continue; // the sweep stamp
        }
        let ns = loader::join2(od, nm);
        if nm == SCRIPT_NS {
            list_script(ns.as_str(), now, &mut es);
        } else {
            list_entries(ns.as_str(), now, &mut es);
        }
    }
    // Each file once: its names (entries), its size, and whether it is unused.
    let mut names_of = Map::<u64, i32>::new();
    for i in 0..es.len() {
        let c = switch names_of.get(&es[i].id) {
            Some(v) => *v,
            None => 0,
        };
        names_of.insert(es[i].id, c + 1);
    }
    let mut seen = Set::<u64>::new();
    let mut total: u64 = 0;
    let mut files: usize = 0;
    let mut cand = Vector::<ObjUse>::new();
    for i in 0..es.len() {
        if seen.contains(&es[i].id) {
            continue;
        }
        seen.insert(es[i].id);
        total += es[i].size as u64;
        files += 1;
        if *names_of.get(&es[i].id).unwrap() == es[i].links {
            cand.push(ObjUse { mt: es[i].mt, at: i });
        }
    }
    let mut drop = Set::<u64>::new();
    if clean {
        for k in 0..cand.len() {
            drop.insert(es[cand[k].at].id);
        }
    } else if total > budget || files > max {
        cand.sort_by(obj_use_older);
        let cap = pick(files > max, keep, files);
        let mut left = files;
        for k in 0..cand.len() {
            if total <= budget && left <= cap {
                break;
            }
            let e = es.at(cand[k].at);
            drop.insert(e.id);
            total -= e.size as u64;
            left -= 1;
        }
    }
    if drop.len() == 0 {
        return;
    }
    for i in 0..es.len() {
        if drop.contains(&es[i].id) {
            remove_entry(es.at(i));
        }
    }
}

// Delete entry `e` and its dependency list.
fn remove_entry(e: &Entry) {
    let mut o = e.path.clone();
    let _ = unsafe shim::sc_unlink(o.cstr());
    o.truncate(o.len() - 1);
    o.push_str("d");
    let _ = unsafe shim::sc_unlink(o.cstr());
}

// List the script namespace `ns` (the layout of `script_entry`) into `es`. An entry directly in `ns` (a
// compiler before the subdirectories) moves to its subdirectory first.
fn list_script(ns: str, now: i64, es: &mut Vector<Entry>) {
    let top = list_dir(ns, false).unwrap_or(Vector::<String>::new());
    for i in 0..top.len() {
        let n = top.at(i).as_str();
        let mut p = loader::join2(ns, n);
        if n.len() == 34 && key_prefixed(n) {
            mkdir_p(loader::join2(ns, n.slice(0, 2)).as_str());
            let mut to = script_entry(ns, n);
            let _ = unsafe shim::sc_rename(p.cstr(), to.cstr());
        } else if n.ends_with(".tmp") && now - unsafe shim::sc_mtime(p.cstr()) >= TMP_IDLE {
            let _ = unsafe shim::sc_unlink(p.cstr());
        }
    }
    let subs = list_dir(ns, false).unwrap_or(Vector::<String>::new());
    for s in 0..subs.len() {
        if subs.at(s).len() == 2 {
            list_entries(loader::join2(ns, subs.at(s).as_str()).as_str(), now, es);
        }
    }
}

// List the objects of directory `dir` into `es`; delete there a dependency list whose object is gone, a
// packed `<key>.z` entry and a temp file older than TMP_IDLE.
fn list_entries(dir: str, now: i64, es: &mut Vector<Entry>) {
    let mut names = list_dir(dir, false).unwrap_or(Vector::<String>::new());
    // Sorted, `<key>.d` comes right before `<key>.o`.
    names.sort();
    for i in 0..names.len() {
        let n = names.at(i).as_str();
        let mut p = loader::join2(dir, n);
        let key = n.len() == 34 && key_prefixed(n);
        if n.ends_with(".tmp") {
            if now - unsafe shim::sc_mtime(p.cstr()) >= TMP_IDLE {
                let _ = unsafe shim::sc_unlink(p.cstr());
            }
        } else if key && n.ends_with(".z") {
            let _ = unsafe shim::sc_unlink(p.cstr());
        } else if key && n.ends_with(".d") {
            let next = if i + 1 < names.len() {
                names.at(i + 1).as_str();
            } else {
                "";
            };
            if !(next.len() == 34 && next.starts_with(n.slice(0, 33)) && next.ends_with(".o")) {
                let _ = unsafe shim::sc_unlink(p.cstr());
            }
        } else if key && n.ends_with(".o") {
            let mut e = Entry { path: p };
            e.links = unsafe shim::sc_file_links(e.path.cstr(), &mut e.id, &mut e.size, &mut e.mt);
            if e.links > 0 {
                es.push(e);
            }
        }
    }
}
