#if defined(__GNUC__) || defined(__clang__)
# define ALWAYS_INLINE static inline __attribute__((always_inline))
#elif defined(_MSC_VER)
# define ALWAYS_INLINE static __forceinline
#else
# define ALWAYS_INLINE static inline
#endif

#if defined(__GNUC__) || defined(__clang__)
# define NOINLINE __attribute__((noinline))
# define COLD static __attribute__((cold, noinline))
// Like COLD, but for functions with external linkage (declared in a header,
// called across translation units) — same cold/noinline hint, no `static`.
# define COLD_EXPORT __attribute__((cold, noinline))
#elif defined(_MSC_VER)
# define NOINLINE __declspec(noinline)
# define COLD static __declspec(noinline)
# define COLD_EXPORT __declspec(noinline)
#else
# define NOINLINE
# define COLD static
# define COLD_EXPORT
#endif

#if defined(__GNUC__) || defined(__clang__)
# define LIKELY(x)   __builtin_expect(!!(x), 1)
# define UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
# define LIKELY(x)   (x)
# define UNLIKELY(x) (x)
#endif

// For generic-container functions an instantiation may not call (no warning when unused).
#if defined(__GNUC__) || defined(__clang__)
# define MAYBE_UNUSED __attribute__((unused))
#else
# define MAYBE_UNUSED
#endif