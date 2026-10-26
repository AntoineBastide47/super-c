// The Mach-O arm64 linker: objects plus the SDK's libraries (`.tbd` stubs or Mach-O dylibs) into a
// position-independent executable or a dylib for macOS 12 or later. Imports bind through chained fixups
// (`DYLD_CHAINED_PTR_64_OFFSET`, no lazy binding): a call to an imported function goes through a stub
// that loads its `__got` slot. The image carries `__unwind_info` from the objects' compact unwind
// entries, the symbol table with a debug map for each object with DWARF (as `dsymutil` and lldb read
// it), the exports trie, the function starts and an ad-hoc linker signature, which arm64 macOS needs to
// run the code. Output is a function of the inputs alone: no timestamps.
import link::util as lu;
import link::tbd;
import link::sha256 as sha;
import utils::names as nm;
import std::platform::fs;
import std::parallel::data as parallel;

const NONE: u32 = 0xFFFFFFFF;
const PAGE: u64 = 0x4000;
const EXE_BASE: u64 = 0x100000000;

const MH_MAGIC_64: u32 = 0xFEEDFACF;
const FAT_MAGIC: u32 = 0xBEBAFECA; // 0xCAFEBABE as read little-endian
const CPU_ARM64: u32 = 0x0100000C;
const MH_OBJECT: u32 = 1;
const MH_EXECUTE: u32 = 2;
const MH_DYLIB: u32 = 6;

const LC_SEGMENT_64: u32 = 0x19;
const LC_SYMTAB: u32 = 0x2;
const LC_DYSYMTAB: u32 = 0xB;
const LC_LOAD_DYLIB: u32 = 0xC;
const LC_ID_DYLIB: u32 = 0xD;
const LC_LOAD_DYLINKER: u32 = 0xE;
const LC_UUID: u32 = 0x1B;
const LC_CODE_SIGNATURE: u32 = 0x1D;
const LC_REEXPORT_DYLIB: u32 = 0x8000001F;
const LC_DYLD_INFO_ONLY: u32 = 0x80000022;
const LC_FUNCTION_STARTS: u32 = 0x26;
const LC_MAIN: u32 = 0x80000028;
const LC_BUILD_VERSION: u32 = 0x32;
const LC_DYLD_EXPORTS_TRIE: u32 = 0x80000033;
const LC_DYLD_CHAINED_FIXUPS: u32 = 0x80000034;

const MH_NOUNDEFS: u32 = 0x1;
const MH_DYLDLINK: u32 = 0x4;
const MH_TWOLEVEL: u32 = 0x80;
const MH_PIE: u32 = 0x200000;
const MH_HAS_TLV_DESCRIPTORS: u32 = 0x800000;
const MH_NO_REEXPORTED_DYLIBS: u32 = 0x100000;

const S_TYPE: u32 = 0xFF;
const S_REGULAR: u32 = 0;
const S_ZEROFILL: u32 = 1;
const S_NON_LAZY_SYMBOL_POINTERS: u32 = 6;
const S_SYMBOL_STUBS: u32 = 8;
const S_MOD_INIT_FUNC_POINTERS: u32 = 9;
const S_GB_ZEROFILL: u32 = 0xC;
const S_THREAD_LOCAL_REGULAR: u32 = 0x11;
const S_THREAD_LOCAL_ZEROFILL: u32 = 0x12;
const S_THREAD_LOCAL_VARIABLES: u32 = 0x13;
const S_ATTR_DEBUG: u32 = 0x02000000;
const S_ATTR_PURE_INSTRUCTIONS: u32 = 0x80000000;
const S_ATTR_SOME_INSTRUCTIONS: u32 = 0x400;
const SG_READ_ONLY: u32 = 0x10;

const N_STAB: u8 = 0xE0;
const N_PEXT: u8 = 0x10;
const N_TYPE: u8 = 0x0E;
const N_EXT: u8 = 0x01;
const N_SECT: u8 = 0x0E;
const N_ABS: u8 = 0x02;
const N_WEAK_DEF: u16 = 0x80;
const N_SO: u8 = 0x64;
const N_OSO: u8 = 0x66;
const N_BNSYM: u8 = 0x2E;
const N_FUN: u8 = 0x24;
const N_ENSYM: u8 = 0x4E;

const R_UNSIGNED: u32 = 0;
const R_SUBTRACTOR: u32 = 1;
const R_BRANCH26: u32 = 2;
const R_PAGE21: u32 = 3;
const R_PAGEOFF12: u32 = 4;
const R_GOT_LOAD_PAGE21: u32 = 5;
const R_GOT_LOAD_PAGEOFF12: u32 = 6;
const R_POINTER_TO_GOT: u32 = 7;
const R_TLVP_LOAD_PAGE21: u32 = 8;
const R_TLVP_LOAD_PAGEOFF12: u32 = 9;
const R_ADDEND: u32 = 10;

const DYLD_CHAINED_PTR_64_OFFSET: u32 = 6;
const DYLD_CHAINED_IMPORT_ADDEND: u32 = 2;

/// What a link produces.
pub const K_EXE: u8 = 0;
pub const K_DYLIB: u8 = 1;

/// A link: the objects, the libraries (`-l` names searched in `dirs`, then the SDK's `usr/lib`;
/// frameworks searched in `fdirs`, then the SDK's), the SDK root, the output and its kind (a dylib's
/// install name `install`), and whether to leave out the local symbols and the debug map (`strip`).
pub struct Opts {
    pub out: String,
    pub kind: u8,
    pub install: String,
    pub objs: Vector<String>,
    pub libs: Vector<String>,
    pub dirs: Vector<String>,
    pub fworks: Vector<String>,
    pub fdirs: Vector<String>,
    pub sdk: String,
    pub strip: bool,
    pub jobs: u32, // 1: the signature's page hashes in this thread, else on the task pool
}

// An input file: its bytes in the blob, its sections and symbols.
struct IFile {
    pub path: u32, // `L.paths` index
    pub at: usize,
    pub len: usize,
    pub sec0: u32,
    pub nsec: u32,
    pub sym0: u32,
    pub nsym: u32,
    pub debug: bool, // holds DWARF: the debug map names it
}

// An input section: names (`sn` ids), flags, alignment, the object's address and size, its bytes and
// relocations in the blob, and where it lands: output section `out` at offset `at`.
struct ISec {
    pub file: u32,
    pub seg: u32,
    pub sect: u32,
    pub flags: u32,
    pub align: u8,
    pub addr: u64,
    pub size: u64,
    pub off: usize,
    pub reloff: usize,
    pub nreloc: u32,
    pub out: u32,
    pub at: u64,
}

// An input symbol: its name (`names` id), nlist type, section (1-based in its file, 0 none), desc and value.
struct ISym {
    pub name: u32,
    pub ty: u8,
    pub sect: u8,
    pub desc: u16,
    pub value: u64,
    pub file: u32,
}

// A global symbol's state.
const G_UNDEF: u8 = 0;
const G_DEF: u8 = 1; // an object defines it: `sym`
const G_DYLIB: u8 = 2; // library `lib` (1-based ordinal) exports it
const G_COMMON: u8 = 3; // a tentative definition: `size` bytes aligned to `1 << align`, at `at` of `__common`
const G_HEADER: u8 = 4; // the image's own Mach-O header

struct GSym {
    pub name: u32,
    pub kind: u8,
    pub sym: u32,
    pub lib: u32,
    pub size: u64,
    pub align: u8,
    pub at: u64,
    pub got: u32,
    pub stub: u32,
    pub imp: u32,
    pub tlv: bool, // exported as a thread-local variable
    pub weak: bool,
}

// An output section: its segment (`SEG_*` or a later index for another segment), names, flags,
// alignment, its order within the segment, size, address and file offset.
struct OSec {
    pub seg: u32,
    pub segname: u32, // `sn` id
    pub sect: u32, // `sn` id
    pub flags: u32,
    pub align: u8,
    pub rank: u32,
    pub size: u64,
    pub addr: u64,
    pub off: u64,
}

// An output segment: its sections `first .. first + n` of the sorted output sections.
struct OSeg {
    pub name: String,
    pub first: u32,
    pub n: u32,
    pub addr: u64,
    pub vmsize: u64,
    pub off: u64,
    pub filesize: u64,
    pub prot: u32,
    pub flags: u32,
}

// A chained fixup: the pointer at image offset `at` gets the image offset `target` (rebase) or import
// `imp`.
struct Fix {
    pub at: u64,
    pub target: u64,
    pub imp: u32,
}

// An import: a library's symbol plus an addend.
struct Imp {
    pub name: u32,
    pub lib: u32,
    pub addend: i64,
    pub weak: bool,
}

// A library the image loads: its install name and versions.
struct Lib {
    pub install: String,
    pub cur: u32,
    pub compat: u32,
}

// A compact unwind range: where a function starts (input section `sec` at object address `v`, or image
// address `v` when `sec` is NONE) and its encoding.
struct Unw {
    pub sec: u32,
    pub v: u64,
    pub enc: u32,
}

extend IFile as Copy {}
extend ISec as Copy {}
extend ISym as Copy {}
extend GSym as Copy {}
extend Fix as Copy {}
extend Imp as Copy {}
extend Unw as Copy {}
extend OSec as Copy {}

const SEG_TEXT: u32 = 0;
const SEG_DCONST: u32 = 1;
const SEG_DATA: u32 = 2;

struct L {
    pub kind: u8,
    pub install: String,
    pub base: u64,
    pub files: Vector<IFile>,
    pub paths: Vector<String>,
    pub secs: Vector<ISec>,
    pub syms: Vector<ISym>,
    pub names: nm::Names,
    pub sn: nm::Names, // segment and section names
    pub glob: Vector<u32>, // per name id: its `gs` index plus 1 (0: not global)
    pub gs: Vector<GSym>,
    pub libs: Vector<Lib>,
    pub osecs: Vector<OSec>,
    pub segs: Vector<OSeg>,
    pub fixes: Vector<Fix>,
    pub imps: Vector<Imp>,
    pub got: Vector<u32>, // per slot: its `gs` index
    pub stubs: Vector<u32>, // per stub: its `gs` index
    pub unw: Vector<Unw>,
    pub unw_enc: Vector<u32>, // the distinct encodings: `__unwind_info`'s common table when at most 127
    pub o_stubs: u32,
    pub o_got: u32,
    pub o_unwind: u32,
    pub o_common: u32,
    pub tlv_start: u64, // the thread-local template's image offset
    pub tlv: bool,
    pub err: String,
}

