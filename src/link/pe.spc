// The PE linker for x86-64 Windows: COFF objects plus the system's DLLs (read for their exported names)
// into a console executable or a DLL that links the universal C runtime (ucrtbase.dll). A call of a
// DLL's function goes through a thunk that jumps through its import address table slot, a `__imp_`
// reference reads the slot itself. The executable starts at its own entry, which configures the C
// runtime as mingw-w64's start code does, runs the `.CRT$XC*` initializers and calls `main`; a DLL's
// entry runs the initializers on attach and its `atexit` handlers on detach, from a table of its own,
// and its export directory names every global its objects define. Thread-locals use the image's TLS
// directory. The image carries base relocations (it loads at any address), the exception
// table, and the debug sections unless stripped.
//
// mingw-w64's import libraries also carry a few C functions the C runtime DLLs do not export: the ones
// that are its exports under another name (`RENAMES`), and the ones the static part of its C library
// implements, which the Super-C runtime defines as `__sc_ucrt_<name>` (`std::rt::builtins`).
import link::ar;
import link::util as lu;
import target::native as nat;
import utils::names as nm;
import std::platform::fs;
import stdlib;

const NONE: u32 = 0xFFFFFFFF;

/// A link: the objects, the libraries (`-l` names, each a DLL found in `dirs` or the system directory),
/// the output (a DLL when `shared`), whether to leave out the debug sections (`strip`), and the main
/// thread's stack reserve (0: mingw-w64's 2 MiB).
pub(package) struct Opts {
    pub(package) out: String,
    pub(package) shared: bool,
    pub(package) objs: Vector<String>,
    pub(package) libs: Vector<String>,
    pub(package) dirs: Vector<String>,
    pub(package) strip: bool,
    pub(package) stack: u64,
    pub(package) gc: bool, // drop the COMDAT sections nothing reaches (`--gc-sections`, `collect`)
    /// A shared library's exports: None, every default-visibility global; else the globals named.
    pub(package) exports: Option<Set<String>>,
    pub(package) mem: *mut lu::Mem, // the objects held in memory (`lu::take_held`)
}

const SCN_CODE: u32 = 0x20;
const SCN_IDATA: u32 = 0x40;
const SCN_UDATA: u32 = 0x80;
const SCN_LNK_INFO: u32 = 0x200;
const SCN_LNK_REMOVE: u32 = 0x800;
const SCN_LNK_COMDAT: u32 = 0x1000;
const SCN_NRELOC_OVFL: u32 = 0x01000000;
const SCN_DISCARDABLE: u32 = 0x02000000;
const SCN_EXEC: u32 = 0x20000000;
const SCN_READ: u32 = 0x40000000;
const SCN_WRITE: u32 = 0x80000000;

const REL_ABSOLUTE: u32 = 0;
const REL_ADDR64: u32 = 1;
const REL_ADDR32: u32 = 2;
const REL_ADDR32NB: u32 = 3;
const REL_REL32: u32 = 4;
const REL_REL32_5: u32 = 9;
const REL_SECTION: u32 = 10;
const REL_SECREL: u32 = 11;

const CLASS_EXTERNAL: u8 = 2;
const CLASS_STATIC: u8 = 3;
const CLASS_WEAK: u8 = 105; // a weak external: its auxiliary record names the default
const SEL_NODUPLICATES: u8 = 1; // a COMDAT section a second definition of its symbol is an error for
const SEL_ASSOCIATIVE: u8 = 5; // a COMDAT section kept or dropped with another
const CLASS_AUX: u8 = 0xFF; // an auxiliary record's slot

// lld's preferred addresses of an executable and of a DLL.
const EXE_BASE: u64 = 0x140000000;
const DLL_BASE: u64 = 0x180000000;
const SECT_ALIGN: u64 = 0x1000;
const FILE_ALIGN: u64 = 0x200;

// The C runtime DLL and the functions the entry calls.
const CRT_DLL: str = "ucrtbase.dll";
const ENTRY_IMPORTS: []str = [
    "_set_invalid_parameter_handler",
    "_set_app_type",
    "_configure_narrow_argv",
    "_initialize_narrow_environment",
    "__p___argc",
    "__p___argv",
    "exit",
];

// The functions a DLL's entry and its `atexit` call: its own exit-handler table, which its unload runs, as
// mingw-w64's DLL start code keeps it.
const DLL_IMPORTS: []str = ["_initialize_onexit_table", "_register_onexit_function", "_execute_onexit_table"];

// The C functions the C runtime DLL exports under another name: (name, export).
// mingw-w64's x64 headers name `stat` and `fstat` `stat64i32` and `fstat64i32` (`__MINGW_ASM_CALL`), aliases
// only its import libraries define: UCRT's `_stat64i32` and `_fstat64i32`.
const RENAMES: [](str, str) = [
    ("atexit", "_crt_atexit"),
    ("time", "_time64"),
    ("hypotf", "_hypotf"),
    ("stat", "_stat64i32"),
    ("fstat", "_fstat64i32"),
];

// The DLLs every link searches after the `-l` ones: the system's core and the C runtime first, then the
// ones mingw-w64's toolchain also links by default, read only while a symbol is still undefined.
const DEFAULT_DLLS: []str = ["kernel32.dll", CRT_DLL];
const LATE_DLLS: []str = ["user32.dll", "advapi32.dll", "shell32.dll"];

// An API set: a DLL name the loader maps to the DLL that implements it, which the system directory need
// not hold; its exports are the API set's contract (mingw-w64's `api-ms-win-core-synch-l1-2-0.def`).
const SYNCH_DLL: str = "api-ms-win-core-synch-l1-2-0.dll";
const SYNCH_EXPORTS: []str = ["WaitOnAddress", "WakeByAddressAll", "WakeByAddressSingle"];

struct IFile {
    pub(package) path: u32,
    pub(package) at: usize,
    pub(package) sec0: u32,
    pub(package) nsec: u32,
    pub(package) sym0: u32,
    pub(package) nsym: u32,
}

// An input section: its name, the output section it joins, flags, alignment, size, bytes (in the blob;
// none for zero-filled data), relocations, and where it lands in its output section.
struct ISec {
    pub(package) file: u32,
    pub(package) name: u32,
    pub(package) flags: u32,
    pub(package) align: u64,
    pub(package) size: u64,
    pub(package) off: usize,
    pub(package) reloff: usize,
    pub(package) nreloc: u32,
    pub(package) out: u32,
    pub(package) at: u64,
    pub(package) assoc: u32, // an associative COMDAT section's section, else NONE
    pub(package) sel: u8, // a COMDAT section's selection, else 0
}

// An input symbol (an auxiliary record keeps its slot, so symbol table indices stay direct).
struct ISym {
    pub(package) name: u32,
    pub(package) value: u32,
    pub(package) sec: i32,
    pub(package) class: u8,
    pub(package) file: u32,
}

const G_UNDEF: u8 = 0;
const G_DEF: u8 = 1; // an object defines it: `sym`
const G_IMPORT: u8 = 2; // DLL `lib` exports it, at name table index `hint`
const G_COMMON: u8 = 3; // tentative: `size` bytes aligned to `align`, at `at` of `.bss`
const G_SYNTH: u8 = 4; // the linker defines it: relative address `at`

struct GSym {
    pub(package) name: u32,
    pub(package) kind: u8,
    pub(package) sym: u32,
    pub(package) lib: u32,
    pub(package) hint: u32,
    pub(package) size: u64,
    pub(package) align: u64,
    pub(package) at: u64,
    pub(package) alias: u32, // the global it stands for (`__imp_X`: X; a renamed or runtime-supplied function), else NONE
    pub(package) iat: bool, // `__imp_X`: the import address table slot of `alias`
    pub(package) strong: bool, // an object references it undefined
    pub(package) need: bool, // an import the image imports
    pub(package) slot: u32, // an import's index in `imports`
    pub(package) wdef: u32, // a weak external's default (an input symbol) while no object defines it, else NONE
}

// An output section.
struct OSec {
    pub(package) name: u32, // `sn` id
    pub(package) flags: u32,
    pub(package) align: u64,
    pub(package) size: u64,
    pub(package) rva: u64,
    pub(package) off: u64,
    pub(package) raw: u64, // its bytes in the file (0: zero-filled)
}

// A DLL: its name, and whether an import binds to it.
struct Lib {
    pub(package) dll: String,
    pub(package) used: bool,
}

extend IFile as Copy {}
extend ISec as Copy {}
extend ISym as Copy {}
extend GSym as Copy {}
extend OSec as Copy {}

struct L {
    pub(package) files: Vector<IFile>,
    pub(package) paths: Vector<String>,
    pub(package) secs: Vector<ISec>,
    pub(package) syms: Vector<ISym>,
    pub(package) names: nm::Names,
    pub(package) sn: nm::Names,
    pub(package) glob: Vector<u32>,
    pub(package) gs: Vector<GSym>,
    pub(package) libs: Vector<Lib>,
    pub(package) osecs: Vector<OSec>,
    pub(package) imports: Vector<u32>, // the imported globals, by library
    pub(package) relocs: Vector<u32>, // the relative addresses base relocations fix up
    pub(package) o_text: u32,
    pub(package) o_rdata: u32,
    pub(package) o_data: u32,
    pub(package) o_bss: u32,
    pub(package) o_idata: u32,
    pub(package) o_tls: u32,
    pub(package) o_pdata: u32,
    pub(package) entry_at: u64, // in `.text`
    pub(package) thunks_at: u64, // in `.text`
    pub(package) xdata_at: u64, // the entry's unwind information, in `.rdata`
    pub(package) tlsdir_at: u64, // in `.rdata`
    pub(package) tls_index_at: u64, // in `.data`
    pub(package) xc_lo: u64, // the `.CRT$XC*` initializers' range in `.rdata`
    pub(package) xc_hi: u64,
    pub(package) entry_pdata_at: u64, // in `.pdata`
    pub(package) shared: bool, // a DLL
    pub(package) base: u64, // the preferred image address
    pub(package) onexit_at: u64, // a DLL's exit-handler table, in `.data`
    pub(package) exports: Vector<u32>, // a DLL's exported globals, by name
    pub(package) edata_at: u64, // a DLL's export directory, in `.rdata`
    pub(package) edata_size: u64, // with its tables and names
    pub(package) err: String,
}

const ENTRY_SIZE: u64 = 128;

