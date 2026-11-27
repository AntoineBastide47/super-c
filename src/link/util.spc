// Byte helpers the linkers share: whole-file reads and writes, little-endian fields, LEB128.
import std::platform::fs;
import codegen::obj as ob;
import utils::par as par;

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

/// The version an Apple SDK's `SDKSettings.json` (`b`) names, as a Mach-O version word (major << 16 |
/// minor << 8 | patch): the string of its first `"Version"` key; 0 when it has none.
pub(package) const fn sdk_settings_version(b: []u8) u32 {
    let key = "\"Version\"";
    let n = b.len();
    let k = key.len();
    for at in 0..n {
        if at + k > n {
            break;
        }
        let mut same = true;
        for q in 0..k {
            same = same && b[at + q] == key.byte_at(q);
        }
        if !same {
            continue;
        }
        // The colon and the string's quote.
        let mut i = at + k;
        while i < n && (b[i] == b' ' || b[i] == b':') {
            i += 1;
        }
        if i >= n || b[i] != b'"' {
            return 0;
        }
        i += 1;
        let mut v: u32 = 0;
        // Up to three numbers between dots.
        for part in 0..3u32 {
            let mut x: u32 = 0;
            while i < n && b[i] >= b'0' && b[i] <= b'9' && x < 6553 {
                x = x * 10 + (b[i] - b'0') as u32;
                i += 1;
            }
            let mask: u32 = if part == 0 {
                0xFFFF
            } else {
                0xFF
            };
            v |= (x & mask) << 16 - 8 * part;
            if i >= n || b[i] != b'.' {
                break;
            }
            i += 1;
        }
        return v;
    }
    return 0;
}

/// arm64 code stays off a boundary of this many bytes (`keep_pad`): a processor runs code that holds one
/// a cycle late each time it passes it (Apple M-series: a function of 5 instructions or a loop of 7 that
/// holds one takes 4 cycles in place of 3; boundaries of 64 to 2048 bytes cost nothing).
const KEEP_PAGE: u64 = 4096;
// A function or a loop of at most this many bytes stays off the boundary: longer code passes it once in
// more cycles, and each move costs up to this many bytes of padding.
const KEEP_MAX: u64 = 128;
// `keep_pad` moves its code at most this many times.
const KEEP_TRIES: u32 = 8;

/// A function that fits one line of this many bytes stays inside one where the link's processors show
/// the cost of the boundary between two (`keep_pad`; a Neoverse N2 runs a function of 5 instructions
/// that holds one 6% slower and a loop no slower; Apple M-series: nothing).
pub(package) const KEEP_LINE: u64 = 64;

/// The bytes to leave before arm64 code `code` (a function, or an object's whole code) that would start
/// at address `addr`, a multiple of `align` (a power of two, 4 at least): first, with lines of `line`
/// bytes (0: the link keeps no lines), the move to the next line of code that fits one line and would
/// hold a boundary between two; then the fewest more, the place in the line kept, after which no
/// KEEP_PAGE boundary falls inside the code when it has at most KEEP_MAX bytes, nor inside a loop of at
/// most KEEP_MAX bytes of it. The first move alone when KEEP_TRIES moves find no such place.
pub(package) const fn keep_pad(code: []u8, addr: u64, align: u64, line: u64) u64 {
    let n = code.len() as u64;
    let first = if line != 0 && n <= line && addr % line + n > line {
        align_up(addr, line) - addr
    } else {
        0u64
    };
    let mut pad = first;
    for _ in 0..KEEP_TRIES {
        let start = addr + pad;
        let mut bd = align_up(start + 1, KEEP_PAGE);
        let mut d: u64 = 0;
        // One step per boundary inside the code.
        for _ in 0..n / KEEP_PAGE + 1 {
            if d != 0 || bd >= start + n {
                break;
            }
            d = bd - start - kept_start(code, bd - start);
            bd += KEEP_PAGE;
        }
        if d == 0 {
            return pad;
        }
        pad += align_up(d, align.max(line));
    }
    return first;
}

