// The COFF object writer for x86-64 (Windows): the header, a section per non-empty object section kind
// and per named section, `.xdata` with each function's UNWIND_INFO and `.pdata` with its function table
// entry, the relocations (implicit addends, in the section bytes), the symbol table (a section symbol per
// section, then the object's symbols) and the string table. Under `-ffunction-sections` and
// `-fdata-sections` the code and the variables split at their symbols into COMDAT sections, as clang's
// are, each function's `.xdata` and `.pdata` associative to its code. Thread-local variables, all with their bytes,
// go to `.tls$`, which the linker merges into the image's `.tls` (native TLS, as clang and gcc 16
// built with it place them).
import codegen::obj as ob;
import target::x64 as x;

const SCN_CODE: u32 = 0x20;
const SCN_DATA: u32 = 0x40;
const SCN_BSS: u32 = 0x80;
const SCN_LNK_COMDAT: u32 = 0x1000;
const SCN_NRELOC_OVFL: u32 = 0x01000000;
const SCN_DISCARDABLE: u32 = 0x02000000;
const SCN_EXEC: u32 = 0x20000000;
const SCN_READ: u32 = 0x40000000;
const SCN_WRITE: u32 = 0x80000000;

const REL_ADDR64: u32 = 1;
const REL_ADDR32NB: u32 = 3;
const REL_REL32: u32 = 4;
const REL_SECREL: u32 = 11;

const CLASS_EXTERNAL: u32 = 2;
const CLASS_STATIC: u32 = 3;

const SEL_NODUPLICATES: u32 = 1;
const SEL_ANY: u32 = 2;
const SEL_ASSOCIATIVE: u32 = 5;

// A section of the file: its name, flags, bytes (none for `.bss`), size and relocations; a COMDAT one's
// selection and, associative, the section number it goes with.
struct CSec {
    pub(package) name: String,
    pub(package) flags: u32,
    pub(package) bytes: Vector<u8>,
    pub(package) size: u64,
    pub(package) rels: Vector<u8>, // 10-byte entries
    pub(package) nrel: u32,
    pub(package) sel: u32,
    pub(package) assoc: u32,
}

// The name and flags of object section `k` of `o`.
fn sec_info(o: &ob::Obj, k: u8, name: &mut String) u32 {
    let al = o.secs[k as usize].align_log2 as u32 + 1 << 20;
    if k >= ob::S_COUNT {
        name.push_str(&o.secs[k as usize].name);
        if o.secs[k as usize].code {
            return SCN_CODE | SCN_EXEC | SCN_READ | al;
        }
        if name.as_str().starts_with(".debug_") {
            // Debug information: no part of the image.
            return SCN_DATA | SCN_DISCARDABLE | SCN_READ | al;
        }
        return SCN_DATA | SCN_READ | SCN_WRITE | al;
    }
    if k == ob::S_TEXT {
        name.push_str(".text");
        return SCN_CODE | SCN_EXEC | SCN_READ | al;
    }
    if k == ob::S_CSTR || k == ob::S_RODATA || k == ob::S_RELRO {
        name.push_str(".rdata");
        return SCN_DATA | SCN_READ | al;
    }
    if k == ob::S_DATA {
        name.push_str(".data");
        return SCN_DATA | SCN_READ | SCN_WRITE | al;
    }
    if k == ob::S_TDATA {
        name.push_str(".tls$");
        return SCN_DATA | SCN_READ | SCN_WRITE | al;
    }
    assert(k == ob::S_BSS, "coff: a thread-local section without bytes");
    name.push_str(".bss");
    return SCN_BSS | SCN_READ | SCN_WRITE | al;
}

// Add an `.xdata` section of bytes `xdata` and an empty `.pdata` one after it, both COMDAT sections
// associative to section number `assoc` unless it is 0.
fn unwind_pair(secs: &mut Vector<CSec>, xdata: Vector<u8>, assoc: u32) {
    let (fl, sel) = if assoc != 0 {
        (SCN_LNK_COMDAT, SEL_ASSOCIATIVE)
    } else {
        (0u32, 0u32)
    };
    let n = xdata.len() as u64;
    secs.push(
        CSec {
            name: String::from_str(".xdata"),
            flags: SCN_DATA | SCN_READ | 3 << 20 | fl,
            bytes: xdata,
            size: n,
            rels: Vector::<u8>::new(),
            nrel: 0,
            sel: sel,
            assoc: assoc,
        },
    );
    secs.push(
        CSec {
            name: String::from_str(".pdata"),
            flags: SCN_DATA | SCN_READ | 3 << 20 | fl,
            bytes: Vector::<u8>::new(),
            size: 0,
            rels: Vector::<u8>::new(),
            nrel: 0,
            sel: sel,
            assoc: assoc,
        },
    );
}

