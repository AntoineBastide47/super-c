// The string module: the owning, growable UTF-8 `String`. Auto-imported as the prelude, so `String` is
// in scope unqualified everywhere. The borrowed `str` view it builds on (the type of a string literal)
// lives in the sibling `str` prelude module.
//
// Representation: the SMALL STRING OPTIMIZATION. `String` is a struct of a `repr` (an untagged union of two
// same-sized 24-byte layouts) plus the allocator it was built through:
//   - Large { ptr, len, cap } -- a heap buffer the value owns.
//   - Small { data: [u8; 23], len: u8 } -- up to 23 UTF-8 bytes stored INLINE, no allocation.
// The union's last byte is `Small.len` and (little-endian) the most-significant byte of `Large.cap`. The
// high bit of that byte is the discriminant: set => large (so `cap` keeps its real value in the low 63
// bits), clear => small (a small length 0..=23 always has its high bit clear). So a freshly built short
// string lives entirely inline and the first push that crosses 23 bytes transitions it to the heap.
//
// The allocator `A` is a VALUE stored OUTSIDE the SSO union (`alloc: A`), so the same allocator instance
// that made an allocation also releases it -- which a stateful arena/pool handle requires (`alloc`/`dealloc`
// never reconstruct a fresh `A`). A zero-sized allocator (`Global`) costs no space, so a `String<Global>` is
// still 24 bytes; a non-zero handle makes `String<A>` larger -- the correct price of a stateful allocator.
// `new()`/`from_str()`/... use a default-constructed allocator; build a stateful one with `new_in`/
// `with_capacity_in`/`from_str_in` (the convenience constructors require `A: Default`).
//
// Bytes are UTF-8, length is tracked explicitly (no NUL terminator, embedded zeros are fine), appends are
// amortised O(1), and bulk work goes through libc memcpy/memmove/memcmp. Every method reads the bytes
// through `as_ptr()`/`data_ptr()` and the length through `len()`, so the small/large split is invisible.
//
// Caveat: for a SMALL string `as_ptr()` points INTO the String value itself, so it is invalidated when the
// String is moved/copied as well as when a mutation grows it onto the heap (matches C++ SSO).
//
// Encapsulation: `String` is `pub` but its `repr`/`alloc` members are private; the Repr/Large/Small helper
// types are module-private (their fields are `pub` only so `String`'s own methods can reach them).
//
// Borrowed raw access is available through `as_ptr` / `as_str`; higher-level borrowed iterators remain
// out of scope until the prelude can express them without header cycles.

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
    fn memmove(dst: *mut void, src: *const void, n: usize) *mut void;
    fn memcmp(a: *const void, b: *const void, n: usize) i32;
    fn strlen(s: *const char) usize;
    fn putchar(c: i32) i32;
    fn snprintf(buf: *mut char, n: usize, fmt: *const char, ...) i32;
    type FILE;
    fn fputc(c: i32, f: *mut FILE) i32;
    fn fwrite(p: *const void, size: usize, n: usize, f: *mut FILE) usize;
    fn __sc_stdout() *mut FILE;
    fn __sc_stderr() *mut FILE;
}

// Heap representation. `cap`'s top bit is the "is large" discriminant; its real value is the low 63 bits.
struct StringLarge {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}

// Inline representation: up to 23 UTF-8 bytes plus a 0..=23 length whose high bit (the discriminant) is
// always clear. 23 == sizeof(StringLarge) - 1 on a 64-bit target.
struct StringSmall {
    pub data: [u8; 23],
    pub len: u8,
}

// The SSO union: the heap and inline layouts overlap in the same 24 bytes (the allocator lives beside it in
// `String`, never inside this union).
union StringRepr {
    pub large: StringLarge,
    pub small: StringSmall,
}

pub struct String<A = Global> {
    repr: StringRepr,
    alloc: A, // the allocator the heap buffer (if any) was obtained through (private; zero-sized for Global)
}

