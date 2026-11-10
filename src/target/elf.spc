// The ELF relocatable object writer for x86-64 and arm64: the header, a section per non-empty object section kind and
// per named section (with `-ffunction-sections` and `-fdata-sections` the code and the variables split at their symbols
// into a section each, `.text.<name>`), `.eh_frame` with one common entry and a frame entry per function, `.rela`
// sections, the symbol table (locals first) and the string tables. A thread-local variable is an STT_TLS symbol in
// `.tdata` or `.tbss`. `.note.GNU-stack` marks the stack non-executable.
import codegen::obj as ob;
import target::x64 as x;
import target::a64 as a;
import ast::ast as ast;

pub(package) const SHT_PROGBITS: u32 = 1;
pub(package) const SHT_SYMTAB: u32 = 2;
pub(package) const SHT_STRTAB: u32 = 3;
pub(package) const SHT_RELA: u32 = 4;
pub(package) const SHT_NOBITS: u32 = 8;
pub(package) const SHT_INIT_ARRAY: u32 = 14;
pub(package) const SHT_FINI_ARRAY: u32 = 15;
pub(package) const SHT_PREINIT_ARRAY: u32 = 16;
pub(package) const SHT_X86_64_UNWIND: u32 = 0x70000001;

pub(package) const SHF_WRITE: u64 = 1;
pub(package) const SHF_ALLOC: u64 = 2;
pub(package) const SHF_EXECINSTR: u64 = 4;
const SHF_MERGE: u64 = 0x10;
const SHF_STRINGS: u64 = 0x20;
const SHF_INFO_LINK: u64 = 0x40;
pub(package) const SHF_TLS: u64 = 0x400;
pub(package) const SHF_GNU_RETAIN: u64 = 0x200000;

const STB_LOCAL: u32 = 0;
const STB_GLOBAL: u32 = 1;
const STB_WEAK: u32 = 2;
const STT_NOTYPE: u32 = 0;
const STT_OBJECT: u32 = 1;
const STT_FUNC: u32 = 2;
const STT_SECTION: u32 = 3;
const STT_TLS: u32 = 6;
const STV_HIDDEN: u8 = 2;

pub(package) const R_X86_64_64: u32 = 1;
pub(package) const R_X86_64_32: u32 = 10;
pub(package) const R_X86_64_PC32: u32 = 2;
pub(package) const R_X86_64_PLT32: u32 = 4;
pub(package) const R_X86_64_TLSGD: u32 = 19;
pub(package) const R_X86_64_TPOFF32: u32 = 23;
pub(package) const R_X86_64_GOTPCRELX: u32 = 41;
pub(package) const R_X86_64_REX_GOTPCRELX: u32 = 42;

pub(package) const R_AARCH64_ABS64: u32 = 257;
pub(package) const R_AARCH64_ABS32: u32 = 258;
pub(package) const R_AARCH64_PREL32: u32 = 261;
pub(package) const R_AARCH64_ADR_PREL_PG_HI21: u32 = 275;
pub(package) const R_AARCH64_ADD_ABS_LO12_NC: u32 = 277;
pub(package) const R_AARCH64_LDST8_ABS_LO12_NC: u32 = 278;
pub(package) const R_AARCH64_JUMP26: u32 = 282;
pub(package) const R_AARCH64_CALL26: u32 = 283;
pub(package) const R_AARCH64_LDST16_ABS_LO12_NC: u32 = 284;
pub(package) const R_AARCH64_LDST32_ABS_LO12_NC: u32 = 285;
pub(package) const R_AARCH64_LDST64_ABS_LO12_NC: u32 = 286;
pub(package) const R_AARCH64_LDST128_ABS_LO12_NC: u32 = 299;
pub(package) const R_AARCH64_ADR_GOT_PAGE: u32 = 311;
pub(package) const R_AARCH64_LD64_GOT_LO12_NC: u32 = 312;
pub(package) const R_AARCH64_TLSDESC_ADR_PAGE21: u32 = 562;
pub(package) const R_AARCH64_TLSDESC_LD64_LO12: u32 = 563;
pub(package) const R_AARCH64_TLSDESC_ADD_LO12: u32 = 564;
pub(package) const R_AARCH64_TLSDESC_CALL: u32 = 569;

