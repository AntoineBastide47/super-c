// Error values: `Error`, a tiny owned error for APIs that want more context than a bare i32 code, the error
// chain (`ErrorSource`), and the I/O contract types every `Reader`, `Writer` and platform call shares (`Unit`,
// `IoError`, `IoErrorKind`, `IoOp`).
//
// Chaining: an `Error` may own the `Error` it wraps (`Error::with_source`), and any `ErrorSource` names the
// `Error` it wraps (`source`), so `sources()` walks the chain, nearest cause first, in O(1) per link. An
// `IoError` joins a chain as `Error::from_string(io.code, io.fmt())`. No prelude conversion does it: every
// program carries the prelude's non-generic code, and a conversion would instantiate the derived
// `IoError::fmt` in every build. The links are `Error` values, not `dyn ErrorSource` ones: there is no
// run-time downcast, so a `dyn` link would show only `fmt` and `source`, which an `Error` carries; a
// concrete link keeps `Error` `Clone`, `Send` and `Sync`. The stable categories stay on the concrete types
// (`Error.code`, `IoError.kind`): branch on them before wrapping. Error text is not identity.

/// A code plus an owned message, and the `Error` it wraps, if any; clones deep-copy the message and the
/// chain.
pub struct Error {
    pub code: i32,
    message: String,
    source: Option<Box<Error>>,
}

/// An error that may wrap another: `source` returns the `Error` it wraps. `source` DEFAULTS to none, so a
/// leaf error conforms with an empty extend (`@derive(ErrorSource)`).
pub interface ErrorSource: Format {
    fn source(self: &Self) Option<&Error> {
        return Option::<&Error>::None;
    }

    /// The chain below `self`: `source()`, then its source, until one has none. `self` is not part of it.
    fn sources(self: &Self) ErrorSources {
        return ErrorSources { next: self.source() };
    }
}

/// The iterator of `ErrorSource::sources`: the wrapped errors, nearest first.
pub struct ErrorSources<'a> {
    pub(package) next: Option<&'a Error>,
}

extend Error {
    /// Copies `message`'s bytes into an owned String the Error frees.
    pub fn new(code: i32, message: str) Error {
        return Error { code: code, message: String::from_str(message), source: Option::<Box<Error>>::None };
    }

    /// Takes ownership of `message` (no byte copy).
    pub const fn from_string(code: i32, message: String) Error {
        return Error { code: code, message: message, source: Option::<Box<Error>>::None };
    }

    /// An Error that wraps `source`: copies `message`, and takes ownership of `source` (one allocation for
    /// its box).
    pub fn with_source(code: i32, message: str, source: Error) Error {
        return Error {
            code: code,
            message: String::from_str(message),
            source: Option::<Box<Error>>::Some(Box::new(source)),
        };
    }

    /// The message text.
    pub const fn message(self: &Error) &String {
        return &self.message;
    }
}

extend Error as Clone {
    pub fn clone(self: &Error) Error {
        return Error { code: self.code, message: self.message.clone(), source: self.source.clone() };
    }
}

extend Error as Format {
    pub fn fmt(self: &Error) String {
        let mut out = String::from_str("Error(");
        out.push_i64(self.code);
        out.push_str(": ");
        out.push_string(&self.message);
        out.push_str(")");
        return out;
    }
}

extend Error as ErrorSource {
    pub fn source(self: &Error) Option<&Error> {
        return switch &self.source {
            Some(b) => Option::<&Error>::Some(b),
            None => Option::<&Error>::None,
        };
    }
}

extend<'a> ErrorSources<'a> as Iterator<&'a Error> {
    pub fn next(self: &mut ErrorSources<'a>) Option<&'a Error> {
        let cur = self.next;
        if let Some(e) = cur {
            self.next = e.source();
        }
        return cur;
    }
}

/// The success value of an operation that returns no data (`Result<Unit, IoError>`). Zero bytes.
pub struct Unit {}

/// The stable category of an I/O or operating-system failure: what a caller branches on. The native error
/// number stays in `IoError.code`.
@derive(Eq, Format)
pub enum IoErrorKind {
    Refused, // nothing is listening
    Unreachable, // no route, or the name does not resolve
    Reset, // the peer dropped the connection
    AddressInUse, // something already holds that address
    Closed, // the peer closed, or the handle is closed
    Other,
    NotFound,
    PermissionDenied,
    AlreadyExists,
    InvalidInput, // an argument the operation rejects (a path with a NUL byte, a bad flag)
    InvalidData, // bytes that do not decode
    UnexpectedEnd, // the stream ended inside a unit the caller needs whole
    TimedOut,
    Interrupted, // a signal stopped the call; the platform layer retries it and never returns this kind
    WouldBlock,
    Unsupported, // the target has no such facility
    OutOfMemory,
    Cancelled,
    LimitExceeded, // a size, count or descriptor limit
}

/// The operation that failed.
@derive(Eq, Format)
pub enum IoOp {
    Other,
    Open,
    Close,
    Read,
    Write,
    Seek,
    Sync,
    Stat,
    ReadDir,
    CreateDir,
    RemoveDir,
    Unlink,
    Rename,
    Link,
    Symlink,
    ReadLink,
    RealPath,
    SetPermissions,
    SetTimes,
    Lock,
    Unlock,
    Spawn,
    Wait,
    Kill,
    Pipe,
    ExePath,
    CurrentDir,
    SetCurrentDir,
    TempDir,
    SetEnv,
    UnsetEnv,
    Entropy,
    Reserve,
    Commit,
    Protect,
    Release,
    ThreadCreate,
    ThreadJoin,
    Signal,
    Socket,
    Connect,
    Bind,
    Listen,
    Accept,
    Send,
    Recv,
    Resolve,
    Poll,
    LoadLibrary,
    Symbol,
    GetEnv,
    ThreadLocal,
    ProcessId,
    ResourceUsage,
    SetLimit,
}

/// Why an I/O or operating-system operation failed. `code` is the native error number (`errno`, a Win32 or
/// Winsock code), 0 when there is none. Error text is not identity: compare `kind`.
@derive(Eq, Format, ErrorSource)
pub struct IoError {
    pub kind: IoErrorKind,
    pub code: i32,
    pub op: IoOp,
}

extend IoError {
    /// An error with no native code.
    pub const fn new(kind: IoErrorKind, op: IoOp) IoError {
        return IoError { kind: kind, code: 0, op: op };
    }
    /// The kind, for a caller that does not care about the number.
    pub const fn kind(self: &IoError) IoErrorKind {
        return self.kind;
    }
}
