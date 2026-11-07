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
| LIR lowering CFG (every core block's successors, which `share_plan` reads too) and dominators | `Lower::cfg`, `Lower::dominators` | `Lower` (`sat`, `sl`, `order`, `preds`, `idom`), per body | end of `Lower::body` |
| Storage-marker liveness, one step per block (`live & keep \| born`) | `Lower::share_plan` | locals, per body | end of `share_plan` |
| Address exposure, argument modes | `Lower::scan` (`arg_mode`) | `Lower`, per body | end of `Lower::body` |
| Type classes | `Lower::ty` | `Lower.cc.tcache` (`Lower::tkey`: a final type id alone, a provisional one with its module) | whole build |
| Field lists | `Lower::fields_of` (`member` reads `fpool` in place) | `cc.fcache`, `cc.fpool` | whole build |
| Shapes of payload enums | `Lower::enum_of`; `fields_of` stores the shape its `decl_fields` placed | `cc.ecache` | whole build |
| Register leaves of an aggregate | `Lower::layout_of` (`leaves`) | `cc.lcache`, `cc.lpool` | whole build |
| Static asserts of a module; instances checked | `cemit_inst_asserts` (graph, checker queue, drain) | `Interp` (`sa_list`, `sa_done`) | whole build |
| Layouts (size, align, offsets) | `ir::layout` `Svc` | one cache per `Svc` owner (each `Mangler`, `Lowerer`, interpreter) | whole build |
| `@owned` fields of a concrete referent | `owned_of` (`owned_fields`) | `cc.ocache`, `cc.opool` | whole build |
| Frozen (no `UnsafeCell`) of a concrete type | `frozen_top` (`frozen`) | `cc.zcache` | whole build |
| The caches above (`lw::LCaches`) in a parallel emission | each shard task takes the set of its pooled task context and gives it back (`CEmit::swap_caches`) | `DropCtx.lc` | whole build |
| Package constants of an emitter (backends, `names_vectors`, the mangler's prelude lookups, niche declarations and C library names) | `CEmit::new`, `Mangler::new`; a shard copies the master's (`CEmit::new_like`, `Mangler::new_like`) | each emitter; the C library names one `Arc` | whole build |
| Uses of each instruction during slot forwarding | `forward_slots` (`inst_uses`) | `Tidy.uat`, `Tidy.ul` | the forwarding; `drop_unused_slots` reads its slot use counts (`snuse`) when nothing forwarded |
| Package part of the native cache key | `nat_base` | a local per loop (a module's key: its emission key xor it) | per loop |

## optimize (`lir::opt` `Run`, `S_LOWERED` to the end of the `lir_opt` block)

Per package, in `Run::new`:

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| Calls of each body: callee, argument roots | `calls_of` | `Calls` | `Run::new` |
| Memory effects, written and escaping parameters | `effects` (over `Calls`; a worklist over the callers of each body, `rc`, and the bodies that pass to its parameters, `rp`), `own_effects`, `own_escapes`, `stalls` (counts over `rc`) | `Sym.fx`, `Sym.esc`, `Run.wargs` | end of the build |
| Call-graph levels and job edges; the bodies whose job finished | `levels`; each job's end | `Run.level`, `Run.edges`, `Run.order`; `Run.fin` (`await_marked` waits on it) | end of the build |
| Inliner shape test; a finished body's inliner facts (inlinable, `small` within `SHRINK` and the run's budget, `forwarder`, computes with floats) | `Run::new`; `il::facts` after the job (a held body's in `Run::new`) | `Run.shape`; `Run.ok` (`IL_*`) | end of the build |

Per body, on `Opt` (`Run::job` runs the passes in order). `Opt::tables(pk, b, want)` computes
only the levels `kept` lacks (`K_GRAPH` < `K_DOM` < `K_NEST` < `K_MEM` < `K_SLOTS`); every change to
the body sets `kept = K_NONE`, and `forget` runs at a job's start, after inlining, after `direct_known`
makes calls direct, and when a job takes a scratch back after its wait (`Run::ready`). `thread`, which
moves edges alone, keeps `K_GRAPH` (`cfg` and the predecessors again, the operands of the terminators
and of its rewrites spliced in, `splice_ops`); `estimate` computes `cfg` alone. `preheaders`
keeps `K_NEST` (`enter_tables` gives the tables a fresh computation gives), and in `loop_opts`
`unpreheaders` takes back the tables `save_tables` copied:

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| Successors, RPO, predecessors; block of each instruction; operand lists (CSR) | `Opt::graph` (`block_map`, `operands`) | `Opt` (`pred_at`, `preds`, `pblock`, `blk_of`, `ops_at`, `ops`, `ops_dst`) | `K_GRAPH`: any change |
| Per instruction, its readers up to 2, and whether an `or` reads it | `Opt::readers` (from `ops`), at the start of `thread` and of the walk | `Opt` (`icount`, `in_or`; `counted`) | the next `operands` or `splice_ops` |
| Dominator tree and its pre/post numbers | `Opt::dominators` | `Opt` (`dpre`, `dpost`) | `K_DOM`: any change |
| Loop nesting, preheaders, loop blocks in block order | `Opt::nest` | `Opt` (`inner`, `lparent`, `preh`, `lb_at`, `lbs`) | `K_NEST`: any change |
| Private slots and the slot each address derives, alias classes and their scope roots' bases, slot escapes, frozen memory, per-block and per-loop writes and tags | `Opt::memory` (`privates`, `classes`, `slot_escapes`, `root_bases`, `frozen`, `bw`, `bt`, `bpw`, `bst`) | `Opt` (`pder`, which `slot_escapes` and `slot_apart` read through `der_slot`; `cbase` among them) | `K_MEM`: any change |
| Slot base, offset, escape | `Opt::slot_writes` | `Opt` | `K_SLOTS`: any change |
| Slots an instruction still addresses | `Opt::rebuild`, `emit` | `Opt.sused` | the next rebuild |
| The pool records and `lines` entries a body names (dead ones dropped; `compact_lines` keeps equal entries apart) | `Body::compact_pool`, at the end of `Run::job` | `Body.pool`, `Body.lines` | the next pass that adds records |
| Rare blocks | `Opt::estimate` | `BLOCK_RARE` flags on the body | any block change; codegen reads them too |
| Loop weights | `Opt::weigh` | `Opt` | any edge or block change |
| Unsigned upper bound of a value | `Opt::ubound` | not stored | per call |
| A loop's blocks and the block of each instruction for the loop transforms | `LoopOpt::shape` (from `Opt`'s `lb_at`, `lbs`), `LoopOpt::candidates` (a copy of `blk_of`, `pblock`, which the transforms extend) | `LoopOpt` (`inl`, `lblocks`, `owner`, `powner`) | the loop's transform |
| Loop counter, trip count, exit test | `LoopOpt::counted_by`, `trip`, `cf_test` (`lir::loops`) | `LoopOpt`, per loop | the loop's transform |
| Header counts and shape test of a loop | `LoopOpt::header_counts` | caller | the loop's transform |
| Closed form's leaving values and their targets | `LoopOpt::close_plan` (no change), then `close_apply` | `LoopOpt` (`lout`, `tgt_of`, `tused`, `cf_leave`) | `close_apply` |
| Promotion candidates, the slots addresses derive (`collect`, for `merges` too) | `Promoter::collect`, `Promoter::merges` (`lir::promote`; graph and operand lists from `Opt`) | `Promoter` | the promotion |
| SLP predecessor tables | `Slp::plan` (`lir::slp`; block map and use counts from `Opt`'s `blk_of`, `pblock`, `ops`) | `Slp` | the packing |
| Operand lists of one instruction | `lir::verify` `uses`, `uses_into` | caller's vector | per call |

A pass that returns false must leave the body unchanged; the next pass then reuses the facts
above. Recompute a fact only after a change that the "Valid until" column names.

## codegen (`native_plan` to `S_GENERATED`)

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| RPO, predecessors of reached blocks (CSR), loop nesting, rare blocks, fold decisions, use counts | `Live::analyze` (`reverse_postorder`, `loops`, `rare_blocks`, `folds`; `Live::run` adds `relayout`) | `Live` (`rpo`, `npred`, `pat`, `preds`, `inner`, `pfold`, `count`) | end of the function, retries included |
| Block layout, live ranges, last uses, folded use lists (CSR) | `Live::relayout` (`layout`, `ranges`; `uses_of`) | `Live` (`pos`, `end`, `ua`, `un`, `uv`) | a change of the layout (`after`) |
| Rare blocks | `Live::rare_blocks` (none under `Live::in_place`: wasm) | `Live` | end of the function; the optimizer's `BLOCK_RARE` holds the same fact only when `lir_opt` ran |
| Next use of each folded operand | `Live::ranges`, reverse walk of the existing operand CSR; `Live::advance` consumes it | `Live.next`, `use_next`; native eviction scoring reads `next` | layout change; cursors advance once per instruction |
| Register home classes and prefix cuts | `Live::plan`; safe cuts reuse `pat`, `preds`, `pos` | `Live.home`, `cut`, sorted `splits`; native `home_at` and `save_splits` consume them | next home plan or layout change |
| Operand list of one instruction (edge arguments included) | `live::each_use`; folded: `Live::uses_of` | caller's vector; `Live` | per call |
| Special operations of the body | `lv::op_flags` | `Gen.opf` | end of the function, retries included |
| Stack canary | `lver::protected` | `Gen.prot` | end of the function, retries included |
| Wasm structure (idom, loop headers, forward edges) | `codegen::structure` `Shape::run` (reads `Live`'s `rpo`, `pat`, `preds`) | `Shape` | end of the function |
| Call layout of a signature | `call_layout` (a64gen, x64gen), `cc::classify` | `Gen` (`lays`, `lay_at`) | end of the function |
| Intrinsic template of each body symbol | `intrin::of_symbols` | `Gen.itpl` | end of the function |
| Calls that return, clobber, dead ends | `call_tables` | `Gen` (`cret`, `cpre`, `rarec`) | end of the function |
| Object symbol of a package symbol | `osym_of` (wasm `pkg_osym`) | `Gen.osym` | end of the object |
| Object sections, symbols, relocations | `codegen::obj` `Obj` | `Obj`, then the object bytes | the object write |

## publish, sync, link

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| Object bytes | `nat::object` | `NatObj.bytes`, then the `.o` file and the link's `lu::Mem` | the link reads them (memory) |
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

- lower: a native build still renders the C text of its constants and statics, of its aggregates'
  definitions and of the extern headers' checks, which only the C backend reads, and spells each
  callee's symbol again per calling module for the cross-unit edges (which choose the objects too);
  `Svc` holds one copy per owner.
- lower: `dead_stores` scans back from the block's end for each storage end (about one
  instruction per call in the self-build).
- optimize: `LoopOpt` analyses a rejected loop again in each round; the exit test has four
  decoders (`cf_test`, `trip`, `counted_by`, `checks`), and `top_of` repeats part of `ubound`;
  `Slp::plan` builds every block's in-edges (`graph`'s predecessors hold no edge ids and cover the
  reached blocks only); `return_slot` builds operand lists after a `run`'s rebuild left no tables;
  `thread`'s header test repeats `nest`'s; `only_use`, `only_in` and `only_step` scan the whole body
  per query.
- codegen: `Live::rare_blocks` repeats the optimizer's `BLOCK_RARE` when `lir_opt` ran; each
  object compiles its own copy of the unowned package data it names (string literals; weak with
  `-fdata-sections`, so the link keeps one); a64gen and x64gen hold parallel copies of the
  target-dependent parts of the register allocation (`edge_moves`, `continues`, `entry_reg`,
  `param_home`, `call_tables`, `plan_homes` and more).
- publish, sync, link: the linker parses again the objects the build had in memory, and reads the
  replayed ones from their files; the four linkers repeat `global`, `out_section` and the
  `copy_sections` loops.
