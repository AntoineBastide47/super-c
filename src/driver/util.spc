import stdio;
import stdlib;
import string as cstring;
import lexer::token as tok;
import lexer::lexer as lex;
import lexer::token_type as ltt;
import ast::ast as *;
import module::loader as loader;
import ast::parser as par;
import fmt::builder as fbld;
import driver_shim as shim;
import std::platform::clock;
import std::platform::fs;
import std::platform::process;
import emit::rt_h as rth;
import ir::cpu_features as cf;
import bindgen::ctarget_data as ctd;
import atomic;
import target::table as tgt;

/// The 64-bit FNV-1a offset basis: the state of an empty hash (std `str::hash` starts from it).
pub const FNV_BASIS: u64 = 0xcbf29ce484222325u64;

/// 64-bit FNV-1a of `s` continued from state `h`: hashing a then b continues over their concatenation.
pub const fn fnv_cont(h: u64, s: str) u64 {
    let mut x = h;
    for k in 0..s.len() {
        x = (x ^ s.byte_at(k) as u64).wrapping_mul(0x100000001b3u64);
    }
    return x;
}

// The memoized `compiler_id`, 0 until a call reads the executable. The bytes behind the running process
// stay its identity even if the file is replaced later. Relaxed atomics: concurrent first calls store
// the same value.
static mut G_CID: u64 = 0;

/// The identity of the running compiler: a content hash of its executable (`file_id`), read once per
/// process. The C a compiler emits is a function of the compiler, so the emit stamp and the per-TU cache
/// key on this, not on the file's path or mtime: a reinstall, a copy or an extracted archive can keep
/// both while the content changes. 0 when the executable cannot be read (the caller then keeps no cache).
pub fn compiler_id() u64 {
    let c = unsafe atomic::load_u64(&G_CID, 0);
    if c != 0 {
        return c;
    }
    let exe = exe_path();
    if exe.len() == 0 {
        return 0;
    }
    let h = file_id(exe.as_str());
    unsafe atomic::store_u64(&mut G_CID, h, 0);
    return h;
}

/// The running executable's path as the system reports it ('/' separators on Windows; under WASI an
/// absolute argv[0], `shim::sc_set_argv0`); empty when it does not resolve.
pub fn exe_path() String {
    if PLATFORM == Platform::Wasm {
        return shim::argv0_path();
    }
    return process::exe_path().unwrap_or(String::new());
}

/// Monotonic milliseconds (never wall clock).
pub fn ticks_ms() i64 {
    return (clock::monotonic_ns() / 1000000) as i64;
}

/// Modification time of `path` in seconds; 0 when it does not exist (the build engine's staleness
/// sentinel).
pub fn file_mtime(path: str) i64 {
    if let Ok(m) = fs::stat(path) {
        return mtime_s(m.modified_ns);
    }
    return 0;
}

/// Whether paths `a` and `b` name one physical file (device and file number); false when either does not
/// exist.
pub fn same_file(a: str, b: str) bool {
    let ma = fs::stat(a);
    let mb = fs::stat(b);
    if ma.is_err() || mb.is_err() {
        return false;
    }
    let other = mb.unwrap();
    return ma.unwrap().same_file(&other);
}

/// Nanoseconds `ns` as whole seconds, rounded down as `st_mtime` is.
pub const fn mtime_s(ns: i64) i64 {
    let s = ns / 1000000000;
    if ns % 1000000000 < 0 {
        return s - 1;
    }
    return s;
}

/// The exit code a finished child stands for: its own, or 1 when a signal ended it.
pub const fn exit_code(st: process::ExitStatus) i32 {
    return switch st {
        Code(c) => c,
        Signal(_) => 1,
    };
}

// The start state of the four hash lanes of `file_id` and `str_id`.
const LANES0: [u64; 4] = [FNV_BASIS, 0x9e3779b97f4a7c15u64, 0xBF58476D1CE4E5B9u64, 0x94D049BB133111EBu64];

// Fold one 32-byte group into the four lanes, one 8-byte word each: the four multiply chains are
// independent and run in parallel, about 1 ms per 10 MB.
const fn lanes_mix(l: &mut [u64; 4], w0: u64, w1: u64, w2: u64, w3: u64) {
    l[0] = (l[0] ^ w0).wrapping_mul(0x100000001b3u64);
    l[1] = (l[1] ^ w1).wrapping_mul(0x100000001b3u64);
    l[2] = (l[2] ^ w2).wrapping_mul(0x100000001b3u64);
    l[3] = (l[3] ^ w3).wrapping_mul(0x100000001b3u64);
    l[0] = l[0] ^ l[0] >> 29;
    l[1] = l[1] ^ l[1] >> 29;
    l[2] = l[2] ^ l[2] >> 29;
    l[3] = l[3] ^ l[3] >> 29;
}

