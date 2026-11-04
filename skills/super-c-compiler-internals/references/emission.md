# Emission Buffers, Probes and the Output Tree

## Emission Buffers and Probes

`CemitOut` holds one geometrically grown buffer per TU (`TuBufs`: `tus[t]` plus
`tu_incs[t]`, `tu_heads[t][k]` per shard, `tu_tail[t]` and the chunk table
`ck_off`/`ck_end`/`ck_shard` indexed by `tu_chunks[t]`; `inst_c` with
`inst_incs`/`inst_heads`/`inst_chunks` per owner module; `fwd_h`, `defs_h[d]` (one
definition header per type, file `__sc_t/<defs_stem[d]>.h`), `protos_h[m]`, `registry_c`). A consumer that inspects the emitted C (the test harness,
the bench sink) must concatenate the headers, every shard head, the buffers and the
tail; the driver assembles each shard into one reused buffer (`shard_text`, reserved to the
shard's length) and publishes it with `publish_file`: one compare, and one write call
when the content changed. The layout, ownership and shard rules are in
[output-layout.md](output-layout.md).
Symbols, type spellings and call strings render once and intern into pools
(`sym_memo`, `sx_nm_pool`, `sx_cs_pool`); a generic call's symbol interns under the
fingerprint of (callee, receiver instance, targs, env), the same key the demand dedup
uses, so only the first spelling per TU context constructs it. The recursive renderers
(`emit_operand` through inlined temporaries, `emit_region` through structured control
flow) share a nesting counter bounded by `RENDER_NEST_MAX` (256, clang's bracket depth).
An `else if` chain renders flat (`} else if (..) {` in a loop), and a region that follows
arms that do not fall through continues in the caller's loop instead of recursing, so only
a falling chain whose tests need statements first still nests per arm. A body whose
structured regions pass the bound fails the dry planning pass and takes the flat goto
layout (`plan_structured`).
A `TM_SWITCH` of two or more cases on a non-boolean discriminant is a native C `switch`
in both layouts, so the C compiler builds a jump table (an `if` chain gets none from MinGW
gcc): each target's case labels together (`SWITCH_LINE_CASES` to a line; a range lists
every value, as ISO C has no case ranges), a case of the otherwise target left to
`default`, which the switch always has (`-Wswitch` on an enum discriminant). The goto layout
spells each case as `goto bb_N;` (`emit_switch_gotos`); the structured one
(`emit_native_switch`) emits each target's region once, also inside a loop, where an arm's
loop break is a forward `goto` (`sx_sw_brk`: a C `break` would only leave the switch) and
`continue` stays. In a loop, a switch whose arms continue or leave it joins where its other
arms reconverge (`CFlow::compute_follows`). A bounds check `bce` folds keeps its condition
operand on the goto for the IR re-proof; `count_all` does not count it, so the condition's
store is dead.
C11 guarantees string literals of 4095 bytes only (`STR_LIT_MAX`; `-pedantic-errors` rejects a
longer one). A string constant whose bytes (`str_const_bytes`: frame stripped, escapes decoded)
pass it spells as a block-scope `static const uint8_t __sc_lit<constant id>[]` of its bytes and a
terminating 0 (`long_lit`, declared once per body in `lit_decls` and inserted ahead of the body's
statements), read as `sizeof(__sc_lit<id>) - 1` bytes like a literal; a file-scope constant
(`push_c_str_data`) uses a compound literal array, which has static storage there. An assertion
message spells at most `ASSERT_SRC_MAX` (1000) bytes of each expression's source.
A fold chain of inlined temporaries keeps every link past `INLINE_CHAIN_MAX` (64) as a
declared temporary, so long expressions stay under that depth. A body that still passes it
is refused and reported as a located error (`CEmit.refused`, merged from the shards by
`report_refusals`).

A by-value `[]mut T` parameter splits the definition (`split_abi`, `emit_fn_inner`): the body is
`<sym>__r`, which takes the view as `<T> *restrict __sc_sp<l>, size_t __sc_sn<l>` (without `restrict` when the function has a fixed-array value parameter) and rebuilds the
local, and `split_entry` writes ahead of it the prototype of `<sym>__r` and the struct-ABI entry
`<sym>` on the chunk's first line, so `proto_of` yields both prototypes on one line (the driver
pairs prototype line k with chunk k). A direct call (`split_callee`, `split_arg`) spells
`<sym>__r` and `x.ptr, x.len` for each view argument (`split_views`), unless the callee is
extern, variadic, `@blocking` or a vector-backend entry, or a view argument spells a forwarded call
(`fwd_spelled`), which would then run twice; such a call reaches `<sym>`. Vector-backend entries
(`CEmit.no_split`) and `@emit_macro` templates keep the struct ABI.

