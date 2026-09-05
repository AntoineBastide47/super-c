// The manifest half of the language server: `build.toml` gets diagnostics, key/section completion and
// hover, from the SAME parser and validator the build runs (bsys::parse_check). Nothing here re-states
// the schema's rules: a manifest key that the build accepts is a key the editor accepts, because both
// ask the same function. Only the documentation strings below are the editor's own.

import build_system::manifest as bsys;
import utils::errors as diag;

/// One manifest diagnostic: a raw byte span and its message, ready for the server to map to a range.
pub struct TomlDiag {
    pub start: u32,
    pub len: u32,
    pub msg: String,
}

/// Validate `src` as a manifest. The build's own checker produces these, so the editor never disagrees
/// with `super-c build` about what is wrong.
pub fn diagnostics(src: str) Vector<TomlDiag> {
    let mut out = Vector::<TomlDiag>::new();
    let (m, errs) = bsys::parse_check(src, "");
    for i in 0..errs.errors.len() {
        let d = errs.errors.at(i);
        out.push(TomlDiag { start: d.start, len: d.len, msg: d.msg.clone() });
    }
    return out;
}

// --- schema, for completion and hover ---------------------------------------------------------------
// `sec` matches the section a key lives under: "" is the top level, a name ending in '.' matches any
// section with that prefix (`profile.` covers `[profile.release]`).

struct Key {
    pub sec: str<'static>,
    pub name: str<'static>,
    pub doc: str<'static>,
}

const KEYS: [Key; 24] = [
    Key { sec: "", name: "bin", doc: "name of the binary this project builds" },
    Key { sec: "", name: "root", doc: "entry source file (default: src/main.spc)" },
    Key { sec: "", name: "out-dir", doc: "directory for build output (default: build)" },
    Key { sec: "", name: "test-dir", doc: "directory scanned for @test files (default: tests)" },
    Key { sec: "", name: "bench-dir", doc: "directory scanned for @bench files (default: bench)" },
    Key { sec: "", name: "cc", doc: "C compiler to invoke (else $CC, else cc)" },
    Key { sec: "", name: "cstd", doc: "C standard passed to the C compiler" },
    Key { sec: "", name: "cflags", doc: "extra C compiler flags, as an array of strings" },
    Key { sec: "", name: "ldflags", doc: "extra linker flags, as an array of strings" },
    Key { sec: "", name: "ldlibs", doc: "libraries to link, as an array of strings" },
    Key { sec: "", name: "jobs", doc: "parallel C compile jobs (default: one per core)" },
    Key { sec: "", name: "const-eval-steps", doc: "compile-time evaluation step budget" },
    Key { sec: "", name: "const-eval-memory", doc: "compile-time evaluation memory budget (B, or NK/NM/NG)" },
    Key { sec: "", name: "default-profile", doc: "profile used when none is named" },
    Key { sec: "profile.", name: "cflags", doc: "C compiler flags for this profile" },
    Key { sec: "profile.", name: "ldflags", doc: "linker flags for this profile" },
    Key { sec: "profile.", name: "strip", doc: "strip the linked binary (bool)" },
    Key { sec: "command.", name: "run", doc: "the command line to run, as an array of strings" },
    Key { sec: "command.", name: "needs-build", doc: "build the project first (bool)" },
    Key { sec: "command.", name: "env", doc: "environment for the command, as an inline table" },
    Key { sec: "lib", name: "name", doc: "library name (default: the project directory)" },
    Key { sec: "lib", name: "root", doc: "library entry source file (default: src/lib.spc)" },
    Key { sec: "lib", name: "type", doc: "array of \"static\" and/or \"shared\"" },
    Key { sec: "bin.", name: "root", doc: "entry source file for this binary target" },
];

const SECTIONS: [Key; 4] = [
    Key { sec: "", name: "lib", doc: "build this project as a library" },
    Key { sec: "", name: "profile.", doc: "flags for one build profile, e.g. [profile.release]" },
    Key { sec: "", name: "command.", doc: "a custom subcommand, e.g. [command.fuzz]" },
    Key { sec: "", name: "bin.", doc: "an extra binary target, e.g. [bin.tool]" },
];

