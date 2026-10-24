// The prelude hashing contract: `Hash::hash_into` streams through a `Hasher`, equal values feed equal
// streams, and the derived form walks fields and variants.

// A hasher that records the stream, so a test compares the bytes a value feeds.
struct Tape {
    pub bytes: Vector<u8>,
}

extend Tape {
    fn new() Tape {
        return Tape { bytes: Vector::<u8>::new() };
    }
}

extend Tape as Hasher {
    pub fn write(self: &mut Tape, bytes: []u8) {
        for b in bytes {
            self.bytes.push(b);
        }
    }
    pub fn finish(self: &Tape) u64 {
        return self.bytes.len() as u64;
    }
}

fn tape_of<T: Hash>(v: &T) Vector<u8> {
    let mut t = Tape::new();
    v.hash_into(&mut t);
    return replace(&mut t.bytes, Vector::<u8>::new());
}

@derive(Hash, Eq)
struct Point {
    pub x: i32,
    pub name: String,
}

@derive(Hash, Eq)
enum Shape {
    Dot,
    Circle(u8),
}

@test
fn integers_feed_their_hash_as_eight_bytes() {
    let t = tape_of(&0x0102i32);
    assert_eq(t.len(), 8);
    assert_eq(*t.at(0), 2u8);
    assert_eq(*t.at(1), 1u8);
    assert_eq(*t.at(7), 0u8);
}

@test
fn strings_feed_bytes_and_a_terminator() {
    let t = tape_of(&"ab");
    assert_eq(t.len(), 3);
    assert_eq(*t.at(0), b'a');
    assert_eq(*t.at(2), 0xFFu8);
    let s = String::from_str("ab");
    assert(tape_of(&s) == t);
}

@test
fn string_boundaries_are_part_of_the_stream() {
    let a: Vector<String> = [String::from_str("ab"), String::from_str("c")].into();
    let b: Vector<String> = [String::from_str("a"), String::from_str("bc")].into();
    assert(tape_of(&a) != tape_of(&b));
}

@test
fn derived_struct_walks_its_fields() {
    let p = Point { x: 7, name: String::from_str("q") };
    let t = tape_of(&p);
    // 8 bytes for `x`, then "q" and its terminator.
    assert_eq(t.len(), 10);
    assert_eq(*t.at(0), 7u8);
    assert_eq(*t.at(8), b'q');
    let q = Point { x: 7, name: String::from_str("q") };
    assert(tape_of(&q) == t);
}

@test
fn derived_enum_feeds_tag_then_payload() {
    let d = tape_of(&Shape::Dot);
    assert_eq(d.len(), 8);
    let circle = Shape::Circle(9);
    let c = tape_of(&circle);
    assert_eq(c.len(), 16);
    assert_eq(*c.at(0), 1u8);
    assert_eq(*c.at(8), 9u8);
}

@test
fn options_and_vectors_mark_presence_and_length() {
    let none: Option<u8> = Option::<u8>::None;
    assert_eq(tape_of(&none).len(), 1);
    let some = Option::<u8>::Some(3);
    assert_eq(tape_of(&some).len(), 9);
    let v: Vector<u8> = [1u8, 2u8].into();
    assert_eq(tape_of(&v).len(), 24);
}
