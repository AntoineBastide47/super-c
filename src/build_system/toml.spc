// TOML-subset parser for build.toml. Deliberately small: `key = value` pairs, `[section]` /
// `[section.name]` headers, `#` comments. Values: "strings" (\" \\ \n \t \r escapes), integers,
// booleans, [arrays of strings] (multiline ok, trailing comma ok), and { inline = "tables" } of
// string values. No floats, dates, multiline strings, nested arrays, or arrays of tables -- the
// manifest schema needs none of them and full TOML is not a goal.
import utils::errors as diag;

pub const TV_STR: u8 = 0;
pub const TV_INT: u8 = 1;
pub const TV_BOOL: u8 = 2;
pub const TV_ARR: u8 = 3;
pub const TV_TBL: u8 = 4;

pub struct TomlPair {
    pub k: String,
    pub v: String,
}

extend TomlPair as Free {
    pub fn free(self: &mut Self) {
        self.k.free();
        self.v.free();
    }
}

/// A parsed value tagged by `kind` (TV_*): only the matching payload field is meaningful, the rest
/// keep their empty defaults.
pub struct TomlVal {
    pub kind: u8,
    pub s: String,
    pub i: i64,
    pub b: bool,
    pub arr: Vector<String>,
    pub tbl: Vector<TomlPair>,
}

extend TomlVal {
    fn empty(kind: u8) TomlVal {
        return TomlVal {
            kind: kind,
            s: String::new(),
            i: 0,
            b: false,
            arr: Vector::<String>::new(),
            tbl: Vector::<TomlPair>::new(),
        };
    }
}

extend TomlVal as Free {
    pub fn free(self: &mut Self) {
        self.s.free();
        self.arr.free();
        self.tbl.free();
    }
}

/// One `key = value` under its (possibly empty) section; `at` is the key's byte offset for diagnostics.
pub struct TomlItem {
    pub section: String,
    pub key: String,
    pub at: u32,
    pub val: TomlVal,
}

extend TomlItem as Free {
    pub fn free(self: &mut Self) {
        self.section.free();
        self.key.free();
        self.val.free();
    }
}

struct Parser<'a> {
    pub src: str<'a>,
    pub i: usize,
    pub section: String,
    pub items: Vector<TomlItem>,
    pub errors: diag::Errors,
}

extend Parser as Free {
    pub fn free(self: &mut Self) {
        self.section.free();
        self.items.free();
        self.errors.free();
    }
}

const fn is_key_byte(b: u8) bool {
    return b >= b'a' && b <= b'z' || b >= b'A' && b <= b'Z' || b >= b'0' && b <= b'9' || b == b'-' || b == b'_' || b == b'.';
}

