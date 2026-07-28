/* COMPLETION-based I/O, the other half of the reactor story from sc_io.h.
   The readiness poller in sc_io.h answers "when can I read this descriptor?" and leaves the syscall to the
   caller. This answers a different question: "here is the read, tell me when it is DONE." The buffer travels
   with the request, the kernel fills it, and what comes back is the result -- one syscall for a batch of
   operations instead of one per readiness event plus one per transfer.

   Two kernels implement that model and neither is optional to support separately: io_uring on Linux and
   IOCP on Windows. They agree on the shape (submit with a cookie, reap cookie + result), which is why this
   is ONE interface rather than a third branch inside the readiness poller -- the models are different enough
   that folding them together would leave both bent.

   `sc_cq_new` returns NULL wherever neither exists (macOS, an old Linux, a container that blocks the
   io_uring syscalls), and that is the signal to use sc_io.h instead. Nothing here replaces the readiness
   path: it is a faster road for the platforms that have one.

   THREADING: a queue may be submitted to from any thread -- coroutines run on every worker -- and reaped by
   one. Submission is serialised internally, because an io_uring submission queue has a single producer by
   design. */
#ifndef SC_CIO_H
#define SC_CIO_H

#include <stddef.h>
#include <stdint.h>

/* A completion queue sized for `entries` in-flight operations, or NULL if this platform has no completion
   engine (or it is unavailable, e.g. blocked by a container's seccomp profile). */
void *sc_cq_new(unsigned entries);
void sc_cq_free(void *q);

/* Submit one operation. 0 when it was queued, -1 when it could not be. `udata` is returned by sc_cq_wait
   and is never dereferenced here; the two largest uintptr_t values are RESERVED for the engine's own
   bookkeeping and must not be used as cookies. The BUFFER MUST STAY PUT until the completion arrives -- the kernel writes
   into it after this call returns, so it cannot live in a frame the coroutine is about to leave. */
int sc_cq_read(void *q, int fd, void *buf, size_t n, void *udata);
int sc_cq_write(void *q, int fd, const void *buf, size_t n, void *udata);
int sc_cq_accept(void *q, int lfd, void *udata);

/* Reap up to `max` completions into the parallel arrays: how many were filled, 0 if the timeout expired,
   -1 on error. `timeout_ms` < 0 waits indefinitely. A result is what the operation returned -- a byte count,
   a new descriptor -- or a NEGATIVE errno, which is how both engines report failure here. */
int sc_cq_wait(void *q, void **udata, long *res, int max, int timeout_ms);

/* Make a blocked sc_cq_wait return promptly, for shutdown. Safe from another thread. */
void sc_cq_wake(void *q);

#endif
