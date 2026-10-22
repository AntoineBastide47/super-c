#!/usr/bin/env python3
# Generates ffi/immintrin.spc and std/simd/backend/x86_64.spc from the families below and GCC's
# <immintrin.h> prototypes (build/x86gen/protos.json, from protos.py). Run from the repository root:
#
#   python3 scripts/x86gen/protos.py && python3 scripts/x86gen/gen.py
#   ./super-c fmt std/simd/backend/x86_64.spc ffi/immintrin.spc
#
# The binding holds the intrinsics the backend and std/simd/x86.spc call. The AVX10.2 prototypes, which
# GCC 13 lacks, are added by hand (GCC 15's).
import os
import re

BITS = {'i8': 8, 'u8': 8, 'i16': 16, 'u16': 16, 'i32': 32, 'u32': 32, 'i64': 64, 'u64': 64, 'f32': 32, 'f64': 64}
INTS = ['i8', 'u8', 'i16', 'u16', 'i32', 'u32', 'i64', 'u64']
FLTS = ['f32', 'f64']
UNS = {8: 'u8', 16: 'u16', 32: 'u32', 64: 'u64'}
EPI = {8: 'epi8', 16: 'epi16', 32: 'epi32', 64: 'epi64'}
EPU = {8: 'epu8', 16: 'epu16', 32: 'epu32', 64: 'epu64'}


def sg(t):
    return t[0] == 'i'


def isf(t):
    return t[0] == 'f'


class W:
    def __init__(self, bits, p, h, si, fi, ff):
        self.bits, self.p, self.h, self.si, self.fi, self.ff = bits, p, h, si, fi, ff
        self.I = {128: '__m128i', 256: '__m256i', 512: '__m512i'}[bits]
        self.F = {128: '__m128', 256: '__m256', 512: '__m512'}[bits]
        self.D = {128: '__m128d', 256: '__m256d', 512: '__m512d'}[bits]

    def reg(self, t):
        return self.F if t == 'f32' else self.D if t == 'f64' else self.I

    def n(self, t):
        return self.bits // BITS[t]

    def ld(self, t):  # vector -> register helper
        return self.h + ('f' if t == 'f32' else 'd' if t == 'f64' else 'i')

    def st(self, t):  # register -> vector helper, applied with its turbofish
        return f'{self.ld(t)}v::<{t}, {self.n(t)}>'

    def ps(self, t):
        return 'ps' if t == 'f32' else 'pd'

    def ib(self, t):
        """The base feature of integer lanes of `t` at this width."""
        if self.bits == 512 and BITS[t] <= 16:
            return 'Avx512bw'
        return self.fi


W128 = W(128, '_mm', 'x', 'si128', 'Sse2', 'Sse2')
W256 = W(256, '_mm256', 'y', 'si256', 'Avx2', 'Avx')
W512 = W(512, '_mm512', 'z', 'si512', 'Avx512f', 'Avx512f')
WS = [W128, W256, W512]

# ---------------------------------------------------------------------------------------------
# Intrinsic signatures: name -> (ret, [(type, name)], [features], mem). `sig` records one.
# ---------------------------------------------------------------------------------------------
SIGS = {}


def sig(name, ret, params, fs, mem=''):
    ps = []
    for p in params.split(',') if params else []:
        t, n = p.strip().rsplit(' ', 1)
        ps.append((t, n))
    if name in SIGS:
        return
    SIGS[name] = (ret, ps, fs, mem)


def wsigs(w):
    """The signatures every width has, under its own prefix and feature names."""
    P, I, F, D = w.p, w.I, w.F, w.D
    b, fb = w.bits, w.bits // 8
    vi = w.fi
    vf = w.ff
    bw = 'Avx512bw' if b == 512 else vi
    s = sig
    s(f'{P}_loadu_{w.si}', I, 'p *const void', [vf if b == 256 else vi], f'reads p {fb}')
    s(f'{P}_storeu_{w.si}', 'void', f'p *mut void, a {I}', [vf if b == 256 else vi], f'writes p {fb}')
    for k, R in (('ps', F), ('pd', D)):
        s(f'{P}_loadu_{k}', R, 'p *const void', [vf], f'reads p {fb}')
        s(f'{P}_storeu_{k}', 'void', f'p *mut void, a {R}', [vf], f'writes p {fb}')
        for op in ('add', 'sub', 'mul', 'div', 'min', 'max'):
            s(f'{P}_{op}_{k}', R, f'a {R}, b {R}', [vf])
        s(f'{P}_sqrt_{k}', R, f'a {R}', [vf])
        s(f'{P}_set1_{k}', R, f'a {"f32" if k == "ps" else "f64"}', [vf])
        s(f'{P}_setzero_{k}', R, '', [vf])
        s(f'{P}_fmadd_{k}', R, f'a {R}, b {R}, c {R}', ['Fma' if b < 512 else vf])
        if b < 512:
            for op in ('and', 'andnot', 'or', 'xor'):
                s(f'{P}_{op}_{k}', R, f'a {R}, b {R}', [vf])
            s(f'{P}_movemask_{k}', 'i32', f'a {R}', [vf])
            s(f'{P}_blendv_{k}', R, f'a {R}, b {R}, m {R}', ['Sse41' if b == 128 else vf])
            s(f'{P}_round_{k}', R, f'a {R}, imm i32', ['Sse41' if b == 128 else vf])
        else:
            s(f'{P}_roundscale_{k}', R, f'a {R}, imm i32', [vf])
            s(f'{P}_cmp_{k}_mask', 'u16' if k == 'ps' else 'u8', f'a {R}, b {R}, imm i32', [vf])
            s(f'{P}_mask_blend_{k}', R, f'k {"u16" if k == "ps" else "u8"}, a {R}, b {R}', [vf])
        s(f'{P}_cast{k}_{w.si}', I, f'a {R}', [vf])
        s(f'{P}_cast{w.si}_{k}', R, f'a {I}', [vf])
    for op in ('and', 'or', 'xor', 'andnot'):
        s(f'{P}_{op}_{w.si}', I, f'a {I}, b {I}', [vi])
    s(f'{P}_setzero_{w.si}', I, '', [vf if b == 256 else vi])
    for e, sc in ((8, 'i8'), (16, 'i16'), (32, 'i32'), (64, 'i64')):
        ex = 'epi64x' if e == 64 and b < 512 else EPI[e]
        s(f'{P}_set1_{ex}', I, f'a {sc}', [vf if b == 256 else vi])
        ff = bw if e <= 16 else vi
        s(f'{P}_add_{EPI[e]}', I, f'a {I}, b {I}', [ff])
        s(f'{P}_sub_{EPI[e]}', I, f'a {I}, b {I}', [ff])
    return


# ---------------------------------------------------------------------------------------------
# Entries
# ---------------------------------------------------------------------------------------------
OUT = []
NAMES = set()


def entry(op, fs, name, params, ret, body):
    """One `@simd_impl` function; `body` lines without indentation."""
    r = '' if ret == '' else f' {ret}'
    name = re.sub(r'Simd<(\w+), (\d+)>', r'\1x\2', name)
    if name in NAMES:
        name += '_' + fs[-1].lower()
    NAMES.add(name)
    lines = '\n'.join('    ' + l if l else '' for l in body.split('\n'))
    OUT.append(f'@arch(x86_64)\n@simd_impl(simd::Op::{op}, [{", ".join("cpu::Feature::" + f for f in fs)}])\n'
               f'fn {name}({params}){r} {{\n{lines}\n}}\n')


PROTOS = __import__('json').load(open(os.path.join('build', 'x86gen', 'protos.json')))
PTR = {'__m128i_u': '__m128i_u', '__m256i_u': '__m256i_u', 'float': 'f32', 'double': 'f64', 'int': 'i32',
       'long long': 'void', 'long long int': 'void', 'void': 'void'}


def ptr_type(ctype):
    """The Super-C pointer type of C pointer type `ctype` (`float const *`)."""
    base = ctype.replace('*', '').replace('const', '').strip()
    return ('*const ' if 'const' in ctype else '*mut ') + PTR[base]


def pc(intr, expr, have):
    """Pointer argument `expr`, of type `have`, as the pointer parameter of intrinsic `intr` takes it."""
    for prm in PROTOS[intr]['params'].split(','):
        ty = re.sub(r'\s*\b__\w+$', '', prm.strip()).strip()
        if '*' in ty:
            want = ptr_type(ty)
            if 'long long' in ty:
                return f'vc({expr})' if 'const' in ty else f'vm({expr})'
            return expr if (want == have or want.endswith(' void')) else f'{expr} as {want}'
    raise Exception(intr)


def pr(intr, mut):
    """`&x` (`&mut x`), a vector local, as the pointer parameter of intrinsic `intr` takes it."""
    have = '*mut Simd<T, N>' if mut else '*const Simd<T, N>'
    ref = '&mut x' if mut else '&x'
    p = pc(intr, ref, have)
    return p if p == ref else f'({ref}) as {have} as {p.split(" as ", 1)[1]}'


def cv(x, t, src):
    """`x` (of type `src`) as `t`."""
    return x if t == src else f'{x} as {t}'


def mc(mi):
    """Mask `m` as the intrinsic's mask integer `mi`."""
    return 'm as u64' if mi == 'u64' else f'm as u64 as {mi}'


def B(t, n):
    """The vector type: its alias from 128 bits, else `Simd<T, N>`."""
    return f'{t}x{n}' if BITS[t] * n >= 128 else f'Simd<{t}, {n}>'


# ---- Load / Store ---------------------------------------------------------------------------
def fam_load_store():
    for w in WS:
        for t in INTS + FLTS:
            n = w.n(t)
            k = 'ps' if t == 'f32' else 'pd' if t == 'f64' else w.si
            f = w.fi if w.bits != 256 else 'Avx'
            if isf(t):
                f = w.ff
            ld, sto = f'{w.p}_loadu_{k}', f'{w.p}_storeu_{k}'
            entry('Load', [f], f'load_{B(t, n)}', f'p: *const {t}', B(t, n),
                  f'return {w.st(t)}(unsafe {ld}({pc(ld, "p", "*const " + t)}));')
            entry('Store', [f], f'store_{B(t, n)}', f'p: *mut {t}, v: {B(t, n)}', '',
                  f'unsafe {sto}({pc(sto, "p", "*mut " + t)}, {w.ld(t)}(v));')


# ---- Integer lane-wise arithmetic and bits --------------------------------------------------
def fam_int_basic():
    for w in WS:
        P = w.p
        for t in INTS:
            n, e = w.n(t), BITS[t]
            V = B(t, n)
            f = w.ib(t)
            a, b = f'{w.ld(t)}(a)', f'{w.ld(t)}(b)'
            st = w.st(t)
            entry('WrappingAdd', [f], f'wrapping_add_{V}', f'a: {V}, b: {V}', V, f'return {st}({P}_add_{EPI[e]}({a}, {b}));')
            entry('WrappingSub', [f], f'wrapping_sub_{V}', f'a: {V}, b: {V}', V, f'return {st}({P}_sub_{EPI[e]}({a}, {b}));')
            entry('WrappingNeg', [f], f'wrapping_neg_{V}', f'a: {V}', V, f'return {st}({P}_sub_{EPI[e]}({P}_setzero_{w.si}(), {a}));')
            g = w.fi
            entry('And', [g], f'and_{V}', f'a: {V}, b: {V}', V, f'return {st}({P}_and_{w.si}({a}, {b}));')
            entry('Or', [g], f'or_{V}', f'a: {V}, b: {V}', V, f'return {st}({P}_or_{w.si}({a}, {b}));')
            entry('Xor', [g], f'xor_{V}', f'a: {V}, b: {V}', V, f'return {st}({P}_xor_{w.si}({a}, {b}));')
            entry('Not', [g], f'not_{V}', f'a: {V}', V, f'return {st}({P}_xor_{w.si}({a}, {P}_set1_epi32(-1)));')


def w_only(*bits):
    return [w for w in WS if w.bits in bits]


