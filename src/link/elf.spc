// The ELF linker for x86-64 and arm64 Linux: objects plus the system's shared libraries (glibc's, read
// for their exported symbols and versions) into a position-independent executable or a shared library.
// Imports bind at load (BIND_NOW): a call to an imported function goes through a stub that jumps through
// its GOT slot; a pointer in writable data is a dynamic relocation. The executable starts at its own
// `_start`, which calls glibc's `__libc_start_main` (version GLIBC_2.34, which runs the executable's
// initializers itself) with `main`. Thread-local accesses relax to the local-exec model in an
// executable and to initial-exec in a shared library, which exports its default-visibility globals and
// leaves what no input defines to the program that loads it. The image carries
// `.eh_frame` with its binary search table, the symbol table, the debug sections with their
// relocations applied, and the section headers.
import link::util as lu;
import link::ar;
import target::native as nat;
import utils::names as nm;
import std::platform::fs;

const NONE: u32 = 0xFFFFFFFF;

/// What a link produces: an executable, or a shared library (`soname` its name).
pub(package) const K_EXE: u8 = 0;
pub(package) const K_SHARED: u8 = 1;

/// A link: the objects, the libraries (`-l` names searched in `dirs`, then the system's directories
/// under `sysroot`), the output, the instruction set (`a64`: arm64, else x86-64), and whether to leave
/// out the symbol table and the debug sections (`strip`).
pub(package) struct Opts {
    pub(package) out: String,
    pub(package) kind: u8,
    pub(package) objs: Vector<String>,
    pub(package) libs: Vector<String>,
    pub(package) dirs: Vector<String>,
    pub(package) sysroot: String,
    pub(package) a64: bool,
    pub(package) strip: bool,
    pub(package) soname: String,
    /// A shared library's exports: None, every default-visibility global; else the globals named.
    pub(package) exports: Option<Set<String>>,
}

const SHT_PROGBITS: u32 = 1;
const SHT_SYMTAB: u32 = 2;
const SHT_STRTAB: u32 = 3;
const SHT_RELA: u32 = 4;
const SHT_HASH: u32 = 5;
const SHT_DYNAMIC: u32 = 6;
const SHT_NOBITS: u32 = 8;
const SHT_DYNSYM: u32 = 11;
const SHT_INIT_ARRAY: u32 = 14;
const SHT_FINI_ARRAY: u32 = 15;
const SHT_PREINIT_ARRAY: u32 = 16;
const SHT_GROUP: u32 = 17;
const SHT_X86_64_UNWIND: u32 = 0x70000001;
const SHT_GNU_VERDEF: u32 = 0x6FFFFFFD;
const SHT_GNU_VERNEED: u32 = 0x6FFFFFFE;
const SHT_GNU_VERSYM: u32 = 0x6FFFFFFF;

const SHF_WRITE: u64 = 1;
const SHF_ALLOC: u64 = 2;
const SHF_EXECINSTR: u64 = 4;
const SHF_TLS: u64 = 0x400;

const SHN_UNDEF: u32 = 0;
const SHN_ABS: u32 = 0xFFF1;
const SHN_COMMON: u32 = 0xFFF2;

const STB_LOCAL: u8 = 0;
const STB_GLOBAL: u8 = 1;
const STB_WEAK: u8 = 2;
const STT_NOTYPE: u8 = 0;
const STT_OBJECT: u8 = 1;
const STT_FUNC: u8 = 2;
const STT_SECTION: u8 = 3;
const STT_FILE: u8 = 4;
const STT_TLS: u8 = 6;
const STT_GNU_IFUNC: u8 = 10;
const STV_DEFAULT: u8 = 0;

const PT_LOAD: u32 = 1;
const PT_DYNAMIC: u32 = 2;
const PT_INTERP: u32 = 3;
const PT_PHDR: u32 = 6;
const PT_TLS: u32 = 7;
const PT_GNU_EH_FRAME: u32 = 0x6474E550;
const PT_GNU_STACK: u32 = 0x6474E551;
const PT_GNU_RELRO: u32 = 0x6474E552;

const DT_NULL: u64 = 0;
const DT_NEEDED: u64 = 1;
const DT_HASH: u64 = 4;
const DT_STRTAB: u64 = 5;
const DT_SYMTAB: u64 = 6;
const DT_RELA: u64 = 7;
const DT_RELASZ: u64 = 8;
const DT_RELAENT: u64 = 9;
const DT_STRSZ: u64 = 10;
const DT_SYMENT: u64 = 11;
const DT_DEBUG: u64 = 21;
const DT_INIT_ARRAY: u64 = 25;
const DT_FINI_ARRAY: u64 = 26;
const DT_INIT_ARRAYSZ: u64 = 27;
const DT_FINI_ARRAYSZ: u64 = 28;
const DT_FLAGS: u64 = 30;
const DT_PREINIT_ARRAY: u64 = 32;
const DT_PREINIT_ARRAYSZ: u64 = 33;
const DT_RELACOUNT: u64 = 0x6FFFFFF9;
const DT_FLAGS_1: u64 = 0x6FFFFFFB;
const DT_VERSYM: u64 = 0x6FFFFFF0;
const DT_VERNEED: u64 = 0x6FFFFFFE;
const DT_VERNEEDNUM: u64 = 0x6FFFFFFF;
const DF_BIND_NOW: u64 = 8;
const DF_STATIC_TLS: u64 = 0x10;
const DT_SONAME: u64 = 14;
const DF_1_NOW: u64 = 1;
const DF_1_PIE: u64 = 0x08000000;

// x86-64 relocation types.
const X_64: u32 = 1;
const X_PC32: u32 = 2;
const X_PLT32: u32 = 4;
const X_GLOB_DAT: u32 = 6;
const X_RELATIVE: u32 = 8;
const X_GOTPCREL: u32 = 9;
const X_32: u32 = 10;
const X_32S: u32 = 11;
const X_TLSGD: u32 = 19;
const X_GOTTPOFF: u32 = 22;
const X_TPOFF32: u32 = 23;
const X_PC64: u32 = 24;
const X_TPOFF64: u32 = 18;
const X_GOTPCRELX: u32 = 41;
const X_REX_GOTPCRELX: u32 = 42;

// arm64 relocation types.
const A_ABS64: u32 = 257;
const A_ABS32: u32 = 258;
const A_PREL64: u32 = 260;
const A_PREL32: u32 = 261;
const A_LD_PREL_LO19: u32 = 273;
const A_ADR_PREL_LO21: u32 = 274;
const A_ADR_PREL_PG_HI21: u32 = 275;
const A_ADD_ABS_LO12_NC: u32 = 277;
const A_LDST8_ABS_LO12_NC: u32 = 278;
const A_TSTBR14: u32 = 279;
const A_CONDBR19: u32 = 280;
const A_JUMP26: u32 = 282;
const A_CALL26: u32 = 283;
const A_LDST16_ABS_LO12_NC: u32 = 284;
const A_LDST32_ABS_LO12_NC: u32 = 285;
const A_LDST64_ABS_LO12_NC: u32 = 286;
const A_LDST128_ABS_LO12_NC: u32 = 299;
const A_ADR_GOT_PAGE: u32 = 311;
const A_LD64_GOT_LO12_NC: u32 = 312;
const A_TLSIE_ADR_GOTTPREL_PAGE21: u32 = 541;
const A_TLSIE_LD64_GOTTPREL_LO12_NC: u32 = 542;
const A_TLSLE_MOVW_TPREL_G2: u32 = 544;
const A_TLSLE_MOVW_TPREL_G0_NC: u32 = 548;
const A_TLSLE_ADD_TPREL_HI12: u32 = 549;
const A_TLSLE_ADD_TPREL_LO12: u32 = 550;
const A_TLSLE_ADD_TPREL_LO12_NC: u32 = 551;
const A_TLSLE_LDST8_TPREL_LO12: u32 = 552;
const A_TLSLE_LDST64_TPREL_LO12_NC: u32 = 559;
const A_TLSLE_LDST128_TPREL_LO12: u32 = 570;
const A_TLSLE_LDST128_TPREL_LO12_NC: u32 = 571;
const A_TLSDESC_ADR_PAGE21: u32 = 562;
const A_TLSDESC_LD64_LO12: u32 = 563;
const A_TLSDESC_ADD_LO12: u32 = 564;
const A_TLSDESC_CALL: u32 = 569;
const A_GLOB_DAT: u32 = 1025;
const A_RELATIVE: u32 = 1027;
const A_TLS_TPREL64: u32 = 1030;

// The system directories glibc's own linker searches, per instruction set.
const DIRS_X64: [str; 6] = [
    "/lib/x86_64-linux-gnu",
    "/usr/lib/x86_64-linux-gnu",
    "/lib64",
    "/usr/lib64",
    "/lib",
    "/usr/lib",
];
const DIRS_A64: [str; 6] = [
    "/lib/aarch64-linux-gnu",
    "/usr/lib/aarch64-linux-gnu",
    "/lib64",
    "/usr/lib64",
    "/lib",
    "/usr/lib",
];

// An input file: its bytes in the blob, its sections (one per section header) and symbols.
struct IFile {
    pub(package) path: u32,
    pub(package) at: usize,
    pub(package) sec0: u32,
    pub(package) nsec: u32,
    pub(package) sym0: u32,
    pub(package) nsym: u32,
}

// An input section: name (`sn` id), type, flags, alignment, size, its bytes in the blob, the index of the
// relocation section that applies to it (NONE: none), and where it lands.
struct ISec {
    pub(package) file: u32,
    pub(package) name: u32,
    pub(package) ty: u32,
    pub(package) flags: u64,
    pub(package) align: u64,
    pub(package) size: u64,
    pub(package) off: usize,
    pub(package) rela: u32,
    pub(package) out: u32,
    pub(package) at: u64,
}

// An input symbol.
struct ISym {
    pub(package) name: u32,
    pub(package) info: u8,
    pub(package) other: u8,
    pub(package) shndx: u32,
    pub(package) value: u64,
    pub(package) size: u64,
    pub(package) file: u32,
}

const G_UNDEF: u8 = 0;
const G_DEF: u8 = 1; // an object defines it: `sym`
const G_SHARED: u8 = 2; // library `lib` exports it, version `ver` of that library
const G_COMMON: u8 = 3; // tentative: `size` bytes aligned to `align`, at `at` of `.bss`
const G_SYNTH: u8 = 4; // the linker defines it: image address `at`

struct GSym {
    pub(package) name: u32,
    pub(package) kind: u8,
    pub(package) sym: u32,
    pub(package) lib: u32,
    pub(package) ver: u32, // `vers` index, NONE: unversioned
    pub(package) size: u64,
    pub(package) align: u64,
    pub(package) at: u64,
    pub(package) got: u32,
    pub(package) plt: u32,
    pub(package) dynix: u32, // `.dynsym` index
    pub(package) weak: bool,
    pub(package) used: bool, // a kept relocation refers to it
    pub(package) strong: bool, // an object references it with a global (not weak) undefined symbol
    pub(package) func: bool,
}

// An output section.
struct OSec {
    pub(package) name: u32,
    pub(package) ty: u32,
    pub(package) flags: u64,
    pub(package) align: u64,
    pub(package) rank: u32,
    pub(package) size: u64,
    pub(package) addr: u64,
    pub(package) off: u64,
    pub(package) link: u32,
    pub(package) info: u32,
    pub(package) entsize: u64,
}

// A library: its name for DT_NEEDED and whether a symbol binds to it.
struct Lib {
    pub(package) soname: String,
    pub(package) used: bool,
}

// A symbol version a library defines: its library and name.
struct Ver {
    pub(package) lib: u32,
    pub(package) name: String,
    pub(package) index: u32, // `.gnu.version` index once needed (0: not needed)
}

// A dynamic relocation: at image address `at`, type `ty`, dynamic symbol `sym` (0: none), `addend`.
struct DRel {
    pub(package) at: u64,
    pub(package) ty: u32,
    pub(package) sym: u32,
    pub(package) addend: i64,
}

extend IFile as Copy {}
extend ISec as Copy {}
extend ISym as Copy {}
extend GSym as Copy {}
extend OSec as Copy {}
extend DRel as Copy {}

struct L {
    pub(package) a64: bool,
    pub(package) page: u64,
    pub(package) files: Vector<IFile>,
    pub(package) paths: Vector<String>,
    pub(package) secs: Vector<ISec>,
    pub(package) syms: Vector<ISym>,
    pub(package) names: nm::Names,
    pub(package) sn: nm::Names,
    pub(package) glob: Vector<u32>,
    pub(package) gs: Vector<GSym>,
    pub(package) libs: Vector<Lib>,
    pub(package) vers: Vector<Ver>,
    pub(package) osecs: Vector<OSec>,
    pub(package) got: Vector<u32>, // per slot: its `gs` index
    pub(package) plt: Vector<u32>, // per stub: its `gs` index
    pub(package) drels: Vector<DRel>,
    pub(package) dyns: Vector<u32>, // `.dynsym` after the null entry: `gs` indices
    pub(package) skip: Vector<u64>, // relaxed sequences: (input section << 32 | offset) of each relocation they consume
    pub(package) nfde: u32,
    pub(package) tls_start: u64,
    pub(package) tls_size: u64,
    pub(package) tls_align: u64,
    pub(package) o: Vector<u32>, // output section indices by role (`O_*`)
    pub(package) start_at: u64, // `_start`'s address
    pub(package) nph: u32, // program headers
    pub(package) shared: bool, // a shared library: no entry, exported symbols, thread-locals as initial-exec
    pub(package) lgot: Vector<u32>, // the GOT slots of local symbols (after `got`): their input symbols
    pub(package) lgot_slot: Map<u32, u32>, // input symbol -> its `lgot` slot
    pub(package) tls_keys: Vector<u64>, // a shared library's thread-local GOT slots (after `lgot`): their symbols
    pub(package) tls_slot: Map<u64, u32>, // symbol key (`tls_key`) -> slot
    pub(package) err: String,
}

