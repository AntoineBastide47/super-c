// boundary_cost.c: what it costs on this processor to run a short function, or the short loop that calls
// it, across an address boundary. The function (5 instructions) and the loop (7 instructions) are machine
// code this program places at chosen addresses of an executable region: the loop calls the function once
// per element. Per boundary size (64 bytes to 65536) the function, then the loop, is placed so that an
// odd multiple of that size falls after each of its instructions; the other one stays inside a 64-byte
// line. The time per element is the least of REPS runs, printed as its ratio to the run with both inside
// a line. A second table does the same for a loop of the same work that calls nothing.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#endif
#ifdef __APPLE__
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#endif

#if defined(__aarch64__)
#define ARCH "arm64"
static const uint32_t KERNEL_W[] = {0x51018401, 0x53001c21, 0x7100643f, 0x1a9f87e0, 0xd65f03c0};
static const uint32_t LOOP_W[] = {0xa9bd7bfd, 0xa90153f3, 0xf90013f5, 0xaa0003f3, 0xaa0103f5, 0xd2800014,
                                  0xb8404660, 0x53001c00, 0x94000000, 0x53001c01, 0x8b010294, 0xeb15027f,
                                  0x54ffff43, 0xaa1403e0, 0xf94013f5, 0xa94153f3, 0xa8c37bfd, 0xd65f03c0};
#define KERNEL_N 20
#define LOOP_N 72
#define HEAD_OFF 24
#define CALL_OFF 32
// The bytes before the boundary, per placement: the boundary after each instruction, then at the end and
// at the start.
static const int KCUT[] = {4, 8, 12, 16, 20, 0};
static const int LCUT[] = {4, 8, 12, 16, 20, 24, 28, 0};
static const uint32_t PLAIN_W[] = {0xd2800002, 0xb8404403, 0x51018464, 0x12001c84, 0x7100649f,
                                   0x9a828442, 0xeb01001f, 0x54ffff43, 0xaa0203e0, 0xd65f03c0};
#define PLAIN_CODE PLAIN_W
#define PLAIN_N 40
#define PLAIN_HEAD 4
static const int PCUT[] = {4, 8, 12, 16, 20, 24, 28, 0};
#define ABI
#elif defined(__x86_64__)
#define ARCH "x86-64"
static const uint8_t KERNEL_B[] = {0x8d, 0x47, 0x9f, 0x3c, 0x19, 0x0f, 0x96, 0xc0, 0xc3};
static const uint8_t LOOP_B[] = {0x53, 0x41, 0x54, 0x41, 0x55, 0x48, 0x89, 0xfb, 0x49, 0x89, 0xf4, 0x45,
                                 0x31, 0xed, 0x0f, 0xb6, 0x3b, 0x48, 0x83, 0xc3, 0x04, 0xe8, 0,    0,
                                 0,    0,    0x0f, 0xb6, 0xc0, 0x49, 0x01, 0xc5, 0x4c, 0x39, 0xe3, 0x72,
                                 0xe9, 0x4c, 0x89, 0xe8, 0x41, 0x5d, 0x41, 0x5c, 0x5b, 0xc3};
#define KERNEL_N 9
#define LOOP_N 46
#define HEAD_OFF 14
#define CALL_OFF 21
// The boundary inside the first instruction, after each instruction, at the end and at the start.
static const int KCUT[] = {1, 3, 5, 8, 9, 0};
static const int LCUT[] = {3, 7, 12, 15, 18, 21, 23, 0};
static const uint8_t PLAIN_B[] = {0x31, 0xc0, 0x0f, 0xb6, 0x0f, 0x48, 0x83, 0xc7, 0x04, 0x80,
                                  0xe9, 0x61, 0x80, 0xf9, 0x19, 0x0f, 0x96, 0xc1, 0x0f, 0xb6,
                                  0xc9, 0x48, 0x01, 0xc8, 0x48, 0x39, 0xf7, 0x72, 0xe5, 0xc3};