# ---- Integer multiply -----------------------------------------------------------------------
def fam_int_mul():
    for w in WS:
        P = w.p
        for t in INTS:
            n, e = w.n(t), BITS[t]
            V = B(t, n)
            a, b, st = f'{w.ld(t)}(a)', f'{w.ld(t)}(b)', w.st(t)
            if e == 16:
                entry('WrappingMul', [w.ib(t)], f'wrapping_mul_{V}', f'a: {V}, b: {V}', V, f'return {st}({P}_mullo_epi16({a}, {b}));')
            elif e == 32:
                entry('WrappingMul', ['Sse41' if w.bits == 128 else w.fi], f'wrapping_mul_{V}', f'a: {V}, b: {V}', V,
                      f'return {st}({P}_mullo_epi32({a}, {b}));')
                if w.bits == 128:
                    # Two `pmuludq` over the even and the odd lanes; their low halves interleaved.
                    entry('WrappingMul', ['Sse2'], f'wrapping_mul_{V}', f'a: {V}, b: {V}', V,
                          f'let x = {a};\nlet y = {b};\n'
                          f'let ev = _mm_mul_epu32(x, y);\n'
                          f'let od = _mm_mul_epu32(_mm_srli_epi64(x, 32), _mm_srli_epi64(y, 32));\n'
                          f'return {st}(_mm_unpacklo_epi32(_mm_shuffle_epi32(ev, 8), _mm_shuffle_epi32(od, 8)));')
            elif e == 64:
                if w.bits == 512:
                    entry('WrappingMul', ['Avx512dq'], f'wrapping_mul_{V}', f'a: {V}, b: {V}', V, f'return {st}({P}_mullo_epi64({a}, {b}));')
                else:
                    entry('WrappingMul', ['Avx512dq', 'Avx512vl'], f'wrapping_mul_{V}', f'a: {V}, b: {V}', V, f'return {st}({P}_mullo_epi64({a}, {b}));')
                # The 32-bit partial products: lo(a) * lo(b) + (hi(a) * lo(b) + lo(a) * hi(b)) << 32.
                entry('WrappingMul', [w.fi], f'wrapping_mul_{V}', f'a: {V}, b: {V}', V,
                      f'let x = {a};\nlet y = {b};\n'
                      f'let lo = {P}_mul_epu32(x, y);\n'
                      f'let c = {P}_add_epi64({P}_mul_epu32({P}_srli_epi64(x, 32), y), {P}_mul_epu32(x, {P}_srli_epi64(y, 32)));\n'
                      f'return {st}({P}_add_epi64(lo, {P}_slli_epi64(c, 32)));')
            else:
                # Bytes: the 16-bit products of the even and of the odd bytes, their low bytes.
                entry('WrappingMul', [w.ib(t)], f'wrapping_mul_{V}', f'a: {V}, b: {V}', V,
                      f'let x = {a};\nlet y = {b};\n'
                      f'let ev = {P}_and_{w.si}({P}_mullo_epi16(x, y), {P}_set1_epi16(255));\n'
                      f'let od = {P}_slli_epi16({P}_mullo_epi16({P}_srli_epi16(x, 8), {P}_srli_epi16(y, 8)), 8);\n'
                      f'return {st}({P}_or_{w.si}(ev, od));')


# ---- Float arithmetic -----------------------------------------------------------------------
def fam_float():
    for w in WS:
        P = w.p
        for t in FLTS:
            n = w.n(t)
            V = B(t, n)
            k = w.ps(t)
            f = w.ff
            a, b, c, st = f'{w.ld(t)}(a)', f'{w.ld(t)}(b)', f'{w.ld(t)}(c)', w.st(t)
            for op, nm in (('Add', 'add'), ('Sub', 'sub'), ('Mul', 'mul'), ('Div', 'div')):
                entry(op, [f], f'{nm}_{V}', f'a: {V}, b: {V}', V, f'return {st}({P}_{nm}_{k}({a}, {b}));')
            entry('Sqrt', [f], f'sqrt_{V}', f'a: {V}', V, f'return {st}({P}_sqrt_{k}({a}));')
            entry('Fma', ['Fma'] if w.bits < 512 else [f], f'fma_{V}', f'a: {V}, b: {V}, c: {V}', V,
                  f'return {st}({P}_fmadd_{k}({a}, {b}, {c}));')
            # The sign bit alone: `-`, `abs` and `copysign` keep every other bit.
            if w.bits < 512:
                z = f'{P}_set1_{k}(-0.0)'
                entry('Neg', [f], f'neg_{V}', f'a: {V}', V, f'return {st}({P}_xor_{k}({a}, {z}));')
                entry('Abs', [f], f'abs_{V}', f'a: {V}', V, f'return {st}({P}_andnot_{k}({z}, {a}));')
                entry('Copysign', [f], f'copysign_{V}', f'a: {V}, b: {V}', V,
                      f'let s = {z};\nreturn {st}({P}_or_{k}({P}_andnot_{k}(s, {a}), {P}_and_{k}(s, {b})));')
            else:
                sb = f'{P}_set1_epi{"32" if t == "f32" else "64"}({"-2147483648" if t == "f32" else "-9223372036854775807 - 1"})'
                ai, bi = f'{P}_cast{k}_{w.si}({a})', f'{P}_cast{k}_{w.si}({b})'
                entry('Neg', [f], f'neg_{V}', f'a: {V}', V, f'return {st}({P}_cast{w.si}_{k}({P}_xor_{w.si}({ai}, {sb})));')
                entry('Abs', [f], f'abs_{V}', f'a: {V}', V, f'return {st}({P}_cast{w.si}_{k}({P}_andnot_{w.si}({sb}, {ai})));')
                entry('Copysign', [f], f'copysign_{V}', f'a: {V}, b: {V}', V,
                      f'let s = {sb};\n'
                      f'return {st}({P}_cast{w.si}_{k}({P}_or_{w.si}({P}_andnot_{w.si}(s, {ai}), {P}_and_{w.si}(s, {bi}))));')
            # Rounding: to nearest even, toward -inf, +inf and zero, without the inexact exception.
            for op, nm, imm in (('RoundEven', 'round_even', 8), ('Floor', 'floor', 9), ('Ceil', 'ceil', 10), ('Trunc', 'trunc', 11)):
                if w.bits == 512:
                    entry(op, [f], f'{nm}_{V}', f'a: {V}', V, f'return {st}({P}_roundscale_{k}({a}, {imm}));')
                else:
                    entry(op, ['Sse41'] if w.bits == 128 else [f], f'{nm}_{V}', f'a: {V}', V, f'return {st}({P}_round_{k}({a}, {imm}));')


# ---- Integer min, max, abs, saturating, abs_diff ----------------------------------------------
def minmax_expr(w, t, op, x, y):
    """`op` ('min'/'max') of registers `x`, `y` of lanes `t` and the features it needs; None when the
    width has no sequence."""
    P, e = w.p, BITS[t]
    u = 'epu' if not sg(t) else 'epi'
    if w.bits == 512:
        return f'{P}_{op}_{u}{e}({x}, {y})', [w.ib(t)]
    if e == 64:
        return f'{P}_{op}_{u}64({x}, {y})', ['Avx512f', 'Avx512vl']
    if w.bits == 256:
        return f'{P}_{op}_{u}{e}({x}, {y})', ['Avx2']
    if (t in ('u8', 'i16')):
        return f'{P}_{op}_{u}{e}({x}, {y})', ['Sse2']
    return f'{P}_{op}_{u}{e}({x}, {y})', ['Sse41']


def gt_expr(w, t, x, y):
    """Lanes of all ones where `x > y` (signed or unsigned by `t`), at 128 or 256 bits, and the
    features; the unsigned order flips the sign bits first."""
    P, e = w.p, BITS[t]
    f = ['Sse42'] if (w.bits == 128 and e == 64) else [w.fi]
    if sg(t):
        return f'{P}_cmpgt_epi{e}({x}, {y})', f
    sbit = {8: f'{P}_set1_epi8(-128)', 16: f'{P}_set1_epi16(-32768)', 32: f'{P}_set1_epi32(-2147483648)',
            64: f'{P}_set1_epi64x(-9223372036854775807 - 1)'}[e]
    return f'{P}_cmpgt_epi{e}({P}_xor_{w.si}({x}, {sbit}), {P}_xor_{w.si}({y}, {sbit}))', f


def blend(w, m, x, y):
    """Lanes of `x` where mask lanes `m` are all ones, else of `y` (and, andnot, or)."""
    P = w.p
    return f'{P}_or_{w.si}({P}_and_{w.si}({m}, {x}), {P}_andnot_{w.si}({m}, {y}))'


def fam_int_minmax():
    for w in WS:
        P = w.p
        for t in INTS:
            n, e = w.n(t), BITS[t]
            V = B(t, n)
            a, b, st = f'{w.ld(t)}(a)', f'{w.ld(t)}(b)', w.st(t)
            for op, nm in (('Min', 'min'), ('Max', 'max')):
                ex, f = minmax_expr(w, t, nm, a, b)
                entry(op, f, f'{nm}_{V}', f'a: {V}, b: {V}', V, f'return {st}({ex});')
                if w.bits == 128 and t not in ('u8', 'i16') or w.bits == 256 and e == 64:
                    # A comparison and a blend.
                    if w.bits == 128 and e == 64:
                        gf = ['Sse42']
                    else:
                        gf = [w.fi]
                    if w.bits == 128 and t == 'u16':
                        # min(a, b) = a - (a -sat b); max(a, b) = b + (a -sat b).
                        body = (f'let x = {a};\nlet d = {P}_subs_epu16(x, {b});\n'
                                + (f'return {st}({P}_sub_epi16(x, d));' if nm == 'min' else f'return {st}({P}_add_epi16({b}, d));'))
                        entry(op, ['Sse2'], f'{nm}_{V}', f'a: {V}, b: {V}', V, body)
                    elif e < 64 or w.bits == 256 or w.bits == 128:
                        g, gf = gt_expr(w, t, 'x', 'y')
                        pick = blend(w, 'g', 'y', 'x') if nm == 'min' else blend(w, 'g', 'x', 'y')
                        entry(op, gf, f'{nm}_{V}', f'a: {V}, b: {V}', V, f'let x = {a};\nlet y = {b};\nlet g = {g};\nreturn {st}({pick});')
            if sg(t):
                # GCC's `abs_epi8` casts to plain `char` lanes and folds to an unsigned abs, a no-op,
                # under `-funsigned-char` (every build passes it): `sign_epi8(a, a)`, and on 512 bits
                # the unsigned minimum of `a` and `-a`, give the same lanes.
                ab = f'return {st}({P}_abs_epi{e}({a}));'
                if e == 8:
                    ab = (f'let x = {a};\nreturn {st}(' + (f'{P}_min_epu8(x, {P}_sub_epi8({P}_setzero_si512(), x))'
                          if w.bits == 512 else f'{P}_sign_epi8(x, x)') + ');')
                if w.bits == 512 or e == 64:
                    f = [w.ib(t)] if w.bits == 512 else ['Avx512f', 'Avx512vl']
                    entry('WrappingAbs', f, f'wrapping_abs_{V}', f'a: {V}', V, ab)
                else:
                    entry('WrappingAbs', ['Ssse3'] if w.bits == 128 else ['Avx2'], f'wrapping_abs_{V}', f'a: {V}', V, ab)
                    if w.bits == 128:
                        # (a ^ s) - s with s the lanes' sign: all ones for a negative lane.
                        s = f'{P}_cmpgt_epi8({P}_setzero_si128(), x)' if e == 8 else f'{P}_srai_epi{e}(x, {e - 1})'
                        entry('WrappingAbs', ['Sse2'], f'wrapping_abs_{V}', f'a: {V}', V,
                              f'let x = {a};\nlet s = {s};\nreturn {st}({P}_sub_epi{e}({P}_xor_si128(x, s), s));')
            if e <= 16:
                u = 'epi' if sg(t) else 'epu'
                f = [w.ib(t)]
                entry('SaturatingAdd', f, f'saturating_add_{V}', f'a: {V}, b: {V}', V, f'return {st}({P}_adds_{u}{e}({a}, {b}));')
                entry('SaturatingSub', f, f'saturating_sub_{V}', f'a: {V}, b: {V}', V, f'return {st}({P}_subs_{u}{e}({a}, {b}));')
            # |a - b| exact in the unsigned type of the width: max - min, wrapping.
            ux = UNS[e]
            mn, f1 = minmax_expr(w, t, 'min', 'x', 'y')
            mx, _ = minmax_expr(w, t, 'max', 'x', 'y')
            entry('AbsDiff', f1, f'abs_diff_{V}', f'a: {V}, b: {V}', B(ux, n),
                  f'let x = {a};\nlet y = {b};\nreturn {w.h}iv::<{ux}, {n}>({P}_sub_epi{e}({mx}, {mn}));')


