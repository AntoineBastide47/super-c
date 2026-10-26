// The archiver: objects into a static library, with the symbol index a linker reads to find the member
// that defines a symbol. Mach-O archives take the BSD layout (`#1/<n>` names, a sorted `__.SYMDEF`);
// the others the System V layout every other linker reads (a `/` index, a `//` table of long names).
// The output is deterministic: no times, owners or modes but the fixed ones.
import link::util as lu;
import target::native as nat;
import utils::names as nm;

/// Archive the objects `objs` (object format `fmt`, `target::native::OBJ_*`) into `out`. False with the reason in `err` when it fails.
pub fn archive(fmt: u8, out: str, objs: &Vector<String>, err: &mut String) bool {
    let mut data = Vector::<Vector<u8>>::new();
    let mut syms = Vector::<(String, u32)>::new(); // (name, member)
    for i in 0..objs.len() {
        let d = lu::read(objs[i].as_str());
        if d.is_none() {
            err.format_into("cannot read '{}'", objs[i].as_str());
            return false;
        }
        let bytes = d.unwrap();
        {
            let mut names = Vector::<str>::new();
            if !defined(fmt, bytes.as_slice(), &mut names) {
                err.format_into("'{}' is not an object of the target's format", objs[i].as_str());
                return false;
            }
            for k in 0..names.len() {
                syms.push((String::from_str(names[k]), i as u32));
            }
        }
        data.push(bytes);
    }
    let mut a = Vector::<u8>::new();
    if fmt == nat::OBJ_MACHO {
        bsd(objs, &data, &mut syms, &mut a);
    } else {
        sysv(objs, &data, &syms, &mut a);
    }
    if !lu::write(out, a.as_slice(), 0o644) {
        err.format_into("cannot write '{}'", out);
        return false;
    }
    return true;
}

/// An object member of an archive `read` found: its name and its bytes' place in the archive.
pub struct Member {
    pub name: String,
    pub at: usize,
    pub size: usize,
}

/// The object members of archive `b` (object format `fmt`) into `members`, and each external symbol a
/// member defines into `syms` as (name, member), in member order. The BSD and System V layouts with
/// their long names; the symbol indexes, the long-name table and members of another format are not
/// object members. False with the reason in `err` when `b` is no archive or is malformed.
pub fn read<'a>(
    fmt: u8,
    b: Slice<'a, u8>,
    members: &mut Vector<Member>,
    syms: &mut Vector<(str<'a>, u32)>,
    err: &mut String,
) bool {
    if b.len() < 8 || lu::cstr(b[0..8], 0) != "!<arch>\n" {
        err.push_str(
            if b.len() >= 8 && lu::cstr(b[0..8], 0) == "!<thin>\n" {
                "a thin archive";
            } else {
                "not an archive";
            },
        );
        return false;
    }
    let mut longs: usize = 0; // the `//` member's data
    let mut nlongs: usize = 0;
    let mut h: usize = 8;
    let mut names = Vector::<str<'a>>::new();
    // Each step reads one member: at least its 60-byte header.
    while h < b.len() {
        if h + 60 > b.len() || b[h + 58] != b'`' || b[h + 59] != b'\n' {
            err.format_into("a malformed member header at byte {}", h);
            return false;
        }
        let mut size: usize = 0;
        for k in 48..58usize {
            let d = b[h + k];
            if d >= b'0' && d <= b'9' {
                size = size * 10 + (d - b'0') as usize;
            } else if d != b' ' {
                err.format_into("a malformed member size at byte {}", h);
                return false;
            }
        }
        let mut at = h + 60;
        if at + size > b.len() {
            err.format_into("a member past the archive's end at byte {}", h);
            return false;
        }
        let field = b[h..h + 16];
        let mut name = String::new();
        let mut special = false;
        if field[0] == b'#' && field[1] == b'1' && field[2] == b'/' {
            // BSD: the name's length, the name first in the data.
            let mut n: usize = 0;
            for k in 3..16usize {
                let d = field[k];
                if d >= b'0' && d <= b'9' {
                    n = n * 10 + (d - b'0') as usize;
                }
            }
            if n > size {
                err.format_into("a malformed member name at byte {}", h);
                return false;
            }
            name.push_str(lu::cstr(b[at..at + n], 0));
            at += n;
            size -= n;
            special = name.as_str().starts_with("__.SYMDEF");
        } else if field[0] == b'/' {
            if field[1] >= b'0' && field[1] <= b'9' {
                // System V: an offset into the long-name table, the name ending in `/\n` (GNU) or NUL.
                let mut off: usize = 0;
                for k in 1..16usize {
                    let d = field[k];
                    if d >= b'0' && d <= b'9' {
                        off = off * 10 + (d - b'0') as usize;
                    }
                }
                if off >= nlongs {
                    err.format_into("a long member name outside the name table at byte {}", h);
                    return false;
                }
                let mut e = longs + off;
                while e < longs + nlongs && b[e] != b'\n' && b[e] != 0 {
                    e += 1;
                }
                if e > longs + off && b[e - 1] == b'/' {
                    e -= 1;
                }
                name.push_str(unsafe str::from_raw(b.as_ptr() + longs + off, e - longs - off));
            } else {
                // `/`, `/SYM64/`, `//` and other tables.
                special = true;
                if field[1] == b'/' {
                    longs = at;
                    nlongs = size;
                }
            }
        } else {
            let mut e: usize = 16;
            while e > 0 && (field[e - 1] == b' ' || field[e - 1] == b'/') {
                e -= 1;
            }
            name.push_str(unsafe str::from_raw(field.as_ptr(), e));
            special = name.as_str().starts_with("__.SYMDEF");
        }
        if !special {
            names.truncate(0);
            if defined(fmt, b[at..at + size], &mut names) {
                let m = members.len() as u32;
                for k in 0..names.len() {
                    syms.push((names[k], m));
                }
                members.push(Member { name: name, at: at, size: size });
            }
        }
        h = at + size + (at + size & 1);
    }
    return true;
}