/// Link `o`. False with the reason in `err` when it fails.
pub fn link(o: &Opts, err: &mut String) bool {
    let mut l = L {
        kind: o.kind,
        install: o.install.clone(),
        base: if o.kind == K_EXE {
            EXE_BASE;
        } else {
            0u64;
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
        osecs: Vector::<OSec>::new(),
        segs: Vector::<OSeg>::new(),
        fixes: Vector::<Fix>::new(),
        imps: Vector::<Imp>::new(),
        got: Vector::<u32>::new(),
        stubs: Vector::<u32>::new(),
        unw: Vector::<Unw>::new(),
        unw_enc: Vector::<u32>::new(),
        o_stubs: NONE,
        o_got: NONE,
        o_unwind: NONE,
        o_common: NONE,
        tlv_start: 0,
        tlv: false,
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
    for i in 0..o.objs.len() {
        if !read_object(l, o.objs[i].as_str(), blob) {
            return false;
        }
    }
    // An executable exports its header, as ld64 defines it.
    if o.kind == K_EXE {
        let _ = global(l, l.names.intern("__mh_execute_header"));
    }
    let b = blob.as_slice();
    if !resolve_objects(l, b) || !load_libraries(l, o) || !finish_symbols(l) || !scan_relocations(l, b) {
        return false;
    }
    if !layout(l, b) {
        return false;
    }
    let mut img = Vector::<u8>::new();
    let end = l.segs[l.segs.len() - 1].off;
    img.resize_default(end as usize);
    if !copy_sections(l, b, &mut img) || !apply_relocations(l, b, &mut img) {
        return false;
    }
    if !write_synthetic(l, &mut img) {
        return false;
    }
    finish(l, o, b, &mut img);
    if !lu::write(o.out.as_str(), img.as_slice(), 0o755) {
        l.err.format_into("cannot write '{}'", o.out.as_str());
        return false;
    }
    return true;
}

// ---- input ----------------------------------------------------------------------------------------------

// Append object `path` to the blob and record its sections and symbols.
fn read_object(l: &mut L, path: str, blob: &mut Vector<u8>) bool {
    let at = blob.len();
    if !lu::read_append(path, blob) {
        l.err.format_into("cannot read '{}'", path);
        return false;
    }
    let b = blob.as_slice();
    let n = b.len() - at;
    if n < 32 || lu::r32(b, at) != MH_MAGIC_64 || lu::r32(b, at + 4) != CPU_ARM64 || lu::r32(b, at + 12) != MH_OBJECT {
        l.err.format_into("'{}' is not an arm64 Mach-O object", path);
        return false;
    }
    let fi = l.files.len() as u32;
    l.paths.push(String::from_str(path));
    let mut f = IFile {
        path: (l.paths.len() - 1) as u32,
        at: at,
        len: n,
        sec0: l.secs.len() as u32,
        nsec: 0,
        sym0: l.syms.len() as u32,
        nsym: 0,
        debug: false,
    };
    let ncmds = lu::r32(b, at + 16);
    let mut c = at + 32;
    for _ in 0..ncmds {
        if c + 8 > at + n {
            l.err.format_into("'{}': truncated load commands", path);
            return false;
        }
        let cmd = lu::r32(b, c);
        let size = lu::r32(b, c + 4) as usize;
        if cmd == LC_SEGMENT_64 {
            let nsect = lu::r32(b, c + 64);
            for k in 0..nsect as usize {
                let s = c + 72 + 80 * k;
                let flags = lu::r32(b, s + 64);
                let seg = l.sn.intern(lu::cstr(b[s + 16..s + 32], 0));
                let sect = l.sn.intern(lu::cstr(b[s..s + 16], 0));
                if (flags & S_ATTR_DEBUG) != 0 {
                    f.debug = true;
                }
                l.secs.push(
                    ISec {
                        file: fi,
                        seg: seg,
                        sect: sect,
                        flags: flags,
                        align: lu::r32(b, s + 52) as u8,
                        addr: lu::r64(b, s + 32),
                        size: lu::r64(b, s + 40),
                        off: at + lu::r32(b, s + 48) as usize,
                        reloff: at + lu::r32(b, s + 56) as usize,
                        nreloc: lu::r32(b, s + 60),
                        out: NONE,
                        at: 0,
                    },
                );
                f.nsec += 1;
            }
        } else if cmd == LC_SYMTAB {
            let symoff = at + lu::r32(b, c + 8) as usize;
            let nsyms = lu::r32(b, c + 12);
            let stroff = at + lu::r32(b, c + 16) as usize;
            let strs = b[stroff..at + n];
            for k in 0..nsyms as usize {
                let e = symoff + 16 * k;
                l.syms.push(
                    ISym {
                        name: l.names.intern(lu::cstr(strs, lu::r32(b, e) as usize)),
                        ty: b[e + 4],
                        sect: b[e + 5],
                        desc: lu::r16(b, e + 6) as u16,
                        value: lu::r64(b, e + 8),
                        file: fi,
                    },
                );
            }
            f.nsym = nsyms;
        }
        c += size;
    }
    l.files.push(f);
    return true;
}

// The `gs` index of global name `id`, added undefined when new.
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
                lib: 0,
                size: 0,
                align: 0,
                at: 0,
                got: NONE,
                stub: NONE,
                imp: NONE,
                tlv: false,
                weak: false,
            },
        );
        l.glob[id as usize] = l.gs.len() as u32;
    }
    return l.glob[id as usize] - 1;
}

// Enter every object's external symbols into the global table: a definition, a tentative one (the
// largest size wins) or a reference. Two strong definitions of a name are an error.
fn resolve_objects(l: &mut L, b: []u8) bool {
    for k in 0..l.syms.len() {
        let y = l.syms[k];
        if (y.ty & N_STAB) != 0 || (y.ty & N_EXT) == 0 {
            continue;
        }
        let g = global(l, y.name);
        let mut gy = l.gs[g as usize];
        let t = y.ty & N_TYPE;
        if t == N_SECT || t == N_ABS {
            let weak = (y.desc & N_WEAK_DEF) != 0;
            if gy.kind == G_DEF {
                if weak {
                    continue;
                }
                if !gy.weak {
                    l.err.format_into(
                        "duplicate symbol '{}' in '{}' and '{}'",
                        l.names.spell(y.name),
                        l.paths[l.files[l.syms[gy.sym as usize].file as usize].path as usize].as_str(),
                        l.paths[l.files[y.file as usize].path as usize].as_str(),
                    );
                    return false;
                }
            }
            gy.kind = G_DEF;
            gy.sym = k as u32;
            gy.weak = weak;
            gy.tlv = t == N_SECT && sec_type(l, y.file, y.sect) == S_THREAD_LOCAL_VARIABLES;
        } else if y.value != 0 && gy.kind != G_DEF {
            // A common symbol: its value is its size, its desc bits 8.. its alignment.
            gy.kind = G_COMMON;
            if y.value > gy.size {
                gy.size = y.value;
            }
            let al = (y.desc >> 8 & 0xF) as u8;
            if al > gy.align {
                gy.align = al;
            }
        }
        l.gs[g as usize] = gy;
    }
    let _ = b;
    return true;
}

// The section type of section `sect` (1-based) of file `f`.
fn sec_type(l: &L, f: u32, sect: u8) u32 {
    return l.secs[(l.files[f as usize].sec0 + sect as u32 - 1) as usize].flags & S_TYPE;
}

// ---- libraries ------------------------------------------------------------------------------------------

// The stub targets an arm64 macOS image links against: Apple's system stubs list only arm64e.
const WANT: [str; 2] = ["arm64-macos", "arm64e-macos"];

// Load libSystem, then each `-l` library and framework in order; each one's exports resolve the undefined
// globals not yet resolved.
fn load_libraries(l: &mut L, o: &Opts) bool {
    let sys = format("{}/usr/lib/libSystem.tbd", o.sdk.as_str());
    if !load_file(l, o, sys.as_str()) {
        return false;
    }
    for i in 0..o.libs.len() {
        let name = o.libs[i].as_str();
        let mut found = String::new();
        if find_lib(o, name, &mut found) != LIB_SHARED {
            found.clear();
        }
        if found.len() == 0 {
            l.err.format_into("library not found: -l{}", name);
            return false;
        }
        if !load_file(l, o, found.as_str()) {
            return false;
        }
    }
    for i in 0..o.fworks.len() {
        let name = o.fworks[i].as_str();
        let mut found = String::new();
        for d in 0..o.fdirs.len() + 1 {
            let dir = if d < o.fdirs.len() {
                o.fdirs[d].clone();
            } else {
                format("{}/System/Library/Frameworks", o.sdk.as_str());
            };
            for ext in [".tbd", ""] {
                let c = format("{}/{}.framework/{}{}", dir.as_str(), name, name, ext);
                if found.len() == 0 && is_file(c.as_str()) {
                    found = c;
                }
            }
        }
        if found.len() == 0 {
            l.err.format_into("framework not found: {}", name);
            return false;
        }
        if !load_file(l, o, found.as_str()) {
            return false;
        }
    }
    return true;
}

/// What `find_lib` finds.
pub const LIB_NONE: u8 = 0;
pub const LIB_SHARED: u8 = 1; // a stub or a dylib
pub const LIB_ARCHIVE: u8 = 2;

/// Library `-l<name>` of link `o`, as ld64 searches: each directory of `dirs`, then the SDK's
/// `usr/lib`, for `lib<name>.tbd`, `.dylib`, then `.a`; its path into `path`.
pub fn find_lib(o: &Opts, name: str, path: &mut String) u8 {
    for d in 0..o.dirs.len() + 1 {
        let dir = if d < o.dirs.len() {
            o.dirs[d].clone();
        } else {
            format("{}/usr/lib", o.sdk.as_str());
        };
        for k in 0..3usize {
            let ext = if k == 0 {
                ".tbd";
            } else if k == 1 {
                ".dylib";
            } else {
                ".a";
            };
            let c = format("{}/lib{}{}", dir.as_str(), name, ext);
            if is_file(c.as_str()) {
                path.clear();
                path.push_string(&c);
                return if k == 2 {
                    LIB_ARCHIVE;
                } else {
                    LIB_SHARED;
                };
            }
        }
    }
    return LIB_NONE;
}

fn is_file(p: str) bool {
    let m = fs::stat(p);
    return m.is_ok() && m.unwrap().kind == fs::FileKind::File;
}

// Load the library in file `path` (a stub or a dylib): it gets the next ordinal unless an earlier
// library has its install name.
fn load_file(l: &mut L, o: &Opts, path: str) bool {
    let data = lu::read(path);
    if data.is_none() {
        l.err.format_into("cannot read '{}'", path);
        return false;
    }
    let d = data.unwrap();
    let b = d.as_slice();
    if path.ends_with(".tbd") {
        let mut docs = Vector::<tbd::Doc>::new();
        if !tbd::parse(b, WANT, &mut docs) || docs.len() == 0 {
            l.err.format_into("'{}' is not a text-based stub this linker reads", path);
            return false;
        }
        let install = tbd::span(b, docs[0].install);
        let ord = ordinal(l, install, 0x10000, 0x10000);
        if ord == NONE {
            return true;
        }
        // Each re-exported library's symbols bind through this one: from a document of the same file,
        // else from its own stub in the SDK. A stub names each at most once; the depth is the SDK's.
        let mut todo = Vector::<String>::new();
        todo.push(String::from_str(install));
        let mut done = Vector::<String>::new();
        while todo.len() != 0 {
            let name = todo.pop().unwrap();
            if done.contains(&name) {
                continue;
            }
            let mut hit = false;
            for k in 0..docs.len() {
                if !hit && tbd::span(b, docs[k].install) == name.as_str() {
                    hit = true;
                    export_doc(l, b, &docs[k], ord);
                    for r in 0..docs[k].reexports.len() {
                        todo.push(String::from_str(tbd::span(b, docs[k].reexports[r])));
                    }
                }
            }
            if !hit && !reexport_file(l, o, name.as_str(), ord, &mut todo) {
                return false;
            }
            done.push(name);
        }
        return true;
    }
    return load_dylib(l, o, b, path, NONE);
}

// The ordinal of the library with install name `install`, added when new; NONE when an earlier
// library has it (its symbols bound already).
fn ordinal(l: &mut L, install: str, cur: u32, compat: u32) u32 {
    for i in 0..l.libs.len() {
        if l.libs[i].install.as_str() == install {
            return NONE;
        }
    }
    l.libs.push(Lib { install: String::from_str(install), cur: cur, compat: compat });
    return l.libs.len() as u32;
}

// Bind every undefined global document `d` of stub `b` exports to library `ord`.
fn export_doc(l: &mut L, b: []u8, d: &tbd::Doc, ord: u32) {
    for i in 0..d.exports.len() {
        let e = d.exports[i];
        let s = tbd::span(b, e);
        if e.kind == tbd::E_PLAIN {
            bind_export(l, s, ord);
        } else if e.kind == tbd::E_OBJC_CLASS {
            bind_export(l, format("_OBJC_CLASS_$_{}", s).as_str(), ord);
            bind_export(l, format("_OBJC_METACLASS_$_{}", s).as_str(), ord);
        } else if e.kind == tbd::E_OBJC_EH {
            bind_export(l, format("_OBJC_EHTYPE_$_{}", s).as_str(), ord);
        } else {
            bind_export(l, format("_OBJC_IVAR_$_{}", s).as_str(), ord);
        }
    }
}

fn bind_export(l: &mut L, s: str, ord: u32) {
    let id = l.names.find(s);
    if id < 0 || id as usize >= l.glob.len() || l.glob[id as usize] == 0 {
        return;
    }
    let g = (l.glob[id as usize] - 1) as usize;
    if l.gs[g].kind == G_UNDEF {
        l.gs.index_mut(g).kind = G_DYLIB;
        l.gs.index_mut(g).lib = ord;
    }
}

// A re-exported library `install` of library `ord` whose stub is its own file in the SDK: its exports,
// and its own re-exports onto `todo`.
fn reexport_file(l: &mut L, o: &Opts, install: str, ord: u32, todo: &mut Vector<String>) bool {
    let mut stem = String::from_str(install);
    if install.ends_with(".dylib") {
        stem = String::from_str(install.slice(0, install.len() - 6));
    }
    let path = format("{}{}.tbd", o.sdk.as_str(), stem.as_str());
    let data = lu::read(path.as_str());
    if data.is_none() {
        l.err.format_into("cannot find the stub of re-exported library '{}'", install);
        return false;
    }
    let d = data.unwrap();
    let b = d.as_slice();
    let mut docs = Vector::<tbd::Doc>::new();
    if !tbd::parse(b, WANT, &mut docs) || docs.len() == 0 {
        l.err.format_into("'{}' is not a text-based stub this linker reads", path.as_str());
        return false;
    }
    export_doc(l, b, &docs[0], ord);
    for r in 0..docs[0].reexports.len() {
        todo.push(String::from_str(tbd::span(b, docs[0].reexports[r])));
    }
    return true;
}

