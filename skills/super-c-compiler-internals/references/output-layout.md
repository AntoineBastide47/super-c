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
applied in `qualified()`, free-function symbols and enum tags). A name that is such a name
followed by underscores gets one more `_` (`escaped_stem`), so the escape stays injective: `sqrt`
spells `sqrt_` and a name `sqrt_` spells `sqrt__`. Extern names keep their exact C spelling
(`c_ident` escapes keywords only).

## Files

The tree is written to `gen_root`: `<root>/build/<profile>/raw` for a bare build and
`<out-dir>/<target dir>/raw` for a manifest build (the target dir is the profile name,
`<profile>-bin-NAME`, `<profile>-lib`, `test`, or `bench/<profile>`). `PROFILE` makes the
text depend on the profile, so each profile has its own tree, manifest, per-TU cache and
orphan pruning; a program that does not read it emits the same bytes under every profile,
and every tree comparison compares within one profile.

| File | Content | Included by |
|------|---------|-------------|
| `__sc_fwd.h` | runtime includes, the headers of `extern "C" "<header>"` blocks that `super_rt.h` includes too, dyn fat types, `@emit_macro` templates, assert helpers, the `__sc_wrap` address conversion, extern and block-wrapper prototypes that need no definition header (one that does, by an array declarator of an aggregate or a scoped header's alias, is a declaration of the units that call it: `split_protos`), dyn table and ZST sentinel declarations, plus copies of the type declarations those spell; no other type declaration | every generated file |
| `__sc_t/__scx<k>.h` | one per scoped `extern "C" "<header>"` header (`XHdr`, numbered in an order that keeps every module's block order, first declared first among the ready headers, and on a cycle the first declared left): the `__scx` files of the scoped headers a module's earlier blocks name (`pre`: `<psapi.h>` needs `<windows.h>`, `<windows.h>` needs `<ws2tcpip.h>`; only lower numbers, so no cycle), the header's include, one `#define __sc_x_<name> <name>` per item C spells by name (`extern_block_aliases`), then the checks of its blocks' types and constants | the units, definition headers and prototype headers whose text spells one of its aliases; the registry unit when it has checks and no unit includes it |
| `__sc_t/<stem>.h` | one definition header per emitted type (struct, union, payload enum, payload-less enum, generic instance, closure environment, result carrier): the includes of the definition headers of the types its body embeds by value, the type's `typedef` line, copies of the other declarations the body spells, the definition, then the type's layout checks (`_Static_assert` of size and alignment) | units that need the type complete (also as the result carrier of a `_ret` typedef or the element of an array declarator they declare); definition headers that embed it by value or as an array element; prototype headers whose `_ret` typedefs name it or whose array declarators have it as element |
| `<mod>.h` | the definition headers of the result carriers its `_ret` typedefs name and those of the element types of its array declarators (parameters, constants), copies of the type declarations its prototypes spell, `_ret` typedefs, cross-TU prototypes, constant and descriptor declarations the module owns | C code that calls the module (the module's interface); no generated file (a unit declares what it uses) |
| `<mod>.c`, `<mod>__p<k>.c` | the includes (forward header, the definition headers the module's text and its declarations need), copies of the typedef lines of the types it and its declarations name only through pointers, the cross-TU declarations (of every prototype header) its text spells, `_ret` typedefs first (`XDecls`, below), then the module's bodies, sharded by `stable_item_hash(symbol) mod count`; the count comes from the rendered size (`shard_policy`: one shard per 256 KiB of C; a count read from the previous `__sc_shards` is kept while every shard stays within half and one and a half times that), or from `[shards]` in build.toml; a static closure follows the body before it | |
| `<mod>__inst.c`, `<mod>__inst__p<k>.c` | generic instances of the module's generics, glue of its types, its constants and descriptors, dyn tables of its receivers (same policy per owner; `[instance-shards]` overrides); includes as for a module TU, from the instance context's rows | |
| `__sc_shards` | `super-c-shards<TAB>1`, then `module<TAB>tus<TAB>insts` for every module with more than one shard of either kind: the counts this build used, which the next build reads as its starting point; `packs<TAB>n`, the pack count, read the same way; `pch<TAB>1` when the units compile through the precompiled header of `__sc_fwd.h` (from `PCH_UNITS`, four, units that include it: each shard that compiles alone, each pack), which a build that plans the tree without its emission reads | the next build |
| `__sc_registry.c` | in every program: the external definitions of the inline helpers of `super_rt.h` and `__sc_fwd.h` (`SC_RT_EXTERNS`, `extern __typeof__(f) f;` per helper, which C11 6.7.4p7 makes the unit's definitions external whatever its include order); ZST sentinels; the reflection registry: the `@reflect` roots sorted by symbol (each root is an external `const` with hidden visibility except on Windows, defined in its owner's instance shard), one pointer table, one constructor passing that sorted table to `__sc_reflect_register` once (the runtime keeps its address and count: no capacity limit, lookup never depends on constructor order) | |
| `__sc_unity.c` | only for a small program (module, instance and registry units under `UNITY_MAX`, 2 MiB of C, and more than one of them): one `#include` per such unit, in write order. The build compiles it alone and none of its members: one compiler process, the shared headers parsed once (about 4 times less compile CPU on a test program). A test runner, wasm's C library and a unit that includes a `__scx` file, also through a definition header (`tu_x`, `inst_x`, `reg_x`: the header's macros would reach the members after it, its declarations the members before it), compile on their own | the build (the only C unit of its members) |
| `__sc_pack<k>.c` | only for a larger program with at least two units of one shard and less than `PACK_UNIT` (64 KiB) of C: one `#include` per such unit whose file stem hashes to pack `k` modulo the pack count, in write order, written after every unit (`pack_plan`). The count is `shard_policy` of those units' bytes from the previous `packs` line of `__sc_shards`; every pack below the count is written, an empty one too. The build compiles each pack and none of its members | the build (the only C unit of its members) |
| `__sc_manifest` | one record per output (kind `u` for `__sc_unity.c` and the packs): kind, path, 64-bit content hash, owner module, shard index, generated headers included; the effective shard counts (`shards` lines, whether chosen or overridden); the C command inputs; the registry roots | tooling |

Every include line is relative (`../` per module directory level); the tree compiles
with no `-I` flag. An `extern "C" "<header>"` header is named from the including file: relative when the file and the tree both lie below
the working directory, else by absolute real path (`include_name`, `src/driver/util.spc`), so a
tree that moves with its project emits the same text. A unit includes definition headers in stem order, then prototype
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
- A pointer to an array whose innermost element is an aggregate the emitter defines
  (`Mangler::ptr_wraps`: every length positive) spells as a pointer to the array's wrapper
  struct `<element>__a<N>` (one `_<M>` per inner dimension; `struct Node__a2 { Node e[2]; }`),
  everywhere: members, locals, parameters, function-pointer parameters, container storage.
  C needs an array's element complete even below a pointer, and inside the definition of a
  self or mutually recursive aggregate it is not; a pointer to an incomplete struct is legal.
  The wrapper has the array's size, alignment and layout (its layout check says so), so
  pointer arithmetic and the ABI are the array pointer's. A dereference or a subscript of
  pointer storage reads the member (`(*p).e[1]`, `v.ptr[i].e`), and an array's address
  converts as a value through `__sc_wrap` (`(Node__a2 *)__sc_wrap(&a)`; a decayed array
  through `void *`): no lvalue is ever accessed as another type, and no cast applies to an
  address, which the strictest strict-aliasing diagnostics flag. Each wrapper is defined in
  its element's definition header, after the element, and its typedef line leads that
  header's body (the element's members may point at it); a use through a pointer copies the
  typedef, and a dereference needs the element complete, which includes the wrapper. The
  manglers request each wrapper once (`wrap_reqs`, rendered text), the seed shards merge them
  by range (`CapMark.wrap`), the per-TU cache journals them (`RK_WRAP`), and the assembly
  orders them by element and name.
- A forward declaration has one home: an aggregate's typedef line lives in its definition
  header, a payload-less enum (the enum definition itself) likewise. A typedef line that
  no definition header holds (a zero-sized aggregate, a pointee no body needs complete)
  has no file. Every other file gets a copy of each declaration it names whose home it
  does not include: a header by one identifier scan of its text (`FwdDecls::copy`, and
  `FwdDecls::scan_def` for a definition header, which in the same scan finds the types
  the body embeds by value: a declared name outside parentheses followed by a declarator
  name, and the element type of every array declarator, also below a pointer or in a
  function-pointer parameter: C rejects an array of an incomplete type), a unit from its
  spelling row (`FwdDecls::want`), plus those its cross-TU declarations spell. C11
  allows a repeated typedef, and an enum copy keeps its `SUPER_ENUM_` include guard. C11
  has no forward-declared enum, and prototypes take enums by value, so a prototype header
  gets the full enum.
- A unit's definition headers come from its type-need row (`Mangler::tneed`, one row per
  spelling context like the use rows): the FNV of each aggregate C name its text uses, bit
  0 set when the text needs the complete type. The C type speller records every
  aggregate, instance or closure environment it spells: complete outside a pointer and as
  the element of an array declarator, typedef only below a pointer or inside a
  function-pointer type otherwise (`ptr_depth`). The body
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
  types it includes and a new type changes no unit; an extern enum keeps its check in its
  module's first shard. Every defined instance of a module's generic aggregate is checked, whichever
  module's records name it (`inst_recs`). A header struct or union has its layout and field checks in
  its header's `__scx` file (in `__sc_fwd.h` for a header `super_rt.h` includes), by its C name, so
  every unit that includes the header runs them once, and the registry unit includes every `__scx`
  file with checks that no unit includes (`unit_reach`), so they run also where no unit uses the
  header (a constant that folds to its value). A registry that includes one compiles alone (`reg_x`):
  the header's declarations would meet the names of the pack's earlier members. A field of another header's type names that type by alias, so the file includes its
  header. The checks are rendered with `no_edges` set: they record no use edge and no type need for
  the module's unit.
- A scoped header (`Package::extern_header_scoped`: a header of `extern "C" "<header>"` blocks
  that `super_rt.h` does not include, or any header of the runtime module `std/rt/base.spc`, of a
  block with a function that needs no CPU feature) reaches only the files that use one of its items.
  The runtime's blocks are scoped so that their checks (POSIX types and constants) stay out of
  `__sc_fwd.h`, which C code built at another feature level includes through an emitted header. Its macros would otherwise rename the identifiers of
  every file (`<windows.h>` defines `near`, `far`, `small`, `interface` and hundreds more). The
  emitter spells every such item by alias (`mbe::x_alias`, from `Package::xscoped`, which
  `scope_extern_items` fills before the inliner runs): a function, a static, a type and an
  enumerator as `__sc_x_` and its C name, a space as `_` (`__sc_x_struct_stat`, apart from function
  `__sc_x_stat`). No other C name spells an alias, so the name scans are exact:
  `FwdDecls::add_header` makes a definition or prototype header include the `__scx` file (`scan`),
  and `XDecls::add_header` a unit (`unit_incs`); a local or a field named like a header function
  brings no header. The alias survives the emission cache with the text. A header-less prototype
  that names an alias is a unit declaration (`split_protos`), without its `extern`, which
  `decl_name` reads as an object's. A unit that includes a `__scx` file, directly or through a
  definition header (`x_reach`), compiles outside the packs (`tu_x`, `inst_x`), and so does every
  unit of wasm's C library (`Package::is_libc`), which compiles with `-fno-builtin`
  (`loader::libc_unit`). A declaration of
  `__sc_fwd.h` that names an alias (a trait-object table whose method names a header type, an
  `@emit_macro` template) makes the forward header include the `__scx` file: every file then sees
  that header. A header `super_rt.h` includes stays in `__sc_fwd.h`, by C
  name: every file has it already. The inliner splices no callee that calls an item of a scoped
  header, or holds a value of its type or reads its static (`is_global_extern_fn`, `ty_scoped`):
  the splice would bring the header, and its macros, into the caller's unit. A unit that uses a
  scoped header itself sees its macros: a local named `near` there fails the C compile. Every TU
  can call any other header-declared extern function (and a header-less one through its
  prototype, below), so the Core IR inliner splices a callee that calls one into any TU; the runtime's bit counts (behind `u64::trailing_zeros`) and atomics (`ffi/atomic.spc`, verified intrinsic calls) are inline definitions with external linkage in every
  TU's `super_rt.h` (an inline function with external linkage may call them: C11 6.7.4p3), so a callee that calls one splices too (`detect::dispatch`'s acquire
  load). A splice accepts an argument whose C value is the parameter's: a reference into a
  pointer parameter, a function into a function-pointer parameter.
