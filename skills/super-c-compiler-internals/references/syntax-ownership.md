# Syntax ownership: the body arena

Every module keeps two syntax arenas (`src/ast/ast.spc`). The module arena (`Ast.nodes`,
`Ast.children`) holds the declarations, every signature, every constant initializer and
every pinned body. The body arena (`Ast.b`) holds the releasable bodies: the block of every
function that is not generic, not `const fn`, not an interface member and not a member of
a generic `extend`, with the nodes a desugar appends to such a body. The driver frees the
body arenas once the last reader of body syntax has run, before emission plans and
renders the C, which is where the build's memory peaks. This is the record of the
measurement that gated the change (plan v2/7), the design, the release contract and the
results.

## Measurement

One transpile of the compiler (92 modules, 5.0 MiB of source, release compiler, one
worker) before the split:

| Value | Result |
|-------|-------:|
| nodes after parse | 737k at 60 B = 46.4 MiB retained (children 1.8 MiB) |
| nodes inside bodies | 641k (87%) in 4,855 bodies = 36.7 MiB |
| syntax live after resolve, typecheck, emission | unchanged: 76 MiB of frontend data survived to the peak |
| body semantic side tables | resolutions 8.7 MiB, types 4.3 MiB, other tables 5.2 MiB |
| largest module (`typechecker`) | 103k nodes, 9.9 MiB retained |
| peak live / peak RSS | 160 MiB at the plan phase / 197 MiB |
| bodies emission re-lowers | generic, `const fn` and interface-default bodies: 1,607 bodies, 65k nodes (10%) |
| LSP retention per open or closed document | the workspace package, 93.5 MiB (bodies 39%), the same for a closed document |
| body edit in the largest module | 67 ms; 365 unchanged sibling bodies re-checked (about 7 ms of it) |

Edit latency does not depend on syntax ownership: the recheck closure is the module because
the checker keeps module-level tables, and 48 ms of the 67 were a quadratic dead-store lint
(fixed separately; the round is 17 ms now). The gate the user accepted is the batch peak:
release the body syntax and its per-node tables before the plan phase. `SC_SYNTAX_STATS=1`
prints the accounting per phase (parse, resolve, typecheck, borrowck, release, emit).

## Ids and arenas

A NodeId with bit 30 (`NODE_BODY`) set indexes the body arena at `id & NODE_BODY_MASK`;
every other id indexes the module arena. A NodeList start carries the same bit for the
body arena's child array. The accessors (`at`, `at_const`, `list`, `type_of`, `set_type`,
`resolution_def`, `set_resolution_def`, `type_args`, `dyn_use_at`, `deref_use_at`)
dispatch on the bit; the body arena owns its own `types`, `resolutions`, `mono_at`,
`dyn_at` and `deref_at` tables so a release frees them too. Both arenas are `SplitVec`s:
`freeze_nodes` / `freeze_resolutions` pin both before a parallel stage appends.

