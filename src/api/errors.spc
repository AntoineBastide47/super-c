// The error model of the compiler API: a stable code a client branches on, a short message for people,
// and the source range the failure concerns. A code never changes meaning; message text is not identity.

/// The API version: major << 16 | minor. The C ABI and the process protocol report it.
pub const API_VERSION: u32 = 0 << 16 | 1;

/// The stable category of a failed API call.
@derive(Eq, Format)
pub enum Code {
    InvalidArgument, // an argument the call rejects: an unknown file, an edit outside the text
    StaleHandle, // a C ABI or protocol handle of an earlier generation
    WrongWorkspace, // a C ABI or protocol handle of another session
    Cancelled, // the request's token cancelled it
    Deadline, // the request's deadline passed
    Limit, // a result or memory budget of the request or the session
    Io, // the file provider failed; `ApiError.io` holds the cause
    ParseFailed, // the source does not parse
    SemanticFailed, // the source parses and does not check
    VerificationFailed, // generated IR or edits do not verify
    PluginFailed, // an analyzer or tool failed
    ProtocolFailed, // a malformed process-protocol message
    ReentrantCall, // a C ABI callback called its own session
    NotChecked, // the session holds no complete analysis: `check` first
    UnsupportedCapability, // the C ABI or the protocol does not grant the capability
    VersionMismatch, // the C ABI table or the protocol major differs
    Internal, // a compiler defect
}

/// A failed API call.
pub struct ApiError {
    pub code: Code,
    pub message: String,
    /// The file the failure concerns, empty when none, and the byte range `[start, end)` in it.
    pub file: String,
    pub start: u32,
    pub end: u32,
    /// The cause of an `Io` error.
    pub io: Option<IoError>,
}

extend ApiError {
    /// An error of `code` with `message` and no location.
    pub fn new(code: Code, message: str) ApiError {
        return ApiError { code: code, message: String::from_str(message), io: Option::<IoError>::None };
    }

    /// An error of `code` with `message` at bytes `[start, end)` of `file`.
    pub fn at(code: Code, message: str, file: str, start: u32, end: u32) ApiError {
        return ApiError {
            code: code,
            message: String::from_str(message),
            file: String::from_str(file),
            start: start,
            end: end,
            io: Option::<IoError>::None,
        };
    }

    /// The `Io` error of `cause` on `file`.
    pub fn io(cause: IoError, file: str) ApiError {
        return ApiError {
            code: Code::Io,
            message: String::from_str("the file provider failed"),
            file: String::from_str(file),
            io: Option::<IoError>::Some(cause),
        };
    }
}
