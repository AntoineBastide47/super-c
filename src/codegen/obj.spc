// The object a native backend fills and an object format writes: sections of bytes, symbols and
// relocations, in the terms every format shares. A relocation kind is the instruction set's (`R_*` of
// its encoder); the format writer maps it to its own type. Names are C names: the writer adds the
// format's prefix.
import utils::names as nm;

// Section kinds, in the order the writer lays them out.
pub(package) const S_TEXT: u8 = 0; // code
pub(package) const S_CSTR: u8 = 1; // NUL-terminated strings, merged by the linker
pub(package) const S_RODATA: u8 = 2; // read-only data without relocations
pub(package) const S_RELRO: u8 = 3; // read-only data with pointer relocations
pub(package) const S_DATA: u8 = 4;
pub(package) const S_TDATA: u8 = 5; // thread-local initial values
pub(package) const S_BSS: u8 = 6; // zero-filled: no bytes
pub(package) const S_TBSS: u8 = 7; // thread-local zero-filled
pub(package) const S_COUNT: u8 = 8;
pub(package) const NOSEC: u8 = 255;
/// The most sections an object holds: the kinds, then the named ones (`named`), then the ones the format
/// writers add (`own_section`: unwind and debug information).
pub(package) const S_MAX: u8 = 240;
const S_OWN: u8 = 8;

/// A section: its bytes (none for the zero-filled kinds), its size and alignment. A named section (past
/// the kinds) carries its format's spelling and whether it holds code.
pub(package) struct Section {
    pub(package) bytes: Vector<u8>,
    pub(package) size: u64,
    pub(package) align_log2: u8,
    pub(package) name: String,
    pub(package) code: bool,
}

/// Symbol flags.
pub(package) const SF_GLOBAL: u8 = 1;
pub(package) const SF_FUNC: u8 = 2;
pub(package) const SF_TLS: u8 = 4; // a thread-local variable: its section holds its initial value
pub(package) const SF_USED: u8 = 8; // the linker keeps it though nothing refers to it
pub(package) const SF_HIDDEN: u8 = 16; // a global symbol the linked image does not export

/// A symbol: defined in section `sec` at `off` (NOSEC: another object defines it).
pub(package) struct OSym {
    pub(package) name: u32, // `names` id
    pub(package) sec: u8,
    pub(package) flags: u8,
    pub(package) off: u64,
    pub(package) size: u64,
}

/// A relocation at byte `off` of section `sec`: the kind's field there holds symbol `sym` plus `addend`.
pub(package) struct ORel {
    pub(package) sec: u8,
    pub(package) kind: u8,
    pub(package) off: u32,
    pub(package) sym: u32,
    pub(package) addend: i64,
}

/// The unwind rules of one function: the function symbol, its code size, its DWARF call frame
/// instructions, `cfi_len` bytes at `cfi_at` of `Obj.cfi` (after the format's common entry, which states
/// the rules at the function's first byte) for ELF's `.eh_frame`, and its compact unwind encoding for
/// Mach-O's `__compact_unwind`, which may cover `size` bytes from byte `off` of the function alone (a
/// function whose frame its rare code alone sets up has two).
pub(package) struct OFrame {
    pub(package) sym: u32,
    pub(package) size: u32,
    pub(package) cfi_at: u32,
    pub(package) cfi_len: u32,
    pub(package) compact: u32,
    pub(package) off: u32,
}

/// A row of a function's line table: from byte `off` of the function its code comes from line `line`,
/// column `col` of package file `file` (`lir::ir::Package.files`).
pub(package) struct OLine {
    pub(package) off: u32,
    pub(package) file: u32,
    pub(package) line: u32,
    pub(package) col: u32,
}

/// A function the debug information describes: its symbol, its code size, its line rows
/// `Obj.lines[start .. start + n]`, and the byte its body starts at past the prologue.
pub(package) struct OFunc {
    pub(package) sym: u32,
    pub(package) size: u32,
    pub(package) start: u32,
    pub(package) n: u32,
    pub(package) body: u32,
}

/// A 32-bit offset into the section that defines the symbol (a debug section's start), plus the addend:
/// the format resolves it (Mach-O), or relocates it against the section (ELF, COFF).
pub(package) const R_SECOFF32: u8 = 200;

/// Append the low 16 bits of `v` to `o`, little-endian.
pub(package) fn w16(o: &mut Vector<u8>, v: u32) {
    o.push((v & 0xFF) as u8);
    o.push((v >> 8 & 0xFF) as u8);
}

/// Append `v` to `o`, little-endian.
pub(package) fn w32(o: &mut Vector<u8>, v: u32) {
    w16(o, v & 0xFFFF);
    w16(o, v >> 16);
}

