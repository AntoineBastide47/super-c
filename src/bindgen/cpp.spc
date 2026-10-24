// The C11 preprocessor of `super-c bindgen`: it prints what `cc -E` and `cc -E -dM` print. Each file
// becomes 16-byte tokens once; macros expand by Prosser's algorithm over hash-consed hide sets; the output is
// `cc -E` text with line markers. Bounds: include depth 200, `#if` nesting 1024, expression and argument
// nesting 256, and 2^24 token steps per top-level expansion; every other loop is bounded by its input.
import module::loader as loader;
import utils::names as nm;
import std::platform::fs;

extern "C" {
    fn memchr(s: *const void, c: i32, n: usize) *mut void;
}

const NONE: u32 = 0xFFFFFFFFu32;
const INCLUDE_DEPTH_MAX: usize = 200;
const COND_DEPTH_MAX: usize = 1024;
const EXPR_DEPTH_MAX: u32 = 256;
const EXPAND_DEPTH_MAX: u32 = 256;
const WORK_MAX: u64 = 16777216;
const TEXT_PAD: usize = 8;
const FLUSH_AT: usize = 512;

// Token kinds. `K_PARAM`, `K_STRINGIFY`, `K_PASTE` and `K_VAOPT` occur only in stored macro bodies;
// `K_PLACE` only while a body is substituted; `K_PRAGMA` carries the text of a `#pragma` line.
const K_IDENT: u8 = 0;
const K_NUM: u8 = 1;
const K_STR: u8 = 2;
const K_CHAR: u8 = 3;
const K_PUNCT: u8 = 4;
const K_OTHER: u8 = 5;
const K_PARAM: u8 = 6;
const K_STRINGIFY: u8 = 7;
const K_PASTE: u8 = 8;
const K_VAOPT: u8 = 9;
const K_PLACE: u8 = 10;
const K_PRAGMA: u8 = 11;

const F_SPC: u8 = 1;
const F_BOL: u8 = 2;
const F_CONT: u8 = 4; // a file token on a later physical line than the logical line it began on

// Spelling ids. Id 0 is the empty string and ids 1..255 are the one-byte strings, so a one-byte token's id is
// its byte. `FIXED` follows from `ID_ELLIPSIS`, in this order.
const ID_HASH: u32 = 35;
const ID_LPAREN: u32 = 40;
const ID_RPAREN: u32 = 41;
const ID_COMMA: u32 = 44;
const ID_ELLIPSIS: u32 = 256;
const ID_HASHHASH: u32 = 257;
const ID_DEFINED: u32 = 258;
const ID_VA_ARGS: u32 = 259;
const ID_VA_OPT: u32 = 260;
const ID_PRAGMA_OP: u32 = 261;
const ID_DEFINE: u32 = 262;
const ID_UNDEF: u32 = 263;
const ID_INCLUDE: u32 = 264;
const ID_INCLUDE_NEXT: u32 = 265;
const ID_IMPORT: u32 = 266;
const ID_IF: u32 = 267;
const ID_IFDEF: u32 = 268;
const ID_IFNDEF: u32 = 269;
const ID_ELIF: u32 = 270;
const ID_ELIFDEF: u32 = 271;
const ID_ELIFNDEF: u32 = 272;
const ID_ELSE: u32 = 273;
const ID_ENDIF: u32 = 274;
const ID_LINE: u32 = 275;
const ID_ERROR: u32 = 276;
const ID_WARNING: u32 = 277;
const ID_PRAGMA: u32 = 278;
const ID_IDENT: u32 = 279;
const ID_SCCS: u32 = 280;
const ID_ONCE: u32 = 281;
const ID_ASSERT: u32 = 282;
const ID_UNASSERT: u32 = 283;
const ID_PUSH_MACRO: u32 = 284;
const ID_POP_MACRO: u32 = 285;
const ID_CHAR_UNSIGNED: u32 = 286;
const ID_DIGRAPH_HASH: u32 = 287;
const ID_DIGRAPH_HASHHASH: u32 = 288;

const FIXED: []str = [
    "...",
    "##",
    "defined",
    "__VA_ARGS__",
    "__VA_OPT__",
    "_Pragma",
    "define",
    "undef",
    "include",
    "include_next",
    "import",
    "if",
    "ifdef",
    "ifndef",
    "elif",
    "elifdef",
    "elifndef",
    "else",
    "endif",
    "line",
    "error",
    "warning",
    "pragma",
    "ident",
    "sccs",
    "once",
    "assert",
    "unassert",
    "push_macro",
    "pop_macro",
    "__CHAR_UNSIGNED__",
    "%:",
    "%:%:",
];

// Macro kinds. A built-in's `param_count` holds its `B_*` code.
const M_OBJ: u8 = 0;
const M_FUNC: u8 = 1;
const M_BUILTIN: u8 = 2;

const B_FILE: u32 = 1;
const B_LINE: u32 = 2;
const B_COUNTER: u32 = 3;
const B_LEVEL: u32 = 4;
const B_BASE: u32 = 5;
const B_DATE: u32 = 6;
const B_TIME: u32 = 7;
const B_TIMESTAMP: u32 = 8;
const B_FILE_NAME: u32 = 9;
const B_HAS_INCLUDE: u32 = 10;
const B_HAS_INCLUDE_NEXT: u32 = 11;
const B_HAS_FEATURE: u32 = 12;
const B_HAS_EXTENSION: u32 = 13;
const B_HAS_ATTRIBUTE: u32 = 14;
const B_HAS_C_ATTRIBUTE: u32 = 15;
const B_HAS_BUILTIN: u32 = 16;
const B_HAS_DECLSPEC: u32 = 17;
const B_HAS_WARNING: u32 = 18;
const B_IS_IDENTIFIER: u32 = 19;
const B_BUILDING_MODULE: u32 = 20;
const B_IS_TARGET_ARCH: u32 = 21;
const B_IS_TARGET_VENDOR: u32 = 22;
const B_IS_TARGET_OS: u32 = 23;
const B_IS_TARGET_ENVIRONMENT: u32 = 24;
const B_IS_TARGET_VARIANT_OS: u32 = 25;
const B_IS_TARGET_VARIANT_ENVIRONMENT: u32 = 26;
// `__FLT_EVAL_METHOD__`, a built-in in clang (a pragma can change it): defined, and absent from `-dM`. 0 on
// every target bindgen has (x86-64's SSE, AArch64, wasm32).
const B_FLT_EVAL_METHOD: u32 = 27;

const BUILTINS: []str = [
    "__FILE__",
    "__LINE__",
    "__COUNTER__",
    "__INCLUDE_LEVEL__",
    "__BASE_FILE__",
    "__DATE__",
    "__TIME__",
    "__TIMESTAMP__",
    "__FILE_NAME__",
    "__has_include",
    "__has_include_next",
    "__has_feature",
    "__has_extension",
    "__has_attribute",
    "__has_c_attribute",
    "__has_builtin",
    "__has_declspec_attribute",
    "__has_warning",
    "__is_identifier",
    "__building_module",
    "__is_target_arch",
    "__is_target_vendor",
    "__is_target_os",
    "__is_target_environment",
    "__is_target_variant_os",
    "__is_target_variant_environment",
    "__FLT_EVAL_METHOD__",
];

const KEYWORDS: []str = [
    "auto",
    "break",
    "case",
    "char",
    "const",
    "continue",
    "default",
    "do",
    "double",
    "else",
    "enum",
    "extern",
    "float",
    "for",
    "goto",
    "if",
    "inline",
    "int",
    "long",
    "register",
    "restrict",
    "return",
    "short",
    "signed",
    "sizeof",
    "static",
    "struct",
    "switch",
    "typedef",
    "union",
    "unsigned",
    "void",
    "volatile",
    "while",
    "_Alignas",
    "_Alignof",
    "_Atomic",
    "_Bool",
    "_Complex",
    "_Generic",
    "_Imaginary",
    "_Noreturn",
    "_Static_assert",
    "_Thread_local",
];

// Conditional states: low two bits, plus a bit once `#else` was seen.
const C_TAKE: u8 = 0;
const C_WAIT: u8 = 1;
const C_DONE: u8 = 2;
const C_ELSE: u8 = 4;

const OP_OROR: u32 = 0x7c7cu32;
const OP_ANDAND: u32 = 0x2626u32;
const OP_EQ: u32 = 0x3d3du32;
const OP_NE: u32 = 0x3d21u32;
const OP_LE: u32 = 0x3d3cu32;
const OP_GE: u32 = 0x3d3eu32;
const OP_SHL: u32 = 0x3c3cu32;
const OP_SHR: u32 = 0x3e3eu32;

/// An in-memory file: `path` is what an `#include` resolves to, `text` its contents.
pub struct VFile {
    pub path: String,
    pub text: String,
}

/// Search paths, in-memory files and macro text for one preprocessor.
pub struct PpConfig {
    pub quote_dirs: Vector<String>,
    pub dirs: Vector<String>,
    pub sys_dirs: Vector<String>,
    /// Apple framework directories, searched after `sys_dirs`: `Name/Header.h` is
    /// `<dir>/Name.framework/Headers/Header.h`, then `PrivateHeaders`.
    pub frameworks: Vector<String>,
    pub files: Vector<VFile>,
    pub predefs: String,
    pub cmdline: String,
    pub has: Vector<String>,
}

struct Tok {
    pub kind: u8,
    pub flags: u8,
    pub id: u32,
    pub line: u32,
    pub hide: u32,
}

// `param_count` counts the parameters, a variadic one included. `variadic` is 0, 1 (`...`) or 2 (`name...`). A `simple` body
// holds no parameter, `#`, `##` or `__VA_OPT__`, so an expansion copies it.
struct Macro {
    pub name: u32,
    pub kind: u8,
    pub variadic: u8,
    pub simple: bool,
    pub param_count: u32,
    pub params_start: u32,
    pub body_start: u32,
    pub body_len: u32,
}

struct FileInfo {
    pub start: u32,
    pub end: u32,
    pub guard: u32,
    pub once: bool,
}

struct Val {
    pub v: u64,
    pub u: bool,
}

// The class bits of each byte, for the lexer: one load per byte instead of a chain of compares.
const B_SPACE: u8 = 1; // horizontal space, a vertical tab, a form feed, a carriage return, a NUL
const B_START: u8 = 2; // starts an identifier
const B_DIGIT: u8 = 4;
const B_CMT: u8 = 8; // ends a run of a block comment's text: `*` or a newline
const CLS: [u8; 256] = classes();

const fn classes() [u8; 256] {
    let mut t = [0u8; 256];
    for i in 0..256usize {
        let c = i as u8;
        let mut k: u8 = 0;
        if c == b' ' || c == b'\t' || c == b'\r' || c == 0x0b || c == 0x0c || c == 0 {
            k = B_SPACE;
        } else if c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c == b'_' || c == b'$' || c >= 0x80 {
            k = B_START;
        } else if c >= b'0' && c <= b'9' {
            k = B_DIGIT;
        }
        if c == b'*' || c == b'\n' {
            k |= B_CMT;
        }
        // `i` stays below the 256 entries.
        unsafe {
            t[i] = k;
        }
    }
    return t;
}

// The end of the run from `i` of bytes with a class bit of `bits`: the first other offset, or `n`. A
// counted loop with no call runs strip-mined.
fn run_end(p: *const u8, i: usize, n: usize, bits: u8) usize {
    for k in i..n {
        if (unsafe CLS[(unsafe p[k]) as usize] & bits) == 0 {
            return k;
        }
    }
    return n;
}

// The end of the run from `i` of bytes with no class bit of `bits`, or `n`.
fn run_end_not(p: *const u8, i: usize, n: usize, bits: u8) usize {
    for k in i..n {
        if (unsafe CLS[(unsafe p[k]) as usize] & bits) != 0 {
            return k;
        }
    }
    return n;
}

// The CLS entry of `c`: a byte indexes the 256 entries in bounds.
const fn cls(c: u8) u8 {
    return unsafe CLS[c as usize];
}

const fn is_id_start(c: u8) bool {
    return (cls(c) & B_START) != 0;
}

const fn is_digit(c: u8) bool {
    return (cls(c) & B_DIGIT) != 0;
}

const fn is_id_body(c: u8) bool {
    return (cls(c) & (B_START | B_DIGIT)) != 0;
}

const fn is_punct_byte(c: u8) bool {
    return c > b' ' && c < 0x7f && !is_id_body(c) && c != b'\\' && c != b'@' && c != b'`';
}

// Whether `c` separates directories in a path on this host.
@platform(windows)
const fn is_separator(c: u8) bool {
    return c == b'/' || c == b'\\';
}

@platform(!windows)
const fn is_separator(c: u8) bool {
    return c == b'/';
}

@platform(windows)
const fn is_absolute_path(name: str) bool {
    return name.len() > 0 && is_separator(name.byte_at(0)) || name.len() > 2 && name.byte_at(1) == b':';
}

@platform(!windows)
const fn is_absolute_path(name: str) bool {
    return name.len() > 0 && name.byte_at(0) == b'/';
}

const fn pair_code(a: u8, b: u8) u32 {
    return a as u32 | b as u32 << 8;
}

// The Prosser-safe test for a pair of adjacent output tokens: whether printing them without a space would lex
// differently.
const fn needs_space(pk: u8, pl: u8, k: u8, f: u8) bool {
    if pk == K_OTHER || k == K_OTHER {
        return true;
    }
    let word = pk == K_IDENT || pk == K_NUM;
    if word && (k == K_IDENT || k == K_NUM || k == K_STR || k == K_CHAR) {
        return true;
    }
    if pk == K_NUM && k == K_PUNCT {
        return f == b'.' || (f == b'+' || f == b'-') && (pl == b'e' || pl == b'E' || pl == b'p' || pl == b'P');
    }
    if pk == K_PUNCT && pl == b'.' && k == K_NUM {
        return true;
    }
    if pk == K_PUNCT && k == K_PUNCT {
        let a = pl == b'+' || pl == b'-' || pl == b'<' || pl == b'>' || pl == b'&' || pl == b'|' || pl == b'=';
        let b = pl == b'!' || pl == b'*' || pl == b'/' || pl == b'%' || pl == b'^' || pl == b'#' || pl == b':';
        let c = pl == b'.';
        let g = f == b'+' || f == b'-' || f == b'<' || f == b'>' || f == b'&' || f == b'|' || f == b'=';
        let h = f == b'#' || f == b':' || f == b'.' || f == b'/' || f == b'*';
        return (a || b || c) && (g || h);
    }
    return false;
}

