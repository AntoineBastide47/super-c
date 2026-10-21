// The checked prelude image: the package state the prelude stage leaves (`driver::emit::prelude_stage`)
// as bytes, and its cache in the object cache. A build writes the image, then reads it back into
// its own package before its second stage, so a build that loads the image from the cache and one that
// checks the prelude itself continue from the same state.
//
// A cached image is an entry of the object cache's shared `script` namespace (`ocache::script_entry`),
// named by the hash of what the prelude stage reads besides the std files (the std directory as given and
// the build settings) and by the compiler that wrote it. It records the std files it was checked from
// (content hashes) and the directories their imports were looked up in (listings); a reader compares both
// and checks the prelude again on any difference. It follows the namespace's rules: a read touches it
// (`touch_entry`), the cache sweep packs and trims it with the objects, and SC_NO_CACHE turns it off.
import module::loader as loader;
import ir::interp as iri;
import ast::ast as *;
import build_system::objcache as ocache;
import driver::util as *;
import utils::persist as *;

/// The image format; a change to any saved type's layout bumps it.
const IMAGE_VER: u64 = 2;

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

/// The compiler identity (`compiler_id`) the image cache keys on; 0 when the object cache is off, so a build
/// without it does not hash the compiler.
pub fn cache_id() u64 {
    if ocache::object_cache_dir().len() == 0 {
        return 0;
    }
    return compiler_id();
}

// The cache entry of the image for `key` written by compiler `cid`; empty when the object cache is off.
fn image_path(key: u64, cid: u64) String {
    let root = ocache::object_cache_dir();
    if root.len() == 0 {
        return root;
    }
    let mut name = String::new();
    ocache::hex64(key, &mut name);
    ocache::hex64(cid, &mut name);
    name.push_str(".o");
    return ocache::script_entry(ocache::script_ns(root.as_str()).as_str(), name.as_str());
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

/// What a checked prelude was read from: every module file with its content hash, and every directory
/// the loader listed (the std directory and the import lookups) with its listing's identity.
struct Deps {
    pub files: Vector<String>,
    pub file_ids: Vector<u64>,
    pub dirs: Vector<String>,
    pub dir_ids: Vector<u64>,
}

extend Deps as Persist {}

// What `q` was checked from, as its load read it: a file edited or a directory changed during the check
// then fails `deps_current`. `std_id` is `dir_id(std_dir)` from before the load.
fn deps_of(q: &loader::Package, std_dir: str, std_id: u64) Deps {
    let mut d = Deps {};
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

// Whether the files and directories `d` records are still as recorded.
fn deps_current(d: &Deps) bool {
    for i in 0..d.files.len() {
        if file_id(d.files.at(i).as_str()) != d.file_ids[i] {
            return false;
        }
    }
    for i in 0..d.dirs.len() {
        if dir_id(d.dirs.at(i).as_str()) != d.dir_ids[i] {
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

/// Store `img` under `key` for compiler `cid` (`compiler_id`) with the dependencies of `q`, the package
/// that checked it from `std_dir`, whose listing had identity `std_id` (`dir_id`) before the load. A
/// failed write only makes the next build check the prelude again.
pub fn write(key: u64, cid: u64, q: &loader::Package, std_dir: str, std_id: u64, img: &String) {
    let path = image_path(key, cid);
    if path.len() == 0 {
        return;
    }
    let mut w = header(key, cid, img);
    deps_of(q, std_dir, std_id).save(&mut w);
    w.align();
    mkdir_p(loader::dirname_of(path.as_str()));
    let _ = write_file_atomic_parts(path.as_str(), w.buf.as_str(), img.as_str());
}

/// The stored image file for `key` that compiler `cid` wrote and whose std files are current, and the
/// offset of its payload (16-byte aligned, as `load` reads it); None when there is none.
pub fn read(key: u64, cid: u64, at: &mut usize) Option<String> {
    let path = image_path(key, cid);
    if path.len() == 0 {
        return Option::<String>::None;
    }
    let body = ocache::read_entry(path.as_str());
    if body.is_none() {
        return Option::<String>::None;
    }
    let b = body.unwrap();
    let mut r = Reader::new(b.as_str().ptr(), b.len());
    let ver = r.u64();
    let k = r.u64();
    let c = r.u64();
    let n = r.u64() as usize;
    let mut d = Deps {};
    d.load(&mut r);
    r.align();
    if !r.ok || ver != IMAGE_VER || k != key || c != cid || r.left() != n || !deps_current(&d) {
        return Option::<String>::None;
    }
    ocache::touch_entry(path.as_str());
    *at = b.len() - n;
    return Option::<String>::Some(b);
}
