// X25519 (RFC 7748, 5), proved: the specification is the RFC's Montgomery ladder on the integers modulo
// p = 2^255 - 19 (`scalar_mult`), and `x25519` computes exactly the u-coordinate it defines, encoded in 32
// little-endian bytes. The implementation holds a field element in ten limbs of 26 and 25 bits (`val`),
// swaps with `Secret::pick`, and inverts by Fermat's theorem; each function runs in constant time on the
// scalar and the coordinate (`@constant_time`). No operation panics. Import with
// `import std::crypto::x25519;`.

import std::crypto::secret as *;
import std::spec::arith;

// The prime 2^255 - 19.
pub(package) spec fn p() int {
    return 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed;
}

// The value of limbs `f`: limb `i` at weight 2^ceil(25.5 i), 26 bits at even `i` and 25 at odd `i`.
pub(package) spec fn val(f: [Secret<u64>; 10]) int {
    return f[0].value() as int + f[1].value() as int * 0x4000000 + f[2].value() as int * 0x8000000000000 + f[3].value() as int * 0x20000000000000000000 + f[4].value() as int * 0x40000000000000000000000000 + f[5].value() as int * 0x100000000000000000000000000000000 + f[6].value() as int * 0x200000000000000000000000000000000000000 + f[7].value() as int * 0x800000000000000000000000000000000000000000000 + f[8].value() as int * 0x1000000000000000000000000000000000000000000000000000 + f[9].value() as int * 0x4000000000000000000000000000000000000000000000000000000000;
}

// The value of column sums `d` at the limb weights.
spec fn dval(d: [Secret<u64>; 10]) int {
    return d[0].value() as int + d[1].value() as int * 0x4000000 + d[2].value() as int * 0x8000000000000 + d[3].value() as int * 0x20000000000000000000 + d[4].value() as int * 0x40000000000000000000000000 + d[5].value() as int * 0x100000000000000000000000000000000 + d[6].value() as int * 0x200000000000000000000000000000000000000 + d[7].value() as int * 0x800000000000000000000000000000000000000000000 + d[8].value() as int * 0x1000000000000000000000000000000000000000000000000000 + d[9].value() as int * 0x4000000000000000000000000000000000000000000000000000000000;
}

// The limbs `carry` leaves: each below its width, but the second, below 2^25 + 2^20.
pub(package) spec fn carried(f: [Secret<u64>; 10]) bool {
    return f[0].value() < 0x4000000 && f[1].value() < 0x2100000 && f[2].value() < 0x4000000 && f[3].value() < 0x2000000 && f[4].value() < 0x4000000 && f[5].value() < 0x2000000 && f[6].value() < 0x4000000 && f[7].value() < 0x2000000 && f[8].value() < 0x4000000 && f[9].value() < 0x2000000;
}

// The limbs `mul` takes: each below 4 times its width.
pub(package) spec fn loose(f: [Secret<u64>; 10]) bool {
    return f[0].value() < 0x10000000 && f[1].value() < 0x8000000 && f[2].value() < 0x10000000 && f[3].value() < 0x8000000 && f[4].value() < 0x10000000 && f[5].value() < 0x8000000 && f[6].value() < 0x10000000 && f[7].value() < 0x8000000 && f[8].value() < 0x10000000 && f[9].value() < 0x8000000;
}

// Limbs `f2` are twice limbs `f`.
spec fn doubled(f: [Secret<u64>; 10], f2: [Secret<u64>; 10]) bool {
    return f2[0].value() as int == 2 * f[0].value() as int && f2[1].value() as int == 2 * f[1].value() as int && f2[2].value() as int == 2 * f[2].value() as int && f2[3].value() as int == 2 * f[3].value() as int && f2[4].value() as int == 2 * f[4].value() as int && f2[5].value() as int == 2 * f[5].value() as int && f2[6].value() as int == 2 * f[6].value() as int && f2[7].value() as int == 2 * f[7].value() as int && f2[8].value() as int == 2 * f[8].value() as int && f2[9].value() as int == 2 * f[9].value() as int;
}

// Limbs `g19` are 19 times limbs `g`.
spec fn times19(g: [Secret<u64>; 10], g19: [Secret<u64>; 10]) bool {
    return g19[0].value() as int == 19 * g[0].value() as int && g19[1].value() as int == 19 * g[1].value() as int && g19[2].value() as int == 19 * g[2].value() as int && g19[3].value() as int == 19 * g[3].value() as int && g19[4].value() as int == 19 * g[4].value() as int && g19[5].value() as int == 19 * g[5].value() as int && g19[6].value() as int == 19 * g[6].value() as int && g19[7].value() as int == 19 * g[7].value() as int && g19[8].value() as int == 19 * g[8].value() as int && g19[9].value() as int == 19 * g[9].value() as int;
}

// The products of the limbs at their weights: the column sums of `mul` plus a multiple of p, since
// 2^255 = p + 19 and the weights of two odd limbs add to one more than their column's.
lemma product_id(
    p00: int,
    p01: int,
    p02: int,
    p03: int,
    p04: int,
    p05: int,
    p06: int,
    p07: int,
    p08: int,
    p09: int,
    p10: int,
    p11: int,
    p12: int,
    p13: int,
    p14: int,
    p15: int,
    p16: int,
    p17: int,
    p18: int,
    p19: int,
    p20: int,
    p21: int,
    p22: int,
    p23: int,
    p24: int,
    p25: int,
    p26: int,
    p27: int,
    p28: int,
    p29: int,
    p30: int,
    p31: int,
    p32: int,
    p33: int,
    p34: int,
    p35: int,
    p36: int,
    p37: int,
    p38: int,
    p39: int,
    p40: int,
    p41: int,
    p42: int,
    p43: int,
    p44: int,
    p45: int,
    p46: int,
    p47: int,
    p48: int,
    p49: int,
    p50: int,
    p51: int,
    p52: int,
    p53: int,
    p54: int,
    p55: int,
    p56: int,
    p57: int,
    p58: int,
    p59: int,
    p60: int,
    p61: int,
    p62: int,
    p63: int,
    p64: int,
    p65: int,
    p66: int,
    p67: int,
    p68: int,
    p69: int,
    p70: int,
    p71: int,
    p72: int,
    p73: int,
    p74: int,
    p75: int,
    p76: int,
    p77: int,
    p78: int,
    p79: int,
    p80: int,
    p81: int,
    p82: int,
    p83: int,
    p84: int,
    p85: int,
    p86: int,
    p87: int,
    p88: int,
    p89: int,
    p90: int,
    p91: int,
    p92: int,
    p93: int,
    p94: int,
    p95: int,
    p96: int,
    p97: int,
    p98: int,
    p99: int,
)
    ensures p00 + p01 * 0x4000000 + p02 * 0x8000000000000 + p03 * 0x20000000000000000000 + p04 * 0x40000000000000000000000000 + p05 * 0x100000000000000000000000000000000 + p06 * 0x200000000000000000000000000000000000000 + p07 * 0x800000000000000000000000000000000000000000000 + p08 * 0x1000000000000000000000000000000000000000000000000000 + p09 * 0x4000000000000000000000000000000000000000000000000000000000 + p10 * 0x4000000 + p11 * 0x10000000000000 + p12 * 0x20000000000000000000 + p13 * 0x80000000000000000000000000 + p14 * 0x100000000000000000000000000000000 + p15 * 0x400000000000000000000000000000000000000 + p16 * 0x800000000000000000000000000000000000000000000 + p17 * 0x2000000000000000000000000000000000000000000000000000 + p18 * 0x4000000000000000000000000000000000000000000000000000000000 + p19 * 0x10000000000000000000000000000000000000000000000000000000000000000 + p20 * 0x8000000000000 + p21 * 0x20000000000000000000 + p22 * 0x40000000000000000000000000 + p23 * 0x100000000000000000000000000000000 + p24 * 0x200000000000000000000000000000000000000 + p25 * 0x800000000000000000000000000000000000000000000 + p26 * 0x1000000000000000000000000000000000000000000000000000 + p27 * 0x4000000000000000000000000000000000000000000000000000000000 + p28 * 0x8000000000000000000000000000000000000000000000000000000000000000 + p29 * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + p30 * 0x20000000000000000000 + p31 * 0x80000000000000000000000000 + p32 * 0x100000000000000000000000000000000 + p33 * 0x400000000000000000000000000000000000000 + p34 * 0x800000000000000000000000000000000000000000000 + p35 * 0x2000000000000000000000000000000000000000000000000000 + p36 * 0x4000000000000000000000000000000000000000000000000000000000 + p37 * 0x10000000000000000000000000000000000000000000000000000000000000000 + p38 * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + p39 * 0x80000000000000000000000000000000000000000000000000000000000000000000000000000 + p40 * 0x40000000000000000000000000 + p41 * 0x100000000000000000000000000000000 + p42 * 0x200000000000000000000000000000000000000 + p43 * 0x800000000000000000000000000000000000000000000 + p44 * 0x1000000000000000000000000000000000000000000000000000 + p45 * 0x4000000000000000000000000000000000000000000000000000000000 + p46 * 0x8000000000000000000000000000000000000000000000000000000000000000 + p47 * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + p48 * 0x40000000000000000000000000000000000000000000000000000000000000000000000000000 + p49 * 0x100000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p50 * 0x100000000000000000000000000000000 + p51 * 0x400000000000000000000000000000000000000 + p52 * 0x800000000000000000000000000000000000000000000 + p53 * 0x2000000000000000000000000000000000000000000000000000 + p54 * 0x4000000000000000000000000000000000000000000000000000000000 + p55 * 0x10000000000000000000000000000000000000000000000000000000000000000 + p56 * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + p57 * 0x80000000000000000000000000000000000000000000000000000000000000000000000000000 + p58 * 0x100000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p59 * 0x400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p60 * 0x200000000000000000000000000000000000000 + p61 * 0x800000000000000000000000000000000000000000000 + p62 * 0x1000000000000000000000000000000000000000000000000000 + p63 * 0x4000000000000000000000000000000000000000000000000000000000 + p64 * 0x8000000000000000000000000000000000000000000000000000000000000000 + p65 * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + p66 * 0x40000000000000000000000000000000000000000000000000000000000000000000000000000 + p67 * 0x100000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p68 * 0x200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p69 * 0x800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p70 * 0x800000000000000000000000000000000000000000000 + p71 * 0x2000000000000000000000000000000000000000000000000000 + p72 * 0x4000000000000000000000000000000000000000000000000000000000 + p73 * 0x10000000000000000000000000000000000000000000000000000000000000000 + p74 * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + p75 * 0x80000000000000000000000000000000000000000000000000000000000000000000000000000 + p76 * 0x100000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p77 * 0x400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p78 * 0x800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p79 * 0x2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p80 * 0x1000000000000000000000000000000000000000000000000000 + p81 * 0x4000000000000000000000000000000000000000000000000000000000 + p82 * 0x8000000000000000000000000000000000000000000000000000000000000000 + p83 * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + p84 * 0x40000000000000000000000000000000000000000000000000000000000000000000000000000 + p85 * 0x100000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p86 * 0x200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p87 * 0x800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p88 * 0x1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p89 * 0x4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p90 * 0x4000000000000000000000000000000000000000000000000000000000 + p91 * 0x10000000000000000000000000000000000000000000000000000000000000000 + p92 * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + p93 * 0x80000000000000000000000000000000000000000000000000000000000000000000000000000 + p94 * 0x100000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p95 * 0x400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p96 * 0x800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p97 * 0x2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p98 * 0x4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + p99 * 0x10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 == p00 + 38 * p19 + 19 * p28 + 38 * p37 + 19 * p46 + 38 * p55 + 19 * p64 + 38 * p73 + 19 * p82 + 38 * p91 + (p01 + p10 + 19 * p29 + 19 * p38 + 19 * p47 + 19 * p56 + 19 * p65 + 19 * p74 + 19 * p83 + 19 * p92) * 0x4000000 + (p02 + 2 * p11 + p20 + 38 * p39 + 19 * p48 + 38 * p57 + 19 * p66 + 38 * p75 + 19 * p84 + 38 * p93) * 0x8000000000000 + (p03 + p12 + p21 + p30 + 19 * p49 + 19 * p58 + 19 * p67 + 19 * p76 + 19 * p85 + 19 * p94) * 0x20000000000000000000 + (p04 + 2 * p13 + p22 + 2 * p31 + p40 + 38 * p59 + 19 * p68 + 38 * p77 + 19 * p86 + 38 * p95) * 0x40000000000000000000000000 + (p05 + p14 + p23 + p32 + p41 + p50 + 19 * p69 + 19 * p78 + 19 * p87 + 19 * p96) * 0x100000000000000000000000000000000 + (p06 + 2 * p15 + p24 + 2 * p33 + p42 + 2 * p51 + p60 + 38 * p79 + 19 * p88 + 38 * p97) * 0x200000000000000000000000000000000000000 + (p07 + p16 + p25 + p34 + p43 + p52 + p61 + p70 + 19 * p89 + 19 * p98) * 0x800000000000000000000000000000000000000000000 + (p08 + 2 * p17 + p26 + 2 * p35 + p44 + 2 * p53 + p62 + 2 * p71 + p80 + 38 * p99) * 0x1000000000000000000000000000000000000000000000000000 + (p09 + p18 + p27 + p36 + p45 + p54 + p63 + p72 + p81 + p90) * 0x4000000000000000000000000000000000000000000000000000000000 + p() * (2 * p19 + p28 + p29 * 0x4000000 + 2 * p37 + p38 * 0x4000000 + 2 * p39 * 0x8000000000000 + p46 + p47 * 0x4000000 + p48 * 0x8000000000000 + p49 * 0x20000000000000000000 + 2 * p55 + p56 * 0x4000000 + 2 * p57 * 0x8000000000000 + p58 * 0x20000000000000000000 + 2 * p59 * 0x40000000000000000000000000 + p64 + p65 * 0x4000000 + p66 * 0x8000000000000 + p67 * 0x20000000000000000000 + p68 * 0x40000000000000000000000000 + p69 * 0x100000000000000000000000000000000 + 2 * p73 + p74 * 0x4000000 + 2 * p75 * 0x8000000000000 + p76 * 0x20000000000000000000 + 2 * p77 * 0x40000000000000000000000000 + p78 * 0x100000000000000000000000000000000 + 2 * p79 * 0x200000000000000000000000000000000000000 + p82 + p83 * 0x4000000 + p84 * 0x8000000000000 + p85 * 0x20000000000000000000 + p86 * 0x40000000000000000000000000 + p87 * 0x100000000000000000000000000000000 + p88 * 0x200000000000000000000000000000000000000 + p89 * 0x800000000000000000000000000000000000000000000 + 2 * p91 + p92 * 0x4000000 + 2 * p93 * 0x8000000000000 + p94 * 0x20000000000000000000 + 2 * p95 * 0x40000000000000000000000000 + p96 * 0x100000000000000000000000000000000 + 2 * p97 * 0x200000000000000000000000000000000000000 + p98 * 0x800000000000000000000000000000000000000000000 + 2 * p99 * 0x1000000000000000000000000000000000000000000000000000)
{}

// `a` times the value `g` of limbs `b0` to `b9`.
lemma row(a: int, g: int, b0: int, b1: int, b2: int, b3: int, b4: int, b5: int, b6: int, b7: int, b8: int, b9: int)
    requires g == b0 + b1 * 0x4000000 + b2 * 0x8000000000000 + b3 * 0x20000000000000000000 + b4 * 0x40000000000000000000000000 + b5 * 0x100000000000000000000000000000000 + b6 * 0x200000000000000000000000000000000000000 + b7 * 0x800000000000000000000000000000000000000000000 + b8 * 0x1000000000000000000000000000000000000000000000000000 + b9 * 0x4000000000000000000000000000000000000000000000000000000000
    ensures a * g == a * b0 + a * b1 * 0x4000000 + a * b2 * 0x8000000000000 + a * b3 * 0x20000000000000000000 + a * b4 * 0x40000000000000000000000000 + a * b5 * 0x100000000000000000000000000000000 + a * b6 * 0x200000000000000000000000000000000000000 + a * b7 * 0x800000000000000000000000000000000000000000000 + a * b8 * 0x1000000000000000000000000000000000000000000000000000 + a * b9 * 0x4000000000000000000000000000000000000000000000000000000000
{
    arith::mul_eq(
        a,
        g,
        b0 + b1 * 0x4000000 + b2 * 0x8000000000000 + b3 * 0x20000000000000000000 + b4 * 0x40000000000000000000000000 + b5 * 0x100000000000000000000000000000000 + b6 * 0x200000000000000000000000000000000000000 + b7 * 0x800000000000000000000000000000000000000000000 + b8 * 0x1000000000000000000000000000000000000000000000000000 + b9 * 0x4000000000000000000000000000000000000000000000000000000000,
    );
}

// The value `f` of limbs `a0` to `a9` times `g`.
lemma column(f: int, g: int, a0: int, a1: int, a2: int, a3: int, a4: int, a5: int, a6: int, a7: int, a8: int, a9: int)
    requires f == a0 + a1 * 0x4000000 + a2 * 0x8000000000000 + a3 * 0x20000000000000000000 + a4 * 0x40000000000000000000000000 + a5 * 0x100000000000000000000000000000000 + a6 * 0x200000000000000000000000000000000000000 + a7 * 0x800000000000000000000000000000000000000000000 + a8 * 0x1000000000000000000000000000000000000000000000000000 + a9 * 0x4000000000000000000000000000000000000000000000000000000000
    ensures f * g == a0 * g + a1 * g * 0x4000000 + a2 * g * 0x8000000000000 + a3 * g * 0x20000000000000000000 + a4 * g * 0x40000000000000000000000000 + a5 * g * 0x100000000000000000000000000000000 + a6 * g * 0x200000000000000000000000000000000000000 + a7 * g * 0x800000000000000000000000000000000000000000000 + a8 * g * 0x1000000000000000000000000000000000000000000000000000 + a9 * g * 0x4000000000000000000000000000000000000000000000000000000000
{
    arith::mul_eq(
        g,
        f,
        a0 + a1 * 0x4000000 + a2 * 0x8000000000000 + a3 * 0x20000000000000000000 + a4 * 0x40000000000000000000000000 + a5 * 0x100000000000000000000000000000000 + a6 * 0x200000000000000000000000000000000000000 + a7 * 0x800000000000000000000000000000000000000000000 + a8 * 0x1000000000000000000000000000000000000000000000000000 + a9 * 0x4000000000000000000000000000000000000000000000000000000000,
    );
}

// A product of two values at most `x` and `y` is at most `x * y`.
lemma product_below(a: int, b: int, x: int, y: int)
    requires 0 <= a && a <= x && 0 <= b && b <= y
    ensures a * b <= x * y
{
    arith::mul_le(a, x, b);
    arith::mul_le(b, y, x);
}

