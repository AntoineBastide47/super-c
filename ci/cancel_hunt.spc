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

fn main() i32 {
    notify_vs_cancel(300);
    timeout_vs_cancel(200);
    blocking_vs_cancel(200);
    group_storm(20);
    blocking::shutdown();
    let res = rt::try_shutdown(rt::ShutdownOptions::defaults());
    if res.unresponsive != 0 {
        return 1;
    }
    return 0;
}
