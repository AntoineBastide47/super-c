// std::platform's smaller modules: OS entropy, the clocks, the CPU count and the forwarded feature
// queries, reserved and committed memory, OS threads, thread-local keys and parking, signals, dynamic
// libraries, and sockets with their WouldBlock contract.

import std::platform::clock;
import std::platform::cpu;
import std::platform::dylib;
import std::platform::entropy;
import std::platform::signal as psig;
import std::platform::socket;
import std::platform::thread;
import std::platform::vm;

@platform(macos | linux)
import signal as csig;

@test
fn entropy_fills_the_whole_buffer_with_os_bytes() {
    let mut a: [u8; 64] = [0; 64];
    let mut b: [u8; 64] = [0; 64];
    entropy::fill(a).unwrap();
    entropy::fill(b).unwrap();
    // Two 512-bit draws are equal, or all zero, with probability 2^-512.
    let va: []u8 = a;
    let vb: []u8 = b;
    let mut same = true;
    let mut zero = true;
    for i in 0..64 {
        same = same && va[i] == vb[i];
        zero = zero && va[i] == 0;
    }
    assert(!same);
    assert(!zero);
    // A large request is filled to its last byte: no zero run of 64 bytes at its end.
    let mut big = Vector::<u8>::new();
    big.resize_default(1 << 20);
    entropy::fill(big.index_range_mut(0..1 << 20)).unwrap();
    let mut tail_zero = true;
    let size: usize = 1 << 20;
    for i in size - 64..size {
        tail_zero = tail_zero && *big.at(i) == 0;
    }
    assert(!tail_zero);
    let mut none: [u8; 0] = [];
    entropy::fill(none).unwrap();
}

@test
fn clocks_move_forward() {
    let t0 = clock::monotonic_ns();
    let w0 = clock::wall_ns();
    clock::sleep_ns(2000000);
    let t1 = clock::monotonic_ns();
    assert(t1 - t0 >= 2000000);
    assert(w0 > 1600000000 * 1000000000); // after September 2020
    assert(clock::wall_ns() >= w0);
    assert_eq(clock::filetime_unix_ns(116444736000000000), 0);
}

@test
fn cpu_count_answers() {
    assert(cpu::count().unwrap() >= 1);
}

@platform(!wasm)
@test
fn reserved_memory_commits_and_protects_by_page() {
    let page = vm::page_size().unwrap();
    assert(page >= 4096);
    assert_eq(page & page - 1, 0);
    let mut m = vm::reserve(page * 3 - 1).unwrap();
    assert_eq(m.len(), page * 3);
    m.commit(page, page).unwrap();
    let p = unsafe (m.as_ptr() + page);
    unsafe p[0] = 7;
    unsafe p[page - 1] = 9;
    m.protect(page, page, vm::Protection::Read).unwrap();
    assert_eq(unsafe p[0], 7);
    m.protect(page, page, vm::Protection::ReadWrite).unwrap();
    unsafe p[1] = 8;
    assert_eq(unsafe p[page - 1], 9);
    assert(vm::reserve(0).unwrap_err().kind == IoErrorKind::InvalidInput);
}

@platform(!wasm)
@test(should_panic)
fn a_misaligned_range_panics() {
    let page = vm::page_size().unwrap();
    let mut m = vm::reserve(page * 2).unwrap();
    let _ = m.commit(1, page);
}

@platform(!wasm)
static mut DETACHED: i32 = 0;

@platform(!wasm)
const fn store_42(arg: *mut void) *mut void {
    unsafe *(arg as *mut i32) = 42;
    return arg;
}

@platform(!wasm)
@test
fn threads_run_and_join() {
    let mut cell: i32 = 0;
    let t = unsafe thread::spawn(store_42, &mut cell).unwrap();
    t.join().unwrap();
    assert_eq(cell, 42);
    // A dropped handle detaches; the thread still runs to its end, so it writes a static.
    {
        let _d = unsafe thread::spawn(store_42, unsafe &mut DETACHED).unwrap();
    }
    thread::yield_now();
}

@test
fn thread_local_keys_hold_one_value_per_thread() {
    let mut k = thread::TlsKey::new().unwrap();
    assert(k.get() == null);
    let mut x: i32 = 5;
    k.set(&mut x).unwrap();
    assert(k.get() == (&mut x) as *mut void);
    k.set(null).unwrap();
    assert(k.get() == null);
}

