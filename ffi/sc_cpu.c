/* CPU feature detection (see sc_cpu.h): per OS, the one query each offers. A failing or missing query
   means the feature is absent. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE 1 /* sysctlbyname's header under -D_POSIX_C_SOURCE */
#endif
#include "sc_cpu.h"

#include <stdlib.h>
#if defined(__aarch64__) || defined(_M_ARM64)
#if defined(__APPLE__)
#include <sys/sysctl.h>
#elif defined(_WIN32)
#include <windows.h>
#elif defined(__linux__)
#include <sys/auxv.h>
#endif
#elif defined(__x86_64__)
#include <cpuid.h>
#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif
#endif

/* The `cpu::Feature` discriminants, in the order of the compiler's table. */
enum {
  F_SIMD128, F_RELAXED_SIMD, F_SSE2, F_NEON, F_FP16, F_DOTPROD, F_RDM, F_I8MM, F_BF16, F_AES, F_SHA2, F_SHA3,
  F_CRC, F_LSE, F_SVE, F_SVE2, F_SSE3, F_SSSE3, F_SSE41, F_SSE42, F_POPCNT, F_CX16, F_LAHF_SAHF, F_AVX,
  F_AVX2, F_FMA, F_BMI1, F_BMI2, F_F16C, F_LZCNT, F_MOVBE, F_AVX512F, F_AVX512BW, F_AVX512CD, F_AVX512DQ,
  F_AVX512VL, F_AVX512VBMI, F_AVX512VBMI2, F_AVX512BITALG, F_AVX512VPOPCNTDQ, F_AVX512VNNI, F_AVX512FP16,
  F_GFNI, F_VAES, F_VPCLMULQDQ, F_AESNI, F_PCLMULQDQ, F_AVX101, F_AVX102
};

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
#ifdef __SSE3__
    | SC_BIT(F_SSE3)
#endif
#ifdef __SSSE3__
    | SC_BIT(F_SSSE3)
#endif
#ifdef __SSE4_1__
    | SC_BIT(F_SSE41)
#endif
#ifdef __SSE4_2__
    | SC_BIT(F_SSE42)
#endif
#ifdef __POPCNT__
    | SC_BIT(F_POPCNT)
#endif
#if defined(__x86_64__) && defined(__GCC_HAVE_SYNC_COMPARE_AND_SWAP_16)
    | SC_BIT(F_CX16)
#endif
#ifdef __LAHF_SAHF__
    | SC_BIT(F_LAHF_SAHF)
#endif
#ifdef __AVX__
    | SC_BIT(F_AVX)
#endif
#ifdef __AVX2__
    | SC_BIT(F_AVX2)
#endif
#ifdef __FMA__
    | SC_BIT(F_FMA)
#endif
#ifdef __BMI__
    | SC_BIT(F_BMI1)
#endif
#ifdef __BMI2__
    | SC_BIT(F_BMI2)
#endif
#ifdef __F16C__
    | SC_BIT(F_F16C)
#endif
#ifdef __LZCNT__
    | SC_BIT(F_LZCNT)
#endif
#ifdef __MOVBE__
    | SC_BIT(F_MOVBE)
#endif
#ifdef __AVX512F__
    | SC_BIT(F_AVX512F)
#endif
#ifdef __AVX512BW__
    | SC_BIT(F_AVX512BW)
#endif
#ifdef __AVX512CD__
    | SC_BIT(F_AVX512CD)
#endif
#ifdef __AVX512DQ__
    | SC_BIT(F_AVX512DQ)
#endif
#ifdef __AVX512VL__
    | SC_BIT(F_AVX512VL)
#endif
#ifdef __AVX512VBMI__
    | SC_BIT(F_AVX512VBMI)
#endif
#ifdef __AVX512VBMI2__
    | SC_BIT(F_AVX512VBMI2)
#endif
#ifdef __AVX512BITALG__
    | SC_BIT(F_AVX512BITALG)
#endif
#ifdef __AVX512VPOPCNTDQ__
    | SC_BIT(F_AVX512VPOPCNTDQ)
#endif
#ifdef __AVX512VNNI__
    | SC_BIT(F_AVX512VNNI)
#endif
#ifdef __AVX512FP16__
    | SC_BIT(F_AVX512FP16)
#endif
#ifdef __GFNI__
    | SC_BIT(F_GFNI)
#endif
#ifdef __VAES__
    | SC_BIT(F_VAES)
#endif
#ifdef __VPCLMULQDQ__
    | SC_BIT(F_VPCLMULQDQ)
#endif
#ifdef __AES__
    | SC_BIT(F_AESNI)
#endif
#ifdef __PCLMUL__
    | SC_BIT(F_PCLMULQDQ)
#endif
#if defined(__AVX10_1_512__) || defined(__AVX10_1__) && !defined(__AVX10_1_256__)
    | SC_BIT(F_AVX101)
#endif
#if defined(__AVX10_2_512__) || defined(__AVX10_2__) && !defined(__AVX10_2_256__)
    | SC_BIT(F_AVX102)
#endif
    ;

