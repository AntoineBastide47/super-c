// Implicit cross-width integer widening (`UInt<M>` where a wider `UInt<BITS>` is expected) selects the
// generic `widen<const M>` conversion. Emitting that library conversion with its OWN generics binds
// them from the argument through the conversion-symbol path. Built through the compiler so the emit
// path runs.
import tests::harness as h;

@test
fn implicit_uint_widening_runs() {
    // 5 as UInt<128> flows into a UInt<256> parameter without an explicit call; the value survives.
    h::expect_exit(
        "narrow uint widens into a wider slot",
        "import std::int as bigint;\nfn wider(x: bigint::UInt<256>) u64 {\n    return x.limb(0);\n}\nfn main() i32 {\n    let a = bigint::UInt::<128>::from(5);\n    return wider(a) as i32 - 5;\n}\n",
        0,
    );
}

@test
fn implicit_int_widening_runs() {
    // The signed twin: Int<128> into an Int<256> slot.
    h::expect_exit(
        "narrow int widens into a wider slot",
        "import std::int as bigint;\nfn wider(x: bigint::Int<256>) i64 {\n    return x.to_i64();\n}\nfn main() i32 {\n    let a = bigint::Int::<128>::from(-7);\n    return (wider(a) + 7) as i32;\n}\n",
        0,
    );
}
