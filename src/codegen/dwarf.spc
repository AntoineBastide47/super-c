// DWARF 4 line tables for an object: one compile unit whose functions (`Obj.funcs`) each have a
// subprogram entry, an address range and a line sequence (`Obj.lines`). Version 4 is what clang emits
// for the macOS deployment target (11.0, before 15) and what every target's debugger reads. The
// sections' bytes and their fixups are format-free (`build`); `attach` adds them to an ELF, COFF or
// Mach-O object, and the wasm writer takes them as custom sections.
import codegen::obj as ob;
import lir::ir as ir;

/// The debug sections.
pub const D_ABBREV: u8 = 0;
pub const D_INFO: u8 = 1;
pub const D_LINE: u8 = 2;
pub const D_RANGES: u8 = 3;
pub const D_COUNT: u8 = 4;

/// Fixup kinds: the address of symbol `sym` plus the addend (pointer-sized), or the offset of byte
/// `addend` of debug section `sym` (4 bytes), which a linker moves as it joins the sections.
pub const FX_ADDR: u8 = 0;
pub const FX_SECOFF: u8 = 1;

/// A field of debug section `sec` at byte `off` that the format relocates.
pub struct DFix {
    pub sec: u8,
    pub off: u32,
    pub kind: u8,
    pub sym: u32,
    pub addend: i64,
}

extend DFix as Copy {}

/// The debug sections' bytes and their fixups. A fixup's field holds zero bytes: the format places the
/// addend.
pub struct Dwarf {
    pub secs: Vector<Vector<u8>>,
    pub fixes: Vector<DFix>,
}

/// The names of the debug sections, in `D_*` order.
pub const NAMES: [str; 4] = [".debug_abbrev", ".debug_info", ".debug_line", ".debug_ranges"];

// Abbreviations: the compile unit, a local subprogram, a global one; each subprogram's form plus 2 without
// a file and line, for a function without rows.
const AB_CU: u8 = 1;
const AB_SUB: u8 = 2;
const AB_SUB_EXT: u8 = 3;
const ABBREVS: [u8; 76] = [
    // The unit: producer, language, name, line table, compile directory, base address 0, ranges.
    AB_CU,
    0x11,
    1,
    0x25,
    0x08,
    0x13,
    0x05,
    0x03,
    0x08,
    0x10,
    0x17,
    0x1B,
    0x08,
    0x11,
    0x01,
    0x55,
    0x17,
    0,
    0,
    // A subprogram: start, size, name, file and line.
    AB_SUB,
    0x2E,
    0,
    0x11,
    0x01,
    0x12,
    0x06,
    0x03,
    0x08,
    0x3A,
    0x0F,
    0x3B,
    0x0F,
    0,
    0,
    // A global one: also external.
    AB_SUB_EXT,
    0x2E,
    0,
    0x11,
    0x01,
    0x12,
    0x06,
    0x03,
    0x08,
    0x3A,
    0x0F,
    0x3B,
    0x0F,
    0x3F,
    0x19,
    0,
    0,
    // Without rows: no file and line.
    AB_SUB + 2,
    0x2E,
    0,
    0x11,
    0x01,
    0x12,
    0x06,
    0x03,
    0x08,
    0,
    0,
    AB_SUB_EXT + 2,
    0x2E,
    0,
    0x11,
    0x01,
    0x12,
    0x06,
    0x03,
    0x08,
    0x3F,
    0x19,
    0,
    0,
    0,
];

const DW_LANG_C11: u32 = 0x1D;
// The line program's special opcodes: a line step of LINE_BASE to LINE_BASE + LINE_RANGE - 1 and an
// address step together in one byte past the standard opcodes.
const LINE_BASE: i32 = -5;
const LINE_RANGE: u32 = 14;
const OPCODE_BASE: u32 = 13;
const STD_LENGTHS: [u8; 12] = [0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1];

fn uleb(o: &mut Vector<u8>, v0: u64) {
    let mut v = v0;
    // Seven bits a byte: at most 10 bytes.
    for _ in 0..10 {
        let b = (v & 0x7F) as u8;
        v >>= 7;
        if v == 0 {
            o.push(b);
            return;
        }
        o.push(b | 0x80);
    }
}

