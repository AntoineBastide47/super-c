// The string module: the owning, growable UTF-8 `String`. Auto-imported as the prelude, so `String` is
// in scope unqualified everywhere. The borrowed `str` view it builds on (the type of a string literal)
// lives in the sibling `str` prelude module.
//
// Representation: the SMALL STRING OPTIMIZATION. `String` is a struct of a `repr` (an untagged union of two
// same-sized layouts, 24 bytes on a 64-bit target and 12 on a 32-bit one) plus the allocator it was built
// through:
//   - Large { ptr, len, cap }: a heap buffer the value owns.
//   - Small { data: [u8; SSO_CAP], len: u8 }; that many UTF-8 bytes stored INLINE, no allocation.
// The union's last byte is `Small.len` and (little-endian) the most-significant byte of `Large.cap`. The
// high bit of that byte is the discriminant: set => large (so `cap` keeps its real value in the remaining
// bits), clear => small (a small length 0..=SSO_CAP always has its high bit clear). So a freshly built short
// string lives entirely inline and the first push that crosses SSO_CAP bytes transitions it to the heap.
//
// The allocator `A` is a VALUE stored OUTSIDE the SSO union (`alloc: A`), so the same allocator instance
// that made an allocation also releases it, which a stateful arena/pool handle requires (`alloc`/`dealloc`
// never reconstruct a fresh `A`). A zero-sized allocator (`Global`) costs no space, so a `String<Global>` is
// still exactly the union; a non-zero handle makes `String<A>` larger: the price of a stateful allocator.
// `new()`/`from_str()`/... use a default-constructed allocator; build a stateful one with `new_in`/
// `with_capacity_in`/`from_str_in` (the convenience constructors require `A: Default`).
//
// Bytes are UTF-8, length is tracked explicitly (no NUL terminator, embedded zeros are fine), appends are
// amortised O(1), and bulk work goes through libc memcpy/memmove/memcmp. Every method reads the bytes
// of the active representation (the heap block, or the inline array, which a pointer to it reaches
// alone) and the length through `len()`; callers see no small/large split.
//
// Caveat: for a SMALL string `as_ptr()` points INTO the String value itself, so it is invalidated when the
// String is moved/copied as well as when a mutation grows it onto the heap.
//
// Encapsulation: `String` is `pub` but its `repr`/`alloc` members are private; the Repr/Large/Small helper
// types are module-private (their fields are `pub` only so `String`'s own methods can reach them).
//
// Borrowed raw access is available through `as_ptr` / `as_str`; higher-level borrowed iterators remain
// out of scope until the prelude can express them without header cycles.

import std::spec::seq as *;

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
    fn memmove(dst: *mut void, src: *const void, n: usize) *mut void;
    fn memset(dst: *mut void, c: i32, n: usize) *mut void;
    fn memcmp(a: *const void, b: *const void, n: usize) i32;
    fn strlen(s: *const char) usize;
    fn putchar(c: i32) i32;
    fn snprintf(buf: *mut char, n: usize, fmt: *const char, ...) i32;
    type FILE;
    fn fputc(c: i32, f: *mut FILE) i32;
    fn fwrite(p: *const void, size: usize, n: usize, f: *mut FILE) usize;
}

// The standard output streams: `stdout` and `stderr` are macros over a per-target C object. wasm's C
// library defines no such object: its streams come from `sc_stdio_stream` (`std::rt::libc`).
@platform(macos | ios)
extern "C" "stdio.h" {
    @import("__stdoutp")
    static mut c_stdout: *mut FILE;
    @import("__stderrp")
    static mut c_stderr: *mut FILE;
}
@platform(linux | android)
extern "C" "stdio.h" {
    @import("stdout")
    static mut c_stdout: *mut FILE;
    @import("stderr")
    static mut c_stderr: *mut FILE;
}
@platform(wasm)
extern "C" {
    fn sc_stdio_stream(fd: i32) *mut FILE;
}
@platform(windows)
extern "C" "stdio.h" {
    fn __acrt_iob_func(i: u32) *mut FILE;
}

@platform(macos | ios | linux | android)
fn std_out() *mut FILE {
    return unsafe c_stdout;
}
@platform(macos | ios | linux | android)
fn std_err() *mut FILE {
    return unsafe c_stderr;
}
@platform(wasm)
fn std_out() *mut FILE {
    return unsafe sc_stdio_stream(1);
}
@platform(wasm)
fn std_err() *mut FILE {
    return unsafe sc_stdio_stream(2);
}
@platform(windows)
fn std_out() *mut FILE {
    return unsafe __acrt_iob_func(1);
}
@platform(windows)
fn std_err() *mut FILE {
    return unsafe __acrt_iob_func(2);
}

// Heap representation. `cap`'s top bit is the "is large" discriminant; its real value is the rest.
struct StringLarge {
    @owned
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}

// Both numbers are DERIVED from the pointer width rather than written out. On a 32-bit target (wasm32)
// `StringLarge` is 12 bytes, so a fixed 23-byte inline buffer would put the discriminant byte past `cap`
// altogether: every heap string then read back as inline and printed its own header.
const SSO_CAP: usize = sizeof(StringLarge) - 1;
const LARGE_BIT: usize = 1 << sizeof(usize) * 8 - 1;

// Inline representation: up to SSO_CAP UTF-8 bytes plus a 0..=SSO_CAP length whose high bit (the
// discriminant) is always clear.
struct StringSmall {
    // Spelled out rather than `[u8; SSO_CAP]`: an array length that NAMES a const cannot be folded while
    // lowering this type for a module typechecked before this one, which is what materializing a
    // `const S: String` in another module does. A `sizeof` needs only the layout, so it folds there.
    pub data: [u8; sizeof(StringLarge) - 1],
    pub len: u8,
}

// The SSO union: the heap and inline layouts overlap in the same 24 bytes (the allocator lives beside it in
// `String`, never inside this union).
union StringRepr {
    pub large: StringLarge,
    pub small: StringSmall,
}

/// A growable, heap-owning byte string with a small inline buffer; not NUL-terminated (see `cstr`). A
/// is the allocator of the large representation.
pub struct String<A: Allocator = Global>
    invariant self.repr.small.len < 0x80 ==> self.repr.small.len as usize <= SSO_CAP
    invariant self.repr.small.len >= 0x80 ==> self.repr.large.cap >= LARGE_BIT && self.repr.large.len <= self.repr.large.cap - LARGE_BIT && A::owns(
        self.repr.large.ptr,
        self.repr.large.cap - LARGE_BIT,
        1,
    )
    invariant self.repr.small.len >= 0x80 ==> block(self.repr.large.ptr).len() == (self.repr.large.cap - LARGE_BIT) as int
{
    repr: StringRepr,
    alloc: A, // the allocator the heap buffer (if any) was obtained through (private; zero-sized for Global)
}

// A String owns its bytes, so it is safe to send to / share with another thread when its allocator is
// (the raw buffer pointer would otherwise make it structurally neither).
unsafe extend<A: Allocator> String<A> as Zeroable {}
unsafe extend<A: Allocator + Send> String<A> as Send {}

unsafe extend<A: Allocator + Sync> String<A> as Sync {}

// The bytes of an inline buffer in order.
spec fn inline_view(data: []u8) Seq<u8> {
    return data.view();
}

