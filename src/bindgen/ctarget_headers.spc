// The compiler's built-in headers (a resource directory's files), found under BUILTIN_DIR before the C
// library's. Each reads the target's predefined macros; one a C library may supply defers to it with
// `#include_next`. Derived from clang's headers (Apache-2.0 WITH LLVM-exception; each carries the notice):
// ptrauth.h, stdatomic.h, stddef.h, limits.h, stdint.h, and the SIMD headers' types and prototypes (the
// intrinsic bodies are compiler built-ins no C library declaration uses). The rest follow the C standard.

/// One built-in header: its name, the instruction sets that have it (bit 0 x86_64, bit 1 aarch64,
/// bit 2 wasm32) and its text.
pub(package) struct Header {
    pub(package) name: str<'static>,
    pub(package) arch: u8,
    pub(package) text: str<'static>,
}

/// Every built-in header, in name order.
pub(package) const HEADERS: [Header; 37] = [
    Header {
        name: "amxintrin.h",
        arch: 1,
        text: M"(/* Derived from clang's <amxintrin.h>. Part of the LLVM Project, under the Apache License v2.0 with
   LLVM Exceptions. See https://llvm.org/LICENSE.txt for license information.
   SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception */
#ifndef __SC_AMXINTRIN_H
#define __SC_AMXINTRIN_H
typedef int _tile1024i __attribute__((__vector_size__(1024), __aligned__(64)));
typedef struct __tile1024i_str { const unsigned short row; const unsigned short col; _tile1024i tile; } __tile1024i;
#endif
)",
    },
    Header {
        name: "arm_acle.h",
        arch: 2,
        text: M"(/* Derived from clang's <arm_acle.h>. Part of the LLVM Project, under the Apache License v2.0 with
   LLVM Exceptions. See https://llvm.org/LICENSE.txt for license information.
   SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception */
#ifndef __SC_ARM_ACLE_H
#define __SC_ARM_ACLE_H
#include <stdint.h>
void __dmb(unsigned int);
void __dsb(unsigned int);
void __isb(unsigned int);
void __wfi(void);
void __wfe(void);
void __sev(void);
void __sevl(void);
void __yield(void);
typedef struct { uint64_t val[8]; } data512_t;
#endif
)",
    },
    Header {
        name: "arm_neon.h",
        arch: 2,
        text: M"(/* Derived from clang's <arm_neon.h>. Part of the LLVM Project, under the Apache License v2.0 with
   LLVM Exceptions. See https://llvm.org/LICENSE.txt for license information.
   SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception */
#ifndef __SC_ARM_NEON_H
#define __SC_ARM_NEON_H
#include <stdint.h>
typedef __bf16 bfloat16_t;
typedef float float32_t;
typedef __fp16 float16_t;
typedef __mfp8 mfloat8_t;
typedef double float64_t;
typedef uint64_t fpm_t;
enum __ARM_FPM_FORMAT { __ARM_FPM_E5M2, __ARM_FPM_E4M3 };
enum __ARM_FPM_OVERFLOW { __ARM_FPM_INFNAN, __ARM_FPM_SATURATE };
typedef __attribute__((neon_vector_type(8))) int8_t int8x8_t;
typedef __attribute__((neon_vector_type(16))) int8_t int8x16_t;
typedef __attribute__((neon_vector_type(4))) int16_t int16x4_t;
typedef __attribute__((neon_vector_type(8))) int16_t int16x8_t;
typedef __attribute__((neon_vector_type(2))) int32_t int32x2_t;
typedef __attribute__((neon_vector_type(4))) int32_t int32x4_t;
typedef __attribute__((neon_vector_type(1))) int64_t int64x1_t;
typedef __attribute__((neon_vector_type(2))) int64_t int64x2_t;
typedef __attribute__((neon_vector_type(8))) uint8_t uint8x8_t;
typedef __attribute__((neon_vector_type(16))) uint8_t uint8x16_t;
typedef __attribute__((neon_vector_type(4))) uint16_t uint16x4_t;
typedef __attribute__((neon_vector_type(8))) uint16_t uint16x8_t;
typedef __attribute__((neon_vector_type(2))) uint32_t uint32x2_t;
typedef __attribute__((neon_vector_type(4))) uint32_t uint32x4_t;
typedef __attribute__((neon_vector_type(1))) uint64_t uint64x1_t;
typedef __attribute__((neon_vector_type(2))) uint64_t uint64x2_t;
typedef __attribute__((neon_vector_type(8))) mfloat8_t mfloat8x8_t;
typedef __attribute__((neon_vector_type(16))) mfloat8_t mfloat8x16_t;
typedef __attribute__((neon_vector_type(4))) float16_t float16x4_t;
typedef __attribute__((neon_vector_type(8))) float16_t float16x8_t;
typedef __attribute__((neon_vector_type(2))) float32_t float32x2_t;
typedef __attribute__((neon_vector_type(4))) float32_t float32x4_t;
typedef __attribute__((neon_vector_type(1))) float64_t float64x1_t;
typedef __attribute__((neon_vector_type(2))) float64_t float64x2_t;
typedef struct int8x8x2_t { int8x8_t val[2]; } int8x8x2_t;
typedef struct int8x16x2_t { int8x16_t val[2]; } int8x16x2_t;
typedef struct int16x4x2_t { int16x4_t val[2]; } int16x4x2_t;
typedef struct int16x8x2_t { int16x8_t val[2]; } int16x8x2_t;
typedef struct int32x2x2_t { int32x2_t val[2]; } int32x2x2_t;
typedef struct int32x4x2_t { int32x4_t val[2]; } int32x4x2_t;
typedef struct int64x1x2_t { int64x1_t val[2]; } int64x1x2_t;
typedef struct int64x2x2_t { int64x2_t val[2]; } int64x2x2_t;
typedef struct uint8x8x2_t { uint8x8_t val[2]; } uint8x8x2_t;
typedef struct uint8x16x2_t { uint8x16_t val[2]; } uint8x16x2_t;
typedef struct uint16x4x2_t { uint16x4_t val[2]; } uint16x4x2_t;
typedef struct uint16x8x2_t { uint16x8_t val[2]; } uint16x8x2_t;
typedef struct uint32x2x2_t { uint32x2_t val[2]; } uint32x2x2_t;
typedef struct uint32x4x2_t { uint32x4_t val[2]; } uint32x4x2_t;
typedef struct uint64x1x2_t { uint64x1_t val[2]; } uint64x1x2_t;
typedef struct uint64x2x2_t { uint64x2_t val[2]; } uint64x2x2_t;
typedef struct mfloat8x8x2_t { mfloat8x8_t val[2]; } mfloat8x8x2_t;
typedef struct mfloat8x16x2_t { mfloat8x16_t val[2]; } mfloat8x16x2_t;
typedef struct float16x4x2_t { float16x4_t val[2]; } float16x4x2_t;
typedef struct float16x8x2_t { float16x8_t val[2]; } float16x8x2_t;
typedef struct float32x2x2_t { float32x2_t val[2]; } float32x2x2_t;
typedef struct float32x4x2_t { float32x4_t val[2]; } float32x4x2_t;
typedef struct float64x1x2_t { float64x1_t val[2]; } float64x1x2_t;
typedef struct float64x2x2_t { float64x2_t val[2]; } float64x2x2_t;
typedef struct int8x8x3_t { int8x8_t val[3]; } int8x8x3_t;
typedef struct int8x16x3_t { int8x16_t val[3]; } int8x16x3_t;
typedef struct int16x4x3_t { int16x4_t val[3]; } int16x4x3_t;
typedef struct int16x8x3_t { int16x8_t val[3]; } int16x8x3_t;
typedef struct int32x2x3_t { int32x2_t val[3]; } int32x2x3_t;
typedef struct int32x4x3_t { int32x4_t val[3]; } int32x4x3_t;
typedef struct int64x1x3_t { int64x1_t val[3]; } int64x1x3_t;
typedef struct int64x2x3_t { int64x2_t val[3]; } int64x2x3_t;
typedef struct uint8x8x3_t { uint8x8_t val[3]; } uint8x8x3_t;
typedef struct uint8x16x3_t { uint8x16_t val[3]; } uint8x16x3_t;
typedef struct uint16x4x3_t { uint16x4_t val[3]; } uint16x4x3_t;
typedef struct uint16x8x3_t { uint16x8_t val[3]; } uint16x8x3_t;
typedef struct uint32x2x3_t { uint32x2_t val[3]; } uint32x2x3_t;
typedef struct uint32x4x3_t { uint32x4_t val[3]; } uint32x4x3_t;
typedef struct uint64x1x3_t { uint64x1_t val[3]; } uint64x1x3_t;
typedef struct uint64x2x3_t { uint64x2_t val[3]; } uint64x2x3_t;
typedef struct mfloat8x8x3_t { mfloat8x8_t val[3]; } mfloat8x8x3_t;
typedef struct mfloat8x16x3_t { mfloat8x16_t val[3]; } mfloat8x16x3_t;
typedef struct float16x4x3_t { float16x4_t val[3]; } float16x4x3_t;
typedef struct float16x8x3_t { float16x8_t val[3]; } float16x8x3_t;
typedef struct float32x2x3_t { float32x2_t val[3]; } float32x2x3_t;
typedef struct float32x4x3_t { float32x4_t val[3]; } float32x4x3_t;
typedef struct float64x1x3_t { float64x1_t val[3]; } float64x1x3_t;
typedef struct float64x2x3_t { float64x2_t val[3]; } float64x2x3_t;
typedef struct int8x8x4_t { int8x8_t val[4]; } int8x8x4_t;
typedef struct int8x16x4_t { int8x16_t val[4]; } int8x16x4_t;
typedef struct int16x4x4_t { int16x4_t val[4]; } int16x4x4_t;
typedef struct int16x8x4_t { int16x8_t val[4]; } int16x8x4_t;
typedef struct int32x2x4_t { int32x2_t val[4]; } int32x2x4_t;
typedef struct int32x4x4_t { int32x4_t val[4]; } int32x4x4_t;
typedef struct int64x1x4_t { int64x1_t val[4]; } int64x1x4_t;
typedef struct int64x2x4_t { int64x2_t val[4]; } int64x2x4_t;
typedef struct uint8x8x4_t { uint8x8_t val[4]; } uint8x8x4_t;
typedef struct uint8x16x4_t { uint8x16_t val[4]; } uint8x16x4_t;
typedef struct uint16x4x4_t { uint16x4_t val[4]; } uint16x4x4_t;
typedef struct uint16x8x4_t { uint16x8_t val[4]; } uint16x8x4_t;
typedef struct uint32x2x4_t { uint32x2_t val[4]; } uint32x2x4_t;
typedef struct uint32x4x4_t { uint32x4_t val[4]; } uint32x4x4_t;
typedef struct uint64x1x4_t { uint64x1_t val[4]; } uint64x1x4_t;
typedef struct uint64x2x4_t { uint64x2_t val[4]; } uint64x2x4_t;
typedef struct mfloat8x8x4_t { mfloat8x8_t val[4]; } mfloat8x8x4_t;
typedef struct mfloat8x16x4_t { mfloat8x16_t val[4]; } mfloat8x16x4_t;
typedef struct float16x4x4_t { float16x4_t val[4]; } float16x4x4_t;
typedef struct float16x8x4_t { float16x8_t val[4]; } float16x8x4_t;
typedef struct float32x2x4_t { float32x2_t val[4]; } float32x2x4_t;
typedef struct float32x4x4_t { float32x4_t val[4]; } float32x4x4_t;
typedef struct float64x1x4_t { float64x1_t val[4]; } float64x1x4_t;
typedef struct float64x2x4_t { float64x2_t val[4]; } float64x2x4_t;
typedef __attribute__((neon_vector_type(4))) bfloat16_t bfloat16x4_t;
typedef __attribute__((neon_vector_type(8))) bfloat16_t bfloat16x8_t;
typedef struct bfloat16x4x2_t { bfloat16x4_t val[2]; } bfloat16x4x2_t;
typedef struct bfloat16x8x2_t { bfloat16x8_t val[2]; } bfloat16x8x2_t;
typedef struct bfloat16x4x3_t { bfloat16x4_t val[3]; } bfloat16x4x3_t;
typedef struct bfloat16x8x3_t { bfloat16x8_t val[3]; } bfloat16x8x3_t;
typedef struct bfloat16x4x4_t { bfloat16x4_t val[4]; } bfloat16x4x4_t;
typedef struct bfloat16x8x4_t { bfloat16x8_t val[4]; } bfloat16x8x4_t;
typedef uint16_t poly16_t;
typedef uint64_t poly64_t;
typedef __uint128_t poly128_t;
typedef uint8_t poly8_t;
typedef uint16_t poly16_t;
typedef uint64_t poly64_t;
typedef __uint128_t poly128_t;
typedef __attribute__((neon_polyvector_type(8))) poly8_t poly8x8_t;
typedef __attribute__((neon_polyvector_type(16))) poly8_t poly8x16_t;
typedef __attribute__((neon_polyvector_type(4))) poly16_t poly16x4_t;
typedef __attribute__((neon_polyvector_type(8))) poly16_t poly16x8_t;
typedef __attribute__((neon_polyvector_type(1))) poly64_t poly64x1_t;
typedef __attribute__((neon_polyvector_type(2))) poly64_t poly64x2_t;
typedef struct poly8x8x2_t { poly8x8_t val[2]; } poly8x8x2_t;
typedef struct poly8x16x2_t { poly8x16_t val[2]; } poly8x16x2_t;
typedef struct poly16x4x2_t { poly16x4_t val[2]; } poly16x4x2_t;
typedef struct poly16x8x2_t { poly16x8_t val[2]; } poly16x8x2_t;
typedef struct poly64x1x2_t { poly64x1_t val[2]; } poly64x1x2_t;
typedef struct poly64x2x2_t { poly64x2_t val[2]; } poly64x2x2_t;
typedef struct poly8x8x3_t { poly8x8_t val[3]; } poly8x8x3_t;
typedef struct poly8x16x3_t { poly8x16_t val[3]; } poly8x16x3_t;
typedef struct poly16x4x3_t { poly16x4_t val[3]; } poly16x4x3_t;
typedef struct poly16x8x3_t { poly16x8_t val[3]; } poly16x8x3_t;
typedef struct poly64x1x3_t { poly64x1_t val[3]; } poly64x1x3_t;
typedef struct poly64x2x3_t { poly64x2_t val[3]; } poly64x2x3_t;
typedef struct poly8x8x4_t { poly8x8_t val[4]; } poly8x8x4_t;
typedef struct poly8x16x4_t { poly8x16_t val[4]; } poly8x16x4_t;
typedef struct poly16x4x4_t { poly16x4_t val[4]; } poly16x4x4_t;
typedef struct poly16x8x4_t { poly16x8_t val[4]; } poly16x8x4_t;
typedef struct poly64x1x4_t { poly64x1_t val[4]; } poly64x1x4_t;
typedef struct poly64x2x4_t { poly64x2_t val[4]; } poly64x2x4_t;
#endif
)",
    },
    Header {
        name: "avx2intrin.h",
        arch: 1,
        text: M"(/* x86 AVX2 intrinsics: functions are compiler built-ins (see <mmintrin.h>). */
#ifndef __SC_AVX2INTRIN_H
#define __SC_AVX2INTRIN_H
#include <avxintrin.h>
#endif
)",
    },
    Header {
        name: "avx512bf16intrin.h",
        arch: 1,
        text: M"(/* Derived from clang's <avx512bf16intrin.h>. Part of the LLVM Project, under the Apache License v2.0 with
   LLVM Exceptions. See https://llvm.org/LICENSE.txt for license information.
   SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception */
#ifndef __SC_AVX512BF16INTRIN_H
#define __SC_AVX512BF16INTRIN_H
#include <avx512fintrin.h>
typedef __bf16 __v32bf __attribute__((__vector_size__(64), __aligned__(64)));
typedef __bf16 __m512bh __attribute__((__vector_size__(64), __aligned__(64)));
typedef __bf16 __bfloat16 __attribute__((deprecated("use __bf16 instead")));
#endif
)",
    },
    Header {
        name: "avx512fintrin.h",
        arch: 1,
        text: M"(/* Derived from clang's <avx512fintrin.h>. Part of the LLVM Project, under the Apache License v2.0 with
   LLVM Exceptions. See https://llvm.org/LICENSE.txt for license information.
   SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception */
#ifndef __SC_AVX512FINTRIN_H
#define __SC_AVX512FINTRIN_H
#include <avxintrin.h>
typedef char __v64qi __attribute__((__vector_size__(64)));
typedef short __v32hi __attribute__((__vector_size__(64)));
typedef double __v8df __attribute__((__vector_size__(64)));
typedef float __v16sf __attribute__((__vector_size__(64)));
typedef long long __v8di __attribute__((__vector_size__(64)));
typedef int __v16si __attribute__((__vector_size__(64)));
typedef unsigned char __v64qu __attribute__((__vector_size__(64)));
typedef unsigned short __v32hu __attribute__((__vector_size__(64)));
typedef unsigned long long __v8du __attribute__((__vector_size__(64)));
typedef unsigned int __v16su __attribute__((__vector_size__(64)));
typedef signed char __v64qs __attribute__((__vector_size__(64)));
typedef float __m512 __attribute__((__vector_size__(64), __aligned__(64)));
typedef double __m512d __attribute__((__vector_size__(64), __aligned__(64)));
typedef long long __m512i __attribute__((__vector_size__(64), __aligned__(64)));
typedef float __m512_u __attribute__((__vector_size__(64), __aligned__(1)));
typedef double __m512d_u __attribute__((__vector_size__(64), __aligned__(1)));
typedef long long __m512i_u __attribute__((__vector_size__(64), __aligned__(1)));
typedef unsigned char __mmask8;
typedef unsigned short __mmask16;
#endif
)",
    },
    Header {
        name: "avx512fp16intrin.h",
        arch: 1,
        text: M"(/* Derived from clang's <avx512fp16intrin.h>. Part of the LLVM Project, under the Apache License v2.0 with
   LLVM Exceptions. See https://llvm.org/LICENSE.txt for license information.
   SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception */
#ifndef __SC_AVX512FP16INTRIN_H
#define __SC_AVX512FP16INTRIN_H
#include <avx512fintrin.h>
typedef _Float16 __v32hf __attribute__((__vector_size__(64), __aligned__(64)));
typedef _Float16 __m512h __attribute__((__vector_size__(64), __aligned__(64)));
typedef _Float16 __m512h_u __attribute__((__vector_size__(64), __aligned__(1)));
#endif
)",
    },
    Header {
        name: "avxintrin.h",
        arch: 1,
        text: M"(/* Derived from clang's <avxintrin.h>. Part of the LLVM Project, under the Apache License v2.0 with
   LLVM Exceptions. See https://llvm.org/LICENSE.txt for license information.
   SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception */
#ifndef __SC_AVXINTRIN_H
#define __SC_AVXINTRIN_H
#include <emmintrin.h>
typedef double __v4df __attribute__ ((__vector_size__ (32)));
typedef float __v8sf __attribute__ ((__vector_size__ (32)));
typedef long long __v4di __attribute__ ((__vector_size__ (32)));
typedef int __v8si __attribute__ ((__vector_size__ (32)));
typedef short __v16hi __attribute__ ((__vector_size__ (32)));
typedef char __v32qi __attribute__ ((__vector_size__ (32)));
typedef unsigned long long __v4du __attribute__ ((__vector_size__ (32)));
typedef unsigned int __v8su __attribute__ ((__vector_size__ (32)));
typedef unsigned short __v16hu __attribute__ ((__vector_size__ (32)));
typedef unsigned char __v32qu __attribute__ ((__vector_size__ (32)));
typedef signed char __v32qs __attribute__((__vector_size__(32)));
typedef float __m256 __attribute__ ((__vector_size__ (32), __aligned__(32)));
typedef double __m256d __attribute__((__vector_size__(32), __aligned__(32)));
typedef long long __m256i __attribute__((__vector_size__(32), __aligned__(32)));
typedef float __m256_u __attribute__ ((__vector_size__ (32), __aligned__(1)));
typedef double __m256d_u __attribute__((__vector_size__(32), __aligned__(1)));
typedef long long __m256i_u __attribute__((__vector_size__(32), __aligned__(1)));
typedef _Float16 __v16hf __attribute__((__vector_size__(32), __aligned__(32)));
typedef _Float16 __m256h __attribute__((__vector_size__(32), __aligned__(32)));
typedef _Float16 __m256h_u __attribute__((__vector_size__(32), __aligned__(1)));
typedef __bf16 __v16bf __attribute__((__vector_size__(32), __aligned__(32)));
typedef __bf16 __m256bh __attribute__((__vector_size__(32), __aligned__(32)));
#endif
)",
    },
    Header {
        name: "cpuid.h",
        arch: 1,
        text: M"(/* x86 CPU identification (see <mmintrin.h>): the functions are inline assembly in the compiler's
   header; nothing here is a type. */
#ifndef __SC_CPUID_H
#define __SC_CPUID_H
#endif
)",
    },
    Header {
        name: "emmintrin.h",
        arch: 1,
        text: M"(/* Derived from clang's <emmintrin.h>. Part of the LLVM Project, under the Apache License v2.0 with
   LLVM Exceptions. See https://llvm.org/LICENSE.txt for license information.
   SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception */
#ifndef __SC_EMMINTRIN_H
#define __SC_EMMINTRIN_H
#include <xmmintrin.h>
typedef double __m128d __attribute__((__vector_size__(16), __aligned__(16)));
typedef double __m128d_u __attribute__((__vector_size__(16), __aligned__(1)));
typedef long long __m128i_u __attribute__((__vector_size__(16), __aligned__(1)));
typedef double __v2df __attribute__((__vector_size__(16)));
typedef unsigned long long __v2du __attribute__((__vector_size__(16)));
typedef signed char __v16qs __attribute__((__vector_size__(16)));
typedef _Float16 __v8hf __attribute__((__vector_size__(16), __aligned__(16)));
typedef _Float16 __m128h __attribute__((__vector_size__(16), __aligned__(16)));
typedef _Float16 __m128h_u __attribute__((__vector_size__(16), __aligned__(1)));
typedef __bf16 __v8bf __attribute__((__vector_size__(16), __aligned__(16)));
typedef __bf16 __m128bh __attribute__((__vector_size__(16), __aligned__(16)));
#endif
)",
    },
    Header {
        name: "float.h",
        arch: 7,
        text: M"(/* <float.h>: floating-point characteristics (C11 5.2.4.2.2) from the target's predefined macros.
   Every supported target evaluates an operation in its operand type. The mingw-w64 header adds
   the Windows floating-point control functions and is included first; each macro is redefined
   from a clean slate. */
#ifndef __SC_FLOAT_H
#define __SC_FLOAT_H
#define _FLOAT_H___
#if defined(__MINGW32__) && __has_include_next(<float.h>)
#include_next <float.h>
#endif

#undef FLT_ROUNDS
#define FLT_ROUNDS (__builtin_flt_rounds())
#undef FLT_EVAL_METHOD
#define FLT_EVAL_METHOD 0
#undef FLT_RADIX
#define FLT_RADIX __FLT_RADIX__
#undef DECIMAL_DIG
#define DECIMAL_DIG __DECIMAL_DIG__

#undef FLT_MANT_DIG
#define FLT_MANT_DIG __FLT_MANT_DIG__
#undef DBL_MANT_DIG
#define DBL_MANT_DIG __DBL_MANT_DIG__
#undef LDBL_MANT_DIG
#define LDBL_MANT_DIG __LDBL_MANT_DIG__
#undef FLT_DIG
#define FLT_DIG __FLT_DIG__
#undef DBL_DIG
#define DBL_DIG __DBL_DIG__
#undef LDBL_DIG
#define LDBL_DIG __LDBL_DIG__
#undef FLT_MIN_EXP
#define FLT_MIN_EXP __FLT_MIN_EXP__
#undef DBL_MIN_EXP
#define DBL_MIN_EXP __DBL_MIN_EXP__
#undef LDBL_MIN_EXP
#define LDBL_MIN_EXP __LDBL_MIN_EXP__
#undef FLT_MIN_10_EXP
#define FLT_MIN_10_EXP __FLT_MIN_10_EXP__
#undef DBL_MIN_10_EXP
#define DBL_MIN_10_EXP __DBL_MIN_10_EXP__
#undef LDBL_MIN_10_EXP
#define LDBL_MIN_10_EXP __LDBL_MIN_10_EXP__
#undef FLT_MAX_EXP
#define FLT_MAX_EXP __FLT_MAX_EXP__
#undef DBL_MAX_EXP
#define DBL_MAX_EXP __DBL_MAX_EXP__
#undef LDBL_MAX_EXP
#define LDBL_MAX_EXP __LDBL_MAX_EXP__
#undef FLT_MAX_10_EXP
#define FLT_MAX_10_EXP __FLT_MAX_10_EXP__
#undef DBL_MAX_10_EXP
#define DBL_MAX_10_EXP __DBL_MAX_10_EXP__
#undef LDBL_MAX_10_EXP
#define LDBL_MAX_10_EXP __LDBL_MAX_10_EXP__
#undef FLT_MAX
#define FLT_MAX __FLT_MAX__
#undef DBL_MAX
#define DBL_MAX __DBL_MAX__
#undef LDBL_MAX
#define LDBL_MAX __LDBL_MAX__
#undef FLT_EPSILON
#define FLT_EPSILON __FLT_EPSILON__
#undef DBL_EPSILON
#define DBL_EPSILON __DBL_EPSILON__
#undef LDBL_EPSILON
#define LDBL_EPSILON __LDBL_EPSILON__
#undef FLT_MIN
#define FLT_MIN __FLT_MIN__
#undef DBL_MIN
#define DBL_MIN __DBL_MIN__
#undef LDBL_MIN
#define LDBL_MIN __LDBL_MIN__

#if !defined(__STRICT_ANSI__) || (defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L)
#undef FLT_DECIMAL_DIG
#define FLT_DECIMAL_DIG __FLT_DECIMAL_DIG__
#undef DBL_DECIMAL_DIG
#define DBL_DECIMAL_DIG __DBL_DECIMAL_DIG__
#undef LDBL_DECIMAL_DIG
#define LDBL_DECIMAL_DIG __LDBL_DECIMAL_DIG__
#undef FLT_HAS_SUBNORM
#define FLT_HAS_SUBNORM __FLT_HAS_DENORM__
#undef DBL_HAS_SUBNORM
#define DBL_HAS_SUBNORM __DBL_HAS_DENORM__
#undef LDBL_HAS_SUBNORM
#define LDBL_HAS_SUBNORM __LDBL_HAS_DENORM__
#undef FLT_TRUE_MIN
#define FLT_TRUE_MIN __FLT_DENORM_MIN__
#undef DBL_TRUE_MIN
#define DBL_TRUE_MIN __DBL_DENORM_MIN__
#undef LDBL_TRUE_MIN
#define LDBL_TRUE_MIN __LDBL_DENORM_MIN__
#endif

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L
#undef FLT_NORM_MAX
#define FLT_NORM_MAX __FLT_NORM_MAX__
#undef DBL_NORM_MAX
#define DBL_NORM_MAX __DBL_NORM_MAX__
#undef LDBL_NORM_MAX
#define LDBL_NORM_MAX __LDBL_NORM_MAX__
#endif
#endif
)",
    },
    Header {
        name: "immintrin.h",
        arch: 1,
        text: M"(/* x86 intrinsics umbrella header (see <mmintrin.h>). */
#ifndef __SC_IMMINTRIN_H
#define __SC_IMMINTRIN_H
#include <mmintrin.h>
#include <xmmintrin.h>
#include <emmintrin.h>
#include <pmmintrin.h>
#include <tmmintrin.h>
#include <smmintrin.h>
#include <nmmintrin.h>
#include <wmmintrin.h>
#include <avxintrin.h>
#include <avx2intrin.h>
#include <avx512fintrin.h>
#include <uintrintrin.h>
#include <amxintrin.h>
#include <avx512bf16intrin.h>
#include <avx512fp16intrin.h>
#endif
)",
    },
    Header {
        name: "intrin.h",
        arch: 3,
        text: M"(/* MSVC-style intrinsics header (see <mmintrin.h>). In the MSVC dialect (_MSC_VER) the compiler
   declares the intrinsic functions itself; for mingw-w64 the C library's header does. */
#ifndef __SC_INTRIN_H
#define __SC_INTRIN_H
#if defined(__x86_64__) || defined(__i386__)
#include <immintrin.h>
#elif defined(__aarch64__)
#include <arm_neon.h>
#endif
#if !defined(_MSC_VER) && __has_include_next(<intrin.h>)
#include_next <intrin.h>
#endif
#endif
)",
    },
    Header {
        name: "iso646.h",
        arch: 7,
        text: M"(/* <iso646.h>: alternative spellings (C11 7.9). */
#ifndef __SC_ISO646_H
#define __SC_ISO646_H
#define and &&
#define and_eq &=
#define bitand &
#define bitor |
#define compl ~
#define not !
#define not_eq !=
#define or ||
#define or_eq |=
#define xor ^
#define xor_eq ^=
#endif
)",
    },
    Header {
        name: "limits.h",
        arch: 7,
        text: M"(/* Macro spellings follow clang's header (part of the LLVM Project, under the Apache License v2.0 with
   LLVM Exceptions; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception). <limits.h>: integer limits (C11 5.2.4.2.1). The C library's header comes first (it adds the
   POSIX limits); this header defines the standard limits it leaves out. */
