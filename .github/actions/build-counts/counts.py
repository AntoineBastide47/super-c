"""The build work counts of one platform: this commit's compiler against the last release's, and the
threshold check of their change.

summarize TEXT OUT LABEL CC WORKLOAD: reads the `llvm-profdata merge --text` profile TEXT of one workload
run and writes OUT, a TSV of `label` (the compiler measured), `cc`, `workload`, `source` (`measured`),
`total` (every counter summed: llvm-profdata's "Total count"), `functions`, then one
`module<TAB>name<TAB>count` line per module, the largest first. A module is the mangled prefix before the
first `__` (`typechecker__check_expr` is `typechecker`); a function without one (`__sc_add_usize`, a
runtime helper) is its own module.

saved PREV OUT SHA CC WORKLOAD LABEL: when PREV (a saved `<target>.tsv`) counts commit SHA (its label
`(SHA)`) with clang CC and workload WORKLOAD, writes it to OUT with label LABEL and `source` `saved`, and
exits 0; else exits 1.

check TARGET BASE HEAD MD WARN LIMIT VERDICT: writes the Markdown table of HEAD's total against BASE's
(and the modules that moved most) to MD, prints a warning annotation for a growth of WARN percent or more
and an error annotation for LIMIT percent or more, and writes `ok`, `warn` or `over` (LIMIT reached: the
release waits for an approval) to VERDICT.

merge PREV NEW OUT: copies NEW's files to OUT, and PREV's files of each platform NEW lacks (a platform
whose job failed keeps its last counts).
"""

import os
import re
import shutil
import sys

TOP = 8  # modules listed per platform, the largest changes first


def summarize(text, out, label, cc, workload):
    lines = open(text).read().split("\n")
    modules = {}
    functions = 0
    i = 0
    while i < len(lines):
        # A record: the name, "# Func Hash:", the hash, "# Num Counters:", n, "# Counter Values:", n values.
        if lines[i].startswith("# Func Hash:"):
            name = lines[i - 1].split(":")[-1]
            n = int(lines[i + 3])
            m = re.match(r"([A-Za-z0-9]+?)__", name)
            key = m.group(1) if m else name
            modules[key] = modules.get(key, 0) + sum(int(v) for v in lines[i + 5 : i + 5 + n])
            functions += 1
            i += 5 + n
            continue
        i += 1
    with open(out, "w") as f:
        f.write(f"label\t{label}\ncc\t{cc}\nworkload\t{workload}\nsource\tmeasured\n")
        f.write(f"total\t{sum(modules.values())}\nfunctions\t{functions}\n")
        for k, v in sorted(modules.items(), key=lambda kv: -kv[1]):
            f.write(f"module\t{k}\t{v}\n")


def load(path):
    meta, modules = {}, {}
    for line in open(path).read().splitlines():
        parts = line.split("\t")
        if parts[0] == "module":
            modules[parts[1]] = int(parts[2])
        else:
            meta[parts[0]] = parts[1]
    return meta, modules


def saved(prev, out, sha, cc, workload, label):
    meta, _ = load(prev)
    if meta.get("label") != f"({sha})" or meta.get("cc") != cc or meta.get("workload") != workload:
        sys.exit(1)
    lines = open(prev).read().splitlines()
    with open(out, "w") as f:
        for line in lines:
            key = line.split("\t")[0]
            if key == "label":
                line = f"label\t{label}"
            elif key == "source":
                line = "source\tsaved"
            f.write(line + "\n")


def pct(old, new):
    return f"{(new - old) / old * 100:+.4f}%" if old else "new"


def check(target, base, head, md, warn, limit, verdict):
    bm, bmod = load(base)
    hm, hmod = load(head)
    old, cur = int(bm["total"]), int(hm["total"])
    growth = (cur - old) / old * 100
    warn, limit = float(warn), float(limit)
    msg = f"{target}: build work {pct(old, cur)} against the last release"
    if growth >= limit:
        v, note = "over", f"**{limit}% or more: the release waits for an approval**"
        alert = f"> [!CAUTION]\n> {msg}, at or over the {limit}% limit. The release waits for an approval.\n"
        print(f"::error::{msg}, at or over the {limit}% limit: the release waits for an approval")
    elif growth >= warn:
        v, note, alert = "warn", f"warning: {warn}% or more", f"> [!WARNING]\n> {msg}.\n"
        print(f"::warning::{msg}")
    else:
        v, note, alert = "ok", "ok", ""
        print(msg)
    with open(verdict, "w") as f:
        f.write(v + "\n")
    out = [
        f"### {target}: build work\n",
        alert,
        (
            f"This commit's {hm['workload']} against the saved count of the last release's ({hm['cc']}).\n"
            if bm.get("source") == "saved"
            else f"Both compilers on this commit's sources, no saved count of the last release to compare: a "
            f"{hm['workload']} ({hm['cc']}).\n"
        ),
        "| compiler | total count | functions |\n|---|---|---|",
        f"| last release {bm['label']} | {old:,} | {bm['functions']} |",
        f"| this commit {hm['label']} | {cur:,} | {hm['functions']} |",
        f"| change | {cur - old:+,} ({pct(old, cur)}) | {note} |",
    ]
    moved = sorted(set(bmod) | set(hmod), key=lambda k: -abs(hmod.get(k, 0) - bmod.get(k, 0)))
    rows = [k for k in moved[:TOP] if hmod.get(k, 0) != bmod.get(k, 0)]
    if rows:
        out.append("\n| module | last release | this commit | change |\n|---|---|---|---|")
        for k in rows:
            a, b = bmod.get(k, 0), hmod.get(k, 0)
            out.append(f"| `{k}` | {a:,} | {b:,} | {b - a:+,} ({pct(a, b)}) |")
    with open(md, "w") as f:
        f.write("\n".join(filter(None, out)) + "\n\n")


def merge(prev, new, out):
    os.makedirs(out, exist_ok=True)
    have = {f.split(".")[0].split("-")[0] for f in os.listdir(new)} if os.path.isdir(new) else set()
    for d, keep in ((new, lambda t: True), (prev, lambda t: t not in have)):
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            t = f.split(".")[0].split("-")[0]
            if keep(t):
                shutil.copy(os.path.join(d, f), os.path.join(out, f))
                if d == prev and f == t + ".tsv":
                    print(f"{t}: not measured in this run, its last counts are kept\n")


if __name__ == "__main__":
    {"summarize": summarize, "saved": saved, "check": check, "merge": merge}[sys.argv[1]](*sys.argv[2:])