- An extern function of a block without a header gets a prototype in `__sc_fwd.h`
  (`CEmit::collect_extern_proto`), typed from its declaration (the parameter and result
  annotations' recorded types in the callee's module), unless an always-included header declares
  it (`Mangler::c_lib_declared`: `C_LIB_NAMES` and `c_lib_family`) or its name starts with `__sc_`
  (an entry point of the runtime, `std/rt/base.spc`, which `super_rt.h` or the runtime module's
  prototypes declare), or `super_rt.h` defines it (`rt_h::rt_defines`, `sc_ctz64`): a declaration
  without `inline` would make every unit's copy an external definition. An extern `malloc`, `calloc`, `realloc` or `free` outside the runtime spells
  the leak tracker's `sc_lk_*` entry (`Mangler::tracked_alloc`), which `super_rt.h` declares. The prototype binds a function whose header the build's feature
  macros cannot include (macOS `sysctlbyname`).
- A `@thread_local` static's definition and declarations take `_Thread_local`
  (`CEmit::stat_specs`). Every access spells `(*sym__tls())`, a per-unit `static noinline`
  accessor under a `sym__tls_d` guard (`CEmit::tls_accessor`) that the static's demand writes
  with its declaration (`stat_demand`, and the place demand in `emit_place_base`); a
  header-owned one records a `StatRef` too, so `stat_decls` and `stat_items` stay aligned. The
  demand key is the hash of the C symbol, salted for an extern binding (`CEmit::stat_key`): a
  binding and a definition of one C object (wasm's `errno`, which `ffi/errno.spc` binds and
  `std::rt::libc` defines; `environ`, which a program binds with no header) take two entries, so
  the binding never hides the definition.
  `XDecls::add_all` takes the guarded block through its `#endif` as one declaration of
  `sym__tls`, and a unit that spells the accessor gets the static's declaration with it.