// A Mach-O dylib (or the arm64 slice of a universal one) at `path`: library `ord` (NONE: a new ordinal
// from its install name), its exports trie, and the libraries it re-exports.
fn load_dylib(l: &mut L, o: &Opts, d: []u8, path: str, ord0: u32) bool {
    let mut at: usize = 0;
    if d.len() >= 8 && lu::r32(d, 0) == FAT_MAGIC {
        let n = be32(d, 4) as usize;
        let mut hit = false;
        for k in 0..n {
            let e = 8 + 20 * k;
            if !hit && e + 20 <= d.len() && be32(d, e) == CPU_ARM64 {
                at = be32(d, e + 8) as usize;
                hit = true;
            }
        }
        if !hit {
            l.err.format_into("'{}' has no arm64 slice", path);
            return false;
        }
    }
    if d.len() < at + 32 || lu::r32(d, at) != MH_MAGIC_64 || lu::r32(d, at + 12) != MH_DYLIB {
        l.err.format_into("'{}' is not an arm64 dylib", path);
        return false;
    }
    let ncmds = lu::r32(d, at + 16);
    let mut ord = ord0;
    let mut trie_off: usize = 0;
    let mut trie_size: usize = 0;
    let mut reexp = Vector::<String>::new();
    let mut c = at + 32;
    for _ in 0..ncmds {
        let cmd = lu::r32(d, c);
        if cmd == LC_ID_DYLIB && ord == NONE {
            let name = lu::cstr(d, c + lu::r32(d, c + 8) as usize);
            ord = ordinal(l, name, lu::r32(d, c + 16), lu::r32(d, c + 20));
            if ord == NONE {
                return true;
            }
        } else if cmd == LC_DYLD_EXPORTS_TRIE {
            trie_off = at + lu::r32(d, c + 8) as usize;
            trie_size = lu::r32(d, c + 12) as usize;
        } else if cmd == LC_DYLD_INFO_ONLY {
            trie_off = at + lu::r32(d, c + 40) as usize;
            trie_size = lu::r32(d, c + 44) as usize;
        } else if cmd == LC_REEXPORT_DYLIB {
            reexp.push(String::from_str(lu::cstr(d, c + lu::r32(d, c + 8) as usize)));
        }
        c += lu::r32(d, c + 4) as usize;
    }
    if ord == NONE {
        l.err.format_into("'{}' has no install name", path);
        return false;
    }
    // Walk the trie depth-first with an explicit stack of (node offset, name length).
    let t = d[trie_off..trie_off + trie_size];
    let mut name = Vector::<u8>::new();
    let mut stack = Vector::<(usize, usize)>::new();
    if trie_size != 0 {
        stack.push((0usize, 0usize));
    }
    let mut steps: usize = 0;
    while stack.len() != 0 {
        steps += 1;
        if steps > trie_size {
            l.err.format_into("'{}': malformed exports trie", path);
            return false;
        }
        let (node, nl) = stack.pop().unwrap();
        name.truncate(nl);
        let mut p = node;
        let term = lu::read_uleb(t, &mut p) as usize;
        if term != 0 {
            bind_export(l, unsafe str::from_raw(name.as_ptr(), name.len()), ord);
        }
        p += term;
        if p >= t.len() {
            continue;
        }
        let nchild = t[p] as usize;
        p += 1;
        for _ in 0..nchild {
            let es = p;
            while p < t.len() && t[p] != 0 {
                p += 1;
            }
            let edge = t[es..p];
            p += 1;
            let child = lu::read_uleb(t, &mut p) as usize;
            // The child's name: this node's, then the edge; kept past the stack's other entries.
            let mut full = Vector::<u8>::new();
            full.extend_from_slice(name.as_slice());
            full.extend_from_slice(edge);
            let sub = name.len();
            name.extend_from_slice(edge);
            stack.push((child, name.len()));
            name.truncate(sub);
            let _ = full;
        }
    }
    for i in 0..reexp.len() {
        let r = reexp[i].as_str();
        let p = format("{}{}", o.sdk.as_str(), r);
        let rd = lu::read(p.as_str());
        if rd.is_none() {
            continue;
        }
        let rb = rd.unwrap();
        if !load_dylib(l, o, rb.as_slice(), p.as_str(), ord) {
            return false;
        }
    }
    return true;
}

fn be32(b: []u8, at: usize) u32 {
    return b[at] as u32 << 24 | b[at + 1] as u32 << 16 | b[at + 2] as u32 << 8 | b[at + 3] as u32;
}

// The symbols no input defines: `__mh_execute_header` (or `__mh_dylib_header`) is the image's header, a
// `___sc_zst_<A>` sentinel a fresh `A`-aligned byte. Any other one is an error.
fn finish_symbols(l: &mut L) bool {
    let mut missing = String::new();
    let mut nmiss: usize = 0;
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        if gy.kind != G_UNDEF {
            continue;
        }
        let s = l.names.spell(gy.name);
        if s == "__mh_execute_header" || s == "__mh_dylib_header" {
            l.gs.index_mut(g).kind = G_HEADER;
            continue;
        }
        if s.starts_with("___sc_zst_") {
            let a = parse_u64(s.slice(10, s.len()));
            if a != 0 && (a & a - 1) == 0 {
                let y = l.gs.index_mut(g);
                y.kind = G_COMMON;
                y.size = 1;
                y.align = log2(a);
                continue;
            }
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

fn parse_u64(s: str) u64 {
    let mut v: u64 = 0;
    for i in 0..s.len() {
        let c = s.byte_at(i);
        if c < b'0' || c > b'9' || v > 0xFFFFFFFF {
            return 0;
        }
        v = v * 10 + (c - b'0') as u64;
    }
    return v;
}

fn log2(a: u64) u8 {
    let mut n: u8 = 0;
    while 1u64 << n as u64 < a {
        n += 1;
    }
    return n;
}

// ---- relocations: what needs a GOT slot, a stub or an import --------------------------------------------

// The global a relocation's symbol `y` refers to, or NONE for a local symbol.
fn gof(l: &L, y: ISym) u32 {
    if (y.ty & N_EXT) == 0 || (y.ty & N_STAB) != 0 {
        return NONE;
    }
    return l.glob[y.name as usize] - 1;
}

fn scan_relocations(l: &mut L, b: []u8) bool {
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if dropped(l, sc) {
            continue;
        }
        let f = l.files[sc.file as usize];
        for r in 0..sc.nreloc as usize {
            let w1 = lu::r32(b, sc.reloff + 8 * r + 4);
            let ty = w1 >> 28;
            if (w1 >> 27 & 1) == 0 || ty == R_ADDEND {
                continue;
            }
            let y = l.syms[(f.sym0 + (w1 & 0xFFFFFF)) as usize];
            let g = gof(l, y);
            if g == NONE {
                if ty == R_GOT_LOAD_PAGE21 || ty == R_GOT_LOAD_PAGEOFF12 || ty == R_POINTER_TO_GOT {
                    l.err.format_into(
                        "'{}': a GOT reference to local symbol '{}'",
                        l.paths[f.path as usize].as_str(),
                        l.names.spell(y.name),
                    );
                    return false;
                }
                continue;
            }
            let k = l.gs[g as usize].kind;
            if ty == R_GOT_LOAD_PAGE21 || ty == R_GOT_LOAD_PAGEOFF12 || ty == R_POINTER_TO_GOT {
                if l.gs[g as usize].got == NONE {
                    l.gs.index_mut(g as usize).got = l.got.len() as u32;
                    l.got.push(g);
                }
            } else if ty == R_BRANCH26 && k == G_DYLIB {
                if l.gs[g as usize].stub == NONE {
                    l.gs.index_mut(g as usize).stub = l.stubs.len() as u32;
                    l.stubs.push(g);
                    if l.gs[g as usize].got == NONE {
                        l.gs.index_mut(g as usize).got = l.got.len() as u32;
                        l.got.push(g);
                    }
                }
            } else if (ty == R_TLVP_LOAD_PAGE21 || ty == R_TLVP_LOAD_PAGEOFF12) && k == G_DYLIB {
                l.err.format_into(
                    "'{}': thread-local variable '{}' comes from a library",
                    l.paths[f.path as usize].as_str(),
                    l.names.spell(y.name),
                );
                return false;
            } else if (ty == R_PAGE21 || ty == R_PAGEOFF12) && k == G_DYLIB {
                l.err.format_into(
                    "'{}': a direct reference to '{}', which a library defines",
                    l.paths[f.path as usize].as_str(),
                    l.names.spell(y.name),
                );
                return false;
            }
        }
    }
    return true;
}

// Whether input section `s` stays out of the image: debug information, and the linker's own input
// (`__LD`: the compact unwind entries `__unwind_info` replaces).
fn dropped(l: &L, s: ISec) bool {
    return (s.flags & S_ATTR_DEBUG) != 0 || l.sn.spell(s.seg) == "__LD";
}

// ---- layout ---------------------------------------------------------------------------------------------

// The output section of segment `seg`, section `sect` with `flags`, added when new.
fn out_section(l: &mut L, segname: str, sect: str, flags: u32) u32 {
    let sg = l.sn.intern(segname);
    let st = l.sn.intern(sect);
    for i in 0..l.osecs.len() {
        if l.osecs[i].segname == sg && l.osecs[i].sect == st {
            return i as u32;
        }
    }
    let seg = if segname == "__TEXT" {
        SEG_TEXT;
    } else if segname == "__DATA_CONST" {
        SEG_DCONST;
    } else if segname == "__DATA" {
        SEG_DATA;
    } else {
        3 + l.osecs.len() as u32;
    };
    l.osecs.push(
        OSec {
            seg: seg,
            segname: sg,
            sect: st,
            flags: flags,
            align: 0,
            rank: rank(segname, sect, flags),
            size: 0,
            addr: 0,
            off: 0,
        },
    );
    return (l.osecs.len() - 1) as u32;
}

// A section's order within its segment: code first, the unwind table last in __TEXT; the thread-local
// sections together (their template is one range) and every zero-filled one last in __DATA.
fn rank(seg: str, sect: str, flags: u32) u32 {
    let t = flags & S_TYPE;
    if seg == "__TEXT" {
        if sect == "__text" {
            return 0;
        }
        if sect == "__stubs" {
            return 1;
        }
        if (flags & S_ATTR_SOME_INSTRUCTIONS) != 0 {
            return 2;
        }
        if sect == "__unwind_info" {
            return 9;
        }
        return 5;
    }
    if seg == "__DATA_CONST" {
        if sect == "__got" {
            return 0;
        }
        return 5;
    }
    if t == S_THREAD_LOCAL_VARIABLES {
        return 6;
    }
    if t == S_THREAD_LOCAL_REGULAR {
        return 7;
    }
    if t == S_THREAD_LOCAL_ZEROFILL {
        return 8;
    }
    if t == S_ZEROFILL || t == S_GB_ZEROFILL {
        return 9;
    }
    if sect == "__data" {
        return 0;
    }
    return 5;
}

// Whether section flags `fl` hold no file bytes.
fn zerofill(fl: u32) bool {
    let t = fl & S_TYPE;
    return t == S_ZEROFILL || t == S_GB_ZEROFILL || t == S_THREAD_LOCAL_ZEROFILL;
}

// Assign every kept input section its output section and offset, add the synthetic sections, sort the
// sections into segments, then give the segments and sections their addresses and file offsets.
fn layout(l: &mut L, b: []u8) bool {
    if l.stubs.len() != 0 {
        l.o_stubs = out_section(
            l,
            "__TEXT",
            "__stubs",
            S_SYMBOL_STUBS | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS,
        );
    }
    if l.got.len() != 0 {
        l.o_got = out_section(l, "__DATA_CONST", "__got", S_NON_LAZY_SYMBOL_POINTERS);
    }
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if dropped(l, sc) || sc.size == 0 && (sc.flags & S_TYPE) != S_THREAD_LOCAL_VARIABLES {
            continue;
        }
        let mut seg = String::from_str(l.sn.spell(sc.seg));
        let sect = String::from_str(l.sn.spell(sc.sect));
        // Read-only after the fixups: constant data with pointers and the initializers.
        if seg.as_str() == "__DATA" && (sect.as_str() == "__const" || (sc.flags & S_TYPE) == S_MOD_INIT_FUNC_POINTERS) {
            seg = String::from_str("__DATA_CONST");
        }
        let o = out_section(l, seg.as_str(), sect.as_str(), sc.flags);
        let os = l.osecs.index_mut(o as usize);
        if sc.align > os.align {
            os.align = sc.align;
        }
        let a = 1u64 << sc.align as u64;
        os.size = lu::align_up(os.size, a);
        let at = os.size;
        os.size += sc.size;
        os.flags |= sc.flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS);
        let ms = l.secs.index_mut(s);
        ms.out = o;
        ms.at = at;
    }
    let mut ncommon: usize = 0;
    for g in 0..l.gs.len() {
        if l.gs[g].kind == G_COMMON {
            ncommon += 1;
        }
    }
    if ncommon != 0 {
        l.o_common = out_section(l, "__DATA", "__common", S_ZEROFILL);
        for g in 0..l.gs.len() {
            let gy = l.gs[g];
            if gy.kind != G_COMMON {
                continue;
            }
            let os = l.osecs.index_mut(l.o_common as usize);
            if gy.align > os.align {
                os.align = gy.align;
            }
            os.size = lu::align_up(os.size, 1u64 << gy.align as u64);
            l.gs.index_mut(g).at = os.size;
            os.size += gy.size;
        }
    }
    if l.stubs.len() != 0 {
        let os = l.osecs.index_mut(l.o_stubs as usize);
        os.size = 12 * l.stubs.len() as u64;
        os.align = 2;
    }
    if l.got.len() != 0 {
        let os = l.osecs.index_mut(l.o_got as usize);
        os.size = 8 * l.got.len() as u64;
        os.align = 3;
    }
    if !collect_unwind(l, b) {
        return false;
    }
    l.o_unwind = out_section(l, "__TEXT", "__unwind_info", S_REGULAR);
    let uo = l.o_unwind as usize;
    l.osecs.index_mut(uo).size = unwind_size(l);
    l.osecs.index_mut(uo).align = 2;
    // Sort by segment, then rank, then first appearance; remap the input sections and the synthetic ones.
    let n = l.osecs.len();
    let mut keys = Vector::<u64>::with_capacity(n);
    for i in 0..n {
        let os = &l.osecs[i];
        keys.push(os.seg as u64 << 40 | os.rank as u64 << 32 | i as u64);
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
    l.o_stubs = remap(l.o_stubs, &newix);
    l.o_got = remap(l.o_got, &newix);
    l.o_common = remap(l.o_common, &newix);
    l.o_unwind = remap(l.o_unwind, &newix);
    // Segments: __PAGEZERO for an executable, then one per segment name in order, then __LINKEDIT.
    if l.kind == K_EXE {
        l.segs.push(
            OSeg {
                name: String::from_str("__PAGEZERO"),
                first: 0,
                n: 0,
                addr: 0,
                vmsize: EXE_BASE,
                off: 0,
                filesize: 0,
                prot: 0,
                flags: 0,
            },
        );
    }
    let mut i: usize = 0;
    while i < n {
        let first = i;
        while i < n && l.osecs[i].seg == l.osecs[first].seg {
            i += 1;
        }
        let name = String::from_str(l.sn.spell(l.osecs[first].segname));
        let prot = if name.as_str() == "__TEXT" {
            5u32;
        } else {
            3u32;
        };
        let flags = if name.as_str() == "__DATA_CONST" {
            SG_READ_ONLY;
        } else {
            0u32;
        };
        l.segs.push(
            OSeg {
                name: name,
                first: first as u32,
                n: (i - first) as u32,
                addr: 0,
                vmsize: 0,
                off: 0,
                filesize: 0,
                prot: prot,
                flags: flags,
            },
        );
    }
    l.segs.push(
        OSeg {
            name: String::from_str("__LINKEDIT"),
            first: n as u32,
            n: 0,
            addr: 0,
            vmsize: 0,
            off: 0,
            filesize: 0,
            prot: 1,
            flags: 0,
        },
    );
    // Addresses: __TEXT holds the header and load commands; each segment starts on a page.
    let hdr = 32 + cmds_size(l);
    let mut va: u64 = 0;
    let mut fo: u64 = 0;
    for k in 0..l.segs.len() {
        let sg = &l.segs[k];
        if sg.name.as_str() == "__PAGEZERO" {
            continue;
        }
        let first = sg.first as usize;
        let cnt = sg.n as usize;
        let seg_va = va;
        let seg_fo = fo;
        let mut at: u64 = if k == 0 || l.segs[k - 1].name.as_str() == "__PAGEZERO" {
            hdr;
        } else {
            0u64;
        };
        let mut fend: u64 = at;
        for q in first..first + cnt {
            let os = l.osecs.index_mut(q);
            at = lu::align_up(at, 1u64 << os.align as u64);
            os.addr = l.base + seg_va + at;
            os.off = if zerofill(os.flags) {
                0u64;
            } else {
                seg_fo + at;
            };
            at += os.size;
            if !zerofill(os.flags) {
                fend = at;
            }
        }
        let msg = l.segs.index_mut(k);
        msg.addr = l.base + seg_va;
        msg.off = seg_fo;
        msg.vmsize = lu::align_up(at, PAGE);
        msg.filesize = lu::align_up(fend, PAGE);
        if msg.name.as_str() == "__LINKEDIT" {
            msg.vmsize = 0;
            msg.filesize = 0;
        }
        va += msg.vmsize;
        fo += msg.filesize;
    }
    // The thread-local template: the thread-local sections' range, from the first one's start.
    let mut found = false;
    for q in 0..n {
        let t = l.osecs[q].flags & S_TYPE;
        if (t == S_THREAD_LOCAL_REGULAR || t == S_THREAD_LOCAL_ZEROFILL) && !found {
            found = true;
            l.tlv_start = l.osecs[q].addr;
        }
        if t == S_THREAD_LOCAL_VARIABLES {
            l.tlv = true;
        }
    }
    return true;
}

