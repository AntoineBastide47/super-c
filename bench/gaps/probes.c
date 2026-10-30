// The clang side of the code generation gap probes (GAPS.md): each function is the C form of the probe
// of the same name in gaps.spc, with a `c_` prefix. lib.sh archives it. The types are unsigned, so
// overflow wraps as in Super-C's release and bench profiles.
#include <stdbool.h>
#include <stdint.h>

#define F __attribute__((noinline, used))

F uint32_t c_r_sum(uint32_t n) { if (n == 0) return 0; return n + c_r_sum(n - 1); }
F uint64_t c_r_fact(uint64_t n) { if (n == 0) return 1; return n * c_r_fact(n - 1); }
F uint32_t c_r_bits(uint32_t x) { if (x == 0) return 0; return (x & 1) + c_r_bits(x >> 1); }
F uint64_t c_r_pow(uint64_t b, uint32_t e) { if (e == 0) return 1; return b * c_r_pow(b, e - 1); }
F uint32_t c_r_fib(uint32_t n) { if (n < 2) return n; return c_r_fib(n - 1) + c_r_fib(n - 2); }
F uint32_t c_r_len(uint32_t n) { if (n == 0) return 0; return 1 + c_r_len(n - 1); }
F bool c_is_even(uint32_t i) { if (i == 0) return true; return !c_is_even(i - 1); }
F uint32_t c_l_pop(uint32_t x) { uint32_t c = 0; while (x) { x &= x - 1; c++; } return c; }
F uint32_t c_l_log2(uint32_t x) { uint32_t c = 0; while (x) { x >>= 1; c++; } return c; }
F uint32_t c_b_bswap(uint32_t x) { return (x >> 24) | ((x >> 8) & 0xff00) | ((x << 8) & 0xff0000) | (x << 24); }
F uint32_t c_c_load32be(const uint8_t *b) { return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3]; }
F bool c_b_lower(uint8_t c) { return c >= 97 && c <= 122; }
F bool c_b_pow2(uint32_t x) { return x != 0 && (x & (x - 1)) == 0; }
F bool c_f_and(uint32_t x, uint32_t y, uint32_t z) { return x == 3 && y < 9 && z != 0; }
F bool c_f_or0(uint32_t x, uint32_t y) { return x == 0 || y == 0; }
bool c_r_odd(uint32_t n);
F bool c_r_even(uint32_t n) { if (n == 0) return true; return c_r_odd(n - 1); }
F bool c_r_odd(uint32_t n) { if (n == 0) return false; return c_r_even(n - 1); }
F int32_t c_s_max(int32_t a, int32_t b) { return a > b ? a : b; }
F int32_t c_s_clamp(int32_t x, int32_t lo, int32_t hi) { if (x < lo) return lo; if (x > hi) return hi; return x; }
F int32_t c_s_cmp3(int32_t a, int32_t b) { if (a < b) return -1; if (a > b) return 1; return 0; }
F int32_t c_s_abs(int32_t x) { return x < 0 ? -x : x; }
F uint32_t c_s_cinc(uint32_t a, uint32_t b, uint32_t c) { return a > b ? c + 1 : c; }
F uint32_t c_s_divmod(uint32_t a, uint32_t b) { return a / b + a % b; }
F bool c_s_srem2(int32_t x) { return x % 2 == 1; }
F uint32_t c_s_ctz(uint32_t x) { return x == 0 ? 32 : (uint32_t)__builtin_ctz(x); }
F uint32_t c_s_clz16(uint16_t x) { return x == 0 ? 16 : (uint32_t)__builtin_clz(x) - 16; }
F uint32_t c_s_shm(uint32_t x, uint32_t n) { return x << (n & 31); }
F uint32_t c_t_f0(uint32_t a) { return a * 3 + 1; }
F uint32_t c_t_f1(uint32_t a) { return a ^ 0x55; }
F uint32_t c_t_f2(uint32_t a) { return a << 2; }
F uint32_t c_t_call(uint32_t x, uint32_t a) {
  switch (x) { case 0: return c_t_f0(a); case 1: return c_t_f1(a); case 2: return c_t_f2(a); default: return a; }
}
F uint32_t c_o_ref(const uint32_t *p) { return p ? *p : 0; }
F uint32_t c_s_mulhi(uint32_t a, uint32_t b) { return (uint32_t)(((uint64_t)a * b) >> 32); }
F uint64_t c_s_ispow2m(uint64_t x, uint64_t a) { return x % 64 + a / 8; }