extend<A: Allocator> String<A> {
    // --- representation helpers (private) ------------------------------------------------------

    // The high bit of the union's last byte: set for the heap layout, clear for the inline one.
    fn is_large(self: &String<A>) bool {
        return (self.repr.small.len & 0x80) != 0;
    }

    // A mutable pointer to the bytes, inline or heap. Re-read after any growth (it may move).
    fn data_ptr(self: &mut String<A>) *mut u8 {
        if self.is_large() {
            return self.repr.large.ptr;
        }
        return &self.repr.small.data[0] as *mut u8;
    }

    // Set the byte length in whichever representation is active (caller keeps a small length <= 23).
    fn set_len(self: &mut String<A>, n: usize) {
        if self.is_large() {
            self.repr.large.len = n;
        } else {
            self.repr.small.len = n as u8;
        }
    }

    // Ensure the heap buffer holds at least `new_cap` bytes, transitioning inline -> heap if needed
    // (copying the inline bytes out first). `new_cap` must exceed the inline budget. Allocates through the
    // STORED allocator (a String buffer is a byte array, so the alignment is always 1).
    fn grow_to(self: &mut String<A>, new_cap: usize) {
        if self.is_large() {
            let p = self.alloc.realloc(self.repr.large.ptr as *mut void, self.capacity(), new_cap, 1) as *mut u8;
            self.repr.large.ptr = p;
            self.repr.large.cap = new_cap | 1 as usize << 63;
            return;
        }
        let cur = self.repr.small.len as usize;
        let p = self.alloc.alloc(new_cap, 1) as *mut u8;
        if cur > 0 {
            unsafe memcpy(p as *mut void, &self.repr.small.data[0] as *const void, cur);
        }
        self.repr.large.ptr = p;
        self.repr.large.len = cur;
        self.repr.large.cap = new_cap | 1 as usize << 63;
    }

    // --- construction --------------------------------------------------------------------------

    // An empty string backed by an explicit allocator value (a stateful arena/pool handle, or a zero-sized
    // tag) -- inline, owns no heap yet. `small.len = 0` also clears the discriminant bit.
    pub fn new_in(alloc: A) String<A> {
        return String::<A> { repr: StringRepr { small: StringSmall { len: 0 } }, alloc: alloc };
    }

    // Pre-size for `cap` bytes through an explicit allocator. Up to 23 stay inline (no allocation).
    pub fn with_capacity_in(mut alloc: A, cap: usize) String<A> {
        if cap <= 23 {
            return String::<A> { repr: StringRepr { small: StringSmall { len: 0 } }, alloc: alloc };
        }
        let p = alloc.alloc(cap, 1) as *mut u8;
        return String::<A> {
            repr: StringRepr { large: StringLarge { ptr: p, len: 0, cap: cap | 1 as usize << 63 } },
            alloc: alloc,
        };
    }

    // A new string through an explicit allocator, holding a copy of `text`'s bytes.
    pub fn from_str_in(alloc: A, text: str) String<A> {
        let mut s = String::<A>::with_capacity_in(alloc, text.len());
        s.push_str(text);
        return s;
    }

    // --- capacity & length ---------------------------------------------------------------------

    // Bytes currently stored. `s.len()` (this method) is the public accessor; the small/large split is
    // internal. (A bare `s.len` would be a private member -- a compile error outside this module.)
    pub fn len(self: &String<A>) usize {
        if self.is_large() {
            return self.repr.large.len;
        }
        return self.repr.small.len as usize;
    }

    // Total bytes available before the next growth: the real heap capacity, or the 23-byte inline budget.
    pub fn capacity(self: &String<A>) usize {
        if self.is_large() {
            return self.repr.large.cap << 1 >> 1; // drop the discriminant bit
        }
        return 23;
    }

    pub fn is_empty(self: &String<A>) bool {
        return self.len() == 0;
    }

    // Guarantee room for `additional` more bytes, growing by doubling (amortised O(1) append). Stays
    // inline while the total fits in 23 bytes.
    pub fn reserve(self: &mut String<A>, additional: usize) {
        let needed = self.len() + additional;
        if needed <= self.capacity() {
            return;
        }
        let mut new_cap = self.capacity() * 2;
        if new_cap < needed {
            new_cap = needed;
        }
        self.grow_to(new_cap);
    }

    // Like `reserve`, but allocate exactly enough (no doubling slack).
    pub fn reserve_exact(self: &mut String<A>, additional: usize) {
        let needed = self.len() + additional;
        if needed > self.capacity() {
            self.grow_to(needed);
        }
    }

    // Read-ahead sentinel padding: guarantee at least `n` zero bytes immediately after the logical end,
    // WITHOUT changing len. Code that establishes this may then over-read up to `n` bytes past the end
    // safely -- e.g. a lexer whose scan loops rely on the trailing NUL to terminate (no per-byte bounds
    // check) or that reads 8-byte words. Pre-size with with_capacity(len+n) and this never reallocates.
    pub fn pad_nul(self: &mut String<A>, n: usize) {
        self.reserve_exact(n);
        let l = self.len();
        let p = self.data_ptr();
        let mut i: usize = 0;
        while i < n {
            unsafe p[l + i] = 0;
            i = i + 1;
        }
    }

    // --- raw tail writes: for an external writer (a C vsnprintf/memcpy) that fills the spare region ------

    // Reserve room for `additional` more bytes and return a writable pointer at the current end (into the
    // spare capacity, `capacity() - len()` bytes of it). Write up to that many bytes there, then commit them
    // with `advance_len`. The returned pointer is invalidated by any later growth -- re-fetch after one.
    pub fn spare_mut(self: &mut String<A>, additional: usize) *mut u8 {
        self.reserve(additional);
        return unsafe (self.data_ptr() + self.len());
    }

    // Grow the length by `n` bytes just written into the spare region via `spare_mut`. Caller guarantees
    // `len() + n <= capacity()` and that those `n` bytes were initialised.
    pub fn advance_len(self: &mut String<A>, n: usize) {
        self.set_len(self.len() + n);
    }

    // Free unused capacity. A heap string short enough to fit inline moves back onto the stack and frees
    // its buffer; otherwise it reallocs down to its length. Inline strings are already minimal.
    pub fn shrink_to_fit(self: &mut String<A>) {
        if !self.is_large() {
            return;
        }
        let n = self.repr.large.len;
        let p = self.repr.large.ptr;
        let cap = self.capacity(); // read BEFORE any memcpy: the inline move overwrites the union's cap field
        if n <= 23 {
            // move back inline, then free the heap buffer
            if n > 0 {
                unsafe memcpy(&self.repr.small.data[0] as *mut void, p as *const void, n);
            }
            self.alloc.dealloc(p as *mut void, cap, 1);
            self.repr.small.len = n as u8; // clears the discriminant (n <= 23)
            return;
        }
        if self.capacity() != n {
            let np = self.alloc.realloc(p as *mut void, self.capacity(), n, 1) as *mut u8;
            self.repr.large.ptr = np;
            self.repr.large.cap = n | 1 as usize << 63;
        }
    }

    // Free the contents but keep any heap allocation for reuse.
    pub fn clear(self: &mut String<A>) {
        self.set_len(0);
    }

    // Shorten to at most `new_len` bytes (no-op if already shorter). Caller keeps UTF-8 boundaries.
    pub fn truncate(self: &mut String<A>, new_len: usize) {
        if new_len < self.len() {
            self.set_len(new_len);
        }
    }

    // --- append --------------------------------------------------------------------------------

    // Append `n` raw bytes from `src` (the bulk primitive the other appenders build on).
    pub fn push_bytes(self: &mut String<A>, src: *const u8, n: usize) {
        if n == 0 {
            return;
        }
        self.reserve(n);
        let len = self.len();
        let p = self.data_ptr();
        unsafe memcpy(unsafe (p + len) as *mut void, src as *const void, n);
        self.set_len(len + n);
    }

    // Append one raw byte.
    pub fn push_byte(self: &mut String<A>, b: u8) {
        self.reserve(1);
        let len = self.len();
        let p = self.data_ptr();
        unsafe p[len] = b;
        self.set_len(len + 1);
    }

    // Append one Unicode scalar value, UTF-8 encoded into 1-4 bytes.
    pub fn push(self: &mut String<A>, ch: u32) {
        if ch < 0x80 {
            self.push_byte(ch as u8);
        } else if ch < 0x800 {
            self.push_byte((0xC0 | ch >> 6) as u8);
            self.push_byte((0x80 | ch & 0x3F) as u8);
        } else if ch < 0x10000 {
            self.push_byte((0xE0 | ch >> 12) as u8);
            self.push_byte((0x80 | ch >> 6 & 0x3F) as u8);
            self.push_byte((0x80 | ch & 0x3F) as u8);
        } else {
            self.push_byte((0xF0 | ch >> 18) as u8);
            self.push_byte((0x80 | ch >> 12 & 0x3F) as u8);
            self.push_byte((0x80 | ch >> 6 & 0x3F) as u8);
            self.push_byte((0x80 | ch & 0x3F) as u8);
        }
    }

    // Append the bytes of a `str` (e.g. a string literal).
    pub fn push_str(self: &mut String<A>, text: str) {
        self.push_bytes(text.ptr(), text.len());
    }

    // Append another String's bytes.
    pub fn push_string(self: &mut String<A>, other: &String<A>) {
        self.push_bytes(other.as_ptr(), other.len());
    }

    // Append the base-10 digits of an unsigned integer. Recurses on the high digits so they print first.
    pub fn push_u64(self: &mut String<A>, value: u64) {
        if value >= 10 {
            self.push_u64(value / 10);
        }
        self.push_byte((48 + value % 10) as u8);
    }

    // Append the base-10 digits of a signed integer, with a leading '-' when negative. The magnitude is
    // taken in u64 (`0 - value`) so i64::MIN is handled without overflow.
    pub fn push_i64(self: &mut String<A>, value: i64) {
        if value < 0 {
            self.push_byte(45);
            self.push_u64(0 as u64 - value as u64);
        } else {
            self.push_u64(value as u64);
        }
    }

    // Append the base-16 digits of an unsigned integer (no "0x" prefix). `upper` selects A-F vs a-f.
    // Recurses on the high nibbles so they print first; 0 prints as a single "0".
    pub fn push_hex(self: &mut String<A>, value: u64, upper: bool) {
        if value >= 16 {
            self.push_hex(value / 16, upper);
        }
        let d = value % 16;
        if d < 10 {
            self.push_byte((48 + d) as u8);
        } else {
            let mut base: u64 = 87; // 'a' - 10
            if upper {
                base = 55; // 'A' - 10
            }
            self.push_byte((base + d) as u8);
        }
    }

    // Append a signed integer in hex, with a leading '-' on negatives (magnitude in u64, so i64::MIN is safe).
    pub fn push_hex_i64(self: &mut String<A>, value: i64, upper: bool) {
        if value < 0 {
            self.push_byte(45);
            self.push_hex(0 as u64 - value as u64, upper);
        } else {
            self.push_hex(value as u64, upper);
        }
    }

    // Append the base-2 digits of an unsigned integer ('{:b}', no "0b" prefix). 0 prints as "0".
    pub fn push_bin(self: &mut String<A>, value: u64) {
        if value >= 2 {
            self.push_bin(value / 2);
        }
        self.push_byte((48 + value % 2) as u8);
    }

    // Append a floating-point value with exactly `prec` digits after the decimal point ('{:.N}').
    pub fn push_f64_prec(self: &mut String<A>, value: f64, prec: u32) {
        let buf = self.alloc.alloc(64, 1) as *mut char;
        let n = unsafe snprintf(buf, 64, "%.*f", prec as i32, value);
        if n > 0 {
            let mut m = n as usize;
            if m > 63 {
                m = 63; // snprintf reports the WOULD-BE length; only the truncated bytes exist
            }
            self.push_bytes(buf as *const u8, m);
        }
        self.alloc.dealloc(buf as *mut void, 64, 1);
    }

    // Append `s` in a `width`-byte field padded with `fill` ('{:>8}', '{:08}', '{:^6}').
    // `align`: 0 = left, 1 = right, 2 = center. A right-aligned zero fill is numeric-aware:
    // a leading '-' stays in front of the zeros.
    pub fn push_padded(self: &mut String<A>, s: str, width: usize, fill: u8, align: u8) {
        let n = s.len();
        if width <= n {
            self.push_str(s);
            return;
        }
        let pad = width - n;
        if align == 1 && fill == 48 && n > 0 && s.byte_at(0) == 45 {
            self.push_byte(45);
            for k in 0..pad {
                self.push_byte(48);
            }
            self.push_str(s.slice(1, n));
            return;
        }
        let mut lead: usize = 0;
        if align == 1 {
            lead = pad;
        } else if align == 2 {
            lead = pad / 2;
        }
        let mut i: usize = 0;
        while i < lead {
            self.push_byte(fill);
            i += 1;
        }
        self.push_str(s);
        while i < pad {
            self.push_byte(fill);
            i += 1;
        }
    }

    // Pad, in place, the field appended since `from` (a prior `len()`) to `width` bytes — the
    // no-temporary twin of `push_padded` for values formatted directly into this string: one
    // reserve, one memmove of the field, then fill. Same rules: `align` 0 = left, 1 = right,
    // 2 = center; a right-aligned zero fill keeps a leading '-' in front of the zeros.
    pub fn pad_at(self: &mut String<A>, from: usize, width: usize, fill: u8, align: u8) {
        let n = self.len() - from;
        if width <= n {
            return;
        }
        let pad = width - n;
        self.reserve(pad);
        let p = unsafe (self.data_ptr() + from);
        let mut lead: usize = 0;
        if align == 1 {
            lead = pad;
        } else if align == 2 {
            lead = pad / 2;
        }
        let mut sign: usize = 0;
        if align == 1 && fill == 48 && n > 0 && unsafe p[0] == 45 {
            sign = 1;
        }
        if lead > 0 {
            unsafe memmove(unsafe (p + sign + lead) as *mut void, unsafe (p + sign) as *const void, n - sign);
        }
        let mut i = sign;
        while i < sign + lead {
            unsafe p[i] = fill;
            i += 1;
        }
        i = lead + n;
        while i < width {
            unsafe p[i] = fill;
            i += 1;
        }
        self.set_len(from + width);
    }

    // Append a floating-point value formatted by C's "%g" (compact, round-trip-ish). The scratch buffer is
    // taken from the stored allocator and released back to it.
    pub fn push_f64(self: &mut String<A>, value: f64) {
        let buf = self.alloc.alloc(32, 1) as *mut char;
        let n = unsafe snprintf(buf, 32, "%g", value);
        if n > 0 {
            self.push_bytes(buf as *const u8, n as usize);
        }
        self.alloc.dealloc(buf as *mut void, 32, 1);
    }

    // Insert one byte at index `i` (0 <= i <= len), shifting the tail right.
    pub fn insert_byte(self: &mut String<A>, i: usize, b: u8) {
        self.reserve(1);
        let len = self.len();
        let p = self.data_ptr();
        unsafe memmove((unsafe (p + i) + 1) as *mut void, unsafe (p + i) as *const void, len - i);
        unsafe p[i] = b;
        self.set_len(len + 1);
    }

    // Insert a `str` at byte index `i` (0 <= i <= len), shifting the tail right.
    pub fn insert_str(self: &mut String<A>, i: usize, text: str) {
        if text.len() == 0 {
            return;
        }
        self.reserve(text.len());
        let len = self.len();
        let p = self.data_ptr();
        unsafe memmove((unsafe (p + i) + text.len()) as *mut void, unsafe (p + i) as *const void, len - i);
        unsafe memcpy(unsafe (p + i) as *mut void, text.ptr() as *const void, text.len());
        self.set_len(len + text.len());
    }

    // --- remove --------------------------------------------------------------------------------

    // Remove and return the last byte, or 0 if the string is empty.
    pub fn pop_byte(self: &mut String<A>) u8 {
        let len = self.len();
        if len == 0 {
            return 0;
        }
        let p = self.data_ptr();
        self.set_len(len - 1);
        return unsafe p[len - 1];
    }

    // Remove and return the last UTF-8 scalar value (walking back over continuation bytes), or 0 if
    // empty -- the inverse of `push`.
    pub fn pop(self: &mut String<A>) u32 {
        let len = self.len();
        if len == 0 {
            return 0;
        }
        let p = self.data_ptr();
        let mut start = len - 1;
        while start > 0 && (unsafe p[start] & 0xC0) == 0x80 {
            // skip 0b10xxxxxx continuation bytes
            start = start - 1;
        }
        let n = len - start;
        let b0 = unsafe p[start] as u32;
        let mut ch: u32 = b0;
        if n == 2 {
            ch = (b0 & 0x1F) << 6 | unsafe p[start + 1] as u32 & 0x3F;
        } else if n == 3 {
            ch = (b0 & 0x0F) << 12 | (unsafe p[start + 1] as u32 & 0x3F) << 6 | unsafe p[start + 2] as u32 & 0x3F;
        } else if n == 4 {
            ch = (b0 & 0x07) << 18 | (unsafe p[start + 1] as u32 & 0x3F) << 12 | (unsafe p[start + 2] as u32 & 0x3F) << 6 | unsafe p[start + 3] as u32 & 0x3F;
        }
        self.set_len(start);
        return ch;
    }

    // Remove and return the byte at index `i` (i < len), shifting the tail left.
    pub fn remove_byte(self: &mut String<A>, i: usize) u8 {
        let len = self.len();
        let p = self.data_ptr();
        let b = unsafe p[i];
        unsafe memmove(unsafe (p + i) as *mut void, (unsafe (p + i) + 1) as *const void, len - i - 1);
        self.set_len(len - 1);
        return b;
    }

    // --- access --------------------------------------------------------------------------------

    // The byte at `i` (0 <= i < len). No bounds check -- the caller owns the index.
    pub fn byte(self: &String<A>, i: usize) u8 {
        return unsafe self.as_ptr()[i];
    }

    // Overwrite the byte at `i` (0 <= i < len).
    pub fn set_byte(self: &mut String<A>, i: usize, b: u8) {
        let p = self.data_ptr();
        unsafe p[i] = b;
    }

    // A read-only pointer to the bytes (inline or heap). See the module-level caveat on small strings.
    pub fn as_ptr(self: &String<A>) *const u8 {
        if self.is_large() {
            return self.repr.large.ptr as *const u8;
        }
        return &self.repr.small.data[0] as *const u8;
    }

    pub fn as_str(self: &String<A>) str {
        return str::from_raw(self.as_ptr(), self.len());
    }

    // Borrowed iterators over the bytes -- delegate to the `str` view: valid until the next mutation, and
    // only while `self` is alive (bind the String to a `let`; do not iterate a temporary's iterator).
    pub fn bytes(self: &String<A>) Bytes {
        return self.as_str().bytes();
    }

    pub fn chars(self: &String<A>) Chars {
        return self.as_str().chars();
    }

    pub fn split(self: &String<A>, sep: str) Split {
        return self.as_str().split(sep);
    }

    pub fn lines(self: &String<A>) Lines {
        return self.as_str().lines();
    }

    // A NUL-terminated `*const char` view of the bytes, for passing to C APIs (the FFI `.cstr()` bridge).
    // Writes a trailing 0 just past `len` without changing the length, growing by one byte if needed. The
    // pointer is valid until the next mutation; embedded NULs make C see a truncated string.
    pub fn cstr(self: &mut String<A>) *const char {
        self.reserve(1);
        let len = self.len();
        let p = self.data_ptr();
        unsafe p[len] = 0;
        return self.as_ptr() as *const char;
    }

    // Number of UTF-8 scalar values: every byte that is not a 0b10xxxxxx continuation starts one.
    pub fn char_count(self: &String<A>) usize {
        let n = self.len();
        let p = self.as_ptr();
        let mut count: usize = 0;
        for i in 0..n {
            if (unsafe p[i] & 0xC0) != 0x80 {
                count = count + 1;
            }
        }
        return count;
    }

    // Bytes [start, end) copied into a new owned String (through a copy of this string's allocator).
    pub fn substring(self: &String<A>, start: usize, end: usize) String<A> {
        let n = end - start;
        let mut s = String::<A>::with_capacity_in(self.alloc, n);
        if n > 0 {
            unsafe memcpy(s.data_ptr() as *mut void, unsafe (self.as_ptr() + start) as *const void, n);
            s.set_len(n);
        }
        return s;
    }

    // `self` repeated `n` times in a freshly allocated String (same allocator).
    pub fn repeat(self: &String<A>, n: usize) String<A> {
        let len = self.len();
        let src = self.as_ptr();
        let mut out = String::<A>::with_capacity_in(self.alloc, len * n);
        if len > 0 {
            for k in 0..n {
                let at = out.len();
                let dst = out.data_ptr();
                unsafe memcpy(unsafe (dst + at) as *mut void, src as *const void, len);
                out.set_len(at + len);
            }
        }
        return out;
    }

    // --- compare -------------------------------------------------------------------------------

    pub fn equals(self: &String<A>, other: &String<A>) bool {
        let n = self.len();
        if n != other.len() {
            return false;
        }
        if n == 0 {
            return true;
        }
        return unsafe memcmp(self.as_ptr() as *const void, other.as_ptr() as *const void, n) == 0;
    }

    pub fn eq_str(self: &String<A>, text: str) bool {
        let n = self.len();
        if n != text.len() {
            return false;
        }
        if n == 0 {
            return true;
        }
        return unsafe memcmp(self.as_ptr() as *const void, text.ptr() as *const void, n) == 0;
    }

    // ASCII-case-insensitive content equality (multibyte bytes must match exactly).
    pub fn eq_ignore_ascii_case(self: &String<A>, other: &String<A>) bool {
        let n = self.len();
        if n != other.len() {
            return false;
        }
        let a = self.as_ptr();
        let b = other.as_ptr();
        for i in 0..n {
            let mut x = unsafe a[i];
            let mut y = unsafe b[i];
            if x >= 65 && x <= 90 {
                x = x + 32;
            } // fold A-Z to a-z
            if y >= 65 && y <= 90 {
                y = y + 32;
            }
            if x != y {
                return false;
            }
        }
        return true;
    }

    // True if every byte is ASCII (< 0x80) -- i.e. no multibyte UTF-8 sequences.
    pub fn is_ascii(self: &String<A>) bool {
        let n = self.len();
        let p = self.as_ptr();
        for i in 0..n {
            if unsafe p[i] >= 0x80 {
                return false;
            }
        }
        return true;
    }

    // --- search --------------------------------------------------------------------------------

    pub fn starts_with(self: &String<A>, prefix: str) bool {
        if prefix.len() > self.len() {
            return false;
        }
        if prefix.len() == 0 {
            return true;
        }
        return unsafe memcmp(self.as_ptr() as *const void, prefix.ptr() as *const void, prefix.len()) == 0;
    }

    pub fn ends_with(self: &String<A>, suffix: str) bool {
        let n = self.len();
        if suffix.len() > n {
            return false;
        }
        if suffix.len() == 0 {
            return true;
        }
        return unsafe memcmp(
            unsafe (self.as_ptr() + (n - suffix.len())) as *const void,
            suffix.ptr() as *const void,
            suffix.len(),
        ) == 0;
    }

    // First index of byte `b`, or `len` (a past-the-end sentinel) if absent.
    pub fn index_of_byte(self: &String<A>, b: u8) usize {
        let n = self.len();
        let p = self.as_ptr();
        for i in 0..n {
            if unsafe p[i] == b {
                return i;
            }
        }
        return n;
    }

    // Last index of byte `b`, or `len` if absent.
    pub fn last_index_of_byte(self: &String<A>, b: u8) usize {
        let n = self.len();
        let p = self.as_ptr();
        let mut i = n;
        while i > 0 {
            i = i - 1;
            if unsafe p[i] == b {
                return i;
            }
        }
        return n;
    }

    pub fn contains_byte(self: &String<A>, b: u8) bool {
        return self.index_of_byte(b) < self.len();
    }

    // Count of (non-overlapping at the byte level) occurrences of byte `b`.
    pub fn count_byte(self: &String<A>, b: u8) usize {
        let len = self.len();
        let p = self.as_ptr();
        let mut n: usize = 0;
        for i in 0..len {
            if unsafe p[i] == b {
                n = n + 1;
            }
        }
        return n;
    }

    // First byte index where `needle` occurs, or `len` if absent (naive O(n*m) window scan).
    pub fn find(self: &String<A>, needle: str) usize {
        let n = self.len();
        if needle.len() == 0 {
            return 0;
        }
        if needle.len() > n {
            return n;
        }
        let p = self.as_ptr();
        let last = n - needle.len();
        for i in 0..=last {
            if unsafe memcmp(unsafe (p + i) as *const void, needle.ptr() as *const void, needle.len()) == 0 {
                return i;
            }
        }
        return n;
    }

    // Last byte index where `needle` occurs, or `len` if absent.
    pub fn rfind(self: &String<A>, needle: str) usize {
        let n = self.len();
        if needle.len() == 0 {
            return n;
        }
        if needle.len() > n {
            return n;
        }
        let p = self.as_ptr();
        let mut i = n - needle.len() + 1; // one past the highest candidate; walk down to 0
        while i > 0 {
            i = i - 1;
            if unsafe memcmp(unsafe (p + i) as *const void, needle.ptr() as *const void, needle.len()) == 0 {
                return i;
            }
        }
        return n;
    }

    pub fn contains(self: &String<A>, needle: str) bool {
        return self.find(needle) != self.len();
    }

    // --- transform & replace -------------------------------------------------------------------

    pub fn to_ascii_upper(self: &mut String<A>) {
        let n = self.len();
        let p = self.data_ptr();
        for i in 0..n {
            let b = unsafe p[i];
            if b >= 97 && b <= 122 {
                // 'a'..='z' -> 'A'..='Z'
                unsafe p[i] = b - 32;
            }
        }
    }

    pub fn to_ascii_lower(self: &mut String<A>) {
        let n = self.len();
        let p = self.data_ptr();
        for i in 0..n {
            let b = unsafe p[i];
            if b >= 65 && b <= 90 {
                // 'A'..='Z' -> 'a'..='z'
                unsafe p[i] = b + 32;
            }
        }
    }

    // Replace every byte equal to `from` with `to`, in place.
    pub fn replace_byte(self: &mut String<A>, from: u8, to: u8) {
        let n = self.len();
        let p = self.data_ptr();
        for i in 0..n {
            if unsafe p[i] == from {
                unsafe p[i] = to;
            }
        }
    }

    // A new String (same allocator) with every non-overlapping occurrence of `from` replaced by `to`.
    // Unmatched runs are copied in bulk (memcpy via push_bytes); only the replacements interrupt the copy.
    pub fn replace(self: &String<A>, from: str, to: str) String<A> {
        let n = self.len();
        if from.len() == 0 || from.len() > n {
            return self.clone();
        }
        let p = self.as_ptr();
        let mut out = String::<A>::new_in(self.alloc);
        let last = n - from.len();
        let mut i: usize = 0;
        let mut run: usize = 0; // start of the pending unmatched run
        while i <= last {
            if unsafe memcmp(unsafe (p + i) as *const void, from.ptr() as *const void, from.len()) == 0 {
                out.push_bytes(unsafe (p + run) as *const u8, i - run);
                out.push_str(to);
                i = i + from.len();
                run = i;
            } else {
                i = i + 1;
            }
        }
        out.push_bytes(unsafe (p + run) as *const u8, n - run); // trailing run
        return out;
    }

    // Free leading ASCII whitespace (space, tab, newline, carriage return), shifting bytes left.
    pub fn trim_start(self: &mut String<A>) {
        let len = self.len();
        let p = self.data_ptr();
        let mut start: usize = 0;
        while start < len {
            let b = unsafe p[start];
            if b != 32 && b != 9 && b != 10 && b != 13 {
                break;
            }
            start = start + 1;
        }
        if start > 0 {
            unsafe memmove(p as *mut void, unsafe (p + start) as *const void, len - start);
            self.set_len(len - start);
        }
    }

    // Free trailing ASCII whitespace.
    pub fn trim_end(self: &mut String<A>) {
        let p = self.data_ptr();
        let mut len = self.len();
        while len > 0 {
            let b = unsafe p[len - 1];
            if b != 32 && b != 9 && b != 10 && b != 13 {
                break;
            }
            len = len - 1;
        }
        self.set_len(len);
    }

    // Free ASCII whitespace from both ends.
    pub fn trim(self: &mut String<A>) {
        self.trim_end();
        self.trim_start();
    }

    // --- output --------------------------------------------------------------------------------

    // Write the UTF-8 bytes to stdout (no trailing newline).
    pub fn print(self: &String<A>) {
        unsafe fwrite(self.as_ptr() as *const void, 1, self.len(), unsafe __sc_stdout());
    }

    pub fn println(self: &String<A>) {
        self.print();
        unsafe putchar(10);
    }

    // Write the UTF-8 bytes to stderr (no trailing newline) -- the `eprint`/`eprintln` builtins' writer.
    pub fn eprint(self: &String<A>) {
        unsafe fwrite(self.as_ptr() as *const void, 1, self.len(), unsafe __sc_stderr());
    }

    pub fn eprintln(self: &String<A>) {
        self.eprint();
        unsafe fputc(10, unsafe __sc_stderr());
    }
}