fn sleb(o: &mut Vector<u8>, v0: i64) {
    let mut v = v0;
    // Seven bits a byte: at most 10 bytes.
    for _ in 0..10 {
        let b = (v & 0x7F) as u8;
        v >>= 7;
        if v == 0 && (b & 0x40) == 0 || v == -1 && (b & 0x40) != 0 {
            o.push(b);
            return;
        }
        o.push(b | 0x80);
    }
}

fn cstr(o: &mut Vector<u8>, s: str) {
    for i in 0..s.len() {
        o.push(s.byte_at(i));
    }
    o.push(0);
}

// Overwrite the 4 bytes at `at` of `o` with `v`.
const fn patch32(o: &mut Vector<u8>, at: usize, v: u32) {
    for j in 0..4usize {
        o[at + j] = (v >> (8 * j) as u32 & 0xFF) as u8;
    }
}

extend Dwarf {
    /// The debug information of object `o`'s functions, files named by package `p`, compiled in
    /// directory `comp_dir`, with `ptr`-byte addresses.
    pub fn of_obj(o: &ob::Obj, p: &ir::Package, comp_dir: str, ptr: u32) Dwarf {
        let mut names = Vector::<str>::with_capacity(o.funcs.len());
        let mut globals = Vector::<bool>::with_capacity(o.funcs.len());
        for k in 0..o.funcs.len() {
            let y = o.funcs[k].sym;
            names.push(o.name_of(y));
            globals.push((o.syms[y as usize].flags & ob::SF_GLOBAL) != 0);
        }
        let files = file_names(p);
        return Dwarf::build(
            o.funcs.as_slice(),
            o.lines.as_slice(),
            names.as_slice(),
            globals.as_slice(),
            files.as_slice(),
            comp_dir,
            ptr,
        );
    }

    /// The debug information of functions `funcs` (the symbol of each is the address fixups' symbol),
    /// their rows in `lines`, named `names`, global where `globals` says, in package files named
    /// `files`, compiled in directory `comp_dir`, with `ptr`-byte addresses.
    pub fn build(
        funcs: []ob::OFunc,
        lines: []ob::OLine,
        names: []str,
        globals: []bool,
        files: []str,
        comp_dir: str,
        ptr: u32,
    ) Dwarf {
        let mut fx = Vector::<DFix>::new();
        let mut abbrev = Vector::<u8>::new();
        let ab: []u8 = ABBREVS;
        for i in 0..ab.len() {
            abbrev.push(ab[i]);
        }
        // The files the rows name, numbered from 1 in order of first use.
        let mut fidx = Vector::<u32>::new();
        let mut used = Vector::<u32>::new();
        for k in 0..lines.len() {
            let f = lines[k].file;
            while fidx.len() <= f as usize {
                fidx.push(0);
            }
            if fidx[f as usize] == 0 {
                used.push(f);
                fidx[f as usize] = used.len() as u32;
            }
        }
        let line = line_program(funcs, lines, files, &used, &fidx, ptr, &mut fx);
        // The unit, then a subprogram and an address range per function.
        let name = if used.len() != 0 {
            files[used[0] as usize];
        } else {
            "";
        };
        let mut info = Vector::<u8>::new();
        let mut ranges = Vector::<u8>::new();
        ob::w32(&mut info, 0);
        ob::w16(&mut info, 4);
        fix(&mut info, &mut fx, D_INFO, FX_SECOFF, D_ABBREV, 4);
        info.push(ptr as u8);
        uleb(&mut info, AB_CU);
        cstr(&mut info, "super-c");
        ob::w16(&mut info, DW_LANG_C11);
        cstr(&mut info, name);
        fix(&mut info, &mut fx, D_INFO, FX_SECOFF, D_LINE, 4);
        cstr(&mut info, comp_dir);
        for _ in 0..ptr {
            info.push(0);
        }
        fix(&mut info, &mut fx, D_INFO, FX_SECOFF, D_RANGES, 4);
        for k in 0..funcs.len() {
            let f = funcs[k];
            uleb(
                &mut info,
                if globals[k] {
                    AB_SUB_EXT;
                } else {
                    AB_SUB;
                } + if f.n == 0 {
                    2u8;
                } else {
                    0u8;
                },
            );
            fix(&mut info, &mut fx, D_INFO, FX_ADDR, f.sym, ptr);
            ob::w32(&mut info, f.size);
            cstr(&mut info, names[k]);
            if f.n != 0 {
                uleb(&mut info, fidx[lines[f.start as usize].file as usize]);
                uleb(&mut info, lines[f.start as usize].line);
            }
            fix(&mut ranges, &mut fx, D_RANGES, FX_ADDR, f.sym, ptr);
            fix(&mut ranges, &mut fx, D_RANGES, FX_ADDR, f.sym, ptr);
            // The range's end: one past the function's last byte.
            fx.index_mut(fx.len() - 1).addend = f.size;
        }
        info.push(0);
        let n = info.len() as u32;
        patch32(&mut info, 0, n - 4);
        for _ in 0..2 * ptr {
            ranges.push(0);
        }
        let mut secs = Vector::<Vector<u8>>::with_capacity(D_COUNT as usize);
        secs.push(abbrev);
        secs.push(info);
        secs.push(line);
        secs.push(ranges);
        return Dwarf { secs: secs, fixes: fx };
    }
}

