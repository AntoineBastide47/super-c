# Output layout: headers, shards and ownership

The emitted C tree is a function of the package's by-value type graph and of what every
translation unit spells. This is the record of the measured decision behind it, the
ownership rules, and the checks that keep it sound. Source of truth: the assembly and
write-out stages in `src/driver/emit.spc` (search `Assembly:` and `write_shard`), the
owner rules in `src/emit/tu.spc` (`pick_owner`, `type_owner`) and the spelling rows in
`src/emit/mangle.spc` (`modpfx`, `mark_used`, `um_hit_kind`).

## Files

| File | Content | Included by |
|------|---------|-------------|
| `__sc_fwd.h` | runtime includes, `typedef struct X X;` for every aggregate, closure env forward typedefs, payload-less enums, dyn fat types, `@emit_macro` templates, assert helpers, extern and block-wrapper prototypes, dyn table and ZST sentinel declarations | every generated file |
| `<mod>__types.h` | the complete definitions of every aggregate the module owns, in the global by-value order, then the closure env structs it owns; one header per SCC of the by-value module graph, named by the smallest member path | TUs that spell one of its type names; type headers whose definitions embed one of its types; prototype headers whose `_ret` structs do |
| `<mod>.h` | `_ret` typedefs, cross-TU prototypes, constant and descriptor declarations the module owns | TUs that spell one of its symbols (and the module's own shards) |
| `<mod>.c`, `<mod>__p<k>.c` | the module's bodies, sharded by `stable_item_hash(symbol) mod count`; the count comes from the rendered size (`shard_policy`: one shard per 256 KiB of C; a count read from the previous `__sc_shards` is kept while every shard stays within half and one and a half times that), or from `[shards]` in build.toml; a static closure follows the body before it | |
| `<mod>__inst.c`, `<mod>__inst__p<k>.c` | generic instances of the module's generics, glue of its types, its constants and descriptors, dyn tables of its receivers (same policy per owner; `[instance-shards]` overrides) | |
| `__sc_shards` | `super-c-shards<TAB>1`, then `module<TAB>tus<TAB>insts` for every module with more than one shard of either kind: the counts this build used, which the next build reads as its starting point | the next build |
| `__sc_registry.c` | ZST sentinels; the reflection registry: the `@reflect` roots sorted by symbol (each root is an external `const` with hidden visibility except on Windows, defined in its owner's instance shard), one pointer table, one constructor calling `__sc_reflect_register` per root (lookup reads the runtime's table, never constructor order) | |
| `__sc_manifest` | one record per output: kind, path, 64-bit content hash, owner module, shard index, generated headers included; the effective shard counts (`shards` lines, whether chosen or overridden); the C command inputs; the registry roots | tooling |

Every include line is relative (`../` per module directory level); the tree compiles
with no `-I` flag.

## Ownership

- A named aggregate belongs to its declaring module. A generic instance aggregate
  belongs to the owner of the by-value type argument whose definition came latest in the
  global by-value order, else to the generic's module; so `Option<ast::Node>` lives in
  `ast/ast__types.h` beside `Node`, `Vector<T>` (pointer to T) in `__std/vector__types.h`.
  A TU that spells the instance name spells every argument owner too, so the owner's
  header is always included where the instance is used.
- Payload-less enums are global (`__sc_fwd.h`): C11 has no forward-declared enum and
  prototypes take them by value.
- A `_ret` struct belongs to the function's module and lands in its prototype header
  (callers need it complete); that header includes the type headers of the fields'
  owners. A closure env struct belongs to the closure's module and lands in its type
  header.
- A function instance body belongs to the generic's declaring module; free glue to the
  destroyed type's owner (the generic's module for instances, matching where the drop
  site's symbol edge points); a constant to its declaring module; a `type_info`
  descriptor to the described type's owner (`core` for builtins); a dyn table to the
  receiver type's owner, else the interface's module.
- Every module-prefix spelling records a (context -> owner) edge on the mangler, typed
  as a type name (inside `type_m`/`ctype`/`inst_name`) or another symbol; a context is
  a module TU or `CTX_INST | owner` for an owner's instance shard, and the assembly-time
  renderers (constants, descriptors, dyn tables, block wrappers) switch to the owner's
  context. A shard includes the type headers of its type row and the prototype headers
  of its symbol row, plus its own module's two headers. Symbols spelled without a
  module prefix (`String__free` through `inst_name`, `__sc_ti__T`, fixed-text
  `Global__alloc`) record their owner explicitly; a new spelling path that omits the
  edge fails the strict C gate with an implicit declaration.

## Decision record

Measured with `python3 ci/fanout_report.py <gen> <obj> std` on the compiler's own tree
(147 units, 710 aggregates, 130 modules; a 14-core dev-profile build).

Before: two shared headers (`__sc_types.h` 145 KiB, `__sc_protos.h` 410 KiB) included
by every TU, and one shared instance TU (523 KiB, two parts, 58 owner modules): a
signature edit recompiled 87 of 91 units, a layout edit 69 to 87, and any generic body
edit rewrote the instance TU.

Rejected: nominally separate headers per module for the `std::core` /
`std::parallel::atomics` / `std::parallel::sync` by-value cycle. They would include
each other and invalidate the same units; the cycle gets one SCC header
(`__std/core__types.h`).

Accepted (the layout above). The type graph is a DAG of 710 aggregates (no type-level
SCC), with one 3-module SCC at the module level. As the include graph delivers it:

| Edit class | TUs invalidated (median / p90 / max of 147) |
|-----------|----------------------------------------------|
| private body | 1 / 1 / 6 (the module's shards) |
| public signature | 1 / 19 / 85 |
| by-value layout | 1 / 24 / 128 |

The maxima are the prelude's `str`, `String` and `Vector` (spelled by nearly every
unit) and `lexer::token` (`Span` is embedded by the AST, which every pass embeds): a
layout edit there is a whole-program rebuild by construction. A module TU includes the
type headers of a median 6 modules and the prototype headers of a median 6.

Whole-build edits through the real engine (the `ci/bench_matrix.sh` edits, 14 cores,
dev profile, warm caches): a private body edit rewrites 1 C file and recompiles 1 of 151
objects (2.2 s end to end); the public signature edit in `module::loader` rewrites its
prototype header and recompiles 40 objects (6.2 s, against 87 of 91 before); the layout
edit in `lexer::token` rewrites 24 C files (their field initializers change) plus one
type header and recompiles 92 objects (5.3 s, against 69 to 87 of 91 before). A cold
build with every cache off, both layouts emitted from the same sources: the old layout
compiles 92 units in 77 to 79 s of C compiler time over a 9.2 s span (10.0 s total), the
new layout 151 units in 82 s over an 8.4 s span (9.2 s total): the 60 extra small units
cost about 4% more compiler time, and writing the largest units first (the streaming
compile starts each unit as its file lands) shortens the critical path. Header size does
not move a unit's compile time (measured: one unit with its own include list against
every generated header included, 5.0 s both). A generic body edit (`Vector::push` in `std/vector.spc`) rewrites the
two `__std/vector__inst` shards and no header, recompiles 2 objects, and leaves the
registry TU byte-identical; changing a `[shards]` count prints the migration notice and
rewrites that module's shards only.

