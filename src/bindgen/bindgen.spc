// `super-c bindgen <header.h>`: turn a C library's header into a Super-C `extern "C"` module.
//
// The C is read through bindgen's own preprocessor (`bindgen::cpp`) under the C environment of the target
// (`bindgen::ctarget`: clang's predefined macros, `__has_*` answers, system directories and built-in
// headers), never through a C compiler. It resolves every `#include`, `#if` and macro, so what reaches the
// parser here is a flat list of declarations with no preprocessor left in it. Its macro dump supplies the
// target's integer widths, so `long` maps by what the target says it is rather than by assumption.
//
// The preprocessor also says where each declaration CAME FROM (`# <line> "<file>"` markers), which is what
// separates the requested header's own declarations from the thousands its includes drag in. Everything is
// parsed (a typedef from <stddef.h> is needed to resolve one in the target) but only declarations whose
// origin is the requested header are emitted.
//
// Scope: functions, the typedefs needed to spell their signatures, enums (tagged ones as `enum`, anonymous
// enumerators and object-like macros as constants; an integer one inside the extern block, where the C
// compile checks its value), structs/unions with every member, from which Super-C computes the layout
// (the emitted C checks it against the header on every target; bitfields, anonymous members and a member
// of an opaque type by value fall back to opaque), `extern` globals (const-qualified as `const`, writable
// as `static mut`), and opaque `pub type` for everything else a declaration names. Function-LIKE macros cannot appear at all: the
// preprocessor has already expanded them away by the time anything here runs.

import stdio;
import std::platform::fs;
import module::loader as loader;
import driver::util as *;
import lexer::lexer as lex;
import bindgen::cpp as cpp;
import bindgen::ctarget as ct;

const TK_EOF: i32 = 0;
const TK_IDENT: i32 = 1;
const TK_NUM: i32 = 2;
const TK_PUNCT: i32 = 3;
const TK_STR: i32 = 4;

// A token cursor over preprocessed C. Line markers are consumed by the scanner itself and published as
// `file`, so the parser never sees a directive and always knows the declaration's origin.
struct Lexer<'a> {
    pub src: str<'a>,
    pub pos: usize,
    pub kind: i32,
    pub start: usize,
    pub end: usize,
    pub file: String, // the `# <line> "<file>"` most recently passed
    /// The vector attribute the declaration being read carries: its bytes (`vector_size`), minus its
    /// lanes (`neon_vector_type`, `ext_vector_type`), 0 for none.
    pub vec: i64,
    pub lay_attr: bool, // a `packed` or `aligned` attribute passed since the record body being read began
    /// The `packed` and `aligned(N)` attributes passed since `parse_specs` reset them, and whether one of
    /// another form (`aligned` without a value) passed: a record's own attributes (`apply_attrs`).
    pub a_packed: bool,
    pub a_align: u32,
    pub a_unknown: bool,
    /// The packing of the records after the `#pragma pack` lines passed (`pragma_pack`): the value as written
    /// (empty: none), the values `push` saved, and whether a line of another form passed (no record's
    /// layout then follows from its members alone).
    pub pack: String,
    pub pack_stack: Vector<String>,
    pub pack_unknown: bool,
    pub rec_depth: u32, // the record bodies being read
    pub anon_n: u32, // the nameless records defined in a member so far (`parse_specs`)
}

const fn is_id_start(c: u8) bool {
    return c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c == b'_' || c == b'$';
}

const fn is_id_body(c: u8) bool {
    return is_id_start(c) || c >= b'0' && c <= b'9';
}

const fn is_digit(c: u8) bool {
    return c >= b'0' && c <= b'9';
}

