#!/usr/bin/env python3
# Derives the x64tab rows of every instruction form the x86-64 intrinsic templates use (and the moves
# the code generator emits) from llvm-mc's encodings: the opcode, prefix, map, W, L, the field of each
# operand, the EVEX displacement scale, masking, and the operand swaps LLVM takes for a 2-byte VEX
# prefix. Prints the rows the table lacks (LLVM_MC, else the Homebrew llvm-mc, else `llvm-mc`).
# usage: x64rows.py x64.json src/target/x64tab.spc > rows.txt
import json, os, re, subprocess, sys

MC = os.environ.get('LLVM_MC', '/opt/homebrew/opt/llvm/bin/llvm-mc')
if not os.path.exists(MC):
    MC = 'llvm-mc'
ATTR = '+avx512f,+avx512vl,+avx512bw,+avx512dq,+avx512cd,+avx512vbmi,+avx512vbmi2,+avx512vnni,+avx512bitalg,+avx512vpopcntdq,+vaes,+gfni,+aes,+pclmul,+avx2,+fma,+avx10.2,+sse4.2,+ssse3'

def mc(lines):
    """Encode each line; None for the ones llvm-mc rejects."""
    src = '\n'.join(lines) + '\n'
    r = subprocess.run([MC, '-triple=x86_64', '-mattr=' + ATTR, '-show-encoding'], input=src, capture_output=True, text=True)
    bad = set()
    for l in r.stderr.split('\n'):
        m = re.match(r'<stdin>:(\d+):\d+: (error|warning)', l)
        if m:
            bad.add(int(m.group(1)) - 1)
    encs = []
    for l in r.stdout.split('\n'):
        m = re.search(r'# encoding: \[([^\]]*)\]', l)
        if m:
            encs.append([int(x, 16) for x in m.group(1).split(',')])
    out = []
    k = 0
    for i in range(len(lines)):
        if i in bad:
            out.append(None)
        else:
            out.append(encs[k])
            k += 1
    assert k == len(encs), (k, len(encs))
    return out

def dis(b):
    """The mnemonic and operands llvm-mc disassembles bytes `b` to, None for none."""
    r = subprocess.run([MC, '-triple=x86_64', '-mattr=' + ATTR, '--disassemble'], input=' '.join('0x%02x' % x for x in b) + '\n', capture_output=True, text=True)
    for l in r.stdout.split('\n'):
        l = l.strip()
        if l and not l.startswith('.'):
            mn, _, ops = l.partition('\t')
            return mn.strip(), ops.strip()
    return None

