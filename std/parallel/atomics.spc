// Typed atomics. `Atomic<T>` wraps a plain `T` cell and drives the compiler's `__sc_atomic_*` builtins
// (through `ffi/atomic.spc`) so reads, writes and read-modify-write operations on it are indivisible across
// threads. Every operation takes an explicit `MemoryOrder`. Import with `import std::parallel::atomics;`.
//
// `T` must be an integer builtin (it conforms to `AtomicOps` below). The value is stored unwrapped, so an
// `Atomic<T>` is exactly `sizeof(T)` and can be shared by raw pointer or through an `Arc`.

import atomic;

/// Memory ordering for an atomic operation, from weakest to strongest. Discriminants match the codes the
/// runtime wrapper expects, so `order as i32` is the wire value.
///
/// - `Relaxed`: atomicity only, no ordering with other memory.
/// - `Acquire` (loads/RMW): later reads/writes can't move before this load.
/// - `Release` (stores/RMW): earlier reads/writes can't move after this store.
/// - `AcqRel` (RMW): both, in one operation.
/// - `SeqCst`: a single total order across all `SeqCst` operations (the safe default).
pub enum MemoryOrder {
    Relaxed,
    Acquire,
    Release,
    AcqRel,
    SeqCst,
}

/// The per-type atomic primitives, one thin conformance per integer builtin. Not implemented by hand for
/// user types: only the builtins the runtime provides `__sc_atomic_*` for can be atomic. The order is
/// already lowered to its `i32` code here; the typed `Atomic<T>` façade is what takes `MemoryOrder`.
pub interface AtomicOps {
    fn atomic_load(p: *const Self, mo: i32) Self;
    fn atomic_store(p: *mut Self, v: Self, mo: i32);
    fn atomic_swap(p: *mut Self, v: Self, mo: i32) Self;
    fn atomic_add(p: *mut Self, v: Self, mo: i32) Self;
    fn atomic_sub(p: *mut Self, v: Self, mo: i32) Self;
    fn atomic_and(p: *mut Self, v: Self, mo: i32) Self;
    fn atomic_or(p: *mut Self, v: Self, mo: i32) Self;
    fn atomic_xor(p: *mut Self, v: Self, mo: i32) Self;
    fn atomic_cas(p: *mut Self, expected: Self, desired: Self, weak: bool, so: i32, fo: i32) bool;
}

extend i32 as AtomicOps {
    fn atomic_load(p: *const i32, mo: i32) i32 {
        return atomic::load_i32(p, mo);
    }
    fn atomic_store(p: *mut i32, v: i32, mo: i32) {
        atomic::store_i32(p, v, mo);
    }
    fn atomic_swap(p: *mut i32, v: i32, mo: i32) i32 {
        return atomic::swap_i32(p, v, mo);
    }
    fn atomic_add(p: *mut i32, v: i32, mo: i32) i32 {
        return atomic::add_i32(p, v, mo);
    }
    fn atomic_sub(p: *mut i32, v: i32, mo: i32) i32 {
        return atomic::sub_i32(p, v, mo);
    }
    fn atomic_and(p: *mut i32, v: i32, mo: i32) i32 {
        return atomic::and_i32(p, v, mo);
    }
    fn atomic_or(p: *mut i32, v: i32, mo: i32) i32 {
        return atomic::or_i32(p, v, mo);
    }
    fn atomic_xor(p: *mut i32, v: i32, mo: i32) i32 {
        return atomic::xor_i32(p, v, mo);
    }
    fn atomic_cas(p: *mut i32, expected: i32, desired: i32, weak: bool, so: i32, fo: i32) bool {
        return atomic::cas_i32(p, expected, desired, weak, so, fo);
    }
}

extend i64 as AtomicOps {
    fn atomic_load(p: *const i64, mo: i32) i64 {
        return atomic::load_i64(p, mo);
    }
    fn atomic_store(p: *mut i64, v: i64, mo: i32) {
        atomic::store_i64(p, v, mo);
    }
    fn atomic_swap(p: *mut i64, v: i64, mo: i32) i64 {
        return atomic::swap_i64(p, v, mo);
    }
    fn atomic_add(p: *mut i64, v: i64, mo: i32) i64 {
        return atomic::add_i64(p, v, mo);
    }
    fn atomic_sub(p: *mut i64, v: i64, mo: i32) i64 {
        return atomic::sub_i64(p, v, mo);
    }
    fn atomic_and(p: *mut i64, v: i64, mo: i32) i64 {
        return atomic::and_i64(p, v, mo);
    }
    fn atomic_or(p: *mut i64, v: i64, mo: i32) i64 {
        return atomic::or_i64(p, v, mo);
    }
    fn atomic_xor(p: *mut i64, v: i64, mo: i32) i64 {
        return atomic::xor_i64(p, v, mo);
    }
    fn atomic_cas(p: *mut i64, expected: i64, desired: i64, weak: bool, so: i32, fo: i32) bool {
        return atomic::cas_i64(p, expected, desired, weak, so, fo);
    }
}