// Output section roles.
const O_INTERP: usize = 0;
const O_HASH: usize = 1;
const O_DYNSYM: usize = 2;
const O_DYNSTR: usize = 3;
const O_VERSYM: usize = 4;
const O_VERNEED: usize = 5;
const O_RELA: usize = 6;
const O_EHHDR: usize = 7;
const O_EH: usize = 8;
const O_TEXT: usize = 9;
const O_PLT: usize = 10;
const O_DYNAMIC: usize = 11;
const O_GOT: usize = 12;
const O_BSS: usize = 13;
const O_DATA: usize = 14;
const O_COUNT: usize = 15;

/// Link `o`. False with the reason in `err` when it fails.
pub(package) fn link(o: &Opts, err: &mut String) bool {
    let mut l = L {
        a64: o.a64,
        page: if o.a64 {
            0x10000u64;
        } else {
            0x1000u64;
        },
        files: Vector::<IFile>::new(),
        paths: Vector::<String>::new(),
        secs: Vector::<ISec>::new(),
        syms: Vector::<ISym>::new(),
        names: nm::Names::with_capacity(1 << 20, 1 << 14),
        sn: nm::Names::with_capacity(1 << 10, 1 << 6),
        glob: Vector::<u32>::new(),
        gs: Vector::<GSym>::new(),
        libs: Vector::<Lib>::new(),
        vers: Vector::<Ver>::new(),
        osecs: Vector::<OSec>::new(),
        got: Vector::<u32>::new(),
        plt: Vector::<u32>::new(),
        drels: Vector::<DRel>::new(),
        dyns: Vector::<u32>::new(),
        skip: Vector::<u64>::new(),
        nfde: 0,
        tls_start: 0,
        tls_size: 0,
        tls_align: 1,
        o: Vector::<u32>::new(),
        start_at: 0,
        nph: 0,
        shared: o.kind == K_SHARED,
        lgot: Vector::<u32>::new(),
        lgot_slot: Map::<u32, u32>::new(),
        tls_keys: Vector::<u64>::new(),
        tls_slot: Map::<u64, u32>::new(),
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
    // The archives, positional and of the libraries, take part before the shared libraries.
    let mut ars = ar::Archives::new();
    for i in 0..o.objs.len() {
        let p = o.objs[i].as_str();
        if ar::is_archive(p) {
            if !ars.add(nat::OBJ_ELF, p, &mut l.err) {
                return false;
            }
        } else if !read_object(l, p, blob) {
            return false;
        }
    }
    let mut sos = Vector::<String>::new();
    if !lib_files(l, o, &mut sos, &mut ars) {
        return false;
    }
    // An executable's entry references `main` and glibc's start routine.
    let mut main = NONE;
    let mut lsm = NONE;
    if !l.shared {
        main = global(l, l.names.intern("main"));
        lsm = global(l, l.names.intern("__libc_start_main"));
        l.gs.index_mut(main as usize).used = true;
        l.gs.index_mut(lsm as usize).used = true;
    }
    if !resolve_objects(l, 0) || !take_members(l, &mut ars, blob) {
        return false;
    }
    let b = blob.as_slice();
    mark_used(l, b);
    if !load_libraries(l, &sos) || !finish_symbols(l) || !l.shared && !check_glibc(l, lsm) {
        return false;
    }
    if !scan(l, b, lsm) {
        return false;
    }
    layout(l, o, b);
    let end = file_end(l);
    let mut img = Vector::<u8>::new();
    img.resize_default(end as usize);
    copy_sections(l, b, &mut img);
    if !apply(l, b, &mut img) {
        return false;
    }
    if !l.shared {
        write_start(l, main, lsm, &mut img);
    }
    write_synthetic(l, b, &mut img);
    finish(l, o, b, &mut img);
    if !lu::write(o.out.as_str(), img.as_slice(), 0o755) {
        l.err.format_into("cannot write '{}'", o.out.as_str());
        return false;
    }
    return true;
}

// ---- input ----------------------------------------------------------------------------------------------

fn read_object(l: &mut L, path: str, blob: &mut Vector<u8>) bool {
    let at = blob.len();
    if !lu::read_append(path, blob) {
        l.err.format_into("cannot read '{}'", path);
        return false;
    }
    return parse_object(l, path, at, blob);
}

// The static libraries' members the link needs: each one that defines a global a strong reference
// leaves undefined, its own references in turn, until none is left (a pass takes at least one member,
// so the passes are at most the members).
fn take_members(l: &mut L, ars: &mut ar::Archives, blob: &mut Vector<u8>) bool {
    let mut more = ars.paths.len() != 0;
    while more {
        more = false;
        for g in 0..l.gs.len() {
            let gy = l.gs[g];
            if gy.kind != G_UNDEF || !gy.strong {
                continue;
            }
            let am = ars.find(l.names.spell(gy.name));
            if am.is_none() {
                continue;
            }
            let m = am.unwrap();
            ars.take(m);
            let at = blob.len();
            blob.extend_from_slice(ars.bytes(m));
            let f0 = l.files.len();
            if !parse_object(l, ars.name(m).as_str(), at, blob) || !resolve_objects(l, f0) {
                return false;
            }
            more = true;
        }
    }
    return true;
}

// Record the sections and symbols of the object at `at` of the blob, named `path`.
fn parse_object(l: &mut L, path: str, at: usize, blob: &Vector<u8>) bool {
    let b = blob.as_slice();
    let mach: u32 = if l.a64 {
        183;
    } else {
        62;
    };
    if b.len() - at < 64 || lu::r32(b, at) != 0x464C457F || b[at + 4] != 2 || lu::r16(b, at + 16) != 1 || lu::r16(
        b,
        at + 18,
    ) != mach {
        l.err.format_into("'{}' is not a 64-bit relocatable ELF object of the target", path);
        return false;
    }
    l.paths.push(String::from_str(path));
    let fi = l.files.len() as u32;
    let shoff = at + lu::r64(b, at + 0x28) as usize;
    let shnum = lu::r16(b, at + 0x3C) as usize;
    let shstr = lu::r16(b, at + 0x3E) as usize;
    let strs_at = at + lu::r64(b, shoff + 64 * shstr + 24) as usize;
    let sec0 = l.secs.len() as u32;
    let mut symtab: usize = 0;
    for k in 0..shnum {
        let h = shoff + 64 * k;
        let ty = lu::r32(b, h + 4);
        let name = l.sn.intern(lu::cstr(b[strs_at..b.len()], lu::r32(b, h) as usize));
        l.secs.push(
            ISec {
                file: fi,
                name: name,
                ty: ty,
                flags: lu::r64(b, h + 8),
                align: lu::r64(b, h + 48).max(1),
                size: lu::r64(b, h + 32),
                off: at + lu::r64(b, h + 24) as usize,
                rela: NONE,
                out: NONE,
                at: 0,
            },
        );
        if ty == SHT_SYMTAB {
            symtab = h;
        }
    }
    // Each relocation section to the section it applies to.
    for k in 0..shnum {
        let h = shoff + 64 * k;
        if lu::r32(b, h + 4) == SHT_RELA {
            let target = lu::r32(b, h + 44);
            l.secs.index_mut((sec0 + target) as usize).rela = sec0 + k as u32;
        }
    }
    let sym0 = l.syms.len() as u32;
    let mut nsym: u32 = 0;
    if symtab != 0 {
        let so = at + lu::r64(b, symtab + 24) as usize;
        let n = lu::r64(b, symtab + 32) as usize / 24;
        let strh = shoff + 64 * lu::r32(b, symtab + 40) as usize;
        let st = at + lu::r64(b, strh + 24) as usize;
        for k in 0..n {
            let e = so + 24 * k;
            l.syms.push(
                ISym {
                    name: l.names.intern(lu::cstr(b[st..b.len()], lu::r32(b, e) as usize)),
                    info: b[e + 4],
                    other: b[e + 5],
                    shndx: lu::r16(b, e + 6),
                    value: lu::r64(b, e + 8),
                    size: lu::r64(b, e + 16),
                    file: fi,
                },
            );
        }
        nsym = n as u32;
    }
    l.files.push(
        IFile { path: (l.paths.len() - 1) as u32, at: at, sec0: sec0, nsec: shnum as u32, sym0: sym0, nsym: nsym },
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
                ver: NONE,
                size: 0,
                align: 1,
                at: 0,
                got: NONE,
                plt: NONE,
                dynix: 0,
                weak: false,
                used: false,
                strong: false,
                func: false,
            },
        );
        l.glob[id as usize] = l.gs.len() as u32;
    }
    return l.glob[id as usize] - 1;
}

const fn bind_of(y: ISym) u8 {
    return y.info >> 4;
}

const fn type_of(y: ISym) u8 {
    return y.info & 15;
}

// Enter every object's global symbols: a strong definition beats a weak one, two strong ones are an
// error; a tentative one takes the largest size.
fn resolve_objects(l: &mut L, from: usize) bool {
    for f in from..l.files.len() {
        let fl = l.files[f];
        for k in fl.sym0..fl.sym0 + fl.nsym {
            let y = l.syms[k as usize];
            if bind_of(y) == STB_LOCAL {
                continue;
            }
            let g = global(l, y.name);
            let mut gy = l.gs[g as usize];
            if y.shndx == SHN_UNDEF {
                if bind_of(y) == STB_GLOBAL {
                    gy.strong = true;
                }
                l.gs[g as usize] = gy;
                continue;
            }
            if y.shndx == SHN_COMMON {
                if gy.kind != G_DEF {
                    gy.kind = G_COMMON;
                    gy.size = gy.size.max(y.size);
                    gy.align = gy.align.max(y.value);
                }
                l.gs[g as usize] = gy;
                continue;
            }
            let weak = bind_of(y) == STB_WEAK;
            if gy.kind == G_DEF {
                if weak {
                    continue;
                }
                let prev = l.syms[gy.sym as usize];
                if bind_of(prev) != STB_WEAK {
                    l.err.format_into(
                        "duplicate symbol '{}' in '{}' and '{}'",
                        l.names.spell(y.name),
                        l.paths[l.files[prev.file as usize].path as usize].as_str(),
                        l.paths[fl.path as usize].as_str(),
                    );
                    return false;
                }
            }
            gy.kind = G_DEF;
            gy.sym = k;
            gy.func = type_of(y) == STT_FUNC;
            l.gs[g as usize] = gy;
        }
    }
    return true;
}

// ---- libraries ------------------------------------------------------------------------------------------

// The shared libraries `lib_files` found, in order; each one's exports bind the globals still undefined.
fn load_libraries(l: &mut L, sos: &Vector<String>) bool {
    for i in 0..sos.len() {
        if !load_so(l, sos[i].as_str()) {
            return false;
        }
    }
    return true;
}

// The files of each `-l` library of link `o`, then of libc: shared libraries into `sos`, static ones into
// `ars`. A GNU ld script gives each file it names (its `AS_NEEDED` ones too: a library no symbol binds to
// gets no DT_NEEDED anyway).
fn lib_files(l: &mut L, o: &Opts, sos: &mut Vector<String>, ars: &mut ar::Archives) bool {
    let mut names = Vector::<String>::new();
    for i in 0..o.libs.len() {
        names.push(o.libs[i].clone());
    }
    names.push(String::from_str("c"));
    let mut files = Vector::<String>::new();
    for i in 0..names.len() {
        let mut path = String::new();
        let kind = find(o, names[i].as_str(), &mut path);
        if kind == LIB_NONE {
            l.err.format_into("library not found: -l{}", names[i].as_str());
            return false;
        }
        files.truncate(0);
        if kind == LIB_SHARED && !script_files(o, path.as_str(), &mut files) {
            files.push(path);
        } else if kind == LIB_ARCHIVE {
            files.push(path);
        }
        for k in 0..files.len() {
            let f = files[k].as_str();
            if ar::is_archive(f) {
                if !ars.add(nat::OBJ_ELF, f, &mut l.err) {
                    return false;
                }
            } else {
                sos.push(files[k].clone());
            }
        }
    }
    return true;
}

/// What `find_lib` finds.
pub(package) const LIB_NONE: u8 = 0;
pub(package) const LIB_SHARED: u8 = 1;
pub(package) const LIB_ARCHIVE: u8 = 2;

/// Library `-l<name>` of link `o`, as glibc's linker searches: each directory of `dirs`, then the system's,
/// for `lib<name>.so` (a shared library or a GNU ld script), `lib<name>.so.<N>`, then `lib<name>.a`; its
/// path into `path`.
pub(package) fn find(o: &Opts, name: str, path: &mut String) u8 {
    let sys: []str = if o.a64 {
        DIRS_A64;
    } else {
        DIRS_X64;
    };
    let mut dirs = Vector::<String>::new();
    for i in 0..o.dirs.len() {
        dirs.push(o.dirs[i].clone());
    }
    for i in 0..sys.len() {
        dirs.push(format("{}{}", o.sysroot.as_str(), sys[i]));
    }
    for d in 0..dirs.len() {
        let so = format("{}/lib{}.so", dirs[d].as_str(), name);
        if is_file(so.as_str()) {
            path.clear();
            path.push_string(&so);
            return LIB_SHARED;
        }
        let v = newest_version(dirs[d].as_str(), name);
        if v.len() != 0 {
            path.clear();
            path.push_string(&v);
            return LIB_SHARED;
        }
        let a = format("{}/lib{}.a", dirs[d].as_str(), name);
        if is_file(a.as_str()) {
            path.clear();
            path.push_string(&a);
            return LIB_ARCHIVE;
        }
    }
    return LIB_NONE;
}