#ifndef __SC_LIMITS_H
#define __SC_LIMITS_H
#define _GCC_LIMITS_H_
#if __STDC_HOSTED__ && __has_include_next(<limits.h>)
#include_next <limits.h>
#endif

#ifndef CHAR_BIT
#define CHAR_BIT __CHAR_BIT__
#endif
#ifndef SCHAR_MAX
#define SCHAR_MAX __SCHAR_MAX__
#endif
#ifndef SCHAR_MIN
#define SCHAR_MIN (-__SCHAR_MAX__ - 1)
#endif
#ifndef UCHAR_MAX
#define UCHAR_MAX (__SCHAR_MAX__ * 2 + 1)
#endif
#ifndef CHAR_MAX
#ifdef __CHAR_UNSIGNED__
#define CHAR_MAX (__SCHAR_MAX__ * 2 + 1)
#else
#define CHAR_MAX __SCHAR_MAX__
#endif
#endif
#ifndef CHAR_MIN
#ifdef __CHAR_UNSIGNED__
#define CHAR_MIN 0
#else
#define CHAR_MIN (-__SCHAR_MAX__ - 1)
#endif
#endif
#ifndef SHRT_MAX
#define SHRT_MAX __SHRT_MAX__
#endif
#ifndef SHRT_MIN
#define SHRT_MIN (-__SHRT_MAX__ - 1)
#endif
#ifndef USHRT_MAX
#define USHRT_MAX (__SHRT_MAX__ * 2 + 1)
#endif
#ifndef INT_MAX
#define INT_MAX __INT_MAX__
#endif
#ifndef INT_MIN
#define INT_MIN (-__INT_MAX__ - 1)
#endif
#ifndef UINT_MAX
#define UINT_MAX (__INT_MAX__ * 2U + 1U)
#endif
#ifndef LONG_MAX
#define LONG_MAX __LONG_MAX__
#endif
#ifndef LONG_MIN
#define LONG_MIN (-__LONG_MAX__ - 1L)
#endif
#ifndef ULONG_MAX
#define ULONG_MAX (__LONG_MAX__ * 2UL + 1UL)
#endif
#ifndef LLONG_MAX
#define LLONG_MAX __LONG_LONG_MAX__
#endif
#ifndef LLONG_MIN
#define LLONG_MIN (-__LONG_LONG_MAX__ - 1LL)
#endif
#ifndef ULLONG_MAX
#define ULLONG_MAX (__LONG_LONG_MAX__ * 2ULL + 1ULL)
#endif
#ifndef LONG_LONG_MAX
#define LONG_LONG_MAX __LONG_LONG_MAX__
#define LONG_LONG_MIN (-__LONG_LONG_MAX__ - 1LL)
#define ULONG_LONG_MAX (__LONG_LONG_MAX__ * 2ULL + 1ULL)
#endif
#ifndef MB_LEN_MAX
#define MB_LEN_MAX 1
#endif

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L
#ifndef BOOL_WIDTH
#define BOOL_WIDTH __BOOL_WIDTH__
#define CHAR_WIDTH __CHAR_BIT__
#define SCHAR_WIDTH __CHAR_BIT__
#define UCHAR_WIDTH __CHAR_BIT__
#define SHRT_WIDTH __SHRT_WIDTH__
#define USHRT_WIDTH __SHRT_WIDTH__
#define INT_WIDTH __INT_WIDTH__
#define UINT_WIDTH __INT_WIDTH__
#define LONG_WIDTH __LONG_WIDTH__
#define ULONG_WIDTH __LONG_WIDTH__
#define LLONG_WIDTH __LLONG_WIDTH__
#define ULLONG_WIDTH __LLONG_WIDTH__
#define BITINT_MAXWIDTH __BITINT_MAXWIDTH__
#endif
#endif
#endif
)",
    },
    Header {
        name: "mm_malloc.h",
        arch: 1,
        text: M"(/* <mm_malloc.h>: aligned allocation for the SIMD intrinsics headers, over malloc. The alignment is a
   power of two. */
#ifndef __SC_MM_MALLOC_H
#define __SC_MM_MALLOC_H
#include <stdlib.h>
static __inline__ void *_mm_malloc(size_t __size, size_t __align) {
    void *__raw;
    char *__p;
    if (__align < sizeof(void *)) {
        __align = sizeof(void *);
    }
    __raw = malloc(__size + __align + sizeof(void *));
    if (__raw == (void *)0) {
        return (void *)0;
    }
    __p = (char *)(((__UINTPTR_TYPE__)__raw + sizeof(void *) + __align - 1) & ~(__UINTPTR_TYPE__)(__align - 1));
    ((void **)__p)[-1] = __raw;
    return __p;
}
static __inline__ void _mm_free(void *__p) {
    if (__p != (void *)0) {
        free(((void **)__p)[-1]);
    }
}
#endif
)",
    },
    Header {
        name: "mmintrin.h",
        arch: 1,
        text: M"(/* Derived from clang's <mmintrin.h>. Part of the LLVM Project, under the Apache License v2.0 with
   LLVM Exceptions. See https://llvm.org/LICENSE.txt for license information.
   SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception */
#ifndef __SC_MMINTRIN_H
#define __SC_MMINTRIN_H
typedef long long __m64 __attribute__((__vector_size__(8), __aligned__(8)));
typedef long long __v1di __attribute__((__vector_size__(8)));
typedef int __v2si __attribute__((__vector_size__(8)));
typedef short __v4hi __attribute__((__vector_size__(8)));
typedef char __v8qi __attribute__((__vector_size__(8)));
typedef unsigned long long __v1du __attribute__ ((__vector_size__ (8)));
typedef unsigned int __v2su __attribute__ ((__vector_size__ (8)));
typedef unsigned short __v4hu __attribute__((__vector_size__(8)));
typedef unsigned char __v8qu __attribute__((__vector_size__(8)));
typedef signed char __v8qs __attribute__((__vector_size__(8)));
typedef long long __m128i __attribute__((__vector_size__(16), __aligned__(16)));
typedef long long __v2di __attribute__ ((__vector_size__ (16)));
typedef int __v4si __attribute__((__vector_size__(16)));
typedef short __v8hi __attribute__((__vector_size__(16)));
typedef char __v16qi __attribute__((__vector_size__(16)));
#endif
)",
    },
    Header {
        name: "nmmintrin.h",
        arch: 1,
        text: M"(/* x86 intrinsics group: functions are compiler built-ins (see <mmintrin.h>). */
#ifndef __SC_NMMINTRIN_H
#define __SC_NMMINTRIN_H
#include <emmintrin.h>
#endif
)",
    },
    Header {
        name: "pmmintrin.h",
        arch: 1,
        text: M"(/* x86 intrinsics group: functions are compiler built-ins (see <mmintrin.h>). */
#ifndef __SC_PMMINTRIN_H
#define __SC_PMMINTRIN_H
#include <emmintrin.h>
#endif
)",
    },
    Header {
        name: "ptrauth.h",
        arch: 7,
        text: M"(/*===---- ptrauth.h - Pointer authentication -------------------------------===
 *
 * Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
 * See https://llvm.org/LICENSE.txt for license information.
 * SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
 *
 *===-----------------------------------------------------------------------===
 */

#ifndef __PTRAUTH_H
#define __PTRAUTH_H

typedef enum {
  ptrauth_key_asia = 0,
  ptrauth_key_asib = 1,
  ptrauth_key_asda = 2,
  ptrauth_key_asdb = 3,

  /* A process-independent key which can be used to sign code pointers. */
  ptrauth_key_process_independent_code = ptrauth_key_asia,

  /* A process-specific key which can be used to sign code pointers. */
  ptrauth_key_process_dependent_code = ptrauth_key_asib,

  /* A process-independent key which can be used to sign data pointers. */
  ptrauth_key_process_independent_data = ptrauth_key_asda,

  /* A process-specific key which can be used to sign data pointers. */
  ptrauth_key_process_dependent_data = ptrauth_key_asdb,

  /* The key used to sign return addresses on the stack.
     The extra data is based on the storage address of the return address.
     On AArch64, that is always the storage address of the return address + 8
     (or, in other words, the value of the stack pointer on function entry) */
  ptrauth_key_return_address = ptrauth_key_process_dependent_code,

  /* The key used to sign C function pointers.
     The extra data is always 0. */
  ptrauth_key_function_pointer = ptrauth_key_process_independent_code,

  /* The key used to sign C++ v-table pointers.
     The extra data is always 0. */
  ptrauth_key_cxx_vtable_pointer = ptrauth_key_process_independent_data,

  /* The key used to sign metadata pointers to Objective-C method-lists. */
  ptrauth_key_method_list_pointer = ptrauth_key_asda,

  /* The key used to sign Objective-C isa and super pointers. */
  ptrauth_key_objc_isa_pointer = ptrauth_key_process_independent_data,
  ptrauth_key_objc_super_pointer = ptrauth_key_process_independent_data,

  /* The key used to sign selector pointers */
  ptrauth_key_objc_sel_pointer = ptrauth_key_process_dependent_data,

  /* The key used to sign Objective-C class_ro_t pointers. */
  ptrauth_key_objc_class_ro_pointer = ptrauth_key_process_independent_data,

  /* The key used to sign pointers in ELF .init_array/.fini_array. */
  ptrauth_key_init_fini_pointer = ptrauth_key_process_independent_code,

  /* Other pointers signed under the ABI use private ABI rules. */

} ptrauth_key;

/* An integer type of the appropriate size for a discriminator argument. */
typedef __UINTPTR_TYPE__ ptrauth_extra_data_t;

/* An integer type of the appropriate size for a generic signature. */
typedef __UINTPTR_TYPE__ ptrauth_generic_signature_t;

/* A signed pointer value embeds the original pointer together with
   a signature that attests to the validity of that pointer.  Because
   this signature must use only "spare" bits of the pointer, a
   signature's validity is probabilistic in practice: it is unlikely
   but still plausible that an invalidly-derived signature will
   somehow equal the correct signature and therefore successfully
   authenticate.  Nonetheless, this scheme provides a strong degree
   of protection against certain kinds of attacks. */

/* Authenticating a pointer that was not signed with the given key
   and extra-data value will (likely) fail by trapping. */

/* The null function pointer is always the all-zero bit pattern.
   Signing an all-zero bit pattern will embed a (likely) non-zero
   signature in the result, and so the result will not seem to be
   a null function pointer.  Authenticating this value will yield
   a null function pointer back.  However, authenticating an
   all-zero bit pattern will probably fail, because the
   authentication will expect a (likely) non-zero signature to
   embedded in the value.

   Because of this, if a pointer may validly be null, you should
   check for null before attempting to authenticate it with one
   of these intrinsics.  This is not necessary when using the
   __ptrauth qualifier; the compiler will perform this check
   automatically. */

#if __has_feature(ptrauth_intrinsics) || defined(__PTRAUTH__)

/* Strip the signature from a value without authenticating it.

   If the value is a function pointer, the result will not be a
   legal function pointer because of the missing signature, and
   attempting to call it will result in an authentication failure.

   The value must be an expression of pointer type.
   The key must be a constant expression of type ptrauth_key.
   The result will have the same type as the original value. */
#define ptrauth_strip(__value, __key) __builtin_ptrauth_strip(__value, __key)

/* Blend a constant discriminator into the given pointer-like value
   to form a new discriminator.  Not all bits of the inputs are
   guaranteed to contribute to the result.

   On arm64e, the integer must fall within the range of a uint16_t;
   other bits may be ignored.

   For the purposes of ptrauth_sign_constant, the result of calling
   this function is considered a constant expression if the arguments
   are constant.  Some restrictions may be imposed on the pointer.

   The first argument must be an expression of pointer type.
   The second argument must be an expression of integer type.
   The result will have type uintptr_t. */
#define ptrauth_blend_discriminator(__pointer, __integer)                      \
  __builtin_ptrauth_blend_discriminator(__pointer, __integer)

/* Return a signed pointer for a constant address in a manner which guarantees
   a non-attackable sequence.

   The value must be a constant expression of pointer type which evaluates to
   a non-null pointer.
   The key must be a constant expression of type ptrauth_key.
   The extra data must be a constant expression of pointer or integer type;
   if an integer, it will be coerced to ptrauth_extra_data_t.
   The result will have the same type as the original value.

   This can be used in constant expressions.  */
#define ptrauth_sign_constant(__value, __key, __data)                          \
  __builtin_ptrauth_sign_constant(__value, __key, __data)

/* Add a signature to the given pointer value using a specific key,
   using the given extra data as a salt to the signing process.

   This operation does not authenticate the original value and is
   therefore potentially insecure if an attacker could possibly
   control that value.

   The value must be an expression of pointer type.
   The key must be a constant expression of type ptrauth_key.
   The extra data must be an expression of pointer or integer type;
   if an integer, it will be coerced to ptrauth_extra_data_t.
   The result will have the same type as the original value. */
#define ptrauth_sign_unauthenticated(__value, __key, __data)                   \
  __builtin_ptrauth_sign_unauthenticated(__value, __key, __data)

/* Authenticate a pointer using one scheme and resign it using another.

   If the result is subsequently authenticated using the new scheme, that
   authentication is guaranteed to fail if and only if the initial
   authentication failed.

   The value must be an expression of pointer type.
   The key must be a constant expression of type ptrauth_key.
   The extra data must be an expression of pointer or integer type;
   if an integer, it will be coerced to ptrauth_extra_data_t.
   The result will have the same type as the original value.

   This operation is guaranteed to not leave the intermediate value
   available for attack before it is re-signed.

   Do not pass a null pointer to this function. A null pointer
   will not successfully authenticate.

   This operation traps if the authentication fails. */
#define ptrauth_auth_and_resign(__value, __old_key, __old_data, __new_key,     \
                                __new_data)                                    \
  __builtin_ptrauth_auth_and_resign(__value, __old_key, __old_data, __new_key, \
                                    __new_data)