extend<'a> Lexer<'a> {
    fn new(src: str<'a>) Lexer<'a> {
        let mut lx = Lexer::<'a> {
            src: src,
            pos: 0,
            kind: TK_EOF,
            start: 0,
            end: 0,
            file: String::new(),
            vec: 0,
            lay_attr: false,
            a_packed: false,
            a_align: 0,
            a_unknown: false,
            pack: String::new(),
            pack_stack: Vector::<String>::new(),
            pack_unknown: false,
            rec_depth: 0,
            anon_n: 0,
        };
        lx.advance();
        return lx;
    }

    const fn text(self: &Lexer<'a>) str<'a> {
        return self.src.slice(self.start, self.end);
    }

    const fn at_punct(self: &Lexer<'a>, c: u8) bool {
        return self.kind == TK_PUNCT && self.end == self.start + 1 && self.src.byte_at(self.start) == c;
    }

    // A `# <line> "<file>" ...` marker: the quoted name becomes `file`. Anything else on a `#` line (a
    // `#pragma` the preprocessor kept) is skipped whole.
    fn line_marker(self: &mut Lexer<'a>) {
        let n = self.src.len();
        let mut i = self.pos + 1;
        while i < n && (self.src.byte_at(i) == b' ' || self.src.byte_at(i) == b'\t') {
            i = i + 1;
        }
        if i < n && is_digit(self.src.byte_at(i)) {
            while i < n && is_digit(self.src.byte_at(i)) {
                i = i + 1;
            }
            while i < n && (self.src.byte_at(i) == b' ' || self.src.byte_at(i) == b'\t') {
                i = i + 1;
            }
            if i < n && self.src.byte_at(i) == b'"' {
                i = i + 1;
                let fs = i;
                while i < n && self.src.byte_at(i) != b'"' {
                    i = i + 1;
                }
                self.file.clear();
                self.file.push_str(self.src.slice(fs, i));
            }
        }
        let at = self.pos;
        while self.pos < n && self.src.byte_at(self.pos) != b'\n' {
            self.pos = self.pos + 1;
        }
        let line = self.src.slice(at, self.pos);
        if line.find("pragma") >= 0 && line.find("pack") >= 0 {
            self.pragma_pack(line);
        }
    }

    // A `#pragma pack` line: `pack(N)`, `pack()`, `pack(push[, N])` and `pack(pop[, N])` set the packing of
    // the records after it, as GCC and clang do (N may be a macro: `parse_record_body` evaluates it); a
    // line of another form makes `pack_unknown`.
    fn pragma_pack(self: &mut Lexer<'a>, line: str) {
        let o = line.find_byte(b'(');
        let e = line.find_byte(b')');
        if o < 0 || e < o {
            self.pack_unknown = true;
            return;
        }
        let args = line.slice(o as usize + 1, e as usize);
        if args.trim().len() == 0 {
            self.pack.clear();
            return;
        }
        let mut a: usize = 0;
        for i in 0..args.len() + 1 {
            if i < args.len() && args.byte_at(i) != b',' {
                continue;
            }
            let w = args.slice(a, i).trim();
            a = i + 1;
            if w == "push" {
                // A nesting deeper than any header's is not modelled.
                if self.pack_stack.len() >= 64 {
                    self.pack_unknown = true;
                    return;
                }
                self.pack_stack.push(self.pack.clone());
            } else if w == "pop" {
                self.pack = self.pack_stack.pop().unwrap_or(String::new());
            } else if w.len() != 0 && w != "show" {
                self.pack.clear();
                self.pack.push_str(w);
            }
        }
    }

    fn advance(self: &mut Lexer<'a>) {
        let n = self.src.len();
        loop {
            while self.pos < n {
                let c = self.src.byte_at(self.pos);
                if c == b'\n' {
                    self.pos = self.pos + 1;
                    // A `#` in the first column is a line marker; `-E` leaves nothing else at file scope.
                    while self.pos < n && self.src.byte_at(self.pos) == b'#' {
                        self.line_marker();
                        if self.pos < n {
                            self.pos = self.pos + 1;
                        }
                    }
                    continue;
                }
                if c == b' ' || c == b'\t' || c == b'\r' {
                    self.pos = self.pos + 1;
                    continue;
                }
                break;
            }
            if self.pos == 0 && n != 0 && self.src.byte_at(0) == b'#' {
                self.line_marker();
                continue;
            }
            break;
        }
        if self.pos >= n {
            self.kind = TK_EOF;
            self.start = n;
            self.end = n;
            return;
        }
        let c = self.src.byte_at(self.pos);
        self.start = self.pos;
        if is_id_start(c) {
            while self.pos < n && is_id_body(self.src.byte_at(self.pos)) {
                self.pos = self.pos + 1;
            }
            self.kind = TK_IDENT;
        } else if is_digit(c) {
            // One token for the whole numeric soup: suffixes, exponents and hex digits all read as body.
            while self.pos < n && (is_id_body(self.src.byte_at(self.pos)) || self.src.byte_at(self.pos) == b'.') {
                self.pos = self.pos + 1;
            }
            self.kind = TK_NUM;
        } else if c == b'"' || c == b'\'' {
            let q = c;
            self.pos = self.pos + 1;
            while self.pos < n && self.src.byte_at(self.pos) != q {
                if self.src.byte_at(self.pos) == b'\\' && self.pos + 1 < n {
                    self.pos = self.pos + 1;
                }
                self.pos = self.pos + 1;
            }
            if self.pos < n {
                self.pos = self.pos + 1;
            }
            self.kind = TK_STR;
        } else {
            // `...` is the only multi-character punctuator a declaration can contain.
            if c == b'.' && self.pos + 2 < n && self.src.byte_at(self.pos + 1) == b'.' && self.src.byte_at(self.pos + 2) == b'.' {
                self.pos = self.pos + 3;
            } else {
                self.pos = self.pos + 1;
            }
            self.kind = TK_PUNCT;
        }
        self.end = self.pos;
    }

    // Consume a balanced (), [] or {} group; the cursor must be on the opener.
    fn skip_group(self: &mut Lexer<'a>, open: u8, close: u8) {
        if !self.at_punct(open) {
            return;
        }
        let mut depth: i32 = 0;
        loop {
            if self.kind == TK_EOF {
                return;
            }
            if self.at_punct(open) {
                depth = depth + 1;
            } else if self.at_punct(close) {
                depth = depth - 1;
                if depth == 0 {
                    self.advance();
                    return;
                }
            }
            self.advance();
        }
    }
}

const MAX_PTR: usize = 8;

// One C type as far as this tool models it: a base name already mapped to Super-C, a pointer depth, and
// a bit per level saying whether THAT level's pointee is const (bit 0 is the base's own `const`). A
// function pointer carries its rendered Super-C signature instead, since `fn(..) T` is already a pointer.
struct CType {
    pub base: String,
    pub ptr: usize,
    pub qual: u32,
    pub fnsig: String, // non-empty => this is a function pointer and `base`/`ptr` are unused
    pub ok: bool,
}

fn ctype_new() CType {
    return CType { base: String::new(), ptr: 0, qual: 0, fnsig: String::new(), ok: true };
}

extend CType {
    fn clone(self: &CType) CType {
        return CType {
            base: String::from_str(self.base.as_str()),
            ptr: self.ptr,
            qual: self.qual,
            fnsig: String::from_str(self.fnsig.as_str()),
            ok: self.ok,
        };
    }

    const fn qual_at(self: &CType, level: usize) bool {
        return (self.qual >> level as u32 & 1u32) != 0;
    }

    // The Super-C spelling. Pointers render outermost first, each one `*const` or `*mut` by what it points
    // at: C's `const char *` is a pointer to const, C's `char *const` is a const binding and says nothing
    // about the pointee, which is why only the pointee's qualifier survives here.
    fn render(self: &CType, out: &mut String) {
        if self.fnsig.len() != 0 {
            out.push_str(self.fnsig.as_str());
            return;
        }
        let mut i = self.ptr;
        while i > 0 {
            if self.qual_at(i - 1) {
                out.push_str("*const ");
            } else {
                out.push_str("*mut ");
            }
            i = i - 1;
        }
        out.push_str(self.base.as_str());
    }
}

// The fixed-width C types, mapped by NAME rather than by what they expand to: `size_t` is `usize` because
// that is what it means, not because this host happens to spell it `unsigned long`.
fn wellknown(name: str, out: &mut String) bool {
    let sub = switch name {
        "size_t" | "uintptr_t" => "usize",
        "ssize_t" | "ptrdiff_t" | "intptr_t" => "isize",
        "int8_t" => "i8",
        "int16_t" => "i16",
        "int32_t" => "i32",
        "int64_t" => "i64",
        "uint8_t" => "u8",
        "uint16_t" => "u16",
        "uint32_t" => "u32",
        "uint64_t" => "u64",
        "_Bool" | "bool" => "bool",
        "va_list" | "__builtin_va_list" | "__gnuc_va_list" => "va_list",
        _ => "",
    };
    if sub.len() == 0 {
        return false;
    }
    out.push_str(sub);
    return true;
}

// Widths the target's predefined macros report, so `long` and friends map by measurement.
struct Widths {
    pub short_b: i32,
    pub int_b: i32,
    pub long_b: i32,
    pub llong_b: i32,
    pub ptr_b: i32,
}

fn int_name(bytes: i32, signed: bool, out: &mut String) {
    let n = if signed {
        "i";
    } else {
        "u";
    };
    out.push_str(n);
    if bytes == 1 {
        out.push_str("8");
    } else if bytes == 2 {
        out.push_str("16");
    } else if bytes == 8 {
        out.push_str("64");
    } else {
        out.push_str("32");
    }
}

struct Param {
    pub name: String,
    pub ty: String,
}

struct FnDecl {
    pub name: String,
    pub params: Vector<Param>,
    pub ret: String,
    pub variadic: bool,
}

struct Alias {
    pub name: String, // the C typedef / struct tag
    pub sub: String, // what it maps to in Super-C ("" while it is an opaque tag)
    pub opaque: bool,
    /// False when the typedef's own type could not be modelled. Carried so that a signature spelled with
    /// it is dropped too: the alias table would otherwise launder an unknown C type into a plausible name.
    pub ok: bool,
}

struct Field {
    pub name: String, // the C member's name
    pub ty: String,
    pub bits: i32, // a bitfield's width, -1 for another member
}

// A struct or union DEFINED in the target header. `ok` is false as soon as one member has no faithful
// Super-C form (a bitfield, an anonymous member, a flexible array, an unmodelled type): such a record
// falls back to the opaque `pub type`, which keeps every member out of reach instead of binding some.
// `tagless`: the body had no tag, so `tag` is the typedef that names it (`typedef struct { .. } Foo;`).
// `attr`: a `packed` or `aligned` attribute or a `#pragma pack` may move its members (`c_layout`).
struct Record {
    pub tag: String,
    pub fields: Vector<Field>,
    pub is_union: bool,
    pub ok: bool,
    pub mine: bool,
    pub tagless: bool,
    pub attr: bool,
    pub pack: u32, // the `#pragma pack` value its members' alignment is capped at, 0 for none
    pub anon: bool, // an anonymous struct or union member: a field named "" (`find_member`)
    pub bitf: bool, // a bitfield member
    pub packed: bool, // `__attribute__((packed))`: every member aligned to 1
    pub aligned: u32, // `__attribute__((aligned(N)))`: the alignment at least, 0 for none
}

struct EnumVal {
    pub name: String,
    pub value: i64,
}

// A C enum. A TAGGED one becomes a Super-C `enum` (its tag is a type a signature can name); an anonymous
// one is the "block of constants" idiom and becomes plain consts, which is how C code uses it.
// `tagless`: the body had no tag, so `tag` is the typedef that names it (`typedef enum { .. } Foo;`).
struct EnumDef {
    pub tag: String,
    pub vals: Vector<EnumVal>,
    pub ok: bool,
    pub mine: bool,
    pub tagless: bool,
}

struct ConstDef {
    pub name: String,
    pub ty: String,
    pub value: String,
    pub mutable: bool, // a global whose C declaration is not const: bound as `static mut`
}

// Everything the parse produced: the type environment (every typedef in the whole translation unit, since
// the target header's signatures are spelled with them) and the declarations from the target header alone.
struct Collected {
    pub aliases: Vector<Alias>,
    pub fns: Vector<FnDecl>,
    pub opaques: Vector<String>, // struct tags reached only through a pointer -> `pub type X;`
    pub records: Vector<Record>,
    pub enums: Vector<EnumDef>,
    pub consts: Vector<ConstDef>, // anonymous-enum constants, then object-like macros
    pub globals: Vector<ConstDef>, // `extern` variables the library exports
    pub widths: Widths,
    pub cur_mine: bool, // whether the declaration being parsed comes from the target header
    /// The anonymous struct/union/enum body parsed last, waiting for the typedef that names it
    /// (`typedef struct { .. } Foo;` is how most C libraries declare their types). -1 when there is none.
    pub pending_agg: i32,
    pub pending_is_enum: bool,
    pub saw_extern: bool, // the declaration being parsed carried `extern`: a variable, not a definition
    /// Functions from the target header whose signature this tool could not model. Reported rather than
    /// swallowed: a binding file that is quietly short is worse than one that says what it left out.
    pub skipped: usize,
    /// Object-like macros of the `-dM` dump: name -> offsets of the replacement text in the dump
    /// (start << 32 | end). Built once, so a lookup does not rescan the dump.
    pub macros: Map<String, u64>,
    /// The `static` functions of every origin: no object exports them.
    pub statics: Set<String>,
    /// The target lays bitfields out the Microsoft way (`rec_layout`): Windows.
    pub ms_bitfields: bool,
    /// For `header_facts`: every function declaration of every origin, the first of each name (`proto_ix`).
    pub all_protos: bool,
    pub protos: Vector<FnDecl>,
    pub proto_ix: Map<String, u32>,
    pub alias_ix: Map<String, u32>, // per alias name, its index in `aliases`
    pub opaque_set: Set<String>, // the names in `opaques`
}

// Vendor noise that carries no meaning for a binding. `__attribute__`, `__declspec` and `asm` take a
// parenthesised argument; the rest are bare words.
const fn noise_word(s: str) bool {
    return s == "__extension__" || s == "__inline" || s == "__inline__" || s == "inline" || s == "__restrict" || s == "__restrict__" || s == "restrict" || s == "_Nullable" || s == "_Nonnull" || s == "_Null_unspecified" || s == "__nullable" || s == "__nonnull" || s == "_Noreturn" || s == "__cdecl" || s == "__stdcall" || s == "__fastcall" || s == "__volatile" || s == "volatile" || s == "_Atomic" || s == "__pragma" || s == "__forceinline";
}

const fn noise_call(s: str) bool {
    return s == "__attribute__" || s == "__attribute" || s == "__declspec" || s == "asm" || s == "__asm" || s == "__asm__" || s == "__has_attribute";
}

// A Super-C keyword cannot name a parameter, field or function, and `str`/`int` would shadow the
// prelude's names; a trailing underscore keeps the C name recognisable.
const fn keyword(s: str) bool {
    return lex::is_keyword(s) || s == "str" || s == "int";
}

fn safe_name(s: str, out: &mut String) {
    out.push_str(s);
    if keyword(s) {
        out.push_byte(b'_');
    }
}

// Whether constant `cd` is an integer, which an extern block can hold and the C compile checks.
fn int_const(cd: &ConstDef) bool {
    return switch cd.ty.as_str() {
        "i8" | "i16" | "i32" | "i64" | "isize" | "u8" | "u16" | "u32" | "u64" | "usize" => true,
        _ => false,
    };
}

// The type a field of rendered type `ty` holds by value: the element of an array, or "" for a
// pointer or a function pointer.
const fn by_value_base(ty: str) str {
    let mut t = ty;
    while t.len() != 0 && t.byte_at(0) == b'[' {
        t = t.slice(1, t.len());
    }
    let semi = t.find(";");
    if semi >= 0 {
        t = t.slice(0, semi as usize);
    }
    if t.len() == 0 || t.byte_at(0) == b'*' || t.starts_with("fn(") {
        return "";
    }
    return t;
}

// A symbol whose name is a keyword binds under its escaped spelling (`safe_name`); the import
// pins the C symbol to the original name.
fn pin_keyword(s: str, out: &mut String) {
    if keyword(s) {
        out.format_into("    @import(\"{}\")\n", s);
    }
}

const I64_MAX: i64 = 0x7FFFFFFFFFFFFFFF;
const I64_MIN: i64 = -I64_MAX - 1;

// An integer written in a C enumerator or an array bound: decimal, hex or a character, with the suffixes
// and sign C allows. -1 means "not a plain integer", which is what makes the caller fall back.
const fn int_literal(t: str) i64 {
    let n = t.len();
    if n == 0 {
        return -1;
    }
    let mut i: usize = 0;
    let mut base: i64 = 10;
    if n > 2 && t.byte_at(0) == b'0' && (t.byte_at(1) == b'x' || t.byte_at(1) == b'X') {
        base = 16;
        i = 2;
    } else if n > 2 && t.byte_at(0) == b'0' && (t.byte_at(1) == b'b' || t.byte_at(1) == b'B') {
        base = 2;
        i = 2;
    } else if n > 1 && t.byte_at(0) == b'0' {
        // C reads a leading 0 as octal.
        base = 8;
        i = 1;
    }
    let mut v: i64 = 0;
    let mut any = false;
    while i < n {
        let ch = t.byte_at(i);
        let mut d: i64 = -1;
        if is_digit(ch) {
            d = ch - b'0';
        } else if base == 16 && ch >= b'a' && ch <= b'f' {
            d = (ch - b'a') as i64 + 10;
        } else if base == 16 && ch >= b'A' && ch <= b'F' {
            d = (ch - b'A') as i64 + 10;
        } else if ch == b'u' || ch == b'U' || ch == b'l' || ch == b'L' {
            // A width suffix, not a digit.
            break;
        } else {
            return -1;
        }
        if d >= base {
            return -1;
        }
        if v > (I64_MAX - d) / base {
            return -1;
        }
        v = v * base + d;
        any = true;
        i = i + 1;
    }
    if !any {
        return -1;
    }
    return v;
}

extend EnumDef {
    const fn val_of(self: &Self, name: str) Option<i64> {
        for i in 0..self.vals.len() {
            if self.vals[i].name.as_str() == name {
                return Option::<i64>::Some(self.vals[i].value);
            }
        }
        return Option::<i64>::None;
    }
}

// The preprocessor prints the path it opened, which is only the same STRING as the requested header when
// the request was already absolute: compare by identity, not by spelling. `--from=` widens the set: a
// platform that splits its headers (macOS declares `printf` in `_printf.h`, not `stdio.h`) puts the
// declarations somewhere the request never named, and only the caller knows which of those to accept.
fn same_origin(a: str, want: str, extra: &Vector<String>) bool {
    if a.len() == 0 {
        return false;
    }
    if a == want {
        return true;
    }
    for i in 0..extra.len() {
        if extra[i].len() != 0 && a.contains(extra[i].as_str()) {
            return true;
        }
    }
    return same_file(a, want);
}

// Preprocess `header` under the C environment `env`, with the `-I` directories `incs` searched before the
// system ones and the in-memory files `files`: the `cc -E` text into `text` and the `cc -E -dM` dump into
// `dump`. False after an error, which the preprocessor reports on stderr.
fn preprocess(
    env: &ct::CTarget,
    header: str,
    incs: &Vector<String>,
    mut files: Vector<cpp::VFile>,
    text: &mut String,
    dump: &mut String,
    read: &mut Vector<String>,
    quiet: bool,
) bool {
    for i in 0..env.headers.len() {
        files.push(
            cpp::VFile {
                path: format("{}/{}", ct::BUILTIN_DIR, env.headers[i]),
                text: String::from_str(ct::builtin_header(env.headers[i])),
            },
        );
    }
    let mut has = Vector::<String>::new();
    for i in 0..env.has.len() {
        has.push(String::from_str(env.has[i]));
    }
    let mut pp = cpp::Pp::new(
        cpp::PpConfig {
            quote_dirs: Vector::<String>::new(),
            dirs: incs.clone(),
            sys_dirs: env.sys_dirs.clone(),
            frameworks: env.frameworks.clone(),
            files: files,
            predefs: env.predefs.clone(),
            cmdline: String::new(),
            has: has,
        },
    );
    pp.quiet = quiet;
    let ok = pp.preprocess(header, text);
    *read = replace(&mut pp.disk_paths, Vector::<String>::new());
    if !ok {
        return false;
    }
    pp.dump_macros(dump);
    return true;
}

/// The C environment of target `target` and `arch` under `sysroot` (`ct::c_target`; empty: discover it)
/// with the C flags `flags` (`ct::apply_c_flags`) into `env`; false when the target has none or a flag
/// does not apply.
pub fn header_env(target: i32, arch: i32, sysroot: str, flags: str, env: &mut ct::CTarget) bool {
    return ct::c_target(target, arch, sysroot, env) && ct::apply_c_flags(flags, env);
}

/// The facts of the C headers whose `#include` lines are `pre` (in a C unit's order) under C environment
/// `env` (`header_env`) that a native build reads: the
/// values of the integer constants `names` it defines (macros, which may name enumerators and other
/// macros, or enumerators), `vals[k]` holding the value of `names[k]` when `oks[k]`, whether each of the
/// functions `fns` is `static` there (`statics[k]`: no object exports it) and its prototype (`sigs[k]`:
/// `f` or `v` (variadic), then the result's shape and each parameter's (`c_shape`; `-` for `void`), space
/// separated; empty when the headers declare none). Per type of `types`, its
/// scalar class (`classes`), a record's layout (`layouts`, `c_layout`), and its size and alignment
/// (`sizes`: size << 32 | alignment, 0 when they do not follow from the header). Per aggregate of `aggs`
/// (a C type as a declaration names it: `struct tm`, `union u`, `enum color` or a typedef, then
/// `|<member>` per member it names), its facts (`afacts`, `agg_facts`), and per type of `shape_of`, its
/// shape (`shapes`, `c_shape`). `read` takes the
/// files the preprocessor read. False when the header does not preprocess.
pub fn header_facts(
    env: &ct::CTarget,
    pre: str,
    names: []str,
    vals: &mut Vector<i64>,
    oks: &mut Vector<bool>,
    fns: []str,
    statics: &mut Vector<bool>,
    sigs: &mut Vector<String>,
    types: []str,
    classes: &mut Vector<u8>,
    layouts: &mut Vector<String>,
    sizes: &mut Vector<u64>,
    aggs: []str,
    afacts: &mut Vector<String>,
    shape_of: []str,
    shapes: &mut Vector<String>,
    read: &mut Vector<String>,
) bool {
    let path = "/__sc_header_ints.c";
    // After the header, each name the preprocessor expands, function-like macros included (mingw-w64
    // spells `ERROR_LOCK_VIOLATION` as `__MSABI_LONG(33)`): a marker, then a separator before each.
    let mut probe = format("{}{}\n", pre, HF_BEGIN);
    for k in 0..names.len() {
        probe.format_into("{} {}\n", HF_SEP, names[k]);
    }
    let mut files = Vector::<cpp::VFile>::new();
    files.push(cpp::VFile { path: String::from_str(path), text: probe });
    let mut out = String::new();
    let mut dump = String::new();
    let none = Vector::<String>::new();
    if !preprocess(env, path, &none, files, &mut out, &mut dump, read, true) {
        return false;
    }
    let all = out.as_str();
    let mark = all.find(HF_BEGIN);
    if mark < 0 {
        return false;
    }
    let text = String::from_str(all.slice(0, mark as usize));
    let mut tail = all.slice(mark as usize + HF_BEGIN.len(), all.len());
    let mut c = Collected {
        aliases: Vector::<Alias>::new(),
        fns: Vector::<FnDecl>::new(),
        opaques: Vector::<String>::new(),
        records: Vector::<Record>::new(),
        enums: Vector::<EnumDef>::new(),
        consts: Vector::<ConstDef>::new(),
        globals: Vector::<ConstDef>::new(),
        widths: Widths { short_b: 2, int_b: 4, long_b: 8, llong_b: 8, ptr_b: 8 },
        cur_mine: false,
        pending_agg: -1,
        pending_is_enum: false,
        saw_extern: false,
        skipped: 0,
        macros: Map::<String, u64>::new(),
        statics: Set::<String>::new(),
        alias_ix: Map::<String, u32>::new(),
        opaque_set: Set::<String>::new(),
        ms_bitfields: false,
        all_protos: false,
        protos: Vector::<FnDecl>::new(),
        proto_ix: Map::<String, u32>::new(),
    };
    c.index_macros(dump.as_str());
    c.widths = read_widths(&c, dump.as_str());
    let win = String::from_str("_WIN32");
    c.ms_bitfields = c.macros.contains_key(&win);
    c.all_protos = true;
    let mut lx = Lexer::new(text.as_str());
    lx.parse_unit(&mut c, path, &none, dump.as_str());
    let mut ex = String::new();
    for k in 0..names.len() {
        // The name's expansion: up to the next separator, its line markers dropped.
        let at = tail.find(HF_SEP);
        if at < 0 {
            return false;
        }
        tail = tail.slice(at as usize + HF_SEP.len(), tail.len());
        let end = tail.find(HF_SEP);
        let seg = if end < 0 {
            tail;
        } else {
            tail.slice(0, end as usize);
        };
        ex.clear();
        let mut a: usize = 0;
        for b in 0..seg.len() + 1 {
            if b == seg.len() || seg.byte_at(b) == b'\n' {
                let ln = seg.slice(a, b);
                if !ln.trim().starts_with("#") {
                    ex.push_str(ln);
                    ex.push_byte(b' ');
                }
                a = b + 1;
            }
        }
        // The value's 64 bits: an unsigned 64-bit constant past i64 keeps its bits.
        let v = ce_cv(ex.as_str().trim(), &c, null, dump.as_str(), 0);
        oks.push(v.is_some());
        vals.push(
            if v.is_some() {
                cv_pat(v.unwrap()) as i64;
            } else {
                0;
            },
        );
    }
    for k in 0..fns.len() {
        let key = String::from_str(fns[k]);
        statics.push(c.statics.contains(&key));
        let mut sg = String::new();
        if let Some(i) = c.proto_ix.get(&key) {
            let f = &c.protos[(*i) as usize];
            sg.push_str(pick(f.variadic, "v ", "f "));
            c_shape(&c, f.ret.as_str(), &mut sg);
            for q in 0..f.params.len() {
                sg.push_byte(b' ');
                c_shape(&c, f.params[q].ty.as_str(), &mut sg);
            }
        }
        sigs.push(sg);
    }
    let mut lv = Vector::<(u32, u8)>::new();
    for k in 0..types.len() {
        let mut cl = scalar_class(&c, types[k]);
        let mut lay = String::new();
        lv.truncate(0);
        let mut size: u32 = 0;
        let mut align: u32 = 0;
        if cl == SC_NONE && c_layout(&c, types[k], 0, false, &mut lv, &mut size, &mut align) {
            cl = SC_REC;
            lay.format_into("{} {}", size, align);
            for q in 0..lv.len() {
                lay.format_into(" {}{}", lv[q].0, lv[q].1 as char);
            }
        }
        classes.push(cl);
        layouts.push(lay);
        lv.truncate(0);
        sizes.push(
            if c_layout(&c, types[k], 0, true, &mut lv, &mut size, &mut align) {
                size as u64 << 32 | align as u64;
            } else {
                0;
            },
        );
    }
    for k in 0..aggs.len() {
        let mut f = String::new();
        agg_facts(&c, dump.as_str(), aggs[k], &mut f);
        afacts.push(f);
    }
    for k in 0..shape_of.len() {
        let mut f = String::new();
        c_shape(&c, shape_of[k], &mut f);
        shapes.push(f);
    }
    return true;
}

// The facts of aggregate query `query` (`header_facts`'s `aggs`: a C type, then `|<member>` per member
// the declaration names) into `out`: for a struct or union `R <size> <align>` and per member the header
// has ` <member>=<offset>=<shape>` (`member_at`, `c_shape`); for an enum `E` and per enumerator
// ` <name>=<value>`; `?` when the header defines it but its layout or values do not follow (a bitfield,
// an anonymous member, a layout attribute, a value that is no constant); empty when the header does not
// define it.
fn agg_facts(c: &Collected, dump: str, query: str, out: &mut String) {
    let bar = query.find_byte(b'|');
    let cty = if bar < 0 {
        query;
    } else {
        query.slice(0, bar as usize);
    };
    let tagged = cty.starts_with("struct ") || cty.starts_with("union ") || cty.starts_with("enum ");
    let name = if tagged {
        cty.slice(cty.find_byte(b' ') as usize + 1, cty.len());
    } else {
        cty;
    };
    let mut ri: i32 = -1;
    let mut ei: i32 = -1;
    if tagged {
        if cty.starts_with("enum ") {
            ei = enum_index(c, name, false);
        } else {
            ri = record_index(c, name, false);
        }
    } else {
        // A typedef: through its chain to a typedef'd tagless body, or to a tag after the first step. Each
        // step follows one typedef; a chain is shorter than the alias table.
        let mut t = name;
        for step in 0..c.aliases.len() + 1 {
            ri = record_index(c, t, true);
            ei = enum_index(c, t, true);
            if step != 0 && ri < 0 && ei < 0 {
                ri = record_index(c, t, false);
                ei = enum_index(c, t, false);
            }
            if ri >= 0 || ei >= 0 {
                break;
            }
            let ai = c.alias_of(t);
            if ai < 0 {
                break;
            }
            let al = &c.aliases[ai as usize];
            if !al.ok || al.sub.len() == 0 || al.sub.as_str() == t {
                ri = record_index(c, t, false);
                ei = enum_index(c, t, false);
                break;
            }
            t = al.sub.as_str();
        }
    }
    if ei >= 0 {
        let ed = &c.enums[ei as usize];
        if !ed.ok {
            out.push_str("?");
            return;
        }
        out.push_str("E");
        for q in 0..ed.vals.len() {
            out.format_into(" {}={}", ed.vals[q].name.as_str(), ed.vals[q].value);
        }
        return;
    }
    if ri < 0 {
        return;
    }
    let mut size: u32 = 0;
    let mut align: u32 = 0;
    let mut lv = Vector::<(u32, u8)>::new();
    let r = &c.records[ri as usize];
    if !r.ok || r.attr || !c_layout(c, r.tag.as_str(), 0, true, &mut lv, &mut size, &mut align) {
        out.push_str("?");
        return;
    }
    out.format_into("R {} {}", size, align);
    let mut rest = if bar < 0 {
        "";
    } else {
        query.slice(bar as usize + 1, query.len());
    };
    let mut sh = String::new();
    for _ in 0..query.len() {
        if rest.len() == 0 {
            break;
        }
        let e = rest.find_byte(b'|');
        let m = if e < 0 {
            rest;
        } else {
            rest.slice(0, e as usize);
        };
        rest = if e < 0 {
            "";
        } else {
            rest.slice(e as usize + 1, rest.len());
        };
        sh.clear();
        let mut off: u32 = 0;
        if member_at(c, dump, ri, m, &mut off, &mut sh) {
            out.format_into(" {}={}={}", m, off, sh.as_str());
        }
    }
}

// The offset and shape (`c_shape`) of member `name` of record `ri`: one of its own or of its anonymous
// members (`find_member`), or the path of members a macro of that name expands to (`sa_handler`:
// `__sigaction_u.__sa_handler`). False when it has none.
fn member_at(c: &Collected, dump: str, ri: i32, name: str, off: &mut u32, shape: &mut String) bool {
    let mut path = String::new();
    let mut rec = ri;
    let mut at: u32 = 0;
    let mut ty = String::new();
    let mut o: u32 = 0;
    if !find_member(c, ri, name, 0, &mut o, &mut ty) && !c.macro_value(dump, name, &mut path) {
        return false;
    }
    if path.len() == 0 {
        path.push_str(name);
    }
    let p = path.as_str().trim();
    let mut a: usize = 0;
    for i in 0..p.len() + 1 {
        if i < p.len() && p.byte_at(i) != b'.' {
            continue;
        }
        let seg = p.slice(a, i).trim();
        a = i + 1;
        ty.clear();
        if rec < 0 || !find_member(c, rec, seg, 0, &mut o, &mut ty) {
            return false;
        }
        at += o;
        if i == p.len() {
            *off = at;
            c_shape(c, ty.as_str(), shape);
            return true;
        }
        rec = record_of_type(c, ty.as_str());
    }
    return false;
}

// Member `name` of record `ri`, one of its own or of an anonymous member's at most 8 levels down: its
// offset into `off` and its rendered type into `ty`. False when it has none or a layout does not follow.
fn find_member(c: &Collected, ri: i32, name: str, depth: u32, off: &mut u32, ty: &mut String) bool {
    let r = &c.records[ri as usize];
    let mut offs = Vector::<u32>::new();
    if depth > 8 || !field_offsets(c, ri, &mut offs) {
        return false;
    }
    for k in 0..r.fields.len() {
        if r.fields[k].name.as_str() == name {
            *off = offs[k];
            ty.push_string(&r.fields[k].ty);
            return true;
        }
    }
    for k in 0..r.fields.len() {
        if r.fields[k].name.len() != 0 || r.fields[k].bits >= 0 {
            continue;
        }
        let sub = c.record_of(r.fields[k].ty.as_str());
        let mut o: u32 = 0;
        if sub >= 0 && find_member(c, sub, name, depth + 1, &mut o, ty) {
            *off = offs[k] + o;
            return true;
        }
    }
    return false;
}

// The offset of each member of record `ri` into `out` (`rec_layout`); false when a member's layout does
// not follow.
fn field_offsets(c: &Collected, ri: i32, out: &mut Vector<u32>) bool {
    let mut lv = Vector::<(u32, u8)>::new();
    let mut size: u32 = 0;
    let mut align: u32 = 0;
    return rec_layout(c, &c.records[ri as usize], 0, true, &mut lv, out, &mut size, &mut align);
}

// The layout of record `r` (`c_layout`'s record case): its size and alignment, each member's offset into
// `offs` (a bitfield's: the first byte it uses) and its scalar leaves into `out`, at most 17 (a bitfield's
// storage unit is one integer leaf). A `#pragma pack` caps a member's alignment, `packed` makes it 1, and
// `aligned` raises the record's. Bitfields share storage units as GCC and clang lay them out: the
// Microsoft way on Windows (`-mms-bitfields`, mingw's default: a run of one declared size shares a unit of
// that size), else the System V way (a bitfield crosses no boundary of its type's alignment, and only a
// named one aligns the record). False when a member's layout does not follow.
fn rec_layout(
    c: &Collected,
    r: &Record,
    depth: u32,
    vec: bool,
    out: &mut Vector<(u32, u8)>,
    offs: &mut Vector<u32>,
    size: &mut u32,
    align: &mut u32,
) bool {
    if !r.ok || r.attr {
        return false;
    }
    let mut at: u32 = 0; // the bytes the members use so far
    let mut bits: u32 = 0; // System V: the bits the members use so far
    let mut unit: u32 = 0; // Microsoft: the open bitfield unit's size, 0 when none is open
    let mut used: u32 = 0; // Microsoft: the bits it uses
    let mut al: u32 = 1;
    let mut fl = Vector::<(u32, u8)>::new();
    for k in 0..r.fields.len() {
        fl.truncate(0);
        let mut fs: u32 = 0;
        let mut fa: u32 = 0;
        if !c_layout(c, r.fields[k].ty.as_str(), depth + 1, vec, &mut fl, &mut fs, &mut fa) {
            return false;
        }
        if r.packed {
            fa = 1;
        } else if r.pack != 0 && fa > r.pack {
            fa = r.pack;
        }
        let w = r.fields[k].bits;
        if w >= 0 {
            let wb = w as u32;
            if fs == 0 || fs > 8 || wb > fs * 8 {
                return false;
            }
            let code = switch fs {
                1 => b'b',
                2 => b'h',
                4 => b'w',
                _ => b'q',
            };
            if r.is_union {
                offs.push(0);
                at = ast_max(at, fs);
                al = ast_max(al, pick(c.ms_bitfields || r.fields[k].name.len() != 0, fa, 1u32));
                continue;
            }
            if c.ms_bitfields {
                if wb == 0 {
                    unit = 0;
                    offs.push(at);
                    continue;
                }
                if unit != fs || used + wb > fs * 8 {
                    let o = at + fa - 1 & ~(fa - 1);
                    if out.len() <= 16 {
                        out.push((o, code));
                    }
                    at = o + fs;
                    unit = fs;
                    used = 0;
                }
                offs.push(at - fs + used / 8);
                used += wb;
                al = ast_max(al, fa);
                continue;
            }
            let mut b = ast_max(bits, at * 8);
            let ub = fa * 8;
            if wb == 0 {
                b = b + ub - 1 & ~(ub - 1);
            } else if !r.packed && b / ub != (b + wb - 1) / ub {
                b = b + ub - 1 & ~(ub - 1);
            }
            offs.push(b / 8);
            if wb != 0 && out.len() <= 16 {
                out.push((b / 8 & ~(fs - 1), code));
            }
            bits = b + wb;
            at = (bits + 7) / 8;
            if wb != 0 && r.fields[k].name.len() != 0 {
                al = ast_max(al, fa);
            }
            continue;
        }
        unit = 0;
        let o = if r.is_union {
            0u32;
        } else {
            at + fa - 1 & ~(fa - 1);
        };
        for q in 0..fl.len() {
            if out.len() <= 16 {
                out.push((o + fl[q].0, fl[q].1));
            }
        }
        offs.push(o);
        at = if r.is_union {
            ast_max(at, fs);
        } else {
            o + fs;
        };
        bits = at * 8;
        al = ast_max(al, fa);
    }
    al = ast_max(al, r.aligned);
    *size = at + al - 1 & ~(al - 1);
    *align = al;
    return true;
}

// Whether record `r`'s `#pragma pack` lowers a member's alignment (`mingw`'s `pack(push, 8)` moves no
// member of 8 bytes or less), or a member's layout does not follow.
fn pack_moves(c: &Collected, r: &Record) bool {
    let mut lv = Vector::<(u32, u8)>::new();
    for k in 0..r.fields.len() {
        lv.truncate(0);
        let mut fs: u32 = 0;
        let mut fa: u32 = 0;
        if !c_layout(c, r.fields[k].ty.as_str(), 0, true, &mut lv, &mut fs, &mut fa) || fa > r.pack {
            return true;
        }
    }
    return false;
}

// The record a rendered type (a tag or a typedef) names through its typedefs; -1 when it names none.
fn record_of_type(c: &Collected, ty: str) i32 {
    let mut t = ty;
    for _ in 0..c.aliases.len() + 1 {
        let ri = c.record_of(t);
        if ri >= 0 {
            return ri;
        }
        let ai = c.alias_of(t);
        if ai < 0 || !c.aliases[ai as usize].ok || c.aliases[ai as usize].sub.as_str() == t {
            return -1;
        }
        t = c.aliases[ai as usize].sub.as_str();
    }
    return -1;
}

// The record whose tag is `tag`, a typedef'd tagless one when `tagless`; -1 when there is none.
const fn record_index(c: &Collected, tag: str, tagless: bool) i32 {
    for i in 0..c.records.len() {
        if c.records[i].tag.as_str() == tag && c.records[i].tagless == tagless {
            return i as i32;
        }
    }
    return -1;
}

// The enum whose tag is `tag`, a typedef'd tagless one when `tagless`; -1 when there is none.
const fn enum_index(c: &Collected, tag: str, tagless: bool) i32 {
    for i in 0..c.enums.len() {
        if c.enums[i].tag.as_str() == tag && c.enums[i].tagless == tagless {
            return i as i32;
        }
    }
    return -1;
}

// The shape of C type `ty` (a rendered type, a typedef, a tag, or `struct`, `union` or `enum` and a tag)
// through its typedefs, appended to `out`: `p` a pointer, `c` a plain `char`, `b` a `_Bool`, `s<n>` and
// `u<n>` a signed and an unsigned integer of n bytes (an enum: `s4`), `f4` a `float`, `f8` a `double`,
// `v<n>` a vector of n bytes, `r:<tag>` a struct or union, `[<n>]` and the element's shape an array of n
// elements; `?` when it does not follow from the header.
fn c_shape(c: &Collected, ty: str, out: &mut String) {
    let pb = c.widths.ptr_b as u32;
    let mut t = ty;
    // Each step strips an array or follows a typedef: at most one per alias and per array level.
    for _ in 0..c.aliases.len() + 64 {
        if t.starts_with("*") || t.starts_with("fn(") {
            out.push_str("p");
            return;
        }
        if t.starts_with("[") && t.ends_with("]") {
            // `[T; N]`, the last `;` the outer extent's.
            let mut semi: isize = -1;
            for i in 1..t.len() {
                if t.byte_at(i) == b';' {
                    semi = i as isize;
                }
            }
            if semi < 0 || semi as usize + 2 >= t.len() {
                out.push_str("?");
                return;
            }
            out.format_into("[{}]", int_literal(t.slice(semi as usize + 2, t.len() - 1)));
            t = t.slice(1, semi as usize);
            continue;
        }
        let leaf = switch t {
            "i8" => "s1",
            "i16" => "s2",
            "i32" => "s4",
            "i64" => "s8",
            "u8" => "u1",
            "u16" => "u2",
            "u32" => "u4",
            "u64" => "u8",
            "isize" => pick(pb == 8, "s8", "s4"),
            "usize" => pick(pb == 8, "u8", "u4"),
            "char" => "c",
            "bool" => "b",
            "f32" => "f4",
            "f64" => "f8",
            "void" => "-",
            _ => "",
        };
        if leaf.len() != 0 {
            out.push_str(leaf);
            return;
        }
        if t.starts_with("struct ") || t.starts_with("union ") {
            let tag = t.slice(t.find_byte(b' ') as usize + 1, t.len());
            if record_index(c, tag, false) >= 0 {
                out.format_into("r:{}", tag);
            } else {
                out.push_str("?");
            }
            return;
        }
        if t.starts_with("enum ") {
            out.push_str(pick(enum_index(c, t.slice(5, t.len()), false) >= 0, "s4", "?"));
            return;
        }
        let ai = c.alias_of(t);
        if ai >= 0 && c.aliases[ai as usize].ok && c.aliases[ai as usize].sub.len() != 0 && c.aliases[ai as usize].sub.as_str() != t {
            t = c.aliases[ai as usize].sub.as_str();
            continue;
        }
        if ai >= 0 && !c.aliases[ai as usize].ok {
            out.push_str("?");
            return;
        }
        if c.record_of(t) >= 0 {
            out.format_into("r:{}", t);
            return;
        }
        let mut en = false;
        for e in 0..c.enums.len() {
            en = en || c.enums[e].tag.as_str() == t;
        }
        if en {
            out.push_str("s4");
            return;
        }
        let vb = vec_bytes(c, t);
        if vb != 0 {
            out.format_into("v{}", vb);
        } else {
            out.push_str("?");
        }
        return;
    }
    out.push_str("?");
}

// The layout of C type `ty` (a rendered member type, a typedef or a record's tag): its size, its alignment
// and its scalar leaves at their offsets (`b` `h` `w` `q` integers of 1 to 8 bytes, `f` and `d` floats,
// `p` pointers), at most 17: past 16 a calling convention passes it in memory. With `vec`, a vector
// (`f32x4`, which `vector_size` aligns to its size) counts too, as a leaf `v`: the size only. False when
// a member's layout does not follow from its type alone (a vector without `vec`, `long double`, an
// attribute, an unknown name).
fn c_layout(c: &Collected, ty: str, depth: u32, vec: bool, out: &mut Vector<(u32, u8)>, size: &mut u32, align: &mut u32) bool {
    if depth > 8 {
        return false;
    }
    let pb = c.widths.ptr_b as u32;
    if ty.starts_with("*") || ty.starts_with("fn(") {
        *size = pb;
        *align = pb;
        out.push((0, b'p'));
        return true;
    }
    if ty.starts_with("[") && ty.ends_with("]") {
        // `[T; N]`: N elements of T, the last `;` the outer extent's.
        let mut semi: isize = -1;
        for i in 1..ty.len() {
            if ty.byte_at(i) == b';' {
                semi = i as isize;
            }
        }
        if semi < 0 || semi as usize + 2 >= ty.len() {
            return false;
        }
        // A length of 0 is a flexible array member: no bytes, its element's alignment.
        let n = int_literal(ty.slice(semi as usize + 2, ty.len() - 1));
        let mut el = Vector::<(u32, u8)>::new();
        let mut es: u32 = 0;
        if n < 0 || !c_layout(c, ty.slice(1, semi as usize), depth + 1, vec, &mut el, &mut es, align) {
            return false;
        }
        *size = es * n as u32;
        // Each element adds at least one leaf: at most 17 steps.
        let mut k: u32 = 0;
        while k < n as u32 && out.len() <= 16 {
            for q in 0..el.len() {
                out.push((k * es + el[q].0, el[q].1));
            }
            k += 1;
        }
        return true;
    }
    let (sz, code) = switch ty {
        "i8" | "u8" | "bool" | "char" => (1u32, b'b'),
        "i16" | "u16" => (2u32, b'h'),
        "i32" | "u32" => (4u32, b'w'),
        "i64" | "u64" => (8u32, b'q'),
        "isize" | "usize" => (
            pb,
            if pb == 8 {
                b'q';
            } else {
                b'w';
            }
        ),
        "f32" => (4u32, b'f'),
        "f64" => (8u32, b'd'),
        _ => (0u32, 0u8),
    };
    if sz != 0 {
        *size = sz;
        *align = sz;
        out.push((0, code));
        return true;
    }
    let vb = vec_bytes(c, ty);
    if vec && vb != 0 {
        *size = vb;
        *align = vb;
        out.push((0, b'v'));
        return true;
    }
    let ri = c.record_of(ty);
    if ri >= 0 {
        let mut offs = Vector::<u32>::new();
        return rec_layout(c, &c.records[ri as usize], depth, vec, out, &mut offs, size, align);
    }
    for e in 0..c.enums.len() {
        let ed = &c.enums[e];
        if ed.tag.as_str() == ty {
            // An enum whose values fit an `int` is one (C11 6.7.2.2).
            let mut fits = ed.ok;
            for q in 0..ed.vals.len() {
                fits = fits && ed.vals[q].value >= -2147483648 && ed.vals[q].value <= 2147483647;
            }
            if !fits {
                return false;
            }
            *size = 4;
            *align = 4;
            out.push((0, b'w'));
            return true;
        }
    }
    let ai = c.alias_of(ty);
    if ai < 0 {
        return false;
    }
    let al = &c.aliases[ai as usize];
    if !al.ok || al.sub.len() == 0 || al.sub.as_str() == ty {
        return false;
    }
    return c_layout(c, al.sub.as_str(), depth + 1, vec, out, size, align);
}

const fn ast_max(a: u32, b: u32) u32 {
    return if a > b {
        a;
    } else {
        b;
    };
}

// The markers `header_facts` writes after the header: the start of the names, and before each name.
const HF_BEGIN: str = "__sc_hf_begin";
const HF_SEP: str = "__sc_hf_sep";

/// `scalar_class`: typedef `name` is not a scalar (a record, `long double`, unknown).
pub const SC_NONE: u8 = b'0';
/// `scalar_class`: an integer or a pointer.
pub const SC_INT: u8 = b'i';
/// `scalar_class`: a `float`.
pub const SC_F32: u8 = b'f';
/// `scalar_class`: a `double`.
pub const SC_F64: u8 = b'd';
/// `scalar_class`: a vector of 8-, 16-, 32- or 64-bit integers, of `float`s or of `double`s.
pub const SC_V8: u8 = b'B';
pub const SC_V16: u8 = b'H';
pub const SC_V32: u8 = b'W';
pub const SC_V64: u8 = b'Q';
pub const SC_VF32: u8 = b'F';
pub const SC_VF64: u8 = b'D';
/// `scalar_class`: a struct of 128-bit vectors only (`arm_neon.h`'s `uint8x16x2_t`), which a calling
/// convention passes as that many vectors.
pub const SC_VTUPLE: u8 = b'T';
/// A struct or union of scalars: `header_facts` gives its layout as `<size> <align>` and its leaves, each
/// ` <offset><code>` (`c_layout`).
pub const SC_REC: u8 = b'R';

// The bytes of vector type `name` (`record_vector`'s `i8x16`) through its typedefs; 0 for another type.
fn vec_bytes(c: &Collected, name: str) u32 {
    let mut n = name;
    for _ in 0..c.aliases.len() + 1 {
        let x = n.find("x");
        if x > 0 && x as usize + 1 < n.len() && is_digit(n.byte_at(x as usize + 1)) {
            let lanes = int_literal(n.slice(x as usize + 1, n.len()));
            let eb: i64 = switch n.slice(0, x as usize) {
                "i8" | "u8" => 1,
                "i16" | "u16" => 2,
                "i32" | "u32" | "f32" => 4,
                "i64" | "u64" | "f64" => 8,
                _ => 0,
            };
            return if lanes > 0 {
                (lanes * eb) as u32;
            } else {
                0;
            };
        }
        let ai = c.alias_of(n);
        if ai < 0 || c.aliases[ai as usize].opaque {
            return 0;
        }
        n = c.aliases[ai as usize].sub.as_str();
    }
    return 0;
}

// Whether struct `tag` holds 128-bit vectors only: fields of such a vector, or one array of them.
fn vec_tuple(c: &Collected, tag: str) bool {
    let ri = c.record_of(tag);
    if ri < 0 {
        return false;
    }
    let r = &c.records[ri as usize];
    if r.is_union || r.fields.len() == 0 {
        return false;
    }
    for k in 0..r.fields.len() {
        let mut t = r.fields[k].ty.as_str();
        if t.starts_with("[") {
            let semi = t.find(";");
            if semi < 0 {
                return false;
            }
            t = t.slice(1, semi as usize);
        }
        if vec_bytes(c, t) != 16 {
            return false;
        }
    }
    return true;
}

// The scalar class of typedef `name` (`SC_*`) through its chain of typedefs.
fn scalar_class(c: &Collected, name: str) u8 {
    let mut n = name;
    // Each step follows one typedef; a chain is shorter than the alias table.
    for _ in 0..c.aliases.len() + 1 {
        let ai = c.alias_of(n);
        if ai < 0 {
            return SC_NONE;
        }
        let al = &c.aliases[ai as usize];
        let sub = al.sub.as_str();
        if al.opaque && al.ok && vec_tuple(c, sub) {
            return SC_VTUPLE;
        }
        if !al.ok || al.opaque {
            return SC_NONE;
        }
        if sub.starts_with("*") || sub.starts_with("fn(") {
            return SC_INT;
        }
        // A vector (`record_vector`): its lane type, `x`, its lane count.
        let x = sub.find("x");
        if x > 0 && x as usize + 1 < sub.len() && is_digit(sub.byte_at(x as usize + 1)) {
            let v = switch sub.slice(0, x as usize) {
                "i8" | "u8" => SC_V8,
                "i16" | "u16" => SC_V16,
                "i32" | "u32" => SC_V32,
                "i64" | "u64" => SC_V64,
                "f32" => SC_VF32,
                "f64" => SC_VF64,
                _ => 0u8,
            };
            if v != 0 {
                return v;
            }
        }
        let k = switch sub {
            "i8" | "i16" | "i32" | "i64" | "isize" | "u8" | "u16" | "u32" | "u64" | "usize" | "char" | "bool" => SC_INT,
            "f32" => SC_F32,
            "f64" => SC_F64,
            _ => 0u8,
        };
        if k != 0 {
            return k;
        }
        n = sub;
    }
    return SC_NONE;
}

// One line of `text` starting at `i`, without its terminator.
const fn line_at<'a>(text: str<'a>, i: usize, end: &mut usize) str<'a> {
    let n = text.len();
    let mut e = i;
    while e < n && text.byte_at(e) != b'\n' {
        e = e + 1;
    }
    *end = e;
    return text.slice(i, e);
}

