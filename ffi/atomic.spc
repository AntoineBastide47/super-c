// Sequentially-consistent atomics backed by the compiler runtime's `__sc_atomic_*` builtins (lowered to
// `__atomic_*`). The runtime provides i8/i16/i32/i64/isize/u8/u16/u32/u64/usize plus bool. Pointers can
// be exchanged or compared by casting through usize.

extern "C" {
    fn __sc_atomic_load_i8(p: *const i8) i8;
    fn __sc_atomic_store_i8(p: *mut i8, v: i8);
    fn __sc_atomic_swap_i8(p: *mut i8, v: i8) i8;
    fn __sc_atomic_add_i8(p: *mut i8, v: i8) i8;
    fn __sc_atomic_sub_i8(p: *mut i8, v: i8) i8;
    fn __sc_atomic_and_i8(p: *mut i8, v: i8) i8;
    fn __sc_atomic_or_i8(p: *mut i8, v: i8) i8;
    fn __sc_atomic_xor_i8(p: *mut i8, v: i8) i8;
    fn __sc_atomic_cas_i8(p: *mut i8, expected: i8, desired: i8) bool;

    fn __sc_atomic_load_i16(p: *const i16) i16;
    fn __sc_atomic_store_i16(p: *mut i16, v: i16);
    fn __sc_atomic_swap_i16(p: *mut i16, v: i16) i16;
    fn __sc_atomic_add_i16(p: *mut i16, v: i16) i16;
    fn __sc_atomic_sub_i16(p: *mut i16, v: i16) i16;
    fn __sc_atomic_and_i16(p: *mut i16, v: i16) i16;
    fn __sc_atomic_or_i16(p: *mut i16, v: i16) i16;
    fn __sc_atomic_xor_i16(p: *mut i16, v: i16) i16;
    fn __sc_atomic_cas_i16(p: *mut i16, expected: i16, desired: i16) bool;

    fn __sc_atomic_load_i32(p: *const i32) i32;
    fn __sc_atomic_store_i32(p: *mut i32, v: i32);
    fn __sc_atomic_swap_i32(p: *mut i32, v: i32) i32;
    fn __sc_atomic_add_i32(p: *mut i32, v: i32) i32;
    fn __sc_atomic_sub_i32(p: *mut i32, v: i32) i32;
    fn __sc_atomic_and_i32(p: *mut i32, v: i32) i32;
    fn __sc_atomic_or_i32(p: *mut i32, v: i32) i32;
    fn __sc_atomic_xor_i32(p: *mut i32, v: i32) i32;
    fn __sc_atomic_cas_i32(p: *mut i32, expected: i32, desired: i32) bool;

    fn __sc_atomic_load_i64(p: *const i64) i64;
    fn __sc_atomic_store_i64(p: *mut i64, v: i64);
    fn __sc_atomic_swap_i64(p: *mut i64, v: i64) i64;
    fn __sc_atomic_add_i64(p: *mut i64, v: i64) i64;
    fn __sc_atomic_sub_i64(p: *mut i64, v: i64) i64;
    fn __sc_atomic_and_i64(p: *mut i64, v: i64) i64;
    fn __sc_atomic_or_i64(p: *mut i64, v: i64) i64;
    fn __sc_atomic_xor_i64(p: *mut i64, v: i64) i64;
    fn __sc_atomic_cas_i64(p: *mut i64, expected: i64, desired: i64) bool;

    fn __sc_atomic_load_isize(p: *const isize) isize;
    fn __sc_atomic_store_isize(p: *mut isize, v: isize);
    fn __sc_atomic_swap_isize(p: *mut isize, v: isize) isize;
    fn __sc_atomic_add_isize(p: *mut isize, v: isize) isize;
    fn __sc_atomic_sub_isize(p: *mut isize, v: isize) isize;
    fn __sc_atomic_and_isize(p: *mut isize, v: isize) isize;
    fn __sc_atomic_or_isize(p: *mut isize, v: isize) isize;
    fn __sc_atomic_xor_isize(p: *mut isize, v: isize) isize;
    fn __sc_atomic_cas_isize(p: *mut isize, expected: isize, desired: isize) bool;

    fn __sc_atomic_load_u8(p: *const u8) u8;
    fn __sc_atomic_store_u8(p: *mut u8, v: u8);
    fn __sc_atomic_swap_u8(p: *mut u8, v: u8) u8;
    fn __sc_atomic_add_u8(p: *mut u8, v: u8) u8;
    fn __sc_atomic_sub_u8(p: *mut u8, v: u8) u8;
    fn __sc_atomic_and_u8(p: *mut u8, v: u8) u8;
    fn __sc_atomic_or_u8(p: *mut u8, v: u8) u8;
    fn __sc_atomic_xor_u8(p: *mut u8, v: u8) u8;
    fn __sc_atomic_cas_u8(p: *mut u8, expected: u8, desired: u8) bool;

    fn __sc_atomic_load_u16(p: *const u16) u16;
    fn __sc_atomic_store_u16(p: *mut u16, v: u16);
    fn __sc_atomic_swap_u16(p: *mut u16, v: u16) u16;
    fn __sc_atomic_add_u16(p: *mut u16, v: u16) u16;
    fn __sc_atomic_sub_u16(p: *mut u16, v: u16) u16;
    fn __sc_atomic_and_u16(p: *mut u16, v: u16) u16;
    fn __sc_atomic_or_u16(p: *mut u16, v: u16) u16;
    fn __sc_atomic_xor_u16(p: *mut u16, v: u16) u16;
    fn __sc_atomic_cas_u16(p: *mut u16, expected: u16, desired: u16) bool;

    fn __sc_atomic_load_u32(p: *const u32) u32;
    fn __sc_atomic_store_u32(p: *mut u32, v: u32);
    fn __sc_atomic_swap_u32(p: *mut u32, v: u32) u32;
    fn __sc_atomic_add_u32(p: *mut u32, v: u32) u32;
    fn __sc_atomic_sub_u32(p: *mut u32, v: u32) u32;
    fn __sc_atomic_and_u32(p: *mut u32, v: u32) u32;
    fn __sc_atomic_or_u32(p: *mut u32, v: u32) u32;
    fn __sc_atomic_xor_u32(p: *mut u32, v: u32) u32;
    fn __sc_atomic_cas_u32(p: *mut u32, expected: u32, desired: u32) bool;

    fn __sc_atomic_load_u64(p: *const u64) u64;
    fn __sc_atomic_store_u64(p: *mut u64, v: u64);
    fn __sc_atomic_swap_u64(p: *mut u64, v: u64) u64;
    fn __sc_atomic_add_u64(p: *mut u64, v: u64) u64;
    fn __sc_atomic_sub_u64(p: *mut u64, v: u64) u64;
    fn __sc_atomic_and_u64(p: *mut u64, v: u64) u64;
    fn __sc_atomic_or_u64(p: *mut u64, v: u64) u64;
    fn __sc_atomic_xor_u64(p: *mut u64, v: u64) u64;
    fn __sc_atomic_cas_u64(p: *mut u64, expected: u64, desired: u64) bool;

    fn __sc_atomic_load_usize(p: *const usize) usize;
    fn __sc_atomic_store_usize(p: *mut usize, v: usize);
    fn __sc_atomic_swap_usize(p: *mut usize, v: usize) usize;
    fn __sc_atomic_add_usize(p: *mut usize, v: usize) usize;
    fn __sc_atomic_sub_usize(p: *mut usize, v: usize) usize;
    fn __sc_atomic_and_usize(p: *mut usize, v: usize) usize;
    fn __sc_atomic_or_usize(p: *mut usize, v: usize) usize;
    fn __sc_atomic_xor_usize(p: *mut usize, v: usize) usize;
    fn __sc_atomic_cas_usize(p: *mut usize, expected: usize, desired: usize) bool;

    fn __sc_atomic_load_bool(p: *const bool) bool;
    fn __sc_atomic_store_bool(p: *mut bool, v: bool);
    fn __sc_atomic_swap_bool(p: *mut bool, v: bool) bool;
    fn __sc_atomic_cas_bool(p: *mut bool, expected: bool, desired: bool) bool;

    fn __sc_atomic_fence();
}

