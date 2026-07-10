#include "../__std/core.h"
#include "../__std/str.h"

_Static_assert(sizeof(F32Bits) == 4 && _Alignof(F32Bits) == 4, "super-c layout model mismatch: F32Bits");
_Static_assert(sizeof(F64Bits) == 8 && _Alignof(F64Bits) == 8, "super-c layout model mismatch: F64Bits");

static __attribute__((unused)) uint32_t f32_total_key(float const x);
static __attribute__((unused)) uint64_t f64_total_key(double const x);

_Noreturn void panic(str const msg) {
  __sc_panic_str(str__ptr(&msg), str__len(&msg));
}

bool i8__eq(const int8_t *const self, const int8_t *const other) {
  return ((*self) == (*other));
}

int32_t i8__cmp(const int8_t *const self, const int8_t *const other) {
  if ((*self) < (*other)) {
    return -1;
  }
  if ((*self) > (*other)) {
    return 1;
  }
  return 0;
}

uint64_t i8__hash(const int8_t *const self) {
  return ((uint64_t)(*self));
}

int8_t i8__clone(const int8_t *const self) {
  return (*self);
}

int8_t i8__default_(void) {
  return 0;
}

void i8__free(int8_t *const self) {
  (void)self;
}

bool i16__eq(const int16_t *const self, const int16_t *const other) {
  return ((*self) == (*other));
}

int32_t i16__cmp(const int16_t *const self, const int16_t *const other) {
  if ((*self) < (*other)) {
    return -1;
  }
  if ((*self) > (*other)) {
    return 1;
  }
  return 0;
}

uint64_t i16__hash(const int16_t *const self) {
  return ((uint64_t)(*self));
}

int16_t i16__clone(const int16_t *const self) {
  return (*self);
}

int16_t i16__default_(void) {
  return 0;
}

void i16__free(int16_t *const self) {
  (void)self;
}

bool i32__eq(const int32_t *const self, const int32_t *const other) {
  return ((*self) == (*other));
}

int32_t i32__cmp(const int32_t *const self, const int32_t *const other) {
  if ((*self) < (*other)) {
    return -1;
  }
  if ((*self) > (*other)) {
    return 1;
  }
  return 0;
}

uint64_t i32__hash(const int32_t *const self) {
  return ((uint64_t)(*self));
}

int32_t i32__clone(const int32_t *const self) {
  return (*self);
}

int32_t i32__default_(void) {
  return 0;
}

void i32__free(int32_t *const self) {
  (void)self;
}

bool i64__eq(const int64_t *const self, const int64_t *const other) {
  return ((*self) == (*other));
}

int32_t i64__cmp(const int64_t *const self, const int64_t *const other) {
  if ((*self) < (*other)) {
    return -1;
  }
  if ((*self) > (*other)) {
    return 1;
  }
  return 0;
}

uint64_t i64__hash(const int64_t *const self) {
  return ((uint64_t)(*self));
}

int64_t i64__clone(const int64_t *const self) {
  return (*self);
}

int64_t i64__default_(void) {
  return 0;
}

void i64__free(int64_t *const self) {
  (void)self;
}

bool isize__eq(const intptr_t *const self, const intptr_t *const other) {
  return ((*self) == (*other));
}

int32_t isize__cmp(const intptr_t *const self, const intptr_t *const other) {
  if ((*self) < (*other)) {
    return -1;
  }
  if ((*self) > (*other)) {
    return 1;
  }
  return 0;
}

uint64_t isize__hash(const intptr_t *const self) {
  return ((uint64_t)(*self));
}

intptr_t isize__clone(const intptr_t *const self) {
  return (*self);
}

intptr_t isize__default_(void) {
  return 0LL;
}

void isize__free(intptr_t *const self) {
  (void)self;
}

bool u8__eq(const uint8_t *const self, const uint8_t *const other) {
  return ((*self) == (*other));
}

int32_t u8__cmp(const uint8_t *const self, const uint8_t *const other) {
  if ((*self) < (*other)) {
    return -1;
  }
  if ((*self) > (*other)) {
    return 1;
  }
  return 0;
}

uint64_t u8__hash(const uint8_t *const self) {
  return ((uint64_t)(*self));
}

uint8_t u8__clone(const uint8_t *const self) {
  return (*self);
}

uint8_t u8__default_(void) {
  return 0U;
}

