# The Super-C compiler API

The SDK is the compiler source at a release tag. A tool vendors it and imports the modules under
`src/api/`:

```sh
super-c vendor <compiler repository> superc --ref=<release tag>
```

```super-c
import vendor::superc::src::api::session as ses;
```

Only `src/api/` is visible to a client. Every other compiler item is `pub(package)`: a client that names
one, through a path, a glob import of its module or a glob import of a facade module, gets a visibility
error. A facade item names no type a client cannot name.

## Ways to use it

| Way | What | Where |
| --- | --- | --- |
| Native | Import the facade modules and build the tool with `super-c build`. | [examples](examples) |
| Compiled-in tools | List analyzer and hook modules in `build.toml` (`[tools] analyzers`, `[tools] hooks`). `super-c lint`, `build` and `run` build them into a compiler with the vendored source and run it. | `api::analysis`, `api::build` |
| C ABI | Build a shared library from `src/api/c_abi.spc` with `[lib] type = ["shared"]` and `exports = "c"`; include [`sdk/libsuperc.h`](../../sdk/libsuperc.h). | `api::c_abi` |
| Process protocol | Run `super-c tool-server --stdio` (or `--socket=PATH`) and speak JSON frames. [`sdk/protocol/v1.transcript`](../../sdk/protocol/v1.transcript) holds requests with their exact replies. | `api::protocol` |

## Modules and stability

| Module | Capability | Class |
| --- | --- | --- |
| `api::session`, `api::source`, `api::errors` | Sessions over projects or files, file providers, edits, cancellation, budgets, error codes | provisional |
| `api::syntax` | Lossless syntax trees, tokens, trivia, formatting, text edits | provisional |
| `api::semantic` | Symbols, types, layouts, hover, references, outline, rename | provisional |
| `api::refactor` | Refactorings with validation, structural matching | provisional |
| `api::analysis` | Analyzers with facts, prerequisites, fixes and cached results | provisional |
| `api::build` | Build plans and reports, steps, hooks | provisional; hooks experimental |
| `api::cli` | The command line of a tool compiler | provisional |
| `api::ir` | HIR nodes and Core IR functions | experimental |
| `api::lir` | LIR programs: text form, verification, evaluation, objects, loading | experimental |
| `api::backend` | Custom backends over LIR | experimental |
| C ABI (`API_VERSION` 0.1) | `libsuperc.h` | provisional |
| Protocol 1 | `tool-server` | provisional |

The classes:

- **stable**: compatible for the stated major version.
- **provisional**: source can change with release notes and a migration period.
- **experimental**: works only with the exact compiler version it was written for. A schema that follows
  the compiler (HIR, Core IR, LIR) is experimental.
- **internal**: not shipped; every compiler item outside `src/api/`.

No surface is stable yet. A surface becomes stable only after a compatibility review with real clients,
read-only surfaces (source, syntax, diagnostics, navigation, types, layouts, build plans) before any
mutation, transform or backend surface. The C ABI version is `API_VERSION` (major `<< 16 |` minor) and its
function table (`superc_api_table`); the protocol major is negotiated in `hello`.

## Guarantees

The API guarantees:

- Results consistent with one revision of the inputs; a view cannot outlive a change of its session (a
  compile error in native code, `stale_handle` in the C ABI and the protocol).
- Explicit ownership and thread rules on every type.
- Stable status codes (`api::errors::Code`) and negotiated capabilities in the C ABI and the protocol.
- Deterministic, documented orders of every enumeration.
- No dependency on mutable compiler internals.
- A failure or a capability rejection, never silently incomplete data.

It does not guarantee:

- Numeric ID stability across revisions.
- A stable HIR, Core IR or LIR schema, or a stable binary layout of them.
- Security isolation of in-process code: an analyzer, a hook or a backend shares the compiler's address
  space. The process protocol is the isolation boundary.
- A successful semantic result for invalid code.
- Source-compatible access to compiler internals.

## Compatibility suites

- The examples below build against a vendored copy of the compiler and run (`tests/api/api_sdk_test.spc`).
- A C client compiles against `libsuperc.h`, links the library and runs (`tests/api/api_c_abi_test.spc`).
- The server answers `sdk/protocol/v1.transcript` reply for reply (`tests/api/api_protocol_test.spc`).

## Examples

| Example | Shows |
| --- | --- |
| [diagnostics](examples/diagnostics/main.spc) | Check a project and print its diagnostics with their codes. |
| [rename](examples/rename/main.spc) | Rename a declaration and print the edits. |
| [lir](examples/lir/main.spc) | Build a function as LIR text, verify it, evaluate it and compile it to an object. |
| [build-hook](examples/build-hook/main.spc) | Plan and build a project with a hook that writes an artifact. |

Each example is a project: copy its directory, vendor the compiler into it as `vendor/superc`, and run
`super-c build`.
