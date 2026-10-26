// The wasm linker: relocatable wasm objects (the tool conventions' Linking.md, as `target::wasmobj` writes
// them) into a WASI command module. A WASI call is an import its object names with a module; every other
// symbol must be defined. The module exports `_start` and the memory; the stack comes first in memory or
// after the data (wasm-ld's `--stack-first`), then the data, then the heap (`__heap_base`). The
// constructors (`.init_array` segments) run from the linker's `__wasm_call_ctors`. Function pointers are
// slots of the module's one table. The module carries a name section and the debug sections unless
// stripped.
import link::util as lu;
import utils::names as nm;
import target::wasm as w;

const NONE: u32 = 0xFFFFFFFF;

/// A link: the objects, the output, the stack's size and place, and whether to leave out the names and
/// the debug sections.
pub struct Opts {
    pub out: String,
    pub objs: Vector<String>,
    pub stack: u64, // 0: wasm-ld's 64 KiB
    pub stack_first: bool,
    pub strip: bool,
}

// Symbol kinds and flags (the linking conventions').
const K_FUNC: u8 = 0;
const K_DATA: u8 = 1;
const K_GLOBAL: u8 = 2;
const K_SECTION: u8 = 3;
const K_TABLE: u8 = 5;
const F_WEAK: u32 = 1;
const F_LOCAL: u32 = 2;
const F_UNDEFINED: u32 = 0x10;
const F_EXPLICIT_NAME: u32 = 0x40;

// An input file: its bytes in the blob, and where its parts start in the per-file tables.
struct IFile {
    pub path: u32,
    pub at: usize,
    pub sym0: u32,
    pub nsym: u32,
    pub type0: u32, // `types`: the file's types
    pub imp0: u32, // `fimps`: its function imports
    pub nimp: u32,
    pub fn0: u32, // `funcs`: its bodies
    pub nfn: u32,
    pub seg0: u32, // `segs`: its data segments
    pub nseg: u32,
    pub sec0: u32, // `secs`: its sections
    pub nsec: u32,
    pub gimp0: u32, // `gimps`: the names of its global imports
    pub timp0: u32, // `timps`: the names of its table imports
}

// A section of an input: its id, the custom section's name (`sn` id), its payload in the blob.
struct ISec {
    pub id: u8,
    pub name: u32,
    pub at: usize,
    pub len: usize,
    pub out: u64, // a debug section: where its payload lands in its output section
}

// A function import of an input: module and field (`names` ids) and type (output type index).
struct IImp {
    pub module: u32,
    pub field: u32,
    pub ty: u32,
}

// A function body of an input: its type, its entry (size field first) in the blob, where it lands.
struct IFunc {
    pub ty: u32,
    pub at: usize,
    pub len: usize,
    pub index: u32, // the output function index
    pub out: u64, // the entry's offset in the output code section's payload
}

// A data segment of an input: name, alignment, bytes in the blob, its address once placed (NONE: a
// constructor table, not placed).
struct ISeg {
    pub name: u32,
    pub align: u32,
    pub at: usize,
    pub len: usize,
    pub addr: u32,
}

// A symbol of an input.
struct ISym {
    pub kind: u8,
    pub flags: u32,
    pub name: u32, // `names` id; 0 for a section symbol
    pub index: u32, // function, global, table or section index; data: segment
    pub off: u32, // data: offset in the segment
    pub size: u32,
    pub file: u32,
}

const G_UNDEF: u8 = 0;
const G_DEF: u8 = 1; // `sym` defines it
const G_IMPORT: u8 = 2; // a function import: `imp`
const G_SYNTH: u8 = 3; // the linker's: data address `addr`, or function `index`

struct GSym {
    pub name: u32,
    pub kind: u8,
    pub sym: u32,
    pub imp: u32, // `oimps` index
    pub addr: u32,
    pub index: u32, // output function index (a defined or imported function)
    pub weak_ref: bool, // every reference is weak
    pub strong: bool, // a strong reference
}

// An output function import.
struct OImp {
    pub module: u32,
    pub field: u32,
    pub ty: u32,
}

extend IFile as Copy {}
extend ISec as Copy {}
extend IImp as Copy {}
extend IFunc as Copy {}
extend ISeg as Copy {}
extend ISym as Copy {}
extend GSym as Copy {}
extend OImp as Copy {}

struct L {
    pub files: Vector<IFile>,
    pub paths: Vector<String>,
    pub secs: Vector<ISec>,
    pub types: Vector<Vector<u8>>, // output types: params then results, as encoded
    pub ftypes: Vector<u32>, // per input type: its output type
    pub fimps: Vector<IImp>,
    pub gimps: Vector<u32>,
    pub timps: Vector<u32>,
    pub funcs: Vector<IFunc>,
    pub segs: Vector<ISeg>,
    pub syms: Vector<ISym>,
    pub names: nm::Names,
    pub glob: Vector<u32>,
    pub gs: Vector<GSym>,
    pub oimps: Vector<OImp>,
    pub table: Vector<u32>, // the table's functions (output indices) from slot 1
    pub slot_of: Map<u32, u32>, // output function index -> its table slot
    pub ctors: Vector<u32>, // output function indices `__wasm_call_ctors` calls
    pub ctor_fn: u32, // `__wasm_call_ctors`'s output index
    pub ctor_ty: u32,
    pub nfuncs: u32, // imports plus bodies plus the ctor function
    pub sp: u32, // the stack pointer's initial value
    pub heap_base: u32,
    pub data_end: u32,
    pub data_lo: u32,
    pub err: String,
}

