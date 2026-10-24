// First-class tuples. `(A, B)` is sugar for `Tuple2<A, B>`, an ordinary prelude struct, exactly
// like `[]T` lowering to `Slice<T>`. A tuple literal `(a, b)` builds one, `t.0` reads field `_0`,
// and `let (a, b) = t;` destructures by field. Arity is 2-4; tuples are plain value types (no
// `Free` conformance: elements are moved in on construction and moved out on destructuring).
//
// A tuple is `Eq`, `Ord`, `Hash`, `Clone`, `Default` and `Format` when every element is: `cmp` is
// lexicographic in element order, `hash` is FNV-1a over the elements' own hashes and `hash_into` feeds
// the elements in order, so tuples key a `Map` and sort; `fmt` renders `(a, b)`. The bodies are written
// out rather than inherited from the field-wise defaults: an inherited default is checked against every
// tuple instance, also one whose elements lack the interface.

/// The struct behind `(A, B)`; `.0`/`.1` are `_0`/`_1`.
pub struct Tuple2<T0, T1> {
    pub _0: T0,
    pub _1: T1,
}
/// The struct behind `(A, B, C)`.
pub struct Tuple3<T0, T1, T2> {
    pub _0: T0,
    pub _1: T1,
    pub _2: T2,
}
/// The struct behind `(A, B, C, D)`.
pub struct Tuple4<T0, T1, T2, T3> {
    pub _0: T0,
    pub _1: T1,
    pub _2: T2,
    pub _3: T3,
}

// `sep`, then `v` rendered through its own `fmt`.
fn push_element<T: Format>(s: &mut String, sep: str, v: &T) {
    s.push_str(sep);
    let f = v.fmt();
    s.push_string(&f);
}

extend<T0: Eq, T1: Eq> Tuple2<T0, T1> as Eq {
    pub fn eq(self: &Tuple2<T0, T1>, other: &Tuple2<T0, T1>) bool {
        return self._0 == other._0 && self._1 == other._1;
    }
}

extend<T0: Ord, T1: Ord> Tuple2<T0, T1> as Ord {
    pub fn cmp(self: &Tuple2<T0, T1>, other: &Tuple2<T0, T1>) i32 {
        let c = self._0.cmp(&other._0);
        if c != 0 {
            return c;
        }
        return self._1.cmp(&other._1);
    }
}

extend<T0: Hash, T1: Hash> Tuple2<T0, T1> as Hash {
    pub fn hash_into<H: Hasher>(self: &Tuple2<T0, T1>, h: &mut H) {
        self._0.hash_into(h);
        self._1.hash_into(h);
    }
}

extend<T0: Clone, T1: Clone> Tuple2<T0, T1> as Clone {
    pub fn clone(self: &Tuple2<T0, T1>) Tuple2<T0, T1> {
        return (self._0.clone(), self._1.clone());
    }
}

extend<T0: Default, T1: Default> Tuple2<T0, T1> as Default {
    pub fn default() Tuple2<T0, T1> {
        return (T0::default(), T1::default());
    }
}

extend<T0: Format, T1: Format> Tuple2<T0, T1> as Format {
    pub fn fmt(self: &Tuple2<T0, T1>) String {
        let mut s = String::from_str("(");
        push_element(&mut s, "", &self._0);
        push_element(&mut s, ", ", &self._1);
        s.push_str(")");
        return s;
    }
}

extend<T0: Eq, T1: Eq, T2: Eq> Tuple3<T0, T1, T2> as Eq {
    pub fn eq(self: &Tuple3<T0, T1, T2>, other: &Tuple3<T0, T1, T2>) bool {
        return self._0 == other._0 && self._1 == other._1 && self._2 == other._2;
    }
}

extend<T0: Ord, T1: Ord, T2: Ord> Tuple3<T0, T1, T2> as Ord {
    pub fn cmp(self: &Tuple3<T0, T1, T2>, other: &Tuple3<T0, T1, T2>) i32 {
        let mut c = self._0.cmp(&other._0);
        if c != 0 {
            return c;
        }
        c = self._1.cmp(&other._1);
        if c != 0 {
            return c;
        }
        return self._2.cmp(&other._2);
    }
}

