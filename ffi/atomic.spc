// Atomics backed by the compiler runtime's `__sc_atomic_*` builtins (lowered to `__atomic_*`). Each op
// takes a memory-order code (see `std/parallel/atomics.spc`'s `MemoryOrder`: Relaxed=0, Acquire=1,
// Release=2, AcqRel=3, SeqCst=4); an order illegal for an op clamps to SeqCst in the runtime wrapper. The
// runtime provides i8/i16/i32/i64/isize/u8/u16/u32/u64/usize plus bool. Pointers can be exchanged or
// compared by casting through usize. `cas` takes a `weak` flag (weak may fail spuriously but is cheaper on
// LL/SC targets) plus separate success/failure orders. The `pub` wrappers hold the `unsafe` extern calls
// internally: callers need no `unsafe` block.

extern "C" {
    fn __sc_atomic_load_i8(p: *const i8, mo: i32) i8;
    fn __sc_atomic_store_i8(p: *mut i8, v: i8, mo: i32);
    fn __sc_atomic_swap_i8(p: *mut i8, v: i8, mo: i32) i8;
    fn __sc_atomic_add_i8(p: *mut i8, v: i8, mo: i32) i8;
    fn __sc_atomic_sub_i8(p: *mut i8, v: i8, mo: i32) i8;
    fn __sc_atomic_and_i8(p: *mut i8, v: i8, mo: i32) i8;
    fn __sc_atomic_or_i8(p: *mut i8, v: i8, mo: i32) i8;
    fn __sc_atomic_xor_i8(p: *mut i8, v: i8, mo: i32) i8;
    fn __sc_atomic_cas_i8(p: *mut i8, expected: i8, desired: i8, weak: bool, so: i32, fo: i32) bool;

    fn __sc_atomic_load_i16(p: *const i16, mo: i32) i16;
    fn __sc_atomic_store_i16(p: *mut i16, v: i16, mo: i32);
    fn __sc_atomic_swap_i16(p: *mut i16, v: i16, mo: i32) i16;
    fn __sc_atomic_add_i16(p: *mut i16, v: i16, mo: i32) i16;
    fn __sc_atomic_sub_i16(p: *mut i16, v: i16, mo: i32) i16;
    fn __sc_atomic_and_i16(p: *mut i16, v: i16, mo: i32) i16;
    fn __sc_atomic_or_i16(p: *mut i16, v: i16, mo: i32) i16;
    fn __sc_atomic_xor_i16(p: *mut i16, v: i16, mo: i32) i16;
    fn __sc_atomic_cas_i16(p: *mut i16, expected: i16, desired: i16, weak: bool, so: i32, fo: i32) bool;

    fn __sc_atomic_load_i32(p: *const i32, mo: i32) i32;
    fn __sc_atomic_store_i32(p: *mut i32, v: i32, mo: i32);
    fn __sc_atomic_swap_i32(p: *mut i32, v: i32, mo: i32) i32;
    fn __sc_atomic_add_i32(p: *mut i32, v: i32, mo: i32) i32;
    fn __sc_atomic_sub_i32(p: *mut i32, v: i32, mo: i32) i32;
    fn __sc_atomic_and_i32(p: *mut i32, v: i32, mo: i32) i32;
    fn __sc_atomic_or_i32(p: *mut i32, v: i32, mo: i32) i32;
    fn __sc_atomic_xor_i32(p: *mut i32, v: i32, mo: i32) i32;
    fn __sc_atomic_cas_i32(p: *mut i32, expected: i32, desired: i32, weak: bool, so: i32, fo: i32) bool;

    fn __sc_atomic_load_i64(p: *const i64, mo: i32) i64;
    fn __sc_atomic_store_i64(p: *mut i64, v: i64, mo: i32);
    fn __sc_atomic_swap_i64(p: *mut i64, v: i64, mo: i32) i64;
    fn __sc_atomic_add_i64(p: *mut i64, v: i64, mo: i32) i64;
    fn __sc_atomic_sub_i64(p: *mut i64, v: i64, mo: i32) i64;
    fn __sc_atomic_and_i64(p: *mut i64, v: i64, mo: i32) i64;
    fn __sc_atomic_or_i64(p: *mut i64, v: i64, mo: i32) i64;
    fn __sc_atomic_xor_i64(p: *mut i64, v: i64, mo: i32) i64;
    fn __sc_atomic_cas_i64(p: *mut i64, expected: i64, desired: i64, weak: bool, so: i32, fo: i32) bool;

    fn __sc_atomic_load_isize(p: *const isize, mo: i32) isize;
    fn __sc_atomic_store_isize(p: *mut isize, v: isize, mo: i32);
    fn __sc_atomic_swap_isize(p: *mut isize, v: isize, mo: i32) isize;
    fn __sc_atomic_add_isize(p: *mut isize, v: isize, mo: i32) isize;
    fn __sc_atomic_sub_isize(p: *mut isize, v: isize, mo: i32) isize;
    fn __sc_atomic_and_isize(p: *mut isize, v: isize, mo: i32) isize;
    fn __sc_atomic_or_isize(p: *mut isize, v: isize, mo: i32) isize;
    fn __sc_atomic_xor_isize(p: *mut isize, v: isize, mo: i32) isize;
    fn __sc_atomic_cas_isize(p: *mut isize, expected: isize, desired: isize, weak: bool, so: i32, fo: i32) bool;

    fn __sc_atomic_load_u8(p: *const u8, mo: i32) u8;
    fn __sc_atomic_store_u8(p: *mut u8, v: u8, mo: i32);
    fn __sc_atomic_swap_u8(p: *mut u8, v: u8, mo: i32) u8;
    fn __sc_atomic_add_u8(p: *mut u8, v: u8, mo: i32) u8;
    fn __sc_atomic_sub_u8(p: *mut u8, v: u8, mo: i32) u8;
    fn __sc_atomic_and_u8(p: *mut u8, v: u8, mo: i32) u8;
    fn __sc_atomic_or_u8(p: *mut u8, v: u8, mo: i32) u8;
    fn __sc_atomic_xor_u8(p: *mut u8, v: u8, mo: i32) u8;
    fn __sc_atomic_cas_u8(p: *mut u8, expected: u8, desired: u8, weak: bool, so: i32, fo: i32) bool;

    fn __sc_atomic_load_u16(p: *const u16, mo: i32) u16;
    fn __sc_atomic_store_u16(p: *mut u16, v: u16, mo: i32);
    fn __sc_atomic_swap_u16(p: *mut u16, v: u16, mo: i32) u16;
    fn __sc_atomic_add_u16(p: *mut u16, v: u16, mo: i32) u16;
    fn __sc_atomic_sub_u16(p: *mut u16, v: u16, mo: i32) u16;
    fn __sc_atomic_and_u16(p: *mut u16, v: u16, mo: i32) u16;
    fn __sc_atomic_or_u16(p: *mut u16, v: u16, mo: i32) u16;
    fn __sc_atomic_xor_u16(p: *mut u16, v: u16, mo: i32) u16;
    fn __sc_atomic_cas_u16(p: *mut u16, expected: u16, desired: u16, weak: bool, so: i32, fo: i32) bool;

    fn __sc_atomic_load_u32(p: *const u32, mo: i32) u32;
    fn __sc_atomic_store_u32(p: *mut u32, v: u32, mo: i32);
    fn __sc_atomic_swap_u32(p: *mut u32, v: u32, mo: i32) u32;
    fn __sc_atomic_add_u32(p: *mut u32, v: u32, mo: i32) u32;
    fn __sc_atomic_sub_u32(p: *mut u32, v: u32, mo: i32) u32;
    fn __sc_atomic_and_u32(p: *mut u32, v: u32, mo: i32) u32;
    fn __sc_atomic_or_u32(p: *mut u32, v: u32, mo: i32) u32;
    fn __sc_atomic_xor_u32(p: *mut u32, v: u32, mo: i32) u32;
    fn __sc_atomic_cas_u32(p: *mut u32, expected: u32, desired: u32, weak: bool, so: i32, fo: i32) bool;

    fn __sc_atomic_load_u64(p: *const u64, mo: i32) u64;
    fn __sc_atomic_store_u64(p: *mut u64, v: u64, mo: i32);
    fn __sc_atomic_swap_u64(p: *mut u64, v: u64, mo: i32) u64;
    fn __sc_atomic_add_u64(p: *mut u64, v: u64, mo: i32) u64;
    fn __sc_atomic_sub_u64(p: *mut u64, v: u64, mo: i32) u64;
    fn __sc_atomic_and_u64(p: *mut u64, v: u64, mo: i32) u64;
    fn __sc_atomic_or_u64(p: *mut u64, v: u64, mo: i32) u64;
    fn __sc_atomic_xor_u64(p: *mut u64, v: u64, mo: i32) u64;
    fn __sc_atomic_cas_u64(p: *mut u64, expected: u64, desired: u64, weak: bool, so: i32, fo: i32) bool;

    fn __sc_atomic_load_usize(p: *const usize, mo: i32) usize;
    fn __sc_atomic_store_usize(p: *mut usize, v: usize, mo: i32);
    fn __sc_atomic_swap_usize(p: *mut usize, v: usize, mo: i32) usize;
    fn __sc_atomic_add_usize(p: *mut usize, v: usize, mo: i32) usize;
    fn __sc_atomic_sub_usize(p: *mut usize, v: usize, mo: i32) usize;
    fn __sc_atomic_and_usize(p: *mut usize, v: usize, mo: i32) usize;
    fn __sc_atomic_or_usize(p: *mut usize, v: usize, mo: i32) usize;
    fn __sc_atomic_xor_usize(p: *mut usize, v: usize, mo: i32) usize;
    fn __sc_atomic_cas_usize(p: *mut usize, expected: usize, desired: usize, weak: bool, so: i32, fo: i32) bool;

    fn __sc_atomic_load_bool(p: *const bool, mo: i32) bool;
    fn __sc_atomic_store_bool(p: *mut bool, v: bool, mo: i32);
    fn __sc_atomic_swap_bool(p: *mut bool, v: bool, mo: i32) bool;
    fn __sc_atomic_cas_bool(p: *mut bool, expected: bool, desired: bool, weak: bool, so: i32, fo: i32) bool;

    fn __sc_atomic_fence(mo: i32);
}