/// Link `o`. False with the reason in `err` when it fails.
pub(package) fn link(o: &Opts, err: &mut String) bool {
    let mut l = L {
        files: Vector::<IFile>::new(),
        paths: Vector::<String>::new(),
        secs: Vector::<ISec>::new(),
        syms: Vector::<ISym>::new(),
        names: nm::Names::with_capacity(1 << 20, 1 << 14),
        sn: nm::Names::with_capacity(1 << 10, 1 << 6),
        glob: Vector::<u32>::new(),
        gs: Vector::<GSym>::new(),
        libs: Vector::<Lib>::new(),
        osecs: Vector::<OSec>::new(),
        imports: Vector::<u32>::new(),
        relocs: Vector::<u32>::new(),
        o_text: NONE,
        o_rdata: NONE,
        o_data: NONE,
        o_bss: NONE,
        o_idata: NONE,
        o_tls: NONE,
        o_pdata: NONE,
        entry_at: 0,
        thunks_at: 0,
        xdata_at: 0,
        tlsdir_at: 0,
        tls_index_at: 0,
        xc_lo: 0,
        xc_hi: 0,
        entry_pdata_at: 0,
        shared: o.shared,
        base: if o.shared {
            DLL_BASE
        } else {
            EXE_BASE
        },
        onexit_at: 0,
        exports: Vector::<u32>::new(),
        edata_at: 0,
        edata_size: 0,
        err: String::new(),
    };
    let mut blob = Vector::<u8>::new();
    let ok = run(&mut l, o, &mut blob);
    if !ok {
        err.push_string(&l.err);
    }
    return ok;
}

fn run(l: &mut L, o: &Opts, blob: &mut Vector<u8>) bool {
    // The archives, positional and the `-l` static libraries, give the members the objects need.
    let mut ars = ar::Archives::new();
    for i in 0..o.objs.len() {
        let p = o.objs[i].as_str();
        let at = blob.len();
        if lu::take_held(o.mem, p, blob) {
            if !parse_object(l, p, at, blob) {
                return false;
            }
            continue;
        }
        if ar::is_archive(p) {
            if !ars.add(nat::OBJ_COFF, p, &mut l.err) {
                return false;
            }
        } else if !read_object(l, p, blob) {
            return false;
        }
    }
    for i in 0..o.libs.len() {
        let mut path = String::new();
        if static_lib(o, &o.libs[i], &mut path) && !ars.add(nat::OBJ_COFF, &path, &mut l.err) {
            return false;
        }
    }
    let main = global(l, l.names.intern("main"));
    l.gs.index_mut(main as usize).strong = !l.shared;
    if !resolve_objects(l, 0) || !ar::take_members(l, &mut ars, blob) {
        return false;
    }
    bind_weak(l);
    if !resolve_imports(l, o) || !finish_symbols(l, main) || !no_dtors(l) {
        return false;
    }
    let b = blob.as_slice();
    if o.gc {
        collect(l, b, main);
    }
    layout(l, o);
    let mut img = Vector::<u8>::new();
    img.resize_default(file_end(l) as usize);
    copy_sections(l, b, &mut img);
    if !apply(l, b, &mut img) {
        return false;
    }
    write_synthetic(l, o, main, &mut img);
    finish(l, o, &mut img);
    if !lu::write(&o.out, &img, 0o755) {
        l.err.format_into("cannot write '{}'", o.out.as_str());
        return false;
    }
    return true;
}

extend L as ar::Members {
    fn globals(self: &Self) usize {
        return self.gs.len();
    }

    fn wanted(self: &Self, g: usize) bool {
        return self.gs[g].kind == G_UNDEF && self.gs[g].strong && self.gs[g].wdef == NONE;
    }

    fn global_name(self: &Self, g: usize) str {
        return self.names.spell(self.gs[g].name);
    }

    fn enter_member(self: &mut Self, name: str, at: usize, blob: &mut Vector<u8>) bool {
        let f0 = self.files.len();
        return parse_object(self, name, at, blob) && resolve_objects(self, f0);
    }
}

// ---- input ----------------------------------------------------------------------------------------------

// The name of a section or symbol: inline up to 8 bytes, else at an offset into the string table
// (`str_at`: `/<decimal>` for a section, the second word for a symbol).
const fn short_name<'a>(b: Slice<'a, u8>, at: usize) str<'a> {
    let mut n: usize = 0;
    while n < 8 && b[at + n] != 0 {
        n += 1;
    }
    return unsafe str::from_raw(b.as_ptr() + at, n);
}

fn read_object(l: &mut L, path: str, blob: &mut Vector<u8>) bool {
    let at = blob.len();
    if !lu::read_append(path, blob) {
        l.err.format_into("cannot read '{}'", path);
        return false;
    }
    return parse_object(l, path, at, blob);
}

// Enter the object at `at` of `blob` (named `path` in messages).
fn parse_object(l: &mut L, path: str, at: usize, blob: &Vector<u8>) bool {
    let b = blob.as_slice();
    if b.len() - at < 20 || lu::r16(b, at) != 0x8664 || lu::r16(b, at + 16) != 0 {
        l.err.format_into("'{}' is not an x86-64 COFF object", path);
        return false;
    }
    l.paths.push(String::from_str(path));
    let fi = l.files.len() as u32;
    let nsec = lu::r16(b, at + 2) as usize;
    let symtab = at + lu::r32(b, at + 8) as usize;
    let nsym = lu::r32(b, at + 12) as usize;
    let strtab = symtab + 18 * nsym;
    let sec0 = l.secs.len() as u32;
    for k in 0..nsec {
        let h = at + 20 + 40 * k;
        let mut name = short_name(b, h);
        if name.starts_with("/") {
            let mut v: usize = 0;
            for i in 1..name.len() {
                v = v * 10 + (name.byte_at(i) - b'0') as usize;
            }
            name = lu::cstr(b, strtab + v);
        }
        let flags = lu::r32(b, h + 36);
        let al = flags >> 20 & 0xF;
        let raw = lu::r32(b, h + 20) as usize;
        let mut nrel = lu::r16(b, h + 32);
        let reloff = at + lu::r32(b, h + 24) as usize;
        if (flags & SCN_NRELOC_OVFL) != 0 && nrel == 0xFFFF {
            // The first entry counts them, itself included.
            nrel = lu::r32(b, reloff) - 1;
        }
        l.secs.push(
            ISec {
                file: fi,
                name: l.sn.intern(name),
                flags: flags,
                align: if al == 0 {
                    1u64
                } else {
                    1u64 << (al - 1) as u64
                },
                size: lu::r32(b, h + 16),
                off: if raw == 0 {
                    0usize
                } else {
                    at + raw
                },
                reloff: if (flags & SCN_NRELOC_OVFL) != 0 && lu::r16(b, h + 32) == 0xFFFF {
                    reloff + 10
                } else {
                    reloff
                },
                nreloc: nrel,
                out: NONE,
                at: 0,
                assoc: NONE,
                sel: 0,
            },
        );
    }
    let sym0 = l.syms.len() as u32;
    let mut k: usize = 0;
    // Each step reads one symbol and skips its auxiliary records.
    while k < nsym {
        let e = symtab + 18 * k;
        let name = if lu::r32(b, e) == 0 {
            lu::cstr(b, strtab + lu::r32(b, e + 4) as usize)
        } else {
            short_name(b, e)
        };
        let naux = b[e + 17] as usize;
        // A COMDAT section's definition (its section symbol's auxiliary record): the selection, and an
        // associative one's section.
        let sec = lu::r16(b, e + 12) as i16;
        if b[e + 16] == CLASS_STATIC && naux != 0 && sec > 0 && sec as usize <= nsec {
            let s = (sec0 + sec as u32 - 1) as usize;
            let a = e + 18;
            if (l.secs[s].flags & SCN_LNK_COMDAT) != 0 {
                l.secs.index_mut(s).sel = b[a + 14];
                if b[a + 14] == SEL_ASSOCIATIVE && lu::r16(b, a + 12) != 0 {
                    l.secs.index_mut(s).assoc = sec0 + lu::r16(b, a + 12) - 1;
                }
            }
        }
        l.syms.push(
            ISym {
                name: l.names.intern(name),
                // A weak external's: its default's index (its auxiliary record's first word).
                value: if b[e + 16] == CLASS_WEAK && naux != 0 {
                    lu::r32(b, e + 18)
                } else {
                    lu::r32(b, e + 8)
                },
                sec: lu::r16(b, e + 12) as i16,
                class: b[e + 16],
                file: fi,
            },
        );
        for _ in 0..naux {
            l.syms.push(ISym { name: 0, value: 0, sec: 0, class: CLASS_AUX, file: fi });
        }
        k += 1 + naux;
    }
    l.files.push(
        IFile {
            path: (l.paths.len() - 1) as u32,
            at: at,
            sec0: sec0,
            nsec: nsec as u32,
            sym0: sym0,
            nsym: l.syms.len() as u32 - sym0,
        },
    );
    return true;
}

fn global(l: &mut L, id: u32) u32 {
    while l.glob.len() <= id as usize {
        l.glob.push(0);
    }
    if l.glob[id as usize] == 0 {
        l.gs.push(
            GSym {
                name: id,
                kind: G_UNDEF,
                sym: NONE,
                lib: NONE,
                hint: 0,
                size: 0,
                align: 1,
                at: 0,
                alias: NONE,
                iat: false,
                strong: false,
                need: false,
                slot: NONE,
                wdef: NONE,
            },
        );
        l.glob[id as usize] = l.gs.len() as u32;
    }
    return l.glob[id as usize] - 1;
}

// The global an input symbol names (NONE: a local one).
const fn gof(l: &L, k: u32) u32 {
    let y = l.syms[k as usize];
    if y.class != CLASS_EXTERNAL && y.class != CLASS_WEAK {
        return NONE;
    }
    return l.glob[y.name as usize] - 1;
}

