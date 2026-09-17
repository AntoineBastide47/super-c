// Bounded workloads for the parts of the runtime the primitive lanes do not reach: the timer list, the
// reactor, cancellation, the memory a parked task holds, workers going idle between bursts, the blocking
// pool past its thread limit, and the task-block pool on both sides of its capacity. Every workload has a
// FIXED size (the sweeps vary only the worker count) and validates what it did; a runtime defect met on the
// way is a failed run, never a faster one.

import atomic;
import stdio;
import unistd;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::atomics as atomics;
import std::parallel::arc as arc;
import std::parallel::platform as platform;
import std::parallel::time as time;
import std::parallel::task as task;
import std::parallel::blocking as blocking;
import std::parallel::io as io;
import std::parallel::net as net;
import std::testing::bench as bench;
import std::testing::bench_sys as sys;
import bench::sweep as sweep;

const TIMER_TASKS: i64 = 1000; // sleeping tasks per round
const TIMER_SLEEPS: i64 = 5; // sleeps per task, each 1 ms: the timer list is armed 5000 times a round
const PATTERN_ROUNDS: i32 = 5; // rounds per (pattern, live count) point in the timer_patterns lane
const CONNS: i64 = 64; // client connections in the socket lane
const SOCK_MSGS: i64 = 20; // messages per connection
const SOCK_LEN: usize = 64; // bytes per message
const CANCEL_TASKS: i64 = 1000; // children parked in a sleep when the group is cancelled
const PARKED_TASKS: i64 = 4096; // tasks parked at once in the memory lane
const MEMB_TASKS: i64 = 400000; // short tasks registered with one long-lived source per round
const MEMB_LIVE: i64 = 512; // at most this many of them in flight at once
const MEMB_PARKED: i64 = 1000; // members parked when the source is finally cancelled
const PARK_ROUNDS: i32 = 5; // memory rounds: the figure is stable, the timing is not the point
const BURST_TASKS: i64 = 500; // tasks per burst
const BURSTS: i64 = 20; // bursts per round
const IDLE_NS: i64 = 5000000; // the gap between bursts in the idle lane: long enough for workers to park
const FLOOD: i64 = 256; // blocking calls in flight at once: four times the pool's thread limit
const FLOOD_SLEEP_US: u32 = 2000; // what each blocking call holds its thread for
const COMPUTE_TASKS: i64 = 4; // compute tasks whose progress is measured under the flood
const COMPUTE_CHUNK: i64 = 2000; // burn iterations per progress tick
const BELOW_POOL: i64 = 512; // live tasks under the task-block pool's capacity (1024 shared blocks)
const ABOVE_POOL: i64 = 2048; // live tasks past it: half the blocks are built and released every round
const SETTLE_NS: u64 = 5000000000; // how long a lane waits for its tasks to reach a parked state

// Report a workload that did less than it claims.
fn check(name: str, got: i64, want: i64) {
    if got != want {
        let mut what = String::from_str(name);
        what.push_str(": ");
        what.push_i64(got);
        what.push_str(" of ");
        what.push_i64(want);
        bench::fail(what.as_str());
    }
}

// Wait, bounded, until `want` registered tasks are parked with wait kind `kind`. False when the wait ran
// out: a runtime defect the lane reports.
fn wait_parked(kind: i32, want: usize) bool {
    let deadline = platform::now_ns() + SETTLE_NS;
    let mut snap = Vector::<rt::TaskInfo>::new();
    loop {
        snap.clear();
        rt::task_snapshot(&mut snap);
        let mut n: usize = 0;
        for i in 0..snap.len() {
            if snap.at(i).wait_kind == kind {
                n = n + 1;
            }
        }
        if n >= want {
            return true;
        }
        if platform::now_ns() > deadline {
            return false;
        }
        rt::sleep_ns(100000);
    }
}

// --- timer churn --------------------------------------------------------------------------------------.

// TIMER_TASKS tasks each sleep TIMER_SLEEPS times for a millisecond: every sleep arms the scheduler's
// timer list and every wake disarms it, with a thousand entries on it at once.
fn timers_once() {
    let wg = sync::WaitGroup::new();
    wg.add(TIMER_TASKS);
    let sleeps = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    for _i in 0..TIMER_TASKS {
        let w = wg.clone();
        let s = sleeps.clone();
        launch || {
            let mut n: i64 = 0;
            for _k in 0..TIMER_SLEEPS {
                let t0 = platform::now_ns();
                time::sleep(time::Duration::from_millis(1));
                if platform::now_ns() - t0 >= 1000000 {
                    n = n + 1;
                }
            }
            let _ = s.get().fetch_add(n, atomics::MemoryOrder::Relaxed);
            w.done();
        };
    }
    wg.wait();
    check(
        "timer_churn sleeps of full length",
        sleeps.get().load(atomics::MemoryOrder::Acquire),
        TIMER_TASKS * TIMER_SLEEPS,
    );
}

@bench(log_results = false)
/// Benchmark lane: a thousand tasks arming and disarming timers, swept across workers.
pub fn timer_churn(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    b.set_diag_rounds(0);
    while b.running() {
        sweep::sweep("timer_churn", timers_once);
    }
}

// --- socket readiness -----------------------------------------------------------------------------------.

// Echo one connection until the peer closes; returns the bytes echoed.
@platform(macos | linux)
fn echo(s: &net::TcpStream) i64 {
    let mut buf = Vector::<u8>::with_capacity(SOCK_LEN);
    for _k in 0..SOCK_LEN {
        buf.push(0u8);
    }
    let mut total: i64 = 0;
    loop {
        let n = s.read(buf.index_range_mut(0..SOCK_LEN));
        if n <= 0 {
            break;
        }
        let w = s.write(buf.index_range(0..n as usize));
        if w != n {
            break;
        }
        total = total + n as i64;
    }
    return total;
}