/// Append `v` to `o`, little-endian.
pub(package) fn w64(o: &mut Vector<u8>, v: u64) {
    w32(o, v as u32);
    w32(o, (v >> 32) as u32);
}

extend OSym as Copy {}
extend ORel as Copy {}
extend OFrame as Copy {}
extend OLine as Copy {}
extend OFunc as Copy {}

pub(package) struct Obj {
    pub(package) secs: Vector<Section>,
    pub(package) syms: Vector<OSym>,
    pub(package) rels: Vector<ORel>,
    pub(package) frames: Vector<OFrame>,
    pub(package) cfi: Vector<u8>,
    pub(package) lines: Vector<OLine>,
    pub(package) funcs: Vector<OFunc>, // with debug information, every function
    pub(package) names: nm::Names,
    sym_of: Vector<u32>, // per name id, its symbol plus 1 (0: none)
}

extend Obj {
    pub(package) fn new() Obj {
        let mut o = Obj {
            secs: Vector::<Section>::with_capacity(S_COUNT as usize),
            syms: Vector::<OSym>::new(),
            rels: Vector::<ORel>::new(),
            frames: Vector::<OFrame>::new(),
            cfi: Vector::<u8>::new(),
            lines: Vector::<OLine>::new(),
            funcs: Vector::<OFunc>::new(),
            names: nm::Names::with_capacity(1 << 12, 1 << 8),
            sym_of: Vector::<u32>::new(),
        };
        for _ in 0..S_COUNT {
            o.secs.push(
                Section { bytes: Vector::<u8>::new(), size: 0, align_log2: 0, name: String::new(), code: false },
            );
        }
        return o;
    }

    /// The named section `spec` (its format's spelling), added when new; holding `code` when a function
    /// goes there. NOSEC when the object holds S_MAX - S_OWN sections already.
    pub(package) fn named(self: &mut Self, spec: str, code: bool) u8 {
        return self.named_in(spec, code, S_MAX - S_OWN);
    }

    /// A data section `spec` a format writer adds (unwind or debug information), from the room `named`
    /// leaves: at most S_OWN of them.
    pub(package) fn own_section(self: &mut Self, spec: str) u8 {
        let s = self.named_in(spec, false, S_MAX);
        assert(s != NOSEC, "obj: more sections of the writers' own than S_OWN");
        return s;
    }

    fn named_in(self: &mut Self, spec: str, code: bool, max: u8) u8 {
        for k in S_COUNT as usize..self.secs.len() {
            if self.secs[k].name.as_str() == spec {
                self.secs.index_mut(k).code = self.secs[k].code || code;
                return k as u8;
            }
        }
        if self.secs.len() >= max as usize {
            return NOSEC;
        }
        self.secs.push(
            Section { bytes: Vector::<u8>::new(), size: 0, align_log2: 0, name: String::from_str(spec), code: code },
        );
        return (self.secs.len() - 1) as u8;
    }

    /// The symbol named `name`, added undefined when new.
    pub(package) fn sym(self: &mut Self, name: str) u32 {
        let id = self.names.intern(name);
        while self.sym_of.len() <= id as usize {
            self.sym_of.push(0);
        }
        if self.sym_of[id as usize] == 0 {
            self.syms.push(OSym { name: id, sec: NOSEC, flags: 0, off: 0, size: 0 });
            self.sym_of[id as usize] = self.syms.len() as u32;
        }
        return self.sym_of[id as usize] - 1;
    }

    /// Align section `s` to `1 << al` (its alignment grows to cover it); the new end.
    pub(package) fn align(self: &mut Self, s: u8, al: u8) u64 {
        let sec = self.secs.index_mut(s as usize);
        if al > sec.align_log2 {
            sec.align_log2 = al;
        }
        let a = 1u64 << al as u64;
        let at = sec.size + a - 1 & ~(a - 1);
        if s != S_BSS && s != S_TBSS {
            while sec.bytes.len() as u64 < at {
                sec.bytes.push(0);
            }
        }
        sec.size = at;
        return at;
    }

    /// Define symbol `k` at the end of section `s`, aligned to `1 << al`, as the next `size` bytes;
    /// their offset. Bytes are the caller's to append (`put`), none in a zero-filled section.
    pub(package) fn define(self: &mut Self, k: u32, s: u8, al: u8, size: u64, flags: u8) u64 {
        let at = self.align(s, al);
        let y = self.syms.index_mut(k as usize);
        y.sec = s;
        y.off = at;
        y.size = size;
        y.flags = flags;
        if s == S_BSS || s == S_TBSS {
            self.secs.index_mut(s as usize).size = at + size;
        }
        return at;
    }

    /// Append `bytes` to section `s`.
    pub(package) fn put(self: &mut Self, s: u8, bytes: []u8) {
        let sec = self.secs.index_mut(s as usize);
        for i in 0..bytes.len() {
            sec.bytes.push(bytes[i]);
        }
        sec.size = sec.bytes.len() as u64;
    }

    /// Append zero bytes to section `s` up to size `n`.
    pub(package) fn pad_to(self: &mut Self, s: u8, n: u64) {
        let sec = self.secs.index_mut(s as usize);
        while sec.bytes.len() as u64 < n {
            sec.bytes.push(0);
        }
        sec.size = sec.bytes.len() as u64;
    }

    pub(package) fn reloc(self: &mut Self, s: u8, kind: u8, off: u32, sym: u32, addend: i64) {
        self.rels.push(ORel { sec: s, kind: kind, off: off, sym: sym, addend: addend });
    }

    /// The spelling of symbol `k`.
    pub(package) const fn name_of(self: &Self, k: u32) str {
        return self.names.spell(self.syms[k as usize].name);
    }
}