/// The static libraries of a link, read whole, and the member that defines each of their symbols: the
/// first archive and member that defines it, as the inputs come (LLD's rule). A linker takes a member
/// when a symbol it still needs is one of them (`find`, then `take`), and reads its bytes as an object.
pub struct Archives {
    pub paths: Vector<String>,
    pub data: Vector<Vector<u8>>,
    pub members: Vector<Vector<Member>>,
    pub taken: Vector<Vector<bool>>,
    pub names: nm::Names, // the defined symbols' names
    pub defs: Vector<u64>, // per `names` id: (archive << 32 | member) + 1, 0 for none
}

extend Archives {
    pub fn new() Archives {
        return Archives {
            paths: Vector::<String>::new(),
            data: Vector::<Vector<u8>>::new(),
            members: Vector::<Vector<Member>>::new(),
            taken: Vector::<Vector<bool>>::new(),
            names: nm::Names::with_capacity(1 << 16, 1 << 10),
            defs: Vector::<u64>::new(),
        };
    }

    /// Add archive `path` (object format `fmt`). False with the reason in `err` when it cannot be read.
    pub fn add(self: &mut Self, fmt: u8, path: str, err: &mut String) bool {
        let d = lu::read(path);
        if d.is_none() {
            err.format_into("cannot read '{}'", path);
            return false;
        }
        let mut bytes = d.unwrap();
        if fmt == nat::OBJ_MACHO && !arm64_slice(&mut bytes) {
            err.format_into("'{}': a universal file without an arm64 slice", path);
            return false;
        }
        let mut ms = Vector::<Member>::new();
        // The names borrow the bytes until the archive keeps them.
        {
            let mut syms = Vector::<(str, u32)>::new();
            let mut why = String::new();
            if !read(fmt, bytes.as_slice(), &mut ms, &mut syms, &mut why) {
                err.format_into("'{}': {}", path, why.as_str());
                return false;
            }
            let a = self.paths.len() as u64;
            for k in 0..syms.len() {
                let id = self.names.intern(syms[k].0) as usize;
                if id >= self.defs.len() {
                    self.defs.resize_default(id + 1);
                }
                if self.defs[id] == 0 {
                    self.defs.set(id, (a << 32 | syms[k].1 as u64) + 1);
                }
            }
        }
        let mut t = Vector::<bool>::new();
        t.resize_default(ms.len());
        self.paths.push(String::from_str(path));
        self.data.push(bytes);
        self.members.push(ms);
        self.taken.push(t);
        return true;
    }

    /// The member that defines `name` and was not taken yet, as archive << 32 | member; None otherwise.
    pub fn find(self: &Self, name: str) Option<u64> {
        let id = self.names.find(name);
        if id < 0 || id as usize >= self.defs.len() || self.defs[id as usize] == 0 {
            return Option::<u64>::None;
        }
        let am = self.defs[id as usize] - 1;
        if self.taken[(am >> 32) as usize][(am & 0xFFFFFFFF) as usize] {
            return Option::<u64>::None;
        }
        return Option::<u64>::Some(am);
    }

    /// Mark member `am` (`find`'s value) taken.
    pub fn take(self: &mut Self, am: u64) {
        self.taken.index_mut((am >> 32) as usize).set((am & 0xFFFFFFFF) as usize, true);
    }

    /// The bytes of member `am`.
    pub fn bytes(self: &Self, am: u64) []u8 {
        let m = &self.members[(am >> 32) as usize][(am & 0xFFFFFFFF) as usize];
        return self.data[(am >> 32) as usize].index_range(m.at..m.at + m.size);
    }

    /// The name of member `am` for messages: `<archive>(<member>)`.
    pub fn name(self: &Self, am: u64) String {
        return format(
            "{}({})",
            self.paths[(am >> 32) as usize].as_str(),
            self.members[(am >> 32) as usize][(am & 0xFFFFFFFF) as usize].name.as_str(),
        );
    }
}

