// Result<T, E>: success `Ok(T)` or failure `Err(E)`. A two-parameter payload-bearing generic enum,
// monomorphized per (T, E). Value-yielding methods CONSUME `self` (matching the owned value moves the
// payload out); read-only methods take `&self` and bind the payload by reference (`switch` binding modes).
// `Result<T, E>` is auto-`Free` whenever `T` is `Free` (the `E` arm is freed through the `.free()`
// Free intrinsic -- a no-op when `E` is not `Free`); freeing it deep-frees the live payload.

pub enum Result<T, E> {
    Ok(T),
    Err(E),
}

extend<T, E> Result<T, E> {
    pub const fn ok(value: T) Result<T, E> {
        return Result::<T, E>::Ok(value);
    }

    pub const fn err(error: E) Result<T, E> {
        return Result::<T, E>::Err(error);
    }

    pub const fn is_ok(self: &Result<T, E>) bool {
        return switch self {
            Ok(_) => true,
            Err(_) => false,
        };
    }

    pub const fn is_err(self: &Result<T, E>) bool {
        return switch self {
            Ok(_) => false,
            Err(_) => true,
        };
    }

    /// The success value; panics on `Err`. Consumes `self`. A panic aborts the process with no
    /// unwinding, so the discarded payload is never cleaned up.
    pub const fn unwrap(self: Result<T, E>) T {
        return switch self {
            Ok(v) => v,
            Err(_) => panic("Result::unwrap on Err"),
        };
    }

    /// The success value; panics with `msg` on `Err`. Consumes `self`.
    pub const fn expect(self: Result<T, E>, msg: str) T {
        return switch self {
            Ok(v) => v,
            Err(_) => panic(msg),
        };
    }

    /// The error value; panics on `Ok`. Consumes `self`.
    pub const fn unwrap_err(self: Result<T, E>) E {
        return switch self {
            Ok(_) => panic("Result::unwrap_err on Ok"),
            Err(e) => e,
        };
    }

    /// The success value, or `default` on `Err`. Consumes `self`; the discarded `Err` payload is freed and
    /// the unused `default` (on the `Ok` path) is freed by auto-`Free`.
    pub const fn unwrap_or(self: Result<T, E>, default: T) T {
        return switch self {
            Ok(v) => v,
            Err(e) => {
                default;
            },
        };
    }

    /// The error value, or `default` on `Ok`. Consumes `self`; the discarded `Ok` payload is freed.
    pub const fn err_or(self: Result<T, E>, default: E) E {
        return switch self {
            Ok(v) => {
                default;
            },
            Err(e) => e,
        };
    }

    /// The success value, or `f(error)` computed lazily on the error case. Consumes `self`.
    pub const fn unwrap_or_else(self: Result<T, E>, f: fn(E) T) T {
        return switch self {
            Ok(v) => v,
            Err(e) => f(e),
        };
    }

    /// Map the success value through `f`, leaving an error untouched. Consumes `self`.
    pub const fn map<U, F: fn(T) U>(self: Result<T, E>, f: F) Result<U, E> {
        return switch self {
            Ok(v) => Result::<U, E>::Ok(f(v)),
            Err(e) => Result::<U, E>::Err(e),
        };
    }

    /// Map the error value through `f`, leaving a success untouched. Consumes `self`.
    pub const fn map_err<F, M: fn(E) F>(self: Result<T, E>, f: M) Result<T, F> {
        return switch self {
            Ok(v) => Result::<T, F>::Ok(v),
            Err(e) => Result::<T, F>::Err(f(e)),
        };
    }

    /// Chain a fallible step on the success value; `f` returns its own `Result` (flat-map). Consumes `self`.
    pub const fn and_then<U, F: fn(T) Result<U, E>>(self: Result<T, E>, f: F) Result<U, E> {
        return switch self {
            Ok(v) => f(v),
            Err(e) => Result::<U, E>::Err(e),
        };
    }

    /// `self` when it is `Ok`, otherwise `other`. Consumes both; the discarded `Err` payload is freed and
    /// the unused `other` (on the `Ok` path) is freed by auto-`Free`.
    pub const fn or(self: Result<T, E>, other: Result<T, E>) Result<T, E> {
        return switch self {
            Ok(v) => Result::<T, E>::Ok(v),
            Err(e) => {
                other;
            },
        };
    }

    /// The success value as an `Option` (`Err` becomes `None`). Consumes `self`; the discarded `Err` payload
    /// is freed.
    pub const fn get_ok(self: Result<T, E>) Option<T> {
        return switch self {
            Ok(v) => Option::<T>::Some(v),
            Err(e) => {
                Option::<T>::None;
            },
        };
    }

    /// The error value as an `Option` (`Ok` becomes `None`). Consumes `self`; the discarded `Ok` payload is
    /// freed.
    pub const fn get_err(self: Result<T, E>) Option<E> {
        return switch self {
            Ok(v) => {
                Option::<E>::None;
            },
            Err(e) => Option::<E>::Some(e),
        };
    }
}

// Auto-`Free` whenever `T` is `Free`: freeing deep-frees the live payload in place (the `&mut self` match
// binds it by reference). The `Err` arm's `.free()` is the Free intrinsic -- a no-op unless `E` too
// is `Free`.
extend<T: Free, E> Result<T, E> as Free {
    pub fn free(self: &mut Result<T, E>) {
        switch self {
            Ok(v) => v.free(),
            Err(e) => e.free(),
        };
    }
}

// Conditional conformances: a Result is Clone/Eq exactly when both its arms are (read-only, ref-binding).
extend<T: Clone, E: Clone> Result<T, E> as Clone {
    pub const fn clone(self: &Result<T, E>) Result<T, E> {
        return switch self {
            Ok(v) => Result::<T, E>::Ok(v.clone()),
            Err(e) => Result::<T, E>::Err(e.clone()),
        };
    }
}

extend<T: Eq, E: Eq> Result<T, E> as Eq {
    pub const fn eq(self: &Result<T, E>, other: &Result<T, E>) bool {
        return switch self {
            Ok(a) => switch other {
                Ok(b) => *a == *b,
                Err(_) => false,
            },
            Err(a) => switch other {
                Ok(_) => false,
                Err(b) => *a == *b,
            },
        };
    }
}

extend<T: Format, E: Format> Result<T, E> as Format {
    pub fn fmt(self: &Result<T, E>) String {
        let inner = switch self {
            Ok(v) => v.fmt(),
            Err(e) => e.fmt(),
        };
        let mut s = String::new();
        if self.is_ok() {
            s.push_str("Ok(");
        } else {
            s.push_str("Err(");
        }
        s.push_string(&inner);
        s.push_str(")");
        return s;
    }
}