/// A file section's share of an object section, for the writers that split sections at their symbols
/// (`-ffunction-sections`, `-fdata-sections`): bytes `lo .. hi` of section `k`, named after symbol `sym`
/// when the section splits (NONE32: its whole, or the bytes before its first symbol), at the writer's
/// section number `hdr`.
pub(package) struct Part {
    pub(package) k: u8,
    pub(package) lo: u64,
    pub(package) hi: u64,
    pub(package) sym: u32,
    pub(package) hdr: u32,
}

extend Part as Copy {}

// Whether section `k` splits at its symbols under `split` (`SPLIT_*`): the code with the functions, the
// variables' kinds with the data; not the merged strings nor a named section.
fn splits(k: u8, split: u8) bool {
    if k == S_TEXT {
        return (split & SPLIT_FUNCS) != 0;
    }
    return (split & SPLIT_DATA) != 0 && k != S_CSTR && k < S_COUNT;
}

/// The parts of `o`'s non-empty sections, in section order, each split one at its symbols under `split`
/// (`SPLIT_*`); `first[k]` the first of section `k`'s (its parts run to `first[k + 1]`).
pub(package) fn parts_of(o: &Obj, split: u8, parts: &mut Vector<Part>, first: &mut Vector<u32>) {
    let mut starts = Vector::<u64>::new(); // offset << 32 | symbol
    first.resize_default(o.secs.len() + 1);
    for k in 0..o.secs.len() {
        first[k] = parts.len() as u32;
        let size = o.secs[k].size;
        if size == 0 {
            continue;
        }
        starts.truncate(0);
        if splits(k as u8, split) {
            for y in 0..o.syms.len() {
                let sy = o.syms[y];
                if sy.sec as usize == k && sy.off < size {
                    starts.push(sy.off << 32 | y as u64);
                }
            }
            starts.sort();
        }
        if starts.len() == 0 || starts[0] >> 32 != 0 {
            parts.push(Part { k: k as u8, lo: 0, hi: size, sym: NONE32, hdr: 0 });
        }
        for i in 0..starts.len() {
            let lo = starts[i] >> 32;
            if i > 0 && starts[i - 1] >> 32 == lo {
                continue;
            }
            // The section's previous part ends here.
            if parts.len() as u32 > first[k] {
                parts.index_mut(parts.len() - 1).hi = lo;
            }
            parts.push(Part { k: k as u8, lo: lo, hi: size, sym: (starts[i] & 0xFFFFFFFF) as u32, hdr: 0 });
        }
    }
    first[o.secs.len()] = parts.len() as u32;
}

/// The part of section `k` that holds byte `off`: the last one starting at or before it; NONE32 when the
/// section has no part (it is empty).
pub(package) fn part_at(parts: &Vector<Part>, first: &Vector<u32>, k: u8, off: u64) u32 {
    let mut lo = first[k as usize];
    let mut hi = first[k as usize + 1];
    if lo == hi {
        return NONE32;
    }
    while hi - lo > 1 {
        let mid = (lo + hi) / 2;
        if parts[mid as usize].lo <= off {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    return lo;
}

pub(package) const NONE32: u32 = 0xFFFFFFFF;
/// `split` (`lir::ir::Package.split`): functions in sections of their own, variables in sections of their
/// own.
pub(package) const SPLIT_FUNCS: u8 = 1;
pub(package) const SPLIT_DATA: u8 = 2;