// The hash of lanes `l` over `tot` bytes; never 0.
const fn lanes_end(l: &[u64; 4], tot: u64) u64 {
    let h = skey_mix(skey_mix(skey_mix(skey_mix(skey_mix(FNV_BASIS, l[0]), l[1]), l[2]), l[3]), tot);
    // 0 means "no identity"; a real hash never takes it.
    return h | (h == 0) as u64;
}

/// A content hash of the file at `path`: `str_id` of its bytes (a regular file reads in whole 64 KiB
/// blocks, a multiple of the 32-byte groups); 0 when it cannot be read.
pub fn file_id(path: str) u64 {
    let f = stdio::fopen(path, "rb");
    if f == null {
        return 0;
    }
    // Words, so the loads below are aligned.
    let mut buf = Array::<u64, 8192>::new();
    let bp = (&mut buf[0]) as *mut u64;
    let mut l = LANES0;
    let mut tot: u64 = 0;
    loop {
        let n = unsafe stdio::fread(bp, 1, 65536, f);
        if n == 0 {
            break;
        }
        tot += n as u64;
        // Zero the bytes past the data up to a whole group of four words.
        let e = (n + 31) / 32 * 32;
        for k in n..e {
            unsafe (bp as *mut u8)[k] = 0;
        }
        let mut i: usize = 0;
        while i < e / 8 {
            lanes_mix(&mut l, buf[i], buf[i + 1], buf[i + 2], buf[i + 3]);
            i += 4;
        }
    }
    let bad = unsafe stdio::ferror(f) != 0;
    unsafe stdio::fclose(f);
    if bad {
        return 0;
    }
    return lanes_end(&l, tot);
}

/// A content hash of `s` in the scheme of `file_id`, about 1 ms per 10 MB; never 0.
pub fn str_id(s: str) u64 {
    let mut l = LANES0;
    let mut w = Array::<u64, 4>::new();
    let n = s.len();
    let mut i: usize = 0;
    while i + 32 <= n {
        unsafe cstring::memcpy((&mut w[0]) as *mut u64, s.ptr() + i, 32);
        lanes_mix(&mut l, w[0], w[1], w[2], w[3]);
        i += 32;
    }
    if i < n {
        // The tail, zero-padded to a whole group.
        w = Array::<u64, 4>::new();
        unsafe cstring::memcpy((&mut w[0]) as *mut u64, s.ptr() + i, n - i);
        lanes_mix(&mut l, w[0], w[1], w[2], w[3]);
    }
    return lanes_end(&l, n as u64);
}

/// A 4096-byte path scratch buffer; `PathBuf {}` partial init zero-fills the array.
pub type PathBuf = Array<char, 4096>;
/// A small zero-filled C string scratch buffer.
pub type Buf64 = Array<char, 64>;

/// Format `src` into `out` at `width` columns. Returns false on lex/parse errors or a
/// comment-count mismatch; callers must not use `out` after failure.
pub fn format_source(src: &String, path: str, width: i32, out: &mut String) bool {
    let mut vsrc = src.clone();
    let mut lx = lex::Lexer::new(&mut vsrc, path);
    lx.keep_trivia = true;
    lx.scan_tokens();
    if lx.has_errors() {
        lx.log_errors();
        return false;
    }
    let toks = lx.take_tokens();
    let mut ncomments: usize = 0;
    let mut sig = Vector::<tok::Token>::new();
    for i in 0..toks.len() {
        let t = *toks.at(i);
        let k = t.kind();
        if k == ltt::TokenType::LineComment || k == ltt::TokenType::BlockComment || k == ltt::TokenType::DocLineComment || k == ltt::TokenType::DocBlockComment {
            ncomments = ncomments + 1;
        } else {
            sig.push(t);
        }
    }
    let mut ps = par::Parser::new(sig, vsrc.as_str(), path);
    // The formatter prints `@derive` as attribute text and reprints the source items 1:1, so the
    // synthesized extends must not exist in its AST.
    ps.expand_derive = false;
    ps.build_ast();
    if ps.has_errors() {
        ps.errors.log();
        return false;
    }
    let ast = ps.take_ast();
    let emitted = fbld::format_program(&ast, src.as_str(), width, out);
    if emitted != ncomments {
        // Either direction is a formatter defect: a dropped comment or a comment printed twice.
        eprintln("fmt: internal error: '{}' has {} comments but would print {}; refusing", path, ncomments, emitted);
        return false;
    }
    return true;
}