// One client: connect, send SOCK_MSGS messages, read each echo back in full; returns the bytes read back.
@platform(macos | linux)
fn client(port: i32) i64 {
    let mut buf = Vector::<u8>::with_capacity(SOCK_LEN);
    for k in 0..SOCK_LEN {
        buf.push(k as u8);
    }
    let r = net::TcpStream::connect("127.0.0.1", port);
    if r.is_err() {
        return 0;
    }
    let s = r.unwrap();
    let mut total: i64 = 0;
    for _m in 0..SOCK_MSGS {
        if s.write(buf.index_range(0..SOCK_LEN)) != SOCK_LEN as isize {
            break;
        }
        let mut at: usize = 0;
        while at < SOCK_LEN {
            let n = s.read(buf.index_range_mut(at..SOCK_LEN));
            if n <= 0 {
                break;
            }
            at = at + n as usize;
        }
        if at != SOCK_LEN {
            break;
        }
        total = total + SOCK_LEN as i64;
    }
    return total;
}

// CONNS connections, each carrying SOCK_MSGS round trips through the reactor: every read parks the task
// on descriptor readiness and every readiness event wakes one.
@platform(macos | linux)
fn sockets_once() {
    let lr = net::TcpListener::bind("127.0.0.1", 0);
    if lr.is_err() {
        bench::fail("socket_readiness: bind failed");
        return;
    }
    let listener = lr.unwrap();
    let port = listener.port();
    let wg = sync::WaitGroup::new();
    wg.add(CONNS * 2 + 1);
    let echoed = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let received = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let wa = wg.clone();
    let wg2 = wg.clone();
    let e2 = echoed.clone();
    launch || {
        for _c in 0..CONNS {
            switch listener.accept() {
                Ok(stream) => {
                    let w = wg2.clone();
                    let e = e2.clone();
                    launch || {
                        let n = echo(&stream);
                        let _ = e.get().fetch_add(n, atomics::MemoryOrder::Relaxed);
                        w.done();
                    };
                },
                Err(_) => {
                    // The accept failed: the client counts the shortfall, and the echo task it would have
                    // had is released here so the group still completes.
                    wg2.done();
                },
            };
        }
        wa.done();
    };
    for _c in 0..CONNS {
        let w = wg.clone();
        let r = received.clone();
        launch || {
            let n = client(port);
            let _ = r.get().fetch_add(n, atomics::MemoryOrder::Relaxed);
            w.done();
        };
    }
    wg.wait();
    let want = CONNS * SOCK_MSGS * SOCK_LEN as i64;
    check("socket_readiness bytes received", received.get().load(atomics::MemoryOrder::Acquire), want);
    check("socket_readiness bytes echoed", echoed.get().load(atomics::MemoryOrder::Acquire), want);
}

@platform(macos | linux)
@bench
/// Benchmark lane: TCP echo round trips over the reactor.
pub fn socket_readiness(b: &mut bench::Bencher) {
    let want = CONNS * SOCK_MSGS;
    b.each(want);
    b.unit("msg");
    b.set_rounds(50);
    while b.running() {
        sockets_once();
        b.tally(want, want);
    }
    io::shutdown();
}

// --- socket shapes ----------------------------------------------------------------------------------------.
// The same message pattern as the echo lane (bytes 0..SOCK_LEN, so every message sums to MSG_SUM), in the
// shapes that move the reactor differently: readiness already present when the wait is armed, readiness
// that always arrives after the park, traffic in both directions at once, a burst of short connections,
// and an echo under a thousand idle descriptors. Every lane checks bytes and checksums on both ends.

const MSG_SUM: i64 = 2016; // 0 + 1 + ... + 63
const BURST_CONNS: i64 = 100; // connections per round in the burst lane, one round trip each
const IDLE_CONNS: i64 = 1000; // descriptors parked while the idle lane echoes

// Read exactly `n` bytes from `s`, summing them; false if the peer closed first.
@platform(macos | linux)
fn read_exact(s: &net::TcpStream, buf: &mut Vector<u8>, n: usize, sum: &mut i64) bool {
    let mut at: usize = 0;
    while at < n {
        let got = s.read(buf.index_range_mut(at..n));
        if got <= 0 {
            return false;
        }
        at = at + got as usize;
    }
    for k in 0..n {
        *sum = *sum + (*buf.at(k)) as i64;
    }
    return true;
}

// Echo SOCK_MSGS messages, with `delay_ns` of sleep before each read (0: none); the checksum of what
// came in, or -1 on a short connection.
@platform(macos | linux)
fn echo_checked(s: &net::TcpStream, delay_ns: u64) i64 {
    let mut buf = Vector::<u8>::with_capacity(SOCK_LEN);
    buf.resize_default(SOCK_LEN);
    let mut sum: i64 = 0;
    for _m in 0..SOCK_MSGS {
        if delay_ns != 0 {
            rt::sleep_ns(delay_ns as i64);
        }
        if !read_exact(s, &mut buf, SOCK_LEN, &mut sum) {
            return -1;
        }
        if s.write(buf.index_range(0..SOCK_LEN)) != SOCK_LEN as isize {
            return -1;
        }
    }
    return sum;
}