// Enter the external symbols of the objects from file `from` on: one definition each, but a COMDAT
// section that defines a defined name is dropped (with its associative sections) unless either selects no
// duplicates; a tentative one (no
// section, a size) takes the largest size; a weak external keeps its default until an object defines it.
fn resolve_objects(l: &mut L, from: usize) bool {
    for f in from..l.files.len() {
        let fl = l.files[f];
        let mut k = fl.sym0;
        // Each step enters one symbol.
        while k < fl.sym0 + fl.nsym {
            let y = l.syms[k as usize];
            k += 1;
            if y.class == CLASS_WEAK {
                // `value`: the default's index in the object.
                let g = global(l, y.name);
                let tag = y.value;
                if l.gs[g as usize].kind == G_UNDEF && l.gs[g as usize].wdef == NONE {
                    l.gs.index_mut(g as usize).wdef = fl.sym0 + tag;
                }
                continue;
            }
            if y.class != CLASS_EXTERNAL {
                continue;
            }
            let g = global(l, y.name);
            let mut gy = l.gs[g as usize];
            if y.sec == 0 && y.value == 0 {
                gy.strong = true;
                l.gs[g as usize] = gy;
                continue;
            }
            if y.sec == 0 {
                if gy.kind != G_DEF {
                    gy.kind = G_COMMON;
                    gy.size = gy.size.max(y.value);
                    // Aligned as its size's largest power of two up to 16.
                    let mut a: u64 = 1;
                    while a < 16 && y.value as u64 % (2 * a) == 0 {
                        a *= 2;
                    }
                    gy.align = gy.align.max(a);
                }
                l.gs[g as usize] = gy;
                continue;
            }
            if gy.kind == G_DEF && y.sec > 0 && (l.secs[(fl.sec0 + y.sec as u32 - 1) as usize].flags & SCN_LNK_COMDAT) != 0 && l.secs[(fl.sec0 + y.sec as u32 - 1) as usize].sel != SEL_NODUPLICATES && def_sel(
                l,
                gy.sym,
            ) != SEL_NODUPLICATES {
                drop_section(l, fl.sec0 + y.sec as u32 - 1);
                continue;
            }
            if gy.kind == G_DEF {
                let prev = l.syms[gy.sym as usize];
                l.err.format_into(
                    "duplicate symbol '{}' in '{}' and '{}'",
                    l.names.spell(y.name),
                    l.paths[l.files[prev.file as usize].path as usize].as_str(),
                    l.paths[fl.path as usize].as_str(),
                );
                return false;
            }
            gy.kind = G_DEF;
            gy.sym = k - 1;
            gy.wdef = NONE;
            l.gs[g as usize] = gy;
        }
    }
    return true;
}

// GCC's destructor tables (`.dtors`), which the entry does not run: an error, not a destructor left out.
fn no_dtors(l: &mut L) bool {
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if sc.size != 0 && (sc.flags & SCN_LNK_REMOVE) == 0 && l.sn.spell(sc.name).starts_with(".dtors") {
            l.err.format_into(
                "'{}': a destructor (`.dtors`), which this linker does not run",
                l.paths[l.files[sc.file as usize].path as usize].as_str(),
            );
            return false;
        }
    }
    return true;
}

// The COMDAT selection of the section that defines symbol `k` (0: none).
fn def_sel(l: &L, k: u32) u8 {
    let y = l.syms[k as usize];
    if y.sec <= 0 {
        return 0;
    }
    return l.secs[(l.files[y.file as usize].sec0 + (y.sec - 1) as u32) as usize].sel;
}

// Drop input section `s` and the associative sections that follow it.
fn drop_section(l: &mut L, s: u32) {
    l.secs.index_mut(s as usize).flags |= SCN_LNK_REMOVE;
    let f = l.secs[s as usize].file;
    for i in s as usize + 1..l.secs.len() {
        if l.secs[i].file != f {
            break;
        }
        if l.secs[i].assoc == s {
            drop_section(l, i as u32);
        }
    }
}

// A weak external no object defines: its default.
fn bind_weak(l: &mut L) {
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        if gy.kind == G_UNDEF && gy.wdef != NONE {
            let m = l.gs.index_mut(g);
            m.kind = G_DEF;
            m.sym = gy.wdef;
        }
    }
}

// ---- garbage collection ---------------------------------------------------------------------------------

// Drop the COMDAT sections no root reaches through relocations (`/OPT:REF`, as lld-link does): the roots
// are every other loaded section, `main` and a DLL's exports. A section kept keeps its associative
// sections (its function table entries and unwind information). Debug sections are no roots: a relocation
// of theirs into a dropped section stays unapplied (`apply`). Each round marks a new section or ends the
// loop.
fn collect(l: &mut L, b: []u8, main: u32) {
    let mut live = Vector::<bool>::new();
    live.resize_default(l.secs.len());
    let mut work = Vector::<u32>::new();
    for s in 0..l.secs.len() {
        let fl = l.secs[s].flags;
        if (fl & (SCN_LNK_COMDAT | SCN_LNK_INFO | SCN_LNK_REMOVE | SCN_DISCARDABLE)) == 0 {
            live[s] = true;
            work.push(s as u32);
        }
    }
    if !l.shared {
        reach_global(l, main, &mut live, &mut work);
    }
    for g in 0..l.gs.len() {
        if l.shared && l.gs[g].alias == NONE {
            reach_global(l, g as u32, &mut live, &mut work);
        }
    }
    loop {
        while let Some(s) = work.pop() {
            let sc = l.secs[s as usize];
            let f = l.files[sc.file as usize];
            for i in 0..sc.nreloc as usize {
                reach_sym(l, f.sym0 + lu::r32(b, sc.reloff + 10 * i + 4), &mut live, &mut work);
            }
        }
        for s in 0..l.secs.len() {
            let a = l.secs[s].assoc;
            if a != NONE && live[a as usize] && !live[s] && (l.secs[s].flags & SCN_LNK_REMOVE) == 0 {
                live[s] = true;
                work.push(s as u32);
            }
        }
        if work.len() == 0 {
            break;
        }
    }
    for s in 0..l.secs.len() {
        if (l.secs[s].flags & SCN_LNK_COMDAT) != 0 && !live[s] {
            l.secs.index_mut(s).flags |= SCN_LNK_REMOVE;
        }
    }
}

// Mark live the section that defines global `g`.
fn reach_global(l: &L, g: u32, live: &mut Vector<bool>, work: &mut Vector<u32>) {
    let t = res(l, g);
    if l.gs[t as usize].kind == G_DEF {
        reach_def(l, l.gs[t as usize].sym, live, work);
    }
}

// Mark live the section that holds the target of symbol `k`.
fn reach_sym(l: &L, k: u32, live: &mut Vector<bool>, work: &mut Vector<u32>) {
    let g = gof(l, k);
    if g != NONE {
        reach_global(l, g, live, work);
    } else {
        reach_def(l, k, live, work);
    }
}

// Mark live the section that defines symbol `k`.
fn reach_def(l: &L, k: u32, live: &mut Vector<bool>, work: &mut Vector<u32>) {
    let y = l.syms[k as usize];
    if y.sec <= 0 {
        return;
    }
    let s = l.files[y.file as usize].sec0 + (y.sec - 1) as u32;
    if !live[s as usize] && (l.secs[s as usize].flags & SCN_LNK_REMOVE) == 0 {
        live[s as usize] = true;
        work.push(s);
    }
}

// ---- DLLs -----------------------------------------------------------------------------------------------

// The DLL `-l<name>` of link `o` names: none for a static library (`static_lib`) or `m` (the C runtime
// DLL holds the math functions), the API set behind mingw-w64's `synchronization` library, else
// `<name>.dll`.
fn dll_of(o: &Opts, name: str, out: &mut String) bool {
    let mut path = String::new();
    if name == "m" || static_lib(o, name, &mut path) {
        return false;
    }
    if name == "synchronization" {
        out.push_str(SYNCH_DLL);
    } else {
        out.format_into("{}.dll", name);
    }
    return true;
}

// The system directory: `%SystemRoot%\System32` on a Windows host, none elsewhere.
fn system_dir(out: &mut String) bool {
    let root = stdlib::get_env("SystemRoot");
    if root.is_none() {
        return false;
    }
    out.format_into("{}\\System32", root.unwrap().as_str());
    return true;
}

/// Whether link `o` finds DLL `dll` (`-L` directories, then the system directory) or knows its exports
/// (an API set); its path into `path`, empty for an API set.
pub(package) fn find_dll(o: &Opts, dll: str, path: &mut String) bool {
    for i in 0..o.dirs.len() {
        let p = format("{}/{}", o.dirs[i].as_str(), dll);
        if lu::is_file(&p) {
            path.push_string(&p);
            return true;
        }
    }
    let mut sys = String::new();
    if system_dir(&mut sys) {
        let p = format("{}\\{}", sys.as_str(), dll);
        if lu::is_file(&p) {
            path.push_string(&p);
            return true;
        }
    }
    return dll == SYNCH_DLL;
}

/// Whether link `o` finds every DLL it needs: the C runtime's, the system's core, and the `-l` ones;
/// else the first one missing into `why`.
pub(package) fn has_dlls(o: &Opts, why: &mut String) bool {
    let mut want = Vector::<String>::new();
    for i in 0..o.libs.len() {
        let mut d = String::new();
        if dll_of(o, &o.libs[i], &mut d) {
            want.push(d);
        }
    }
    for i in 0..DEFAULT_DLLS.len() {
        want.push(String::from_str(DEFAULT_DLLS[i]));
    }
    for i in 0..want.len() {
        let mut p = String::new();
        if !find_dll(o, &want[i], &mut p) {
            why.format_into("no '{}'", want[i].as_str());
            return false;
        }
    }
    return true;
}

/// Whether `-l<name>` of link `o` is a static library: `lib<name>.a`, `<name>.lib` or `lib<name>.lib` in a
/// `-L` directory (GNU ld's order, import libraries `lib<name>.dll.a` left out) that holds an object and no
/// import (`ar::read`); its path into `path`. An import library stands for its DLL.
pub(package) fn static_lib(o: &Opts, name: str, path: &mut String) bool {
    const FORMS: [](str, str) = [("lib", ".a"), ("", ".lib"), ("lib", ".lib")];
    for i in 0..o.dirs.len() {
        for f in 0..FORMS.len() {
            let p = format("{}/{}{}{}", o.dirs[i].as_str(), FORMS[f].0, name, FORMS[f].1);
            if !lu::is_file(&p) {
                continue;
            }
            let d = lu::read(&p);
            if d.is_none() {
                continue;
            }
            let data = d.unwrap();
            let mut ms = Vector::<ar::Member>::new();
            let mut syms = Vector::<(str, u32)>::new();
            let mut why = String::new();
            // mingw-w64's import libraries (`libws2_32.a`) hold objects beside their imports.
            let mut imports = false;
            if ar::read(nat::OBJ_COFF, &data, &mut ms, &mut syms, &mut imports, &mut why) && ms.len() != 0 && !imports {
                path.push_string(&p);
                return true;
            }
        }
    }
    return false;
}