pub fn load_i32(p: *const i32) i32 { return unsafe __sc_atomic_load_i32(p); }
pub fn store_i32(p: *mut i32, v: i32) { unsafe __sc_atomic_store_i32(p, v); }
pub fn swap_i32(p: *mut i32, v: i32) i32 { return unsafe __sc_atomic_swap_i32(p, v); }
pub fn add_i32(p: *mut i32, v: i32) i32 { return unsafe __sc_atomic_add_i32(p, v); }
pub fn sub_i32(p: *mut i32, v: i32) i32 { return unsafe __sc_atomic_sub_i32(p, v); }
pub fn and_i32(p: *mut i32, v: i32) i32 { return unsafe __sc_atomic_and_i32(p, v); }
pub fn or_i32(p: *mut i32, v: i32) i32 { return unsafe __sc_atomic_or_i32(p, v); }
pub fn xor_i32(p: *mut i32, v: i32) i32 { return unsafe __sc_atomic_xor_i32(p, v); }
pub fn cas_i32(p: *mut i32, expected: i32, desired: i32) bool { return unsafe __sc_atomic_cas_i32(p, expected, desired); }

pub fn load_i8(p: *const i8) i8 { return unsafe __sc_atomic_load_i8(p); }
pub fn store_i8(p: *mut i8, v: i8) { unsafe __sc_atomic_store_i8(p, v); }
pub fn swap_i8(p: *mut i8, v: i8) i8 { return unsafe __sc_atomic_swap_i8(p, v); }
pub fn add_i8(p: *mut i8, v: i8) i8 { return unsafe __sc_atomic_add_i8(p, v); }
pub fn sub_i8(p: *mut i8, v: i8) i8 { return unsafe __sc_atomic_sub_i8(p, v); }
pub fn and_i8(p: *mut i8, v: i8) i8 { return unsafe __sc_atomic_and_i8(p, v); }
pub fn or_i8(p: *mut i8, v: i8) i8 { return unsafe __sc_atomic_or_i8(p, v); }
pub fn xor_i8(p: *mut i8, v: i8) i8 { return unsafe __sc_atomic_xor_i8(p, v); }
pub fn cas_i8(p: *mut i8, expected: i8, desired: i8) bool { return unsafe __sc_atomic_cas_i8(p, expected, desired); }

