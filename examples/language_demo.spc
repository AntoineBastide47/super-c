// Super-C language and C-emission demo.

import std::parallel::channel as channel;
import std::parallel::data as parallel;
import std::parallel::runtime as runtime;
import std::simd;
import std::text::utf16;
import std::time;

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

@thread_local
static mut THREAD_CALLS: u32 = 0;

extern "C" {
    fn malloc(size: usize) *mut void;
    fn free(pointer: *mut void) void;
    @unsafe(safe)
    fn abs(value: i32) i32;
}

type Score = i32;

@derive(Solid)
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

type Twin<T> = Pair<T, T>;
type Bounds = (i32, i32);

union NumberBits {
    pub integer: u32,
    pub real: f32,
}

enum Shape {
    Dot,
    Circle(i32),
    Rect { width: i32, height: i32 },
}

enum Level {
    Low = 1,
    Mid,
    High = 10,
}

enum Token {
    Number(i32),
    End = 9,
    Skip,
}

interface Area {
    fn area(self: &Self) i32;
    fn doubled(self: &Self) i32 {
        return self.area() * 2;
    }
}

interface Solid: Area {
    fn volume(self: &Self, depth: i32) i32 {
        return self.area() * depth;
    }
}

extend Point {
    /// The point translated by (dx, dy).
    pub const fn moved(self: &Point, dx: i32, dy: i32) Point {
        return Point { x: self.x + dx, y: self.y + dy };
    }
}

