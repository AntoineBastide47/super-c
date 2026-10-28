// std::platform::fs against the file system itself: short reads and the end of a stream, NotFound and
// PermissionDenied, handles released (never twice) on error paths, publish keeping an unchanged file's
// time, mkdir_all and remove_all, directory listings, metadata and identity, links, times, locks, and a
// write fault reported on the call after a partial write. Each test works in its own scratch directory.

import std::platform::fs;
import std::platform::path;
import std::platform::process;
import std::platform::signal;
import std::platform::socket;
import tests::platform::platform_harness as ph;

@platform(macos | ios | linux | android)
extern "C" "unistd.h" {
    fn geteuid() u32;
}

struct Fx {
    pub s: ph::Scratch,
}

@test_init
fn setup() Fx {
    return Fx { s: ph::scratch() };
}

// Whether this process ignores permission bits (root on POSIX).
@platform(macos | ios | linux | android)
fn privileged() bool {
    return unsafe geteuid() == 0;
}
@platform(windows | wasm)
fn privileged() bool {
    return false;
}

@test
fn reads_partially_then_reports_the_end(fx: &mut Fx) {
    let p = fx.s.at("ten");
    ph::write_text(p.as_str(), "0123456789");
    let mut f = fs::open(p.as_str(), fs::OpenOptions { read: true }).unwrap();
    let mut four: [u8; 4] = [0; 4];
    assert_eq(f.read(four).unwrap(), 4);
    assert_eq(four[3], b'3');
    assert_eq(f.read(four).unwrap(), 4);
    // The file has two bytes left: a read moves those and returns the short count.
    assert_eq(f.read(four).unwrap(), 2);
    assert_eq(four[1], b'9');
    assert_eq(f.read(four).unwrap(), 0);
    assert_eq(f.read(four).unwrap(), 0);
    assert_eq(f.seek(fs::SeekFrom::Start(3)).unwrap(), 3);
    let mut none: [u8; 0] = [];
    assert_eq(f.read(none).unwrap(), 0); // an empty buffer, not the end
    let mut big: [u8; 64] = [0; 64];
    assert_eq(f.read_full(big).unwrap(), 7);
    assert_eq(f.seek(fs::SeekFrom::End(-2)).unwrap(), 8);
    assert_eq(f.seek(fs::SeekFrom::Current(1)).unwrap(), 9);
    assert_eq(f.read(big).unwrap(), 1);
    assert_eq(big[0], b'9');
}

@test
fn missing_paths_are_not_found(fx: &mut Fx) {
    let p = fx.s.at("missing");
    let q = fx.s.at("missing/child");
    let e = fs::open(p.as_str(), fs::OpenOptions { read: true }).unwrap_err();
    assert(e.kind == IoErrorKind::NotFound);
    assert(e.op == IoOp::Open);
    assert(e.code != 0);
    assert(fs::stat(p.as_str()).unwrap_err().kind == IoErrorKind::NotFound);
    assert(fs::lstat(p.as_str()).unwrap_err().kind == IoErrorKind::NotFound);
    assert(fs::read_dir(p.as_str()).unwrap_err().kind == IoErrorKind::NotFound);
    assert(fs::unlink(p.as_str()).unwrap_err().kind == IoErrorKind::NotFound);
    assert(fs::rmdir(p.as_str()).unwrap_err().kind == IoErrorKind::NotFound);
    assert(fs::rename(p.as_str(), q.as_str()).unwrap_err().kind == IoErrorKind::NotFound);
    assert(fs::readlink(p.as_str()).unwrap_err().kind == IoErrorKind::NotFound);
    assert(fs::realpath(p.as_str()).unwrap_err().kind == IoErrorKind::NotFound);
    assert(fs::mkdir(q.as_str()).unwrap_err().kind == IoErrorKind::NotFound);
    assert(fs::set_times(p.as_str(), fs::FileTime::Now, fs::FileTime::Now).unwrap_err().kind == IoErrorKind::NotFound);
    assert(fs::remove_all(p.as_str()).is_ok());
    let bad = fs::open("a\x00b", fs::OpenOptions { read: true }).unwrap_err();
    assert(bad.kind == IoErrorKind::InvalidInput);
    assert(bad.op == IoOp::Open);
}