/// "<gen_dir>/<mod path, '::' -> '/'><ext>" (heap-allocated; caller owns).
pub fn build_out_path(gen_dir: str, mod_path: str, ext: str) String {
    let mut out = String::from_str(gen_dir);
    out.push_byte(b'/');
    let n = mod_path.len();
    let mut i: usize = 0;
    while i < n {
        if mod_path.byte_at(i) == b':' && i + 1 < n && mod_path.byte_at(i + 1) == b':' {
            out.push_byte(b'/');
            i = i + 2;
        } else {
            out.push_byte(mod_path.byte_at(i));
            i = i + 1;
        }
    }
    out.push_str(ext);
    return out;
}

/// True when `path` names an existing directory.
pub fn is_dir(path: str) bool {
    if let Ok(m) = fs::stat(path) {
        return m.kind == fs::FileKind::Dir;
    }
    return false;
}

/// Whitespace-split `s` into argv entries: FLAG strings keep their shell-splitting contract
/// ("-framework Cocoa" is two arguments); paths the engine controls are pushed as single entries and
/// never split, which is what lets spaces, quotes and non-ASCII bytes pass through.
pub fn split_args(out: &mut Vector<String>, s: str) {
    let mut a: usize = 0;
    for i in 0..s.len() + 1 {
        let ws = i == s.len() || s[i] == b' ' || s[i] == b'\t';
        if ws {
            if i > a {
                out.push(String::from_str(s.slice(a, i)));
            }
            a = i + 1;
        }
    }
}

/// Spawn `args` and wait, output inherited (or captured when `log` is not empty): the exit code, -1 when
/// the program does not start or the wait fails. A child a signal ended returns 1 and is named on stderr
/// with the signal.
pub fn exec_args(args: &Vector<String>, log: str) i32 {
    return exec_at("", args, log);
}

/// `exec_args` of program `file` (a path; empty: `args[0]` searched in PATH), `args` its argv.
pub fn exec_at(file: str, args: &Vector<String>, log: str) i32 {
    let c = spawn_at(file, args, log);
    if c.is_none() {
        return -1;
    }
    let mut child = c.unwrap();
    let st = child.wait();
    if st.is_err() {
        return -1;
    }
    let s = st.unwrap();
    if let Signal(sig) = s {
        report_signal(args.at(0).as_str(), sig);
    }
    return exit_code(s);
}

// Name on stderr the program `prog` that signal `sig` ended.
@platform(macos | ios | linux | android)
fn report_signal(prog: str, sig: i32) {
    let name = unsafe str::from_cstr(strsignal(sig));
    eprintln("super-c: '{}' was terminated by signal {} ({})", prog, sig, name);
}
@platform(windows | wasm)
fn report_signal(_prog: str, _sig: i32) {}

@platform(macos | ios | linux | android)
extern "C" "string.h" {
    fn strsignal(sig: i32) *mut char;
}

/// `spawn_args` of program `file` (a path; empty: `args[0]` searched in PATH), `args` its argv.
pub fn spawn_at(file: str, args: &Vector<String>, log: str) Option<process::Child> {
    let mut argv = Vector::<str>::with_capacity(args.len());
    for i in 0..args.len() {
        argv.push(args.at(i).as_str());
    }
    let mut cmd = process::Command::new(argv[0..argv.len()]);
    if file.len() != 0 {
        cmd.program = Option::<str>::Some(file);
    }
    if log.len() != 0 {
        cmd.stdout = process::Redirect::Path(log);
        cmd.stderr = process::Redirect::Stdout;
    }
    return process::spawn(cmd).get_ok();
}

/// Append `s` to argv `out` as one argument.
pub fn push_arg(out: &mut Vector<String>, s: str) {
    out.push(String::from_str(s));
}

/// False when the file cannot be opened, or a short write or failed close left it incomplete.
pub fn write_file(path: str, body: str) bool {
    return write_file_parts(path, body, "");
}

/// `write_file` of `head` followed by `body`, which stay apart in memory.
pub fn write_file_parts(path: str, head: str, body: str) bool {
    let f = stdio::fopen(path, "wb");
    if f == null {
        return false;
    }
    let n = unsafe stdio::fwrite(head.ptr(), 1, head.len(), f) + unsafe stdio::fwrite(body.ptr(), 1, body.len(), f);
    let rc = unsafe stdio::fclose(f);
    return n == head.len() + body.len() && rc == 0;
}