/* Authenticate a pointer using one scheme and resign it as a C
   function pointer.

   If the result is subsequently authenticated using the new scheme, that
   authentication is guaranteed to fail if and only if the initial
   authentication failed.

   The value must be an expression of function pointer type.
   The key must be a constant expression of type ptrauth_key.
   The extra data must be an expression of pointer or integer type;
   if an integer, it will be coerced to ptrauth_extra_data_t.
   The result will have the same type as the original value.

   This operation is guaranteed to not leave the intermediate value
   available for attack before it is re-signed. Additionally, if this
   expression is used syntactically as the function expression in a
   call, only a single authentication will be performed. */
#define ptrauth_auth_function(__value, __old_key, __old_data)                  \
  ptrauth_auth_and_resign(__value, __old_key, __old_data,                      \
                          ptrauth_key_function_pointer, 0)

/* Authenticate a data pointer.

   The value must be an expression of non-function pointer type.
   The key must be a constant expression of type ptrauth_key.
   The extra data must be an expression of pointer or integer type;
   if an integer, it will be coerced to ptrauth_extra_data_t.
   The result will have the same type as the original value.

   This operation traps if the authentication fails. */
#define ptrauth_auth_data(__value, __old_key, __old_data)                      \
  __builtin_ptrauth_auth(__value, __old_key, __old_data)

