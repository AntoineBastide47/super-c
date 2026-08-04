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
// Scope: functions, the typedefs needed to spell their signatures, and opaque `pub type` for structs that
// only ever appear behind a pointer. A struct whose FIELDS a caller needs is not emitted: its layout would
// have to match C exactly on every target, which is a promise this tool cannot make from one host's headers.

import stdio;
import stdlib;
import driver_shim as shim;
import module::loader as loader;
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
struct Collected {
    pub aliases: Vector<Alias>,
    pub fns: Vector<FnDecl>,
    pub opaques: Vector<String>, // struct tags reached only through a pointer -> `pub type X;`
    pub widths: Widths,
    /// Functions from the target header whose signature this tool could not model. Reported rather than
    /// swallowed: a binding file that is quietly short is worse than one that says what it left out.
    pub skipped: usize,
}

extend Collected as Free {
    fn free(self: &mut Collected) {
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

/// Declaration specifiers: the type part of a declaration, up to the first declarator. Returns the base
/// type; `is_typedef` reports a leading `typedef`. A `struct`/`union`/`enum` body is skipped -- only its tag
/// is kept, and the tag becomes an opaque type if the emitted signatures need it.
fn parse_specs(lx: &mut Lexer, c: &mut Collected, is_typedef: *mut bool, base_const: *mut bool, is_static: *mut bool) CType {
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
            let kw = String::from_str(t);
            lx.advance();
            skip_noise(lx);
            let mut tag = String::new();
            if lx.kind == TK_IDENT {
                tag.push_str(lx.text());
                lx.advance();
            }
            if lx.at_punct(b'{') {
                lx.skip_group(b'{', b'}');
            }
            if kw.as_str() == "enum" {
                // An enum's underlying type is an int as far as a call is concerned.
                ty.base.push_str("i32");
            } else if tag.len() != 0 {
                ty.base.push_string(&tag);
                c.note_opaque(tag.as_str());
            } else {
                ty.ok = false; // an anonymous struct has no name to refer to
            }
            named = true;
            tag.free();
            kw.free();
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
) CType {
    let mut ty = base.clone();
    if base_const {
        ty.qual = ty.qual | 1u32;
    }
    unsafe *is_fn = false;
    unsafe *variadic = false;
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
        parse_params(lx, c, &mut ps, &mut va);
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
    // An array parameter is a pointer, and an array of anything else is not something to bind.
    while lx.at_punct(b'[') {
        lx.skip_group(b'[', b']');
        if ty.ptr + 1 >= MAX_PTR {
            ty.ok = false;
        } else {
            ty.ptr = ty.ptr + 1;
        }
    }
    return ty;
}

fn parse_params(lx: &mut Lexer, c: &mut Collected, out: &mut Vector<Param>, variadic: *mut bool) {
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
        let base = parse_specs(lx, c, &mut td, &mut bc, &mut st);
        let mut nm = String::new();
        let mut isfn = false;
        let mut va2 = false;
        let mut sub = Vector::<Param>::new();
        let ty = parse_declarator(lx, c, &base, bc, &mut nm, &mut isfn, &mut sub, &mut va2);
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
fn parse_unit(lx: &mut Lexer, c: &mut Collected, want: str) {
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
        let mine = same_origin(here.as_str(), want);
        let mut td = false;
        let mut bc = false;
        let mut st = false;
        let base = parse_specs(lx, c, &mut td, &mut bc, &mut st);
        loop {
            let mut nm = String::new();
            let mut isfn = false;
            let mut va = false;
            let mut ps = Vector::<Param>::new();
            let ty = parse_declarator(lx, c, &base, bc, &mut nm, &mut isfn, &mut ps, &mut va);
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
    if is_fn || c.alias_of(name) >= 0 {
        return;
    }
    let mut sub = String::new();
    ty.render(&mut sub);
    let opaque = ty.ptr == 0 && ty.fnsig.len() == 0 && sub.as_str() == name;
    c.aliases.push(Alias { name: String::from_str(name), sub: sub, opaque: opaque, ok: ty.ok || opaque });
}

// The preprocessor prints the path it opened, which is only the same STRING as the requested header when
// the request was already absolute -- compare by identity, and fall back to the trailing path segment.
fn same_origin(a: str, want: str) bool {
    if a.len() == 0 {
        return false;
    }
    if a == want {
        return true;
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

fn cpp_command(cc: str, header: str, incs: &Vector<String>, dump_macros: bool) String {
    let mut cmd = String::from_str(cc);
    cmd.push_str(" -E");
    if dump_macros {
        cmd.push_str(" -dM");
    }
    cmd.push_str(" -x c");
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

// `__SIZEOF_*__` is what the toolchain itself reports, so `long` maps to what it will actually be.
fn read_widths(text: str) Widths {
    let mut w = Widths { short_b: 2, int_b: 4, long_b: 8, llong_b: 8, ptr_b: 8 };
    let n = text.len();
    let mut i: usize = 0;
    while i < n {
        let mut e = i;
        while e < n && text.byte_at(e) != b'\n' {
            e = e + 1;
        }
        let line = text.slice(i, e);
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

fn emit(c: &Collected, header: str, spelling: str, link: str, out: &mut String) {
    out.format_into("// Generated by `super-c bindgen {}`; edit the generator's input, not this file.\n", spelling);
    out.push_str("// Raw C bindings: every call requires `unsafe`. Structs reached only through a pointer are opaque\n");
    out.push_str("// types -- their layout is C's business, not this module's.\n\n");
    let _ = header;
    if link.len() != 0 {
        out.format_into("@c.link(\"{}\")\n", link);
    }
    out.format_into("extern \"C\" \"{}\" {{\n", spelling);
    let mut first = true;
    for i in 0..c.opaques.len() {
        let nm = c.opaques[i].as_str();
        if !opaque_used(c, nm) {
            continue;
        }
        out.format_into("    pub type {};\n", nm);
        first = false;
    }
    if !first {
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

/// `super-c bindgen <header.h> [-o out.spc] [--link NAME] [--header SPELLING] [-I dir]...`
/// Returns a process exit code.
pub fn run(header: str, out_path: str, link: str, spelling_in: str, incs: &Vector<String>, cc_in: str) i32 {
    let mut cc = String::from_str(cc_in);
    if cc.len() == 0 {
        let e = stdlib::getenv("CC");
        if e != null && unsafe *e != 0 as char {
            cc.push_str(str::from_cstr(e));
        } else {
            cc.push_str("cc");
        }
    }
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
        widths: Widths { short_b: 2, int_b: 4, long_b: 8, llong_b: 8, ptr_b: 8 },
        skipped: 0,
    };

    let mut mcmd = cpp_command(cc.as_str(), hdr.as_str(), incs, true);
    if unsafe shim::sc_run(mcmd.cstr(), null, mpath.cstr(), null, null) == 0 {
        switch loader::read_file(mpath.as_str()) {
            Some(t) => {
                c.widths = read_widths(t.as_str());
                t.free();
            },
            None => {},
        };
    }
    let _ = unsafe shim::sc_unlink(mpath.cstr());

    let mut cmd = cpp_command(cc.as_str(), hdr.as_str(), incs, false);
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
                parse_unit(&mut lx, &mut c, hdr.as_str());
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
