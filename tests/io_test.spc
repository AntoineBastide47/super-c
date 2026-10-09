// The reactor (std/parallel/io): several tasks may wait on one descriptor in one direction or in both,
// a descriptor number reused under a stale wait serves its new waiter, a readiness event and a deadline
// race to a single winner on every round and every wait settles, cancellation and close reach the reactor
// before a waiting frame ends, a descriptor that cannot be registered reports not ready, shutdown settles
// what is still parked, and a thousand idle descriptors leave an active one served. Every test ends with
// no admitted wait left behind. Waits that readiness must end have no deadline, and the tests wait for
// state through the parallel harness: a missed wake shows as a bounded wait that fails, never as a
// duration a loaded runner exceeds.

import std::parallel::runtime as rt;
import std::parallel::io as io;
import std::parallel::net as net;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::arc as arc;
import std::parallel::atomics as atomics;
import std::parallel::platform as platform;
import std::parallel::time as time;
import tests::parallel_harness as ph;
import tests::cli_harness as cli;
import sc_io;

// A connected pair: `a` is the client end, `b` the accepted end.
struct Pair {
    pub a: net::TcpStream,
    pub b: net::TcpStream,
}

fn pair(l: &net::TcpListener) Pair {
    let a = net::TcpStream::connect("127.0.0.1", l.port()).unwrap();
    let b = l.accept().unwrap();
    return Pair { a: a, b: b };
}

fn counter() arc::Arc<atomics::Atomic<i64>> {
    return arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
}

fn count(c: &arc::Arc<atomics::Atomic<i64>>) i64 {
    return c.get().load(atomics::MemoryOrder::Acquire);
}

fn bump(c: &arc::Arc<atomics::Atomic<i64>>) {
    let _ = c.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
}

fn write_one(s: &net::TcpStream) {
    let msg: [u8; 1] = [7u8];
    let _ = s.write(msg);
}

// Wait on `fd` without a deadline, so only readiness (or a close or shutdown) ends the wait, and count
// a readiness.
fn wait_ready(fd: i32, write: bool, hits: &arc::Arc<atomics::Atomic<i64>>) {
    if io::wait_until(fd, write, 0) {
        bump(hits);
    }
}

// Wait, bounded, until `want` tasks have recorded an I/O wait (`io::pending_waits`): the waiters are at
// their wait, so a byte written now is what wakes them rather than what they find already there.
fn wait_pending(want: usize) bool {
    return ph::wait_waiting(rt::WK_IO, want);
}

fn finish() {
    assert_eq(io::pending_waits(), 0usize);
    io::shutdown();
    rt::shutdown();
}

// Two tasks wait readable on ONE socket: one byte wakes both promptly; neither is silently replaced.
@test
fn two_readers_on_one_socket_both_wake() {
    rt::set_worker_count(2);
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let p = pair(&l);
    let fd = p.b.fd;
    let wg = sync::WaitGroup::new();
    wg.add(2);
    let hits = counter();
    for _k in 0..2 {
        let w = wg.clone();
        let h = hits.clone();
        launch || {
            defer w.done();
            wait_ready(fd, false, &h);
        };
    }
    assert(wait_pending(2), "both readers arm");
    write_one(&p.a);
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "both readers finish");
    assert_eq(count(&hits), 2);
    finish();
}

// A read wait and a write wait on the same socket are independent: the socket is writable at once, and the
// reader must still wake when data arrives afterwards.
@test
fn read_and_write_waits_on_one_socket_are_independent() {
    rt::set_worker_count(2);
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let p = pair(&l);
    let fd = p.b.fd;
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let hits = counter();
    let w1 = wg.clone();
    let h1 = hits.clone();
    launch || {
        defer w1.done();
        wait_ready(fd, false, &h1);
    };
    assert(wait_pending(1), "the reader arms first");
    let writer = sync::WaitGroup::new();
    writer.add(1);
    let w2 = writer.clone();
    let h2 = hits.clone();
    launch || {
        defer w2.done();
        wait_ready(fd, true, &h2);
    };
    // The write wait is satisfied at once (the socket is writable) and never pending, so its completion
    // is what orders it: only once it has finished is the byte written, and the still-armed reader must
    // wake on it. The reader may still be registering when the writer does: under epoll the two
    // directions share one registration, which neither may drop.
    assert(writer.wait_timeout(time::Duration::from_secs(10)), "the write wait finishes at once");
    write_one(&p.a);
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "the read wait finishes");
    assert_eq(count(&hits), 2);
    finish();
}

