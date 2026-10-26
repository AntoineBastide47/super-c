#!/usr/bin/env python3
# Derives the intrinsic templates of src/target/a64intrin.spc, x64intrin.spc and wasmintrin.spc from
# clang's code for a one-call wrapper of each intrinsic the bindings (ffi/arm_neon.spc,
# ffi/immintrin.spc, ffi/wasm_simd128.spc) declare. Run from the repository root with an LLVM clang
# (CLANG, else the Homebrew one, else `clang` in PATH), then emit.py; x64rows.py derives the x64tab rows
# the x86-64 templates need:
#
#   python3 scripts/intrin/gen.py a64 build/intrin/a64.json
#   python3 scripts/intrin/emit.py a64 build/intrin/a64.json src/target/a64intrin.spc
#   ./super-c fmt src/target/a64intrin.spc
#   python3 scripts/intrin/x64rows.py build/intrin/x64.json src/target/x64tab.spc > build/intrin/rows.txt
#
# A constant argument becomes `{k}` or `{k*a+b}`: the numbers that follow it linearly over candidate
# values, checked on every value to twice the largest. Compiles are cached in build/intrin/<isa>.
import re, subprocess, sys, os, json, itertools, hashlib

ISA = sys.argv[1]
OUT = sys.argv[2]
ROOT = os.getcwd()
FFI = {'a64': 'ffi/arm_neon.spc', 'x64': 'ffi/immintrin.spc', 'wasm': 'ffi/wasm_simd128.spc'}[ISA]
HDR = {'a64': 'arm_neon.h', 'x64': 'immintrin.h', 'wasm': 'wasm_simd128.h'}[ISA]
CLANG = os.environ.get('CLANG', '/opt/homebrew/opt/llvm/bin/clang')
if not os.path.exists(CLANG):
    CLANG = 'clang'
WORK = os.path.join(ROOT, 'build', 'intrin', ISA)
os.makedirs(WORK, exist_ok=True)

X86_FEAT = {
    'Sse2': 'sse2', 'Sse41': 'sse4.1', 'Sse42': 'sse4.2', 'Ssse3': 'ssse3', 'Avx': 'avx', 'Avx2': 'avx2',
    'Fma': 'fma', 'Avx512f': 'avx512f', 'Avx512vl': 'avx512vl', 'Avx512bw': 'avx512bw', 'Avx512dq': 'avx512dq',
    'Avx512cd': 'avx512cd', 'Avx512vbmi': 'avx512vbmi', 'Avx512vbmi2': 'avx512vbmi2', 'Avx512vnni': 'avx512vnni',
    'Avx512bitalg': 'avx512bitalg', 'Avx512vpopcntdq': 'avx512vpopcntdq', 'Vaes': 'vaes', 'Gfni': 'gfni',
    'Aesni': 'aes', 'Pclmulqdq': 'pclmul', 'Avx102': 'avx10.2',
}

def parse_bindings():
    src = open(os.path.join(ROOT, FFI)).read()
    out = []
    feats = []
    hdr = HDR
    for line in src.split('\n'):
        t = line.strip()
        m = re.match(r'^extern "C" "([^"]+)"', t)
        if m:
            hdr = m.group(1)
            continue
        m = re.match(r'@target_feature\(\[(.*)\]\)', t)
        if m:
            feats = re.findall(r'cpu::Feature::(\w+)', m.group(1))
            continue
        m = re.match(r'pub fn (\w+)\((.*)\)\s*([^;]*);', t)
        if m:
            name, ps, ret = m.group(1), m.group(2).strip(), m.group(3).strip()
            params = []
            if ps:
                for p in ps.split(','):
                    pn, pt = p.split(':', 1)
                    params.append((pn.strip(), pt.strip()))
            out.append({'name': name, 'params': params, 'ret': ret, 'feats': feats, 'hdr': hdr})
            feats = []
    return out

SCALAR = {'i8': 'int8_t', 'i16': 'int16_t', 'i32': 'int32_t', 'i64': 'int64_t', 'u8': 'uint8_t', 'u16': 'uint16_t',
          'u32': 'uint32_t', 'u64': 'uint64_t', 'f32': 'float', 'f64': 'double', 'bool': '_Bool', 'usize': 'size_t',
          'isize': 'ptrdiff_t', 'void': 'void', 'char': 'char'}
