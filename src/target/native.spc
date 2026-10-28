// The native backends' entry: an object of LIR functions and data for a target. The supported targets
// are macOS arm64 (arm64, Apple AAPCS64, Mach-O), Linux x86-64 (x86-64, System V, ELF), Linux arm64
// (arm64, AAPCS64, ELF), Windows x86-64 (x86-64, Microsoft x64, COFF) and wasm32-wasip1 (the basic C
// ABI, a relocatable wasm object).
import lir::ir as *;
import codegen::obj as ob;
import codegen::dwarf as dw;
import target::x64 as x;
import target::a64 as a;
import target::a64gen as gen;
import target::x64gen as xgen;
import target::macho as mo;
import target::elf as elf;
import target::coff as coff;
import target::table as tgt;
import target::wasmgen as wgen;
import target::wasmobj as wobj;
import target::assembler as asmr;
import target::ctxswitch as ctxs;

/// Whether a native backend compiles for operating system `os` on instruction set `isa`.
pub(package) const fn supported(os: i32, isa: i32) bool {
    return apple_arm64(os, isa) || linux_x64(os, isa) || linux_arm64(os, isa) || windows_x64(os, isa) || wasm32(os, isa);
}

const fn apple_arm64(os: i32, isa: i32) bool {
    return tgt::callconv_of(os, isa).name == "apple-aapcs64" && tgt::obj_of(os).name == "macho";
}

const fn linux_x64(os: i32, isa: i32) bool {
    return tgt::os(os).name == "linux" && tgt::isa(isa).name == "x86_64";
}

const fn windows_x64(os: i32, isa: i32) bool {
    return tgt::os(os).name == "windows" && tgt::isa(isa).name == "x86_64";
}

const fn linux_arm64(os: i32, isa: i32) bool {
    return tgt::os(os).name == "linux" && tgt::callconv_of(os, isa).name == "aapcs64" && tgt::obj_of(os).name == "elf";
}

const fn wasm32(os: i32, isa: i32) bool {
    return tgt::obj_of(os).name == "wasm" && tgt::isa(isa).name == "wasm32";
}

/// The own linker's format for `(os, isa)` (`link::link`): none, Mach-O arm64, ELF x86-64, ELF arm64, PE
/// x86-64 or wasm32.
pub(package) const LINK_NONE: u8 = 0;
pub(package) const LINK_MACHO: u8 = 1;
pub(package) const LINK_ELF_X64: u8 = 2;
pub(package) const LINK_ELF_A64: u8 = 3;
pub(package) const LINK_PE: u8 = 4;
pub(package) const LINK_WASM: u8 = 5;

/// The object format of OS `os` (`target::table::ObjFormat`), as the archiver reads objects.
pub(package) const OBJ_MACHO: u8 = 0;
pub(package) const OBJ_ELF: u8 = 1;
pub(package) const OBJ_COFF: u8 = 2;
pub(package) const OBJ_WASM: u8 = 3;

pub(package) const fn obj_kind(os: i32) u8 {
    let f = tgt::obj_of(os).name;
    if f == "macho" {
        return OBJ_MACHO;
    }
    if f == "coff" {
        return OBJ_COFF;
    }
    if f == "wasm" {
        return OBJ_WASM;
    }
    return OBJ_ELF;
}

pub(package) const fn own_linker(os: i32, isa: i32) u8 {
    if apple_arm64(os, isa) && tgt::os(os).sdk == tgt::SDK_NONE {
        return LINK_MACHO;
    }
    if linux_x64(os, isa) {
        return LINK_ELF_X64;
    }
    if linux_arm64(os, isa) {
        return LINK_ELF_A64;
    }
    if windows_x64(os, isa) {
        return LINK_PE;
    }
    if wasm32(os, isa) {
        return LINK_WASM;
    }
    return LINK_NONE;
}

const NONE16: u16 = 0xFFFF;

// The context operation (`SYS_CTXSWAP`, `SYS_CTXENTRY`) whose naked function package function `s` is, or
// NONE16.
fn ctx_op(p: &Package, s: u32) u16 {
    let b = &p.bodies[p.syms[s as usize].def as usize];
    if !b.naked {
        return NONE16;
    }
    for i in 0..b.insts.len() {
        let t = b.insts[i];
        if t.op == O_SYS && (t.aux == SYS_CTXSWAP || t.aux == SYS_CTXENTRY) {
            return t.aux;
        }
    }
    return NONE16;
}

