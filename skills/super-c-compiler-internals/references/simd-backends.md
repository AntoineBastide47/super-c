# Vector Backends and the Lowering Planner

How a vector operation reaches target instructions: the CPU feature set of a build, the backend
table of `@simd_impl` entries, the lowering planner (`simd_plan`), and the C the renderer writes. The language contract
is in super-c-language `references/simd.md` (Target features and backends).

## Feature set

`src/ir/cpu_features.spc` is the source of truth: `CPU_FEATURES` (append-only; row `i` is bit `i`
of a `CpuFeatureSet { w: [u64; 2] }` and the discriminant of `std::cpu::Feature`), `IMPLIED` (each
row's closure, a constant), `apply` (a `+a,-b` list for one instruction set, with the error text),
`close`, `baseline(target, arch)` (a row's `base` names the platforms whose every build has it:
the macOS and iOS aarch64 baselines, and the macOS, iOS and Android x86_64 ones, are wider),
`beyond_baseline`, `level` (an x86-64 psABI level name, `X_LEVELS`; `apply` takes one as a list
item), `push_c_flags(set, target)` (the aarch64 rows make one `-march`/`-mcpu` flag at the lowest
architecture their `level` allows; the x86_64 rows `-march=x86-64-vN` for the highest level the
set holds, else `-march=x86-64` for a set with the baseline (never the C compiler's default), then
each further row's `-m` flag, the baseline's included; `--emit-c` writes them into `__cflags`) and
`push_target_attr(set, build, target)` (a function's C `target` attribute: the x86 flag
names, or `SC_TGT_A64(clang, gcc)` with clang's `+ext` list and GCC's `arch=armv8.N-a+ext`, which
the runtime header chooses). `IMPLIED` is closed by Warshall's algorithm (an implication may name a later
row), with the bit test and the join spelled inline: every compile-time evaluation interprets it.
`Manifest.target` carries the platform. `Package.features` holds the build's closed set (the host
baseline by default); `bsys::features_for` computes it from build.toml and `--target-feature`,
`main.spc` for a bare build and the `lint` command (`loader::set_load_target`, read by
`Package::new`). `Package.simd_width` (256 or 512) is the planner's preferred width on AVX-512.
A function's effective set is `Package::fn_set(m, f)`: the build's and its `@target_feature`'s
(`fn_features`), closed (on wasm32 the build's alone); `Package.fn_union` joins every function's
set, so the entries any function may call render. Both, and every backend entry's key, features and
name, mix into the TU cache header hash (`driver::tuc`), so a changed set or table never replays a cached unit.

## Attributes

`@target_feature`, `@simd_impl`, `@value`, `@reads`, `@writes` take constant-expression
arguments: `ATTR_EXPR_KINDS` and `ATTR_EXPR_ARGS` (`ast.spc`) give each argument's kind (`AA_*`:
`u32`, `usize`, a `cpu::Feature` list, a `simd::Op`, a parameter, a byte count). The parser builds
a tuple node for several arguments and checks the arity; the resolver resolves the parameter-scoped
kinds inside the function scope (`resolve_attr_exprs`); the type checker checks each argument
(`tc_attr_exprs`) and stores the folded value with `set_attr_value` (`AttrVal { v, w }`: a feature
list in `w`, a symbolic byte count flagged in `w[1]`). `FN_FEATURES` and `FN_LANE_ACCESS` flag the
function; the parser checks a feature list of `cpu::Feature` variant paths against the
function's and its extend's `@arch` gates (`check_feature_gate`), before the build filter
removes a gated item; `TypePool.simd_op` and `TypePool.cpu_feature` name the two std enums.

