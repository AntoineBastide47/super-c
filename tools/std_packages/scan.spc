// A token scan of one Super-C source, exact for its `import` items and the functions and statics of its
// `extern` blocks: comments (nested block comments too), string, byte string and character literals and
// lifetimes are skipped, so text inside them never counts, and an item under `@platform`, `@arch` or `@when`
// counts as any other; each extern item records whether those `@platform` and `@arch` attributes keep it in
// a wasm32 build. A matchertext literal without holes is skipped as a string is; one with holes stops the
// scan with an error: the scan does not read its template.

/// One `import` item: its path segments joined by `::`, and its line.
pub struct Import {
    pub path: String,
    pub line: u32,
}

/// One function, or with `data` one static, of an `extern` block: its C symbol (the `@import` pin, else the
/// declared name), its line, and whether a wasm32 build keeps it: no `@platform` or `@arch` attribute of the
/// item or of its block leaves wasm out.
pub struct ExternFn {
    pub name: String,
    pub line: u32,
    pub data: bool,
    pub wasm: bool,
}

/// The items of one source. `error` is empty when the scan read the whole source; else it names the first
/// construct the scan cannot read, at `error_line`, and the item lists hold at most the items before it.
pub struct Scan {
    pub imports: Vector<Import>,
    pub externs: Vector<ExternFn>,
    pub error: String,
    pub error_line: u32,
}

const TOK_IDENT: u8 = 0;
const TOK_STRING: u8 = 1; // `start` and `len` span the content between the quotes
const TOK_PUNCT: u8 = 2; // one byte

struct Tok {
    pub kind: u8,
    pub start: u32,
    pub len: u32,
    pub line: u32,
}

/// The imports and extern functions of `src`.
pub fn scan(src: str) Scan {
    let mut s = Scan {
        imports: Vector::<Import>::new(),
        externs: Vector::<ExternFn>::new(),
        error: String::new(),
        error_line: 0,
    };
    let mut toks = Vector::<Tok>::new();
    if tokenize(src, &mut toks, &mut s) {
        read_items(src, &toks, &mut s);
    }
    return s;
}

// The byte at `i`, 0 past the end.
const fn at(src: str, i: usize) u8 {
    if i < src.len() {
        return src.byte_at(i);
    }
    return 0;
}

const fn is_digit(b: u8) bool {
    return b >= b'0' && b <= b'9';
}

// A byte of an identifier or a number: ASCII letters, digits, `_`, and every byte of a non-ASCII scalar.
const fn is_word_byte(b: u8) bool {
    return b == b'_' || b >= b'a' && b <= b'z' || b >= b'A' && b <= b'Z' || is_digit(b) || b >= 0x80;
}

// The length of the UTF-8 sequence lead byte `b` starts; 1 for ASCII.
const fn utf8_len(b: u8) usize {
    if b >= 0xF0 {
        return 4;
    }
    if b >= 0xE0 {
        return 3;
    }
    if b >= 0xC0 {
        return 2;
    }
    return 1;
}

const fn mt_closer(b: u8) u8 {
    if b == b'(' {
        return b')';
    }
    if b == b'[' {
        return b']';
    }
    return b'}';
}

// After an `M` that ends at `i`: true when a well-nested chain of `(`, `[`, `{` and their closers, then a
// `"`, follows: the start of a matchertext literal, as the compiler's lexer decides it.
const fn matchertext_ahead(src: str, i: usize) bool {
    let mut j = i;
    while at(src, j) == b'(' || at(src, j) == b'[' || at(src, j) == b'{' {
        j += 1;
    }
    let openers = j - i;
    for k in 0..openers {
        if at(src, j) != mt_closer(src.byte_at(i + openers - 1 - k)) {
            return false;
        }
        j += 1;
    }
    return at(src, j) == b'"';
}

// The index past the matchertext literal without holes whose `"` is at `i` (`M"(..)"`): its content is
// verbatim and its matchers match, so the literal ends at the closer that matches its opener, then a `"`.
// 0 when the source ends first. `line` counts the newlines of the content.
const fn raw_mt_end(src: str, i: usize, line: &mut u32) usize {
    let o = at(src, i + 1);
    if o != b'(' && o != b'[' && o != b'{' {
        return 0;
    }
    let mut depth: usize = 0;
    let mut j = i + 1;
    while j < src.len() {
        let c = src.byte_at(j);
        if c == b'(' || c == b'[' || c == b'{' {
            depth += 1;
        } else if c == b')' || c == b']' || c == b'}' {
            depth -= 1;
            if depth == 0 {
                return if at(src, j + 1) == b'"' {
                    j + 2;
                } else {
                    0;
                };
            }
        } else if c == b'\n' {
            *line += 1;
        }
        j += 1;
    }
    return 0;
}

// The index of the `"` that closes the string whose content starts at `i`; 0 when the line or the source
// ends first.
const fn string_end(src: str, i: usize) usize {
    let mut j = i;
    while j < src.len() {
        let b = src.byte_at(j);
        if b == b'"' {
            return j;
        }
        if b == b'\n' {
            return 0;
        }
        j += if b == b'\\' {
            2;
        } else {
            1;
        };
    }
    return 0;
}

