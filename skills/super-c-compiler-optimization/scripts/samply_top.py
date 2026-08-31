#!/usr/bin/env python3
"""Aggregate samply profiles into a hotspot ranking without the browser UI.

Usage:
    samply record --save-only --unstable-presymbolicate -o run1.profile.json.gz <cmd>
    ... repeat for run2..runN ...
    python3 samply_top.py run*.profile.json.gz

Each profile needs its `<name>.syms.json` sidecar (written by --unstable-presymbolicate)
next to it; without the sidecar, native frames print as hex addresses. Functions are
ranked by how many runs they appear in, then by total samples, so a one-run fluke sorts
below a hotspot that shows up everywhere.

Exits non-zero when no samples were read: an empty aggregation is a broken capture, not
a quiet program.
"""

import bisect
import collections
import gzip
import json
import sys

TOP_N = 30


def norm_id(debug_id: str) -> str:
    return debug_id.replace("-", "").upper()


def load_sidecar(profile_path: str):
    # samply names the sidecar <output>.syms.json with the .gz dropped:
    # run1.profile.json.gz -> run1.profile.json.syms.json
    base = profile_path[:-3] if profile_path.endswith(".gz") else profile_path
    try:
        with open(base + ".syms.json") as f:
            syms = json.load(f)
    except FileNotFoundError:
        return None, None
    strings = syms["string_table"]
    libsyms = {}
    for lib in syms["data"]:
        tab = sorted((e["rva"], e.get("size", 0), e["symbol"]) for e in lib["symbol_table"])
        libsyms[norm_id(lib["debug_id"])] = ([r for r, _, _ in tab], tab)
    return strings, libsyms


def resolve(strings, libsyms, breakpad_id: str, addr: int):
    # The profile's breakpadId carries a trailing age digit the sidecar id lacks.
    ent = libsyms.get(norm_id(breakpad_id)[:32])
    if ent is None:
        return None
    rvas, tab = ent
    i = bisect.bisect_right(rvas, addr) - 1
    if i < 0:
        return None
    rva, size, sym = tab[i]
    if size and addr >= rva + size:
        return None
    return strings[sym]


def profile_counts(path: str) -> collections.Counter:
    with gzip.open(path) as f:
        prof = json.load(f)
    strings, libsyms = load_sidecar(path)
    plibs = prof["libs"]
    counts = collections.Counter()
    for th in prof["threads"]:
        ft, fn, rt = th["frameTable"], th["funcTable"], th["resourceTable"]
        tstr = th["stringArray"]
        for s in th["samples"]["stack"]:
            if s is None:
                continue
            frame = th["stackTable"]["frame"][s]
            addr, func = ft["address"][frame], ft["func"][frame]
            res = fn["resource"][func]
            name = tstr[fn["name"][func]]
            if libsyms is not None and res >= 0 and addr is not None and addr >= 0:
                lib_idx = rt["lib"][res]
                if lib_idx is not None and lib_idx >= 0:
                    sym = resolve(strings, libsyms, plibs[lib_idx]["breakpadId"], addr)
                    if sym is not None:
                        name = sym
            counts[name] += 1
    return counts


def main() -> int:
    paths = sys.argv[1:]
    if not paths:
        print(__doc__, file=sys.stderr)
        return 2
    per_run = [profile_counts(p) for p in paths]
    total_samples = sum(sum(c.values()) for c in per_run)
    if total_samples == 0:
        print("error: zero samples across all profiles - capture is broken", file=sys.stderr)
        return 1
    runs_present = collections.Counter()
    totals = collections.Counter()
    for counts in per_run:
        for name, n in counts.items():
            runs_present[name] += 1
            totals[name] += n
    ranked = sorted(totals, key=lambda k: (-runs_present[k], -totals[k]))
    print(f"{len(paths)} run(s), {total_samples} leaf samples")
    print(f"{'runs':>5} {'samples':>8} {'share':>7}  function")
    for name in ranked[:TOP_N]:
        share = 100.0 * totals[name] / total_samples
        print(f"{runs_present[name]:>5} {totals[name]:>8} {share:>6.2f}%  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
