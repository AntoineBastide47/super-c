// OS-thread ownership (std/parallel/thread): the result crosses the boundary exactly once, a dropped
// handle detaches, every substrate failure is fatal after releasing what it built, and repeated spawn and
// detach reach a steady state. The fatal paths run under `should_panic` with the substrate's failure hooks
// (`sc_runtime::sc_rt_fail_arm`); each test is a forked child, so an armed hook never outlives it.

import atomic;
import sc_runtime;
import std::parallel::thread as thread;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::blocking as blocking;
import std::parallel::io as io;
import std::parallel::time as time;
import std::parallel::platform as platform;
import std::testing::bench_sys as sys;
import tests::cli_harness as cli;

// Exact-destruction counter: every `free` of a Tracked bumps it, so a test can prove one destruction.
static mut G_FREES: i64 = 0;

struct Tracked {
    pub n: i64,
}

extend Tracked as Free {
    pub fn free(self: &mut Tracked) {
        let _ = unsafe atomic::add_i64(&mut unsafe G_FREES, 1, 0);
    }
}

fn frees() i64 {
    return unsafe atomic::load_i64(&mut unsafe G_FREES, 1);
}

// Wait, bounded, until `frees()` reaches `want`.
fn wait_frees(want: i64) bool {
    let deadline = platform::now_ns() + 5000000000;
    while frees() < want {
        if platform::now_ns() > deadline {
            return false;
        }
        rt::sleep_ns(200000);
    }
    return true;
}

// --- the result crosses once -----------------------------------------------------------------------------

@test
fn join_after_completion_moves_the_value() {
    let h = thread::spawn(
        fn() Tracked {
            return Tracked { n: 7 };
        },
    );
    rt::sleep_ns(20000000); // the thread finishes long before the join
    let v = h.join();
    assert_eq(v.n, 7);
    assert_eq(frees(), 0); // moved, not destroyed
    let _ = v;
}

@test
fn join_before_completion_waits() {
    let h = thread::spawn(
        fn() Tracked {
            rt::sleep_ns(30000000);
            return Tracked { n: 9 };
        },
    );
    let v = h.join();
    assert_eq(v.n, 9);
    assert_eq(frees(), 0);
    let _ = v;
}

@test
fn value_destroyed_once_after_join() {
    {
        let h = thread::spawn(
            fn() Tracked {
                return Tracked { n: 1 };
            },
        );
        let v = h.join();
        assert_eq(v.n, 1);
    }
    assert_eq(frees(), 1);
}

@test
fn drop_before_completion_detaches_and_the_thread_frees() {
    {
        let _h = thread::spawn(
            fn() Tracked {
                rt::sleep_ns(30000000);
                return Tracked { n: 2 };
            },
        );
    }
    assert_eq(frees(), 0); // still running when the handle went
    assert(wait_frees(1), "the detached thread destroys its unclaimed result");
    rt::sleep_ns(10000000);
    assert_eq(frees(), 1);
}

@test
fn drop_after_completion_frees_here() {
    let h = thread::spawn(
        fn() Tracked {
            return Tracked { n: 3 };
        },
    );
    rt::sleep_ns(20000000);
    assert_eq(frees(), 0); // the thread finished but the handle still owns the value
    {
        let _h = h;
    }
    assert_eq(frees(), 1);
}

@test
fn zero_sized_result() {
    let h = thread::spawn(|| {});
    h.join();
    {
        // Detached: the thread reports through the counter, and the test waits for it so the exit
        // leak check sees a finished thread rather than one still holding its payload.
        let _d = thread::spawn(
            || {
                let _ = unsafe atomic::add_i64(&mut unsafe G_FREES, 1, 0);
            },
        );
    }
    assert(wait_frees(1), "the detached zero-sized thread finishes");
}

// --- failures are fatal, after release ------------------------------------------------------------------

@test(should_panic)
fn spawn_fails_when_the_os_refuses_a_thread() {
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_THREAD_CREATE, 1);
    let _h = thread::spawn(
        fn() Tracked {
            return Tracked { n: 4 };
        },
    );
}

@test(should_panic)
fn spawn_fails_when_the_handle_cannot_be_allocated() {
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_ALLOC, 1);
    let _h = thread::spawn(
        fn() i32 {
            return 1;
        },
    );
}

@test(should_panic)
fn join_failure_is_fatal() {
    let h = thread::spawn(
        fn() i32 {
            return 1;
        },
    );
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_THREAD_JOIN, 1);
    let _ = h.join();
}

@test(should_panic)
fn detach_failure_is_fatal() {
    let h = thread::spawn(
        fn() i32 {
            return 1;
        },
    );
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_THREAD_DETACH, 1);
    let _h = h;
}

