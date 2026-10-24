// Byte-order reads and writes of builtin scalars in byte slices (Go's `encoding/binary` LittleEndian and
// BigEndian, Odin's `core:encoding/endian`, C++ `std::byteswap` over `std::memcpy`): one generic API over
// the sealed interface `EndianScalar`, which `u8` to `u64`, `i8` to `i64`, `usize`, `isize`, `f32` and
// `f64` implement.
//
// A read or write at byte offset `off` checks the bounds once and then moves the value with one unaligned
// load or store, plus one byte swap when the order differs from the target's `ENDIAN`. The plain forms
// panic when the slice is too short (a contract violation); `try_read_le` and `try_read_be` return
// `None` for untrusted input. A float keeps its exact bits, NaN payloads included. Every operation is
// O(1); only `append_le` and `append_be` allocate, through the vector's allocator, amortized O(1). The
// functions are pure over their arguments and safe from every thread. Import with
// `import std::mem::endian;`.

import std::mem::ptr;

/// A builtin scalar that the byte-order functions read and write: `u8` to `u64`, `i8` to `i64`, `usize`,
/// `isize`, `f32` and `f64`. Only `std` implements it.
pub interface EndianScalar: Copy {
    /// The value with its bytes in reverse order (C++ `std::byteswap`; the bits of a float).
    fn swap_bytes(self: Self) Self;
}

// The value in little-endian byte order, from or to the target's order.
@always_inline
fn to_le<T: EndianScalar>(x: T) T {
    if ENDIAN == Endian::Big {
        return x.swap_bytes();
    }
    return x;
}

// The value in big-endian byte order, from or to the target's order.
@always_inline
fn to_be<T: EndianScalar>(x: T) T {
    if ENDIAN == Endian::Little {
        return x.swap_bytes();
    }
    return x;
}

// True when `n` bytes at `off` are inside a slice of `len` bytes. `n` is a constant at every call, so
// `len - n` is the only subtraction and cannot wrap.
@always_inline
const fn fits(len: usize, off: usize, n: usize) bool {
    return n <= len && off <= len - n;
}

/// The little-endian `T` at byte offset `off` of `b`. Panics: fewer than `sizeof(T)` bytes from `off`.
pub fn read_le<T: EndianScalar>(b: []u8, off: usize) T {
    if !fits(b.len(), off, sizeof(T)) {
        panic("endian: read past the end of the slice");
    }
    return to_le(unsafe ptr::read_unaligned::<T>(b.as_ptr() + off));
}

/// The big-endian `T` at byte offset `off` of `b`. Panics: fewer than `sizeof(T)` bytes from `off`.
pub fn read_be<T: EndianScalar>(b: []u8, off: usize) T {
    if !fits(b.len(), off, sizeof(T)) {
        panic("endian: read past the end of the slice");
    }
    return to_be(unsafe ptr::read_unaligned::<T>(b.as_ptr() + off));
}

/// The little-endian `T` at byte offset `off` of `b`, or `None` when fewer than `sizeof(T)` bytes follow
/// `off`.
pub fn try_read_le<T: EndianScalar>(b: []u8, off: usize) Option<T> {
    if !fits(b.len(), off, sizeof(T)) {
        return Option::<T>::None;
    }
    return Option::<T>::Some(to_le(unsafe ptr::read_unaligned::<T>(b.as_ptr() + off)));
}

/// The big-endian `T` at byte offset `off` of `b`, or `None` when fewer than `sizeof(T)` bytes follow
/// `off`.
pub fn try_read_be<T: EndianScalar>(b: []u8, off: usize) Option<T> {
    if !fits(b.len(), off, sizeof(T)) {
        return Option::<T>::None;
    }
    return Option::<T>::Some(to_be(unsafe ptr::read_unaligned::<T>(b.as_ptr() + off)));
}

