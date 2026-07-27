#ifndef SC_DRIVER_SHIM_H
#define SC_DRIVER_SHIM_H

/* Platform glue for the self-hosted super-c driver: the handful of things that need C struct/macro
   access or process-global state a `fn main() i32` (which maps onto `int main(void)`) cannot reach. */

const char *sc_dirent_name(void *entry);             /* ((struct dirent *)entry)->d_name */
int sc_stat_isdir(const char *path);                 /* 1 dir, 0 not, -1 on stat failure */
int sc_dirent_isdir(void *entry);                    /* readdir d_type: 1 dir, 0 not, -1 unknown */
int sc_same_file(const char *a, const char *b);      /* 1 same file (POSIX dev+ino / Win32 file id), 0 not, -1 on failure */
int sc_wifexited(int status);                        /* WIFEXITED(status) as 0/1 */
int sc_wexitstatus(int status);                      /* WEXITSTATUS(status) */
char *sc_realpath(const char *path, char *resolved); /* realpath(3) */
int sc_exe_path(char *buf, unsigned size);           /* absolute path of the running binary; 0 on success */
int sc_getpid(void);                                 /* getpid(); for unique temp paths */
int sc_host_platform(void);                          /* build target: 0 windows, 1 macos, 2 linux */

int sc_chdir(const char *path);   /* chdir / _chdir; 0 on success */
int sc_mkdir(const char *path);   /* mkdir(path, 0775); ignores EEXIST at the caller */
int sc_rmdir(const char *path);   /* rmdir(path) */
int sc_unlink(const char *path);  /* unlink(path) */
void *sc_opendir(const char *path);
void *sc_readdir(void *dir);      /* the next struct dirent *, or NULL */
int sc_closedir(void *dir);

#include <stdint.h>

long long sc_mtime(const char *path); /* mtime seconds; 0 if missing */
int sc_ncpu(void);                    /* online core count; >= 1 */
long long sc_ticks_ms(void);          /* monotonic milliseconds (build-phase timing) */
long long sc_spawn(const char *cmd);  /* start cmd via the shell, no wait; pid/handle or -1 */
int sc_wait_any(const int64_t *pids, int n, int *code); /* index of the first child to exit; -1 on error */
int sc_rename(const char *from, const char *to); /* rename(2); replaces an existing target on Windows too */
int sc_setenv(const char *name, const char *value); /* setenv(3) overwrite / _putenv_s */

/* Run `cmd` to completion and return its exit code (-1 if it could not be started or did not exit
   normally). This is the portable stand-in for `system()` plus shell redirection: the test harnesses use
   it so their commands contain no shell syntax at all, which is what lets them run on Windows.
     in_path   NULL: no stdin (the null device)            else: read stdin from this file
     out_path  NULL: discard stdout                        else: truncate + write stdout to this file
     err_path  NULL: merge stderr into stdout ("2>&1")     else: truncate + write stderr to this file
     env       NULL/"": inherit                            else: space-separated NAME=VALUE for the child
   POSIX runs `cmd` through /bin/sh (word splitting and quoting are the shell's); Windows hands the same
   line to CreateProcess, which applies its own quoting rules -- so a command must use double quotes and no
   operators to mean the same thing on both. */
int sc_run(const char *cmd, const char *in_path, const char *out_path, const char *err_path, const char *env);

/* `sc_run` for a program whose output belongs on OUR stdout/stderr: same command-line rules, but the child
   inherits this process's standard handles instead of redirecting them. Returns its exit code, or -1 if it
   could not be started. Use this rather than `system()` to run a program at a path we just built: on
   Windows `system()` is cmd.exe, which strips the outer quotes off its `/c` line and then splits the
   program name at the first '/', so "build/raw-test/__tests.exe" comes back as `'build' is not
   recognized`. */
int sc_exec(const char *cmd);

int sc_mkdir_p(const char *path); /* mkdir -p: creates every missing component; 0 on success */
int sc_rm_rf(const char *path);   /* rm -rf: recursive delete, 0 if the path is gone afterwards */
const char *sc_tmpdir(void);      /* the system temp directory, no trailing separator */

#endif