// Registrations add up on every backend: a read registration that lands after a write one, before the
// poller is read, keeps the write interest and its queued event (an epoll registration replaces the
// descriptor's mask, so each carries the bits registered before it).
@test
fn a_registration_keeps_the_other_directions_event() {
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let p = pair(&l);
    let q = unsafe sc_io::sc_io_new();
    assert(q != null, "a poller");
    assert_eq(unsafe sc_io::sc_io_set(q, p.b.fd, sc_io::WR, 0), 0);
    assert_eq(unsafe sc_io::sc_io_set(q, p.b.fd, sc_io::RD, 1), 0);
    let mut out: [i32; 192] = [0; 192];
    assert_eq(unsafe sc_io::sc_io_wait(q, &mut out[0], sc_io::EV_MAX, 10000), 1);
    assert_eq(out[0], p.b.fd);
    assert_eq(out[1], sc_io::WR);
    unsafe sc_io::sc_io_free(q);
}

// The same two waits, but the byte arrives WHILE the write wait is arming: the read event may be delivered
// before the reactor has seen the write wait's arm, and the write wait must still be served promptly rather
// than sit until something else wakes the reactor.
@test
fn a_write_wait_arming_under_a_read_event_is_still_served() {
    rt::set_worker_count(2);
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let rounds: i64 = 40;
    let hits = counter();
    for _r in 0..rounds {
        let p = pair(&l);
        let fd = p.b.fd;
        let wg = sync::WaitGroup::new();
        wg.add(2);
        let w1 = wg.clone();
        let h1 = hits.clone();
        launch || {
            defer w1.done();
            wait_ready(fd, false, &h1);
        };
        assert(wait_pending(1), "the reader arms first");
        let w2 = wg.clone();
        let h2 = hits.clone();
        launch || {
            defer w2.done();
            wait_ready(fd, true, &h2);
        };
        write_one(&p.a);
        assert(wg.wait_timeout(time::Duration::from_secs(10)), "both waits finish");
    }
    assert_eq(count(&hits), 2 * rounds);
    finish();
}

// A timed wait on socket X; X is closed under it and its number handed to a new socket, on which a second
// task waits: the first wait's expiry must not remove the second's registration.
@test
fn a_reused_descriptor_number_serves_its_new_waiter() {
    rt::set_worker_count(2);
    // The reactor's own descriptors exist before the pairs: the number a close frees is then the lowest
    // free one, which the next socket takes.
    let _ = io::ensure_reactor();
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let mut p = pair(&l);
    let fd = p.b.fd;
    // The first wait is armed and then settled by the close; the same descriptor number then carries a
    // new socket and a new wait. The byte is written only after the first wait's deadline has passed,
    // so a stale expiry would have removed the new registration by then.
    let first = sync::WaitGroup::new();
    first.add(1);
    let w1 = first.clone();
    launch || {
        defer w1.done();
        let _ = io::wait_until(fd, false, time::deadline_in(time::Duration::from_millis(100)));
    };
    assert(wait_pending(1), "the first wait arms");
    p.b.close();
    p.a.close();
    assert(first.wait_timeout(time::Duration::from_secs(10)), "the first wait settles on the close");
    let q = pair(&l); // POSIX hands out the lowest free numbers: the two just closed, in order
    let fd2 = q.b.fd;
    assert(cli::on_windows() || fd2 == fd, "the new socket reuses the number");
    let hits = counter();
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w2 = wg.clone();
    let h2 = hits.clone();
    launch || {
        defer w2.done();
        wait_ready(fd2, false, &h2);
    };
    assert(wait_pending(1), "the new wait arms on the reused number");
    time::sleep(time::Duration::from_millis(200));
    write_one(&q.a);
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "the second wait finishes");
    assert_eq(count(&hits), 1);
    finish();
}

// A close that lands as the reactor stops: a closer that counted in before the stop pushes its report and
// only then counts out, so the poller thread drains once more after it finds no closer left. Every round,
// thirty-two tasks signal and then close a listener each while the shutdown starts behind the signals;
// the suite's leak gate holds every report to account. Twenty-five rounds: enough to hit the window, and
// little enough socket churn not to slow the tests that share the shard (the select backend most).
@test
fn close_racing_shutdown_drains_its_report() {
    rt::set_worker_count(2);
    for _i in 0..25 {
        let _ = io::ensure_reactor();
        let wg = sync::WaitGroup::new();
        wg.add(32);
        for _k in 0..32 {
            let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
            let w = wg.clone();
            launch || {
                w.done();
                let _ = l.port(); // the env closes the listener once the body is over: behind the signal
            };
        }
        assert(wg.wait_timeout(time::Duration::from_secs(10)), "the tasks signal");
        io::shutdown();
    }
    finish();
}

