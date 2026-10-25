// Byte helpers the linkers share: whole-file reads and writes, little-endian fields, LEB128.
import std::platform::fs;

/// The bytes of file `path`, None when it cannot be read in full.
pub(package) fn read(path: str) Option<Vector<u8>> {
    let mut b = Vector::<u8>::new();
    if !read_append(path, &mut b) {
        return Option::<Vector<u8>>::None;
    }
    return Option::<Vector<u8>>::Some(b);
}

/// Append the bytes of file `path` to `out`; false when it cannot be read.
pub(package) fn read_append(path: str, out: &mut Vector<u8>) bool {
    let opened = fs::open(path, fs::OpenOptions { read: true });
    if opened.is_err() {
        return false;
    }
    let mut f = opened.unwrap();
    let md = f.metadata();
    if md.is_err() {
        return false;
    }
    let at0 = out.len();
    let n = md.unwrap().size as usize;
    out.resize_default(at0 + n);
    let mut at: usize = 0;
    // Bounded by the file's size: each step reads at least one byte or stops.
    while at < n {
        let r = f.read(unsafe SliceMut::<u8> { ptr: out.as_ptr() as *mut u8 + at0 + at, len: n - at });
        if r.is_err() || r.unwrap() == 0 {
            out.truncate(at0);
            return false;
        }
        at += r.unwrap();
    }
    return true;
}

/// Write `bytes` to a new file `path` with permission bits `mode`: any file there is removed first, so a
/// running or code-signed copy keeps its own bytes. False when a step fails.
pub(package) fn write(path: str, bytes: []u8, mode: u32) bool {
    let _ = fs::unlink(path);
    let opened = fs::open(path, fs::OpenOptions { write: true, create: true, truncate: true, mode: mode });
    if opened.is_err() {
        return false;
    }
    let mut f = opened.unwrap();
    return f.write_all(bytes).is_ok() && f.close().is_ok() && fs::set_permissions(path, mode).is_ok();
}

pub(package) const fn r16(b: []u8, at: usize) u32 {
    return b[at] as u32 | b[at + 1] as u32 << 8;
}

pub(package) const fn r32(b: []u8, at: usize) u32 {
    return r16(b, at) | r16(b, at + 2) << 16;
}

pub(package) const fn r64(b: []u8, at: usize) u64 {
    return r32(b, at) as u64 | r32(b, at + 4) as u64 << 32;
}

pub(package) const fn p16(b: &mut Vector<u8>, at: usize, v: u32) {
    b[at] = (v & 0xFF) as u8;
    b[at + 1] = (v >> 8 & 0xFF) as u8;
}

pub(package) const fn p32(b: &mut Vector<u8>, at: usize, v: u32) {
    p16(b, at, v & 0xFFFF);
    p16(b, at + 2, v >> 16);
}

pub(package) const fn p64(b: &mut Vector<u8>, at: usize, v: u64) {
    p32(b, at, v as u32);
    p32(b, at + 4, (v >> 32) as u32);
}

/// Append the little-endian 16, 32 and 64 bits of `v` to `o`.
pub(package) fn w16(o: &mut Vector<u8>, v: u32) {
    o.push((v & 0xFF) as u8);
    o.push((v >> 8 & 0xFF) as u8);
}

pub(package) fn w32(o: &mut Vector<u8>, v: u32) {
    w16(o, v & 0xFFFF);
    w16(o, v >> 16);
}

pub(package) fn w64(o: &mut Vector<u8>, v: u64) {
    w32(o, v as u32);
    w32(o, (v >> 32) as u32);
}

/// Append `s` and a terminating zero to string table `t`; its offset.
pub(package) fn put_str(t: &mut Vector<u8>, s: str) u32 {
    let at = t.len() as u32;
    for i in 0..s.len() {
        t.push(s.byte_at(i));
    }
    t.push(0);
    return at;
}

/// Append `v` as unsigned LEB128.
pub(package) fn uleb(o: &mut Vector<u8>, v: u64) {
    let mut x = v;
    // At most 10 bytes for 64 bits.
    loop {
        let byte = (x & 0x7F) as u8;
        x = x >> 7;
        if x == 0 {
            o.push(byte);
            return;
        }
        o.push(byte | 0x80);
    }
}

/// The size of `v` as unsigned LEB128.
pub(package) const fn uleb_len(v: u64) usize {
    let mut n: usize = 1;
    let mut x = v >> 7;
    while x != 0 {
        n += 1;
        x = x >> 7;
    }
    return n;
}

/// The unsigned LEB128 at `*at` of `b`, `*at` moved past it; `b.len()` ends a truncated one.
pub(package) const fn read_uleb(b: []u8, at: &mut usize) u64 {
    let mut v: u64 = 0;
    let mut sh: u64 = 0;
    while *at < b.len() && sh < 64 {
        let c = b[*at];
        *at += 1;
        v |= (c & 0x7F) as u64 << sh;
        if (c & 0x80) == 0 {
            return v;
        }
        sh += 7;
    }
    return v;
}

/// The NUL-terminated string at `at` of `b` (to the end when unterminated).
pub(package) const fn cstr<'a>(b: Slice<'a, u8>, at: usize) str<'a> {
    let mut e = at;
    while e < b.len() && b[e] != 0 {
        e += 1;
    }
    return unsafe str::from_raw(b.as_ptr() + at, e - at);
}

/// `v` rounded up to a multiple of `a` (a power of two).
pub(package) const fn align_up(v: u64, a: u64) u64 {
    return v + a - 1 & ~(a - 1);
}
