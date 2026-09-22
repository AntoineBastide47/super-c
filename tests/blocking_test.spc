// The blocking pool (std/parallel/blocking): a call's record lives in its frame and costs no allocation,
// a result is owned by exactly one side, a failed thread creation strands nothing, idle threads exit and
// are reaped, a nested call runs on the pool thread it is already on, a full queue parks callers for
// admission, thread creation never exceeds the limit, and a bounded shutdown reports what an unreturned
// foreign call keeps alive rather than freeing it. Every test releases both pools; the suite's leak gate
// proves the records and handles came back.

import atomic;
import sc_runtime;
import std::parallel::runtime as rt;
import tests::parallel_harness as ph;
import std::parallel::sync as sync;
import std::parallel::blocking as blocking;
import std::parallel::channel as chan;
import std::parallel::arc as arc;
import std::parallel::atomics as atomics;
import std::parallel::platform as platform;
import std::parallel::time as time;
import std::testing::bench_sys as sys;

@platform(macos | linux)
extern "C" "unistd.h" {
    @blocking
    fn usleep(us: u32) i32;
}

// Exact-destruction counter: every `free` of a Payload bumps it, so a test can prove one destruction.
static mut G_FREES: i64 = 0;

struct Payload {
    pub n: i64,
}

extend Payload as Free {
    pub fn free(self: &mut Payload) {
        let _ = atomic::add_i64(&mut unsafe G_FREES, 1, 0);
    }
}

fn frees() i64 {
    return atomic::load_i64(&mut unsafe G_FREES, 1);
}

// Code after a cancelled call must never run: the task unwinds through its cancellation ladder instead.
static mut G_AFTER: i64 = 0;

fn after_mark() {
    let _ = atomic::add_i64(&mut unsafe G_AFTER, 1, 0);
}

fn afters() i64 {
    return atomic::load_i64(&mut unsafe G_AFTER, 1);
}

fn counter() arc::Arc<atomics::Atomic<i64>> {
    return arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
}

fn count(c: &arc::Arc<atomics::Atomic<i64>>) i64 {
    return c.get().load(atomics::MemoryOrder::Acquire);
}

// A blocking body: hold a pool thread for `ms` and return `v`.
fn hold(ms: u64, v: i64) i64 {
    time::sleep(time::Duration::from_millis(ms));
    return v;
}

// A blocking body: hold a pool thread until `gate` opens and return `v`. A hold measured in time loses to
// a loaded runner; one that ends on a signal ends exactly when the test says.
fn hold_open(gate: &arc::Arc<atomics::Atomic<i64>>, v: i64) i64 {
    while count(gate) == 0 {
        time::sleep(time::Duration::from_millis(1));
    }
    return v;
}

// Wait, bounded, until the pool reports no call queued or running. A caller is woken before the thread
// that ran its call has counted itself out, so the count may lag a returned call by a few instructions.
fn wait_quiet() bool {
    let deadline = platform::now_ns() + 5000000000;
    loop {
        let s = blocking::stats();
        if s.queued == 0 && s.running == 0 {
            return true;
        }
        if platform::now_ns() > deadline {
            return false;
        }
        time::sleep(time::Duration::from_millis(1));
    }
}

// Wait, bounded, until `frees()` reaches `want`: a deferred signal fires before the task's locals drop.
fn wait_frees(want: i64) bool {
    let deadline = platform::now_ns() + 5000000000;
    while frees() < want {
        if platform::now_ns() > deadline {
            return false;
        }
        time::sleep(time::Duration::from_millis(1));
    }
    return true;
}

// Wait, bounded, until the pool reports no live and no starting thread.
fn wait_threads_gone() bool {
    let deadline = platform::now_ns() + 5000000000;
    loop {
        let s = blocking::stats();
        if s.live == 0 && s.starting == 0 {
            return true;
        }
        if platform::now_ns() > deadline {
            return false;
        }
        time::sleep(time::Duration::from_millis(5));
    }
}

