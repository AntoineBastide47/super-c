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

// What a section of the file holds: a part of the object's sections, a frame's UNWIND_INFO (`.xdata`) or
// function table entry (`.pdata`), or every frame's (`q` NONE32).
const CS_PART: u8 = 0;
const CS_XDATA: u8 = 1;
const CS_PDATA: u8 = 2;

// A section of the file: what it holds (`kind`, the part or frame `q`), its flags, size and relocation count;
// a COMDAT one's selection and, associative, the section number it goes with; where its bytes and its
// relocations start (`raw`, `rat`, 0: none).
struct CSec {
    pub(package) kind: u8,
    pub(package) q: u32,
    pub(package) flags: u32,
    pub(package) size: u64,
    pub(package) nrel: u32,
    pub(package) sel: u32,
    pub(package) assoc: u32,
    pub(package) raw: u32,
    pub(package) rat: u32,
}

extend CSec as Copy {}

// The name of file section `s` of `o`.
fn csec_name<'a>(o: &'a ob::Obj, parts: &Vector<ob::Part>, s: CSec) str<'a> {
    if s.kind == CS_XDATA {
        return ".xdata";
    }
    if s.kind == CS_PDATA {
        return ".pdata";
    }
    let k = parts[s.q as usize].k;
    if k >= ob::S_COUNT {
        return o.secs[k as usize].name.as_str();
    }
    if k == ob::S_TEXT {
        return ".text";
    }
    if k == ob::S_CSTR || k == ob::S_RODATA || k == ob::S_RELRO {
        return ".rdata";
    }
    if k == ob::S_DATA {
        return ".data";
    }
    if k == ob::S_TDATA {
        return ".tls$";
    }
    assert(k == ob::S_BSS, "coff: a thread-local section without bytes");
    return ".bss";
}

// The flags of object section `k` of `o`.
fn sec_flags(o: &ob::Obj, k: u8) u32 {
    let al = o.secs[k as usize].align_log2 as u32 + 1 << 20;
    if k >= ob::S_COUNT {
        if o.secs[k as usize].code {
            return SCN_CODE | SCN_EXEC | SCN_READ | al;
        }
        if o.secs[k as usize].name.as_str().starts_with(".debug_") {
            // Debug information: no part of the image.
            return SCN_DATA | SCN_DISCARDABLE | SCN_READ | al;
        }
        return SCN_DATA | SCN_READ | SCN_WRITE | al;
    }
    if k == ob::S_TEXT {
        return SCN_CODE | SCN_EXEC | SCN_READ | al;
    }
    if k == ob::S_CSTR || k == ob::S_RODATA || k == ob::S_RELRO {
        return SCN_DATA | SCN_READ | al;
    }
    if k == ob::S_DATA || k == ob::S_TDATA {
        return SCN_DATA | SCN_READ | SCN_WRITE | al;
    }
    assert(k == ob::S_BSS, "coff: a thread-local section without bytes");
    return SCN_BSS | SCN_READ | SCN_WRITE | al;
}