fn remap(o: u32, newix: &Vector<u32>) u32 {
    if o == NONE {
        return NONE;
    }
    return newix[o as usize];
}

// The size of the load commands (header excluded).
fn cmds_size(l: &L) u64 {
    let mut n: u64 = 0;
    for k in 0..l.segs.len() {
        n += 72 + 80 * l.segs[k].n as u64;
    }
    n += 16 + 16 + 24 + 80 + 24 + 24 + 16 + 16;
    if l.kind == K_EXE {
        n += 32 + 24;
    } else {
        n += lu::align_up(24 + l.install.len() as u64 + 1, 8);
    }
    for i in 0..l.libs.len() {
        n += lu::align_up(24 + l.libs[i].install.len() as u64 + 1, 8);
    }
    return n;
}

// ---- symbol addresses -----------------------------------------------------------------------------------

// The address of input symbol `k` (defined in its file).
fn sym_addr(l: &L, k: u32) u64 {
    let y = l.syms[k as usize];
    if (y.ty & N_TYPE) == N_ABS {
        return y.value;
    }
    let s = l.secs[(l.files[y.file as usize].sec0 + y.sect as u32 - 1) as usize];
    if s.out == NONE {
        return 0;
    }
    return (l.osecs[s.out as usize].addr + s.at).wrapping_add(y.value.wrapping_sub(s.addr));
}

// The address of global `g` (not a library's).
fn g_addr(l: &L, g: u32) u64 {
    let gy = l.gs[g as usize];
    if gy.kind == G_DEF {
        return sym_addr(l, gy.sym);
    }
    if gy.kind == G_COMMON {
        return l.osecs[l.o_common as usize].addr + gy.at;
    }
    return l.base;
}

// ---- section bytes and relocations ----------------------------------------------------------------------

fn copy_sections(l: &mut L, b: []u8, img: &mut Vector<u8>) bool {
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if sc.out == NONE || zerofill(sc.flags) {
            continue;
        }
        let at = (l.osecs[sc.out as usize].off + sc.at) as usize;
        for i in 0..sc.size as usize {
            img[at + i] = b[sc.off + i];
        }
    }
    return true;
}

// The import of library symbol `g` plus `addend`, added when new.
fn import_of(l: &mut L, g: u32, addend: i64) u32 {
    let gy = l.gs[g as usize];
    if addend == 0 && gy.imp != NONE {
        return gy.imp;
    }
    for i in 0..l.imps.len() {
        if l.imps[i].name == gy.name && l.imps[i].addend == addend {
            return i as u32;
        }
    }
    l.imps.push(Imp { name: gy.name, lib: gy.lib, addend: addend, weak: false });
    let i = (l.imps.len() - 1) as u32;
    if addend == 0 {
        l.gs.index_mut(g as usize).imp = i;
    }
    return i;
}

// A pointer at image address `at` to `value`, or to library symbol `g` plus `addend` when `g` is not
// NONE: a chained fixup.
fn pointer(l: &mut L, at: u64, value: u64, g: u32, addend: i64) {
    if g != NONE {
        let imp = import_of(l, g, addend);
        l.fixes.push(Fix { at: at - l.base, target: 0, imp: imp });
    } else {
        l.fixes.push(Fix { at: at - l.base, target: value - l.base, imp: NONE });
    }
}

fn apply_relocations(l: &mut L, b: []u8, img: &mut Vector<u8>) bool {
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if sc.out == NONE || sc.nreloc == 0 {
            continue;
        }
        let os = l.osecs[sc.out as usize];
        let f = l.files[sc.file as usize];
        let writable = l.sn.spell(os.segname) != "__TEXT";
        let tvars = (sc.flags & S_TYPE) == S_THREAD_LOCAL_VARIABLES;
        let mut addend: i64 = 0;
        let mut sub: u64 = 0;
        let mut has_sub = false;
        for r in 0..sc.nreloc as usize {
            let w0 = lu::r32(b, sc.reloff + 8 * r);
            let w1 = lu::r32(b, sc.reloff + 8 * r + 4);
            let off = w0 as u64;
            let symnum = w1 & 0xFFFFFF;
            let pcrel = (w1 >> 24 & 1) != 0;
            let len = w1 >> 25 & 3;
            let ext = (w1 >> 27 & 1) != 0;
            let ty = w1 >> 28;
            if ty == R_ADDEND {
                addend = (symnum << 8) as i32 >> 8;
                continue;
            }
            let p_addr = os.addr + sc.at + off;
            let p = (os.off + sc.at + off) as usize;
            // The target: a symbol (local, global or a library's), or a section of the object.
            let mut g = NONE;
            let mut target: u64 = 0;
            if ext {
                let k = f.sym0 + symnum;
                let y = l.syms[k as usize];
                g = gof(l, y);
                if g == NONE {
                    target = sym_addr(l, k);
                } else if l.gs[g as usize].kind != G_DYLIB {
                    target = g_addr(l, g);
                    g = NONE;
                }
            } else if ty != R_UNSIGNED && ty != R_SUBTRACTOR {
                l.err.format_into(
                    "'{}': a section-relative relocation of type {}",
                    l.paths[f.path as usize].as_str(),
                    ty,
                );
                return false;
            }
            if ty == R_SUBTRACTOR {
                if g != NONE {
                    l.err.format_into("'{}': a difference with a library's symbol", l.paths[f.path as usize].as_str());
                    return false;
                }
                sub = target;
                has_sub = true;
                continue;
            }
            if ty == R_UNSIGNED {
                let stored = if len == 3 {
                    lu::r64(img.as_slice(), p);
                } else {
                    lu::r32(img.as_slice(), p) as u64;
                };
                if !ext {
                    target = section_relative(l, f, symnum, stored);
                }
                let v = if ext {
                    target.wrapping_add(stored);
                } else {
                    target;
                };
                if has_sub {
                    has_sub = false;
                    let d = v.wrapping_sub(sub);
                    if len == 3 {
                        lu::p64(img, p, d);
                    } else {
                        lu::p32(img, p, d as u32);
                    }
                    continue;
                }
                if len != 3 || pcrel {
                    l.err.format_into("'{}': a 32-bit absolute address", l.paths[f.path as usize].as_str());
                    return false;
                }
                if tvars && off % 24 == 16 {
                    // A descriptor's third word: its variable's offset in the thread-local template.
                    lu::p64(img, p, v - l.tlv_start);
                    continue;
                }
                if !writable {
                    l.err.format_into(
                        "'{}': an absolute address in read-only section {},{}",
                        l.paths[f.path as usize].as_str(),
                        l.sn.spell(os.segname),
                        l.sn.spell(os.sect),
                    );
                    return false;
                }
                if (p_addr & 3) != 0 {
                    l.err.format_into(
                        "'{}': a pointer at an address not a multiple of 4",
                        l.paths[f.path as usize].as_str(),
                    );
                    return false;
                }
                lu::p64(img, p, 0);
                pointer(l, p_addr, v, g, stored as i64);
                continue;
            }
            let insn = lu::r32(img.as_slice(), p);
            if ty == R_BRANCH26 {
                let t = if g != NONE {
                    l.osecs[l.o_stubs as usize].addr + 12 * l.gs[g as usize].stub as u64;
                } else {
                    target;
                }.wrapping_add(addend as u64);
                let d = t.wrapping_sub(p_addr) as i64;
                if d < -(1i64 << 27) || d >= 1i64 << 27 {
                    l.err.format_into("'{}': a branch beyond 128 MiB", l.paths[f.path as usize].as_str());
                    return false;
                }
                lu::p32(img, p, insn & 0xFC000000 | (d >> 2) as u32 & 0x3FFFFFF);
            } else if ty == R_PAGE21 || ty == R_GOT_LOAD_PAGE21 || ty == R_TLVP_LOAD_PAGE21 {
                let t = if ty == R_GOT_LOAD_PAGE21 {
                    got_addr(l, f, symnum);
                } else {
                    target.wrapping_add(addend as u64);
                };
                let d = (t & ~0xFFFu64).wrapping_sub(p_addr & ~0xFFFu64) as i64 >> 12;
                if d < -(1i64 << 20) || d >= 1i64 << 20 {
                    l.err.format_into("'{}': a page reference beyond 4 GiB", l.paths[f.path as usize].as_str());
                    return false;
                }
                let imm = d as u32;
                lu::p32(img, p, insn & 0x9F00001F | (imm & 3) << 29 | (imm >> 2 & 0x7FFFF) << 5);
            } else if ty == R_PAGEOFF12 || ty == R_GOT_LOAD_PAGEOFF12 {
                let t = if ty == R_GOT_LOAD_PAGEOFF12 {
                    got_addr(l, f, symnum);
                } else {
                    target.wrapping_add(addend as u64);
                };
                let lo = (t & 0xFFF) as u32;
                let mut sh: u32 = 0;
                if (insn & 0x3B000000) == 0x39000000 {
                    sh = insn >> 30;
                    if (insn & 0x04800000) == 0x04800000 {
                        sh = 4;
                    }
                }
                if (lo & (1u32 << sh) - 1) != 0 {
                    l.err.format_into("'{}': a misaligned page offset", l.paths[f.path as usize].as_str());
                    return false;
                }
                lu::p32(img, p, insn & 0xFFC003FF | lo >> sh << 10);
            } else if ty == R_TLVP_LOAD_PAGEOFF12 {
                // The descriptor is the image's own: the load of its address becomes an add.
                let lo = (target.wrapping_add(addend as u64) & 0xFFF) as u32;
                lu::p32(img, p, 0x91000000 | lo << 10 | (insn >> 5 & 31) << 5 | insn & 31);
            } else if ty == R_POINTER_TO_GOT && pcrel && len == 2 {
                let d = got_addr(l, f, symnum).wrapping_sub(p_addr);
                lu::p32(img, p, d as u32);
            } else {
                l.err.format_into("'{}': relocation type {} is not supported", l.paths[f.path as usize].as_str(), ty);
                return false;
            }
            addend = 0;
        }
    }
    return true;
}

