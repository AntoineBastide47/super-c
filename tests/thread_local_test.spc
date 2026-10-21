// `@thread_local` gives a `static mut` one object per OS thread. Each use reaches the object through an
// accessor the C compiler cannot fold across calls, since a coroutine may resume on another thread.
import tests::harness as h;

// Each thread starts from the initializer and changes only its own object.
const THREADS: str = M"(import pthread;

@thread_local
static mut COUNT: u64 = 7;
@thread_local
static mut LANES: [i32; 4] = [1, 2, 3, 4];
static mut SEEN: u64 = 0;

fn bump(n: u64) u64 {
    for _i in 0..n {
        unsafe COUNT += 1;
    }
    unsafe LANES[1] += 10;
    return unsafe COUNT;
}

fn worker(arg: *mut void) *mut void {
    let v = bump(5);
    unsafe SEEN = v + unsafe LANES[1] as u64;
    return arg;
}

fn main() i32 {
    let mut t = unsafe zeroed::<pthread::pthread_t>();
    unsafe pthread::pthread_create(&mut t, null, worker, null);
    let mine = bump(100);
    unsafe pthread::pthread_join(t, null);
    let p = &mut unsafe COUNT;
    *p = 1;
    if mine != 107 || unsafe SEEN != 24 || unsafe LANES[1] != 12 || unsafe COUNT != 1 {
        return 1;
    }
    return 0;
}
)";

fn each_thread_has_its_own_object(b: &mut h::ExitBatch) {
    b.add("each thread has its own thread-local objects", THREADS, 0);
}

@test
fn uses_go_through_the_accessor() {
    let c = h::compile_c(
        "@thread_local\nstatic mut N: [u32; 2] = [3, 4];\nfn main() i32 {\n    unsafe N[1] += 1;\n    return unsafe N[1] as i32 - 5;\n}\n",
    );
    assert(c.ok(), "the program compiles");
    assert(c.code_has("extern _Thread_local uint32_t N[2];"), "the declaration is thread-local");
    assert(c.code_has("_Thread_local uint32_t N[2] = { 3, 4 };"), "the definition is thread-local");
    assert(c.code_has("static __attribute__((noinline, unused)) uint32_t (*N__tls(void))[2] {"), "the accessor");
    assert(c.code_has("(*N__tls())[1]"), "a use calls the accessor");
}

@test
fn thread_local_errors() {
    h::expect_err_msg(
        "on a constant",
        "@thread_local\nconst K: i32 = 3;\nfn main() i32 { return K; }\n",
        "'@thread_local' may only be applied to a 'static mut'",
    );
    h::expect_err_msg(
        "on a function",
        "@thread_local\nfn f() {}\nfn main() i32 { return 0; }\n",
        "'@thread_local' may only be applied to a 'static mut'",
    );
    h::expect_err_msg(
        "its address in a static initializer",
        "@thread_local\nstatic mut C: u64 = 7;\nstatic mut P: *mut u64 = &mut unsafe C;\nfn main() i32 { return 0; }\n",
        "a thread-local has one object per thread: a constant or 'static mut' initializer cannot use it",
    );
    h::expect_err_msg(
        "with an argument",
        "@thread_local(1)\nstatic mut C: u64 = 7;\nfn main() i32 { return 0; }\n",
        "attribute '@thread_local' takes no arguments",
    );
}

// The exit-code cases of the provider functions above, one program per group (`h::ExitBatch`).
@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    each_thread_has_its_own_object(&mut b);
    b.run();
}