// A client that sends every message before reading any echo (the server's later waits find data already
// there) when `ahead`, or one round trip at a time otherwise; the checksum of the echoes, or -1.
@platform(macos | linux)
fn client_checked(port: i32, ahead: bool) i64 {
    let mut msg = Vector::<u8>::with_capacity(SOCK_LEN);
    for k in 0..SOCK_LEN {
        msg.push(k as u8);
    }
    let r = net::TcpStream::connect("127.0.0.1", port);
    if r.is_err() {
        return -1;
    }
    let s = r.unwrap();
    let mut buf = Vector::<u8>::with_capacity(SOCK_LEN);
    buf.resize_default(SOCK_LEN);
    let mut sum: i64 = 0;
    if ahead {
        for _m in 0..SOCK_MSGS {
            if s.write(msg.index_range(0..SOCK_LEN)) != SOCK_LEN as isize {
                return -1;
            }
        }
        for _m in 0..SOCK_MSGS {
            if !read_exact(&s, &mut buf, SOCK_LEN, &mut sum) {
                return -1;
            }
        }
        return sum;
    }
    for _m in 0..SOCK_MSGS {
        if s.write(msg.index_range(0..SOCK_LEN)) != SOCK_LEN as isize {
            return -1;
        }
        if !read_exact(&s, &mut buf, SOCK_LEN, &mut sum) {
            return -1;
        }
    }
    return sum;
}

// `conns` connections through `listener`: servers echo (sleeping `delay_ns` before each read), clients
// send `ahead` or in lockstep; both checksums must total conns * SOCK_MSGS * MSG_SUM.
@platform(macos | linux)
fn shape_once(name: str, listener: net::TcpListener, conns: i64, delay_ns: u64, ahead: bool) {
    let port = listener.port();
    let wg = sync::WaitGroup::new();
    wg.add(conns * 2 + 1);
    let echoed = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let received = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let wa = wg.clone();
    let wg2 = wg.clone();
    let e2 = echoed.clone();
    launch || {
        // A deadline on every accept: a client whose connect failed (ephemeral ports exhausted by an
        // earlier run) then fails the round's check instead of parking this task for ever.
        for _c in 0..conns {
            switch listener.accept_until(time::deadline_in(time::Duration::from_secs(10))) {
                Ok(stream) => {
                    let w = wg2.clone();
                    let e = e2.clone();
                    launch || {
                        let n = echo_checked(&stream, delay_ns);
                        let _ = e.get().fetch_add(n, atomics::MemoryOrder::Relaxed);
                        w.done();
                    };
                },
                Err(_) => {
                    wg2.done();
                },
            };
        }
        wa.done();
    };
    for _c in 0..conns {
        let w = wg.clone();
        let r = received.clone();
        launch || {
            let n = client_checked(port, ahead);
            let _ = r.get().fetch_add(n, atomics::MemoryOrder::Relaxed);
            w.done();
        };
    }
    wg.wait();
    let want = conns * SOCK_MSGS * MSG_SUM;
    check(name, received.get().load(atomics::MemoryOrder::Acquire), want);
    check(name, echoed.get().load(atomics::MemoryOrder::Acquire), want);
}

@platform(macos | linux)
fn ready_now_once() {
    let lr = net::TcpListener::bind("127.0.0.1", 0);
    if lr.is_err() {
        bench::fail("socket_ready_now: bind failed");
        return;
    }
    let listener = lr.unwrap();
    shape_once("socket_ready_now checksum", listener, CONNS, 0, true);
}

@platform(macos | linux)
@bench
/// Benchmark lane: echo where the server's waits mostly find data already present.
pub fn socket_ready_now(b: &mut bench::Bencher) {
    let want = CONNS * SOCK_MSGS;
    b.each(want);
    b.unit("msg");
    b.set_rounds(50);
    while b.running() {
        ready_now_once();
        b.tally(want, want);
    }
    io::shutdown();
}

@platform(macos | linux)
fn delayed_once() {
    let lr = net::TcpListener::bind("127.0.0.1", 0);
    if lr.is_err() {
        bench::fail("socket_delayed: bind failed");
        return;
    }
    let listener = lr.unwrap();
    shape_once("socket_delayed checksum", listener, CONNS, 200000, false);
}

@platform(macos | linux)
@bench
/// Benchmark lane: echo where readiness always arrives after the park (the server sleeps before each read).
pub fn socket_delayed(b: &mut bench::Bencher) {
    let want = CONNS * SOCK_MSGS;
    b.each(want);
    b.unit("msg");
    b.set_rounds(20);
    while b.running() {
        delayed_once();
        b.tally(want, want);
    }
    io::shutdown();
}

// One end of a bidirectional connection: a writer task sends SOCK_MSGS messages while a reader task reads
// SOCK_MSGS; the checksum read is added to `sum`.
@platform(macos | linux)
fn bidir_end(s: &net::TcpStream, sum: &arc::Arc<atomics::Atomic<i64>>, wg: &sync::WaitGroup) {
    let mut msg = Vector::<u8>::with_capacity(SOCK_LEN);
    for k in 0..SOCK_LEN {
        msg.push(k as u8);
    }
    for _m in 0..SOCK_MSGS {
        if s.write(msg.index_range(0..SOCK_LEN)) != SOCK_LEN as isize {
            break;
        }
    }
    let mut buf = Vector::<u8>::with_capacity(SOCK_LEN);
    buf.resize_default(SOCK_LEN);
    let mut got: i64 = 0;
    for _m in 0..SOCK_MSGS {
        if !read_exact(s, &mut buf, SOCK_LEN, &mut got) {
            break;
        }
    }
    let _ = sum.get().fetch_add(got, atomics::MemoryOrder::Relaxed);
    wg.done();
}