void u8__free(uint8_t *const self) {
  (void)self;
}

bool u16__eq(const uint16_t *const self, const uint16_t *const other) {
  return ((*self) == (*other));
}

int32_t u16__cmp(const uint16_t *const self, const uint16_t *const other) {
  if ((*self) < (*other)) {
    return -1;
  }
  if ((*self) > (*other)) {
    return 1;
  }
  return 0;
}

uint64_t u16__hash(const uint16_t *const self) {
  return ((uint64_t)(*self));
}

uint16_t u16__clone(const uint16_t *const self) {
  return (*self);
}

uint16_t u16__default_(void) {
  return 0U;
}

void u16__free(uint16_t *const self) {
  (void)self;
}

bool u32__eq(const uint32_t *const self, const uint32_t *const other) {
  return ((*self) == (*other));
}

int32_t u32__cmp(const uint32_t *const self, const uint32_t *const other) {
  if ((*self) < (*other)) {
    return -1;
  }
  if ((*self) > (*other)) {
    return 1;
  }
  return 0;
}

uint64_t u32__hash(const uint32_t *const self) {
  return ((uint64_t)(*self));
}

uint32_t u32__clone(const uint32_t *const self) {
  return (*self);
}

uint32_t u32__default_(void) {
  return 0U;
}

void u32__free(uint32_t *const self) {
  (void)self;
}

bool u64__eq(const uint64_t *const self, const uint64_t *const other) {
  return ((*self) == (*other));
}

int32_t u64__cmp(const uint64_t *const self, const uint64_t *const other) {
  if ((*self) < (*other)) {
    return -1;
  }
  if ((*self) > (*other)) {
    return 1;
  }
  return 0;
}

uint64_t u64__hash(const uint64_t *const self) {
  return ((uint64_t)(*self));
}

uint64_t u64__clone(const uint64_t *const self) {
  return (*self);
}

uint64_t u64__default_(void) {
  return 0ULL;
}

void u64__free(uint64_t *const self) {
  (void)self;
}

bool usize__eq(const size_t *const self, const size_t *const other) {
  return ((*self) == (*other));
}

int32_t usize__cmp(const size_t *const self, const size_t *const other) {
  if ((*self) < (*other)) {
    return -1;
  }
  if ((*self) > (*other)) {
    return 1;
  }
  return 0;
}

uint64_t usize__hash(const size_t *const self) {
  return ((uint64_t)(*self));
}

size_t usize__clone(const size_t *const self) {
  return (*self);
}

size_t usize__default_(void) {
  return 0ULL;
}

void usize__free(size_t *const self) {
  (void)self;
}

bool char__eq(const char *const self, const char *const other) {
  return ((*self) == (*other));
}

int32_t char__cmp(const char *const self, const char *const other) {
  if ((*self) < (*other)) {
    return -1;
  }
  if ((*self) > (*other)) {
    return 1;
  }
  return 0;
}

uint64_t char__hash(const char *const self) {
  return ((uint64_t)(*self));
}

char char__clone(const char *const self) {
  return (*self);
}

char char__default_(void) {
  return 0;
}

void char__free(char *const self) {
  (void)self;
}

bool bool__eq(const bool *const self, const bool *const other) {
  return ((*self) == (*other));
}

int32_t bool__cmp(const bool *const self, const bool *const other) {
  if ((*self) < (*other)) {
    return -1;
  }
  if ((*self) > (*other)) {
    return 1;
  }
  return 0;
}

uint64_t bool__hash(const bool *const self) {
  return ((uint64_t)(*self));
}

bool bool__clone(const bool *const self) {
  return (*self);
}

bool bool__default_(void) {
  return false;
}

void bool__free(bool *const self) {
  (void)self;
}

static __attribute__((unused)) uint32_t f32_total_key(float const x) {
  const F32Bits b = (F32Bits){ .f = x };
  if (({ uint32_t __sc0 = b.u; int64_t __sc1 = (int64_t)(31U); if ((uint64_t)__sc1 >= 32) { __sc_panic("shift out of range"); } (uint32_t)(__sc0 >> __sc1); }) == 1U) {
    return (b.u ^ 0xFFFFFFFFU);
  }
  return (b.u ^ 0x80000000U);
}

