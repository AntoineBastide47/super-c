// Path: a small owning path wrapper around String. It is intentionally lexical: it joins and splits path
// text, but does not touch the filesystem. Filesystem syscalls live in the FFI modules.

pub struct Path {
    inner: *mut String,
}

extern "C" {
    fn malloc(size: usize) *mut void;
    fn free(ptr: *mut void) void;
    fn abort() void;
}

extend Path {
    fn own_inner(inner: String) *mut String {
        let p = malloc(sizeof(String)) as *mut String;
        if (p as *mut void) == null {
            abort();
        }
        p[0] = inner;
        return p;
    }

    pub fn new() Path {
        return Path { inner: Path::own_inner(String::new()) };
    }

    pub fn from_str(text: str) Path {
        return Path { inner: Path::own_inner(String::from_str(text)) };
    }

    pub fn as_string(self: &Path) &String {
        return &self.inner[0];
    }

    pub fn as_str(self: &Path) str {
        return self.inner[0].as_str();
    }

    pub fn len(self: &Path) usize {
        return self.inner[0].len();
    }

    pub fn is_empty(self: &Path) bool {
        return self.inner[0].is_empty();
    }

    pub fn join(self: &Path, child: str) Path {
        let mut out = self.inner[0].clone();
        if !out.is_empty() && !out.ends_with("/") {
            out.push_byte(47);
        }
        out.push_str(child);
        return Path { inner: Path::own_inner(out) };
    }

    pub fn file_name(self: &Path) str {
        let s = self.inner[0].as_str();
        let i = self.inner[0].rfind("/");
        if i == self.inner[0].len() {
            return s;
        }
        return s.slice(i + 1, s.len);
    }

    pub fn parent(self: &Path) Path {
        let i = self.inner[0].rfind("/");
        if i == self.inner[0].len() {
            return Path::new();
        }
        return Path { inner: Path::own_inner(self.inner[0].substring(0, i)) };
    }

    pub fn extension(self: &Path) str {
        let name = self.file_name();
        let dot = name.find_byte(46);
        if dot < 0 {
            return str::default();
        }
        return name.slice((dot as usize) + 1, name.len);
    }
}

extend Path as Free {
    pub fn free(self: &mut Path) {
        if (self.inner as *mut void) != null {
            self.inner[0].free();
            free(self.inner as *mut void);
            self.inner = null;
        }
    }
}

extend Path as Clone {
    pub fn clone(self: &Path) Path {
        return Path { inner: Path::own_inner(self.inner[0].clone()) };
    }
}

extend Path as Eq {
    pub fn eq(self: &Path, other: &Path) bool {
        return self.inner[0].eq(&other.inner[0]);
    }
}

extend Path as Format {
    pub fn fmt(self: &Path) String {
        return self.inner[0].clone();
    }
}

extend Path as Default {
    pub fn default() Path {
        return Path::new();
    }
}
