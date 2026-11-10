// Lemmas of integer arithmetic over `int` and `nat`, for proofs: products, powers of two, division and
// remainders. Every build that imports the module proves them. `/` and `%` are the integer types'
// truncated division and remainder; the division lemmas state them for a dividend at least 0 and a
// divisor above 0, where they are the floor division and the least remainder.

/// `a * b == a * c` from `b == c`: a product of `a` with an expression in place of an equal term.
pub lemma mul_eq(a: int, b: int, c: int)
    requires b == c
    ensures a * b == a * c
{}

/// A product of two values at least 0 is at least 0.
pub lemma mul_nonneg(a: int, b: int)
    requires a >= 0
    requires b >= 0
    ensures a * b >= 0
    decreases a
{
    if a > 0 {
        mul_nonneg(a - 1, b);
    }
}

/// A product of two values above 0 is above 0.
pub lemma mul_pos(a: int, b: int)
    requires a > 0
    requires b > 0
    ensures a * b > 0
{
    mul_nonneg(a - 1, b);
}

/// A product keeps an order: `a <= b` gives `a * c <= b * c` for `c` at least 0.
pub lemma mul_le(a: int, b: int, c: int)
    requires a <= b
    requires c >= 0
    ensures a * c <= b * c
{
    mul_nonneg(b - a, c);
}

/// A product keeps a strict order: `a < b` gives `a * c < b * c` for `c` above 0.
pub lemma mul_lt(a: int, b: int, c: int)
    requires a < b
    requires c > 0
    ensures a * c < b * c
{
    mul_pos(b - a, c);
}

/// 2 to the power `n`.
pub spec fn pow2(n: nat) nat
    decreases n
{
    return if n == 0 {
        1
    } else {
        2 * pow2(n - 1)
    };
}

pub lemma pow2_pos(n: nat)
    ensures pow2(n) > 0
    decreases n
{
    if n > 0 {
        pow2_pos(n - 1);
    }
}

pub lemma pow2_add(a: nat, b: nat)
    ensures pow2(a + b) == pow2(a) * pow2(b)
    decreases b
{
    if b > 0 {
        pow2_add(a, b - 1);
        mul_eq(pow2(a), pow2(b), 2 * pow2(b - 1));
    }
}

pub lemma pow2_le(a: nat, b: nat)
    requires a <= b
    ensures pow2(a) <= pow2(b)
    decreases b
{
    if a < b {
        pow2_le(a, b - 1);
    }
}

/// `x` is its quotient by `m` times `m` plus its remainder, which lies in [0, m - 1].
pub lemma div_mod(x: int, m: int)
    requires x >= 0
    requires m > 0
    ensures x == x / m * m + x % m
    ensures 0 <= x % m
    ensures x % m < m
{}

/// The quotient and the remainder are the only `q` and `r` with `x == q * m + r` and `r` in [0, m - 1].
pub lemma mod_unique(x: int, q: int, r: int, m: int)
    requires x >= 0
    requires m > 0
    requires 0 <= r
    requires r < m
    requires x == q * m + r
    ensures x / m == q
    ensures x % m == r
{
    div_mod(x, m);
    if q > x / m {
        mul_le(x / m + 1, q, m);
    } else if q < x / m {
        mul_le(q + 1, x / m, m);
    }
}

pub lemma mod_mod(x: int, m: int)
    requires x >= 0
    requires m > 0
    ensures x % m % m == x % m
{
    div_mod(x, m);
    mod_unique(x % m, 0, x % m, m);
}

pub lemma mod_add_multiple(x: int, k: int, m: int)
    requires x >= 0
    requires k >= 0
    requires m > 0
    ensures (x + k * m) % m == x % m
{
    div_mod(x, m);
    mul_nonneg(k, m);
    mod_unique(x + k * m, x / m + k, x % m, m);
}

pub lemma mod_add(a: int, b: int, m: int)
    requires a >= 0
    requires b >= 0
    requires m > 0
    ensures (a + b) % m == (a % m + b % m) % m
{
    div_mod(a, m);
    div_mod(b, m);
    div_mod(a % m + b % m, m);
    mod_unique(a + b, a / m + b / m + (a % m + b % m) / m, (a % m + b % m) % m, m);
}

pub lemma mod_mul(a: int, b: int, m: int)
    requires a >= 0
    requires b >= 0
    requires m > 0
    ensures a * b % m == a % m * (b % m) % m
{
    div_mod(a, m);
    div_mod(b, m);
    let ra = a % m;
    let rb = b % m;
    let qa = a / m;
    let qb = b / m;
    mul_eq(a, b, qb * m + rb);
    mul_eq(qb * m, a, qa * m + ra);
    mul_eq(rb, a, qa * m + ra);
    mul_nonneg(ra, rb);
    div_mod(ra * rb, m);
    mul_nonneg(a, b);
    mod_unique(a * b, qa * qb * m + qb * ra + qa * rb + ra * rb / m, ra * rb % m, m);
}
