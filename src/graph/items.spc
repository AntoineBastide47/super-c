// The item schedule index (plan v2/8): the package-owned records the semantic scheduler reads,
// built from the package index and the resolution side tables. `build` runs once resolution is
// complete: stable keys, the (module, node) lookup, the precheck dependency ranges and their
// strongly connected components, and the Resolved state. `finalize` refines it on demand once
// the checks are done: the signature hashes from the post-typecheck signature metadata and the
// final dependency ranges (the resolutions typecheck added, the engine's dynamic body edges);
// its consumers (invalidation, instance work) call it, so a build that needs neither pays
// nothing for it. The batch and the language server share the readiness states. SC_ITEM_STATS=1 prints the
// measurement that gated the index (`report`): per-item costs, the graph, and the predicted
// makespans of an item schedule against the module schedule the frontier runs today.
import ast::ast as *;
import module::loader as loader;
import std::parallel::platform as plat;

const NONE: u32 = 0xFFFFFFFF;
const TMEMO: usize = 1024; // target memo slots (a 10-bit hash)
const FNV_OFF: u64 = 0xCBF29CE484222325u64;
const FNV_PRIME: u64 = 0x100000001B3u64;

const fn mix(h: u64, v: u64) u64 {
    return (h ^ v) * FNV_PRIME;
}

fn hash_bytes(mut h: u64, b: str) u64 {
    for i in 0..b.len() {
        h = mix(h, b[i]);
    }
    return h;
}

/// Per-module declaration spans for the owner lookup (items in source order; members nest
/// inside their extend). Read-only once built: the resolve frontier's tasks share them.
pub struct Spans {
    pub top_s: Vector<u32>,
    pub top_e: Vector<u32>,
    pub top_id: Vector<u32>,
    pub mem_s: Vector<u32>,
    pub mem_e: Vector<u32>,
    pub mem_id: Vector<u32>,
}

// The previous answer of an owner lookup: consecutive nodes share an owner. Only a leaf
// answer (a member, or a top-level item without members) is reused: an extend's span holds its
// members' spans.
struct Cache {
    pub m: u32,
    pub item: u32,
    pub s: u32,
    pub e: u32,
    pub leaf: bool,
}

const fn cache_none() Cache {
    return Cache { m: NONE, item: NONE, s: 0, e: 0, leaf: false };
}

fn spans_of(p: &loader::Package, m: usize) Spans {
    let mut sp = Spans {
        top_s: Vector::<u32>::new(),
        top_e: Vector::<u32>::new(),
        top_id: Vector::<u32>::new(),
        mem_s: Vector::<u32>::new(),
        mem_e: Vector::<u32>::new(),
        mem_id: Vector::<u32>::new(),
    };
    if !p.modules.at(m).has_ast {
        return sp;
    }
    let a = &p.modules.at(m).ast;
    for i in p.idx.mod_items[m] as usize..p.idx.mod_items[m + 1] as usize {
        let it = p.idx.items.at(i);
        let s = a.at_const(it.node).span;
        if it.owner == loader::ITEM_NONE {
            sp.top_s.push(s.start);
            sp.top_e.push(s.end);
            sp.top_id.push(i as u32);
        } else {
            sp.mem_s.push(s.start);
            sp.mem_e.push(s.end);
            sp.mem_id.push(i as u32);
        }
    }
    return sp;
}

