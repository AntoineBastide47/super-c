// Super-C language and C-emission demo.
//
// Keep this program deterministic and portable. Each section uses a language
// feature in executable code, so demand-driven emission cannot hide a bad
// lowering. A zero exit status is the contract.
//
// Raw strings are intentionally absent: matchertext literals (`M"(...)"`) replace them, so
// `r"..."` lexes as an identifier followed by a string. Everything else the language offers has an
// executable section below -- tuple structs, `for value in slice`, byte strings, and `&dyn`
// parameters included.

const ANSWER: i32 = 42;
const fn triangular(n: i32) i32 {
    let mut total = 0;
    for i in 0..=n {
        total += i;
    }
    return total;
}

static_assert(triangular(8) == 36, "const evaluation");
static_assert(sizeof((i32, bool)) >= sizeof(i32) + sizeof(bool), "tuple layout");

static mut VISITS: i32 = 0;

extern "C" {
    fn free(pointer: *mut void) void;
}

type Score = i32;

struct Point {
    pub x: i32,
    pub y: i32,
}

struct Marker;

struct Rgb(i32, i32, i32);

struct Boxed<T>(T);

struct Pair<A, B> {
    pub first: A,
    pub second: B,
}

union NumberBits {
    pub integer: u32,
    pub real: f32,
}

enum Shape {
    Dot,
    Circle(i32),
    Rect { width: i32, height: i32 },
}

interface Area {
    fn area(self: &Self) i32;
    fn doubled(self: &Self) i32 {
        return self.area() * 2;
    }
}

extend Point {
    pub fn moved(self: &Point, dx: i32, dy: i32) Point {
        return Point { x: self.x + dx, y: self.y + dy };
    }

    pub fn add(self: &Point, other: &Point) Point {
        return Point { x: self.x + other.x, y: self.y + other.y };
    }
}

extend Point as Area {
    pub fn area(self: &Point) i32 {
        return self.x * self.y;
    }
}

extend Point as Deref<i32> {
    pub fn deref(self: &Point) &i32 {
        return &self.x;
    }
}

fn identity<T>(value: T) T {
    return value;
}

fn greater<'a>(left: &'a i32, right: &'a i32) &'a i32 {
    if *left > *right {
        return left;
    }
    return right;
}

fn make_pair<A, B>(first: A, second: B) Pair<A, B> {
    return Pair::<A, B> { first: first, second: second };
}

fn sum_inline<const N: usize>() usize {
    let mut total: usize = 0;
    inline for i in 0..N {
        total += i;
    }
    return total;
}

fn field_count<T>() usize {
    let mut count: usize = 0;
    inline for _field in 0..type_info::<T>().fields.len {
        count += 1;
    }
    return count;
}

fn divmod(divisor: i32, value: i32) (i32, i32) {
    return value / divisor, value % divisor;
}

fn shape_area(shape: Shape) i32 {
    return switch shape {
        Dot => 0,
        Circle(radius) => radius * radius * 3,
        Rect { width: width, height: height } => width * height,
    };
}

fn classify(value: i32) i32 {
    return switch value {
        0 => 0,
        1 | 2 | 3 => 1,
        4..=9 => 2,
        n if n < 0 => -1,
        _ => 3,
    };
}

fn dynamic_area(value: &dyn Area) i32 {
    return value.doubled();
}

fn apply(function: fn(i32) i32, value: i32) i32 {
    return function(value);
}

fn apply_generic<F: fn(i32) i32>(function: F, value: i32) i32 {
    return function(value);
}

fn checked(value: i32) Result<i32, i32> {
    if value < 0 {
        return Result::<i32, i32>::Err(value);
    }
    return Result::<i32, i32>::Ok(value + 1);
}

fn checked_twice(value: i32) Result<i32, i32> {
    let next = checked(value)?;
    return Result::<i32, i32>::Ok(next * 2);
}

fn sum_slice(values: []i32) i32 {
    let mut total = 0;
    for i in 0..values.len() {
        total += *values.get(i);
    }
    return total;
}

