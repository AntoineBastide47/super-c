#include "pthread_ext.h"
#include <pthread.h>
#include <stdlib.h>
#include <time.h>

void *sc_mutex_new(void) {
    pthread_mutex_t *m = (pthread_mutex_t *)malloc(sizeof *m);
    if (m) pthread_mutex_init(m, NULL);
    return m;
}
void sc_mutex_free(void *p) {
    pthread_mutex_t *m = (pthread_mutex_t *)p;
    if (m) { pthread_mutex_destroy(m); free(m); }
}

void *sc_cond_new(void) {
    pthread_cond_t *c = (pthread_cond_t *)malloc(sizeof *c);
    if (c) pthread_cond_init(c, NULL);
    return c;
}
void sc_cond_free(void *p) {
    pthread_cond_t *c = (pthread_cond_t *)p;
    if (c) { pthread_cond_destroy(c); free(c); }
}

int sc_cond_timedwait_ns(void *cp, void *mp, long long rel_ns) {
    pthread_cond_t *c = (pthread_cond_t *)cp;
    pthread_mutex_t *m = (pthread_mutex_t *)mp;
    if (rel_ns < 0) return pthread_cond_wait(c, m);
    /* pthread_cond_timedwait takes an ABSOLUTE deadline on the cond's clock (realtime by default). */
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    long long ns = (long long)ts.tv_nsec + rel_ns % 1000000000ll;
    ts.tv_sec += (time_t)(rel_ns / 1000000000ll + ns / 1000000000ll);
    ts.tv_nsec = (long)(ns % 1000000000ll);
    return pthread_cond_timedwait(c, m, &ts);
}

void *sc_rwlock_new(void) {
    pthread_rwlock_t *r = (pthread_rwlock_t *)malloc(sizeof *r);
    if (r) pthread_rwlock_init(r, NULL);
    return r;
}
void sc_rwlock_free(void *p) {
    pthread_rwlock_t *r = (pthread_rwlock_t *)p;
    if (r) { pthread_rwlock_destroy(r); free(r); }
}
