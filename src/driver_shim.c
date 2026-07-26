/* This file needs POSIX.1-2008 (realpath, readlink, popen, setenv, ...); declare it BEFORE any
   include so a bare `-std=c11` compile (the legacy `super-c build` path) still sees the prototypes
   on glibc -- without this, implicit declarations truncate returned pointers and crash. */
#ifndef _POSIX_C_SOURCE
#  define _POSIX_C_SOURCE 200809L
#endif

#include "driver_shim.h"

#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#if !defined(_WIN32)
#  include <spawn.h>
#endif
#if defined(_WIN32)
#  include <direct.h>  /* _mkdir, _rmdir */
#  include <io.h>      /* _access, _unlink */
#  include <process.h> /* _getpid */
#  include <windows.h>
#else
#  include <sys/wait.h> /* WIFEXITED/WEXITSTATUS */
#endif
#if defined(__APPLE__)
#  include <crt_externs.h>  /* _NSGetArgc/_NSGetArgv */
#  include <mach-o/dyld.h>  /* _NSGetExecutablePath */
#endif

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
#if defined(_WIN32)
  /* mingw's <dirent.h> has no d_type field; report unknown so the caller falls back to stat. */
  (void)entry;
  return -1;
#else
  unsigned char t = ((struct dirent *)entry)->d_type;
  if (t == DT_DIR)
    return 1;
  if (t == DT_UNKNOWN)
    return -1;
  return 0;
#endif
}

/* 1 iff both paths resolve to the same physical file (same device + inode), 0 if not, -1 if either
   can't be stat'd. Ground-truth file identity -- cheaper than realpath (one stat each, no readdir). */
