// The relocatable wasm object `wasm-ld` links (the tool conventions' Linking.md): function types,
// imports, functions, data segments, the `linking` section's symbol table and segment info, and the
// relocations of the code and data sections. The code generator fills a `WObj`; `write` lays it out.
//
// Symbols are the object's: a function (defined, or an import from `env`), a data symbol (one segment
// each, or undefined), the stack pointer global and the function table. A relocation names a symbol (a
// type index for R_TYPE_INDEX_LEB) and its offset in the body or segment that holds it.
import target::wasm as w;
import utils::names as nm;
import codegen::obj as ob;
import codegen::dwarf as dw;

/// Symbol kinds (the linking conventions' `SYMTAB_*`).
pub const K_FUNC: u8 = 0;
pub const K_DATA: u8 = 1;
pub const K_GLOBAL: u8 = 2;
pub const K_SECTION: u8 = 3;
pub const K_TABLE: u8 = 5;

/// Symbol flags (`WASM_SYM_*`).
pub const F_WEAK: u32 = 1;
pub const F_LOCAL: u32 = 2;
pub const F_HIDDEN: u32 = 4;
pub const F_UNDEFINED: u32 = 0x10;
pub const F_EXPLICIT_NAME: u32 = 0x40;
pub const F_NO_STRIP: u32 = 0x80;

/// Segment flags.
const SEG_RETAIN: u32 = 4;

pub const NONE: u32 = 0xFFFFFFFF;

/// A relocation: type `kind` at byte `off` of its body or segment, against symbol `sym` (a type index for
/// R_TYPE_INDEX_LEB) plus `addend`.
pub struct WRel {
    pub kind: u8,
    pub off: u32,
    pub sym: u32,
    pub addend: i32,
}

extend WRel as Copy {}

/// A symbol. A function has its type (`ty`) and, once defined, its body (`def`, into `funcs`); data has
/// its segment (`def`, into `segs`) and size.
pub struct WSym {
    pub name: u32, // `names` id
    pub kind: u8,
    pub flags: u32,
    pub ty: u32,
    pub def: u32,
    pub size: u32,
    pub imod: u32, // an import's module (`names` id), NONE for `env`
    pub iname: u32, // an import's name (`names` id), NONE for the symbol's
}

extend WSym as Copy {}

/// A function body: its type, its locals past the parameters (one wasm type each), its instructions
/// (the closing `end` included) and their relocations; with debug information its line rows (offsets
/// into `code`) and the offset its body starts at past the prologue.
pub struct WFunc {
    pub sym: u32,
    pub locals: Vector<u8>,
    pub code: Vector<u8>,
    pub rels: Vector<WRel>,
    pub lines: Vector<ob::OLine>,
    pub body: u32,
}

/// A data segment: its name, alignment, bytes (`size` of them, the zero-filled ones too) and relocations.
pub struct WSeg {
    pub name: String,
    pub align_log2: u32,
    pub bytes: Vector<u8>,
    pub rels: Vector<WRel>,
    pub retain: bool,
}

/// The object a wasm code generator fills.
pub struct WObj {
    pub names: nm::Names,
    pub syms: Vector<WSym>,
    pub types: Vector<Vector<u8>>, // each a function type's encoding (params, then results)
    pub funcs: Vector<WFunc>,
    pub segs: Vector<WSeg>,
    pub simd: bool, // a body uses v128
    /// With debug information: the package's file paths by file id and the compile directory.
    pub debug: bool,
    pub files: Vector<String>,
    pub comp_dir: String,
    sym_of: Vector<u32>, // per name id, its symbol plus 1 (0: none)
}

