#!/bin/sh
# Install the Super-C VS Code extension for the local user and reload VS Code.
#
#   editors/vscode/install.sh [--no-reload]
#
# What it does:
#   1. symlinks this folder into ~/.vscode/extensions (edits here apply on the next reload),
#   2. installs the extension's npm dependencies if missing,
#   3. clears a `superc.serverPath` a previous install pinned to ./super-c -- the extension now
#      discovers the server itself (release build first, then ./super-c, then PATH),
#   4. restarts VS Code so the running window picks everything up (hot exit keeps unsaved buffers).
set -e

ext_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$ext_dir/../.." && pwd)
server="$repo_root/super-c"

if [ ! -x "$server" ]; then
    printf 'install: %s is missing -- build it first (./super-c build or make)\n' "$server" >&2
    exit 1
fi

# 1) extension symlink
mkdir -p "$HOME/.vscode/extensions"
ln -sfn "$ext_dir" "$HOME/.vscode/extensions/super-c-0.1.0"
printf 'install: linked ~/.vscode/extensions/super-c-0.1.0 -> %s\n' "$ext_dir"

# 2) dependencies
if [ ! -d "$ext_dir/node_modules/vscode-languageclient" ]; then
    printf 'install: npm install (vscode-languageclient)\n'
    (cd "$ext_dir" && npm install --silent)
fi

# 3) clear the serverPath a previous install pinned (JSON edit; refuses rather than clobbering on a
# parse error). A path the user chose themselves is left alone.
settings="$HOME/Library/Application Support/Code/User/settings.json"
SC_SETTINGS="$settings" SC_SERVER="$server" python3 - <<'EOF'
import json, os, sys
p = os.environ["SC_SETTINGS"]
server = os.environ["SC_SERVER"]
if not os.path.exists(p):
    sys.exit(0)
try:
    s = json.load(open(p))
except ValueError:
    print("install: could not parse %s; if it contains" % p, file=sys.stderr)
    print('install:   "superc.serverPath": "%s"   remove it -- the extension discovers the server now' % server, file=sys.stderr)
    sys.exit(0)
if s.get("superc.serverPath") == server:
    del s["superc.serverPath"]
    json.dump(s, open(p, "w"), indent=4)
    print("install: cleared superc.serverPath (the extension discovers the server: release build, ./super-c, PATH)")
elif "superc.serverPath" in s:
    print("install: keeping your explicit superc.serverPath = %s" % s["superc.serverPath"])
EOF

# 4) reload: restart VS Code (a running window snapshots its config at activation)
if [ "$1" = "--no-reload" ]; then
    printf 'install: done -- reload VS Code windows to activate (Cmd+Shift+P > Reload Window)\n'
    exit 0
fi
if pgrep -xq Electron 2>/dev/null || pgrep -fq "Visual Studio Code" 2>/dev/null; then
    printf 'install: restarting VS Code...\n'
    osascript -e 'quit app "Visual Studio Code"' || true
    sleep 2
    open -a "Visual Studio Code"
else
    printf 'install: done -- start VS Code and open a .spc file\n'
fi