@platform(macos | linux)
fn bidir_once() {
    let lr = net::TcpListener::bind("127.0.0.1", 0);
    if lr.is_err() {
        bench::fail("socket_bidir: bind failed");
        return;
    }
    let listener = lr.unwrap();
    let port = listener.port();
    let wg = sync::WaitGroup::new();
    wg.add(CONNS * 2 + 1);
    let sum = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let wa = wg.clone();
    let wg2 = wg.clone();
    let s2 = sum.clone();
    launch || {
        for _c in 0..CONNS {
            switch listener.accept_until(time::deadline_in(time::Duration::from_secs(10))) {
                Ok(stream) => {
                    let w = wg2.clone();
                    let s = s2.clone();
                    launch || {
                        bidir_end(&stream, &s, &w);
                    };
                },
                Err(_) => {
                    wg2.done();
                },
            };
        }
        wa.done();
    };
    for _c in 0..CONNS {
        let w = wg.clone();
        let s = sum.clone();
        launch || {
            switch net::TcpStream::connect("127.0.0.1", port) {
                Ok(stream) => {
                    bidir_end(&stream, &s, &w);
                },
                Err(_) => {
                    w.done();
                },
            };
        };
    }
    wg.wait();
    check("socket_bidir checksum", sum.get().load(atomics::MemoryOrder::Acquire), 2 * CONNS * SOCK_MSGS * MSG_SUM);
}

@platform(macos | linux)
@bench
/// Benchmark lane: both ends of every connection send and receive at once.
pub fn socket_bidir(b: &mut bench::Bencher) {
    let want = 2 * CONNS * SOCK_MSGS;
    b.each(want);
    b.unit("msg");
    b.set_rounds(50);
    while b.running() {
        bidir_once();
        b.tally(want, want);
    }
    io::shutdown();
}

// A burst of short connections: BURST_CONNS connects, each one message and its echo, then closed.
@platform(macos | linux)
fn conn_burst_once() {
    let lr = net::TcpListener::bind("127.0.0.1", 0);
    if lr.is_err() {
        bench::fail("socket_burst: bind failed");
        return;
    }
    let listener = lr.unwrap();
    let port = listener.port();
    let wg = sync::WaitGroup::new();
    wg.add(BURST_CONNS * 2 + 1);
    let sum = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let wa = wg.clone();
    let wg2 = wg.clone();
    launch || {
        for _c in 0..BURST_CONNS {
            switch listener.accept_until(time::deadline_in(time::Duration::from_secs(10))) {
                Ok(stream) => {
                    let w = wg2.clone();
                    launch || {
                        let mut buf = Vector::<u8>::with_capacity(SOCK_LEN);
                        buf.resize_default(SOCK_LEN);
                        let mut got: i64 = 0;
                        if read_exact(&stream, &mut buf, SOCK_LEN, &mut got) {
                            let _ = stream.write(buf.index_range(0..SOCK_LEN));
                        }
                        w.done();
                    };
                },
                Err(_) => {
                    wg2.done();
                },
            };
        }
        wa.done();
    };
    for _c in 0..BURST_CONNS {
        let w = wg.clone();
        let s = sum.clone();
        launch || {
            let mut msg = Vector::<u8>::with_capacity(SOCK_LEN);
            for k in 0..SOCK_LEN {
                msg.push(k as u8);
            }
            switch net::TcpStream::connect("127.0.0.1", port) {
                Ok(stream) => {
                    let mut got: i64 = 0;
                    if stream.write(msg.index_range(0..SOCK_LEN)) == SOCK_LEN as isize {
                        let mut buf = Vector::<u8>::with_capacity(SOCK_LEN);
                        buf.resize_default(SOCK_LEN);
                        let _ = read_exact(&stream, &mut buf, SOCK_LEN, &mut got);
                    }
                    let _ = s.get().fetch_add(got, atomics::MemoryOrder::Relaxed);
                },
                Err(_) => {},
            };
            w.done();
        };
    }
    wg.wait();
    check("socket_burst checksum", sum.get().load(atomics::MemoryOrder::Acquire), BURST_CONNS * MSG_SUM);
}

@platform(macos | linux)
@bench
/// Benchmark lane: a burst of short connections, one round trip each, through accept and connect.
pub fn socket_burst(b: &mut bench::Bencher) {
    b.each(BURST_CONNS);
    b.unit("conn");
    b.set_rounds(20);
    while b.running() {
        conn_burst_once();
        b.tally(BURST_CONNS, BURST_CONNS);
    }
    io::shutdown();
}

// The echo lane under IDLE_CONNS idle connections, each parked in a read until the lane ends. The idle
// descriptors are set up once, outside the timed rounds (a thousand connections per round would exhaust
// the ephemeral ports), and their wake at the end is timed on its own.
@platform(macos | linux)
struct Idle {
    pub listener: net::TcpListener,
    pub peers: Vector<net::TcpStream>,
    pub parked: sync::WaitGroup,
    pub woke: arc::Arc<atomics::Atomic<i64>>,
}