const fn exponent_before(p: *const u8, e: usize) bool {
    let c = unsafe p[e - 1];
    return c == b'e' || c == b'E' || c == b'p' || c == b'P';
}

const fn is_string_prefix(p: *const u8, n: usize) bool {
    let a = unsafe p[0];
    if n == 1 {
        return a == b'L' || a == b'u' || a == b'U';
    }
    return n == 2 && a == b'u' && unsafe p[1] == b'8';
}

// The end of the quoted literal that opens at `i`, or 0 when a newline or the end comes first.
const fn scan_quoted(p: *const u8, i: usize, n: usize) usize {
    let q = unsafe p[i];
    let mut j = i + 1;
    while j < n {
        let c = unsafe p[j];
        if c == q {
            return j + 1;
        }
        if c == b'\n' {
            return 0;
        }
        if c == b'\\' && j + 1 < n {
            j += 1;
        }
        j += 1;
    }
    return 0;
}

const fn punct_len(p: *const u8, i: usize) usize {
    let c = unsafe p[i];
    let d = unsafe p[i + 1];
    if c == b'.' {
        if d == b'.' && unsafe p[i + 2] == b'.' {
            return 3;
        }
        return 1;
    }
    if c == b'<' && (d == b':' || d == b'%') || c == b':' && d == b'>' || c == b'%' && d == b'>' {
        return 2;
    }
    if c == b'%' && d == b':' {
        if unsafe p[i + 2] == b'%' && unsafe p[i + 3] == b':' {
            return 4;
        }
        return 2;
    }
    if c == b'<' || c == b'>' {
        if d == c {
            if unsafe p[i + 2] == b'=' {
                return 3;
            }
            return 2;
        }
        if d == b'=' {
            return 2;
        }
        return 1;
    }
    if c == b'-' && (d == b'>' || d == b'-' || d == b'=') {
        return 2;
    }
    if c == b'+' && (d == b'+' || d == b'=') {
        return 2;
    }
    if c == b'&' && (d == b'&' || d == b'=') {
        return 2;
    }
    if c == b'|' && (d == b'|' || d == b'=') {
        return 2;
    }
    if c == b'#' && d == b'#' {
        return 2;
    }
    if (c == b'=' || c == b'!' || c == b'*' || c == b'/' || c == b'%' || c == b'^') && d == b'=' {
        return 2;
    }
    return 1;
}

// The first offset at or after `i` of a backslash that ends a physical line, or `n`.
fn find_splice(p: *const u8, i: usize, n: usize) usize {
    let mut j = i;
    // Each step passes one backslash: at most `n - i` steps.
    while j < n {
        let f = (unsafe memchr(p + j, b'\\', n - j)) as *const u8;
        if f == null {
            return n;
        }
        j = f as usize - p as usize;
        let d = unsafe p[j + 1];
        if d == b'\n' || d == b'\r' && unsafe p[j + 2] == b'\n' {
            return j;
        }
        j += 1;
    }
    return n;
}

// Spellings, interned once: the single bytes first, so a byte is its own id, then the fixed names.
fn names_new() nm::Names {
    let mut n = nm::Names::with_capacity(1 << 20, 1 << 14);
    n.intern("");
    for b in 1..256u32 {
        let c = b as u8;
        let id = n.intern(unsafe str::from_raw(&c, 1));
        assert_eq(id, b);
    }
    for k in 0..FIXED.len() {
        let id = n.intern(FIXED[k]);
        assert_eq(id, ID_ELLIPSIS + k as u32);
    }
    return n;
}

// Hide sets: sorted lists of macro names, hash-consed so a set is its id. Set 0 is empty.
struct Hides {
    pub off: Vector<u32>,
    pub data: Vector<u32>,
    pub tab: Vector<u32>,
    pub tmp: Vector<u32>,
    // Direct-mapped cache of merges: the same argument set is merged into every token of an expansion.
    pub memo_key: Vector<u64>,
    pub memo_set: Vector<u32>,
    pub add_key: Vector<u64>, // the same for `add`: (set, name)
    pub add_set: Vector<u32>,
}

const MEMO_SIZE: usize = 4096;

extend Hides {
    fn new() Hides {
        let mut tab = Vector::<u32>::new();
        tab.resize_default(1024);
        let mut off = Vector::<u32>::new();
        off.push(0);
        off.push(0);
        let mut memo_key = Vector::<u64>::new();
        memo_key.resize_default(MEMO_SIZE);
        let mut memo_set = Vector::<u32>::new();
        memo_set.resize_default(MEMO_SIZE);
        let mut add_key = Vector::<u64>::new();
        add_key.resize_default(MEMO_SIZE);
        let mut add_set = Vector::<u32>::new();
        add_set.resize_default(MEMO_SIZE);
        return Hides {
            add_key: add_key,
            add_set: add_set,
            off: off,
            data: Vector::<u32>::new(),
            tab: tab,
            tmp: Vector::<u32>::new(),
            memo_key: memo_key,
            memo_set: memo_set,
        };
    }

    const fn contains(self: &Hides, set: u32, name: u32) bool {
        if set == 0 {
            return false;
        }
        let e = self.off[set as usize + 1] as usize;
        let mut i = self.off[set as usize] as usize;
        while i < e {
            if self.data[i] == name {
                return true;
            }
            i += 1;
        }
        return false;
    }

    const fn same(self: &Hides, id: u32) bool {
        let s = self.off[id as usize] as usize;
        let e = self.off[id as usize + 1] as usize;
        if e - s != self.tmp.len() {
            return false;
        }
        for k in 0..self.tmp.len() {
            if self.data[s + k] != self.tmp[k] {
                return false;
            }
        }
        return true;
    }

    // The id of the set held in `tmp`, sorted and without repeats.
    fn make(self: &mut Hides) u32 {
        let n = self.tmp.len();
        if n == 0 {
            return 0;
        }
        let mut h: u64 = 0xcbf29ce484222325u64;
        for k in 0..n {
            h = (h ^ self.tmp[k] as u64).wrapping_mul(0x100000001b3u64);
        }
        let mask = self.tab.len() - 1;
        let mut i = h as usize & mask;
        let mut probes: usize = 0;
        while probes <= mask {
            let e = self.tab[i];
            if e == 0 {
                break;
            }
            if self.same(e - 1) {
                return e - 1;
            }
            i = i + 1 & mask;
            probes += 1;
        }
        assert(probes <= mask);
        let id = (self.off.len() - 1) as u32;
        for k in 0..n {
            self.data.push(self.tmp[k]);
        }
        self.off.push(self.data.len() as u32);
        self.tab[i] = id + 1;
        if self.off.len() * 2 > self.tab.len() {
            self.grow();
        }
        return id;
    }

    fn grow(self: &mut Hides) {
        let size = self.tab.len() * 2;
        let mut tab = Vector::<u32>::new();
        tab.resize_default(size);
        let mask = size - 1;
        for id in 1..self.off.len() - 1 {
            let s = self.off[id] as usize;
            let e = self.off[id + 1] as usize;
            let mut h: u64 = 0xcbf29ce484222325u64;
            for k in s..e {
                h = (h ^ self.data[k] as u64).wrapping_mul(0x100000001b3u64);
            }
            let mut i = h as usize & mask;
            while tab[i] != 0 {
                i = i + 1 & mask;
            }
            tab[i] = id as u32 + 1;
        }
        self.tab = tab;
    }

    fn add(self: &mut Hides, set: u32, name: u32) u32 {
        if self.contains(set, name) {
            return set;
        }
        let key = set as u64 << 32 | name as u64;
        let slot = (key.wrapping_mul(0x9E3779B97F4A7C15u64) >> 40) as usize & MEMO_SIZE - 1;
        if self.add_key[slot] == key {
            return self.add_set[slot];
        }
        self.tmp.clear();
        let s = self.off[set as usize] as usize;
        let e = self.off[set as usize + 1] as usize;
        let mut placed = false;
        for k in s..e {
            let v = self.data[k];
            if !placed && v > name {
                self.tmp.push(name);
                placed = true;
            }
            self.tmp.push(v);
        }
        if !placed {
            self.tmp.push(name);
        }
        let r = self.make();
        self.add_key[slot] = key;
        self.add_set[slot] = r;
        return r;
    }

    fn merge(self: &mut Hides, a: u32, b: u32) u32 {
        if a == b || b == 0 {
            return a;
        }
        if a == 0 {
            return b;
        }
        let key = a as u64 << 32 | b as u64;
        let slot = (key.wrapping_mul(0x9E3779B97F4A7C15u64) >> 40) as usize & MEMO_SIZE - 1;
        if self.memo_key[slot] == key {
            return self.memo_set[slot];
        }
        self.tmp.clear();
        let mut i = self.off[a as usize] as usize;
        let ie = self.off[a as usize + 1] as usize;
        let mut j = self.off[b as usize] as usize;
        let je = self.off[b as usize + 1] as usize;
        while i < ie || j < je {
            if j >= je || i < ie && self.data[i] < self.data[j] {
                self.tmp.push(self.data[i]);
                i += 1;
            } else if i >= ie || self.data[j] < self.data[i] {
                self.tmp.push(self.data[j]);
                j += 1;
            } else {
                self.tmp.push(self.data[i]);
                i += 1;
                j += 1;
            }
        }
        let r = self.make();
        self.memo_key[slot] = key;
        self.memo_set[slot] = r;
        return r;
    }

    fn intersect(self: &mut Hides, a: u32, b: u32) u32 {
        if a == b {
            return a;
        }
        if a == 0 || b == 0 {
            return 0;
        }
        self.tmp.clear();
        let mut i = self.off[a as usize] as usize;
        let ie = self.off[a as usize + 1] as usize;
        let mut j = self.off[b as usize] as usize;
        let je = self.off[b as usize + 1] as usize;
        while i < ie && j < je {
            if self.data[i] < self.data[j] {
                i += 1;
            } else if self.data[j] < self.data[i] {
                j += 1;
            } else {
                self.tmp.push(self.data[i]);
                i += 1;
                j += 1;
            }
        }
        return self.make();
    }
}

// Tokenise `text` (phases 1 to 3), appending to `toks`. The byte at `text[len]` and the `TEXT_PAD - 1` after
// it must be readable zeros. Returns 0, or the line of an unterminated comment.
fn tokenize(names: &mut nm::Names, text: str, toks: &mut Vector<Tok>) u32 {
    let n0 = text.len();
    let p0 = text.ptr();
    let first = find_splice(p0, 0, n0);
    if first == n0 {
        let none = Vector::<u32>::new();
        return lex(names, p0, n0, &none, toks);
    }
    let mut clean = String::with_capacity(n0 + TEXT_PAD);
    let mut cuts = Vector::<u32>::new();
    let mut at: usize = 0;
    let mut spelling = first;
    while spelling < n0 {
        clean.push_str(text.slice(at, spelling));
        cuts.push(clean.len() as u32);
        at = spelling + if unsafe p0[spelling + 1] == b'\r' {
            3;
        } else {
            2;
        };
        spelling = find_splice(p0, at, n0);
    }
    clean.push_str(text.slice(at, n0));
    clean.pad_nul(TEXT_PAD);
    return lex(names, clean.as_ptr(), clean.len(), &cuts, toks);
}

fn lex(names: &mut nm::Names, p: *const u8, n: usize, cuts: &Vector<u32>, toks: &mut Vector<Tok>) u32 {
    let mut i: usize = 0;
    let mut line: u32 = 1;
    let mut cut: usize = 0;
    let mut spc = false;
    let mut bol = true;
    let mut logical: u32 = 1;
    if n >= 3 && unsafe p[0] == 0xEF && unsafe p[1] == 0xBB && unsafe p[2] == 0xBF {
        i = 3;
    }
    while i < n {
        let c = unsafe p[i];
        if (cls(c) & B_SPACE) != 0 {
            i = run_end(p, i + 1, n, B_SPACE);
            spc = true;
            continue;
        }
        if c == b'\n' {
            line += 1;
            bol = true;
            spc = true;
            i += 1;
            continue;
        }
        if c == b'/' && unsafe p[i + 1] == b'*' {
            let mut j = i + 2;
            // Each step passes a run of text and one `*` or newline: at most `n - i` steps.
            loop {
                j = run_end_not(p, j, n, B_CMT);
                if j >= n || unsafe p[j] == b'*' && unsafe p[j + 1] == b'/' {
                    break;
                }
                if unsafe p[j] == b'\n' {
                    line += 1;
                }
                j += 1;
            }
            if j >= n {
                return line;
            }
            i = j + 2;
            spc = true;
            continue;
        }
        if c == b'/' && unsafe p[i + 1] == b'/' {
            let f = (unsafe memchr(p + i, b'\n', n - i)) as *const u8;
            i = if f == null {
                n;
            } else {
                f as usize - p as usize;
            };
            spc = true;
            continue;
        }
        while cut < cuts.len() && cuts[cut] as usize <= i {
            line += 1;
            cut += 1;
        }
        let mut e = i + 1;
        let mut kind = K_PUNCT;
        if is_id_start(c) {
            // The padding zero after the text ends an identifier at `n` at most.
            e = run_end(p, e, n, B_START | B_DIGIT);
            kind = K_IDENT;
            let q = unsafe p[e];
            if (q == b'"' || q == b'\'') && is_string_prefix(unsafe (p + i), e - i) {
                let quote_end = scan_quoted(p, e, n);
                if quote_end != 0 {
                    e = quote_end;
                    kind = if q == b'"' {
                        K_STR;
                    } else {
                        K_CHAR;
                    };
                }
            }
        } else if is_digit(c) || c == b'.' && is_digit(unsafe p[i + 1]) {
            kind = K_NUM;
            loop {
                let d = unsafe p[e];
                if is_id_body(d) || d == b'.' {
                    e += 1;
                } else if (d == b'+' || d == b'-') && exponent_before(p, e) {
                    e += 1;
                } else {
                    break;
                }
            }
        } else if c == b'"' || c == b'\'' {
            let quote_end = scan_quoted(p, i, n);
            if quote_end != 0 {
                e = quote_end;
                kind = if c == b'"' {
                    K_STR;
                } else {
                    K_CHAR;
                };
            } else {
                kind = K_OTHER;
            }
        } else if is_punct_byte(c) {
            e = i + punct_len(p, i);
        } else {
            kind = K_OTHER;
        }
        let id = if e == i + 1 {
            c as u32;
        } else {
            names.intern(unsafe str::from_raw(p + i, e - i));
        };
        let mut flags: u8 = 0;
        if spc {
            flags = F_SPC;
        }
        if bol {
            flags = flags | F_BOL;
            logical = line;
        } else if line != logical {
            flags = flags | F_CONT;
        }
        toks.push(Tok { kind: kind, flags: flags, id: id, line: line, hide: 0 });
        spc = false;
        bol = false;
        i = e;
    }
    return 0;
}