fn is_file(p: str) bool {
    let m = fs::stat(p);
    return m.is_ok() && m.unwrap().kind == fs::FileKind::File;
}

// The newest `lib<name>.so.<N>` of directory `dir` (the largest N), empty when none.
fn newest_version(dir: str, name: str) String {
    let mut best = String::new();
    let mut best_v: u64 = 0;
    let opened = fs::read_dir(dir);
    if opened.is_err() {
        return best;
    }
    let pre = format("lib{}.so.", name);
    let mut rd = opened.unwrap();
    // Bounded by the directory's entries.
    while let Some(Ok(e)) = rd.next() {
        if !e.name.starts_with(pre.as_str()) {
            continue;
        }
        let rest = e.name.slice(pre.len(), e.name.len());
        let mut v: u64 = 0;
        let mut ok = rest.len() != 0;
        for i in 0..rest.len() {
            let c = rest.byte_at(i);
            if c < b'0' || c > b'9' {
                ok = false;
            } else if ok {
                v = v * 10 + (c - b'0') as u64;
            }
        }
        if ok && (best.len() == 0 || v > best_v) {
            best_v = v;
            best = format("{}/{}", dir, e.name);
        }
    }
    return best;
}

// The files GNU ld script `path` names into `out` (each absolute word ending in `.so`, `.so.<N>` or `.a`),
// under the sysroot of link `o` when the script is and the file is there (a cross C library's scripts name
// their files by full path); false when `path` is an ELF file, not a script.
fn script_files(o: &Opts, path: str, out: &mut Vector<String>) bool {
    let data = lu::read(path);
    if data.is_none() {
        return false;
    }
    let d = data.unwrap();
    if d.len() >= 4 && lu::r32(d.as_slice(), 0) == 0x464C457F {
        return false;
    }
    let root = if o.sysroot.len() != 0 && path.starts_with(o.sysroot.as_str()) {
        o.sysroot.as_str();
    } else {
        "";
    };
    let t = unsafe str::from_raw(d.as_ptr(), d.len());
    let mut i: usize = 0;
    // Each step consumes one word.
    while i < t.len() {
        while i < t.len() && is_script_space(t.byte_at(i)) {
            i += 1;
        }
        let s = i;
        while i < t.len() && !is_script_space(t.byte_at(i)) {
            i += 1;
        }
        let w = t.slice(s, i);
        if w.starts_with("/") && (w.ends_with(".so") || w.contains(".so.") || w.ends_with(".a")) {
            let f = format("{}{}", root, w);
            if root.len() != 0 && !is_file(f.as_str()) {
                out.push(String::from_str(w));
            } else {
                out.push(f);
            }
        }
    }
    return out.len() != 0;
}

const fn is_script_space(c: u8) bool {
    return c == b' ' || c == b'\n' || c == b'\t' || c == b'(' || c == b')';
}

// Load shared library `path`: its soname, its version definitions and its exported symbols; each export
// an undefined global takes binds it here, at the export's default version.
fn load_so(l: &mut L, path: str) bool {
    let data = lu::read(path);
    if data.is_none() {
        l.err.format_into("cannot read '{}'", path);
        return false;
    }
    let d = data.unwrap();
    let b = d.as_slice();
    if b.len() < 64 || lu::r32(b, 0) != 0x464C457F || lu::r16(b, 16) != 3 {
        l.err.format_into("'{}' is not an ELF shared library", path);
        return false;
    }
    let shoff = lu::r64(b, 0x28) as usize;
    let shnum = lu::r16(b, 0x3C) as usize;
    let mut dynsym: usize = 0;
    let mut versym: usize = 0;
    let mut verdef: usize = 0;
    let mut dynamic: usize = 0;
    for k in 0..shnum {
        let h = shoff + 64 * k;
        let ty = lu::r32(b, h + 4);
        if ty == SHT_DYNSYM {
            dynsym = h;
        } else if ty == SHT_GNU_VERSYM {
            versym = h;
        } else if ty == SHT_GNU_VERDEF {
            verdef = h;
        } else if ty == SHT_DYNAMIC {
            dynamic = h;
        }
    }
    if dynsym == 0 {
        l.err.format_into("'{}' has no dynamic symbol table", path);
        return false;
    }
    let strh = shoff + 64 * lu::r32(b, dynsym + 40) as usize;
    let st = lu::r64(b, strh + 24) as usize;
    let strs = b[st..b.len()];
    // The soname: DT_SONAME, else the file's name.
    let mut soname = String::from_str(basename(path));
    if dynamic != 0 {
        let doff = lu::r64(b, dynamic + 24) as usize;
        let dn = lu::r64(b, dynamic + 32) as usize / 16;
        for k in 0..dn {
            if lu::r64(b, doff + 16 * k) == 14 {
                soname = String::from_str(lu::cstr(strs, lu::r64(b, doff + 16 * k + 8) as usize));
            }
        }
    }
    let lib = l.libs.len() as u32;
    l.libs.push(Lib { soname: soname, used: false });
    // Version definitions: index to `vers` entry.
    let mut vix = Vector::<u32>::new();
    if verdef != 0 {
        let mut p = lu::r64(b, verdef + 24) as usize;
        let n = lu::r32(b, verdef + 44) as usize;
        for _ in 0..n {
            let ndx = lu::r16(b, p + 4) as usize;
            let aux = p + lu::r32(b, p + 12) as usize;
            let vname = lu::cstr(strs, lu::r32(b, aux) as usize);
            while vix.len() <= ndx {
                vix.push(NONE);
            }
            vix[ndx] = l.vers.len() as u32;
            l.vers.push(Ver { lib: lib, name: String::from_str(vname), index: 0 });
            let next = lu::r32(b, p + 16) as usize;
            if next == 0 {
                break;
            }
            p += next;
        }
    }
    let so = lu::r64(b, dynsym + 24) as usize;
    let n = lu::r64(b, dynsym + 32) as usize / 24;
    let vs = if versym != 0 {
        lu::r64(b, versym + 24) as usize;
    } else {
        0usize;
    };
    for k in 1..n {
        let e = so + 24 * k;
        let shndx = lu::r16(b, e + 6);
        let bind = b[e + 4] >> 4;
        if shndx == SHN_UNDEF || bind == STB_LOCAL {
            continue;
        }
        let mut ver = NONE;
        if versym != 0 {
            let v = lu::r16(b, vs + 2 * k);
            // A hidden version is an old one: new links take the default.
            if (v & 0x8000) != 0 {
                continue;
            }
            if v as usize < vix.len() && v > 1 {
                ver = vix[v as usize];
            }
        }
        let id = l.names.find(lu::cstr(strs, lu::r32(b, e) as usize));
        if id < 0 || id as usize >= l.glob.len() || l.glob[id as usize] == 0 {
            continue;
        }
        let g = (l.glob[id as usize] - 1) as usize;
        if l.gs[g].kind == G_UNDEF {
            let y = l.gs.index_mut(g);
            y.kind = G_SHARED;
            y.lib = lib;
            y.ver = ver;
            y.func = (b[e + 4] & 15) == STT_FUNC || (b[e + 4] & 15) == STT_GNU_IFUNC;
        }
    }
    return true;
}

const fn basename(p: str) str {
    let mut i = p.len();
    while i > 0 && p.byte_at(i - 1) != b'/' {
        i -= 1;
    }
    return p.slice(i, p.len());
}

// The symbols no input defines: `__dso_handle` is the image itself (the key glibc's `__cxa_atexit` takes);
// a `__sc_zst_<A>` sentinel, a weak reference and any other undefined one are errors but for a weak one,
// which stays zero.
fn finish_symbols(l: &mut L) bool {
    let mut missing = String::new();
    let mut nmiss: usize = 0;
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        if gy.kind != G_UNDEF {
            continue;
        }
        let s = l.names.spell(gy.name);
        if s == "__dso_handle" || s == "__ehdr_start" {
            l.gs.index_mut(g).kind = G_SYNTH;
            continue;
        }
        if !gy.used || !gy.strong {
            continue;
        }
        if l.shared {
            // The program that loads the library defines it; bound weakly, it does not stop the load.
            let m = l.gs.index_mut(g);
            m.kind = G_SHARED;
            m.lib = NONE;
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

// glibc 2.34's `__libc_start_main` runs the executable's initializers itself; an older one leaves them to
// the C toolchain's start files.
fn check_glibc(l: &mut L, lsm: u32) bool {
    let gy = l.gs[lsm as usize];
    if gy.kind == G_SHARED && gy.ver != NONE {
        let v = l.vers[gy.ver as usize].name.as_str();
        if v.starts_with("GLIBC_2.") {
            let minor = v.slice(8, v.len());
            let mut m: u32 = 0;
            for i in 0..minor.len() {
                let c = minor.byte_at(i);
                if c < b'0' || c > b'9' {
                    break;
                }
                m = m * 10 + (c - b'0') as u32;
            }
            if m >= 34 {
                return true;
            }
        }
    }
    l.err.push_str("the C library is not glibc 2.34 or later: its `__libc_start_main` does not run the initializers");
    return false;
}

// ---- relocation scan ------------------------------------------------------------------------------------

// The global an input symbol refers to (NONE: a local symbol).
const fn gof(l: &L, k: u32) u32 {
    let y = l.syms[k as usize];
    if bind_of(y) == STB_LOCAL {
        return NONE;
    }
    return l.glob[y.name as usize] - 1;
}

// Whether input section `s` is part of the loaded image.
const fn alloc(s: ISec) bool {
    return (s.flags & SHF_ALLOC) != 0;
}

// Whether input section `s` is kept at all: loaded, or debug information.
const fn kept(l: &L, s: ISec) bool {
    if s.ty == SHT_RELA || s.ty == SHT_SYMTAB || s.ty == SHT_STRTAB || s.ty == SHT_GROUP || s.ty == 0 {
        return false;
    }
    return alloc(s) || l.sn.spell(s.name).starts_with(".debug_");
}

// One relocation of a section: offset, type, symbol (file-relative), addend.
struct Rel {
    pub(package) off: u64,
    pub(package) ty: u32,
    pub(package) sym: u32,
    pub(package) addend: i64,
}

extend Rel as Copy {}

const fn rel_at(b: []u8, rs: ISec, i: usize) Rel {
    let e = rs.off + 24 * i;
    let info = lu::r64(b, e + 8);
    return Rel {
        off: lu::r64(b, e),
        ty: (info & 0xFFFFFFFF) as u32,
        sym: (info >> 32) as u32,
        addend: lu::r64(b, e + 16) as i64,
    };
}

// Mark relocation `i` of input section `s` consumed by a relaxed sequence.
fn skip_rel(l: &mut L, s: u32, off: u64) {
    l.skip.push(s as u64 << 32 | off);
}

const fn skipped(l: &L, s: u32, off: u64) bool {
    let k = s as u64 << 32 | off;
    let mut lo: usize = 0;
    let mut hi = l.skip.len();
    while lo < hi {
        let mid = (lo + hi) / 2;
        if l.skip[mid] < k {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo < l.skip.len() && l.skip[lo] == k;
}

// What each kept relocation needs: a GOT slot, a stub, a dynamic relocation; relaxed thread-local
// sequences drop their call of `__tls_get_addr`.
// The globals the kept relocations refer to; a relaxed thread-local sequence's call of `__tls_get_addr` is
// no reference.
fn mark_used(l: &mut L, b: []u8) {
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if sc.rela == NONE || !kept(l, sc) {
            continue;
        }
        let rs = l.secs[sc.rela as usize];
        let n = (rs.size / 24) as usize;
        for i in 0..n {
            let r = rel_at(b, rs, i);
            if r.ty == X_TLSGD && !l.a64 {
                // data16 lea x@tlsgd(%rip), %rdi; data16 data16 rex.W call __tls_get_addr@PLT: the call's
                // relocation is 8 bytes on.
                skip_rel(l, s as u32, r.off + 8);
            }
        }
    }
    l.skip.sort();
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if sc.rela == NONE || !kept(l, sc) {
            continue;
        }
        let rs = l.secs[sc.rela as usize];
        let f = l.files[sc.file as usize];
        let n = (rs.size / 24) as usize;
        for i in 0..n {
            let r = rel_at(b, rs, i);
            if skipped(l, s as u32, r.off) {
                continue;
            }
            let g = gof(l, f.sym0 + r.sym);
            if g != NONE {
                l.gs.index_mut(g as usize).used = true;
            }
        }
    }
}

fn scan(l: &mut L, b: []u8, lsm: u32) bool {
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if sc.rela == NONE || !kept(l, sc) {
            continue;
        }
        let rs = l.secs[sc.rela as usize];
        let f = l.files[sc.file as usize];
        let n = (rs.size / 24) as usize;
        for i in 0..n {
            let r = rel_at(b, rs, i);
            if skipped(l, s as u32, r.off) {
                continue;
            }
            let k = f.sym0 + r.sym;
            let g = gof(l, k);
            if g == NONE && tls_ie(l, r.ty) {
                tls_slot(l, g, k);
                continue;
            }
            if g == NONE {
                if alloc(sc) && (sc.flags & SHF_WRITE) != 0 && (r.ty == X_64 && !l.a64 || r.ty == A_ABS64 && l.a64) {
                    l.drels.push(DRel { at: 0, ty: 0, sym: 0, addend: 0 });
                } else if is_got(l, r.ty) && l.lgot_slot.get(&k).is_none() {
                    let n = l.lgot.len() as u32;
                    let _ = l.lgot_slot.insert(k, n);
                    l.lgot.push(k);
                }
                continue;
            }
            l.gs.index_mut(g as usize).used = true;
            let shared = l.gs[g as usize].kind == G_SHARED;
            if tls_ie(l, r.ty) {
                tls_slot(l, g, k);
            } else if is_got(l, r.ty) {
                need_got(l, g);
            } else if (r.ty == X_PLT32 && !l.a64 || (r.ty == A_CALL26 || r.ty == A_JUMP26) && l.a64) && shared {
                if l.gs[g as usize].plt == NONE {
                    l.gs.index_mut(g as usize).plt = l.plt.len() as u32;
                    l.plt.push(g);
                    need_got(l, g);
                }
            } else if (r.ty == X_64 && !l.a64 || r.ty == A_ABS64 && l.a64) && alloc(sc) {
                if (sc.flags & SHF_WRITE) == 0 {
                    l.err.format_into(
                        "'{}': an absolute address in read-only section {}",
                        l.paths[f.path as usize].as_str(),
                        l.sn.spell(sc.name),
                    );
                    return false;
                }
                l.drels.push(DRel { at: 0, ty: 0, sym: 0, addend: 0 });
            } else if shared && alloc(sc) {
                l.err.format_into(
                    "'{}': relocation type {} to '{}', which a library defines",
                    l.paths[f.path as usize].as_str(),
                    r.ty,
                    l.names.spell(l.gs[g as usize].name),
                );
                return false;
            }
        }
    }
    if !l.shared {
        need_got(l, lsm);
    }
    // The binding of each used import; its library is needed.
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        if gy.kind == G_SHARED && gy.used && gy.lib != NONE {
            l.libs.index_mut(gy.lib as usize).used = true;
            if gy.ver != NONE {
                l.vers.index_mut(gy.ver as usize).index = 1;
            }
        }
    }
    return true;
}

