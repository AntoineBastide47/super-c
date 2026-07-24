// FFI bindings for common filesystem and directory APIs. Import with `import filesystem;`. Every call
// site requires `unsafe`.
// Struct layouts such as `stat` and `dirent` vary by platform, so APIs that fill or return those structs
// use `*mut void` / `*const void`; provide platform-specific layout glue when you need field access.

extern "C" {
    pub type DIR;

    pub fn stat(path: *const char, buf: *mut void) i32;
    pub fn lstat(path: *const char, buf: *mut void) i32;
    pub fn fstat(fd: i32, buf: *mut void) i32;

    pub fn mkdir(path: *const char, mode: u32) i32;
    pub fn rmdir(path: *const char) i32;
    pub fn unlink(path: *const char) i32;
    pub fn chmod(path: *const char, mode: u32) i32;
    pub fn chown(path: *const char, owner: u32, group: u32) i32;

    pub fn opendir(path: *const char) *mut DIR;
    pub fn readdir(dir: *mut DIR) *mut void;
    pub fn closedir(dir: *mut DIR) i32;
    pub fn rewinddir(dir: *mut DIR) void;
}