/// Link `o`. False with the reason in `err` when it fails.
pub fn link(o: &Opts, err: &mut String) bool {
    let mut l = L {
        files: Vector::<IFile>::new(),
        paths: Vector::<String>::new(),
        secs: Vector::<ISec>::new(),
        types: Vector::<Vector<u8>>::new(),
        ftypes: Vector::<u32>::new(),
        fimps: Vector::<IImp>::new(),
        gimps: Vector::<u32>::new(),
        timps: Vector::<u32>::new(),
        funcs: Vector::<IFunc>::new(),
        segs: Vector::<ISeg>::new(),
        syms: Vector::<ISym>::new(),
        names: nm::Names::with_capacity(1 << 20, 1 << 14),
        glob: Vector::<u32>::new(),
        gs: Vector::<GSym>::new(),
        oimps: Vector::<OImp>::new(),
        table: Vector::<u32>::new(),
        slot_of: Map::<u32, u32>::new(),
        ctors: Vector::<u32>::new(),
        ctor_fn: NONE,
        ctor_ty: NONE,
        nfuncs: 0,
        sp: 0,
        heap_base: 0,
        data_end: 0,
        data_lo: 0,
        err: String::new(),
    };
    let _ = l.names.intern("");
    let mut blob = Vector::<u8>::new();
    let ok = run(&mut l, o, &mut blob);
    if !ok {
        err.push_string(&l.err);
    }
    return ok;
}

fn run(l: &mut L, o: &Opts, blob: &mut Vector<u8>) bool {
    for i in 0..o.objs.len() {
        if !read_object(l, o.objs[i].as_str(), blob) {
            return false;
        }
    }
    let b = blob.as_slice();
    if !resolve(l) || !assign_functions(l, b) {
        return false;
    }
    layout_memory(l, o);
    let mut m = Vector::<u8>::new();
    if !write_module(l, o, b, &mut m) {
        return false;
    }
    if !lu::write(o.out.as_str(), m.as_slice(), 0o755) {
        l.err.format_into("cannot write '{}'", o.out.as_str());
        return false;
    }
    return true;
}

// ---- reading --------------------------------------------------------------------------------------------

fn rd_name<'a>(b: Slice<'a, u8>, p: &mut usize) str<'a> {
    let n = lu::read_uleb(b, p) as usize;
    let s = unsafe str::from_raw(b.as_ptr() + *p, n);
    *p += n;
    return s;
}

fn sleb(b: []u8, p: &mut usize) i64 {
    let mut r: i64 = 0;
    let mut sh: u32 = 0;
    // At most 10 bytes for 64 bits.
    loop {
        let c = b[*p];
        *p += 1;
        r |= (c & 0x7F) as i64 << sh as i64;
        sh += 7;
        if (c & 0x80) == 0 {
            if sh < 64 && (c & 0x40) != 0 {
                r |= -1i64 << sh as i64;
            }
            return r;
        }
    }
}

// The output index of type `enc` (added when new).
fn type_index(l: &mut L, enc: []u8) u32 {
    for i in 0..l.types.len() {
        if l.types.at(i).as_slice() == enc {
            return i as u32;
        }
    }
    let mut v = Vector::<u8>::new();
    v.extend_from_slice(enc);
    l.types.push(v);
    return (l.types.len() - 1) as u32;
}

