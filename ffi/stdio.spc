// FFI bindings for <stdio.h>: file and console I/O. Import with `import stdio;`.
//
// `FILE` is an opaque C handle (its layout lives in <stdio.h>); the raw `pub` bindings expose the C API,
// and the `File` struct adds a safe, owning wrapper: `open` returns `None` instead of a null handle, and
// `Free` closes the handle automatically. The standard streams stdin/stdout/stderr are exposed through
// helper functions. Calling the raw bindings requires `unsafe` except `getchar`/`putchar`; the `File`
// methods and the wrapper functions do not.

import errno;
import stdlib;

extern "C" {
    /// A C stream.
    pub type FILE;

    // Open / close / flush.
    @import("fopen")
    fn c_fopen(path: *const char, mode: *const char) *mut FILE;
    /// Reopen `stream` on `path`; the stream, or null (the stream is closed) on failure.
    pub fn freopen(path: *const char, mode: *const char, stream: *mut FILE) *mut FILE;
    /// Flush and close; 0 on success, EOF on error.
    pub fn fclose(stream: *mut FILE) i32;
    /// Write out buffered data (all streams when null); 0 on success.
    pub fn fflush(stream: *mut FILE) i32;

    /// Block read / write (element size in bytes); return the element count transferred.
    pub fn fread(ptr: *mut void, size: usize, count: usize, stream: *mut FILE) usize;
    /// Write `count` items of `size` bytes; the number of items written.
    pub fn fwrite(ptr: *const void, size: usize, count: usize, stream: *mut FILE) usize;

    /// Character / line I/O. `fgetc`/`getchar` return the byte or -1 (EOF); `fgets` returns null at EOF.
    pub fn fgetc(stream: *mut FILE) i32;
    /// Write one byte; the byte, or EOF on error.
    pub fn fputc(c: i32, stream: *mut FILE) i32;
    /// Write a NUL-terminated string (no newline); non-negative on success.
    pub fn fputs(s: *const char, stream: *mut FILE) i32;
    /// Read up to `size - 1` bytes through a newline into `buf`, NUL-terminated; null at EOF or error.
    pub fn fgets(buf: *mut char, size: i32, stream: *mut FILE) *mut char;
    /// Next byte of stdin, or EOF.
    @unsafe(safe)
    pub fn getchar() i32;
    /// Write one byte to stdout; the byte, or EOF.
    @unsafe(safe)
    pub fn putchar(c: i32) i32;
    /// Write a string plus newline to stdout; non-negative on success.
    pub fn puts(s: *const char) i32;
    /// Print `prefix: <strerror(errno)>` to stderr.
    pub fn perror(prefix: *const char) void;

    /// Positioning and status.
    pub fn fseek(stream: *mut FILE, offset: stdlib::c_long, whence: i32) i32;
    /// Current position in bytes, or -1.
    pub fn ftell(stream: *mut FILE) stdlib::c_long;
    /// Seek to the start and clear the error flag.
    pub fn rewind(stream: *mut FILE) void;
    /// Nonzero once a read hit end of file.
    pub fn feof(stream: *mut FILE) i32;
    /// Nonzero once an I/O error occurred.
    pub fn ferror(stream: *mut FILE) i32;

    /// Filesystem.
    pub fn remove(path: *const char) i32;
    /// Rename or move a file; 0 or -1 and errno.
    pub fn rename(from: *const char, to: *const char) i32;

    /// Formatted I/O (C variadic): the format string drives the trailing argument list. `snprintf` is the
    /// bounds-checked formatter (writes at most `size` bytes incl. the NUL); the `*scanf` family reads.
    pub fn printf(fmt: *const char, ...) i32;
    /// Formatted write; the byte count, or negative on error.
    pub fn fprintf(stream: *mut FILE, fmt: *const char, ...) i32;
    /// Formatted write into `buf` (at most `size - 1` bytes plus NUL); the length that would have been
    /// written.
    pub fn snprintf(buf: *mut char, size: usize, fmt: *const char, ...) i32;
    /// Formatted read from a string; the number of conversions assigned, or EOF.
    pub fn sscanf(s: *const char, fmt: *const char, ...) i32;
    /// Formatted read from stdin; the number of conversions assigned, or EOF.
    pub fn scanf(fmt: *const char, ...) i32;
    /// Formatted read from `stream`; the number of conversions assigned, or EOF.
    pub fn fscanf(stream: *mut FILE, fmt: *const char, ...) i32;
}