// Closes racing the reactor's start keep their count: the builder clears only a stopped reactor's mark, so
// every close counts out to zero and each round's shutdown finds no closer left. A lost count leaves the
// stopping reactor waiting for a closer that is gone, and the shutdown never returns.
@test
fn closes_racing_the_reactor_start_keep_their_count() {
    rt::set_worker_count(2);
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    for _i in 0..50 {
        let p = pair(&l);
        let fd = p.b.fd;
        let hits = counter();
        let h = hits.clone();
        let mut spare = Vector::<net::TcpListener>::new();
        for _k in 0..16 {
            spare.push(net::TcpListener::bind("127.0.0.1", 0).unwrap());
        }
        launch || {
            wait_ready(fd, false, &h); // the first wait starts the reactor
        };
        spare.clear(); // sixteen closes while it starts
        assert(wait_pending(1), "the wait is recorded");
        write_one(&p.a);
        assert(ph::wait_count(&hits, 1), "the byte ends the wait");
        assert(ph::wait_quiescent(), "the woken task completes");
        io::shutdown();
    }
    finish();
}

// The deadline and the data race on every round: every wait settles, whichever wins, and no wait is left
// admitted when the rounds are over.
@test
fn event_and_deadline_race_settles_every_round() {
    rt::set_worker_count(2);
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let p = pair(&l);
    let fd = p.b.fd;
    let rounds: i64 = 500;
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let done = counter();
    let d = done.clone();
    launch || {
        defer w.done();
        let mut buf = Vector::<u8>::new();
        buf.resize_default(64);
        let cap: usize = 64;
        for _r in 0..rounds {
            if io::wait_until(fd, false, time::deadline_in(time::Duration::from_micros(300))) {
                let _ = io::read(fd, buf.index_range_mut(0..cap));
            }
            bump(&d);
        }
    };
    for _r in 0..rounds {
        time::sleep(time::Duration::from_micros(300));
        write_one(&p.a);
    }
    assert(wg.wait_timeout(time::Duration::from_secs(30)), "the rounds finish");
    assert_eq(count(&done), rounds);
    finish();
}

// Cancellation lands at every point of a wait's life: before the arm is published, while it is armed, and
// as data arrives. Every task ends, the reactor keeps no wait, and the sockets still work afterwards.
@test
fn cancellation_at_every_point_of_a_wait_reaches_the_reactor() {
    rt::set_worker_count(2);
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let p = pair(&l);
    let fd = p.b.fd;
    let rounds: i64 = 200;
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let ended = counter();
    for r in 0..rounds {
        let wg = sync::WaitGroup::new();
        wg.add(1);
        let w = wg.clone();
        let e = ended.clone();
        let tx = ktx.clone();
        launch || {
            defer w.done();
            defer bump(&e);
            let _ = tx.send(rt::current_key());
            let _ = io::wait_until(fd, false, 0);
        };
        let key = krx.recv().unwrap();
        // 0 to 60 us: sometimes before the park, sometimes while armed.
        let spin_until = platform::now_ns() + r as u64 % 7 * 10000;
        while platform::now_ns() < spin_until {
            rt::yield_now();
        }
        if r % 3 == 0 {
            write_one(&p.a); // data racing the cancellation
        }
        let _ = rt::request_cancel(key, rt::CR_USER);
        assert(wg.wait_timeout(time::Duration::from_secs(10)), "the cancelled waiter finishes");
    }
    assert_eq(count(&ended), rounds);
    // The pair still works: drain what the rounds wrote, then one more round trip.
    let mut buf = Vector::<u8>::new();
    buf.resize_default(256);
    let cap: usize = 256;
    let expected = (rounds + 2) / 3 + 1; // one byte per round that wrote, and the one below
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let got = counter();
    let g = got.clone();
    launch || {
        defer w.done();
        loop {
            let n = io::read(fd, buf.index_range_mut(0..cap));
            if n <= 0 {
                break;
            }
            let _ = g.get().fetch_add(n as i64, atomics::MemoryOrder::Relaxed);
            if count(&g) >= expected {
                break;
            }
        }
    };
    write_one(&p.a);
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "the reader finishes");
    assert_eq(count(&got), expected);
    finish();
}

