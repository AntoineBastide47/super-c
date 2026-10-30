// The Mach-O object writer for arm64: one MH_OBJECT with one unnamed segment, a section per non-empty
// object section kind, the symbol table (locals, defined globals, then undefined ones) and the
// ARM64_RELOC_* relocations. A thread-local variable becomes its descriptor in __thread_vars (the
// variable's own symbol) and its initial value under `<name>$tlv$init`. C names take the `_` prefix.
import codegen::obj as ob;
import target::a64 as a;

const MH_MAGIC_64: u32 = 0xFEEDFACF;
const CPU_TYPE_ARM64: u32 = 0x0100000C;
const MH_OBJECT: u32 = 1;
const MH_SUBSECTIONS_VIA_SYMBOLS: u32 = 0x2000;
const LC_SEGMENT_64: u32 = 0x19;
const LC_SYMTAB: u32 = 0x2;
const LC_DYSYMTAB: u32 = 0xB;
const LC_BUILD_VERSION: u32 = 0x32;
const PLATFORM_MACOS: u32 = 1;
const MACOS_MIN: u32 = 0x000B0000; // 11.0: the first macOS on arm64

const S_REGULAR: u32 = 0;
const S_ZEROFILL: u32 = 1;
const S_CSTRING_LITERALS: u32 = 2;
const S_THREAD_LOCAL_REGULAR: u32 = 0x11;
const S_THREAD_LOCAL_ZEROFILL: u32 = 0x12;
const S_THREAD_LOCAL_VARIABLES: u32 = 0x13;
const S_ATTR_CODE: u32 = 0x80000400; // pure and some instructions
const S_ATTR_SOME_INSTRUCTIONS: u32 = 0x400;
const S_ATTR_PURE_INSTRUCTIONS: u32 = 0x80000000;

pub(package) const NONE32: u32 = 0xFFFFFFFF;
const N_EXT: u8 = 1;
const N_SECT: u8 = 0xE;
const N_PEXT: u8 = 0x10;
const N_NO_DEAD_STRIP: u32 = 0x20;

// The section types and attributes a `segment,section,type,attributes` name spells, as the assembler
// reads them.
const TYPES: [str; 12] = [
    "regular",
    "zerofill",
    "cstring_literals",
    "4byte_literals",
    "8byte_literals",
    "literal_pointers",
    "non_lazy_symbol_pointers",
    "lazy_symbol_pointers",
    "symbol_stubs",
    "mod_init_funcs",
    "mod_term_funcs",
    "coalesced",
];
const ATTRS: [str; 7] = [
    "pure_instructions",
    "no_toc",
    "strip_static_syms",
    "no_dead_strip",
    "live_support",
    "self_modifying_code",
    "debug",
];

const RT_UNSIGNED: u32 = 0;
const RT_BRANCH26: u32 = 2;
const RT_PAGE21: u32 = 3;
const RT_PAGEOFF12: u32 = 4;
const RT_GOT_PAGE21: u32 = 5;
const RT_GOT_PAGEOFF12: u32 = 6;
const RT_TLVP_PAGE21: u32 = 8;
const RT_TLVP_PAGEOFF12: u32 = 9;
const RT_ADDEND: u32 = 10;

// A Mach-O section: its object kind (or TV, the descriptors), names and flags.
const TV: u8 = 254;

fn wname(o: &mut Vector<u8>, s: str) {
    for i in 0..16usize {
        o.push(
            if i < s.len() {
                s.byte_at(i)
            } else {
                0
            },
        );
    }
}

