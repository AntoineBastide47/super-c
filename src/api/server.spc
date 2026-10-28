// `super-c tool-server`: the process protocol (`api::protocol`) over stdio or a Unix-domain socket. A
// reader thread reads the frames and passes them to the request loop through a bounded queue; it handles
// `cancel` itself, so a cancel stops the running request (`RequestOptions.cancel`) or one still queued.
// The request loop alone writes. Socket mode serves one connection at a time; each starts with a fresh
// handshake and its workspaces end with it. The socket lives in an owner-only directory, takes mode 0600,
// and a peer of another user ID is closed before it can send.
import api::errors as *;
import api::protocol as pr;
import api::session as ses;
import lsp::transport as transport;
import lsp::json as json;
import stdio;
import unistd;
import std::parallel::arc;
import std::parallel::channel as ch;
import std::parallel::sync;
import std::parallel::task as ptask;
import std::parallel::thread;
import std::platform::fs;
import std::platform::signal as sig;
import std::platform::socket as sk;

@platform(!windows)
extern "C" "stdio.h" {
    fn fdopen(fd: i32, mode: *const char) *mut stdio::FILE;
}

// Frames the reader may queue ahead of the request loop.
const QUEUE_MAX: usize = 64;
// Cancelled ids remembered for requests still queued; the oldest is forgotten first.
const EARLY_MAX: usize = 256;

// The request the loop runs, the source that cancels it, and the ids cancelled before they ran.
struct CancelState {
    pub active: i64,
    pub source: Option<ptask::CancelSource>,
    pub early: Vector<i64>,
}

// The target of `msg` when it is a `cancel` request; -1 otherwise.
fn cancel_target(msg: str) i64 {
    if msg.find("\"cancel\"") < 0 {
        return -1;
    }
    let v = switch json::parse(msg) {
        Ok(v) => v,
        Err(_) => {
            return -1;
        },
    };
    if v.value_str("method") != "cancel" {
        return -1;
    }
    return switch v.value("params") {
        Some(p) => p.value_i64("target", -1),
        None => -1,
    };
}

// The stream the reader reads: stdin for descriptor -1, else descriptor `fd`.
@platform(!windows)
fn read_stream(fd: i32) *mut stdio::FILE {
    if fd < 0 {
        return stdio::stdin();
    }
    let mut m = String::from_str("r");
    return unsafe fdopen(fd, m.cstr());
}

@platform(windows)
fn read_stream(_fd: i32) *mut stdio::FILE {
    return stdio::stdin();
}

// The reader thread: frames of at most `max` bytes from descriptor `fd` (-1: stdin) into `tx`, cancels
// applied to `st`. Ends at the end of the input or a malformed frame, and closes the queue.
fn read_loop(fd: i32, max: usize, tx: &ch::Sender<String>, st: &arc::Arc<sync::Mutex<CancelState>>) {
    let f = read_stream(fd);
    let mut rd = transport::Reader::new(f);
    // Bounded by the frames of the input.
    while let Some(msg) = transport::read_message_max(&mut rd, max) {
        let t = cancel_target(msg.as_str());
        if t >= 0 {
            let mut g = st.get().lock();
            let cs = g.get_mut();
            if cs.active == t {
                if let Some(src) = &cs.source {
                    src.cancel(1);
                }
            } else {
                if cs.early.len() == EARLY_MAX {
                    let _ = cs.early.remove(0);
                }
                cs.early.push(t);
            }
        }
        if let Rejected(_) = tx.send(msg) {
            break;
        }
    }
    tx.close();
    if fd >= 0 {
        let _ = unsafe stdio::fclose(f);
    }
}

