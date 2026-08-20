// Per-TU emission cache (see cemit_package): for every module whose fingerprint is unchanged the
// seed loop skips lowering and replays the module's journaled side effects -- chunk texts, demand/
// glue/agg/proto attempts, pool interns, liveness edges -- through the emitter's own dedup gates.
// The fingerprint is deliberately package-aware where emission is: it hashes the module's transitive
// import closure (plus the prelude), the ordered module path list (short-prefix collisions and
// ModuleId order rename symbols in UNRELATED TUs), the package extend surface (method_by_name scans
// every module), the prelude-live bit, and the compiler binary itself. Shared headers, the instance
// TU, layout asserts and TU liveness are recomputed every build, so a replayed module's bytes land
// in a fully fresh assembly.
import ast::ast as *;
import emit::mangle as mbe;
import module::loader as loader;
import driver_shim as shim;
import driver::util as *;
import stdlib;

const TUC_MAGIC: u32 = 0x53435455; // "UTCS" little-endian spells SCTU on disk
const TUC_VER: u32 = 1;

fn fnv_mix(h: u64, v: u64) u64 {
    let mut x = h;
    x = (x ^ v & 0xFF) * 1099511628211u64;
    x = (x ^ v >> 8 & 0xFF) * 1099511628211u64;
    x = (x ^ v >> 16 & 0xFF) * 1099511628211u64;
    x = (x ^ v >> 24 & 0xFF) * 1099511628211u64;
    x = (x ^ v >> 32 & 0xFF) * 1099511628211u64;
    x = (x ^ v >> 40 & 0xFF) * 1099511628211u64;
    x = (x ^ v >> 48 & 0xFF) * 1099511628211u64;
    x = (x ^ v >> 56 & 0xFF) * 1099511628211u64;
    return x;
}

fn fnv_str(h: u64, s: str) u64 {
    let mut x = h;
    for k in 0..s.len() {
        x = (x ^ s.byte_at(k) as u64) * 1099511628211u64;
    }
    return x;
}

fn w8(o: &mut String, v: u8) {
    o.push_byte(v);
}

fn w32(o: &mut String, v: u32) {
    o.push_byte((v & 0xFF) as u8);
    o.push_byte((v >> 8 & 0xFF) as u8);
    o.push_byte((v >> 16 & 0xFF) as u8);
    o.push_byte((v >> 24 & 0xFF) as u8);
}

fn w64(o: &mut String, v: u64) {
    w32(o, (v & 0xFFFFFFFF) as u32);
    w32(o, (v >> 32) as u32);
}

fn wstr(o: &mut String, s: str) {
    w32(o, s.len() as u32);
    o.push_str(s);
}

/// Bounds-checked little-endian cursor over the loaded cache image. Any overrun latches `ok=false`
/// and every later read returns zero, so a truncated or corrupt file degrades to a cache miss.
pub struct Rd {
    pub sp: *const u8,
    pub at: usize,
    pub end: usize,
    pub ok: bool,
}

fn r8(r: &mut Rd) u8 {
    if !r.ok || r.at >= r.end {
        r.ok = false;
        return 0;
    }
    let v = unsafe r.sp[r.at];
    r.at += 1;
    return v;
}

fn r32(r: &mut Rd) u32 {
    if !r.ok || r.at + 4 > r.end {
        r.ok = false;
        return 0;
    }
    let v = (unsafe r.sp[r.at]) as u32 | (unsafe r.sp[r.at + 1]) as u32 << 8 | (unsafe r.sp[r.at + 2]) as u32 << 16 | (unsafe r.sp[r.at + 3]) as u32 << 24;
    r.at += 4;
    return v;
}

fn r64(r: &mut Rd) u64 {
    let lo = r32(r) as u64;
    let hi = r32(r) as u64;
    return lo | hi << 32;
}

fn rstr(r: &mut Rd, out: &mut String) {
    let n = r32(r) as usize;
    if !r.ok || r.at + n > r.end {
        r.ok = false;
        return;
    }
    out.push_str(unsafe str::from_raw(r.sp + r.at, n));
    r.at += n;
}

