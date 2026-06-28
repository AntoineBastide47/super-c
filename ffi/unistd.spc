// FFI bindings for <unistd.h>. Import with `import unistd;`.

extern "C" {
    pub fn read(fd: i32, buf: *mut void, count: usize) isize;
    pub fn write(fd: i32, buf: *const void, count: usize) isize;
    pub fn close(fd: i32) i32;
    pub fn pipe(fds: *mut i32) i32;
    pub fn dup(fd: i32) i32;
    pub fn dup2(oldfd: i32, newfd: i32) i32;

    pub fn getpid() i32;
    pub fn getppid() i32;
    pub fn fork() i32;
    pub fn execvp(file: *const char, argv: *const *const char) i32;

    pub fn chdir(path: *const char) i32;
    pub fn getcwd(buf: *mut char, size: usize) *mut char;
    pub fn sleep(seconds: u32) u32;
    pub fn usleep(usec: u32) i32;
}
