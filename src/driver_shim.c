/* This file needs POSIX.1-2008 (realpath, readlink, popen, setenv, ...); declare it BEFORE any
   include so a bare `-std=c11` compile (the legacy `super-c build` path) still sees the prototypes
   on glibc -- without this, implicit declarations truncate returned pointers and crash. */
#ifndef _POSIX_C_SOURCE
#  define _POSIX_C_SOURCE 200809L
#endif
/* And this on top of it, because _POSIX_C_SOURCE is not enough for all of them: glibc 2.41 guards realpath
   with __USE_MISC/__USE_XOPEN_EXTENDED, neither of which POSIX.1-2008 alone sets. Older glibc did declare
   it, so this compiles today and stops compiling the moment the CI image moves -- with an implicit
   declaration truncating the returned pointer to int, which is the crash the note above warns about. */
#ifndef _DEFAULT_SOURCE
#  define _DEFAULT_SOURCE 1
#endif

#include "driver_shim.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#if !defined(_WIN32) && !defined(__wasi__)
#  include <spawn.h>
#endif
#if defined(_WIN32)
#  include <direct.h>  /* _mkdir, _rmdir */
#  include <io.h>      /* _access, _unlink */
#  include <process.h> /* _getpid */
#  include <windows.h>
#elif !defined(__wasi__)
#  include <signal.h>   /* kill(pid, 0) liveness probe */
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

#if defined(_WIN32) || defined(__wasi__)
/* system() returns the child's exit code directly on Windows (no wait-status encoding), and WASI
   has no child processes at all -- the stubs below never produce a status to decode. */
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
#elif defined(__wasi__)
  return 1; /* WASI has no pids; a constant keeps pid-suffixed temp names stable */
#else
  return (int)getpid();
#endif
}

int sc_process_alive(int64_t pid) {
  if (pid <= 0)
    return 0;
#if defined(_WIN32)
  HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
  if (h == NULL)
    return 0;
  DWORD code = 0;
  int alive = GetExitCodeProcess(h, &code) && code == STILL_ACTIVE;
  CloseHandle(h);
  return alive;
#elif defined(__wasi__)
  return 1; /* WASI has no pids to probe */
#else
  return kill((pid_t)pid, 0) == 0 || errno == EPERM;
#endif
}

/* Host/target platform index, resolved by the compiler that builds this shim: 0 windows, 1 macos, 2 linux,
   3 wasm, 4 ios, 5 android.
   The self-hosted driver reads it as the default `--target`, so @platform gating matches the native build. */
int sc_host_platform(void) {
#if defined(_WIN32)
  return 0;
#elif defined(__ANDROID__)
  return 5; /* checked before __linux__: bionic is its own platform */
#elif defined(__wasi__)
  return 3; /* wasm */
#elif defined(__APPLE__)
  return 1;
#else
  return 2;
#endif
}

