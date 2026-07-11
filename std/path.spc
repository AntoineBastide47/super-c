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
        let p = unsafe malloc(sizeof(String)) as *mut String;
        if p as *mut void == null {
            unsafe abort();
        }
        unsafe p[0] = inner;
        return p;
    }

    pub fn new() Path {
        return Path { inner: Path::own_inner(String::new()) };
    }

    pub fn from_str(text: str) Path {
        return Path { inner: Path::own_inner(String::from_str(text)) };
    }

    pub fn as_string(self: &Path) &String {
        return &unsafe self.inner[0];
    }

    pub fn as_str(self: &Path) str {
        return unsafe self.inner[0].as_str();
    }

    pub fn len(self: &Path) usize {
        return unsafe self.inner[0].len();
    }

    pub fn is_empty(self: &Path) bool {
        return unsafe self.inner[0].is_empty();
    }

    pub fn join(self: &Path, child: str) Path {
        let mut out = unsafe self.inner[0].clone();
        if !out.is_empty() && !out.ends_with("/") {
            out.push_byte(47);
        }
        out.push_str(child);
        return Path { inner: Path::own_inner(out) };
    }

    pub fn file_name(self: &Path) str {
        let s = unsafe self.inner[0].as_str();
        let mut end = s.len(); // drop trailing '/' so "src/" yields "src", not ""
        while end > 0 && s.byte_at(end - 1) == 47 {
            end = end - 1;
        }
        let mut i = end;
        while i > 0 {
            i = i - 1;
            if s.byte_at(i) == 47 {
                return s.slice(i + 1, end);
            }
        }
        return s.slice(0, end);
    }

    pub fn parent(self: &Path) Path {
        let i = unsafe self.inner[0].rfind("/");
        if i == unsafe self.inner[0].len() {
            return Path::new();
        }
        return Path { inner: Path::own_inner(unsafe self.inner[0].substring(0, i)) };
    }

    pub fn extension(self: &Path) str {
        let name = self.file_name();
        let mut i = name.len(); // the LAST '.', so "archive.tar.gz" -> "gz"
        while i > 0 {
            i = i - 1;
            if name.byte_at(i) == 46 {
                if i == 0 {
                    return str::default(); // a leading-dot dotfile (".gitignore") has no extension
                }
                return name.slice(i + 1, name.len());
            }
        }
        return str::default();
    }
}

extend Path as Free {
    pub fn free(self: &mut Path) {
        if self.inner as *mut void != null {
            unsafe self.inner[0].free();
            unsafe free(self.inner as *mut void);
            self.inner = null;
        }
    }
}

extend Path as Clone {
    pub fn clone(self: &Path) Path {
        return Path { inner: Path::own_inner(unsafe self.inner[0].clone()) };
    }
}

extend Path as Eq {
    pub fn eq(self: &Path, other: &Path) bool {
        return unsafe self.inner[0].eq(&unsafe other.inner[0]);
    }
}

extend Path as Format {
    pub fn fmt(self: &Path) String {
        return unsafe self.inner[0].clone();
    }
}

extend Path as Default {
    pub fn default() Path {
        return Path::new();
    }
}
