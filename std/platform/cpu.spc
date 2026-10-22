// The online core count (the run-time CPU feature queries are `std::cpu::detect`). Unstable, internal to std
// and the compiler.
import sc_runtime;

/// The number of online logical CPUs, at least 1: one on WASI, whose module runs on one thread.
pub fn count() Result<usize, IoError> {
    return Result::<usize, IoError>::Ok(sc_runtime::sc_rt_ncpu());
}
