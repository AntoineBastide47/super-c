#!/bin/sh
# Super-C installer (the `curl | sh` path):
#
#   curl -fsSL https://raw.githubusercontent.com/AntoineBastide47/super-c/main/install.sh | sh
#
# Downloads the latest release for this platform, installs it to ~/.super-c
# (bin/ + the std/ and ffi/ trees the compiler reads at build time), and adds
# ~/.super-c/bin to PATH in your shell's rc file (zsh/bash; once, deduplicated).
# Windows: download the super-c-windows-*.zip release asset and add its folder
# to PATH by hand.
set -eu

REPO="AntoineBastide47/super-c"

case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    *)
        echo "install: unsupported platform '$(uname -s)' -- download a release archive from https://github.com/$REPO/releases" >&2
        exit 1
        ;;
esac
arch="$(uname -m)"
name="super-c-${os}-${arch}"
url="https://github.com/$REPO/releases/latest/download/${name}.tar.gz"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading ${name}.tar.gz ..."
if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp/pkg.tar.gz" "$url" || {
        echo "install: no release asset for ${os}-${arch} -- see https://github.com/$REPO/releases" >&2
        exit 1
    }
else
    wget -qO "$tmp/pkg.tar.gz" "$url" || {
        echo "install: no release asset for ${os}-${arch} -- see https://github.com/$REPO/releases" >&2
        exit 1
    }
fi
tar -C "$tmp" -xzf "$tmp/pkg.tar.gz"

dest="$HOME/.super-c"
mkdir -p "$dest/bin"
# the binary first, then the trees it reads (fresh copies; stale files must not linger)
cp "$tmp/$name/super-c" "$dest/bin/super-c"
chmod +x "$dest/bin/super-c"
rm -rf "$dest/std" "$dest/ffi"
cp -R "$tmp/$name/std" "$tmp/$name/ffi" "$dest/"
echo "installed $dest/bin/super-c (+ std, ffi)"

# PATH: same contract as `super-c install` -- append once, to the shell's own rc file
case ":$PATH:" in
    *":$dest/bin:"*) exit 0 ;;
esac
case "${SHELL:-}" in
    */zsh) rc="$HOME/.zshrc" ;;
    */bash) rc="$HOME/.bashrc" ;;
    *)
        echo "note: add $dest/bin to your PATH"
        exit 0
        ;;
esac
if [ -f "$rc" ] && grep -q '\.super-c/bin' "$rc"; then
    echo "note: $rc already exports the path; open a new shell (or source it)"
    exit 0
fi
{
    printf '\n# added by the super-c installer\n'
    printf 'export PATH="$HOME/.super-c/bin:$PATH"\n'
} >> "$rc"
echo "added ~/.super-c/bin to PATH in $rc; open a new shell (or \`source $rc\`)"
