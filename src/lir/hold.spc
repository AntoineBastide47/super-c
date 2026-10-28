// Held records: what a unit's own object gives the optimization of the other units, kept in the per-TU
// cache (`driver::tuc`), so a build that replays the object optimizes the rest as a build that renders it
// does (`lir::opt::Run`). Per function of the object: the walk facts (the shape test, the direct calls
// before optimization) and, when its callers may inline it, its optimized body with the kind, C-library
// mark and recorded signature of every symbol the body names. Per data definition of the object: the
// definition, which the optimizer folds loads from. The data no unit claims that an inlinable body names
// (a string literal: each object that names one has its copy), with the data their relocations reach, stay
// defined for the emission, as the lowering of the body defines them. A record names symbols, messages
// and files by their spellings, so it loads into any package.
import lir::ir as *;
import lir::opt as lopt;
import utils::persist as *;

extend Inst as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &Inst, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut Inst, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend Block as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &Block, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut Block, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend Loc as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &Loc, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut Loc, r: &mut Reader) {
        load_bytes(self, r);
    }
}

// A slot has padding after its alignment: field by field.
extend Slot as Persist {}

extend Scope as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &Scope, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut Scope, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend Body as Persist {
    fn save(self: &Body, w: &mut Writer) {
        self.insts.save(w);
        self.locs.save(w);
        self.blocks.save(w);
        self.params.save(w);
        self.pool.save(w);
        self.words.save(w);
        self.slots.save(w);
        self.syms.save(w);
        self.msgs.save(w);
        self.lines.save(w);
        self.inl.save(w);
        self.sig.save(w);
        self.refs.save(w);
        self.scopes.save(w);
        self.naked.save(w);
    }

    fn load(self: &mut Body, r: &mut Reader) {
        self.insts.load(r);
        self.locs.load(r);
        self.blocks.load(r);
        self.params.load(r);
        self.pool.load(r);
        self.words.load(r);
        self.slots.load(r);
        self.syms.load(r);
        self.msgs.load(r);
        self.lines.load(r);
        self.inl.load(r);
        self.sig.load(r);
        self.refs.load(r);
        self.scopes.load(r);
        self.naked.load(r);
    }
}

// A symbol an inlinable body names: its spelling (`Rec.names`), kind, C-library mark (`Sym.ext`) and
// recorded signature (`Rec.decls`, NONE for none).
@derive(Copy)
pub(package) struct HRef {
    pub(package) name: u32,
    pub(package) kind: u8,
    pub(package) ext: bool,
    pub(package) sig: u32,
}

extend HRef as Persist {}

// A function of the object: its spelling, walk facts (`HELD_*`), effects (`Sym.fx`) and the parameters
// whose memory it may write, direct calls (spellings, in instruction order) and, with HELD_OK, its
// optimized body, whose symbols are `refs`, whose messages and line files are spellings.
pub(package) struct HFunc {
    pub(package) name: u32,
    pub(package) flags: u8,
    pub(package) fx: u8,
    pub(package) wargs: u64,
    pub(package) calls: Vector<u32>,
    pub(package) body: Body,
    pub(package) refs: Vector<HRef>,
}

extend HFunc as Persist {}

// A relocation of a data definition: the target's spelling and kind.
@derive(Copy)
pub(package) struct HReloc {
    pub(package) offset: u32,
    pub(package) sym: u32,
    pub(package) kind: u8,
    pub(package) addend: i64,
}

extend HReloc as Persist {}

pub(package) struct HData {
    pub(package) name: u32,
    pub(package) kind: u8,
    pub(package) size: u32,
    pub(package) align_log2: u8,
    pub(package) readonly: bool,
    pub(package) bytes: Vector<u8>,
    pub(package) relocs: Vector<HReloc>,
}

extend HData as Persist {}

/// A unit's held record (`save`, `read`).
pub(package) struct Rec {
    pub(package) names: Vector<String>,
    pub(package) funcs: Vector<HFunc>,
    pub(package) data: Vector<HData>,
    pub(package) free: Vector<HData>,
    pub(package) decls: Vector<Body>,
}

extend Rec as Persist {}

