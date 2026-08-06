// `super-c bindgen <header.h>`: turn a C library's header into a Super-C `extern "C"` module.
//
// The C is read through the SYSTEM PREPROCESSOR rather than parsed from source: `cc -E` resolves every
// `#include`, `#if` and macro, so what reaches the parser here is a flat list of declarations with no
// preprocessor left in it, and the same toolchain that will compile the emitted C decides what those
// declarations are. `cc -E -dM` supplies the target's integer widths, so `long` maps by what this toolchain
// says it is rather than by assumption.
//
// The preprocessor also says where each declaration CAME FROM (`# <line> "<file>"` markers), which is what
// separates the requested header's own declarations from the thousands its includes drag in. Everything is
// parsed -- a typedef from <stddef.h> is needed to resolve one in the target -- but only declarations whose
// origin is the requested header are emitted.
//
// Scope: functions, the typedefs needed to spell their signatures, enums (tagged ones as `enum`, anonymous
// enumerators and object-like macros as constants), fielded structs/unions where every member is modelable
// (the emitted C layout-asserts them against the header on every target; bitfields and anonymous members
// fall back to opaque), `extern` globals (const-qualified as `const`, writable as `static mut`), and opaque
// `pub type` for everything reached only through a pointer. Function-LIKE macros cannot appear at all: the
// preprocessor has already expanded them away by the time anything here runs.

import stdio;
import stdlib;
import driver_shim as shim;
import module::loader as loader;
import string as cstring;
import driver::util as *;

// ---------------------------------------------------------------------------------------------------------
// scanning
// ---------------------------------------------------------------------------------------------------------

const TK_EOF: i32 = 0;
const TK_IDENT: i32 = 1;
const TK_NUM: i32 = 2;
const TK_PUNCT: i32 = 3;
const TK_STR: i32 = 4;

/// A token cursor over preprocessed C. Line markers are consumed by the scanner itself and published as
/// `file`, so the parser never sees a directive and always knows the declaration's origin.
struct Lexer<'a> {
    pub src: str<'a>,
    pub pos: usize,
    pub kind: i32,
    pub start: usize,
    pub end: usize,
    pub file: String, // the `# <line> "<file>"` most recently passed
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

extend Lexer<'a> as Free {
    fn free(self: &mut Lexer<'a>) {
        self.file.free();
    }
}

extend Lexer<'a> {
    fn new(src: str<'a>) Lexer<'a> {
        let mut lx = Lexer::<'a> { src: src, pos: 0, kind: TK_EOF, start: 0, end: 0, file: String::new() };
        lx.advance();
        return lx;
    }

    fn text(self: &Lexer<'a>) str {
        return self.src.slice(self.start, self.end);
    }

    fn at_punct(self: &Lexer<'a>, c: u8) bool {
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
        let mut got = false;
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
                got = true;
            }
        }
        let _ = got;
        while self.pos < n && self.src.byte_at(self.pos) != b'\n' {
            self.pos = self.pos + 1;
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

// ---------------------------------------------------------------------------------------------------------
// C types
// ---------------------------------------------------------------------------------------------------------

const MAX_PTR: usize = 8;

/// One C type as far as this tool models it: a base name already mapped to Super-C, a pointer depth, and
/// a bit per level saying whether THAT level's pointee is const (bit 0 is the base's own `const`). A
/// function pointer carries its rendered Super-C signature instead, since `fn(..) T` is already a pointer.
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

extend CType as Free {
    fn free(self: &mut CType) {
        self.base.free();
        self.fnsig.free();
    }
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

    /// The Super-C spelling. Pointers render outermost first, each one `*const` or `*mut` by what it points
    /// at -- C's `const char *` is a pointer to const, C's `char *const` is a const binding and says nothing
    /// about the pointee, which is why only the pointee's qualifier survives here.
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
        "size_t" => {
            "usize";
        },
        "ssize_t" => {
            "isize";
        },
        "ptrdiff_t" => {
            "isize";
        },
        "intptr_t" => {
            "isize";
        },
        "uintptr_t" => {
            "usize";
        },
        "int8_t" => {
            "i8";
        },
        "int16_t" => {
            "i16";
        },
        "int32_t" => {
            "i32";
        },
        "int64_t" => {
            "i64";
        },
        "uint8_t" => {
            "u8";
        },
        "uint16_t" => {
            "u16";
        },
        "uint32_t" => {
            "u32";
        },
        "uint64_t" => {
            "u64";
        },
        "_Bool" => {
            "bool";
        },
        "bool" => {
            "bool";
        },
        "va_list" => {
            "va_list";
        },
        "__builtin_va_list" => {
            "va_list";
        },
        "__gnuc_va_list" => {
            "va_list";
        },
        _ => {
            "";
        },
    };
    if sub.len() == 0 {
        return false;
    }
    out.push_str(sub);
    return true;
}

/// Widths this toolchain reports through `cc -E -dM`, so `long` and friends map by measurement.
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

// ---------------------------------------------------------------------------------------------------------
// what was collected
// ---------------------------------------------------------------------------------------------------------

struct Param {
    pub name: String,
    pub ty: String,
}

extend Param as Free {
    fn free(self: &mut Param) {
        self.name.free();
        self.ty.free();
    }
}

struct FnDecl {
    pub name: String,
    pub params: Vector<Param>,
    pub ret: String,
    pub variadic: bool,
}

extend FnDecl as Free {
    fn free(self: &mut FnDecl) {
        self.name.free();
        self.params.free();
        self.ret.free();
    }
}

struct Alias {
    pub name: String, // the C typedef / struct tag
    pub sub: String, // what it maps to in Super-C ("" while it is an opaque tag)
    pub opaque: bool,
    /// False when the typedef's own type could not be modelled. Carried so that a signature spelled with
    /// it is dropped too: the alias table would otherwise launder an unknown C type into a plausible name.
    pub ok: bool,
}

extend Alias as Free {
    fn free(self: &mut Alias) {
        self.name.free();
        self.sub.free();
    }
}

/// Everything the parse produced: the type environment (every typedef in the whole translation unit, since
/// the target header's signatures are spelled with them) and the declarations from the target header alone.
struct Field {
    pub name: String,
    pub ty: String,
}

extend Field as Free {
    fn free(self: &mut Field) {
        self.name.free();
        self.ty.free();
    }
}

/// A struct or union DEFINED in the target header. `ok` is false as soon as one member has no faithful
/// Super-C form -- a bitfield, an anonymous member, a flexible array, an unmodelled type -- because a
/// record with a field silently dropped has the wrong LAYOUT, and every call through it would corrupt
/// memory. Such a record falls back to the opaque `pub type`, which is merely limited rather than wrong.
struct Record {
    pub tag: String,
    pub fields: Vector<Field>,
    pub is_union: bool,
    pub ok: bool,
    pub mine: bool,
}

extend Record as Free {
    fn free(self: &mut Record) {
        self.tag.free();
        self.fields.free();
    }
}

struct EnumVal {
    pub name: String,
    pub value: i64,
}

extend EnumVal as Free {
    fn free(self: &mut EnumVal) {
        self.name.free();
    }
}

/// A C enum. A TAGGED one becomes a Super-C `enum` (its tag is a type a signature can name); an anonymous
/// one is the "block of constants" idiom and becomes plain consts, which is how C code uses it.
struct EnumDef {
    pub tag: String,
    pub vals: Vector<EnumVal>,
    pub ok: bool,
    pub partial: bool, // at least one enumerator was not evaluable and is absent
    pub mine: bool,
}

extend EnumDef as Free {
    fn free(self: &mut EnumDef) {
        self.tag.free();
        self.vals.free();
    }
}

struct ConstDef {
    pub name: String,
    pub ty: String,
    pub value: String,
    pub mutable: bool, // a global whose C declaration is not const: bound as `static mut`
}

extend ConstDef as Free {
    fn free(self: &mut ConstDef) {
        self.name.free();
        self.ty.free();
        self.value.free();
    }
}

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
    /// The anonymous struct/union/enum body just parsed, waiting for the typedef that names it
    /// (`typedef struct { .. } Foo;` is how most C libraries declare their types). -1 when there is none.
    pub pending_agg: i32,
    pub pending_is_enum: bool,
    pub saw_extern: bool, // the declaration being parsed carried `extern`: a variable, not a definition
    /// Functions from the target header whose signature this tool could not model. Reported rather than
    /// swallowed: a binding file that is quietly short is worse than one that says what it left out.
    pub skipped: usize,
}

