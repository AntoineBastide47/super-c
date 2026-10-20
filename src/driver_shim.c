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
/* Strict POSIX on Darwin hides ru_maxrss; the full API level restores it. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#  define _DARWIN_C_SOURCE 1
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
#  include <sys/resource.h>
#endif
#if defined(_WIN32)
#  include <direct.h>  /* _mkdir, _rmdir */
#  include <io.h>      /* _access, _unlink */
#  include <process.h> /* _getpid */
#  include <sys/utime.h> /* _utime */
#  define PSAPI_VERSION 2 /* GetProcessMemoryInfo resolves to K32... in kernel32: no -lpsapi needed */
#  include <windows.h>
#  include <psapi.h>
#elif !defined(__wasi__)
#  include <poll.h>     /* sc_file_pending */
#  include <signal.h>   /* kill: the liveness probe, sc_kill */
#  include <sys/resource.h> /* getrusage: peak RSS */
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

int sc_lstat_isdir(const char *path) {
#if defined(_WIN32)
  DWORD a = GetFileAttributesA(path);
  if (a == INVALID_FILE_ATTRIBUTES)
    return -1;
  if (!(a & FILE_ATTRIBUTE_DIRECTORY))
    return 0;
  return (a & FILE_ATTRIBUTE_REPARSE_POINT) ? 2 : 1;
#else
  struct stat st;
  if (lstat(path, &st) != 0)
    return -1;
  return S_ISDIR(st.st_mode) ? 1 : 0;
#endif
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

int sc_readlink(const char *path, char *buf, unsigned size) {
#if defined(_WIN32) || defined(__wasi__)
  (void)path;
  (void)buf;
  (void)size;
  return -1;
#else
  if (size == 0)
    return -1;
  const ssize_t n = readlink(path, buf, size - 1);
  if (n < 0)
    return -1;
  buf[n] = '\0';
  return (int)n;
#endif
}

#if defined(__wasi__)
static const char *sc_argv0; /* the host's argv[0]: WASI has no other name for the running module */
void sc_set_argv0(const char *argv0) { sc_argv0 = argv0; }
#else
void sc_set_argv0(const char *argv0) { (void)argv0; }
#endif

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
  /* readlink does not terminate and silently truncates: a result that fills `buf` may be cut short. */
  ssize_t n = readlink("/proc/self/exe", buf, (size_t)size);
  if (n <= 0 || (size_t)n >= (size_t)size)
    return -1;
  buf[n] = '\0';
  return 0;
#elif defined(__wasi__)
  /* An absolute argv[0] names the module file through a preopened root (`wasmtime run --dir=/
     --argv0 <abs path>`); a relative one resolves against the guest's cwd, not the host's, so it
     names no file this can trust. */
  if (!sc_argv0 || sc_argv0[0] != '/')
    return -1;
  size_t n = strlen(sc_argv0);
  if (n >= (size_t)size)
    return -1;
  memcpy(buf, sc_argv0, n + 1);
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

int64_t sc_file_read(void *f, void *buf, size_t n) {
#if defined(_WIN32)
  unsigned want = n > 1u << 30 ? 1u << 30 : (unsigned)n;
  return _read(_fileno((FILE *)f), buf, want);
#else
  ssize_t r;
  do {
    r = read(fileno((FILE *)f), buf, n);
  } while (r < 0 && errno == EINTR);
  return (int64_t)r;
#endif
}

int sc_file_pending(void *f) {
#if defined(_WIN32)
  HANDLE h = (HANDLE)_get_osfhandle(_fileno((FILE *)f));
  if (h == INVALID_HANDLE_VALUE)
    return 0;
  if (GetFileType(h) == FILE_TYPE_PIPE) {
    DWORD avail = 0;
    if (!PeekNamedPipe(h, NULL, 0, NULL, &avail, NULL))
      return 1; /* a broken pipe: the read reports it */
    return avail > 0;
  }
  return WaitForSingleObject(h, 0) == WAIT_OBJECT_0;
#elif defined(__wasi__)
  (void)f;
  return 0;
#else
  struct pollfd pfd;
  pfd.fd = fileno((FILE *)f);
  pfd.events = POLLIN;
  pfd.revents = 0;
  return poll(&pfd, 1, 0) > 0; /* data, end of stream or an error: the read returns at once */
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
int sc_errno_absent(void) { return errno == ENOENT || errno == ENOTDIR; }

int sc_file_open(const char *path, int64_t *size, int64_t *mtime) {
#if defined(_WIN32)
  struct _stat64 st;
  int fd = _open(path, _O_RDONLY | _O_BINARY);
  if (fd < 0)
    return -1;
  if (_fstat64(fd, &st) != 0 || (st.st_mode & _S_IFMT) != _S_IFREG) {
    _close(fd);
    return -1;
  }
#else
  struct stat st;
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0)
    return -1;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
    close(fd);
    return -1;
  }
#endif
  *size = (int64_t)st.st_size;
  *mtime = (int64_t)st.st_mtime; /* as sc_mtime reads it */
  return fd;
}

