# Generated Output

## Generated Output

`super-c build app.spc` writes its tree into `build/<profile>/raw/` (`build/debug/raw/` without
`--profile`): `PROFILE` makes the emission depend on the profile, so every profile has its own tree,
per-TU cache, manifest and orphan pruning, and switching profiles never mixes trees. A linking build
writes the native objects there and no C; `--emit-c` writes the program's C instead.

```
build/
  debug/raw/
    app.o app__inst.o # a linking build: the module's object and its instances' object
    __sc_registry_n.o # a linking build: ZST sentinels and the reflection registry
    __sc_native       # a linking build: per module, the key its objects were compiled under
    __sc_hfacts       # the record of the header scan (`native_header_facts`)
    __sc_manifest     # the build's configuration; with --emit-c also output paths, content hashes,
                      # header dependencies, shard counts
    __ldflags         # linker flags collected from @link (one per line)
    .tu_cache         # per-TU journal/replay cache
    super_rt.h        # --emit-c: the runtime header the C units include: libc includes, arithmetic helpers
    __sc_fwd.h        # --emit-c: runtime and extern-block includes, dyn/extern declarations shared by every TU
    __sc_registry.c   # --emit-c: runtime helper definitions, ZST sentinels and the reflection registry
    __sc_shards       # --emit-c: the shard counts this build used (read back by the next build)
    app.h             # --emit-c: one header per module (prototypes)
    app.c app__inst.c # --emit-c: the module's C and its generic instances, glue and constants
    __units __cflags  # --emit-c: the units to compile and the flags of every compile
    __sc_t/           # --emit-c: one definition header per type (app__Point.h: typedef, definition, layout check)
    __std/            # demanded prelude modules only
```

`--emit-c` writes the readable C tree in its place: `super_rt.h` (libc includes, arithmetic helpers,
runtime prototypes), `__sc_fwd.h` (the runtime and extern-block includes shared by every unit), one
`.h`/`.c` per module, one definition header per type in `__sc_t/`, `<module>__inst.c`, and
`__units`, `__cflags`, `__ldflags`.

A manifest build (`super-c build` with `build.toml`) works in one directory per target and
profile: `<out-dir>/<profile>` for the main binary, `<out-dir>/<profile>-bin-NAME` and
`<out-dir>/<profile>-lib` for the other targets. The emitter writes `raw/` there (the per-TU cache
and `__sc_manifest` with it), and the link reads that one tree: the emitter compares each file with
what it holds and writes only the files whose content changed, so an unchanged file keeps its mtime
(`publish_file`). A build whose emission fails writes no unit or header, so the tree stays as the
last successful emission left it. The emit stamp `.emit_stamp` lands beside `raw/`. The link record
`<out-dir>/__link-<hash of the binary's path>.cmd` holds the own linker's command line (` +archive` for
a static library, ` +strip` for a stripped link): another command, a missing binary or a newer object
links again. `super-c test` runs the same engine on the generated test root under the `test` profile
in `<out-dir>/test/` (`raw/`, the runner `__tests`), with the emit stamp, the per-TU cache and the
native record making an unchanged suite a link check; `super-c bench` uses `<out-dir>/bench/<profile>/`.
Engine code takes every manifest output path from out-dir (the `out-dir` key or `--out-dir`, default
`build`) and never spells `build/`. The tree of a file build (`super-c build <root.spc>`) under
`<root dir>/build/<profile>/raw` is the one exception.

One process builds a profile directory at a time: a build holds the lock file `.lock` in it
(`bsys::tree_lock`: a POSIX record lock, `LockFileEx` on Windows, none under WASI) from the emit to
the link, and a file build holds its `build/<profile>` the same way. A second build of
the directory prints "build: waiting for another build of '<dir>'" and waits at most 30 minutes. Without
the lock it would rewrite the files the first one reads, which could compile or link a torn file. The
OS releases the lock when the
process ends, also by a crash; a transpiler child (`--emit-sub`) runs under its engine's lock.

Parallel analysis (the resolve frontier, the type check, borrow check and always-panics
item jobs, the emission frontier) is used only when the package holds at least 256 KiB of
non-prelude source (`Package::analysis_jobs`,
`loader::PAR_MIN_USER_BYTES`); below that the worker pool costs about as much CPU as the
serial compile and gains a few milliseconds at most, so small compiles run serially and
hand their jobserver slots back. The native compile of the modules is parallel either way.

The C tree of `--emit-c` builds with any C compiler and no `-I` flag: compile each unit `__units`
lists with the flags of `__cflags`, then link the objects with the flags of `__ldflags`, one per line
(`ci/cc_tree.sh` does it: `sh ci/cc_tree.sh build/debug/raw app`). `__sc_unity.c` and
`__sc_pack<k>.c` include other units, and `__units` names them in place of their members. `__cflags`
holds the dialect and the feature macros of `push_c_env` (without them Darwin's
`struct stat` lacks the fields std binds), `-funsigned-char` (the language's `char` is unsigned, and
`super_rt.h` fails to compile without it), `-ffp-contract=off` (only an explicit `fma` fuses, so float
results equal the constant evaluator's), `-Werror=incompatible-pointer-types`, `-fno-builtin-<f>` for
the transcendental libm functions (`LIBM_AS_WRITTEN` in `src/driver/emit.spc`), the target and CPU
feature flags, the profile's `-O` level and `-g`, and `-DSC_ARITH_WRAP` when the profile wraps
integer overflow.