// Past the `'` at `i`: past the whole character literal it opens, or past the quote alone when it starts a
// lifetime or a label (`'a` with no closing quote). 0 for an unterminated character literal.
const fn quote_end(src: str, i: usize) usize {
    if at(src, i + 1) == b'\\' {
        let mut j = i + 3;
        while j < src.len() && src.byte_at(j) != b'\'' && src.byte_at(j) != b'\n' {
            j += 1;
        }
        if at(src, j) != b'\'' {
            return 0;
        }
        return j + 1;
    }
    let n = utf8_len(at(src, i + 1));
    if at(src, i + 1 + n) == b'\'' {
        return i + 2 + n;
    }
    return i + 1;
}

// Set the scan error; false.
fn fail(s: &mut Scan, line: u32, msg: str) bool {
    s.error = String::from_str(msg);
    s.error_line = line;
    return false;
}

// The identifier, string and punctuation tokens of `src`; false on a construct the scan cannot read.
fn tokenize(src: str, toks: &mut Vector<Tok>, s: &mut Scan) bool {
    let n = src.len();
    let mut i: usize = 0;
    let mut line: u32 = 1;
    while i < n {
        let b = src.byte_at(i);
        if b == b'\n' {
            line += 1;
            i += 1;
        } else if b == b' ' || b == b'\t' || b == b'\r' {
            i += 1;
        } else if b == b'/' && at(src, i + 1) == b'/' {
            while i < n && src.byte_at(i) != b'\n' {
                i += 1;
            }
        } else if b == b'/' && at(src, i + 1) == b'*' {
            let first = line;
            let mut depth: usize = 1;
            i += 2;
            while depth > 0 {
                if i >= n {
                    return fail(s, first, "unterminated block comment");
                }
                let c = src.byte_at(i);
                if c == b'/' && at(src, i + 1) == b'*' {
                    depth += 1;
                    i += 2;
                } else if c == b'*' && at(src, i + 1) == b'/' {
                    depth -= 1;
                    i += 2;
                } else {
                    if c == b'\n' {
                        line += 1;
                    }
                    i += 1;
                }
            }
        } else if b == b'"' {
            let end = string_end(src, i + 1);
            if end == 0 {
                return fail(s, line, "unterminated string literal");
            }
            toks.push(Tok { kind: TOK_STRING, start: (i + 1) as u32, len: (end - i - 1) as u32, line: line });
            i = end + 1;
        } else if b == b'\'' {
            i = quote_end(src, i);
            if i == 0 {
                return fail(s, line, "unterminated character literal");
            }
        } else if is_digit(b) {
            while i < n && is_word_byte(src.byte_at(i)) {
                i += 1;
            }
        } else if is_word_byte(b) {
            let start = i;
            while i < n && is_word_byte(src.byte_at(i)) {
                i += 1;
            }
            let word = src.slice(start, i);
            if word == "b" && at(src, i) == b'"' {
                let end = string_end(src, i + 1);
                if end == 0 {
                    return fail(s, line, "unterminated byte string literal");
                }
                i = end + 1;
            } else if word == "b" && at(src, i) == b'\'' {
                i = quote_end(src, i);
                if i == 0 {
                    return fail(s, line, "unterminated byte character literal");
                }
            } else if word == "M" && at(src, i) == b'"' {
                let first = line;
                i = raw_mt_end(src, i, &mut line);
                if i == 0 {
                    return fail(s, first, "unterminated matchertext literal");
                }
            } else if word == "M" && matchertext_ahead(src, i) {
                return fail(s, line, "a matchertext literal with holes, which the scan does not read");
            } else {
                toks.push(Tok { kind: TOK_IDENT, start: start as u32, len: (i - start) as u32, line: line });
            }
        } else {
            toks.push(Tok { kind: TOK_PUNCT, start: i as u32, len: 1, line: line });
            i += 1;
        }
    }
    return true;
}

// The text of token `k`; empty past the last token.
const fn text<'a>(src: str<'a>, toks: &Vector<Tok>, k: usize) str<'a> {
    if k >= toks.len() {
        return "";
    }
    let t = toks[k];
    return src.slice(t.start as usize, (t.start + t.len) as usize);
}

const fn is_kind(toks: &Vector<Tok>, k: usize, kind: u8) bool {
    return k < toks.len() && toks[k].kind == kind;
}

const fn is_punct(src: str, toks: &Vector<Tok>, k: usize, p: str) bool {
    return is_kind(toks, k, TOK_PUNCT) && text(src, toks, k) == p;
}

const fn is_word(src: str, toks: &Vector<Tok>, k: usize, w: str) bool {
    return is_kind(toks, k, TOK_IDENT) && text(src, toks, k) == w;
}