// `__SIZEOF_*__` is what the target reports, so `long` maps to what it will be: from the macros
// `index_macros` read.
fn read_widths(c: &Collected, dump: str) Widths {
    return Widths {
        short_b: size_macro(c, dump, "__SIZEOF_SHORT__", 2),
        int_b: size_macro(c, dump, "__SIZEOF_INT__", 4),
        long_b: size_macro(c, dump, "__SIZEOF_LONG__", 8),
        llong_b: size_macro(c, dump, "__SIZEOF_LONG_LONG__", 8),
        ptr_b: size_macro(c, dump, "__SIZEOF_POINTER__", 8),
    };
}

// The value of size macro `name`, else `dflt`.
fn size_macro(c: &Collected, dump: str, name: str, dflt: i32) i32 {
    let mut v = String::new();
    if !c.macro_value(dump, name, &mut v) {
        return dflt;
    }
    let b = macro_int(v.as_str());
    if b <= 0 {
        return dflt;
    }
    return b;
}

const fn macro_int(line: str) i32 {
    let n = line.len();
    let mut i = n;
    while i > 0 && line.byte_at(i - 1) != b' ' {
        i = i - 1;
    }
    // Only the `__SIZEOF_*__` widths matter, so anything that is not a small run of digits: a suffixed
    // `9223372036854775807LL`, a parenthesised expression: is not one of them.
    if n - i > 4 || n == i {
        return 0;
    }
    let mut v: i32 = 0;
    while i < n {
        let ch = line.byte_at(i);
        if !is_digit(ch) {
            return 0;
        }
        v = v * 10 + (ch - b'0') as i32;
        i = i + 1;
    }
    return v;
}