/// The section and segment names and the flags of named section `spec` (`segment,section[,type[,attr+
/// ...]]`), holding `code` when a function is there; NONE32 for a type or attribute this writer does not
/// know. A code section without attributes holds pure instructions, as the C compiler marks it.
pub(package) fn named_flags<'a>(spec: str<'a>, code: bool, sect: &mut str<'a>, seg: &mut str<'a>) u32 {
    let mut parts = Vector::<str<'a>>::new();
    let mut at: usize = 0;
    for i in 0..spec.len() + 1 {
        if i == spec.len() || spec.byte_at(i) == b',' {
            parts.push(spec.slice(at, i));
            at = i + 1;
        }
    }
    let np = parts.len();
    if np < 2 || np > 4 {
        return NONE32;
    }
    *seg = parts[0];
    *sect = parts[1];
    let mut fl: u32 = S_REGULAR;
    if np > 2 {
        fl = NONE32;
        let ts: []str = TYPES;
        for t in 0..ts.len() {
            if parts[2] == ts[t] {
                fl = t as u32;
            }
        }
        if fl == NONE32 {
            return NONE32;
        }
    }
    if np > 3 {
        let al = parts[3];
        let mut a0: usize = 0;
        for i in 0..al.len() + 1 {
            if i == al.len() || al.byte_at(i) == b'+' {
                let w = al.slice(a0, i);
                a0 = i + 1;
                let mut bitv: u32 = 0;
                let as_: []str = ATTRS;
                for t in 0..as_.len() {
                    if w == as_[t] {
                        bitv = 0x80000000u32 >> t as u32;
                    }
                }
                if bitv == 0 {
                    return NONE32;
                }
                fl |= bitv;
            }
        }
    } else if code {
        fl |= S_ATTR_PURE_INSTRUCTIONS;
    }
    if code {
        fl |= S_ATTR_SOME_INSTRUCTIONS;
    }
    return fl;
}

// The section and segment names and flags of object section `k` of `o`.
fn sec_names<'a>(o: &'a ob::Obj, k: u8, sect: &mut str<'a>, seg: &mut str<'a>) u32 {
    if k >= ob::S_COUNT && k != TV {
        let s = &o.secs[k as usize];
        return named_flags(&s.name, s.code, sect, seg);
    }
    *seg = "__DATA";
    if k == ob::S_TEXT {
        *sect = "__text";
        *seg = "__TEXT";
        return S_ATTR_CODE;
    }
    if k == ob::S_CSTR {
        *sect = "__cstring";
        *seg = "__TEXT";
        return S_CSTRING_LITERALS;
    }
    if k == ob::S_RODATA {
        *sect = "__const";
        *seg = "__TEXT";
        return S_REGULAR;
    }
    if k == ob::S_RELRO {
        *sect = "__const";
        return S_REGULAR;
    }
    if k == ob::S_DATA {
        *sect = "__data";
        return S_REGULAR;
    }
    if k == ob::S_TDATA {
        *sect = "__thread_data";
        return S_THREAD_LOCAL_REGULAR;
    }
    if k == ob::S_BSS {
        *sect = "__bss";
        return S_ZEROFILL;
    }
    if k == ob::S_TBSS {
        *sect = "__thread_bss";
        return S_THREAD_LOCAL_ZEROFILL;
    }
    *sect = "__thread_vars";
    return S_THREAD_LOCAL_VARIABLES;
}

