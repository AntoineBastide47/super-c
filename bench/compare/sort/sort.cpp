// The libc++ baselines of the shared slice algorithms: the same inputs, timing and report as sort.spc.
// Each lane times every run on a fresh copy of its input and prints the mean of the faster half of the
// runs in ns per element (a run of 1000 elements lasts a few clock steps, so a single best run is
// quantized), and a checksum of its result that the Super-C side must match.
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

static uint64_t rng_state;
static uint64_t next() {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return rng_state;
}

static std::vector<uint64_t> make(int kind, size_t n) {
    rng_state = 88172645463325252ull;
    std::vector<uint64_t> v(n);
    for (size_t i = 0; i < n; i++) {
        switch (kind) {
        case 0: v[i] = next(); break;
        case 1: v[i] = i; break;
        case 2: v[i] = n - i; break;
        case 3: v[i] = next() % 16; break;
        default: v[i] = i % 1000; break;
        }
    }
    return v;
}

// The checksum covers the order a lane promises: every sampled element, or for selection the selected one.
template <class F> static void lane(const char *op, const char *kind_name, int kind, size_t n, int reps, F f) {
    std::vector<double> times;
    uint64_t sum = 0;
    const auto input = make(kind, n);
    std::vector<uint64_t> v(n);
    for (int r = 0; r < reps; r++) {
        v = input;
        auto t0 = std::chrono::steady_clock::now();
        f(v);
        auto t1 = std::chrono::steady_clock::now();
        times.push_back(std::chrono::duration<double, std::nano>(t1 - t0).count() / n);
        sum = 0;
        if (strcmp(op, "select") == 0) {
            sum = v[n / 2];
        } else {
            for (size_t i = 0; i < n; i += n / 64 + 1) sum = sum * 31 + v[i];
        }
    }
    std::sort(times.begin(), times.end());
    double fast = 0;
    for (size_t i = 0; i < times.size() / 2; i++) fast += times[i];
    printf("%s %s %zu %.2f %llu\n", op, kind_name, n, fast / (times.size() / 2), (unsigned long long)sum);
}

int main() {
    const char *names[] = {"random", "sorted", "reversed", "few16", "saw1000"};
    for (size_t n : {1000ul, 100000ul, 1000000ul}) {
        int reps = n == 1000 ? 2000 : n == 100000 ? 40 : 8;
        for (int k = 0; k < 5; k++) {
            lane("sort", names[k], k, n, reps, [](std::vector<uint64_t> &v) { std::sort(v.begin(), v.end()); });
            lane("sort_by", names[k], k, n, reps, [](std::vector<uint64_t> &v) { std::sort(v.begin(), v.end(), [](uint64_t a, uint64_t b) { return b < a; }); });
            lane("stable", names[k], k, n, reps, [](std::vector<uint64_t> &v) { std::stable_sort(v.begin(), v.end()); });
            lane("stable_by", names[k], k, n, reps, [](std::vector<uint64_t> &v) { std::stable_sort(v.begin(), v.end(), [](uint64_t a, uint64_t b) { return b < a; }); });
            lane("select", names[k], k, n, reps, [](std::vector<uint64_t> &v) { std::nth_element(v.begin(), v.begin() + v.size() / 2, v.end()); });
            lane("heap", names[k], k, n, reps, [](std::vector<uint64_t> &v) { std::make_heap(v.begin(), v.end()); std::sort_heap(v.begin(), v.end()); });
        }
    }
}
