// Reactor race exerciser for the ThreadSanitizer lane (see check.sh): the shapes that move the reactor's
// ownership boundaries hardest. Readiness against deadlines round after round (the event batch against the
// timer's claim and the disarm that follows), cancellation landing before, during and after the arm's
// publication, several waiters in one direction and in both on one socket, descriptor numbers closed and
// reused under stale waits, sockets closed under parked readers and writers, and shutdown while waits are pending
// and events are in flight. Every wait must settle, every task must end, and any TSan report is a hole in
// the reclamation argument at the top of std/parallel/io.spc.

import sc_io;
import std::parallel::runtime as rt;
import std::parallel::io as io;
import std::parallel::net as net;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::arc as arc;
import std::parallel::atomics as atomics;
import std::parallel::platform as platform;
import std::parallel::time as time;

struct Pair {
    pub a: net::TcpStream,
    pub b: net::TcpStream,
}

fn pair(l: &net::TcpListener) Pair {
    let a = net::TcpStream::connect("127.0.0.1", l.port()).unwrap();
    let b = l.accept().unwrap();
    return Pair { a: a, b: b };
}

fn write_one(s: &net::TcpStream) {
    let msg: [u8; 1] = [7u8];
    let _ = s.write(msg);
}

fn drain(fd: i32) {
    let mut buf = Vector::<u8>::new();
    buf.resize_default(256);
    let cap: usize = 256;
    loop {
        let n = io::read(fd, buf.index_range_mut(0..cap));
        if n < 256 {
            break;
        }
    }
}

// Readiness against the deadline on every round, from several tasks on one socket at once.
fn event_vs_deadline(l: &net::TcpListener, rounds: i64) {
    let p = pair(l);
    let fd = p.b.fd;
    let wg = sync::WaitGroup::new();
    wg.add(3);
    let done = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    for _k in 0..3 {
        let w = wg.clone();
        let d = done.clone();
        launch || {
            defer w.done();
            let mut buf = Vector::<u8>::new();
            buf.resize_default(64);
            let cap: usize = 64;
            for _r in 0..rounds {
                if io::wait_until(fd, false, time::deadline_in(time::Duration::from_micros(200))) {
                    // Three tasks race for one byte: a non-blocking read, so a loser does not park.
                    let sl = buf.index_range_mut(0..cap);
                    let _ = unsafe sc_io::sc_io_read(fd, sl.ptr, cap);
                }
                let _ = d.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            }
        };
    }
    for _r in 0..rounds {
        time::sleep(time::Duration::from_micros(200));
        write_one(&p.a);
    }
    wg.wait();
    if done.get().load(atomics::MemoryOrder::Acquire) != 3 * rounds {
        panic("io_hunt: a wait did not settle");
    }
}

// Cancellation before, during and after the arm's publication, with data racing it every third round.
fn cancel_storm(l: &net::TcpListener, rounds: i64) {
    let p = pair(l);
    let fd = p.b.fd;
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    for r in 0..rounds {
        let wg = sync::WaitGroup::new();
        wg.add(1);
        let w = wg.clone();
        let tx = ktx.clone();
        launch || {
            defer w.done();
            let _ = tx.send(rt::current_key());
            let _ = io::wait_until(fd, false, 0);
        };
        let key = krx.recv().unwrap();
        let spin_until = platform::now_ns() + r as u64 % 7 * 10000;
        while platform::now_ns() < spin_until {
            rt::yield_now();
        }
        if r % 3 == 0 {
            write_one(&p.a);
        }
        let _ = rt::request_cancel(key, rt::CR_USER);
        wg.wait();
    }
    drain(fd);
}