extend<A: Allocator> String<A> {
    /// Its bytes in order: `s.len()` is its length, `s[i]` its byte `i`.
    pub spec fn view(self: &String<A>) Seq<u8> {
        return self.storage().take(self.length());
    }

    // The bytes of the active representation: the heap block, or the inline buffer.
    spec fn storage(self: &String<A>) Seq<u8> {
        return if self.repr.small.len >= 0x80 {
            block(self.repr.large.ptr)
        } else {
            inline_view(self.repr.small.data)
        };
    }

    // The length of the active representation.
    spec fn length(self: &String<A>) int {
        return if self.repr.small.len >= 0x80 {
            self.repr.large.len as int
        } else {
            self.repr.small.len as int
        };
    }

    // --- representation helpers (private) ------------------------------------------------------.

    // The high bit of the union's last byte: set for the heap layout, clear for the inline one.
    const fn is_large(self: &String<A>) bool
        ensures |r| r == self.repr.small.len >= 0x80
    {
        return self.repr.small.len >= 0x80;
    }

    // Set the byte length in whichever representation is active (caller keeps a small length <= SSO_CAP).
    const fn set_len(self: &mut String<A>, n: usize)
        requires n <= self.capacity()
        ensures self.len() == n && self.capacity() == old(self.capacity()) && self.is_large() == old(self.is_large())
        ensures self.view() == old(self.storage()).take(n as int) && self.repr.small.len >= 0x80 == old(self.repr.small.len >= 0x80)
    {
        if self.is_large() {
            self.repr.large.len = n;
            assert self.repr.small.len >= 0x80 by {};
        } else {
            self.repr.small.len = n as u8;
            assert self.repr.small.len < 0x80 by {};
        }
    }

    // Ensure the heap buffer holds at least `new_cap` bytes, transitioning inline -> heap if needed
    // (copying the inline bytes out first). `new_cap` must exceed the inline budget. Allocates through the
    // STORED allocator (a String buffer is a byte array, so the alignment is always 1).
    fn grow_to(self: &mut String<A>, new_cap: usize)
        requires new_cap < LARGE_BIT && new_cap > self.capacity()
        ensures self.is_large() && self.capacity() == new_cap && self.len() == old(self.len()) && self.view() == old(self.view())
    {
        if self.is_large() {
            let cap = self.repr.large.cap - LARGE_BIT;
            let p = (unsafe self.alloc.realloc(self.repr.large.ptr, cap, new_cap, 1)) as *mut u8;
            self.repr.large.ptr = p;
            self.repr.large.cap = new_cap + LARGE_BIT;
            // The capacity's top bit is the inline length's high bit.
            assert self.repr.small.len >= 0x80 by {};
            return;
        }
        let cur = self.repr.small.len as usize;
        let p = (unsafe self.alloc.alloc(new_cap, 1)) as *mut u8;
        if cur > 0 {
            unsafe memcpy(p, &self.repr.small.data[0], cur);
        }
        self.repr.large.ptr = p;
        self.repr.large.len = cur;
        self.repr.large.cap = new_cap + LARGE_BIT;
        assert self.repr.small.len >= 0x80 by {};
    }

    // --- construction --------------------------------------------------------------------------.

    /// An empty string backed by an explicit allocator value (a stateful arena/pool handle, or a zero-sized
    /// tag): inline, owns no heap yet. `small.len = 0` also clears the discriminant bit.
    pub const fn new_in(alloc: A) String<A>
        ensures |r| r.view() == Seq::<u8>::empty()
    {
        return String::<A> { repr: StringRepr { small: StringSmall { len: 0 } }, alloc: alloc };
    }

    /// Pre-size for `cap` bytes through an explicit allocator. Up to SSO_CAP stay inline (no allocation).
    pub fn with_capacity_in(mut alloc: A, cap: usize) String<A>
        panics if cap > SSO_CAP && cap >= LARGE_BIT
        ensures |r| r.len() == 0 && r.capacity() >= cap && r.view() == Seq::<u8>::empty()
    {
        if cap <= SSO_CAP {
            return String::<A> { repr: StringRepr { small: StringSmall { len: 0 } }, alloc: alloc };
        }
        if cap >= LARGE_BIT {
            // The capacity's top bit is the discriminant.
            panic("String: capacity overflow");
        }
        let p = (unsafe alloc.alloc(cap, 1)) as *mut u8;
        let r = String::<A> {
            repr: StringRepr { large: StringLarge { ptr: p, len: 0, cap: cap + LARGE_BIT } },
            alloc: alloc,
        };
        // The capacity's top bit is the inline length's high bit.
        assert r.repr.small.len >= 0x80 by {};
        return r;
    }

    /// A new string through an explicit allocator, holding a copy of `text`'s bytes.
    pub fn from_str_in(alloc: A, text: str) String<A> {
        let mut s = String::<A>::with_capacity_in(alloc, text.len());
        s.push_str(text);
        return s;
    }

    // --- capacity & length ---------------------------------------------------------------------.

    /// Bytes currently stored. `s.len()` (this method) is the public accessor; the small/large split is
    /// internal. (A bare `s.len` would be a private member: a compile error outside this module.)
    pub const fn len(self: &String<A>) usize
        ensures |r| self.repr.small.len >= 0x80 && r == self.repr.large.len || self.repr.small.len < 0x80 && r == self.repr.small.len as usize
        ensures |r| r as int == self.view().len()
    {
        if self.is_large() {
            return self.repr.large.len;
        }
        return self.repr.small.len as usize;
    }

    /// Total bytes available before the next growth: the real heap capacity, or the inline budget.
    pub const fn capacity(self: &String<A>) usize
        ensures |r| self.repr.small.len >= 0x80 && r == self.repr.large.cap - LARGE_BIT || self.repr.small.len < 0x80 && r == SSO_CAP
    {
        if self.is_large() {
            // Drop the discriminant bit.
            return self.repr.large.cap - LARGE_BIT;
        }
        return SSO_CAP;
    }

    /// True when the length is 0.
    pub const fn is_empty(self: &String<A>) bool
        ensures |r| r == (self.view().len() == 0)
    {
        return self.len() == 0;
    }

    /// Guarantee room for `additional` more bytes, growing by doubling (amortised O(1) append). Stays
    /// inline while the total fits in the inline budget.
    pub fn reserve(self: &mut String<A>, additional: usize)
        panics if additional as int > self.capacity() as int - self.len() as int && additional as int + self.len() as int >= LARGE_BIT as int
        ensures self.len() == old(self.len()) && self.len() as int + additional as int <= self.capacity() as int
        ensures self.view() == old(self.view())
    {
        // `capacity - len` cannot wrap, where `len + additional` could.
        if additional <= self.capacity() - self.len() {
            return;
        }
        self.grow_for(additional);
    }

    // The growth path of `reserve`, out of line so the check above stays small enough to inline into
    // every append.
    @noinline
    fn grow_for(self: &mut String<A>, additional: usize)
        requires additional as int > self.capacity() as int - self.len() as int
        panics if additional as int + self.len() as int >= LARGE_BIT as int
        ensures self.len() == old(self.len()) && self.len() as int + additional as int <= self.capacity() as int
        ensures self.view() == old(self.view())
    {
        let needed = self.checked_needed(additional);
        // A capacity stays below LARGE_BIT, so doubling it cannot wrap.
        let mut new_cap = self.capacity() * 2;
        if new_cap >= LARGE_BIT {
            new_cap = LARGE_BIT - 1;
        }
        if new_cap < needed {
            new_cap = needed;
        }
        self.grow_to(new_cap);
    }

    /// Like `reserve`, but allocate exactly enough (no doubling slack).
    pub fn reserve_exact(self: &mut String<A>, additional: usize)
        panics if additional as int > self.capacity() as int - self.len() as int && additional as int + self.len() as int >= LARGE_BIT as int
        ensures self.len() == old(self.len()) && self.len() as int + additional as int <= self.capacity() as int
        ensures self.view() == old(self.view())
    {
        if additional > self.capacity() - self.len() {
            self.grow_to(self.checked_needed(additional));
        }
    }

    // `len + additional`, which must stay below LARGE_BIT: the capacity's top bit is the discriminant.
    // Panics otherwise.
    const fn checked_needed(self: &String<A>, additional: usize) usize
        panics if additional as int + self.len() as int >= LARGE_BIT as int
        ensures |r| r < LARGE_BIT && r as int == self.len() as int + additional as int
    {
        if additional >= LARGE_BIT - self.len() {
            panic("String: capacity overflow");
        }
        return self.len() + additional;
    }

    /// Read-ahead sentinel padding: guarantee at least `n` zero bytes immediately after the logical end,
    /// WITHOUT changing len. Code that establishes this may then over-read up to `n` bytes past the end
    /// safely: e.g. a lexer whose scan loops rely on the trailing NUL to terminate (no per-byte bounds
    /// check) or that reads 8-byte words. Pre-size with with_capacity(len+n) and this never reallocates.
    pub fn pad_nul(self: &mut String<A>, n: usize) {
        self.reserve_exact(n);
        let l = self.len();
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        let mut i: usize = 0;
        while i < n {
            unsafe p[l + i] = 0;
            i = i + 1;
        }
    }

    // --- raw tail writes: for an external writer (a C vsnprintf/memcpy) that fills the spare region ------.

    /// Reserve room for `additional` more bytes and return a writable pointer at the current end (into the
    /// spare capacity, `capacity() - len()` bytes of it). Write up to that many bytes there, then commit them
    /// with `advance_len`. The returned pointer is invalidated by any later growth: re-fetch after one.
    pub fn spare_mut(self: &mut String<A>, additional: usize) *mut u8
        panics if additional as int > self.capacity() as int - self.len() as int && additional as int + self.len() as int >= LARGE_BIT as int
        ensures self.len() == old(self.len()) && self.len() as int + additional as int <= self.capacity() as int
        ensures self.view() == old(self.view())
        ensures |r| self.repr.small.len >= 0x80 ==> r == unsafe (self.repr.large.ptr + self.len())
        ensures |r| self.repr.small.len < 0x80 ==> r as *const u8 == unsafe ((&self.repr.small.data[0]) as *const u8 + self.len())
    {
        self.reserve(additional);
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        return unsafe (p + self.len());
    }

    /// Grow the length by `n` bytes written into the spare region via `spare_mut`. Caller guarantees
    /// `len() + n <= capacity()` and that those `n` bytes were initialised.
    pub const fn advance_len(self: &mut String<A>, n: usize)
        requires self.len() as int + n as int <= self.capacity() as int
    {
        self.set_len(self.len() + n);
    }

    /// Free unused capacity. A heap string short enough to fit inline moves back onto the stack and frees
    /// its buffer; otherwise it reallocs down to its length. Inline strings are already minimal.
    pub fn shrink_to_fit(self: &mut String<A>)
        ensures self.view() == old(self.view())
    {
        if !self.is_large() {
            return;
        }
        ghost let v0 = self.view();
        let n = self.repr.large.len;
        let p = self.repr.large.ptr;
        let cap = self.capacity(); // read BEFORE any memcpy: the inline move overwrites the union's cap field
        if n <= SSO_CAP {
            // Move back inline, then free the heap buffer.
            if n > 0 {
                unsafe memcpy(&mut self.repr.small.data[0], p, n);
            }
            // Clears the discriminant (n <= SSO_CAP): the string is whole again before the free, which
            // may panic.
            self.repr.small.len = n as u8;
            assert self.repr.small.len < 0x80 && self.view() == v0 by {};
            unsafe self.alloc.dealloc(p, cap, 1);
            return;
        }
        if cap != n {
            let nc = n + LARGE_BIT;
            let np = (unsafe self.alloc.realloc(p, cap, n, 1)) as *mut u8;
            self.repr.large.ptr = np;
            self.repr.large.cap = nc;
            assert self.repr.small.len >= 0x80 && self.view() == v0 by {};
        }
    }

    /// Free the contents but keep any heap allocation for reuse.
    pub const fn clear(self: &mut String<A>)
        ensures self.view() == Seq::<u8>::empty()
    {
        self.set_len(0);
    }

    /// Shorten to at most `new_len` bytes (no-op if already shorter). Caller keeps UTF-8 boundaries.
    pub const fn truncate(self: &mut String<A>, new_len: usize)
        ensures new_len as int >= old(self.view()).len() ==> self.view() == old(self.view())
        ensures new_len as int < old(self.view()).len() ==> self.view() == old(self.view()).take(new_len as int)
    {
        if new_len < self.len() {
            take_take(self.storage(), self.length(), new_len as int);
            self.set_len(new_len);
        }
    }

    // --- append --------------------------------------------------------------------------------.

    /// Append the bytes of `src` (the bulk primitive the other appenders build on).
    // Out of line: each representation has its own copy, too large for every append site (inlined, they
    // made the compiler 6% larger and its build no faster).
    @noinline
    pub fn push_bytes(self: &mut String<A>, src: Slice<u8>)
        panics if self.view().len() + src.view().len() >= LARGE_BIT as int
        ensures self.view() == old(self.view()).concat(src.view())
    {
        let n = src.len;
        if n == 0 {
            return;
        }
        self.reserve(n);
        if self.is_large() {
            self.append_large(src);
        } else {
            self.append_small(src);
        }
    }

    // `push_bytes` past the growth, on the heap representation: each representation proves alone.
    fn append_large(self: &mut String<A>, src: Slice<u8>)
        requires self.repr.small.len >= 0x80 && self.len() as int + src.len as int <= self.capacity() as int
        ensures self.view() == old(self.view()).concat(src.view())
    {
        let len = self.len();
        let n = src.len;
        ghost let v1 = self.view();
        let p = self.repr.large.ptr;
        unsafe memcpy(unsafe (p + len), src.ptr, n);
        // The block: the first `len` bytes, then the copied ones.
        assert block(self.repr.large.ptr).take(len as int + n as int) == v1.concat(src.view()) by {};
        assert self.storage().take(len as int + n as int) == v1.concat(src.view()) by {};
        self.set_len(len + n);
    }

    // `push_bytes` past the growth, on the inline representation.
    fn append_small(self: &mut String<A>, src: Slice<u8>)
        requires self.repr.small.len < 0x80 && self.len() as int + src.len as int <= self.capacity() as int
        ensures self.view() == old(self.view()).concat(src.view())
    {
        let len = self.len();
        let n = src.len;
        ghost let v1 = self.view();
        let p = (&mut self.repr.small.data[0]) as *mut u8;
        unsafe memcpy(unsafe (p + len), src.ptr, n);
        assert self.storage().take(len as int + n as int) == v1.concat(src.view()) by {};
        self.set_len(len + n);
    }

    /// Append one raw byte.
    pub fn push_byte(self: &mut String<A>, b: u8)
        panics if self.view().len() + 1 >= LARGE_BIT as int
        ensures self.view() == old(self.view()).push(b)
        ensures self.view().len() == old(self.view()).len() + 1
    {
        // The growth keeps the length: read before it.
        let len = self.len();
        self.reserve(1);
        ghost let s1 = self.storage();
        push_view(self.view(), s1, len as int, len as int + 1, b);
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        unsafe p[len] = b;
        assert self.storage() == s1.update(len as int, b) by {};
        self.set_len(len + 1);
    }

    /// Append one Unicode scalar value, UTF-8 encoded into 1-4 bytes.
    pub fn push(self: &mut String<A>, ch: u32)
        panics if self.view().len() + 4 >= LARGE_BIT as int
        ensures self.view() == old(self.view()).concat(utf8(ch))
    {
        if ch < 0x80 {
            concat_one(self.view(), ch as u8);
            self.push_byte(ch as u8);
            return;
        }
        // The encoding, then one append.
        let mut b: [u8; 4] = [0; 4];
        let mut n: usize = 4;
        if ch < 0x800 {
            b[0] = (0xC0 | ch >> 6) as u8;
            b[1] = (0x80 | ch & 0x3F) as u8;
            n = 2;
        } else if ch < 0x10000 {
            b[0] = (0xE0 | ch >> 12) as u8;
            b[1] = (0x80 | ch >> 6 & 0x3F) as u8;
            b[2] = (0x80 | ch & 0x3F) as u8;
            n = 3;
        } else {
            b[0] = (0xF0 | ch >> 18) as u8;
            b[1] = (0x80 | ch >> 12 & 0x3F) as u8;
            b[2] = (0x80 | ch >> 6 & 0x3F) as u8;
            b[3] = (0x80 | ch & 0x3F) as u8;
        }
        let e = b[0..n];
        assert e.view() == utf8(ch) by {};
        self.push_bytes(e);
    }

    /// Append the bytes of a `str` (e.g. a string literal).
    @always_inline
    pub fn push_str(self: &mut String<A>, text: str)
        panics if self.view().len() + text.view().len() >= LARGE_BIT as int
        ensures self.view() == old(self.view()).concat(text.view())
    {
        let b = unsafe Slice::<u8> { ptr: text.ptr(), len: text.len() };
        assert b.view() == text.view() by {};
        self.push_bytes(b);
    }

    /// Append another String's bytes.
    pub fn push_string(self: &mut String<A>, other: &String<A>) {
        self.push_str(other.as_str());
    }

    /// Append the base-10 digits of an unsigned integer: the space for all of them is reserved once, then
    /// the digits are written from the last.
    pub fn push_u64(self: &mut String<A>, value: u64) {
        let mut n: usize = 1;
        let mut v = value;
        // At most 19 steps: a u64 has at most 20 digits.
        while v >= 10 {
            v /= 10;
            n += 1;
        }
        self.reserve(n);
        let len = self.len();
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        let mut x = value;
        for k in 0..n {
            unsafe p[len + n - 1 - k] = (48 + x % 10) as u8;
            x /= 10;
        }
        self.set_len(len + n);
    }

    /// Append the base-10 digits of a signed integer, with a leading '-' when negative. The magnitude is
    /// taken in u64 (`0 - value`) so i64::MIN is handled without overflow.
    pub fn push_i64(self: &mut String<A>, value: i64) {
        if value < 0 {
            self.push_byte(45);
            self.push_u64((value as u64).wrapping_neg());
        } else {
            self.push_u64(value as u64);
        }
    }

    /// Append the base-16 digits of an unsigned integer (no "0x" prefix). `upper` selects A-F vs a-f.
    /// Recurses on the high nibbles so they print first; 0 prints as a single "0".
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
                // 'A' - 10.
                base = 55;
            }
            self.push_byte((base + d) as u8);
        }
    }

    /// Append a signed integer in hex, with a leading '-' on negatives (magnitude in u64, so i64::MIN is safe).
    pub fn push_hex_i64(self: &mut String<A>, value: i64, upper: bool) {
        if value < 0 {
            self.push_byte(45);
            self.push_hex((value as u64).wrapping_neg(), upper);
        } else {
            self.push_hex(value as u64, upper);
        }
    }

    /// Append the base-2 digits of an unsigned integer ('{:b}', no "0b" prefix). 0 prints as "0".
    pub fn push_bin(self: &mut String<A>, value: u64) {
        if value >= 2 {
            self.push_bin(value / 2);
        }
        self.push_byte((48 + value % 2) as u8);
    }

    /// Append a floating-point value with exactly `prec` digits after the decimal point ('{:.N}').
    pub fn push_f64_prec(self: &mut String<A>, value: f64, prec: u32) {
        // A NaN's sign is the machine's (IEEE 754 leaves it open): every NaN prints as `nan`.
        if value != value {
            self.push_str("nan");
            return;
        }
        // Straight into the spare capacity. snprintf reports the full length, so a result that did not fit
        // (with its NUL) is formatted again into a reservation of exactly that size.
        let len = self.len();
        let room = self.capacity() - len;
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        let n = unsafe snprintf((unsafe (p + len)) as *mut char, room, "%.*f", prec as i32, value);
        if n <= 0 {
            return;
        }
        if n as usize >= room {
            self.reserve(n as usize + 1);
            let q = if self.is_large() {
                self.repr.large.ptr
            } else {
                (&mut self.repr.small.data[0]) as *mut u8
            };
            let _ = unsafe snprintf((unsafe (q + len)) as *mut char, n as usize + 1, "%.*f", prec as i32, value);
        }
        self.advance_len(n as usize);
    }

    /// Append `s` in a `width`-byte field padded with `fill` ('{:>8}', '{:08}', '{:^6}').
    /// `align`: 0 = left, 1 = right, 2 = center. A right-aligned zero fill is numeric-aware:
    /// a leading '-' stays in front of the zeros.
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

    /// Pad, in place, the field appended since `from` (a prior `len()`) to `width` bytes: the
    /// no-temporary twin of `push_padded` for values formatted directly into this string: one
    /// reserve, one memmove of the field, then two fills. Same rules: `align` 0 = left, 1 = right,
    /// 2 = center; a right-aligned zero fill keeps a leading '-' in front of the zeros.
    pub fn pad_at(self: &mut String<A>, from: usize, width: usize, fill: u8, align: u8) {
        if from > self.len() {
            panic("String::pad_at: start past the end");
        }
        let n = self.len() - from;
        if width <= n {
            return;
        }
        let pad = width - n;
        self.reserve(pad);
        let mut lead: usize = 0;
        if align == 1 {
            lead = pad;
        } else if align == 2 {
            lead = pad / 2;
        }
        let mut sign: usize = 0;
        if align == 1 && fill == 48 && n > 0 && self.byte(from) == 45 {
            sign = 1;
        }
        self.pad_field(from, n, width, lead, sign, fill);
        self.set_len(from + width);
    }

    // `pad_at`'s writes: the field of `n` bytes at `from` moves `lead` bytes right after its first `sign`
    // bytes, and `fill` takes the `lead` bytes it leaves and the bytes after it up to `from + width`.
    const fn pad_field(self: &mut String<A>, from: usize, n: usize, width: usize, lead: usize, sign: usize, fill: u8)
        requires sign <= n && n as int + lead as int <= width as int && from as int + n as int == self.len() as int
        requires from as int + width as int <= self.capacity() as int
        ensures self.len() == old(self.len()) && self.capacity() == old(self.capacity())
    {
        let p0 = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        let p = unsafe (p0 + from);
        if lead > 0 {
            unsafe memmove(unsafe (p + sign + lead), unsafe (p + sign), n - sign);
        }
        unsafe memset(unsafe (p + sign), fill, lead);
        unsafe memset(unsafe (p + lead + n), fill, width - lead - n);
    }

    /// Append a floating-point value formatted by C's "%g" (compact, round-trip-ish), written straight
    /// into the spare capacity: "%g" needs at most 13 bytes plus the NUL, so the second format never runs.
    pub fn push_f64(self: &mut String<A>, value: f64) {
        // A NaN's sign is the machine's (IEEE 754 leaves it open): every NaN prints as `nan`.
        if value != value {
            self.push_str("nan");
            return;
        }
        // A result that did not fit (with its NUL) is formatted again into a reservation of that size.
        self.reserve(16);
        let len = self.len();
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        let n = unsafe snprintf((unsafe (p + len)) as *mut char, 16, "%g", value);
        if n <= 0 {
            return;
        }
        if n as usize >= 16 {
            self.reserve(n as usize + 1);
            let q = if self.is_large() {
                self.repr.large.ptr
            } else {
                (&mut self.repr.small.data[0]) as *mut u8
            };
            let _ = unsafe snprintf((unsafe (q + len)) as *mut char, n as usize + 1, "%g", value);
        }
        self.advance_len(n as usize);
    }

    /// Insert one byte at index `i`, shifting the tail right. Panics when `i > len`.
    pub fn insert_byte(self: &mut String<A>, i: usize, b: u8)
        panics if i as int > self.view().len() || self.view().len() + 1 >= LARGE_BIT as int
        ensures self.view() == old(self.view()).take(i as int).push(b).concat(old(self.view()).skip(i as int))
    {
        if i > self.len() {
            panic("String::insert_byte: index out of bounds");
        }
        self.reserve(1);
        let len = self.len();
        ghost let v1 = self.view();
        self.shift_right(i, len);
        ghost let s2 = self.storage();
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        unsafe p[i] = b;
        assert self.storage() == s2.update(i as int, b) && len < self.capacity() by {};
        upd_take_out(s2, i as int, i as int, b);
        upd_sub_out(s2, i as int, i as int + 1, len as int + 1, b);
        take_split(self.storage(), i as int, len as int);
        assert self.storage().take(len as int + 1) == v1.take(i as int).push(b).concat(v1.skip(i as int)) by {};
        self.set_len(len + 1);
    }

    // Move bytes `i` to `len` one place right (`insert_byte`'s room): the bytes before `i` stay. One function
    // per representation, each proved alone.
    const fn shift_right(self: &mut String<A>, i: usize, len: usize)
        requires i <= len && len == self.len() && len < self.capacity()
        ensures self.len() == len && self.capacity() == old(self.capacity()) && len as int < self.storage().len()
        ensures self.storage().take(i as int) == old(self.view()).take(i as int)
        ensures self.storage().subrange(i as int + 1, len as int + 1) == old(self.view()).skip(i as int)
    {
        if self.is_large() {
            self.shift_right_large(i, len);
        } else {
            self.shift_right_small(i, len);
        }
    }

    const fn shift_right_large(self: &mut String<A>, i: usize, len: usize)
        requires i <= len && len == self.len() && len < self.capacity() && self.repr.small.len >= 0x80
        ensures self.storage().subrange(i as int + 1, len as int + 1) == old(self.view()).skip(i as int)
        ensures self.storage().take(i as int) == old(self.view()).take(i as int)
        ensures self.len() == len && self.capacity() == old(self.capacity()) && len as int < self.storage().len()
    {
        let p = self.repr.large.ptr;
        unsafe memmove(unsafe (p + i) + 1, unsafe (p + i), len - i);
    }

    const fn shift_right_small(self: &mut String<A>, i: usize, len: usize)
        requires i <= len && len == self.len() && len < self.capacity() && self.repr.small.len < 0x80
        ensures self.len() == len && self.capacity() == old(self.capacity()) && len as int < self.storage().len()
        ensures self.storage().take(i as int) == old(self.view()).take(i as int)
        ensures self.storage().subrange(i as int + 1, len as int + 1) == old(self.view()).skip(i as int)
    {
        let p = (&mut self.repr.small.data[0]) as *mut u8;
        unsafe memmove(unsafe (p + i) + 1, unsafe (p + i), len - i);
    }

    /// Insert a `str` at byte index `i`, shifting the tail right. Panics when `i > len`.
    pub fn insert_str(self: &mut String<A>, i: usize, text: str) {
        if i > self.len() {
            panic("String::insert_str: index out of bounds");
        }
        if text.len() == 0 {
            return;
        }
        self.reserve(text.len());
        let len = self.len();
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        unsafe memmove(unsafe (p + i) + text.len(), unsafe (p + i), len - i);
        unsafe memcpy(unsafe (p + i), text.ptr(), text.len());
        self.set_len(len + text.len());
    }

    // --- remove --------------------------------------------------------------------------------.

    /// Remove and return the last byte, or 0 if the string is empty.
    pub const fn pop_byte(self: &mut String<A>) u8
        ensures |r| old(self.view()).len() == 0 ==> r == 0 && self.view() == old(self.view())
        ensures |r| old(self.view()).len() > 0 ==> r == old(self.view())[old(self.view()).len() - 1] && self.view() == old(self.view()).take(
            old(self.view()).len() - 1,
        )
    {
        let len = self.len();
        if len == 0 {
            return 0;
        }
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        let b = unsafe p[len - 1];
        take_take(self.storage(), len as int, len as int - 1);
        take_at(self.storage(), len as int, len as int - 1);
        self.set_len(len - 1);
        return b;
    }

    /// Remove and return the last UTF-8 scalar value (walking back over continuation bytes), or 0 if
    /// empty: the inverse of `push`.
    pub const fn pop(self: &mut String<A>) u32 {
        let len = self.len();
        if len == 0 {
            return 0;
        }
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        let mut start = len - 1;
        while start > 0 && (unsafe p[start] & 0xC0) == 0x80
            invariant start < len && len == self.len() && len <= self.capacity()
        {
            // Skip 0b10xxxxxx continuation bytes.
            start = start - 1;
        }
        let n = len - start;
        let b0 = (unsafe p[start]) as u32;
        let mut ch: u32 = b0;
        if n == 2 {
            ch = (b0 & 0x1F) << 6 | (unsafe p[start + 1]) as u32 & 0x3F;
        } else if n == 3 {
            ch = (b0 & 0x0F) << 12 | ((unsafe p[start + 1]) as u32 & 0x3F) << 6 | (unsafe p[start + 2]) as u32 & 0x3F;
        } else if n == 4 {
            ch = (b0 & 0x07) << 18 | ((unsafe p[start + 1]) as u32 & 0x3F) << 12 | ((unsafe p[start + 2]) as u32 & 0x3F) << 6 | (unsafe p[start + 3]) as u32 & 0x3F;
        }
        self.set_len(start);
        return ch;
    }

    /// Remove and return the byte at index `i`, shifting the tail left. Panics when `i >= len`.
    pub const fn remove_byte(self: &mut String<A>, i: usize) u8
        panics if i as int >= self.view().len()
        ensures |r| r == old(self.view())[i as int]
        ensures self.view() == old(self.view()).take(i as int).concat(old(self.view()).skip(i as int + 1))
    {
        let len = self.len();
        if i >= len {
            panic("String::remove_byte: index out of bounds");
        }
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        let b = unsafe p[i];
        assert b == self.view()[i as int] by {};
        self.shift_left(i, len);
        take_cat(self.storage(), i as int, len as int - 1);
        self.set_len(len - 1);
        return b;
    }

    // Move bytes `i + 1` to `len` one place left (`remove_byte`'s gap): the bytes before `i` stay.
    const fn shift_left(self: &mut String<A>, i: usize, len: usize)
        requires i < len && len == self.len()
        ensures self.len() == len && self.capacity() == old(self.capacity()) && len as int <= self.storage().len()
        ensures self.storage().take(i as int) == old(self.view()).take(i as int)
        ensures self.storage().subrange(i as int, len as int - 1) == old(self.view()).skip(i as int + 1)
    {
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        ghost let s0 = self.storage();
        assert self.view() == s0.take(len as int) by {};
        unsafe memmove(unsafe (p + i), unsafe (p + i) + 1, len - i - 1);
        assert self.storage().take(i as int) == s0.take(i as int) by {};
        assert self.storage().subrange(i as int, len as int - 1) == s0.subrange(i as int + 1, len as int) by {};
        take_sub(s0, len as int, i as int + 1, len as int);
        take_take(s0, len as int, i as int);
    }

    // --- access --------------------------------------------------------------------------------.

    /// The byte at `i`. Panics when `i >= len`.
    pub const fn byte(self: &String<A>, i: usize) u8 {
        if i >= self.len() {
            panic("String::byte: index out of bounds");
        }
        return unsafe self.as_ptr()[i];
    }

    /// Overwrite the byte at `i`. Panics when `i >= len`.
    pub const fn set_byte(self: &mut String<A>, i: usize, b: u8)
        panics if i as int >= self.view().len()
        ensures self.view() == old(self.view()).update(i as int, b)
    {
        if i >= self.len() {
            panic("String::set_byte: index out of bounds");
        }
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        unsafe p[i] = b;
    }

    /// A read-only pointer to the bytes (inline or heap). See the module-level caveat on small strings.
    pub const fn as_ptr(self: &String<A>) *const u8 {
        if self.is_large() {
            return self.repr.large.ptr;
        }
        return &self.repr.small.data[0];
    }

    /// Raw mutable pointer to the bytes, from the exclusive borrow (`as_ptr`'s never writes); a write keeps
    /// them UTF-8. Invalidated by any reallocating mutation.
    pub const fn as_mut_ptr(self: &mut String<A>) *mut u8
        ensures self.view() == old(self.view()) && self.len() == old(self.len()) && self.capacity() == old(self.capacity())
        ensures self.repr.small.len >= 0x80 == old(self.repr.small.len >= 0x80)
        ensures |r| self.repr.small.len >= 0x80 ==> r == self.repr.large.ptr
        ensures |r| self.repr.small.len < 0x80 ==> r == (&mut self.repr.small.data[0]) as *mut u8
    {
        if self.is_large() {
            return self.repr.large.ptr;
        }
        return &mut self.repr.small.data[0];
    }

    /// Borrowed iterators over the bytes: delegate to the `str` view: valid until the next mutation, and
    /// only while `self` is alive (bind the String to a `let`; do not iterate a temporary's iterator).
    pub const fn bytes(self: &String<A>) Bytes {
        return self.as_str().bytes();
    }

    /// Iterator over the Unicode scalars (assumes valid UTF-8).
    pub const fn chars(self: &String<A>) Chars {
        return self.as_str().chars();
    }

    /// Iterator over the pieces between occurrences of `sep`.
    pub const fn split<'a>(self: &'a String<A>, sep: str<'a>) Split<'a> {
        return self.as_str().split(sep);
    }

    /// Iterator over the lines without their terminators.
    pub const fn lines(self: &String<A>) Lines {
        return self.as_str().lines();
    }

    /// A NUL-terminated `*const char` view of the bytes, for passing to C APIs (the FFI `.cstr()` bridge).
    /// Writes a trailing 0 right past `len` without changing the length, growing by one byte if needed. The
    /// pointer is valid until the next mutation; embedded NULs make C see a truncated string.
    pub fn cstr(self: &mut String<A>) *const char
        panics if self.view().len() + 1 >= LARGE_BIT as int
        ensures self.view() == old(self.view()) && self.len() == old(self.len()) && self.len() < self.capacity()
        ensures |r| self.repr.small.len >= 0x80 ==> r as *const u8 == self.repr.large.ptr as *const u8
        ensures |r| self.repr.small.len < 0x80 ==> r as *const u8 == (&self.repr.small.data[0]) as *const u8
    {
        self.reserve(1);
        let len = self.len();
        ghost let s1 = self.storage();
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        unsafe p[len] = 0;
        assert self.storage() == s1.update(len as int, 0) by {};
        upd_take_out(s1, len as int, len as int, 0);
        return p as *const char;
    }

    /// `cstr` to write in place (a C routine that fills a template, `mkstemp`'s `XXXXXX`); a write keeps the
    /// bytes UTF-8.
    pub fn cstr_mut(self: &mut String<A>) *mut char
        panics if self.view().len() + 1 >= LARGE_BIT as int
        ensures self.view() == old(self.view()) && self.len() == old(self.len()) && self.len() < self.capacity()
        ensures |r| self.repr.small.len >= 0x80 ==> r as *mut u8 == self.repr.large.ptr
        ensures |r| self.repr.small.len < 0x80 ==> r as *mut u8 == (&mut self.repr.small.data[0]) as *mut u8
    {
        let _ = self.cstr();
        return self.as_mut_ptr() as *mut char;
    }

    /// Number of UTF-8 scalar values: every byte that is not a 0b10xxxxxx continuation starts one.
    pub const fn char_count(self: &String<A>) usize {
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

    /// Bytes [start, end) copied into a new owned String (through a copy of this string's allocator).
    /// Panics unless `start <= end <= len`.
    pub fn substring(self: &String<A>, start: usize, end: usize) String<A> {
        if start > end || end > self.len() {
            panic("String::substring: range out of bounds");
        }
        let n = end - start;
        let mut s = String::<A>::with_capacity_in(self.alloc, n);
        if n > 0 {
            let p = if s.is_large() {
                s.repr.large.ptr
            } else {
                (&mut s.repr.small.data[0]) as *mut u8
            };
            unsafe memcpy(p, unsafe (self.as_ptr() + start), n);
            s.set_len(n);
        }
        return s;
    }

    /// `self` repeated `n` times in a freshly allocated String (same allocator).
    pub fn repeat(self: &String<A>, n: usize) String<A> {
        let len = self.len();
        let src = self.as_ptr();
        if n != 0 && len > (LARGE_BIT - 1) / n {
            panic("String::repeat: capacity overflow");
        }
        // One reservation: each append then fits.
        let mut out = String::<A>::with_capacity_in(self.alloc, len * n);
        if len > 0 {
            for _k in 0..n {
                out.push_bytes(unsafe Slice::<u8> { ptr: src, len: len });
            }
        }
        return out;
    }

    // --- compare -------------------------------------------------------------------------------.

    /// Byte equality with another String.
    pub const fn equals(self: &String<A>, other: &String<A>) bool {
        let n = self.len();
        if n != other.len() {
            return false;
        }
        if n == 0 {
            return true;
        }
        return unsafe memcmp(self.as_ptr(), other.as_ptr(), n) == 0;
    }

    /// Byte equality with a `str`.
    pub const fn eq_str(self: &String<A>, text: str) bool {
        let n = self.len();
        if n != text.len() {
            return false;
        }
        if n == 0 {
            return true;
        }
        return unsafe memcmp(self.as_ptr(), text.ptr(), n) == 0;
    }

    /// ASCII-case-insensitive content equality (multibyte bytes must match exactly).
    pub const fn eq_ignore_ascii_case(self: &String<A>, other: &String<A>) bool {
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

    /// True if every byte is ASCII (< 0x80): i.e. no multibyte UTF-8 sequences.
    pub const fn is_ascii(self: &String<A>) bool {
        let n = self.len();
        let p = self.as_ptr();
        for i in 0..n {
            if unsafe p[i] >= 0x80 {
                return false;
            }
        }
        return true;
    }

    // --- search --------------------------------------------------------------------------------.

    /// True when the bytes begin with `prefix`.
    pub const fn starts_with(self: &String<A>, prefix: str) bool {
        if prefix.len() > self.len() {
            return false;
        }
        if prefix.len() == 0 {
            return true;
        }
        return unsafe memcmp(self.as_ptr(), prefix.ptr(), prefix.len()) == 0;
    }

    /// True when the bytes end with `suffix`.
    pub const fn ends_with(self: &String<A>, suffix: str) bool {
        let n = self.len();
        if suffix.len() > n {
            return false;
        }
        if suffix.len() == 0 {
            return true;
        }
        return unsafe memcmp(unsafe (self.as_ptr() + (n - suffix.len())), suffix.ptr(), suffix.len()) == 0;
    }

    /// First index of byte `b`, or `len` (a past-the-end sentinel) if absent.
    pub const fn index_of_byte(self: &String<A>, b: u8) usize {
        let n = self.len();
        let p = self.as_ptr();
        for i in 0..n {
            if unsafe p[i] == b {
                return i;
            }
        }
        return n;
    }

    /// Last index of byte `b`, or `len` if absent.
    pub const fn last_index_of_byte(self: &String<A>, b: u8) usize {
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

    /// True when byte `b` occurs.
    pub const fn contains_byte(self: &String<A>, b: u8) bool {
        return self.index_of_byte(b) < self.len();
    }

    /// Count of (non-overlapping at the byte level) occurrences of byte `b`.
    pub const fn count_byte(self: &String<A>, b: u8) usize {
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

    /// First byte index where `needle` occurs, or `len` if absent (naive O(n*m) window scan).
    pub const fn find(self: &String<A>, needle: str) usize {
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
            if unsafe memcmp(unsafe (p + i), needle.ptr(), needle.len()) == 0 {
                return i;
            }
        }
        return n;
    }

    /// Last byte index where `needle` occurs, or `len` if absent.
    pub const fn rfind(self: &String<A>, needle: str) usize {
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
            if unsafe memcmp(unsafe (p + i), needle.ptr(), needle.len()) == 0 {
                return i;
            }
        }
        return n;
    }

    /// True when `needle` occurs as a substring.
    pub const fn contains(self: &String<A>, needle: str) bool {
        return self.find(needle) != self.len();
    }

    // --- transform & replace -------------------------------------------------------------------.

    /// Uppercase every ASCII letter in place; other bytes untouched.
    pub const fn to_ascii_upper(self: &mut String<A>) {
        let n = self.len();
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        for i in 0..n {
            let b = unsafe p[i];
            if b >= 97 && b <= 122 {
                // 'a'..='z' -> 'A'..='Z'.
                unsafe p[i] = b - 32;
            }
        }
    }

    /// Lowercase every ASCII letter in place; other bytes untouched.
    pub const fn to_ascii_lower(self: &mut String<A>) {
        let n = self.len();
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        for i in 0..n {
            let b = unsafe p[i];
            if b >= 65 && b <= 90 {
                // 'A'..='Z' -> 'a'..='z'.
                unsafe p[i] = b + 32;
            }
        }
    }

    /// Replace every byte equal to `from` with `to`, in place.
    pub const fn replace_byte(self: &mut String<A>, from: u8, to: u8) {
        let n = self.len();
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        for i in 0..n {
            if unsafe p[i] == from {
                unsafe p[i] = to;
            }
        }
    }

    /// A new String (same allocator) with every non-overlapping occurrence of `from` replaced by `to`.
    /// Unmatched runs are copied in bulk (memcpy via push_bytes); only the replacements interrupt the copy.
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
            if unsafe memcmp(unsafe (p + i), from.ptr(), from.len()) == 0 {
                out.push_bytes(unsafe Slice::<u8> { ptr: unsafe (p + run), len: i - run });
                out.push_str(to);
                i = i + from.len();
                run = i;
            } else {
                i = i + 1;
            }
        }
        // Trailing run.
        out.push_bytes(unsafe Slice::<u8> { ptr: unsafe (p + run), len: n - run });
        return out;
    }

    /// Free leading ASCII whitespace (space, tab, newline, carriage return), shifting bytes left.
    pub const fn trim_start(self: &mut String<A>) {
        let len = self.len();
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        let mut start: usize = 0;
        while start < len
            invariant start <= len && len == self.len() && len <= self.capacity()
        {
            let b = unsafe p[start];
            if b != 32 && b != 9 && b != 10 && b != 13 {
                break;
            }
            start = start + 1;
        }
        if start > 0 {
            unsafe memmove(p, unsafe (p + start), len - start);
            self.set_len(len - start);
        }
    }

    /// Free trailing ASCII whitespace.
    pub const fn trim_end(self: &mut String<A>) {
        let p = if self.is_large() {
            self.repr.large.ptr
        } else {
            (&mut self.repr.small.data[0]) as *mut u8
        };
        let mut len = self.len();
        while len > 0
            invariant len <= self.len() && self.len() <= self.capacity()
        {
            let b = unsafe p[len - 1];
            if b != 32 && b != 9 && b != 10 && b != 13 {
                break;
            }
            len = len - 1;
        }
        self.set_len(len);
    }

    /// Free ASCII whitespace from both ends.
    pub const fn trim(self: &mut String<A>) {
        self.trim_end();
        self.trim_start();
    }

    // --- output --------------------------------------------------------------------------------.

    /// Write the UTF-8 bytes to stdout (no trailing newline).
    pub fn print(self: &String<A>) {
        unsafe fwrite(self.as_ptr(), 1, self.len(), std_out());
    }

    /// Write the bytes plus a newline to stdout.
    pub fn println(self: &String<A>) {
        self.print();
        unsafe putchar(10);
    }

    /// Write the UTF-8 bytes to stderr (no trailing newline): the `eprint`/`eprintln` builtins' writer.
    pub fn eprint(self: &String<A>) {
        unsafe fwrite(self.as_ptr(), 1, self.len(), std_err());
    }

    /// Write the bytes plus a newline to stderr.
    pub fn eprintln(self: &String<A>) {
        self.eprint();
        unsafe fputc(10, std_err());
    }
}

