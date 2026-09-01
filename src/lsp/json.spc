// JSON value + parser for the LSP: a Super-C port of the author's C++ Serde::JSON / Serde::JSONParser
// library (JSON.hpp/cpp + JsonParser.hpp/cpp), on existing std types. Kept from the original: ordered
// key/value pair objects, the iterative token-dispatch parser over an explicit value stack (no recursion,
// depth-capped), SWAR quote/backslash/control scanning, run-copied string decoding with full \uXXXX
// surrogate handling, and the strict error messages. Adapted: exceptions become Result<JSON, String>,
// GetX() type mismatches panic, and only the in-memory (string_view) parse path is ported -- the LSP reads
// whole Content-Length-framed bodies. Two protocol-driven deviations in dump(): strings are re-escaped on
// output (the wire format must be valid JSON) and integral numbers print without a ".0" suffix (LSP
// positions and ids are integers).
import string as cstring;

pub const JT_NULL: u8 = 0;
pub const JT_BOOL: u8 = 1;
pub const JT_NUMBER: u8 = 2;
pub const JT_STRING: u8 = 3;
pub const JT_ARRAY: u8 = 4;
pub const JT_OBJECT: u8 = 5;

const MAX_NESTING_DEPTH: usize = 1024;

/// One ordered object member (the C++ JSONObject is a vector of pairs, not a map: order preserved).
pub struct JSONPair {
    pub key: String,
    pub value: JSON,
}

extend JSONPair as Free {
    pub fn free(self: &mut Self) {
        self.key.free();
        self.value.free();
    }
}

/// A JSON value tagged by `kind`; only the payload matching `kind` is meaningful, the rest stay empty.
pub struct JSON {
    pub kind: u8,
    pub b: bool,
    pub num: f64,
    pub s: String,
    pub arr: Vector<JSON>, // JT_ARRAY elements
    pub obj: Vector<JSONPair>, // JT_OBJECT members, insertion order
}

