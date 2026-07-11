// Token-based source formatter (`super-c fmt`). Re-emits the trivia-preserving token stream with
// canonical Rust-style spacing and indentation. V1 contract: line breaks stay where the author put
// them (never joined, never forced), blank-line runs cap at one empty line, indentation is recomputed
// (4 spaces per brace level, +1 for open paren/bracket continuations and lines led by `.`/`&&`/`||`),
// and inter-token spacing comes from a (prev, cur) pair table plus the token state the grammar needs:
// generic-angle classification (bounded lookahead + follow-set check), unary-vs-binary `-`/`*`/`&`,
// and closure-pipe tracking. Comments are ordered tokens: a trailing `//` comment keeps its line with
// one space before it; block comments are emitted verbatim (only surrounding whitespace normalized).
// The output re-lexes to the identical significant token stream, so formatting cannot change meaning.

import lexer::lexer as lex;
import lexer::token as *;
import lexer::token_type as *;

struct Fx {
    pub src: *const u8,
    pub n: usize,
    pub brace: i32,
    pub paren: i32,
    pub brack: i32,
    pub gdepth: i32, // open generic-angle depth (spacing only; reset at ; { } for safety)
    pub in_closure: bool, // between the opening and closing `|` of closure params
    pub prev_glue: bool, // previous token glues right (unary prefix, generic `<`, closure-open `|`)
    pub prev_gclose: bool, // previous token closed a generic argument list (`>` / `>>`)
    pub in_sig: bool, // between a `fn` keyword and its body/terminator (return types live here)
    pub sig_paren: i32, // paren depth where that `fn` appeared; return position = back at this depth
    pub prev_empty_br: bool, // previous significant token was the `]` of an EMPTY `[]` (slice type head)
}

fn tk(toks: &Vector<Token>, i: usize) TokenType {
    return (*toks.at(i)).kind();
}

fn is_comment(k: TokenType) bool {
    return k == TokenType::LineComment || k == TokenType::BlockComment
        || k == TokenType::DocLineComment || k == TokenType::DocBlockComment;
}

// The previous token ends an operand: a `-`/`*`/`&` after one is a binary operator, before one a prefix.
fn is_operand_end(k: TokenType) bool {
    switch k {
        Identifier | IntegerLiteral | FloatLiteral | CharacterLiteral | ByteCharacterLiteral |
        StringLiteral | RawStringLiteral | ByteStringLiteral | True | False | Null |
        SelfLower | SelfUpper | RightParen | RightBracket | RightBrace | Question => { return true; },
        _ => { return false; },
    };
    return false;
}

// Token legal INSIDE a generic argument list (types, bounds, defaults, const-generic literals).
fn generic_arg_token(k: TokenType) bool {
    switch k {
        Identifier | SelfUpper | PathSeparator | Comma | Colon | Semicolon | IntegerLiteral |
        Star | Ampersand | Mut | Const | Dyn | Fn | Plus | Equal |
        LeftBracket | RightBracket => { return true; },
        _ => { return false; },
    };
    return false;
}

// May directly follow a closing `>` when it really ended a generic argument list (C#-style check).
fn generic_follow(k: TokenType) bool {
    switch k {
        LeftParen | RightParen | RightBracket | LeftBrace | RightBrace | Comma | Semicolon |
        Colon | PathSeparator | Equal | As | Where | Eof => { return true; },
        _ => { return false; },
    };
    return false;
}

// Classify the `<` at token index i: generic-argument opener (true) or less-than operator (false).
// Turbofish (`::<`) and `extend<` are unconditional; after an identifier a bounded forward scan must
// reach the matching `>`/`>>` through generic-legal tokens, with the closer's follow token confirming.
fn generic_open(fx: &Fx, toks: &Vector<Token>, i: usize) bool {
    let mut pi = i;
    let mut prev = TokenType::Eof;
    while pi > 0 {
        pi = pi - 1;
        prev = tk(&*toks, pi);
        if !is_comment(prev) { break; }
    }
    if prev == TokenType::PathSeparator { return true; }
    let lax = prev == TokenType::Extend; // `extend<T> Vector<..>`: an identifier follows the closer
    if !lax && prev != TokenType::Identifier && prev != TokenType::SelfUpper { return false; }
    let mut depth: i32 = 1;
    let mut pdepth: i32 = 0;
    let mut j = i + 1;
    let mut steps = 0;
    while j < fx.n && steps < 160 {
        let k = tk(&*toks, j);
        if is_comment(k) { j = j + 1; continue; }
        if k == TokenType::LessThan { depth = depth + 1; }
        else if k == TokenType::GreaterThan || k == TokenType::RightShift {
            if k == TokenType::RightShift { depth = depth - 2; }
            else { depth = depth - 1; }
            if depth <= 0 {
                if lax { return true; }
                let mut f = j + 1;
                while f < fx.n && is_comment(tk(&*toks, f)) { f = f + 1; }
                let fk = if f < fx.n { tk(&*toks, f); } else { TokenType::Eof; };
                return generic_follow(fk);
            }
        } else if k == TokenType::LeftParen { pdepth = pdepth + 1; }
        else if k == TokenType::RightParen {
            pdepth = pdepth - 1;
            if pdepth < 0 { return false; }
        } else if !generic_arg_token(k) { return false; }
        j = j + 1;
        steps = steps + 1;
    }
    return false;
}