extend<A: Allocator + Default> String<A> {
    /// An empty string (default-constructed allocator: `Global`, or any zero-sized/reconstructible tag).
    pub fn new() String<A>
        ensures |r| r.view() == Seq::<u8>::empty()
    {
        return String::<A>::new_in(A::default());
    }

    /// Pre-size for `cap` bytes (default allocator). Up to SSO_CAP stay inline (no allocation); more allocates.
    pub fn with_capacity(cap: usize) String<A>
        panics if cap > SSO_CAP && cap >= LARGE_BIT
        ensures |r| r.len() == 0 && r.capacity() >= cap && r.view() == Seq::<u8>::empty()
    {
        return String::<A>::with_capacity_in(A::default(), cap);
    }

    /// A new string (default allocator) holding a copy of `text`'s bytes.
    pub fn from_str(text: str) String<A> {
        return String::<A>::from_str_in(A::default(), text);
    }

    /// A new string copied from a NUL-terminated C string (the inverse of `cstr`), for FFI return values
    /// such as `getenv`/`strerror`. Copies up to the first NUL. Unsafe: the caller promises a
    /// NUL-terminated string at `s`.
    pub unsafe fn from_cstr(s: *const char) String<A> {
        let n = strlen(s);
        let mut out = String::<A>::with_capacity(n);
        out.push_bytes(unsafe Slice::<u8> { ptr: s as *const u8, len: n });
        return out;
    }

    /// Build a fresh String (default allocator) from an unsigned / signed integer or a float.
    pub fn from_u64(value: u64) String<A> {
        let mut s = String::<A>::new();
        s.push_u64(value);
        return s;
    }
    /// The decimal spelling of `value`.
    pub fn from_i64(value: i64) String<A> {
        let mut s = String::<A>::new();
        s.push_i64(value);
        return s;
    }
    /// The default spelling of `value` (see push_f64).
    pub fn from_f64(value: f64) String<A> {
        let mut s = String::<A>::new();
        s.push_f64(value);
        return s;
    }
    /// The hexadecimal spelling of `value`, without a prefix; `upper` selects A-F.
    pub fn from_hex(value: u64, upper: bool) String<A> {
        let mut s = String::<A>::new();
        s.push_hex(value, upper);
        return s;
    }
}