INTS = {'i8', 'i16', 'i32', 'i64', 'u8', 'u16', 'u32', 'u64', 'usize', 'isize'}

def ctype(t):
    t = t.strip()
    if t.startswith('*const '):
        return 'const ' + ctype(t[7:]) + ' *'
    if t.startswith('*mut '):
        return ctype(t[5:]) + ' *'
    return SCALAR.get(t, t)

def wrapper(b, consts):
    ps = []
    args = []
    for k, (pn, pt) in enumerate(b['params']):
        ps.append('%s p%d' % (ctype(pt), k))
        args.append(str(consts[k]) if k in consts else 'p%d' % k)
    ret = ctype(b['ret']) if b['ret'] else 'void'
    attr = ''
    if ISA == 'x64':
        # The features on the command line: the calling convention passes a 256- or 512-bit vector in a
        # register only when the whole unit has them.
        fs = [X86_FEAT[f] for f in b['feats'] if f in X86_FEAT]
        attr = '/* -m%s */ ' % ' -m'.join(fs) if fs else ''
    call = '%s(%s)' % (b['name'], ', '.join(args))
    body = ('return %s;' % call) if ret != 'void' else ('%s;' % call)
    return '#include <stdint.h>\n#include <stddef.h>\n#include <%s>\n%s%s w(%s) { %s }\n' % (b['hdr'], attr, ret, ', '.join(ps) if ps else 'void', body)

def flags():
    if ISA == 'a64':
        return ['--target=aarch64-linux-gnu', '-march=armv8.2-a+aes+sha2+sha3+crc+rdm+dotprod+i8mm']
    if ISA == 'x64':
        return ['--target=x86_64-linux-gnu']
    return ['--target=wasm32-wasip1', '-msimd128', '-mrelaxed-simd']

def compile_(text):
    h = hashlib.sha1(text.encode()).hexdigest()[:16]
    cp = os.path.join(WORK, h + '.c')
    sp = os.path.join(WORK, h + '.s')
    ep = os.path.join(WORK, h + '.err')
    if not os.path.exists(sp) and not os.path.exists(ep):
        open(cp, 'w').write(text)
        mf = []
        m = re.search(r'/\* (-m[^*]*) \*/', text)
        if m:
            mf = m.group(1).split()
        r = subprocess.run([CLANG] + flags() + mf + ['-ffreestanding', '-O1', '-S', '-fno-asynchronous-unwind-tables', '-o', sp, cp], capture_output=True, text=True)
        if r.returncode != 0:
            open(ep, 'w').write(r.stderr)
            if os.path.exists(sp):
                os.remove(sp)
    if os.path.exists(ep):
        return None, open(ep).read()
    return open(sp).read(), ''

def body_lines(asm):
    lines = asm.split('\n')
    out = []
    data = {}
    inside = False
    cur_lbl = None
    for ln in lines:
        s = ln.split('//')[0].rstrip() if ISA == 'a64' else ln.split('#')[0].rstrip()
        st = s.strip()
        if not st:
            continue
        if re.match(r'^_?w:', st):
            inside = True
            continue
        if ISA == 'wasm' and st.startswith('.functype'):
            continue
        if inside:
            if st.startswith('.Lfunc_end') or st == 'end_function':
                inside = False
                continue
            if st.startswith('.cfi') or st.startswith('.p2align'):
                continue
            if ISA == 'wasm' and st.startswith('.local'):
                out.append(st)
                continue
            if st.startswith('.'):
                out.append('!' + st)
                continue
            # The wrapper's `vzeroupper` before its return: inline, it would clear the vectors live across
            # the call.
            if st in ('ret', 'retq', 'vzeroupper'):
                continue
            out.append(canon(stack_args(re.sub(r'\s+', ' ', st))))
        else:
            m = re.match(r'^(\.LCPI\w+):', st)
            if m:
                cur_lbl = m.group(1)
                data[cur_lbl] = []
                continue
            if cur_lbl and re.match(r'^\.(byte|short|hword|word|long|quad|xword|zero|4byte|8byte|2byte)\b', st):
                data[cur_lbl].append(st)
                continue
            if st.startswith('.section') or st.startswith('.text') or st.startswith('.p2align') or st.startswith('.size') or st.startswith('.type') or st.startswith('.globl'):
                if not st.startswith('.p2align'):
                    cur_lbl = None
                continue
    return out, data