// Whether relocation `ty` starts a thread-local sequence a shared library relaxes to initial-exec.
const fn tls_ie(l: &L, ty: u32) bool {
    return l.shared && (ty == X_TLSGD && !l.a64 || (ty == A_TLSDESC_ADR_PAGE21 || ty == A_TLSIE_ADR_GOTTPREL_PAGE21) && l.a64);
}

// The key of thread-local symbol `k` (global `g`, or NONE for a local one).
const fn tls_key(g: u32, k: u32) u64 {
    if g != NONE {
        return 1u64 << 63 | g as u64;
    }
    return k;
}

fn tls_slot(l: &mut L, g: u32, k: u32) {
    let key = tls_key(g, k);
    if l.tls_slot.get(&key).is_none() {
        let n = l.tls_keys.len() as u32;
        let _ = l.tls_slot.insert(key, n);
        l.tls_keys.push(key);
    }
}

// The address of the GOT slot that holds the thread pointer offset of thread-local symbol `k`.
fn tls_got_addr(l: &L, k: u32) u64 {
    let slot = *l.tls_slot.get(&tls_key(gof(l, k), k)).unwrap();
    return l.osecs[l.o[O_GOT] as usize].addr + 8 * (l.got.len() + l.lgot.len() + slot as usize) as u64;
}

// The GOT slot of the target of relocation symbol `k` (global `g`, or NONE for a local one).
fn slot_addr(l: &L, g: u32, k: u32) u64 {
    if g != NONE {
        return got_addr(l, g);
    }
    return l.osecs[l.o[O_GOT] as usize].addr + 8 * (l.got.len() as u64 + (*l.lgot_slot.get(&k).unwrap()) as u64);
}

const fn is_got(l: &L, ty: u32) bool {
    if l.a64 {
        return ty == A_ADR_GOT_PAGE || ty == A_LD64_GOT_LO12_NC;
    }
    return ty == X_GOTPCREL || ty == X_GOTPCRELX || ty == X_REX_GOTPCRELX;
}

fn need_got(l: &mut L, g: u32) {
    if l.gs[g as usize].got == NONE {
        l.gs.index_mut(g as usize).got = l.got.len() as u32;
        l.got.push(g);
    }
}

// ---- layout ---------------------------------------------------------------------------------------------

// The output section named `name`, added when new.
fn out_section(l: &mut L, name: str, ty: u32, flags: u64, rank: u32) u32 {
    let id = l.sn.intern(name);
    for i in 0..l.osecs.len() {
        if l.osecs[i].name == id {
            return i as u32;
        }
    }
    l.osecs.push(
        OSec {
            name: id,
            ty: ty,
            flags: flags,
            align: 1,
            rank: rank,
            size: 0,
            addr: 0,
            off: 0,
            link: 0,
            info: 0,
            entsize: 0,
        },
    );
    return (l.osecs.len() - 1) as u32;
}

// An input section's output name and its rank: the order within the image, which groups the segments.
// R: headers, dynamic linking tables, read-only data, unwind tables; RX: code; RW (relro): thread-local
// templates, initializer arrays, read-only-after-relocation data, the dynamic section, the GOT; RW: data,
// then zero-filled data; then the sections the image does not load.
const fn out_name<'a>(l: &'a L, s: ISec, rank: &mut u32) str<'a> {
    let n = l.sn.spell(s.name);
    if !alloc(s) {
        *rank = 900;
        return n;
    }
    if (s.flags & SHF_TLS) != 0 {
        if s.ty == SHT_NOBITS {
            *rank = 410;
            return ".tbss";
        }
        *rank = 400;
        return ".tdata";
    }
    if (s.flags & SHF_EXECINSTR) != 0 {
        *rank = 300;
        return if n.starts_with(".text") {
            ".text";
        } else {
            n;
        };
    }
    if s.ty == SHT_INIT_ARRAY || n.starts_with(".init_array") {
        *rank = 420;
        return ".init_array";
    }
    if s.ty == SHT_FINI_ARRAY || n.starts_with(".fini_array") {
        *rank = 421;
        return ".fini_array";
    }
    if s.ty == SHT_PREINIT_ARRAY {
        *rank = 419;
        return ".preinit_array";
    }
    if n == ".eh_frame" {
        *rank = 210;
        return n;
    }
    if (s.flags & SHF_WRITE) == 0 {
        *rank = 100;
        return if n.starts_with(".rodata") {
            ".rodata";
        } else {
            n;
        };
    }
    if n.starts_with(".data.rel.ro") {
        *rank = 430;
        return ".data.rel.ro";
    }
    if s.ty == SHT_NOBITS {
        *rank = 600;
        return if n.starts_with(".bss") {
            ".bss";
        } else {
            n;
        };
    }
    *rank = 500;
    return if n.starts_with(".data") {
        ".data";
    } else {
        n;
    };
}

// The segment of rank `r`: 0 R, 1 RX, 2 RW relro, 3 RW, 4 not loaded.
const fn seg_of(r: u32) u32 {
    if r < 300 {
        return 0;
    }
    if r < 400 {
        return 1;
    }
    if r < 500 {
        return 2;
    }
    if r < 900 {
        return 3;
    }
    return 4;
}

fn layout(l: &mut L, o: &Opts, b: []u8) {
    for _ in 0..O_COUNT {
        l.o.push(NONE);
    }
    if !l.shared {
        role(l, O_INTERP, ".interp", SHT_PROGBITS, SHF_ALLOC, 10);
    }
    role(l, O_HASH, ".hash", SHT_HASH, SHF_ALLOC, 11);
    role(l, O_DYNSYM, ".dynsym", SHT_DYNSYM, SHF_ALLOC, 12);
    role(l, O_DYNSTR, ".dynstr", SHT_STRTAB, SHF_ALLOC, 13);
    role(l, O_VERSYM, ".gnu.version", SHT_GNU_VERSYM, SHF_ALLOC, 14);
    role(l, O_VERNEED, ".gnu.version_r", SHT_GNU_VERNEED, SHF_ALLOC, 15);
    role(l, O_RELA, ".rela.dyn", SHT_RELA, SHF_ALLOC, 16);
    role(l, O_TEXT, ".text", SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR, 300);
    if l.plt.len() != 0 {
        role(l, O_PLT, ".plt", SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR, 310);
    }
    role(l, O_DYNAMIC, ".dynamic", SHT_DYNAMIC, SHF_ALLOC | SHF_WRITE, 440);
    role(l, O_GOT, ".got", SHT_PROGBITS, SHF_ALLOC | SHF_WRITE, 450);
    // `_start` leads the code.
    let text = l.o[O_TEXT] as usize;
    l.osecs.index_mut(text).size = if l.shared {
        0u64;
    } else {
        start_size(l.a64);
    };
    l.osecs.index_mut(text).align = 16;
    let mut has_eh = false;
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if !kept(l, sc) || l.sn.spell(sc.name) == ".note.GNU-stack" {
            continue;
        }
        let mut rank: u32 = 0;
        let name = String::from_str(out_name(l, sc, &mut rank));
        let ty = if sc.ty == SHT_X86_64_UNWIND {
            SHT_PROGBITS;
        } else {
            sc.ty;
        };
        let o = out_section(l, name.as_str(), ty, sc.flags & (SHF_ALLOC | SHF_WRITE | SHF_EXECINSTR | SHF_TLS), rank);
        has_eh = has_eh || name.as_str() == ".eh_frame";
        let os = l.osecs.index_mut(o as usize);
        os.align = os.align.max(sc.align);
        os.size = lu::align_up(os.size, sc.align);
        let at = os.size;
        os.size += sc.size;
        let ms = l.secs.index_mut(s);
        ms.out = o;
        ms.at = at;
    }
    // Tentative definitions: in `.bss`.
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        if gy.kind != G_COMMON {
            continue;
        }
        role(l, O_BSS, ".bss", SHT_NOBITS, SHF_ALLOC | SHF_WRITE, 600);
        let os = l.osecs.index_mut(l.o[O_BSS] as usize);
        os.align = os.align.max(gy.align);
        os.size = lu::align_up(os.size, gy.align);
        let at = os.size;
        os.size += gy.size;
        l.gs.index_mut(g).at = at;
    }
    if has_eh {
        l.nfde = count_fdes(l, b);
        role(l, O_EHHDR, ".eh_frame_hdr", SHT_PROGBITS, SHF_ALLOC, 200);
        role(l, O_EH, ".eh_frame", SHT_PROGBITS, SHF_ALLOC, 210);
        let eh = l.o[O_EH];
        // A zero terminator after the frames.
        l.osecs.index_mut(eh as usize).size += 4;
        let hh = l.o[O_EHHDR] as usize;
        l.osecs.index_mut(hh).size = 12 + 8 * l.nfde as u64;
        l.osecs.index_mut(hh).align = 4;
    }
    // The dynamic linking tables' sizes.
    dyn_tables(l, o);
    // Sort by rank, then first appearance; remap the inputs and roles.
    let n = l.osecs.len();
    let mut keys = Vector::<u64>::with_capacity(n);
    for i in 0..n {
        keys.push(l.osecs[i].rank as u64 << 32 | i as u64);
    }
    keys.sort();
    let mut newix = Vector::<u32>::new();
    newix.resize_default(n);
    let mut sorted = Vector::<OSec>::with_capacity(n);
    for i in 0..n {
        let old = (keys[i] & 0xFFFFFFFF) as usize;
        newix[old] = i as u32;
        sorted.push(l.osecs[old]);
    }
    l.osecs = sorted;
    for s in 0..l.secs.len() {
        if l.secs[s].out != NONE {
            l.secs.index_mut(s).out = newix[l.secs[s].out as usize];
        }
    }
    for r in 0..O_COUNT {
        if l.o[r] != NONE {
            let v = newix[l.o[r] as usize];
            l.o[r] = v;
        }
    }
    l.nph = nphdrs(l);
    // Addresses: the headers, then each segment from a new page in memory, its file offset congruent to
    // its address.
    let hdr = 64 + 56 * l.nph as u64;
    let mut off = hdr;
    let mut va = hdr;
    let mut prev_seg: u32 = 0;
    for i in 0..n {
        let os = l.osecs[i];
        let seg = seg_of(os.rank);
        if seg == 4 {
            continue;
        }
        if seg != prev_seg {
            va = lu::align_up(va, l.page) + off % l.page;
            prev_seg = seg;
        }
        if os.ty == SHT_NOBITS {
            va = lu::align_up(va, os.align);
            // No bytes in the file; its offset congruent to its address all the same.
            let mut no = off - off % l.page + va % l.page;
            if no < off {
                no += l.page;
            }
            let m = l.osecs.index_mut(i);
            m.addr = va;
            m.off = no;
            if (os.flags & SHF_TLS) == 0 {
                va += os.size;
            }
            continue;
        }
        off = lu::align_up(off, os.align);
        va = lu::align_up(va, os.align);
        // The file offset congruent to the address within the page: the next such offset.
        if off % l.page != va % l.page {
            let mut no = off - off % l.page + va % l.page;
            if no < off {
                no += l.page;
            }
            off = no;
        }
        let m = l.osecs.index_mut(i);
        m.addr = va;
        m.off = off;
        off += os.size;
        va += os.size;
    }
    // The thread-local template: `.tdata` then `.tbss`.
    let mut first = true;
    for i in 0..n {
        let os = l.osecs[i];
        if (os.flags & SHF_TLS) != 0 {
            if first {
                l.tls_start = os.addr;
                first = false;
            }
            l.tls_size = os.addr + os.size - l.tls_start;
            l.tls_align = l.tls_align.max(os.align);
        }
    }
}

// The output section of role `r`, added when new.
fn role(l: &mut L, r: usize, name: str, ty: u32, flags: u64, rank: u32) {
    let o = out_section(l, name, ty, flags, rank);
    l.o[r] = o;
}

// Whether the image has thread-locals.
const fn has_tls(l: &L) bool {
    for i in 0..l.osecs.len() {
        if (l.osecs[i].flags & SHF_TLS) != 0 {
            return true;
        }
    }
    return false;
}

// Whether loadable segment `seg` has a section.
const fn seg_used(l: &L, seg: u32) bool {
    for i in 0..l.osecs.len() {
        if seg_of(l.osecs[i].rank) == seg {
            return true;
        }
    }
    return seg == 0;
}

