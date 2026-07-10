#ifndef SC_DRIVER_SHIM_H
#define SC_DRIVER_SHIM_H

/* Platform glue for the self-hosted super-c driver: the handful of things that need C struct/macro
   access or process-global state a `fn main() i32` (which maps onto `int main(void)`) cannot reach. */

int sc_argc(void);                                   /* the process argument count */
char **sc_argv(void);                                /* the process argument vector */
const char *sc_dirent_name(void *entry);             /* ((struct dirent *)entry)->d_name */
int sc_stat_isdir(const char *path);                 /* 1 dir, 0 not, -1 on stat failure */
int sc_dirent_isdir(void *entry);                    /* readdir d_type: 1 dir, 0 not, -1 unknown */
int sc_same_file(const char *a, const char *b);      /* 1 same file (dev+ino), 0 not, -1 stat failure */
int sc_wifexited(int status);                        /* WIFEXITED(status) as 0/1 */
int sc_wexitstatus(int status);                      /* WEXITSTATUS(status) */
char *sc_realpath(const char *path, char *resolved); /* realpath(3) */
int sc_exe_path(char *buf, unsigned size);           /* absolute path of the running binary; 0 on success */
int sc_getpid(void);                                 /* getpid(); for unique temp paths */

int sc_mkdir(const char *path);   /* mkdir(path, 0775); ignores EEXIST at the caller */
int sc_rmdir(const char *path);   /* rmdir(path) */
int sc_unlink(const char *path);  /* unlink(path) */
void *sc_opendir(const char *path);
void *sc_readdir(void *dir);      /* the next struct dirent *, or NULL */
int sc_closedir(void *dir);

#endif