// C constant expressions
// Enumerators and object-like macros are rarely bare literals: `(1 << 8)`, `A | B`, `SOME_OTHER_MACRO`,
// `((__uint64_t)1 << 63) - 1`; and dropping every one of those loses most of a library's constants (91 of
// them in curl.h alone). This is the integer subset of C's constant expressions, with C's types: each
// value carries its type after the integer promotions, literals take the type C gives them, operands
// meet in the usual arithmetic conversions, and unsigned results wrap. It REFUSES anything else, and
// every operation whose result C leaves undefined (a signed overflow, a shift by the width or more),
// rather than guessing, because a constant that is subtly wrong is worse than absent.

struct CExpr<'a> {
    pub lx: Lexer<'a>,
    pub ok: bool,
}

// A value of a C integer constant expression: its bits `v` in a type `bits` wide (32 or 64, after the
// integer promotions; the bits above zero), unsigned when `uns`.
struct CV {
    pub v: u64,
    pub bits: u32,
    pub uns: bool,
}

const CE_DEPTH: i32 = 8;
const U64_MAX: u64 = 0xFFFFFFFFFFFFFFFF;

// The bits of a type `bits` wide.
const fn mask(bits: u32) u64 {
    return U64_MAX >> 64 - bits;
}

// The signed value of the bits `v` of a type `bits` wide.
const fn sext(v: u64, bits: u32) i64 {
    return (v << 64 - bits) as i64 >> 64 - bits;
}

// An `int` of value `v`.
const fn cv_int(v: i64) CV {
    return CV { v: v as u64 & mask(32), bits: 32, uns: false };
}

// The value of `x` in 64-bit two's complement.
const fn cv_pat(x: CV) u64 {
    if x.uns {
        return x.v;
    }
    return sext(x.v, x.bits) as u64;
}

// Whether the type `bits` wide, unsigned when `uns`, holds the value of `x`.
const fn cv_fits(x: CV, bits: u32, uns: bool) bool {
    if !x.uns && sext(x.v, x.bits) < 0 {
        return !uns && sext(x.v, x.bits) >= sext(~(mask(bits) >> 1), 64);
    }
    return x.v <= mask(bits) >> (!uns) as u32;
}

// The integer type a scalar binding names: `bits` wide (8 to 64), unsigned when `uns`; `ptr_bits` for
// `usize` and `isize`. False for any other type.
const fn int_ty(sub: str, ptr_bits: u32, bits: &mut u32, uns: &mut bool) bool {
    let b: u32 = switch sub {
        "i8" | "u8" => 8,
        "i16" | "u16" => 16,
        "i32" | "u32" => 32,
        "i64" | "u64" => 64,
        "isize" | "usize" => ptr_bits,
        _ => 0,
    };
    *bits = b;
    *uns = sub.len() != 0 && sub.byte_at(0) == b'u';
    return b != 0;
}

// The value and type of integer literal `t` under the target's widths `w`: the first type of C's list
// for its base and suffix that holds it. None when no type does, or `t` is no integer literal.
fn lit_cv(t: str, w: &Widths) Option<CV> {
    let n = t.len();
    let mut i: usize = 0;
    let mut base: u64 = 10;
    if n > 2 && t.byte_at(0) == b'0' && (t.byte_at(1) == b'x' || t.byte_at(1) == b'X') {
        base = 16;
        i = 2;
    } else if n > 2 && t.byte_at(0) == b'0' && (t.byte_at(1) == b'b' || t.byte_at(1) == b'B') {
        base = 2;
        i = 2;
    } else if t.byte_at(0) == b'0' {
        // C reads a leading 0 as octal; the 0 is its first digit.
        base = 8;
    }
    let mut v: u64 = 0;
    let mut any = false;
    while i < n {
        let ch = t.byte_at(i);
        let mut d: u64 = 16;
        if is_digit(ch) {
            d = ch - b'0';
        } else if base == 16 && ch >= b'a' && ch <= b'f' {
            d = ch - b'a' + 10;
        } else if base == 16 && ch >= b'A' && ch <= b'F' {
            d = ch - b'A' + 10;
        } else {
            break;
        }
        if d >= base || v > (U64_MAX - d) / base {
            return Option::<CV>::None;
        }
        v = v * base + d;
        any = true;
        i += 1;
    }
    // The suffix: `u`, and `l` or `ll`, in either order and case.
    let mut us: u32 = 0;
    let mut ls: u32 = 0;
    while i < n {
        let ch = t.byte_at(i);
        if ch == b'u' || ch == b'U' {
            us += 1;
        } else if ch == b'l' || ch == b'L' {
            ls += 1;
        } else {
            return Option::<CV>::None;
        }
        i += 1;
    }
    if !any || us > 1 || ls > 2 {
        return Option::<CV>::None;
    }
    // C's list: int, long and long long from the suffix's length on, each signed unless `u`, and, for
    // a hex, octal or binary literal, followed by its unsigned type.
    for k in ls..3 {
        let wb = if k == 0 {
            w.int_b;
        } else if k == 1 {
            w.long_b;
        } else {
            w.llong_b;
        } as u32 * 8;
        if us == 0 && v <= mask(wb) >> 1 {
            return Option::<CV>::Some(CV { v: v, bits: wb, uns: false });
        }
        if (us == 1 || base != 10) && v <= mask(wb) {
            return Option::<CV>::Some(CV { v: v, bits: wb, uns: true });
        }
    }
    return Option::<CV>::None;
}