extend Point as Add {
    type Output = Point;
    pub const fn add(self: &Point, other: &Point) Point {
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

extend Point as Neg {
    type Output = Point;
    pub const fn neg(self: &Point) Point {
        return Point { x: -self.x, y: -self.y };
    }
}

extend i32 as Mul<Point> {
    type Output = Point;
    pub const fn mul(self: &i32, other: &Point) Point {
        return Point { x: *self * other.x, y: *self * other.y };
    }
}

// Private fields: only this type's own extend blocks name `hits`.
struct Counter {
    pub label: i32,
    hits: i32,
}

extend Counter {
    pub const START: i32 = 100;

    pub const fn new(label: i32) Self {
        return Self { label: label, hits: Self::START };
    }

    pub fn bump(self: &mut Self) i32 {
        self.hits += 1;
        return self.hits;
    }
}

@derive(Clone, Eq, Ord, Hash, Format)
struct Version {
    pub major: i32,
    pub minor: i32,
}

struct Percent {
    pub value: u8,
}

extend Percent as TryFrom<i32> {
    type Error = i32;
    pub const fn try_from(value: i32) Result<Percent, i32> {
        if value < 0 || value > 100 {
            return Result::<Percent, i32>::Err(value);
        }
        return Result::<Percent, i32>::Ok(Percent { value: value as u8 });
    }
}

// `samples[i]` calls `index`; `samples[lo..hi]` calls `index_range`.
struct Samples {
    pub values: Vector<i32>,
}

extend Samples as Index<i32, []i32> {
    pub const fn index(self: &Samples, i: usize) &i32 {
        return self.values.at(i);
    }

    pub const fn index_range(self: &Samples, r: Range<usize>) []i32 {
        return self.values.index_range(r);
    }
}

// A generic conformance: every type that satisfies `Lane` gets `bits`.
interface Lane {}

extend i32 as Lane {}

extend i64 as Lane {}

interface Width {
    fn bits(self: &Self) usize;
}

extend<T: Lane> T as Width {
    pub const fn bits(self: &T) usize {
        return sizeof(T) * 8;
    }
}

struct Label<'a> {
    pub text: str<'a>,
}

@align(64)
struct CacheLine {
    pub value: u64,
}

@packed
struct WireHeader {
    pub tag: u8,
    pub length: u32,
}

static_assert(alignof(CacheLine) == 64, "cache-line alignment");
static_assert(sizeof(WireHeader) == 5, "packed layout");

// Visibility levels: an item without a modifier is private to its file.
pub(module) const LIMIT: i32 = i32::MAX;

pub(package) const fn clamp_add(a: i32, b: i32) i32 {
    return a.saturating_add(b);
}

// Build constants: a failed gate removes the item before name resolution.
@platform(windows)
const fn path_separator() char {
    return '\\';
}

@platform(!windows)
const fn path_separator() char {
    return '/';
}

@when(TEST)
const TEST_BUILD: bool = true;

@when(!TEST)
const TEST_BUILD: bool = false;

const fn identity<T>(value: T) T {
    return value;
}

const fn greater<'a>(left: &'a i32, right: &'a i32) &'a i32 {
    if *left > *right {
        return left;
    }
    return right;
}

const fn make_pair<A, B>(first: A, second: B) Pair<A, B> {
    return Pair::<A, B> { first: first, second: second };
}

const fn sum_inline<const N: usize>() usize {
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

// A local constant and a static assertion hold per instance.
const fn lane_bytes<T>() usize {
    const BYTES: usize = sizeof(T);
    static_assert(BYTES <= 8, "lanes fit in 8 bytes");
    return BYTES;
}

fn sum3<T: Add<Output = T> + Copy>(a: T, b: T, c: T) T {
    return a + b + c;
}

const fn divmod(divisor: i32, value: i32) (i32, i32) {
    return value / divisor, value % divisor;
}

const fn bounds(values: []i32) Bounds {
    let mut low = i32::MAX;
    let mut high = i32::MIN;
    for value in values {
        if unlikely(value < low) {
            low = value;
        }
        if unlikely(value > high) {
            high = value;
        }
    }
    return (low, high);
}

const fn corners(size: i32) [i32; 2] {
    return [0, size];
}

@tail_recurse
const fn gcd(a: u64, b: u64) u64 {
    if b == 0 {
        return a;
    }
    return gcd(b, a % b);
}

static_assert(gcd(84, 36) == 12, "tail recursion folds");

const fn shape_area(shape: Shape) i32 {
    return switch shape {
        Dot => 0,
        Circle(radius) => radius * radius * 3,
        Rect { width: width, height: height } => width * height,
    };
}

const fn classify(value: i32) i32 {
    return switch value {
        0 => 0,
        1 | 2 | 3 => 1,
        4..=9 => 2,
        n if n < 0 => -1,
        _ => 3,
    };
}

const fn sign(value: i64) i32 {
    return switch value {
        i64::MIN..=-1 => -1,
        0 => 0,
        1..=i64::MAX => 1,
    };
}

const fn token_value(token: Token) i32 {
    return switch token {
        Number(value) => value,
        End => -1,
        Skip => 0,
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

fn apply_dyn(function: &dyn fn(i32) i32, value: i32) i32 {
    return function(value);
}

fn make_adder(step: i32) Box<dyn fn(i32) i32> {
    return |value: i32| value + step;
}

const fn checked(value: i32) Result<i32, i32> {
    if value < 0 {
        return Result::<i32, i32>::Err(value);
    }
    return Result::<i32, i32>::Ok(value + 1);
}

const fn checked_twice(value: i32) Result<i32, i32> {
    let next = checked(value)?;
    return Result::<i32, i32>::Ok(next * 2);
}

const fn sum_slice(values: []i32) i32 {
    let mut total = 0;
    for i in 0..values.len() {
        total += *values.get(i);
    }
    return total;
}

fn sum_ints(count: i32, ...) i32 {
    let ap: va_list;
    va_start(ap, count);
    let mut total = 0;
    for _ in 0..count {
        total += unsafe va_arg(ap, i32);
    }
    va_end(ap);
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

fn pattern_forms() i32 {
    let pairs: [(i32, bool); 3] = [(1, true), (2, false), (3, true)];
    let mut total = 0;
    for (value, keep) in pairs {
        if keep {
            total += value;
        }
    }

    if let Some(inner) = Option::<i32>::Some(5) {
        total += inner;
    }

    let mut stack = Vector::<(i32, i32)>::new();
    stack.push((1, 2));
    stack.push((3, 4));
    while let Some((left, right)) = stack.pop() {
        total += left * right;
    }

    // A write to a `for mut` binding changes the next iteration.
    for mut step in 0..10 {
        if step == 2 {
            step = 8;
        }
        total += 1;
    }
    return total;
}

unsafe const fn raw_read_twice(pointer: *const i32) i32 {
    return *pointer + pointer[0];
}

const fn pointer_and_defer() i32 {
    let pointer = (unsafe malloc(sizeof(i32))) as *mut i32;
    defer unsafe free(pointer);
    unsafe *pointer = 21;
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

fn standard_library() {
    let mut versions = Map::<Version, i32>::new();
    versions.insert(Version { major: 1, minor: 2 }, 12);
    versions.insert(Version { major: 2, minor: 0 }, 20);
    let found = switch versions.get(&Version { major: 2, minor: 0 }) {
        Some(value) => *value,
        None => 0,
    };
    assert_eq(found, 20);

    let mut units = Vector::<u16>::new();
    assert(utf16::encode("h\u{e9}\u{1f600}", &mut units).is_ok());
    let mut decoded = String::new();
    assert(utf16::decode(units[0..units.len()], &mut decoded).is_ok());
    assert_eq(units.len(), 4usize);
    assert(decoded.as_str() == "h\u{e9}\u{1f600}");

    let mut sink = String::new();
    assert_eq(sink.write(b"io").unwrap(), 2usize);
    assert(sink.as_str() == "io");

    assert_eq(time::Duration::from_millis(3).as_nanos(), 3000000u64);

    let lanes: f32x4 = [1.0, 2.0, 3.0, 4.0];
    let scaled = lanes * f32x4::splat(2.0);
    let ints = i32x4::from_array([1, 2, 3, 4]);
    assert_eq(simd::reduce_add_ordered(scaled), 20.0f32);
    assert_eq(simd::reduce_add(ints + ints), 20);
}

fn concurrency() i64 {
    let values: [i64; 6] = [1, 2, 3, 4, 5, 6];
    let reduced = parallel::reduce(
        values,
        fn() i64 {
            return 0;
        },
        fn(total: i64, value: &i64) i64 {
            return total + *value;
        },
        fn(left: i64, right: i64) i64 {
            return left + right;
        },
    );

    // A send needs a live receiver: take it before the producers start.
    let results = channel::Channel::<i64>::bounded(4);
    let receiver = results.receiver();
    for worker in 0..4 {
        let sender = results.sender();
        launch || {
            let _ = sender.send(worker as i64 * 10);
        };
    }
    let mut received: i64 = 0;
    for _ in 0..4 {
        received += receiver.recv().unwrap();
    }
    runtime::shutdown();
    return reduced + received;
}

@inline
const fn attributed(value: i32) i32 {
    return value;
}

fn main(args: Vector<str>) i32 {
    let _: Marker = Marker {};
    let pair: Pair<Score, i32> = make_pair(identity(20), 7);
    let (quotient, remainder) = divmod(5, pair.first + pair.second);
    assert_eq(quotient, 5);
    assert_eq(remainder, 2);
    let twin: Twin<u8> = Pair { first: 1, second: 2 };
    assert_eq(twin.first + twin.second, 3u8);

    let mut point = Point { x: 3, y: 4 };
    point = point.moved(1, 1);
    point += Point { x: 1, y: 1 };
    assert_eq(point.area(), 30);
    assert_eq(*point, 5);
    assert_eq(dynamic_area(&point), 60);
    assert_eq(*greater(&point.x, &point.y), 6);
    let solid: &dyn Solid = &point;
    let flat: &dyn Area = solid;
    assert_eq(solid.volume(2) + flat.area(), 90);
    let flipped = -point;
    let tripled = 3 * point;
    assert_eq(flipped.x + tripled.y, 13);
    let partial = Point { x: 7 };
    let blank = unsafe zeroed::<Point>();
    assert_eq(partial.y + blank.x + blank.y, 0);

    let mut counter = Counter::new(1);
    counter.bump();
    assert_eq(counter.bump(), Counter::START + 2);

    assert_eq(shape_area(Shape::Circle(3)), 27);
    assert_eq(shape_area(Shape::Rect { width: 6, height: 7 }), ANSWER);
    assert_eq(shape_area(Shape::Dot), 0);
    assert_eq(classify(-3), -1);
    assert_eq(classify(8), 2);
    assert_eq(sign(i64::MIN) + sign(0) + sign(7), 0);
    assert_eq(Level::Low as i32 + Level::Mid as i32 + Level::High as i32, 13);
    assert_eq(token_value(Token::Number(4)) + token_value(Token::End) + token_value(Token::Skip), 3);

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
    assert_eq(apply_dyn(&captured, 1), 11);
    let add_two = make_adder(2);
    assert_eq(add_two(40), ANSWER);
    let mut tasks = Vector::<Box<dyn fn() i32>>::new();
    tasks.push(|| offset);
    tasks.push(|| ANSWER);
    assert_eq(tasks.at(0)() + 1, 11);
    let splitter: fn(i32, i32) (i32, i32) = divmod;
    let (tens, ones) = splitter(10, ANSWER);
    assert_eq(tens * 10 + ones, ANSWER);
    let pick: for<'a> fn(&'a i32, &'a i32) &'a i32 = greater;
    assert_eq(*pick(&tens, &ones), 4);
    assert_eq(corners(5)[1], 5);

    let array: [i32; 5] = [1, 2, 3, 4, 5];
    let slice: []i32 = array[1..4];
    assert_eq(sum_slice(slice), 9);
    assert_eq(sum_inline::<10>(), 45);
    assert_eq(field_count::<Point>(), 2);
    assert_eq(lane_bytes::<i64>(), 8usize);
    assert_eq(loop_forms(), 19);
    assert_eq(pattern_forms(), 27);
    let (low, high) = bounds(array);
    assert_eq(low + high, 6);
    assert_eq(sum3(point, -point, Point { x: 1, y: 2 }).y, 2);
    assert_eq(21.bits() + 1i64.bits(), 96usize);
    assert_eq(gcd(84, 36), 12u64);
    assert_eq(sum_ints(3, 10, 20, 12), ANSWER);

    let result = checked_twice(20);
    assert_eq(
        switch result {
            Ok(value) => value,
            Err(error) => error,
        },
        ANSWER,
    );
    let percent: Result<Percent, i32> = 42.try_into();
    assert_eq(percent.unwrap().value, 42u8);
    assert(Percent::try_from(101).is_err());

    let bits = NumberBits { integer: 0x3f800000u32 };
    assert_eq(bits.real, 1.0f32);
    assert_eq(pointer_and_defer(), 44);
    assert_eq(ownership_and_containers(), 13);

    let color = Rgb(10, 20, 12);
    assert_eq(color.0 + color.1 + color.2, ANSWER);
    let wrapped = Boxed::<i32>(ANSWER);
    assert_eq(wrapped.0, ANSWER);
    let mut boxed = Box::<i32>::new(41);
    *boxed += 1;
    assert_eq(*boxed, ANSWER);
    let mut slot = 7;
    assert_eq(replace(&mut slot, 9), 7);
    let late: i32;
    late = slot;
    assert_eq(late, 9);

    let first = Version { major: 1, minor: 2 };
    let second = first.clone();
    assert(first == second);
    assert(first < Version { major: 1, minor: 3 });
    assert(format("{}", first).as_str() == "Version { major: 1, minor: 2 }");

    let samples = Samples { values: Vector::<i32>::from([1, 2, 3, 4]) };
    assert_eq(samples[2] + sum_slice(samples[1..3]), 8);

    assert_eq(sum_by_value(slice), 9);

    let bytes = b"AB";
    assert_eq(bytes[0] as i32 + bytes[1] as i32, 131);
    let letter: char = 'A';
    assert_eq(letter as u8 + 1, b'B');

    let raw = M"(say "hi" (twice))";
    assert(raw == "say \"hi\" (twice)");
    let n = 7;
    let message = M{}"(n={n}, next={n + 1})";
    assert(message.as_str() == "n=7, next=8");
    let owner = String::from_str("borrowed");
    let label = Label { text: owner.as_str() };
    assert_eq(label.text.len(), 8);
    assert_eq(0x1.8p3, 12.0);

    assert_eq(u8::MAX.wrapping_add(1), 0u8);
    assert(i32::MAX.checked_add(1).is_none());
    assert_eq(clamp_add(LIMIT, 1), i32::MAX);
    let (wrapped_sum, overflowed) = 250u8.overflowing_add(10);
    assert(overflowed && wrapped_sum == 4);
    assert_eq(abs(-ANSWER), ANSWER);

    let mut sparse: [i32; 8] = [[2] = 40, [7] = 2];
    sparse[0] = args.len() as i32;
    assert_eq(sparse[2] + sparse[7], ANSWER);

    assert(POINTER_WIDTH as usize == sizeof(usize) * 8);
    let separator = switch PLATFORM {
        Windows => '\\',
        _ => '/',
    };
    assert_eq(separator, path_separator());
    assert(!TEST_BUILD);

    standard_library();
    assert_eq(concurrency(), 81);

    unsafe {
        VISITS += 1;
        assert_eq(VISITS, 1);
        THREAD_CALLS += 1;
        assert_eq(THREAD_CALLS, 1u32);
    }
    return attributed(0);
}
