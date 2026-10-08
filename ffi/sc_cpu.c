/* CPU feature detection (see sc_cpu.h): per OS, the one query each offers. A failing or missing query
   means the feature is absent. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE 1 /* sysctlbyname's header under -D_POSIX_C_SOURCE */
#endif
#include "sc_cpu.h"

#if defined(__aarch64__) || defined(_M_ARM64)
#if defined(__APPLE__)
#include <sys/sysctl.h>
#elif defined(_WIN32)
#include <windows.h>
#elif defined(__linux__)
#include <sys/auxv.h>
#endif
#endif

/* The `cpu::Feature` discriminants, in the order of the compiler's table. */
enum { F_SIMD128, F_RELAXED_SIMD, F_SSE2, F_NEON, F_FP16, F_DOTPROD, F_RDM, F_I8MM, F_BF16, F_AES, F_SHA2, F_SHA3, F_CRC, F_LSE, F_SVE, F_SVE2 };

#define SC_BIT(f) ((uint64_t)1 << (f))

/* The features the build's flags enable: present wherever the program runs. */
static const uint64_t sc_cpu_static = 0
#ifdef __wasm_simd128__
    | SC_BIT(F_SIMD128)
#endif
#ifdef __wasm_relaxed_simd__
    | SC_BIT(F_RELAXED_SIMD)
#endif
#if defined(__SSE2__) || defined(_M_X64)
    | SC_BIT(F_SSE2)
#endif
#if defined(__ARM_NEON) || defined(_M_ARM64)
    | SC_BIT(F_NEON)
#endif
#ifdef __ARM_FEATURE_FP16_VECTOR_ARITHMETIC
    | SC_BIT(F_FP16)
#endif
#ifdef __ARM_FEATURE_DOTPROD
    | SC_BIT(F_DOTPROD)
#endif
#ifdef __ARM_FEATURE_QRDMX
    | SC_BIT(F_RDM)
#endif
#ifdef __ARM_FEATURE_MATMUL_INT8
    | SC_BIT(F_I8MM)
#endif
#ifdef __ARM_FEATURE_BF16_VECTOR_ARITHMETIC
    | SC_BIT(F_BF16)
#endif
#ifdef __ARM_FEATURE_AES
    | SC_BIT(F_AES)
#endif
#ifdef __ARM_FEATURE_SHA2
    | SC_BIT(F_SHA2)
#endif
#ifdef __ARM_FEATURE_SHA3
    | SC_BIT(F_SHA3)
#endif
#ifdef __ARM_FEATURE_CRC32
    | SC_BIT(F_CRC)
#endif
#ifdef __ARM_FEATURE_ATOMICS
    | SC_BIT(F_LSE)
#endif
#ifdef __ARM_FEATURE_SVE
    | SC_BIT(F_SVE)
#endif
#ifdef __ARM_FEATURE_SVE2
    | SC_BIT(F_SVE2)
#endif
    ;