// The standard streams: `stdin`, `stdout` and `stderr` are macros over a per-target C object. wasm's C
// library defines no such object: its streams come from `sc_stdio_stream` (`std::rt::libc`).
@platform(macos | ios)
extern "C" "stdio.h" {
    @import("__stdinp")
    static mut c_stdin: *mut FILE;
    @import("__stdoutp")
    static mut c_stdout: *mut FILE;
    @import("__stderrp")
    static mut c_stderr: *mut FILE;
}
@platform(linux | android)
extern "C" "stdio.h" {
    @import("stdin")
    static mut c_stdin: *mut FILE;
    @import("stdout")
    static mut c_stdout: *mut FILE;
    @import("stderr")
    static mut c_stderr: *mut FILE;
}
@platform(wasm)
extern "C" {
    /// The standard stream `fd`: 0 stdin, 1 stdout, 2 stderr.
    fn sc_stdio_stream(fd: i32) *mut FILE;
}
@platform(windows)
extern "C" "stdio.h" {
    /// The UCRT's standard stream `i`: 0 stdin, 1 stdout, 2 stderr.
    fn __acrt_iob_func(i: u32) *mut FILE;
}

/// `fseek` origins.
pub const SEEK_SET: i32 = 0;
/// fseek whence values.
pub const SEEK_CUR: i32 = 1;
pub const SEEK_END: i32 = 2;

/// An owning file handle: closed exactly once, automatically, when it goes out of scope (`Free`).
pub struct File {
    handle: *mut FILE,
}

extend File {
    /// Open `path` with a C `fopen` mode ("r", "w", "a", "rb", ...). `None` if the file cannot be opened.
    pub fn open(path: &mut String, mode: &mut String) Option<File> {
        let h = unsafe c_fopen(path.cstr(), mode.cstr());
        if h == null {
            return None;
        }
        return Some(File { handle: h });
    }

    /// Append `text`'s bytes to the file; returns the number of bytes written.
    pub fn write_str(self: &mut File, text: &String) usize {
        return unsafe fwrite(text.as_ptr(), 1, text.len(), self.handle);
    }

    /// Read the entire remaining contents into a new owned string.
    pub fn read_all(self: &mut File) String {
        let mut out = String::new();
        let mut c = unsafe fgetc(self.handle);
        while c >= 0 {
            out.push_byte(c as u8);
            c = unsafe fgetc(self.handle);
        }
        return out;
    }

    /// Flush buffered writes to the OS. Returns 0 on success.
    pub fn flush(self: &mut File) i32 {
        return unsafe fflush(self.handle);
    }

    /// Close now, idempotently. Also runs automatically via `Free`.
    pub fn close(self: &mut File) {
        if self.handle != null {
            unsafe fclose(self.handle);
            self.handle = null;
        }
    }
}

extend File as Free {
    fn free(self: &mut File) {
        self.close();
    }
}

extend File as Writer {
    /// One `fwrite`: the count it took, or its error (the C errno, kind `Other`) when it took no byte.
    fn write(self: &mut File, bytes: []u8) Result<usize, IoError> {
        let n = unsafe fwrite(bytes.as_ptr(), 1, bytes.len(), self.handle);
        if n == 0 && bytes.len() != 0 {
            return Err(IoError { kind: Other, code: errno::errno(), op: Write });
        }
        return Ok(n);
    }
}

/// Open `path` with a C `fopen` mode ("r", "w", "a", "rb", ...), returning the raw handle (`null` on
/// failure) for callers that manage `fclose` themselves. Both args are NUL-terminated into temporaries.
pub fn fopen(path: str, mode: str) *mut FILE {
    let mut p = String::from_str(path);
    let mut m = String::from_str(mode);
    return unsafe c_fopen(p.cstr(), m.cstr());
}

/// The C stdin stream.
@platform(macos | ios | linux | android)
pub fn stdin() *mut FILE {
    return unsafe c_stdin;
}
/// The C stdout stream.
@platform(macos | ios | linux | android)
pub fn stdout() *mut FILE {
    return unsafe c_stdout;
}
/// The C stderr stream.
@platform(macos | ios | linux | android)
pub fn stderr() *mut FILE {
    return unsafe c_stderr;
}
/// The C stdin stream.
@platform(wasm)
pub fn stdin() *mut FILE {
    return unsafe sc_stdio_stream(0);
}
/// The C stdout stream.
@platform(wasm)
pub fn stdout() *mut FILE {
    return unsafe sc_stdio_stream(1);
}
/// The C stderr stream.
@platform(wasm)
pub fn stderr() *mut FILE {
    return unsafe sc_stdio_stream(2);
}
/// The C stdin stream.
@platform(windows)
pub fn stdin() *mut FILE {
    return unsafe __acrt_iob_func(0);
}
/// The C stdout stream.
@platform(windows)
pub fn stdout() *mut FILE {
    return unsafe __acrt_iob_func(1);
}
/// The C stderr stream.
@platform(windows)
pub fn stderr() *mut FILE {
    return unsafe __acrt_iob_func(2);
}