// One space between prev and cur when they share a line? (Newlines are handled by the caller.)
// `sig_ret` marks a return-type position (`fn f(..) HERE`): what follows `)` is a type, not a call/index.
fn space_between(fx: &Fx, prev: TokenType, cur: TokenType, cur_gopen: bool, cur_gclose: bool, cur_pipe_close: bool, sig_ret: bool, cur_unary: bool) bool {
    if fx.prev_glue { return false; }
    // A slice-type head `[]` glues to its element: `[]u8`, `[]mut T`, `[]*mut T`.
    if fx.prev_empty_br && (cur == TokenType::Identifier || cur == TokenType::SelfUpper || cur == TokenType::Mut || cur_unary) {
        return false;
    }
    switch prev {
        LeftParen | LeftBracket | Dot | PathSeparator | At | Tilde | Bang => { return false; },
        Range | RangeInclusive => { return cur == TokenType::RightBrace; }, // `{ x, .. }` vs `a[1..]`
        Sizeof | Alignof => { return cur != TokenType::LeftParen; },
        _ => {},
    };
    if cur_gopen || cur_gclose { return false; }
    if cur_pipe_close { return false; }
    switch cur {
        Comma | Semicolon | Dot | Question | PathSeparator | Colon |
        RightParen | RightBracket | Range | RangeInclusive => { return false; },
        RightBrace => { return prev != TokenType::LeftBrace; }, // `{}` glued, `{ x }` spaced
        LeftParen => {
            if sig_ret { return true; } // `fn f(..) (u64, usize)`: a multi-return type, not a call
            if fx.prev_gclose { return false; } // turbofish call `f::<T>()`
            switch prev {
                Identifier | SelfUpper | New | Import | Fn | RightParen | RightBracket => { return false; }, // Fn: `fn(&T) U`; Import: `@c.import(..)`
                _ => { return true; },
            };
            return true;
        },
        LeftBracket => {
            if sig_ret { return true; } // `fn f(..) []T`: a slice return type, not indexing
            switch prev {
                Identifier | SelfLower | RightParen | RightBracket => { return false; }, // indexing
                _ => { return true; },
            };
            return true;
        },
        _ => {},
    };
    return true;
}

// Indentation level for a line whose first token is `k` (called with the depths as they are BEFORE
// that token is processed): 4 spaces per level.
fn line_indent(fx: &Fx, k: TokenType) i32 {
    let cont = fx.paren + fx.brack;
    let mut d = fx.brace;
    if k == TokenType::RightBrace {
        d = d - 1;
        if cont > 0 { d = d + 1; }
    } else if k == TokenType::RightParen || k == TokenType::RightBracket {
        if cont > 1 { d = d + 1; } // still nested after this closer; else align with the statement
    } else {
        if cont > 0 { d = d + 1; }
        if k == TokenType::Dot || k == TokenType::AmpersandAmpersand || k == TokenType::PipePipe {
            d = d + 1; // continuation: method chains and broken boolean operators
        }
    }
    if d < 0 { d = 0; }
    return d;
}

fn push_spaces(out: &mut String, n: i32) {
    let mut i: i32 = 0;
    while i < n { out.push_byte(b' '); i = i + 1; }
}

// Count '\n' bytes in src[from..to).
fn newlines_between(fx: &Fx, from: usize, to: usize) i32 {
    let mut c: i32 = 0;
    let mut i = from;
    while i < to {
        if (unsafe fx.src[i]) == b'\n' { c = c + 1; }
        i = i + 1;
    }
    return c;
}