/* The OS query's answer. Every row names the query of one feature. */
static uint64_t sc_cpu_detect(void) {
  uint64_t w = 0;
#if (defined(__aarch64__) || defined(_M_ARM64)) && defined(__APPLE__)
  /* hw.optional.arm.FEAT_*: 1 when present; a missing key (no SVE key exists) means absent. */
  static const struct { const char *key; int f; } rows[] = {
      {"hw.optional.arm.FEAT_FP16", F_FP16}, {"hw.optional.arm.FEAT_DotProd", F_DOTPROD},
      {"hw.optional.arm.FEAT_RDM", F_RDM},   {"hw.optional.arm.FEAT_I8MM", F_I8MM},
      {"hw.optional.arm.FEAT_BF16", F_BF16}, {"hw.optional.arm.FEAT_AES", F_AES},
      {"hw.optional.arm.FEAT_SHA256", F_SHA2}, {"hw.optional.arm.FEAT_SHA3", F_SHA3},
      {"hw.optional.arm.FEAT_CRC32", F_CRC}, {"hw.optional.arm.FEAT_LSE", F_LSE},
  };
  w |= SC_BIT(F_NEON);
  for (unsigned i = 0; i < sizeof rows / sizeof rows[0]; i++) {
    int v = 0;
    size_t n = sizeof v;
    if (sysctlbyname(rows[i].key, &v, &n, NULL, 0) == 0 && n == sizeof v && v != 0)
      w |= SC_BIT(rows[i].f);
  }
#elif (defined(__aarch64__) || defined(_M_ARM64)) && defined(_WIN32)
  /* PF_ARM_* values of the IsProcessorFeaturePresent documentation; older MinGW headers lack some
     names. A V8 crypto bit covers AES and SHA-2; no constant exists for RDM. 0 means absent. */
  static const struct { DWORD pf; int f; } rows[] = {
      {67, F_FP16}, {43, F_DOTPROD}, {66, F_I8MM}, {68, F_BF16}, {30, F_AES}, {30, F_SHA2},
      {64, F_SHA3}, {31, F_CRC},     {34, F_LSE},  {46, F_SVE},  {47, F_SVE2},
  };
  w |= SC_BIT(F_NEON);
  for (unsigned i = 0; i < sizeof rows / sizeof rows[0]; i++)
    if (IsProcessorFeaturePresent(rows[i].pf))
      w |= SC_BIT(rows[i].f);
#elif defined(__aarch64__) && defined(__linux__)
  /* The HWCAP and HWCAP2 bits of the kernel's arch/arm64/include/uapi/asm/hwcap.h (older libc headers
     lack some names). fp16 needs both its scalar and its vector bit. getauxval gives 0 when absent. */
  static const struct { unsigned char word, bit; int f; } rows[] = {
      {0, 1, F_NEON},     {0, 20, F_DOTPROD}, {0, 12, F_RDM},  {1, 13, F_I8MM}, {1, 14, F_BF16},
      {0, 3, F_AES},      {0, 6, F_SHA2},     {0, 17, F_SHA3}, {0, 7, F_CRC},   {0, 8, F_LSE},
      {0, 22, F_SVE},     {1, 1, F_SVE2},
  };
  unsigned long hw[2] = {getauxval(AT_HWCAP), 0};
#ifdef AT_HWCAP2
  hw[1] = getauxval(AT_HWCAP2);
#endif
  for (unsigned i = 0; i < sizeof rows / sizeof rows[0]; i++)
    if (hw[rows[i].word] >> rows[i].bit & 1)
      w |= SC_BIT(rows[i].f);
  if ((hw[0] >> 9 & 1) && (hw[0] >> 10 & 1))
    w |= SC_BIT(F_FP16);
#endif
  return w;
}

/* The answer, then the state word: a reader that sees the state set sees the answer. Two first callers
   store equal words. */
static uint64_t sc_cpu_word;
static int sc_cpu_ready;

void sc_cpu_init(void) {
  if (__atomic_load_n(&sc_cpu_ready, __ATOMIC_ACQUIRE))
    return;
  __atomic_store_n(&sc_cpu_word, sc_cpu_detect() | sc_cpu_static, __ATOMIC_RELAXED);
  __atomic_store_n(&sc_cpu_ready, 1, __ATOMIC_RELEASE);
}

__attribute__((constructor)) static void sc_cpu_ctor(void) { sc_cpu_init(); }

int sc_cpu_has(int feature) {
  sc_cpu_init();
  return feature >= 0 && feature < 64 && (int)(__atomic_load_n(&sc_cpu_word, __ATOMIC_RELAXED) >> feature & 1);
}

void sc_cpu_words(uint64_t out[2]) {
  sc_cpu_init();
  out[0] = __atomic_load_n(&sc_cpu_word, __ATOMIC_RELAXED);
  out[1] = 0;
}

void sc_cpu_detected_words(uint64_t out[2]) {
  out[0] = sc_cpu_detect();
  out[1] = 0;
}

void sc_cpu_static_words(uint64_t out[2]) {
  out[0] = sc_cpu_static;
  out[1] = 0;
}