The type checker records each call or value use of a function that needs features
(`Ast.feature_calls`: span, callee, caller, the enclosing `unsafe` marker, `in_unsafe`) and each
caller of a `@lane_access` function (`Ast.lane_callers`); an `unsafe` marker whose only reason is
such a use goes to `Ast.unsafe_lints` instead of the checker's own lint. `check_feature_calls`
(`driver/emit.spc`, package-wide, after the type check) classifies each use (`feature_use`: 0 the
caller's effective set holds the callee's, 1 it needs `unsafe`, 2 an error even there: wasm32, an
extern binding, an `@always_inline` callee), reports the uses not covered, the `@export`
functions with features and the outside-called ones (`main`, tests, benches) the build cannot
call, and sets `fn_union`; `lint_feature_unsafe` reports a deferred marker no use of class 1 or 2
needs (a build's lints and `lint`), with the `(cpu::Feature, f)` tuple rows of feature functions
(`Ast.feature_rows`, a `detect::dispatch` table) whose feature does not imply the function's. `tc_feature_bound_args` rejects a feature function as the
value of a closure bound. The Core IR inliner never splices a callee whose features its caller's
set lacks (`inline.spc`, reason `IJ_NOT_FN`).

Feature clones: `InlineStore::build` copies every kept function body that holds a vector and no
closure (`vec_ix`, `vec_bodies`, `vec_body`). While a body emits under a set that holds a backend
entry the build's closure does not (`CEmit.fs`: a `@target_feature` function's, or a clone's; SME
alone holds none), `CEmit::clone_set` gives a call of such a function that states no features that
set: `callee_sym_i` spells `<symbol>__fs<32 hex
digits of the features beyond the build's>` (`clone_sfx`, also the clone's closure suffix) and
records a `Demand` with `fs` set, journaled in the event's `xs` (four words). The drains emit it
under `demand_set` (its `fs`, else the function's set), the target attribute from that set
(`cemit_fn_attrs`), and `cemit_take_body` lowers it from the store's copy when its own emission
took the kept body. The clone lands in the callee module's instance file. One emitter renders bodies
for several TUs (the serial drain after the seeds), so its local-declaration memo (`decl_memo`) is
keyed by the spelling context too: the first render in a TU records the type's definition edge.

Run-time copies (`--simd-dispatch`): the load computes `Package.simd_levels` (`simd_levels_compute`:
the levels of `simd_dispatch` over the build's features, closed, by size; x86_64 only; `build::dispatch_for` turns an unset level list into `off` at opt-level 0
or 1 and for a script without a profile) and, for a
program with vectors, loads the detector module `sc_cpu` (`ffi/sc_cpu.spc`), whose `@export("sc_cpu_words")`
the prologues call.
`CEmit::dispatch_prologue` opens every function `vec_body` keeps that states no features and emits
under the build's set with `if (__sc_simd_lvl() >= k) return <name>__fs<hex>(<its parameters>);`,
the highest level first (the `__r` split body forwards to the copy's `__r`), and demands each copy
(its function, symbol, substitutions and closure suffix plus the level's suffix, `fs` the level's
set). `simd_level_fn` writes `__sc_simd_lvl()` into the forward header (a relaxed per-TU cache over
`sc_cpu_words` and `SC_SIMD_LEVEL`). A native build renders no C: the prologue only demands the copies
and lists them (`CEmit.disp`), and the LIR of the function opens with the same choice (`Lower::entry`:
each copy's call forwards the function's parameters and returns its result) over the byte `__sc_simd_lv`,
one per program in the registry object (`native_registry`, `simd_level_init`): 0, the build's features,
until the registry's constructor `__sc_simd_init` sets it before `main` from `sc_cpu_words` and
`SC_SIMD_LEVEL`; code that runs before it takes the original. The levels join the emit stamp's `opt` line and the TU cache
header. The interpreter traps on a call of such a function ("`f` has no compile-time
value"). `ir::facts::call_access` reads the memory annotations (`MA_READ`, `MA_WRITE`, `MA_LANES`);
`term_effect` gives an annotated read `EF_NONE` and a write `EF_PTR` through its argument.

## Backend table

`loader::load_prelude` loads `std/simd/backend/<x86_64|aarch64|wasm>.spc` as module
`std::simd::backend::<name>` (`Module.backend`, std for `tc_in_std` whatever the std path's
spelling) when the file exists, the build has a feature and a loaded module names a vector
(`Ast.names_vectors`, set by the lexer's `vector_name`: `Simd` or `Mask` before `<` or `::`,
`simd::`, a lane or mask alias; std's `simd.spc` aside), so a program without vectors, the
compiler among them, loads no backend. The backend module emits no unit (`module_emits`), and emission liveness starts from
no module that only it imports, so what its entries and attributes name stays dead until live
code names it. `tc_simd_shape` checks each entry's signature
against the operation's shape and computes its key: `op | T << 16 | R << 24 | N << 32` (`ir::OP_*`:
the scalar operators, `OP_SIMD + code`, then the lane-mask forms `OP_CMP_LANES` to
`OP_SHR_SCALAR`; `T` the vector operand's lane builtin, `R` the result's lane or scalar builtin or
the index lanes' for a run-time index, `N` the lanes). `build_simd_table` collects the entries of
the build's instruction set into `Package.simd_table` with each entry's feature set closed, sorted
by `simd_plan::entry_cmp` (key, then feature count, the largest first, then declaration),
reports two entries with one key and feature set, and marks an entry `lanes` when it calls a
`@lane_access` binding. `ir::op_variant` names
each operation's `simd::Op` variant.

## Planner

`simd_plan::plan(table, fs, checked, op, t, r, n, width)` is a pure function of the table, the
effective set `fs` of the function that holds the statement (`CEmit.fs`, set per function and
closure) and the preferred width (`max_bits`: 256 bits on AVX-512 unless the width is 512):

- `PF_NATIVE`: an entry for `n` lanes, at most `max_bits` wide, whose features `fs` holds (the
  largest set first).
- `PF_SPLIT`: the widest entry for `n / 2^k` lanes, `chunks` calls in lane order. Only a lane-wise
  operation splits, or a reduction whose combining operation (`combine_op`: the tree float sums
  and products, wrapping integer sums and products, `min`, `max`, `and`, `or`, `xor`) has an
  entry at the chunk width.
- `PF_NATIVE` again: an entry for `n` lanes past the preferred width, when no split exists (a
  512-bit `compress`).
- `PF_SCALAR`: the lane loop.

`Plan.combine` is IR_NONE but for a split reduction. `checked` (a memory checker) skips
`lanes` entries. `SC_SIMD_SCALAR=1` turns `simd_plan` off for a
build (`CEmit.simd_on`), an emission-mode switch (`inline::emit_mode_env`); `SC_SIMD_TRACE`
reports each operation without a native entry.

## Rendering

`CEmit::vec_plan_of` maps a vector statement to a plan and the argument and result forms
(`VPlan`: vector, mask bits, lane-mask temporaries, scalar, pointer). A trapping `+ - *` calls
its `OverflowAdd`/`Sub`/`Mul` entry for the failing lanes' bits and traps on them
(`vec_checks_planned`; else the lane loop computes the failure flags), a shift by a scalar
count checks the count once, then the wrapping twin's entry computes the lanes. A masked
load or store keeps its range checks (`range_bits`: one comparison for an access inside the
slice), then calls `LoadMasked`/`StoreMasked` (`emit_vec_mem_planned`; `load_or` is a plain
`Load` when every lane is inside the slice, else it passes the lanes inside). A gather's or
scatter's index check is `CmpGtLanes` against `len - 1`, folded by `|` and tested by
`AnyLanes` (`index_check_planned`); only a failing test computes the lanes' bits, and the lane loop
then checks nothing again. `gather_unchecked` (`SIMD_GATHER_UNCHECKED`) has no check and takes the
`Gather` entry. A gather whose index vector a slice load defined on its straight path (its block, then
predecessors that alone reach it by a goto, a constant switch or an assertion; at most 32 statements;
nothing between writes memory, a projection, an address-taken local or the load's operands, and no
address-taken local's storage ends) reads its indexes in its lane loop from the slice,
`s.ptr[start + i]` (`gather_loads`, `sx_gload`): Clang 18 keeps a loaded index vector in registers and
widens and extracts each lane. With the slice read, the portable `gather_sum_f32` runs at the Neon
kernel's speed on Neoverse N2 under Clang 18 (0.224 and 0.217 ns per element at 4 KiB, 0.275 and 0.275
at 64 KiB; run 39072972330).
`compress_store` over chunks of at most 8 lanes moves each chunk's active lanes to its front
with `SwizzleOrZero` and a byte-index table emitted at the site, stores whole chunks at the next
free element, and restores the elements after the last written one, read first
(`compress_store_planned`; the slice is borrowed alone). A comparison is `CmpXxLanes` then:

- lane-mask temporaries `__sc_ml<local>_<chunk>` when its one read is a `choose` later in the same
  block or in a block a chain of calls and gotos alone reaches, each step's successor (past empty
  gotos) with one predecessor among the blocks reachable from the entry (`straight`, over the body's
  `CFlow`: an inlined body leaves dead blocks), through one whole copy (`lane_only`, `ml_alias`); the `choose` reads them with
  `ChooseLanes`.
  A `choose` of narrower lanes takes them narrowed by the truncating `Cast` entries, a pair of
  chunks into one per step (`narrow_plan`, `emit_narrow`);
- the lane count when its one read, through whole copies and a cast to `u64`, is `count`'s
  `sc_popcount64` call (`mask_count`), on aarch64 (Neon has no lane-bits instruction) or over
  several chunks (`count_kind`; without a plan the lane loop sums the lanes): the chunks' lane masks summed by the wrapping `+` entry,
  reduced by `ReduceAdd` and negated (`VR_FOLD`), and the call then only converts its argument
  (`counted_call`);
- `AnyLanes` or `AllLanes` when its one read, through whole copies and a cast to `u64`, is a test
  against 0 or the `N` low bits (`mask_red`, the constant folded by `const_u64`): the comparison
  writes a value the test reads the same (1 or 0, the bits or 0);
- else `LanesToMask` per chunk, the bits shifted into place.

A mask local defined once, by such a comparison, by a mask operator over such locals or by a whole
copy of one, whose definition dominates every read, lives in lane-mask temporaries too when at
least one read takes lanes: a `choose` of its chunking, or such an operator or copy (`lf_scan`,
`ml_lf`, a fixpoint bounded at 64 rounds). Its temps declare up front with the locals; an operator
calls the lane type's `And`, `Or`, `Xor` or `Not` entry over its operands' temps (`emit_lf_op`); a
copy reads its root's temps; a local also read otherwise keeps its bits, `LanesToMask` per chunk
after its definition (`lf_bits`). `Mask<N>`'s `&`, `|`, `^` and `!` are the `simd.and` ..
`simd.not` intrinsics, an RV_BINARY or RV_UNARY over masks: over bits, C's operator on the storage
integer, `!` masked to the N lanes.

Where the set has the mask-bit forms (AVX-512), a comparison calls `CmpEq` .. `CmpGe` and a
`choose` calls `Choose` instead of the lane-mask forms. A gather or scatter with a `Gather` or
`Scatter` entry calls it after the index check (the inactive lanes keep the fallback); a
`compress_store` with `Compress` and `StoreMasked` entries compresses into a register and stores
its first `count` lanes (`ventry_whole`: these cannot split, so they take entries past the
preferred width when none within it exists). A function's C definition and each entry's carry the C target attribute
of their features beyond the build's (`cemit_fn_attrs`, `push_target_attr`).

A comparison in lane-mask temporaries (`ml_lanes`), and the copy its `choose` reads, declare no
variable. A split reads and writes 16-byte chunks in place (`v.c[k]`) where the vector names them
(`Mangler::vec_chunked`: wider than the build's widest register, `vec_reg_bytes`); only a raw form
whose pointer may address an address-taken vector (`vec_addr_taken`) copies its vectors first, and
a vector held in one C vector (`vec_def`) is copied out to chunks and back. A half or `concat` whose
vectors name their chunks, or whose half is one chunk, copies whole chunks (`chunk_halves`), never a
lane loop: GCC builds a half that a lane loop copies out of the chunks' union one lane at a time. A split reduction is
one expression over the chunks in place, else over copied chunks; a narrowing passes each pair of
chunks as a compound literal of the wider vector's `c`, or of `__builtin_shufflevector` of their
lanes for a C vector; pointers, masks, scalars, names and literals are spelled at each use, an
operand expression bound once.

Without entries (`simd_on` false: wasm without `simd128`, `SC_SIMD_SCALAR=1`) every
vector statement is a lane loop, and `vec_fusion` merges each slice load or non-trapping
lane-wise operation that only a later lane loop of its block reads, when no statement between
writes memory, an address-taken local or the definition's operands: the reader's loop computes
its lane (`T __sc_v<l> = ..`, `fused_lanes`), and a comparison read by a `choose` becomes the
lane's truth. A load never merges into a loop that stores to its slice; into one that stores to
another slice only on wasm, where no C compiler vectorizes the loop. An accumulator's loop of 8
lanes or more with more than an operator unrolls by eight at most (`__SC_LANES`), so a JIT keeps
the accumulators in memory. A splat or array literal cast to a vector is a compound literal
(`vec_literals`), and a vector result the next statement copies writes the copy's place
(`vec_forward`). A constant index list (`swizzle`, `shuffle`) under the planner is
`__builtin_shufflevector` over GNU vectors of the operands' lanes, which the C compiler lowers to
the target's shuffles; it has no entry.

A `choose` of a stored mask uses `MaskToLanes` then `ChooseLanes`, else the bit-form entry.
A trapping shift by a vector count gathers the bits of the lanes whose count is out of range,
traps on them, then calls the wrapping twin. A dot product (`SR_DOT`, keyed by its accumulator
type) has no combining operation, and `compress` and `expand` (`SR_MASKED`) move lanes across
the vector: like a run-time index each is one native call or the lane loop. A `compress` or
`expand` call casts the mask bits to the entry's mask type.

An entry gives the language result, not an instruction's: a reduction keeps the definition's
order (a float tree adds the upper half onto the lower half; integer wrapping sums and products,
`min`, `max` and the bitwise reductions may take any order); an entry survives the C compiler's
folds, which assume no signaling NaN (`x + -0.0`, `x * 1.0` and `fminnm(x, x)` fold to `x`),
so NaN handling uses an operation they keep (`fmax(x, x)` quiets) or comparisons and selects; and a signed wrapping operation uses the unsigned
intrinsic (GCC spells `vaddq_s8` as C arithmetic, undefined on overflow).
Entry calls spell `__sc_si_<symbol>(..)`. `cemit_simd_entries` renders every entry the
features of `fn_union` allow (a TU-cache replay or a macro expansion may call any of them), splices
the file's helpers into each entry whatever `SC_INLINE` says (a call left is a build error),
renders a constant an entry addresses (a shuffle table) with the core module's definitions
(`emit_owner`) and declares it in each entry header that names it, then renders each one with a
scratch emitter as a `static inline __attribute__((always_inline))` function into a lazily written
definition header `__sc_t/__sc_si_<name>.h`; a unit includes the headers of the entries it calls,
and an entry no unit calls is not written. A split copies each operand into an array of chunks and
spells each pointer, scalar and mask once before any call, and copies the result's chunks back
after the last: a pointer may alias an operand or the result. The C compiler keeps the chunks
in registers.

## New instruction sets

A fixed-width backend for another architecture is added only when all three hold:

1. A user or project asks for the architecture and names a client program or kernel.
2. The compiler targets the architecture (`--arch=`): layout (`ir::layout::target_for`), the C
   toolchain, a test lane that runs binaries, and the loader's `backends` name of its backend file
   (`load_prelude`). Adding the architecture is a separate task that comes first.
3. A CI or local runner runs the conformance suite natively or under an emulator the project
   already uses.

Each decision, accepted or rejected with its reason, is recorded below.

The work for an accepted architecture `A`, in order:

1. Its rows in `CPU_FEATURES` (name, implies, C flag, per-OS baseline) and the matching
   `cpu::Feature` variants in the same order (`tests/simd/target_feature_test.spc` asserts both).
2. A binding module `ffi/<header>.spc` with `@arch(A)`: the register types as `@value` types,
   `@target_feature` on each intrinsic, and `@reads`/`@writes` with the exact byte count on
   every intrinsic that reads or writes memory through a pointer.
3. `std/simd/backend/<A>.spc` with `@simd_impl` entries: lane arithmetic, the lane-form
   comparisons, `ChooseLanes`, contiguous `Load` and `Store` and the integer reductions first, then
   `LanesToMask`, `MaskToLanes`, `AnyLanes` and `AllLanes`. Every other operation keeps the lane
   loop until it has a verified entry; an entry needs no compiler change. Each entry states each
   semantic gap of its instructions (NaN rule, zero sign, shift count range, float to integer
   conversion, saturation) and the sequence that restores the language rule.
4. Detection in `ffi/sc_cpu.spc` for each OS of `A` through the OS capability interface
   (`getauxval` on Linux), every error read as "absent", callable before `main` with no allocation
   and no lock, every feature reachable through `sc_cpu_has`, the 16-byte compare-exchange feature
   among them when it is optional.
5. The `-m`/`-march` spellings and the C target attribute of `A` that `--emit-c` writes
   (`push_c_flags`, `push_target_attr` in `src/ir/cpu_features.spc`).
6. A module `std::simd::<A>` only for operations with no portable meaning and a named client.

The backend is accepted when the full vector conformance suite gives the lane loop's results; every
entry of the file passes `tests/simd/simd_entry_test.spc`; `expect_asm` finds the hardware instructions
of lane arithmetic, a comparison, `choose`, a load, a store and an integer reduction; every memory
intrinsic of the binding module has a memory annotation; a baseline build runs on the minimum CPU of
`A`; the portable arithmetic kernels of `bench/simd_baseline` are within 10% of hand-written
intrinsic kernels for `A`; and the fixpoint and `check.sh` pass on the host.

Decisions: no architecture beyond x86_64, aarch64 and wasm32 has been requested. RISC-V with a
fixed `VLEN` (`zvl128b`, `zvl256b`, RVV intrinsics), POWER VSX (`<altivec.h>`), LoongArch LSX/LASX
and s390x z/Vector are not compiler targets, so each needs the architecture first. SVE and SVE2 are
detected only: a scalable register has a run-time length, which no `Simd<T, N>` (a compile-time
size) describes, so no fixed-width backend uses them. SME (`sme`, `sme2`, `sme-f64f64`) has no
backend entries either: its outer products are matrix operations, which module-level assembly kernels of std run
(`ffi/sc_sme.spc` for `std::simd::matrix`, super-c-language `references/simd.md`), each entering
streaming mode itself.

## Tests

- `tests/simd/target_feature_test.spc`: the enums against the compiler tables (compile-time asserts),
  feature lists, manifest and command line, the attributes' diagnostics, the feature fingerprint
  and the rejected-probe error.
- `tests/simd/simd_plan_test.spc`: `simd_plan::plan` over a fixed synthetic table.
- `tests/simd/simd_wasm_test.spc`: byte-identical C without vectors, instruction checks, the wasm32
  module against a scalar model.
- `tests/simd/simd_entry_test.spc` (`tests/gen/simd_entry.spc`): every entry against the lane loop,
  in the wasm lane and on an aarch64 or x86_64 host, each entry the run's features
  (`SC_SIMD_FEATURES`) reach and no run with fewer features reaches (the baseline run, and at 512
  bits the 256-bit run); an entry another of its key and other features shadows in this
  build is called in a build of the other set.
- `tests/simd/simd_x86_test.spc`: per-function planning, the memory annotations of
  `ffi/immintrin.spc`, and on an x86_64 host byte-identical C without vectors, instruction checks
  per level (no `ymm`/`zmm` in a baseline function) and `std::simd::x86` against scalar models.
- `tests/simd/multiversion_test.spc`: the `@target_feature` use rules and lint, closure bounds,
  `@export`, the target attributes and the inliner, function-address casts, `detect::dispatch`
  (order, fallback by `SC_CPU_OFF`, one detection, the race and LTO builds) and the x86 detection
  decision on fixed registers.
- `tests/simd/simd_aarch64_test.spc`: byte-identical C without vectors across the optional features,
  instruction checks, the halves order of a float tree sum, `std::simd::aarch64` against scalar
  models, the memory annotations of `ffi/arm_neon.spc`, and `std::cpu::detect`.