pub struct Tuc {
    pub on: bool,
    pub hdr: u64,
    pub keys: Vector<u64>,
    pub raw: String, // previous cache image ("" = none)
    pub hit: Vector<bool>,
    pub soff: Vector<u64>, // payload offset per module in `raw` (past key+len)
    pub slen: Vector<u64>,
    pub out: String, // next cache image, assembled section by section in module order
    pub path: String,
}

extend Tuc as Free {
    pub fn free(self: &mut Self) {
        self.keys.free();
        self.raw.free();
        self.hit.free();
        self.soff.free();
        self.slen.free();
        self.out.free();
        self.path.free();
    }
}

fn header_hash(p: &loader::Package, target: i32) u64 {
    let mut exe = PathBuf {};
    if unsafe shim::sc_exe_path(&mut exe[0], 4096) != 0 {
        return 0;
    }
    let ep = str::from_cstr(&exe[0]);
    let mt = unsafe shim::sc_mtime(&mut exe[0]);
    if mt == 0 {
        return 0;
    }
    let mut h = 1469598103934665603u64;
    h = fnv_str(h, ep);
    h = fnv_mix(h, mt as u64);
    h = fnv_mix(h, TUC_VER);
    h = fnv_mix(h, target as u64 ^ p.arch as u64 << 8);
    h = fnv_mix(
        h,
        if p.bootstrap {
            1u64;
        } else {
            0 as u64;
        },
    );
    h = fnv_mix(h, p.modules.len() as u64);
    // the ordered path list: prefixing (`user_mods > 1`), short-prefix collisions and ModuleId
    // numbering are all pure functions of it
    for i in 0..p.modules.len() {
        h = fnv_str(h, p.modules[i].path.as_str());
        h = fnv_mix(
            h,
            if p.modules[i].has_ast {
                1u64;
            } else {
                0 as u64;
            },
        );
    }
    // the extend surface: method_by_name resolves first-match over EVERY module's extends, so a
    // method added or renamed anywhere may respell calls in modules that never import it
    for i in 0..p.modules.len() {
        if !p.modules[i].has_ast {
            continue;
        }
        let a = unsafe &*p.module_ast_const(i as ModuleId);
        let its = a.at_const(a.root).as_data.program.items;
        for k in 0..its.len {
            let nid = unsafe a.list(its)[k as usize];
            let n = a.at_const(nid);
            if n.kind != NodeKind::NODE_EXTEND {
                continue;
            }
            h = fnv_mix(h, i as u64 ^ 0xE0);
            h = fnv_mix(
                h,
                if n.as_data.extend_def.interface_type != NODE_NONE {
                    1u64;
                } else {
                    0 as u64;
                },
            );
            let tg = a.resolution_def(n.as_data.extend_def.target_type);
            h = fnv_mix(h, tg.module);
            if tg.node != NODE_NONE {
                let da = unsafe &*p.module_ast_const(tg.module);
                let dn = da.at_const(tg.node);
                if dn.kind == NodeKind::NODE_STRUCT || dn.kind == NodeKind::NODE_ENUM {
                    {
                        let sp9 = da.at_const(dn.as_data.aggregate.name).as_data.name.text;
                        h = fnv_str(
                            h,
                            p.modules[tg.module as usize].source.as_str().slice(sp9.start as usize, sp9.end as usize),
                        );
                    }
                } else {
                    h = fnv_mix(h, tg.node); // rarer targets: node identity (over-invalidates only)
                }
            }
            let ms = n.as_data.extend_def.items;
            for j in 0..ms.len {
                let mid = unsafe a.list(ms)[j as usize];
                let mn = a.at_const(mid);
                if mn.kind == NodeKind::NODE_FUNCTION {
                    {
                        let sp9 = a.at_const(mn.as_data.function.name).as_data.name.text;
                        h = fnv_str(h, p.modules[i].source.as_str().slice(sp9.start as usize, sp9.end as usize));
                    }
                }
            }
        }
    }
    return h;
}

