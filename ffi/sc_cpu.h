/* CPU feature detection, the project's one detector, for std/cpu/detect.spc and C runtime code. Bit `i`
   of a feature word is the `cpu::Feature` variant of discriminant `i` (the compiler's feature table).
   Detection allocates nothing, takes no lock and runs once: a constructor runs it before `main`, and the
   first query runs it too. A feature the build's flags enable counts as present. */
#ifndef SC_CPU_H
#define SC_CPU_H

#include <stdint.h>

/* Detect the features; idempotent, safe before `main` and from any thread. */
void sc_cpu_init(void);
/* Whether feature `feature` (a `cpu::Feature` discriminant) is present: 1 or 0. */
int sc_cpu_has(int feature);
/* The present features, two words. */
void sc_cpu_words(uint64_t out[2]);
/* The features the OS query reports, without the build's own: a new query on each call. */
void sc_cpu_detected_words(uint64_t out[2]);
/* The features the build's flags enable (the C compiler's `__ARM_FEATURE_*`, `__wasm_simd128__`, ...
   macros), two words. */
void sc_cpu_static_words(uint64_t out[2]);
/* The x86 features (one word) of CPUID registers `r` (leaf 1 ECX; leaf 7.0 EBX, ECX, EDX; leaf 7.1
   EDX; leaf 80000001h ECX; leaf 24h EBX), XCR0 `xcr0`, and `os_zmm`, the OS's own report of the
   AVX-512 state (macOS). A pure function, on every host. */
uint64_t sc_cpu_x86_decide(const uint32_t r[7], uint64_t xcr0, int os_zmm);
/* How many times the OS query ran in this process (`sc_cpu_detected_words` included). */
int sc_cpu_query_count(void);

#endif