// The import-only globals: each undefined `__imp_X` stands for X's slot; the targets of `RENAMES`, the
// old names' `_X` and the entry's imports are looked up too.
fn prepare_imports(l: &mut L) {
    let n = l.gs.len();
    for g in 0..n {
        let gy = l.gs[g];
        let s = l.names.spell(gy.name);
        if gy.kind == G_UNDEF && s.starts_with("__imp_") {
            let base = String::from_str(s.slice(6, s.len()));
            let t = global(l, l.names.intern(&base));
            let m = l.gs.index_mut(g);
            m.alias = t;
            m.iat = true;
        } else if gy.kind == G_UNDEF && !s.starts_with("_") {
            let old = format("_{}", s);
            let _ = global(l, l.names.intern(&old));
        }
    }
    for i in 0..RENAMES.len() {
        let _ = global(l, l.names.intern(RENAMES[i].1));
    }
    let ei = entry_imports(l.shared);
    for i in 0..ei.len() {
        let _ = global(l, l.names.intern(ei[i]));
    }
    if l.shared {
        let _ = global(l, l.names.intern("__sc_dll_atexit"));
    }
}

// The C runtime functions the entry calls.
const fn entry_imports(shared: bool) Slice<'static, str<'static>> {
    if shared {
        return DLL_IMPORTS;
    }
    return ENTRY_IMPORTS;
}

// Whether a global still needs a definition: undefined, and not an alias.
const fn open(l: &L) bool {
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        if gy.kind == G_UNDEF && gy.alias == NONE && gy.strong {
            return true;
        }
    }
    return false;
}

// Bind each undefined global a DLL exports: the `-l` DLLs in order, then the defaults, then (while a
// symbol is still undefined) the late defaults; then the C functions those DLLs lack.
fn resolve_imports(l: &mut L, o: &Opts) bool {
    prepare_imports(l);
    let mut dlls = Vector::<String>::new();
    for i in 0..o.libs.len() {
        let mut d = String::new();
        if dll_of(o, &o.libs[i], &mut d) {
            dlls.push(d);
        }
    }
    for i in 0..DEFAULT_DLLS.len() {
        dlls.push(String::from_str(DEFAULT_DLLS[i]));
    }
    for i in 0..dlls.len() {
        if !load_dll(l, o, &dlls[i], true) {
            return false;
        }
    }
    for i in 0..LATE_DLLS.len() {
        if open(l) {
            let _ = load_dll(l, o, LATE_DLLS[i], false);
        }
    }
    // A C function the DLLs lack: a renamed export, else its old POSIX name's `_X` export (mingw-w64's
    // `getcwd` is `_getcwd`), else the runtime's own.
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        if gy.kind != G_UNDEF || gy.alias != NONE {
            continue;
        }
        let s = String::from_str(l.names.spell(gy.name));
        if l.shared && s.as_str() == "atexit" {
            l.gs.index_mut(g).alias = l.glob[l.names.find("__sc_dll_atexit") as usize] - 1;
            continue;
        }
        for i in 0..RENAMES.len() {
            if s.as_str() == RENAMES[i].0 {
                let t = l.glob[l.names.find(RENAMES[i].1) as usize] - 1;
                if l.gs[t as usize].kind == G_IMPORT {
                    l.gs.index_mut(g).alias = t;
                }
            }
        }
        if l.gs[g].alias == NONE && !s.as_str().starts_with("_") {
            let old = l.names.find(format("_{}", s.as_str()).as_str());
            if old >= 0 && old as usize < l.glob.len() && l.glob[old as usize] != 0 {
                let t = l.glob[old as usize] - 1;
                if l.gs[t as usize].kind == G_IMPORT {
                    l.gs.index_mut(g).alias = t;
                }
            }
        }
        let own = l.names.find(format("__sc_ucrt_{}", s.as_str()).as_str());
        if l.gs[g].alias == NONE && own >= 0 && own as usize < l.glob.len() && l.glob[own as usize] != 0 {
            let t = l.glob[own as usize] - 1;
            if l.gs[t as usize].kind == G_DEF {
                l.gs.index_mut(g).alias = t;
            }
        }
    }
    return true;
}

// Read the exported names of DLL `dll` and bind each undefined global one names. False, with the reason,
// when a `required` DLL cannot be read.
fn load_dll(l: &mut L, o: &Opts, dll: str, required: bool) bool {
    let lib = l.libs.len() as u32;
    l.libs.push(Lib { dll: String::from_str(dll), used: false });
    let mut path = String::new();
    if !find_dll(o, dll, &mut path) {
        if required {
            l.err.format_into("DLL not found: {}", dll);
        }
        return !required;
    }
    if path.len() == 0 {
        // An API set: its contract's names.
        for i in 0..SYNCH_EXPORTS.len() {
            bind_export(l, lib, SYNCH_EXPORTS[i], i as u32);
        }
        return true;
    }
    let data = lu::read(&path);
    if data.is_none() {
        l.err.format_into("cannot read '{}'", path.as_str());
        return false;
    }
    let d = data.unwrap();
    let b = d.as_slice();
    if b.len() < 64 || lu::r16(b, 0) != 0x5A4D {
        l.err.format_into("'{}' is not a PE file", path.as_str());
        return false;
    }
    let pe = lu::r32(b, 0x3C) as usize;
    let nsec = lu::r16(b, pe + 6) as usize;
    let opt = pe + 24;
    let dd = opt + if lu::r16(b, opt) == 0x20B {
        112usize
    } else {
        96usize
    };
    let erva = lu::r32(b, dd);
    if erva == 0 {
        return true;
    }
    let sh = opt + lu::r16(b, pe + 20) as usize;
    let e = rva_off(b, sh, nsec, erva);
    let nnames = lu::r32(b, e + 24) as usize;
    let names = rva_off(b, sh, nsec, lu::r32(b, e + 32));
    for i in 0..nnames {
        let at = rva_off(b, sh, nsec, lu::r32(b, names + 4 * i));
        bind_export(l, lib, lu::cstr(b, at), i as u32);
    }
    return true;
}

// The file offset of relative address `rva` of a PE file with `nsec` section headers at `sh`.
const fn rva_off(b: []u8, sh: usize, nsec: usize, rva: u32) usize {
    for k in 0..nsec {
        let h = sh + 40 * k;
        let va = lu::r32(b, h + 12);
        let size = lu::r32(b, h + 8).max(lu::r32(b, h + 16));
        if rva >= va && rva < va + size {
            return (rva - va + lu::r32(b, h + 20)) as usize;
        }
    }
    return 0;
}

fn bind_export(l: &mut L, lib: u32, name: str, hint: u32) {
    let id = l.names.find(name);
    if id < 0 || id as usize >= l.glob.len() || l.glob[id as usize] == 0 {
        return;
    }
    let g = (l.glob[id as usize] - 1) as usize;
    if l.gs[g].kind == G_UNDEF && l.gs[g].alias == NONE {
        let y = l.gs.index_mut(g);
        y.kind = G_IMPORT;
        y.lib = lib;
        y.hint = hint;
    }
}

// The global `g` stands for.
fn res(l: &L, g: u32) u32 {
    let a = l.gs[g as usize].alias;
    if a == NONE {
        return g;
    }
    return res(l, a);
}

// The linker's own symbols, then every strong reference must be defined; mark the imports the image
// takes.
fn finish_symbols(l: &mut L, main: u32) bool {
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        if gy.kind == G_UNDEF && gy.alias == NONE {
            let s = l.names.spell(gy.name);
            if s == "_tls_index" || s == "__ImageBase" || s == "__sc_dll_atexit" && l.shared {
                l.gs.index_mut(g).kind = G_SYNTH;
            }
        }
    }
    if !l.shared && l.gs[main as usize].kind != G_DEF {
        l.err.push_str("undefined symbol: main");
        return false;
    }
    let mut missing = String::new();
    let mut nmiss: usize = 0;
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        let s = l.names.spell(gy.name);
        let mut entry = false;
        let ei = entry_imports(l.shared);
        for i in 0..ei.len() {
            entry = entry || s == ei[i];
        }
        if !gy.strong && !entry {
            continue;
        }
        let t = res(l, g as u32);
        let k = l.gs[t as usize].kind;
        if k == G_IMPORT {
            l.gs.index_mut(t as usize).need = true;
            continue;
        }
        if k != G_UNDEF && !(gy.iat && k != G_IMPORT) {
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

// ---- layout ---------------------------------------------------------------------------------------------

// The output section named `name` (added when new).
fn out_section(l: &mut L, name: str, flags: u32) u32 {
    let id = l.sn.intern(name);
    for i in 0..l.osecs.len() {
        if l.osecs[i].name == id {
            return i as u32;
        }
    }
    l.osecs.push(OSec { name: id, flags: flags, align: 1, size: 0, rva: 0, off: 0, raw: 0 });
    return (l.osecs.len() - 1) as u32;
}

// The output section an input section of name `n` and flags `f` joins: grouped sections (`X$Y`) join
// X's; code joins `.text`, read-only data `.rdata`, writable data `.data`, zero-filled data `.bss`. A
// section of another name keeps it, as GNU ld and link.exe keep one (`@unsafe(link_section)`).
const fn out_name<'a>(n: str<'a>, f: u32) str<'a> {
    let mut base = n;
    let d = n.find("$");
    if d > 0 {
        base = n.slice(0, d as usize);
    }
    if base == ".tls" || base == ".pdata" || base.starts_with(".debug_") || !std_section(base) {
        return base;
    }
    // The initializer and terminator tables are read-only once relocated.
    if base == ".CRT" {
        return ".rdata";
    }
    if (f & SCN_CODE) != 0 {
        return ".text";
    }
    if (f & SCN_UDATA) != 0 {
        return ".bss";
    }
    if (f & SCN_WRITE) != 0 {
        return ".data";
    }
    return ".rdata";
}

// Whether `base` names a section the standard ones take: code, data, read-only data, zero-filled data,
// unwind data, the initializer tables and GCC's exception tables.
const fn std_section(base: str) bool {
    let dotted: [str; 4] = [".text", ".data", ".rodata", ".bss"];
    for x in dotted {
        if base == x || base.starts_with(x) && base.byte_at(x.len()) == b'.' {
            return true;
        }
    }
    return base == ".rdata" || base == ".xdata" || base == ".CRT" || base == ".ctors" || base == ".dtors" || base == ".eh_frame" || base == ".gcc_except_table";
}