/// Whether archive `path` holds an object of format `fmt` (a Mach-O universal file: in its arm64 slice).
pub fn holds_objects(fmt: u8, path: str) bool {
    let d = lu::read(path);
    if d.is_none() {
        return false;
    }
    let mut b = d.unwrap();
    if fmt == nat::OBJ_MACHO && !arm64_slice(&mut b) {
        return false;
    }
    let mut ms = Vector::<Member>::new();
    let mut syms = Vector::<(str, u32)>::new();
    let mut why = String::new();
    return read(fmt, b.as_slice(), &mut ms, &mut syms, &mut why) && ms.len() != 0;
}

// A Mach-O universal file (big-endian `fat_header`, then a `fat_arch` per slice) becomes its arm64
// slice; any other file stays. False when a universal file has no arm64 slice.
fn arm64_slice(b: &mut Vector<u8>) bool {
    if b.len() < 8 || be32(b.as_slice(), 0) != 0xCAFEBABE {
        return true;
    }
    let n = be32(b.as_slice(), 4) as usize;
    for i in 0..n {
        let e = 8 + 20 * i;
        if e + 20 > b.len() {
            return false;
        }
        let off = be32(b.as_slice(), e + 8) as usize;
        let size = be32(b.as_slice(), e + 12) as usize;
        if be32(b.as_slice(), e) == 0x0100000C && off + size <= b.len() {
            let mut s = Vector::<u8>::with_capacity(size);
            s.extend_from_slice(b.as_slice()[off..off + size]);
            *b = s;
            return true;
        }
    }
    return false;
}

const fn be32(b: []u8, at: usize) u32 {
    return b[at] as u32 << 24 | b[at + 1] as u32 << 16 | b[at + 2] as u32 << 8 | b[at + 3] as u32;
}

/// Whether input `path` names a static library: `.a`, or `.lib` on Windows.
pub fn is_archive(path: str) bool {
    return path.ends_with(".a") || path.ends_with(".lib");
}

// A member header: the name field, then the fixed fields, the size, the terminator.
fn header(a: &mut Vector<u8>, name: str, size: u64) {
    field(a, name, 16);
    field(a, "0", 12);
    field(a, "0", 6);
    field(a, "0", 6);
    field(a, "644", 8);
    field(a, format("{}", size).as_str(), 10);
    a.push(b'`');
    a.push(b'\n');
}