@platform(macos | linux)
fn idle_setup() Option<Idle> {
    let lr = net::TcpListener::bind("127.0.0.1", 0);
    if lr.is_err() {
        bench::fail("socket_idle_many: bind failed");
        return Option::<Idle>::None;
    }
    let listener = lr.unwrap();
    let port = listener.port();
    let mut peers = Vector::<net::TcpStream>::new();
    let parked = sync::WaitGroup::new();
    parked.add(IDLE_CONNS);
    let woke = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    for _i in 0..IDLE_CONNS {
        switch net::TcpStream::connect("127.0.0.1", port) {
            Ok(c) => {
                peers.push(c);
            },
            Err(_) => {
                bench::fail("socket_idle_many: connect failed");
                return Option::<Idle>::None;
            },
        };
        switch listener.accept_until(time::deadline_in(time::Duration::from_secs(10))) {
            Ok(s) => {
                let w = parked.clone();
                let k = woke.clone();
                launch || {
                    let mut buf = Vector::<u8>::with_capacity(8);
                    buf.resize_default(8);
                    let cap: usize = 8;
                    if s.read(buf.index_range_mut(0..cap)) == 1 {
                        let _ = k.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
                    }
                    w.done();
                };
            },
            Err(_) => {
                bench::fail("socket_idle_many: accept failed");
                return Option::<Idle>::None;
            },
        };
    }
    if !wait_parked(rt::WK_IO, IDLE_CONNS as usize) {
        bench::fail("socket_idle_many: the idle readers did not all park");
        return Option::<Idle>::None;
    }
    return Option::<Idle>::Some(Idle { listener: listener, peers: peers, parked: parked, woke: woke });
}

// Wake every idle reader with one byte and count them in; the batch of a thousand wakes is timed.
@platform(macos | linux)
fn idle_wake(idle: &Idle) {
    let byte: [u8; 1] = [1u8];
    for i in 0..IDLE_CONNS as usize {
        let _ = idle.peers.at(i).write(byte);
    }
    idle.parked.wait();
    check("socket_idle_many wakes", idle.woke.get().load(atomics::MemoryOrder::Acquire), IDLE_CONNS);
}

@platform(macos | linux)
@bench
/// Benchmark lane: the echo round trips under a thousand idle parked descriptors, then their wake.
pub fn socket_idle_many(b: &mut bench::Bencher) {
    let want = CONNS * SOCK_MSGS;
    b.each(want);
    b.unit("msg");
    b.set_rounds(20);
    let setup = idle_setup();
    if setup.is_none() {
        return;
    }
    let idle = setup.unwrap();
    while b.running() {
        let lr = net::TcpListener::bind("127.0.0.1", 0);
        if lr.is_err() {
            bench::fail("socket_idle_many: bind failed");
            return;
        }
        shape_once("socket_idle_many checksum", lr.unwrap(), CONNS, 0, false);
        b.tally(want, want);
    }
    idle_wake(&idle);
    io::shutdown();
}

// --- timer patterns -------------------------------------------------------------------------------------.

// One point of the timer_patterns lane: `live` tasks arm one timed wait each in the given pattern, all
// armed at once, and the round is the whole spawn, arm, expiry (or early notify) and completion. Lateness
// is what a sleeper observes past its own deadline. Patterns: 0 increasing deadlines (each task later than
// the previous), 1 decreasing, 2 equal, 3 pseudo-random, 4 cancelled (a wait on the task's own condvar,
// notified before its deadline: arm plus removal, no expiry). The waits park on the timer heap alone (a
// sleep, or a condvar nobody else waits on), so the round prices the heap and not a shared wait queue.
fn pattern_once(pattern: i64, live: i64, late: &mut Vector<f64>) {
    let wg = sync::WaitGroup::new();
    wg.add(live);
    let lat = arc::Arc::<sync::Mutex<Vector<f64>>>::new(sync::Mutex::<Vector<f64>>::new(Vector::<f64>::new()));
    let mut cvs = Vector::<arc::Arc<sync::Condvar>>::new();
    let mut locks = Vector::<arc::Arc<sync::Mutex<i64>>>::new();
    let base = platform::now_ns() + 2000000; // the earliest deadline: 2 ms out, past the spawn burst
    for i in 0..live {
        let w = wg.clone();
        let l = lat.clone();
        // Deadlines spread over 8 ms in the pattern's order; equal keeps one; random scatters.
        let off: u64 = switch pattern {
            0 => i as u64 * 8000000 / live as u64,
            1 => (live - 1 - i) as u64 * 8000000 / live as u64,
            2 => 4000000u64,
            3 => (i as u64 * 2654435761 >> 5) % 8000000,
            _ => 200000000u64, // cancelled: far away, never reached
        };
        if pattern == 4 {
            let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
            let c = arc::Arc::<sync::Condvar>::new(sync::Condvar::new());
            locks.push(m.clone());
            cvs.push(c.clone());
            launch || {
                defer w.done();
                let g = m.get().lock();
                while *g.get() == 0 {
                    let _ = c.get().wait_until(&g, base + off);
                }
            };
        } else {
            launch || {
                defer w.done();
                let dl = base + off;
                let now = platform::now_ns();
                if dl > now {
                    rt::sleep_ns((dl - now) as i64);
                }
                let woke = platform::now_ns();
                let mut v = l.get().lock();
                v.get_mut().push((woke - dl) as f64 / 1000.0);
            };
        }
    }
    if pattern == 4 {
        if !wait_parked(rt::WK_CONDVAR, live as usize) {
            bench::fail("timer_patterns: the waiters did not all park");
        }
        for i in 0..cvs.len() {
            {
                let mut g = locks.at(i).get().lock();
                *g.get_mut() = 1;
            }
            cvs.at(i).get().notify_one();
        }
    }
    wg.wait();
    let v = lat.get().lock();
    for i in 0..v.len() {
        late.push(*v.at(i));
    }
}

