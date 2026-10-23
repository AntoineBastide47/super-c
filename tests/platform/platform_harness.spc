// Shared pieces of the std::platform tests: a scratch directory that removes itself, byte views of
// text, and whole-file reads and writes through the layer itself.

import std::platform::entropy;
import std::platform::fs;
import std::platform::process;

/// A fresh directory under the system's temporary directory, removed with everything in it when the
/// value drops.
pub struct Scratch {
    pub dir: String,
}

/// `s` as bytes.
pub const fn bytes_of(s: str) []u8 {
    return unsafe Slice::<u8> { ptr: s.ptr(), len: s.len() };
}

/// A new scratch directory, named by the process id and random bytes so concurrent tests never share
/// one.
pub fn scratch() Scratch {
    let mut r: [u8; 8] = [0; 8];
    entropy::fill(r).unwrap();
    let mut dir = fs::temp_dir().unwrap();
    dir.format_into("/sc-plat-{}-", process::pid().unwrap_or(1));
    for b in r {
        dir.push_hex(b, false);
    }
    fs::mkdir(dir.as_str()).unwrap();
    return Scratch { dir: dir };
}

/// The whole file at `path` as text.
pub fn read_text(path: str) String {
    let mut f = fs::open(path, fs::OpenOptions { read: true }).unwrap();
    let n = f.metadata().unwrap().size as usize;
    let mut out = String::with_capacity(n + 1);
    let got = f.read_full(unsafe SliceMut::<u8> { ptr: out.spare_mut(n), len: n }).unwrap();
    out.advance_len(got);
    return out;
}

/// Create or truncate the file at `path` to hold `text`.
pub fn write_text(path: str, text: str) {
    let mut f = fs::open(path, fs::OpenOptions { write: true, create: true, truncate: true }).unwrap();
    f.write_all(bytes_of(text)).unwrap();
}

extend Scratch {
    /// The path of `name` inside the directory.
    pub fn at(self: &Scratch, name: str) String {
        let mut p = self.dir.clone();
        p.push_byte(b'/');
        p.push_str(name);
        return p;
    }
}

extend Scratch as Free {
    pub fn free(self: &mut Scratch) {
        let _ = fs::remove_all(self.dir.as_str());
        self.dir.free(); // a written `free` replaces the derived one, which would free the path
    }
}