const fn is_punct(t: Tok, id: u32) bool {
    return t.kind == K_PUNCT && t.id == id;
}

// `#` and `##`, also in their digraph spellings `%:` and `%:%:`.
const fn is_hash(t: Tok) bool {
    return t.kind == K_PUNCT && (t.id == ID_HASH || t.id == ID_DIGRAPH_HASH);
}

const fn is_hashhash(t: Tok) bool {
    return t.kind == K_PUNCT && (t.id == ID_HASHHASH || t.id == ID_DIGRAPH_HASHHASH);
}

fn report(err: &mut String, file: str, line: u32, msg: str, quiet: bool) {
    err.clear();
    err.push_str(file);
    err.push_byte(b':');
    err.push_u64(line);
    err.push_str(": ");
    err.push_str(msg);
    if !quiet {
        err.eprintln();
    }
}

// Append the strings of `src` to `dst`, in order, without copying them.
fn move_all(dst: &mut Vector<String>, mut src: Vector<String>) {
    src.reverse();
    while let Some(s) = src.pop() {
        dst.push(s);
    }
}

fn push_escaped(out: &mut String, s: str) {
    for i in 0..s.len() {
        let c = s.byte_at(i);
        if c == b'"' || c == b'\\' {
            out.push_byte(b'\\');
        }
        out.push_byte(c);
    }
}

// The string literal of `toks[s..s + l]` as `#` spells it: one space where a token had white space, and a
// backslash before each quote and backslash inside a string or character literal. Placemarkers are skipped.
fn stringify_tokens(names: &mut nm::Names, tmp: &mut String, toks: &Vector<Tok>, s: usize, l: usize) u32 {
    tmp.clear();
    tmp.push_byte(b'"');
    let mut first = true;
    for k in s..s + l {
        let x = toks[k];
        if x.kind == K_PLACE {
            continue;
        }
        if !first && (x.flags & F_SPC) != 0 {
            tmp.push_byte(b' ');
        }
        first = false;
        let spelling = names.spell(x.id);
        if x.kind == K_STR || x.kind == K_CHAR {
            push_escaped(tmp, spelling);
        } else {
            tmp.push_str(spelling);
        }
    }
    // A final backslash that escapes nothing is dropped.
    let mut slashes: usize = 0;
    while slashes + 1 < tmp.len() && tmp.byte(tmp.len() - 1 - slashes) == b'\\' {
        slashes += 1;
    }
    if slashes % 2 == 1 {
        tmp.truncate(tmp.len() - 1);
    }
    tmp.push_byte(b'"');
    return names.intern(tmp.as_str());
}

// `__x__` becomes `x`, also on each side of a `::` scope.
fn push_attribute_name(out: &mut String, name: str) {
    let mut a: usize = 0;
    let n = name.len();
    loop {
        let mut e = a;
        while e < n && !(name.byte_at(e) == b':' && e + 1 < n && name.byte_at(e + 1) == b':') {
            e += 1;
        }
        let part = name.slice(a, e);
        if part.len() > 4 && part.starts_with("__") && part.ends_with("__") {
            out.push_str(part.slice(2, part.len() - 2));
        } else {
            out.push_str(part);
        }
        if e >= n {
            return;
        }
        out.push_str("::");
        a = e + 2;
    }
}

/// A C preprocessor over one configuration. `preprocess` may run more than once; macros persist.
pub struct Pp {
    search_dirs: Vector<String>,
    n_quote: usize,
    n_plain: usize, // the search directories before the framework directories
    memory_files: Vector<VFile>,
    memory_file_index: Map<String, u32>,
    predefs: String,
    cmdline: String,
    has: Set<String>,
    names: nm::Names,
    hides: Hides,
    macros: Vector<Macro>,
    macro_table: Vector<u32>,
    macro_params: Vector<u32>,
    macro_body: Vector<Tok>,
    toks: Vector<Tok>,
    files: Vector<FileInfo>,
    by_path: Map<String, u32>,
    by_ident: Map<String, u32>,
    pos: usize,
    end: usize,
    delta: i64,
    name: String,
    path: String,
    base: String,
    file_index: u32,
    dir: u32,
    cond_base: usize,
    depth: usize,
    conditions: Vector<u8>,
    file_names: Vector<String>,
    found_dir: u32,
    out_line: u32,
    at_bol: bool,
    marker_due: bool,
    last_kind: u8,
    last_byte: u8,
    arg_tokens: Vector<Tok>,
    arg_ranges: Vector<u32>,
    pool: Vector<Vector<Tok>>,
    expr: Vector<Tok>,
    expr_pos: usize,
    pushed_macros: Vector<u64>,
    tmp: String,
    cond_mode: bool,
    work: u64,
    expand_depth: u32,
    exp_end: u32,
    cont_line: u32,
    counter: u64,
    error_line: u32,
    failed: bool,
    /// The paths of the files read from disk, in the order of the first read.
    pub disk_paths: Vector<String>,
    /// Errors are kept in `err`, not printed.
    pub quiet: bool,
    primed: bool,
    in_args: bool,
    queried_seen: Set<String>,
    /// The `has` keys the run asked for, each once, in the order asked.
    pub queried: Vector<String>,
    pub err: String,
}