/* Compute a constant discriminator from the given string.

   The argument must be a string literal of char character type.  The result
   has type ptrauth_extra_data_t.

   The result value is never zero and always within range for both the
   __ptrauth qualifier and ptrauth_blend_discriminator.

   This can be used in constant expressions.
*/
#define ptrauth_string_discriminator(__string)                                 \
  __builtin_ptrauth_string_discriminator(__string)

/* Compute a constant discriminator from the given type.

   The result can be used as the second argument to
   ptrauth_blend_discriminator or the third argument to the
   __ptrauth qualifier.  It has type size_t.

   If the type is a C++ member function pointer type, the result is
   the discriminator used to signed member function pointers of that
   type.  If the type is a function, function pointer, or function
   reference type, the result is the discriminator used to sign
   functions of that type.  It is ill-formed to use this macro with any
   other type.

   A call to this function is an integer constant expression. */
#define ptrauth_type_discriminator(__type)                                     \
  __builtin_ptrauth_type_discriminator(__type)

/* Compute the constant discriminator used by Clang to sign pointers with the
   given C function pointer type.

   A call to this function is an integer constant expression. */
#if __has_feature(ptrauth_function_pointer_type_discrimination)
#define ptrauth_function_pointer_type_discriminator(__type)                    \
  __builtin_ptrauth_type_discriminator(__type)
