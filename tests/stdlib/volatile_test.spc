// std::mem::volatile: a volatile read and write give an ordinary access's value for scalars, aggregates
// and pointers, at run time and in a constant; `zeroize` and `zeroize_raw` clear exactly their bytes at
// every alignment.
import std::mem::volatile as vol;

struct Pair {
    pub a: i32,
    pub b: u8,
}

extend Pair as Copy {}

const fn round_trip() u64 {
    let mut x: u64 = 5;
    let px: *mut u64 = &mut x;
    unsafe {
        vol::write_volatile(px, 41);
        return vol::read_volatile(px) + x;
    }
}

const ROUND_TRIP: u64 = round_trip();

@test
fn read_and_write_scalars_aggregates_and_pointers() {
    let mut p = Pair { a: 1, b: 2 };
    let pp: *mut Pair = &mut p;
    let mut fp: *const u8 = null;
    let pf: *mut *const u8 = &mut fp;
    unsafe {
        vol::write_volatile(pp, Pair { a: 7, b: 9 });
        let q = vol::read_volatile(pp);
        assert_eq(q.a, 7);
        assert_eq(q.b, 9);
        vol::write_volatile(pf, &p.b);
        assert_eq(*vol::read_volatile(pf), 9);
    }
    assert_eq(round_trip(), 82);
}

@test
fn volatile_accesses_fold_as_ordinary_ones() {
    static_assert(ROUND_TRIP == 82, "a volatile write then read folds");
    assert_eq(ROUND_TRIP, round_trip());
}

@test
fn zeroize_clears_every_byte() {
    let mut buf: [u8; 37] = [0xAB; 37];
    vol::zeroize(buf);
    for x in buf {
        assert_eq(x, 0);
    }
    let mut none: [u8; 0] = [];
    vol::zeroize(none);
}

@test
fn zeroize_raw_clears_its_range_at_every_alignment() {
    for start in 0usize..9 {
        for n in 0usize..20 {
            let mut b = Vector::<u8>::new();
            for _ in 0..32 {
                b.push(1);
            }
            unsafe vol::zeroize_raw(unsafe (b.as_ptr() as *mut u8 + start), n);
            for k in 0usize..32 {
                let want: u8 = if k >= start && k < start + n {
                    0;
                } else {
                    1;
                };
                assert_eq(*b.at(k), want);
            }
        }
    }
}
