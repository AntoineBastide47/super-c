// The compiler API's source input: file providers, which a session reads every file through, and byte-range
// edits. A provider answers for whole files and directory listings; the session keeps editor buffers and
// generated text above it. Paths are the provider's own names: the host's for `DiskFiles`, any `/`-separated
// names for `MemoryFiles`.
import std::platform::fs;
import api::errors as *;

/// A file system a session reads its sources and its `build.toml` through.
pub interface FileProvider {
    /// Put the bytes of file `path` into `out`: true, or false when `path` names no file.
    fn read(self: &mut Self, path: str, out: &mut String) Result<bool, IoError>;
    /// Push the names directly in directory `dir` into `out`, in any order: true, or false when `dir`
    /// names no directory.
    fn list(self: &mut Self, dir: str, out: &mut Vector<String>) Result<bool, IoError>;
}

/// The host's file system.
pub struct DiskFiles {}

extend DiskFiles as FileProvider {
    pub fn read(self: &mut Self, path: str, out: &mut String) Result<bool, IoError> {
        let mut f = switch fs::open(path, fs::OpenOptions { read: true }) {
            Ok(f) => f,
            Err(e) => {
                return if e.kind == IoErrorKind::NotFound {
                    Ok(false)
                } else {
                    Err(e)
                };
            },
        };
        let m = f.metadata()?;
        if m.kind != fs::FileKind::File {
            return Ok(false);
        }
        let sz = m.size as usize;
        out.clear();
        out.reserve(sz);
        let n = f.read_full(unsafe SliceMut::<u8> { ptr: out.spare_mut(sz), len: sz })?;
        out.advance_len(n);
        f.close()?;
        return Ok(true);
    }

    pub fn list(self: &mut Self, dir: str, out: &mut Vector<String>) Result<bool, IoError> {
        let mut d = switch fs::read_dir(dir) {
            Ok(d) => d,
            Err(e) => {
                return if e.kind == IoErrorKind::NotFound {
                    Ok(false)
                } else {
                    Err(e)
                };
            },
        };
        // Bounded by the entries of the directory.
        while let Some(r) = d.next() {
            out.push(String::from_str(r?.name));
        }
        return Ok(true);
    }
}

/// Files held in memory, by name, optionally above the host's files. A directory is every name prefix that
/// ends before a `/`, and with the host's files below, every host directory too.
pub struct MemoryFiles {
    names: Vector<String>,
    texts: Vector<String>,
    disk: bool,
    roots: Vector<String>, // real paths: the host files read lie in one; empty: any
}

extend MemoryFiles {
    /// Memory files alone.
    pub fn new() MemoryFiles {
        return MemoryFiles { names: Vector::<String>::new(), texts: Vector::<String>::new(), disk: false };
    }

    /// Memory files above the host's: a name the memory does not hold reads from the host.
    pub fn over_disk() MemoryFiles {
        return MemoryFiles { names: Vector::<String>::new(), texts: Vector::<String>::new(), disk: true };
    }

    /// Memory files above the host's files under directories `roots`: a host path is read or listed only
    /// when its real path (symbolic links resolved) lies in a root. `IoError` when a root does not resolve.
    pub fn over_disk_within(roots: Slice<String>) Result<MemoryFiles, IoError> {
        let mut m = MemoryFiles::over_disk();
        for i in 0..roots.len() {
            m.roots.push(fs::realpath(&roots[i])?);
        }
        return Ok(m);
    }

    // Whether the host's file `path` may be read: no roots, or its real path lies in one.
    fn reachable(self: &Self, path: str) bool {
        if self.roots.len() == 0 {
            return true;
        }
        let real = switch fs::realpath(path) {
            Ok(r) => r,
            Err(_) => {
                return false;
            },
        };
        let rp = real.as_str();
        for i in 0..self.roots.len() {
            let r = self.roots[i].as_str();
            if rp.starts_with(r) && (rp.len() == r.len() || rp.byte_at(r.len()) == b'/' || rp.byte_at(r.len()) == b'\\') {
                return true;
            }
        }
        return false;
    }

    /// Set file `name` to `text`, added when new.
    pub fn set(self: &mut Self, name: str, text: str) {
        for i in 0..self.names.len() {
            if self.names[i].as_str() == name {
                self.texts[i] = String::from_str(text);
                return;
            }
        }
        self.names.push(String::from_str(name));
        self.texts.push(String::from_str(text));
    }

    /// Remove file `name`; false when it is not there.
    pub fn remove(self: &mut Self, name: str) bool {
        for i in 0..self.names.len() {
            if self.names[i].as_str() == name {
                let _ = self.names.swap_remove(i);
                let _ = self.texts.swap_remove(i);
                return true;
            }
        }
        return false;
    }
}

