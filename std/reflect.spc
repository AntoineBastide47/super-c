// Reflection-derived operations: each is written ONCE over `fields(v)` / `variants(v)` and
// monomorphizes per concrete type into exactly the code a hand-written version would be -- no
// runtime type walk, no erasure. The per-field bounds (Format, Hash) are proven per field at each
// use site; a field that lacks one names itself in the diagnostic. `Format` and `Hash` use the
// `reflect_any_*` pair as their DEFAULT bodies, so a bare `extend T as Format {}` derives them.

/// `"Name { a: 1, b: x }"` for any struct, tuple, or union whose fields all satisfy `Format`.
pub fn reflect_string<T>(v: &T) String {
    let ti = type_info::<T>();
    let mut s = String::from_str(ti.name);
    s.push_str(" { ");
    inline for f in fields(v) {
        if f.index > 0 {
            s.push_str(", ");
        }
        s.push_str(f.name);
        s.push_str(": ");
        reflect_fmt_field(&mut s, &f.value);
    }
    s.push_str(" }");
    return s;
}

fn reflect_fmt_field<V: Format>(out: &mut String, x: &V) {
    let fs = x.fmt();
    out.push_str(fs.as_str());
    fs.free();
}

/// FNV-1a over every field's own `Hash`, in declaration order. Two values of one type hash equal
/// when their fields do; the field ORDER is part of the hash, the field names are not.
pub fn reflect_hash<T>(v: &T) u64 {
    let mut h: u64 = 1469598103934665603u64;
    inline for f in fields(v) {
        h = h ^ reflect_hash_field(&f.value);
        h = h * 1099511628211u64;
    }
    return h;
}

fn reflect_hash_field<V: Hash>(x: &V) u64 {
    return x.hash();
}

/// `"Dot"` / `"Line(42)"` / `"Pair(1, 2)"` for any enum: the ACTIVE variant's name, then every
/// payload value it carries, in order, each through its own `Format`.
pub fn reflect_variant_string<T>(e: &T) String {
    let mut s = String::new();
    inline for v in variants(e) {
        if v.is_active {
            s.push_str(v.name);
            if v.payload > 0 {
                s.push_str("(");
                inline for p in payloads(v) {
                    if p.index > 0 {
                        s.push_str(", ");
                    }
                    reflect_fmt_field(&mut s, &p.value);
                }
                s.push_str(")");
            }
        }
    }
    return s;
}

/// FNV-1a over the ACTIVE variant's tag, then each of its payload values' own `Hash`, in order --
/// so payload-less variants hash by tag alone, and equal values hash equally.
pub fn reflect_variant_hash<T>(e: &T) u64 {
    let mut h: u64 = 1469598103934665603u64;
    inline for v in variants(e) {
        if v.is_active {
            h = h ^ v.tag as u64;
            h = h * 1099511628211u64;
            inline for p in payloads(v) {
                h = h ^ reflect_hash_field(&p.value);
                h = h * 1099511628211u64;
            }
        }
    }
    return h;
}

/// Struct-or-enum dispatch for the interface defaults: an enum goes through its variants, anything
/// else through its fields. The untaken branch's reflection loop has zero copies, so it costs nothing.
pub fn reflect_any_string<T>(v: &T) String {
    if type_info::<T>().kind == TypeTag::Enum {
        return reflect_variant_string(v);
    }
    return reflect_string(v);
}

pub fn reflect_any_hash<T>(v: &T) u64 {
    if type_info::<T>().kind == TypeTag::Enum {
        return reflect_variant_hash(v);
    }
    return reflect_hash(v);
}
