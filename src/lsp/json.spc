// JSON value + parser for the LSP: ordered key/value pair objects,
// the iterative token-dispatch parser over an explicit value stack (no recursion,
// depth-capped), SWAR quote/backslash/control scanning, run-copied string decoding with full \uXXXX
// surrogate handling, and the strict error messages. Two protocol-driven deviations in dump(): strings are re-escaped on
// output (the wire format must be valid JSON) and integral numbers print without a ".0" suffix (LSP
// positions and ids are integers).
import string as cstring;
import stdlib;

const MAX_NESTING_DEPTH: usize = 1024;

/// One ordered object member
pub struct JSONPair {
    pub key: String,
    pub value: JSON,
}

/// A JSON value. Only the active variant holds a payload, so a value is 32 bytes.
pub enum JSON {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vector<JSON>),
    Obj(Vector<JSONPair>), // members in insertion order
}

extend JSON {
    /// A boolean value.
    pub fn boolean(value: bool) JSON {
        return JSON::Bool(value);
    }

    /// A number value.
    pub fn number(value: f64) JSON {
        return JSON::Num(value);
    }

    /// An integer, stored as f64 (exact below 2^53).
    pub fn integer(value: i64) JSON {
        return JSON::Num(value as f64);
    }

    /// A string value; `value` is copied.
    pub fn str(value: str) JSON {
        return JSON::Str(String::from_str(value));
    }

    /// Takes ownership of `value` (no copy): the JSON(std::string&&) constructor.
    pub fn string(value: String) JSON {
        return JSON::Str(value);
    }

    /// An empty array.
    pub fn array() JSON {
        return JSON::Arr(Vector::<JSON>::new());
    }

    /// An empty object.
    pub fn object() JSON {
        return JSON::Obj(Vector::<JSONPair>::new());
    }

    /// Kind test.
    pub const fn is_null(self: &Self) bool {
        return switch self {
            Null => true,
            _ => false,
        };
    }

    /// Kind test.
    pub const fn is_bool(self: &Self) bool {
        return switch self {
            Bool(_) => true,
            _ => false,
        };
    }

    /// Kind test.
    pub const fn is_number(self: &Self) bool {
        return switch self {
            Num(_) => true,
            _ => false,
        };
    }

    /// Kind test.
    pub const fn is_string(self: &Self) bool {
        return switch self {
            Str(_) => true,
            _ => false,
        };
    }

    /// Kind test.
    pub const fn is_array(self: &Self) bool {
        return switch self {
            Arr(_) => true,
            _ => false,
        };
    }

    /// Kind test.
    pub const fn is_object(self: &Self) bool {
        return switch self {
            Obj(_) => true,
            _ => false,
        };
    }

    /// The boolean. Panics: not a boolean.
    pub const fn get_bool(self: &Self) bool {
        return switch self {
            Bool(b) => *b,
            _ => panic("JSON::get_bool called on a non-boolean type"),
        };
    }

    /// The number. Panics: not a number.
    pub const fn get_number(self: &Self) f64 {
        return switch self {
            Num(n) => *n,
            _ => panic("JSON::get_number called on a non-number type"),
        };
    }

    /// The number truncated to i64. Panics: not a number, or outside the i64 range (NaN included).
    pub const fn get_i64(self: &Self) i64 {
        let n = self.get_number();
        if !in_i64_range(n) {
            panic("JSON::get_i64 called on a number outside the i64 range");
        }
        return n as i64;
    }

    /// The string. Panics: not a string.
    pub const fn get_string(self: &Self) &String {
        return switch self {
            Str(s) => s,
            _ => panic("JSON::get_string called on a non-string type"),
        };
    }

    /// The string as a view. Panics: not a string.
    pub const fn get_str(self: &Self) str {
        return self.get_string().as_str();
    }

    /// Element at `index`; panics out of bounds or on a non-array (JSON::At(size_t)).
    pub const fn at(self: &Self, index: usize) &JSON {
        return switch self {
            Arr(a) => a.at(index),
            _ => panic("JSON::at on a non array-type"),
        };
    }

    /// Member for `key`; panics when missing or on a non-object (JSON::At(string)).
    pub fn at_key(self: &Self, key: str) &JSON {
        return switch self.value(key) {
            Some(v) => v,
            None => panic("JSON::at_key called with a missing key or on a non object-type"),
        };
    }

    /// Safe member lookup: None when absent or on a non-object (the JSON::Value analog, Option-shaped).
    pub fn value(self: &Self, key: str) Option<&JSON> {
        if let Obj(o) = self {
            for i in 0..o.len() {
                if o.at(i).key.as_str() == key {
                    return Option::<&JSON>::Some(&o.at(i).value);
                }
            }
        }
        return Option::<&JSON>::None;
    }

    /// True when this object has member `key` (false for non-objects).
    pub fn contains_key(self: &Self, key: str) bool {
        return self.value(key).is_some();
    }

    /// Member as integer / string view with a default: the common LSP request-field reads. A number
    /// outside the i64 range (NaN included) also yields `dflt`.
    pub fn value_i64(self: &Self, key: str, dflt: i64) i64 {
        if let Some(v) = self.value(key) {
            if let Num(n) = v {
                if in_i64_range(*n) {
                    return (*n) as i64;
                }
            }
        }
        return dflt;
    }

    /// Member `key` as a string view; empty when absent or not a string.
    pub fn value_str(self: &Self, key: str) str {
        if let Some(v) = self.value(key) {
            if let Str(s) = v {
                return s.as_str();
            }
        }
        return "";
    }

    /// Element count of an array or member count of an object. Panics: a scalar.
    pub const fn size(self: &Self) usize {
        return switch self {
            Arr(a) => a.len(),
            Obj(o) => o.len(),
            _ => panic("JSON::size called on non-array or non-object type"),
        };
    }

    /// Append to the array; a non-array converts to one first (JSON::PushBack). Owns `value`.
    pub fn push_back(self: &mut Self, value: JSON) {
        if !self.is_array() {
            *self = JSON::array();
        }
        self.items_mut().push(value);
    }

    /// Set `key` to `value`, overwriting an existing member; a non-object converts to one first
    /// (JSON::Emplace). Owns `value`.
    pub fn emplace(self: &mut Self, key: str, value: JSON) {
        if !self.is_object() {
            *self = JSON::object();
        }
        let o = self.members_mut();
        for i in 0..o.len() {
            if o.at(i).key.as_str() == key {
                o[i].value = value;
                return;
            }
        }
        o.push(JSONPair { key: String::from_str(key), value: value });
    }

    /// Deep copy
    pub fn clone(self: &Self) JSON {
        switch self {
            Arr(a) => {
                let mut c = Vector::<JSON>::with_capacity(a.len());
                for i in 0..a.len() {
                    c.push(a.at(i).clone());
                }
                return JSON::Arr(c);
            },
            Obj(o) => {
                let mut c = Vector::<JSONPair>::with_capacity(o.len());
                for i in 0..o.len() {
                    c.push(JSONPair { key: o.at(i).key.clone(), value: o.at(i).value.clone() });
                }
                return JSON::Obj(c);
            },
            Str(s) => {
                return JSON::Str(s.clone());
            },
            Num(n) => {
                return JSON::Num(*n);
            },
            Bool(b) => {
                return JSON::Bool(*b);
            },
            Null => {
                return JSON::Null;
            },
        };
    }

    /// Reserve capacity for `size` elements or members. Panics: a scalar.
    pub fn reserve(self: &mut Self, size: usize) {
        switch self {
            Arr(a) => a.reserve(size),
            Obj(o) => o.reserve(size),
            _ => panic("JSON::reserve called on non-array and non-object type"),
        };
    }

    // The array elements. Panics: not an array.
    fn items_mut(self: &mut Self) &mut Vector<JSON> {
        return switch self {
            Arr(a) => a,
            _ => panic("JSON::items_mut called on a non-array type"),
        };
    }

    // The object members. Panics: not an object.
    fn members_mut(self: &mut Self) &mut Vector<JSONPair> {
        return switch self {
            Obj(o) => o,
            _ => panic("JSON::members_mut called on a non-object type"),
        };
    }

    // Element or member count; 0 for a scalar.
    const fn count(self: &Self) usize {
        return switch self {
            Arr(a) => a.len(),
            Obj(o) => o.len(),
            _ => 0,
        };
    }

    /// Serialize compactly (JSON::Dump).
    pub fn dump(self: &Self) String {
        let mut out = String::with_capacity(256);
        self.dump_into(&mut out);
        return out;
    }

    /// Append the compact serialization to `out`.
    pub fn dump_into(self: &Self, out: &mut String) {
        switch self {
            Null => out.push_str("null"),
            Bool(true) => out.push_str("true"),
            Bool(false) => out.push_str("false"),
            Num(n) => dump_number(*n, out),
            Str(s) => dump_escaped(s.as_str(), out),
            Arr(a) => {
                out.push_byte(b'[');
                for i in 0..a.len() {
                    if i > 0 {
                        out.push_byte(b',');
                    }
                    a.at(i).dump_into(out);
                }
                out.push_byte(b']');
            },
            Obj(o) => {
                out.push_byte(b'{');
                for i in 0..o.len() {
                    if i > 0 {
                        out.push_byte(b',');
                    }
                    dump_escaped(o.at(i).key.as_str(), out);
                    out.push_byte(b':');
                    o.at(i).value.dump_into(out);
                }
                out.push_byte(b'}');
            },
        };
    }
}

