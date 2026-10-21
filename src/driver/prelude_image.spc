// The checked prelude image: the package state the prelude stage leaves (`driver::emit::prelude_stage`)
// as bytes, and its cache in the object cache. A build writes the image, then reads it back into
// its own package before its second stage, so a build that loads the image from the cache and one that
// checks the prelude itself continue from the same state.
//
// A cached image is a file of the build cache root's `prelude` directory, named by the hash of what the
// prelude stage reads besides the std files (the std directory as given and the build settings) and by
// the compiler that wrote it. It records the std files it was checked from (content hashes), the
// directories their imports were looked up in (listings) and the path of the compiler; a reader compares
// the files and directories and checks the prelude again on any difference. A read touches it, the cache
// sweep deletes the stale images and the idle ones beyond the most recent (`sweep`), and SC_NO_CACHE
// turns the cache off.
import module::loader as loader;
import driver_shim as shim;
import ir::interp as iri;
import ast::ast as *;
import build_system::objcache as ocache;
import driver::util as *;
import utils::persist as *;

/// The image format; a change to any saved type's layout bumps it.
const IMAGE_VER: u64 = 3;

/// The cache name of the prelude image for `p`'s settings, the constant-evaluation budgets and the
/// type-table hash mode.
pub fn key(p: &loader::Package, std_dir: str, target: i32, steps: u32, mem: u64) u64 {
    let mut h = skey_mix(FNV_BASIS, IMAGE_VER);
    h = mix_str(h, std_dir);
    h = mix_str(h, p.std_root.as_str());
    h = skey_mix(h, target as u64);
    h = skey_mix(h, p.arch as u64);
    h = skey_mix(h, p.features.w[0]);
    h = skey_mix(h, p.features.w[1]);
    h = skey_mix(h, p.simd_width);
    h = mix_str(h, p.simd_dispatch.as_str());
    h = skey_mix(h, p.mem_check as u64);
    h = skey_mix(h, p.build_cfg);
    h = skey_mix(h, p.test_build as u64);
    h = skey_mix(h, p.bootstrap as u64);
    h = mix_str(h, p.profile.as_str());
    h = skey_mix(h, p.profiles.len() as u64);
    for i in 0..p.profiles.len() {
        h = mix_str(h, p.profiles.at(i).as_str());
    }
    h = skey_mix(h, steps);
    h = skey_mix(h, mem);
    // The type tables' hash index differs under SC_TYPE_COLLIDE.
    return skey_mix(h, (unsafe TS_COLLIDE) as u64);
}

// `s` mixed into `h` with its length, so two strings cannot run together.
fn mix_str(h: u64, s: str) u64 {
    return skey_mix(fnv_cont(h, s), s.len() as u64);
}

/// The compiler identity (`compiler_id`) the image cache keys on; 0 when the object cache is off (`cache`,
/// the build's cache root, is empty), so a build without it does not hash the compiler.
pub fn cache_id(cache: str) u64 {
    if cache.len() == 0 {
        return 0;
    }
    return compiler_id();
}

// The file of the image for `key` written by compiler `cid` in cache root `cache`.
fn image_path(cache: str, key: u64, cid: u64) String {
    let mut p = loader::join2(cache, "prelude/");
    p.push_str(image_name(key, cid).as_str());
    return p;
}

// The file name of the image for `key` written by compiler `cid`.
fn image_name(key: u64, cid: u64) String {
    let mut name = String::new();
    ocache::hex64(key, &mut name);
    ocache::hex64(cid, &mut name);
    name.push_str(".img");
    return name;
}

/// The identity of directory `dir`'s listing (`loader::dir_listing`): its names in order, and whether it
/// listed.
pub fn dir_id(dir: str) u64 {
    let mut names = Vector::<String>::new();
    let st = loader::dir_listing(dir, &mut names);
    return listing_id(st, &names);
}

// The identity of a listing: its `loader::dir_listing` state and its sorted names.
fn listing_id(st: u8, names: &Vector<String>) u64 {
    let mut h = skey_mix(FNV_BASIS, st);
    for i in 0..names.len() {
        h = mix_str(h, names.at(i).as_str());
    }
    return h;
}