ICMP = ['eq', 'lt', 'le', 'false', 'neq', 'nlt', 'nle', 'true']
FCMP = ['eq', 'lt', 'le', 'unord', 'neq', 'nlt', 'nle', 'ord', 'eq_uq', 'nge', 'ngt', 'false', 'neq_oq', 'ge', 'gt', 'true',
        'eq_os', 'lt_oq', 'le_oq', 'unord_s', 'neq_us', 'nlt_uq', 'nle_uq', 'ord_s', 'eq_us', 'nge_uq', 'ngt_uq', 'false_os',
        'neq_os', 'ge_oq', 'gt_oq', 'true_us']

# An x86 compare's predicate alias (`vpcmpltd`, `vcmpleps`) as the base form with the predicate immediate.
def canon(line):
    if ISA != 'x64':
        return line
    m = re.match(r'^(v?)(p?)cmp([a-z_]+?)(ps|pd|ss|sd|ub|uw|ud|uq|b|w|d|q) (.*)$', line)
    if not m:
        return line
    v, p, pred, sfx, ops = m.groups()
    if p:
        # `vpcmpeqd` and `vpcmpgtd` with a vector result are instructions of their own.
        if not v or pred not in ICMP or not re.search(r'%k\d$', ops):
            return line
        return '%spcmp%s $%d, %s' % (v, sfx, ICMP.index(pred), ops)
    if pred not in FCMP or sfx not in ('ps', 'pd', 'ss', 'sd'):
        return line
    return '%scmp%s $%d, %s' % (v, sfx, FCMP.index(pred), ops)

# The SysV stack arguments 7 and 8 (both 32-bit here) as the registers the intrinsic layout gives them.
def stack_args(line):
    if ISA != 'x64' or '(%rsp)' not in line:
        return line
    assert re.match(r'^v?(movd|pinsrd) ', line), line
    return line.replace('8(%rsp)', '%r10d').replace('16(%rsp)', '%r11d')

NUM = re.compile(r'(-?0x[0-9a-fA-F]+|-?\d+)')

def tokens(lines):
    return [NUM.split(l) for l in lines]

def candidates(n_imm):
    base = [[1, 2, 3], [2, 3, 4], [0, 1, 2], [2, 4, 8], [1, 2], [0, 1], [4, 8, 12], [8, 16, 24], [16, 32, 48], [0, 2, 4]]
    return base

def is_int(t):
    return t in INTS

# Whether fit `fit` of the numbers of token form `t0` holds for every value of immediate `k` to twice the
# candidates' largest whose code has that form (a value of another form takes other instructions; a value
# past the operand's range is undefined, which twice the candidates may reach: a lane past the last).
def verify(b, fixed, k, t0, fit, top):
    for v in range(0, 2 * top + 2):
        consts = dict(fixed)
        consts[k] = v
        a2, e2 = compile_(wrapper(b, consts))
        if a2 is None:
            continue
        t = tokens(body_lines(a2)[0])
        if len(t) != len(t0) or any(len(x) != len(y) for x, y in zip(t, t0)):
            continue
        for li in range(len(t0)):
            for ti in range(len(t0[li])):
                if (li, ti) in fit:
                    a, bb = fit[(li, ti)]
                    if int(t[li][ti], 0) != a * v + bb:
                        return False
                elif t[li][ti] != t0[li][ti] and ti % 2 == 1:
                    return False
    return True

# Templates clang's code cannot give: the immediate selector of carry-less multiplication, whose bits other
# than 0 and 4 clang clears (the instruction ignores them).
OVERRIDE = {'_mm_clmulepi64_si128': ['pclmulqdq ${2}, %xmm1, %xmm0']}