// `c + a * b`, below 2^64.
@constant_time
const fn mul_add(c: Secret<u64>, a: Secret<u64>, b: Secret<u64>) Secret<u64>
    requires c.value() as int + a.value() as int * b.value() as int < 0x10000000000000000
    ensures |o| o.value() as int == c.value() as int + a.value() as int * b.value() as int
{
    return c + a * b;
}

// `a + b`, below 2^64.
@constant_time
const fn add(a: Secret<u64>, b: Secret<u64>) Secret<u64>
    requires a.value() as int + b.value() as int < 0x10000000000000000
    ensures |o| o.value() as int == a.value() as int + b.value() as int
{
    return a + b;
}

// `m * a`, below 2^64.
@constant_time
const fn times(a: Secret<u64>, m: u64) Secret<u64>
    requires a.value() as int * m as int < 0x10000000000000000
    ensures |o| o.value() as int == m as int * a.value() as int
{
    return a * Secret::new(m);
}

// Column 0 of the product of `f` and `g`: `f2` holds twice the limbs of `f`, `g19` 19 times those of `g`.
@constant_time
fn column0(f: [Secret<u64>; 10], g: [Secret<u64>; 10], f2: [Secret<u64>; 10], g19: [Secret<u64>; 10]) Secret<u64>
    requires loose(f) && loose(g) && doubled(f, f2) && times19(g, g19)
    ensures |o| o.value() as int == f[0].value() as int * g[0].value() as int + 38 * (f[1].value() as int * g[9].value() as int) + 19 * (f[2].value() as int * g[8].value() as int) + 38 * (f[3].value() as int * g[7].value() as int) + 19 * (f[4].value() as int * g[6].value() as int) + 38 * (f[5].value() as int * g[5].value() as int) + 19 * (f[6].value() as int * g[4].value() as int) + 38 * (f[7].value() as int * g[3].value() as int) + 19 * (f[8].value() as int * g[2].value() as int) + 38 * (f[9].value() as int * g[1].value() as int)
    ensures |o| o.value() < 0x8000000000000000
{
    product_below(f[0].value() as int, g[0].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[1].value() as int, g19[9].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[1].value() as int, g19[9].value() as int, 19 * g[9].value() as int);
    arith::mul_eq(g[9].value() as int, f2[1].value() as int, 2 * f[1].value() as int);
    product_below(f[2].value() as int, g19[8].value() as int, 0xfffffff, 0x12fffffed);
    arith::mul_eq(f[2].value() as int, g19[8].value() as int, 19 * g[8].value() as int);
    product_below(f2[3].value() as int, g19[7].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[3].value() as int, g19[7].value() as int, 19 * g[7].value() as int);
    arith::mul_eq(g[7].value() as int, f2[3].value() as int, 2 * f[3].value() as int);
    product_below(f[4].value() as int, g19[6].value() as int, 0xfffffff, 0x12fffffed);
    arith::mul_eq(f[4].value() as int, g19[6].value() as int, 19 * g[6].value() as int);
    product_below(f2[5].value() as int, g19[5].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[5].value() as int, g19[5].value() as int, 19 * g[5].value() as int);
    arith::mul_eq(g[5].value() as int, f2[5].value() as int, 2 * f[5].value() as int);
    product_below(f[6].value() as int, g19[4].value() as int, 0xfffffff, 0x12fffffed);
    arith::mul_eq(f[6].value() as int, g19[4].value() as int, 19 * g[4].value() as int);
    product_below(f2[7].value() as int, g19[3].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[7].value() as int, g19[3].value() as int, 19 * g[3].value() as int);
    arith::mul_eq(g[3].value() as int, f2[7].value() as int, 2 * f[7].value() as int);
    product_below(f[8].value() as int, g19[2].value() as int, 0xfffffff, 0x12fffffed);
    arith::mul_eq(f[8].value() as int, g19[2].value() as int, 19 * g[2].value() as int);
    product_below(f2[9].value() as int, g19[1].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[9].value() as int, g19[1].value() as int, 19 * g[1].value() as int);
    arith::mul_eq(g[1].value() as int, f2[9].value() as int, 2 * f[9].value() as int);
    return mul_add(
        mul_add(
            mul_add(
                mul_add(
                    mul_add(
                        mul_add(
                            mul_add(
                                mul_add(mul_add(mul_add(Secret::new(0u64), f[0], g[0]), f2[1], g19[9]), f[2], g19[8]),
                                f2[3],
                                g19[7],
                            ),
                            f[4],
                            g19[6],
                        ),
                        f2[5],
                        g19[5],
                    ),
                    f[6],
                    g19[4],
                ),
                f2[7],
                g19[3],
            ),
            f[8],
            g19[2],
        ),
        f2[9],
        g19[1],
    );
}

// Column 1 of the product of `f` and `g`: `f2` holds twice the limbs of `f`, `g19` 19 times those of `g`.
@constant_time
fn column1(f: [Secret<u64>; 10], g: [Secret<u64>; 10], f2: [Secret<u64>; 10], g19: [Secret<u64>; 10]) Secret<u64>
    requires loose(f) && loose(g) && doubled(f, f2) && times19(g, g19)
    ensures |o| o.value() as int == f[0].value() as int * g[1].value() as int + f[1].value() as int * g[0].value() as int + 19 * (f[2].value() as int * g[9].value() as int) + 19 * (f[3].value() as int * g[8].value() as int) + 19 * (f[4].value() as int * g[7].value() as int) + 19 * (f[5].value() as int * g[6].value() as int) + 19 * (f[6].value() as int * g[5].value() as int) + 19 * (f[7].value() as int * g[4].value() as int) + 19 * (f[8].value() as int * g[3].value() as int) + 19 * (f[9].value() as int * g[2].value() as int)
    ensures |o| o.value() < 0x8000000000000000
{
    product_below(f[0].value() as int, g[1].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[1].value() as int, g[0].value() as int, 0x7ffffff, 0xfffffff);
    product_below(f[2].value() as int, g19[9].value() as int, 0xfffffff, 0x97ffffed);
    arith::mul_eq(f[2].value() as int, g19[9].value() as int, 19 * g[9].value() as int);
    product_below(f[3].value() as int, g19[8].value() as int, 0x7ffffff, 0x12fffffed);
    arith::mul_eq(f[3].value() as int, g19[8].value() as int, 19 * g[8].value() as int);
    product_below(f[4].value() as int, g19[7].value() as int, 0xfffffff, 0x97ffffed);
    arith::mul_eq(f[4].value() as int, g19[7].value() as int, 19 * g[7].value() as int);
    product_below(f[5].value() as int, g19[6].value() as int, 0x7ffffff, 0x12fffffed);
    arith::mul_eq(f[5].value() as int, g19[6].value() as int, 19 * g[6].value() as int);
    product_below(f[6].value() as int, g19[5].value() as int, 0xfffffff, 0x97ffffed);
    arith::mul_eq(f[6].value() as int, g19[5].value() as int, 19 * g[5].value() as int);
    product_below(f[7].value() as int, g19[4].value() as int, 0x7ffffff, 0x12fffffed);
    arith::mul_eq(f[7].value() as int, g19[4].value() as int, 19 * g[4].value() as int);
    product_below(f[8].value() as int, g19[3].value() as int, 0xfffffff, 0x97ffffed);
    arith::mul_eq(f[8].value() as int, g19[3].value() as int, 19 * g[3].value() as int);
    product_below(f[9].value() as int, g19[2].value() as int, 0x7ffffff, 0x12fffffed);
    arith::mul_eq(f[9].value() as int, g19[2].value() as int, 19 * g[2].value() as int);
    return mul_add(
        mul_add(
            mul_add(
                mul_add(
                    mul_add(
                        mul_add(
                            mul_add(
                                mul_add(mul_add(mul_add(Secret::new(0u64), f[0], g[1]), f[1], g[0]), f[2], g19[9]),
                                f[3],
                                g19[8],
                            ),
                            f[4],
                            g19[7],
                        ),
                        f[5],
                        g19[6],
                    ),
                    f[6],
                    g19[5],
                ),
                f[7],
                g19[4],
            ),
            f[8],
            g19[3],
        ),
        f[9],
        g19[2],
    );
}

// Column 2 of the product of `f` and `g`: `f2` holds twice the limbs of `f`, `g19` 19 times those of `g`.
@constant_time
fn column2(f: [Secret<u64>; 10], g: [Secret<u64>; 10], f2: [Secret<u64>; 10], g19: [Secret<u64>; 10]) Secret<u64>
    requires loose(f) && loose(g) && doubled(f, f2) && times19(g, g19)
    ensures |o| o.value() as int == f[0].value() as int * g[2].value() as int + 2 * (f[1].value() as int * g[1].value() as int) + f[2].value() as int * g[0].value() as int + 38 * (f[3].value() as int * g[9].value() as int) + 19 * (f[4].value() as int * g[8].value() as int) + 38 * (f[5].value() as int * g[7].value() as int) + 19 * (f[6].value() as int * g[6].value() as int) + 38 * (f[7].value() as int * g[5].value() as int) + 19 * (f[8].value() as int * g[4].value() as int) + 38 * (f[9].value() as int * g[3].value() as int)
    ensures |o| o.value() < 0x8000000000000000
{
    product_below(f[0].value() as int, g[2].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[1].value() as int, g[1].value() as int, 0xffffffe, 0x7ffffff);
    arith::mul_eq(g[1].value() as int, f2[1].value() as int, 2 * f[1].value() as int);
    product_below(f[2].value() as int, g[0].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[3].value() as int, g19[9].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[3].value() as int, g19[9].value() as int, 19 * g[9].value() as int);
    arith::mul_eq(g[9].value() as int, f2[3].value() as int, 2 * f[3].value() as int);
    product_below(f[4].value() as int, g19[8].value() as int, 0xfffffff, 0x12fffffed);
    arith::mul_eq(f[4].value() as int, g19[8].value() as int, 19 * g[8].value() as int);
    product_below(f2[5].value() as int, g19[7].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[5].value() as int, g19[7].value() as int, 19 * g[7].value() as int);
    arith::mul_eq(g[7].value() as int, f2[5].value() as int, 2 * f[5].value() as int);
    product_below(f[6].value() as int, g19[6].value() as int, 0xfffffff, 0x12fffffed);
    arith::mul_eq(f[6].value() as int, g19[6].value() as int, 19 * g[6].value() as int);
    product_below(f2[7].value() as int, g19[5].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[7].value() as int, g19[5].value() as int, 19 * g[5].value() as int);
    arith::mul_eq(g[5].value() as int, f2[7].value() as int, 2 * f[7].value() as int);
    product_below(f[8].value() as int, g19[4].value() as int, 0xfffffff, 0x12fffffed);
    arith::mul_eq(f[8].value() as int, g19[4].value() as int, 19 * g[4].value() as int);
    product_below(f2[9].value() as int, g19[3].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[9].value() as int, g19[3].value() as int, 19 * g[3].value() as int);
    arith::mul_eq(g[3].value() as int, f2[9].value() as int, 2 * f[9].value() as int);
    return mul_add(
        mul_add(
            mul_add(
                mul_add(
                    mul_add(
                        mul_add(
                            mul_add(
                                mul_add(mul_add(mul_add(Secret::new(0u64), f[0], g[2]), f2[1], g[1]), f[2], g[0]),
                                f2[3],
                                g19[9],
                            ),
                            f[4],
                            g19[8],
                        ),
                        f2[5],
                        g19[7],
                    ),
                    f[6],
                    g19[6],
                ),
                f2[7],
                g19[5],
            ),
            f[8],
            g19[4],
        ),
        f2[9],
        g19[3],
    );
}

// Column 3 of the product of `f` and `g`: `f2` holds twice the limbs of `f`, `g19` 19 times those of `g`.
@constant_time
fn column3(f: [Secret<u64>; 10], g: [Secret<u64>; 10], f2: [Secret<u64>; 10], g19: [Secret<u64>; 10]) Secret<u64>
    requires loose(f) && loose(g) && doubled(f, f2) && times19(g, g19)
    ensures |o| o.value() as int == f[0].value() as int * g[3].value() as int + f[1].value() as int * g[2].value() as int + f[2].value() as int * g[1].value() as int + f[3].value() as int * g[0].value() as int + 19 * (f[4].value() as int * g[9].value() as int) + 19 * (f[5].value() as int * g[8].value() as int) + 19 * (f[6].value() as int * g[7].value() as int) + 19 * (f[7].value() as int * g[6].value() as int) + 19 * (f[8].value() as int * g[5].value() as int) + 19 * (f[9].value() as int * g[4].value() as int)
    ensures |o| o.value() < 0x8000000000000000
{
    product_below(f[0].value() as int, g[3].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[1].value() as int, g[2].value() as int, 0x7ffffff, 0xfffffff);
    product_below(f[2].value() as int, g[1].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[3].value() as int, g[0].value() as int, 0x7ffffff, 0xfffffff);
    product_below(f[4].value() as int, g19[9].value() as int, 0xfffffff, 0x97ffffed);
    arith::mul_eq(f[4].value() as int, g19[9].value() as int, 19 * g[9].value() as int);
    product_below(f[5].value() as int, g19[8].value() as int, 0x7ffffff, 0x12fffffed);
    arith::mul_eq(f[5].value() as int, g19[8].value() as int, 19 * g[8].value() as int);
    product_below(f[6].value() as int, g19[7].value() as int, 0xfffffff, 0x97ffffed);
    arith::mul_eq(f[6].value() as int, g19[7].value() as int, 19 * g[7].value() as int);
    product_below(f[7].value() as int, g19[6].value() as int, 0x7ffffff, 0x12fffffed);
    arith::mul_eq(f[7].value() as int, g19[6].value() as int, 19 * g[6].value() as int);
    product_below(f[8].value() as int, g19[5].value() as int, 0xfffffff, 0x97ffffed);
    arith::mul_eq(f[8].value() as int, g19[5].value() as int, 19 * g[5].value() as int);
    product_below(f[9].value() as int, g19[4].value() as int, 0x7ffffff, 0x12fffffed);
    arith::mul_eq(f[9].value() as int, g19[4].value() as int, 19 * g[4].value() as int);
    return mul_add(
        mul_add(
            mul_add(
                mul_add(
                    mul_add(
                        mul_add(
                            mul_add(
                                mul_add(mul_add(mul_add(Secret::new(0u64), f[0], g[3]), f[1], g[2]), f[2], g[1]),
                                f[3],
                                g[0],
                            ),
                            f[4],
                            g19[9],
                        ),
                        f[5],
                        g19[8],
                    ),
                    f[6],
                    g19[7],
                ),
                f[7],
                g19[6],
            ),
            f[8],
            g19[5],
        ),
        f[9],
        g19[4],
    );
}

// Column 4 of the product of `f` and `g`: `f2` holds twice the limbs of `f`, `g19` 19 times those of `g`.
@constant_time
fn column4(f: [Secret<u64>; 10], g: [Secret<u64>; 10], f2: [Secret<u64>; 10], g19: [Secret<u64>; 10]) Secret<u64>
    requires loose(f) && loose(g) && doubled(f, f2) && times19(g, g19)
    ensures |o| o.value() as int == f[0].value() as int * g[4].value() as int + 2 * (f[1].value() as int * g[3].value() as int) + f[2].value() as int * g[2].value() as int + 2 * (f[3].value() as int * g[1].value() as int) + f[4].value() as int * g[0].value() as int + 38 * (f[5].value() as int * g[9].value() as int) + 19 * (f[6].value() as int * g[8].value() as int) + 38 * (f[7].value() as int * g[7].value() as int) + 19 * (f[8].value() as int * g[6].value() as int) + 38 * (f[9].value() as int * g[5].value() as int)
    ensures |o| o.value() < 0x8000000000000000
{
    product_below(f[0].value() as int, g[4].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[1].value() as int, g[3].value() as int, 0xffffffe, 0x7ffffff);
    arith::mul_eq(g[3].value() as int, f2[1].value() as int, 2 * f[1].value() as int);
    product_below(f[2].value() as int, g[2].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[3].value() as int, g[1].value() as int, 0xffffffe, 0x7ffffff);
    arith::mul_eq(g[1].value() as int, f2[3].value() as int, 2 * f[3].value() as int);
    product_below(f[4].value() as int, g[0].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[5].value() as int, g19[9].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[5].value() as int, g19[9].value() as int, 19 * g[9].value() as int);
    arith::mul_eq(g[9].value() as int, f2[5].value() as int, 2 * f[5].value() as int);
    product_below(f[6].value() as int, g19[8].value() as int, 0xfffffff, 0x12fffffed);
    arith::mul_eq(f[6].value() as int, g19[8].value() as int, 19 * g[8].value() as int);
    product_below(f2[7].value() as int, g19[7].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[7].value() as int, g19[7].value() as int, 19 * g[7].value() as int);
    arith::mul_eq(g[7].value() as int, f2[7].value() as int, 2 * f[7].value() as int);
    product_below(f[8].value() as int, g19[6].value() as int, 0xfffffff, 0x12fffffed);
    arith::mul_eq(f[8].value() as int, g19[6].value() as int, 19 * g[6].value() as int);
    product_below(f2[9].value() as int, g19[5].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[9].value() as int, g19[5].value() as int, 19 * g[5].value() as int);
    arith::mul_eq(g[5].value() as int, f2[9].value() as int, 2 * f[9].value() as int);
    return mul_add(
        mul_add(
            mul_add(
                mul_add(
                    mul_add(
                        mul_add(
                            mul_add(
                                mul_add(mul_add(mul_add(Secret::new(0u64), f[0], g[4]), f2[1], g[3]), f[2], g[2]),
                                f2[3],
                                g[1],
                            ),
                            f[4],
                            g[0],
                        ),
                        f2[5],
                        g19[9],
                    ),
                    f[6],
                    g19[8],
                ),
                f2[7],
                g19[7],
            ),
            f[8],
            g19[6],
        ),
        f2[9],
        g19[5],
    );
}