// The address of the GOT slot of symbol `symnum` of file `f`.
fn got_addr(l: &L, f: IFile, symnum: u32) u64 {
    let y = l.syms[(f.sym0 + symnum) as usize];
    let g = gof(l, y);
    return l.osecs[l.o_got as usize].addr + 8 * l.gs[g as usize].got as u64;
}

// The image address of object address `v` in section `sect` (1-based) of file `f`.
fn section_relative(l: &L, f: IFile, sect: u32, v: u64) u64 {
    let s = l.secs[(f.sec0 + sect - 1) as usize];
    return (l.osecs[s.out as usize].addr + s.at).wrapping_add(v.wrapping_sub(s.addr));
}

// The stubs, the GOT slots and the unwind table.
fn write_synthetic(l: &mut L, img: &mut Vector<u8>) bool {
    if l.stubs.len() != 0 {
        let os = l.osecs[l.o_stubs as usize];
        let got = l.osecs[l.o_got as usize].addr;
        for i in 0..l.stubs.len() {
            let a = os.addr + 12 * i as u64;
            let p = (os.off + 12 * i as u64) as usize;
            let slot = got + 8 * l.gs[l.stubs[i] as usize].got as u64;
            let d = (slot & ~0xFFFu64).wrapping_sub(a & ~0xFFFu64) as i64 >> 12;
            let imm = d as u32;
            // adrp x16, slot@PAGE; ldr x16, [x16, slot@PAGEOFF]; br x16
            lu::p32(img, p, 0x90000010 | (imm & 3) << 29 | (imm >> 2 & 0x7FFFF) << 5);
            lu::p32(img, p + 4, 0xF9400210 | ((slot & 0xFFF) >> 3) as u32 << 10);
            lu::p32(img, p + 8, 0xD61F0200);
        }
    }
    if l.got.len() != 0 {
        let os = l.osecs[l.o_got as usize];
        for i in 0..l.got.len() {
            let g = l.got[i];
            let a = os.addr + 8 * i as u64;
            if l.gs[g as usize].kind == G_DYLIB {
                pointer(l, a, 0, g, 0);
            } else {
                let v = g_addr(l, g);
                pointer(l, a, v, NONE, 0);
            }
        }
    }
    return write_unwind(l, img);
}

// ---- unwind information ---------------------------------------------------------------------------------

// Whether input section `s` holds code.
fn code(s: ISec) bool {
    return (s.flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)) != 0;
}

// The defining input symbol of symbol `k` (itself when defined, else the global's definition); NONE
// when no object defines it.
fn defining(l: &L, k: u32) u32 {
    let y = l.syms[k as usize];
    if (y.ty & N_TYPE) == N_SECT {
        return k;
    }
    let g = gof(l, y);
    if g == NONE || l.gs[g as usize].kind != G_DEF {
        return NONE;
    }
    return l.gs[g as usize].sym;
}