// A relocation entry: at `at`, against symbol table index `sym`, of type `ty`.
fn put_rel(out: &mut Vector<u8>, at: u32, sym: u32, ty: u32) {
    ob::w32(out, at);
    ob::w32(out, sym);
    ob::w16(out, ty);
}

// Add `v` to the little-endian field of `n` bytes at `at` of `b` (an implicit addend).
const fn add_field(b: &mut Vector<u8>, at: u32, n: u32, v: u64) {
    let mut cur: u64 = 0;
    for q in 0..n {
        cur |= b[(at + q) as usize] as u64 << (8 * q) as u64;
    }
    cur = cur.wrapping_add(v);
    for q in 0..n {
        b[(at + q) as usize] = (cur >> (8 * q) as u64 & 0xFF) as u8;
    }
}

// A symbol table entry: the name (inline up to 8 bytes, else a string table offset), value, section
// number, type, storage class and auxiliary entry count.
fn put_sym(out: &mut Vector<u8>, strs: &mut Vector<u8>, name: str, value: u32, sec: u32, ty: u32, class: u32, aux: u32) {
    if name.len() <= 8 {
        for i in 0..8usize {
            out.push(
                if i < name.len() {
                    name.byte_at(i)
                } else {
                    0
                },
            );
        }
    } else {
        ob::w32(out, 0);
        ob::w32(out, strs.len() as u32);
        for i in 0..name.len() {
            strs.push(name.byte_at(i));
        }
        strs.push(0);
    }
    ob::w32(out, value);
    ob::w16(out, sec);
    ob::w16(out, ty);
    out.push(class as u8);
    out.push(aux as u8);
}