// Column 5 of the product of `f` and `g`: `f2` holds twice the limbs of `f`, `g19` 19 times those of `g`.
@constant_time
fn column5(f: [Secret<u64>; 10], g: [Secret<u64>; 10], f2: [Secret<u64>; 10], g19: [Secret<u64>; 10]) Secret<u64>
    requires loose(f) && loose(g) && doubled(f, f2) && times19(g, g19)
    ensures |o| o.value() as int == f[0].value() as int * g[5].value() as int + f[1].value() as int * g[4].value() as int + f[2].value() as int * g[3].value() as int + f[3].value() as int * g[2].value() as int + f[4].value() as int * g[1].value() as int + f[5].value() as int * g[0].value() as int + 19 * (f[6].value() as int * g[9].value() as int) + 19 * (f[7].value() as int * g[8].value() as int) + 19 * (f[8].value() as int * g[7].value() as int) + 19 * (f[9].value() as int * g[6].value() as int)
    ensures |o| o.value() < 0x8000000000000000
{
    product_below(f[0].value() as int, g[5].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[1].value() as int, g[4].value() as int, 0x7ffffff, 0xfffffff);
    product_below(f[2].value() as int, g[3].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[3].value() as int, g[2].value() as int, 0x7ffffff, 0xfffffff);
    product_below(f[4].value() as int, g[1].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[5].value() as int, g[0].value() as int, 0x7ffffff, 0xfffffff);
    product_below(f[6].value() as int, g19[9].value() as int, 0xfffffff, 0x97ffffed);
    arith::mul_eq(f[6].value() as int, g19[9].value() as int, 19 * g[9].value() as int);
    product_below(f[7].value() as int, g19[8].value() as int, 0x7ffffff, 0x12fffffed);
    arith::mul_eq(f[7].value() as int, g19[8].value() as int, 19 * g[8].value() as int);
    product_below(f[8].value() as int, g19[7].value() as int, 0xfffffff, 0x97ffffed);
    arith::mul_eq(f[8].value() as int, g19[7].value() as int, 19 * g[7].value() as int);
    product_below(f[9].value() as int, g19[6].value() as int, 0x7ffffff, 0x12fffffed);
    arith::mul_eq(f[9].value() as int, g19[6].value() as int, 19 * g[6].value() as int);
    return mul_add(
        mul_add(
            mul_add(
                mul_add(
                    mul_add(
                        mul_add(
                            mul_add(
                                mul_add(mul_add(mul_add(Secret::new(0u64), f[0], g[5]), f[1], g[4]), f[2], g[3]),
                                f[3],
                                g[2],
                            ),
                            f[4],
                            g[1],
                        ),
                        f[5],
                        g[0],
                    ),
                    f[6],
                    g19[9],
                ),
                f[7],
                g19[8],
            ),
            f[8],
            g19[7],
        ),
        f[9],
        g19[6],
    );
}

// Column 6 of the product of `f` and `g`: `f2` holds twice the limbs of `f`, `g19` 19 times those of `g`.
@constant_time
fn column6(f: [Secret<u64>; 10], g: [Secret<u64>; 10], f2: [Secret<u64>; 10], g19: [Secret<u64>; 10]) Secret<u64>
    requires loose(f) && loose(g) && doubled(f, f2) && times19(g, g19)
    ensures |o| o.value() as int == f[0].value() as int * g[6].value() as int + 2 * (f[1].value() as int * g[5].value() as int) + f[2].value() as int * g[4].value() as int + 2 * (f[3].value() as int * g[3].value() as int) + f[4].value() as int * g[2].value() as int + 2 * (f[5].value() as int * g[1].value() as int) + f[6].value() as int * g[0].value() as int + 38 * (f[7].value() as int * g[9].value() as int) + 19 * (f[8].value() as int * g[8].value() as int) + 38 * (f[9].value() as int * g[7].value() as int)
    ensures |o| o.value() < 0x8000000000000000
{
    product_below(f[0].value() as int, g[6].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[1].value() as int, g[5].value() as int, 0xffffffe, 0x7ffffff);
    arith::mul_eq(g[5].value() as int, f2[1].value() as int, 2 * f[1].value() as int);
    product_below(f[2].value() as int, g[4].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[3].value() as int, g[3].value() as int, 0xffffffe, 0x7ffffff);
    arith::mul_eq(g[3].value() as int, f2[3].value() as int, 2 * f[3].value() as int);
    product_below(f[4].value() as int, g[2].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[5].value() as int, g[1].value() as int, 0xffffffe, 0x7ffffff);
    arith::mul_eq(g[1].value() as int, f2[5].value() as int, 2 * f[5].value() as int);
    product_below(f[6].value() as int, g[0].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[7].value() as int, g19[9].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[7].value() as int, g19[9].value() as int, 19 * g[9].value() as int);
    arith::mul_eq(g[9].value() as int, f2[7].value() as int, 2 * f[7].value() as int);
    product_below(f[8].value() as int, g19[8].value() as int, 0xfffffff, 0x12fffffed);
    arith::mul_eq(f[8].value() as int, g19[8].value() as int, 19 * g[8].value() as int);
    product_below(f2[9].value() as int, g19[7].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[9].value() as int, g19[7].value() as int, 19 * g[7].value() as int);
    arith::mul_eq(g[7].value() as int, f2[9].value() as int, 2 * f[9].value() as int);
    return mul_add(
        mul_add(
            mul_add(
                mul_add(
                    mul_add(
                        mul_add(
                            mul_add(
                                mul_add(mul_add(mul_add(Secret::new(0u64), f[0], g[6]), f2[1], g[5]), f[2], g[4]),
                                f2[3],
                                g[3],
                            ),
                            f[4],
                            g[2],
                        ),
                        f2[5],
                        g[1],
                    ),
                    f[6],
                    g[0],
                ),
                f2[7],
                g19[9],
            ),
            f[8],
            g19[8],
        ),
        f2[9],
        g19[7],
    );
}

// Column 7 of the product of `f` and `g`: `f2` holds twice the limbs of `f`, `g19` 19 times those of `g`.
@constant_time
fn column7(f: [Secret<u64>; 10], g: [Secret<u64>; 10], f2: [Secret<u64>; 10], g19: [Secret<u64>; 10]) Secret<u64>
    requires loose(f) && loose(g) && doubled(f, f2) && times19(g, g19)
    ensures |o| o.value() as int == f[0].value() as int * g[7].value() as int + f[1].value() as int * g[6].value() as int + f[2].value() as int * g[5].value() as int + f[3].value() as int * g[4].value() as int + f[4].value() as int * g[3].value() as int + f[5].value() as int * g[2].value() as int + f[6].value() as int * g[1].value() as int + f[7].value() as int * g[0].value() as int + 19 * (f[8].value() as int * g[9].value() as int) + 19 * (f[9].value() as int * g[8].value() as int)
    ensures |o| o.value() < 0x8000000000000000
{
    product_below(f[0].value() as int, g[7].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[1].value() as int, g[6].value() as int, 0x7ffffff, 0xfffffff);
    product_below(f[2].value() as int, g[5].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[3].value() as int, g[4].value() as int, 0x7ffffff, 0xfffffff);
    product_below(f[4].value() as int, g[3].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[5].value() as int, g[2].value() as int, 0x7ffffff, 0xfffffff);
    product_below(f[6].value() as int, g[1].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[7].value() as int, g[0].value() as int, 0x7ffffff, 0xfffffff);
    product_below(f[8].value() as int, g19[9].value() as int, 0xfffffff, 0x97ffffed);
    arith::mul_eq(f[8].value() as int, g19[9].value() as int, 19 * g[9].value() as int);
    product_below(f[9].value() as int, g19[8].value() as int, 0x7ffffff, 0x12fffffed);
    arith::mul_eq(f[9].value() as int, g19[8].value() as int, 19 * g[8].value() as int);
    return mul_add(
        mul_add(
            mul_add(
                mul_add(
                    mul_add(
                        mul_add(
                            mul_add(
                                mul_add(mul_add(mul_add(Secret::new(0u64), f[0], g[7]), f[1], g[6]), f[2], g[5]),
                                f[3],
                                g[4],
                            ),
                            f[4],
                            g[3],
                        ),
                        f[5],
                        g[2],
                    ),
                    f[6],
                    g[1],
                ),
                f[7],
                g[0],
            ),
            f[8],
            g19[9],
        ),
        f[9],
        g19[8],
    );
}

// Column 8 of the product of `f` and `g`: `f2` holds twice the limbs of `f`, `g19` 19 times those of `g`.
@constant_time
fn column8(f: [Secret<u64>; 10], g: [Secret<u64>; 10], f2: [Secret<u64>; 10], g19: [Secret<u64>; 10]) Secret<u64>
    requires loose(f) && loose(g) && doubled(f, f2) && times19(g, g19)
    ensures |o| o.value() as int == f[0].value() as int * g[8].value() as int + 2 * (f[1].value() as int * g[7].value() as int) + f[2].value() as int * g[6].value() as int + 2 * (f[3].value() as int * g[5].value() as int) + f[4].value() as int * g[4].value() as int + 2 * (f[5].value() as int * g[3].value() as int) + f[6].value() as int * g[2].value() as int + 2 * (f[7].value() as int * g[1].value() as int) + f[8].value() as int * g[0].value() as int + 38 * (f[9].value() as int * g[9].value() as int)
    ensures |o| o.value() < 0x8000000000000000
{
    product_below(f[0].value() as int, g[8].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[1].value() as int, g[7].value() as int, 0xffffffe, 0x7ffffff);
    arith::mul_eq(g[7].value() as int, f2[1].value() as int, 2 * f[1].value() as int);
    product_below(f[2].value() as int, g[6].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[3].value() as int, g[5].value() as int, 0xffffffe, 0x7ffffff);
    arith::mul_eq(g[5].value() as int, f2[3].value() as int, 2 * f[3].value() as int);
    product_below(f[4].value() as int, g[4].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[5].value() as int, g[3].value() as int, 0xffffffe, 0x7ffffff);
    arith::mul_eq(g[3].value() as int, f2[5].value() as int, 2 * f[5].value() as int);
    product_below(f[6].value() as int, g[2].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[7].value() as int, g[1].value() as int, 0xffffffe, 0x7ffffff);
    arith::mul_eq(g[1].value() as int, f2[7].value() as int, 2 * f[7].value() as int);
    product_below(f[8].value() as int, g[0].value() as int, 0xfffffff, 0xfffffff);
    product_below(f2[9].value() as int, g19[9].value() as int, 0xffffffe, 0x97ffffed);
    arith::mul_eq(f2[9].value() as int, g19[9].value() as int, 19 * g[9].value() as int);
    arith::mul_eq(g[9].value() as int, f2[9].value() as int, 2 * f[9].value() as int);
    return mul_add(
        mul_add(
            mul_add(
                mul_add(
                    mul_add(
                        mul_add(
                            mul_add(
                                mul_add(mul_add(mul_add(Secret::new(0u64), f[0], g[8]), f2[1], g[7]), f[2], g[6]),
                                f2[3],
                                g[5],
                            ),
                            f[4],
                            g[4],
                        ),
                        f2[5],
                        g[3],
                    ),
                    f[6],
                    g[2],
                ),
                f2[7],
                g[1],
            ),
            f[8],
            g[0],
        ),
        f2[9],
        g19[9],
    );
}

// Column 9 of the product of `f` and `g`: `f2` holds twice the limbs of `f`, `g19` 19 times those of `g`.
@constant_time
fn column9(f: [Secret<u64>; 10], g: [Secret<u64>; 10], f2: [Secret<u64>; 10], g19: [Secret<u64>; 10]) Secret<u64>
    requires loose(f) && loose(g) && doubled(f, f2) && times19(g, g19)
    ensures |o| o.value() as int == f[0].value() as int * g[9].value() as int + f[1].value() as int * g[8].value() as int + f[2].value() as int * g[7].value() as int + f[3].value() as int * g[6].value() as int + f[4].value() as int * g[5].value() as int + f[5].value() as int * g[4].value() as int + f[6].value() as int * g[3].value() as int + f[7].value() as int * g[2].value() as int + f[8].value() as int * g[1].value() as int + f[9].value() as int * g[0].value() as int
    ensures |o| o.value() < 0x8000000000000000
{
    product_below(f[0].value() as int, g[9].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[1].value() as int, g[8].value() as int, 0x7ffffff, 0xfffffff);
    product_below(f[2].value() as int, g[7].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[3].value() as int, g[6].value() as int, 0x7ffffff, 0xfffffff);
    product_below(f[4].value() as int, g[5].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[5].value() as int, g[4].value() as int, 0x7ffffff, 0xfffffff);
    product_below(f[6].value() as int, g[3].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[7].value() as int, g[2].value() as int, 0x7ffffff, 0xfffffff);
    product_below(f[8].value() as int, g[1].value() as int, 0xfffffff, 0x7ffffff);
    product_below(f[9].value() as int, g[0].value() as int, 0x7ffffff, 0xfffffff);
    return mul_add(
        mul_add(
            mul_add(
                mul_add(
                    mul_add(
                        mul_add(
                            mul_add(
                                mul_add(mul_add(mul_add(Secret::new(0u64), f[0], g[9]), f[1], g[8]), f[2], g[7]),
                                f[3],
                                g[6],
                            ),
                            f[4],
                            g[5],
                        ),
                        f[5],
                        g[4],
                    ),
                    f[6],
                    g[3],
                ),
                f[7],
                g[2],
            ),
            f[8],
            g[1],
        ),
        f[9],
        g[0],
    );
}

// `x` split at bit 26.
lemma split26(x: u64)
    ensures x as int == (x & 0x3ffffff) as int + 0x4000000 * (x >> 26) as int
    ensures (x & 0x3ffffff) < 0x4000000
{
    assert x / 0x4000000 == x >> 26 by {};
    assert x % 0x4000000 == (x & 0x3ffffff) by {};
    assert x as int == (x % 0x4000000) as int + 0x4000000 * (x / 0x4000000) as int by {};
}

// The low 26 bits of `x` and the carry past them.
@constant_time
const fn carry26(x: Secret<u64>) [Secret<u64>; 2]
    ensures |o| x.value() as int == o[0].value() as int + 0x4000000 * o[1].value() as int
    ensures |o| o[0].value() < 0x4000000 && o[1].value() as int * 0x4000000 <= x.value() as int && o[1].value() < 0x4000000000
{
    split26(x.value());
    return [x & Secret::new(0x3ffffffu64), x >> 26];
}

// `x` split at bit 25.
lemma split25(x: u64)
    ensures x as int == (x & 0x1ffffff) as int + 0x2000000 * (x >> 25) as int
    ensures (x & 0x1ffffff) < 0x2000000
{
    assert x / 0x2000000 == x >> 25 by {};
    assert x % 0x2000000 == (x & 0x1ffffff) by {};
    assert x as int == (x % 0x2000000) as int + 0x2000000 * (x / 0x2000000) as int by {};
}

// The low 25 bits of `x` and the carry past them.
@constant_time
const fn carry25(x: Secret<u64>) [Secret<u64>; 2]
    ensures |o| x.value() as int == o[0].value() as int + 0x2000000 * o[1].value() as int
    ensures |o| o[0].value() < 0x2000000 && o[1].value() as int * 0x2000000 <= x.value() as int && o[1].value() < 0x8000000000
{
    split25(x.value());
    return [x & Secret::new(0x1ffffffu64), x >> 25];
}

// Limbs of the value of column sums `d` modulo p, as `carried` holds them.
@constant_time
fn carry(d: [Secret<u64>; 10]) [Secret<u64>; 10]
    requires d[0].value() < 0x8000000000000000 && d[1].value() < 0x8000000000000000 && d[2].value() < 0x8000000000000000 && d[3].value() < 0x8000000000000000 && d[4].value() < 0x8000000000000000 && d[5].value() < 0x8000000000000000 && d[6].value() < 0x8000000000000000 && d[7].value() < 0x8000000000000000 && d[8].value() < 0x8000000000000000 && d[9].value() < 0x8000000000000000
    ensures |h| val(h) % p() == dval(d) % p()
    ensures |h| carried(h)
{
    let a0 = carry26(d[0]);
    let a1 = carry25(add(d[1], a0[1]));
    let a2 = carry26(add(d[2], a1[1]));
    let a3 = carry25(add(d[3], a2[1]));
    let a4 = carry26(add(d[4], a3[1]));
    let a5 = carry25(add(d[5], a4[1]));
    let a6 = carry26(add(d[6], a5[1]));
    let a7 = carry25(add(d[7], a6[1]));
    let a8 = carry26(add(d[8], a7[1]));
    let a9 = carry25(add(d[9], a8[1]));
    let b0 = carry26(add(a0[0], times(a9[1], 19)));
    let h = [b0[0], add(a1[0], b0[1]), a2[0], a3[0], a4[0], a5[0], a6[0], a7[0], a8[0], a9[0]];
    assert val(h) + p() * a9[1].value() as int == dval(d) by {};
    arith::mod_add_multiple(val(h), a9[1].value() as int, p());
    return h;
}

// Twice limbs `f`.
@constant_time
const fn double(f: [Secret<u64>; 10]) [Secret<u64>; 10]
    requires loose(f)
    ensures |o| doubled(f, o)
{
    return [
        times(f[0], 2),
        times(f[1], 2),
        times(f[2], 2),
        times(f[3], 2),
        times(f[4], 2),
        times(f[5], 2),
        times(f[6], 2),
        times(f[7], 2),
        times(f[8], 2),
        times(f[9], 2),
    ];
}

// 19 times limbs `g`.
@constant_time
const fn times19_of(g: [Secret<u64>; 10]) [Secret<u64>; 10]
    requires loose(g)
    ensures |o| times19(g, o)
{
    return [
        times(g[0], 19),
        times(g[1], 19),
        times(g[2], 19),
        times(g[3], 19),
        times(g[4], 19),
        times(g[5], 19),
        times(g[6], 19),
        times(g[7], 19),
        times(g[8], 19),
        times(g[9], 19),
    ];
}