# ---- Comparisons, choose, lane masks ---------------------------------------------------------
# The float predicates of `_mm256_cmp_ps` and `_mm512_cmp_ps_mask`: ordered and quiet, but `!=`,
# which a NaN makes true.
FCMP = {'eq': 0, 'ne': 4, 'lt': 17, 'le': 18, 'gt': 30, 'ge': 29}
# The integer predicates of `_mm512_cmp_epi32_mask` (`_MM_CMPINT_*`).
ICMP = {'eq': 0, 'ne': 4, 'lt': 1, 'le': 2, 'gt': 6, 'ge': 5}
CMPS = [('eq', 'Eq'), ('ne', 'Ne'), ('lt', 'Lt'), ('le', 'Le'), ('gt', 'Gt'), ('ge', 'Ge')]


def fam_compare():
    for w in WS:
        P = w.p
        for t in INTS + FLTS:
            n, e = w.n(t), BITS[t]
            V = B(t, n)
            ux = UNS[e]
            U = B(ux, n)
            a, b = f'{w.ld(t)}(a)', f'{w.ld(t)}(b)'
            mk = {2: 'mask2', 4: 'mask4', 8: 'mask8', 16: 'mask16', 32: 'mask32', 64: 'mask64'}[n]
            if w.bits < 512:
                # Lane masks: all ones where the comparison holds.
                for c, C in CMPS:
                    if isf(t):
                        k = w.ps(t)
                        if w.bits == 128:
                            ex = {'eq': f'{P}_cmpeq_{k}(x, y)', 'ne': f'{P}_cmpneq_{k}(x, y)', 'lt': f'{P}_cmplt_{k}(x, y)',
                                  'le': f'{P}_cmple_{k}(x, y)', 'gt': f'{P}_cmplt_{k}(y, x)', 'ge': f'{P}_cmple_{k}(y, x)'}[c]
                        else:
                            ex = f'{P}_cmp_{k}(x, y, {FCMP[c]})'
                        entry(f'Cmp{C}Lanes', [w.ff], f'cmp_{c}_lanes_{V}', f'a: {V}, b: {V}', U,
                              f'let x = {a};\nlet y = {b};\nreturn {w.h}iv::<{ux}, {n}>({P}_cast{k}_{w.si}({ex}));')
                    else:
                        eqf = ['Sse41'] if (w.bits == 128 and e == 64) else [w.fi]
                        eq = f'{P}_cmpeq_epi{e}(x, y)'
                        gt, gf = gt_expr(w, t, 'x', 'y')
                        lt, _ = gt_expr(w, t, 'y', 'x')
                        ones = f'{P}_set1_epi32(-1)'
                        ex, f = {'eq': (eq, eqf), 'ne': (f'{P}_xor_{w.si}({eq}, {ones})', eqf), 'gt': (gt, gf), 'lt': (lt, gf),
                                 'le': (f'{P}_xor_{w.si}({gt}, {ones})', gf), 'ge': (f'{P}_xor_{w.si}({lt}, {ones})', gf)}[c]
                        entry(f'Cmp{C}Lanes', f, f'cmp_{c}_lanes_{V}', f'a: {V}, b: {V}', U,
                              f'let x = {a};\nlet y = {b};\nreturn {w.h}iv::<{ux}, {n}>({ex});')
                # A lane mask chooses whole lanes: a byte blend.
                m = f'{w.h}i(m)'
                if w.bits == 128:
                    entry('ChooseLanes', ['Sse41'], f'choose_lanes_{V}', f'm: {U}, a: {V}, b: {V}', V,
                          f'return {w.st(t)}({P}_cast{w.si}_{w.ps(t)}({P}_blendv_epi8({P}_cast{w.ps(t)}_{w.si}({b}), {P}_cast{w.ps(t)}_{w.si}({a}), {m})));'
                          if isf(t) else f'return {w.st(t)}({P}_blendv_epi8({b}, {a}, {m}));')
                    entry('ChooseLanes', ['Sse2'], f'choose_lanes_{V}', f'm: {U}, a: {V}, b: {V}', V,
                          f'let k = {m};\nreturn {w.h}iv::<{t}, {n}>({blend(w, "k", w.h + "i(a)", w.h + "i(b)")});')
                else:
                    entry('ChooseLanes', ['Avx2'], f'choose_lanes_{V}', f'm: {U}, a: {V}, b: {V}', V,
                          f'return {w.h}iv::<{t}, {n}>({P}_blendv_epi8({w.h}i(b), {w.h}i(a), {m}));')
                # Lane masks to the mask's bits and back, once per unsigned lane type.
                if t == ux:
                    lm = f'{w.h}i(m)'
                    if e == 8:
                        bits = f'{P}_movemask_epi8({lm})'
                        bf = ['Sse2'] if w.bits == 128 else ['Avx2']
                    elif e == 16:
                        if w.bits == 128:
                            bits = f'_mm_movemask_epi8(_mm_packs_epi16({lm}, _mm_setzero_si128()))'
                            bf = ['Sse2']
                        else:
                            bits = f'_mm_movemask_epi8(_mm_packs_epi16(_mm256_castsi256_si128(r), _mm256_extracti128_si256(r, 1)))'
                            bf = ['Avx2']
                    else:
                        k = 'ps' if e == 32 else 'pd'
                        bits = f'{P}_movemask_{k}({P}_cast{w.si}_{k}({lm}))'
                        bf = [w.ff]
                    pre = f'let r = {lm};\n' if (e == 16 and w.bits == 256) else ''
                    entry('LanesToMask', bf, f'lanes_to_mask_{U}', f'm: {U}', mk,
                          f'{pre}return ({bits} as u64 & {(1 << n) - 1}) as {mk};')
                    entry('AnyLanes', ['Sse2'] if w.bits == 128 else ['Avx2'], f'any_lanes_{U}', f'm: {U}', 'bool',
                          f'return {P}_movemask_epi8({lm}) != 0;')
                    entry('AllLanes', ['Sse2'] if w.bits == 128 else ['Avx2'], f'all_lanes_{U}', f'm: {U}', 'bool',
                          f'return {P}_movemask_epi8({lm}) == {"65535" if w.bits == 128 else "-1"};')
                    # The mask's bits back to lanes: each lane tests its own bit.
                    if e == 8:
                        if w.bits == 128:
                            # Bytes 0 to 7 test bits 0 to 7 of the low byte, bytes 8 to 15 of the high byte.
                            sel = '_mm_shuffle_epi8(_mm_set1_epi16(m as u64 as i16), _mm_setr_epi8(0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1))'
                            bit = '_mm_set1_epi64x(-9205322385119247871)'
                            entry('MaskToLanes', ['Ssse3'], f'mask_to_lanes_{U}', f'm: {mk}', U,
                                  f'let b = {bit};\nreturn xiv::<u8, 16>(_mm_cmpeq_epi8(_mm_and_si128({sel}, b), b));')
                        else:
                            sel = '_mm256_shuffle_epi8(_mm256_set1_epi32(m as u64 as i32), _mm256_setr_epi8(0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3))'
                            bit = '_mm256_set1_epi64x(-9205322385119247871)'
                            entry('MaskToLanes', ['Avx2'], f'mask_to_lanes_{U}', f'm: {mk}', U,
                                  f'let b = {bit};\nreturn yiv::<u8, 32>(_mm256_cmpeq_epi8(_mm256_and_si256({sel}, b), b));')
                    else:
                        bitl = ', '.join(str((1 << i) if i < e - 1 else -(1 << i)) for i in range(n))
                        sc = {16: 'i16', 32: 'i32', 64: 'i64'}[e]
                        ex = 'epi64x' if e == 64 else EPI[e]
                        if e == 64 and w.bits == 128:
                            bt = f'_mm_set_epi64x(2, 1)'
                        elif e == 64:
                            bt = f'_mm256_set_epi64x(8, 4, 2, 1)'
                        else:
                            bt = f'{P}_setr_epi{e}({bitl})'
                        cmp = f'{P}_cmpeq_epi{e}'
                        mf = ['Sse41'] if (e == 64 and w.bits == 128) else [w.fi]
                        entry('MaskToLanes', mf, f'mask_to_lanes_{U}', f'm: {mk}', U,
                              f'let b = {bt};\nreturn {w.h}iv::<{ux}, {n}>({cmp}({P}_and_{w.si}({P}_set1_{ex}(m as u64 as {sc}), b), b));')
                        if e == 64 and w.bits == 128:
                            # SSE2: the low halves' 32-bit test, copied into the high halves (whose test
                            # always holds).
                            entry('MaskToLanes', ['Sse2'], f'mask_to_lanes_{U}', f'm: {mk}', U,
                                  'let b = _mm_set_epi32(0, 2, 0, 1);\nreturn xiv::<u64, 2>(_mm_shuffle_epi32(_mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32(m as u64 as i32), b), b), 160));')
            # The comparisons as the mask itself, from AVX-512's mask registers; and the choice by it.
            if w.bits == 512:
                mf = [w.ib(t)] if not isf(t) else ['Avx512f']
            else:
                mf = ['Avx512f', 'Avx512vl'] + (['Avx512bw'] if (e <= 16 and not isf(t)) else [])
            mi = {2: 'u8', 4: 'u8', 8: 'u8', 16: 'u16', 32: 'u32', 64: 'u64'}[n]
            for c, C in CMPS:
                if isf(t):
                    ex = f'{P}_cmp_{w.ps(t)}_mask({a}, {b}, {FCMP[c]})'
                else:
                    ex = f'{P}_cmp_{"epi" if sg(t) else "epu"}{e}_mask({a}, {b}, {ICMP[c]})'
                entry(f'Cmp{C}', mf, f'cmp_{c}_{V}', f'a: {V}, b: {V}', mk, f'return ({ex}{"" if mi == "u64" else " as u64"}) as {mk};')
            k = w.ps(t) if isf(t) else f'epi{e}'
            entry('Choose', mf, f'choose_{V}', f'm: {mk}, a: {V}, b: {V}', V,
                  f'return {w.st(t)}({P}_mask_blend_{k}({mc(mi)}, {b}, {a}));')


def sign_mask(w, e, x, n):
    """The mask (as a `u64` expression) of the sign bits of lanes of width `e` of register `x`."""
    P = w.p
    if e == 8:
        return f'{P}_movemask_epi8({x}) as u64'
    if e == 16:
        if w.bits == 128:
            return f'_mm_movemask_epi8(_mm_packs_epi16({x}, _mm_setzero_si128())) as u64 & 255'
        return f'_mm_movemask_epi8(_mm_packs_epi16(_mm256_castsi256_si128({x}), _mm256_extracti128_si256({x}, 1))) as u64 & 65535'
    k = 'ps' if e == 32 else 'pd'
    return f'{P}_movemask_{k}({P}_cast{w.si}_{k}({x})) as u64'


