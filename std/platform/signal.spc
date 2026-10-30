// Signals of std::platform. POSIX names its signals in `Signal`: each can take its default action, be
// ignored, or run a handler. Windows has console events (`ConsoleEvent`) instead, which handler routines
// receive. WASI has neither: there every registration is Unsupported. A handler runs at any point of any
// thread, between two instructions: it may only call async-signal-safe functions and store to atomics or
// `volatile` state, so installing one is `unsafe`. Unstable, internal to std and the compiler.
import std::platform::error;

@platform(macos | ios)
type sigset_t = u32;

@platform(macos | ios | linux | android)
extern "C" "signal.h" {
    @platform(linux | android)
    @import("sigset_t")
    struct sigset_t {
        @import("__val")
        pub val: [u64; 16],
    }
    // `sa_handler` is the header's macro over the handler union's first member.
    @platform(macos | ios)
    struct sigaction {
        @import("sa_handler")
        pub handler: fn(i32),
        pub sa_mask: sigset_t,
        pub sa_flags: i32,
    }
    @platform(linux | android)
    struct sigaction {
        @import("sa_handler")
        pub handler: fn(i32),
        pub sa_mask: sigset_t,
        pub sa_flags: i32,
        pub sa_restorer: fn(),
    }
    @import("sigaction")
    fn c_sigaction(sig: i32, act: *const sigaction, old: *mut sigaction) i32;
    fn sigemptyset(set: *mut sigset_t) i32;
    const SIGHUP: i32;
    const SIGINT: i32;
    const SIGQUIT: i32;
    const SIGPIPE: i32;
    const SIGALRM: i32;
    const SIGTERM: i32;
    const SIGCHLD: i32;
    const SIGUSR1: i32;
    const SIGUSR2: i32;
    @platform(macos | ios)
    const SA_RESTART: i32 = 2;
    @platform(linux | android)
    const SA_RESTART: i32 = 0x10000000;
}

// SIGWINCH is outside POSIX: the headers define it only above the build's feature level. Darwin and Linux
// both number it 28.
@platform(macos | ios | linux | android)
const SIGWINCH: i32 = 28;

@platform(windows)
extern "C" "windows.h" {
    // `BOOL (WINAPI *)(DWORD)`: `DWORD` is a C `unsigned long`, which no Super-C type spells (`u32` is
    // `unsigned int`), so a routine passes through `ConsoleHandler`.
    @layout(8, 8)
    type PHANDLER_ROUTINE;
    fn SetConsoleCtrlHandler(routine: PHANDLER_ROUTINE, add: i32) i32;
}

/// A POSIX signal a program commonly handles or ignores.
@platform(!windows)
@derive(Eq, Format)
pub enum Signal {
    Hangup,
    Interrupt,
    Quit,
    Pipe, // a write to a pipe or socket whose reader is gone
    Alarm,
    Terminate,
    Child,
    User1,
    User2,
    WindowChange,
}

/// A Windows console event, as a handler routine receives it (`CTRL_*_EVENT`).
@platform(windows)
@derive(Eq, Format)
pub enum ConsoleEvent {
    CtrlC = 0,
    CtrlBreak = 1,
    Close = 2,
    Logoff = 5,
    Shutdown = 6,
}

// The bits of `sa_handler`, which holds SIG_DFL (0) or SIG_IGN (1) in place of a handler.
@platform(macos | ios | linux | android)
union SignalHandler {
    pub f: fn(i32),
    pub p: *mut void,
}

// A console routine's address, as SetConsoleCtrlHandler takes it (`h`; null removes every routine).
@platform(windows)
union ConsoleHandler {
    pub f: fn(u32) i32,
    pub p: *mut void,
    pub h: PHANDLER_ROUTINE,
}

