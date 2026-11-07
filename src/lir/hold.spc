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
        self.owned.save(w);
        self.bools.save(w);
        self.fmath.save(w);
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
        self.owned.load(r);
        self.bools.load(r);
        self.fmath.load(r);
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

// A function of the object: its spelling, walk facts (`HELD_*`), effects (`Sym.fx`), the parameters
// whose memory it may write and those it may let escape (`Sym.esc`), its parameters' byte ranges
// (`Sym.span`'s entries), direct calls (spellings, in instruction order) and, with HELD_OK, its optimized
// body, whose symbols are `refs`, whose messages and line files are spellings.
pub(package) struct HFunc {
    pub(package) name: u32,
    pub(package) flags: u8,
    pub(package) fx: u8,
    pub(package) wargs: u64,
    pub(package) esc: u64,
    pub(package) spans: Vector<u64>,
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

/// A unit's held record (`record`, `read`). `Held::save` writes it field by field, as its conformance does:
/// a field added here is added there.
pub(package) struct Rec {
    pub(package) names: Vector<String>,
    pub(package) funcs: Vector<HFunc>,
    pub(package) data: Vector<HData>,
    pub(package) free: Vector<HData>,
    pub(package) decls: Vector<Body>,
}

extend Rec as Persist {}

// A body of the package a record holds while it is written (`Held`): the record's function `func`, body
// `body`, with the package's symbols, messages and line files.
struct Lent {
    func: u32,
    body: u32,
    syms: Vector<u32>,
    msgs: Vector<u32>,
    files: Vector<u32>,
}

// A record under construction: spellings get indices in first-use order. Its names are the package's name
// ids (`names`), spelled when it is saved (`Held::save`); `rec.names` stays empty.
struct Saver {
    pub(package) rec: Rec,
    pub(package) names: Vector<u32>,
    pub(package) ids: Map<u32, u32>, // package name id -> index into `names`
}

extend Saver {
    // Data definition `d` of symbol `s` as a record entry.
    fn data(self: &mut Self, pk: &Package, s: u32) HData {
        let sy = pk.syms[s as usize];
        let d = pk.data[sy.def as usize];
        let mut hd = HData {
            name: self.name(sy.name),
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
            hd.relocs.push(HReloc { offset: rl.offset, sym: self.name(ry.name), kind: ry.kind, addend: rl.addend });
        }
        return hd;
    }

    fn name(self: &mut Self, id: u32) u32 {
        if let Some(k) = self.ids.get(&id) {
            return *k;
        }
        let k = self.names.len() as u32;
        self.names.push(id);
        self.ids.insert(id, k);
        return k;
    }
}

/// What the records of the units `want` marks hold (`units`): per unit, its own function symbols and
/// data definition symbols (`Sym.own`), in symbol order; per body, its function symbol.
pub(package) struct Units {
    bsym: Vector<u32>,
    fs: Vector<Vector<u32>>,
    ds: Vector<Vector<u32>>,
}

/// A unit's record while it is written: it holds the package's bodies it lent until `restore`.
pub(package) struct Held {
    sv: Saver,
    lent: Vector<Lent>,
}

/// The `Units` of `pk` for the units `want` marks.
pub(package) fn units(pk: &Package, want: &Vector<bool>) Units {
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
    return Units { bsym: bsym, fs: fs, ds: ds };
}

/// The record of unit `u` of `us`, from `pk` after `r` optimized its bodies and gave them back. It takes
/// the inlined forms `r` kept (`Run::take_inlined`) and holds `pk`'s bodies until `restore`.
pub(package) fn record(pk: &mut Package, r: &mut lopt::Run, us: &Units, u: usize) Held {
    let mut sv = Saver {
        rec: Rec {
            names: Vector::<String>::new(),
            funcs: Vector::<HFunc>::with_capacity(us.fs.at(u).len()),
            data: Vector::<HData>::with_capacity(us.ds.at(u).len()),
            free: Vector::<HData>::new(),
            decls: Vector::<Body>::new(),
        },
        names: Vector::<u32>::new(),
        ids: Map::<u32, u32>::new(),
    };
    // The free data the inlinable bodies name, then the free data their relocations reach.
    let mut free = Vector::<u32>::new();
    let mut seen = Set::<u32>::new();
    // Per package signature, its index in `decls`: each one recorded once.
    let mut sigs = Map::<u32, u32>::new();
    // The package's bodies the record holds, with their own symbols, messages and line files.
    let mut lent = Vector::<Lent>::new();
    for q in 0..us.fs.at(u).len() {
        let s = us.fs.at(u)[q];
        let sy = pk.syms[s as usize];
        let k = sy.def;
        let ok = r.inlinable(k);
        let mut f = HFunc {
            name: sv.name(sy.name),
            flags: if r.shape_of(k) {
                HELD_SHAPE
            } else {
                0u8
            } | if ok {
                HELD_OK
            } else {
                0u8
            } | if sy.cold {
                HELD_COLD
            } else {
                0u8
            } | if sy.always {
                HELD_ALWAYS
            } else {
                0u8
            },
            fx: sy.fx,
            wargs: r.wargs_of(k),
            esc: sy.esc,
            spans: Vector::<u64>::new(),
            calls: Vector::<u32>::new(),
            // An inlinable function's is its body (`take_inlined`).
            body: if ok {
                Body::empty()
            } else {
                Body::new()
            },
            refs: Vector::<HRef>::new(),
        };
        if sy.span != NONE {
            let n = pk.spans[sy.span as usize] as usize;
            f.spans.extend_from_slice(pk.spans[sy.span as usize + 1..sy.span as usize + 1 + n]);
        }
        let cs = r.calls_of(k);
        f.calls.reserve_exact(cs.len());
        for c in 0..cs.len() {
            f.calls.push(sv.name(pk.syms[us.bsym[cs[c] as usize] as usize].name));
        }
        if ok {
            let (b, of_pk) = r.take_inlined(pk, k);
            f.body = b;
            f.refs.reserve_exact(f.body.syms.len());
            for i in 0..f.body.syms.len() {
                let ry = pk.syms[f.body.syms[i] as usize];
                if ry.kind != SK_FUNC && ry.def != NONE && ry.unit == NONE && !seen.contains(&f.body.syms[i]) {
                    seen.insert(f.body.syms[i]);
                    free.push(f.body.syms[i]);
                }
                let mut sig = NONE;
                if ry.sig != NONE {
                    sig = (switch sigs.get(&ry.sig) {
                        Some(x) => *x,
                        None => {
                            let x = sv.rec.decls.len() as u32;
                            sv.rec.decls.push(pk.decls[ry.sig as usize].compact());
                            sigs.insert(ry.sig, x);
                            x
                        },
                    });
                }
                f.refs.push(HRef { name: sv.name(ry.name), kind: ry.kind, ext: ry.ext, sig: sig });
            }
            let syms = replace(&mut f.body.syms, Vector::<u32>::new());
            if of_pk {
                let mut l = Lent {
                    func: sv.rec.funcs.len() as u32,
                    body: k,
                    syms: syms,
                    msgs: Vector::<u32>::with_capacity(f.body.msgs.len()),
                    files: Vector::<u32>::with_capacity(f.body.lines.len()),
                };
                l.msgs.extend_copy(&f.body.msgs);
                for i in 0..f.body.lines.len() {
                    l.files.push(f.body.lines[i].file);
                }
                lent.push(l);
            }
            for i in 0..f.body.msgs.len() {
                f.body.msgs[i] = sv.name(pk.msgs[f.body.msgs[i] as usize]);
            }
            for i in 1..f.body.lines.len() {
                f.body.lines.index_mut(i).file = sv.name(pk.files[f.body.lines[i].file as usize]);
            }
        }
        sv.rec.funcs.push(f);
    }
    for q in 0..us.ds.at(u).len() {
        let hd = sv.data(pk, us.ds.at(u)[q]);
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
    return Held { sv: sv, lent: lent };
}

extend Held {
    /// The bytes `write` gives.
    pub(package) fn size(self: &Self, pk: &Package) usize {
        let mut sz = Writer::sizing();
        self.save(pk, &mut sz);
        return sz.len();
    }

    pub(package) fn write(self: &Self, pk: &Package, w: &mut Writer) {
        self.save(pk, w);
    }

    // The record as `Rec`'s conformance saves it, field by field, its names spelled from `pk`
    // (`Saver::names`): what `read` loads.
    fn save(self: &Self, pk: &Package, w: &mut Writer) {
        w.u64(self.sv.names.len() as u64);
        for i in 0..self.sv.names.len() {
            let s = pk.spell(self.sv.names[i]);
            w.u64(s.len() as u64);
            w.bytes(s.ptr(), s.len());
        }
        self.sv.rec.funcs.save(w);
        self.sv.rec.data.save(w);
        self.sv.rec.free.save(w);
        self.sv.rec.decls.save(w);
    }

    /// Give `pk` the bodies the record holds back, as they were.
    pub(package) fn restore(self: &mut Self, pk: &mut Package) {
        for x in 0..self.lent.len() {
            let l = self.lent.index_mut(x);
            let mut b = replace(&mut self.sv.rec.funcs.index_mut(l.func as usize).body, Body::empty());
            b.syms = replace(&mut l.syms, Vector::<u32>::new());
            b.msgs = replace(&mut l.msgs, Vector::<u32>::new());
            for i in 0..b.lines.len() {
                b.lines.index_mut(i).file = l.files[i];
            }
            pk.bodies.set(l.body as usize, b);
        }
        self.lent.truncate(0);
    }
}

/// Record `img` (from `Held::write`, 16-byte aligned) for a package of `ptr_bytes`-byte pointers; None when it
/// does not read or names past its tables.
pub(package) fn read(img: str, ptr_bytes: u32) Option<Rec> {
    let mut r = Reader::new(img.ptr(), img.len());
    let rec = load_new::<Rec>(&mut r);
    if !r.ok || r.left() != 0 || !valid(&rec, ptr_bytes) {
        return None;
    }
    return Some(rec);
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
    let added = pk.add_data(s, d.size, d.align_log2, d.readonly, &d.bytes, rs[0..rs.len()]);
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
        pk.held.span_at.push(0);
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
        y.cold = (f.flags & HELD_COLD) != 0;
        y.always = (f.flags & HELD_ALWAYS) != 0;
        pk.held.syms.push(s);
        pk.held.flags.push(f.flags);
        pk.held.fx.push(f.fx);
        pk.held.wargs.push(f.wargs);
        pk.held.esc.push(f.esc);
        pk.held.spans.extend_copy(&f.spans);
        pk.held.span_at.push(pk.held.spans.len() as u32);
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
    pk.held.data_end = pk.data.len() as u32;
    pk.held.bytes_end = pk.bytes.len() as u32;
    pk.held.relocs_end = pk.relocs.len() as u32;
}