/// Whether the backend for `(os, isa)` assembles module-level assembly.
pub(package) const fn asm_native(os: i32, isa: i32) bool {
    return apple_arm64(os, isa) || linux_arm64(os, isa) || linux_x64(os, isa) || windows_x64(os, isa) || wasm32(os, isa);
}

/// Write into `out` an object for `(os, isa)` that defines function symbols `funcs` and data symbols
/// `datas` of package `p`, and module-level assembly `text` (`asm_native`). False, with the function and
/// the reason in `err`, when a body is outside what the backend compiles.
pub(package) fn object(
    p: &Package,
    os: i32,
    isa: i32,
    funcs: []u32,
    datas: []u32,
    text: str,
    out: &mut Vector<u8>,
    err: &mut String,
) bool {
    if text.len() != 0 && !asm_native(os, isa) {
        err.push_str("module-level assembly");
        return false;
    }
    if wasm32(os, isa) {
        return wasm_object(p, funcs, datas, text, out, err);
    }
    let win = windows_x64(os, isa);
    let x64 = win || linux_x64(os, isa);
    let apple = apple_arm64(os, isa);
    if !x64 && !apple && !linux_arm64(os, isa) {
        err.push_str("no native backend for this target");
        return false;
    }
    let mut o = ob::Obj::new();
    let mut ga = gen::Gen::new(p, &mut o, apple, !apple);
    let mut gx = xgen::Gen::new(p, &mut o, win);
    let mut g = Backend { a: &mut ga, x: &mut gx, x64: x64 };
    let fmt = if apple {
        asmr::FMT_MACHO;
    } else if win {
        asmr::FMT_COFF;
    } else {
        asmr::FMT_ELF;
    };
    // The context switch and its entry are their target's assembly (`target::ctxswitch`), after the
    // module-level assembly, as the runtime held them.
    let mut all = String::from_str(text);
    for i in 0..funcs.len() {
        let op = ctx_op(p, funcs[i]);
        if op != NONE16 {
            if all.len() != 0 && !all.as_str().ends_with("\n") {
                all.push_byte(b'\n');
            }
            ctxs::text(op, isa, fmt, p.spell(p.syms[funcs[i] as usize].name), &mut all);
            continue;
        }
        if !g.func(funcs[i], false) {
            err.format_into("{}: {}", p.spell(p.syms[funcs[i] as usize].name), g.why());
            return false;
        }
    }
    for i in 0..datas.len() {
        if !g.data(datas[i], false) {
            err.format_into("{}: {}", p.spell(p.syms[datas[i] as usize].name), g.why());
            return false;
        }
    }
    // Local copies of what the object references that the package defines and no unit owns (string
    // literals, say); the zero-sized sentinels are the C registry's. Each step defines a symbol or ends.
    let mut k: usize = 0;
    while k < o.syms.len() {
        let y = o.syms[k];
        k += 1;
        if y.sec != ob::NOSEC {
            continue;
        }
        let nm = String::from_str(o.name_of(k as u32 - 1));
        let s = p.find_symbol(nm.as_str());
        if s == NONE || nm.as_str().starts_with("__sc_zst_") {
            continue;
        }
        let ps = p.syms[s as usize];
        if ps.def == NONE || ps.unit != NONE {
            continue;
        }
        if ps.kind == SK_FUNC {
            if !g.func(s, true) {
                err.format_into("{}: {}", nm.as_str(), g.why());
                return false;
            }
        } else if !g.data(s, true) {
            err.format_into("{}: {}", nm.as_str(), g.why());
            return false;
        }
    }
    if all.len() != 0 {
        let mut asr = asmr::Asm::new(
            if x64 {
                asmr::ISA_X64;
            } else {
                asmr::ISA_A64;
            },
            fmt,
        );
        if !asr.module(&mut o, all.as_str()) {
            err.format_into("module-level assembly: {}", asr.err.as_str());
            return false;
        }
    }
    if p.debug && o.funcs.len() != 0 {
        let d = dw::Dwarf::of_obj(&o, p, p.comp_dir.as_str(), p.ptr_bytes);
        let fmt = if apple {
            dw::F_MACHO;
        } else if win {
            dw::F_COFF;
        } else {
            dw::F_ELF;
        };
        dw::attach(&mut o, &d, fmt, ast_pick(x64, x::R_ABS64, a::R_ABS64));
    }
    if win {
        coff::write(&o, p.split, out);
        return true;
    }
    if !apple {
        elf::write(&o, !x64, p.split, out);
        return true;
    }
    // A named section the format does not know is an error.
    for k in ob::S_COUNT as usize..o.secs.len() {
        let mut sect: str = "";
        let mut seg: str = "";
        if mo::named_flags(o.secs[k].name.as_str(), o.secs[k].code, &mut sect, &mut seg) == mo::NONE32 {
            err.format_into("the section '{}' is not a Mach-O section this backend writes", o.secs[k].name.as_str());
            return false;
        }
    }
    mo::write(&mut o, out);
    return true;
}