// The compact unwind ranges: each object's `__LD,__compact_unwind` entries, plus encoding 0 at each
// function start no entry covers (assembly without unwind rules) and at the stubs, so no address takes
// an earlier function's rules. Their distinct encodings into `unw_enc`.
fn collect_unwind(l: &mut L, b: []u8) bool {
    // Each entry's function, as (input section << 40 | object address), and its length.
    let mut keys = Vector::<u64>::new();
    let mut lens = Vector::<u64>::new();
    for s in 0..l.secs.len() {
        let sc = l.secs[s];
        if l.sn.spell(sc.seg) != "__LD" || l.sn.spell(sc.sect) != "__compact_unwind" {
            continue;
        }
        let f = l.files[sc.file as usize];
        for r in 0..sc.nreloc as usize {
            let w0 = lu::r32(b, sc.reloff + 8 * r);
            let w1 = lu::r32(b, sc.reloff + 8 * r + 4);
            let off = w0 as usize;
            if off % 32 != 0 {
                l.err.format_into(
                    "'{}': compact unwind with a personality or language data",
                    l.paths[f.path as usize].as_str(),
                );
                return false;
            }
            let e = sc.off + off;
            let stored = lu::r64(b, e);
            let mut sec: u32 = NONE;
            let mut v: u64 = stored;
            if (w1 >> 27 & 1) != 0 {
                let k = defining(l, f.sym0 + (w1 & 0xFFFFFF));
                if k != NONE {
                    let y = l.syms[k as usize];
                    let yf = l.files[y.file as usize];
                    sec = yf.sec0 + y.sect as u32 - 1;
                    v = y.value + stored;
                }
            } else {
                sec = f.sec0 + (w1 & 0xFFFFFF) - 1;
            }
            if sec == NONE || l.secs[sec as usize].out == NONE {
                continue;
            }
            let enc = lu::r32(b, e + 12);
            l.unw.push(Unw { sec: sec, v: v, enc: enc });
            keys.push(sec as u64 << 40 | v);
            lens.push(lu::r32(b, e + 8));
        }
    }
    // Function starts no entry covers: binary search the entries sorted by key.
    let mut order = Vector::<u64>::with_capacity(keys.len());
    for i in 0..keys.len() {
        order.push(keys[i]);
    }
    order.sort();
    let mut ends = Map::<u64, u64>::new();
    for i in 0..keys.len() {
        let _ = ends.insert(keys[i], keys[i] + lens[i]);
    }
    for k in 0..l.syms.len() {
        let y = l.syms[k];
        if (y.ty & N_STAB) != 0 || (y.ty & N_TYPE) != N_SECT {
            continue;
        }
        let sec = l.files[y.file as usize].sec0 + y.sect as u32 - 1;
        let sc = l.secs[sec as usize];
        if sc.out == NONE || !code(sc) {
            continue;
        }
        let key = sec as u64 << 40 | y.value;
        let mut lo: usize = 0;
        let mut hi = order.len();
        while lo < hi {
            let mid = (lo + hi) / 2;
            if order[mid] <= key {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        let covered = lo != 0 && order[lo - 1] >> 40 == sec as u64 && key < *ends.get(&order[lo - 1]).unwrap();
        if !covered {
            l.unw.push(Unw { sec: sec, v: y.value, enc: 0 });
            order.push(key);
            let _ = ends.insert(key, key + 1);
            // Keep the search order: a later symbol at the same address finds this one.
            let mut j = order.len() - 1;
            while j > 0 && order[j - 1] > order[j] {
                let t = order[j - 1];
                order[j - 1] = order[j];
                order[j] = t;
                j -= 1;
            }
        }
    }
    if l.stubs.len() != 0 {
        l.unw.push(Unw { sec: NONE, v: 0, enc: 0 });
    }
    for i in 0..l.unw.len() {
        let e = l.unw[i].enc;
        if !l.unw_enc.contains(&e) {
            l.unw_enc.push(e);
        }
    }
    return true;
}

// Compressed second-level pages when the encodings fit the common table, else regular ones.
fn compressed(l: &L) bool {
    return l.unw_enc.len() <= 127;
}

fn per_page(l: &L) usize {
    if compressed(l) {
        return 1021;
    }
    return 511;
}

// The size of `__unwind_info`: the header, the common encodings, the first-level index (a sentinel
// after the pages) and the pages.
fn unwind_size(l: &L) u64 {
    let n = l.unw.len();
    let pp = per_page(l);
    let npages = (n + pp - 1) / pp;
    let mut size = 28 + 12 * (npages as u64 + 1);
    if compressed(l) {
        size += 4 * l.unw_enc.len() as u64 + 12 * npages as u64 + 4 * n as u64;
    } else {
        size += 8 * npages as u64 + 8 * n as u64;
    }
    return size;
}

fn write_unwind(l: &mut L, img: &mut Vector<u8>) bool {
    // Image offsets of the ranges, sorted; the stubs' at the stubs.
    let n = l.unw.len();
    let mut keyed = Vector::<u64>::with_capacity(n);
    for i in 0..n {
        let u = l.unw[i];
        let a = if u.sec == NONE {
            l.osecs[l.o_stubs as usize].addr;
        } else {
            let sc = l.secs[u.sec as usize];
            l.osecs[sc.out as usize].addr + sc.at + u.v - sc.addr;
        } - l.base;
        keyed.push(a << 24 | i as u64);
    }
    keyed.sort();
    let mut end: u64 = 0;
    for q in 0..l.osecs.len() {
        let os = &l.osecs[q];
        if (os.flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)) != 0 && os.addr + os.size - l.base > end {
            end = os.addr + os.size - l.base;
        }
    }
    let os = l.osecs[l.o_unwind as usize];
    let at = os.off as usize;
    let comp = compressed(l);
    let pp = per_page(l);
    let npages = (n + pp - 1) / pp;
    let nc = if comp {
        l.unw_enc.len();
    } else {
        0usize;
    };
    let mut o = Vector::<u8>::with_capacity(os.size as usize);
    let idx = 28 + 4 * nc;
    let lsda = idx + 12 * (npages + 1);
    lu::w32(&mut o, 1);
    lu::w32(&mut o, 28);
    lu::w32(&mut o, nc as u32);
    lu::w32(&mut o, idx as u32);
    lu::w32(&mut o, 0);
    lu::w32(&mut o, idx as u32);
    lu::w32(&mut o, npages as u32 + 1);
    for i in 0..nc {
        lu::w32(&mut o, l.unw_enc[i]);
    }
    // The first-level index, its page offsets filled as the pages go.
    let mut page_at = lsda;
    for pg in 0..npages {
        let first = keyed[pg * pp] >> 24;
        lu::w32(&mut o, first as u32);
        lu::w32(&mut o, page_at as u32);
        lu::w32(&mut o, lsda as u32);
        let cnt = (n - pg * pp).min(pp);
        page_at += if comp {
            12 + 4 * cnt;
        } else {
            8 + 8 * cnt;
        };
    }
    lu::w32(&mut o, end as u32);
    lu::w32(&mut o, 0);
    lu::w32(&mut o, lsda as u32);
    for pg in 0..npages {
        let cnt = (n - pg * pp).min(pp);
        let base = keyed[pg * pp] >> 24;
        if comp {
            lu::w32(&mut o, 3);
            lu::w16(&mut o, 12);
            lu::w16(&mut o, cnt as u32);
            lu::w16(&mut o, (12 + 4 * cnt) as u32);
            lu::w16(&mut o, 0);
        } else {
            lu::w32(&mut o, 2);
            lu::w16(&mut o, 8);
            lu::w16(&mut o, cnt as u32);
        }
        for j in 0..cnt {
            let kv = keyed[pg * pp + j];
            let a = kv >> 24;
            let enc = l.unw[(kv & 0xFFFFFF) as usize].enc;
            if comp {
                let d = a - base;
                if d >= 1u64 << 24 {
                    l.err.push_str("unwind information: a page spans more than 16 MiB of code");
                    return false;
                }
                let ei = l.unw_enc.position(&enc).unwrap() as u32;
                lu::w32(&mut o, d as u32 | ei << 24);
            } else {
                lu::w32(&mut o, a as u32);
                lu::w32(&mut o, enc);
            }
        }
    }
    assert(o.len() as u64 == os.size, "macho: the unwind table's size");
    for i in 0..o.len() {
        img[at + i] = o[i];
    }
    return true;
}

fn bw32(o: &mut Vector<u8>, v: u32) {
    o.push((v >> 24) as u8);
    o.push((v >> 16 & 0xFF) as u8);
    o.push((v >> 8 & 0xFF) as u8);
    o.push((v & 0xFF) as u8);
}

fn bw64(o: &mut Vector<u8>, v: u64) {
    bw32(o, (v >> 32) as u32);
    bw32(o, v as u32);
}

// ---- chained fixups -------------------------------------------------------------------------------------

// The `LC_DYLD_CHAINED_FIXUPS` payload: the header, each segment's chain starts, the imports and their
// names. Each fixup's pointer in `img` becomes its chain entry.
fn chained_fixups(l: &mut L, img: &mut Vector<u8>) Vector<u8> {
    let mut keyed = Vector::<u64>::with_capacity(l.fixes.len());
    for i in 0..l.fixes.len() {
        keyed.push(l.fixes[i].at << 24 | i as u64);
    }
    keyed.sort();
    let mut o = Vector::<u8>::new();
    for _ in 0..28 {
        o.push(0);
    }
    while o.len() % 8 != 0 {
        o.push(0);
    }
    let starts = o.len();
    let nseg = l.segs.len();
    lu::w32(&mut o, nseg as u32);
    for _ in 0..nseg {
        lu::w32(&mut o, 0);
    }
    let mut q: usize = 0;
    for k in 0..nseg {
        let sg = &l.segs[k];
        if sg.addr < l.base {
            continue;
        }
        let so = sg.addr - l.base;
        let se = so + sg.vmsize;
        let mut first = q;
        while first < keyed.len() && keyed[first] >> 24 < so {
            first += 1;
        }
        let mut last = first;
        while last < keyed.len() && keyed[last] >> 24 < se {
            last += 1;
        }
        q = last;
        if first == last {
            continue;
        }
        while o.len() % 8 != 0 {
            o.push(0);
        }
        let rel = (o.len() - starts) as u32;
        lu::p32(&mut o, starts + 4 + 4 * k, rel);
        // The pages with file bytes: dyld's page-in linking maps that many from the file, so a count that
        // reached into the zero-filled tail would map the file's next bytes there.
        let npages = ((sg.filesize + PAGE - 1) / PAGE) as usize;
        lu::w32(&mut o, (22 + 2 * npages) as u32);
        lu::w16(&mut o, PAGE as u32);
        lu::w16(&mut o, DYLD_CHAINED_PTR_64_OFFSET);
        lu::w64(&mut o, so);
        lu::w32(&mut o, 0);
        lu::w16(&mut o, npages as u32);
        let ps = o.len();
        for _ in 0..npages {
            lu::w16(&mut o, 0xFFFF);
        }
        let mut cur = npages;
        for i in first..last {
            let at = keyed[i] >> 24;
            let fx = l.fixes[(keyed[i] & 0xFFFFFF) as usize];
            let page = ((at - so) / PAGE) as usize;
            if page != cur {
                cur = page;
                lu::p16(&mut o, ps + 2 * page, ((at - so) % PAGE) as u32);
            }
            let mut next: u64 = 0;
            if i + 1 < last {
                let na = keyed[i + 1] >> 24;
                if (na - so) / PAGE == page as u64 {
                    next = (na - at) / 4;
                }
            }
            let v = if fx.imp != NONE {
                fx.imp as u64 | next << 51 | 1u64 << 63;
            } else {
                fx.target | next << 51;
            };
            let fo = file_off(l, at);
            lu::p64(img, fo as usize, v);
        }
    }
    while o.len() % 4 != 0 {
        o.push(0);
    }
    let imports = o.len();
    let mut syms = Vector::<u8>::new();
    for i in 0..l.imps.len() {
        let im = l.imps[i];
        let ord = l.gs[(l.glob[im.name as usize] - 1) as usize].lib;
        lu::w32(
            &mut o,
            ord & 0xFF | if im.weak {
                1u32;
            } else {
                0u32;
            } << 8 | syms.len() as u32 << 9,
        );
        lu::w32(&mut o, im.addend as u32);
        let s = l.names.spell(im.name);
        for j in 0..s.len() {
            syms.push(s.byte_at(j));
        }
        syms.push(0);
    }
    let symbols = o.len();
    o.extend_from_slice(syms.as_slice());
    while o.len() % 8 != 0 {
        o.push(0);
    }
    lu::p32(&mut o, 4, starts as u32);
    lu::p32(&mut o, 8, imports as u32);
    lu::p32(&mut o, 12, symbols as u32);
    lu::p32(&mut o, 16, l.imps.len() as u32);
    lu::p32(&mut o, 20, DYLD_CHAINED_IMPORT_ADDEND);
    return o;
}

// The file offset of image offset `at` (in a segment with file bytes).
fn file_off(l: &L, at: u64) u64 {
    for k in 0..l.segs.len() {
        let sg = &l.segs[k];
        if sg.addr >= l.base && at >= sg.addr - l.base && at < sg.addr - l.base + sg.vmsize {
            return sg.off + at - (sg.addr - l.base);
        }
    }
    assert(false, "macho: an image offset outside the segments");
    return 0;
}

// ---- exports trie ---------------------------------------------------------------------------------------

// A trie node: whether a name ends here (its flags and image offset), its edges `e0 .. e0 + ne` in
// `TEdge`s, and its offset in the trie.
struct TNode {
    pub term: bool,
    pub flags: u64,
    pub addr: u64,
    pub e0: u32,
    pub ne: u32,
    pub off: u32,
}

// An edge: bytes `a .. b` of name `name` (index into the sorted names), to node `to`.
struct TEdge {
    pub name: u32,
    pub a: u32,
    pub b: u32,
    pub to: u32,
}

extend TNode as Copy {}
extend TEdge as Copy {}

// The exports trie of `names` (sorted, distinct) with their flags and image offsets.
fn exports_trie(l: &L, names: &Vector<u32>, flags: &Vector<u64>, addrs: &Vector<u64>) Vector<u8> {
    let mut nodes = Vector::<TNode>::new();
    let mut edges = Vector::<TEdge>::new();
    nodes.push(TNode { term: false, flags: 0, addr: 0, e0: 0, ne: 0, off: 0 });
    if names.len() != 0 {
        // Build breadth-first: each work item is a node and the names under it sharing `depth` bytes.
        let mut work = Vector::<(u32, u32, u32, u32)>::new(); // node, lo, hi, depth
        work.push((0u32, 0u32, names.len() as u32, 0u32));
        let mut w: usize = 0;
        while w < work.len() {
            let (node, lo0, hi, depth) = work[w];
            w += 1;
            let mut lo = lo0;
            let d = depth as usize;
            if l.names.spell(names[lo as usize]).len() == d {
                let nd = nodes.index_mut(node as usize);
                nd.term = true;
                nd.flags = flags[lo as usize];
                nd.addr = addrs[lo as usize];
                lo += 1;
            }
            let e0 = edges.len() as u32;
            let mut i = lo;
            while i < hi {
                let si = l.names.spell(names[i as usize]);
                let c = si.byte_at(d);
                let mut j = i + 1;
                while j < hi && l.names.spell(names[j as usize]).byte_at(d) == c {
                    j += 1;
                }
                // The group's common prefix: the first and last name's, as the names are sorted.
                let sl = l.names.spell(names[(j - 1) as usize]);
                let mut cp = d + 1;
                while cp < si.len() && cp < sl.len() && si.byte_at(cp) == sl.byte_at(cp) {
                    cp += 1;
                }
                let child = nodes.len() as u32;
                nodes.push(TNode { term: false, flags: 0, addr: 0, e0: 0, ne: 0, off: 0 });
                edges.push(TEdge { name: i, a: depth, b: cp as u32, to: child });
                work.push((child, i, j, cp as u32));
                i = j;
            }
            let nd = nodes.index_mut(node as usize);
            nd.e0 = e0;
            nd.ne = edges.len() as u32 - e0;
        }
    }
    // Offsets: a node's size depends on its children's offsets; iterate to a fixed point. Offsets only
    // grow, so it ends.
    let mut changed = true;
    while changed {
        changed = false;
        let mut off: u32 = 0;
        for i in 0..nodes.len() {
            if nodes[i].off != off {
                nodes.index_mut(i).off = off;
                changed = true;
            }
            off += node_size(l, names, &nodes, &edges, i) as u32;
        }
    }
    let mut o = Vector::<u8>::new();
    for i in 0..nodes.len() {
        let nd = nodes[i];
        if nd.term {
            let ts = lu::uleb_len(nd.flags) + lu::uleb_len(nd.addr);
            lu::uleb(&mut o, ts as u64);
            lu::uleb(&mut o, nd.flags);
            lu::uleb(&mut o, nd.addr);
        } else {
            o.push(0);
        }
        o.push(nd.ne as u8);
        for k in nd.e0..nd.e0 + nd.ne {
            let e = edges[k as usize];
            let s = l.names.spell(names[e.name as usize]);
            for c in e.a..e.b {
                o.push(s.byte_at(c as usize));
            }
            o.push(0);
            lu::uleb(&mut o, nodes[e.to as usize].off);
        }
    }
    while o.len() % 8 != 0 {
        o.push(0);
    }
    return o;
}

fn node_size(l: &L, names: &Vector<u32>, nodes: &Vector<TNode>, edges: &Vector<TEdge>, i: usize) usize {
    let nd = nodes[i];
    let mut n: usize = 1;
    if nd.term {
        let ts = lu::uleb_len(nd.flags) + lu::uleb_len(nd.addr);
        n = lu::uleb_len(ts as u64) + ts;
    }
    n += 1;
    for k in nd.e0..nd.e0 + nd.ne {
        let e = edges[k as usize];
        n += (e.b - e.a) as usize + 1 + lu::uleb_len(nodes[e.to as usize].off);
    }
    let _ = names;
    let _ = l;
    return n;
}

// ---- __LINKEDIT and the header --------------------------------------------------------------------------

// An output symbol table entry.
struct OSym {
    pub name: u32, // offset in the string table
    pub ty: u8,
    pub sect: u8,
    pub desc: u16,
    pub value: u64,
}

extend OSym as Copy {}

// The output section number (1-based) of input symbol `k`'s section.
fn out_sect(l: &L, k: u32) u8 {
    let y = l.syms[k as usize];
    let s = l.secs[(l.files[y.file as usize].sec0 + y.sect as u32 - 1) as usize];
    return (s.out + 1) as u8;
}

// Whether input symbol `k` is defined in a section the image keeps.
fn kept(l: &L, k: u32) bool {
    let y = l.syms[k as usize];
    if (y.ty & N_TYPE) != N_SECT {
        return (y.ty & N_TYPE) == N_ABS;
    }
    return l.secs[(l.files[y.file as usize].sec0 + y.sect as u32 - 1) as usize].out != NONE;
}

// The compile unit's directory and name in the DWARF of file `f` (`DW_AT_comp_dir`, `DW_AT_name`, as
// inline strings or `.debug_str` offsets); empty when not found.
fn cu_names<'a>(l: &L, b: Slice<'a, u8>, f: IFile, dir: &mut str<'a>, name: &mut str<'a>) {
    let mut info = NONE;
    let mut abbrev = NONE;
    let mut strs = NONE;
    for s in f.sec0..f.sec0 + f.nsec {
        let sect = l.sn.spell(l.secs[s as usize].sect);
        if sect == "__debug_info" {
            info = s;
        } else if sect == "__debug_abbrev" {
            abbrev = s;
        } else if sect == "__debug_str" {
            strs = s;
        }
    }
    if info == NONE || abbrev == NONE {
        return;
    }
    let si = l.secs[info as usize];
    let sa = l.secs[abbrev as usize];
    let ib = b[si.off..si.off + si.size as usize];
    let ab = b[sa.off..sa.off + sa.size as usize];
    if ib.len() < 11 || lu::r16(ib, 4) > 4 {
        return;
    }
    let mut p: usize = 11;
    let code = lu::read_uleb(ib, &mut p);
    // The abbreviation: its code, tag, children flag, then (attribute, form) pairs.
    let mut q: usize = lu::r32(ib, 6) as usize;
    let mut found = false;
    while q < ab.len() && !found {
        let c = lu::read_uleb(ab, &mut q);
        if c == 0 {
            return;
        }
        let _tag = lu::read_uleb(ab, &mut q);
        q += 1;
        if c == code {
            found = true;
        } else {
            // Skip its attribute pairs.
            loop {
                let at = lu::read_uleb(ab, &mut q);
                let fo = lu::read_uleb(ab, &mut q);
                if at == 0 && fo == 0 || q >= ab.len() {
                    break;
                }
            }
        }
    }
    if !found {
        return;
    }
    // Each step reads one attribute; the pair (0, 0) ends them.
    while q < ab.len() && p < ib.len() {
        let at = lu::read_uleb(ab, &mut q);
        let fo = lu::read_uleb(ab, &mut q);
        if at == 0 && fo == 0 {
            return;
        }
        let mut v = "";
        let mut is_str = false;
        if fo == 0x08 {
            v = lu::cstr(ib, p);
            p += v.len() + 1;
            is_str = true;
        } else if fo == 0x0E {
            let o = lu::r32(ib, p) as usize;
            p += 4;
            if strs != NONE {
                let ss = l.secs[strs as usize];
                v = lu::cstr(b[ss.off..ss.off + ss.size as usize], o);
                is_str = true;
            }
        } else if fo == 0x01 || fo == 0x07 {
            p += 8;
        } else if fo == 0x0B || fo == 0x0C {
            p += 1;
        } else if fo == 0x05 {
            p += 2;
        } else if fo == 0x06 || fo == 0x17 || fo == 0x10 {
            p += 4;
        } else if fo == 0x0F || fo == 0x0D {
            let _ = lu::read_uleb(ib, &mut p);
        } else if fo != 0x19 {
            return;
        }
        if is_str && at == 0x03 {
            *name = v;
        } else if is_str && at == 0x1B {
            *dir = v;
        }
    }
}