extend<A: Allocator + Default> String<A> {
    // An empty string (default-constructed allocator -- `Global`, or any zero-sized/reconstructible tag).
    pub fn new() String<A> {
        return String::<A>::new_in(A::default());
    }

    // Pre-size for `cap` bytes (default allocator). Up to 23 stay inline (no allocation); more allocates.
    pub fn with_capacity(cap: usize) String<A> {
        return String::<A>::with_capacity_in(A::default(), cap);
    }

    // A new string (default allocator) holding a copy of `text`'s bytes.
    pub fn from_str(text: str) String<A> {
        return String::<A>::from_str_in(A::default(), text);
    }

    // A new string copied from a NUL-terminated C string (the inverse of `cstr`), for FFI return values
    // such as `getenv`/`strerror`. Copies up to the first NUL.
    pub fn from_cstr(s: *const char) String<A> {
        let n = unsafe strlen(s);
        let mut out = String::<A>::with_capacity(n);
        out.push_bytes(s as *const u8, n);
        return out;
    }

    // Build a fresh String (default allocator) from an unsigned / signed integer or a float.
    pub fn from_u64(value: u64) String<A> {
        let mut s = String::<A>::new();
        s.push_u64(value);
        return s;
    }
    pub fn from_i64(value: i64) String<A> {
        let mut s = String::<A>::new();
        s.push_i64(value);
        return s;
    }
    pub fn from_f64(value: f64) String<A> {
        let mut s = String::<A>::new();
        s.push_f64(value);
        return s;
    }
    pub fn from_hex(value: u64, upper: bool) String<A> {
        let mut s = String::<A>::new();
        s.push_hex(value, upper);
        return s;
    }
}