pub fn load_i16(p: *const i16) i16 { return unsafe __sc_atomic_load_i16(p); }
pub fn store_i16(p: *mut i16, v: i16) { unsafe __sc_atomic_store_i16(p, v); }
pub fn swap_i16(p: *mut i16, v: i16) i16 { return unsafe __sc_atomic_swap_i16(p, v); }
pub fn add_i16(p: *mut i16, v: i16) i16 { return unsafe __sc_atomic_add_i16(p, v); }
pub fn sub_i16(p: *mut i16, v: i16) i16 { return unsafe __sc_atomic_sub_i16(p, v); }
pub fn and_i16(p: *mut i16, v: i16) i16 { return unsafe __sc_atomic_and_i16(p, v); }
pub fn or_i16(p: *mut i16, v: i16) i16 { return unsafe __sc_atomic_or_i16(p, v); }
pub fn xor_i16(p: *mut i16, v: i16) i16 { return unsafe __sc_atomic_xor_i16(p, v); }
pub fn cas_i16(p: *mut i16, expected: i16, desired: i16) bool { return unsafe __sc_atomic_cas_i16(p, expected, desired); }

pub fn load_i64(p: *const i64) i64 { return unsafe __sc_atomic_load_i64(p); }
pub fn store_i64(p: *mut i64, v: i64) { unsafe __sc_atomic_store_i64(p, v); }
pub fn swap_i64(p: *mut i64, v: i64) i64 { return unsafe __sc_atomic_swap_i64(p, v); }
pub fn add_i64(p: *mut i64, v: i64) i64 { return unsafe __sc_atomic_add_i64(p, v); }
pub fn sub_i64(p: *mut i64, v: i64) i64 { return unsafe __sc_atomic_sub_i64(p, v); }
pub fn and_i64(p: *mut i64, v: i64) i64 { return unsafe __sc_atomic_and_i64(p, v); }
pub fn or_i64(p: *mut i64, v: i64) i64 { return unsafe __sc_atomic_or_i64(p, v); }
pub fn xor_i64(p: *mut i64, v: i64) i64 { return unsafe __sc_atomic_xor_i64(p, v); }
pub fn cas_i64(p: *mut i64, expected: i64, desired: i64) bool { return unsafe __sc_atomic_cas_i64(p, expected, desired); }

