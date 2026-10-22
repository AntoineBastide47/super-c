// The error side of std::platform: the native error number of a failed call (errno on POSIX and WASI, the
// Win32 code from GetLastError on Windows, Winsock codes included) classified into an `IoErrorKind`.
// Unstable, internal to std and the compiler.
import errno;

@platform(!windows)
extern "C" "errno.h" {
    const ENOENT: i32;
    const ENOTDIR: i32;
    const EPERM: i32;
    const EACCES: i32;
    const EROFS: i32;
    const EEXIST: i32;
    const EINVAL: i32;
    const ENAMETOOLONG: i32;
    const ELOOP: i32;
    const EISDIR: i32;
    const EBADF: i32;
    const EINTR: i32;
    const EAGAIN: i32;
    const EWOULDBLOCK: i32;
    const EINPROGRESS: i32;
    const ETIMEDOUT: i32;
    const ENOMEM: i32;
    const EMFILE: i32;
    const ENFILE: i32;
    const ENOSPC: i32;
    const EFBIG: i32;
    const E2BIG: i32;
    const EMLINK: i32;
    const ENOSYS: i32;
    const ENOTSUP: i32;
    const EOPNOTSUPP: i32;
    const EAFNOSUPPORT: i32;
    const ECONNREFUSED: i32;
    const ECONNRESET: i32;
    const ECONNABORTED: i32;
    const EADDRINUSE: i32;
    const EADDRNOTAVAIL: i32;
    const ENETUNREACH: i32;
    const EHOSTUNREACH: i32;
    const EPIPE: i32;
    const ENOTCONN: i32;
    const ECANCELED: i32;
    const ESRCH: i32;
    const ECHILD: i32;
    const EXDEV: i32;
}

@platform(windows)
extern "C" "windows.h" {
    fn GetLastError() u32;
}

/// The error of the failed `op` from this thread's last native error number.
@platform(!windows)
pub fn last_error(op: IoOp) IoError {
    return code_error(errno::errno(), op);
}
/// The error of the failed `op` from this thread's last native error number.
@platform(windows)
pub fn last_error(op: IoOp) IoError {
    return code_error((unsafe GetLastError()) as i32, op);
}

/// The error of the failed `op` from native error number `code`.
pub const fn code_error(code: i32, op: IoOp) IoError {
    return IoError { kind: kind_of(code), code: code, op: op };
}

/// `op` has no implementation on this target.
pub const fn unsupported(op: IoOp) IoError {
    return IoError::new(IoErrorKind::Unsupported, op);
}

/// Whether the last native error number is EINTR: the call was interrupted and the layer runs it again.
@platform(!windows)
pub fn interrupted() bool {
    return errno::errno() == EINTR;
}

/// The category of errno value `e`.
@platform(!windows)
pub const fn kind_of(e: i32) IoErrorKind {
    if e == ENOENT || e == ENOTDIR || e == ESRCH {
        return IoErrorKind::NotFound;
    }
    if e == EPERM || e == EACCES || e == EROFS {
        return IoErrorKind::PermissionDenied;
    }
    if e == EEXIST {
        return IoErrorKind::AlreadyExists;
    }
    if e == EINVAL || e == ENAMETOOLONG || e == ELOOP || e == EISDIR || e == EBADF || e == EXDEV || e == ECHILD {
        return IoErrorKind::InvalidInput;
    }
    if e == EAGAIN || e == EWOULDBLOCK || e == EINPROGRESS {
        return IoErrorKind::WouldBlock;
    }
    if e == EINTR {
        return IoErrorKind::Interrupted;
    }
    if e == ETIMEDOUT {
        return IoErrorKind::TimedOut;
    }
    if e == ENOMEM {
        return IoErrorKind::OutOfMemory;
    }
    if e == EMFILE || e == ENFILE || e == ENOSPC || e == EFBIG || e == E2BIG || e == EMLINK {
        return IoErrorKind::LimitExceeded;
    }
    if e == ENOSYS || e == ENOTSUP || e == EOPNOTSUPP || e == EAFNOSUPPORT {
        return IoErrorKind::Unsupported;
    }
    if e == ECONNREFUSED {
        return IoErrorKind::Refused;
    }
    if e == ECONNRESET || e == ECONNABORTED {
        return IoErrorKind::Reset;
    }
    if e == EADDRINUSE || e == EADDRNOTAVAIL {
        return IoErrorKind::AddressInUse;
    }
    if e == ENETUNREACH || e == EHOSTUNREACH {
        return IoErrorKind::Unreachable;
    }
    if e == EPIPE || e == ENOTCONN {
        return IoErrorKind::Closed;
    }
    if e == ECANCELED {
        return IoErrorKind::Cancelled;
    }
    return IoErrorKind::Other;
}