/// Copy file `srcp` to `dstp` (created or truncated); false when either cannot be opened or any read,
/// write or close fails.
pub fn copy_file(srcp: str, dstp: str) bool {
    let fi = stdio::fopen(srcp, "rb");
    if fi == null {
        return false;
    }
    let fo = stdio::fopen(dstp, "wb");
    if fo == null {
        unsafe stdio::fclose(fi);
        return false;
    }
    let mut buf = Array::<char, 4096>::new();
    let mut ok = true;
    loop {
        let n = unsafe stdio::fread(&mut buf[0], 1, 4096, fi);
        if n == 0 {
            break;
        }
        if unsafe stdio::fwrite(&buf[0], 1, n, fo) != n {
            ok = false;
            break;
        }
    }
    // A read error also ends the loop, and would otherwise pass for end of file.
    if unsafe stdio::ferror(fi) != 0 {
        ok = false;
    }
    unsafe stdio::fclose(fi);
    if unsafe stdio::fclose(fo) != 0 {
        ok = false;
    }
    return ok;
}

/// The units of emitted tree `root` that its packs include, as paths relative to `root`: they compile
/// only through them (`driver::emit::pack_plan`: a small program's units in `__sc_unity.c`, a larger
/// one's small units in `__sc_pack0.c`, `__sc_pack1.c`, ..). Empty when the tree has no pack.
pub fn unity_members(root: str, out: &mut Set<String>) {
    for k in 0..SHARD_MAX + 1 {
        let up = if k == 0 {
            format("{}/__sc_unity.c", root);
        } else {
            format("{}/__sc_pack{}.c", root, k - 1);
        };
        let body = loader::read_file(up.as_str());
        if body.is_none() {
            if k != 0 {
                return;
            }
            continue;
        }
        let b = body.unwrap();
        for line in b.as_str().lines() {
            if line.starts_with("#include \"") && line.ends_with("\"") {
                out.insert(String::from_str(line.slice(10, line.len() - 1)));
            }
        }
    }
}

/// The most shards one module may have (a chunk's shard is a `u8`), and the most packs a tree has: a
/// pack count is a shard count (`driver::emit::shard_policy`).
pub const SHARD_MAX: u32 = 64;

/// The name a generated file in directory `dir` includes file `abs` by (both real paths): relative when
/// both lie below the working directory, so a tree that moves with its project (a copy, a worktree,
/// the gate's tree) emits the same text and keeps its cache keys; else `abs`, which compiles from any
/// location.
pub fn include_name(abs: str, dir: str) String {
    // A real path: `/...`, or `X:/...` on Windows (fs::realpath writes forward slashes there).
    let rooted = abs.starts_with("/") || abs.len() > 2 && abs[1] == b':';
    if !rooted {
        return String::from_str(abs);
    }
    let wd = fs::realpath(".");
    if wd.is_err() {
        return String::from_str(abs);
    }
    let cwd = wd.unwrap();
    let c = cwd.as_str();
    if c.len() <= 1 || !below(abs, c) || dir != c && !below(dir, c) {
        return String::from_str(abs);
    }
    let mut out = String::new();
    for i in c.len()..dir.len() {
        if dir[i] == b'/' {
            out.push_str("../");
        }
    }
    out.push_str(abs.slice(c.len() + 1, abs.len()));
    return out;
}

// Whether path `p` lies below directory `d` (both without a trailing separator).
const fn below(p: str, d: str) bool {
    return p.len() > d.len() && p.starts_with(d) && p[d.len()] == b'/';
}

/// write_file through `<path>.tmp` and an atomic rename: an interrupted or failed write leaves `path`
/// as it was, never torn. False when any step fails. Compile, LTO-probe and stamp records ignore a
/// failure: an old or missing record only makes the next build redo that work.
pub fn write_file_atomic(path: str, body: str) bool {
    return write_file_atomic_parts(path, body, "");
}

/// `write_file_atomic` of `head` followed by `body` (`write_file_parts`).
pub fn write_file_atomic_parts(path: str, head: str, body: str) bool {
    let mut tmp = String::from_str(path);
    tmp.push_str(".tmp");
    if write_file_parts(tmp.as_str(), head, body) && fs::rename(tmp.as_str(), path).is_ok() {
        return true;
    }
    let _ = fs::unlink(tmp.as_str());
    return false;
}