// A fixup of `size` zero bytes at the end of section `sec` (bytes `b`): the address of symbol `sym`
// (FX_ADDR), or the offset of debug section `sym` (FX_SECOFF), plus no addend.
fn fix(b: &mut Vector<u8>, fx: &mut Vector<DFix>, sec: u8, kind: u8, sym: u32, size: u32) {
    fx.push(DFix { sec: sec, off: b.len() as u32, kind: kind, sym: sym, addend: 0 });
    for _ in 0..size {
        b.push(0);
    }
}

// The line program: a header naming the files `used` (package file ids into `files`, `fidx` their
// numbers), then a sequence per function.
fn line_program(
    funcs: []ob::OFunc,
    lines: []ob::OLine,
    files: []str,
    used: &Vector<u32>,
    fidx: &Vector<u32>,
    ptr: u32,
    fx: &mut Vector<DFix>,
) Vector<u8> {
    let mut l = Vector::<u8>::new();
    ob::w32(&mut l, 0);
    ob::w16(&mut l, 4);
    ob::w32(&mut l, 0);
    let hdr = l.len();
    l.push(1);
    l.push(1);
    l.push(1);
    l.push(LINE_BASE as u8);
    l.push(LINE_RANGE as u8);
    l.push(OPCODE_BASE as u8);
    let sl: []u8 = STD_LENGTHS;
    for i in 0..sl.len() {
        l.push(sl[i]);
    }
    // No include directories: each file by its own path, relative to the compile directory.
    l.push(0);
    for k in 0..used.len() {
        cstr(&mut l, files[used[k] as usize]);
        l.push(0);
        l.push(0);
        l.push(0);
    }
    l.push(0);
    let hl = (l.len() - hdr) as u32;
    patch32(&mut l, 6, hl);
    for k in 0..funcs.len() {
        let f = funcs[k];
        if f.n == 0 {
            continue;
        }
        // DW_LNE_set_address.
        l.push(0);
        uleb(&mut l, 1 + ptr as u64);
        l.push(2);
        fix(&mut l, fx, D_LINE, FX_ADDR, f.sym, ptr);
        let mut at: u32 = 0;
        let mut file: u32 = 1;
        let mut line: u32 = 1;
        let mut col: u32 = 0;
        for r in 0..f.n {
            let row = lines[(f.start + r) as usize];
            row_op(&mut l, row, fidx[row.file as usize], &mut at, &mut file, &mut line, &mut col, false);
            // The body starts past the prologue: a row there ends the prologue.
            let next = if r + 1 < f.n {
                lines[(f.start + r + 1) as usize].off;
            } else {
                f.size;
            };
            if r == 0 && f.body < next {
                let mut b = row;
                b.off = f.body;
                row_op(&mut l, b, fidx[row.file as usize], &mut at, &mut file, &mut line, &mut col, true);
            }
        }
        // DW_LNS_advance_pc to the end, DW_LNE_end_sequence.
        if f.size > at {
            l.push(2);
            uleb(&mut l, f.size - at);
        }
        l.push(0);
        l.push(1);
        l.push(1);
    }
    let n = l.len() as u32;
    patch32(&mut l, 0, n - 4);
    return l;
}