/// What a checked prelude was read from: every module file with its content hash, every directory the
/// loader listed (the std directory and the import lookups) with its listing's identity, and the real
/// path of the compiler that checked it.
struct Deps {
    pub exe: String,
    pub files: Vector<String>,
    pub file_ids: Vector<u64>,
    pub dirs: Vector<String>,
    pub dir_ids: Vector<u64>,
}

extend Deps as Persist {}

// What `q` was checked from, as its load read it: a file edited or a directory changed during the check
// then fails `deps_current`. `std_id` is `dir_id(std_dir)` from before the load.
fn deps_of(q: &loader::Package, std_dir: str, std_id: u64) Deps {
    let mut d = Deps { exe: loader::real_path_of(exe_path().as_str()) };
    for m in 0..q.modules.len() {
        if q.build_module == m as i32 {
            continue; // the build-constant module has no file: its text is the settings
        }
        d.files.push(q.modules.at(m).file.clone());
        d.file_ids.push(q.modules.at(m).src_id);
    }
    d.dirs.push(String::from_str(std_dir));
    d.dir_ids.push(std_id);
    let dc = &q.dir_cache;
    for i in 0..dc.dirs.len() {
        d.dirs.push(dc.dirs.at(i).clone());
        d.dir_ids.push(listing_id(dc.state[i], dc.entries.at(i)));
    }
    return d;
}

/// The identities of files (`file_id`) and directory listings (`dir_id`), each computed once: the
/// images a sweep checks share their std files and compilers.
struct Ids {
    files: Map<String, u64>,
    dirs: Map<String, u64>,
}

extend Ids {
    fn new() Ids {
        return Ids { files: Map::<String, u64>::new(), dirs: Map::<String, u64>::new() };
    }

    fn file(self: &mut Ids, path: &String) u64 {
        if !self.files.contains_key(path) {
            self.files.insert(path.clone(), file_id(path.as_str()));
        }
        return *self.files.get(path).unwrap();
    }

    fn dir(self: &mut Ids, path: &String) u64 {
        if !self.dirs.contains_key(path) {
            self.dirs.insert(path.clone(), dir_id(path.as_str()));
        }
        return *self.dirs.get(path).unwrap();
    }
}

// Whether the files and directories `d` records are still as recorded.
fn deps_current(d: &Deps, ids: &mut Ids) bool {
    for i in 0..d.files.len() {
        if ids.file(d.files.at(i)) != d.file_ids[i] {
            return false;
        }
    }
    for i in 0..d.dirs.len() {
        if ids.dir(d.dirs.at(i)) != d.dir_ids[i] {
            return false;
        }
    }
    return true;
}

/// The state of `q` after its prelude stage (`driver::emit::check_prelude`) and the deferred checks of
/// its engine `e`. The fields not saved are the settings the reader sets itself, caches, and the state
/// later stages compute.
pub fn save(q: &loader::Package, e: &iri::Interp) String {
    // A sizing pass first: the image is then written into one allocation of its size.
    let mut m = Writer::sizing();
    save_into(q, e, &mut m);
    let mut w = Writer::new();
    w.buf.reserve_exact(m.len());
    save_into(q, e, &mut w);
    return replace(&mut w.buf, String::new());
}

// What `save` writes, into `w`.
fn save_into(q: &loader::Package, e: &iri::Interp, w: &mut Writer) {
    q.modules.save(w);
    q.mod_index.save(w);
    q.mod_chain.save(w);
    q.alias_path.save(w);
    q.alias_id.save(w);
    q.simd_levels.save(w);
    q.build_module.save(w);
    q.build_target.save(w);
    q.ext_inputs.save(w);
    q.core_module.save(w);
    q.core_seeded.save(w);
    w.bytes(((&q.builtin_decls) as *const NodeId) as *const u8, sizeof([NodeId; loader::BT_COUNT_N]));
    q.method_used.save(w);
    q.always_methods.save(w);
    q.tt.deref().save(w);
    q.pub_map.save(w);
    q.publications.save(w);
    q.tt_class.save(w);
    q.idx.save(w);
    q.lint_warnings.save(w);
    q.carry.save(w);
    e.pending.save(w);
    e.pending_consts.save(w);
    e.pending_strict.save(w);
    e.inst_asserts.save(w);
}