// Launch `n` calls that each hold a pool thread for `ms`, and wait until every thread is busy with one,
// so that what is launched next queues behind them whatever order the workers run tasks in.
fn hold_threads(
    wg: &sync::WaitGroup,
    ok: &arc::Arc<atomics::Atomic<i64>>,
    n: i64,
    gate: &arc::Arc<atomics::Atomic<i64>>,
) {
    wg.add(n);
    for i in 0..n {
        let w = wg.clone();
        let o = ok.clone();
        let g = gate.clone();
        launch || {
            defer w.done();
            let want = i;
            let gi = g.clone(); // the call's closure owns its own handle: it outlives this frame
            if blocking::call(
                fn() i64 {
                    return hold_open(&gi, want);
                },
            ) == want {
                let _ = o.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            }
        };
    }
    let deadline = platform::now_ns() + 5000000000;
    while blocking::stats().running < n as usize && platform::now_ns() < deadline {
        time::sleep(time::Duration::from_millis(1));
    }
    assert_eq(blocking::stats().running, n as usize);
}

fn finish() {
    let r = blocking::try_shutdown(5000000000);
    assert(r.released, "the pool is released once every call has returned");
    rt::shutdown();
}

// --- values and ownership ---------------------------------------------------------------------------.

// Many tasks each make several calls; every value comes back to its caller, and the thread count never
// passed the limit.
@test
fn calls_return_their_values() {
    rt::set_worker_count(4);
    let tasks: i64 = 200;
    let each: i64 = 20;
    let sum = counter();
    let wg = sync::WaitGroup::new();
    wg.add(tasks);
    for t in 0..tasks {
        let w = wg.clone();
        let s = sum.clone();
        launch || {
            defer w.done();
            let mut got: i64 = 0;
            for i in 0..each {
                let id = t * each + i;
                got = got + blocking::call(
                    fn() i64 {
                        return id;
                    },
                );
            }
            let _ = s.get().fetch_add(got, atomics::MemoryOrder::Relaxed);
        };
    }
    assert(wg.wait_timeout(time::Duration::from_secs(30)), "every call returns");
    let n = tasks * each;
    assert_eq(count(&sum), n * (n - 1) / 2);
    assert(wait_quiet(), "the pool counts every call out");
    let st = blocking::stats();
    assert(st.peak_threads <= blocking::MAX_THREADS, "thread creation stays within the limit");
    finish();
}

// A steady stream of calls from one task allocates nothing per call: the record is the caller's frame.
@test
fn a_call_allocates_nothing() {
    rt::set_worker_count(2);
    if unsafe sys::sc_bs_alloc_supported() == 0 {
        return;
    }
    let calls: i64 = 200;
    let got = counter();
    let allocs = counter();
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let g = got.clone();
    let a = allocs.clone();
    launch || {
        defer w.done();
        // Warm the pool: its thread and the first wake are paid once.
        let _ = blocking::call(
            fn() i64 {
                return 0i64;
            },
        );
        unsafe sys::sc_bs_alloc_enable(1);
        let before = unsafe sys::sc_bs_alloc_calls();
        let mut n: i64 = 0;
        for _i in 0..calls {
            n = n + blocking::call(
                fn() i64 {
                    return 1i64;
                },
            );
        }
        let after = unsafe sys::sc_bs_alloc_calls();
        unsafe sys::sc_bs_alloc_enable(0);
        g.get().store(n, atomics::MemoryOrder::Release);
        a.get().store(after - before, atomics::MemoryOrder::Release);
    };
    assert(wg.wait_timeout(time::Duration::from_secs(30)), "the calls return");
    assert_eq(count(&got), calls);
    assert(count(&allocs) < calls / 10, "far fewer allocations than calls");
    finish();
}

// An owned result crosses back and is destroyed exactly once, by the caller.
@test
fn an_owned_result_is_destroyed_once() {
    rt::set_worker_count(2);
    atomic::store_i64(&mut unsafe G_FREES, 0, 0);
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        defer w.done();
        let v = blocking::call(
            fn() Payload {
                return Payload { n: 5 };
            },
        );
        assert_eq(v.n, 5i64);
    };
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "the call returns");
    assert(wait_frees(1), "the caller destroys the result");
    assert_eq(frees(), 1i64);
    finish();
}