// The opcodes of a row at `r.off` for line `r.line`, column `r.col` of file number `fno`, from the state
// `at`, `file`, `line`, `col`; with `pend` it ends the prologue.
fn row_op(
    l: &mut Vector<u8>,
    r: ob::OLine,
    fno: u32,
    at: &mut u32,
    file: &mut u32,
    line: &mut u32,
    col: &mut u32,
    pend: bool,
) {
    if fno != *file {
        l.push(4);
        uleb(l, fno);
        *file = fno;
    }
    if r.col != *col {
        l.push(5);
        uleb(l, r.col);
        *col = r.col;
    }
    if pend {
        l.push(10);
    }
    let ad = r.off - *at;
    let ld = r.line as i64 - (*line) as i64;
    *at = r.off;
    *line = r.line;
    if ld >= LINE_BASE as i64 && ld < LINE_BASE as i64 + LINE_RANGE as i64 {
        let op = (ld - LINE_BASE as i64) as u64 + LINE_RANGE as u64 * ad as u64 + OPCODE_BASE as u64;
        if op <= 255 {
            l.push(op as u8);
            return;
        }
    }
    if ld != 0 {
        l.push(3);
        sleb(l, ld);
    }
    if ad != 0 {
        l.push(2);
        uleb(l, ad);
    }
    l.push(1);
}

const NONE32: u32 = 0xFFFFFFFF;

/// The paths of package `p`'s files, by file id.
pub fn file_names(p: &ir::Package) Vector<str> {
    let mut v = Vector::<str>::with_capacity(p.files.len());
    for k in 0..p.files.len() {
        v.push(p.spell(p.files[k]));
    }
    return v;
}

/// The line rows of function `sym` (`size` bytes, its body from byte `body`) into `o`: `rows` hold a
/// body code unit and a `lines` index of `b` each, a unit `unit` bytes, the body `nbody` units; a row
/// past the body (a branch the epilogue replaced) starts the epilogue. The prologue takes the first
/// row's location.
pub fn rows(o: &mut ob::Obj, b: &ir::Body, sym: u32, size: u32, body: u32, rows: &Vector<u64>, nbody: u32, unit: u32) {
    let start = o.lines.len() as u32;
    for k in 0..rows.len() {
        let w = (rows[k] >> 32) as u32;
        let l = b.lines[(rows[k] & 0xFFFFFFFF) as usize];
        let off = if k == 0 {
            0;
        } else if w < nbody {
            body + w * unit;
        } else {
            body + nbody * unit;
        };
        o.lines.push(ob::OLine { off: off, file: l.file, line: l.line, col: l.col });
    }
    o.funcs.push(ob::OFunc { sym: sym, size: size, start: start, n: o.lines.len() as u32 - start, body: body });
}

/// The formats `attach` writes into.
pub const F_MACHO: u8 = 0;
pub const F_ELF: u8 = 1;
pub const F_COFF: u8 = 2;

/// Add `d`'s sections to object `o` of format `fmt`, an address fixup as relocation kind `abs` of the
/// instruction set. Mach-O keeps the debug sections in its objects (the linker leaves them, `dsymutil`
/// reads them), so an offset into them needs no relocation; ELF and COFF linkers join them, so it
/// relocates against a local symbol at the section's start (`ob::R_SECOFF32`).
pub fn attach(o: &mut ob::Obj, d: &Dwarf, fmt: u8, abs: u8) {
    let names: []str = NAMES;
    let mut sec = Vector::<u8>::new();
    let mut start = Vector::<u32>::new();
    for k in 0..D_COUNT as usize {
        let spec = if fmt == F_MACHO {
            format("__DWARF,__{},regular,debug", names[k].slice(1, names[k].len()));
        } else {
            String::from_str(names[k]);
        };
        let s = o.own_section(spec.as_str());
        sec.push(s);
        let mut y = NONE32;
        if fmt != F_MACHO {
            y = o.sym(format("__sc_dw{}", names[k].slice(6, names[k].len())).as_str());
            let _ = o.define(y, s, 0, d.secs[k].len() as u64, 0);
        }
        start.push(y);
        o.put(s, d.secs[k].as_slice());
    }
    for k in 0..d.fixes.len() {
        let x = d.fixes[k];
        let s = sec[x.sec as usize];
        if x.kind == FX_ADDR {
            o.reloc(s, abs, x.off, x.sym, x.addend);
        } else if fmt != F_MACHO {
            o.reloc(s, ob::R_SECOFF32, x.off, start[x.sym as usize], x.addend);
        } else {
            let b = &mut o.secs.index_mut(s as usize).bytes;
            for j in 0..4u32 {
                b[(x.off + j) as usize] = (x.addend as u64 >> (8 * j) as u64 & 0xFF) as u8;
            }
        }
    }
}