/// Write object `o` as a COFF x86-64 object into `out`, its sections split at their symbols as `split`
/// asks (`ob::SPLIT_*`).
pub(package) fn write(o: &ob::Obj, split: u8, out: &mut Vector<u8>) {
    // The file's sections: the object's non-empty ones (or their parts), then `.xdata` and `.pdata` for
    // the frames (a pair per frame when the code splits).
    let mut parts = Vector::<ob::Part>::new();
    let mut first = Vector::<u32>::new();
    ob::parts_of(o, split, &mut parts, &mut first);
    // Per symbol, its part (NONE32: undefined).
    let mut sp = Vector::<u32>::with_capacity(o.syms.len());
    for k in 0..o.syms.len() {
        let y = o.syms[k];
        sp.push(
            if y.sec == ob::NOSEC {
                ob::NONE32
            } else {
                ob::part_at(&parts, &first, y.sec, y.off)
            },
        );
    }
    // A part with a symbol the link must keep stays plain: the linker keeps every section but a COMDAT one
    // nothing reaches.
    let mut kept = Vector::<bool>::new();
    kept.resize_default(parts.len());
    for y in 0..o.syms.len() {
        let sy = o.syms[y];
        if (sy.flags & ob::SF_USED) != 0 {
            let q = sp[y];
            if q != ob::NONE32 {
                kept[q as usize] = true;
            }
        }
    }
    let mut secs = Vector::<CSec>::new();
    for q in 0..parts.len() {
        let pt = parts[q];
        let mut nm = String::new();
        let mut fl = sec_info(o, pt.k, &mut nm);
        let mut bytes = Vector::<u8>::new();
        if (fl & SCN_BSS) == 0 {
            for j in pt.lo as usize..pt.hi as usize {
                bytes.push(o.secs[pt.k as usize].bytes[j]);
            }
        }
        let comdat = pt.sym != ob::NONE32 && !kept[q];
        if comdat {
            fl |= SCN_LNK_COMDAT;
        }
        secs.push(
            CSec {
                name: nm,
                flags: fl,
                bytes: bytes,
                size: pt.hi - pt.lo,
                rels: Vector::<u8>::new(),
                nrel: 0,
                // A weak definition's section: the link keeps one of the objects' (`ob::SF_WEAK`).
                sel: if !comdat {
                    0u32
                } else if (o.syms[pt.sym as usize].flags & ob::SF_WEAK) != 0 {
                    SEL_ANY
                } else {
                    SEL_NODUPLICATES
                },
                assoc: 0,
            },
        );
        parts.index_mut(q).hdr = secs.len() as u32;
    }
    let per_fn = (split & ob::SPLIT_FUNCS) != 0;
    // Per frame, its `.xdata` and `.pdata` section numbers.
    let mut fxs = Vector::<u32>::new();
    let mut fps = Vector::<u32>::new();
    if o.frames.len() != 0 && !per_fn {
        let mut xdata = Vector::<u8>::new();
        for f in 0..o.frames.len() {
            let fr = o.frames[f];
            xdata.extend_from_slice(o.cfi[fr.cfi_at as usize..(fr.cfi_at + fr.cfi_len) as usize]);
        }
        unwind_pair(&mut secs, xdata, 0);
    }
    for f in 0..o.frames.len() {
        if per_fn {
            let fr = o.frames[f];
            let q = sp[fr.sym as usize] as usize;
            let mut xdata = Vector::<u8>::new();
            xdata.extend_from_slice(o.cfi[fr.cfi_at as usize..(fr.cfi_at + fr.cfi_len) as usize]);
            unwind_pair(
                &mut secs,
                xdata,
                if secs[parts[q].hdr as usize - 1].sel != 0 {
                    parts[q].hdr
                } else {
                    0u32
                },
            );
        }
        fxs.push(secs.len() as u32 - 1);
        fps.push(secs.len() as u32);
    }
    // Symbol table indexes: a section symbol (with its auxiliary entry) per file section, then the
    // object's symbols: in their order, or with the sections split each part's first one before its
    // others, as a COMDAT section's symbol is the first that names it.
    let nsec = secs.len() as u32;
    let mut order = Vector::<u64>::with_capacity(o.syms.len());
    for k in 0..o.syms.len() {
        let mut key: u64 = 0;
        if split != 0 {
            let q = sp[k];
            let lead = q != ob::NONE32 && parts[q as usize].sym == k as u32;
            key = q as u64 << 1 | (!lead) as u64;
        }
        order.push(key << 32 | k as u64);
    }
    if split != 0 {
        order.sort();
    }
    let mut symix = Vector::<u32>::new();
    symix.resize_default(o.syms.len());
    for i in 0..order.len() {
        symix[(order[i] & 0xFFFFFFFF) as usize] = 2 * nsec + i as u32;
    }
    // Relocations, their addends into the section bytes.
    for r in 0..o.rels.len() {
        let rl = o.rels[r];
        let q = ob::part_at(&parts, &first, rl.sec, rl.off) as usize;
        let s = parts[q].hdr as usize - 1;
        let at = (rl.off as u64 - parts[q].lo) as u32;
        let ty = if rl.kind == x::R_ABS64 {
            add_field(&mut secs.index_mut(s).bytes, at, 8, rl.addend as u64);
            REL_ADDR64
        } else if rl.kind == x::R_SECREL || rl.kind == ob::R_SECOFF32 {
            add_field(&mut secs.index_mut(s).bytes, at, 4, rl.addend as u64);
            REL_SECREL
        } else {
            assert(rl.kind == x::R_PC32 || rl.kind == x::R_PLT32, "coff: a relocation kind ELF alone takes");
            // REL32 is relative to the field's end: the addend's 4 bytes back.
            add_field(&mut secs.index_mut(s).bytes, at, 4, (rl.addend + 4) as u64);
            REL_REL32
        };
        put_rel(&mut secs.index_mut(s).rels, at, symix[rl.sym as usize], ty);
        secs.index_mut(s).nrel += 1;
    }
    // A function table entry per frame: its start and end, and its UNWIND_INFO in its `.xdata`.
    let mut xat: u32 = 0;
    for f in 0..o.frames.len() {
        let fr = o.frames[f];
        let xs = fxs[f];
        let p = secs.index_mut(fps[f] as usize - 1);
        let at = p.bytes.len() as u32;
        ob::w32(&mut p.bytes, fr.off);
        ob::w32(&mut p.bytes, fr.off + fr.size);
        ob::w32(
            &mut p.bytes,
            if per_fn {
                0u32
            } else {
                xat
            },
        );
        put_rel(&mut p.rels, at, symix[fr.sym as usize], REL_ADDR32NB);
        put_rel(&mut p.rels, at + 4, symix[fr.sym as usize], REL_ADDR32NB);
        put_rel(&mut p.rels, at + 8, 2 * (xs - 1), REL_ADDR32NB);
        p.nrel += 3;
        p.size = p.bytes.len() as u64;
        xat += fr.cfi_len;
    }
    // Layout: the header, the section headers, then per section its bytes and its relocations, then the
    // symbol table and the string table.
    let mut strs = Vector::<u8>::new();
    ob::w32(&mut strs, 0);
    let mut at = 20 + 40 * nsec;
    let mut raw = Vector::<u32>::with_capacity(nsec as usize);
    let mut rat = Vector::<u32>::with_capacity(nsec as usize);
    for k in 0..nsec as usize {
        // Bytes 4-aligned; relocations right after them.
        if secs[k].bytes.len() != 0 {
            at = at + 3 & ~3u32;
            raw.push(at);
        } else {
            raw.push(0);
        }
        at += secs[k].bytes.len() as u32;
        // Past 65535 relocations the first entry holds their count, itself included.
        let ovf = secs[k].nrel > 0xFFFF;
        rat.push(
            if secs[k].nrel != 0 {
                at
            } else {
                0
            },
        );
        at += 10 * (secs[k].nrel + ovf as u32);
    }
    let symtab = at;
    let nsyms = 2 * nsec + o.syms.len() as u32;
    // The header, at the start of `out` as ELF's and Mach-O's are.
    out.truncate(0);
    ob::w16(out, 0x8664);
    ob::w16(out, nsec);
    ob::w32(out, 0);
    ob::w32(out, symtab);
    ob::w32(out, nsyms);
    ob::w16(out, 0);
    ob::w16(out, 0);
    for k in 0..nsec as usize {
        let s = &secs[k];
        let nm = s.name.as_str();
        if nm.len() <= 8 {
            for i in 0..8usize {
                out.push(
                    if i < nm.len() {
                        nm.byte_at(i)
                    } else {
                        0
                    },
                );
            }
        } else {
            // "/<offset>" into the string table.
            let mut slash = format("/{}", strs.len());
            for i in 0..nm.len() {
                strs.push(nm.byte_at(i));
            }
            strs.push(0);
            while slash.len() < 8 {
                slash.push_byte(0);
            }
            for i in 0..8usize {
                out.push(slash.as_str().byte_at(i));
            }
        }
        let ovf = s.nrel > 0xFFFF;
        ob::w32(out, 0);
        ob::w32(out, 0);
        ob::w32(out, s.size as u32);
        ob::w32(out, raw[k]);
        ob::w32(out, rat[k]);
        ob::w32(out, 0);
        ob::w16(
            out,
            if ovf {
                0xFFFF
            } else {
                s.nrel
            },
        );
        ob::w16(out, 0);
        ob::w32(
            out,
            s.flags | if ovf {
                SCN_NRELOC_OVFL
            } else {
                0
            },
        );
    }
    for k in 0..nsec as usize {
        while out.len() as u32 < raw[k] {
            out.push(0);
        }
        out.extend_from_slice(&secs[k].bytes);
        if secs[k].nrel > 0xFFFF {
            put_rel(out, secs[k].nrel + 1, 0, 0);
        }
        out.extend_from_slice(&secs[k].rels);
    }
    assert(out.len() as u32 == symtab, "coff: the laid out size differs from the written one");
    // Section symbols, each with its auxiliary entry: the length and the relocation count.
    for k in 0..nsec as usize {
        let s = &secs[k];
        put_sym(out, &mut strs, &s.name, 0, k as u32 + 1, 0, CLASS_STATIC, 1);
        ob::w32(out, s.size as u32);
        ob::w16(
            out,
            if s.nrel > 0xFFFF {
                0xFFFF
            } else {
                s.nrel
            },
        );
        ob::w16(out, 0);
        ob::w32(out, 0);
        ob::w16(out, s.assoc);
        out.push(s.sel as u8);
        for _ in 0..3 {
            out.push(0);
        }
    }
    for i in 0..order.len() {
        let k = (order[i] & 0xFFFFFFFF) as usize;
        let y = o.syms[k];
        let q = sp[k];
        let global = y.sec == ob::NOSEC || (y.flags & ob::SF_GLOBAL) != 0;
        put_sym(
            out,
            &mut strs,
            o.name_of(k as u32),
            if q == ob::NONE32 {
                y.off as u32
            } else {
                (y.off - parts[q as usize].lo) as u32
            },
            if q == ob::NONE32 {
                0
            } else {
                parts[q as usize].hdr
            },
            if (y.flags & ob::SF_FUNC) != 0 {
                0x20
            } else {
                0
            },
            if global {
                CLASS_EXTERNAL
            } else {
                CLASS_STATIC
            },
            0,
        );
    }
    let n = strs.len() as u32;
    for q in 0..4u32 {
        strs[q as usize] = (n >> 8 * q & 0xFF) as u8;
    }
    out.extend_from_slice(&strs);
}