def decode(b):
    """The fields of one encoding."""
    f = {'pfx': 0, 'rexw': 0, 'enc': 0, 'W': 0, 'L': 0, 'vvvv': 0, 'R': 0, 'X': 0, 'B': 0, 'aaa': 0, 'z': 0, 'map': 0}
    p = 0
    while b[p] in (0x66, 0xF2, 0xF3):
        f['pfx'] = b[p]
        p += 1
    if b[p] & 0xF0 == 0x40:
        r = b[p]
        f['rexw'], f['R'], f['X'], f['B'] = r >> 3 & 1, r >> 2 & 1, r >> 1 & 1, r & 1
        p += 1
    pp = {0: 0, 1: 0x66, 2: 0xF3, 3: 0xF2}
    if b[p] == 0xC5:
        f['enc'] = 1
        b1 = b[p + 1]
        f['R'] = 1 - (b1 >> 7)
        f['vvvv'] = (~b1 >> 3) & 15
        f['L'] = b1 >> 2 & 1
        f['pfx'] = pp[b1 & 3]
        f['map'] = 1
        p += 2
    elif b[p] == 0xC4:
        f['enc'] = 1
        b1, b2 = b[p + 1], b[p + 2]
        f['R'], f['X'], f['B'] = 1 - (b1 >> 7), 1 - (b1 >> 6 & 1), 1 - (b1 >> 5 & 1)
        f['map'] = b1 & 31
        f['W'] = b2 >> 7
        f['vvvv'] = (~b2 >> 3) & 15
        f['L'] = b2 >> 2 & 1
        f['pfx'] = pp[b2 & 3]
        p += 3
    elif b[p] == 0x62:
        f['enc'] = 2
        p0, p1, p2 = b[p + 1], b[p + 2], b[p + 3]
        f['R'], f['X'], f['B'] = 1 - (p0 >> 7), 1 - (p0 >> 6 & 1), 1 - (p0 >> 5 & 1)
        f['map'] = p0 & 7
        f['W'] = p1 >> 7
        f['vvvv'] = (~p1 >> 3) & 15
        f['pfx'] = pp[p1 & 3]
        f['z'] = p2 >> 7
        f['L'] = p2 >> 5 & 3
        f['aaa'] = p2 & 7
        assert p0 >> 4 & 1 == 1 and p2 >> 3 & 1 == 1 and p2 >> 4 & 1 == 0, b
        p += 4
    if f['enc']:
        op = b[p]
        p += 1
        f['oplen'] = p
        f['op'] = {1: 0x0F00, 2: 0x0F3800, 3: 0x0F3A00}[f['map']] | op
    else:
        if b[p] == 0x0F:
            if b[p + 1] in (0x38, 0x3A):
                f['op'] = 0x0F0000 | b[p + 1] << 8 | b[p + 2]
                p += 3
            else:
                f['op'] = 0x0F00 | b[p + 1]
                p += 2
        else:
            f['op'] = b[p]
            p += 1
        f['oplen'] = p
    if p >= len(b):
        f['mod'] = f['reg'] = f['rm'] = None
        f['sib'] = f['disp8'] = None
        f['rest'] = []
        return f
    m = b[p]
    p += 1
    f['mod'], f['reg'], f['rm'] = m >> 6, (m >> 3 & 7) | f['R'] << 3, (m & 7) | f['B'] << 3
    f['sib'] = None
    if f['mod'] != 3 and m & 7 == 4:
        f['sib'] = b[p]
        p += 1
    f['disp8'] = None
    if f['mod'] == 1:
        f['disp8'] = b[p] if b[p] < 128 else b[p] - 256
        p += 1
    elif f['mod'] == 2:
        p += 4
    f['rest'] = b[p:]
    return f

GP32 = ['eax', 'ecx', 'edx', 'ebx', 'esp', 'ebp', 'esi', 'edi']
GP64 = ['rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi']

def classify(o):
    o = o.strip()
    m = re.fullmatch(r'%([xyz])mm(\d+)', o)
    if m:
        return (m.group(1), int(m.group(2)))
    m = re.fullmatch(r'%k(\d)', o)
    if m:
        return ('k', int(m.group(1)))
    if re.fullmatch(r'%(e[a-d]x|e[sd]i|r\d+d)', o):
        return ('g32', 0)
    if re.fullmatch(r'%(r[a-d]x|r[sd]i|r\d+)', o):
        return ('g64', 0)
    if o.startswith('$'):
        return ('imm', 0)
    m = re.fullmatch(r'\(%r\w+,%([xyz])mm\d+,[^)]*\)', o)
    if m:
        return ('vsib' + m.group(1), 0)
    if o.startswith('(') or re.match(r'-?\d+\(', o):
        return ('mem', 0)
    raise Exception('operand ' + o)

def split_ops(s):
    out, depth, cur = [], 0, ''
    for c in s:
        if c == '(':
            depth += 1
        if c == ')':
            depth -= 1
        if c == ',' and depth == 0:
            out.append(cur)
            cur = ''
        else:
            cur += c
    if cur.strip():
        out.append(cur)
    return [x.strip() for x in out]

def parse_line(l):
    mn, _, rest = l.partition(' ')
    mask = re.search(r'\{%k(\d)\}', rest) is not None
    zero = '{z}' in rest
    rest = re.sub(r'\s*\{%k\d\}|\s*\{z\}', '', rest)
    ops = [classify(o) for o in split_ops(rest)] if rest.strip() else []
    return mn, ops, mask, zero