// The `.eh_frame` common entry: version 1, "zR" (0x7A 0x52), code alignment 1, data alignment -8, return address
// register 16 (rip), FDE pointers PC-relative signed 4 bytes; at a function's first byte the CFA is rsp + 8
// and the return address at CFA - 8. 24 bytes with its length.
const CIE: [u8; 24] = [20, 0, 0, 0, 0, 0, 0, 0, 1, 0x7A, 0x52, 0, 1, 0x78, 16, 1, 0x1B, 0x0C, 7, 8, 0x90, 1, 0, 0];

// arm64's: code alignment 4, data alignment -8, return address register 30 (x30); at a function's first
// instruction the CFA is sp + 0. 24 bytes with its length.
const CIE_A64: [u8; 24] = [20, 0, 0, 0, 0, 0, 0, 0, 1, 0x7A, 0x52, 0, 4, 0x78, 30, 1, 0x1B, 0x0C, 31, 0, 0, 0, 0, 0];

// The name, type and flags of object section `k` of `o`.
const fn sec_info<'a>(o: &'a ob::Obj, k: u8, name: &mut str<'a>, ty: &mut u32) u64 {
    *ty = SHT_PROGBITS;
    if k >= ob::S_COUNT {
        let s = &o.secs[k as usize];
        *name = s.name.as_str();
        if s.code {
            return SHF_ALLOC | SHF_EXECINSTR;
        }
        if name.starts_with(".debug_") {
            // Debug information: no part of the image.
            return 0;
        }
        if *name == ".init_array" {
            *ty = SHT_INIT_ARRAY;
        } else if *name == ".fini_array" {
            *ty = SHT_FINI_ARRAY;
        } else if *name == ".preinit_array" {
            *ty = SHT_PREINIT_ARRAY;
        }
        return SHF_ALLOC | SHF_WRITE;
    }
    if k == ob::S_TEXT {
        *name = ".text";
        return SHF_ALLOC | SHF_EXECINSTR;
    }
    if k == ob::S_CSTR {
        *name = ".rodata.str1.1";
        return SHF_ALLOC | SHF_MERGE | SHF_STRINGS;
    }
    if k == ob::S_RODATA {
        *name = ".rodata";
        return SHF_ALLOC;
    }
    if k == ob::S_RELRO {
        *name = ".data.rel.ro";
        return SHF_ALLOC | SHF_WRITE;
    }
    if k == ob::S_DATA {
        *name = ".data";
        return SHF_ALLOC | SHF_WRITE;
    }
    if k == ob::S_TDATA {
        *name = ".tdata";
        return SHF_ALLOC | SHF_WRITE | SHF_TLS;
    }
    *ty = SHT_NOBITS;
    if k == ob::S_BSS {
        *name = ".bss";
        return SHF_ALLOC | SHF_WRITE;
    }
    *name = ".tbss";
    return SHF_ALLOC | SHF_WRITE | SHF_TLS;
}

// The ELF type of relocation kind `k`.
const fn rel_type(k: u8) u32 {
    if k == x::R_PC32 {
        return R_X86_64_PC32;
    }
    if k == x::R_PLT32 {
        return R_X86_64_PLT32;
    }
    if k == x::R_GOTPCRELX {
        return R_X86_64_GOTPCRELX;
    }
    if k == x::R_REX_GOTPCRELX {
        return R_X86_64_REX_GOTPCRELX;
    }
    if k == x::R_TLSGD {
        return R_X86_64_TLSGD;
    }
    if k == x::R_TPOFF32 {
        return R_X86_64_TPOFF32;
    }
    assert(k == x::R_ABS64, "elf: a relocation kind COFF alone takes");
    return R_X86_64_64;
}