extend JSON as Default {
    /// A JSON null
    pub fn default() JSON {
        return JSON::Null;
    }
}

// True when `n` truncates to an i64 without overflow (false for NaN: every comparison fails).
const fn in_i64_range(n: f64) bool {
    return n >= -9223372036854775808.0 && n < 9223372036854775808.0;
}

fn dump_number(n: f64, out: &mut String) {
    // NaN and infinity are not valid JSON: emit null so the wire format stays parseable.
    if n != n || n > 1.7976931348623157e308 || n < -1.7976931348623157e308 {
        out.push_str("null");
        return;
    }
    if n >= -9007199254740992.0 && n <= 9007199254740992.0 {
        let i = n as i64;
        if i as f64 == n {
            out.push_i64(i);
            return;
        }
    }
    out.push_f64(n);
}

/// Append `s` as a JSON string literal: quote/backslash/control bytes escaped, raw UTF-8 kept.
pub fn dump_escaped(s: str, out: &mut String) {
    out.push_byte(b'"');
    for i in 0..s.len() {
        let b = s[i];
        if b == b'"' {
            out.push_str("\\\"");
        } else if b == b'\\' {
            out.push_str("\\\\");
        } else if b == b'\n' {
            out.push_str("\\n");
        } else if b == b'\r' {
            out.push_str("\\r");
        } else if b == b'\t' {
            out.push_str("\\t");
        } else if b < 0x20 {
            out.push_str("\\u00");
            out.push_byte("0123456789abcdef"[(b >> 4) as usize]);
            out.push_byte("0123456789abcdef"[(b & 15) as usize]);
        } else {
            out.push_byte(b);
        }
    }
    out.push_byte(b'"');
}