extend CExpr {
    // Value `x` converted to the type `bits` wide, unsigned when `uns`: modulo 2^bits for an unsigned
    // type; refused when a signed type does not hold it.
    fn to_ty(self: &mut Self, x: CV, bits: u32, uns: bool) CV {
        if !uns && !cv_fits(x, bits, false) {
            self.ok = false;
        }
        return CV { v: cv_pat(x) & mask(bits), bits: bits, uns: uns };
    }

    // `x` after a cast to the type `bits` wide, unsigned when `uns`, then the integer promotions.
    fn cast(self: &mut Self, x: CV, bits: u32, uns: bool) CV {
        let r = self.to_ty(x, bits, uns);
        if bits < 32 {
            return CV { v: cv_pat(r) & mask(32), bits: 32, uns: false };
        }
        return r;
    }

    // Signed arithmetic traps on overflow; a result outside i64 makes the expression unknown instead.
    const fn add_checked(self: &mut Self, a: i64, b: i64) i64 {
        if b > 0 && a > I64_MAX - b || b < 0 && a < I64_MIN - b {
            self.ok = false;
            return 0;
        }
        return a + b;
    }

    const fn sub_checked(self: &mut Self, a: i64, b: i64) i64 {
        if b < 0 && a > I64_MAX + b || b > 0 && a < I64_MIN + b {
            self.ok = false;
            return 0;
        }
        return a - b;
    }

    const fn mul_checked(self: &mut Self, a: i64, b: i64) i64 {
        let mut over = false;
        if a > 0 {
            if b > 0 {
                over = a > I64_MAX / b;
            } else {
                over = b < I64_MIN / a;
            }
        } else if a < 0 {
            if b > 0 {
                over = a < I64_MIN / b;
            } else if b < 0 {
                over = a < I64_MAX / b;
            }
        }
        if over {
            self.ok = false;
            return 0;
        }
        return a * b;
    }

    // The usual arithmetic conversions of `a` and `b`, then `op` on their values: the result in the common
    // type, which an unsigned result wraps into and a signed one must fit.
    fn arith(self: &mut Self, a: CV, b: CV, op: u8) CV {
        let mut bits = if a.bits > b.bits {
            a.bits;
        } else {
            b.bits;
        };
        let mut uns = a.uns;
        if a.uns != b.uns {
            // The unsigned type when it is at least as wide, else the wider signed one, which holds it.
            let (ub, sb) = if a.uns {
                (a.bits, b.bits);
            } else {
                (b.bits, a.bits);
            };
            uns = ub >= sb;
            if !uns {
                bits = sb;
            }
        }
        let x = self.to_ty(a, bits, uns).v;
        let y = self.to_ty(b, bits, uns).v;
        if (op == b'/' || op == b'%') && y == 0 {
            self.ok = false;
            return cv_int(0);
        }
        if op == b'&' || op == b'^' || op == b'|' {
            let r = switch op {
                b'&' => x & y,
                b'^' => x ^ y,
                _ => x | y,
            };
            return CV { v: r, bits: bits, uns: uns };
        }
        if uns {
            let r = switch op {
                b'+' => x.wrapping_add(y),
                b'-' => x.wrapping_sub(y),
                b'*' => x.wrapping_mul(y),
                b'/' => x / y,
                _ => x % y,
            };
            return CV { v: r & mask(bits), bits: bits, uns: true };
        }
        let sx = sext(x, bits);
        let sy = sext(y, bits);
        if (op == b'/' || op == b'%') && sx == I64_MIN && sy == -1 {
            self.ok = false;
            return cv_int(0);
        }
        let r = switch op {
            b'+' => self.add_checked(sx, sy),
            b'-' => self.sub_checked(sx, sy),
            b'*' => self.mul_checked(sx, sy),
            b'/' => sx / sy,
            _ => sx % sy,
        };
        let out = CV { v: r as u64, bits: 64, uns: false };
        if !cv_fits(out, bits, false) {
            self.ok = false;
        }
        return CV { v: r as u64 & mask(bits), bits: bits, uns: false };
    }

    // `a << s` (`left`) or `a >> s`, of `a`'s type. A count outside the width is refused; a left shift of
    // a signed value must keep every bit inside the unsigned type of its width (the sign bit takes the
    // last, as every C compiler does).
    fn shift(self: &mut Self, a: CV, s: CV, left: bool) CV {
        if !s.uns && sext(s.v, s.bits) < 0 || cv_pat(s) >= a.bits as u64 {
            self.ok = false;
            return cv_int(0);
        }
        let n = cv_pat(s) as u32;
        if !left {
            if a.uns {
                return CV { v: a.v >> n, bits: a.bits, uns: true };
            }
            return CV { v: (sext(a.v, a.bits) >> n) as u64 & mask(a.bits), bits: a.bits, uns: false };
        }
        if !a.uns && (sext(a.v, a.bits) < 0 || a.v > mask(a.bits) >> n) {
            self.ok = false;
            return cv_int(0);
        }
        return CV { v: a.v << n & mask(a.bits), bits: a.bits, uns: a.uns };
    }

    // A cast's type name after its `(`: an integer type `bits` wide (8 to 64), unsigned when `uns`, or a
    // pointer (`T *`, or a typedef of one: an unsigned integer of the pointer's width), and the cursor past
    // the `)`. False, with the cursor unmoved, for anything else.
    fn cast_type(self: &mut Self, c: &Collected, dump: str, bits: &mut u32, uns: &mut bool) bool {
        let (p0, s0, e0, k0) = (self.lx.pos, self.lx.start, self.lx.end, self.lx.kind);
        let mut longs: u32 = 0;
        let mut shorts: u32 = 0;
        let mut chars: u32 = 0;
        let mut words: u32 = 0;
        let mut sign: u32 = 0; // 1 signed, 2 unsigned
        let mut named = String::new();
        let mut ok = true;
        while ok && self.lx.kind == TK_IDENT {
            let t = self.lx.text();
            if t == "long" {
                longs += 1;
            } else if t == "short" {
                shorts += 1;
            } else if t == "char" {
                chars += 1;
            } else if t == "signed" || t == "__signed__" {
                sign = 1;
            } else if t == "unsigned" {
                sign = 2;
            } else if t != "int" && t != "const" && t != "volatile" {
                ok = named.len() == 0;
                named.push_str(t);
            }
            words += 1;
            self.lx.advance();
        }
        let mut stars: u32 = 0;
        // Each step takes one `*` of the type: the cast's text bounds them.
        while ok && self.lx.at_punct(b'*') {
            stars += 1;
            self.lx.advance();
        }
        ok = ok && words != 0 && self.lx.at_punct(b')');
        let mut pr = String::new();
        let pb = if c.macro_value(dump, "__SIZEOF_POINTER__", &mut pr) {
            int_literal(pr.as_str()) as u32 * 8;
        } else {
            0;
        };
        let ai = c.alias_of(named.as_str());
        let ptr_alias = ai >= 0 && c.aliases.at(ai as usize).ok && (c.aliases.at(ai as usize).sub.as_str().starts_with(
            "*",
        ) || c.aliases.at(ai as usize).sub.as_str().starts_with("fn("));
        if ok && (stars != 0 || named.len() != 0 && ptr_alias) {
            ok = pb != 0;
            *bits = pb;
            *uns = true;
        } else if ok && named.len() != 0 {
            // A typedef alone: a fixed-width name, or one the header maps to an integer.
            let mut sub = String::new();
            if !wellknown(named.as_str(), &mut sub) {
                if ai >= 0 && !c.aliases.at(ai as usize).opaque && c.aliases.at(ai as usize).ok {
                    sub.push_string(&c.aliases.at(ai as usize).sub);
                }
            }
            ok = longs + shorts + chars + sign == 0 && int_ty(sub.as_str(), pb, bits, uns);
        } else if ok {
            // Plain `char` has the target's signedness: only an explicit sign is modelled.
            ok = chars == 0 || sign != 0 && chars == 1 && longs + shorts == 0;
            *uns = sign == 2;
            *bits = if chars != 0 {
                8u32;
            } else if shorts != 0 {
                c.widths.short_b as u32 * 8;
            } else if longs == 1 {
                c.widths.long_b as u32 * 8;
            } else if longs > 1 {
                c.widths.llong_b as u32 * 8;
            } else {
                c.widths.int_b as u32 * 8;
            };
        }
        if ok {
            self.lx.advance();
            return true;
        }
        self.lx.pos = p0;
        self.lx.start = s0;
        self.lx.end = e0;
        self.lx.kind = k0;
        return false;
    }

    // One name: an enumerator of the enum being built, a constant already collected, any enum's value, or
    // another macro: resolved recursively, since headers define constants in terms of each other. An
    // enumerator is an `int` when it fits one.
    fn ex_ident(self: &mut Self, c: &Collected, e: *const EnumDef, dump: str, depth: i32, name: str) CV {
        if e != null {
            let ed: &EnumDef = unsafe &*e;
            let v = ed.val_of(name);
            if v.is_some() {
                return CExpr::enum_cv(v.unwrap());
            }
        }
        for i in 0..c.consts.len() {
            if c.consts[i].name.as_str() == name {
                let lit = int_literal(c.consts[i].value.as_str());
                let mut bits: u32 = 0;
                let mut uns = false;
                if lit >= 0 && int_ty(c.consts[i].ty.as_str(), 64, &mut bits, &mut uns) {
                    return self.cast(CV { v: lit as u64, bits: 64, uns: false }, bits, uns);
                }
            }
        }
        for i in 0..c.enums.len() {
            let v = c.enums.at(i).val_of(name);
            if v.is_some() {
                return CExpr::enum_cv(v.unwrap());
            }
        }
        if depth < CE_DEPTH {
            let mut raw = String::new();
            let got = c.macro_value(dump, name, &mut raw);
            if got && raw.len() != 0 {
                let v = ce_cv(raw.as_str(), c, e, dump, depth + 1);
                if v.is_some() {
                    return v.unwrap();
                }
            }
        }
        self.ok = false;
        return cv_int(0);
    }

    const fn enum_cv(v: i64) CV {
        let x = CV { v: v as u64, bits: 64, uns: false };
        if cv_fits(x, 32, false) {
            return cv_int(v);
        }
        return x;
    }

    fn ex_primary(self: &mut Self, c: &Collected, e: *const EnumDef, dump: str, depth: i32) CV {
        if self.lx.kind == TK_EOF {
            self.ok = false;
            return cv_int(0);
        }
        if self.lx.at_punct(b'(') {
            self.lx.advance();
            let mut bits: u32 = 0;
            let mut uns = false;
            if self.cast_type(c, dump, &mut bits, &mut uns) {
                let x = self.ex_unary(c, e, dump, depth);
                return self.cast(x, bits, uns);
            }
            let v = self.ex_or(c, e, dump, depth);
            if !self.lx.at_punct(b')') {
                self.ok = false;
                return cv_int(0);
            }
            self.lx.advance();
            return v;
        }
        if self.lx.kind == TK_NUM {
            let v = lit_cv(self.lx.text(), &c.widths);
            self.lx.advance();
            if v.is_none() {
                self.ok = false;
                return cv_int(0);
            }
            return v.unwrap();
        }
        if self.lx.kind == TK_STR && self.lx.text().byte_at(0) == b'\'' {
            // A character constant is an `int`; only the plain one-byte form is modelled.
            let t = self.lx.text();
            self.lx.advance();
            if t.len() == 3 {
                return cv_int(t.byte_at(1));
            }
            self.ok = false;
            return cv_int(0);
        }
        if self.lx.kind == TK_IDENT {
            let nm = String::from_str(self.lx.text());
            self.lx.advance();
            // A call reaches here as an identifier followed by something unexpected; the caller refuses it
            // when the expression does not end cleanly.
            return self.ex_ident(c, e, dump, depth, nm.as_str());
        }
        self.ok = false;
        return cv_int(0);
    }

    // The size of the type named after `sizeof (`, and the cursor past its `)`: an integer or pointer type
    // (`cast_type`), or a record or typedef whose layout follows from the header (`c_layout`). 0 for
    // anything else.
    fn sizeof_type(self: &mut Self, c: &Collected, dump: str) u64 {
        let mut bits: u32 = 0;
        let mut uns = false;
        if self.cast_type(c, dump, &mut bits, &mut uns) {
            return bits as u64 / 8;
        }
        if self.lx.kind == TK_IDENT && (self.lx.text() == "struct" || self.lx.text() == "union") {
            self.lx.advance();
        }
        if self.lx.kind != TK_IDENT {
            return 0;
        }
        let name = String::from_str(self.lx.text());
        self.lx.advance();
        if !self.lx.at_punct(b')') {
            return 0;
        }
        self.lx.advance();
        let ai = c.alias_of(name.as_str());
        let ty = if ai >= 0 && c.aliases.at(ai as usize).ok && !c.aliases.at(ai as usize).opaque {
            c.aliases.at(ai as usize).sub.as_str();
        } else {
            name.as_str();
        };
        let mut lv = Vector::<(u32, u8)>::new();
        let mut size: u32 = 0;
        let mut align: u32 = 0;
        if !c_layout(c, ty, 0, true, &mut lv, &mut size, &mut align) {
            return 0;
        }
        return size;
    }

    fn ex_unary(self: &mut Self, c: &Collected, e: *const EnumDef, dump: str, depth: i32) CV {
        if self.lx.kind == TK_IDENT && self.lx.text() == "sizeof" {
            // `sizeof (type)`, a `size_t`.
            self.lx.advance();
            let n = if self.lx.at_punct(b'(') {
                self.lx.advance();
                self.sizeof_type(c, dump);
            } else {
                0;
            };
            if n == 0 {
                self.ok = false;
                return cv_int(0);
            }
            return CV { v: n, bits: c.widths.ptr_b as u32 * 8, uns: true };
        }
        if self.lx.at_punct(b'-') {
            self.lx.advance();
            let x = self.ex_unary(c, e, dump, depth);
            return self.arith(CV { v: 0, bits: x.bits, uns: x.uns }, x, b'-');
        }
        if self.lx.at_punct(b'+') {
            self.lx.advance();
            return self.ex_unary(c, e, dump, depth);
        }
        if self.lx.at_punct(b'~') {
            self.lx.advance();
            let x = self.ex_unary(c, e, dump, depth);
            return CV { v: ~x.v & mask(x.bits), bits: x.bits, uns: x.uns };
        }
        if self.lx.at_punct(b'!') {
            self.lx.advance();
            let x = self.ex_unary(c, e, dump, depth);
            if x.v == 0 {
                return cv_int(1);
            }
            return cv_int(0);
        }
        return self.ex_primary(c, e, dump, depth);
    }

    fn ex_mul(self: &mut Self, c: &Collected, e: *const EnumDef, dump: str, depth: i32) CV {
        let mut v = self.ex_unary(c, e, dump, depth);
        while self.lx.at_punct(b'*') || self.lx.at_punct(b'/') || self.lx.at_punct(b'%') {
            let op = self.lx.text().byte_at(0);
            self.lx.advance();
            let r = self.ex_unary(c, e, dump, depth);
            v = self.arith(v, r, op);
        }
        return v;
    }

    fn ex_add(self: &mut Self, c: &Collected, e: *const EnumDef, dump: str, depth: i32) CV {
        let mut v = self.ex_mul(c, e, dump, depth);
        while self.lx.at_punct(b'+') || self.lx.at_punct(b'-') {
            let op = self.lx.text().byte_at(0);
            self.lx.advance();
            let r = self.ex_mul(c, e, dump, depth);
            v = self.arith(v, r, op);
        }
        return v;
    }

    fn ex_shift(self: &mut Self, c: &Collected, e: *const EnumDef, dump: str, depth: i32) CV {
        let mut v = self.ex_add(c, e, dump, depth);
        // The scanner emits punctuation one byte at a time, so `<<` is two `<` in a row.
        while self.lx.at_punct(b'<') || self.lx.at_punct(b'>') {
            let left = self.lx.at_punct(b'<');
            self.lx.advance();
            if left && !self.lx.at_punct(b'<') || !left && !self.lx.at_punct(b'>') {
                self.ok = false;
                return v;
            }
            self.lx.advance();
            let sh = self.ex_add(c, e, dump, depth);
            v = self.shift(v, sh, left);
        }
        return v;
    }

    fn ex_and(self: &mut Self, c: &Collected, e: *const EnumDef, dump: str, depth: i32) CV {
        let mut v = self.ex_shift(c, e, dump, depth);
        while self.lx.at_punct(b'&') {
            self.lx.advance();
            if self.lx.at_punct(b'&') {
                // `&&` is a logical operator, not a constant this models.
                self.ok = false;
                return v;
            }
            let r = self.ex_shift(c, e, dump, depth);
            v = self.arith(v, r, b'&');
        }
        return v;
    }

    fn ex_xor(self: &mut Self, c: &Collected, e: *const EnumDef, dump: str, depth: i32) CV {
        let mut v = self.ex_and(c, e, dump, depth);
        while self.lx.at_punct(b'^') {
            self.lx.advance();
            let r = self.ex_and(c, e, dump, depth);
            v = self.arith(v, r, b'^');
        }
        return v;
    }

    fn ex_or(self: &mut Self, c: &Collected, e: *const EnumDef, dump: str, depth: i32) CV {
        let mut v = self.ex_xor(c, e, dump, depth);
        while self.lx.at_punct(b'|') {
            self.lx.advance();
            if self.lx.at_punct(b'|') {
                self.ok = false;
                return v;
            }
            let r = self.ex_xor(c, e, dump, depth);
            v = self.arith(v, r, b'|');
        }
        return v;
    }
}

// The value and type of a C integer constant expression, or None when any part of it is outside this
// subset. `e` (may be null) is an enum under construction, whose earlier enumerators are in scope.
fn ce_cv(text: str, c: &Collected, e: *const EnumDef, dump: str, depth: i32) Option<CV> {
    if text.len() == 0 || depth > CE_DEPTH {
        return Option::<CV>::None;
    }
    let mut x = CExpr::<'_> { lx: Lexer::new(text), ok: true };
    let v = x.ex_or(c, e, dump, depth);
    // Trailing tokens mean the text was never a constant expression: a call, a comma.
    if x.ok && x.lx.kind == TK_EOF {
        return Option::<CV>::Some(v);
    }
    return Option::<CV>::None;
}

// `ce_cv`'s value when an i64 holds it.
fn ce_eval(text: str, c: &Collected, e: *const EnumDef, dump: str, depth: i32) Option<i64> {
    let r = ce_cv(text, c, e, dump, depth);
    if r.is_some() && cv_fits(r.unwrap(), 64, false) {
        return Option::<i64>::Some(cv_pat(r.unwrap()) as i64);
    }
    return Option::<i64>::None;
}

// Which names the TARGET header defines. `-dM` gives every macro in scope: thousands of them, from the
// compiler and every include, and says nothing about where each came from, so the names are taken from
// the header's own text and only their VALUES are read from the dump (which is the value that
// survived the `#if`s). Function-like macros are skipped: a Super-C const cannot stand in for one.
fn header_macro_names(src: str, out: &mut Vector<String>) {
    let n = src.len();
    let mut i: usize = 0;
    while i < n {
        let mut e = i;
        while e < n && src.byte_at(e) != b'\n' {
            e = e + 1;
        }
        let mut k = i;
        while k < e && (src.byte_at(k) == b' ' || src.byte_at(k) == b'\t') {
            k = k + 1;
        }
        if k < e && src.byte_at(k) == b'#' {
            k = k + 1;
            while k < e && (src.byte_at(k) == b' ' || src.byte_at(k) == b'\t') {
                k = k + 1;
            }
            if k + 6 <= e && src.slice(k, k + 6) == "define" {
                k = k + 6;
                while k < e && (src.byte_at(k) == b' ' || src.byte_at(k) == b'\t') {
                    k = k + 1;
                }
                let ns = k;
                while k < e && is_id_body(src.byte_at(k)) {
                    k = k + 1;
                }
                // `#define F(x)` is function-like: the paren must not be adjacent to the name.
                if k > ns && (k >= e || src.byte_at(k) != b'(') {
                    out.push(String::from_str(src.slice(ns, k)));
                }
            }
        }
        i = e + 1;
    }
}

// `((-1))` -> `-1`: the parentheses C needs for hygiene carry no meaning here.
const fn strip_parens(v: str) str {
    let mut s = v;
    loop {
        if s.len() < 2 || s.byte_at(0) != b'(' || s.byte_at(s.len() - 1) != b')' {
            return s;
        }
        // Only when the two are each other's partner: `(a)+(b)` must survive intact.
        let mut depth: i32 = 0;
        let mut k: usize = 0;
        let mut matched = true;
        while k < s.len() {
            if s.byte_at(k) == b'(' {
                depth = depth + 1;
            } else if s.byte_at(k) == b')' {
                depth = depth - 1;
                if depth == 0 && k + 1 != s.len() {
                    matched = false;
                }
            }
            k = k + 1;
        }
        if !matched {
            return s;
        }
        s = s.slice(1, s.len() - 1);
    }
}

const fn is_float_text(v: str) bool {
    let mut dot = false;
    for i in 0..v.len() {
        let ch = v.byte_at(i);
        if ch == b'.' {
            dot = true;
        } else if (ch == b'e' || ch == b'E') && i != 0 {
            dot = true;
        } else if !is_digit(ch) && ch != b'+' && ch != b'-' && ch != b'f' && ch != b'F' && ch != b'l' && ch != b'L' {
            return false;
        }
    }
    return dot;
}

// Turn one macro replacement into a typed Super-C constant: an integer, float or string literal, or an
// integer expression the constant evaluator (`ce_eval`) can fold. Anything outside that subset is left
// out: a const that is subtly different from the macro is worse than no const.
fn macro_const(name: str, raw: str, c: &Collected, dump: str, out: &mut ConstDef) bool {
    let v = strip_parens(raw);
    if v.len() == 0 {
        return false;
    }
    if v.byte_at(0) == b'"' && v.byte_at(v.len() - 1) == b'"' {
        out.name.push_str(name);
        out.ty.push_str("str<'static>");
        out.value.push_str(v);
        return true;
    }
    let mut body = v;
    let mut neg = false;
    if body.byte_at(0) == b'-' {
        neg = true;
        body = body.slice(1, body.len());
    }
    if body.len() == 0 {
        return false;
    }
    if is_float_text(body) {
        let mut k = body.len();
        while k > 0 && (body.byte_at(k - 1) == b'f' || body.byte_at(k - 1) == b'F' || body.byte_at(k - 1) == b'l' || body.byte_at(
            k - 1,
        ) == b'L') {
            k = k - 1;
        }
        out.name.push_str(name);
        out.ty.push_str("f64");
        if neg {
            out.value.push_byte(b'-');
        }
        out.value.push_str(body.slice(0, k));
        return true;
    }
    // A literal, or an expression: `(1 << 8)`, `A | B`, a name standing for another macro. The evaluator
    // settles whether it is a constant at all, and refuses when any part of it is outside C's integer
    // subset. A value outside i64 is left out.
    let r = ce_cv(v, c, null, dump, 0);
    if r.is_none() || !cv_fits(r.unwrap(), 64, false) {
        return false;
    }
    let x = r.unwrap();
    let iv = cv_pat(x) as i64;
    out.name.push_str(name);
    // Unsigned only when C says so; the width is the smallest that holds the value.
    out.ty.push_str(
        if x.uns && iv > 0xFFFFFFFF {
            "u64";
        } else if x.uns {
            "u32";
        } else if cv_fits(x, 32, false) {
            "i32";
        } else {
            "i64";
        },
    );
    out.value.format_into("{}", iv);
    return true;
}

const fn type_mentions(ty: str, name: str) bool {
    let n = ty.len();
    let m = name.len();
    if m == 0 || n < m {
        return false;
    }
    let mut i: usize = 0;
    while i + m <= n {
        if ty.slice(i, i + m) == name {
            let before_ok = i == 0 || !is_id_body(ty.byte_at(i - 1));
            let after_ok = i + m == n || !is_id_body(ty.byte_at(i + m));
            if before_ok && after_ok {
                return true;
            }
        }
        i = i + 1;
    }
    return false;
}

// `super-c bindgen <header.h> [-o out.spc] [--link=NAME] [--header=SPELLING] [-I dir]... [--from=PART]...`
// Returns a process exit code.
fn run_one(
    header: str,
    out_path: str,
    link: str,
    spelling_in: str,
    incs: &Vector<String>,
    froms: &Vector<String>,
    env: &ct::CTarget,
) i32 {
    let mut hdr = String::from_str(header);
    if let Ok(abs) = fs::realpath(header) {
        hdr = abs;
    }
    let mut spelling = String::from_str(spelling_in);
    if spelling.len() == 0 {
        spelling.push_str(header);
    }

    let mut c = Collected {
        aliases: Vector::<Alias>::new(),
        fns: Vector::<FnDecl>::new(),
        opaques: Vector::<String>::new(),
        records: Vector::<Record>::new(),
        enums: Vector::<EnumDef>::new(),
        consts: Vector::<ConstDef>::new(),
        globals: Vector::<ConstDef>::new(),
        widths: Widths { short_b: 2, int_b: 4, long_b: 8, llong_b: 8, ptr_b: 8 },
        cur_mine: false,
        pending_agg: -1,
        pending_is_enum: false,
        saw_extern: false,
        skipped: 0,
        macros: Map::<String, u64>::new(),
        statics: Set::<String>::new(),
        alias_ix: Map::<String, u32>::new(),
        opaque_set: Set::<String>::new(),
        ms_bitfields: false,
        all_protos: false,
        protos: Vector::<FnDecl>::new(),
        proto_ix: Map::<String, u32>::new(),
    };

    let mut text = String::new();
    let mut mdump = String::new();
    let mut read = Vector::<String>::new();
    if !preprocess(env, hdr.as_str(), incs, Vector::<cpp::VFile>::new(), &mut text, &mut mdump, &mut read, false) {
        eprintln("super-c: the preprocessor failed on '{}'", header);
        return 1;
    }
    c.index_macros(mdump.as_str());
    c.widths = read_widths(&c, mdump.as_str());
    let win = String::from_str("_WIN32");
    c.ms_bitfields = c.macros.contains_key(&win);
    let mut lx = Lexer::new(text.as_str());
    lx.parse_unit(&mut c, hdr.as_str(), froms, mdump.as_str());
    c.collect_consts(hdr.as_str(), mdump.as_str());
    c.demote_opaque_holders();
    let mut out = String::new();
    c.emit(spelling.as_str(), link, &mut out);
    return write_out(out.as_str(), out_path, c.fns.len(), c.skipped);
}

