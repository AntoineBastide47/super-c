#!/usr/bin/env python3
"""Regenerate src/bindgen/ctarget_data.spc from the reference clang.

usage: python3 -I scripts/gen_ctarget.py CLANG OUT.spc UNIVERSE.spc LLVM_DIR [--scan LABEL=DIR]...

CLANG is the reference compiler (ctarget.spc, the pinned release). UNIVERSE.spc (a test-only module)
receives every name asked of it, true or false. LLVM_DIR holds Features.def, Attr.td, Builtins.td,
TokenKinds.def and BuiltinsAArch64.def, BuiltinsAArch64NeonSVEBridge.def, BuiltinsWebAssembly.def of the same release
(https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-<version>/clang/include/clang/Basic/<file>).
The x86 `__builtin_ia32_*` names are left out: no C library header tests them. Each --scan names a system include tree whose C headers are
searched for the names they pass to __has_builtin. Only the reference compiler's preprocessor runs.
"""
import os
import re
import subprocess
import sys

# (target, arch, clang triple, flags the build adds, family, system directory name), one per row of
# src/target/table.spc's TARGETS, in its order: row i of ROWS is the C environment of TARGETS row i.
# target codes are its OSES indexes (windows 0, macos 1, linux 2, wasm 3, ios 4, android 5), arch codes
# its ISAS indexes (x86_64 0, aarch64 1, wasm32 2).
WASI = " -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS"
TARGETS = [
    (1, 0, "x86_64-apple-macos11.0", "", "apple", ""),
    (1, 1, "arm64-apple-macos11.0", "", "apple", ""),
    (4, 0, "x86_64-apple-ios13.0-simulator", "", "apple", ""),
    (4, 1, "arm64-apple-ios13.0", "", "apple", ""),
    (2, 0, "x86_64-unknown-linux-gnu", "", "elf", "x86_64-linux-gnu"),
    (2, 1, "aarch64-unknown-linux-gnu", "", "elf", "aarch64-linux-gnu"),
    (5, 0, "x86_64-linux-android24", "", "elf", "x86_64-linux-android"),
    (5, 1, "aarch64-linux-android24", "", "elf", "aarch64-linux-android"),
    (0, 0, "x86_64-w64-mingw32", "", "windows", "x86_64-w64-mingw32"),
    (0, 1, "aarch64-w64-mingw32", "", "windows", "aarch64-w64-mingw32"),
    (3, 2, "wasm32-wasip1", WASI, "wasm", "wasm32-wasip1"),
]

# Upstream clang's answers whatever the vendor's build: no configuration file, and the runtime library
# each target defaults to rather than the build's CLANG_DEFAULT_RTLIB (with libgcc, which Debian's
# packages choose, Android aarch64 loses function multiversioning and its predefined macro).
HERMETIC = ["--no-default-config", "--rtlib=platform"]

# ctarget.spc writes these from PINNED_VERSION (ctarget_data.spc).
PINNED = {"__clang_major__", "__clang_minor__", "__clang_patchlevel__", "__clang_version__", "__VERSION__"}

BUILTIN_RE = re.compile(r"__has_builtin\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)")
SPELLING_RE = re.compile(r"\b(GNU|GCC|Clang|ClangGCC|Declspec|C23)<([^>]*)>")
STRING_RE = re.compile(r'"([^"]*)"')
# A Builtins.td record: its kind, name, parent list, and body (to the `}` that starts a line).
RECORD_RE = re.compile(r"^(class|def)\s+(\w+)\s*:(.*?)(?:;|\{(.*?)^\})", re.S | re.M)
# A Template<types, affixes, as_prefix> parent: the affixes and the prefix flag.
TEMPLATE_RE = re.compile(r"Template<\s*\[[^\]]*\]\s*,\s*\[([^\]]*)\]\s*(,\s*(?:/\*.*?\*/)?\s*1)?\s*>", re.S)

# Candidate values of the __is_target_* operators the SDK headers use (clang compares the triple's
# parts by name); the reference compiler's answer per triple keeps the true ones.
TARGET_NAMES = {
    "os": "darwin macos macosx ios tvos watchos xros visionos driverkit bridgeos linux windows win32 android wasi "
    "freebsd netbsd openbsd emscripten none unknown fuchsia haiku solaris aix zos".split(),
    "arch": "x86_64 i386 i686 arm64 arm64e arm64_32 aarch64 arm armv7 armv7k wasm32 wasm64 riscv64 ppc64 s390x".split(),
    "vendor": "apple pc unknown w64 scei".split(),
    "environment": "gnu android musl msvc macabi simulator wasi eabi gnueabi kernelkit exclavekit exclavecore".split(),
    "variant_os": "macos macosx ios tvos watchos xros visionos".split(),
    "variant_environment": "macabi simulator".split(),
}


