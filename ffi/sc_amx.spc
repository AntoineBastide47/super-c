// AMX matrix kernels for std::simd::matrix: byte products into 32-bit sums on the tile registers
// (AMX-INT8), a 32 x 32 block of the result per step of 64 of the inner dimension. The kernel is
// module-level assembly; the Super-C entry points ask Linux for the tile state, pack the operands and
// copy the result out. A kernel runs only where the CPU has AMX-INT8 (`cpu::Feature::AmxInt8`). Every
// result equals the portable kernel's: element (i, j) is the sum over p of the products modulo 2^32
// (`tdpbssd` and `tdpbusd` wrap). Prefer `std::simd::matrix`, which checks the shapes and chooses a
// kernel by the CPU.
import std::cpu;
import atomic;
import stdlib;
import string as cstring;

/// 1 where this module has the kernels (Linux on x86_64), else 0.
pub const fn sc_amx_built() i32 {
    if PLATFORM == Platform::Linux && ARCH == Arch::X86_64 {
        return 1;
    }
    return 0;
}

/// `c` (m x n, i32) = `a` (m x k) * `b` (k x n), the bytes of `a` signed, or unsigned when `ua`, those
/// of `b` signed: each element the sum of the products modulo 2^32. 0, or -1 (`c` untouched) when the
/// kernels are not built, Linux refuses the tile state, or the scratch cannot be allocated. The caller
/// guarantees the three extents.
@platform(linux)
@arch(x86_64)
@target_feature([cpu::Feature::AmxInt8])
pub unsafe fn sc_amx_mul_i8(c: *mut i32, a: *const u8, b: *const u8, m: usize, k: usize, n: usize, ua: bool) i32 {
    if !permitted() {
        return -1;
    }
    // The extents padded: rows to the block's 32, columns to 32, the inner dimension to a tile row's 64.
    let mp = m + 31 & ~31usize;
    let np = n + 31 & ~31usize;
    let kp = k + 63 & ~63usize;
    if m == 0 || n == 0 || k == 0 || mp < m || np < n || kp < k {
        return -1;
    }
    // `a` and `c` serve in place when no extent pads; else a copy of their rows, the padding zero.
    let a_in = mp == m && kp == k;
    let c_in = mp == m && np == n;
    let (sa0, o1) = mp.overflowing_mul(kp);
    let (sb, o2) = kp.overflowing_mul(np);
    let (sc0, o3) = mp.overflowing_mul(np);
    let (sc1, o4) = sc0.overflowing_mul(4);
    let sa = if a_in {
        0usize
    } else {
        sa0
    };
    let sc = if c_in {
        0usize
    } else {
        sc1
    };
    // One allocation: `b` in groups of four rows (each column's four bytes one word, np words a group),
    // then `a` and the result when they do not serve in place.
    let (s1, o5) = sb.overflowing_add(sa);
    let (total, o6) = s1.overflowing_add(sc);
    if o1 || o2 || o3 || o4 || o5 || o6 {
        return -1;
    }
    let buf = stdlib::calloc(total, 1) as *mut u8;
    if buf == null {
        return -1;
    }
    let pb = buf as *mut u32;
    let pw = buf + sb;
    let pa = if a_in {
        a
    } else {
        pw as *const u8
    };
    let pc = if c_in {
        c
    } else {
        (buf + sb + sa) as *mut i32
    };
    if !a_in {
        for i in 0..m {
            cstring::memcpy(pw + i * kp, a + i * k, k);
        }
    }
    // Group g: rows 4g to 4g + 3 of `b` (0 past row k - 1), column j's four bytes in word g * np + j.
    for g in 0..(k + 3) / 4 {
        let r = 4 * g;
        let b0 = b + r * n;
        for j in 0..n {
            let mut w = b0[j] as u32;
            if r + 1 < k {
                w |= b0[n + j] as u32 << 8;
            }
            if r + 2 < k {
                w |= b0[2 * n + j] as u32 << 16;
            }
            if r + 3 < k {
                w |= b0[3 * n + j] as u32 << 24;
            }
            pb[g * np + j] = w;
        }
    }
    let mut job = Job { c: pc, a: pa, b: buf, mp: mp, np: np, kp: kp, ua: ua as usize, cfg: [0; 64] };
    // Palette 1; tiles 0 to 7 of 16 rows of 64 bytes (bytes 16 to 31: each tile's row bytes, two each;
    // bytes 48 to 55: its rows).
    job.cfg[0] = 1;
    for t in 0..8usize {
        job.cfg[16 + 2 * t] = 64;
        job.cfg[48 + t] = 16;
    }
    sc_amx_i8_tiles(&mut job);
    if !c_in {
        for i in 0..m {
            cstring::memcpy(c + i * n, pc + i * np, n * 4);
        }
    }
    stdlib::free(buf);
    return 0;
}

@platform(!linux)
@arch(x86_64)
@target_feature([cpu::Feature::AmxInt8])
pub unsafe fn sc_amx_mul_i8(_c: *mut i32, _a: *const u8, _b: *const u8, _m: usize, _k: usize, _n: usize, _ua: bool) i32 {
    return -1;
}

// The kernel's operands (`sc_amx_i8_tiles`): the padded result, the packed operands, the padded extents,
// 1 for unsigned bytes of `a`, and the tile configuration `ldtilecfg` reads.
@platform(linux)
@arch(x86_64)
struct Job {
    c: *mut i32,
    a: *const u8,
    b: *const u8,
    mp: usize,
    np: usize,
    kp: usize,
    ua: usize,
    cfg: [u8; 64],
}

