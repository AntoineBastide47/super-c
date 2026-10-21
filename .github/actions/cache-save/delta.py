"""The delta of a CI job's super-c cache base (~/.super-c/cache) against the cache it restored.

snapshot LIST          record every file's size and mtime after the restore
pack LIST TAR          write the files added or changed since, and the list of the files deleted since
                       (member `.deleted`), as TAR; hard links within it stay links
apply TAR [--keep]     extract TAR over the cache base, then delete the files it lists as deleted
                       (`--keep`: delete nothing)

The archives are this repository's own CI artifacts and caches.
"""
import io
import os
import sys
import tarfile

BASE = os.path.join(os.path.expanduser("~"), ".super-c", "cache")
DELETED = ".deleted"


def listing():
    out = {}
    for root, _, files in os.walk(BASE):
        for f in files:
            p = os.path.join(root, f)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            out[os.path.relpath(p, BASE).replace(os.sep, "/")] = f"{st.st_size}\t{st.st_mtime_ns}"
    return out


def snapshot(path):
    with open(path, "w", encoding="utf-8") as f:
        for rel, v in sorted(listing().items()):
            f.write(f"{rel}\t{v}\n")


def read_snapshot(path):
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            rel, size, mt = line.rstrip("\n").split("\t")
            out[rel] = f"{size}\t{mt}"
    return out


def pack(snap, tar):
    before = read_snapshot(snap)
    now = listing()
    changed = sorted(r for r, v in now.items() if before.get(r) != v)
    deleted = sorted(r for r in before if r not in now)
    with tarfile.open(tar, "w") as t:
        body = "".join(r + "\n" for r in deleted).encode()
        info = tarfile.TarInfo(DELETED)
        info.size = len(body)
        t.addfile(info, io.BytesIO(body))
        for r in changed:
            t.add(os.path.join(BASE, r), arcname=r, recursive=False)
    size = sum(int(now[r].split("\t")[0]) for r in changed)
    print(f"cache delta: {len(changed)} files added or changed ({size / 1048576:.1f} MiB), {len(deleted)} deleted")


def apply(tar, keep):
    os.makedirs(BASE, exist_ok=True)
    with tarfile.open(tar) as t:
        members = t.getmembers()
        gone = []
        for m in members:
            if m.name == DELETED:
                gone = t.extractfile(m).read().decode().split("\n")
        files = [m for m in members if m.name != DELETED]
        try:
            t.extractall(BASE, members=files, filter="fully_trusted")
        except TypeError:  # a Python before extraction filters
            t.extractall(BASE, members=files)
    if keep:
        gone = []
    n = 0
    for r in gone:
        if r and os.path.lexists(os.path.join(BASE, r)):
            os.remove(os.path.join(BASE, r))
            n += 1
    print(f"cache delta {os.path.basename(tar)}: {len(files)} files applied, {n} deleted")


def main(argv):
    if len(argv) == 3 and argv[1] == "snapshot":
        snapshot(argv[2])
    elif len(argv) == 4 and argv[1] == "pack":
        pack(argv[2], argv[3])
    elif len(argv) in (3, 4) and argv[1] == "apply" and argv[3:] in ([], ["--keep"]):
        apply(argv[2], argv[3:] == ["--keep"])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