// Whether the `@platform(..)` or `@arch(..)` whose `(` is token `k` keeps wasm32: a list of names joined by
// `|` that holds `wasm` (`wasm32` for an arch), or `!` and another name. `*end` is set past its `)`.
const fn keeps_wasm(src: str, toks: &Vector<Tok>, k: usize, arch: bool, end: &mut usize) bool {
    let want = if arch {
        "wasm32";
    } else {
        "wasm";
    };
    let mut j = k + 1;
    let neg = is_punct(src, toks, j, "!");
    if neg {
        j += 1;
    }
    let mut found = false;
    // Bounded by the tokens.
    while j < toks.len() && !is_punct(src, toks, j, ")") {
        if is_word(src, toks, j, want) {
            found = true;
        }
        j += 1;
    }
    *end = j + 1;
    return found != neg;
}

// The imports and the extern functions and statics, from the tokens.
fn read_items(src: str, toks: &Vector<Tok>, s: &mut Scan) {
    let mut depth: usize = 0;
    let mut block: usize = 0; // the brace depth of the extern block's items; 0 outside a block
    let mut pin = String::new(); // the pending `@import` symbol of the block's next item
    let mut wasm = true; // the `@platform` and `@arch` attributes since the last item keep wasm32
    let mut block_wasm = true; // the same, of the extern block
    let mut k: usize = 0;
    while k < toks.len() {
        let line = toks[k].line;
        if is_punct(src, toks, k, "@") && (is_word(src, toks, k + 1, "platform") || is_word(src, toks, k + 1, "arch")) && is_punct(
            src,
            toks,
            k + 2,
            "(",
        ) {
            let mut end: usize = 0;
            wasm = keeps_wasm(src, toks, k + 2, is_word(src, toks, k + 1, "arch"), &mut end) && wasm;
            k = end;
            continue;
        }
        if is_punct(src, toks, k, "{") || is_punct(src, toks, k, "}") || is_punct(src, toks, k, ";") {
            wasm = true;
        }
        if is_punct(src, toks, k, "{") {
            depth += 1;
        } else if is_punct(src, toks, k, "}") {
            if depth == 0 {
                let _ = fail(s, line, "unbalanced '}'");
                return;
            }
            depth -= 1;
            if depth < block {
                block = 0;
            }
            if depth == block {
                pin.clear();
            }
        } else if is_word(src, toks, k, "import") && !(k > 0 && is_punct(src, toks, k - 1, "@")) {
            k = read_import(src, toks, k, s);
            if k == 0 {
                return;
            }
            continue;
        } else if is_word(src, toks, k, "extern") {
            // `extern "ABI" ["header"] {`
            let mut j = k + 1;
            if !is_kind(toks, j, TOK_STRING) {
                let _ = fail(s, line, "an 'extern' without its ABI string");
                return;
            }
            j += 1;
            if is_kind(toks, j, TOK_STRING) {
                j += 1;
            }
            if !is_punct(src, toks, j, "{") {
                let _ = fail(s, line, "an 'extern' without its '{'");
                return;
            }
            depth += 1;
            block = depth;
            block_wasm = wasm;
            wasm = true;
            pin.clear();
            k = j + 1;
            continue;
        } else if block > 0 && depth == block {
            if is_punct(src, toks, k, "@") && is_word(src, toks, k + 1, "import") && is_punct(src, toks, k + 2, "(") && is_kind(
                toks,
                k + 3,
                TOK_STRING,
            ) && is_punct(src, toks, k + 4, ")") {
                pin = String::from_str(text(src, toks, k + 3));
                k += 5;
                continue;
            }
            let data = is_word(src, toks, k, "static");
            let mut n = k + 1;
            if data && is_word(src, toks, n, "mut") {
                n += 1;
            }
            if (data || is_word(src, toks, k, "fn")) && is_kind(toks, n, TOK_IDENT) {
                let name = if pin.is_empty() {
                    String::from_str(text(src, toks, n));
                } else {
                    pin.clone();
                };
                s.externs.push(ExternFn { name: name, line: line, data: data, wasm: block_wasm && wasm });
                pin.clear();
                k = n + 1;
                continue;
            }
            if is_punct(src, toks, k, ";") {
                pin.clear();
            }
        }
        k += 1;
    }
}

// The `import` item whose keyword is token `k`: `import a::b [as c | as *];`. The index after its `;`, or 0
// with the scan error set.
fn read_import(src: str, toks: &Vector<Tok>, k: usize, s: &mut Scan) usize {
    let line = toks[k].line;
    let mut j = k + 1;
    if !is_kind(toks, j, TOK_IDENT) {
        let _ = fail(s, line, "an 'import' without a path");
        return 0;
    }
    let mut path = String::from_str(text(src, toks, j));
    j += 1;
    while is_punct(src, toks, j, ":") && is_punct(src, toks, j + 1, ":") && is_kind(toks, j + 2, TOK_IDENT) {
        path.push_str("::");
        path.push_str(text(src, toks, j + 2));
        j += 3;
    }
    if is_word(src, toks, j, "as") && (is_kind(toks, j + 1, TOK_IDENT) || is_punct(src, toks, j + 1, "*")) {
        j += 2;
    }
    if !is_punct(src, toks, j, ";") {
        let _ = fail(s, line, "an 'import' without its ';'");
        return 0;
    }
    s.imports.push(Import { path: path, line: line });
    return j + 1;
}