extend Collected as Free {
    fn free(self: &mut Collected) {
        self.records.free();
        self.enums.free();
        self.consts.free();
        self.globals.free();
        self.aliases.free();
        self.fns.free();
        self.opaques.free();
    }
}

extend Collected {
    fn alias_of(self: &Collected, name: str) i32 {
        for i in 0..self.aliases.len() {
            if self.aliases[i].name.as_str() == name {
                return i as i32;
            }
        }
        return -1;
    }

    fn note_opaque(self: &mut Collected, name: str) {
        for i in 0..self.opaques.len() {
            if self.opaques[i].as_str() == name {
                return;
            }
        }
        self.opaques.push(String::from_str(name));
    }
}

// ---------------------------------------------------------------------------------------------------------
// parsing declarations
// ---------------------------------------------------------------------------------------------------------

// Vendor noise that carries no meaning for a binding. `__attribute__`, `__declspec` and `asm` take a
// parenthesised argument; the rest are bare words.
fn noise_word(s: str) bool {
    return s == "__extension__" || s == "__inline" || s == "__inline__" || s == "inline" || s == "__restrict" || s == "__restrict__" || s == "restrict" || s == "_Nullable" || s == "_Nonnull" || s == "_Null_unspecified" || s == "__nullable" || s == "__nonnull" || s == "_Noreturn" || s == "__cdecl" || s == "__stdcall" || s == "__fastcall" || s == "__volatile" || s == "volatile" || s == "_Atomic" || s == "__pragma" || s == "__forceinline";
}

fn noise_call(s: str) bool {
    return s == "__attribute__" || s == "__attribute" || s == "__declspec" || s == "asm" || s == "__asm" || s == "__asm__" || s == "__has_attribute";
}

fn skip_noise(lx: &mut Lexer) {
    loop {
        if lx.kind != TK_IDENT {
            return;
        }
        let t = lx.text();
        if noise_call(t) {
            lx.advance();
            lx.skip_group(b'(', b')');
            continue;
        }
        if noise_word(t) {
            lx.advance();
            continue;
        }
        return;
    }
}

// A Super-C keyword cannot name a parameter; a trailing underscore keeps the C name recognisable.
fn keyword(s: str) bool {
    return s == "as" || s == "import" || s == "break" || s == "case" || s == "const" || s == "continue" || s == "defer" || s == "asm" || s == "do" || s == "dyn" || s == "else" || s == "enum" || s == "extern" || s == "false" || s == "fn" || s == "for" || s == "if" || s == "extend" || s == "in" || s == "let" || s == "loop" || s == "switch" || s == "move" || s == "mut" || s == "new" || s == "null" || s == "pub" || s == "sizeof" || s == "alignof" || s == "return" || s == "self" || s == "Self" || s == "struct" || s == "interface" || s == "true" || s == "type" || s == "union" || s == "unsafe" || s == "where" || s == "while" || s == "str" || s == "int";
}

fn safe_name(s: str, out: &mut String) {
    out.push_str(s);
    if keyword(s) {
        out.push_byte(b'_');
    }
}

fn record_of(c: &Collected, tag: str) i32 {
    for i in 0..c.records.len() {
        if c.records[i].tag.as_str() == tag {
            return i as i32;
        }
    }
    return -1;
}