def text(mn, ops, nums, mask, zero, memrep=None):
    """AT&T text of shape `ops` (AT&T order) with register numbers `nums`."""
    parts = []
    for i, (c, n0) in enumerate(ops):
        n = nums[i]
        if memrep is not None and i == memrep[0]:
            parts.append(memrep[1])
            continue
        if c in ('x', 'y', 'z'):
            parts.append('%%%smm%d' % (c, n))
        elif c == 'x0':
            parts.append('%xmm0')
        elif c == 'k':
            parts.append('%%k%d' % n)
        elif c == 'g32':
            parts.append('%' + GP32[n])
        elif c == 'g64':
            parts.append('%' + GP64[n])
        elif c == 'imm':
            parts.append('$1')
        elif c == 'mem':
            parts.append('64(%rax)')
        elif c.startswith('vsib'):
            parts.append('64(%%rax,%%%smm%d,4)' % (c[4], n))
    s = mn + ' ' + ', '.join(parts)
    if mask:
        s += ' {%k1}'
    if zero:
        s += ' {z}'
    return s

def numbering(ops, base):
    nums = []
    k = 0
    for c, n0 in ops:
        if c == 'x0':
            nums.append(0)
        else:
            nums.append(base[k])
            k += 1
    return nums

N1 = [1, 2, 3, 5, 6]
N2 = [3, 5, 6, 7, 1]

def kind_of(c, field, regonly):
    if c == 'x0':
        return 'X0'
    if field == 'is4':
        return {'x': 'XI4', 'y': 'YI4'}[c]
    if c == 'imm':
        return 'I8'
    if c.startswith('vsib'):
        return 'VS' + c[4].upper()
    if field == 'vvvv':
        return {'x': 'XV', 'y': 'YV', 'z': 'ZV', 'k': 'KV'}[c]
    if field == 'reg':
        return {'x': 'X', 'y': 'Y', 'z': 'Z', 'k': 'KR', 'g32': 'R32', 'g64': 'R64'}[c]
    assert field == 'rm', (c, field)
    if c == 'mem':
        return regonly  # the memory form's class, chosen by the caller
    if regonly is True:
        return {'x': 'XR', 'y': 'YR', 'z': 'ZR', 'k': 'KRM', 'g32': 'RR32', 'g64': 'RR64'}[c]
    return {'x': 'XM', 'y': 'YM', 'z': 'ZM', 'g32': 'RM32', 'g64': 'RM64'}[c]

def same_op(a, b):
    return a is not None and b is not None and all(a[k] == b[k] for k in ('enc', 'op', 'pfx', 'W', 'L', 'map', 'rexw'))