const fn out_flags(name: str) u32 {
    if name == ".text" {
        return SCN_CODE | SCN_EXEC | SCN_READ;
    }
    if name == ".bss" {
        return SCN_UDATA | SCN_READ | SCN_WRITE;
    }
    if name == ".data" || name == ".idata" || name == ".tls" {
        return SCN_IDATA | SCN_READ | SCN_WRITE;
    }
    if name.starts_with(".debug_") || name == ".reloc" {
        return SCN_IDATA | SCN_DISCARDABLE | SCN_READ;
    }
    return SCN_IDATA | SCN_READ;
}

// Place `size` bytes aligned to `align` at the end of output section `o`; their offset in it.
fn grow(l: &mut L, o: u32, size: u64, align: u64) u64 {
    let os = l.osecs.index_mut(o as usize);
    os.align = os.align.max(align);
    os.size = lu::align_up(os.size, align);
    let at = os.size;
    os.size += size;
    return at;
}

fn layout(l: &mut L, o: &Opts) {
    // The fixed order: code, read-only data, data, zero-filled data, imports, thread-local templates, the
    // exception table; then the rest, the base relocations and the debug sections.
    l.o_text = out_section(l, ".text", out_flags(".text"));
    l.o_rdata = out_section(l, ".rdata", out_flags(".rdata"));
    l.o_data = out_section(l, ".data", out_flags(".data"));
    l.o_bss = out_section(l, ".bss", out_flags(".bss"));
    l.o_idata = out_section(l, ".idata", out_flags(".idata"));
    l.o_tls = out_section(l, ".tls", out_flags(".tls"));
    l.o_pdata = out_section(l, ".pdata", out_flags(".pdata"));
    l.entry_at = grow(l, l.o_text, ENTRY_SIZE, 16);
    // The inputs, each output section's in name order (grouped sections by their suffix), stably.
    let mut keyed = Vector::<(String, u32)>::new();
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if (sc.flags & (SCN_LNK_INFO | SCN_LNK_REMOVE)) != 0 || sc.size == 0 {
            continue;
        }
        let n = l.sn.spell(sc.name);
        if o.strip && n.starts_with(".debug_") {
            continue;
        }
        keyed.push((init_key(n), s as u32));
    }
    keyed.sort();
    let mut xc_first = true;
    // The last input's output section: the next input of the same output name joins it.
    let mut prev_o = NONE;
    let mut prev = "";
    for i in 0..keyed.len() {
        let s = keyed[i].1;
        let sc = l.secs[s as usize];
        let n = keyed[i].0.as_str();
        let on = out_name(n, sc.flags);
        if prev_o == NONE || on != prev {
            let mut fl = out_flags(on);
            if on != ".text" && on != ".rdata" && on != ".data" && on != ".bss" && on != ".tls" && on != ".pdata" && !on.starts_with(
                ".debug_",
            ) {
                fl = sc.flags & (SCN_CODE | SCN_IDATA | SCN_UDATA | SCN_EXEC | SCN_READ | SCN_WRITE);
            }
            prev_o = out_section(l, on, fl);
            prev = on;
        }
        let out = prev_o;
        let at = grow(l, out, sc.size, sc.align);
        let m = l.secs.index_mut(s as usize);
        m.out = out;
        m.at = at;
        if n.starts_with(".CRT$XC") {
            if xc_first {
                l.xc_lo = at;
                xc_first = false;
            }
            l.xc_hi = at + sc.size;
        }
    }
    // Tentative definitions in `.bss`.
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        if gy.kind == G_COMMON {
            let at = grow(l, l.o_bss, gy.size, gy.align);
            l.gs.index_mut(g).at = at;
        }
    }
    // The import thunks, the entry's unwind information and its exception table entry, the TLS directory
    // and its empty callback list, `_tls_index`.
    let mut nimp: u64 = 0;
    for li in 0..l.libs.len() {
        for g in 0..l.gs.len() {
            let gy = l.gs[g];
            if gy.kind == G_IMPORT && gy.need && gy.lib == li as u32 {
                l.gs.index_mut(g).slot = l.imports.len() as u32;
                l.imports.push(g as u32);
                l.libs.index_mut(li).used = true;
                nimp += 1;
            }
        }
    }
    l.thunks_at = grow(l, l.o_text, 8 * nimp, 8);
    l.xdata_at = grow(l, l.o_rdata, 12, 4);
    l.entry_pdata_at = grow(l, l.o_pdata, 12, 4);
    if l.osecs[l.o_tls as usize].size != 0 {
        l.tlsdir_at = grow(l, l.o_rdata, 48, 8);
    }
    l.tls_index_at = grow(l, l.o_data, 4, 4);
    if l.shared {
        l.onexit_at = grow(l, l.o_data, 24, 8);
        // The exports: every global an object defines, or the ones the export list names, by name (the
        // loader searches the names).
        let mut keyed = Vector::<(String, u32)>::new();
        for g in 0..l.gs.len() {
            let k = l.gs[g].kind;
            if (k == G_DEF || k == G_COMMON) && l.gs[g].alias == NONE && lu::listed(
                &o.exports,
                l.names.spell(l.gs[g].name),
            ) {
                keyed.push((String::from_str(l.names.spell(l.gs[g].name)), g as u32));
            }
        }
        keyed.sort();
        let mut size = 40 + o.out.len() as u64 + 1;
        for i in 0..keyed.len() {
            l.exports.push(keyed[i].1);
            size += 10 + keyed[i].0.len() as u64 + 1;
        }
        l.edata_at = grow(l, l.o_rdata, size, 4);
        l.edata_size = size;
    }
    // The import tables: the directory, then per DLL its lookup table, its address table, then the names.
    let mut nlib: u64 = 0;
    let mut names: u64 = 0;
    for li in 0..l.libs.len() {
        if l.libs[li].used {
            nlib += 1;
            names += l.libs[li].dll.len() as u64 + 1;
        }
    }
    for i in 0..l.imports.len() {
        names += lu::align_up(2 + l.names.spell(l.gs[l.imports[i] as usize].name).len() as u64 + 1, 2);
    }
    let _ = grow(l, l.o_idata, 20 * (nlib + 1) + 16 * (nimp + nlib) + names, 8);
    // Drop the empty sections.
    let mut keep = Vector::<u32>::new();
    let mut kept = Vector::<OSec>::new();
    for i in 0..l.osecs.len() {
        if l.osecs[i].size != 0 {
            keep.push(kept.len() as u32);
            kept.push(l.osecs[i]);
        } else {
            keep.push(NONE);
        }
    }
    l.osecs = kept;
    for s in 0..l.secs.len() {
        if l.secs[s].out != NONE {
            let v = keep[l.secs[s].out as usize];
            l.secs.index_mut(s).out = v;
        }
    }
    l.o_text = keep[l.o_text as usize];
    l.o_rdata = keep[l.o_rdata as usize];
    l.o_data = keep[l.o_data as usize];
    l.o_bss = remap(&keep, l.o_bss);
    l.o_idata = keep[l.o_idata as usize];
    l.o_tls = remap(&keep, l.o_tls);
    l.o_pdata = keep[l.o_pdata as usize];
    // The base relocation section is sized once the relocations are known (`finish`), after the others.
    // Addresses: after the headers, each section on its own page, its bytes on the file's alignment.
    let mut rva = lu::align_up(headers_size(l.osecs.len() + 1), SECT_ALIGN);
    let mut off = lu::align_up(headers_size(l.osecs.len() + 1), FILE_ALIGN);
    for i in 0..l.osecs.len() {
        let os = l.osecs.index_mut(i);
        os.rva = rva;
        rva = lu::align_up(rva + os.size, SECT_ALIGN);
        if (os.flags & SCN_UDATA) == 0 {
            os.off = off;
            os.raw = lu::align_up(os.size, FILE_ALIGN);
            off += os.raw;
        }
    }
}

// The layout key of input section `n`: its name, but GCC's constructor tables join the initializers
// (`.CRT$XC*`), which the entry runs in order: `.ctors.<65535 - priority>` by priority, `.ctors` (the
// default priority) after them, as mingw-w64's `__do_global_ctors` runs them.
fn init_key(n: str) String {
    if n == ".ctors" {
        return String::from_str(".CRT$XCU");
    }
    if n.starts_with(".ctors.") && n.len() == 12 {
        let mut v: u32 = 0;
        for i in 7..12usize {
            v = v * 10 + (n.byte_at(i) - b'0') as u32;
        }
        let mut k = String::from_str(".CRT$XCT");
        let p = 65535 - v.min(65535);
        for d in [10000u32, 1000, 100, 10, 1] {
            k.push_byte(b'0' + (p / d % 10) as u8);
        }
        return k;
    }
    return String::from_str(n);
}

const fn remap(keep: &Vector<u32>, o: u32) u32 {
    if o == NONE {
        return NONE;
    }
    return keep[o as usize];
}

// The size of the headers for `nsec` sections: the DOS header, the signature, the COFF and the optional
// headers, the section headers.
const fn headers_size(nsec: usize) u64 {
    return 64 + 4 + 20 + 240 + 40 * nsec as u64;
}

// The end of the sections' bytes in the file.
const fn file_end(l: &L) u64 {
    let mut e = lu::align_up(headers_size(l.osecs.len() + 1), FILE_ALIGN);
    for i in 0..l.osecs.len() {
        e = e.max(l.osecs[i].off + l.osecs[i].raw);
    }
    return e;
}

// ---- addresses ------------------------------------------------------------------------------------------

const fn sec_rva(l: &L, s: u32) u64 {
    let sc = l.secs[s as usize];
    return l.osecs[sc.out as usize].rva + sc.at;
}

const fn sym_rva(l: &L, k: u32) u64 {
    let y = l.syms[k as usize];
    let f = l.files[y.file as usize];
    if y.sec <= 0 {
        return y.value;
    }
    return sec_rva(l, f.sec0 + (y.sec - 1) as u32) + y.value as u64;
}

const fn thunk_rva(l: &L, g: u32) u64 {
    return l.osecs[l.o_text as usize].rva + l.thunks_at + 8 * l.gs[g as usize].slot as u64;
}