# ---- Overflow tests of the trapping operators ---------------------------------------------------
def fam_overflow():
    for w in (W128, W256):
        P = w.p
        for t in INTS:
            n, e = w.n(t), BITS[t]
            V = B(t, n)
            mk = f'mask{n}'
            a, b = f'{w.ld(t)}(a)', f'{w.ld(t)}(b)'
            f = [w.fi] if not (e == 64 and not sg(t) and w.bits == 128) else ['Sse42']
            if sg(t):
                # Signed: the sign of (a ^ r) & (b ^ r) for a sum, of (a ^ b) & (a ^ r) for a difference.
                add = f'let x = {a};\nlet y = {b};\nlet r = {P}_add_epi{e}(x, y);\nlet o = {P}_and_{w.si}({P}_xor_{w.si}(x, r), {P}_xor_{w.si}(y, r));\n'
                sub = f'let x = {a};\nlet y = {b};\nlet r = {P}_sub_epi{e}(x, y);\nlet o = {P}_and_{w.si}({P}_xor_{w.si}(x, y), {P}_xor_{w.si}(x, r));\n'
                entry('OverflowAdd', [w.fi], f'overflow_add_{V}', f'a: {V}, b: {V}', mk, add + f'return ({sign_mask(w, e, "o", n)}) as {mk};')
                entry('OverflowSub', [w.fi], f'overflow_sub_{V}', f'a: {V}, b: {V}', mk, sub + f'return ({sign_mask(w, e, "o", n)}) as {mk};')
            else:
                # Unsigned: the wrapped sum below an operand, the subtrahend above the minuend.
                g1, gf = gt_expr(w, t, 'x', f'{P}_add_epi{e}(x, y)')
                g2, _ = gt_expr(w, t, 'y', 'x')
                entry('OverflowAdd', gf, f'overflow_add_{V}', f'a: {V}, b: {V}', mk,
                      f'let x = {a};\nlet y = {b};\nlet o = {g1};\nreturn ({sign_mask(w, e, "o", n)}) as {mk};')
                entry('OverflowSub', gf, f'overflow_sub_{V}', f'a: {V}, b: {V}', mk,
                      f'let x = {a};\nlet y = {b};\nlet o = {g2};\nreturn ({sign_mask(w, e, "o", n)}) as {mk};')
            if e == 16:
                # The high half of each product: zero (unsigned), the low half's sign (signed).
                if sg(t):
                    body = (f'let x = {a};\nlet y = {b};\n'
                            f'let o = {P}_xor_{w.si}({P}_mulhi_epi16(x, y), {P}_srai_epi16({P}_mullo_epi16(x, y), 15));\n'
                            f'return ({sign_mask(w, 16, f"{P}_cmpeq_epi16(o, {P}_setzero_{w.si}())", n)} ^ {(1 << n) - 1}) as {mk};')
                else:
                    body = (f'let o = {P}_mulhi_epu16({a}, {b});\n'
                            f'return ({sign_mask(w, 16, f"{P}_cmpeq_epi16(o, {P}_setzero_{w.si}())", n)} ^ {(1 << n) - 1}) as {mk};')
                entry('OverflowMul', [w.fi], f'overflow_mul_{V}', f'a: {V}, b: {V}', mk, body)


# ---- Shifts ---------------------------------------------------------------------------------------
def fam_shift():
    for w in WS:
        P = w.p
        for t in INTS:
            n, e = w.n(t), BITS[t]
            V = B(t, n)
            a, st = f'{w.ld(t)}(a)', w.st(t)
            cnt = '_mm_cvtsi32_si128(n)' if t in ('i8', 'u8', 'i16', 'u16') else '_mm_cvtsi32_si128(n as i32)' if t != 'i32' else '_mm_cvtsi32_si128(n)'
            f = [w.ib(t)]
            if e >= 16:
                entry('ShlScalar', f, f'shl_scalar_{V}', f'a: {V}, n: {t}', V, f'return {st}({P}_sll_epi{e}({a}, {cnt}));')
                if not sg(t):
                    entry('ShrScalar', f, f'shr_scalar_{V}', f'a: {V}, n: {t}', V, f'return {st}({P}_srl_epi{e}({a}, {cnt}));')
                elif e < 64 or w.bits == 512:
                    entry('ShrScalar', f, f'shr_scalar_{V}', f'a: {V}, n: {t}', V, f'return {st}({P}_sra_epi{e}({a}, {cnt}));')
                else:
                    entry('ShrScalar', ['Avx512f', 'Avx512vl'], f'shr_scalar_{V}', f'a: {V}, n: {t}', V,
                          f'return {st}({P}_sra_epi64({a}, {cnt}));')
                    # The logical shift, then the sign spread: (x >> n ^ m) - m, m = 1 << (63 - n).
                    entry('ShrScalar', f, f'shr_scalar_{V}', f'a: {V}, n: {t}', V,
                          f'let m = {P}_set1_epi64x((1u64 << (63 - n) as u64) as i64);\n'
                          f'return {st}({P}_sub_epi64({P}_xor_{w.si}({P}_srl_epi64({a}, {cnt}), m), m));')
            else:
                # Bytes: the 16-bit shift, then the bits that crossed a byte cleared.
                entry('ShlScalar', f, f'shl_scalar_{V}', f'a: {V}, n: {t}', V,
                      f'return {st}({P}_and_{w.si}({P}_sll_epi16({a}, {cnt}), {P}_set1_epi8((255u32 << n as u32) as u8 as i8)));')
                lo = f'{P}_and_{w.si}({P}_srl_epi16({a}, {cnt}), {P}_set1_epi8((255u32 >> n as u32) as u8 as i8))'
                if sg(t):
                    entry('ShrScalar', f, f'shr_scalar_{V}', f'a: {V}, n: {t}', V,
                          f'let m = {P}_set1_epi8((128u32 >> n as u32) as u8 as i8);\n'
                          f'return {st}({P}_sub_epi8({P}_xor_{w.si}({lo}, m), m));')
                else:
                    entry('ShrScalar', f, f'shr_scalar_{V}', f'a: {V}, n: {t}', V, f'return {st}({lo});')
            # A vector count, modulo the width.
            if e >= 16:
                if e == 16:
                    vf = ['Avx512bw'] if w.bits == 512 else ['Avx512bw', 'Avx512vl']
                elif w.bits == 512:
                    vf = ['Avx512f']
                else:
                    vf = ['Avx2']
                c = f'{P}_and_{w.si}({w.ld(t)}(n), {P}_set1_epi{e if e < 64 else ("64x" if w.bits < 512 else "64")}({e - 1}))'
                entry('WrappingShl', vf, f'wrapping_shl_{V}', f'a: {V}, n: {V}', V, f'return {st}({P}_sllv_epi{e}({a}, {c}));')
                if not sg(t):
                    entry('WrappingShr', vf, f'wrapping_shr_{V}', f'a: {V}, n: {V}', V, f'return {st}({P}_srlv_epi{e}({a}, {c}));')
                else:
                    sf = vf if (e < 64 or w.bits == 512) else ['Avx512f', 'Avx512vl']
                    entry('WrappingShr', sf, f'wrapping_shr_{V}', f'a: {V}, n: {V}', V, f'return {st}({P}_srav_epi{e}({a}, {c}));')
                if e >= 32:
                    rf = ['Avx512f'] if w.bits == 512 else ['Avx512f', 'Avx512vl']
                    cn = f'{w.ld(t)}(n)'
                    entry('RotateLeft', rf, f'rotate_left_{V}', f'a: {V}, n: {V}', V, f'return {st}({P}_rolv_epi{e}({a}, {cn}));')
                    entry('RotateRight', rf, f'rotate_right_{V}', f'a: {V}, n: {V}', V, f'return {st}({P}_rorv_epi{e}({a}, {cn}));')


# ---- Bit counts -----------------------------------------------------------------------------------
def fam_bits():
    for w in WS:
        P = w.p
        for t in INTS:
            n, e = w.n(t), BITS[t]
            V = B(t, n)
            a, st = f'{w.ld(t)}(a)', w.st(t)
            vl = [] if w.bits == 512 else ['Avx512vl']
            pf = (['Avx512bitalg'] if e <= 16 else ['Avx512vpopcntdq']) + vl
            entry('CountOnes', pf, f'count_ones_{V}', f'a: {V}', V, f'return {st}({P}_popcnt_epi{e}({a}));')
            if e >= 32:
                entry('LeadingZeros', ['Avx512cd'] + vl, f'leading_zeros_{V}', f'a: {V}', V, f'return {st}({P}_lzcnt_epi{e}({a}));')
            if w.bits == 512:
                continue
            # SSSE3: each nibble's count from a 16-entry table, then the bytes summed per lane.
            tab = ', '.join(str(bin(i).count('1')) for i in range(16))
            tabw = tab if w.bits == 128 else tab + ', ' + tab
            body = (f'let x = {a};\nlet lo = {P}_set1_epi8(15);\nlet tab = {P}_setr_epi8({tabw});\n'
                    f'let c = {P}_add_epi8({P}_shuffle_epi8(tab, {P}_and_{w.si}(x, lo)), {P}_shuffle_epi8(tab, {P}_and_{w.si}({P}_srli_epi16(x, 4), lo)));\n')
            if e == 8:
                body += f'return {st}(c);'
            elif e == 16:
                body += f'return {st}({P}_add_epi16({P}_and_{w.si}(c, {P}_set1_epi16(255)), {P}_srli_epi16(c, 8)));'
            elif e == 32:
                body += (f'let h = {P}_add_epi16({P}_and_{w.si}(c, {P}_set1_epi16(255)), {P}_srli_epi16(c, 8));\n'
                         f'return {st}({P}_add_epi32({P}_and_{w.si}(h, {P}_set1_epi32(65535)), {P}_srli_epi32(h, 16)));')
            else:
                body += f'return {st}({P}_sad_epu8(c, {P}_setzero_{w.si}()));'
            entry('CountOnes', ['Ssse3'] if w.bits == 128 else ['Avx2'], f'count_ones_{V}', f'a: {V}', V, body)


# ---- Float min_num, max_num, minimum, maximum -------------------------------------------------------
def fam_fminmax():
    for w in WS:
        P = w.p
        for t in FLTS:
            n = w.n(t)
            V = B(t, n)
            k = w.ps(t)
            a, b, st = f'{w.ld(t)}(a)', f'{w.ld(t)}(b)', w.st(t)
            q = '0x00400000' if t == 'f32' else '0x0008000000000000'
            ie = '32' if t == 'f32' else '64'
            if w.bits < 512:
                # `minps` gives `b` when an operand is NaN or both are zeros: equal operands take their
                # OR (min) or AND (max), the sign rule of zeros; a NaN `b` takes `a`, quieted when NaN.
                qs = f'{P}_cast{w.si}_{k}({P}_set1_epi{ie}{"x" if (ie == "64") else ""}({q}))'
                if w.bits == 128:
                    eq, un = f'{P}_cmpeq_{k}(x, y)', f'{P}_cmpunord_{k}'
                    unx, uny, unxy = f'{un}(x, x)', f'{un}(y, y)', f'{un}(x, y)'
                else:
                    eq = f'{P}_cmp_{k}(x, y, 0)'
                    unx, uny, unxy = f'{P}_cmp_{k}(x, x, 3)', f'{P}_cmp_{k}(y, y, 3)', f'{P}_cmp_{k}(x, y, 3)'

                def bl(m, x, y):
                    return f'{P}_or_{k}({P}_and_{k}({m}, {x}), {P}_andnot_{k}({m}, {y}))'
                for nm, op, mm, zz in (('min', 'Min', 'min', 'or'), ('max', 'Max', 'max', 'and')):
                    entry(op, [w.ff], f'{nm}_{V}', f'a: {V}, b: {V}', V,
                          f'let x = {a};\nlet y = {b};\n'
                          f'let r = {bl(eq, f"{P}_{zz}_{k}(x, y)", f"{P}_{mm}_{k}(x, y)")};\n'
                          f'let xq = {P}_or_{k}(x, {P}_and_{k}({unx}, {qs}));\n'
                          f'return {st}({bl(uny, "xq", "r")});')
                for nm, op, mm, zz in (('minimum', 'Minimum', 'min', 'or'), ('maximum', 'Maximum', 'max', 'and')):
                    entry(op, [w.ff], f'{nm}_{V}', f'a: {V}, b: {V}', V,
                          f'let x = {a};\nlet y = {b};\n'
                          f'let r = {bl(eq, f"{P}_{zz}_{k}(x, y)", f"{P}_{mm}_{k}(x, y)")};\n'
                          f'return {st}({P}_or_{k}(r, {unxy}));')
            else:
                # The same rules with mask registers.
                ki = 'epi32' if t == 'f32' else 'epi64'
                mi = 'u16' if t == 'f32' else 'u8'
                xi, yi = f'{P}_cast{k}_si512(x)', f'{P}_cast{k}_si512(y)'
                for nm, op, mm, zz in (('min', 'Min', 'min', 'or'), ('max', 'Max', 'max', 'and')):
                    entry(op, [w.ff], f'{nm}_{V}', f'a: {V}, b: {V}', V,
                          f'let x = {a};\nlet y = {b};\n'
                          f'let z = {P}_castsi512_{k}({P}_{zz}_si512({xi}, {yi}));\n'
                          f'let r = {P}_mask_blend_{k}({P}_cmp_{k}_mask(x, y, 0), {P}_{mm}_{k}(x, y), z);\n'
                          f'let xq = {P}_castsi512_{k}({P}_mask_or_{ki}({xi}, {P}_cmp_{k}_mask(x, x, 3), {xi}, {P}_set1_{ki}({q})));\n'
                          f'return {st}({P}_mask_blend_{k}({P}_cmp_{k}_mask(y, y, 3), r, xq));')
                for nm, op, mm, zz in (('minimum', 'Minimum', 'min', 'or'), ('maximum', 'Maximum', 'max', 'and')):
                    entry(op, [w.ff], f'{nm}_{V}', f'a: {V}, b: {V}', V,
                          f'let x = {a};\nlet y = {b};\n'
                          f'let z = {P}_castsi512_{k}({P}_{zz}_si512({xi}, {yi}));\n'
                          f'let r = {P}_mask_blend_{k}({P}_cmp_{k}_mask(x, y, 0), {P}_{mm}_{k}(x, y), z);\n'
                          f'return {st}({P}_mask_blend_{k}({P}_cmp_{k}_mask(x, y, 3), r, {P}_castsi512_{k}({P}_set1_{ki}(-1))));')


