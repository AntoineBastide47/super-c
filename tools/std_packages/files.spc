// File access of the checker over std::platform::fs: whole-file reads, and the sorted `.spc`
// files under a directory. Paths use `/` on every host.
import std::platform::fs;

/// The bytes of the file at `path`; None when it cannot be opened or read.
pub fn read_file(path: str) Option<String> {
    let opened = fs::open(path, fs::OpenOptions { read: true });
    if opened.is_err() {
        return None;
    }
    let mut f = opened.unwrap();
    let md = f.metadata();
    if md.is_err() {
        return None;
    }
    let n = md.unwrap().size as usize;
    let mut text = String::with_capacity(n);
    let got = f.read_full(unsafe SliceMut::<u8> { ptr: text.spare_mut(n), len: n });
    if got.is_err() || f.close().is_err() {
        return None;
    }
    text.advance_len(got.unwrap());
    return Some(text);
}

/// The `.spc` files under `dir`, recursively, as paths relative to `dir` in byte order. Entries whose name
/// starts with `.` are skipped. False when a directory cannot be read.
pub fn list_spc(dir: str, out: &mut Vector<String>) bool {
    let ok = list_spc_in(dir, "", out);
    out.sort();
    return ok;
}

// The `.spc` files of `<root>/<rel>` and its subdirectories, as `<rel><name>` paths.
fn list_spc_in(root: str, rel: str, out: &mut Vector<String>) bool {
    let mut path = String::from_str(root);
    path.push_byte(b'/');
    path.push_str(rel);
    let opened = fs::read_dir(&path);
    if opened.is_err() {
        return false;
    }
    let mut d = opened.unwrap();
    let mut dirs = Vector::<String>::new();
    let mut ok = true;
    // Bounded by the entries of the directory.
    while let Some(r) = d.next() {
        if r.is_err() {
            ok = false;
            break;
        }
        let e = r.unwrap();
        if e.name.starts_with(".") {
            continue;
        }
        let mut child_rel = String::from_str(rel);
        child_rel.push_str(e.name);
        // A link to a directory counts as one: only a listing kind of File settles it without a stat.
        let is_dir = switch e.kind {
            Some(File) => false,
            Some(Dir) => true,
            _ => {
                let mut child = String::from_str(&path);
                child.push_str(e.name);
                fs::stat(&child).map(|m: fs::Metadata| m.kind == fs::FileKind::Dir).unwrap_or(false)
            },
        };
        if is_dir {
            child_rel.push_byte(b'/');
            dirs.push(child_rel);
        } else if child_rel.ends_with(".spc") {
            out.push(child_rel);
        }
    }
    for sub in dirs.iter() {
        ok = list_spc_in(root, sub.as_str(), out) && ok;
    }
    return ok;
}