pub fn load_i8(p: *const i8, mo: i32) i8 {
    return unsafe __sc_atomic_load_i8(p, mo);
}
pub fn store_i8(p: *mut i8, v: i8, mo: i32) {
    unsafe __sc_atomic_store_i8(p, v, mo);
}
pub fn swap_i8(p: *mut i8, v: i8, mo: i32) i8 {
    return unsafe __sc_atomic_swap_i8(p, v, mo);
}
pub fn add_i8(p: *mut i8, v: i8, mo: i32) i8 {
    return unsafe __sc_atomic_add_i8(p, v, mo);
}
pub fn sub_i8(p: *mut i8, v: i8, mo: i32) i8 {
    return unsafe __sc_atomic_sub_i8(p, v, mo);
}
pub fn and_i8(p: *mut i8, v: i8, mo: i32) i8 {
    return unsafe __sc_atomic_and_i8(p, v, mo);
}
pub fn or_i8(p: *mut i8, v: i8, mo: i32) i8 {
    return unsafe __sc_atomic_or_i8(p, v, mo);
}
pub fn xor_i8(p: *mut i8, v: i8, mo: i32) i8 {
    return unsafe __sc_atomic_xor_i8(p, v, mo);
}
pub fn cas_i8(p: *mut i8, expected: i8, desired: i8, weak: bool, so: i32, fo: i32) bool {
    return unsafe __sc_atomic_cas_i8(p, expected, desired, weak, so, fo);
}