extend Parser {
    const fn at_end(self: &Self) bool {
        return self.i >= self.src.len();
    }

    const fn peek(self: &Self) u8 {
        if self.at_end() {
            return 0;
        }
        return self.src[self.i];
    }

    // Skip spaces, tabs and comments; newlines too when `nl` is set.
    fn skip_ws(self: &mut Self, nl: bool) {
        while !self.at_end() {
            let b = self.peek();
            if b == b' ' || b == b'\t' || b == b'\r' {
                self.i = self.i + 1;
            } else if nl && b == b'\n' {
                self.i = self.i + 1;
            } else if b == b'#' {
                while !self.at_end() && self.peek() != b'\n' {
                    self.i = self.i + 1;
                }
            } else {
                break;
            }
        }
    }

    fn err(self: &mut Self, at: usize, msg: String) {
        self.errors.emit(at as u32, 1, msg);
        // resync to the next line so one typo yields one diagnostic
        while !self.at_end() && self.peek() != b'\n' {
            self.i = self.i + 1;
        }
    }

    fn parse_key(self: &mut Self) String {
        let start = self.i;
        while !self.at_end() && is_key_byte(self.peek()) {
            self.i = self.i + 1;
        }
        return String::from_str(self.src.slice(start, self.i));
    }

    fn parse_string(self: &mut Self) Option<String> {
        let q = self.i;
        self.i = self.i + 1; // opening quote
        let mut out = String::new();
        while !self.at_end() {
            let b = self.peek();
            if b == b'"' {
                self.i = self.i + 1;
                return Option::<String>::Some(out);
            }
            if b == b'\n' {
                break;
            }
            if b == b'\\' {
                self.i = self.i + 1;
                let e = self.peek();
                if e == b'n' {
                    out.push_byte(b'\n');
                } else if e == b't' {
                    out.push_byte(b'\t');
                } else if e == b'r' {
                    out.push_byte(b'\r');
                } else if e == b'"' || e == b'\\' {
                    out.push_byte(e);
                } else {
                    self.err(self.i, format("unknown escape in string"));
                    return Option::<String>::None;
                }
                self.i = self.i + 1;
            } else {
                out.push_byte(b);
                self.i = self.i + 1;
            }
        }
        self.err(q, format("unterminated string"));
        return Option::<String>::None;
    }

    fn parse_value(self: &mut Self) Option<TomlVal> {
        self.skip_ws(false);
        let b = self.peek();
        if b == b'"' {
            let s = self.parse_string();
            if s.is_none() {
                return Option::<TomlVal>::None;
            }
            let mut v = TomlVal::empty(TV_STR);
            v.s = s.unwrap();
            return Option::<TomlVal>::Some(v);
        }
        if b == b'[' {
            self.i = self.i + 1;
            let mut v = TomlVal::empty(TV_ARR);
            loop {
                self.skip_ws(true);
                if self.peek() == b']' {
                    self.i = self.i + 1;
                    return Option::<TomlVal>::Some(v);
                }
                if self.peek() != b'"' {
                    self.err(self.i, format("arrays may only contain strings"));
                    return Option::<TomlVal>::None;
                }
                let s = self.parse_string();
                if s.is_none() {
                    return Option::<TomlVal>::None;
                }
                v.arr.push(s.unwrap());
                self.skip_ws(true);
                if self.peek() == b',' {
                    self.i = self.i + 1;
                } else if self.peek() != b']' {
                    self.err(self.i, format("expected ',' or ']' in array"));
                    return Option::<TomlVal>::None;
                }
            }
        }
        if b == b'{' {
            self.i = self.i + 1;
            let mut v = TomlVal::empty(TV_TBL);
            loop {
                self.skip_ws(false);
                if self.peek() == b'}' {
                    self.i = self.i + 1;
                    return Option::<TomlVal>::Some(v);
                }
                let k = self.parse_key();
                if k.len() == 0 {
                    self.err(self.i, format("expected key in inline table"));
                    return Option::<TomlVal>::None;
                }
                self.skip_ws(false);
                if self.peek() != b'=' {
                    self.err(self.i, format("expected '=' in inline table"));
                    return Option::<TomlVal>::None;
                }
                self.i = self.i + 1;
                self.skip_ws(false);
                if self.peek() != b'"' {
                    self.err(self.i, format("inline tables may only contain string values"));
                    return Option::<TomlVal>::None;
                }
                let s = self.parse_string();
                if s.is_none() {
                    return Option::<TomlVal>::None;
                }
                v.tbl.push(TomlPair { k: k, v: s.unwrap() });
                self.skip_ws(false);
                if self.peek() == b',' {
                    self.i = self.i + 1;
                } else if self.peek() != b'}' {
                    self.err(self.i, format("expected ',' or '}}' in inline table"));
                    return Option::<TomlVal>::None;
                }
            }
        }
        if b == b't' || b == b'f' {
            let k = self.parse_key();
            let is_true = k.as_str() == "true";
            let ok = is_true || k.as_str() == "false";
            if ok {
                let mut v = TomlVal::empty(TV_BOOL);
                v.b = is_true;
                return Option::<TomlVal>::Some(v);
            }
            self.err(self.i, format("expected value"));
            return Option::<TomlVal>::None;
        }
        if b == b'-' || b >= b'0' && b <= b'9' {
            let neg = b == b'-';
            if neg {
                self.i = self.i + 1;
            }
            let ds = self.i;
            let mut n: i64 = 0;
            while !self.at_end() && self.peek() >= b'0' && self.peek() <= b'9' {
                n = n * 10 + (self.peek() - b'0') as i64;
                self.i = self.i + 1;
            }
            if self.i == ds {
                self.err(self.i, format("expected digits"));
                return Option::<TomlVal>::None;
            }
            let mut v = TomlVal::empty(TV_INT);
            v.i = if neg {
                -n;
            } else {
                n;
            };
            return Option::<TomlVal>::Some(v);
        }
        self.err(self.i, format("expected value"));
        return Option::<TomlVal>::None;
    }

    fn parse_line(self: &mut Self) {
        if self.peek() == b'[' {
            let at = self.i;
            self.i = self.i + 1;
            let name = self.parse_key();
            if name.len() == 0 || self.peek() != b']' {
                self.err(at, format("malformed section header"));
                return;
            }
            self.i = self.i + 1;
            self.section = name;
            // a bare header is still a fact (an empty [lib] means "this project has a library"):
            // record it as a keyless item so the schema can see section PRESENCE
            self.items.push(
                TomlItem {
                    section: self.section.clone(),
                    key: String::new(),
                    at: at as u32,
                    val: TomlVal::empty(TV_BOOL),
                },
            );
            return;
        }
        let at = self.i;
        let key = self.parse_key();
        if key.len() == 0 {
            self.err(at, format("expected key"));
            return;
        }
        self.skip_ws(false);
        if self.peek() != b'=' {
            self.err(self.i, format("expected '=' after key"));
            return;
        }
        self.i = self.i + 1;
        let val = self.parse_value();
        if val.is_none() {
            return;
        }
        self.items.push(TomlItem { section: self.section.clone(), key: key, at: at as u32, val: val.unwrap() });
        // nothing else may follow the value on the line
        self.skip_ws(false);
        if !self.at_end() && self.peek() != b'\n' {
            self.err(self.i, format("unexpected trailing characters"));
        }
    }
}

/// Parse `src` into items in file order; diagnostics (if any) are rendered against `file` and printed
/// here. None on any error (one per offending line -- the parser resyncs at newlines).
/// Parse into `errs` instead of reporting: the caller decides what to do with the diagnostics (the
/// build logs them, the language server turns them into editor squiggles). Spans stay raw -- `finalize`
/// is the step that rewrites messages into rendered blocks, and an editor wants them unrendered.
pub fn parse_into(src: str, errs: &mut diag::Errors) Option<Vector<TomlItem>> {
    let mut p = Parser {
        src: src,
        i: 0,
        section: String::new(),
        items: Vector::<TomlItem>::new(),
        errors: diag::Errors::new(),
    };
    loop {
        p.skip_ws(true);
        if p.at_end() {
            break;
        }
        p.parse_line();
    }
    let bad = p.errors.has_errors();
    for i in 0..p.errors.errors.len() {
        errs.emit(p.errors.starts[i], p.errors.lens[i], p.errors.errors.at(i).clone());
    }
    if bad {
        return Option::<Vector<TomlItem>>::None;
    }
    return Option::<Vector<TomlItem>>::Some(replace(&mut p.items, Vector::<TomlItem>::new()));
}

pub fn parse(src: str, file: str) Option<Vector<TomlItem>> {
    let mut errs = diag::Errors::new();
    let r = parse_into(src, &mut errs);
    if errs.has_errors() {
        errs.finalize(src, file);
        errs.log();
    }
    return r;
}