/// The entry names of `dir` in directory order, without "." and ".." (and without any dot-entry
/// unless `hidden`); None when the directory cannot be opened.
pub fn list_dir(dir: str, hidden: bool) Option<Vector<String>> {
    let opened = fs::read_dir(dir);
    if opened.is_err() {
        return Option::<Vector<String>>::None;
    }
    let mut d = opened.unwrap();
    let mut names = Vector::<String>::new();
    // Bounded by the entries of the directory; a read error ends the listing, as the end does.
    while let Some(Ok(e)) = d.next() {
        if e.name.starts_with(".") && !hidden {
            continue;
        }
        names.push(String::from_str(e.name));
    }
    return Option::<Vector<String>>::Some(names);
}

/// Create `path` and any missing parent directories (like `mkdir -p`); existing dirs are ignored.
/// An existing directory costs one stat: the components are created only when it is missing.
pub fn mkdir_p(path: str) {
    if path.len() == 0 || is_dir(path) {
        return;
    }
    let _ = fs::mkdir_all(path);
}

/// Make file `path` hold exactly `body`, creating missing parent directories: a file that already holds
/// it is not written, so it keeps its mtime (the build's staleness anchor). 1 when the file was written,
/// 0 when it already held `body`, -1 when it could not be opened, written or closed in full.
pub fn publish_file(path: str, body: str) i32 {
    let r = fs::publish(path, unsafe Slice::<u8> { ptr: body.ptr(), len: body.len() });
    if r.is_err() {
        return -1;
    }
    return r.unwrap() as i32;
}

/// Recursively delete every .c/.h/.o under `dir` that is NOT in the keep-list (the files this run wrote), then
/// drop any directory left empty. The compiler overwrites build/ in place but must also remove outputs the
/// program does not produce (a removed module, instance or @test runner); a stale TU would
/// otherwise linger and break `cc build/**/*.c`. Path comparison is exact ("<dir>/<name>", like build_out_path).
pub fn prune_orphans(dir: str, keep: &Vector<String>) {
    let mut ks = Set::<str>::new();
    for i in 0..keep.len() {
        ks.insert(keep[i].as_str());
    }
    let mut path = String::from_str(dir);
    prune_dir(&mut path, &ks);
}

// Prune directory `dir` (restored on return): one path buffer for the whole walk.
fn prune_dir(dir: &mut String, keep: &Set<str>) {
    let opened = fs::read_dir(dir.as_str());
    if opened.is_err() {
        return;
    }
    let mut d = opened.unwrap();
    let base = dir.len();
    // Bounded by the entries of the directory; a read error ends the walk, as the end does.
    while let Some(Ok(e)) = d.next() {
        // Only generated .c/.h translation units and native objects are ours to prune. Such a name is a
        // file (a module directory name has no dot), so only other names cost a stat.
        let unit = e.name.ends_with(".c") || e.name.ends_with(".h") || e.name.ends_with(".o");
        dir.push_byte(b'/');
        dir.push_str(e.name);
        if !unit {
            if is_dir(dir.as_str()) {
                prune_dir(dir, keep);
                let _ = fs::rmdir(dir.as_str());
            }
        } else {
            let ds = dir.as_str();
            if !keep.contains(&ds) {
                let _ = fs::unlink(ds);
            }
        }
        dir.truncate(base);
    }
}

/// The C backend's runtime header shared by every generated file (`emit::rt_h`), published with
/// `publish_file`: -1, after a message, when it cannot be written in full; else 1 when this build rewrote
/// it, 0 when it was current.
pub fn write_super_rt(gen_dir: str) i32 {
    let mut path = build_out_path(gen_dir, "super_rt", ".h");
    let mut h = String::from_str("#ifndef SUPER_RT_H\n#define SUPER_RT_H\n");
    h.push_str(rth::super_rt_h());
    h.push_str("#endif\n");
    let hr = publish_file(path.as_str(), h.as_str());
    if hr < 0 {
        unsafe stdio::perror(path.cstr());
        return -1;
    }
    return hr;
}

/// The NDK's prebuilt LLVM directory (`toolchains/llvm/prebuilt/<host>`), which holds `bin/clang` and
/// `sysroot`, appended to `out`; $ANDROID_NDK_HOME (or $ANDROID_NDK_ROOT) locates the NDK. False, with
/// `out` unchanged, when neither is set.
pub fn ndk_llvm(out: &mut String) bool {
    let mut ndk = stdlib::get_env("ANDROID_NDK_HOME").unwrap_or(String::new());
    if ndk.len() == 0 {
        ndk = stdlib::get_env("ANDROID_NDK_ROOT").unwrap_or(String::new());
    }
    if ndk.len() == 0 {
        return false;
    }
    out.push_string(&ndk);
    out.push_str("/toolchains/llvm/prebuilt/");
    out.push_str(ndk_host_tag());
    return true;
}