pub fn load_isize(p: *const isize) isize { return unsafe __sc_atomic_load_isize(p); }
pub fn store_isize(p: *mut isize, v: isize) { unsafe __sc_atomic_store_isize(p, v); }
pub fn swap_isize(p: *mut isize, v: isize) isize { return unsafe __sc_atomic_swap_isize(p, v); }
pub fn add_isize(p: *mut isize, v: isize) isize { return unsafe __sc_atomic_add_isize(p, v); }
pub fn sub_isize(p: *mut isize, v: isize) isize { return unsafe __sc_atomic_sub_isize(p, v); }
pub fn and_isize(p: *mut isize, v: isize) isize { return unsafe __sc_atomic_and_isize(p, v); }
pub fn or_isize(p: *mut isize, v: isize) isize { return unsafe __sc_atomic_or_isize(p, v); }
pub fn xor_isize(p: *mut isize, v: isize) isize { return unsafe __sc_atomic_xor_isize(p, v); }
pub fn cas_isize(p: *mut isize, expected: isize, desired: isize) bool { return unsafe __sc_atomic_cas_isize(p, expected, desired); }

pub fn load_u8(p: *const u8) u8 { return unsafe __sc_atomic_load_u8(p); }
pub fn store_u8(p: *mut u8, v: u8) { unsafe __sc_atomic_store_u8(p, v); }
pub fn swap_u8(p: *mut u8, v: u8) u8 { return unsafe __sc_atomic_swap_u8(p, v); }
pub fn add_u8(p: *mut u8, v: u8) u8 { return unsafe __sc_atomic_add_u8(p, v); }
pub fn sub_u8(p: *mut u8, v: u8) u8 { return unsafe __sc_atomic_sub_u8(p, v); }
pub fn and_u8(p: *mut u8, v: u8) u8 { return unsafe __sc_atomic_and_u8(p, v); }
pub fn or_u8(p: *mut u8, v: u8) u8 { return unsafe __sc_atomic_or_u8(p, v); }
pub fn xor_u8(p: *mut u8, v: u8) u8 { return unsafe __sc_atomic_xor_u8(p, v); }
pub fn cas_u8(p: *mut u8, expected: u8, desired: u8) bool { return unsafe __sc_atomic_cas_u8(p, expected, desired); }

pub fn load_u16(p: *const u16) u16 { return unsafe __sc_atomic_load_u16(p); }
pub fn store_u16(p: *mut u16, v: u16) { unsafe __sc_atomic_store_u16(p, v); }
pub fn swap_u16(p: *mut u16, v: u16) u16 { return unsafe __sc_atomic_swap_u16(p, v); }
pub fn add_u16(p: *mut u16, v: u16) u16 { return unsafe __sc_atomic_add_u16(p, v); }
pub fn sub_u16(p: *mut u16, v: u16) u16 { return unsafe __sc_atomic_sub_u16(p, v); }
pub fn and_u16(p: *mut u16, v: u16) u16 { return unsafe __sc_atomic_and_u16(p, v); }
pub fn or_u16(p: *mut u16, v: u16) u16 { return unsafe __sc_atomic_or_u16(p, v); }
pub fn xor_u16(p: *mut u16, v: u16) u16 { return unsafe __sc_atomic_xor_u16(p, v); }
pub fn cas_u16(p: *mut u16, expected: u16, desired: u16) bool { return unsafe __sc_atomic_cas_u16(p, expected, desired); }