A fixed-array value parameter is the C parameter `T const __sc_ap<l>[N]` (`param_ctype`, a pointer to
the caller's array; `ap_name`): `arr_param_copies` copies it into the local named as the parameter
before the body. Every spelling of the signature uses `param_ctype` (definition, prototype, function
value, vtable slot, thunk, `split_entry`). A function with such a parameter declares no `restrict`
on its `&mut` parameters or its split views (`has_arr` in `emit_fn_inner`): the copy reads bytes a
`restrict` pointer of the call may write (C11 6.7.3.1). A call casts a nested array argument to
`T const (*)[M]`. In a backtrace the parameter shows as `__sc_ap<l>`.

A body renders straight into the TU buffer: `emit_body_core_cf` takes `self.out` out of
the emitter and threads it as `o: &mut String` through every statement, control-flow
and terminator renderer (the expression renderers already take `dst`), then asserts
`self.out` stayed empty before putting the buffer back. Wrappers such as `(*..)` insert
their opener at a mark (`String::insert_str`) instead of copying the text so far; a
spelling needed twice or after later text rides in the `sget`/`sput` scratch pool, never
in a fresh `String`. Rendering order is part of the contract: demands, sentinels and
static stubs record in spelling order, so a sub-expression must still spell where it
did before, only without the intermediate copy.

`src/emit/probe.spc` is the emission probe: per region (graph, acquire, relower-refl,
relower-zst, inline, drops, sym, decl, render, assemble, publish, sync) wall time, calls
and, with the allocation tracker on, allocation calls and requested bytes, plus
repeated-work tallies (bodies taken/lowered, per reason the re-lowering templates,
instances, re-lowerings, identical re-lowerings and retained bytes, rendered bytes; the
re-lowering census and the instance discovery total are in
[instance-specialization.md](instance-specialization.md)). Every context that
does the work (`CEmit`, `DropCtx`, the driver) carries one; shard probes merge into the
master's (the tallies always, the regions when on), and `SC_CEMIT_STATS` prints the
table. The build record (`SC_BUILD_STATS`) carries the two re-lowering counts. Off, each
operation is one branch.

## Output Tree

`gen_root` defaults to `<root_dir>/build/<profile>/raw`; manifest builds point it into
their target's profile directory (`<out-dir>/<profile>/raw`). Module paths map to nested directories (`::` → `/`):

```
<gen_root>/
  super_rt.h               # C backend header (src/emit/rt_h.spc): libc includes, arithmetic helpers, runtime prototypes
  std/
    rt/base.c              # the runtime module (traps, leak tracker, overflow report), as every module
    rt/libc.c  rt/libm.c   # wasm only: the C library (std/rt/libc.spc, std/rt/libm.spc), with -fno-builtin
  __sc_fwd.h               # runtime and extern-block includes, dyn/extern declarations, shared by every TU
  __sc_t/app__Point.h      # one definition header per type: its typedef, definition and layout check
  app.h  app.c             # per module: .h holds its prototypes and `_ret` typedefs, .c the TU body
  app__p1.c                # module shards (__p<k>, k from 1): the size policy's count, or the build.toml [shards] override
  app__inst.c              # generic instances, glue, constants and dyn tables app owns
                           # (+ app__inst__p<k>.c when the owner's instances need more than one shard)
  __std/string.h  __std/string.c  # prelude: loaded under the reserved __std:: namespace
                           # so output never collides with a user std/ directory
  __sc_registry.c          # ZST sentinels and the reflection registry
  __sc_manifest            # paths, content hashes, header dependencies, owners, shard counts
  __sc_shards              # the shard counts this build used; the next build starts from them
  __ldflags                # one @link flag per line
  __test_main.c            # the test table and the `main` that calls std/rt/test.spc (--test only)
```

Dead modules are pruned transitively (scan-live plus everything a kept TU spells symbols
from), and `prune_orphans` deletes outputs a previous build wrote that this one no
longer emits.
