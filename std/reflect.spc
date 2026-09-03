// Reflection-derived operations, and the reference for the COMPILE-TIME REFLECTION intrinsics they
// are written over. The intrinsics are compiler constructs, not functions: no declaration exists
// anywhere, so this header is their documentation.
//
//   type_info::<T>()   A non-owning `TypeInfo` descriptor of T (name, kind, size, align, fields,
//                      variants, meta, methods; see std/core.spc). Folds at compile time; a runtime
//                      use reads static data. Cannot describe an opaque FFI type. `methods` lists
//                      every `extend` function declared for a decl-backed or builtin type
//                      (enumeration only: a descriptor cannot invoke).
//   zeroed::<T>()      An all-zero-bytes T. `unsafe`: zero bytes are not a valid value of every
//                      type. It is the seed the reflection constructors fill field by field:
//                      releasing an all-zero value is a no-op for every owning std type.
//   fields(&v)         The field binder: `inline for f in fields(&v) { .. }` typechecks the body
//                      ONCE against a symbolic per-field type and the emitter unrolls one copy per
//                      field, each with the field's concrete type: no runtime walk, no erasure.
//                      Subjects must be references; `fields(&mut v)` makes each `f.value` a mutable
//                      place. Iterates a struct, tuple, or union (or a type parameter standing for
//                      one; on an enum the loop has zero copies).
//   variants(&e)       The variant binder, over an enum's declaration order. `v.is_active` is the
//                      only member that reads the subject; everything else is a per-copy constant.
//   payloads(v)        The payload sub-binder of the ACTIVE variants loop: it takes the variants
//                      BINDER itself (`inline for p in payloads(v)`), never a value, and projects
//                      through the outer loop's subjects.
//
// Every binder form exists only as the iterable of an `inline for` (a `parallel for` or a stored
// value is rejected), and a closure inside the body may not capture the binder: its type differs
// per copy. Binder members:
//
//   f.name / f.index               `str<'static>` / `usize` copy constants ("_0", "_1", .. for
//                                  tuples).
//   f.value                        THE field itself, at its own type: pass `&f.value` (or
//                                  `&mut f.value` through a `&mut` subject) to a generic callee and
//                                  it monomorphizes per field. The bound that callee places on its
//                                  parameter is proven PER FIELD, and a failing field names itself
//                                  in the diagnostic.
//   f.offset / f.size / f.kind     C-layout byte offset, sizeof, and the `TypeTag` of the field's
//                                  type.
//   v.tag / v.payload / v.name     The variant's discriminant (the enum CONSTANT's value for a
//                                  payload-less enum), its payload count, and its name.
//   v.is_active                    Whether the subject currently holds this variant.
//   p.value / p.index / p.name     One payload of the active variant, like a field.
//
// PAIRED subjects: `fields(&a, &b)` / `variants(&a, &b)` bind a second subject of the SAME type.
// `f.other` (fields, payloads) is the second subject's same field: always read-only; and
// `v.other_active` tests the second subject's tag. This is what field-wise equality, ordering, and
// clone-into are built from; there is no way to reach a second value's field without it.
//
// METADATA: `@reflect(key, key = 100, key = "text", ..)` on a struct/enum/field/variant/method
// attaches `MetaInfo` entries the descriptor carries (`ti.meta`, `ti.fields.get(i).meta`,
// `VariantInfo.meta`, `MethodInfo.meta`; lookups via `.meta("key")` / `.has_meta("key")`). Inside a
// binder body, `f.has_meta("k")`, `f.meta_bool("k")`, `f.meta_int("k")`, and `f.meta_str("k")` are
// PER-COPY CONSTANTS (a missing key reads false / 0 / ""; the key must be a string literal), and an
// `if` over them (including a `meta_str` compare against a string literal) folds at emission,
// so the untagged copies' bodies are never emitted. A `@reflect` tag on a CONCRETE type
// additionally EXPORTS its descriptor as the C global `sc_typeinfo_<name>` and registers it at
// startup: an external tool reads `__sc_reflect_types` (super_rt.h) and walks the same statics the
// program uses. String values keep their RAW source bytes (escape sequences are not processed).
//
// All of it works under the compile-time evaluator (`const fn`, static_assert, which also runs
// INSIDE fn bodies, per instantiation for a generic fn), including writes through `&mut f.value`,
// `zeroed`, payload-less enums (tags read their declared constants), `payloads` projection, and
// `format`. `if` conditions on per-copy constants (`v.payload == 1`, `f.index != 0`,
// `f.has_meta("k")`) fold at emission, so the untaken copy's body is never emitted at all.
//
// The derive helpers below are each written ONCE over these binders and monomorphize per concrete
// type into exactly the code a hand-written version would be. `Format`/`Hash`/`Eq`/`Ord`/`Clone`/
// `Default` use them as DEFAULT bodies, so a bare `extend T as I {}`, or `@derive(I, ..)` on the
// declaration, which expands to exactly those extends: derives the implementation; defining the
// method overrides it.

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
    out.push_str(x.fmt().as_str());
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

