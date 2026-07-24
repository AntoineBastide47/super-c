// Platform glue shared by the driver (main) and the loader: the handful of things that need C struct/macro
// access or process-global state a `fn main() i32` (which maps onto `int main(void)`) cannot reach.
// The backing "driver_shim.h" resolves next to this file; its same-stem sibling driver_shim.c is
// discovered and compiled automatically.
extern "C" "driver_shim.h" {
    /// Name of a `sc_readdir` entry; borrows the entry, invalidated by the next read on the same stream.
    pub fn sc_dirent_name(entry: *mut void) *const char;
    /// 1 directory, 0 other file kind, -1 when `path` cannot be stat'd.
    pub fn sc_stat_isdir(path: *const char) i32;
    /// d_type of a `sc_readdir` entry: 1 dir, 0 non-dir, -1 unknown (caller must stat; always -1 on Windows).
    pub fn sc_dirent_isdir(entry: *mut void) i32;
    /// 1 iff both paths resolve to the same physical file, 0 if distinct, -1 if either cannot be stat'd.
    pub fn sc_same_file(a: *const char, b: *const char) i32;
    /// WIFEXITED as 0/1 on a wait status; always 1 on Windows, where system() returns the exit code directly.
    pub fn sc_wifexited(status: i32) i32;
    /// WEXITSTATUS of a wait status (identity on Windows).
    pub fn sc_wexitstatus(status: i32) i32;
    /// Absolute path of `path` written into `resolved` ('\' normalized to '/' on Windows); null on failure.
    /// Safety: `resolved` must hold at least 4096 bytes.
    pub fn sc_realpath(path: *const char, resolved: *mut char) *mut char;
    /// Running executable's path into `buf`: 0 on success, nonzero on failure or truncation.
    pub fn sc_exe_path(buf: *mut char, size: u32) i32;
    pub fn sc_getpid() i32;
    /// Platform index baked in when the shim is compiled: 0 windows, 1 macos, 2 linux (the default --target).
    pub fn sc_host_platform() i32;
    pub fn sc_chdir(path: *const char) i32;
    pub fn sc_mkdir(path: *const char) i32;
    pub fn sc_rmdir(path: *const char) i32;
    pub fn sc_unlink(path: *const char) i32;
    pub fn sc_opendir(path: *const char) *mut void;
    pub fn sc_readdir(dir: *mut void) *mut void;
    pub fn sc_closedir(dir: *mut void) i32;
    /// Modification time in seconds; 0 when the file does not exist -- the build engine's staleness sentinel.
    pub fn sc_mtime(path: *const char) i64;
    /// Online core count; 4 when it cannot be determined.
    pub fn sc_ncpu() i32;
    /// Monotonic milliseconds (never wall clock).
    pub fn sc_ticks_ms() i64;
    /// Start `cmd` through the shell without waiting (redirections go inside the string); returns a
    /// pid/handle that must be claimed by `sc_wait_any`, or -1 on spawn failure.
    pub fn sc_spawn(cmd: *const char) i64;
    /// Block until any of the `n` children exits: returns its index into `pids` and stores its exit
    /// code in `code`; -1 on wait error.
    pub fn sc_wait_any(pids: *const i64, n: i32, code: *mut i32) i32;
    /// rename() that also replaces an existing destination on Windows (unlinks `to` first).
    pub fn sc_rename(from: *const char, to: *const char) i32;
    /// Set `name`=`value` in this process's environment, overwriting any existing value.
    pub fn sc_setenv(name: *const char, value: *const char) i32;
}