int64_t sc_file_read_close(int fd, void *buf, size_t n) {
  size_t got = 0;
  int bad = 0;
  /* Every pass reads at least one byte or ends the loop, so it runs at most n times. */
  while (got < n) {
#if defined(_WIN32)
    size_t left = n - got;
    int r = _read(fd, (char *)buf + got, left > 1u << 30 ? 1u << 30 : (unsigned)left);
#else
    ssize_t r = read(fd, (char *)buf + got, n - got);
#endif
    if (r <= 0) {
      bad = r < 0;
      break;
    }
    got += (size_t)r;
  }
#if defined(_WIN32)
  bad |= _close(fd) != 0;
#else
  bad |= close(fd) != 0;
#endif
  return bad ? -1 : (int64_t)got;
}

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

long long sc_mtime_ns(const char *path) {
#if defined(_WIN32)
  WIN32_FILE_ATTRIBUTE_DATA d;
  if (!GetFileAttributesExA(path, GetFileExInfoStandard, &d))
    return 0;
  /* FILETIME counts 100 ns ticks from 1601; the offset moves the origin to 1970. */
  const unsigned long long t =
      ((unsigned long long)d.ftLastWriteTime.dwHighDateTime << 32) | d.ftLastWriteTime.dwLowDateTime;
  return (long long)(t - 116444736000000000ull) * 100;
#else
  struct stat st;
  if (stat(path, &st) != 0)
    return 0;
#if defined(__APPLE__)
  return (long long)st.st_mtimespec.tv_sec * 1000000000ll + st.st_mtimespec.tv_nsec;
#else
  return (long long)st.st_mtim.tv_sec * 1000000000ll + st.st_mtim.tv_nsec;
#endif
#endif
}

