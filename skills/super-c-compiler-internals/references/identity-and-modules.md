# Identity Model and Package Architecture

## Identity Model

### NodeId (`u32`)

An index into one of a module's two syntax arenas. Bit 30 (`NODE_BODY`) set: the body arena
(`Ast.b`, the releasable bodies: every function body that is not generic, `const fn`, an
interface member or a member of a generic `extend`); clear: the module arena (`Ast.nodes`:
declarations, signatures, constant initializers, pinned bodies). Module-local. Every AST
item, expression, type annotation, and pattern is a node. The accessors dispatch on the bit;
a scan enumerates both arenas through `nnodes()` / `nth_id()`, and a per-node scratch table
is indexed by `dense(id)`. Module-arena id 0 is the reserved empty sentinel, but body-arena id
0 is a real node, so a per-arena scan starts at 0. A batch build frees every body arena once,
in `cemit_package` after the instance graph and its per-instance `static_assert` check,
before the C is planned and rendered; the language server frees a closed document's after every round and parses it
back on demand (`BodyArena.released`, `Interp.body_missing`); the model, the release contract
and the owned records the later passes read instead are in
[syntax-ownership.md](syntax-ownership.md).

A node's payload is the `NodeAs` union (`src/ast/ast.spc`), at most 20 bytes, so a node is 32
bytes. The kinds with a larger payload (asm, function, struct and enum, interface, extend,
generic parameter, the three `for` forms, closure: `ext_kind`) keep it in the `ext` table of
the node's arena (`NodeExt`); the node holds its index and, for a declaration, a copy of its
name (`ExtRef`). Read the payload with `Ast::ext(id)`, the name with `Ast::ext_name(id)`, write
with `Ast::ext_mut(id)`, and create such a node with `Ast::add_ext` (the parser's
`mk_ext`/`fin_ext`). All three panic on a node of another kind: test the kind first, also
before a `pick`, which evaluates both values. A wrong-variant read of an inline payload returns
heap-dependent bytes, which passed on macOS and Linux and failed only on Windows, in LSP
completion, constant evaluation and `dyn fn` handling. Keep every `NodeAs` member at 20 bytes
or less (`static_assert(sizeof(Node) == 32)`); a larger payload joins `NodeExt`, and rare data
goes to an `Ast` side table (a type path's associated type bindings: `Ast::type_bindings`).

### ItemId

An index into the package index's item table (`PkgIndex.items`: every top-level and associated
declaration), dense for one compilation. `Package.sched` (`ItemSched`) holds one record per
item: a stable key (module path and ordinals: no node id), a post-typecheck signature hash,
schedule and final dependency ranges, the schedule component and the component graph the
item scheduler runs, the item's own node ranges, and the monotone readiness state (Resolved,
Checking, Checked, IrReady). The constant engine and the checker decide what an item may read
as checked by the static visibility rule over the components (`graph::items::visible`: a
dependency component, an earlier item of the same component, a prelude item). Built by
`graph::items` after resolution (inside the resolve frontier's tasks); the scheduler, the
rule and the measurements are in [item-index.md](item-index.md).

### DefId

Cross-module identity (`src/ast/ast.spc:22`):

```superc
pub struct DefId { pub module: ModuleId, pub node: NodeId }
```

Used by the resolution side table (`Ast.resolutions: SplitVec<DefId>`) to record where a
name resolves.

### TypeId (`u32`)

An index into the package type table (`Package.tt`, a `TypePool`): structurally equal
types share one id across every module. A type interned before its publication
checkpoint gets a provisional id (bit `TYPE_PROV`) in the module's own `Ast.pool`;
`publish_types` renumbers every provisional record into the package table in a
canonical order at the start of borrow checking and again at the start of emission, and
remaps every retained table. Final ids are identical for one worker and every worker
count. The instance graph interns straight into the package table. An `Ast` without a
package (`gt == null`, unit tests) keeps module-local ids. The model, the ordering, the
validation switches and the measurements are in
[type-identity.md](type-identity.md).

### ModuleId (`u16`)

An index into `Package.modules`. Directory names are sorted at load so ids are
deterministic regardless of readdir order (`src/module/loader.spc`).

## Package and Module Architecture

`Package` owns all modules. One `.spc` file = one module. The prelude (`std/*.spc`) is
auto-loaded and its public decls resolve unqualified. Abridged from
`src/module/loader.spc:25`:

```superc
pub struct Module {
    pub path: String,   // "__std::string" (prelude) / "lexer::token"; root = its file stem
    pub file: String,   // filesystem path the source was read from
    pub source: String, // file contents (span offsets index into it)
    pub ast: Ast,       // parsed AST; after hir::lower runs it IS the module's HIR
    pub has_ast: bool,
    pub prelude: bool,
}

pub struct Package {
    pub modules: Vector<Module>,
    pub root_dir: String,  // imports resolve relative to it
    pub gen_root: String,  // where the emitted C tree goes (default <root>/build/<profile>/raw)
    pub std_root: String,  // second import search root
    pub cir: *mut void,    // the Core IR interpreter (opaque to avoid a type cycle)
    pub jobs: u32,         // --jobs worker count (0/1 = serial)
    // ... plus demand/liveness tables: method_used, always_methods,
    // co_spans (safepoint reachability), ...
}
```

**In-place mutation:** each stage mutates a module's Ast through a raw pointer into its
Package slot. There is no `override_ast` indirection (it was deleted); the Ast never
leaves its slot, so lookups that land back on the in-flight module read the live tree.

**Cross-module lookup:** `Package::lookup(from, mid, name, want_type)` finds a top-level decl
of module `mid` that module `from` sees (`FROM_ANY`: the compiler's own lookups, every item
visible beyond its file). It is **O(1)**: a byte-exact symbol probe plus one name-map probe into
the package declaration index (`ensure_index`, built in deterministic module and source order),
whose name maps hold every item visible beyond its file with its level (`ItemMeta.vis`), then
`Package::vis_ok`: one level compare, then a package compare (`Module.pkg`) or a prefix compare of
the asking file's path with the owner's `Module.scope`. `Package::qual_lookup` is what `m::x`
names: `m`'s own item, else one its glob imports reach (`PkgIndex.globs`); an implicit directory
index (`Module.implicit_index`, file = the directory and a `/`, source synthesized by
`loader::read_module`) reaches its files' own items and reports an ambiguity. The resolver checks
signatures for less visible types (`check_leaks`) and the typechecker field and member levels
(`field_seen`, `member_seen`).

**Mangling** (`src/emit/mangle.spc`, the frozen symbol-naming authority):

- Module prefixing is on only when the package holds **more than one non-prelude
  module besides the runtime** (`Package::rt_module`, `std/rt/base.spc`, whose own symbols
  always take its prefix) **and the prelude's dependencies** (`Package::prelude_dep`: a std module
  that only prelude modules import, such as `std::spec::seq`; its symbols always take their prefix,
  and it emits only what live code names, as a prelude module); single-file programs emit plain C names, except a top-level name that a prelude
  item also has (`PkgIndex.pl_names`, the shadow set), which `Mangler::ident` escapes with `_`
  (`format` becomes `format_`).
- A module prefixes with just its **last path segment** when no other non-prelude module
  shares it; the full `a__b__` path otherwise. A user module whose first prefix segment begins
  a prelude symbol (a prelude type, interface or generic function name, or a builtin type name:
  `PkgIndex.pl_stems`, `Mangler::prelude_stem`; bit 1 of `short_table`) takes one more `_`
  after that segment: `str___len`, `Vector___i32__push`.
- Prelude modules are never prefixed. The program entry (`Package::is_entry`: the root
  module's top-level `main`, `Package.root`; each listed file of a batch lint) is never prefixed,
  and the driver renames it `__sc_user_main` under the C `main` wrapper. Every other `main` (another
  module's, a method) is an ordinary function: prefixed, unchecked against the entry signatures,
  linted. An extern function IS its C symbol: never prefixed, never suffixed.
