// AddressSanitizer runtime options for sanitized (dev) builds.
//
// ASan reads its options from the ASAN_OPTIONS environment variable or from
// this startup hook -- never from a -DASAN_OPTIONS compile macro. Defining the
// hook bakes the options into every sanitized binary (the dev engine and the
// test drivers), so they apply however the binary is launched. The file
// compiles to nothing in non-sanitized (release) builds.

#if defined(__SANITIZE_ADDRESS__)
#  define JE_ASAN 1
#elif defined(__has_feature)
#  if __has_feature(address_sanitizer)
#    define JE_ASAN 1
#  endif
#endif

#ifdef JE_ASAN
const char *__asan_default_options(void);
const char *__asan_default_options(void) {
#  ifdef __APPLE__
    // LeakSanitizer (detect_leaks) is not supported on macOS; omit it there.
    return "verbosity=0:halt_on_error=1:symbolize=1";
#  else
    return "verbosity=0:halt_on_error=1:detect_leaks=1:symbolize=1";
#  endif
}
#endif