static __attribute__((unused)) uint64_t f64_total_key(double const x) {
  const F64Bits b = (F64Bits){ .f = x };
  if (({ uint64_t __sc2 = b.u; int64_t __sc3 = (int64_t)(63ULL); if ((uint64_t)__sc3 >= 64) { __sc_panic("shift out of range"); } (uint64_t)(__sc2 >> __sc3); }) == 1ULL) {
    return (b.u ^ 0xFFFFFFFFFFFFFFFFULL);
  }
  return (b.u ^ 0x8000000000000000ULL);
}

bool f32__eq(const float *const self, const float *const other) {
  return (f32_total_key((*self)) == f32_total_key((*other)));
}

int32_t f32__cmp(const float *const self, const float *const other) {
  const uint32_t a = f32_total_key((*self));
  const uint32_t b = f32_total_key((*other));
  if (a < b) {
    return -1;
  }
  if (a > b) {
    return 1;
  }
  return 0;
}

uint64_t f32__hash(const float *const self) {
  return ((uint64_t)f32_total_key((*self)));
}

float f32__clone(const float *const self) {
  return (*self);
}

float f32__default_(void) {
  return 0.0;
}

void f32__free(float *const self) {
  (void)self;
}

bool f64__eq(const double *const self, const double *const other) {
  return (f64_total_key((*self)) == f64_total_key((*other)));
}

int32_t f64__cmp(const double *const self, const double *const other) {
  const uint64_t a = f64_total_key((*self));
  const uint64_t b = f64_total_key((*other));
  if (a < b) {
    return -1;
  }
  if (a > b) {
    return 1;
  }
  return 0;
}

uint64_t f64__hash(const double *const self) {
  return f64_total_key((*self));
}

double f64__clone(const double *const self) {
  return (*self);
}

double f64__default_(void) {
  return 0.0;
}

void f64__free(double *const self) {
  (void)self;
}

float _Complex c32__clone(const float _Complex *const self) {
  return (*self);
}

float _Complex c32__default_(void) {
  return ((float _Complex)0.0);
}

void c32__free(float _Complex *const self) {
  (void)self;
}

double _Complex c64__clone(const double _Complex *const self) {
  return (*self);
}

double _Complex c64__default_(void) {
  return ((double _Complex)0.0);
}

void c64__free(double _Complex *const self) {
  (void)self;
}

int8_t i8__abs(int8_t const self) {
  if (self < 0) {
    return ((int8_t)((uint8_t)((uint32_t)0U - (uint32_t)((uint8_t)self))));
  }
  return self;
}

int8_t i8__signum(int8_t const self) {
  if (self < 0) {
    return -1;
  }
  if (self > 0) {
    return 1;
  }
  return 0;
}

bool i8__is_positive(int8_t const self) {
  return (self > 0);
}

bool i8__is_negative(int8_t const self) {
  return (self < 0);
}

int8_t i8__min(int8_t const self, int8_t const other) {
  if (self < other) {
    return self;
  }
  return other;
}

int8_t i8__max(int8_t const self, int8_t const other) {
  if (self > other) {
    return self;
  }
  return other;
}

int8_t i8__clamp(int8_t const self, int8_t const min, int8_t const max) {
  if (self < min) {
    return min;
  }
  if (self > max) {
    return max;
  }
  return self;
}

int16_t i16__abs(int16_t const self) {
  if (self < 0) {
    return ((int16_t)((uint16_t)((uint32_t)0U - (uint32_t)((uint16_t)self))));
  }
  return self;
}

int16_t i16__signum(int16_t const self) {
  if (self < 0) {
    return -1;
  }
  if (self > 0) {
    return 1;
  }
  return 0;
}

bool i16__is_positive(int16_t const self) {
  return (self > 0);
}

bool i16__is_negative(int16_t const self) {
  return (self < 0);
}

int16_t i16__min(int16_t const self, int16_t const other) {
  if (self < other) {
    return self;
  }
  return other;
}

int16_t i16__max(int16_t const self, int16_t const other) {
  if (self > other) {
    return self;
  }
  return other;
}

int16_t i16__clamp(int16_t const self, int16_t const min, int16_t const max) {
  if (self < min) {
    return min;
  }
  if (self > max) {
    return max;
  }
  return self;
}

int32_t i32__abs(int32_t const self) {
  if (self < 0) {
    return ((int32_t)(0U - ((uint32_t)self)));
  }
  return self;
}

int32_t i32__signum(int32_t const self) {
  if (self < 0) {
    return -1;
  }
  if (self > 0) {
    return 1;
  }
  return 0;
}

