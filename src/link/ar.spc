// The archiver: objects into a static library, with the symbol index a linker reads to find the member
// that defines a symbol. Mach-O archives take the BSD layout (`#1/<n>` names, a sorted `__.SYMDEF`);
// the others the System V layout every other linker reads (a `/` index, a `//` table of long names).
// The output is deterministic: no times, owners or modes but the fixed ones.
import link::util as lu;
import target::native as nat;

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
        let mut names = Vector::<String>::new();
        if !defined(fmt, bytes.as_slice(), &mut names) {
            err.format_into("'{}' is not an object of the target's format", objs[i].as_str());
            return false;
        }
        for k in 0..names.len() {
            syms.push((replace(names.index_mut(k), String::new()), i as u32));
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
fn defined(fmt: u8, b: []u8, out: &mut Vector<String>) bool {
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

fn macho_syms(b: []u8, out: &mut Vector<String>) bool {
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
                    out.push(String::from_str(lu::cstr(b, st + lu::r32(b, e) as usize)));
                }
            }
        }
        c += lu::r32(b, c + 4) as usize;
    }
    return true;
}

fn elf_syms(b: []u8, out: &mut Vector<String>) bool {
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
                out.push(String::from_str(lu::cstr(b, st + lu::r32(b, e) as usize)));
            }
        }
    }
    return true;
}

fn coff_syms(b: []u8, out: &mut Vector<String>) bool {
    if b.len() < 20 || lu::r16(b, 0) != 0x8664 {
        return false;
    }
    let symtab = lu::r32(b, 8) as usize;
    let nsym = lu::r32(b, 12) as usize;
    let strtab = symtab + 18 * nsym;
    let mut k: usize = 0;
    // Each step reads one symbol and skips its auxiliary records.
    while k < nsym {
        let e = symtab + 18 * k;
        let sec = lu::r16(b, e + 12) as i16;
        if b[e + 16] == 2 && sec != 0 {
            if lu::r32(b, e) == 0 {
                out.push(String::from_str(lu::cstr(b, strtab + lu::r32(b, e + 4) as usize)));
            } else {
                let mut n: usize = 0;
                while n < 8 && b[e + n] != 0 {
                    n += 1;
                }
                out.push(String::from_str(unsafe str::from_raw(b.as_ptr() + e, n)));
            }
        }
        k += 1 + b[e + 17] as usize;
    }
    return true;
}

fn wasm_syms(b: []u8, out: &mut Vector<String>) bool {
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
                                out.push(String::from_str(s));
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
