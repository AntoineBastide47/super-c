// The reader of `packages.toml`, a TOML subset: `#` comments, the tables `[ffi]` and `[package.NAME]`, and
// `key = value` lines whose value is a basic string ("...", escapes \" \\ \n \t), a decimal integer, an array
// of strings (it may span lines), or an inline table of strings ({ key = "...", .. } on one line). Any other
// construct, an unknown or repeated key, and a missing required key are errors.

/// The targets of a package row, in table order.
pub const TARGETS: []str = ["macos", "ios", "linux", "android", "windows", "wasm"];
/// The support levels of a target; a package's `status` holds 1 + an index into this list, 0 when unset.
pub const STATUS: []str = ["full", "reduced", "unavailable"];
const TIER_MAX: i64 = 5;

const PKG_KEYS: []str = [
    "tier",
    "targets",
    "limits",
    "capabilities",
    "accelerations",
    "allocator",
    "thread_safety",
    "blocking",
    "errors",
    "platform_ffi",
    "c_functions",
];
const KEY_LIMITS: usize = 2;
// Every key but `limits`, `platform_ffi` and `c_functions`.
const PKG_REQUIRED: u32 = 0x1FB;
const FFI_KEYS: []str = ["modules", "functions"];

/// One `[package.NAME]` row.
pub struct Package {
    pub name: String,
    pub line: u32, // the line of its table header
    pub tier: u8,
    pub status: Array<u8, 6>, // per TARGETS: 1 + an index into STATUS, 0 when unset
    pub limits: String,
    pub capabilities: Vector<String>,
    pub accelerations: Vector<String>,
    pub allocator: String,
    pub thread_safety: String,
    pub blocking: String,
    pub errors: String,
    pub platform_ffi: Vector<String>,
    pub c_functions: Vector<String>,
    pub keys: u32, // bit k: PKG_KEYS[k] is set
}

/// The whole file: the package rows in file order and the `[ffi]` table.
pub struct Manifest {
    pub packages: Vector<Package>,
    pub ffi_modules: Vector<String>,
    pub ffi_functions: Vector<String>,
}

struct Pair {
    pub key: String,
    pub value: String,
}

struct Reader<'a> {
    pub src: str<'a>,
    pub i: usize,
    pub line: u32,
}

/// The manifest `src` holds, or the first error as `LINE: message`.
pub fn read_manifest(src: str) Result<Manifest, String> {
    let mut r = Reader { src: src, i: 0, line: 1 };
    let mut m = Manifest {
        packages: Vector::<Package>::new(),
        ffi_modules: Vector::<String>::new(),
        ffi_functions: Vector::<String>::new(),
    };
    let mut ffi_line: u32 = 0; // the `[ffi]` header's line; 0 before it
    let mut ffi_keys: u32 = 0;
    let mut in_ffi = false;
    loop {
        r.skip_space(true);
        if r.i >= r.src.len() {
            break;
        }
        if r.peek() == b'[' {
            let line = r.line;
            r.i += 1;
            let name = r.word(true);
            r.expect(b']')?;
            if name == "ffi" {
                if ffi_line != 0 {
                    return r.fail("a second [ffi] table");
                }
                ffi_line = line;
                in_ffi = true;
            } else if name.starts_with("package.") && name.len() > 8 && name.slice(8, name.len()).find_byte(b'.') < 0 {
                let pkg = name.slice(8, name.len());
                for p in m.packages.iter() {
                    if p.name.as_str() == pkg {
                        return r.fail("a second row of one package");
                    }
                }
                m.packages.push(Package::new(pkg, line));
                in_ffi = false;
            } else {
                return r.fail("a table other than [ffi] and [package.NAME]");
            }
            r.end_of_line()?;
            continue;
        }
        let key = r.word(false);
        if key.is_empty() {
            return r.fail("a key or a table header expected");
        }
        r.skip_space(false);
        r.expect(b'=')?;
        r.skip_space(false);
        if in_ffi {
            let k = key_index(FFI_KEYS, key);
            if k < 0 {
                return r.fail("an unknown key of [ffi]");
            }
            if (ffi_keys >> k as u32 & 1) != 0 {
                return r.fail("a repeated key");
            }
            ffi_keys = ffi_keys | 1u32 << k as u32;
            if k == 0 {
                m.ffi_modules = r.list()?;
            } else {
                m.ffi_functions = r.list()?;
            }
        } else if m.packages.is_empty() {
            return r.fail("a key outside a table");
        } else {
            let last = m.packages.len() - 1;
            r.package_key(&mut m.packages[last], key)?;
        }
        r.end_of_line()?;
    }
    if ffi_line == 0 {
        return r.fail("no [ffi] table");
    }
    if ffi_keys != 3 {
        return Err(format("{}: [ffi] needs 'modules' and 'functions'", ffi_line));
    }
    for p in m.packages.iter() {
        p.validate()?;
    }
    return Ok(m);
}