/// Load image `img` (from `save`) into `p`, which holds no module yet, and its engine `e`; false when the
/// image is cut short (`p` then holds a partial state the caller drops). The modules join `p`'s type
/// table.
pub fn load(p: &mut loader::Package, e: &mut iri::Interp, img: str) bool {
    let mut r = Reader::new(img.ptr(), img.len());
    p.modules.load(&mut r);
    p.mod_index.load(&mut r);
    p.mod_chain.load(&mut r);
    p.alias_path.load(&mut r);
    p.alias_id.load(&mut r);
    p.simd_levels.load(&mut r);
    p.build_module.load(&mut r);
    p.build_target.load(&mut r);
    p.ext_inputs.load(&mut r);
    p.core_module.load(&mut r);
    p.core_seeded.load(&mut r);
    r.bytes(((&mut p.builtin_decls) as *mut NodeId) as *mut u8, sizeof([NodeId; loader::BT_COUNT_N]));
    p.method_used.load(&mut r);
    p.always_methods.load(&mut r);
    p.tt.deref_mut().load(&mut r);
    p.pub_map.load(&mut r);
    p.publications.load(&mut r);
    p.tt_class.load(&mut r);
    p.idx.load(&mut r);
    p.lint_warnings.load(&mut r);
    p.carry.load(&mut r);
    e.pending.load(&mut r);
    e.pending_consts.load(&mut r);
    e.pending_strict.load(&mut r);
    e.inst_asserts.load(&mut r);
    if !r.ok || r.left() != 0 {
        return false;
    }
    p.bind_types();
    return true;
}

// The file header: the format, the key, the compiler and the payload's length, then the dependencies.
fn header(key: u64, cid: u64, payload: &String) Writer {
    let mut w = Writer::new();
    w.u64(IMAGE_VER);
    w.u64(key);
    w.u64(cid);
    w.u64(payload.len() as u64);
    return w;
}

/// Store `img` in cache root `cache` under `key` for compiler `cid` (`compiler_id`) with the dependencies
/// of `q`, the package that checked it from `std_dir`, whose listing had identity `std_id` (`dir_id`) before the load. A
/// failed write only makes the next build check the prelude again.
pub fn write(cache: str, key: u64, cid: u64, q: &loader::Package, std_dir: str, std_id: u64, img: &String) {
    let path = image_path(cache, key, cid);
    let mut w = header(key, cid, img);
    deps_of(q, std_dir, std_id).save(&mut w);
    w.align();
    mkdir_p(loader::dirname_of(path.as_str()));
    let _ = write_file_atomic_parts(path.as_str(), w.buf.as_str(), img.as_str());
}

/// The image file in cache root `cache` for `key` that compiler `cid` wrote and whose std files are
/// current, and the offset of its payload (16-byte aligned, as `load` reads it); None when there is none.
pub fn read(cache: str, key: u64, cid: u64, at: &mut usize) Option<String> {
    let mut path = image_path(cache, key, cid);
    let body = loader::read_file(path.as_str());
    if body.is_none() {
        return Option::<String>::None;
    }
    let b = body.unwrap();
    let mut d = Deps {};
    let mut ids = Ids::new();
    if !parse(b.as_str(), b.len(), key, cid, &mut d, at) || !deps_current(&d, &mut ids) {
        return Option::<String>::None;
    }
    // A use: the sweep deletes an image idle for its period.
    let _ = unsafe shim::sc_touch(path.cstr());
    return Option::<String>::Some(b);
}

// The dependencies that the head `h` of an image file of `size` bytes records into `d`, and its payload's
// offset into `at`; false when the format, key `key`, compiler `cid` or payload length does not check or
// `h` ends before the payload.
fn parse(h: str, size: usize, key: u64, cid: u64, d: &mut Deps, at: &mut usize) bool {
    let mut r = Reader::new(h.ptr(), h.len());
    let ver = r.u64();
    let k = r.u64();
    let c = r.u64();
    let n = r.u64() as usize;
    d.load(&mut r);
    r.align();
    *at = h.len() - r.left();
    return r.ok && ver == IMAGE_VER && k == key && c == cid && size - *at == n;
}

