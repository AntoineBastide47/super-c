#include "pthread_ext.h"
#include <pthread.h>
#include <stdlib.h>

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

void *sc_rwlock_new(void) {
    pthread_rwlock_t *r = (pthread_rwlock_t *)malloc(sizeof *r);
    if (r) pthread_rwlock_init(r, NULL);
    return r;
}
void sc_rwlock_free(void *p) {
    pthread_rwlock_t *r = (pthread_rwlock_t *)p;
    if (r) { pthread_rwlock_destroy(r); free(r); }
}