// The index of `key` in `keys`, -1 when absent.
const fn key_index(keys: []str, key: str) isize {
    for k in 0..keys.len() {
        if keys[k] == key {
            return k as isize;
        }
    }
    return -1;
}

extend Package {
    fn new(name: str, line: u32) Package {
        return Package {
            name: String::from_str(name),
            line: line,
            tier: 0,
            status: Array::<u8, 6> {},
            limits: String::new(),
            capabilities: Vector::<String>::new(),
            accelerations: Vector::<String>::new(),
            allocator: String::new(),
            thread_safety: String::new(),
            blocking: String::new(),
            errors: String::new(),
            platform_ffi: Vector::<String>::new(),
            c_functions: Vector::<String>::new(),
            keys: 0,
        };
    }

    // True when every target has the status `full`.
    const fn all_full(self: &Package) bool {
        for t in 0..TARGETS.len() {
            if self.status[t] != 1 {
                return false;
            }
        }
        return true;
    }

    // The keys a complete row needs: the required ones, a target list naming every target, `limits` exactly
    // when a target is not `full`, and no empty string.
    fn validate(self: &Package) Result<Unit, String> {
        let missing = PKG_REQUIRED & ~self.keys;
        if missing != 0 {
            let mut k: usize = 0;
            while (missing >> k as u32 & 1) == 0 {
                k += 1;
            }
            return Err(format("{}: [package.{}] has no '{}'", self.line, self.name.as_str(), PKG_KEYS[k]));
        }
        for t in 0..TARGETS.len() {
            if self.status[t] == 0 {
                return Err(format("{}: [package.{}] has no status for '{}'", self.line, self.name.as_str(), TARGETS[t]));
            }
        }
        let has_limits = (self.keys >> KEY_LIMITS as u32 & 1) != 0;
        if has_limits == self.all_full() {
            return Err(
                format(
                    "{}: [package.{}] needs 'limits' exactly when a target is not 'full'",
                    self.line,
                    self.name.as_str(),
                ),
            );
        }
        if has_limits && self.limits.is_empty() || self.allocator.is_empty() || self.thread_safety.is_empty() || self.blocking.is_empty() || self.errors.is_empty() {
            return Err(format("{}: [package.{}] has an empty value", self.line, self.name.as_str()));
        }
        return Ok(Unit {});
    }
}