#else
#define ptrauth_function_pointer_type_discriminator(__type)                    \
  ((ptrauth_extra_data_t)0)
#endif

/* Compute a signature for the given pair of pointer-sized values.
   The order of the arguments is significant.

   Like a pointer signature, the resulting signature depends on
   private key data and therefore should not be reliably reproducible
   by attackers.  That means that this can be used to validate the
   integrity of arbitrary data by storing a signature for that data
   alongside it, then checking that the signature is still valid later.
   Data which exceeds two pointers in size can be signed by either
   computing a tree of generic signatures or just signing an ordinary
   cryptographic hash of the data.

   The result has type ptrauth_generic_signature_t.  However, it may
   not have as many bits of entropy as that type's width would suggest;
   some implementations are known to compute a compressed signature as
   if the arguments were a pointer and a discriminator.

   The arguments must be either pointers or integers; if integers, they
   will be coerce to uintptr_t. */
#define ptrauth_sign_generic_data(__value, __data)                             \
  __builtin_ptrauth_sign_generic_data(__value, __data)

/* C++ vtable pointer signing class attribute */
#define ptrauth_cxx_vtable_pointer(key, address_discrimination,                \
                                   extra_discrimination...)                    \
  [[clang::ptrauth_vtable_pointer(key, address_discrimination,                 \
                                  extra_discrimination)]]

/* The value is ptrauth_string_discriminator("init_fini") */
#define __ptrauth_init_fini_discriminator 0xd9d4

/* Objective-C pointer auth ABI qualifiers */
#define __ptrauth_objc_method_list_imp                                         \
  __ptrauth(ptrauth_key_function_pointer, 1, 0)

#if __has_feature(ptrauth_objc_method_list_pointer)
#define __ptrauth_objc_method_list_pointer                                     \
  __ptrauth(ptrauth_key_method_list_pointer, 1, 0xC310)
#else
#define __ptrauth_objc_method_list_pointer
#endif

#define __ptrauth_isa_discriminator 0x6AE1
#define __ptrauth_super_discriminator 0xB5AB
#define __ptrauth_objc_isa_pointer                                             \
  __ptrauth(ptrauth_key_objc_isa_pointer, 1, __ptrauth_isa_discriminator)
#if __has_feature(ptrauth_restricted_intptr_qualifier)
#define __ptrauth_objc_isa_uintptr                                             \
  __ptrauth_restricted_intptr(ptrauth_key_objc_isa_pointer, 1,                 \
                              __ptrauth_isa_discriminator)
#else
#define __ptrauth_objc_isa_uintptr                                             \
  __ptrauth(ptrauth_key_objc_isa_pointer, 1, __ptrauth_isa_discriminator)
#endif

#define __ptrauth_objc_super_pointer                                           \
  __ptrauth(ptrauth_key_objc_super_pointer, 1, __ptrauth_super_discriminator)

#define __ptrauth_objc_sel_discriminator 0x57c2
#if __has_feature(ptrauth_objc_interface_sel)
#define __ptrauth_objc_sel                                                     \
  __ptrauth(ptrauth_key_objc_sel_pointer, 1, __ptrauth_objc_sel_discriminator)
#else
#define __ptrauth_objc_sel
#endif

#define __ptrauth_objc_class_ro_discriminator 0x61f8
#define __ptrauth_objc_class_ro                                                \
  __ptrauth(ptrauth_key_objc_class_ro_pointer, 1,                              \
            __ptrauth_objc_class_ro_discriminator)

#else

#define ptrauth_strip(__value, __key)                                          \
  ({                                                                           \
    (void)__key;                                                               \
    __value;                                                                   \
  })

#define ptrauth_blend_discriminator(__pointer, __integer)                      \
  ({                                                                           \
    (void)__pointer;                                                           \
    (void)__integer;                                                           \
    ((ptrauth_extra_data_t)0);                                                 \
  })

#define ptrauth_sign_constant(__value, __key, __data)                          \
  ({                                                                           \
    (void)__key;                                                               \
    (void)__data;                                                              \
    __value;                                                                   \
  })

#define ptrauth_sign_unauthenticated(__value, __key, __data)                   \
  ({                                                                           \
    (void)__key;                                                               \
    (void)__data;                                                              \
    __value;                                                                   \
  })

#define ptrauth_auth_and_resign(__value, __old_key, __old_data, __new_key,     \
                                __new_data)                                    \
  ({                                                                           \
    (void)__old_key;                                                           \
    (void)__old_data;                                                          \
    (void)__new_key;                                                           \
    (void)__new_data;                                                          \
    __value;                                                                   \
  })

#define ptrauth_auth_function(__value, __old_key, __old_data)                  \
  ({                                                                           \
    (void)__old_key;                                                           \
    (void)__old_data;                                                          \
    __value;                                                                   \
  })

#define ptrauth_auth_data(__value, __old_key, __old_data)                      \
  ({                                                                           \
    (void)__old_key;                                                           \
    (void)__old_data;                                                          \
    __value;                                                                   \
  })

#define ptrauth_string_discriminator(__string)                                 \
  ({                                                                           \
    (void)__string;                                                            \
    ((ptrauth_extra_data_t)0);                                                 \
  })

#define ptrauth_type_discriminator(__type) ((ptrauth_extra_data_t)0)
#define ptrauth_function_pointer_type_discriminator(__type)                    \
  ((ptrauth_extra_data_t)0)

#define ptrauth_sign_generic_data(__value, __data)                             \
  ({                                                                           \
    (void)__value;                                                             \
    (void)__data;                                                              \
    ((ptrauth_generic_signature_t)0);                                          \
  })


#define ptrauth_cxx_vtable_pointer(key, address_discrimination,                \
                                   extra_discrimination...)

#define __ptrauth_objc_isa_pointer
#define __ptrauth_objc_isa_uintptr
#define __ptrauth_objc_super_pointer

#endif /* __has_feature(ptrauth_intrinsics) || defined(__PTRAUTH__) */