/// The signal number of `s` on this system.
@platform(macos | ios | linux | android)
pub const fn number(s: Signal) i32 {
    return switch s {
        Hangup => SIGHUP,
        Interrupt => SIGINT,
        Quit => SIGQUIT,
        Pipe => SIGPIPE,
        Alarm => SIGALRM,
        Terminate => SIGTERM,
        Child => SIGCHLD,
        User1 => SIGUSR1,
        User2 => SIGUSR2,
        WindowChange => SIGWINCH,
    };
}

/// Let `s` take its default action again.
@platform(!windows)
pub fn set_default(s: Signal) Result<Unit, IoError> {
    return install(s, null);
}

/// Ignore `s` (`Pipe`: a write to a closed pipe or socket fails with Closed instead of ending the
/// process). Children started afterwards inherit an ignored signal.
@platform(!windows)
pub fn ignore(s: Signal) Result<Unit, IoError> {
    return install(s, 1 as *mut void);
}

/// Run `handler(number)` when `s` arrives. Interrupted system calls restart.
/// Safety: `handler` calls only async-signal-safe functions and touches only atomic or volatile state.
@platform(macos | ios | linux | android)
pub unsafe fn set_handler(s: Signal, handler: fn(i32)) Result<Unit, IoError> {
    return install(s, SignalHandler { f: handler }.p);
}
/// Run `handler(number)` when `s` arrives. Unsupported: WASI has no signals.
/// Safety: `handler` calls only async-signal-safe functions and touches only atomic or volatile state.
@platform(wasm)
pub unsafe fn set_handler(_s: Signal, _handler: fn(i32)) Result<Unit, IoError> {
    return Result::<Unit, IoError>::Err(error::unsupported(IoOp::Signal));
}

// Make `h` the action of `s`: SIG_DFL (null), SIG_IGN (1) or a handler's address.
@platform(macos | ios | linux | android)
fn install(s: Signal, h: *mut void) Result<Unit, IoError> {
    let mut sa = unsafe zeroed::<sigaction>();
    sa.handler = SignalHandler { p: h }.f;
    sa.sa_flags = SA_RESTART;
    unsafe sigemptyset(&mut sa.sa_mask);
    if unsafe c_sigaction(number(s), &sa, null) != 0 {
        return Err(error::last_error(IoOp::Signal));
    }
    return Ok(Unit {});
}
@platform(wasm)
fn install(_s: Signal, _h: *mut void) Result<Unit, IoError> {
    return Result::<Unit, IoError>::Err(error::unsupported(IoOp::Signal));
}

/// Add `routine` to the console event handlers: the last added runs first, and one that returns nonzero
/// handles the event. It runs on a thread the system starts for the event.
/// Safety: `routine` is safe to run on another thread at any moment.
@platform(windows)
pub unsafe fn add_console_handler(routine: fn(u32) i32) Result<Unit, IoError> {
    return console_handler(ConsoleHandler { f: routine }.p, 1);
}

/// Remove `routine` from the console event handlers.
@platform(windows)
pub fn remove_console_handler(routine: fn(u32) i32) Result<Unit, IoError> {
    return console_handler(ConsoleHandler { f: routine }.p, 0);
}

/// Make this process ignore Ctrl+C (`on`), or take its default action again; children inherit the
/// setting.
@platform(windows)
pub fn ignore_ctrl_c(on: bool) Result<Unit, IoError> {
    return console_handler(null, on as i32);
}

/// The event of console event code `code`, None for a code this enum does not name.
@platform(windows)
pub fn console_event(code: u32) Option<ConsoleEvent> {
    return switch code {
        0 => Some(CtrlC),
        1 => Some(CtrlBreak),
        2 => Some(Close),
        5 => Some(Logoff),
        6 => Some(Shutdown),
        _ => None,
    };
}

@platform(windows)
fn console_handler(p: *mut void, add: i32) Result<Unit, IoError> {
    if unsafe SetConsoleCtrlHandler(ConsoleHandler { p: p }.h, add) == 0 {
        return Err(error::last_error(IoOp::Signal));
    }
    return Ok(Unit {});
}
