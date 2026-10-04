// build.toml engine: transpile the root's module closure into <out-dir>/<profile>/raw, content-sync it
// into <out-dir>/<profile>/gen (unchanged files keep their mtime), compile stale objects in parallel with
// -MMD dep tracking into <out-dir>/<profile>/obj, link, then optionally strip. `super-c command <name>`
// and `super-c clean` live here too.
//
// Process discipline: every compiler, linker, archiver, strip, probe, and git invocation is an argv
// child (sc_spawn_argv, no shell), so paths pass through verbatim: spaces, quotes, non-ASCII. The
// ONE shell survivor is `super-c command`, whose manifest lines are sh/cmd syntax by user contract. Flag
// STRINGS keep their historic whitespace-splitting. compile_commands.json (one `arguments` row per
// TU) lands beside gen/obj; .cmd fingerprints, the link record, and the emit stamp write through
// temp + atomic rename. Toolchain contract is a gcc-style driver (cc/clang/gcc; mingw on Windows):
// -MMD/-c/-o are assumed, so MSVC's cl.exe is out of contract and has no /showIncludes lane.
import stdio;
import stdlib;
import time;
import driver_shim as shim;
import driver::stats as bst;
import std::parallel::platform as platform;
import std::parallel::runtime as prt;
import module::loader as loader;
import ir::inline as inl;
import ir::interp as iri;
import driver::emit as *;
import driver::util as *;
import build_system::manifest as mf;
import build_system::objcache as *;
import build_system::probe as pr;
import ast::parser as par;
import lsp::json as json;

// A failed child's captured output is replayed up to this many bytes; the file keeps the rest.
const LOG_LIMIT: usize = 65536;

fn cat_file_bounded(path: str, limit: usize) {
    let f = stdio::fopen(path, "rb");
    if f == null {
        return;
    }
    let mut buf = Array::<char, 4096>::new();
    let mut shown: usize = 0;
    let mut dropped: usize = 0;
    loop {
        let n = unsafe stdio::fread(&mut buf[0], 1, 4096, f);
        if n == 0 {
            break;
        }
        if shown < limit {
            let take = if shown + n > limit {
                limit - shown;
            } else {
                n;
            };
            unsafe stdio::fwrite(&buf[0], 1, take, stdio::stderr());
            shown += take;
            dropped += n - take;
        } else {
            dropped += n;
        }
    }
    unsafe stdio::fclose(f);
    if dropped != 0 {
        eprintln("build: ... {} more byte(s) in {}", dropped, path);
    }
}

// Recursively collect regular files under dir as paths relative to `base` (no leading '/').
fn walk_files(dir: str, base_len: usize, out: &mut Vector<String>) {
    let names = list_dir(dir, false).unwrap_or(Vector::<String>::new());
    for i in 0..names.len() {
        let mut p = loader::join2(dir, names.at(i).as_str());
        if unsafe shim::sc_stat_isdir(p.cstr()) == 1 {
            walk_files(p.as_str(), base_len, out);
        } else {
            let full = p.as_str();
            out.push(String::from_str(full.slice(base_len + 1, full.len())));
        }
    }
}

// `walk_files` over a generated tree: a `.c` or `.h` name there is a file, so only other names cost
// a stat (the tree holds one definition header per type).
fn walk_gen_files(dir: str, base_len: usize, out: &mut Vector<String>) {
    let names = list_dir(dir, false).unwrap_or(Vector::<String>::new());
    for i in 0..names.len() {
        let nm = names.at(i).as_str();
        let mut p = loader::join2(dir, nm);
        if !nm.ends_with(".c") && !nm.ends_with(".h") && unsafe shim::sc_stat_isdir(p.cstr()) == 1 {
            walk_gen_files(p.as_str(), base_len, out);
        } else {
            let full = p.as_str();
            out.push(String::from_str(full.slice(base_len + 1, full.len())));
        }
    }
}

fn contains(v: &Vector<String>, s: str) bool {
    for i in 0..v.len() {
        if v.at(i).as_str() == s {
            return true;
        }
    }
    return false;
}

