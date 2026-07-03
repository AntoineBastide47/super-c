// First-class tuples. `(A, B)` is sugar for `Tuple2<A, B>` — an ordinary prelude struct, exactly
// like `[]T` lowering to `Slice<T>`. A tuple literal `(a, b)` builds one, `t.0` reads field `_0`,
// and `let (a, b) = t;` destructures by field. Arity is 2-4; tuples are plain value types (no
// `Free` conformance: elements are moved in on construction and moved out on destructuring).
pub struct Tuple2<T0, T1> { pub _0: T0, pub _1: T1 }
pub struct Tuple3<T0, T1, T2> { pub _0: T0, pub _1: T1, pub _2: T2 }
pub struct Tuple4<T0, T1, T2, T3> { pub _0: T0, pub _1: T1, pub _2: T2, pub _3: T3 }