fn read_object(l: &mut L, path: str, blob: &mut Vector<u8>) bool {
    let at = blob.len();
    if !lu::read_append(path, blob) {
        l.err.format_into("cannot read '{}'", path);
        return false;
    }
    let b = blob.as_slice();
    let end = b.len();
    if end - at < 8 || lu::r32(b, at) != 0x6D736100 || lu::r32(b, at + 4) != 1 {
        l.err.format_into("'{}' is not a wasm object", path);
        return false;
    }
    l.paths.push(String::from_str(path));
    let fi = l.files.len() as u32;
    let mut f = IFile {
        path: fi,
        at: at,
        sym0: l.syms.len() as u32,
        nsym: 0,
        type0: l.ftypes.len() as u32,
        imp0: l.fimps.len() as u32,
        nimp: 0,
        fn0: l.funcs.len() as u32,
        nfn: 0,
        seg0: l.segs.len() as u32,
        nseg: 0,
        sec0: l.secs.len() as u32,
        nsec: 0,
        gimp0: l.gimps.len() as u32,
        timp0: l.timps.len() as u32,
    };
    let mut p = at + 8;
    let mut linking: usize = 0;
    let mut linking_end: usize = 0;
    // Each step reads one section.
    while p < end {
        let id = b[p];
        p += 1;
        let len = lu::read_uleb(b, &mut p) as usize;
        let mut q = p;
        let mut name: u32 = 0;
        if id == 0 {
            let n = String::from_str(rd_name(b, &mut q));
            name = l.names.intern(n.as_str());
            if n.as_str() == "linking" {
                linking = q;
                linking_end = p + len;
            }
        }
        l.secs.push(ISec { id: id, name: name, at: q, len: p + len - q, out: 0 });
        f.nsec += 1;
        if id == 1 {
            let n = lu::read_uleb(b, &mut q);
            for _ in 0..n {
                q += 1; // 0x60
                let s = q;
                let np = lu::read_uleb(b, &mut q) as usize;
                q += np;
                let nr = lu::read_uleb(b, &mut q) as usize;
                q += nr;
                let t = type_index(l, b[s..q]);
                l.ftypes.push(t);
            }
        } else if id == 2 {
            let n = lu::read_uleb(b, &mut q);
            for _ in 0..n {
                let module = String::from_str(rd_name(b, &mut q));
                let field = String::from_str(rd_name(b, &mut q));
                let kind = b[q];
                q += 1;
                if kind == 0 {
                    let ty = lu::read_uleb(b, &mut q) as u32;
                    l.fimps.push(
                        IImp {
                            module: l.names.intern(module.as_str()),
                            field: l.names.intern(field.as_str()),
                            ty: l.ftypes[(f.type0 + ty) as usize],
                        },
                    );
                    f.nimp += 1;
                } else if kind == 1 {
                    l.timps.push(l.names.intern(field.as_str()));
                    q += 1;
                    let fl = lu::read_uleb(b, &mut q);
                    let _ = lu::read_uleb(b, &mut q);
                    if (fl & 1) != 0 {
                        let _ = lu::read_uleb(b, &mut q);
                    }
                } else if kind == 2 {
                    let fl = lu::read_uleb(b, &mut q);
                    let _ = lu::read_uleb(b, &mut q);
                    if (fl & 1) != 0 {
                        let _ = lu::read_uleb(b, &mut q);
                    }
                } else {
                    l.gimps.push(l.names.intern(field.as_str()));
                    q += 2;
                }
            }
        } else if id == 3 {
            let n = lu::read_uleb(b, &mut q);
            for _ in 0..n {
                let ty = lu::read_uleb(b, &mut q) as u32;
                l.funcs.push(IFunc { ty: l.ftypes[(f.type0 + ty) as usize], at: 0, len: 0, index: NONE, out: 0 });
                f.nfn += 1;
            }
        } else if id == 10 {
            let n = lu::read_uleb(b, &mut q);
            for k in 0..n as u32 {
                let s = q;
                let sz = lu::read_uleb(b, &mut q) as usize;
                q += sz;
                let fx = l.funcs.index_mut((f.fn0 + k) as usize);
                fx.at = s;
                fx.len = q - s;
            }
        } else if id == 11 {
            let n = lu::read_uleb(b, &mut q);
            for _ in 0..n {
                let flags = lu::read_uleb(b, &mut q);
                if flags != 0 {
                    l.err.format_into("'{}': a passive or indexed data segment", path);
                    return false;
                }
                // i32.const <offset> end
                q += 1;
                let _ = sleb(b, &mut q);
                q += 1;
                let sz = lu::read_uleb(b, &mut q) as usize;
                l.segs.push(ISeg { name: 0, align: 0, at: q, len: sz, addr: 0 });
                f.nseg += 1;
                q += sz;
            }
        }
        p += len;
    }
    if linking == 0 {
        l.err.format_into("'{}' has no linking section", path);
        return false;
    }
    // linking: version 2, then its subsections.
    let mut q = linking;
    if lu::read_uleb(b, &mut q) != 2 {
        l.err.format_into("'{}': a linking section of another version", path);
        return false;
    }
    while q < linking_end {
        let sub = b[q];
        q += 1;
        let slen = lu::read_uleb(b, &mut q) as usize;
        let send = q + slen;
        if sub == 8 {
            let n = lu::read_uleb(b, &mut q);
            for _ in 0..n {
                let kind = b[q];
                q += 1;
                let flags = lu::read_uleb(b, &mut q) as u32;
                let mut y = ISym { kind: kind, flags: flags, name: 0, index: 0, off: 0, size: 0, file: fi };
                if kind == K_DATA {
                    y.name = l.names.intern(rd_name(b, &mut q));
                    if (flags & F_UNDEFINED) == 0 {
                        y.index = lu::read_uleb(b, &mut q) as u32;
                        y.off = lu::read_uleb(b, &mut q) as u32;
                        y.size = lu::read_uleb(b, &mut q) as u32;
                    }
                } else if kind == K_SECTION {
                    y.index = lu::read_uleb(b, &mut q) as u32;
                } else {
                    y.index = lu::read_uleb(b, &mut q) as u32;
                    if (flags & F_UNDEFINED) == 0 || (flags & F_EXPLICIT_NAME) != 0 {
                        y.name = l.names.intern(rd_name(b, &mut q));
                    } else if kind == K_FUNC {
                        // An import's symbol takes the import's field as its name.
                        y.name = l.fimps[(f.imp0 + y.index) as usize].field;
                    } else if kind == K_GLOBAL {
                        y.name = l.gimps[(f.gimp0 + y.index) as usize];
                    } else {
                        y.name = l.timps[(f.timp0 + y.index) as usize];
                    }
                }
                l.syms.push(y);
                f.nsym += 1;
            }
        } else if sub == 5 {
            let n = lu::read_uleb(b, &mut q);
            for k in 0..n as u32 {
                let nmv = l.names.intern(rd_name(b, &mut q));
                let al = lu::read_uleb(b, &mut q) as u32;
                let _ = lu::read_uleb(b, &mut q);
                let sg = l.segs.index_mut((f.seg0 + k) as usize);
                sg.name = nmv;
                sg.align = al;
            }
        } else if sub == 6 {
            l.err.format_into("'{}': init functions in the linking section", path);
            return false;
        }
        q = send;
    }
    l.files.push(f);
    return true;
}

