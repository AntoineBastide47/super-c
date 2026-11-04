# Running Tests

## Running Tests

Always run with `--quiet`: the failure replay and the tally carry all the signal, and
agents and CI logs stay readable. Drop it only when a PASSING test's output is needed
(pair with `--test-no-fork`, which is the only mode that shows it).

```sh
super-c test --quiet                   # the standard form: only the failures and the tally
super-c test --quiet --filter=parse    # substring match on test name
super-c test --quiet --test-shard=1/4  # one-based CI sharding, balanced by tests/durations.tsv
super-c test --quiet --test-record-durations  # refresh tests/durations.tsv from this run
super-c test --test-shard=1/2 --test-durations=tests/durations/<lane>.tsv --test-record-durations=s1.tsv  # CI lane: its weights, this shard's times alone
super-c test --quiet --test-jobs=8     # bound the fork pool (default: one per CPU)
super-c test --quiet --test-timeout=120 # fail a test that runs past 120 s (default 90, 0: none)
super-c test --test-no-fork            # in-process (for debuggers; shows passing output)
```

### How the suite is built

`super-c test` first builds the compiler under test with the `test` profile (`opt-level` 1) into
`<out-dir>/test-bin`, or with `--profile=P` into `<out-dir>/P`. It exports it as `$SUPERC` for the
CLI tests; when the project
holds `std/core.spc` and `SC_STD_DIR` is unset, it also sets `SC_STD_DIR` to the project's
`std/`, because `--out-dir` may place that compiler away from the tree it must load. The test
runner itself is a separate engine build of the generated test root under the built-in
`test` profile (`opt-level` 1): the per-TU cache, the native record and the emit stamp, linked to
`build/test/__tests`, its objects under `build/test/raw/`. An unchanged suite skips straight to the
link check. `--filter=S` acts at build time too: the
generated root imports only the test files with a test whose name (`<module>::<fn>`, or
`<module>::<Type>::<fn>` for a suite method) contains S, after a parse-only scan of the
suite, and a filter no test matches is an error. The runner then runs only the matching
tests of those files. Override the runner's flags with a
`[profile.test]` section in `build.toml`. The runner is Super-C (`std/rt/test.spc`, which the loader adds
to test builds); the generated test entry (`__test_main.o`, from LIR text) holds only the test table and
the `main` that passes it to `sc_test_main`. Run directly, the runner takes `--filter=S`,
`--shard=K/N`, `--jobs=N`, `--timeout=S`, `--weights=F`, `--record=F`, `--quiet` and `--no-fork` (not the driver's `--test-*` spellings)
and exits 2 on any other argument. A runner started without an inherited `SC_JOBSERVER` makes its own
of `--jobs` slots, as `super-c test` does, so its tests and the compilers they start share one budget. Every compiler the CLI harnesses
(`tests/cli_harness.spc`, `tests/harness.spc`) run shares one cache base: `super-c test` exports
`SC_TEST_CACHE_DIR` (kept across runs; CI sets `~/.super-c/cache/.tests`, inside the cache it saves),
else `<out-dir>/test/cache`, as `SC_CACHE_DIR`, so a unit an earlier build compiled is not compiled
again; the second it deletes when the run ends (and at its start, what an interrupted run left). The
runner itself builds in the project's own cache root. A fixture project takes a fixed name (`app`,
`initapp`), so a kept base holds one root per name, not one per run. A test that checks cache behavior sets its
own `SC_CACHE_DIR` under its scratch directory, and so does every test that runs `clean --full`,
which removes the project's cache root.

### Fork isolation

Each test runs in a **forked child process**. A panic, failed assertion, or crash fails
only that test. The other tests continue. The parent collects exit status and reports.

`--test-no-fork` disables forking for debugger attachment. `should_panic` tests are
skipped in this mode.