def run(args, inp=None):
    r = subprocess.run(args, input=inp, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr[:2000])
        raise SystemExit(1)
    return r.stdout


def dump_macros(clang, triple, flags):
    out = run([clang] + HERMETIC + ["--target=" + triple] + flags.split() + ["-dM", "-E", "-x", "c", "/dev/null"])
    table = {}
    for line in out.splitlines():
        assert line.startswith("#define ")
        body = line[len("#define "):]
        key = re.match(r"[A-Za-z_][A-Za-z0-9_]*", body).group(0)
        if key not in PINNED:
            table[key] = body
    return table


def definitions(llvm):
    """Candidate names per __has_* operator from the compiler's own definition lists."""
    feats = open(os.path.join(llvm, "Features.def"), encoding="utf-8").read()
    names = {"feature": set(), "extension": set(), "attribute": set(), "c_attribute": set(), "declspec_attribute": set()}
    for kind, name in re.findall(r"^(FEATURE|EXTENSION)\(\s*(\w+)", feats, re.M):
        names[kind.lower()].add(name)
    attrs = open(os.path.join(llvm, "Attr.td"), encoding="utf-8").read()
    for cls, args in SPELLING_RE.findall(attrs):
        strs = STRING_RE.findall(args)
        if not strs or cls == "C23" and len(strs) < 2:
            continue
        plain = strs[1] if cls == "C23" and len(strs) > 1 else strs[0]
        if cls == "Declspec":
            names["declspec_attribute"].add(plain)
        elif cls == "C23":
            scope = strs[0] if len(strs) > 1 else ""
            names["c_attribute"].add((scope + "::" if scope else "") + plain)
        else:
            names["attribute"].add(plain)
            if cls in ("GCC", "ClangGCC"):
                names["c_attribute"].add("gnu::" + plain)
            if cls in ("Clang", "ClangGCC"):
                names["c_attribute"].add("clang::" + plain)
    # Every feature is an extension too.
    names["extension"] |= names["feature"]
    return names


DUNDER_KINDS = ("feature", "extension", "attribute", "c_attribute")


def dunder(n):
    """The double-underscore spelling of a name, which the operators accept too."""
    head, sep, tail = n.rpartition("::")
    return head + sep + "__" + tail + "__"


def template_of(parents, templates):
    """The (affixes, as_prefix) of a record's Template parent, direct or through a class, or None."""
    m = TEMPLATE_RE.search(parents)
    if m:
        return STRING_RE.findall(m.group(1)), m.group(2) is not None
    for p in re.findall(r"\w+", parents):
        if p in templates:
            return templates[p]
    return None


def builtin_defs(llvm):
    """Builtin names of the compiler's definition files (generic, AArch64, Arm, WebAssembly): a templated
    spelling once per affix, an AddBuiltinPrefixedAlias one with its `__builtin_` alias too; and the
    keywords `__has_builtin` answers: every `__builtin_` keyword and every type, array and expression
    trait (TokenKinds.def)."""
    names = set()
    td = open(os.path.join(llvm, "Builtins.td"), encoding="utf-8").read()
    templates = {}
    for kind, name, parents, body in RECORD_RE.findall(td):
        t = template_of(parents, templates)
        if kind == "class":
            if t is not None:
                templates[name] = t
            continue
        sp = re.search(r"Spellings\s*=\s*\[(.*?)\]", body, re.S)
        if not sp:
            continue
        spellings = STRING_RE.findall(sp.group(1))
        if t is not None:
            affixes, prefix = t
            spellings = [a + s if prefix else s + a for s in spellings for a in affixes]
        if re.search(r"AddBuiltinPrefixedAlias\s*=\s*1", body):
            spellings += ["__builtin_" + s for s in spellings]
        names.update(spellings)
    tokens = open(os.path.join(llvm, "TokenKinds.def"), encoding="utf-8").read()
    traits = ("TYPE_TRAIT_1", "TYPE_TRAIT_2", "TYPE_TRAIT_N", "ARRAY_TYPE_TRAIT", "EXPRESSION_TRAIT")
    for macro, name in re.findall(r'^(\w+)\(\s*"?(\w+)"?\s*,', tokens, re.M):
        if macro in traits or name.startswith("__builtin_"):
            names.add(name)
    for f in ("BuiltinsAArch64.def", "BuiltinsWebAssembly.def", "BuiltinsAArch64NeonSVEBridge.def"):
        text = open(os.path.join(llvm, f), encoding="utf-8").read()
        names.update(re.findall(r"^(?:TARGET_)?(?:BUILTIN|HEADER_BUILTIN)\(\s*(\w+)", text, re.M))
        names.update(re.findall(r"^(?:TARGET_)?(?:LIB|LANG)BUILTIN\(\s*(\w+)", text, re.M))
    return {n for n in names if re.fullmatch(r"[A-Za-z_]\w*", n)}


