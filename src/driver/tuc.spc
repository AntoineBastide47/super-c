// Per-TU emission cache (see cemit_package): for every module whose fingerprint is unchanged the
// seed loop skips lowering and replays the module's journaled side effects -- chunk texts, demand/
// glue/agg/proto attempts, liveness edges -- through the emitter's own dedup gates. Sections are
// POSITION-INDEPENDENT: every TypeId a journaled event carries is translated to a section-local
// structural type table at record time and re-interned at replay, so a section records and replays
// under any pool state -- including the parallel seed frontier, whose intern order is scheduling-
// dependent.
// The fingerprint is deliberately package-aware where emission is: it hashes the module's transitive
// import closure (plus the prelude), the ordered module path list (short-prefix collisions and
// ModuleId order rename symbols in UNRELATED TUs), the package extend surface (method_by_name scans
// every module), the prelude-live bit, and the compiler binary itself. Shared headers, the instance
// TU, layout asserts and TU liveness are recomputed every build, so a replayed module's bytes land
// in a fully fresh assembly.
import ast::ast as *;
import emit::mangle as mbe;
import ir::inline as inl;
import module::loader as loader;
import driver_shim as shim;
import driver::util as *;
import stdlib;

const TUC_MAGIC: u32 = 0x53435455; // "UTCS" little-endian spells SCTU on disk
const TUC_VER: u32 = 3;

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
    // emission-mode switches change the C a body renders to: a record written under one mode
    // must never replay under another
    for i in 0..inl::EMIT_MODE_ENV_N {
        let e = stdlib::getenv(inl::emit_mode_env(i));
        if e != null {
            h = fnv_str(h, str::from_cstr(e));
            h = fnv_mix(h, 101 + i as u64);
        }
    }
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
    if r.r32() != TUC_MAGIC || r.r32() != TUC_VER || r.r64() != t.hdr || r.r32() as usize != n {
        return t; // stale image: every module misses; the new image still gets written
    }
    for m in 0..n {
        let key = r.r64();
        let ln = r.r32() as u64;
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

// ---- module payloads --------------------------------------------------------------------------
// payload = ntab u32 | type-table entries | nev u32 | events
// Events carry table INDICES where they carried TypeIds (0xFFFFFFFF = TYPE_NONE); the table entry
// is a structural description whose children are earlier entries, re-interned at replay into the
// pool the consuming field names. Node ids and declaring modules are stable under the key (the
// sources of the whole import closure), so nominal leaves serialize as raw Ty bytes.

const TT_NONE: u32 = 0xFFFFFFFFu32;
const TT_RAW: u8 = 0;
const TT_WRAP: u8 = 1;
const TT_ARR: u8 = 2;
const TT_INST: u8 = 3;
const TT_PROJ: u8 = 4;
const TT_LIN: u8 = 5;

pub struct TtRec {
    pub memo: Map<u64, u64>, // (am << 32 | at) -> table index
    pub tab: String,
    pub count: u32,
}

extend TtRec as Free {
    pub fn free(self: &mut Self) {
        self.memo.free();
        self.tab.free();
    }
}

pub fn tt_new() TtRec {
    return TtRec { memo: Map::<u64, u64>::new(), tab: String::new(), count: 0 };
}

/// Table index for `(am, at)`, appending the entry (children first) on first sight.
pub fn tt_ref(p: &loader::Package, r: &mut TtRec, am: ModuleId, at: TypeId) u32 {
    if at == TYPE_NONE {
        return TT_NONE;
    }
    let key = am as u64 << 32 | at as u64;
    switch r.memo.get(&key) {
        Some(v) => {
            return (*v) as u32;
        },
        None => {},
    };
    let a = unsafe &*p.module_ast_const(am);
    let ty = *a.type_at(at);
    let k = ty.kind;
    if k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_SLICE {
        let er = tt_ref(p, r, am, ty.as_data.elem);
        w8(&mut r.tab, TT_WRAP);
        w8(&mut r.tab, k as u8);
        w8(&mut r.tab, ty.qualifier);
        w8(
            &mut r.tab,
            if ty.concrete {
                1u8;
            } else {
                0 as u8;
            },
        );
        w32(&mut r.tab, ty.module);
        w32(&mut r.tab, er);
    } else if k == TypeKind::TYPE_ARRAY {
        let er = tt_ref(p, r, am, ty.as_data.arr.elem);
        w8(&mut r.tab, TT_ARR);
        w8(&mut r.tab, ty.qualifier);
        w8(
            &mut r.tab,
            if ty.concrete {
                1u8;
            } else {
                0 as u8;
            },
        );
        w32(&mut r.tab, ty.module);
        w32(&mut r.tab, er);
        w32(&mut r.tab, ty.as_data.arr.len);
    } else if k == TypeKind::TYPE_INSTANCE || k == TypeKind::TYPE_DYN {
        let it = *a.instance(ty.as_data.inst);
        let mut ar = Array::<u32, 8> {};
        for i in 0..it.n {
            ar[i as usize] = tt_ref(p, r, am, unsafe it.args[i as usize]);
        }
        w8(&mut r.tab, TT_INST);
        w8(&mut r.tab, k as u8);
        w8(&mut r.tab, ty.qualifier);
        w8(
            &mut r.tab,
            if ty.concrete {
                1u8;
            } else {
                0 as u8;
            },
        );
        w32(&mut r.tab, ty.module);
        w32(&mut r.tab, it.module);
        w32(&mut r.tab, it.decl);
        w8(&mut r.tab, it.n);
        for i in 0..it.n {
            w32(&mut r.tab, ar[i as usize]);
        }
    } else if k == TypeKind::TYPE_FIELD_PROJECTION {
        let orf = tt_ref(p, r, am, ty.as_data.proj.owner);
        w8(&mut r.tab, TT_PROJ);
        w8(&mut r.tab, ty.qualifier);
        w8(
            &mut r.tab,
            if ty.concrete {
                1u8;
            } else {
                0 as u8;
            },
        );
        w32(&mut r.tab, ty.module);
        w32(&mut r.tab, orf);
        w32(&mut r.tab, ty.as_data.proj.binder);
    } else if k == TypeKind::TYPE_CONST_EXPR {
        let l = *a.const_lin_at(ty.as_data.inst);
        w8(&mut r.tab, TT_LIN);
        w8(&mut r.tab, ty.qualifier);
        w8(
            &mut r.tab,
            if ty.concrete {
                1u8;
            } else {
                0 as u8;
            },
        );
        w32(&mut r.tab, ty.module);
        w64(&mut r.tab, l.k as u64);
        w64(&mut r.tab, l.div_of() as u64);
        w32(&mut r.tab, l.n as u32);
        for i in 0..l.n {
            w32(&mut r.tab, (unsafe l.p[i as usize]).module);
            w32(&mut r.tab, (unsafe l.p[i as usize]).node);
            w64(&mut r.tab, (unsafe l.c[i as usize]) as u64);
        }
    } else {
        // nominal / leaf payloads carry no pool-relative data: raw bytes round-trip
        w8(&mut r.tab, TT_RAW);
        let tp = ((&ty) as *const Ty) as *const u8;
        for b in 0..sizeof(Ty) {
            r.tab.push_byte(unsafe tp[b]);
        }
    }
    let idx = r.count;
    r.count += 1;
    r.memo.insert(key, idx);
    return idx;
}

/// One decoded table entry; fields are tag-specific.
pub struct TtEnt {
    pub tag: u8,
    pub kind: u8,
    pub qual: u8,
    pub conc: u8,
    pub module: u32,
    pub r0: u32, // elem/owner ref
    pub aux: u32, // array len / projection binder
    pub im: u32,
    pub idecl: u32,
    pub n: u8,
    pub argr: [u32; 8],
    pub raw: [u8; 16],
    pub lin: ConstLin,
}

/// Intern table entry `idx` (children first) into module `am`'s pool. `cache` keys (idx, am).
pub fn tt_id(p: &loader::Package, tab: &Vector<TtEnt>, cache: &mut Map<u64, u64>, idx: u32, am: ModuleId) TypeId {
    if idx == TT_NONE {
        return TYPE_NONE;
    }
    if idx as usize >= tab.len() {
        return TYPE_NONE;
    }
    let key = idx as u64 << 32 | am as u64;
    switch cache.get(&key) {
        Some(v) => {
            return (*v) as TypeId;
        },
        None => {},
    };
    let e = tab.at(idx as usize);
    let a = unsafe &mut *(p.module_ast_const(am) as *mut Ast);
    let mut id = TYPE_NONE;
    if e.tag == TT_RAW {
        let mut ty = Ty { kind: TypeKind::TYPE_ERROR, concrete: false };
        let tp = ((&mut ty) as *mut Ty) as *mut u8;
        for b in 0..sizeof(Ty) {
            unsafe tp[b] = unsafe e.raw[b];
        }
        id = a.intern_type(ty);
    } else if e.tag == TT_WRAP {
        let el = tt_id(p, tab, cache, e.r0, am);
        id = a.intern_type(
            Ty {
                kind: e.kind as TypeKind,
                qualifier: e.qual,
                concrete: e.conc != 0,
                module: e.module as ModuleId,
                as_data: TyAs { elem: el },
            },
        );
    } else if e.tag == TT_ARR {
        let el = tt_id(p, tab, cache, e.r0, am);
        id = a.intern_type(
            Ty {
                kind: TypeKind::TYPE_ARRAY,
                qualifier: e.qual,
                concrete: e.conc != 0,
                module: e.module as ModuleId,
                as_data: TyAs { arr: TyArr { elem: el, len: e.aux } },
            },
        );
    } else if e.tag == TT_INST {
        let mut ar = Array::<TypeId, 8> {};
        for i in 0..e.n {
            ar[i as usize] = tt_id(p, tab, cache, unsafe e.argr[i as usize], am);
        }
        id = if e.kind as TypeKind == TypeKind::TYPE_DYN {
            a.intern_dyn(e.im as ModuleId, e.idecl, &ar[0], e.n, e.qual);
        } else {
            a.intern_instance(e.im as ModuleId, e.idecl, &ar[0], e.n);
        };
    } else if e.tag == TT_PROJ {
        let ow = tt_id(p, tab, cache, e.r0, am);
        id = a.intern_type(
            Ty {
                kind: TypeKind::TYPE_FIELD_PROJECTION,
                qualifier: e.qual,
                concrete: e.conc != 0,
                module: e.module as ModuleId,
                as_data: TyAs { proj: TyProj { owner: ow, binder: e.aux } },
            },
        );
    } else {
        let l = e.lin;
        id = a.intern_const_lin(&l);
    }
    cache.insert(key, id);
    return id;
}

// The id slots per event kind (see RK_*): each pairs a TypeId field with the field naming its pool.
fn ev_tr(
    p: &loader::Package,
    r: &mut TtRec,
    ev: &mbe::RecEv,
    b_out: &mut u32,
    d_out: &mut u32,
    xs_out: &mut Vector<u32>,
    subs_out: &mut Vector<u32>,
) {
    *b_out = ev.b;
    *d_out = ev.d;
    if ev.kind == mbe::RK_GLUE || ev.kind == mbe::RK_STAT {
        *d_out = tt_ref(p, r, ev.a as ModuleId, ev.d);
    } else if ev.kind == mbe::RK_DYNREQ || ev.kind == mbe::RK_TI || ev.kind == mbe::RK_MDYN {
        *b_out = tt_ref(p, r, ev.a as ModuleId, ev.b);
    } else if ev.kind == mbe::RK_DYNTAB {
        *b_out = tt_ref(p, r, ev.a as ModuleId, ev.b);
        *d_out = tt_ref(p, r, ev.c as ModuleId, ev.d);
    }
    if ev.kind == mbe::RK_AGG {
        for i in 0..ev.xs.len() {
            xs_out.push(tt_ref(p, r, ev.a as ModuleId, ev.xs[i]));
        }
    } else {
        for i in 0..ev.xs.len() {
            xs_out.push(ev.xs[i]);
        }
    }
    if ev.kind == mbe::RK_DEMAND || ev.kind == mbe::RK_GLUE || ev.kind == mbe::RK_AGG {
        for i in 0..ev.subs.len() {
            subs_out.push(tt_ref(p, r, ev.subs.at(i).am, ev.subs.at(i).at));
        }
    } else {
        for i in 0..ev.subs.len() {
            subs_out.push(ev.subs.at(i).at);
        }
    }
}

/// Rewrite a decoded event's table refs back to live TypeIds interned into the consuming pools.
pub fn ev_patch(p: &loader::Package, tab: &Vector<TtEnt>, cache: &mut Map<u64, u64>, ev: &mut mbe::RecEv) {
    if ev.kind == mbe::RK_GLUE || ev.kind == mbe::RK_STAT {
        ev.d = tt_id(p, tab, cache, ev.d, ev.a as ModuleId);
    } else if ev.kind == mbe::RK_DYNREQ || ev.kind == mbe::RK_TI || ev.kind == mbe::RK_MDYN {
        ev.b = tt_id(p, tab, cache, ev.b, ev.a as ModuleId);
    } else if ev.kind == mbe::RK_DYNTAB {
        ev.b = tt_id(p, tab, cache, ev.b, ev.a as ModuleId);
        ev.d = tt_id(p, tab, cache, ev.d, ev.c as ModuleId);
    }
    if ev.kind == mbe::RK_AGG {
        for i in 0..ev.xs.len() {
            ev.xs.set(i, tt_id(p, tab, cache, ev.xs[i], ev.a as ModuleId));
        }
    }
    if ev.kind == mbe::RK_DEMAND || ev.kind == mbe::RK_GLUE || ev.kind == mbe::RK_AGG {
        for i in 0..ev.subs.len() {
            let am = ev.subs.at(i).am;
            let nv = tt_id(p, tab, cache, ev.subs.at(i).at, am);
            ev.subs.index_mut(i).at = nv;
        }
    }
}

fn ser_ev_tr(p: &loader::Package, r: &mut TtRec, o: &mut String, ev: &mbe::RecEv) {
    let mut b = ev.b;
    let mut d = ev.d;
    let mut xs = Vector::<u32>::new();
    let mut sat = Vector::<u32>::new();
    ev_tr(p, r, ev, &mut b, &mut d, &mut xs, &mut sat);
    w8(o, ev.kind);
    w32(o, ev.a);
    w32(o, b);
    w32(o, ev.c);
    w32(o, d);
    w64(o, ev.h);
    wstr(o, ev.s1.as_str());
    wstr(o, ev.s2.as_str());
    w32(o, ev.subs.len() as u32);
    for i in 0..ev.subs.len() {
        let sb = *ev.subs.at(i);
        w32(o, sb.pm);
        w32(o, sb.pnode);
        w32(o, sb.am);
        w32(o, sat[i]);
        w32(o, sb.lim);
    }
    w32(o, xs.len() as u32);
    for i in 0..xs.len() {
        w32(o, xs[i]);
    }
}

/// Serialize `evs[from..]` as one section payload: the structural type table first, then the
/// events with every TypeId slot rewritten to a table index.
pub fn ser_evs(p: &loader::Package, o: &mut String, evs: &Vector<mbe::RecEv>, from: usize, bodies: str) {
    let mut r = tt_new();
    let mut eb = String::new();
    for i in from..evs.len() {
        let ev = evs.at(i);
        if ev.kind == mbe::RK_CHUNK && ev.s1.len() == 0 {
            // chunk text lives in the bodies buffer at record time (a/b are its bounds)
            w8(&mut eb, ev.kind);
            w32(&mut eb, 0);
            w32(&mut eb, 0);
            w32(&mut eb, 0);
            w32(&mut eb, 0);
            w64(&mut eb, 0);
            wstr(&mut eb, bodies.slice(ev.a as usize, ev.b as usize));
            wstr(&mut eb, "");
            w32(&mut eb, 0);
            w32(&mut eb, 0);
        } else {
            ser_ev_tr(p, &mut r, &mut eb, ev);
        }
    }
    w32(o, r.count);
    o.push_string(&r.tab);
    w32(o, (evs.len() - from) as u32);
    o.push_string(&eb);
}

extend Rd {
    fn r8(self: &mut Self) u8 {
        if !self.ok || self.at >= self.end {
            self.ok = false;
            return 0;
        }
        let v = unsafe self.sp[self.at];
        self.at += 1;
        return v;
    }

    fn r32(self: &mut Self) u32 {
        if !self.ok || self.at + 4 > self.end {
            self.ok = false;
            return 0;
        }
        let v = (unsafe self.sp[self.at]) as u32 | (unsafe self.sp[self.at + 1]) as u32 << 8 | (unsafe self.sp[self.at + 2]) as u32 << 16 | (unsafe self.sp[self.at + 3]) as u32 << 24;
        self.at += 4;
        return v;
    }

    fn r64(self: &mut Self) u64 {
        let lo = self.r32() as u64;
        let hi = self.r32() as u64;
        return lo | hi << 32;
    }

    fn rstr(self: &mut Self, out: &mut String) {
        let n = self.r32() as usize;
        if !self.ok || self.at + n > self.end {
            self.ok = false;
            return;
        }
        out.push_str(unsafe str::from_raw(self.sp + self.at, n));
        self.at += n;
    }

    pub fn read_table(self: &mut Self, out: &mut Vector<TtEnt>) bool {
        let ntab = self.r32() as usize;
        for _i in 0..ntab {
            let mut e = TtEnt {
                tag: self.r8(),
                kind: 0,
                qual: 0,
                conc: 0,
                module: 0,
                r0: 0,
                aux: 0,
                im: 0,
                idecl: 0,
                n: 0,
                argr: [0; 8],
                raw: [0; 16],
                lin: ConstLin { k: 0, n: 0 },
            };
            if e.tag == TT_RAW {
                for b in 0..sizeof(Ty) {
                    unsafe e.raw[b] = self.r8();
                }
            } else if e.tag == TT_WRAP {
                e.kind = self.r8();
                e.qual = self.r8();
                e.conc = self.r8();
                e.module = self.r32();
                e.r0 = self.r32();
            } else if e.tag == TT_ARR {
                e.qual = self.r8();
                e.conc = self.r8();
                e.module = self.r32();
                e.r0 = self.r32();
                e.aux = self.r32();
            } else if e.tag == TT_INST {
                e.kind = self.r8();
                e.qual = self.r8();
                e.conc = self.r8();
                e.module = self.r32();
                e.im = self.r32();
                e.idecl = self.r32();
                e.n = self.r8();
                if e.n > 8 {
                    return false;
                }
                for i in 0..e.n {
                    unsafe e.argr[i as usize] = self.r32();
                }
            } else if e.tag == TT_PROJ {
                e.qual = self.r8();
                e.conc = self.r8();
                e.module = self.r32();
                e.r0 = self.r32();
                e.aux = self.r32();
            } else if e.tag == TT_LIN {
                e.qual = self.r8();
                e.conc = self.r8();
                e.module = self.r32();
                e.lin.k = self.r64() as i64;
                let dv = self.r64() as i64;
                e.lin.div = dv;
                let ln = self.r32();
                if ln > 4 {
                    return false;
                }
                e.lin.n = ln as i32;
                for i in 0..ln {
                    let dm = self.r32() as ModuleId;
                    let dn = self.r32();
                    unsafe e.lin.p[i as usize] = DefId { module: dm, node: dn };
                    unsafe e.lin.c[i as usize] = self.r64() as i64;
                }
            } else {
                return false;
            }
            if !self.ok {
                return false;
            }
            out.push(e);
        }
        return self.ok;
    }

    pub fn read_count(self: &mut Self) u32 {
        return self.r32();
    }

    pub fn read_ev(self: &mut Self, ev: &mut mbe::RecEv) bool {
        ev.kind = self.r8();
        ev.a = self.r32();
        ev.b = self.r32();
        ev.c = self.r32();
        ev.d = self.r32();
        ev.h = self.r64();
        ev.s1.truncate(0);
        self.rstr(&mut ev.s1);
        ev.s2.truncate(0);
        self.rstr(&mut ev.s2);
        ev.subs.truncate(0);
        let ns = self.r32() as usize;
        for _i in 0..ns {
            let pm = self.r32() as ModuleId;
            let pnode = self.r32();
            let am = self.r32() as ModuleId;
            let at = self.r32();
            let lim = self.r32();
            ev.subs.push(mbe::MSub { pm: pm, pnode: pnode, am: am, at: at, lim: lim });
        }
        ev.xs.truncate(0);
        let nx = self.r32() as usize;
        for _i in 0..nx {
            ev.xs.push(self.r32());
        }
        return self.ok;
    }
}

extend Tuc {
    pub fn open(self: &Self, m: usize) Rd {
        return Rd {
            sp: self.raw.as_str().ptr(),
            at: self.soff[m] as usize,
            end: (self.soff[m] + self.slen[m]) as usize,
            ok: true,
        };
    }

    /// Append one finished live-module section (key + length + payload) to the next image.
    pub fn sec_add(self: &mut Self, m: usize, payload: &String) {
        w64(&mut self.out, self.keys[m]);
        w32(&mut self.out, payload.len() as u32);
        self.out.push_string(payload);
    }

    /// Carry a hit module's previous section into the next image byte for byte.
    pub fn sec_keep(self: &mut Self, m: usize) {
        w64(&mut self.out, self.keys[m]);
        w32(&mut self.out, self.slen[m] as u32);
        self.out.push_str(self.raw.as_str().slice(self.soff[m] as usize, (self.soff[m] + self.slen[m]) as usize));
    }

    /// A module that produced no cacheable section (replay precondition failed after a hit): an empty
    /// payload never matches on load, so the next build re-emits it live.
    pub fn sec_void(self: &mut Self, m: usize) {
        w64(&mut self.out, self.keys[m] ^ 0x5555555555555555u64);
        w32(&mut self.out, 0);
    }
}
