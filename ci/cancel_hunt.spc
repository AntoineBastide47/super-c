// Cancellation race exerciser for the ThreadSanitizer lane (see check.sh). Hammers every pairwise race
// the reclamation design must survive: notify against cancel, timeout against cancel, blocking completion
// against cancel, cancellation during every park phase (by cancelling at random points around parks),
// group cancellation fan-outs, and shutdown against spawn. Any TSan report is a real happens-before hole.

import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::time as time;
import std::parallel::task as task;
import std::parallel::blocking as blocking;

// Notify and cancel race for the same park, over and over, with jittered timing.
fn notify_vs_cancel(rounds: i64) {
    for i in 0..rounds {
        let kch = chan::Channel::<rt::TaskKey>::bounded(1);
        let ktx = kch.sender();
        let krx = kch.receiver();
        let ch = chan::Channel::<i64>::bounded(1);
        let tx = ch.sender();
        let rx = ch.receiver();
        let done = sync::WaitGroup::new();
        done.add(1);
        let d = done.clone();
        launch || {
            defer d.done();
            let _ = ktx.send(rt::current_key());
            let _got = rx.recv();
        };
        let key = krx.recv().unwrap();
        if i % 4 == 0 {
            time::sleep(time::Duration::from_micros(i as u64 % 300));
        }
        let _ = tx.send(i);
        let _ = rt::request_cancel(key, rt::CR_USER);
        done.wait();
    }
}

// Timed waits whose deadline lands exactly where the cancel does.
fn timeout_vs_cancel(rounds: i64) {
    for i in 0..rounds {
        let kch = chan::Channel::<rt::TaskKey>::bounded(1);
        let ktx = kch.sender();
        let krx = kch.receiver();
        let gate = sync::WaitGroup::new();
        gate.add(1);
        let done = sync::WaitGroup::new();
        done.add(1);
        let g = gate.clone();
        let d = done.clone();
        launch || {
            defer d.done();
            let _ = ktx.send(rt::current_key());
            let _ok = g.wait_timeout(time::Duration::from_micros(500));
        };
        let key = krx.recv().unwrap();
        time::sleep(time::Duration::from_micros(i as u64 % 700));
        let _ = rt::request_cancel(key, rt::CR_USER);
        done.wait();
        gate.done();
    }
}

// Blocking completion racing abandonment.
fn blocking_vs_cancel(rounds: i64) {
    for i in 0..rounds {
        let kch = chan::Channel::<rt::TaskKey>::bounded(1);
        let ktx = kch.sender();
        let krx = kch.receiver();
        let done = sync::WaitGroup::new();
        done.add(1);
        let d = done.clone();
        launch || {
            defer d.done();
            let _ = ktx.send(rt::current_key());
            let _got = blocking::call_c(
                fn() i64 {
                    return 7;
                },
            );
        };
        let key = krx.recv().unwrap();
        if i % 2 == 0 {
            time::sleep(time::Duration::from_micros(50));
        }
        let _ = rt::request_cancel(key, rt::CR_USER);
        done.wait();
    }
}

// A fan-out of sleepers cancelled as a group, at several worker interleavings.
fn group_storm(rounds: i64) {
    for _i in 0..rounds {
        let mut g = task::TaskGroup::new();
        for _k in 0..16 {
            g.spawn(
                || {
                    time::sleep(time::Duration::from_secs(10));
                },
            );
        }
        g.cancel();
        let _ = g.join();
    }
}

// Membership schedules: two sources per task with either one cancelling, a source dropped while its
// members live, the same source bound twice, members completing while the sweep runs, and a block reused
// right after its member completed. Every record must leave its source exactly once and touch no freed
// state: under ASan this is the use-after-free check, under TSan the ordering check.
fn membership_storm(rounds: i64) {
    for i in 0..rounds {
        let (sa, ta) = task::CancelSource::new();
        let (sb, tb) = task::CancelSource::new();
        let wg = sync::WaitGroup::new();
        wg.add(24);
        for k in 0..8i64 {
            let w = wg.clone();
            let a = ta.clone();
            let b = tb.clone();
            launch || {
                defer w.done();
                a.bind_current();
                b.bind_current();
                a.bind_current(); // duplicate: still one membership
                if k % 2 == 0 {
                    time::sleep(time::Duration::from_secs(10)); // reclaimed by whichever source cancels
                }
                // Odd children complete at once: their keys may be swept after they are gone.
            };
        }
        {
            // A source whose handles all go away while its members run: the records keep it alive.
            let (sc, tc) = task::CancelSource::new();
            for _k in 0..8 {
                let w = wg.clone();
                let c = tc.clone();
                launch || {
                    defer w.done();
                    c.bind_current();
                    rt::yield_now();
                };
            }
            let _ = sc.members();
        }
        for _k in 0..8 {
            // Never bound: a block recycled from a completed member must not be reached by any sweep.
            let w = wg.clone();
            launch || {
                defer w.done();
                time::sleep(time::Duration::from_millis(1));
            };
        }
        if i % 2 == 0 {
            sa.cancel(rt::CR_USER);
            sb.cancel(rt::CR_POLICY);
        } else {
            sb.cancel(rt::CR_USER);
            sa.cancel(rt::CR_POLICY);
        }
        wg.wait();
        if sa.members() != 0 || sb.members() != 0 {
            panic("membership_storm: a cancelled source still holds members");
        }
    }
}

fn main() i32 {
    notify_vs_cancel(300);
    timeout_vs_cancel(200);
    blocking_vs_cancel(200);
    group_storm(20);
    membership_storm(200);
    blocking::shutdown();
    let res = rt::try_shutdown(rt::ShutdownOptions::defaults());
    if res.unresponsive != 0 {
        return 1;
    }
    return 0;
}
