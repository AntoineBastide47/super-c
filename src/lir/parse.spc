// The LIR text parser: reads `lir::print`'s text form back into a package. One pass, one line at a time,
// no backtracking: each line is a declaration, a block header or one instruction. A value used before its
// definition (a loop's edge argument) is patched when the body ends, since the printer numbers values in
// text order. The parser checks syntax and table references only; the verifier checks meaning. It stops at
// the first error, which names the line and column, and rejects a body past the verifier's limits while
// it reads, so its memory is bounded by the input.
import ast::ast as ast;
import lir::ir as *;
import lir::verify as verify;
import ir::core as core;
import utils::names as nm;

/// The parse of `text`: the package, or the first error (`line:col: what`) in `err`.
pub fn parse(text: str, err: &mut String) Option<Package> {
    let mut ps = Parser::new(text);
    return ps.run(err);
}

struct Parser<'a> {
    text: str<'a>,
    at: usize, // the next byte
    line_start: usize,
    line_end: usize,
    line_no: u32,
    why: str<'static>,
    pkg: Package,
    body: Body,
    sym: u32, // the symbol of the body being read, NONE outside one
    file: u32, // the body's file
    vmap: Vector<u32>, // printed value number -> value id, NONE before its definition
    fixes: Vector<Fix>, // operands that hold a printed number, to patch at the end of the body
    lays: Vector<u32>, // printed layout number -> pool index
    words: Vector<u32>, // scratch
    parts: Vector<str<'a>>, // the current mnemonic's opcode and suffixes
    ops: Map<u64, u8>, // the hash of each opcode's name -> the opcode
    vops: Map<u64, u16>, // the hash of each vector operation's name -> its code
}

