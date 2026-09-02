// FFI bindings for <stdio.h>: file and console I/O. Import with `import stdio;`.
//
// `FILE` is an opaque C handle (its layout lives in <stdio.h>); the raw `pub` bindings expose the C API,
// and the `File` struct adds a safe, owning wrapper: `open` returns `None` instead of a null handle, and
// `Free` closes the handle automatically. The standard streams stdin/stdout/stderr are exposed through
// helper functions. Calling the raw bindings requires `unsafe`; the `File` methods and the wrapper
// functions do not.

extern "C" {
    pub type FILE;

    // Open / close / flush.
    @c.import("fopen")
    fn c_fopen(path: *const char, mode: *const char) *mut FILE;
    pub fn freopen(path: *const char, mode: *const char, stream: *mut FILE) *mut FILE;
    pub fn fclose(stream: *mut FILE) i32;
    pub fn fflush(stream: *mut FILE) i32;

    // Block read / write (element size in bytes); return the element count transferred.
    pub fn fread(ptr: *mut void, size: usize, count: usize, stream: *mut FILE) usize;
    pub fn fwrite(ptr: *const void, size: usize, count: usize, stream: *mut FILE) usize;

    // Character / line I/O. `fgetc`/`getchar` return the byte or -1 (EOF); `fgets` returns null at EOF.
    pub fn fgetc(stream: *mut FILE) i32;
    pub fn fputc(c: i32, stream: *mut FILE) i32;
    pub fn fputs(s: *const char, stream: *mut FILE) i32;
    pub fn fgets(buf: *mut char, size: i32, stream: *mut FILE) *mut char;
    pub fn getchar() i32;
    pub fn putchar(c: i32) i32;
    pub fn puts(s: *const char) i32;
    pub fn perror(prefix: *const char) void;

    // Positioning and status.
    pub fn fseek(stream: *mut FILE, offset: i64, whence: i32) i32;
    pub fn ftell(stream: *mut FILE) i64;
    pub fn rewind(stream: *mut FILE) void;
    pub fn feof(stream: *mut FILE) i32;
    pub fn ferror(stream: *mut FILE) i32;

    // Filesystem.
    pub fn remove(path: *const char) i32;
    pub fn rename(from: *const char, to: *const char) i32;

    // Formatted I/O (C variadic): the format string drives the trailing argument list. `snprintf` is the
    // bounds-checked formatter (writes at most `size` bytes incl. the NUL); the `*scanf` family reads.
    pub fn printf(fmt: *const char, ...) i32;
    pub fn fprintf(stream: *mut FILE, fmt: *const char, ...) i32;
    pub fn snprintf(buf: *mut char, size: usize, fmt: *const char, ...) i32;
    pub fn sscanf(s: *const char, fmt: *const char, ...) i32;
    pub fn scanf(fmt: *const char, ...) i32;
    pub fn fscanf(stream: *mut FILE, fmt: *const char, ...) i32;

    // Runtime helpers for C's standard stream macros/globals.
    pub fn __sc_stdin() *mut FILE;
    pub fn __sc_stdout() *mut FILE;
    pub fn __sc_stderr() *mut FILE;
}

// `fseek` origins.
pub const SEEK_SET: i32 = 0;
pub const SEEK_CUR: i32 = 1;
pub const SEEK_END: i32 = 2;

// An owning file handle: closed exactly once, automatically, when it goes out of scope (`Free`).
pub struct File {
    handle: *mut FILE,
}

extend File {
    // Open `path` with a C `fopen` mode ("r", "w", "a", "rb", ...). `None` if the file cannot be opened.
    pub fn open(path: &mut String, mode: &mut String) Option<File> {
        let h = unsafe c_fopen(path.cstr(), mode.cstr());
        if h == null {
            return Option::<File>::None;
        }
        return Option::<File>::Some(File { handle: h });
    }

    // Append `text`'s bytes to the file; returns the number of bytes written.
    pub fn write_str(self: &mut File, text: &String) usize {
        return unsafe fwrite(text.as_ptr(), 1, text.len(), self.handle);
    }

    // Read the entire remaining contents into a new owned string.
    pub fn read_all(self: &mut File) String {
        let mut out = String::new();
        let mut c = unsafe fgetc(self.handle);
        while c >= 0 {
            out.push_byte(c as u8);
            c = unsafe fgetc(self.handle);
        }
        return out;
    }

    // Flush buffered writes to the OS. Returns 0 on success.
    pub fn flush(self: &mut File) i32 {
        return unsafe fflush(self.handle);
    }

    // Close now, idempotently. Also runs automatically via `Free`.
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
    fn write(self: &mut File, bytes: []u8) usize {
        return unsafe fwrite(bytes.as_ptr(), 1, bytes.len(), self.handle);
    }
}

// Open `path` with a C `fopen` mode ("r", "w", "a", "rb", ...), returning the raw handle (`null` on
// failure) for callers that manage `fclose` themselves. Both args are NUL-terminated into temporaries.
pub fn fopen(path: str, mode: str) *mut FILE {
    let mut p = String::from_str(path);
    let mut m = String::from_str(mode);
    return unsafe c_fopen(p.cstr(), m.cstr());
}

pub fn stdin() *mut FILE {
    return unsafe __sc_stdin();
}
pub fn stdout() *mut FILE {
    return unsafe __sc_stdout();
}
pub fn stderr() *mut FILE {
    return unsafe __sc_stderr();
}

// Windows opens the standard streams in text mode, which writes "\n" as "\r\n" and folds "\r\n" to "\n"
// on read; a byte-counted protocol needs the raw bytes. Returns false when the switch fails. POSIX
// streams have no text mode, so elsewhere this is a no-op.
@platform(windows)
extern "C" "io.h" {
    fn _setmode(fd: i32, mode: i32) i32;
    fn _fileno(stream: *mut FILE) i32;
}

@platform(windows)
pub fn set_binary(stream: *mut FILE) bool {
    let fd = unsafe _fileno(stream);
    return unsafe _setmode(fd, 0x8000) != -1; // _O_BINARY
}

@platform(!windows)
pub const fn set_binary(_stream: *mut FILE) bool {
    return true;
}