#endif /* __PTRAUTH_H */
)",
    },
    Header {
        name: "smmintrin.h",
        arch: 1,
        text: M"(/* x86 intrinsics group: functions are compiler built-ins (see <mmintrin.h>). */
#ifndef __SC_SMMINTRIN_H
#define __SC_SMMINTRIN_H
#include <emmintrin.h>
#endif
)",
    },
    Header {
        name: "stdalign.h",
        arch: 7,
        text: M"(/* <stdalign.h>: alignment (C11 7.15). In C23 alignas and alignof are keywords. */
#ifndef __SC_STDALIGN_H
#define __SC_STDALIGN_H
#define __alignas_is_defined 1
#define __alignof_is_defined 1
#if !defined(__STDC_VERSION__) || __STDC_VERSION__ < 202311L
#define alignas _Alignas
#define alignof _Alignof
#endif
#endif
)",
    },
    Header {
        name: "stdarg.h",
        arch: 7,
        text: M"(/* <stdarg.h>: variable arguments (C11 7.16). __need___va_list asks for __gnuc_va_list alone. */
#ifndef __GNUC_VA_LIST
#define __GNUC_VA_LIST
typedef __builtin_va_list __gnuc_va_list;
#endif

#ifdef __need___va_list
#undef __need___va_list
#else
#ifndef __SC_STDARG_H
#define __SC_STDARG_H
#ifndef _VA_LIST
#define _VA_LIST
typedef __builtin_va_list va_list;
#endif
#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L
#define va_start(ap, ...) __builtin_va_start(ap, 0)
#else
#define va_start(ap, param) __builtin_va_start(ap, param)
#endif
#define va_end(ap) __builtin_va_end(ap)
#define va_arg(ap, type) __builtin_va_arg(ap, type)
#define va_copy(dest, src) __builtin_va_copy(dest, src)
#define __va_copy(dest, src) __builtin_va_copy(dest, src)
#endif
#endif
)",
    },
    Header {
        name: "stdatomic.h",
        arch: 7,
        text: M"(/*===---- stdatomic.h - Standard header for atomic types and operations -----===
 *
 * Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
 * See https://llvm.org/LICENSE.txt for license information.
 * SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
 *
 *===-----------------------------------------------------------------------===
 */

#ifndef __CLANG_STDATOMIC_H
#define __CLANG_STDATOMIC_H

/* If we're hosted, fall back to the system's stdatomic.h. FreeBSD, for
 * example, already has a Clang-compatible stdatomic.h header.
 *
 * Exclude the MSVC path as well as the MSVC header as of the 14.31.30818
 * explicitly disallows `stdatomic.h` in the C mode via an `#error`.  Fallback
 * to the clang resource header until that is fully supported.  The
 * `stdatomic.h` header requires C++23 or newer.
 */
#if __STDC_HOSTED__ &&                                                         \
    __has_include_next(<stdatomic.h>) &&                                       \
    (!defined(_MSC_VER) || (defined(__cplusplus) && __cplusplus >= 202002L))
# include_next <stdatomic.h>
#else

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 7.17.1 Introduction */

#define ATOMIC_BOOL_LOCK_FREE       __CLANG_ATOMIC_BOOL_LOCK_FREE
#define ATOMIC_CHAR_LOCK_FREE       __CLANG_ATOMIC_CHAR_LOCK_FREE
#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L
#define ATOMIC_CHAR8_T_LOCK_FREE    __CLANG_ATOMIC_CHAR8_T_LOCK_FREE
#endif
#define ATOMIC_CHAR16_T_LOCK_FREE   __CLANG_ATOMIC_CHAR16_T_LOCK_FREE
#define ATOMIC_CHAR32_T_LOCK_FREE   __CLANG_ATOMIC_CHAR32_T_LOCK_FREE
#define ATOMIC_WCHAR_T_LOCK_FREE    __CLANG_ATOMIC_WCHAR_T_LOCK_FREE
#define ATOMIC_SHORT_LOCK_FREE      __CLANG_ATOMIC_SHORT_LOCK_FREE
#define ATOMIC_INT_LOCK_FREE        __CLANG_ATOMIC_INT_LOCK_FREE
#define ATOMIC_LONG_LOCK_FREE       __CLANG_ATOMIC_LONG_LOCK_FREE
#define ATOMIC_LLONG_LOCK_FREE      __CLANG_ATOMIC_LLONG_LOCK_FREE
#define ATOMIC_POINTER_LOCK_FREE    __CLANG_ATOMIC_POINTER_LOCK_FREE

/* 7.17.2 Initialization */
#if (defined(__STDC_VERSION__) && __STDC_VERSION__ < 202311L) ||               \
    defined(__cplusplus)
/* ATOMIC_VAR_INIT was removed in C23, but still remains in C++23. */
#define ATOMIC_VAR_INIT(value) (value)
#endif

#if ((defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201710L &&              \
      __STDC_VERSION__ < 202311L) ||                                           \
     (defined(__cplusplus) && __cplusplus >= 202002L)) &&                      \
    !defined(_CLANG_DISABLE_CRT_DEPRECATION_WARNINGS)
/* ATOMIC_VAR_INIT was deprecated in C17 and C++20. */
#pragma clang deprecated(ATOMIC_VAR_INIT)
#endif
#define atomic_init __c11_atomic_init

/* 7.17.3 Order and consistency */

typedef enum memory_order {
  memory_order_relaxed = __ATOMIC_RELAXED,
  memory_order_consume = __ATOMIC_CONSUME,
  memory_order_acquire = __ATOMIC_ACQUIRE,
  memory_order_release = __ATOMIC_RELEASE,
  memory_order_acq_rel = __ATOMIC_ACQ_REL,
  memory_order_seq_cst = __ATOMIC_SEQ_CST
} memory_order;

#define kill_dependency(y) (y)

/* 7.17.4 Fences */

/* These should be provided by the libc implementation. */
void atomic_thread_fence(memory_order);
void atomic_signal_fence(memory_order);

#define atomic_thread_fence(order) __c11_atomic_thread_fence(order)
#define atomic_signal_fence(order) __c11_atomic_signal_fence(order)

/* 7.17.5 Lock-free property */

#define atomic_is_lock_free(obj) __c11_atomic_is_lock_free(sizeof(*(obj)))

/* 7.17.6 Atomic integer types */

#ifdef __cplusplus
typedef _Atomic(bool)               atomic_bool;
#else
typedef _Atomic(_Bool)              atomic_bool;
#endif
typedef _Atomic(char)               atomic_char;
typedef _Atomic(signed char)        atomic_schar;
typedef _Atomic(unsigned char)      atomic_uchar;
typedef _Atomic(short)              atomic_short;
typedef _Atomic(unsigned short)     atomic_ushort;
typedef _Atomic(int)                atomic_int;
typedef _Atomic(unsigned int)       atomic_uint;
typedef _Atomic(long)               atomic_long;
typedef _Atomic(unsigned long)      atomic_ulong;
typedef _Atomic(long long)          atomic_llong;
typedef _Atomic(unsigned long long) atomic_ullong;
#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L
typedef _Atomic(unsigned char)      atomic_char8_t;
#endif
typedef _Atomic(uint_least16_t)     atomic_char16_t;
typedef _Atomic(uint_least32_t)     atomic_char32_t;
typedef _Atomic(wchar_t)            atomic_wchar_t;
typedef _Atomic(int_least8_t)       atomic_int_least8_t;
typedef _Atomic(uint_least8_t)      atomic_uint_least8_t;
typedef _Atomic(int_least16_t)      atomic_int_least16_t;
typedef _Atomic(uint_least16_t)     atomic_uint_least16_t;
typedef _Atomic(int_least32_t)      atomic_int_least32_t;
typedef _Atomic(uint_least32_t)     atomic_uint_least32_t;
typedef _Atomic(int_least64_t)      atomic_int_least64_t;
typedef _Atomic(uint_least64_t)     atomic_uint_least64_t;
typedef _Atomic(int_fast8_t)        atomic_int_fast8_t;
typedef _Atomic(uint_fast8_t)       atomic_uint_fast8_t;
typedef _Atomic(int_fast16_t)       atomic_int_fast16_t;
typedef _Atomic(uint_fast16_t)      atomic_uint_fast16_t;
typedef _Atomic(int_fast32_t)       atomic_int_fast32_t;
typedef _Atomic(uint_fast32_t)      atomic_uint_fast32_t;
typedef _Atomic(int_fast64_t)       atomic_int_fast64_t;
typedef _Atomic(uint_fast64_t)      atomic_uint_fast64_t;
typedef _Atomic(intptr_t)           atomic_intptr_t;
typedef _Atomic(uintptr_t)          atomic_uintptr_t;
typedef _Atomic(size_t)             atomic_size_t;
typedef _Atomic(ptrdiff_t)          atomic_ptrdiff_t;
typedef _Atomic(intmax_t)           atomic_intmax_t;
typedef _Atomic(uintmax_t)          atomic_uintmax_t;

/* 7.17.7 Operations on atomic types */

#define atomic_store(object, desired) __c11_atomic_store(object, desired, __ATOMIC_SEQ_CST)
#define atomic_store_explicit __c11_atomic_store

#define atomic_load(object) __c11_atomic_load(object, __ATOMIC_SEQ_CST)
#define atomic_load_explicit __c11_atomic_load

#define atomic_exchange(object, desired) __c11_atomic_exchange(object, desired, __ATOMIC_SEQ_CST)
#define atomic_exchange_explicit __c11_atomic_exchange

#define atomic_compare_exchange_strong(object, expected, desired) __c11_atomic_compare_exchange_strong(object, expected, desired, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)
#define atomic_compare_exchange_strong_explicit __c11_atomic_compare_exchange_strong

#define atomic_compare_exchange_weak(object, expected, desired) __c11_atomic_compare_exchange_weak(object, expected, desired, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)
#define atomic_compare_exchange_weak_explicit __c11_atomic_compare_exchange_weak

#define atomic_fetch_add(object, operand) __c11_atomic_fetch_add(object, operand, __ATOMIC_SEQ_CST)
#define atomic_fetch_add_explicit __c11_atomic_fetch_add

#define atomic_fetch_sub(object, operand) __c11_atomic_fetch_sub(object, operand, __ATOMIC_SEQ_CST)
#define atomic_fetch_sub_explicit __c11_atomic_fetch_sub

#define atomic_fetch_or(object, operand) __c11_atomic_fetch_or(object, operand, __ATOMIC_SEQ_CST)
#define atomic_fetch_or_explicit __c11_atomic_fetch_or