extend u32 as AtomicOps {
    fn atomic_load(p: *const u32, mo: i32) u32 {
        return atomic::load_u32(p, mo);
    }
    fn atomic_store(p: *mut u32, v: u32, mo: i32) {
        atomic::store_u32(p, v, mo);
    }
    fn atomic_swap(p: *mut u32, v: u32, mo: i32) u32 {
        return atomic::swap_u32(p, v, mo);
    }
    fn atomic_add(p: *mut u32, v: u32, mo: i32) u32 {
        return atomic::add_u32(p, v, mo);
    }
    fn atomic_sub(p: *mut u32, v: u32, mo: i32) u32 {
        return atomic::sub_u32(p, v, mo);
    }
    fn atomic_and(p: *mut u32, v: u32, mo: i32) u32 {
        return atomic::and_u32(p, v, mo);
    }
    fn atomic_or(p: *mut u32, v: u32, mo: i32) u32 {
        return atomic::or_u32(p, v, mo);
    }
    fn atomic_xor(p: *mut u32, v: u32, mo: i32) u32 {
        return atomic::xor_u32(p, v, mo);
    }
    fn atomic_cas(p: *mut u32, expected: u32, desired: u32, weak: bool, so: i32, fo: i32) bool {
        return atomic::cas_u32(p, expected, desired, weak, so, fo);
    }
}

extend u64 as AtomicOps {
    fn atomic_load(p: *const u64, mo: i32) u64 {
        return atomic::load_u64(p, mo);
    }
    fn atomic_store(p: *mut u64, v: u64, mo: i32) {
        atomic::store_u64(p, v, mo);
    }
    fn atomic_swap(p: *mut u64, v: u64, mo: i32) u64 {
        return atomic::swap_u64(p, v, mo);
    }
    fn atomic_add(p: *mut u64, v: u64, mo: i32) u64 {
        return atomic::add_u64(p, v, mo);
    }
    fn atomic_sub(p: *mut u64, v: u64, mo: i32) u64 {
        return atomic::sub_u64(p, v, mo);
    }
    fn atomic_and(p: *mut u64, v: u64, mo: i32) u64 {
        return atomic::and_u64(p, v, mo);
    }
    fn atomic_or(p: *mut u64, v: u64, mo: i32) u64 {
        return atomic::or_u64(p, v, mo);
    }
    fn atomic_xor(p: *mut u64, v: u64, mo: i32) u64 {
        return atomic::xor_u64(p, v, mo);
    }
    fn atomic_cas(p: *mut u64, expected: u64, desired: u64, weak: bool, so: i32, fo: i32) bool {
        return atomic::cas_u64(p, expected, desired, weak, so, fo);
    }
}

extend usize as AtomicOps {
    fn atomic_load(p: *const usize, mo: i32) usize {
        return atomic::load_usize(p, mo);
    }
    fn atomic_store(p: *mut usize, v: usize, mo: i32) {
        atomic::store_usize(p, v, mo);
    }
    fn atomic_swap(p: *mut usize, v: usize, mo: i32) usize {
        return atomic::swap_usize(p, v, mo);
    }
    fn atomic_add(p: *mut usize, v: usize, mo: i32) usize {
        return atomic::add_usize(p, v, mo);
    }
    fn atomic_sub(p: *mut usize, v: usize, mo: i32) usize {
        return atomic::sub_usize(p, v, mo);
    }
    fn atomic_and(p: *mut usize, v: usize, mo: i32) usize {
        return atomic::and_usize(p, v, mo);
    }
    fn atomic_or(p: *mut usize, v: usize, mo: i32) usize {
        return atomic::or_usize(p, v, mo);
    }
    fn atomic_xor(p: *mut usize, v: usize, mo: i32) usize {
        return atomic::xor_usize(p, v, mo);
    }
    fn atomic_cas(p: *mut usize, expected: usize, desired: usize, weak: bool, so: i32, fo: i32) bool {
        return atomic::cas_usize(p, expected, desired, weak, so, fo);
    }
}