@test(should_panic)
fn task_stack_map_failure_is_fatal() {
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_STACK_MAP, 1);
    launch || {};
}

@test(should_panic)
fn task_stack_guard_failure_is_fatal() {
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_STACK_GUARD, 1);
    launch || {};
}

@test(should_panic)
fn task_stack_release_failure_is_fatal() {
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        w.done();
    };
    wg.wait();
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_STACK_RELEASE, 1);
    rt::shutdown(); // drains the pool: the first stack release fails
}

@test(should_panic)
fn scheduler_lock_allocation_failure_is_fatal() {
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_ALLOC, 1); // the timer lock, first of all
    launch || {};
}

@test(should_panic)
fn scheduler_parker_allocation_failure_is_fatal() {
    rt::set_worker_count(2);
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_ALLOC, 4); // lock, parker 0 lock, cv; parker 1 lock
    launch || {};
}

@test(should_panic)
fn scheduler_without_any_worker_is_fatal() {
    rt::set_worker_count(1);
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_THREAD_CREATE, 1);
    launch || {};
}

@test(should_panic)
fn worker_handle_allocation_failure_is_fatal() {
    rt::set_worker_count(1);
    // The last allocation of a one-worker start-up: lock, parker lock, parker cv, then the worker's thread
    // handle. (The worker's own context lives inline in its frame, so it is not an allocation here.)
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_ALLOC, 4);
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        w.done();
    };
    let _ = wg.wait_timeout(time::Duration::from_secs(2));
}

// A worker the OS refuses after others started: the pool runs on with the workers it has.
@test
fn scheduler_keeps_the_workers_it_started() {
    rt::set_worker_count(3);
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_THREAD_CREATE, 2);
    let wg = sync::WaitGroup::new();
    wg.add(50);
    for _i in 0..50 {
        let w = wg.clone();
        launch || {
            w.done();
        };
    }
    wg.wait();
    assert_eq(rt::worker_count(), 1usize); // the live count (creation stops at the refused second worker), not the three asked for
    rt::shutdown();
}

@test(should_panic)
fn blocking_pool_lock_allocation_failure_is_fatal() {
    // The scheduler's allocations come first (it starts on the first launch); arm after it is up.
    rt::set_worker_count(1);
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        w.done();
    };
    wg.wait();
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_ALLOC, 1);
    let _ = blocking::call(
        fn() i32 {
            return 1;
        },
    );
}

@test(should_panic)
fn blocking_pool_without_any_thread_is_fatal() {
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_THREAD_CREATE, 1);
    let _ = blocking::call(
        fn() i32 {
            return 1;
        },
    );
}

@platform(macos | linux)
@test(should_panic)
fn reactor_thread_failure_is_fatal() {
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_THREAD_CREATE, 1);
    let _ = io::ensure_reactor();
}

// --- steady state -----------------------------------------------------------------------------------------

// Two thousand detached and two thousand joined threads: every cell, payload and handle block comes back
// (the suite's leak gate checks the child at exit), the task stacks are untouched, and the resident set
// does not keep growing.
@test
fn repeated_spawn_and_detach_reach_a_steady_state() {
    let stk0 = platform::stack_bytes();
    let rss0 = unsafe sys::sc_bs_rss_now();
    for _i in 0..2000 {
        let _h = thread::spawn(
            fn() Tracked {
                return Tracked { n: 5 };
            },
        );
    }
    assert(wait_frees(2000), "every detached thread destroyed its result");
    let rss1 = unsafe sys::sc_bs_rss_now();
    for i in 0..2000 {
        let h = thread::spawn(
            fn() i64 {
                return i;
            },
        );
        assert_eq(h.join(), i);
    }
    let rss2 = unsafe sys::sc_bs_rss_now();
    assert_eq(platform::stack_bytes(), stk0);
    if rss0 >= 0 {
        // Thread stacks the OS caches after exit are bounded; unreleased cells or handles would not be.
        assert(rss2 - rss1 < 8 * 1048576, "the second thousand threads do not grow the resident set");
    }
    assert_eq(frees(), 2000);
}

// --- the compile-time rule -------------------------------------------------------------------------------

// A closure that captures nothing is Send, so the old bound let it return a raw pointer built inside it:
// a non-Send value crossing back over the thread boundary. `T: Send` closes that.
@test
fn spawn_rejects_a_non_send_result() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::parallel::thread as thread;
fn main() i32 {
    let h = thread::spawn(fn() *mut i32 {
        let mut x: i32 = 5;
        return &mut x as *mut i32;
    });
    let _ = h.join();
    return 0;
}
)",
    );
    let r = p.compile("main.spc");
    assert(r.exit != 0, "returning a raw pointer from a spawned thread is rejected");
    assert(r.out_has("Send"), "the rejection cites the Send bound");
}