extend<T0: Hash, T1: Hash, T2: Hash> Tuple3<T0, T1, T2> as Hash {
    pub fn hash_into<H: Hasher>(self: &Tuple3<T0, T1, T2>, h: &mut H) {
        self._0.hash_into(h);
        self._1.hash_into(h);
        self._2.hash_into(h);
    }
}

extend<T0: Clone, T1: Clone, T2: Clone> Tuple3<T0, T1, T2> as Clone {
    pub fn clone(self: &Tuple3<T0, T1, T2>) Tuple3<T0, T1, T2> {
        return (self._0.clone(), self._1.clone(), self._2.clone());
    }
}

extend<T0: Default, T1: Default, T2: Default> Tuple3<T0, T1, T2> as Default {
    pub fn default() Tuple3<T0, T1, T2> {
        return (T0::default(), T1::default(), T2::default());
    }
}

extend<T0: Format, T1: Format, T2: Format> Tuple3<T0, T1, T2> as Format {
    pub fn fmt(self: &Tuple3<T0, T1, T2>) String {
        let mut s = String::from_str("(");
        push_element(&mut s, "", &self._0);
        push_element(&mut s, ", ", &self._1);
        push_element(&mut s, ", ", &self._2);
        s.push_str(")");
        return s;
    }
}

extend<T0: Eq, T1: Eq, T2: Eq, T3: Eq> Tuple4<T0, T1, T2, T3> as Eq {
    pub fn eq(self: &Tuple4<T0, T1, T2, T3>, other: &Tuple4<T0, T1, T2, T3>) bool {
        return self._0 == other._0 && self._1 == other._1 && self._2 == other._2 && self._3 == other._3;
    }
}

extend<T0: Ord, T1: Ord, T2: Ord, T3: Ord> Tuple4<T0, T1, T2, T3> as Ord {
    pub fn cmp(self: &Tuple4<T0, T1, T2, T3>, other: &Tuple4<T0, T1, T2, T3>) i32 {
        let mut c = self._0.cmp(&other._0);
        if c != 0 {
            return c;
        }
        c = self._1.cmp(&other._1);
        if c != 0 {
            return c;
        }
        c = self._2.cmp(&other._2);
        if c != 0 {
            return c;
        }
        return self._3.cmp(&other._3);
    }
}

extend<T0: Hash, T1: Hash, T2: Hash, T3: Hash> Tuple4<T0, T1, T2, T3> as Hash {
    pub fn hash_into<H: Hasher>(self: &Tuple4<T0, T1, T2, T3>, h: &mut H) {
        self._0.hash_into(h);
        self._1.hash_into(h);
        self._2.hash_into(h);
        self._3.hash_into(h);
    }
}

extend<T0: Clone, T1: Clone, T2: Clone, T3: Clone> Tuple4<T0, T1, T2, T3> as Clone {
    pub fn clone(self: &Tuple4<T0, T1, T2, T3>) Tuple4<T0, T1, T2, T3> {
        return (self._0.clone(), self._1.clone(), self._2.clone(), self._3.clone());
    }
}

extend<T0: Default, T1: Default, T2: Default, T3: Default> Tuple4<T0, T1, T2, T3> as Default {
    pub fn default() Tuple4<T0, T1, T2, T3> {
        return (T0::default(), T1::default(), T2::default(), T3::default());
    }
}

extend<T0: Format, T1: Format, T2: Format, T3: Format> Tuple4<T0, T1, T2, T3> as Format {
    pub fn fmt(self: &Tuple4<T0, T1, T2, T3>) String {
        let mut s = String::from_str("(");
        push_element(&mut s, "", &self._0);
        push_element(&mut s, ", ", &self._1);
        push_element(&mut s, ", ", &self._2);
        push_element(&mut s, ", ", &self._3);
        s.push_str(")");
        return s;
    }
}
