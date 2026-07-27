// FFI bindings for common filesystem and directory APIs. Import with `import filesystem;`. Every call
// site requires `unsafe`.
// Struct layouts such as `stat` and `dirent` vary by platform, so APIs that fill or return those structs
// use `*mut void` / `*const void`; provide platform-specific layout glue when you need field access.
//
// One block per backing header, because that is what gets each header included in the emitted C: none of
// these are among the standard headers the runtime prologue carries, so a single unnamed block would leave
// every declaration missing and each call would compile as an implicit declaration (an error under C99).

extern "C" "sys/stat.h" {
    pub fn stat(path: *const char, buf: *mut void) i32;
    pub fn lstat(path: *const char, buf: *mut void) i32;
    pub fn fstat(fd: i32, buf: *mut void) i32;

    pub fn chmod(path: *const char, mode: u32) i32;
}

// `mkdir` is the one call here whose SIGNATURE differs by platform: the Windows CRT spells it `_mkdir` and
// takes no mode, having no POSIX permission bits to apply. Both targets keep the two-argument POSIX surface
// so calling code stays portable -- on Windows `mode` is accepted and ignored, which is the one semantic
// difference the identical signature hides.
@platform(!windows)
extern "C" "sys/stat.h" {
    pub fn mkdir(path: *const char, mode: u32) i32;
}

@platform(windows)
extern "C" "direct.h" {
    fn _mkdir(path: *const char) i32;
}

@platform(windows)
pub unsafe fn mkdir(path: *const char, _mode: u32) i32 {
    return _mkdir(path);
}

extern "C" "unistd.h" {
    pub fn rmdir(path: *const char) i32;
    pub fn unlink(path: *const char) i32;
    pub fn chown(path: *const char, owner: u32, group: u32) i32;
}

extern "C" "dirent.h" {
    pub type DIR;

    pub fn opendir(path: *const char) *mut DIR;
    pub fn readdir(dir: *mut DIR) *mut void;
    pub fn closedir(dir: *mut DIR) i32;
    pub fn rewinddir(dir: *mut DIR) void;
}