/// Per-module fingerprint: sources of the transitive import closure (prelude included), the
/// module's own identity, and its prelude-live bit. Everything package-shaped lives in the header.
fn keys_compute(p: &loader::Package, live: *const bool, keys: &mut Vector<u64>) {
    let n = p.modules.len();
    let mut srch = Vector::<u64>::new();
    for i in 0..n {
        srch.push(fnv_str(1469598103934665603u64, p.modules[i].source.as_str()));
    }
    let mut inq = Vector::<u8>::new();
    inq.resize_default(n);
    let mut stack = Vector::<u32>::new();
    for m in 0..n {
        for i in 0..n {
            inq.set(i, 0);
        }
        stack.truncate(0);
        stack.push(m as u32);
        inq.set(m, 1);
        for i in 0..n {
            if p.modules[i].prelude && *inq.at(i) == 0 {
                inq.set(i, 1);
                stack.push(i as u32);
            }
        }
        while stack.len() != 0 {
            let cur = switch stack.pop() {
                Some(v) => v as usize,
                None => 0 as usize,
            };
            let lo = (*p.idx.mod_imports.at(cur)) as usize;
            let hi = (*p.idx.mod_imports.at(cur + 1)) as usize;
            for e in lo..hi {
                let d = (*p.idx.imports.at(e)) as usize;
                if *inq.at(d) == 0 {
                    inq.set(d, 1);
                    stack.push(d as u32);
                }
            }
        }
        let mut h = 1469598103934665603u64;
        h = fnv_mix(h, m as u64);
        h = fnv_str(h, p.modules[m].path.as_str());
        for i in 0..n {
            if *inq.at(i) != 0 {
                h = fnv_mix(h, i as u64);
                h = fnv_mix(h, srch[i]);
            }
        }
        if live != null && p.modules[m].prelude {
            h = fnv_mix(
                h,
                if unsafe live[m] {
                    0x1Eu64;
                } else {
                    0xDEADu64;
                },
            );
        }
        keys.push(h);
    }
}

pub fn tuc_setup(p: &loader::Package, live: *const bool, target: i32, gen_root: str) Tuc {
    let mut t = Tuc {
        on: false,
        hdr: 0,
        keys: Vector::<u64>::new(),
        raw: String::new(),
        hit: Vector::<bool>::new(),
        soff: Vector::<u64>::new(),
        slen: Vector::<u64>::new(),
        out: String::new(),
        path: String::new(),
    };
    let n = p.modules.len();
    for _i in 0..n {
        t.hit.push(false);
        t.soff.push(0);
        t.slen.push(0);
    }
    if stdlib::getenv("SC_NO_TU_CACHE") != null || gen_root.len() == 0 || n == 0 {
        return t;
    }
    t.hdr = header_hash(p, target);
    if t.hdr == 0 {
        return t;
    }
    keys_compute(p, live, &mut t.keys);
    t.path.push_str(gen_root);
    t.path.push_str("/.tu_cache");
    t.on = true;
    // the next image starts now; sections append in module order as the seed loop runs
    w32(&mut t.out, TUC_MAGIC);
    w32(&mut t.out, TUC_VER);
    w64(&mut t.out, t.hdr);
    w32(&mut t.out, n as u32);
    let prev = switch loader::read_file(t.path.as_str()) {
        Some(s) => s,
        None => String::new(),
    };
    if prev.len() == 0 {
        return t;
    }
    t.raw = prev;
    let mut r = Rd { sp: t.raw.as_str().ptr(), at: 0, end: t.raw.len(), ok: true };
    if r32(&mut r) != TUC_MAGIC || r32(&mut r) != TUC_VER || r64(&mut r) != t.hdr || r32(&mut r) as usize != n {
        return t; // stale image: every module misses; the new image still gets written
    }
    for m in 0..n {
        let key = r64(&mut r);
        let ln = r32(&mut r) as u64;
        if !r.ok || r.at as u64 + ln > r.end as u64 {
            return t;
        }
        t.soff.set(m, r.at as u64);
        t.slen.set(m, ln);
        t.hit.set(m, key == t.keys[m] && ln != 0);
        r.at += ln as usize;
    }
    if r.at != r.end {
        for m in 0..n {
            t.hit.set(m, false); // trailing garbage: distrust the whole image
        }
    }
    return t;
}