bool i32__is_positive(int32_t const self) {
  return (self > 0);
}

bool i32__is_negative(int32_t const self) {
  return (self < 0);
}

int32_t i32__min(int32_t const self, int32_t const other) {
  if (self < other) {
    return self;
  }
  return other;
}

int32_t i32__max(int32_t const self, int32_t const other) {
  if (self > other) {
    return self;
  }
  return other;
}

int32_t i32__clamp(int32_t const self, int32_t const min, int32_t const max) {
  if (self < min) {
    return min;
  }
  if (self > max) {
    return max;
  }
  return self;
}

int64_t i64__abs(int64_t const self) {
  if (self < 0) {
    return ((int64_t)(0ULL - ((uint64_t)self)));
  }
  return self;
}

int64_t i64__signum(int64_t const self) {
  if (self < 0) {
    return -1;
  }
  if (self > 0) {
    return 1;
  }
  return 0;
}

bool i64__is_positive(int64_t const self) {
  return (self > 0);
}

bool i64__is_negative(int64_t const self) {
  return (self < 0);
}

int64_t i64__min(int64_t const self, int64_t const other) {
  if (self < other) {
    return self;
  }
  return other;
}

int64_t i64__max(int64_t const self, int64_t const other) {
  if (self > other) {
    return self;
  }
  return other;
}

int64_t i64__clamp(int64_t const self, int64_t const min, int64_t const max) {
  if (self < min) {
    return min;
  }
  if (self > max) {
    return max;
  }
  return self;
}

intptr_t isize__abs(intptr_t const self) {
  if (self < 0LL) {
    return ((intptr_t)(0ULL - ((size_t)self)));
  }
  return self;
}

intptr_t isize__signum(intptr_t const self) {
  if (self < 0LL) {
    return -1;
  }
  if (self > 0LL) {
    return 1LL;
  }
  return 0LL;
}

bool isize__is_positive(intptr_t const self) {
  return (self > 0LL);
}

bool isize__is_negative(intptr_t const self) {
  return (self < 0LL);
}

intptr_t isize__min(intptr_t const self, intptr_t const other) {
  if (self < other) {
    return self;
  }
  return other;
}

intptr_t isize__max(intptr_t const self, intptr_t const other) {
  if (self > other) {
    return self;
  }
  return other;
}

intptr_t isize__clamp(intptr_t const self, intptr_t const min, intptr_t const max) {
  if (self < min) {
    return min;
  }
  if (self > max) {
    return max;
  }
  return self;
}

bool u8__is_power_of_two(uint8_t const self) {
  return ((self != 0U) && ((self & ((uint8_t)((uint32_t)self - (uint32_t)1U))) == 0U));
}

uint8_t u8__min(uint8_t const self, uint8_t const other) {
  if (self < other) {
    return self;
  }
  return other;
}

uint8_t u8__max(uint8_t const self, uint8_t const other) {
  if (self > other) {
    return self;
  }
  return other;
}

uint8_t u8__clamp(uint8_t const self, uint8_t const min, uint8_t const max) {
  if (self < min) {
    return min;
  }
  if (self > max) {
    return max;
  }
  return self;
}

bool u16__is_power_of_two(uint16_t const self) {
  return ((self != 0U) && ((self & ((uint16_t)((uint32_t)self - (uint32_t)1U))) == 0U));
}

uint16_t u16__min(uint16_t const self, uint16_t const other) {
  if (self < other) {
    return self;
  }
  return other;
}

uint16_t u16__max(uint16_t const self, uint16_t const other) {
  if (self > other) {
    return self;
  }
  return other;
}

uint16_t u16__clamp(uint16_t const self, uint16_t const min, uint16_t const max) {
  if (self < min) {
    return min;
  }
  if (self > max) {
    return max;
  }
  return self;
}

bool u32__is_power_of_two(uint32_t const self) {
  return ((self != 0U) && ((self & (self - 1U)) == 0U));
}

uint32_t u32__min(uint32_t const self, uint32_t const other) {
  if (self < other) {
    return self;
  }
  return other;
}

uint32_t u32__max(uint32_t const self, uint32_t const other) {
  if (self > other) {
    return self;
  }
  return other;
}

uint32_t u32__clamp(uint32_t const self, uint32_t const min, uint32_t const max) {
  if (self < min) {
    return min;
  }
  if (self > max) {
    return max;
  }
  return self;
}

