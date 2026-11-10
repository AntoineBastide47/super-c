// Byte helpers the linkers share: whole-file reads and writes, little-endian fields, LEB128.
import std::platform::fs;
import codegen::obj as ob;

/// The bytes of file `path`, None when it cannot be read in full.
pub(package) fn read(path: str) Option<Vector<u8>> {
    let mut b = Vector::<u8>::new();
    if !read_append(path, &mut b) {
        return None;
    }
    return Some(b);
}

/// `read_append` of input `path`, its failure the reason in `err`.
pub(package) fn read_input(path: str, out: &mut Vector<u8>, err: &mut String) bool {
    if read_append(path, out) {
        return true;
    }
    err.format_into("cannot read '{}'", path);
    return false;
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
        let r = f.read(unsafe SliceMut::<u8> { ptr: out.as_mut_ptr() + at0 + at, len: n - at });
        if r.is_err() || r.unwrap() == 0 {
            out.truncate(at0);
            return false;
        }
        at += r.unwrap();
    }
    return true;
}

/// The objects a link takes from memory in place of their files, by path: the ones the build that links
/// them just wrote.
pub(package) struct Mem {
    pub(package) objs: Map<String, Vector<u8>>,
}

extend Mem {
    pub(package) fn new() Mem {
        return Mem { objs: Map::<String, Vector<u8>>::new() };
    }
}

/// Append the bytes of object `path` that `mem` holds (null: none) to `blob`, and let them go; false when
/// it holds none.
pub(package) fn take_held(mem: *mut Mem, path: str, blob: &mut Vector<u8>) bool {
    if mem == null || unsafe (*mem).objs.len() == 0 {
        return false;
    }
    let key = String::from_str(path);
    switch unsafe (*mem).objs.remove(&key) {
        Some(b) => {
            blob.extend_from_slice(&b);
            return true;
        },
        None => {
            return false;
        },
    }
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
    return f.write_all(bytes).is_ok() && f.close().is_ok() && keep_mode(path, mode);
}

// Give `path` permission bits `mode` past the umask.
@platform(!wasm)
fn keep_mode(path: str, mode: u32) bool {
    return fs::set_permissions(path, mode).is_ok();
}
// WASI files have no permission bits.
@platform(wasm)
const fn keep_mode(_path: str, _mode: u32) bool {
    return true;
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

/// An output image by its address and size: the tasks that copy and relocate input sections write
/// through it, each into its own sections' bytes, and nothing resizes the image meanwhile.
pub(package) struct Img {
    ptr: *mut u8,
    len: usize,
}

extend Img as Copy {}

// The image outlives the tasks of the stage that writes it; their byte ranges are disjoint.
unsafe extend Img as Send {}

extend Img {
    pub(package) const fn of(v: &mut Vector<u8>) Img {
        return Img { ptr: v.as_mut_ptr(), len: v.len() };
    }

    fn at(self: Img, at: usize, n: usize) *mut u8 {
        assert(at + n <= self.len, "an access past the image");
        return unsafe (self.ptr + at);
    }

    pub(package) fn r8(self: Img, at: usize) u8 {
        return unsafe self.at(at, 1)[0];
    }

    pub(package) fn p8(self: Img, at: usize, v: u8) {
        unsafe self.at(at, 1)[0] = v;
    }

    pub(package) fn r16(self: Img, at: usize) u32 {
        let p = self.at(at, 2);
        return (unsafe p[0]) as u32 | (unsafe p[1]) as u32 << 8;
    }

    pub(package) fn r32(self: Img, at: usize) u32 {
        return self.r16(at) | self.r16(at + 2) << 16;
    }

    pub(package) fn r64(self: Img, at: usize) u64 {
        return self.r32(at) as u64 | self.r32(at + 4) as u64 << 32;
    }

    pub(package) fn p16(self: Img, at: usize, v: u32) {
        let p = self.at(at, 2);
        unsafe p[0] = (v & 0xFF) as u8;
        unsafe p[1] = (v >> 8 & 0xFF) as u8;
    }

    pub(package) fn p32(self: Img, at: usize, v: u32) {
        self.p16(at, v & 0xFFFF);
        self.p16(at + 2, v >> 16);
    }

    pub(package) fn p64(self: Img, at: usize, v: u64) {
        self.p32(at, v as u32);
        self.p32(at + 4, (v >> 32) as u32);
    }

    /// `b` at `at`.
    pub(package) fn put(self: Img, at: usize, b: []u8) {
        let p = self.at(at, b.len());
        unsafe SliceMut::<u8> { ptr: p, len: b.len() }.copy_from_slice(b);
    }
}

/// The chunks of a linker's input sections: a fixed count, so a chunk's work does not depend on the workers.
pub(package) const SEC_CHUNKS: u64 = 64;

/// Into `out`, the end of each chunk of `w.len()` items of about equal total weight `w` (SEC_CHUNKS of them,
/// fewer when the items are few).
pub(package) fn chunk_ends(w: &Vector<u64>, out: &mut Vector<u32>) {
    out.truncate(0);
    let mut tot: u64 = 0;
    for i in 0..w.len() {
        tot += w[i];
    }
    let mut acc: u64 = 0;
    for i in 0..w.len() {
        acc += w[i];
        if i + 1 == w.len() || acc * SEC_CHUNKS >= tot * (out.len() as u64 + 1) {
            out.push(i as u32 + 1);
        }
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

/// Whether `p` names a regular file.
pub(package) fn is_file(p: str) bool {
    let m = fs::stat(p);
    return m.is_ok() && m.unwrap().kind == fs::FileKind::File;
}

/// The last component of POSIX path `p`.
pub(package) const fn basename(p: str) str {
    let mut i = p.len();
    while i > 0 && p.byte_at(i - 1) != b'/' {
        i -= 1;
    }
    return p.slice(i, p.len());
}

/// The big-endian 32-bit word at `at` of `b`.
pub(package) const fn be32(b: []u8, at: usize) u32 {
    return b[at] as u32 << 24 | b[at + 1] as u32 << 16 | b[at + 2] as u32 << 8 | b[at + 3] as u32;
}

/// `v` rounded up to a multiple of `a` (a power of two).
pub(package) const fn align_up(v: u64, a: u64) u64 {
    return v + a - 1 & ~(a - 1);
}

/// Whether export list `exports` (None: every global) names `name`.
pub(package) fn listed(exports: &Option<Set<String>>, name: str) bool {
    return switch exports {
        Some(s) => {
            let k = String::from_str(name);
            s.contains(&k)
        },
        None => true,
    };
}

/// The undefined symbols of a link: their count and the names of the first 20.
pub(package) struct Missing {
    n: usize,
    names: String,
}

extend Missing {
    pub(package) fn new() Missing {
        return Missing { n: 0, names: String::new() };
    }

    pub(package) fn add(self: &mut Self, s: str) {
        self.n += 1;
        if self.n <= 20 {
            self.names.format_into("\n  {}", s);
        }
    }

    /// Whether no symbol is missing; else the report in `err`.
    pub(package) fn report(self: &Self, err: &mut String) bool {
        if self.n == 0 {
            return true;
        }
        err.format_into("{} undefined symbol(s):{}", self.n, self.names.as_str());
        if self.n > 20 {
            err.push_str("\n  ...");
        }
        return false;
    }
}