uint64_t sc_cpu_x86_decide(const uint32_t r[7], uint64_t xcr0, int os_zmm) {
  /* The CPUID bit of each feature: register r[reg], bit `bit`; `state` 1 needs the AVX register state,
     2 the AVX-512 state too. */
  static const struct { unsigned char reg, bit, f, state; } rows[] = {
      {0, 0, F_SSE3, 0},           {0, 9, F_SSSE3, 0},          {0, 19, F_SSE41, 0},        {0, 20, F_SSE42, 0},
      {0, 23, F_POPCNT, 0},        {0, 13, F_CX16, 0},          {5, 0, F_LAHF_SAHF, 0},     {0, 28, F_AVX, 1},
      {1, 5, F_AVX2, 1},           {0, 12, F_FMA, 1},           {1, 3, F_BMI1, 0},          {1, 8, F_BMI2, 0},
      {0, 29, F_F16C, 1},          {5, 5, F_LZCNT, 0},          {0, 22, F_MOVBE, 0},        {1, 16, F_AVX512F, 2},
      {1, 30, F_AVX512BW, 2},      {1, 28, F_AVX512CD, 2},      {1, 17, F_AVX512DQ, 2},     {1, 31, F_AVX512VL, 2},
      {2, 1, F_AVX512VBMI, 2},     {2, 6, F_AVX512VBMI2, 2},    {2, 12, F_AVX512BITALG, 2}, {2, 14, F_AVX512VPOPCNTDQ, 2},
      {2, 11, F_AVX512VNNI, 2},    {3, 23, F_AVX512FP16, 2},    {2, 8, F_GFNI, 0},          {2, 9, F_VAES, 1},
      {2, 10, F_VPCLMULQDQ, 1},    {0, 25, F_AESNI, 0},         {0, 1, F_PCLMULQDQ, 0},
  };
  /* OSXSAVE and XCR0 bits 1 and 2 (SSE and AVX state); bits 5 to 7 (opmask and ZMM state), which macOS
     enables per thread on first use, so there the OS's own answer stands for them. */
  int ymm = (r[0] >> 27 & 1) && (xcr0 & 6) == 6;
  int zmm = ymm && (os_zmm || (xcr0 & 0xE0) == 0xE0);
  uint64_t w = SC_BIT(F_SSE2);
  for (unsigned i = 0; i < sizeof rows / sizeof rows[0]; i++)
    if ((r[rows[i].reg] >> rows[i].bit & 1) && (rows[i].state == 0 || (rows[i].state == 1 ? ymm : zmm)))
      w |= SC_BIT(rows[i].f);
  /* AVX10: CPUID.(7,1):EDX bit 19, the version in CPUID.24h:EBX bits 0 to 7, the 512-bit form bit 18. */
  if (zmm && (r[4] >> 19 & 1) && (r[6] >> 18 & 1) && (r[6] & 0xFF) >= 1)
    w |= SC_BIT(F_AVX101) | ((r[6] & 0xFF) >= 2 ? SC_BIT(F_AVX102) : 0);
  return w;
}

/* The OS queries made: one per process unless two first callers race. */
static int sc_cpu_queries;

int sc_cpu_query_count(void) { return __atomic_load_n(&sc_cpu_queries, __ATOMIC_RELAXED); }

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
#elif defined(__x86_64__)
  /* CPUID leaves 1, (7,0), (7,1) when (7,0) reports it, 80000001h and 24h; a leaf past the maximum
     reads as zeros. */
  uint32_t r[7] = {0}, a, b, c, d, sub7 = 0;
  if (__get_cpuid_count(1, 0, &a, &b, &c, &d))
    r[0] = c;
  if (__get_cpuid_count(7, 0, &a, &b, &c, &d))
    r[1] = b, r[2] = c, r[3] = d, sub7 = a;
  if (sub7 >= 1 && __get_cpuid_count(7, 1, &a, &b, &c, &d))
    r[4] = d;
  if (__get_cpuid_count(0x80000001u, 0, &a, &b, &c, &d))
    r[5] = c;
  if (__get_cpuid_count(0x24, 0, &a, &b, &c, &d))
    r[6] = b;
  uint64_t xcr0 = 0;
  if (r[0] >> 27 & 1) {
    /* XGETBV(0); `_xgetbv` would need `-mxsave` under GCC. */
    __asm__ volatile("xgetbv" : "=a"(a), "=d"(d) : "c"(0));
    xcr0 = (uint64_t)d << 32 | a;
  }
  int os_zmm = 0;
#if defined(__APPLE__)
  size_t n = sizeof os_zmm;
  if (sysctlbyname("hw.optional.avx512f", &os_zmm, &n, NULL, 0) != 0 || n != sizeof os_zmm)
    os_zmm = 0;
#endif
  w = sc_cpu_x86_decide(r, xcr0, os_zmm);
#endif
  /* SC_CPU_OFF (a test switch): a mask of detected features to report absent. */
  const char *off = getenv("SC_CPU_OFF");
  if (off != NULL)
    w &= ~(uint64_t)strtoull(off, NULL, 0);
  __atomic_add_fetch(&sc_cpu_queries, 1, __ATOMIC_RELAXED);
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
