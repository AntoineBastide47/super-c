#!/bin/sh
# Install the Super-C VS Code extension for the local user and reload VS Code.
#
#   editors/vscode/install.sh [--no-reload]
#
# What it does:
#   1. symlinks this folder into ~/.vscode/extensions (edits here apply on the next reload),
#   2. installs the extension's npm dependencies if missing,
#   3. points `superc.serverPath` at this repo's ./super-c binary in the user settings,
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

# 3) superc.serverPath in the user settings (JSON edit; refuses rather than clobbering on a parse error)
settings="$HOME/Library/Application Support/Code/User/settings.json"
SC_SETTINGS="$settings" SC_SERVER="$server" python3 - <<'EOF'
import json, os, sys
p = os.environ["SC_SETTINGS"]
server = os.environ["SC_SERVER"]
s = {}
if os.path.exists(p):
    try:
        s = json.load(open(p))
    except ValueError:
        print("install: could not parse %s (comments/trailing commas?);" % p, file=sys.stderr)
        print('install: add   "superc.serverPath": "%s"   to it manually' % server, file=sys.stderr)
        sys.exit(0)
if s.get("superc.serverPath") != server:
    s["superc.serverPath"] = server
    json.dump(s, open(p, "w"), indent=4)
    print("install: set superc.serverPath = %s" % server)
else:
    print("install: superc.serverPath already set")
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
