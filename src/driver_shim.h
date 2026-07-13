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

int sc_mkdir(const char *path);   /* mkdir(path, 0775); ignores EEXIST at the caller */
int sc_rmdir(const char *path);   /* rmdir(path) */
int sc_unlink(const char *path);  /* unlink(path) */
void *sc_opendir(const char *path);
void *sc_readdir(void *dir);      /* the next struct dirent *, or NULL */
int sc_closedir(void *dir);

long long sc_mtime(const char *path); /* mtime seconds; 0 if missing */
int sc_ncpu(void);                    /* online core count; >= 1 */
void *sc_popen(const char *cmd);      /* popen(cmd, "r") */
int sc_pclose(void *f);               /* waits; returns the exit code */
int sc_rename(const char *from, const char *to); /* rename(2); replaces an existing target on Windows too */
int sc_setenv(const char *name, const char *value); /* setenv(3) overwrite / _putenv_s */

#endif