Windows has no `fork`: the parent runs the global `@test_init`/`@test_free` pair once, and
each test runs in its own child process that rebuilds a private global env. CRT
differences that affect the runner and tests: `_dup2` returns 0 on success; `_spawnv`
joins its arguments with spaces and quotes nothing; `abort()` is fail-fast (exit code
0xC0000409) and flushes nothing, so atexit handlers and the leak report do not run;
`freopen` resets to full buffering and `_IOLBF` acts as `_IOFBF`, so a capture child sets
`_IONBF` on both streams. Diagnose a Windows-only failure on the real `windows-latest`
runner: edit the `windows` job in `.github/workflows/debug.yml`, which runs on dispatch only.
In both workflows, each platform builds its compiler once (`compile`, `windows-compile`,
`wasm-compile`: an artifact) and runs its test shards in parallel on it (three on Windows, the
slowest runner, two elsewhere). The build has two stages: the latest release builds stage 1, and
stage 1 builds the tested compiler at the default profile, both natively; `wasm-compile` builds
`super-c.wasm` the same way (the native wasm backend), and `wasm-package` ships a release build of
it, as `package` ships a release build of the native binary. The Linux arm64 compiler (target
`linux_arm64` in the release matrices, `linux-arm64-compile` in the debug workflow) is cross-built
natively on the x86-64 runner by the x86-64 one against the arm64 C library
(`libc6-dev-arm64-cross`: headers and libraries, no compiler); the arm64 runner (`ubuntu-26.04-arm`)
runs its test shards, gate and package, which rebuild the compiler there. No transpile count runs
for it: no earlier release has a Linux arm64 compiler to count against.
In the release workflow (macOS, Linux, Linux arm64 and Windows in one matrix)
the correctness gate (`ci/gate.sh --core`), the x86-64 levels and the `compare` job (Linux, clang 22:
the tests that compile C, the C environment tables, the strict C warnings) run beside the shards, and the release binary is
built after all of them pass. Only the release workflow on main saves caches (the toolchain action's
`save: true`), so no other workflow or branch evicts its entries. Each platform keeps one object
cache, `objcache-<target>-<sha>` (the cache base `~/.super-c/cache`, the tests' `.tests` included):
the compile, test and package jobs upload the files they added or changed and the list of those they
deleted (`.github/actions/cache-save/delta.py`), and the `caches` job merges them over the platform's
newest cache at the end of the run. Gate, counts, compare and the wasm checks save only their
own delta (`objdelta-<target>-<role>-<sha>`), which the toolchain action restores over the platform
cache. The installation caches are restored every run, so GitHub's eviction past its limit takes the
superseded caches of older commits first. The toolchain and bootstrap steps live in `.github/actions/`. An
emit-only probe does not help there: emission without `--test` drops `@test` bodies, so
instrument the test file and rebuild the suite.

### Output capture and the failure report

Each child's stdout and stderr go to a capture file owned by the runner. A passing
test's output is discarded. After the run, a `failures:` section replays each failed
test's output under a `---- name ----` header, followed by how the process ended
(the signal or exit code, or "did not panic as expected"), then lists the failed names
again. A test that aborts (a failed `assert`, a panic, a trap) also reports `last errno: N (message)`
when the aborting thread's `errno` is not zero, on every OS: the runner resets `errno` when the test
starts, so the code is one the test's own calls set, though maybe before the failing line. `--quiet` drops the per-test `ok` and `skipped` lines; the header, the `FAILED`
lines, the failure section, and the tally stay. `--test-no-fork` captures nothing, so
use it to see a passing test's output.

### Sharding for CI

`--test-shard=K/N` splits the test list into N shards and runs shard K. `super-c test` balances
the shards by the suite's recorded durations, `tests/durations.tsv` (one `<seconds>\t<name>` line
per test, sorted by name): the filter-matched tests, the longest first, each go to the shard with
the least time so far, ties to the lowest shard, and a test the file does not name counts as the
median recorded duration. Every shard computes the same assignment from the same file, test list
and filter, so the shards are disjoint and cover the list. Without the file (and for one file,
`super-c test app.spc`) tests are dealt round-robin. One file's `--test-record-durations`
needs `=F` or `--test-durations=F`: a file has no suite folder for a default file. `super-c test --test-record-durations` merges
the run's times into the file: a test that ran gets its new time, one that did not (another shard)
keeps its old one, and a name the suite no longer has is dropped. A filtered run builds only the
files with a match, so it keeps every line it has no test for (a removed test's line stays until an
unfiltered run). Refresh it after adding or removing slow tests (`--filter` for the new ones); a stale
file only makes the split less even.

`--test-durations=F` names the weights file instead (and the file a plain `--test-record-durations`
writes); `--test-record-durations=F` merges the run's times into F instead, so a shard recording into
a fresh F lists only the tests it ran. CI runners are several times slower than a laptop, and not
uniformly, so each CI lane splits by its own file, `tests/durations/<lane>.tsv` (`macos`, `linux`,
`windows`, `wasm`). The files are not committed: they are the repository's one `test-durations`
artifact. One job of each Release, Debug and `Test durations` run copies it into the run's
`durations-plan` artifact (`.github/actions/test-durations-plan`), and every shard downloads that copy
first (`.github/actions/test-durations`; a lane without one uses `tests/durations.tsv`). A rerun shard
thus runs the tests it ran in the first attempt. Every Release run refreshes `test-durations`: each
shard records the times of the tests it ran (`--test-record-durations=<file>`), and the `durations`
job (`.github/actions/test-durations-save`) merges each lane's shards (the tests of a shard that
recorded nothing keep their old times), replaces the artifact, deletes every other durations
artifact, and summarizes the measured and planned shard times. The `Test durations` workflow
(`.github/workflows/test-durations.yml`) runs the same shards and job on demand, without a release.
