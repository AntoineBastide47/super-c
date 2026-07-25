// Typed sequentially-consistent atomics. `Atomic<T>` wraps a plain `T` cell and drives the compiler's
// `__sc_atomic_*` builtins (through `ffi/atomic.spc`) so reads, writes and read-modify-write operations on
// it are indivisible across threads. Import with `import std::parallel::atomic;`.
//
// `T` must be an integer builtin (it conforms to `AtomicOps` below). The value is stored unwrapped, so an
// `Atomic<T>` is exactly `sizeof(T)` and can be shared by raw pointer or through an `Arc`.

import atomic;

/// The per-type atomic primitives, one thin conformance per integer builtin. Not implemented by hand for
/// user types: only the builtins the runtime provides `__sc_atomic_*` for can be atomic.
pub interface AtomicOps {
    fn atomic_load(p: *const Self) Self;
    fn atomic_store(p: *mut Self, v: Self);
    fn atomic_swap(p: *mut Self, v: Self) Self;
    fn atomic_add(p: *mut Self, v: Self) Self;
    fn atomic_sub(p: *mut Self, v: Self) Self;
    fn atomic_cas(p: *mut Self, expected: Self, desired: Self) bool;
}

extend i32 as AtomicOps {
    fn atomic_load(p: *const i32) i32 {
        return atomic::load_i32(p);
    }
    fn atomic_store(p: *mut i32, v: i32) {
        atomic::store_i32(p, v);
    }
    fn atomic_swap(p: *mut i32, v: i32) i32 {
        return atomic::swap_i32(p, v);
    }
    fn atomic_add(p: *mut i32, v: i32) i32 {
        return atomic::add_i32(p, v);
    }
    fn atomic_sub(p: *mut i32, v: i32) i32 {
        return atomic::sub_i32(p, v);
    }
    fn atomic_cas(p: *mut i32, expected: i32, desired: i32) bool {
        return atomic::cas_i32(p, expected, desired);
    }
}

extend i64 as AtomicOps {
    fn atomic_load(p: *const i64) i64 {
        return atomic::load_i64(p);
    }
    fn atomic_store(p: *mut i64, v: i64) {
        atomic::store_i64(p, v);
    }
    fn atomic_swap(p: *mut i64, v: i64) i64 {
        return atomic::swap_i64(p, v);
    }
    fn atomic_add(p: *mut i64, v: i64) i64 {
        return atomic::add_i64(p, v);
    }
    fn atomic_sub(p: *mut i64, v: i64) i64 {
        return atomic::sub_i64(p, v);
    }
    fn atomic_cas(p: *mut i64, expected: i64, desired: i64) bool {
        return atomic::cas_i64(p, expected, desired);
    }
}

extend u32 as AtomicOps {
    fn atomic_load(p: *const u32) u32 {
        return atomic::load_u32(p);
    }
    fn atomic_store(p: *mut u32, v: u32) {
        atomic::store_u32(p, v);
    }
    fn atomic_swap(p: *mut u32, v: u32) u32 {
        return atomic::swap_u32(p, v);
    }
    fn atomic_add(p: *mut u32, v: u32) u32 {
        return atomic::add_u32(p, v);
    }
    fn atomic_sub(p: *mut u32, v: u32) u32 {
        return atomic::sub_u32(p, v);
    }
    fn atomic_cas(p: *mut u32, expected: u32, desired: u32) bool {
        return atomic::cas_u32(p, expected, desired);
    }
}

extend u64 as AtomicOps {
    fn atomic_load(p: *const u64) u64 {
        return atomic::load_u64(p);
    }
    fn atomic_store(p: *mut u64, v: u64) {
        atomic::store_u64(p, v);
    }
    fn atomic_swap(p: *mut u64, v: u64) u64 {
        return atomic::swap_u64(p, v);
    }
    fn atomic_add(p: *mut u64, v: u64) u64 {
        return atomic::add_u64(p, v);
    }
    fn atomic_sub(p: *mut u64, v: u64) u64 {
        return atomic::sub_u64(p, v);
    }
    fn atomic_cas(p: *mut u64, expected: u64, desired: u64) bool {
        return atomic::cas_u64(p, expected, desired);
    }
}

extend usize as AtomicOps {
    fn atomic_load(p: *const usize) usize {
        return atomic::load_usize(p);
    }
    fn atomic_store(p: *mut usize, v: usize) {
        atomic::store_usize(p, v);
    }
    fn atomic_swap(p: *mut usize, v: usize) usize {
        return atomic::swap_usize(p, v);
    }
    fn atomic_add(p: *mut usize, v: usize) usize {
        return atomic::add_usize(p, v);
    }
    fn atomic_sub(p: *mut usize, v: usize) usize {
        return atomic::sub_usize(p, v);
    }
    fn atomic_cas(p: *mut usize, expected: usize, desired: usize) bool {
        return atomic::cas_usize(p, expected, desired);
    }
}

extend isize as AtomicOps {
    fn atomic_load(p: *const isize) isize {
        return atomic::load_isize(p);
    }
    fn atomic_store(p: *mut isize, v: isize) {
        atomic::store_isize(p, v);
    }
    fn atomic_swap(p: *mut isize, v: isize) isize {
        return atomic::swap_isize(p, v);
    }
    fn atomic_add(p: *mut isize, v: isize) isize {
        return atomic::add_isize(p, v);
    }
    fn atomic_sub(p: *mut isize, v: isize) isize {
        return atomic::sub_isize(p, v);
    }
    fn atomic_cas(p: *mut isize, expected: isize, desired: isize) bool {
        return atomic::cas_isize(p, expected, desired);
    }
}

/// An atomic integer cell. Every operation is sequentially consistent. The cell holds `T` unwrapped, so its
/// address can be handed to other threads (through a raw pointer or an `Arc`) and mutated concurrently.
pub struct Atomic<T: AtomicOps> {
    value: T,
}

extend<T: AtomicOps> Atomic<T> {
    /// A cell initialised to `v`.
    pub fn new(v: T) Atomic<T> {
        return Atomic::<T> { value: v };
    }
    /// Atomically read the current value.
    pub fn load(self: &Atomic<T>) T {
        return T::atomic_load(&self.value);
    }
    /// Atomically overwrite the value.
    pub fn store(self: &mut Atomic<T>, v: T) {
        T::atomic_store(&mut self.value, v);
    }
    /// Atomically overwrite the value, returning the previous one.
    pub fn swap(self: &mut Atomic<T>, v: T) T {
        return T::atomic_swap(&mut self.value, v);
    }
    /// Atomically add `v`, returning the previous value.
    pub fn fetch_add(self: &mut Atomic<T>, v: T) T {
        return T::atomic_add(&mut self.value, v);
    }
    /// Atomically subtract `v`, returning the previous value.
    pub fn fetch_sub(self: &mut Atomic<T>, v: T) T {
        return T::atomic_sub(&mut self.value, v);
    }
    /// If the value equals `expected`, replace it with `desired`; returns whether the swap happened.
    pub fn compare_exchange(self: &mut Atomic<T>, expected: T, desired: T) bool {
        return T::atomic_cas(&mut self.value, expected, desired);
    }
}