bool u64__is_power_of_two(uint64_t const self) {
  return ((self != 0ULL) && ((self & (self - 1ULL)) == 0ULL));
}

uint64_t u64__min(uint64_t const self, uint64_t const other) {
  if (self < other) {
    return self;
  }
  return other;
}

uint64_t u64__max(uint64_t const self, uint64_t const other) {
  if (self > other) {
    return self;
  }
  return other;
}

uint64_t u64__clamp(uint64_t const self, uint64_t const min, uint64_t const max) {
  if (self < min) {
    return min;
  }
  if (self > max) {
    return max;
  }
  return self;
}

bool usize__is_power_of_two(size_t const self) {
  return ((self != 0ULL) && ((self & (self - 1ULL)) == 0ULL));
}

size_t usize__min(size_t const self, size_t const other) {
  if (self < other) {
    return self;
  }
  return other;
}

size_t usize__max(size_t const self, size_t const other) {
  if (self > other) {
    return self;
  }
  return other;
}

size_t usize__clamp(size_t const self, size_t const min, size_t const max) {
  if (self < min) {
    return min;
  }
  if (self > max) {
    return max;
  }
  return self;
}

bool f32__is_nan(float const self) {
  return (self != self);
}

bool f32__is_infinite(float const self) {
  return (((!f32__is_nan(self)) && (self == (1.0 / 0.0))) || (self == (-1.0f / 0.0)));
}

bool f32__is_finite(float const self) {
  return ((!f32__is_nan(self)) && (!f32__is_infinite(self)));
}

bool f32__is_sign_positive(float const self) {
  return (copysignf(1.0, self) > 0.0);
}

bool f32__is_sign_negative(float const self) {
  return (copysignf(1.0, self) < 0.0);
}

float f32__abs(float const self) {
  return fabsf(self);
}

float f32__signum(float const self) {
  if (f32__is_nan(self)) {
    return self;
  }
  return copysignf(1.0, self);
}

float f32__copysign(float const self, float const sign) {
  return copysignf(self, sign);
}

float f32__min(float const self, float const other) {
  return fminf(self, other);
}

float f32__max(float const self, float const other) {
  return fmaxf(self, other);
}

float f32__clamp(float const self, float const min, float const max) {
  if (self < min) {
    return min;
  }
  if (self > max) {
    return max;
  }
  return self;
}

float f32__floor(float const self) {
  return floorf(self);
}

float f32__ceil(float const self) {
  return ceilf(self);
}

float f32__round(float const self) {
  return roundf(self);
}

float f32__trunc(float const self) {
  return truncf(self);
}

float f32__fract(float const self) {
  return (self - truncf(self));
}

float f32__recip(float const self) {
  return (1.0 / self);
}

float f32__sqrt(float const self) {
  return sqrtf(self);
}

float f32__cbrt(float const self) {
  return cbrtf(self);
}

float f32__powf(float const self, float const n) {
  return powf(self, n);
}

float f32__powi(float const self, int32_t const n) {
  return powf(self, ((float)n));
}

float f32__exp(float const self) {
  return expf(self);
}

float f32__exp2(float const self) {
  return exp2f(self);
}

float f32__exp_m1(float const self) {
  return expm1f(self);
}

float f32__ln(float const self) {
  return logf(self);
}

float f32__log(float const self, float const base) {
  return (logf(self) / logf(base));
}

float f32__log2(float const self) {
  return log2f(self);
}

float f32__log10(float const self) {
  return log10f(self);
}

float f32__ln_1p(float const self) {
  return log1pf(self);
}

float f32__hypot(float const self, float const other) {
  return hypotf(self, other);
}

float f32__sin(float const self) {
  return sinf(self);
}

float f32__cos(float const self) {
  return cosf(self);
}

float f32__tan(float const self) {
  return tanf(self);
}

float f32__asin(float const self) {
  return asinf(self);
}

float f32__acos(float const self) {
  return acosf(self);
}

float f32__atan(float const self) {
  return atanf(self);
}

float f32__atan2(float const self, float const other) {
  return atan2f(self, other);
}

f32__sin_cos_ret f32__sin_cos(float const self) {
  return (f32__sin_cos_ret){ sinf(self), cosf(self) };
}

float f32__sinh(float const self) {
  return sinhf(self);
}

float f32__cosh(float const self) {
  return coshf(self);
}