# ---- Conversions --------------------------------------------------------------------------------
def f2i32(w, a, uns):
    """`as i32` (or `as u32` when `uns`) of f32 register `a` at 128 or 256 bits: truncation saturated,
    NaN 0. `cvttps2dq` gives 0x80000000 for NaN and past either end."""
    P = w.p
    if not uns:
        hi = f'{P}_cast{w.si}_ps({P}_set1_epi32(1325400064))'  # 2^31 as f32
        return (f'let x = {a};\nlet r = {P}_cvttps_epi32(x);\n'
                f'let big = {P}_castps_{w.si}({cmp_ge(w, "x", hi)});\n'
                f'let ord = {P}_castps_{w.si}({cmp_ord(w, "x")});\n'
                f'return {{}}({P}_and_{w.si}({P}_xor_{w.si}(r, big), ord));')
    # Negative and NaN lanes to 0 by `max` (it gives its second operand for a NaN); the lanes from
    # 2^31 converted 2^31 lower and their top bit set; past 2^32 all ones.
    two31 = f'{P}_cast{w.si}_ps({P}_set1_epi32(1325400064))'
    two32 = f'{P}_cast{w.si}_ps({P}_set1_epi32(1333788672))'
    return (f'let x = {P}_max_ps({a}, {P}_setzero_ps());\n'
            f'let h = {two31};\n'
            f'let big = {P}_castps_{w.si}({cmp_ge(w, "x", "h")});\n'
            f'let lo = {P}_cvttps_epi32(x);\n'
            f'let up = {P}_xor_{w.si}({P}_cvttps_epi32({P}_sub_ps(x, h)), {P}_set1_epi32(-2147483648));\n'
            f'let r = {P}_or_{w.si}({P}_and_{w.si}(big, up), {P}_andnot_{w.si}(big, lo));\n'
            f'return {{}}({P}_or_{w.si}(r, {P}_castps_{w.si}({cmp_ge(w, "x", two32)})));')


def cmp_ge(w, x, y):
    return f'_mm_cmpge_ps({x}, {y})' if w.bits == 128 else f'_mm256_cmp_ps({x}, {y}, 29)'


def cmp_ord(w, x):
    return f'_mm_cmpord_ps({x}, {x})' if w.bits == 128 else f'_mm256_cmp_ps({x}, {x}, 7)'


def fam_cast():
    for w in WS:
        P = w.p
        # A change of signedness keeps every bit.
        for e in (8, 16, 32, 64):
            n = w.bits // e
            for s, d in ((f'i{e}', f'u{e}'), (f'u{e}', f'i{e}')):
                entry('Cast', [w.fi if w.bits != 256 else 'Avx'], f'cast_{B(s, n)}_{B(d, n)}', f'a: {B(s, n)}', B(d, n),
                      f'return {w.st(d)}({w.ld(s)}(a));')
        n = w.bits // 32
        fi, fu = B('f32', n), B('i32', n)
        uu = B('u32', n)
        if w.bits < 512:
            entry('Cast', [w.ff], f'cast_{fu}_{fi}', f'a: {fu}', fi, f'return {w.st("f32")}({P}_cvtepi32_ps({w.ld("i32")}(a)));')
            entry('Cast', [w.fi], f'cast_{fi}_{fu}', f'a: {fi}', fu, f2i32(w, f'{w.ld("f32")}(a)', False).format(w.st('i32')))
            entry('Cast', [w.fi], f'cast_{fi}_{uu}', f'a: {fi}', uu, f2i32(w, f'{w.ld("f32")}(a)', True).format(w.st('u32')))
            # u32: the high and the low 16 bits converted apart, each exactly; one rounding in the sum.
            entry('Cast', [w.fi], f'cast_{uu}_{fi}', f'a: {uu}', fi,
                  f'let x = {w.ld("u32")}(a);\n'
                  f'let hi = {P}_mul_ps({P}_cvtepi32_ps({P}_srli_epi32(x, 16)), {P}_set1_ps(65536.0));\n'
                  f'return {w.st("f32")}({P}_add_ps(hi, {P}_cvtepi32_ps({P}_and_{w.si}(x, {P}_set1_epi32(65535)))));')
            vl = ['Avx512f', 'Avx512vl']
            entry('Cast', vl, f'cast_{uu}_{fi}', f'a: {uu}', fi, f'return {w.st("f32")}({P}_cvtepu32_ps({w.ld("u32")}(a)));')
        else:
            entry('Cast', ['Avx512f'], f'cast_{fu}_{fi}', f'a: {fu}', fi, f'return {w.st("f32")}({P}_cvtepi32_ps({w.ld("i32")}(a)));')
            entry('Cast', ['Avx512f'], f'cast_{uu}_{fi}', f'a: {uu}', fi, f'return {w.st("f32")}({P}_cvtepu32_ps({w.ld("u32")}(a)));')
            # Truncation; past either end that end, NaN 0, by the comparison masks.
            for d, cv, lo, hi in (('i32', 'cvttps_epi32', 'cvt_lo', '1325400064'), ('u32', 'cvttps_epu32', 'cvt_lo', '1333788672')):
                dv = B(d, n)
                mx = '2147483647' if d == 'i32' else '-1'
                mn = '-2147483648' if d == 'i32' else '0'
                entry('Cast', ['Avx512f'], f'cast_{fi}_{dv}', f'a: {fi}', dv,
                      f'let x = {w.ld("f32")}(a);\n'
                      f'let r = {P}_{cv}(x);\n'
                      f'let r1 = {P}_mask_mov_epi32(r, {P}_cmp_ps_mask(x, {P}_castsi512_ps({P}_set1_epi32({hi})), 29), {P}_set1_epi32({mx}));\n'
                      + (f'let r2 = {P}_mask_mov_epi32(r1, {P}_cmp_ps_mask(x, {P}_setzero_ps(), 17), {P}_set1_epi32({mn}));\n' if d == 'u32' else '')
                      + f'return {w.st(d)}({P}_maskz_mov_epi32({P}_cmp_ps_mask(x, x, 7), {"r2" if d == "u32" else "r1"}));')
        # 64-bit lanes and doubles: AVX-512DQ.
        n = w.bits // 64
        dq = ['Avx512dq'] if w.bits == 512 else ['Avx512dq', 'Avx512vl']
        for s in ('i64', 'u64'):
            u = 'epi64' if s == 'i64' else 'epu64'
            entry('Cast', dq, f'cast_{B(s, n)}_{B("f64", n)}', f'a: {B(s, n)}', B('f64', n),
                  f'return {w.st("f64")}({P}_cvt{u}_pd({w.ld(s)}(a)));')
        # Integer widening: the sign- or zero-extension of the source's own signedness.
        for es, ed in ((8, 16), (8, 32), (8, 64), (16, 32), (16, 64), (32, 64)):
            nd = w.bits // ed
            nsrc_bits = nd * es
            if nsrc_bits < 64 or nd < 2:
                continue
            for s in (f'i{es}', f'u{es}'):
                for d in (f'i{ed}', f'u{ed}'):
                    cv = f'{P}_cvt{"epi" if s[0] == "i" else "epu"}{es}_epi{ed}'
                    src = B(s, nd)
                    if nsrc_bits == 64:
                        ld = f'xli(a)'
                    elif nsrc_bits == 128:
                        ld = f'xi(a)'
                    else:
                        ld = f'yi(a)'
                    f = ['Sse41'] if w.bits == 128 else (['Avx2'] if w.bits == 256 else (['Avx512bw'] if (es == 8 and ed == 16) else ['Avx512f']))
                    entry('Cast', f, f'cast_{src}_{B(d, nd)}', f'a: {src}', B(d, nd), f'return {w.st(d)}({cv}({ld}));')
        # Integer narrowing: the low bits.
        if w.bits == 512:
            for es, ed in ((16, 8), (32, 8), (32, 16), (64, 8), (64, 16), (64, 32)):
                ns = 512 // es
                f = ['Avx512bw'] if es == 16 else ['Avx512f']
                rb = ns * ed
                back = {64: 'xliv', 128: 'xiv', 256: 'yiv'}[rb]
                for s in (f'i{es}', f'u{es}'):
                    for d in (f'i{ed}', f'u{ed}'):
                        entry('Cast', f, f'cast_{B(s, ns)}_{B(d, ns)}', f'a: {B(s, ns)}', B(d, ns),
                              f'return {back}::<{d}, {ns}>(_mm512_cvtepi{es}_epi{ed}(zi(a)));')
                        sat = 'cvtsepi' if s[0] == 'i' and d[0] == 'i' else 'cvtusepi' if s[0] == 'u' and d[0] == 'u' else None
                        if sat:
                            entry('NarrowSaturating', f, f'narrow_saturating_{B(s, ns)}_{B(d, ns)}', f'a: {B(s, ns)}', B(d, ns),
                                  f'return {back}::<{d}, {ns}>(_mm512_{sat}{es}_epi{ed}(zi(a)));')
        else:
            # The pairs of a 128-bit register (64-bit result), or of a 256-bit one's halves.
            for es, ed in ((16, 8), (32, 16)):
                ns = w.bits // es
                pk = 'packus_epi16' if es == 16 else 'packus_epi32'
                f = (['Sse2'] if es == 16 else ['Sse41']) if w.bits == 128 else ['Avx2']
                keep = f'_mm_set1_epi{es}({(1 << ed) - 1})'
                for s in (f'i{es}', f'u{es}'):
                    for d in (f'i{ed}', f'u{ed}'):
                        if w.bits == 128:
                            body = f'return xliv::<{d}, {ns}>(_mm_{pk}(_mm_and_si128(xi(a), {keep}), _mm_setzero_si128()));'
                        else:
                            body = (f'let x = yi(a);\nlet k = {keep};\n'
                                    f'return xiv::<{d}, {ns}>(_mm_{pk}(_mm_and_si128(_mm256_castsi256_si128(x), k), _mm_and_si128(_mm256_extracti128_si256(x, 1), k)));')
                        entry('Cast', f, f'cast_{B(s, ns)}_{B(d, ns)}', f'a: {B(s, ns)}', B(d, ns), body)
                # Saturating: signed to signed `packs`, signed to unsigned `packus`; unsigned first
                # clamped below the signed maximum.
                for s, d, pre, op in ((f'i{es}', f'i{ed}', None, 'packs'), (f'i{es}', f'u{ed}', None, 'packus'),
                                      (f'u{es}', f'u{ed}', 'min', 'packus')):
                    if op == 'packs':
                        f2 = ['Sse2'] if w.bits == 128 else ['Avx2']
                    elif es == 32 or pre:
                        f2 = ['Sse41'] if w.bits == 128 else ['Avx2']
                    else:
                        f2 = ['Sse2'] if w.bits == 128 else ['Avx2']
                    cl = (lambda x: f'_mm_min_epu{es}({x}, _mm_set1_epi{es}({(1 << ed) - 1}))') if pre else (lambda x: x)
                    pko = f'_mm_{op}_epi{es}'
                    if w.bits == 128:
                        body = f'return xliv::<{d}, {ns}>({pko}({cl("xi(a)")}, _mm_setzero_si128()));'
                    else:
                        body = (f'let x = yi(a);\n'
                                f'return xiv::<{d}, {ns}>({pko}({cl("_mm256_castsi256_si128(x)")}, {cl("_mm256_extracti128_si256(x, 1)")}));')
                    entry('NarrowSaturating', f2, f'narrow_saturating_{B(s, ns)}_{B(d, ns)}', f'a: {B(s, ns)}', B(d, ns), body)
            if w.bits == 256:
                # 64-bit lanes to 32: the even 32-bit words.
                for s in ('i64', 'u64'):
                    for d in ('i32', 'u32'):
                        entry('Cast', ['Avx2'], f'cast_{B(s, 4)}_{B(d, 4)}', f'a: {B(s, 4)}', B(d, 4),
                              f'return xiv::<{d}, 4>(_mm256_castsi256_si128(_mm256_permutevar8x32_epi32(yi(a), _mm256_setr_epi32(0, 2, 4, 6, 0, 2, 4, 6))));')
        # f32 and f64: the C conversions round to nearest, as `as` does.
        if w.bits == 128:
            entry('Cast', ['Sse2'], 'cast_f32x2_f64x2', 'a: Simd<f32, 2>', 'f64x2', 'return xdv::<f64, 2>(_mm_cvtps_pd(_mm_castsi128_ps(xli(a))));')
            entry('Cast', ['Sse2'], 'cast_f64x2_f32x2', 'a: f64x2', 'Simd<f32, 2>', 'return xliv::<f32, 2>(_mm_castps_si128(_mm_cvtpd_ps(xd(a))));')
        elif w.bits == 256:
            entry('Cast', ['Avx'], 'cast_f32x4_f64x4', 'a: f32x4', 'f64x4', 'return ydv::<f64, 4>(_mm256_cvtps_pd(xf(a)));')
            entry('Cast', ['Avx'], 'cast_f64x4_f32x4', 'a: f64x4', 'f32x4', 'return xfv::<f32, 4>(_mm256_cvtpd_ps(yd(a)));')
        else:
            entry('Cast', ['Avx512f'], 'cast_f32x8_f64x8', 'a: f32x8', 'f64x8', 'return zdv::<f64, 8>(_mm512_cvtps_pd(yf(a)));')
            entry('Cast', ['Avx512f'], 'cast_f64x8_f32x8', 'a: f64x8', 'f32x8', 'return yfv::<f32, 8>(_mm512_cvtpd_ps(zd(a)));')


