# C FFI, Testing, Concurrency and std Highlights

## C FFI

```superc
extern "C" {
    type FILE;
    fn fopen(path: *const char, mode: *const char) *mut FILE;
    fn fclose(file: *mut FILE) i32;
}

extern "C" "native.h" {     // discovers native.c beside the .spc file
    fn native_mix(a: i32, b: i32) i32;
}
```

An opaque `type X;` renders as its bare C name, so it must name a type some included
header actually defines (`FILE` works because stdio.h is auto-included; an invented name
fails when the `--emit-c` tree compiles). A `struct`, `union` or `enum` in the block is a header
type: the C type (`struct stat`, `enum color`, or a typedef name through `@import`), with the fields
the declaration lists and the header's layout, which the build checks field by field; the block
must name that header. It has no drop glue (see `super-c-ffi`, Header Types). No type of an extern
block implements `Free`: wrap it in a struct that does. C code comes in as a library (`@link`).
`@link("m")` declares a library. Variadics work in both directions (`...`, `va_list`,
`va_start`, `va_arg`, `va_end`); `va_arg` needs `unsafe` (see `super-c-ffi`).

## Testing

```superc
@test_init
fn setup() Fx {
    let mut v = Vector::<i32>::new();
    v.push(1); v.push(2);
    return Fx { v: v };
}

@test
fn drains(fx: &mut Fx) {
    let mut s = 0;
    while let Some(x) = fx.v.pop() { s += x; }
    assert_eq(s, 3);
}

@test(should_panic)
fn rejects_bad() { panic("boom"); }

@test(should_panic, timeout = 5) // a list: should_panic and timeout = N seconds, each at most once
fn rejects_quickly() { panic("boom"); }
```

`assert(cond)`, `assert_eq(a, b)`, `assert_ne(a, b)` are compiler builtins that print
source text, values, and file:line on failure.

## Concurrency

`launch || { .. };` spawns a stackful coroutine on a work-stealing pool. `Arc<T>` for
shared ownership across threads. `Mutex<T>`, `RwLock<T>`, `Channel<T>`, atomics, and
`parallel::range`/`each`/`reduce` for data parallelism. `Send`/`Sync` marker interfaces
enforced at spawn boundaries.

## Standard Library Highlights