extend MemoryFiles as FileProvider {
    pub fn read(self: &mut Self, path: str, out: &mut String) Result<bool, IoError> {
        for i in 0..self.names.len() {
            if self.names[i].as_str() == path {
                out.clear();
                out.push_str(&self.texts[i]);
                return Ok(true);
            }
        }
        if self.disk && self.reachable(path) {
            let mut d = DiskFiles {};
            return d.read(path, out);
        }
        return Ok(false);
    }

    pub fn list(self: &mut Self, dir: str, out: &mut Vector<String>) Result<bool, IoError> {
        let base = out.len();
        let mut found = false;
        for i in 0..self.names.len() {
            let n = self.names[i].as_str();
            if n.len() <= dir.len() + 1 || !n.starts_with(dir) || n.byte_at(dir.len()) != b'/' {
                continue;
            }
            found = true;
            let rest = n.slice(dir.len() + 1, n.len());
            let cut = rest.find("/");
            let entry = if cut < 0 {
                rest
            } else {
                rest.slice(0, cut as usize)
            };
            let mut seen = false;
            for k in base..out.len() {
                if out[k].as_str() == entry {
                    seen = true;
                }
            }
            if !seen {
                out.push(String::from_str(entry));
            }
        }
        if self.disk && self.reachable(dir) {
            let mut host = Vector::<String>::new();
            let mut d = DiskFiles {};
            if d.list(dir, &mut host)? {
                found = true;
                let mine = out.len();
                for k in 0..host.len() {
                    let mut seen = false;
                    for j in base..mine {
                        if out[j].as_str() == host[k].as_str() {
                            seen = true;
                        }
                    }
                    if !seen {
                        out.push(replace(host.index_mut(k), String::new()));
                    }
                }
            }
        }
        return Ok(found);
    }
}

/// One replacement: bytes `[start, end)` of a text become `text`.
pub struct Edit {
    pub start: u32,
    pub end: u32,
    pub text: String,
}

/// `text` with `edits` applied into `out`. Every offset is a byte offset into `text` on a UTF-8 character
/// boundary; edits do not overlap, and inserts at one offset apply in their order. Any other edit set is
/// `InvalidArgument`, with `out` unchanged.
pub fn apply_edits(text: str, edits: Slice<Edit>, out: &mut String) Result<Unit, ApiError> {
    let mut order = Vector::<u32>::with_capacity(edits.len());
    for i in 0..edits.len() {
        let e = &edits[i];
        if e.start > e.end || e.end as usize > text.len() || !boundary(text, e.start) || !boundary(text, e.end) {
            return Err(ApiError::new(Code::InvalidArgument, "an edit range is outside the text or splits a character"));
        }
        order.push(i as u32);
    }
    // By start, an insert before a replacement at its offset.
    order.sort_stable_by_key(|i: &u32| edits[(*i) as usize].start as u64 << 32 | edits[(*i) as usize].end as u64);
    for k in 1..order.len() {
        if edits[order[k] as usize].start < edits[order[k - 1] as usize].end {
            return Err(ApiError::new(Code::InvalidArgument, "two edits overlap"));
        }
    }
    let mut r = String::with_capacity(text.len());
    let mut at: usize = 0;
    for k in 0..order.len() {
        let e = &edits[order[k] as usize];
        r.push_str(text.slice(at, e.start as usize));
        r.push_str(&e.text);
        at = e.end as usize;
    }
    r.push_str(text.slice(at, text.len()));
    *out = r;
    return Ok(Unit {});
}

// Whether byte offset `at` of `text` starts a character or ends the text.
fn boundary(text: str, at: u32) bool {
    return at as usize == text.len() || (text.byte_at(at as usize) & 0xC0) != 0x80;
}