// The arm64 ELF type of relocation kind `k` on instruction `insn`: a branch's from B or BL, a page
// offset's from the instruction (ADD, or a load or store of its access size), as Mach-O's linker infers it.
const fn rel_type_a64(k: u8, insn: u32) u32 {
    if k == a::R_BRANCH26 {
        return ast::pick(insn >> 31 != 0, R_AARCH64_CALL26, R_AARCH64_JUMP26);
    }
    if k == a::R_PAGE21 {
        return R_AARCH64_ADR_PREL_PG_HI21;
    }
    if k == a::R_PAGEOFF12 {
        if (insn & 0x1F000000) == 0x11000000 {
            return R_AARCH64_ADD_ABS_LO12_NC;
        }
        // A load or store (unsigned offset): bits 31:30 the size, bit 26 a vector register, a 128-bit one
        // size 0 with opc 2 or 3.
        let size = insn >> 30;
        if (insn >> 26 & 1) != 0 && size == 0 && (insn >> 23 & 1) != 0 {
            return R_AARCH64_LDST128_ABS_LO12_NC;
        }
        return if size == 0 {
            R_AARCH64_LDST8_ABS_LO12_NC
        } else if size == 1 {
            R_AARCH64_LDST16_ABS_LO12_NC
        } else if size == 2 {
            R_AARCH64_LDST32_ABS_LO12_NC
        } else {
            R_AARCH64_LDST64_ABS_LO12_NC
        };
    }
    if k == a::R_GOT_PAGE21 {
        return R_AARCH64_ADR_GOT_PAGE;
    }
    if k == a::R_GOT_PAGEOFF12 {
        return R_AARCH64_LD64_GOT_LO12_NC;
    }
    if k == a::R_TLSDESC_PAGE21 {
        return R_AARCH64_TLSDESC_ADR_PAGE21;
    }
    if k == a::R_TLSDESC_LD64 {
        return R_AARCH64_TLSDESC_LD64_LO12;
    }
    if k == a::R_TLSDESC_ADD {
        return R_AARCH64_TLSDESC_ADD_LO12;
    }
    if k == a::R_TLSDESC_CALL {
        return R_AARCH64_TLSDESC_CALL;
    }
    assert(k == a::R_ABS64, "elf: an arm64 relocation kind ELF has no type for");
    return R_AARCH64_ABS64;
}

// The word at byte `off` of section `k` of `o`.
const fn word_at(o: &ob::Obj, k: u8, off: u32) u32 {
    let b = &o.secs[k as usize].bytes;
    let i = off as usize;
    return b[i] as u32 | b[i + 1] as u32 << 8 | b[i + 2] as u32 << 16 | b[i + 3] as u32 << 24;
}

// One section header.
struct Shdr {
    pub(package) name: u32,
    pub(package) ty: u32,
    pub(package) flags: u64,
    pub(package) off: u64,
    pub(package) size: u64,
    pub(package) link: u32,
    pub(package) info: u32,
    pub(package) align: u64,
    pub(package) entsize: u64,
}

extend Shdr as Copy {}