int sc_same_file(const char *a, const char *b) {
#if defined(_WIN32)
  /* mingw's stat() leaves st_ino == 0, so the POSIX dev+ino test below would report ANY two same-volume
     files as identical -- which made load_prelude wrongly dedup std/string.spc against ffi/string.spc and
     drop the whole String module. Use the real Win32 identity (volume serial + 64-bit file index). */
  BY_HANDLE_FILE_INFORMATION ia, ib;
  const DWORD share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
  HANDLE ha = CreateFileA(a, 0, share, NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
  if (ha == INVALID_HANDLE_VALUE)
    return -1;
  HANDLE hb = CreateFileA(b, 0, share, NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
  if (hb == INVALID_HANDLE_VALUE) {
    CloseHandle(ha);
    return -1;
  }
  int ok = GetFileInformationByHandle(ha, &ia) && GetFileInformationByHandle(hb, &ib);
  CloseHandle(ha);
  CloseHandle(hb);
  if (!ok)
    return -1;
  return (ia.dwVolumeSerialNumber == ib.dwVolumeSerialNumber && ia.nFileIndexHigh == ib.nFileIndexHigh &&
          ia.nFileIndexLow == ib.nFileIndexLow)
             ? 1
             : 0;
#else
  struct stat sa, sb;
  if (stat(a, &sa) != 0 || stat(b, &sb) != 0)
    return -1;
  return (sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino) ? 1 : 0;
#endif
}

#if defined(_WIN32)
/* system() returns the child's exit code directly on Windows (no wait-status encoding). */
int sc_wifexited(int status) {
  (void)status;
  return 1;
}
int sc_wexitstatus(int status) { return status; }
#else
int sc_wifexited(int status) { return WIFEXITED(status) ? 1 : 0; }
int sc_wexitstatus(int status) { return WEXITSTATUS(status); }
#endif

char *sc_realpath(const char *path, char *resolved) {
#if defined(_WIN32)
  if (_access(path, 0) != 0)
    return NULL;
  char *const r = _fullpath(resolved, path, 4096);
  if (r)
    for (char *p = resolved; *p; p++)
      if (*p == '\\')
        *p = '/';
  return r;
#else
  return realpath(path, resolved);
#endif
}

int sc_exe_path(char *buf, unsigned size) {
#if defined(_WIN32)
  DWORD n = GetModuleFileNameA(NULL, buf, (DWORD)size);
  if (n == 0 || n >= (DWORD)size)
    return -1;
  for (char *p = buf; *p; p++)
    if (*p == '\\')
      *p = '/';
  return 0;
#elif defined(__APPLE__)
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

int sc_getpid(void) {
#if defined(_WIN32)
  return (int)_getpid();
#else
  return (int)getpid();
#endif
}

/* Host/target platform index, resolved by the compiler that builds this shim: 0 windows, 1 macos, 2 linux.
   The self-hosted driver reads it as the default `--target`, so @platform gating matches the native build. */
int sc_host_platform(void) {
#if defined(_WIN32)
  return 0;
#elif defined(__APPLE__)
  return 1;
#else
  return 2;
#endif
}

int sc_chdir(const char *path) {
#if defined(_WIN32)
  return _chdir(path);
#else
  return chdir(path);
#endif
}
int sc_mkdir(const char *path) {
#if defined(_WIN32)
  return _mkdir(path);
#else
  return mkdir(path, 0775);
#endif
}
int sc_rmdir(const char *path) {
#if defined(_WIN32)
  return _rmdir(path);
#else
  return rmdir(path);
#endif
}
int sc_unlink(const char *path) {
#if defined(_WIN32)
  return _unlink(path);
#else
  return unlink(path);
#endif
}
void *sc_opendir(const char *path) { return (void *)opendir(path); }
void *sc_readdir(void *dir) { return (void *)readdir((DIR *)dir); }
int sc_closedir(void *dir) { return closedir((DIR *)dir); }

/* ---- build-system helpers (build.toml engine) ---- */

/* File modification time in seconds; 0 when the file does not exist. */
long long sc_mtime(const char *path) {
#if defined(_WIN32)
  struct _stat64 st;
  if (_stat64(path, &st) != 0)
    return 0;
  return (long long)st.st_mtime;
#else
  struct stat st;
  if (stat(path, &st) != 0)
    return 0;
  return (long long)st.st_mtime;
#endif
}

/* Online core count; 4 when it cannot be determined. */
int sc_ncpu(void) {
#if defined(_WIN32)
  const char *n = getenv("NUMBER_OF_PROCESSORS");
  int v = n ? atoi(n) : 0;
  return v > 0 ? v : 4;
#elif defined(__APPLE__)
  /* _SC_NPROCESSORS_ONLN is hidden by strict _POSIX_C_SOURCE on macOS, and <sys/sysctl.h> does not
     compile under it (u_int); declare the stable libc entry point directly. */
  extern int sysctlbyname(const char *, void *, size_t *, void *, size_t);
  int v = 0;
  size_t len = sizeof v;
  if (sysctlbyname("hw.ncpu", &v, &len, NULL, 0) != 0 || v < 1)
    return 4;
  return v;
#else
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  return n > 0 ? (int)n : 4;
#endif
}

/* Monotonic milliseconds for build-phase timing. */
long long sc_ticks_ms(void) {
#if defined(_WIN32)
  return (long long)GetTickCount64();
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

/* Start `cmd` through the shell without waiting (redirections live inside the string); the returned
   pid/handle is claimed by sc_wait_any. -1 on spawn failure. */
long long sc_spawn(const char *cmd) {
#if defined(_WIN32)
  const char *sh = getenv("COMSPEC");
  if (!sh)
    sh = "cmd.exe";
  size_t n = strlen(sh) + strlen(cmd) + 5;
  char *line = malloc(n);
  if (!line)
    return -1;
  snprintf(line, n, "%s /c %s", sh, cmd);
  STARTUPINFOA si;
  PROCESS_INFORMATION pi;
  memset(&si, 0, sizeof si);
  si.cb = sizeof si;
  BOOL ok = CreateProcessA(NULL, line, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);
  free(line);
  if (!ok)
    return -1;
  CloseHandle(pi.hThread);
  return (long long)(intptr_t)pi.hProcess;
#else
  extern char **environ;
  pid_t pid;
  char *argv[] = {"sh", "-c", (char *)cmd, NULL};
  if (posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, environ) != 0)
    return -1;
  return (long long)pid;
#endif
}

/* Wait until ANY of the n spawned children exits: returns its index and stores its exit code, so the
   scheduler refills the freed slot immediately instead of draining in FIFO order. -1 on error. */
int sc_wait_any(const int64_t *pids, int n, int *code) {
#if defined(_WIN32)
  HANDLE hs[MAXIMUM_WAIT_OBJECTS];
  if (n > MAXIMUM_WAIT_OBJECTS)
    n = MAXIMUM_WAIT_OBJECTS;
  for (int i = 0; i < n; i++)
    hs[i] = (HANDLE)(intptr_t)pids[i];
  DWORD w = WaitForMultipleObjects((DWORD)n, hs, FALSE, INFINITE);
  if (w >= (DWORD)n)
    return -1;
  DWORD ec = 1;
  GetExitCodeProcess(hs[w], &ec);
  CloseHandle(hs[w]);
  *code = (int)ec;
  return (int)w;
#else
  for (;;) {
    int st = 0;
    pid_t p = waitpid(-1, &st, 0);
    if (p < 0)
      return -1;
    for (int i = 0; i < n; i++)
      if ((int64_t)p == (int64_t)pids[i]) {
        *code = WIFEXITED(st) ? WEXITSTATUS(st) : 1;
        return i;
      }
    /* an unrelated child (none are expected during the compile phase): keep waiting */
  }
#endif
}

/* Atomic-ish rename for the build system's link-then-swap; Windows rename() refuses to replace. */
int sc_rename(const char *from, const char *to) {
#if defined(_WIN32)
  _unlink(to);
#endif
  return rename(from, to);
}

/* Environment write for the build system (SUPERC for the test harness, SC_CMD for nested manifest-command
   invocations). */
int sc_setenv(const char *name, const char *value) {
#if defined(_WIN32)
  return _putenv_s(name, value);
#else
  return setenv(name, value, 1);
#endif
}

/* ---- portable process + filesystem helpers for the test harnesses ---------------------------------- */
/* strdup is POSIX, not C11, and the Windows spelling differs; one copy here keeps both legs identical. */
static char *sc_strdup_local(const char *s) {
  size_t n = strlen(s) + 1;
  char *p = (char *)malloc(n);
  if (p)
    memcpy(p, s, n);
  return p;
}

/* These exist so tests/cli_harness.spc and tests/harness.spc need no shell at all: every construct they
   used to write in POSIX sh -- redirection, `mkdir -p`, `rm -rf`, an env prefix -- is a parameter here.
   That is what makes the suite run on Windows, where cmd.exe speaks none of it. */

/* One NAME=VALUE assignment applied around a child: the value is set before the spawn and the previous
   one (or its absence) restored afterwards, so the parent's environment is unchanged. */
typedef struct {
  char name[64];
  char *old;
  int had;
} sc_env_save;

static int sc_env_apply(const char *env, sc_env_save *saves, int max) {
  int n = 0;
  const char *p = env;
  while (p && *p && n < max) {
    while (*p == ' ' || *p == '\t')
      p++;
    const char *eq = strchr(p, '=');
    if (!eq)
      break;
    const char *end = eq;
    while (*end && *end != ' ' && *end != '\t')
      end++;
    size_t nl = (size_t)(eq - p);
    if (nl == 0 || nl >= sizeof saves[0].name)
      break;
    memcpy(saves[n].name, p, nl);
    saves[n].name[nl] = 0;
    const char *prev = getenv(saves[n].name);
    saves[n].had = prev != 0;
    saves[n].old = prev ? sc_strdup_local(prev) : 0;
    size_t vl = (size_t)(end - eq - 1);
    char *val = (char *)malloc(vl + 1);
    if (!val)
      break;
    memcpy(val, eq + 1, vl);
    val[vl] = 0;
    sc_setenv(saves[n].name, val);
    free(val);
    n++;
    p = end;
  }
  return n;
}

static void sc_env_restore(sc_env_save *saves, int n) {
  for (int i = 0; i < n; i++) {
    if (saves[i].had && saves[i].old)
      sc_setenv(saves[i].name, saves[i].old);
    else
      sc_setenv(saves[i].name, "");
    free(saves[i].old);
  }
}

int sc_mkdir_p(const char *path) {
  char buf[4096];
  size_t n = strlen(path);
  if (n == 0 || n >= sizeof buf)
    return -1;
  memcpy(buf, path, n + 1);
  for (size_t i = 1; i < n; i++) {
    if (buf[i] == '/' || buf[i] == '\\') {
      const char sep = buf[i];
      buf[i] = 0;
      if (sc_stat_isdir(buf) != 1)
        sc_mkdir(buf);
      buf[i] = sep;
    }
  }
  if (sc_stat_isdir(buf) == 1)
    return 0;
  sc_mkdir(buf);
  return sc_stat_isdir(buf) == 1 ? 0 : -1;
}

int sc_rm_rf(const char *path) {
  if (sc_stat_isdir(path) == 1) {
    void *d = sc_opendir(path);
    if (d) {
      void *e;
      while ((e = sc_readdir(d)) != 0) {
        const char *nm = sc_dirent_name(e);
        if (!strcmp(nm, ".") || !strcmp(nm, ".."))
          continue;
        char child[4096];
        snprintf(child, sizeof child, "%s/%s", path, nm);
        sc_rm_rf(child);
      }
      sc_closedir(d);
    }
    sc_rmdir(path);
  } else {
    sc_unlink(path);
  }
  return sc_stat_isdir(path) == 1 ? -1 : 0;
}

const char *sc_tmpdir(void) {
  static char buf[4096];
  if (buf[0])
    return buf;
#if defined(_WIN32)
  DWORD n = GetTempPathA((DWORD)sizeof buf, buf);
  if (n == 0 || n >= sizeof buf) {
    snprintf(buf, sizeof buf, "%s", ".");
    return buf;
  }
  while (n > 1 && (buf[n - 1] == '\\' || buf[n - 1] == '/'))
    buf[--n] = 0; /* no trailing separator: callers join with '/' */
#else
  const char *t = getenv("TMPDIR");
  if (!t || !*t)
    t = "/tmp";
  snprintf(buf, sizeof buf, "%s", t);
  size_t n = strlen(buf);
  while (n > 1 && buf[n - 1] == '/')
    buf[--n] = 0;
#endif
  return buf;
}

#if defined(_WIN32)
static HANDLE sc_open_for_child(const char *path, int write) {
  SECURITY_ATTRIBUTES sa;
  memset(&sa, 0, sizeof sa);
  sa.nLength = sizeof sa;
  sa.bInheritHandle = TRUE;
  const char *name = path ? path : "NUL";
  return CreateFileA(name, write ? GENERIC_WRITE : GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                     write ? CREATE_ALWAYS : OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
}

int sc_run(const char *cmd, const char *in_path, const char *out_path, const char *err_path, const char *env) {
  sc_env_save saves[8];
  const int nenv = env ? sc_env_apply(env, saves, 8) : 0;
  HANDLE hin = sc_open_for_child(in_path, 0);
  HANDLE hout = sc_open_for_child(out_path, 1);
  HANDLE herr = err_path ? sc_open_for_child(err_path, 1) : INVALID_HANDLE_VALUE;
  if (herr == INVALID_HANDLE_VALUE && !err_path) /* merge stderr into stdout */
    DuplicateHandle(GetCurrentProcess(), hout, GetCurrentProcess(), &herr, 0, TRUE, DUPLICATE_SAME_ACCESS);
  STARTUPINFOA si;
  PROCESS_INFORMATION pi;
  memset(&si, 0, sizeof si);
  si.cb = sizeof si;
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = hin;
  si.hStdOutput = hout;
  si.hStdError = herr;
  size_t n = strlen(cmd) + 1;
  char *line = (char *)malloc(n);
  int rc = -1;
  if (line) {
    memcpy(line, cmd, n);
    if (CreateProcessA(NULL, line, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
      WaitForSingleObject(pi.hProcess, INFINITE);
      DWORD code = 1;
      GetExitCodeProcess(pi.hProcess, &code);
      rc = (int)code;
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
    }
    free(line);
  }
  if (hin != INVALID_HANDLE_VALUE)
    CloseHandle(hin);
  if (hout != INVALID_HANDLE_VALUE)
    CloseHandle(hout);
  if (herr != INVALID_HANDLE_VALUE)
    CloseHandle(herr);
  sc_env_restore(saves, nenv);
  return rc;
}
#else
int sc_run(const char *cmd, const char *in_path, const char *out_path, const char *err_path, const char *env) {
  extern char **environ;
  sc_env_save saves[8];
  const int nenv = env ? sc_env_apply(env, saves, 8) : 0;
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_addopen(&fa, 0, in_path ? in_path : "/dev/null", O_RDONLY, 0);
  posix_spawn_file_actions_addopen(&fa, 1, out_path ? out_path : "/dev/null", O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (err_path)
    posix_spawn_file_actions_addopen(&fa, 2, err_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  else
    posix_spawn_file_actions_adddup2(&fa, 1, 2); /* 2>&1 */
  char *argv[] = {(char *)"sh", (char *)"-c", (char *)cmd, NULL};
  pid_t pid;
  int rc = -1;
  if (posix_spawn(&pid, "/bin/sh", &fa, NULL, argv, environ) == 0) {
    int st = 0;
    while (waitpid(pid, &st, 0) < 0) {
    }
    rc = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
  }
  posix_spawn_file_actions_destroy(&fa);
  sc_env_restore(saves, nenv);
  return rc;
}
#endif