@test
fn permission_bits_refuse_writes(fx: &mut Fx) {
    let p = fx.s.at("ro");
    ph::write_text(p.as_str(), "x");
    fs::set_permissions(p.as_str(), 0o444).unwrap();
    assert_eq(fs::stat(p.as_str()).unwrap().permissions & 0o222, 0);
    let w = fs::open(p.as_str(), fs::OpenOptions { write: true });
    if privileged() {
        assert(w.is_ok());
    } else {
        let e = w.unwrap_err();
        assert(e.kind == IoErrorKind::PermissionDenied);
        assert(e.op == IoOp::Open);
    }
    if PLATFORM == Platform::Windows {
        // Windows refuses to remove a read-only file; remove_all clears the flag first.
        assert(fs::unlink(p.as_str()).unwrap_err().kind == IoErrorKind::PermissionDenied);
    }
    let d = fx.s.at("rodir");
    fs::mkdir(d.as_str()).unwrap();
    let inner = fx.s.at("rodir/f");
    ph::write_text(inner.as_str(), "y");
    fs::set_permissions(inner.as_str(), 0o444).unwrap();
    assert(fs::remove_all(d.as_str()).is_ok());
    assert(fs::lstat(d.as_str()).unwrap_err().kind == IoErrorKind::NotFound);
    assert(fs::remove_all(p.as_str()).is_ok());
}

// A directory without write permission refuses a new entry (POSIX: Windows has no such bit).
@platform(macos | linux)
@test
fn a_read_only_directory_refuses_new_entries(fx: &mut Fx) {
    let d = fx.s.at("locked");
    fs::mkdir(d.as_str()).unwrap();
    fs::set_permissions(d.as_str(), 0o555).unwrap();
    let f = fx.s.at("locked/new");
    let r = fs::open(f.as_str(), fs::OpenOptions { write: true, create: true });
    let m = fs::mkdir(fx.s.at("locked/sub").as_str());
    fs::set_permissions(d.as_str(), 0o755).unwrap();
    if !privileged() {
        assert(r.unwrap_err().kind == IoErrorKind::PermissionDenied);
        assert(m.unwrap_err().kind == IoErrorKind::PermissionDenied);
    }
}

// The lowest free descriptor number: equal before and after the error paths when none of them leaked
// one.
@platform(macos | ios | linux | android)
fn next_fd(probe: str) i32 {
    let f = fs::open(probe, fs::OpenOptions { read: true }).unwrap();
    return f.raw();
}

@platform(macos | ios | linux | android)
@test
fn error_paths_release_their_handles_once(fx: &mut Fx) {
    let keep_path = fx.s.at("keep");
    ph::write_text(keep_path.as_str(), "kept");
    // An open handle across the error paths: a double close on any of them would close it (or a handle
    // that reuses its number), and its reads would fail.
    let mut keep = fs::open(keep_path.as_str(), fs::OpenOptions { read: true }).unwrap();
    let before = next_fd(keep_path.as_str());
    let dir = fx.s.at("d");
    fs::mkdir(dir.as_str()).unwrap();
    // A directory opened to write: the open fails.
    assert(fs::open(dir.as_str(), fs::OpenOptions { write: true }).is_err());
    // publish under a parent that is a file: the comparison open fails, the write open fails, mkdir_all
    // fails.
    let under_file = fx.s.at("keep/sub/x");
    assert(fs::publish(under_file.as_str(), ph::bytes_of("x")).is_err());
    // publish of the same bytes: the comparison opens, reads and closes, and writes nothing.
    assert(!fs::publish(keep_path.as_str(), ph::bytes_of("kept")).unwrap());
    // A listing of a file fails; a listing of a directory dropped mid-way closes.
    assert(fs::read_dir(keep_path.as_str()).is_err());
    ph::write_text(fx.s.at("d/a").as_str(), "a");
    {
        let mut d = fs::read_dir(dir.as_str()).unwrap();
        assert(d.next().is_some());
    }
    // A stat of a missing path and a lock of a read-only handle.
    assert(fs::stat(fx.s.at("nope").as_str()).is_err());
    let _ = keep.lock_exclusive(0);
    // A spawn whose program does not exist, with a file redirect the child would have opened.
    let argv: [str; 1] = ["sc-platform-no-such-program"];
    let mut cmd = process::Command::new(argv);
    let out = fx.s.at("out");
    cmd.stdout = process::Redirect::Path(out.as_str());
    assert(process::spawn(cmd).unwrap_err().kind == IoErrorKind::NotFound);
    assert_eq(next_fd(keep_path.as_str()), before);
    let mut buf: [u8; 8] = [0; 8];
    assert(keep.seek(fs::SeekFrom::Start(0)).is_ok());
    assert_eq(keep.read(buf).unwrap(), 4);
    // An explicit close reports its result and leaves nothing for the drop to close again.
    assert(keep.close().is_ok());
    assert_eq(next_fd(keep_path.as_str()), before - 1);
}