pub fn load_i16(p: *const i16, mo: i32) i16 {
    return unsafe __sc_atomic_load_i16(p, mo);
}
pub fn store_i16(p: *mut i16, v: i16, mo: i32) {
    unsafe __sc_atomic_store_i16(p, v, mo);
}
pub fn swap_i16(p: *mut i16, v: i16, mo: i32) i16 {
    return unsafe __sc_atomic_swap_i16(p, v, mo);
}
pub fn add_i16(p: *mut i16, v: i16, mo: i32) i16 {
    return unsafe __sc_atomic_add_i16(p, v, mo);
}
pub fn sub_i16(p: *mut i16, v: i16, mo: i32) i16 {
    return unsafe __sc_atomic_sub_i16(p, v, mo);
}
pub fn and_i16(p: *mut i16, v: i16, mo: i32) i16 {
    return unsafe __sc_atomic_and_i16(p, v, mo);
}
pub fn or_i16(p: *mut i16, v: i16, mo: i32) i16 {
    return unsafe __sc_atomic_or_i16(p, v, mo);
}
pub fn xor_i16(p: *mut i16, v: i16, mo: i32) i16 {
    return unsafe __sc_atomic_xor_i16(p, v, mo);
}
pub fn cas_i16(p: *mut i16, expected: i16, desired: i16, weak: bool, so: i32, fo: i32) bool {
    return unsafe __sc_atomic_cas_i16(p, expected, desired, weak, so, fo);
}