/// Write object `o` as an ELF relocatable object for arm64 (`a64`) or x86-64 into `out`, its sections split
/// at their symbols as `split` asks (`ob::SPLIT_*`). The layout comes first (each section's offset in the
/// data after the 64-byte header, the section names, the symbols), then the bytes, into `out` at its size.
pub(package) fn write(o: &ob::Obj, a64: bool, split: u8, out: &mut Vector<u8>) {
    let mut parts = Vector::<ob::Part>::new();
    let mut first = Vector::<u32>::new();
    ob::parts_of(o, split, &mut parts, &mut first);
    let np = parts.len();
    // A part with a symbol the link must keep stays through garbage collection.
    let mut retain = Vector::<bool>::new();
    retain.resize_default(np);
    for y in 0..o.syms.len() {
        let sy = o.syms[y];
        if (sy.flags & ob::SF_USED) != 0 && sy.sec != ob::NOSEC {
            let q = ob::part_at(&parts, &first, sy.sec, sy.off);
            if q != ob::NONE32 {
                retain[q as usize] = true;
            }
        }
    }
    // Each part's relocations, in object order: `byp[pfirst[q] .. pfirst[q + 1]]` are part `q`'s.
    let mut pfirst = Vector::<u32>::new();
    pfirst.resize_default(np + 1);
    let mut rpart = Vector::<u32>::with_capacity(o.rels.len());
    for r in 0..o.rels.len() {
        let x = o.rels[r];
        let q = ob::part_at(&parts, &first, x.sec, x.off);
        rpart.push(q);
        if q != ob::NONE32 {
            pfirst[q as usize + 1] += 1;
        }
    }
    let eh = o.frames.len() != 0;
    let mut nrela: u32 = eh as u32;
    for q in 0..np {
        nrela += (pfirst[q + 1] != 0) as u32;
        pfirst[q + 1] += pfirst[q];
    }
    let mut byp = Vector::<u32>::new();
    byp.resize_default(pfirst[np] as usize);
    let mut fill = Vector::<u32>::new();
    fill.extend_copy(&pfirst);
    for r in 0..o.rels.len() {
        let q = rpart[r];
        if q != ob::NONE32 {
            byp[fill[q as usize] as usize] = r as u32;
            fill[q as usize] += 1;
        }
    }
    // The section names and headers at their counts: the null header, a part's, `.note.GNU-stack`,
    // `.eh_frame`, a part's relocations', `.eh_frame`'s, `.symtab`, `.strtab`, `.shstrtab`.
    let mut nsh: usize = 1 + ".note.GNU-stack".len() + ".symtab".len() + ".strtab".len() + ".shstrtab".len() + 4;
    if eh {
        nsh += ".eh_frame".len() + ".rela.eh_frame".len() + 2;
    }
    for q in 0..np {
        let n = part_name_len(o, parts[q]) + 1;
        nsh += n;
        if pfirst[q + 1] != pfirst[q] {
            nsh += ".rela".len() + n;
        }
    }
    let mut shstr = Vector::<u8>::with_capacity(nsh);
    shstr.push(0);
    let nhdr = 1 + np + 1 + eh as usize + nrela as usize + 3;
    let mut hdrs = Vector::<Shdr>::with_capacity(nhdr);
    hdrs.push(Shdr { name: 0, ty: 0, flags: 0, off: 0, size: 0, link: 0, info: 0, align: 0, entsize: 0 });
    // `pos`: the data laid out so far, in header order.
    let mut pos: u64 = 0;
    for q in 0..np {
        let pt = parts[q];
        let s = &o.secs[pt.k as usize];
        let mut name: str = "";
        let mut ty: u32 = 0;
        let fl = sec_info(o, pt.k, &mut name, &mut ty) | ast::pick(retain[q], SHF_GNU_RETAIN, 0u64);
        let al = 1u64 << s.align_log2 as u64;
        let mut off: u64 = 0;
        if ty != SHT_NOBITS {
            pos = up(pos, al);
            off = pos;
            pos += pt.hi - pt.lo;
        }
        parts.index_mut(q).hdr = hdrs.len() as u32;
        hdrs.push(
            Shdr {
                name: add_part_name(&mut shstr, o, "", name, pt.sym),
                ty: ty,
                flags: fl,
                off: off,
                size: pt.hi - pt.lo,
                link: 0,
                info: 0,
                align: al,
                entsize: if ty == SHT_INIT_ARRAY || ty == SHT_FINI_ARRAY || ty == SHT_PREINIT_ARRAY {
                    8
                } else if (fl & SHF_MERGE) != 0 {
                    1
                } else {
                    0
                },
            },
        );
    }
    hdrs.push(
        Shdr {
            name: ob::put_str(&mut shstr, ".note.GNU-stack"),
            ty: SHT_PROGBITS,
            flags: 0,
            off: pos,
            size: 0,
            link: 0,
            info: 0,
            align: 1,
            entsize: 0,
        },
    );
    // .eh_frame: the common entry, then each function's entry with its PC-relative start; an entry is its
    // length field and that many bytes (`fde_len`).
    let mut eh_rels = Vector::<ob::ORel>::with_capacity(o.frames.len());
    let mut eh_sec: u32 = 0;
    if eh {
        pos = up(pos, 8);
        let start = pos;
        let cie: []u8 = ast::pick(a64, CIE_A64, CIE);
        pos += cie.len() as u64;
        for f in 0..o.frames.len() {
            let fr = o.frames[f];
            eh_rels.push(
                ob::ORel { sec: 0, kind: x::R_PC32, part: true, off: (pos - start + 8) as u32, sym: fr.sym, addend: 0 },
            );
            pos += 4 + fde_len(fr.cfi_len) as u64;
        }
        eh_sec = hdrs.len() as u32;
        hdrs.push(
            Shdr {
                name: ob::put_str(&mut shstr, ".eh_frame"),
                ty: ast::pick(a64, SHT_PROGBITS, SHT_X86_64_UNWIND),
                flags: SHF_ALLOC,
                off: start,
                size: pos - start,
                link: 0,
                info: 0,
                align: 8,
                entsize: 0,
            },
        );
    }
    // Symbols: locals, then defined globals and undefined ones, each group in symbol order. The tables at
    // their sizes: a name is its bytes and a 0, an entry 24 bytes (the null one, a section's, an object
    // symbol's).
    let mut nstr: usize = 1;
    for k in 0..o.syms.len() {
        nstr += o.name_of(k as u32).len() + 1;
    }
    let mut strtab = Vector::<u8>::with_capacity(nstr);
    strtab.push(0);
    let mut symix = Vector::<u32>::new();
    symix.resize_default(o.syms.len());
    let mut syms = Vector::<u8>::with_capacity(24 * (1 + np + o.syms.len()));
    syms.resize_default(syms.len() + 24);
    let mut nsym: u32 = 1;
    // A section symbol per part with frames or a relocation through it (`ob::ORel.part`): `.eh_frame` and
    // the jump tables refer to a function through it, as a relocation against a global symbol would make
    // the read-only section need one in a shared object.
    let mut secsym = Vector::<u32>::new();
    secsym.resize_default(np);
    for f in 0..o.frames.len() + o.rels.len() {
        let k = if f < o.frames.len() {
            o.frames[f].sym
        } else if o.rels[f - o.frames.len()].part {
            o.rels[f - o.frames.len()].sym
        } else {
            continue;
        };
        let y = o.syms[k as usize];
        let q = ob::part_at(&parts, &first, y.sec, y.off) as usize;
        if secsym[q] == 0 {
            secsym[q] = nsym;
            nsym += 1;
            ob::w32(&mut syms, 0);
            syms.push((STB_LOCAL << 4 | STT_SECTION) as u8);
            syms.push(0);
            ob::w16(&mut syms, parts[q].hdr);
            ob::w64(&mut syms, 0);
            ob::w64(&mut syms, 0);
        }
    }
    let mut first_global: u32 = 0;
    for pass in 0..2 {
        if pass == 1 {
            first_global = nsym;
        }
        for k in 0..o.syms.len() {
            let y = o.syms[k];
            let global = y.sec == ob::NOSEC || (y.flags & ob::SF_GLOBAL) != 0;
            if global != (pass == 1) {
                continue;
            }
            symix[k] = nsym;
            nsym += 1;
            ob::w32(&mut syms, ob::put_str(&mut strtab, o.name_of(k as u32)));
            let ty = if (y.flags & ob::SF_TLS) != 0 {
                STT_TLS
            } else if y.sec == ob::NOSEC {
                STT_NOTYPE
            } else if (y.flags & ob::SF_FUNC) != 0 {
                STT_FUNC
            } else {
                STT_OBJECT
            };
            let bind = if (y.flags & ob::SF_WEAK) != 0 {
                STB_WEAK
            } else if global {
                STB_GLOBAL
            } else {
                STB_LOCAL
            };
            syms.push((bind << 4 | ty) as u8);
            syms.push(ast::pick((y.flags & ob::SF_HIDDEN) != 0, STV_HIDDEN, 0u8));
            let q = if y.sec == ob::NOSEC {
                ob::NONE32
            } else {
                ob::part_at(&parts, &first, y.sec, y.off)
            };
            if q == ob::NONE32 {
                ob::w16(&mut syms, 0);
                ob::w64(&mut syms, y.off);
            } else {
                ob::w16(&mut syms, parts[q as usize].hdr);
                ob::w64(&mut syms, y.off - parts[q as usize].lo);
            }
            ob::w64(&mut syms, y.size);
        }
    }
    let symtab = hdrs.len() as u32 + nrela;
    // Relocation sections, each at the next multiple of 8 (a part without relocations pads too).
    let rela0 = hdrs.len();
    for q in 0..np {
        let pt = parts[q];
        pos = up(pos, 8);
        let n = pfirst[q + 1] - pfirst[q];
        if n == 0 {
            continue;
        }
        let mut name: str = "";
        let mut ty: u32 = 0;
        let _ = sec_info(o, pt.k, &mut name, &mut ty);
        hdrs.push(
            Shdr {
                name: add_part_name(&mut shstr, o, ".rela", name, pt.sym),
                ty: SHT_RELA,
                flags: SHF_INFO_LINK,
                off: pos,
                size: n * 24,
                link: symtab,
                info: pt.hdr,
                align: 8,
                entsize: 24,
            },
        );
        pos += n as u64 * 24;
    }
    if eh {
        pos = up(pos, 8);
        hdrs.push(
            Shdr {
                name: ob::put_str(&mut shstr, ".rela.eh_frame"),
                ty: SHT_RELA,
                flags: SHF_INFO_LINK,
                off: pos,
                size: (eh_rels.len() * 24) as u64,
                link: symtab,
                info: eh_sec,
                align: 8,
                entsize: 24,
            },
        );
        pos += (eh_rels.len() * 24) as u64;
    }
    assert(hdrs.len() as u32 == symtab, "elf: the relocation sections counted differ from those laid out");
    pos = up(pos, 8);
    hdrs.push(
        Shdr {
            name: ob::put_str(&mut shstr, ".symtab"),
            ty: SHT_SYMTAB,
            flags: 0,
            off: pos,
            size: syms.len() as u64,
            link: symtab + 1,
            info: first_global,
            align: 8,
            entsize: 24,
        },
    );
    pos += syms.len() as u64;
    hdrs.push(
        Shdr {
            name: ob::put_str(&mut shstr, ".strtab"),
            ty: SHT_STRTAB,
            flags: 0,
            off: pos,
            size: strtab.len() as u64,
            link: 0,
            info: 0,
            align: 1,
            entsize: 0,
        },
    );
    pos += strtab.len() as u64;
    let shstrndx = hdrs.len() as u32;
    let shname = ob::put_str(&mut shstr, ".shstrtab");
    hdrs.push(
        Shdr {
            name: shname,
            ty: SHT_STRTAB,
            flags: 0,
            off: pos,
            size: shstr.len() as u64,
            link: 0,
            info: 0,
            align: 1,
            entsize: 0,
        },
    );
    pos += shstr.len() as u64;
    pos = up(pos, 8);
    assert(
        shstr.len() == nsh && hdrs.len() == nhdr,
        "elf: the section names or headers counted differ from those laid out",
    );
    // The header, the data at offset 64, then the section headers.
    let size = 64 + pos as usize + 64 * hdrs.len();
    out.truncate(0);
    out.reserve_exact(size);
    // The identification: magic, 64 bits, little-endian, version 1, the System V ABI, padding.
    ob::w64(out, 0x00010102464C457F);
    ob::w64(out, 0);
    ob::w16(out, 1);
    ob::w16(out, ast::pick(a64, 183u32, 62));
    ob::w32(out, 1);
    ob::w64(out, 0);
    ob::w64(out, 0);
    ob::w64(out, 64 + pos);
    ob::w32(out, 0);
    ob::w16(out, 64);
    ob::w16(out, 0);
    ob::w16(out, 0);
    ob::w16(out, 64);
    ob::w16(out, hdrs.len() as u32);
    ob::w16(out, shstrndx);
    for q in 0..np {
        let pt = parts[q];
        let h = hdrs[pt.hdr as usize];
        if h.ty != SHT_NOBITS {
            ob::pad(out, 64 + h.off);
            out.extend_from_slice(o.secs[pt.k as usize].bytes[pt.lo as usize..pt.hi as usize]);
        }
    }
    if eh {
        ob::pad(out, 64 + hdrs[eh_sec as usize].off);
        let start = out.len();
        let cie: []u8 = ast::pick(a64, CIE_A64, CIE);
        out.extend_from_slice(cie);
        for f in 0..o.frames.len() {
            let fr = o.frames[f];
            let at = out.len() - start;
            // length, CIE pointer, pc_begin, pc_range, augmentation size 0, the rules, then padding.
            let len = fde_len(fr.cfi_len);
            ob::w32(out, len);
            ob::w32(out, (at + 4) as u32);
            ob::w32(out, 0);
            ob::w32(out, fr.size);
            out.push(0);
            out.extend_from_slice(o.cfi[fr.cfi_at as usize..(fr.cfi_at + fr.cfi_len) as usize]);
            for _ in 4 + 4 + 4 + 1 + fr.cfi_len..len {
                out.push(0);
            }
        }
    }
    let mut ri = rela0;
    for q in 0..np {
        let pt = parts[q];
        if pfirst[q + 1] == pfirst[q] {
            continue;
        }
        ob::pad(out, 64 + hdrs[ri].off);
        ri += 1;
        for j in pfirst[q]..pfirst[q + 1] {
            let x = o.rels[byp[j as usize] as usize];
            let abs32 = ast::pick(a64, R_AARCH64_ABS32, R_X86_64_32);
            let ty = if x.kind == ob::R_SECOFF32 {
                abs32
            } else if a64 {
                rel_type_a64(x.kind, word_at(o, x.sec, x.off))
            } else {
                rel_type(x.kind)
            };
            ob::w64(out, x.off as u64 - pt.lo);
            if x.part {
                let y = o.syms[x.sym as usize];
                let qs = ob::part_at(&parts, &first, y.sec, y.off) as usize;
                ob::w64(out, secsym[qs] as u64 << 32 | ty as u64);
                ob::w64(out, (x.addend + (y.off - parts[qs].lo) as i64) as u64);
            } else {
                ob::w64(out, symix[x.sym as usize] as u64 << 32 | ty as u64);
                ob::w64(out, x.addend as u64);
            }
        }
    }
    if eh {
        ob::pad(out, 64 + hdrs[ri].off);
        for r in 0..eh_rels.len() {
            let x = eh_rels[r];
            let y = o.syms[x.sym as usize];
            ob::w64(out, x.off);
            let pc32 = ast::pick(a64, R_AARCH64_PREL32, R_X86_64_PC32);
            let q = ob::part_at(&parts, &first, y.sec, y.off) as usize;
            ob::w64(out, secsym[q] as u64 << 32 | pc32 as u64);
            ob::w64(out, y.off - parts[q].lo);
        }
    }
    ob::pad(out, 64 + hdrs[symtab as usize].off);
    out.extend_from_slice(&syms);
    out.extend_from_slice(&strtab);
    out.extend_from_slice(&shstr);
    ob::pad(out, 64 + pos);
    for i in 0..hdrs.len() {
        let h = hdrs[i];
        ob::w32(out, h.name);
        ob::w32(out, h.ty);
        ob::w64(out, h.flags);
        ob::w64(out, 0);
        ob::w64(
            out,
            if i == 0 {
                0
            } else {
                64 + h.off
            },
        );
        ob::w64(out, h.size);
        ob::w32(out, h.link);
        ob::w32(out, h.info);
        ob::w64(out, h.align);
        ob::w64(out, h.entsize);
    }
    assert(out.len() == size, "elf: the object written differs from its layout");
}