pub fn load_u32(p: *const u32) u32 { return unsafe __sc_atomic_load_u32(p); }
pub fn store_u32(p: *mut u32, v: u32) { unsafe __sc_atomic_store_u32(p, v); }
pub fn swap_u32(p: *mut u32, v: u32) u32 { return unsafe __sc_atomic_swap_u32(p, v); }
pub fn add_u32(p: *mut u32, v: u32) u32 { return unsafe __sc_atomic_add_u32(p, v); }
pub fn sub_u32(p: *mut u32, v: u32) u32 { return unsafe __sc_atomic_sub_u32(p, v); }
pub fn and_u32(p: *mut u32, v: u32) u32 { return unsafe __sc_atomic_and_u32(p, v); }
pub fn or_u32(p: *mut u32, v: u32) u32 { return unsafe __sc_atomic_or_u32(p, v); }
pub fn xor_u32(p: *mut u32, v: u32) u32 { return unsafe __sc_atomic_xor_u32(p, v); }
pub fn cas_u32(p: *mut u32, expected: u32, desired: u32) bool { return unsafe __sc_atomic_cas_u32(p, expected, desired); }

pub fn load_u64(p: *const u64) u64 { return unsafe __sc_atomic_load_u64(p); }
pub fn store_u64(p: *mut u64, v: u64) { unsafe __sc_atomic_store_u64(p, v); }
pub fn swap_u64(p: *mut u64, v: u64) u64 { return unsafe __sc_atomic_swap_u64(p, v); }
pub fn add_u64(p: *mut u64, v: u64) u64 { return unsafe __sc_atomic_add_u64(p, v); }
pub fn sub_u64(p: *mut u64, v: u64) u64 { return unsafe __sc_atomic_sub_u64(p, v); }
pub fn and_u64(p: *mut u64, v: u64) u64 { return unsafe __sc_atomic_and_u64(p, v); }
pub fn or_u64(p: *mut u64, v: u64) u64 { return unsafe __sc_atomic_or_u64(p, v); }
pub fn xor_u64(p: *mut u64, v: u64) u64 { return unsafe __sc_atomic_xor_u64(p, v); }
pub fn cas_u64(p: *mut u64, expected: u64, desired: u64) bool { return unsafe __sc_atomic_cas_u64(p, expected, desired); }

pub fn load_usize(p: *const usize) usize { return unsafe __sc_atomic_load_usize(p); }
pub fn store_usize(p: *mut usize, v: usize) { unsafe __sc_atomic_store_usize(p, v); }
pub fn swap_usize(p: *mut usize, v: usize) usize { return unsafe __sc_atomic_swap_usize(p, v); }
pub fn add_usize(p: *mut usize, v: usize) usize { return unsafe __sc_atomic_add_usize(p, v); }
pub fn sub_usize(p: *mut usize, v: usize) usize { return unsafe __sc_atomic_sub_usize(p, v); }
pub fn and_usize(p: *mut usize, v: usize) usize { return unsafe __sc_atomic_and_usize(p, v); }
pub fn or_usize(p: *mut usize, v: usize) usize { return unsafe __sc_atomic_or_usize(p, v); }
pub fn xor_usize(p: *mut usize, v: usize) usize { return unsafe __sc_atomic_xor_usize(p, v); }
pub fn cas_usize(p: *mut usize, expected: usize, desired: usize) bool { return unsafe __sc_atomic_cas_usize(p, expected, desired); }

pub fn load_bool(p: *const bool) bool { return unsafe __sc_atomic_load_bool(p); }
pub fn store_bool(p: *mut bool, v: bool) { unsafe __sc_atomic_store_bool(p, v); }
pub fn swap_bool(p: *mut bool, v: bool) bool { return unsafe __sc_atomic_swap_bool(p, v); }
pub fn cas_bool(p: *mut bool, expected: bool, desired: bool) bool { return unsafe __sc_atomic_cas_bool(p, expected, desired); }

pub fn load_ptr(p: *const usize) usize { return load_usize(p); }
pub fn store_ptr(p: *mut usize, v: usize) { store_usize(p, v); }
pub fn swap_ptr(p: *mut usize, v: usize) usize { return swap_usize(p, v); }
pub fn cas_ptr(p: *mut usize, expected: usize, desired: usize) bool { return cas_usize(p, expected, desired); }

pub fn fence() { unsafe __sc_atomic_fence(); }