fn write_out(text: str, out_path: str, nfns: usize, skipped: usize) i32 {
    if out_path.len() == 0 {
        if unsafe stdio::fwrite(text.ptr(), 1, text.len(), stdio::stdout()) != text.len() {
            unsafe stdio::fputs("super-c: cannot write the bindings to stdout\n".ptr() as *const char, stdio::stderr());
            return 1;
        }
        return 0;
    }
    if !write_file_atomic(out_path, text) {
        unsafe stdio::fprintf(
            stdio::stderr(),
            "super-c: cannot write '%.*s'\n".ptr() as *const char,
            out_path.len() as i32,
            out_path.ptr(),
        );
        return 1;
    }
    unsafe stdio::fprintf(
        stdio::stdout(),
        "bindgen: %d function(s) -> %.*s\n".ptr() as *const char,
        nfns as i32,
        out_path.len() as i32,
        out_path.ptr(),
    );
    if skipped != 0 {
        unsafe stdio::fprintf(
            stdio::stderr(),
            "bindgen: %d function(s) skipped -- a parameter or return type has no Super-C form\n".ptr() as *const char,
            skipped as i32,
        );
    }
    return 0;
}

// One header to convert: where it is, how the generated module spells its `#include`, and where the
// result goes.
struct Job {
    pub path: String,
    pub spelling: String,
    pub out: String,
}

fn join_path(a: str, b: str) String {
    let mut p = String::from_str(a);
    if p.len() != 0 && !p.as_str().ends_with("/") {
        p.push_byte(b'/');
    }
    p.push_str(b);
    return p;
}

// The directory part of `p`, empty when there is none.
const fn dir_part(p: str) str {
    let mut k = p.len();
    while k > 0 && p.byte_at(k - 1) != b'/' {
        k = k - 1;
    }
    if k == 0 {
        return "";
    }
    return p.slice(0, k - 1);
}

const fn stem_of(p: str) str {
    let base = loader::basename_of(p);
    if base.ends_with(".h") {
        return base.slice(0, base.len() - 2);
    }
    return base;
}

// The generated file's stem. A module is imported by its file name, so anything that cannot appear in an
// identifier becomes `_`: `typecheck-gcc.h` would otherwise produce a module nothing can import. Only
// the FILE name is rewritten; the `#include` spelling has to stay exactly what C wrote.
fn module_stem(p: str, out: &mut String) {
    let st = stem_of(p);
    for i in 0..st.len() {
        let ch = st.byte_at(i);
        if is_id_body(ch) {
            out.push_byte(ch);
        } else {
            out.push_byte(b'_');
        }
    }
}

// Every `.h` under `dir`, recursively. `rel` is the path so far BELOW the directory the user named,
// which is what the generated module uses to `#include` it: name the include root and the spellings
// come out the way C code writes them (`curl/curl.h`).
fn walk_headers(dir: str, rel: str, out_dir: str, jobs: &mut Vector<Job>) bool {
    let listed = list_dir(dir, false);
    if listed.is_none() {
        unsafe stdio::fprintf(
            stdio::stderr(),
            "super-c: cannot read directory '%.*s'\n".ptr() as *const char,
            dir.len() as i32,
            dir.ptr(),
        );
        return false;
    }
    let mut names = listed.unwrap();
    names.sort();
    let mut ok = true;
    for i in 0..names.len() {
        let child = join_path(dir, names[i].as_str());
        let crel = join_path(rel, names[i].as_str());
        if is_dir(child.as_str()) {
            if !walk_headers(child.as_str(), crel.as_str(), out_dir, jobs) {
                ok = false;
            }
        } else if names[i].as_str().ends_with(".h") {
            let o = join_path(out_dir, dir_part(crel.as_str()));
            let mut leaf = String::new();
            module_stem(crel.as_str(), &mut leaf);
            leaf.push_str(".spc");
            let full = join_path(o.as_str(), leaf.as_str());
            jobs.push(Job { path: child, spelling: crel, out: full });
            continue;
        }
    }
    return ok;
}

/// `super-c bindgen <header.h|dir>... [-o out]`. A directory is walked recursively for `.h` files, so a
/// whole library's include tree converts in one call: `-o` then names a DIRECTORY, and the tree under it
/// mirrors the headers'. A single header with no `-o` still writes to stdout. `cstd` is the project's.
pub fn run(
    paths: &Vector<String>,
    out_path: str,
    link: str,
    spelling_in: str,
    incs: &Vector<String>,
    froms: &Vector<String>,
    cflags: &Vector<String>,
    target: i32,
    arch: i32,
    sysroot: str,
    cstd: str,
) i32 {
    let mut env = ct::CTarget::new();
    if !ct::c_target(target, arch, sysroot, &mut env) {
        return 1;
    }
    // The build's C environment first, so the headers declare what the generated C compiles against;
    // `--cflag=` after it, as a manifest's `cflags` follow its `cstd`.
    let mut flags = String::new();
    push_c_env(&mut flags, cstd, target);
    flags.push_byte(b' ');
    for i in 0..cflags.len() {
        flags.push_string(&cflags[i]);
        flags.push_byte(b' ');
    }
    if !ct::apply_c_flags(flags.as_str(), &mut env) {
        return 1;
    }
    let out_is_file = out_path.ends_with(".spc");
    let out_dir = if out_is_file {
        "";
    } else {
        out_path;
    };
    let mut jobs = Vector::<Job>::new();
    let mut rc: i32 = 0;
    for i in 0..paths.len() {
        let p = paths[i].as_str();
        let isdir = is_dir(p);
        if isdir {
            if out_dir.len() == 0 {
                unsafe stdio::fputs(
                    "super-c: bindgen over a directory needs '-o <dir>' to write into\n".ptr() as *const char,
                    stdio::stderr(),
                );
                rc = 1;
                break;
            }
            if !walk_headers(p, "", out_dir, &mut jobs) {
                rc = 1;
            }
            continue;
        }
        let mut sp = String::from_str(spelling_in);
        if sp.len() == 0 {
            sp.push_str(p);
        }
        let mut o = String::new();
        if out_is_file {
            o.push_str(out_path);
        } else if out_dir.len() != 0 {
            let mut leaf = String::new();
            module_stem(p, &mut leaf);
            leaf.push_str(".spc");
            let full = join_path(out_dir, leaf.as_str());
            o.push_string(&full);
        }
        jobs.push(Job { path: String::from_str(p), spelling: sp, out: o });
    }
    if jobs.len() > 1 && out_is_file {
        unsafe stdio::fputs(
            "super-c: '-o <file>.spc' takes one header; name a directory for several\n".ptr() as *const char,
            stdio::stderr(),
        );
        rc = 1;
    } else if jobs.len() > 1 && out_dir.len() == 0 {
        unsafe stdio::fputs(
            "super-c: several headers need '-o <dir>' to write into\n".ptr() as *const char,
            stdio::stderr(),
        );
        rc = 1;
    } else {
        for i in 0..jobs.len() {
            // Each header is its own module, so one that cannot be read or preprocessed fails alone.
            let od = dir_part(jobs[i].out.as_str());
            if od.len() != 0 {
                let _ = fs::mkdir_all(od);
            }
            if run_one(jobs[i].path.as_str(), jobs[i].out.as_str(), link, jobs[i].spelling.as_str(), incs, froms, &env) != 0 {
                rc = 1;
            }
        }
        if jobs.len() > 1 {
            unsafe stdio::fprintf(
                stdio::stdout(),
                "bindgen: %d header(s) -> %.*s\n".ptr() as *const char,
                jobs.len() as i32,
                out_dir.len() as i32,
                out_dir.ptr(),
            );
        }
    }
    return rc;
}

