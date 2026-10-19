// The constant generator of the wide float formats' functions (std/math/wide.spc): writes
// std/math/wide_consts.spc, the bits of pi/4, ln 2 and 2/pi after the binary point. Integer fixed-point
// arithmetic only (Machin's arctangent formula, the atanh series of ln 2, a Newton reciprocal), so every
// bit is exact and the output is the same on every host.
//
//   super-c release tools/wide_math && tools/wide_math/build/release/wide-math-gen [out-dir]
//
// `out-dir` defaults to std/math (run from the repository root).
import stdio;

// Fixed-point values are base-2^32 digits, digit 0 the integer part, the others the fraction.

// 64-bit limbs written of pi/4 and ln 2 (4096 bits) and of 2/pi (268800 bits: past f256's largest
// exponent, 2^18, by the reduction's working bits).
const SMALL_LIMBS: usize = 64;
const TOP_LIMBS: usize = 4200;
// Digits computed past the written ones: the truncation errors stay below their last bit.
const GUARD: usize = 4;

fn zeros(n: usize) Vector<u64> {
    let mut v = Vector::<u64>::with_capacity(n);
    for _ in 0..n {
        v.push(0);
    }
    return v;
}

// `a /= d` for `0 < d < 2^31`; the digits before `lead` are zero.
fn div_small(a: &mut Vector<u64>, d: u64, lead: usize) {
    let mut rem: u64 = 0;
    for i in lead..a.len() {
        let cur = rem << 32 | a[i];
        a[i] = cur / d;
        rem = cur % d;
    }
}

// `a *= k` for `k < 2^31`.
fn mul_small(a: &mut Vector<u64>, k: u64) {
    let mut carry: u64 = 0;
    let mut i = a.len();
    while i > 0 {
        i -= 1;
        let p = a[i] * k + carry;
        a[i] = p & 0xFFFFFFFF;
        carry = p >> 32;
    }
    assert(carry == 0, "gen: a fixed-point product overflows its integer digit");
}

// `a += b` (`sub`: `a -= b`, with `a >= b`); the digits of `b` before `lead` are zero.
fn add_from(a: &mut Vector<u64>, b: &Vector<u64>, lead: usize, sub: bool) {
    let mut c: u64 = 0;
    let mut i = a.len();
    while i > lead {
        i -= 1;
        if sub {
            let s = a[i] + 0x100000000 - b[i] - c;
            a[i] = s & 0xFFFFFFFF;
            c = 1 - (s >> 32);
        } else {
            let s = a[i] + b[i] + c;
            a[i] = s & 0xFFFFFFFF;
            c = s >> 32;
        }
    }
    while c != 0 && i > 0 {
        i -= 1;
        if sub {
            let s = a[i] + 0x100000000 - c;
            a[i] = s & 0xFFFFFFFF;
            c = 1 - (s >> 32);
        } else {
            let s = a[i] + c;
            a[i] = s & 0xFFFFFFFF;
            c = s >> 32;
        }
    }
    assert(c == 0, "gen: a fixed-point sum leaves its range");
}

// The sum over k of `s^k / ((2k + 1) x^(2k + 1))` to `n` digits, `s` -1 (`alternate`, atan(1/x)) or 1
// (atanh(1/x)), for `1 < x < 2^15`.
fn arc_series(n: usize, x: u64, alternate: bool) Vector<u64> {
    let mut sum = zeros(n);
    let mut p = zeros(n);
    p[0] = 1;
    div_small(&mut p, x, 0);
    let mut t = zeros(n);
    let mut lead: usize = 0;
    // Each term is below the last by x^2 >= 4: at most 16 terms per digit.
    for k in 0..(16 * n) as u64 {
        let old = lead;
        while lead < n && p[lead] == 0 {
            lead += 1;
        }
        if lead == n {
            return sum;
        }
        for i in old..lead {
            t[i] = 0;
        }
        for i in lead..n {
            t[i] = p[i];
        }
        div_small(&mut t, 2 * k + 1, lead);
        add_from(&mut sum, &t, lead, alternate && k % 2 == 1);
        div_small(&mut p, x * x, lead);
    }
    panic("gen: an arctangent series did not converge");
}

// `a * b` to `n` digits.
fn mul(a: &Vector<u64>, b: &Vector<u64>, n: usize) Vector<u64> {
    let mut lo = zeros(n + 1);
    let mut hi = zeros(n + 1);
    for i in 0..n {
        for j in 0..n - i {
            let p = a[i] * b[j];
            lo[i + j] += p & 0xFFFFFFFF;
            if i + j > 0 {
                hi[i + j - 1] += p >> 32;
            }
        }
    }
    let mut r = zeros(n);
    let mut c: u64 = 0;
    let mut k = n;
    while k > 0 {
        k -= 1;
        let s = lo[k] + hi[k] + c;
        r[k] = s & 0xFFFFFFFF;
        c = s >> 32;
    }
    assert(c == 0, "gen: a fixed-point product overflows its integer digit");
    return r;
}