- A module-level `asm` item emits `__asm__("<template>");` in the module's first unit
  (`push_c_asm_str` re-escapes a matchertext template); `module_has_asm` keeps such a module
  emitted (`keep_mod`) and gives it a unit.
- A result list `(A, B)` is one result, the tuple's `TupleN` struct (the parser makes the list a
  tuple type). A result C cannot return as it is (one fixed array)
  returns in a carrier struct shared by every function and function value with that result
  (`Mangler::ret_pack`: `__sc_ret<n>__<types>`, `__sc_reta__<array>`), defined in its own
  definition header; a function's `<name>_ret` typedef aliases it in the module's prototype
  header, which includes that definition header (`hdr_k`/`hdr_h`: the carrier's name key,
  spelled under the body's substitutions); a function-pointer spelling needs only its typedef.
  A dyn vtable slot returns the carrier itself (`dyn_ret`), and a call through the vtable
  declares its destination with it (`untyped_ret_struct`: the declaring interface's result list
  under its arguments in the dyn type's hierarchy, `dyn_iface_inst`), since no `<name>_ret` alias
  exists for an erased callee.
- A vector is the struct `__sc_v<N>_<lane>` (`{ _Alignas(A) T l[N]; }`, `A` the layout
  alignment; under `Mangler::vec_regs`, a build that plans backend entries, a vector of 2 to 16
  bytes whose alignment is its size holds `T l __attribute__((vector_size(S)))`, so its lanes have
  no address: a lane place or a constant's pointer to a lane spells `((T *)&v)[i]`, byte moves
  `(char *)&v + off`; a wider one of 16-byte chunks also names them, `union { l; c[k]; }`, so a
  split operation reads and writes `v.c[k]`; `Mangler::vec_def`, which records the chunk's need
  wherever the vector's is recorded, since its definition names the chunk), defined once per mangler as a pack (`Mangler::vec_pack`, `pack_reqs`) in its own
  definition header, which also carries the lane-check helper `__sc_lane` under an include
  guard, and asserts the layout model; a mask is its storage integer (`uint8_t` to `uint64_t`).
  In mangled names a vector is `__sc_v<N>_<lane>` and a mask `__sc_mask<N>`: the runtime's
  reserved prefix, which no user type spells.
- A dyn vtable (`<stem>__vt`) holds `__free`, `tid`, the interface's methods, then each
  superinterface's methods (breadth first, `dyn_supers`: the checker records each interface
  bound's `dyn I<args>` on the bound node, grounded here under the dyn type's arguments), then one
  `__super_<superstem>` pointer per superinterface. A table's super pointers name the source
  type's tables for those superinterfaces with the same ownership and allocator; an upcast keeps
  `.data` and reads `.vt->__super_<stem>`.
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
  context. A shard declares the cross-TU declarations its text spells, from one identifier
  scan of the text of its module TU or instance unit (`XDecls`, `xd_rows`: the rows on up to
  eight workers, the largest first; 29 ms of CPU for the compiler's 16 MB of C, about 5 ms of
  wall time) against the declared names of every prototype header (`decl_name`, which reads an `@export`
  function's parenthesized `(name)(` declarator); C parses
  every declaration it includes: whole prototype headers cost the compiler's build about 10%
  of its clang compile and 4% of its gcc one. Its definition headers come from the type-need row
  (above), and the edges only keep a module's TU alive for the transitive TU pruning. Symbols spelled without a
  module prefix of their own (`String__free` and `Vector__T__push` led by an `inst_name`
  segment, `__sc_ti__T`, fixed-text `Global__alloc`) record their owner explicitly; a new spelling path that omits the
  edge can prune the TU that defines the symbol (a link error). A query that only asks
  whether something exists spells nothing: an edge recorded by a spelling the output
  never uses adds an include, and when a memo answers the same query in one worker but
  not in a parallel shard, the tree depends on the worker count (`is_destructible`
  asks `Mangler::find_method`, not `method_by_name`). Demand keys are symbol segments,
  so they record no edge; the call's own symbol records the context's edges. The body's
  identifier reservation spells every local's C type with `Mangler::no_edges` set: a local
  the output declares records its edge and its type need at the declaration, and a
  zero-sized local is never declared.

## Decision record

Before: two shared headers (`__sc_types.h` 145 KiB, `__sc_protos.h` 410 KiB) included
by every TU, and one shared instance TU (523 KiB, two parts, 58 owner modules): a
signature edit recompiled 87 of 91 units, a layout edit 69 to 87, and any generic body
edit rewrote the instance TU.

Rejected: nominally separate headers per module for the `std::core` /
`std::parallel::atomics` / `std::parallel::sync` by-value cycle. They would include
each other and invalidate the same units; the cycle gets one SCC header
(`__std/core__types.h`).

Accepted (the layout above). The type graph is a DAG (no type-level SCC), with one
3-module SCC at the module level. A layout edit of the prelude's `str`, `String` or
`Vector` (spelled by nearly every unit) or of `lexer::token` (`Span` is embedded by the
AST, which every pass embeds) is a whole-program rebuild by construction. A generic body
edit (`Vector::push` in `std/vector.spc`) rewrites the two `__std/vector__inst` shards and
no header, and leaves the registry TU byte-identical; changing a `[shards]` count prints
the migration notice and rewrites that module's shards only.

Targets set before the change and met: a body edit recompiles only the module's own
shards; a signature or layout edit in a leaf module recompiles under 10% of the units;
no header include cycle; the forward header under 64 KiB; byte-identical two-generation
fixpoint and `--jobs=1` versus `--jobs=N` output.

### Forward declarations

Before: `__sc_fwd.h` held every aggregate typedef, closure env typedef and payload-less
enum, and every unit includes it, so adding or renaming any type recompiled 164 of 167
units. Now each declaration lives in its home type header and a header copies only the
declarations it spells (see Ownership).

Edges follow the same rule. Before, a symbol segment recorded a type edge
(`String__new__Global` gave its unit `__std/interfaces__types.h`, which holds only the
zero-sized `Global`), and so did the identifier reservation of every local type.

### Definition headers per type

Before: one type header per by-value module SCC (`<mod>__types.h`), included by every unit
whose row spelled a type of the module, so any type edit rewrote that header and
recompiled every unit including it. Now each type has its own definition header and each
unit includes the headers of the types its text needs complete (see Ownership). A field
swap in `tok::Span` recompiles exactly the units whose include closure holds
`token__Span.h`, and each of them fails to compile against a typedef-only `Span` (checked
by replacing the header), so each needs the definition. A new type recompiles no unit
because its layout check lives in its own header, not in its module's first shard.

The tree grows from 162 to 927 headers (839 definition headers; include lines in units
2736 to 7261, in headers 368 to 1807; headers 846 to 1003 KB, units 9804 to 9978 KB, of
which 78 are unit typedef copies). Self-transpile codegen (bench binaries of both trees
over the same sources, alternating, 4 rounds): 216.3 ms before, 218.7 ms after (+1.1%,
the need records and the assembly). Cold build (every cache off, ccache off) 11.41 s
before and 11.34 s after (median of 4 alternating runs, when the build compiled C); no-op build 98
to 101 ms both.

## Emission cost of the layout

Measured, when the build compiled C, on the release compiler with a no-op C compiler (`--cc=true`,
`SC_CEMIT_STATS=1`), which isolates emission from compilation: the assembly stage takes
1 to 2 ms; the write stage 240 to 260 ms, of which the build engine's per-file sink
(`sync` in the probe report, 293 files) took 180 to 210 ms against 165 ms for the 162
files of the old layout. Three costs had to be removed to get there:

- The C object cache (since removed) hashed every included header again for every unit (7x
  with dependency-local headers); it then memoized each file's transitive hash per build.
- Parent directories were created with one `mkdir` per path component for every file;
  `publish_file` now opens first and creates directories only when that fails, and
  `mkdir_p` stats the full path before it walks the components.
- The spelling rows are two bit matrices (types, symbols) of `(2n+1) x ceil(n/64)`
  words per mangler instead of three byte matrices: about 5 KiB instead of 51 KiB per
  parallel shard for the compiler's 92 modules.

One tree: the emitter writes `gen_root` in place and the build reads it. Before, a
manifest build wrote every file into `raw/` and its sink wrote it again into a
content-synced `gen/`, the compiled tree (about 95 ms per emitting build on macOS, 24 to
49 ms on Linux, 254 to 350 ms on Windows). Now `publish_file` (`std::platform::fs::publish`) compares each
file with the text first (its size, then its bytes; never the manifest's hash, which would
hide a hand edit) and writes only a changed file, with one `write` call, so an unchanged
file keeps its mtime. The sink hears whether each file changed. The headers are
published on up to four workers (`publish_batch`; file creation in one directory scales
about 2x on APFS: at `--jobs=4` the write stage less its sink takes 82 instead of 151 ms on a
fresh tree), then recorded and reported in manifest order, so the tree, the manifest and the
sink's order do not depend on the worker count. The manifest hash is
`skey_mix(FNV_BASIS, str_id(text))` over each file's whole text. Measured on the
self-build (`--jobs=1 --cc=/usr/bin/true`, min of 3): the write stage 363 to 141 ms on a
fresh tree and 284 to 81 ms on an unchanged one; tree files created 2741 to 1369 cold, and
none on an unchanged tree; `mkdir` calls 3778 to 236; the write stage's allocations
280k to 195k cold.

A tree that did not exist before the build skips the emitter's orphan pruning, and the
pruning stats only names that are not `.c` or `.h`.

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
  type-need row (`RK_TNEED`: its sorted distinct keys as word pairs), array wrapper
  requests (`RK_WRAP`) and result carrier requests (`RK_PACK`); after the sections, per
  module its held record (`lir::hold`: what its own object gives the LIR optimization of
  the other units), under its key and native key; format version 14.
  A replayed tree must match a `SC_NO_TU_CACHE=1` tree byte for byte after an edit
  (`tests/cli/cli_test.spc`, `build_staleness_gates` covers the header-change and
  layout-change cases).
- `tests/cli/cli_test.spc`: `build_type_edit_stays_local` (a type edit leaves units without
  the module's types untouched), `build_new_type_recompiles_no_user` (a new type in a
  module every unit uses recompiles no unit; removing it prunes its header and its
  manifest record), `build_field_edit_recompiles_users` (a field edit recompiles the
  owner and the by-value user, not a pointer-only user or a user of another type of the
  module).
- The stale-output pruning keeps exactly the files this build wrote (the `keep` list), so
  the definition header of a type that disappears is removed; the manifest records every
  definition header (kind `h`, owner module, the headers it includes).