extend JSON {
    fn make(kind: u8) JSON {
        return JSON {
            kind: kind,
            b: false,
            num: 0.0,
            s: String::new(),
            arr: Vector::<JSON>::new(),
            obj: Vector::<JSONPair>::new(),
        };
    }

    pub fn boolean(value: bool) JSON {
        let mut j = JSON::make(JT_BOOL);
        j.b = value;
        return j;
    }

    pub fn number(value: f64) JSON {
        let mut j = JSON::make(JT_NUMBER);
        j.num = value;
        return j;
    }

    pub fn integer(value: i64) JSON {
        return JSON::number(value as f64);
    }

    pub fn str(value: str) JSON {
        let mut j = JSON::make(JT_STRING);
        j.s = String::from_str(value);
        return j;
    }

    /// Takes ownership of `value` (no copy) -- the JSON(std::string&&) constructor.
    pub fn string(value: String) JSON {
        let mut j = JSON::make(JT_STRING);
        j.s = value;
        return j;
    }

    pub fn array() JSON {
        return JSON::make(JT_ARRAY);
    }

    pub fn object() JSON {
        return JSON::make(JT_OBJECT);
    }

    pub const fn is_null(self: &Self) bool {
        return self.kind == JT_NULL;
    }

    pub const fn is_bool(self: &Self) bool {
        return self.kind == JT_BOOL;
    }

    pub const fn is_array(self: &Self) bool {
        return self.kind == JT_ARRAY;
    }

    pub const fn is_object(self: &Self) bool {
        return self.kind == JT_OBJECT;
    }

    // Checked accessors: the C++ GetX() throw std::logic_error on a type mismatch; here they panic.
    pub const fn get_bool(self: &Self) bool {
        if self.kind != JT_BOOL {
            panic("JSON::get_bool called on a non-boolean type");
        }
        return self.b;
    }

    pub const fn get_number(self: &Self) f64 {
        if self.kind != JT_NUMBER {
            panic("JSON::get_number called on a non-number type");
        }
        return self.num;
    }

    pub const fn get_i64(self: &Self) i64 {
        return self.get_number() as i64;
    }

    pub const fn get_string(self: &Self) &String {
        if self.kind != JT_STRING {
            panic("JSON::get_string called on a non-string type");
        }
        return &self.s;
    }

    pub const fn get_str(self: &Self) str {
        return self.get_string().as_str();
    }

    /// Element at `index`; panics out of bounds or on a non-array (JSON::At(size_t)).
    pub const fn at(self: &Self, index: usize) &JSON {
        if self.kind != JT_ARRAY {
            panic("JSON::at on a non array-type");
        }
        return self.arr.at(index);
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
        if self.kind == JT_OBJECT {
            for i in 0..self.obj.len() {
                if self.obj.at(i).key.as_str() == key {
                    return Option::<&JSON>::Some(&self.obj.at(i).value);
                }
            }
        }
        return Option::<&JSON>::None;
    }

    pub fn contains_key(self: &Self, key: str) bool {
        return self.value(key).is_some();
    }

    // Member as integer / string view with a default -- the common LSP request-field reads.
    pub fn value_i64(self: &Self, key: str, dflt: i64) i64 {
        return switch self.value(key) {
            Some(v) => switch v.kind == JT_NUMBER {
                true => v.num as i64,
                false => dflt,
            },
            None => dflt,
        };
    }

    pub fn value_str(self: &Self, key: str) str {
        return switch self.value(key) {
            Some(v) => switch v.kind == JT_STRING {
                true => v.s.as_str(),
                false => "",
            },
            None => "",
        };
    }

    pub const fn size(self: &Self) usize {
        if self.kind == JT_ARRAY {
            return self.arr.len();
        }
        if self.kind == JT_OBJECT {
            return self.obj.len();
        }
        panic("JSON::size called on non-array or non-object type");
    }

    // Become an empty value of `kind` (the variant reassignment in C++). Assigning over a field frees what
    // it held, so the three stores below are the release as well as the reset.
    fn reset_to(self: &mut Self, kind: u8) {
        self.s = String::new();
        self.arr = Vector::<JSON>::new();
        self.obj = Vector::<JSONPair>::new();
        self.kind = kind;
    }

    /// Append to the array; a non-array converts to one first (JSON::PushBack). Owns `value`.
    pub fn push_back(self: &mut Self, value: JSON) {
        if self.kind != JT_ARRAY {
            self.reset_to(JT_ARRAY);
        }
        self.arr.push(value);
    }

    /// Set `key` to `value`, overwriting an existing member; a non-object converts to one first
    /// (JSON::Emplace). Owns `value`.
    pub fn emplace(self: &mut Self, key: str, value: JSON) {
        if self.kind != JT_OBJECT {
            self.reset_to(JT_OBJECT);
        }
        for i in 0..self.obj.len() {
            if self.obj.at(i).key.as_str() == key {
                self.obj[i].value = value;
                return;
            }
        }
        self.obj.push(JSONPair { key: String::from_str(key), value: value });
    }

    /// Deep copy (the C++ copy constructor).
    pub fn clone(self: &Self) JSON {
        let mut j = JSON::make(self.kind);
        j.b = self.b;
        j.num = self.num;
        j.s = self.s.clone();
        for i in 0..self.arr.len() {
            j.arr.push(self.arr.at(i).clone());
        }
        for i in 0..self.obj.len() {
            j.obj.push(JSONPair { key: self.obj.at(i).key.clone(), value: self.obj.at(i).value.clone() });
        }
        return j;
    }

    pub fn reserve(self: &mut Self, size: usize) {
        if self.kind == JT_ARRAY {
            self.arr.reserve(size);
        } else if self.kind == JT_OBJECT {
            self.obj.reserve(size);
        } else {
            panic("JSON::reserve called on non-array and non-object type");
        }
    }

    /// Serialize; `pretty` indents by two spaces per level (JSON::Dump). Unlike the C++ original this
    /// re-escapes string content (required for a valid wire format) and prints integral numbers without
    /// the ".0" suffix (LSP ids/positions are integers).
    pub fn dump(self: &Self, pretty: bool) String {
        let mut out = String::with_capacity(256);
        self.dump_into(&mut out, pretty, 0);
        return out;
    }

    fn dump_into(self: &Self, out: &mut String, pretty: bool, indent: u32) {
        if self.kind == JT_NULL {
            out.push_str("null");
        } else if self.kind == JT_BOOL {
            if self.b {
                out.push_str("true");
            } else {
                out.push_str("false");
            }
        } else if self.kind == JT_NUMBER {
            dump_number(self.num, out);
        } else if self.kind == JT_STRING {
            dump_escaped(self.s.as_str(), out);
        } else if self.kind == JT_ARRAY {
            out.push_byte(b'[');
            for i in 0..self.arr.len() {
                if i > 0 {
                    out.push_byte(b',');
                }
                if pretty {
                    dump_indent(out, indent + 1);
                }
                self.arr.at(i).dump_into(out, pretty, indent + 1);
            }
            if pretty && self.arr.len() != 0 {
                dump_indent(out, indent);
            }
            out.push_byte(b']');
        } else {
            out.push_byte(b'{');
            for i in 0..self.obj.len() {
                if i > 0 {
                    out.push_byte(b',');
                }
                if pretty {
                    dump_indent(out, indent + 1);
                }
                dump_escaped(self.obj.at(i).key.as_str(), out);
                out.push_byte(b':');
                if pretty {
                    out.push_byte(b' ');
                }
                self.obj.at(i).value.dump_into(out, pretty, indent + 1);
            }
            if pretty && self.obj.len() != 0 {
                dump_indent(out, indent);
            }
            out.push_byte(b'}');
        }
    }
}

