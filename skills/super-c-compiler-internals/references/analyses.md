# Analysis Inventory: Native Backend

The facts each backend phase computes, where the result lives, and what makes it stale.
Read the phase's table before you add a traversal, analysis, table, or pass
(`super-c-task-discipline` section 10). Reuse a fact while it is valid, extend its
producer, or keep it valid through your transform. Update this file in the same change
when you add, remove, or move an analysis. The source is authoritative for names; this
file is authoritative for where to look first.

## lower (`cemit_package`, `B_PLAN` to `S_LOWERED`)

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| Core CFG, RPO, idom | `ir::facts` `build_cfg` (bce) | facts state, per body | bce folds an edge |
| C control-flow shape (RPO, idom, postdominators, loops) | `emit::cflow` `build_into` | `cem.cf_ext` | read only by the C renderer; not built in a native build |
| LIR lowering CFG and dominators | `Lower::cfg`, `Lower::dominators` | `Lower`, per body | end of `Lower::body` |
| Address exposure, argument modes | `Lower::scan` (`arg_mode`) | `Lower`, per body | end of `Lower::body` |
| Type classes | `Lower::ty` | `Lower.tcache` (key includes the module) | whole build |
| Field lists | `Lower::fields_of` (`member` reads `fpool` in place) | `fcache`, `fpool` | whole build |
| Layouts (size, align, offsets) | `ir::layout` `Svc` | one cache per `Svc` owner (each `Mangler`, `Lowerer`, interpreter) | whole build |
| `@owned` fields of a concrete referent | `owned_of` (`owned_fields`) | `ocache`, `opool` | whole build |
| Frozen (no `UnsafeCell`) of a concrete type | `frozen_top` (`frozen`) | `zcache` | whole build |
| Package part of the native cache key | `nat_base` | a local per loop (a module's key: its emission key xor it) | per loop |

## optimize (`lir::opt` `Run`, `S_LOWERED` to the end of the `lir_opt` block)

Per package, in `Run::new`:

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| Calls of each body: callee, argument roots | `calls_of` | `Calls` | `Run::new` |
| Memory effects, written and escaping parameters | `effects` (over `Calls`), `own_effects`, `own_escapes` | `Sym.fx`, `Sym.esc`, `Run.wargs` | end of the build |
| Call-graph levels and job edges | `levels` | `Run.level`, `Run.edges`, `Run.order` | end of the build |
| Inliner shape test | `Run::new` | `Run.shape`; after a job, `Run.ok` | end of the build |

Per body, on `Opt` (`Run::job` runs the passes in order). `Opt::tables(pk, b, want)` computes
only the levels `kept` lacks (`K_GRAPH` < `K_DOM` < `K_NEST` < `K_MEM`); every change to the body
sets `kept = K_NONE`, and `forget` runs at a job's start and after inlining:

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| Successors, RPO, predecessors; block of each instruction; operand lists (CSR) | `Opt::graph` (`block_map`, `operands`) | `Opt` (`pred_at`, `preds`, `pblock`, `blk_of`, `ops_at`, `ops`, `ops_dst`) | `K_GRAPH`: any change |
| Dominator tree and its pre/post numbers | `Opt::dominators` | `Opt` (`dpre`, `dpost`) | `K_DOM`: any change |
| Loop nesting, preheaders, loop blocks in block order | `Opt::nest` | `Opt` (`inner`, `lparent`, `preh`, `lb_at`, `lbs`) | `K_NEST`: any change |
| Private slots, alias classes and their scope roots' bases, frozen memory, per-block and per-loop writes and tags | `Opt::memory` (`privates`, `classes`, `root_bases`, `frozen`, `bw`, `bt`, `bpw`, `bst`) | `Opt` (`cbase` among them) | `K_MEM`: any change |
| Slot base, offset, escape | `Opt::slot_writes` | `Opt` | any instruction change |
| Slots an instruction still addresses | `Opt::rebuild`, `emit` | `Opt.sused` | the next rebuild |
| Rare blocks | `Opt::estimate` | `BLOCK_RARE` flags on the body | any block change; codegen reads them too |
| Loop weights | `Opt::weigh` | `Opt` | any edge or block change |
| Unsigned upper bound of a value | `Opt::ubound` | not stored | per call |
| Loop counter, trip count, exit test | `LoopOpt::counted_by`, `trip`, `cf_test` (`lir::loops`) | `LoopOpt`, per loop | the loop's transform |
| Header counts and shape test of a loop | `LoopOpt::header_counts` | caller | the loop's transform |
| Closed form's leaving values and their targets | `LoopOpt::close_plan` (no change), then `close_apply` | `LoopOpt` (`lout`, `tgt_of`, `tused`, `cf_leave`) | `close_apply` |
| Promotion candidates | `Promoter::collect`, `Promoter::merges` (`lir::promote`) | `Promoter` | the promotion |
| SLP predecessor tables | `Slp::plan` (`lir::slp`; block map from `Opt`) | `Slp` | the packing |
| Operand lists of one instruction | `lir::verify` `uses`, `uses_into` | caller's vector | per call |

A pass that returns false must leave the body unchanged; the next pass then reuses the facts
above. Recompute a fact only after a change that the "Valid until" column names.

## codegen (`native_plan` to `S_GENERATED`)

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| RPO, predecessors of reached blocks (CSR), loop nesting, rare blocks, fold decisions, use counts | `Live::run` (`reverse_postorder`, `loops`, `rare_blocks`, `folds`) | `Live` (`rpo`, `npred`, `pat`, `preds`, `inner`, `pfold`, `count`) | end of the function, retries included |
| Block layout, live ranges, last uses, folded use lists (CSR) | `Live::relayout` (`layout`, `ranges`; `uses_of`) | `Live` (`pos`, `end`, `ua`, `un`, `uv`) | a change of the layout (`after`) |
| Rare blocks | `Live::rare_blocks` | `Live` | end of the function; the optimizer's `BLOCK_RARE` holds the same fact only when `lir_opt` ran |
| Homes | `Live::plan` | `Live` | end of the function |
| Operand list of one instruction (edge arguments included) | `live::each_use`; folded: `Live::uses_of` | caller's vector; `Live` | per call |
| Special operations of the body | `lv::op_flags` | `Gen.opf` | end of the function, retries included |
| Stack canary | `lver::protected` | `Gen.prot` | end of the function, retries included |
| Wasm structure (idom, loop headers, forward edges) | `codegen::structure` `Shape::run` (reads `Live`'s `rpo`, `pat`, `preds`) | `Shape` | end of the function |
| Call layout of a signature | `call_layout` (a64gen, x64gen), `cc::classify` | `Gen` (`lays`, `lay_sig`) | end of the function |
| Intrinsic template of each body symbol | `intrin::of_symbols` | `Gen.itpl` | end of the function |
| Calls that return, clobber, dead ends | `call_tables` | `Gen` (`cret`, `cpre`, `rarec`) | end of the function |
| Object symbol of a package symbol | `osym_of` (wasm `pkg_osym`) | `Gen.osym` | end of the object |
| Object sections, symbols, relocations | `codegen::obj` `Obj` | `Obj`, then the object bytes | the object write |

## publish, sync, link

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| Object bytes | `nat::object` | `NatObj.bytes`, then the `.o` file | end of `run_package` (memory) |
| Output file hash, manifest line | `out_hash`, `man_line` | manifest | end of the build |
| Per-TU cache image | `driver::tuc` | `.tu_cache` | next emitting build |
| Parsed input objects | `parse_object` (`link::macho`, `elf`, `pe`, `wasm`) | linker state | end of the link |
| Function parts of a section | `split_sections` | linker state | end of the link |
| Part of a symbol | `part` (binary search) | not stored | per call (COFF writer: once per symbol) |
| Relocations of each section | Mach-O writer, one pass | `rat`, `rix` (writer locals) | the object write |
| Live relocations, their resolved globals | `mark_live`, `scan_relocations`, `apply_relocations` | linker state | end of the link |

## Known recomputations

These recompute a fact the compiler already holds. Remove each line when it is fixed. Do
not copy their pattern into new code.

- lower: a native build still renders the C signature, local names and the C tree (headers,
  `__sc_registry.c`, manifest `h` lines) that only the C backend reads; `Svc`, `tcache` and
  `fcache` hold one copy per owner or per module.
- optimize: `LoopOpt` analyses a rejected loop again in each round; the exit test has four
  decoders (`cf_test`, `trip`, `counted_by`, `checks`), and `top_of` repeats part of `ubound`.
- codegen: `Live::rare_blocks` repeats the optimizer's `BLOCK_RARE` when `lir_opt` ran; each
  object compiles its own copy of the unowned package data it names (string literals: 3712
  extra copies over 298 objects in a self-build); a64gen and x64gen hold identical copies of
  `arg_relays`, `relay_parts`, `parts_taken`, `dead_end`, `edge_moves`, `resolve_moves` and more.
- publish, sync, link: the linker reads back and parses the objects the build had in memory; the
  four linkers repeat `read_object`, `take_members`, `global` and `copy_sections`.