@test
fn publish_writes_only_changed_bytes(fx: &mut Fx) {
    let p = fx.s.at("a/b/c/out.txt"); // the parents do not exist yet
    assert(fs::publish(p.as_str(), ph::bytes_of("hello")).unwrap());
    assert(ph::read_text(p.as_str()).eq_str("hello"));
    let old: i64 = 1000000000 * 1000000000;
    fs::set_times(p.as_str(), fs::FileTime::At(old), fs::FileTime::At(old)).unwrap();
    assert(!fs::publish(p.as_str(), ph::bytes_of("hello")).unwrap());
    assert_eq(fs::stat(p.as_str()).unwrap().modified_ns, old);
    // Same size, other bytes; then another size.
    assert(fs::publish(p.as_str(), ph::bytes_of("hellp")).unwrap());
    assert(ph::read_text(p.as_str()).eq_str("hellp"));
    assert(fs::stat(p.as_str()).unwrap().modified_ns != old);
    assert(fs::publish(p.as_str(), ph::bytes_of("")).unwrap());
    assert_eq(fs::stat(p.as_str()).unwrap().size, 0);
    // A file larger than the comparison buffer.
    let mut big = String::new();
    for i in 0..40000 {
        big.push_byte(b'a' + (i % 26) as u8);
    }
    assert(fs::publish(p.as_str(), ph::bytes_of(big.as_str())).unwrap());
    assert(!fs::publish(p.as_str(), ph::bytes_of(big.as_str())).unwrap());
    big.set_byte(39999, b'#');
    assert(fs::publish(p.as_str(), ph::bytes_of(big.as_str())).unwrap());
    assert(ph::read_text(p.as_str()).equals(&big));
}

@test
fn mkdir_all_creates_missing_parents(fx: &mut Fx) {
    let deep = fx.s.at("x/y/z/");
    fs::mkdir_all(deep.as_str()).unwrap();
    assert(fs::stat(fx.s.at("x/y/z").as_str()).unwrap().kind == fs::FileKind::Dir);
    fs::mkdir_all(deep.as_str()).unwrap(); // an existing directory
    let f = fx.s.at("x/file");
    ph::write_text(f.as_str(), "");
    assert(fs::mkdir_all(f.as_str()).unwrap_err().kind == IoErrorKind::AlreadyExists);
    assert(fs::mkdir(fx.s.at("x").as_str()).unwrap_err().kind == IoErrorKind::AlreadyExists);
    assert(fs::rmdir(fx.s.at("x").as_str()).is_err()); // not empty
}

@test
fn remove_all_does_not_follow_links(fx: &mut Fx) {
    let outside = fx.s.at("outside");
    fs::mkdir(outside.as_str()).unwrap();
    ph::write_text(fx.s.at("outside/precious").as_str(), "keep me");
    fs::mkdir_all(fx.s.at("tree/a/b").as_str()).unwrap();
    ph::write_text(fx.s.at("tree/a/b/f1").as_str(), "1");
    ph::write_text(fx.s.at("tree/a/f2").as_str(), "2");
    let ro = fx.s.at("tree/a/ro");
    ph::write_text(ro.as_str(), "3");
    fs::set_permissions(ro.as_str(), 0o444).unwrap();
    // A link to a directory outside the tree: Windows needs developer mode to create one.
    let linked = fs::symlink(outside.as_str(), fx.s.at("tree/a/link").as_str()).is_ok();
    assert(linked || PLATFORM == Platform::Windows);
    fs::remove_all(fx.s.at("tree").as_str()).unwrap();
    assert(fs::lstat(fx.s.at("tree").as_str()).unwrap_err().kind == IoErrorKind::NotFound);
    assert(ph::read_text(fx.s.at("outside/precious").as_str()).eq_str("keep me"));
    // A link at the top is removed itself.
    if linked {
        let top = fx.s.at("toplink");
        fs::symlink(outside.as_str(), top.as_str()).unwrap();
        fs::remove_all(top.as_str()).unwrap();
        assert(fs::stat(outside.as_str()).unwrap().kind == fs::FileKind::Dir);
    }
}

