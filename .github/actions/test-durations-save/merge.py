import glob
import os
import re

# Merge each lane's shard files (shards/durations-<lane>-<k>.tsv, the tests each shard ran) into
# out/<lane>.tsv, keep the current file of a lane no shard measured, and summarize each lane's measured
# and planned shard times. SHARDS: "<lane>=<count> ...".
shards = dict((k, int(v)) for k, v in (x.split("=") for x in os.environ["SHARDS"].split()))
os.makedirs("out", exist_ok=True)
rows = ["| lane | tests | total s | measured shard s | planned shard s |", "|---|---|---|---|---|"]
for lane, n in shards.items():
    per = {}
    times = {}
    for f in sorted(glob.glob(f"shards/durations-{lane}-*.tsv")):
        k = int(re.search(r"-(\d+)\.tsv$", f).group(1))
        for line in open(f):
            if line.startswith("#") or "\t" not in line:
                continue
            secs, name = line.rstrip("\n").split("\t", 1)
            times[name] = float(secs)
            per[k] = per.get(k, 0.0) + float(secs)
    if not times:
        # Not measured (every shard failed before recording): the lane keeps its current file.
        old = f"tests/durations/{lane}.tsv"
        if os.path.exists(old):
            with open(old) as i, open(f"out/{lane}.tsv", "w") as o:
                o.write(i.read())
        rows.append(f"| {lane} | not measured{', kept' if os.path.exists(old) else ''} | | | |")
        continue
    with open(f"out/{lane}.tsv", "w") as o:
        o.write("# super-c test --test-record-durations: seconds per test, read to balance --test-shard\n")
        for name in sorted(times):
            o.write(f"{times[name]:.2f}\t{name}\n")
    # The runner's split: the longest first, each to the shard with the least time so far.
    load = [0.0] * n
    for name in sorted(times, key=lambda t: -times[t]):
        load[load.index(min(load))] += times[name]
    measured = " / ".join(f"{per.get(k, 0):.0f}" for k in range(1, n + 1))
    planned = " / ".join(f"{x:.0f}" for x in load)
    rows.append(f"| {lane} | {len(times)} | {sum(times.values()):.0f} | {measured} | {planned} |")
with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as s:
    s.write("## Test durations\n\nTest seconds summed per shard (the runner runs tests in parallel, so a shard's wall time is shorter).\n\n")
    s.write("\n".join(rows) + "\n")
print("\n".join(rows))