// ---- symbols --------------------------------------------------------------------------------------------

fn global(l: &mut L, id: u32) u32 {
    while l.glob.len() <= id as usize {
        l.glob.push(0);
    }
    if l.glob[id as usize] == 0 {
        l.gs.push(
            GSym { name: id, kind: G_UNDEF, sym: NONE, imp: NONE, addr: 0, index: NONE, weak_ref: true, strong: false },
        );
        l.glob[id as usize] = l.gs.len() as u32;
    }
    return l.glob[id as usize] - 1;
}

// The global symbol an input symbol names (NONE: a local one or a section).
fn gof(l: &L, k: u32) u32 {
    let y = l.syms[k as usize];
    if (y.flags & F_LOCAL) != 0 || y.kind == K_SECTION {
        return NONE;
    }
    return l.glob[y.name as usize] - 1;
}

// Enter the symbols: a strong definition beats a weak one, two strong ones are an error; an undefined
// function with a module other than `env` is an import of that module (a WASI call).
fn resolve(l: &mut L) bool {
    for fi in 0..l.files.len() {
        let f = l.files[fi];
        for k in f.sym0..f.sym0 + f.nsym {
            let y = l.syms[k as usize];
            if (y.flags & F_LOCAL) != 0 || y.kind == K_SECTION {
                continue;
            }
            let g = global(l, y.name);
            let mut gy = l.gs[g as usize];
            if (y.flags & F_UNDEFINED) != 0 {
                if (y.flags & F_WEAK) == 0 {
                    gy.weak_ref = false;
                }
                gy.strong = gy.strong || (y.flags & F_WEAK) == 0;
                if y.kind == K_FUNC && gy.kind == G_UNDEF {
                    let im = l.fimps[(f.imp0 + y.index) as usize];
                    if l.names.spell(im.module) != "env" {
                        gy.kind = G_IMPORT;
                        gy.imp = add_import(l, im);
                    }
                }
                l.gs[g as usize] = gy;
                continue;
            }
            if gy.kind == G_DEF {
                if (y.flags & F_WEAK) != 0 {
                    continue;
                }
                let prev = l.syms[gy.sym as usize];
                if (prev.flags & F_WEAK) == 0 {
                    l.err.format_into(
                        "duplicate symbol '{}' in '{}' and '{}'",
                        l.names.spell(y.name),
                        l.paths[prev.file as usize].as_str(),
                        l.paths[fi].as_str(),
                    );
                    return false;
                }
            }
            gy.kind = G_DEF;
            gy.sym = k;
            l.gs[g as usize] = gy;
        }
    }
    // The linker's own: the start of the heap, the end of the data, the constructors' caller; the stack
    // pointer and the table are the module's.
    let mut missing = String::new();
    let mut nmiss: usize = 0;
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        if gy.kind != G_UNDEF {
            continue;
        }
        let s = l.names.spell(gy.name);
        if s == "__heap_base" || s == "__data_end" || s == "__wasm_call_ctors" || s == "__stack_pointer" || s == "__indirect_function_table" || s == "__dso_handle" {
            l.gs.index_mut(g).kind = G_SYNTH;
            continue;
        }
        if gy.weak_ref {
            continue;
        }
        nmiss += 1;
        if nmiss <= 20 {
            missing.format_into("\n  {}", s);
        }
    }
    if nmiss != 0 {
        l.err.format_into("{} undefined symbol(s):{}", nmiss, missing.as_str());
        if nmiss > 20 {
            l.err.push_str("\n  ...");
        }
        return false;
    }
    return true;
}

fn add_import(l: &mut L, im: IImp) u32 {
    for i in 0..l.oimps.len() {
        if l.oimps[i].module == im.module && l.oimps[i].field == im.field {
            return i as u32;
        }
    }
    l.oimps.push(OImp { module: im.module, field: im.field, ty: im.ty });
    return (l.oimps.len() - 1) as u32;
}