extend<'a> Parser<'a> {
    fn new(text: str<'a>) Parser<'a> {
        return Parser {
            text: text,
            at: 0,
            line_start: 0,
            line_end: 0,
            line_no: 0,
            why: "",
            pkg: Package::new(8),
            body: Body::new(),
            sym: NONE,
            file: 0,
            vmap: Vector::<u32>::new(),
            fixes: Vector::<Fix>::new(),
            lays: Vector::<u32>::new(),
            words: Vector::<u32>::new(),
            parts: Vector::<str<'a>>::new(),
            ops: op_names(),
            vops: vop_names(),
        };
    }

    fn run(self: &mut Self, err: &mut String) Option<Package> {
        if self.package() {
            return Option::<Package>::Some(replace(&mut self.pkg, Package::new(8)));
        }
        err.format_into("{}:{}: {}", self.line_no, self.at - self.line_start + 1, self.why);
        return Option::<Package>::None;
    }

    fn fail(self: &mut Self, why: str<'static>) bool {
        if self.why.len() == 0 {
            self.why = why;
        }
        return false;
    }

    // Move to the next line; false at the end of the text.
    fn next_line(self: &mut Self) bool {
        if self.line_no != 0 {
            self.at = self.line_end + 1;
        }
        if self.at > self.text.len() || self.line_no != 0 && self.line_end >= self.text.len() {
            return false;
        }
        self.line_start = self.at;
        let mut e = self.at;
        while e < self.text.len() && self.text.byte_at(e) != b'\n' {
            e += 1;
        }
        self.line_end = e;
        self.line_no += 1;
        return true;
    }

    // The next byte of the line, 0 at its end or at a comment.
    const fn peek(self: &Self) u8 {
        if self.at >= self.line_end {
            return 0;
        }
        let c = self.text.byte_at(self.at);
        return ast::pick(c == b';', 0u8, c);
    }

    fn skip_spaces(self: &mut Self) {
        while self.at < self.line_end && self.text.byte_at(self.at) == b' ' {
            self.at += 1;
        }
    }

    // Skip spaces, then the byte `c` if it is next.
    fn eat(self: &mut Self, c: u8) bool {
        self.skip_spaces();
        if self.peek() == c {
            self.at += 1;
            return true;
        }
        return false;
    }

    fn expect(self: &mut Self, c: u8, why: str<'static>) bool {
        return self.eat(c) || self.fail(why);
    }

    // The next word: letters, digits, `_`, `.`, `$` and `-`.
    fn word(self: &mut Self) str<'a> {
        self.skip_spaces();
        let s = self.at;
        while self.at < self.line_end && (name_char(self.text.byte_at(self.at)) || self.text.byte_at(self.at) == b'-') {
            self.at += 1;
        }
        return self.text.slice(s, self.at);
    }

    // Whether the next word is `w` (consumed when it is).
    fn keyword(self: &mut Self, w: str) bool {
        let save = self.at;
        if self.word() == w {
            return true;
        }
        self.at = save;
        return false;
    }

    fn expect_word(self: &mut Self, w: str, why: str<'static>) bool {
        return self.keyword(w) || self.fail(why);
    }

    // A decimal integer, signed.
    fn int(self: &mut Self, out: &mut i64) bool {
        self.skip_spaces();
        let neg = self.peek() == b'-';
        if neg || self.peek() == b'+' {
            self.at += 1;
        }
        let s = self.at;
        let mut v: u64 = 0;
        while self.at < self.line_end && self.text.byte_at(self.at) >= b'0' && self.text.byte_at(self.at) <= b'9' {
            let d = (self.text.byte_at(self.at) - b'0') as u64;
            if v > (0xFFFFFFFFFFFFFFFFu64 - d) / 10 {
                return self.fail("the integer does not fit 64 bits");
            }
            v = v * 10 + d;
            self.at += 1;
        }
        if self.at == s {
            return self.fail("expected an integer");
        }
        *out = if neg {
            (v as i64).wrapping_neg();
        } else {
            v as i64;
        };
        return true;
    }

    fn uint(self: &mut Self, out: &mut u32) bool {
        let mut v: i64 = 0;
        if !self.int(&mut v) {
            return false;
        }
        if v < 0 || v > 0xFFFFFFFF {
            return self.fail("expected a 32-bit unsigned integer");
        }
        *out = v as u32;
        return true;
    }

    // `0x` and hexadecimal digits.
    fn hex(self: &mut Self, out: &mut u64) bool {
        self.skip_spaces();
        if self.peek() != b'0' || self.at + 1 >= self.line_end || self.text.byte_at(self.at + 1) != b'x' {
            return self.fail("expected a hexadecimal number");
        }
        self.at += 2;
        let s = self.at;
        let mut v: u64 = 0;
        while self.at < self.line_end && hex_val(self.text.byte_at(self.at)) >= 0 {
            if self.at - s == 16 {
                return self.fail("the number does not fit 64 bits");
            }
            v = v << 4 | hex_val(self.text.byte_at(self.at)) as u64;
            self.at += 1;
        }
        if self.at == s {
            return self.fail("expected a hexadecimal digit");
        }
        *out = v;
        return true;
    }

    // `<prefix><n>`: a numbered name such as `v3`, `b0`, `s2`, `f1`, `l0`.
    fn numbered(self: &mut Self, prefix: u8, out: &mut u32) bool {
        self.skip_spaces();
        if self.peek() != prefix {
            return self.fail("expected a numbered name");
        }
        self.at += 1;
        return self.uint(out);
    }

    // A string literal into `out`.
    fn quoted(self: &mut Self, out: &mut String) bool {
        self.skip_spaces();
        if self.peek() != b'"' {
            return self.fail("expected a string literal");
        }
        self.at += 1;
        while self.at < self.line_end {
            let c = self.text.byte_at(self.at);
            self.at += 1;
            if c == b'"' {
                return true;
            }
            if c != b'\\' {
                out.push_byte(c);
                continue;
            }
            if self.at >= self.line_end {
                break;
            }
            let e = self.text.byte_at(self.at);
            self.at += 1;
            if e == b'"' || e == b'\\' {
                out.push_byte(e);
            } else if e == b'x' && self.at + 2 <= self.line_end && hex_val(self.text.byte_at(self.at)) >= 0 && hex_val(
                self.text.byte_at(self.at + 1),
            ) >= 0 {
                out.push_byte(
                    (hex_val(self.text.byte_at(self.at)) * 16 + hex_val(self.text.byte_at(self.at + 1))) as u8,
                );
                self.at += 2;
            } else {
                return self.fail("unknown escape in a string literal");
            }
        }
        return self.fail("unterminated string literal");
    }

    // `@name` or `@"name"`, into `out`.
    fn name(self: &mut Self, out: &mut String) bool {
        if !self.expect(b'@', "expected a symbol name") {
            return false;
        }
        if self.peek() == b'"' {
            return self.quoted(out);
        }
        let s = self.at;
        while self.at < self.line_end && name_char(self.text.byte_at(self.at)) {
            self.at += 1;
        }
        if self.at == s {
            return self.fail("expected a symbol name");
        }
        out.push_str(self.text.slice(s, self.at));
        return true;
    }

    // `@name` of a declared symbol.
    fn sym_ref(self: &mut Self, out: &mut u32) bool {
        let mut nm = String::new();
        if !self.name(&mut nm) {
            return false;
        }
        *out = self.pkg.find_symbol(nm.as_str());
        return *out != NONE || self.fail("no symbol of this name is declared");
    }

    // A machine type.
    fn ty(self: &mut Self, out: &mut u8) bool {
        let w = self.word();
        *out = type_of_text(w);
        return *out != T_NONE || self.fail("expected a machine type");
    }

    // The end of the line: an optional location, then nothing but a comment.
    fn line_end_loc(self: &mut Self, loc: &mut Loc) bool {
        self.skip_spaces();
        if self.peek() == b'!' {
            self.at += 1;
            let mut f = self.file;
            if self.peek() == b'f' {
                if !self.numbered(b'f', &mut f) || !self.expect(b':', "expected ':' after the file") {
                    return false;
                }
                if f as usize >= self.pkg.files.len() {
                    return self.fail("no such file");
                }
            }
            let mut l: u32 = 0;
            let mut c: u32 = 0;
            if !self.uint(&mut l) || !self.expect(b':', "expected ':' between line and column") || !self.uint(&mut c) {
                return false;
            }
            if l == 0 {
                return self.fail("a line is 1 or more");
            }
            *loc = Loc { file: f, line: l, col: c };
        }
        self.skip_spaces();
        return self.peek() == 0 || self.fail("unexpected text at the end of the line");
    }

    fn package(self: &mut Self) bool {
        if !self.next_line() || !self.expect_word("lir", "expected 'lir'") || !self.expect_word("ptr", "expected 'ptr'") {
            return false;
        }
        let mut pb: u32 = 0;
        if !self.uint(&mut pb) || pb != 4 && pb != 8 {
            return self.fail("the pointer size is 4 or 8");
        }
        self.pkg.ptr_bytes = pb;
        self.skip_spaces();
        if self.peek() == b'v' {
            let mut vb: u32 = 0;
            if !self.expect_word("vec", "expected 'vec'") || !self.uint(&mut vb) || vb != 0 && vb != 16 && vb != 32 && vb != 64 {
                return self.fail("the vector register width is 0, 16, 32 or 64");
            }
            self.pkg.vec_regs = vb;
        }
        let mut loc = Loc { file: 0, line: 0, col: 0 };
        if !self.line_end_loc(&mut loc) {
            return false;
        }
        while self.next_line() {
            self.skip_spaces();
            if self.peek() == 0 {
                continue;
            }
            let ok = if self.at == self.line_start && self.peek() == b'b' {
                self.block_header();
            } else if self.at != self.line_start {
                self.body_line();
            } else {
                self.top_line();
            };
            if !ok {
                return false;
            }
        }
        return self.end_body();
    }

    fn top_line(self: &mut Self) bool {
        let w = self.word();
        let mut loc = Loc { file: 0, line: 0, col: 0 };
        if w == "file" {
            let mut k: u32 = 0;
            let mut path = String::new();
            if !self.numbered(b'f', &mut k) || !self.quoted(&mut path) {
                return false;
            }
            if k as usize != self.pkg.files.len() || self.pkg.add_file(path.as_str()) != k {
                return self.fail("files are numbered in order, each path once");
            }
            return self.line_end_loc(&mut loc);
        }
        if w == "sym" {
            let mut nm = String::new();
            if !self.name(&mut nm) {
                return false;
            }
            let kind = self.word();
            let link = self.word();
            if kind != "fn" && kind != "data" && kind != "tls" || link != "global" && link != "local" {
                return self.fail("expected 'fn', 'data' or 'tls', then 'global' or 'local'");
            }
            let sk = if kind == "fn" {
                SK_FUNC;
            } else if kind == "tls" {
                SK_TLS;
            } else {
                SK_DATA;
            };
            let s = self.pkg.add_symbol(nm.as_str(), sk, ast::pick(link == "global", SL_GLOBAL, SL_LOCAL));
            if s == NONE {
                return self.fail("the symbol is declared twice");
            }
            self.pkg.syms.index_mut(s as usize).used = self.keyword("used");
            self.pkg.syms.index_mut(s as usize).ext = self.keyword("ext");
            if self.keyword("section") {
                let mut sp = String::new();
                if !self.quoted(&mut sp) {
                    return false;
                }
                self.pkg.set_section(s, sp.as_str());
            }
            return self.line_end_loc(&mut loc);
        }
        if w == "data" {
            return self.end_body() && self.data_line();
        }
        if w == "fn" {
            if !self.end_body() {
                return false;
            }
            let mut s: u32 = 0;
            if !self.sym_ref(&mut s) {
                return false;
            }
            if self.pkg.syms[s as usize].kind != SK_FUNC || self.pkg.syms[s as usize].def != NONE {
                return self.fail("the symbol is no function symbol without a definition");
            }
            self.sym = s;
            self.body.clear();
            self.file = 0;
            self.vmap.truncate(0);
            self.fixes.truncate(0);
            self.lays.truncate(0);
            return self.line_end_loc(&mut loc);
        }
        return self.fail("expected 'file', 'sym', 'data' or 'fn'");
    }

    fn data_line(self: &mut Self) bool {
        let mut s: u32 = 0;
        let mut size: u32 = 0;
        let mut al: u32 = 0;
        if !self.sym_ref(&mut s) || !self.expect_word("size", "expected 'size'") || !self.uint(&mut size) || !self.expect_word(
            "align",
            "expected 'align'",
        ) || !self.uint(&mut al) {
            return false;
        }
        let ro = self.keyword("ro");
        let mut bytes = Vector::<u8>::new();
        if self.keyword("bytes") {
            self.skip_spaces();
            while self.at + 1 < self.line_end && hex_val(self.text.byte_at(self.at)) >= 0 && hex_val(
                self.text.byte_at(self.at + 1),
            ) >= 0 {
                bytes.push((hex_val(self.text.byte_at(self.at)) * 16 + hex_val(self.text.byte_at(self.at + 1))) as u8);
                self.at += 2;
            }
        }
        let mut rs = Vector::<Reloc>::new();
        while self.keyword("reloc") {
            let mut off: u32 = 0;
            let mut t: u32 = 0;
            if !self.uint(&mut off) || !self.sym_ref(&mut t) {
                return false;
            }
            let mut add: i64 = 0;
            self.skip_spaces();
            if (self.peek() == b'+' || self.peek() == b'-') && !self.int(&mut add) {
                return false;
            }
            rs.push(Reloc { offset: off, sym: t, addend: add });
        }
        let mut loc = Loc { file: 0, line: 0, col: 0 };
        if !self.line_end_loc(&mut loc) {
            return false;
        }
        if al > 31 || !self.pkg.add_data(s, size, al as u8, ro, bytes[0..bytes.len()], rs[0..rs.len()]) {
            return self.fail("the data does not fit its symbol, its size or its relocations");
        }
        return true;
    }

    // A header line of the body: `file`, `layout`, `sig` or `slot`; else an instruction.
    fn body_line(self: &mut Self) bool {
        if self.sym == NONE {
            return self.fail("an indented line outside a function");
        }
        let save = self.at;
        let w = self.word();
        let mut loc = Loc { file: 0, line: 0, col: 0 };
        if self.body.blocks.len() == 0 {
            if w == "file" {
                let mut f: u32 = 0;
                if !self.numbered(b'f', &mut f) || f as usize >= self.pkg.files.len() {
                    return self.fail("no such file");
                }
                self.file = f;
                return self.line_end_loc(&mut loc);
            }
            if w == "layout" {
                return self.layout_line();
            }
            if w == "naked" {
                self.body.naked = true;
                return self.line_end_loc(&mut loc);
            }
            if w == "sig" {
                let mut sg: u32 = 0;
                if !self.signature(&mut sg) {
                    return false;
                }
                self.body.sig = sg;
                return self.line_end_loc(&mut loc);
            }
            if w == "slot" {
                let mut k: u32 = 0;
                let mut size: u32 = 0;
                let mut al: u32 = 0;
                if !self.numbered(b's', &mut k) || !self.expect_word("size", "expected 'size'") || !self.uint(&mut size) || !self.expect_word(
                    "align",
                    "expected 'align'",
                ) || !self.uint(&mut al) {
                    return false;
                }
                if k as usize != self.body.slots.len() || al > 31 {
                    return self.fail("slots are numbered in order");
                }
                let _ = self.body.slot(size, al as u8);
                return self.line_end_loc(&mut loc);
            }
            return self.fail("expected 'file', 'layout', 'naked', 'sig', 'slot' or a block");
        }
        self.at = save;
        return self.inst_line();
    }

    fn layout_line(self: &mut Self) bool {
        let mut k: u32 = 0;
        let mut size: u32 = 0;
        let mut al: u32 = 0;
        if !self.numbered(b'l', &mut k) || !self.expect_word("size", "expected 'size'") || !self.uint(&mut size) || !self.expect_word(
            "align",
            "expected 'align'",
        ) || !self.uint(&mut al) || !self.expect(b'[', "expected '['") {
            return false;
        }
        if k as usize != self.lays.len() {
            return self.fail("layouts are numbered in order");
        }
        let at = self.body.pool.len() as u32;
        self.body.pool.push(size);
        self.body.pool.push(al);
        self.body.pool.push(0);
        if !self.eat(b']') {
            loop {
                let mut off: u32 = 0;
                let mut t: u8 = 0;
                if !self.uint(&mut off) || !self.ty(&mut t) {
                    return false;
                }
                self.body.pool.push(off);
                self.body.pool.push(t);
                self.body.pool[at as usize + 2] += 1;
                if self.eat(b']') {
                    break;
                }
                if !self.expect(b',', "expected ',' or ']'") {
                    return false;
                }
            }
        }
        self.lays.push(at);
        let mut loc = Loc { file: 0, line: 0, col: 0 };
        return self.line_end_loc(&mut loc);
    }

    // A parameter or result type: a machine type, `l<k>` or `void` (results only).
    fn param_type(self: &mut Self, out: &mut u32) bool {
        self.skip_spaces();
        if self.peek() == b'l' {
            let mut k: u32 = 0;
            if !self.numbered(b'l', &mut k) {
                return false;
            }
            if k as usize >= self.lays.len() {
                return self.fail("no such layout");
            }
            *out = AGG | self.lays[k as usize];
            return true;
        }
        if self.keyword("void") {
            *out = T_NONE;
            return true;
        }
        let w = self.word();
        let s = w.ends_with(".s");
        let t = type_of_text(
            if s {
                w.slice(0, w.len() - 2);
            } else {
                w;
            },
        );
        if t == T_NONE || s && t != T_I8 && t != T_I16 {
            return self.fail("expected a machine type");
        }
        *out = t as u32 | ast::pick(s, SIG_SEXT, 0);
        return true;
    }

    // `(params) -> result`, `...` before the variadic ones (or alone at the end).
    fn signature(self: &mut Self, out: &mut u32) bool {
        if !self.expect(b'(', "expected '('") {
            return false;
        }
        let mut ps = Vector::<u32>::new();
        let mut nfixed = NONE;
        if !self.eat(b')') {
            loop {
                self.skip_spaces();
                if self.peek() == b'.' {
                    if !self.expect_word("...", "expected '...'") || nfixed != NONE {
                        return self.fail("one '...' per signature");
                    }
                    nfixed = ps.len() as u32;
                    if self.eat(b')') {
                        break;
                    }
                }
                let mut pt: u32 = 0;
                if !self.param_type(&mut pt) || pt == T_NONE as u32 {
                    return self.fail("expected a parameter type");
                }
                ps.push(pt);
                if self.eat(b')') {
                    break;
                }
                if !self.expect(b',', "expected ',' or ')'") {
                    return false;
                }
            }
        }
        if ps.len() as u32 > verify::MAX_ARGS {
            return self.fail("the signature passes the argument limit");
        }
        let mut ret: u32 = 0;
        if !self.expect(b'-', "expected '->'") || !self.expect(b'>', "expected '->'") || !self.param_type(&mut ret) {
            return false;
        }
        let variadic = nfixed != NONE;
        *out = self.body.signature(ps[0..ps.len()], ast::pick(variadic, nfixed, ps.len() as u32), variadic, ret);
        return true;
    }

    // `b<k>[(v<n>: type, ...)]:[ cold]`.
    fn block_header(self: &mut Self) bool {
        if self.sym == NONE {
            return self.fail("a block outside a function");
        }
        if self.body.sig == NONE {
            return self.fail("a body opens with its signature");
        }
        let mut k: u32 = 0;
        if !self.numbered(b'b', &mut k) {
            return false;
        }
        if k as usize != self.body.blocks.len() {
            return self.fail("blocks are numbered in order");
        }
        let mut tys = Vector::<u8>::new();
        let mut nums = Vector::<u32>::new();
        if self.eat(b'(') {
            loop {
                let mut v: u32 = 0;
                let mut t: u8 = 0;
                if !self.numbered(b'v', &mut v) || !self.expect(b':', "expected ':'") || !self.ty(&mut t) {
                    return false;
                }
                tys.push(t);
                nums.push(v);
                if self.eat(b')') {
                    break;
                }
                if !self.expect(b',', "expected ',' or ')'") {
                    return false;
                }
            }
        }
        if !self.expect(b':', "expected ':' after the block") {
            return false;
        }
        let cold = self.keyword("cold");
        let mut loc = Loc { file: 0, line: 0, col: 0 };
        if !self.line_end_loc(&mut loc) {
            return false;
        }
        if self.body.blocks.len() != 0 && !self.closed() {
            return self.fail("the previous block has no terminator");
        }
        let blk = self.body.add_block(tys[0..tys.len()]);
        if cold {
            self.body.blocks.index_mut(blk as usize).flags = BLOCK_COLD;
        }
        self.body.begin(blk);
        for j in 0..nums.len() {
            if !self.define_value(nums[j], self.body.param(blk, j as u32)) {
                return false;
            }
        }
        return true;
    }

    // Whether the last block ends with a terminator.
    const fn closed(self: &Self) bool {
        let n = self.body.insts.len();
        let blk = self.body.blocks[self.body.blocks.len() - 1];
        return blk.len != 0 && is_terminator(self.body.insts[n - 1].op);
    }

    // Printed value `num` is value `v`: numbers come in order.
    fn define_value(self: &mut Self, num: u32, v: Value) bool {
        if num as usize != self.vmap.len() {
            return self.fail("values are numbered in order");
        }
        self.vmap.push(v);
        return true;
    }

    // A value operand: `v<n>` (a printed number, patched later when not yet defined) or `none`.
    fn value(self: &mut Self, out: &mut u32, fixed: &mut bool) bool {
        if self.keyword("none") {
            *out = VNONE;
            *fixed = false;
            return true;
        }
        let mut n: u32 = 0;
        if !self.numbered(b'v', &mut n) {
            return false;
        }
        if n as usize < self.vmap.len() {
            *out = self.vmap[n as usize];
            *fixed = false;
        } else {
            *out = n;
            *fixed = true;
        }
        return true;
    }

    // A value operand in field `field` of the instruction about to be added.
    fn inst_value(self: &mut Self, field: u64, out: &mut u32) bool {
        let mut fx = false;
        if !self.value(out, &mut fx) {
            return false;
        }
        if fx {
            self.fixes.push(
                Fix {
                    at: self.body.insts.len() as u64 << 2 | field,
                    pool: false,
                    line: self.line_no,
                    col: self.at - self.line_start + 1,
                },
            );
        }
        return true;
    }

    // A value appended to the pool.
    fn pool_value(self: &mut Self) bool {
        let mut v: u32 = 0;
        let mut fx = false;
        if !self.value(&mut v, &mut fx) {
            return false;
        }
        if fx {
            self.fixes.push(
                Fix {
                    at: self.body.pool.len() as u64,
                    pool: true,
                    line: self.line_no,
                    col: self.at - self.line_start + 1,
                },
            );
        }
        self.body.pool.push(v);
        return true;
    }

    // `b<k>[(values)]` as an edge in the pool.
    fn edge(self: &mut Self, out: &mut u32) bool {
        let mut k: u32 = 0;
        if !self.numbered(b'b', &mut k) {
            return false;
        }
        let at = self.body.pool.len() as u32;
        self.body.pool.push(k);
        self.body.pool.push(0);
        if self.eat(b'(') {
            loop {
                if !self.pool_value() {
                    return false;
                }
                self.body.pool[at as usize + 1] += 1;
                if self.body.pool[at as usize + 1] > verify::MAX_ARGS {
                    return self.fail("the edge passes the argument limit");
                }
                if self.eat(b')') {
                    break;
                }
                if !self.expect(b',', "expected ',' or ')'") {
                    return false;
                }
            }
        }
        *out = at;
        return true;
    }

    // `+n` or `-n`, or nothing: a byte offset.
    fn offset(self: &mut Self, out: &mut u32) bool {
        self.skip_spaces();
        *out = 0;
        if self.peek() != b'+' && self.peek() != b'-' {
            return true;
        }
        let mut v: i64 = 0;
        if !self.int(&mut v) {
            return false;
        }
        if v < -2147483648 || v > 2147483647 {
            return self.fail("an offset fits 32 bits");
        }
        *out = (v as i32) as u32;
        return true;
    }

    // An order name.
    fn order(self: &mut Self, out: &mut u16) bool {
        let w = self.word();
        for k in 0..5u16 {
            if order_name(k) == w {
                *out = k;
                return true;
            }
        }
        return self.fail("expected a memory order");
    }

    fn inst_line(self: &mut Self) bool {
        if self.body.blocks.len() == 0 {
            return self.fail("an instruction outside a block");
        }
        if self.closed() {
            return self.fail("an instruction after its block's terminator");
        }
        if self.body.insts.len() as u64 >= verify::MAX_INSTS as u64 {
            return self.fail("the body passes the instruction limit");
        }
        let mut num = NONE;
        let mut flag = NONE;
        self.skip_spaces();
        // A result: `v` and a digit (a mnemonic such as `vaend` also starts with `v`); a checked
        // operation's flag after a ','.
        let nx = self.at + 1;
        if self.peek() == b'v' && nx < self.line_end && self.text.byte_at(nx) >= b'0' && self.text.byte_at(nx) <= b'9' {
            if !self.numbered(b'v', &mut num) || self.eat(b',') && !self.numbered(b'v', &mut flag) || !self.expect(
                b'=',
                "expected '='",
            ) {
                return false;
            }
        }
        let mn = self.word();
        // The mnemonic: the opcode, then its suffixes, each after a '.'.
        self.parts.truncate(0);
        let mut s: usize = 0;
        for k in 0..mn.len() + 1 {
            if k == mn.len() || mn.byte_at(k) == b'.' {
                self.parts.push(mn.slice(s, k));
                s = k + 1;
            }
        }
        let mut op: u8 = 0;
        let mut first: usize = 1;
        if self.parts.len() > 1 && self.parts[0] == "call" && self.parts[1] == "ind" {
            op = O_CALLIND;
            first = 2;
        } else {
            let p0 = self.parts[0];
            switch self.ops.get(&nm::hash_bytes(p0.ptr(), p0.len())) {
                Some(k) => {
                    if op_info(*k).name == p0 {
                        op = *k;
                    }
                },
                None => {},
            };
        }
        if op == 0 || op == O_CALLIND && first == 1 {
            return self.fail("unknown opcode");
        }
        let f = op_info(op).form;
        let mut t = Inst { op: op, ty: T_NONE, aux: 0, a: VNONE, b: VNONE, c: VNONE };
        // Suffixes before the type.
        let mut pi = first;
        if f == F_CMP {
            let mut found = false;
            for c in 0..C_COUNT {
                if pi < self.parts.len() && cond_name(c) == self.parts[pi] {
                    t.aux = c;
                    found = true;
                }
            }
            if !found {
                return self.fail("unknown condition");
            }
            pi += 1;
            t.ty = T_I8;
        } else if f == F_OVF {
            if pi >= self.parts.len() || self.parts[pi] != "s" && self.parts[pi] != "u" {
                return self.fail("expected '.s' or '.u'");
            }
            t.aux = ast::pick(self.parts[pi] == "s", OV_SIGNED, 0);
            pi += 1;
        } else if op == O_ARMW {
            let mut found = false;
            for r in 0..6u16 {
                if pi < self.parts.len() && rmw_name(r) == self.parts[pi] {
                    t.aux = r << 4;
                    found = true;
                }
            }
            if !found {
                return self.fail("expected a read-modify-write operation");
            }
            pi += 1;
        } else if op == O_MEMCPY && pi < self.parts.len() && self.parts[pi] == "overlap" {
            t.aux = MEM_OVERLAP;
            pi += 1;
        } else if (op == O_FPTOSI || op == O_FPTOUI) && pi < self.parts.len() && self.parts[pi] == "unchecked" {
            t.aux = CV_UNCHECKED;
            pi += 1;
        } else if op == O_VOP {
            let mut found = false;
            if pi < self.parts.len() {
                let pn = self.parts[pi];
                switch self.vops.get(&nm::hash_bytes(pn.ptr(), pn.len())) {
                    Some(k) => {
                        found = core::op_name(*k) == pn;
                        t.aux = *k;
                    },
                    None => {},
                };
            }
            if !found {
                return self.fail("unknown vector operation");
            }
            pi += 1;
            if pi < self.parts.len() && self.parts[pi] == "s" {
                t.aux |= VOP_SIGNED;
                pi += 1;
            }
            if pi < self.parts.len() && self.parts[pi] == "ds" {
                t.aux |= VOP_DSIGNED;
                pi += 1;
            }
            if pi < self.parts.len() && self.parts[pi] == "unchecked" {
                t.aux |= VOP_UNCHECKED;
                pi += 1;
            }
        }
        if op == O_ACAS {
            t.ty = T_I8;
        } else if op == O_SLOTADDR || op == O_SYMADDR || op == O_RETADDR || op == O_PTRADD {
            t.ty = T_PTR;
        } else if pi < self.parts.len() {
            t.ty = type_of_text(self.parts[pi]);
            if t.ty == T_NONE {
                return self.fail("unknown suffix");
            }
            pi += 1;
        }
        if pi != self.parts.len() {
            return self.fail("unexpected suffix");
        }
        if num != NONE != (t.ty != T_NONE) {
            return self.fail("an instruction with a result names it, one without does not");
        }
        if flag != NONE != (f == F_OVF) || flag != NONE && flag != num + 1 {
            return self.fail("a checked operation names its value and then its flag, one other instruction no flag");
        }
        if !self.operands(&mut t, f) {
            return false;
        }
        let mut loc = Loc { file: 0, line: 0, col: 0 };
        if !self.line_end_loc(&mut loc) {
            return false;
        }
        let v = self.body.emit(t, self.body.loc(loc));
        if num != NONE && !self.define_value(num, v) {
            return false;
        }
        return flag == NONE || self.define_value(flag, VFLAG | v);
    }

    fn operands(self: &mut Self, t: &mut Inst, f: u8) bool {
        let op = t.op;
        if f == F_IMM {
            if op == O_FCONST {
                let mut bits: u64 = 0;
                if !self.hex(&mut bits) {
                    return false;
                }
                t.a = bits as u32;
                t.b = (bits >> 32) as u32;
            } else {
                let mut v: i64 = 0;
                if !self.int(&mut v) {
                    return false;
                }
                let bits = type_bits(t.ty, self.pkg.ptr_bytes);
                let u = if bits >= 64 {
                    v as u64;
                } else {
                    v as u64 & (1u64 << bits as u64) - 1;
                };
                t.a = u as u32;
                t.b = (u >> 32) as u32;
            }
            return true;
        }
        if f == F_WIDE {
            t.a = self.body.words.len() as u32;
            t.b = 0;
            loop {
                let mut w: u64 = 0;
                if !self.hex(&mut w) {
                    return false;
                }
                self.body.words.push(w);
                t.b += 1;
                if !self.eat(b',') {
                    return true;
                }
            }
        }
        if f == F_SYM {
            let mut s: u32 = 0;
            if !self.sym_ref(&mut s) || !self.offset(&mut t.b) {
                return false;
            }
            t.a = self.body.ref_sym(s);
            return true;
        }
        if f == F_SLOT {
            return self.numbered(b's', &mut t.a);
        }
        if f == F_UN || f == F_RET {
            self.skip_spaces();
            if f == F_RET && (self.peek() == 0 || self.peek() == b'!') {
                return true;
            }
            return self.inst_value(0, &mut t.a);
        }
        if f == F_BIN || f == F_CMP || f == F_OVF {
            return self.inst_value(0, &mut t.a) && self.expect(b',', "expected ','") && self.inst_value(1, &mut t.b);
        }
        if f == F_TRI {
            if !self.inst_value(0, &mut t.a) || !self.expect(b',', "expected ','") || !self.inst_value(1, &mut t.b) || !self.expect(
                b',',
                "expected ','",
            ) || !self.inst_value(2, &mut t.c) {
                return false;
            }
            if op == O_ACAS {
                let mut so: u16 = 0;
                let mut fo: u16 = 0;
                if !self.order(&mut so) || !self.order(&mut fo) {
                    return false;
                }
                t.aux = so | fo << 3 | ast::pick(self.keyword("weak"), ACAS_WEAK, 0);
            }
            return true;
        }
        if f == F_PTRADD {
            if !self.inst_value(0, &mut t.a) {
                return false;
            }
            if self.eat(b',') {
                let mut sc: u32 = 0;
                if !self.inst_value(1, &mut t.b) || !self.expect(b'*', "expected '*'") || !self.uint(&mut sc) {
                    return false;
                }
                if sc == 0 || sc > 65535 {
                    return self.fail("a scale is 1 to 65535");
                }
                t.aux = sc as u16;
            }
            return self.offset(&mut t.c);
        }
        if f == F_LOAD || f == F_STORE {
            if f == F_STORE && (!self.inst_value(1, &mut t.b) || !self.expect(b',', "expected ','")) {
                return false;
            }
            if !self.inst_value(0, &mut t.a) || !self.offset(&mut t.c) {
                return false;
            }
            if op == O_ALOAD || op == O_ASTORE || op == O_ARMW {
                let mut o: u16 = 0;
                if !self.order(&mut o) {
                    return false;
                }
                t.aux |= o;
                return true;
            }
            let mut al: u32 = 0;
            if !self.expect_word("align", "expected 'align'") || !self.uint(&mut al) || al > 15 {
                return self.fail("an alignment is 0 to 15");
            }
            t.aux = al as u16 | ast::pick(self.keyword("volatile"), MEM_VOLATILE, 0);
            return true;
        }
        if f == F_CALL || f == F_CALLIND {
            if f == F_CALL {
                let mut s: u32 = 0;
                if !self.sym_ref(&mut s) {
                    return false;
                }
                t.a = self.body.ref_sym(s);
            } else if !self.inst_value(0, &mut t.a) {
                return false;
            }
            if !self.expect(b'(', "expected '('") {
                return false;
            }
            t.c = self.body.pool.len() as u32;
            let mut n: u32 = 0;
            if !self.eat(b')') {
                loop {
                    if !self.pool_value() {
                        return false;
                    }
                    n += 1;
                    if n > verify::MAX_ARGS {
                        return self.fail("the call passes the argument limit");
                    }
                    if self.eat(b')') {
                        break;
                    }
                    if !self.expect(b',', "expected ',' or ')'") {
                        return false;
                    }
                }
            }
            t.aux = n as u16;
            return self.expect(b':', "expected ':' and the call's signature") && self.signature(&mut t.b);
        }
        if f == F_ASM {
            return self.asm_operands(t);
        }
        if f == F_VOP {
            if !self.expect(b'(', "expected '('") {
                return false;
            }
            t.a = self.body.pool.len() as u32;
            t.b = 0;
            if !self.eat(b')') {
                loop {
                    if !self.pool_value() {
                        return false;
                    }
                    t.b += 1;
                    if self.eat(b')') {
                        break;
                    }
                    if !self.expect(b',', "expected ',' or ')'") {
                        return false;
                    }
                }
            }
            if self.keyword("lanes") {
                if !self.expect(b'[', "expected '['") {
                    return false;
                }
                t.c = self.body.pool.len() as u32;
                self.body.pool.push(0);
                if !self.eat(b']') {
                    loop {
                        let mut l: u32 = 0;
                        if !self.uint(&mut l) {
                            return false;
                        }
                        self.body.pool.push(l);
                        self.body.pool[t.c as usize] += 1;
                        if self.eat(b']') {
                            break;
                        }
                        if !self.expect(b',', "expected ',' or ']'") {
                            return false;
                        }
                    }
                }
            }
            return true;
        }
        if f == F_JMP {
            return self.edge(&mut t.a);
        }
        if f == F_BR {
            return self.inst_value(0, &mut t.a) && self.expect(b',', "expected ','") && self.edge(&mut t.b) && self.expect(
                b',',
                "expected ','",
            ) && self.edge(&mut t.c);
        }
        if f == F_SWITCH {
            if !self.inst_value(0, &mut t.a) || !self.expect(b'[', "expected '['") {
                return false;
            }
            t.b = self.body.words.len() as u32;
            self.words.truncate(0);
            if !self.eat(b']') {
                loop {
                    let mut v: i64 = 0;
                    let mut e: u32 = 0;
                    if !self.int(&mut v) || !self.expect(b'-', "expected '->'") || !self.expect(b'>', "expected '->'") || !self.edge(
                        &mut e,
                    ) {
                        return false;
                    }
                    self.body.words.push(v as u64);
                    self.words.push(e);
                    if self.words.len() > 65535 {
                        return self.fail("the switch passes the case limit");
                    }
                    if self.eat(b']') {
                        break;
                    }
                    if !self.expect(b',', "expected ',' or ']'") {
                        return false;
                    }
                }
            }
            let mut d: u32 = 0;
            if !self.expect_word("else", "expected 'else'") || !self.edge(&mut d) {
                return false;
            }
            t.aux = self.words.len() as u16;
            t.c = self.body.pool.len() as u32;
            for k in 0..self.words.len() {
                self.body.pool.push(self.words[k]);
            }
            self.body.pool.push(d);
            return true;
        }
        if f == F_PANIC {
            let mut m = String::new();
            if !self.quoted(&mut m) {
                return false;
            }
            t.a = self.body.ref_msg(self.pkg.add_message(m.as_str()));
            return !self.keyword("lane") || self.inst_value(1, &mut t.b);
        }
        if op == O_FENCE {
            return self.order(&mut t.aux);
        }
        return true;
    }

    // A quoted text as a body message into the pool.
    fn pool_msg(self: &mut Self) bool {
        let mut m = String::new();
        if !self.quoted(&mut m) {
            return false;
        }
        let k = self.body.ref_msg(self.pkg.add_message(m.as_str()));
        self.body.pool.push(k);
        return true;
    }

    // `asm "template" out["c" type, ..] in["c", ..] clobber["c", ..] (values)` (`F_ASM`).
    fn asm_operands(self: &mut Self, t: &mut Inst) bool {
        let r = self.body.pool.len() as u32;
        t.c = r;
        if !self.pool_msg() {
            return false;
        }
        for _ in 0..3 {
            self.body.pool.push(0);
        }
        // The outputs: their constraints, then their types after them.
        let mut tys = Vector::<u32>::new();
        if !self.expect_word("out", "expected 'out'") || !self.expect(b'[', "expected '['") {
            return false;
        }
        if !self.eat(b']') {
            loop {
                let mut ty: u8 = 0;
                if !self.pool_msg() || !self.ty(&mut ty) {
                    return false;
                }
                tys.push(ty);
                if self.eat(b']') {
                    break;
                }
                if !self.expect(b',', "expected ',' or ']'") {
                    return false;
                }
            }
        }
        for k in 0..tys.len() {
            self.body.pool.push(tys[k]);
        }
        self.body.pool[(r + 1) as usize] = tys.len() as u32;
        let names: [str; 2] = ["in", "clobber"];
        for w in 0..2usize {
            if !self.expect_word(unsafe names[w], "expected 'in' or 'clobber'") || !self.expect(b'[', "expected '['") {
                return false;
            }
            let mut n: u32 = 0;
            if !self.eat(b']') {
                loop {
                    if !self.pool_msg() {
                        return false;
                    }
                    n += 1;
                    if self.eat(b']') {
                        break;
                    }
                    if !self.expect(b',', "expected ',' or ']'") {
                        return false;
                    }
                }
            }
            self.body.pool[(r + 2 + w as u32) as usize] = n;
        }
        if !self.expect(b'(', "expected '('") {
            return false;
        }
        t.a = self.body.pool.len() as u32;
        t.b = 0;
        if !self.eat(b')') {
            loop {
                if !self.pool_value() {
                    return false;
                }
                t.b += 1;
                if self.eat(b')') {
                    break;
                }
                if !self.expect(b',', "expected ',' or ')'") {
                    return false;
                }
            }
        }
        if t.b != self.body.pool[(r + 1) as usize] + self.body.pool[(r + 2) as usize] {
            return self.fail("an asm takes one value per output and input");
        }
        return true;
    }

    // Patch the forward value numbers and define the body read so far.
    fn end_body(self: &mut Self) bool {
        if self.sym == NONE {
            return true;
        }
        if self.body.blocks.len() == 0 || !self.closed() {
            return self.fail("a function's last block has no terminator");
        }
        for k in 0..self.fixes.len() {
            let fx = self.fixes[k];
            let n = if fx.pool {
                self.body.pool[fx.at as usize];
            } else {
                match_field(self.body.insts[(fx.at >> 2) as usize], fx.at & 3);
            };
            if n as usize >= self.vmap.len() {
                // Report at the use: its line and the column after the value.
                self.line_no = fx.line;
                self.line_start = 0;
                self.at = fx.col - 1;
                return self.fail("a value is used but never defined");
            }
            let v = self.vmap[n as usize];
            if fx.pool {
                self.body.pool[fx.at as usize] = v;
            } else {
                let t = self.body.insts.index_mut((fx.at >> 2) as usize);
                if (fx.at & 3) == 0 {
                    t.a = v;
                } else if (fx.at & 3) == 1 {
                    t.b = v;
                } else {
                    t.c = v;
                }
            }
        }
        let _ = self.pkg.define(self.sym, &self.body);
        self.sym = NONE;
        return true;
    }
}

