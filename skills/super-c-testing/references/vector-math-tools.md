# The vector math tools

## The vector math tools

`tools/simd_math` is one project with three binaries (one root: imports cannot cross project
roots): `simd-math-gen` (`gen.spc`), `simd-math-check` (`check.spc`) and `simd-math-bench`
(`bench.spc`), over `real.spc` (double words, `f128`, `f256`), `ref.spc` (the reference functions)
and `remez.spc` (minimax fits). Build each in release and run it from the repository root:

```sh
./super-c release tools/simd_math                          # simd-math-gen
tools/simd_math/build/release/simd-math-gen                # rewrites std/simd/math/coeffs_f32.spc and coeffs_f64.spc
./super-c release tools/simd_math --bin=simd-math-check
tools/simd_math/build/release-bin-simd-math-check/simd-math-check --write   # the full check
./super-c release tools/simd_math --bin=simd-math-bench
tools/simd_math/build/release-bin-simd-math-bench/simd-math-bench [--only=NAME]
```

- The generator is deterministic (its fits run in parallel, each independent, on grids built once
  for both lane types): rerun it after a change to a polynomial spec or a constant, then rerun the
  full check. A fit that misses its target, or a Remez exchange that does not converge, stops it.
- The full check: every f32 input of a one-argument function (2^32, minutes per class in parallel)
  against the f64 C library; `--n` f64 inputs per function (default 10^9: about an hour for all; a
  quarter random bits, a quarter within 2^40 ULP of 0, 1, the domain ends and every `Konsts`
  threshold, the rest uniform per binade, or near multiples of pi/2 for the trigonometric functions)
  against the double-word reference; pairs of two-argument functions shaped per function, and in f32
  every pair of binades; a result within 0.01 ULP of the bound, or a subnormal one, again against
  f128; a zero result must have the reference's sign. The special-value tables: a zero, infinite or
  NaN argument gives the C library's result exactly, any other the class bound against f128. `--write`
  replaces the measured table (each function's largest error and its input) at the top of each class
  module; it needs every function and both lane types. `--only=NAME`, `--part=K/N` (the functions
  whose index is K modulo N), `--f32`, `--f64`, `--n=N` and `--sample32=N` (random f32 inputs instead
  of all) narrow a run; `--jobs=N` (both tools) sets the worker threads. Exit status 1: a result over its
  bound or a wrong special value, printed per function and class.
- The bench prints ns per element for each class and the scalar C library loop at the native lane
  count (wide ranges log-uniform per binade), the ratios, and a `gate:` line per failed class gate
  (precise not slower than the library; balanced 20% faster than precise and fast 20% faster than
  balanced for exp, log, sin and cos, faster for the rest); exit status 1 when one fails.

`tests/simd/simd_math_test.spc` runs in the normal suite: the special values of every function, class
and lane type at compile time against run time (`const_runtime_parity`, Annex F domain edges and
pow's special pairs included; each function through a `@noinline` wrapper, so its kernel is in the
C once), a hash of 10^5 results per function and kind (the planned build
against `SC_SIMD_SCALAR=1`; for every function, two-argument ones, `powi` and `sincos` included, each
lane of a call at the other lane count against the call on that lane's inputs alone; and a fixed
combined hash per class and lane type every target must give, one test each (`ALL_PRECISE_32` ..
`ALL_FAST_64`): after a kernel or coefficient change, set it to the `all` line the failing test
prints). Its builds and the math model's (`tests/gen/math.spc`) run one compile job (`--jobs=1`): a
test of the parallel suite takes one CPU, so its large programs do not starve the tests beside it;
its tests take `@test(timeout = 300)`. `tests/cli/vector_math_tools_test.spc` runs the generator against the committed coefficients
and the reduced check (10^6 inputs per function: `--n=500000 --sample32=500000`, a third of the
functions per test), each tool built with the release profile (their f128 arithmetic needs
inlining across units) in a scratch copy. Their results do not depend on the lowering, so that
file's path names no `simd_`: CI's per-level `--filter=simd_` jobs skip it. In the suite the tools
run with `--jobs=1`: a test that starts a worker per CPU slows every test beside it past its
timeout. These tests take `@test(timeout = 300)`.
