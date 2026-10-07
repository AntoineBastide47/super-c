# Vector Backends and the Lowering Planner

How a vector operation reaches target instructions: the CPU feature set of a build, the backend
table of `@simd_impl` entries, the lowering planner (`simd_plan`), and the C the renderer writes. The language contract
is in super-c-language `references/simd.md` (Target features and backends).

## Feature set

`src/ir/cpu_features.spc` is the source of truth: `CPU_FEATURES` (append-only; row `i` is bit `i`
of a `CpuFeatureSet { w: [u64; 2] }` and the discriminant of `std::cpu::Feature`), `IMPLIED` (each
row's closure, a constant), `apply` (a `+a,-b` list for one instruction set, with the error text),
`close`, `baseline`, `push_c_flags`. `Package.features` holds the build's closed set (the host
baseline by default); `bsys::features_for` computes it from build.toml and `--target-feature`,
`main.spc` for a bare build. `Package.mem_check` is true under `-fsanitize=` with `address`,
`memory` or `thread` (`bsys::mem_checker`; the transpile form sets the engine's toolchain, so
both routes agree). Both, and every backend entry's key, features and name, mix into the TU
cache header hash (`driver::tuc`), so a changed set or table never replays a cached unit.

## Attributes

`@target_feature`, `@simd_impl`, `@c.value`, `@c.reads`, `@c.writes` take constant-expression
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
(`Ast.feature_calls`) and each caller of a `@c.lane_access` function (`Ast.lane_callers`);
`check_feature_calls` (`driver/emit.spc`, package-wide) reports a use whose build and caller both
lack the features. The interpreter traps on a call of such a function ("`f` has no compile-time
value"). `ir::facts::call_access` reads the memory annotations (`MA_READ`, `MA_WRITE`, `MA_LANES`);
`term_effect` gives an annotated read `EF_NONE` and a write `EF_PTR` through its argument.

## Backend table

`loader::load_prelude` loads `std/simd/backend/<x86|aarch64|wasm>.spc` as module
`std::simd::backend::<name>` (`Module.backend`) when the file exists and the build has a
feature. The backend module emits no unit (`module_emits`), and emission liveness starts from
no module that only it imports, so what its entries and attributes name stays dead until live
code names it. `tc_simd_shape` checks each entry's signature
against the operation's shape and computes its key: `op | T << 16 | R << 24 | N << 32` (`ir::OP_*`:
the scalar operators, `OP_SIMD + code`, then the lane-mask forms `OP_CMP_LANES` to
`OP_SHR_SCALAR`; `T` the vector operand's lane builtin, `R` the result's lane or scalar builtin or
the index lanes' for a run-time index, `N` the lanes). `build_simd_table` collects the entries of
the build's instruction set into `Package.simd_table`, sorted by `simd_plan::entry_cmp` (key, then
feature count, the largest first, then declaration), reports two entries with one key and feature
count, and marks an entry `lanes` when it calls a `@c.lane_access` binding. `ir::op_variant` names
each operation's `simd::Op` variant.

## Planner

`simd_plan::plan(table, features, checked, op, t, r, n)` is a pure function:

- `PF_NATIVE`: an entry for `n` lanes whose features the build holds (the most specific first).
- `PF_SPLIT`: the widest entry for `n / 2^k` lanes, `chunks` calls in lane order. Only a lane-wise
  operation splits, or a reduction whose combining operation (`combine_op`: the tree float sums
  and products, wrapping integer sums and products, `min`, `max`, `and`, `or`, `xor`) has an
  entry at the chunk width.
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
load or store keeps its range checks, then calls `LoadMasked`/`StoreMasked`
(`emit_vec_mem_planned`; `load_or` passes the lanes inside the slice). A comparison is
`CmpXxLanes` then:

- lane-mask temporaries `__sc_ml<local>_<chunk>` when its one read is a `choose` in the same block
  (`lane_only`, through one whole copy: `ml_alias`); the `choose` reads them with `ChooseLanes`;
- `AnyLanes` or `AllLanes` when its one read, through whole copies and a cast to `u64`, is a test
  against 0 or the `N` low bits (`mask_red`, the constant folded by `const_u64`): the comparison
  writes a value the test reads the same (1 or 0, the bits or 0);
- else `LanesToMask` per chunk, the bits shifted into place.

A comparison in lane-mask temporaries (`ml_lanes`), and the copy its `choose` reads, declare no
variable. A constant index list (`swizzle`, `shuffle`) under the planner is
`__builtin_shufflevector` over GNU vectors of the operands' lanes, which the C compiler lowers to
the target's shuffles; it has no entry.

A `choose` of a stored mask uses `MaskToLanes` then `ChooseLanes`, else the bit-form entry.
Entry calls spell `__sc_si_<symbol>(..)`. `cemit_simd_entries` splices the file's helpers into each entry
whatever `SC_INLINE` says (a call left is a build error), then renders every usable entry with a
scratch emitter as a `static inline __attribute__((always_inline))` function into a lazily written
definition header `__sc_t/__sc_si_<name>.h`; a unit includes the headers of the entries it calls,
and an entry no unit calls is not written. A split copies each operand into an array of chunks and
spells each pointer, scalar and mask once before any call, and copies the result's chunks back
after the last: a pointer may alias an operand or the result. The C compiler keeps the chunks
in registers.

## Tests

- `tests/target_feature_test.spc`: the enums against the compiler tables (compile-time asserts),
  feature lists, manifest and command line, the attributes' diagnostics, the feature fingerprint
  and the rejected-probe error.
- `tests/simd_plan_test.spc`: `simd_plan::plan` over a fixed synthetic table.
- `tests/simd_wasm_test.spc`: byte-identical C without vectors, instruction checks, the wasm32
  module against a scalar model.
- `tests/simd_entry_test.spc` (`tests/gen/simd_entry.spc`): every entry against the lane loop.