// The least offset in arm64 code `code` of what must not hold a boundary at offset `o` inside (`keep_pad`):
// 0 for code of at most KEEP_MAX bytes, else the head of the widest loop of at most KEEP_MAX bytes (the
// target of a backward branch, up to the branch) that begins before `o` and ends at it or after; `o`
// when none does.
const fn kept_start(code: []u8, o: u64) u64 {
    let n = code.len() as u64;
    if n <= KEEP_MAX {
        return 0;
    }
    let mut h = o;
    let mut x = o & ~3u64;
    // The branch of such a loop is less than KEEP_MAX bytes after `o`.
    for _ in 0..KEEP_MAX / 4 {
        if x + 4 > n {
            break;
        }
        let back = a64_back(r32(code, x as usize));
        if back != 0 && back <= x && back <= KEEP_MAX && x - back < h {
            h = x - back;
        }
        x += 4;
    }
    return h;
}

// The bytes arm64 instruction `w` branches back by: a conditional branch, a compare or test and branch, or
// a jump, to a lower address; 0 for any other word.
const fn a64_back(w: u32) u64 {
    let (bits, at) = if (w & 0xFF000010) == 0x54000000 || (w & 0x7E000000) == 0x34000000 {
        (19u32, 5u32)
    } else if (w & 0x7E000000) == 0x36000000 {
        (14u32, 5u32)
    } else if (w & 0xFC000000) == 0x14000000 {
        (26u32, 0u32)
    } else {
        return 0;
    };
    let f = w >> at & (1u32 << bits) - 1;
    if f >> bits - 1 == 0 {
        return 0;
    }
    return ((1u32 << bits) - f) as u64 * 4;
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

// ---- identical code folding ------------------------------------------------------------------------------

/// A function a link may fold into an identical one (`fold`): its bytes `at .. at + len` of the input, what
/// else must be the same (`key`: the format's alignment, flags and unwind rules), the hash of both
/// (`fold_hashes`), and its relocations `rels[r0 .. r0 + rn]`, in place order.
pub(package) struct FoldPart {
    pub(package) at: usize,
    pub(package) len: usize,
    pub(package) key: u64,
    pub(package) hash: u64,
    pub(package) r0: u32,
    pub(package) rn: u32,
}

/// A relocation of a `FoldPart`: its place in the part, its kind (the format's fields but the target and the
/// addend), and its target: part `part`, or (`part` NONE) any other target `tgt` (the format's exact name of a
/// symbol or section, `FOLD_GLOBAL`, `FOLD_ABS`, `FOLD_SECTION`), at `val` (offset and addend).
pub(package) struct FoldRel {
    pub(package) off: u32,
    pub(package) kind: u32,
    pub(package) part: u32,
    pub(package) tgt: u64,
    pub(package) val: u64,
}

extend FoldPart as Copy {}
extend FoldRel as Copy {}

pub(package) const FOLD_NONE: u32 = 0xFFFFFFFF;
/// The tags of a `FoldRel`'s other target: a global symbol (its id below), an absolute value (`val`), an input
/// section (its index below).
pub(package) const FOLD_GLOBAL: u64 = 1u64 << 32;
pub(package) const FOLD_ABS: u64 = 2u64 << 32;
pub(package) const FOLD_SECTION: u64 = 3u64 << 32;

/// Each part's `hash` of its key and bytes, on `jobs` workers. Only parts of one hash may fold: a caller
/// lists the relocations of those alone, and takes the others as the targets they are.
pub(package) fn fold_hashes(ps: &mut Vector<FoldPart>, b: []u8, jobs: u32) {
    let mut fc = FoldCtx { ps: ps.as_mut_ptr(), n: ps.len(), b: b.ptr, blen: b.len };
    par::chunks((ps.len() + FOLD_CHUNK - 1) / FOLD_CHUNK, jobs, fold_chunk, (&mut fc) as *mut FoldCtx);
}

// The parts a job of `fold_hashes` takes.
const FOLD_CHUNK: usize = 256;

// What `fold_chunk` reads and writes: the parts and the bytes.
struct FoldCtx {
    ps: *mut FoldPart,
    n: usize,
    b: *const u8,
    blen: usize,
}

// The hashes of chunk `c` of the parts, each part's into its own `hash`.
const fn fold_chunk(ctx: *mut void, c: usize) {
    let fc = unsafe &*(ctx as *const FoldCtx);
    let b = unsafe Slice::<u8> { ptr: fc.b, len: fc.blen };
    let lo = c * FOLD_CHUNK;
    let hi = (lo + FOLD_CHUNK).min(fc.n);
    for i in lo..hi {
        let p = unsafe &mut fc.ps[i];
        let mut h = (p.key ^ p.len as u64).wrapping_mul(0x9E3779B97F4A7C15);
        let mut k: usize = 0;
        while k + 8 <= p.len {
            h = (h ^ r64(b, p.at + k)).wrapping_mul(0x100000001B3);
            k += 8;
        }
        while k < p.len {
            h = (h ^ b[p.at + k] as u64).wrapping_mul(0x100000001B3);
            k += 1;
        }
        p.hash = h;
    }
}

/// Per part of `ps`, the part it folds into: the first of its class, NONE for that one and for a part alone. A
/// class holds parts of the same key, bytes and relocations, a relocation's target part counting by its
/// class: the classes split until every part's targets' classes agree (partition refinement, as LLD's
/// identical code folding), so two parts of a class run the same code on the same data.
pub(package) fn fold(ps: &Vector<FoldPart>, rs: &Vector<FoldRel>, b: []u8) Vector<u32> {
    let n = ps.len();
    let mut cls = Vector::<u32>::new();
    cls.resize_default(n);
    let mut keys = Vector::<u128>::with_capacity(n);
    // The parts with a relocation against a part: the others never split after the first classes.
    let mut dep = Vector::<u32>::new();
    for i in 0..n {
        let p = ps[i];
        let mut h = p.hash;
        let mut d = false;
        for r in p.r0..p.r0 + p.rn {
            let x = rs[r as usize];
            h = (h ^ x.off as u64 << 32 ^ x.kind ^ (x.part == FOLD_NONE) as u64).wrapping_mul(0x100000001B3);
            h = (h ^ x.tgt ^ x.val.rotate_left(17)).wrapping_mul(0x100000001B3);
            d = d || x.part != FOLD_NONE;
        }
        keys.push(h as u128 << 32 | i as u64);
        if d {
            dep.push(i as u32);
        }
    }
    keys.sort();
    // The first classes: the same constant parts (`fold_same`).
    let mut nc = fold_split(&keys, &mut cls, |x: usize, y: usize| fold_same(&ps[x], &ps[y], rs, b));
    let mut next = Vector::<u32>::new();
    next.resize_default(n);
    // Each round splits a class or ends: at most one round per part.
    for _ in 0..n + 1 {
        keys.truncate(0);
        for k in 0..dep.len() {
            let i = dep[k] as usize;
            let p = ps[i];
            let mut h = (cls[i] as u64).wrapping_mul(0x9E3779B97F4A7C15);
            for r in p.r0..p.r0 + p.rn {
                if rs[r as usize].part != FOLD_NONE {
                    h = (h ^ cls[rs[r as usize].part as usize] as u64).wrapping_mul(0x100000001B3);
                }
            }
            keys.push(cls[i] as u128 << 96 | h as u128 << 32 | i as u64);
        }
        keys.sort();
        // A class keeps its id when no part of it moves; a split gives the moved parts new ones.
        for i in 0..n {
            next[i] = cls[i];
        }
        let m = fold_refine(&keys, &cls, &mut next, nc, |x: usize, y: usize| fold_targets(&ps[x], &ps[y], rs, &cls));
        let done = m == nc;
        let t = replace(&mut cls, Vector::<u32>::new());
        cls = replace(&mut next, t);
        nc = m;
        if done {
            break;
        }
    }
    // The first part of each class, by index.
    let mut first = Vector::<u32>::new();
    for _ in 0..nc {
        first.push(FOLD_NONE);
    }
    let mut out = Vector::<u32>::with_capacity(n);
    for i in 0..n {
        let c = cls[i] as usize;
        if first[c] == FOLD_NONE {
            first[c] = i as u32;
            out.push(FOLD_NONE);
        } else {
            out.push(first[c]);
        }
    }
    return out;
}

// Class ids into `cls` for the parts `keys` lists sorted (`hash << 32 | part`): a part takes the class of the
// first earlier part of its run of equal hashes that `same` holds for, else a new one. The class count.
fn fold_split<F: fn(usize, usize) bool>(keys: &Vector<u128>, cls: &mut Vector<u32>, same: F) u32 {
    let mut nc: u32 = 0;
    // The parts of the current run that started a class.
    let mut heads = Vector::<u32>::new();
    for k in 0..keys.len() {
        let i = (keys[k] & 0xFFFFFFFF) as usize;
        if k == 0 || keys[k] >> 32 != keys[k - 1] >> 32 {
            heads.truncate(0);
        }
        let mut c = FOLD_NONE;
        for q in heads.iter() {
            if same((*q) as usize, i) {
                c = cls[(*q) as usize];
                break;
            }
        }
        if c == FOLD_NONE {
            c = nc;
            nc += 1;
            heads.push(i as u32);
        }
        cls[i] = c;
    }
    return nc;
}

// One round of the refinement: the parts `keys` lists sorted (`old class << 96 | hash << 32 | part`, the
// parts that depend on others) split their old classes `cls` into `next`, which holds the old ones. The
// first group of an old class keeps its id, each other group takes a new one past `nc`. The class count.
fn fold_refine<F: fn(usize, usize) bool>(
    keys: &Vector<u128>,
    cls: &Vector<u32>,
    next: &mut Vector<u32>,
    nc0: u32,
    same: F,
) u32 {
    let mut nc = nc0;
    // The parts of the current run of one old class and hash that started a group, and the groups' ids.
    let mut heads = Vector::<u32>::new();
    // Whether the current old class gave out its id yet.
    let mut kept = false;
    for k in 0..keys.len() {
        let i = (keys[k] & 0xFFFFFFFF) as usize;
        if k == 0 || keys[k] >> 96 != keys[k - 1] >> 96 {
            kept = false;
        }
        if k == 0 || keys[k] >> 32 != keys[k - 1] >> 32 {
            heads.truncate(0);
        }
        let mut c = FOLD_NONE;
        for q in heads.iter() {
            if same((*q) as usize, i) {
                c = next[(*q) as usize];
                break;
            }
        }
        if c == FOLD_NONE {
            if kept {
                c = nc;
                nc += 1;
            } else {
                c = cls[i];
                kept = true;
            }
            heads.push(i as u32);
        }
        next[i] = c;
    }
    return nc;
}
// Whether parts `p` and `q` have the same constant parts: key, bytes, relocations but their target parts.
const fn fold_same(p: &FoldPart, q: &FoldPart, rs: &Vector<FoldRel>, b: []u8) bool {
    if p.key != q.key || p.len != q.len || p.rn != q.rn || b[p.at..p.at + p.len] != b[q.at..q.at + q.len] {
        return false;
    }
    for k in 0..p.rn {
        let x = rs[(p.r0 + k) as usize];
        let y = rs[(q.r0 + k) as usize];
        if x.off != y.off || x.kind != y.kind || x.part == FOLD_NONE != (y.part == FOLD_NONE) || x.tgt != y.tgt || x.val != y.val {
            return false;
        }
    }
    return true;
}

// Whether the target parts of `p`'s and `q`'s relocations (the same constant parts) are of one class each.
const fn fold_targets(p: &FoldPart, q: &FoldPart, rs: &Vector<FoldRel>, cls: &Vector<u32>) bool {
    for k in 0..p.rn {
        let x = rs[(p.r0 + k) as usize];
        let y = rs[(q.r0 + k) as usize];
        if x.part != FOLD_NONE && cls[x.part as usize] != cls[y.part as usize] {
            return false;
        }
    }
    return true;
}
