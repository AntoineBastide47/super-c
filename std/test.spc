// Test assertions -- COMPILER BUILTINS. Every call is desugared at its call site (the typechecker
// checks the arguments specially; codegen bakes in the failing expression's source text and its
// file:line, prints the left/right values where the type is directly printable, and aborts), so the
// bodies below are never emitted. The `unsafe abort()` bodies also keep CTFE honest: an interpreted
// caller bails to runtime instead of silently skipping an assertion.
//
//   assert(cond)              assert(cond, "message")   -- the message must be a `str`
//   assert_eq(left, right)    assert_ne(left, right)    -- one type; builtin/str/String/enum or Eq
//
// Arguments are READ, not moved: asserting on an owned String/Vector leaves it usable afterwards.

extern "C" {
    fn abort() void;
}

pub fn assert(condition: bool, ...) {
    if !condition {
        unsafe abort();
    }
}

pub fn assert_eq(condition: bool, ...) {
    unsafe abort(); // placeholder body (calls never reach it; see the header comment)
}

pub fn assert_ne(condition: bool, ...) {
    unsafe abort(); // placeholder body (calls never reach it; see the header comment)
}