// The Win32 codes of winerror.h, WSAE* included: one number space, so no code of one family is read in
// the meaning of another.
/// The category of Win32 error code `e`.
@platform(windows)
pub fn kind_of(e: i32) IoErrorKind {
    return switch e {
        2 | 3 | 15 | 53 | 67 | 126 | 127 | 161 | 267 => IoErrorKind::NotFound, // FILE_NOT_FOUND, PATH_NOT_FOUND, INVALID_DRIVE, BAD_NETPATH, BAD_NET_NAME, MOD_NOT_FOUND, PROC_NOT_FOUND, BAD_PATHNAME, DIRECTORY (a file where a directory is named: POSIX ENOTDIR)
        5 | 19 | 32 | 33 | 1314 | 10013 => IoErrorKind::PermissionDenied, // ACCESS_DENIED, WRITE_PROTECT, SHARING_VIOLATION, LOCK_VIOLATION, PRIVILEGE_NOT_HELD, WSAEACCES
        80 | 183 => IoErrorKind::AlreadyExists, // FILE_EXISTS, ALREADY_EXISTS
        6 | 17 | 87 | 123 | 206 | 4390 | 10022 => IoErrorKind::InvalidInput, // INVALID_HANDLE, NOT_SAME_DEVICE, INVALID_PARAMETER, INVALID_NAME, FILENAME_EXCED_RANGE, NOT_A_REPARSE_POINT, WSAEINVAL
        8 | 14 => IoErrorKind::OutOfMemory, // NOT_ENOUGH_MEMORY, OUTOFMEMORY
        4 | 112 | 1450 | 10024 | 10055 => IoErrorKind::LimitExceeded, // TOO_MANY_OPEN_FILES, DISK_FULL, NO_SYSTEM_RESOURCES, WSAEMFILE, WSAENOBUFS
        50 | 120 | 10043 | 10045 | 10047 => IoErrorKind::Unsupported, // NOT_SUPPORTED, CALL_NOT_IMPLEMENTED, WSAEPROTONOSUPPORT, WSAEOPNOTSUPP, WSAEAFNOSUPPORT
        258 | 1460 | 10060 => IoErrorKind::TimedOut, // WAIT_TIMEOUT, TIMEOUT, WSAETIMEDOUT
        995 | 1223 => IoErrorKind::Cancelled, // OPERATION_ABORTED, CANCELLED
        10004 => IoErrorKind::Interrupted, // WSAEINTR
        232 | 10035 | 10036 => IoErrorKind::WouldBlock, // NO_DATA (a pipe in no-wait mode), WSAEWOULDBLOCK, WSAEINPROGRESS
        10061 => IoErrorKind::Refused, // WSAECONNREFUSED
        10053 | 10054 => IoErrorKind::Reset, // WSAECONNABORTED, WSAECONNRESET
        10048 | 10049 => IoErrorKind::AddressInUse, // WSAEADDRINUSE, WSAEADDRNOTAVAIL
        10051 | 10065 | 11001 => IoErrorKind::Unreachable, // WSAENETUNREACH, WSAEHOSTUNREACH, WSAHOST_NOT_FOUND
        109 | 10057 | 10058 => IoErrorKind::Closed, // BROKEN_PIPE, WSAENOTCONN, WSAESHUTDOWN
        _ => IoErrorKind::Other,
    };
}