// Does a key declared for `pat` apply in `sec`? A pattern ending in '.' is a prefix.
const fn sec_matches(pat: str, sec: str) bool {
    if pat.len() != 0 && pat[pat.len() - 1] == b'.' {
        return sec.len() > pat.len() && sec.starts_with(pat);
    }
    return pat == sec;
}

/// The section header in force at byte `at`: the last `[name]` at or before it, "" for the top level.
pub fn section_at(src: str, at: usize) String {
    let mut sec = String::new();
    let mut i: usize = 0;
    let mut line_start: usize = 0;
    while i < src.len() && i < at {
        if src[i] == b'\n' {
            line_start = i + 1;
            i = i + 1;
            continue;
        }
        if i == line_start && src[i] == b'[' {
            let mut j = i + 1;
            while j < src.len() && src[j] != b']' && src[j] != b'\n' {
                j = j + 1;
            }
            if j < src.len() && src[j] == b']' && j <= at {
                sec.clear();
                sec.push_str(src.slice(i + 1, j));
            }
        }
        i = i + 1;
    }
    return sec;
}

// The identifier-ish run of bytes around `at` (letters, digits, '-', '_', '.').
fn word_at(src: str, at: usize) str {
    let mut s = at;
    while s > 0 && is_word(src[s - 1]) {
        s = s - 1;
    }
    let mut e = at;
    while e < src.len() && is_word(src[e]) {
        e = e + 1;
    }
    return src.slice(s, e);
}

const fn is_word(c: u8) bool {
    return c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9' || c == b'-' || c == b'_' || c == b'.';
}

/// Is byte `at` inside a section header (between '[' and ']' on its line)? Header position completes
/// section names; anywhere else completes keys.
pub fn in_header(src: str, at: usize) bool {
    let mut i = at;
    while i > 0 && src[i - 1] != b'\n' {
        i = i - 1;
    }
    while i < at {
        if src[i] == b'[' {
            return true;
        }
        if src[i] != b' ' && src[i] != b'\t' {
            return false;
        }
        i = i + 1;
    }
    return false;
}

/// One completion item: the text to insert and its one-line documentation.
pub struct Item {
    pub label: String,
    pub doc: String,
}

/// What may be written at `at`: section names inside a `[...]` header, else the keys of the section in
/// force. Already-present keys are not filtered out: a duplicate is the validator's business, and
/// hiding a key the cursor is currently retyping would be worse.
pub fn completions(src: str, at: usize) Vector<Item> {
    let mut out = Vector::<Item>::new();
    if in_header(src, at) {
        let secs: []Key = SECTIONS;
        for i in 0..secs.len() {
            let s = secs.at(i);
            out.push(Item { label: String::from_str(s.name), doc: String::from_str(s.doc) });
        }
        return out;
    }
    let sec = section_at(src, at);
    let ks: []Key = KEYS;
    for i in 0..ks.len() {
        let k = ks.at(i);
        if sec_matches(k.sec, sec.as_str()) {
            out.push(Item { label: String::from_str(k.name), doc: String::from_str(k.doc) });
        }
    }
    return out;
}

/// The documentation for the key or section name under `at`, or an empty string.
pub fn hover(src: str, at: usize) String {
    let w = word_at(src, at);
    if w.len() == 0 {
        return String::new();
    }
    if in_header(src, at) {
        let secs: []Key = SECTIONS;
        for i in 0..secs.len() {
            let s = secs.at(i);
            let bare = trim_dot(s.name);
            if w == bare || w.starts_with(bare) && s.name[s.name.len() - 1] == b'.' {
                return String::from_str(s.doc);
            }
        }
        return String::new();
    }
    let sec = section_at(src, at);
    let mut doc = String::new();
    let ks: []Key = KEYS;
    for i in 0..ks.len() {
        let k = ks.at(i);
        if k.name == w && sec_matches(k.sec, sec.as_str()) {
            doc.clear();
            doc.push_str(k.doc);
        }
    }
    return doc;
}

const fn trim_dot(s: str) str {
    if s.len() != 0 && s[s.len() - 1] == b'.' {
        return s.slice(0, s.len() - 1);
    }
    return s;
}
