// The build cache shared by the build engine and script builds: its base and each project's root (the
// prelude images live there), the 128-bit key mix, and the executable search of PATH. Its retention
// lives in build_system::build (`sweep`).
import stdlib;
import driver_shim as shim;
import std::platform::fs;
import std::platform::process;
import module::loader as loader;
import ast::ast as *;
import driver::util as *;
import target::table as tgt;

/// A temp file an interrupted install left behind is removed after this many seconds.
pub const TMP_IDLE: i64 = 3600;
/// The cache root of project `project` (`cache_root`), or empty when caching is disabled
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
/// `<base>/<project>` (`project_dir`), so each project's sweep sees only its own files; empty when no
/// base resolves. The prelude images live under `prelude`.
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

/// Mix `n` bytes at `p` into the two key lanes. Two independent lanes: a cached result served for the
/// WRONG key would be silently wrong output, so the key is 128 bits, not 64.
pub const fn ch_mix_bytes(h1: &mut u64, h2: &mut u64, p: *const u8, n: usize) {
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
    let win = PLATFORM == Platform::Windows;
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
                            let mt = file_mtime(cand.as_str());
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
    return file_mtime(cand.as_str());
}

/// The developer directory `xcode-select` chose (the target of `/var/db/xcode_select_link`); empty when
/// none is set.
pub fn xcode_select_dir() String {
    return fs::readlink("/var/db/xcode_select_link").unwrap_or(String::new());
}