/// Benchmark lane: one timed wait per task in five deadline patterns, at three live counts. Each row is
/// the per-timer cost of the whole round (spawn, arm, expiry or removal, completion) and the lateness
/// sleepers saw past their deadlines. Worker counts are swept by `timer_churn`; this lane keeps the
/// default pool.
@bench(log_results = false)
pub fn timer_patterns(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    b.set_diag_rounds(0);
    let names: [str; 5] = ["increasing", "decreasing", "equal", "random", "cancelled"];
    let lives: [i64; 3] = [100, 1000, 10000];
    while b.running() {
        unsafe stdio::printf("\n  timer_patterns: one timed wait per task\n".ptr() as *const char);
        unsafe stdio::printf(
            "    %-11s %7s %11s %11s %11s %10s\n".ptr() as *const char,
            "pattern".ptr() as *const char,
            "live".ptr() as *const char,
            "median ms".ptr() as *const char,
            "ns/timer".ptr() as *const char,
            "late p99 us".ptr() as *const char,
            "Mcyc".ptr() as *const char,
        );
        for pi in 0..5i64 {
            for li in 0..3usize {
                let live = unsafe lives[li];
                let mut ms = Vector::<f64>::new();
                let mut cyc = Vector::<f64>::new();
                let mut late = Vector::<f64>::new();
                pattern_once(pi, live, &mut late);
                late.clear();
                for _r in 0..PATTERN_ROUNDS {
                    let c0 = unsafe sys::sc_bs_cycles();
                    let t0 = platform::now_ns();
                    pattern_once(pi, live, &mut late);
                    let t1 = platform::now_ns();
                    let c1 = unsafe sys::sc_bs_cycles();
                    ms.push((t1 - t0) as f64 / 1000000.0);
                    cyc.push((c1 - c0) as f64 / 1000000.0);
                }
                let sm = bench::summarize(&mut ms);
                let sc = bench::summarize(&mut cyc);
                let sl = if late.len() != 0 {
                    bench::summarize(&mut late);
                } else {
                    bench::summarize(&mut ms); // the cancelled pattern has no expiry: the column is dashed
                };
                let mut p99: f64 = -1.0;
                if late.len() != 0 {
                    p99 = sl.p99;
                }
                unsafe stdio::printf(
                    "    %-11s %7lld %11.3f %11.1f %11.1f %10.2f\n".ptr() as *const char,
                    (unsafe names[pi as usize].ptr()) as *const char,
                    live,
                    sm.median,
                    sm.median * 1000000.0 / live as f64,
                    p99,
                    sc.median,
                );
            }
        }
        b.tally(1, 1);
    }
}

// --- cancellation ---------------------------------------------------------------------------------------.

// CANCEL_TASKS children parked in a cancellable sleep, then cancelled as a group: the measured part is the
// cancel request through every child's unwinding to the join. Setup (spawn and park) is excluded.
fn cancel_once(b: &mut bench::Bencher) i64 {
    b.pause();
    let mut g = task::TaskGroup::new();
    for _i in 0..CANCEL_TASKS {
        g.spawn(
            || {
                time::sleep(time::Duration::from_secs(60));
            },
        );
    }
    if !wait_parked(rt::WK_SLEEP, CANCEL_TASKS as usize) {
        bench::fail("cancellation: the children did not all reach their sleep");
    }
    b.resume();
    g.cancel();
    let rep = g.join();
    return rep.cancelled as i64;
}

@bench
/// Benchmark lane: cancelling a thousand parked children and joining them.
pub fn cancellation(b: &mut bench::Bencher) {
    b.each(CANCEL_TASKS);
    b.unit("task");
    b.set_rounds(50);
    while b.running() {
        let cancelled = cancel_once(b);
        b.tally(CANCEL_TASKS, cancelled);
    }
}

// --- cancellation membership --------------------------------------------------------------------------.

/// Benchmark lane: one long-lived source, MEMB_TASKS short tasks per round registered with it in waves of
/// MEMB_LIVE, so the live membership never exceeds the wave while the history grows by a round each time.
/// The per-task figure is spawn plus registration plus completion. After the rounds, MEMB_PARKED members
/// park and the source cancels them: the note reports that cancel's time and what the source still holds,
/// which must follow the live members, not the history.
@bench
pub fn cancel_membership(b: &mut bench::Bencher) {
    b.each(MEMB_TASKS);
    b.unit("task");
    b.set_rounds(5);
    let (src, tok) = task::CancelSource::new();
    let mut history: i64 = 0;
    while b.running() {
        let base = rt::completed_tasks();
        let mut left = MEMB_TASKS;
        while left > 0 {
            let n = if left < MEMB_LIVE {
                left;
            } else {
                MEMB_LIVE;
            };
            let wg = sync::WaitGroup::new();
            wg.add(n);
            for _i in 0..n {
                let w = wg.clone();
                let t = tok.clone();
                launch || {
                    t.bind_current();
                    w.done();
                };
            }
            wg.wait();
            left = left - n;
        }
        history = history + MEMB_TASKS;
        b.tally(MEMB_TASKS, (rt::completed_tasks() - base) as i64);
    }
    // The cancel after the history: members parked in a sleep, then one request sweep.
    let wg = sync::WaitGroup::new();
    wg.add(MEMB_PARKED);
    for _i in 0..MEMB_PARKED {
        let w = wg.clone();
        let t = tok.clone();
        launch || {
            defer w.done(); // the cancelled sleep never returns: the report must ride the unwind
            t.bind_current();
            time::sleep(time::Duration::from_secs(60));
        };
    }
    if !wait_parked(rt::WK_SLEEP, MEMB_PARKED as usize) {
        bench::fail("cancel_membership: the members did not all reach their sleep");
    }
    let live = src.members();
    let t0 = platform::now_ns();
    src.cancel(rt::CR_USER);
    let t1 = platform::now_ns();
    wg.wait();
    let mut note = String::from_str("cancel of ");
    note.push_i64(live as i64);
    note.push_str(" live members after ");
    note.push_i64(history);
    note.push_str(" registrations: ");
    note.push_f64_prec((t1 - t0) as f64 / 1000.0, 1);
    note.push_str(" us; members held after: ");
    note.push_i64(src.members() as i64);
    b.note(note.as_str());
}