// Build `__LINKEDIT`, write the header and load commands, then the UUID and the signature.
fn finish(l: &mut L, o: &Opts, b: []u8, img: &mut Vector<u8>) {
    let fixups = chained_fixups(l, img);
    // The symbol table: the debug map and the local symbols, the exported ones, the imports.
    let mut st = Vector::<u8>::new();
    st.push(b' ');
    st.push(0);
    let mut locs = Vector::<OSym>::new();
    let mut exts = Vector::<OSym>::new();
    let mut unds = Vector::<OSym>::new();
    if !o.strip {
        for fi in 0..l.files.len() {
            let f = l.files[fi];
            if f.debug {
                debug_map(l, b, f, &mut st, &mut locs);
            }
        }
        for k in 0..l.syms.len() {
            let y = l.syms[k];
            if (y.ty & N_STAB) != 0 || (y.ty & N_TYPE) != N_SECT || !kept(l, k as u32) {
                continue;
            }
            if (y.ty & N_EXT) != 0 && (y.ty & N_PEXT) == 0 {
                continue;
            }
            let s = l.names.spell(y.name);
            if s.len() == 0 || s.starts_with("L") || s.starts_with("l") {
                continue;
            }
            locs.push(
                OSym {
                    name: lu::put_str(&mut st, s),
                    ty: N_SECT | y.ty & N_PEXT,
                    sect: out_sect(l, k as u32),
                    desc: 0,
                    value: sym_addr(l, k as u32),
                },
            );
        }
    }
    // Exported names, sorted for the trie: a stripped executable's header alone, as `strip` leaves it.
    let mut enames = Vector::<u32>::new();
    let mut eflags = Vector::<u64>::new();
    let mut eaddrs = Vector::<u64>::new();
    let mut keyed = Vector::<(String, u32)>::new();
    let all = !o.strip || o.kind != K_EXE;
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        let exported = all && (gy.kind == G_COMMON || gy.kind == G_DEF && (l.syms[gy.sym as usize].ty & N_PEXT) == 0) || gy.kind == G_HEADER;
        if exported {
            keyed.push((String::from_str(l.names.spell(gy.name)), g as u32));
        }
    }
    keyed.sort();
    for i in 0..keyed.len() {
        let g = keyed[i].1;
        let gy = l.gs[g as usize];
        let a = g_addr(l, g);
        let abs = gy.kind == G_DEF && (l.syms[gy.sym as usize].ty & N_TYPE) == N_ABS;
        let (sect, desc) = if gy.kind == G_HEADER {
            (1u8, 0x10u16);
        } else if abs {
            (0u8, 0u16);
        } else if gy.kind == G_COMMON {
            ((l.o_common + 1) as u8, 0u16);
        } else {
            (
                out_sect(l, gy.sym),
                if gy.weak {
                    N_WEAK_DEF;
                } else {
                    0u16;
                }
            );
        };
        let ty = if abs {
            N_ABS | N_EXT;
        } else {
            N_SECT | N_EXT;
        };
        exts.push(OSym { name: lu::put_str(&mut st, l.names.spell(gy.name)), ty: ty, sect: sect, desc: desc, value: a });
        enames.push(gy.name);
        eflags.push(
            if gy.tlv {
                1u64;
            } else {
                0u64;
            } | if gy.weak {
                4u64;
            } else {
                0u64;
            },
        );
        eaddrs.push(a - l.base);
    }
    let mut undix = Vector::<u32>::new(); // per `gs` index: its symbol table index (imports only)
    undix.resize_default(l.gs.len());
    for g in 0..l.gs.len() {
        let gy = l.gs[g];
        if gy.kind == G_DYLIB {
            undix[g] = (locs.len() + exts.len() + unds.len()) as u32;
            unds.push(
                OSym {
                    name: lu::put_str(&mut st, l.names.spell(gy.name)),
                    ty: N_EXT,
                    sect: 0,
                    desc: (gy.lib << 8) as u16,
                    value: 0,
                },
            );
        }
    }
    let trie = exports_trie(l, &enames, &eflags, &eaddrs);
    // Function starts: every function symbol's address, ascending.
    let mut starts = Vector::<u64>::new();
    for k in 0..l.syms.len() {
        let y = l.syms[k];
        if (y.ty & N_STAB) != 0 || (y.ty & N_TYPE) != N_SECT || !kept(l, k as u32) {
            continue;
        }
        let sc = l.secs[(l.files[y.file as usize].sec0 + y.sect as u32 - 1) as usize];
        if code(sc) {
            starts.push(sym_addr(l, k as u32));
        }
    }
    starts.sort();
    let mut fstarts = Vector::<u8>::new();
    let text0 = l.segs[if l.kind == K_EXE {
        1usize;
    } else {
        0usize;
    }].addr;
    let mut prev = text0;
    for i in 0..starts.len() {
        if i != 0 && starts[i] == starts[i - 1] {
            continue;
        }
        lu::uleb(&mut fstarts, starts[i] - prev);
        prev = starts[i];
    }
    fstarts.push(0);
    while fstarts.len() % 8 != 0 {
        fstarts.push(0);
    }
    // The indirect symbols: one per stub, then one per GOT slot.
    let mut ind = Vector::<u8>::new();
    for i in 0..l.stubs.len() {
        lu::w32(&mut ind, undix[l.stubs[i] as usize]);
    }
    for i in 0..l.got.len() {
        let g = l.got[i];
        lu::w32(
            &mut ind,
            if l.gs[g as usize].kind == G_DYLIB {
                undix[g as usize];
            } else {
                0x80000000u32;
            },
        );
    }
    while st.len() % 8 != 0 {
        st.push(0);
    }
    // __LINKEDIT: fixups, trie, function starts, symbols, indirect symbols, strings, then the signature.
    let le = l.segs.len() - 1;
    let le_off = l.segs[le].off;
    let fix_off = le_off;
    let trie_off = fix_off + fixups.len() as u64;
    let fs_off = trie_off + trie.len() as u64;
    let sym_off = fs_off + fstarts.len() as u64;
    let nsyms = locs.len() + exts.len() + unds.len();
    let ind_off = sym_off + 16 * nsyms as u64;
    let str_off = lu::align_up(ind_off + ind.len() as u64, 8);
    let sig_off = lu::align_up(str_off + st.len() as u64, 16);
    let ident = basename(o.out.as_str());
    let npages = (sig_off + 4095) / 4096;
    let sig_size = 20 + 88 + ident.len() as u64 + 1 + 32 * npages;
    let le_size = sig_off + sig_size - le_off;
    img.extend_from_slice(fixups.as_slice());
    img.extend_from_slice(trie.as_slice());
    img.extend_from_slice(fstarts.as_slice());
    let mut tab = Vector::<u8>::with_capacity(16 * nsyms);
    for grp in 0..3 {
        let v = if grp == 0 {
            &locs;
        } else if grp == 1 {
            &exts;
        } else {
            &unds;
        };
        for i in 0..v.len() {
            let e = v[i];
            lu::w32(&mut tab, e.name);
            tab.push(e.ty);
            tab.push(e.sect);
            lu::w16(&mut tab, e.desc);
            lu::w64(&mut tab, e.value);
        }
    }
    img.extend_from_slice(tab.as_slice());
    img.extend_from_slice(ind.as_slice());
    while img.len() as u64 < str_off {
        img.push(0);
    }
    img.extend_from_slice(st.as_slice());
    while img.len() as u64 < sig_off {
        img.push(0);
    }
    let lsg = l.segs.index_mut(le);
    lsg.filesize = le_size;
    lsg.vmsize = lu::align_up(le_size, PAGE);
    // The header and load commands.
    let mut h = Vector::<u8>::new();
    let ncmds_at: usize = 16;
    lu::w32(&mut h, MH_MAGIC_64);
    lu::w32(&mut h, CPU_ARM64);
    lu::w32(&mut h, 0);
    lu::w32(
        &mut h,
        if l.kind == K_EXE {
            MH_EXECUTE;
        } else {
            MH_DYLIB;
        },
    );
    lu::w32(&mut h, 0);
    lu::w32(&mut h, 0);
    let mut flags = MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL;
    if l.kind == K_EXE {
        flags |= MH_PIE;
    } else {
        flags |= MH_NO_REEXPORTED_DYLIBS;
    }
    if l.tlv {
        flags |= MH_HAS_TLV_DESCRIPTORS;
    }
    lu::w32(&mut h, flags);
    lu::w32(&mut h, 0);
    let mut ncmds: u32 = 0;
    for k in 0..l.segs.len() {
        let sg = &l.segs[k];
        lu::w32(&mut h, LC_SEGMENT_64);
        lu::w32(&mut h, 72 + 80 * sg.n);
        name16(&mut h, sg.name.as_str());
        lu::w64(&mut h, sg.addr);
        lu::w64(&mut h, sg.vmsize);
        lu::w64(&mut h, sg.off);
        lu::w64(&mut h, sg.filesize);
        lu::w32(
            &mut h,
            if sg.name.as_str() == "__PAGEZERO" {
                0u32;
            } else {
                sg.prot;
            },
        );
        lu::w32(&mut h, sg.prot);
        lu::w32(&mut h, sg.n);
        lu::w32(&mut h, sg.flags);
        for q in sg.first..sg.first + sg.n {
            let os = &l.osecs[q as usize];
            name16(&mut h, l.sn.spell(os.sect));
            name16(&mut h, l.sn.spell(os.segname));
            lu::w64(&mut h, os.addr);
            lu::w64(&mut h, os.size);
            lu::w32(&mut h, os.off as u32);
            lu::w32(&mut h, os.align);
            lu::w32(&mut h, 0);
            lu::w32(&mut h, 0);
            lu::w32(&mut h, os.flags);
            let (r1, r2) = if q == l.o_stubs {
                (0u32, 12u32);
            } else if q == l.o_got {
                (l.stubs.len() as u32, 0u32);
            } else {
                (0u32, 0u32);
            };
            lu::w32(&mut h, r1);
            lu::w32(&mut h, r2);
            lu::w32(&mut h, 0);
        }
        ncmds += 1;
    }
    linkedit_cmd(&mut h, LC_DYLD_CHAINED_FIXUPS, fix_off, fixups.len() as u64);
    linkedit_cmd(&mut h, LC_DYLD_EXPORTS_TRIE, trie_off, trie.len() as u64);
    lu::w32(&mut h, LC_SYMTAB);
    lu::w32(&mut h, 24);
    lu::w32(&mut h, sym_off as u32);
    lu::w32(&mut h, nsyms as u32);
    lu::w32(&mut h, str_off as u32);
    lu::w32(&mut h, st.len() as u32);
    lu::w32(&mut h, LC_DYSYMTAB);
    lu::w32(&mut h, 80);
    lu::w32(&mut h, 0);
    lu::w32(&mut h, locs.len() as u32);
    lu::w32(&mut h, locs.len() as u32);
    lu::w32(&mut h, exts.len() as u32);
    lu::w32(&mut h, (locs.len() + exts.len()) as u32);
    lu::w32(&mut h, unds.len() as u32);
    for _ in 0..6 {
        lu::w32(&mut h, 0);
    }
    lu::w32(&mut h, ind_off as u32);
    lu::w32(&mut h, (ind.len() / 4) as u32);
    for _ in 0..4 {
        lu::w32(&mut h, 0);
    }
    ncmds += 4;
    if l.kind == K_EXE {
        lu::w32(&mut h, LC_LOAD_DYLINKER);
        lu::w32(&mut h, 32);
        lu::w32(&mut h, 12);
        put_padded(&mut h, "/usr/lib/dyld", 20);
    } else {
        dylib_cmd(&mut h, LC_ID_DYLIB, l.install.as_str(), 0x10000, 0x10000);
    }
    ncmds += 1;
    let uuid_at = h.len() + 8;
    lu::w32(&mut h, LC_UUID);
    lu::w32(&mut h, 24);
    for _ in 0..16 {
        h.push(0);
    }
    lu::w32(&mut h, LC_BUILD_VERSION);
    lu::w32(&mut h, 24);
    lu::w32(&mut h, 1);
    lu::w32(&mut h, 0x000C0000);
    lu::w32(&mut h, 0x000C0000);
    lu::w32(&mut h, 0);
    ncmds += 2;
    if l.kind == K_EXE {
        let main = l.names.find("_main");
        let mut entry: u64 = 0;
        if main >= 0 && main as usize < l.glob.len() && l.glob[main as usize] != 0 {
            entry = file_off(l, g_addr(l, l.glob[main as usize] - 1) - l.base);
        }
        lu::w32(&mut h, LC_MAIN);
        lu::w32(&mut h, 24);
        lu::w64(&mut h, entry);
        lu::w64(&mut h, 0);
        ncmds += 1;
    }
    for i in 0..l.libs.len() {
        dylib_cmd(&mut h, LC_LOAD_DYLIB, l.libs[i].install.as_str(), l.libs[i].cur, l.libs[i].compat);
        ncmds += 1;
    }
    linkedit_cmd(&mut h, LC_FUNCTION_STARTS, fs_off, fstarts.len() as u64);
    linkedit_cmd(&mut h, LC_CODE_SIGNATURE, sig_off, sig_size);
    ncmds += 2;
    let sizeofcmds = (h.len() - 32) as u32;
    assert(sizeofcmds as u64 == cmds_size(l), "macho: the load commands' size");
    lu::p32(&mut h, ncmds_at, ncmds);
    lu::p32(&mut h, ncmds_at + 4, sizeofcmds);
    for i in 0..h.len() {
        img[i] = h[i];
    }
    sign(l, img, ident, sig_off, uuid_at, o.jobs);
}