extend<'a> Reader<'a> {
    const fn peek(self: &Self) u8 {
        if self.i < self.src.len() {
            return self.src.byte_at(self.i);
        }
        return 0;
    }

    fn fail<T>(self: &Self, msg: str) Result<T, String> {
        return Err(format("{}: {}", self.line, msg));
    }

    // Skip spaces, tabs, carriage returns and comments; newlines too when `lines`.
    const fn skip_space(self: &mut Self, lines: bool) {
        while self.i < self.src.len() {
            let b = self.src.byte_at(self.i);
            if b == b'#' {
                while self.i < self.src.len() && self.src.byte_at(self.i) != b'\n' {
                    self.i += 1;
                }
            } else if b == b'\n' && lines {
                self.line += 1;
                self.i += 1;
            } else if b == b' ' || b == b'\t' || b == b'\r' {
                self.i += 1;
            } else {
                return;
            }
        }
    }

    fn expect(self: &mut Self, b: u8) Result<Unit, String> {
        if self.peek() != b {
            let mut msg = String::from_str("'");
            msg.push_byte(b);
            msg.push_str("' expected");
            return self.fail(&msg);
        }
        self.i += 1;
        return Ok(Unit {});
    }

    // The rest of the line holds only spaces and a comment.
    fn end_of_line(self: &mut Self) Result<Unit, String> {
        self.skip_space(false);
        if self.i >= self.src.len() {
            return Ok(Unit {});
        }
        self.expect(b'\n')?;
        self.line += 1;
        return Ok(Unit {});
    }

    // A bare key (`A-Z a-z 0-9 _ -`), and `.` too when `dotted`; empty when none starts here.
    const fn word(self: &mut Self, dotted: bool) str<'a> {
        let start = self.i;
        while self.i < self.src.len() {
            let b = self.src.byte_at(self.i);
            if !(b == b'_' || b == b'-' || b >= b'a' && b <= b'z' || b >= b'A' && b <= b'Z' || b >= b'0' && b <= b'9' || dotted && b == b'.') {
                break;
            }
            self.i += 1;
        }
        return self.src.slice(start, self.i);
    }

    fn string(self: &mut Self) Result<String, String> {
        self.expect(b'"')?;
        let mut out = String::new();
        loop {
            let b = self.peek();
            if b == 0 || b == b'\n' {
                return self.fail("an unterminated string");
            }
            self.i += 1;
            if b == b'"' {
                return Ok(out);
            }
            if b != b'\\' {
                out.push_byte(b);
                continue;
            }
            let e = self.peek();
            self.i += 1;
            if e == b'"' || e == b'\\' {
                out.push_byte(e);
            } else if e == b'n' {
                out.push_byte(b'\n');
            } else if e == b't' {
                out.push_byte(b'\t');
            } else {
                return self.fail("an escape other than \\\" \\\\ \\n \\t");
            }
        }
    }

    fn integer(self: &mut Self) Result<i64, String> {
        let start = self.i;
        while self.peek() >= b'0' && self.peek() <= b'9' {
            self.i += 1;
        }
        let v = self.src.slice(start, self.i).parse_i64();
        if v.is_none() {
            return self.fail("an integer expected");
        }
        return Ok(v.unwrap());
    }

    // `[ "a", "b", ]`, over any number of lines.
    fn list(self: &mut Self) Result<Vector<String>, String> {
        self.expect(b'[')?;
        let mut out = Vector::<String>::new();
        loop {
            self.skip_space(true);
            if self.peek() == b']' {
                break;
            }
            out.push(self.string()?);
            self.skip_space(true);
            if self.peek() == b',' {
                self.i += 1;
            } else if self.peek() != b']' {
                return self.fail("',' or ']' expected");
            }
        }
        self.i += 1;
        return Ok(out);
    }

    // `{ key = "value", .. }` on one line.
    fn table(self: &mut Self) Result<Vector<Pair>, String> {
        self.expect(b'{')?;
        let mut out = Vector::<Pair>::new();
        loop {
            self.skip_space(false);
            if self.peek() == b'}' {
                break;
            }
            let key = self.word(false);
            if key.is_empty() {
                return self.fail("a key expected");
            }
            self.skip_space(false);
            self.expect(b'=')?;
            self.skip_space(false);
            out.push(Pair { key: String::from_str(key), value: self.string()? });
            self.skip_space(false);
            if self.peek() == b',' {
                self.i += 1;
            } else if self.peek() != b'}' {
                return self.fail("',' or '}' expected");
            }
        }
        self.i += 1;
        return Ok(out);
    }

    // The value of `key` in package row `p`.
    fn package_key(self: &mut Self, p: &mut Package, key: str) Result<Unit, String> {
        let k = key_index(PKG_KEYS, key);
        if k < 0 {
            return self.fail("an unknown key of a package row");
        }
        let bit = 1u32 << k as u32;
        if (p.keys & bit) != 0 {
            return self.fail("a repeated key");
        }
        p.keys = p.keys | bit;
        switch key {
            "tier" => {
                let t = self.integer()?;
                if t > TIER_MAX {
                    return self.fail("a tier above 5");
                }
                p.tier = t as u8;
            },
            "targets" => {
                let pairs = self.table()?;
                for pair in pairs.iter() {
                    let t = key_index(TARGETS, &pair.key);
                    if t < 0 {
                        return self.fail("an unknown target");
                    }
                    if p.status[t as usize] != 0 {
                        return self.fail("a repeated target");
                    }
                    let s = key_index(STATUS, &pair.value);
                    if s < 0 {
                        return self.fail("a status other than full, reduced and unavailable");
                    }
                    p.status[t as usize] = s as u8 + 1;
                }
            },
            "limits" => {
                p.limits = self.string()?;
            },
            "capabilities" => {
                p.capabilities = self.list()?;
            },
            "accelerations" => {
                p.accelerations = self.list()?;
            },
            "allocator" => {
                p.allocator = self.string()?;
            },
            "thread_safety" => {
                p.thread_safety = self.string()?;
            },
            "blocking" => {
                p.blocking = self.string()?;
            },
            "errors" => {
                p.errors = self.string()?;
            },
            "platform_ffi" => {
                p.platform_ffi = self.list()?;
            },
            _ => {
                p.c_functions = self.list()?; // the last of PKG_KEYS
            },
        }
        return Ok(Unit {});
    }
}
