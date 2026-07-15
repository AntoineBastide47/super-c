// Thin LSP client: spawns `<superc.serverPath> lsp` and lets vscode-languageclient do the rest.
const vscode = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");

let client;

function activate(context) {
  const config = vscode.workspace.getConfiguration("superc");
  const serverPath = config.get("serverPath", "super-c");
  const cwd = vscode.workspace.workspaceFolders?.[0]?.uri?.fsPath;

  const serverOptions = {
    command: serverPath,
    args: ["lsp"],
    options: cwd ? { cwd } : {},
  };
  const clientOptions = {
    documentSelector: [{ language: "super-c" }],
  };

  client = new LanguageClient("superc", "Super-C Language Server", serverOptions, clientOptions);
  context.subscriptions.push({ dispose: () => client && client.stop() });
  client.start();
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