@test
fn read_dir_lists_each_entry_once(fx: &mut Fx) {
    // A name past the inline String budget: the listing's name buffer goes to the heap.
    ph::write_text(fx.s.at("b_longer_than_the_inline_budget").as_str(), "");
    ph::write_text(fx.s.at("a").as_str(), "");
    fs::mkdir(fx.s.at("c").as_str()).unwrap();
    let mut names = Vector::<String>::new();
    let mut d = fs::read_dir(fx.s.dir.as_str()).unwrap();
    while let Some(r) = d.next() {
        let e = r.unwrap();
        if let Some(k) = e.kind {
            let want = if e.name == "c" {
                fs::FileKind::Dir;
            } else {
                fs::FileKind::File;
            };
            assert(k == want);
        }
        names.push(String::from_str(e.name));
    }
    names.sort();
    assert_eq(names.len(), 3);
    assert(names.at(0).eq_str("a"));
    assert(names.at(1).eq_str("b_longer_than_the_inline_budget"));
    assert(names.at(2).eq_str("c"));
    let mut empty = fs::read_dir(fx.s.at("c").as_str()).unwrap();
    assert(empty.next().is_none());
    assert(empty.next().is_none());
}

@test
fn metadata_reports_kind_identity_links_and_times(fx: &mut Fx) {
    let a = fx.s.at("a");
    ph::write_text(a.as_str(), "abc");
    let m = fs::stat(a.as_str()).unwrap();
    assert(m.kind == fs::FileKind::File);
    assert_eq(m.size, 3);
    assert_eq(m.links, 1);
    let b = fx.s.at("b");
    fs::link(a.as_str(), b.as_str()).unwrap();
    let ma = fs::stat(a.as_str()).unwrap();
    let mb = fs::stat(b.as_str()).unwrap();
    assert(ma.same_file(&mb));
    assert_eq(ma.links, 2);
    {
        // Closed before the rename below: Windows does not replace an open file, it moves it aside.
        let f = fs::open(b.as_str(), fs::OpenOptions { read: true }).unwrap();
        assert(f.metadata().unwrap().same_file(&ma));
    }
    let c = fx.s.at("c");
    ph::write_text(c.as_str(), "other");
    assert(!fs::stat(c.as_str()).unwrap().same_file(&ma));
    // rename replaces an existing file.
    fs::rename(c.as_str(), b.as_str()).unwrap();
    assert(ph::read_text(b.as_str()).eq_str("other"));
    assert(fs::stat(c.as_str()).unwrap_err().kind == IoErrorKind::NotFound);
    assert_eq(fs::stat(a.as_str()).unwrap().links, 1);
    // Times in 100 ns steps survive on every target; Keep leaves one alone.
    let t: i64 = 1234567890123456700;
    fs::set_times(a.as_str(), fs::FileTime::At(t), fs::FileTime::At(t + 100)).unwrap();
    let mt = fs::stat(a.as_str()).unwrap();
    assert_eq(mt.modified_ns, t + 100);
    assert_eq(mt.accessed_ns, t);
    fs::set_times(a.as_str(), fs::FileTime::Keep, fs::FileTime::At(-1000000000)).unwrap();
    assert_eq(fs::stat(a.as_str()).unwrap().modified_ns, -1000000000);
    fs::set_times(a.as_str(), fs::FileTime::Now, fs::FileTime::Now).unwrap();
    assert(fs::stat(a.as_str()).unwrap().modified_ns > 1600000000 * 1000000000);
    assert(fs::stat(fx.s.dir.as_str()).unwrap().kind == fs::FileKind::Dir);
}

@test
fn links_resolve_and_report_their_text(fx: &mut Fx) {
    let target = fx.s.at("target");
    ph::write_text(target.as_str(), "t");
    let l = fx.s.at("l");
    if fs::symlink("target", l.as_str()).is_err() {
        assert(PLATFORM == Platform::Windows); // developer mode is off
        return;
    }
    assert(fs::readlink(l.as_str()).unwrap().eq_str("target"));
    assert(fs::lstat(l.as_str()).unwrap().kind == fs::FileKind::Symlink);
    assert(fs::stat(l.as_str()).unwrap().kind == fs::FileKind::File);
    assert(fs::readlink(target.as_str()).unwrap_err().kind == IoErrorKind::InvalidInput);
    let r = fs::realpath(target.as_str()).unwrap();
    assert(path::is_absolute(r.as_str()));
    assert(r.ends_with("/target"));
    assert(fs::realpath(l.as_str()).unwrap().equals(&r));
    // A dangling link still has its text.
    let dangling = fx.s.at("dangling");
    fs::symlink("nowhere", dangling.as_str()).unwrap();
    assert(fs::readlink(dangling.as_str()).unwrap().eq_str("nowhere"));
    assert(fs::stat(dangling.as_str()).unwrap_err().kind == IoErrorKind::NotFound);
}

