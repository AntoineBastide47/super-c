#!/bin/sh
set -e

# 1) Formatting must already be canonical (no auto-rewrite: the check fails instead).
./super-c fmt src std ffi --check

# 2) Full lint; any warning fails the check.
./super-c lint src std ffi

# 3) Bootstrap from the latest release binary; any failure fails the check.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gh release download --pattern super-c-macos-arm64.tar.gz --dir "$tmp"
tar xzf "$tmp/super-c-macos-arm64.tar.gz" -C "$tmp" super-c-macos-arm64/super-c
mv "$tmp/super-c-macos-arm64/super-c" ./super-c
chmod +x ./super-c
make -B
