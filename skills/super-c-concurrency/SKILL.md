---
name: super-c-concurrency
description: "Covers concurrent programming in Super-C: the launch keyword, stackful coroutines, work-stealing scheduler, Arc/Mutex/RwLock/Channel, Send/Sync enforcement, data parallelism, async I/O, select, and task diagnostics. Use when writing concurrent Super-C programs, debugging races, or understanding the runtime model."
allowed-tools: Bash Read
---

# Super-C Concurrency

## Agent checklist

- Identify task, thread, and blocking-pool boundaries.
- Check `Send` and `Sync` requirements at every cross-thread boundary.
- Use task-aware primitives for coroutine code.
- Define shutdown ownership for every runtime pool started by the program.

Super-C provides structured concurrency through stackful coroutines on an M:N scheduler,
with compile-time safety enforced by `Send`/`Sync` marker interfaces.

## launch

```superc
launch || {
    println("hello from a coroutine");
};
```

`launch` spawns a stackful coroutine on a lazily-started work-stealing pool (one pthread
per CPU by default, or `runtime::set_worker_count(n)`). Both closure spellings work:
`launch || { .. };` and `launch fn() { .. };`. Call `runtime::shutdown()` before main
returns (`import std::parallel::runtime as runtime;`).

**Bound:** `fn move() + Send + 'static`. `Send` prevents un-sendable values from crossing
thread boundaries. `'static` prevents borrowing the launcher's stack frame. `fn move`
ensures the closure owns its captures.

`launch` is a **sugar keyword**: the parser emits a `NODE_LAUNCH` marker, and a desugar
pass lowers it to `runtime::submit(...)` before typecheck. No later pass ever sees the
marker. The runtime module is loaded conditionally: programs without `launch` pay nothing.

## Reference files

Read only the file the task needs. Section names are kept, so a pointer such as
"see Header Types" names a heading in one of these files.

- [coroutines.md](references/coroutines.md): stackful coroutines, the scheduler, Send and Sync.
- [sync-and-channels.md](references/sync-and-channels.md): Mutex, RwLock, atomics, channels, select.
- [data-parallelism.md](references/data-parallelism.md): parallel range, each, reduce, inline for.
- [io-and-blocking.md](references/io-and-blocking.md): async I/O and blocking calls.
- [diagnostics.md](references/diagnostics.md): task diagnostics, hunting races and hangs, measuring the runtime.
- [cancellation.md](references/cancellation.md): cancellation sources and groups, shutdown.
