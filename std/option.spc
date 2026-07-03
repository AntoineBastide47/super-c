// Option<T>: an optional value -- `Some(T)` or `None`. A payload-bearing generic enum, monomorphized
// per element type. Methods that yield the contained value CONSUME `self` (Rust's by-value `Option`):
// matching an owned value moves the payload out, so the source is not double-freed. Read-only methods take
// `&self` and bind the payload by reference (`switch` binding modes). `Option<T>` is auto-`Free` exactly
// when `T` is (conditional conformance): freeing a `Some(t)` deep-frees its payload.

pub enum Option<T> {
    Some(T),
    None,
}

extend<T> Option<T> {

    pub fn some(value: T) Option<T> {
        return Option::<T>::Some(value);
    }

    pub fn none() Option<T> {
        return Option::<T>::None;
    }

    pub fn is_some(self: &Option<T>) bool {
        return switch self {
            Some(_) => true,
            None => false,
        };
    }

    pub fn is_none(self: &Option<T>) bool {
        return switch self {
            Some(_) => false,
            None => true,
        };
    }

    // The contained value; panics on `None`. Consumes `self`.
    pub fn unwrap(self: Option<T>) T {
        return switch self {
            Some(v) => v,
            None => panic("Option::unwrap on None"),
        };
    }

    // The contained value; panics with `msg` on `None`. Consumes `self`.
    pub fn expect(self: Option<T>, msg: str) T {
        return switch self {
            Some(v) => v,
            None => panic(msg),
        };
    }

    // The contained value, or `default` when empty. Consumes `self` (matching the owned value moves the
    // payload out); the unused alternative is freed by scope-exit auto-`Free`.
    pub fn unwrap_or(self: Option<T>, default: T) T {
        return switch self {
            Some(v) => v,
            None => default,
        };
    }

    // The contained value, or `f()` computed lazily when empty. Consumes `self`.
    pub fn unwrap_or_else(self: Option<T>, f: fn() T) T {
        return switch self {
            Some(v) => v,
            None => f(),
        };
    }

    // Replace the value in place (returns the previous Option). The old payload travels out in `old`.
    pub fn replace(self: &mut Option<T>, value: T) Option<T> {
        let old = *self;
        *self = Option::<T>::Some(value);
        return old;
    }

    // Take the value out in place, leaving `None` behind (returns the previous Option).
    pub fn take(self: &mut Option<T>) Option<T> {
        let old = *self;
        *self = Option::<T>::None;
        return old;
    }

    // Map the contained value through `f`, producing `Option<U>` (`None` stays `None`). Consumes `self`.
    pub fn map<U, F: fn(T) U>(self: Option<T>, f: F) Option<U> {
        return switch self {
            Some(v) => Option::<U>::Some(f(v)),
            None => Option::<U>::None,
        };
    }

    // Map the contained value, or return `default` when empty. Consumes `self`; frees the unused `default`
    // on the `Some` path (a no-op for non-`Free` types).
    pub fn map_or<U, F: fn(T) U>(self: Option<T>, default: U, f: F) U {
        return switch self {
            Some(v) => f(v),
            None => default,
        };
    }

    // Chain a fallible step: `f` itself returns an `Option<U>` (flat-map / "bind"). Consumes `self`.
    pub fn and_then<U, F: fn(T) Option<U>>(self: Option<T>, f: F) Option<U> {
        return switch self {
            Some(v) => f(v),
            None => Option::<U>::None,
        };
    }

    // Keep the value only when `pred` holds, else `None`. Consumes `self`; the `&self` match lets `pred`
    // peek the payload before `self` is moved. On rejection `self` is freed by scope-exit auto-`Free`.
    // NOTE: `pred` takes `T` by value, so for a Free element type this copies (and the copy is freed),
    // double-freeing the payload `self` still owns. A `fn(&T)` predicate is the right fix but currently
    // hits two compiler gaps (over-const borrow of an embedded pointer payload; no `&mut`->`&` coercion).
    pub fn filter<F: fn(T) bool>(self: Option<T>, pred: F) Option<T> {
        let keep = switch &self {
            Some(v) => pred(*v),
            None => false,
        };
        if keep {
            return self;
        }
        return Option::<T>::None;
    }

    // `self` when it holds a value, otherwise `other`. Consumes both; the unused alternative is freed by
    // scope-exit auto-`Free`.
    pub fn or(self: Option<T>, other: Option<T>) Option<T> {
        return switch self {
            Some(v) => Option::<T>::Some(v),
            None => other,
        };
    }

    // `None` when `self` is empty, otherwise `other`. Consumes both: on `Some` the discarded `self` payload
    // is freed and `other` is returned; on `None` the unused `other` param is freed by auto-`Free`.
    pub fn and<U>(self: Option<T>, other: Option<U>) Option<U> {
        return switch self {
            Some(mut v) => { v.free(); other; },
            None => Option::<U>::None,
        };
    }
}

// The default Option is the empty one.
extend<T> Option<T> as Default {
    pub fn default() Option<T> { return Option::<T>::none(); }
}

// Auto-`Free` exactly when the payload is: freeing a `Some(t)` deep-frees `t` in place (the `&mut self`
// match binds the payload by reference).
extend<T: Free> Option<T> as Free {
    pub fn free(self: &mut Option<T>) {
        switch self {
            Some(v) => v.free(),
            None => {},
        };
    }
}

// Conditional conformances: an Option is Clone/Eq/Hash exactly when its payload is. Each binds the payload
// by reference (`&self` match) and dispatches to the payload's own bound method.
extend<T: Clone> Option<T> as Clone {
    pub fn clone(self: &Option<T>) Option<T> {
        return switch self {
            Some(v) => Option::<T>::Some(v.clone()),
            None => Option::<T>::None,
        };
    }
}

extend<T: Eq> Option<T> as Eq {
    pub fn eq(self: &Option<T>, other: &Option<T>) bool {
        return switch self {
            Some(a) => switch other {
                Some(b) => a.eq(b),
                None => false,
            },
            None => other.is_none(),
        };
    }
}

extend<T: Hash> Option<T> as Hash {
    pub fn hash(self: &Option<T>) u64 {
        return switch self {
            Some(v) => v.hash() * 0x100000001b3 + 1,
            None => 0 as u64,
        };
    }
}

extend<T: Format> Option<T> as Format {
    pub fn fmt(self: &Option<T>) String {
        if self.is_none() {
            return String::from_str("None");
        }
        let mut inner = switch self { // Some -- bind and format the payload (None arm is unreachable here)
            Some(v) => v.fmt(),
            None => String::new(),
        };
        let mut s = String::from_str("Some(");
        s.push_string(&inner);
        inner.free();
        s.push_str(")");
        return s;
    }
}
