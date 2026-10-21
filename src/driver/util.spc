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
import driver::rt_c as rtc;
import ir::cpu_features as cf;
import atomic;

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

/// The running executable's path as the system reports it; empty when it does not resolve.
pub fn exe_path() String {
    let mut exe = PathBuf {};
    if unsafe shim::sc_exe_path(&mut exe[0], 4096) != 0 {
        return String::new();
    }
    return String::from_str(str::from_cbuf(exe.as_slice()));
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
/// Small zero-filled C string scratch buffers.
pub type Buf64 = Array<char, 64>;
pub type Buf128 = Array<char, 128>;

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
    let mut p = String::from_str(path);
    return unsafe shim::sc_stat_isdir(p.cstr()) == 1;
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

/// Spawn `args` and wait, output inherited (or captured when `log` is non-null): exit code, -1 on failure.
pub fn exec_args(args: &mut Vector<String>, log: *const char) i32 {
    return exec_at(null, args, log);
}

/// `exec_args` of program `file` (a path; null: `args[0]` searched in PATH), `args` its argv.
pub fn exec_at(file: *const char, args: &mut Vector<String>, log: *const char) i32 {
    let mut ptrs = Vector::<usize>::with_capacity(args.len() + 1);
    for i in 0..args.len() {
        ptrs.push(args[i].cstr() as usize);
    }
    ptrs.push(0);
    return unsafe shim::sc_exec_argv(file, ptrs.as_ptr() as *const *const char, log);
}

/// Spawn `args` without a shell; `log` (may be null) captures the child's stdout+stderr. The child's pid,
/// or -1 on spawn failure.
pub fn spawn_args(args: &mut Vector<String>, log: *const char) i64 {
    return spawn_at(null, args, log);
}

/// `spawn_args` of program `file` (a path; null: `args[0]` searched in PATH), `args` its argv.
pub fn spawn_at(file: *const char, args: &mut Vector<String>, log: *const char) i64 {
    let mut ptrs = Vector::<usize>::with_capacity(args.len() + 1);
    for i in 0..args.len() {
        ptrs.push(args[i].cstr() as usize);
    }
    ptrs.push(0);
    return unsafe shim::sc_spawn_argv(file, ptrs.as_ptr() as *const *const char, log);
}

/// A copy of argv `src`.
pub fn clone_args(src: &Vector<String>) Vector<String> {
    let mut out = Vector::<String>::with_capacity(src.len());
    for i in 0..src.len() {
        out.push(src.at(i).clone());
    }
    return out;
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

/// Make `dstp` a second name of file `srcp` (a hard link: one copy on disk), or a copy where the file
/// system refuses a link (another volume, a link count limit); `dstp` is replaced. The two names share
/// one inode, so nothing may write either in place: a compile into `dstp` must remove it first.
pub fn link_or_copy(srcp: str, dstp: str) bool {
    let mut s = String::from_str(srcp);
    let mut d = String::from_str(dstp);
    let _ = unsafe shim::sc_unlink(d.cstr());
    return unsafe shim::sc_link(s.cstr(), d.cstr()) == 0 || copy_file(srcp, dstp);
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
/// the gate's tree) emits the same text and keeps its object cache keys; else `abs`, which compiles
/// from any location.
pub fn include_name(abs: str, dir: str) String {
    let mut wd = PathBuf {};
    let mut dot = String::from_str(".");
    // A real path: `/...`, or `X:/...` on Windows (sc_realpath writes forward slashes there).
    let rooted = abs.starts_with("/") || abs.len() > 2 && abs[1] == b':';
    if !rooted || unsafe shim::sc_realpath(dot.cstr(), &mut wd[0]) == null {
        return String::from_str(abs);
    }
    let c = str::from_cbuf(wd.as_slice());
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
    let mut dst = String::from_str(path);
    if write_file_parts(tmp.as_str(), head, body) && unsafe shim::sc_rename(tmp.cstr(), dst.cstr()) == 0 {
        return true;
    }
    let _ = unsafe shim::sc_unlink(tmp.cstr());
    return false;
}

/// The entry names of `dir` in directory order, without "." and ".." (and without any dot-entry
/// unless `hidden`); None when the directory cannot be opened.
pub fn list_dir(dir: str, hidden: bool) Option<Vector<String>> {
    let mut d = String::from_str(dir);
    let dh = unsafe shim::sc_opendir(d.cstr());
    if dh == null {
        return Option::<Vector<String>>::None;
    }
    let mut names = Vector::<String>::new();
    loop {
        let e = unsafe shim::sc_readdir(dh);
        if e == null {
            break;
        }
        let nm = unsafe str::from_cstr(shim::sc_dirent_name(e));
        if nm.starts_with(".") && (!hidden || nm == "." || nm == "..") {
            continue;
        }
        names.push(String::from_str(nm));
    }
    unsafe shim::sc_closedir(dh);
    return Option::<Vector<String>>::Some(names);
}

/// Create `path` and any missing parent directories (like `mkdir -p`); existing dirs are ignored.
/// An existing directory costs one stat: the components are created only when it is missing.
pub fn mkdir_p(path: str) {
    let n = path.len();
    if n == 0 || n >= 4096 {
        return;
    }
    let mut buf = Array::<char, 4096>::new();
    unsafe buf.copy_from(path.ptr(), n);
    buf[n] = 0 as char;
    let base = (&buf[0]) as *const char; // read-only C string view; the buffer is edited in place below
    if unsafe shim::sc_stat_isdir(base) == 1 {
        return;
    }
    for i in 1..n {
        if buf[i] == '/' as char {
            buf[i] = 0 as char;
            let _ = unsafe shim::sc_mkdir(base);
            buf[i] = '/' as char;
        }
    }
    let _ = unsafe shim::sc_mkdir(base);
}

/// Make file `path` hold exactly `body`, creating missing parent directories: a file that already holds
/// it is not written, so it keeps its mtime (the build's staleness anchor). 1 when the file was written,
/// 0 when it already held `body`, -1 when it could not be opened, written or closed in full.
pub fn publish_file(path: &mut String, body: str) i32 {
    return unsafe shim::sc_publish(path.cstr(), body.ptr(), body.len());
}

/// Recursively delete every .c/.h under `dir` that is NOT in the keep-list (the files this run wrote), then
/// drop any directory left empty. The compiler overwrites build/ in place but must also remove outputs the
/// program does not produce (a removed module/instance/@test-runner/@c.source wrapper); a stale TU would
/// otherwise linger and break `cc build/**/*.c`. Path comparison is exact ("<dir>/<name>", like build_out_path).
pub fn prune_orphans(dir: *const char, keep: &Vector<String>) {
    let mut ks = Set::<str>::new();
    for i in 0..keep.len() {
        ks.insert(keep[i].as_str());
    }
    prune_dir(dir, &ks);
}

fn prune_dir(dir: *const char, keep: &Set<str>) {
    let d = unsafe shim::sc_opendir(dir);
    if d == null {
        return;
    }
    loop {
        let e = unsafe shim::sc_readdir(d);
        if e == null {
            break;
        }
        let name = unsafe shim::sc_dirent_name(e);
        if unsafe cstring::strcmp(name, ".".ptr() as *const char) == 0 || unsafe cstring::strcmp(
            name,
            "..".ptr() as *const char,
        ) == 0 {
            continue;
        }

        let mut pb = PathBuf {};
        let np = unsafe stdio::snprintf(&mut pb[0], 4096, "%s/%s".ptr() as *const char, dir, name);
        if np < 0 || np as usize >= 4096 {
            continue;
        }
        let path = (&pb[0]) as *const char;
        // Only generated .c/.h translation units are ours to prune. Such a name is a file (a module
        // directory name has no dot), so only other names cost a stat.
        let l = unsafe cstring::strlen(name);
        if !(l >= 2 && unsafe name[l - 2] == '.' as char && (unsafe name[l - 1] == 'c' as char || unsafe name[l - 1] == 'h' as char)) {
            if unsafe shim::sc_stat_isdir(path) == 1 {
                prune_dir(path, keep);
                let _ = unsafe shim::sc_rmdir(path);
            }
            continue;
        }
        let ps = unsafe str::from_cstr(path);
        if !keep.contains(&ps) {
            let _ = unsafe shim::sc_unlink(path);
        }
    }
    let _ = unsafe shim::sc_closedir(d);
}

/// The runtime header shared by every generated module (the C standard library includes plus the
/// leak-tracker interposition), and the tracker's implementation TU the engine compiles alongside, each
/// published with `publish_file`. -1, after a message, when either file cannot be written in full; else
/// bit 0 set when the header was rewritten and bit 1 when the source was.
pub fn write_super_rt(gen_dir: str) i32 {
    let mut path = build_out_path(gen_dir, "super_rt", ".h");
    let mut h = String::from_str("#ifndef SUPER_RT_H\n#define SUPER_RT_H\n");
    h.push_str(unsafe str::from_cstr(rtc::super_rt_includes()));
    h.push_str("#endif\n");
    let hr = publish_file(&mut path, h.as_str());
    if hr < 0 {
        unsafe stdio::perror(path.cstr());
        return -1;
    }
    let mut cpath = build_out_path(gen_dir, "super_rt", ".c");
    let cr = publish_file(&mut cpath, unsafe str::from_cstr(rtc::super_rt_source()));
    if cr < 0 {
        unsafe stdio::perror(cpath.cstr());
        return -1;
    }
    return hr | cr << 1;
}

// Cross toolchains
// Shared by BOTH link paths (the build.toml engine and the single-file `super-c build foo.spc`) because
// a target that reaches only one of them mis-builds silently: the front end gates items on the target while
// the C compiler still builds for the host.

/// The SDK a `--target=` needs, as an index into the helpers below: 1 iOS, 2 Android, 3 wasm, 0 none
/// (windows/macos/linux compile with the ordinary `cc`).
pub const fn target_sdk(target: i32) i32 {
    if target == 3 {
        return 3;
    }
    if target == 4 {
        return 1;
    }
    if target == 5 {
        return 2;
    }
    return 0;
}

/// The C compiler command: `cc` when set (the manifest's or the package's), else the cross target
/// `sdk`'s own toolchain ($CC on the host would build a host binary), else $CC, else `cc`.
pub fn resolve_cc(cc: str, sdk: i32) String {
    let mut out = String::from_str(cc);
    if out.len() == 0 && sdk != 0 {
        sdk_cc(sdk, &mut out);
    }
    if out.len() == 0 {
        let env = stdlib::get_env("CC").unwrap_or(String::new());
        if env.len() != 0 {
            out.push_string(&env);
        } else {
            out.push_str("cc");
        }
    }
    return out;
}

/// The cross compiler for `sdk`, found through the SDK's own environment variable so no path is baked
/// into the compiler. Empty when the toolchain is not installed; the caller then falls back and the
/// C compiler reports what is missing.
pub fn sdk_cc(sdk: i32, out: &mut String) {
    if sdk == 1 {
        // IOS: clang from the active Xcode, selected by `xcrun` so the SDK path comes from the toolchain.
        out.push_str("xcrun --sdk iphoneos clang");
        return;
    }
    if sdk == 2 {
        // Android: the NDK's prebuilt clang. $ANDROID_NDK_HOME (or $ANDROID_NDK_ROOT) locates it.
        let mut ndk = stdlib::get_env("ANDROID_NDK_HOME").unwrap_or(String::new());
        if ndk.len() == 0 {
            ndk = stdlib::get_env("ANDROID_NDK_ROOT").unwrap_or(String::new());
        }
        if ndk.len() == 0 {
            return;
        }
        out.push_string(&ndk);
        out.push_str("/toolchains/llvm/prebuilt/");
        out.push_str(ndk_host_tag());
        out.push_str("/bin/clang");
        return;
    }
    if sdk == 3 {
        // WebAssembly: the wasi-sdk's clang when present (it brings wasi-libc), else a plain clang,
        // which can only build freestanding code.
        let w = stdlib::get_env("WASI_SDK_PATH").unwrap_or(String::new());
        if w.len() != 0 {
            out.push_string(&w);
            out.push_str("/bin/clang");
            return;
        }
        out.push_str("clang");
    }
}

// The NDK lays its prebuilt toolchains out per build host.
const fn ndk_host_tag() str<'static> {
    if unsafe shim::sc_host_platform() == 0 {
        return "windows-x86_64";
    }
    if unsafe shim::sc_host_platform() == 1 {
        // The NDK ships one universal darwin toolchain under this name.
        return "darwin-x86_64";
    }
    return "linux-x86_64";
}

/// Flags every translation unit needs for a cross target: the triple, and for wasm the wasi sysroot's
/// own defaults, then the flags of the enabled CPU `features` in table order. Nothing here overrides
/// the manifest: these come first, manifest flags after. Callers split the result on whitespace
/// (`split_args`), so no quoting: a sysroot path must hold no space.
pub fn push_sdk_flags(cmd: &mut String, target: i32, sdk: i32, arch: i32, features: cf::CpuFeatureSet) {
    push_triple(cmd, sdk, arch);
    cf::push_c_flags(features, target, cmd);
}

fn push_triple(cmd: &mut String, sdk: i32, arch: i32) {
    if sdk == 1 {
        // The triple carries the deployment floor: without a version clang assumes an iOS old enough to
        // lack thread-local storage, which the runtime's preemption tick needs.
        cmd.push_str(" -target ");
        if arch == 0 {
            cmd.push_str("x86_64-apple-ios13.0-simulator");
        } else {
            cmd.push_str("arm64-apple-ios13.0");
        }
        return;
    }
    if sdk == 2 {
        // The NDK's clang takes the API level in the triple; 24 is the oldest still widely supported.
        cmd.push_str(" -target ");
        if arch == 0 {
            cmd.push_str("x86_64-linux-android24");
        } else {
            cmd.push_str("aarch64-linux-android24");
        }
        return;
    }
    if sdk == 3 {
        // A wasi sysroot supplies the libc the emitted C needs. $WASI_SDK_PATH names a full wasi-sdk
        // (its sysroot sits under share/wasi-sysroot); $WASI_SYSROOT names a bare one. With neither,
        // only freestanding code can build; there is no libc to include.
        let sdkp = stdlib::get_env("WASI_SDK_PATH").unwrap_or(String::new());
        if sdkp.len() != 0 {
            cmd.push_str(" -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS");
            cmd.push_str(" -target wasm32-wasip1 --sysroot=");
            cmd.push_string(&sdkp);
            cmd.push_str("/share/wasi-sysroot");
            return;
        }
        let sr = stdlib::get_env("WASI_SYSROOT").unwrap_or(String::new());
        if sr.len() != 0 {
            cmd.push_str(" -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS");
            cmd.push_str(" -target wasm32-wasip1 --sysroot=");
            cmd.push_string(&sr);
            return;
        }
        cmd.push_str(" -target wasm32 -nostdlib");
    }
}

/// Flags and libraries a target needs at LINK time only. wasi keeps signals and the process clock
/// behind opt-in emulation libraries; the runtime's panic path installs a signal handler and `time::clock`
/// reads the process clock (emulated by the wall clock), so the build asks for both. The main thread
/// gets the 8 MiB stack of Linux and macOS on every target, so a program that runs on one runs on all:
/// wasm-ld's default stack is 64 KiB (placed first, so an overflow traps rather than overwriting static
/// data), a Windows executable reserves 1 MiB unless its header says otherwise.
pub fn push_sdk_libs(cmd: &mut String, target: i32, sdk: i32) {
    if target == 0 && sdk == 0 {
        cmd.push_str(" -Wl,--stack,8388608");
    }
    if sdk == 3 {
        cmd.push_str(" -Wl,-z,stack-size=8388608 -Wl,--stack-first");
        let sdkp = stdlib::getenv("WASI_SDK_PATH");
        let sr = stdlib::getenv("WASI_SYSROOT");
        if sdkp != null && unsafe *sdkp != 0 as char || sr != null && unsafe *sr != 0 as char {
            cmd.push_str(" -lwasi-emulated-signal -lwasi-emulated-process-clocks");
        }
    }
}
