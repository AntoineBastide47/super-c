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
| field without a modifier (its type's `extend` blocks) | none | none | none | `private` |
| field `pub(file)` | none | none | none | none |
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