// The output function indices: the imports, the bodies in input order, then `__wasm_call_ctors`; the
// constructors, from the `.init_array` segments' relocations.
fn assign_functions(l: &mut L, b: []u8) bool {
    let ni = l.oimps.len() as u32;
    for i in 0..l.funcs.len() {
        l.funcs.index_mut(i).index = ni + i as u32;
    }
    l.ctor_fn = ni + l.funcs.len() as u32;
    l.nfuncs = l.ctor_fn + 1;
    let empty: [u8; 2] = [0, 0];
    l.ctor_ty = type_index(l, empty);
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        if gy.kind == G_IMPORT {
            l.gs.index_mut(g).index = gy.imp;
        } else if gy.kind == G_DEF && l.syms[gy.sym as usize].kind == K_FUNC {
            let y = l.syms[gy.sym as usize];
            let f = l.files[y.file as usize];
            l.gs.index_mut(g).index = l.funcs[(f.fn0 + y.index - f.nimp) as usize].index;
        } else if gy.kind == G_SYNTH && l.names.spell(gy.name) == "__wasm_call_ctors" {
            l.gs.index_mut(g).index = l.ctor_fn;
        }
    }
    // The constructor tables, in input order.
    for fi in 0..l.files.len() {
        let f = l.files[fi];
        for s in f.sec0..f.sec0 + f.nsec {
            let sc = l.secs[s as usize];
            if sc.id != 0 || !l.names.spell(sc.name).starts_with("reloc.") {
                continue;
            }
            let mut q = sc.at;
            let target = lu::read_uleb(b, &mut q) as u32;
            if l.secs[(f.sec0 + target) as usize].id != 11 {
                continue;
            }
            let data = l.secs[(f.sec0 + target) as usize];
            let n = lu::read_uleb(b, &mut q);
            for _ in 0..n {
                let ty = b[q];
                q += 1;
                let off = lu::read_uleb(b, &mut q) as usize;
                let k = lu::read_uleb(b, &mut q) as u32;
                if w::has_addend(ty) {
                    let _ = sleb(b, &mut q);
                }
                let sg = seg_at(l, f, data.at + off);
                if sg != NONE && l.names.spell(l.segs[sg as usize].name).starts_with(".init_array") && ty == w::R_TABLE_INDEX_I32 {
                    let fx = func_index(l, f.sym0 + k);
                    l.ctors.push(fx);
                    l.segs.index_mut(sg as usize).addr = NONE;
                }
            }
        }
    }
    return true;
}

// The segment of file `f` that holds blob offset `at` (NONE: none).
fn seg_at(l: &L, f: IFile, at: usize) u32 {
    for s in f.seg0..f.seg0 + f.nseg {
        let sg = l.segs[s as usize];
        if at >= sg.at && at < sg.at + sg.len {
            return s;
        }
    }
    return NONE;
}

// The output function index input symbol `k` (a function) stands for.
fn func_index(l: &L, k: u32) u32 {
    let g = gof(l, k);
    if g != NONE {
        return l.gs[g as usize].index;
    }
    let y = l.syms[k as usize];
    let f = l.files[y.file as usize];
    return l.funcs[(f.fn0 + y.index - f.nimp) as usize].index;
}

// ---- memory ---------------------------------------------------------------------------------------------

// The order of the output segments: read-only data, data, zero-filled data.
fn seg_rank(n: str) u32 {
    if n.starts_with(".rodata") {
        return 0;
    }
    if n.starts_with(".bss") {
        return 2;
    }
    return 1;
}

// Place the stack and the segments: the stack first (`stack_first`) or after the data at wasm-ld's
// global base 1024, each segment on its alignment; the heap after both, on 16 bytes.
fn layout_memory(l: &mut L, o: &Opts) {
    let stack = if o.stack != 0 {
        o.stack as u32;
    } else {
        65536u32;
    };
    let mut at: u32 = 1024;
    if o.stack_first {
        at = stack;
        l.sp = stack;
    }
    l.data_lo = at;
    for rank in 0..3u32 {
        for s in 0..l.segs.len() {
            let sg = l.segs[s];
            if sg.addr == NONE || seg_rank(l.names.spell(sg.name)) != rank {
                continue;
            }
            let al = 1u32 << sg.align;
            at = at + al - 1 & ~(al - 1);
            l.segs.index_mut(s).addr = at;
            at += sg.len as u32;
        }
    }
    l.data_end = at;
    if !o.stack_first {
        at = at + 15 & ~15u32;
        at += stack;
        l.sp = at;
    }
    l.heap_base = at + 15 & ~15u32;
}

// The address of data symbol `k` (a weak undefined one: 0).
fn data_addr(l: &L, k: u32) u32 {
    let g = gof(l, k);
    let mut kk = k;
    if g != NONE {
        let gy = l.gs[g as usize];
        if gy.kind == G_SYNTH {
            let s = l.names.spell(gy.name);
            if s == "__heap_base" {
                return l.heap_base;
            }
            if s == "__data_end" {
                return l.data_end;
            }
            return 0;
        }
        if gy.kind != G_DEF {
            return 0;
        }
        kk = gy.sym;
    }
    let y = l.syms[kk as usize];
    let f = l.files[y.file as usize];
    return l.segs[(f.seg0 + y.index) as usize].addr + y.off;
}

// The table slot of function `fx` (added on first use; slot 0 is the null pointer).
fn slot(l: &mut L, fx: u32) u32 {
    let s = l.slot_of.get(&fx);
    if s.is_some() {
        return *s.unwrap();
    }
    l.table.push(fx);
    let n = l.table.len() as u32;
    let _ = l.slot_of.insert(fx, n);
    return n;
}

// ---- output ---------------------------------------------------------------------------------------------