// Both directions and several waiters per direction on one socket, woken by data and by writability.
fn many_waiters(l: &net::TcpListener, rounds: i64) {
    let p = pair(l);
    let fd = p.b.fd;
    for _r in 0..rounds {
        let wg = sync::WaitGroup::new();
        wg.add(6);
        for k in 0..6 {
            let w = wg.clone();
            launch || {
                defer w.done();
                let _ = io::wait_until(fd, k % 2 == 1, time::deadline_in(time::Duration::from_secs(5)));
            };
        }
        time::sleep(time::Duration::from_micros(500));
        write_one(&p.a);
        wg.wait();
        drain(fd);
    }
}

// Descriptor numbers closed and reused under timed waits, round after round.
fn reuse_storm(l: &net::TcpListener, rounds: i64) {
    for _r in 0..rounds {
        let mut p = pair(l);
        let fd = p.b.fd;
        let wg = sync::WaitGroup::new();
        wg.add(1);
        let w = wg.clone();
        launch || {
            defer w.done();
            let _ = io::wait_until(fd, false, time::deadline_in(time::Duration::from_millis(2)));
        };
        time::sleep(time::Duration::from_micros(300));
        p.b.close();
        p.a.close();
        let q = pair(l);
        let fd2 = q.b.fd;
        wg.add(1);
        let w2 = wg.clone();
        launch || {
            defer w2.done();
            let _ = io::wait_until(fd2, false, time::deadline_in(time::Duration::from_secs(5)));
        };
        time::sleep(time::Duration::from_millis(3));
        write_one(&q.a);
        wg.wait();
    }
}

// Shutdown with waits pending and events in flight, then a fresh reactor for the next round.
fn shutdown_storm(l: &net::TcpListener, rounds: i64) {
    for _r in 0..rounds {
        let mut pairs = Vector::<Pair>::new();
        for _i in 0..8 {
            pairs.push(pair(l));
        }
        let wg = sync::WaitGroup::new();
        wg.add(8);
        for i in 0..8usize {
            let fd = pairs.at(i).b.fd;
            let w = wg.clone();
            launch || {
                defer w.done();
                let _ = io::wait_until(fd, false, time::deadline_in(time::Duration::from_secs(5)));
            };
        }
        time::sleep(time::Duration::from_micros(500));
        for i in 0..4usize {
            write_one(&pairs.at(i).a); // events in flight as the shutdown lands
        }
        io::shutdown();
        wg.wait();
    }
}

// Sockets closed under parked readers and writers, from another task and from the main thread, with data
// racing the close; the numbers are reused at once.
fn close_storm(l: &net::TcpListener, rounds: i64) {
    for r in 0..rounds {
        let mut p = pair(l);
        let fd = p.b.fd;
        let wg = sync::WaitGroup::new();
        wg.add(2);
        for k in 0..2 {
            let w = wg.clone();
            launch || {
                defer w.done();
                let _ = io::wait_until(fd, k == 1, time::deadline_in(time::Duration::from_secs(5)));
            };
        }
        if r % 2 == 0 {
            time::sleep(time::Duration::from_micros(200));
        }
        if r % 3 == 0 {
            write_one(&p.a);
        }
        p.b.close();
        p.a.close();
        wg.wait();
    }
}

fn main() i32 {
    rt::set_worker_count(4);
    let l = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    eprintln("io_hunt: event_vs_deadline");
    event_vs_deadline(&l, 300);
    eprintln("io_hunt: cancel_storm");
    cancel_storm(&l, 200);
    eprintln("io_hunt: many_waiters");
    many_waiters(&l, 100);
    eprintln("io_hunt: reuse_storm");
    reuse_storm(&l, 50);
    eprintln("io_hunt: close_storm");
    close_storm(&l, 200);
    eprintln("io_hunt: shutdown_storm");
    shutdown_storm(&l, 20);
    eprintln("io_hunt: done");
    if io::pending_waits() != 0 {
        return 1;
    }
    io::shutdown();
    let res = rt::try_shutdown(rt::ShutdownOptions::defaults());
    if res.unresponsive != 0 {
        return 1;
    }
    return 0;
}