// The import address table slot of import `g`: the address tables follow the directory and the lookup
// tables, one per DLL in `imports` order, each ending with a zero entry.
const fn iat_rva(l: &L, g: u32) u64 {
    let (_lookup, iat) = import_tables(l);
    let gy = l.gs[g as usize];
    let mut before: u64 = 0;
    for li in 0..gy.lib as usize {
        if l.libs[li].used {
            before += 1;
        }
    }
    return iat + 8 * (gy.slot as u64 + before);
}

// The relative addresses of the lookup tables and of the address tables.
const fn import_tables(l: &L) (u64, u64) {
    let mut nlib: u64 = 0;
    for li in 0..l.libs.len() {
        nlib += l.libs[li].used as u64;
    }
    let base = l.osecs[l.o_idata as usize].rva + 20 * (nlib + 1);
    return (base, base + 8 * (l.imports.len() as u64 + nlib));
}

// The relative address of global `g` (`__imp_X`: X's slot; an import: its thunk).
fn g_rva(l: &L, g0: u32) u64 {
    let g = res(l, g0);
    let gy = l.gs[g as usize];
    if l.gs[g0 as usize].iat {
        return iat_rva(l, g);
    }
    if gy.kind == G_DEF {
        return sym_rva(l, gy.sym);
    }
    if gy.kind == G_IMPORT {
        return thunk_rva(l, g);
    }
    if gy.kind == G_COMMON {
        return l.osecs[l.o_bss as usize].rva + gy.at;
    }
    if l.names.spell(gy.name) == "_tls_index" {
        return l.osecs[l.o_data as usize].rva + l.tls_index_at;
    }
    if l.names.spell(gy.name) == "__sc_dll_atexit" {
        return l.osecs[l.o_text as usize].rva + l.entry_at + DLL_ATEXIT;
    }
    return 0;
}

fn target_rva(l: &L, k: u32) u64 {
    let g = gof(l, k);
    if g == NONE {
        return sym_rva(l, k);
    }
    return g_rva(l, g);
}

// The output section that holds the target of symbol `k` (NONE: none).
fn target_osec(l: &L, k: u32) u32 {
    let g = gof(l, k);
    let mut kk = k;
    if g != NONE {
        let t = res(l, g);
        if l.gs[t as usize].kind != G_DEF {
            return NONE;
        }
        kk = l.gs[t as usize].sym;
    }
    let y = l.syms[kk as usize];
    if y.sec <= 0 {
        return NONE;
    }
    return l.secs[(l.files[y.file as usize].sec0 + (y.sec - 1) as u32) as usize].out;
}

// Whether symbol `k`'s target is defined in a section (of an object).
fn in_section(l: &L, k: u32) bool {
    let g = gof(l, k);
    if g == NONE {
        return l.syms[k as usize].sec > 0;
    }
    let t = res(l, g);
    return l.gs[t as usize].kind == G_DEF && l.syms[l.gs[t as usize].sym as usize].sec > 0;
}

// ---- section bytes and relocations ----------------------------------------------------------------------

const fn copy_sections(l: &L, b: []u8, img: &mut Vector<u8>) {
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if sc.out == NONE || sc.off == 0 || (l.osecs[sc.out as usize].flags & SCN_UDATA) != 0 {
            continue;
        }
        let at = (l.osecs[sc.out as usize].off + sc.at) as usize;
        img.index_range_mut(at..at + sc.size as usize).copy_from_slice(b[sc.off..sc.off + sc.size as usize]);
    }
}

fn apply(l: &mut L, b: []u8, img: &mut Vector<u8>) bool {
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if sc.out == NONE || sc.nreloc == 0 {
            continue;
        }
        let f = l.files[sc.file as usize];
        let os_off = l.osecs[sc.out as usize].off;
        let os_rva = l.osecs[sc.out as usize].rva;
        let debug = (l.osecs[sc.out as usize].flags & SCN_DISCARDABLE) != 0;
        for i in 0..sc.nreloc as usize {
            let e = sc.reloff + 10 * i;
            let at = lu::r32(b, e) as u64;
            let k = f.sym0 + lu::r32(b, e + 4);
            let ty = lu::r16(b, e + 8);
            let p = (os_off + sc.at + at) as usize;
            let pr = os_rva + sc.at + at;
            if debug && target_osec(l, k) == NONE && in_section(l, k) {
                // Debug information on a dropped section's code: left unapplied, as lld-link leaves it.
                continue;
            }
            let t = target_rva(l, k);
            if ty == REL_ADDR64 {
                lu::p64(img, p, lu::r64(img.as_slice(), p).wrapping_add(l.base + t));
                if !debug {
                    l.relocs.push(pr as u32);
                }
            } else if ty == REL_ADDR32NB {
                lu::p32(img, p, lu::r32(img.as_slice(), p).wrapping_add(t as u32));
            } else if ty >= REL_REL32 && ty <= REL_REL32_5 {
                let d = t.wrapping_sub(pr + 4 + (ty - REL_REL32) as u64) as u32;
                lu::p32(img, p, lu::r32(img.as_slice(), p).wrapping_add(d));
            } else if ty == REL_SECREL {
                let o = target_osec(l, k);
                let base = if o == NONE {
                    0u64
                } else {
                    l.osecs[o as usize].rva
                };
                lu::p32(img, p, lu::r32(img.as_slice(), p).wrapping_add(t.wrapping_sub(base) as u32));
            } else if ty == REL_SECTION {
                let o = target_osec(l, k);
                lu::p16(
                    img,
                    p,
                    if o == NONE {
                        0u32
                    } else {
                        o + 1
                    },
                );
            } else if ty == REL_ADDR32 {
                l.err.format_into(
                    "'{}': a 32-bit absolute address (the image loads above 4 GiB)",
                    l.paths[f.path as usize].as_str(),
                );
                return false;
            } else if ty != REL_ABSOLUTE {
                l.err.format_into(
                    "'{}': COFF relocation type {} is not supported",
                    l.paths[f.path as usize].as_str(),
                    ty,
                );
                return false;
            }
        }
    }
    return true;
}

// ---- synthetic sections ---------------------------------------------------------------------------------

// The entry: the C runtime's invalid parameter handler (one that returns, as mingw-w64's), the console
// application type, the unexpanded arguments and the environment; the initializers; then
// `exit(main(argc, argv))`. Its unwind information: a 40-byte frame (shadow space and alignment), so a
// backtrace stops cleanly.
const ENTRY: [u8; 114] = [
    0x48,
    0x83,
    0xEC,
    0x28, // sub rsp, 40
    0x48,
    0x8D,
    0x0D,
    0,
    0,
    0,
    0, // lea rcx, [rip + ret]
    0xFF,
    0x15,
    0,
    0,
    0,
    0, // call [_set_invalid_parameter_handler]
    0xB9,
    1,
    0,
    0,
    0, // mov ecx, 1 (_crt_console_app)
    0xFF,
    0x15,
    0,
    0,
    0,
    0, // call [_set_app_type]
    0xB9,
    1,
    0,
    0,
    0, // mov ecx, 1 (_crt_argv_unexpanded_arguments)
    0xFF,
    0x15,
    0,
    0,
    0,
    0, // call [_configure_narrow_argv]
    0xFF,
    0x15,
    0,
    0,
    0,
    0, // call [_initialize_narrow_environment]
    0x48,
    0x8D,
    0x35,
    0,
    0,
    0,
    0, // lea rsi, [rip + initializers]
    0x48,
    0x8D,
    0x3D,
    0,
    0,
    0,
    0, // lea rdi, [rip + their end]
    0x48,
    0x39,
    0xFE, // 59: cmp rsi, rdi
    0x73,
    0x10, // jae 80
    0x48,
    0x8B,
    0x06, // mov rax, [rsi]
    0x48,
    0x83,
    0xC6,
    0x08, // add rsi, 8
    0x48,
    0x85,
    0xC0, // test rax, rax
    0x74,
    0xEF, // jz 59
    0xFF,
    0xD0, // call rax
    0xEB,
    0xEB, // jmp 59
    0xFF,
    0x15,
    0,
    0,
    0,
    0, // 80: call [__p___argc]
    0x8B,
    0x18, // mov ebx, [rax]
    0xFF,
    0x15,
    0,
    0,
    0,
    0, // call [__p___argv]
    0x48,
    0x8B,
    0x10, // mov rdx, [rax]
    0x89,
    0xD9, // mov ecx, ebx
    0xE8,
    0,
    0,
    0,
    0, // call main
    0x89,
    0xC1, // mov ecx, eax
    0xFF,
    0x15,
    0,
    0,
    0,
    0, // call [exit]
    0xCC, // int3
    0xC3, // 113: ret (the invalid parameter handler)
];

// The rel32 fields of `ENTRY` that call through the import slots, in `ENTRY_IMPORTS` order.
const ENTRY_CALLS: []u64 = [13, 24, 35, 41, 82, 90, 108];

// A DLL's entry: on attach (reason 1) its exit-handler table and the initializers; on detach (0) the
// table's handlers; TRUE. Its unwind information: two pushes and a 40-byte frame. `atexit` then adds
// to the table.
const DLL_ENTRY: [u8; 90] = [
    0x56, // push rsi
    0x57, // push rdi
    0x48,
    0x83,
    0xEC,
    0x28, // sub rsp, 40
    0x83,
    0xFA,
    0x01, // cmp edx, 1
    0x74,
    0x13, // je 30
    0x85,
    0xD2, // test edx, edx
    0x75,
    0x3F, // jne 78
    0x48,
    0x8D,
    0x0D,
    0,
    0,
    0,
    0, // lea rcx, [table]
    0xFF,
    0x15,
    0,
    0,
    0,
    0, // call [_execute_onexit_table]
    0xEB,
    0x30, // jmp 78
    0x48,
    0x8D,
    0x0D,
    0,
    0,
    0,
    0, // 30: lea rcx, [table]
    0xFF,
    0x15,
    0,
    0,
    0,
    0, // call [_initialize_onexit_table]
    0x48,
    0x8D,
    0x35,
    0,
    0,
    0,
    0, // lea rsi, [rip + initializers]
    0x48,
    0x8D,
    0x3D,
    0,
    0,
    0,
    0, // lea rdi, [rip + their end]
    0x48,
    0x39,
    0xFE, // 57: cmp rsi, rdi
    0x73,
    0x10, // jae 78
    0x48,
    0x8B,
    0x06, // mov rax, [rsi]
    0x48,
    0x83,
    0xC6,
    0x08, // add rsi, 8
    0x48,
    0x85,
    0xC0, // test rax, rax
    0x74,
    0xEF, // jz 57
    0xFF,
    0xD0, // call rax
    0xEB,
    0xEB, // jmp 57
    0x48,
    0x83,
    0xC4,
    0x28, // 78: add rsp, 40
    0x5F, // pop rdi
    0x5E, // pop rsi
    0xB8,
    1,
    0,
    0,
    0, // mov eax, 1
    0xC3, // ret
];