// `p` rounded up to a multiple of `al` (a power of two).
const fn up(p: u64, al: u64) u64 {
    return p + al - 1 & ~(al - 1);
}

// The bytes after the length field of a frame entry with `cfi` bytes of rules: CIE pointer, pc_begin,
// pc_range, augmentation size 0 and the rules, padded so the entry with its length field is a multiple of 8.
const fn fde_len(cfi: u32) u32 {
    let n = 4 + 4 + 4 + 1 + cfi;
    return (n + 4 + 7 & ~7u32) - 4;
}

// The bytes of part `pt`'s section name: its section's name, then `.` and its symbol's when it has one.
const fn part_name_len(o: &ob::Obj, pt: ob::Part) usize {
    let mut name: str = "";
    let mut ty: u32 = 0;
    let _ = sec_info(o, pt.k, &mut name, &mut ty);
    return if pt.sym != ob::NONE32 {
        name.len() + 1 + o.name_of(pt.sym).len()
    } else {
        name.len()
    };
}

// Append `pre`, `name`, then `.` and symbol `sym`'s name when it is one, and a NUL to string table `t`; its
// offset.
fn add_part_name(t: &mut Vector<u8>, o: &ob::Obj, pre: str, name: str, sym: u32) u32 {
    let at = t.len() as u32;
    push_bytes(t, pre);
    push_bytes(t, name);
    if sym != ob::NONE32 {
        t.push(b'.');
        push_bytes(t, o.name_of(sym));
    }
    t.push(0);
    return at;
}

// Append the bytes of `s` to `t`.
fn push_bytes(t: &mut Vector<u8>, s: str) {
    for i in 0..s.len() {
        t.push(s.byte_at(i));
    }
}