# ---- Reductions, dot, run-time byte index --------------------------------------------------------
def fam_reduce():
    w = W128
    for t in INTS:
        n, e = w.n(t), BITS[t]
        V = B(t, n)
        x = 'let x = xi(v);\n'
        # Wrapping sums: the bytes' sums of absolute differences against zero, or a fold of halves.
        if e == 8:
            body = x + 'let s = _mm_sad_epu8(x, _mm_setzero_si128());\n' \
                       f'return {cv("_mm_cvtsi128_si32(_mm_add_epi64(s, _mm_unpackhi_epi64(s, s)))", t, "i32")};'
        elif e == 16:
            body = x + 'let s = _mm_madd_epi16(x, _mm_set1_epi16(1));\n' \
                       'let s2 = _mm_add_epi32(s, _mm_shuffle_epi32(s, 78));\n' \
                       f'return {cv("_mm_cvtsi128_si32(_mm_add_epi32(s2, _mm_shuffle_epi32(s2, 177)))", t, "i32")};'
        elif e == 32:
            body = x + 'let s = _mm_add_epi32(x, _mm_shuffle_epi32(x, 78));\n' \
                       f'return {cv("_mm_cvtsi128_si32(_mm_add_epi32(s, _mm_shuffle_epi32(s, 177)))", t, "i32")};'
        else:
            body = x + f'return {cv("_mm_cvtsi128_si64(_mm_add_epi64(x, _mm_unpackhi_epi64(x, x)))", t, "i64")};'
        entry('ReduceAdd', ['Sse2'], f'reduce_add_{V}', f'v: {V}', t, body)
        # Bitwise reductions: a fold of halves.
        for op, nm in (('ReduceAnd', 'and'), ('ReduceOr', 'or'), ('ReduceXor', 'xor')):
            steps = [('_mm_unpackhi_epi64(s, s)', 64), ('_mm_shuffle_epi32(s, 177)', 32), ('_mm_srli_epi32(s, 16)', 16), ('_mm_srli_epi16(s, 8)', 8)]
            body = 'let mut s = xi(v);\n'
            for sh, wd in steps:
                if wd >= e:
                    body += f's = _mm_{nm}_si128(s, {sh});\n'
            body += f'return {cv("_mm_cvtsi128_si" + ("64" if e == 64 else "32") + "(s)", t, "i64" if e == 64 else "i32")};'
            entry(op, ['Sse2'], f'reduce_{nm}_{V}', f'v: {V}', t, body)
        # Extremes: u16 by `phminposuw` (max by complement); the others by a fold of halves.
        for op, nm in (('ReduceMin', 'min'), ('ReduceMax', 'max')):
            if t == 'u16':
                if nm == 'min':
                    body = 'return _mm_cvtsi128_si32(_mm_minpos_epu16(xi(v))) as u16;'
                else:
                    body = 'return 65535 - _mm_cvtsi128_si32(_mm_minpos_epu16(_mm_xor_si128(xi(v), _mm_set1_epi32(-1)))) as u16;'
                entry(op, ['Sse41'], f'reduce_{nm}_{V}', f'v: {V}', t, body)
                continue
            if e == 64:
                continue
            steps = [('_mm_unpackhi_epi64(s, s)', 64), ('_mm_shuffle_epi32(s, 177)', 32), ('_mm_srli_epi32(s, 16)', 16), ('_mm_srli_epi16(s, 8)', 8)]
            body = 'let mut s = xi(v);\n'
            for sh, wd in steps:
                if wd >= e:
                    ex, _ = minmax_expr(w, t, nm, 's', sh)
                    body += f's = {ex};\n'
            body += f'return {cv("_mm_cvtsi128_si32(s)", t, "i32")};'
            _, f = minmax_expr(w, t, nm, 's', 's')
            entry(op, f, f'reduce_{nm}_{V}', f'v: {V}', t, body)
    for t in FLTS:
        n = w.n(t)
        V = B(t, n)
        k = w.ps(t)
        # The tree: the upper half onto the lower half, until one lane.
        for op, nm in (('ReduceAddTree', 'add'), ('ReduceMulTree', 'mul')):
            if t == 'f32':
                body = (f'let x = xf(v);\nlet h = _mm_{nm}_ps(x, _mm_movehl_ps(x, x));\n'
                        f'return _mm_cvtss_f32(_mm_{nm}_ss(h, _mm_shuffle_ps(h, h, 85)));')
            else:
                body = f'let x = xd(v);\nreturn _mm_cvtsd_f64(_mm_{nm}_sd(x, _mm_unpackhi_pd(x, x)));'
            entry(op, ['Sse2'], f'reduce_{nm}_tree_{V}', f'v: {V}', t, body)
    # `dot::<i32>` of i16 lanes: the pairs' products summed by `pmaddwd` (modulo 2^32), then the sum.
    if True:
        entry('Dot', ['Sse2'], 'dot_i16x8_i32', 'a: i16x8, b: i16x8', 'i32',
              'let s = _mm_madd_epi16(xi(a), xi(b));\n'
              'let s2 = _mm_add_epi32(s, _mm_shuffle_epi32(s, 78));\n'
              'return _mm_cvtsi128_si32(_mm_add_epi32(s2, _mm_shuffle_epi32(s2, 177)));')
    # A run-time byte index: `pshufb` gives 0 where the index byte's top bit is set, so the
    # indexes from 16 saturate past 127 first.
    for t in ('i8', 'u8'):
        entry('SwizzleOrZero', ['Ssse3'], f'swizzle_or_zero_{t}x16', f'a: {t}x16, idx: u8x16', f'{t}x16',
              f'return xiv::<{t}, 16>(_mm_shuffle_epi8(xi(a), _mm_adds_epu8(xi(idx), _mm_set1_epi8(112))));')


# ---- Masked memory, compress, expand --------------------------------------------------------------
def lane_bits(w, e, n, m):
    """The lane masks (all ones where bit `i` of mask `m` is set) of `n` lanes of width 32 or 64."""
    P = w.p
    sc = 'i32' if e == 32 else 'i64'
    if e == 32:
        bt = f'{P}_setr_epi32(' + ', '.join(str(1 << i) for i in range(n)) + ')'
        return f'{P}_cmpeq_epi32({P}_and_{w.si}({P}_set1_epi32({m} as u64 as i32), b), b)', bt
    bt = f'{P}_set_epi64x(' + ', '.join(str(1 << i) for i in reversed(range(n))) + ')'
    return f'{P}_cmpeq_epi64({P}_and_{w.si}({P}_set1_epi64x({m} as u64 as i64), b), b)', bt


def fam_masked():
    for w in WS:
        P = w.p
        for t in INTS + FLTS:
            n, e = w.n(t), BITS[t]
            V = B(t, n)
            mk = f'mask{n}'
            mi = {2: 'u8', 4: 'u8', 8: 'u8', 16: 'u16', 32: 'u32', 64: 'u64'}[n]
            st = w.st(t)
            sfx = w.ps(t) if isf(t) else f'epi{e}'
            # AVX-512: the masked forms take the mask itself; masked lanes are not accessed.
            if w.bits == 512:
                f = ['Avx512bw'] if e <= 16 else ['Avx512f']
            else:
                f = ['Avx512f', 'Avx512vl'] + (['Avx512bw'] if e <= 16 else [])
            entry('LoadMasked', f, f'load_masked_{V}', f'p: *const {t}, m: {mk}, fb: {V}', V,
                  f'return {st}(unsafe {P}_mask_loadu_{sfx}({w.ld(t)}(fb), {mc(mi)}, p));')
            entry('StoreMasked', f, f'store_masked_{V}', f'p: *mut {t}, m: {mk}, v: {V}', '',
                  f'unsafe {P}_mask_storeu_{sfx}(p, {mc(mi)}, {w.ld(t)}(v));')
            cf = ['Avx512vbmi2'] + ([] if w.bits == 512 else ['Avx512vl']) if e <= 16 else f
            entry('Compress', cf, f'compress_{V}', f'm: {mk}, v: {V}, fill: {V}', V,
                  f'return {st}({P}_mask_compress_{sfx}({w.ld(t)}(fill), {mc(mi)}, {w.ld(t)}(v)));')
            entry('Expand', cf, f'expand_{V}', f'm: {mk}, v: {V}, fill: {V}', V,
                  f'return {st}({P}_mask_expand_{sfx}({w.ld(t)}(fill), {mc(mi)}, {w.ld(t)}(v)));')
            # AVX and AVX2: `vmaskmov` and `vpmaskmov` over 32- and 64-bit lanes, under lane masks.
            if w.bits < 512 and e >= 32:
                lb, bt = lane_bits(w, e, n, 'm')
                k = 'ps' if e == 32 else 'pd'
                if isf(t):
                    li, si = f'{P}_maskload_{k}', f'{P}_maskstore_{k}'
                    blend = f'{P}_blendv_{k}({w.ld(t)}(fb), r, {P}_cast{w.si}_{k}(s))'
                else:
                    li, si = f'{P}_maskload_epi{e}', f'{P}_maskstore_epi{e}'
                    blend = f'{P}_blendv_epi8({w.ld(t)}(fb), r, s)'
                ld = f'{li}({pc(li, "p", "*const " + t)}, s)'
                sto = f'{si}({pc(si, "p", "*mut " + t)}, s, {w.ld(t)}(v))'
                f2 = ['Avx2']
                entry('LoadMasked', f2, f'load_masked_{V}', f'p: *const {t}, m: {mk}, fb: {V}', V,
                      f'let b = {bt};\nlet s = {lb};\nlet r = unsafe {ld};\nreturn {st}({blend});')
                entry('StoreMasked', f2, f'store_masked_{V}', f'p: *mut {t}, m: {mk}, v: {V}', '',
                      f'let b = {bt};\nlet s = {lb};\nunsafe {sto};')