// The SHA-256 of each 4 KiB page of `img` below `end` into `out`: in this thread for one job, else in
// parallel.
fn page_hashes(img: &Vector<u8>, end: usize, jobs: u32, out: &mut Vector<u8>) {
    out.resize_default(32 * ((end + 4095) / 4096));
    if jobs == 1 {
        let mut dg = [0u8; 32];
        for pg in 0..out.len() / 32 {
            let a = 4096 * pg;
            sha::digest(img.index_range(a..(a + 4096).min(end)), &mut dg);
            for i in 0..32usize {
                out[32 * pg + i] = unsafe dg[i];
            }
        }
        return;
    }
    let base = out.as_ptr() as usize;
    // 64 pages (256 KiB of input) per task.
    parallel::chunks_mut(
        out.index_range_mut(0..out.len()),
        32 * 64,
        |c: []mut u8| {
            let pg0 = (c.as_ptr() as usize - base) / 32;
            let mut dg = [0u8; 32];
            for k in 0..c.len() / 32 {
                let a = 4096 * (pg0 + k);
                sha::digest(img.index_range(a..(a + 4096).min(end)), &mut dg);
                for i in 0..32usize {
                    c[32 * k + i] = unsafe dg[i];
                }
            }
        },
    );
}

// The debug map of file `f`: its source and object names, then each of its functions' address and size.
fn debug_map(l: &L, b: []u8, f: IFile, st: &mut Vector<u8>, locs: &mut Vector<OSym>) {
    let mut dir: str = "";
    let mut name: str = "";
    cu_names(l, b, f, &mut dir, &mut name);
    if name.len() == 0 {
        name = basename(l.paths[f.path as usize].as_str());
    }
    let mut d = String::from_str(dir);
    if d.len() != 0 && !d.as_str().ends_with("/") {
        d.push_byte(b'/');
    }
    locs.push(OSym { name: lu::put_str(st, d.as_str()), ty: N_SO, sect: 0, desc: 0, value: 0 });
    locs.push(OSym { name: lu::put_str(st, name), ty: N_SO, sect: 0, desc: 0, value: 0 });
    locs.push(OSym { name: lu::put_str(st, l.paths[f.path as usize].as_str()), ty: N_OSO, sect: 0, desc: 1, value: 0 });
    // The functions sorted by address; each one's size reaches the next one or its section's end.
    let mut fk = Vector::<u64>::new();
    for k in f.sym0..f.sym0 + f.nsym {
        let y = l.syms[k as usize];
        if (y.ty & N_STAB) != 0 || (y.ty & N_TYPE) != N_SECT || !kept(l, k) {
            continue;
        }
        let sc = l.secs[(f.sec0 + y.sect as u32 - 1) as usize];
        if code(sc) {
            fk.push(sym_addr(l, k) << 24 | (k - f.sym0) as u64);
        }
    }
    fk.sort();
    for i in 0..fk.len() {
        let k = f.sym0 + (fk[i] & 0xFFFFFF) as u32;
        let a = fk[i] >> 24;
        let y = l.syms[k as usize];
        let sc = l.secs[(f.sec0 + y.sect as u32 - 1) as usize];
        let send = l.osecs[sc.out as usize].addr + sc.at + sc.size;
        let mut e = send;
        if i + 1 < fk.len() && fk[i + 1] >> 24 < send {
            e = fk[i + 1] >> 24;
        }
        if e == a {
            continue;
        }
        let sect = out_sect(l, k);
        locs.push(OSym { name: 1, ty: N_BNSYM, sect: sect, desc: 0, value: a });
        locs.push(OSym { name: lu::put_str(st, l.names.spell(y.name)), ty: N_FUN, sect: sect, desc: 0, value: a });
        locs.push(OSym { name: 1, ty: N_FUN, sect: 0, desc: 0, value: e - a });
        locs.push(OSym { name: 1, ty: N_ENSYM, sect: sect, desc: 0, value: e - a });
    }
    locs.push(OSym { name: 1, ty: N_SO, sect: 1, desc: 0, value: 0 });
}

fn basename(p: str) str {
    let mut i = p.len();
    while i > 0 && p.byte_at(i - 1) != b'/' {
        i -= 1;
    }
    return p.slice(i, p.len());
}

fn name16(h: &mut Vector<u8>, s: str) {
    for i in 0..16usize {
        h.push(
            if i < s.len() {
                s.byte_at(i);
            } else {
                0u8;
            },
        );
    }
}

fn put_padded(h: &mut Vector<u8>, s: str, n: usize) {
    for i in 0..n {
        h.push(
            if i < s.len() {
                s.byte_at(i);
            } else {
                0u8;
            },
        );
    }
}

fn linkedit_cmd(h: &mut Vector<u8>, cmd: u32, off: u64, size: u64) {
    lu::w32(h, cmd);
    lu::w32(h, 16);
    lu::w32(h, off as u32);
    lu::w32(h, size as u32);
}

fn dylib_cmd(h: &mut Vector<u8>, cmd: u32, name: str, cur: u32, compat: u32) {
    let size = lu::align_up(24 + name.len() as u64 + 1, 8) as u32;
    lu::w32(h, cmd);
    lu::w32(h, size);
    lu::w32(h, 24);
    lu::w32(h, 2);
    lu::w32(h, cur);
    lu::w32(h, compat);
    put_padded(h, name, (size - 24) as usize);
}

// The ad-hoc linker signature at `sig_off`: one code directory hashing each 4 KiB page before it.
// The UUID (at `uuid_at`, zero until now) is a hash of the page hashes, so the image is hashed once:
// then the page that holds it is hashed again.
fn sign(l: &L, img: &mut Vector<u8>, ident: str, sig_off: u64, uuid_at: usize, jobs: u32) {
    let npages = (sig_off + 4095) / 4096;
    let id_off: u32 = 88;
    let hash_off = id_off + ident.len() as u32 + 1;
    let cd_len = hash_off + 32 * npages as u32;
    let mut s = Vector::<u8>::new();
    bw32(&mut s, 0xFADE0CC0);
    bw32(&mut s, 20 + cd_len);
    bw32(&mut s, 1);
    bw32(&mut s, 0);
    bw32(&mut s, 20);
    bw32(&mut s, 0xFADE0C02);
    bw32(&mut s, cd_len);
    bw32(&mut s, 0x20400);
    bw32(&mut s, 0x20002); // ad-hoc, linker-signed
    bw32(&mut s, hash_off);
    bw32(&mut s, id_off);
    bw32(&mut s, 0);
    bw32(&mut s, npages as u32);
    bw32(&mut s, sig_off as u32);
    s.push(32);
    s.push(2); // SHA-256
    s.push(0);
    s.push(12); // 4 KiB pages
    bw32(&mut s, 0);
    bw32(&mut s, 0);
    bw32(&mut s, 0);
    bw32(&mut s, 0);
    bw64(&mut s, 0);
    // The executable segment: __TEXT.
    let text = &l.segs[if l.kind == K_EXE {
        1usize;
    } else {
        0usize;
    }];
    bw64(&mut s, text.off);
    bw64(&mut s, text.filesize);
    bw64(
        &mut s,
        if l.kind == K_EXE {
            1u64;
        } else {
            0u64;
        },
    );
    for i in 0..ident.len() {
        s.push(ident.byte_at(i));
    }
    s.push(0);
    let end = sig_off as usize;
    let mut hashes = Vector::<u8>::new();
    page_hashes(img, end, jobs, &mut hashes);
    let mut dg = [0u8; 32];
    sha::digest(hashes.as_slice(), &mut dg);
    for i in 0..16usize {
        img[uuid_at + i] = unsafe dg[i];
    }
    img[uuid_at + 6] = img[uuid_at + 6] & 0x0F | 0x40;
    img[uuid_at + 8] = img[uuid_at + 8] & 0x3F | 0x80;
    let pg = uuid_at / 4096;
    for q in pg..(uuid_at + 15) / 4096 + 1 {
        sha::digest(img.index_range(4096 * q..(4096 * q + 4096).min(end)), &mut dg);
        for i in 0..32usize {
            hashes[32 * q + i] = unsafe dg[i];
        }
    }
    s.extend_from_slice(hashes.as_slice());
    img.extend_from_slice(s.as_slice());
}
