// build.toml engine: transpile the root's module closure into <out-dir>/<profile>/raw (the emitter
// writes only the files whose content changed, so an unchanged file keeps its mtime), compile stale
// objects from that tree in parallel with -MMD dep tracking into <out-dir>/<profile>/obj, link, then
// optionally strip. `super-c command <name>` and `super-c clean` live here too.
//
// Process discipline: every compiler, linker, archiver, strip, probe, and git invocation is an argv
// child (sc_spawn_argv, no shell), so paths pass through verbatim: spaces, quotes, non-ASCII. The
// ONE shell survivor is `super-c command`, whose manifest lines are sh/cmd syntax by user contract. Flag
// STRINGS keep their historic whitespace-splitting. compile_commands.json (one `arguments` row per
// TU) lands beside raw/obj; .cmd fingerprints, the link record, and the emit stamp write through
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
import driver::prelude_image as pimg;
import driver::util as *;
import build_system::manifest as mf;
import build_system::objcache as *;
import build_system::probe as pr;
import ast::parser as par;
import ir::cpu_features as cf;
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
// A translation unit whose C text, quoted-include closure, compiler version and compile command all
// match a previous compile reuses that compile's object instead of running the C compiler again.
// The key hashes content, so the cache needs no invalidation story: different content is a
// different key. The content includes paths: the emitted headers name the runtime and extern-block
// headers by absolute path, so a unit that includes a tree's own header gets other keys in a tree
// at another path. System headers (<...>) are outside the key; the compiler-version fingerprint
// stands in for them, the same bet ccache's direct mode makes.
//
// Retention: each local object tree (a profile directory such as build/debug) owns the namespace
// `<root>/o/<hash of its real path>`. A successful build writes the key set of its units as a
// generation file `g<seq>` when the set changed, keeps the newest OBJ_GENS generations, and deletes
// every object and dependency list no kept generation names (`obj_cache_commit`). A sweep every 30 minutes
// (`sweep`, which `super-c clean` runs at once) removes dead namespaces, the unused objects beyond the
// project's `cache-size` and the script namespace's bound, and idle linker caches (`sweep_cache`), and
// the project's idle build trees (`sweep_project`).
// A unit whose object records no path (no coverage or profile instrumentation, `instruments`; debug
// information names the working directory `.`, `dmap`) also goes to the script namespace every tree
// shares, and a miss in the tree's namespace reads it there: another tree that compiled the same text
// with the same command (the runtime of every test fixture) serves it. The key holds the whole command
// but the directory map, so the object is the one this tree's compile would write; an object whose
// bytes still name the working directory (a compiler that ignored the map) stays out of the shared
// namespace.
// The key, the cache root and the namespace that script builds share live in build_system::objcache.