// `f * g` modulo p, as limbs of `carry`.
@constant_time
pub(package) fn mul(f: [Secret<u64>; 10], g: [Secret<u64>; 10]) [Secret<u64>; 10]
    requires loose(f) && loose(g)
    ensures |o| val(o) % p() == val(f) * val(g) % p()
    ensures |o| carried(o)
{
    let f2 = double(f);
    let g19 = times19_of(g);
    let d = [
        column0(f, g, f2, g19),
        column1(f, g, f2, g19),
        column2(f, g, f2, g19),
        column3(f, g, f2, g19),
        column4(f, g, f2, g19),
        column5(f, g, f2, g19),
        column6(f, g, f2, g19),
        column7(f, g, f2, g19),
        column8(f, g, f2, g19),
        column9(f, g, f2, g19),
    ];
    ghost let gv = val(g);
    row(
        f[0].value() as int,
        gv,
        g[0].value() as int,
        g[1].value() as int,
        g[2].value() as int,
        g[3].value() as int,
        g[4].value() as int,
        g[5].value() as int,
        g[6].value() as int,
        g[7].value() as int,
        g[8].value() as int,
        g[9].value() as int,
    );
    row(
        f[1].value() as int,
        gv,
        g[0].value() as int,
        g[1].value() as int,
        g[2].value() as int,
        g[3].value() as int,
        g[4].value() as int,
        g[5].value() as int,
        g[6].value() as int,
        g[7].value() as int,
        g[8].value() as int,
        g[9].value() as int,
    );
    row(
        f[2].value() as int,
        gv,
        g[0].value() as int,
        g[1].value() as int,
        g[2].value() as int,
        g[3].value() as int,
        g[4].value() as int,
        g[5].value() as int,
        g[6].value() as int,
        g[7].value() as int,
        g[8].value() as int,
        g[9].value() as int,
    );
    row(
        f[3].value() as int,
        gv,
        g[0].value() as int,
        g[1].value() as int,
        g[2].value() as int,
        g[3].value() as int,
        g[4].value() as int,
        g[5].value() as int,
        g[6].value() as int,
        g[7].value() as int,
        g[8].value() as int,
        g[9].value() as int,
    );
    row(
        f[4].value() as int,
        gv,
        g[0].value() as int,
        g[1].value() as int,
        g[2].value() as int,
        g[3].value() as int,
        g[4].value() as int,
        g[5].value() as int,
        g[6].value() as int,
        g[7].value() as int,
        g[8].value() as int,
        g[9].value() as int,
    );
    row(
        f[5].value() as int,
        gv,
        g[0].value() as int,
        g[1].value() as int,
        g[2].value() as int,
        g[3].value() as int,
        g[4].value() as int,
        g[5].value() as int,
        g[6].value() as int,
        g[7].value() as int,
        g[8].value() as int,
        g[9].value() as int,
    );
    row(
        f[6].value() as int,
        gv,
        g[0].value() as int,
        g[1].value() as int,
        g[2].value() as int,
        g[3].value() as int,
        g[4].value() as int,
        g[5].value() as int,
        g[6].value() as int,
        g[7].value() as int,
        g[8].value() as int,
        g[9].value() as int,
    );
    row(
        f[7].value() as int,
        gv,
        g[0].value() as int,
        g[1].value() as int,
        g[2].value() as int,
        g[3].value() as int,
        g[4].value() as int,
        g[5].value() as int,
        g[6].value() as int,
        g[7].value() as int,
        g[8].value() as int,
        g[9].value() as int,
    );
    row(
        f[8].value() as int,
        gv,
        g[0].value() as int,
        g[1].value() as int,
        g[2].value() as int,
        g[3].value() as int,
        g[4].value() as int,
        g[5].value() as int,
        g[6].value() as int,
        g[7].value() as int,
        g[8].value() as int,
        g[9].value() as int,
    );
    row(
        f[9].value() as int,
        gv,
        g[0].value() as int,
        g[1].value() as int,
        g[2].value() as int,
        g[3].value() as int,
        g[4].value() as int,
        g[5].value() as int,
        g[6].value() as int,
        g[7].value() as int,
        g[8].value() as int,
        g[9].value() as int,
    );
    ghost let fv = val(f);
    column(
        fv,
        gv,
        f[0].value() as int,
        f[1].value() as int,
        f[2].value() as int,
        f[3].value() as int,
        f[4].value() as int,
        f[5].value() as int,
        f[6].value() as int,
        f[7].value() as int,
        f[8].value() as int,
        f[9].value() as int,
    );
    ghost let q = 2 * (f[1].value() as int * g[9].value() as int) + f[2].value() as int * g[8].value() as int + f[2].value() as int * g[9].value() as int * 0x4000000 + 2 * (f[3].value() as int * g[7].value() as int) + f[3].value() as int * g[8].value() as int * 0x4000000 + 2 * (f[3].value() as int * g[9].value() as int) * 0x8000000000000 + f[4].value() as int * g[6].value() as int + f[4].value() as int * g[7].value() as int * 0x4000000 + f[4].value() as int * g[8].value() as int * 0x8000000000000 + f[4].value() as int * g[9].value() as int * 0x20000000000000000000 + 2 * (f[5].value() as int * g[5].value() as int) + f[5].value() as int * g[6].value() as int * 0x4000000 + 2 * (f[5].value() as int * g[7].value() as int) * 0x8000000000000 + f[5].value() as int * g[8].value() as int * 0x20000000000000000000 + 2 * (f[5].value() as int * g[9].value() as int) * 0x40000000000000000000000000 + f[6].value() as int * g[4].value() as int + f[6].value() as int * g[5].value() as int * 0x4000000 + f[6].value() as int * g[6].value() as int * 0x8000000000000 + f[6].value() as int * g[7].value() as int * 0x20000000000000000000 + f[6].value() as int * g[8].value() as int * 0x40000000000000000000000000 + f[6].value() as int * g[9].value() as int * 0x100000000000000000000000000000000 + 2 * (f[7].value() as int * g[3].value() as int) + f[7].value() as int * g[4].value() as int * 0x4000000 + 2 * (f[7].value() as int * g[5].value() as int) * 0x8000000000000 + f[7].value() as int * g[6].value() as int * 0x20000000000000000000 + 2 * (f[7].value() as int * g[7].value() as int) * 0x40000000000000000000000000 + f[7].value() as int * g[8].value() as int * 0x100000000000000000000000000000000 + 2 * (f[7].value() as int * g[9].value() as int) * 0x200000000000000000000000000000000000000 + f[8].value() as int * g[2].value() as int + f[8].value() as int * g[3].value() as int * 0x4000000 + f[8].value() as int * g[4].value() as int * 0x8000000000000 + f[8].value() as int * g[5].value() as int * 0x20000000000000000000 + f[8].value() as int * g[6].value() as int * 0x40000000000000000000000000 + f[8].value() as int * g[7].value() as int * 0x100000000000000000000000000000000 + f[8].value() as int * g[8].value() as int * 0x200000000000000000000000000000000000000 + f[8].value() as int * g[9].value() as int * 0x800000000000000000000000000000000000000000000 + 2 * (f[9].value() as int * g[1].value() as int) + f[9].value() as int * g[2].value() as int * 0x4000000 + 2 * (f[9].value() as int * g[3].value() as int) * 0x8000000000000 + f[9].value() as int * g[4].value() as int * 0x20000000000000000000 + 2 * (f[9].value() as int * g[5].value() as int) * 0x40000000000000000000000000 + f[9].value() as int * g[6].value() as int * 0x100000000000000000000000000000000 + 2 * (f[9].value() as int * g[7].value() as int) * 0x200000000000000000000000000000000000000 + f[9].value() as int * g[8].value() as int * 0x800000000000000000000000000000000000000000000 + 2 * (f[9].value() as int * g[9].value() as int) * 0x1000000000000000000000000000000000000000000000000000;
    assert fv * gv == f[0].value() as int * g[0].value() as int + f[0].value() as int * g[1].value() as int * 0x4000000 + f[0].value() as int * g[2].value() as int * 0x8000000000000 + f[0].value() as int * g[3].value() as int * 0x20000000000000000000 + f[0].value() as int * g[4].value() as int * 0x40000000000000000000000000 + f[0].value() as int * g[5].value() as int * 0x100000000000000000000000000000000 + f[0].value() as int * g[6].value() as int * 0x200000000000000000000000000000000000000 + f[0].value() as int * g[7].value() as int * 0x800000000000000000000000000000000000000000000 + f[0].value() as int * g[8].value() as int * 0x1000000000000000000000000000000000000000000000000000 + f[0].value() as int * g[9].value() as int * 0x4000000000000000000000000000000000000000000000000000000000 + f[1].value() as int * g[0].value() as int * 0x4000000 + f[1].value() as int * g[1].value() as int * 0x10000000000000 + f[1].value() as int * g[2].value() as int * 0x20000000000000000000 + f[1].value() as int * g[3].value() as int * 0x80000000000000000000000000 + f[1].value() as int * g[4].value() as int * 0x100000000000000000000000000000000 + f[1].value() as int * g[5].value() as int * 0x400000000000000000000000000000000000000 + f[1].value() as int * g[6].value() as int * 0x800000000000000000000000000000000000000000000 + f[1].value() as int * g[7].value() as int * 0x2000000000000000000000000000000000000000000000000000 + f[1].value() as int * g[8].value() as int * 0x4000000000000000000000000000000000000000000000000000000000 + f[1].value() as int * g[9].value() as int * 0x10000000000000000000000000000000000000000000000000000000000000000 + f[2].value() as int * g[0].value() as int * 0x8000000000000 + f[2].value() as int * g[1].value() as int * 0x20000000000000000000 + f[2].value() as int * g[2].value() as int * 0x40000000000000000000000000 + f[2].value() as int * g[3].value() as int * 0x100000000000000000000000000000000 + f[2].value() as int * g[4].value() as int * 0x200000000000000000000000000000000000000 + f[2].value() as int * g[5].value() as int * 0x800000000000000000000000000000000000000000000 + f[2].value() as int * g[6].value() as int * 0x1000000000000000000000000000000000000000000000000000 + f[2].value() as int * g[7].value() as int * 0x4000000000000000000000000000000000000000000000000000000000 + f[2].value() as int * g[8].value() as int * 0x8000000000000000000000000000000000000000000000000000000000000000 + f[2].value() as int * g[9].value() as int * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + f[3].value() as int * g[0].value() as int * 0x20000000000000000000 + f[3].value() as int * g[1].value() as int * 0x80000000000000000000000000 + f[3].value() as int * g[2].value() as int * 0x100000000000000000000000000000000 + f[3].value() as int * g[3].value() as int * 0x400000000000000000000000000000000000000 + f[3].value() as int * g[4].value() as int * 0x800000000000000000000000000000000000000000000 + f[3].value() as int * g[5].value() as int * 0x2000000000000000000000000000000000000000000000000000 + f[3].value() as int * g[6].value() as int * 0x4000000000000000000000000000000000000000000000000000000000 + f[3].value() as int * g[7].value() as int * 0x10000000000000000000000000000000000000000000000000000000000000000 + f[3].value() as int * g[8].value() as int * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + f[3].value() as int * g[9].value() as int * 0x80000000000000000000000000000000000000000000000000000000000000000000000000000 + f[4].value() as int * g[0].value() as int * 0x40000000000000000000000000 + f[4].value() as int * g[1].value() as int * 0x100000000000000000000000000000000 + f[4].value() as int * g[2].value() as int * 0x200000000000000000000000000000000000000 + f[4].value() as int * g[3].value() as int * 0x800000000000000000000000000000000000000000000 + f[4].value() as int * g[4].value() as int * 0x1000000000000000000000000000000000000000000000000000 + f[4].value() as int * g[5].value() as int * 0x4000000000000000000000000000000000000000000000000000000000 + f[4].value() as int * g[6].value() as int * 0x8000000000000000000000000000000000000000000000000000000000000000 + f[4].value() as int * g[7].value() as int * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + f[4].value() as int * g[8].value() as int * 0x40000000000000000000000000000000000000000000000000000000000000000000000000000 + f[4].value() as int * g[9].value() as int * 0x100000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[5].value() as int * g[0].value() as int * 0x100000000000000000000000000000000 + f[5].value() as int * g[1].value() as int * 0x400000000000000000000000000000000000000 + f[5].value() as int * g[2].value() as int * 0x800000000000000000000000000000000000000000000 + f[5].value() as int * g[3].value() as int * 0x2000000000000000000000000000000000000000000000000000 + f[5].value() as int * g[4].value() as int * 0x4000000000000000000000000000000000000000000000000000000000 + f[5].value() as int * g[5].value() as int * 0x10000000000000000000000000000000000000000000000000000000000000000 + f[5].value() as int * g[6].value() as int * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + f[5].value() as int * g[7].value() as int * 0x80000000000000000000000000000000000000000000000000000000000000000000000000000 + f[5].value() as int * g[8].value() as int * 0x100000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[5].value() as int * g[9].value() as int * 0x400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[6].value() as int * g[0].value() as int * 0x200000000000000000000000000000000000000 + f[6].value() as int * g[1].value() as int * 0x800000000000000000000000000000000000000000000 + f[6].value() as int * g[2].value() as int * 0x1000000000000000000000000000000000000000000000000000 + f[6].value() as int * g[3].value() as int * 0x4000000000000000000000000000000000000000000000000000000000 + f[6].value() as int * g[4].value() as int * 0x8000000000000000000000000000000000000000000000000000000000000000 + f[6].value() as int * g[5].value() as int * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + f[6].value() as int * g[6].value() as int * 0x40000000000000000000000000000000000000000000000000000000000000000000000000000 + f[6].value() as int * g[7].value() as int * 0x100000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[6].value() as int * g[8].value() as int * 0x200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[6].value() as int * g[9].value() as int * 0x800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[7].value() as int * g[0].value() as int * 0x800000000000000000000000000000000000000000000 + f[7].value() as int * g[1].value() as int * 0x2000000000000000000000000000000000000000000000000000 + f[7].value() as int * g[2].value() as int * 0x4000000000000000000000000000000000000000000000000000000000 + f[7].value() as int * g[3].value() as int * 0x10000000000000000000000000000000000000000000000000000000000000000 + f[7].value() as int * g[4].value() as int * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + f[7].value() as int * g[5].value() as int * 0x80000000000000000000000000000000000000000000000000000000000000000000000000000 + f[7].value() as int * g[6].value() as int * 0x100000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[7].value() as int * g[7].value() as int * 0x400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[7].value() as int * g[8].value() as int * 0x800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[7].value() as int * g[9].value() as int * 0x2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[8].value() as int * g[0].value() as int * 0x1000000000000000000000000000000000000000000000000000 + f[8].value() as int * g[1].value() as int * 0x4000000000000000000000000000000000000000000000000000000000 + f[8].value() as int * g[2].value() as int * 0x8000000000000000000000000000000000000000000000000000000000000000 + f[8].value() as int * g[3].value() as int * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + f[8].value() as int * g[4].value() as int * 0x40000000000000000000000000000000000000000000000000000000000000000000000000000 + f[8].value() as int * g[5].value() as int * 0x100000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[8].value() as int * g[6].value() as int * 0x200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[8].value() as int * g[7].value() as int * 0x800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[8].value() as int * g[8].value() as int * 0x1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[8].value() as int * g[9].value() as int * 0x4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[9].value() as int * g[0].value() as int * 0x4000000000000000000000000000000000000000000000000000000000 + f[9].value() as int * g[1].value() as int * 0x10000000000000000000000000000000000000000000000000000000000000000 + f[9].value() as int * g[2].value() as int * 0x20000000000000000000000000000000000000000000000000000000000000000000000 + f[9].value() as int * g[3].value() as int * 0x80000000000000000000000000000000000000000000000000000000000000000000000000000 + f[9].value() as int * g[4].value() as int * 0x100000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[9].value() as int * g[5].value() as int * 0x400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[9].value() as int * g[6].value() as int * 0x800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[9].value() as int * g[7].value() as int * 0x2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[9].value() as int * g[8].value() as int * 0x4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 + f[9].value() as int * g[9].value() as int * 0x10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 by {};
    product_id(
        f[0].value() as int * g[0].value() as int,
        f[0].value() as int * g[1].value() as int,
        f[0].value() as int * g[2].value() as int,
        f[0].value() as int * g[3].value() as int,
        f[0].value() as int * g[4].value() as int,
        f[0].value() as int * g[5].value() as int,
        f[0].value() as int * g[6].value() as int,
        f[0].value() as int * g[7].value() as int,
        f[0].value() as int * g[8].value() as int,
        f[0].value() as int * g[9].value() as int,
        f[1].value() as int * g[0].value() as int,
        f[1].value() as int * g[1].value() as int,
        f[1].value() as int * g[2].value() as int,
        f[1].value() as int * g[3].value() as int,
        f[1].value() as int * g[4].value() as int,
        f[1].value() as int * g[5].value() as int,
        f[1].value() as int * g[6].value() as int,
        f[1].value() as int * g[7].value() as int,
        f[1].value() as int * g[8].value() as int,
        f[1].value() as int * g[9].value() as int,
        f[2].value() as int * g[0].value() as int,
        f[2].value() as int * g[1].value() as int,
        f[2].value() as int * g[2].value() as int,
        f[2].value() as int * g[3].value() as int,
        f[2].value() as int * g[4].value() as int,
        f[2].value() as int * g[5].value() as int,
        f[2].value() as int * g[6].value() as int,
        f[2].value() as int * g[7].value() as int,
        f[2].value() as int * g[8].value() as int,
        f[2].value() as int * g[9].value() as int,
        f[3].value() as int * g[0].value() as int,
        f[3].value() as int * g[1].value() as int,
        f[3].value() as int * g[2].value() as int,
        f[3].value() as int * g[3].value() as int,
        f[3].value() as int * g[4].value() as int,
        f[3].value() as int * g[5].value() as int,
        f[3].value() as int * g[6].value() as int,
        f[3].value() as int * g[7].value() as int,
        f[3].value() as int * g[8].value() as int,
        f[3].value() as int * g[9].value() as int,
        f[4].value() as int * g[0].value() as int,
        f[4].value() as int * g[1].value() as int,
        f[4].value() as int * g[2].value() as int,
        f[4].value() as int * g[3].value() as int,
        f[4].value() as int * g[4].value() as int,
        f[4].value() as int * g[5].value() as int,
        f[4].value() as int * g[6].value() as int,
        f[4].value() as int * g[7].value() as int,
        f[4].value() as int * g[8].value() as int,
        f[4].value() as int * g[9].value() as int,
        f[5].value() as int * g[0].value() as int,
        f[5].value() as int * g[1].value() as int,
        f[5].value() as int * g[2].value() as int,
        f[5].value() as int * g[3].value() as int,
        f[5].value() as int * g[4].value() as int,
        f[5].value() as int * g[5].value() as int,
        f[5].value() as int * g[6].value() as int,
        f[5].value() as int * g[7].value() as int,
        f[5].value() as int * g[8].value() as int,
        f[5].value() as int * g[9].value() as int,
        f[6].value() as int * g[0].value() as int,
        f[6].value() as int * g[1].value() as int,
        f[6].value() as int * g[2].value() as int,
        f[6].value() as int * g[3].value() as int,
        f[6].value() as int * g[4].value() as int,
        f[6].value() as int * g[5].value() as int,
        f[6].value() as int * g[6].value() as int,
        f[6].value() as int * g[7].value() as int,
        f[6].value() as int * g[8].value() as int,
        f[6].value() as int * g[9].value() as int,
        f[7].value() as int * g[0].value() as int,
        f[7].value() as int * g[1].value() as int,
        f[7].value() as int * g[2].value() as int,
        f[7].value() as int * g[3].value() as int,
        f[7].value() as int * g[4].value() as int,
        f[7].value() as int * g[5].value() as int,
        f[7].value() as int * g[6].value() as int,
        f[7].value() as int * g[7].value() as int,
        f[7].value() as int * g[8].value() as int,
        f[7].value() as int * g[9].value() as int,
        f[8].value() as int * g[0].value() as int,
        f[8].value() as int * g[1].value() as int,
        f[8].value() as int * g[2].value() as int,
        f[8].value() as int * g[3].value() as int,
        f[8].value() as int * g[4].value() as int,
        f[8].value() as int * g[5].value() as int,
        f[8].value() as int * g[6].value() as int,
        f[8].value() as int * g[7].value() as int,
        f[8].value() as int * g[8].value() as int,
        f[8].value() as int * g[9].value() as int,
        f[9].value() as int * g[0].value() as int,
        f[9].value() as int * g[1].value() as int,
        f[9].value() as int * g[2].value() as int,
        f[9].value() as int * g[3].value() as int,
        f[9].value() as int * g[4].value() as int,
        f[9].value() as int * g[5].value() as int,
        f[9].value() as int * g[6].value() as int,
        f[9].value() as int * g[7].value() as int,
        f[9].value() as int * g[8].value() as int,
        f[9].value() as int * g[9].value() as int,
    );
    assert dval(d) == f[0].value() as int * g[0].value() as int + 38 * (f[1].value() as int * g[9].value() as int) + 19 * (f[2].value() as int * g[8].value() as int) + 38 * (f[3].value() as int * g[7].value() as int) + 19 * (f[4].value() as int * g[6].value() as int) + 38 * (f[5].value() as int * g[5].value() as int) + 19 * (f[6].value() as int * g[4].value() as int) + 38 * (f[7].value() as int * g[3].value() as int) + 19 * (f[8].value() as int * g[2].value() as int) + 38 * (f[9].value() as int * g[1].value() as int) + (f[0].value() as int * g[1].value() as int + f[1].value() as int * g[0].value() as int + 19 * (f[2].value() as int * g[9].value() as int) + 19 * (f[3].value() as int * g[8].value() as int) + 19 * (f[4].value() as int * g[7].value() as int) + 19 * (f[5].value() as int * g[6].value() as int) + 19 * (f[6].value() as int * g[5].value() as int) + 19 * (f[7].value() as int * g[4].value() as int) + 19 * (f[8].value() as int * g[3].value() as int) + 19 * (f[9].value() as int * g[2].value() as int)) * 0x4000000 + (f[0].value() as int * g[2].value() as int + 2 * (f[1].value() as int * g[1].value() as int) + f[2].value() as int * g[0].value() as int + 38 * (f[3].value() as int * g[9].value() as int) + 19 * (f[4].value() as int * g[8].value() as int) + 38 * (f[5].value() as int * g[7].value() as int) + 19 * (f[6].value() as int * g[6].value() as int) + 38 * (f[7].value() as int * g[5].value() as int) + 19 * (f[8].value() as int * g[4].value() as int) + 38 * (f[9].value() as int * g[3].value() as int)) * 0x8000000000000 + (f[0].value() as int * g[3].value() as int + f[1].value() as int * g[2].value() as int + f[2].value() as int * g[1].value() as int + f[3].value() as int * g[0].value() as int + 19 * (f[4].value() as int * g[9].value() as int) + 19 * (f[5].value() as int * g[8].value() as int) + 19 * (f[6].value() as int * g[7].value() as int) + 19 * (f[7].value() as int * g[6].value() as int) + 19 * (f[8].value() as int * g[5].value() as int) + 19 * (f[9].value() as int * g[4].value() as int)) * 0x20000000000000000000 + (f[0].value() as int * g[4].value() as int + 2 * (f[1].value() as int * g[3].value() as int) + f[2].value() as int * g[2].value() as int + 2 * (f[3].value() as int * g[1].value() as int) + f[4].value() as int * g[0].value() as int + 38 * (f[5].value() as int * g[9].value() as int) + 19 * (f[6].value() as int * g[8].value() as int) + 38 * (f[7].value() as int * g[7].value() as int) + 19 * (f[8].value() as int * g[6].value() as int) + 38 * (f[9].value() as int * g[5].value() as int)) * 0x40000000000000000000000000 + (f[0].value() as int * g[5].value() as int + f[1].value() as int * g[4].value() as int + f[2].value() as int * g[3].value() as int + f[3].value() as int * g[2].value() as int + f[4].value() as int * g[1].value() as int + f[5].value() as int * g[0].value() as int + 19 * (f[6].value() as int * g[9].value() as int) + 19 * (f[7].value() as int * g[8].value() as int) + 19 * (f[8].value() as int * g[7].value() as int) + 19 * (f[9].value() as int * g[6].value() as int)) * 0x100000000000000000000000000000000 + (f[0].value() as int * g[6].value() as int + 2 * (f[1].value() as int * g[5].value() as int) + f[2].value() as int * g[4].value() as int + 2 * (f[3].value() as int * g[3].value() as int) + f[4].value() as int * g[2].value() as int + 2 * (f[5].value() as int * g[1].value() as int) + f[6].value() as int * g[0].value() as int + 38 * (f[7].value() as int * g[9].value() as int) + 19 * (f[8].value() as int * g[8].value() as int) + 38 * (f[9].value() as int * g[7].value() as int)) * 0x200000000000000000000000000000000000000 + (f[0].value() as int * g[7].value() as int + f[1].value() as int * g[6].value() as int + f[2].value() as int * g[5].value() as int + f[3].value() as int * g[4].value() as int + f[4].value() as int * g[3].value() as int + f[5].value() as int * g[2].value() as int + f[6].value() as int * g[1].value() as int + f[7].value() as int * g[0].value() as int + 19 * (f[8].value() as int * g[9].value() as int) + 19 * (f[9].value() as int * g[8].value() as int)) * 0x800000000000000000000000000000000000000000000 + (f[0].value() as int * g[8].value() as int + 2 * (f[1].value() as int * g[7].value() as int) + f[2].value() as int * g[6].value() as int + 2 * (f[3].value() as int * g[5].value() as int) + f[4].value() as int * g[4].value() as int + 2 * (f[5].value() as int * g[3].value() as int) + f[6].value() as int * g[2].value() as int + 2 * (f[7].value() as int * g[1].value() as int) + f[8].value() as int * g[0].value() as int + 38 * (f[9].value() as int * g[9].value() as int)) * 0x1000000000000000000000000000000000000000000000000000 + (f[0].value() as int * g[9].value() as int + f[1].value() as int * g[8].value() as int + f[2].value() as int * g[7].value() as int + f[3].value() as int * g[6].value() as int + f[4].value() as int * g[5].value() as int + f[5].value() as int * g[4].value() as int + f[6].value() as int * g[3].value() as int + f[7].value() as int * g[2].value() as int + f[8].value() as int * g[1].value() as int + f[9].value() as int * g[0].value() as int) * 0x4000000000000000000000000000000000000000000000000000000000 by {};
    assert val(f) * val(g) == dval(d) + p() * q by {};
    arith::mod_add_multiple(dval(d), q, p());
    return carry(d);
}