// A body that returns at once, round after round: the completion can never resume a caller that is
// still switching out, because the job is published only from the park hand-off.
@test
fn completion_before_the_wait_is_ordered() {
    rt::set_worker_count(4);
    let rounds: i64 = 2000;
    let got = counter();
    let wg = sync::WaitGroup::new();
    wg.add(4);
    for _k in 0..4 {
        let w = wg.clone();
        let g = got.clone();
        launch || {
            defer w.done();
            let mut n: i64 = 0;
            for i in 0..rounds {
                let want = i;
                n = n + blocking::call(
                    fn() i64 {
                        return want;
                    },
                ) - i;
            }
            let _ = g.get().fetch_add(n, atomics::MemoryOrder::Relaxed);
        };
    }
    assert(wg.wait_timeout(time::Duration::from_secs(30)), "the calls return");
    assert_eq(count(&got), 0i64);
    finish();
}

// A plain thread (the test's own) blocks for the value; a pool thread calling again runs the body in place.
@test
fn a_plain_thread_blocks_and_a_pool_thread_runs_in_place() {
    rt::set_worker_count(2);
    let v = blocking::call(
        fn() i64 {
            return 3i64;
        },
    );
    assert_eq(v, 3i64);
    let nested = blocking::call(
        fn() i64 {
            let before = blocking::stats();
            let inner = blocking::call(
                fn() i64 {
                    return 4i64;
                },
            );
            let after = blocking::stats();
            // The inner call took no thread and queued nothing: it ran on this pool thread.
            if after.created != before.created || after.peak_queued != before.peak_queued {
                return -1i64;
            }
            return inner;
        },
    );
    assert_eq(nested, 4i64);
    finish();
}

// --- threads ----------------------------------------------------------------------------------------.

// A thread creation that fails while another thread lives is reported and strands nothing: the job
// waits for the live thread, and the reservation is released.
@test
fn a_failed_creation_with_a_live_thread_strands_nothing() {
    rt::set_worker_count(2);
    // The scheduler's own threads come first: the hook must hit the pool's next creation, not a worker.
    let wg0 = sync::WaitGroup::new();
    wg0.add(1);
    let w0 = wg0.clone();
    launch || {
        w0.done();
    };
    wg0.wait();
    let _ = blocking::call(
        fn() i64 {
            return 0i64;
        },
    );
    // The thread counts itself out after its caller is woken: both launches must find it spinning or
    // parked, so the first pops or is covered by it and only the second reserves a creation.
    assert(wait_quiet(), "the first call has settled");
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_THREAD_CREATE, 1);
    let got = counter();
    let wg = sync::WaitGroup::new();
    wg.add(2);
    for k in 0..2 {
        let w = wg.clone();
        let g = got.clone();
        launch || {
            defer w.done();
            let v = k + 1;
            let _ = g.get().fetch_add(
                blocking::call(
                    fn() i64 {
                        return hold(50, v);
                    },
                ),
                atomics::MemoryOrder::Relaxed,
            );
        };
    }
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "both calls return through the one thread");
    assert_eq(count(&got), 3i64);
    let st = blocking::stats();
    assert_eq(st.created, 1usize);
    assert_eq(st.starting, 0usize);
    assert_eq(st.live, 1usize);
    finish();
}

// An idle thread exits after the timeout and its handle is reaped by the next creation.
@test
fn an_idle_thread_exits_and_is_reaped() {
    rt::set_worker_count(2);
    blocking::set_idle_ns(20000000);
    let _ = blocking::call(
        fn() i64 {
            return 0i64;
        },
    );
    assert(wait_threads_gone(), "the idle thread exits");
    let _ = blocking::call(
        fn() i64 {
            return 0i64;
        },
    );
    let st = blocking::stats();
    assert_eq(st.created, 2usize);
    assert_eq(st.reaped, 1usize);
    assert_eq(st.live, 1usize);
    finish();
}