/// Whether this process may use the tiles: Linux granted the tile data state (asked on the first call).
/// False where the kernels are not built.
@platform(linux)
@arch(x86_64)
pub fn sc_amx_ready() bool {
    return permitted();
}

@platform(!linux)
@arch(x86_64)
pub fn sc_amx_ready() bool {
    return false;
}

@arch(!x86_64)
pub fn sc_amx_ready() bool {
    return false;
}

// Whether Linux gives this process the tile data state (`arch_prctl(ARCH_REQ_XCOMP_PERM,
// XFEATURE_XTILEDATA)`), asked once: 1 granted, 2 refused, 0 not asked. Two first callers ask alike.
@platform(linux)
@arch(x86_64)
static mut PERMIT: i32 = 0;

@platform(linux)
@arch(x86_64)
fn permitted() bool {
    let s = unsafe atomic::load_i32(&PERMIT, 1);
    if s != 0 {
        return s == 1;
    }
    let ok = unsafe sc_amx_permit() == 0;
    unsafe atomic::store_i32(&mut PERMIT, 2 - ok as i32, 2);
    return ok;
}

// `sc_amx_i8_tiles(job)`: for each 32 x 32 block of the padded result (rows i0 in rbx, columns j0 in
// rcx), tiles 0 to 3 hold its four 16 x 16 quarters, zeroed; each step of 64 bytes of the inner
// dimension loads rows i0 and i0 + 16 of `a` (tiles 4, 5: 64 bytes of each of 16 rows, kp apart) and
// the groups of `b` (tiles 6, 7: 16 groups of four rows, columns j0 and j0 + 16), and adds the four
// products, `tdpbssd` or for unsigned bytes of `a` `tdpbusd`. Registers: r8 the result, r9 `a`, r10 `b`,
// r11 mp, r12 np, r13 kp, r14 the kind, r15 np * 4 (a row of the result and a group of `b`, in bytes),
// rsi and rbp the two rows of `a`, rdi the groups of `b`, rax the bytes of the inner dimension left.
// `sc_amx_permit()`: the system call's result, 0 when granted.
@platform(linux)
@arch(x86_64)
asm(M"(.text
.p2align 4
sc_amx_i8_tiles:
push %rbx
push %rbp
push %r12
push %r13
push %r14
push %r15
ldtilecfg 56(%rdi)
mov (%rdi), %r8
mov 8(%rdi), %r9
mov 16(%rdi), %r10
mov 24(%rdi), %r11
mov 32(%rdi), %r12
mov 40(%rdi), %r13
mov 48(%rdi), %r14
lea (,%r12,4), %r15
xor %ebx, %ebx
.Lamx_rows:
xor %ecx, %ecx
.Lamx_cols:
tilezero %tmm0
tilezero %tmm1
tilezero %tmm2
tilezero %tmm3
mov %rbx, %rax
imul %r13, %rax
lea (%r9,%rax), %rsi
mov %r13, %rdx
shl $4, %rdx
lea (%rsi,%rdx), %rbp
lea (%r10,%rcx,4), %rdi
mov %r13, %rax
.Lamx_inner:
tileloadd (%rsi,%r13,1), %tmm4
tileloadd (%rbp,%r13,1), %tmm5
tileloadd (%rdi,%r15,1), %tmm6
tileloadd 64(%rdi,%r15,1), %tmm7
test %r14, %r14
jnz .Lamx_unsigned
tdpbssd %tmm6, %tmm4, %tmm0
tdpbssd %tmm7, %tmm4, %tmm1
tdpbssd %tmm6, %tmm5, %tmm2
tdpbssd %tmm7, %tmm5, %tmm3
jmp .Lamx_next
.Lamx_unsigned:
tdpbusd %tmm6, %tmm4, %tmm0
tdpbusd %tmm7, %tmm4, %tmm1
tdpbusd %tmm6, %tmm5, %tmm2
tdpbusd %tmm7, %tmm5, %tmm3
.Lamx_next:
add $64, %rsi
add $64, %rbp
mov %r15, %rdx
shl $4, %rdx
add %rdx, %rdi
sub $64, %rax
jnz .Lamx_inner
mov %rbx, %rax
imul %r12, %rax
add %rcx, %rax
lea (%r8,%rax,4), %rdx
tilestored %tmm0, (%rdx,%r15,1)
tilestored %tmm1, 64(%rdx,%r15,1)
mov %r15, %rax
shl $4, %rax
add %rax, %rdx
tilestored %tmm2, (%rdx,%r15,1)
tilestored %tmm3, 64(%rdx,%r15,1)
add $32, %rcx
cmp %r12, %rcx
jb .Lamx_cols
add $32, %rbx
cmp %r11, %rbx
jb .Lamx_rows
tilerelease
pop %r15
pop %r14
pop %r13
pop %r12
pop %rbp
pop %rbx
ret
.p2align 4
sc_amx_permit:
mov $158, %eax
mov $0x1023, %edi
mov $18, %esi
syscall
ret
.globl sc_amx_i8_tiles
.hidden sc_amx_i8_tiles
.type sc_amx_i8_tiles, @function
.globl sc_amx_permit
.hidden sc_amx_permit
.type sc_amx_permit, @function
)");

@platform(linux)
@arch(x86_64)
extern "C" {
    fn sc_amx_i8_tiles(job: *mut Job);
    fn sc_amx_permit() i64;
}