// Release the heap buffer (through the STORED allocator) and reset to the empty, inline state. Auto-`Free`:
// a `String` is freed at scope exit (unless moved out or freed explicitly). This is sound because every
// `String`-returning method here (`clone`/`substring`/`replace`/`repeat`) allocates a FRESH buffer -- none
// hands out a copy that shares the heap pointer -- so no aliased owner ever exists to double-free.
extend<A: Allocator> String<A> as Free {
    pub fn free(self: &mut String<A>) {
        if self.is_large() {
            self.alloc.dealloc(self.repr.large.ptr as *mut void, self.capacity(), 1);
        }
        self.repr.small.len = 0; // back to inline, empty (clears the discriminant)
    }
}

// Standard-interface conformances. Thin wrappers over the methods above so `String` can be used behind
// generic bounds (`fn join<T: Format>(..)`, `fn max<T: Ord>(..)`) and so operators dispatch to it.
extend<A: Allocator> String<A> as Eq {
    pub fn eq(self: &String<A>, other: &String<A>) bool {
        return self.equals(other);
    }
}

extend<A: Allocator> String<A> as Hash {
    // 64-bit FNV-1a over the bytes (matches str::hash, so an equal `str` and `String` hash alike).
    pub fn hash(self: &String<A>) u64 {
        let n = self.len();
        let p = self.as_ptr();
        let mut h: u64 = 0xcbf29ce484222325;
        for i in 0..n {
            h = (h ^ unsafe p[i] as u64) * 0x100000001b3;
        }
        return h;
    }
}