// Bursts separated by idle periods: the live thread count returns to zero each time and every exited
// thread is reaped, so handles and records plateau instead of accumulating.
@test
fn burst_and_idle_cycles_plateau() {
    rt::set_worker_count(4);
    blocking::set_idle_ns(20000000);
    let burst: i64 = 100;
    for _cycle in 0..4 {
        let wg = sync::WaitGroup::new();
        wg.add(burst);
        let ok = counter();
        for i in 0..burst {
            let w = wg.clone();
            let o = ok.clone();
            launch || {
                defer w.done();
                let want = i;
                let got = if i % 2 == 0 {
                    blocking::call(
                        fn() i64 {
                            return hold(2, want);
                        },
                    );
                } else {
                    blocking::call_c(
                        fn() i64 {
                            return hold(2, want);
                        },
                    ).unwrap_or(-1);
                };
                if got == want {
                    let _ = o.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
                }
            };
        }
        assert(wg.wait_timeout(time::Duration::from_secs(20)), "the burst returns");
        assert_eq(count(&ok), burst);
        assert(wait_threads_gone(), "the threads go idle and exit");
        let st = blocking::stats();
        assert(st.cache_bytes <= blocking::CACHE_BUDGET, "recycled records stay within the budget");
    }
    let _ = blocking::call(
        fn() i64 {
            return 0i64;
        },
    );
    let st = blocking::stats();
    assert(st.created >= 4, "each burst started threads");
    assert_eq(st.reaped + st.live, st.created);
    finish();
}

// Thread creation driven hard near the limit, with the thread's own start delayed past its publication
// and one creation made to fail: live plus starting never exceeds the limit, counts settle, and every
// call returns.
@test
fn creation_near_the_limit_stays_bounded() {
    rt::set_worker_count(4);
    blocking::set_publish_delay_ns(200000);
    let calls: i64 = 300;
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_THREAD_CREATE, 7);
    let ok = counter();
    let wg = sync::WaitGroup::new();
    wg.add(calls);
    for i in 0..calls {
        let w = wg.clone();
        let o = ok.clone();
        launch || {
            defer w.done();
            let want = i;
            let got = blocking::call(
                fn() i64 {
                    return hold(3, want);
                },
            );
            if got == want {
                let _ = o.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            }
        };
    }
    assert(wg.wait_timeout(time::Duration::from_secs(30)), "every call returns");
    assert_eq(count(&ok), calls);
    assert(wait_quiet(), "the pool counts every call out");
    let st = blocking::stats();
    assert(st.peak_threads <= blocking::MAX_THREADS, "live plus starting never passed the limit");
    assert_eq(st.starting, 0usize);
    blocking::set_publish_delay_ns(0);
    finish();
}

// --- admission --------------------------------------------------------------------------------------.

// Every thread held and the queue full: further callers park for admission (or block, from a plain
// thread), the queue never passes its bound, and every call returns its value.
@test
fn a_full_queue_parks_callers_for_admission() {
    rt::set_worker_count(4);
    let holders = blocking::MAX_THREADS as i64;
    let extra = blocking::MAX_PENDING as i64 + 40;
    let ok = counter();
    let wg = sync::WaitGroup::new();
    let gate = counter();
    hold_threads(&wg, &ok, holders, &gate);
    wg.add(extra);
    for i in 0..extra {
        let w = wg.clone();
        let o = ok.clone();
        launch || {
            defer w.done();
            let want = i;
            let got = blocking::call(
                fn() i64 {
                    return want;
                },
            );
            if got == want {
                let _ = o.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            }
        };
    }
    // The threads stay held until a caller has actually waited for admission, so the wait is a fact
    // rather than a race against the hold.
    let deadline = platform::now_ns() + 5000000000;
    while blocking::stats().admit_waits == 0 && platform::now_ns() < deadline {
        time::sleep(time::Duration::from_millis(1));
    }
    assert(blocking::stats().admit_waits > 0, "callers waited for admission");
    gate.get().store(1, atomics::MemoryOrder::Release);
    assert(wg.wait_timeout(time::Duration::from_secs(60)), "every call returns");
    assert_eq(count(&ok), holders + extra);
    let st = blocking::stats();
    assert(st.peak_queued <= blocking::MAX_PENDING, "the queue never passed its bound");
    finish();
}

