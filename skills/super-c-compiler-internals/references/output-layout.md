# Output layout: headers, shards and ownership

The emitted C tree is a function of the package's by-value type graph and of what every
translation unit spells. This is the record of the measured decision behind it, the
ownership rules, and the checks that keep it sound. Source of truth: the assembly and
write-out stages in `src/driver/emit.spc` (search `Assembly:`, `DefSet`, `unit_incs` and
`write_shard`), the definition chunks in `src/emit/tu.spc` and the spelling rows in
`src/emit/mangle.spc` (`modpfx`, `mark_used`, `um_hit_kind`, `need_name`, `need_ty`).

Identifier escape: `Mangler::ident` appends `_` to a name that is a C keyword or a macro
from the standard headers the emitted C includes (`c_keyword`, `c_std_macro`: `I`,
`errno`, `EOF`, the `E`/`SIG`/`FE_`/`INT*_MAX` families and the rest), for fields, payload
members, locals, parameters, captures and root-module items; an enum tag that joins into
such a macro is escaped too. An unprefixed file-scope symbol (a single-module root item, a
prelude item) that equals a name the included headers declare (`C_LIB_NAMES`, and the
`c_lib_family` prefixes such as `pthread_` and `int*_t`) gets the same `_` (`lib_escape`,
applied in `qualified()`, free-function symbols and enum tags). Extern names keep their
exact C spelling (`c_ident` escapes keywords only).

## Files

The tree is written to `gen_root`: `<root>/build/<profile>/raw` for a bare build and
`<out-dir>/<target dir>/raw` for a manifest build (the target dir is the profile name,
`<profile>-bin-NAME`, `<profile>-lib`, `test`, or `bench/<profile>`). `PROFILE` makes the
text depend on the profile, so each profile has its own tree, manifest, per-TU cache and
orphan pruning; a program that does not read it emits the same bytes under every profile,
and every tree comparison compares within one profile.