extend<A: Allocator> String<A> as Ord {
    // Lexicographic byte order; shorter is less when one is a prefix of the other.
    pub fn cmp(self: &String<A>, other: &String<A>) i32 {
        let la = self.len();
        let lb = other.len();
        let mut n = la;
        if lb < la {
            n = lb;
        }
        let c = unsafe memcmp(self.as_ptr() as *const void, other.as_ptr() as *const void, n);
        if c != 0 {
            return c;
        }
        if la < lb {
            return -1;
        }
        if la > lb {
            return 1;
        }
        return 0;
    }
}

extend<A: Allocator + Default> String<A> as Default {
    pub fn default() String<A> {
        return String::<A>::new();
    }
}

extend<A: Allocator + Default> String<A> as From<str> {
    pub fn from(value: str) String<A> {
        return String::<A>::from_str(value);
    }
}

extend<A: Allocator> String<A> as Clone {
    // A deep copy: an independent value with the same contents, through a copy of this string's allocator
    // (inline copies need no allocation).
    pub fn clone(self: &String<A>) String<A> {
        let n = self.len();
        let mut s = String::<A>::with_capacity_in(self.alloc, n);
        if n > 0 {
            unsafe memcpy(s.data_ptr() as *mut void, self.as_ptr() as *const void, n);
            s.set_len(n);
        }
        return s;
    }
}

