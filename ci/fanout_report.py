#!/usr/bin/env python3
"""Type fanout, header use and instance ownership report over one emitted tree.

Usage: python3 ci/fanout_report.py <gen-dir> <obj-dir> <std-dir> [report.md]

Reads the generated C (the forward header, every type and prototype header, every module and
instance TU), the per-unit compile records under <obj-dir> (`<unit>.cmd`, second line = ms), and the
std sources (prelude declaration owners). It builds:

  ByValueTypeGraph        emitted aggregate -> aggregate whose complete definition it embeds
  HeaderUseGraph          TU -> owner modules whose complete types, pointer types or prototypes it uses
  InstanceOwnershipGraph  every definition in the instance shards -> its stable owner module
  IncludeGraph            TU -> generated headers it includes, transitively (the invalidation that
                          the emitted layout actually has)

and reports type SCCs, header fanout, the TUs (and C compile CPU) invalidated by private-body,
public-signature and by-value-layout edits, both as the TU texts need them and as the include graph
delivers them, and the instance shards' content by owner. It changes no output; the emitted tree is
the emission plan it measures.
"""
import os
import re
import statistics
import sys
from collections import defaultdict

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
KEYWORDS = {"struct", "union", "enum", "typedef", "const", "static", "extern", "return", "if", "else",
            "while", "for", "sizeof", "_Alignof", "void", "bool", "int", "char", "unsigned", "signed",
            "long", "short", "float", "double", "inline", "goto", "break", "continue", "switch", "case",
            "default", "do", "volatile", "register", "restrict"}


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


class Modules:
    """Owner resolution: `<prefix>__Name` for user modules (short last segment, or the full path),
    unprefixed prelude names through the std declaration map."""

    def __init__(self, gen, std):
        self.user = {}  # prefix -> module path
        self.paths = []
        for root, _dirs, files in os.walk(gen):
            for f in files:
                if not f.endswith(".c") or f.startswith("__") or f == "super_rt.c":
                    continue
                rel = os.path.relpath(os.path.join(root, f), gen)[:-2]
                if re.search(r"__p\d+$", rel):
                    continue
                segs = rel.split(os.sep)
                if segs[0] == "__std":
                    path = "std::" + "::".join(segs[1:])
                else:
                    path = "::".join(segs)
                self.paths.append(path)
                if segs[0] != "__std":
                    self.user[segs[-1]] = path
                    self.user["__".join(segs)] = path
        self.std_decl = {}  # declared name -> std module path
        for root, _dirs, files in os.walk(std):
            for f in files:
                if not f.endswith(".spc"):
                    continue
                rel = os.path.relpath(os.path.join(root, f), std)[:-4]
                mpath = "std::" + rel.replace(os.sep, "::")
                for line in read(os.path.join(root, f)).splitlines():
                    m = re.match(r"\s*(?:pub\s+)?(?:struct|enum|union|const fn|fn|const|static mut|static)\s+([A-Za-z_]\w*)", line)
                    if m and not line.startswith(" "):
                        self.std_decl.setdefault(m.group(1), mpath)
                    m = re.match(r"extend(?:<[^>]*>)?\s+([A-Za-z_]\w*)", line)
                    if m:
                        self.std_decl.setdefault(m.group(1), mpath)
        self.cache = {}

    def owner(self, name):
        """The owner module of a C identifier, or None for runtime and builtin names."""
        if name in self.cache:
            return self.cache[name]
        r = None
        segs = name.split("__")
        # Longest user prefix first: `driver__emit` before `driver`.
        for k in range(len(segs) - 1, 0, -1):
            pfx = "__".join(segs[:k])
            if pfx in self.user:
                r = self.user[pfx]
                break
        if r is None and segs[0] in self.std_decl:
            r = self.std_decl[segs[0]]
        self.cache[name] = r
        return r


