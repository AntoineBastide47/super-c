#!/usr/bin/env python3
# Extracts the prototypes of GCC's <immintrin.h> into build/x86gen/protos.json, the input of gen.py:
# each intrinsic's result, parameters and the `#pragma GCC target` features its definition sits under.
# The header comes from the `gcc:13` amd64 Docker image (preprocessed with __OPTIMIZE__, so every
# intrinsic is an inline function, not a macro). Run from the repository root.
import json
import os
import re
import subprocess

out = os.path.join('build', 'x86gen')
os.makedirs(out, exist_ok=True)
pre = subprocess.run(['docker', 'run', '--rm', '-i', '--platform', 'linux/amd64', 'gcc:13', 'gcc', '-E',
                      '-D__OPTIMIZE__', '-x', 'c', '-'], input='#include <immintrin.h>\n', capture_output=True,
                     text=True, check=True).stdout
lines = pre.split('\n')
stack = []
cur = []  # the current target list (the joined pragma targets)
protos = {}
i = 0
while i < len(lines):
    l = lines[i].strip()
    if l.startswith('#pragma GCC push_options'):
        stack.append(list(cur))
    elif l.startswith('#pragma GCC pop_options'):
        cur = stack.pop() if stack else []
    elif l.startswith('#pragma GCC target('):
        t = re.findall(r'"([^"]*)"', l)
        cur = [x for s in t for x in s.split(',')]
    elif l.startswith('extern __inline'):
        ret = l[len('extern __inline'):].split('__attribute__')[0].strip()
        j = i + 1
        while lines[j].strip() == '' or lines[j].strip().startswith('__attribute__'):
            j += 1
        txt = lines[j].strip()
        while txt.count('(') > txt.count(')'):
            j += 1
            txt += ' ' + lines[j].strip()
        m = re.match(r'(\w+)\s*\((.*)\)\s*$', txt)
        if m:
            protos[m.group(1)] = {'ret': ret, 'params': m.group(2), 'target': cur}
        i = j
    i += 1
json.dump(protos, open(os.path.join(out, 'protos.json'), 'w'), indent=0)
print(len(protos), 'prototypes')