pub fn load_i32(p: *const i32, mo: i32) i32 {
    return unsafe __sc_atomic_load_i32(p, mo);
}
pub fn store_i32(p: *mut i32, v: i32, mo: i32) {
    unsafe __sc_atomic_store_i32(p, v, mo);
}
pub fn swap_i32(p: *mut i32, v: i32, mo: i32) i32 {
    return unsafe __sc_atomic_swap_i32(p, v, mo);
}
pub fn add_i32(p: *mut i32, v: i32, mo: i32) i32 {
    return unsafe __sc_atomic_add_i32(p, v, mo);
}
pub fn sub_i32(p: *mut i32, v: i32, mo: i32) i32 {
    return unsafe __sc_atomic_sub_i32(p, v, mo);
}
pub fn and_i32(p: *mut i32, v: i32, mo: i32) i32 {
    return unsafe __sc_atomic_and_i32(p, v, mo);
}
pub fn or_i32(p: *mut i32, v: i32, mo: i32) i32 {
    return unsafe __sc_atomic_or_i32(p, v, mo);
}
pub fn xor_i32(p: *mut i32, v: i32, mo: i32) i32 {
    return unsafe __sc_atomic_xor_i32(p, v, mo);
}
pub fn cas_i32(p: *mut i32, expected: i32, desired: i32, weak: bool, so: i32, fo: i32) bool {
    return unsafe __sc_atomic_cas_i32(p, expected, desired, weak, so, fo);
}

pub fn load_i64(p: *const i64, mo: i32) i64 {
    return unsafe __sc_atomic_load_i64(p, mo);
}
pub fn store_i64(p: *mut i64, v: i64, mo: i32) {
    unsafe __sc_atomic_store_i64(p, v, mo);
}
pub fn swap_i64(p: *mut i64, v: i64, mo: i32) i64 {
    return unsafe __sc_atomic_swap_i64(p, v, mo);
}
pub fn add_i64(p: *mut i64, v: i64, mo: i32) i64 {
    return unsafe __sc_atomic_add_i64(p, v, mo);
}
pub fn sub_i64(p: *mut i64, v: i64, mo: i32) i64 {
    return unsafe __sc_atomic_sub_i64(p, v, mo);
}
pub fn and_i64(p: *mut i64, v: i64, mo: i32) i64 {
    return unsafe __sc_atomic_and_i64(p, v, mo);
}
pub fn or_i64(p: *mut i64, v: i64, mo: i32) i64 {
    return unsafe __sc_atomic_or_i64(p, v, mo);
}
pub fn xor_i64(p: *mut i64, v: i64, mo: i32) i64 {
    return unsafe __sc_atomic_xor_i64(p, v, mo);
}
pub fn cas_i64(p: *mut i64, expected: i64, desired: i64, weak: bool, so: i32, fo: i32) bool {
    return unsafe __sc_atomic_cas_i64(p, expected, desired, weak, so, fo);
}

pub fn load_isize(p: *const isize, mo: i32) isize {
    return unsafe __sc_atomic_load_isize(p, mo);
}
pub fn store_isize(p: *mut isize, v: isize, mo: i32) {
    unsafe __sc_atomic_store_isize(p, v, mo);
}
pub fn swap_isize(p: *mut isize, v: isize, mo: i32) isize {
    return unsafe __sc_atomic_swap_isize(p, v, mo);
}
pub fn add_isize(p: *mut isize, v: isize, mo: i32) isize {
    return unsafe __sc_atomic_add_isize(p, v, mo);
}
pub fn sub_isize(p: *mut isize, v: isize, mo: i32) isize {
    return unsafe __sc_atomic_sub_isize(p, v, mo);
}
pub fn and_isize(p: *mut isize, v: isize, mo: i32) isize {
    return unsafe __sc_atomic_and_isize(p, v, mo);
}
pub fn or_isize(p: *mut isize, v: isize, mo: i32) isize {
    return unsafe __sc_atomic_or_isize(p, v, mo);
}
pub fn xor_isize(p: *mut isize, v: isize, mo: i32) isize {
    return unsafe __sc_atomic_xor_isize(p, v, mo);
}
pub fn cas_isize(p: *mut isize, expected: isize, desired: isize, weak: bool, so: i32, fo: i32) bool {
    return unsafe __sc_atomic_cas_isize(p, expected, desired, weak, so, fo);
}

