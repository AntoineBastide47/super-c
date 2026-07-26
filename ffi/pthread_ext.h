/* Sizing shim for std/parallel/sync: pthread_mutex_t / pthread_cond_t / pthread_rwlock_t are opaque with
 * platform-dependent sizes (a mutex is 40 bytes on glibc, 64 on macOS; an rwlock is 56 vs 200), so Super-C
 * cannot allocate them itself. These helpers allocate, initialise, destroy and release one of each, hiding
 * the size entirely in C. Locking/waiting is done from Super-C through the ordinary pthread bindings. */
#ifndef SC_PTHREAD_EXT_H
#define SC_PTHREAD_EXT_H

void *sc_mutex_new(void);
void sc_mutex_free(void *m);
void *sc_cond_new(void);
void sc_cond_free(void *c);
/* Wait on `c` under held mutex `m` for at most `rel_ns` nanoseconds (relative). Returns 0 if signalled,
 * nonzero on timeout/spurious wake -- the caller must re-check its condition. */
int sc_cond_timedwait_ns(void *c, void *m, long long rel_ns);
void *sc_rwlock_new(void);
void sc_rwlock_free(void *r);

#endif