// The number of program headers: PHDR, INTERP, a LOAD per used segment, DYNAMIC, GNU_STACK, GNU_RELRO, and
// TLS and GNU_EH_FRAME when the image has thread-locals and frames.
const fn nphdrs(l: &L) u32 {
    let mut n: u32 = 4 + (!l.shared) as u32 + has_tls(l) as u32 + (l.o[O_EHHDR] != NONE) as u32;
    for seg in 0..4u32 {
        n += seg_used(l, seg) as u32;
    }
    return n;
}

// The end of the file's loaded bytes.
const fn file_end(l: &L) u64 {
    let mut e: u64 = 0;
    for i in 0..l.osecs.len() {
        let os = l.osecs[i];
        if seg_of(os.rank) != 4 && os.ty != SHT_NOBITS && os.off + os.size > e {
            e = os.off + os.size;
        }
    }
    return e;
}

// The dynamic linking tables: the symbols (the imports, in binding order), their names and versions, the
// hash table, the needed versions, the relocations and the dynamic section.
fn dyn_tables(l: &mut L, o: &Opts) {
    let mut strsz: u64 = 1 + o.soname.len() as u64 + 1;
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        if gy.kind == G_SHARED && gy.used || l.shared && exported(l, g as u32) && lu::listed(
            &o.exports,
            l.names.spell(gy.name),
        ) {
            l.dyns.push(g as u32);
            l.gs.index_mut(g).dynix = l.dyns.len() as u32;
            strsz += l.names.spell(gy.name).len() as u64 + 1;
        }
    }
    let mut nneed: u64 = 0;
    let mut nver: u64 = 0;
    for i in 0..l.libs.len() {
        if l.libs[i].used {
            nneed += 1;
            strsz += l.libs[i].soname.len() as u64 + 1;
        }
    }
    let mut idx: u32 = 2;
    for v in 0..l.vers.len() {
        if l.vers[v].index != 0 {
            l.vers.index_mut(v).index = idx;
            idx += 1;
            nver += 1;
            strsz += l.vers[v].name.len() as u64 + 1;
        }
    }
    let nsym = l.dyns.len() as u64 + 1;
    if !l.shared {
        set(l, O_INTERP, interp(l).len() as u64 + 1, 1, 0);
    }
    set(l, O_DYNSYM, 24 * nsym, 8, 24);
    set(l, O_DYNSTR, strsz, 1, 0);
    set(l, O_HASH, 8 + 4 * nbucket(nsym) + 4 * nsym, 8, 4);
    set(l, O_VERSYM, 2 * nsym, 2, 2);
    // The libraries with a needed version each get a Verneed record; each version a Vernaux.
    let mut nvlib: u64 = 0;
    for i in 0..l.libs.len() {
        let mut any = false;
        for v in 0..l.vers.len() {
            any = any || l.vers[v].lib == i as u32 && l.vers[v].index != 0;
        }
        if any {
            nvlib += 1;
        }
    }
    set(l, O_VERNEED, 16 * nvlib + 16 * nver, 8, 0);
    // A dynamic relocation per pointer in writable data and per GOT slot (one already per pointer).
    let nrel = l.drels.len() as u64 + l.got.len() as u64 + l.lgot.len() as u64 + l.tls_keys.len() as u64;
    set(l, O_RELA, 24 * nrel, 8, 24);
    let mut ndyn: u64 = nneed + 18;
    for i in 0..l.osecs.len() {
        let nm = l.sn.spell(l.osecs[i].name);
        if nm == ".init_array" || nm == ".fini_array" || nm == ".preinit_array" {
            ndyn += 2;
        }
    }
    set(l, O_DYNAMIC, 16 * ndyn, 8, 16);
    set(l, O_GOT, 8 * (l.got.len() + l.lgot.len() + l.tls_keys.len()) as u64, 8, 8);
    if l.plt.len() != 0 {
        set(l, O_PLT, 16 * l.plt.len() as u64, 16, 16);
    }
}

// The program interpreter, glibc's dynamic linker.
const fn interp(l: &L) str<'static> {
    if l.a64 {
        return "/lib/ld-linux-aarch64.so.1";
    }
    return "/lib64/ld-linux-x86-64.so.2";
}

// Whether a shared library exports global `g`: an object defines it, visible by default.
const fn exported(l: &L, g: u32) bool {
    let gy = l.gs[g as usize];
    if gy.kind == G_COMMON {
        return true;
    }
    return gy.kind == G_DEF && (l.syms[gy.sym as usize].other & 3) == STV_DEFAULT;
}

fn set(l: &mut L, role: usize, size: u64, align: u64, entsize: u64) {
    let os = l.osecs.index_mut(l.o[role] as usize);
    os.size = size;
    os.align = align;
    os.entsize = entsize;
}

const fn nbucket(nsym: u64) u64 {
    return (nsym / 2).max(1);
}

// The frame description entries of the inputs' `.eh_frame` sections.
const fn count_fdes(l: &L, b: []u8) u32 {
    let mut n: u32 = 0;
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if sc.out == NONE || l.sn.spell(sc.name) != ".eh_frame" {
            continue;
        }
        let mut p: usize = 0;
        let e = sc.size as usize;
        // Each step reads one record.
        while p + 8 <= e {
            let len = lu::r32(b, sc.off + p) as usize;
            if len == 0 {
                break;
            }
            if lu::r32(b, sc.off + p + 4) != 0 {
                n += 1;
            }
            p += 4 + len;
        }
    }
    return n;
}

// ---- addresses ------------------------------------------------------------------------------------------

const fn sym_addr(l: &L, k: u32) u64 {
    let y = l.syms[k as usize];
    if y.shndx == SHN_ABS {
        return y.value;
    }
    if y.shndx == SHN_UNDEF || y.shndx >= 0xFF00 {
        return 0;
    }
    let f = l.files[y.file as usize];
    let s = l.secs[(f.sec0 + y.shndx) as usize];
    if s.out == NONE {
        return 0;
    }
    return l.osecs[s.out as usize].addr + s.at + y.value;
}

const fn g_addr(l: &L, g: u32) u64 {
    let gy = l.gs[g as usize];
    if gy.kind == G_DEF {
        return sym_addr(l, gy.sym);
    }
    if gy.kind == G_COMMON {
        return l.osecs[l.o[O_BSS] as usize].addr + gy.at;
    }
    if gy.kind == G_SHARED && gy.plt != NONE {
        return l.osecs[l.o[O_PLT] as usize].addr + 16 * gy.plt as u64;
    }
    return 0;
}

// The address of a relocation's target symbol `k` (a library's function: its stub).
const fn target(l: &L, k: u32) u64 {
    let g = gof(l, k);
    if g == NONE {
        return sym_addr(l, k);
    }
    return g_addr(l, g);
}

const fn got_addr(l: &L, g: u32) u64 {
    return l.osecs[l.o[O_GOT] as usize].addr + 8 * l.gs[g as usize].got as u64;
}

// The thread pointer offset of thread-local address `a`: x86-64 places the block below the thread
// pointer, arm64 after a 16-byte control block.
const fn tpoff(l: &L, a: u64) i64 {
    if l.a64 {
        return (lu::align_up(16, l.tls_align) + a - l.tls_start) as i64;
    }
    return (a - l.tls_start) as i64 - lu::align_up(l.tls_size, l.tls_align) as i64;
}

// ---- section bytes and relocations ----------------------------------------------------------------------

const fn copy_sections(l: &L, b: []u8, img: &mut Vector<u8>) {
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if sc.out == NONE || sc.ty == SHT_NOBITS || seg_of(l.osecs[sc.out as usize].rank) == 4 {
            continue;
        }
        let at = (l.osecs[sc.out as usize].off + sc.at) as usize;
        for i in 0..sc.size as usize {
            img[at + i] = b[sc.off + i];
        }
    }
}

fn apply(l: &mut L, b: []u8, img: &mut Vector<u8>) bool {
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if sc.rela == NONE || sc.out == NONE || seg_of(l.osecs[sc.out as usize].rank) == 4 {
            continue;
        }
        let rs = l.secs[sc.rela as usize];
        let f = l.files[sc.file as usize];
        let os = l.osecs[sc.out as usize];
        let n = (rs.size / 24) as usize;
        for i in 0..n {
            let r = rel_at(b, rs, i);
            if skipped(l, s as u32, r.off) {
                continue;
            }
            let k = f.sym0 + r.sym;
            let p_addr = os.addr + sc.at + r.off;
            let p = (os.off + sc.at + r.off) as usize;
            if !reloc(l, img, s as u32, f, k, r, p_addr, p, (sc.flags & SHF_WRITE) != 0) {
                return false;
            }
        }
    }
    return true;
}

const fn fits(v: i64, bits: u32) bool {
    return v >= -(1i64 << (bits - 1) as i64) && v < 1i64 << (bits - 1) as i64;
}

