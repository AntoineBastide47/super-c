#!/bin/sh
set -e

# 1) Formatting must already be canonical (no auto-rewrite: the check fails instead).
printf 'check: formatting (fmt --check)\n'
if ! files=$(SC_LEAK_CHECK=fatal ./super-c fmt src std ffi tests bench ci --check); then
    printf 'check: FAILED -- these files are not canonically formatted:\n' >&2
    printf '%s\n' "$files" | sed 's/^/  /' >&2
    printf 'fix with: ./super-c fmt src std ffi tests bench ci\n' >&2
    exit 1
fi

# 2) Full lint, once per supported target (@platform gates differ); any warning fails the check.
for target in macos linux windows; do
    printf 'check: lint (--target=%s)\n' "$target"
    if ! SC_LEAK_CHECK=fatal ./super-c lint src std ffi tests bench ci --target="$target"; then
        printf 'check: FAILED -- lint warnings above (--target=%s) must be fixed (or try: ./super-c lint --fix <file>)\n' "$target" >&2
        exit 1
    fi
done

# 3) Full test suite with the current compiler (built first if stale), leak-gated: every process in
# the run (compiler, harness, spawned servers, compiled fixtures) exits nonzero on leaks/double frees.
printf 'check: tests\n'
if ! SC_LEAK_CHECK=fatal ./super-c test; then
    printf 'check: FAILED -- test failures above\n' >&2
    exit 1
fi

# 4) Bootstrap from the latest release binary; any failure fails the check.
# Stage 0: the release binary builds current source via the legacy `build <root> -o` path (works
# even for a pre-build-system release). Stage 0 then rebuilds itself through the engine (SC_CMD=1
# bypasses the [command.build] bootstrap override, whose lines would point at the wrong binary) --
# two generations from current source, the same guarantee the Makefile's SELF-BUILD gave.
printf 'check: bootstrap rebuild from the latest release\n'
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if ! gh release download --pattern super-c-macos-arm64.tar.gz --dir "$tmp"; then
    printf 'check: FAILED -- could not download the release bootstrap binary (gh auth / network?)\n' >&2
    exit 1
fi
tar xzf "$tmp/super-c-macos-arm64.tar.gz" -C "$tmp" super-c-macos-arm64/super-c
mv "$tmp/super-c-macos-arm64/super-c" ./super-c
chmod +x ./super-c
if ! ./super-c build --bootstrap-tags -o stage0-super-c src/main.spc; then
    printf 'check: FAILED -- the release binary cannot build the current source\n' >&2
    exit 1
fi
if ! SC_CMD=1 SC_LEAK_CHECK=fatal ./stage0-super-c build; then
    rm -f stage0-super-c
    printf 'check: FAILED -- two-stage rebuild from the release bootstrap broke (see build output above)\n' >&2
    exit 1
fi
rm -f stage0-super-c
printf 'check: OK\n'
