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
    /// Instruction set baked in when the shim is compiled: 0 x86_64, 1 aarch64, 2 wasm32, -1 other
    /// (the default --arch).
    pub fn sc_host_arch() i32;
    pub fn sc_chdir(path: *const char) i32;
    pub fn sc_mkdir(path: *const char) i32;
    pub fn sc_rmdir(path: *const char) i32;
    pub fn sc_unlink(path: *const char) i32;
    pub fn sc_chmod_rw(path: *const char) i32;
    pub fn sc_trace_install() void;
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
    /// Start argv[0..] (NULL-terminated pointer array) WITHOUT a shell: argv[0] is PATH-searched and
    /// every later entry reaches the child verbatim -- spaces, quotes, and non-ASCII bytes included.
    /// A non-null `out_path` truncate-redirects the child's stdout+stderr into it; null inherits.
    /// Returns a pid/handle for sc_wait_any/sc_try_wait/sc_waitpid, or -1 on spawn failure.
    pub fn sc_spawn_argv(argv: *const *const char, out_path: *const char) i64;
    /// sc_spawn_argv + wait: the child's exit code, or -1 on spawn/wait failure.
    pub fn sc_exec_argv(argv: *const *const char, out_path: *const char) i32;
    /// Block until any of the `n` children exits: returns its index into `pids` and stores its exit
    /// code in `code`; -1 on wait error.
    pub fn sc_wait_any(pids: *const i64, n: i32, code: *mut i32) i32;
    /// Non-blocking `sc_wait_any`: index of an already-exited child, or -1 when none has exited yet.
    /// Never reaps a pid outside `pids`, so it is safe while the parallel emit workers are alive.
    pub fn sc_try_wait(pids: *const i64, n: i32, code: *mut i32) i32;
    /// fork() for the parallel emit workers; -1 where unsupported (Windows) selects the serial path.
    pub fn sc_fork() i64;
    /// Anonymous pipe: fds[0] read end, fds[1] write end. -1 on failure or Windows.
    pub fn sc_pipe(fds: *mut i32) i32;
    /// Read exactly `n` bytes (short only at EOF), so completion packets never tear; -1 on error.
    pub fn sc_fd_read(fd: i32, buf: *mut void, n: i32) i32;
    /// Write all `n` bytes; -1 on error.
    pub fn sc_fd_write(fd: i32, buf: *const void, n: i32) i32;
    pub fn sc_fd_close(fd: i32) i32;
    /// `_exit()`: no atexit handlers, no stream flushing. Emit workers end here so the inherited
    /// leak registry and buffered stdio are not replayed once per child.
    pub fn sc_exit_now(code: i32);
    /// 1 when this binary is ASan-instrumented: fork() copy-on-write-faults the whole shadow per
    /// child there, costing more than the parallel emit saves, so such a binary stays serial.
    pub fn sc_asan() i32;
    /// Wait for ONE specific child; its exit code via `code`. 0 on success, -1 on error/Windows.
    pub fn sc_waitpid(pid: i64, code: *mut i32) i32;
    /// rename() that also replaces an existing destination on Windows -- including one that is a RUNNING
    /// executable, which Windows will not delete but will let us rename aside (parked as `<to>.old`).
    pub fn sc_rename(from: *const char, to: *const char) i32;
    /// Make `path` executable (0755); a no-op on Windows, which goes by extension.
    pub fn sc_chmod_exec(path: *const char) i32;
    /// Set `name`=`value` in this process's environment, overwriting any existing value.
    pub fn sc_setenv(name: *const char, value: *const char) i32;

    /// Run `cmd` to completion and return its exit code (-1 if it could not start). The portable stand-in
    /// for `system()` plus shell redirection -- the test harnesses use it so their command strings hold no
    /// shell syntax, which is what makes the suite run on Windows as well.
    /// `in_path` null reads nothing; `out_path` null discards stdout; `err_path` null merges stderr into
    /// stdout; `env` is space-separated `NAME=VALUE` applied to the child only.
    pub fn sc_run(
        cmd: *const char,
        in_path: *const char,
        out_path: *const char,
        err_path: *const char,
        env: *const char,
    ) i32;
    /// `sc_run` for a program whose output belongs on our own stdout/stderr (it inherits them instead of
    /// being redirected); returns its exit code, or -1 if it could not start. Always use this, never
    /// `system()`, to run a binary at a path we built: on Windows `system()` is cmd.exe, which drops the
    /// outer quotes of its `/c` line and then splits the program name at the first '/'.
    pub fn sc_exec(cmd: *const char) i32;
    /// `mkdir -p`: create every missing component of `path`. 0 on success.
    pub fn sc_mkdir_p(path: *const char) i32;
    /// `rm -rf`: delete `path` and anything under it. 0 once it is gone.
    pub fn sc_rm_rf(path: *const char) i32;
    /// The system temp directory, without a trailing separator.
    pub fn sc_tmpdir() *const char;
}