// A record under construction: spellings get indices in first-use order.
struct Saver {
    pub(package) rec: Rec,
    pub(package) ids: Map<u32, u32>, // package name id -> index into `rec.names`
}

extend Saver {
    // Data definition `d` of symbol `s` as a record entry.
    fn data(self: &mut Self, pk: &Package, s: u32) HData {
        let sy = pk.syms[s as usize];
        let d = pk.data[sy.def as usize];
        let mut hd = HData {
            name: self.name(pk, sy.name),
            kind: sy.kind,
            size: d.size,
            align_log2: d.align_log2,
            readonly: d.readonly,
            bytes: Vector::<u8>::new(),
            relocs: Vector::<HReloc>::with_capacity(d.nrelocs as usize),
        };
        hd.bytes.extend_from_slice(pk.data_bytes(&d));
        for j in d.relocs..d.relocs + d.nrelocs {
            let rl = pk.relocs[j as usize];
            let ry = pk.syms[rl.sym as usize];
            hd.relocs.push(HReloc { offset: rl.offset, sym: self.name(pk, ry.name), kind: ry.kind, addend: rl.addend });
        }
        return hd;
    }

    fn name(self: &mut Self, pk: &Package, id: u32) u32 {
        if let Some(k) = self.ids.get(&id) {
            return *k;
        }
        let k = self.rec.names.len() as u32;
        self.rec.names.push(String::from_str(pk.spell(id)));
        self.ids.insert(id, k);
        return k;
    }
}

/// The record of every unit `want` marks into `out` (indexed by unit), from `pk` after `r` optimized its
/// bodies and gave them back: each unit's own functions and data definitions (`Sym.own`), in symbol
/// order.
pub(package) fn save(pk: &Package, r: &lopt::Run, want: &Vector<bool>, out: &mut Vector<String>) {
    let n = want.len();
    let nb = pk.bodies.len();
    let mut bsym = Vector::<u32>::with_capacity(nb);
    for _ in 0..nb {
        bsym.push(NONE);
    }
    let mut fs = Vector::<Vector<u32>>::new();
    let mut ds = Vector::<Vector<u32>>::new();
    fs.resize_default(n);
    ds.resize_default(n);
    for s in 0..pk.syms.len() {
        let sy = pk.syms[s];
        if sy.def == NONE {
            continue;
        }
        if sy.kind == SK_FUNC {
            bsym[sy.def as usize] = s as u32;
        }
        if !sy.own || sy.unit as usize >= n || !want[sy.unit as usize] {
            continue;
        }
        if sy.kind == SK_FUNC {
            fs.index_mut(sy.unit as usize).push(s as u32);
        } else {
            ds.index_mut(sy.unit as usize).push(s as u32);
        }
    }
    out.truncate(0);
    out.resize_default(n);
    for u in 0..n {
        if !want[u] {
            continue;
        }
        let mut sv = Saver {
            rec: Rec {
                names: Vector::<String>::new(),
                funcs: Vector::<HFunc>::with_capacity(fs.at(u).len()),
                data: Vector::<HData>::with_capacity(ds.at(u).len()),
                free: Vector::<HData>::new(),
                decls: Vector::<Body>::new(),
            },
            ids: Map::<u32, u32>::new(),
        };
        // The free data the inlinable bodies name, then the free data their relocations reach.
        let mut free = Vector::<u32>::new();
        let mut seen = Set::<u32>::new();
        for q in 0..fs.at(u).len() {
            let s = fs.at(u)[q];
            let sy = pk.syms[s as usize];
            let k = sy.def;
            let ok = r.inlinable(k);
            let mut f = HFunc {
                name: sv.name(pk, sy.name),
                flags: if r.shape_of(k) {
                    HELD_SHAPE;
                } else {
                    0u8;
                } | if ok {
                    HELD_OK;
                } else {
                    0u8;
                },
                fx: sy.fx,
                wargs: r.wargs_of(k),
                calls: Vector::<u32>::new(),
                body: Body::new(),
                refs: Vector::<HRef>::new(),
            };
            let cs = r.calls_of(k);
            for c in 0..cs.len() {
                f.calls.push(sv.name(pk, pk.syms[bsym[cs[c] as usize] as usize].name));
            }
            if ok {
                f.body = pk.bodies[k as usize].compact();
                for i in 0..f.body.syms.len() {
                    let ry = pk.syms[f.body.syms[i] as usize];
                    if ry.kind != SK_FUNC && ry.def != NONE && ry.unit == NONE && !seen.contains(&f.body.syms[i]) {
                        seen.insert(f.body.syms[i]);
                        free.push(f.body.syms[i]);
                    }
                    let mut sig = NONE;
                    if ry.sig != NONE {
                        sig = sv.rec.decls.len() as u32;
                        sv.rec.decls.push(pk.decls[ry.sig as usize].compact());
                    }
                    f.refs.push(HRef { name: sv.name(pk, ry.name), kind: ry.kind, ext: ry.ext, sig: sig });
                }
                f.body.syms.truncate(0);
                for i in 0..f.body.msgs.len() {
                    f.body.msgs[i] = sv.name(pk, pk.msgs[f.body.msgs[i] as usize]);
                }
                for i in 1..f.body.lines.len() {
                    f.body.lines.index_mut(i).file = sv.name(pk, pk.files[f.body.lines[i].file as usize]);
                }
            }
            sv.rec.funcs.push(f);
        }
        for q in 0..ds.at(u).len() {
            let hd = sv.data(pk, ds.at(u)[q]);
            sv.rec.data.push(hd);
        }
        // Each free definition once: the list grows as the relocations reach new ones.
        let mut q: usize = 0;
        while q < free.len() {
            let d = pk.data[pk.syms[free[q] as usize].def as usize];
            for j in d.relocs..d.relocs + d.nrelocs {
                let t = pk.relocs[j as usize].sym;
                let ty = pk.syms[t as usize];
                if ty.kind != SK_FUNC && ty.def != NONE && ty.unit == NONE && !seen.contains(&t) {
                    seen.insert(t);
                    free.push(t);
                }
            }
            let hd = sv.data(pk, free[q]);
            sv.rec.free.push(hd);
            q += 1;
        }
        let mut w = Writer::new();
        sv.rec.save(&mut w);
        out.set(u, replace(&mut w.buf, String::new()));
    }
}