extend Pp {
    /// A preprocessor for `config`. Nothing runs until `preprocess`.
    pub fn new(mut config: PpConfig) Pp {
        let mut search_dirs = Vector::<String>::new();
        move_all(&mut search_dirs, replace(&mut config.quote_dirs, Vector::<String>::new()));
        let n_quote = search_dirs.len();
        move_all(&mut search_dirs, replace(&mut config.dirs, Vector::<String>::new()));
        move_all(&mut search_dirs, replace(&mut config.sys_dirs, Vector::<String>::new()));
        let n_plain = search_dirs.len();
        move_all(&mut search_dirs, replace(&mut config.frameworks, Vector::<String>::new()));
        let mut has = Set::<String>::new();
        let mut keys = replace(&mut config.has, Vector::<String>::new());
        keys.reverse();
        while let Some(key) = keys.pop() {
            has.insert(key);
        }
        let mut memory_files = replace(&mut config.files, Vector::<VFile>::new());
        let mut memory_file_index = Map::<String, u32>::new();
        for i in 0..memory_files.len() {
            memory_file_index.insert(memory_files[i].path.clone(), i as u32);
            memory_files[i].text.pad_nul(TEXT_PAD);
        }
        let mut tab = Vector::<u32>::new();
        tab.resize_default(4096);
        let mut pp = Pp {
            search_dirs: search_dirs,
            n_quote: n_quote,
            n_plain: n_plain,
            memory_files: memory_files,
            memory_file_index: memory_file_index,
            predefs: replace(&mut config.predefs, String::new()),
            cmdline: replace(&mut config.cmdline, String::new()),
            has: has,
            names: names_new(),
            hides: Hides::new(),
            macros: Vector::<Macro>::new(),
            macro_table: tab,
            macro_params: Vector::<u32>::new(),
            macro_body: Vector::<Tok>::new(),
            toks: Vector::<Tok>::with_capacity(1 << 16),
            files: Vector::<FileInfo>::new(),
            by_path: Map::<String, u32>::new(),
            by_ident: Map::<String, u32>::new(),
            pos: 0,
            end: 0,
            delta: 0,
            name: String::new(),
            path: String::new(),
            base: String::new(),
            file_index: NONE,
            dir: NONE,
            cond_base: 0,
            depth: 0,
            conditions: Vector::<u8>::new(),
            file_names: Vector::<String>::new(),
            found_dir: NONE,
            out_line: 1,
            at_bol: true,
            marker_due: false,
            last_kind: K_OTHER,
            last_byte: 0,
            arg_tokens: Vector::<Tok>::new(),
            arg_ranges: Vector::<u32>::new(),
            pool: Vector::<Vector<Tok>>::new(),
            expr: Vector::<Tok>::new(),
            expr_pos: 0,
            pushed_macros: Vector::<u64>::new(),
            tmp: String::new(),
            cond_mode: false,
            work: 0,
            expand_depth: 0,
            exp_end: 0,
            cont_line: NONE,
            counter: 0,
            error_line: 0,
            failed: false,
            disk_paths: Vector::<String>::new(),
            quiet: false,
            primed: false,
            in_args: false,
            queried_seen: Set::<String>::new(),
            queried: Vector::<String>::new(),
            err: String::new(),
        };
        for k in 0..BUILTINS.len() {
            let id = pp.names.intern(BUILTINS[k]);
            let idx = pp.macros.len() as u32;
            pp.macros.push(
                Macro {
                    name: id,
                    kind: M_BUILTIN,
                    variadic: 0,
                    simple: true,
                    param_count: k as u32 + 1,
                    params_start: 0,
                    body_start: 0,
                    body_len: 0,
                },
            );
            pp.set_macro(id, idx + 1);
        }
        return pp;
    }

    fn error(self: &mut Pp, msg: str) {
        if self.failed {
            return;
        }
        self.failed = true;
        report(&mut self.err, self.name.as_str(), self.error_line, msg, self.quiet);
    }

    fn take_vec(self: &mut Pp) Vector<Tok> {
        return switch self.pool.pop() {
            Some(v) => v,
            None => Vector::<Tok>::new(),
        };
    }

    fn give_vec(self: &mut Pp, mut v: Vector<Tok>) {
        v.clear();
        self.pool.push(v);
    }

    const fn macro_index(self: &Pp, id: u32) u32 {
        if id as usize < self.macro_table.len() {
            return self.macro_table[id as usize];
        }
        return 0;
    }

    fn set_macro(self: &mut Pp, id: u32, idx1: u32) {
        let need = self.names.count();
        while self.macro_table.len() < need {
            self.macro_table.push(0);
        }
        self.macro_table[id as usize] = idx1;
    }

    fn intern_tmp(self: &mut Pp) u32 {
        return self.names.intern(self.tmp.as_str());
    }

    // ---- Files -------------------------------------------------------------------------------------------

    // Tokenise `text` into a new cached file. None on an unterminated comment (reported against `path`).
    fn add_file(self: &mut Pp, text: str, path: str) Option<u32> {
        let start = self.toks.len();
        let error_line = tokenize(&mut self.names, text, &mut self.toks);
        if error_line != 0 {
            self.toks.truncate(start);
            self.failed = true;
            report(&mut self.err, path, error_line, "unterminated /* comment", self.quiet);
            return Option::<u32>::None;
        }
        let end = self.toks.len();
        let guard = self.detect_guard(start, end);
        self.file_names.push(String::from_str(path));
        let idx = self.files.len() as u32;
        self.files.push(FileInfo { start: start as u32, end: end as u32, guard: guard, once: false });
        return Option::<u32>::Some(idx);
    }

    // The macro G when the whole file is `#ifndef G`, `#define G ..`, a body and the matching `#endif`.
    const fn detect_guard(self: &Pp, start: usize, end: usize) u32 {
        if end < start + 6 {
            return NONE;
        }
        let t = &self.toks;
        let hash_token = t[start];
        let a = t[start + 1];
        let g = t[start + 2];
        if !(is_hash(hash_token) && a.kind == K_IDENT && a.id == ID_IFNDEF && g.kind == K_IDENT) {
            return NONE;
        }
        if (t[start + 3].flags & F_BOL) == 0 || !is_hash(t[start + 3]) {
            return NONE;
        }
        if t[start + 4].id != ID_DEFINE || t[start + 5].id != g.id || t[start + 4].kind != K_IDENT {
            return NONE;
        }
        let mut depth: u32 = 0;
        let mut i = start;
        while i < end {
            let x = t[i];
            if (x.flags & F_BOL) != 0 && is_hash(x) && i + 1 < end && t[i + 1].kind == K_IDENT {
                let d = t[i + 1].id;
                if d == ID_IF || d == ID_IFDEF || d == ID_IFNDEF {
                    depth += 1;
                } else if d == ID_ELSE || d == ID_ELIF || d == ID_ELIFDEF || d == ID_ELIFNDEF {
                    if depth == 1 {
                        return NONE;
                    }
                } else if d == ID_ENDIF {
                    depth -= 1;
                    if depth == 0 {
                        let mut j = i + 1;
                        while j < end {
                            if (t[j].flags & F_BOL) != 0 {
                                return NONE;
                            }
                            j += 1;
                        }
                        return g.id;
                    }
                }
            }
            i += 1;
        }
        return NONE;
    }

    // The cached file at `path`: an in-memory file first, then the disk. A second path to a file already read
    // (same device and index) reuses its tokens, and a path that holds no file is remembered as a miss, so a
    // search list is walked once per name.
    fn load(self: &mut Pp, path: str) Option<u32> {
        let key = String::from_str(path);
        if let Some(v) = self.by_path.get(&key) {
            if *v == NONE {
                return Option::<u32>::None;
            }
            return Option::<u32>::Some(*v);
        }
        let mut vfile_index = NONE;
        if let Some(v) = self.memory_file_index.get(&key) {
            vfile_index = *v;
        }
        let mut identity = key.clone();
        let mut disk = String::new();
        if vfile_index == NONE {
            // The identity of a regular file: two paths of one physical file give one key.
            let st = fs::stat(key.as_str());
            if st.is_err() {
                self.by_path.insert(key, NONE);
                return Option::<u32>::None;
            }
            let m = st.unwrap();
            if m.kind == fs::FileKind::Dir {
                self.by_path.insert(key, NONE);
                return Option::<u32>::None;
            }
            identity = format("\x01{}:{}", m.dev, m.ino);
        }
        if let Some(v) = self.by_ident.get(&identity) {
            let f = *v;
            self.by_path.insert(key, f);
            return Option::<u32>::Some(f);
        }
        let found: Option<u32>;
        if vfile_index != NONE {
            let text = replace(&mut self.memory_files[vfile_index as usize].text, String::new());
            found = self.add_file(text.as_str(), path);
            self.memory_files[vfile_index as usize].text = text;
        } else {
            if let Some(t) = loader::read_file(path) {
                disk = t;
            } else {
                self.failed = true;
                report(&mut self.err, path, 0, "cannot read file", self.quiet);
                return Option::<u32>::None;
            }
            disk.pad_nul(TEXT_PAD);
            self.disk_paths.push(String::from_str(path));
            found = self.add_file(disk.as_str(), path);
        }
        if let Some(f) = found {
            self.by_path.insert(key, f);
            self.by_ident.insert(identity, f);
        }
        return found;
    }

    fn join_path(dir: str, name: str, out: &mut String) {
        out.clear();
        out.push_str(dir);
        if dir.len() != 0 && !is_separator(dir.byte_at(dir.len() - 1)) {
            out.push_byte(b'/');
        }
        out.push_str(name);
    }

    // Search for an include. On success `found_dir` is the search directory that held it.
    fn find_include(self: &mut Pp, name: str, angled: bool, next: bool) Option<u32> {
        let absolute = is_absolute_path(name);
        let mut cand = String::new();
        if absolute {
            if let Some(f) = self.load(name) {
                self.found_dir = NONE;
                return Option::<u32>::Some(f);
            }
            return Option::<u32>::None;
        }
        let mut start: usize = if angled {
            self.n_quote;
        } else {
            0;
        };
        if next && self.dir != NONE {
            start = self.dir as usize + 1;
        } else if !angled && !next {
            let p = self.path.as_str();
            let mut cut = p.len();
            while cut > 0 && !is_separator(p.byte_at(cut - 1)) {
                cut -= 1;
            }
            // clang names the includer's own directory `.` when the includer has none: `./inc/h.h`.
            Pp::join_path(
                if cut == 0 {
                    ".";
                } else {
                    p.slice(0, cut);
                },
                name,
                &mut cand,
            );
            if let Some(f) = self.load(cand.as_str()) {
                self.found_dir = NONE;
                return Option::<u32>::Some(f);
            }
            if cut == 0 {
                if let Some(f) = self.load(name) {
                    self.found_dir = NONE;
                    return Option::<u32>::Some(f);
                }
            }
        }
        for i in start..self.search_dirs.len() {
            if self.failed {
                break;
            }
            if i < self.n_plain {
                Pp::join_path(self.search_dirs[i].as_str(), name, &mut cand);
                if let Some(f) = self.load(cand.as_str()) {
                    self.found_dir = i as u32;
                    return Option::<u32>::Some(f);
                }
            } else {
                let dir = self.search_dirs[i].clone();
                if let Some(f) = self.framework_header(dir.as_str(), name) {
                    self.found_dir = i as u32;
                    return Option::<u32>::Some(f);
                }
            }
        }
        // As clang does last: a header of a subframework of the framework that holds the includer
        // (`<Sub/H.h>` from `<dir>/X.framework/Headers/..` is `<dir>/X.framework/Frameworks/Sub.framework/Headers/H.h`).
        let fw = self.path.as_str().find(".framework/");
        if fw >= 0 && !self.failed {
            let outer = String::from_str(self.path.as_str().slice(0, fw as usize + 10));
            Pp::join_path(outer.as_str(), "Frameworks", &mut cand);
            let sub = cand.clone();
            if let Some(f) = self.framework_header(sub.as_str(), name) {
                self.found_dir = NONE;
                return Option::<u32>::Some(f);
            }
        }
        return Option::<u32>::None;
    }

    // `Name/Header.h` in framework directory `dir`: `Name.framework/Headers/Header.h`, then
    // `Name.framework/PrivateHeaders/Header.h`. None for a name without a directory part.
    fn framework_header(self: &mut Pp, dir: str, name: str) Option<u32> {
        let slash = name.find_byte(b'/');
        if slash <= 0 {
            return Option::<u32>::None;
        }
        let k = slash as usize;
        let mut cand = String::new();
        for sub in ["Headers", "PrivateHeaders"] {
            cand.clear();
            cand.format_into("{}/{}.framework/{}/{}", dir, name.slice(0, k), sub, name.slice(k + 1, name.len()));
            if let Some(f) = self.load(cand.as_str()) {
                return Option::<u32>::Some(f);
            }
            if self.failed {
                break;
            }
        }
        return Option::<u32>::None;
    }

    // ---- Output ------------------------------------------------------------------------------------------

    fn marker(self: &mut Pp, line: u32, flag: u32, out: &mut String) {
        if !self.at_bol {
            out.push_byte(b'\n');
        }
        out.push_str("# ");
        out.push_u64(line);
        out.push_str(" \"");
        push_escaped(out, self.name.as_str());
        out.push_byte(b'"');
        if flag != 0 {
            out.push_byte(b' ');
            out.push_u64(flag);
        }
        out.push_byte(b'\n');
        self.out_line = line;
        self.at_bol = true;
        self.marker_due = false;
    }

    // Bring the output to `line`: nothing when it is there, newlines for a short gap, else a marker.
    fn sync(self: &mut Pp, line: u32, out: &mut String) {
        if !self.marker_due && line == self.out_line {
            return;
        }
        if !self.at_bol {
            out.push_byte(b'\n');
            self.out_line += 1;
            self.at_bol = true;
        }
        if !self.marker_due && line >= self.out_line && line - self.out_line <= 8 {
            while self.out_line < line {
                out.push_byte(b'\n');
                self.out_line += 1;
            }
        } else {
            self.marker(line, 0, out);
        }
    }

    fn flush(self: &mut Pp, sink: &mut Vector<Tok>, out: &mut String) {
        for k in 0..sink.len() {
            let t = sink[k];
            if (t.flags & F_CONT) == 0 || t.kind == K_PRAGMA {
                self.sync(t.line, out);
            }
            if t.kind == K_PRAGMA {
                if !self.at_bol {
                    self.marker(t.line, 0, out);
                }
                out.push_str("#pragma ");
                out.push_str(self.names.spell(t.id));
                out.push_byte(b'\n');
                self.out_line += 1;
                self.at_bol = true;
                continue;
            }
            let s = self.names.spell(t.id);
            // A `#` first on an output line would read as a directive: clang indents it.
            if self.at_bol && is_hash(t) {
                out.push_byte(b' ');
            } else if !self.at_bol && ((t.flags & F_SPC) != 0 || needs_space(
                self.last_kind,
                self.last_byte,
                t.kind,
                s.byte_at(0),
            )) {
                out.push_byte(b' ');
            }
            out.push_str(s);
            self.at_bol = false;
            self.last_kind = t.kind;
            self.last_byte = s.byte_at(s.len() - 1);
        }
        sink.clear();
    }

    // ---- Driver ------------------------------------------------------------------------------------------

    /// Preprocess the file `path` into `out` as `cc -E` prints it. False after an error, reported on stderr
    /// as `file:line: message` and kept in `err`.
    pub fn preprocess(self: &mut Pp, path: str, out: &mut String) bool {
        self.failed = false;
        self.err.clear();
        if !self.primed {
            self.primed = true;
            let mut scratch = String::new();
            let predefs = replace(&mut self.predefs, String::new());
            self.run_text("<built-in>", predefs.as_str(), &mut scratch);
            let cmdline = replace(&mut self.cmdline, String::new());
            self.run_text("<command line>", cmdline.as_str(), &mut scratch);
        }
        self.base = String::from_str(path);
        if self.failed {
            return false;
        }
        self.at_bol = out.len() == 0 || out.byte(out.len() - 1) == b'\n';
        self.out_line = 1;
        self.last_kind = K_OTHER;
        let main = self.load(path);
        if main.is_some() {
            let first = self.file_names[main.unwrap() as usize].clone();
            self.run_file(main.unwrap(), first.as_str(), NONE, NONE, out);
        } else if !self.failed {
            self.failed = true;
            report(&mut self.err, path, 0, "cannot open file", self.quiet);
        }
        if !self.at_bol {
            out.push_byte(b'\n');
            self.at_bol = true;
        }
        return !self.failed;
    }

    fn run_text(self: &mut Pp, name: str, text: str, out: &mut String) {
        let mut t = String::from_str(text);
        t.pad_nul(TEXT_PAD);
        if let Some(f) = self.add_file(t.as_str(), name) {
            self.run_file(f, name, NONE, NONE, out);
        }
    }

    // Run one file as the current file. `ret_line` is the parent line the output returns to, or NONE.
    fn run_file(self: &mut Pp, file_index: u32, path: str, dir: u32, ret_line: u32, out: &mut String) {
        let info = self.files[file_index as usize];
        let saved_name = replace(&mut self.name, String::from_str(path));
        let saved_path = replace(&mut self.path, String::from_str(path));
        let saved_pos = self.pos;
        let saved_end = self.end;
        let saved_delta = self.delta;
        let saved_fidx = self.file_index;
        let saved_dir = self.dir;
        let saved_base = self.cond_base;
        self.pos = info.start as usize;
        self.end = info.end as usize;
        self.delta = 0;
        self.file_index = file_index;
        self.dir = dir;
        self.cond_base = self.conditions.len();
        self.cont_line = NONE;
        self.depth += 1;
        self.marker(1, 1, out);
        self.process(out);
        self.depth -= 1;
        self.conditions.truncate(self.cond_base);
        self.name = saved_name;
        self.path = saved_path;
        self.pos = saved_pos;
        self.end = saved_end;
        self.delta = saved_delta;
        self.file_index = saved_fidx;
        self.dir = saved_dir;
        self.cond_base = saved_base;
        self.cont_line = NONE;
        if ret_line != NONE {
            self.marker(ret_line, 2, out);
        }
    }

    const fn skipping(self: &Pp) bool {
        return self.conditions.len() > 0 && (self.conditions[self.conditions.len() - 1] & 3) != C_TAKE;
    }

    const fn fix_line(self: &Pp, t: Tok) Tok {
        let mut r = t;
        r.line = (t.line as i64 + self.delta) as u32;
        return r;
    }

    // Move to the next directive: the rest of a skipped group holds no token that matters.
    const fn skip_group(self: &mut Pp) {
        while self.pos < self.end && !self.at_directive() {
            self.pos += 1;
        }
    }

    const fn skip_group_if_skipping(self: &mut Pp) {
        if self.skipping() {
            self.skip_group();
        }
    }

    const fn at_directive(self: &Pp) bool {
        let t = self.toks[self.pos];
        return (t.flags & F_BOL) != 0 && is_hash(t);
    }

    fn process(self: &mut Pp, out: &mut String) {
        let mut st = self.take_vec();
        let mut sink = self.take_vec();
        while self.pos < self.end && !self.failed {
            if self.skipping() {
                self.skip_group();
                if self.pos >= self.end {
                    break;
                }
                self.directive(&mut sink, out);
                continue;
            }
            let raw = self.toks[self.pos];
            if (raw.flags & F_BOL) != 0 {
                self.cont_line = NONE;
            }
            if (raw.flags & F_BOL) != 0 && is_hash(raw) {
                self.flush(&mut sink, out);
                self.directive(&mut sink, out);
                continue;
            }
            self.pos += 1;
            let mut t = self.fix_line(raw);
            if t.line == self.cont_line {
                t.flags = t.flags | F_CONT;
            }
            if t.kind == K_IDENT && (self.macro_index(t.id) != 0 || t.id == ID_PRAGMA_OP) {
                self.error_line = t.line;
                self.work = 0;
                st.push(t);
                self.expand(&mut st, true, &mut sink);
                st.clear();
            } else {
                sink.push(t);
            }
            if sink.len() >= FLUSH_AT {
                self.flush(&mut sink, out);
            }
        }
        self.flush(&mut sink, out);
        if !self.failed && self.conditions.len() > self.cond_base {
            self.error_line = if self.end > 0 {
                self.fix_line(self.toks[self.end - 1]).line;
            } else {
                1;
            };
            self.error("unterminated conditional directive");
        }
        self.give_vec(st);
        self.give_vec(sink);
    }

    // ---- Directives --------------------------------------------------------------------------------------

    fn push_cond(self: &mut Pp, state: u8) {
        if self.conditions.len() >= COND_DEPTH_MAX {
            self.error("conditional directives nest too deeply");
            return;
        }
        self.conditions.push(state);
    }

    // The tokens `tokens_start..tokens_end` of a directive, macro-expanded in `cond` mode or not, into `sink`.
    fn expand_range(self: &mut Pp, tokens_start: usize, tokens_end: usize, cond: bool, sink: &mut Vector<Tok>) {
        let mut st = self.take_vec();
        let mut k = tokens_end;
        while k > tokens_start {
            k -= 1;
            let mut t = self.toks[k];
            t.flags = t.flags & F_SPC;
            t.line = self.error_line;
            st.push(t);
        }
        self.work = 0;
        self.cond_mode = cond;
        self.expand(&mut st, false, sink);
        self.cond_mode = false;
        self.give_vec(st);
    }

    fn eval_if(self: &mut Pp, tokens_start: usize, tokens_end: usize) bool {
        let mut sink = self.take_vec();
        self.expand_range(tokens_start, tokens_end, true, &mut sink);
        let old = replace(&mut self.expr, sink);
        self.expr_pos = 0;
        let r = if self.failed {
            false;
        } else {
            self.expr_top();
        };
        let used = replace(&mut self.expr, old);
        self.give_vec(used);
        return r;
    }

    // `#ifdef` and `#ifndef`: whether the name at `tokens_start` is defined.
    fn name_defined(self: &mut Pp, tokens_start: usize, tokens_end: usize) bool {
        if tokens_start >= tokens_end {
            self.error("macro name missing");
            return false;
        }
        let t = self.toks[tokens_start];
        if t.kind != K_IDENT {
            self.error("macro name must be an identifier");
            return false;
        }
        return self.macro_index(t.id) != 0;
    }

    fn directive(self: &mut Pp, sink: &mut Vector<Tok>, out: &mut String) {
        let tokens_start = self.pos + 1;
        let hash_line = self.toks[self.pos].line;
        let mut tokens_end = tokens_start;
        while tokens_end < self.end && (self.toks[tokens_end].flags & F_BOL) == 0 {
            tokens_end += 1;
        }
        self.pos = tokens_end;
        self.error_line = (hash_line as i64 + self.delta) as u32;
        let skipping = self.skipping();
        if tokens_start == tokens_end {
            return;
        }
        let name_token = self.toks[tokens_start];
        if name_token.kind != K_IDENT {
            if name_token.kind == K_NUM && !skipping {
                self.do_line(tokens_start, tokens_end, true);
            } else if !skipping {
                self.error("invalid preprocessing directive");
            }
            return;
        }
        let name_id = name_token.id;
        let a = tokens_start + 1;
        if name_id == ID_IF {
            if skipping {
                self.push_cond(C_DONE);
            } else {
                let v = self.eval_if(a, tokens_end);
                self.push_cond(
                    if v {
                        C_TAKE;
                    } else {
                        C_WAIT;
                    },
                );
            }
        } else if name_id == ID_IFDEF || name_id == ID_IFNDEF {
            if skipping {
                self.push_cond(C_DONE);
            } else {
                let d = self.name_defined(a, tokens_end);
                self.push_cond(
                    if d == (name_id == ID_IFDEF) {
                        C_TAKE;
                    } else {
                        C_WAIT;
                    },
                );
            }
        } else if name_id == ID_ELIF || name_id == ID_ELIFDEF || name_id == ID_ELIFNDEF {
            self.do_elif(name_id, a, tokens_end);
        } else if name_id == ID_ELSE {
            if self.conditions.len() <= self.cond_base {
                self.error("#else without #if");
                return;
            }
            let k = self.conditions.len() - 1;
            let s = self.conditions[k];
            if (s & C_ELSE) != 0 {
                self.error("#else after #else");
                return;
            }
            self.conditions[k] = if (s & 3) == C_WAIT {
                C_TAKE;
            } else if (s & 3) == C_TAKE {
                C_DONE;
            } else {
                s & 3;
            } | C_ELSE;
        } else if name_id == ID_ENDIF {
            if self.conditions.len() <= self.cond_base {
                self.error("#endif without #if");
                return;
            }
            self.conditions.truncate(self.conditions.len() - 1);
        } else if skipping {
            return;
        } else if name_id == ID_DEFINE {
            self.do_define(tokens_start, tokens_end);
        } else if name_id == ID_UNDEF {
            if a >= tokens_end || self.toks[a].kind != K_IDENT {
                self.error("macro name must be an identifier");
                return;
            }
            let id = self.toks[a].id;
            if self.macro_index(id) != 0 {
                self.set_macro(id, 0);
            }
        } else if name_id == ID_INCLUDE || name_id == ID_INCLUDE_NEXT || name_id == ID_IMPORT {
            if self.in_args {
                self.error("embedding a #include directive within macro arguments is not supported");
                return;
            }
            self.flush(sink, out);
            self.do_include(a, tokens_end, name_id == ID_INCLUDE_NEXT, name_id == ID_IMPORT, out);
        } else if name_id == ID_LINE {
            self.do_line(a, tokens_end, false);
        } else if name_id == ID_ERROR {
            self.tmp.clear();
            self.tmp.push_str("#error");
            for k in a..tokens_end {
                self.tmp.push_byte(b' ');
                self.tmp.push_str(self.names.spell(self.toks[k].id));
            }
            let msg = self.tmp.clone();
            self.error(msg.as_str());
        } else if name_id == ID_PRAGMA {
            self.do_pragma(a, tokens_end, sink, out);
        } else if name_id == ID_WARNING || name_id == ID_IDENT || name_id == ID_SCCS || name_id == ID_ASSERT || name_id == ID_UNASSERT {
            return;
        } else {
            self.error("invalid preprocessing directive");
        }
    }

    fn do_elif(self: &mut Pp, name_id: u32, a: usize, tokens_end: usize) {
        if self.conditions.len() <= self.cond_base {
            self.error("#elif without #if");
            return;
        }
        let k = self.conditions.len() - 1;
        let s = self.conditions[k];
        if (s & C_ELSE) != 0 {
            self.error("#elif after #else");
            return;
        }
        if (s & 3) == C_TAKE {
            self.conditions[k] = C_DONE;
        } else if (s & 3) == C_WAIT {
            let mut v = false;
            if name_id == ID_ELIF {
                v = self.eval_if(a, tokens_end);
            } else {
                v = self.name_defined(a, tokens_end) == (name_id == ID_ELIFDEF);
            }
            self.conditions[k] = if v {
                C_TAKE;
            } else {
                C_WAIT;
            };
        }
    }

    const fn param_index(self: &Pp, params_start: usize, param_count: usize, id: u32) u32 {
        for q in 0..param_count {
            if self.macro_params[params_start + q] == id {
                return q as u32;
            }
        }
        return NONE;
    }

    fn do_define(self: &mut Pp, tokens_start: usize, tokens_end: usize) {
        if tokens_start + 1 >= tokens_end {
            self.error("macro name missing");
            return;
        }
        let name_token = self.toks[tokens_start + 1];
        if name_token.kind != K_IDENT {
            self.error("macro name must be an identifier");
            return;
        }
        if name_token.id == ID_DEFINED {
            self.error("'defined' cannot be used as a macro name");
            return;
        }
        let mut k = tokens_start + 2;
        let params_start = self.macro_params.len();
        let mut kind = M_OBJ;
        let mut variadic: u8 = 0;
        if k < tokens_end && is_punct(self.toks[k], ID_LPAREN) && (self.toks[k].flags & F_SPC) == 0 {
            kind = M_FUNC;
            k += 1;
            let mut first = true;
            let mut closed = false;
            while k < tokens_end && !closed {
                let t = self.toks[k];
                if first && is_punct(t, ID_RPAREN) {
                    k += 1;
                    closed = true;
                    continue;
                }
                if is_punct(t, ID_ELLIPSIS) {
                    variadic = 1;
                    self.macro_params.push(ID_VA_ARGS);
                    k += 1;
                } else if t.kind == K_IDENT {
                    let param_count = self.macro_params.len() - params_start;
                    if self.param_index(params_start, param_count, t.id) != NONE {
                        self.macro_params.truncate(params_start);
                        self.error("duplicate macro parameter");
                        return;
                    }
                    self.macro_params.push(t.id);
                    k += 1;
                    if k < tokens_end && is_punct(self.toks[k], ID_ELLIPSIS) {
                        variadic = 2;
                        k += 1;
                    }
                } else {
                    self.macro_params.truncate(params_start);
                    self.error("invalid macro parameter list");
                    return;
                }
                first = false;
                if k >= tokens_end {
                    break;
                }
                if is_punct(self.toks[k], ID_RPAREN) {
                    k += 1;
                    closed = true;
                } else if is_punct(self.toks[k], ID_COMMA) && variadic == 0 {
                    k += 1;
                } else {
                    self.macro_params.truncate(params_start);
                    self.error("invalid macro parameter list");
                    return;
                }
            }
            if !closed {
                self.macro_params.truncate(params_start);
                self.error("missing ')' in macro parameter list");
                return;
            }
        }
        let param_count = self.macro_params.len() - params_start;
        let body_start = self.macro_body.len();
        let mut simple = true;
        let mut j = k;
        while j < tokens_end {
            let mut t = self.toks[j];
            t.flags = t.flags & F_SPC;
            t.line = 0;
            if j == k {
                t.flags = 0;
            }
            let mut bad = "";
            if kind == M_FUNC && t.kind == K_IDENT {
                let param_pos = self.param_index(params_start, param_count, t.id);
                if param_pos != NONE {
                    t.kind = K_PARAM;
                    t.id = param_pos;
                    simple = false;
                } else if variadic != 0 && t.id == ID_VA_OPT {
                    t.kind = K_VAOPT;
                    simple = false;
                    if j + 1 >= tokens_end || !is_punct(self.toks[j + 1], ID_LPAREN) {
                        bad = "missing '(' after __VA_OPT__";
                    } else {
                        let mut depth: u32 = 0;
                        let mut close = tokens_end;
                        let mut q = j + 1;
                        while q < tokens_end && close == tokens_end {
                            if is_punct(self.toks[q], ID_LPAREN) {
                                depth += 1;
                            } else if is_punct(self.toks[q], ID_RPAREN) {
                                depth -= 1;
                                if depth == 0 {
                                    close = q;
                                }
                            }
                            q += 1;
                        }
                        if close > j + 2 && close < tokens_end {
                            if is_hashhash(self.toks[j + 2]) {
                                bad = "'##' cannot appear at start of __VA_OPT__ argument";
                            } else if is_hashhash(self.toks[close - 1]) {
                                bad = "'##' cannot appear at end of __VA_OPT__ argument";
                            }
                        }
                    }
                }
            } else if is_hashhash(t) {
                t.kind = K_PASTE;
                simple = false;
                if j == k || j + 1 == tokens_end {
                    bad = "'##' cannot appear at either end of a macro expansion";
                }
            } else if kind == M_FUNC && is_hash(t) {
                t.kind = K_STRINGIFY;
                simple = false;
                let named = j + 1 < tokens_end && self.toks[j + 1].kind == K_IDENT;
                let is_param = named && self.param_index(params_start, param_count, self.toks[j + 1].id) != NONE;
                let is_group = named && variadic != 0 && self.toks[j + 1].id == ID_VA_OPT;
                if !is_param && !is_group {
                    bad = "'#' is not followed by a macro parameter";
                }
            }
            if bad.len() != 0 {
                self.macro_body.truncate(body_start);
                self.macro_params.truncate(params_start);
                self.error(bad);
                return;
            }
            self.macro_body.push(t);
            j += 1;
        }
        let idx = self.macros.len() as u32;
        self.macros.push(
            Macro {
                name: name_token.id,
                kind: kind,
                variadic: variadic,
                simple: simple,
                param_count: param_count as u32,
                params_start: params_start as u32,
                body_start: body_start as u32,
                body_len: (self.macro_body.len() - body_start) as u32,
            },
        );
        self.set_macro(name_token.id, idx + 1);
    }

    // The header named by `v`: 1 for "x", 2 for <x>, 0 when it is neither. The name goes to `name`.
    fn header_name(self: &Pp, v: &Vector<Tok>, name: &mut String) u32 {
        name.clear();
        if v.len() == 0 {
            return 0;
        }
        let t = v[0];
        if t.kind == K_STR {
            let s = self.names.spell(t.id);
            if s.byte_at(0) != b'"' || s.len() < 2 {
                return 0;
            }
            name.push_str(s.slice(1, s.len() - 1));
            return 1;
        }
        if !is_punct(t, b'<') {
            return 0;
        }
        for k in 1..v.len() {
            let x = v[k];
            if is_punct(x, b'>') {
                return 2;
            }
            if k > 1 && (x.flags & F_SPC) != 0 {
                name.push_byte(b' ');
            }
            name.push_str(self.names.spell(x.id));
        }
        return 0;
    }

    fn do_include(self: &mut Pp, a: usize, tokens_end: usize, next: bool, once: bool, out: &mut String) {
        let mut v = self.take_vec();
        if a < tokens_end && (self.toks[a].kind == K_STR || is_punct(self.toks[a], b'<')) {
            for k in a..tokens_end {
                v.push(self.toks[k]);
            }
        } else {
            self.expand_range(a, tokens_end, false, &mut v);
        }
        let mut name = String::new();
        let kind = self.header_name(&v, &mut name);
        self.give_vec(v);
        if self.failed {
            return;
        }
        if kind == 0 {
            self.error("expected \"FILENAME\" or <FILENAME>");
            return;
        }
        let ret = (self.toks[tokens_end - 1].line as i64 + self.delta + 1) as u32;
        let found = self.find_include(name.as_str(), kind == 2, next);
        if self.failed {
            return;
        }
        if found.is_none() {
            let mut msg = String::new();
            msg.format_into("'{}' file not found", name.as_str());
            self.error(msg.as_str());
            return;
        }
        let f = found.unwrap();
        let info = self.files[f as usize];
        if info.once || info.guard != NONE && self.macro_index(info.guard) != 0 {
            return;
        }
        if once {
            self.files[f as usize].once = true;
        }
        if self.depth >= INCLUDE_DEPTH_MAX {
            self.error("#include nested too deeply");
            return;
        }
        let path = self.file_names[f as usize].clone();
        let dir = self.found_dir;
        self.run_file(f, path.as_str(), dir, ret, out);
    }

    // `#line N "file"` and the GNU `# N "file" flags`.
    fn do_line(self: &mut Pp, a: usize, tokens_end: usize, marker: bool) {
        let mut v = self.take_vec();
        if marker {
            for k in a..tokens_end {
                v.push(self.toks[k]);
            }
        } else {
            self.expand_range(a, tokens_end, false, &mut v);
        }
        let mut n: u64 = 0;
        let mut ok = v.len() > 0 && v[0].kind == K_NUM;
        if ok {
            let s = self.names.spell(v[0].id);
            for i in 0..s.len() {
                let c = s.byte_at(i);
                if !is_digit(c) || n > 4294967295 {
                    ok = false;
                    break;
                }
                n = n * 10 + (c - b'0') as u64;
            }
        }
        if !ok || self.failed {
            self.give_vec(v);
            self.error("#line directive requires a positive integer argument");
            return;
        }
        if v.len() > 1 {
            let t = v[1];
            let s = self.names.spell(t.id);
            if t.kind != K_STR || s.byte_at(0) != b'"' {
                self.give_vec(v);
                self.error("invalid filename for #line directive");
                return;
            }
            let mut f = String::new();
            let mut i: usize = 1;
            while i + 1 < s.len() {
                if s.byte_at(i) == b'\\' && i + 2 < s.len() {
                    i += 1;
                }
                f.push_byte(s.byte_at(i));
                i += 1;
            }
            self.name = f;
            self.marker_due = true;
        }
        self.give_vec(v);
        let next_phys = self.toks[tokens_end - 1].line as i64 + 1;
        self.delta = n as i64 - next_phys;
        self.marker_due = true;
    }

    // The effect of a pragma given as tokens: `once` is consumed (true), `push_macro` and `pop_macro` run and
    // are kept in the output.
    fn pragma_effect(self: &mut Pp, v: &Vector<Tok>) bool {
        if v.len() == 0 || v[0].kind != K_IDENT {
            return false;
        }
        let id = v[0].id;
        if id == ID_ONCE {
            self.files[self.file_index as usize].once = true;
            return true;
        }
        if (id == ID_PUSH_MACRO || id == ID_POP_MACRO) && v.len() > 3 && v[2].kind == K_STR {
            let quoted = String::from_str(self.names.spell(v[2].id));
            let nid = self.names.intern(quoted.as_str().slice(1, quoted.len() - 1));
            let cur = self.macro_index(nid);
            if id == ID_PUSH_MACRO {
                self.pushed_macros.push(nid as u64 << 32 | cur as u64);
            } else {
                let mut k = self.pushed_macros.len();
                while k > 0 {
                    k -= 1;
                    if (self.pushed_macros[k] >> 32) as u32 == nid {
                        self.set_macro(nid, (self.pushed_macros[k] & 0xFFFFFFFFu64) as u32);
                        self.pushed_macros.remove(k);
                        break;
                    }
                }
            }
        }
        return false;
    }

    fn do_pragma(self: &mut Pp, a: usize, tokens_end: usize, sink: &mut Vector<Tok>, out: &mut String) {
        if self.in_args {
            self.error("embedding a #pragma directive within macro arguments is not supported");
            return;
        }
        let mut v = self.take_vec();
        for k in a..tokens_end {
            v.push(self.toks[k]);
        }
        if !self.pragma_effect(&v) {
            self.tmp.clear();
            for k in 0..v.len() {
                if k > 0 && (v[k].flags & F_SPC) != 0 {
                    self.tmp.push_byte(b' ');
                }
                self.tmp.push_str(self.names.spell(v[k].id));
            }
            let id = self.intern_tmp();
            sink.push(Tok { kind: K_PRAGMA, flags: F_BOL, id: id, line: self.error_line, hide: 0 });
            self.flush(sink, out);
        }
        self.give_vec(v);
    }

    // ---- Expansion ---------------------------------------------------------------------------------------

    const fn file_ready(self: &Pp) bool {
        if self.pos >= self.end {
            return false;
        }
        return !self.at_directive();
    }

    fn next_tok(self: &mut Pp, st: &mut Vector<Tok>, from_file: bool) Option<Tok> {
        if st.len() > 0 {
            let k = st.len() - 1;
            let t = st[k];
            st.truncate(k);
            return Option::<Tok>::Some(t);
        }
        if !from_file {
            return Option::<Tok>::None;
        }
        // Inside the arguments of a macro call a directive is processed, as clang does.
        while self.in_args && self.pos < self.end && self.at_directive() && !self.failed {
            let mut unused_sink = self.take_vec();
            let mut unused_out = String::new();
            self.directive(&mut unused_sink, &mut unused_out);
            self.give_vec(unused_sink);
            self.skip_group_if_skipping();
        }
        if !self.failed && self.file_ready() {
            let t = self.toks[self.pos];
            self.pos += 1;
            return Option::<Tok>::Some(self.fix_line(t));
        }
        return Option::<Tok>::None;
    }

    // The next token; on the end of the source an error, and a `K_OTHER` token.
    fn need_tok(self: &mut Pp, st: &mut Vector<Tok>, from_file: bool) Tok {
        if let Some(t) = self.next_tok(st, from_file) {
            return t;
        }
        self.error("unterminated macro invocation");
        return Tok { kind: K_OTHER, flags: 0, id: 0, line: self.error_line, hide: 0 };
    }

    const fn lparen_next(self: &Pp, st: &Vector<Tok>, from_file: bool) bool {
        if st.len() > 0 {
            return is_punct(st[st.len() - 1], ID_LPAREN);
        }
        return from_file && self.file_ready() && is_punct(self.toks[self.pos], ID_LPAREN);
    }

    fn expand(self: &mut Pp, st: &mut Vector<Tok>, from_file: bool, sink: &mut Vector<Tok>) {
        self.expand_depth += 1;
        if self.expand_depth > EXPAND_DEPTH_MAX {
            self.error("macro arguments nest too deeply");
            self.expand_depth -= 1;
            return;
        }
        let saved_end = self.exp_end;
        while st.len() > 0 && !self.failed {
            let k = st.len() - 1;
            let t = st[k];
            st.truncate(k);
            self.work += 1;
            if self.work > WORK_MAX {
                self.error("macro expansion exceeds the work limit");
                break;
            }
            if t.kind != K_IDENT {
                sink.push(t);
                continue;
            }
            if t.id == ID_PRAGMA_OP {
                self.expand_pragma_op(t, st, from_file, sink);
                continue;
            }
            if t.id == ID_DEFINED && self.cond_mode {
                self.expand_defined(t, st, from_file, sink);
                continue;
            }
            let macro_slot = self.macro_index(t.id);
            if macro_slot == 0 || self.hides.contains(t.hide, t.id) {
                sink.push(t);
                continue;
            }
            let m = self.macros[macro_slot as usize - 1];
            if m.kind == M_BUILTIN {
                self.expand_builtin(m.param_count, t, st, from_file, sink);
            } else if m.kind == M_OBJ {
                self.expand_object(m, t, st);
            } else {
                self.expand_function(m, t, st, from_file, sink);
            }
        }
        self.exp_end = saved_end;
        self.expand_depth -= 1;
    }

    fn expand_object(self: &mut Pp, m: Macro, t: Tok, st: &mut Vector<Tok>) {
        if t.hide == 0 {
            self.exp_end = t.line;
        }
        let new_hide = self.hides.add(t.hide, t.id);
        let mut res = self.take_vec();
        if m.simple {
            for i in 0..m.body_len {
                res.push(self.macro_body[(m.body_start + i) as usize]);
            }
        } else {
            self.substitute(&m, 0, m.body_len, self.arg_ranges.len(), &mut res);
        }
        self.push_result(&mut res, t, new_hide, st);
        self.give_vec(res);
    }

    // Push `res` on `st` so its first token pops first: each token gets the hide set, the line and the spacing
    // of the macro name `t`; placemarkers go.
    fn push_result(self: &mut Pp, res: &mut Vector<Tok>, t: Tok, new_hide: u32, st: &mut Vector<Tok>) {
        let base = st.len();
        let mut k = res.len();
        self.work += k as u64;
        while k > 0 {
            k -= 1;
            let mut x = res[k];
            if x.kind == K_PLACE {
                continue;
            }
            x.hide = if x.hide == 0 {
                new_hide;
            } else {
                self.hides.merge(x.hide, new_hide);
            };
            // An argument token that began a source line keeps that: clang starts a new output line there, at the
            // line of the macro name.
            x.line = t.line;
            if (x.flags & F_BOL) != 0 {
                x.flags = x.flags & (F_SPC | F_BOL);
            } else {
                x.flags = x.flags & F_SPC | t.flags & F_CONT;
            }
            st.push(x);
        }
        if st.len() > base {
            let top = st.len() - 1;
            st[top].flags = t.flags & (F_SPC | F_CONT | F_BOL);
            st[top].line = t.line;
        }
    }

    fn expand_function(self: &mut Pp, m: Macro, t: Tok, st: &mut Vector<Tok>, from_file: bool, sink: &mut Vector<Tok>) {
        if !self.lparen_next(st, from_file) {
            sink.push(t);
            return;
        }
        let _ = self.next_tok(st, from_file);
        let tokens_base = self.arg_tokens.len();
        let ranges_base = self.arg_ranges.len();
        let close_paren = self.collect_args(&m, st, from_file);
        if self.failed {
            self.arg_tokens.truncate(tokens_base);
            self.arg_ranges.truncate(ranges_base);
            return;
        }
        let both = self.hides.intersect(t.hide, close_paren.hide);
        let new_hide = self.hides.add(both, t.id);
        let mut res = self.take_vec();
        if m.simple {
            for i in 0..m.body_len {
                res.push(self.macro_body[(m.body_start + i) as usize]);
            }
        } else {
            self.substitute(&m, 0, m.body_len, ranges_base, &mut res);
        }
        self.arg_tokens.truncate(tokens_base);
        self.arg_ranges.truncate(ranges_base);
        // `__LINE__` in the result reports the closing parenthesis of the outermost invocation; the result
        // itself prints where the macro name was.
        if t.hide == 0 || close_paren.hide == 0 {
            self.exp_end = close_paren.line;
        }
        if close_paren.hide == 0 && from_file && close_paren.line != t.line {
            self.cont_line = close_paren.line;
        }
        self.push_result(&mut res, t, new_hide, st);
        self.give_vec(res);
    }

    fn finish_arg(self: &mut Pp, start: usize) {
        self.arg_ranges.push(start as u32);
        self.arg_ranges.push((self.arg_tokens.len() - start) as u32);
        self.arg_ranges.push(NONE);
        self.arg_ranges.push(0);
    }

    // Read the arguments after `(` into `arg_tokens` and `arg_ranges` (four words each: start, length, and the start and
    // length of the expanded form, NONE until needed). An omitted variable argument has start NONE. Returns the
    // closing `)`.
    fn collect_args(self: &mut Pp, m: &Macro, st: &mut Vector<Tok>, from_file: bool) Tok {
        let saved = self.in_args;
        self.in_args = from_file;
        let closed = self.collect_args_in(m, st, from_file);
        self.in_args = saved;
        return closed;
    }

    fn collect_args_in(self: &mut Pp, m: &Macro, st: &mut Vector<Tok>, from_file: bool) Tok {
        let param_count = m.param_count as usize;
        let ranges_base = self.arg_ranges.len();
        let mut depth: u32 = 0;
        let mut start = self.arg_tokens.len();
        let mut given: usize = 0;
        let mut closed = Tok { kind: K_OTHER, flags: 0, id: 0, line: self.error_line, hide: 0 };
        let mut done = false;
        while !done {
            let t = self.need_tok(st, from_file);
            if self.failed {
                return closed;
            }
            self.work += 1;
            if self.work > WORK_MAX {
                self.error("macro expansion exceeds the work limit");
                return closed;
            }
            if is_punct(t, ID_LPAREN) {
                depth += 1;
                self.arg_tokens.push(t);
            } else if is_punct(t, ID_RPAREN) {
                if depth == 0 {
                    done = true;
                    closed = t;
                } else {
                    depth -= 1;
                    self.arg_tokens.push(t);
                }
            } else if is_punct(t, ID_COMMA) && depth == 0 && !(m.variadic != 0 && given + 1 == param_count) {
                self.finish_arg(start);
                start = self.arg_tokens.len();
                given += 1;
            } else {
                self.arg_tokens.push(t);
            }
        }
        self.finish_arg(start);
        given += 1;
        let mut bad = "";
        if param_count == 0 {
            if given == 1 && self.arg_ranges[ranges_base + 1] == 0 {
                self.arg_ranges.truncate(ranges_base);
            } else {
                bad = "too many arguments provided to function-like macro invocation";
            }
        } else if m.variadic == 0 {
            if given > param_count {
                bad = "too many arguments provided to function-like macro invocation";
            } else if given < param_count {
                bad = "too few arguments provided to function-like macro invocation";
            }
        } else if given + 1 == param_count {
            self.finish_arg(self.arg_tokens.len());
            let o = self.arg_ranges.len() - 4;
            self.arg_ranges[o] = NONE;
        } else if param_count == 1 && self.arg_ranges[ranges_base + 1] == 0 {
            self.arg_ranges[ranges_base] = NONE;
        } else if given < param_count {
            bad = "too few arguments provided to function-like macro invocation";
        }
        if bad.len() != 0 {
            self.error(bad);
        }
        return closed;
    }

    // The expanded form of argument `p` as (start, length) in `arg_tokens`; an argument with nothing to expand is
    // its own expansion.
    fn arg_expanded(self: &mut Pp, ranges_base: usize, p: usize) (usize, usize) {
        let o = ranges_base + 4 * p;
        if self.arg_ranges[o + 2] != NONE {
            return self.arg_ranges[o + 2] as usize, self.arg_ranges[o + 3] as usize;
        }
        let s = self.arg_ranges[o] as usize;
        let l = self.arg_ranges[o + 1] as usize;
        let mut need = false;
        for k in s..s + l {
            let x = self.arg_tokens[k];
            if x.kind == K_IDENT && (self.macro_index(x.id) != 0 && !self.hides.contains(x.hide, x.id) || x.id == ID_PRAGMA_OP || self.cond_mode && x.id == ID_DEFINED) {
                need = true;
                break;
            }
        }
        if !need {
            self.arg_ranges[o + 2] = s as u32;
            self.arg_ranges[o + 3] = l as u32;
            return s, l;
        }
        let mut st2 = self.take_vec();
        let mut sink2 = self.take_vec();
        let mut k = s + l;
        while k > s {
            k -= 1;
            st2.push(self.arg_tokens[k]);
        }
        self.expand(&mut st2, false, &mut sink2);
        let expanded_start = self.arg_tokens.len();
        let expanded_len = sink2.len();
        for k in 0..expanded_len {
            self.arg_tokens.push(sink2[k]);
        }
        self.give_vec(st2);
        self.give_vec(sink2);
        self.arg_ranges[o + 2] = expanded_start as u32;
        self.arg_ranges[o + 3] = expanded_len as u32;
        return expanded_start, expanded_len;
    }

    // Append argument `p` to `res`. A raw argument that is empty leaves a placemarker.
    fn append_arg(self: &mut Pp, ranges_base: usize, p: usize, expanded: bool, spc: u8, res: &mut Vector<Tok>) {
        let mut s = self.arg_ranges[ranges_base + 4 * p] as usize;
        let mut l = self.arg_ranges[ranges_base + 4 * p + 1] as usize;
        if expanded {
            let (expanded_start, expanded_len) = self.arg_expanded(ranges_base, p);
            s = expanded_start;
            l = expanded_len;
        }
        if l == 0 {
            if !expanded {
                res.push(Tok { kind: K_PLACE, flags: spc, id: 0, line: 0, hide: 0 });
            }
            return;
        }
        for k in 0..l {
            let mut x = self.arg_tokens[s + k];
            if k == 0 {
                x.flags = spc;
            }
            res.push(x);
        }
    }

    // `#` applied to the operand at body index `i + 1`: an argument, or the `__VA_OPT__` group. Returns the
    // string token and the body index after the operand.
    fn stringify_operand(self: &mut Pp, m: &Macro, i: u32, hi: u32, ranges_base: usize) (Tok, u32) {
        let operand = self.macro_body[(m.body_start + i + 1) as usize];
        let mut next = i + 2;
        let id: u32;
        if operand.kind == K_VAOPT {
            let mut group = self.take_vec();
            next = self.subst_vaopt(m, i + 1, hi, ranges_base, &mut group);
            id = stringify_tokens(&mut self.names, &mut self.tmp, &group, 0, group.len());
            self.give_vec(group);
        } else {
            let p = operand.id as usize;
            let s = self.arg_ranges[ranges_base + 4 * p] as usize;
            let l = self.arg_ranges[ranges_base + 4 * p + 1] as usize;
            id = stringify_tokens(&mut self.names, &mut self.tmp, &self.arg_tokens, s, l);
        }
        return Tok { kind: K_STR, flags: 0, id: id, line: 0, hide: 0 }, next;
    }

    fn glue(self: &mut Pp, l: Tok, r: Tok) Option<Tok> {
        if l.kind == K_PLACE {
            let mut x = r;
            x.flags = l.flags & F_SPC;
            return Option::<Tok>::Some(x);
        }
        if r.kind == K_PLACE {
            return Option::<Tok>::Some(l);
        }
        self.tmp.clear();
        self.tmp.push_str(self.names.spell(l.id));
        self.tmp.push_str(self.names.spell(r.id));
        self.tmp.pad_nul(TEXT_PAD);
        let mut pasted = self.take_vec();
        let error_line = tokenize(&mut self.names, self.tmp.as_str(), &mut pasted);
        let ok = error_line == 0 && pasted.len() == 1;
        let mut x = l;
        if ok {
            x = pasted[0];
            x.flags = l.flags & F_SPC;
            x.line = l.line;
            x.hide = self.hides.intersect(l.hide, r.hide);
        }
        self.give_vec(pasted);
        if !ok {
            return Option::<Tok>::None;
        }
        return Option::<Tok>::Some(x);
    }

    const fn vaopt_close(self: &Pp, m: &Macro, i: u32, hi: u32) u32 {
        let mut depth: u32 = 0;
        let mut j = i + 1;
        while j < hi {
            let b = self.macro_body[(m.body_start + j) as usize];
            if is_punct(b, ID_LPAREN) {
                depth += 1;
            } else if is_punct(b, ID_RPAREN) {
                depth -= 1;
                if depth == 0 {
                    return j;
                }
            }
            j += 1;
        }
        return hi;
    }

    // `__VA_OPT__ ( .. )` at body index `i`: its tokens when the variable arguments expand to something, else a
    // placemarker. Returns the index after the `)`.
    fn subst_vaopt(self: &mut Pp, m: &Macro, i: u32, hi: u32, ranges_base: usize, res: &mut Vector<Tok>) u32 {
        let close = self.vaopt_close(m, i, hi);
        let (_es, expanded_len) = self.arg_expanded(ranges_base, (m.param_count - 1) as usize);
        if expanded_len > 0 {
            self.substitute(m, i + 2, close, ranges_base, res);
        } else {
            res.push(Tok { kind: K_PLACE, flags: 0, id: 0, line: 0, hide: 0 });
        }
        return close + 1;
    }

    // The `##` at body index `i`: join the last token of `res` with the first token of its right operand.
    // Returns the index after the operand.
    fn subst_paste(self: &mut Pp, m: &Macro, i: u32, hi: u32, ranges_base: usize, res: &mut Vector<Tok>) u32 {
        let j = i + 1;
        let r = self.macro_body[(m.body_start + j) as usize];
        let mut right = self.take_vec();
        let mut next = j + 1;
        if r.kind == K_PARAM {
            let p = r.id as usize;
            let comma = res.len() > 0 && is_punct(res[res.len() - 1], ID_COMMA);
            if comma && m.variadic != 0 && r.id + 1 == m.param_count {
                if self.arg_ranges[ranges_base + 4 * p] == NONE {
                    res.truncate(res.len() - 1);
                } else {
                    self.append_arg(ranges_base, p, false, r.flags & F_SPC, res);
                }
                self.give_vec(right);
                return next;
            }
            self.append_arg(ranges_base, p, false, r.flags & F_SPC, &mut right);
        } else if r.kind == K_VAOPT {
            next = self.subst_vaopt(m, j, hi, ranges_base, &mut right);
        } else if r.kind == K_STRINGIFY {
            let (mut x, after) = self.stringify_operand(m, j, hi, ranges_base);
            x.flags = r.flags & F_SPC;
            right.push(x);
            next = after;
        } else {
            right.push(r);
        }
        if right.len() == 0 {
            right.push(Tok { kind: K_PLACE, flags: 0, id: 0, line: 0, hide: 0 });
        }
        let mut lhs = Tok { kind: K_PLACE, flags: 0, id: 0, line: 0, hide: 0 };
        if res.len() > 0 {
            lhs = res[res.len() - 1];
            res.truncate(res.len() - 1);
        }
        if let Some(g) = self.glue(lhs, right[0]) {
            res.push(g);
            for k in 1..right.len() {
                res.push(right[k]);
            }
        } else {
            let mut msg = String::new();
            msg.format_into(
                "pasting \"{}\" and \"{}\" does not give a valid preprocessing token",
                self.names.spell(lhs.id),
                self.names.spell(right[0].id),
            );
            self.error(msg.as_str());
        }
        self.give_vec(right);
        return next;
    }

    // Substitute the body tokens `lo..hi` of `m` into `res`, with the arguments at `ranges_base` in `arg_ranges`.
    fn substitute(self: &mut Pp, m: &Macro, lo: u32, hi: u32, ranges_base: usize, res: &mut Vector<Tok>) {
        let mut i = lo;
        while i < hi && !self.failed {
            let b = self.macro_body[(m.body_start + i) as usize];
            if b.kind == K_STRINGIFY {
                let (mut x, after) = self.stringify_operand(m, i, hi, ranges_base);
                x.flags = b.flags & F_SPC;
                res.push(x);
                i = after;
            } else if b.kind == K_PARAM {
                let paste = i + 1 < hi && self.macro_body[(m.body_start + i + 1) as usize].kind == K_PASTE;
                self.append_arg(ranges_base, b.id as usize, !paste, b.flags & F_SPC, res);
                i += 1;
            } else if b.kind == K_VAOPT {
                i = self.subst_vaopt(m, i, hi, ranges_base, res);
            } else if b.kind == K_PASTE {
                i = self.subst_paste(m, i, hi, ranges_base, res);
            } else {
                res.push(b);
                i += 1;
            }
        }
    }

    // `defined X` and `defined(X)` inside an `#if`.
    fn expand_defined(self: &mut Pp, t: Tok, st: &mut Vector<Tok>, from_file: bool, sink: &mut Vector<Tok>) {
        let mut a = self.need_tok(st, from_file);
        let paren = is_punct(a, ID_LPAREN);
        if paren {
            a = self.need_tok(st, from_file);
        }
        if self.failed {
            return;
        }
        if a.kind != K_IDENT {
            self.error("operator 'defined' requires an identifier");
            return;
        }
        if paren {
            let c = self.need_tok(st, from_file);
            if !self.failed && !is_punct(c, ID_RPAREN) {
                self.error("missing ')' after 'defined'");
                return;
            }
        }
        let d = self.macro_index(a.id) != 0;
        sink.push(
            Tok {
                kind: K_NUM,
                flags: t.flags & (F_SPC | F_CONT),
                id: if d {
                    49;
                } else {
                    48;
                },
                line: t.line,
                hide: 0,
            },
        );
    }

    // `_Pragma("text")` becomes a pragma token.
    fn expand_pragma_op(self: &mut Pp, t: Tok, st: &mut Vector<Tok>, from_file: bool, sink: &mut Vector<Tok>) {
        let a = self.need_tok(st, from_file);
        let s = self.need_tok(st, from_file);
        let c = self.need_tok(st, from_file);
        if self.failed {
            return;
        }
        if !is_punct(a, ID_LPAREN) || s.kind != K_STR || !is_punct(c, ID_RPAREN) {
            self.error("_Pragma takes a parenthesized string literal");
            return;
        }
        let spelling = self.names.spell(s.id);
        let mut i = spelling.find_byte(b'"') as usize + 1;
        self.tmp.clear();
        while i + 1 < spelling.len() {
            if spelling.byte_at(i) == b'\\' && i + 2 < spelling.len() {
                i += 1;
            }
            self.tmp.push_byte(spelling.byte_at(i));
            i += 1;
        }
        let id = self.intern_tmp();
        let mut v = self.take_vec();
        self.tmp.pad_nul(TEXT_PAD);
        let _ = tokenize(&mut self.names, self.tmp.as_str(), &mut v);
        if !self.pragma_effect(&v) {
            sink.push(Tok { kind: K_PRAGMA, flags: 0, id: id, line: t.line, hide: 0 });
        }
        self.give_vec(v);
    }

    fn expand_builtin(self: &mut Pp, code: u32, t: Tok, st: &mut Vector<Tok>, from_file: bool, sink: &mut Vector<Tok>) {
        if code >= B_HAS_INCLUDE && code != B_FLT_EVAL_METHOD {
            self.expand_query(code, t, st, from_file, sink);
            return;
        }
        let mut r = Tok { kind: K_NUM, flags: t.flags & (F_SPC | F_CONT), id: 0, line: t.line, hide: t.hide };
        self.tmp.clear();
        if code == B_FLT_EVAL_METHOD {
            self.tmp.push_byte(b'0');
        } else if code == B_LINE {
            self.tmp.push_u64(
                if t.hide != 0 {
                    self.exp_end;
                } else {
                    t.line;
                },
            );
        } else if code == B_COUNTER {
            self.tmp.push_u64(self.counter);
            self.counter += 1;
        } else if code == B_LEVEL {
            self.tmp.push_u64(self.depth as u64 - 1);
        } else if code == B_FILE || code == B_BASE || code == B_FILE_NAME {
            r.kind = K_STR;
            self.tmp.push_byte(b'"');
            if code == B_FILE {
                push_escaped(&mut self.tmp, self.name.as_str());
            } else if code == B_BASE {
                push_escaped(&mut self.tmp, self.base.as_str());
            } else {
                let full = self.name.as_str();
                let mut cut = full.len();
                while cut > 0 && !is_separator(full.byte_at(cut - 1)) {
                    cut -= 1;
                }
                push_escaped(&mut self.tmp, full.slice(cut, full.len()));
            }
            self.tmp.push_byte(b'"');
        } else {
            r.kind = K_STR;
            if code == B_DATE {
                self.tmp.push_str("\"Jan  1 1970\"");
            } else if code == B_TIME {
                self.tmp.push_str("\"00:00:00\"");
            } else {
                assert_eq(code, B_TIMESTAMP);
                self.tmp.push_str("\"Thu Jan  1 00:00:00 1970\"");
            }
        }
        r.id = self.intern_tmp();
        sink.push(r);
    }

    // `__has_include(..)`, `__has_feature(..)` and the other query operators.
    fn expand_query(self: &mut Pp, code: u32, t: Tok, st: &mut Vector<Tok>, from_file: bool, sink: &mut Vector<Tok>) {
        let open = self.need_tok(st, from_file);
        if !self.failed && !is_punct(open, ID_LPAREN) {
            self.error("missing '(' after a __has_ operator");
            return;
        }
        let mut args = self.take_vec();
        let mut depth: u32 = 1;
        while depth > 0 && !self.failed {
            let x = self.need_tok(st, from_file);
            if is_punct(x, ID_LPAREN) {
                depth += 1;
            } else if is_punct(x, ID_RPAREN) {
                depth -= 1;
            }
            if depth > 0 {
                args.push(x);
            }
        }
        if self.failed {
            self.give_vec(args);
            return;
        }
        let mut value = false;
        if code == B_HAS_INCLUDE || code == B_HAS_INCLUDE_NEXT {
            if args.len() > 0 && args[0].kind == K_IDENT {
                let mut st2 = self.take_vec();
                let mut k = args.len();
                while k > 0 {
                    k -= 1;
                    st2.push(args[k]);
                }
                args.clear();
                self.expand(&mut st2, false, &mut args);
                self.give_vec(st2);
            }
            let mut name = String::new();
            let kind = self.header_name(&args, &mut name);
            if kind == 0 {
                self.error("expected \"FILENAME\" or <FILENAME>");
            } else {
                value = self.find_include(name.as_str(), kind == 2, code == B_HAS_INCLUDE_NEXT).is_some();
            }
        } else if code != B_HAS_WARNING && code != B_BUILDING_MODULE {
            let mut key = String::new();
            if code == B_HAS_FEATURE {
                key.push_str("feature:");
            } else if code == B_HAS_EXTENSION {
                key.push_str("extension:");
            } else if code == B_HAS_ATTRIBUTE {
                key.push_str("attribute:");
            } else if code == B_HAS_C_ATTRIBUTE {
                key.push_str("c_attribute:");
            } else if code == B_HAS_BUILTIN {
                key.push_str("builtin:");
            } else if code == B_HAS_DECLSPEC {
                key.push_str("declspec_attribute:");
            } else if code == B_IS_TARGET_ARCH {
                key.push_str("target_arch:");
            } else if code == B_IS_TARGET_VENDOR {
                key.push_str("target_vendor:");
            } else if code == B_IS_TARGET_OS {
                key.push_str("target_os:");
            } else if code == B_IS_TARGET_ENVIRONMENT {
                key.push_str("target_environment:");
            } else if code == B_IS_TARGET_VARIANT_OS {
                key.push_str("target_variant_os:");
            } else if code == B_IS_TARGET_VARIANT_ENVIRONMENT {
                key.push_str("target_variant_environment:");
            } else {
                key.push_str("keyword:");
            }
            self.tmp.clear();
            for k in 0..args.len() {
                self.tmp.push_str(self.names.spell(args[k].id));
            }
            if code == B_IS_IDENTIFIER {
                let mut reserved = false;
                for k in 0..KEYWORDS.len() {
                    reserved = reserved || self.tmp.as_str() == KEYWORDS[k];
                }
                key.push_str(self.tmp.as_str());
                value = args.len() == 1 && args[0].kind == K_IDENT && !reserved && !self.has.contains(&key);
            } else {
                if code == B_HAS_BUILTIN || code >= B_IS_TARGET_ARCH {
                    key.push_str(self.tmp.as_str());
                } else {
                    push_attribute_name(&mut key, self.tmp.as_str());
                }
                value = self.has.contains(&key);
                if !self.queried_seen.contains(&key) {
                    self.queried_seen.insert(key.clone());
                    self.queried.push(key);
                }
            }
        }
        self.give_vec(args);
        sink.push(
            Tok {
                kind: K_NUM,
                flags: t.flags & (F_SPC | F_CONT),
                id: if value {
                    49;
                } else {
                    48;
                },
                line: t.line,
                hide: 0,
            },
        );
    }

    // ---- #if expressions ---------------------------------------------------------------------------------

    fn expr_top(self: &mut Pp) bool {
        if self.expr.len() == 0 {
            self.error("#if with no expression");
            return false;
        }
        let v = self.expr_comma(true, 0);
        if !self.failed && self.expr_pos < self.expr.len() {
            self.error("unexpected token in preprocessor expression");
        }
        return v.v != 0;
    }

    // The operator at the cursor as its bytes (`pair_code` for two), or 0.
    const fn expr_op(self: &Pp) u32 {
        if self.expr_pos >= self.expr.len() {
            return 0;
        }
        let t = self.expr[self.expr_pos];
        if t.kind != K_PUNCT {
            return 0;
        }
        let s = self.names.spell(t.id);
        if s.len() == 1 {
            return s.byte_at(0);
        }
        if s.len() == 2 {
            return pair_code(s.byte_at(0), s.byte_at(1));
        }
        return 0;
    }

    fn expr_comma(self: &mut Pp, live: bool, depth: u32) Val {
        let mut v = self.expr_cond(live, depth);
        while !self.failed && self.expr_op() == b',' as u32 {
            self.expr_pos += 1;
            v = self.expr_cond(live, depth);
        }
        return v;
    }

    fn expr_cond(self: &mut Pp, live: bool, depth: u32) Val {
        let c = self.expr_bin(1, live, depth);
        if self.failed || self.expr_op() != b'?' as u32 {
            return c;
        }
        if depth > EXPR_DEPTH_MAX {
            self.error("preprocessor expression nests too deeply");
            return c;
        }
        self.expr_pos += 1;
        let a = self.expr_comma(live && c.v != 0, depth + 1);
        if self.failed || self.expr_op() != b':' as u32 {
            self.error("expected ':' in conditional expression");
            return c;
        }
        self.expr_pos += 1;
        let b = self.expr_cond(live && c.v == 0, depth + 1);
        return Val {
            v: if c.v != 0 {
                a.v;
            } else {
                b.v;
            },
            u: a.u || b.u,
        };
    }

    fn expr_bin(self: &mut Pp, minp: i32, live: bool, depth: u32) Val {
        let mut lhs = self.expr_unary(live, depth);
        while !self.failed {
            let op = self.expr_op();
            let prec = op_prec(op);
            if prec == 0 || prec < minp {
                break;
            }
            self.expr_pos += 1;
            let mut live2 = live;
            if op == OP_ANDAND {
                live2 = live && lhs.v != 0;
            } else if op == OP_OROR {
                live2 = live && lhs.v == 0;
            }
            let rhs = self.expr_bin(prec + 1, live2, depth);
            lhs = self.expr_apply(op, lhs, rhs, live);
        }
        return lhs;
    }

    fn expr_apply(self: &mut Pp, op: u32, a: Val, b: Val, live: bool) Val {
        let u = a.u || b.u;
        let sa = a.v as i64;
        let sb = b.v as i64;
        if op == OP_ANDAND {
            return Val { v: (a.v != 0 && b.v != 0) as u64, u: false };
        }
        if op == OP_OROR {
            return Val { v: (a.v != 0 || b.v != 0) as u64, u: false };
        }
        if op == OP_EQ {
            return Val { v: (a.v == b.v) as u64, u: false };
        }
        if op == OP_NE {
            return Val { v: (a.v != b.v) as u64, u: false };
        }
        if op == b'<' as u32 || op == b'>' as u32 || op == OP_LE || op == OP_GE {
            let lt = if u {
                a.v < b.v;
            } else {
                sa < sb;
            };
            let gt = if u {
                a.v > b.v;
            } else {
                sa > sb;
            };
            let mut r = !lt;
            if op == b'<' as u32 {
                r = lt;
            } else if op == b'>' as u32 {
                r = gt;
            } else if op == OP_LE {
                r = !gt;
            }
            return Val { v: r as u64, u: false };
        }
        if op == OP_SHL || op == OP_SHR {
            let mut left = op == OP_SHL;
            let mut n = b.v;
            if !b.u && sb < 0 {
                left = !left;
                n = 0u64.wrapping_sub(b.v);
            }
            if left {
                if n >= 64 {
                    return Val { v: 0, u: a.u };
                }
                return Val { v: a.v << n, u: a.u };
            }
            if n >= 64 {
                if a.u || sa >= 0 {
                    return Val { v: 0, u: a.u };
                }
                return Val { v: 0xFFFFFFFFFFFFFFFFu64, u: a.u };
            }
            if a.u {
                return Val { v: a.v >> n, u: true };
            }
            return Val { v: (sa >> n as i64) as u64, u: false };
        }
        if op == b'+' as u32 {
            return Val { v: a.v.wrapping_add(b.v), u: u };
        }
        if op == b'-' as u32 {
            return Val { v: a.v.wrapping_sub(b.v), u: u };
        }
        if op == b'*' as u32 {
            return Val { v: a.v.wrapping_mul(b.v), u: u };
        }
        if op == b'&' as u32 {
            return Val { v: a.v & b.v, u: u };
        }
        if op == b'|' as u32 {
            return Val { v: a.v | b.v, u: u };
        }
        if op == b'^' as u32 {
            return Val { v: a.v ^ b.v, u: u };
        }
        assert(op == b'/' as u32 || op == b'%' as u32);
        let div = op == b'/' as u32;
        if b.v == 0 {
            if live {
                self.error("division by zero in preprocessor expression");
            }
            return Val { v: 0, u: u };
        }
        if u {
            return Val {
                v: if div {
                    a.v / b.v;
                } else {
                    a.v % b.v;
                },
                u: true,
            };
        }
        if sb == -1 {
            return Val {
                v: if div {
                    0u64.wrapping_sub(a.v);
                } else {
                    0;
                },
                u: false,
            };
        }
        return Val {
            v: if div {
                sa / sb;
            } else {
                sa % sb;
            } as u64,
            u: false,
        };
    }

    fn expr_unary(self: &mut Pp, live: bool, depth: u32) Val {
        let zero = Val { v: 0, u: false };
        if depth > EXPR_DEPTH_MAX {
            self.error("preprocessor expression nests too deeply");
            return zero;
        }
        if self.expr_pos >= self.expr.len() {
            self.error("expected a value in the preprocessor expression");
            return zero;
        }
        let t = self.expr[self.expr_pos];
        self.expr_pos += 1;
        if t.kind == K_NUM || t.kind == K_CHAR {
            let mut v = zero;
            let fault = if t.kind == K_NUM {
                self.parse_int(t.id, &mut v);
            } else {
                self.parse_char(t.id, &mut v);
            };
            if fault.len() != 0 {
                self.error(fault);
            }
            return v;
        }
        if t.kind == K_IDENT {
            return zero;
        }
        if t.kind == K_PUNCT {
            let c = t.id;
            if c == ID_LPAREN {
                let v = self.expr_comma(live, depth + 1);
                if !self.failed && self.expr_op() != ID_RPAREN {
                    self.error("expected ')' in preprocessor expression");
                    return zero;
                }
                self.expr_pos += 1;
                return v;
            }
            if c == b'+' as u32 {
                return self.expr_unary(live, depth + 1);
            }
            if c == b'-' as u32 {
                let v = self.expr_unary(live, depth + 1);
                return Val { v: 0u64.wrapping_sub(v.v), u: v.u };
            }
            if c == b'~' as u32 {
                let v = self.expr_unary(live, depth + 1);
                return Val { v: ~v.v, u: v.u };
            }
            if c == b'!' as u32 {
                let v = self.expr_unary(live, depth + 1);
                return Val { v: (v.v == 0) as u64, u: false };
            }
        }
        if t.kind == K_STR {
            self.error("string literal in preprocessor expression");
        } else {
            self.error("token is not valid in preprocessor expression");
        }
        return zero;
    }

    // The value of an integer constant into `out`; an error message, or "".
    const fn parse_int(self: &Pp, id: u32, out: &mut Val) str<'static> {
        let s = self.names.spell(id);
        let n = s.len();
        let mut base: u64 = 10;
        let mut i: usize = 0;
        if n > 1 && s.byte_at(0) == b'0' {
            let x = s.byte_at(1);
            if x == b'x' || x == b'X' {
                base = 16;
                i = 2;
            } else if x == b'b' || x == b'B' {
                base = 2;
                i = 2;
            } else {
                base = 8;
                i = 1;
            }
        }
        for k in 0..n {
            let c = s.byte_at(k);
            if c == b'.' || base != 16 && (c == b'e' || c == b'E') || base == 16 && (c == b'p' || c == b'P') {
                return "floating constant in preprocessor expression";
            }
        }
        let mut v: u64 = 0;
        let mut over = false;
        while i < n {
            let c = s.byte_at(i);
            if c == b'\'' {
                i += 1;
                continue;
            }
            let d = digit_value(c, base);
            if d >= base {
                break;
            }
            if v > (0xFFFFFFFFFFFFFFFFu64 - d) / base {
                over = true;
            }
            v = v.wrapping_mul(base).wrapping_add(d);
            i += 1;
        }
        let mut long_count: u32 = 0;
        let mut unsigned_count: u32 = 0;
        while i < n {
            let c = s.byte_at(i);
            if c == b'u' || c == b'U' {
                unsigned_count += 1;
            } else if c == b'l' || c == b'L' {
                long_count += 1;
            } else {
                unsigned_count = 9;
            }
            i += 1;
        }
        if unsigned_count > 1 || long_count > 2 {
            return "invalid suffix on integer constant";
        }
        *out = Val { v: v, u: over || unsigned_count == 1 || v > 0x7FFFFFFFFFFFFFFFu64 };
        return "";
    }

    // The value of a character constant: an `int` for a plain one, the char type's value for a prefixed one.
    const fn parse_char(self: &Pp, id: u32, out: &mut Val) str<'static> {
        let s = self.names.spell(id);
        let n = s.len();
        let mut i: usize = 0;
        let mut wide: u32 = 0;
        if s.byte_at(0) == b'L' {
            wide = 1;
            i = 1;
        } else if s.byte_at(0) == b'U' {
            wide = 3;
            i = 1;
        } else if s.byte_at(0) == b'u' {
            if s.byte_at(1) == b'8' {
                i = 2;
            } else {
                wide = 2;
                i = 1;
            }
        }
        i += 1;
        let end = n - 1;
        let mut value: u64 = 0;
        let mut count: u32 = 0;
        while i < end {
            let c = s.byte_at(i);
            let mut code: u64 = c;
            i += 1;
            if c == b'\\' && i < end {
                let e = s.byte_at(i);
                i += 1;
                if e == b'n' {
                    code = 10;
                } else if e == b't' {
                    code = 9;
                } else if e == b'r' {
                    code = 13;
                } else if e == b'a' {
                    code = 7;
                } else if e == b'b' {
                    code = 8;
                } else if e == b'f' {
                    code = 12;
                } else if e == b'v' {
                    code = 11;
                } else if e == b'e' || e == b'E' {
                    code = 27;
                } else if e == b'x' || e == b'u' || e == b'U' {
                    code = 0;
                    let limit: u32 = if e == b'u' {
                        4;
                    } else if e == b'U' {
                        8;
                    } else {
                        16;
                    };
                    let mut digits: u32 = 0;
                    while i < end && digits < limit {
                        let d = digit_value(s.byte_at(i), 16);
                        if d >= 16 {
                            break;
                        }
                        code = code << 4 | d;
                        digits += 1;
                        i += 1;
                    }
                } else if e >= b'0' && e <= b'7' {
                    code = e - b'0';
                    let mut digits: u32 = 1;
                    while i < end && digits < 3 && s.byte_at(i) >= b'0' && s.byte_at(i) <= b'7' {
                        code = code << 3 | (s.byte_at(i) - b'0') as u64;
                        digits += 1;
                        i += 1;
                    }
                } else {
                    code = e;
                }
            } else if wide != 0 && c >= 0xC0 {
                let extra: u32 = if c >= 0xF0 {
                    3;
                } else if c >= 0xE0 {
                    2;
                } else {
                    1;
                };
                code = c as u64 & 0x3Fu64 >> extra;
                let mut k: u32 = 0;
                while k < extra && i < end {
                    code = code << 6 | (s.byte_at(i) & 0x3F) as u64;
                    i += 1;
                    k += 1;
                }
            }
            if wide == 0 {
                value = value << 8 | code & 0xFF;
            } else {
                value = code;
            }
            count += 1;
        }
        if count == 0 {
            return "empty character constant";
        }
        if wide == 0 && count == 1 && self.macro_index(ID_CHAR_UNSIGNED) != 0 {
            *out = Val { v: value & 0xFF, u: false };
            return "";
        }
        if wide == 0 && count == 1 {
            *out = Val { v: (((value as u8) as i8) as i64) as u64, u: false };
            return "";
        }
        if wide == 0 || wide == 1 {
            *out = Val { v: (((value as u32) as i32) as i64) as u64, u: false };
            return "";
        }
        *out = Val {
            v: if wide == 2 {
                value & 0xFFFF;
            } else {
                value & 0xFFFFFFFFu64;
            },
            u: true,
        };
        return "";
    }

    // ---- Macro dump --------------------------------------------------------------------------------------

    /// Every macro defined now, one per line, as `cc -E -dM` prints them.
    pub fn dump_macros(self: &Pp, out: &mut String) {
        for i in 0..self.macros.len() {
            let m = self.macros[i];
            if m.kind == M_BUILTIN || self.macro_index(m.name) != i as u32 + 1 {
                continue;
            }
            out.push_str("#define ");
            out.push_str(self.names.spell(m.name));
            if m.kind == M_FUNC {
                out.push_byte(b'(');
                for q in 0..m.param_count {
                    if q > 0 {
                        out.push_byte(b',');
                    }
                    if q + 1 == m.param_count && m.variadic == 1 {
                        out.push_str("...");
                        continue;
                    }
                    out.push_str(self.names.spell(self.macro_params[(m.params_start + q) as usize]));
                    if q + 1 == m.param_count && m.variadic == 2 {
                        out.push_str("...");
                    }
                }
                out.push_byte(b')');
            }
            out.push_byte(b' ');
            for j in 0..m.body_len {
                let b = self.macro_body[(m.body_start + j) as usize];
                if j > 0 && (b.flags & F_SPC) != 0 {
                    out.push_byte(b' ');
                }
                if b.kind == K_PARAM {
                    out.push_str(self.names.spell(self.macro_params[(m.params_start + b.id) as usize]));
                } else if b.kind == K_VAOPT {
                    out.push_str("__VA_OPT__");
                } else {
                    out.push_str(self.names.spell(b.id));
                }
            }
            out.push_byte(b'\n');
        }
    }
}

