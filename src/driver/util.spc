import stdio;
import stdlib;
import string as cstring;
import lexer::token as tok;
import lexer::lexer as lex;
import lexer::token_type as ltt;
import ast::ast as *;
import ast::parser as par;
import fmt::builder as fbld;
import driver_shim as shim;
import driver::rt_c as rtc;

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

/// The identity of the running compiler: a content hash of its executable (`file_id`). The C a compiler
/// emits is a function of the compiler, so the emit stamp and the per-TU cache key on this, not on the
/// file's path or mtime: a reinstall, a copy or an extracted archive can keep both while the content
/// changes. 0 when the executable cannot be read (the caller then keeps no cache).
pub fn compiler_id() u64 {
    let mut exe = PathBuf {};
    if unsafe shim::sc_exe_path(&mut exe[0], 4096) != 0 {
        return 0;
    }
    return file_id(str::from_cstr(&exe[0]));
}

/// A content hash of the file at `path`; 0 when it cannot be read or is empty. Four independent lanes
/// over 8-byte words keep the multiply chains parallel: about 1 ms per 10 MB.
pub fn file_id(path: str) u64 {
    let f = stdio::fopen(path, "rb");
    if f == null {
        return 0;
    }
    // Words, so the loads below are aligned.
    let mut buf = Array::<u64, 8192>::new();
    let bp = (&mut buf[0]) as *mut u64;
    let mut l0 = FNV_BASIS;
    let mut l1: u64 = 0x9e3779b97f4a7c15u64;
    let mut l2: u64 = 0xBF58476D1CE4E5B9u64;
    let mut l3: u64 = 0x94D049BB133111EBu64;
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
            l0 = (l0 ^ buf[i]).wrapping_mul(0x100000001b3u64);
            l1 = (l1 ^ buf[i + 1]).wrapping_mul(0x100000001b3u64);
            l2 = (l2 ^ buf[i + 2]).wrapping_mul(0x100000001b3u64);
            l3 = (l3 ^ buf[i + 3]).wrapping_mul(0x100000001b3u64);
            l0 = l0 ^ l0 >> 29;
            l1 = l1 ^ l1 >> 29;
            l2 = l2 ^ l2 >> 29;
            l3 = l3 ^ l3 >> 29;
            i += 4;
        }
    }
    let bad = unsafe stdio::ferror(f) != 0;
    unsafe stdio::fclose(f);
    if bad || tot == 0 {
        return 0;
    }
    let h = skey_mix(skey_mix(skey_mix(skey_mix(skey_mix(FNV_BASIS, l0), l1), l2), l3), tot);
    // 0 means "no identity"; a real hash never takes it.
    return h | (h == 0) as u64;
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
    let mut ptrs = Vector::<usize>::with_capacity(args.len() + 1);
    for i in 0..args.len() {
        ptrs.push(args[i].cstr() as usize);
    }
    ptrs.push(0);
    return unsafe shim::sc_exec_argv(ptrs.as_ptr() as *const *const char, log);
}

/// False when the file cannot be opened, or a short write or failed close left it incomplete.
pub fn write_file(path: str, body: str) bool {
    let f = stdio::fopen(path, "wb");
    if f == null {
        return false;
    }
    let n = unsafe stdio::fwrite(body.ptr(), 1, body.len(), f);
    let rc = unsafe stdio::fclose(f);
    return n == body.len() && rc == 0;
}

/// write_file through `<path>.tmp` and an atomic rename: an interrupted or failed write leaves `path`
/// as it was, never torn. False when any step fails. Compile, LTO-probe and stamp records ignore a
/// failure: an old or missing record only makes the next build redo that work.
pub fn write_file_atomic(path: str, body: str) bool {
    let mut tmp = String::from_str(path);
    tmp.push_str(".tmp");
    let mut dst = String::from_str(path);
    if write_file(tmp.as_str(), body) && unsafe shim::sc_rename(tmp.cstr(), dst.cstr()) == 0 {
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
        let nm = str::from_cstr(unsafe shim::sc_dirent_name(e));
        if nm.starts_with(".") && (!hidden || nm == "." || nm == "..") {
            continue;
        }
        names.push(String::from_str(nm));
    }
    unsafe shim::sc_closedir(dh);
    return Option::<Vector<String>>::Some(names);
}

/// Create `path` and any missing parent directories (like `mkdir -p`); existing dirs are ignored.
pub fn mkdir_p(path: str) {
    let n = path.len();
    if n == 0 || n >= 4096 {
        return;
    }
    let mut buf = Array::<char, 4096>::new();
    buf.copy_from(path.ptr(), n);
    buf[n] = 0 as char;
    let base = (&buf[0]) as *const char; // read-only C string view; the buffer is edited in place below
    for i in 1..n {
        if buf[i] == '/' as char {
            buf[i] = 0 as char;
            let _ = unsafe shim::sc_mkdir(base);
            buf[i] = '/' as char;
        }
    }
    let _ = unsafe shim::sc_mkdir(base);
}