// Parser (JSONParser's string_view path): one pass over the bytes, dispatching per token class and
// attaching values through an explicit stack of raw slots: no recursion, so nesting depth is bounded by
// MAX_NESTING_DEPTH instead of the C stack. Pointers are stored as usize (a raw *mut to a Free type is
// move-tracked); slot pointers stay stable because a parent container never grows while a child is open.

// SWAR helpers (findStringStop): scan 8 bytes at a time for a quote, backslash or control byte.
const SWAR_LO: u64 = 0x0101010101010101;
const SWAR_HI: u64 = 0x8080808080808080;

const fn has_zero_byte(v: u64) bool {
    return (v - SWAR_LO & ~v & SWAR_HI) != 0;
}

fn find_string_stop(s: str, from: usize, to: usize) usize {
    let quote_mask = SWAR_LO * 0x22;
    let slash_mask = SWAR_LO * 0x5C;
    let ctrl_mask = SWAR_LO * 0x20;
    let base = s.ptr() as usize;
    let mut p = from;
    while to - p >= 8 {
        let mut chunk: u64 = 0;
        unsafe cstring::memcpy((&mut chunk) as *mut u64, (base + p) as *const void, 8);
        let has_ctrl = (chunk - ctrl_mask & ~chunk & SWAR_HI) != 0;
        if has_zero_byte(chunk ^ quote_mask) || has_zero_byte(chunk ^ slash_mask) || has_ctrl {
            break;
        }
        p += 8;
    }
    while p < to {
        let c = s[p];
        if c == b'"' || c == b'\\' || c <= 0x1F {
            break;
        }
        p += 1;
    }
    return p;
}

