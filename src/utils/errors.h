#ifndef ERRORS_H
#define ERRORS_H

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "types/vector.h"

// Format one error message and append it, with the source span [at, at+len) it
// refers to, to the given vectors. The va_list variant is the shared core behind
// every Label_errorf (see ERRORS_BODY). The vectors are out-parameters (pushed
// to), so they are not const.
COLD_EXPORT void errors_vemitf(
    String_Vec *errors, String_Vec *errors_notes, U32_Vec *errors_start, U32_Vec *errors_len, const uint32_t at,
    const uint32_t len, const char *fmt, va_list args);

// Append an unspanned note to the most recent diagnostic. Notes are rendered as
// `= note: ...` lines after the primary source underline. Calling this before
// any error is a no-op.
COLD_EXPORT void errors_vnotef(String_Vec *errors, String_Vec *errors_notes, const char *fmt, va_list args);

// Replace each collected message in place with a rendered, plain-text block
// (header, source line, caret underline). Call once after all errors are
// gathered, before logging. `errors` is rewritten in place, so it is not const.
// `file` is the source's path, shown in the `--> file:line:col` location line
// (NULL/"" falls back to `--> line:col`).
COLD_EXPORT void errors_finalize(
    String_Vec *errors, const String_Vec *errors_notes, const U32_Vec *errors_start, const U32_Vec *errors_len,
    const uint8_t *source, const size_t len, const char *file);

// Write the rendered blocks to stderr, adding rustc-style ANSI colors only when
// stderr is a terminal (so piped/redirected output and take_errors stay plain).
COLD_EXPORT void errors_log(const String_Vec *errors);

// Report an allocation failure and abort. The shared body behind every
// out-of-memory check in the compiler.
COLD_EXPORT void oom(void);

#define ERRORS_VARIABLES                                                                                               \
  String_Vec errors;                                                                                                   \
  String_Vec errors_notes;                                                                                             \
  U32_Vec errors_start;                                                                                                \
  U32_Vec errors_len;

#define ERRORS_INIT(Var)                                                                                               \
  do {                                                                                                                 \
    (Var)->errors = String_Vec_init();                                                                                 \
    (Var)->errors_notes = String_Vec_init();                                                                           \
    (Var)->errors_start = U32_Vec_init();                                                                              \
    (Var)->errors_len = U32_Vec_init();                                                                                \
  } while (0)

#define ERRORS_DEINIT(Var)                                                                                             \
  do {                                                                                                                 \
    for (size_t i = 0; i < (*Var)->errors.len; i++)                                                                    \
      free((*Var)->errors.data[i]);                                                                                    \
    for (size_t i = 0; i < (*Var)->errors_notes.len; i++)                                                              \
      free((*Var)->errors_notes.data[i]);                                                                              \
    VEC_DEINIT((*Var)->errors)                                                                                         \
    VEC_DEINIT((*Var)->errors_notes)                                                                                   \
    VEC_DEINIT((*Var)->errors_start);                                                                                  \
    VEC_DEINIT((*Var)->errors_len);                                                                                    \
  } while (0)

// Bail out of the (int-returning) driver with a failure status when a stage collected errors.
#define ERRORS_CHECK(Var)                                                                                              \
  if (Var##_has_errors(Var)) {                                                                                         \
    Var##_log_errors(Var);                                                                                             \
    Var##_free(&Var);                                                                                                  \
    return 1;                                                                                                          \
  }

// take_errors hands ownership of the collected messages to the caller. Only the
// test and benchmark drivers use it, so it is compiled out of release (NDEBUG)
// builds, where errors are only ever reported through Label_log_errors.
#ifdef NDEBUG
  #define ERRORS_TAKE_DECL(Struct, Label, Var)
  #define ERRORS_TAKE_DEFN(Struct, Label, Var)
#else
  #define ERRORS_TAKE_DECL(Struct, Label, Var) COLD_EXPORT String_Vec Label##_take_errors(Struct *Var);
  #define ERRORS_TAKE_DEFN(Struct, Label, Var)                                                                         \
    COLD_EXPORT String_Vec Label##_take_errors(Struct *Var) {                                                          \
      if ((Var)->errors.len == 0)                                                                                      \
        return String_Vec_init();                                                                                      \
      const String_Vec out = (Var)->errors;                                                                            \
      (Var)->errors = String_Vec_init();                                                                               \
      for (size_t i = 0; i < (Var)->errors_notes.len; i++)                                                             \
        free((Var)->errors_notes.data[i]);                                                                             \
      VEC_DEINIT((Var)->errors_notes);                                                                                 \
      (Var)->errors_notes = String_Vec_init();                                                                         \
      return out;                                                                                                      \
    }
#endif

#define ERRORS_API(Struct, Label, Var)                                                                                 \
  bool Label##_has_errors(const Struct *Var);                                                                          \
  COLD_EXPORT void Label##_log_errors(const Struct *Var);                                                              \
  ERRORS_TAKE_DECL(Struct, Label, Var)                                                                                 \
  COLD_EXPORT void Label##_errorf(Struct *Var, const uint32_t at, const uint32_t len, const char *fmt, ...);           \
  COLD_EXPORT void Label##_notef(Struct *Var, const char *fmt, ...);

#define ERRORS_BODY(Struct, Label, Var)                                                                                \
  bool Label##_has_errors(const Struct *Var) {                                                                         \
    return (Var)->errors.len != 0;                                                                                     \
  }                                                                                                                    \
                                                                                                                       \
  COLD_EXPORT void Label##_log_errors(const Struct *Var) {                                                             \
    errors_log(&(Var)->errors);                                                                                        \
  }                                                                                                                    \
                                                                                                                       \
  ERRORS_TAKE_DEFN(Struct, Label, Var)                                                                                 \
                                                                                                                       \
  COLD_EXPORT void Label##_errorf(Struct *Var, const uint32_t at, const uint32_t len, const char *fmt, ...) {          \
    va_list args;                                                                                                      \
    va_start(args, fmt);                                                                                               \
    errors_vemitf(&(Var)->errors, &(Var)->errors_notes, &(Var)->errors_start, &(Var)->errors_len, at, len, fmt, args); \
    va_end(args);                                                                                                      \
  }                                                                                                                    \
                                                                                                                       \
  COLD_EXPORT void Label##_notef(Struct *Var, const char *fmt, ...) {                                                  \
    va_list args;                                                                                                      \
    va_start(args, fmt);                                                                                               \
    errors_vnotef(&(Var)->errors, &(Var)->errors_notes, fmt, args);                                                    \
    va_end(args);                                                                                                      \
  }

#endif // ERRORS_H