| File | Content | Included by |
|------|---------|-------------|
| `__sc_fwd.h` | runtime includes, the headers of `extern "C" "<header>"` blocks, dyn fat types, `@emit_macro` templates, assert helpers, extern and block-wrapper prototypes, dyn table and ZST sentinel declarations, plus copies of the type declarations those spell; no other type declaration | every generated file |
| `__sc_t/<stem>.h` | one definition header per emitted type (struct, union, payload enum, payload-less enum, generic instance, closure environment): the includes of the definition headers of the types its body embeds by value, the type's `typedef` line, copies of the other declarations the body spells, the definition, then the type's layout checks (`_Static_assert` of size and alignment) | units that need the type complete; definition headers that embed it by value; prototype headers whose `_ret` structs embed it or whose constant arrays have it as element |
| `<mod>.h` | the definition headers its `_ret` structs and constant arrays need, copies of the type declarations its prototypes spell, `_ret` typedefs, cross-TU prototypes, constant and descriptor declarations the module owns | TUs that spell one of its symbols (and the module's own shards) |
| `<mod>.c`, `<mod>__p<k>.c` | the includes (forward header, the definition headers the module's text needs, the prototype headers of the modules it spells symbols of), copies of the typedef lines of the types it names only through pointers, then the module's bodies, sharded by `stable_item_hash(symbol) mod count`; the count comes from the rendered size (`shard_policy`: one shard per 256 KiB of C; a count read from the previous `__sc_shards` is kept while every shard stays within half and one and a half times that), or from `[shards]` in build.toml; a static closure follows the body before it | |
| `<mod>__inst.c`, `<mod>__inst__p<k>.c` | generic instances of the module's generics, glue of its types, its constants and descriptors, dyn tables of its receivers (same policy per owner; `[instance-shards]` overrides); includes as for a module TU, from the instance context's rows | |
| `__sc_shards` | `super-c-shards<TAB>1`, then `module<TAB>tus<TAB>insts` for every module with more than one shard of either kind: the counts this build used, which the next build reads as its starting point | the next build |
| `__sc_registry.c` | ZST sentinels; the reflection registry: the `@reflect` roots sorted by symbol (each root is an external `const` with hidden visibility except on Windows, defined in its owner's instance shard), one pointer table, one constructor passing that sorted table to `__sc_reflect_register` once (the runtime keeps its address and count: no capacity limit, lookup never depends on constructor order) | |
| `__sc_manifest` | one record per output: kind, path, 64-bit content hash, owner module, shard index, generated headers included; the effective shard counts (`shards` lines, whether chosen or overridden); the C command inputs; the registry roots | tooling |

Every include line is relative (`../` per module directory level); the tree compiles
with no `-I` flag. A unit includes definition headers in stem order, then prototype
headers in module path order.

Definition header stems (`DefSet::stems`): the C name itself when it has at most 40 bytes,
else its first 23 bytes, `_` and the 16 hex digits of the name's FNV-64. Names that fold
to one stem case-insensitively (macOS and Windows file systems) all take the hashed form,
and the assembly asserts that the final stems are distinct after folding. The stems are
identifiers, so a stem is also the include guard (`SC_D_<stem>`). A stem depends only on
the type's own name, except in the case-folding collision, where a new type can rename
the header of the type it collides with.

## Ownership

- A type definition has one file: its definition header. The owner module recorded in the
  manifest is the declaring module (for a generic instance: the generic's, for a closure
  environment: the closure's); it places no file.
- A forward declaration has one home: an aggregate's typedef line lives in its definition
  header, a payload-less enum (the enum definition itself) likewise. A typedef line that
  no definition header holds (a zero-sized aggregate, a pointee no body needs complete)
  has no file. Every other file gets a copy of each declaration it names whose home it
  does not include: a header by one identifier scan of its text (`FwdDecls::copy`, and
  `FwdDecls::scan_def` for a definition header, which in the same scan finds the types
  the body embeds by value: a declared name outside parentheses followed by a declarator
  name), a unit from its spelling row (`FwdDecls::want`, no scan of the unit text). C11
  allows a repeated typedef, and an enum copy keeps its `SUPER_ENUM_` include guard. C11
  has no forward-declared enum, and prototypes take enums by value, so a prototype header
  gets the full enum.
- A unit's definition headers come from its type-need row (`Mangler::tneed`, one row per
  spelling context like the use rows): the FNV of each aggregate C name its text uses, bit
  0 set when the text needs the complete type. The C type speller records every
  aggregate, instance or closure environment it spells: complete outside a pointer,
  typedef only below a pointer or inside a function-pointer type (`ptr_depth`). The body
  emitter records complete needs where the text uses a value without spelling its type
  (`Mangler::need_ty`): a member access through a pointer or on a static, forwarded call
  or captured-environment base, a dereference used as a value, a subscript, pointer
  arithmetic, a discriminant read, a call result used in place, a static used as a value,
  an enumerator constant, a closure environment literal and the closure body's `__env`,
  and the fixed texts that name `str`, `Global` and `Vector__str`. A member access on a
  declared local or on a member of a complete aggregate records nothing: the declaration
  and the embedding definition already need the type. A missing record fails the strict C
  gate with an incomplete or unknown type. A unit includes the definition header of every
  complete need and gets a copy of the typedef line of every other one. The rows are sets:
  their order, and the repeats a direct-mapped filter lets through (`tn_seen`,
  `tn_recent`), never reach the output.
- Layout checks live in the definition header of the checked type, so a unit checks the
  types it includes and a new type changes no unit; an extern aggregate (defined by a C
  header) keeps its check in its module's first shard. The checks are rendered with
  `no_edges` set: they record no use edge and no type need for the module's unit.
- The headers of `extern "C" "<header>"` blocks are global (`__sc_fwd.h`): every TU can
  call a header-declared extern function, so the Core IR inliner splices a callee that
  calls one (the `std/bits.h` bit counts behind `u64::trailing_zeros`) into any TU.
- A `_ret` struct belongs to the function's module and lands in its prototype header
  (callers need it complete); that header includes the definition headers of its
  by-value fields (`hdr_k`/`hdr_h`: the field's definition key, spelled under the body's
  substitutions, so a generic instance's `_ret` resolves to the instance's header).
- A function instance body belongs to the generic's declaring module; free glue to the
  destroyed type's owner (the generic's module for instances, matching where the drop
  site's symbol edge points); a constant to its declaring module; a `type_info`
  descriptor to the described type's owner (`core` for builtins); a dyn table to the
  receiver type's owner, else the interface's module.
- A module-prefix spelling records a (context -> owner) edge on the mangler only where
  the C text uses the item: a type edge inside a C type spelling (`ctype`, `type_name`,
  `inst_type_name`), a symbol edge for a symbol's own prefix, and no edge inside a symbol
  segment (`type_m`, `inst_name`, `args_m`, `dyn_stem` outside a C type: the `util__K`
  of `gen__size__util__K`), because a name inside a mangled symbol needs no C
  declaration of the type; the enclosing symbol records its owner. A context is
  a module TU or `CTX_INST | owner` for an owner's instance shard, and the assembly-time
  renderers (constants, descriptors, dyn tables, block wrappers) switch to the owner's
  context. A shard includes the prototype headers of its symbol row plus its own
  module's; its definition headers come from the type-need row (above), and the type
  edges now only keep a module's TU alive for the transitive TU pruning. Symbols spelled without a
  module prefix of their own (`String__free` and `Vector__T__push` led by an `inst_name`
  segment, `__sc_ti__T`, fixed-text `Global__alloc`) record their owner explicitly; a new spelling path that omits the
  edge fails the strict C gate with an implicit declaration. A query that only asks
  whether something exists spells nothing: an edge recorded by a spelling the output
  never uses adds an include, and when a memo answers the same query in one worker but
  not in a parallel shard, the tree depends on the worker count (`is_destructible`
  asks `Mangler::find_method`, not `method_by_name`). Demand keys are symbol segments,
  so they record no edge; the call's own symbol records the context's edges. The body's
  identifier reservation spells every local's C type with `Mangler::no_edges` set: a local
  the output declares records its edge and its type need at the declaration, and a
  zero-sized local is never declared.

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

### Forward declarations

Before: `__sc_fwd.h` held every aggregate typedef, closure env typedef and payload-less
enum, and every unit includes it, so adding or renaming any type recompiled 164 of 167
units. Now each declaration lives in its home type header and a header copies only the
declarations it spells (see Ownership). Measured on the compiler's own tree (dev profile,
14 cores, object cache off), adding one unused `pub struct`:

| Module | Units recompiled before | after |
|--------|-------------------------|-------|
| `lexer::token` | 164 of 167 | 95 of 166 (its type header is in the include closure of 95 units through `ast`) |
| `fmt::doc` | 164 of 167 | 8 of 166 |
| `driver::stats` | 164 of 167 | 4 of 166 |

The copies add 1.4% of emitted C (10150 to 10290 KiB, 79 KiB of typedef lines and
47 KiB of enum definitions in headers). Self-transpile codegen, two alternating A/B
runs: 215.4 / 214.1 ms before, 215.7 / 215.7 ms after (noise). Cold build (every cache
off) 8.9 s and no-op build 0.12 s, both unchanged.

Edges follow the same rule. Before, a symbol segment recorded a type edge
(`String__new__Global` gave its unit `__std/interfaces__types.h`, which holds only the
zero-sized `Global`), and so did the identifier reservation of every local type. Measured
on the compiler's own tree (dev profile, object cache off, 167 units), adding
`pub struct Zst {}` to `std/interfaces.spc`: 93 units included that header and 93
recompiled before; 3 include it and 3 recompile after (`main.c` casts to `Global *` in
the fixed-text `main` wrapper, and the module's own two units). Include lines in the
units drop from 2964 to 2736. Self-transpile codegen, two alternating A/B runs:
217.0 / 216.6 ms before, 216.8 / 216.5 ms after (noise).

### Definition headers per type

Before: one type header per by-value module SCC (`<mod>__types.h`), included by every unit
whose row spelled a type of the module, so any type edit rewrote that header and
recompiled every unit including it. Now each type has its own definition header and each
unit includes the headers of the types its text needs complete (see Ownership). Measured
on the compiler's own tree (dev profile, 14 cores, object cache off, 167 units), units
recompiled after each edit:

| Edit | before | after |
|------|--------|-------|
| add a `pub struct` to `lexer::token` | 96 | 0 |
| add a `pub struct` to `fmt::doc` | 7 | 0 |
| add a `pub struct` to `driver::stats` | 4 | 0 |
| swap the two fields of `tok::Span` | 96 | 66 |

The 66 are exactly the units whose include closure holds `token__Span.h`, and each of
them fails to compile against a typedef-only `Span` (checked by replacing the header), so
each needs the definition. A new type recompiles no unit because its layout check lives
in its own header, not in its module's first shard.

The tree grows from 162 to 927 headers (839 definition headers; include lines in units
2736 to 7261, in headers 368 to 1807; headers 846 to 1003 KB, units 9804 to 9978 KB, of
which 78 are unit typedef copies). Self-transpile codegen (bench binaries of both trees
over the same sources, alternating, 4 rounds): 216.3 ms before, 218.7 ms after (+1.1%,
the need records and the assembly). Cold build (every cache off, ccache off) 11.41 s
before and 11.34 s after (median of 4 alternating runs); no-op build 98 to 101 ms both.
The no-op build reads more and longer depfiles, so the engine's staleness check stats
each dependency path once per build and walks the generated tree without a stat per
`.c`/`.h` name.

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
- The per-TU cache replays chunk owners, `_ret` typedef owners, header edges (`RK_HEDGE`:
  owner module and definition key), typed spelling rows (`RK_EDGE`) and the module's
  type-need row (`RK_TNEED`: its sorted distinct keys as word pairs); format version 5.
  A replayed tree must match a `SC_NO_TU_CACHE=1` tree byte for byte after an edit
  (`tests/cli_test.spc`, `build_staleness_gates` covers the header-change and
  layout-change cases).
- `tests/cli_test.spc`: `build_type_edit_stays_local` (a type edit leaves units without
  the module's types untouched), `build_new_type_recompiles_no_user` (a new type in a
  module every unit uses recompiles no unit; removing it prunes its header and its
  manifest record), `build_field_edit_recompiles_users` (a field edit recompiles the
  owner and the by-value user, not a pointer-only user or a user of another type of the
  module).
- The stale-output pruning keeps exactly the files this build wrote (the `keep` list), so
  the definition header of a type that disappears is removed; the manifest records every
  definition header (kind `h`, owner module, the headers it includes).
- `ci/fanout_report.py` reports both what the unit texts need and what the include
  graph delivers; a widening gap between the two means a need record or a header put
  a definition somewhere too broad.