// Serve one client: frames from descriptor `in_fd` (-1: stdin), answers to `out`, until the input ends.
fn serve(cfg: pr::Launch, in_fd: i32, out: *mut stdio::FILE) {
    let st = arc::Arc::<sync::Mutex<CancelState>>::new(
        sync::Mutex::<CancelState>::new(
            CancelState { active: -1, source: Option::<ptask::CancelSource>::None, early: Vector::<i64>::new() },
        ),
    );
    let chan = ch::Channel::<String>::bounded(QUEUE_MAX);
    let tx = chan.sender();
    let rx = chan.receiver();
    let st2 = st.clone();
    let max = cfg.max_frame;
    let reader = thread::spawn(move (|| read_loop(in_fd, max, &tx, &st2)));
    let mut sv = pr::Server::new(cfg);
    // Bounded by the frames the reader passes on.
    while let Some(msg) = rx.recv() {
        let req = switch json::parse(msg.as_str()) {
            Ok(v) => v,
            Err(e) => {
                let r = pr::error_reply(
                    -1,
                    ApiError::new(Code::ProtocolFailed, format("malformed JSON: {}", e.as_str()).as_str()),
                );
                transport::write_message(out, r.as_str());
                continue;
            },
        };
        let id = req.value_i64("id", -1);
        let is_cancel = req.value_str("method") == "cancel";
        // A cancel follows its target in the queue: the target ran, so its id leaves the early list.
        let gone = if is_cancel {
            switch req.value("params") {
                Some(p) => p.value_i64("target", -1),
                None => -1,
            };
        } else {
            id;
        };
        let (src, tok) = ptask::CancelSource::new();
        let mut early = false;
        {
            let mut g = st.get().lock();
            let cs = g.get_mut();
            for i in 0..cs.early.len() {
                if cs.early[i] == gone {
                    let _ = cs.early.remove(i);
                    early = !is_cancel;
                    break;
                }
            }
            cs.active = id;
            cs.source = Option::<ptask::CancelSource>::Some(src);
        }
        let reply = if early {
            pr::error_reply(id, ApiError::new(Code::Cancelled, "the request was cancelled before it ran"));
        } else {
            sv.handle_json(
                &req,
                &ses::RequestOptions {
                    cancel: Option::<ptask::CancelToken>::Some(tok),
                    deadline_ns: 0,
                    result_limit: 0,
                },
            );
        };
        {
            let mut g = st.get().lock();
            let cs = g.get_mut();
            cs.active = -1;
            cs.source = Option::<ptask::CancelSource>::None;
        }
        transport::write_message(out, reply.as_str());
        let p = sv.take_payload();
        if p.len() != 0 {
            write_bytes(out, &p);
        }
    }
    reader.join();
}

// Frame and send the bytes of `p`, then flush.
fn write_bytes(f: *mut stdio::FILE, p: &Vector<u8>) {
    let mut hdr = String::with_capacity(40);
    hdr.format_into("Content-Length: {}\r\n\r\n", p.len());
    unsafe stdio::fwrite(hdr.as_ptr(), 1, hdr.len(), f);
    unsafe stdio::fwrite(p.as_ptr(), 1, p.len(), f);
    unsafe stdio::fflush(f);
}

/// Serve one client over stdin and stdout; 0 when its input ends.
pub fn run_stdio(cfg: pr::Launch) i32 {
    serve(cfg, -1, stdio::stdout());
    return 0;
}

/// Serve clients of the Unix-domain socket at `path`, one at a time, until accepting fails: 1 then, or
/// when the socket cannot be made. The directory of `path` is created owner-only, or must be owner-only.
@platform(macos | ios | linux | android)
pub fn run_socket(cfg: pr::Launch, path: str) i32 {
    let mut cut = path.len();
    while cut > 0 && path.byte_at(cut - 1) != b'/' {
        cut -= 1;
    }
    let dir = if cut <= 1 {
        "/";
    } else {
        path.slice(0, cut - 1);
    };
    switch fs::stat(dir) {
        Ok(m) => {
            if m.kind != fs::FileKind::Dir || (m.permissions & 0o077) != 0 {
                eprintln("tool-server: '{}' must be a directory only its owner can use (mode 0700)", dir);
                return 1;
            }
        },
        Err(_) => {
            if fs::mkdir(dir).is_err() || fs::set_permissions(dir, 0o700).is_err() {
                eprintln("tool-server: cannot create the directory '{}'", dir);
                return 1;
            }
        },
    };
    let l = switch sk::unix_listen(path, 4) {
        Ok(fd) => fd,
        Err(e) => {
            eprintln("tool-server: cannot listen at '{}': {}", path, e);
            return 1;
        },
    };
    if fs::set_permissions(path, 0o600).is_err() {
        eprintln("tool-server: cannot restrict '{}'", path);
        let _ = sk::close(l);
        let _ = fs::unlink(path);
        return 1;
    }
    // A client that leaves mid-answer makes the write fail, not the server end.
    let _ = sig::ignore(sig::Signal::Pipe);
    let me = sk::uid();
    // Serves until accepting fails; a signal ends the server.
    loop {
        let c = switch sk::unix_accept(l) {
            Ok(fd) => fd,
            Err(e) => {
                eprintln("tool-server: accept failed: {}", e);
                break;
            },
        };
        let ok = switch sk::peer_uid(c) {
            Ok(u) => u == me,
            Err(_) => false,
        };
        if !ok {
            let _ = sk::close(c);
            continue;
        }
        let mut m = String::from_str("w");
        let out = unsafe fdopen(unistd::dup(c), m.cstr());
        if out == null {
            let _ = sk::close(c);
            continue;
        }
        serve(cfg.clone(), c, out);
        let _ = unsafe stdio::fclose(out);
    }
    let _ = sk::close(l);
    let _ = fs::unlink(path);
    return 1;
}

/// Socket mode needs Unix-domain sockets with a peer check: not on this target.
@platform(windows | wasm)
pub fn run_socket(_launch: pr::Launch, _path: str) i32 {
    eprintln("tool-server: --socket is not supported on this target; use --stdio");
    return 1;
}