extend WObj {
    pub fn new() WObj {
        return WObj {
            names: nm::Names::with_capacity(1 << 10, 1 << 6),
            syms: Vector::<WSym>::new(),
            types: Vector::<Vector<u8>>::new(),
            funcs: Vector::<WFunc>::new(),
            segs: Vector::<WSeg>::new(),
            simd: false,
            debug: false,
            files: Vector::<String>::new(),
            comp_dir: String::new(),
            sym_of: Vector::<u32>::new(),
        };
    }

    /// The symbol named `s` of kind `kind`, added undefined on first use.
    pub fn sym(self: &mut Self, s: str, kind: u8) u32 {
        let id = self.names.intern(s);
        while self.sym_of.len() <= id as usize {
            self.sym_of.push(0);
        }
        if self.sym_of[id as usize] != 0 {
            return self.sym_of[id as usize] - 1;
        }
        let k = self.syms.len() as u32;
        self.syms.push(
            WSym { name: id, kind: kind, flags: F_UNDEFINED, ty: NONE, def: NONE, size: 0, imod: NONE, iname: NONE },
        );
        self.sym_of[id as usize] = k + 1;
        return k;
    }

    /// The name of symbol `k`.
    pub const fn name_of(self: &Self, k: u32) str {
        return self.names.spell(self.syms[k as usize].name);
    }

    /// The index of function type `enc` (its parameters' and results' encoding), added on first use.
    pub fn type_index(self: &mut Self, enc: &Vector<u8>) u32 {
        for i in 0..self.types.len() {
            if self.types.at(i).as_slice() == enc.as_slice() {
                return i as u32;
            }
        }
        let mut c = Vector::<u8>::with_capacity(enc.len());
        c.extend_copy(enc);
        self.types.push(c);
        return self.types.len() as u32 - 1;
    }

    /// Define function symbol `k` with body `f`; `flags` its binding and visibility.
    pub fn define_func(self: &mut Self, k: u32, ty: u32, flags: u32, f: WFunc) {
        let s = self.syms.index_mut(k as usize);
        s.ty = ty;
        s.flags = flags;
        s.def = self.funcs.len() as u32;
        self.funcs.push(f);
    }

    /// Define data symbol `k` as segment `g` of `size` bytes.
    pub fn define_data(self: &mut Self, k: u32, flags: u32, g: WSeg) {
        let s = self.syms.index_mut(k as usize);
        s.flags = flags;
        s.def = self.segs.len() as u32;
        s.size = g.bytes.len() as u32;
        self.segs.push(g);
    }

    /// Give undefined function symbol `k` its type, the first call's.
    pub fn import_type(self: &mut Self, k: u32, ty: u32) {
        let s = self.syms.index_mut(k as usize);
        if s.ty == NONE {
            s.ty = ty;
        }
    }
}

// The object's index spaces: functions (imports first), globals, tables, and each symbol's index in its
// space (NONE for data).
struct Spaces {
    pub fidx: Vector<u32>, // per symbol
    pub nfimports: u32,
    pub sp_sym: u32,
    pub table_sym: u32,
}

