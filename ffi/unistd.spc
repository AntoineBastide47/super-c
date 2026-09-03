// FFI bindings for <unistd.h>. Import with `import unistd;`. Every call site requires `unsafe`.
// The block names its backing header, which is what gets `<unistd.h>` included in the emitted C: it is not
// one of the standard headers the runtime prologue carries, so without this the declarations are missing
// and every call compiles as an implicit declaration (an error under C99 and later).

extern "C" "unistd.h" {
    /// read(2): bytes read, 0 at EOF, -1 and errno.
    pub fn read(fd: i32, buf: *mut void, count: usize) isize;
    /// write(2): bytes written (may be short), -1 and errno.
    pub fn write(fd: i32, buf: *const void, count: usize) isize;
    /// close(2); 0 or -1 and errno.
    pub fn close(fd: i32) i32;
    /// Flush this file's writes all the way to the device and wait for it. The blocking syscall that
    /// blocks: a page-cache write returns immediately, this does not.
    pub fn fsync(fd: i32) i32;
    /// Create a pipe: `fds[0]` read end, `fds[1]` write end; 0 or -1.
    pub fn pipe(fds: *mut i32) i32;
    /// Duplicate a descriptor onto the lowest free number; -1 on failure.
    pub fn dup(fd: i32) i32;
    /// Duplicate `oldfd` onto `newfd`, closing `newfd` first; -1 on failure.
    pub fn dup2(oldfd: i32, newfd: i32) i32;

    /// This process's id.
    pub fn getpid() i32;
    /// The parent process's id.
    pub fn getppid() i32;
    /// Fork: 0 in the child, the child's pid in the parent, -1 on failure.
    pub fn fork() i32;
    /// Replace the process image, PATH-searching `file`; returns only on failure (-1).
    pub fn execvp(file: *const char, argv: *const *const char) i32;

    /// Change the working directory; 0 or -1.
    pub fn chdir(path: *const char) i32;
    /// Working directory into `buf`; `buf`, or null when `size` is too small.
    pub fn getcwd(buf: *mut char, size: usize) *mut char;
    /// Sleep whole seconds; the seconds left if interrupted.
    pub fn sleep(seconds: u32) u32;
    /// Sleep microseconds; 0 or -1.
    pub fn usleep(usec: u32) i32;
}