def scan_builtins(trees):
    found = set()
    for _, d in trees:
        for root, subdirs, files in os.walk(d):
            subdirs[:] = [s for s in subdirs if s != "c++"]
            for f in files:
                if not f.endswith(".h"):
                    continue
                try:
                    with open(os.path.join(root, f), encoding="utf-8", errors="replace") as fh:
                        text = fh.read()
                except OSError:
                    continue
                if "__has_builtin" in text:
                    found.update(BUILTIN_RE.findall(text))
    return found


def has_truth(clang, triple, flags, universe):
    """The true answers of the reference compiler: kind:name keys."""
    lines = []
    for kind, names in sorted(universe.items()):
        for n in sorted(names):
            lines.append('#if __has_%s(%s)\n@@"%s:%s"\n#endif\n' % (kind, n, kind, n))
    for kind, names in sorted(TARGET_NAMES.items()):
        for n in names:
            lines.append('#if __is_target_%s(%s)\n@@"target_%s:%s"\n#endif\n' % (kind, n, kind, n))
    out = run([clang] + HERMETIC + ["--target=" + triple] + flags.split() + ["-E", "-P", "-x", "c", "-"], "".join(lines))
    return {l[3:-1]: l[3:-1] for l in out.splitlines() if l.startswith("@@")}


def layer_text(sets, dels):
    return "".join([sets[k] + "\n" for k in sorted(sets)] + ["-" + k + "\n" for k in sorted(dels)])


def plan_layers(finals, groups):
    """finals: target index -> {key: line}. Returns (layers, per-target layer id lists).

    A layer is (sets, dels): lines to set by key, keys to remove."""
    n = len(finals)
    state = [dict() for _ in range(n)]
    layers = []
    plan = [[] for _ in range(n)]

    def add(members, sets, dels):
        if not sets and not dels:
            return
        layers.append((sets, dels))
        for t in members:
            plan[t].append(len(layers) - 1)
            state[t].update(sets)
            for k in dels:
                del state[t][k]

    for _, members in groups:
        sets, dels = {}, set()
        for k in set().union(*[set(finals[t]) | set(state[t]) for t in members]):
            vals = {finals[t].get(k) for t in members}
            if len(vals) != 1:
                continue
            v = vals.pop()
            if v is None:
                if all(k in state[t] for t in members):
                    dels.add(k)
            elif any(state[t].get(k) != v for t in members):
                sets[k] = v
        add(members, sets, dels)
    for t in range(n):
        sets = {k: v for k, v in finals[t].items() if state[t].get(k) != v}
        add([t], sets, {k for k in state[t] if k not in finals[t]})
        assert state[t] == finals[t]
    return layers, plan


def balanced(text):
    depth = 0
    for c in text:
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