def derive(mn, ops, mask, zero):
    """Rows (as dicts) for one shape; ops in AT&T order."""
    t1 = text(mn, ops, numbering(ops, N1), mask, zero)
    t2 = text(mn, ops, numbering(ops, N2), mask, zero)
    e1, e2 = mc([t1, t2])
    if e1 is None:
        return None, 'llvm-mc rejects ' + t1
    f1, f2 = decode(e1), decode(e2)
    n1, n2 = numbering(ops, N1), numbering(ops, N2)
    fields = []
    digit = None
    used = set()
    for i, (c, _) in enumerate(ops):
        if c in ('imm', 'x0'):
            fields.append(None)
            continue
        if c in ('mem',) or c.startswith('vsib'):
            fields.append('rm')
            used.add('rm')
            continue
        cand = []
        for fld in ('reg', 'rm', 'vvvv', 'is4'):
            if fld in used:
                continue
            def val(f):
                if fld == 'reg':
                    return f['reg']
                if fld == 'rm':
                    return f['rm'] if f['mod'] == 3 else None
                if fld == 'vvvv':
                    return f['vvvv']
                return f['rest'][-1] >> 4 if f['rest'] else None
            if val(f1) == n1[i] and val(f2) == n2[i]:
                cand.append(fld)
        if len(cand) != 1:
            return None, 'ambiguous field for operand %d of %s: %s' % (i, t1, cand)
        fields.append(cand[0])
        used.add(cand[0])
    if f1['mod'] is None:
        digit = 'N'
    elif 'reg' not in used:
        assert f1['reg'] == f2['reg']
        digit = f1['reg'] & 7
    if 'vvvv' not in used and f1['enc']:
        assert f1['vvvv'] == 0, t1
    # The rm operand: register only, or also memory (its disp8 scale).
    rmi = fields.index('rm') if 'rm' in fields else None
    N = None
    kinds = [None] * len(ops)
    if rmi is not None:
        c = ops[rmi][0]
        if c == 'mem' or c.startswith('vsib'):
            fm = f1
            # The register class the memory form shares its row with.
            mclass = 'M'
            if c == 'mem':
                # The register form of these bytes, if the instruction has one: its class.
                rb = e1[:f1['oplen']] + [0xC0 | (f1['reg'] & 7) << 3 | 2] + f1['rest']
                d = dis(rb)
                if d is not None and d[0] == mn:
                    dops = split_ops(re.sub(r'\s*\{%k\d\}|\s*\{z\}', '', d[1]))
                    rc = classify(dops[rmi])[0]
                    mclass = {'x': 'XM', 'y': 'YM', 'z': 'ZM', 'g32': 'RM32', 'g64': 'RM64'}[rc]
            kinds[rmi] = mclass if c == 'mem' else kind_of(c, 'rm', None)
        else:
            t3 = text(mn, ops, numbering(ops, N1), mask, zero, (rmi, '64(%rax)'))
            e3 = mc([t3])[0]
            fm = decode(e3) if e3 is not None else None
            regonly = not same_op(fm, f1)
            kinds[rmi] = kind_of(c, 'rm', regonly)
            if regonly:
                fm = None
        if fm is not None and f1['enc'] == 2:
            d = fm['disp8']
            assert d is not None and 64 % d == 0, (t1, d)
            N = 64 // d
    for i, (c, _) in enumerate(ops):
        if kinds[i] is None:
            kinds[i] = kind_of(c, fields[i], None) if fields[i] else ('I8' if c == 'imm' else 'X0')
    # The flags of masking.
    mk = mz = mr = False
    if f1['enc'] == 2:
        base = [text(mn, ops, numbering(ops, N1), m, z) for m, z in ((True, False), (True, True), (False, False))]
        em = mc(base)
        mk = em[0] is not None and same_op(decode(em[0]), f1)
        mz = em[1] is not None and same_op(decode(em[1]), f1)
        mr = em[2] is None
    # The other operand order llvm-mc takes for a 2-byte VEX prefix: the sources of a commutative
    # operation (for a compare, of some predicates), the other row of a move.
    sw = swc = mv = False
    ik = list(reversed(kinds))
    if f1['enc'] == 1 and ik[:3] in (['X', 'XV', 'XM'], ['Y', 'YV', 'YM']) and len(ik) in (3, 4):
        c = ik[0].lower()
        def sw_at(imm):
            pre = '$%d, ' % imm if len(ik) == 4 else ''
            e = mc(['%s %s%%%smm8, %%%smm1, %%%smm2' % (mn, pre, c, c, c)])[0]
            return e is not None and decode(e)['vvvv'] == 8
        if len(ik) == 3 or ik[3] == 'I8':
            if sw_at(0):
                sw = True
                if len(ik) == 4 and not sw_at(1):
                    swc = True
    if f1['enc'] == 1 and ik in (['X', 'XM'], ['Y', 'YM']):
        c = ik[0].lower()
        e = mc(['%s %%%smm8, %%%smm1' % (mn, c, c)])[0]
        mv = e is not None and decode(e)['op'] != f1['op']
    return {'sw': sw, 'swc': swc, 'mv': mv, 'mn': mn, 'op': f1['op'], 'pfx': f1['pfx'], 'digit': digit, 'enc': f1['enc'], 'W': f1['W'] or f1['rexw'],
            'L': f1['L'], 'N': N, 'mk': mk, 'mz': mz, 'mr': mr, 'kinds': list(reversed(kinds)), 'rexw': f1['rexw'], 'text': t1}, None

def ncode(N, L, enc):
    if enc != 2 or N is None:
        return 0
    vl = 16 << L
    for c in range(4):
        if vl >> c == N:
            return c
    return {1: 4, 2: 5, 4: 6, 8: 7, 16: 8, 32: 9}[N]