const fn digit_value(c: u8, base: u64) u64 {
    let mut d: u64 = 99;
    if c >= b'0' && c <= b'9' {
        d = c - b'0';
    } else if c >= b'a' && c <= b'f' {
        d = (c - b'a') as u64 + 10;
    } else if c >= b'A' && c <= b'F' {
        d = (c - b'A') as u64 + 10;
    }
    if d >= base || base != 16 && d >= 10 {
        return 99;
    }
    return d;
}

const fn op_prec(op: u32) i32 {
    if op == OP_OROR {
        return 1;
    }
    if op == OP_ANDAND {
        return 2;
    }
    if op == b'|' as u32 {
        return 3;
    }
    if op == b'^' as u32 {
        return 4;
    }
    if op == b'&' as u32 {
        return 5;
    }
    if op == OP_EQ || op == OP_NE {
        return 6;
    }
    if op == b'<' as u32 || op == b'>' as u32 || op == OP_LE || op == OP_GE {
        return 7;
    }
    if op == OP_SHL || op == OP_SHR {
        return 8;
    }
    if op == b'+' as u32 || op == b'-' as u32 {
        return 9;
    }
    if op == b'*' as u32 || op == b'/' as u32 || op == b'%' as u32 {
        return 10;
    }
    return 0;
}