// The field element limbs `f` stand for.
pub(package) spec fn fe(f: [Secret<u64>; 10]) int {
    return val(f) % p();
}

/// `a + b` in the field of the integers modulo p.
pub spec fn fadd(a: int, b: int) int {
    return (a + b) % p();
}

/// `a - b` in the field, for `a` and `b` in [0, p - 1].
pub spec fn fsub(a: int, b: int) int {
    return (a + p() - b) % p();
}

/// `a * b` in the field.
pub spec fn fmul(a: int, b: int) int {
    return a * b % p();
}

// `f * g`.
@constant_time
fn fe_mul(f: [Secret<u64>; 10], g: [Secret<u64>; 10]) [Secret<u64>; 10]
    requires loose(f) && loose(g)
    ensures |o| fe(o) == fmul(fe(f), fe(g)) && carried(o)
{
    let o = mul(f, g);
    arith::mod_mul(val(f), val(g), p());
    return o;
}

// `f + g`.
@constant_time
fn fe_add(f: [Secret<u64>; 10], g: [Secret<u64>; 10]) [Secret<u64>; 10]
    requires carried(f) && carried(g)
    ensures |o| fe(o) == fadd(fe(f), fe(g)) && loose(o)
{
    let o = [
        add(f[0], g[0]),
        add(f[1], g[1]),
        add(f[2], g[2]),
        add(f[3], g[3]),
        add(f[4], g[4]),
        add(f[5], g[5]),
        add(f[6], g[6]),
        add(f[7], g[7]),
        add(f[8], g[8]),
        add(f[9], g[9]),
    ];
    arith::mod_add(val(f), val(g), p());
    return o;
}

// `a + k - b`, at least 0 and below 2^64.
@constant_time
const fn add_sub(a: Secret<u64>, k: u64, b: Secret<u64>) Secret<u64>
    requires a.value() as int + k as int < 0x10000000000000000 && b.value() as int <= a.value() as int + k as int
    ensures |o| o.value() as int == a.value() as int + k as int - b.value() as int
{
    return a + Secret::new(k) - b;
}

// `a + 2p - b` modulo p is `a - b` in the field, for `b` below 2p.
lemma sub_mod(a: int, b: int)
    requires a >= 0 && 0 <= b && b < 2 * p()
    ensures (a + 2 * p() - b) % p() == fsub(a % p(), b % p())
{
    arith::div_mod(a, p());
    arith::div_mod(b, p());
    arith::mod_add_multiple(a % p() + p() - b % p(), a / p() + 1 - b / p(), p());
}

// `f - g`, as `f + 2p - g` limb by limb.
@constant_time
fn fe_sub(f: [Secret<u64>; 10], g: [Secret<u64>; 10]) [Secret<u64>; 10]
    requires carried(f) && carried(g)
    ensures |o| fe(o) == fsub(fe(f), fe(g)) && loose(o)
{
    let o = [
        add_sub(f[0], 0x7ffffda, g[0]),
        add_sub(f[1], 0x3fffffe, g[1]),
        add_sub(f[2], 0x7fffffe, g[2]),
        add_sub(f[3], 0x3fffffe, g[3]),
        add_sub(f[4], 0x7fffffe, g[4]),
        add_sub(f[5], 0x3fffffe, g[5]),
        add_sub(f[6], 0x7fffffe, g[6]),
        add_sub(f[7], 0x3fffffe, g[7]),
        add_sub(f[8], 0x7fffffe, g[8]),
        add_sub(f[9], 0x3fffffe, g[9]),
    ];
    assert val(o) == val(f) + 2 * p() - val(g) by {};
    sub_mod(val(f), val(g));
    return o;
}

// `121665 * f`.
@constant_time
fn fe_mul121665(f: [Secret<u64>; 10]) [Secret<u64>; 10]
    requires loose(f)
    ensures |o| fe(o) == fmul(121665, fe(f)) && carried(o)
{
    let d = [
        times(f[0], 121665),
        times(f[1], 121665),
        times(f[2], 121665),
        times(f[3], 121665),
        times(f[4], 121665),
        times(f[5], 121665),
        times(f[6], 121665),
        times(f[7], 121665),
        times(f[8], 121665),
        times(f[9], 121665),
    ];
    let o = carry(d);
    ghost let v = val(f);
    assert dval(d) == 121665 * v by {};
    assert fe(o) == 121665 * v % p() by {};
    // 121665 v = 121665 (v mod p) + 121665 (v / p) p.
    arith::div_mod(v, p());
    ghost let r = v % p();
    ghost let q = v / p();
    assert 121665 * v == 121665 * r + 121665 * q * p() by {};
    arith::mod_add_multiple(121665 * r, 121665 * q, p());
    assert fe(o) == 121665 * r % p() by {};
    return o;
}

// `f` where `c` is true, else `g`.
spec fn chosen(c: bool, f: [Secret<u64>; 10], g: [Secret<u64>; 10]) [Secret<u64>; 10] {
    return if c {
        f
    } else {
        g
    };
}

// `f` where `c` is true, else `g`, in constant time.
@constant_time
fn fe_pick(c: Secret<bool>, f: [Secret<u64>; 10], g: [Secret<u64>; 10]) [Secret<u64>; 10]
    ensures |o| o == chosen(c.value(), f, g)
{
    return [
        Secret::pick(c, f[0], g[0]),
        Secret::pick(c, f[1], g[1]),
        Secret::pick(c, f[2], g[2]),
        Secret::pick(c, f[3], g[3]),
        Secret::pick(c, f[4], g[4]),
        Secret::pick(c, f[5], g[5]),
        Secret::pick(c, f[6], g[6]),
        Secret::pick(c, f[7], g[7]),
        Secret::pick(c, f[8], g[8]),
        Secret::pick(c, f[9], g[9]),
    ];
}

/// `z` to the power `e`, in the field.
pub spec fn pow(z: int, e: int) int
    decreases e
{
    return if e <= 0 {
        1
    } else {
        z * pow(z, e - 1) % p()
    };
}

// A power lies in [0, p - 1].
lemma pow_range(z: int, e: int)
    requires 0 <= z && z < p()
    ensures 0 <= pow(z, e) && pow(z, e) < p()
    decreases e
{
    if e > 0 {
        pow_range(z, e - 1);
        arith::mul_nonneg(z, pow(z, e - 1));
        arith::div_mod(z * pow(z, e - 1), p());
    }
}

// `z^(a + b)` is `z^a * z^b`.
lemma pow_add(z: int, a: int, b: int)
    requires 0 <= z && z < p() && a >= 0 && b >= 0
    ensures pow(z, a + b) == pow(z, a) * pow(z, b) % p()
    decreases b
{
    pow_range(z, a);
    if b == 0 {
        arith::mod_unique(pow(z, a), 0, pow(z, a), p());
        assert pow(z, b) == 1 by {};
        assert pow(z, a + b) == pow(z, a) by {};
    } else {
        pow_add(z, a, b - 1);
        pow_range(z, b - 1);
        ghost let x = pow(z, a);
        ghost let y = pow(z, b - 1);
        arith::mul_nonneg(x, y);
        arith::mul_nonneg(z, y);
        arith::mod_unique(z, 0, z, p());
        arith::mod_unique(x, 0, x, p());
        assert pow(z, a + b) == z * pow(z, a + b - 1) % p() by {};
        assert pow(z, a + b - 1) == x * y % p() by {};
        // z (x y mod p) and x (z y mod p) are both z x y modulo p.
        arith::mod_mul(z, x * y, p());
        assert pow(z, a + b) == z * (x * y) % p() by {};
        assert pow(z, b) == z * y % p() by {};
        arith::mod_mul(x, z * y, p());
        assert x * pow(z, b) % p() == x * (z * y) % p() by {};
        arith::mul_eq(z, x * y, y * x);
    }
}
// `(z^e)^m` is `z^(e m)`.
lemma pow_pow(z: int, e: int, m: int)
    requires 0 <= z && z < p() && e >= 0 && m >= 0
    ensures pow(pow(z, e), m) == pow(z, e * m)
    decreases m
{
    if m == 0 {
        assert pow(pow(z, e), m) == 1 by {};
        assert pow(z, e * m) == 1 by {};
    } else {
        pow_pow(z, e, m - 1);
        pow_range(z, e);
        arith::mul_nonneg(e, m - 1);
        pow_add(z, e, e * (m - 1));
        assert pow(pow(z, e), m) == pow(z, e) * pow(pow(z, e), m - 1) % p() by {};
        assert e + e * (m - 1) == e * m by {};
    }
}

// The element of limbs `f` lies in [0, p - 1].
lemma fe_range(f: [Secret<u64>; 10])
    ensures 0 <= fe(f) && fe(f) < p()
{
    arith::div_mod(val(f), p());
}

// `f` squared `n` times.
@constant_time
fn sq_n(f: [Secret<u64>; 10], n: usize) [Secret<u64>; 10]
    requires carried(f)
    ensures |o| fe(o) == pow(fe(f), arith::pow2(n as nat)) && carried(o)
{
    ghost let y = fe(f);
    fe_range(f);
    pow_range(y, 1);
    arith::mod_unique(y, 0, y, p());
    assert pow(y, 0) == 1 by {};
    assert pow(y, 1) == y * pow(y, 0) % p() by {};
    assert pow(y, 1) == y by {};
    assert arith::pow2(0) == 1 by {};
    let mut x = f;
    for i in 0..n
        invariant carried(x) && fe(x) == pow(y, arith::pow2(i as nat))
    {
        ghost let m = arith::pow2(i as nat);
        arith::pow2_pos(i as nat);
        pow_add(y, m, m);
        assert arith::pow2(i as nat + 1) == m + m by {};
        x = fe_mul(x, x);
    }
    return x;
}

// The powers of 2 the inversion's chain reads.
lemma powers()
    ensures arith::pow2(1) == 2 && arith::pow2(2) == 4 && arith::pow2(5) == 32 && arith::pow2(10) == 0x400
    ensures arith::pow2(20) == 0x100000 && arith::pow2(50) == 0x4000000000000 && arith::pow2(100) == 0x10000000000000000000000000
{
    assert arith::pow2(1) == 2 by {};
    arith::pow2_add(1, 1);
    arith::pow2_add(2, 2);
    arith::pow2_add(4, 1);
    arith::pow2_add(5, 5);
    arith::pow2_add(10, 10);
    arith::pow2_add(20, 20);
    arith::pow2_add(40, 10);
    arith::pow2_add(50, 50);
}

// `f^(p - 2)`, the inverse of a nonzero `f` (Fermat), by 254 squarings and 11 products.
@constant_time
fn invert(f: [Secret<u64>; 10]) [Secret<u64>; 10]
    requires carried(f)
    ensures |o| fe(o) == pow(fe(f), p() - 2) && carried(o)
{
    ghost let z = fe(f);
    fe_range(f);
    powers();
    arith::mod_unique(z, 0, z, p());
    assert pow(z, 0) == 1 by {};
    assert pow(z, 1) == z * pow(z, 0) % p() by {};
    let z2 = fe_mul(f, f);
    pow_add(z, 1, 1);
    assert fe(z2) == pow(z, 0x2) by {};
    let z8 = sq_n(z2, 2);
    pow_pow(z, 2, 4);
    assert fe(z8) == pow(z, 0x8) by {};
    let z9 = fe_mul(z8, f);
    pow_add(z, 8, 1);
    assert fe(z9) == pow(z, 0x9) by {};
    let z11 = fe_mul(z9, z2);
    pow_add(z, 9, 2);
    assert fe(z11) == pow(z, 0xb) by {};
    let z22 = fe_mul(z11, z11);
    pow_add(z, 11, 11);
    assert fe(z22) == pow(z, 0x16) by {};
    // z^(2^k - 1) for k = 5, 10, 20, 40, 50, 100, 200, 250.
    let a5 = fe_mul(z22, z9);
    pow_add(z, 22, 9);
    assert fe(a5) == pow(z, 0x1f) by {};
    let a10 = fe_mul(sq_n(a5, 5), a5);
    pow_pow(z, 0x1f, 0x20);
    pow_add(z, 0x3e0, 0x1f);
    assert fe(a10) == pow(z, 0x3ff) by {};
    let a20 = fe_mul(sq_n(a10, 10), a10);
    pow_pow(z, 0x3ff, 0x400);
    pow_add(z, 0xffc00, 0x3ff);
    assert fe(a20) == pow(z, 0xfffff) by {};
    let a40 = fe_mul(sq_n(a20, 20), a20);
    pow_pow(z, 0xfffff, 0x100000);
    pow_add(z, 0xfffff00000, 0xfffff);
    assert fe(a40) == pow(z, 0xffffffffff) by {};
    let a50 = fe_mul(sq_n(a40, 10), a10);
    pow_pow(z, 0xffffffffff, 0x400);
    pow_add(z, 0x3fffffffffc00, 0x3ff);
    assert fe(a50) == pow(z, 0x3ffffffffffff) by {};
    let a100 = fe_mul(sq_n(a50, 50), a50);
    pow_pow(z, 0x3ffffffffffff, 0x4000000000000);
    pow_add(z, 0xffffffffffffc000000000000, 0x3ffffffffffff);
    assert fe(a100) == pow(z, 0xfffffffffffffffffffffffff) by {};
    let a200 = fe_mul(sq_n(a100, 100), a100);
    pow_pow(z, 0xfffffffffffffffffffffffff, 0x10000000000000000000000000);
    pow_add(z, 0xfffffffffffffffffffffffff0000000000000000000000000, 0xfffffffffffffffffffffffff);
    assert fe(a200) == pow(z, 0xffffffffffffffffffffffffffffffffffffffffffffffffff) by {};
    let a250 = fe_mul(sq_n(a200, 50), a50);
    pow_pow(z, 0xffffffffffffffffffffffffffffffffffffffffffffffffff, 0x4000000000000);
    pow_add(z, 0x3fffffffffffffffffffffffffffffffffffffffffffffffffc000000000000, 0x3ffffffffffff);
    assert fe(a250) == pow(z, 0x3ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff) by {};
    let o = fe_mul(sq_n(a250, 5), z11);
    pow_pow(z, 0x3ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff, 32);
    pow_add(z, 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0, 11);
    assert fe(o) == pow(z, 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeb) by {};
    assert p() - 2 == 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeb by {};
    return o;
}