fn field(a: &mut Vector<u8>, s: str, n: usize) {
    for i in 0..n {
        a.push(
            if i < s.len() {
                s.byte_at(i);
            } else {
                b' ';
            },
        );
    }
}

fn put_be32(a: &mut Vector<u8>, v: u32) {
    a.push((v >> 24) as u8);
    a.push((v >> 16 & 0xFF) as u8);
    a.push((v >> 8 & 0xFF) as u8);
    a.push((v & 0xFF) as u8);
}

fn base<'a>(p: str<'a>) str<'a> {
    let mut i = p.len();
    while i > 0 && p.byte_at(i - 1) != b'/' && p.byte_at(i - 1) != b'\\' {
        i -= 1;
    }
    return p.slice(i, p.len());
}

// System V: the `/` index (the member count, each symbol's member offset, big-endian, then the names),
// the `//` long names, then the members, each on an even offset.
fn sysv(objs: &Vector<String>, data: &Vector<Vector<u8>>, syms: &Vector<(String, u32)>, a: &mut Vector<u8>) {
    let mut longs = Vector::<u8>::new();
    let mut names = Vector::<String>::new();
    for i in 0..objs.len() {
        let b = base(objs[i].as_str());
        if b.len() < 16 {
            names.push(format("{}/", b));
        } else {
            names.push(format("/{}", longs.len()));
            for q in 0..b.len() {
                longs.push(b.byte_at(q));
            }
            longs.push(b'/');
            longs.push(b'\n');
        }
    }
    let mut strsz: u64 = 0;
    for k in 0..syms.len() {
        strsz += syms[k].0.len() as u64 + 1;
    }
    let idx = 4 + 4 * syms.len() as u64 + strsz;
    let mut at: u64 = 8 + 60 + lu::align_up(idx, 2);
    if longs.len() != 0 {
        at += 60 + lu::align_up(longs.len() as u64, 2);
    }
    let mut offs = Vector::<u32>::new();
    for i in 0..data.len() {
        offs.push(at as u32);
        at += 60 + lu::align_up(data.at(i).len() as u64, 2);
    }
    a.extend_from_slice([0x21u8, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E, 0x0A]); // "!<arch>\n"
    header(a, "/", idx);
    put_be32(a, syms.len() as u32);
    for k in 0..syms.len() {
        put_be32(a, offs[syms[k].1 as usize]);
    }
    for k in 0..syms.len() {
        let _ = lu::put_str(a, syms[k].0.as_str());
    }
    if a.len() % 2 != 0 {
        a.push(b'\n');
    }
    if longs.len() != 0 {
        header(a, "//", longs.len() as u64);
        a.extend_from_slice(longs.as_slice());
        if a.len() % 2 != 0 {
            a.push(b'\n');
        }
    }
    for i in 0..data.len() {
        header(a, names[i].as_str(), data.at(i).len() as u64);
        a.extend_from_slice(data.at(i).as_slice());
        if a.len() % 2 != 0 {
            a.push(b'\n');
        }
    }
}

// The name field of a BSD member: `#1/<n>`, the name's `n` bytes (zero-padded so the data starts on 8
// bytes) leading the data.
fn bsd_name_len(at: u64, name: str) u64 {
    return lu::align_up(at + 60 + name.len() as u64 + 1, 8) - at - 60;
}