/// Lay `o` out as an object file into `out`.
pub fn write(o: &WObj, out: &mut Vector<u8>) {
    let mut sp = Spaces { fidx: Vector::<u32>::new(), nfimports: 0, sp_sym: NONE, table_sym: NONE };
    // The function index space: the undefined functions (imports), then the bodies in order.
    for k in 0..o.syms.len() {
        sp.fidx.push(NONE);
        let s = o.syms[k];
        if s.kind == K_FUNC && s.def == NONE {
            sp.fidx[k] = sp.nfimports;
            sp.nfimports += 1;
        } else if s.kind == K_GLOBAL {
            sp.sp_sym = k as u32;
        } else if s.kind == K_TABLE {
            sp.table_sym = k as u32;
        }
    }
    for k in 0..o.syms.len() {
        let s = o.syms[k];
        if s.kind == K_FUNC && s.def != NONE {
            sp.fidx[k] = sp.nfimports + s.def;
        }
    }
    out.extend_from_slice([0x00u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]);
    let mut sec = Vector::<u8>::new();
    let mut nsec: u32 = 0;
    // Types.
    w::uleb(&mut sec, o.types.len() as u64);
    for i in 0..o.types.len() {
        sec.push(0x60);
        sec.extend_copy(o.types.at(i));
    }
    let _ = put_section(out, 1, &mut sec, &mut nsec);
    // Imports: the memory, the table, the stack pointer, the undefined functions.
    let nimp = 1 + (sp.table_sym != NONE) as u32 + (sp.sp_sym != NONE) as u32 + sp.nfimports;
    w::uleb(&mut sec, nimp);
    w::name(&mut sec, "env");
    w::name(&mut sec, "__linear_memory");
    sec.push(2);
    sec.push(0);
    w::uleb(&mut sec, 0);
    if sp.table_sym != NONE {
        w::name(&mut sec, "env");
        w::name(&mut sec, "__indirect_function_table");
        sec.push(1);
        sec.push(w::FUNCREF);
        sec.push(0);
        w::uleb(&mut sec, 0);
    }
    if sp.sp_sym != NONE {
        w::name(&mut sec, "env");
        w::name(&mut sec, "__stack_pointer");
        sec.push(3);
        sec.push(w::I32);
        sec.push(1);
    }
    for k in 0..o.syms.len() {
        let s = o.syms[k];
        if s.kind == K_FUNC && s.def == NONE {
            w::name(
                &mut sec,
                if s.imod != NONE {
                    o.names.spell(s.imod);
                } else {
                    "env";
                },
            );
            w::name(
                &mut sec,
                if s.iname != NONE {
                    o.names.spell(s.iname);
                } else {
                    o.name_of(k as u32);
                },
            );
            sec.push(0);
            w::uleb(&mut sec, s.ty);
        }
    }
    let _ = put_section(out, 2, &mut sec, &mut nsec);
    // Functions: their types.
    w::uleb(&mut sec, o.funcs.len() as u64);
    for i in 0..o.funcs.len() {
        w::uleb(&mut sec, o.syms[o.funcs.at(i).sym as usize].ty);
    }
    let _ = put_section(out, 3, &mut sec, &mut nsec);
    // The data count (the bulk memory forms read it; clang writes it).
    w::uleb(&mut sec, o.segs.len() as u64);
    let _ = put_section(out, 12, &mut sec, &mut nsec);
    // Code: per body its size, its locals in runs of one type, its instructions. A relocation's offset
    // counts from the section's contents.
    let mut code_rels = Vector::<WRel>::new();
    w::uleb(&mut sec, o.funcs.len() as u64);
    let mut head = Vector::<u8>::new();
    // Per body, where its entry starts in the section's contents and its instructions start in the entry.
    let mut entry = Vector::<u32>::with_capacity(o.funcs.len());
    let mut inst_at = Vector::<u32>::with_capacity(o.funcs.len());
    let mut body_size = Vector::<u32>::with_capacity(o.funcs.len());
    for i in 0..o.funcs.len() {
        let f = o.funcs.at(i);
        entry.push(sec.len() as u32);
        head.truncate(0);
        let mut runs: u32 = 0;
        let mut j: usize = 0;
        while j < f.locals.len() {
            let mut e = j + 1;
            while e < f.locals.len() && f.locals[e] == f.locals[j] {
                e += 1;
            }
            runs += 1;
            j = e;
        }
        w::uleb(&mut head, runs);
        j = 0;
        while j < f.locals.len() {
            let mut e = j + 1;
            while e < f.locals.len() && f.locals[e] == f.locals[j] {
                e += 1;
            }
            w::uleb(&mut head, (e - j) as u64);
            head.push(f.locals[j]);
            j = e;
        }
        body_size.push((head.len() + f.code.len()) as u32);
        w::uleb(&mut sec, (head.len() + f.code.len()) as u64);
        sec.extend_copy(&head);
        let base = sec.len() as u32;
        inst_at.push(base - entry[i]);
        let at0 = sec.len();
        sec.extend_copy(&f.code);
        for q in 0..f.rels.len() {
            let r = f.rels[q];
            let mut rr = r;
            rr.off = base + r.off;
            code_rels.push(rr);
            fill_reloc(&mut sec, at0 + r.off as usize, r, &sp);
        }
    }
    let code_index = put_section(out, 10, &mut sec, &mut nsec);
    // Data: one active segment per data symbol at a running address (the linker places them again).
    let mut data_rels = Vector::<WRel>::new();
    w::uleb(&mut sec, o.segs.len() as u64);
    let mut addr: u32 = 0;
    for i in 0..o.segs.len() {
        let g = o.segs.at(i);
        let al = 1u32 << g.align_log2;
        addr = addr + al - 1 & ~(al - 1);
        sec.push(0);
        sec.push(w::I32_CONST);
        w::sleb(&mut sec, addr);
        sec.push(w::END);
        w::uleb(&mut sec, g.bytes.len() as u64);
        let base = sec.len() as u32;
        sec.extend_copy(&g.bytes);
        for q in 0..g.rels.len() {
            let mut rr = g.rels[q];
            rr.off = base + g.rels[q].off;
            data_rels.push(rr);
        }
        addr += g.bytes.len() as u32;
    }
    let data_index = put_section(out, 11, &mut sec, &mut nsec);
    // Debug information: the sections, each with a section symbol after the object's symbols.
    let mut dbg_index = Vector::<u32>::new();
    let mut dbg_rels = Vector::<Vector<WRel>>::new();
    if o.debug {
        let mut d = debug_info(o, &inst_at, &body_size);
        let names: []str = dw::NAMES;
        for k in 0..dw::D_COUNT as usize {
            dbg_rels.push(Vector::<WRel>::new());
        }
        for x in 0..d.fixes.len() {
            let f = d.fixes[x];
            let b = d.secs.index_mut(f.sec as usize);
            // The field holds the object's own value: a function's entry offset, or the section offset.
            let (kind, sym, v) = if f.kind == dw::FX_ADDR {
                (w::R_FUNCTION_OFFSET_I32, f.sym, entry[o.syms[f.sym as usize].def as usize] as i64 + f.addend);
            } else {
                (w::R_SECTION_OFFSET_I32, o.syms.len() as u32 + f.sym, f.addend);
            };
            for j in 0..4u32 {
                b[(f.off + j) as usize] = (v as u64 >> (8 * j) as u64 & 0xFF) as u8;
            }
            dbg_rels.index_mut(f.sec as usize).push(WRel { kind: kind, off: f.off, sym: sym, addend: f.addend as i32 });
        }
        for k in 0..dw::D_COUNT as usize {
            dbg_index.push(put_custom(out, names[k], d.secs.at(k), &mut nsec));
        }
    }
    // linking: the symbol table, then the segment info.
    let mut lk = Vector::<u8>::new();
    w::uleb(&mut lk, 2);
    let mut sub = Vector::<u8>::new();
    w::uleb(&mut sub, (o.syms.len() + dbg_index.len()) as u64);
    for k in 0..o.syms.len() {
        let s = o.syms[k];
        sub.push(s.kind);
        // An import of another name than the symbol's names the symbol too.
        let explicit = s.kind == K_FUNC && s.def == NONE && s.iname != NONE;
        w::uleb(
            &mut sub,
            if explicit {
                s.flags | F_EXPLICIT_NAME;
            } else {
                s.flags;
            },
        );
        if s.kind == K_DATA {
            w::name(&mut sub, o.name_of(k as u32));
            if s.def != NONE {
                w::uleb(&mut sub, s.def);
                w::uleb(&mut sub, 0);
                w::uleb(&mut sub, s.size);
            }
            continue;
        }
        let idx = if s.kind == K_FUNC {
            sp.fidx[k];
        } else {
            0u32;
        };
        w::uleb(&mut sub, idx);
        if s.def != NONE || explicit {
            w::name(&mut sub, o.name_of(k as u32));
        }
    }
    for k in 0..dbg_index.len() {
        sub.push(K_SECTION);
        w::uleb(&mut sub, F_LOCAL);
        w::uleb(&mut sub, dbg_index[k]);
    }
    lk.push(8);
    w::uleb(&mut lk, sub.len() as u64);
    lk.extend_copy(&sub);
    sub.truncate(0);
    if o.segs.len() != 0 {
        w::uleb(&mut sub, o.segs.len() as u64);
        for i in 0..o.segs.len() {
            let g = o.segs.at(i);
            w::name(&mut sub, g.name.as_str());
            w::uleb(&mut sub, g.align_log2);
            w::uleb(&mut sub, ast_pick32(g.retain, SEG_RETAIN, 0));
        }
        lk.push(5);
        w::uleb(&mut lk, sub.len() as u64);
        lk.extend_copy(&sub);
    }
    let _ = put_custom(out, "linking", &lk, &mut nsec);
    // The relocations of the code, of the data and of the debug sections.
    if code_rels.len() != 0 {
        let rc = rel_section(code_index, &code_rels);
        let _ = put_custom(out, "reloc.CODE", &rc, &mut nsec);
    }
    if data_rels.len() != 0 {
        let rd = rel_section(data_index, &data_rels);
        let _ = put_custom(out, "reloc.DATA", &rd, &mut nsec);
    }
    let names: []str = dw::NAMES;
    for k in 0..dbg_index.len() {
        if dbg_rels.at(k).len() != 0 {
            let rs = rel_section(dbg_index[k], dbg_rels.at(k));
            let _ = put_custom(out, format("reloc.{}", names[k]).as_str(), &rs, &mut nsec);
        }
    }
    // The features the code uses.
    let mut tf = Vector::<u8>::new();
    let mut feats = Vector::<str>::new();
    feats.push("mutable-globals");
    feats.push("sign-ext");
    if sp.table_sym != NONE {
        feats.push("reference-types");
    }
    if o.simd {
        feats.push("simd128");
    }
    w::uleb(&mut tf, feats.len() as u64);
    for i in 0..feats.len() {
        tf.push(b'+');
        w::name(&mut tf, feats[i]);
    }
    let _ = put_custom(out, "target_features", &tf, &mut nsec);
}

