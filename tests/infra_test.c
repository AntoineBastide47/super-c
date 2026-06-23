// Coverage of the two remaining src/ files with no other home: asan_options.c (the
// __asan_default_options startup hook and its Apple/non-Apple branch) and utils/attributes.h
// (the portability macros -- compile + behavior coverage).

#include "test_harness.h"

#include "utils/attributes.h"

#if defined(__SANITIZE_ADDRESS__)
#  define INFRA_ASAN 1
#elif defined(__has_feature)
#  if __has_feature(address_sanitizer)
#    define INFRA_ASAN 1
#  endif
#endif

#ifdef INFRA_ASAN
const char *__asan_default_options(void); // defined in src/asan_options.c under sanitized builds
#endif

ALWAYS_INLINE int doubled(const int x) {
  return x * 2;
}

COLD int cold_succ(const int x) { // COLD already implies `static`
  return x + 1;
}

static NOINLINE int noinline_id(const int x) {
  return x;
}

static void test_asan_options(void) {
#ifdef INFRA_ASAN
  const char *opts = __asan_default_options();
  CHECK(opts != NULL, "asan options string is present");
  CHECK_STR_CONTAINS(opts, "halt_on_error=1");
  CHECK_STR_CONTAINS(opts, "symbolize=1");
#  ifdef __APPLE__
  CHECK_STR_ABSENT(opts, "detect_leaks"); // LeakSanitizer is unsupported on macOS -> omitted
#  else
  CHECK_STR_CONTAINS(opts, "detect_leaks=1");
#  endif
#else
  CHECK(true, "non-sanitized build: __asan_default_options not linked");
#endif
}

static void test_attributes(void) {
  CHECK(doubled(21) == 42, "ALWAYS_INLINE function runs");
  CHECK(cold_succ(41) == 42, "COLD function runs");
  CHECK(noinline_id(7) == 7, "NOINLINE function runs");

  const int x = 5;
  CHECK(LIKELY(x == 5), "LIKELY yields the condition value");
  CHECK(!UNLIKELY(x == 6), "UNLIKELY yields the condition value");

  int MAYBE_UNUSED spare = 0; // compiles clean under -Wunused with the attribute
  CHECK(true, "MAYBE_UNUSED suppresses the unused-variable warning");
}

int main(void) {
  test_asan_options();
  test_attributes();
  if (failures) {
    fprintf(stderr, "%d infra test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("infra tests passed");
  return 0;
}