# ---- The helpers and the files --------------------------------------------------------------------
def helpers():
    out = []
    for w, f in ((W128, 'Sse2'), (W256, 'Avx'), (W512, 'Avx512f')):
        for kk, sfx in (('i', w.si), ('f', 'ps'), ('d', 'pd')):
            R = {'i': w.I, 'f': w.F, 'd': w.D}[kk]
            h = w.h + kk
            out.append(f'// Vector `x` in a {w.bits}-bit register, and back.\n'
                       f'@arch(x86_64)\n@target_feature([cpu::Feature::{f}])\n'
                       f'fn {h}<T: SimdElement, const N: usize>(x: Simd<T, N>) {R} {{\n'
                       f'    return unsafe {w.p}_loadu_{sfx}({pr(f"{w.p}_loadu_{sfx}", False)});\n}}\n\n'
                       f'@arch(x86_64)\n@target_feature([cpu::Feature::{f}])\n'
                       f'fn {h}v<T: SimdElement, const N: usize>(r: {R}) Simd<T, N> {{\n'
                       f'    let mut x = unsafe zeroed::<Simd<T, N>>();\n'
                       f'    unsafe {w.p}_storeu_{sfx}({pr(f"{w.p}_storeu_{sfx}", True)}, r);\n'
                       f'    return x;\n}}\n')
    out.append('// Vector `x` of 64 bits in the low half of a register, and back.\n'
               '@arch(x86_64)\n@target_feature([cpu::Feature::Sse2])\n'
               'fn xli<T: SimdElement, const N: usize>(x: Simd<T, N>) __m128i {\n'
               '    return unsafe _mm_loadl_epi64((&x) as *const Simd<T, N> as *const __m128i_u);\n}\n\n'
               '@arch(x86_64)\n@target_feature([cpu::Feature::Sse2])\n'
               'fn xliv<T: SimdElement, const N: usize>(r: __m128i) Simd<T, N> {\n'
               '    let mut x = unsafe zeroed::<Simd<T, N>>();\n'
               '    unsafe _mm_storel_epi64((&mut x) as *mut Simd<T, N> as *mut __m128i_u, r);\n'
               '    return x;\n}\n')
    out.append('// A pointer as `void *`, which C converts to the `long long *` some intrinsics take (an\n'
               '// `int64_t *` is `long *` on LP64).\n'
               '@arch(x86_64)\nfn vc<T>(p: *const T) *const void {\n    return p;\n}\n\n'
               '@arch(x86_64)\nfn vm<T>(p: *mut T) *mut void {\n    return p;\n}\n')
    return '\n'.join(out)


# The intrinsics std/simd/x86.spc calls beyond the backend's.
EXTRA_USES = open('std/simd/x86.spc').read() if __import__('os').path.exists('std/simd/x86.spc') else ''


def main():
    for fam in (fam_load_store, fam_int_basic, fam_int_mul, fam_float, fam_int_minmax, fam_compare, fam_overflow,
                fam_shift, fam_bits, fam_fminmax, fam_cast, fam_reduce, fam_masked, fam_gather, fam_i64_gaps, fam_minmax_avx10):
        fam()
    hdr = '''// The x86-64 entries of the portable vector operations (`@simd_impl`): SSE2 to SSE4.2 at 128 bits,
// AVX and AVX2 at 256, AVX-512 at 512 and, through AVX-512VL, its mask-register forms at 128 and 256.
// One entry per operation, lane type, lane count and feature set that has a sequence; the planner
// takes the one with the largest feature set the function enables and splits a wider vector into
// the widest chunk the preferred width allows. An operation without an entry keeps its lane loop.
// Each entry gives the operation's exact result for every input: a trapping operator's `Overflow`
// entry, or its count check, runs before its wrapping twin. Storage is read and written with the
// unaligned forms: a vector's alignment is at most 16.
import std::cpu;
import std::simd;
import immintrin as *;

'''
    body = hdr + helpers() + '\n' + '\n'.join(OUT)
    # An intrinsic with an immediate operand is unsafe: its operand must be a constant.
    body = re.sub(r'(?<!unsafe )\b(' + '|'.join(sorted(IMM)) + r')\(', r'unsafe \1(', body)
    open('std/simd/backend/x86_64.spc', 'w').write(body)
    used = sorted(set(re.findall(r'\b(_mm\w*)\(', body + EXTRA_USES)))
    open('ffi/immintrin.spc', 'w').write(binding(used))
    print(len(OUT), 'entries,', len(used), 'intrinsics')



# ---- The binding, from GCC's <immintrin.h> prototypes ------------------------------------------------
CTYPE = {'__m128': '__m128', '__m128d': '__m128d', '__m128i': '__m128i', '__m256': '__m256', '__m256d': '__m256d',
         '__m256i': '__m256i', '__m512': '__m512', '__m512d': '__m512d', '__m512i': '__m512i', '__mmask8': 'u8',
         '__mmask16': 'u16', '__mmask32': 'u32', '__mmask64': 'u64', 'char': 'i8', 'short': 'i16', 'int': 'i32',
         'const int': 'i32', 'int const': 'i32', 'unsigned int': 'u32', 'long long': 'i64', 'float': 'f32',
         'double': 'f64'}
FEAT = {'': 'Sse2', 'sse3': 'Sse3', 'ssse3': 'Ssse3', 'sse4.1': 'Sse41', 'sse4.2': 'Sse42', 'avx': 'Avx', 'avx2': 'Avx2',
        'fma': 'Fma', 'avx512f': 'Avx512f', 'avx512bw': 'Avx512bw', 'avx512cd': 'Avx512cd', 'avx512dq': 'Avx512dq',
        'avx512vl': 'Avx512vl', 'avx512vbmi': 'Avx512vbmi', 'avx512vbmi2': 'Avx512vbmi2', 'avx512bitalg': 'Avx512bitalg',
        'avx512vpopcntdq': 'Avx512vpopcntdq', 'avx512vnni': 'Avx512vnni', 'gfni': 'Gfni', 'vaes': 'Vaes',
        'vpclmulqdq': 'Vpclmulqdq', 'aes': 'Aesni', 'pclmul': 'Pclmulqdq', 'popcnt': 'Popcnt', 'lzcnt': 'Lzcnt',
        'bmi': 'Bmi1', 'bmi2': 'Bmi2', 'f16c': 'F16c', 'avx512fp16': 'Avx512fp16', 'avx10.2': 'Avx102'}
BYTES = {'_mm_': 16, '_mm256_': 32, '_mm512_': 64}


# The intrinsics with an immediate operand (a `const` scalar parameter in GCC's header).
IMM = {n for n, pr in PROTOS.items() if any('const' in x and '*' not in x and '__m' not in x
                                            for x in pr['params'].split(','))}


def binding(used):
    P = PROTOS
    out = ['''// FFI bindings for <immintrin.h> (Intel's SSE to AVX-512 intrinsics): the register types and the
// intrinsics std/simd/backend/x86_64.spc and std/simd/x86.spc call, each with the instruction set the
// header enables it under. An access through a pointer states its range, or for a masked or indexed
// one that it touches its active lanes only; an immediate operand must be a constant (its binding is
// unsafe).
import std::cpu;

extern "C" "immintrin.h" {''']
    for b, sz in ((128, 16), (256, 32), (512, 64)):
        for sfx, what in (('i', 'integer lanes'), ('', 'f32 lanes'), ('d', 'f64 lanes')):
            out.append(f'    /// A {b}-bit register of {what}.\n    @arch(x86_64)\n    @value({sz}, 16)\n    pub type __m{b}{sfx};')
        if b < 512:
            out.append(f'    /// The {b} bits a register load or store addresses, at any alignment.\n    @arch(x86_64)\n    pub type __m{b}i_u;')
    for u in used:
        pr = P[u]
        ret = pr['ret'].strip()
        params = []
        ptr = None
        for k, prm in enumerate([x.strip() for x in pr['params'].split(',') if x.strip() and x.strip() != 'void']):
            ty = re.sub(r'\s*\b__\w+$', '', prm).strip()
            if '*' in ty:
                params.append(('p', ptr_type(ty)))
                ptr = 'p'
            else:
                params.append((chr(ord('a') + k) if k < 26 else f'a{k}', CTYPE[ty]))
        fs = [FEAT[t] for t in pr['target'] if t != 'sse2'] or ['Sse2']
        attrs = ['@arch(x86_64)', f'@target_feature([{", ".join("cpu::Feature::" + f for f in fs)}])']
        if ptr is None:
            if u not in IMM:
                attrs.append('@unsafe(safe)')
        elif any(s in u for s in ('maskload', 'maskstore', 'mask_loadu', 'mask_storeu', 'gather', 'scatter', 'compressstoreu', 'expandloadu')):
            attrs.append('@lane_access')
        elif 'loadl' in u or 'storel' in u:
            attrs.append(f'@{"reads" if "load" in u else "writes"}(p, 8)')
        elif 'load' in u or 'store' in u:
            pre = [p for p in BYTES if u.startswith(p)][-1]
            attrs.append(f'@{"reads" if "load" in u else "writes"}(p, {BYTES[pre]})')
        else:
            raise Exception(u)
        r = '' if ret == 'void' else ' ' + CTYPE[ret]
        sig = ', '.join(f'{n}: {t}' for n, t in params)
        out.append('\n'.join('    ' + a for a in attrs) + f'\n    pub fn {u}({sig}){r};')
    out.append('}\n')
    return '\n'.join(out)