// --- parked-task memory ---------------------------------------------------------------------------------.

/// Benchmark lane: what a parked task holds. PARKED_TASKS tasks park on a channel at once; the resident
/// set, the mapped stacks and the pool are read while they are parked, and per-task figures go in the
/// note. The timed round is the whole spawn, park, release and completion.
@bench
pub fn parked_task_memory(b: &mut bench::Bencher) {
    b.each(PARKED_TASKS);
    b.unit("task");
    b.set_rounds(PARK_ROUNDS);
    let mut rss_per_task: f64 = 0.0;
    let mut stack_per_task: f64 = 0.0;
    let mut first = true;
    while b.running() {
        let rss0 = unsafe sys::sc_bs_rss_now();
        let stk0 = platform::stack_bytes();
        let ch = chan::Channel::<i64>::unbounded();
        let tx = ch.sender();
        let wg = sync::WaitGroup::new();
        wg.add(PARKED_TASKS);
        let woke = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
        for _i in 0..PARKED_TASKS {
            let rx = ch.receiver();
            let w = wg.clone();
            let k = woke.clone();
            launch || {
                switch rx.recv() {
                    Some(_v) => {},
                    None => {
                        let _ = k.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
                    },
                };
                w.done();
            };
        }
        if !wait_parked(rt::WK_CHANNEL_RECV, PARKED_TASKS as usize) {
            bench::fail("parked_task_memory: the tasks did not all park");
        }
        let rss1 = unsafe sys::sc_bs_rss_now();
        let stk1 = platform::stack_bytes();
        tx.close();
        wg.wait();
        b.tally(PARKED_TASKS, woke.get().load(atomics::MemoryOrder::Acquire));
        if first {
            // The first round builds every block; later rounds reuse what the pool kept, so only the
            // first delta is the cost of one parked task.
            first = false;
            rss_per_task = (rss1 - rss0) as f64 / PARKED_TASKS as f64;
            stack_per_task = (stk1 - stk0) as f64 / PARKED_TASKS as f64;
        }
    }
    let mut note = String::from_str("per parked task (first round): rss ");
    if unsafe sys::sc_bs_rss_now() >= 0 {
        note.push_f64_prec(rss_per_task / 1024.0, 1);
        note.push_str(" KiB resident");
    } else {
        note.push_str("unavailable");
    }
    note.push_str(", ");
    note.push_f64_prec(stack_per_task / 1024.0, 1);
    note.push_str(" KiB mapped");
    b.note(note.as_str());
}

// --- burst / idle cycles --------------------------------------------------------------------------------.

/// Benchmark lane: BURSTS bursts of BURST_TASKS tasks with an idle gap between them, long enough for
/// every worker to park, so each burst pays the wake-up. The gap is excluded from the round, so the
/// difference to `burst_nogap` is the wake-up cost alone.
@bench
pub fn burst_idle(b: &mut bench::Bencher) {
    let total = BURSTS * BURST_TASKS;
    b.each(total);
    b.unit("task");
    b.set_rounds(30);
    while b.running() {
        let mut ok: i64 = 0;
        for _k in 0..BURSTS {
            b.pause();
            rt::sleep_ns(IDLE_NS);
            b.resume();
            ok = ok + burst_once();
        }
        b.tally(total, ok);
    }
}

// One burst: BURST_TASKS tasks spawned and awaited; returns how many ran.
fn burst_once() i64 {
    let wg = sync::WaitGroup::new();
    wg.add(BURST_TASKS);
    let done = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    for _i in 0..BURST_TASKS {
        let w = wg.clone();
        let d = done.clone();
        launch || {
            let _ = d.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            w.done();
        };
    }
    wg.wait();
    return done.get().load(atomics::MemoryOrder::Acquire);
}

/// Benchmark lane: the same bursts back to back, workers never idle.
@bench
pub fn burst_nogap(b: &mut bench::Bencher) {
    let total = BURSTS * BURST_TASKS;
    b.each(total);
    b.unit("task");
    b.set_rounds(30);
    while b.running() {
        let mut ok: i64 = 0;
        for _k in 0..BURSTS {
            ok = ok + burst_once();
        }
        b.tally(total, ok);
    }
}

// --- blocking saturation --------------------------------------------------------------------------------.

// Progress counter for the compute tasks running beside the flood, and the flag that stops them.
static mut G_PROGRESS: i64 = 0;
static mut G_STOP: i32 = 0;

fn compute_progress_task() {
    let mut chunks: i64 = 0;
    while atomic::load_i32(&mut unsafe G_STOP, 1) == 0 {
        bench::black_box(bench::burn(COMPUTE_CHUNK));
        chunks = chunks + 1;
        rt::yield_now();
    }
    let _ = atomic::add_i64(&mut unsafe G_PROGRESS, chunks, 0);
}

// Run COMPUTE_TASKS compute tasks until `stop` is raised by the caller, and return the chunks they completed
// per millisecond of the window.
type LatSink = arc::Arc<sync::Mutex<Vector<f64>>>;

