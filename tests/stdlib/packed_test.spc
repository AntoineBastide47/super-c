// std::collections::packed: `PackedEnums`, enum values stored at the size of their own variant. Checked: the
// bytes each variant takes (`v.size`), the values read back in order through `for_each`, `iter` and `drain`,
// owning payloads moved and freed exactly once, growth over many values, and the enums that gain nothing
// (a niche enum, an enum without payloads).
import std::collections::packed as *;

enum Shape {
    Dot,
    Circle(f64),
    Rect(f64, f64, f64, f64),
}

enum Msg {
    Ping,
    Text(String),
    Blob { data: Vector<u8>, tag: u32 },
}

enum Light {
    Red,
    Green,
}

const fn area(s: &Shape) f64 {
    return switch *s {
        Dot => 0.0,
        Circle(r) => 3.0 * r * r,
        Rect(x, y, w, h) => w * h + x * 0.0 + y * 0.0,
    };
}

@test
fn variant_sizes() {
    // The tag byte, then the variant's own payload at its alignment.
    let d = Shape::Dot;
    let c = Shape::Circle(1.0);
    let r = Shape::Rect(0.0, 0.0, 1.0, 1.0);
    assert_eq(packed_size(&d), 1);
    assert_eq(packed_size(&c), 16);
    assert_eq(packed_size(&r), 40);
    assert_eq(sizeof(Shape), 40);
    // A niche enum keeps its discriminant in its payload, and an enum without payloads is its tag.
    let x = 3;
    let o: Option<&i32> = Option::Some(&x);
    assert_eq(packed_size(&o), sizeof(usize));
    let g = Light::Green;
    assert_eq(packed_size(&g), sizeof(Light));
}

@test
fn values_read_back_in_order() {
    let mut p = PackedEnums::<Shape>::new();
    assert(p.is_empty(), "a new sequence is empty");
    p.push(Shape::Dot);
    p.push(Shape::Circle(2.0));
    p.push(Shape::Rect(0.0, 0.0, 3.0, 4.0));
    p.push(Shape::Dot);
    assert_eq(p.len(), 4);
    assert_eq(p.byte_len(), 1 + 16 + 40 + 1);
    let mut total: f64 = 0.0;
    let mut kinds = String::new();
    p.for_each(
        |s: &Shape| {
            total += area(s);
            kinds.push_str(
                switch *s {
                    Dot => "d",
                    Circle(_) => "c",
                    Rect(_, _, _, _) => "r",
                },
            );
        },
    );
    assert(total == 24.0, "for_each lends every value");
    assert(kinds.as_str() == "dcrd", "in push order");
    let mut n = 0;
    let mut sum: f64 = 0.0;
    for s in p.iter() {
        sum += area(&s);
        n += 1;
    }
    assert_eq(n, 4);
    assert(sum == 24.0, "iter copies every value out");
}

@test
fn owning_payloads_move_once() {
    let mut p = PackedEnums::<Msg>::new();
    for i in 0..100 {
        if i % 3 == 0 {
            p.push(Msg::Ping);
        } else if i % 3 == 1 {
            p.push(Msg::Text(format("a string longer than the inline capacity, number {}", i)));
        } else {
            let mut d = Vector::<u8>::new();
            d.push(i as u8);
            p.push(Msg::Blob { data: d, tag: i as u32 });
        }
    }
    assert_eq(p.len(), 100);
    assert(p.byte_len() < 100 * sizeof(Msg), "a Ping takes its tag alone");
    let mut chars: usize = 0;
    p.for_each(
        |m: &Msg| {
            if let Text(s) = m {
                chars += s.len();
            }
        },
    );
    assert(chars > 33 * 40, "for_each reads the owning payloads in place");
    let mut tags: u32 = 0;
    let mut texts = 0;
    p.drain(
        |m: Msg| {
            switch m {
                Blob { data: data, tag: tag } => {
                    tags += tag + data[0] as u32;
                },
                Text(_) => {
                    texts += 1;
                },
                Ping => {},
            };
        },
    );
    assert_eq(p.len(), 0);
    assert_eq(p.byte_len(), 0);
    assert_eq(texts, 33);
    let mut expect: u32 = 0;
    for i in 0..100 {
        if i % 3 == 2 {
            expect += 2 * i as u32;
        }
    }
    assert_eq(tags, expect);
    // The owning values left at the end are freed with the sequence.
    p.push(Msg::Text(String::from_str("a second string longer than the inline capacity")));
    p.push(Msg::Ping);
}

@test
fn growth_keeps_every_value() {
    let mut p = PackedEnums::<Shape>::new();
    for i in 0..1000 {
        if i % 2 == 0 {
            p.push(Shape::Circle(i as f64));
        } else {
            p.push(Shape::Dot);
        }
    }
    assert_eq(p.byte_len(), 500 * 16 + 500);
    let mut k = 0;
    let mut ok = true;
    for s in p.iter() {
        ok = ok && (switch s {
            Circle(r) => k % 2 == 0 && r == k as f64,
            Dot => k % 2 == 1,
            Rect(_, _, _, _) => false,
        });
        k += 1;
    }
    assert(ok && k == 1000, "every value survives the growths");
    p.clear();
    assert(p.is_empty(), "clear empties it");
    p.push(Shape::Dot);
    assert_eq(p.byte_len(), 1);
}
