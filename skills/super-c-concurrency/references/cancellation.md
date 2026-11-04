# Cancellation and Shutdown

## Cancellation Sources and Groups

`std::parallel::task` owns cooperative cancellation. Only a `CancelSource` requests it;
a `CancelToken` observes it; a `TaskGroup` bundles a source with the children it spawns.
Dropping a `TaskGroup` joins its children with cancellation masked, so a group never ends
before its children even when its owner has a cancellation pending. Every `free` whose waits
can accept a cancellation runs masked the same way (the lowering wraps it in
`cancel_mask_enter`/`cancel_mask_exit`), so a destructor always completes.

```superc
let (src, tok) = task::CancelSource::new();
launch || {
    tok.bind_current();                   // this task is now a member of `src`
    time::sleep(long);                    // a cancellable wait unwinds on the request
};
src.cancel(runtime::CR_USER);            // request every member; first reason wins

let mut g = task::TaskGroup::new();
g.spawn(|| { work(); });                  // children bind the group's token themselves
g.cancel();
let report = g.join();                    // completed / cancelled / unresponsive counts
```

Registration contract (`CancelToken::bind_current`, documented at the top of
`std/parallel/task.spc`):

- Membership is per (task, source). Binding one source twice from a task is one
  membership; binding several sources is one membership each.
- The record belongs to the task: the first lives inline in the task block, further ones
  are small heap records. The source links records into a list of its LIVE members and
  keeps nothing of its history.
- A membership ends when the task completes, by return or by cancellation cleanup: the
  runtime unlinks every record before the task's identity can be recycled. The record
  holds a reference to the shared state, so a source and all its tokens may be dropped
  while members live.
- Binding after `cancel` delivers the request at once with the first request's reason.
- `cancel` raises the flag under the source lock, then drains members in registration
  order in bounded batches and requests each by generation-checked key outside the lock,
  so a member that completes meanwhile is rejected, never touched.
- `CancelSource::members()` is the diagnostic live count; it is zero after `cancel`.

Lock order: a source lock is taken alone and never held across a request or a task's
cleanup. A key-based request takes only the registry slot lock.

**Compiled cancellation edges.** After a call whose callee can reach the runtime's
acceptance, a task-reachable body outside `std::parallel::runtime` probes for an accepted
cancellation and, on one, runs its cleanup ladder and returns a poison value its caller
never reads. A call carries the edge when it is evaluated with nothing unregistered
pending: the root of a statement or of a `let` initializer, a lone return value, an `if`
or `while` condition, a switch scrutinee (the task unwinds before any arm runs) and the arm
values of a switch or `if` in such a position, the first call of a receiver chain
(`rx.recv().unwrap_or(0)` unwinds after `recv`), both sides of `&&` and `||`, the right
side of an assignment to a call-free place, and a `for` loop's `next`. Implicit calls follow
the same rule: an operator method at such a node (a compound assignment checks once the place
holds its result) and a user `Deref` hop. A call after an
evaluated argument or a left operand (and every call in `std::parallel` but that root) leaves an
accepted request to the next edge, but when its callee returned through its own ladder (probe 1)
it unwinds at once: that result is poison, and nothing reads it. Its ladder also frees the
pending owned temporaries of the expression (the ones still initialized). An
edge after a call that returned a real value frees it first (a `Some(guard)` unlocks). A
call to a fn value carries the edge when some fn value of the package can accept (a closure
written as a spawn entry is not one); a bound or `dyn` call, when some conformance method of
its name can. In `std::parallel` only the root call of an expression statement or a plain
`let` carries one: its primitives report a cancelled wait through their results and release
raw resources after it (`TcpStream::connect` closes its socket). `runtime::cancel_after_wait`
never carries an edge. That function is how a primitive's wait cleanup accepts the request;
it reports through its result so the primitive finishes removing its registrations and hands
back the value it waited with, and the edge fires after the primitive, at its caller. A probe
placed right after it unwound the primitive mid-cleanup and leaked a channel's unsent payload.
Whether a body is task-reachable comes from the whole-package analysis above; targets differ
here, so a probe that is absent on one target may be present on another. Constant evaluation
runs the same bodies: no task exists at compile time, so the evaluator folds the probe to 0
(no cancellation), as it folds the combined safepoint.

Known gap: in a generic body an unbounded `T` is not an owning type, so a `T` value a
path does not consume is never dropped in an instance with an owning argument (a
never-moved `T` parameter, `Option::unwrap_or`'s unused default). Bound it with `Free`
where a drop is required.

Timed waits live in one indexed binary min-heap under the scheduler lock, ordered by
(deadline, arm sequence): arming and disarming are logarithmic, the earliest deadline is
read in constant time, equal deadlines come due in arm order, and a sweep may reach its
members in any order. Exactly one idle worker times its park to the earliest deadline;
the others sleep untimed, and only a new earliest deadline wakes that worker. Due timers
are made runnable in bounded batches per lock hold, as one chain on the injection queue,
and the promoting worker wakes one idle worker for each promoted task past the first. A deadline that would wrap the clock
saturates (`runtime::deadline_after`, used by `time::deadline_in`).

## Shutdown

```superc
runtime::shutdown();   // drain the pool, join all workers
```

The program is responsible for calling `shutdown()` before exit. The shutdown report
names any tasks that were still running.

See [primitives.md](primitives.md) for the full API reference.
