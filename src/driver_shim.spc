// Platform glue shared by the driver (main) and the loader: the handful of things that need C struct/macro
// access or process-global state a `fn main() i32` (which maps onto `int main(void)`) cannot reach.
// The backing "driver_shim.h" resolves next to this file; its same-stem sibling driver_shim.c is
// discovered and compiled automatically.
extern "C" "driver_shim.h" {
    pub fn sc_dirent_name(entry: *mut void) *const char;
    pub fn sc_stat_isdir(path: *const char) i32;
    pub fn sc_dirent_isdir(entry: *mut void) i32;
    pub fn sc_same_file(a: *const char, b: *const char) i32;
    pub fn sc_wifexited(status: i32) i32;
    pub fn sc_wexitstatus(status: i32) i32;
    pub fn sc_realpath(path: *const char, resolved: *mut char) *mut char;
    pub fn sc_exe_path(buf: *mut char, size: u32) i32;
    pub fn sc_getpid() i32;
    pub fn sc_host_platform() i32;
    pub fn sc_mkdir(path: *const char) i32;
    pub fn sc_rmdir(path: *const char) i32;
    pub fn sc_unlink(path: *const char) i32;
    pub fn sc_opendir(path: *const char) *mut void;
    pub fn sc_readdir(dir: *mut void) *mut void;
    pub fn sc_closedir(dir: *mut void) i32;
    pub fn sc_mtime(path: *const char) i64;
    pub fn sc_ncpu() i32;
    pub fn sc_popen(cmd: *const char) *mut void;
    pub fn sc_pclose(f: *mut void) i32;
    pub fn sc_rename(from: *const char, to: *const char) i32;
    pub fn sc_setenv(name: *const char, value: *const char) i32;
}