// A String is its own textual form, and it is the canonical in-memory sink for formatting. `Format::fmt`
// yields the default-allocator `String` (the universal text type) regardless of `self`'s allocator, so it
// copies the bytes into a fresh `String<Global>`.
extend<A: Allocator> String<A> as Format {
    pub fn fmt(self: &String<A>) String<Global> {
        return String::<Global>::from_str(self.as_str());
    }
}

extend<A: Allocator> String<A> as Writer {
    // Append the bytes, returning the number written (always the slice length -- the buffer grows on demand).
    pub fn write(self: &mut String<A>, bytes: []u8) usize {
        let n = bytes.len();
        self.push_bytes(bytes.as_ptr(), n);
        return n;
    }
}

// Index conformance: `s[i]` borrows the byte at `i`, and `s[lo..hi]` -- any range form, `..=` including
// the end byte, an open end meaning `len()` -- is a borrowed `str` sub-view (valid until the next
// mutation, like `as_str`). Byte-addressed and unchecked: the caller keeps the bounds within `len` and
// on UTF-8 boundaries. No IndexMut: bytes are mutated through the growing/UTF-8-aware String API.
extend<A: Allocator> String<A> as Index<u8, str> {
    pub fn index(self: &String<A>, i: usize) &u8 {
        if i >= self.len() {
            panic("String[i]: index out of bounds");
        }
        return &unsafe self.as_str().ptr()[i];
    }
    pub fn index_range(self: &String<A>, r: Range<usize>) str {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > self.len() {
            panic("String[a..b]: range out of bounds");
        }
        return self.as_str().slice(r.start, hi);
    }
}

// Formatted output, compiler builtins. The first argument is a string literal with `{}` placeholders; the
// trailing arguments fill them in order and are appended by their type (any integer/float, bool, char, str,
// String, or any `Format` type). `{{`/`}}` are literal braces. `format` returns the built String; `print`
// writes it to stdout; `println` adds a trailing newline. (Bodies are stubs -- the compiler splits the
// literal and emits the per-argument appends at each call site.)
pub fn format(fmt: str, ...) String {
    return String::<Global>::new();
}
pub fn print(fmt: str, ...) {}
pub fn println(fmt: str, ...) {}
pub fn eprint(fmt: str, ...) {} // like print/println, written to stderr
pub fn eprintln(fmt: str, ...) {}

// Like `format`, but APPENDS the rendered output into this buffer instead of returning a new String --
// zero allocation (reuses the buffer's capacity). It is a METHOD so the receiver's `&mut` borrow defers
// past the argument evaluation (a free-fn `&mut dst` arg would collide with `self.X` format args).
// Lowered by codegen; this body is never emitted.
extend<A: Allocator> String<A> {
    pub fn format_into(self: &mut String<A>, fmt: str, ...) void {}
}