// Release the heap buffer (through the STORED allocator) and reset to the empty, inline state. Auto-`Free`:
// a `String` is freed at scope exit (unless moved out or freed explicitly). This is sound because every
// `String`-returning method here (`clone`/`substring`/`replace`/`repeat`) allocates a FRESH buffer: none
// hands out a copy that shares the heap pointer, so no aliased owner ever exists to double-free.
extend<A: Allocator> String<A> as Free {
    pub fn free(self: &mut String<A>) {
        if self.is_large() {
            unsafe self.alloc.dealloc(self.repr.large.ptr, self.capacity(), 1);
        }
        // Back to inline, empty (clears the discriminant).
        self.repr.small.len = 0;
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
    /// The bytes and terminator `str::hash_into` feeds, so an equal `str` and `String` hash alike.
    pub fn hash_into<H: Hasher>(self: &String<A>, h: &mut H) {
        self.as_str().hash_into(h);
    }
}

extend<A: Allocator> String<A> as Ord {
    /// Lexicographic byte order; shorter is less when one is a prefix of the other.
    pub fn cmp(self: &String<A>, other: &String<A>) i32 {
        let la = self.len();
        let lb = other.len();
        let mut n = la;
        if lb < la {
            n = lb;
        }
        let c = unsafe memcmp(self.as_ptr(), other.as_ptr(), n);
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
    /// A deep copy: an independent value with the same contents, through a copy of this string's allocator
    /// (inline copies need no allocation).
    pub fn clone(self: &String<A>) String<A> {
        let n = self.len();
        let mut s = String::<A>::with_capacity_in(self.alloc, n);
        if n > 0 {
            let p = if s.is_large() {
                s.repr.large.ptr
            } else {
                (&mut s.repr.small.data[0]) as *mut u8
            };
            unsafe memcpy(p, self.as_ptr(), n);
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
    /// Append the bytes: always `Ok(bytes.len())`, the buffer grows on demand.
    pub fn write(self: &mut String<A>, bytes: []u8) Result<usize, IoError> {
        self.push_bytes(bytes);
        return Ok(bytes.len());
    }
}

// Index conformance: `s[i]` borrows the byte at `i`, and `s[lo..hi]`; any range form, `..=` including
// the end byte, an open end meaning `len()`: is a borrowed `str` sub-view (valid until the next
// mutation, like `as_str`). Byte-addressed: bounds past `len` panic, and the caller keeps them on UTF-8
// boundaries. No IndexMut: bytes are mutated through the growing/UTF-8-aware String API.
extend<A: Allocator> String<A> as Index<u8, str> {
    pub fn index(self: &String<A>, i: usize) &u8 {
        if i >= self.len() {
            panic_parts(type_info::<Self>().qualified_name, "[i]: index out of bounds");
        }
        let p = if self.is_large() {
            self.repr.large.ptr as *const u8
        } else {
            (&self.repr.small.data[0]) as *const u8
        };
        return &unsafe p[i];
    }
    pub fn index_range(self: &String<A>, r: Range<usize>) str {
        if r.inclusive && r.end >= self.len() {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        let hi = if r.inclusive {
            r.end + 1
        } else {
            r.end
        };
        if r.start > hi || hi > self.len() {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        return self.as_str().slice(r.start, hi);
    }
}

/// Formatted output, compiler builtins. The first argument is a string literal with `{}` placeholders; the
/// trailing arguments fill them in order and are appended by their type (any integer/float, bool, char, str,
/// String, or any `Format` type). `{{`/`}}` are literal braces. `format` returns the built String; `print`
/// writes it to stdout; `println` adds a trailing newline. (Bodies are stubs: the typechecker rewrites a
/// `format` call into `sugar_fmt_*` shim calls, so it const-folds; the print family is lowered by codegen.)
pub fn format(_fmt: str, ...) String {
    return String::<Global>::new();
}
/// Formatted print to stdout; the compiler lowers calls, this body is never run.
pub fn print(_fmt: str, ...) {}
pub fn println(_fmt: str, ...) {}
/// Formatted print to stderr; the compiler lowers calls, this body is never run.
pub fn eprint(_fmt: str, ...) {} // like print/println, written to stderr
pub fn eprintln(_fmt: str, ...) {}

/// The print family's desugar tails: consume the rendered buffer (write, then free) so the
/// checker-built sugar block owns no live String at its end.
pub fn sugar_print(f: String) {
    f.print();
}
/// `println` shim: prints the formatted String plus newline to stdout and consumes it.
pub fn sugar_println(f: String) {
    f.println();
}
/// `eprint` shim: prints the formatted String to stderr and consumes it.
pub fn sugar_eprint(f: String) {
    f.eprint();
}
/// `eprintln` shim: prints the formatted String plus newline to stderr and consumes it.
pub fn sugar_eprintln(f: String) {
    f.eprintln();
}
/// `format_into`'s desugar tail: append the rendered piece into the destination buffer, consuming it.
pub fn sugar_format_into(dst: &mut String, f: String) {
    dst.push_string(&f);
}

// Like `format`, but APPENDS the rendered output into this buffer instead of returning a new String:
// zero allocation (reuses the buffer's capacity). It is a METHOD so the receiver's `&mut` borrow defers
// past the argument evaluation (a free-fn `&mut dst` arg would collide with `self.X` format args).
// Lowered by codegen; this body is never emitted.
extend<A: Allocator> String<A> {
    /// Formatted append; the compiler lowers calls, this body is never run.
    pub fn format_into(self: &mut String<A>, _fmt: str, ...) {}
}

/// The typechecker rewrites every `format(..)` call into a block of assignments through these
/// shims (`f = sugar_fmt_i64(f, v);`) so the result const-folds like ordinary code. The String
/// threads BY VALUE (move in, move out): statements keep C's evaluation order strict, and a padded
/// placeholder reuses the same shims to render its piece as one nested expression, so no second
/// local is ever needed. Each value parameter's type is what the widening rules let every dispatched
/// source type reach implicitly (the rewrite synthesizes no casts). Not meant to be called by hand.
pub fn sugar_fmt_new() String {
    return String::<Global>::new();
}
/// Matchertext interpolation guard: a hole's rendered piece must itself be matchertext; the
/// ASCII matchers (), [], {} must properly match, so no runtime value can break out of the
/// literal's structure (each compliant piece keeps the whole result compliant, and matching can
/// never complete ACROSS holes). Byte-level scan: matchers are ASCII, every other byte passes
/// through uninspected. Panics on violation; in a const context the panic fails the fold instead.
pub fn sugar_mt_splice(mut s: String, piece: String) String {
    let v = piece.as_str();
    let mut st = Vector::<u8>::new();
    let mut ok = true;
    for i in 0..v.len() {
        let b = v[i];
        if b == b'(' || b == b'[' || b == b'{' {
            st.push(b);
        } else if b == b')' || b == b']' || b == b'}' {
            let need = if b == b')' {
                b'('
            } else if b == b']' {
                b'['
            } else {
                b'{'
            };
            if st.len() == 0 || st.pop().unwrap() != need {
                ok = false;
                break;
            }
        }
    }
    if !ok || st.len() != 0 {
        panic("matchertext interpolation: value is not matchertext (unmatched ASCII matcher)");
    }
    s.push_string(&piece);
    return s;
}
/// `format` shim: appends a `str` to `s` and returns it.
pub fn sugar_fmt_str(mut s: String, v: str) String {
    s.push_str(v);
    return s;
}
/// `format` shim: appends a borrowed String to `s` and returns it.
pub fn sugar_fmt_string(mut s: String, v: &String) String {
    s.push_string(v);
    return s;
}
/// `format` shim: appends an owned String (consumed) to `s` and returns it.
pub fn sugar_fmt_owned(mut s: String, v: String) String {
    s.push_string(&v);
    return s;
}
/// `format` shim: appends a signed integer in decimal to `s` and returns it.
pub fn sugar_fmt_i64(mut s: String, v: i64) String {
    s.push_i64(v);
    return s;
}
/// `format` shim: appends an unsigned integer in decimal to `s` and returns it.
pub fn sugar_fmt_u64(mut s: String, v: u64) String {
    s.push_u64(v);
    return s;
}
/// Isize/usize have no implicit widening (their width is platform-dependent), so they get their own
/// shims; same for their hex/bin forms below.
pub fn sugar_fmt_isize(mut s: String, v: isize) String {
    s.push_i64(v as i64);
    return s;
}
/// `format` shim: appends a usize in decimal to `s` and returns it.
pub fn sugar_fmt_usize(mut s: String, v: usize) String {
    s.push_u64(v as u64);
    return s;
}
/// `format` shim: appends an f64 with the default precision to `s` and returns it.
pub fn sugar_fmt_f64(mut s: String, v: f64) String {
    s.push_f64(v);
    return s;
}
/// `format` shim: appends an f64 with `prec` fractional digits to `s` and returns it.
pub fn sugar_fmt_f64_prec(mut s: String, v: f64, prec: u32) String {
    s.push_f64_prec(v, prec);
    return s;
}
/// `format` shim: appends `true`/`false` to `s` and returns it.
pub fn sugar_fmt_bool(mut s: String, v: bool) String {
    if v {
        s.push_str("true");
    } else {
        s.push_str("false");
    }
    return s;
}
/// `format` shim: appends a char as one byte to `s` and returns it.
pub fn sugar_fmt_char(mut s: String, v: char) String {
    s.push_byte(v as u8);
    return s;
}
/// `format` shim: appends a signed integer in lowercase hex to `s` and returns it.
pub fn sugar_fmt_hex_i(mut s: String, v: i64) String {
    s.push_hex_i64(v, false);
    return s;
}
/// `format` shim: appends a signed integer in uppercase hex to `s` and returns it.
pub fn sugar_fmt_hex_i_up(mut s: String, v: i64) String {
    s.push_hex_i64(v, true);
    return s;
}
/// `format` shim: appends an unsigned integer in lowercase hex to `s` and returns it.
pub fn sugar_fmt_hex_u(mut s: String, v: u64) String {
    s.push_hex(v, false);
    return s;
}
/// `format` shim: appends an unsigned integer in uppercase hex to `s` and returns it.
pub fn sugar_fmt_hex_u_up(mut s: String, v: u64) String {
    s.push_hex(v, true);
    return s;
}
/// `format` shim: appends a char in lowercase hex to `s` and returns it.
pub fn sugar_fmt_hex_c(mut s: String, v: char) String {
    s.push_hex(v as u64, false);
    return s;
}
/// `format` shim: appends a char in uppercase hex to `s` and returns it.
pub fn sugar_fmt_hex_c_up(mut s: String, v: char) String {
    s.push_hex(v as u64, true);
    return s;
}
/// `format` shim: appends an isize in lowercase hex to `s` and returns it.
pub fn sugar_fmt_hex_is(mut s: String, v: isize) String {
    s.push_hex_i64(v as i64, false);
    return s;
}
/// `format` shim: appends an isize in uppercase hex to `s` and returns it.
pub fn sugar_fmt_hex_is_up(mut s: String, v: isize) String {
    s.push_hex_i64(v as i64, true);
    return s;
}
/// `format` shim: appends a usize in lowercase hex to `s` and returns it.
pub fn sugar_fmt_hex_us(mut s: String, v: usize) String {
    s.push_hex(v as u64, false);
    return s;
}
/// `format` shim: appends a usize in uppercase hex to `s` and returns it.
pub fn sugar_fmt_hex_us_up(mut s: String, v: usize) String {
    s.push_hex(v as u64, true);
    return s;
}
/// `{:b}` renders at the ARGUMENT's width (an i8 shows 8 digits), so one shim per width; the sub-64
/// ones take i64 because every narrower integer, signed or not, widens to it losslessly.
pub fn sugar_fmt_bin8(mut s: String, v: i64) String {
    s.push_bin((v & 0xFF) as u64);
    return s;
}
/// `format` shim: appends the low 16 bits in binary to `s` and returns it.
pub fn sugar_fmt_bin16(mut s: String, v: i64) String {
    s.push_bin((v & 0xFFFF) as u64);
    return s;
}
/// `format` shim: appends the low 32 bits in binary to `s` and returns it.
pub fn sugar_fmt_bin32(mut s: String, v: i64) String {
    s.push_bin((v & 0xFFFFFFFF) as u64);
    return s;
}
/// `format` shim: appends a signed integer's 64 bits in binary to `s` and returns it.
pub fn sugar_fmt_bin64i(mut s: String, v: i64) String {
    s.push_bin(v as u64);
    return s;
}
/// `format` shim: appends an unsigned integer in binary to `s` and returns it.
pub fn sugar_fmt_bin64u(mut s: String, v: u64) String {
    s.push_bin(v);
    return s;
}
/// `format` shim: appends a char in binary to `s` and returns it.
pub fn sugar_fmt_bin_c(mut s: String, v: char) String {
    s.push_bin(v as u64);
    return s;
}
/// `format` shim: appends an isize in binary to `s` and returns it.
pub fn sugar_fmt_bin_is(mut s: String, v: isize) String {
    s.push_bin((v as i64) as u64);
    return s;
}
/// `format` shim: appends a usize in binary to `s` and returns it.
pub fn sugar_fmt_bin_us(mut s: String, v: usize) String {
    s.push_bin(v as u64);
    return s;
}
/// `format` shim: appends a `Format` value through its `fmt` to `s` and returns it.
pub fn sugar_fmt_val<T: Format>(mut s: String, v: &T) String {
    let r = v.fmt();
    s.push_string(&r);
    return s;
}
/// `format` shim: appends an owned `Format` value (consumed) through its `fmt` to `s` and returns it.
pub fn sugar_fmt_val_owned<T: Format>(mut s: String, v: T) String {
    let r = v.fmt();
    s.push_string(&r);
    return s;
}
/// Width padding: `piece` is the placeholder rendered on its own (by the shims above, on a fresh
/// String: SSO keeps short pieces off the heap); it lands in `s` filled up to `width` with
/// `fill`'s first byte (space when empty: the spec had no fill character to point at).
pub fn sugar_fmt_pad_l(mut s: String, piece: String, width: usize, fill: str) String {
    let from = s.len();
    s.push_string(&piece);
    s.pad_at(from, width, sugar_fill_byte(fill), 0u8);
    return s;
}
/// `format` shim: appends `piece` right-aligned in `width` columns, padded with `fill`.
pub fn sugar_fmt_pad_r(mut s: String, piece: String, width: usize, fill: str) String {
    let from = s.len();
    s.push_string(&piece);
    s.pad_at(from, width, sugar_fill_byte(fill), 1u8);
    return s;
}
/// `format` shim: appends `piece` centered in `width` columns, padded with `fill`.
pub fn sugar_fmt_pad_c(mut s: String, piece: String, width: usize, fill: str) String {
    let from = s.len();
    s.push_string(&piece);
    s.pad_at(from, width, sugar_fill_byte(fill), 2u8);
    return s;
}
const fn sugar_fill_byte(fill: str) u8 {
    if fill.len() == 0 {
        return b' ';
    }
    return fill[0];
}

extend<A: Allocator> String<A> as AsStr {
    /// The bytes as a borrowed `str` view: valid until the next mutation and, for a small string, until a move.
    pub const fn as_str(self: &String<A>) str {
        return unsafe str::from_raw(self.as_ptr(), self.len());
    }
}