/// FNV-1a over the ACTIVE variant's tag, then each of its payload values' own `Hash`, in order:
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

/// The derived hash of `v`: field-wise for structs and tuples, variant-wise for enums.
pub fn reflect_any_hash<T>(v: &T) u64 {
    if type_info::<T>().kind == TypeTag::Enum {
        return reflect_variant_hash(v);
    }
    return reflect_hash(v);
}

/// Field-by-field equality through each field's own `Eq`, in declaration order: `fields(a, b)`
/// pairs every field with the other subject's same field.
pub fn reflect_eq<T>(a: &T, b: &T) bool {
    inline for f in fields(a, b) {
        if !reflect_eq_field(&f.value, &f.other) {
            return false;
        }
    }
    return true;
}

fn reflect_eq_field<V: Eq>(x: &V, y: &V) bool {
    return x.eq(y);
}

/// Enum equality: the same ACTIVE variant, then every payload pair equal through its own `Eq`.
pub fn reflect_variant_eq<T>(a: &T, b: &T) bool {
    let mut r = true;
    inline for v in variants(a, b) {
        if v.is_active {
            if !v.other_active {
                r = false;
            } else {
                inline for p in payloads(v) {
                    if !reflect_eq_field(&p.value, &p.other) {
                        r = false;
                    }
                }
            }
        }
    }
    return r;
}

/// Lexicographic field ordering through each field's own `Ord`: the first unequal field decides.
pub fn reflect_cmp<T>(a: &T, b: &T) i32 {
    inline for f in fields(a, b) {
        let c = reflect_cmp_field(&f.value, &f.other);
        if c != 0 {
            return c;
        }
    }
    return 0;
}

fn reflect_cmp_field<V: Ord>(x: &V, y: &V) i32 {
    return x.cmp(y);
}

/// Enum ordering: by discriminant first, then the shared ACTIVE variant's payloads lexicographically.
pub fn reflect_variant_cmp<T>(a: &T, b: &T) i32 {
    let mut ta: i32 = 0;
    let mut tb: i32 = 0;
    inline for v in variants(a) {
        if v.is_active {
            ta = v.tag;
        }
    }
    inline for v in variants(b) {
        if v.is_active {
            tb = v.tag;
        }
    }
    if ta != tb {
        if ta < tb {
            return -1;
        }
        return 1;
    }
    let mut c: i32 = 0;
    inline for v in variants(a, b) {
        if v.is_active && v.other_active {
            inline for p in payloads(v) {
                if c == 0 {
                    c = reflect_cmp_field(&p.value, &p.other);
                }
            }
        }
    }
    return c;
}

/// The derived equality of `a` and `b`. Panics: T is a union.
pub fn reflect_any_eq<T>(a: &T, b: &T) bool {
    if type_info::<T>().kind == TypeTag::Union {
        panic("a derived 'eq' covers structs, tuples, and enums; write it by hand for a union");
    }
    if type_info::<T>().kind == TypeTag::Enum {
        return reflect_variant_eq(a, b);
    }
    return reflect_eq(a, b);
}

/// The derived ordering of `a` and `b` (negative, zero, positive). Panics: T is a union.
pub fn reflect_any_cmp<T>(a: &T, b: &T) i32 {
    if type_info::<T>().kind == TypeTag::Union {
        panic("a derived 'cmp' covers structs, tuples, and enums; write it by hand for a union");
    }
    if type_info::<T>().kind == TypeTag::Enum {
        return reflect_variant_cmp(a, b);
    }
    return reflect_cmp(a, b);
}

/// A fresh deep copy built field by field: a `zeroed` T seeded, then every field cloned in from the
/// source through its own `Clone`. Overwriting the zeroed placeholder is safe: releasing an
/// all-zero value is a no-op for every owning std type. Enums need the active variant CONSTRUCTED,
/// and a union's overlapping fields cannot be cloned independently, so both refuse loudly.
pub fn reflect_clone<T>(v: &T) T {
    if type_info::<T>().kind == TypeTag::Enum || type_info::<T>().kind == TypeTag::Union {
        panic("a derived 'clone' covers structs and tuples; write it by hand for an enum or union");
    }
    let mut out = unsafe zeroed::<T>();
    inline for f in fields(&mut out, v) {
        reflect_clone_field(&mut f.value, &f.other);
    }
    return out;
}

fn reflect_clone_field<V: Clone>(dst: &mut V, src: &V) {
    *dst = src.clone();
}