int sc_host_arch(void) {
#if defined(__x86_64__) || defined(_M_X64)
  return 0;
#elif defined(__aarch64__) || defined(_M_ARM64)
  return 1;
#elif defined(__wasm32__) || defined(__wasm__)
  return 2;
#else
  return -1;
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
/* Make a path writable so unlink can remove it: git creates its object files read-only, and on
   Windows _unlink refuses a read-only file outright. */
int sc_chmod_rw(const char *path) {
#if defined(_WIN32)
  return _chmod(path, _S_IREAD | _S_IWRITE);
#else
  return chmod(path, 0644);
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
#elif defined(__wasm__)
  return 1; /* one thread of execution: the parallel frontiers must resolve to the serial path */
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
#if defined(__wasi__)
  (void)cmd;
  return -1; /* WASI has no processes; the caller's spawn-failure path reports it */
#elif defined(_WIN32)
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

#if defined(_WIN32)
/* One CreateProcess command-line argument under the MSVCRT parsing rules: quote when the argument
   contains a space, tab, quote, or is empty; inside quotes, N backslashes before a '"' become 2N+1
   backslashes, and trailing backslashes double so the closing quote survives. */
static size_t win_quoted_len(const char *a) {
  size_t n = strlen(a), need = 0;
  int plain = n != 0;
  for (size_t i = 0; i < n; i++)
    if (a[i] == ' ' || a[i] == '\t' || a[i] == '"')
      plain = 0;
  if (plain)
    return n;
  need = 2; /* the surrounding quotes */
  size_t bs = 0;
  for (size_t i = 0; i < n; i++) {
    if (a[i] == '\\') {
      bs++;
    } else if (a[i] == '"') {
      need += bs + 1; /* doubled backslashes + the escape for the quote */
      bs = 0;
    } else {
      bs = 0;
    }
    need++;
  }
  need += bs; /* trailing backslashes double */
  return need;
}
static char *win_quote_into(char *w, const char *a) {
  size_t n = strlen(a);
  int plain = n != 0;
  for (size_t i = 0; i < n; i++)
    if (a[i] == ' ' || a[i] == '\t' || a[i] == '"')
      plain = 0;
  if (plain) {
    memcpy(w, a, n);
    return w + n;
  }
  *w++ = '"';
  size_t bs = 0;
  for (size_t i = 0; i < n; i++) {
    if (a[i] == '\\') {
      bs++;
      *w++ = '\\';
    } else if (a[i] == '"') {
      for (size_t k = 0; k < bs + 1; k++)
        *w++ = '\\';
      bs = 0;
      *w++ = '"';
    } else {
      bs = 0;
      *w++ = a[i];
    }
  }
  for (size_t k = 0; k < bs; k++)
    *w++ = '\\';
  *w++ = '"';
  return w;
}
#endif

/* Start argv[0..] (NULL-terminated) WITHOUT any shell: argv[0] is PATH-searched, every later entry
   reaches the child verbatim (spaces, quotes, non-ASCII bytes included). When out_path is non-NULL,
   the child's stdout+stderr truncate-redirect into it; NULL inherits the parent's. The returned
   pid/handle is claimed by sc_wait_any/sc_try_wait/sc_waitpid. -1 on spawn failure. */
long long sc_spawn_argv(const char *const *argv, const char *out_path) {
#if defined(__wasi__)
  (void)argv;
  (void)out_path;
  return -1;
#elif defined(_WIN32)
  size_t total = 1;
  for (int i = 0; argv[i]; i++)
    total += win_quoted_len(argv[i]) + 1;
  char *line = malloc(total);
  if (!line)
    return -1;
  char *w = line;
  for (int i = 0; argv[i]; i++) {
    if (i)
      *w++ = ' ';
    w = win_quote_into(w, argv[i]);
  }
  *w = '\0';
  STARTUPINFOA si;
  PROCESS_INFORMATION pi;
  memset(&si, 0, sizeof si);
  si.cb = sizeof si;
  HANDLE h = INVALID_HANDLE_VALUE;
  if (out_path) {
    SECURITY_ATTRIBUTES sa;
    memset(&sa, 0, sizeof sa);
    sa.nLength = sizeof sa;
    sa.bInheritHandle = TRUE;
    h = CreateFileA(out_path, GENERIC_WRITE, FILE_SHARE_READ, &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
      free(line);
      return -1;
    }
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = h;
    si.hStdError = h;
  }
  BOOL ok = CreateProcessA(NULL, line, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);
  free(line);
  if (h != INVALID_HANDLE_VALUE)
    CloseHandle(h);
  if (!ok)
    return -1;
  CloseHandle(pi.hThread);
  return (long long)(intptr_t)pi.hProcess;
#else
  extern char **environ;
  pid_t pid;
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_t *pfa = NULL;
  if (out_path) {
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 1, out_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&fa, 1, 2);
    pfa = &fa;
  }
  int rc = posix_spawnp(&pid, argv[0], pfa, NULL, (char *const *)argv, environ);
  if (pfa)
    posix_spawn_file_actions_destroy(&fa);
  return rc == 0 ? (long long)pid : -1;
#endif
}

/* sc_spawn_argv + wait: the child's exit code, or -1 on spawn/wait failure. */
int sc_exec_argv(const char *const *argv, const char *out_path) {
  long long pid = sc_spawn_argv(argv, out_path);
  if (pid < 0)
    return -1;
  int code = 1;
  if (sc_waitpid(pid, &code) != 0)
    return -1;
  return code;
}

/* Wait until ANY of the n spawned children exits: returns its index and stores its exit code, so the
   scheduler refills the freed slot immediately instead of draining in FIFO order. -1 on error. */
int sc_wait_any(const int64_t *pids, int n, int *code) {
#if defined(__wasi__)
  (void)pids; (void)n; (void)code;
  return -1;
#elif defined(_WIN32)
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

/* Non-blocking sc_wait_any: index of an already-exited child, or -1 when none has exited yet.
   Unlike sc_wait_any it never reaps a pid outside `pids`, so it is safe while unrelated children
   (the parallel emit workers) are alive. */
int sc_try_wait(const int64_t *pids, int n, int *code) {
#if defined(__wasi__)
  (void)pids; (void)n; (void)code;
  return -1;
#elif defined(_WIN32)
  HANDLE hs[MAXIMUM_WAIT_OBJECTS];
  if (n > MAXIMUM_WAIT_OBJECTS)
    n = MAXIMUM_WAIT_OBJECTS;
  for (int i = 0; i < n; i++)
    hs[i] = (HANDLE)(intptr_t)pids[i];
  DWORD w = WaitForMultipleObjects((DWORD)n, hs, FALSE, 0);
  if (w >= (DWORD)n)
    return -1;
  DWORD ec = 1;
  GetExitCodeProcess(hs[w], &ec);
  CloseHandle(hs[w]);
  *code = (int)ec;
  return (int)w;
#else
  for (int i = 0; i < n; i++) {
    int st = 0;
    pid_t p = waitpid((pid_t)pids[i], &st, WNOHANG);
    if (p == (pid_t)pids[i]) {
      *code = WIFEXITED(st) ? WEXITSTATUS(st) : 1;
      return i;
    }
  }
  return -1;
#endif
}

/* fork() for the parallel emit workers; -1 where unsupported (Windows), which selects the serial path. */
long long sc_fork(void) {
#if defined(_WIN32) || defined(__wasi__)
  return -1;
#else
  return (long long)fork();
#endif
}

/* Anonymous pipe: fds[0] read end, fds[1] write end. -1 on failure or Windows. */
int sc_pipe(int *fds) {
#if defined(_WIN32) || defined(__wasi__)
  (void)fds;
  return -1;
#else
  return pipe(fds);
#endif
}

/* Read exactly `n` bytes (short only at EOF); the emit workers' 2-byte completion packets must
   never tear across reads. Returns bytes read, -1 on error. */
int sc_fd_read(int fd, void *buf, int n) {
#if defined(_WIN32)
  (void)fd; (void)buf; (void)n;
  return -1;
#else
  int got = 0;
  while (got < n) {
    ssize_t r = read(fd, (char *)buf + got, (size_t)(n - got));
    if (r < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    if (r == 0)
      break;
    got += (int)r;
  }
  return got;
#endif
}

int sc_fd_write(int fd, const void *buf, int n) {
#if defined(_WIN32)
  (void)fd; (void)buf; (void)n;
  return -1;
#else
  int put = 0;
  while (put < n) {
    ssize_t r = write(fd, (const char *)buf + put, (size_t)(n - put));
    if (r < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    put += (int)r;
  }
  return put;
#endif
}

int sc_fd_close(int fd) {
#if defined(_WIN32)
  (void)fd;
  return -1;
#else
  return close(fd);
#endif
}

/* _exit(): no atexit handlers, no stream flushing. Emit workers end here so the inherited leak
   registry and buffered stdio are not replayed once per child. */
void sc_exit_now(int code) {
  _exit(code);
}

/* 1 when this binary is ASan-instrumented. fork() under ASan copy-on-write-faults the entire
   shadow region per child, which costs more than the parallel emit saves -- such a binary keeps
   the serial path. Compile-time of the shim, which is built with the profile's own cflags. */
int sc_asan(void) {
#if defined(__SANITIZE_ADDRESS__)
  return 1;
#elif defined(__has_feature)
#  if __has_feature(address_sanitizer)
  return 1;
#  else
  return 0;
#  endif
#else
  return 0;
#endif
}

/* Block for ONE specific child; its exit code via *code, 0 on success, -1 on error/Windows.
   Never reaps unrelated children. */
int sc_waitpid(long long pid, int *code) {
#if defined(__wasi__)
  (void)pid; (void)code;
  return -1;
#elif defined(_WIN32)
  HANDLE h = (HANDLE)(intptr_t)pid;
  if (WaitForSingleObject(h, INFINITE) != WAIT_OBJECT_0)
    return -1;
  DWORD ec = 1;
  GetExitCodeProcess(h, &ec);
  CloseHandle(h);
  *code = (int)ec;
  return 0;
#else
  int st = 0;
  while (waitpid((pid_t)pid, &st, 0) < 0) {
    if (errno != EINTR)
      return -1;
  }
  *code = WIFEXITED(st) ? WEXITSTATUS(st) : 1;
  return 0;
#endif
}

/* Atomic-ish rename for the build system's link-then-swap; Windows rename() refuses to replace. */
int sc_chmod_exec(const char *path) {
#if defined(_WIN32)
  (void)path; /* no exec bit: Windows decides by extension */
  return 0;
#else
  return chmod(path, 0755);
#endif
}

int sc_rename(const char *from, const char *to) {
#if defined(_WIN32)
  char side[4096];
  if (MoveFileExA(from, to, MOVEFILE_REPLACE_EXISTING))
    return 0;
  /* `to` may be a RUNNING image -- the compiler replacing itself. Windows refuses to delete or overwrite
     one, but it does allow RENAMING one, because the mapped section holds the file object rather than the
     path. So park the old image beside itself and move the new file into the name it vacated. The parked
     file cannot be deleted while anything is still executing it; the next build sweeps it. */
  if ((size_t)snprintf(side, sizeof side, "%s.old", to) >= sizeof side)
    return -1;
  _unlink(side); /* an image parked by an earlier self-replace, now that nothing is running it */
  if (!MoveFileExA(to, side, MOVEFILE_REPLACE_EXISTING))
    return -1;
  if (MoveFileExA(from, to, MOVEFILE_REPLACE_EXISTING))
    return 0;
  MoveFileExA(side, to, MOVEFILE_REPLACE_EXISTING); /* put it back rather than leave the name empty */
  return -1;
#else
  return rename(from, to);
#endif
}

/* Environment write for the build system (SUPERC points the test harness at the freshly built compiler). */
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
  /* Forward slashes, like sc_realpath: Win32 accepts them everywhere, and a path that reaches a JSON
     string or a C string literal must not carry backslashes -- "C:\Users\..." is an invalid escape in
     both, which is how a temp path silently corrupts an LSP request. */
  for (DWORD i = 0; i < n; i++)
    if (buf[i] == '\\')
      buf[i] = '/';
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
/* An output handle is APPEND-ONLY, and that is not a detail. The command being run may itself spawn
   processes that inherit this handle -- the test runner spawns one per test -- so several processes write
   to it at once. Plain GENERIC_WRITE makes every write land at the shared file pointer, which is correct
   only for as long as every writer agrees on where that is; FILE_APPEND_DATA makes each write go to the end
   of the file atomically, whatever any writer thinks the position is. Creation still truncates, so a
   capture never picks up a previous run: that needs write access, hence the two calls. */
static HANDLE sc_open_for_child(const char *path, int write) {
  SECURITY_ATTRIBUTES sa;
  memset(&sa, 0, sizeof sa);
  sa.nLength = sizeof sa;
  sa.bInheritHandle = TRUE;
  const char *name = path ? path : "NUL";
  if (!write)
    return CreateFileA(name, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING,
                       FILE_ATTRIBUTE_NORMAL, NULL);
  HANDLE trunc = CreateFileA(name, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, CREATE_ALWAYS,
                             FILE_ATTRIBUTE_NORMAL, NULL);
  if (trunc != INVALID_HANDLE_VALUE) CloseHandle(trunc);
  return CreateFileA(name, FILE_APPEND_DATA | SYNCHRONIZE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                     OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
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

int sc_exec(const char *cmd) {
  STARTUPINFOA si;
  PROCESS_INFORMATION pi;
  memset(&si, 0, sizeof si);
  si.cb = sizeof si; /* no STARTF_USESTDHANDLES: the child writes to our console */
  size_t n = strlen(cmd) + 1;
  char *line = (char *)malloc(n);
  if (!line)
    return -1;
  memcpy(line, cmd, n);
  int rc = -1;
  if (CreateProcessA(NULL, line, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    rc = (int)code;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  }
  free(line);
  return rc;
}
#elif defined(__wasi__)
/* WASI has no processes: every command runner fails cleanly and the caller reports it. */
int sc_run(const char *cmd, const char *in_path, const char *out_path, const char *err_path, const char *env) {
  (void)cmd; (void)in_path; (void)out_path; (void)err_path; (void)env;
  return -1;
}
int sc_exec(const char *cmd) {
  (void)cmd;
  return -1;
}
#else
int sc_run(const char *cmd, const char *in_path, const char *out_path, const char *err_path, const char *env) {
  extern char **environ;
  sc_env_save saves[8];
  const int nenv = env ? sc_env_apply(env, saves, 8) : 0;
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_addopen(&fa, 0, in_path ? in_path : "/dev/null", O_RDONLY, 0);
  /* O_APPEND for the same reason as the Windows branch above: the command may spawn processes of its own
     that inherit this descriptor, and appending is what keeps their writes from depending on a shared
     offset. O_TRUNC still clears the file at open, so a capture never includes a previous run. */
  posix_spawn_file_actions_addopen(&fa, 1, out_path ? out_path : "/dev/null",
                                   O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
  if (err_path)
    posix_spawn_file_actions_addopen(&fa, 2, err_path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
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

int sc_exec(const char *cmd) {
  extern char **environ;
  char *argv[] = {(char *)"sh", (char *)"-c", (char *)cmd, NULL};
  pid_t pid;
  if (posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, environ) != 0)
    return -1;
  int st = 0;
  while (waitpid(pid, &st, 0) < 0) {
  }
  return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}
#endif

/* Crash attribution for the compiler itself: every panic ends in abort(), which raises SIGABRT before
   the process dies, so a handler installed here is the one place a stack survives to be printed. POSIX
   prints symbolized frames; Windows has no DWARF-aware symbolizer at runtime, so it prints each return
   address as an offset from the PE base (ASLR-stable) for addr2line against the same binary. */
#if defined(__wasi__)
void sc_trace_install(void) {} /* WASI has neither signals nor a backtrace to print */
#else
#include <signal.h>
#if defined(_WIN32)
static void sc_trace_abort(int sig) {
  (void)sig;
  void *bt[32];
  unsigned short n = RtlCaptureStackBackTrace(0, 32, bt, NULL);
  char *base = (char *)GetModuleHandleA(NULL);
  fprintf(stderr, "trace: base %p\n", (void *)base);
  for (unsigned short i = 0; i < n; i++)
    fprintf(stderr, "trace: +0x%llx\n", (unsigned long long)((char *)bt[i] - base));
  fflush(stderr);
}
#else
#  include <execinfo.h>
static void sc_trace_abort(int sig) {
  (void)sig;
  void *bt[32];
  backtrace_symbols_fd(bt, backtrace(bt, 32), 2);
}
#endif
void sc_trace_install(void) { signal(SIGABRT, sc_trace_abort); }
#endif
