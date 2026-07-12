#!/bin/sh
# Content-sync the freshly emitted C tree ($1) into the persistent compile tree ($2):
# only files whose CONTENT changed get new mtimes, so make recompiles exactly those objects.
# Files that vanished from the emitted tree are pruned (their stale .o is simply never linked
# again -- OBJECTS is derived from the synced tree).
src="$1"; dst="$2"
mkdir -p "$dst"
(cd "$src" && find . -type f) | while IFS= read -r f; do
    if ! cmp -s "$src/$f" "$dst/$f" 2>/dev/null; then
        mkdir -p "$dst/$(dirname "$f")"
        cp "$src/$f" "$dst/$f"
    fi
done
(cd "$dst" && find . -type f ! -name '*.d') | while IFS= read -r f; do
    [ -f "$src/$f" ] || rm -f "$dst/$f"
done