/// Byte `i` of scalar `k` as RFC 7748, 5 decodes it: bits 0 to 2 cleared, bit 255 cleared, bit 254 set.
pub spec fn clamped(k: [u8; 32], i: int) u8 {
    return if i == 0 {
        k[0] & 248
    } else if i == 31 {
        k[31] & 127 | 64
    } else if 0 < i && i < 31 {
        k[i as usize]
    } else {
        0
    };
}

/// Bit `t` of the decoded scalar `k`: 0 or 1.
pub spec fn scalar_bit(k: [u8; 32], t: int) int {
    return if 0 <= t && t < 256 {
        (clamped(k, t / 8) >> (t % 8) as u8 & 1) as int
    } else {
        0
    };
}

/// The u-coordinate `u` decodes to (RFC 7748, 5): little-endian, bit 255 cleared, modulo p.
pub spec fn decode_u(u: [u8; 32]) int {
    return (u[0] as int + u[1] as int * 0x100 + u[2] as int * 0x10000 + u[3] as int * 0x1000000 + u[4] as int * 0x100000000 + u[5] as int * 0x10000000000 + u[6] as int * 0x1000000000000 + u[7] as int * 0x100000000000000 + u[8] as int * 0x10000000000000000 + u[9] as int * 0x1000000000000000000 + u[10] as int * 0x100000000000000000000 + u[11] as int * 0x10000000000000000000000 + u[12] as int * 0x1000000000000000000000000 + u[13] as int * 0x100000000000000000000000000 + u[14] as int * 0x10000000000000000000000000000 + u[15] as int * 0x1000000000000000000000000000000 + u[16] as int * 0x100000000000000000000000000000000 + u[17] as int * 0x10000000000000000000000000000000000 + u[18] as int * 0x1000000000000000000000000000000000000 + u[19] as int * 0x100000000000000000000000000000000000000 + u[20] as int * 0x10000000000000000000000000000000000000000 + u[21] as int * 0x1000000000000000000000000000000000000000000 + u[22] as int * 0x100000000000000000000000000000000000000000000 + u[23] as int * 0x10000000000000000000000000000000000000000000000 + u[24] as int * 0x1000000000000000000000000000000000000000000000000 + u[25] as int * 0x100000000000000000000000000000000000000000000000000 + u[26] as int * 0x10000000000000000000000000000000000000000000000000000 + u[27] as int * 0x1000000000000000000000000000000000000000000000000000000 + u[28] as int * 0x100000000000000000000000000000000000000000000000000000000 + u[29] as int * 0x10000000000000000000000000000000000000000000000000000000000 + u[30] as int * 0x1000000000000000000000000000000000000000000000000000000000000 + (u[31] & 127) as int * 0x100000000000000000000000000000000000000000000000000000000000000) % p();
}

// The first argument where `sw` is 0, the second where it is 1 (`cswap`).
spec fn cs(sw: int, a: int, b: int) int {
    return if sw == 1 {
        b
    } else {
        a
    };
}

/// One step of the Montgomery ladder (RFC 7748, 5) on state `s` = [x_2, z_2, x_3, z_3, swap], with
/// u-coordinate `x1` and scalar bit `kt`.
pub spec fn ladder_step(s: [int; 5], x1: int, kt: int) [int; 5] {
    let sw = (s[4] + kt) % 2;
    let x2 = cs(sw, s[0], s[2]);
    let z2 = cs(sw, s[1], s[3]);
    let x3 = cs(sw, s[2], s[0]);
    let z3 = cs(sw, s[3], s[1]);
    let a = fadd(x2, z2);
    let aa = fmul(a, a);
    let b = fsub(x2, z2);
    let bb = fmul(b, b);
    let e = fsub(aa, bb);
    let c = fadd(x3, z3);
    let d = fsub(x3, z3);
    let da = fmul(d, a);
    let cb = fmul(c, b);
    return [
        fmul(aa, bb),
        fmul(e, fadd(aa, fmul(121665, e))),
        fmul(fadd(da, cb), fadd(da, cb)),
        fmul(x1, fmul(fsub(da, cb), fsub(da, cb))),
        kt,
    ];
}

/// The ladder's state after its first `n` steps, on bits 254 down to 255 - n of scalar `k`.
pub spec fn ladder(k: [u8; 32], x1: int, n: int) [int; 5]
    decreases n
{
    return if n <= 0 {
        [1, 0, x1, 1, 0]
    } else {
        ladder_step(ladder(k, x1, n - 1), x1, scalar_bit(k, 255 - n))
    };
}

/// X25519(k, u) (RFC 7748, 5): the u-coordinate of the scalar multiple, `x_2 * z_2^(p - 2)` after the
/// last swap, in [0, p - 1].
pub spec fn scalar_mult(k: [u8; 32], u: [u8; 32]) int {
    let s = ladder(k, decode_u(u), 255);
    return fmul(cs(s[4], s[0], s[2]), pow(cs(s[4], s[1], s[3]), p() - 2));
}

/// The value of little-endian bytes `b`.
pub spec fn le_value(b: [u8; 32]) int {
    return b[0] as int + b[1] as int * 0x100 + b[2] as int * 0x10000 + b[3] as int * 0x1000000 + b[4] as int * 0x100000000 + b[5] as int * 0x10000000000 + b[6] as int * 0x1000000000000 + b[7] as int * 0x100000000000000 + b[8] as int * 0x10000000000000000 + b[9] as int * 0x1000000000000000000 + b[10] as int * 0x100000000000000000000 + b[11] as int * 0x10000000000000000000000 + b[12] as int * 0x1000000000000000000000000 + b[13] as int * 0x100000000000000000000000000 + b[14] as int * 0x10000000000000000000000000000 + b[15] as int * 0x1000000000000000000000000000000 + b[16] as int * 0x100000000000000000000000000000000 + b[17] as int * 0x10000000000000000000000000000000000 + b[18] as int * 0x1000000000000000000000000000000000000 + b[19] as int * 0x100000000000000000000000000000000000000 + b[20] as int * 0x10000000000000000000000000000000000000000 + b[21] as int * 0x1000000000000000000000000000000000000000000 + b[22] as int * 0x100000000000000000000000000000000000000000000 + b[23] as int * 0x10000000000000000000000000000000000000000000000 + b[24] as int * 0x1000000000000000000000000000000000000000000000000 + b[25] as int * 0x100000000000000000000000000000000000000000000000000 + b[26] as int * 0x10000000000000000000000000000000000000000000000000000 + b[27] as int * 0x1000000000000000000000000000000000000000000000000000000 + b[28] as int * 0x100000000000000000000000000000000000000000000000000000000 + b[29] as int * 0x10000000000000000000000000000000000000000000000000000000000 + b[30] as int * 0x1000000000000000000000000000000000000000000000000000000000000 + b[31] as int * 0x100000000000000000000000000000000000000000000000000000000000000;
}
/// The values of bytes `b`.
pub spec fn bytes(b: [Secret<u8>; 32]) [u8; 32] {
    return [
        b[0].value(),
        b[1].value(),
        b[2].value(),
        b[3].value(),
        b[4].value(),
        b[5].value(),
        b[6].value(),
        b[7].value(),
        b[8].value(),
        b[9].value(),
        b[10].value(),
        b[11].value(),
        b[12].value(),
        b[13].value(),
        b[14].value(),
        b[15].value(),
        b[16].value(),
        b[17].value(),
        b[18].value(),
        b[19].value(),
        b[20].value(),
        b[21].value(),
        b[22].value(),
        b[23].value(),
        b[24].value(),
        b[25].value(),
        b[26].value(),
        b[27].value(),
        b[28].value(),
        b[29].value(),
        b[30].value(),
        b[31].value(),
    ];
}

// 1 where `b` holds, else 0.
spec fn bit(b: bool) int {
    return if b {
        1
    } else {
        0
    };
}

// The ladder state of field elements `s` and swap `sw`.
spec fn state(s: [[Secret<u64>; 10]; 4], sw: bool) [int; 5] {
    return [fe(s[0]), fe(s[1]), fe(s[2]), fe(s[3]), bit(sw)];
}

// Each of the field elements of `s` as `carry` leaves it.
spec fn all_carried(s: [[Secret<u64>; 10]; 4]) bool {
    return carried(s[0]) && carried(s[1]) && carried(s[2]) && carried(s[3]);
}

// The element `fe_pick` chose.
lemma picked(c: bool, f: [Secret<u64>; 10], g: [Secret<u64>; 10], o: [Secret<u64>; 10])
    requires o == chosen(c, f, g) && carried(f) && carried(g)
    ensures fe(o) == cs(bit(c), fe(g), fe(f)) && carried(o)
{}

// One ladder step (`ladder_step`) on state `s` with swap `swap`, u-coordinate `x1` and scalar bit `kt`.
@constant_time
fn step(s: [[Secret<u64>; 10]; 4], swap: Secret<bool>, x1: [Secret<u64>; 10], kt: Secret<bool>) [[Secret<u64>; 10]; 4]
    requires all_carried(s) && carried(x1)
    ensures |o| all_carried(o) && state(o, kt.value()) == ladder_step(state(s, swap.value()), fe(x1), bit(kt.value()))
{
    let sw = swap ^ kt;
    assert bit(sw.value()) == (bit(swap.value()) + bit(kt.value())) % 2 by {};
    let x2 = fe_pick(sw, s[2], s[0]);
    picked(sw.value(), s[2], s[0], x2);
    let z2 = fe_pick(sw, s[3], s[1]);
    picked(sw.value(), s[3], s[1], z2);
    let x3 = fe_pick(sw, s[0], s[2]);
    picked(sw.value(), s[0], s[2], x3);
    let z3 = fe_pick(sw, s[1], s[3]);
    picked(sw.value(), s[1], s[3], z3);
    let a = fe_add(x2, z2);
    let aa = fe_mul(a, a);
    let b = fe_sub(x2, z2);
    let bb = fe_mul(b, b);
    let e = fe_sub(aa, bb);
    let c = fe_add(x3, z3);
    let d = fe_sub(x3, z3);
    let da = fe_mul(d, a);
    let cb = fe_mul(c, b);
    let sum = fe_add(da, cb);
    let dif = fe_sub(da, cb);
    return [fe_mul(aa, bb), fe_mul(e, fe_add(aa, fe_mul121665(e))), fe_mul(sum, sum), fe_mul(x1, fe_mul(dif, dif))];
}

// Bit 254 - `n` of the decoded scalar `k`, the bit of ladder step `n`: the low bit of clamped byte
// `t / 8` (`clamped`) shifted right by `t % 8`.
@constant_time
fn scalar_bit_ct(k: [Secret<u8>; 32], n: usize) Secret<bool>
    requires n < 255
    ensures |b| bit(b.value()) == scalar_bit(bytes(k), 255 - (n as int + 1))
{
    let t = 254 - n;
    let i = t / 8;
    let mut x = k[i];
    if i == 0 {
        x = x & Secret::new(248u8);
    }
    if i == 31 {
        x = x & Secret::new(127u8) | Secret::new(64u8);
    }
    return (x >> t % 8 & Secret::new(1u8)).ne(Secret::new(0u8));
}

// A state equal to `ladder(n)`, stepped on bit 255 - (n + 1), is `ladder(n + 1)`.
lemma ladder_next(k: [u8; 32], x1: int, n: int, x: [int; 5], b: int)
    requires 0 <= n && x == ladder(k, x1, n) && b == scalar_bit(k, 255 - (n + 1))
    ensures ladder_step(x, x1, b) == ladder(k, x1, n + 1)
{
    assert ladder(k, x1, n + 1) == ladder_step(ladder(k, x1, n), x1, scalar_bit(k, 255 - (n + 1))) by {};
}

// The ladder on scalar `k` and u-coordinate `x1`, after its last swap: x_2 and z_2.
@constant_time
fn ladder_ct(k: [Secret<u8>; 32], x1: [Secret<u64>; 10]) [[Secret<u64>; 10]; 2]
    requires carried(x1)
    ensures |o| carried(o[0]) && carried(o[1])
    ensures |o| fe(o[0]) == cs(
        ladder(bytes(k), fe(x1), 255)[4],
        ladder(bytes(k), fe(x1), 255)[0],
        ladder(bytes(k), fe(x1), 255)[2],
    )
    ensures |o| fe(o[1]) == cs(
        ladder(bytes(k), fe(x1), 255)[4],
        ladder(bytes(k), fe(x1), 255)[1],
        ladder(bytes(k), fe(x1), 255)[3],
    )
{
    let zero = [
        Secret::new(0u64),
        Secret::new(0u64),
        Secret::new(0u64),
        Secret::new(0u64),
        Secret::new(0u64),
        Secret::new(0u64),
        Secret::new(0u64),
        Secret::new(0u64),
        Secret::new(0u64),
        Secret::new(0u64),
    ];
    let mut one = zero;
    one[0] = Secret::new(1u64);
    let mut s = [one, zero, x1, one];
    let mut swap = Secret::new(false);
    assert state(s, swap.value()) == ladder(bytes(k), fe(x1), 0) by {};
    for i in 0usize..255
        invariant all_carried(s) && state(s, swap.value()) == ladder(bytes(k), fe(x1), i as int)
    {
        let kt = scalar_bit_ct(k, i);
        let next = step(s, swap, x1, kt);
        ladder_next(bytes(k), fe(x1), i as int, state(s, swap.value()), bit(kt.value()));
        s = next;
        swap = kt;
    }
    let x2 = fe_pick(swap, s[2], s[0]);
    picked(swap.value(), s[2], s[0], x2);
    let z2 = fe_pick(swap, s[3], s[1]);
    picked(swap.value(), s[3], s[1], z2);
    return [x2, z2];
}

// Limb 0 of a little-endian number: bits 0 to 25, from its bytes 0 to 3.
@constant_time
const fn limb0(b0: Secret<u64>, b1: Secret<u64>, b2: Secret<u64>, b3: Secret<u64>) Secret<u64>
    requires b0.value() < 256 && b1.value() < 256 && b2.value() < 256 && b3.value() < 256
    ensures |o| o.value() as int == b0.value() as int + b1.value() as int * 0x100 + b2.value() as int * 0x10000 + (b3.value() & 0x3) as int * 0x1000000
    ensures |o| o.value() < 0x4000000
{
    return b0 + (b1 << 8) + (b2 << 16) + ((b3 & Secret::new(0x3u64)) << 24);
}

// Limb 1 of a little-endian number: bits 26 to 50, from its bytes 3 to 6.
@constant_time
const fn limb1(b0: Secret<u64>, b1: Secret<u64>, b2: Secret<u64>, b3: Secret<u64>) Secret<u64>
    requires b0.value() < 256 && b1.value() < 256 && b2.value() < 256 && b3.value() < 256
    ensures |o| o.value() as int == (b0.value() >> 2) as int + b1.value() as int * 0x40 + b2.value() as int * 0x4000 + (b3.value() & 0x7) as int * 0x400000
    ensures |o| o.value() < 0x2000000
{
    return (b0 >> 2) + (b1 << 6) + (b2 << 14) + ((b3 & Secret::new(0x7u64)) << 22);
}

// Limb 2 of a little-endian number: bits 51 to 76, from its bytes 6 to 9.
@constant_time
const fn limb2(b0: Secret<u64>, b1: Secret<u64>, b2: Secret<u64>, b3: Secret<u64>) Secret<u64>
    requires b0.value() < 256 && b1.value() < 256 && b2.value() < 256 && b3.value() < 256
    ensures |o| o.value() as int == (b0.value() >> 3) as int + b1.value() as int * 0x20 + b2.value() as int * 0x2000 + (b3.value() & 0x1f) as int * 0x200000
    ensures |o| o.value() < 0x4000000
{
    return (b0 >> 3) + (b1 << 5) + (b2 << 13) + ((b3 & Secret::new(0x1fu64)) << 21);
}

// Limb 3 of a little-endian number: bits 77 to 101, from its bytes 9 to 12.
@constant_time
const fn limb3(b0: Secret<u64>, b1: Secret<u64>, b2: Secret<u64>, b3: Secret<u64>) Secret<u64>
    requires b0.value() < 256 && b1.value() < 256 && b2.value() < 256 && b3.value() < 256
    ensures |o| o.value() as int == (b0.value() >> 5) as int + b1.value() as int * 0x8 + b2.value() as int * 0x800 + (b3.value() & 0x3f) as int * 0x80000
    ensures |o| o.value() < 0x2000000
{
    return (b0 >> 5) + (b1 << 3) + (b2 << 11) + ((b3 & Secret::new(0x3fu64)) << 19);
}

// Limb 4 of a little-endian number: bits 102 to 127, from its bytes 12 to 15.
@constant_time
const fn limb4(b0: Secret<u64>, b1: Secret<u64>, b2: Secret<u64>, b3: Secret<u64>) Secret<u64>
    requires b0.value() < 256 && b1.value() < 256 && b2.value() < 256 && b3.value() < 256
    ensures |o| o.value() as int == (b0.value() >> 6) as int + b1.value() as int * 0x4 + b2.value() as int * 0x400 + b3.value() as int * 0x40000
    ensures |o| o.value() < 0x4000000
{
    return (b0 >> 6) + (b1 << 2) + (b2 << 10) + (b3 << 18);
}