pub fn tuc_open(t: &Tuc, m: usize) Rd {
    return Rd { sp: t.raw.as_str().ptr(), at: t.soff[m] as usize, end: (t.soff[m] + t.slen[m]) as usize, ok: true };
}

// ---- module payloads --------------------------------------------------------------------------
// payload = t0 t1 i0 i1 (u32) | pool records | 0xFF | nev u32 | events
// pool record: 1 = raw Ty + expected TypeId; 2 = raw TyInstance + expected TypeId (its paired
// TYPE_INSTANCE entry). Records replay through intern_type/intern_instance in recorded order, so
// ids match exactly or the section is rejected before any other side effect lands.

fn pool_prefix_hash(a: &Ast, t0: usize, i0: usize) u64 {
    let mut h = 1469598103934665603u64;
    // Ty is padding-free by construction (see Ty's word-wise Hash): raw bytes are deterministic
    let tp = a.type_pool.as_ptr() as *const u8;
    for b in 0..t0 * sizeof(Ty) {
        h = (h ^ (unsafe tp[b]) as u64) * 1099511628211u64;
    }
    // TyInstance carries padding: hash fields only
    for k in 0..i0 {
        let it = a.instances.at(k);
        h = fnv_mix(h, it.module as u64 << 40 ^ it.decl as u64 << 8 ^ it.n as u64);
        for j in 0..it.n {
            h = fnv_mix(h, unsafe it.args[j as usize]);
        }
    }
    return h;
}

pub fn ser_pool(o: &mut String, a: &Ast, t0: usize, t1: usize, i0: usize, i1: usize) {
    w32(o, t0 as u32);
    w32(o, t1 as u32);
    w32(o, i0 as u32);
    w32(o, i1 as u32);
    // recorded events reference pre-seed pool ids of this module: the whole prefix must be byte-
    // identical at replay, not merely the same length (cross-module typecheck interns land here)
    w64(o, pool_prefix_hash(a, t0, i0));
    for ti in t0..t1 {
        let ty = *a.type_pool.at(ti);
        if ty.kind == TypeKind::TYPE_INSTANCE && ty.as_data.inst as usize >= i0 {
            let it = a.instances.at(ty.as_data.inst as usize);
            w8(o, 2);
            let ip = (it as *const TyInstance) as *const u8;
            for b in 0..sizeof(TyInstance) {
                o.push_byte(unsafe ip[b]);
            }
            w32(o, ti as u32);
        } else {
            w8(o, 1);
            let tp = ((&ty) as *const Ty) as *const u8;
            for b in 0..sizeof(Ty) {
                o.push_byte(unsafe tp[b]);
            }
            w32(o, ti as u32);
        }
    }
    w8(o, 0xFF);
}

/// Re-intern the recorded pool delta, run FIRST in a section replay: 0 = ok, 1 = clean reject
/// (nothing mutated yet -- the caller may emit live and re-record), 2 = dirty reject (interns
/// landed before the divergence -- the caller must void the section and skip re-recording).
pub fn replay_pool(r: &mut Rd, a: &mut Ast) i32 {
    let t0 = r32(r) as usize;
    let _t1 = r32(r) as usize;
    let i0 = r32(r) as usize;
    let _i1 = r32(r) as usize;
    let ph = r64(r);
    if !r.ok || a.type_pool.len() != t0 || a.instances.len() != i0 || pool_prefix_hash(a, t0, i0) != ph {
        return 1;
    }
    let mut mutated = false;
    loop {
        let tag = r8(r);
        if !r.ok {
            return reject(mutated);
        }
        if tag == 0xFF {
            return 0;
        }
        if tag == 2 {
            let mut it = TyInstance { module: 0, decl: NODE_NONE, n: 0 };
            let ip = ((&mut it) as *mut TyInstance) as *mut u8;
            for b in 0..sizeof(TyInstance) {
                unsafe ip[b] = r8(r);
            }
            let expect = r32(r);
            if !r.ok {
                return reject(mutated);
            }
            mutated = true;
            if a.intern_instance(it.module, it.decl, &it.args[0], it.n) != expect {
                return 2;
            }
        } else if tag == 1 {
            let mut ty = Ty { kind: TypeKind::TYPE_ERROR, concrete: false };
            let tp = ((&mut ty) as *mut Ty) as *mut u8;
            for b in 0..sizeof(Ty) {
                unsafe tp[b] = r8(r);
            }
            let expect = r32(r);
            if !r.ok {
                return reject(mutated);
            }
            mutated = true;
            if a.intern_type(ty) != expect {
                return 2;
            }
        } else {
            return reject(mutated);
        }
    }
}