// A cancellable call parked for admission leaves with `None` when its task is cancelled, consuming nothing.
@test
fn a_cancelled_admission_wait_returns_none() {
    rt::set_worker_count(4);
    let holders = blocking::MAX_THREADS as i64;
    let fill = blocking::MAX_PENDING as i64;
    let ok = counter();
    let wg = sync::WaitGroup::new();
    let gate = counter();
    hold_threads(&wg, &ok, holders, &gate);
    wg.add(fill);
    for _i in 0..fill {
        let w = wg.clone();
        launch || {
            defer w.done();
            let _ = blocking::call(
                fn() i64 {
                    return 1i64;
                },
            );
        };
    }
    // Wait until the queue is full, then park a cancellable caller and cancel it.
    let deadline = platform::now_ns() + 5000000000;
    while blocking::stats().queued < blocking::MAX_PENDING && platform::now_ns() < deadline {
        time::sleep(time::Duration::from_millis(1));
    }
    assert_eq(blocking::stats().queued, blocking::MAX_PENDING);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let done = sync::WaitGroup::new();
    done.add(1);
    let d = done.clone();
    atomic::store_i64(&mut unsafe G_AFTER, 0, 0);
    let base = rt::cancelled_tasks();
    launch || {
        defer d.done();
        let _ = ktx.send(rt::current_key());
        let _got = blocking::call_c(
            fn() i64 {
                return 9i64;
            },
        );
        after_mark(); // unreachable: the cancelled task unwinds from the call
    };
    let key = krx.recv().unwrap();
    assert(ph::wait_parked(key), "the caller parks for admission");
    assert(rt::request_cancel(key, rt::CR_USER), "the parked caller is live");
    assert(done.wait_timeout(time::Duration::from_secs(10)), "the cancelled caller returns");
    assert_eq(afters(), 0i64);
    gate.get().store(1, atomics::MemoryOrder::Release);
    assert(wg.wait_timeout(time::Duration::from_secs(60)), "the rest return");
    finish();
    // Counted when the task completes, after its deferred signal: read once the scheduler has folded it.
    assert_eq(rt::cancelled_tasks() - base, 1usize);
}

// --- shutdown ---------------------------------------------------------------------------------------.

// A call held past the deadline: the shutdown returns on time with the call counted as running and its
// thread outstanding, a call made while the pool is closing runs on its caller's thread, the held call
// still returns its value, and a later attempt releases the pool.
@test
fn shutdown_with_an_unreturned_call_is_bounded() {
    rt::set_worker_count(2);
    let got = counter();
    let gate = counter();
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let g = got.clone();
    let ga = gate.clone();
    launch || {
        defer w.done();
        let gi = ga.clone(); // the call's closure owns its own handle: it outlives this frame
        g.get().store(
            blocking::call(
                fn() i64 {
                    return hold_open(&gi, 7);
                },
            ),
            atomics::MemoryOrder::Release,
        );
    };
    // The call is running before the shutdown is asked for, and stays out until the gate opens below.
    let deadline = platform::now_ns() + 5000000000;
    while blocking::stats().running < 1 && platform::now_ns() < deadline {
        time::sleep(time::Duration::from_millis(1));
    }
    let t0 = platform::now_ns();
    let r = blocking::try_shutdown(50000000);
    let took = platform::now_ns() - t0;
    assert(!r.released, "the pool is not released under an unreturned call");
    assert_eq(r.running, 1usize);
    assert_eq(r.queued, 0usize);
    assert(r.threads >= 1, "the thread running the call is outstanding");
    assert(took < 1000000000, "the shutdown returned at its deadline");
    // Closing: a new call runs on its caller's own thread and still answers.
    let late = counter();
    let wg2 = sync::WaitGroup::new();
    wg2.add(1);
    let w2 = wg2.clone();
    let l2 = late.clone();
    launch || {
        defer w2.done();
        l2.get().store(
            blocking::call(
                fn() i64 {
                    return 11i64;
                },
            ),
            atomics::MemoryOrder::Release,
        );
    };
    assert(wg2.wait_timeout(time::Duration::from_secs(10)), "the late call returns");
    assert_eq(count(&late), 11i64);
    gate.get().store(1, atomics::MemoryOrder::Release);
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "the held call returns");
    assert_eq(count(&got), 7i64);
    let r2 = blocking::try_shutdown(5000000000);
    assert(r2.released, "the pool is released once the call has returned");
    assert_eq(blocking::stats().created, 0usize);
    rt::shutdown();
}