// Limb 5 of a little-endian number: bits 128 to 152, from its bytes 16 to 19.
@constant_time
const fn limb5(b0: Secret<u64>, b1: Secret<u64>, b2: Secret<u64>, b3: Secret<u64>) Secret<u64>
    requires b0.value() < 256 && b1.value() < 256 && b2.value() < 256 && b3.value() < 256
    ensures |o| o.value() as int == b0.value() as int + b1.value() as int * 0x100 + b2.value() as int * 0x10000 + (b3.value() & 0x1) as int * 0x1000000
    ensures |o| o.value() < 0x2000000
{
    return b0 + (b1 << 8) + (b2 << 16) + ((b3 & Secret::new(0x1u64)) << 24);
}

// Limb 6 of a little-endian number: bits 153 to 178, from its bytes 19 to 22.
@constant_time
const fn limb6(b0: Secret<u64>, b1: Secret<u64>, b2: Secret<u64>, b3: Secret<u64>) Secret<u64>
    requires b0.value() < 256 && b1.value() < 256 && b2.value() < 256 && b3.value() < 256
    ensures |o| o.value() as int == (b0.value() >> 1) as int + b1.value() as int * 0x80 + b2.value() as int * 0x8000 + (b3.value() & 0x7) as int * 0x800000
    ensures |o| o.value() < 0x4000000
{
    return (b0 >> 1) + (b1 << 7) + (b2 << 15) + ((b3 & Secret::new(0x7u64)) << 23);
}

// Limb 7 of a little-endian number: bits 179 to 203, from its bytes 22 to 25.
@constant_time
const fn limb7(b0: Secret<u64>, b1: Secret<u64>, b2: Secret<u64>, b3: Secret<u64>) Secret<u64>
    requires b0.value() < 256 && b1.value() < 256 && b2.value() < 256 && b3.value() < 256
    ensures |o| o.value() as int == (b0.value() >> 3) as int + b1.value() as int * 0x20 + b2.value() as int * 0x2000 + (b3.value() & 0xf) as int * 0x200000
    ensures |o| o.value() < 0x2000000
{
    return (b0 >> 3) + (b1 << 5) + (b2 << 13) + ((b3 & Secret::new(0xfu64)) << 21);
}

// Limb 8 of a little-endian number: bits 204 to 229, from its bytes 25 to 28.
@constant_time
const fn limb8(b0: Secret<u64>, b1: Secret<u64>, b2: Secret<u64>, b3: Secret<u64>) Secret<u64>
    requires b0.value() < 256 && b1.value() < 256 && b2.value() < 256 && b3.value() < 256
    ensures |o| o.value() as int == (b0.value() >> 4) as int + b1.value() as int * 0x10 + b2.value() as int * 0x1000 + (b3.value() & 0x3f) as int * 0x100000
    ensures |o| o.value() < 0x4000000
{
    return (b0 >> 4) + (b1 << 4) + (b2 << 12) + ((b3 & Secret::new(0x3fu64)) << 20);
}

// Limb 9 of a little-endian number: bits 230 to 254, from its bytes 28 to 31.
@constant_time
const fn limb9(b0: Secret<u64>, b1: Secret<u64>, b2: Secret<u64>, b3: Secret<u64>) Secret<u64>
    requires b0.value() < 256 && b1.value() < 256 && b2.value() < 256 && b3.value() < 256
    ensures |o| o.value() as int == (b0.value() >> 6) as int + b1.value() as int * 0x4 + b2.value() as int * 0x400 + (b3.value() & 0x7f) as int * 0x40000
    ensures |o| o.value() < 0x2000000
{
    return (b0 >> 6) + (b1 << 2) + (b2 << 10) + ((b3 & Secret::new(0x7fu64)) << 18);
}

// Byte `b` split at bit 1.
lemma byte_split1(b: u64)
    requires b < 256
    ensures b as int == (b & 0x1) as int + 0x2 * (b >> 1) as int && b >> 1 < 0x80
{
    assert (b & 0x1) == b % 0x2 && b >> 1 == b / 0x2 by {};
}

// Byte `b` split at bit 2.
lemma byte_split2(b: u64)
    requires b < 256
    ensures b as int == (b & 0x3) as int + 0x4 * (b >> 2) as int && b >> 2 < 0x40
{
    assert (b & 0x3) == b % 0x4 && b >> 2 == b / 0x4 by {};
}

// Byte `b` split at bit 3.
lemma byte_split3(b: u64)
    requires b < 256
    ensures b as int == (b & 0x7) as int + 0x8 * (b >> 3) as int && b >> 3 < 0x20
{
    assert (b & 0x7) == b % 0x8 && b >> 3 == b / 0x8 by {};
}

// Byte `b` split at bit 4.
lemma byte_split4(b: u64)
    requires b < 256
    ensures b as int == (b & 0xf) as int + 0x10 * (b >> 4) as int && b >> 4 < 0x10
{
    assert (b & 0xf) == b % 0x10 && b >> 4 == b / 0x10 by {};
}

// Byte `b` split at bit 5.
lemma byte_split5(b: u64)
    requires b < 256
    ensures b as int == (b & 0x1f) as int + 0x20 * (b >> 5) as int && b >> 5 < 0x8
{
    assert (b & 0x1f) == b % 0x20 && b >> 5 == b / 0x20 by {};
}

// Byte `b` split at bit 6.
lemma byte_split6(b: u64)
    requires b < 256
    ensures b as int == (b & 0x3f) as int + 0x40 * (b >> 6) as int && b >> 6 < 0x4
{
    assert (b & 0x3f) == b % 0x40 && b >> 6 == b / 0x40 by {};
}

// Byte `b` split at bit 7.
lemma byte_split7(b: u64)
    requires b < 256
    ensures b as int == (b & 0x7f) as int + 0x80 * (b >> 7) as int && b >> 7 < 0x2
{
    assert (b & 0x7f) == b % 0x80 && b >> 7 == b / 0x80 by {};
}

// The low 7 bits of byte `x`, at 64 bits and at 8.
lemma mask_byte(x: u8)
    ensures (x as u64 & 0x7f) as int == (x & 127) as int
{}

// The field element little-endian bytes `u` spell, bit 255 aside.
@constant_time
fn decode(u: [Secret<u8>; 32]) [Secret<u64>; 10]
    ensures |o| fe(o) == decode_u(bytes(u)) && carried(o)
{
    let b = [
        u[0].cast::<u64>(),
        u[1].cast::<u64>(),
        u[2].cast::<u64>(),
        u[3].cast::<u64>(),
        u[4].cast::<u64>(),
        u[5].cast::<u64>(),
        u[6].cast::<u64>(),
        u[7].cast::<u64>(),
        u[8].cast::<u64>(),
        u[9].cast::<u64>(),
        u[10].cast::<u64>(),
        u[11].cast::<u64>(),
        u[12].cast::<u64>(),
        u[13].cast::<u64>(),
        u[14].cast::<u64>(),
        u[15].cast::<u64>(),
        u[16].cast::<u64>(),
        u[17].cast::<u64>(),
        u[18].cast::<u64>(),
        u[19].cast::<u64>(),
        u[20].cast::<u64>(),
        u[21].cast::<u64>(),
        u[22].cast::<u64>(),
        u[23].cast::<u64>(),
        u[24].cast::<u64>(),
        u[25].cast::<u64>(),
        u[26].cast::<u64>(),
        u[27].cast::<u64>(),
        u[28].cast::<u64>(),
        u[29].cast::<u64>(),
        u[30].cast::<u64>(),
        u[31].cast::<u64>(),
    ];
    byte_split2(b[3].value());
    byte_split3(b[6].value());
    byte_split5(b[9].value());
    byte_split6(b[12].value());
    byte_split1(b[19].value());
    byte_split3(b[22].value());
    byte_split4(b[25].value());
    byte_split6(b[28].value());
    assert b[0].value() as int == u[0].value() as int by {};
    assert b[1].value() as int == u[1].value() as int by {};
    assert b[2].value() as int == u[2].value() as int by {};
    assert b[3].value() as int == u[3].value() as int by {};
    assert b[4].value() as int == u[4].value() as int by {};
    assert b[5].value() as int == u[5].value() as int by {};
    assert b[6].value() as int == u[6].value() as int by {};
    assert b[7].value() as int == u[7].value() as int by {};
    assert b[8].value() as int == u[8].value() as int by {};
    assert b[9].value() as int == u[9].value() as int by {};
    assert b[10].value() as int == u[10].value() as int by {};
    assert b[11].value() as int == u[11].value() as int by {};
    assert b[12].value() as int == u[12].value() as int by {};
    assert b[13].value() as int == u[13].value() as int by {};
    assert b[14].value() as int == u[14].value() as int by {};
    assert b[15].value() as int == u[15].value() as int by {};
    assert b[16].value() as int == u[16].value() as int by {};
    assert b[17].value() as int == u[17].value() as int by {};
    assert b[18].value() as int == u[18].value() as int by {};
    assert b[19].value() as int == u[19].value() as int by {};
    assert b[20].value() as int == u[20].value() as int by {};
    assert b[21].value() as int == u[21].value() as int by {};
    assert b[22].value() as int == u[22].value() as int by {};
    assert b[23].value() as int == u[23].value() as int by {};
    assert b[24].value() as int == u[24].value() as int by {};
    assert b[25].value() as int == u[25].value() as int by {};
    assert b[26].value() as int == u[26].value() as int by {};
    assert b[27].value() as int == u[27].value() as int by {};
    assert b[28].value() as int == u[28].value() as int by {};
    assert b[29].value() as int == u[29].value() as int by {};
    assert b[30].value() as int == u[30].value() as int by {};
    assert b[31].value() == u[31].value() as u64 by {};
    mask_byte(u[31].value());
    let o = [
        limb0(b[0], b[1], b[2], b[3]),
        limb1(b[3], b[4], b[5], b[6]),
        limb2(b[6], b[7], b[8], b[9]),
        limb3(b[9], b[10], b[11], b[12]),
        limb4(b[12], b[13], b[14], b[15]),
        limb5(b[16], b[17], b[18], b[19]),
        limb6(b[19], b[20], b[21], b[22]),
        limb7(b[22], b[23], b[24], b[25]),
        limb8(b[25], b[26], b[27], b[28]),
        limb9(b[28], b[29], b[30], b[31]),
    ];
    assert val(o) == b[0].value() as int + b[1].value() as int * 0x100 + b[2].value() as int * 0x10000 + b[3].value() as int * 0x1000000 + b[4].value() as int * 0x100000000 + b[5].value() as int * 0x10000000000 + b[6].value() as int * 0x1000000000000 + b[7].value() as int * 0x100000000000000 + b[8].value() as int * 0x10000000000000000 + b[9].value() as int * 0x1000000000000000000 + b[10].value() as int * 0x100000000000000000000 + b[11].value() as int * 0x10000000000000000000000 + b[12].value() as int * 0x1000000000000000000000000 + b[13].value() as int * 0x100000000000000000000000000 + b[14].value() as int * 0x10000000000000000000000000000 + b[15].value() as int * 0x1000000000000000000000000000000 + b[16].value() as int * 0x100000000000000000000000000000000 + b[17].value() as int * 0x10000000000000000000000000000000000 + b[18].value() as int * 0x1000000000000000000000000000000000000 + b[19].value() as int * 0x100000000000000000000000000000000000000 + b[20].value() as int * 0x10000000000000000000000000000000000000000 + b[21].value() as int * 0x1000000000000000000000000000000000000000000 + b[22].value() as int * 0x100000000000000000000000000000000000000000000 + b[23].value() as int * 0x10000000000000000000000000000000000000000000000 + b[24].value() as int * 0x1000000000000000000000000000000000000000000000000 + b[25].value() as int * 0x100000000000000000000000000000000000000000000000000 + b[26].value() as int * 0x10000000000000000000000000000000000000000000000000000 + b[27].value() as int * 0x1000000000000000000000000000000000000000000000000000000 + b[28].value() as int * 0x100000000000000000000000000000000000000000000000000000000 + b[29].value() as int * 0x10000000000000000000000000000000000000000000000000000000000 + b[30].value() as int * 0x1000000000000000000000000000000000000000000000000000000000000 + (b[31].value() & 0x7f) as int * 0x100000000000000000000000000000000000000000000000000000000000000 by {};
    return o;
}
// Limbs `f` each below their width: the value lies in [0, 2^255 - 1].
spec fn exact(f: [Secret<u64>; 10]) bool {
    return f[0].value() < 0x4000000 && f[1].value() < 0x2000000 && f[2].value() < 0x4000000 && f[3].value() < 0x2000000 && f[4].value() < 0x4000000 && f[5].value() < 0x2000000 && f[6].value() < 0x4000000 && f[7].value() < 0x2000000 && f[8].value() < 0x4000000 && f[9].value() < 0x2000000;
}

// 1 where the value of carried limbs `h` is at least p, else 0: the carry out of bit 255 of the value
// plus 19.
@constant_time
const fn quotient(h: [Secret<u64>; 10]) Secret<u64>
    requires carried(h)
    ensures |q| q.value() <= 1 && q.value() as int == 1 == val(h) >= p()
{
    let a0 = carry26(add(h[0], Secret::new(19u64)));
    let a1 = carry25(add(h[1], a0[1]));
    let a2 = carry26(add(h[2], a1[1]));
    let a3 = carry25(add(h[3], a2[1]));
    let a4 = carry26(add(h[4], a3[1]));
    let a5 = carry25(add(h[5], a4[1]));
    let a6 = carry26(add(h[6], a5[1]));
    let a7 = carry25(add(h[7], a6[1]));
    let a8 = carry26(add(h[8], a7[1]));
    let a9 = carry25(add(h[9], a8[1]));
    assert val(h) + 19 == a0[0].value() as int + a1[0].value() as int * 0x4000000 + a2[0].value() as int * 0x8000000000000 + a3[0].value() as int * 0x20000000000000000000 + a4[0].value() as int * 0x40000000000000000000000000 + a5[0].value() as int * 0x100000000000000000000000000000000 + a6[0].value() as int * 0x200000000000000000000000000000000000000 + a7[0].value() as int * 0x800000000000000000000000000000000000000000000 + a8[0].value() as int * 0x1000000000000000000000000000000000000000000000000000 + a9[0].value() as int * 0x4000000000000000000000000000000000000000000000000000000000 + 0x8000000000000000000000000000000000000000000000000000000000000000 * a9[1].value() as int by {};
    return a9[1];
}

// The limbs of the value of carried limbs `h` plus `19 q`, each below its width, and the carry out of
// bit 255.
@constant_time
const fn subtract(h: [Secret<u64>; 10], q: Secret<u64>) [Secret<u64>; 11]
    requires carried(h) && q.value() <= 1
    ensures |o| low(o) + 0x8000000000000000000000000000000000000000000000000000000000000000 * o[10].value() as int == val(
        h,
    ) + 19 * q.value() as int && exact_low(o)
{
    let b0 = carry26(add(h[0], times(q, 19)));
    let b1 = carry25(add(h[1], b0[1]));
    let b2 = carry26(add(h[2], b1[1]));
    let b3 = carry25(add(h[3], b2[1]));
    let b4 = carry26(add(h[4], b3[1]));
    let b5 = carry25(add(h[5], b4[1]));
    let b6 = carry26(add(h[6], b5[1]));
    let b7 = carry25(add(h[7], b6[1]));
    let b8 = carry26(add(h[8], b7[1]));
    let b9 = carry25(add(h[9], b8[1]));
    return [b0[0], b1[0], b2[0], b3[0], b4[0], b5[0], b6[0], b7[0], b8[0], b9[0], b9[1]];
}

// The value of limbs `o[0]` to `o[9]`.
spec fn low(o: [Secret<u64>; 11]) int {
    return o[0].value() as int + o[1].value() as int * 0x4000000 + o[2].value() as int * 0x8000000000000 + o[3].value() as int * 0x20000000000000000000 + o[4].value() as int * 0x40000000000000000000000000 + o[5].value() as int * 0x100000000000000000000000000000000 + o[6].value() as int * 0x200000000000000000000000000000000000000 + o[7].value() as int * 0x800000000000000000000000000000000000000000000 + o[8].value() as int * 0x1000000000000000000000000000000000000000000000000000 + o[9].value() as int * 0x4000000000000000000000000000000000000000000000000000000000;
}

// Limbs `o[0]` to `o[9]` each below their width.
spec fn exact_low(o: [Secret<u64>; 11]) bool {
    return o[0].value() < 0x4000000 && o[1].value() < 0x2000000 && o[2].value() < 0x4000000 && o[3].value() < 0x2000000 && o[4].value() < 0x4000000 && o[5].value() < 0x2000000 && o[6].value() < 0x4000000 && o[7].value() < 0x2000000 && o[8].value() < 0x4000000 && o[9].value() < 0x2000000;
}

// The carry out of bit 255 of `v + 19 q`, for `v` below 2^255 + 2^46 and `q` 1 where `v` is at least p,
// is `q`.
lemma top_carry(v: int, l: int, q: int, c: int)
    requires 0 <= q && q <= 1 && q == 1 == v >= p() && 0 <= l && l < 0x8000000000000000000000000000000000000000000000000000000000000000 && 0 <= c && v < 0x8000000000000000000000000000000000000000000000000000400000000000
    requires v + 19 * q == l + 0x8000000000000000000000000000000000000000000000000000000000000000 * c
    ensures c == q
{
    assert q != 1 || c == 1 by {};
    assert q == 1 || c == 0 by {};
}

// Limbs of the value of carried limbs `h` modulo p, each below its width.
@constant_time
fn freeze(h: [Secret<u64>; 10]) [Secret<u64>; 10]
    requires carried(h)
    ensures |o| val(o) == val(h) % p() && exact(o)
{
    let q = quotient(h);
    let r = subtract(h, q);
    let o = [r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9]];
    assert val(o) == low(r) && val(o) < 0x8000000000000000000000000000000000000000000000000000000000000000 && val(h) < 0x8000000000000000000000000000000000000000000000000000400000000000 by {};
    top_carry(val(h), val(o), q.value() as int, r[10].value() as int);
    assert val(o) == val(h) - q.value() as int * 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed by {};
    arith::mod_unique(val(h), q.value() as int, val(o), p());
    return o;
}