const fn ast_pick(c: bool, t: u8, f: u8) u8 {
    return if c {
        t;
    } else {
        f;
    };
}

// The generator of the target: the arm64 one, or the x86-64 one (`x64`). Both share the object.
struct Backend {
    pub(package) a: *mut gen::Gen,
    pub(package) x: *mut xgen::Gen,
    pub(package) x64: bool,
}

extend Backend {
    fn func(self: &mut Self, s: u32, local: bool) bool {
        if self.x64 {
            return unsafe (*self.x).func(s, local);
        }
        return unsafe (*self.a).func(s, local);
    }

    fn data(self: &mut Self, s: u32, local: bool) bool {
        if self.x64 {
            return unsafe (*self.x).data(s, local);
        }
        return unsafe (*self.a).data(s, local);
    }

    // The first refusal's reason.
    const fn why(self: &Self) str {
        if self.x64 {
            return unsafe (*self.x).err.as_str();
        }
        return unsafe (*self.a).err.as_str();
    }
}

// `object` for wasm32: the code generator fills a wasm object, local copies included.
fn wasm_object(p: &Package, funcs: []u32, datas: []u32, text: str, out: &mut Vector<u8>, err: &mut String) bool {
    let mut o = wobj::WObj::new();
    if p.debug {
        o.debug = true;
        o.comp_dir = p.comp_dir.clone();
        for k in 0..p.files.len() {
            o.files.push(String::from_str(p.spell(p.files[k])));
        }
    }
    let mut g = wgen::Gen::new(p, &mut o);
    for i in 0..funcs.len() {
        if !g.func(funcs[i], false) {
            err.format_into("{}: {}", p.spell(p.syms[funcs[i] as usize].name), g.err.as_str());
            return false;
        }
    }
    for i in 0..datas.len() {
        if !g.data(datas[i], false) {
            err.format_into("{}: {}", p.spell(p.syms[datas[i] as usize].name), g.err.as_str());
            return false;
        }
    }
    // Local copies of what the object references that the package defines and no unit owns. Each step
    // defines a symbol or ends.
    let mut k: usize = 0;
    while k < o.syms.len() {
        let y = o.syms[k];
        k += 1;
        if y.def != wobj::NONE || y.kind == wobj::K_GLOBAL || y.kind == wobj::K_TABLE {
            continue;
        }
        let nm = String::from_str(o.name_of(k as u32 - 1));
        let s = p.find_symbol(nm.as_str());
        if s == NONE || nm.as_str().starts_with("__sc_zst_") {
            continue;
        }
        let ps = p.syms[s as usize];
        if ps.def == NONE || ps.unit != NONE {
            continue;
        }
        let ok = if ps.kind == SK_FUNC {
            g.func(s, true);
        } else {
            g.data(s, true);
        };
        if !ok {
            err.format_into("{}: {}", nm.as_str(), g.err.as_str());
            return false;
        }
    }
    if text.len() != 0 {
        let mut e = String::new();
        if !asmr::wasm_module(&mut o, text, &mut e) {
            err.format_into("module-level assembly: {}", e.as_str());
            return false;
        }
    }
    wobj::write(&o, out);
    return true;
}
