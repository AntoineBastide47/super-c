#!/usr/bin/env python3
# Emit the intrinsic table of one ISA as Super-C from gen.py's json.
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

o = [HEAD, '\n', '/// The rows, by name: the intrinsic and its instructions.\n', 'pub const ROWS: [(str<\'static>, str<\'static>); %d] = [\n' % len(rows)]
for r in rows:
    body = '\\n'.join(esc(conv(l)) for l in r['asm'])
    o.append('    ("%s", "%s"),\n' % (r['name'], body))
o.append('];\n')
if ISA == 'wasm':
    o.append('\n/// Per row: the wasm signature of a function of the intrinsic\'s arguments and result.\n')
    o.append('pub const SIGS: [str<\'static>; %d] = [\n' % len(rows))
    for r in rows:
        o.append('    "%s",\n' % r['sig'])
    o.append('];\n')
open(OUT, 'w').write(''.join(o))
print(len(rows))
