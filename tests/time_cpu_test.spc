// `time::cpu_seconds` is the process's processor time: work advances it and a sleep does not. The Windows
// C runtime's `clock()` counts wall time since the process started, so a sleep advanced it there. wasm has
// no process clock (wasi emulates it with the wall clock), so the test does not run there.

import time;
import std::parallel::runtime as rt;
import std::parallel::platform as platform;

@platform(!wasm)
@test
fn cpu_seconds_counts_processor_time_only() {
    let t0 = time::cpu_seconds();
    assert(t0 >= 0.0, "the process clock is available");
    rt::sleep_ns(300000000);
    let slept = time::cpu_seconds() - t0;
    assert(slept < 0.1, "a 300 ms sleep consumes almost no processor time");
    // Spin until 50 ms of processor time have passed; ten seconds of wall time bound the loop.
    let t1 = time::cpu_seconds();
    let w0 = platform::now_ns();
    let mut x: u64 = 1;
    while time::cpu_seconds() - t1 < 0.05 && platform::now_ns() - w0 < 10000000000u64 {
        for i in 0..100000u64 {
            x = x.wrapping_mul(6364136223846793005u64).wrapping_add(i);
        }
    }
    assert(x != 0, "the spin ran");
    assert(time::cpu_seconds() - t1 >= 0.05, "work advances the processor time");
}
