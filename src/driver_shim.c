#include "driver_shim.h"

#include <dirent.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#  include <crt_externs.h>  /* _NSGetArgc/_NSGetArgv */
#  include <mach-o/dyld.h>  /* _NSGetExecutablePath */
#endif

int sc_argc(void) {
#if defined(__APPLE__)
  return *_NSGetArgc();
#else
  return 0;
#endif
}

char **sc_argv(void) {
#if defined(__APPLE__)
  return *_NSGetArgv();
#else
  return (char **)0;
#endif
}

const char *sc_dirent_name(void *entry) { return ((struct dirent *)entry)->d_name; }

int sc_stat_isdir(const char *path) {
  struct stat st;
  if (stat(path, &st) != 0)
    return -1;
  return S_ISDIR(st.st_mode) ? 1 : 0;
}

/* DT_DIR/DT_UNKNOWN are BSD/Linux extensions hidden under strict _POSIX_C_SOURCE; their values are a
   stable ABI so define them if the header didn't. (The d_type FIELD itself is present on both platforms.) */
#ifndef DT_UNKNOWN
#  define DT_UNKNOWN 0
#endif
#ifndef DT_DIR
#  define DT_DIR 4
#endif

/* Directory-entry type straight from readdir's d_type: 1 dir, 0 non-dir, -1 unknown (caller must stat). */
int sc_dirent_isdir(void *entry) {
  unsigned char t = ((struct dirent *)entry)->d_type;
  if (t == DT_DIR)
    return 1;
  if (t == DT_UNKNOWN)
    return -1;
  return 0;
}

/* 1 iff both paths resolve to the same physical file (same device + inode), 0 if not, -1 if either
   can't be stat'd. Ground-truth file identity -- cheaper than realpath (one stat each, no readdir). */
int sc_same_file(const char *a, const char *b) {
  struct stat sa, sb;
  if (stat(a, &sa) != 0 || stat(b, &sb) != 0)
    return -1;
  return (sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino) ? 1 : 0;
}

int sc_wifexited(int status) { return WIFEXITED(status) ? 1 : 0; }
int sc_wexitstatus(int status) { return WEXITSTATUS(status); }

char *sc_realpath(const char *path, char *resolved) { return realpath(path, resolved); }

int sc_exe_path(char *buf, unsigned size) {
#if defined(__APPLE__)
  uint32_t sz = size;
  return _NSGetExecutablePath(buf, &sz);
#elif defined(__linux__)
  ssize_t n = readlink("/proc/self/exe", buf, (size_t)size - 1);
  if (n <= 0)
    return -1;
  buf[n] = '\0';
  return 0;
#else
  (void)buf;
  (void)size;
  return -1;
#endif
}

int sc_getpid(void) { return (int)getpid(); }

int sc_mkdir(const char *path) { return mkdir(path, 0775); }
int sc_rmdir(const char *path) { return rmdir(path); }
int sc_unlink(const char *path) { return unlink(path); }
void *sc_opendir(const char *path) { return (void *)opendir(path); }
void *sc_readdir(void *dir) { return (void *)readdir((DIR *)dir); }
int sc_closedir(void *dir) { return closedir((DIR *)dir); }