// The DLL's `atexit`, after its entry: mov rdx, rcx; lea rcx, [table]; jmp [_register_onexit_function].
const DLL_ATEXIT: u64 = 96;
const DLL_ATEXIT_CODE: [u8; 16] = [0x48, 0x89, 0xCA, 0x48, 0x8D, 0x0D, 0, 0, 0, 0, 0xFF, 0x25, 0, 0, 0, 0];

// The import slot of entry function `name`.
fn entry_slot(l: &L, name: str) u64 {
    return iat_rva(l, res(l, l.glob[l.names.find(name) as usize] - 1));
}

fn write_dll_entry(l: &mut L, img: &mut Vector<u8>) {
    let text = l.osecs[l.o_text as usize];
    let e = (text.off + l.entry_at) as usize;
    let er = text.rva + l.entry_at;
    for i in 0..ENTRY_SIZE as usize {
        img[e + i] = if i < 90 {
            unsafe DLL_ENTRY[i]
        } else if i >= DLL_ATEXIT as usize && i < DLL_ATEXIT as usize + 16 {
            unsafe DLL_ATEXIT_CODE[i - DLL_ATEXIT as usize]
        } else {
            0xCC
        };
    }
    let rel = |img: &mut Vector<u8>, field: u64, target: u64| {
        lu::p32(img, e + field as usize, target.wrapping_sub(er + field + 4) as u32);
    };
    let table = l.osecs[l.o_data as usize].rva + l.onexit_at;
    let rd = l.osecs[l.o_rdata as usize];
    rel(img, 18, table);
    rel(img, 24, entry_slot(l, "_execute_onexit_table"));
    rel(img, 33, table);
    rel(img, 39, entry_slot(l, "_initialize_onexit_table"));
    rel(img, 46, rd.rva + l.xc_lo);
    rel(img, 53, rd.rva + l.xc_hi);
    rel(img, DLL_ATEXIT + 6, table);
    rel(img, DLL_ATEXIT + 12, entry_slot(l, "_register_onexit_function"));
    let x = (rd.off + l.xdata_at) as usize;
    let xd: [u8; 12] = [0x01, 0x06, 0x03, 0x00, 0x06, 0x42, 0x02, 0x70, 0x01, 0x60, 0x00, 0x00];
    for i in 0..12usize {
        img[x + i] = unsafe xd[i];
    }
    let pd = l.osecs[l.o_pdata as usize];
    let pe = (pd.off + l.entry_pdata_at) as usize;
    lu::p32(img, pe, er as u32);
    lu::p32(img, pe + 4, (er + 90) as u32);
    lu::p32(img, pe + 8, (rd.rva + l.xdata_at) as u32);
}

// A DLL's export directory: its name, then the addresses, the names and their ordinals, all exports
// named and ordered by name.
fn write_exports(l: &L, o: &Opts, img: &mut Vector<u8>) {
    let rd = l.osecs[l.o_rdata as usize];
    let d = (rd.off + l.edata_at) as usize;
    let dr = rd.rva + l.edata_at;
    let n = l.exports.len() as u64;
    let eat = dr + 40;
    let enpt = eat + 4 * n;
    let eord = enpt + 4 * n;
    let mut str_at = eord + 2 * n;
    let leaf = base_name(&o.out);
    let name_rva = str_at;
    for i in 0..leaf.len() {
        img[d + (str_at - dr) as usize + i] = leaf.byte_at(i);
    }
    str_at += leaf.len() as u64 + 1;
    lu::p32(img, d + 12, name_rva as u32);
    lu::p32(img, d + 16, 1);
    lu::p32(img, d + 20, n as u32);
    lu::p32(img, d + 24, n as u32);
    lu::p32(img, d + 28, eat as u32);
    lu::p32(img, d + 32, enpt as u32);
    lu::p32(img, d + 36, eord as u32);
    for i in 0..l.exports.len() {
        let g = l.exports[i];
        lu::p32(img, d + (eat - dr) as usize + 4 * i, g_rva(l, g) as u32);
        lu::p32(img, d + (enpt - dr) as usize + 4 * i, str_at as u32);
        lu::p16(img, d + (eord - dr) as usize + 2 * i, i as u32);
        let s = l.names.spell(l.gs[g as usize].name);
        for q in 0..s.len() {
            img[d + (str_at - dr) as usize + q] = s.byte_at(q);
        }
        str_at += s.len() as u64 + 1;
    }
}

const fn base_name(p: str) str {
    let mut i = p.len();
    while i > 0 && p.byte_at(i - 1) != b'/' && p.byte_at(i - 1) != b'\\' {
        i -= 1;
    }
    return p.slice(i, p.len());
}

fn write_synthetic(l: &mut L, o: &Opts, main: u32, img: &mut Vector<u8>) {
    if l.shared {
        write_dll_entry(l, img);
        write_exports(l, o, img);
    } else {
        write_entry(l, main, img);
    }
    write_tables(l, img);
}

fn write_entry(l: &mut L, main: u32, img: &mut Vector<u8>) {
    let text = l.osecs[l.o_text as usize];
    let e = (text.off + l.entry_at) as usize;
    let er = text.rva + l.entry_at;
    for i in 0..ENTRY_SIZE as usize {
        img[e + i] = if i < 114 {
            unsafe ENTRY[i]
        } else {
            0xCC
        };
    }
    let rel = |img: &mut Vector<u8>, field: u64, target: u64| {
        lu::p32(img, e + field as usize, target.wrapping_sub(er + field + 4) as u32);
    };
    rel(img, 7, er + 113);
    for i in 0..ENTRY_IMPORTS.len() {
        let g = res(l, l.glob[l.names.find(ENTRY_IMPORTS[i]) as usize] - 1);
        rel(img, ENTRY_CALLS[i], iat_rva(l, g));
    }
    let rd = l.osecs[l.o_rdata as usize];
    rel(img, 48, rd.rva + l.xc_lo);
    rel(img, 55, rd.rva + l.xc_hi);
    rel(img, 100, g_rva(l, main));
    // Its unwind information: version 1, a 4-byte prologue, one code: a small allocation of 40 bytes.
    let x = (rd.off + l.xdata_at) as usize;
    let xd: [u8; 8] = [0x01, 0x04, 0x01, 0x00, 0x04, 0x42, 0x00, 0x00];
    for i in 0..8usize {
        img[x + i] = unsafe xd[i];
    }
    let pd = l.osecs[l.o_pdata as usize];
    let pe = (pd.off + l.entry_pdata_at) as usize;
    lu::p32(img, pe, er as u32);
    lu::p32(img, pe + 4, (er + 114) as u32);
    lu::p32(img, pe + 8, (rd.rva + l.xdata_at) as u32);
}

// The import thunks, the TLS directory, the import tables and the sorted exception table.
fn write_tables(l: &mut L, img: &mut Vector<u8>) {
    let text = l.osecs[l.o_text as usize];
    let rd = l.osecs[l.o_rdata as usize];
    // The thunks: jmp [slot].
    for i in 0..l.imports.len() {
        let g = l.imports[i];
        let t = (text.off + l.thunks_at + 8 * i as u64) as usize;
        let tr = text.rva + l.thunks_at + 8 * i as u64;
        img[t] = 0xFF;
        img[t + 1] = 0x25;
        lu::p32(img, t + 2, iat_rva(l, g).wrapping_sub(tr + 6) as u32);
        img[t + 6] = 0xCC;
        img[t + 7] = 0xCC;
    }
    // The TLS directory: the template's start and end, the index's address, the empty callback list
    // (the directory's last 8 bytes), no zero fill, the template's alignment.
    if l.o_tls != NONE {
        let tl = l.osecs[l.o_tls as usize];
        let d = (rd.off + l.tlsdir_at) as usize;
        let dr = rd.rva + l.tlsdir_at;
        lu::p64(img, d, l.base + tl.rva);
        lu::p64(img, d + 8, l.base + tl.rva + tl.size);
        lu::p64(img, d + 16, l.base + l.osecs[l.o_data as usize].rva + l.tls_index_at);
        lu::p64(img, d + 24, l.base + dr + 40);
        lu::p32(img, d + 32, 0);
        lu::p32(img, d + 36, tl.align.trailing_zeros() as u32 + 1 << 20);
        for q in 0..4u64 {
            l.relocs.push((dr + 8 * q) as u32);
        }
    }
    write_imports(l, img);
    // The exception table, sorted by function start.
    let pd2 = l.osecs[l.o_pdata as usize];
    let n = (pd2.size / 12) as usize;
    let mut keyed = Vector::<u64>::with_capacity(n);
    for i in 0..n {
        keyed.push(lu::r32(img.as_slice(), pd2.off as usize + 12 * i) as u64 << 32 | i as u64);
    }
    keyed.sort();
    let mut sorted = Vector::<u8>::with_capacity(12 * n);
    for i in 0..n {
        let j = pd2.off as usize + 12 * (keyed[i] & 0xFFFFFFFF) as usize;
        for q in 0..12usize {
            sorted.push(img[j + q]);
        }
    }
    for i in 0..sorted.len() {
        img[pd2.off as usize + i] = sorted[i];
    }
}

// The import directory: per DLL its lookup table and its address table (the same hint/name entries
// until the loader binds them), then the hint/name entries and the DLL names.
const fn write_imports(l: &L, img: &mut Vector<u8>) {
    let id = l.osecs[l.o_idata as usize];
    let (lookup, iat) = import_tables(l);
    let mut names = iat + (iat - lookup);
    let mut slot: u64 = 0;
    let mut dir = id.off as usize;
    for li in 0..l.libs.len() {
        if !l.libs[li].used {
            continue;
        }
        let first = slot;
        for i in 0..l.imports.len() {
            let gy = l.gs[l.imports[i] as usize];
            if gy.lib != li as u32 {
                continue;
            }
            let hn = names;
            let ho = (id.off + hn - id.rva) as usize;
            lu::p16(img, ho, gy.hint);
            let s = l.names.spell(gy.name);
            for q in 0..s.len() {
                img[ho + 2 + q] = s.byte_at(q);
            }
            names += lu::align_up(2 + s.len() as u64 + 1, 2);
            lu::p64(img, (id.off + lookup + 8 * slot - id.rva) as usize, hn);
            lu::p64(img, (id.off + iat + 8 * slot - id.rva) as usize, hn);
            slot += 1;
        }
        slot += 1; // the zero entry
        let dn = names;
        let dll = l.libs[li].dll.as_str();
        for q in 0..dll.len() {
            img[(id.off + dn - id.rva) as usize + q] = dll.byte_at(q);
        }
        names += dll.len() as u64 + 1;
        lu::p32(img, dir, (lookup + 8 * first) as u32);
        lu::p32(img, dir + 12, dn as u32);
        lu::p32(img, dir + 16, (iat + 8 * first) as u32);
        dir += 20;
    }
}