// 1/v to `n` digits by Newton's iteration y <- y (2 - v y), each step doubling the correct digits, for
// `v` near pi.
fn reciprocal(v: &Vector<u64>, n: usize) Vector<u64> {
    let mut y = zeros(n);
    // 1/pi to 64 bits: 0x0.517cc1b727220a94.
    y[1] = 0x517cc1b7;
    y[2] = 0x27220a94;
    let mut nd: usize = 3;
    for _ in 0..64 {
        nd = if 2 * nd > n {
            n;
        } else {
            2 * nd;
        };
        let t = mul(v, &y, nd);
        let mut two = zeros(nd);
        two[0] = 2;
        add_from(&mut two, &t, 0, true);
        let y2 = mul(&y, &two, nd);
        for i in 0..nd {
            y[i] = y2[i];
        }
        if nd == n {
            // One more step at full precision for the last doubling's error.
            let t2 = mul(v, &y, n);
            let mut two2 = zeros(n);
            two2[0] = 2;
            add_from(&mut two2, &t2, 0, true);
            let y3 = mul(&y, &two2, n);
            return y3;
        }
    }
    panic("gen: the reciprocal did not converge");
}

// The fraction digits of `v` (digit 0 zero) as `limbs` 64-bit words, most significant first.
fn emit(out: &mut String, name: str, doc: str, v: &Vector<u64>, limbs: usize) {
    assert(v[0] == 0, "gen: a constant is not below 1");
    out.format_into(
        "\n/// {}: {} bits after the binary point, most significant first.\npub const {}: [u64; {}] = [\n",
        doc,
        limbs * 64,
        name,
        limbs,
    );
    for i in 0..limbs {
        let w = v[1 + 2 * i] << 32 | v[2 + 2 * i];
        out.push_str("    0x");
        let mut s = 60i64;
        while s >= 0 {
            let d = w >> s as u64 & 15;
            out.push_byte(
                if d < 10 {
                    (48 + d) as u8;
                } else {
                    (87 + d) as u8;
                },
            );
            s -= 4;
        }
        out.push_str(",\n");
    }
    out.push_str("];\n");
}

fn write(path: str, text: &String) {
    let f = stdio::fopen(path, "wb");
    assert(f != null, "gen: cannot open the output file");
    let n = unsafe stdio::fwrite(text.as_str().ptr(), 1, text.len(), f);
    assert(n == text.len() && unsafe stdio::fclose(f) == 0, "gen: cannot write the output file");
}

fn main(args: Vector<str>) i32 {
    let mut dir = "std/math";
    if args.len() > 1 {
        dir = args[1];
    }
    let n = 2 * TOP_LIMBS + 1 + GUARD;
    // pi = 16 atan(1/5) - 4 atan(1/239) (Machin).
    let mut pi = arc_series(n, 5, true);
    mul_small(&mut pi, 16);
    let mut b = arc_series(n, 239, true);
    mul_small(&mut b, 4);
    add_from(&mut pi, &b, 0, true);
    assert(pi[0] == 3 && pi[1] == 0x243f6a88, "gen: pi is wrong");
    // ln 2 = 2 atanh(1/3).
    let ns = 2 * SMALL_LIMBS + 1 + GUARD;
    let mut ln2 = arc_series(ns, 3, false);
    mul_small(&mut ln2, 2);
    assert(ln2[1] == 0xb17217f7, "gen: ln 2 is wrong");
    let mut two_over_pi = reciprocal(&pi, n);
    mul_small(&mut two_over_pi, 2);
    assert(two_over_pi[1] == 0xa2f9836e, "gen: 2/pi is wrong");
    // pi * (2/pi) is 2 to within the guard digits.
    let check = mul(&pi, &two_over_pi, n);
    let near_two = check[0] == 2 && check[n - GUARD] == 0 || check[0] == 1 && check[n - GUARD] == 0xFFFFFFFF;
    assert(near_two, "gen: 2/pi does not invert pi");
    let mut pi4 = pi;
    div_small(&mut pi4, 4, 0);
    let mut out = String::new();
    out.push_str(
        "// Generated by tools/wide_math/gen.spc: the bits of pi/4, ln 2 and 2/pi of the wide float formats'\n// functions (`wide.spc`). Do not edit; rerun the generator.\n",
    );
    emit(&mut out, "PI4_BITS", "pi/4", &pi4, SMALL_LIMBS);
    emit(&mut out, "LN2_BITS", "ln 2", &ln2, SMALL_LIMBS);
    emit(&mut out, "TWO_OVER_PI_BITS", "2/pi", &two_over_pi, TOP_LIMBS);
    let mut path = String::from_str(dir);
    path.push_str("/wide_consts.spc");
    write(path.as_str(), &out);
    return 0;
}