fn put_uleb5(o: &mut Vector<u8>, at: usize, v: u32) {
    w::patch_uleb5(o, at, v);
}

fn put_sleb5(o: &mut Vector<u8>, at: usize, v: i32) {
    let mut x = v as i64;
    for i in 0..5usize {
        let mut c = (x & 0x7F) as u8;
        x = x >> 7;
        if i < 4 {
            c |= 0x80;
        }
        o[at + i] = c;
    }
}

// Where relocated blob offset `src` lands in its output: the code section's payload (`P_CODE`), the memory
// image (`P_DATA`, `usize::MAX` for a constructor table), or a debug section whose input payload at blob
// offset `tsat` lands at `base` (`P_DEBUG`).
const P_CODE: u8 = 0;
const P_DATA: u8 = 1;
const P_DEBUG: u8 = 2;

fn rel_pos(l: &L, mode: u8, base: usize, tsat: usize, src: usize) usize {
    if mode == P_CODE {
        return code_pos(l, src);
    }
    if mode == P_DATA {
        return data_pos(l, src);
    }
    return base + (src - tsat);
}

// Apply relocation section `sc` of file `f` to `out`, which holds its target's payload (`rel_pos`).
fn apply_rels(l: &mut L, f: IFile, b: []u8, sc: ISec, out: &mut Vector<u8>, mode: u8, base: usize) bool {
    let mut q = sc.at;
    let target = lu::read_uleb(b, &mut q) as u32;
    let tsec = l.secs[(f.sec0 + target) as usize];
    let n = lu::read_uleb(b, &mut q);
    for _ in 0..n {
        let ty = b[q];
        q += 1;
        let off = lu::read_uleb(b, &mut q) as usize;
        let k = lu::read_uleb(b, &mut q) as u32;
        let addend = if w::has_addend(ty) {
            sleb(b, &mut q);
        } else {
            0i64;
        };
        let src = tsec.at + off;
        let p = rel_pos(l, mode, base, tsec.at, src);
        if p == usize::MAX {
            continue;
        }
        if ty == w::R_FUNCTION_INDEX_LEB {
            let fx = func_index(l, f.sym0 + k);
            if fx == NONE {
                l.err.format_into(
                    "'{}': a call of undefined weak function '{}'",
                    l.paths[f.path as usize].as_str(),
                    l.names.spell(l.syms[(f.sym0 + k) as usize].name),
                );
                return false;
            }
            put_uleb5(out, p, fx);
        } else if ty == w::R_TYPE_INDEX_LEB {
            put_uleb5(out, p, l.ftypes[(f.type0 + k) as usize]);
        } else if ty == w::R_GLOBAL_INDEX_LEB {
            // The module's one global.
            if l.names.spell(l.syms[(f.sym0 + k) as usize].name) != "__stack_pointer" {
                l.err.format_into(
                    "'{}': global '{}'",
                    l.paths[f.path as usize].as_str(),
                    l.names.spell(l.syms[(f.sym0 + k) as usize].name),
                );
                return false;
            }
            put_uleb5(out, p, 0);
        } else if ty == w::R_TABLE_NUMBER_LEB {
            put_uleb5(out, p, 0);
        } else if ty == w::R_TABLE_INDEX_SLEB || ty == w::R_TABLE_INDEX_I32 {
            let s = slot(l, func_index(l, f.sym0 + k));
            if ty == w::R_TABLE_INDEX_SLEB {
                put_sleb5(out, p, s as i32);
            } else {
                lu::p32(out, p, s);
            }
        } else if ty == w::R_MEMORY_ADDR_LEB || ty == w::R_MEMORY_ADDR_SLEB || ty == w::R_MEMORY_ADDR_I32 {
            let a = (data_addr(l, f.sym0 + k) as i64 + addend) as u32;
            if ty == w::R_MEMORY_ADDR_LEB {
                put_uleb5(out, p, a);
            } else if ty == w::R_MEMORY_ADDR_SLEB {
                put_sleb5(out, p, a as i32);
            } else {
                lu::p32(out, p, a);
            }
        } else if ty == w::R_FUNCTION_OFFSET_I32 {
            let y = l.syms[(f.sym0 + k) as usize];
            let mut v: u64 = 0;
            if y.kind == K_FUNC && (y.flags & F_UNDEFINED) == 0 {
                v = l.funcs[(f.fn0 + y.index - f.nimp) as usize].out;
            }
            lu::p32(out, p, (v as i64 + addend) as u32);
        } else if ty == w::R_SECTION_OFFSET_I32 {
            let y = l.syms[(f.sym0 + k) as usize];
            let v = l.secs[(f.sec0 + y.index) as usize].out;
            lu::p32(out, p, (v as i64 + addend) as u32);
        } else {
            l.err.format_into("'{}': wasm relocation type {} is not supported", l.paths[f.path as usize].as_str(), ty);
            return false;
        }
    }
    return true;
}

fn section(m: &mut Vector<u8>, id: u8, body: &Vector<u8>) {
    m.push(id);
    w::uleb(m, body.len() as u64);
    m.extend_from_slice(body.as_slice());
}