// Apply relocation `r` (of input section `s`, symbol `k` of file `f`) at image address `pa`, file offset
// `p`.
fn reloc(l: &mut L, img: &mut Vector<u8>, s: u32, f: IFile, k: u32, r: Rel, pa: u64, p: usize, writable: bool) bool {
    let sv = target(l, k);
    let g = gof(l, k);
    let shared = g != NONE && l.gs[g as usize].kind == G_SHARED;
    let sa = sv.wrapping_add(r.addend as u64);
    let path = l.paths[f.path as usize].as_str();
    if !l.a64 {
        if r.ty == X_64 {
            if writable {
                if shared {
                    dyn_rel(l, pa, X_64, l.gs[g as usize].dynix, r.addend);
                } else {
                    dyn_rel(l, pa, X_RELATIVE, 0, sa as i64);
                }
                lu::p64(img, p, 0);
            } else {
                lu::p64(img, p, sa);
            }
            return true;
        }
        if r.ty == X_PC32 || r.ty == X_PLT32 {
            let d = sa.wrapping_sub(pa) as i64;
            if !fits(d, 32) {
                l.err.format_into("'{}': a 32-bit displacement out of range", path);
                return false;
            }
            lu::p32(img, p, d as u32);
            return true;
        }
        if r.ty == X_PC64 {
            lu::p64(img, p, sa.wrapping_sub(pa));
            return true;
        }
        if r.ty == X_GOTPCREL || r.ty == X_GOTPCRELX || r.ty == X_REX_GOTPCRELX {
            let d = slot_addr(l, g, k).wrapping_add(r.addend as u64).wrapping_sub(pa) as i64;
            lu::p32(img, p, d as u32);
            return true;
        }
        if r.ty == X_32 || r.ty == X_32S {
            lu::p32(img, p, sa as u32);
            return true;
        }
        if r.ty == X_TLSGD {
            // Relaxed to local-exec: mov %fs:0, %rax; lea tpoff(%rax), %rax. A shared library's to
            // initial-exec: mov %fs:0, %rax; add slot(%rip), %rax.
            let st = p - 4;
            let seq: [u8; 12] = if l.shared {
                [0x64, 0x48, 0x8B, 0x04, 0x25, 0, 0, 0, 0, 0x48, 0x03, 0x05];
            } else {
                [0x64, 0x48, 0x8B, 0x04, 0x25, 0, 0, 0, 0, 0x48, 0x8D, 0x80];
            };
            for j in 0..12usize {
                img[st + j] = unsafe seq[j];
            }
            let v = if l.shared {
                tls_got_addr(l, k).wrapping_sub(pa - 4 + 16);
            } else {
                tpoff(l, sv) as u64;
            };
            lu::p32(img, st + 12, v as u32);
            let _ = s;
            return true;
        }
        if r.ty == X_TPOFF32 {
            lu::p32(img, p, tpoff(l, sv).wrapping_add(r.addend) as u32);
            return true;
        }
        l.err.format_into("'{}': x86-64 relocation type {} is not supported", path, r.ty);
        return false;
    }
    let insn = lu::r32(img.as_slice(), p);
    if r.ty == A_ABS64 {
        if writable {
            if shared {
                dyn_rel(l, pa, A_ABS64, l.gs[g as usize].dynix, r.addend);
            } else {
                dyn_rel(l, pa, A_RELATIVE, 0, sa as i64);
            }
            lu::p64(img, p, 0);
        } else {
            lu::p64(img, p, sa);
        }
        return true;
    }
    if r.ty == A_ABS32 {
        lu::p32(img, p, sa as u32);
        return true;
    }
    if r.ty == A_PREL32 {
        lu::p32(img, p, sa.wrapping_sub(pa) as u32);
        return true;
    }
    if r.ty == A_PREL64 {
        lu::p64(img, p, sa.wrapping_sub(pa));
        return true;
    }
    if r.ty == A_CALL26 || r.ty == A_JUMP26 {
        let d = sa.wrapping_sub(pa) as i64;
        if !fits(d, 28) {
            l.err.format_into("'{}': a branch beyond 128 MiB", path);
            return false;
        }
        lu::p32(img, p, insn & 0xFC000000 | (d >> 2) as u32 & 0x3FFFFFF);
        return true;
    }
    if r.ty == A_CONDBR19 || r.ty == A_LD_PREL_LO19 {
        let d = sa.wrapping_sub(pa) as i64;
        lu::p32(img, p, insn & 0xFF00001F | ((d >> 2) as u32 & 0x7FFFF) << 5);
        return true;
    }
    if r.ty == A_TSTBR14 {
        let d = sa.wrapping_sub(pa) as i64;
        lu::p32(img, p, insn & 0xFFF8001F | ((d >> 2) as u32 & 0x3FFF) << 5);
        return true;
    }
    if r.ty == A_ADR_PREL_LO21 {
        let d = sa.wrapping_sub(pa) as u32;
        lu::p32(img, p, insn & 0x9F00001F | (d & 3) << 29 | (d >> 2 & 0x7FFFF) << 5);
        return true;
    }
    if r.ty == A_ADR_PREL_PG_HI21 || r.ty == A_ADR_GOT_PAGE {
        let t = if r.ty == A_ADR_GOT_PAGE {
            slot_addr(l, g, k);
        } else {
            sa;
        };
        let d = (t & ~0xFFFu64).wrapping_sub(pa & ~0xFFFu64) as i64 >> 12;
        if !fits(d, 21) {
            l.err.format_into("'{}': a page reference beyond 4 GiB", path);
            return false;
        }
        let imm = d as u32;
        lu::p32(img, p, insn & 0x9F00001F | (imm & 3) << 29 | (imm >> 2 & 0x7FFFF) << 5);
        return true;
    }
    if r.ty == A_ADD_ABS_LO12_NC || r.ty == A_LDST8_ABS_LO12_NC || r.ty == A_LDST16_ABS_LO12_NC || r.ty == A_LDST32_ABS_LO12_NC || r.ty == A_LDST64_ABS_LO12_NC || r.ty == A_LDST128_ABS_LO12_NC || r.ty == A_LD64_GOT_LO12_NC {
        let t = if r.ty == A_LD64_GOT_LO12_NC {
            slot_addr(l, g, k);
        } else {
            sa;
        };
        let sh: u32 = if r.ty == A_LDST16_ABS_LO12_NC {
            1;
        } else if r.ty == A_LDST32_ABS_LO12_NC {
            2;
        } else if r.ty == A_LDST64_ABS_LO12_NC || r.ty == A_LD64_GOT_LO12_NC {
            3;
        } else if r.ty == A_LDST128_ABS_LO12_NC {
            4;
        } else {
            0;
        };
        let lo = (t & 0xFFF) as u32;
        lu::p32(img, p, insn & 0xFFC003FF | lo >> sh << 10);
        return true;
    }
    // A thread-local descriptor sequence relaxed to local-exec: movz x0, #hi16, lsl #16; movk x0, #lo16;
    // nop; nop.
    // A shared library's: adrp x0, slot; ldr x0, [x0, :lo12:slot]; nop; nop (initial-exec).
    if r.ty == A_TLSDESC_ADR_PAGE21 && l.shared {
        let slot = tls_got_addr(l, k);
        let d = ((slot & ~0xFFFu64).wrapping_sub(pa & ~0xFFFu64) as i64 >> 12) as u32;
        lu::p32(img, p, 0x90000000 | (d & 3) << 29 | (d >> 2 & 0x7FFFF) << 5);
        return true;
    }
    if r.ty == A_TLSDESC_LD64_LO12 && l.shared {
        let slot = tls_got_addr(l, k);
        lu::p32(img, p, 0xF9400000 | ((slot & 0xFFF) >> 3) as u32 << 10);
        return true;
    }
    if r.ty == A_TLSDESC_ADR_PAGE21 {
        let t = tpoff(l, sv) as u64;
        if t >= 1u64 << 32 {
            l.err.format_into("'{}': thread-locals beyond 4 GiB", path);
            return false;
        }
        lu::p32(img, p, 0xD2A00000 | (t >> 16 & 0xFFFF) as u32 << 5);
        return true;
    }
    if r.ty == A_TLSDESC_LD64_LO12 {
        let t = tpoff(l, sv) as u64;
        lu::p32(img, p, 0xF2800000 | (t & 0xFFFF) as u32 << 5);
        return true;
    }
    if r.ty == A_TLSDESC_ADD_LO12 || r.ty == A_TLSDESC_CALL {
        lu::p32(img, p, 0xD503201F);
        return true;
    }
    // Initial-exec: the GOT slot of the offset in a shared library; in an executable the offset itself
    // (movz xN, #hi16, lsl #16; movk xN, #lo16), as LLD relaxes it.
    let rd = insn & 0x1F;
    if r.ty == A_TLSIE_ADR_GOTTPREL_PAGE21 && l.shared {
        let slot = tls_got_addr(l, k);
        let d = ((slot & ~0xFFFu64).wrapping_sub(pa & ~0xFFFu64) as i64 >> 12) as u32;
        lu::p32(img, p, 0x90000000 | rd | (d & 3) << 29 | (d >> 2 & 0x7FFFF) << 5);
        return true;
    }
    if r.ty == A_TLSIE_LD64_GOTTPREL_LO12_NC && l.shared {
        let slot = tls_got_addr(l, k);
        lu::p32(img, p, insn & 0xFFC003FF | ((slot & 0xFFF) >> 3) as u32 << 10);
        return true;
    }
    // Local-exec: the thread pointer offset itself.
    let tp = tpoff(l, sv).wrapping_add(r.addend) as u64;
    let le = r.ty >= A_TLSLE_MOVW_TPREL_G2 && r.ty <= A_TLSLE_LDST64_TPREL_LO12_NC || r.ty == A_TLSLE_LDST128_TPREL_LO12 || r.ty == A_TLSLE_LDST128_TPREL_LO12_NC;
    if (r.ty == A_TLSIE_ADR_GOTTPREL_PAGE21 || r.ty == A_TLSIE_LD64_GOTTPREL_LO12_NC || le) && l.shared {
        l.err.format_into("'{}': a local-exec thread-local access in a shared library", path);
        return false;
    }
    if r.ty == A_TLSIE_ADR_GOTTPREL_PAGE21 || r.ty == A_TLSIE_LD64_GOTTPREL_LO12_NC || r.ty == A_TLSLE_ADD_TPREL_HI12 {
        if tp >= 1u64 << 24 && r.ty == A_TLSLE_ADD_TPREL_HI12 || tp >= 1u64 << 32 {
            l.err.format_into("'{}': thread-locals beyond the reach of their access", path);
            return false;
        }
    }
    if r.ty == A_TLSIE_ADR_GOTTPREL_PAGE21 {
        lu::p32(img, p, 0xD2A00000 | rd | (tp >> 16 & 0xFFFF) as u32 << 5);
        return true;
    }
    if r.ty == A_TLSIE_LD64_GOTTPREL_LO12_NC {
        lu::p32(img, p, 0xF2800000 | rd | (tp & 0xFFFF) as u32 << 5);
        return true;
    }
    if r.ty >= A_TLSLE_MOVW_TPREL_G2 && r.ty <= A_TLSLE_MOVW_TPREL_G0_NC {
        // G2, G1, G1_NC, G0, G0_NC: the 16 bits at 32, 16, 16, 0, 0.
        let sh: u64 = if r.ty == A_TLSLE_MOVW_TPREL_G2 {
            32;
        } else if r.ty < A_TLSLE_MOVW_TPREL_G0_NC - 1 {
            16;
        } else {
            0;
        };
        lu::p32(img, p, insn & 0xFFE0001F | (tp >> sh & 0xFFFF) as u32 << 5);
        return true;
    }
    if r.ty == A_TLSLE_ADD_TPREL_HI12 {
        lu::p32(img, p, insn & 0xFFC003FF | (tp >> 12 & 0xFFF) as u32 << 10);
        return true;
    }
    if r.ty == A_TLSLE_ADD_TPREL_LO12 || r.ty == A_TLSLE_ADD_TPREL_LO12_NC {
        lu::p32(img, p, insn & 0xFFC003FF | (tp & 0xFFF) as u32 << 10);
        return true;
    }
    if le {
        // LDST8, 16, 32, 64 (each with its NC form), then LDST128: the low 12 bits scaled by the access.
        let sh: u32 = if r.ty >= A_TLSLE_LDST128_TPREL_LO12 {
            4;
        } else {
            (r.ty - A_TLSLE_LDST8_TPREL_LO12) / 2;
        };
        lu::p32(img, p, insn & 0xFFC003FF | (tp & 0xFFF) as u32 >> sh << 10);
        return true;
    }
    l.err.format_into("'{}': arm64 relocation type {} is not supported", path, r.ty);
    return false;
}

fn dyn_rel(l: &mut L, at: u64, ty: u32, sym: u32, addend: i64) {
    l.drels.push(DRel { at: at, ty: ty, sym: sym, addend: addend });
}

// Apply the relocations of the debug sections: addresses at their link-time values, offsets into other
// debug sections at the merged section's.
const fn apply_debug(l: &L, b: []u8, img: &mut Vector<u8>, dbg_off: &Vector<u64>) {
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if sc.rela == NONE || sc.out == NONE || seg_of(l.osecs[sc.out as usize].rank) != 4 {
            continue;
        }
        let rs = l.secs[sc.rela as usize];
        let f = l.files[sc.file as usize];
        let n = (rs.size / 24) as usize;
        for i in 0..n {
            let r = rel_at(b, rs, i);
            let k = f.sym0 + r.sym;
            let y = l.syms[k as usize];
            let p = (dbg_off[sc.out as usize] + sc.at + r.off) as usize;
            let mut v = target(l, k).wrapping_add(r.addend as u64);
            // A section symbol of a debug section: the offset within the merged section.
            if type_of(y) == STT_SECTION {
                let ts = l.secs[(f.sec0 + y.shndx) as usize];
                if ts.out != NONE && seg_of(l.osecs[ts.out as usize].rank) == 4 {
                    v = ts.at.wrapping_add(r.addend as u64);
                }
            }
            if r.ty == X_64 && !l.a64 || r.ty == A_ABS64 && l.a64 {
                lu::p64(img, p, v);
            } else {
                lu::p32(img, p, v as u32);
            }
        }
    }
}

// ---- the entry ------------------------------------------------------------------------------------------

const fn start_size(a64: bool) u64 {
    if a64 {
        return 56;
    }
    return 48;
}

// `_start`: the stack's argc and argv, the dynamic linker's finalizer, then
// `__libc_start_main(main, argc, argv, 0, 0, rtld_fini, stack_end)`, which does not return.
const fn write_start(l: &mut L, main: u32, lsm: u32, img: &mut Vector<u8>) {
    let os = l.osecs[l.o[O_TEXT] as usize];
    let a = os.addr;
    let p = os.off as usize;
    l.start_at = a;
    let ma = g_addr(l, main);
    let slot = got_addr(l, lsm);
    if l.a64 {
        let code: [u32; 14] = [
            0xD280001D, // mov x29, #0
            0xD280001E, // mov x30, #0
            0xAA0003E5, // mov x5, x0
            0xF94003E1, // ldr x1, [sp]
            0x910023E2, // add x2, sp, #8
            0x910003E6, // mov x6, sp
            0x90000000, // adrp x0, main
            0x91000000, // add x0, x0, :lo12:main
            0xD2800003, // mov x3, #0
            0xD2800004, // mov x4, #0
            0x90000010, // adrp x16, slot
            0xF9400210, // ldr x16, [x16, :lo12:slot]
            0xD63F0200, // blr x16
            0xD4200000, // brk #0
        ];
        for i in 0..14usize {
            lu::p32(img, p + 4 * i, unsafe code[i]);
        }
        let pm = ((ma & ~0xFFFu64).wrapping_sub(a + 24 & ~0xFFFu64) as i64 >> 12) as u32;
        lu::p32(img, p + 24, 0x90000000 | (pm & 3) << 29 | (pm >> 2 & 0x7FFFF) << 5);
        lu::p32(img, p + 28, 0x91000000 | (ma & 0xFFF) as u32 << 10);
        let ps = ((slot & ~0xFFFu64).wrapping_sub(a + 40 & ~0xFFFu64) as i64 >> 12) as u32;
        lu::p32(img, p + 40, 0x90000010 | (ps & 3) << 29 | (ps >> 2 & 0x7FFFF) << 5);
        lu::p32(img, p + 44, 0xF9400210 | ((slot & 0xFFF) >> 3) as u32 << 10);
        return;
    }
    let code: [u8; 32] = [
        0x31,
        0xED, // xor %ebp, %ebp
        0x49,
        0x89,
        0xD1, // mov %rdx, %r9
        0x5E, // pop %rsi
        0x48,
        0x89,
        0xE2, // mov %rsp, %rdx
        0x48,
        0x83,
        0xE4,
        0xF0, // and $-16, %rsp
        0x50, // push %rax
        0x54, // push %rsp
        0x45,
        0x31,
        0xC0, // xor %r8d, %r8d
        0x31,
        0xC9, // xor %ecx, %ecx
        0x48,
        0x8D,
        0x3D,
        0,
        0,
        0,
        0, // lea main(%rip), %rdi
        0xFF,
        0x15,
        0,
        0,
        0, // call *slot(%rip) (the last byte is the next row's)
    ];
    for i in 0..32usize {
        img[p + i] = unsafe code[i];
    }
    img[p + 32] = 0;
    img[p + 33] = 0xF4; // hlt
    lu::p32(img, p + 23, ma.wrapping_sub(a + 27) as u32);
    lu::p32(img, p + 29, slot.wrapping_sub(a + 33) as u32);
}

// ---- synthetic sections ---------------------------------------------------------------------------------