/* Set the modification time of `path` to now; 0 on success. */
int sc_touch(const char *path) {
#if defined(_WIN32)
  return _utime(path, NULL);
#else
  return utimensat(AT_FDCWD, path, NULL, 0);
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

/* The process-tree jobserver: `capacity` slots for the whole tree, one of them implicit to the process
   that made it. Each other slot is one byte of a slot file, held by a byte-range lock: fcntl F_SETLK
   (POSIX) or LockFileEx (Windows). The system drops a process's locks when it ends, by an exit, an abort
   or a kill, so a slot is never lost, and a forked child does not inherit its parent's POSIX locks.
   SC_JOBSERVER names the file to every process of the tree: "<slots>,<fd>" on POSIX, the inherited
   descriptor of the unlinked file; "<slots>,<path>" on Windows, a temporary file the system deletes when
   its last handle closes. */
#define SC_JS_MAX 1024
static int sc_js_claimed;
static int sc_js_release_registered;
#if !defined(__wasi__) /* WASI has no slot file: its jobserver holds no slot */
static int sc_js_loaded;
static int sc_js_slots;
static unsigned char sc_js_own[SC_JS_MAX]; /* the slot bytes this process holds */
#endif
#if defined(_WIN32)
static HANDLE sc_js_file = INVALID_HANDLE_VALUE;

static int sc_jobserver_load(void) {
  if (sc_js_loaded)
    return 1;
  const char *v = getenv("SC_JOBSERVER");
  int n = -1;
  int used = 0;
  if (v == NULL || sscanf(v, "%d,%n", &n, &used) != 1 || used == 0 || n < 0 || n > SC_JS_MAX)
    return 0;
  sc_js_file = CreateFileA(v + used, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (sc_js_file == INVALID_HANDLE_VALUE)
    return 0;
  sc_js_slots = n;
  sc_js_loaded = 1;
  return 1;
}

int sc_jobserver_init(int capacity) {
  if (sc_jobserver_load())
    return 1;
  const int n = capacity < 1 ? 0 : capacity - 1 > SC_JS_MAX ? SC_JS_MAX : capacity - 1;
  char dir[MAX_PATH];
  const DWORD dl = GetTempPathA(sizeof dir, dir);
  if (dl == 0 || dl >= sizeof dir)
    return 0;
  char path[MAX_PATH + 64];
  int pl = snprintf(path, sizeof path, "%ssuper-c-jobs-%lu-%llu", dir, (unsigned long)GetCurrentProcessId(),
                    (unsigned long long)GetTickCount64());
  if (pl < 1 || (size_t)pl >= sizeof path)
    return 0;
  sc_js_file = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                           CREATE_NEW, FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, NULL);
  if (sc_js_file == INVALID_HANDLE_VALUE)
    return 0;
  char text[MAX_PATH + 96];
  int tl = snprintf(text, sizeof text, "%d,%s", n, path);
  if (tl < 1 || (size_t)tl >= sizeof text || !SetEnvironmentVariableA("SC_JOBSERVER", text)) {
    CloseHandle(sc_js_file);
    sc_js_file = INVALID_HANDLE_VALUE;
    return 0;
  }
  sc_js_slots = n;
  sc_js_loaded = 1;
  return 1;
}

static int sc_jobserver_lock(int i, int lock) {
  OVERLAPPED ov;
  memset(&ov, 0, sizeof ov);
  ov.Offset = (DWORD)i;
  if (!lock)
    return UnlockFileEx(sc_js_file, 0, 1, 0, &ov) ? 1 : -1;
  if (LockFileEx(sc_js_file, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ov))
    return 1;
  return GetLastError() == ERROR_LOCK_VIOLATION ? 0 : -1;
}
#elif !defined(__wasi__)
static int sc_js_fd = -1;

static int sc_jobserver_load(void) {
  if (sc_js_loaded)
    return 1;
  const char *v = getenv("SC_JOBSERVER");
  int n = -1;
  int fd = -1;
  char tail = 0;
  if (v == NULL || sscanf(v, "%d,%d%c", &n, &fd, &tail) != 2 || n < 0 || n > SC_JS_MAX || fd < 0)
    return 0;
  if (fcntl(fd, F_GETFD) < 0)
    return 0;
  sc_js_fd = fd;
  sc_js_slots = n;
  sc_js_loaded = 1;
  return 1;
}

int sc_jobserver_init(int capacity) {
  if (sc_jobserver_load())
    return 1;
  const int n = capacity < 1 ? 0 : capacity - 1 > SC_JS_MAX ? SC_JS_MAX : capacity - 1;
  const char *dir = getenv("TMPDIR");
  char path[1024];
  int pl = snprintf(path, sizeof path, "%s/super-c-jobs-XXXXXX", dir != NULL && dir[0] != 0 ? dir : "/tmp");
  if (pl < 1 || (size_t)pl >= sizeof path)
    return 0;
  /* No FD_CLOEXEC: every process the tree starts inherits the descriptor. */
  const int fd = mkstemp(path);
  if (fd < 0)
    return 0;
  if (unlink(path) != 0) {
    close(fd);
    return 0;
  }
  char text[64];
  int tl = snprintf(text, sizeof text, "%d,%d", n, fd);
  if (tl < 1 || (size_t)tl >= sizeof text || setenv("SC_JOBSERVER", text, 1) != 0) {
    close(fd);
    return 0;
  }
  sc_js_fd = fd;
  sc_js_slots = n;
  sc_js_loaded = 1;
  return 1;
}

/* Lock (`lock` 1) or unlock slot byte `i`: 1 done, 0 another process holds it, -1 an error. */
static int sc_jobserver_lock(int i, int lock) {
  struct flock fl;
  memset(&fl, 0, sizeof fl);
  fl.l_type = lock ? F_WRLCK : F_UNLCK;
  fl.l_whence = SEEK_SET;
  fl.l_start = i;
  fl.l_len = 1;
  for (;;) {
    if (fcntl(sc_js_fd, F_SETLK, &fl) == 0)
      return 1;
    if (errno == EINTR)
      continue;
    return lock && (errno == EACCES || errno == EAGAIN) ? 0 : -1;
  }
}
#endif

#if defined(__wasi__)
int sc_jobserver_init(int capacity) {
  (void)capacity;
  return 0;
}
static int sc_jobserver_active(void) { return 0; }
static int sc_jobserver_try_acquire(void) { return 0; }
static int sc_jobserver_release(void) { return 0; }
#else
static int sc_jobserver_active(void) { return sc_jobserver_load(); }

/* Take a free slot: 1, or 0 when every slot is held. A lock error is fatal: the tree's budget is gone. */
static int sc_jobserver_try_acquire(void) {
  if (!sc_jobserver_load())
    return 0;
  for (int i = 0; i < sc_js_slots; i++) {
    if (sc_js_own[i])
      continue;
    const int r = sc_jobserver_lock(i, 1);
    if (r < 0)
      abort();
    if (r == 1) {
      sc_js_own[i] = 1;
      return 1;
    }
  }
  return 0;
}

/* Give back one held slot: 1, or 0 when this process holds none. */
static int sc_jobserver_release(void) {
  if (!sc_jobserver_load())
    return 0;
  for (int i = 0; i < sc_js_slots; i++) {
    if (sc_js_own[i]) {
      if (sc_jobserver_lock(i, 0) != 1)
        abort();
      sc_js_own[i] = 0;
      return 1;
    }
  }
  return 0;
}
#endif

void sc_jobserver_release_claim(void) {
  while (sc_js_claimed > 1) {
    if (!sc_jobserver_release())
      abort();
    sc_js_claimed--;
  }
  sc_js_claimed = 0;
}

int sc_jobserver_claim(int wanted) {
  if (wanted < 1)
    wanted = 1;
  if (!sc_jobserver_active())
    return wanted;
  if (sc_js_claimed != 0)
    return sc_js_claimed;
  sc_js_claimed = 1;
  while (sc_js_claimed < wanted && sc_jobserver_try_acquire())
    sc_js_claimed++;
  if (!sc_js_release_registered) {
    if (atexit(sc_jobserver_release_claim) != 0)
      abort();
    sc_js_release_registered = 1;
  }
  return sc_js_claimed;
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

int64_t sc_tree_lock(const char *path, int64_t wait_ms) {
#if defined(__wasi__)
  /* No file locks: a WASI compiler runs as the transpiler of an engine that holds the lock. */
  (void)path;
  (void)wait_ms;
  return 0;
#else
  long long until = sc_ticks_ms() + wait_ms;
#  if defined(_WIN32)
  HANDLE h = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (h == INVALID_HANDLE_VALUE)
    return -2;
  for (;;) {
    OVERLAPPED ov;
    memset(&ov, 0, sizeof ov);
    if (LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ov))
      return (int64_t)(intptr_t)h;
    if (GetLastError() != ERROR_LOCK_VIOLATION) {
      CloseHandle(h);
      return -2;
    }
    if (sc_ticks_ms() >= until) {
      CloseHandle(h);
      return -1;
    }
    Sleep(100);
  }
#  else
  int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
  if (fd < 0)
    return -2;
  for (;;) {
    /* A POSIX record lock on the whole file: held by this process until it closes `fd` or ends. */
    struct flock fl;
    memset(&fl, 0, sizeof fl);
    fl.l_type = F_WRLCK;
    fl.l_whence = SEEK_SET;
    if (fcntl(fd, F_SETLK, &fl) == 0)
      return fd;
    if (errno != EACCES && errno != EAGAIN && errno != EINTR) {
      close(fd);
      return -2;
    }
    if (sc_ticks_ms() >= until) {
      close(fd);
      return -1;
    }
    struct timespec ts = {0, 100000000};
    nanosleep(&ts, NULL);
  }
#  endif
#endif
}

void sc_tree_unlock(int64_t h) {
#if defined(_WIN32)
  CloseHandle((HANDLE)(intptr_t)h);
#elif !defined(__wasi__)
  close((int)h);
#else
  (void)h;
#endif
}

long long sc_peak_rss(void) {
#if defined(_WIN32)
  PROCESS_MEMORY_COUNTERS pmc;
  if (!GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof pmc))
    return 0;
  return (long long)pmc.PeakWorkingSetSize;
#elif defined(__wasi__)
  return 0;
#else
  struct rusage ru;
  if (getrusage(RUSAGE_SELF, &ru) != 0)
    return 0;
#  if defined(__APPLE__)
  return (long long)ru.ru_maxrss; /* bytes */
#  else
  return (long long)ru.ru_maxrss * 1024LL; /* KiB */
#  endif
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

static long long spawn_in(const char *file, const char *const *argv, const char *out_path, const char *cwd);

/* Start argv[0..] (NULL-terminated) WITHOUT any shell: the program `file` names (a path), or argv[0]
   PATH-searched when `file` is NULL; argv[0] reaches the child as written, and every later entry
   verbatim (spaces, quotes, non-ASCII bytes included). When out_path is non-NULL, the child's
   stdout+stderr truncate-redirect into it; NULL inherits the parent's. The returned pid/handle is
   claimed by sc_wait_any/sc_try_wait/sc_waitpid. -1 on spawn failure. */
long long sc_spawn_argv(const char *file, const char *const *argv, const char *out_path) {
  return spawn_in(file, argv, out_path, NULL);
}

/* sc_spawn_argv of argv[0] with the child's working directory set to `cwd` (NULL: this process's). */
long long sc_spawn_argv_in(const char *const *argv, const char *out_path, const char *cwd) {
  return spawn_in(NULL, argv, out_path, cwd);
}

static long long spawn_in(const char *file, const char *const *argv, const char *out_path, const char *cwd) {
#if defined(__wasi__)
  (void)file;
  (void)argv;
  (void)out_path;
  (void)cwd;
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
  BOOL ok = CreateProcessA(file, line, NULL, NULL, TRUE, 0, NULL, cwd, &si, &pi);
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
  if (out_path || cwd) {
    posix_spawn_file_actions_init(&fa);
    pfa = &fa;
  }
  if (out_path) {
    posix_spawn_file_actions_addopen(&fa, 1, out_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&fa, 1, 2);
  }
  if (cwd) {
#if defined(__APPLE__) || defined(__GLIBC__)
    /* macOS 26 replaces the _np name with the POSIX 2024 one and deprecates the _np one when the
       deployment target is 26 or later; an older target has only the _np one. */
#  if defined(__APPLE__) && __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ >= 260000
    int crc = posix_spawn_file_actions_addchdir(&fa, cwd);
#  else
    int crc = posix_spawn_file_actions_addchdir_np(&fa, cwd);
#  endif
    if (crc != 0) {
      posix_spawn_file_actions_destroy(&fa);
      return -1;
    }
#else
    /* No chdir file action on this libc. */
    posix_spawn_file_actions_destroy(&fa);
    return -1;
#endif
  }
  /* posix_spawnp makes a whole spawn attempt per PATH entry: a program found once starts by its path.
     A path that does not start (a PATH match that is not executable) falls back to the search. */
  int rc = file ? posix_spawn(&pid, file, pfa, NULL, (char *const *)argv, environ) : -1;
  if (rc != 0)
    rc = posix_spawnp(&pid, argv[0], pfa, NULL, (char *const *)argv, environ);
  if (pfa)
    posix_spawn_file_actions_destroy(&fa);
  return rc == 0 ? (long long)pid : -1;
#endif
}

/* sc_spawn_argv + wait: the child's exit code, or -1 on spawn/wait failure. A child a signal ended
   returns 1 and is named on stderr with the signal: its exit status carries no other trace of it. */
int sc_exec_argv(const char *file, const char *const *argv, const char *out_path) {
  long long pid = sc_spawn_argv(file, argv, out_path);
  if (pid < 0)
    return -1;
#if defined(_WIN32) || defined(__wasi__)
  int code = 1;
  if (sc_waitpid(pid, &code) != 0)
    return -1;
  return code;
#else
  int st = 0;
  while (waitpid((pid_t)pid, &st, 0) < 0) {
    if (errno != EINTR)
      return -1;
  }
  if (WIFSIGNALED(st)) {
    fprintf(stderr, "super-c: '%s' was terminated by signal %d (%s)\n", argv[0], WTERMSIG(st), strsignal(WTERMSIG(st)));
    return 1;
  }
  return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
#endif
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

/* End child `pid` (an `sc_spawn_argv` id) at once, as an outside kill does: SIGKILL on POSIX,
   TerminateProcess on its handle on Windows. 0 when the kill is sent, -1 on error; the caller still
   waits for the child. */
int sc_kill(long long pid) {
#if defined(__wasi__)
  (void)pid;
  return -1;
#elif defined(_WIN32)
  return TerminateProcess((HANDLE)(intptr_t)pid, 137) ? 0 : -1;
#else
  return kill((pid_t)pid, SIGKILL) == 0 ? 0 : -1;
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

int sc_chmod_exec(const char *path) {
#if defined(_WIN32)
  (void)path; /* no exec bit: Windows decides by extension */
  return 0;
#else
  return chmod(path, 0755);
#endif
}

/* The number of names of the file `path` (its hard links), with its identity on its volume in `*id`
   (POSIX inode, Win32 file index); -1 when it cannot be read. */
int sc_file_links(const char *path, uint64_t *id) {
#if defined(_WIN32)
  BY_HANDLE_FILE_INFORMATION fi;
  HANDLE h = CreateFileA(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                         FILE_FLAG_BACKUP_SEMANTICS, NULL);
  if (h == INVALID_HANDLE_VALUE)
    return -1;
  int ok = GetFileInformationByHandle(h, &fi);
  CloseHandle(h);
  if (!ok)
    return -1;
  *id = (uint64_t)fi.nFileIndexHigh << 32 | fi.nFileIndexLow;
  return (int)fi.nNumberOfLinks;
#else
  struct stat st;
  if (stat(path, &st) != 0)
    return -1;
  *id = (uint64_t)st.st_ino;
  return (int)st.st_nlink;
#endif
}

/* A second name `to` for the file `from` (a hard link); 0 on success. */
int sc_link(const char *from, const char *to) {
#if defined(_WIN32)
  return CreateHardLinkA(to, from, NULL) ? 0 : -1;
#else
  return link(from, to);
#endif
}

/* Atomic-ish rename for the build system's link-then-swap; Windows rename() refuses to replace. */
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

/* Remove `name` from the environment: a switch the compiler reads as `getenv(...) != NULL` must not
   survive as an empty string. */
int sc_unsetenv(const char *name) {
#if defined(_WIN32)
  return _putenv_s(name, "");
#else
  return unsetenv(name);
#endif
}

/* ---- portable process + filesystem helpers for the test harnesses ---------------------------------- */
#if !defined(__wasi__) /* WASI spawns no children: the env helpers below serve only sc_run */
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

/* Restore in reverse, so a name assigned twice gets back its value from before the first assignment. */
static void sc_env_restore(sc_env_save *saves, int n) {
  for (int i = n - 1; i >= 0; i--) {
    if (saves[i].had && saves[i].old)
      sc_setenv(saves[i].name, saves[i].old);
    else
      sc_unsetenv(saves[i].name);
    free(saves[i].old);
  }
}

/* Apply every NAME=VALUE of `env` (space separated; a VALUE in double quotes may hold spaces) and return
   how many, or -1 with none left applied when one is malformed, there are more than `max`, or memory runs
   out: a child never runs with part of the environment its caller asked for. */
static int sc_env_apply(const char *env, sc_env_save *saves, int max) {
  int n = 0;
  const char *p = env;
  for (;;) {
    while (*p == ' ' || *p == '\t')
      p++;
    if (!*p)
      return n;
    const char *eq = p;
    while (*eq && *eq != '=' && *eq != ' ' && *eq != '\t')
      eq++;
    if (*eq != '=' || n == max)
      break;
    const char *v0 = eq + 1;
    const char *v1;
    const char *end;
    if (*v0 == '"') {
      v0++;
      v1 = strchr(v0, '"');
      if (!v1)
        break;
      end = v1 + 1;
    } else {
      v1 = v0;
      while (*v1 && *v1 != ' ' && *v1 != '\t')
        v1++;
      end = v1;
    }
    if (*end && *end != ' ' && *end != '\t')
      break;
    size_t nl = (size_t)(eq - p);
    if (nl == 0 || nl >= sizeof saves[0].name)
      break;
    memcpy(saves[n].name, p, nl);
    saves[n].name[nl] = 0;
    const char *prev = getenv(saves[n].name);
    saves[n].had = prev != 0;
    saves[n].old = prev ? sc_strdup_local(prev) : 0;
    size_t vl = (size_t)(v1 - v0);
    char *val = (char *)malloc(vl + 1);
    if (!val || (prev && !saves[n].old)) {
      free(val);
      free(saves[n].old);
      break;
    }
    memcpy(val, v0, vl);
    val[vl] = 0;
    sc_setenv(saves[n].name, val);
    free(val);
    n++;
    p = end;
  }
  sc_env_restore(saves, n);
  return -1;
}
#endif

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

/* Links are removed, never followed: a link to a directory must not lose the target's contents. A child
   whose path does not fit is left in place (a truncated path names another file), so the rmdir fails and
   the result reports it. */
int sc_rm_rf(const char *path) {
  const int kind = sc_lstat_isdir(path);
  if (kind == 1) {
    void *d = sc_opendir(path);
    if (d) {
      void *e;
      while ((e = sc_readdir(d)) != 0) {
        const char *nm = sc_dirent_name(e);
        if (!strcmp(nm, ".") || !strcmp(nm, ".."))
          continue;
        char child[4096];
        const int cn = snprintf(child, sizeof child, "%s/%s", path, nm);
        if (cn < 0 || (size_t)cn >= sizeof child)
          continue;
        sc_rm_rf(child);
      }
      sc_closedir(d);
    }
    sc_rmdir(path);
  } else if (kind == 2) {
    sc_rmdir(path); /* a Windows directory link or junction: rmdir removes the link alone */
  } else if (kind == 0) {
    sc_unlink(path);
  }
  return sc_lstat_isdir(path) == -1 ? 0 : -1;
}

/* Make file `path` hold exactly the `n` bytes at `p` (driver_shim.spc). The comparison reads through a
   16 KiB stack buffer: the emitter can call this on a coroutine stack. */
int sc_publish(const char *path, const void *p, size_t n) {
#if defined(_WIN32)
  int fd = _open(path, _O_RDONLY | _O_BINARY);
#else
  int fd = open(path, O_RDONLY | O_CLOEXEC);
#endif
  if (fd >= 0) {
#if defined(_WIN32)
    struct _stat64 st;
    int same = _fstat64(fd, &st) == 0 && (uint64_t)st.st_size == (uint64_t)n;
#else
    struct stat st;
    int same = fstat(fd, &st) == 0 && (uint64_t)st.st_size == (uint64_t)n;
#endif
    size_t off = 0;
    while (same) {
      char buf[16384];
#if defined(_WIN32)
      const int r = _read(fd, buf, (unsigned)sizeof buf);
#else
      const ssize_t r = read(fd, buf, sizeof buf);
      if (r < 0 && errno == EINTR)
        continue;
#endif
      if (r <= 0) {
        same = r == 0 && off == n;
        break;
      }
      same = off + (size_t)r <= n && memcmp(buf, (const char *)p + off, (size_t)r) == 0;
      off += (size_t)r;
    }
#if defined(_WIN32)
    _close(fd);
#else
    close(fd);
#endif
    if (same)
      return 0;
  }
#if defined(_WIN32)
  const int wflags = _O_WRONLY | _O_CREAT | _O_TRUNC | _O_BINARY;
  fd = _open(path, wflags, _S_IREAD | _S_IWRITE);
#else
  const int wflags = O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC;
  fd = open(path, wflags, 0644);
#endif
  if (fd < 0 && errno == ENOENT) {
    /* The parent directories exist for all but the first file written into each. */
    const char *s1 = strrchr(path, '/');
    const char *s2 = strrchr(path, '\\');
    const char *slash = s2 > s1 ? s2 : s1;
    char dir[4096];
    if (slash == NULL || slash == path || (size_t)(slash - path) >= sizeof dir)
      return -1;
    memcpy(dir, path, (size_t)(slash - path));
    dir[slash - path] = 0;
    sc_mkdir_p(dir);
#if defined(_WIN32)
    fd = _open(path, wflags, _S_IREAD | _S_IWRITE);
#else
    fd = open(path, wflags, 0644);
#endif
  }
  if (fd < 0)
    return -1;
  /* One write per call, no stdio buffer: a file is one system call on every host. */
  size_t off = 0;
  while (off < n) {
    const size_t want = n - off > (1u << 30) ? (1u << 30) : n - off;
#if defined(_WIN32)
    const int w = _write(fd, (const char *)p + off, (unsigned)want);
#else
    const ssize_t w = write(fd, (const char *)p + off, want);
    if (w < 0 && errno == EINTR)
      continue;
#endif
    if (w <= 0)
      break;
    off += (size_t)w;
  }
#if defined(_WIN32)
  const int cr = _close(fd);
#else
  const int cr = close(fd);
#endif
  return off == n && cr == 0 ? 1 : -1;
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
  if (nenv < 0)
    return -1;
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
  if (nenv < 0)
    return -1;
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
    pid_t w;
    while ((w = waitpid(pid, &st, 0)) < 0 && errno == EINTR) {
    }
    if (w == pid)
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
  pid_t w;
  while ((w = waitpid(pid, &st, 0)) < 0 && errno == EINTR) {
  }
  if (w != pid)
    return -1;
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

int sc_raise_open_files(uint64_t need) {
#if !defined(_WIN32) && !defined(__wasi__)
  struct rlimit r;
  if (getrlimit(RLIMIT_NOFILE, &r) != 0)
    return -1;
  if (r.rlim_cur != RLIM_INFINITY && r.rlim_cur < need) {
    if (r.rlim_max != RLIM_INFINITY && r.rlim_max < need)
      return -1;
    r.rlim_cur = (rlim_t)need;
    if (setrlimit(RLIMIT_NOFILE, &r) != 0)
      return -1;
  }
#else
  (void)need;
#endif
  return 0;
}
