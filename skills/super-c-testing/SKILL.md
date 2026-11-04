---
name: super-c-testing
description: "Covers writing and running tests in Super-C: the @test/@test_init/@test_free lifecycle, fixtures, method suites, should_panic, fork isolation, sharding, assert builtins, SC_LEAK_CHECK as a CI gate, and the self-host test corpus. Use when writing tests, debugging test failures, or setting up CI for a Super-C project."
allowed-tools: Bash Read
---

# Super-C Testing

## Agent checklist

- Read the test lifecycle rules before changing fixtures or test attributes.
- Always pass `--quiet` when running tests: only the failures (with their replayed
  output) and the tally matter, and the per-test `ok` lines drown them out.
- Use the narrowest relevant test command and preserve fork isolation.
- Watch a CI run with `sh ci/wait-run.sh <run-id>` in the background until it ends, never with
  `sleep` (`AGENTS.md`, Monitoring CI). It prints only the failed jobs' failure reports.
- Keep leak checking enabled when validating ownership behavior.
- Report stale test documentation after harness or fixture changes.

Super-C has a built-in test framework. Tests are declared with attributes, discovered
automatically, and run in forked child processes for isolation.

`super-c test` imports every `.spc` file under `tests/`, subdirectories included; a file's path is its
module path, so `tests/simd/simd_x86_test.spc` holds the tests `tests::simd::simd_x86_test::*`. The suite
groups its files by area: `frontend/` (lexer to type checker), `borrowck/`, `ir/`, `codegen/`, `simd/`,
`math/`, `stdlib/`, `concurrency/`, `platform/`, `cli/`, `lsp/`, `tooling/` (fmt, lint, doc IR, the C
preprocessor) and `gen/` (the program generators and their test). The shared helpers stay at the top
(`tests/harness.spc`, `tests/cli_harness.spc`); an area's own helper lives in its folder
(`tests/concurrency/parallel_harness.spc`, `tests/platform/platform_harness.spc`). A file keeps its area
prefix (`simd_`, `math_`, `cli_`, `lsp_`, `platform_`) so a `--filter` on it still selects the area.

## Reference files

Read only the file the task needs. Section names are kept, so a pointer such as
"see Header Types" names a heading in one of these files.

- [writing-tests.md](references/writing-tests.md): @test, fixtures, teardown, expected panics, timeouts, global fixtures, method suites, assert builtins.
- [running-tests.md](references/running-tests.md): how the suite is built, fork isolation, output capture, sharding.
- [leak-detection.md](references/leak-detection.md): SC_LEAK_CHECK, its CI use, lint-based leak detection.
- [compiler-corpus.md](references/compiler-corpus.md): the LIR check, native backend tests, case families, differential oracles, vector conformance lane, program generator.
- [vector-math-tools.md](references/vector-math-tools.md): the vector math tools.
- [design-rules.md](references/design-rules.md): rules every new test must follow.
