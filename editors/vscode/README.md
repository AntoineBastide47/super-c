# Super-C for VS Code

Language support for Super-C (`.spc`), backed by the compiler's own language server (`super-c lsp`):
live diagnostics on every edit, hover (types + signatures), go-to-definition, find references, rename,
completion (fields/methods after `.`, variants/module items after `::`), document formatting
(`super-c fmt` canonical style) and semantic highlighting.

## Setup

1. Build or install `super-c` and make sure it is on your `PATH` (or set `superc.serverPath` to the
   binary's absolute path in the VS Code settings).
2. Install dependencies and launch:

```sh
cd editors/vscode
npm install
```

- **Development:** open `editors/vscode` in VS Code and press F5 (Run Extension).
- **Package/install:** `npx @vscode/vsce package` then `code --install-extension super-c-0.1.0.vsix`.

## Settings

- `superc.serverPath` — the `super-c` binary the server is spawned from. When unset, the extension
  discovers one: the workspace's `<out-dir>/release/super-c` first (a release build is sanitizer-free
  and uses about a quarter of the ASan dev build's memory), then the workspace-root `super-c`, then
  `super-c` on `PATH`. Set it explicitly to override the order (e.g. to a stale-proof absolute path).
- `superc.trace.server` — LSP wire tracing (`off` / `messages` / `verbose`).

## Notes

- The server compiles the whole workspace (without codegen) on every change; on a project the size of
  the Super-C compiler itself that is tens of milliseconds.
- A `build.toml` at the workspace root roots the analysis at its `root` entry; files outside that
  closure are analyzed standalone, like `super-c lint <file>`.
