// Error chaining in std/error.spc: `Error::with_source` owns the wrapped error, `ErrorSource::source` names
// it, and `sources()` walks the chain nearest first; chains of depth 3 through `Error`, `IoError` and a user
// error type, clones that deep-copy the chain, and the existing `Error` surface unchanged. Every chain owns
// Strings, so the leak check proves each link is freed once.

// A user error that wraps an `Error`.
struct Load {
    pub path: String,
    pub cause: Error,
}

// A user leaf error: the default `source` (none).
@derive(ErrorSource)
struct Parse {
    pub line: u32,
}

const fn need_send_sync<T: Send + Sync>(x: T) T {
    return x;
}

// The `code`s of the chain below `e`, nearest first.
fn codes<E: ErrorSource>(e: &E) Vector<i32> {
    let mut v = Vector::<i32>::new();
    for c in e.sources() {
        v.push(c.code);
    }
    return v;
}

fn depth3() Error {
    let io = IoError { kind: IoErrorKind::NotFound, code: 2, op: IoOp::Open };
    let read = Error::with_source(10, "read config", Error::from_string(io.code, io.fmt()));
    return Error::with_source(20, "start service", read);
}

extend Load as Format {
    pub fn fmt(self: &Load) String {
        let mut s = String::from_str("Load(");
        s.push_string(&self.path);
        s.push_str(")");
        return s;
    }
}

extend Load as ErrorSource {
    pub fn source(self: &Load) Option<&Error> {
        return Option::<&Error>::Some(&self.cause);
    }
}

extend Parse as Format {
    pub fn fmt(self: &Parse) String {
        let mut s = String::from_str("Parse at line ");
        s.push_u64(self.line);
        return s;
    }
}

@test
fn a_chain_of_depth_three_walks_nearest_first() {
    let top = depth3();
    let c = codes(&top);
    assert_eq(c.len(), 2);
    assert_eq(*c.at(0), 10);
    assert_eq(*c.at(1), 2);
    let mut it = top.sources();
    let first = it.next().unwrap();
    assert_eq(first.message().as_str(), "read config");
    let second = it.next().unwrap();
    let text = second.fmt();
    assert_eq(text.as_str(), "Error(2: IoError { kind: NotFound, code: 2, op: Open })");
    assert(second.source().is_none());
    assert(it.next().is_none());
    assert(it.next().is_none());
    assert_eq(last(top.sources()).unwrap().code, 2);
    assert_eq(count(top.sources()), 2);
    assert_eq(top.source().unwrap().code, 10);
}

@test
fn a_user_error_starts_a_chain() {
    let l = Load { path: String::from_str("/etc/app"), cause: depth3() };
    let c = codes(&l);
    assert_eq(c.len(), 3);
    assert_eq(*c.at(0), 20);
    assert_eq(*c.at(2), 2);
    let leaf = Parse { line: 4 };
    assert(leaf.source().is_none());
    assert_eq(count(leaf.sources()), 0);
    let io = IoError::new(IoErrorKind::Closed, IoOp::Read);
    assert(io.source().is_none());
    assert_eq(count(io.sources()), 0);
}

@test
fn clones_deep_copy_the_chain() {
    let a = depth3();
    let b = a.clone();
    assert_eq(b.code, 20);
    assert_eq(b.message().as_str(), "start service");
    let ca = codes(&a);
    let cb = codes(&b);
    assert(ca == cb);
    let pa = a.source().unwrap().message() as *const String;
    let pb = b.source().unwrap().message() as *const String;
    assert(pa != pb);
    let moved = need_send_sync(b);
    assert_eq(count(moved.sources()), 2);
}

@test
fn the_existing_error_surface_is_unchanged() {
    let e = Error::new(7, "bad input");
    assert_eq(e.code, 7);
    assert_eq(e.message().as_str(), "bad input");
    assert(e.source().is_none());
    let f = Error::from_string(8, String::from_str("owned"));
    let text = f.fmt();
    assert_eq(text.as_str(), "Error(8: owned)");
    let g = f.clone();
    assert_eq(g.message().as_str(), "owned");
    let t = IoError::new(IoErrorKind::TimedOut, IoOp::Poll);
    let io = Error::from_string(t.code, t.fmt());
    assert_eq(io.code, 0);
    assert_eq(io.message().as_str(), t.fmt().as_str());
    let wrapped = Error::with_source(1, "outer", Error::with_source(2, "middle", Error::new(3, "inner")));
    let text2 = wrapped.fmt();
    assert_eq(text2.as_str(), "Error(1: outer)");
    assert_eq(count(wrapped.sources()), 2);
}