// An integer written in a C enumerator or an array bound: decimal, hex or a character, with the suffixes
// and sign C allows. -1 means "not a plain integer", which is what makes the caller fall back.
fn int_literal(t: str) i64 {
    let n = t.len();
    if n == 0 {
        return -1;
    }
    let mut i: usize = 0;
    let mut base: i64 = 10;
    if n > 2 && t.byte_at(0) == b'0' && (t.byte_at(1) == b'x' || t.byte_at(1) == b'X') {
        base = 16;
        i = 2;
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
            break; // a width suffix, not a digit
        } else {
            return -1;
        }
        if d >= base {
            return -1;
        }
        if v > 0x0FFFFFFFFFFFFFFF {
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

/// `{ NAME [= <int>] , ... }`. Auto-increment is C's, so a bare name is one past the previous value. An
/// enumerator this cannot evaluate marks the whole enum unusable rather than guessing a discriminant --
/// a wrong constant is a bug at every call site that compares against it.
fn parse_enum_body(lx: &mut Lexer, c: &mut Collected, tag: str, dump: str) {
    let mut e = EnumDef { tag: String::from_str(tag), vals: Vector::<EnumVal>::new(), ok: true, mine: c.cur_mine };
    lx.advance(); // '{'
    let mut next: i64 = 0;
    let mut known = true;
    loop {
        skip_noise(lx);
        if lx.kind == TK_EOF || lx.at_punct(b'}') {
            break;
        }
        let before = lx.pos;
        if lx.at_punct(b',') {
            lx.advance();
            continue;
        }
        if lx.kind != TK_IDENT {
            e.ok = false;
            lx.advance();
            continue;
        }
        let nm = String::from_str(lx.text());
        lx.advance();
        skip_noise(lx);
        if lx.at_punct(b'=') {
            lx.advance();
            skip_noise(lx);
            // The whole initialiser, up to the comma or brace that ends it, handed to the constant
            // evaluator: `= 1 << 8` and `= A | B` are as common in headers as a bare number.
            let vstart = lx.start;
            let mut vend = lx.start;
            let mut par: i32 = 0;
            loop {
                if lx.kind == TK_EOF {
                    break;
                }
                if par == 0 && (lx.at_punct(b',') || lx.at_punct(b'}')) {
                    break;
                }
                if lx.at_punct(b'(') {
                    par = par + 1;
                } else if lx.at_punct(b')') {
                    par = par - 1;
                }
                vend = lx.end;
                lx.advance();
            }
            let mut got = false;
            let v = ce_eval(lx.src.slice(vstart, vend), c, &e, dump, 0, &mut got);
            next = v;
            // An enumerator this cannot evaluate makes the NEXT one unknown too, since C's auto-increment
            // counts from it. Only those are dropped -- the rest of the enum is still worth having.
            known = got;
        }
        if known {
            e.vals.push(EnumVal { name: nm, value: next });
        } else {
            nm.free();
            e.partial = true;
        }
        next = next + 1;
        skip_noise(lx);
        if !lx.at_punct(b',') && !lx.at_punct(b'}') {
            e.ok = false;
            break;
        }
        if lx.pos == before && lx.kind != TK_EOF {
            e.ok = false;
            lx.advance();
        }
    }
    // Consume the rest of the body whatever happened, so the declaration after it still parses.
    while lx.kind != TK_EOF && !lx.at_punct(b'}') {
        lx.advance();
    }
    if lx.at_punct(b'}') {
        lx.advance();
    }
    if e.vals.len() == 0 {
        e.ok = false;
    }
    c.enums.push(e);
}

fn enum_val_of(e: &EnumDef, name: str, out: *mut i64) bool {
    for i in 0..e.vals.len() {
        if e.vals[i].name.as_str() == name {
            unsafe *out = e.vals[i].value;
            return true;
        }
    }
    return false;
}

/// `{ <member declarations> }`. Members are ordinary declarations, so the same specifier/declarator parse
/// runs recursively. Bitfields, anonymous members and flexible arrays make the record unusable: each one
/// changes the LAYOUT in a way a field list cannot express, and a record with the wrong layout is worse
/// than no record at all.
fn parse_record_body(lx: &mut Lexer, c: &mut Collected, tag: str, is_union: bool, dump: str) {
    let mut r = Record {
        tag: String::from_str(tag),
        fields: Vector::<Field>::new(),
        is_union: is_union,
        ok: true, // a nameless body is named by the typedef that follows; emission re-checks the tag
        mine: c.cur_mine,
    };
    lx.advance(); // '{'
    let mut depth: i32 = 1;
    loop {
        skip_noise(lx);
        if lx.kind == TK_EOF {
            break;
        }
        // A member shape this parser does not model would otherwise consume nothing and spin here
        // forever. Stepping over one token loses that member -- which `ok` already records -- instead
        // of the whole run.
        let before = lx.pos;
        if lx.at_punct(b'}') {
            lx.advance();
            depth = depth - 1;
            if depth == 0 {
                break;
            }
            continue;
        }
        if lx.at_punct(b';') {
            lx.advance();
            continue;
        }
        let mut td = false;
        let mut bc = false;
        let mut st = false;
        let base = parse_specs(lx, c, &mut td, &mut bc, &mut st, dump);
        let mut any = false;
        loop {
            let mut nm = String::new();
            let mut isfn = false;
            let mut va = false;
            let mut ps = Vector::<Param>::new();
            let mut adim: i64 = -1;
            let ty = parse_declarator(lx, c, &base, bc, &mut nm, &mut isfn, &mut ps, &mut va, false, &mut adim, dump);
            ps.free();
            if lx.at_punct(b':') {
                r.ok = false; // a bitfield: its width is not a field type
                lx.advance();
                if lx.kind == TK_NUM {
                    lx.advance();
                }
            }
            if nm.len() == 0 || isfn || !ty.ok || adim == -2 {
                r.ok = false; // an anonymous member, a function member, or an extent with no constant
            } else {
                let mut rt = String::new();
                if adim >= 0 {
                    rt.push_byte(b'[');
                    ty.render(&mut rt);
                    rt.format_into("; {}]", adim);
                } else {
                    ty.render(&mut rt);
                }
                let mut fname = String::new();
                safe_name(nm.as_str(), &mut fname);
                r.fields.push(Field { name: fname, ty: rt });
            }
            any = true;
            nm.free();
            ty.free();
            skip_noise(lx);
            if lx.at_punct(b',') {
                lx.advance();
                continue;
            }
            break;
        }
        base.free();
        let _ = any;
        if lx.at_punct(b';') {
            lx.advance();
        }
        if lx.pos == before && lx.kind != TK_EOF {
            r.ok = false;
            lx.advance();
        }
    }
    if r.fields.len() == 0 {
        r.ok = false;
    }
    c.records.push(r);
}

/// Declaration specifiers: the type part of a declaration, up to the first declarator. Returns the base
/// type; `is_typedef` reports a leading `typedef`. A `struct`/`union`/`enum` body is skipped -- only its tag
/// is kept, and the tag becomes an opaque type if the emitted signatures need it.
fn parse_specs(
    lx: &mut Lexer,
    c: &mut Collected,
    is_typedef: *mut bool,
    base_const: *mut bool,
    is_static: *mut bool,
    dump: str,
) CType {
    let mut ty = ctype_new();
    let mut signed = true;
    let mut explicit_sign = false;
    let mut longs: i32 = 0;
    let mut shorts: i32 = 0;
    let mut prim = String::new();
    let mut named = false;
    unsafe *is_typedef = false;
    unsafe *base_const = false;
    unsafe *is_static = false;
    loop {
        skip_noise(lx);
        if lx.kind != TK_IDENT {
            break;
        }
        let t = lx.text();
        if t == "typedef" {
            unsafe *is_typedef = true;
            lx.advance();
            continue;
        }
        if t == "const" {
            unsafe *base_const = true;
            lx.advance();
            continue;
        }
        if t == "static" || t == "extern" || t == "register" || t == "auto" || t == "__thread" || t == "_Thread_local" {
            // A `static inline` helper left in the header has no external symbol to call.
            if t == "static" {
                unsafe *is_static = true;
            }
            if t == "extern" {
                c.saw_extern = true;
            }
            lx.advance();
            continue;
        }
        if t == "unsigned" || t == "signed" || t == "__signed" || t == "__signed__" {
            signed = t != "unsigned";
            explicit_sign = true;
            lx.advance();
            continue;
        }
        if t == "long" {
            longs = longs + 1;
            lx.advance();
            continue;
        }
        if t == "short" {
            shorts = shorts + 1;
            lx.advance();
            continue;
        }
        if t == "void" || t == "char" || t == "int" || t == "float" || t == "double" || t == "_Bool" {
            prim.clear();
            prim.push_str(t);
            lx.advance();
            continue;
        }
        if t == "struct" || t == "union" || t == "enum" {
            let is_enum = t == "enum";
            let is_union = t == "union";
            lx.advance();
            skip_noise(lx);
            let mut tag = String::new();
            if lx.kind == TK_IDENT {
                tag.push_str(lx.text());
                lx.advance();
            }
            let mut defined = false;
            if lx.at_punct(b'{') {
                defined = true;
                if is_enum {
                    parse_enum_body(lx, c, tag.as_str(), dump);
                } else {
                    parse_record_body(lx, c, tag.as_str(), is_union, dump);
                }
            }
            if is_enum {
                // A TAGGED enum defined here becomes a Super-C enum, so its tag names a type a signature
                // can use; anything else is an `int` as far as a call is concerned.
                // Named by its tag exactly when that enum is one this module emits -- including at a USE
                // site, which carries no body and is where most of them appear.
                if tag.len() == 0 && defined {
                    c.pending_agg = c.enums.len() as i32 - 1; // the typedef below names it, if one follows
                    c.pending_is_enum = true;
                    ty.ok = false;
                } else if tag.len() != 0 && enum_emitted(c, tag.as_str()) {
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
                ty.ok = false; // nameless until the typedef below names it
            } else {
                ty.ok = false; // an anonymous struct has no name to refer to
            }
            named = true;
            tag.free();
            break;
        }
        // The type is complete -- this identifier starts the declarator. `unsigned long n` counts as
        // complete even though no type NAME was written, or the parameter's own name is swallowed as one.
        if named || prim.len() != 0 || longs > 0 || shorts > 0 || explicit_sign {
            break;
        }
        // A typedef name, or a type this tool has never heard of.
        // `size_t` means `usize` because that is what it means, not because this host happens to spell
        // it `unsigned long` -- so the standard names are consulted before the typedef table.
        if wellknown(t, &mut ty.base) {
            named = true;
            lx.advance();
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
            sub.free();
        } else {
            ty.ok = false;
            ty.base.push_str(t);
        }
        named = true;
        lx.advance();
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
                ty.ok = false; // long double has no Super-C counterpart
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
    prim.free();
    return ty;
}

/// One declarator: pointers, an optional name, then array/function suffixes. `name` receives the declared
/// identifier (empty for an abstract declarator). `is_fn` reports a function declarator and `params`/
/// `variadic` its signature.
fn parse_declarator(
    lx: &mut Lexer,
    c: &mut Collected,
    base: &CType,
    base_const: bool,
    name: &mut String,
    is_fn: *mut bool,
    params: &mut Vector<Param>,
    variadic: *mut bool,
    decay: bool,
    arr_len: *mut i64,
    dump: str,
) CType {
    let mut ty = base.clone();
    if base_const {
        ty.qual = ty.qual | 1u32;
    }
    unsafe *is_fn = false;
    unsafe *variadic = false;
    unsafe *arr_len = -1;
    loop {
        skip_noise(lx);
        if !lx.at_punct(b'*') {
            break;
        }
        lx.advance();
        if ty.ptr + 1 >= MAX_PTR {
            ty.ok = false;
            ty.ptr = MAX_PTR - 1;
        } else {
            ty.ptr = ty.ptr + 1;
        }
        skip_noise(lx);
        while lx.kind == TK_IDENT && lx.text() == "const" {
            ty.qual = ty.qual | 1u32 << ty.ptr as u32;
            lx.advance();
            skip_noise(lx);
        }
    }
    skip_noise(lx);
    // `T (*name)(args)`: a function pointer. The inner parenthesised declarator holds the name; the
    // suffix that follows the group is the signature it points to.
    let mut fnptr = false;
    if lx.at_punct(b'(') {
        let save = lx.pos;
        let sk = lx.kind;
        let ss = lx.start;
        let se = lx.end;
        lx.advance();
        skip_noise(lx);
        if lx.at_punct(b'*') {
            fnptr = true;
            lx.advance();
            skip_noise(lx);
            if lx.kind == TK_IDENT {
                name.push_str(lx.text());
                lx.advance();
            }
            skip_noise(lx);
            if lx.at_punct(b')') {
                lx.advance();
            }
        } else {
            lx.pos = save;
            lx.kind = sk;
            lx.start = ss;
            lx.end = se;
        }
    } else if lx.kind == TK_IDENT {
        name.push_str(lx.text());
        lx.advance();
    }
    skip_noise(lx);
    if lx.at_punct(b'(') {
        let mut ps = Vector::<Param>::new();
        let mut va = false;
        parse_params(lx, c, &mut ps, &mut va, dump);
        if fnptr {
            // Rendered here and carried as a signature: `fn(..) T` is already the pointer.
            let mut sig = String::from_str("fn(");
            for i in 0..ps.len() {
                if i != 0 {
                    sig.push_str(", ");
                }
                sig.push_string(&ps[i].ty);
            }
            sig.push_str(") ");
            ty.render(&mut sig);
            let mut out = ctype_new();
            out.ok = ty.ok && !va;
            out.fnsig.push_string(&sig);
            sig.free();
            ps.free();
            ty.free();
            return out;
        }
        unsafe *is_fn = true;
        unsafe *variadic = va;
        for i in 0..ps.len() {
            params.push(Param { name: String::from_str(ps[i].name.as_str()), ty: String::from_str(ps[i].ty.as_str()) });
        }
        ps.free();
    }
    // An array PARAMETER is a pointer -- that is C's own rule. An array FIELD is not: dropping its extent
    // would change the record's layout, so the bound is carried out and the field keeps `[T; N]`.
    let mut first = true;
    while lx.at_punct(b'[') {
        if decay {
            lx.skip_group(b'[', b']');
            if ty.ptr + 1 >= MAX_PTR {
                ty.ok = false;
            } else {
                ty.ptr = ty.ptr + 1;
            }
            continue;
        }
        lx.advance();
        let mut n: i64 = -2; // no extent, or one this tool cannot evaluate
        if lx.kind == TK_NUM {
            n = int_literal(lx.text());
            if n < 0 {
                n = -2;
            }
            lx.advance();
        }
        if !lx.at_punct(b']') {
            n = -2;
            while lx.kind != TK_EOF && !lx.at_punct(b']') {
                lx.advance();
            }
        }
        if lx.at_punct(b']') {
            lx.advance();
        }
        if first {
            unsafe *arr_len = n;
        } else {
            unsafe *arr_len = -2; // a second dimension: not modelled
        }
        first = false;
    }
    return ty;
}

fn parse_params(lx: &mut Lexer, c: &mut Collected, out: &mut Vector<Param>, variadic: *mut bool, dump: str) {
    lx.advance(); // '('
    let mut idx: i32 = 0;
    loop {
        skip_noise(lx);
        if lx.kind == TK_EOF || lx.at_punct(b')') {
            break;
        }
        if lx.kind == TK_PUNCT && lx.text() == "..." {
            unsafe *variadic = true;
            lx.advance();
            continue;
        }
        if lx.at_punct(b',') {
            lx.advance();
            continue;
        }
        let mut td = false;
        let mut bc = false;
        let mut st = false;
        let base = parse_specs(lx, c, &mut td, &mut bc, &mut st, dump);
        let mut nm = String::new();
        let mut isfn = false;
        let mut va2 = false;
        let mut sub = Vector::<Param>::new();
        let mut adim: i64 = -1;
        let ty = parse_declarator(lx, c, &base, bc, &mut nm, &mut isfn, &mut sub, &mut va2, true, &mut adim, dump);
        sub.free();
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
        nm.free();
        ty.free();
        base.free();
        skip_noise(lx);
        if lx.at_punct(b',') {
            lx.advance();
        } else if !lx.at_punct(b')') {
            break; // something unmodelled: stop before it desynchronises the whole file
        }
    }
    if lx.at_punct(b')') {
        lx.advance();
    }
}

/// Walk the whole preprocessed unit. Every typedef is recorded (the target's signatures are spelled with
/// them, wherever they were declared); only declarations whose origin file is `want` are emitted.
fn parse_unit(lx: &mut Lexer, c: &mut Collected, want: str, extra: &Vector<String>, dump: str) {
    loop {
        skip_noise(lx);
        if lx.kind == TK_EOF {
            return;
        }
        if lx.at_punct(b';') {
            lx.advance();
            continue;
        }
        if lx.at_punct(b'{') {
            lx.skip_group(b'{', b'}'); // a `static inline` body left in the header
            continue;
        }
        if lx.kind != TK_IDENT {
            lx.advance();
            continue;
        }
        let here = String::from_str(lx.file.as_str());
        let mine = same_origin(here.as_str(), want, extra);
        // Published for parse_specs: a struct or enum BODY is parsed from inside the specifier, which is
        // where its origin has to be known -- only the target header's own records are emitted.
        c.cur_mine = mine;
        c.pending_agg = -1;
        c.saw_extern = false;
        let mut td = false;
        let mut bc = false;
        let mut st = false;
        let base = parse_specs(lx, c, &mut td, &mut bc, &mut st, dump);
        loop {
            let mut nm = String::new();
            let mut isfn = false;
            let mut va = false;
            let mut ps = Vector::<Param>::new();
            let mut adim: i64 = -1;
            let ty = parse_declarator(lx, c, &base, bc, &mut nm, &mut isfn, &mut ps, &mut va, true, &mut adim, dump);
            // A parameter this tool could not model poisons the whole signature: a binding with a wrong
            // type is worse than a missing one, so the function is dropped rather than guessed at.
            let mut keep = nm.len() != 0 && !td && !st && isfn && mine && ty.ok;
            for i in 0..ps.len() {
                if ps[i].ty.as_str() == "?" {
                    keep = false;
                }
            }
            if nm.len() != 0 && td {
                record_typedef(c, nm.as_str(), &ty, isfn);
            }
            // `extern int errno;` and friends: a global the library exports. Bound by what C itself
            // declares: a const-qualified binding becomes an extern `const` (readable), anything else a
            // `static mut`, whose accesses carry the ordinary static-mut unsafe rules across the FFI.
            if !keep && !td && !st && !isfn && mine && ty.ok && c.saw_extern && nm.len() != 0 && adim < 0 {
                let mut vt = String::new();
                ty.render(&mut vt);
                let wr = ty.fnsig.len() != 0 || !ty.qual_at(ty.ptr);
                c.globals.push(
                    ConstDef { name: String::from_str(nm.as_str()), ty: vt, value: String::new(), mutable: wr },
                );
            }
            if keep {
                let mut ret = String::new();
                ty.render(&mut ret);
                c.fns.push(FnDecl { name: String::from_str(nm.as_str()), params: ps, ret: ret, variadic: va });
            } else {
                if isfn && mine && !td && !st && nm.len() != 0 {
                    c.skipped = c.skipped + 1;
                }
                ps.free();
            }
            nm.free();
            ty.free();
            skip_noise(lx);
            if lx.at_punct(b',') {
                lx.advance();
                continue;
            }
            break;
        }
        base.free();
        here.free();
        if lx.at_punct(b'{') {
            lx.skip_group(b'{', b'}');
        } else if lx.at_punct(b';') {
            lx.advance();
        } else if lx.kind != TK_EOF {
            lx.advance(); // unmodelled: step over one token and resynchronise on the next `;`
        }
    }
}

// A typedef of a pointer-to-struct or of a struct tag keeps its own NAME as an opaque type; anything else
// resolves to the Super-C type it stands for.
fn record_typedef(c: &mut Collected, name: str, ty: &CType, is_fn: bool) {
    let pend = c.pending_agg;
    let pend_enum = c.pending_is_enum;
    c.pending_agg = -1;
    if is_fn || c.alias_of(name) >= 0 {
        return;
    }
    // `typedef struct { .. } Foo;` -- the body carried no tag, so the typedef IS the name. Most C
    // libraries declare their types this way, and a nameless record was previously dropped outright.
    if pend >= 0 && ty.ptr == 0 && ty.fnsig.len() == 0 {
        let idx = pend as usize;
        if pend_enum && idx < c.enums.len() && c.enums[idx].tag.len() == 0 {
            c.enums[idx].tag.push_str(name);
            c.aliases.push(Alias { name: String::from_str(name), sub: String::from_str(name), opaque: true, ok: true });
            return;
        }
        if !pend_enum && idx < c.records.len() && c.records[idx].tag.len() == 0 {
            c.records[idx].tag.push_str(name);
            c.aliases.push(Alias { name: String::from_str(name), sub: String::from_str(name), opaque: true, ok: true });
            return;
        }
    }
    let mut sub = String::new();
    ty.render(&mut sub);
    let opaque = ty.ptr == 0 && ty.fnsig.len() == 0 && sub.as_str() == name;
    c.aliases.push(Alias { name: String::from_str(name), sub: sub, opaque: opaque, ok: ty.ok || opaque });
}

fn path_contains(a: str, needle: str) bool {
    let n = a.len();
    let m = needle.len();
    if m == 0 || n < m {
        return false;
    }
    let mut i: usize = 0;
    while i + m <= n {
        if a.slice(i, i + m) == needle {
            return true;
        }
        i = i + 1;
    }
    return false;
}

// The preprocessor prints the path it opened, which is only the same STRING as the requested header when
// the request was already absolute -- compare by identity, not by spelling. `--from=` widens the set: a
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
        if path_contains(a, extra[i].as_str()) {
            return true;
        }
    }
    let mut sa = String::from_str(a);
    let mut sw = String::from_str(want);
    let same = unsafe shim::sc_same_file(sa.cstr(), sw.cstr()) == 1;
    sa.free();
    sw.free();
    return same;
}

// ---------------------------------------------------------------------------------------------------------
// driving the preprocessor
// ---------------------------------------------------------------------------------------------------------

fn temp_path(tag: str) String {
    let mut p = String::from_str(str::from_cstr(unsafe shim::sc_tmpdir()));
    p.format_into("/super-c-bindgen-{}-{}", unsafe shim::sc_getpid(), tag);
    return p;
}

fn cpp_command(cc: str, header: str, incs: &Vector<String>, cflags: &Vector<String>, dump_macros: bool) String {
    let mut cmd = String::from_str(cc);
    cmd.push_str(" -E");
    if dump_macros {
        cmd.push_str(" -dM");
    }
    cmd.push_str(" -x c");
    for i in 0..cflags.len() {
        cmd.push_str(" \"");
        cmd.push_string(&cflags[i]);
        cmd.push_byte(b'"');
    }
    for i in 0..incs.len() {
        cmd.push_str(" -I\"");
        cmd.push_string(&incs[i]);
        cmd.push_byte(b'"');
    }
    cmd.push_str(" \"");
    cmd.push_str(header);
    cmd.push_byte(b'"');
    return cmd;
}

// One line of `text` starting at `i`, without its terminator. A `\r` is dropped with the `\n`: the
// preprocessor's output is CRLF on Windows, and a value read as `7\r` parses as nothing at all -- which
// silently cost every macro constant there, and `__SIZEOF_LONG__` with them (Windows' `long` is 4 bytes,
// so falling back to the 8-byte default mistyped every `long` in a signature).
fn line_at(text: str, i: usize, end: *mut usize) str {
    let n = text.len();
    let mut e = i;
    while e < n && text.byte_at(e) != b'\n' {
        e = e + 1;
    }
    unsafe *end = e;
    let mut t = e;
    if t > i && text.byte_at(t - 1) == b'\r' {
        t = t - 1;
    }
    return text.slice(i, t);
}

// `__SIZEOF_*__` is what the toolchain itself reports, so `long` maps to what it will actually be.
fn read_widths(text: str) Widths {
    let mut w = Widths { short_b: 2, int_b: 4, long_b: 8, llong_b: 8, ptr_b: 8 };
    let n = text.len();
    let mut i: usize = 0;
    while i < n {
        let mut e: usize = 0;
        let line = line_at(text, i, &mut e);
        let v = macro_int(line);
        if v > 0 {
            if line_defines(line, "__SIZEOF_SHORT__") {
                w.short_b = v;
            } else if line_defines(line, "__SIZEOF_INT__") {
                w.int_b = v;
            } else if line_defines(line, "__SIZEOF_LONG__") {
                w.long_b = v;
            } else if line_defines(line, "__SIZEOF_LONG_LONG__") {
                w.llong_b = v;
            } else if line_defines(line, "__SIZEOF_POINTER__") {
                w.ptr_b = v;
            }
        }
        i = e + 1;
    }
    return w;
}

fn line_defines(line: str, name: str) bool {
    if !line.starts_with("#define ") {
        return false;
    }
    let rest = line[8..];
    return rest.starts_with(name) && rest.len() > name.len() && rest.byte_at(name.len()) == b' ';
}

fn macro_int(line: str) i32 {
    let n = line.len();
    let mut i = n;
    while i > 0 && line.byte_at(i - 1) != b' ' {
        i = i - 1;
    }
    // Only the `__SIZEOF_*__` widths matter, so anything that is not a small run of digits -- a suffixed
    // `9223372036854775807LL`, a parenthesised expression -- is simply not one of them.
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

// ---------------------------------------------------------------------------------------------------------
// C constant expressions
// ---------------------------------------------------------------------------------------------------------
// Enumerators and object-like macros are rarely bare literals -- `(1 << 8)`, `A | B`, `SOME_OTHER_MACRO` --
// and dropping every one of those loses most of a library's constants (91 of them in curl.h alone). This is
// the integer subset of C's constant expressions: enough for the shapes headers actually use, and it
// REFUSES anything else rather than guessing, because a constant that is subtly wrong is worse than absent.

struct CExpr<'a> {
    pub lx: Lexer<'a>,
    pub ok: bool,
}

extend CExpr<'a> as Free {
    fn free(self: &mut CExpr<'a>) {
        self.lx.free();
    }
}

const CE_DEPTH: i32 = 8;

// One name: an enumerator of the enum being built, a constant already collected, any enum's value, or
// another macro -- resolved recursively, since headers define constants in terms of each other.
fn ex_ident(x: &mut CExpr, c: &Collected, e: *const EnumDef, dump: str, depth: i32, name: str) i64 {
    if e != null {
        let mut v: i64 = 0;
        if enum_val_of(unsafe &*e, name, &mut v) {
            return v;
        }
    }
    for i in 0..c.consts.len() {
        if c.consts[i].name.as_str() == name {
            let lit = int_literal(c.consts[i].value.as_str());
            if lit >= 0 {
                return lit;
            }
        }
    }
    for i in 0..c.enums.len() {
        let mut v: i64 = 0;
        if enum_val_of(c.enums.at(i), name, &mut v) {
            return v;
        }
    }
    if depth < CE_DEPTH {
        let mut raw = String::new();
        let got = macro_value(dump, name, &mut raw);
        if got && raw.len() != 0 {
            let mut sub = false;
            let v = ce_eval(raw.as_str(), c, e, dump, depth + 1, &mut sub);
            raw.free();
            if sub {
                return v;
            }
            x.ok = false;
            return 0;
        }
        raw.free();
    }
    x.ok = false;
    return 0;
}

fn ex_primary(x: &mut CExpr, c: &Collected, e: *const EnumDef, dump: str, depth: i32) i64 {
    if x.lx.kind == TK_EOF {
        x.ok = false;
        return 0;
    }
    if x.lx.at_punct(b'(') {
        x.lx.advance();
        let v = ex_or(x, c, e, dump, depth);
        if !x.lx.at_punct(b')') {
            x.ok = false;
            return 0;
        }
        x.lx.advance();
        return v;
    }
    if x.lx.kind == TK_NUM {
        let v = int_literal(x.lx.text());
        x.lx.advance();
        if v < 0 {
            x.ok = false;
            return 0;
        }
        return v;
    }
    if x.lx.kind == TK_STR && x.lx.text().byte_at(0) == b'\'' {
        // A character constant is an integer; only the plain one-byte form is modelled.
        let t = x.lx.text();
        x.lx.advance();
        if t.len() == 3 {
            return t.byte_at(1);
        }
        x.ok = false;
        return 0;
    }
    if x.lx.kind == TK_IDENT {
        let nm = String::from_str(x.lx.text());
        x.lx.advance();
        // A cast (`(int)x`) or a call reaches here as an identifier followed by something unexpected;
        // both are refused by the caller when the expression does not end cleanly.
        let v = ex_ident(x, c, e, dump, depth, nm.as_str());
        nm.free();
        return v;
    }
    x.ok = false;
    return 0;
}

fn ex_unary(x: &mut CExpr, c: &Collected, e: *const EnumDef, dump: str, depth: i32) i64 {
    if x.lx.at_punct(b'-') {
        x.lx.advance();
        return 0 - ex_unary(x, c, e, dump, depth);
    }
    if x.lx.at_punct(b'+') {
        x.lx.advance();
        return ex_unary(x, c, e, dump, depth);
    }
    if x.lx.at_punct(b'~') {
        x.lx.advance();
        return 0 - ex_unary(x, c, e, dump, depth) - 1; // ~v == -v - 1
    }
    if x.lx.at_punct(b'!') {
        x.lx.advance();
        if ex_unary(x, c, e, dump, depth) == 0 {
            return 1;
        }
        return 0;
    }
    return ex_primary(x, c, e, dump, depth);
}

fn ex_mul(x: &mut CExpr, c: &Collected, e: *const EnumDef, dump: str, depth: i32) i64 {
    let mut v = ex_unary(x, c, e, dump, depth);
    loop {
        if x.lx.at_punct(b'*') {
            x.lx.advance();
            v = v * ex_unary(x, c, e, dump, depth);
        } else if x.lx.at_punct(b'/') {
            x.lx.advance();
            let d = ex_unary(x, c, e, dump, depth);
            if d == 0 {
                x.ok = false;
                return 0;
            }
            v = v / d;
        } else if x.lx.at_punct(b'%') {
            x.lx.advance();
            let d = ex_unary(x, c, e, dump, depth);
            if d == 0 {
                x.ok = false;
                return 0;
            }
            v = v % d;
        } else {
            return v;
        }
    }
}

fn ex_add(x: &mut CExpr, c: &Collected, e: *const EnumDef, dump: str, depth: i32) i64 {
    let mut v = ex_mul(x, c, e, dump, depth);
    loop {
        if x.lx.at_punct(b'+') {
            x.lx.advance();
            v = v + ex_mul(x, c, e, dump, depth);
        } else if x.lx.at_punct(b'-') {
            x.lx.advance();
            v = v - ex_mul(x, c, e, dump, depth);
        } else {
            return v;
        }
    }
}

fn ex_shift(x: &mut CExpr, c: &Collected, e: *const EnumDef, dump: str, depth: i32) i64 {
    let mut v = ex_add(x, c, e, dump, depth);
    loop {
        // The scanner emits punctuation one byte at a time, so `<<` is two `<` in a row.
        if x.lx.at_punct(b'<') {
            x.lx.advance();
            if !x.lx.at_punct(b'<') {
                x.ok = false;
                return 0;
            }
            x.lx.advance();
            let sh = ex_add(x, c, e, dump, depth);
            if sh < 0 || sh > 62 {
                x.ok = false;
                return 0;
            }
            v = v << sh;
        } else if x.lx.at_punct(b'>') {
            x.lx.advance();
            if !x.lx.at_punct(b'>') {
                x.ok = false;
                return 0;
            }
            x.lx.advance();
            let sh = ex_add(x, c, e, dump, depth);
            if sh < 0 || sh > 62 {
                x.ok = false;
                return 0;
            }
            v = v >> sh;
        } else {
            return v;
        }
    }
}

fn ex_and(x: &mut CExpr, c: &Collected, e: *const EnumDef, dump: str, depth: i32) i64 {
    let mut v = ex_shift(x, c, e, dump, depth);
    while x.lx.at_punct(b'&') {
        x.lx.advance();
        if x.lx.at_punct(b'&') {
            x.ok = false; // `&&` is a logical operator, not a constant this models
            return 0;
        }
        v = v & ex_shift(x, c, e, dump, depth);
    }
    return v;
}

fn ex_xor(x: &mut CExpr, c: &Collected, e: *const EnumDef, dump: str, depth: i32) i64 {
    let mut v = ex_and(x, c, e, dump, depth);
    while x.lx.at_punct(b'^') {
        x.lx.advance();
        v = v ^ ex_and(x, c, e, dump, depth);
    }
    return v;
}

fn ex_or(x: &mut CExpr, c: &Collected, e: *const EnumDef, dump: str, depth: i32) i64 {
    let mut v = ex_xor(x, c, e, dump, depth);
    while x.lx.at_punct(b'|') {
        x.lx.advance();
        if x.lx.at_punct(b'|') {
            x.ok = false;
            return 0;
        }
        v = v | ex_xor(x, c, e, dump, depth);
    }
    return v;
}

/// The value of a C integer constant expression, or `ok = false` when any part of it is outside this
/// subset. `e` (may be null) is an enum under construction, whose earlier enumerators are in scope.
fn ce_eval(text: str, c: &Collected, e: *const EnumDef, dump: str, depth: i32, ok: *mut bool) i64 {
    unsafe *ok = false;
    if text.len() == 0 || depth > CE_DEPTH {
        return 0;
    }
    let mut x = CExpr::<'_> { lx: Lexer::new(text), ok: true };
    let v = ex_or(&mut x, c, e, dump, depth);
    // Trailing tokens mean the text was never a constant expression -- a cast, a call, a comma.
    let clean = x.ok && x.lx.kind == TK_EOF;
    unsafe *ok = clean;
    return v;
}

// ---------------------------------------------------------------------------------------------------------
// object-like macros
// ---------------------------------------------------------------------------------------------------------

// Which names the TARGET header defines. `-dM` gives every macro in scope -- thousands of them, from the
// compiler and every include -- and says nothing about where each came from, so the names are taken from
// the header's own text and only their VALUES are read from the dump (which is the value that actually
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

// The macro's replacement text, as `#define NAME <text>` in the `-dM` dump; empty when it has none.
fn macro_value(dump: str, name: str, out: &mut String) bool {
    let n = dump.len();
    let mut i: usize = 0;
    while i < n {
        let mut e: usize = 0;
        let line = line_at(dump, i, &mut e);
        if line_defines(line, name) {
            let v = line[8 + name.len()..];
            let mut a: usize = 0;
            while a < v.len() && v.byte_at(a) == b' ' {
                a = a + 1;
            }
            out.push_str(v.slice(a, v.len()));
            return true;
        }
        i = e + 1;
    }
    return false;
}

// `((-1))` -> `-1`: the parentheses C needs for hygiene carry no meaning here.
fn strip_parens(v: str) str {
    let mut s = v;
    loop {
        if s.len() < 2 || s.byte_at(0) != b'(' || s.byte_at(s.len() - 1) != b')' {
            return s;
        }
        // Only when the two are each other's partner -- `(a)+(b)` must survive intact.
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

fn is_float_text(v: str) bool {
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

/// Turn one macro replacement into a typed Super-C constant. Only literals: an integer, a float or a
/// string. An expression macro (`(SIZE_MAX >> 1)`, `INT32_MAX`) is left alone -- folding C expressions is
/// the C compiler's job, and a const that is subtly different from the macro is worse than no const.
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
    let mut iv = int_literal(body);
    if iv < 0 {
        // Not a literal: `(1 << 8)`, `A | B`, or a name standing for another macro. The evaluator settles
        // whether it is a constant at all -- and refuses when any part of it is outside C's integer subset.
        let mut got = false;
        let ev = ce_eval(v, c, null, dump, 0, &mut got);
        if !got {
            return false;
        }
        out.name.push_str(name);
        out.ty.push_str(
            if ev > 0x7FFFFFFF || ev < 0 - 0x80000000 {
                "i64";
            } else {
                "i32";
            },
        );
        out.value.format_into("{}", ev);
        return true;
    }
    let _ = iv;
    iv = int_literal(body);
    // Unsigned only when C says so; the width is the smallest that holds the value, as a literal would be.
    let mut uns = false;
    for i in 0..body.len() {
        if body.byte_at(i) == b'u' || body.byte_at(i) == b'U' {
            uns = true;
        }
    }
    out.name.push_str(name);
    if uns {
        out.ty.push_str(
            if iv > 0xFFFFFFFF {
                "u64";
            } else {
                "u32";
            },
        );
    } else {
        out.ty.push_str(
            if iv > 0x7FFFFFFF {
                "i64";
            } else {
                "i32";
            },
        );
    }
    if neg {
        out.value.push_byte(b'-');
    }
    out.value.format_into("{}", iv);
    return true;
}

// ---------------------------------------------------------------------------------------------------------
// emitting
// ---------------------------------------------------------------------------------------------------------

// Only the opaque tags the emitted signatures actually mention: a header pulls in hundreds of struct names
// through its own includes, and binding all of them would bury the ones a caller needs.
fn opaque_used(c: &Collected, name: str) bool {
    for i in 0..c.fns.len() {
        let f = c.fns.at(i);
        if type_mentions(f.ret.as_str(), name) {
            return true;
        }
        for j in 0..f.params.len() {
            if type_mentions(f.params[j].ty.as_str(), name) {
                return true;
            }
        }
    }
    return false;
}

fn type_mentions(ty: str, name: str) bool {
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

// A tag emitted as a real `pub struct`/`pub union` must not ALSO be declared opaque -- one name, one
// definition.
fn record_emitted(c: &Collected, tag: str) bool {
    let ri = record_of(c, tag);
    if ri < 0 {
        return false;
    }
    let r = c.records.at(ri as usize);
    return r.mine && r.ok;
}

fn enum_emitted(c: &Collected, tag: str) bool {
    for i in 0..c.enums.len() {
        if c.enums[i].tag.as_str() == tag {
            return c.enums[i].mine && c.enums[i].ok;
        }
    }
    return false;
}

// A name already spoken for. C's namespaces are separate -- a macro, an enumerator and a function may all
// be called `FOO` -- but Super-C has one, so the first definition wins and the rest are left out.
fn name_taken(c: &Collected, upto: usize, name: str) bool {
    for i in 0..c.fns.len() {
        if c.fns[i].name.as_str() == name {
            return true;
        }
    }
    for i in 0..upto {
        if c.consts[i].name.as_str() == name {
            return true;
        }
    }
    for i in 0..c.records.len() {
        if c.records[i].tag.as_str() == name && record_emitted(c, name) {
            return true;
        }
    }
    for i in 0..c.enums.len() {
        if c.enums[i].tag.as_str() == name && enum_emitted(c, name) {
            return true;
        }
    }
    return false;
}

/// The constants the module exposes: an anonymous enum's enumerators (C's "block of constants" idiom),
/// then the target header's own object-like macros. Order matters -- an enumerator is a real declaration
/// and a macro is textual, so the declaration wins any name they share.
fn collect_consts(c: &mut Collected, header: str, dump: str) {
    for i in 0..c.enums.len() {
        if !c.enums[i].mine || !c.enums[i].ok || c.enums[i].tag.len() != 0 {
            continue;
        }
        for j in 0..c.enums[i].vals.len() {
            let mut cd = ConstDef { name: String::new(), ty: String::from_str("i32"), value: String::new() };
            cd.name.push_str(c.enums[i].vals[j].name.as_str());
            cd.value.format_into("{}", c.enums[i].vals[j].value);
            let taken = name_taken(c, c.consts.len(), cd.name.as_str());
            if taken {
                cd.free();
            } else {
                c.consts.push(cd);
            }
        }
    }
    let mut names = Vector::<String>::new();
    switch loader::read_file(header) {
        Some(src) => {
            header_macro_names(src.as_str(), &mut names);
            src.free();
        },
        None => {},
    };
    for i in 0..names.len() {
        let mut raw = String::new();
        if macro_value(dump, names[i].as_str(), &mut raw) {
            let mut cd = ConstDef { name: String::new(), ty: String::new(), value: String::new() };
            let ok = macro_const(names[i].as_str(), raw.as_str(), c, dump, &mut cd) && !name_taken(
                c,
                c.consts.len(),
                names[i].as_str(),
            );
            if ok {
                c.consts.push(cd);
            } else {
                cd.free();
            }
        }
        raw.free();
    }
    names.free();
}

fn emit(c: &Collected, header: str, spelling: str, link: str, out: &mut String) {
    out.format_into("// Generated by `super-c bindgen {}`; edit the generator's input, not this file.\n", spelling);
    out.push_str("// Raw C bindings: every call requires `unsafe`. Structs reached only through a pointer are opaque\n");
    out.push_str("// types -- their layout is C's business, not this module's.\n\n");
    let _ = header;
    // The constants are ordinary top-level items and come first; `@c.link` has to sit on the extern block
    // itself, so it is emitted last, immediately above it.
    for i in 0..c.consts.len() {
        let cd = c.consts.at(i);
        out.format_into("pub const {}: {} = {};\n", cd.name.as_str(), cd.ty.as_str(), cd.value.as_str());
    }
    if c.consts.len() != 0 {
        out.push_byte(b'\n');
    }
    if link.len() != 0 {
        out.format_into("@c.link(\"{}\")\n", link);
    }
    out.format_into("extern \"C\" \"{}\" {{\n", spelling);
    let mut first = true;
    for i in 0..c.opaques.len() {
        let nm = c.opaques[i].as_str();
        if !opaque_used(c, nm) || record_emitted(c, nm) || enum_emitted(c, nm) {
            continue;
        }
        // A tag C never typedef'd is `struct x` there, not `x`.
        let ai = c.alias_of(nm);
        if !(ai >= 0 && c.aliases.at(ai as usize).opaque) {
            out.format_into("    @c.import(\"struct {}\")\n", nm);
        }
        out.format_into("    pub type {};\n", nm);
        first = false;
    }
    if !first {
        out.push_byte(b'\n');
    }
    for i in 0..c.enums.len() {
        let e = c.enums.at(i);
        if !e.mine || !e.ok || e.tag.len() == 0 {
            continue;
        }
        let ai = c.alias_of(e.tag.as_str());
        if !(ai >= 0 && c.aliases.at(ai as usize).opaque) {
            out.format_into("    @c.import(\"enum {}\")\n", e.tag.as_str());
        }
        out.format_into("    pub enum {} {{\n", e.tag.as_str());
        for j in 0..e.vals.len() {
            out.format_into("        {} = {},\n", e.vals[j].name.as_str(), e.vals[j].value);
        }
        out.push_str("    }\n\n");
    }
    // Inside the block, so these ARE the header's types rather than look-alikes: the emitted C uses the
    // header's own definition and asserts this layout against it. A tag C never typedef'd has to be
    // spelled `struct x` there, which is what the pinned symbol carries.
    for i in 0..c.records.len() {
        let r = c.records.at(i);
        if !r.mine || !r.ok || r.tag.len() == 0 {
            continue;
        }
        let kw = if r.is_union {
            "union";
        } else {
            "struct";
        };
        let ai = c.alias_of(r.tag.as_str());
        let typedefed = ai >= 0 && c.aliases.at(ai as usize).opaque;
        if !typedefed {
            out.format_into("    @c.import(\"{} {}\")\n", kw, r.tag.as_str());
        }
        out.format_into("    pub {} {} {{\n", kw, r.tag.as_str());
        for j in 0..r.fields.len() {
            out.format_into("        pub {}: {},\n", r.fields[j].name.as_str(), r.fields[j].ty.as_str());
        }
        out.push_str("    }\n\n");
    }
    for i in 0..c.globals.len() {
        if c.globals[i].mutable {
            out.format_into("    pub static mut {}: {};\n", c.globals[i].name.as_str(), c.globals[i].ty.as_str());
        } else {
            out.format_into("    pub const {}: {};\n", c.globals[i].name.as_str(), c.globals[i].ty.as_str());
        }
    }
    if c.globals.len() != 0 {
        out.push_byte(b'\n');
    }
    for i in 0..c.fns.len() {
        let f = c.fns.at(i);
        out.format_into("    pub fn {}(", f.name.as_str());
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

// ---------------------------------------------------------------------------------------------------------
// entry point
// ---------------------------------------------------------------------------------------------------------

/// `super-c bindgen <header.h> [-o out.spc] [--link=NAME] [--header=SPELLING] [-I dir]... [--from=PART]...`
/// Returns a process exit code.
fn run_one(
    header: str,
    out_path: str,
    link: str,
    spelling_in: str,
    incs: &Vector<String>,
    froms: &Vector<String>,
    cflags: &Vector<String>,
    cc_str: str,
) i32 {
    let cc = String::from_str(cc_str);
    let mut hdr = String::from_str(header);
    let mut abs = PathBuf {};
    if unsafe shim::sc_realpath(hdr.cstr(), &mut abs[0]) != null {
        hdr.clear();
        hdr.push_str(str::from_cstr(&abs[0]));
    }
    let mut spelling = String::from_str(spelling_in);
    if spelling.len() == 0 {
        spelling.push_str(header);
    }

    let mut ipath = temp_path("i");
    let mut mpath = temp_path("m");
    let mut rc: i32 = 1;
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
    };

    let mut mdump = String::new();
    let mut mcmd = cpp_command(cc.as_str(), hdr.as_str(), incs, cflags, true);
    if unsafe shim::sc_run(mcmd.cstr(), null, mpath.cstr(), null, null) == 0 {
        switch loader::read_file(mpath.as_str()) {
            Some(t) => {
                c.widths = read_widths(t.as_str());
                mdump.push_string(&t);
                t.free();
            },
            None => {},
        };
    }
    let _ = unsafe shim::sc_unlink(mpath.cstr());

    let mut cmd = cpp_command(cc.as_str(), hdr.as_str(), incs, cflags, false);
    let prc = unsafe shim::sc_run(cmd.cstr(), null, ipath.cstr(), null, null);
    if prc != 0 {
        unsafe stdio::fprintf(
            stdio::stderr(),
            "super-c: the preprocessor failed on '%.*s'\n".ptr() as *const char,
            header.len() as i32,
            header.ptr(),
        );
    } else {
        switch loader::read_file(ipath.as_str()) {
            Some(text) => {
                let mut lx = Lexer::new(text.as_str());
                parse_unit(&mut lx, &mut c, hdr.as_str(), froms, mdump.as_str());
                collect_consts(&mut c, hdr.as_str(), mdump.as_str());
                let mut out = String::new();
                emit(&c, hdr.as_str(), spelling.as_str(), link, &mut out);
                rc = write_out(out.as_str(), out_path, c.fns.len(), c.skipped);
                out.free();
                text.free();
            },
            None => {
                unsafe stdio::fputs(
                    "super-c: could not read the preprocessed output\n".ptr() as *const char,
                    stdio::stderr(),
                );
                rc = 1;
            },
        };
    }
    let _ = unsafe shim::sc_unlink(ipath.cstr());
    cmd.free();
    mcmd.free();
    mdump.free();
    ipath.free();
    mpath.free();
    spelling.free();
    hdr.free();
    cc.free();
    c.free();
    return rc;
}

fn write_out(text: str, out_path: str, nfns: usize, skipped: usize) i32 {
    if out_path.len() == 0 {
        unsafe stdio::fwrite(text.ptr(), 1, text.len(), stdio::stdout());
        return 0;
    }
    let f = stdio::fopen(out_path, "wb");
    if f == null {
        unsafe stdio::fprintf(
            stdio::stderr(),
            "super-c: cannot write '%.*s'\n".ptr() as *const char,
            out_path.len() as i32,
            out_path.ptr(),
        );
        return 1;
    }
    unsafe stdio::fwrite(text.ptr(), 1, text.len(), f);
    unsafe stdio::fclose(f);
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

// ---------------------------------------------------------------------------------------------------------
// path expansion
// ---------------------------------------------------------------------------------------------------------

/// One header to convert: where it is, how the generated module spells its `#include`, and where the
/// result goes.
struct Job {
    pub path: String,
    pub spelling: String,
    pub out: String,
}

extend Job as Free {
    fn free(self: &mut Job) {
        self.path.free();
        self.spelling.free();
        self.out.free();
    }
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
fn dir_part(p: str) str {
    let mut k = p.len();
    while k > 0 && p.byte_at(k - 1) != b'/' {
        k = k - 1;
    }
    if k == 0 {
        return "";
    }
    return p.slice(0, k - 1);
}

fn stem_of(p: str) str {
    let mut k = p.len();
    while k > 0 && p.byte_at(k - 1) != b'/' {
        k = k - 1;
    }
    let base = p.slice(k, p.len());
    if base.ends_with(".h") {
        return base.slice(0, base.len() - 2);
    }
    return base;
}

/// The generated file's stem. A module is imported by its file name, so anything that cannot appear in an
/// identifier becomes `_` -- `typecheck-gcc.h` would otherwise produce a module nothing can import. Only
/// the FILE name is rewritten; the `#include` spelling has to stay exactly what C wrote.
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

/// Every `.h` under `dir`, recursively. `rel` is the path so far BELOW the directory the user named,
/// which is what the generated module uses to `#include` it -- name the include root and the spellings
/// come out the way C code writes them (`curl/curl.h`).
fn walk_headers(dir: str, rel: str, out_dir: str, jobs: &mut Vector<Job>) i32 {
    let mut d = String::from_str(dir);
    let dh = unsafe shim::sc_opendir(d.cstr());
    if dh == null {
        unsafe stdio::fprintf(
            stdio::stderr(),
            "super-c: cannot read directory '%.*s'\n".ptr() as *const char,
            dir.len() as i32,
            dir.ptr(),
        );
        return 1;
    }
    let mut names = Vector::<String>::new();
    loop {
        let e = unsafe shim::sc_readdir(dh);
        if e == null {
            break;
        }
        let nm = unsafe shim::sc_dirent_name(e);
        if unsafe nm[0] == '.' as char {
            continue;
        }
        names.push(String::from_cstr(nm));
    }
    let _ = unsafe shim::sc_closedir(dh);
    names.sort_by(|a: &String, b: &String| name_cmp(a, b));
    let mut rc: i32 = 0;
    for i in 0..names.len() {
        let mut child = join_path(dir, names[i].as_str());
        let crel = join_path(rel, names[i].as_str());
        if unsafe shim::sc_stat_isdir(child.cstr()) == 1 {
            if walk_headers(child.as_str(), crel.as_str(), out_dir, jobs) != 0 {
                rc = 1;
            }
        } else if names[i].as_str().ends_with(".h") {
            let o = join_path(out_dir, dir_part(crel.as_str()));
            let mut leaf = String::new();
            module_stem(crel.as_str(), &mut leaf);
            leaf.push_str(".spc");
            let full = join_path(o.as_str(), leaf.as_str());
            jobs.push(Job { path: child, spelling: crel, out: full });
            o.free();
            leaf.free();
            continue;
        }
    }
    names.free();
    return rc;
}

// Byte-lexicographic with a length tiebreak: the same walk order on every filesystem.
const fn name_cmp(a: &String, b: &String) i32 {
    let la = a.len();
    let lb = b.len();
    let m = if la < lb {
        la;
    } else {
        lb;
    };
    let c = unsafe cstring::memcmp(a.as_str().ptr(), b.as_str().ptr(), m);
    if c != 0 {
        return c;
    }
    return la as i32 - lb as i32;
}

/// `super-c bindgen <header.h|dir>... [-o out]`. A directory is walked recursively for `.h` files, so a
/// whole library's include tree converts in one call -- `-o` then names a DIRECTORY, and the tree under it
/// mirrors the headers'. A single header with no `-o` still writes to stdout.
pub fn run(
    paths: &Vector<String>,
    out_path: str,
    link: str,
    spelling_in: str,
    incs: &Vector<String>,
    froms: &Vector<String>,
    cflags: &Vector<String>,
    cc_in: str,
) i32 {
    let mut cc = String::from_str(cc_in);
    if cc.len() == 0 {
        let e = stdlib::getenv("CC");
        if e != null && unsafe *e != 0 as char {
            cc.push_str(str::from_cstr(e));
        } else {
            cc.push_str("cc");
        }
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
        let mut pp = String::from_str(p);
        let isdir = unsafe shim::sc_stat_isdir(pp.cstr()) == 1;
        pp.free();
        if isdir {
            if out_dir.len() == 0 {
                unsafe stdio::fputs(
                    "super-c: bindgen over a directory needs '-o <dir>' to write into\n".ptr() as *const char,
                    stdio::stderr(),
                );
                rc = 1;
                break;
            }
            if walk_headers(p, "", out_dir, &mut jobs) != 0 {
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
            full.free();
            leaf.free();
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
                let mut odp = String::from_str(od);
                let _ = unsafe shim::sc_mkdir_p(odp.cstr());
                odp.free();
            }
            if run_one(
                jobs[i].path.as_str(),
                jobs[i].out.as_str(),
                link,
                jobs[i].spelling.as_str(),
                incs,
                froms,
                cflags,
                cc.as_str(),
            ) != 0 {
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
    jobs.free();
    cc.free();
    return rc;
}
