// Reflection-derived operations: each is written ONCE over `fields(v)` and monomorphizes per
// concrete type into exactly the code a hand-written version would be -- no runtime type walk, no
// erasure. The per-field bounds (Format, Hash) are proven per field at each use site; a field that
// lacks one names itself in the diagnostic.

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