fn custom(m: &mut Vector<u8>, name: str, body: &Vector<u8>) {
    let mut c = Vector::<u8>::new();
    w::name(&mut c, name);
    c.extend_from_slice(body.as_slice());
    section(m, 0, &c);
}

// Where blob offset `src` (in some body) lands in the output code section's payload.
fn code_pos(l: &L, src: usize) usize {
    // The bodies of one input are in order: a binary search over all of them would need them sorted by
    // blob offset, which input order gives.
    let mut lo: usize = 0;
    let mut hi = l.funcs.len();
    while lo < hi {
        let mid = (lo + hi) / 2;
        if l.funcs[mid].at + l.funcs[mid].len <= src {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    let fx = l.funcs[lo];
    return fx.out as usize + (src - fx.at);
}

// Where blob offset `src` (in some segment) lands in the memory image (`usize::MAX`: a constructor table).
fn data_pos(l: &L, src: usize) usize {
    let mut lo: usize = 0;
    let mut hi = l.segs.len();
    while lo < hi {
        let mid = (lo + hi) / 2;
        if l.segs[mid].at + l.segs[mid].len <= src {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    let sg = l.segs[lo];
    if sg.addr == NONE {
        return usize::MAX;
    }
    return (sg.addr - l.data_lo) as usize + (src - sg.at);
}

fn write_module(l: &mut L, o: &Opts, b: []u8, m: &mut Vector<u8>) bool {
    // The code: each body as its input wrote it (the relocated fields keep their 5-byte forms), then
    // `__wasm_call_ctors`.
    let mut code = Vector::<u8>::new();
    w::uleb(&mut code, (l.funcs.len() + 1) as u64);
    for i in 0..l.funcs.len() {
        let fx = l.funcs[i];
        l.funcs.index_mut(i).out = code.len() as u64;
        code.extend_from_slice(b[fx.at..fx.at + fx.len]);
    }
    let mut cb = Vector::<u8>::new();
    cb.push(0);
    for i in 0..l.ctors.len() {
        cb.push(w::CALL);
        w::uleb(&mut cb, l.ctors[i]);
    }
    cb.push(w::END);
    w::uleb(&mut code, cb.len() as u64);
    code.extend_from_slice(cb.as_slice());
    // The memory image of the data.
    let mut mem = Vector::<u8>::new();
    mem.resize_default((l.data_end - l.data_lo) as usize);
    for s in 0..l.segs.len() {
        let sg = l.segs[s];
        if sg.addr == NONE {
            continue;
        }
        let at = (sg.addr - l.data_lo) as usize;
        for q in 0..sg.len {
            mem[at + q] = b[sg.at + q];
        }
    }
    // The debug sections' output offsets, per name in input order.
    let mut dnames = Vector::<u32>::new();
    let mut dsize = Vector::<u64>::new();
    if !o.strip {
        for s in 0..l.secs.len() {
            let sc = l.secs[s];
            if sc.id != 0 || !l.names.spell(sc.name).starts_with(".debug_") {
                continue;
            }
            let mut d = NONE;
            for i in 0..dnames.len() {
                if dnames[i] == sc.name {
                    d = i as u32;
                }
            }
            if d == NONE {
                d = dnames.len() as u32;
                dnames.push(sc.name);
                dsize.push(0);
            }
            l.secs.index_mut(s).out = dsize[d as usize];
            dsize[d as usize] += sc.len as u64;
        }
    }
    let mut dbg = Vector::<Vector<u8>>::new();
    for i in 0..dnames.len() {
        let mut v = Vector::<u8>::with_capacity(dsize[i] as usize);
        for s in 0..l.secs.len() {
            let sc = l.secs[s];
            if sc.id == 0 && sc.name == dnames[i] {
                v.extend_from_slice(b[sc.at..sc.at + sc.len]);
            }
        }
        dbg.push(v);
    }
    // The relocations.
    for fi in 0..l.files.len() {
        let f = l.files[fi];
        for s in f.sec0..f.sec0 + f.nsec {
            let sc = l.secs[s as usize];
            if sc.id != 0 || !l.names.spell(sc.name).starts_with("reloc.") {
                continue;
            }
            let mut q = sc.at;
            let target = lu::read_uleb(b, &mut q) as u32;
            let ts = l.secs[(f.sec0 + target) as usize];
            let mut ok = true;
            if ts.id == 10 {
                ok = apply_rels(l, f, b, sc, &mut code, P_CODE, 0);
            } else if ts.id == 11 {
                ok = apply_rels(l, f, b, sc, &mut mem, P_DATA, 0);
            } else {
                for i in 0..dnames.len() {
                    if dnames[i] == ts.name {
                        ok = apply_rels(l, f, b, sc, dbg.index_mut(i), P_DEBUG, ts.out as usize);
                    }
                }
            }
            if !ok {
                return false;
            }
        }
    }
    let sid = l.names.find("_start");
    if sid < 0 || sid as usize >= l.glob.len() || l.glob[sid as usize] == 0 || l.gs[(l.glob[sid as usize] - 1) as usize].kind != G_DEF {
        l.err.push_str("undefined symbol: _start");
        return false;
    }
    let start = l.glob[sid as usize] - 1;
    // The module.
    m.extend_from_slice([0x00u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]);
    let mut s = Vector::<u8>::new();
    w::uleb(&mut s, l.types.len() as u64);
    for i in 0..l.types.len() {
        s.push(0x60);
        s.extend_from_slice(l.types.at(i).as_slice());
    }
    section(m, 1, &s);
    s.truncate(0);
    w::uleb(&mut s, l.oimps.len() as u64);
    for i in 0..l.oimps.len() {
        let im = l.oimps[i];
        w::name(&mut s, l.names.spell(im.module));
        w::name(&mut s, l.names.spell(im.field));
        s.push(0);
        w::uleb(&mut s, im.ty);
    }
    section(m, 2, &s);
    s.truncate(0);
    w::uleb(&mut s, (l.funcs.len() + 1) as u64);
    for i in 0..l.funcs.len() {
        w::uleb(&mut s, l.funcs[i].ty);
    }
    w::uleb(&mut s, l.ctor_ty);
    section(m, 3, &s);
    // The table: the null slot and every function a pointer names.
    let nslots = l.table.len() as u64 + 1;
    s.truncate(0);
    w::uleb(&mut s, 1);
    s.push(w::FUNCREF);
    s.push(1);
    w::uleb(&mut s, nslots);
    w::uleb(&mut s, nslots);
    section(m, 4, &s);
    // The memory: enough pages for the stack, the data and the heap's start.
    s.truncate(0);
    w::uleb(&mut s, 1);
    s.push(0);
    w::uleb(&mut s, (l.heap_base as u64 + 65535) / 65536);
    section(m, 5, &s);
    // The stack pointer.
    s.truncate(0);
    w::uleb(&mut s, 1);
    s.push(w::I32);
    s.push(1);
    s.push(w::I32_CONST);
    w::sleb(&mut s, l.sp);
    s.push(w::END);
    section(m, 6, &s);
    s.truncate(0);
    w::uleb(&mut s, 2);
    w::name(&mut s, "memory");
    s.push(2);
    w::uleb(&mut s, 0);
    w::name(&mut s, "_start");
    s.push(0);
    w::uleb(&mut s, l.gs[start as usize].index);
    section(m, 7, &s);
    if l.table.len() != 0 {
        s.truncate(0);
        w::uleb(&mut s, 1);
        s.push(0);
        s.push(w::I32_CONST);
        w::sleb(&mut s, 1);
        s.push(w::END);
        w::uleb(&mut s, l.table.len() as u64);
        for i in 0..l.table.len() {
            w::uleb(&mut s, l.table[i]);
        }
        section(m, 9, &s);
    }
    section(m, 10, &code);
    // The data: the image's runs, split at 32 zero bytes or more, the trailing zeros left out.
    let mut runs = Vector::<(u32, u32)>::new();
    let mut i: usize = 0;
    let n = mem.len();
    // Each step finds one run.
    while i < n {
        while i < n && mem[i] == 0 {
            i += 1;
        }
        if i == n {
            break;
        }
        let st = i;
        let mut z: usize = 0;
        while i < n && z < 32 {
            if mem[i] == 0 {
                z += 1;
            } else {
                z = 0;
            }
            i += 1;
        }
        runs.push((st as u32, (i - z) as u32));
    }
    s.truncate(0);
    w::uleb(&mut s, runs.len() as u64);
    for r in 0..runs.len() {
        let (a, e) = runs[r];
        s.push(0);
        s.push(w::I32_CONST);
        w::sleb(&mut s, l.data_lo + a);
        s.push(w::END);
        w::uleb(&mut s, e - a);
        s.extend_from_slice(mem[a as usize..e as usize]);
    }
    section(m, 11, &s);
    if !o.strip {
        // The names of the functions.
        let mut fnames = Vector::<(u32, u32)>::new();
        for g in 0..l.gs.len() {
            let gy = l.gs[g];
            if gy.index != NONE {
                fnames.push((gy.index, gy.name));
            }
        }
        for fi in 0..l.files.len() {
            let f = l.files[fi];
            for k in f.sym0..f.sym0 + f.nsym {
                let y = l.syms[k as usize];
                if y.kind == K_FUNC && (y.flags & F_LOCAL) != 0 && (y.flags & F_UNDEFINED) == 0 {
                    fnames.push((l.funcs[(f.fn0 + y.index - f.nimp) as usize].index, y.name));
                }
            }
        }
        fnames.sort();
        let mut sub = Vector::<u8>::new();
        let mut cnt: u64 = 0;
        let mut body = Vector::<u8>::new();
        for q in 0..fnames.len() {
            if q != 0 && fnames[q].0 == fnames[q - 1].0 {
                continue;
            }
            w::uleb(&mut body, fnames[q].0);
            w::name(&mut body, l.names.spell(fnames[q].1));
            cnt += 1;
        }
        w::uleb(&mut sub, cnt);
        sub.extend_from_slice(body.as_slice());
        let mut nsec = Vector::<u8>::new();
        nsec.push(1);
        w::uleb(&mut nsec, sub.len() as u64);
        nsec.extend_from_slice(sub.as_slice());
        custom(m, "name", &nsec);
        for d in 0..dnames.len() {
            custom(m, l.names.spell(dnames[d]), dbg.at(d));
        }
    }
    return true;
}
