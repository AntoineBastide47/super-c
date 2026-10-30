// build.toml engine: compile the root's module closure into native objects under
// <out-dir>/<profile>/raw (the emitter writes only the files whose content changed, so an unchanged file
// keeps its mtime) and link them with the own linker (`link::link`); `--emit-c` writes the program's C
// tree there instead. `super-c command <name>` and `super-c clean` live here too.
//
// Process discipline: every transpiler and git invocation is an argv child (process::spawn, no shell), so
// paths pass through verbatim: spaces, quotes, non-ASCII. The ONE shell survivor is `super-c command`,
// whose manifest lines are sh/cmd syntax by user contract. Flag STRINGS keep their historic
// whitespace-splitting. The link record and the emit stamp write through temp + atomic rename.
import stdio;
import stdlib;
import target::table as tgt;
import time;
import driver_shim as shim;
import std::platform::cpu;
import std::platform::env;
import std::platform::fs;
import std::platform::process;
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
import ast::ast as ast;
import ast::parser as par;
import ir::cpu_features as cf;
import lsp::json as json;
import link::link as lk;
import link::util as lu;
import build_system::ext as ext;

// A failed child's captured output is replayed up to this many bytes; the file keeps the rest.
const LOG_LIMIT: usize = 65536;

// Recursively collect regular files under dir as paths relative to `base` (no leading '/').
fn walk_files(dir: str, base_len: usize, out: &mut Vector<String>) {
    let names = list_dir(dir, false).unwrap_or(Vector::<String>::new());
    for i in 0..names.len() {
        let p = loader::join2(dir, names.at(i).as_str());
        if is_dir(&p) {
            walk_files(&p, base_len, out);
        } else {
            let full = p.as_str();
            out.push(String::from_str(full.slice(base_len + 1, full.len())));
        }
    }
}

// `walk_files` over a generated tree: a `.c`, `.h` or `.o` name there is a file, so only other names
// cost a stat (the tree holds one definition header per type).
fn walk_gen_files(dir: str, base_len: usize, out: &mut Vector<String>) {
    let names = list_dir(dir, false).unwrap_or(Vector::<String>::new());
    for i in 0..names.len() {
        let nm = names.at(i).as_str();
        let p = loader::join2(dir, nm);
        if !nm.ends_with(".c") && !nm.ends_with(".h") && !nm.ends_with(".o") && is_dir(&p) {
            walk_gen_files(&p, base_len, out);
        } else {
            let full = p.as_str();
            out.push(String::from_str(full.slice(base_len + 1, full.len())));
        }
    }
}

const fn contains(v: &Vector<String>, s: str) bool {
    for i in 0..v.len() {
        if v.at(i).as_str() == s {
            return true;
        }
    }
    return false;
}

/// Recursive delete (files then directories); silently ignores a missing path. Never follows a link:
/// a POSIX symlink is unlinked and a Windows directory link or junction is removed without descending.
pub(package) fn rm_rf(path: str) {
    // A read-only file (a vendored repository's git objects) goes too: Windows refuses to unlink one,
    // and `fs::remove_all` makes it writable first.
    let _ = fs::remove_all(path);
}

// The build cache: ~/.super-c/cache (`objcache::cache_base`), one root per project, which holds the
// checked std prelude's images (`driver::prelude_image`).
//
// Retention: a sweep every 30 minutes (`sweep`, which `super-c clean` runs at once) removes the stale
// prelude images (`sweep_cache`) and the project's idle build trees (`sweep_project`).

/// A build tree, link record or binary is removed after this many seconds with no entry changed (a build
/// refreshes its tree at most daily).
const TREE_IDLE: i64 = 30 * 86400;
/// The sweeps (`sweep`) run at most once per this many seconds.
const SWEEP_EVERY: i64 = 30 * 60;

/// The newest mtime of `dir` and its entries (0 when `dir` is missing).
fn newest_mtime(dir: str) i64 {
    let mut best = file_mtime(dir);
    let names = list_dir(dir, false).unwrap_or(Vector::<String>::new());
    for i in 0..names.len() {
        let p = loader::join2(dir, names.at(i).as_str());
        let mt = file_mtime(&p);
        if mt > best {
            best = mt;
        }
    }
    return best;
}

/// The sweeps after every successful build of project `m` (null for a script build) and by `super-c
/// clean` (`clean`): the cache sweep (`sweep_cache`) at most once per SWEEP_EVERY (the stamp
/// `<root>/.sweep`), and the project sweep (`sweep_project`) as often (`<out-dir>/.sweep`). `clean`
/// runs both now.
pub(package) fn sweep(m: *const mf::Manifest, now: i64, clean: bool) {
    let croot = if m != null {
        cache_root(project_name(unsafe &*m))
    } else {
        cache_root("")
    };
    if croot.len() != 0 && (clean || sweep_due(&croot, now)) {
        sweep_cache(&croot, now);
    }
    if m != null && (clean || sweep_due(unsafe (*m).out_dir.as_str(), now)) {
        sweep_project(unsafe &*m, now);
    }
}

// Whether the sweep whose stamp is `<dir>/.sweep` is due (no stamp, or one older than SWEEP_EVERY); a
// due sweep restamps first, and one whose stamp cannot be written does not run: every build would sweep.
fn sweep_due(dir: str, now: i64) bool {
    let stamp = loader::join2(dir, ".sweep");
    let last = file_mtime(&stamp);
    if last != 0 && now - last < SWEEP_EVERY {
        return false;
    }
    mkdir_p(dir);
    let mut body = String::new();
    body.push_i64(now);
    return write_file_atomic(&stamp, &body);
}

/// The cache root's directory name of project `m`: its `bin`, else its `[lib]` name.
pub(package) const fn project_name<'a>(m: &'a mf::Manifest) str<'a> {
    if m.bin.len() != 0 {
        return m.bin.as_str();
    }
    return m.lib_name.as_str();
}

/// Delete what no build reads again below cache root `root` (`cache_root`): the stale prelude images
/// (`prelude_image::sweep`).
fn sweep_cache(root: str, now: i64) {
    pimg::sweep(root, now);
}