/// Write object `o` as a Mach-O arm64 object into `out`.
pub(package) fn write(o: &mut ob::Obj, out: &mut Vector<u8>) {
    // The functions' compact unwind entries, which the linker turns into `__unwind_info`: each one's
    // address, size and encoding, no personality and no language data.
    if o.frames.len() != 0 {
        let cu = o.own_section("__LD,__compact_unwind,regular,debug");
        let _ = o.align(cu, 3);
        for f in 0..o.frames.len() {
            let fr = o.frames[f];
            if fr.compact == 0 {
                continue;
            }
            let at = o.secs[cu as usize].bytes.len() as u32;
            let mut e = Vector::<u8>::with_capacity(32);
            ob::w64(&mut e, 0);
            ob::w32(&mut e, fr.size);
            ob::w32(&mut e, fr.compact);
            ob::w64(&mut e, 0);
            ob::w64(&mut e, 0);
            o.put(cu, &e);
            o.reloc(cu, a::R_ABS64, at, fr.sym, fr.off);
        }
    }
    // Thread-local variables: the descriptors section, the variable symbols moved onto it, their values
    // under new local symbols.
    let mut tv = Vector::<u8>::new();
    let mut tv_rel = Vector::<ob::ORel>::new();
    let ns0 = o.syms.len();
    let mut boot = NONE32;
    for k in 0..ns0 {
        let y = o.syms[k];
        if (y.flags & ob::SF_TLS) == 0 || y.sec == ob::NOSEC {
            continue;
        }
        if boot == NONE32 {
            boot = o.sym("_tlv_bootstrap");
        }
        let mut init = String::from_str(o.name_of(k as u32));
        init.push_str("$tlv$init");
        let ik = o.sym(&init);
        let iy = o.syms.index_mut(ik as usize);
        iy.sec = y.sec;
        iy.off = y.off;
        iy.size = y.size;
        iy.flags = 0;
        let at = tv.len() as u32;
        tv_rel.push(ob::ORel { sec: TV, kind: a::R_ABS64, off: at, sym: boot, addend: 0 });
        tv_rel.push(ob::ORel { sec: TV, kind: a::R_ABS64, off: at + 16, sym: ik, addend: 0 });
        for _ in 0..24 {
            tv.push(0);
        }
        let vy = o.syms.index_mut(k);
        vy.sec = TV;
        vy.off = at;
        vy.size = 24;
    }
    // The sections present, in kind order; the descriptors after the initialized ones, the zero-filled
    // ones (from `nfile` on) last.
    let ns = o.secs.len();
    let mut zf = Vector::<bool>::with_capacity(ns);
    for k in 0..ns {
        zf.push(zerofill(o, k as u8));
    }
    let mut kinds = Vector::<u8>::new();
    for k in 0..ns {
        if o.secs[k].size != 0 && !zf[k] {
            kinds.push(k as u8);
        }
    }
    if tv.len() != 0 {
        kinds.push(TV);
    }
    let nfile = kinds.len();
    for k in 0..ns {
        if o.secs[k].size != 0 && zf[k] {
            kinds.push(k as u8);
        }
    }
    let nsect = kinds.len() as u32;
    // Section number (1-based) of each kind.
    let mut secno = Vector::<u8>::new();
    for _ in 0..256 {
        secno.push(0);
    }
    for i in 0..kinds.len() {
        secno[kinds[i] as usize] = (i + 1) as u8;
    }
    // Addresses and file offsets.
    let hdr: u32 = 32;
    let seg_sz: u32 = 72 + 80 * nsect;
    let cmds: u32 = seg_sz + 24 + 24 + 80;
    // A section's file offset is the segment's plus its address, so the segment starts at the largest
    // alignment of a section with bytes.
    let mut addr = Vector::<u64>::new();
    let mut foff = Vector::<u32>::new();
    let mut va: u64 = 0;
    let mut fal: u64 = 1;
    for i in 0..kinds.len() {
        let k = kinds[i];
        let (size, al) = sec_size(o, &tv, k);
        let a = 1u64 << al as u64;
        va = va + a - 1 & ~(a - 1);
        addr.push(va);
        va += size;
        if i < nfile && a > fal {
            fal = a;
        }
    }
    let data_start = (hdr + cmds) as u64 + fal - 1 & ~(fal - 1);
    // An absolute pointer's addend is the bytes it relocates. An address in a debug section holds the
    // object's own address of its target and relocates against the target's section, as `dsymutil` maps
    // it. One pass also lists each section's relocations in order (`rat`, `rix`).
    let mut dbg = Vector::<bool>::new();
    dbg.resize_default(ns);
    for k in ob::S_COUNT as usize..ns {
        dbg[k] = o.secs[k].name.as_str().starts_with("__DWARF,");
    }
    let mut rat = Vector::<u32>::new();
    rat.resize_default(ns + 1);
    for r in 0..o.rels.len() {
        let x = o.rels[r];
        rat[x.sec as usize + 1] += 1;
        let v = if dbg[x.sec as usize] {
            let y = o.syms[x.sym as usize];
            assert(x.kind == a::R_ABS64 && y.sec != ob::NOSEC, "macho: a debug address of a function of the object");
            addr[(secno[y.sec as usize] - 1) as usize] + y.off + x.addend as u64
        } else if x.kind == a::R_ABS64 {
            x.addend as u64
        } else {
            continue;
        };
        let b = o.secs.index_mut(x.sec as usize);
        for j in 0..8u32 {
            b.bytes[(x.off + j) as usize] = (v >> (8 * j) as u64 & 0xFF) as u8;
        }
    }
    for k in 0..ns {
        rat[k + 1] += rat[k];
    }
    let mut rix = Vector::<u32>::new();
    rix.resize_default(o.rels.len());
    let mut rfill = rat.clone();
    for r in 0..o.rels.len() {
        let s = o.rels[r].sec as usize;
        rix[rfill[s] as usize] = r as u32;
        rfill[s] += 1;
    }
    let mut filesz: u64 = 0;
    for i in 0..kinds.len() {
        let k = kinds[i];
        if i >= nfile {
            foff.push(0);
        } else {
            let (size, _al) = sec_size(o, &tv, k);
            foff.push((data_start + addr[i]) as u32);
            filesz = addr[i] + size;
        }
    }
    // Relocations per section, then the symbol table and the strings.
    let mut rel_off = Vector::<u32>::new();
    let mut rel_n = Vector::<u32>::new();
    let mut relbytes = Vector::<u8>::new();
    // Symbol order: locals, defined globals, undefined; each group in symbol order.
    let mut order = Vector::<u32>::new();
    let mut nloc: u32 = 0;
    let mut next: u32 = 0;
    for pass in 0..3 {
        for k in 0..o.syms.len() {
            let y = o.syms[k];
            let grp = if y.sec == ob::NOSEC {
                2
            } else if (y.flags & ob::SF_GLOBAL) != 0 {
                1
            } else {
                0
            };
            if grp == pass {
                order.push(k as u32);
                if pass == 0 {
                    nloc += 1;
                } else if pass == 1 {
                    next += 1;
                }
            }
        }
    }
    let mut symix = Vector::<u32>::new();
    symix.resize_default(o.syms.len());
    for i in 0..order.len() {
        symix[order[i] as usize] = i as u32;
    }
    let reloc_start = data_start + filesz + 7 & ~7u64;
    for i in 0..kinds.len() {
        let k = kinds[i];
        rel_off.push((reloc_start + relbytes.len() as u64) as u32);
        let n0 = relbytes.len();
        if k == TV {
            for r in 0..tv_rel.len() {
                put_rel(&mut relbytes, tv_rel[r], &symix);
            }
        } else {
            for q in rat[k as usize]..rat[k as usize + 1] {
                let x = o.rels[rix[q as usize] as usize];
                if dbg[k as usize] {
                    // Against the section: its number, not extern.
                    ob::w32(&mut relbytes, x.off);
                    ob::w32(
                        &mut relbytes,
                        secno[o.syms[x.sym as usize].sec as usize] as u32 | 3u32 << 25 | RT_UNSIGNED << 28,
                    );
                } else {
                    put_rel(&mut relbytes, x, &symix);
                }
            }
        }
        rel_n.push(((relbytes.len() - n0) / 8) as u32);
    }
    let symoff = reloc_start + relbytes.len() as u64;
    let mut strs = Vector::<u8>::new();
    strs.push(b' ');
    strs.push(0);
    let mut nl = Vector::<u8>::new();
    for i in 0..order.len() {
        let k = order[i];
        let y = o.syms[k as usize];
        ob::w32(&mut nl, strs.len() as u32);
        strs.push(b'_');
        let s = o.name_of(k);
        for j in 0..s.len() {
            strs.push(s.byte_at(j));
        }
        strs.push(0);
        if y.sec == ob::NOSEC {
            nl.push(N_EXT);
            nl.push(0);
            ob::w16(&mut nl, 0);
            ob::w64(&mut nl, 0);
        } else {
            let si = secno[y.sec as usize];
            nl.push(
                N_SECT | if (y.flags & ob::SF_GLOBAL) != 0 {
                    N_EXT
                } else {
                    0
                } | if (y.flags & ob::SF_HIDDEN) != 0 {
                    N_PEXT
                } else {
                    0
                },
            );
            nl.push(si);
            ob::w16(
                &mut nl,
                if (y.flags & ob::SF_USED) != 0 {
                    N_NO_DEAD_STRIP
                } else {
                    0
                },
            );
            ob::w64(&mut nl, addr[(si - 1) as usize] + y.off);
        }
    }
    while strs.len() % 8 != 0 {
        strs.push(0);
    }
    let stroff = symoff + nl.len() as u64;
    // The header and load commands.
    out.truncate(0);
    out.reserve((stroff + strs.len() as u64) as usize);
    ob::w32(out, MH_MAGIC_64);
    ob::w32(out, CPU_TYPE_ARM64);
    ob::w32(out, 0);
    ob::w32(out, MH_OBJECT);
    ob::w32(out, 4);
    ob::w32(out, cmds);
    ob::w32(out, MH_SUBSECTIONS_VIA_SYMBOLS);
    ob::w32(out, 0);
    ob::w32(out, LC_SEGMENT_64);
    ob::w32(out, seg_sz);
    wname(out, "");
    ob::w64(out, 0);
    ob::w64(out, va);
    ob::w64(out, data_start);
    ob::w64(out, filesz);
    ob::w32(out, 7);
    ob::w32(out, 7);
    ob::w32(out, nsect);
    ob::w32(out, 0);
    for i in 0..kinds.len() {
        let k = kinds[i];
        let mut sect: str = "";
        let mut seg: str = "";
        let fl = sec_names(o, k, &mut sect, &mut seg);
        let (size, al) = sec_size(o, &tv, k);
        wname(out, sect);
        wname(out, seg);
        ob::w64(out, addr[i]);
        ob::w64(out, size);
        ob::w32(out, foff[i]);
        ob::w32(out, al);
        ob::w32(
            out,
            if rel_n[i] != 0 {
                rel_off[i]
            } else {
                0
            },
        );
        ob::w32(out, rel_n[i]);
        ob::w32(out, fl);
        ob::w32(out, 0);
        ob::w32(out, 0);
        ob::w32(out, 0);
    }
    ob::w32(out, LC_BUILD_VERSION);
    ob::w32(out, 24);
    ob::w32(out, PLATFORM_MACOS);
    ob::w32(out, MACOS_MIN);
    ob::w32(out, 0);
    ob::w32(out, 0);
    ob::w32(out, LC_SYMTAB);
    ob::w32(out, 24);
    ob::w32(out, symoff as u32);
    ob::w32(out, order.len() as u32);
    ob::w32(out, stroff as u32);
    ob::w32(out, strs.len() as u32);
    ob::w32(out, LC_DYSYMTAB);
    ob::w32(out, 80);
    ob::w32(out, 0);
    ob::w32(out, nloc);
    ob::w32(out, nloc);
    ob::w32(out, next);
    ob::w32(out, nloc + next);
    ob::w32(out, order.len() as u32 - nloc - next);
    for _ in 0..12 {
        ob::w32(out, 0);
    }
    // Section bytes.
    for i in 0..kinds.len() {
        let k = kinds[i];
        if i >= nfile {
            continue;
        }
        ob::pad(out, foff[i]);
        if k == TV {
            out.extend_from_slice(&tv);
        } else {
            let b = &o.secs[k as usize].bytes;
            out.extend_from_slice(b.as_slice());
        }
    }
    ob::pad(out, reloc_start);
    out.extend_from_slice(&relbytes);
    out.extend_from_slice(&nl);
    out.extend_from_slice(&strs);
}