// ---- headers --------------------------------------------------------------------------------------------

// The base relocations, the section headers' names (a long one in the string table), the headers.
fn finish(l: &mut L, o: &Opts, img: &mut Vector<u8>) {
    // `.reloc`: per 4 KiB page its address, its size and a 16-bit entry per address (type DIR64), padded
    // to 4 bytes.
    l.relocs.sort();
    let mut rb = Vector::<u8>::new();
    let mut i: usize = 0;
    // Each step writes one page's block.
    while i < l.relocs.len() {
        let page = l.relocs[i] & ~0xFFFu32;
        let start = rb.len();
        lu::w32(&mut rb, page);
        lu::w32(&mut rb, 0);
        while i < l.relocs.len() && (l.relocs[i] & ~0xFFFu32) == page {
            lu::w16(&mut rb, 0xA000 | l.relocs[i] & 0xFFF);
            i += 1;
        }
        if (rb.len() - start) % 4 != 0 {
            lu::w16(&mut rb, 0);
        }
        let sz = (rb.len() - start) as u32;
        lu::p32(&mut rb, start + 4, sz);
    }
    // It goes last.
    let mut rel_rva = lu::align_up(headers_size(l.osecs.len() + 1), SECT_ALIGN);
    for k in 0..l.osecs.len() {
        rel_rva = rel_rva.max(lu::align_up(l.osecs[k].rva + l.osecs[k].size, SECT_ALIGN));
    }
    let rel_off = img.len() as u64;
    let rel_raw = lu::align_up(rb.len() as u64, FILE_ALIGN);
    let rel_vsz = lu::align_up(rb.len() as u64, SECT_ALIGN);
    let nrel_sec = (rb.len() != 0) as usize;
    img.extend_from_slice(&rb);
    img.resize_default((rel_off + rel_raw) as usize);
    // The string table for the long section and symbol names; unless stripped, the COFF symbol table GNU
    // ld keeps: each named symbol of a loaded section, by its output section and offset in it.
    let mut strs = Vector::<u8>::new();
    lu::w32(&mut strs, 0);
    let mut hdr_names = Vector::<String>::new();
    for k in 0..l.osecs.len() {
        let n = l.sn.spell(l.osecs[k].name);
        if n.len() <= 8 {
            hdr_names.push(String::from_str(n));
        } else {
            hdr_names.push(format("/{}", strs.len()));
            let _ = lu::put_str(&mut strs, n);
        }
    }
    let mut syms = Vector::<u8>::new();
    let mut nsyms: u32 = 0;
    for f in 0..l.files.len() {
        let fl = l.files[f];
        for k in fl.sym0..fl.sym0 + fl.nsym {
            let y = l.syms[k as usize];
            if o.strip || y.class != CLASS_EXTERNAL && y.class != CLASS_STATIC || y.sec <= 0 {
                continue;
            }
            let sc = l.secs[(fl.sec0 + y.sec as u32 - 1) as usize];
            let n = l.names.spell(y.name);
            if sc.out == NONE || n.len() == 0 || n.starts_with(".") || (l.osecs[sc.out as usize].flags & SCN_DISCARDABLE) != 0 {
                continue;
            }
            if n.len() <= 8 {
                for i in 0..8usize {
                    syms.push(
                        if i < n.len() {
                            n.byte_at(i)
                        } else {
                            0u8
                        },
                    );
                }
            } else {
                lu::w32(&mut syms, 0);
                let at = lu::put_str(&mut strs, n);
                lu::w32(&mut syms, at);
            }
            lu::w32(&mut syms, (sc.at + y.value as u64) as u32);
            lu::w16(&mut syms, sc.out + 1);
            lu::w16(
                &mut syms,
                if (sc.flags & SCN_CODE) != 0 {
                    0x20u32
                } else {
                    0u32
                },
            );
            syms.push(y.class);
            syms.push(0);
            nsyms += 1;
        }
    }
    let sym_off = if strs.len() > 4 || nsyms != 0 {
        img.len() as u64
    } else {
        0u64
    };
    if sym_off != 0 {
        img.extend_from_slice(&syms);
        let n = strs.len() as u32;
        lu::p32(&mut strs, 0, n);
        img.extend_from_slice(&strs);
    }
    // The headers.
    let nsec = l.osecs.len() + nrel_sec;
    let mut h = Vector::<u8>::new();
    lu::w16(&mut h, 0x5A4D);
    for _ in 0..29 {
        lu::w16(&mut h, 0);
    }
    lu::w32(&mut h, 64);
    lu::w32(&mut h, 0x00004550);
    lu::w16(&mut h, 0x8664);
    lu::w16(&mut h, nsec as u32);
    lu::w32(&mut h, 0);
    lu::w32(&mut h, sym_off as u32);
    lu::w32(&mut h, nsyms);
    lu::w16(&mut h, 240);
    // An executable image, large-address aware; a DLL.
    lu::w16(
        &mut h,
        if l.shared {
            0x2022u32
        } else {
            0x0022u32
        },
    );
    // The optional header.
    let mut code: u64 = 0;
    let mut idata: u64 = 0;
    let mut udata: u64 = 0;
    for k in 0..l.osecs.len() {
        let os = &l.osecs[k];
        if (os.flags & SCN_CODE) != 0 {
            code += os.raw;
        } else if (os.flags & SCN_UDATA) != 0 {
            udata += lu::align_up(os.size, FILE_ALIGN);
        } else {
            idata += os.raw;
        }
    }
    idata += rel_raw * nrel_sec as u64;
    let image_end = rel_rva + rel_vsz * nrel_sec as u64;
    let text = &l.osecs[l.o_text as usize];
    lu::w16(&mut h, 0x20B);
    h.push(14);
    h.push(0);
    lu::w32(&mut h, code as u32);
    lu::w32(&mut h, idata as u32);
    lu::w32(&mut h, udata as u32);
    lu::w32(&mut h, (text.rva + l.entry_at) as u32);
    lu::w32(&mut h, text.rva as u32);
    lu::w64(&mut h, l.base);
    lu::w32(&mut h, SECT_ALIGN as u32);
    lu::w32(&mut h, FILE_ALIGN as u32);
    lu::w16(&mut h, 6);
    lu::w16(&mut h, 0);
    lu::w16(&mut h, 0);
    lu::w16(&mut h, 0);
    lu::w16(&mut h, 6);
    lu::w16(&mut h, 0);
    lu::w32(&mut h, 0);
    lu::w32(&mut h, image_end as u32);
    lu::w32(&mut h, lu::align_up(headers_size(nsec), FILE_ALIGN) as u32);
    lu::w32(&mut h, 0);
    lu::w16(&mut h, 3); // the console subsystem
    // High-entropy addresses, a movable image, no-execute data, terminal-server aware.
    lu::w16(&mut h, 0x8160);
    // The stack (mingw-w64's 2 MiB reserved unless the link names its size) and mingw-w64's heap defaults.
    lu::w64(
        &mut h,
        if o.stack != 0 {
            o.stack
        } else {
            0x200000u64
        },
    );
    lu::w64(&mut h, 0x1000);
    lu::w64(&mut h, 0x100000);
    lu::w64(&mut h, 0x1000);
    lu::w32(&mut h, 0);
    lu::w32(&mut h, 16);
    // The data directories: import, exception, base relocation, TLS, import address table.
    let (_lookup, iat) = import_tables(l);
    let mut nlib: u64 = 0;
    for li in 0..l.libs.len() {
        nlib += l.libs[li].used as u64;
    }
    let idt = l.osecs[l.o_idata as usize].rva;
    let pd = &l.osecs[l.o_pdata as usize];
    for d in 0..16u32 {
        let (rva, size) = if d == 0 && l.shared {
            (l.osecs[l.o_rdata as usize].rva + l.edata_at, l.edata_size)
        } else if d == 1 {
            (idt, 20 * (nlib + 1))
        } else if d == 3 {
            (pd.rva, pd.size)
        } else if d == 5 && nrel_sec != 0 {
            (rel_rva, rb.len() as u64)
        } else if d == 9 && l.o_tls != NONE {
            (l.osecs[l.o_rdata as usize].rva + l.tlsdir_at, 40u64)
        } else if d == 12 {
            (iat, 8 * (l.imports.len() as u64 + nlib))
        } else {
            (0u64, 0u64)
        };
        lu::w32(&mut h, rva as u32);
        lu::w32(&mut h, size as u32);
    }
    // The section headers, `.reloc` last.
    for k in 0..l.osecs.len() {
        let os = &l.osecs[k];
        section_header(&mut h, &hdr_names[k], os.size, os.rva, os.raw, os.off, os.flags);
    }
    if nrel_sec != 0 {
        section_header(&mut h, ".reloc", rb.len() as u64, rel_rva, rel_raw, rel_off, out_flags(".reloc"));
    }
    assert(h.len() as u64 == headers_size(nsec), "pe: the headers' size");
    for q in 0..h.len() {
        img[q] = h[q];
    }
}

fn section_header(h: &mut Vector<u8>, name: str, vsize: u64, rva: u64, raw: u64, off: u64, flags: u32) {
    for i in 0..8usize {
        h.push(
            if i < name.len() {
                name.byte_at(i)
            } else {
                0u8
            },
        );
    }
    lu::w32(h, vsize as u32);
    lu::w32(h, rva as u32);
    lu::w32(h, raw as u32);
    lu::w32(
        h,
        if raw == 0 {
            0u32
        } else {
            off as u32
        },
    );
    lu::w32(h, 0);
    lu::w32(h, 0);
    lu::w32(h, 0);
    lu::w32(h, flags);
}