# ---- Gather, scatter ------------------------------------------------------------------------------------
# The indexes widen to 64 bits (`vpmovzxdq`): a 32-bit index from 2^31 would be negative in the
# 32-bit forms.
def fam_gather():
    def mask32(n):  # lane masks of `n` 32-bit lanes (n <= 4) from mask bits `m`
        lb, bt = lane_bits(W128, 32, 4, 'm')
        return bt, lb

    for t in ('i32', 'u32', 'f32', 'i64', 'u64', 'f64'):
        e = BITS[t]
        ps = isf(t)
        k = ('ps' if e == 32 else 'pd') if ps else f'epi{e}'
        for I in ('u32', 'u64'):
            # AVX2: 4 lanes of 32 bits, 2 or 4 of 64.
            for n in ((4, 8) if e == 32 else (2, 4)):
                V, X, mk = B(t, n), B(I, n), f'mask{n}'
                if e == 32:
                    g = f'_mm256_mask_i64gather_{k}'
                    pp = pc(g, 'p', '*const ' + t)
                    def one(src, idx, kk):
                        msk = f'_mm_castsi128_ps({kk})' if ps else kk
                        return f'{g}({src}, {pp}, {idx}, {msk}, 4)'
                    lb, bt = lane_bits(W128, 32, 4, 'm')
                    if n == 4:
                        idx = '_mm256_cvtepu32_epi64(xi(idx))' if I == 'u32' else 'yi(idx)'
                        body = f'let b = {bt};\nlet s = {lb};\nreturn {W128.st(t)}(unsafe {one(W128.ld(t) + "(fb)", idx, "s")});'
                    else:
                        if I == 'u32':
                            lo, hi = '_mm256_cvtepu32_epi64(_mm256_castsi256_si128(x))', '_mm256_cvtepu32_epi64(_mm256_extracti128_si256(x, 1))'
                            pre = 'let x = yi(idx);\n'
                        else:
                            lo, hi = 'yi(idx.low_half())', 'yi(idx.high_half())'
                            pre = ''
                        sl = lb.replace('set1_epi32(m as u64 as i32)', 'set1_epi32((m as u64 & 15) as i32)')
                        sh = lb.replace('set1_epi32(m as u64 as i32)', 'set1_epi32((m as u64 >> 4) as i32)')
                        rk = '_mm256_set_m128' if ps else '_mm256_set_m128i'
                        fl = f'{W128.ld(t)}(fb.low_half())'
                        fh = f'{W128.ld(t)}(fb.high_half())'
                        body = (pre + f'let b = {bt};\n'
                                f'let lo = unsafe {one(fl, lo, sl)};\nlet hi = unsafe {one(fh, hi, sh)};\n'
                                f'return {W256.st(t)}({rk}(hi, lo));')
                    entry('Gather', ['Avx2'], f'gather_{V}_{I}', f'p: *const {t}, idx: {X}, m: {mk}, fb: {V}', V, body)
                else:
                    w = W128 if n == 2 else W256
                    g = f'{w.p}_mask_i64gather_{k}'
                    pp = pc(g, 'p', '*const ' + t)
                    lb, bt = lane_bits(w, 64, n, 'm')
                    if n == 2:
                        idx = '_mm_cvtepu32_epi64(xli(idx))' if I == 'u32' else 'xi(idx)'
                    else:
                        idx = '_mm256_cvtepu32_epi64(xi(idx))' if I == 'u32' else 'yi(idx)'
                    msk = f'{w.p}_castsi{w.bits}_pd(s)' if ps else 's'
                    entry('Gather', ['Avx2'], f'gather_{V}_{I}', f'p: *const {t}, idx: {X}, m: {mk}, fb: {V}', V,
                          f'let b = {bt};\nlet s = {lb};\nreturn {w.st(t)}(unsafe {g}({w.ld(t)}(fb), {pp}, {idx}, {msk}, 8));')
            # AVX-512: 8 lanes per instruction, by the mask itself.
            for n in ((8, 16) if e == 32 else (8,)):
                if n == 16 and I == 'u64':
                    continue
                V, X, mk = B(t, n), B(I, n), f'mask{n}'
                g = f'_mm512_mask_i64gather_{k}'
                sc = f'_mm512_mask_i64scatter_{k}'
                wd = W256 if e == 32 else W512
                if n == 8:
                    idx = '_mm512_cvtepu32_epi64(yi(idx))' if I == 'u32' else 'zi(idx)'
                    entry('Gather', ['Avx512f'], f'gather_{V}_{I}', f'p: *const {t}, idx: {X}, m: {mk}, fb: {V}', V,
                          f'return {wd.st(t)}(unsafe {g}({wd.ld(t)}(fb), m as u64 as u8, {idx}, p, {e // 8}));')
                    entry('Scatter', ['Avx512f'], f'scatter_{V}_{I}', f'p: *mut {t}, idx: {X}, m: {mk}, v: {V}', '',
                          f'unsafe {sc}(p, m as u64 as u8, {idx}, {wd.ld(t)}(v), {e // 8});')
                else:
                    lo = '_mm512_cvtepu32_epi64(_mm512_castsi512_si256(x))'
                    hi = '_mm512_cvtepu32_epi64(_mm512_extracti64x4_epi64(x, 1))'
                    f = ['Avx512f']
                    entry('Gather', f, f'gather_{V}_{I}', f'p: *const {t}, idx: {X}, m: {mk}, fb: {V}', V,
                          f'let x = zi(idx);\n'
                          f'let lo = unsafe {g}({W256.ld(t)}(fb.low_half()), (m as u64 & 255) as u8, {lo}, p, 4);\n'
                          f'let hi = unsafe {g}({W256.ld(t)}(fb.high_half()), (m as u64 >> 8) as u8, {hi}, p, 4);\n'
                          + (f'return {W512.st(t)}(_mm512_castpd_ps(_mm512_insertf64x4(_mm512_castps_pd(_mm512_castps256_ps512(lo)), _mm256_castps_pd(hi), 1)));'
                           if ps else f'return {W512.st(t)}(_mm512_inserti64x4(_mm512_castsi256_si512(lo), hi, 1));'))
                    entry('Scatter', ['Avx512f'], f'scatter_{V}_{I}', f'p: *mut {t}, idx: {X}, m: {mk}, v: {V}', '',
                          f'let x = zi(idx);\n'
                          f'unsafe {sc}(p, (m as u64 & 255) as u8, {lo}, {W256.ld(t)}(v.low_half()), 4);\n'
                          f'unsafe {sc}(p, (m as u64 >> 8) as u8, {hi}, {W256.ld(t)}(v.high_half()), 4);')


# ---- 64-bit lanes before AVX-512 ------------------------------------------------------------------------
# SSE2 has no 64-bit comparison: a signed `x < y` is the sign of `(x - y) ^ ((x ^ y) & ((x - y) ^ x))`
# (the difference's sign, corrected on overflow), copied into both halves of the lane; an unsigned one
# flips the sign bits first. AVX2 (and SSE4.2 on 128 bits) compare with `cmpgt_epi64`.
def fam_i64_gaps():
    SG = '_mm_set1_epi64x(-9223372036854775807 - 1)'
    ALL = '_mm_set1_epi32(-1)'

    def lt(x, y):
        return (f'let d = _mm_sub_epi64({x}, {y});\n'
                f'let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128({x}, {y}), _mm_xor_si128(d, {x})));\n'
                f'let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);\n')

    for t in ('i64', 'u64'):
        V, U = f'{t}x2', 'u64x2'
        pre = ('let x = xi(a);\nlet y = xi(b);\n' if t == 'i64'
               else f'let x = _mm_xor_si128(xi(a), {SG});\nlet y = _mm_xor_si128(xi(b), {SG});\n')
        prm = f'a: {V}, b: {V}'
        entry('CmpEqLanes', ['Sse2'], f'cmp_eq_lanes_{V}', prm, U,
              'let c = _mm_cmpeq_epi32(xi(a), xi(b));\nreturn xiv::<u64, 2>(_mm_and_si128(c, _mm_shuffle_epi32(c, 177)));')
        entry('CmpNeLanes', ['Sse2'], f'cmp_ne_lanes_{V}', prm, U,
              f'let c = _mm_cmpeq_epi32(xi(a), xi(b));\nreturn xiv::<u64, 2>(_mm_xor_si128(_mm_and_si128(c, _mm_shuffle_epi32(c, 177)), {ALL}));')
        for op, nm, xs, ys, neg in (('CmpLtLanes', 'lt', 'x', 'y', False), ('CmpGtLanes', 'gt', 'y', 'x', False),
                                    ('CmpLeLanes', 'le', 'y', 'x', True), ('CmpGeLanes', 'ge', 'x', 'y', True)):
            r = f'_mm_xor_si128(m, {ALL})' if neg else 'm'
            entry(op, ['Sse2'], f'cmp_{nm}_lanes_{V}', prm, U, pre + lt(xs, ys) + f'return xiv::<u64, 2>({r});')
        for op, nm in (('Min', 'min'), ('Max', 'max')):
            pick = '_mm_or_si128(_mm_and_si128(m, xi(a)), _mm_andnot_si128(m, xi(b)))' if nm == 'min' else \
                   '_mm_or_si128(_mm_and_si128(m, xi(b)), _mm_andnot_si128(m, xi(a)))'
            entry(op, ['Sse2'], f'{nm}_{V}', prm, V, pre + lt('x', 'y') + f'return xiv::<{t}, 2>({pick});')
        # |a - b|: the smaller operand subtracted from the larger.
        entry('AbsDiff', ['Sse2'], f'abs_diff_{V}', prm, U, pre + lt('x', 'y')
              + 'let p = _mm_sub_epi64(xi(a), xi(b));\nlet q = _mm_sub_epi64(xi(b), xi(a));\n'
              + 'return xiv::<u64, 2>(_mm_or_si128(_mm_and_si128(m, q), _mm_andnot_si128(m, p)));')
        if t == 'i64':
            entry('WrappingAbs', ['Sse2'], f'wrapping_abs_{V}', f'a: {V}', V,
                  'let x = xi(a);\nlet s = _mm_shuffle_epi32(_mm_srai_epi32(x, 31), 245);\n'
                  'return xiv::<i64, 2>(_mm_sub_epi64(_mm_xor_si128(x, s), s));')
    for w, f in ((W128, 'Sse42'), (W256, 'Avx2')):
        P, n, h = w.p, w.bits // 64, w.h
        Z = f'{P}_setzero_{w.si}()'
        SGW = f'{P}_set1_epi64x(-9223372036854775807 - 1)'
        for t in ('i64', 'u64'):
            V, U = f'{t}x{n}', f'u64x{n}'
            prm = f'a: {V}, b: {V}'
            x, y = (f'{h}i(a)', f'{h}i(b)') if t == 'i64' else (f'{P}_xor_{w.si}({h}i(a), {SGW})', f'{P}_xor_{w.si}({h}i(b), {SGW})')
            entry('AbsDiff', [f], f'abs_diff_{V}', prm, U,
                  f'let m = {P}_cmpgt_epi64({y}, {x});\nlet p = {P}_sub_epi64({h}i(a), {h}i(b));\nlet q = {P}_sub_epi64({h}i(b), {h}i(a));\n'
                  f'return {h}iv::<u64, {n}>({P}_or_{w.si}({P}_and_{w.si}(m, q), {P}_andnot_{w.si}(m, p)));')
        V = f'i64x{n}'
        entry('WrappingAbs', [f], f'wrapping_abs_{V}', f'a: {V}', V,
              f'let x = {h}i(a);\nlet s = {P}_cmpgt_epi64({Z}, x);\nreturn {h}iv::<i64, {n}>({P}_sub_epi64({P}_xor_{w.si}(x, s), s));')
        # An arithmetic shift by lane counts: the logical one of the value with its sign flipped away.
        entry('WrappingShr', ['Avx2'], f'wrapping_shr_{V}', f'a: {V}, n: {V}', V,
              f'let x = {h}i(a);\nlet s = {P}_cmpgt_epi64({Z}, x);\nlet c = {P}_and_{w.si}({h}i(n), {P}_set1_epi64x(63));\n'
              f'return {h}iv::<i64, {n}>({P}_xor_{w.si}({P}_srlv_epi64({P}_xor_{w.si}(x, s), c), s));')


# ---- AVX10.2 VMINMAX ----------------------------------------------------------------------------------
# imm8[1:0] picks minimum or maximum; imm8[3:2] = 01 keeps the chosen operand's sign (00 would take the
# first source's); imm8[4] the IEEE 754-2019 number forms (`minimumNumber`: a NaN operand yields the
# other) over the NaN-propagating ones; both order -0 below +0 (GCC's avx10-minmax-helper.h model).
for _w in ('_mm', '_mm256', '_mm512'):
    _r = {'_mm': '__m128', '_mm256': '__m256', '_mm512': '__m512'}[_w]
    for _s, _t in (('ps', ''), ('pd', 'd')):
        PROTOS[f'{_w}_minmax_{_s}'] = {'ret': _r + _t, 'params': f'{_r}{_t} __A, {_r}{_t} __B, const int __C',
                                       'target': ['avx10.2']}
        IMM.add(f'{_w}_minmax_{_s}')


def fam_minmax_avx10():
    for w in WS:
        for t in ('f32', 'f64'):
            n = w.n(t)
            V = B(t, n)
            for op, nm, imm in (('Min', 'min_num', 20), ('Max', 'max_num', 21), ('Minimum', 'minimum', 4),
                                ('Maximum', 'maximum', 5)):
                entry(op, ['Avx102'], f'{nm}_{V}', f'a: {V}, b: {V}', V,
                      f'return {w.st(t)}({w.p}_minmax_{w.ps(t)}({w.ld(t)}(a), {w.ld(t)}(b), {imm}));')


if __name__ == '__main__':
    main()