fn compute_window(flood: bool, lat: &LatSink) f64 {
    atomic::store_i32(&mut unsafe G_STOP, 0, 2);
    atomic::store_i64(&mut unsafe G_PROGRESS, 0, 2);
    let wg = sync::WaitGroup::new();
    wg.add(COMPUTE_TASKS);
    for _i in 0..COMPUTE_TASKS {
        let w = wg.clone();
        launch || {
            compute_progress_task();
            w.done();
        };
    }
    let t0 = platform::now_ns();
    let mut ok: i64 = 0;
    if flood {
        ok = flood_once(lat);
    } else {
        rt::sleep_ns(20000000);
    }
    let dt = (platform::now_ns() - t0) as f64 / 1000000.0;
    atomic::store_i32(&mut unsafe G_STOP, 1, 2);
    wg.wait();
    if flood {
        check("blocking_saturation calls returned their id", ok, FLOOD);
    }
    return atomic::load_i64(&mut unsafe G_PROGRESS, 1) as f64 / dt;
}

// FLOOD blocking calls at once, four times the pool's thread limit, each holding its thread for
// FLOOD_SLEEP_US; returns how many came back with their own id, and appends each call's latency in
// microseconds (queue wait plus the hold) to `lat`.
fn flood_once(lat: &LatSink) i64 {
    let wg = sync::WaitGroup::new();
    wg.add(FLOOD);
    let ok = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    for i in 0..FLOOD {
        let w = wg.clone();
        let o = ok.clone();
        let k = lat.clone();
        let id = i;
        launch || {
            let t0 = platform::now_ns();
            let got = blocking::call(
                fn() i64 {
                    let _ = unsafe unistd::usleep(FLOOD_SLEEP_US);
                    return id;
                },
            );
            let us = (platform::now_ns() - t0) as f64 / 1000.0;
            if got == id {
                let _ = o.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            }
            {
                let mut g = k.get().lock();
                g.get_mut().push(us);
            }
            w.done();
        };
    }
    wg.wait();
    return ok.get().load(atomics::MemoryOrder::Acquire);
}

/// Benchmark lane: FLOOD blocking calls against a pool of `blocking::MAX_THREADS` threads, with compute
/// tasks running beside them. The round is the flood; the note is how much of their unloaded progress the
/// compute tasks kept while it ran.
@bench
pub fn blocking_saturation(b: &mut bench::Bencher) {
    b.each(FLOOD);
    b.unit("call");
    b.set_rounds(30);
    let lat = arc::Arc::<sync::Mutex<Vector<f64>>>::new(
        sync::Mutex::<Vector<f64>>::new(Vector::<f64>::with_capacity(40 * FLOOD as usize)),
    );
    let unloaded = compute_window(false, &lat);
    let mut shares = Vector::<f64>::new();
    while b.running() {
        let under = compute_window(true, &lat);
        shares.push(under / unloaded * 100.0);
        b.tally(FLOOD, FLOOD);
    }
    let sm = bench::summarize(&mut shares);
    let mut note = String::from_str("compute progress under the flood: median ");
    note.push_f64_prec(sm.median, 1);
    note.push_str("% of unloaded (");
    note.push_f64_prec(unloaded, 1);
    note.push_str(" chunks/ms); limit ");
    note.push_u64(blocking::MAX_THREADS as u64);
    note.push_str(" threads for ");
    note.push_i64(FLOOD);
    note.push_str(" calls; peak ");
    let st = blocking::stats();
    note.push_u64(st.peak_threads as u64);
    note.push_str(" threads, peak ");
    note.push_u64(st.peak_queued as u64);
    note.push_str(" queued, ");
    note.push_u64(st.admit_waits as u64);
    note.push_str(" admission waits");
    b.note(note.as_str());
    let mut g = lat.get().lock();
    let t = bench::dist_text("call latency", "us", g.get_mut());
    b.note_more(t.as_str());
}

// --- task counts on both sides of the block pool --------------------------------------------------------.

// `n` tasks alive at once, every one parked on a barrier until the launcher joins it; the round is spawn,
// park, release and completion of all of them. Below the pool's capacity every block is recycled between
// rounds; above it, the excess is built (mmap, guard page) and released (munmap) every round.
fn live_once(n: i64) i64 {
    let bar = sync::Barrier::new(n + 1);
    let wg = sync::WaitGroup::new();
    wg.add(n);
    let passed = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    for _i in 0..n {
        let bb = bar.clone();
        let w = wg.clone();
        let p = passed.clone();
        launch || {
            let _ = bb.wait();
            let _ = p.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            w.done();
        };
    }
    let _ = bar.wait();
    wg.wait();
    return passed.get().load(atomics::MemoryOrder::Acquire);
}

fn live_lane(b: &mut bench::Bencher, n: i64) {
    b.each(n);
    b.unit("task");
    b.set_rounds(50);
    while b.running() {
        let ok = live_once(n);
        b.tally(n, ok);
    }
    let mut note = String::from_str("stacks mapped after: ");
    note.push_f64_prec(platform::stack_bytes() as f64 / 1048576.0, 1);
    note.push_str(" MiB");
    b.note(note.as_str());
}

@bench
/// Benchmark lane: 512 tasks alive at once, within the task-block pool.
pub fn live_below_pool(b: &mut bench::Bencher) {
    live_lane(b, BELOW_POOL);
}

@bench
/// Benchmark lane: 2048 tasks alive at once, past the task-block pool.
pub fn live_above_pool(b: &mut bench::Bencher) {
    live_lane(b, ABOVE_POOL);
}