/// Delete what no build of manifest `m` reads again: every entry of its out-dir with nothing written
/// for TREE_IDLE (a build tree, a link record, a binary), except a tree whose lock a build holds, and the
/// emitted trees below its root directory (`root_trees`) idle as long.
pub(package) fn sweep_project(m: &mf::Manifest, now: i64) {
    let out = m.out_dir.as_str();
    let names = list_dir(out, false).unwrap_or(Vector::<String>::new());
    for i in 0..names.len() {
        let p = loader::join2(out, names.at(i).as_str());
        if names.at(i).as_str() != ".sweep" && now - newest_mtime(&p) >= TREE_IDLE {
            rm_unlocked(&p);
        }
    }
    let trees = root_trees(m);
    for i in 0..trees.len() {
        let raw = loader::join2(trees.at(i).as_str(), "raw");
        if now - newest_mtime(&raw) >= TREE_IDLE {
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
    let mut busy = false;
    {
        let mut held = Vector::<Lock>::new();
        for i in 0..locks.len() {
            let lp = locks.at(i).as_str();
            if !busy && file_mtime(lp) != 0 {
                let h = lock_file(lp, 0);
                busy = !h.held();
                held.push(h);
            }
        }
        if !busy {
            rm_rf(p);
        }
    }
    if !busy {
        rm_rf(p);
    }
}

// The emitted trees below the root directory of manifest `m` (`<root dir>/build/<profile>`, of bare
// and script builds): only a directory whose `raw` holds the emission's manifest, so a user directory
// named `build` is never one. Their emission rewrites `raw/__sc_manifest` every time, which keeps the
// idle age of a tree in use low. None when that directory is the manifest's out-dir (`root = "main.spc"`
// with the default `out-dir`): its trees are the engine's, swept with their locks as out-dir entries.
fn root_trees(m: &mf::Manifest) Vector<String> {
    let mut out = Vector::<String>::new();
    let b = loader::join2(loader::dirname_of(&m.root), "build");
    let rb = real_path(&b);
    if rb.len() != 0 && rb.as_str() == real_path(&m.out_dir).as_str() {
        return out;
    }
    let names = list_dir(&b, false).unwrap_or(Vector::<String>::new());
    for i in 0..names.len() {
        let pd = loader::join2(&b, names.at(i).as_str());
        let rt = loader::join2(&pd, "raw/__sc_manifest");
        if file_mtime(&rt) != 0 {
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
    let lp = loader::join2(pd, ".lock");
    {
        let h = lock_file(&lp, 0);
        if !h.held() {
            return;
        }
        rm_rf(loader::join2(pd, "raw").as_str());
        rm_rf(loader::join2(pd, "obj").as_str());
        let _ = fs::unlink(&lp);
    }
    let _ = fs::unlink(&lp);
    let _ = fs::rmdir(pd);
    let _ = fs::rmdir(loader::dirname_of(pd));
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

/// The names of `m`'s profiles: the ones a PROFILE comparison may name.
pub(package) fn profile_names(m: &mf::Manifest) Vector<String> {
    let mut out = Vector::<String>::new();
    for i in 0..m.profiles.len() {
        out.push(String::from_str(m.profiles.at(i).name));
    }
    return out;
}

/// Package `p`'s settings under profile `name` of `m` (none for an unknown name): its `opt-level`, its
/// debug information, and in `Package.build_cfg` its lock-order checks (the LOCKDEP bit) and whether
/// integer overflow wraps (the OVERFLOW_CHECKS bit).
pub(package) const fn apply_profile(m: &mf::Manifest, name: str, p: &mut loader::Package) {
    let pi = m.profile_index(name);
    if pi < 0 {
        return;
    }
    let prof = m.profiles.at(pi as usize);
    p.opt = prof.opt;
    p.debug_info = prof.debug;
    p.cg_on = prof.cg_on;
    p.cg_off = prof.cg_off;
    p.build_cfg = pick(prof.arith_wraps(), 1u32 << (ast::BC_OVERFLOW_CHECKS - ast::BC_LOCKDEP) as u32, 0u32) | pick(
        prof.lockdep,
        1u32,
        0u32,
    );
}

/// The command line's `-O<level>` (`opt`; OPT_NONE: none) and `-f` flags (`on`, `off`) over a build
/// without a profile, as a profile with them sets it (`apply_profile`).
pub(package) fn apply_flags(opt: i32, on: u64, off: u64, p: &mut loader::Package) {
    if opt != mf::OPT_NONE {
        let wrap = 1u32 << (ast::BC_OVERFLOW_CHECKS - ast::BC_LOCKDEP) as u32;
        p.opt = opt;
        p.build_cfg = p.build_cfg & ~wrap | pick(mf::wraps(-1, opt), wrap, 0u32);
    }
    p.cg_on = on;
    p.cg_off = off;
}

/// Whether built-in profile `name` strips the binaries it links (a build without a manifest).
pub(package) fn profile_strip(name: str) bool {
    let m = mf::builtins_only();
    let pi = m.profile_index(name);
    return pi >= 0 && m.profiles.at(pi as usize).strip;
}

// Field `idx` of `s` split at byte `sep`; the last field runs to the end, and a missing one is empty.
const fn field_of(s: str, sep: u8, idx: usize) str {
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

extend Lock {
    pub(package) const fn held(self: &Lock) bool {
        return switch self {
            Held(_) => true,
            _ => false,
        };
    }
    pub(package) const fn busy(self: &Lock) bool {
        return switch self {
            Busy => true,
            _ => false,
        };
    }
}

/// Platform artifact name for a library target: static -> lib<name>.a everywhere (mingw uses ar
/// archives too); shared -> the target's shared-library prefix and suffix around the name.
pub(package) fn lib_file(name: str, shared: bool, target: i32) String {
    let mut s = String::new();
    let o = tgt::os(target);
    if shared {
        s.push_str(o.shared_prefix);
        s.push_str(name);
        s.push_str(o.shared_suffix);
        return s;
    }
    s.push_str("lib");
    s.push_str(name);
    s.push_str(".a");
    return s;
}

/// The name a linked binary must have on `target`: its executable suffix (Windows: `.exe`), which nothing
/// supplies for us: the engine links to `<bin>.tmp` and renames, so the linker never sees a name without
/// an extension to append one to. An extensionless PE cannot even be started: CreateProcess appends
/// `.exe` to a name that has none and then fails to find it. `pub` because the driver names binaries too.
pub(package) fn exe_name(base: str, target: i32) String {
    let mut s = String::from_str(base);
    let sfx = tgt::os(target).exe_suffix;
    if !base.ends_with(sfx) {
        s.push_str(sfx);
    }
    return s;
}

// Where a profile keeps its own copy of the manifest's binary: <out-dir>/<profile>/<name>. Each profile
// links its own, so a `debug` build can never end up standing in for the release artifact: the manifest's
// `bin` is a copy INSTALLED from here, and only by the commands whose job is to produce it.
fn profile_bin(m: &mf::Manifest, prof_name: str, target: i32) String {
    let dir = loader::join2(&m.out_dir, prof_name);
    let leaf = exe_name(loader::basename_of(&m.bin), target);
    return loader::join2(&dir, &leaf);
}

// Copy the profile's binary to `to`, the path the manifest calls the project's binary. A copy rather than a
// move, so the profile keeps the file its next build compares against. Written beside the target and
// renamed onto it, never written over it: truncating an executable that is currently running corrupts the
// image the OS is still paging from, and fs::rename knows how to displace a running one on Windows.
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
    if !write_file(&tmp, &body) {
        let _ = fs::unlink(&tmp);
        eprintln("build: cannot write '{}'", tmp.as_str());
        return 1;
    }
    let _ = fs::set_permissions(&tmp, 0o755);
    if fs::rename(&tmp, to).is_err() {
        eprintln("build: cannot replace '{}'", to);
        return 1;
    }
    return 0;
}

/// Profile name to build with: the CLI `--profile` flag, else the manifest's default-profile.
pub(package) const fn resolve_profile<'a>(m: &'a mf::Manifest<'a>, cli: str<'a>) str<'a> {
    if cli.len() != 0 {
        return cli;
    }
    return m.default_profile.as_str();
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
const fn stamp_field(line: str, idx: usize) str {
    return field_of(line, b'\t', idx);
}

const fn stamp_u64(line: str, idx: usize) u64 {
    return stamp_field(line, idx).parse_u64().unwrap_or(0);
}

/// What the emit stamp takes before the load reads any input: the clock (`ticks_ms`), and the mtime
/// and `.spc` listing (`stamp_dir_hash`) of the std directory, the prelude's file set.
struct StampLoad {
    pub(package) t0: i64,
    pub(package) std_mt: i64,
    pub(package) std_h: u64,
}

fn stamp_load(std_dir: str) StampLoad {
    let mut sl = StampLoad { t0: ticks_ms(), std_mt: 0, std_h: 0 };
    if std_dir.len() != 0 {
        sl.std_mt = file_mtime(std_dir);
        sl.std_h = stamp_dir_hash(std_dir);
    }
    return sl;
}

// The whole seconds since `t0` (`ticks_ms`), rounded up.
fn stamp_lag(t0: i64) u64 {
    return ((ticks_ms() - t0 + 999) / 1000) as u64;
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
    let opened = fs::read_dir(dir);
    if opened.is_err() {
        return 0;
    }
    let mut d = opened.unwrap();
    let mut h: u64 = 0;
    // Bounded by the entries of the directory; a read error ends the listing, as the end does.
    while let Some(Ok(e)) = d.next() {
        if e.name.ends_with(".spc") {
            h = h.wrapping_add(fnv(e.name));
        }
    }
    return h;
}

// The record of directory `dir`, whose `.spc` listing hashed `h` (`stamp_dir_hash`) when the loader
// listed it: its mtime, then that hash. False when the listing now differs: the directory changed
// during the build.
fn stamp_push_dir(out: &mut String, dir: str, h: u64) bool {
    let mt = file_mtime(dir);
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
    // Emission-mode switches change the emitted C or its checks, and SC_UNITY_MAX its units: a stamp
    // written under one mode must not satisfy a build under another.
    out.push_str("\t");
    for i in 0..inl::EMIT_MODE_ENV_N {
        stamp_push_env(out, inl::emit_mode_env(i));
    }
    stamp_push_env(out, "SC_UNITY_MAX");
    // The steps and hooks: a stamp of other extensions must not skip their stages.
    out.format_into("\text {}\n", ext::id());
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
// and `.o` files; `sl` was taken before the load. Written only on full success; an unreadable input or a
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
        &p.simd_dispatch,
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
        // An implicit directory index is its directory's listing, which a `dir` record below covers.
        if md.file.len() != 0 && !md.implicit_index {
            stamp_line(&mut out, "in\t", md.mtime as u64, md.src_id, &md.file);
        }
    }
    // A native build reads C headers' constants into its objects.
    for i in 0..p.header_files.len() {
        let hp = p.header_files.at(i).as_str();
        let h = file_id(hp);
        if h == 0 {
            return;
        }
        stamp_line(&mut out, "in\t", file_mtime(hp) as u64, h, hp);
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
                    h = h.wrapping_add(fnv(ents.at(k).as_str()));
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
    let _ = write_file_atomic(path, &out);
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
    let t0 = ticks_ms();
    let body0 = loader::read_file(path);
    if body0.is_none() {
        return false;
    }
    let body = body0.unwrap();
    let s = body.as_str();
    // Second-granularity mtimes cannot distinguish an edit made in the same second as the read the
    // stamp vouches for: entries stamped within 2s of the stamp file's own mtime, less the record's lag,
    // verify by content instead.
    let mut recent = file_mtime(path) - 2;
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
            let mt = file_mtime(fp);
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
            let mt = file_mtime(dp);
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
        nc += (rels.at(i).as_str().ends_with(".c") || rels.at(i).as_str().ends_with(".o")) as u64;
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
        let _ = write_file_atomic(path, &out);
    }
    return true;
}

/// The options every manifest build passes down to the engine unchanged.
pub(package) struct BuildCtx<'a> {
    pub(package) jobs: u32, // --jobs; 0 = the manifest's `jobs`, else one per core
    pub(package) std_dir: str<'a>,
    pub(package) ce_steps: u32, // compile-time evaluation budgets; 0 = the engine default
    pub(package) ce_mem: u64,
    pub(package) target: i32,
    pub(package) bootstrap_tags: bool,
    pub(package) lint: bool,
    /// `--transpiler`: the command that runs the transpile step in place of this compiler's own frontend
    /// (`run_transpiler`); empty for the frontend.
    pub(package) transpiler: str<'a>,
    /// `--target-feature`: the comma list applied after the manifest's `target-features`.
    pub(package) target_features: str<'a>,
    /// `--simd-width`: 256 or 512; 0 = the manifest's `simd-width`.
    pub(package) simd_width: u32,
    /// `--simd-dispatch`: `off` or x86-64 levels; empty = the manifest's `simd-dispatch`.
    pub(package) simd_dispatch: str<'a>,
    /// `--sysroot`: the target's C library tree, its headers and libraries; empty: discovered.
    pub(package) sysroot: str<'a>,
}

/// The vector width the build's planner prefers on AVX-512: `--simd-width`, else `simd-width`, else 256.
pub(package) const fn simd_width(m: &mf::Manifest, cx: &BuildCtx) u32 {
    return pick(cx.simd_width != 0, cx.simd_width, pick(m.simd_width != 0, m.simd_width, 256));
}

/// The run-time copies' levels (`loader::Package.simd_dispatch`): `--simd-dispatch`, else
/// `simd-dispatch`; empty for the default.
pub(package) const fn simd_dispatch<'a>(m: &'a mf::Manifest, cx: &BuildCtx<'a>) str<'a> {
    return if cx.simd_dispatch.len() != 0 {
        cx.simd_dispatch
    } else {
        m.simd_dispatch.as_str()
    };
}

/// The levels a build at profile `prof` copies for: `spec` when set; else `off` in a profile at
/// opt-level 0 or 1 (`debug`, `test`: the copies make the compile of vector code longer and add little
/// speed there) and in a script build without a profile, the default elsewhere.
pub(package) const fn dispatch_for<'a>(m: &mf::Manifest, prof: str, spec: str<'a>) str<'a> {
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
pub(package) fn check_features(m: &mf::Manifest, cli: str) bool {
    let mut s = tgt::baseline(m.target, m.arch);
    let mut err = String::new();
    let mut ok = cf::level(&m.target_cpu, m.arch, false, &mut s, &mut err);
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

/// The CPU features of a build of `m` under profile `prof_name`: the instruction set's baseline, then
/// the build's `target-cpu` level, then the profile's `target-features` (else the build's), then the command line's list `cli`, closed
/// under `implies`. The lists passed `check_features`.
pub(package) fn features_for(m: &mf::Manifest, prof_name: str, cli: str) cf::CpuFeatureSet {
    let mut s = tgt::baseline(m.target, m.arch);
    let mut err = String::new();
    let _ = cf::level(&m.target_cpu, m.arch, false, &mut s, &mut err);
    let pi = m.profile_index(prof_name);
    let tf = if pi >= 0 && m.profiles.at(pi as usize).has_features {
        &m.profiles.at(pi as usize).target_features
    } else {
        &m.target_features
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
        stamp_load(cx.std_dir)
    } else {
        StampLoad { t0: 0, std_mt: 0, std_h: 0 }
    };
    loader::set_load_jobs(jobs);
    let tl0 = ticks_ms();
    // The build settings the prelude's build constants spell (`@arch` gates on the instruction
    // set too), set before the load.
    let mut p = loader::package_new(root_dir, alt, cx.std_dir);
    p.arch = m.arch;
    p.features = features_for(m, prof_name, cx.target_features);
    p.simd_width = simd_width(m, cx);
    p.simd_dispatch = String::from_str(dispatch_for(m, prof_name, simd_dispatch(m, cx)));
    apply_profile(m, prof_name, &mut p);
    p.sysroot = String::from_str(cx.sysroot);
    p.pic = m.lib_shared && tgt::obj_of(cx.target).pic;
    p.test_build = topts != null && unsafe (*topts).enabled;
    p.profile = String::from_str(prof_name);
    p.profiles = profile_names(m);
    p.bootstrap = cx.bootstrap_tags;
    let pkg = (&mut p) as *mut loader::Package;
    let mut cirv = iri::interp_master(pkg, cx.ce_steps, cx.ce_mem);
    let cdir = object_cache_dir(project_name(m));
    if prelude_stage(&mut p, &mut cirv, cx.std_dir, root, cx.target, jobs, cx.ce_steps, cx.ce_mem, &cdir) {
        // After the prelude stage, which may swap in a saved prelude package.
        p.std_internals = m.std_internals;
        p.lib_build = m.lib_name.len() != 0 && root == m.lib_root.as_str();
        p.load_user(root, cx.std_dir, cx.target);
    }
    bst::mark(bst::B_LOAD);
    if stdlib::getenv("SC_CEMIT_STATS") != null {
        eprintln("phase load: {} ms", ticks_ms() - tl0);
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
    let mut rc = run_package(&mut p, topts, "", cx.target, cx.lint, sink);
    if rc == 0 && p.lib_build && !write_exports(&p, srcgen) {
        rc = 1;
    }
    if rc == 0 && cid != 0 {
        stamp_write(stamp, &p, m, cx.std_dir, root_dir, cx.target, cx.bootstrap_tags, cx.lint, p.unit_files, cid, &sl);
    }
    // The stamp record is the last output of the emission; the package's teardown that follows
    // belongs to the sync phase.
    bst::mark(bst::B_PUBLISH);
    return rc;
}

// Write `<gen>/__sc_exports`: the `@export` symbol of every program declaration of `p`, one per line in
// module order, which the link of a library with `exports = "c"` keeps alone. The standard library's
// exports are runtime hooks, not the library's interface. False when the file does not write.
fn write_exports(p: &loader::Package, gen: str) bool {
    let mut out = String::new();
    for m in 0..p.modules.len() {
        let md = &p.modules[m];
        if !md.has_ast || md.prelude || md.path.as_str().starts_with("std::") {
            continue;
        }
        let a = &p.modules[m].ast;
        let src = p.modules[m].source.as_str();
        for i in 0..a.attrs.len() {
            let at = a.attrs.at(i);
            if at.kind == AttrKind::ATTR_EXPORT as u8 && at.str_span.end > at.str_span.start {
                out.push_str(src.slice(at.str_span.start as usize, at.str_span.end as usize));
                out.push_byte(b'\n');
            }
        }
    }
    let path = loader::join2(gen, "__sc_exports");
    if !write_file(&path, &out) {
        eprintln("build: cannot write '{}'", path.as_str());
        return false;
    }
    return true;
}

// The link flags that keep the symbols of `<gen>/__sc_exports` alone in a shared library for `target`: a
// list file `<pdir>/exports.*` written for the linker. False when a file does not read or write.
fn export_flags(gen: str, pdir: str, target: i32, out: &mut Vector<String>) bool {
    let names = switch loader::read_file(loader::join2(gen, "__sc_exports").as_str()) {
        Some(t) => t,
        None => {
            eprintln("build: the library's export list is missing; build it again");
            return false;
        },
    };
    let fmt = tgt::obj_of(target).name;
    let mut list = String::new();
    let path = loader::join2(
        pdir,
        if fmt == "macho" {
            "exports.txt"
        } else if fmt == "coff" {
            "exports.def"
        } else {
            "exports.map"
        },
    );
    if fmt == "macho" {
        for line in names.as_str().lines() {
            list.format_into("_{}\n", line);
        }
        out.push(format("-Wl,-exported_symbols_list,{}", path.as_str()));
    } else if fmt == "coff" {
        list.push_str("EXPORTS\n");
        for line in names.as_str().lines() {
            list.format_into("    {}\n", line);
        }
        out.push(path.clone());
    } else if fmt == "elf" {
        list.push_str("{\n  global:\n");
        for line in names.as_str().lines() {
            list.format_into("    {};\n", line);
        }
        list.push_str("  local: *;\n};\n");
        out.push(format("-Wl,--version-script={}", path.as_str()));
    } else {
        return true;
    }
    if !write_file(&path, &list) {
        eprintln("build: cannot write '{}'", path.as_str());
        return false;
    }
    return true;
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
            which_path(w, &mut path)
        } else {
            path.push_str(w);
            file_mtime(&path)
        };
        if mt != 0 && !is_dir(&path) {
            h = skey_mix(h, file_id(&path));
        }
    }
    // 0 means "no identity"; a real hash never takes it.
    return h | (h == 0) as u64;
}

// The transpile step through the external transpiler `cx.transpiler`: its words (whitespace-split, the
// contract of every command string in the engine; no shell), then the transpile form of this compiler's
// command line (`manifest_emit`), each argument one argv entry. The transpiler reads build.toml in this
// working directory and writes the tree where the engine's own frontend would (the C tree when `c_tree`),
// so the tree is the same function of the same inputs. `cid` (0: no stamp) becomes the identity in the
// stamp it writes.
fn run_transpiler(m: &mf::Manifest, prof_name: str, root: str, sub: str, cx: &BuildCtx, cid: u64, c_tree: bool) i32 {
    let mut args = Vector::<String>::new();
    split_args(&mut args, cx.transpiler);
    push_arg(&mut args, root);
    args.push(format("--emit-sub={}", sub));
    if c_tree {
        push_arg(&mut args, "--emit-c");
    }
    // Absolute: a transpiler under a WASI runtime starts in the guest's "/".
    let cwd = fs::realpath(".");
    if cwd.is_err() {
        eprintln("build: cannot resolve the working directory for the transpiler");
        return 1;
    }
    args.push(format("--manifest-dir={}", cwd.unwrap().as_str()));
    args.push(format("--out-dir={}", m.out_dir.as_str()));
    args.push(format("--profile={}", prof_name));
    // The level and flags the command line set over the profile.
    let pi = m.profile_index(prof_name);
    if pi >= 0 {
        let prof = m.profiles.at(pi as usize);
        let mut fl = String::new();
        mf::cg_spell(prof.opt, prof.cg_on, prof.cg_off, &mut fl);
        split_args(&mut args, &fl);
    }
    args.push(format("--target={}", tgt::os(cx.target).name));
    args.push(format("--arch={}", tgt::isa(m.arch).name));
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
    if cx.sysroot.len() != 0 {
        args.push(format("--sysroot={}", cx.sysroot));
    }
    let rc = exec_args(&args, "");
    if rc != 0 {
        eprintln("build: transpiler failed (exit {}): {}", rc, render_cmd(&args).as_str());
        return 1;
    }
    return 0;
}

// The transpile form's sink: the tree-relative path of every file the emission rewrote, one per line.
struct RewriteLog {
    pub(package) root_len: usize,
    pub(package) text: String,
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
/// goes to `<out-dir>/<sub>/raw` exactly as the engine's own frontend writes it (its C when `c`, as
/// `--emit-c` does, else its objects), with a nonzero `id` the emit stamp for it, under that identity, to
/// `<out-dir>/<sub>/.emit_stamp.new`, and the paths of the files it rewrote to
/// `<out-dir>/<sub>/.emit_rewritten` (the engine's `rewritten`).
pub(package) fn manifest_emit(m: &mf::Manifest, profile: str, root: str, sub: str, cx: &BuildCtx, id: u64, c: bool) i32 {
    let prof_name = resolve_profile(m, profile);
    if m.profile_index(prof_name) < 0 {
        eprintln("build: unknown profile '{}'", prof_name);
        return 1;
    }
    let pdir = loader::join2(&m.out_dir, sub);
    let srcgen = loader::join2(&pdir, "raw");
    let stamp = loader::join2(&pdir, ".emit_stamp.new");
    // The engine that runs this emission ran the steps: its stamp and cache keys hold their identity.
    let cur = ext::Current {
        profile: String::from_str(prof_name),
        dir: pdir.clone(),
        os: cx.target,
        isa: m.arch,
        id: ext_id(m),
    };
    ext::begin(&cur);
    defer {
        ext::end();
    }
    let mut log = RewriteLog { root_len: srcgen.len(), text: String::new() };
    let mut sink = EmitSink { ctx: (&mut log) as *mut RewriteLog, notify: log_rewritten, objs: null };
    let rc = emit_closure(
        m,
        prof_name,
        root,
        loader::dirname_of(&m.root),
        "",
        &srcgen,
        build_jobs(m, cx),
        cx,
        null,
        if c {
            null
        } else {
            &mut sink
        },
        &stamp,
        id,
    );
    if rc == 0 {
        let _ = write_file_atomic(loader::join2(&pdir, ".emit_rewritten").as_str(), &log.text);
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
    return cpu_count();
}

/// The outcome of `transpile_step`.
pub(package) struct Transpiled {
    pub(package) rc: i32, // the emission's exit code; 0 when the stamp skipped it
    pub(package) skipped: bool, // the emit stamp proved the tree exact: nothing was emitted
    pub(package) cid: u64, // the emitting compiler's identity in the stamp record; 0 = no stamp
    pub(package) gen_files: Vector<String>, // when skipped, the files of <out-dir>/<sub>/raw (`walk_gen_files`)
}

/// The transpile step of an engine build, alone: the emit-stamp check (phase boundary `B_STAMP`), then,
/// unless the stamp proves the tree of <out-dir>/<sub> exact, the emission of `root`'s closure into
/// <out-dir>/<sub>/raw through `cx.transpiler` or this compiler's own frontend (boundaries `B_LOAD` to
/// `B_PUBLISH`), each finished file streamed into `sink` (null: none). The emission writes its stamp
/// record to `.emit_stamp.new`; the engine installs it once the tree is complete. The engine and the
/// self-transpile benchmark run this one function, so the benchmark times what a build transpiles.
pub(package) fn transpile_step(
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
    let pdir = loader::join2(&m.out_dir, sub);
    let srcgen = loader::join2(&pdir, "raw");
    let stamp_path = loader::join2(&pdir, ".emit_stamp");
    let mut stamp_new = stamp_path.clone();
    stamp_new.push_str(".new");
    // The evaluator check needs every body emitted.
    let cache_on = stdlib::getenv("SC_NO_EMIT_CACHE") == null && stdlib::getenv("SC_LIR_EVAL") == null;
    let external = cx.transpiler.len() != 0;
    // The emitting compiler's identity, read before the emission: the tree it emits is its function, of
    // whether it holds C (`--emit-c`: no link takes it, as `run_package` decides) or objects, and of the LIR
    // optimizer's switches (SC_LIR_OPT, SC_LIR_INLINE, SC_LIR_PROMOTE).
    let c_tree = sink == null && (topts == null || !unsafe (*topts).enabled);
    let cid = if !cache_on {
        0 as u64
    } else if external {
        transpiler_id(cx.transpiler) ^ c_tree as u64
    } else {
        let mut sel = String::from_str(pick(c_tree, "c|", "o|"));
        for v in ["SC_LIR_OPT", "SC_LIR_INLINE", "SC_LIR_PROMOTE"] {
            sel.format_into("{}|", stdlib::get_env(v).unwrap_or(String::from_str("-")).as_str());
        }
        compiler_id() ^ fnv_cont(FNV_BASIS, &sel)
    };
    let mut gen_files = Vector::<String>::new();
    let skipped = cache_on && stamp_fresh(
        &stamp_path,
        root_dir,
        cx.std_dir,
        cx.target,
        m.arch,
        features_for(m, prof_name, cx.target_features),
        simd_width(m, cx),
        dispatch_for(m, prof_name, simd_dispatch(m, cx)),
        cx.bootstrap_tags,
        cx.lint,
        &srcgen,
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
    let _ = fs::unlink(&stamp_path);
    let _ = fs::unlink(&stamp_new);
    if external {
        let rw = loader::join2(&pdir, ".emit_rewritten");
        let _ = fs::unlink(&rw);
    }
    let rc = if external {
        run_transpiler(m, prof_name, root, sub, cx, cid, c_tree)
    } else {
        emit_closure(m, prof_name, root, root_dir, alt, &srcgen, jobs, cx, topts, sink, &stamp_new, cid)
    };
    return Transpiled { rc: rc, skipped: false, cid: cid, gen_files: Vector::<String>::new() };
}

// The stamp an emission into <out-dir>/<sub> wrote beside the final one: it vouches for the tree now.
fn stamp_publish(m: &mf::Manifest, sub: str) {
    let stamp_path = loader::join2(loader::join2(&m.out_dir, sub).as_str(), ".emit_stamp");
    let mut stamp_new = stamp_path.clone();
    stamp_new.push_str(".new");
    let _ = fs::rename(&stamp_new, &stamp_path);
}

/// `super-c build --emit-c`: the C tree of the manifest's primary root under `profile`, for the build's
/// target, into <out-dir>/<profile>/raw in place of the objects (`c_build_files` describes its compile);
/// prints the tree's path. Compiles and links nothing.
pub(package) fn manifest_emit_c(m: &mf::Manifest, profile: str, cx: &BuildCtx) i32 {
    let prof_name = resolve_profile(m, profile);
    if m.profile_index(prof_name) < 0 {
        eprintln("build: unknown profile '{}'", prof_name);
        return 1;
    }
    let pdir = loader::join2(&m.out_dir, prof_name);
    let lk = tree_lock(&pdir);
    if !lk.held() {
        return 1;
    }
    let root = m.root.as_str();
    let tr = transpile_step(
        m,
        prof_name,
        root,
        loader::dirname_of(root),
        "",
        prof_name,
        build_jobs(m, cx),
        cx,
        null,
        null,
    );
    if tr.rc != 0 {
        return tr.rc;
    }
    if !tr.skipped && tr.cid != 0 {
        stamp_publish(m, prof_name);
    }
    println("{}/raw", pdir.as_str());
    return 0;
}

/// `transpile_step` for the manifest's primary root under `prof_name`: the tree `root_build` compiles,
/// <out-dir>/<prof_name>/raw. What the self-transpile benchmark runs per round.
pub(package) fn root_transpile(m: &mf::Manifest, prof_name: str, cx: &BuildCtx, sink: *mut EmitSink) i32 {
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
    let pdir = loader::join2(&m.out_dir, sub);
    let lk = tree_lock(&pdir);
    if !lk.held() {
        return 1;
    }
    bst::begin();
    let rc = engine_build_i(m, prof_name, root, root_dir, alt, sub, bin, cx, link_kind, topts);
    bst::finish(rc);
    return rc;
}

/// The longest a build waits for another build of its tree, in milliseconds.
const TREE_LOCK_WAIT_MS: i64 = 30 * 60 * 1000;

/// Take the lock of build tree `dir` (the file `<dir>/.lock`): one process builds a tree at a time. A
/// second build would rewrite the files the first one reads, so the first could compile or link a torn
/// file. Waits for a build in
/// progress at most TREE_LOCK_WAIT_MS. The lock, released when it drops; not `held` after a reported
/// error.
pub(package) fn tree_lock(dir: str) Lock {
    mkdir_p(dir);
    let p = loader::join2(dir, ".lock");
    let mut h = lock_file(&p, 0);
    if h.busy() {
        eprintln("build: waiting for another build of '{}'", dir);
        h = lock_file(&p, TREE_LOCK_WAIT_MS);
        if h.busy() {
            eprintln("build: another build held '{}' for {} minutes", dir, TREE_LOCK_WAIT_MS / 60000);
            return Failed;
        }
    }
    if !h.held() {
        eprintln("build: cannot lock '{}'", p.as_str());
    }
    return h;
}

/// An exclusive lock on a file (`lock_file`).
pub(package) enum Lock {
    /// Held through the open file until it drops; None under WASI, which has no file locks: a WASI
    /// compiler runs as the transpiler of an engine that holds the lock.
    Held(Option<fs::File>),
    /// Another process still holds it.
    Busy,
    /// The file cannot be opened or locked.
    Failed,
}

/// The exclusive lock of file `p` (created when missing), waiting at most `wait_ms` for another process
/// to release it. No child process inherits it, and the system releases it when this process ends.
pub(package) fn lock_file(p: str, wait_ms: i64) Lock {
    if PLATFORM == Platform::Wasm {
        return Lock::Held(Option::<fs::File>::None);
    }
    let opened = fs::open(p, fs::OpenOptions { read: true, write: true, create: true, mode: 0o644 });
    if opened.is_err() {
        return Failed;
    }
    let mut f = opened.unwrap();
    let r = f.lock_exclusive(wait_ms as u64 * 1000000);
    if r.is_ok() {
        return Held(Some(f));
    }
    if r.unwrap_err().kind == IoErrorKind::TimedOut {
        return Busy;
    }
    return Failed;
}

/// Modification time of `path` in nanoseconds (100 ns steps on Windows); 0 when it does not exist.
pub(package) fn file_mtime_ns(path: str) i64 {
    return fs::stat(path).map(|m: fs::Metadata| m.modified_ns).unwrap_or(0);
}

/// The online core count, at least 1; 1 under WASI (one thread of execution: the parallel frontiers
/// resolve to the serial path).
pub(package) fn cpu_count() u32 {
    return cpu::count().unwrap_or(1) as u32;
}

/// The extension identity of the builds of `m`: its steps' configurations and the installed hooks' identity
/// (`build_system::ext`); 0 without either. Part of the per-TU cache key and the emit stamp, so output of other
/// steps or hooks never replays.
pub(package) fn ext_id(m: &mf::Manifest) u64 {
    let h = ext::hooks();
    if m.steps.len() == 0 && h == null {
        return 0;
    }
    let mut t = String::new();
    for i in 0..m.steps.len() {
        let st = &m.steps[i];
        t.format_into("step\t{}\t{}\n", st.name.as_str(), st.cache);
        let lists: [&Vector<String>; 4] = [&st.argv, &st.inputs, &st.outputs, &st.env];
        for l in lists {
            for k in 0..l.len() {
                t.format_into("\t{}\n", l[k].as_str());
            }
            t.push_str("-\n");
        }
    }
    if h != null {
        t.format_into("hooks\t{}\n", unsafe (*h).id);
    }
    return str_id(&t) | 1;
}

// `path` without leading `./`.
fn plain_path(path: str) str {
    let mut p = path;
    while p.starts_with("./") {
        p = p.slice(2, p.len());
    }
    return p;
}

// Whether `path` names a regular file.
fn is_file(path: str) bool {
    return switch fs::stat(path) {
        Ok(md) => md.kind == fs::FileKind::File,
        Err(_) => false,
    };
}

// The content hash of file `path` into `out` as hex; false when it cannot be read.
fn push_file_hash(path: str, out: &mut String) bool {
    return switch loader::read_file(path) {
        Some(t) => {
            hex64(str_id(&t), out);
            true
        },
        None => false,
    };
}

// The record of step `st` before it runs: its argv, its program's path, size and time, the values of its
// environment variables and its inputs' hashes; the program into `prog`. False after printing why the step
// cannot run: its program is missing, an input is missing, or its argv names a project file it does not
// declare (an input it would read untracked).
fn step_record(st: &mf::Step, prog: &mut String, rec: &mut String) bool {
    let nm = st.name.as_str();
    for k in 0..st.argv.len() {
        let a = st.argv[k].as_str();
        let mut c = a;
        let eq = a.find("=");
        if a.starts_with("-") && eq > 0 {
            c = a.slice(eq as usize + 1, a.len());
        }
        let f = plain_path(c);
        if (k == 0 || f.len() != 0 && c.byte_at(0) != b'-') && mf::project_path(f) && is_file(f) {
            let fs0 = String::from_str(f);
            if !st.inputs.contains(&fs0) && !st.outputs.contains(&fs0) {
                eprintln("build: [step.{}] names the project file '{}' in its argv but not in 'inputs'", nm, f);
                return false;
            }
        }
        rec.format_into("a\t{}\n", a);
    }
    let a0 = st.argv[0].as_str();
    if a0.contains("/") {
        prog.push_str(a0);
    } else if which_path(a0, prog) == 0 {
        eprintln("build: [step.{}]: the program '{}' is not in PATH", nm, a0);
        return false;
    }
    switch fs::stat(prog.as_str()) {
        Ok(md) => {
            rec.format_into("prog\t{}\t{}\t{}\n", prog.as_str(), md.size, md.modified_ns);
        },
        Err(_) => {
            eprintln("build: [step.{}]: the program '{}' does not exist", nm, prog.as_str());
            return false;
        },
    }
    for k in 0..st.env.len() {
        let key = st.env[k].as_str();
        switch stdlib::get_env(key) {
            Some(v) => rec.format_into("env\t{}={}\n", key, v.as_str()),
            None => rec.format_into("env\t{}\n", key),
        }
    }
    for k in 0..st.inputs.len() {
        let f = plain_path(&st.inputs[k]);
        rec.format_into("in\t{}\t", f);
        if !is_file(f) || !push_file_hash(f, rec) {
            eprintln("build: [step.{}]: the input '{}' does not exist", nm, f);
            return false;
        }
        rec.push_str("\n");
    }
    return true;
}

// `rec` followed by the hashes of the outputs of `st`; false when one is missing.
fn step_outputs(st: &mf::Step, rec: &String, out: &mut String) bool {
    out.push_string(rec);
    for k in 0..st.outputs.len() {
        let f = plain_path(&st.outputs[k]);
        out.format_into("out\t{}\t", f);
        if !is_file(f) || !push_file_hash(f, out) {
            return false;
        }
        out.push_str("\n");
    }
    return true;
}

/// Whether step `i` of `m` is current: cached, and its record matches its configuration, program,
/// environment, inputs and outputs. Reads only.
pub(package) fn step_current(m: &mf::Manifest, i: usize) bool {
    let st = &m.steps[i];
    let mut prog = String::new();
    let mut rec = String::new();
    let mut now = String::new();
    let rpath = loader::join2(loader::join2(&m.out_dir, ".steps").as_str(), &st.name);
    return st.cache && step_record(st, &mut prog, &mut rec) && step_outputs(st, &rec, &mut now) && file_eq(&rpath, &now);
}

/// Run the steps of `m` (`[step.NAME]`) whose record (`<out-dir>/.steps/<name>`) does not match their
/// configuration, program, environment, inputs and outputs, or that set `cache = false`; in declaration
/// order, without a shell, in the project directory, with only the variables their `env` names. Their
/// names join `ran`. 1 after printing why a step cannot run, failed, or did not write an output.
pub(package) fn run_steps(m: &mf::Manifest, ran: &mut Vector<String>) i32 {
    if m.steps.len() == 0 {
        return 0;
    }
    let rdir = loader::join2(&m.out_dir, ".steps");
    mkdir_p(&rdir);
    // Builds of two profiles run the same steps over the same files: one at a time.
    let lk = lock_file(loader::join2(&rdir, ".lock").as_str(), TREE_LOCK_WAIT_MS);
    if !lk.held() {
        eprintln("build: cannot lock '{}'", rdir.as_str());
        return 1;
    }
    for i in 0..m.steps.len() {
        let st = &m.steps[i];
        let nm = st.name.as_str();
        let mut prog = String::new();
        let mut rec = String::new();
        if !step_record(st, &mut prog, &mut rec) {
            return 1;
        }
        let rpath = loader::join2(&rdir, nm);
        if st.cache {
            let mut now = String::new();
            if step_outputs(st, &rec, &mut now) && file_eq(&rpath, &now) {
                continue;
            }
        }
        let _ = fs::unlink(&rpath);
        let mut envs = Vector::<String>::with_capacity(st.env.len());
        for k in 0..st.env.len() {
            if let Some(v) = stdlib::get_env(&st.env[k]) {
                envs.push(format("{}={}", st.env[k].as_str(), v.as_str()));
            }
        }
        let mut ev = Vector::<str>::with_capacity(envs.len());
        for k in 0..envs.len() {
            ev.push(&envs[k]);
        }
        let mut av = Vector::<str>::with_capacity(st.argv.len());
        for k in 0..st.argv.len() {
            av.push(&st.argv[k]);
        }
        if !process_allowed(&prog) {
            return 1;
        }
        let mut cmd = process::Command::new(&av);
        cmd.program = Some(prog.as_str());
        cmd.env = Some(ev.as_slice());
        let rc = wait_code(process::spawn(cmd));
        if rc != 0 {
            eprintln("build: [step.{}] failed (exit {})", nm, rc);
            return 1;
        }
        let mut done = String::new();
        if !step_outputs(st, &rec, &mut done) {
            for k in 0..st.outputs.len() {
                if !is_file(plain_path(&st.outputs[k])) {
                    eprintln("build: [step.{}] did not write '{}'", nm, st.outputs[k].as_str());
                }
            }
            return 1;
        }
        if !write_file_atomic(&rpath, &done) {
            eprintln("build: cannot write '{}'; the step runs again next build", rpath.as_str());
        }
        ran.push(st.name.clone());
    }
    return 0;
}

// Run the hooks of engine stage `stage` (STAGE_BEFORE_ANALYSIS, STAGE_AFTER_ARTIFACTS) of build `cur`;
// `arts`: the files the build produced. False when a hook reported an error.
fn engine_stage(stage: u32, cur: &ext::Current, arts: *const Vector<String>) bool {
    let h = ext::hooks();
    if h == null {
        return true;
    }
    let d = ext::StageData {
        stage: stage,
        profile: &cur.profile,
        dir: &cur.dir,
        os: cur.os,
        isa: cur.isa,
        pkg: null,
        prog: null,
        artifacts: arts,
    };
    return unsafe (*h).run((*h).ctx, &d);
}

// The native objects a build's emission writes (`EmitSink` kind 3), how many of them it rewrote, and the
// link's `.pending` marker, written at the first new one. With `record` (an API request collects the build,
// `ext::report`), each object as a unit.
struct NatSink {
    pub(package) objs: Vector<String>,
    pub(package) fresh: usize,
    pub(package) pending: String,
    pub(package) marked: bool,
    pub(package) ret: i32,
    pub(package) record: bool,
    pub(package) units: Vector<ext::CompileUnit>,
    pub(package) mem: lu::Mem, // the new objects' bytes, which the link reads (`EmitSink.objs`)
}

fn nat_notify(ctx: *mut void, path: str, _text: str, kind: i32, changed: bool) {
    let s = unsafe &mut *(ctx as *mut NatSink);
    if kind != 3 {
        return;
    }
    s.add(path, changed);
}

extend NatSink {
    // Object `path` of the link, new (`changed`) or not.
    fn add(self: &mut Self, path: str, changed: bool) {
        if changed {
            self.mark();
        }
        self.objs.push(String::from_str(path));
        if self.record {
            self.units.push(ext::CompileUnit { object: String::from_str(path), compiled: changed });
        }
    }

    // A new object: the binary links again, also after an interrupted build.
    fn mark(self: &mut Self) {
        self.fresh += 1;
        if self.marked {
            return;
        }
        self.marked = true;
        if !write_file(&self.pending, "") {
            eprintln("build: cannot write '{}'", self.pending.as_str());
            self.ret = 1;
        }
    }
}

/// The arguments of a link of `objs` into `out` for `m` under profile `prof` (`link_kind` as
/// `engine_build`'s) that the own linker reads: a shared library's flags, the output, the objects, the
/// sysroot, the target's libraries, the manifest's and the profile's `ldflags`, the profile's
/// `link-args`, the `@link` flags the emission recorded under `gen` and `ldlibs`.
pub(package) fn link_args(
    m: &mf::Manifest,
    prof: &mf::Profile,
    cx: &BuildCtx,
    gen: str,
    link_kind: i32,
    out: str,
    soname: str,
    objs: &Vector<String>,
) Vector<String> {
    let mut a = Vector::<String>::new();
    if link_kind == 2 {
        push_arg(&mut a, "-shared");
        // The library's own name, not the temporary it links to: a program that links it records this
        // name and loads the library through it.
        let so = tgt::obj_of(cx.target).soname;
        if so.len() != 0 {
            a.push(format("{}{}", so, soname));
        }
    }
    link_head(&mut a, out, objs, cx.sysroot, cx.target, mf::cg_effective(prof.opt, prof.cg_on, prof.cg_off));
    for i in 0..m.ldflags.len() {
        split_args(&mut a, m.ldflags.at(i).as_str());
    }
    for i in 0..prof.ldflags.len() {
        split_args(&mut a, prof.ldflags.at(i).as_str());
    }
    for i in 0..prof.link_args.len() {
        a.push(format("-Wl,{}", prof.link_args.at(i).as_str()));
    }
    push_ldflags(&mut a, loader::join2(gen, "__ldflags").as_str());
    for i in 0..m.ldlibs.len() {
        split_args(&mut a, m.ldlibs.at(i).as_str());
    }
    return a;
}

/// The arguments every link of the own linker starts with: output `out`, the objects `objs`, the sysroot,
/// target `target`'s libraries and, under code-gen flags `cg`, the flag that drops what nothing reaches.
pub(package) fn link_head(a: &mut Vector<String>, out: str, objs: &Vector<String>, sysroot: str, target: i32, cg: u64) {
    push_arg(a, "-o");
    push_arg(a, out);
    for i in 0..objs.len() {
        a.push(objs.at(i).clone());
    }
    if sysroot.len() != 0 {
        a.push(format("--sysroot={}", sysroot));
    }
    split_args(a, tgt::os(target).exe_link);
    let gc = mf::link_gc(cg, tgt::obj_of(target).name == "macho");
    if gc.len() != 0 {
        push_arg(a, gc);
    }
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
    let t0 = ticks_ms();
    bst::mark(bst::B_START);
    let pdir = loader::join2(&m.out_dir, sub);
    let gen = loader::join2(&pdir, "raw");
    let cur = ext::Current {
        profile: String::from_str(prof_name),
        dir: pdir.clone(),
        os: cx.target,
        isa: m.arch,
        id: ext_id(m),
    };
    ext::begin(&cur);
    defer {
        ext::end();
    }
    if ext::hooks() != null && cx.transpiler.len() != 0 {
        eprintln("build: the hooks run in this compiler's own transpile, which --transpiler replaces");
        return 1;
    }
    let mut steps_ran = Vector::<String>::new();
    if run_steps(m, &mut steps_ran) != 0 || !engine_stage(ext::STAGE_BEFORE_ANALYSIS, &cur, null) {
        return 1;
    }
    let jobs = build_jobs(m, cx);
    // The evaluator check of a test build is part of the emission: nothing links.
    if topts != null && unsafe (*topts).enabled && lir_eval_check() {
        return transpile_step(m, prof_name, root, root_dir, alt, sub, jobs, cx, topts, null).rc;
    }
    let stats = bst::last();
    if stats != null {
        let g = unsafe &mut *stats;
        g.profile.push_str(prof_name);
        g.bin.push_str(bin);
        g.jobs = jobs;
    }
    let lrec = link_record(&m.out_dir, bin);
    let mut fppath = lrec.clone();
    fppath.push_str(".cmd");
    let mut pending = fppath.clone();
    pending.push_str(".pending");
    let mut ns = NatSink {
        objs: Vector::<String>::new(),
        fresh: 0,
        pending: pending,
        marked: false,
        ret: 0,
        record: ext::report() != null,
        units: Vector::<ext::CompileUnit>::new(),
        mem: lu::Mem::new(),
    };
    let mut sink = EmitSink { ctx: (&mut ns) as *mut NatSink, notify: nat_notify, objs: &mut ns.mem };
    bst::mark(bst::B_SETUP);

    // 1) The emission into <out-dir>/<sub>/raw, each native object into the sink: unless the emit stamp
    // proves every input unchanged since the last successful emission, when the tree is exact already.
    let mut tr = transpile_step(m, prof_name, root, root_dir, alt, sub, jobs, cx, topts, &mut sink);
    let skip_emit = tr.skipped;
    let external = cx.transpiler.len() != 0;
    if stats != null {
        unsafe (*stats).skip_emit = skip_emit;
    }
    if !skip_emit {
        if tr.rc != 0 {
            return tr.rc;
        }
        // The emission wrote its stamp beside the final one; only a complete tree gets it.
        if tr.cid != 0 {
            stamp_publish(m, sub);
        }
    }
    let t_transpile = ticks_ms();
    bst::mark(bst::B_SYNC);
    // 2) A tree the stamp kept or an external transpiler wrote: its objects, off a walk of the tree. The
    // record an external transpiler left names the files it rewrote (`manifest_emit`); without one, every
    // object is new.
    if skip_emit || external {
        let mut rels = replace(&mut tr.gen_files, Vector::<String>::new());
        if !skip_emit {
            walk_gen_files(&gen, gen.len(), &mut rels);
        }
        let mut rewritten = Set::<String>::new();
        let mut all_new = false;
        if external && !skip_emit {
            switch loader::read_file(loader::join2(&pdir, ".emit_rewritten").as_str()) {
                Some(t) => {
                    for line in t.as_str().lines() {
                        rewritten.insert(String::from_str(line));
                    }
                },
                None => {
                    all_new = true;
                },
            }
        }
        for i in 0..rels.len() {
            if rels.at(i).as_str().ends_with(".o") {
                ns.add(loader::join2(&gen, rels.at(i).as_str()).as_str(), all_new || rewritten.contains(rels.at(i)));
            }
        }
    }
    let mut ret = ns.ret;
    let mut linked = false;
    let mut t_link = t_transpile;
    let mut link_argv = Vector::<String>::new();
    if ret == 0 {
        // The link list is sorted, so its order never depends on the emission's: the link record holds
        // the whole command.
        ns.objs.sort();
        let objs = &ns.objs;
        let bmt = file_mtime(bin);
        let mut tmp = String::from_str(bin);
        tmp.push_str(".tmp");
        // A shared library records its file's name (a DLL's export directory names itself so): it links
        // under that name, in a directory of its own.
        let tmp_dir = tmp.clone();
        if link_kind == 2 {
            mkdir_p(&tmp_dir);
            tmp = loader::join2(&tmp_dir, loader::basename_of(bin));
        }
        let mut largs = link_args(m, prof, cx, &gen, link_kind, &tmp, loader::basename_of(bin), objs);
        if link_kind == 2 && m.lib_exports_c && !export_flags(&gen, &pdir, cx.target, &mut largs) {
            return 1;
        }
        let strip = prof.strip && link_kind == 0;
        let mut fp = render_cmd(&largs);
        if link_kind == 1 {
            fp.push_str(" +archive");
        }
        if strip {
            fp.push_str(" +strip");
        }
        // 3) Link when anything changed: a new object, a missing binary, or another command than the
        // recorded one.
        let mut need = bmt == 0 || file_mtime(&ns.pending) != 0;
        for i in 0..objs.len() {
            need = need || file_mtime(objs.at(i).as_str()) > bmt;
        }
        if !need {
            need = (switch loader::read_file(&fppath) {
                Some(old) => old.as_str() != fp.as_str(),
                None => true,
            });
        }
        if need {
            linked = true;
            if ns.record {
                link_argv = largs.clone();
            }
            let _ = fs::unlink(&tmp);
            let mut why = String::new();
            let r = if link_kind == 1 {
                lk::archive(m.target, &tmp, objs, &mut why)
            } else {
                lk::link_args(m.target, m.arch, &largs, strip, jobs, &mut ns.mem, &mut why)
            };
            if jobs != 1 {
                prt::shutdown(); // the link may have started the pool
            }
            if r != lk::LINKED {
                eprintln(
                    "build: {} failed: {}",
                    if link_kind == 1 {
                        "archive"
                    } else {
                        "link"
                    },
                    why.as_str(),
                );
                ret = 1;
            } else if fs::rename(&tmp, bin).is_err() {
                eprintln("build: cannot move '{}' into place", bin);
                ret = 1;
            } else if link_kind == 2 && fs::rmdir(&tmp_dir).is_err() {
                eprintln("build: cannot remove '{}'", tmp_dir.as_str());
                ret = 1;
            } else if write_file_atomic(&fppath, &fp) {
                // The pending marker goes only once the link record holds this link: without the record,
                // a same-second object could leave the next build on this binary.
                let _ = fs::unlink(&ns.pending);
            } else {
                eprintln("build: cannot write '{}'; the next build relinks", fppath.as_str());
            }
        }
        t_link = ticks_ms();
        // Retention runs only after a successful build.
        if ret == 0 {
            sweep(m, time::now(), false);
        }
    }
    if ret == 0 {
        let mut arts = Vector::<String>::with_capacity(1);
        arts.push(String::from_str(bin));
        if !engine_stage(ext::STAGE_AFTER_ARTIFACTS, &cur, &arts) {
            ret = 1;
        }
    }
    let rp = ext::report();
    if rp != null {
        unsafe (*rp).targets.push(
            ext::TargetReport {
                artifact: String::from_str(bin),
                emitted: !skip_emit,
                units: replace(&mut ns.units, Vector::<ext::CompileUnit>::new()),
                link: link_argv,
                linked: linked,
                steps_run: steps_ran,
                transpile_ms: t_transpile - t0,
                link_ms: t_link - t_transpile,
            },
        );
    }
    if stats != null {
        unsafe (*stats).linked = linked;
        unsafe (*stats).total_c = ns.objs.len();
        unsafe (*stats).stale_n = ns.fresh;
    }
    if stdlib::getenv("SC_TIMINGS") != null {
        eprintln(
            "timings[{}->{}]: transpile {}ms | link {}ms ({}) | total {}ms",
            prof_name,
            bin,
            t_transpile - t0,
            t_link - t_transpile,
            if linked {
                "relinked"
            } else {
                "cached"
            },
            t_link - t0,
        );
    }
    return ret;
}

/// The link record of binary path `bin` in out-dir `out_dir`, without its `.cmd` extension (also the
/// stem of its `.pending` marker and response file). Per binary and profile-agnostic (out-dir root),
/// since profiles share bin paths and a debug binary left behind by a release link must read as out of
/// date. The name is a hash of the path: it fits NAME_MAX for any path, and two paths do not share it.
pub(package) fn link_record(out_dir: str, bin: str) String {
    let mut h1 = FNV_BASIS;
    let mut h2: u64 = 0x9e3779b97f4a7c15;
    ch_mix_bytes(&mut h1, &mut h2, bin.ptr(), bin.len());
    let mut name = String::from_str("__link-");
    hex64(h1, &mut name);
    hex64(h2, &mut name);
    return loader::join2(out_dir, &name);
}

/// `super-c build` from build.toml: run the engine on the manifest's root under the resolved profile
/// (see `resolve_profile`), linking `bin_override` when non-empty, else the manifest's `bin`. With
/// `bin_override`, `sel_bin` (`--bin=NAME`) names the target linked there: a [bin.NAME] or the root.
pub(package) fn manifest_build(m: &mf::Manifest, profile: str, bin_override: str, sel_bin: str, cx: &BuildCtx) i32 {
    let prof_name = resolve_profile(m, profile);
    if bin_override.len() != 0 {
        // `-o` names an exact path: link straight there, no profile copy and nothing installed.
        let ob = exe_name(bin_override, cx.target);
        if sel_bin.len() == 0 || sel_bin == m.bin.as_str() {
            return root_build(m, prof_name, &ob, cx);
        }
        for i in 0..m.bins.len() {
            let bt = m.bins.at(i);
            if bt.name.as_str() == sel_bin {
                let mut sub = String::from_str(prof_name);
                sub.push_str("-bin-");
                sub.push_string(&bt.name);
                let dir = loader::dirname_of(&m.root);
                return engine_build(m, prof_name, &bt.root, dir, "", &sub, &ob, cx, 0, null);
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
    let dest = exe_name(&m.bin, cx.target);
    return install_bin(&path, &dest);
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
    let dir = loader::join2(&m.out_dir, &sub);
    let path = loader::join2(&dir, leaf);
    let rc = engine_build(m, prof_name, root, loader::dirname_of(&m.root), "", &sub, &path, cx, link_kind, null);
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
    let leaf = exe_name(&bt.name, cx.target);
    return target_build(m, prof_name, &bt.root, &suffix, &leaf, 0, cx, out);
}

/// `super-c build`/`release` over every manifest target (cargo-style): the [lib] section's static and/or
/// shared artifacts, the primary `bin` (installed onto the manifest's `bin` path), and each [bin.NAME].
/// `sel_bin`/`sel_lib` restrict to one target (`--bin=NAME` / `--lib`).
pub(package) fn manifest_build_all(m: &mf::Manifest, profile: str, sel_bin: str, sel_lib: bool, cx: &BuildCtx) i32 {
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
            let leaf = lib_file(&m.lib_name, shared, cx.target);
            let mut path = String::new();
            let rc = target_build(
                m,
                prof_name,
                &m.lib_root,
                "-lib",
                &leaf,
                kind,
                if shared && m.lib_static {
                    &nolint
                } else {
                    cx
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

/// The files `manifest_build_all` makes of `m` at profile `prof_name` for `target`, in its build order: the
/// library's static and shared files, the primary binary in its profile directory, each [bin.NAME].
pub(package) fn artifact_paths(m: &mf::Manifest, prof_name: str, target: i32, out: &mut Vector<String>) {
    if m.lib_name.len() != 0 {
        let dir = loader::join2(&m.out_dir, format("{}-lib", prof_name).as_str());
        for kind in 1..3 {
            let shared = kind == 2;
            if shared && m.lib_shared || !shared && m.lib_static {
                out.push(loader::join2(&dir, lib_file(&m.lib_name, shared, target).as_str()));
            }
        }
    }
    if m.bin.len() != 0 {
        out.push(profile_bin(m, prof_name, target));
    }
    for i in 0..m.bins.len() {
        let bt = m.bins.at(i);
        let dir = loader::join2(&m.out_dir, format("{}-bin-{}", prof_name, bt.name.as_str()).as_str());
        out.push(loader::join2(&dir, exe_name(&bt.name, target).as_str()));
    }
}

/// Scaffold a project in `dir` named `name` (cargo new/init): build.toml, src/main.spc, .gitignore,
/// and a best-effort `git init` when no repository is present. Refuses to overwrite an existing manifest.
pub(package) fn scaffold_project(dir: str, name: str) i32 {
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
    let probe = stdio::fopen(&man, "rb");
    if probe != null {
        unsafe stdio::fclose(probe);
        eprintln("init: '{}' already exists", man.as_str());
        return 1;
    }
    let srcdir = loader::join2(dir, "src");
    mkdir_p(&srcdir);
    let mut toml = String::new();
    toml.push_str("bin = \"");
    toml.push_str(name);
    toml.push_str("\"\nroot = \"src/main.spc\"\n");
    if !write_file(&man, &toml) {
        eprintln("init: cannot write '{}'", man.as_str());
        return 1;
    }
    let mainp = loader::join2(&srcdir, "main.spc");
    let mut mains = String::new();
    mains.push_str("fn main() i32 {\n    println(\"Hello from ");
    mains.push_str(name);
    mains.push_str("!\");\n    return 0;\n}\n");
    if !write_file(&mainp, &mains) {
        eprintln("init: cannot write '{}'", mainp.as_str());
        return 1;
    }
    let gi = loader::join2(dir, ".gitignore");
    let gprobe = stdio::fopen(&gi, "rb");
    if gprobe != null {
        unsafe stdio::fclose(gprobe);
    } else {
        let _ = write_file(&gi, "/build\n");
    }
    let gitdir = loader::join2(dir, ".git");
    if !is_dir(&gitdir) {
        let mut ga = Vector::<String>::new();
        push_arg(&mut ga, "git");
        push_arg(&mut ga, "init");
        push_arg(&mut ga, "-q");
        push_arg(&mut ga, dir);
        let _ = exec_args(&ga, ""); // best-effort: no git, no repository, no error
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
        if is_dir(&s) {
            if !copy_tree(&s, &d, depth + 1) {
                ok = false;
            }
        } else if !copy_file(&s, &d) {
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
        let d = loader::join2(dir, names.at(i).as_str());
        if names.at(i).as_str() == ".git" {
            rm_rf(&d);
        } else if fs::lstat(&d).map(|m: fs::Metadata| m.kind == fs::FileKind::Dir).unwrap_or(false) {
            strip_git(&d);
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
pub(package) fn vendor_dep(root: str, src: str, name_arg: str, ref_arg: str, force: bool) i32 {
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
        name_arg
    } else {
        base.slice(k, base.len())
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
    let dest = loader::join2(&vdir, name);
    if is_dir(&dest) {
        if !force {
            eprintln("vendor: '{}' already exists (replace it with --force)", dest.as_str());
            return 1;
        }
        rm_rf(&dest);
    }
    let is_git = src.starts_with("git@") || src.ends_with(".git") || scheme_len(src) != 0;
    if !is_git && ref_arg.len() != 0 {
        eprintln("vendor: --ref pins a git source; '{}' is a local directory", src);
        return 1;
    }
    mkdir_p(&vdir);
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
        if exec_args(&ga, "") != 0 {
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
            if exec_args(&co, "") != 0 {
                eprintln("vendor: no ref '{}' in '{}'", ref_arg, src);
                rm_rf(&dest);
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
            if exec_args(&su, "") != 0 {
                eprintln("vendor: submodule update failed at '{}' in '{}'", ref_arg, src);
                rm_rf(&dest);
                return 1;
            }
        }
        // The exact commit, captured BEFORE the repository is stripped: afterwards nobody can ask.
        let head = git_head(&dest);
        if head.len() != 0 {
            stamp.push_str("commit = \"");
            stamp.push_str(&head);
            stamp.push_str("\"\n");
        }
        strip_git(&dest);
    } else {
        if !is_dir(src) {
            eprintln("vendor: '{}' is not a directory (a git source needs a scheme, git@, or .git)", src);
            return 1;
        }
        if !copy_tree(src, &dest, 0) {
            eprintln("vendor: copy failed for '{}'", src);
            rm_rf(&dest);
            return 1;
        }
    }
    let sf = loader::join2(&dest, ".vendor");
    let _ = write_file(&sf, &stamp);
    println("vendored {} at {} (import vendor::{}::<module>;)", name, dest.as_str(), name);
    return 0;
}

// The output of `git -C dir <a> <b> <c>` (empty args dropped) with trailing newlines removed, read
// back through `tmp`; empty when git fails or is absent. The exec API does the redirection
// itself: a `>` in the command would need a shell, which Windows does not get.
fn git_capture(dir: str, tmp: str, a: str, b: str, c: str) String {
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
    let rc = exec_args(&ga, tmp);
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
        }
    }
    rm_rf(tmp);
    return out;
}

// `git rev-parse HEAD` of a checkout.
fn git_head(dir: str) String {
    let tmp = loader::join2(dir, ".vendor-head");
    return git_capture(dir, &tmp, "rev-parse", "HEAD", "");
}

// The checkout's identity for a benchmark record: the short commit, "-dirty" appended when a
// tracked file differs from it, or "unknown" when git cannot answer.
fn git_build_id(dir: str, tmp_dir: str) String {
    let tmp = loader::join2(tmp_dir, ".bench_git");
    let mut id = git_capture(dir, &tmp, "rev-parse", "--short=12", "HEAD");
    if id.len() == 0 {
        id.push_str("unknown");
        return id;
    }
    let st = git_capture(dir, &tmp, "status", "--porcelain", "--untracked-files=no");
    if st.len() != 0 {
        id.push_str("-dirty");
    }
    return id;
}

// Length of a URL scheme prefix ("https://...") including the separator, 0 when there is none.
const fn scheme_len(s: str) usize {
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
    let rc = root_build(m, prof_name, &path, cx);
    *out = path;
    return rc;
}

/// `super-c run`: build the manifest binary (like `manifest_build`), then execute it (cargo run).
/// Returns the build's failure code, or the binary's exit code. The binary is `bin_override` if
/// given, else the manifest's `bin`; a bare name is run cwd-relative (`./bin`), never through PATH.
pub(package) fn manifest_run_bin(m: &mf::Manifest, profile: str, bin_override: str, sel_bin: str, cx: &BuildCtx) i32 {
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
        return exec_args(&ra0, "");
    }
    let rc = if bin_override.len() != 0 {
        built = exe_name(bin_override, cx.target);
        root_build(m, prof_name, &built, cx)
    } else {
        // Run the profile's own binary where it was linked; `run` builds to run, it does not install.
        build_into_profile(m, prof_name, cx, &mut built)
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
    return exec_args(&ra, "");
}

// The evaluator check of a test build: `SC_LIR` and `SC_LIR_EVAL` (`run_package`).
fn lir_eval_check() bool {
    return stdlib::getenv("SC_LIR") != null && stdlib::getenv("SC_LIR_EVAL") != null;
}

/// `super-c test`: build the project, then discover <test-dir>/**/*.spc (default tests/), synthesize
/// an aggregating root, and run the @test pipeline on it (SUPERC points at the fresh binary).
pub(package) fn manifest_test(m: &mf::Manifest, profile: str, cx: &BuildCtx, topts: *const TestOpts) i32 {
    let mut nolint = *cx;
    nolint.lint = false;
    if !is_dir(&m.test_dir) {
        eprintln("test: no {}/ directory next to src/", m.test_dir.as_str());
        return 1;
    }
    // The profile's own binary, left where it was linked: `test` must not stand in for `build`, or a run of
    // the suite would replace whatever the manifest's binary currently is (a release artifact, say). With
    // no `--profile`, the binary takes the `test` profile, in a tree of its own beside the
    // runner's <out-dir>/test.
    // The evaluator check only emits the suite: the project's binary is not built and no test runs.
    let check = lir_eval_check();
    let mut binp = String::new();
    let rc = if check {
        0
    } else if profile.len() == 0 {
        let leaf = exe_name(loader::basename_of(&m.bin), cx.target);
        target_build(m, "test", &m.root, "-bin", &leaf, 0, &nolint, &mut binp)
    } else {
        build_into_profile(m, profile, &nolint, &mut binp)
    };
    if rc != 0 {
        return rc;
    }
    let mut src = String::new();
    if suite_import_root(&m.test_dir, "test", &mut src) == 0 {
        eprintln("test: no .spc files under {}/", m.test_dir.as_str());
        return 1;
    }
    mkdir_p(&m.out_dir);
    // A filter is part of the generated root: it imports only the files with a matching test, so the
    // others are not built. Finding them takes a parse of the whole suite.
    let filter = if unsafe (*topts).filter != null {
        unsafe str::from_cstr((*topts).filter)
    } else {
        ""
    };
    if filter.len() != 0 {
        let scanp = loader::join2(&m.out_dir, "test_scan.spc");
        if !write_file(&scanp, &src) {
            eprintln("test: cannot write '{}'", scanp.as_str());
            return 1;
        }
        let p = suite_scan(&scanp, loader::dirname_of(&m.root), cx, m.arch);
        if !p.ok {
            return 1;
        }
        let mut tpref = String::new();
        push_module_path(&mut tpref, &m.test_dir);
        tpref.push_str("::");
        src.clear();
        src.push_str("// generated by `super-c test` -- do not edit\n");
        if test_filter_imports(&p, &tpref, filter, &mut src) == 0 {
            eprintln("test: no test name contains '{}'", filter);
            return 1;
        }
    }
    src.push_str("\nfn main() i32 {\n    return 0;\n}\n");
    let rootp = loader::join2(&m.out_dir, "test_root.spc");
    // Rewrite the root only when its content changed: an unchanged root keeps its mtime, so the emit
    // stamp proves the suite unchanged without hashing every input.
    if !file_eq(&rootp, &src) {
        if !write_file(&rootp, &src) {
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
    let _ = unsafe env::set("SUPERC", &binb);
    // That compiler looks for std/ beside its binary, which `--out-dir` may place outside the project:
    // a project that holds a std tree names it (`SC_STD_DIR`, read by main.spc's `exe_std_dir`).
    if real_path("std/core.spc").len() != 0 && stdlib::get_env("SC_STD_DIR").is_none() {
        let sd = real_path("std");
        let _ = unsafe env::set("SC_STD_DIR", &sd);
    }
    // The runner is built through the engine under the `test` profile, in its own <out-dir>/test tree:
    // the per-TU cache, the native record and the emit stamp turn an unchanged suite into a link check
    // instead of a rebuild of every module.
    let tsub = "test";
    let tdir_out = loader::join2(&m.out_dir, tsub);
    let tbin = loader::join2(&tdir_out, exe_name("__tests", cx.target).as_str());
    let brc = engine_build(m, tsub, &rootp, ".", loader::dirname_of(&m.root), tsub, &tbin, &nolint, 0, topts);
    if brc != 0 || check {
        return brc;
    }
    // The suite's recorded durations balance the shards: `--test-durations`, else
    // `<test dir>/durations.tsv` (written by --test-record-durations).
    let mut durp = loader::join2(&m.test_dir, "durations.tsv");
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
        kept.clone()
    } else {
        loader::join2(&tdir_out, "cache")
    };
    if kept.len() == 0 {
        rm_rf(&tcache);
    }
    mkdir_p(&tcache);
    let ac = real_path(&tcache);
    let _ = unsafe env::set("SC_CACHE_DIR", &ac);
    let trc = test_run_runner(&o, &tbin);
    if kept.len() == 0 {
        rm_rf(&tcache);
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
                let ts = unsafe (*a).at_const(unsafe (*a).ext(id).extend_def.target_type).span;
                let mut cut = ts.start as usize;
                for k in cut + 1..ts.end as usize {
                    if src[k - 1] == b':' && src[k] == b':' {
                        cut = k + 1;
                    }
                }
                let ty = src.slice(cut, ts.end as usize);
                let ed = unsafe (*a).ext(id).extend_def;
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
    let nm = unsafe (*a).at_const(unsafe (*a).ext_name(id)).as_data.name.text;
    let fname = src.slice(nm.start as usize, nm.end as usize);
    let mut name = String::from_str(path);
    name.push_str("::");
    name.push_str(fname);
    if name.as_str().contains(filter) {
        return true;
    }
    if ty.len() == 0 || unsafe (*a).ext(id).function.params.len == 0 {
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
            if unsafe (*a).ext(id).function.vis != VIS_PUB {
                let sp = fnode.span;
                eprintln(
                    "bench: '@bench' function at {}:{} must be 'pub' -- the generated runner calls it from another module",
                    path,
                    sp.start,
                );
                return false;
            }
            let nm = unsafe (*a).at_const(unsafe (*a).ext_name(id)).as_data.name.text;
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
            raw.slice(1, raw.len())
        } else {
            raw
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
            raw.slice(1, raw.len())
        } else {
            raw
        };
        // The `<bench-dir>::` every one of these starts with says nothing: strip it from the name.
        let name = if full.starts_with(prefix) {
            full.slice(prefix.len(), full.len())
        } else {
            full
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
                "true"
            } else {
                "false"
            },
        );
        out.push_str(");\n        if __code >= 0 {\n            return __code;\n        }\n    }\n");
    }
    out.push_str("    return __run.end();\n}\n");
}

/// `super-c bench`: discover `@bench` functions under <bench-dir> (default bench/), build a runner
/// for them under the bench profile (by default) into <out-dir>/bench-bin and run it (skipped when
/// `no_run`). A non-empty `filter` builds and runs only the benchmarks whose name contains it.
pub(package) fn manifest_bench(m: &mf::Manifest, profile: str, no_run: bool, filter: str, cx: &BuildCtx) i32 {
    let mut nolint = *cx;
    nolint.lint = false;
    if !is_dir(&m.bench_dir) {
        eprintln("bench: no {}/ directory next to src/", m.bench_dir.as_str());
        return 1;
    }
    // The module-path prefix the discovery root gives every bench module ("<bench-dir>::").
    let mut bpref = String::new();
    push_module_path(&mut bpref, &m.bench_dir);
    bpref.push_str("::");
    // Two passes, because a benchmark is DISCOVERED rather than registered. The first root imports every
    // module under bench/ so they all get parsed; walking those ASTs for `@bench` gives the list; the second
    // root is written with a call to each one. Loading twice is cheap (the first pass only parses) and it
    // is what keeps a bench file from having to be wired into a hand-maintained `main`.
    let mut listing = String::new();
    let nmods = suite_import_root(&m.bench_dir, "bench", &mut listing);
    if nmods == 0 {
        eprintln("bench: no .spc files under {}/", m.bench_dir.as_str());
        return 1;
    }
    mkdir_p(&m.out_dir);
    let scanp = loader::join2(&m.out_dir, "bench_scan.spc");
    if !write_file(&scanp, &listing) {
        eprintln("bench: cannot write '{}'", scanp.as_str());
        return 1;
    }
    let p = suite_scan(&scanp, loader::dirname_of(&m.root), cx, m.arch);
    let mut found = Vector::<String>::new();
    if !p.ok || !bench_collect(&p, &bpref, &mut found) {
        return 1;
    }
    if found.len() == 0 {
        eprintln("bench: no '@bench' functions under {}/", m.bench_dir.as_str());
        return 1;
    }
    // The selection is part of the generated root, so only the selected benchmarks' modules are built. The
    // name matched is the one the runner reports: "<module path>::<name>" without the "<bench-dir>::".
    if filter.len() != 0 {
        let mut kept = Vector::<String>::new();
        for i in 0..found.len() {
            let e = found.at(i).as_str();
            let quiet = if e[0] == b'-' {
                1 as usize
            } else {
                0 as usize
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
    let build_id = git_build_id(".", &m.out_dir);
    let prof_name = if profile.len() != 0 {
        profile
    } else {
        "bench"
    };
    // The runner prints and records what it was compiled with: the profile, its `opt-level` and its debug
    // information. Quoted into a string literal of the generated root, so no quote survives.
    let mut flags = String::from_str(prof_name);
    let pi = m.profile_index(prof_name);
    if pi >= 0 {
        let prof = m.profiles.at(pi as usize);
        flags.format_into(" opt-level={} debug={}", prof.opt, prof.debug);
    }
    for i in 0..flags.len() {
        if flags.as_str()[i] == b'"' || flags.as_str()[i] == b'\\' {
            flags.set_byte(i, b' ');
        }
    }
    let mut rootsrc = String::new();
    bench_run_root(&found, &bpref, &build_id, &flags, &mut rootsrc);
    let genp = loader::join2(&m.out_dir, "bench_root.spc");
    if !write_file(&genp, &rootsrc) {
        eprintln("bench: cannot write '{}'", genp.as_str());
        return 1;
    }
    let rootp = genp.as_str();
    let sub = loader::join2("bench", prof_name);
    // Bound, not inlined: a `str` taken from a TEMPORARY String dangles the moment the statement ends, and
    // a short name lives inside the String itself, so the borrow points at a dead stack slot.
    let leaf = exe_name("bench-bin", cx.target);
    let bin = loader::join2(&m.out_dir, &leaf);
    // Rooted at the project root (like tests), so `import bench::x;` works for lint AND build.
    let rc = engine_build(m, prof_name, rootp, ".", loader::dirname_of(&m.root), &sub, &bin, &nolint, 0, null);
    if rc != 0 || no_run {
        return rc;
    }
    let mut ra = Vector::<String>::new();
    ra.push(bin.clone());
    // A built binary: argv exec, never through a shell.
    return exec_args(&ra, "");
}

/// `super-c lint`, `build` or `run` of a project whose manifest lists analyzers or hooks (`[tools]`): build a
/// compiler from the vendored compiler (`tools_compiler`), the analyzer modules and the hook modules, then run
/// it with `args` and `SC_TOOLS_RUN=1`. That compiler installs the hooks (`api::build::install`) for its
/// builds, lints as this one does and runs the analyzers after (`api::cli::run` with its tools hook). The engine
/// builds it, so an unchanged project relinks nothing; it reads std from `cx.std_dir`.
pub(package) fn manifest_tools(m: &mf::Manifest, args: Slice<str>, cx: &BuildCtx) i32 {
    if PLATFORM == Platform::Wasm {
        eprintln("tools: the tool compiler runs as a process, which WASI does not have");
        return 1;
    }
    let mut cpath = String::new();
    push_module_path(&mut cpath, &m.tools_compiler);
    let mut root = String::new();
    root.format_into("import {}::src::api::cli as compiler;\n", cpath.as_str());
    if m.tools.len() != 0 {
        root.format_into("import {}::src::api::analysis as an;\n", cpath.as_str());
    }
    if m.hooks.len() != 0 {
        root.format_into("import {}::src::api::build as bld;\n", cpath.as_str());
    }
    let nt = m.tools.len();
    for k in 0..nt + m.hooks.len() {
        let t = if k < nt {
            m.tools.at(k).as_str()
        } else {
            m.hooks.at(k - nt).as_str()
        };
        if !t.ends_with(".spc") || file_mtime(t) == 0 {
            eprintln("tools: [tools] module '{}' is no .spc file of the project", t);
            return 1;
        }
        let mut mp = String::new();
        push_module_path(&mut mp, t.slice(0, t.len() - 4));
        root.format_into("import {} as t{};\n", mp.as_str(), k);
    }
    if nt != 0 {
        root.push_str("\n// The project's analyzers, after the compiler's own lint.\nfn tools(std_dir: str) i32 {\n");
        root.push_str("    let mut list = Vector::<Box<dyn an::Analyzer>>::new();\n");
        for k in 0..nt {
            root.format_into(
                "    let mut v{} = t{}::analyzers();\n    v{}.reverse();\n    while let Some(a) = v{}.pop() {{\n        list.push(a);\n    }}\n",
                k,
                k,
                k,
                k,
            );
        }
        root.push_str("    return an::lint_tools(std_dir, \".\", list);\n}\n");
    }
    root.push_str("\nfn main(args: Vector<str>) i32 {\n");
    if m.hooks.len() != 0 {
        // The project's hooks, installed while the compiler runs.
        root.push_str("    let mut hooks = Vector::<Box<dyn bld::Hook>>::new();\n");
        for k in nt..nt + m.hooks.len() {
            root.format_into(
                "    let mut v{} = t{}::hooks();\n    v{}.reverse();\n    while let Some(h) = v{}.pop() {{\n        hooks.push(h);\n    }}\n",
                k,
                k,
                k,
                k,
            );
        }
        root.push_str(
            "    let _installed = switch bld::install(hooks) {\n        Ok(i) => i,\n        Err(e) => {\n            eprintln(\"error: {}\", e.message.as_str());\n            return 1;\n        },\n    };\n",
        );
    }
    if nt != 0 {
        root.push_str("    let rc = compiler::run(args, Option::<compiler::LintTools>::Some(tools));\n");
    } else {
        root.push_str("    let rc = compiler::run(args, Option::<compiler::LintTools>::None);\n");
    }
    // `_installed` uninstalls the hooks when main returns.
    root.push_str("    return rc;\n}\n");
    mkdir_p(&m.out_dir);
    let genp = loader::join2(&m.out_dir, "tools_root.spc");
    if !write_file(&genp, &root) {
        eprintln("tools: cannot write '{}'", genp.as_str());
        return 1;
    }
    let mut nolint = *cx;
    nolint.lint = false;
    let leaf = exe_name("tools-super-c", cx.target);
    let bin = loader::join2(&m.out_dir, &leaf);
    let rc = engine_build(m, "debug", &genp, ".", loader::dirname_of(&m.root), "tools", &bin, &nolint, 0, null);
    if rc != 0 {
        return rc;
    }
    if unsafe env::set("SC_TOOLS_RUN", "1").is_err() || unsafe env::set("SC_STD_DIR", cx.std_dir).is_err() {
        eprintln("tools: cannot set the tool compiler's environment");
        return 1;
    }
    let mut ra = Vector::<String>::with_capacity(args.len());
    ra.push(bin.clone());
    for i in 1..args.len() {
        ra.push(String::from_str(args[i]));
    }
    return exec_args(&ra, "");
}

/// `super-c command <name>`: run a manifest command, building first when it asks for it. Lines run in
/// order; the first nonzero exit stops and is returned.
pub(package) fn manifest_run(m: &mf::Manifest, name: str, profile: str, cx: &BuildCtx) i32 {
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
        let k = c.env_k.at(e).as_str();
        if unsafe env::set(k, c.env_v.at(e).as_str()).is_err() {
            eprintln("command: cannot set environment variable '{}'", k);
            return 1;
        }
    }
    for i in 0..c.run.len() {
        let rc = run_line(c.run.at(i).as_str());
        if rc != 0 {
            return rc;
        }
    }
    return 0;
}

/// Run command line `line` with this process's standard streams and wait: its exit code, or -1 when it
/// could not start or did not exit (a signal ended it). POSIX runs it through `/bin/sh -c`; Windows hands
/// the line to CreateProcess as written, with no shell, so a line means the same on both only with
/// double quotes and no operators. Never `system()`: on Windows that is cmd.exe, which drops the outer
/// quotes of its `/c` line and then splits the program name at the first '/'.
pub(package) fn run_line(line: str) i32 {
    if !process_allowed(line) {
        return -1;
    }
    let sh: [str; 3] = ["sh", "-c", line];
    let none: [str; 0] = [];
    let mut cmd = if PLATFORM == Platform::Windows {
        process::Command::new(none)
    } else {
        process::Command::new(sh)
    };
    if PLATFORM == Platform::Windows {
        cmd.command_line = Some(line);
    } else {
        cmd.program = Some("/bin/sh");
    }
    return wait_code(process::spawn(cmd));
}

/// The exit code of the child `c` started, once it ends: -1 when it did not start, the wait failed or a
/// signal ended it.
pub(package) fn wait_code(c: Result<process::Child, IoError>) i32 {
    if c.is_err() {
        return -1;
    }
    let mut child = c.unwrap();
    return switch child.wait() {
        Ok(Code(code)) => code,
        _ => -1,
    };
}

/// `super-c clean`: the sweeps every build runs at most once per SWEEP_EVERY, now (`sweep`). `full` (`--full`): remove the out-dir, every emitted tree below the root directory
/// (`root_trees`) and the project's cache root instead.
pub(package) fn manifest_clean(m: &mf::Manifest, full: bool) i32 {
    if !full {
        sweep(m, time::now(), true);
        return 0;
    }
    rm_rf(&m.out_dir);
    let trees = root_trees(m);
    for i in 0..trees.len() {
        rm_root_tree(trees.at(i).as_str());
    }
    let croot = cache_root(project_name(m));
    if croot.len() != 0 {
        rm_rf(&croot);
        println("removed {}", croot.as_str());
    }
    return 0;
}