#define PLAIN_CODE PLAIN_B
#define PLAIN_N 30
#define PLAIN_HEAD 2
static const int PCUT[] = {3, 7, 10, 13, 16, 19, 22, 25, 27, 0};
#define ABI __attribute__((sysv_abi))
#else
#error "arm64 or x86-64"
#endif
#define NK (int)(sizeof KCUT / sizeof KCUT[0])
#define NL (int)(sizeof LCUT / sizeof LCUT[0])
#define NP (int)(sizeof PCUT / sizeof PCUT[0])

typedef uint64_t (ABI *loop_fn)(const uint32_t *, const uint32_t *);

#define REGION (2u << 20)
#define ELEMS 4096
#define REPS 7

static double now_ns(void) {
#ifdef _WIN32
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1e9 / (double)f.QuadPart;
#else
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e9 + (double)t.tv_nsec;
#endif
}

static uint8_t *region(void) {
#ifdef _WIN32
    return VirtualAlloc(NULL, REGION, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
#elif defined(__APPLE__)
    void *p = mmap(NULL, REGION, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    return p == MAP_FAILED ? NULL : p;
#else
    void *p = mmap(NULL, REGION, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return p == MAP_FAILED ? NULL : p;
#endif
}

// The function at `k`, the loop with its head at `head`: the loop's entry.
static loop_fn place(uint8_t *k, uint8_t *head) {
    uint8_t *l = head - HEAD_OFF;
#ifdef __APPLE__
    pthread_jit_write_protect_np(0);
#endif
#if defined(__aarch64__)
    memcpy(k, KERNEL_W, KERNEL_N);
    memcpy(l, LOOP_W, LOOP_N);
    uint32_t bl = 0x94000000 | (uint32_t)(((k - (l + CALL_OFF)) / 4) & 0x3ffffff);
    memcpy(l + CALL_OFF, &bl, 4);
#else
    memcpy(k, KERNEL_B, KERNEL_N);
    memcpy(l, LOOP_B, LOOP_N);
    int32_t rel = (int32_t)(k - (l + CALL_OFF + 5));
    memcpy(l + CALL_OFF + 1, &rel, 4);
#endif
#ifdef __APPLE__
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(k, KERNEL_N);
    sys_icache_invalidate(l, LOOP_N);
#elif !defined(_WIN32)
    __builtin___clear_cache((char *)k, (char *)k + KERNEL_N);
    __builtin___clear_cache((char *)l, (char *)l + LOOP_N);
#else
    FlushInstructionCache(GetCurrentProcess(), k, KERNEL_N);
    FlushInstructionCache(GetCurrentProcess(), l, LOOP_N);
#endif
    return (loop_fn)l;
}

// The loop that calls nothing, its head at `head`: its entry.
static loop_fn place_plain(uint8_t *head) {
    uint8_t *l = head - PLAIN_HEAD;
#ifdef __APPLE__
    pthread_jit_write_protect_np(0);
#endif
    memcpy(l, PLAIN_CODE, PLAIN_N);
#ifdef __APPLE__
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(l, PLAIN_N);
#elif !defined(_WIN32)
    __builtin___clear_cache((char *)l, (char *)l + PLAIN_N);
#else
    FlushInstructionCache(GetCurrentProcess(), l, PLAIN_N);
#endif
    return (loop_fn)l;
}

static uint32_t data[ELEMS];
static uint64_t want;
static int calls = 2000;

// The least time per element of REPS runs of the loop over the data `calls` times, in nanoseconds.
static double measure(loop_fn f) {
    double best = 1e30;
    for (int r = 0; r < REPS; r++) {
        uint64_t sum = 0;
        double t0 = now_ns();
        for (int c = 0; c < calls; c++) sum += f(data, data + ELEMS);
        double t = (now_ns() - t0) / ((double)calls * ELEMS);
        if (sum != want * (uint64_t)calls) {
            printf("WRONG RESULT: %llu, expected %llu\n", (unsigned long long)sum, (unsigned long long)(want * calls));
            exit(1);
        }
        if (t < best) best = t;
    }
    return best;
}

int main(void) {
    uint32_t s = 12345;
    for (int i = 0; i < ELEMS; i++) {
        s = s * 1664525u + 1013904223u;
        data[i] = s >> 24;
        want += (uint8_t)(data[i] - 0x61) <= 0x19;
    }
    uint8_t *p = region();
    if (!p) {
        printf("NO EXECUTABLE REGION\n");
        return 1;
    }
    // Both multiples of twice the largest boundary, so `bk + x` and `bl + x` are odd multiples of `x`.
    uint8_t *base = (uint8_t *)(((uintptr_t)p + 0x3ffff) & ~(uintptr_t)0x3ffff);
    uint8_t *bk = base + 0x40000, *bl = base + 0x80000;
    // Inside a 64-byte line, away from every larger boundary.
    uint8_t *kn = bk - 0x1000 + 0x104, *ln = bl - 0x1000 + 0x108;
    // About 40 ms per run.
    double t0 = now_ns();
    (void)measure(place(kn, ln));
    double per = (now_ns() - t0) / REPS;
    calls = (int)(calls * 40e6 / per) + 1;
    double basens = measure(place(kn, ln));
#ifdef _WIN32
    long page = 4096;
#else
    long page = sysconf(_SC_PAGESIZE);
#endif
    printf("arch %s, page %ld bytes, %d elements per run, both inside a line: %.3f ns per element\n", ARCH, page,
           calls * ELEMS, basens);
    printf("time per element / time with both inside a line; columns: bytes of the code before the boundary\n");
    printf("%-9s function", "boundary");
    for (int i = 0; i < NK; i++) printf(" %5d", KCUT[i]);
    printf("   loop");
    for (int i = 0; i < NL; i++) printf(" %5d", LCUT[i]);
    printf("\n");
    double worst_k[16], worst_l[16];
    int nx = 0;
    for (long x = 64; x <= 65536; x *= 2, nx++) {
        double b = measure(place(kn, ln));
        printf("%-9ld         ", x);
        worst_k[nx] = 0;
        worst_l[nx] = 0;
        for (int i = 0; i < NK; i++) {
            double r = measure(place(bk + x - KCUT[i], ln)) / b;
            printf(" %5.2f", r);
            if (KCUT[i] != 0 && KCUT[i] != KERNEL_N && r > worst_k[nx]) worst_k[nx] = r;
        }
        printf("       ");
        for (int i = 0; i < NL; i++) {
            double r = measure(place(kn, bl + x - LCUT[i])) / b;
            printf(" %5.2f", r);
            if (LCUT[i] != 0 && LCUT[i] != LCUT[NL - 2] && r > worst_l[nx]) worst_l[nx] = r;
        }
        printf("\n");
        fflush(stdout);
    }
    // The loop that calls nothing, in the region's last quarter.
    uint8_t *bp = base + 0xc0000, *pn = bp - 0x1000 + 0x108;
    double pbase = measure(place_plain(pn));
    printf("a loop that calls nothing, inside a line: %.3f ns per element\n", pbase);
    printf("%-9s loop", "boundary");
    for (int i = 0; i < NP; i++) printf(" %5d", PCUT[i]);
    printf("\n");
    double worst_p[16];
    nx = 0;
    for (long x = 64; x <= 65536; x *= 2, nx++) {
        double b = measure(place_plain(pn));
        printf("%-9ld     ", x);
        worst_p[nx] = 0;
        for (int i = 0; i < NP; i++) {
            double r = measure(place_plain(bp + x - PCUT[i])) / b;
            printf(" %5.2f", r);
            if (PCUT[i] != 0 && PCUT[i] != PCUT[NP - 2] && r > worst_p[nx]) worst_p[nx] = r;
        }
        printf("\n");
        fflush(stdout);
    }
    printf("worst ratio with the boundary inside, per boundary size:\n");
    nx = 0;
    for (long x = 64; x <= 65536; x *= 2, nx++)
        printf("  %-6ld function %.2f  loop %.2f  loop without a call %.2f\n", x, worst_k[nx], worst_l[nx], worst_p[nx]);
    return 0;
}