// The DWARF of `o`'s bodies: an address is an offset from a body's entry (its size field), where body
// `i`'s instructions start `inst_at[i]` bytes later; its range is the size its field states
// (`body_size[i]`), as clang states it. A row before the instructions (the entry's locals) takes the
// first row's location.
fn debug_info(o: &WObj, inst_at: &Vector<u32>, body_size: &Vector<u32>) dw::Dwarf {
    let mut funcs = Vector::<ob::OFunc>::new();
    let mut lines = Vector::<ob::OLine>::new();
    let mut names = Vector::<str>::new();
    let mut globals = Vector::<bool>::new();
    for i in 0..o.funcs.len() {
        let f = o.funcs.at(i);
        let start = lines.len() as u32;
        for r in 0..f.lines.len() {
            let mut l = f.lines[r];
            l.off = inst_at[i] + l.off;
            lines.push(l);
        }
        funcs.push(
            ob::OFunc {
                sym: f.sym,
                size: body_size[i],
                start: start,
                n: f.lines.len() as u32,
                body: inst_at[i] + f.body,
            },
        );
        names.push(o.name_of(f.sym));
        globals.push((o.syms[f.sym as usize].flags & F_LOCAL) == 0);
    }
    let mut files = Vector::<str>::with_capacity(o.files.len());
    for k in 0..o.files.len() {
        files.push(o.files.at(k).as_str());
    }
    return dw::Dwarf::build(
        funcs.as_slice(),
        lines.as_slice(),
        names.as_slice(),
        globals.as_slice(),
        files.as_slice(),
        o.comp_dir.as_str(),
        4,
    );
}

