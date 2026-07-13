#!/bin/sh
set -e

# 1) Formatting must already be canonical (no auto-rewrite: the check fails instead).
printf 'check: formatting (fmt --check)\n'
if ! files=$(./super-c fmt src std ffi --check); then
    printf 'check: FAILED -- these files are not canonically formatted:\n' >&2
    printf '%s\n' "$files" | sed 's/^/  /' >&2
    printf 'fix with: ./super-c fmt src std ffi\n' >&2
    exit 1
fi

# 2) Full lint; any warning fails the check.
printf 'check: lint\n'
if ! ./super-c lint src std ffi; then
    printf 'check: FAILED -- lint warnings above must be fixed (or try: ./super-c lint --fix <file>)\n' >&2
    exit 1
fi

# 3) Full test suite with the current compiler.
printf 'check: tests\n'
if ! make test; then
    printf 'check: FAILED -- test failures above\n' >&2
    exit 1
fi

# 4) Bootstrap from the latest release binary; any failure fails the check.
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
if ! make -B; then
    printf 'check: FAILED -- two-stage rebuild from the release bootstrap broke (see build output above)\n' >&2
    exit 1
fi
printf 'check: OK\n'