/// Store `v` little-endian at byte offset `off` of `b`. Panics: fewer than `sizeof(T)` bytes from `off`.
pub const fn write_le<T: EndianScalar>(b: []mut u8, off: usize, v: T) {
    if !fits(b.len(), off, sizeof(T)) {
        panic("endian: write past the end of the slice");
    }
    unsafe ptr::write_unaligned::<T>(b.as_mut_ptr() + off, to_le(v));
}

/// Store `v` big-endian at byte offset `off` of `b`. Panics: fewer than `sizeof(T)` bytes from `off`.
pub fn write_be<T: EndianScalar>(b: []mut u8, off: usize, v: T) {
    if !fits(b.len(), off, sizeof(T)) {
        panic("endian: write past the end of the slice");
    }
    unsafe ptr::write_unaligned::<T>(b.as_mut_ptr() + off, to_be(v));
}

/// Append the `sizeof(T)` little-endian bytes of `x` to `v`. Amortized O(1); grows `v` through its
/// allocator.
pub fn append_le<T: EndianScalar, A: Allocator>(v: &mut Vector<u8, A>, x: T) {
    let y = to_le(x);
    v.extend_from_slice(unsafe Slice::<u8> { ptr: ((&y) as *const T) as *const u8, len: sizeof(T) });
}

/// Append the `sizeof(T)` big-endian bytes of `x` to `v`. Amortized O(1); grows `v` through its
/// allocator.
pub fn append_be<T: EndianScalar, A: Allocator>(v: &mut Vector<u8, A>, x: T) {
    let y = to_be(x);
    v.extend_from_slice(unsafe Slice::<u8> { ptr: ((&y) as *const T) as *const u8, len: sizeof(T) });
}

// The byte swaps are shift-and-mask forms that C compilers turn into one `bswap` (x86_64) or `rev`
// (aarch64) instruction.

extend u8 as EndianScalar {
    pub fn swap_bytes(self: u8) u8 {
        return self;
    }
}

extend u16 as EndianScalar {
    pub fn swap_bytes(self: u16) u16 {
        return self << 8 | self >> 8;
    }
}

extend u32 as EndianScalar {
    pub fn swap_bytes(self: u32) u32 {
        return self << 24 | (self & 0xFF00) << 8 | self >> 8 & 0xFF00 | self >> 24;
    }
}

extend u64 as EndianScalar {
    pub fn swap_bytes(self: u64) u64 {
        let mut v = self << 32 | self >> 32;
        v = (v & 0x0000FFFF0000FFFF) << 16 | v >> 16 & 0x0000FFFF0000FFFF;
        return (v & 0x00FF00FF00FF00FF) << 8 | v >> 8 & 0x00FF00FF00FF00FF;
    }
}

extend usize as EndianScalar {
    pub fn swap_bytes(self: usize) usize {
        if POINTER_WIDTH == 64 {
            return (self as u64).swap_bytes() as usize;
        }
        return (self as u32).swap_bytes() as usize;
    }
}

extend i8 as EndianScalar {
    pub fn swap_bytes(self: i8) i8 {
        return self;
    }
}

extend i16 as EndianScalar {
    pub fn swap_bytes(self: i16) i16 {
        return (self as u16).swap_bytes() as i16;
    }
}

extend i32 as EndianScalar {
    pub fn swap_bytes(self: i32) i32 {
        return (self as u32).swap_bytes() as i32;
    }
}

extend i64 as EndianScalar {
    pub fn swap_bytes(self: i64) i64 {
        return (self as u64).swap_bytes() as i64;
    }
}

extend isize as EndianScalar {
    pub fn swap_bytes(self: isize) isize {
        return (self as usize).swap_bytes() as isize;
    }
}

// A float swaps as its bits: no float operation runs, so a NaN keeps its payload.
extend f32 as EndianScalar {
    pub fn swap_bytes(self: f32) f32 {
        return ptr::bit_cast::<f32, u32>(ptr::bit_cast::<u32, f32>(self).swap_bytes());
    }
}

extend f64 as EndianScalar {
    pub fn swap_bytes(self: f64) f64 {
        return ptr::bit_cast::<f64, u64>(ptr::bit_cast::<u64, f64>(self).swap_bytes());
    }
}
