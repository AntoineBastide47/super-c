/* libsuperc: the stable C ABI of the Super-C compiler API.
 *
 * Build: a project that vendors the compiler (`super-c vendor <compiler repository> superc --ref=<tag>`) and
 * declares a library target whose root imports `vendor::superc::src::api::c_abi`:
 *
 *     [lib]
 *     name = "superc"
 *     type = ["shared"]
 *
 * Every function returns a status: SUPERC_OK, or the error of the call. A read takes the generation the
 * caller read from superc_session_generation; a change of the session makes a new generation, and a read of
 * an older one is SUPERC_STALE_HANDLE. Strings are a pointer and a byte length, UTF-8. A result owns the
 * strings its items point at until superc_result_free. Every symbol starts with superc_ or SUPERC_.
 * The library shares the embedder's address space: it is no security boundary. */
#ifndef LIBSUPERC_H
#define LIBSUPERC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SUPERC_API_MAJOR 0
#define SUPERC_API_MINOR 1

/* Status codes: one to one with the compiler API's error codes. */
#define SUPERC_OK 0
#define SUPERC_INVALID_ARGUMENT 1
#define SUPERC_STALE_HANDLE 2
#define SUPERC_WRONG_WORKSPACE 3
#define SUPERC_CANCELLED 4
#define SUPERC_DEADLINE 5
#define SUPERC_LIMIT 6
#define SUPERC_IO 7
#define SUPERC_PARSE_FAILED 8
#define SUPERC_SEMANTIC_FAILED 9
#define SUPERC_VERIFICATION_FAILED 10
#define SUPERC_PLUGIN_FAILED 11
#define SUPERC_PROTOCOL_FAILED 12
#define SUPERC_REENTRANT_CALL 13
#define SUPERC_NOT_CHECKED 14
#define SUPERC_UNSUPPORTED_CAPABILITY 15
#define SUPERC_VERSION_MISMATCH 16
#define SUPERC_INTERNAL 17

/* Diagnostic severities. */
#define SUPERC_SEVERITY_ERROR 1
#define SUPERC_SEVERITY_WARNING 2

typedef struct superc_session superc_session;
typedef struct superc_result superc_result;

/* One item of a result. The caller sets `size` to sizeof(superc_item); the library writes no field past it. */
typedef struct superc_item {
    uint32_t size;
    uint32_t api_version;
    const char *file;
    size_t file_len;
    uint32_t start; /* byte range in the file */
    uint32_t end;
    uint32_t severity; /* diagnostics: SUPERC_SEVERITY_* */
    uint32_t code;     /* diagnostics: the stable code; superc_code_name names it */
    const char *text;  /* diagnostics: the message; symbols: the name */
    size_t text_len;
} superc_item;

/* The API version: major << 16 | minor. */
uint32_t superc_api_version(void);

/* Sessions. */
int32_t superc_session_open_file(const char *path, size_t path_len, const char *std_dir, size_t std_len,
                                 superc_session **out);
int32_t superc_session_open_project(const char *dir, size_t dir_len, const char *std_dir, size_t std_len,
                                    superc_session **out);
void superc_session_free(superc_session *session);
uint64_t superc_session_generation(const superc_session *session);
int32_t superc_session_set_text(superc_session *session, const char *path, size_t path_len, const char *text,
                                size_t text_len, int64_t *version);
int32_t superc_session_check(superc_session *session);
int32_t superc_session_error(superc_session *session, superc_result **out);

/* Reads at a generation. */
int32_t superc_session_diagnostics(superc_session *session, uint64_t generation, superc_result **out);
int32_t superc_session_symbol_at(superc_session *session, uint64_t generation, const char *file, size_t file_len,
                                 uint32_t offset, superc_result **out);
int32_t superc_session_references(superc_session *session, uint64_t generation, const char *file,
                                  size_t file_len, uint32_t offset, superc_result **out);

/* Text. */
int32_t superc_format(const char *text, size_t text_len, superc_result **out);
void superc_code_name(uint32_t code, const char **name, size_t *name_len);

/* Results. */
size_t superc_result_count(const superc_result *result);
void superc_result_text(const superc_result *result, const char **text, size_t *text_len);
int32_t superc_result_item(const superc_result *result, size_t index, superc_item *item);
void superc_result_free(superc_result *result);

/* The version 1 function table. A newer minor version only appends members. */
typedef struct superc_api_v1 {
    uint32_t size;
    uint32_t version;
    uint32_t (*api_version)(void);
    int32_t (*session_open_file)(const char *, size_t, const char *, size_t, superc_session **);
    int32_t (*session_open_project)(const char *, size_t, const char *, size_t, superc_session **);
    void (*session_free)(superc_session *);
    uint64_t (*session_generation)(const superc_session *);
    int32_t (*session_set_text)(superc_session *, const char *, size_t, const char *, size_t, int64_t *);
    int32_t (*session_check)(superc_session *);
    int32_t (*session_error)(superc_session *, superc_result **);
    int32_t (*session_diagnostics)(superc_session *, uint64_t, superc_result **);
    int32_t (*session_symbol_at)(superc_session *, uint64_t, const char *, size_t, uint32_t, superc_result **);
    int32_t (*session_references)(superc_session *, uint64_t, const char *, size_t, uint32_t, superc_result **);
    int32_t (*format)(const char *, size_t, superc_result **);
    size_t (*result_count)(const superc_result *);
    void (*result_text)(const superc_result *, const char **, size_t *);
    int32_t (*result_item)(const superc_result *, size_t, superc_item *);
    void (*result_free)(superc_result *);
    void (*code_name)(uint32_t, const char **, size_t *);
} superc_api_v1;

#define SUPERC_TABLE_V1 1

/* Fill the function table of `version` at `table` (`size` bytes): SUPERC_VERSION_MISMATCH for a version the
 * library does not fill. */
int32_t superc_api_table(uint32_t version, void *table, size_t size);

#ifdef __cplusplus
}
#endif

#endif