fn loop_forms() i32 {
    let mut total = 0;
    let mut i = 0;
    while i < 4 {
        i += 1;
        if i == 2 {
            continue;
        }
        total += i;
    }

    do {
        total += 1;
    } while false;

    let yielded = loop {
        break 5;
    };

    'outer: for x in 0..3 {
        for y in 0..3 {
            if x + y == 3 {
                break 'outer;
            }
            total += 1;
        }
    }
    return total + yielded;
}

unsafe fn raw_read_twice(pointer: *const i32) i32 {
    return *pointer + pointer[0];
}

fn pointer_and_defer() i32 {
    let pointer = new i32 (21);
    defer unsafe free(pointer);
    unsafe *pointer += 1;
    let view: &i32 = unsafe &*pointer;
    return unsafe raw_read_twice(view);
}

fn ownership_and_containers() i32 {
    let mut text = String::from_str("super");
    text.push_str("-c");

    let mut values = Vector::<i32>::with_capacity(4);
    values.push(1);
    values.push(2);
    values.push(3);
    let mut popped = 0;
    switch values.pop() {
        Some(value) => {
            popped = value;
        },
        _ => {},
    };

    let mut mapped = 0;
    loop {
        switch values.pop() {
            Some(value) => {
                mapped += value;
            },
            _ => {
                break;
            },
        };
    }
    return text.len() as i32 + popped + mapped;
}

fn sum_by_value(values: []i32) i32 {
    let mut total = 0;
    for value in values {
        total += value;
    }
    return total;
}

@c.inline
fn attributed(value: i32) i32 {
    return value;
}

fn main(args: Vector<str>) i32 {
    let _: Marker = Marker {};
    let pair: Pair<Score, i32> = make_pair(identity(20), 7);
    let (quotient, remainder) = divmod(5, pair.first + pair.second);
    assert_eq(quotient, 5);
    assert_eq(remainder, 2);

    let mut point = Point { x: 3, y: 4 };
    point = point.moved(1, 1);
    point += Point { x: 1, y: 1 };
    assert_eq(point.area(), 30);
    assert_eq(*point, 5);
    assert_eq(dynamic_area(&point), 60);
    assert_eq(*greater(&point.x, &point.y), 6);

    assert_eq(shape_area(Shape::Circle(3)), 27);
    assert_eq(shape_area(Shape::Rect { width: 6, height: 7 }), ANSWER);
    assert_eq(shape_area(Shape::Dot), 0);
    assert_eq(classify(-3), -1);
    assert_eq(classify(8), 2);

    let plain = |value: i32| value * 2;
    let offset = 10;
    let captured = |value: i32| value + offset;
    let anonymous = fn(value: i32) i32 {
        return value - 1;
    };
    assert_eq(apply(plain, 6), 12);
    assert_eq(apply(anonymous, 6), 5);
    assert_eq(captured(5), 15);
    assert_eq(apply_generic(plain, 5), 10);

    let array: [i32; 5] = [1, 2, 3, 4, 5];
    let slice: []i32 = array[1..4];
    assert_eq(sum_slice(slice), 9);
    assert_eq(sum_inline::<10>(), 45);
    assert_eq(field_count::<Point>(), 2);
    assert_eq(loop_forms(), 19);

    let result = checked_twice(20);
    assert_eq(
        switch result {
            Ok(value) => value,
            Err(error) => error,
        },
        ANSWER,
    );

    let bits = NumberBits { integer: 0x3f800000u32 };
    assert_eq(bits.real, 1.0f32);
    assert_eq(pointer_and_defer(), 44);
    assert_eq(ownership_and_containers(), 13);

    let color = Rgb(10, 20, 12);
    assert_eq(color.0 + color.1 + color.2, ANSWER);
    let wrapped = Boxed::<i32>(ANSWER);
    assert_eq(wrapped.0, ANSWER);

    assert_eq(sum_by_value(slice), 9);

    let bytes = b"AB";
    assert_eq(bytes[0] as i32 + bytes[1] as i32, 131);

    let raw = "raw text";
    assert_eq(raw.len(), 8);
    assert_eq(0x1.8p3, 12.0);

    let mut sparse: [i32; 8] = [[2] = 40, [7] = 2];
    sparse[0] = args.len() as i32;
    assert_eq(sparse[2] + sparse[7], ANSWER);

    unsafe {
        VISITS += 1;
        assert_eq(VISITS, 1);
    }
    return attributed(0);
}
