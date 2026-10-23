// std::platform::env: a set value reads back as a copy, appears once in a snapshot and disappears with
// `unset`; names the system cannot hold are rejected before any change.

import std::platform::env;

@test
fn set_get_unset_and_snapshot() {
    unsafe env::set("SC_PLAT_ENV_T", "a b=c \xC3\xA9").unwrap();
    let v = env::get("SC_PLAT_ENV_T").unwrap().unwrap();
    // The copy stays valid across a later change.
    unsafe env::set("SC_PLAT_ENV_T", "second").unwrap();
    assert(v.eq_str("a b=c \xC3\xA9"));
    assert(env::get("SC_PLAT_ENV_T").unwrap().unwrap().eq_str("second"));
    let vars = env::vars().unwrap();
    let mut it = vars.iter();
    let mut hits = 0;
    let mut total = 0;
    while let Some((name, value)) = it.next() {
        if name == "SC_PLAT_ENV_T" {
            assert(value == "second");
            hits += 1;
        }
        total += 1;
    }
    assert_eq(hits, 1);
    assert(total > 1);
    unsafe env::unset("SC_PLAT_ENV_T").unwrap();
    assert(env::get("SC_PLAT_ENV_T").unwrap().is_none());
    unsafe env::unset("SC_PLAT_ENV_T").unwrap(); // already unset
}

@test
fn rejects_names_the_environment_cannot_hold() {
    let bad: [str; 3] = ["", "A=B", "A\x00B"];
    for n in bad {
        let e = env::get(n).unwrap_err();
        assert(e.kind == IoErrorKind::InvalidInput);
        assert(e.op == IoOp::GetEnv);
        assert(unsafe env::set(n, "v").unwrap_err().kind == IoErrorKind::InvalidInput);
        assert(unsafe env::unset(n).unwrap_err().kind == IoErrorKind::InvalidInput);
    }
    assert(unsafe env::set("SC_PLAT_ENV_NUL", "a\x00b").unwrap_err().kind == IoErrorKind::InvalidInput);
    assert(env::get("SC_PLAT_ENV_NUL").unwrap().is_none());
}
