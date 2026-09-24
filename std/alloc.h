/* Over-aligned heap blocks for std's Global allocator (see interfaces.spc). The platform call differs
   (aligned_alloc on POSIX and wasi-libc, _aligned_malloc on Windows, whose blocks need _aligned_free),
   so the choice is made where the C compiler knows the target. */
#ifndef SC_ALLOC_H
#define SC_ALLOC_H
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#if defined(_WIN32)
#include <malloc.h>
#endif
#ifdef SC_LK_ALIGNED
/* The leak tracker is compiled in (super_rt.h): it allocates, records and releases over-aligned blocks,
   as its malloc/free macros do for the others. */
#define sc_alloc_aligned(size, align) sc_lk_aligned_alloc(size, align)
#define sc_free_aligned(p) sc_lk_aligned_free(p)
#else
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#endif
/* `size` bytes aligned to `align` (a power of two, at least sizeof(void *)); NULL when out of memory. */
static inline void *sc_alloc_aligned(size_t size, size_t align) {
#if defined(_WIN32)
  return _aligned_malloc(size, align);
#else
  /* C11 aligned_alloc: declared under a strict -std=c11, where glibc hides posix_memalign from a plain C
     consumer of the emitted headers. Its size must be a multiple of the alignment. */
  if (size > SIZE_MAX - align) return NULL;
  return aligned_alloc(align, (size + align - 1) & ~(align - 1));
#endif
}
/* Releases a block from sc_alloc_aligned; NULL is a no-op. */
static inline void sc_free_aligned(void *p) {
#if defined(_WIN32)
  _aligned_free(p);
#else
  free(p);
#endif
}
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic pop
#endif
#endif /* SC_LK_ALIGNED */
#endif /* SC_ALLOC_H */