pub fn load_u8(p: *const u8, mo: i32) u8 {
    return unsafe __sc_atomic_load_u8(p, mo);
}
pub fn store_u8(p: *mut u8, v: u8, mo: i32) {
    unsafe __sc_atomic_store_u8(p, v, mo);
}
pub fn swap_u8(p: *mut u8, v: u8, mo: i32) u8 {
    return unsafe __sc_atomic_swap_u8(p, v, mo);
}
pub fn add_u8(p: *mut u8, v: u8, mo: i32) u8 {
    return unsafe __sc_atomic_add_u8(p, v, mo);
}
pub fn sub_u8(p: *mut u8, v: u8, mo: i32) u8 {
    return unsafe __sc_atomic_sub_u8(p, v, mo);
}
pub fn and_u8(p: *mut u8, v: u8, mo: i32) u8 {
    return unsafe __sc_atomic_and_u8(p, v, mo);
}
pub fn or_u8(p: *mut u8, v: u8, mo: i32) u8 {
    return unsafe __sc_atomic_or_u8(p, v, mo);
}
pub fn xor_u8(p: *mut u8, v: u8, mo: i32) u8 {
    return unsafe __sc_atomic_xor_u8(p, v, mo);
}
pub fn cas_u8(p: *mut u8, expected: u8, desired: u8, weak: bool, so: i32, fo: i32) bool {
    return unsafe __sc_atomic_cas_u8(p, expected, desired, weak, so, fo);
}

pub fn load_u16(p: *const u16, mo: i32) u16 {
    return unsafe __sc_atomic_load_u16(p, mo);
}
pub fn store_u16(p: *mut u16, v: u16, mo: i32) {
    unsafe __sc_atomic_store_u16(p, v, mo);
}
pub fn swap_u16(p: *mut u16, v: u16, mo: i32) u16 {
    return unsafe __sc_atomic_swap_u16(p, v, mo);
}
pub fn add_u16(p: *mut u16, v: u16, mo: i32) u16 {
    return unsafe __sc_atomic_add_u16(p, v, mo);
}
pub fn sub_u16(p: *mut u16, v: u16, mo: i32) u16 {
    return unsafe __sc_atomic_sub_u16(p, v, mo);
}
pub fn and_u16(p: *mut u16, v: u16, mo: i32) u16 {
    return unsafe __sc_atomic_and_u16(p, v, mo);
}
pub fn or_u16(p: *mut u16, v: u16, mo: i32) u16 {
    return unsafe __sc_atomic_or_u16(p, v, mo);
}
pub fn xor_u16(p: *mut u16, v: u16, mo: i32) u16 {
    return unsafe __sc_atomic_xor_u16(p, v, mo);
}
pub fn cas_u16(p: *mut u16, expected: u16, desired: u16, weak: bool, so: i32, fo: i32) bool {
    return unsafe __sc_atomic_cas_u16(p, expected, desired, weak, so, fo);
}

pub fn load_u32(p: *const u32, mo: i32) u32 {
    return unsafe __sc_atomic_load_u32(p, mo);
}
pub fn store_u32(p: *mut u32, v: u32, mo: i32) {
    unsafe __sc_atomic_store_u32(p, v, mo);
}
pub fn swap_u32(p: *mut u32, v: u32, mo: i32) u32 {
    return unsafe __sc_atomic_swap_u32(p, v, mo);
}
pub fn add_u32(p: *mut u32, v: u32, mo: i32) u32 {
    return unsafe __sc_atomic_add_u32(p, v, mo);
}
pub fn sub_u32(p: *mut u32, v: u32, mo: i32) u32 {
    return unsafe __sc_atomic_sub_u32(p, v, mo);
}
pub fn and_u32(p: *mut u32, v: u32, mo: i32) u32 {
    return unsafe __sc_atomic_and_u32(p, v, mo);
}
pub fn or_u32(p: *mut u32, v: u32, mo: i32) u32 {
    return unsafe __sc_atomic_or_u32(p, v, mo);
}
pub fn xor_u32(p: *mut u32, v: u32, mo: i32) u32 {
    return unsafe __sc_atomic_xor_u32(p, v, mo);
}
pub fn cas_u32(p: *mut u32, expected: u32, desired: u32, weak: bool, so: i32, fo: i32) bool {
    return unsafe __sc_atomic_cas_u32(p, expected, desired, weak, so, fo);
}

