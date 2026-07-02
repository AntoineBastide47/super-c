// Minimal test helpers. These abort the process on failure, which keeps them usable in small programs and
// generated tests without requiring a runner.

extern "C" {
    fn abort() void;
}

pub fn assert_true(condition: bool) {
    if !condition {
        unsafe abort();
    }
}

pub fn assert_eq<T: Eq>(left: &T, right: &T) {
    if !left.eq(right) {
        unsafe abort();
    }
}

pub fn assert_ne<T: Eq>(left: &T, right: &T) {
    if left.eq(right) {
        unsafe abort();
    }
}