#define atomic_fetch_xor(object, operand) __c11_atomic_fetch_xor(object, operand, __ATOMIC_SEQ_CST)
#define atomic_fetch_xor_explicit __c11_atomic_fetch_xor

#define atomic_fetch_and(object, operand) __c11_atomic_fetch_and(object, operand, __ATOMIC_SEQ_CST)
#define atomic_fetch_and_explicit __c11_atomic_fetch_and

/* 7.17.8 Atomic flag type and operations */

typedef struct atomic_flag { atomic_bool _Value; } atomic_flag;

#ifdef __cplusplus
#define ATOMIC_FLAG_INIT {false}
#else
#define ATOMIC_FLAG_INIT { 0 }
#endif

/* These should be provided by the libc implementation. */
#ifdef __cplusplus
bool atomic_flag_test_and_set(volatile atomic_flag *);
bool atomic_flag_test_and_set_explicit(volatile atomic_flag *, memory_order);
#else
_Bool atomic_flag_test_and_set(volatile atomic_flag *);
_Bool atomic_flag_test_and_set_explicit(volatile atomic_flag *, memory_order);
#endif
void atomic_flag_clear(volatile atomic_flag *);
void atomic_flag_clear_explicit(volatile atomic_flag *, memory_order);

#define atomic_flag_test_and_set(object) __c11_atomic_exchange(&(object)->_Value, 1, __ATOMIC_SEQ_CST)
#define atomic_flag_test_and_set_explicit(object, order) __c11_atomic_exchange(&(object)->_Value, 1, order)

#define atomic_flag_clear(object) __c11_atomic_store(&(object)->_Value, 0, __ATOMIC_SEQ_CST)
#define atomic_flag_clear_explicit(object, order) __c11_atomic_store(&(object)->_Value, 0, order)

#ifdef __cplusplus
}
#endif

#endif /* __STDC_HOSTED__ */
#endif /* __CLANG_STDATOMIC_H */

)",
    },
    Header {
        name: "stdbool.h",
        arch: 7,
        text: M"(/* <stdbool.h>: Boolean type and values (C11 7.18). In C23 bool, true and false are keywords. */
#ifndef __SC_STDBOOL_H
#define __SC_STDBOOL_H
#define __bool_true_false_are_defined 1
#if !defined(__STDC_VERSION__) || __STDC_VERSION__ < 202311L
#define bool _Bool
#define true 1
#define false 0
#endif
#endif
)",
    },
    Header {
        name: "stdckdint.h",
        arch: 7,
        text: M"(/* <stdckdint.h>: checked integer arithmetic (C23 7.20). */
#ifndef __SC_STDCKDINT_H
#define __SC_STDCKDINT_H
#define __STDC_VERSION_STDCKDINT_H__ 202311L
#define ckd_add(result, a, b) __builtin_add_overflow((a), (b), (result))
#define ckd_sub(result, a, b) __builtin_sub_overflow((a), (b), (result))
#define ckd_mul(result, a, b) __builtin_mul_overflow((a), (b), (result))
#endif
)",
    },
    Header {
        name: "stddef.h",
        arch: 7,
        text: M"(/* The max_align_t members are clang's (part of the LLVM Project, under the Apache License v2.0 with LLVM
   Exceptions; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception).
   <stddef.h>: common definitions (C11 7.19). A C library may ask for single parts through the
   __need_<name> macros; then only those parts are defined. */
#if !defined(__need_ptrdiff_t) && !defined(__need_size_t) && !defined(__need_rsize_t) && !defined(__need_wchar_t) && !defined(__need_wint_t) && !defined(__need_NULL) && !defined(__need_max_align_t) && !defined(__need_offsetof) && !defined(__need_nullptr_t) && !defined(__need_unreachable)
#ifndef __SC_STDDEF_H
#define __SC_STDDEF_H
#define __need_ptrdiff_t
#define __need_size_t
#define __need_wchar_t
#define __need_NULL
#define __need_max_align_t
#define __need_offsetof
#if defined(__STDC_WANT_LIB_EXT1__) && __STDC_WANT_LIB_EXT1__ >= 1
#define __need_rsize_t
#endif
#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L
#define __need_nullptr_t
#define __need_unreachable
#endif
#endif
#endif

#ifdef __need_ptrdiff_t
#ifndef _PTRDIFF_T
#define _PTRDIFF_T
typedef __PTRDIFF_TYPE__ ptrdiff_t;
#endif
#undef __need_ptrdiff_t
#endif

#ifdef __need_size_t
#ifndef _SIZE_T
#define _SIZE_T
typedef __SIZE_TYPE__ size_t;
#endif
#undef __need_size_t
#endif

#ifdef __need_rsize_t
#ifndef _RSIZE_T
#define _RSIZE_T
typedef __SIZE_TYPE__ rsize_t;
#endif
#undef __need_rsize_t
#endif

#ifdef __need_wchar_t
#ifndef _WCHAR_T
#define _WCHAR_T
typedef __WCHAR_TYPE__ wchar_t;
#endif
#undef __need_wchar_t
#endif

#ifdef __need_wint_t
#ifndef _WINT_T
#define _WINT_T
typedef __WINT_TYPE__ wint_t;
#endif
#undef __need_wint_t
#endif

#ifdef __need_NULL
#undef NULL
#define NULL ((void*)0)
#undef __need_NULL
#endif

#ifdef __need_offsetof
#undef offsetof
#define offsetof(type, member) __builtin_offsetof(type, member)
#undef __need_offsetof
#endif

#ifdef __need_max_align_t
#ifndef _GCC_MAX_ALIGN_T
#define _GCC_MAX_ALIGN_T
#ifdef __APPLE__
typedef long double max_align_t;
#else
typedef struct {
    long long __clang_max_align_nonce1 __attribute__((__aligned__(__alignof__(long long))));
    long double __clang_max_align_nonce2 __attribute__((__aligned__(__alignof__(long double))));
} max_align_t;
#endif
#endif
#undef __need_max_align_t
#endif

#ifdef __need_nullptr_t
#ifndef __SC_NULLPTR_T
#define __SC_NULLPTR_T
typedef typeof(nullptr) nullptr_t;
#endif
#undef __need_nullptr_t
#endif

#ifdef __need_unreachable
#undef unreachable
#define unreachable() __builtin_unreachable()
#undef __need_unreachable
#endif
)",
    },
    Header {
        name: "stdint.h",
        arch: 7,
        text: M"(/* Macro spellings follow clang's header (part of the LLVM Project, under the Apache License v2.0 with
   LLVM Exceptions; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception). <stdint.h>: integer types (C11 7.20). A C library that has the header supplies it. Else the
   types, limits and constants come from the target's predefined macros. */
#ifndef __SC_STDINT_H
#define __SC_STDINT_H
#if __STDC_HOSTED__ && __has_include_next(<stdint.h>)
#include_next <stdint.h>
#else

typedef __INT8_TYPE__ int8_t;
typedef __INT16_TYPE__ int16_t;
typedef __INT32_TYPE__ int32_t;
typedef __INT64_TYPE__ int64_t;
typedef __UINT8_TYPE__ uint8_t;
typedef __UINT16_TYPE__ uint16_t;
typedef __UINT32_TYPE__ uint32_t;
typedef __UINT64_TYPE__ uint64_t;

typedef __INT_LEAST8_TYPE__ int_least8_t;
typedef __INT_LEAST16_TYPE__ int_least16_t;
typedef __INT_LEAST32_TYPE__ int_least32_t;
typedef __INT_LEAST64_TYPE__ int_least64_t;
typedef __UINT_LEAST8_TYPE__ uint_least8_t;
typedef __UINT_LEAST16_TYPE__ uint_least16_t;
typedef __UINT_LEAST32_TYPE__ uint_least32_t;
typedef __UINT_LEAST64_TYPE__ uint_least64_t;

typedef __INT_FAST8_TYPE__ int_fast8_t;
typedef __INT_FAST16_TYPE__ int_fast16_t;
typedef __INT_FAST32_TYPE__ int_fast32_t;
typedef __INT_FAST64_TYPE__ int_fast64_t;
typedef __UINT_FAST8_TYPE__ uint_fast8_t;
typedef __UINT_FAST16_TYPE__ uint_fast16_t;
typedef __UINT_FAST32_TYPE__ uint_fast32_t;
typedef __UINT_FAST64_TYPE__ uint_fast64_t;

typedef __INTPTR_TYPE__ intptr_t;
typedef __UINTPTR_TYPE__ uintptr_t;
typedef __INTMAX_TYPE__ intmax_t;
typedef __UINTMAX_TYPE__ uintmax_t;

#define INT8_MAX __INT8_MAX__
#define INT16_MAX __INT16_MAX__
#define INT32_MAX __INT32_MAX__
#define INT64_MAX __INT64_MAX__
#define INT8_MIN (-INT8_MAX - 1)
#define INT16_MIN (-INT16_MAX - 1)
#define INT32_MIN (-INT32_MAX - 1)
#define INT64_MIN (-INT64_MAX - 1)
#define UINT8_MAX __UINT8_MAX__
#define UINT16_MAX __UINT16_MAX__
#define UINT32_MAX __UINT32_MAX__
#define UINT64_MAX __UINT64_MAX__

#define INT_LEAST8_MAX __INT_LEAST8_MAX__
#define INT_LEAST16_MAX __INT_LEAST16_MAX__
#define INT_LEAST32_MAX __INT_LEAST32_MAX__
#define INT_LEAST64_MAX __INT_LEAST64_MAX__
#define INT_LEAST8_MIN (-INT_LEAST8_MAX - 1)
#define INT_LEAST16_MIN (-INT_LEAST16_MAX - 1)
#define INT_LEAST32_MIN (-INT_LEAST32_MAX - 1)
#define INT_LEAST64_MIN (-INT_LEAST64_MAX - 1)
#define UINT_LEAST8_MAX __UINT_LEAST8_MAX__
#define UINT_LEAST16_MAX __UINT_LEAST16_MAX__
#define UINT_LEAST32_MAX __UINT_LEAST32_MAX__
#define UINT_LEAST64_MAX __UINT_LEAST64_MAX__

