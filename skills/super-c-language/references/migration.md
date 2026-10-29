# Migration Names

The Super-C name of each common contract, by the names Go, Rust, Odin and C++ give it. Super-C has one
name per operation and no alias for an upstream name.

## Visibility and modules

| Super-C | Go | Rust | Odin | C++ |
| --- | --- | --- | --- | --- |
| item without a modifier (its file) | none | private item (module) | `@(private = "file")` | `static`, anonymous namespace |
| `pub(module)` (its directory and subdirectories) | none | `pub(super)`, `pub(in path)` | none | none |
| `pub(package)` (its import root) | lowercase name (package) | `pub(crate)` | `@(private)` (package) | none |
| `pub` | uppercase name | `pub` | default | `extern`, header |
| field without a modifier (its file) | none | private field (module) | none | none |
| `import a::b;` of a directory without `b.spc` | `import "a/b"` | `mod b;` with `b/mod.rs` | `import "a/b"` | none |
| `import m as *;` (re-export: `x::name` reaches `m`'s names) | dot import | `pub use m::*;` | none | `using namespace` |
| `std_internals = true` in `build.toml` | `internal/` | none | none | none |

## Errors and conversion

| Super-C | Go | Rust | Odin | C++ |
| --- | --- | --- | --- | --- |
| `Unit` | `struct{}` | `()` | `struct{}` | `std::monostate` |
| `IoError` (`kind`, `code`, `op`) | `error`, `*os.PathError` | `std::io::Error` | `os.Error` | `std::system_error` |
| `IoErrorKind` | `errors.Is(err, fs.ErrNotExist)` | `std::io::ErrorKind` | `os.General_Error` | `std::errc` |
| `IoOp` | `PathError.Op` | none | none | none |
| `TryFrom` with `type Error`, `x.try_into()` | none | `TryFrom`, `TryInto` | none | none |

## Byte streams

| Super-C | Go | Rust | Odin | C++ |
| --- | --- | --- | --- | --- |
| `Writer::write` returning `Result<usize, IoError>` | `io.Writer.Write` | `std::io::Write::write` | `io.write` | `std::ostream::write` |
| `Reader::read` returning `Result<usize, IoError>` | `io.Reader.Read` | `std::io::Read::read` | `io.read` | `std::istream::read` |
| `Ok(0)` from `read` | `io.EOF` | `Ok(0)` | `.EOF` | `eof()` |

## Time, network and text

| Super-C | Go | Rust | Odin | C++ |
| --- | --- | --- | --- | --- |
| `std::time::Duration` | `time.Duration` | `std::time::Duration` | `time.Duration` | `std::chrono::nanoseconds` |
| `std::time::sleep` (task-aware) | `time.Sleep` | `std::thread::sleep`, `tokio::time::sleep` | `time.sleep` | `std::this_thread::sleep_for` |
| `std::time::deadline_in` | `time.Now().Add` | `Instant::now() + d` | `time.tick_add` | `steady_clock::now() + d` |
| `std::net::TcpListener::bind` | `net.Listen("tcp", ..)` | `TcpListener::bind` | `net.listen_tcp` | none |
| `std::net::TcpStream::connect` | `net.Dial("tcp", ..)` | `TcpStream::connect` | `net.dial_tcp` | none |
| `std::net::UdpSocket::bind` | `net.ListenUDP` | `UdpSocket::bind` | `net.make_bound_udp_socket` | none |
| `std::text::utf16::encode` | `utf16.Encode` | `str::encode_utf16` | `utf16.encode_string` | `std::wstring_convert` |
| `std::text::utf16::decode` | `utf16.Decode` | `String::from_utf16` | `utf16.decode_to_utf8` | `std::wstring_convert` |

## Platform layer (`std::platform`, unstable, `std_internals = true`)

| Super-C | Go | Rust | Odin | C++ |
| --- | --- | --- | --- | --- |
| `fs::open(path, OpenOptions { .. })` | `os.OpenFile` | `OpenOptions::open` | `os.open` | `std::fopen` |
| `fs::read_dir` | `os.ReadDir` | `std::fs::read_dir` | `os.read_dir` | `std::filesystem::directory_iterator` |
| `fs::mkdir_all` | `os.MkdirAll` | `std::fs::create_dir_all` | `os.make_directory_all` | `std::filesystem::create_directories` |
| `fs::remove_all` | `os.RemoveAll` | `std::fs::remove_dir_all` | `os.remove_all` | `std::filesystem::remove_all` |
| `fs::realpath` | `filepath.EvalSymlinks` | `std::fs::canonicalize` | none | `std::filesystem::canonical` |
| `clock::monotonic_ns` | `time.Now` (monotonic reading) | `Instant::now` | `time.tick_now` | `steady_clock::now` |
| `clock::wall_ns` | `time.Now().UnixNano` | `SystemTime::now` | `time.now` | `system_clock::now` |
| `entropy::fill` | `crypto/rand.Read` | none (the `getrandom` crate) | `crypto.rand_bytes` | `std::random_device` |
| `process::spawn(Command::new(argv))` | `exec.Command` | `std::process::Command::spawn` | `os.process_start` | none |
| `env::get` | `os.LookupEnv` | `std::env::var_os` | `os.lookup_env` | `std::getenv` |
| `dylib::open` | `plugin.Open` | none (the `libloading` crate) | `dynlib.load_library` | none |

## Hashing

| Super-C | Go | Rust | Odin | C++ |
| --- | --- | --- | --- | --- |
| `hash(&v)` (64-bit digest through `DefaultHasher`) | `maphash.Comparable` | `BuildHasher::hash_one` | `hash.fnv64a` and kin | `std::hash<T>{}(v)` |
| `Hash::hash_into(h)` (the one `Hash` method) | `hash.Hash.Write` | `Hash::hash(&mut H)` | none | `std::hash<T>` specialization |
| `DefaultHasher` (unkeyed word-wise fold and multiply) | none | none (its `DefaultHasher` is SipHash) | none | none |
| `Hasher` (`write`, `write_u8`, `write_u64`, `finish`) | `hash.Hash64` | `Hasher` | none | none |
| `BuildHasher::hash_one` | none | `BuildHasher::hash_one` | none | none |
| `DefaultHash` (unkeyed, deterministic) | none | `BuildHasherDefault<H>` | none | `std::hash` |
| `std::hash::keyed::KeyedHash` | runtime map seed | `RandomState` | none | none |
| `std::hash::keyed::SipHasher13` / `SipHasher24` | none | `DefaultHasher` / none | none | none |

## Sequences and sorting

The algorithms are methods of `[]T` (`Slice`) and `[]mut T` (`SliceMut`); `Vector`, `Array` and `StaticVector`
reach them through `as_slice()` / `as_mut_slice()` and keep `sort`, `sort_by`, `sort_by_key`, `binary_search`,
`is_sorted`, `dedup` and `reverse` themselves. A comparator returns a negative, zero or positive `i32`.

| Super-C | Go | Rust | Odin | C++ |
| --- | --- | --- | --- | --- |
| `sort`, `sort_by`, `sort_by_key` (unstable) | `slices.Sort`, `slices.SortFunc` | `sort_unstable`, `sort_unstable_by`, `sort_unstable_by_key` | `slice.sort`, `slice.sort_by` | `std::sort` |
| `sort_stable`, `sort_stable_by`, `sort_stable_by_key`, `_in(alloc)` | `slices.SortStableFunc` | `sort`, `sort_by`, `sort_by_key` | `slice.stable_sort` | `std::stable_sort` |
| `sort_stable_in_place`, `_by`, `_by_key` (no heap memory) | `sort.Stable` | none | none | `std::stable_sort` without a buffer, `std::inplace_merge` |
| `select_nth_unstable`, `_by`, `_by_key` | none | same names | none | `std::nth_element` |
| `heapify`, `push_heap`, `pop_heap`, `sort_heap`, `is_heap` (and `_by`) | `container/heap` | none (`BinaryHeap`) | none | `make_heap`, `push_heap`, `pop_heap`, `sort_heap`, `is_heap` |
| `binary_search`, `binary_search_by`, `binary_search_by_key` | `slices.BinarySearch` | same names | `slice.binary_search` | `std::binary_search`, `lower_bound` |
| `partition_point` | `sort.Search` | `partition_point` | none | `std::partition_point` |
| `partition`, `is_partitioned` | none | `partition_in_place` (unstable), `is_partitioned` | none | `std::partition`, `is_partitioned` |
| `partition_dedup`, `_by`, `_by_key`; `Vector::dedup_by`, `dedup_by_key` | `slices.Compact` | `partition_dedup` (unstable), `Vec::dedup_by` | none | `std::unique` |
| `rotate_left`, `rotate_right`, `reverse`, `swap`, `swap_with_slice` | `slices.Reverse` | same names | `slice.reverse` | `std::rotate`, `std::reverse`, `std::swap_ranges` |
| `fill`, `copy_from_slice`, `clone_from_slice`, `split_at`, `split_at_mut` | `copy` | same names | `copy` | `std::fill`, `std::copy` |
| `contains`, `starts_with`, `ends_with`, `iter`, `iter_mut` | `slices.Contains` | same names | `slice.contains` | `std::find`, `std::ranges::starts_with` |

## Collections

| Super-C | Go | Rust | Odin | C++ |
| --- | --- | --- | --- | --- |
| `Map::entry` (`or_insert`, `or_insert_with`, `or_default`, `and_modify`) | none | `HashMap::entry` | none | `try_emplace` |
| `Map::iter`, `iter_mut`, `values_mut`, `drain`, `retain`, `get_key_value`, `remove_entry`, `reserve` | `range`, `maps.DeleteFunc` | same names | `for k, v in m` | `begin`, `erase_if`, `extract`, `reserve` |
| `Set::set_union`, `intersection`, `difference`, `symmetric_difference`, `is_subset` | none | `union` and the same names | `card(a & b)` on bit sets only | `std::set_union` and kin |
| `std::collections::deque::Deque` | none | `VecDeque` | `container/queue.Queue` | `std::deque` |
| `std::collections::deque::RingBuffer<T, N>` | `container/ring` | none | `container/queue` over a fixed buffer | none |
| `std::collections::heap::BinaryHeap`, `Reverse` | `container/heap` | `BinaryHeap`, `cmp::Reverse` | `container/priority_queue` | `std::priority_queue`, `std::greater` |
| `std::collections::btree::BTreeMap`, `BTreeSet`, `Bound` | none | `BTreeMap`, `BTreeSet`, `Bound` | `container/rbtree` | `std::map`, `std::set` |
| `std::collections::hive::Hive`, `HiveHandle` (`insert`, unsafe `get`, `remove`; `retain`, `reserve`, `trim_capacity`) | none | none | none | `std::hive` (`insert`, `erase`, `erase_if`, `reserve`, `trim_capacity`) |
| `std::collections::bits::BitSet<N>`, `BitVec`, `BitField` | `math/bits` per word | none (`fixedbitset` crate) | `bit_set`, `container/bit_array`, `bit_field` | `std::bitset`, `std::vector<bool>`, bit-field members |
| `std::collections::mdspan::MdSpan`, `MdSpanMut` (`row_major`, `col_major`, `strided`) | none | none | none | `std::mdspan` (`layout_right`, `layout_left`, `layout_stride`) |

## Allocators

| Super-C | Go | Rust | Odin | C++ |
| --- | --- | --- | --- | --- |
| `std::alloc::Arena` (`allocator()`, `reset`, `with_buffer`) | none | none | `mem.Arena`, `mem.Dynamic_Arena` | `std::pmr::monotonic_buffer_resource` |
| `std::alloc::Pool` | none | none | none | `std::pmr::unsynchronized_pool_resource` |
| `std::parallel::pool::SyncPool` | `sync.Pool` (an object cache, not an allocator) | none | none | `std::pmr::synchronized_pool_resource` |
| `std::alloc::NoAlloc` | none | none | `mem.panic_allocator` | `std::pmr::null_memory_resource` |
| `std::alloc::Stack` (zero-sized, task-local, last-in first-out reclaim) | none | none | `mem.Stack` (a fixed buffer) | none |

## Memory and shared ownership

| Super-C | Go | Rust | Odin | C++ |
| --- | --- | --- | --- | --- |
| `std::mem::layout::Layout` (`new`, `array`, `followed_by`, `pad_to_align`) | none | `Layout` (`extend` is `followed_by`) | `size_of`, `align_of` | `sizeof`, `alignof` |
| `std::mem::ptr` (`read_unaligned`, `copy`, `copy_nonoverlapping`, `swap`, `write_bytes`, `bit_cast`) | `copy`, `math.Float64bits` | `core::ptr`, `transmute` | `mem.copy`, `transmute` | `std::memcpy`, `std::bit_cast` |
| `std::mem::endian` (`read_le`, `read_be`, `write_le`, `try_read_le`, `append_le`) | `binary.LittleEndian.Uint32`, `PutUint32`, `AppendUint32` | `from_le_bytes`, `to_le_bytes` | `endian.get_u32`, `put_u32` | `std::byteswap` with `memcpy` |
| `std::mem::volatile` (`read_volatile`, `write_volatile`, `zeroize`) | none | `ptr::read_volatile`, `write_volatile` | `intrinsics.volatile_load` | `volatile` |
| `std::mem::cell::Cell`, `RefCell`, `OnceCell` | none (`sync.OnceValue` is thread-safe) | same names | none | none |
| `std::mem::rc::Rc`, `rc::Weak` (`downgrade`, `upgrade`, `make_mut`) | none (`weak.Pointer` for Weak) | `Rc`, `rc::Weak` | none | `std::shared_ptr`, `std::weak_ptr` (atomic counts) |
| `std::parallel::arc::Arc`, `arc::Weak` | none | `Arc`, `sync::Weak` | none | `std::shared_ptr`, `std::weak_ptr` |

## Scalars

The integer, float, `bool` and `char` methods take Rust's names; C++ `<bit>` maps as follows.

| Super-C | Go | Rust | Odin | C++ |
| --- | --- | --- | --- | --- |
| `count_ones`, `count_zeros`, `leading_zeros`, `trailing_zeros`, `leading_ones`, `trailing_ones` | `bits.OnesCount`, `bits.LeadingZeros` | same names | `bits.count_ones` | `popcount`, `countl_zero`, `countr_zero`, `countl_one`, `countr_one` |
| `rotate_left`, `rotate_right`, `swap_bytes`, `reverse_bits` | `bits.RotateLeft`, `bits.ReverseBytes`, `bits.Reverse` | same names | `bits.rotate_left32`, `bits.byte_swap`, `bits.reverse_bits` | `rotl`, `rotr`, `byteswap` |
| `is_power_of_two`, `next_power_of_two`, `ilog2` | none | same names | `math.is_power_of_two` | `has_single_bit`, `bit_ceil`, `bit_width - 1` |
| `to_le_bytes`, `from_be_bytes` and kin, `to_bits`, `from_bits` | `binary.*Endian`, `math.Float64bits` | same names | `transmute` | `std::bit_cast` |
| `pow`, `isqrt`, `ilog10`, `div_euclid`, `rem_euclid`, `abs_diff`, `midpoint` and their `checked_`/`wrapping_`/`saturating_`/`overflowing_` forms | none | same names | none | `std::midpoint`, `div_sat` |
| `f64::classify`, `next_up`, `next_down`, `maximum`, `minimum` | `math.Nextafter`, built-in `max` | same names | `math.classify` | `fpclassify`, `nextafter`, C23 `fmaximum` |
| `bool::then`, `then_some`; `char::is_ascii_*`, `to_digit`, `from_digit` | `unicode.Is*` | same names | `unicode.is_*` | `<cctype>` |
