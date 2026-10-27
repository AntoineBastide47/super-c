// Text-based stubs (TAPI `.tbd`, version 4): the interface of an Apple SDK library without its code. A
// file holds YAML documents, one per library (libSystem's lists its re-exported libraries after its
// own); each names its install name, its re-exported libraries and its exported symbols per target.
// The parser reads the YAML subset these files use: top-level keys, sequences of mappings whose items
// start with `- `, flow sequences `[ ... ]` across lines, single-quoted and plain scalars.
import link::util as lu;

/// How an exported name spells its symbols.
pub const E_PLAIN: u8 = 0; // the name itself
pub const E_OBJC_CLASS: u8 = 1; // `_OBJC_CLASS_$_` and `_OBJC_METACLASS_$_` before it
pub const E_OBJC_EH: u8 = 2; // `_OBJC_EHTYPE_$_` before it
pub const E_OBJC_IVAR: u8 = 3; // `_OBJC_IVAR_$_` before it

/// Bytes `at .. at + len` of the file.
pub struct Span {
    pub at: u32,
    pub len: u32,
    pub kind: u8,
}

extend Span as Copy {}

/// One library: its install name, the names it exports for the target, the install names of the
/// libraries it re-exports.
pub struct Doc {
    pub install: Span,
    pub exports: Vector<Span>,
    pub reexports: Vector<Span>,
}

// The top-level key whose sequence is being read.
const K_OTHER: u8 = 0;
const K_EXPORTS: u8 = 1; // `exports` and `reexports`: symbols this library provides
const K_LIBS: u8 = 2; // `reexported-libraries`

/// The libraries of stub file `t` for a target `want` names (`arm64-macos`), into `docs`. False when the
/// file is not a version 4 stub.
pub fn parse(t: []u8, want: []str, docs: &mut Vector<Doc>) bool {
    let n = t.len();
    let mut p: usize = 0;
    let mut sect = K_OTHER;
    let mut item_ok = false;
    let mut in_doc = false;
    let mut items = Vector::<Span>::new();
    // Each step consumes one line, or one key and its value.
    while p < n {
        let ls = p;
        while p < n && t[p] == b' ' {
            p += 1;
        }
        let indent = p - ls;
        if p >= n {
            break;
        }
        if t[p] == b'\n' || t[p] == b'#' {
            skip_line(t, &mut p);
            continue;
        }
        if indent == 0 && starts(t, p, "---") {
            if !starts(t, p, "--- !tapi-tbd") {
                return false;
            }
            docs.push(
                Doc {
                    install: Span { at: 0, len: 0, kind: 0 },
                    exports: Vector::<Span>::new(),
                    reexports: Vector::<Span>::new(),
                },
            );
            in_doc = true;
            sect = K_OTHER;
            skip_line(t, &mut p);
            continue;
        }
        if indent == 0 && starts(t, p, "...") {
            in_doc = false;
            skip_line(t, &mut p);
            continue;
        }
        if !in_doc {
            return false;
        }
        let item = starts(t, p, "- ");
        if item {
            p += 2;
            item_ok = false;
            while p < n && t[p] == b' ' {
                p += 1;
            }
        }
        // The key.
        let ks = p;
        while p < n && t[p] != b':' && t[p] != b'\n' {
            p += 1;
        }
        if p >= n || t[p] != b':' {
            return false;
        }
        let key = unsafe str::from_raw(t.as_ptr() + ks, p - ks);
        p += 1;
        while p < n && t[p] == b' ' {
            p += 1;
        }
        // The value: a flow sequence, a scalar, or nothing (a block follows).
        items.truncate(0);
        if p < n && t[p] == b'[' {
            p += 1;
            if !flow(t, &mut p, &mut items) {
                return false;
            }
        } else if p < n && t[p] != b'\n' {
            items.push(scalar(t, &mut p));
        }
        skip_line(t, &mut p);
        let d = docs.len() - 1;
        if indent == 0 && !item {
            sect = K_OTHER;
            if key == "exports" || key == "reexports" {
                sect = K_EXPORTS;
            } else if key == "reexported-libraries" {
                sect = K_LIBS;
            } else if key == "tbd-version" {
                if items.len() != 1 || span(t, items[0]) != "4" {
                    return false;
                }
            } else if key == "install-name" && items.len() == 1 {
                docs.index_mut(d).install = items[0];
            }
            continue;
        }
        if key == "targets" {
            item_ok = false;
            for i in 0..items.len() {
                let s = span(t, items[i]);
                for w in 0..want.len() {
                    item_ok = item_ok || s == want[w];
                }
            }
            continue;
        }
        if !item_ok {
            continue;
        }
        if sect == K_LIBS && key == "libraries" {
            for i in 0..items.len() {
                docs.index_mut(d).reexports.push(items[i]);
            }
            continue;
        }
        if sect != K_EXPORTS {
            continue;
        }
        let kind = if key == "objc-classes" {
            E_OBJC_CLASS;
        } else if key == "objc-eh-types" {
            E_OBJC_EH;
        } else if key == "objc-ivars" {
            E_OBJC_IVAR;
        } else if key == "symbols" || key == "weak-symbols" || key == "thread-local-symbols" {
            E_PLAIN;
        } else {
            continue;
        };
        for i in 0..items.len() {
            let mut s = items[i];
            s.kind = kind;
            // `$ld$` names direct the static linker for older deployment targets; nothing binds them.
            if !span(t, s).starts_with("$ld$") {
                docs.index_mut(d).exports.push(s);
            }
        }
    }
    return true;
}

/// The bytes of span `s` of `t`.
pub const fn span<'a>(t: Slice<'a, u8>, s: Span) str<'a> {
    return unsafe str::from_raw(t.as_ptr() + s.at as usize, s.len as usize);
}

const fn starts(t: []u8, p: usize, s: str) bool {
    if p + s.len() > t.len() {
        return false;
    }
    for i in 0..s.len() {
        if t[p + i] != s.byte_at(i) {
            return false;
        }
    }
    return true;
}

const fn skip_line(t: []u8, p: &mut usize) {
    while *p < t.len() && t[*p] != b'\n' {
        *p += 1;
    }
    if *p < t.len() {
        *p += 1;
    }
}

// A scalar at `*p`: single-quoted, or plain to the end of the line (or a flow separator inside `[ ]`).
const fn scalar(t: []u8, p: &mut usize) Span {
    let n = t.len();
    if t[*p] == b'\'' {
        let s = *p + 1;
        let mut e = s;
        while e < n && t[e] != b'\'' {
            e += 1;
        }
        *p = if e < n {
            e + 1;
        } else {
            e;
        };
        return Span { at: s as u32, len: (e - s) as u32, kind: 0 };
    }
    let s = *p;
    let mut e = s;
    while e < n && t[e] != b'\n' && t[e] != b',' && t[e] != b']' {
        e += 1;
    }
    *p = e;
    while e > s && t[e - 1] == b' ' {
        e -= 1;
    }
    return Span { at: s as u32, len: (e - s) as u32, kind: 0 };
}

// The items of a flow sequence whose `[` precedes `*p`, into `items`; `*p` past its `]`.
fn flow(t: []u8, p: &mut usize, items: &mut Vector<Span>) bool {
    let n = t.len();
    // Each step consumes a separator or an item.
    while *p < n {
        let c = t[*p];
        if c == b']' {
            *p += 1;
            return true;
        }
        if c == b' ' || c == b'\n' || c == b',' {
            *p += 1;
            continue;
        }
        items.push(scalar(t, p));
    }
    return false;
}
