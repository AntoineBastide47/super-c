#ifndef SUPER_RT_H
#define SUPER_RT_H
#if __has_include(<assert.h>)
#include <assert.h>
#endif
#if __has_include(<complex.h>)
#include <complex.h>
#endif
#if __has_include(<ctype.h>)
#include <ctype.h>
#endif
#if __has_include(<errno.h>)
#include <errno.h>
#endif
#if __has_include(<fenv.h>)
#include <fenv.h>
#endif
#if __has_include(<float.h>)
#include <float.h>
#endif
#if __has_include(<inttypes.h>)
#include <inttypes.h>
#endif
#if __has_include(<iso646.h>)
#include <iso646.h>
#endif
#if __has_include(<limits.h>)
#include <limits.h>
#endif
#if __has_include(<locale.h>)
#include <locale.h>
#endif
#if __has_include(<math.h>)
#include <math.h>
#endif
#if __has_include(<dlfcn.h>)
#include <dlfcn.h>
#endif
#if __has_include(<signal.h>)
#include <signal.h>
#endif
#if __has_include(<stdalign.h>)
#include <stdalign.h>
#endif
#if __has_include(<stdarg.h>)
#include <stdarg.h>
#endif
#if __has_include(<stdatomic.h>)
#include <stdatomic.h>
#endif
#if __has_include(<stdbit.h>)
#include <stdbit.h>
#endif
#if __has_include(<stdbool.h>)
#include <stdbool.h>
#endif
#if __has_include(<stdckdint.h>)
#include <stdckdint.h>
#endif
#if __has_include(<stddef.h>)
#include <stddef.h>
#endif
#if __has_include(<stdint.h>)
#include <stdint.h>
#endif
#if __has_include(<stdio.h>)
#include <stdio.h>
#endif
#if __has_include(<stdlib.h>)
#include <stdlib.h>
#endif
#if __has_include(<stdnoreturn.h>)
#include <stdnoreturn.h>
#endif
#if __has_include(<string.h>)
#include <string.h>
#endif
#if __has_include(<tgmath.h>)
#include <tgmath.h>
#endif
#if __has_include(<threads.h>)
#include <threads.h>
#endif
#if __has_include(<time.h>)
#include <time.h>
#endif
#if __has_include(<uchar.h>)
#include <uchar.h>
#endif
#if __has_include(<wchar.h>)
#include <wchar.h>
#endif
#if __has_include(<wctype.h>)
#include <wctype.h>
#endif
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#define SC_AT(T,S) \
static inline T __sc_atomic_load_##S(const T*p){return __atomic_load_n(p,__ATOMIC_SEQ_CST);} \
static inline void __sc_atomic_store_##S(T*p,T v){__atomic_store_n(p,v,__ATOMIC_SEQ_CST);} \
static inline T __sc_atomic_swap_##S(T*p,T v){return __atomic_exchange_n(p,v,__ATOMIC_SEQ_CST);} \
static inline T __sc_atomic_add_##S(T*p,T v){return __atomic_fetch_add(p,v,__ATOMIC_SEQ_CST);} \
static inline T __sc_atomic_sub_##S(T*p,T v){return __atomic_fetch_sub(p,v,__ATOMIC_SEQ_CST);} \
static inline T __sc_atomic_and_##S(T*p,T v){return __atomic_fetch_and(p,v,__ATOMIC_SEQ_CST);} \
static inline T __sc_atomic_or_##S(T*p,T v){return __atomic_fetch_or(p,v,__ATOMIC_SEQ_CST);} \
static inline T __sc_atomic_xor_##S(T*p,T v){return __atomic_fetch_xor(p,v,__ATOMIC_SEQ_CST);} \
static inline bool __sc_atomic_cas_##S(T*p,T e,T d){return __atomic_compare_exchange_n(p,&e,d,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST);}
SC_AT(int8_t,i8) SC_AT(int16_t,i16) SC_AT(int32_t,i32) SC_AT(int64_t,i64) SC_AT(intptr_t,isize)
SC_AT(uint8_t,u8) SC_AT(uint16_t,u16) SC_AT(uint32_t,u32) SC_AT(uint64_t,u64) SC_AT(size_t,usize)
#undef SC_AT
static inline bool __sc_atomic_load_bool(const bool*p){return __atomic_load_n(p,__ATOMIC_SEQ_CST);}
static inline void __sc_atomic_store_bool(bool*p,bool v){__atomic_store_n(p,v,__ATOMIC_SEQ_CST);}
static inline bool __sc_atomic_swap_bool(bool*p,bool v){return __atomic_exchange_n(p,v,__ATOMIC_SEQ_CST);}
static inline bool __sc_atomic_cas_bool(bool*p,bool e,bool d){return __atomic_compare_exchange_n(p,&e,d,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST);}
static inline void __sc_atomic_fence(void){__atomic_thread_fence(__ATOMIC_SEQ_CST);}
#pragma GCC diagnostic pop
#endif
static inline __attribute__((unused)) FILE* __sc_stdin(void){return stdin;}
static inline __attribute__((unused)) FILE* __sc_stdout(void){return stdout;}
static inline __attribute__((unused)) FILE* __sc_stderr(void){return stderr;}
static inline __attribute__((unused)) int* __sc_errno_location(void){return &errno;}
static _Noreturn __attribute__((unused)) void __sc_panic(const char *__m) {
  fprintf(stderr, "super-c: %s\n", __m); abort();
}
static _Noreturn __attribute__((unused)) void __sc_panic_str(const uint8_t *__p, size_t __n) {
  fprintf(stderr, "panic: %.*s\n", (int)__n, (const char *)__p); abort();
}
static __attribute__((unused)) inline size_t __sc_bounds(size_t __i, size_t __n) {
  if (__i >= __n) __sc_panic("index out of bounds");
  return __i;
}
#endif