fn write_synthetic(l: &mut L, b: []u8, img: &mut Vector<u8>) {
    // The stubs: jmp *slot(%rip); arm64: adrp x16, slot; ldr x17, [x16, :lo12:slot]; br x17.
    if l.plt.len() != 0 {
        let os = l.osecs[l.o[O_PLT] as usize];
        for i in 0..l.plt.len() {
            let a = os.addr + 16 * i as u64;
            let p = (os.off + 16 * i as u64) as usize;
            let slot = got_addr(l, l.plt[i]);
            if l.a64 {
                let d = ((slot & ~0xFFFu64).wrapping_sub(a & ~0xFFFu64) as i64 >> 12) as u32;
                lu::p32(img, p, 0x90000010 | (d & 3) << 29 | (d >> 2 & 0x7FFFF) << 5);
                lu::p32(img, p + 4, 0xF9400211 | ((slot & 0xFFF) >> 3) as u32 << 10);
                lu::p32(img, p + 8, 0xD61F0220);
                lu::p32(img, p + 12, 0xD503201F);
            } else {
                img[p] = 0xFF;
                img[p + 1] = 0x25;
                lu::p32(img, p + 2, slot.wrapping_sub(a + 6) as u32);
                for j in 6..16usize {
                    img[p + j] = 0xCC;
                }
            }
        }
    }
    // The GOT: a local target's address (a relative relocation), an import's binding.
    let gos = l.osecs[l.o[O_GOT] as usize];
    for i in 0..l.got.len() {
        let g = l.got[i];
        let a = gos.addr + 8 * i as u64;
        if l.gs[g as usize].kind == G_SHARED {
            let ty = if l.a64 {
                A_GLOB_DAT;
            } else {
                X_GLOB_DAT;
            };
            dyn_rel(l, a, ty, l.gs[g as usize].dynix, 0);
        } else {
            let ty = if l.a64 {
                A_RELATIVE;
            } else {
                X_RELATIVE;
            };
            dyn_rel(l, a, ty, 0, g_addr(l, g) as i64);
        }
    }
    // The local symbols' slots: their addresses.
    for i in 0..l.lgot.len() {
        let a = gos.addr + 8 * (l.got.len() + i) as u64;
        let ty = if l.a64 {
            A_RELATIVE;
        } else {
            X_RELATIVE;
        };
        dyn_rel(l, a, ty, 0, sym_addr(l, l.lgot[i]) as i64);
    }
    // A shared library's thread-local slots: the offset from the thread pointer the dynamic linker places
    // the library's block at, plus the variable's offset in it.
    for i in 0..l.tls_keys.len() {
        let key = l.tls_keys[i];
        let a = gos.addr + 8 * (l.got.len() + l.lgot.len() + i) as u64;
        let va = if key >> 63 != 0 {
            g_addr(l, (key & 0xFFFFFFFF) as u32);
        } else {
            sym_addr(l, key as u32);
        };
        let ty = if l.a64 {
            A_TLS_TPREL64;
        } else {
            X_TPOFF64;
        };
        dyn_rel(l, a, ty, 0, (va - l.tls_start) as i64);
    }
    if l.o[O_EH] != NONE {
        write_eh_hdr(l, b, img);
    }
}

// `.eh_frame_hdr`: the frames' address, their count and the table of (start, entry) sorted by start,
// both relative to the header.
fn write_eh_hdr(l: &L, b: []u8, img: &mut Vector<u8>) {
    let _ = b;
    let eh = l.osecs[l.o[O_EH] as usize];
    let hh = l.osecs[l.o[O_EHHDR] as usize];
    let mut ent = Vector::<u64>::with_capacity(l.nfde as usize);
    let mut fdes = Vector::<u64>::with_capacity(l.nfde as usize);
    // Walk the merged frames as relocated: each CIE's pointer encoding, each FDE's start.
    let base = eh.off as usize;
    let end = base + eh.size as usize - 4;
    let mut p = base;
    let mut enc: u8 = 0x1B;
    let mut cie_enc = Map::<u64, u8>::new();
    while p + 8 <= end {
        let len = lu::r32(img.as_slice(), p) as usize;
        if len == 0 {
            break;
        }
        let id = lu::r32(img.as_slice(), p + 4);
        if id == 0 {
            enc = cie_fde_enc(img.as_slice(), p);
            let _ = cie_enc.insert((p - base) as u64, enc);
        } else {
            let cie = p + 4 - id as usize;
            let ce = cie_enc.get(&((cie - base) as u64));
            let e = if ce.is_some() {
                *ce.unwrap();
            } else {
                enc;
            };
            let field = p + 8;
            let fa = eh.addr + (field - base) as u64;
            let v = lu::r32(img.as_slice(), field);
            let start = if (e & 0x70) == 0x10 {
                fa.wrapping_add(((v as i32) as i64) as u64);
            } else {
                v as u64;
            };
            ent.push(start);
            fdes.push(eh.addr + (p - base) as u64);
        }
        p += 4 + len;
    }
    let mut keyed = Vector::<u64>::with_capacity(ent.len());
    for i in 0..ent.len() {
        keyed.push(ent[i] - hh.addr << 24 | i as u64);
    }
    keyed.sort();
    let h = hh.off as usize;
    img[h] = 1;
    img[h + 1] = 0x1B;
    img[h + 2] = 0x03;
    img[h + 3] = 0x3B;
    lu::p32(img, h + 4, eh.addr.wrapping_sub(hh.addr + 4) as u32);
    lu::p32(img, h + 8, keyed.len() as u32);
    for i in 0..keyed.len() {
        let j = (keyed[i] & 0xFFFFFF) as usize;
        lu::p32(img, h + 12 + 8 * i, (ent[j] - hh.addr) as u32);
        lu::p32(img, h + 16 + 8 * i, (fdes[j] - hh.addr) as u32);
    }
}

// The FDE pointer encoding of the CIE at `p` ('R' in its augmentation; absolute otherwise).
const fn cie_fde_enc(b: []u8, p: usize) u8 {
    let mut q = p + 9;
    let aug = q;
    while b[q] != 0 {
        q += 1;
    }
    let augs = unsafe str::from_raw(b.as_ptr() + aug, q - aug);
    q += 1;
    let _ = lu::read_uleb(b, &mut q);
    let _ = lu::read_uleb(b, &mut q);
    let _ = lu::read_uleb(b, &mut q);
    if !augs.starts_with("z") {
        return 0;
    }
    let _ = lu::read_uleb(b, &mut q);
    for i in 1..augs.len() {
        let c = augs.byte_at(i);
        if c == b'R' {
            return b[q];
        }
        if c == b'P' {
            let pe = b[q];
            q += 1 + ptr_size(pe);
        } else if c == b'L' {
            q += 1;
        }
    }
    return 0;
}

const fn ptr_size(e: u8) usize {
    let f = e & 0x0F;
    if f == 0x02 || f == 0x0A {
        return 2;
    }
    if f == 0x03 || f == 0x0B {
        return 4;
    }
    return 8;
}

// ---- the dynamic tables, the headers, the symbol table --------------------------------------------------

// The SysV ELF hash of `s`.
const fn elf_hash(s: str) u32 {
    let mut h: u32 = 0;
    for i in 0..s.len() {
        h = (h << 4) + s.byte_at(i) as u32;
        let g = h & 0xF0000000;
        if g != 0 {
            h ^= g >> 24;
        }
        h &= ~g;
    }
    return h;
}