extend JSON as Default {
    /// A JSON null -- the C++ default constructor.
    pub fn default() JSON {
        return JSON::make(JT_NULL);
    }
}

extend JSON as Free {
    pub fn free(self: &mut Self) {
        self.s.free();
        self.arr.free();
        self.obj.free();
    }
}

fn dump_indent(out: &mut String, level: u32) {
    out.push_byte(b'\n');
    for k in 0..level * 2 {
        out.push_byte(b' ');
    }
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

// ---------------------------------------------------------------------------------------------------------
// Parser (JSONParser's string_view path): one pass over the bytes, dispatching per token class and
// attaching values through an explicit stack of raw slots -- no recursion, so nesting depth is bounded by
// MAX_NESTING_DEPTH instead of the C stack. Pointers are stored as usize (a raw *mut to a Free type is
// move-tracked); slot pointers stay stable because a parent container never grows while a child is open.
// ---------------------------------------------------------------------------------------------------------

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

extend JSONParser as Free {
    pub fn free(self: &mut Self) {
        self.stack.free();
        self.pending_key.free();
        self.candidate_key.free();
        self.err.free();
    }
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
        let t = self.top() as *mut JSON;
        if !self.comma_detected && unsafe t.obj.len() != 0 {
            self.fail("Missing ',' between object members");
            return 0;
        }
        if !self.pending_key_set {
            self.fail("Expected a key before adding an inner value");
            return 0;
        }
        let k = replace(&mut self.pending_key, String::new());
        self.candidate_key.clear();
        unsafe t.obj.push(JSONPair { key: k, value: json });
        self.pending_key_set = false;
        self.comma_detected = false;
        let idx = unsafe t.obj.len() - 1;
        return ((&mut unsafe t.obj[idx].value) as *mut JSON) as usize;
    }

    // Append `json` to the open array; frees it on a comma error.
    fn set_array_value(self: &mut Self, json: JSON) {
        let t = self.top() as *mut JSON;
        if !self.comma_detected && unsafe t.arr.len() != 0 {
            self.fail("Missing ',' between array members");
            return;
        }
        unsafe t.arr.push(json);
        self.comma_detected = false;
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
            p += 1; // the backslash
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
                out.push(code); // UTF-8 encode (String::push replaces the manual encoder)
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

    // Parse the number in src[from..to] (JSONParser::parseNumber): integer mantissa, fractional
    // accumulation, then a power-of-ten exponent scale.
    fn parse_number(self: &mut Self, from: usize, to: usize) f64 {
        let mut p = from;
        let mut neg = false;
        if self.src[p] == b'-' {
            neg = true;
            p += 1;
        }
        if p == to {
            self.fail("Invalid number: digit expected after '-'");
            return 0.0;
        }
        let mut int_part: u64 = 0;
        let b0 = self.src[p];
        if b0 == b'0' {
            p += 1;
            if p < to && self.src[p] >= b'0' && self.src[p] <= b'9' {
                self.fail("Invalid number: Leading zeros are not allowed");
                return 0.0;
            }
        } else if b0 >= b'1' && b0 <= b'9' {
            while p < to && self.src[p] >= b'0' && self.src[p] <= b'9' {
                int_part = int_part * 10 + (self.src[p] - b'0') as u64;
                p += 1;
            }
        } else {
            self.fail("Invalid number: digit expected after '-'");
            return 0.0;
        }
        let mut frac_part: f64 = 0.0;
        if p < to && self.src[p] == b'.' {
            p += 1;
            if p == to || self.src[p] < b'0' || self.src[p] > b'9' {
                self.fail("Invalid number: digit expected after '.'");
                return 0.0;
            }
            let mut factor: f64 = 0.1;
            while p < to && self.src[p] >= b'0' && self.src[p] <= b'9' {
                frac_part += (self.src[p] - b'0') as f64 * factor;
                factor *= 0.1;
                p += 1;
            }
        }
        let mut value = int_part as f64 + frac_part;
        if p < to && (self.src[p] == b'e' || self.src[p] == b'E') {
            p += 1;
            let mut exp_neg = false;
            if p < to && (self.src[p] == b'+' || self.src[p] == b'-') {
                exp_neg = self.src[p] == b'-';
                p += 1;
            }
            if p == to || self.src[p] < b'0' || self.src[p] > b'9' {
                self.fail("Invalid number: digit expected after exponent");
                return 0.0;
            }
            // Saturate the exponent at a value past the f64 range so a pathological input like
            // 1e999999999 costs O(digits), and scale by squaring -- O(log exponent), never linear.
            let mut exponent: i64 = 0;
            while p < to && self.src[p] >= b'0' && self.src[p] <= b'9' {
                if exponent < 4096 {
                    exponent = exponent * 10 + (self.src[p] - b'0') as i64;
                }
                p += 1;
            }
            if exponent > 400 {
                exponent = 400;
            }
            let mut scale: f64 = 1.0;
            let mut base: f64 = 10.0;
            let mut e = exponent;
            while e > 0 {
                if (e & 1) == 1 {
                    scale *= base;
                }
                base *= base;
                e = e >> 1;
            }
            if exp_neg {
                value /= scale;
            } else {
                value *= scale;
            }
        }
        if p != to {
            self.fail("Invalid character in number");
            return 0.0;
        }
        if neg {
            return 0.0 - value;
        }
        return value;
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
                // skip
            } else if c == b'{' {
                self.depth += 1;
                if self.depth > MAX_NESTING_DEPTH {
                    self.fail("Nesting depth limit exceeded");
                    return i;
                }
                let t = self.top() as *mut JSON;
                if unsafe t.kind == JT_OBJECT {
                    let mut child = JSON::object();
                    child.reserve(8);
                    let slot = self.set_object_value(child);
                    if slot == 0 {
                        return i;
                    }
                    self.stack.push(slot);
                } else if unsafe t.kind == JT_ARRAY {
                    let mut child = JSON::object();
                    child.reserve(8);
                    self.set_array_value(child);
                    if self.err.len() != 0 {
                        return i;
                    }
                    let last = unsafe t.arr.len() - 1;
                    self.stack.push(((&mut unsafe t.arr[last]) as *mut JSON) as usize);
                } else if self.stack.len() == 1 {
                    t.reset_to(JT_OBJECT);
                    unsafe t.obj.reserve(8);
                }
                self.found_data = true;
            } else if c == b'}' {
                let t = self.top() as *mut JSON;
                if unsafe t.kind == JT_OBJECT {
                    if self.pending_key_set {
                        self.fail_s(format("Missing value for key '{}' in object", self.pending_key.as_str()));
                        return i;
                    }
                    if self.comma_detected && unsafe t.obj.len() != 0 {
                        self.fail("Trailing ',' before closing '}'");
                        return i;
                    }
                    self.depth -= 1;
                    self.stack.pop();
                    if self.stack.len() == 0 {
                        return i + 1;
                    }
                } else if unsafe t.kind == JT_ARRAY {
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
                if unsafe t.kind == JT_OBJECT {
                    let mut child = JSON::array();
                    child.reserve(8);
                    let slot = self.set_object_value(child);
                    if slot == 0 {
                        return i;
                    }
                    self.stack.push(slot);
                } else if unsafe t.kind == JT_ARRAY {
                    let mut child = JSON::array();
                    child.reserve(8);
                    self.set_array_value(child);
                    if self.err.len() != 0 {
                        return i;
                    }
                    let last = unsafe t.arr.len() - 1;
                    self.stack.push(((&mut unsafe t.arr[last]) as *mut JSON) as usize);
                } else if self.stack.len() == 1 {
                    // root arrays reserve by input size (max(16, n/512)) like the original
                    let mut cap: usize = 16;
                    if n / 512 > cap {
                        cap = n / 512;
                    }
                    t.reset_to(JT_ARRAY);
                    unsafe t.arr.reserve(cap);
                }
                self.found_data = true;
            } else if c == b']' {
                let t = self.top() as *mut JSON;
                if unsafe t.kind == JT_ARRAY {
                    if self.comma_detected && unsafe t.arr.len() != 0 {
                        self.fail("Trailing ',' before closing ']'");
                        return i;
                    }
                    self.depth -= 1;
                    self.stack.pop();
                    if self.stack.len() == 0 {
                        return i + 1;
                    }
                } else if unsafe t.kind == JT_OBJECT {
                    self.fail("Expected '}' but found ']'");
                    return i;
                } else {
                    self.fail("Unexpected ']'");
                    return i;
                }
                self.found_data = true;
            } else if c == b':' {
                let t = self.top() as *mut JSON;
                if unsafe t.kind == JT_ARRAY {
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
                if self.comma_detected {
                    self.fail("Duplicate ','");
                    return i;
                }
                self.comma_detected = true;
                self.pending_key_set = false;
                self.pending_key.clear();
                self.candidate_key.clear();
                self.candidate_key_set = false;
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
                        if unsafe t.kind == JT_OBJECT {
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
                        } else if unsafe t.kind == JT_ARRAY {
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
                if unsafe t.kind == JT_OBJECT && !self.pending_key_set {
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
                if unsafe t.kind == JT_OBJECT {
                    self.set_object_value(JSON::number(num));
                } else if unsafe t.kind == JT_ARRAY {
                    self.set_array_value(JSON::number(num));
                } else if self.stack.len() == 1 {
                    unsafe *t = JSON::number(num);
                    self.stack.pop();
                    return q;
                }
                i = q - 1;
            } else if c == b't' || c == b'f' || c == b'n' {
                let t = self.top() as *mut JSON;
                if unsafe t.kind == JT_OBJECT && !self.pending_key_set {
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
                if unsafe t.kind == JT_OBJECT {
                    self.set_object_value(val);
                } else if unsafe t.kind == JT_ARRAY {
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
        if unsafe t.kind == JT_OBJECT {
            return Result::<JSON, String>::Err(String::from_str("Missing closing '}' for object"));
        }
        if unsafe t.kind == JT_ARRAY {
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
