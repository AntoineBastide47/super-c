// Error values: `Error`, a tiny owned error for APIs that want more context than a bare i32 code, and the I/O
// contract types every `Reader`, `Writer` and platform call shares (`Unit`, `IoError`, `IoErrorKind`, `IoOp`).

/// A code plus an owned message; clones deep-copy the message.
pub struct Error {
    pub code: i32,
    message: String,
}

extend Error {
    /// Copies `message`'s bytes into an owned String the Error frees.
    pub fn new(code: i32, message: str) Error {
        return Error { code: code, message: String::from_str(message) };
    }

    /// Takes ownership of `message` (no byte copy).
    pub const fn from_string(code: i32, message: String) Error {
        return Error { code: code, message: message };
    }

    /// The message text.
    pub const fn message(self: &Error) &String {
        return &self.message;
    }
}

extend Error as Clone {
    pub fn clone(self: &Error) Error {
        return Error { code: self.code, message: self.message.clone() };
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

/// The success value of an operation that returns no data (`Result<Unit, IoError>`). Zero bytes.
pub struct Unit {}

/// The stable category of an I/O or operating-system failure: what a caller branches on. The native error
/// number stays in `IoError.code`.
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

extend IoErrorKind as Eq {}

extend IoErrorKind as Format {}

extend IoOp as Eq {}

extend IoOp as Format {}

extend IoError as Eq {}

extend IoError as Format {}