/// Recursive delete (files then directories); silently ignores a missing path. Never follows a link:
/// a POSIX symlink is unlinked and a Windows directory link or junction is removed without descending.
pub fn rm_rf(path: str) {
    let mut p = String::from_str(path);
    let isdir = unsafe shim::sc_lstat_isdir(p.cstr());
    if isdir == 2 {
        unsafe shim::sc_rmdir(p.cstr());
    } else if isdir == 1 {
        let names = list_dir(path, true).unwrap_or(Vector::<String>::new());
        for i in 0..names.len() {
            let c = loader::join2(path, names.at(i).as_str());
            rm_rf(c.as_str());
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

// The global object cache: ~/.super-c/cache, content-addressed
// A translation unit whose C text, quoted-include closure, compiler version and flags all match a
// previous compile of the same local object tree reuses that compile's object instead of running
// the C compiler again. The key hashes content, so the cache needs no invalidation story: different
// content is a different key. The content includes paths: every unit includes __sc_fwd.h, which
// names the runtime headers by absolute path, so a tree at another path gets other keys. System
// headers (<...>) are outside the key; the compiler-version fingerprint stands in for them, the same
// bet ccache's direct mode makes.
//
// Retention: each local object tree (a profile directory such as build/dev) owns the namespace
// `<root>/o/<hash of its real path>`. A successful build writes the key set of its units as a
// generation file `g<seq>` when the set changed, keeps the newest OBJ_GENS generations, and deletes
// every object and dependency list no kept generation names (`obj_cache_commit`). A daily sweep
// removes dead namespaces and idle linker caches (`cache_sweep`).
// The key, the cache root and the namespace that script builds share live in build_system::objcache.

/// The generations an object cache namespace keeps: the current build and three older ones.
const OBJ_GENS: usize = 4;
/// A namespace whose owner directory exists is removed after this many seconds with no entry
/// changed (a build refreshes its current generation at most daily).
const OBJ_NS_IDLE: i64 = 30 * 86400;
/// A linker cache namespace is removed after this many seconds with no entry written or used.
const LTO_NS_IDLE: i64 = 7 * 86400;

/// The object cache namespace of the local object tree `pdir` below cache root `root`:
/// `<root>/o/<hash of pdir's real path>`. Empty when `root` is empty (caching disabled).
fn obj_cache_ns(root: str, pdir: str) String {
    if root.len() == 0 {
        return String::new();
    }
    let rp = real_path(pdir);
    let mut out = loader::join2(root, "o/");
    hex64(
        fnv_cont(
            FNV_BASIS,
            if rp.len() != 0 {
                rp.as_str();
            } else {
                pdir;
            },
        ),
        &mut out,
    );
    return out;
}

/// The newest mtime of `dir` and its entries (0 when `dir` is missing).
fn newest_mtime(dir: str) i64 {
    let mut d = String::from_str(dir);
    let mut best = unsafe shim::sc_mtime(d.cstr());
    let names = list_dir(dir, false).unwrap_or(Vector::<String>::new());
    for i in 0..names.len() {
        let mut p = loader::join2(dir, names.at(i).as_str());
        let mt = unsafe shim::sc_mtime(p.cstr());
        if mt > best {
            best = mt;
        }
    }
    return best;
}

/// The generation file `g<seq>` of namespace `ns`.
fn gen_path(ns: str, seq: u64) String {
    let mut p = loader::join2(ns, "g");
    p.push_u64(seq);
    return p;
}

const fn seq_desc(a: &u64, b: &u64) i32 {
    if *a > *b {
        return -1;
    }
    if *a < *b {
        return 1;
    }
    return 0;
}

/// Insert every line of generation text `text` into `live`.
fn add_keys(live: &mut Set<String>, text: str) {
    let mut a: usize = 0;
    for i in 0..text.len() {
        if text[i] == b'\n' {
            if i > a {
                live.insert(String::from_str(text.slice(a, i)));
            }
            a = i + 1;
        }
    }
}

/// Record the cache keys `keys` of a successful build in namespace `ns` and trim the namespace.
/// A changed key set becomes the next generation; an unchanged set trims nothing and only refreshes
/// its generation's mtime once a day (the age `cache_sweep` reads), so a no-op build reads one
/// directory and one file. The trim keeps the newest OBJ_GENS generations and deletes each object
/// and dependency list none of them names. Only builds of this object tree write the namespace, and
/// every object this build installed is in `keys`. A restore that loses a race with the trim cannot
/// open the file and compiles instead. A failed step leaves its files to the next trim. `src_dir`
/// is the source directory recorded as the namespace owner.
fn obj_cache_commit(ns: str, keys: &mut Vector<String>, src_dir: str, now: i64) {
    let lo = list_dir(ns, false);
    if lo.is_none() {
        return;
    }
    let names = lo.unwrap();
    keys.sort();
    let mut text = String::new();
    for i in 0..keys.len() {
        if i == 0 || keys.at(i).as_str() != keys.at(i - 1).as_str() {
            text.push_string(keys.at(i));
            text.push_byte(b'\n');
        }
    }
    let mut seqs = Vector::<u64>::new();
    let mut has_owner = false;
    for i in 0..names.len() {
        let n = names.at(i).as_str();
        if n == "owner" {
            has_owner = true;
        } else if n.len() > 1 && n.len() <= 12 && n[0] == b'g' {
            let s = n.slice(1, n.len()).parse_u64();
            if !s.is_none() {
                seqs.push(s.unwrap());
            }
        }
    }
    seqs.sort_by(seq_desc);
    let mut next: u64 = 1;
    if seqs.len() != 0 {
        next = seqs[0] + 1;
        let mut gp = gen_path(ns, seqs[0]);
        let old = loader::read_file(gp.as_str());
        if !old.is_none() {
            let ob = old.unwrap();
            if ob.as_str() == text.as_str() {
                if now - unsafe shim::sc_mtime(gp.cstr()) >= 86400 {
                    let _ = write_file_atomic(gp.as_str(), text.as_str());
                }
                return;
            }
        }
    }
    let gp = gen_path(ns, next);
    if !write_file_atomic(gp.as_str(), text.as_str()) {
        return;
    }
    if !has_owner {
        let own = real_path(src_dir);
        if own.len() != 0 {
            let op = loader::join2(ns, "owner");
            let _ = write_file_atomic(op.as_str(), own.as_str());
        }
    }
    let mut live = Set::<String>::new();
    add_keys(&mut live, text.as_str());
    for i in 0..seqs.len() {
        let mut p = gen_path(ns, seqs[i]);
        if i + 1 < OBJ_GENS {
            let g = loader::read_file(p.as_str());
            if !g.is_none() {
                let gb = g.unwrap();
                add_keys(&mut live, gb.as_str());
            }
        } else {
            let _ = unsafe shim::sc_unlink(p.cstr());
        }
    }
    for i in 0..names.len() {
        let n = names.at(i).as_str();
        let mut p = loader::join2(ns, n);
        if n.ends_with(".tmp") {
            if now - unsafe shim::sc_mtime(p.cstr()) >= TMP_IDLE {
                let _ = unsafe shim::sc_unlink(p.cstr());
            }
        } else if n.len() == 34 && key_prefixed(n) {
            let stem = String::from_str(n.slice(0, 32));
            if !live.contains(&stem) {
                let _ = unsafe shim::sc_unlink(p.cstr());
            }
        }
    }
}

/// An object namespace no build reads again: its owner directory is gone, or nothing in it
/// (generations, owner record, objects) changed for OBJ_NS_IDLE.
fn ns_dead(ns: str, now: i64) bool {
    let op = loader::join2(ns, "owner");
    let own = loader::read_file(op.as_str());
    if !own.is_none() {
        let ob = own.unwrap();
        let mut od = String::from_str(ob.as_str());
        if unsafe shim::sc_mtime(od.cstr()) == 0 {
            return true;
        }
    }
    return now - newest_mtime(ns) >= OBJ_NS_IDLE;
}

/// At most once a day (the mtime of `<root>/o/.sweep`), delete what no build reads again: dead object
/// namespaces (`ns_dead`), linker cache namespaces with no entry written or used for LTO_NS_IDLE (a
/// toolchain upgrade leaves the old one behind), and the flat `<key>.o`/`<key>.d` files that
/// compilers before namespaces installed directly in the root.
fn cache_sweep(root: str, now: i64) {
    let od = loader::join2(root, "o");
    let mut stamp = loader::join2(od.as_str(), ".sweep");
    let last = unsafe shim::sc_mtime(stamp.cstr());
    if last != 0 && now - last < 86400 {
        return;
    }
    mkdir_p(od.as_str());
    let mut body = String::new();
    body.push_i64(now);
    if !write_file_atomic(stamp.as_str(), body.as_str()) {
        return;
    }
    let nss = list_dir(od.as_str(), false).unwrap_or(Vector::<String>::new());
    for i in 0..nss.len() {
        let ns = loader::join2(od.as_str(), nss.at(i).as_str());
        if ns_dead(ns.as_str(), now) {
            rm_rf(ns.as_str());
        }
    }
    let ld = loader::join2(root, "lto");
    let ltos = list_dir(ld.as_str(), false).unwrap_or(Vector::<String>::new());
    for i in 0..ltos.len() {
        let lp = loader::join2(ld.as_str(), ltos.at(i).as_str());
        if now - newest_mtime(lp.as_str()) >= LTO_NS_IDLE {
            rm_rf(lp.as_str());
        }
    }
    let flat = list_dir(root, false).unwrap_or(Vector::<String>::new());
    for i in 0..flat.len() {
        if key_prefixed(flat.at(i).as_str()) {
            let mut fp = loader::join2(root, flat.at(i).as_str());
            let _ = unsafe shim::sc_unlink(fp.cstr());
        }
    }
}

// The gen-tree prefix in a stored .d is replaced by `@/`, so a dependency list written in one project
// reads correctly in every other; paths outside the tree (absolute backing headers) stay as written.
fn dep_portable(s: str, gen: str) String {
    let mut out = String::new();
    let mut i: usize = 0;
    while i < s.len() {
        if i + gen.len() < s.len() && s.slice(i, i + gen.len()) == gen && s[i + gen.len()] == b'/' {
            out.push_str("@");
            i = i + gen.len();
        } else {
            out.push_byte(s[i]);
            i = i + 1;
        }
    }
    return out;
}

fn dep_local(s: str, gen: str) String {
    let mut out = String::new();
    let mut i: usize = 0;
    while i < s.len() {
        if i + 1 < s.len() && s[i] == b'@' && s[i + 1] == b'/' {
            out.push_str(gen);
            i = i + 1;
        } else {
            out.push_byte(s[i]);
            i = i + 1;
        }
    }
    return out;
}

// content-sync: <root_dir>/build -> <out>/gen. Unchanged files keep their mtime (the staleness anchor);
// orphans in gen are deleted so removed modules do not linger in the link.
// Streamed in fixed chunks: comparing never holds a second copy of the file in memory. The chunk
// stays small because the emit stream's notifications can run on a coroutine stack.
fn file_eq(a: str, b: &String) bool {
    let f = stdio::fopen(a, "rb");
    if f == null {
        return false;
    }
    let want = b.as_str();
    let mut buf = Array::<u8, 16384>::new();
    let mut off: usize = 0;
    let mut same = true;
    loop {
        let n = unsafe stdio::fread(&mut buf[0], 1, 16384, f);
        if n == 0 {
            break;
        }
        if off + n > want.len() || str::from_raw(&buf[0], n) != want.slice(off, off + n) {
            same = false;
            break;
        }
        off += n;
    }
    if unsafe stdio::ferror(f) != 0 {
        same = false;
    }
    unsafe stdio::fclose(f);
    return same && off == want.len();
}

// `synced`: the files the stream already synced this build (their bytes are equal on both sides), so
// the safety net compares only what the stream never heard about.
fn sync_tree(srcdir: str, dstdir: str, synced: &Set<String>) i32 {
    let mut rels = Vector::<String>::new();
    walk_gen_files(srcdir, srcdir.len(), &mut rels);
    for i in 0..rels.len() {
        if synced.contains(rels.at(i)) {
            continue;
        }
        let rel = rels.at(i).as_str();
        let sp = loader::join2(srcdir, rel);
        let dp = loader::join2(dstdir, rel);
        let content = loader::read_file(sp.as_str());
        if content.is_none() {
            eprintln("build: cannot read '{}'", sp.as_str());
            return 1;
        }
        let body = content.unwrap();
        if !file_eq(dp.as_str(), &body) {
            // Ensure parent dirs, then write.
            mkdir_p(loader::dirname_of(dp.as_str()));
            if !write_file(dp.as_str(), body.as_str()) {
                eprintln("build: cannot write '{}'", dp.as_str());
                return 1;
            }
        }
    }
    // Drop orphans.
    let mut live = Set::<String>::new();
    for i in 0..rels.len() {
        live.insert(rels.at(i).clone());
    }
    let mut old = Vector::<String>::new();
    walk_gen_files(dstdir, dstdir.len(), &mut old);
    for i in 0..old.len() {
        if !live.contains(old.at(i)) {
            let mut dp = loader::join2(dstdir, old.at(i).as_str());
            unsafe shim::sc_unlink(dp.cstr());
        }
    }
    return 0;
}

// Staleness: obj or its -MMD .d file missing, or any dependency in the .d file newer than the object.
// Every compile writes a .d, so an object without one has unknown header dependencies.
// Is the object older than its source or any recorded dependency? Mtimes have second granularity, so
// a file the sync rewrote in this build counts as newer whatever its mtime says: an edit landing in the
// same second its previous object was compiled would otherwise keep a stale object.
fn obj_stale(
    cpath: &mut String,
    opath: &mut String,
    dpath: str,
    rewritten: &Set<String>,
    gen: str,
    mtimes: &mut Map<String, i64>,
) bool {
    let omt = unsafe shim::sc_mtime(opath.cstr());
    if omt == 0 {
        return true;
    }
    if rewritten_dep(cpath.as_str(), rewritten, gen) {
        return true;
    }
    let dep = loader::read_file(dpath);
    if dep.is_none() {
        return true;
    }
    let d = dep.unwrap();
    let s = d.as_str();
    // Skip "target:" then walk the whitespace-separated deps in make syntax: a backslash before a line
    // break continues the list, `\ ` and `\#` stand for the character, `$$` for `$`.
    let mut i: usize = 0;
    while i < s.len() && s[i] != b':' {
        i = i + 1;
    }
    i = i + 1;
    let mut stale = false;
    let mut dep_path = String::new();
    // The end of the text ends the last path like a line break.
    while !stale && i <= s.len() {
        let c = if i < s.len() {
            s[i];
        } else {
            b'\n';
        };
        let next = if i + 1 < s.len() {
            s[i + 1];
        } else {
            0u8;
        };
        let sep = c == b' ' || c == b'\t' || c == b'\n' || c == b'\r' || c == b'\\' && (next == b'\n' || next == b'\r');
        if !sep && c != b'\\' && c != b'$' {
            // A run of plain bytes copies as one slice.
            let mut j = i + 1;
            while j < s.len() && s[j] != b' ' && s[j] != b'\t' && s[j] != b'\n' && s[j] != b'\r' && s[j] != b'\\' && s[j] != b'$' {
                j = j + 1;
            }
            dep_path.push_str(s.slice(i, j));
            i = j;
            continue;
        }
        if !sep {
            if c == b'\\' && (next == b' ' || next == b'#') || c == b'$' && next == b'$' {
                i = i + 1;
            }
            dep_path.push_byte(s[i]);
            i = i + 1;
            continue;
        }
        i = i + 1;
        if dep_path.len() != 0 {
            // Units share most headers: one stat per spelled path per build.
            let mt = switch mtimes.get(&dep_path) {
                Some(v) => *v,
                None => {
                    let v9 = unsafe shim::sc_mtime(dep_path.cstr());
                    mtimes.insert(dep_path.clone(), v9);
                    v9;
                },
            };
            stale = mt == 0 || mt > omt || rewritten_dep(dep_path.as_str(), rewritten, gen);
            dep_path.clear();
        }
    }
    return stale;
}

// Whether `path` (as the compiler's dependency list spells it) is a gen-tree file rewritten this build.
// The list spells a header through the including file's directory (`__std/../__sc_fwd.h`), so the
// path is normalized before the lookup.
fn rewritten_dep(path: str, rewritten: &Set<String>, gen: str) bool {
    if rewritten.is_empty() || path.len() <= gen.len() + 1 || !path.starts_with(gen) || path[gen.len()] != b'/' {
        return false;
    }
    let mut rel = String::new();
    norm_path(path.slice(gen.len() + 1, path.len()), &mut rel);
    return rewritten.contains(&rel);
}

// The build itself
// The compiler named by manifest/$CC/default, WITHOUT the ccache decision (that probe costs a
// shell round-trip, so the engine runs it in the background: see CcStream::ensure_cc).
fn push_all(cmd: &mut String, flags: &Vector<String>) {
    for i in 0..flags.len() {
        cmd.push_byte(b' ');
        cmd.push_string(flags.at(i));
    }
}

// One display/fingerprint line for an argv (arguments containing whitespace render quoted). Feeds
// the .cmd fingerprints and error reporting; never executed, so no escaping subtleties matter.
fn render_cmd(args: &Vector<String>) String {
    let mut out = String::new();
    for i in 0..args.len() {
        if i != 0 {
            out.push_byte(b' ');
        }
        let a = args.at(i).as_str();
        let mut plain = a.len() != 0;
        for k in 0..a.len() {
            if a[k] == b' ' || a[k] == b'\t' || a[k] == b'"' {
                plain = false;
            }
        }
        if plain {
            out.push_str(a);
        } else {
            out.push_byte(b'"');
            out.push_str(a);
            out.push_byte(b'"');
        }
    }
    return out;
}

// Profile flags, minus what the target cannot honour. mingw ships no libasan/libubsan, so the built-in
// dev/debug profiles' `-fsanitize*` would fail the link on Windows: there they are dropped instead
// (SC_LEAK_CHECK, being self-hosted, still covers leaks, double frees and a realloc of a freed pointer
// there; no other use after free).
fn push_profile(cmd: &mut String, flags: &Vector<String>, target: i32, sdk: i32) {
    for i in 0..flags.len() {
        let f = flags.at(i).as_str();
        // Mingw ships no libasan/libubsan, and neither do the iOS, Android or wasm toolchains as used
        // here: the sanitizer flags would fail the link, so they are dropped (SC_LEAK_CHECK still works).
        if (target == 0 || sdk != 0) && f.starts_with("-fsanitize") {
            continue;
        }
        cmd.push_byte(b' ');
        cmd.push_str(f);
    }
}

// The profile's `opt-level` flag, then its flag array (`push_profile`), so an explicit `-O` in the
// array still wins; `wl` renders each `link-args` entry through the driver. The compile side of a
// profile without overflow checks defines SC_ARITH_WRAP (super_rt.h's arithmetic helpers).
fn push_profile_side(cmd: &mut String, prof: &mf::Profile, flags: &Vector<String>, wl: bool, target: i32, sdk: i32) {
    let of = mf::opt_flag(prof.opt);
    if of.len() != 0 {
        cmd.push_byte(b' ');
        cmd.push_str(of);
    }
    if !wl && prof.arith_wraps() {
        cmd.push_str(" -DSC_ARITH_WRAP");
    }
    push_profile(cmd, flags, target, sdk);
    if wl {
        for i in 0..prof.link_args.len() {
            cmd.push_str(" -Wl,");
            cmd.push_string(prof.link_args.at(i));
        }
    }
}

/// The names of `m`'s profiles: the ones a PROFILE comparison may name.
pub fn profile_names(m: &mf::Manifest) Vector<String> {
    let mut out = Vector::<String>::new();
    for i in 0..m.profiles.len() {
        out.push(String::from_str(m.profiles.at(i).name));
    }
    return out;
}

/// The built-in flags for profile `name`, as one command-line fragment (cflags then ldflags), for a build
/// with no manifest to read them from: `super-c release foo.spc`. `compile_only` keeps the compile side
/// alone (cflags and the LTO mode), what each separate compile of a cached script build takes; the link
/// takes the whole fragment. Empty for an unknown name, so an unrecognised `--profile=` degrades to the
/// plain build rather than failing. `target` drops what that target cannot honour, exactly as a manifest
/// build does.
pub fn profile_flags(name: str, target: i32, sdk: i32, compile_only: bool) String {
    let mut out = String::new();
    if name.len() == 0 {
        return out;
    }
    let m = mf::builtins_only();
    let pi = m.profile_index(name);
    if pi >= 0 {
        let prof = m.profiles.at(pi as usize);
        push_profile_side(&mut out, prof, &prof.cflags, false, target, sdk);
        if !compile_only {
            push_profile_side(&mut out, prof, &prof.ldflags, true, target, sdk);
        }
        // A script build links once, with no link record to relink against, so a ThinLTO request has
        // no probe here and keeps the automatic mode.
        let lf = mf::lto_flag(
            if prof.lto == mf::LTO_THIN {
                mf::LTO_AUTO;
            } else {
                prof.lto;
            },
        );
        if lf.len() != 0 {
            out.push_byte(b' ');
            out.push_str(lf);
        }
    }
    return out;
}

/// The linker cache namespace schema, also part of the probe record's key: bump when the emitted C
/// changes shape in a way that must not share a namespace with, or reuse the verdict of, an older
/// compiler.
const LTO_SCHEMA: u32 = 1;

// Field `idx` of `s` split at byte `sep`; the last field runs to the end, and a missing one is empty.
fn field_of(s: str, sep: u8, idx: usize) str {
    let mut a: usize = 0;
    let mut k: usize = 0;
    for i in 0..s.len() {
        if s[i] == sep {
            if k == idx {
                return s.slice(a, i);
            }
            k += 1;
            a = i + 1;
        }
    }
    if k == idx {
        return s.slice(a, s.len());
    }
    return s.slice(0, 0);
}

/// The executable the first word of `cmd` names: as given when it has a directory part, else the
/// first PATH entry holding it (`.exe` too on a Windows host). Returns its mtime; 0 when unresolved
/// (`out` then holds the bare word).
fn which_path(cmd: str, out: &mut String) i64 {
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
        let pe = stdlib::getenv("PATH");
        if pe != null {
            let path = str::from_cstr(pe);
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

/// The linker a `-v` link log names: the last child command line (a leading space, then the
/// program, quoted by clang and bare by gcc) whose program exists. Writes `ld\t<path>\t<mtime>`.
fn linker_of_log(path: str, out: &mut String) {
    let body = loader::read_file(path);
    if body.is_none() {
        return;
    }
    let b = body.unwrap();
    let s = b.as_str();
    let mut a: usize = 0;
    for i in 0..s.len() + 1 {
        if i == s.len() || s[i] == b'\n' {
            if i > a + 1 && s[a] == b' ' {
                let mut x = a + 1;
                let q = s[x] == b'"';
                if q {
                    x += 1;
                }
                let mut y = x;
                while y < i && s[y] != b'\n' && s[y] != b'\r' && if q {
                    s[y] != b'"';
                } else {
                    s[y] != b' ';
                } {
                    y += 1;
                }
                let mut prog = String::from_str(s.slice(x, y));
                let mt = unsafe shim::sc_mtime(prog.cstr());
                if mt != 0 {
                    out.clear();
                    out.push_str("ld\t");
                    out.push_string(&prog);
                    out.push_byte(b'\t');
                    out.push_i64(mt);
                }
            }
            a = i + 1;
        }
    }
}

/// A ThinLTO cache entry (`llvmcache-<hash>`) exists directly under `dir`.
fn cache_has_entry(dir: str) bool {
    let mut files = Vector::<String>::new();
    walk_files(dir, dir.len(), &mut files);
    for i in 0..files.len() {
        if files.at(i).as_str().starts_with("llvmcache-") {
            return true;
        }
    }
    return false;
}

/// The linker cache options of `form` (1 Apple ld, 2 lld, 3 the LLVM gold plugin under gold or
/// bfd) for cache directory `dir`, through the compiler driver. Every form bounds the cache itself:
/// entries unused for a week go, the cache stays under a tenth of the disk (lld and gold: also under
/// 1 GiB; Apple ld has only the relative limit), checked at most hourly.
/// The directory is one verbatim argument (never split).
fn lto_cache_args(form: i32, dir: str, out: &mut Vector<String>) {
    if form == 1 {
        let mut a = String::from_str("-Wl,-cache_path_lto,");
        a.push_str(dir);
        out.push(a);
        push_arg(out, "-Wl,-prune_interval_lto,3600");
        push_arg(out, "-Wl,-prune_after_lto,604800");
        push_arg(out, "-Wl,-max_relative_cache_size_lto,10");
    } else if form == 2 {
        let mut a = String::from_str("-Wl,--thinlto-cache-dir=");
        a.push_str(dir);
        out.push(a);
        push_arg(
            out,
            "-Wl,--thinlto-cache-policy=prune_interval=1h:prune_after=168h:cache_size=10%:cache_size_bytes=1g",
        );
    } else {
        let mut a = String::from_str("-Wl,-plugin-opt,cache-dir=");
        a.push_str(dir);
        out.push(a);
        push_arg(
            out,
            "-Wl,-plugin-opt,cache-policy=prune_interval=1h:prune_after=168h:cache_size=10%:cache_size_bytes=1g",
        );
    }
}

// A command fingerprint ends with the toolchain probe results the build used (`Probes::mark_used`), if any.
fn push_used(fp: &mut String, used: &String) {
    if used.len() != 0 {
        fp.push_str(" | probes ");
        fp.push_string(used);
    }
}

// A stale translation unit waiting for a worker slot.
struct Pend {
    pub args: Vector<String>, // full compile argv (no shell; the spawn API captures the log)
    pub fp: String, // fingerprint: cc version + the command driving the object
    pub log: String,
    pub cmdpath: String, // <obj>.cmd: fingerprint, last duration, cache key (empty when not cacheable)
    pub prev_ms: i64, // last recorded duration; longest-first scheduling shrinks the tail
    pub cobj: String, // global-cache install target for the object; empty = not cacheable
    pub oout: String, // the object this compile writes (the install source)
    pub dout: String, // its .d sibling
    pub seq: usize, // queue order: the tiebreak among equal durations
}

// One in-flight compile job: its child pid plus what to record/cleanup on completion.
struct Job {
    pub pid: i64,
    pub fp: String,
    pub log: String,
    pub cmdpath: String,
    pub start_ns: u64,
    pub cobj: String, // see Pend: the global-cache install, performed on success
    pub oout: String,
    pub dout: String,
}

extend Job {
    // On success, persist fingerprint, duration and cache key, and install the object into the global
    // cache, via a temp named by key and pid + rename, so concurrent builds never write the same temp
    // file. On failure, report the exit status and replay a bounded part of the captured compiler
    // output; the log file stays for inspection (the unit's next successful compile removes it).
    // `gen` is the gen root, which the portable .d rewrite replaces.
    fn finish(self: &mut Self, code: i32, gen: str) i32 {
        let end_ns = platform::now_ns();
        bst::cc_job(self.start_ns, end_ns);
        if code != 0 {
            eprintln("build: C compile failed (exit {}); output kept at {}", code, self.log.as_str());
            cat_file_bounded(self.log.as_str(), LOG_LIMIT);
            return code;
        } else {
            let rec = format(
                "{}\n{}\n{}",
                self.fp.as_str(),
                (end_ns - self.start_ns) / 1000000,
                cache_key(self.cobj.as_str()),
            );
            let _ = write_file_atomic(self.cmdpath.as_str(), rec.as_str());
            if self.cobj.len() != 0 {
                let pid = unsafe shim::sc_getpid();
                let mut tmp = format("{}.{}.tmp", self.cobj.as_str(), pid);
                let mut oc = self.cobj.clone();
                if !copy_file(self.oout.as_str(), tmp.as_str()) || unsafe shim::sc_rename(tmp.cstr(), oc.cstr()) != 0 {
                    let _ = unsafe shim::sc_unlink(tmp.cstr());
                }
                let dep = loader::read_file(self.dout.as_str());
                if !dep.is_none() {
                    let d = dep.unwrap();
                    let port = dep_portable(d.as_str(), gen);
                    let mut dtmp = format("{}.{}.d.tmp", self.cobj.as_str(), pid);
                    let mut cd = self.cobj.clone();
                    cd.truncate(cd.len() - 2);
                    cd.push_str(".d");
                    if !write_file(dtmp.as_str(), port.as_str()) || unsafe shim::sc_rename(dtmp.cstr(), cd.cstr()) != 0 {
                        let _ = unsafe shim::sc_unlink(dtmp.cstr());
                    }
                }
            }
        }
        unsafe shim::sc_unlink(self.log.cstr());
        return code;
    }
}

// The cache key of install target `cobj` (`<namespace>/<key>.o`); empty when not cacheable.
const fn cache_key(cobj: str) str {
    let b = loader::basename_of(cobj);
    if b.len() < 2 {
        return "";
    }
    return b.slice(0, b.len() - 2);
}

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

/// MacOS and iOS are one platform family for artifact shape (Mach-O, .dylib), even though they are
/// separate `@platform` values.
pub const fn is_darwin(target: i32) bool {
    return target == 1 || target == 4;
}

/// The name a linked binary must have on `target`: Windows executables carry `.exe`, and nothing
/// supplies it for us: the engine links to `<bin>.tmp` and renames, so the C compiler never sees a name
/// without an extension to append one to. An extensionless PE cannot even be started: CreateProcess appends
/// `.exe` to a name that has none and then fails to find it. `pub` because the driver names binaries too.
pub fn exe_name(base: str, target: i32) String {
    let mut s = String::from_str(base);
    if target == 0 && !base.ends_with(".exe") {
        s.push_str(".exe");
    }
    return s;
}

// Where a profile keeps its own copy of the manifest's binary: <out-dir>/<profile>/<name>. Each profile
// links its own, so a `dev` build can never end up standing in for the release artifact: the manifest's
// `bin` is a copy INSTALLED from here, and only by the commands whose job is to produce it.
fn profile_bin(m: &mf::Manifest, prof_name: str, target: i32) String {
    let dir = loader::join2(m.out_dir.as_str(), prof_name);
    let leaf = exe_name(loader::basename_of(m.bin.as_str()), target);
    return loader::join2(dir.as_str(), leaf.as_str());
}

// Copy the profile's binary to `to`, the path the manifest calls the project's binary. A copy rather than a
// move, so the profile keeps the file its next build compares against. Written beside the target and
// renamed onto it, never written over it: truncating an executable that is currently running corrupts the
// image the OS is still paging from, and sc_rename knows how to displace a running one on Windows.
fn install_bin(from: str, to: str) i32 {
    let cur = loader::read_file(from);
    if cur.is_none() {
        eprintln("build: cannot read '{}'", from);
        return 1;
    }
    let body = cur.unwrap();
    // Byte-compare first: an unchanged binary keeps its mtime (downstream tools get make-friendly
    // timestamps).
    if file_eq(to, &body) {
        return 0;
    }
    let mut tmp = String::from_str(to);
    tmp.push_str(".tmp");
    let mut tob = String::from_str(to);
    if !write_file(tmp.as_str(), body.as_str()) {
        let _ = unsafe shim::sc_unlink(tmp.cstr());
        eprintln("build: cannot write '{}'", tmp.as_str());
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
    pub cc_tail: String, // " <cstd> <cflags> <profile cflags> -MMD -c [-flto=..]" (also the object-cache key text)
    pub ldbase: String, // " <sdk flags and libs> <ldflags> <profile ldflags>": the fixed part of the link line
    pub target: i32,
    pub lto_req: i32, // the profile's `lto` mode (SC_LTO overrides it)
    pub lto: i32, // the mode in use once ensure_cc ran: lto_req, or LTO_AUTO for a rejected ThinLTO request
    pub lto_cache: bool, // the link line names a ThinLTO cache directory
    pub lto_reason: String, // why ThinLTO or its cache was rejected; empty when both are in use
    pub lto_ld: Vector<String>, // the mode's link arguments: `-flto=..` and the linker cache options
    pub probe_cc_pid: i64, // background `ccache -V` probe; -1 = resolve synchronously on demand
    pub probe_ver_pid: i64, // background `<cc> --version` probe; -1 = resolve synchronously
    pub ccver_path: String, // <pdir>/.ccver, the version probe's output file
    pub ccprobe_path: String, // <pdir>/.ccprobe, the ccache probe's discarded output
    pub probes: pr::Probes, // the toolchain probe record and the probes this build needs
    pub cc_args: Vector<String>, // resolved compiler argv ([ccache] + cc tokens); empty until ensure_cc
    pub prefix_args: Vector<String>, // cc_args + cc_tail tokens; empty until ensure_cc
    pub ccver: String,
    pub cc_ready: bool,
    pub jobs: u32,
    pub objs: Vector<String>,
    pub pend: Vector<Pend>, // binary heap, `pend_before` order at the root
    pub window: Vector<Job>,
    pub total_c: usize,
    pub stale_n: usize,
    // `<link record>.pending`: written before the first object this build replaces (compiled or
    // restored from the object cache) and removed once a link succeeds, so a link that failed or never
    // ran is redone even when the objects' mtimes fall in the second the binary was linked.
    pub pending: String,
    pub marked: bool, // this build wrote `pending`
    pub ret: i32,
    pub cache: String, // this object tree's namespace of the global object cache; empty = disabled
    pub keys: Vector<String>, // the cache key of every planned unit that has one (`obj_cache_commit`)
    pub rewritten: Set<String>, // gen-relative files whose content changed in this build's sync
    pub mtimes: Map<String, i64>, // dependency path (as a depfile spells it) -> its mtime, stat once per build
    pub synced: Set<String>, // every gen-relative file the stream synced (equal on both sides now)
    pub made_dirs: Set<String>, // gen directories this build's sync created or verified
    pub ccdb: Vector<String>, // compile_commands.json rows, one per planned unit (stale or not)
    /// Object-cache hashing memo: file path FNV -> 1 + index of its two words in `hpool`
    /// (0 while the file is on the include path being hashed); see `ch_hash_file`.
    pub hmemo: Map<u64, u64>,
    pub hpool: Vector<u64>,
    pub ccdb_dir: String, // absolute working directory the compile argv is relative to
}

extend CcStream {
    /// Finish compiler resolution: collect the background probes (ccache presence by exit code,
    /// `cc --version` first line: both overlap the transpile), or run either synchronously when its
    /// spawn failed. No shell anywhere: the probes are argv children with captured output. Idempotent;
    /// called before the first compile command is built and again before the link line.
    pub fn ensure_cc(self: &mut Self) {
        if self.cc_ready {
            return;
        }
        self.cc_ready = true;
        let mut have_ccache = false;
        if self.probe_cc_pid >= 0 {
            let mut code: i32 = 0;
            have_ccache = unsafe shim::sc_waitpid(self.probe_cc_pid, &mut code) == 0 && code == 0;
        } else {
            let mut pa = Vector::<String>::new();
            push_arg(&mut pa, "ccache");
            push_arg(&mut pa, "-V");
            let mut pp = String::from_str(self.ccprobe_path.as_str());
            have_ccache = exec_args(&mut pa, pp.cstr()) == 0;
        }
        let mut pp2 = String::from_str(self.ccprobe_path.as_str());
        unsafe shim::sc_unlink(pp2.cstr());
        if have_ccache {
            push_arg(&mut self.cc_args, "ccache");
        }
        split_args(&mut self.cc_args, self.cc_raw.as_str());
        let mut have_ver = false;
        if self.probe_ver_pid >= 0 {
            let mut code2: i32 = 0;
            let _ = unsafe shim::sc_waitpid(self.probe_ver_pid, &mut code2);
            let v = take_first_line(self.ccver_path.as_str());
            if !v.is_none() {
                let line = v.unwrap();
                self.ccver.push_string(&line);
                have_ver = true;
            }
        }
        if !have_ver {
            let mut va = Vector::<String>::new();
            split_args(&mut va, self.cc_raw.as_str());
            push_arg(&mut va, "--version");
            self.ccver = cc_version_argv(&mut va, self.pdir.as_str());
        }
        self.probes.settle(&self.ccver);
        self.lto_resolve();
        self.probes.save();
        let lf = mf::lto_flag(self.lto);
        if lf.len() != 0 {
            self.cc_tail.push_byte(b' ');
            self.cc_tail.push_str(lf);
            push_arg(&mut self.lto_ld, lf);
        }
        self.prefix_args = clone_args(&self.cc_args);
        split_args(&mut self.prefix_args, self.cc_tail.as_str());
        if self.cache.len() != 0 {
            mkdir_p(self.cache.as_str());
        }
    }

    /// Settle the LTO mode. A ThinLTO request needs the toolchain's answer: the probe record's `thin-lto`
    /// result (the verdict, then the linker's path and mtime; the record's key holds the compiler, the
    /// target and the flags) gives it without a process while the linker is unchanged, else `lto_probe`
    /// measures it. A rejected request keeps `-flto=auto`, the mode the profiles used before ThinLTO,
    /// and `lto_reason` names why. The verdict joins the build's used probe results. The linker cache
    /// directory is `<cache root>/lto/<hash of the key below and the linker line>`: one namespace per
    /// compiler, linker, target, flag set and schema, pruned by the linker itself (`lto_cache_args`).
    fn lto_resolve(self: &mut Self) {
        self.lto = self.lto_req;
        if self.lto_req != mf::LTO_THIN {
            return;
        }
        let mut key = String::from_str("sc-lto ");
        key.push_u64(LTO_SCHEMA);
        key.push_byte(b'\t');
        key.push_string(&self.ccver);
        key.push_byte(b'\t');
        let mut ccpath = String::new();
        let ccmt = which_path(self.cc_raw.as_str(), &mut ccpath);
        key.push_string(&ccpath);
        key.push_byte(b'\t');
        key.push_i64(ccmt);
        key.push_byte(b'\t');
        key.push_i64(self.target);
        key.push_byte(b'\t');
        key.push_string(&self.cc_tail);
        key.push_byte(b'\t');
        key.push_string(&self.ldbase);
        let mut form: i32 = -2; // -2 no valid result, -1 rejected, 0 no cache, else a `lto_cache_args` form
        let mut ld = String::new();
        let rec = self.probes.res.at(pr::LTO).as_str();
        let l1 = self.probes.aux.at(pr::LTO).as_str();
        let mut ldp = String::from_str(stamp_field(l1, 1));
        let ldmt = stamp_field(l1, 2).parse_i64();
        if ldp.as_str() == "-" || !ldmt.is_none() && unsafe shim::sc_mtime(ldp.cstr()) == ldmt.unwrap() {
            if rec.starts_with("thin ") {
                let f = rec.slice(5, rec.len()).parse_i64();
                if !f.is_none() && f.unwrap() >= 0 && f.unwrap() <= 3 {
                    form = f.unwrap() as i32;
                    ld.push_str(l1);
                }
            } else if rec.starts_with("auto: ") {
                form = -1;
                self.lto_reason.push_str(rec.slice(6, rec.len()));
            }
        }
        if form == -2 {
            form = self.lto_probe(&mut ld);
        }
        self.probes.mark_used(pr::LTO);
        if form < 0 {
            self.lto = mf::LTO_AUTO;
            return;
        }
        if form == 0 || stdlib::getenv("SC_NO_LTO_CACHE") != null {
            return;
        }
        let root = cache_root();
        if root.len() == 0 {
            return;
        }
        let mut dir = loader::join2(root.as_str(), "lto/");
        hex64(fnv_cont(fnv_cont(FNV_BASIS, key.as_str()), ld.as_str()), &mut dir);
        mkdir_p(dir.as_str());
        lto_cache_args(form, dir.as_str(), &mut self.lto_ld);
        self.lto_cache = true;
    }

    /// Measure ThinLTO support with a one-function program under `<pdir>/.ltoprobe`, in the argv
    /// form a real build uses: the compile with the profile's compile tail and `-flto=thin`, the link
    /// with the fixed link flags (its `-v` log names the linker, recorded in `ld`), then the link
    /// again with each linker cache form until one produces a cache entry. Exit codes and output
    /// files decide, never version text. Records the result in the probe table and returns the cache
    /// form (0 none, 1 Apple ld, 2 lld, 3 the gold plugin), or -1 when ThinLTO is rejected, with
    /// `lto_reason` set.
    fn lto_probe(self: &mut Self, ld: &mut String) i32 {
        let dir = loader::join2(self.pdir.as_str(), ".ltoprobe");
        rm_rf(dir.as_str());
        mkdir_p(dir.as_str());
        let src = loader::join2(dir.as_str(), "p.c");
        let mut obj = loader::join2(dir.as_str(), "p.o");
        let mut exe = loader::join2(dir.as_str(), "p.out");
        let mut log = loader::join2(dir.as_str(), "log");
        let mut form: i32 = -1;
        ld.push_str("ld\t-\t0");
        if !write_file(src.as_str(), "int main(void) {\n    return 0;\n}\n") {
            self.lto_reason.push_str("cannot write the probe source");
        } else {
            let mut ca = clone_args(&self.cc_args);
            split_args(&mut ca, self.cc_tail.as_str());
            push_arg(&mut ca, "-flto=thin");
            ca.push(src.clone());
            push_arg(&mut ca, "-o");
            ca.push(obj.clone());
            if exec_args(&mut ca, log.cstr()) != 0 || unsafe shim::sc_mtime(obj.cstr()) == 0 {
                self.lto_reason.push_str("the compiler rejects -flto=thin");
            } else {
                let mut lb = clone_args(&self.cc_args);
                push_arg(&mut lb, "-o");
                lb.push(exe.clone());
                lb.push(obj.clone());
                split_args(&mut lb, self.ldbase.as_str());
                push_arg(&mut lb, "-flto=thin");
                let mut lv = clone_args(&lb);
                push_arg(&mut lv, "-v");
                if exec_args(&mut lv, log.cstr()) != 0 || unsafe shim::sc_mtime(exe.cstr()) == 0 {
                    self.lto_reason.push_str("the linker rejects -flto=thin");
                } else {
                    form = 0;
                    linker_of_log(log.as_str(), ld);
                    let cache = loader::join2(dir.as_str(), "cache");
                    // Apple ld first on Darwin; elsewhere lld, then the gold and bfd plugin.
                    for k in 0..3 {
                        let f: i32 = if is_darwin(self.target) {
                            k + 1;
                        } else {
                            (k + 1) % 3 + 1;
                        };
                        unsafe shim::sc_unlink(exe.cstr());
                        rm_rf(cache.as_str());
                        let mut fa = clone_args(&lb);
                        lto_cache_args(f, cache.as_str(), &mut fa);
                        if exec_args(&mut fa, log.cstr()) == 0 && unsafe shim::sc_mtime(exe.cstr()) != 0 && cache_has_entry(
                            cache.as_str(),
                        ) {
                            form = f;
                            break;
                        }
                    }
                    if form == 0 {
                        self.lto_reason.push_str("the linker rejects a ThinLTO cache directory with a pruning policy");
                    }
                }
            }
        }
        rm_rf(dir.as_str());
        let verdict = if form < 0 {
            format("auto: {}", self.lto_reason.as_str());
        } else {
            format("thin {}", form);
        };
        self.probes.set(pr::LTO, verdict.as_str(), ld.as_str());
        return form;
    }

    /// Sync one finished file raw -> gen (byte-compare keeps the mtime anchor); a source also gets
    /// its compile planned and the pool pumped.
    pub fn on_file(self: &mut Self, path: str, kind: i32) {
        let rel = path.slice(self.src_len + 1, path.len());
        let content = loader::read_file(path);
        if content.is_none() {
            eprintln("build: cannot read '{}'", path);
            self.ret = 1;
            return;
        }
        let body = content.unwrap();
        let dp = loader::join2(self.gen.as_str(), rel);
        if !file_eq(dp.as_str(), &body) {
            // One mkdir walk per directory per build, not one per file.
            let dir = String::from_str(loader::dirname_of(dp.as_str()));
            if !self.made_dirs.contains(&dir) {
                mkdir_p(dir.as_str());
                self.made_dirs.insert(dir);
            }
            if !write_file(dp.as_str(), body.as_str()) {
                eprintln("build: cannot write '{}'", dp.as_str());
                self.ret = 1;
                return;
            }
            self.rewritten.insert(String::from_str(rel));
        }
        self.synced.insert(String::from_str(rel));
        if kind != 1 {
            return;
        }
        self.plan_c(rel);
        self.pump();
    }

    /// Staleness + command construction for one gen-relative .c; stale units join pend, every unit's
    /// object joins the link list.
    pub fn plan_c(self: &mut Self, rel: str) {
        self.ensure_cc();
        self.total_c = self.total_c + 1;
        let mut cpath = loader::join2(self.gen.as_str(), rel);
        let mut opath = loader::join2(self.obj.as_str(), rel.slice(0, rel.len() - 2));
        opath.push_str(".o");
        let stem = opath.as_str().slice(0, opath.len() - 2);
        let mut dpath = String::from_str(stem);
        dpath.push_str(".d");
        let mut cmdpath = String::from_str(stem);
        cmdpath.push_str(".cmd");
        let mut args = clone_args(&self.prefix_args);
        args.push(cpath.clone());
        push_arg(&mut args, "-o");
        args.push(opath.clone());
        let mut fp = self.ccver.clone();
        fp.push_str(" | ");
        let rendered = render_cmd(&args);
        fp.push_string(&rendered);
        push_used(&mut fp, &self.probes.used);
        // compile_commands.json row (every unit, stale or not): tooling attaches to the generated
        // tree through it, so it reflects the exact argv this build would run.
        {
            let mut row = String::from_str("  {\"directory\": ");
            json::dump_escaped(self.ccdb_dir.as_str(), &mut row);
            row.push_str(", \"file\": ");
            json::dump_escaped(cpath.as_str(), &mut row);
            row.push_str(", \"output\": ");
            json::dump_escaped(opath.as_str(), &mut row);
            row.push_str(", \"arguments\": [");
            for ai in 0..args.len() {
                if ai != 0 {
                    row.push_str(", ");
                }
                json::dump_escaped(args.at(ai).as_str(), &mut row);
            }
            row.push_str("]}");
            self.ccdb.push(row);
        }
        let mut fp_ok = false;
        let mut prev_ms: i64 = 0;
        let mut prev_key = String::new();
        let old = loader::read_file(cmdpath.as_str());
        if !old.is_none() {
            let ob = old.unwrap();
            let s = ob.as_str();
            fp_ok = field_of(s, b'\n', 0) == fp.as_str();
            let ms = field_of(s, b'\n', 1).parse_i64();
            if !ms.is_none() {
                prev_ms = ms.unwrap();
            }
            prev_key.push_str(field_of(s, b'\n', 2));
        }
        if !fp_ok || obj_stale(
            &mut cpath,
            &mut opath,
            dpath.as_str(),
            &self.rewritten,
            self.gen.as_str(),
            &mut self.mtimes,
        ) {
            if !self.marked {
                self.marked = true;
                if !write_file(self.pending.as_str(), "") {
                    eprintln("build: cannot write '{}'", self.pending.as_str());
                    self.ret = 1;
                }
            }
            mkdir_p(loader::dirname_of(opath.as_str()));
            let mut cobj = String::new();
            if self.cache.len() != 0 {
                let mut h1 = FNV_BASIS;
                let mut h2: u64 = 0x9e3779b97f4a7c15;
                ch_mix_bytes(&mut h1, &mut h2, self.ccver.as_str().ptr(), self.ccver.len());
                ch_mix_bytes(&mut h1, &mut h2, self.cc_tail.as_str().ptr(), self.cc_tail.len());
                if ch_hash_file(cpath.as_str(), &mut h1, &mut h2, 0, &mut self.hmemo, &mut self.hpool) {
                    let mut keyname = String::new();
                    hex64(h1, &mut keyname);
                    hex64(h2, &mut keyname);
                    self.keys.push(keyname.clone());
                    keyname.push_str(".o");
                    cobj = loader::join2(self.cache.as_str(), keyname.as_str());
                    if self.cache_restore(&cobj, opath.as_str(), dpath.as_str(), &fp) {
                        self.objs.push(opath.clone());
                        return;
                    }
                }
            }
            let mut log = opath.clone();
            log.push_str(".log");
            self.pend_push(
                Pend {
                    args: args,
                    fp: fp,
                    log: log,
                    cmdpath: cmdpath,
                    prev_ms: prev_ms,
                    cobj: cobj,
                    oout: opath.clone(),
                    dout: dpath.clone(),
                    seq: self.stale_n,
                },
            );
            self.stale_n = self.stale_n + 1;
        } else if prev_key.len() == 32 && self.cache.len() != 0 {
            // Up to date: the key its compile or restore recorded still names its object.
            self.keys.push(prev_key);
        }
        self.objs.push(opath.clone());
    }

    // A cache hit: the object and its portable dependency list copy into place, and the .cmd
    // records the fingerprint so the next build's staleness check needs no cache at all. An entry
    // without its dependency list is a miss: a restored object without a .d would never see a
    // header change (a concurrent build can publish the object before its list).
    fn cache_restore(self: &mut Self, cobj: &String, opath: str, dpath: str, fp: &String) bool {
        let mut cd = cobj.clone();
        cd.truncate(cd.len() - 2);
        cd.push_str(".d");
        let dep = loader::read_file(cd.as_str());
        if dep.is_none() || !copy_file(cobj.as_str(), opath) {
            return false;
        }
        let d = dep.unwrap();
        let loc = dep_local(d.as_str(), self.gen.as_str());
        if !write_file(dpath, loc.as_str()) {
            return false;
        }
        let mut cmdp = String::from_str(opath.slice(0, opath.len() - 2));
        cmdp.push_str(".cmd");
        let rec = format("{}\n0\n{}", fp.as_str(), cache_key(cobj.as_str()));
        let _ = write_file_atomic(cmdp.as_str(), rec.as_str());
        return true;
    }

    // The error path's counterpart of ensure_cc: reap the background probes unused and remove their
    // output files.
    fn abandon_probes(self: &mut Self) {
        if self.cc_ready {
            return;
        }
        self.cc_ready = true;
        let mut code: i32 = 0;
        if self.probe_cc_pid >= 0 {
            let _ = unsafe shim::sc_waitpid(self.probe_cc_pid, &mut code);
        }
        if self.probe_ver_pid >= 0 {
            let _ = unsafe shim::sc_waitpid(self.probe_ver_pid, &mut code);
        }
        let mut pp = String::from_str(self.ccprobe_path.as_str());
        unsafe shim::sc_unlink(pp.cstr());
        let mut vp = String::from_str(self.ccver_path.as_str());
        unsafe shim::sc_unlink(vp.cstr());
        self.probes.abandon();
    }

    /// Fill free slots (longest-known-first) and reap whatever already exited; never blocks.
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
                if j.finish(code, self.gen.as_str()) != 0 {
                    self.ret = 1;
                }
            }
            if self.pend.len() == 0 || self.window.len() as u32 >= self.jobs {
                break;
            }
            self.spawn_next();
        }
    }

    // Start the pending compile with the longest previous duration, so the slowest unit never starts
    // last. Among equal durations the earliest queued starts first.
    fn spawn_next(self: &mut Self) {
        let mut w = self.pend_pop();
        let pid = spawn_args(&mut w.args, w.log.cstr());
        if pid < 0 {
            eprintln("build: cannot spawn compiler");
            self.ret = 1;
            unsafe shim::sc_unlink(w.log.cstr());
            return;
        }
        self.window.push(
            Job {
                pid: pid,
                fp: replace(&mut w.fp, String::new()),
                log: replace(&mut w.log, String::new()),
                cmdpath: replace(&mut w.cmdpath, String::new()),
                start_ns: platform::now_ns(),
                cobj: replace(&mut w.cobj, String::new()),
                oout: replace(&mut w.oout, String::new()),
                dout: replace(&mut w.dout, String::new()),
            },
        );
    }

    fn pend_push(self: &mut Self, p: Pend) {
        self.pend.push(p);
        let mut i = self.pend.len() - 1;
        while i > 0 && pend_before(self.pend.at(i), self.pend.at((i - 1) / 2)) {
            self.pend.swap(i, (i - 1) / 2);
            i = (i - 1) / 2;
        }
    }

    fn pend_pop(self: &mut Self) Pend {
        let last = self.pend.len() - 1;
        self.pend.swap(0, last);
        let top = self.pend.pop().unwrap();
        let n = self.pend.len();
        let mut i: usize = 0;
        for _ in 0..n {
            let l = 2 * i + 1;
            let mut s = i;
            if l < n && pend_before(self.pend.at(l), self.pend.at(s)) {
                s = l;
            }
            if l + 1 < n && pend_before(self.pend.at(l + 1), self.pend.at(s)) {
                s = l + 1;
            }
            if s == i {
                break;
            }
            self.pend.swap(i, s);
            i = s;
        }
        return top;
    }

    /// Run everything left to completion (blocking): only called once the emit workers are gone, so
    /// sc_wait_any's waitpid(-1) cannot reap anything but our compile jobs. `discard` abandons units
    /// not yet started: the error path, which still must reap what is in flight.
    pub fn drain(self: &mut Self, discard: bool) {
        if discard {
            self.pend.truncate(0);
            self.abandon_probes();
        }
        while self.pend.len() != 0 || self.window.len() != 0 {
            while self.pend.len() != 0 && self.window.len() as u32 < self.jobs {
                self.spawn_next();
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
            if j.finish(code, self.gen.as_str()) != 0 {
                self.ret = 1;
            }
        }
    }
}

// Longest previous duration first; among equal durations the earliest queued.
const fn pend_before(a: &Pend, b: &Pend) bool {
    return a.prev_ms > b.prev_ms || a.prev_ms == b.prev_ms && a.seq < b.seq;
}

fn stream_notify(ctx: *mut void, path: str, kind: i32) {
    let s = ctx as *mut CcStream;
    unsafe (*s).on_file(path, kind);
}

// Emit stamp: skip the whole transpile when no input changed since the last successful emission.
// The stamp records every input the emitted tree is a function of: the emitting compiler (its content
// hash, `compiler_id`), the emission-relevant options, and every loaded module file, the manifest and
// every external C input as (mtime, fnv64, len). A per-module skip would be UNSOUND here (owner-emitted instances and the
// shared headers make every TU depend on the whole import closure); the whole-package check is
// exact. mtime is only the fast path: a drifted mtime with matching content still counts as fresh
// (and refreshes the stamp), so git checkouts do not force rebuilds. SC_NO_EMIT_CACHE disables.

fn stamp_hash_file(path: str, h_out: &mut u64, len_out: &mut u64) bool {
    let f = stdio::fopen(path, "rb");
    if f == null {
        return false;
    }
    let mut buf = Array::<u8, 65536>::new();
    let mut h = FNV_BASIS;
    let mut tot: u64 = 0;
    loop {
        let n = unsafe stdio::fread(&mut buf[0], 1, 65536, f);
        if n == 0 {
            break;
        }
        tot += n as u64;
        for i in 0..n {
            h = (h ^ buf[i] as u64).wrapping_mul(1099511628211u64);
        }
    }
    unsafe stdio::fclose(f);
    *h_out = h;
    *len_out = tot;
    return true;
}

// Field `idx` of the tab-separated stamp record `line`: the whole field or `stamp_u64` as a decimal
// number (0 when it is not one: the check then fails and the stamp is rewritten).
fn stamp_field(line: str, idx: usize) str {
    return field_of(line, b'\t', idx);
}

fn stamp_u64(line: str, idx: usize) u64 {
    return stamp_field(line, idx).parse_u64().unwrap_or(0);
}

// The emitting compiler's record: its content hash (`compiler_id`), taken once before the emission.
fn stamp_exe_line(out: &mut String, cid: u64) {
    out.push_str("exe\t");
    out.push_u64(cid);
    out.push_str("\n");
}

// The number of `.c` files under `gen`. A `.c` or `.h` name is a file: only other names cost a
// stat (the tree holds one definition header per type).
fn stamp_gen_c_count(gen: str) u64 {
    let names = list_dir(gen, false).unwrap_or(Vector::<String>::new());
    let mut n: u64 = 0;
    for i in 0..names.len() {
        let nm = names.at(i).as_str();
        if nm.ends_with(".c") {
            n += 1;
        } else if !nm.ends_with(".h") {
            let mut p = loader::join2(gen, nm);
            if unsafe shim::sc_stat_isdir(p.cstr()) == 1 {
                n += stamp_gen_c_count(p.as_str());
            }
        }
    }
    return n;
}

fn stamp_push_input(out: &mut String, path: str) bool {
    let mut pp = String::from_str(path);
    let mt = unsafe shim::sc_mtime(pp.cstr());
    if mt == 0 {
        return false;
    }
    let mut h: u64 = 0;
    let mut ln: u64 = 0;
    if !stamp_hash_file(path, &mut h, &mut ln) {
        return false;
    }
    stamp_line(out, "in\t", mt as u64, h, ln, path);
    return true;
}

// One stamp record: `kind` (with its tab), then mtime, hash, the length when `kind` is "in\t", and path.
fn stamp_line(out: &mut String, kind: str, mt: u64, h: u64, ln: u64, path: str) {
    out.push_str(kind);
    out.push_u64(mt);
    out.push_str("\t");
    out.push_u64(h);
    out.push_str("\t");
    if kind == "in\t" {
        out.push_u64(ln);
        out.push_str("\t");
    }
    out.push_str(path);
    out.push_str("\n");
}

// Order-independent hash of the `.spc` names in `dir`: the names import resolution and the prelude
// can pick up. A missing directory hashes like one with no such name.
fn stamp_dir_hash(dir: str) u64 {
    let mut d = String::from_str(dir);
    let dh = unsafe shim::sc_opendir(d.cstr());
    if dh == null {
        return 0;
    }
    let mut h: u64 = 0;
    loop {
        let e = unsafe shim::sc_readdir(dh);
        if e == null {
            break;
        }
        let nm = str::from_cstr(unsafe shim::sc_dirent_name(e));
        if !nm.ends_with(".spc") {
            continue;
        }
        h = h.wrapping_add(nm.hash());
    }
    unsafe shim::sc_closedir(dh);
    return h;
}

fn stamp_push_dir(out: &mut String, dir: str) {
    let mut dp = String::from_str(dir);
    stamp_line(out, "dir\t", (unsafe shim::sc_mtime(dp.cstr())) as u64, stamp_dir_hash(dir), 0, dir);
}

// The emission options record: target, arch, bootstrap tags, lint, the emitted C unit count, the
// root directory and the emission-mode environment switches.
fn stamp_opt_line(out: &mut String, target: i32, arch: i32, bootstrap: bool, lint: bool, ccount: u64, root_dir: str) {
    out.push_str("opt\t");
    out.push_u64(target as u64);
    out.push_str("\t");
    out.push_u64(arch as u64 & 0xFF);
    out.push_str("\t");
    out.push_u64(bootstrap as u64);
    out.push_str("\t");
    out.push_u64(lint as u64);
    out.push_str("\t");
    out.push_u64(ccount);
    out.push_str("\t");
    out.push_str(root_dir);
    // Emission-mode switches change the emitted C: a stamp written under one mode must not
    // satisfy a build under another.
    out.push_str("\t");
    for i in 0..inl::EMIT_MODE_ENV_N {
        stamp_push_env(out, inl::emit_mode_env(i));
    }
    out.push_str("\n");
}

fn stamp_push_env(out: &mut String, name: str) {
    let v = stdlib::getenv(name);
    out.push_str(";");
    if v != null {
        out.push_str(str::from_cstr(v));
    }
}

// Record the inputs of a completed emission. Written only on full success; an unreadable
// input aborts the write (no cache beats a wrong one).
fn stamp_write(
    path: str,
    p: &loader::Package,
    std_dir: str,
    root_dir: str,
    target: i32,
    arch: i32,
    bootstrap: bool,
    lint: bool,
    gen: str,
    cid: u64,
) {
    if cid == 0 {
        return;
    }
    let mut out = String::from_str("sc-emit-stamp v3\n");
    stamp_exe_line(&mut out, cid);
    stamp_opt_line(&mut out, target, arch, bootstrap, lint, stamp_gen_c_count(gen), root_dir);
    {
        // The manifest is loaded from the working directory (main.spc): its shard policy and
        // flags shape the emitted tree.
        let mut man = String::from_str("build.toml");
        if unsafe shim::sc_mtime(man.cstr()) != 0 {
            if !stamp_push_input(&mut out, man.as_str()) {
                return;
            }
        }
    }
    for i in 0..p.modules.len() {
        let f = p.modules.at(i).file.as_str();
        if f.len() == 0 {
            continue;
        }
        if !stamp_push_input(&mut out, f) {
            return;
        }
    }
    for i in 0..p.ext_inputs.len() {
        if !stamp_push_input(&mut out, p.ext_inputs.at(i).as_str()) {
            return;
        }
    }
    // Every directory import resolution listed, and the prelude's: a new `.spc` file there can shadow an
    // import (a root file beside an alt-root or std module) or join the prelude without changing any
    // input recorded above.
    for i in 0..p.dir_cache.dirs.len() {
        stamp_push_dir(&mut out, p.dir_cache.dirs.at(i).as_str());
    }
    if std_dir.len() != 0 {
        stamp_push_dir(&mut out, std_dir);
    }
    out.push_str("end\n");
    let _ = write_file_atomic(path, out.as_str());
}

// Is the recorded emission still exact for the current inputs? On mtime drift with matching
// content the stamp is refreshed in place so the next check stays on the fast path.
fn stamp_fresh(path: str, root_dir: str, target: i32, arch: i32, bootstrap: bool, lint: bool, gen: str, cid: u64) bool {
    if cid == 0 {
        return false;
    }
    let body0 = loader::read_file(path);
    if body0.is_none() {
        return false;
    }
    let body = body0.unwrap();
    let s = body.as_str();
    // Second-granularity mtimes cannot distinguish an edit made in the same second the stamp was
    // written: entries stamped within 2s of the stamp file's own mtime verify by content instead.
    let mut spb = String::from_str(path);
    let recent = unsafe shim::sc_mtime(spb.cstr()) - 2;
    let mut fresh = true;
    let mut drift = false;
    let mut saw_end = false;
    let mut ccount: u64 = 0xFFFFFFFFFFFFFFFFu64;
    let mut rewritten = String::new();
    let mut a: usize = 0;
    let mut lno: usize = 0;
    for i2 in 0..s.len() + 1 {
        if i2 != s.len() && s[i2] != b'\n' {
            continue;
        }
        let line = s.slice(a, i2);
        a = i2 + 1;
        if line.len() == 0 {
            continue;
        }
        if lno == 0 {
            if line != "sc-emit-stamp v3" {
                return false;
            }
            rewritten.push_str(line);
            rewritten.push_str("\n");
            lno += 1;
            continue;
        }
        lno += 1;
        let kind = stamp_field(line, 0);
        if kind == "exe" {
            if stamp_u64(line, 1) != cid {
                return false;
            }
            rewritten.push_str(line);
            rewritten.push_str("\n");
        } else if kind == "opt" {
            // Every field but the unit count must match this build's options.
            ccount = stamp_u64(line, 5);
            let mut want = String::new();
            stamp_opt_line(&mut want, target, arch, bootstrap, lint, ccount, root_dir);
            if want.as_str().slice(0, want.len() - 1) != line {
                return false;
            }
            rewritten.push_string(&want);
        } else if kind == "in" {
            let mt0 = stamp_u64(line, 1);
            let fp = stamp_field(line, 4);
            let mut pp = String::from_str(fp);
            let mt = unsafe shim::sc_mtime(pp.cstr());
            if mt == 0 {
                return false;
            }
            if mt as u64 == mt0 && mt0 < recent as u64 {
                rewritten.push_str(line);
                rewritten.push_str("\n");
                continue;
            }
            let mut h: u64 = 0;
            let mut ln: u64 = 0;
            if !stamp_hash_file(fp, &mut h, &mut ln) {
                return false;
            }
            if h != stamp_u64(line, 2) || ln != stamp_u64(line, 3) {
                fresh = false;
                break;
            }
            if mt as u64 != mt0 {
                drift = true;
            }
            stamp_line(&mut rewritten, "in\t", mt as u64, h, ln, fp);
        } else if kind == "dir" {
            let mt0 = stamp_u64(line, 1);
            let dp = stamp_field(line, 3);
            let mut dpp = String::from_str(dp);
            let mt = unsafe shim::sc_mtime(dpp.cstr());
            if mt as u64 == mt0 && mt0 < recent as u64 {
                rewritten.push_str(line);
                rewritten.push_str("\n");
                continue;
            }
            let h = stamp_dir_hash(dp);
            if h != stamp_u64(line, 2) {
                fresh = false;
                break;
            }
            if mt as u64 != mt0 {
                drift = true;
            }
            stamp_line(&mut rewritten, "dir\t", mt as u64, h, 0, dp);
        } else if kind == "end" {
            saw_end = true;
            rewritten.push_str("end\n");
        } else {
            return false;
        }
    }
    if !fresh || !saw_end {
        return false;
    }
    if ccount == 0 || stamp_gen_c_count(gen) != ccount {
        return false;
    }
    if drift {
        let _ = write_file_atomic(path, rewritten.as_str());
    }
    return true;
}

/// The options every manifest build passes down to the engine unchanged.
pub struct BuildCtx<'a> {
    pub jobs: u32, // --jobs; 0 = the manifest's `jobs`, else one per core
    pub std_dir: str<'a>,
    pub ce_steps: u32, // compile-time evaluation budgets; 0 = the engine default
    pub ce_mem: u64,
    pub target: i32,
    pub bootstrap_tags: bool,
    pub lint: bool,
    /// `--transpiler`: the command that runs the transpile step in place of this compiler's own frontend
    /// (`run_transpiler`); empty for the frontend.
    pub transpiler: str<'a>,
}

// Transpile `root`'s closure into `srcgen` with this compiler's own frontend, streaming each finished
// file into `sink` when non-null. On success, when `cid` is not 0, write the emit stamp for the tree to
// `stamp` (the engine moves it into place once the tree is synced).
fn emit_closure(
    m: &mf::Manifest,
    prof_name: str,
    root: str,
    root_dir: str,
    alt: str,
    srcgen: str,
    jobs: u32,
    cx: &BuildCtx,
    topts: *const TestOpts,
    sink: *mut EmitSink,
    stamp: str,
    cid: u64,
) i32 {
    loader::set_load_jobs(jobs);
    let tl0 = unsafe shim::sc_ticks_ms();
    // The build settings the prelude's build constants spell (`@arch` gates on the instruction
    // set too), set before the load.
    let mut p = loader::package_new(root_dir, alt, cx.std_dir);
    p.arch = m.arch;
    p.test_build = topts != null && unsafe (*topts).enabled;
    p.profile = String::from_str(prof_name);
    p.profiles = profile_names(m);
    p.load_root(root, cx.std_dir, cx.bootstrap_tags, cx.target);
    bst::mark(bst::B_LOAD);
    if stdlib::getenv("SC_CEMIT_STATS") != null {
        eprintln("phase load: {} ms", unsafe shim::sc_ticks_ms() - tl0);
    }
    loader::set_load_jobs(1);
    if !p.ok {
        if jobs != 1 {
            prt::shutdown(); // parallel loading started the pool
        }
        return 1;
    }
    p.gen_root = String::from_str(srcgen);
    for i in 0..m.shards.len() {
        p.shard_rules.push(
            loader::ShardRule {
                module: m.shards.at(i).module.clone(),
                tus: m.shards.at(i).tus,
                insts: m.shards.at(i).insts,
            },
        );
    }
    p.jobs = p.analysis_jobs(jobs);
    if p.jobs == 1 && jobs != 1 {
        prt::shutdown(); // parallel loading may have started the pool
    }
    let pkg = (&mut p) as *mut loader::Package;
    let mut cirv = iri::interp_master(pkg, cx.ce_steps, cx.ce_mem);
    p.cir = &mut cirv;
    let rc = run_package(&mut p, topts, "", cx.target, cx.lint, "", "", sink);
    if rc == 0 && cid != 0 {
        stamp_write(stamp, &p, cx.std_dir, root_dir, cx.target, m.arch, cx.bootstrap_tags, cx.lint, srcgen, cid);
    }
    // The stamp record is the last output of the emission; the package's teardown that follows
    // belongs to the sync phase.
    bst::mark(bst::B_PUBLISH);
    return rc;
}

// The identity of the external transpiler `cmd` for the emit stamp: its words, and the content of each
// word that names a file (the program found through PATH as `which_path` finds it; for a runtime
// command, the module it runs). A different transpiler, or new content at the same path, emits again.
fn transpiler_id(cmd: str) u64 {
    let mut words = Vector::<String>::new();
    split_args(&mut words, cmd);
    let mut h = fnv_cont(FNV_BASIS, "transpiler");
    for i in 0..words.len() {
        let w = words.at(i).as_str();
        h = skey_mix(fnv_cont(h, w), w.len() as u64);
        let mut path = String::new();
        let mt = if i == 0 {
            which_path(w, &mut path);
        } else {
            path.push_str(w);
            unsafe shim::sc_mtime(path.cstr());
        };
        if mt != 0 && unsafe shim::sc_stat_isdir(path.cstr()) != 1 {
            h = skey_mix(h, file_id(path.as_str()));
        }
    }
    // 0 means "no identity"; a real hash never takes it.
    return h | (h == 0) as u64;
}

// The transpile step through the external transpiler `cx.transpiler`: its words (whitespace-split, the
// contract of every command string in the engine; no shell), then the transpile form of this compiler's
// command line (`manifest_emit`), each argument one argv entry. The transpiler reads build.toml in this
// working directory and writes the tree where the engine's own frontend would, so the tree is the same
// function of the same inputs. `cid` (0: no stamp) becomes the identity in the stamp it writes.
fn run_transpiler(m: &mf::Manifest, prof_name: str, root: str, sub: str, cx: &BuildCtx, cid: u64) i32 {
    let mut args = Vector::<String>::new();
    split_args(&mut args, cx.transpiler);
    push_arg(&mut args, root);
    args.push(format("--emit-sub={}", sub));
    // Absolute: a transpiler under a WASI runtime starts in the guest's "/".
    let mut cwdb = PathBuf {};
    if unsafe shim::sc_realpath(".".ptr() as *const char, &mut cwdb[0]) == null {
        eprintln("build: cannot resolve the working directory for the transpiler");
        return 1;
    }
    args.push(format("--manifest-dir={}", str::from_cstr(&cwdb[0])));
    args.push(format("--out-dir={}", m.out_dir.as_str()));
    args.push(format("--profile={}", prof_name));
    args.push(format("--target={}", par::axis_names(false)[cx.target as usize]));
    args.push(format("--arch={}", par::axis_names(true)[m.arch as usize]));
    if cx.bootstrap_tags {
        push_arg(&mut args, "--bootstrap-tags");
    }
    if !cx.lint {
        push_arg(&mut args, "--no-lint");
    }
    if cx.ce_steps != 0 {
        args.push(format("--const-eval-steps={}", cx.ce_steps));
    }
    if cx.ce_mem != 0 {
        args.push(format("--const-eval-memory={}", cx.ce_mem));
    }
    if cid != 0 {
        args.push(format("--emit-id={}", cid));
    }
    let rc = exec_args(&mut args, null);
    if rc != 0 {
        eprintln("build: transpiler failed (exit {}): {}", rc, render_cmd(&args).as_str());
        return 1;
    }
    return 0;
}

/// The transpile form of the command line (`super-c <root> --emit-sub=SUB ...`, run by an engine whose
/// `--transpiler` names this compiler): the transpile step of a manifest build alone. `root`'s closure
/// goes to `<out-dir>/<sub>/raw` exactly as the engine's own frontend writes it, and with a nonzero `id`
/// the emit stamp for it, under that identity, to `<out-dir>/<sub>/.emit_stamp.new`.
pub fn manifest_emit(m: &mf::Manifest, profile: str, root: str, sub: str, cx: &BuildCtx, id: u64) i32 {
    let prof_name = resolve_profile(m, profile);
    if m.profile_index(prof_name) < 0 {
        eprintln("build: unknown profile '{}'", prof_name);
        return 1;
    }
    let pdir = loader::join2(m.out_dir.as_str(), sub);
    let srcgen = loader::join2(pdir.as_str(), "raw");
    let stamp = loader::join2(pdir.as_str(), ".emit_stamp.new");
    return emit_closure(
        m,
        prof_name,
        root,
        loader::dirname_of(m.root.as_str()),
        "",
        srcgen.as_str(),
        build_jobs(m, cx),
        cx,
        null,
        null,
        stamp.as_str(),
        id,
    );
}

// The worker count of a manifest build: --jobs, else the manifest's `jobs`, else one per core.
fn build_jobs(m: &mf::Manifest, cx: &BuildCtx) u32 {
    if cx.jobs != 0 {
        return cx.jobs;
    }
    if m.jobs != 0 {
        return m.jobs;
    }
    return (unsafe shim::sc_ncpu()) as u32;
}

/// The outcome of `transpile_step`.
pub struct Transpiled {
    pub rc: i32, // the emission's exit code; 0 when the stamp skipped it
    pub skipped: bool, // the emit stamp proved the tree exact: nothing was emitted
    pub cid: u64, // the emitting compiler's identity in the stamp record; 0 = no stamp
}

/// The transpile step of an engine build, alone: the emit-stamp check (phase boundary `B_STAMP`), then,
/// unless the stamp proves the tree of <out-dir>/<sub> exact, the emission of `root`'s closure into
/// <out-dir>/<sub>/raw through `cx.transpiler` or this compiler's own frontend (boundaries `B_LOAD` to
/// `B_PUBLISH`), each finished file streamed into `sink` (null: none). The emission writes its stamp
/// record to `.emit_stamp.new`; the engine installs it once the tree is synced. The engine and the
/// self-transpile benchmark run this one function, so the benchmark times what a build transpiles.
pub fn transpile_step(
    m: &mf::Manifest,
    prof_name: str,
    root: str,
    root_dir: str,
    alt: str,
    sub: str,
    jobs: u32,
    cx: &BuildCtx,
    topts: *const TestOpts,
    sink: *mut EmitSink,
) Transpiled {
    let pdir = loader::join2(m.out_dir.as_str(), sub);
    let srcgen = loader::join2(pdir.as_str(), "raw");
    let gen = loader::join2(pdir.as_str(), "gen");
    let mut stamp_path = loader::join2(pdir.as_str(), ".emit_stamp");
    let mut stamp_new = stamp_path.clone();
    stamp_new.push_str(".new");
    let cache_on = stdlib::getenv("SC_NO_EMIT_CACHE") == null;
    let external = cx.transpiler.len() != 0;
    // The emitting compiler's identity, read before the emission: the tree it emits is its function.
    let cid = if !cache_on {
        0 as u64;
    } else if external {
        transpiler_id(cx.transpiler);
    } else {
        compiler_id();
    };
    let skipped = cache_on && stamp_fresh(
        stamp_path.as_str(),
        root_dir,
        cx.target,
        m.arch,
        cx.bootstrap_tags,
        cx.lint,
        gen.as_str(),
        cid,
    );
    bst::mark(bst::B_STAMP);
    if skipped {
        return Transpiled { rc: 0, skipped: true, cid: cid };
    }
    // An emission that stops part way leaves raw/ and gen/ partly rewritten: no stamp may vouch for
    // them, or a later build with the old inputs would skip the transpile over a mixed tree.
    let _ = unsafe shim::sc_unlink(stamp_path.cstr());
    let _ = unsafe shim::sc_unlink(stamp_new.cstr());
    let rc = if external {
        run_transpiler(m, prof_name, root, sub, cx, cid);
    } else {
        emit_closure(m, prof_name, root, root_dir, alt, srcgen.as_str(), jobs, cx, topts, sink, stamp_new.as_str(), cid);
    };
    return Transpiled { rc: rc, skipped: false, cid: cid };
}

/// `transpile_step` for the manifest's primary root under `prof_name`: the tree `root_build` compiles,
/// <out-dir>/<prof_name>/raw. What the self-transpile benchmark runs per round.
pub fn root_transpile(m: &mf::Manifest, prof_name: str, cx: &BuildCtx, sink: *mut EmitSink) i32 {
    let root = m.root.as_str();
    return transpile_step(
        m,
        prof_name,
        root,
        loader::dirname_of(root),
        "",
        prof_name,
        build_jobs(m, cx),
        cx,
        null,
        sink,
    ).rc;
}

// The compile side of an engine build in profile directory `pdir` under `prof`: the C compiler, its
// compile and link flags, and the background probes (ccache, the compiler version, and the toolchain
// probes of `need` the record does not hold), started before the transpile. `pending` is the link
// record's pending marker; `cache` the object cache namespace (empty: none).
fn cc_stream(
    m: &mf::Manifest,
    prof: &mf::Profile,
    pdir: &String,
    cx: &BuildCtx,
    jobs: u32,
    lto_req: i32,
    need: u64,
    pending: String,
    cache: String,
) CcStream {
    let cc_raw = resolve_cc(m.cc.as_str(), m.sdk);
    let mut flags = String::new();
    flags.push_byte(b' ');
    flags.push_string(&m.cstd);
    // gcc 14 rejects incompatible pointer arguments; clang only warns. One rule on every host.
    flags.push_str(" -funsigned-char -ffp-contract=off -Werror=incompatible-pointer-types");
    if m.lib_shared && cx.target != 0 {
        // Shared-library objects need it; harmless for the exe targets.
        flags.push_str(" -fPIC");
    }
    // The cross triple comes first; manifest flags can override.
    push_sdk_flags(&mut flags, m.sdk, m.arch);
    push_all(&mut flags, &m.cflags);
    push_profile_side(&mut flags, prof, &prof.cflags, false, cx.target, m.sdk);
    if prof.pgo_use {
        // Clang hard-errors on a missing profile file, so the flag appears only when the file exists.
        let mut pgo = loader::join2(m.out_dir.as_str(), "pgo.profdata");
        if unsafe shim::sc_mtime(pgo.cstr()) != 0 {
            flags.push_str(" -fprofile-use=");
            flags.push_string(&pgo);
            flags.push_str(" -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date -Wno-backend-plugin");
        }
    }
    let mut tail = flags.clone();
    tail.push_str(" -MMD -c");
    // The fixed part of the link line, once: the link, the toolchain probes and their record key share it.
    let mut ldbase = String::new();
    push_sdk_flags(&mut ldbase, m.sdk, m.arch);
    push_sdk_libs(&mut ldbase, m.sdk);
    // The Android and wasm linkers are lld, whose output the host `strip` cannot read: they strip at link.
    if prof.strip && (m.sdk == 2 || m.sdk == 3) {
        ldbase.push_str(" -Wl,--strip-all");
    }
    push_all(&mut ldbase, &m.ldflags);
    push_profile_side(&mut ldbase, prof, &prof.ldflags, true, cx.target, m.sdk);
    // The ccache probe and `cc --version` cost ~50ms of process round-trips; two background argv
    // children (no shell, on every platform) resolve both while the transpile runs: ensure_cc
    // collects the exit code and the captured version line at first use.
    let mut ccver_path = loader::join2(pdir.as_str(), ".ccver");
    let mut ccprobe_path = loader::join2(pdir.as_str(), ".ccprobe");
    let mut pa = Vector::<String>::new();
    push_arg(&mut pa, "ccache");
    push_arg(&mut pa, "-V");
    let probe_cc_pid = spawn_args(&mut pa, ccprobe_path.cstr());
    let mut va = Vector::<String>::new();
    split_args(&mut va, cc_raw.as_str());
    push_arg(&mut va, "--version");
    let probe_ver_pid = spawn_args(&mut va, ccver_path.cstr());
    // The toolchain probes of `need` the record does not hold start beside it. The record's key: the
    // schema, the compiler's path and mtime, the target and the flags; `settle` checks the version.
    let mut ccpath = String::new();
    let ccmt = which_path(cc_raw.as_str(), &mut ccpath);
    let key = format(
        "{}\t{}\t{}\t{}\t{}\t{}\t{}",
        LTO_SCHEMA,
        ccpath.as_str(),
        ccmt,
        cx.target,
        m.arch,
        flags.as_str(),
        ldbase.as_str(),
    );
    let mut pargv = Vector::<String>::new();
    split_args(&mut pargv, cc_raw.as_str());
    split_args(&mut pargv, flags.as_str());
    let probes = pr::Probes::start(pdir.as_str(), key.as_str(), pargv, ldbase.as_str(), cx.target, m.arch, need);
    // The compile argv runs from the process working directory; record it for compile_commands.json.
    let mut cwdb = PathBuf {};
    let ccdb_dir = if unsafe shim::sc_realpath(".".ptr() as *const char, &mut cwdb[0]) != null {
        String::from_cstr(&cwdb[0]);
    } else {
        String::from_str(".");
    };
    return CcStream {
        src_len: pdir.len() + 4, // <pdir>/raw
        gen: loader::join2(pdir.as_str(), "gen"),
        obj: loader::join2(pdir.as_str(), "obj"),
        pdir: pdir.clone(),
        cc_raw: cc_raw,
        cc_tail: tail,
        ldbase: ldbase,
        target: cx.target,
        lto_req: lto_req,
        lto: lto_req,
        lto_cache: false,
        lto_reason: String::new(),
        lto_ld: Vector::<String>::new(),
        probe_cc_pid: probe_cc_pid,
        probe_ver_pid: probe_ver_pid,
        ccver_path: ccver_path,
        ccprobe_path: ccprobe_path,
        probes: probes,
        cc_args: Vector::<String>::new(),
        prefix_args: Vector::<String>::new(),
        ccver: String::new(),
        cc_ready: false,
        jobs: jobs,
        objs: Vector::<String>::new(),
        pend: Vector::<Pend>::new(),
        window: Vector::<Job>::new(),
        total_c: 0,
        stale_n: 0,
        pending: pending,
        marked: false,
        ret: 0,
        cache: cache,
        keys: Vector::<String>::new(),
        rewritten: Set::<String>::new(),
        mtimes: Map::<String, i64>::new(),
        synced: Set::<String>::new(),
        made_dirs: Set::<String>::new(),
        ccdb: Vector::<String>::new(),
        hmemo: Map::<u64, u64>::new(),
        hpool: Vector::<u64>::new(),
        ccdb_dir: ccdb_dir,
    };
}

// Build `root`'s closure with `prof_name`'s flags into <out-dir>/<sub>/{gen,obj}, linking `bin`;
// the transpiled C lands in <out-dir>/<sub>/raw first (PROFILE makes it depend on the profile).
// link_kind: 0 = executable, 1 = static library (ar), 2 = shared library (cc -shared).
fn engine_build(
    m: &mf::Manifest,
    prof_name: str,
    root: str,
    root_dir: str,
    alt: str,
    sub: str,
    bin: str,
    cx: &BuildCtx,
    link_kind: i32,
    topts: *const TestOpts,
) i32 {
    bst::begin();
    let rc = engine_build_i(m, prof_name, root, root_dir, alt, sub, bin, cx, link_kind, topts);
    bst::finish(rc);
    return rc;
}

fn engine_build_i(
    m: &mf::Manifest,
    prof_name: str,
    root: str,
    root_dir: str,
    alt: str,
    sub: str,
    bin: str,
    cx: &BuildCtx,
    link_kind: i32,
    topts: *const TestOpts,
) i32 {
    let pi = m.profile_index(prof_name);
    if pi < 0 {
        eprintln("build: unknown profile '{}'", prof_name);
        return 1;
    }
    let prof = m.profiles.at(pi as usize);
    let t0 = unsafe shim::sc_ticks_ms();
    bst::mark(bst::B_START);

    // Compile-side setup happens BEFORE the transpile: the EmitSink streams each finished TU into
    // the worker pool, overlapping cc with the remainder of the emit pass.
    let pdir = loader::join2(m.out_dir.as_str(), sub);
    let srcgen = loader::join2(pdir.as_str(), "raw");
    let gen = loader::join2(pdir.as_str(), "gen");
    let obj = loader::join2(pdir.as_str(), "obj");
    mkdir_p(gen.as_str());
    mkdir_p(obj.as_str());
    let jobs = build_jobs(m, cx);
    let stats = bst::last();
    if stats != null {
        let g = unsafe &mut *stats;
        g.profile.push_str(prof_name);
        g.bin.push_str(bin);
        g.jobs = jobs;
    }
    let mut lto_req = prof.lto;
    let lenv = stdlib::getenv("SC_LTO");
    if lenv != null {
        lto_req = mf::lto_parse(str::from_cstr(lenv));
        if lto_req < 0 {
            eprintln("build: SC_LTO must be none, full, auto or thin");
            return 1;
        }
    }
    // The link record: per-binary and profile-agnostic (out-dir root), since profiles share bin paths
    // and a dev binary left behind by a release link must read as out of date.
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
    let fppath = loader::join2(m.out_dir.as_str(), fpname.as_str());
    let mut pending = fppath.clone();
    pending.push_str(".pending");
    let cache = obj_cache_ns(object_cache_dir().as_str(), pdir.as_str());
    // No toolchain probe result shapes a build yet but the ThinLTO verdict (`lto_resolve`).
    let mut stream = cc_stream(m, prof, &pdir, cx, jobs, lto_req, 0, pending, cache);
    let mut sink = EmitSink { ctx: &mut stream, notify: stream_notify };

    // 1) transpile the closure to <out-dir>/<raw>, streaming each finished TU into the pool:
    // unless the emit stamp proves every input unchanged since the last successful emission, in
    // which case the generated tree is already exact and the pipeline skips straight to cc/link.
    let tr = transpile_step(m, prof_name, root, root_dir, alt, sub, jobs, cx, topts, &mut sink);
    let skip_emit = tr.skipped;
    if stats != null {
        unsafe (*stats).skip_emit = skip_emit;
    }
    let mut t_transpile = t0;
    let mut ret: i32 = 0;
    if !skip_emit {
        if tr.rc != 0 {
            // Reap what is in flight; abandon what has not started.
            stream.drain(true);
            return tr.rc;
        }
        t_transpile = unsafe shim::sc_ticks_ms();

        // 2) whole-tree content-sync as the safety net: every file was already synced when its
        // notification arrived, so this is a byte-compare no-op that (a) unlinks gen/ orphans and
        // (b) surfaces anything the stream never heard about: planned below off the directory walk.
        // An external transpiler streams nothing, so the sync copies its whole tree here.
        ret = stream.ret;
        if ret == 0 {
            ret = sync_tree(srcgen.as_str(), gen.as_str(), &stream.synced);
        }
        // The emission wrote its stamp beside the final one; only a synced tree gets it. A missing stamp
        // (an input the emission could not read) only makes the next build transpile again.
        if ret == 0 && tr.cid != 0 {
            let mut stamp_path = loader::join2(pdir.as_str(), ".emit_stamp");
            let mut stamp_new = stamp_path.clone();
            stamp_new.push_str(".new");
            let _ = unsafe shim::sc_rename(stamp_new.cstr(), stamp_path.cstr());
        }
    } else {
        t_transpile = unsafe shim::sc_ticks_ms();
    }
    let t_sync = unsafe shim::sc_ticks_ms();
    bst::mark(bst::B_SYNC);
    let mut t_compile = t_sync;
    let mut t_link = t_sync;
    let mut total_c: usize = 0;
    let mut stale_n: usize = 0;
    let mut linked = false;

    if ret == 0 {
        // 3) plan any .c the stream did not see (none expected), then run the pool dry.
        let mut rels = Vector::<String>::new();
        walk_gen_files(gen.as_str(), gen.len(), &mut rels);
        let mut planned = Set::<String>::new();
        for i in 0..stream.objs.len() {
            planned.insert(stream.objs.at(i).clone());
        }
        for i in 0..rels.len() {
            let rel = rels.at(i).as_str();
            if !rel.ends_with(".c") {
                continue;
            }
            let mut opath = loader::join2(obj.as_str(), rel.slice(0, rel.len() - 2));
            opath.push_str(".o");
            if !planned.contains(&opath) {
                stream.plan_c(rel);
            }
        }
        stream.drain(false);
        // A build with zero .c files never planned one; the link still needs cc.
        stream.ensure_cc();
        // compile_commands.json: one row per translation unit, argv exactly as compiled, written
        // atomically so tooling never reads a torn file. Refreshed on every build that plans units.
        // Rows sort by their text (a constant directory then the file path): plan order follows the
        // emit stream's notification arrival, which the parallel emit workers may vary.
        {
            stream.ccdb.sort();
            let mut db = String::from_str("[\n");
            for ri in 0..stream.ccdb.len() {
                if ri != 0 {
                    db.push_str(",\n");
                }
                db.push_string(stream.ccdb.at(ri));
            }
            db.push_str("\n]\n");
            let dbp = loader::join2(pdir.as_str(), "compile_commands.json");
            if !write_file_atomic(dbp.as_str(), db.as_str()) {
                eprintln("build: cannot write '{}'", dbp.as_str());
            }
        }
        let cc_link = clone_args(&stream.cc_args);
        let ccver = stream.ccver.clone();
        total_c = stream.total_c;
        stale_n = stream.stale_n;
        ret = stream.ret;
        // The link list is sorted so its order never depends on notification arrival order:
        // the link fingerprint embeds the full command.
        let mut objs = replace(&mut stream.objs, Vector::<String>::new());
        objs.sort();
        t_compile = unsafe shim::sc_ticks_ms();
        t_link = t_compile;
        bst::mark(bst::B_COMPILE);
        if stats != null {
            let g = unsafe &mut *stats;
            g.cc_version.push_string(&ccver);
            g.ccache = stream.cc_args.len() != 0 && stream.cc_args.at(0).as_str() == "ccache";
            g.total_c = total_c;
            g.stale_n = stale_n;
            g.lto.push_str(mf::lto_name(stream.lto));
            if stream.lto_cache {
                g.lto.push_str("+cache");
            }
            g.lto_reason.push_string(&stream.lto_reason);
        }

        // 4) link when anything changed: a fresh object, a missing/out-of-date binary, or a link
        // command (flags, libs, __ldflags, linker version) differing from the recorded one.
        if ret == 0 {
            let mut binb = String::from_str(bin);
            let bmt = unsafe shim::sc_mtime(binb.cstr());
            let mut tmp = String::from_str(bin);
            tmp.push_str(".tmp");
            let mut largs = Vector::<String>::new();
            if link_kind == 1 {
                // A static library is an archive: no link flags, no libs.
                push_arg(&mut largs, "ar");
                push_arg(&mut largs, "rcs");
                largs.push(tmp.clone());
                for i in 0..objs.len() {
                    largs.push(objs.at(i).clone());
                }
            } else {
                largs = cc_link;
                if link_kind == 2 {
                    push_arg(&mut largs, "-shared");
                    if cx.target != 0 {
                        push_arg(&mut largs, "-fPIC");
                    }
                }
                push_arg(&mut largs, "-o");
                largs.push(tmp.clone());
                for i in 0..objs.len() {
                    largs.push(objs.at(i).clone());
                }
                // Flag STRINGS keep the historic whitespace-splitting contract; only the paths the
                // engine controls (above, and the linker cache directory) are single verbatim arguments.
                split_args(&mut largs, stream.ldbase.as_str());
                for i in 0..stream.lto_ld.len() {
                    largs.push(stream.lto_ld.at(i).clone());
                }
                // @c.link flags recorded by the emitter.
                let lfp = loader::join2(gen.as_str(), "__ldflags");
                push_ldflags(&mut largs, lfp.as_str());
                let mut ll = String::new();
                push_all(&mut ll, &m.ldlibs);
                split_args(&mut largs, ll.as_str());
            }
            let mut fp = ccver.clone();
            fp.push_str(" | ");
            let lrendered = render_cmd(&largs);
            fp.push_string(&lrendered);
            push_used(&mut fp, &stream.probes.used);
            if prof.strip {
                fp.push_str(" +strip");
            }
            let mut need = bmt == 0 || unsafe shim::sc_mtime(stream.pending.cstr()) != 0;
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
                // `ar rcs` updates an existing archive, so a temp an interrupted link left behind would
                // keep the objects of deleted modules.
                let _ = unsafe shim::sc_unlink(tmp.cstr());
                let lrc = exec_args(&mut largs, null);
                if lrc != 0 {
                    eprintln("build: link failed (exit {}): {}", lrc, lrendered.as_str());
                    ret = 1;
                } else {
                    if unsafe shim::sc_rename(tmp.cstr(), binb.cstr()) != 0 {
                        eprintln("build: cannot move '{}' into place", bin);
                        ret = 1;
                    } else {
                        if prof.strip && link_kind == 0 && m.sdk != 2 && m.sdk != 3 {
                            let mut st = Vector::<String>::new();
                            push_arg(&mut st, "strip");
                            push_arg(&mut st, bin);
                            let src = exec_args(&mut st, null);
                            if src != 0 {
                                eprintln("build: strip failed (exit {}); '{}' keeps its symbols", src, bin);
                            }
                        }
                        // The pending marker goes only once the link record holds this link: without
                        // the record, a same-second object could leave the next build on this binary.
                        if write_file_atomic(fppath.as_str(), fp.as_str()) {
                            let _ = unsafe shim::sc_unlink(stream.pending.cstr());
                        } else {
                            eprintln("build: cannot write '{}'; the next build relinks", fppath.as_str());
                        }
                    }
                }
            }
            t_link = unsafe shim::sc_ticks_ms();
        }
        // Retention runs only after a successful build: a failed one may leave its objects unnamed.
        if ret == 0 {
            let now = time::now();
            if stream.cache.len() != 0 {
                obj_cache_commit(stream.cache.as_str(), &mut stream.keys, root_dir, now);
            }
            let croot = cache_root();
            if croot.len() != 0 {
                cache_sweep(croot.as_str(), now);
            }
        }
    } else {
        // A failed sync or compile: reap the compiles still in flight and the probes.
        stream.drain(true);
    }
    if stats != null {
        unsafe (*stats).linked = linked;
    }
    if stdlib::getenv("SC_TIMINGS") != null {
        eprintln(
            "timings[{}->{}]: transpile {}ms | sync {}ms | compile {}ms ({}/{} stale, jobs={}) | link {}ms ({}, lto {}) | total {}ms",
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
            mf::lto_name(stream.lto),
            t_link - t0,
        );
    }
    return ret;
}

/// `super-c build --print-probes`: the toolchain probe table for the target and `profile`'s flags, one
/// `<id> <result>` line per probe after the compiler version and the target. The probes the record
/// `<out-dir>/<profile>/.probes` does not hold run first, beside the version probe, and join it.
pub fn manifest_print_probes(m: &mf::Manifest, profile: str, cx: &BuildCtx) i32 {
    let prof_name = resolve_profile(m, profile);
    let pi = m.profile_index(prof_name);
    if pi < 0 {
        eprintln("build: unknown profile '{}'", prof_name);
        return 1;
    }
    let pdir = loader::join2(m.out_dir.as_str(), prof_name);
    mkdir_p(pdir.as_str());
    let mut stream = cc_stream(
        m,
        m.profiles.at(pi as usize),
        &pdir,
        cx,
        1,
        mf::LTO_THIN,
        pr::ALL,
        String::new(),
        String::new(),
    );
    stream.ensure_cc();
    println("compiler: {}", stream.ccver.as_str());
    println("target: {} {}", par::axis_names(false)[cx.target as usize], par::axis_names(true)[m.arch as usize]);
    for i in 0..pr::table().len() {
        let mut line = String::from_str(pr::table()[i].id);
        while line.len() < 24 {
            line.push_byte(b' ');
        }
        line.push_string(stream.probes.res.at(i));
        println("{}", line.as_str());
    }
    return 0;
}

/// `super-c build` from build.toml: run the engine on the manifest's root under the resolved profile
/// (see `resolve_profile`), linking `bin_override` when non-empty, else the manifest's `bin`.
pub fn manifest_build(m: &mf::Manifest, profile: str, bin_override: str, cx: &BuildCtx) i32 {
    let prof_name = resolve_profile(m, profile);
    if bin_override.len() != 0 {
        // `-o` names an exact path: link straight there, no profile copy and nothing installed.
        let ob = exe_name(bin_override, cx.target);
        return root_build(m, prof_name, ob.as_str(), cx);
    }
    let mut path = String::new();
    let rc = build_into_profile(m, prof_name, cx, &mut path);
    if rc != 0 {
        return rc;
    }
    let dest = exe_name(m.bin.as_str(), cx.target);
    return install_bin(path.as_str(), dest.as_str());
}

// Build one named target through the engine into its own <out-dir>/<profile><suffix> tree (per-target
// gen/obj caches: different closures must not thrash one another's sync). `out` receives the artifact.
fn target_build(
    m: &mf::Manifest,
    prof_name: str,
    root: str,
    suffix: str,
    leaf: str,
    link_kind: i32,
    cx: &BuildCtx,
    out: &mut String,
) i32 {
    let mut sub = String::from_str(prof_name);
    sub.push_str(suffix);
    let dir = loader::join2(m.out_dir.as_str(), sub.as_str());
    let path = loader::join2(dir.as_str(), leaf);
    let rc = engine_build(
        m,
        prof_name,
        root,
        loader::dirname_of(m.root.as_str()),
        "",
        sub.as_str(),
        path.as_str(),
        cx,
        link_kind,
        null,
    );
    *out = path;
    return rc;
}

// Build the manifest's primary root with `prof_name`'s flags into <out-dir>/<prof_name>, linking `bin`.
fn root_build(m: &mf::Manifest, prof_name: str, bin: str, cx: &BuildCtx) i32 {
    let root = m.root.as_str();
    return engine_build(m, prof_name, root, loader::dirname_of(root), "", prof_name, bin, cx, 0, null);
}

// Build the [bin.NAME] target `bt` into <out-dir>/<prof_name>-bin-NAME; `out` receives the executable.
fn bin_build(m: &mf::Manifest, prof_name: str, bt: &mf::BinTarget, cx: &BuildCtx, out: &mut String) i32 {
    let mut suffix = String::from_str("-bin-");
    suffix.push_string(&bt.name);
    let leaf = exe_name(bt.name.as_str(), cx.target);
    return target_build(m, prof_name, bt.root.as_str(), suffix.as_str(), leaf.as_str(), 0, cx, out);
}

/// `super-c build`/`release` over every manifest target (cargo-style): the [lib] section's static and/or
/// shared artifacts, the primary `bin` (installed onto the manifest's `bin` path), and each [bin.NAME].
/// `sel_bin`/`sel_lib` restrict to one target (`--bin=NAME` / `--lib`).
pub fn manifest_build_all(m: &mf::Manifest, profile: str, sel_bin: str, sel_lib: bool, cx: &BuildCtx) i32 {
    let prof_name = resolve_profile(m, profile);
    let selected = sel_bin.len() != 0 || sel_lib;
    let mut matched = false;
    if m.lib_name.len() != 0 && (!selected || sel_lib) {
        matched = true;
        // The static pass lints the closure; the shared pass does not lint it again.
        let mut nolint = *cx;
        nolint.lint = false;
        for kind in 1..3 {
            let shared = kind == 2;
            if shared && !m.lib_shared || !shared && !m.lib_static {
                continue;
            }
            let leaf = lib_file(m.lib_name.as_str(), shared, cx.target);
            let mut path = String::new();
            let rc = target_build(
                m,
                prof_name,
                m.lib_root.as_str(),
                "-lib",
                leaf.as_str(),
                kind,
                if shared {
                    &nolint;
                } else {
                    cx;
                },
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
        let rc = manifest_build(m, profile, "", cx);
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
        let mut path = String::new();
        let rc = bin_build(m, prof_name, bt, cx, &mut path);
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
    // The name is written verbatim into a TOML string, a format string literal and the binary's file
    // name, so a byte any of them would read specially is refused.
    let mut valid = name.len() != 0 && name != "." && name != "..";
    for i in 0..name.len() {
        let c = name[i];
        if c < 0x20u8 || c == b'"' || c == b'\\' || c == b'/' || c == b'{' || c == b'}' {
            valid = false;
        }
    }
    if !valid {
        eprintln("init: '{}' is not a valid project name", name);
        return 1;
    }
    let man = loader::join2(dir, "build.toml");
    let probe = stdio::fopen(man.as_str(), "rb");
    if probe != null {
        unsafe stdio::fclose(probe);
        eprintln("init: '{}' already exists", man.as_str());
        return 1;
    }
    let srcdir = loader::join2(dir, "src");
    mkdir_p(srcdir.as_str());
    let mut toml = String::new();
    toml.push_str("bin = \"");
    toml.push_str(name);
    toml.push_str("\"\nroot = \"src/main.spc\"\n");
    if !write_file(man.as_str(), toml.as_str()) {
        eprintln("init: cannot write '{}'", man.as_str());
        return 1;
    }
    let mainp = loader::join2(srcdir.as_str(), "main.spc");
    let mut mains = String::new();
    mains.push_str("fn main() i32 {\n    println(\"Hello from ");
    mains.push_str(name);
    mains.push_str("!\");\n    return 0;\n}\n");
    if !write_file(mainp.as_str(), mains.as_str()) {
        eprintln("init: cannot write '{}'", mainp.as_str());
        return 1;
    }
    let gi = loader::join2(dir, ".gitignore");
    let gprobe = stdio::fopen(gi.as_str(), "rb");
    if gprobe != null {
        unsafe stdio::fclose(gprobe);
    } else {
        let _ = write_file(gi.as_str(), "/build\n");
    }
    let gitdir = loader::join2(dir, ".git");
    let mut gd = gitdir.clone();
    if unsafe shim::sc_stat_isdir(gd.cstr()) != 1 {
        let mut ga = Vector::<String>::new();
        push_arg(&mut ga, "git");
        push_arg(&mut ga, "init");
        push_arg(&mut ga, "-q");
        push_arg(&mut ga, dir);
        let _ = exec_args(&mut ga, null); // best-effort: no git, no repository, no error
    }
    println("created {} project at {}", name, dir);
    return 0;
}

const COPY_TREE_DEPTH: u32 = 64;

// Recursive directory copy. Any `.git` entry is dropped AT EVERY LEVEL: vendored source belongs to
// the project's own history, and a nested repository (the dependency's, or a submodule's) would be
// invisible to (and shadow files from) the repository the project lives in. Directory links are
// followed, so `depth` bounds a link cycle.
fn copy_tree(srcd: str, dstd: str, depth: u32) bool {
    if depth == COPY_TREE_DEPTH {
        eprintln("vendor: '{}' nests deeper than {} directories (a directory link cycle?)", srcd, COPY_TREE_DEPTH);
        return false;
    }
    mkdir_p(dstd);
    let lo = list_dir(srcd, true);
    if lo.is_none() {
        return false;
    }
    let names = lo.unwrap();
    let mut ok = true;
    for i in 0..names.len() {
        if names.at(i).as_str() == ".git" {
            continue;
        }
        let s = loader::join2(srcd, names.at(i).as_str());
        let d = loader::join2(dstd, names.at(i).as_str());
        let mut sc = s.clone();
        if unsafe shim::sc_stat_isdir(sc.cstr()) == 1 {
            if !copy_tree(s.as_str(), d.as_str(), depth + 1) {
                ok = false;
            }
        } else if !copy_file(s.as_str(), d.as_str()) {
            ok = false;
        }
    }
    return ok;
}

// Delete every `.git` entry under `dir`: the top repository's directory and each submodule's
// `.git` file, which would point at the deleted `.git/modules`.
fn strip_git(dir: str) {
    let lo = list_dir(dir, true);
    if lo.is_none() {
        return;
    }
    let names = lo.unwrap();
    for i in 0..names.len() {
        let mut d = loader::join2(dir, names.at(i).as_str());
        if names.at(i).as_str() == ".git" {
            rm_rf(d.as_str());
        } else if unsafe shim::sc_lstat_isdir(d.cstr()) == 1 {
            strip_git(d.as_str());
        }
    }
}

/// `super-c vendor <src> [name]`: copy a dependency's source into `<root>/vendor/<name>`, where the
/// module loader already resolves it (`import vendor::<name>::<module>;`) so vendoring records
/// nothing in the manifest. A git source (a scheme, a `git@` remote, or a `.git` suffix) is cloned
/// with its submodules and `--ref` pins a branch, tag or commit; anything else must be a local
/// directory and is copied. No `.git` survives either way: vendored source belongs to the project's
/// history, which is also why `.vendor` records the source and the exact commit: with the
/// repository gone, that file is the only statement of WHAT was vendored.
pub fn vendor_dep(root: str, src: str, name_arg: str, ref_arg: str, force: bool) i32 {
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
    // One directory directly under vendor/: `--force` deletes it, so it must not name anything else.
    if name == "." || name == ".." || name.find_byte(b'/') >= 0 || name.find_byte(b'\\') >= 0 {
        eprintln("vendor: '{}' is not a directory name (name one: super-c vendor <src> <name>)", name);
        return 1;
    }
    let vdir = loader::join2(root, "vendor");
    let dest = loader::join2(vdir.as_str(), name);
    let mut dp = dest.clone();
    if unsafe shim::sc_stat_isdir(dp.cstr()) == 1 {
        if !force {
            eprintln("vendor: '{}' already exists (replace it with --force)", dest.as_str());
            return 1;
        }
        rm_rf(dest.as_str());
    }
    let is_git = src.starts_with("git@") || src.ends_with(".git") || scheme_len(src) != 0;
    if !is_git && ref_arg.len() != 0 {
        eprintln("vendor: --ref pins a git source; '{}' is a local directory", src);
        return 1;
    }
    mkdir_p(vdir.as_str());
    let mut stamp = String::from_str("source = \"");
    stamp.push_str(src);
    stamp.push_str("\"\n");
    if is_git {
        let mut ga = Vector::<String>::new();
        push_arg(&mut ga, "git");
        push_arg(&mut ga, "clone");
        push_arg(&mut ga, "-q");
        push_arg(&mut ga, "--recurse-submodules");
        push_arg(&mut ga, src);
        ga.push(dest.clone());
        if exec_args(&mut ga, null) != 0 {
            eprintln("vendor: git clone failed for '{}'", src);
            return 1;
        }
        if ref_arg.len() != 0 {
            // --detach takes a commit hash as readily as a branch or tag name.
            let mut co = Vector::<String>::new();
            push_arg(&mut co, "git");
            push_arg(&mut co, "-C");
            co.push(dest.clone());
            push_arg(&mut co, "checkout");
            push_arg(&mut co, "-q");
            push_arg(&mut co, "--detach");
            push_arg(&mut co, ref_arg);
            if exec_args(&mut co, null) != 0 {
                eprintln("vendor: no ref '{}' in '{}'", ref_arg, src);
                rm_rf(dest.as_str());
                return 1;
            }
            // The checkout moves only the top repository: submodules must follow the ref's commits.
            let mut su = Vector::<String>::new();
            push_arg(&mut su, "git");
            push_arg(&mut su, "-C");
            su.push(dest.clone());
            push_arg(&mut su, "submodule");
            push_arg(&mut su, "update");
            push_arg(&mut su, "-q");
            push_arg(&mut su, "--init");
            push_arg(&mut su, "--recursive");
            if exec_args(&mut su, null) != 0 {
                eprintln("vendor: submodule update failed at '{}' in '{}'", ref_arg, src);
                rm_rf(dest.as_str());
                return 1;
            }
        }
        // The exact commit, captured BEFORE the repository is stripped: afterwards nobody can ask.
        let head = git_head(dest.as_str());
        if head.len() != 0 {
            stamp.push_str("commit = \"");
            stamp.push_str(head.as_str());
            stamp.push_str("\"\n");
        }
        strip_git(dest.as_str());
    } else {
        let mut sp = String::from_str(src);
        if unsafe shim::sc_stat_isdir(sp.cstr()) != 1 {
            eprintln("vendor: '{}' is not a directory (a git source needs a scheme, git@, or .git)", src);
            return 1;
        }
        if !copy_tree(src, dest.as_str(), 0) {
            eprintln("vendor: copy failed for '{}'", src);
            rm_rf(dest.as_str());
            return 1;
        }
    }
    let sf = loader::join2(dest.as_str(), ".vendor");
    let _ = write_file(sf.as_str(), stamp.as_str());
    println("vendored {} at {} (import vendor::{}::<module>;)", name, dest.as_str(), name);
    return 0;
}

// The output of `git -C dir <a> <b> <c>` (empty args dropped) with trailing newlines removed, read
// back through `tmp`; empty when git fails or is absent. The exec API does the redirection
// itself: a `>` in the command would need a shell, which Windows does not get.
fn git_capture(dir: str, tmp: str, a: str, b: str, c: str) String {
    let mut tp = String::from_str(tmp);
    let mut ga = Vector::<String>::new();
    push_arg(&mut ga, "git");
    push_arg(&mut ga, "-C");
    push_arg(&mut ga, dir);
    push_arg(&mut ga, a);
    if b.len() != 0 {
        push_arg(&mut ga, b);
    }
    if c.len() != 0 {
        push_arg(&mut ga, c);
    }
    let rc = exec_args(&mut ga, tp.cstr());
    let mut out = String::new();
    if rc == 0 {
        switch loader::read_file(tmp) {
            Some(t) => {
                out = t;
                while out.len() > 0 && (out.as_str()[out.len() - 1] == b'\n' || out.as_str()[out.len() - 1] == b'\r') {
                    out.truncate(out.len() - 1);
                }
            },
            None => {},
        };
    }
    rm_rf(tmp);
    return out;
}

// `git rev-parse HEAD` of a checkout.
fn git_head(dir: str) String {
    let tmp = loader::join2(dir, ".vendor-head");
    return git_capture(dir, tmp.as_str(), "rev-parse", "HEAD", "");
}

// The checkout's identity for a benchmark record: the short commit, "-dirty" appended when a
// tracked file differs from it, or "unknown" when git cannot answer.
fn git_build_id(dir: str, tmp_dir: str) String {
    let tmp = loader::join2(tmp_dir, ".bench_git");
    let mut id = git_capture(dir, tmp.as_str(), "rev-parse", "--short=12", "HEAD");
    if id.len() == 0 {
        id.push_str("unknown");
        return id;
    }
    let st = git_capture(dir, tmp.as_str(), "status", "--porcelain", "--untracked-files=no");
    if st.len() != 0 {
        id.push_str("-dirty");
    }
    return id;
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
// into place afterwards, and the ones that merely need to run it (test, run) use it where it lies: which
// is what keeps a `test` run from quietly leaving a dev binary where a release one was.
fn build_into_profile(m: &mf::Manifest, prof_name: str, cx: &BuildCtx, out: &mut String) i32 {
    let path = profile_bin(m, prof_name, cx.target);
    let rc = root_build(m, prof_name, path.as_str(), cx);
    *out = path;
    return rc;
}

/// `super-c run`: build the manifest binary (like `manifest_build`), then execute it (cargo run).
/// Returns the build's failure code, or the binary's exit code. The binary is `bin_override` if
/// given, else the manifest's `bin`; a bare name is run cwd-relative (`./bin`), never through PATH.
pub fn manifest_run_bin(m: &mf::Manifest, profile: str, bin_override: str, sel_bin: str, cx: &BuildCtx) i32 {
    let prof_name = resolve_profile(m, profile);
    let mut built = String::new();
    if sel_bin.len() != 0 && sel_bin != m.bin.as_str() {
        // `run --bin=NAME`: build and execute that [bin.NAME] target.
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
        let mut path = String::new();
        let trc = bin_build(m, prof_name, m.bins.at(bi as usize), cx, &mut path);
        if trc != 0 {
            return trc;
        }
        let mut ra0 = Vector::<String>::new();
        ra0.push(path.clone());
        return exec_args(&mut ra0, null);
    }
    let rc = if bin_override.len() != 0 {
        built = exe_name(bin_override, cx.target);
        root_build(m, prof_name, built.as_str(), cx);
    } else {
        // Run the profile's own binary where it was linked; `run` builds to run, it does not install.
        build_into_profile(m, prof_name, cx, &mut built);
    };
    if rc != 0 {
        return rc;
    }
    let mut path = String::new();
    if built.as_str().find_byte(b'/') < 0 {
        path.push_str("./");
    }
    path.push_string(&built);
    let mut ra = Vector::<String>::new();
    ra.push(path.clone());
    // A built binary: argv exec, never through a shell.
    return exec_args(&mut ra, null);
}

/// `super-c test`: build the project, then discover <test-dir>/**/*.spc (default tests/), synthesize
/// an aggregating root, and run the @test pipeline on it (SUPERC points at the fresh binary).
pub fn manifest_test(m: &mf::Manifest, profile: str, cx: &BuildCtx, topts: *const TestOpts) i32 {
    let mut nolint = *cx;
    nolint.lint = false;
    let mut tdir = m.test_dir.clone();
    if unsafe shim::sc_stat_isdir(tdir.cstr()) != 1 {
        eprintln("test: no {}/ directory next to src/", tdir.as_str());
        return 1;
    }
    // The profile's own binary, left where it was linked: `test` must not stand in for `build`, or a run of
    // the suite would replace whatever the manifest's binary currently is (a release artifact, say).
    let prof_name = resolve_profile(m, profile);
    let mut binp = String::new();
    let rc = build_into_profile(m, prof_name, &nolint, &mut binp);
    if rc != 0 {
        return rc;
    }
    let mut src = String::new();
    if suite_import_root(tdir.as_str(), "test", &mut src) == 0 {
        eprintln("test: no .spc files under {}/", tdir.as_str());
        return 1;
    }
    src.push_str("\nfn main() i32 {\n    return 0;\n}\n");
    mkdir_p(m.out_dir.as_str());
    let rootp = loader::join2(m.out_dir.as_str(), "test_root.spc");
    // Rewrite the root only when its content changed: an unchanged root keeps its mtime, so the emit
    // stamp proves the suite unchanged without hashing every input.
    if !file_eq(rootp.as_str(), &src) {
        if !write_file(rootp.as_str(), src.as_str()) {
            eprintln("test: cannot write '{}'", rootp.as_str());
            return 1;
        }
    }
    // The harness compiles+runs snippets through the binary built above ("./" so it never
    // resolves through PATH when the bin name is bare), unless SC_TEST_SUPERC names a different
    // compiler under test (the wasm lane's wasmtime wrapper), which then takes its place.
    let mut binb = String::new();
    let ov = stdlib::getenv("SC_TEST_SUPERC");
    if ov != null && unsafe *ov != 0 as char {
        binb.push_str(str::from_cstr(ov));
    } else {
        if binp.as_str().find_byte(b'/') < 0 {
            binb.push_str("./");
        }
        binb.push_string(&binp);
    }
    unsafe shim::sc_setenv("SUPERC".ptr() as *const char, binb.cstr());
    // The fixture builds of one suite run share one object cache (SC_TEST_CACHE_DIR, read by the
    // harness): the runtime and std units they emit identically compile once, and the cache stays out
    // of the user's global one. Absolute: tests change directory.
    let mut fxc = real_path(m.out_dir.as_str());
    if fxc.len() != 0 {
        fxc.push_str("/test/fixture-cache");
        unsafe shim::sc_setenv("SC_TEST_CACHE_DIR".ptr() as *const char, fxc.cstr());
    }
    // The runner is built through the engine under the `test` profile, in its own <out-dir>/test tree:
    // per-TU parallel compiles, the object cache and the emit stamp turn an unchanged suite into a
    // link check instead of a serial rebuild of every unit.
    let tsub = "test";
    let tdir_out = loader::join2(m.out_dir.as_str(), tsub);
    let tbin = loader::join2(tdir_out.as_str(), exe_name("__tests", cx.target).as_str());
    let brc = engine_build(
        m,
        tsub,
        rootp.as_str(),
        ".",
        loader::dirname_of(m.root.as_str()),
        tsub,
        tbin.as_str(),
        &nolint,
        0,
        topts,
    );
    if brc != 0 {
        return brc;
    }
    return test_run_runner(topts, tbin.as_str());
}

// Every .spc under the suite directory `bdir` of `super-c <cmd>` (test or bench), as
// `import <bdir>::<path>;` lines: a file is part of the suite because of where it lives. Returns how
// many were found.
fn suite_import_root(bdir: str, cmd: str, out: &mut String) usize {
    let mut rels = Vector::<String>::new();
    walk_files(bdir, bdir.len(), &mut rels);
    rels.sort();
    out.push_str("// generated by `super-c ");
    out.push_str(cmd);
    out.push_str("` -- do not edit\n");
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
// this needs (an attribute is recorded by the parser) so nothing here resolves or typechecks.
fn bench_collect(
    rootp: str,
    prefix: str,
    src_dir: str,
    std_dir: str,
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
            // The generated root itself, and anything it pulled in from elsewhere.
            continue;
        }
        let src = p.modules[m].source.as_str();
        let a = p.module_ast_const(mid);
        let nattr = unsafe (*a).attrs.len();
        for ai in 0..nattr {
            let at = unsafe (*a).attrs[ai];
            if at.kind != AttrKind::ATTR_BENCH as u8 {
                continue;
            }
            let fnode = unsafe (*a).at_const(at.owner);
            if fnode.kind != NodeKind::NODE_FUNCTION {
                // The parser already reported this.
                continue;
            }
            if !fnode.as_data.function.is_public() {
                let sp = fnode.span;
                eprintln(
                    "bench: '@bench' function at {}:{} must be 'pub' -- the generated runner calls it from another module",
                    path,
                    sp.start,
                );
                return false;
            }
            let nm = unsafe (*a).at_const(fnode.as_data.function.name).as_data.name.text;
            let mut entry = String::new();
            if at.arg != 0 {
                // `@bench(log_results = false)`: it prints for itself.
                entry.push_byte(b'-');
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
// contributed one (NOT everything under bench/) so a file that merely lives there (a helper, or
// a standalone comparison program with a `main` of its own) is never linked into the runner. Anything a
// benchmark genuinely needs arrives through that benchmark's own imports. Selection is a run-time argument
// (`--filter=S`) rather than part of the generated root, so a filtered run never relinks the bench binary.
fn bench_run_root(found: &Vector<String>, prefix: str, build_id: str, flags: str, out: &mut String) {
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

    // The library owns the run: the selection, one fresh process per benchmark, the pools' shutdown and
    // the exit code (`bench::run`). The root only lists what it found.
    out.push_str("import std::testing::bench as __bench;\n\nfn main(argv: Vector<str>) i32 {\n    __bench::begin(\"");
    out.push_str(build_id);
    out.push_str("\", \"");
    out.push_str(flags);
    out.push_str("\");\n    let mut entries = Vector::<__bench::Entry>::new();\n");
    for i in 0..found.len() {
        let raw = found.at(i).as_str();
        let quiet = raw[0] == b'-';
        let full = if quiet {
            raw.slice(1, raw.len());
        } else {
            raw;
        };
        // The `<bench-dir>::` every one of these starts with says nothing: strip it from the name.
        let name = if full.starts_with(prefix) {
            full.slice(prefix.len(), full.len());
        } else {
            full;
        };
        out.push_str("    entries.push(__bench::Entry { name: \"");
        out.push_str(name);
        out.push_str("\", run: ");
        out.push_str(full);
        out.push_str(", quiet: ");
        out.push_str(
            if quiet {
                "true";
            } else {
                "false";
            },
        );
        out.push_str(" });\n");
    }
    out.push_str("    return __bench::run(&argv, &entries);\n}\n");
}

/// `super-c bench`: discover `@bench` functions under <bench-dir> (default bench/), build a runner
/// for them under the bench profile (by default) into <out-dir>/bench-bin and run it (skipped when
/// `no_run`). A non-empty `filter` runs only the benchmarks whose name contains it.
pub fn manifest_bench(m: &mf::Manifest, profile: str, no_run: bool, filter: str, cx: &BuildCtx) i32 {
    let mut nolint = *cx;
    nolint.lint = false;
    let mut bdir = m.bench_dir.clone();
    if unsafe shim::sc_stat_isdir(bdir.cstr()) != 1 {
        eprintln("bench: no {}/ directory next to src/", bdir.as_str());
        return 1;
    }
    // The module-path prefix the discovery root gives every bench module ("<bench-dir>::").
    let mut bpref = String::new();
    push_module_path(&mut bpref, bdir.as_str());
    bpref.push_str("::");
    // Two passes, because a benchmark is DISCOVERED rather than registered. The first root imports every
    // module under bench/ so they all get parsed; walking those ASTs for `@bench` gives the list; the second
    // root is written with a call to each one. Loading twice is cheap (the first pass only parses) and it
    // is what keeps a bench file from having to be wired into a hand-maintained `main`.
    let mut listing = String::new();
    let nmods = suite_import_root(bdir.as_str(), "bench", &mut listing);
    if nmods == 0 {
        eprintln("bench: no .spc files under {}/", bdir.as_str());
        return 1;
    }
    mkdir_p(m.out_dir.as_str());
    let scanp = loader::join2(m.out_dir.as_str(), "bench_scan.spc");
    if !write_file(scanp.as_str(), listing.as_str()) {
        eprintln("bench: cannot write '{}'", scanp.as_str());
        return 1;
    }
    let mut found = Vector::<String>::new();
    if !bench_collect(
        scanp.as_str(),
        bpref.as_str(),
        loader::dirname_of(m.root.as_str()),
        cx.std_dir,
        cx.bootstrap_tags,
        cx.target,
        &mut found,
    ) {
        return 1;
    }
    if found.len() == 0 {
        eprintln("bench: no '@bench' functions under {}/", bdir.as_str());
        return 1;
    }
    let build_id = git_build_id(".", m.out_dir.as_str());
    let prof_name = if profile.len() != 0 {
        profile;
    } else {
        "bench";
    };
    // The runner prints and records what it was compiled with: the profile, its optimisation level, its
    // C flags and its LTO mode. Quoted into a string literal of the generated root, so no quote survives.
    let mut flags = String::from_str(prof_name);
    let pi = m.profile_index(prof_name);
    if pi >= 0 {
        let prof = m.profiles.at(pi as usize);
        flags.push_byte(b' ');
        flags.push_str(mf::opt_flag(prof.opt));
        for i in 0..prof.cflags.len() {
            flags.push_byte(b' ');
            flags.push_string(prof.cflags.at(i));
        }
        flags.push_str(" lto=");
        flags.push_i64(prof.lto);
    }
    for i in 0..flags.len() {
        if flags.as_str()[i] == b'"' || flags.as_str()[i] == b'\\' {
            flags.set_byte(i, b' ');
        }
    }
    let mut rootsrc = String::new();
    bench_run_root(&found, bpref.as_str(), build_id.as_str(), flags.as_str(), &mut rootsrc);
    let genp = loader::join2(m.out_dir.as_str(), "bench_root.spc");
    if !write_file(genp.as_str(), rootsrc.as_str()) {
        eprintln("bench: cannot write '{}'", genp.as_str());
        return 1;
    }
    let rootp = genp.as_str();
    let sub = loader::join2("bench", prof_name);
    // Bound, not inlined: a `str` taken from a TEMPORARY String dangles the moment the statement ends, and
    // a short name lives inside the String itself, so the borrow points at a dead stack slot.
    let leaf = exe_name("bench-bin", cx.target);
    let bin = loader::join2(m.out_dir.as_str(), leaf.as_str());
    // Rooted at the project root (like tests), so `import bench::x;` works for lint AND build.
    let rc = engine_build(
        m,
        prof_name,
        rootp,
        ".",
        loader::dirname_of(m.root.as_str()),
        sub.as_str(),
        bin.as_str(),
        &nolint,
        0,
        null,
    );
    if rc != 0 || no_run {
        return rc;
    }
    let mut ra = Vector::<String>::new();
    ra.push(bin.clone());
    if filter.len() != 0 {
        let mut fa = String::from_str("--filter=");
        fa.push_str(filter);
        ra.push(fa);
    }
    // A built binary: argv exec, never through a shell.
    return exec_args(&mut ra, null);
}

/// `super-c command <name>`: run a manifest command, building first when it asks for it. Lines run in
/// order; the first nonzero exit stops and is returned.
pub fn manifest_run(m: &mf::Manifest, name: str, profile: str, cx: &BuildCtx) i32 {
    let ci = m.command_index(name);
    if ci < 0 {
        eprintln("run: no command '{}' in build.toml", name);
        return 1;
    }
    let c = m.commands.at(ci as usize);
    if c.needs_build {
        let rc = manifest_build(m, profile, "", cx);
        if rc != 0 {
            return rc;
        }
    }
    // Set in this process, which runs nothing else afterwards, so every line inherits it: a `KEY=v cmd`
    // prefix would need quoting for the shell, and Windows runs the line with no shell at all.
    for e in 0..c.env_k.len() {
        let mut k = c.env_k.at(e).clone();
        let mut v = c.env_v.at(e).clone();
        if unsafe shim::sc_setenv(k.cstr(), v.cstr()) != 0 {
            eprintln("command: cannot set environment variable '{}'", k.as_str());
            return 1;
        }
    }
    for i in 0..c.run.len() {
        let mut cmd = c.run.at(i).clone();
        let rc = unsafe shim::sc_exec(cmd.cstr());
        if rc != 0 {
            return rc;
        }
    }
    return 0;
}

/// `super-c clean`: drop the manifest's outputs; out-dir (per-target raw/gen/obj) plus every
/// `<root dir>/build/<profile>/raw` tree a bare `super-c <root.spc>` emits. A profile directory and
/// the `build` directory go too only when nothing else is in them: they can be the user's own.
pub fn manifest_clean(m: &mf::Manifest) i32 {
    rm_rf(m.out_dir.as_str());
    let b = loader::join2(loader::dirname_of(m.root.as_str()), "build");
    switch list_dir(b.as_str(), false) {
        Some(names) => {
            for i in 0..names.len() {
                // Only an emitted tree: it always holds the runtime header.
                let mut pd = loader::join2(b.as_str(), names.at(i).as_str());
                let raw = loader::join2(pd.as_str(), "raw");
                let mut rt = loader::join2(raw.as_str(), "super_rt.h");
                if unsafe shim::sc_mtime(rt.cstr()) != 0 {
                    rm_rf(raw.as_str());
                    let _ = unsafe shim::sc_rmdir(pd.cstr());
                }
            }
        },
        None => {},
    };
    let mut bc = b.clone();
    let _ = unsafe shim::sc_rmdir(bc.cstr());
    return 0;
}