/// Record `img` (from `save`, 16-byte aligned) for a package of `ptr_bytes`-byte pointers; None when it
/// does not read or names past its tables.
pub(package) fn read(img: str, ptr_bytes: u32) Option<Rec> {
    let mut r = Reader::new(img.ptr(), img.len());
    let rec = load_new::<Rec>(&mut r);
    if !r.ok || r.left() != 0 || !valid(&rec, ptr_bytes) {
        return Option::<Rec>::None;
    }
    return Option::<Rec>::Some(rec);
}

// Whether every index of `rec` is in its table and every data definition holds its bytes and relocations.
fn valid(rec: &Rec, ptr_bytes: u32) bool {
    let nn = rec.names.len() as u32;
    for q in 0..rec.funcs.len() {
        let f = rec.funcs.at(q);
        let mut ok = f.name < nn;
        for c in 0..f.calls.len() {
            ok = ok && f.calls[c] < nn;
        }
        for i in 0..f.refs.len() {
            let h = *f.refs.at(i);
            ok = ok && h.name < nn && (h.sig == NONE || h.sig as usize < rec.decls.len());
        }
        for i in 0..f.body.msgs.len() {
            ok = ok && f.body.msgs[i] < nn;
        }
        for i in 1..f.body.lines.len() {
            ok = ok && f.body.lines[i].file < nn;
        }
        if !ok {
            return false;
        }
    }
    return valid_data(&rec.data, nn, ptr_bytes) && valid_data(&rec.free, nn, ptr_bytes);
}

// Whether every data definition of `ds` holds its bytes and relocations, with its spellings below `nn`.
fn valid_data(ds: &Vector<HData>, nn: u32, ptr_bytes: u32) bool {
    for q in 0..ds.len() {
        let d = ds.at(q);
        let mut ok = d.name < nn && d.kind != SK_FUNC && d.bytes.len() <= d.size as usize;
        for j in 0..d.relocs.len() {
            let h = *d.relocs.at(j);
            ok = ok && h.sym < nn && h.offset as u64 + ptr_bytes as u64 <= d.size as u64;
        }
        if !ok {
            return false;
        }
    }
    return true;
}