extend Lexer {
    fn skip_noise(self: &mut Self) {
        loop {
            if self.kind != TK_IDENT {
                return;
            }
            let t = self.text();
            if noise_call(t) {
                let attr = t == "__attribute__" || t == "__attribute";
                self.advance();
                if attr {
                    self.skip_attr();
                } else {
                    self.skip_group(b'(', b')');
                }
                continue;
            }
            if noise_word(t) {
                self.advance();
                continue;
            }
            return;
        }
    }

    // Skip an `__attribute__((..))` group, noting a vector attribute in `vec`.
    fn skip_attr(self: &mut Self) {
        if !self.at_punct(b'(') {
            return;
        }
        let mut depth: i32 = 0;
        loop {
            if self.kind == TK_EOF {
                return;
            }
            if self.at_punct(b'(') {
                depth = depth + 1;
            } else if self.at_punct(b')') {
                depth = depth - 1;
                if depth == 0 {
                    self.advance();
                    return;
                }
            } else if self.kind == TK_IDENT {
                let t = self.text();
                self.lay_attr = self.lay_attr || t == "packed" || t == "__packed__" || t == "aligned" || t == "__aligned__";
                self.a_packed = self.a_packed || t == "packed" || t == "__packed__";
                if t == "aligned" || t == "__aligned__" {
                    self.advance();
                    if !self.at_punct(b'(') {
                        // The target's largest alignment: not modelled.
                        self.a_unknown = true;
                        continue;
                    }
                    self.advance();
                    let n = if self.kind == TK_NUM {
                        int_literal(self.text());
                    } else {
                        -1i64;
                    };
                    if n <= 0 {
                        self.a_unknown = true;
                    } else if n as u32 > self.a_align {
                        self.a_align = n as u32;
                    }
                    // The argument's `(`: the loop sees it next to its `)`.
                    depth = depth + 1;
                    continue;
                }
                let bytes = t == "vector_size" || t == "__vector_size__";
                let lanes = t == "neon_vector_type" || t == "__neon_vector_type__" || t == "neon_polyvector_type" || t == "ext_vector_type";
                if bytes || lanes {
                    self.advance();
                    if self.at_punct(b'(') {
                        self.advance();
                        if self.kind == TK_NUM {
                            let n = int_literal(self.text());
                            if n > 0 {
                                self.vec = if bytes {
                                    n;
                                } else {
                                    -n;
                                };
                            }
                        }
                        // The argument's `(`: the loop sees it next to its `)`.
                        depth = depth + 1;
                    }
                    continue;
                }
            }
            self.advance();
        }
    }

    // `{ NAME [= <int>] , ... }`. Auto-increment is C's, so a bare name is one past the previous value. An
    // enumerator this cannot evaluate marks the whole enum unusable rather than guessing a discriminant:
    // a wrong constant is a bug at every call site that compares against it.
    fn parse_enum_body(self: &mut Self, c: &mut Collected, tag: str, dump: str) {
        let mut e = EnumDef { tag: String::from_str(tag), vals: Vector::<EnumVal>::new(), ok: true, mine: c.cur_mine };
        // '{'.
        self.advance();
        let mut next: i64 = 0;
        let mut known = true;
        loop {
            self.skip_noise();
            if self.kind == TK_EOF || self.at_punct(b'}') {
                break;
            }
            let before = self.pos;
            if self.at_punct(b',') {
                self.advance();
                continue;
            }
            if self.kind != TK_IDENT {
                e.ok = false;
                self.advance();
                continue;
            }
            let nm = String::from_str(self.text());
            self.advance();
            self.skip_noise();
            if self.at_punct(b'=') {
                self.advance();
                self.skip_noise();
                // The whole initialiser, up to the comma or brace that ends it, handed to the constant
                // evaluator: `= 1 << 8` and `= A | B` are as common in headers as a bare number.
                let vstart = self.start;
                let mut vend = self.start;
                let mut par: i32 = 0;
                loop {
                    if self.kind == TK_EOF {
                        break;
                    }
                    if par == 0 && (self.at_punct(b',') || self.at_punct(b'}')) {
                        break;
                    }
                    if self.at_punct(b'(') {
                        par = par + 1;
                    } else if self.at_punct(b')') {
                        par = par - 1;
                    }
                    vend = self.end;
                    self.advance();
                }
                let v = ce_eval(self.src.slice(vstart, vend), c, &e, dump, 0);
                // An enumerator this cannot evaluate makes the NEXT one unknown too, since C's auto-increment
                // counts from it. Only those are dropped: the rest of the enum is still worth having.
                known = v.is_some();
                next = v.unwrap_or(0);
            }
            if known {
                e.vals.push(EnumVal { name: nm, value: next });
            }
            // C gives the enumerator after I64_MAX no representable value.
            if next == I64_MAX {
                known = false;
            } else {
                next = next + 1;
            }
            self.skip_noise();
            if !self.at_punct(b',') && !self.at_punct(b'}') {
                e.ok = false;
                break;
            }
            if self.pos == before && self.kind != TK_EOF {
                e.ok = false;
                self.advance();
            }
        }
        // Consume the rest of the body whatever happened, so the declaration after it still parses.
        while self.kind != TK_EOF && !self.at_punct(b'}') {
            self.advance();
        }
        if self.at_punct(b'}') {
            self.advance();
        }
        if e.vals.len() == 0 {
            e.ok = false;
        }
        c.enums.push(e);
    }

    // `{ <member declarations> }`. Members are ordinary declarations, so the same specifier/declarator parse
    // runs recursively. Bitfields, anonymous members and flexible arrays make the record unusable: a field
    // list cannot express them, so the record stays opaque.
    fn parse_record_body(self: &mut Self, c: &mut Collected, tag: str, is_union: bool, dump: str) {
        let mut r = Record {
            tag: String::from_str(tag),
            fields: Vector::<Field>::new(),
            is_union: is_union,
            ok: true, // a nameless body is named by the typedef that follows; emission re-checks the tag
            mine: c.cur_mine,
        };
        let la0 = self.lay_attr;
        self.lay_attr = false;
        self.rec_depth += 1;
        // '{'. A nested body is consumed by parse_specs, so the first '}' seen here closes this one.
        self.advance();
        loop {
            self.skip_noise();
            if self.kind == TK_EOF {
                break;
            }
            // A member shape this parser does not model would otherwise consume nothing and spin here
            // forever. Stepping over one token loses that member (which `ok` already records) instead
            // of the whole run.
            let before = self.pos;
            if self.at_punct(b'}') {
                self.advance();
                break;
            }
            if self.at_punct(b';') {
                self.advance();
                continue;
            }
            let mut td = false;
            let mut bc = false;
            let mut st = false;
            let base = self.parse_specs(c, &mut td, &mut bc, &mut st, dump);
            loop {
                let mut nm = String::new();
                let mut isfn = false;
                let mut va = false;
                let mut ps = Vector::<Param>::new();
                let mut adim: i64 = -1;
                let ty = self.parse_declarator(
                    c,
                    &base,
                    bc,
                    &mut nm,
                    &mut isfn,
                    &mut ps,
                    &mut va,
                    false,
                    &mut adim,
                    dump,
                );

                if self.at_punct(b':') {
                    // A bitfield (`rec_layout`): an integer type and a width, a name or none (padding).
                    r.bitf = true;
                    self.advance();
                    let w = if self.kind == TK_NUM {
                        int_literal(self.text());
                    } else {
                        -1i64;
                    };
                    if self.kind == TK_NUM {
                        self.advance();
                    }
                    if w < 0 || w > 64 || isfn || !ty.ok || adim != -1 || ty.ptr != 0 {
                        r.ok = false;
                    } else {
                        r.fields.push(
                            Field { name: String::from_str(nm.as_str()), ty: ty.base.clone(), bits: w as i32 },
                        );
                    }
                } else if nm.len() == 0 && !isfn && ty.ok && adim == -1 && ty.ptr == 0 && ty.base.as_str().starts_with(
                    "__sc_anon_",
                ) {
                    // An anonymous struct or union member: its members are the record's (`find_member`).
                    r.fields.push(Field { name: String::new(), ty: ty.base.clone(), bits: -1 });
                    r.anon = true;
                } else if nm.len() == 0 || isfn || !ty.ok || adim == -2 {
                    // A nameless member of another type, a function member, or an extent with no constant.
                    r.ok = false;
                } else {
                    let mut rt = String::new();
                    if adim >= 0 || adim == -3 {
                        // A flexible array member (`d_name[]`) is Super-C's array of length 0.
                        rt.push_byte(b'[');
                        ty.render(&mut rt);
                        rt.format_into("; {}]", pick(adim == -3, 0i64, adim));
                    } else {
                        ty.render(&mut rt);
                    }
                    r.fields.push(Field { name: String::from_str(nm.as_str()), ty: rt, bits: -1 });
                }
                self.skip_noise();
                if self.at_punct(b',') {
                    self.advance();
                    continue;
                }
                break;
            }

            if self.at_punct(b';') {
                self.advance();
            }
            if self.pos == before && self.kind != TK_EOF {
                r.ok = false;
                self.advance();
            }
        }
        if r.fields.len() == 0 {
            r.ok = false;
        }
        // An attribute after the body (`} __attribute__((packed)) T;`) changes the size or the
        // alignment, which `c_layout`'s reader compares with the declared ones.
        r.attr = self.lay_attr || self.pack_unknown;
        if self.pack.len() != 0 {
            // A power of two up to 16, as GCC and clang take it; else the layout does not follow.
            let v = ce_cv(self.pack.as_str(), c, null, dump, 0);
            let n = if v.is_some() {
                cv_pat(v.unwrap());
            } else {
                0u64;
            };
            if n == 0 || n > 16 || (n & n - 1) != 0 {
                r.attr = true;
            } else {
                r.pack = n as u32;
            }
        }
        self.lay_attr = la0 || self.lay_attr;
        self.rec_depth -= 1;
        c.records.push(r);
    }

    // Declaration specifiers: the type part of a declaration, up to the first declarator. Returns the base
    // type; `is_typedef` reports a leading `typedef`. A `struct`/`union`/`enum` body is skipped: only its tag
    // is kept, and the tag becomes an opaque type if the emitted signatures need it.
    fn parse_specs(
        self: &mut Self,
        c: &mut Collected,
        is_typedef: &mut bool,
        base_const: &mut bool,
        is_static: &mut bool,
        dump: str,
    ) CType {
        let mut ty = ctype_new();
        let mut signed = true;
        let mut explicit_sign = false;
        let mut longs: i32 = 0;
        let mut shorts: i32 = 0;
        let mut prim = String::new();
        let mut named = false;
        *is_typedef = false;
        *base_const = false;
        *is_static = false;
        loop {
            self.skip_noise();
            if self.kind != TK_IDENT {
                break;
            }
            let t = self.text();
            if t == "typedef" {
                *is_typedef = true;
                self.advance();
                continue;
            }
            if t == "const" {
                *base_const = true;
                self.advance();
                continue;
            }
            if t == "static" || t == "extern" || t == "register" || t == "auto" || t == "__thread" || t == "_Thread_local" {
                // A `static inline` helper left in the header has no external symbol to call.
                if t == "static" {
                    *is_static = true;
                }
                if t == "extern" {
                    c.saw_extern = true;
                }
                self.advance();
                continue;
            }
            if t == "unsigned" || t == "signed" || t == "__signed" || t == "__signed__" {
                signed = t != "unsigned";
                explicit_sign = true;
                self.advance();
                continue;
            }
            if t == "long" {
                longs = longs + 1;
                self.advance();
                continue;
            }
            if t == "short" {
                shorts = shorts + 1;
                self.advance();
                continue;
            }
            if t == "void" || t == "char" || t == "int" || t == "float" || t == "double" || t == "_Bool" {
                prim.clear();
                prim.push_str(t);
                self.advance();
                continue;
            }
            if t == "struct" || t == "union" || t == "enum" {
                let is_enum = t == "enum";
                let is_union = t == "union";
                self.advance();
                self.a_packed = false;
                self.a_align = 0;
                self.a_unknown = false;
                self.skip_noise();
                let mut tag = String::new();
                if self.kind == TK_IDENT {
                    tag.push_str(self.text());
                    self.advance();
                    self.skip_noise();
                }
                // The attributes before the body (`struct __attribute__((packed)) s {`).
                let lead = (self.a_packed, self.a_align, self.a_unknown);
                let mut defined = false;
                if self.at_punct(b'{') {
                    defined = true;
                    // A nameless record that types a member (`union { .. } u;`) gets a name of its own, so the
                    // member's type and the outer record's layout follow. No module declares it (`mine` is
                    // false), so a module keeps the outer record opaque (`demote_opaque_holders`).
                    let anon = !is_enum && tag.len() == 0 && self.rec_depth != 0;
                    if anon {
                        tag.format_into("__sc_anon_{}", self.anon_n);
                        self.anon_n += 1;
                    }
                    if is_enum {
                        self.parse_enum_body(c, tag.as_str(), dump);
                    } else {
                        self.parse_record_body(c, tag.as_str(), is_union, dump);
                        // And the attributes after it (`} __attribute__((packed));`).
                        self.a_packed = lead.0;
                        self.a_align = lead.1;
                        self.a_unknown = lead.2;
                        self.skip_noise();
                        let last = c.records.len() - 1;
                        let r = c.records.index_mut(last);
                        r.packed = self.a_packed;
                        r.aligned = self.a_align;
                        r.attr = r.attr || self.a_unknown;
                    }
                    if anon {
                        let last = c.records.len() - 1;
                        c.records.index_mut(last).mine = false;
                    }
                }
                if is_enum {
                    // A TAGGED enum defined here becomes a Super-C enum, so its tag names a type a signature
                    // can use; anything else is an `int` as far as a call is concerned.
                    // Named by its tag exactly when that enum is one this module emits: including at a USE
                    // site, which carries no body and is where most of them appear.
                    if tag.len() == 0 && defined {
                        // The typedef below names it, if one follows.
                        c.pending_agg = c.enums.len() as i32 - 1;
                        c.pending_is_enum = true;
                        ty.ok = false;
                    } else if tag.len() != 0 && c.enum_emitted(tag.as_str()) {
                        ty.base.push_string(&tag);
                    } else {
                        ty.base.push_str("i32");
                    }
                } else if tag.len() != 0 {
                    ty.base.push_string(&tag);
                    c.note_opaque(tag.as_str());
                } else if defined {
                    c.pending_agg = c.records.len() as i32 - 1;
                    c.pending_is_enum = false;
                    // Nameless until the typedef below names it.
                    ty.ok = false;
                } else {
                    // An anonymous struct has no name to refer to.
                    ty.ok = false;
                }
                named = true;
                break;
            }
            // The type is complete: this identifier starts the declarator. `unsigned long n` counts as
            // complete even though no type NAME was written, or the parameter's own name is swallowed as one.
            if named || prim.len() != 0 || longs > 0 || shorts > 0 || explicit_sign {
                break;
            }
            // A typedef name, or a type this tool has never heard of.
            // `size_t` means `usize` because that is what it means, not because this host happens to spell
            // it `unsigned long`, so the standard names are consulted before the typedef table.
            if wellknown(t, &mut ty.base) {
                named = true;
                self.advance();
                break;
            }
            let ai = c.alias_of(t);
            if ai >= 0 {
                // Copied out first: noting the opaque tag needs `&mut c`, which the alias borrow would hold.
                let mut sub = String::new();
                let opaque = c.aliases.at(ai as usize).opaque;
                if opaque {
                    sub.push_str(c.aliases.at(ai as usize).name.as_str());
                } else {
                    sub.push_str(c.aliases.at(ai as usize).sub.as_str());
                }
                ty.base.push_string(&sub);
                if opaque {
                    c.note_opaque(sub.as_str());
                }
                if !c.aliases.at(ai as usize).ok {
                    ty.ok = false;
                }
            } else {
                ty.ok = false;
                ty.base.push_str(t);
            }
            named = true;
            self.advance();
            break;
        }
        if !named {
            let p = prim.as_str();
            if p == "void" {
                ty.base.push_str("void");
            } else if p == "float" {
                ty.base.push_str("f32");
            } else if p == "double" {
                if longs > 0 {
                    // Long double has no Super-C counterpart.
                    ty.ok = false;
                }
                ty.base.push_str("f64");
            } else if p == "char" {
                // Bare `char` is C's string byte and Super-C's `char`; an explicitly signed one is an integer.
                if explicit_sign {
                    int_name(1, signed, &mut ty.base);
                } else {
                    ty.base.push_str("char");
                }
            } else if p == "_Bool" {
                ty.base.push_str("bool");
            } else if p == "int" || longs > 0 || shorts > 0 || explicit_sign {
                let mut b = c.widths.int_b;
                if shorts > 0 {
                    b = c.widths.short_b;
                } else if longs == 1 {
                    b = c.widths.long_b;
                } else if longs > 1 {
                    b = c.widths.llong_b;
                }
                int_name(b, signed, &mut ty.base);
            } else {
                ty.ok = false;
            }
        }
        return ty;
    }

    // One declarator: pointers, an optional name, then array/function suffixes. `name` receives the declared
    // identifier (empty for an abstract declarator). `is_fn` reports a function declarator and `params`/
    // `variadic` its signature.
    fn parse_declarator(
        self: &mut Self,
        c: &mut Collected,
        base: &CType,
        base_const: bool,
        name: &mut String,
        is_fn: &mut bool,
        params: &mut Vector<Param>,
        variadic: &mut bool,
        decay: bool,
        arr_len: &mut i64,
        dump: str,
    ) CType {
        let mut ty = base.clone();
        if base_const {
            ty.qual = ty.qual | 1u32;
        }
        *is_fn = false;
        *variadic = false;
        *arr_len = -1;
        loop {
            self.skip_noise();
            if !self.at_punct(b'*') {
                break;
            }
            self.advance();
            if ty.ptr + 1 >= MAX_PTR {
                ty.ok = false;
                ty.ptr = MAX_PTR - 1;
            } else {
                ty.ptr = ty.ptr + 1;
            }
            self.skip_noise();
            while self.kind == TK_IDENT && self.text() == "const" {
                ty.qual = ty.qual | 1u32 << ty.ptr as u32;
                self.advance();
                self.skip_noise();
            }
        }
        self.skip_noise();
        // `T (*name)(args)`: a function pointer. The inner parenthesised declarator holds the name; the
        // suffix that follows the group is the signature it points to.
        let mut fnptr = false;
        if self.at_punct(b'(') {
            let save = self.pos;
            let sk = self.kind;
            let ss = self.start;
            let se = self.end;
            self.advance();
            self.skip_noise();
            if self.at_punct(b'*') {
                fnptr = true;
                self.advance();
                self.skip_noise();
                if self.kind == TK_IDENT {
                    name.push_str(self.text());
                    self.advance();
                }
                self.skip_noise();
                if self.at_punct(b')') {
                    self.advance();
                }
            } else {
                self.pos = save;
                self.kind = sk;
                self.start = ss;
                self.end = se;
            }
        } else if self.kind == TK_IDENT {
            name.push_str(self.text());
            self.advance();
        }
        self.skip_noise();
        if self.at_punct(b'(') {
            let mut ps = Vector::<Param>::new();
            let mut va = false;
            self.parse_params(c, &mut ps, &mut va, dump);
            if fnptr {
                // Rendered here and carried as a signature: `fn(..) T` is already the pointer.
                let mut sig = String::from_str("fn(");
                let mut ok = ty.ok && !va;
                for i in 0..ps.len() {
                    if i != 0 {
                        sig.push_str(", ");
                    }
                    sig.push_string(&ps[i].ty);
                    // An unmodelled parameter poisons the pointer type like it does a function.
                    if ps[i].ty.as_str() == "?" {
                        ok = false;
                    }
                }
                sig.push_str(") ");
                ty.render(&mut sig);
                let mut out = ctype_new();
                out.ok = ok;
                out.fnsig.push_string(&sig);
                return out;
            }
            *is_fn = true;
            *variadic = va;
            *params = ps; // every caller passes an empty vector
        }
        // An array PARAMETER is a pointer: that is C's own rule. An array FIELD is not: its extent is its
        // size, so the bound is carried out and the field keeps `[T; N]`.
        let mut first = true;
        while self.at_punct(b'[') {
            if decay {
                self.skip_group(b'[', b']');
                if ty.ptr + 1 >= MAX_PTR {
                    ty.ok = false;
                } else {
                    ty.ptr = ty.ptr + 1;
                }
                continue;
            }
            self.advance();
            // The extent: a constant expression (`ce_eval`), up to the `]` that closes it; -3 when there is
            // none (a flexible array member), -2 when this tool cannot evaluate it.
            let s0 = self.start;
            let mut nest: u32 = 0;
            while self.kind != TK_EOF && (nest != 0 || !self.at_punct(b']')) {
                if self.at_punct(b'[') {
                    nest += 1;
                } else if self.at_punct(b']') {
                    nest -= 1;
                }
                self.advance();
            }
            let v = if self.kind == TK_EOF {
                -1i64;
            } else if self.start == s0 {
                -3i64;
            } else {
                ce_eval(self.src.slice(s0, self.start), c, null, dump, 0).unwrap_or(-1);
            };
            let n = if v < 0 && v != -3 {
                -2i64;
            } else {
                v;
            };
            if self.at_punct(b']') {
                self.advance();
            }
            if first {
                *arr_len = n;
            } else {
                // A second dimension: not modelled.
                *arr_len = -2;
            }
            first = false;
        }
        return ty;
    }

    fn parse_params(self: &mut Self, c: &mut Collected, out: &mut Vector<Param>, variadic: &mut bool, dump: str) {
        // '('.
        self.advance();
        let mut idx: i32 = 0;
        loop {
            self.skip_noise();
            if self.kind == TK_EOF || self.at_punct(b')') {
                break;
            }
            if self.kind == TK_PUNCT && self.text() == "..." {
                *variadic = true;
                self.advance();
                continue;
            }
            if self.at_punct(b',') {
                self.advance();
                continue;
            }
            let mut td = false;
            let mut bc = false;
            let mut st = false;
            let base = self.parse_specs(c, &mut td, &mut bc, &mut st, dump);
            let mut nm = String::new();
            let mut isfn = false;
            let mut va2 = false;
            let mut sub = Vector::<Param>::new();
            let mut adim: i64 = -1;
            let ty = self.parse_declarator(c, &base, bc, &mut nm, &mut isfn, &mut sub, &mut va2, true, &mut adim, dump);

            // `(void)` is an empty parameter list, not a parameter.
            let void_only = nm.len() == 0 && ty.ptr == 0 && ty.fnsig.len() == 0 && ty.base.as_str() == "void";
            if !void_only {
                let mut rendered = String::new();
                ty.render(&mut rendered);
                let mut pname = String::new();
                if nm.len() != 0 {
                    safe_name(nm.as_str(), &mut pname);
                } else {
                    pname.format_into("a{}", idx);
                }
                if !ty.ok {
                    rendered.clear();
                    rendered.push_str("?");
                }
                out.push(Param { name: pname, ty: rendered });
                idx = idx + 1;
            }

            self.skip_noise();
            if self.at_punct(b',') {
                self.advance();
            } else if !self.at_punct(b')') {
                // Something unmodelled: stop before it desynchronises the whole file.
                break;
            }
        }
        if self.at_punct(b')') {
            self.advance();
        }
    }

    // Walk the whole preprocessed unit. Every typedef is recorded (the target's signatures are spelled with
    // them, wherever they were declared); only declarations whose origin file is `want` are emitted.
    fn parse_unit(self: &mut Self, c: &mut Collected, want: str, extra: &Vector<String>, dump: str) {
        // The origin test stats files, so it runs once per run of declarations from one file.
        let mut here = String::new();
        let mut mine = false;
        loop {
            self.skip_noise();
            if self.kind == TK_EOF {
                return;
            }
            if self.at_punct(b';') {
                self.advance();
                continue;
            }
            if self.at_punct(b'{') {
                // A `static inline` body left in the header.
                self.skip_group(b'{', b'}');
                continue;
            }
            if self.kind != TK_IDENT {
                self.advance();
                continue;
            }
            if here.as_str() != self.file.as_str() {
                here.clear();
                here.push_str(self.file.as_str());
                mine = same_origin(here.as_str(), want, extra);
            }
            // Published for parse_specs: a struct or enum BODY is parsed from inside the specifier, which is
            // where its origin has to be known: only the target header's own records are emitted.
            c.cur_mine = mine;
            c.pending_agg = -1;
            c.saw_extern = false;
            self.vec = 0;
            let mut td = false;
            let mut bc = false;
            let mut st = false;
            let base = self.parse_specs(c, &mut td, &mut bc, &mut st, dump);
            loop {
                let mut nm = String::new();
                let mut isfn = false;
                let mut va = false;
                let mut ps = Vector::<Param>::new();
                let mut adim: i64 = -1;
                let ty = self.parse_declarator(
                    c,
                    &base,
                    bc,
                    &mut nm,
                    &mut isfn,
                    &mut ps,
                    &mut va,
                    true,
                    &mut adim,
                    dump,
                );
                // A parameter this tool could not model poisons the whole signature: a binding with a wrong
                // type is worse than a missing one, so the function is dropped rather than guessed at.
                let mut keep = nm.len() != 0 && !td && !st && isfn && mine && ty.ok;
                for i in 0..ps.len() {
                    if ps[i].ty.as_str() == "?" {
                        keep = false;
                    }
                }
                if nm.len() != 0 && td && self.vec != 0 && ty.ptr == 0 && !isfn {
                    c.record_vector(nm.as_str(), &ty, self.vec);
                } else if nm.len() != 0 && td {
                    c.record_typedef(nm.as_str(), &ty, isfn);
                }
                if nm.len() != 0 && isfn && st {
                    c.statics.insert(String::from_str(nm.as_str()));
                }
                // `extern int errno;` and friends: a global the library exports. Bound by what C itself
                // declares: a const-qualified binding becomes an extern `const` (readable), anything else a
                // `static mut`, whose accesses carry the ordinary static-mut unsafe rules across the FFI.
                if !keep && !td && !st && !isfn && mine && ty.ok && c.saw_extern && nm.len() != 0 && adim == -1 {
                    let mut vt = String::new();
                    ty.render(&mut vt);
                    let wr = ty.fnsig.len() != 0 || !ty.qual_at(ty.ptr);
                    c.globals.push(
                        ConstDef { name: String::from_str(nm.as_str()), ty: vt, value: String::new(), mutable: wr },
                    );
                }
                let key = String::from_str(nm.as_str());
                if c.all_protos && isfn && !td && nm.len() != 0 && !c.proto_ix.contains_key(&key) {
                    let mut ret = String::new();
                    if ty.ok {
                        ty.render(&mut ret);
                    } else {
                        ret.push_str("?");
                    }
                    // Only the types: a prototype check reads no parameter name.
                    let mut tys = Vector::<Param>::with_capacity(ps.len());
                    for q in 0..ps.len() {
                        tys.push(Param { name: String::new(), ty: ps[q].ty.clone() });
                    }
                    c.proto_ix.insert(key, c.protos.len() as u32);
                    c.protos.push(FnDecl { name: String::from_str(nm.as_str()), params: tys, ret: ret, variadic: va });
                }
                if keep {
                    let mut ret = String::new();
                    ty.render(&mut ret);
                    c.fns.push(FnDecl { name: String::from_str(nm.as_str()), params: ps, ret: ret, variadic: va });
                } else {
                    if isfn && mine && !td && !st && nm.len() != 0 {
                        c.skipped = c.skipped + 1;
                    }
                }

                self.skip_noise();
                if self.at_punct(b',') {
                    self.advance();
                    continue;
                }
                break;
            }

            if self.at_punct(b'{') {
                self.skip_group(b'{', b'}');
            } else if self.at_punct(b';') {
                self.advance();
            } else if self.kind != TK_EOF {
                // Unmodelled: step over one token and resynchronise on the next `;`.
                self.advance();
            }
        }
    }
}