// The same with an abandoned `call_c`: the task leaves at once, the body keeps the thread past the
// deadline, and the unclaimed value is destroyed exactly once when it returns.
@test
fn shutdown_with_an_abandoned_call_is_bounded() {
    rt::set_worker_count(2);
    atomic::store_i64(&mut unsafe G_FREES, 0, 0);
    atomic::store_i64(&mut unsafe G_AFTER, 0, 0);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let gate = counter();
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let ga = gate.clone();
    launch || {
        defer w.done();
        let _ = ktx.send(rt::current_key());
        let gi = ga.clone(); // the body owns its own handle: it outlives this frame
        let _got = blocking::call_c(
            fn() Payload {
                // The body stays out until the gate opens: the cancel and the first shutdown below
                // land while it runs, whatever the runner's pace.
                let _ = hold_open(&gi, 0);
                return Payload { n: 1 };
            },
        );
        after_mark(); // unreachable: the cancelled task unwinds from the call
    };
    let key = krx.recv().unwrap();
    assert(ph::wait_parked(key), "the caller parks in its call");
    assert(rt::request_cancel(key, rt::CR_USER), "the parked caller is live");
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "the caller leaves at once");
    assert_eq(afters(), 0i64);
    assert_eq(frees(), 0i64);
    let r = blocking::try_shutdown(50000000);
    assert(!r.released, "the body still runs");
    assert_eq(r.running, 1usize);
    gate.get().store(1, atomics::MemoryOrder::Release);
    let r2 = blocking::try_shutdown(5000000000);
    assert(r2.released, "released once the body returned");
    assert_eq(frees(), 1i64);
    rt::shutdown();
}

// The same through a `@blocking` extern: foreign code the runtime cannot stop.
@platform(macos | linux)
@test
fn shutdown_with_an_unreturned_foreign_call_is_bounded() {
    rt::set_worker_count(2);
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let rc = counter();
    let r0 = rc.clone();
    launch || {
        defer w.done();
        // Foreign code the runtime cannot stop, and cannot signal either: long enough that the shutdown
        // below, asked for once the call is running, cannot outlast it on a loaded runner.
        r0.get().store(unsafe usleep(1000000), atomics::MemoryOrder::Release);
    };
    // Wait until the pool reports the call running: a fixed sleep loses to a slow start under load.
    let deadline = platform::now_ns() + 5000000000;
    while blocking::stats().running < 1 && platform::now_ns() < deadline {
        time::sleep(time::Duration::from_millis(1));
    }
    let r = blocking::try_shutdown(50000000);
    assert(!r.released, "the foreign call is still running");
    assert_eq(r.running, 1usize);
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "the foreign call returns");
    assert_eq(count(&rc), 0i64);
    let r2 = blocking::try_shutdown(5000000000);
    assert(r2.released, "released once the foreign call returned");
    rt::shutdown();
}

// Shutdown with every thread held, the queue full and callers parked for admission: the waiters run
// their calls themselves at once, the queued work drains, and every value comes back.
@test
fn shutdown_settles_admission_waiters() {
    rt::set_worker_count(4);
    let holders = blocking::MAX_THREADS as i64;
    let fill = blocking::MAX_PENDING as i64;
    let waiters: i64 = 20;
    let calls = holders + fill + waiters;
    let ok = counter();
    let wg = sync::WaitGroup::new();
    let gate = counter();
    hold_threads(&wg, &ok, holders, &gate);
    wg.add(fill + waiters);
    for i in 0..fill + waiters {
        let w = wg.clone();
        let o = ok.clone();
        launch || {
            defer w.done();
            let want = i;
            let got = blocking::call(
                fn() i64 {
                    return want;
                },
            );
            if got == want {
                let _ = o.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            }
        };
    }
    let deadline = platform::now_ns() + 5000000000;
    while blocking::stats().admit_waits < waiters as usize && platform::now_ns() < deadline {
        time::sleep(time::Duration::from_millis(1));
    }
    assert(blocking::stats().admit_waits >= waiters as usize, "the extra callers parked for admission");
    let r = blocking::try_shutdown(20000000);
    assert(!r.released, "the holders still run");
    gate.get().store(1, atomics::MemoryOrder::Release);
    assert(wg.wait_timeout(time::Duration::from_secs(60)), "every call returns");
    assert_eq(count(&ok), calls);
    let r2 = blocking::try_shutdown(5000000000);
    assert(r2.released, "released once drained");
    rt::shutdown();
}