// BSD: `__.SYMDEF SORTED` (the size of the ranlib entries, each a name offset and a member offset, then
// the size of the names and the names), then the members, every data on 8 bytes.
fn bsd(objs: &Vector<String>, data: &Vector<Vector<u8>>, syms: &mut Vector<(String, u32)>, a: &mut Vector<u8>) {
    syms.sort();
    let mut strs = Vector::<u8>::new();
    let mut strx = Vector::<u32>::new();
    for k in 0..syms.len() {
        strx.push(lu::put_str(&mut strs, syms[k].0.as_str()));
    }
    while strs.len() % 8 != 0 {
        strs.push(0);
    }
    let symdef = "__.SYMDEF SORTED";
    let sym_body = 4 + 8 * syms.len() as u64 + 4 + strs.len() as u64;
    let nl0 = bsd_name_len(8, symdef);
    let mut at: u64 = 8 + 60 + nl0 + sym_body;
    let mut offs = Vector::<u32>::new();
    let mut nls = Vector::<u64>::new();
    for i in 0..data.len() {
        let nl = bsd_name_len(at, base(objs[i].as_str()));
        offs.push(at as u32);
        nls.push(nl);
        at += 60 + nl + lu::align_up(data.at(i).len() as u64, 8);
    }
    a.extend_from_slice([0x21u8, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E, 0x0A]); // "!<arch>\n"
    header(a, format("#1/{}", nl0).as_str(), nl0 + sym_body);
    name_field(a, symdef, nl0);
    lu::w32(a, 8 * syms.len() as u32);
    for k in 0..syms.len() {
        lu::w32(a, strx[k]);
        lu::w32(a, offs[syms[k].1 as usize]);
    }
    lu::w32(a, strs.len() as u32);
    a.extend_from_slice(strs.as_slice());
    for i in 0..data.len() {
        let len = lu::align_up(data.at(i).len() as u64, 8);
        header(a, format("#1/{}", nls[i]).as_str(), nls[i] + len);
        name_field(a, base(objs[i].as_str()), nls[i]);
        a.extend_from_slice(data.at(i).as_slice());
        while a.len() % 8 != 0 {
            a.push(b'\n');
        }
    }
}

fn name_field(a: &mut Vector<u8>, name: str, n: u64) {
    for i in 0..n as usize {
        a.push(
            if i < name.len() {
                name.byte_at(i);
            } else {
                0u8;
            },
        );
    }
}

// The external symbols object `b` (format `fmt`) defines, into `out`; false when it is not one.
fn defined<'a>(fmt: u8, b: Slice<'a, u8>, out: &mut Vector<str<'a>>) bool {
    if fmt == nat::OBJ_MACHO {
        return macho_syms(b, out);
    }
    if fmt == nat::OBJ_ELF {
        return elf_syms(b, out);
    }
    if fmt == nat::OBJ_COFF {
        return coff_syms(b, out);
    }
    return wasm_syms(b, out);
}

fn macho_syms<'a>(b: Slice<'a, u8>, out: &mut Vector<str<'a>>) bool {
    if b.len() < 32 || lu::r32(b, 0) != 0xFEEDFACF {
        return false;
    }
    let ncmds = lu::r32(b, 16);
    let mut c: usize = 32;
    for _ in 0..ncmds {
        if lu::r32(b, c) == 0x2 {
            let so = lu::r32(b, c + 8) as usize;
            let n = lu::r32(b, c + 12) as usize;
            let st = lu::r32(b, c + 16) as usize;
            for k in 0..n {
                let e = so + 16 * k;
                let ty = b[e + 4];
                // External, not private, defined (in a section or absolute), no debug entry.
                if (ty & 0xE0) == 0 && (ty & 0x01) != 0 && (ty & 0x10) == 0 && (ty & 0x0E) != 0 {
                    out.push(lu::cstr(b, st + lu::r32(b, e) as usize));
                }
            }
        }
        c += lu::r32(b, c + 4) as usize;
    }
    return true;
}

fn elf_syms<'a>(b: Slice<'a, u8>, out: &mut Vector<str<'a>>) bool {
    if b.len() < 64 || lu::r32(b, 0) != 0x464C457F || b[4] != 2 {
        return false;
    }
    let shoff = lu::r64(b, 0x28) as usize;
    let shnum = lu::r16(b, 0x3C) as usize;
    for k in 0..shnum {
        let h = shoff + 64 * k;
        if lu::r32(b, h + 4) != 2 {
            continue;
        }
        let so = lu::r64(b, h + 24) as usize;
        let n = lu::r64(b, h + 32) as usize / 24;
        let strh = shoff + 64 * lu::r32(b, h + 40) as usize;
        let st = lu::r64(b, strh + 24) as usize;
        for i in 1..n {
            let e = so + 24 * i;
            let bind = b[e + 4] >> 4;
            if (bind == 1 || bind == 2) && lu::r16(b, e + 6) != 0 {
                out.push(lu::cstr(b, st + lu::r32(b, e) as usize));
            }
        }
    }
    return true;
}