pub fn load_u64(p: *const u64, mo: i32) u64 {
    return unsafe __sc_atomic_load_u64(p, mo);
}
pub fn store_u64(p: *mut u64, v: u64, mo: i32) {
    unsafe __sc_atomic_store_u64(p, v, mo);
}
pub fn swap_u64(p: *mut u64, v: u64, mo: i32) u64 {
    return unsafe __sc_atomic_swap_u64(p, v, mo);
}
pub fn add_u64(p: *mut u64, v: u64, mo: i32) u64 {
    return unsafe __sc_atomic_add_u64(p, v, mo);
}
pub fn sub_u64(p: *mut u64, v: u64, mo: i32) u64 {
    return unsafe __sc_atomic_sub_u64(p, v, mo);
}
pub fn and_u64(p: *mut u64, v: u64, mo: i32) u64 {
    return unsafe __sc_atomic_and_u64(p, v, mo);
}
pub fn or_u64(p: *mut u64, v: u64, mo: i32) u64 {
    return unsafe __sc_atomic_or_u64(p, v, mo);
}
pub fn xor_u64(p: *mut u64, v: u64, mo: i32) u64 {
    return unsafe __sc_atomic_xor_u64(p, v, mo);
}
pub fn cas_u64(p: *mut u64, expected: u64, desired: u64, weak: bool, so: i32, fo: i32) bool {
    return unsafe __sc_atomic_cas_u64(p, expected, desired, weak, so, fo);
}

pub fn load_usize(p: *const usize, mo: i32) usize {
    return unsafe __sc_atomic_load_usize(p, mo);
}
pub fn store_usize(p: *mut usize, v: usize, mo: i32) {
    unsafe __sc_atomic_store_usize(p, v, mo);
}
pub fn swap_usize(p: *mut usize, v: usize, mo: i32) usize {
    return unsafe __sc_atomic_swap_usize(p, v, mo);
}
pub fn add_usize(p: *mut usize, v: usize, mo: i32) usize {
    return unsafe __sc_atomic_add_usize(p, v, mo);
}
pub fn sub_usize(p: *mut usize, v: usize, mo: i32) usize {
    return unsafe __sc_atomic_sub_usize(p, v, mo);
}
pub fn and_usize(p: *mut usize, v: usize, mo: i32) usize {
    return unsafe __sc_atomic_and_usize(p, v, mo);
}
pub fn or_usize(p: *mut usize, v: usize, mo: i32) usize {
    return unsafe __sc_atomic_or_usize(p, v, mo);
}
pub fn xor_usize(p: *mut usize, v: usize, mo: i32) usize {
    return unsafe __sc_atomic_xor_usize(p, v, mo);
}
pub fn cas_usize(p: *mut usize, expected: usize, desired: usize, weak: bool, so: i32, fo: i32) bool {
    return unsafe __sc_atomic_cas_usize(p, expected, desired, weak, so, fo);
}

pub fn load_bool(p: *const bool, mo: i32) bool {
    return unsafe __sc_atomic_load_bool(p, mo);
}
pub fn store_bool(p: *mut bool, v: bool, mo: i32) {
    unsafe __sc_atomic_store_bool(p, v, mo);
}
pub fn swap_bool(p: *mut bool, v: bool, mo: i32) bool {
    return unsafe __sc_atomic_swap_bool(p, v, mo);
}
pub fn cas_bool(p: *mut bool, expected: bool, desired: bool, weak: bool, so: i32, fo: i32) bool {
    return unsafe __sc_atomic_cas_bool(p, expected, desired, weak, so, fo);
}

pub fn load_ptr(p: *const usize, mo: i32) usize {
    return load_usize(p, mo);
}
pub fn store_ptr(p: *mut usize, v: usize, mo: i32) {
    store_usize(p, v, mo);
}
pub fn swap_ptr(p: *mut usize, v: usize, mo: i32) usize {
    return swap_usize(p, v, mo);
}
pub fn cas_ptr(p: *mut usize, expected: usize, desired: usize, weak: bool, so: i32, fo: i32) bool {
    return cas_usize(p, expected, desired, weak, so, fo);
}

pub fn fence(mo: i32) {
    unsafe __sc_atomic_fence(mo);
}