// Index of the last span starting at or before `off` when that span also ends after `off`.
fn span_find(s: &Vector<u32>, e: &Vector<u32>, off: u32) u32 {
    let mut lo: usize = 0;
    let mut hi: usize = s.len();
    while lo < hi {
        let mid = (lo + hi) / 2;
        if s[mid] <= off {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if lo == 0 || off >= e[lo - 1] {
        return NONE;
    }
    return (lo - 1) as u32;
}

// The innermost item of module `m` whose declaration holds byte `off`, or NONE (an import, a
// synthesized node without a source span).
fn owner_at(p: &loader::Package, sps: &Vector<Spans>, c: &mut Cache, m: u32, off: u32) u32 {
    if c.m == m && c.leaf && off >= c.s && off < c.e {
        return c.item;
    }
    let sp = sps.at(m as usize);
    c.m = m;
    let k = span_find(&sp.mem_s, &sp.mem_e, off);
    if k != NONE {
        c.item = sp.mem_id[k as usize];
        c.s = sp.mem_s[k as usize];
        c.e = sp.mem_e[k as usize];
        c.leaf = true;
        return c.item;
    }
    let t = span_find(&sp.top_s, &sp.top_e, off);
    if t != NONE {
        c.item = sp.top_id[t as usize];
        c.s = sp.top_s[t as usize];
        c.e = sp.top_e[t as usize];
        c.leaf = p.idx.items.at(c.item as usize).kind != loader::ItemKind::IK_EXTEND as u8;
        return c.item;
    }
    c.item = NONE;
    c.leaf = false;
    return NONE;
}

/// The dependency edges of module `m`'s items read from its resolution tables: one
/// `owner << 32 | target` per resolved reference whose target item differs from the owner
/// (consecutive duplicates dropped; the CSR layout deduplicates the rest), plus one ownership
/// edge per associated item to its extend. Pure over the module's frozen tables, the index and
/// the other modules' declaration spans, so the resolve frontier runs it per task.
///
/// Owners come from id ranges: a parse-time item's nodes are contiguous in each arena and end
/// at the item's node (post-order), the header of an extend precedes its first member, and a
/// function's body is the run ending at its block; a node past every range (a desugar appended
/// later) falls back to the declaration spans. A reference to a declaration inside the owner's
/// own ranges (a local, a parameter) is no edge and needs no lookup.
pub fn module_edges(p: &loader::Package, m: usize, sps: &Vector<Spans>, out: &mut Vector<u64>) {
    if !p.modules.at(m).has_ast {
        return;
    }
    let a = &p.modules.at(m).ast;
    let i0 = p.idx.mod_items[m] as usize;
    let i1 = p.idx.mod_items[m + 1] as usize;
    let nl = i1 - i0;
    for i in i0..i1 {
        let ow = p.idx.items.at(i).owner;
        if ow != loader::ITEM_NONE {
            out.push(i as u64 << 32 | ow as u64);
        }
    }
    // Module-arena ranges (rs, re] -> owner, ascending; the per-item own range for the self test.
    let mut rs = Vector::<u32>::new();
    let mut re = Vector::<u32>::new();
    let mut ro = Vector::<u32>::new();
    let mut mstart = Vector::<u32>::new();
    mstart.resize_default(nl);
    let mut mend = Vector::<u32>::new();
    mend.resize_default(nl);
    let mut opened = Vector::<bool>::new();
    opened.resize_default(nl);
    let mut prev: u32 = 0;
    for k in i0..i1 {
        let it = p.sched.by_node[k];
        let meta = *p.idx.items.at(it as usize);
        if meta.owner != loader::ITEM_NONE && !opened[(meta.owner - i0 as u32) as usize] {
            // The extend's header (generics, target, interface) precedes its first member.
            let ed = a.at_const(p.idx.items.at(meta.owner as usize).node).as_data.extend_def;
            let mut he = ed.target_type;
            if ed.interface_type != NODE_NONE && ed.interface_type > he {
                he = ed.interface_type;
            }
            for g in 0..ed.generics.len {
                let gn = unsafe a.list(ed.generics)[g as usize];
                if gn > he {
                    he = gn;
                }
            }
            rs.push(prev);
            re.push(he);
            ro.push(meta.owner);
            mstart.set((meta.owner - i0 as u32) as usize, prev);
            mend.set((meta.owner - i0 as u32) as usize, he);
            opened.set((meta.owner - i0 as u32) as usize, true);
            prev = he;
        }
        rs.push(prev);
        re.push(meta.node);
        ro.push(it);
        if meta.owner == loader::ITEM_NONE && !opened[(it - i0 as u32) as usize] {
            mstart.set((it - i0 as u32) as usize, prev);
            mend.set((it - i0 as u32) as usize, meta.node);
        }
        prev = meta.node;
    }
    // Body-arena ranges: each function's body run, in node order.
    let mut bs = Vector::<u32>::new();
    let mut be = Vector::<u32>::new();
    let mut bo = Vector::<u32>::new();
    let mut bstart = Vector::<u32>::new();
    bstart.resize_default(nl);
    let mut bend = Vector::<u32>::new();
    bend.resize_default(nl);
    prev = 0;
    for k in i0..i1 {
        let it = p.sched.by_node[k];
        let meta = *p.idx.items.at(it as usize);
        let nd = a.at_const(meta.node);
        if nd.kind == NodeKind::NODE_FUNCTION && Ast::in_body(nd.as_data.function.body) {
            let end = nd.as_data.function.body & NODE_BODY_MASK;
            bs.push(prev);
            be.push(end);
            bo.push(it);
            bstart.set((it - i0 as u32) as usize, prev);
            bend.set((it - i0 as u32) as usize, end);
            prev = end;
        }
    }
    let first_span = if rs.len() != 0 {
        a.at_const(p.idx.items.at(ro[0] as usize).node).span.start;
    } else {
        0u32;
    };
    let mut oc = cache_none();
    let mut tc = cache_none();
    // Targets repeat (a hot callee, a field owner): a direct-mapped memo over (module, node).
    let mut tk = Vector::<u64>::new();
    tk.resize_default(TMEMO);
    let mut tv = Vector::<u32>::new();
    tv.resize_default(TMEMO);
    for i in 0..TMEMO {
        tk.set(i, 0xFFFFFFFFFFFFFFFFu64);
    }
    let mut last: u64 = 0;
    for pass in 0..2 {
        let body = pass == 1;
        let sv = if body {
            &a.b.resolutions;
        } else {
            &a.resolutions;
        };
        let nv = if body {
            &a.b.nodes;
        } else {
            &a.nodes;
        };
        let rng_s = if body {
            &bs;
        } else {
            &rs;
        };
        let rng_e = if body {
            &be;
        } else {
            &re;
        };
        let rng_o = if body {
            &bo;
        } else {
            &ro;
        };
        let nr = rng_e.len();
        let mut r: usize = 0;
        let n = sv.len();
        let nb = sv.base_len();
        for x in 1..n {
            let d = if x < nb {
                unsafe *(sv.base_ptr() + x);
            } else {
                unsafe *sv.ptr_at(x);
            };
            if d.node == NODE_NONE {
                continue;
            }
            for _ in r..nr {
                if x as u32 > rng_e[r] {
                    r += 1;
                } else {
                    break;
                }
            }
            let mut owner = NONE;
            if r < nr && x as u32 > rng_s[r] {
                owner = rng_o[r];
                if !body && r == 0 && (unsafe &*nv.ptr_at(x)).span.start < first_span {
                    continue; // an import path, before the first item
                }
            } else {
                // Past every parse-time range: a desugar; its span names the item it extends.
                owner = owner_at(p, sps, &mut oc, m as u32, (unsafe &*nv.ptr_at(x)).span.start);
                if owner == NONE {
                    continue;
                }
            }
            let ol = (owner - i0 as u32) as usize;
            if d.module as usize == m && owner >= i0 as u32 && ol < nl {
                // Declared inside the owner's own ranges: a local, a parameter, a generic.
                let tn = d.node & NODE_BODY_MASK;
                if Ast::in_body(d.node) {
                    if tn > bstart[ol] && tn <= bend[ol] {
                        continue;
                    }
                } else if tn > mstart[ol] && tn <= mend[ol] {
                    continue;
                }
            }
            let dkey = d.module as u64 << 32 | d.node as u64;
            let slot = (dkey * 0x9E3779B97F4A7C15u64 >> 54) as usize;
            let target = if tk[slot] == dkey {
                tv[slot];
            } else {
                // A declaration that is an item answers from the lookup; a nested one (a field,
                // a variant, a foreign local) from the declaration spans of its module.
                let mut t = p.item_of(d.module, d.node);
                if t == loader::ITEM_NONE {
                    let dm = d.module as usize;
                    t = owner_at(p, sps, &mut tc, d.module, p.modules.at(dm).ast.at_const(d.node).span.start);
                }
                tk.set(slot, dkey);
                tv.set(slot, t);
                t;
            };
            if target == NONE || target == owner {
                continue;
            }
            let e = owner as u64 << 32 | target as u64;
            if e != last {
                out.push(e);
                last = e;
            }
        }
    }
}

// Lay `edges` out as CSR ranges over `n` owners, targets ascending and deduplicated: a counting
// sort by owner, then an insertion sort of each owner's few targets.
fn csr(n: usize, edges: &Vector<u64>, off: &mut Vector<u32>, tgt: &mut Vector<u32>) {
    off.clear();
    off.resize_default(n + 1);
    for i in 0..edges.len() {
        let o = (edges[i] >> 32) as usize;
        off.set(o + 1, off[o + 1] + 1);
    }
    for i in 0..n {
        off.set(i + 1, off[i + 1] + off[i]);
    }
    let mut fill = Vector::<u32>::new();
    fill.resize_default(n);
    tgt.clear();
    tgt.resize_default(edges.len());
    for i in 0..edges.len() {
        let o = (edges[i] >> 32) as usize;
        tgt.set((off[o] + fill[o]) as usize, (edges[i] & 0xFFFFFFFFu64) as u32);
        fill.set(o, fill[o] + 1);
    }
    let mut w: usize = 0;
    let mut nout = Vector::<u32>::new();
    nout.resize_default(n + 1);
    for o in 0..n {
        let s = off[o] as usize;
        let e = off[o + 1] as usize;
        for i in s + 1..e {
            let v = tgt[i];
            let mut j = i;
            while j > s && tgt[j - 1] > v {
                tgt.set(j, tgt[j - 1]);
                j -= 1;
            }
            tgt.set(j, v);
        }
        nout.set(o, w as u32);
        for i in s..e {
            if i == s || tgt[i] != tgt[i - 1] {
                tgt.set(w, tgt[i]);
                w += 1;
            }
        }
    }
    nout.set(n, w as u32);
    tgt.truncate(w);
    *off = nout;
}

/// Open the index after the package index exists: keys and the (module, node) lookup, which
/// `module_edges` reads. `build` completes it.
pub fn open(p: &mut loader::Package) {
    p.ensure_index();
    let n = p.idx.items.len();
    let nm = p.modules.len();
    let mut sch = loader::ItemSched::new();
    // Stable keys: the module path, the top-level ordinal, the member ordinal (0 at top level).
    sch.key.reserve(n);
    for m in 0..nm {
        let mh = hash_bytes(FNV_OFF, p.modules.at(m).path.as_str());
        let mut top: u64 = 0;
        let mut mem: u64 = 0;
        for i in p.idx.mod_items[m] as usize..p.idx.mod_items[m + 1] as usize {
            if p.idx.items.at(i).owner == loader::ITEM_NONE {
                top += 1;
                mem = 0;
                sch.key.push(mix(mix(mh, top), 0));
            } else {
                mem += 1;
                sch.key.push(mix(mix(mh, top), mem));
            }
        }
    }
    // The lookup: each module's items ordered by declaration node.
    sch.by_node.reserve(n);
    for m in 0..nm {
        let i0 = p.idx.mod_items[m] as usize;
        let i1 = p.idx.mod_items[m + 1] as usize;
        let base = sch.by_node.len();
        for i in i0..i1 {
            sch.by_node.push(i as u32);
        }
        // Insertion sort: an extend's record precedes its members but its node follows them.
        for i in base + 1..sch.by_node.len() {
            let v = sch.by_node[i];
            let vn = p.idx.items.at(v as usize).node;
            let mut j = i;
            while j > base && p.idx.items.at(sch.by_node[j - 1] as usize).node > vn {
                sch.by_node.set(j, sch.by_node[j - 1]);
                j -= 1;
            }
            sch.by_node.set(j, v);
        }
    }
    sch.state.resize_default(n);
    sch.ret_attr.resize_default(n);
    for i in 0..n {
        sch.state.set(i, loader::IS_RESOLVED);
        sch.ret_attr.set(i, 2); // unrecorded: the borrow pass scans the body
    }
    sch.sig_hash.resize_default(n);
    sch.fin_off.resize_default(n + 1);
    sch.built = true;
    p.sched = sch;
}

/// Complete the index after resolution with the precheck ranges from `edges` (every module's
/// `module_edges`, any order) and their components.
pub fn build(p: &mut loader::Package, edges: &Vector<u64>) {
    let t0 = plat::now_ns();
    let n = p.idx.items.len();
    let mut off = Vector::<u32>::new();
    let mut tgt = Vector::<u32>::new();
    csr(n, edges, &mut off, &mut tgt);
    let mut comp = Vector::<u32>::new();
    let ncomp = condense(n, &off, &tgt, &mut comp) as u32;
    p.sched.pre_off = off;
    p.sched.pre_edges = tgt;
    p.sched.comp = comp;
    p.sched.ncomp = ncomp;
    p.sched.build_ns = plat::now_ns() - t0;
}

/// The serial path: open, every module's edges in module order, build.
pub fn build_serial(p: &mut loader::Package) {
    let t0 = plat::now_ns();
    open(p);
    let t1 = plat::now_ns();
    let sps = spans_all(p);
    let t2 = plat::now_ns();
    let mut edges = Vector::<u64>::new();
    for m in 0..p.modules.len() {
        module_edges(p, m, &sps, &mut edges);
    }
    let t3 = plat::now_ns();
    build(p, &edges);
    if p.icost_on {
        eprint(
            "item-stats build steps: open {} ms, spans {} ms, scan {} ms ({} raw edges), csr+scc {} ms\n",
            ms(t1 - t0),
            ms(t2 - t1),
            ms(t3 - t2),
            edges.len(),
            ms(plat::now_ns() - t3),
        );
    }
    p.sched.build_ns = plat::now_ns() - t0;
}

/// Every module's declaration spans (the frontier builds them once, before its tasks).
pub fn spans_all(p: &loader::Package) Vector<Spans> {
    let mut sps = Vector::<Spans>::new();
    for m in 0..p.modules.len() {
        sps.push(spans_of(p, m));
    }
    return sps;
}

/// Refine the index after the checks: signature hashes and the final dependency ranges (the
/// resolutions typecheck added, the engine's dynamic body edges), then publish the dynamic
/// edge set empty. Batch builds only.
pub fn finalize(p: &mut loader::Package) {
    if !p.sched.built || p.sched.finalized {
        return;
    }
    p.sched.finalized = true;
    let t0 = plat::now_ns();
    let n = p.idx.items.len();
    let sps = spans_all(p);
    let mut edges = Vector::<u64>::new();
    for m in 0..p.modules.len() {
        module_edges(p, m, &sps, &mut edges);
    }
    for e in p.sched.dyn_edges.iter() {
        edges.push(*e);
    }
    let mut off = Vector::<u32>::new();
    let mut tgt = Vector::<u32>::new();
    csr(n, &edges, &mut off, &mut tgt);
    p.sched.fin_off = off;
    p.sched.fin_edges = tgt;
    p.sched.dyn_edges = Set::<u64>::new();
    let t1 = plat::now_ns();
    p.ensure_sigs();
    let mut hashes = Vector::<u64>::new();
    hashes.resize_default(n);
    let mut c = cache_none();
    for i in 0..n {
        hashes.set(i, sig_hash(p, &sps, &mut c, i));
    }
    p.sched.sig_hash = hashes;
    p.sched.final_ns = t1 - t0;
    p.sched.hash_ns = plat::now_ns() - t1;
}

// The signature hash of item `i`: its key, kind, visibility and attributes, then the semantic
// signature by kind (parameter and return types, generics and bounds, the owner's target and
// interface, fields and variants, the aliased or constant type). Types hash structurally with
// nominal declarations spelled as item keys, so neither node ids nor type numbering enter.
fn sig_hash(p: &loader::Package, sps: &Vector<Spans>, c: &mut Cache, i: usize) u64 {
    let it = *p.idx.items.at(i);
    let m = it.module as usize;
    let a = &p.modules.at(m).ast;
    let mut h = mix(
        mix(p.sched.key[i], it.kind),
        if it.is_public {
            1u64;
        } else {
            0u64;
        },
    );
    for k in 0..a.attrs.len() {
        let at = a.attrs.at(k);
        if at.owner == it.node {
            h = mix(mix(h, at.kind), at.arg);
        }
    }
    if !a.valid(it.node) {
        return h;
    }
    let nd = a.at_const(it.node);
    if nd.kind == NodeKind::NODE_FUNCTION {
        let fd = nd.as_data.function;
        h = mix(
            h,
            if fd.is_extern {
                1u64;
            } else {
                0u64;
            } | if fd.is_variadic {
                2u64;
            } else {
                0u64;
            } | if fd.is_const {
                4u64;
            } else {
                0u64;
            } | if fd.is_unsafe {
                8u64;
            } else {
                0u64;
            },
        );
        h = mix(h, fd.generics.len);
        for g in 0..fd.generics.len {
            h = node_hash(p, sps, c, m, unsafe a.list(fd.generics)[g as usize], h, 0);
        }
        for w in 0..fd.where_clause.len {
            h = node_hash(p, sps, c, m, unsafe a.list(fd.where_clause)[w as usize], h, 0);
        }
        let sig = p.item_sig(it.module, it.node);
        if sig != null {
            let s = unsafe *sig;
            h = mix(mix(h, s.np), s.nr);
            for k in 0..s.np as u32 + s.nr as u32 {
                h = ty_hash(p, sps, c, it.module, p.sig_type(s.start + k), h, 0);
            }
        }
        if it.owner != loader::ITEM_NONE {
            h = mix(h, p.sched.key[it.owner as usize]);
        }
    } else if nd.kind == NodeKind::NODE_STRUCT || nd.kind == NodeKind::NODE_ENUM {
        let ag = nd.as_data.aggregate;
        h = mix(h, ag.members.len);
        for k in 0..ag.members.len {
            let mem = unsafe a.list(ag.members)[k as usize];
            h = ty_hash(p, sps, c, it.module, a.type_of(mem), h, 0);
        }
    } else if nd.kind == NodeKind::NODE_EXTEND {
        let ed = nd.as_data.extend_def;
        h = node_hash(p, sps, c, m, ed.target_type, h, 0);
        h = node_hash(p, sps, c, m, ed.interface_type, h, 0);
    } else if nd.kind == NodeKind::NODE_INTERFACE {
        // The method requirements: each member's parameter and return types.
        let idf = nd.as_data.interface_def;
        h = mix(h, idf.items.len);
        for k in 0..idf.items.len {
            let mem = unsafe a.list(idf.items)[k as usize];
            let mn = a.at_const(mem);
            if mn.kind != NodeKind::NODE_FUNCTION {
                h = ty_hash(p, sps, c, it.module, a.type_of(mem), h, 0);
                continue;
            }
            let fd = mn.as_data.function;
            for q in 0..fd.params.len {
                h = ty_hash(p, sps, c, it.module, a.type_of(unsafe a.list(fd.params)[q as usize]), h, 0);
            }
            for q in 0..fd.returns.len {
                h = ty_hash(p, sps, c, it.module, a.type_of(unsafe a.list(fd.returns)[q as usize]), h, 0);
            }
        }
    } else {
        // Constants, aliases, interfaces: the declaration's own type.
        h = ty_hash(p, sps, c, it.module, a.type_of(it.node), h, 0);
    }
    return h;
}

// Hash the resolution and type of node `id` (a generic parameter, a bound, a type annotation).
fn node_hash(p: &loader::Package, sps: &Vector<Spans>, c: &mut Cache, m: usize, id: NodeId, mut h: u64, depth: u32) u64 {
    if id == NODE_NONE {
        return mix(h, 0);
    }
    let a = &p.modules.at(m).ast;
    if !a.valid(id) {
        return h;
    }
    let d = a.resolution_def(id);
    if d.node != NODE_NONE {
        h = mix(h, decl_key(p, sps, c, d.module as usize, d.node));
    }
    return ty_hash(p, sps, c, m as ModuleId, a.type_of(id), h, depth);
}

// The stable identity of declaration node `node` of module `m`: its item key, or for a nested
// declaration (a generic parameter, a local) the owning item's key with the node's offset inside
// that item's text.
fn decl_key(p: &loader::Package, sps: &Vector<Spans>, c: &mut Cache, m: usize, node: NodeId) u64 {
    let it = p.item_of(m as ModuleId, node);
    if it != loader::ITEM_NONE {
        return p.sched.key[it as usize];
    }
    let a = &p.modules.at(m).ast;
    if !a.valid(node) {
        return 0;
    }
    let s = a.at_const(node).span.start;
    let ow = owner_at(p, sps, c, m as u32, s);
    if ow == NONE {
        return mix(hash_bytes(FNV_OFF, p.modules.at(m).path.as_str()), s);
    }
    return mix(p.sched.key[ow as usize], s - c.s);
}

// Structural type hash: kind, qualifier, then the payload by kind; nominal types through
// `decl_key`, instances through their base and arguments, arrays with their length.
fn ty_hash(p: &loader::Package, sps: &Vector<Spans>, c: &mut Cache, m: ModuleId, t: TypeId, mut h: u64, depth: u32) u64 {
    if t == TYPE_NONE || depth > 32 {
        return mix(h, 0xFF);
    }
    let a = &p.modules.at(m as usize).ast;
    let ty = *a.type_at(t);
    let k = ty.kind;
    h = mix(mix(h, k as u64), ty.qualifier);
    if k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_SLICE {
        return ty_hash(p, sps, c, m, ty.as_data.elem, h, depth + 1);
    }
    if k == TypeKind::TYPE_ARRAY {
        return ty_hash(p, sps, c, m, ty.as_data.arr.elem, mix(h, ty.as_data.arr.len), depth + 1);
    }
    if k == TypeKind::TYPE_INSTANCE || k == TypeKind::TYPE_DYN {
        let inst = *a.instance(ty.as_data.inst);
        h = mix(h, decl_key(p, sps, c, inst.module as usize, inst.decl));
        for i in 0..inst.n {
            h = ty_hash(p, sps, c, m, unsafe inst.args[i as usize], h, depth + 1);
        }
        return h;
    }
    if k == TypeKind::TYPE_BUILTIN {
        return mix(h, ty.as_data.builtin as u64);
    }
    if k == TypeKind::TYPE_CONST {
        return mix(h, ty.as_data.value as u64);
    }
    if k == TypeKind::TYPE_FIELD_PROJECTION {
        return ty_hash(
            p,
            sps,
            c,
            m,
            ty.as_data.proj.owner,
            mix(h, decl_key(p, sps, c, ty.module as usize, ty.as_data.proj.binder)),
            depth + 1,
        );
    }
    if k == TypeKind::TYPE_STRUCT || k == TypeKind::TYPE_ENUM || k == TypeKind::TYPE_OPAQUE || k == TypeKind::TYPE_GENERIC || k == TypeKind::TYPE_FUNCTION || k == TypeKind::TYPE_CONST_EXPR {
        return mix(h, decl_key(p, sps, c, ty.module as usize, ty.as_data.decl));
    }
    return h;
}

// Tarjan's algorithm, iterative, over the CSR graph: `comp[i]` is the component of item `i`,
// components numbered after every component they reference (dependency-first).
fn condense(n: usize, off: &Vector<u32>, tgt: &Vector<u32>, comp: &mut Vector<u32>) usize {
    let mut index = Vector::<u32>::new();
    index.resize_default(n);
    let mut low = Vector::<u32>::new();
    low.resize_default(n);
    let mut on = Vector::<bool>::new();
    on.resize_default(n);
    comp.clear();
    comp.resize_default(n);
    let mut stack = Vector::<u32>::new();
    let mut work = Vector::<u32>::new(); // (node, next edge) pairs
    let mut next: u32 = 1;
    let mut ncomp: usize = 0;
    for root in 0..n {
        if index[root] != 0 {
            continue;
        }
        work.push(root as u32);
        work.push(off[root]);
        index.set(root, next);
        low.set(root, next);
        next += 1;
        stack.push(root as u32);
        on.set(root, true);
        for _ in 0..2 * tgt.len() + 2 * n + 2 {
            if work.len() == 0 {
                break;
            }
            let v = work[work.len() - 2] as usize;
            let e = work[work.len() - 1];
            if e < off[v + 1] {
                work.set(work.len() - 1, e + 1);
                let wv = tgt[e as usize] as usize;
                if index[wv] == 0 {
                    index.set(wv, next);
                    low.set(wv, next);
                    next += 1;
                    stack.push(wv as u32);
                    on.set(wv, true);
                    work.push(wv as u32);
                    work.push(off[wv]);
                } else if on[wv] && index[wv] < low[v] {
                    low.set(v, index[wv]);
                }
                continue;
            }
            if low[v] == index[v] {
                for _ in 0..stack.len() {
                    let x = stack[stack.len() - 1] as usize;
                    stack.truncate(stack.len() - 1);
                    on.set(x, false);
                    comp.set(x, ncomp as u32);
                    if x == v {
                        break;
                    }
                }
                ncomp += 1;
            }
            work.truncate(work.len() - 2);
            if work.len() != 0 {
                let u = work[work.len() - 2] as usize;
                if low[v] < low[u] {
                    low.set(u, low[v]);
                }
            }
        }
    }
    return ncomp;
}

/// A digest of the index (keys, hashes, precheck and final edges, components, states) for the
/// serial/parallel identity gate.
pub fn digest(p: &loader::Package) u64 {
    let s = &p.sched;
    let mut h = FNV_OFF;
    for i in 0..s.key.len() {
        h = mix(mix(mix(mix(h, s.key[i]), s.sig_hash[i]), s.comp[i]), s.state[i]);
    }
    for i in 0..s.pre_edges.len() {
        h = mix(h, s.pre_edges[i]);
    }
    for i in 0..s.fin_edges.len() {
        h = mix(h, s.fin_edges[i]);
    }
    return mix(mix(h, s.pre_edges.len() as u64), s.fin_edges.len() as u64);
}

/// Add `ns` to module `m`'s per-module cost row `k` (0 = emission seed, 1 = always-panics).
pub fn mod_cost(p: &mut loader::Package, m: usize, k: usize, ns: u64) {
    let want = 2 * p.modules.len();
    while p.icost_mod.len() < want {
        p.icost_mod.push(0);
    }
    p.icost_mod.set(2 * m + k, p.icost_mod[2 * m + k] + ns);
}

// A list schedule of `n` jobs over `p` workers: the earliest-free worker takes the earliest-ready
// job (a job is ready once every dependency finished), first-come order among ties. `cost` is
// per job; `dep_off`/`deps` the CSR dependency lists. Returns the makespan.
fn makespan(n: usize, p: usize, cost: &Vector<u64>, dep_off: &Vector<u32>, deps: &Vector<u32>, task_ns: u64) u64 {
    let mut w = Width { max: 0, sum: 0, picks: 0 };
    return makespan_w(n, p, cost, dep_off, deps, task_ns, &mut w);
}

/// The ready-job width a schedule saw: the largest and the average count of ready jobs at the
/// moments a worker picked one.
pub struct Width {
    pub max: u64,
    pub sum: u64,
    pub picks: u64,
}

fn makespan_w(
    n: usize,
    p: usize,
    cost: &Vector<u64>,
    dep_off: &Vector<u32>,
    deps: &Vector<u32>,
    task_ns: u64,
    wd: &mut Width,
) u64 {
    // Dependents (reverse CSR) and the pending-dependency counts.
    let mut rev_off = Vector::<u32>::new();
    rev_off.resize_default(n + 1);
    for j in 0..n {
        for k in dep_off[j] as usize..dep_off[j + 1] as usize {
            let d = deps[k] as usize;
            rev_off.set(d + 1, rev_off[d + 1] + 1);
        }
    }
    for j in 0..n {
        rev_off.set(j + 1, rev_off[j + 1] + rev_off[j]);
    }
    let mut rev = Vector::<u32>::new();
    rev.resize_default(rev_off[n] as usize);
    let mut fill = Vector::<u32>::new();
    fill.resize_default(n);
    let mut pending = Vector::<u32>::new();
    pending.resize_default(n);
    for j in 0..n {
        pending.set(j, dep_off[j + 1] - dep_off[j]);
        for k in dep_off[j] as usize..dep_off[j + 1] as usize {
            let d = deps[k] as usize;
            rev.set((rev_off[d] + fill[d]) as usize, j as u32);
            fill.set(d, fill[d] + 1);
        }
    }
    // The ready heap (time << 20 | job): min by ready time, then job id.
    let mut heap = Vector::<u64>::new();
    for j in 0..n {
        if pending[j] == 0 {
            heap_push(&mut heap, j as u64);
        }
    }
    let mut free = Vector::<u64>::new();
    free.resize_default(p);
    let mut end: u64 = 0;
    for _ in 0..n {
        if heap.len() == 0 {
            break;
        }
        if heap.len() as u64 > wd.max {
            wd.max = heap.len() as u64;
        }
        wd.sum += heap.len() as u64;
        wd.picks += 1;
        let e = heap_pop(&mut heap);
        let j = (e & 0xFFFFFu64) as usize;
        let ready = e >> 20;
        let mut w: usize = 0;
        for x in 1..p {
            if free[x] < free[w] {
                w = x;
            }
        }
        let start = if ready > free[w] {
            ready;
        } else {
            free[w];
        };
        let f = start + cost[j] + task_ns;
        free.set(w, f);
        if f > end {
            end = f;
        }
        for k in rev_off[j] as usize..rev_off[j + 1] as usize {
            let d = rev[k] as usize;
            pending.set(d, pending[d] - 1);
            if pending[d] == 0 {
                heap_push(&mut heap, f << 20 | d as u64);
            }
        }
    }
    return end;
}

fn heap_push(h: &mut Vector<u64>, v: u64) {
    h.push(v);
    let mut i = h.len() - 1;
    while i > 0 && h[(i - 1) / 2] > h[i] {
        let t = h[(i - 1) / 2];
        h.set((i - 1) / 2, h[i]);
        h.set(i, t);
        i = (i - 1) / 2;
    }
}

fn heap_pop(h: &mut Vector<u64>) u64 {
    let top = h[0];
    let last = h[h.len() - 1];
    h.truncate(h.len() - 1);
    if h.len() == 0 {
        return top;
    }
    h.set(0, last);
    let mut i: usize = 0;
    for _ in 0..h.len() {
        let l = 2 * i + 1;
        let r = l + 1;
        let mut s = i;
        if l < h.len() && h[l] < h[s] {
            s = l;
        }
        if r < h.len() && h[r] < h[s] {
            s = r;
        }
        if s == i {
            break;
        }
        let t = h[s];
        h.set(s, h[i]);
        h.set(i, t);
        i = s;
    }
    return top;
}

fn ms(ns: u64) f64 {
    return ns as f64 / 1000000.0;
}

/// SC_ITEM_STATS: the measurement behind the index's decision gate. The graph, the typecheck
/// schedule prediction over the measured per-item costs, the dynamic evaluation edges and the
/// per-body and per-module frontier balances. `task_ns` is the measured cost of one runtime task.
pub fn report(p: &mut loader::Package, task_ns: u64) {
    finalize(p);
    let s = &p.sched;
    let n = p.idx.items.len();
    let nm = p.modules.len();
    // Per-item typecheck cost.
    let mut icost = Vector::<u64>::new();
    icost.resize_default(n);
    let mut tc_sum: u64 = 0;
    let mut mcost = Vector::<u64>::new();
    mcost.resize_default(nm);
    let mut k: usize = 0;
    while k + 1 < p.icost_tc.len() {
        let key = p.icost_tc[k];
        let ns = p.icost_tc[k + 1];
        k += 2;
        let m = (key >> 32) as usize;
        tc_sum += ns;
        mcost.set(m, mcost[m] + ns);
        let it = p.item_of(m as ModuleId, (key & 0xFFFFFFFFu64) as NodeId);
        if it != loader::ITEM_NONE {
            icost.set(it as usize, icost[it as usize] + ns);
        }
    }
    // Component costs and dependency lists (edges to lower components).
    let nc = s.ncomp as usize;
    let mut ccost = Vector::<u64>::new();
    ccost.resize_default(nc);
    let mut csize = Vector::<u32>::new();
    csize.resize_default(nc);
    for i in 0..n {
        let c = s.comp[i] as usize;
        ccost.set(c, ccost[c] + icost[i]);
        csize.set(c, csize[c] + 1);
    }
    let mut cedges = Vector::<u64>::new();
    for i in 0..n {
        for e in s.pre_off[i] as usize..s.pre_off[i + 1] as usize {
            let a = s.comp[i];
            let b = s.comp[s.pre_edges[e] as usize];
            if a != b {
                cedges.push(a as u64 << 32 | b as u64);
            }
        }
    }
    let mut dep_off = Vector::<u32>::new();
    let mut deps = Vector::<u32>::new();
    csr(nc, &cedges, &mut dep_off, &mut deps);
    let mut longest = Vector::<u64>::new();
    longest.resize_default(nc);
    let mut crit: u64 = 0;
    let mut biggest: usize = 0;
    for c in 0..nc {
        let mut best: u64 = 0;
        for k2 in dep_off[c] as usize..dep_off[c + 1] as usize {
            if longest[deps[k2] as usize] > best {
                best = longest[deps[k2] as usize];
            }
        }
        longest.set(c, best + ccost[c]);
        if longest[c] > crit {
            crit = longest[c];
        }
        if csize[c] > csize[biggest] {
            biggest = c;
        }
    }
    let mod_ns = module_schedule_ns(p, &mcost);
    let mut prelude_ns: u64 = 0;
    let mut maxm: usize = 0;
    for m in 0..nm {
        if p.modules.at(m).prelude {
            prelude_ns += mcost[m];
        }
        if mcost[m] > mcost[maxm] {
            maxm = m;
        }
    }
    let mut maxi: usize = 0;
    for i in 0..n {
        if icost[i] > icost[maxi] {
            maxi = i;
        }
    }
    eprint(
        "item-stats graph: {} items, {} precheck edges, {} final edges, {} components (largest {}), built in {} ms, finalized in {} + {} ms, {} KiB, digest {}\n",
        n,
        s.pre_edges.len(),
        s.fin_edges.len(),
        nc,
        csize[biggest],
        ms(s.build_ns),
        ms(s.final_ns),
        ms(s.hash_ns),
        s.retained() / 1024,
        digest(p),
    );
    eprint(
        "item-stats typecheck: serial {} ms, item critical path {} ms, module levels {} ms; prelude group {} ms, largest module {} ms ({}), largest item {} ms ({} node {})\n",
        ms(tc_sum),
        ms(crit),
        ms(mod_ns),
        ms(prelude_ns),
        ms(mcost[maxm]),
        p.modules.at(maxm).path.as_str(),
        ms(icost[maxi]),
        p.modules.at(p.idx.items.at(maxi).module as usize).path.as_str(),
        p.idx.items.at(maxi).node,
    );
    eprint(
        "item-stats typecheck item schedule with {} ns per task ({} ms of task overhead over {} jobs):",
        task_ns,
        ms(task_ns * nc as u64),
        nc,
    );
    let mut ps = Vector::<usize>::new();
    ps.push(1);
    ps.push(2);
    ps.push(4);
    ps.push(8);
    ps.push(14);
    for i in 0..ps.len() {
        let mut wd = Width { max: 0, sum: 0, picks: 0 };
        let mk = makespan_w(nc, ps[i], &ccost, &dep_off, &deps, task_ns, &mut wd);
        eprint(
            " p{}={} ms (ready width max {}, mean {})",
            ps[i],
            ms(mk),
            wd.max,
            wd.sum / if wd.picks == 0 {
                1u64;
            } else {
                wd.picks;
            },
        );
    }
    eprint("\n");
    frontier_line(p, "resolve (per item)", &p.icost_rs, task_ns);
    let mut dn: usize = 0;
    let mut dx: usize = 0;
    let mut k3: usize = 0;
    while k3 + 1 < p.ctfe_edges.len() {
        dn += 1;
        if p.ctfe_edges[k3] >> 32 != p.ctfe_edges[k3 + 1] >> 32 {
            dx += 1;
        }
        k3 += 2;
    }
    eprint("item-stats evaluation: {} bodies lowered from syntax during typecheck ({} cross-module)\n", dn, dx);
    frontier_line(p, "lowering (per body)", &p.icost_lw, task_ns);
    frontier_line(p, "borrowck (per body)", &p.icost_bc, task_ns);
    let mut seed = Vector::<u64>::new();
    let mut panics = Vector::<u64>::new();
    for m in 0..nm {
        if 2 * m + 1 < p.icost_mod.len() {
            seed.push(m as u64 << 32);
            seed.push(p.icost_mod[2 * m]);
            panics.push(m as u64 << 32);
            panics.push(p.icost_mod[2 * m + 1]);
        }
    }
    frontier_line(p, "panics (per module only)", &panics, task_ns);
    frontier_line(p, "emission seed (per module only)", &seed, task_ns);
}

// One frontier's balance: the serial sum, the largest unit, the largest module, and the
// makespans of independent jobs by module and by unit at 14 workers.
fn frontier_line(p: &loader::Package, what: str, rec: &Vector<u64>, task_ns: u64) {
    let nm = p.modules.len();
    let mut per_mod = Vector::<u64>::new();
    per_mod.resize_default(nm);
    let mut units = Vector::<u64>::new();
    let mut sum: u64 = 0;
    let mut maxu: u64 = 0;
    let mut k: usize = 0;
    while k + 1 < rec.len() {
        let m = (rec[k] >> 32) as usize;
        let ns = rec[k + 1];
        k += 2;
        sum += ns;
        per_mod.set(m, per_mod[m] + ns);
        units.push(ns);
        if ns > maxu {
            maxu = ns;
        }
    }
    let mut maxm: u64 = 0;
    let mut maxi: usize = 0;
    for m in 0..nm {
        if per_mod[m] > maxm {
            maxm = per_mod[m];
            maxi = m;
        }
    }
    let empty = Vector::<u32>::new();
    let mut off0 = Vector::<u32>::new();
    off0.resize_default(nm + 1);
    sort_longest_first(&mut per_mod);
    let by_mod = makespan(nm, 14, &per_mod, &off0, &empty, task_ns);
    let mut offu = Vector::<u32>::new();
    offu.resize_default(units.len() + 1);
    sort_longest_first(&mut units);
    let by_unit = makespan(units.len(), 14, &units, &offu, &empty, task_ns);
    eprint(
        "item-stats {}: {} units, serial {} ms, largest unit {} ms, largest module {} ms ({}); 14 workers by module {} ms, by unit {} ms\n",
        what,
        units.len(),
        ms(sum),
        ms(maxu),
        ms(maxm),
        p.modules.at(maxi).path.as_str(),
        ms(by_mod),
        ms(by_unit),
    );
}

// Longest-job-first order for the independent-job schedules.
fn sort_longest_first(v: &mut Vector<u64>) {
    v.sort();
    let n = v.len();
    for i in 0..n / 2 {
        let a = v[i];
        v.set(i, v[n - 1 - i]);
        v.set(n - 1 - i, a);
    }
}

// The typecheck frontier's schedule over the measured module costs: import-SCC levels, the
// prelude one sequential group at level 0, every non-prelude level after the prelude's; a level
// takes its slowest group.
fn module_schedule_ns(p: &loader::Package, mcost: &Vector<u64>) u64 {
    let n = p.modules.len();
    let mut nscc: u32 = 0;
    for i in 0..n {
        if p.idx.scc_of[i] + 1 > nscc {
            nscc = p.idx.scc_of[i] + 1;
        }
    }
    let mut lvl = Vector::<u32>::new();
    lvl.resize_default(nscc as usize);
    let mut changed = true;
    for _ in 0..nscc + 2 {
        if !changed {
            break;
        }
        changed = false;
        for i in 0..n {
            let si = p.idx.scc_of[i] as usize;
            for e in p.idx.mod_imports[i] as usize..p.idx.mod_imports[i + 1] as usize {
                let sj = p.idx.scc_of[p.idx.imports[e] as usize] as usize;
                if sj != si && lvl[sj] + 1 > lvl[si] {
                    lvl.set(si, lvl[sj] + 1);
                    changed = true;
                }
            }
        }
        let mut plvl: u32 = 0;
        for i in 0..n {
            if p.modules.at(i).prelude && lvl[p.idx.scc_of[i] as usize] + 1 > plvl {
                plvl = lvl[p.idx.scc_of[i] as usize] + 1;
            }
        }
        for i in 0..n {
            let si = p.idx.scc_of[i] as usize;
            if !p.modules.at(i).prelude && lvl[si] < plvl {
                lvl.set(si, plvl);
                changed = true;
            }
        }
    }
    let mut gcost = Vector::<u64>::new();
    gcost.resize_default(nscc as usize + 1);
    let mut glvl = Vector::<u32>::new();
    glvl.resize_default(nscc as usize + 1);
    for i in 0..n {
        if p.modules.at(i).prelude {
            gcost.set(nscc as usize, gcost[nscc as usize] + mcost[i]);
        } else {
            let si = p.idx.scc_of[i] as usize;
            gcost.set(si, gcost[si] + mcost[i]);
            glvl.set(si, lvl[si]);
        }
    }
    let mut maxlvl: u32 = 0;
    for c in 0..nscc as usize + 1 {
        if glvl[c] > maxlvl {
            maxlvl = glvl[c];
        }
    }
    let mut total: u64 = 0;
    for l in 0..maxlvl + 1 {
        let mut worst: u64 = 0;
        for c in 0..nscc as usize + 1 {
            if glvl[c] == l && gcost[c] > worst {
                worst = gcost[c];
            }
        }
        total += worst;
    }
    return total;
}