// An import library's members (a short import object, or binutils' `.idata$` sections) are no objects:
// the import library stands for its DLL. A weak external defines its name (its default stands in).
fn coff_syms<'a>(b: Slice<'a, u8>, out: &mut Vector<str<'a>>) bool {
    if b.len() < 20 || lu::r16(b, 0) != 0x8664 {
        return false;
    }
    let nsec = lu::r16(b, 2) as usize;
    for k in 0..nsec {
        let h = 20 + 40 * k;
        if h + 40 > b.len() || lu::cstr(b[h..h + 8], 0).starts_with(".idata$") {
            return false;
        }
    }
    let symtab = lu::r32(b, 8) as usize;
    let nsym = lu::r32(b, 12) as usize;
    let strtab = symtab + 18 * nsym;
    let mut k: usize = 0;
    // Each step reads one symbol and skips its auxiliary records.
    while k < nsym {
        let e = symtab + 18 * k;
        let sec = lu::r16(b, e + 12) as i16;
        if b[e + 16] == 2 && sec != 0 || b[e + 16] == 105 {
            if lu::r32(b, e) == 0 {
                out.push(lu::cstr(b, strtab + lu::r32(b, e + 4) as usize));
            } else {
                let mut n: usize = 0;
                while n < 8 && b[e + n] != 0 {
                    n += 1;
                }
                out.push(unsafe str::from_raw(b.as_ptr() + e, n));
            }
        }
        k += 1 + b[e + 17] as usize;
    }
    return true;
}

fn wasm_syms<'a>(b: Slice<'a, u8>, out: &mut Vector<str<'a>>) bool {
    if b.len() < 8 || lu::r32(b, 0) != 0x6D736100 {
        return false;
    }
    let mut p: usize = 8;
    // Each step reads one section; only `linking` is read.
    while p < b.len() {
        let id = b[p];
        p += 1;
        let len = lu::read_uleb(b, &mut p) as usize;
        let end = p + len;
        if id == 0 {
            let mut q = p;
            let nl = lu::read_uleb(b, &mut q) as usize;
            let name = unsafe str::from_raw(b.as_ptr() + q, nl);
            q += nl;
            if name == "linking" {
                let _ = lu::read_uleb(b, &mut q);
                while q < end {
                    let sub = b[q];
                    q += 1;
                    let sl = lu::read_uleb(b, &mut q) as usize;
                    let se = q + sl;
                    if sub == 8 {
                        let n = lu::read_uleb(b, &mut q);
                        for _ in 0..n {
                            let kind = b[q];
                            q += 1;
                            let flags = lu::read_uleb(b, &mut q);
                            let undef = (flags & 0x10) != 0;
                            let local = (flags & 2) != 0;
                            if kind == 3 {
                                let _ = lu::read_uleb(b, &mut q);
                                continue;
                            }
                            let mut has_name = true;
                            if kind != 1 {
                                let _ = lu::read_uleb(b, &mut q);
                                has_name = !undef || (flags & 0x40) != 0;
                            }
                            let mut s = "";
                            if has_name {
                                let n2 = lu::read_uleb(b, &mut q) as usize;
                                s = unsafe str::from_raw(b.as_ptr() + q, n2);
                                q += n2;
                            }
                            if kind == 1 && !undef {
                                let _ = lu::read_uleb(b, &mut q);
                                let _ = lu::read_uleb(b, &mut q);
                                let _ = lu::read_uleb(b, &mut q);
                            }
                            if !undef && !local && s.len() != 0 {
                                out.push(s);
                            }
                        }
                    }
                    q = se;
                }
            }
        }
        p = end;
    }
    return true;
}