def main(argv):
    if len(argv) < 5:
        sys.stderr.write(__doc__)
        raise SystemExit(2)
    clang, out_path, universe_path, llvm = argv[1], argv[2], argv[3], argv[4]
    scans = []
    rest = argv[5:]
    while rest:
        if rest[0] != "--scan" or len(rest) < 2 or "=" not in rest[1]:
            sys.stderr.write("unknown or malformed argument: %s\n" % " ".join(rest[:2]))
            raise SystemExit(2)
        label, _, d = rest[1].partition("=")
        if not os.path.isdir(d):
            sys.stderr.write("--scan directory %s does not exist\n" % d)
            raise SystemExit(2)
        scans.append((label, d))
        rest = rest[2:]
    found = re.search(r"clang version ([0-9.]+)", run([clang, "--version"]))
    if not found:
        sys.stderr.write("%s is not a clang\n" % clang)
        raise SystemExit(2)
    clang_version = found.group(1)
    universe = definitions(llvm)
    universe["builtin"] = scan_builtins(scans) | builtin_defs(llvm)
    macro_final = [dump_macros(clang, t[2], t[3]) for t in TARGETS]
    # A name that is a predefined macro somewhere would expand inside the question.
    taken = set().union(*[set(m) for m in macro_final])
    for kind in universe:
        universe[kind] = {n for n in universe[kind] if n.rpartition("::")[2] not in taken}
    # The canonical names go to the test universe; the tables are asked those and their dunder spellings.
    canonical = {k: set(v) for k, v in universe.items()}
    for kind in DUNDER_KINDS:
        universe[kind] |= {dunder(n) for n in canonical[kind] if dunder(n).rpartition("::")[2] not in taken}
    has_final = []
    for _, _, triple, flags, _, _ in TARGETS:
        has_final.append(has_truth(clang, triple, flags, universe))
    asked = sorted(["%s:%s" % (k, n) for k, ns in canonical.items() for n in ns] + ["target_%s:%s" % (k, n) for k, ns in TARGET_NAMES.items() for n in ns])
    with open(universe_path, "w", encoding="utf-8") as f:
        f.write("// Generated by scripts/gen_ctarget.py: do not edit. Every canonical `kind:name` the generator asked the\n")
        f.write("// reference compiler, true or false (the tests add the double-underscore spellings of feature,\n")
        f.write("// extension, attribute and c_attribute names), so a test can ask again and find a name the tables lost.\n\n")
        f.write("pub const NAMES: str<'static> = M\"(%s)\";\n" % "\n".join(asked))
    groups = [("base", list(range(len(TARGETS))))]
    for arch in (0, 1):
        groups.append(("arch %d" % arch, [i for i, t in enumerate(TARGETS) if t[1] == arch]))
    for fam in ("apple", "elf", "windows"):
        groups.append(("family " + fam, [i for i, t in enumerate(TARGETS) if t[4] == fam]))
    # One plan serves both tables, so a layer id means the same group in each.
    both = [{**macro_final[i], **has_final[i]} for i in range(len(TARGETS))]
    layers, plan = plan_layers(both, groups)
    macro_layers = []
    has_layers = []
    for sets, dels in layers:
        macro_layers.append(layer_text({k: v for k, v in sets.items() if ":" not in k}, {k for k in dels if ":" not in k}))
        has_layers.append(layer_text({k: v for k, v in sets.items() if ":" in k}, {k for k in dels if ":" in k}))
    assert not any(dels for _, dels in layers), "the runtime merge does not remove entries"
    for t in macro_layers + has_layers:
        assert balanced(t), "unbalanced parentheses in a layer"
        assert ')"' not in t, "a layer would end its raw string"
    out = []
    out.append("// Generated by scripts/gen_ctarget.py from clang %s: do not edit. Names: Features.def and Attr.td of\n" % clang_version)
    out.append("// llvmorg-%s; builtins: the __has_builtin operands of the C headers of %s.\n" % (clang_version, ", ".join(l for l, _ in scans)))
    out.append("// The reference compiler's answer per target decides which names are kept. A layer line `NAME VALUE`\n")
    out.append("// sets a macro (a function-like macro is `NAME(args) body`); the has layers hold `kind:name` lines.\n")
    out.append("// `__clang_version__` and `__VERSION__` depend on the vendor's build: ctarget.spc pins them.\n\n")
    out.append("/// The C environment of `target::table::TARGETS` row `i` is row `i`.\n")
    out.append("pub struct Row {\n    pub triple: str<'static>,\n")
    out.append("    pub dir: str<'static>,\n    pub flags: str<'static>,\n    pub layers: [u8; 4],\n}\n\n")
    out.append("pub const PINNED_VERSION: str<'static> = \"%s\";\n\n" % clang_version)
    out.append("pub const ROWS: [Row; %d] = [\n" % len(TARGETS))
    for i, (_, _, triple, flags, _, d) in enumerate(TARGETS):
        assert len(plan[i]) <= 4
        ids = plan[i] + [255] * (4 - len(plan[i]))
        fields = [
            'triple: "%s"' % triple,
            'dir: "%s"' % d,
            'flags: "%s"' % flags,
            "layers: [%s]" % ", ".join(str(x) for x in ids),
        ]
        one = "    Row { %s }," % ", ".join(fields)
        # The formatter keeps a row on one line up to 120 columns.
        out.append(one + "\n" if len(one) <= 120 else "    Row {\n" + "".join("        %s,\n" % f for f in fields) + "    },\n")
    out.append("];\n\n")
    for const, tables in (("MACRO_LAYERS", macro_layers), ("HAS_LAYERS", has_layers)):
        out.append("pub const %s: [str<'static>; %d] = [\n" % (const, len(tables)))
        for t in tables:
            out.append('    M"(%s)",\n' % t)
        out.append("];\n\n")
    open(out_path, "w", encoding="utf-8").write("".join(out).rstrip("\n") + "\n")
    sys.stderr.write("layers: %d, bytes: %d\n" % (len(layers), sum(len(t) for t in macro_layers + has_layers)))


main(sys.argv)