// Format `source` (a whole file) into `out`. Returns false when the source does not lex (diagnostics
// are logged); `out` is untouched in that case. `file` is only used in diagnostics (may be null).
pub fn format_source(source: str, file: *const char, out: &mut String) bool {
    let mut s = String::from_str(source);
    let mut lx = lex::Lexer::new(&mut s);
    lx.set_file(file);
    lx.keep_trivia = true;
    lx.scan_tokens();
    if lx.has_errors() {
        lx.log_errors();
        lx.free();
        s.free();
        return false;
    }
    let mut toks = lx.take_tokens();
    lx.free();

    let mut fx = Fx {
        src: s.as_str().ptr(),
        n: toks.len(),
        brace: 0, paren: 0, brack: 0, gdepth: 0,
        in_closure: false, prev_glue: false, prev_gclose: false,
        in_sig: false, sig_paren: 0, prev_empty_br: false,
    };
    out.reserve(source.len() + source.len() / 16);

    let mut prev = TokenType::Eof; // sentinel: no previous token yet
    let mut prev_end: usize = 0;
    let mut emitted = false;
    let mut ti: usize = 0;
    while ti < fx.n {
        let t = *toks.at(ti);
        let k = t.kind();
        if k == TokenType::Eof { break; }

        // Classify context-dependent tokens before spacing.
        let gopen = k == TokenType::LessThan && generic_open(&fx, &toks, ti);
        let gclose = (k == TokenType::GreaterThan && fx.gdepth > 0)
            || (k == TokenType::RightShift && fx.gdepth > 1);
        let mut pipe_open = false;
        let mut pipe_close = false;
        if k == TokenType::Pipe {
            if fx.in_closure { pipe_close = true; }
            else if !is_operand_end(prev) && !fx.prev_gclose { pipe_open = true; }
        }
        let sig_ret = fx.in_sig && fx.paren == fx.sig_paren && prev == TokenType::RightParen;
        let mut nk = TokenType::Eof;
        if ti + 1 < fx.n { nk = tk(&toks, ti + 1); }
        // `-`/`*`/`&` are prefixes unless an operand just ended; a return-type position or a
        // `*mut`/`*const` pointer head is always a prefix.
        let unary = (k == TokenType::Minus || k == TokenType::Star || k == TokenType::Ampersand)
            && (!is_operand_end(prev) && !fx.prev_gclose
                || sig_ret
                || (k == TokenType::Star && (nk == TokenType::Mut || nk == TokenType::Const)));

        // Separation: preserved line breaks (blank runs capped at one) or canonical spacing.
        if !emitted {
            // start of file: no leading blank lines
        } else {
            let nl = newlines_between(&fx, prev_end, t.start() as usize);
            if nl > 0 {
                out.push_byte(b'\n');
                if nl > 1 { out.push_byte(b'\n'); }
                push_spaces(&mut *out, 4 * line_indent(&fx, k));
            } else if is_comment(k) {
                out.push_byte(b' '); // trailing comment: exactly one space after the code
            } else if space_between(&fx, prev, k, gopen, gclose, pipe_close, sig_ret, unary) {
                out.push_byte(b' ');
            }
        }

        // The token text itself, verbatim from the source (line comments lose trailing blanks).
        let mut tlen = t.len() as usize;
        if k == TokenType::LineComment || k == TokenType::DocLineComment {
            while tlen > 0 {
                let b = unsafe fx.src[t.start() as usize + tlen - 1];
                if b != b' ' && b != b'\t' { break; }
                tlen = tlen - 1;
            }
        }
        out.push_bytes(unsafe (fx.src + t.start() as usize), tlen);

        // State updates.
        switch k {
            LeftBrace => { fx.brace = fx.brace + 1; fx.gdepth = 0; fx.in_closure = false; fx.in_sig = false; },
            RightBrace => { fx.brace = fx.brace - 1; fx.gdepth = 0; fx.in_closure = false; fx.in_sig = false; },
            LeftParen => { fx.paren = fx.paren + 1; },
            RightParen => {
                fx.paren = fx.paren - 1;
                if fx.in_sig && fx.paren < fx.sig_paren { fx.in_sig = false; }
            },
            LeftBracket => { fx.brack = fx.brack + 1; },
            RightBracket => { fx.brack = fx.brack - 1; },
            Semicolon => { fx.gdepth = 0; fx.in_sig = false; },
            Equal => { fx.in_sig = false; },
            Fn => { fx.in_sig = true; fx.sig_paren = fx.paren; },
            Comma => { if fx.in_sig && fx.paren == fx.sig_paren { fx.in_sig = false; } },
            _ => {},
        };
        if gclose && fx.in_sig && fx.paren == fx.sig_paren { fx.in_sig = false; } // `F: fn(&T) U>`
        if gopen { fx.gdepth = fx.gdepth + 1; }
        if gclose {
            if k == TokenType::RightShift { fx.gdepth = fx.gdepth - 2; }
            else { fx.gdepth = fx.gdepth - 1; }
            if fx.gdepth < 0 { fx.gdepth = 0; }
        }
        if pipe_open { fx.in_closure = true; }
        if pipe_close { fx.in_closure = false; }
        if !is_comment(k) {
            fx.prev_glue = gopen || pipe_open || unary
                || k == TokenType::Tilde || k == TokenType::Bang || k == TokenType::At;
            fx.prev_gclose = gclose;
            fx.prev_empty_br = k == TokenType::RightBracket && prev == TokenType::LeftBracket;
            prev = k;
        } else {
            fx.prev_glue = false; // a comment always separates
            fx.prev_gclose = false;
        }
        prev_end = t.end() as usize;
        emitted = true;
        ti = ti + 1;
    }
    if emitted { out.push_byte(b'\n'); }

    toks.free();
    s.free();
    return true;
}