def parse_types(text):
    """Known aggregate names, the by-value graph over them, and each name's text size."""
    names = set()
    for m in re.finditer(r"^typedef (?:struct|union) (\w+) \1;", text, re.M):
        names.add(m.group(1))
    for m in re.finditer(r"^typedef enum \{[^}]*\} (\w+);", text, re.M):
        names.add(m.group(1))
    for m in re.finditer(r"^typedef (?:struct|union) \{[^\n]*\} (\w+);", text, re.M):
        names.add(m.group(1))
    for m in re.finditer(r"^(?:struct|union) (\w+) \{", text, re.M):
        names.add(m.group(1))
    edges = defaultdict(set)
    size = defaultdict(int)
    # Struct and union bodies: brace-balanced from `struct X {` to the closing `};`.
    for m in re.finditer(r"^(?:struct|union) (\w+) \{", text, re.M):
        nm = m.group(1)
        i = m.end()
        depth = 1
        while i < len(text) and depth > 0:
            c = text[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            i += 1
        body = text[m.end():i]
        size[nm] += i - m.start()
        # Function-pointer members: their parameter types need no complete definition.
        stripped = re.sub(r"\(\*\w*\)\s*\([^)]*\)", "", body)
        for t in IDENT.finditer(stripped):
            tn = t.group(0)
            if tn == nm or tn not in names:
                continue
            j = t.end()
            while j < len(stripped) and stripped[j] in " \t":
                j += 1
            if j < len(stripped) and stripped[j] == "*":
                continue
            edges[nm].add(tn)
    for m in re.finditer(r"^typedef enum \{[^}]*\} (\w+);", text, re.M):
        size[m.group(1)] += m.end() - m.start()
    return names, edges, size


def tarjan(nodes, edges):
    index = {}
    low = {}
    stack = []
    on = set()
    out = []
    counter = [0]
    sys.setrecursionlimit(100000)

    def visit(v):
        index[v] = low[v] = counter[0]
        counter[0] += 1
        stack.append(v)
        on.add(v)
        for w in edges.get(v, ()):
            if w not in index:
                visit(w)
                low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop()
                on.discard(w)
                comp.append(w)
                if w == v:
                    break
            out.append(comp)

    for v in sorted(nodes):
        if v not in index:
            visit(v)
    return out


def parse_protos(text):
    """Function names with a prototype in the shared prototype header."""
    fns = set()
    for line in text.splitlines():
        m = re.match(r"(?:extern )?[A-Za-z_][\w \*]*?\b(\w+)\(", line)
        if m and not line.startswith("#"):
            fns.add(m.group(1))
    return fns


def tu_uses(text, types, fns):
    """Per TU: types needed complete, types needed as pointers only, prototypes used."""
    complete = set()
    pointer = set()
    used_fns = set()
    n = len(text)
    for t in IDENT.finditer(text):
        nm = t.group(0)
        if nm in types:
            j = t.end()
            while j < n and text[j] in " \t":
                j += 1
            if j < n and text[j] == "*":
                pointer.add(nm)
            else:
                complete.add(nm)
        elif nm in fns:
            used_fns.add(nm)
    pointer -= complete
    return complete, pointer, used_fns


def unit_ms(obj, rel):
    p = os.path.join(obj, rel + ".cmd")
    try:
        lines = read(p).splitlines()
        return float(lines[1])
    except (OSError, IndexError, ValueError):
        return None


def classify_inst(line):
    """The content class of one top-level instance-TU definition line."""
    if line.startswith("/*") or line.startswith("#") or line.startswith("}") or line.startswith(" "):
        return None, None
    m = re.match(r"(?:__attribute__\(\(unused\)\) )?(?:static )?const .*?\b(\w+)(?:\[\])? = ", line)
    if m:
        nm = m.group(1)
        if nm.startswith("sc_typeinfo_") or "__ct" in nm or nm.startswith("__sc_ti"):
            return "descriptor", nm
        if nm.endswith("__vtbl") or nm.endswith("__vt"):
            return "dyn table", nm
        return "const/static", nm
    m = re.match(r"[A-Za-z_][\w \*]*?\b(\w+)\((?:.*)\) \{$", line)
    if m:
        nm = m.group(1)
        if nm.endswith("__free__d") or nm.endswith("____free"):
            return "free glue", nm
        if "__dyn" in nm or "__vt" in nm:
            return "dyn table", nm
        return "instance body", nm
    m = re.match(r"[A-Za-z_][\w \*]*?\b(\w+) = .*;$", line)
    if m:
        return "const/static", m.group(1)
    return None, None


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    gen, obj, std = sys.argv[1:4]
    out_path = sys.argv[4] if len(sys.argv) > 4 else None
    mods = Modules(gen, std)
    # Generated headers: the forward header, one type header per by-value SCC, one prototype header
    # per module. The type graph reads every type header, prototypes every prototype header.
    headers = []
    for root, _dirs, files in os.walk(gen):
        for f in sorted(files):
            if f.endswith(".h") and f != "super_rt.h":
                headers.append(os.path.relpath(os.path.join(root, f), gen))
    headers.sort()
    htext = {h: read(os.path.join(gen, h)) for h in headers}
    types_text = "".join(htext[h] for h in headers if h.endswith("__types.h") or h == "__sc_fwd.h")
    protos_text = "".join(htext[h] for h in headers if not h.endswith("__types.h"))
    types, tedges, tsize = parse_types(types_text)
    fns = parse_protos(protos_text)
    type_owner = {t: mods.owner(t) for t in types}

    # Translation units: every .c under gen except the runtime, wrapper and registry TUs.
    units = []
    for root, _dirs, files in os.walk(gen):
        for f in sorted(files):
            if not f.endswith(".c") or f == "super_rt.c" or f.startswith("__ext") or f in ("__test_main.c", "__sc_registry.c"):
                continue
            rel = os.path.relpath(os.path.join(root, f), gen)[:-2]
            units.append(rel)
    units.sort()
    unit_mod = {}
    unit_inst = {}
    for u in units:
        base = re.sub(r"__p\d+$", "", u)
        unit_inst[u] = base.endswith("__inst")
        base = re.sub(r"__inst$", "", base)
        segs = base.split(os.sep)
        if segs[0] == "__std":
            unit_mod[u] = "std::" + "::".join(segs[1:])
        else:
            unit_mod[u] = "::".join(segs)

    # The include graph: every generated header a TU includes, transitively.
    def includes_of(text, at):
        out = []
        base = os.path.dirname(at)
        for m in re.finditer(r'^#include "([^"]+)"', text, re.M):
            inc = os.path.normpath(os.path.join(base, m.group(1)))
            if inc in htext:
                out.append(inc)
        return out

    hdeps = {h: includes_of(htext[h], h) for h in headers}
    trans = {}

    def closure(h):
        if h in trans:
            return trans[h]
        seen = set()
        stack = [h]
        while stack:
            x = stack.pop()
            for y in hdeps[x]:
                if y not in seen:
                    seen.add(y)
                    stack.append(y)
        trans[h] = seen
        return seen

    unit_incs = {}
    for u in units:
        direct = includes_of(read(os.path.join(gen, u + ".c")), u + ".c")
        s9 = set(direct)
        for h in direct:
            s9 |= closure(h)
        unit_incs[u] = s9
    hdr_fan = defaultdict(set)
    for u, hs in unit_incs.items():
        for h in hs:
            hdr_fan[h].add(u)
    ms = {u: unit_ms(obj, u) for u in units}
    ms_known = [v for v in ms.values() if v is not None]

    # Header use per TU.
    use_complete = {}
    use_pointer = {}
    use_fn = {}
    for u in units:
        c, p, f = tu_uses(read(os.path.join(gen, u + ".c")), types, fns)
        use_complete[u] = c
        use_pointer[u] = p
        use_fn[u] = f

    # By-value closure: the types whose layout depends on T (T and everything embedding it).
    rev = defaultdict(set)
    for a, bs in tedges.items():
        for b in bs:
            rev[b].add(a)

    def embedders(t):
        seen = {t}
        stack = [t]
        while stack:
            x = stack.pop()
            for y in rev.get(x, ()):
                if y not in seen:
                    seen.add(y)
                    stack.append(y)
        return seen

    comps = tarjan(types, tedges)
    comp_of = {}
    for i, c in enumerate(comps):
        for t in c:
            comp_of[t] = i

    lines = []
    w = lines.append
    w("# Type fanout, header use and instance ownership report")
    w("")
    w(f"gen `{gen}`, {len(units)} translation units, {len(types)} emitted aggregates, {len(fns)} prototypes, "
      f"{len(mods.paths)} modules; per-unit compile records for {len(ms_known)}/{len(units)} units "
      f"(sum {sum(ms_known):.0f} ms, median {statistics.median(ms_known) if ms_known else 0:.0f} ms).")
    w("")

    # 1. Type graph and SCCs.
    w("## ByValueTypeGraph")
    w("")
    nedges = sum(len(v) for v in tedges.values())
    sizes = [len(c) for c in comps]
    w(f"- nodes {len(types)}, by-value edges {nedges}, SCCs {len(comps)}, largest SCC {max(sizes)}, "
      f"SCCs of size >1: {sum(1 for s in sizes if s > 1)}")
    cross = [c for c in comps if len({type_owner[t] for t in c}) > 1]
    w(f"- cross-module SCCs: {len(cross)}")
    for c in cross[:10]:
        w(f"  - {sorted(c)} spans {sorted({str(type_owner[t]) for t in c})}")
    # Module-level projection: a module embeds another when one of its aggregates embeds one of the
    # other's by value. Cycles here need one shared SCC header; a DAG lets every module own its header.
    medges = defaultdict(set)
    for a, bs in tedges.items():
        for b in bs:
            oa, ob = type_owner[a], type_owner[b]
            if oa is not None and ob is not None and oa != ob:
                medges[oa].add(ob)
    mcomps = tarjan(set(m for m in type_owner.values() if m is not None), medges)
    msizes = sorted((len(c) for c in mcomps), reverse=True)
    w(f"- module-level by-value graph: {len(medges)} modules with cross-module embeds, {sum(len(v) for v in medges.values())} edges, "
      f"module SCCs {len(mcomps)}, sizes above 1: {[s for s in msizes if s > 1]}")
    for c in mcomps:
        if len(c) > 1:
            w(f"  - module SCC: {sorted(c)}")
    by_owner = defaultdict(int)
    for t in types:
        by_owner[type_owner[t]] += 1
    w(f"- aggregates by owner (top 12): " + ", ".join(f"{k} {v}" for k, v in sorted(by_owner.items(), key=lambda kv: -kv[1])[:12]))
    unknown = [t for t in types if type_owner[t] is None]
    w(f"- aggregates with no resolvable owner: {len(unknown)} (e.g. {sorted(unknown)[:8]})")
    w("")

    # 2. Header fanout.
    w("## HeaderUseGraph")
    w("")
    fan_complete = defaultdict(set)  # owner module -> TUs needing a complete definition of one of its types
    fan_pointer = defaultdict(set)
    fan_fn = defaultdict(set)
    type_fan = defaultdict(set)
    for u in units:
        for t in use_complete[u]:
            type_fan[t].add(u)
            fan_complete[type_owner[t]].add(u)
        for t in use_pointer[u]:
            fan_pointer[type_owner[t]].add(u)
        for f in use_fn[u]:
            o = mods.owner(f)
            if o != unit_mod[u]:
                fan_fn[o].add(u)
    n_units = len(units)
    inc_counts = sorted(len(hs) for hs in unit_incs.values())
    w(f"- `__sc_fwd.h` {len(htext.get('__sc_fwd.h', ''))} bytes, {sum(1 for h in headers if h.endswith('__types.h'))} type headers "
      f"({sum(len(htext[h]) for h in headers if h.endswith('__types.h'))} bytes), "
      f"{sum(1 for h in headers if not h.endswith('__types.h') and h != '__sc_fwd.h')} prototype headers "
      f"({sum(len(htext[h]) for h in headers if not h.endswith('__types.h') and h != '__sc_fwd.h')} bytes); "
      f"generated headers per TU (transitive): median {inc_counts[len(inc_counts) // 2]}, max {inc_counts[-1]}")
    w("")
    w("| owner module | TUs needing complete types | TUs needing pointer-only | TUs using prototypes |")
    w("|---|---:|---:|---:|")
    rows = []
    for m in sorted(set(mods.paths), key=str) + [None]:
        rows.append((len(fan_complete[m]), len(fan_pointer[m] - fan_complete[m]), len(fan_fn[m]), m))
    rows.sort(key=lambda r: (-r[0], -r[1], -r[2], str(r[3])))
    for c, p, f, m in rows:
        if c or p or f:
            w(f"| {m} | {c}/{n_units} | {p}/{n_units} | {f}/{n_units} |")
    w("")
    w("Types by fanout (TUs needing the complete definition, top 20):")
    w("")
    for t, us in sorted(type_fan.items(), key=lambda kv: -len(kv[1]))[:20]:
        w(f"- {t} ({type_owner[t]}): {len(us)}/{n_units}, SCC size {len(comps[comp_of[t]])}, embedders {len(embedders(t)) - 1}")
    w("")
    inc_types = []
    inc_protos = []
    for u in units:
        if unit_inst[u]:
            continue
        inc_types.append(len({type_owner[t] for t in use_complete[u]} - {unit_mod[u], None}))
        inc_protos.append(len({mods.owner(f) for f in use_fn[u]} - {unit_mod[u], None}))
    w(f"Per module TU, owner modules whose complete types it needs: median {statistics.median(inc_types):.0f}, max {max(inc_types)}; "
      f"owner modules whose prototypes it calls: median {statistics.median(inc_protos):.0f}, max {max(inc_protos)}")
    w("")
    dist = sorted((len(us) for us in type_fan.values()), reverse=True)
    if dist:
        w(f"Complete-definition fanout distribution over {len(dist)} used types: max {dist[0]}, p90 {dist[len(dist)//10]}, "
          f"median {dist[len(dist)//2]}, types used by one TU only {sum(1 for d in dist if d == 1)}")
    w("")

    # 3. Invalidation per edit class.
    w("## Invalidation by edit class")
    w("")

    def cost(us):
        known = [ms[u] for u in us if ms[u] is not None]
        return sum(known)

    inst_units = [u for u in units if unit_inst[u]]
    inst_cost = cost(inst_units)
    body_rows = []
    sig_rows = []
    lay_rows = []
    inst_owner_bytes = defaultdict(int)
    inst_owner_n = defaultdict(int)
    inst_class_bytes = defaultdict(int)
    inst_class_n = defaultdict(int)
    for u in inst_units:
        text = read(os.path.join(gen, u + ".c"))
        cur = None
        curname = None
        start = 0
        for m in re.finditer(r"^.*$", text, re.M):
            line = m.group(0)
            if cur is None:
                cls, nm = classify_inst(line)
                if cls:
                    cur, curname, start = cls, nm, m.start()
                    if not line.endswith("{"):
                        inst_class_bytes[cur] += m.end() - start
                        inst_class_n[cur] += 1
                        o = mods.owner(curname)
                        inst_owner_bytes[o] += m.end() - start
                        inst_owner_n[o] += 1
                        cur = None
            elif line == "}":
                inst_class_bytes[cur] += m.end() - start
                inst_class_n[cur] += 1
                o = mods.owner(curname)
                inst_owner_bytes[o] += m.end() - start
                inst_owner_n[o] += 1
                cur = None
    owners_with_instances = {o for o in inst_owner_n if o is not None}

    def mod_rel(m):
        segs = m.split("::")
        if segs[0] == "std":
            segs[0] = "__std"
        return os.sep.join(segs)

    real_sig_rows = []
    real_lay_rows = []
    for m in sorted(mods.paths):
        own = [u for u in units if unit_mod[u] == m and not unit_inst[u]]
        body = set(own)
        sig = set(own) | fan_fn[m]
        lay = set(own)
        for t in types:
            if type_owner[t] == m:
                for e in embedders(t):
                    lay |= type_fan[e]
        lay |= fan_fn[m]
        body_rows.append((len(body), cost(body), m))
        sig_rows.append((len(sig), cost(sig), m))
        lay_rows.append((len(lay), cost(lay), m))
        # What the emitted include graph delivers: a signature edit rewrites the module's
        # prototype header, a layout edit its type header (and the module's own TUs).
        ph = mod_rel(m) + ".h"
        th = mod_rel(m) + "__types.h"
        rs = set(own) | hdr_fan.get(ph, set())
        rl = set(own) | hdr_fan.get(th, set())
        real_sig_rows.append((len(rs), cost(rs), m))
        real_lay_rows.append((len(rl), cost(rl), m))

    def summarize(name, rows):
        ns = [r[0] for r in rows]
        cs = [r[1] for r in rows]
        w(f"- **{name}**: TUs invalidated median {statistics.median(ns):.0f}, p90 {sorted(ns)[int(len(ns) * 0.9)]}, "
          f"max {max(ns)} of {n_units}; C compile CPU median {statistics.median(cs):.0f} ms, max {max(cs):.0f} ms "
          f"(clean build {sum(ms_known):.0f} ms)")

    summarize("private body edit (own module TU shards)", body_rows)
    summarize("public signature edit, as the TU texts need it (own TUs plus every TU using the module's prototypes)", sig_rows)
    summarize("by-value layout edit, as the TU texts need it (own TUs, every TU needing an embedding type complete, prototype users)", lay_rows)
    summarize("public signature edit, as the include graph delivers it (own TUs plus every TU including the module's prototype header)", real_sig_rows)
    summarize("by-value layout edit, as the include graph delivers it (own TUs plus every TU including the module's type header)", real_lay_rows)
    w("")
    w("Per module (TUs invalidated: body / signature / layout as needed / signature / layout as delivered; compile ms as delivered):")
    w("")
    w("| module | own TUs | body | sig need | layout need | sig real | layout real | sig ms | layout ms |")
    w("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for (bn, bc, m), (sn, sc, _m2), (ln, lc, _m3), (rsn, rsc, _m4), (rln, rlc, _m5) in sorted(
            zip(body_rows, sig_rows, lay_rows, real_sig_rows, real_lay_rows), key=lambda r: -r[4][0]):
        own = sum(1 for u in units if unit_mod[u] == m and not unit_inst[u])
        w(f"| {m} | {own} | {bn} | {sn} | {ln} | {rsn} | {rln} | {rsc:.0f} | {rlc:.0f} |")
    w("")
    w("Header fanout as delivered (TUs including the header transitively, top 20):")
    w("")
    for h, us in sorted(hdr_fan.items(), key=lambda kv: (-len(kv[1]), kv[0]))[:20]:
        w(f"- {h}: {len(us)}/{n_units} ({cost(us):.0f} ms)")
    w("")

    # 4. Instance shards.
    w("## Instance shards")
    w("")
    ib = sum(len(read(os.path.join(gen, u + ".c"))) for u in inst_units)
    w(f"- shards {len(inst_units)}, bytes {ib}, C compile {inst_cost:.0f} ms, owner modules with content {len(owners_with_instances)}")
    w("- content by class: " + ", ".join(f"{k} {inst_class_n[k]} ({inst_class_bytes[k]} B)" for k in sorted(inst_class_n)))
    w("- content by owner (top 15): " + ", ".join(f"{k} {inst_owner_n[k]} ({inst_owner_bytes[k]} B)" for k, _v in sorted(inst_owner_n.items(), key=lambda kv: -inst_owner_bytes[kv[0]])[:15]))
    shard_by_mod = defaultdict(list)
    for u in inst_units:
        shard_by_mod[unit_mod[u]].append(u)
    w("- shards by owner module (top 12 by bytes): " + ", ".join(
        f"{m} {len(us)} ({sum(len(read(os.path.join(gen, u + '.c'))) for u in us)} B, {cost(us):.0f} ms)"
        for m, us in sorted(shard_by_mod.items(), key=lambda kv: -sum(len(read(os.path.join(gen, u + '.c'))) for u in kv[1]))[:12]))
    w("")

    # 5. Module sizes for shard policy.
    w("## Module TU sizes")
    w("")
    w("| module | parts | bytes | compile ms |")
    w("|---|---:|---:|---:|")
    msize = defaultdict(int)
    mparts = defaultdict(int)
    for u in units:
        if unit_inst[u]:
            continue
        msize[unit_mod[u]] += len(read(os.path.join(gen, u + ".c")))
        mparts[unit_mod[u]] += 1
    for m, b in sorted(msize.items(), key=lambda kv: -kv[1])[:25]:
        w(f"| {m} | {mparts[m]} | {b} | {cost([u for u in units if unit_mod[u] == m and not unit_inst[u]]):.0f} |")
    report = "\n".join(lines) + "\n"
    if out_path:
        with open(out_path, "w") as f:
            f.write(report)
    else:
        sys.stdout.write(report)


if __name__ == "__main__":
    main()
