// FFI bindings for <fcntl.h>. Import with `import fcntl;`.

extern "C" {
    pub fn open(path: *const char, flags: i32, ...) i32;
    pub fn creat(path: *const char, mode: u32) i32;
    pub fn fcntl(fd: i32, cmd: i32, ...) i32;
}