const fn is_number_byte(b: u8) bool {
    return b >= b'0' && b <= b'9' || b == b'e' || b == b'E' || b == b'-' || b == b'+' || b == b'.';
}

const fn is_ws(b: u8) bool {
    return b == b' ' || b == b'\t' || b == b'\r' || b == b'\n';
}

struct JSONParser<'a> {
    pub src: str<'a>,
    pub stack: Vector<usize>, // *mut JSON slots as usize
    pub pending_key: String, // the key waiting to be assigned
    pub candidate_key: String, // a parsed string that may become a key at the next ':'
    pub candidate_key_set: bool,
    pub pending_key_set: bool,
    pub comma_detected: bool,
    pub found_data: bool,
    pub depth: usize,
    pub err: String, // first error message; empty = no error so far
}

extend JSONParser {
    fn fail(self: &mut Self, msg: str) {
        if self.err.len() == 0 {
            self.err.push_str(msg);
        }
    }

    const fn fail_s(self: &mut Self, msg: String) {
        if self.err.len() == 0 {
            self.err = msg;
        }
    }

    fn take_err(self: &mut Self) String {
        let e = replace(&mut self.err, String::new());
        return e;
    }

    fn unexpected(self: &mut Self, c: u8) {
        if c == 0 {
            self.fail("Unexpected character '\\0'");
            return;
        }
        let mut m = String::from_str("Unexpected character '");
        m.push_byte(c);
        m.push_byte(b'\'');
        self.fail_s(m);
    }

    fn eof_junk(self: &mut Self, c: u8) {
        if c == 0 {
            self.fail("Unexpected null byte after JSON end");
            return;
        }
        let mut m = String::from_str("Unexpected character '");
        m.push_byte(c);
        m.push_str("' after JSON end");
        self.fail_s(m);
    }

    const fn top(self: &Self) usize {
        return *self.stack.at(self.stack.len() - 1);
    }

    // Attach `json` under the pending key of the open object; returns the inserted value's slot (as
    // usize), 0 on error. The slot stays valid while it is the open top of stack: nothing is appended to
    // this object until the child closes.
    fn set_object_value(self: &mut Self, json: JSON) usize {
        let o = unsafe (*(self.top() as *mut JSON)).members_mut();
        if !self.comma_detected && o.len() != 0 {
            self.fail("Missing ',' between object members");
            return 0;
        }
        if !self.pending_key_set {
            self.fail("Expected a key before adding an inner value");
            return 0;
        }
        let k = replace(&mut self.pending_key, String::new());
        self.candidate_key.clear();
        o.push(JSONPair { key: k, value: json });
        self.pending_key_set = false;
        self.comma_detected = false;
        let idx = o.len() - 1;
        return ((&mut o[idx].value) as *mut JSON) as usize;
    }

    // Append `json` to the open array and return its slot (as usize), 0 on a comma error (which frees
    // `json`). The slot stays valid while it is the open top of stack.
    fn set_array_value(self: &mut Self, json: JSON) usize {
        let a = unsafe (*(self.top() as *mut JSON)).items_mut();
        if !self.comma_detected && a.len() != 0 {
            self.fail("Missing ',' between array members");
            return 0;
        }
        a.push(json);
        self.comma_detected = false;
        let idx = a.len() - 1;
        return ((&mut a[idx]) as *mut JSON) as usize;
    }

    // Decode the escaped content between src[from..to] (exclusive of the quotes): copy backslash-free
    // runs whole (memchr), decode escapes incl. \uXXXX with strict surrogate-pair validation.
    fn parse_raw_string(self: &mut Self, from: usize, to: usize) String {
        let mut out = String::with_capacity(to - from);
        let base = self.src.ptr() as usize;
        let mut p = from;
        while p < to {
            let hit = unsafe cstring::memchr((base + p) as *const void, 92, to - p);
            let mut stop = to;
            if hit != null {
                stop = hit as usize - base;
            }
            if stop > p {
                out.push_bytes((base + p) as *const u8, stop - p);
            }
            p = stop;
            if p >= to {
                break;
            }
            // The backslash.
            p += 1;
            if p >= to {
                self.fail("Unterminated escape sequence");
                return out;
            }
            let e = self.src[p];
            if e == b'"' || e == b'\\' || e == b'/' {
                out.push_byte(e);
                p += 1;
            } else if e == b'b' {
                out.push_byte(8);
                p += 1;
            } else if e == b'f' {
                out.push_byte(12);
                p += 1;
            } else if e == b'n' {
                out.push_byte(b'\n');
                p += 1;
            } else if e == b'r' {
                out.push_byte(b'\r');
                p += 1;
            } else if e == b't' {
                out.push_byte(b'\t');
                p += 1;
            } else if e == b'u' {
                p += 1;
                if to - p < 4 {
                    self.fail("Incomplete unicode escape");
                    return out;
                }
                let first = self.parse_hex4(p);
                p += 4;
                if self.err.len() != 0 {
                    return out;
                }
                let mut code = first;
                if first >= 0xD800 && first <= 0xDBFF {
                    if to - p < 6 {
                        self.fail("Unexpected end of input: missing low surrogate after high surrogate (\\uXXXX)");
                        return out;
                    }
                    if self.src[p] != b'\\' || self.src[p + 1] != b'u' {
                        self.fail_s(format("Expected '\\u' after high surrogate, found '{}'", self.src.slice(p, p + 2)));
                        return out;
                    }
                    p += 2;
                    let second = self.parse_hex4(p);
                    p += 4;
                    if self.err.len() != 0 {
                        return out;
                    }
                    if second < 0xDC00 || second > 0xDFFF {
                        self.fail_s(
                            format(
                                "Invalid low surrogate: expected value in range \\uDC00..\\uDFFF, got \\u{:04X}",
                                second,
                            ),
                        );
                        return out;
                    }
                    code = 0x10000 + (first - 0xD800 << 10 | second - 0xDC00);
                } else if first >= 0xDC00 && first <= 0xDFFF {
                    self.fail_s(format("Unexpected low surrogate \\u{:04X} without preceding high surrogate", first));
                    return out;
                }
                // UTF-8 encode (String::push replaces the manual encoder).
                out.push(code);
            } else {
                self.fail("Invalid escape sequence");
                return out;
            }
        }
        return out;
    }

    fn parse_hex4(self: &mut Self, at: usize) u32 {
        let mut code: u32 = 0;
        for k in 0..4 as usize {
            let c = self.src[at + k];
            code = code << 4;
            if c >= b'0' && c <= b'9' {
                code = code | (c - b'0') as u32;
            } else if c >= b'a' && c <= b'f' {
                code = code | (c - b'a') as u32 + 10;
            } else if c >= b'A' && c <= b'F' {
                code = code | (c - b'A') as u32 + 10;
            } else {
                self.fail("Invalid hex digit in \\uXXXX");
                return 0;
            }
        }
        return code;
    }

    // Validate the number in src[from..to] against the JSON grammar, then convert it with strtod: the
    // value is correctly rounded, and an exponent past the f64 range saturates to infinity or zero at
    // a cost linear in the digit count.
    fn parse_number(self: &mut Self, from: usize, to: usize) f64 {
        let mut p = from;
        if self.src[p] == b'-' {
            p += 1;
        }
        if p == to {
            self.fail("Invalid number: digit expected after '-'");
            return 0.0;
        }
        let b0 = self.src[p];
        if b0 == b'0' {
            p += 1;
            if p < to && self.src[p] >= b'0' && self.src[p] <= b'9' {
                self.fail("Invalid number: Leading zeros are not allowed");
                return 0.0;
            }
        } else if b0 >= b'1' && b0 <= b'9' {
            while p < to && self.src[p] >= b'0' && self.src[p] <= b'9' {
                p += 1;
            }
        } else {
            self.fail("Invalid number: digit expected after '-'");
            return 0.0;
        }
        if p < to && self.src[p] == b'.' {
            p += 1;
            if p == to || self.src[p] < b'0' || self.src[p] > b'9' {
                self.fail("Invalid number: digit expected after '.'");
                return 0.0;
            }
            while p < to && self.src[p] >= b'0' && self.src[p] <= b'9' {
                p += 1;
            }
        }
        if p < to && (self.src[p] == b'e' || self.src[p] == b'E') {
            p += 1;
            if p < to && (self.src[p] == b'+' || self.src[p] == b'-') {
                p += 1;
            }
            if p == to || self.src[p] < b'0' || self.src[p] > b'9' {
                self.fail("Invalid number: digit expected after exponent");
                return 0.0;
            }
            while p < to && self.src[p] >= b'0' && self.src[p] <= b'9' {
                p += 1;
            }
        }
        if p != to {
            self.fail("Invalid character in number");
            return 0.0;
        }
        let mut text = String::from_str(self.src.slice(from, to));
        return unsafe stdlib::strtod(text.cstr(), null);
    }

    // The parseBuffer main loop over the whole (in-memory) input; returns the consumed byte count.
    fn parse_buffer(self: &mut Self) usize {
        let n = self.src.len();
        let mut i: usize = 0;
        while i < n {
            if self.err.len() != 0 {
                return i;
            }
            let c = self.src[i];
            if is_ws(c) {
                // Skip.
            } else if c == b'{' {
                self.depth += 1;
                if self.depth > MAX_NESTING_DEPTH {
                    self.fail("Nesting depth limit exceeded");
                    return i;
                }
                let t = self.top() as *mut JSON;
                let child = JSON::Obj(Vector::<JSONPair>::with_capacity(8));
                if unsafe (*t).is_object() {
                    let slot = self.set_object_value(child);
                    if slot == 0 {
                        return i;
                    }
                    self.stack.push(slot);
                } else if unsafe (*t).is_array() {
                    let slot = self.set_array_value(child);
                    if slot == 0 {
                        return i;
                    }
                    self.stack.push(slot);
                } else if self.stack.len() == 1 {
                    unsafe *t = child;
                }
                self.found_data = true;
            } else if c == b'}' {
                let t = self.top() as *mut JSON;
                if unsafe (*t).is_object() {
                    if self.pending_key_set {
                        self.fail_s(format("Missing value for key '{}' in object", self.pending_key.as_str()));
                        return i;
                    }
                    if self.candidate_key_set {
                        self.fail("Missing a colon after a key");
                        return i;
                    }
                    if self.comma_detected && unsafe (*t).count() != 0 {
                        self.fail("Trailing ',' before closing '}'");
                        return i;
                    }
                    self.depth -= 1;
                    self.stack.pop();
                    if self.stack.len() == 0 {
                        return i + 1;
                    }
                } else if unsafe (*t).is_array() {
                    self.fail("Expected ']' but found '}'");
                    return i;
                } else {
                    self.fail("Unexpected '}'");
                    return i;
                }
                self.found_data = true;
            } else if c == b'[' {
                self.depth += 1;
                if self.depth > MAX_NESTING_DEPTH {
                    self.fail("Nesting depth limit exceeded");
                    return i;
                }
                let t = self.top() as *mut JSON;
                if unsafe (*t).is_object() {
                    let slot = self.set_object_value(JSON::Arr(Vector::<JSON>::with_capacity(8)));
                    if slot == 0 {
                        return i;
                    }
                    self.stack.push(slot);
                } else if unsafe (*t).is_array() {
                    let slot = self.set_array_value(JSON::Arr(Vector::<JSON>::with_capacity(8)));
                    if slot == 0 {
                        return i;
                    }
                    self.stack.push(slot);
                } else if self.stack.len() == 1 {
                    // Root arrays reserve by input size (max(16, n/512)) like the original.
                    let mut cap: usize = 16;
                    if n / 512 > cap {
                        cap = n / 512;
                    }
                    unsafe *t = JSON::Arr(Vector::<JSON>::with_capacity(cap));
                }
                self.found_data = true;
            } else if c == b']' {
                let t = self.top() as *mut JSON;
                if unsafe (*t).is_array() {
                    if self.comma_detected && unsafe (*t).count() != 0 {
                        self.fail("Trailing ',' before closing ']'");
                        return i;
                    }
                    self.depth -= 1;
                    self.stack.pop();
                    if self.stack.len() == 0 {
                        return i + 1;
                    }
                } else if unsafe (*t).is_object() {
                    self.fail("Expected '}' but found ']'");
                    return i;
                } else {
                    self.fail("Unexpected ']'");
                    return i;
                }
                self.found_data = true;
            } else if c == b':' {
                if unsafe (*(self.top() as *mut JSON)).is_array() {
                    self.fail("Unexpected ':' in an array, did you mean ','?");
                    return i;
                }
                if !self.candidate_key_set {
                    self.fail("Expected a string key before ':'");
                    return i;
                }
                self.pending_key = replace(&mut self.candidate_key, String::new());
                self.pending_key_set = true;
                self.candidate_key_set = false;
                self.found_data = true;
            } else if c == b',' {
                // A comma is valid only right after a complete member of a non-empty container.
                if self.pending_key_set {
                    self.fail_s(format("Missing value for key '{}' in object", self.pending_key.as_str()));
                    return i;
                }
                if self.candidate_key_set {
                    self.fail("Missing a colon after a key");
                    return i;
                }
                if self.comma_detected {
                    self.fail("Duplicate ','");
                    return i;
                }
                // The open container holds no member yet, or no container is open.
                if unsafe (*(self.top() as *mut JSON)).count() == 0 {
                    self.fail("Unexpected ','");
                    return i;
                }
                self.comma_detected = true;
                self.found_data = true;
            } else if c == b'"' {
                let mut q = i + 1;
                let mut needs_decode = false;
                let mut done = false;
                while q < n {
                    q = find_string_stop(self.src, q, n);
                    if q >= n {
                        break;
                    }
                    let cq = self.src[q];
                    if cq == b'"' {
                        let mut text = String::new();
                        if needs_decode {
                            text = self.parse_raw_string(i + 1, q);
                            if self.err.len() != 0 {
                                return i;
                            }
                        } else {
                            text = String::from_str(self.src.slice(i + 1, q));
                        }
                        self.found_data = true;
                        let t = self.top() as *mut JSON;
                        if unsafe (*t).is_object() {
                            if !self.pending_key_set {
                                if !self.candidate_key_set {
                                    self.candidate_key = text;
                                    self.candidate_key_set = true;
                                } else {
                                    self.fail("Missing a colon after a key");
                                    return i;
                                }
                            } else {
                                self.set_object_value(JSON::string(text));
                            }
                        } else if unsafe (*t).is_array() {
                            self.set_array_value(JSON::string(text));
                        } else if self.stack.len() == 1 {
                            unsafe *t = JSON::string(text);
                            self.stack.pop();
                            return q + 1;
                        }

                        i = q;
                        done = true;
                        break;
                    }
                    if cq <= 0x1F {
                        self.fail("Control character in string");
                        return i;
                    }
                    if cq == b'\\' {
                        needs_decode = true;
                        if q + 1 < n {
                            q += 2;
                        } else {
                            q += 1;
                        }
                        continue;
                    }
                    q += 1;
                }
                if !done {
                    self.fail("Unterminated string");
                    return i;
                }
            } else if c == b'-' || c >= b'0' && c <= b'9' {
                let t = self.top() as *mut JSON;
                if unsafe (*t).is_object() && !self.pending_key_set {
                    self.fail("Expected a key before adding a number");
                    return i;
                }
                let mut q = i + 1;
                while q < n && is_number_byte(self.src[q]) {
                    q += 1;
                }
                let num = self.parse_number(i, q);
                if self.err.len() != 0 {
                    return i;
                }
                self.found_data = true;
                if unsafe (*t).is_object() {
                    self.set_object_value(JSON::number(num));
                } else if unsafe (*t).is_array() {
                    self.set_array_value(JSON::number(num));
                } else if self.stack.len() == 1 {
                    unsafe *t = JSON::number(num);
                    self.stack.pop();
                    return q;
                }
                i = q - 1;
            } else if c == b't' || c == b'f' || c == b'n' {
                let t = self.top() as *mut JSON;
                if unsafe (*t).is_object() && !self.pending_key_set {
                    self.fail("Expected a key before adding a boolean or null value");
                    return i;
                }
                let mut lit = "null";
                if c == b't' {
                    lit = "true";
                } else if c == b'f' {
                    lit = "false";
                }
                if i + lit.len() > n {
                    self.unexpected(self.src[n - 1]);
                    return i;
                }
                for k in 0..lit.len() {
                    if self.src[i + k] != lit[k] {
                        self.unexpected(self.src[i + k]);
                        return i;
                    }
                }
                let mut val = JSON::default();
                if c == b't' {
                    val = JSON::boolean(true);
                } else if c == b'f' {
                    val = JSON::boolean(false);
                }
                self.found_data = true;
                if unsafe (*t).is_object() {
                    self.set_object_value(val);
                } else if unsafe (*t).is_array() {
                    self.set_array_value(val);
                } else if self.stack.len() == 1 {
                    unsafe *t = val;
                    return i + lit.len();
                }
                i += lit.len() - 1;
            } else {
                self.unexpected(c);
                return i;
            }
            i += 1;
        }
        return i;
    }
}

