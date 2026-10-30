// Paths of std::platform: the native separator, the absolute-path test, and the conversion between the
// `str` paths of the layer's API and the NUL-terminated native form the operating system takes (bytes on
// POSIX and WASI, UTF-16 on Windows). A path the layer reports on Windows uses '/' separators, so it can
// go into a C string literal or a JSON string unescaped. Unstable, internal to std and the compiler.
import std::text::utf16;

/// The separator the operating system prints.
@platform(windows)
pub const SEPARATOR: u8 = b'\\';
/// The separator the operating system prints.
@platform(!windows)
pub const SEPARATOR: u8 = b'/';

/// A unit of a native path: a byte, or a UTF-16 code unit on Windows.
@platform(windows)
pub type NativeUnit = u16;
/// A unit of a native path: a byte, or a UTF-16 code unit on Windows.
@platform(!windows)
pub type NativeUnit = u8;

// The units a path converts into without an allocation, its NUL included.
const INLINE_UNITS: usize = 512;

/// A path in the operating system's form, NUL-terminated. A path shorter than 512 units lives inline; a
/// longer one takes one allocation.
pub struct NativePath {
    inline: [NativeUnit; INLINE_UNITS],
    heap: Vector<NativeUnit>,
}

/// Whether `b` separates path components: '/', and also '\' on Windows.
pub const fn is_separator(b: u8) bool {
    if PLATFORM == Platform::Windows {
        return b == b'/' || b == b'\\';
    }
    return b == b'/';
}

/// Whether `p` names a file without reference to a current directory: a leading '/' on POSIX and WASI; a
/// drive and a separator (`C:/`) or a leading pair of separators (a UNC or device path) on Windows.
pub const fn is_absolute(p: str) bool {
    if PLATFORM == Platform::Windows {
        if p.len() >= 3 && p.byte_at(1) == b':' && is_separator(p.byte_at(2)) {
            let d = p.byte_at(0) | 0x20;
            return d >= b'a' && d <= b'z';
        }
        return p.len() >= 2 && is_separator(p.byte_at(0)) && is_separator(p.byte_at(1));
    }
    return p.len() >= 1 && p.byte_at(0) == b'/';
}

/// The native form of `p`. InvalidInput when `p` holds a NUL byte, or on Windows when it is not
/// well-formed UTF-8; `op` names the operation in the error.
pub fn native(p: str, op: IoOp) Result<NativePath, IoError> {
    if p.find_byte(0) >= 0 {
        return Err(IoError::new(IoErrorKind::InvalidInput, op));
    }
    let mut np = NativePath::empty();
    if !np.fill(p) {
        return Err(IoError::new(IoErrorKind::InvalidInput, op));
    }
    return Ok(np);
}

/// Append the UTF-8 form of the UTF-16 units `units` to `out`, '\' written as '/' when `slashes`: an
/// unpaired surrogate is InvalidData for `op`.
@platform(windows)
pub fn push_wide(out: &mut String, units: []u16, slashes: bool, op: IoOp) Result<Unit, IoError> {
    let start = out.len();
    if utf16::decode(units, out).is_err() {
        return Err(IoError::new(IoErrorKind::InvalidData, op));
    }
    if slashes {
        for i in start..out.len() {
            if out.byte(i) == b'\\' {
                out.set_byte(i, b'/');
            }
        }
    }
    return Ok(Unit {});
}

/// The units of the NUL-terminated wide string at `p`, without the NUL.
/// Safety: `p` points to a NUL-terminated array of u16 that outlives the view.
@platform(windows)
pub unsafe fn wide_view<'a>(p: *const u16) []'a u16 {
    let mut n: usize = 0;
    // Bounded by the terminating NUL.
    while unsafe p[n] != 0 {
        n += 1;
    }
    return unsafe Slice::<u16> { ptr: p, len: n };
}

extend NativePath {
    fn empty() NativePath {
        return NativePath { inline: [0; INLINE_UNITS], heap: Vector::<NativeUnit>::new() };
    }
    /// The NUL-terminated bytes, valid while the path lives.
    @platform(!windows)
    pub const fn ptr(self: &NativePath) *const char {
        if self.heap.len() != 0 {
            return self.heap.as_ptr() as *const char;
        }
        return ((&self.inline[0]) as *const u8) as *const char;
    }
    /// The NUL-terminated UTF-16 units, valid while the path lives.
    @platform(windows)
    pub fn ptr(self: &NativePath) *const u16 {
        if self.heap.len() != 0 {
            return self.heap.as_ptr();
        }
        return &self.inline[0];
    }

    // Copy `p` (no NUL inside) with its terminator: false when it is not representable.
    @platform(!windows)
    fn fill(self: &mut NativePath, p: str) bool {
        if p.len() < INLINE_UNITS {
            for i in 0..p.len() {
                unsafe self.inline[i] = p.byte_at(i);
            }
            return true;
        }
        self.heap.reserve(p.len() + 1);
        for i in 0..p.len() {
            self.heap.push(p.byte_at(i));
        }
        self.heap.push(0);
        return true;
    }
    @platform(windows)
    fn fill(self: &mut NativePath, p: str) bool {
        // A UTF-16 form never has more units than the UTF-8 form has bytes.
        if p.len() < INLINE_UNITS {
            return utf16::encode_into(p, self.inline).is_ok(); // the NUL after it is already there
        }
        if utf16::encode(p, &mut self.heap).is_err() {
            return false;
        }
        self.heap.push(0);
        return true;
    }
}