const fn ast_pick32(c: bool, a: u32, b: u32) u32 {
    if c {
        return a;
    }
    return b;
}

// The object's own value of relocated field `r` at `at` of `sec`: the index a function, the stack pointer,
// a type or the table has in this object. A memory address or table index stays for the linker.
fn fill_reloc(sec: &mut Vector<u8>, at: usize, r: WRel, sp: &Spaces) {
    if r.kind == w::R_FUNCTION_INDEX_LEB {
        w::patch_uleb5(sec, at, sp.fidx[r.sym as usize]);
    } else if r.kind == w::R_TYPE_INDEX_LEB {
        w::patch_uleb5(sec, at, r.sym);
    }
}

// Append section `id` with contents `sec` to `out` and clear `sec`; its index in the module (`n` counts
// them).
fn put_section(out: &mut Vector<u8>, id: u8, sec: &mut Vector<u8>, n: &mut u32) u32 {
    out.push(id);
    w::uleb(out, sec.len() as u64);
    out.extend_copy(sec);
    sec.truncate(0);
    *n += 1;
    return *n - 1;
}

// Append custom section `name` with contents `body` to `out`; its index in the module (`n` counts them).
fn put_custom(out: &mut Vector<u8>, name: str, body: &Vector<u8>, n: &mut u32) u32 {
    let mut c = Vector::<u8>::new();
    w::name(&mut c, name);
    c.extend_copy(body);
    out.push(0);
    w::uleb(out, c.len() as u64);
    out.extend_copy(&c);
    *n += 1;
    return *n - 1;
}

// The contents of a `reloc.*` section for section `index`.
fn rel_section(index: u32, rels: &Vector<WRel>) Vector<u8> {
    let mut c = Vector::<u8>::new();
    w::uleb(&mut c, index);
    w::uleb(&mut c, rels.len() as u64);
    for q in 0..rels.len() {
        let r = rels[q];
        c.push(r.kind);
        w::uleb(&mut c, r.off);
        w::uleb(&mut c, r.sym);
        if w::has_addend(r.kind) {
            w::sleb(&mut c, r.addend);
        }
    }
    return c;
}