fn finish(l: &mut L, o: &Opts, b: []u8, img: &mut Vector<u8>) {
    if !l.shared {
        let ip = interp(l);
        let oi = l.osecs[l.o[O_INTERP] as usize];
        for i in 0..ip.len() {
            img[oi.off as usize + i] = ip.byte_at(i);
        }
    }
    // .dynstr and .dynsym.
    let mut ds = Vector::<u8>::new();
    ds.push(0);
    let soname = if l.shared {
        lu::put_str(&mut ds, o.soname.as_str());
    } else {
        0u32;
    };
    let mut sym_name = Vector::<u32>::new();
    for i in 0..l.dyns.len() {
        sym_name.push(lu::put_str(&mut ds, l.names.spell(l.gs[l.dyns[i] as usize].name)));
    }
    let mut lib_name = Vector::<u32>::new();
    for i in 0..l.libs.len() {
        lib_name.push(
            if l.libs[i].used {
                lu::put_str(&mut ds, l.libs[i].soname.as_str());
            } else {
                0u32;
            },
        );
    }
    let mut ver_name = Vector::<u32>::new();
    for v in 0..l.vers.len() {
        ver_name.push(
            if l.vers[v].index != 0 {
                lu::put_str(&mut ds, l.vers[v].name.as_str());
            } else {
                0u32;
            },
        );
    }
    let odstr = l.osecs[l.o[O_DYNSTR] as usize];
    for i in 0..ds.len() {
        img[odstr.off as usize + i] = ds[i];
    }
    let odsym = l.osecs[l.o[O_DYNSYM] as usize];
    let ovs = l.osecs[l.o[O_VERSYM] as usize];
    for i in 0..l.dyns.len() {
        let g = l.dyns[i];
        let gy = l.gs[g as usize];
        let e = odsym.off as usize + 24 * (i + 1);
        lu::p32(img, e, sym_name[i]);
        if gy.kind == G_DEF || gy.kind == G_COMMON {
            // An export: its address and size in its output section.
            let (info, shndx, size) = if gy.kind == G_COMMON {
                (STB_GLOBAL << 4 | STT_OBJECT, l.o[O_BSS] + 1, gy.size);
            } else {
                let y = l.syms[gy.sym as usize];
                let f = l.files[y.file as usize];
                (y.info, l.secs[(f.sec0 + y.shndx) as usize].out + 1, y.size);
            };
            img[e + 4] = info;
            lu::p16(img, e + 6, shndx);
            lu::p64(img, e + 8, g_addr(l, g));
            lu::p64(img, e + 16, size);
            lu::p16(img, ovs.off as usize + 2 * (i + 1), 1);
            continue;
        }
        // An import; one no library defines binds weakly (a shared library's).
        img[e + 4] = if gy.lib == NONE {
            STB_WEAK;
        } else {
            STB_GLOBAL;
        } << 4 | if gy.func {
            STT_FUNC;
        } else {
            STT_OBJECT;
        };
        lu::p16(
            img,
            ovs.off as usize + 2 * (i + 1),
            if gy.ver != NONE {
                l.vers[gy.ver as usize].index;
            } else {
                1u32;
            },
        );
    }
    // .hash
    let nsym = l.dyns.len() as u64 + 1;
    let nb = nbucket(nsym);
    let oh = l.osecs[l.o[O_HASH] as usize];
    let h = oh.off as usize;
    lu::p32(img, h, nb as u32);
    lu::p32(img, h + 4, nsym as u32);
    for i in 0..l.dyns.len() {
        let si = (i + 1) as u32;
        let bk = (elf_hash(l.names.spell(l.gs[l.dyns[i] as usize].name)) as u64 % nb) as usize;
        // Prepend to the bucket's chain.
        let head = lu::r32(img.as_slice(), h + 8 + 4 * bk);
        lu::p32(img, h + 8 + 4 * nb as usize + 4 * si as usize, head);
        lu::p32(img, h + 8 + 4 * bk, si);
    }
    // .gnu.version_r: per library with needed versions, its Verneed then the Vernaux records.
    let ovn = l.osecs[l.o[O_VERNEED] as usize];
    let mut q = ovn.off as usize;
    let mut nvlib: u32 = 0;
    let mut last_vn: usize = 0;
    for i in 0..l.libs.len() {
        let mut cnt: u32 = 0;
        for v in 0..l.vers.len() {
            if l.vers[v].lib == i as u32 && l.vers[v].index != 0 {
                cnt += 1;
            }
        }
        if cnt == 0 {
            continue;
        }
        if nvlib != 0 {
            lu::p32(img, last_vn + 12, (q - last_vn) as u32);
        }
        nvlib += 1;
        last_vn = q;
        lu::p16(img, q, 1);
        lu::p16(img, q + 2, cnt);
        lu::p32(img, q + 4, lib_name[i]);
        lu::p32(img, q + 8, 16);
        lu::p32(img, q + 12, 0);
        q += 16;
        let mut k: u32 = 0;
        for v in 0..l.vers.len() {
            if l.vers[v].lib != i as u32 || l.vers[v].index == 0 {
                continue;
            }
            k += 1;
            lu::p32(img, q, elf_hash(l.vers[v].name.as_str()));
            lu::p16(img, q + 4, 0);
            lu::p16(img, q + 6, l.vers[v].index);
            lu::p32(img, q + 8, ver_name[v]);
            lu::p32(
                img,
                q + 12,
                if k < cnt {
                    16u32;
                } else {
                    0u32;
                },
            );
            q += 16;
        }
    }
    // .rela.dyn: the relative relocations first (DT_RELACOUNT), each group by address.
    let mut keyed = Vector::<u64>::with_capacity(l.drels.len());
    let mut nrel: u64 = 0;
    for i in 0..l.drels.len() {
        let dr = l.drels[i];
        if dr.ty == 0 {
            continue;
        }
        let rel = dr.ty == X_RELATIVE && !l.a64 || dr.ty == A_RELATIVE && l.a64;
        if rel {
            nrel += 1;
        }
        keyed.push((!rel) as u64 << 63 | dr.at << 20 | i as u64);
    }
    keyed.sort();
    let ora = l.osecs[l.o[O_RELA] as usize];
    let mut nwritten: usize = 0;
    for i in 0..keyed.len() {
        let dr = l.drels[(keyed[i] & 0xFFFFF) as usize];
        let e = ora.off as usize + 24 * i;
        lu::p64(img, e, dr.at);
        lu::p64(img, e + 8, dr.sym as u64 << 32 | dr.ty as u64);
        lu::p64(img, e + 16, dr.addend as u64);
        nwritten += 1;
    }
    let rela_size = 24 * nwritten as u64;
    // .dynamic
    let od = l.osecs[l.o[O_DYNAMIC] as usize];
    let mut dv = Vector::<u64>::new();
    for i in 0..l.libs.len() {
        if l.libs[i].used {
            dv.push(DT_NEEDED);
            dv.push(lib_name[i]);
        }
    }
    let pairs: [u64; 22] = [
        DT_HASH,
        oh.addr,
        DT_STRTAB,
        odstr.addr,
        DT_SYMTAB,
        odsym.addr,
        DT_STRSZ,
        ds.len() as u64,
        DT_SYMENT,
        24,
        DT_RELA,
        ora.addr,
        DT_RELASZ,
        rela_size,
        DT_RELAENT,
        24,
        DT_RELACOUNT,
        nrel,
        DT_VERSYM,
        ovs.addr,
        if l.shared {
            DT_SONAME;
        } else {
            DT_DEBUG;
        },
        soname,
    ];
    let ps: []u64 = pairs;
    for i in 0..ps.len() {
        dv.push(ps[i]);
    }
    if nvlib != 0 {
        dv.push(DT_VERNEED);
        dv.push(ovn.addr);
        dv.push(DT_VERNEEDNUM);
        dv.push(nvlib);
    }
    for i in 0..l.osecs.len() {
        let os = l.osecs[i];
        let nm = l.sn.spell(os.name);
        if nm == ".init_array" {
            dv.push(DT_INIT_ARRAY);
            dv.push(os.addr);
            dv.push(DT_INIT_ARRAYSZ);
            dv.push(os.size);
        } else if nm == ".fini_array" {
            dv.push(DT_FINI_ARRAY);
            dv.push(os.addr);
            dv.push(DT_FINI_ARRAYSZ);
            dv.push(os.size);
        } else if nm == ".preinit_array" {
            dv.push(DT_PREINIT_ARRAY);
            dv.push(os.addr);
            dv.push(DT_PREINIT_ARRAYSZ);
            dv.push(os.size);
        }
    }
    dv.push(DT_FLAGS);
    dv.push(
        DF_BIND_NOW | if l.tls_keys.len() != 0 {
            DF_STATIC_TLS;
        } else {
            0u64;
        },
    );
    dv.push(DT_FLAGS_1);
    dv.push(
        DF_1_NOW | if l.shared {
            0u64;
        } else {
            DF_1_PIE;
        },
    );
    dv.push(DT_NULL);
    dv.push(0);
    assert(8 * dv.len() as u64 <= od.size, "elf: the dynamic section's size");
    for i in 0..dv.len() {
        lu::p64(img, od.off as usize + 8 * i, dv[i]);
    }
    let _ = b;
    // The sections the image does not load: debug information, then the symbol and string tables.
    let mut shstr = Vector::<u8>::new();
    shstr.push(0);
    let mut sh_name = Vector::<u32>::new();
    for i in 0..l.osecs.len() {
        sh_name.push(lu::put_str(&mut shstr, l.sn.spell(l.osecs[i].name)));
    }
    let mut dbg_off = Vector::<u64>::new();
    dbg_off.resize_default(l.osecs.len());
    if !o.strip {
        for i in 0..l.osecs.len() {
            let os = l.osecs[i];
            if seg_of(os.rank) != 4 {
                continue;
            }
            while img.len() % os.align as usize != 0 {
                img.push(0);
            }
            dbg_off[i] = img.len() as u64;
            l.osecs.index_mut(i).off = img.len() as u64;
            let n0 = img.len();
            img.resize_default(n0 + os.size as usize);
        }
        for s in 0..l.secs.len() {
            let sc = l.secs[s];
            if sc.out == NONE || seg_of(l.osecs[sc.out as usize].rank) != 4 {
                continue;
            }
            let at = (dbg_off[sc.out as usize] + sc.at) as usize;
            for i in 0..sc.size as usize {
                img[at + i] = b[sc.off + i];
            }
        }
        apply_debug(l, b, img, &dbg_off);
    }
    // .symtab: the locals (the files', then `_start`), then the globals.
    let mut st = Vector::<u8>::new();
    st.push(0);
    let mut syms = Vector::<u8>::new();
    for _ in 0..24 {
        syms.push(0);
    }
    let mut nloc: u32 = 1;
    if !o.strip {
        for k in 0..l.syms.len() {
            let y = l.syms[k];
            if bind_of(y) != STB_LOCAL || type_of(y) == STT_SECTION || type_of(y) == STT_FILE || y.shndx == SHN_UNDEF || y.shndx >= 0xFF00 {
                continue;
            }
            let f = l.files[y.file as usize];
            let s = l.secs[(f.sec0 + y.shndx) as usize];
            if s.out == NONE || seg_of(l.osecs[s.out as usize].rank) == 4 || l.names.spell(y.name).len() == 0 {
                continue;
            }
            put_sym(
                &mut syms,
                lu::put_str(&mut st, l.names.spell(y.name)),
                y.info,
                s.out + 1,
                sym_addr(l, k as u32),
                y.size,
            );
            nloc += 1;
        }
        if !l.shared {
            let ts = l.o[O_TEXT] + 1;
            put_sym(
                &mut syms,
                lu::put_str(&mut st, "_start"),
                STB_LOCAL << 4 | STT_FUNC,
                ts,
                l.start_at,
                start_size(l.a64),
            );
            nloc += 1;
        }
        for g in 0..l.gs.len() {
            let gy = l.gs[g];
            if gy.kind == G_DEF {
                let y = l.syms[gy.sym as usize];
                let f = l.files[y.file as usize];
                let sh = if y.shndx == SHN_ABS {
                    SHN_ABS;
                } else {
                    l.secs[(f.sec0 + y.shndx) as usize].out + 1;
                };
                put_sym(
                    &mut syms,
                    lu::put_str(&mut st, l.names.spell(gy.name)),
                    y.info,
                    sh,
                    g_addr(l, g as u32),
                    y.size,
                );
            } else if gy.kind == G_SHARED && gy.used {
                put_sym(
                    &mut syms,
                    lu::put_str(&mut st, l.names.spell(gy.name)),
                    STB_GLOBAL << 4 | if gy.func {
                        STT_FUNC;
                    } else {
                        STT_NOTYPE;
                    },
                    0,
                    0,
                    0,
                );
            }
        }
    }
    let shstrtab_name = lu::put_str(&mut shstr, ".shstrtab");
    let symtab_name = lu::put_str(&mut shstr, ".symtab");
    let strtab_name = lu::put_str(&mut shstr, ".strtab");
    while img.len() % 8 != 0 {
        img.push(0);
    }
    let symtab_off = img.len() as u64;
    img.extend_from_slice(syms.as_slice());
    let strtab_off = img.len() as u64;
    img.extend_from_slice(st.as_slice());
    let shstr_off = img.len() as u64;
    img.extend_from_slice(shstr.as_slice());
    while img.len() % 8 != 0 {
        img.push(0);
    }
    // The section headers: null, the output sections, .symtab, .strtab, .shstrtab.
    let shoff = img.len() as u64;
    let nsh = l.osecs.len() + 4;
    for _ in 0..64 {
        img.push(0);
    }
    let dynstr_ix = l.o[O_DYNSTR] + 1;
    let dynsym_ix = l.o[O_DYNSYM] + 1;
    for i in 0..l.osecs.len() {
        let os = l.osecs[i];
        let loaded = seg_of(os.rank) != 4;
        if !loaded && o.strip {
            put_shdr(img, sh_name[i], SHT_PROGBITS, 0, 0, 0, 0, 0, 0, 1, 0);
            continue;
        }
        let (link, info) = if i as u32 == l.o[O_DYNSYM] {
            (dynstr_ix, 1u32);
        } else if i as u32 == l.o[O_HASH] || i as u32 == l.o[O_VERSYM] || i as u32 == l.o[O_RELA] {
            (dynsym_ix, 0u32);
        } else if i as u32 == l.o[O_VERNEED] {
            (dynstr_ix, nvlib);
        } else if i as u32 == l.o[O_DYNAMIC] {
            (dynstr_ix, 0u32);
        } else {
            (0u32, 0u32);
        };
        let size = if i as u32 == l.o[O_RELA] {
            rela_size;
        } else {
            os.size;
        };
        put_shdr(
            img,
            sh_name[i],
            os.ty,
            os.flags,
            if loaded {
                os.addr;
            } else {
                0u64;
            },
            os.off,
            size,
            link,
            info,
            os.align,
            os.entsize,
        );
    }
    put_shdr(img, symtab_name, SHT_SYMTAB, 0, 0, symtab_off, syms.len() as u64, nsh as u32 - 2, nloc, 8, 24);
    put_shdr(img, strtab_name, SHT_STRTAB, 0, 0, strtab_off, st.len() as u64, 0, 0, 1, 0);
    put_shdr(img, shstrtab_name, SHT_STRTAB, 0, 0, shstr_off, shstr.len() as u64, 0, 0, 1, 0);
    write_headers(l, img, shoff, nsh as u32);
}

fn put_sym(o: &mut Vector<u8>, name: u32, info: u8, shndx: u32, value: u64, size: u64) {
    lu::w32(o, name);
    o.push(info);
    o.push(STV_DEFAULT);
    lu::w16(o, shndx);
    lu::w64(o, value);
    lu::w64(o, size);
}

fn put_shdr(
    o: &mut Vector<u8>,
    name: u32,
    ty: u32,
    flags: u64,
    addr: u64,
    off: u64,
    size: u64,
    link: u32,
    info: u32,
    align: u64,
    entsize: u64,
) {
    lu::w32(o, name);
    lu::w32(o, ty);
    lu::w64(o, flags);
    lu::w64(o, addr);
    lu::w64(o, off);
    lu::w64(o, size);
    lu::w32(o, link);
    lu::w32(o, info);
    lu::w64(o, align);
    lu::w64(o, entsize);
}

// The ELF header and the program headers.
fn write_headers(l: &L, img: &mut Vector<u8>, shoff: u64, nsh: u32) {
    let mut h = Vector::<u8>::new();
    lu::w64(&mut h, 0x00010102464C457F);
    lu::w64(&mut h, 0);
    lu::w16(&mut h, 3); // ET_DYN: position-independent
    lu::w16(
        &mut h,
        if l.a64 {
            183u32;
        } else {
            62u32;
        },
    );
    lu::w32(&mut h, 1);
    lu::w64(&mut h, l.start_at);
    lu::w64(&mut h, 64);
    lu::w64(&mut h, shoff);
    lu::w32(&mut h, 0);
    lu::w16(&mut h, 64);
    lu::w16(&mut h, 56);
    lu::w16(&mut h, l.nph);
    lu::w16(&mut h, 64);
    lu::w16(&mut h, nsh);
    lu::w16(&mut h, nsh - 1);
    let nph = l.nph as u64;
    phdr(&mut h, PT_PHDR, 4, 64, 64, 56 * nph, 56 * nph, 8);
    if !l.shared {
        let oi = l.osecs[l.o[O_INTERP] as usize];
        phdr(&mut h, PT_INTERP, 4, oi.off, oi.addr, oi.size, oi.size, 1);
    }
    // The four loadable segments: each one's first section to its last.
    for seg in 0..4u32 {
        let mut lo: u64 = 0;
        let mut flo: u64 = 0;
        let mut hi: u64 = 0;
        let mut fhi: u64 = 0;
        let mut any = false;
        for i in 0..l.osecs.len() {
            let os = l.osecs[i];
            if seg_of(os.rank) != seg {
                continue;
            }
            if !any {
                lo = os.addr;
                flo = os.off;
                any = true;
            }
            if (os.flags & SHF_TLS) == 0 || os.ty != SHT_NOBITS {
                hi = hi.max(os.addr + os.size);
            }
            if os.ty != SHT_NOBITS {
                fhi = fhi.max(os.off + os.size);
            }
        }
        if seg == 0 {
            lo = 0;
            flo = 0;
        }
        let flags: u32 = if seg == 0 {
            4;
        } else if seg == 1 {
            5;
        } else {
            6;
        };
        if !any && seg != 0 {
            continue;
        }
        phdr(&mut h, PT_LOAD, flags, flo, lo, fhi.max(flo) - flo, hi - lo, l.page);
    }
    let od = l.osecs[l.o[O_DYNAMIC] as usize];
    phdr(&mut h, PT_DYNAMIC, 6, od.off, od.addr, od.size, od.size, 8);
    let mut tls_file: u64 = 0;
    // The template's file offset: its first section's (an empty one's is congruent to its address too).
    let mut tls_off: u64 = 0;
    let mut first = true;
    for i in 0..l.osecs.len() {
        let os = l.osecs[i];
        if (os.flags & SHF_TLS) != 0 && first {
            tls_off = os.off;
            first = false;
        }
        if (os.flags & SHF_TLS) != 0 && os.ty != SHT_NOBITS {
            tls_file = os.addr + os.size - l.tls_start;
        }
    }
    if has_tls(l) {
        phdr(&mut h, PT_TLS, 4, tls_off, l.tls_start, tls_file, l.tls_size, l.tls_align);
    }
    if l.o[O_EHHDR] != NONE {
        let hh = l.osecs[l.o[O_EHHDR] as usize];
        phdr(&mut h, PT_GNU_EH_FRAME, 4, hh.off, hh.addr, hh.size, hh.size, 4);
    }
    phdr(&mut h, PT_GNU_STACK, 6, 0, 0, 0, 0, 16);
    // The relro range: the third segment.
    let mut rlo: u64 = 0;
    let mut rhi: u64 = 0;
    let mut rfo: u64 = 0;
    for i in 0..l.osecs.len() {
        let os = l.osecs[i];
        if seg_of(os.rank) == 2 {
            if rlo == 0 {
                rlo = os.addr;
                rfo = os.off;
            }
            rhi = rhi.max(os.addr + os.size);
        }
    }
    phdr(&mut h, PT_GNU_RELRO, 4, rfo, rlo, rhi - rlo, rhi - rlo, 1);
    assert(h.len() as u64 == 64 + 56 * nph, "elf: the program headers' size");
    for i in 0..h.len() {
        img[i] = h[i];
    }
}

fn phdr(h: &mut Vector<u8>, ty: u32, flags: u32, off: u64, addr: u64, filesz: u64, memsz: u64, align: u64) {
    lu::w32(h, ty);
    lu::w32(h, flags);
    lu::w64(h, off);
    lu::w64(h, addr);
    lu::w64(h, addr);
    lu::w64(h, filesz);
    lu::w64(h, memsz);
    lu::w64(h, align);
}