/// Parse one JSON document from memory (JSONParser::Parse, string_view path). The whole input must be
/// one value plus optional trailing whitespace.
pub fn parse(src: str) Result<JSON, String> {
    let mut root = JSON::default();
    let mut p = JSONParser {
        src: src,
        stack: Vector::<usize>::new(),
        pending_key: String::new(),
        candidate_key: String::new(),
        candidate_key_set: false,
        pending_key_set: false,
        comma_detected: true,
        found_data: false,
        depth: 0,
        err: String::new(),
    };
    p.stack.push(((&mut root) as *mut JSON) as usize);
    let consumed = p.parse_buffer();
    if p.err.len() != 0 {
        return Result::<JSON, String>::Err(p.take_err());
    }
    if !p.found_data {
        return Result::<JSON, String>::Err(String::from_str("Empty input is not valid JSON"));
    }
    if p.stack.len() != 0 {
        let t = p.top() as *mut JSON;
        if unsafe (*t).is_object() {
            return Result::<JSON, String>::Err(String::from_str("Missing closing '}' for object"));
        }
        if unsafe (*t).is_array() {
            return Result::<JSON, String>::Err(String::from_str("Missing closing ']' for array"));
        }
    }
    let mut tail = consumed;
    while tail < src.len() && is_ws(src[tail]) {
        tail += 1;
    }
    if tail < src.len() {
        p.eof_junk(src[tail]);
        return Result::<JSON, String>::Err(p.take_err());
    }
    return Result::<JSON, String>::Ok(root);
}