// An operand that names a value printed later: instruction << 2 | field (0 a, 1 b, 2 c), or a pool index;
// the line and column after the value.
struct Fix {
    pub at: u64,
    pub pool: bool,
    pub line: u32,
    pub col: usize,
}

extend Fix as Copy {}

const fn match_field(t: Inst, f: u64) u32 {
    if f == 0 {
        return t.a;
    }
    if f == 1 {
        return t.b;
    }
    return t.c;
}

const fn name_char(c: u8) bool {
    return c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9' || c == b'_' || c == b'.' || c == b'$';
}

const fn hex_val(c: u8) i64 {
    if c >= b'0' && c <= b'9' {
        return c - b'0';
    }
    if c >= b'a' && c <= b'f' {
        return c - b'a' + 10;
    }
    return -1;
}

/// The machine type text `w` spells, T_NONE for another word.
pub const fn type_of_text(w: str) u8 {
    let names: []str = ["none", "i8", "i16", "i32", "i64", "i128", "f32", "f64", "ptr"];
    for k in 1..names.len() {
        if names[k] == w {
            return k as u8;
        }
    }
    if w.len() < 4 || w.byte_at(0) != b'v' {
        return T_NONE;
    }
    let mut n: u32 = 0;
    let mut k: usize = 1;
    while k < w.len() && w.byte_at(k) >= b'0' && w.byte_at(k) <= b'9' && n < 1000 {
        n = n * 10 + (w.byte_at(k) - b'0') as u32;
        k += 1;
    }
    let lane = type_of_text(w.slice(k, w.len()));
    if n < 2 || n > 64 || (n & n - 1) != 0 || lane == T_NONE || lane == T_I128 || lane == T_PTR || is_vec(lane) {
        return T_NONE;
    }
    let t = vec_type(lane, n);
    return ast::pick(verify::type_ok(t), t, T_NONE);
}

// Each opcode by the hash of its name.
fn op_names() Map<u64, u8> {
    let mut m = Map::<u64, u8>::new();
    for k in 1..OP_COUNT {
        let n = op_info(k).name;
        let h = nm::hash_bytes(n.ptr(), n.len());
        if m.contains_key(&h) {
            panic("two opcode names hash alike");
        }
        m.insert(h, k);
    }
    return m;
}

// Each vector operation by the hash of its name.
fn vop_names() Map<u64, u16> {
    let mut m = Map::<u64, u16>::new();
    for k in 0..core::OP_COUNT {
        let n = core::op_name(k);
        let h = nm::hash_bytes(n.ptr(), n.len());
        if m.contains_key(&h) {
            panic("two vector operation names hash alike");
        }
        m.insert(h, k as u16);
    }
    return m;
}