float f32__tanh(float const self) {
  return tanhf(self);
}

float f32__asinh(float const self) {
  return asinhf(self);
}

float f32__acosh(float const self) {
  return acoshf(self);
}

float f32__atanh(float const self) {
  return atanhf(self);
}

float f32__mul_add(float const self, float const a, float const b) {
  return fmaf(self, a, b);
}

int32_t f32__total_cmp(float const self, float const other) {
  return f32__cmp(&self, (&other));
}

float f32__to_degrees(float const self) {
  return (self * 57.29577951308232);
}

float f32__to_radians(float const self) {
  return (self * 0.017453292519943295);
}

bool f64__is_nan(double const self) {
  return (self != self);
}

bool f64__is_infinite(double const self) {
  return (((!f64__is_nan(self)) && (self == (1.0 / 0.0))) || (self == (-1.0 / 0.0)));
}

bool f64__is_finite(double const self) {
  return ((!f64__is_nan(self)) && (!f64__is_infinite(self)));
}

bool f64__is_sign_positive(double const self) {
  return (copysign(1.0, self) > 0.0);
}

bool f64__is_sign_negative(double const self) {
  return (copysign(1.0, self) < 0.0);
}

double f64__abs(double const self) {
  return fabs(self);
}

double f64__signum(double const self) {
  if (f64__is_nan(self)) {
    return self;
  }
  return copysign(1.0, self);
}

double f64__copysign(double const self, double const sign) {
  return copysign(self, sign);
}

double f64__min(double const self, double const other) {
  return fmin(self, other);
}

double f64__max(double const self, double const other) {
  return fmax(self, other);
}

double f64__clamp(double const self, double const min, double const max) {
  if (self < min) {
    return min;
  }
  if (self > max) {
    return max;
  }
  return self;
}

double f64__floor(double const self) {
  return floor(self);
}

double f64__ceil(double const self) {
  return ceil(self);
}

double f64__round(double const self) {
  return round(self);
}

double f64__trunc(double const self) {
  return trunc(self);
}

double f64__fract(double const self) {
  return (self - trunc(self));
}

double f64__recip(double const self) {
  return (1.0 / self);
}

double f64__sqrt(double const self) {
  return sqrt(self);
}

double f64__cbrt(double const self) {
  return cbrt(self);
}

double f64__powf(double const self, double const n) {
  return pow(self, n);
}

double f64__powi(double const self, int32_t const n) {
  return pow(self, ((double)n));
}

double f64__exp(double const self) {
  return exp(self);
}

double f64__exp2(double const self) {
  return exp2(self);
}

double f64__exp_m1(double const self) {
  return expm1(self);
}

double f64__ln(double const self) {
  return log(self);
}

double f64__log(double const self, double const base) {
  return (log(self) / log(base));
}

double f64__log2(double const self) {
  return log2(self);
}

double f64__log10(double const self) {
  return log10(self);
}

double f64__ln_1p(double const self) {
  return log1p(self);
}

double f64__hypot(double const self, double const other) {
  return hypot(self, other);
}

double f64__sin(double const self) {
  return sin(self);
}

double f64__cos(double const self) {
  return cos(self);
}

double f64__tan(double const self) {
  return tan(self);
}

double f64__asin(double const self) {
  return asin(self);
}

double f64__acos(double const self) {
  return acos(self);
}

double f64__atan(double const self) {
  return atan(self);
}

double f64__atan2(double const self, double const other) {
  return atan2(self, other);
}

f64__sin_cos_ret f64__sin_cos(double const self) {
  return (f64__sin_cos_ret){ sin(self), cos(self) };
}

int32_t f64__total_cmp(double const self, double const other) {
  return f64__cmp(&self, (&other));
}

double f64__sinh(double const self) {
  return sinh(self);
}

double f64__cosh(double const self) {
  return cosh(self);
}

double f64__tanh(double const self) {
  return tanh(self);
}

double f64__asinh(double const self) {
  return asinh(self);
}

double f64__acosh(double const self) {
  return acosh(self);
}

double f64__atanh(double const self) {
  return atanh(self);
}

double f64__mul_add(double const self, double const a, double const b) {
  return fma(self, a, b);
}

double f64__to_degrees(double const self) {
  return (self * 57.29577951308232);
}

double f64__to_radians(double const self) {
  return (self * 0.017453292519943295);
}