/// Open `path` for writing, creating any missing parent directories when the first attempt
/// fails (the directories exist for all but the first file written into each).
pub fn open_out(path: str) *mut stdio::FILE {
    let f = stdio::fopen(path, "wb");
    if f != null {
        return f;
    }
    let p = path.ptr();
    let n = path.len();
    let mut slash: usize = n;
    for i in 0..n {
        if unsafe p[i] == b'/' {
            slash = i;
        }
    }
    if slash == n {
        return null;
    }
    mkdir_p(str::from_raw(p, slash));
    return stdio::fopen(path, "wb");
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
        if unsafe shim::sc_stat_isdir(path) != 0 {
            prune_dir(path, keep);
            let _ = unsafe shim::sc_rmdir(path);
            continue;
        }
        let l = unsafe cstring::strlen(name); // only generated .c/.h translation units are ours to prune
        if !(l >= 2 && unsafe name[l - 2] == '.' as char && (unsafe name[l - 1] == 'c' as char || unsafe name[l - 1] == 'h' as char)) {
            continue;
        }
        let ps = str::from_cstr(path);
        if !keep.contains(&ps) {
            let _ = unsafe shim::sc_unlink(path);
        }
    }
    let _ = unsafe shim::sc_closedir(d);
}

/// The runtime header shared by every generated module (the C standard library includes plus the
/// leak-tracker interposition), and the tracker's implementation TU the engine compiles alongside.
/// False, after a message, when either file cannot be written in full.
pub fn write_super_rt(gen_dir: str) bool {
    let mut path = build_out_path(gen_dir, "super_rt", ".h");
    let f = open_out(path.as_str());
    let mut ok = f != null;
    if ok {
        ok = unsafe stdio::fputs("#ifndef SUPER_RT_H\n#define SUPER_RT_H\n".ptr() as *const char, f) >= 0;
        ok = unsafe stdio::fputs(rtc::super_rt_includes(), f) >= 0 && ok;
        ok = unsafe stdio::fputs("#endif\n".ptr() as *const char, f) >= 0 && ok;
        ok = unsafe stdio::fclose(f) == 0 && ok;
    }
    if !ok {
        unsafe stdio::perror(path.cstr());
        return false;
    }
    let mut cpath = build_out_path(gen_dir, "super_rt", ".c");
    let cf = open_out(cpath.as_str());
    ok = cf != null;
    if ok {
        ok = unsafe stdio::fputs(rtc::super_rt_source(), cf) >= 0;
        ok = unsafe stdio::fclose(cf) == 0 && ok;
    }
    if !ok {
        unsafe stdio::perror(cpath.cstr());
    }
    return ok;
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
        let env = stdlib::getenv("CC");
        if env != null && unsafe *env != 0 as char {
            out.push_str(str::from_cstr(env));
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
        let mut ndk = stdlib::getenv("ANDROID_NDK_HOME");
        if ndk == null || unsafe *ndk == 0 as char {
            ndk = stdlib::getenv("ANDROID_NDK_ROOT");
        }
        if ndk == null || unsafe *ndk == 0 as char {
            return;
        }
        out.push_str(str::from_cstr(ndk));
        out.push_str("/toolchains/llvm/prebuilt/");
        out.push_str(ndk_host_tag());
        out.push_str("/bin/clang");
        return;
    }
    if sdk == 3 {
        // WebAssembly: the wasi-sdk's clang when present (it brings wasi-libc), else a plain clang,
        // which can only build freestanding code.
        let w = stdlib::getenv("WASI_SDK_PATH");
        if w != null && unsafe *w != 0 as char {
            out.push_str(str::from_cstr(w));
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
/// own defaults. Nothing here overrides the manifest: these come first, manifest flags after. Callers
/// split the result on whitespace (`split_args`), so no quoting: a sysroot path must hold no space.
pub fn push_sdk_flags(cmd: &mut String, sdk: i32, arch: i32) {
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
        let sdkp = stdlib::getenv("WASI_SDK_PATH");
        if sdkp != null && unsafe *sdkp != 0 as char {
            cmd.push_str(" -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS");
            cmd.push_str(" -target wasm32-wasip1 --sysroot=");
            cmd.push_str(str::from_cstr(sdkp));
            cmd.push_str("/share/wasi-sysroot");
            return;
        }
        let sr = stdlib::getenv("WASI_SYSROOT");
        if sr != null && unsafe *sr != 0 as char {
            cmd.push_str(" -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS");
            cmd.push_str(" -target wasm32-wasip1 --sysroot=");
            cmd.push_str(str::from_cstr(sr));
            return;
        }
        cmd.push_str(" -target wasm32 -nostdlib");
    }
}

/// Flags and libraries a cross target needs at LINK time only. wasi keeps signals and the process clock
/// behind opt-in emulation libraries; the runtime's panic path installs a signal handler and `time::clock`
/// reads the process clock (emulated by the wall clock), so the build asks for both. wasm-ld's default
/// stack is 64 KiB: a wasm program gets the 8 MiB main-thread stack of the native hosts instead, placed
/// first so an overflow traps rather than overwriting static data.
pub fn push_sdk_libs(cmd: &mut String, sdk: i32) {
    if sdk == 3 {
        cmd.push_str(" -Wl,-z,stack-size=8388608 -Wl,--stack-first");
        let sdkp = stdlib::getenv("WASI_SDK_PATH");
        let sr = stdlib::getenv("WASI_SYSROOT");
        if sdkp != null && unsafe *sdkp != 0 as char || sr != null && unsafe *sr != 0 as char {
            cmd.push_str(" -lwasi-emulated-signal -lwasi-emulated-process-clocks");
        }
    }
}