/// The bytes the sweep reads first of an image: its header and dependencies, about 2 KiB on std.
const HEAD_READ: usize = 64 << 10;

/// The images the sweep keeps whatever their idle time: the most recently used live ones.
const IMAGE_KEEP: usize = 5;
/// An image unused for this many seconds goes, beyond the IMAGE_KEEP most recently used.
const IMAGE_IDLE: i64 = 86400;

// A live image: its file name and its last use.
struct Kept {
    pub name: String,
    pub mt: i64,
}

const fn kept_newer(a: &Kept, b: &Kept) i32 {
    if a.mt > b.mt {
        return -1;
    }
    if a.mt < b.mt {
        return 1;
    }
    return 0;
}

/// Delete the images below cache root `root` that no build reads again: those of another format or
/// name, those whose compiler no longer is at the path it recorded, and those whose std files changed (a
/// reader checks the prelude again); then those unused for IMAGE_IDLE before `now` beyond the IMAGE_KEEP
/// most recently used, and temp files left for ocache::TMP_IDLE. It reads the head of each image
/// (`HEAD_READ`), not its payload. A copy of a compiler that moved checks the prelude once more.
pub fn sweep(root: str, now: i64) {
    let dir = loader::join2(root, "prelude");
    let names = list_dir(dir.as_str(), false).unwrap_or(Vector::<String>::new());
    let mut ids = Ids::new();
    let mut kept = Vector::<Kept>::new();
    for i in 0..names.len() {
        let n = names.at(i).as_str();
        let mut p = loader::join2(dir.as_str(), n);
        let mut mt: i64 = 0;
        if n.ends_with(".tmp") {
            if now - unsafe shim::sc_mtime(p.cstr()) >= ocache::TMP_IDLE {
                let _ = unsafe shim::sc_unlink(p.cstr());
            }
        } else if live(p.as_str(), n, &mut ids, &mut mt) {
            kept.push(Kept { name: String::from_str(n), mt: mt });
        } else {
            let _ = unsafe shim::sc_unlink(p.cstr());
        }
    }
    kept.sort_by(kept_newer);
    for i in IMAGE_KEEP..kept.len() {
        if now - kept[i].mt >= IMAGE_IDLE {
            let mut p = loader::join2(dir.as_str(), kept.at(i).name.as_str());
            let _ = unsafe shim::sc_unlink(p.cstr());
        }
    }
}

// Whether image file `path` named `name` checks, its compiler is still at the path it records, and its
// std files are current; its last use into `mt`.
fn live(path: str, name: str, ids: &mut Ids, mt: &mut i64) bool {
    let mut pc = String::from_str(path);
    let mut size: i64 = 0;
    let fd = unsafe shim::sc_file_open(pc.cstr(), &mut size, mt);
    if fd < 0 {
        return false;
    }
    let want = (size as usize).min(HEAD_READ);
    let mut h = String::with_capacity(want);
    if unsafe shim::sc_file_read_close(fd, h.spare_mut(want), want) != want as i64 {
        return false;
    }
    h.advance_len(want);
    let mut r = Reader::new(h.as_str().ptr(), h.len());
    let ver = r.u64();
    let key = r.u64();
    let cid = r.u64();
    if !r.ok || ver != IMAGE_VER || image_name(key, cid).as_str() != name {
        return false;
    }
    let mut d = Deps {};
    let mut at: usize = 0;
    if !parse(h.as_str(), size as usize, key, cid, &mut d, &mut at) {
        if want == size as usize {
            return false;
        }
        // A head longer than HEAD_READ: read the whole file.
        let b = loader::read_file(path).unwrap_or(String::new());
        d = Deps {};
        if !parse(b.as_str(), b.len(), key, cid, &mut d, &mut at) {
            return false;
        }
    }
    return ids.file(&d.exe) == cid && deps_current(&d, ids);
}