// A socket closed under a wait: the close is reported to the reactor, the wait settles as not ready,
// and the number's next socket starts a new generation. The waits have no deadline, so only the close
// (then the byte) can end them: a missed report fails the bounded wait on the group instead of racing
// a clock. `wait_pending` sees the wait's record, which comes before its registration, so the close may
// also land first: the registration then fails on the closed number (or on the reactor's own descriptor
// that took it, when the wait started the reactor) and the wait settles as not ready all the same.
@test
fn close_under_a_wait_settles_it_at_once() {
    rt::set_worker_count(2);
    // The reactor's own descriptors exist before the pairs: the number a close frees is then the lowest
    // free one, which the next socket takes.
    let _ = io::ensure_reactor();
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let mut p = pair(&l);
    let fd = p.b.fd;
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let not_ready = counter();
    let t = not_ready.clone();
    launch || {
        defer w.done();
        if !io::wait_readable(fd) {
            bump(&t);
        }
    };
    assert(wait_pending(1), "the wait arms");
    p.b.close();
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "the close ends the wait");
    assert_eq(count(&not_ready), 1);
    // The reused number serves its new socket: the connecting end takes the lowest free number (POSIX).
    let q = pair(&l);
    let hits = counter();
    wg.add(1);
    let w2 = wg.clone();
    let h = hits.clone();
    let fd2 = q.a.fd;
    assert(cli::on_windows() || fd2 == fd, "the new socket reuses the number");
    launch || {
        defer w2.done();
        if io::wait_readable(fd2) {
            bump(&h);
        }
    };
    assert(wait_pending(1), "the new wait arms");
    write_one(&q.b);
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "the new wait ends");
    assert_eq(count(&hits), 1);
    finish();
}

// A descriptor number that names nothing cannot be registered: the wait reports not ready at once rather
// than parking until its deadline, and a read on it fails with the descriptor's own error.
@test
fn an_unregisterable_descriptor_reports_not_ready_at_once() {
    rt::set_worker_count(2);
    let _ = io::ensure_reactor(); // its own descriptors must not take the number closed below
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let mut p = pair(&l);
    let fd = p.b.fd;
    p.b.close();
    p.a.close();
    let result = counter(); // 1: the wait reported not ready, 2: it reported ready
    let r = result.clone();
    launch || {
        // No deadline: the refused registration alone ends the wait.
        let v: i64 = if io::wait_until(fd, false, 0) {
            2;
        } else {
            1;
        };
        r.get().store(v, atomics::MemoryOrder::Release);
    };
    assert(ph::wait_count(&result, 1), "the refused registration ends the wait");
    assert_eq(count(&result), 1);
    assert(ph::wait_quiescent(), "the task completes");
    finish();
}

// Numbers closed before the reactor starts: its own descriptors take the lowest free numbers, so a wait
// on a closed number can name one of them. That registration is refused and the wait reports not ready,
// and the wake pipe keeps its own registration: the disarm of a wait that ends at its deadline, which only
// a wake delivers, is still acknowledged.
@test
fn a_number_the_reactor_took_reports_not_ready() {
    rt::set_worker_count(2);
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let mut p1 = pair(&l);
    let mut p2 = pair(&l);
    let live = pair(&l);
    let mut fds = Vector::<i32>::new();
    fds.push(p1.a.fd);
    fds.push(p1.b.fd);
    fds.push(p2.b.fd);
    p1.a.close();
    p1.b.close();
    p2.b.close();
    let wg = sync::WaitGroup::new();
    let not_ready = counter();
    for i in 0..fds.len() {
        wg.add(1);
        let w = wg.clone();
        let t = not_ready.clone();
        let fd = *fds.at(i);
        launch || {
            defer w.done();
            if !io::wait_readable(fd) {
                bump(&t);
            }
        };
    }
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "every wait on a closed number ends");
    assert_eq(count(&not_ready), 3);
    wg.add(1);
    let w = wg.clone();
    let fd = live.b.fd;
    launch || {
        defer w.done();
        let _ = io::wait_until(fd, false, time::deadline_in(time::Duration::from_millis(1)));
    };
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "the expired wait's disarm is acknowledged");
    finish();
}

// Shutdown with a wait still parked: the wait settles as not ready, the task resumes, and a wait started
// after the shutdown starts a fresh reactor. The waits have no deadline and no byte arrives before the
// shutdown, so the shutdown alone can end the first one.
@test
fn shutdown_settles_a_pending_wait() {
    rt::set_worker_count(2);
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let p = pair(&l);
    let fd = p.b.fd;
    let result = counter(); // 1: the wait reported not ready, 2: it reported ready
    let r = result.clone();
    launch || {
        let v: i64 = if io::wait_until(fd, false, 0) {
            2;
        } else {
            1;
        };
        r.get().store(v, atomics::MemoryOrder::Release);
    };
    assert(wait_pending(1), "the wait is recorded");
    io::shutdown();
    assert(ph::wait_count(&result, 1), "the shutdown ends the wait");
    assert_eq(count(&result), 1);
    assert(ph::wait_quiescent(), "the settled task completes");
    // A fresh reactor serves the next wait.
    let hits = counter();
    let h = hits.clone();
    launch || {
        wait_ready(fd, false, &h);
    };
    assert(wait_pending(1), "the new wait is recorded");
    write_one(&p.a);
    assert(ph::wait_count(&hits, 1), "the byte ends the new wait");
    assert(ph::wait_quiescent(), "the woken task completes");
    finish();
}