// Whether section `k` of `o` is zero-filled: no bytes in the file.
fn zerofill(o: &ob::Obj, k: u8) bool {
    if k >= ob::S_COUNT && k != TV {
        let mut sect: str = "";
        let mut seg: str = "";
        let fl = named_flags(&o.secs[k as usize].name, false, &mut sect, &mut seg);
        return fl != NONE32 && (fl & 0xFF) == S_ZEROFILL;
    }
    return k == ob::S_BSS || k == ob::S_TBSS;
}

// The size and alignment of section kind `k` (`tv` the descriptors).
const fn sec_size(o: &ob::Obj, tv: &Vector<u8>, k: u8) (u64, u8) {
    if k == TV {
        return (tv.len() as u64, 3);
    }
    let s = &o.secs[k as usize];
    return (s.size, s.align_log2);
}

// One relocation entry (two for an addend) of `r`, its symbol numbered by `symix`.
fn put_rel(out: &mut Vector<u8>, r: ob::ORel, symix: &Vector<u32>) {
    let mut ty = RT_UNSIGNED;
    let mut pcrel: u32 = 0;
    let mut len: u32 = 2;
    if r.kind == a::R_BRANCH26 {
        ty = RT_BRANCH26;
        pcrel = 1;
    } else if r.kind == a::R_PAGE21 {
        ty = RT_PAGE21;
        pcrel = 1;
    } else if r.kind == a::R_PAGEOFF12 {
        ty = RT_PAGEOFF12;
    } else if r.kind == a::R_GOT_PAGE21 {
        ty = RT_GOT_PAGE21;
        pcrel = 1;
    } else if r.kind == a::R_GOT_PAGEOFF12 {
        ty = RT_GOT_PAGEOFF12;
    } else if r.kind == a::R_TLV_PAGE21 {
        ty = RT_TLVP_PAGE21;
        pcrel = 1;
    } else if r.kind == a::R_TLV_PAGEOFF12 {
        ty = RT_TLVP_PAGEOFF12;
    } else {
        len = 3;
    }
    if r.addend != 0 && ty != RT_UNSIGNED {
        ob::w32(out, r.off);
        ob::w32(out, r.addend as u32 & 0xFFFFFF | 2u32 << 25 | RT_ADDEND << 28);
    }
    ob::w32(out, r.off);
    ob::w32(out, symix[r.sym as usize] | pcrel << 24 | len << 25 | 1u32 << 27 | ty << 28);
}
