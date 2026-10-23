// The prelude contracts: `TryFrom` with its own associated `Error`, which `try_into` returns, and
// `String as Writer`, which accepts every byte.

struct Celsius {
    pub v: i32,
}

enum TooCold {
    Below(i32),
}

extend Celsius as TryFrom<i32> {
    type Error = TooCold;
    pub fn try_from(value: i32) Result<Celsius, TooCold> {
        if value < -273 {
            return Result::<Celsius, TooCold>::Err(TooCold::Below(value));
        }
        return Result::<Celsius, TooCold>::Ok(Celsius { v: value });
    }
}

@test
fn try_from_returns_its_own_error() {
    let ok: Result<Celsius, TooCold> = 20.try_into();
    assert_eq(ok.unwrap().v, 20);
    let cold: Result<Celsius, TooCold> = (-300).try_into();
    switch cold.unwrap_err() {
        Below(v) => assert_eq(v, -300),
    };
    assert(Celsius::try_from(-273).is_ok());
}

@test
fn string_writer_accepts_every_byte() {
    let mut s = String::from_str("ab");
    assert_eq(s.write([b'c', b'd', b'e']).unwrap(), 3usize);
    assert_eq(s.write([]).unwrap(), 0usize);
    assert(s.as_str() == "abcde");
}