@test
fn temp_dir_is_a_directory_without_a_trailing_separator() {
    let t = fs::temp_dir().unwrap();
    assert(t.len() > 1);
    assert(!path::is_separator(t.byte(t.len() - 1)));
    assert(fs::stat(t.as_str()).unwrap().kind == fs::FileKind::Dir);
    if PLATFORM == Platform::Windows {
        assert(!t.contains_byte(b'\\'));
    }
}

@test
fn locks_are_taken_and_released(fx: &mut Fx) {
    let p = fx.s.at("lock");
    let mut f = fs::open(p.as_str(), fs::OpenOptions { read: true, write: true, create: true }).unwrap();
    f.lock_exclusive(0).unwrap();
    f.unlock().unwrap();
    f.lock_exclusive(1000000).unwrap();
}

@test
fn appends_and_creates_exclusively(fx: &mut Fx) {
    let p = fx.s.at("log");
    let mut a = fs::open(p.as_str(), fs::OpenOptions { write: true, append: true, create_new: true }).unwrap();
    a.write_all(ph::bytes_of("one ")).unwrap();
    let mut b = fs::open(p.as_str(), fs::OpenOptions { append: true }).unwrap();
    b.write_all(ph::bytes_of("two")).unwrap();
    a.write_all(ph::bytes_of(" three")).unwrap();
    assert(ph::read_text(p.as_str()).eq_str("one two three"));
    let e = fs::open(p.as_str(), fs::OpenOptions { write: true, create_new: true }).unwrap_err();
    assert(e.kind == IoErrorKind::AlreadyExists);
    let mut t = fs::open(p.as_str(), fs::OpenOptions { write: true, truncate: true }).unwrap();
    t.sync().unwrap();
    assert_eq(fs::stat(p.as_str()).unwrap().size, 0);
}

// The Writer contract on a pipe: a write the pipe takes in part returns that count, and the fault
// that follows (the full pipe, then the reader gone) shows on the next call.
@platform(macos | linux)
@test
fn a_write_fault_after_a_partial_write_shows_on_the_next_call() {
    signal::ignore(signal::Signal::Pipe).unwrap();
    let (mut r, mut w) = process::pipe().unwrap();
    socket::set_nonblocking(w.raw()).unwrap();
    let mut big = Vector::<u8>::new();
    big.resize_default(1 << 20);
    let n = w.write(big[0..big.len()]).unwrap();
    assert(n > 0);
    assert(n < big.len());
    let e = w.write(big[n..big.len()]).unwrap_err();
    assert(e.kind == IoErrorKind::WouldBlock);
    assert(e.op == IoOp::Write);
    // The reader drains a part, then goes away.
    let mut buf: [u8; 4096] = [0; 4096];
    assert_eq(r.read(buf).unwrap(), 4096);
    assert(r.close().is_ok());
    let gone = w.write(big[0..16]).unwrap_err();
    assert(gone.kind == IoErrorKind::Closed);
    signal::set_default(signal::Signal::Pipe).unwrap();
}

// A pipe's reader sees each write as it arrives, then the end once every writer closed.
@platform(!wasm)
@test
fn pipe_reads_are_short_until_the_end() {
    let (mut r, mut w) = process::pipe().unwrap();
    assert(!r.pending().unwrap());
    w.write_all(ph::bytes_of("abc")).unwrap();
    let mut buf: [u8; 64] = [0; 64];
    assert(r.pending().unwrap());
    assert_eq(r.read(buf).unwrap(), 3);
    w.write_all(ph::bytes_of("de")).unwrap();
    assert_eq(r.read(buf).unwrap(), 2);
    assert_eq(buf[1], b'e');
    assert(w.close().is_ok());
    assert(r.pending().unwrap()); // the end is ready to read
    assert_eq(r.read(buf).unwrap(), 0);
}