The parser routes through `Ast.sink_body`: `parse_function` turns it on for a releasable
body (the `pinned` argument, the `pin_scope` of an interface or generic extend, and the
function's own generics decide) and restores it after the block and its named-return
bindings. A later stage that appends nodes sets the sink to the arena of the body it
extends: the HIR lowering per marker, the checker per function body (`check_item`), the
LSP's `reparse_fn_body` from the old body's arena.

Rules for every scan and every table indexed by node id:

- Enumerate both arenas: `nnodes()` and `nth_id(k)` (module arena first). A scan that
  appends nodes walks the two arenas over their pre-loop counts, since `nth_id` reads the
  live module-arena length.
- Index a per-node scratch table by `dense(id)`, never by the raw id; test membership with
  `valid(id)`. A raw body id is above `NODE_BODY` and a table sized to it costs a gigabyte.
- Ordering by id holds inside one arena (post-order: children before parents). Across
  arenas a body id sorts after every module id.
- Closure symbols spell `closure_<node>` for a module-arena closure and
  `closure_b<index>` for a body-arena one (`Mangler::closure_sym`).

## Release contract

`Package::release_bodies` runs in `run_package_i` after `emit_order`: every body is
lowered and kept (`irl::Keep`), every deferred constant is flushed, the lints and the
always-panics check have run, the live set and the emit order have read their last
reference. A NODE_BODY read after that is a bounds abort in `Vector::at`. `super-c lint`
and the test harness never release: their pipelines stop before emission. The LSP releases
per document, see below.

What emission reads of a body after the release, and the owned record that carries it:

| Reader | Record |
|--------|--------|
| the inliner's callee vetting (`callee_slot` lowered callees from syntax per task) | `InlineStore` (`src/ir/inline.spc`): every kept env-free lowering that some kept body calls is vetted once in `cemit_package` (size gate first), accepted callees copied compact; `Package.inl_store` for the emission's lifetime, read by every task |
| a user local's declaration: its name text, kind (`let`, parameter, loop binding, pattern name) and a `[T; 0]` annotation | `LocalDecl.name()` (offset and length inside its span), `LocalDecl.dkind` (`LK_*`), `LocalDecl.zero_len`, filled by `Lowerer::local_decl`; the record stays 32 bytes |
| a closure's captures (names and types), parameter and return types, mutable-capture mask; a `fn(..)` type written in a body | `Ast.closure_facts` / `cap_facts` (`ClosureFact`, `CapFact`): recorded by `check_closure_in` and by the `fn` type lowering, the mask finalized by the borrow checker (`flow_ir`), types remapped at publication |
| inline assembly text | `CoreBody.asms` / `asm_spans` (`AsmRec`), copied by `lower_asm`; the rvalue's `item.node` is the record index |
| the declarations a `free` method's body touches (free-glue completion) | `Ast.free_touched`, recorded by `tc_record_free_touches` after the body check |

The `SC_FACTS_CHECK` watermarks carry the body arena's counts separately and skip them
once the arena is released.

## Results

Release compilers over the same source, one worker, `--cc=true` (`SC_BUILD_STATS=-
SC_BUILD_MEM=1`, `SC_SYNTAX_STATS=1`); before = the compiler without the split:

| Measure | Before | After |
|---------|-------:|------:|
| nodes retained at typecheck (capacity) | 47.8 MiB | 56.4 MiB (the two arenas' reserves; freed at the release) |
| syntax retained after the release: nodes, children, resolutions, types, other tables | 47.8 + 1.8 + 8.7 + 4.3 + 5.2 MiB | 13.8 + 0.6 + 1.3 + 0.7 + 1.7 MiB |
| live at the borrow-check boundary | 121.5 MiB | 129.4 MiB |
| live at the plan boundary (the peak) | 160.7 MiB | 114.5 MiB |
| live at the publish boundary | 133.0 MiB | 82.9 MiB |
| peak RSS | 206 MiB | 190 MiB |
| LSP workspace package retained, every document open | 93.5 MiB | 100.8 MiB (reserves and fact tables) |
| body edit round in the largest module | 17 ms | 20 ms (under a concurrent test run) |
| serial self-transpile round, three interleaved pairs (Mcyc medians) | 1710 / 1716 / 1762 | 1757 / 1768 / 1762 (+2.7%) |
| in-process benchmark: heap requested per round, peak RSS over 100 rounds | 419 MiB, 256 MiB | 435 MiB, 270 MiB |

The peak RSS drops less than the live bytes: the high-water mark now sits in the checks and
prepare phases (176 MiB after borrow checking, the always-panics engines and the flush), before
the release; the plan phase adds 12 MiB over it where it added 44 before. The in-process
benchmark, which transpiles a hundred times in one process, reports a higher high-water mark
than before (the arenas' reserves and the freed body blocks' placement between rounds) even
though each round retains less. The cycle cost is the arena select in every node accessor
(typecheck and borrow checking read every body node) less the emission savings; the hot full
scans hoist the module-arena count (`Ast::nth_id_n`) and the accessors select the arena once
and inline a single access.

Two consumers of body syntax were changed rather than recorded: the inliner no longer
re-lowers a callee per emission task (1,363 lowerings per transpile of the compiler became
one vetting pass over the keep), and the free-glue pass no longer rescans the module per
`free` method at emission. Two latent defects surfaced by the release and fixed: the
emitter located a downcast's enum through a reference type's module (module 0, read as
an unrelated node), and the borrow checker's moved bitset was indexed by the raw node id.
The emitted C differs from the previous compiler only in closure symbol spelling and the
order of hoisted closure bodies; the two-generation fixpoint holds.

## The language server: closed documents release

The server keeps one package per root for its whole life, and only the open documents' bodies
serve a positional feature. After every analysis round (`lsp::analysis::compile`,
`compile_batch`, `recompile`) `release_closed` frees the body arena of every module without an
editor buffer, except the modules the constant engine has demanded (below). `Ast::release_bodies`
also drops the seeds aimed at body nodes, so a later `init_resolutions` never writes past a
fresh arena. The module arena, its type table and every fact table stay, so declarations,
signatures, hover text and the retained diagnostics need nothing back.

A released module's bodies come back through `reparse_bodies`: the module's source parses
again and that parse's body arena replaces the empty one. The parser is a function of the
source alone, so the arena is byte-identical to the one the release freed: every body id, every
fn node's body field and every parse-time side table entry (attributes, lifetimes) is valid
again, and the module resolves and typechecks again to refill the arena's per-node tables (HIR
lowering is idempotent over the module arena; the checker's `init_types` resets the fact
tables). The round parses back:

- the module of a document that opened (`opened`: re-analyzed alone, importers keep their
  analyses since the ids are stable), before the body-splice probe reads its body spans;
- every closed member of the affected closure (a signature edit's importers), before their
  re-resolve;
- every module the engine demanded during the passes (`typecheck_set`).

The constant engine reads foreign bodies for folds and `const fn` scans (`Interp::body_of`,
`fx_scan_fn`). `Interp::body_avail` refuses a body-arena node whose arena is released or not
sized by a check yet, and records the module in `Interp.body_missing` (a refusal for an item
not yet in `tc_done` records too). `typecheck_set` checks the members of a set in import
order (`dep_order`: closure members first, cycles in index order) with a fresh engine per
pass and fresh `tc_done` records for the members; after the pass it parses every demanded
released module back, marks it in `Package.body_hold` (held modules never release again in
that package: the next round needs no parse-back), adds it to the set, and runs the next pass
over the demanders (the members whose check or always-panics probe met a refusal) plus the
parsed-back modules, replacing their records. A refusal of a member typed later in the same
pass stays a refusal, as in a batch build; every extra pass parses at least one module back,
so the passes are bounded by the module count.

A feature that reads a closed module's bodies parses them back through `ensure_bodies`
(re-resolve and re-check with lints off, records discarded): `Server::locate`, `locate_range`
and `hier_locate` for the request's own module (a client may query a document it never
opened), the document-level handlers that map their document themselves, `hydrate_roots`
(every module of every built root) before references, rename and incoming calls, and the
callee's module before outgoing calls. `decl_signature` finds the signature's end at the
first brace after `fn` instead of reading the body node. The next round releases those modules
again. `SC_LSP_STATS=1` prints one line per round: modules, released, held, KiB retained, ms,
parsed back, extra passes.

Release server over the compiler workspace (manifest root 92 modules, workspace batch 169
modules), one document open (`src/lsp/features.spc`), before = the server without the release:

| Measure | Before | After |
|---------|-------:|------:|
| retained after initialize: manifest root, batch root | 101.1 MiB, 124.5 MiB | 43.4 MiB, 61.7 MiB |
| RSS after initialize | 287 MiB | 224 MiB |
| initialize (compile, compile, batch; the manifest root compiled twice) | 225 + 201 + 158 ms | 227 + 158 ms (the seeding build is republished) |
| round on `didOpen` | none | 33 ms (module parsed back, one demanded module, one extra pass) |
| body edit round | 15 to 18 ms | 17 to 19 ms |
| RSS while editing | 290 MiB | 225 to 231 MiB |
| first references query after a round | 0 ms | 228 ms (261 modules parsed back and re-analyzed) |
| RSS after that query | 290 MiB | 278 MiB |
| RSS after `didClose` (a full rebuild) | 313 MiB | 314 MiB |

The full compile keeps every body live until its last phase, so a rebuild's high-water mark
does not move; the retained state between rounds halves. Held modules after the session: one
(a fold's callee), two after the references query.