// An `.xdata` section of `size` bytes and a `.pdata` one of `n` entries after it, for frame `q` (NONE32:
// every frame), both COMDAT sections associative to section number `assoc` unless it is 0.
fn unwind_pair(secs: &mut Vector<CSec>, q: u32, size: u64, n: u32, assoc: u32) {
    let (fl, sel) = if assoc != 0 {
        (SCN_LNK_COMDAT, SEL_ASSOCIATIVE)
    } else {
        (0u32, 0u32)
    };
    let flags = SCN_DATA | SCN_READ | 3 << 20 | fl;
    secs.push(CSec { kind: CS_XDATA, q: q, flags: flags, size: size, nrel: 0, sel: sel, assoc: assoc, raw: 0, rat: 0 });
    secs.push(
        CSec {
            kind: CS_PDATA,
            q: q,
            flags: flags,
            size: 12 * n as u64,
            nrel: 3 * n,
            sel: sel,
            assoc: assoc,
            raw: 0,
            rat: 0,
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

// The bytes a name takes in the string table: none inline (up to 8 bytes), else the name and its NUL.
const fn str_len(name: str) u32 {
    return if name.len() <= 8 {
        0u32
    } else {
        name.len() as u32 + 1
    };
}

// The 8-byte name field of a symbol or section header: the name inline (up to 8 bytes), else what `long`
// writes for the string table offset `*soff`, which then moves past the name.
fn put_name(out: &mut Vector<u8>, soff: &mut u32, name: str, slash: bool) {
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
        return;
    }
    if slash {
        // "/<offset>" in decimal, NUL-padded, its first 8 bytes.
        let mut d: [u8; 10] = [0; 10];
        let mut n: usize = 0;
        let mut v = *soff;
        for _ in 0..10 {
            d[n] = b'0' + (v % 10) as u8;
            n += 1;
            v /= 10;
            if v == 0 {
                break;
            }
        }
        let w = n.min(7);
        out.push(b'/');
        for i in 0..w {
            out.push(d[n - 1 - i]);
        }
        for _ in w + 1..8 {
            out.push(0);
        }
    } else {
        ob::w32(out, 0);
        ob::w32(out, *soff);
    }
    *soff += name.len() as u32 + 1;
}

// A symbol table entry: the name, value, section number, type, storage class and auxiliary entry count.
fn put_sym(out: &mut Vector<u8>, soff: &mut u32, name: str, value: u32, sec: u32, ty: u32, class: u32, aux: u32) {
    put_name(out, soff, name, false);
    ob::w32(out, value);
    ob::w16(out, sec);
    ob::w16(out, ty);
    out.push(class as u8);
    out.push(aux as u8);
}

// A long name's bytes and its NUL onto the string table.
fn put_str(out: &mut Vector<u8>, name: str) {
    if name.len() > 8 {
        for i in 0..name.len() {
            out.push(name.byte_at(i));
        }
        out.push(0);
    }
}

// Zeros onto `out` up to file offset `off`.
fn pad_to(out: &mut Vector<u8>, off: u32) {
    while out.len() as u32 < off {
        out.push(0);
    }
}

/// Write object `o` as a COFF x86-64 object into `out`, its sections split at their symbols as `split`
/// asks (`ob::SPLIT_*`). The file is laid out first, then written once at its size.
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
    let per_fn = (split & ob::SPLIT_FUNCS) != 0;
    let mut secs = Vector::<CSec>::with_capacity(
        parts.len() + 2 * if per_fn {
            o.frames.len()
        } else {
            1
        },
    );
    for q in 0..parts.len() {
        let pt = parts[q];
        let mut fl = sec_flags(o, pt.k);
        let comdat = pt.sym != ob::NONE32 && !kept[q];
        if comdat {
            fl |= SCN_LNK_COMDAT;
        }
        secs.push(
            CSec {
                kind: CS_PART,
                q: q as u32,
                flags: fl,
                size: pt.hi - pt.lo,
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
                raw: 0,
                rat: 0,
            },
        );
        parts.index_mut(q).hdr = secs.len() as u32;
    }
    // Per frame, its `.xdata` and `.pdata` section numbers.
    let mut fxs = Vector::<u32>::with_capacity(o.frames.len());
    let mut fps = Vector::<u32>::with_capacity(o.frames.len());
    if o.frames.len() != 0 && !per_fn {
        let mut size: u64 = 0;
        for f in 0..o.frames.len() {
            size += o.frames[f].cfi_len;
        }
        unwind_pair(&mut secs, ob::NONE32, size, o.frames.len() as u32, 0);
    }
    for f in 0..o.frames.len() {
        if per_fn {
            let fr = o.frames[f];
            let q = sp[fr.sym as usize] as usize;
            let assoc = if secs[parts[q].hdr as usize - 1].sel != 0 {
                parts[q].hdr
            } else {
                0u32
            };
            unwind_pair(&mut secs, f as u32, fr.cfi_len, 1, assoc);
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
    // The relocations by file section, each section's in the object's order (`rord` from `rfrom[s]`).
    let mut rsec = Vector::<u32>::with_capacity(o.rels.len());
    for r in 0..o.rels.len() {
        let rl = o.rels[r];
        let s = parts[ob::part_at(&parts, &first, rl.sec, rl.off) as usize].hdr - 1;
        rsec.push(s);
        secs.index_mut(s as usize).nrel += 1;
    }
    let mut rfrom = Vector::<u32>::new();
    rfrom.resize_default(nsec as usize + 1);
    for s in 0..nsec as usize {
        rfrom[s + 1] = rfrom[s] + if secs[s].kind == CS_PART {
            secs[s].nrel
        } else {
            0
        };
    }
    let mut rord = Vector::<u32>::new();
    rord.resize_default(o.rels.len());
    {
        let mut at = Vector::<u32>::with_capacity(nsec as usize);
        for s in 0..nsec as usize {
            at.push(rfrom[s]);
        }
        for r in 0..o.rels.len() {
            let s = rsec[r] as usize;
            rord[at[s] as usize] = r as u32;
            at[s] += 1;
        }
    }
    // Layout: the header, the section headers, then per section its bytes (4-aligned; none for `.bss`) and
    // its relocations, then the symbol table and the string table.
    let mut at = 20 + 40 * nsec;
    let mut nstr: u32 = 4;
    for k in 0..nsec as usize {
        // The long name: once for the header, once for the section symbol.
        nstr += 2 * str_len(csec_name(o, &parts, secs[k]));
        let s = secs.index_mut(k);
        let n = if (s.flags & SCN_BSS) != 0 {
            0u32
        } else {
            s.size as u32
        };
        if n != 0 {
            at = at + 3 & ~3u32;
            s.raw = at;
        }
        at += n;
        // Past 65535 relocations the first entry holds their count, itself included.
        if s.nrel != 0 {
            s.rat = at;
        }
        at += 10 * (s.nrel + (s.nrel > 0xFFFF) as u32);
    }
    let symtab = at;
    let nsyms = 2 * nsec + o.syms.len() as u32;
    for k in 0..o.syms.len() {
        nstr += str_len(o.name_of(k as u32));
    }
    let size = symtab as usize + 18 * nsyms as usize + nstr as usize;
    out.truncate(0);
    out.reserve_exact(size);
    // The header, the section headers.
    ob::w16(out, 0x8664);
    ob::w16(out, nsec);
    ob::w32(out, 0);
    ob::w32(out, symtab);
    ob::w32(out, nsyms);
    ob::w16(out, 0);
    ob::w16(out, 0);
    let mut soff: u32 = 4;
    for k in 0..nsec as usize {
        let s = secs[k];
        put_name(out, &mut soff, csec_name(o, &parts, s), true);
        let ovf = s.nrel > 0xFFFF;
        ob::w32(out, 0);
        ob::w32(out, 0);
        ob::w32(out, s.size as u32);
        ob::w32(out, s.raw);
        ob::w32(out, s.rat);
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
    // Each section's bytes, its relocations' addends in them, then the relocations.
    let mut xat: u32 = 0;
    for k in 0..nsec as usize {
        let s = secs[k];
        if s.raw != 0 {
            pad_to(out, s.raw);
        }
        if s.kind == CS_PART {
            let pt = parts[s.q as usize];
            if s.raw != 0 {
                out.extend_from_slice(o.secs[pt.k as usize].bytes[pt.lo as usize..pt.hi as usize]);
            }
            for i in rfrom[k]..rfrom[k + 1] {
                let rl = o.rels[rord[i as usize] as usize];
                let f = s.raw + (rl.off as u64 - pt.lo) as u32;
                if rl.kind == x::R_ABS64 {
                    add_field(out, f, 8, rl.addend as u64);
                } else if rl.kind == x::R_SECREL || rl.kind == ob::R_SECOFF32 {
                    add_field(out, f, 4, rl.addend as u64);
                } else {
                    assert(rl.kind == x::R_PC32 || rl.kind == x::R_PLT32, "coff: a relocation kind ELF alone takes");
                    // REL32 is relative to the field's end: the addend's 4 bytes back.
                    add_field(out, f, 4, (rl.addend + 4) as u64);
                }
            }
            if s.nrel > 0xFFFF {
                put_rel(out, s.nrel + 1, 0, 0);
            }
            for i in rfrom[k]..rfrom[k + 1] {
                let rl = o.rels[rord[i as usize] as usize];
                let ty = if rl.kind == x::R_ABS64 {
                    REL_ADDR64
                } else if rl.kind == x::R_SECREL || rl.kind == ob::R_SECOFF32 {
                    REL_SECREL
                } else {
                    REL_REL32
                };
                put_rel(out, (rl.off as u64 - pt.lo) as u32, symix[rl.sym as usize], ty);
            }
        } else if s.kind == CS_XDATA {
            let (f0, f1) = if s.q == ob::NONE32 {
                (0usize, o.frames.len())
            } else {
                (s.q as usize, s.q as usize + 1)
            };
            for f in f0..f1 {
                let fr = o.frames[f];
                out.extend_from_slice(o.cfi[fr.cfi_at as usize..(fr.cfi_at + fr.cfi_len) as usize]);
            }
        } else {
            // A function table entry per frame: its start and end, and its UNWIND_INFO in its `.xdata`.
            let (f0, f1) = if s.q == ob::NONE32 {
                (0usize, o.frames.len())
            } else {
                (s.q as usize, s.q as usize + 1)
            };
            for f in f0..f1 {
                let fr = o.frames[f];
                ob::w32(out, fr.off);
                ob::w32(out, fr.off + fr.size);
                ob::w32(
                    out,
                    if per_fn {
                        0u32
                    } else {
                        xat
                    },
                );
                xat += fr.cfi_len;
            }
            if s.nrel > 0xFFFF {
                put_rel(out, s.nrel + 1, 0, 0);
            }
            for f in f0..f1 {
                let fr = o.frames[f];
                let at = 12 * (f - f0) as u32;
                put_rel(out, at, symix[fr.sym as usize], REL_ADDR32NB);
                put_rel(out, at + 4, symix[fr.sym as usize], REL_ADDR32NB);
                put_rel(out, at + 8, 2 * (fxs[f] - 1), REL_ADDR32NB);
            }
        }
    }
    assert(out.len() as u32 == symtab, "coff: the laid out size differs from the written one");
    // Section symbols, each with its auxiliary entry: the length and the relocation count.
    for k in 0..nsec as usize {
        let s = secs[k];
        put_sym(out, &mut soff, csec_name(o, &parts, s), 0, k as u32 + 1, 0, CLASS_STATIC, 1);
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
            &mut soff,
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
    assert(soff == nstr, "coff: the string table counted differs from the one named");
    // The string table: its size, then the long names in the order the offsets named them.
    ob::w32(out, nstr);
    for k in 0..nsec as usize {
        put_str(out, csec_name(o, &parts, secs[k]));
    }
    for k in 0..nsec as usize {
        put_str(out, csec_name(o, &parts, secs[k]));
    }
    for i in 0..order.len() {
        put_str(out, o.name_of((order[i] & 0xFFFFFFFF) as u32));
    }
    assert(out.len() == size, "coff: the file's size differs from its layout");
}