#define INT_FAST8_MAX __INT_FAST8_MAX__
#define INT_FAST16_MAX __INT_FAST16_MAX__
#define INT_FAST32_MAX __INT_FAST32_MAX__
#define INT_FAST64_MAX __INT_FAST64_MAX__
#define INT_FAST8_MIN (-INT_FAST8_MAX - 1)
#define INT_FAST16_MIN (-INT_FAST16_MAX - 1)
#define INT_FAST32_MIN (-INT_FAST32_MAX - 1)
#define INT_FAST64_MIN (-INT_FAST64_MAX - 1)
#define UINT_FAST8_MAX __UINT_FAST8_MAX__
#define UINT_FAST16_MAX __UINT_FAST16_MAX__
#define UINT_FAST32_MAX __UINT_FAST32_MAX__
#define UINT_FAST64_MAX __UINT_FAST64_MAX__

#define INTPTR_MAX __INTPTR_MAX__
#define INTPTR_MIN (-INTPTR_MAX - 1)
#define UINTPTR_MAX __UINTPTR_MAX__
#define INTMAX_MAX __INTMAX_MAX__
#define INTMAX_MIN (-INTMAX_MAX - 1)
#define UINTMAX_MAX __UINTMAX_MAX__

#define PTRDIFF_MAX __PTRDIFF_MAX__
#define PTRDIFF_MIN (-PTRDIFF_MAX - 1)
#define SIZE_MAX __SIZE_MAX__
#define SIG_ATOMIC_MAX __SIG_ATOMIC_MAX__
#define SIG_ATOMIC_MIN (-SIG_ATOMIC_MAX - 1)
#define WCHAR_MAX __WCHAR_MAX__
#define WINT_MAX __WINT_MAX__
#ifdef __WCHAR_UNSIGNED__
#define WCHAR_MIN 0
#else
#define WCHAR_MIN (-WCHAR_MAX - 1)
#endif
#ifdef __WINT_UNSIGNED__
#define WINT_MIN 0
#else
#define WINT_MIN (-WINT_MAX - 1)
#endif

#define INT8_C(value) __INT8_C(value)
#define INT16_C(value) __INT16_C(value)
#define INT32_C(value) __INT32_C(value)
#define INT64_C(value) __INT64_C(value)
#define UINT8_C(value) __UINT8_C(value)
#define UINT16_C(value) __UINT16_C(value)
#define UINT32_C(value) __UINT32_C(value)
#define UINT64_C(value) __UINT64_C(value)
#define INTMAX_C(value) __INTMAX_C(value)
#define UINTMAX_C(value) __UINTMAX_C(value)

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L
#define INT8_WIDTH 8
#define INT16_WIDTH 16
#define INT32_WIDTH 32
#define INT64_WIDTH 64
#define UINT8_WIDTH 8
#define UINT16_WIDTH 16
#define UINT32_WIDTH 32
#define UINT64_WIDTH 64
#define INT_LEAST8_WIDTH __INT_LEAST8_WIDTH__
#define INT_LEAST16_WIDTH __INT_LEAST16_WIDTH__
#define INT_LEAST32_WIDTH __INT_LEAST32_WIDTH__
#define INT_LEAST64_WIDTH __INT_LEAST64_WIDTH__
#define UINT_LEAST8_WIDTH __INT_LEAST8_WIDTH__
#define UINT_LEAST16_WIDTH __INT_LEAST16_WIDTH__
#define UINT_LEAST32_WIDTH __INT_LEAST32_WIDTH__
#define UINT_LEAST64_WIDTH __INT_LEAST64_WIDTH__
#define INT_FAST8_WIDTH __INT_FAST8_WIDTH__
#define INT_FAST16_WIDTH __INT_FAST16_WIDTH__
#define INT_FAST32_WIDTH __INT_FAST32_WIDTH__
#define INT_FAST64_WIDTH __INT_FAST64_WIDTH__
#define UINT_FAST8_WIDTH __INT_FAST8_WIDTH__
#define UINT_FAST16_WIDTH __INT_FAST16_WIDTH__
#define UINT_FAST32_WIDTH __INT_FAST32_WIDTH__
#define UINT_FAST64_WIDTH __INT_FAST64_WIDTH__
#define INTPTR_WIDTH __INTPTR_WIDTH__
#define UINTPTR_WIDTH __INTPTR_WIDTH__
#define INTMAX_WIDTH __INTMAX_WIDTH__
#define UINTMAX_WIDTH __INTMAX_WIDTH__
#define PTRDIFF_WIDTH __PTRDIFF_WIDTH__
#define SIZE_WIDTH __SIZE_WIDTH__
#define SIG_ATOMIC_WIDTH __SIG_ATOMIC_WIDTH__
#define WCHAR_WIDTH __WCHAR_WIDTH__
#define WINT_WIDTH __WINT_WIDTH__
#endif

#endif
#endif
)",
    },
    Header {
        name: "stdnoreturn.h",
        arch: 7,
        text: M"(/* <stdnoreturn.h>: the noreturn macro (C11 7.23). */
#ifndef __SC_STDNORETURN_H
#define __SC_STDNORETURN_H
#define __noreturn_is_defined 1
#define noreturn _Noreturn
#endif
)",
    },
    Header {
        name: "tgmath.h",
        arch: 7,
        text: M"(/* <tgmath.h>: type-generic math (C11 7.25). Apple's C library supplies it, as clang's own header defers to
   it there only (glibc's rejects clang). Else this header declares the functions it wraps; the generic macros and the __tg_* helpers
   are function-like macros and static functions, which bindgen does not use. */
#ifndef __SC_TGMATH_H
#define __SC_TGMATH_H
#if defined(__APPLE__) && __STDC_HOSTED__ && __has_include_next(<tgmath.h>)
#include_next <tgmath.h>
#else
#include <math.h>
#include <complex.h>
#endif
typedef void _Argument_type_is_not_arithmetic;
#endif
)",
    },
    Header {
        name: "tmmintrin.h",
        arch: 1,
        text: M"(/* x86 intrinsics group: functions are compiler built-ins (see <mmintrin.h>). */
#ifndef __SC_TMMINTRIN_H
#define __SC_TMMINTRIN_H
#include <emmintrin.h>
#endif
)",
    },
    Header {
        name: "uintrintrin.h",
        arch: 1,
        text: M"(/* Derived from clang's <uintrintrin.h>. Part of the LLVM Project, under the Apache License v2.0 with
   LLVM Exceptions. See https://llvm.org/LICENSE.txt for license information.
   SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception */
#ifndef __SC_UINTRINTRIN_H
#define __SC_UINTRINTRIN_H
struct __uintr_frame { unsigned long long rip; unsigned long long rflags; unsigned long long rsp; };
#endif
)",
    },
    Header {
        name: "vadefs.h",
        arch: 7,
        text: M"(/* <vadefs.h>: Windows C libraries include this name from the compiler directory; the C library
   supplies the content. */
#if __has_include_next(<vadefs.h>)
#include_next <vadefs.h>
#endif
)",
    },
    Header {
        name: "wasm_simd128.h",
        arch: 4,
        text: M"(/* Derived from clang's <wasm_simd128.h>. Part of the LLVM Project, under the Apache License v2.0 with
   LLVM Exceptions. See https://llvm.org/LICENSE.txt for license information.
   SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception */
#ifndef __SC_WASM_SIMD128_H
#define __SC_WASM_SIMD128_H
#include <stdbool.h>
#include <stdint.h>
typedef int32_t v128_t __attribute__((__vector_size__(16), __aligned__(16)));
typedef int32_t __v128_u __attribute__((__vector_size__(16), __aligned__(1)));
typedef signed char __i8x16 __attribute__((__vector_size__(16), __aligned__(16)));
typedef unsigned char __u8x16 __attribute__((__vector_size__(16), __aligned__(16)));
typedef short __i16x8 __attribute__((__vector_size__(16), __aligned__(16)));
typedef unsigned short __u16x8 __attribute__((__vector_size__(16), __aligned__(16)));
typedef int __i32x4 __attribute__((__vector_size__(16), __aligned__(16)));
typedef unsigned int __u32x4 __attribute__((__vector_size__(16), __aligned__(16)));
typedef long long __i64x2 __attribute__((__vector_size__(16), __aligned__(16)));
typedef unsigned long long __u64x2 __attribute__((__vector_size__(16), __aligned__(16)));
typedef float __f32x4 __attribute__((__vector_size__(16), __aligned__(16)));
typedef double __f64x2 __attribute__((__vector_size__(16), __aligned__(16)));
typedef __fp16 __f16x8 __attribute__((__vector_size__(16), __aligned__(16)));
typedef signed char __i8x8 __attribute__((__vector_size__(8), __aligned__(8)));
typedef unsigned char __u8x8 __attribute__((__vector_size__(8), __aligned__(8)));
typedef short __i16x4 __attribute__((__vector_size__(8), __aligned__(8)));
typedef unsigned short __u16x4 __attribute__((__vector_size__(8), __aligned__(8)));
typedef int __i32x2 __attribute__((__vector_size__(8), __aligned__(8)));
typedef unsigned int __u32x2 __attribute__((__vector_size__(8), __aligned__(8)));
typedef float __f32x2 __attribute__((__vector_size__(8), __aligned__(8)));
#endif
)",
    },
    Header {
        name: "wmmintrin.h",
        arch: 1,
        text: M"(/* x86 intrinsics group: functions are compiler built-ins (see <mmintrin.h>). */
#ifndef __SC_WMMINTRIN_H
#define __SC_WMMINTRIN_H
#include <emmintrin.h>
#endif
)",
    },
    Header {
        name: "x86intrin.h",
        arch: 1,
        text: M"(/* x86 intrinsics for GCC-style code (see <mmintrin.h>). */
#ifndef __SC_X86INTRIN_H
#define __SC_X86INTRIN_H
#include <immintrin.h>
#endif
)",
    },
    Header {
        name: "xmmintrin.h",
        arch: 1,
        text: M"(/* Derived from clang's <xmmintrin.h>. Part of the LLVM Project, under the Apache License v2.0 with
   LLVM Exceptions. See https://llvm.org/LICENSE.txt for license information.
   SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception */
#ifndef __SC_XMMINTRIN_H
#define __SC_XMMINTRIN_H
#include <mmintrin.h>
#include <mm_malloc.h>
typedef float __v4sf __attribute__((__vector_size__(16)));
typedef float __m128 __attribute__((__vector_size__(16), __aligned__(16)));
typedef float __m128_u __attribute__((__vector_size__(16), __aligned__(1)));
typedef unsigned int __v4su __attribute__((__vector_size__(16)));
typedef unsigned short __v8hu __attribute__((__vector_size__(16)));
typedef unsigned char __v16qu __attribute__((__vector_size__(16)));
#endif
)",
    },
];