fn reject(mutated: bool) i32 {
    if mutated {
        return 2;
    }
    return 1;
}

pub fn ser_ev(o: &mut String, ev: &mbe::RecEv) {
    w8(o, ev.kind);
    w32(o, ev.a);
    w32(o, ev.b);
    w32(o, ev.c);
    w32(o, ev.d);
    w64(o, ev.h);
    wstr(o, ev.s1.as_str());
    wstr(o, ev.s2.as_str());
    w32(o, ev.subs.len() as u32);
    for i in 0..ev.subs.len() {
        let sb = *ev.subs.at(i);
        w32(o, sb.pm);
        w32(o, sb.pnode);
        w32(o, sb.am);
        w32(o, sb.at);
        w32(o, sb.lim);
    }
    w32(o, ev.xs.len() as u32);
    for i in 0..ev.xs.len() {
        w32(o, ev.xs[i]);
    }
}

pub fn ser_evs(o: &mut String, evs: &Vector<mbe::RecEv>, from: usize, bodies: str) {
    w32(o, (evs.len() - from) as u32);
    for i in from..evs.len() {
        let ev = evs.at(i);
        if ev.kind == mbe::RK_CHUNK && ev.s1.len() == 0 {
            // chunk text lives in bodies_all at record time (a/b are its bounds); materialize it
            w8(o, ev.kind);
            w32(o, 0);
            w32(o, 0);
            w32(o, 0);
            w32(o, 0);
            w64(o, 0);
            wstr(o, bodies.slice(ev.a as usize, ev.b as usize));
            wstr(o, "");
            w32(o, 0);
            w32(o, 0);
        } else {
            ser_ev(o, ev);
        }
    }
}

pub fn read_count(r: &mut Rd) u32 {
    return r32(r);
}

pub fn read_ev(r: &mut Rd, ev: &mut mbe::RecEv) bool {
    ev.kind = r8(r);
    ev.a = r32(r);
    ev.b = r32(r);
    ev.c = r32(r);
    ev.d = r32(r);
    ev.h = r64(r);
    ev.s1.truncate(0);
    rstr(r, &mut ev.s1);
    ev.s2.truncate(0);
    rstr(r, &mut ev.s2);
    ev.subs.truncate(0);
    let ns = r32(r) as usize;
    for _i in 0..ns {
        let pm = r32(r) as ModuleId;
        let pnode = r32(r);
        let am = r32(r) as ModuleId;
        let at = r32(r);
        let lim = r32(r);
        ev.subs.push(mbe::MSub { pm: pm, pnode: pnode, am: am, at: at, lim: lim });
    }
    ev.xs.truncate(0);
    let nx = r32(r) as usize;
    for _i in 0..nx {
        ev.xs.push(r32(r));
    }
    return r.ok;
}

/// Append one finished live-module section (key + length + payload) to the next image.
pub fn sec_add(t: &mut Tuc, m: usize, payload: &String) {
    w64(&mut t.out, t.keys[m]);
    w32(&mut t.out, payload.len() as u32);
    t.out.push_string(payload);
}

/// Carry a hit module's previous section into the next image byte for byte.
pub fn sec_keep(t: &mut Tuc, m: usize) {
    w64(&mut t.out, t.keys[m]);
    w32(&mut t.out, t.slen[m] as u32);
    t.out.push_str(t.raw.as_str().slice(t.soff[m] as usize, (t.soff[m] + t.slen[m]) as usize));
}

/// A module that produced no cacheable section (replay precondition failed after a hit): an empty
/// payload never matches on load, so the next build re-emits it live.
pub fn sec_void(t: &mut Tuc, m: usize) {
    w64(&mut t.out, t.keys[m] ^ 0x5555555555555555u64);
    w32(&mut t.out, 0);
}
