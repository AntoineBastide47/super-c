#!/usr/bin/env python3
# Emit the intrinsic table of one ISA as Super-C from gen.py's json: into an existing table file, merge (a
# generated row replaces or adds its name's row; the rows written by hand and the rest of the file stay).
import json, sys, re
ISA, JS, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
rows = json.load(open(JS))
rows = [r for r in rows if 'asm' in r]
rows.sort(key=lambda r: r['name'])

def conv(line):
    # {k} and {k*a+b} placeholders -> @k and @(k*a+b)
    def f(m):
        inner = m.group(1)
        if re.fullmatch(r'\d', inner):
            return '@' + inner
        return '@(' + inner + ')'
    return re.sub(r'\{(\d(?:\*-?\d+[+-]\d+)?)\}', f, line)

def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')

HEAD = {
 'a64': '''// The Advanced SIMD intrinsics (`arm_neon.h`, `arm_acle.h`) the arm64 backend expands in place of a call:
// per intrinsic, its instructions over the registers the standard calling convention gives the call's
// arguments and result (v0, v1, .. for vectors and floats, x0, x1, .. for integers and pointers, in
// order), `@k` the constant argument `k` and `@(k*a+b)` its multiple. Derived from clang's code for a
// one-call wrapper of each; `tests/codegen/asm_test.spc` checks each assembles to clang's bytes.
''',
 'x64': '''// The SSE to AVX-512 intrinsics (`immintrin.h`) the x86-64 backend expands in place of a call: per
// intrinsic, its instructions (AT&T) over the registers the System V convention gives the call's
// arguments and result (xmm0, xmm1, .. for vectors and floats; rdi, rsi, rdx, rcx, r8, r9, then r10 and
// r11 for the stack's, for integers and pointers, in order), `@k` the constant argument `k` and
// `@(k*a+b)` its multiple. Derived from clang's code for a one-call wrapper of each;
// `tests/codegen/asm_test.spc` checks each assembles to clang's bytes.
''',
 'wasm': '''// The simd128 intrinsics (`wasm_simd128.h`) the wasm backend expands in place of a call: per intrinsic,
// its instructions, `local.get k` the call's argument `k`, `@k` the constant argument `k` and
// `@(k*a+b)` its multiple. Derived from clang's code for a one-call wrapper of each;
// `tests/codegen/asm_test.spc` checks each assembles to clang's bytes.
''',
}[ISA]

def block(text, name):
    # The span of `pub(package) const NAME: [...; n] = [` .. its closing `];` in `text`.
    m = re.search(r"pub(?:\(package\))? const %s: \[[^\]]*; \d+\] = \[\n" % name, text)
    if not m:
        return None
    end = text.index('\n];\n', m.end()) + 4
    return m.start(), m.end(), end

def entries(text):
    # The (name, text) pairs of a ROWS block, as written (escapes kept), one line or formatted over several.
    return re.findall(r'\(\s*"([^"]+)",\s*"((?:[^"\\]|\\.)*)"\s*,?\s*\)', text)

gen = {r['name']: '\\n'.join(esc(conv(l)) for l in r['asm']) for r in rows}
gsig = {r['name']: r['sig'] for r in rows} if ISA == 'wasm' else {}
try:
    old = open(OUT).read()
except FileNotFoundError:
    old = None
if old is not None and block(old, 'ROWS') is not None:
    # Merge: a generated row replaces the file's row of its name or adds one; a row the generator does not
    # derive (written by hand: the C library's roundings) stays, and so does the rest of the file.
    a, b, e = block(old, 'ROWS')
    have = dict(entries(old[b:e]))
    sigs = {}
    if ISA == 'wasm':
        sa, sb, se = block(old, 'SIGS')
        sl = re.findall(r'"((?:[^"\\]|\\.)*)"', old[sb:se])
        names = [n for n, _ in entries(old[b:e])]
        sigs = dict(zip(names, sl))
    have.update(gen)
    sigs.update(gsig)
    names = sorted(have)
    vis = old[a:old.index('const ROWS', a)]
    o = [old[:a], vis, "const ROWS: [(str<'static>, str<'static>); %d] = [\n" % len(names)]
    for n in names:
        o.append('    ("%s", "%s"),\n' % (n, have[n]))
    o.append('];\n')
    rest = old[e:]
    if ISA == 'wasm':
        sa, sb, se = block(rest, 'SIGS')
        sv = rest[sa:rest.index('const SIGS', sa)]
        s2 = [sv, "const SIGS: [str<'static>; %d] = [\n" % len(names)]
        for n in names:
            s2.append('    "%s",\n' % sigs[n])
        s2.append('];\n')
        rest = rest[:sa] + ''.join(s2) + rest[se:]
    open(OUT, 'w').write(''.join(o) + rest)
    print(len(names))
    sys.exit(0)

o = [HEAD, '\n', '/// The rows, by name: the intrinsic and its instructions.\n', 'pub(package) const ROWS: [(str<\'static>, str<\'static>); %d] = [\n' % len(rows)]
for r in rows:
    body = '\\n'.join(esc(conv(l)) for l in r['asm'])
    o.append('    ("%s", "%s"),\n' % (r['name'], body))
o.append('];\n')
if ISA == 'wasm':
    o.append('\n/// Per row: the wasm signature of a function of the intrinsic\'s arguments and result.\n')
    o.append('pub(package) const SIGS: [str<\'static>; %d] = [\n' % len(rows))
    for r in rows:
        o.append('    "%s",\n' % r['sig'])
    o.append('];\n')
open(OUT, 'w').write(''.join(o))
print(len(rows))