def row_text(r):
    d = 'D' if r['digit'] is None else str(r['digit'])
    ks = ', '.join('K::' + k for k in r['kinds'])
    kf = 'k%d(%s)' % (len(r['kinds']), ks) if r['kinds'] else '0'
    if r['enc'] == 0:
        if any(k.startswith('R') for k in r['kinds']):
            return None  # the sized general-register rows the table holds
        pf = '0x%X' % r['pfx'] if r['pfx'] else '0'
        return '    r("%s", 0x%X, %s, %s, 0, F_NOSFX, %s),' % (r['mn'], r['op'], pf, d, kf)
    vx = ['VEX' if r['enc'] == 1 else 'EVEX']
    if r['W']:
        vx.append('W1')
    if r['L']:
        vx.append('L%d' % r['L'])
    nc = ncode(r['N'], r['L'], r['enc'])
    if nc:
        vx.append('N%d' % nc)
    if r['mk']:
        vx.append('MK')
    if r['mz']:
        vx.append('MZ')
    if r['mr']:
        vx.append('MR')
    if r['swc']:
        vx.append('SWPC')
    elif r['sw']:
        vx.append('SWP')
    if r['mv']:
        vx.append('MV')
    pf = '0x%X' % r['pfx'] if r['pfx'] else '0'
    return '    v("%s", 0x%X, %s, %s, %s, %s),' % (r['mn'], r['op'], pf, d, ' | '.join(vx), kf)

def main():
    tmpl = json.load(open(sys.argv[1]))
    existing = open(sys.argv[2]).read()
    shapes = {}
    for x in tmpl:
        for l in x.get('asm', []):
            l = re.sub(r'@\(?[^ ,)]*\)?', '1', l)
            l = re.sub(r'\{@?\d[^}]*\}', '4', l) if '{%' not in l else l
            mn, ops, mask, zero = parse_line(l)
            key = (mn, tuple(c for c, _ in ops), mask, zero)
            shapes.setdefault(key, l)
    # The forms the code generator emits, and the store of every move whose load takes the store's
    # encoding for a 2-byte VEX prefix.
    extra = ['vmovdqu (%rax), %ymm1', 'vmovdqu %ymm1, (%rax)', 'vmovdqu64 (%rax), %zmm1', 'vmovdqu64 %zmm1, (%rax)']
    for mn in ('vmovaps', 'vmovapd', 'vmovups', 'vmovupd', 'vmovdqa', 'vmovdqu'):
        for c in ('xmm', 'ymm'):
            extra.append('%s (%%rax), %%%s1' % (mn, c))
            extra.append('%s %%%s1, (%%rax)' % (mn, c))
    for l in extra:
        mn, ops, mask, zero = parse_line(l)
        shapes.setdefault((mn, tuple(c for c, _ in ops), mask, zero), l)
    rows = []
    seen = set()
    errs = 0
    for (mn, cl, mask, zero), l in sorted(shapes.items()):
        ops = [(c, 0) for c in cl]
        # The legacy xmm0 operand of blendv.
        if mn in ('blendvps', 'blendvpd', 'pblendvb') and len(ops) == 3:
            ops[0] = ('x0', 0)
        variants = [(mask, zero)]
        if mask:
            variants.insert(0, (False, False))
        else:
            variants.append((True, False))
        for m, z in variants:
            r, e = derive(mn, ops, m, z)
            if r is None:
                if (m, z) == (mask, zero):
                    print('ERROR', e, file=sys.stderr)
                    errs += 1
                continue
            if (m, z) != (mask, zero) and r['enc'] != (2 if m else 1):
                continue
            t = row_text(r)
            if t is None:
                continue
            sig = t
            if sig in seen:
                continue
            seen.add(sig)
            rows.append((r, t))
    # The rows the table holds already.
    out = []
    for r, t in rows:
        if t.strip() in existing:
            continue
        out.append(t)
    # VEX before EVEX of one mnemonic: the assembler takes the first that encodes.
    out.sort(key=lambda t: (t.split('"')[1], 'EVEX' in t, int(re.search(r'\bL(\d)\b', t).group(1)) if re.search(r'\bL(\d)\b', t) else 0, t.split(', ')[1]))
    print('\n'.join(out))
    print('rows', len(out), 'errors', errs, file=sys.stderr)

main()
