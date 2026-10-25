// The native backends' entry: an object of LIR functions and data for a target. The supported targets
// are macOS arm64 (arm64, Apple AAPCS64, Mach-O), Linux x86-64 (x86-64, System V, ELF), Windows x86-64
// (x86-64, Microsoft x64, COFF) and wasm32-wasip1 (the basic C ABI, a relocatable wasm object).
import lir::ir as *;
import codegen::obj as ob;
import target::a64gen as gen;
import target::x64gen as xgen;
import target::macho as mo;
import target::elf as elf;
import target::coff as coff;
import target::table as tgt;
import target::wasmgen as wgen;
import target::wasmobj as wobj;

/// Whether a native backend compiles for operating system `os` on instruction set `isa`.
pub const fn supported(os: i32, isa: i32) bool {
    return apple_arm64(os, isa) || linux_x64(os, isa) || windows_x64(os, isa) || wasm32(os, isa);
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

const fn wasm32(os: i32, isa: i32) bool {
    return tgt::obj_of(os).name == "wasm" && tgt::isa(isa).name == "wasm32";
}

/// Whether the backend for `(os, isa)` defines and reaches thread-local variables (Windows: the C
/// compiler's model, emutls before gcc 16, is not followed yet).
pub const fn tls_native(os: i32, isa: i32) bool {
    return !windows_x64(os, isa);
}

/// Write into `out` an object for `(os, isa)` that defines function symbols `funcs` and data symbols
/// `datas` of package `p`. False, with the function and the reason in `err`, when a body is outside what
/// the backend compiles.
pub fn object(p: &Package, os: i32, isa: i32, funcs: []u32, datas: []u32, out: &mut Vector<u8>, err: &mut String) bool {
    if wasm32(os, isa) {
        return wasm_object(p, funcs, datas, out, err);
    }
    let win = windows_x64(os, isa);
    let x64 = win || linux_x64(os, isa);
    if !x64 && !apple_arm64(os, isa) {
        err.push_str("no native backend for this target");
        return false;
    }
    let mut o = ob::Obj::new();
    let mut ga = gen::Gen::new(p, &mut o, true);
    let mut gx = xgen::Gen::new(p, &mut o, win);
    let mut g = Backend { a: &mut ga, x: &mut gx, x64: x64 };
    for i in 0..funcs.len() {
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
    if win {
        coff::write(&o, out);
        return true;
    }
    if x64 {
        elf::write(&o, out);
        return true;
    }
    // A named section the format does not know goes through C, whose compiler reports it.
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

// The generator of the target: the arm64 one, or the x86-64 one (`x64`). Both share the object.
struct Backend {
    pub a: *mut gen::Gen,
    pub x: *mut xgen::Gen,
    pub x64: bool,
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
    fn why(self: &Self) str {
        if self.x64 {
            return unsafe (*self.x).err.as_str();
        }
        return unsafe (*self.a).err.as_str();
    }
}

// `object` for wasm32: the code generator fills a wasm object, local copies included.
fn wasm_object(p: &Package, funcs: []u32, datas: []u32, out: &mut Vector<u8>, err: &mut String) bool {
    let mut o = wobj::WObj::new();
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
    wobj::write(&o, out);
    return true;
}