Targets set before the change and met: a body edit recompiles only the module's own
shards; a signature or layout edit in a leaf module recompiles under 10% of the units;
no header include cycle; the forward header under 64 KiB; byte-identical two-generation
fixpoint and `--jobs=1` versus `--jobs=N` output.

## Emission cost of the layout

Measured on the release compiler with a no-op C compiler (`--cc=true`,
`SC_CEMIT_STATS=1`), which isolates emission from compilation: the assembly stage takes
1 to 2 ms; the write stage 240 to 260 ms, of which the build engine's per-file sink
(`sync` in the probe report, 293 files) takes 180 to 210 ms against 165 ms for the 162
files of the old layout. Three costs had to be removed to get there:

- The object cache hashed every included header again for every unit (7x with
  dependency-local headers): `ch_hash_file` now memoizes each file's transitive hash per
  build, with include paths normalized (`dir/../x.h` -> `x.h`) so every including
  directory hits the same entry.
- `open_out` created parent directories with one `mkdir` per path component for every
  file; it now opens first and creates directories only when that fails.
- The spelling rows are two bit matrices (types, symbols) of `(2n+1) x ceil(n/64)`
  words per mangler instead of three byte matrices: about 5 KiB instead of 51 KiB per
  parallel shard for the compiler's 92 modules.

The manifest hash mixes eight bytes per step, each word read with one copy. After the
stream, the build engine's safety-net sync compares only the files the stream never
synced (`CcStream.synced`; the orphan sweep still walks the tree), the sink creates each
output directory once per build, and a tree that did not exist before the build skips
the emitter's orphan pruning.

## Shard policy

`[shards]` and `[instance-shards]` in build.toml map a module path to a count. The
count is an output schema: the manifest records it, and a build whose policy differs
from the previous manifest's names the migration on stderr (every shard of that module
is rewritten).

## Validation

- `sh ci/gate.sh`: strict C (`-std=c11 -Wall -Wextra -Werror`) over every unit,
  readability (one `.h` beside every module `.c`), the fixpoint, the worker-count
  identity, every target and profile.
- The per-TU cache replays chunk owners, `_ret` typedef owners, header edges and typed
  spelling rows (`RK_AUX`, `RK_HEDGE`, `RK_EDGE`); a replayed tree must match a
  `SC_NO_TU_CACHE=1` tree byte for byte after an edit (`tests/cli_test.spc`,
  `build_staleness_gates` covers the header-change and layout-change cases).
- `ci/fanout_report.py` reports both what the unit texts need and what the include
  graph delivers; a widening gap between the two means an owner rule or a header put
  a definition somewhere too broad.