// The byte pieces of limb 0: bits 0 to 7, 8 to 15, 16 to 23, 24 to 25.
@constant_time
const fn pieces0(x: Secret<u64>) [Secret<u64>; 4]
    requires x.value() < 0x4000000
    ensures |o| x.value() as int == o[0].value() as int + o[1].value() as int * 0x100 + o[2].value() as int * 0x10000 + o[3].value() as int * 0x1000000
    ensures |o| o[0].value() < 0x100 && o[1].value() < 0x100 && o[2].value() < 0x100 && o[3].value() < 0x4
{
    assert x.value() >> 8 == x.value() / 0x100 by {};
    assert x.value() >> 16 == x.value() / 0x10000 by {};
    assert x.value() >> 24 == x.value() / 0x1000000 by {};
    assert (x.value() & 0xff) == x.value() % 0x100 by {};
    assert (x.value() >> 8 & 0xff) == x.value() / 0x100 % 0x100 by {};
    assert (x.value() >> 16 & 0xff) == x.value() / 0x10000 % 0x100 by {};
    assert x.value() / 1 == x.value() / 1 % 0x100 + 0x100 * (x.value() / 0x100) by {};
    assert x.value() / 0x100 == x.value() / 0x100 % 0x100 + 0x100 * (x.value() / 0x10000) by {};
    assert x.value() / 0x10000 == x.value() / 0x10000 % 0x100 + 0x100 * (x.value() / 0x1000000) by {};
    return [x & Secret::new(0xffu64), x >> 8 & Secret::new(0xffu64), x >> 16 & Secret::new(0xffu64), x >> 24];
}

// The byte pieces of limb 1: bits 0 to 5, 6 to 13, 14 to 21, 22 to 24.
@constant_time
const fn pieces1(x: Secret<u64>) [Secret<u64>; 4]
    requires x.value() < 0x2000000
    ensures |o| x.value() as int == o[0].value() as int + o[1].value() as int * 0x40 + o[2].value() as int * 0x4000 + o[3].value() as int * 0x400000
    ensures |o| o[0].value() < 0x40 && o[1].value() < 0x100 && o[2].value() < 0x100 && o[3].value() < 0x8
{
    assert x.value() >> 6 == x.value() / 0x40 by {};
    assert x.value() >> 14 == x.value() / 0x4000 by {};
    assert x.value() >> 22 == x.value() / 0x400000 by {};
    assert (x.value() & 0x3f) == x.value() % 0x40 by {};
    assert (x.value() >> 6 & 0xff) == x.value() / 0x40 % 0x100 by {};
    assert (x.value() >> 14 & 0xff) == x.value() / 0x4000 % 0x100 by {};
    assert x.value() / 1 == x.value() / 1 % 0x40 + 0x40 * (x.value() / 0x40) by {};
    assert x.value() / 0x40 == x.value() / 0x40 % 0x100 + 0x100 * (x.value() / 0x4000) by {};
    assert x.value() / 0x4000 == x.value() / 0x4000 % 0x100 + 0x100 * (x.value() / 0x400000) by {};
    return [x & Secret::new(0x3fu64), x >> 6 & Secret::new(0xffu64), x >> 14 & Secret::new(0xffu64), x >> 22];
}

// The byte pieces of limb 2: bits 0 to 4, 5 to 12, 13 to 20, 21 to 25.
@constant_time
const fn pieces2(x: Secret<u64>) [Secret<u64>; 4]
    requires x.value() < 0x4000000
    ensures |o| x.value() as int == o[0].value() as int + o[1].value() as int * 0x20 + o[2].value() as int * 0x2000 + o[3].value() as int * 0x200000
    ensures |o| o[0].value() < 0x20 && o[1].value() < 0x100 && o[2].value() < 0x100 && o[3].value() < 0x20
{
    assert x.value() >> 5 == x.value() / 0x20 by {};
    assert x.value() >> 13 == x.value() / 0x2000 by {};
    assert x.value() >> 21 == x.value() / 0x200000 by {};
    assert (x.value() & 0x1f) == x.value() % 0x20 by {};
    assert (x.value() >> 5 & 0xff) == x.value() / 0x20 % 0x100 by {};
    assert (x.value() >> 13 & 0xff) == x.value() / 0x2000 % 0x100 by {};
    assert x.value() / 1 == x.value() / 1 % 0x20 + 0x20 * (x.value() / 0x20) by {};
    assert x.value() / 0x20 == x.value() / 0x20 % 0x100 + 0x100 * (x.value() / 0x2000) by {};
    assert x.value() / 0x2000 == x.value() / 0x2000 % 0x100 + 0x100 * (x.value() / 0x200000) by {};
    return [x & Secret::new(0x1fu64), x >> 5 & Secret::new(0xffu64), x >> 13 & Secret::new(0xffu64), x >> 21];
}

// The byte pieces of limb 3: bits 0 to 2, 3 to 10, 11 to 18, 19 to 24.
@constant_time
const fn pieces3(x: Secret<u64>) [Secret<u64>; 4]
    requires x.value() < 0x2000000
    ensures |o| x.value() as int == o[0].value() as int + o[1].value() as int * 0x8 + o[2].value() as int * 0x800 + o[3].value() as int * 0x80000
    ensures |o| o[0].value() < 0x8 && o[1].value() < 0x100 && o[2].value() < 0x100 && o[3].value() < 0x40
{
    assert x.value() >> 3 == x.value() / 0x8 by {};
    assert x.value() >> 11 == x.value() / 0x800 by {};
    assert x.value() >> 19 == x.value() / 0x80000 by {};
    assert (x.value() & 0x7) == x.value() % 0x8 by {};
    assert (x.value() >> 3 & 0xff) == x.value() / 0x8 % 0x100 by {};
    assert (x.value() >> 11 & 0xff) == x.value() / 0x800 % 0x100 by {};
    assert x.value() / 1 == x.value() / 1 % 0x8 + 0x8 * (x.value() / 0x8) by {};
    assert x.value() / 0x8 == x.value() / 0x8 % 0x100 + 0x100 * (x.value() / 0x800) by {};
    assert x.value() / 0x800 == x.value() / 0x800 % 0x100 + 0x100 * (x.value() / 0x80000) by {};
    return [x & Secret::new(0x7u64), x >> 3 & Secret::new(0xffu64), x >> 11 & Secret::new(0xffu64), x >> 19];
}

// The byte pieces of limb 4: bits 0 to 1, 2 to 9, 10 to 17, 18 to 25.
@constant_time
const fn pieces4(x: Secret<u64>) [Secret<u64>; 4]
    requires x.value() < 0x4000000
    ensures |o| x.value() as int == o[0].value() as int + o[1].value() as int * 0x4 + o[2].value() as int * 0x400 + o[3].value() as int * 0x40000
    ensures |o| o[0].value() < 0x4 && o[1].value() < 0x100 && o[2].value() < 0x100 && o[3].value() < 0x100
{
    assert x.value() >> 2 == x.value() / 0x4 by {};
    assert x.value() >> 10 == x.value() / 0x400 by {};
    assert x.value() >> 18 == x.value() / 0x40000 by {};
    assert (x.value() & 0x3) == x.value() % 0x4 by {};
    assert (x.value() >> 2 & 0xff) == x.value() / 0x4 % 0x100 by {};
    assert (x.value() >> 10 & 0xff) == x.value() / 0x400 % 0x100 by {};
    assert x.value() / 1 == x.value() / 1 % 0x4 + 0x4 * (x.value() / 0x4) by {};
    assert x.value() / 0x4 == x.value() / 0x4 % 0x100 + 0x100 * (x.value() / 0x400) by {};
    assert x.value() / 0x400 == x.value() / 0x400 % 0x100 + 0x100 * (x.value() / 0x40000) by {};
    return [x & Secret::new(0x3u64), x >> 2 & Secret::new(0xffu64), x >> 10 & Secret::new(0xffu64), x >> 18];
}

// The byte pieces of limb 5: bits 0 to 7, 8 to 15, 16 to 23, 24 to 24.
@constant_time
const fn pieces5(x: Secret<u64>) [Secret<u64>; 4]
    requires x.value() < 0x2000000
    ensures |o| x.value() as int == o[0].value() as int + o[1].value() as int * 0x100 + o[2].value() as int * 0x10000 + o[3].value() as int * 0x1000000
    ensures |o| o[0].value() < 0x100 && o[1].value() < 0x100 && o[2].value() < 0x100 && o[3].value() < 0x2
{
    assert x.value() >> 8 == x.value() / 0x100 by {};
    assert x.value() >> 16 == x.value() / 0x10000 by {};
    assert x.value() >> 24 == x.value() / 0x1000000 by {};
    assert (x.value() & 0xff) == x.value() % 0x100 by {};
    assert (x.value() >> 8 & 0xff) == x.value() / 0x100 % 0x100 by {};
    assert (x.value() >> 16 & 0xff) == x.value() / 0x10000 % 0x100 by {};
    assert x.value() / 1 == x.value() / 1 % 0x100 + 0x100 * (x.value() / 0x100) by {};
    assert x.value() / 0x100 == x.value() / 0x100 % 0x100 + 0x100 * (x.value() / 0x10000) by {};
    assert x.value() / 0x10000 == x.value() / 0x10000 % 0x100 + 0x100 * (x.value() / 0x1000000) by {};
    return [x & Secret::new(0xffu64), x >> 8 & Secret::new(0xffu64), x >> 16 & Secret::new(0xffu64), x >> 24];
}

// The byte pieces of limb 6: bits 0 to 6, 7 to 14, 15 to 22, 23 to 25.
@constant_time
const fn pieces6(x: Secret<u64>) [Secret<u64>; 4]
    requires x.value() < 0x4000000
    ensures |o| x.value() as int == o[0].value() as int + o[1].value() as int * 0x80 + o[2].value() as int * 0x8000 + o[3].value() as int * 0x800000
    ensures |o| o[0].value() < 0x80 && o[1].value() < 0x100 && o[2].value() < 0x100 && o[3].value() < 0x8
{
    assert x.value() >> 7 == x.value() / 0x80 by {};
    assert x.value() >> 15 == x.value() / 0x8000 by {};
    assert x.value() >> 23 == x.value() / 0x800000 by {};
    assert (x.value() & 0x7f) == x.value() % 0x80 by {};
    assert (x.value() >> 7 & 0xff) == x.value() / 0x80 % 0x100 by {};
    assert (x.value() >> 15 & 0xff) == x.value() / 0x8000 % 0x100 by {};
    assert x.value() / 1 == x.value() / 1 % 0x80 + 0x80 * (x.value() / 0x80) by {};
    assert x.value() / 0x80 == x.value() / 0x80 % 0x100 + 0x100 * (x.value() / 0x8000) by {};
    assert x.value() / 0x8000 == x.value() / 0x8000 % 0x100 + 0x100 * (x.value() / 0x800000) by {};
    return [x & Secret::new(0x7fu64), x >> 7 & Secret::new(0xffu64), x >> 15 & Secret::new(0xffu64), x >> 23];
}

// The byte pieces of limb 7: bits 0 to 4, 5 to 12, 13 to 20, 21 to 24.
@constant_time
const fn pieces7(x: Secret<u64>) [Secret<u64>; 4]
    requires x.value() < 0x2000000
    ensures |o| x.value() as int == o[0].value() as int + o[1].value() as int * 0x20 + o[2].value() as int * 0x2000 + o[3].value() as int * 0x200000
    ensures |o| o[0].value() < 0x20 && o[1].value() < 0x100 && o[2].value() < 0x100 && o[3].value() < 0x10
{
    assert x.value() >> 5 == x.value() / 0x20 by {};
    assert x.value() >> 13 == x.value() / 0x2000 by {};
    assert x.value() >> 21 == x.value() / 0x200000 by {};
    assert (x.value() & 0x1f) == x.value() % 0x20 by {};
    assert (x.value() >> 5 & 0xff) == x.value() / 0x20 % 0x100 by {};
    assert (x.value() >> 13 & 0xff) == x.value() / 0x2000 % 0x100 by {};
    assert x.value() / 1 == x.value() / 1 % 0x20 + 0x20 * (x.value() / 0x20) by {};
    assert x.value() / 0x20 == x.value() / 0x20 % 0x100 + 0x100 * (x.value() / 0x2000) by {};
    assert x.value() / 0x2000 == x.value() / 0x2000 % 0x100 + 0x100 * (x.value() / 0x200000) by {};
    return [x & Secret::new(0x1fu64), x >> 5 & Secret::new(0xffu64), x >> 13 & Secret::new(0xffu64), x >> 21];
}

// The byte pieces of limb 8: bits 0 to 3, 4 to 11, 12 to 19, 20 to 25.
@constant_time
const fn pieces8(x: Secret<u64>) [Secret<u64>; 4]
    requires x.value() < 0x4000000
    ensures |o| x.value() as int == o[0].value() as int + o[1].value() as int * 0x10 + o[2].value() as int * 0x1000 + o[3].value() as int * 0x100000
    ensures |o| o[0].value() < 0x10 && o[1].value() < 0x100 && o[2].value() < 0x100 && o[3].value() < 0x40
{
    assert x.value() >> 4 == x.value() / 0x10 by {};
    assert x.value() >> 12 == x.value() / 0x1000 by {};
    assert x.value() >> 20 == x.value() / 0x100000 by {};
    assert (x.value() & 0xf) == x.value() % 0x10 by {};
    assert (x.value() >> 4 & 0xff) == x.value() / 0x10 % 0x100 by {};
    assert (x.value() >> 12 & 0xff) == x.value() / 0x1000 % 0x100 by {};
    assert x.value() / 1 == x.value() / 1 % 0x10 + 0x10 * (x.value() / 0x10) by {};
    assert x.value() / 0x10 == x.value() / 0x10 % 0x100 + 0x100 * (x.value() / 0x1000) by {};
    assert x.value() / 0x1000 == x.value() / 0x1000 % 0x100 + 0x100 * (x.value() / 0x100000) by {};
    return [x & Secret::new(0xfu64), x >> 4 & Secret::new(0xffu64), x >> 12 & Secret::new(0xffu64), x >> 20];
}

// The byte pieces of limb 9: bits 0 to 1, 2 to 9, 10 to 17, 18 to 24.
@constant_time
const fn pieces9(x: Secret<u64>) [Secret<u64>; 4]
    requires x.value() < 0x2000000
    ensures |o| x.value() as int == o[0].value() as int + o[1].value() as int * 0x4 + o[2].value() as int * 0x400 + o[3].value() as int * 0x40000
    ensures |o| o[0].value() < 0x4 && o[1].value() < 0x100 && o[2].value() < 0x100 && o[3].value() < 0x80
{
    assert x.value() >> 2 == x.value() / 0x4 by {};
    assert x.value() >> 10 == x.value() / 0x400 by {};
    assert x.value() >> 18 == x.value() / 0x40000 by {};
    assert (x.value() & 0x3) == x.value() % 0x4 by {};
    assert (x.value() >> 2 & 0xff) == x.value() / 0x4 % 0x100 by {};
    assert (x.value() >> 10 & 0xff) == x.value() / 0x400 % 0x100 by {};
    assert x.value() / 1 == x.value() / 1 % 0x4 + 0x4 * (x.value() / 0x4) by {};
    assert x.value() / 0x4 == x.value() / 0x4 % 0x100 + 0x100 * (x.value() / 0x400) by {};
    assert x.value() / 0x400 == x.value() / 0x400 % 0x100 + 0x100 * (x.value() / 0x40000) by {};
    return [x & Secret::new(0x3u64), x >> 2 & Secret::new(0xffu64), x >> 10 & Secret::new(0xffu64), x >> 18];
}

// `a + m * b`, below 2^64.
@constant_time
const fn join(a: Secret<u64>, b: Secret<u64>, m: u64) Secret<u64>
    requires a.value() as int + m as int * b.value() as int < 0x10000000000000000
    ensures |o| o.value() as int == a.value() as int + m as int * b.value() as int
{
    return a + b * Secret::new(m);
}

// `x` below 256 as a byte.
@constant_time
fn to_byte(x: Secret<u64>) Secret<u8>
    requires x.value() < 256
    ensures |o| o.value() as int == x.value() as int
{
    return x.cast::<u8>();
}

// The 32 little-endian bytes of the limbs `l`, each below its width.
@constant_time
fn encode(l: [Secret<u64>; 10]) [Secret<u8>; 32]
    requires exact(l)
    ensures |o| le_value(bytes(o)) == val(l)
{
    let p0 = pieces0(l[0]);
    let p1 = pieces1(l[1]);
    let p2 = pieces2(l[2]);
    let p3 = pieces3(l[3]);
    let p4 = pieces4(l[4]);
    let p5 = pieces5(l[5]);
    let p6 = pieces6(l[6]);
    let p7 = pieces7(l[7]);
    let p8 = pieces8(l[8]);
    let p9 = pieces9(l[9]);
    let o = [
        to_byte(p0[0]),
        to_byte(p0[1]),
        to_byte(p0[2]),
        to_byte(join(p0[3], p1[0], 0x4)),
        to_byte(p1[1]),
        to_byte(p1[2]),
        to_byte(join(p1[3], p2[0], 0x8)),
        to_byte(p2[1]),
        to_byte(p2[2]),
        to_byte(join(p2[3], p3[0], 0x20)),
        to_byte(p3[1]),
        to_byte(p3[2]),
        to_byte(join(p3[3], p4[0], 0x40)),
        to_byte(p4[1]),
        to_byte(p4[2]),
        to_byte(p4[3]),
        to_byte(p5[0]),
        to_byte(p5[1]),
        to_byte(p5[2]),
        to_byte(join(p5[3], p6[0], 0x2)),
        to_byte(p6[1]),
        to_byte(p6[2]),
        to_byte(join(p6[3], p7[0], 0x8)),
        to_byte(p7[1]),
        to_byte(p7[2]),
        to_byte(join(p7[3], p8[0], 0x10)),
        to_byte(p8[1]),
        to_byte(p8[2]),
        to_byte(join(p8[3], p9[0], 0x40)),
        to_byte(p9[1]),
        to_byte(p9[2]),
        to_byte(p9[3]),
    ];
    return o;
}

/// X25519 (RFC 7748, 5): the u-coordinate of the multiple of the point of u-coordinate `u` by the
/// scalar `k` decodes to, encoded as 32 little-endian bytes.
@constant_time
pub fn x25519(k: [Secret<u8>; 32], u: [Secret<u8>; 32]) [Secret<u8>; 32]
    ensures |o| le_value(bytes(o)) == scalar_mult(bytes(k), bytes(u))
{
    let x1 = decode(u);
    let r = ladder_ct(k, x1);
    let x = fe_mul(r[0], invert(r[1]));
    return encode(freeze(x));
}

/// The public key of private key `k` (RFC 7748, 6.1): `x25519(k, 9)`.
@constant_time
pub fn x25519_base(k: [Secret<u8>; 32]) [Secret<u8>; 32]
    ensures |o| le_value(bytes(o)) == scalar_mult(bytes(k), base_point())
{
    let z = Secret::new(0u8);
    let u = [
        Secret::new(9u8),
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
        z,
    ];
    assert bytes(u) == base_point() by {};
    return x25519(k, u);
}

/// The u-coordinate 9 of the base point, in 32 little-endian bytes.
pub spec fn base_point() [u8; 32] {
    return [9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
}