// A thousand idle descriptors parked on the reactor while one connection does a hundred round trips: the
// active one is served, the idle ones stay parked, and one byte each wakes them all. How fast the round
// trips go is the reactor benchmark's question.
@test
fn idle_descriptors_leave_an_active_one_served() {
    rt::set_worker_count(2);
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let idle: i64 = 500; // pairs, so a thousand descriptors
    let mut pairs = Vector::<Pair>::new();
    for _i in 0..idle {
        pairs.push(pair(&l));
    }
    let wg = sync::WaitGroup::new();
    wg.add(idle);
    let hits = counter();
    for i in 0..idle as usize {
        let fd = pairs.at(i).b.fd;
        let w = wg.clone();
        let h = hits.clone();
        launch || {
            defer w.done();
            wait_ready(fd, false, &h);
        };
    }
    assert(wait_pending(idle as usize), "every idle wait is recorded");
    // The active connection.
    let p = pair(&l);
    let afd = p.b.fd;
    let awg = sync::WaitGroup::new();
    awg.add(1);
    let aw = awg.clone();
    let trips = counter();
    let tr = trips.clone();
    launch || {
        defer aw.done();
        let mut buf = Vector::<u8>::new();
        buf.resize_default(8);
        let cap: usize = 8;
        for _k in 0..100 {
            if io::read(afd, buf.index_range_mut(0..cap)) <= 0 {
                break;
            }
            let _ = io::write(afd, buf.index_range(0..1));
            bump(&tr);
        }
    };
    let mut back = Vector::<u8>::new();
    back.resize_default(8);
    let bcap: usize = 8;
    for _k in 0..100 {
        write_one(&p.a);
        assert(p.a.read(back.index_range_mut(0..bcap)) == 1, "the echo comes back");
    }
    assert(awg.wait_timeout(time::Duration::from_secs(10)), "the echo task finishes");
    assert_eq(count(&trips), 100);
    assert_eq(io::pending_waits(), idle as usize);
    for i in 0..idle as usize {
        write_one(&pairs.at(i).a);
    }
    assert(wg.wait_timeout(time::Duration::from_secs(30)), "every idle waiter wakes");
    assert_eq(count(&hits), idle);
    finish();
}

// One scheduler worker, a burst of waits from it far larger than one event batch: an unrelated task
// launched behind the burst still gets its turns while the waits are pending, and once readiness lands
// for all of them every command reaches the reactor and every wait is served exactly once.
@test
fn a_burst_of_waits_from_one_worker_is_all_served() {
    rt::set_worker_count(1);
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let n: i64 = 300;
    let mut pairs = Vector::<Pair>::new();
    for _i in 0..n {
        pairs.push(pair(&l));
    }
    let wg = sync::WaitGroup::new();
    wg.add(n);
    let hits = counter();
    for i in 0..n as usize {
        let fd = pairs.at(i).b.fd;
        let w = wg.clone();
        let h = hits.clone();
        launch || {
            defer w.done();
            // The byte comes only after the yield phase below; only readiness ends the wait.
            wait_ready(fd, false, &h);
            wait_ready(fd, true, &h); // writable at once: a second wait on the same descriptor
        };
    }
    // Progress behind the burst: a task that only yields must finish while every wait is still pending.
    assert(wait_pending(n as usize), "every wait of the burst is recorded");
    let turns = counter();
    let pw = sync::WaitGroup::new();
    pw.add(1);
    let pwc = pw.clone();
    let tc = turns.clone();
    launch || {
        defer pwc.done();
        for _k in 0..1000 {
            bump(&tc);
            rt::yield_now();
        }
    };
    assert(pw.wait_timeout(time::Duration::from_secs(10)), "the unrelated task finishes behind the burst");
    assert_eq(count(&turns), 1000);
    assert_eq(io::pending_waits(), n as usize);
    for i in 0..n as usize {
        write_one(&pairs.at(i).a);
    }
    assert(wg.wait_timeout(time::Duration::from_secs(30)), "every waiter finishes");
    assert_eq(count(&hits), 2 * n);
    finish();
}
