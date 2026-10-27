// Volatile memory access and zeroization. Each volatile access reaches memory exactly once and in
// program order relative to every other volatile access, whatever the compiler knows about the
// location; at compile time it is an ordinary load or store.

@intrinsic("mem.volatile_load")
unsafe const fn volatile_load<T>(p: *const T) T;

@intrinsic("mem.volatile_store")
unsafe const fn volatile_store<T>(p: *mut T, v: T);

/// The value at `p`, read with one volatile access: no compiler pass removes the read, merges it with
/// another access, or moves it across another volatile access.
/// Safety: `p` is non-null, aligned for `T`, and points to an initialized `T`.
pub unsafe const fn read_volatile<T: Copy>(p: *const T) T {
    return unsafe volatile_load(p);
}

/// Store `v` at `p` with one volatile access, with the guarantees of `read_volatile`.
/// Safety: `p` is non-null, aligned for `T`, and valid for writes of a `T`.
pub unsafe const fn write_volatile<T: Copy>(p: *mut T, v: T) {
    unsafe volatile_store(p, v);
}

/// Overwrite every byte of `buf` with zero, also when nothing reads `buf` afterwards (a key or a
/// password that goes out of scope): the stores are volatile and a compiler memory fence follows them.
/// Covers the bytes of `buf` only: a copy made earlier (a move of the value, a register spilled to the
/// stack) keeps its contents.
pub fn zeroize(buf: []mut u8) {
    unsafe zeroize_raw(buf.ptr, buf.len);
}

/// `zeroize` over the `n` bytes at `p`: volatile byte stores up to the first word boundary, volatile
/// word stores, then byte stores for the tail, and a compiler memory fence.
/// Safety: `p` is valid for writes of `n` bytes; any pointer when `n` is 0.
pub unsafe fn zeroize_raw(p: *mut u8, n: usize) {
    let w = sizeof(usize);
    let mut i: usize = 0;
    unsafe {
        while i < n && (p + i) as usize % w != 0 {
            volatile_store(p + i, 0u8);
            i += 1;
        }
        while n - i >= w {
            volatile_store((p + i) as *mut usize, 0usize);
            i += w;
        }
        while i < n {
            volatile_store(p + i, 0u8);
            i += 1;
        }
        sc_sys_barrier();
    }
}

// A compiler memory barrier (`lir::ir::SYS_BARRIER`).
extern "C" {
    fn sc_sys_barrier();
}