@test
fn park_returns_when_the_word_differs_or_the_time_passes() {
    let mut word: i32 = 1;
    unsafe thread::park(&mut word, 0, -1); // not the expected value: returns at once
    let t0 = clock::monotonic_ns();
    unsafe thread::park(&mut word, 1, 1000000);
    assert(clock::monotonic_ns() > t0);
    unsafe thread::unpark_one(&mut word);
    unsafe thread::unpark_all(&mut word);
}

@platform(macos | linux)
static mut GOT_SIGNAL: i32 = 0;

@platform(macos | linux)
fn on_user1(sig: i32) {
    unsafe GOT_SIGNAL = sig;
}

@platform(macos | linux)
@test
fn signal_handlers_run_and_reset() {
    unsafe psig::set_handler(psig::Signal::User1, on_user1).unwrap();
    unsafe csig::raise(psig::number(psig::Signal::User1));
    assert_eq(unsafe GOT_SIGNAL, psig::number(psig::Signal::User1));
    psig::ignore(psig::Signal::User1).unwrap();
    unsafe csig::raise(psig::number(psig::Signal::User1)); // ignored: the process lives on
    psig::set_default(psig::Signal::User1).unwrap();
    assert(psig::number(psig::Signal::Interrupt) == csig::SIGINT);
}

@platform(windows)
@test
fn console_events_have_their_codes() {
    assert(psig::console_event(0).unwrap() == psig::ConsoleEvent::CtrlC);
    assert(psig::console_event(6).unwrap() == psig::ConsoleEvent::Shutdown);
    assert(psig::console_event(3).is_none());
    psig::ignore_ctrl_c(true).unwrap();
    psig::ignore_ctrl_c(false).unwrap();
}

// A library every process of the target has, and one of its symbols.
const LIBRARY: str = switch PLATFORM {
    MacOS | IOS => "/usr/lib/libSystem.B.dylib",
    Windows => "kernel32.dll",
    _ => "libc.so.6",
};

@platform(!wasm)
@test
fn libraries_load_and_resolve_symbols() {
    let lib = unsafe dylib::open(LIBRARY).unwrap();
    let sym = if PLATFORM == Platform::Windows {
        "GetCurrentProcessId";
    } else {
        "getpid";
    };
    assert(unsafe lib.symbol(sym).unwrap() != null);
    assert(unsafe lib.symbol("sc_platform_no_such_symbol").unwrap_err().kind == IoErrorKind::NotFound);
    assert(unsafe lib.close().is_ok());
    assert(unsafe dylib::open("sc-platform-no-such-library").is_err());
}

// Wait up to five seconds for `fd` to be ready.
@platform(!wasm)
fn ready(fd: i32, write: bool) bool {
    return socket::wait_fd(fd, write, 5000).unwrap();
}

@platform(!wasm)
@test
fn sockets_report_would_block_and_carry_bytes() {
    let l = socket::tcp_listen("127.0.0.1", 0, 4).unwrap();
    let port = socket::local_port(l).unwrap();
    assert(port > 0);
    assert(socket::tcp_accept(l).unwrap_err().kind == IoErrorKind::WouldBlock);
    let c = socket::tcp_connect("127.0.0.1", port).unwrap();
    assert(ready(c, true));
    socket::connect_result(c).unwrap();
    assert(ready(l, false));
    let a = socket::tcp_accept(l).unwrap();
    let mut buf: [u8; 16] = [0; 16];
    assert(socket::read(a, buf).unwrap_err().kind == IoErrorKind::WouldBlock);
    let msg: [u8; 3] = [1, 2, 3];
    assert_eq(socket::write(c, msg).unwrap(), 3);
    assert(ready(a, false));
    assert_eq(socket::read(a, buf).unwrap(), 3);
    socket::close(c).unwrap();
    assert(ready(a, false));
    assert_eq(socket::read(a, buf).unwrap(), 0); // the peer closed
    socket::close(a).unwrap();
    socket::close(l).unwrap();
    let u = socket::udp_bind("127.0.0.1", 0).unwrap();
    let up = socket::local_port(u).unwrap();
    assert(socket::udp_recv(u, buf).unwrap_err().kind == IoErrorKind::WouldBlock);
    assert_eq(socket::udp_send_to(u, msg, "127.0.0.1", up).unwrap(), 3);
    assert(ready(u, false));
    assert_eq(socket::udp_recv(u, buf).unwrap(), 3);
    socket::close(u).unwrap();
    let mut p = socket::Poller::new().unwrap();
    p.wake();
    let mut ev: [i32; 6] = [0; 6];
    assert_eq(p.wait(ev, 0).unwrap(), 0);
}