// The NDK lays its prebuilt toolchains out per build host.
const fn ndk_host_tag() str<'static> {
    return tgt::os(unsafe shim::sc_host_platform()).ndk_host;
}

/// The wasi sysroot appended to `out`: `share/wasi-sysroot` of the wasi-sdk $WASI_SDK_PATH names, else
/// the bare sysroot $WASI_SYSROOT names. False, with `out` unchanged, when neither is set.
pub fn wasi_sysroot(out: &mut String) bool {
    let sdkp = stdlib::get_env("WASI_SDK_PATH").unwrap_or(String::new());
    if sdkp.len() != 0 {
        out.push_string(&sdkp);
        out.push_str("/share/wasi-sysroot");
        return true;
    }
    let sr = stdlib::get_env("WASI_SYSROOT").unwrap_or(String::new());
    if sr.len() != 0 {
        out.push_string(&sr);
        return true;
    }
    return false;
}

/// Flags every translation unit needs for a cross target: the triple, and for wasm the wasi sysroot's
/// own defaults (on macOS, the instruction set when it is not the host's), then the flags of the
/// enabled CPU `features` in table order. Nothing here overrides the manifest: these come first,
/// manifest flags after. Callers split the result on whitespace (`split_args`), so no quoting: a
/// sysroot path must hold no space.
pub fn push_sdk_flags(cmd: &mut String, target: i32, arch: i32, features: cf::CpuFeatureSet) {
    push_triple(cmd, target, arch);
    let o = tgt::os(target);
    if o.darwin && o.sdk == tgt::SDK_NONE && arch != unsafe shim::sc_host_arch() {
        // Apple's clang builds either instruction set from the one macOS SDK: `-arch` takes the
        // triple's instruction set name.
        if let Some(t) = tgt::target_of(target, arch) {
            cmd.push_str(" -arch ");
            cmd.push_str(t.triple.slice(0, t.triple.find_byte(b'-') as usize));
        }
    }
    cf::push_c_flags(features, target, arch, cmd);
}

/// The flags that decide what the C headers declare, as every compile of the generated tree has them and
/// bindgen preprocesses under them: the dialect and the POSIX level (POSIX 2008 with the XSI extension,
/// which declares `realpath` on glibc and wasi-libc) and the dialect of `target` after it, the unsigned
/// `char`, and the defines of `target` (Windows: one API level for every mingw
/// toolchain; MSYS2 defaults `_WIN32_WINNT` to Windows 10, llvm-mingw to Windows 7, whose headers hide the
/// Windows 8 functions the runtime calls, GetCurrentThreadStackLimits).
pub fn push_c_env(cmd: &mut String, target: i32) {
    cmd.push_str("-std=c11 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700");
    cmd.push_str(tgt::os(target).c_std);
    cmd.push_str(" -funsigned-char");
    cmd.push_str(tgt::os(target).c_defines);
}

fn push_triple(cmd: &mut String, target: i32, arch: i32) {
    let sdk = tgt::os(target).sdk;
    let to = tgt::target_of(target, arch);
    if sdk == tgt::SDK_NONE || to.is_none() {
        return;
    }
    let t = to.unwrap();
    // The triples are the target table's, the ones bindgen's C environment models: iOS carries the
    // deployment floor (without a version clang assumes an iOS old enough to lack thread-local storage,
    // which the runtime's preemption tick needs), Android the API level (24 is the oldest still widely
    // supported).
    let rows: []ctd::Row = ctd::ROWS;
    let row = &rows[t.cenv as usize];
    if sdk != tgt::SDK_WASI {
        cmd.push_str(" -target ");
        cmd.push_str(t.triple);
        return;
    }
    // A wasi sysroot supplies the libc the emitted C needs. With none, only freestanding code can
    // build; there is no libc to include.
    let mut sr = String::new();
    if wasi_sysroot(&mut sr) {
        cmd.push_str(row.flags);
        cmd.push_str(" -target ");
        cmd.push_str(t.triple);
        cmd.push_str(" --sysroot=");
        cmd.push_string(&sr);
        return;
    }
    cmd.push_str(" -target wasm32 -nostdlib");
}