extend Collected {
    const fn alias_of(self: &Collected, name: str) i32 {
        let key = String::from_str(name);
        return switch self.alias_ix.get(&key) {
            Some(i) => (*i) as i32,
            None => -1,
        };
    }

    fn push_alias(self: &mut Collected, a: Alias) {
        self.alias_ix.insert(a.name.clone(), self.aliases.len() as u32);
        self.aliases.push(a);
    }

    // Index the object-like macros of the `-dM` dump (`#define NAME <text>`); the first definition of
    // a name wins. A function-like macro has `(` right after its name and is left out.
    fn index_macros(self: &mut Collected, dump: str) {
        let n = dump.len();
        let mut i: usize = 0;
        while i < n {
            let mut e: usize = 0;
            let line = line_at(dump, i, &mut e);
            let off = i;
            i = e + 1;
            if !line.starts_with("#define ") {
                continue;
            }
            let mut k: usize = 8;
            while k < line.len() && line.byte_at(k) != b' ' && line.byte_at(k) != b'(' {
                k = k + 1;
            }
            if k == 8 || k >= line.len() || line.byte_at(k) != b' ' {
                continue;
            }
            let name = String::from_str(line.slice(8, k));
            if self.macros.contains_key(&name) {
                continue;
            }
            let mut a = k;
            while a < line.len() && line.byte_at(a) == b' ' {
                a = a + 1;
            }
            self.macros.insert(name, (off + a) as u64 << 32 | (off + line.len()) as u64);
        }
    }

    // The macro's replacement text from the dump `index_macros` read; empty when it has none.
    fn macro_value(self: &Collected, dump: str, name: str, out: &mut String) bool {
        let key = String::from_str(name);
        return switch self.macros.get(&key) {
            Some(v) => {
                out.push_str(dump.slice((*v >> 32) as usize, (*v & 0xFFFFFFFFu64) as usize));
                true;
            },
            None => false,
        };
    }

    fn note_opaque(self: &mut Collected, name: str) {
        let key = String::from_str(name);
        if !self.opaque_set.contains(&key) {
            self.opaques.push(key.clone());
            self.opaque_set.insert(key);
        }
    }

    const fn record_of(self: &Self, tag: str) i32 {
        for i in 0..self.records.len() {
            if self.records[i].tag.as_str() == tag {
                return i as i32;
            }
        }
        return -1;
    }

    // A typedef of a pointer-to-struct or of a struct tag keeps its own NAME as an opaque type; anything else
    // resolves to the Super-C type it stands for.
    // A vector typedef: its lane type (`ty`, through its typedefs) and `vec` (`Lexer.vec`) give the
    // portable vector type it maps to (`i8x16`, `f32x4`), unknown when the lanes are not a scalar.
    fn record_vector(self: &mut Self, name: str, ty: &CType, vec: i64) {
        if self.alias_of(name) >= 0 {
            return;
        }
        let mut el = String::new();
        ty.render(&mut el);
        // Each step follows one typedef; a chain is shorter than the alias table.
        for _ in 0..self.aliases.len() + 1 {
            let ai = self.alias_of(el.as_str());
            if ai < 0 || self.aliases[ai as usize].opaque {
                break;
            }
            el = self.aliases[ai as usize].sub.clone();
        }
        let e = if el.as_str() == "c_char" {
            "i8";
        } else {
            el.as_str();
        };
        let eb: i64 = switch e {
            "i8" | "u8" => 1,
            "i16" | "u16" => 2,
            "i32" | "u32" | "f32" => 4,
            "i64" | "u64" | "f64" => 8,
            _ => 0,
        };
        let lanes = if vec > 0 && eb != 0 {
            vec / eb;
        } else {
            -vec;
        };
        let ok = eb != 0 && lanes >= 1 && (lanes & lanes - 1) == 0;
        let sub = if ok {
            format("{}x{}", e, lanes);
        } else {
            String::from_str("?");
        };
        self.push_alias(Alias { name: String::from_str(name), sub: sub, opaque: false, ok: ok });
    }

    fn record_typedef(self: &mut Self, name: str, ty: &CType, is_fn: bool) {
        let pend = self.pending_agg;
        let pend_enum = self.pending_is_enum;
        self.pending_agg = -1;
        if is_fn || self.alias_of(name) >= 0 {
            return;
        }
        // `typedef struct { .. } Foo;`: the body carried no tag, so the typedef IS the name. Most C
        // libraries declare their types this way, so a nameless record must not be dropped.
        if pend >= 0 && ty.ptr == 0 && ty.fnsig.len() == 0 {
            let idx = pend as usize;
            if pend_enum && idx < self.enums.len() && self.enums[idx].tag.len() == 0 {
                self.enums[idx].tag.push_str(name);
                self.enums[idx].tagless = true;
                self.push_alias(
                    Alias { name: String::from_str(name), sub: String::from_str(name), opaque: true, ok: true },
                );
                return;
            }
            if !pend_enum && idx < self.records.len() && self.records[idx].tag.len() == 0 {
                self.records[idx].tag.push_str(name);
                self.records[idx].tagless = true;
                self.push_alias(
                    Alias { name: String::from_str(name), sub: String::from_str(name), opaque: true, ok: true },
                );
                return;
            }
        }
        let mut sub = String::new();
        ty.render(&mut sub);
        let opaque = ty.ptr == 0 && ty.fnsig.len() == 0 && sub.as_str() == name;
        self.push_alias(Alias { name: String::from_str(name), sub: sub, opaque: opaque, ok: ty.ok || opaque });
    }

    // Only the opaque tags the emitted signatures, record fields and globals mention: a header pulls in
    // hundreds of struct names through its own includes, and binding all of them would bury the ones a
    // caller needs.
    const fn opaque_used(self: &Self, name: str) bool {
        for i in 0..self.fns.len() {
            let f = self.fns.at(i);
            if type_mentions(f.ret.as_str(), name) {
                return true;
            }
            for j in 0..f.params.len() {
                if type_mentions(f.params[j].ty.as_str(), name) {
                    return true;
                }
            }
        }
        for i in 0..self.records.len() {
            let r = self.records.at(i);
            if !r.mine || !r.ok || r.tag.len() == 0 {
                continue;
            }
            for j in 0..r.fields.len() {
                if type_mentions(r.fields[j].ty.as_str(), name) {
                    return true;
                }
            }
        }
        for i in 0..self.globals.len() {
            if type_mentions(self.globals[i].ty.as_str(), name) {
                return true;
            }
        }
        return false;
    }

    // A tag emitted as a real `pub struct`/`pub union` must not ALSO be declared opaque: one name, one
    // definition.
    const fn record_emitted(self: &Self, tag: str) bool {
        let ri = self.record_of(tag);
        if ri < 0 {
            return false;
        }
        let r = self.records.at(ri as usize);
        return r.mine && r.ok;
    }

    const fn enum_emitted(self: &Self, tag: str) bool {
        for i in 0..self.enums.len() {
            if self.enums[i].tag.as_str() == tag {
                return self.enums[i].mine && self.enums[i].ok;
            }
        }
        return false;
    }

    // A name already spoken for. C's namespaces are separate: a macro, an enumerator and a function may all
    // be called `FOO`, but Super-C has one, so the first definition wins and the rest are left out.
    const fn name_taken(self: &Self, upto: usize, name: str) bool {
        for i in 0..self.fns.len() {
            if self.fns[i].name.as_str() == name {
                return true;
            }
        }
        for i in 0..upto {
            if self.consts[i].name.as_str() == name {
                return true;
            }
        }
        for i in 0..self.records.len() {
            if self.records[i].tag.as_str() == name && self.record_emitted(name) {
                return true;
            }
        }
        for i in 0..self.enums.len() {
            if self.enums[i].tag.as_str() == name && self.enum_emitted(name) {
                return true;
            }
        }
        return false;
    }

    // The constants the module exposes: an anonymous enum's enumerators (C's "block of constants" idiom),
    // then the target header's own object-like macros. Order matters: an enumerator is a real declaration
    // and a macro is textual, so the declaration wins any name they share.
    fn collect_consts(self: &mut Self, header: str, dump: str) {
        for i in 0..self.enums.len() {
            if !self.enums[i].mine || !self.enums[i].ok || self.enums[i].tag.len() != 0 {
                continue;
            }
            for j in 0..self.enums[i].vals.len() {
                let mut cd = ConstDef { name: String::new(), ty: String::from_str("i32"), value: String::new() };
                cd.name.push_str(self.enums[i].vals[j].name.as_str());
                cd.value.format_into("{}", self.enums[i].vals[j].value);
                if !self.name_taken(self.consts.len(), cd.name.as_str()) {
                    self.consts.push(cd);
                }
            }
        }
        let mut names = Vector::<String>::new();
        if let Some(src) = loader::read_file(header) {
            header_macro_names(src.as_str(), &mut names);
        }
        for i in 0..names.len() {
            let mut raw = String::new();
            if self.macro_value(dump, names[i].as_str(), &mut raw) {
                let mut cd = ConstDef { name: String::new(), ty: String::new(), value: String::new() };
                let ok = macro_const(names[i].as_str(), raw.as_str(), self, dump, &mut cd) && !self.name_taken(
                    self.consts.len(),
                    names[i].as_str(),
                );
                if ok {
                    self.consts.push(cd);
                }
            }
        }
    }

    // A record that holds an opaque type by value (directly or as an array element) has no layout
    // Super-C can compute, so it stays opaque too, and so does every record that holds it. Each pass
    // but the last demotes at least one record, so the record count bounds the passes. Then a
    // function that takes or returns an opaque type by value is skipped, and so is a global of one:
    // Super-C holds no value of a type without a layout.
    fn demote_opaque_holders(self: &mut Self) {
        self.demote_records();
        let mut i = self.fns.len();
        while i > 0 {
            i -= 1;
            let mut bad = self.opaque_value(self.fns[i].ret.as_str());
            for j in 0..self.fns[i].params.len() {
                bad = bad || self.opaque_value(self.fns[i].params[j].ty.as_str());
            }
            if bad {
                let _ = self.fns.remove(i);
                self.skipped += 1;
            }
        }
        i = self.globals.len();
        while i > 0 {
            i -= 1;
            if self.opaque_value(self.globals[i].ty.as_str()) {
                let _ = self.globals.remove(i);
            }
        }
    }

    // Whether rendered type `ty` holds an opaque type by value.
    const fn opaque_value(self: &Self, ty: str) bool {
        let base = by_value_base(ty);
        return base.len() != 0 && self.opaque_named(base);
    }

    fn demote_records(self: &mut Self) {
        // A `#pragma pack` below a member's alignment or a layout attribute moves members where a Super-C
        // struct does not put them, and Super-C has no anonymous member and no bitfield.
        let mut drop = Vector::<usize>::new();
        for i in 0..self.records.len() {
            let r = &self.records[i];
            if r.attr || r.anon || r.bitf || r.packed || r.aligned != 0 || r.pack != 0 && pack_moves(self, r) {
                drop.push(i);
            }
        }
        for i in 0..drop.len() {
            self.records.index_mut(drop[i]).ok = false;
        }
        for _ in 0..self.records.len() + 1 {
            let mut changed = false;
            for i in 0..self.records.len() {
                let r = self.records.at(i);
                if !r.mine || !r.ok {
                    continue;
                }
                let mut holds = false;
                for j in 0..r.fields.len() {
                    if self.opaque_value(r.fields[j].ty.as_str()) {
                        holds = true;
                        break;
                    }
                }
                if holds {
                    self.records.index_mut(i).ok = false;
                    changed = true;
                }
            }
            if !changed {
                return;
            }
        }
        assert(false, "each pass but the last demotes a record");
    }

    // Whether `name` is a type the module binds as opaque: a tag it declares but emits neither as a
    // record nor as an enum.
    const fn opaque_named(self: &Self, name: str) bool {
        if self.record_emitted(name) || self.enum_emitted(name) {
            return false;
        }
        let key = String::from_str(name);
        return self.opaque_set.contains(&key);
    }

    fn emit(self: &Self, spelling: str, link: str, out: &mut String) {
        out.format_into("// Generated by `super-c bindgen {}`; edit the generator's input, not this file.\n", spelling);
        out.push_str(
            "// Raw C bindings: every call requires `unsafe`. A struct this module cannot lay out is an opaque\n",
        );
        out.push_str("// type: use it through a pointer.\n\n");
        // A float or string constant is an ordinary top-level item and comes first; an integer one goes
        // into the extern block, whose C compile checks its value against the header. `@link` has to sit
        // on the extern block itself, so it is emitted last, immediately above it.
        let mut loose = false;
        for i in 0..self.consts.len() {
            let cd = self.consts.at(i);
            if int_const(cd) {
                continue;
            }
            out.push_str("pub const ");
            safe_name(cd.name.as_str(), out);
            out.format_into(": {} = {};\n", cd.ty.as_str(), cd.value.as_str());
            loose = true;
        }
        if loose {
            out.push_byte(b'\n');
        }
        if link.len() != 0 {
            out.format_into("@link(\"{}\")\n", link);
        }
        out.format_into("extern \"C\" \"{}\" {{\n", spelling);
        let mut first = true;
        for i in 0..self.consts.len() {
            let cd = self.consts.at(i);
            if !int_const(cd) {
                continue;
            }
            pin_keyword(cd.name.as_str(), out);
            out.push_str("    pub const ");
            safe_name(cd.name.as_str(), out);
            out.format_into(": {} = {};\n", cd.ty.as_str(), cd.value.as_str());
            first = false;
        }
        if !first {
            out.push_byte(b'\n');
            first = true;
        }
        for i in 0..self.opaques.len() {
            let nm = self.opaques[i].as_str();
            if !self.opaque_used(nm) || self.record_emitted(nm) || self.enum_emitted(nm) {
                continue;
            }
            // A tag C never typedef'd is `struct x` there, not `x`.
            let ai = self.alias_of(nm);
            if !(ai >= 0 && self.aliases.at(ai as usize).opaque) {
                out.format_into("    @import(\"struct {}\")\n", nm);
            }
            out.format_into("    pub type {};\n", nm);
            first = false;
        }
        if !first {
            out.push_byte(b'\n');
        }
        for i in 0..self.enums.len() {
            let e = self.enums.at(i);
            if !e.mine || !e.ok || e.tag.len() == 0 {
                continue;
            }
            // An enum spells as its tag (`enum x`); one with no tag as the typedef that names it.
            if e.tagless {
                out.format_into("    @import(\"{}\")\n", e.tag.as_str());
            }
            out.format_into("    pub enum {} {{\n", e.tag.as_str());
            for j in 0..e.vals.len() {
                out.push_str("        ");
                safe_name(e.vals[j].name.as_str(), out);
                out.format_into(" = {},\n", e.vals[j].value);
            }
            out.push_str("    }\n\n");
        }
        // Inside the block, so these ARE the header's types rather than look-alikes: the emitted C uses the
        // header's own definition and checks each field against it. A record spells as its tag
        // (`struct x`); one with no tag spells as the typedef that names it, which the pin carries.
        for i in 0..self.records.len() {
            let r = self.records.at(i);
            if !r.mine || !r.ok || r.tag.len() == 0 {
                continue;
            }
            let kw = if r.is_union {
                "union";
            } else {
                "struct";
            };
            if r.tagless {
                out.format_into("    @import(\"{}\")\n", r.tag.as_str());
            }
            out.format_into("    pub {} {} {{\n", kw, r.tag.as_str());
            for j in 0..r.fields.len() {
                // A member named by a keyword binds under its escaped name, pinned to the C member.
                let fname = r.fields[j].name.as_str();
                if keyword(fname) {
                    out.format_into("        @import(\"{}\")\n", fname);
                }
                out.push_str("        pub ");
                safe_name(fname, out);
                out.format_into(": {},\n", r.fields[j].ty.as_str());
            }
            out.push_str("    }\n\n");
        }
        for i in 0..self.globals.len() {
            let g = self.globals.at(i);
            pin_keyword(g.name.as_str(), out);
            out.push_str(
                if g.mutable {
                    "    pub static mut ";
                } else {
                    "    pub const ";
                },
            );
            safe_name(g.name.as_str(), out);
            out.format_into(": {};\n", g.ty.as_str());
        }
        if self.globals.len() != 0 {
            out.push_byte(b'\n');
        }
        for i in 0..self.fns.len() {
            let f = self.fns.at(i);
            pin_keyword(f.name.as_str(), out);
            out.push_str("    pub fn ");
            safe_name(f.name.as_str(), out);
            out.push_byte(b'(');
            for j in 0..f.params.len() {
                if j != 0 {
                    out.push_str(", ");
                }
                out.format_into("{}: {}", f.params[j].name.as_str(), f.params[j].ty.as_str());
            }
            if f.variadic {
                if f.params.len() != 0 {
                    out.push_str(", ");
                }
                out.push_str("...");
            }
            out.format_into(") {};\n", f.ret.as_str());
        }
        out.push_str("}\n");
    }
}