/// The generations an object cache namespace keeps: the current build and three older ones.
const OBJ_GENS: usize = 4;
/// A namespace whose owner directory exists is removed after this many seconds with no entry
/// changed (a build refreshes its current generation at most daily).
const OBJ_NS_IDLE: i64 = 30 * 86400;
/// A linker cache namespace is removed after this many seconds with no entry written or used.
const LTO_NS_IDLE: i64 = 7 * 86400;
/// The sweeps (`sweep`) run at most once per this many seconds.
const SWEEP_EVERY: i64 = 30 * 60;

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
/// its generation's mtime once a day (the age `ns_dead` reads), so a no-op build reads one
/// directory and one file. The trim keeps the newest OBJ_GENS generations and deletes each object
/// and dependency list none of them names. Only builds of this object tree write the namespace, and
/// every object this build installed is in `keys`. A restore that loses a race with the trim cannot
/// open the file and compiles instead. A failed step leaves its files to the next trim. `tree`
/// is the object tree (the profile directory) recorded as the namespace owner: the sweep removes the
/// namespace once that directory is gone.
fn obj_cache_commit(ns: str, keys: &mut Vector<String>, tree: str, now: i64) {
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
    let own = real_path(tree);
    if own.len() != 0 {
        let op = loader::join2(ns, "owner");
        // An owner an older compiler wrote names the source directory: replace it.
        if !has_owner || loader::read_file(op.as_str()).unwrap_or(String::new()).as_str() != own.as_str() {
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

/// An object namespace `name` (directory `ns`) no build reads again: its owner object tree is gone;
/// its owner record names another directory (an older compiler recorded the source directory); it has
/// no owner record and nothing in it changed for TMP_IDLE (a build that stopped before its first
/// commit); or nothing in it (generations, owner record, objects) changed for OBJ_NS_IDLE. The
/// script namespace has no owner and goes only when idle: nothing in any of its subdirectories changed.
fn ns_dead(name: str, ns: str, now: i64) bool {
    if name == SCRIPT_NS {
        let mut newest = newest_mtime(ns);
        let subs = list_dir(ns, false).unwrap_or(Vector::<String>::new());
        for i in 0..subs.len() {
            let mt = newest_mtime(loader::join2(ns, subs.at(i).as_str()).as_str());
            if mt > newest {
                newest = mt;
            }
        }
        return now - newest >= OBJ_NS_IDLE;
    }
    let idle = now - newest_mtime(ns);
    let op = loader::join2(ns, "owner");
    let own = loader::read_file(op.as_str());
    if own.is_none() {
        return idle >= TMP_IDLE;
    }
    let ob = own.unwrap();
    let mut od = String::from_str(ob.as_str());
    if unsafe shim::sc_mtime(od.cstr()) == 0 {
        return true;
    }
    let mut want = String::new();
    hex64(fnv_cont(FNV_BASIS, ob.as_str()), &mut want);
    return want.as_str() != name || idle >= OBJ_NS_IDLE;
}

/// The sweeps after every successful build of project `m` (null for a script build) and by `super-c
/// clean` (`clean`): the cache sweep (`sweep_cache`) at most once per SWEEP_EVERY (the stamp
/// `<root>/o/.sweep`), and the project sweep (`sweep_project`) as often (`<out-dir>/.sweep`). `clean`
/// runs both now and deletes every unused object.
pub fn sweep(m: *const mf::Manifest, now: i64, clean: bool) {
    let croot = if m != null {
        cache_root(project_name(unsafe &*m));
    } else {
        cache_root("");
    };
    if croot.len() != 0 && (clean || sweep_due(loader::join2(croot.as_str(), "o").as_str(), now)) {
        sweep_cache(croot.as_str(), m, now, clean);
    }
    if m != null && (clean || sweep_due(unsafe (*m).out_dir.as_str(), now)) {
        sweep_project(unsafe &*m, now);
    }
}

// Whether the sweep whose stamp is `<dir>/.sweep` is due (no stamp, or one older than SWEEP_EVERY); a
// due sweep restamps first, and one whose stamp cannot be written does not run: every build would sweep.
fn sweep_due(dir: str, now: i64) bool {
    let mut stamp = loader::join2(dir, ".sweep");
    let last = unsafe shim::sc_mtime(stamp.cstr());
    if last != 0 && now - last < SWEEP_EVERY {
        return false;
    }
    mkdir_p(dir);
    let mut body = String::new();
    body.push_i64(now);
    return write_file_atomic(stamp.as_str(), body.as_str());
}

/// The cache root's directory name of project `m`: its `bin`, else its `[lib]` name.
pub const fn project_name<'a>(m: &'a mf::Manifest) str<'a> {
    if m.bin.len() != 0 {
        return m.bin.as_str();
    }
    return m.lib_name.as_str();
}

/// Delete what no build reads again below cache root `root` (`cache_root`) of project `m` (null: the
/// script builds' root): dead object namespaces (`ns_dead`), the prelude images
/// (`prelude_image::sweep`), the unused objects beyond the limits (`trim_objects`: `m`'s `cache-size`,
/// or the script namespace's bound in the script builds' root), or every unused object under `clean`,
/// and linker cache namespaces with no entry written or used for LTO_NS_IDLE (a toolchain upgrade leaves
/// the old one behind).
fn sweep_cache(root: str, m: *const mf::Manifest, now: i64, clean: bool) {
    let od = loader::join2(root, "o");
    let nss = list_dir(od.as_str(), false).unwrap_or(Vector::<String>::new());
    for i in 0..nss.len() {
        let name = nss.at(i).as_str();
        if name.starts_with(".") {
            continue; // the sweep stamp
        }
        let ns = loader::join2(od.as_str(), name);
        if ns_dead(name, ns.as_str(), now) {
            rm_rf(ns.as_str());
        }
    }
    pimg::sweep(root, now);
    if m != null {
        trim_objects(od.as_str(), now, unsafe (*m).cache_size, usize::MAX, usize::MAX, clean);
    } else {
        trim_objects(od.as_str(), now, u64::MAX, SCRIPT_OBJ_MAX, SCRIPT_OBJ_KEEP, clean);
    }
    let ld = loader::join2(root, "lto");
    let ltos = list_dir(ld.as_str(), false).unwrap_or(Vector::<String>::new());
    for i in 0..ltos.len() {
        let lp = loader::join2(ld.as_str(), ltos.at(i).as_str());
        if now - newest_mtime(lp.as_str()) >= LTO_NS_IDLE {
            rm_rf(lp.as_str());
        }
    }
}

/// Delete what no build of manifest `m` reads again: every entry of its out-dir with nothing written
/// for OBJ_NS_IDLE (a build tree, a link record, a binary), except a tree whose lock a build holds; the
/// per-suite object cache that compilers before the shared one kept in `<out-dir>/test/fixture-cache`;
/// and the emitted trees below its root directory (`root_trees`) idle as long.
pub fn sweep_project(m: &mf::Manifest, now: i64) {
    let out = m.out_dir.as_str();
    let names = list_dir(out, false).unwrap_or(Vector::<String>::new());
    for i in 0..names.len() {
        let p = loader::join2(out, names.at(i).as_str());
        if names.at(i).as_str() != ".sweep" && now - newest_mtime(p.as_str()) >= OBJ_NS_IDLE {
            rm_unlocked(p.as_str());
        }
    }
    rm_rf(loader::join2(out, "test/fixture-cache").as_str());
    let trees = root_trees(m);
    for i in 0..trees.len() {
        let raw = loader::join2(trees.at(i).as_str(), "raw");
        if now - newest_mtime(raw.as_str()) >= OBJ_NS_IDLE {
            rm_root_tree(trees.at(i).as_str());
        }
    }
}

// Remove out-dir entry `p` unless a build holds the lock of a tree in it: `<p>/.lock`, or
// `<p>/<sub>/.lock` for a nested tree (`bench/<profile>`). The locks taken stay held while the entry
// goes, and a second pass removes what an open lock file kept (Windows deletes no open file).
fn rm_unlocked(p: str) {
    let mut locks = Vector::<String>::new();
    locks.push(loader::join2(p, ".lock"));
    let subs = list_dir(p, false).unwrap_or(Vector::<String>::new());
    for i in 0..subs.len() {
        locks.push(loader::join2(loader::join2(p, subs.at(i).as_str()).as_str(), ".lock"));
    }
    let mut held = Vector::<i64>::new();
    let mut busy = false;
    for i in 0..locks.len() {
        let mut lp = locks.at(i).clone();
        if !busy && unsafe shim::sc_mtime(lp.cstr()) != 0 {
            let h = unsafe shim::sc_tree_lock(lp.cstr(), 0);
            if h < 0 {
                busy = true;
            } else {
                held.push(h);
            }
        }
    }
    if !busy {
        rm_rf(p);
    }
    for i in 0..held.len() {
        unsafe shim::sc_tree_unlock(held[i]);
    }
    if !busy {
        rm_rf(p);
    }
}

// The emitted trees below the root directory of manifest `m` (`<root dir>/build/<profile>`, of bare
// and script builds): only a directory whose `raw` holds the runtime header, so a user directory named
// `build` is never one. Their emission rewrites `raw/__sc_manifest` every time, which keeps the idle
// age of a tree in use low. None when that directory is the manifest's out-dir (`root = "main.spc"`
// with the default `out-dir`): its trees are the engine's, swept with their locks as out-dir entries.
fn root_trees(m: &mf::Manifest) Vector<String> {
    let mut out = Vector::<String>::new();
    let b = loader::join2(loader::dirname_of(m.root.as_str()), "build");
    let rb = real_path(b.as_str());
    if rb.len() != 0 && rb.as_str() == real_path(m.out_dir.as_str()).as_str() {
        return out;
    }
    let names = list_dir(b.as_str(), false).unwrap_or(Vector::<String>::new());
    for i in 0..names.len() {
        let pd = loader::join2(b.as_str(), names.at(i).as_str());
        let mut rt = loader::join2(pd.as_str(), "raw/super_rt.h");
        if unsafe shim::sc_mtime(rt.cstr()) != 0 {
            out.push(pd);
        }
    }
    return out;
}

// Remove emitted tree `pd` (`root_trees`) unless a build holds its lock (`<pd>/.lock`, which every
// build of it takes): its `raw` tree, the objects of its script builds and the lock file, then the
// directory and its `build` parent when nothing else is left in them. The lock stays held while the
// tree goes, and the lock file goes again once it is released (Windows deletes no open file).
fn rm_root_tree(pd: str) {
    let mut lp = loader::join2(pd, ".lock");
    let h = unsafe shim::sc_tree_lock(lp.cstr(), 0);
    if h < 0 {
        return;
    }
    rm_rf(loader::join2(pd, "raw").as_str());
    rm_rf(loader::join2(pd, "obj").as_str());
    let _ = unsafe shim::sc_unlink(lp.cstr());
    unsafe shim::sc_tree_unlock(h);
    let _ = unsafe shim::sc_unlink(lp.cstr());
    let mut d = String::from_str(pd);
    let _ = unsafe shim::sc_rmdir(d.cstr());
    let mut b = String::from_str(loader::dirname_of(pd));
    let _ = unsafe shim::sc_rmdir(b.cstr());
}

// The gen-tree prefix in a stored .d is replaced by `@/`, so a dependency list written in one project
// reads correctly in every other; paths outside the tree (absolute backing headers) stay as written.
// A clang unit that loads the precompiled header (`CcStream::start_pch`) lists the header's inputs by
// the absolute paths the header recorded, through `aobj`, the object tree's absolute path: the emitted
// tree as `<aobj>/../raw/` becomes `@/` too, and `<aobj>/` becomes `@/../obj/`.
fn dep_portable(s: str, gen: str, aobj: str) String {
    let mut out = String::new();
    let og = format("{}/../{}/", aobj, loader::basename_of(gen));
    let ob = format("{}/", aobj);
    let mut i: usize = 0;
    while i < s.len() {
        if s.slice(i, s.len()).starts_with(og.as_str()) {
            out.push_str("@/");
            i += og.len();
        } else if s.slice(i, s.len()).starts_with(ob.as_str()) {
            out.format_into("@/../{}/", loader::basename_of(aobj));
            i += ob.len();
        } else if i + gen.len() < s.len() && s.slice(i, i + gen.len()) == gen && s[i + gen.len()] == b'/' {
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

// Whether file `a` holds exactly `want`. Streamed in fixed chunks: comparing never holds a second copy
// of the file in memory.
fn file_eq(a: str, want: str) bool {
    let f = stdio::fopen(a, "rb");
    if f == null {
        return false;
    }
    let mut buf = Array::<u8, 16384>::new();
    let mut off: usize = 0;
    let mut same = true;
    loop {
        let n = unsafe stdio::fread(&mut buf[0], 1, 16384, f);
        if n == 0 {
            break;
        }
        if off + n > want.len() || unsafe str::from_raw(&buf[0], n) != want.slice(off, off + n) {
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

// Staleness: obj or its -MMD .d file missing, or any dependency in the .d file newer than the object.
// Every compile writes a .d, so an object without one has unknown header dependencies.
// Is the object older than its source or any recorded dependency? The object's time is the mtime of its
// `.cmd` record (`cmdpath`), which the tree's compile or cache restore writes once the object is in
// place: the object itself is a name of a cache entry, whose mtime another tree's use refreshes.
// Times compare in nanoseconds (100 ns steps on Windows): an edit of a header landing in the same second
// its unit's object was compiled is newer. A file system that keeps whole seconds rounds both times
// alike, so a file the emission rewrote in this build counts as newer whatever its mtime says.
fn obj_stale(
    cpath: &mut String,
    opath: &mut String,
    cmdpath: &mut String,
    dpath: str,
    rewritten: &Set<String>,
    gen: str,
    mtimes: &mut Map<String, i64>,
) bool {
    let omt = unsafe shim::sc_mtime_ns(cmdpath.cstr());
    if omt == 0 || unsafe shim::sc_mtime(opath.cstr()) == 0 {
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
                    let v9 = unsafe shim::sc_mtime_ns(dep_path.cstr());
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

// Whether `path` (as the compiler's dependency list spells it) is a tree file rewritten this build.
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

// Profile flags, minus what the target cannot honour. mingw ships no libasan/libubsan, so the
// `--sanitizers` flags `-fsanitize*` would fail the link on Windows: there they are dropped instead
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
/// plain build rather than failing; `sanitizers` (`--sanitizers`) adds the sanitizer flags to any build,
/// a build without a profile included. `target` drops what that target cannot honour, exactly as a
/// manifest build does.
pub fn profile_flags(name: str, target: i32, sdk: i32, compile_only: bool, sanitizers: bool) String {
    let mut out = String::new();
    let m = mf::builtins_only();
    let pi = if name.len() == 0 {
        (-1) as i64;
    } else {
        m.profile_index(name);
    };
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
    // After the profile's flags, as a manifest build appends them to each profile's own.
    if sanitizers {
        let mut sf = Vector::<String>::new();
        split_args(&mut sf, mf::SANITIZER_CFLAGS);
        if !compile_only {
            split_args(&mut sf, mf::SANITIZER_LDFLAGS);
        }
        push_profile(&mut out, &sf, target, sdk);
    }
    return out;
}

/// The LTO mode a build without a manifest compiles built-in profile `name` with (`profile_flags`):
/// its mode, a ThinLTO request as `auto`; LTO_NONE for an unknown name.
pub fn profile_lto(name: str) i32 {
    let m = mf::builtins_only();
    let pi = m.profile_index(name);
    if pi < 0 {
        return mf::LTO_NONE;
    }
    let l = m.profiles.at(pi as usize).lto;
    return pick(l == mf::LTO_THIN, mf::LTO_AUTO, l);
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
    pub sobj: String, // its install target in the shared script namespace; empty = none
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
    pub sobj: String,
    pub oout: String,
    pub dout: String,
}

extend Job {
    // On success, persist fingerprint, duration and cache key, and install the object into the global
    // cache (`cache_install`), in the tree's namespace and the shared one. On failure, report the exit
    // status and replay a bounded part of the captured compiler output; the log file stays for
    // inspection (the unit's next successful compile removes it).
    // `gen` is the gen root, which the portable .d rewrite replaces.
    fn finish(self: &mut Self, code: i32, gen: str, aobj: str, cwds: &Vector<String>) i32 {
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
            cache_install(self.cobj.as_str(), self.oout.as_str(), self.dout.as_str(), gen, aobj);
            if self.sobj.len() != 0 && !names_any(self.oout.as_str(), cwds) {
                cache_install(self.sobj.as_str(), self.oout.as_str(), self.dout.as_str(), gen, aobj);
            }
        }
        unsafe shim::sc_unlink(self.log.cstr());
        return code;
    }
}

// Install object `oout` (as a second name, `link_or_copy`) and its dependency list `dout` (made
// portable: `gen` is the gen root, `aobj` the object tree's absolute path) as cache entry `cobj` (none
// when empty), each through a temp named by the key and the pid and a rename, so concurrent builds
// never write the same temp file.
fn cache_install(cobj: str, oout: str, dout: str, gen: str, aobj: str) {
    if cobj.len() == 0 {
        return;
    }
    mkdir_p(loader::dirname_of(cobj));
    let pid = unsafe shim::sc_getpid();
    let mut tmp = format("{}.{}.tmp", cobj, pid);
    let mut oc = String::from_str(cobj);
    if !link_or_copy(oout, tmp.as_str()) || unsafe shim::sc_rename(tmp.cstr(), oc.cstr()) != 0 {
        let _ = unsafe shim::sc_unlink(tmp.cstr());
    }
    let dep = loader::read_file(dout);
    if !dep.is_none() {
        let d = dep.unwrap();
        let port = dep_portable(d.as_str(), gen, aobj);
        let mut dtmp = format("{}.{}.d.tmp", cobj, pid);
        let mut cd = String::from_str(cobj.slice(0, cobj.len() - 2));
        cd.push_str(".d");
        if !write_file(dtmp.as_str(), port.as_str()) || unsafe shim::sc_rename(dtmp.cstr(), cd.cstr()) != 0 {
            let _ = unsafe shim::sc_unlink(dtmp.cstr());
        }
    }
}

// Whether file `path` contains one of `words` (true when it cannot be read).
fn names_any(path: str, words: &Vector<String>) bool {
    let t = loader::read_file(path);
    if t.is_none() {
        return true;
    }
    let b = t.unwrap();
    for i in 0..words.len() {
        if b.as_str().find(words.at(i).as_str()) >= 0 {
            return true;
        }
    }
    return false;
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
// links its own, so a `debug` build can never end up standing in for the release artifact: the manifest's
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
    if file_eq(to, body.as_str()) {
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
// a TU's compile job is spawned while later TUs are still being emitted. The emit pass writes all
// headers before the first source, so a source's compile can never miss an include. Reaping in-flight jobs uses sc_try_wait only: the blocking sc_wait_any
// (waitpid(-1)) would steal the emit workers' exit statuses while they are alive.
struct CcStream {
    pub src_len: usize, // gen_root prefix; rel = path[src_len+1..]
    pub gen: String, // the emitted tree the compiles read: <pdir>/raw
    pub obj: String,
    pub aobj: String, // `obj` as an absolute path (`dep_portable`)
    pub pdir: String,
    pub cc_raw: String, // the compiler named by the manifest, $CC or the default
    pub cc_file: String, // the path every compile and link spawn runs (`cc_stream`); empty: PATH-searched
    pub cc_tail: String, // " <cstd> <cflags> <profile cflags> -MMD -c [-flto=..]" (also the object-cache key text)
    pub ldbase: String, // " <sdk flags and libs> <ldflags> <profile ldflags>": the fixed part of the link line
    pub target: i32,
    pub lto_req: i32, // the profile's `lto` mode (SC_LTO overrides it)
    pub lto: i32, // the mode in use once ensure_cc ran: lto_req, or LTO_AUTO for a rejected ThinLTO request
    pub lto_cache: bool, // the link line names a ThinLTO cache directory
    pub lto_reason: String, // why ThinLTO or its cache was rejected; empty when both are in use
    pub lto_ld: Vector<String>, // the mode's link arguments: `-flto=..` and the linker cache options
    pub probe_ver_pid: i64, // background `<cc> --version` probe; -1 = resolve synchronously
    pub ccver_path: String, // <pdir>/.ccver, the version probe's output file
    pub probes: pr::Probes, // the toolchain probe record and the probes this build needs
    pub feats: cf::CpuFeatureSet, // the build's CPU features beyond the baseline: their flags' probes must accept them
    pub feat_bad: bool, // a feature's flag was rejected: nothing compiles
    pub cc_args: Vector<String>, // resolved compiler argv (the cc tokens); empty until ensure_cc
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
    // ran is redone even when the objects' times (their `.cmd` records') fall in the second the binary
    // was linked.
    pub pending: String,
    pub marked: bool, // this build wrote `pending`
    pub ret: i32,
    pub croot: String, // the project's cache root (`cache_root`), also with the object cache off
    pub cache: String, // this object tree's namespace of the project's object cache; empty = disabled
    pub shared: String, // the script namespace, when the objects record no path; empty = not shared
    pub cwds: Vector<String>, // the working directory's spellings, which no shared object may contain
    pub dmap: Vector<String>, // under debug information: each of `cwds` mapped to `.`
    pub keys: Vector<String>, // the cache key of every planned unit that has one (`obj_cache_commit`)
    pub rewritten: Set<String>, // tree-relative files whose content this build's emission changed
    pub mtimes: Map<String, i64>, // dependency path (as a depfile spells it) -> its mtime, stat once per build
    pub ccdb: Vector<String>, // compile_commands.json rows, one per planned unit (stale or not)
    /// Object-cache hashing memo and the texts it reads from memory (headers and unity members as
    /// the emitter handed them over, by normalized path); see `ch_hash_file`.
    pub hmemo: Map<String, u64>,
    pub hpool: Vector<u64>,
    pub htext: Map<String, String>,
    pub ccdb_dir: String, // absolute working directory the compile argv is relative to
    pub pch: i32, // the precompiled header's state: PCH_OFF, PCH_RUN, PCH_ON or PCH_FAIL (`start_pch`)
    pub pch_stub: String, // <obj>/__sc_fwd.h: includes the tree's `__sc_fwd.h`; a unit names it in `-include`
    pub pch_out: String, // <obj>/__sc_fwd.h.gch, the precompiled header the compiler finds for the stub
    pub pch_key: String, // " | pch <hash>": the content of `__sc_fwd.h` and its includes; ends every fingerprint
    pub pch_wait: Vector<String>, // tree-relative units that use the precompiled header, planned once it is built
    pub icc1: bool, // the units of a large tree (`start_pch`) take `-fintegrated-cc1`
}

/// The states of a build's precompiled header (`CcStream::start_pch`): none (a small program's tree),
/// its compile runs (the units that use it wait), in use, or not usable (the compile failed: the units
/// parse the header text).
const PCH_OFF: i32 = 0;
const PCH_RUN: i32 = 1;
const PCH_ON: i32 = 2;
const PCH_FAIL: i32 = 3;

// Whether emitted tree `gen` compiles its units through the precompiled header of `__sc_fwd.h`: the
// `pch` line of its `__sc_shards` (`driver::emit::run_package`).
fn tree_pch(gen: str) bool {
    let t = loader::read_file(loader::join2(gen, "__sc_shards").as_str());
    return t.is_some() && t.unwrap().as_str().contains("\npch\t1\n");
}

// Whether tree-relative unit `rel` starts with `#include "<..>__sc_fwd.h"`: every unit the emitter writes
// but the external C wrappers (`__ext<N>_<stem>.c`) and the test runner.
const fn fwd_unit(rel: str) bool {
    return rel != "__test_main.c" && !rel.starts_with("__ext");
}

extend CcStream {
    /// Finish compiler resolution: collect the background probe (`cc --version` first line, which
    /// overlaps the transpile), or run it synchronously when its spawn failed. No shell anywhere: the
    /// probe is an argv child with captured output. Idempotent; called before the first compile command
    /// is built and again before the link line.
    pub fn ensure_cc(self: &mut Self) {
        if self.cc_ready {
            return;
        }
        self.cc_ready = true;
        split_args(&mut self.cc_args, self.cc_raw.as_str());
        let mut have_ver = self.ccver.len() != 0;
        if !have_ver && self.probe_ver_pid >= 0 {
            let mut code2: i32 = 0;
            let _ = unsafe shim::sc_waitpid(self.probe_ver_pid, &mut code2);
            let v = take_first_line(self.ccver_path.as_str());
            if !v.is_none() {
                let line = v.unwrap();
                ccver_record(self.cc_raw.as_str(), &line);
                self.ccver.push_string(&line);
                have_ver = true;
            }
        }
        if !have_ver {
            self.ccver = cc_version(self.cc_raw.as_str(), self.pdir.as_str());
        }
        self.probes.settle(&self.ccver);
        self.lto_resolve();
        // Each enabled feature's flag passed its probe: a rejected one fails the build here, before any
        // compile, and every result used joins the command fingerprint.
        if !features_pass(&mut self.probes, self.feats, self.target, self.cc_raw.as_str()) {
            self.ret = 1;
            self.feat_bad = true;
        }
        self.probes.save();
        let lf = mf::lto_flag(self.lto);
        if lf.len() != 0 {
            self.cc_tail.push_byte(b' ');
            self.cc_tail.push_str(lf);
            push_arg(&mut self.lto_ld, lf);
        }
        let mut nv = String::new();
        if push_novec(&mut self.probes, self.lto, &mut nv) {
            self.cc_tail.push_string(&nv);
        }
        // The link takes it too: under LTO it generates the code.
        let mut uvm = String::new();
        if push_uvm(&mut self.probes, &mut uvm) {
            self.cc_tail.push_string(&uvm);
            self.ldbase.push_string(&uvm);
        }
        self.prefix_args = clone_args(&self.cc_args);
        split_args(&mut self.prefix_args, self.cc_tail.as_str());
        if self.cache.len() != 0 {
            mkdir_p(self.cache.as_str());
            if !instruments(&self.prefix_args) {
                self.shared = script_ns(self.croot.as_str());
                mkdir_p(self.shared.as_str());
            }
        }
        // The compiler spells the working directory as `$PWD` when that names it, else as its real
        // path (with `\` on Windows): under debug information each maps to `.`, so the object does not
        // depend on the tree it was compiled in.
        if self.shared.len() != 0 {
            self.cwds.push(self.ccdb_dir.clone());
            let pwd = stdlib::get_env("PWD").unwrap_or(String::new());
            if pwd.len() != 0 && real_path(pwd.as_str()).as_str() == self.ccdb_dir.as_str() && pwd.as_str() != self.ccdb_dir.as_str() {
                self.cwds.push(pwd);
            }
            if self.ccdb_dir.len() > 2 && self.ccdb_dir.as_str()[1] == b':' {
                let mut bs = self.ccdb_dir.clone();
                bs.replace_byte(b'/', b'\\');
                self.cwds.push(bs);
            }
            for i in 0..pick(debug_info(&self.prefix_args), self.cwds.len(), 0) {
                self.dmap.push(format("-fdebug-prefix-map={}=.", self.cwds.at(i).as_str()));
            }
        }
    }

    /// Settle the LTO mode. A ThinLTO request needs the toolchain's answer: the probe record's `thin-lto`
    /// result (the verdict, then the linker's path and mtime; the record's key holds the compiler and
    /// its command, the target and the flags) gives it without a process while the linker is unchanged, else `lto_probe`
    /// measures it. A rejected request keeps `-flto=auto`, the mode the profiles used before ThinLTO,
    /// and `lto_reason` names why. The verdict joins the build's used probe results. The linker cache
    /// directory is `<cache root>/lto/<hash of the key below and the linker line>`: one namespace per
    /// compiler command, linker, target, flag set and schema, pruned by the linker itself (`lto_cache_args`).
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
        key.push_string(&self.cc_raw);
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
        if self.croot.len() == 0 {
            return;
        }
        let mut dir = loader::join2(self.croot.as_str(), "lto/");
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

    /// One finished file of the tree: a rewritten one joins `rewritten`; a source also gets its
    /// compile planned (`text`, empty when the file must be read, keys the object cache) and the pool
    /// pumped. The text of any other file is kept for the object-cache key of the units that include it.
    pub fn on_file(self: &mut Self, path: str, text: str, kind: i32, changed: bool) {
        let rel = path.slice(self.src_len + 1, path.len());
        if changed {
            self.rewritten.insert(String::from_str(rel));
        }
        if kind != 1 {
            if text.len() != 0 && self.cache.len() != 0 {
                let mut key = String::new();
                norm_path(path, &mut key);
                self.htext.insert(key, String::from_str(text));
            }
            if kind == 2 {
                self.start_pch(text);
                self.pump();
            }
            return;
        }
        self.plan_c(rel, text);
        self.pump();
    }

    /// Plan the precompiled header of the tree's `__sc_fwd.h` (the system headers, the runtime and the
    /// std C headers), which every unit of a large program parses first. The stub `<obj>/__sc_fwd.h`
    /// includes it; compiled as a C header it becomes `<obj>/__sc_fwd.h.gch`, and a unit that names the
    /// stub in `-include` loads that file in place of the text: gcc finds it beside the stub, the clang
    /// driver turns the option into `-include-pch`. A gcc that rejects the file reads the stub.
    /// The header's record (`.cmd`) holds the fingerprint of its command, of the working directory (the
    /// file records its inputs' paths) and of the content of the header and its quoted includes
    /// (`pch_key`), which also ends every unit's fingerprint: a changed header compiles both again, so
    /// no unit loads a precompiled header of other text (gcc checks no input, and its dependency list of a
    /// unit names none of the precompiled header's includes). Where the `pch-no-timestamp` probe accepts
    /// it, clang checks only the sizes of the inputs, so an input touched with unchanged content (an
    /// older mtime too) does not fail a unit; the header's dependency list compiles it again after a
    /// touch. The compile starts before any unit, and the units that use it wait in `pch_wait`
    /// (`pch_done`). A failed compile is recorded under its fingerprint: the units then parse the text,
    /// and the next build tries again only once the fingerprint changed. Where the `integrated-cc1`
    /// probe accepts it, these units and the header compile with `-fintegrated-cc1`: no second process
    /// per unit. Both probes run here, once per probe record.
    pub fn start_pch(self: &mut Self, text: str) {
        self.ensure_cc();
        if self.feat_bad || self.pch != PCH_OFF {
            return;
        }
        self.pch = PCH_FAIL;
        self.probes.require(1u64 << pr::ICC1 as u64 | 1u64 << pr::PCH_NO_TIME as u64);
        self.icc1 = self.probes.res.at(pr::ICC1).as_str() == "accepted";
        let fwd = loader::join2(self.gen.as_str(), "__sc_fwd.h");
        let mut h1 = FNV_BASIS;
        let mut h2: u64 = 0x9e3779b97f4a7c15;
        if !ch_hash_file(&fwd, text, &mut h1, &mut h2, 0, &mut self.hmemo, &mut self.hpool, &self.htext) {
            return;
        }
        self.pch_key.push_str(" | pch ");
        hex64(h1, &mut self.pch_key);
        hex64(h2, &mut self.pch_key);
        self.pch_stub = loader::join2(self.obj.as_str(), "__sc_fwd.h");
        self.pch_out = format("{}.gch", self.pch_stub.as_str());
        // Relative: the object tree and the emitted tree are siblings in the profile directory.
        let stub = format("#include \"../{}/__sc_fwd.h\"\n", loader::basename_of(self.gen.as_str()));
        if !file_eq(self.pch_stub.as_str(), stub.as_str()) && !write_file(self.pch_stub.as_str(), stub.as_str()) {
            return;
        }
        let mut args = clone_args(&self.prefix_args);
        if self.icc1 {
            push_arg(&mut args, "-fintegrated-cc1");
        }
        if self.probes.res.at(pr::PCH_NO_TIME).as_str() == "accepted" {
            split_args(&mut args, pr::table()[pr::PCH_NO_TIME].flags);
        }
        push_arg(&mut args, "-x");
        push_arg(&mut args, "c-header");
        args.push(self.pch_stub.clone());
        push_arg(&mut args, "-o");
        args.push(self.pch_out.clone());
        let mut fp = self.ccver.clone();
        fp.push_str(" | ");
        fp.push_str(render_cmd(&args).as_str());
        push_used(&mut fp, &self.probes.used);
        fp.push_string(&self.pch_key);
        // The header records the paths of its inputs: a tree that moved compiles it again.
        fp.push_str(" | in ");
        fp.push_string(&self.ccdb_dir);
        for i in 0..self.dmap.len() {
            args.push(self.dmap.at(i).clone());
        }
        let mut cmdpath = format("{}.cmd", self.pch_stub.as_str());
        let dpath = format("{}.d", self.pch_stub.as_str());
        let mut opath = self.pch_out.clone();
        let old = loader::read_file(cmdpath.as_str());
        if !old.is_none() {
            let ob = old.unwrap();
            if field_of(ob.as_str(), b'\n', 0) == fp.as_str() {
                if field_of(ob.as_str(), b'\n', 2) == "fail" {
                    return;
                }
                if !obj_stale(
                    &mut self.pch_stub,
                    &mut opath,
                    &mut cmdpath,
                    dpath.as_str(),
                    &self.rewritten,
                    self.gen.as_str(),
                    &mut self.mtimes,
                ) {
                    self.pch = PCH_ON;
                    return;
                }
            }
        }
        // A compiler may write the file in place: no record names a file a stopped build left torn.
        let _ = unsafe shim::sc_unlink(cmdpath.cstr());
        let _ = unsafe shim::sc_unlink(opath.cstr());
        self.pch = PCH_RUN;
        self.pend_push(
            Pend {
                args: args,
                fp: fp,
                log: format("{}.log", opath.as_str()),
                cmdpath: cmdpath,
                prev_ms: 0x7FFFFFFFFFFFFFFF, // first: every unit that uses it waits
                cobj: String::new(),
                sobj: String::new(),
                oout: opath,
                dout: dpath,
                seq: 0,
            },
        );
    }

    // The precompiled header's compile `j` ended with `code`: record it, then plan the units that wait.
    fn pch_done(self: &mut Self, j: &mut Job, code: i32) {
        if code == 0 {
            let _ = j.finish(0, self.gen.as_str(), self.aobj.as_str(), &self.cwds);
            self.pch = PCH_ON;
        } else {
            self.pch = PCH_FAIL;
            let rec = format("{}\n0\nfail", j.fp.as_str());
            let _ = write_file_atomic(j.cmdpath.as_str(), rec.as_str());
            let _ = unsafe shim::sc_unlink(j.oout.cstr());
            let _ = unsafe shim::sc_unlink(j.log.cstr());
        }
        let wait = replace(&mut self.pch_wait, Vector::<String>::new());
        for i in 0..wait.len() {
            self.plan_c(wait.at(i).as_str(), "");
        }
    }

    // Reap the finished job `j` (exit status `code`).
    fn reap(self: &mut Self, j: &mut Job, code: i32) {
        if self.pch == PCH_RUN && j.oout.as_str() == self.pch_out.as_str() {
            self.pch_done(j, code);
        } else if j.finish(code, self.gen.as_str(), self.aobj.as_str(), &self.cwds) != 0 {
            self.ret = 1;
        }
    }

    /// Staleness + command construction for one tree-relative .c (`text`: its content, empty when it
    /// must be read); stale units join pend, every unit's object joins the link list. A unit that uses
    /// the precompiled header waits while it compiles (and is read again when it is planned).
    pub fn plan_c(self: &mut Self, rel: str, text: str) {
        self.ensure_cc();
        if self.feat_bad {
            return;
        }
        let large = self.pch != PCH_OFF && fwd_unit(rel);
        if large && self.pch == PCH_RUN {
            self.pch_wait.push(String::from_str(rel));
            return;
        }
        let pch = large && self.pch == PCH_ON;
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
        if large && self.icc1 {
            push_arg(&mut args, "-fintegrated-cc1");
        }
        let np = args.len();
        if pch {
            push_arg(&mut args, "-include");
            args.push(self.pch_stub.clone());
        }
        args.push(cpath.clone());
        push_arg(&mut args, "-o");
        args.push(opath.clone());
        let mut fp = self.ccver.clone();
        fp.push_str(" | ");
        let rendered = render_cmd(&args);
        fp.push_string(&rendered);
        for i in 0..self.dmap.len() {
            args.push(self.dmap.at(i).clone());
        }
        push_used(&mut fp, &self.probes.used);
        if pch {
            fp.push_string(&self.pch_key);
        }
        // compile_commands.json row (every unit, stale or not): tooling attaches to the generated
        // tree through it, so it reflects the exact argv this build would run, but the precompiled
        // header (the unit includes the same header first): a tool of another compiler version cannot
        // load it.
        {
            let mut row = String::from_str("  {\"directory\": ");
            json::dump_escaped(self.ccdb_dir.as_str(), &mut row);
            row.push_str(", \"file\": ");
            json::dump_escaped(cpath.as_str(), &mut row);
            row.push_str(", \"output\": ");
            json::dump_escaped(opath.as_str(), &mut row);
            row.push_str(", \"arguments\": [");
            for ai in 0..args.len() {
                if pch && (ai == np || ai == np + 1) {
                    continue;
                }
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
            &mut cmdpath,
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
            let mut sobj = String::new();
            if self.cache.len() != 0 {
                // The whole command (the unit's and the object's paths too), so a tree that shares the
                // key compiled exactly this.
                let mut h1 = FNV_BASIS;
                let mut h2: u64 = 0x9e3779b97f4a7c15;
                ch_mix_bytes(&mut h1, &mut h2, self.ccver.as_str().ptr(), self.ccver.len());
                ch_mix_bytes(&mut h1, &mut h2, rendered.as_str().ptr(), rendered.len());
                if ch_hash_file(&cpath, text, &mut h1, &mut h2, 0, &mut self.hmemo, &mut self.hpool, &self.htext) {
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
                    if self.shared.len() != 0 {
                        sobj = script_entry(self.shared.as_str(), keyname.as_str());
                        if self.cache_restore(&sobj, opath.as_str(), dpath.as_str(), &fp) {
                            touch_entry(sobj.as_str());
                            self.objs.push(opath.clone());
                            return;
                        }
                    }
                }
            }
            // The old object may be a name of a cache entry: a compiler that writes its output in
            // place (GNU as) would rewrite the entry.
            let _ = unsafe shim::sc_unlink(opath.cstr());
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
                    sobj: sobj,
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

    // A cache hit: the object links into place (`link_or_copy`), its portable dependency list is
    // written beside it, and the .cmd records the fingerprint so the next build's staleness check needs
    // no cache at all. An entry
    // without its dependency list is a miss: a restored object without a .d would never see a
    // header change (a concurrent build can publish the object before its list).
    fn cache_restore(self: &mut Self, cobj: &String, opath: str, dpath: str, fp: &String) bool {
        let mut cd = cobj.clone();
        cd.truncate(cd.len() - 2);
        cd.push_str(".d");
        let dep = loader::read_file(cd.as_str());
        if dep.is_none() || !link_or_copy(cobj.as_str(), opath) {
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
        // An earlier failed compile's log describes text the restored object replaces, as after a compile.
        let mut lg = String::from_str(opath);
        lg.push_str(".log");
        let _ = unsafe shim::sc_unlink(lg.cstr());
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
        if self.probe_ver_pid >= 0 {
            let _ = unsafe shim::sc_waitpid(self.probe_ver_pid, &mut code);
        }
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
                self.reap(&mut j, code);
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
        let pid = spawn_at(file_of(&mut self.cc_file), &mut w.args, w.log.cstr());
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
                sobj: replace(&mut w.sobj, String::new()),
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
            self.pch_wait.truncate(0);
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
            self.reap(&mut j, code);
        }
    }
}

// Longest previous duration first; among equal durations the earliest queued.
const fn pend_before(a: &Pend, b: &Pend) bool {
    return a.prev_ms > b.prev_ms || a.prev_ms == b.prev_ms && a.seq < b.seq;
}

fn stream_notify(ctx: *mut void, path: str, text: str, kind: i32, changed: bool) {
    let s = ctx as *mut CcStream;
    unsafe (*s).on_file(path, text, kind, changed);
}

// Emit stamp: skip the whole transpile when no input changed since the last successful emission.
// The stamp records every input the emitted tree is a function of: the emitting compiler (its content
// hash, `compiler_id`), the emission-relevant options, and every loaded module file, the manifest and
// every external C input as (mtime, content id: `str_id`, which `file_id` gives for the file). A
// per-module skip would be UNSOUND here (owner-emitted instances and the shared headers make every TU
// depend on the whole import closure); the whole-package check is exact. A module and the manifest are
// recorded as the build read them (`Module.src_id`, the mtime of the stat before the read), so an edit
// made during the build fails the next check. mtime is only the fast path: a drifted mtime with
// matching content still counts as fresh (and refreshes the stamp), so git checkouts do not force
// rebuilds. SC_NO_EMIT_CACHE disables.

/// The stamp format, its first line.
const STAMP_HEAD: str<'static> = "sc-emit-stamp v4";

// Field `idx` of the tab-separated stamp record `line`: the whole field or `stamp_u64` as a decimal
// number (0 when it is not one: the check then fails and the stamp is rewritten).
fn stamp_field(line: str, idx: usize) str {
    return field_of(line, b'\t', idx);
}

fn stamp_u64(line: str, idx: usize) u64 {
    return stamp_field(line, idx).parse_u64().unwrap_or(0);
}

/// What the emit stamp takes before the load reads any input: the clock (`sc_ticks_ms`), and the mtime
/// and `.spc` listing (`stamp_dir_hash`) of the std directory, the prelude's file set.
struct StampLoad {
    pub t0: i64,
    pub std_mt: i64,
    pub std_h: u64,
}

fn stamp_load(std_dir: str) StampLoad {
    let mut sl = StampLoad { t0: unsafe shim::sc_ticks_ms(), std_mt: 0, std_h: 0 };
    if std_dir.len() != 0 {
        let mut sd = String::from_str(std_dir);
        sl.std_mt = unsafe shim::sc_mtime(sd.cstr());
        sl.std_h = stamp_dir_hash(std_dir);
    }
    return sl;
}

// The whole seconds since `t0` (`sc_ticks_ms`), rounded up.
fn stamp_lag(t0: i64) u64 {
    return ((unsafe shim::sc_ticks_ms() - t0 + 999) / 1000) as u64;
}

// The emitting compiler's record: its content hash (`compiler_id`), taken once before the emission, and
// `lag`, the seconds by which the record's mtimes can predate its write (`stamp_lag`).
fn stamp_exe_line(out: &mut String, cid: u64, lag: u64) {
    out.push_str("exe\t");
    out.push_u64(cid);
    out.push_str("\t");
    out.push_u64(lag);
    out.push_str("\n");
}

// The record of the file at `path` as it is now: its mtime, then its content id; false when it cannot
// be read.
fn stamp_push_input(out: &mut String, path: str) bool {
    let mut pp = String::from_str(path);
    let mt = unsafe shim::sc_mtime(pp.cstr());
    if mt == 0 {
        return false;
    }
    let h = file_id(path);
    if h == 0 {
        return false;
    }
    stamp_line(out, "in\t", mt as u64, h, path);
    return true;
}

// One stamp record: `kind` (with its tab), then mtime, hash and path.
fn stamp_line(out: &mut String, kind: str, mt: u64, h: u64, path: str) {
    out.push_str(kind);
    out.push_u64(mt);
    out.push_str("\t");
    out.push_u64(h);
    out.push_str("\t");
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
        let nm = unsafe str::from_cstr(shim::sc_dirent_name(e));
        if !nm.ends_with(".spc") {
            continue;
        }
        h = h.wrapping_add(nm.hash());
    }
    unsafe shim::sc_closedir(dh);
    return h;
}

// The record of directory `dir`, whose `.spc` listing hashed `h` (`stamp_dir_hash`) when the loader
// listed it: its mtime, then that hash. False when the listing now differs: the directory changed
// during the build.
fn stamp_push_dir(out: &mut String, dir: str, h: u64) bool {
    let mut dp = String::from_str(dir);
    let mt = unsafe shim::sc_mtime(dp.cstr());
    if stamp_dir_hash(dir) != h {
        return false;
    }
    stamp_line(out, "dir\t", mt as u64, h, dir);
    return true;
}

// The emission options record: target, arch, CPU features, bootstrap tags, lint, the emitted C unit
// count, the root directory and the emission-mode environment switches.
fn stamp_opt_line(
    out: &mut String,
    target: i32,
    arch: i32,
    feats: cf::CpuFeatureSet,
    width: u32,
    disp: str,
    bootstrap: bool,
    lint: bool,
    ccount: u64,
    root_dir: str,
    std_dir: str,
) {
    out.push_str("opt\t");
    out.push_u64(target as u64);
    out.push_str("\t");
    out.push_u64(arch as u64 & 0xFF);
    out.format_into("\t{}.{}.{}.{}\t", feats.w[0], feats.w[1], width, disp);
    out.push_u64(bootstrap as u64);
    out.push_str("\t");
    out.push_u64(lint as u64);
    out.push_str("\t");
    out.push_u64(ccount);
    out.push_str("\t");
    out.push_str(root_dir);
    // The std tree (`SC_STD_DIR` can move it): its files are inputs recorded by path below.
    out.push_str("\t");
    out.push_str(std_dir);
    // Emission-mode switches change the emitted C, and SC_UNITY_MAX its units: a stamp written under
    // one mode must not satisfy a build under another.
    out.push_str("\t");
    for i in 0..inl::EMIT_MODE_ENV_N {
        stamp_push_env(out, inl::emit_mode_env(i));
    }
    stamp_push_env(out, "SC_UNITY_MAX");
    out.push_str("\n");
}

fn stamp_push_env(out: &mut String, name: str) {
    let v = stdlib::get_env(name);
    out.push_str(";");
    if v.is_some() {
        let vs = v.unwrap();
        out.push_string(&vs);
    }
}

// Record the inputs of a completed emission of `p` under manifest `m`, whose tree holds `ccount` `.c`
// files; `sl` was taken before the load. Written only on full success; an unreadable input or a
// directory that changed during the build aborts the write (no cache beats a wrong one).
fn stamp_write(
    path: str,
    p: &loader::Package,
    m: &mf::Manifest,
    std_dir: str,
    root_dir: str,
    target: i32,
    bootstrap: bool,
    lint: bool,
    ccount: u64,
    cid: u64,
    sl: &StampLoad,
) {
    if cid == 0 {
        return;
    }
    let mut out = String::from_str(STAMP_HEAD);
    out.push_str("\n");
    stamp_exe_line(&mut out, cid, stamp_lag(sl.t0));
    stamp_opt_line(
        &mut out,
        target,
        m.arch,
        p.features,
        p.simd_width,
        p.simd_dispatch.as_str(),
        bootstrap,
        lint,
        ccount,
        root_dir,
        std_dir,
    );
    // The manifest is loaded from the working directory (main.spc): its shard policy and flags shape
    // the emitted tree.
    if m.src_id != 0 {
        stamp_line(&mut out, "in\t", m.mtime as u64, m.src_id, "build.toml");
    }
    for i in 0..p.modules.len() {
        let md = p.modules.at(i);
        if md.file.len() != 0 {
            stamp_line(&mut out, "in\t", md.mtime as u64, md.src_id, md.file.as_str());
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
    let dc = &p.dir_cache;
    for i in 0..dc.dirs.len() {
        let mut h: u64 = 0;
        if dc.state[i] == loader::DIR_LISTED {
            let ents = dc.entries.at(i);
            for k in 0..ents.len() {
                if ents.at(k).as_str().ends_with(".spc") {
                    h = h.wrapping_add(ents.at(k).as_str().hash());
                }
            }
        }
        if !stamp_push_dir(&mut out, dc.dirs.at(i).as_str(), h) {
            return;
        }
    }
    if std_dir.len() != 0 {
        stamp_line(&mut out, "dir\t", sl.std_mt as u64, sl.std_h, std_dir);
    }
    out.push_str("end\n");
    let _ = write_file_atomic(path, out.as_str());
}

// Is the recorded emission still exact for the current inputs? On a hit `rels` holds the files of `gen`
// (`walk_gen_files`). On mtime drift with matching content the stamp is refreshed in place so the next
// check stays on the fast path.
fn stamp_fresh(
    path: str,
    root_dir: str,
    std_dir: str,
    target: i32,
    arch: i32,
    feats: cf::CpuFeatureSet,
    width: u32,
    disp: str,
    bootstrap: bool,
    lint: bool,
    gen: str,
    cid: u64,
    rels: &mut Vector<String>,
) bool {
    if cid == 0 {
        return false;
    }
    let t0 = unsafe shim::sc_ticks_ms();
    let body0 = loader::read_file(path);
    if body0.is_none() {
        return false;
    }
    let body = body0.unwrap();
    let s = body.as_str();
    // Second-granularity mtimes cannot distinguish an edit made in the same second as the read the
    // stamp vouches for: entries stamped within 2s of the stamp file's own mtime, less the record's lag,
    // verify by content instead.
    let mut spb = String::from_str(path);
    let mut recent = unsafe shim::sc_mtime(spb.cstr()) - 2;
    let mut fresh = true;
    let mut drift = false;
    let mut saw_end = false;
    let mut ccount: u64 = 0xFFFFFFFFFFFFFFFFu64;
    // The records after the `exe` line, as a refresh writes them.
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
        lno += 1;
        if lno == 1 {
            if line != STAMP_HEAD {
                return false;
            }
            continue;
        }
        let kind = stamp_field(line, 0);
        if lno == 2 {
            // The `exe` record comes first: the baseline of every mtime below.
            if kind != "exe" || stamp_u64(line, 1) != cid {
                return false;
            }
            recent -= stamp_u64(line, 2) as i64;
        } else if kind == "opt" {
            // Every field but the unit count must match this build's options.
            ccount = stamp_u64(line, 6);
            let mut want = String::new();
            stamp_opt_line(&mut want, target, arch, feats, width, disp, bootstrap, lint, ccount, root_dir, std_dir);
            if want.as_str().slice(0, want.len() - 1) != line {
                return false;
            }
            rewritten.push_string(&want);
        } else if kind == "in" {
            let mt0 = stamp_u64(line, 1) as i64;
            let fp = stamp_field(line, 3);
            let mut pp = String::from_str(fp);
            let mt = unsafe shim::sc_mtime(pp.cstr());
            if mt == 0 {
                return false;
            }
            if mt == mt0 && mt0 < recent {
                rewritten.push_str(line);
                rewritten.push_str("\n");
                continue;
            }
            let h = file_id(fp);
            if h == 0 {
                return false;
            }
            if h != stamp_u64(line, 2) {
                fresh = false;
                break;
            }
            if mt != mt0 {
                drift = true;
            }
            stamp_line(&mut rewritten, "in\t", mt as u64, h, fp);
        } else if kind == "dir" {
            let mt0 = stamp_u64(line, 1) as i64;
            let dp = stamp_field(line, 3);
            let mut dpp = String::from_str(dp);
            let mt = unsafe shim::sc_mtime(dpp.cstr());
            if mt == mt0 && mt0 < recent {
                rewritten.push_str(line);
                rewritten.push_str("\n");
                continue;
            }
            let h = stamp_dir_hash(dp);
            if h != stamp_u64(line, 2) {
                fresh = false;
                break;
            }
            if mt != mt0 {
                drift = true;
            }
            stamp_line(&mut rewritten, "dir\t", mt as u64, h, dp);
        } else if kind == "end" {
            saw_end = true;
            rewritten.push_str("end\n");
        } else {
            return false;
        }
    }
    if !fresh || !saw_end || ccount == 0 {
        return false;
    }
    walk_gen_files(gen, gen.len(), rels);
    let mut nc: u64 = 0;
    for i in 0..rels.len() {
        nc += rels.at(i).as_str().ends_with(".c") as u64;
    }
    if nc != ccount {
        return false;
    }
    if drift {
        // The refreshed mtimes were read since `t0`.
        let mut out = String::from_str(STAMP_HEAD);
        out.push_str("\n");
        stamp_exe_line(&mut out, cid, stamp_lag(t0));
        out.push_string(&rewritten);
        let _ = write_file_atomic(path, out.as_str());
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
    /// `--target-feature`: the comma list applied after the manifest's `target-features`.
    pub target_features: str<'a>,
    /// `--simd-width`: 256 or 512; 0 = the manifest's `simd-width`.
    pub simd_width: u32,
    /// `--simd-dispatch`: `off` or x86-64 levels; empty = the manifest's `simd-dispatch`.
    pub simd_dispatch: str<'a>,
}

/// The vector width the build's planner prefers on AVX-512: `--simd-width`, else `simd-width`, else 256.
pub const fn simd_width(m: &mf::Manifest, cx: &BuildCtx) u32 {
    return pick(cx.simd_width != 0, cx.simd_width, pick(m.simd_width != 0, m.simd_width, 256));
}

/// The run-time copies' levels (`loader::Package.simd_dispatch`): `--simd-dispatch`, else
/// `simd-dispatch`; empty for the default.
pub const fn simd_dispatch<'a>(m: &'a mf::Manifest, cx: &BuildCtx<'a>) str<'a> {
    return if cx.simd_dispatch.len() != 0 {
        cx.simd_dispatch;
    } else {
        m.simd_dispatch.as_str();
    };
}

/// The levels a build at profile `prof` copies for: `spec` when set; else `off` in a profile at
/// opt-level 0 or 1 (`debug`, `test`: the copies make the C compile of vector code 1.4 to 1.7 times
/// longer and add little speed there) and in a script build without a profile (no `-O` flag), the
/// default elsewhere.
pub fn dispatch_for<'a>(m: &mf::Manifest, prof: str, spec: str<'a>) str<'a> {
    let pi = m.profile_index(prof);
    let slow = prof.len() == 0 || pi >= 0 && m.profiles.at(pi as usize).opt >= 0 && m.profiles.at(pi as usize).opt <= 1;
    if spec.len() == 0 && slow {
        return "off";
    }
    return spec;
}

/// Check the `target-features` lists of `m` (the build's and every profile's: a feature of another
/// instruction set applies to another build) and the command line's list `cli` (strict) against the
/// instruction set `m.arch`; false after printing the first error.
pub fn check_features(m: &mf::Manifest, cli: str) bool {
    let mut s = cf::baseline(m.target, m.arch);
    let mut err = String::new();
    let mut ok = cf::level(m.target_cpu.as_str(), m.arch, false, &mut s, &mut err);
    for i in 0..m.target_features.len() {
        ok = ok && cf::apply(m.target_features.at(i).as_str(), m.target, m.arch, false, &mut s, &mut err);
    }
    for k in 0..m.profiles.len() {
        let tf = &m.profiles.at(k).target_features;
        for i in 0..tf.len() {
            ok = ok && cf::apply(tf.at(i).as_str(), m.target, m.arch, false, &mut s, &mut err);
        }
    }
    ok = ok && cf::apply(cli, m.target, m.arch, true, &mut s, &mut err);
    if !ok {
        eprintln("error: {}", err.as_str());
    }
    return ok;
}

/// Whether C flags `fl` enable a memory checker: an address, memory or thread sanitizer.
pub fn mem_checker(fl: str) bool {
    let mut at = fl.find("-fsanitize=");
    while at >= 0 {
        let rest = fl.slice(at as usize + 11, fl.len());
        let mut e: usize = 0;
        while e < rest.len() && rest.byte_at(e) != b' ' {
            e += 1;
        }
        let v = rest.slice(0, e);
        if v.contains("address") || v.contains("memory") || v.contains("thread") {
            return true;
        }
        let nx = rest.find("-fsanitize=");
        at = if nx < 0 {
            -1;
        } else {
            at + 11 + nx;
        };
    }
    return false;
}

/// The C compile's configuration in compile flags `fl`, as the build constants read it
/// (`Package.build_cfg`): bit 0 ThreadSanitizer, bit 1 AddressSanitizer, bit 2 lock-order tracking
/// (`-DSC_LOCKDEP`), bit 3 wrapping arithmetic (`-DSC_ARITH_WRAP`).
pub fn build_cfg(fl: str) u32 {
    let mut cfg: u32 = 0;
    let mut rest = fl;
    loop {
        let at = rest.find("-fsanitize=");
        if at < 0 {
            break;
        }
        rest = rest.slice(at as usize + 11, rest.len());
        let mut e: usize = 0;
        while e < rest.len() && rest.byte_at(e) != b' ' {
            e += 1;
        }
        let v = rest.slice(0, e);
        if v.contains("thread") {
            cfg = cfg | 1;
        }
        if v.contains("address") {
            cfg = cfg | 2;
        }
    }
    if fl.contains("-DSC_LOCKDEP") {
        cfg = cfg | 4;
    }
    if fl.contains("-DSC_ARITH_WRAP") {
        cfg = cfg | 8;
    }
    return cfg;
}

/// The CPU features of a build of `m` under profile `prof_name`: the instruction set's baseline, then
/// the build's `target-cpu` level, then the profile's `target-features` (else the build's), then the command line's list `cli`, closed
/// under `implies`. The lists passed `check_features`.
pub fn features_for(m: &mf::Manifest, prof_name: str, cli: str) cf::CpuFeatureSet {
    let mut s = cf::baseline(m.target, m.arch);
    let mut err = String::new();
    let _ = cf::level(m.target_cpu.as_str(), m.arch, false, &mut s, &mut err);
    let pi = m.profile_index(prof_name);
    let tf = if pi >= 0 && m.profiles.at(pi as usize).has_features {
        &m.profiles.at(pi as usize).target_features;
    } else {
        &m.target_features;
    };
    for i in 0..tf.len() {
        let _ = cf::apply(tf.at(i).as_str(), m.target, m.arch, false, &mut s, &mut err);
    }
    let _ = cf::apply(cli, m.target, m.arch, true, &mut s, &mut err);
    return cf::close(s);
}

// Transpile `root`'s closure into `srcgen` with this compiler's own frontend, streaming each finished
// file into `sink` when non-null. On success, when `cid` is not 0, write the emit stamp for the tree to
// `stamp` (the engine moves it into place once the tree is complete).
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
    let sl = if cid != 0 {
        stamp_load(cx.std_dir);
    } else {
        StampLoad { t0: 0, std_mt: 0, std_h: 0 };
    };
    loader::set_load_jobs(jobs);
    let tl0 = unsafe shim::sc_ticks_ms();
    // The build settings the prelude's build constants spell (`@arch` gates on the instruction
    // set too), set before the load.
    let mut p = loader::package_new(root_dir, alt, cx.std_dir);
    p.arch = m.arch;
    p.features = features_for(m, prof_name, cx.target_features);
    p.simd_width = simd_width(m, cx);
    p.simd_dispatch = String::from_str(dispatch_for(m, prof_name, simd_dispatch(m, cx)));
    let pi = m.profile_index(prof_name);
    if pi >= 0 {
        let mut fl = String::new();
        push_all(&mut fl, &m.cflags);
        push_profile_side(
            &mut fl,
            m.profiles.at(pi as usize),
            &m.profiles.at(pi as usize).cflags,
            false,
            cx.target,
            m.sdk,
        );
        p.mem_check = mem_checker(fl.as_str());
        p.build_cfg = build_cfg(fl.as_str());
    }
    p.test_build = topts != null && unsafe (*topts).enabled;
    p.profile = String::from_str(prof_name);
    p.profiles = profile_names(m);
    p.bootstrap = cx.bootstrap_tags;
    let pkg = (&mut p) as *mut loader::Package;
    let mut cirv = iri::interp_master(pkg, cx.ce_steps, cx.ce_mem);
    let cdir = object_cache_dir(project_name(m));
    if prelude_stage(&mut p, &mut cirv, cx.std_dir, root, cx.target, jobs, cx.ce_steps, cx.ce_mem, cdir.as_str()) {
        p.load_user(root, cx.std_dir, cx.target);
    }
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
    p.cir = &mut cirv;
    let rc = run_package(&mut p, topts, "", cx.target, cx.lint, "", "", sink);
    if rc == 0 && cid != 0 {
        stamp_write(stamp, &p, m, cx.std_dir, root_dir, cx.target, cx.bootstrap_tags, cx.lint, p.c_files, cid, &sl);
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
    args.push(format("--manifest-dir={}", str::from_cbuf(cwdb.as_slice())));
    args.push(format("--out-dir={}", m.out_dir.as_str()));
    args.push(format("--profile={}", prof_name));
    args.push(format("--target={}", par::axis_names(false)[cx.target as usize]));
    args.push(format("--arch={}", par::axis_names(true)[m.arch as usize]));
    if cx.target_features.len() != 0 {
        args.push(format("--target-feature={}", cx.target_features));
    }
    if simd_width(m, cx) == 512 {
        push_arg(&mut args, "--simd-width=512");
    }
    if simd_dispatch(m, cx).len() != 0 {
        args.push(format("--simd-dispatch={}", simd_dispatch(m, cx)));
    }
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

// The transpile form's sink: the tree-relative path of every file the emission rewrote, one per line.
struct RewriteLog {
    pub root_len: usize,
    pub text: String,
}

fn log_rewritten(ctx: *mut void, path: str, _text: str, _kind: i32, changed: bool) {
    if changed {
        let l = unsafe &mut *(ctx as *mut RewriteLog);
        l.text.push_str(path.slice(l.root_len + 1, path.len()));
        l.text.push_byte(b'\n');
    }
}

/// The transpile form of the command line (`super-c <root> --emit-sub=SUB ...`, run by an engine whose
/// `--transpiler` names this compiler): the transpile step of a manifest build alone. `root`'s closure
/// goes to `<out-dir>/<sub>/raw` exactly as the engine's own frontend writes it, with a nonzero `id`
/// the emit stamp for it, under that identity, to `<out-dir>/<sub>/.emit_stamp.new`, and the paths of
/// the files it rewrote to `<out-dir>/<sub>/.emit_rewritten` (the engine's `rewritten`).
pub fn manifest_emit(m: &mf::Manifest, profile: str, root: str, sub: str, cx: &BuildCtx, id: u64) i32 {
    let prof_name = resolve_profile(m, profile);
    if m.profile_index(prof_name) < 0 {
        eprintln("build: unknown profile '{}'", prof_name);
        return 1;
    }
    let pdir = loader::join2(m.out_dir.as_str(), sub);
    let srcgen = loader::join2(pdir.as_str(), "raw");
    let stamp = loader::join2(pdir.as_str(), ".emit_stamp.new");
    let mut log = RewriteLog { root_len: srcgen.len(), text: String::new() };
    let mut sink = EmitSink { ctx: (&mut log) as *mut RewriteLog, notify: log_rewritten };
    let rc = emit_closure(
        m,
        prof_name,
        root,
        loader::dirname_of(m.root.as_str()),
        "",
        srcgen.as_str(),
        build_jobs(m, cx),
        cx,
        null,
        &mut sink,
        stamp.as_str(),
        id,
    );
    if rc == 0 {
        let _ = write_file_atomic(loader::join2(pdir.as_str(), ".emit_rewritten").as_str(), log.text.as_str());
    }
    return rc;
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
    pub gen_files: Vector<String>, // when skipped, the files of <out-dir>/<sub>/raw (`walk_gen_files`)
}

/// The transpile step of an engine build, alone: the emit-stamp check (phase boundary `B_STAMP`), then,
/// unless the stamp proves the tree of <out-dir>/<sub> exact, the emission of `root`'s closure into
/// <out-dir>/<sub>/raw through `cx.transpiler` or this compiler's own frontend (boundaries `B_LOAD` to
/// `B_PUBLISH`), each finished file streamed into `sink` (null: none). The emission writes its stamp
/// record to `.emit_stamp.new`; the engine installs it once the tree is complete. The engine and the
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
    let mut gen_files = Vector::<String>::new();
    let skipped = cache_on && stamp_fresh(
        stamp_path.as_str(),
        root_dir,
        cx.std_dir,
        cx.target,
        m.arch,
        features_for(m, prof_name, cx.target_features),
        simd_width(m, cx),
        dispatch_for(m, prof_name, simd_dispatch(m, cx)),
        cx.bootstrap_tags,
        cx.lint,
        srcgen.as_str(),
        cid,
        &mut gen_files,
    );
    bst::mark(bst::B_STAMP);
    if skipped {
        return Transpiled { rc: 0, skipped: true, cid: cid, gen_files: gen_files };
    }
    // An emission that stops part way leaves raw/ partly rewritten: no stamp may vouch for it, or a
    // later build with the old inputs would skip the transpile over a mixed tree. An external
    // transpiler's record of the files it rewrites must be its own.
    let _ = unsafe shim::sc_unlink(stamp_path.cstr());
    let _ = unsafe shim::sc_unlink(stamp_new.cstr());
    if external {
        let mut rw = loader::join2(pdir.as_str(), ".emit_rewritten");
        let _ = unsafe shim::sc_unlink(rw.cstr());
    }
    let rc = if external {
        run_transpiler(m, prof_name, root, sub, cx, cid);
    } else {
        emit_closure(m, prof_name, root, root_dir, alt, srcgen.as_str(), jobs, cx, topts, sink, stamp_new.as_str(), cid);
    };
    return Transpiled { rc: rc, skipped: false, cid: cid, gen_files: Vector::<String>::new() };
}

// Whether every probe of a feature of `feats` (the build's beyond the baseline of platform `target`)
// accepted its flag (each result is marked used); prints the rejection of each that did not, naming
// the C compiler `cc`, the flag and the features it checks.
fn features_pass(probes: &mut pr::Probes, feats: cf::CpuFeatureSet, target: i32, cc: str) bool {
    let mut bad: u64 = 0;
    for i in 0..cf::FEATURE_COUNT {
        let k = pr::index_of(cf::row(i).probe);
        if !cf::has(feats, i) || k < 0 {
            continue;
        }
        probes.mark_used(k as usize);
        bad |= (probes.res.at(k as usize).as_str() == "rejected") as u64 << k as u64;
    }
    for k in 0..pr::table().len() {
        if (bad >> k as u64 & 1) == 0 {
            continue;
        }
        let mut sub = cf::CpuFeatureSet { w: [0, 0] };
        let mut names = String::new();
        for i in 0..cf::FEATURE_COUNT {
            if cf::has(feats, i) && pr::index_of(cf::row(i).probe) == k as i32 {
                sub = cf::with(sub, i);
                names.format_into("{}'{}'", pick(names.len() == 0, "", ", "), cf::row(i).name);
            }
        }
        let mut fl = String::new();
        cf::push_c_flags(sub, target, &mut fl);
        eprintln(
            "build: the C compiler '{}' rejects '{}': target feature {} needs a compiler that supports it",
            cc,
            fl.as_str().trim(),
            names.as_str(),
        );
    }
    return bad == 0;
}

/// `features_pass` for a build without a manifest: C compiler `cc` (words) with compile flags `flags`
/// and LTO mode `lto`, the probe record in `pdir`. Appends to `more` the flags the build adds
/// (`push_uvm`), and to `late` the ones that must follow the profile's `-O` flag (`push_novec`).
pub fn features_accepted(
    pdir: str,
    cc: str,
    flags: str,
    lto: i32,
    target: i32,
    arch: i32,
    all: cf::CpuFeatureSet,
    more: &mut String,
    late: &mut String,
) bool {
    let feats = cf::beyond_baseline(all, target);
    let need = feature_probes(feats) | uvm_need(target, arch) | novec_need(lto);
    if need == 0 {
        return true;
    }
    let mut ccpath = String::new();
    let ccmt = which_path(cc, &mut ccpath);
    let key = format("{}\t{}\t{}\t{}\t{}\t{}\t{}\t", LTO_SCHEMA, ccpath.as_str(), ccmt, cc, target, arch, flags);
    let mut pargv = Vector::<String>::new();
    split_args(&mut pargv, cc);
    split_args(&mut pargv, flags);
    mkdir_p(pdir);
    let mut probes = pr::Probes::start(pdir, key.as_str(), pargv, "", target, arch, need);
    let ver = cc_version(cc, pdir);
    probes.settle(&ver);
    let ok = features_pass(&mut probes, feats, target, cc);
    let _ = push_novec(&mut probes, lto, late);
    let _ = push_uvm(&mut probes, more);
    probes.save();
    return ok;
}

// The no-prelink-vectorize probe's bit for an LTO mode that can compile as full LTO (`full`, `auto`,
// and a ThinLTO request, which falls back to `auto`), else 0.
const fn novec_need(lto: i32) u64 {
    return pick(lto == mf::LTO_FULL || lto == mf::LTO_AUTO || lto == mf::LTO_THIN, 1u64 << pr::NOVEC as u64, 0);
}

// Append the compile flags that leave vectorization to the link under full LTO (`full` or `auto`) when
// the compiler accepts them (the probe result joins the command fingerprint); whether it did. The link
// vectorizes after it inlines across units, as a single unit does: a function vectorized alone in its
// unit no longer vectorizes in the loop it is inlined into. They follow the `-O` flag, which would
// enable the vectorizers again.
fn push_novec(probes: &mut pr::Probes, lto: i32, out: &mut String) bool {
    if lto != mf::LTO_FULL && lto != mf::LTO_AUTO || probes.res.at(pr::NOVEC).as_str() != "accepted" {
        return false;
    }
    probes.mark_used(pr::NOVEC);
    out.push_byte(b' ');
    out.push_str(pr::table()[pr::NOVEC].flags);
    return true;
}

// The unaligned-vector-move probe's bit where it applies (Windows x86_64), else 0: elsewhere a build
// needs no probe record for it.
const fn uvm_need(target: i32, arch: i32) u64 {
    return pick(target == 0 && arch == 0, 1u64 << pr::UVM as u64, 0);
}

// Append the unaligned-vector-move flag to `out` when its probe accepted it (the result joins the
// command fingerprint); whether it did.
fn push_uvm(probes: &mut pr::Probes, out: &mut String) bool {
    if probes.res.at(pr::UVM).as_str() != "accepted" {
        return false;
    }
    probes.mark_used(pr::UVM);
    out.push_byte(b' ');
    out.push_str(pr::table()[pr::UVM].flags);
    return true;
}

fn feature_probes(s: cf::CpuFeatureSet) u64 {
    let mut need: u64 = 0;
    for i in 0..cf::FEATURE_COUNT {
        let k = pr::index_of(cf::row(i).probe);
        if cf::has(s, i) && k >= 0 {
            need |= 1u64 << k as u64;
        }
    }
    return need;
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
// compile and link flags, and the background probes (the compiler version, and the toolchain probes of
// `need` the record does not hold), started before the transpile. `pending` is the link
// record's pending marker; `cache` the object cache namespace (empty: none).
/// Every C compile: each transcendental libm call std makes runs as written. As builtins, the C
/// compiler may fold them with the host's libm, merge `sin(x)` and `cos(x)` into one `sincos` call or
/// rewrite `pow(2, x)` to `exp2(x)`, whose bits differ with the optimization level (operations.md:
/// compile-time evaluation and the program give one value). The exact ones (`sqrt`, `fabs`, `floor`,
/// `fma`, ..) stay builtins, single instructions.
pub const LIBM_AS_WRITTEN: str<'static> = " -fno-builtin-sin -fno-builtin-cos -fno-builtin-tan -fno-builtin-asin -fno-builtin-acos -fno-builtin-atan -fno-builtin-atan2 -fno-builtin-sinh -fno-builtin-cosh -fno-builtin-tanh -fno-builtin-asinh -fno-builtin-acosh -fno-builtin-atanh -fno-builtin-exp -fno-builtin-exp2 -fno-builtin-expm1 -fno-builtin-log -fno-builtin-log2 -fno-builtin-log10 -fno-builtin-log1p -fno-builtin-pow -fno-builtin-cbrt -fno-builtin-hypot -fno-builtin-sinf -fno-builtin-cosf -fno-builtin-tanf -fno-builtin-asinf -fno-builtin-acosf -fno-builtin-atanf -fno-builtin-atan2f -fno-builtin-sinhf -fno-builtin-coshf -fno-builtin-tanhf -fno-builtin-asinhf -fno-builtin-acoshf -fno-builtin-atanhf -fno-builtin-expf -fno-builtin-exp2f -fno-builtin-expm1f -fno-builtin-logf -fno-builtin-log2f -fno-builtin-log10f -fno-builtin-log1pf -fno-builtin-powf -fno-builtin-cbrtf -fno-builtin-hypotf";

/// The base C flags of every compile of the generated tree, the build's and the test build's: the C
/// environment (`push_c_env`), then the rules fixed on every host.
pub fn push_c_base(cmd: &mut String, cstd: str, target: i32) {
    push_c_env(cmd, cstd, target);
    // gcc 14 rejects incompatible pointer arguments; clang only warns. One rule on every host.
    cmd.push_str(" -ffp-contract=off -Werror=incompatible-pointer-types");
    cmd.push_str(LIBM_AS_WRITTEN);
}

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
    let cc_raw = direct_cc(resolve_cc(m.cc.as_str(), m.sdk, m.arch), m.target, pdir.as_str());
    let mut flags = String::new();
    flags.push_byte(b' ');
    push_c_base(&mut flags, m.cstd.as_str(), m.target);
    if m.lib_shared && cx.target != 0 {
        // Shared-library objects need it; harmless for the exe targets.
        flags.push_str(" -fPIC");
    }
    // The cross triple and the CPU features' flags come first; manifest flags can override.
    let feats = features_for(m, prof.name, cx.target_features);
    push_sdk_flags(&mut flags, m.target, m.sdk, m.arch, feats);
    push_all(&mut flags, &m.cflags);
    push_profile_side(&mut flags, prof, &prof.cflags, false, cx.target, m.sdk);
    let mut tail = flags.clone();
    tail.push_str(" -MMD -c");
    // The fixed part of the link line, once: the link, the toolchain probes and their record key share it.
    let mut ldbase = String::new();
    push_sdk_flags(&mut ldbase, m.target, m.sdk, m.arch, feats);
    push_sdk_libs(&mut ldbase, m.target, m.sdk);
    if prof.strip && strips_at_link(m) {
        ldbase.push_str(" -Wl,--strip-all");
    }
    push_all(&mut ldbase, &m.ldflags);
    push_profile_side(&mut ldbase, prof, &prof.ldflags, true, cx.target, m.sdk);
    // `cc --version` costs a process round-trip: the line recorded for this compiler serves when its
    // identity is unchanged (`ccver_recorded`); else a background argv child (no shell, on
    // every platform) resolves it while the transpile runs, and ensure_cc collects it at first use.
    let mut ccpath = String::new();
    let ccmt = which_path(cc_raw.as_str(), &mut ccpath);
    // posix_spawnp makes a whole spawn attempt per PATH entry (0.4 to 0.9 ms per spawn on macOS): the
    // compiles and the link run the program found here, by its path, and argv[0] keeps the command's
    // word, so no fingerprint changes. CreateProcess searches its own directories first: Windows keeps
    // that search.
    let mut cc_file = String::new();
    if ccpath.as_str().starts_with("/") && unsafe shim::sc_host_platform() != 0 {
        cc_file.push_string(&ccpath);
    }
    let mut ccver_path = loader::join2(pdir.as_str(), ".ccver");
    let ccver0 = ccver_recorded(cc_raw.as_str());
    let mut probe_ver_pid: i64 = -1;
    if ccver0.is_none() {
        let mut va = Vector::<String>::new();
        split_args(&mut va, cc_raw.as_str());
        push_arg(&mut va, "--version");
        probe_ver_pid = spawn_at(file_of(&mut cc_file), &mut va, ccver_path.cstr());
    }
    // The toolchain probes of `need` the record does not hold start beside it. The record's key: the
    // schema, the compiler's path, mtime and command (its arguments select a target too), the target
    // and the flags; `settle` checks the version.
    let key = format(
        "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
        LTO_SCHEMA,
        ccpath.as_str(),
        ccmt,
        cc_raw.as_str(),
        cx.target,
        m.arch,
        flags.as_str(),
        ldbase.as_str(),
    );
    let mut pargv = Vector::<String>::new();
    split_args(&mut pargv, cc_raw.as_str());
    split_args(&mut pargv, flags.as_str());
    let probes = pr::Probes::start(
        pdir.as_str(),
        key.as_str(),
        pargv,
        ldbase.as_str(),
        cx.target,
        m.arch,
        need | feature_probes(cf::beyond_baseline(feats, cx.target)) | uvm_need(cx.target, m.arch) | novec_need(lto_req),
    );
    // The compile argv runs from the process working directory; record it for compile_commands.json.
    let mut cwdb = PathBuf {};
    let ccdb_dir = if unsafe shim::sc_realpath(".".ptr() as *const char, &mut cwdb[0]) != null {
        String::from_str(str::from_cbuf(cwdb.as_slice()));
    } else {
        String::from_str(".");
    };
    return CcStream {
        src_len: pdir.len() + 4, // <pdir>/raw
        gen: loader::join2(pdir.as_str(), "raw"),
        obj: loader::join2(pdir.as_str(), "obj"),
        aobj: if pdir.as_str().starts_with("/") || pdir.len() > 2 && pdir.as_str()[1] == b':' {
            loader::join2(pdir.as_str(), "obj");
        } else {
            format("{}/{}/obj", ccdb_dir.as_str(), pdir.as_str());
        },
        pdir: pdir.clone(),
        cc_raw: cc_raw,
        cc_file: cc_file,
        cc_tail: tail,
        ldbase: ldbase,
        feats: cf::beyond_baseline(feats, cx.target),
        feat_bad: false,
        target: cx.target,
        lto_req: lto_req,
        lto: lto_req,
        lto_cache: false,
        lto_reason: String::new(),
        lto_ld: Vector::<String>::new(),
        probe_ver_pid: probe_ver_pid,
        ccver_path: ccver_path,
        probes: probes,
        cc_args: Vector::<String>::new(),
        prefix_args: Vector::<String>::new(),
        ccver: ccver0.unwrap_or(String::new()),
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
        croot: cache_root(project_name(m)),
        cache: cache,
        shared: String::new(),
        cwds: Vector::<String>::new(),
        dmap: Vector::<String>::new(),
        keys: Vector::<String>::new(),
        rewritten: Set::<String>::new(),
        mtimes: Map::<String, i64>::new(),
        ccdb: Vector::<String>::new(),
        hmemo: Map::<String, u64>::new(),
        hpool: Vector::<u64>::new(),
        htext: Map::<String, String>::new(),
        ccdb_dir: ccdb_dir,
        pch: PCH_OFF,
        pch_stub: String::new(),
        pch_out: String::new(),
        pch_key: String::new(),
        pch_wait: Vector::<String>::new(),
        icc1: false,
    };
}

// Build `root`'s closure with `prof_name`'s flags into <out-dir>/<sub>/{raw,obj}, linking `bin`: the
// transpiled C lands in <out-dir>/<sub>/raw (PROFILE makes it depend on the profile), which the C
// compiler reads.
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
    let pdir = loader::join2(m.out_dir.as_str(), sub);
    let lk = tree_lock(pdir.as_str());
    if lk < 0 {
        return 1;
    }
    bst::begin();
    let rc = engine_build_i(m, prof_name, root, root_dir, alt, sub, bin, cx, link_kind, topts);
    bst::finish(rc);
    unsafe shim::sc_tree_unlock(lk);
    return rc;
}

/// The longest a build waits for another build of its tree, in milliseconds.
const TREE_LOCK_WAIT_MS: i64 = 30 * 60 * 1000;

/// Take the lock of build tree `dir` (the file `<dir>/.lock`): one process builds a tree at a time. A
/// second build would rewrite the units the first one compiles, so the first could compile a torn unit
/// and install that object in the object cache under the key of the text it hashed. Waits for a build in
/// progress at most TREE_LOCK_WAIT_MS. The handle for `sc_tree_unlock`, or -1 after a reported error.
pub fn tree_lock(dir: str) i64 {
    mkdir_p(dir);
    let mut p = loader::join2(dir, ".lock");
    let mut h = unsafe shim::sc_tree_lock(p.cstr(), 0);
    if h == -1 {
        eprintln("build: waiting for another build of '{}'", dir);
        h = unsafe shim::sc_tree_lock(p.cstr(), TREE_LOCK_WAIT_MS);
        if h == -1 {
            eprintln("build: another build held '{}' for {} minutes", dir, TREE_LOCK_WAIT_MS / 60000);
            return -1;
        }
    }
    if h < 0 {
        eprintln("build: cannot lock '{}'", p.as_str());
        return -1;
    }
    return h;
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
    let gen = loader::join2(pdir.as_str(), "raw");
    let obj = loader::join2(pdir.as_str(), "obj");
    // The content-synced copy of the tree that compilers before the emitter wrote the tree in place
    // compiled from.
    rm_rf(loader::join2(pdir.as_str(), "gen").as_str());
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
    let lenv = stdlib::get_env("SC_LTO");
    if lenv.is_some() {
        lto_req = mf::lto_parse(lenv.unwrap().as_str());
        if lto_req < 0 {
            eprintln("build: SC_LTO must be none, full, auto or thin");
            return 1;
        }
    }
    let lrec = link_record(m.out_dir.as_str(), bin);
    let mut fppath = lrec.clone();
    fppath.push_str(".cmd");
    let mut pending = fppath.clone();
    pending.push_str(".pending");
    let cache = obj_cache_ns(object_cache_dir(project_name(m)).as_str(), pdir.as_str());
    // No toolchain probe result shapes a build yet but the ThinLTO verdict (`lto_resolve`).
    let mut stream = cc_stream(m, prof, &pdir, cx, jobs, lto_req, 0, pending, cache);
    let mut sink = EmitSink { ctx: &mut stream, notify: stream_notify };
    bst::mark(bst::B_SETUP);

    // 1) transpile the closure to <out-dir>/<sub>/raw, streaming each finished TU into the pool:
    // unless the emit stamp proves every input unchanged since the last successful emission, in
    // which case the generated tree is already exact and the pipeline skips straight to cc/link.
    let mut tr = transpile_step(m, prof_name, root, root_dir, alt, sub, jobs, cx, topts, &mut sink);
    let skip_emit = tr.skipped;
    let external = cx.transpiler.len() != 0;
    let mut all_new = false;
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

        // 2) An external transpiler streams nothing: the record it left names the files it rewrote
        // (`manifest_emit`); without one, every file of its tree counts as rewritten.
        ret = stream.ret;
        if ret == 0 && external {
            switch loader::read_file(loader::join2(pdir.as_str(), ".emit_rewritten").as_str()) {
                Some(t) => {
                    for line in t.as_str().lines() {
                        stream.rewritten.insert(String::from_str(line));
                    }
                },
                None => {
                    all_new = true;
                },
            };
        }
        // The emission wrote its stamp beside the final one; only a complete tree gets it. A missing stamp
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
        // 3) The stream heard of every unit this build's own emission wrote. A tree the stamp kept or an
        // external transpiler wrote is planned off a walk of the tree. Then run the pool dry.
        if skip_emit || external {
            // The stamp check of a skipped transpile listed the tree already.
            let mut rels = replace(&mut tr.gen_files, Vector::<String>::new());
            if !skip_emit {
                walk_gen_files(gen.as_str(), gen.len(), &mut rels);
            }
            // The members of the packs compile through them, not alone. The tree gets the precompiled
            // header as its emission recorded it.
            let mut included = Set::<String>::new();
            unity_members(gen.as_str(), &mut included);
            if tree_pch(gen.as_str()) {
                stream.start_pch("");
            }
            for i in 0..rels.len() {
                if all_new {
                    stream.rewritten.insert(rels.at(i).clone());
                }
                let rel = rels.at(i).as_str();
                if rel.ends_with(".c") && !included.contains(rels.at(i)) {
                    stream.plan_c(rel, "");
                }
            }
        }
        stream.drain(false);
        // A build with zero .c files never planned one; the link still needs cc.
        stream.ensure_cc();
        // compile_commands.json: one row per translation unit, argv exactly as compiled, written
        // atomically so tooling never reads a torn file, and only when its text changes: a rewrite
        // would make C tooling reload it. Rows sort by their text (a constant directory then the file
        // path): plan order follows the emit stream's notification arrival, which the parallel emit
        // workers may vary.
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
            if !file_eq(dbp.as_str(), db.as_str()) && !write_file_atomic(dbp.as_str(), db.as_str()) {
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
            let mut lfile = String::new();
            let first: usize; // the index of the first object
            if link_kind == 1 {
                // A static library is an archive: no link flags, no libs.
                largs.push(archiver(stream.cc_raw.as_str(), m.target));
                push_arg(&mut largs, "rcs");
                largs.push(tmp.clone());
                first = largs.len();
                for i in 0..objs.len() {
                    largs.push(objs.at(i).clone());
                }
            } else {
                lfile.push_string(&stream.cc_file);
                largs = cc_link;
                if link_kind == 2 {
                    push_arg(&mut largs, "-shared");
                    if cx.target != 0 {
                        push_arg(&mut largs, "-fPIC");
                    }
                }
                push_arg(&mut largs, "-o");
                largs.push(tmp.clone());
                first = largs.len();
                for i in 0..objs.len() {
                    largs.push(objs.at(i).clone());
                }
                // Flag STRINGS keep the historic whitespace-splitting contract; only the paths the
                // engine controls (above, and the linker cache directory) are single verbatim arguments.
                split_args(&mut largs, stream.ldbase.as_str());
                for i in 0..stream.lto_ld.len() {
                    largs.push(stream.lto_ld.at(i).clone());
                }
                // @link flags recorded by the emitter.
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
            // An object's time is its `.cmd` record's (see `obj_stale`): another tree's use of a
            // shared cache entry refreshes the object's own mtime.
            for i in 0..objs.len() {
                if !need {
                    let o = objs.at(i).as_str();
                    let mut cp = String::from_str(o.slice(0, o.len() - 2));
                    cp.push_str(".cmd");
                    need = unsafe shim::sc_mtime(cp.cstr()) > bmt;
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
                let mut rsp = lrec.clone();
                rsp.push_str(".rsp");
                let fit = fit_cmdline(&mut largs, first, objs.len(), rsp.as_str(), cmdline_max());
                let lrc = if fit < 0 {
                    -1;
                } else {
                    exec_at(file_of(&mut lfile), &mut largs, null);
                };
                if fit > 0 {
                    let _ = unsafe shim::sc_unlink(rsp.cstr());
                }
                if lrc != 0 {
                    eprintln("build: link failed (exit {}): {}", lrc, lrendered.as_str());
                    ret = 1;
                } else if prof.strip && link_kind == 0 && !strips_at_link(m) {
                    // The temp is stripped, so no unstripped binary is ever installed, and a failed
                    // strip leaves the previous binary and its record: the next build links again.
                    let mut st = Vector::<String>::new();
                    push_arg(&mut st, "strip");
                    st.push(tmp.clone());
                    let src = exec_args(&mut st, null);
                    if src != 0 {
                        eprintln("build: strip failed (exit {}): '{}'", src, tmp.as_str());
                        ret = 1;
                    }
                }
                if ret == 0 {
                    if unsafe shim::sc_rename(tmp.cstr(), binb.cstr()) != 0 {
                        eprintln("build: cannot move '{}' into place", bin);
                        ret = 1;
                    } else if write_file_atomic(fppath.as_str(), fp.as_str()) {
                        // The pending marker goes only once the link record holds this link: without
                        // the record, a same-second object could leave the next build on this binary.
                        let _ = unsafe shim::sc_unlink(stream.pending.cstr());
                    } else {
                        eprintln("build: cannot write '{}'; the next build relinks", fppath.as_str());
                    }
                }
            }
            t_link = unsafe shim::sc_ticks_ms();
        }
        // Retention runs only after a successful build: a failed one may leave its objects unnamed.
        if ret == 0 {
            let now = time::now();
            if stream.cache.len() != 0 {
                obj_cache_commit(stream.cache.as_str(), &mut stream.keys, pdir.as_str(), now);
            }
            sweep(m, now, false);
        }
    } else {
        // A failed emission or compile: reap the compiles still in flight and the probes.
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

// Whether a stripped build strips at link (`-Wl,--strip-all`): every linker but Apple's can, which
// saves the `strip` process and a rewrite of the binary; the host `strip` cannot read the Android and
// wasm linkers' (lld) output either. A macOS or iOS binary runs `strip`: ld64 has no full strip.
const fn strips_at_link(m: &mf::Manifest) bool {
    return m.target != 1 && m.target != 4;
}

// The path `cstr` of `s` for a spawn's program; null for an empty `s` (the spawn searches PATH).
fn file_of(s: &mut String) *const char {
    if s.len() == 0 {
        return null;
    }
    return s.cstr();
}

/// The link record of binary path `bin` in out-dir `out_dir`, without its `.cmd` extension (also the
/// stem of its `.pending` marker and response file). Per binary and profile-agnostic (out-dir root),
/// since profiles share bin paths and a debug binary left behind by a release link must read as out of
/// date. The name is a hash of the path: it fits NAME_MAX for any path, and two paths do not share it.
pub fn link_record(out_dir: str, bin: str) String {
    let mut h1 = FNV_BASIS;
    let mut h2: u64 = 0x9e3779b97f4a7c15;
    ch_mix_bytes(&mut h1, &mut h2, bin.ptr(), bin.len());
    let mut name = String::from_str("__link-");
    hex64(h1, &mut name);
    hex64(h2, &mut name);
    return loader::join2(out_dir, name.as_str());
}

/// The archiver of the static libraries compiler command `cc` builds for `target`: the host `ar` for
/// the host's object format, else the one beside the cross compiler, which reads the target's objects
/// and indexes their symbols (Apple `ar` writes no index for wasm objects): `llvm-ar` in a clang's
/// directory (the wasi-sdk's and the NDK's), `<triple>-ar` for a `<triple>-gcc`, else `ar`.
pub fn archiver(cc: str, target: i32) String {
    let host = unsafe shim::sc_host_platform();
    let mut e: usize = 0;
    while e < cc.len() && cc[e] != b' ' {
        e += 1;
    }
    let prog = cc.slice(0, e);
    let mut b = prog.len();
    while b > 0 && prog[b - 1] != b'/' && prog[b - 1] != b'\\' {
        b -= 1;
    }
    let name = prog.slice(b, prog.len());
    let g = name.find("-gcc");
    if target == host || host == 1 && target == 4 || !name.contains("clang") && g < 0 {
        return String::from_str("ar");
    }
    let mut out = String::from_str(prog.slice(0, b));
    if name.contains("clang") {
        out.push_str("llvm-ar");
    } else {
        out.push_str(name.slice(0, g as usize + 1));
        out.push_str("ar");
    }
    return out;
}

// CreateProcess takes a command line of at most 32,767 characters, and the gcc driver's collect2 and
// ld lines add its own paths to the line it got: a longer link or archive line than this passes its
// objects through a response file. Other hosts take about a megabyte of arguments.
const WIN_CMDLINE_MAX: usize = 8192;

/// The longest command line `fit_cmdline` leaves as it is on this host.
pub const fn cmdline_max() usize {
    if unsafe shim::sc_host_platform() == 0 {
        return WIN_CMDLINE_MAX;
    }
    return usize::MAX;
}

/// Fit command `args` into a command line of `limit` characters (each argument counted with two quotes
/// and a separator): a longer one moves its arguments `first..first + n` (the objects) into response
/// file `rsp` and names it in their place as `@rsp`, which gcc, ld, ar and llvm-ar read. Each path is
/// a double-quoted line with `/` for `\`, which the GNU and the Windows response-file parsers read
/// alike (Windows paths hold no `"`). 0: `args` unchanged; 1: `rsp` written; -1: it cannot be written.
pub fn fit_cmdline(args: &mut Vector<String>, first: usize, n: usize, rsp: str, limit: usize) i32 {
    let mut len: usize = 0;
    for i in 0..args.len() {
        len += args.at(i).len() + 3;
    }
    if len <= limit {
        return 0;
    }
    let mut body = String::new();
    for i in first..first + n {
        let a = args.at(i).as_str();
        body.push_byte(b'"');
        for k in 0..a.len() {
            body.push_byte(pick(a[k] == b'\\', b'/', a[k]));
        }
        body.push_str("\"\n");
    }
    if !write_file(rsp, body.as_str()) {
        eprintln("build: cannot write '{}'", rsp);
        return -1;
    }
    let mut out = Vector::<String>::with_capacity(args.len() - n + 1);
    for i in 0..args.len() {
        if i == first {
            out.push(format("@{}", rsp));
        }
        if i < first || i >= first + n {
            out.push(replace(&mut args[i], String::new()));
        }
    }
    *args = out;
    return 1;
}

/// `super-c build` from build.toml: run the engine on the manifest's root under the resolved profile
/// (see `resolve_profile`), linking `bin_override` when non-empty, else the manifest's `bin`. With
/// `bin_override`, `sel_bin` (`--bin=NAME`) names the target linked there: a [bin.NAME] or the root.
pub fn manifest_build(m: &mf::Manifest, profile: str, bin_override: str, sel_bin: str, cx: &BuildCtx) i32 {
    let prof_name = resolve_profile(m, profile);
    if bin_override.len() != 0 {
        // `-o` names an exact path: link straight there, no profile copy and nothing installed.
        let ob = exe_name(bin_override, cx.target);
        if sel_bin.len() == 0 || sel_bin == m.bin.as_str() {
            return root_build(m, prof_name, ob.as_str(), cx);
        }
        for i in 0..m.bins.len() {
            let bt = m.bins.at(i);
            if bt.name.as_str() == sel_bin {
                let mut sub = String::from_str(prof_name);
                sub.push_str("-bin-");
                sub.push_string(&bt.name);
                let dir = loader::dirname_of(m.root.as_str());
                return engine_build(m, prof_name, bt.root.as_str(), dir, "", sub.as_str(), ob.as_str(), cx, 0, null);
            }
        }
        eprintln("build: no target named '{}' (check `bin` and [bin.NAME] sections)", sel_bin);
        return 1;
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
// raw/obj caches: different closures must not thrash one another's trees). `out` receives the artifact.
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
        // The first pass lints the closure: the static one when the library has it, else the shared one.
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
                if shared && m.lib_static {
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
        let rc = manifest_build(m, profile, "", "", cx);
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
// is what keeps a `test` run from quietly leaving a debug binary where a release one was.
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
    // the suite would replace whatever the manifest's binary currently is (a release artifact, say). With
    // no `--profile`, the binary takes the `test` profile (no sanitizers), in a tree of its own beside the
    // runner's <out-dir>/test.
    let mut binp = String::new();
    let rc = if profile.len() == 0 {
        let leaf = exe_name(loader::basename_of(m.bin.as_str()), cx.target);
        target_build(m, "test", m.root.as_str(), "-bin", leaf.as_str(), 0, &nolint, &mut binp);
    } else {
        build_into_profile(m, profile, &nolint, &mut binp);
    };
    if rc != 0 {
        return rc;
    }
    let mut src = String::new();
    if suite_import_root(tdir.as_str(), "test", &mut src) == 0 {
        eprintln("test: no .spc files under {}/", tdir.as_str());
        return 1;
    }
    mkdir_p(m.out_dir.as_str());
    // A filter is part of the generated root: it imports only the files with a matching test, so the
    // others are not built. Finding them takes a parse of the whole suite.
    let filter = if unsafe (*topts).filter != null {
        unsafe str::from_cstr((*topts).filter);
    } else {
        "";
    };
    if filter.len() != 0 {
        let scanp = loader::join2(m.out_dir.as_str(), "test_scan.spc");
        if !write_file(scanp.as_str(), src.as_str()) {
            eprintln("test: cannot write '{}'", scanp.as_str());
            return 1;
        }
        let p = suite_scan(scanp.as_str(), loader::dirname_of(m.root.as_str()), cx, m.arch);
        if !p.ok {
            return 1;
        }
        let mut tpref = String::new();
        push_module_path(&mut tpref, tdir.as_str());
        tpref.push_str("::");
        src.clear();
        src.push_str("// generated by `super-c test` -- do not edit\n");
        if test_filter_imports(&p, tpref.as_str(), filter, &mut src) == 0 {
            eprintln("test: no test name contains '{}'", filter);
            return 1;
        }
    }
    src.push_str("\nfn main() i32 {\n    return 0;\n}\n");
    let rootp = loader::join2(m.out_dir.as_str(), "test_root.spc");
    // Rewrite the root only when its content changed: an unchanged root keeps its mtime, so the emit
    // stamp proves the suite unchanged without hashing every input.
    if !file_eq(rootp.as_str(), src.as_str()) {
        if !write_file(rootp.as_str(), src.as_str()) {
            eprintln("test: cannot write '{}'", rootp.as_str());
            return 1;
        }
    }
    // The harness compiles+runs snippets through the binary built above ("./" so it never
    // resolves through PATH when the bin name is bare), unless SC_TEST_SUPERC names a different
    // compiler under test (the wasm lane's wasmtime wrapper), which then takes its place.
    let mut binb = String::new();
    let ov = stdlib::get_env("SC_TEST_SUPERC").unwrap_or(String::new());
    if ov.len() != 0 {
        binb.push_string(&ov);
    } else {
        if binp.as_str().find_byte(b'/') < 0 {
            binb.push_str("./");
        }
        binb.push_string(&binp);
    }
    unsafe shim::sc_setenv("SUPERC".ptr() as *const char, binb.cstr());
    // That compiler looks for std/ beside its binary, which `--out-dir` may place outside the project:
    // a project that holds a std tree names it (`SC_STD_DIR`, read by main.spc's `exe_std_dir`).
    if real_path("std/core.spc").len() != 0 && stdlib::get_env("SC_STD_DIR").is_none() {
        let mut sd = real_path("std");
        unsafe shim::sc_setenv("SC_STD_DIR".ptr() as *const char, sd.cstr());
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
    // The suite's recorded durations balance the shards: `--test-durations`, else
    // `<test dir>/durations.tsv` (written by --test-record-durations).
    let mut durp = loader::join2(tdir.as_str(), "durations.tsv");
    let mut o = unsafe *topts;
    if o.durations == null {
        o.durations = durp.cstr();
    }
    // Every compiler a test runs shares one cache base, so a unit an earlier build compiled is not
    // compiled again: `SC_TEST_CACHE_DIR`, kept across runs (CI saves it), else `<out-dir>/test/cache`,
    // which the run deletes at its end, and at its start what an interrupted run left. Absolute: tests
    // change directory.
    let kept = stdlib::get_env("SC_TEST_CACHE_DIR").unwrap_or(String::new());
    let tcache = if kept.len() != 0 {
        kept.clone();
    } else {
        loader::join2(tdir_out.as_str(), "cache");
    };
    if kept.len() == 0 {
        rm_rf(tcache.as_str());
    }
    mkdir_p(tcache.as_str());
    let mut ac = real_path(tcache.as_str());
    unsafe shim::sc_setenv("SC_CACHE_DIR".ptr() as *const char, ac.cstr());
    let trc = test_run_runner(&o, tbin.as_str());
    if kept.len() == 0 {
        rm_rf(tcache.as_str());
    }
    return trc;
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

// Load the import-only root `rootp` and drop the items `target` and `arch` gate out. A suite scan needs no
// more (an attribute is recorded by the parser), so nothing here resolves or typechecks. `ok` is false
// when a module does not parse.
fn suite_scan(rootp: str, src_dir: str, cx: &BuildCtx, arch: i32) loader::Package {
    // The instruction set gates imports while loading, so it is set before the load.
    let mut p = loader::package_new(".", src_dir, cx.std_dir);
    p.arch = arch;
    p.load_root(rootp, cx.std_dir, cx.bootstrap_tags, cx.target);
    if p.ok {
        p.platform_filter(cx.target);
    }
    return p;
}

// `import` lines for the modules of `p` under the test directory (paths starting with `prefix`) that hold
// a `@test` whose runner name contains `filter`. Returns how many. The runner still selects by `filter`
// among the tests of these modules.
fn test_filter_imports(p: &loader::Package, prefix: str, filter: str, out: &mut String) usize {
    let mut n: usize = 0;
    for m in 0..p.modules.len() {
        let path = p.modules[m].path.as_str();
        if !p.modules[m].has_ast || p.modules[m].prelude || !path.starts_with(prefix) {
            continue;
        }
        let src = p.modules[m].source.as_str();
        let a = p.module_ast_const(m as ModuleId);
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        let mut hit = false;
        for i in 0..items.len {
            let id = unsafe (*a).list(items)[i as usize];
            let item = unsafe (*a).at_const(id);
            if item.kind == NodeKind::NODE_FUNCTION {
                hit = hit || test_name_has(a, src, id, path, "", filter);
            } else if item.kind == NodeKind::NODE_EXTEND {
                // A suite test's runner name holds its type's declared name: the last segment of the target.
                let ts = unsafe (*a).at_const(item.as_data.extend_def.target_type).span;
                let mut cut = ts.start as usize;
                for k in cut + 1..ts.end as usize {
                    if src[k - 1] == b':' && src[k] == b':' {
                        cut = k + 1;
                    }
                }
                let ty = src.slice(cut, ts.end as usize);
                let ed = item.as_data.extend_def;
                for j in 0..ed.items.len {
                    hit = hit || test_name_has(a, src, unsafe (*a).list(ed.items)[j as usize], path, ty, filter);
                }
            }
        }
        if hit {
            out.push_str("import ");
            out.push_str(path);
            out.push_str(";\n");
            n += 1;
        }
    }
    return n;
}

// Whether `id` is a `@test` function whose runner name contains `filter`: `<path>::<fn>`, or
// `<path>::<ty>::<fn>` for a method of extend type `ty` that takes the suite fixture. Which parameter is
// the fixture takes types to know, so a method with parameters matches by either name.
fn test_name_has(a: *const Ast, src: str, id: NodeId, path: str, ty: str, filter: str) bool {
    let f = unsafe (*a).at_const(id);
    if f.kind != NodeKind::NODE_FUNCTION || unsafe (*a).attr_of(id, AttrKind::ATTR_TEST) == null {
        return false;
    }
    let nm = unsafe (*a).at_const(f.as_data.function.name).as_data.name.text;
    let fname = src.slice(nm.start as usize, nm.end as usize);
    let mut name = String::from_str(path);
    name.push_str("::");
    name.push_str(fname);
    if name.as_str().contains(filter) {
        return true;
    }
    if ty.len() == 0 || f.as_data.function.params.len == 0 {
        return false;
    }
    name.truncate(path.len() + 2);
    name.push_str(ty);
    name.push_str("::");
    name.push_str(fname);
    return name.as_str().contains(filter);
}

// Collect every `@bench` function of the scanned package `p` as "<module path>::<name>".
fn bench_collect(p: &loader::Package, prefix: str, out: &mut Vector<String>) bool {
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
        // The live top-level items: `platform_filter` dropped the gated-out ones, and the parser rejects
        // `@bench` anywhere but on a top-level function.
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            let id = unsafe (*a).list(items)[i as usize];
            let at = unsafe (*a).attr_of(id, AttrKind::ATTR_BENCH);
            let fnode = unsafe (*a).at_const(id);
            if at == null || fnode.kind != NodeKind::NODE_FUNCTION {
                // A `@bench` on anything else is the parser's error.
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
            if unsafe (*at).arg != 0 {
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
// benchmark genuinely needs arrives through that benchmark's own imports. `found` holds only the selected
// benchmarks, so a filtered run builds only their modules.
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

    // The library owns the run (`bench::Run`): the selection, one fresh process per benchmark, the pools'
    // shutdown and the exit code. The root calls each benchmark directly, never through a fn value.
    out.push_str("import std::testing::bench as __bench;\n\nfn main(argv: Vector<str>) i32 {\n    __bench::begin(\"");
    out.push_str(build_id);
    out.push_str("\", \"");
    out.push_str(flags);
    out.push_str("\");\n    let mut __run = __bench::Run::new(&argv);\n");
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
        out.push_str("    if __run.wants(\"");
        out.push_str(name);
        out.push_str("\") {\n        let mut __b = __bench::Bencher::new(\"");
        out.push_str(name);
        out.push_str("\");\n        ");
        out.push_str(full);
        out.push_str("(&mut __b);\n        let __code = __run.done(&mut __b, ");
        out.push_str(
            if quiet {
                "true";
            } else {
                "false";
            },
        );
        out.push_str(");\n        if __code >= 0 {\n            return __code;\n        }\n    }\n");
    }
    out.push_str("    return __run.end();\n}\n");
}

/// `super-c bench`: discover `@bench` functions under <bench-dir> (default bench/), build a runner
/// for them under the bench profile (by default) into <out-dir>/bench-bin and run it (skipped when
/// `no_run`). A non-empty `filter` builds and runs only the benchmarks whose name contains it.
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
    let p = suite_scan(scanp.as_str(), loader::dirname_of(m.root.as_str()), cx, m.arch);
    let mut found = Vector::<String>::new();
    if !p.ok || !bench_collect(&p, bpref.as_str(), &mut found) {
        return 1;
    }
    if found.len() == 0 {
        eprintln("bench: no '@bench' functions under {}/", bdir.as_str());
        return 1;
    }
    // The selection is part of the generated root, so only the selected benchmarks' modules are built. The
    // name matched is the one the runner reports: "<module path>::<name>" without the "<bench-dir>::".
    if filter.len() != 0 {
        let mut kept = Vector::<String>::new();
        for i in 0..found.len() {
            let e = found.at(i).as_str();
            let quiet = if e[0] == b'-' {
                1 as usize;
            } else {
                0 as usize;
            };
            if e.slice(quiet + bpref.len(), e.len()).contains(filter) {
                kept.push(String::from_str(e));
            }
        }
        if kept.len() == 0 {
            eprintln("bench: no benchmark name contains '{}'", filter);
            return 1;
        }
        found = kept;
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
        let rc = manifest_build(m, profile, "", "", cx);
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

/// `super-c clean`: the sweeps every build runs at most once per SWEEP_EVERY, now, deleting every unused
/// object (`sweep`). `full` (`--full`): remove the out-dir, every emitted tree below the root directory
/// (`root_trees`) and the project's cache root instead.
pub fn manifest_clean(m: &mf::Manifest, full: bool) i32 {
    if !full {
        sweep(m, time::now(), true);
        return 0;
    }
    rm_rf(m.out_dir.as_str());
    let trees = root_trees(m);
    for i in 0..trees.len() {
        rm_root_tree(trees.at(i).as_str());
    }
    let croot = cache_root(project_name(m));
    if croot.len() != 0 {
        rm_rf(croot.as_str());
        println("removed {}", croot.as_str());
    }
    return 0;
}