extend isize as AtomicOps {
    fn atomic_load(p: *const isize, mo: i32) isize {
        return atomic::load_isize(p, mo);
    }
    fn atomic_store(p: *mut isize, v: isize, mo: i32) {
        atomic::store_isize(p, v, mo);
    }
    fn atomic_swap(p: *mut isize, v: isize, mo: i32) isize {
        return atomic::swap_isize(p, v, mo);
    }
    fn atomic_add(p: *mut isize, v: isize, mo: i32) isize {
        return atomic::add_isize(p, v, mo);
    }
    fn atomic_sub(p: *mut isize, v: isize, mo: i32) isize {
        return atomic::sub_isize(p, v, mo);
    }
    fn atomic_and(p: *mut isize, v: isize, mo: i32) isize {
        return atomic::and_isize(p, v, mo);
    }
    fn atomic_or(p: *mut isize, v: isize, mo: i32) isize {
        return atomic::or_isize(p, v, mo);
    }
    fn atomic_xor(p: *mut isize, v: isize, mo: i32) isize {
        return atomic::xor_isize(p, v, mo);
    }
    fn atomic_cas(p: *mut isize, expected: isize, desired: isize, weak: bool, so: i32, fo: i32) bool {
        return atomic::cas_isize(p, expected, desired, weak, so, fo);
    }
}

/// An atomic integer cell. Every operation takes `&self`: atomics ARE the interior-mutability primitive, so
/// a shared reference (e.g. through an `Arc`) is enough to mutate the cell. That interior mutability lives in
/// an `UnsafeCell`, the one place a `*mut` may be formed from a shared borrow; the value is stored unwrapped
/// inside it, so its address can be shared across threads.
@no_const
pub struct Atomic<T: AtomicOps> {
    cell: UnsafeCell<T>,
}

// Shareable across threads BECAUSE every access is an atomic instruction -- an `Atomic` is the one thing
// entitled to make that claim over an `UnsafeCell`, since the synchronisation is the operation itself. The
// assertion is explicit rather than structural: the field walk stops at `UnsafeCell`, which is never `Sync`
// on its own, so a type wrapping one has to say what makes it safe.
unsafe extend<T: AtomicOps + Send> Atomic<T> as Send {}

unsafe extend<T: AtomicOps + Send> Atomic<T> as Sync {}

extend<T: AtomicOps> Atomic<T> {
    /// A cell initialised to `v`.
    pub fn new(v: T) Atomic<T> {
        return Atomic::<T> { cell: UnsafeCell::<T>::new(v) };
    }
    /// Atomically read the current value.
    pub fn load(self: &Atomic<T>, order: MemoryOrder) T {
        return T::atomic_load(self.cell.get(), order as i32);
    }
    /// Atomically overwrite the value.
    pub fn store(self: &Atomic<T>, v: T, order: MemoryOrder) {
        T::atomic_store(self.cell.get(), v, order as i32);
    }
    /// Atomically overwrite the value, returning the previous one.
    pub fn swap(self: &Atomic<T>, v: T, order: MemoryOrder) T {
        return T::atomic_swap(self.cell.get(), v, order as i32);
    }
    /// Atomically add `v`, returning the previous value.
    pub fn fetch_add(self: &Atomic<T>, v: T, order: MemoryOrder) T {
        return T::atomic_add(self.cell.get(), v, order as i32);
    }
    /// Atomically subtract `v`, returning the previous value.
    pub fn fetch_sub(self: &Atomic<T>, v: T, order: MemoryOrder) T {
        return T::atomic_sub(self.cell.get(), v, order as i32);
    }
    /// Atomically bitwise-AND `v` in, returning the previous value.
    pub fn fetch_and(self: &Atomic<T>, v: T, order: MemoryOrder) T {
        return T::atomic_and(self.cell.get(), v, order as i32);
    }
    /// Atomically bitwise-OR `v` in, returning the previous value.
    pub fn fetch_or(self: &Atomic<T>, v: T, order: MemoryOrder) T {
        return T::atomic_or(self.cell.get(), v, order as i32);
    }
    /// Atomically bitwise-XOR `v` in, returning the previous value.
    pub fn fetch_xor(self: &Atomic<T>, v: T, order: MemoryOrder) T {
        return T::atomic_xor(self.cell.get(), v, order as i32);
    }
    /// If the value equals `expected`, replace it with `desired`; returns whether the swap happened. Strong:
    /// never fails spuriously. `success` orders the read-modify-write when it swaps; `failure` orders the
    /// load when it does not (`failure` may not be `Release`/`AcqRel`).
    pub fn compare_exchange(self: &Atomic<T>, expected: T, desired: T, success: MemoryOrder, failure: MemoryOrder) bool {
        return T::atomic_cas(self.cell.get(), expected, desired, false, success as i32, failure as i32);
    }
    /// Like `compare_exchange`, but may fail spuriously even when the value equals `expected`. Cheaper on
    /// LL/SC targets (e.g. AArch64); use it in a retry loop.
    pub fn compare_exchange_weak(self: &Atomic<T>, expected: T, desired: T, success: MemoryOrder, failure: MemoryOrder) bool {
        return T::atomic_cas(self.cell.get(), expected, desired, true, success as i32, failure as i32);
    }
}

/// A standalone memory fence with the given ordering, ordering surrounding non-atomic and relaxed-atomic
/// accesses without touching a specific cell.
pub fn fence(order: MemoryOrder) {
    atomic::fence(order as i32);
}