def derive(b):
    if b['name'] in OVERRIDE:
        return {'name': b['name'], 'asm': OVERRIDE[b['name']], 'data': {}, 'imms': [2]}
    ints = [k for k, (pn, pt) in enumerate(b['params']) if is_int(pt)]
    asm, err = compile_(wrapper(b, {}))
    imms = []
    if asm is None:
        found = False
        for r in range(1, len(ints) + 1):
            for combo in itertools.combinations(ints, r):
                for vals in ([1] * r, [0] * r, [2] * r):
                    a2, e2 = compile_(wrapper(b, dict(zip(combo, vals))))
                    if a2 is not None:
                        imms = list(combo)
                        found = True
                        break
                if found:
                    break
            if found:
                break
        if not found:
            return {'name': b['name'], 'error': err.strip().split('\n')[0]}
    if not imms:
        lines, data = body_lines(asm)
        return {'name': b['name'], 'asm': lines, 'data': data, 'imms': []}
    # One immediate at a time: the others at a fixed valid value.
    fixed = {}
    for k in imms:
        for v in (1, 0, 2):
            cs = {j: 1 for j in imms}
            cs[k] = v
            if compile_(wrapper(b, cs))[0] is not None:
                fixed[k] = v
                break
    tmpl = None
    for k in imms:
        got = None
        for cand in candidates(len(imms)):
            outs = []
            ok = True
            for v in cand:
                consts = dict(fixed)
                consts[k] = v
                a2, e2 = compile_(wrapper(b, consts))
                if a2 is None:
                    ok = False
                    break
                outs.append(body_lines(a2))
            if not ok or len(outs) < 2:
                continue
            ts = [tokens(o[0]) for o in outs]
            if any(len(t) != len(ts[0]) or any(len(x) != len(y) for x, y in zip(t, ts[0])) for t in ts):
                continue
            # The positions where the numbers differ: a linear function of v.
            fit = {}
            good = True
            for li in range(len(ts[0])):
                for ti in range(len(ts[0][li])):
                    vs = [t[li][ti] for t in ts]
                    if len(set(vs)) == 1:
                        continue
                    if ti % 2 == 0:
                        good = False
                        break
                    ys = [int(x, 0) for x in vs]
                    a = (ys[1] - ys[0]) // (cand[1] - cand[0]) if cand[1] != cand[0] else 0
                    bb = ys[0] - a * cand[0]
                    if any(a * cand[i] + bb != ys[i] for i in range(len(cand))):
                        good = False
                        break
                    fit[(li, ti)] = (a, bb)
                if not good:
                    break
            # An immediate the code ignores is a value out of range (undefined): another candidate.
            if good and fit and verify(b, fixed, k, ts[0], fit, max(cand)):
                got = (ts[0], fit, outs[0][1], cand[0])
                break
        if got is None:
            # One valid non-zero value: a lane index `[v]` is the value itself (a lane-0 form differs).
            consts = dict(fixed)
            consts[k] = 1
            a2, e2 = compile_(wrapper(b, consts))
            if a2 is not None:
                o = body_lines(a2)
                t0 = tokens(o[0])
                fit = {}
                for li in range(len(t0)):
                    for ti in range(1, len(t0[li]), 2):
                        if t0[li][ti] == '1' and (t0[li][ti - 1].endswith('[') and t0[li][ti + 1].startswith(']') or t0[li][ti - 1].endswith('$')):
                            fit[(li, ti)] = (1, 0)
                if len(fit) == 1:
                    got = (t0, fit, o[1], 1)
        if got is None:
            return {'name': b['name'], 'error': 'no consistent immediate form for param %d' % k}
        if tmpl is None:
            tmpl = [list(x) for x in got[0]]
            data = got[2]
        for (li, ti), (a, bb) in got[1].items():
            if a == 1 and bb == 0:
                tmpl[li][ti] = '{%d}' % k
            else:
                tmpl[li][ti] = '{%d*%d%+d}' % (k, a, bb)
    lines = [''.join(x) for x in tmpl]
    return {'name': b['name'], 'asm': lines, 'data': data, 'imms': imms}

def main():
    bs = parse_bindings()
    res = []
    for b in bs:
        r = derive(b)
        if ISA == 'wasm' and 'asm' in r:
            # The wrapper's wasm signature: the argument and result types the instructions take.
            a, e = compile_(wrapper(b, {k: 1 for k in r['imms']}))
            m = re.search(r'\.functype\s+w\s+(\(.*)', a)
            r['sig'] = m.group(1).strip()
        res.append(r)
    json.dump(res, open(OUT, 'w'), indent=1)
    bad = [r for r in res if 'error' in r]
    print('rows', len(res), 'errors', len(bad))
    for r in bad[:40]:
        print(r['name'], r['error'])

main()
