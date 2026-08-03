// Thin LSP client: spawns `<server> lsp` and lets vscode-languageclient do the rest.
const vscode = require("vscode");
const fs = require("fs");
const path = require("path");
const { LanguageClient } = require("vscode-languageclient/node");

let client;

// Server discovery: an explicit `superc.serverPath` wins; otherwise prefer the workspace's
// release-profile binary (sanitizer-free: about a quarter of the ASan dev build's memory), then
// the workspace-root binary, then `super-c` on PATH.
function findServer(config, cwd) {
  const insp = config.inspect("serverPath");
  const explicit = insp && (insp.workspaceFolderValue ?? insp.workspaceValue ?? insp.globalValue);
  if (explicit) return explicit;
  const exe = process.platform === "win32" ? "super-c.exe" : "super-c";
  if (cwd) {
    let out = "build";
    try {
      const m = fs.readFileSync(path.join(cwd, "build.toml"), "utf8").match(/^\s*out-dir\s*=\s*"([^"]+)"/m);
      if (m) out = m[1];
    } catch (e) {}
    for (const cand of [path.join(cwd, out, "release", exe), path.join(cwd, exe)]) {
      if (fs.existsSync(cand)) return cand;
    }
  }
  return exe;
}

function activate(context) {
  const config = vscode.workspace.getConfiguration("superc");
  const cwd = vscode.workspace.workspaceFolders?.[0]?.uri?.fsPath;
  const serverPath = findServer(config, cwd);

  const env = { ...process.env };
  if (!env.ASAN_OPTIONS) {
    env.ASAN_OPTIONS = "quarantine_size_mb=8:malloc_context_size=0:detect_leaks=0";
  }
  const serverOptions = {
    command: serverPath,
    args: ["lsp"],
    options: cwd ? { cwd, env } : { env },
  };
  const clientOptions = {
    // build.toml is served by the same server: it validates the manifest with the build's own checker
    // and completes its keys. Matched by name so no other TOML file is claimed.
    documentSelector: [
      { language: "super-c" },
      { language: "superc-manifest" },
    ],
  };

  client = new LanguageClient("superc", "Super-C Language Server", serverOptions, clientOptions);
  context.subscriptions.push({ dispose: () => client && client.stop() });
  client.start();
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