| Type | Description |
|------|-------------|
| `String` | Owned growable UTF-8 string |
| `str` | Borrowed string view (non-NUL-terminated except a literal, whose C spelling ends in a NUL; print via `%.*s`, or `.to_string()` then `String::cstr()`) |
| `Vector<T>` | Growable array |
| `Box<T>` | Heap-allocated single value |
| `Option<T>` | `Some(x)` / `None`, bare or qualified (`Option::Some(x)`), in values and patterns |
| `Result<T, E>` | `Ok(T)` or `Err(E)` |
| `Map<K, V, A = Global, S = DefaultHash>` | Hash map; `S: BuildHasher` turns a key into its hash (`DefaultHash` is unkeyed and deterministic, `std::hash::keyed::KeyedHash` keyed); `entry(k)` (`or_insert`, `or_default`, `and_modify`, `Occupied`/`Vacant`), `iter()`, `iter_mut()`, `keys()`, `values()`, `drain()`, `retain`; the cursors borrow the map, double-ended with an exact `size_hint` |
| `Set<T, A = Global, S = DefaultHash>` | Hash set; `iter()` borrows it; `set_union`, `intersection`, `difference`, `symmetric_difference` iterate both sets lazily |
| `Array<T, N>` | Fixed-size const-generic array, a type distinct from `[T; N]`. `new()` needs `T: Default`; for raw pointers write `Array::<*mut T, N> {}` |
| `Slice<T>` / `SliceMut<T>` | Fat-pointer views, and the one implementation of the sequence algorithms `Vector`, `Array` and `StaticVector` reach through `as_slice()`/`as_mut_slice()`: `sort` (unstable), `sort_stable` (a scratch block of `len` elements; `_in(alloc)` names its allocator), `sort_stable_in_place` (no heap memory, a 4 KiB stack buffer; about 1.25x the time of `sort_stable` on large inputs), `select_nth_unstable`, the heap operations, `binary_search`, `partition_point`, `partition`, `partition_dedup`, `rotate_left`; comparators return a negative, zero or positive `i32`. A `SliceMut` method takes the view by value: it is reborrowed for the call and conflicts with a live element borrow |
| `(A, B)` ... 8 elements | Tuples (`Tuple2`..`Tuple8`, built by the compiler; access: `.0`, `.1`); `Eq`, `Ord` (lexicographic), `Hash`, `Clone`, `Default` and `Format` when every element has them |
| `Iterator<T>` / `DoubleEndedIterator<T>` | `next`, `size_hint` (bounds; equal bounds are an exact size), `next_back`; the adapters of the prelude `iter` module (`map`, `filter`, `take`, `skip`, `chain`, `rev`, `zip`, `enumerate`, `flat_map`, `step_by`, `peekable`, ..) and consumers (`fold`, `any`, `all`, `find`, `min`, `max`, `collect`, `try_collect`, ..) are free functions; a `Range<T>` of a builtin integer is a double-ended iterator |
| `Hash` / `Hasher` / `BuildHasher` | One method, `hash_into(h)`: feeds the value into a `Hasher` (derived: field by field, consistent only with the derived `Eq`; a type that writes its own `eq` must write `hash_into`, else a static assertion stops the build). Conforming is explicit (`@derive(Hash)`): interior-mutable types (`Cell`, `RefCell`, atomics, locks) are not `Hash`. `hash(&v)` is the prelude's 64-bit hash (`DefaultHasher`), the one `DefaultHash` maps use |
| `Arc<T>` / `arc::Weak<T>` | Atomic reference counting; `downgrade`, `Weak::upgrade`, `get_mut`, `try_unwrap` |
| `Mutex<T>` / `RwLock<T>` | Synchronization |
| `Channel<T>` | Bounded/unbounded channels |
| `Unit` | The zero-sized success value of a status-only operation (`Result<Unit, IoError>`) |
| `IoError` | `kind: IoErrorKind` (the stable category), `code` (the native error number, 0 when none), `op: IoOp` (the failed operation) |
| `Reader` / `Writer` | `read(buf) Result<usize, IoError>`, `write(bytes) Result<usize, IoError>`: `Ok(n)` once a byte moved, a fault after a partial transfer on the next call, `Ok(0)` from `read` only at the end or for an empty buffer |
| `TryFrom<T>` / `TryInto<T>` | Fallible conversion with an associated `type Error`; `x.try_into()` returns `Result<U, U::Error>` |
| `std::time`, `std::net` | Durations, deadlines and task-aware `sleep`; task-aware TCP and UDP |
| `std::text::utf16` | `encode`, `encode_into`, `decode` between UTF-8 and UTF-16 code units, with the offset of ill-formed input |
| `std::collections` | `deque::Deque`, `deque::RingBuffer`, `heap::BinaryHeap` with `heap::Reverse`, `btree::BTreeMap` and `BTreeSet`, `hive::Hive` (stable addresses through `HiveHandle`), `bits::BitSet`, `BitVec` and `BitField`, `mdspan::MdSpan` and `MdSpanMut`, `packed::PackedEnums` (enum values stored at the size of their own variant, read in order); each module's header states its complexity, invalidation and allocator use |
| `std::alloc` | `Arena`, `Pool` and `NoAlloc` (C++ `<memory_resource>`): an owning resource and a `Copy` handle that implements `Allocator`; `Stack`, a zero-sized allocator like `Global` over a region of the running task, neither `Send` nor `Sync` (`Vector::<T, Stack>::new()`); `std::parallel::pool::SyncPool` is the shared pool |
| `std::mem` | `layout::Layout`, `ptr` (unaligned and raw copies, `bit_cast`), `endian` (byte-order reads and writes), `cell::Cell`, `RefCell`, `OnceCell`, `rc::Rc` and `rc::Weak`, `volatile` (volatile access and zeroization) |
| `std::hash::keyed` | `KeyedHash` (SipHash-1-3 under a 128-bit key from `with_key` or the process's entropy, `random`), `SipHasher13`, `SipHasher24`: the builder for maps whose keys come from untrusted input |
| `std::platform::*` | std's internal operating-system layer (files, paths, clocks, entropy, memory, threads, processes, environment, signals, sockets, libraries): unstable, for std and projects with `std_internals = true` |

Every std package declares its tier and target support in `std/packages.toml` (0 prelude; 1 portable, no
operating system; 2 allocating; 3 operating system, I/O and concurrency; 4 encodings and protocols; 5 tooling).
A module imports no module of a higher tier and joins no import cycle across packages; platform FFI stays in
`std::platform` and the substrate modules the file exempts (`ci/gate.sh` checks it with `tools/std_packages`).