/// Define in `pk` the free data of record `rec` (`read`) that it does not define yet. Before any `add`:
/// these stay defined.
pub(package) fn add_free(pk: &mut Package, rec: &Rec) {
    for q in 0..rec.free.len() {
        let _ = define(pk, rec, rec.free.at(q));
    }
}

// Define data `d` of record `rec` in `pk` unless its symbol is defined or of another kind; its symbol, or
// NONE when it does not define it.
fn define(pk: &mut Package, rec: &Rec, d: &HData) u32 {
    let s = pk.symbol(rec.names.at(d.name as usize).as_str(), d.kind);
    if pk.syms[s as usize].kind != d.kind || pk.syms[s as usize].def != NONE {
        return NONE;
    }
    let mut rs = Vector::<Reloc>::with_capacity(d.relocs.len());
    for j in 0..d.relocs.len() {
        let h = *d.relocs.at(j);
        rs.push(
            Reloc { offset: h.offset, sym: pk.symbol(rec.names.at(h.sym as usize).as_str(), h.kind), addend: h.addend },
        );
    }
    let added = pk.add_data(s, d.size, d.align_log2, d.readonly, d.bytes.as_slice(), rs[0..rs.len()]);
    assert(added, "lir: a data definition `read` checked does not add");
    return s;
}

/// Add record `rec` (`read`) of unit `unit` to `pk` as held bodies and data definitions (`Package.held`),
/// after every body and data definition the package has; a function or data object the package defines
/// already keeps its definition.
pub(package) fn add(pk: &mut Package, unit: u32, rec: &Rec) {
    if pk.held.body == NONE {
        pk.held.body = pk.bodies.len() as u32;
        pk.held.data = pk.data.len() as u32;
        pk.held.bytes = pk.bytes.len() as u32;
        pk.held.relocs = pk.relocs.len() as u32;
        pk.held.at.push(0);
    }
    for q in 0..rec.funcs.len() {
        let f = rec.funcs.at(q);
        let s = pk.symbol(rec.names.at(f.name as usize).as_str(), SK_FUNC);
        if pk.syms[s as usize].kind != SK_FUNC || pk.syms[s as usize].def != NONE {
            continue;
        }
        let mut b = Body::new();
        if (f.flags & HELD_OK) != 0 {
            b = f.body.compact();
            for i in 0..f.refs.len() {
                let h = *f.refs.at(i);
                let rs = pk.symbol(rec.names.at(h.name as usize).as_str(), h.kind);
                if h.ext {
                    pk.syms.index_mut(rs as usize).ext = true;
                }
                if h.sig != NONE && pk.syms[rs as usize].sig == NONE {
                    pk.decls.push(rec.decls.at(h.sig as usize).compact());
                    pk.syms.index_mut(rs as usize).sig = pk.decls.len() as u32 - 1;
                }
                b.syms.push(rs);
            }
            for i in 0..b.msgs.len() {
                b.msgs[i] = pk.add_message(rec.names.at(b.msgs[i] as usize).as_str());
            }
            for i in 1..b.lines.len() {
                b.lines.index_mut(i).file = pk.add_file(rec.names.at(b.lines[i].file as usize).as_str());
            }
        }
        pk.bodies.push(b);
        let y = pk.syms.index_mut(s as usize);
        y.def = pk.bodies.len() as u32 - 1;
        y.unit = unit;
        y.own = true;
        pk.held.syms.push(s);
        pk.held.flags.push(f.flags);
        pk.held.fx.push(f.fx);
        pk.held.wargs.push(f.wargs);
        for c in 0..f.calls.len() {
            pk.held.calls.push(pk.symbol(rec.names.at(f.calls[c] as usize).as_str(), SK_FUNC));
        }
        pk.held.at.push(pk.held.calls.len() as u32);
    }
    for q in 0..rec.data.len() {
        let s = define(pk, rec, rec.data.at(q));
        if s == NONE {
            continue;
        }
        let y = pk.syms.index_mut(s as usize);
        y.unit = unit;
        y.own = true;
        pk.held.dsyms.push(s);
    }
}
