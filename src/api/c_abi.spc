// The stable C ABI of the compiler API (`sdk/libsuperc.h`): opaque sessions and results over the native
// facade, built into `libsuperc` by a library target whose root imports this module. Every function returns a
// status that maps one to one to `api::errors::Code` (0: success). A read takes the generation the caller
// read from `superc_session_generation`; one that is not the session's current generation is
// `SUPERC_STALE_HANDLE`, since C cannot borrow-check a view against a change. Strings are a pointer and a
// byte length, UTF-8; a result owns the strings its items point at until `superc_result_free`. The ABI is no
// security boundary: an embedder shares the compiler's address space.
import api::errors as *;
import api::session as ses;
import api::syntax as syn;
import api::semantic as sem;
import api::source as *;
import utils::diag_codes as dc;

/// The function table versions this library fills (`superc_api_table`).
pub const TABLE_V1: u32 = 1;

/// `superc_session`: a session and the message of its last failed call.
pub struct Handle {
    pub(module) s: ses::Session,
    pub(module) err: String,
}

// One item of a result: a location, a severity and code for a diagnostic, and a text.
pub(module) struct ResItem {
    pub file: String,
    pub start: u32,
    pub end: u32,
    pub severity: u32,
    pub code: u32,
    pub text: String,
}

/// `superc_result`: a text and items.
pub struct Res {
    pub(module) text: String,
    pub(module) items: Vector<ResItem>,
}

/// `superc_item`: what `superc_result_item` writes. The caller sets `size` to the size it was compiled with;
/// the library writes no field past it.
pub struct CItem {
    pub size: u32,
    pub api_version: u32,
    pub file: *const u8,
    pub file_len: usize,
    pub start: u32,
    pub end: u32,
    pub severity: u32,
    pub code: u32,
    pub text: *const u8,
    pub text_len: usize,
}

// The status of `code`: its position in `Code`, plus one (0 is success).
fn status(code: Code) i32 {
    return code as i32 + 1;
}

// A string view of C bytes `p[0..n]`; empty for a null pointer.
fn view<'a>(p: *const u8, n: usize) str<'a> {
    if p == null || n == 0 {
        return "";
    }
    return unsafe str::from_raw(p, n);
}

// `v` moved to the heap, as the handle C keeps.
fn to_heap<T>(v: T) *mut T {
    let mut g = Global {};
    let p = (unsafe g.alloc(sizeof(T), alignof(T))) as *mut T;
    unsafe p[0] = v;
    return p;
}

// The value of handle `p`, its heap block released.
fn from_heap<T>(p: *mut T) T {
    let v = unsafe p[0];
    let mut g = Global {};
    unsafe g.dealloc(p, sizeof(T), alignof(T));
    return v;
}

// Record `e` as handle `h`'s last error; its status.
fn fail(h: *mut Handle, e: ApiError) i32 {
    unsafe (*h).err = e.message.clone();
    return status(e.code);
}

// The result of `items` and `text` stored into `*out`; success.
fn give(out: *mut *mut Res, text: String, items: Vector<ResItem>) i32 {
    unsafe *out = to_heap(Res { text: text, items: items });
    return 0;
}

// Handle `h` at generation `gen`: success, else the status of a stale or missing handle.
fn current(h: *mut Handle, gen: u64) i32 {
    if h == null {
        return status(Code::InvalidArgument);
    }
    if unsafe (*h).s.revision() != gen {
        return fail(h, ApiError::new(Code::StaleHandle, "the generation is not the session's current one"));
    }
    return 0;
}

/// `superc_api_version`.
@export("superc_api_version")
pub fn api_version() u32 {
    return API_VERSION;
}

/// `superc_session_open_file`: a session over one file, std from `std_dir`.
@export("superc_session_open_file")
pub fn session_open_file(path: *const u8, path_len: usize, std_dir: *const u8, std_len: usize, out: *mut *mut Handle) i32 {
    if out == null {
        return status(Code::InvalidArgument);
    }
    return switch ses::Session::open_file(view(path, path_len), ses::Config::host(view(std_dir, std_len))) {
        Ok(s) => {
            unsafe *out = to_heap(Handle { s: s, err: String::new() });
            0;
        },
        Err(e) => status(e.code),
    };
}

/// `superc_session_open_project`: a session over the project in directory `dir`.
@export("superc_session_open_project")
pub fn session_open_project(dir: *const u8, dir_len: usize, std_dir: *const u8, std_len: usize, out: *mut *mut Handle) i32 {
    if out == null {
        return status(Code::InvalidArgument);
    }
    return switch ses::Session::open_project(view(dir, dir_len), ses::Config::host(view(std_dir, std_len))) {
        Ok(s) => {
            unsafe *out = to_heap(Handle { s: s, err: String::new() });
            0;
        },
        Err(e) => status(e.code),
    };
}

/// `superc_session_free`.
@export("superc_session_free")
pub fn session_free(h: *mut Handle) {
    if h != null {
        let _ = from_heap(h);
    }
}

/// `superc_session_generation`: the generation every read names; a change makes a new one.
@export("superc_session_generation")
pub fn session_generation(h: *const Handle) u64 {
    if h == null {
        return 0;
    }
    return unsafe (*h).s.revision();
}

/// `superc_session_set_text`: give file `path` the text `text`; its new version into `*version` (may be null).
@export("superc_session_set_text")
pub fn session_set_text(
    h: *mut Handle,
    path: *const u8,
    path_len: usize,
    text: *const u8,
    text_len: usize,
    version: *mut i64,
) i32 {
    if h == null {
        return status(Code::InvalidArgument);
    }
    let v = unsafe (*h).s.set_text(view(path, path_len), view(text, text_len));
    if version != null {
        unsafe *version = v;
    }
    return 0;
}

/// `superc_session_check`: analyze the current inputs.
@export("superc_session_check")
pub fn session_check(h: *mut Handle) i32 {
    if h == null {
        return status(Code::InvalidArgument);
    }
    return switch unsafe (*h).s.check() {
        Ok(_) => 0,
        Err(e) => fail(h, e),
    };
}

/// `superc_session_error`: the message of the session's last failed call.
@export("superc_session_error")
pub fn session_error(h: *mut Handle, out: *mut *mut Res) i32 {
    if h == null || out == null {
        return status(Code::InvalidArgument);
    }
    return give(out, unsafe (*h).err.clone(), Vector::<ResItem>::new());
}

/// `superc_session_diagnostics`: the diagnostics of the last check at generation `gen`, one item each.
@export("superc_session_diagnostics")
pub fn session_diagnostics(h: *mut Handle, gen: u64, out: *mut *mut Res) i32 {
    let st = current(h, gen);
    if st != 0 || out == null {
        return pick_status(st);
    }
    let mut items = Vector::<ResItem>::new();
    switch unsafe (*h).s.diagnostics() {
        Ok(ds) => {
            for d in ds {
                items.push(
                    ResItem {
                        file: String::from_str(d.file()),
                        start: d.start(),
                        end: d.end(),
                        severity: d.severity(),
                        code: d.code(),
                        text: String::from_str(d.message()),
                    },
                );
            }
        },
        Err(e) => {
            return fail(h, e);
        },
    };
    return give(out, String::new(), items);
}

// A failed precondition's status, or the invalid-argument status for a missing out-parameter.
fn pick_status(st: i32) i32 {
    if st != 0 {
        return st;
    }
    return status(Code::InvalidArgument);
}

/// `superc_session_symbol_at`: the declaration named at `offset` of `file` at generation `gen`: one item
/// (its declaration's location, its name as text), or none.
@export("superc_session_symbol_at")
pub fn session_symbol_at(h: *mut Handle, gen: u64, file: *const u8, file_len: usize, offset: u32, out: *mut *mut Res) i32 {
    let st = current(h, gen);
    if st != 0 || out == null {
        return pick_status(st);
    }
    let mut items = Vector::<ResItem>::new();
    let mut sig = String::new();
    switch sem::symbol_at(unsafe &(*h).s, view(file, file_len), offset) {
        Ok(Some(y)) => {
            sig = y.signature();
            if let Some(l) = y.location() {
                items.push(
                    ResItem { file: l.file.clone(), start: l.start, end: l.end, text: String::from_str(y.name()) },
                );
            }
        },
        Ok(None) => {},
        Err(e) => {
            return fail(h, e);
        },
    };
    return give(out, sig, items);
}

/// `superc_session_references`: every reference to the declaration named at `offset` of `file`, its own
/// name included, at generation `gen`; one item each.
@export("superc_session_references")
pub fn session_references(h: *mut Handle, gen: u64, file: *const u8, file_len: usize, offset: u32, out: *mut *mut Res) i32 {
    let st = current(h, gen);
    if st != 0 || out == null {
        return pick_status(st);
    }
    let opts = ses::RequestOptions::none();
    let mut items = Vector::<ResItem>::new();
    switch sem::references_at(unsafe &mut (*h).s, view(file, file_len), offset, true, &opts) {
        Ok(ls) => {
            for i in 0..ls.len() {
                items.push(ResItem { file: ls[i].file.clone(), start: ls[i].start, end: ls[i].end });
            }
        },
        Err(e) => {
            return fail(h, e);
        },
    };
    return give(out, String::new(), items);
}

/// `superc_format`: `text` in the canonical format; the result's text.
@export("superc_format")
pub fn format_text(text: *const u8, text_len: usize, out: *mut *mut Res) i32 {
    if out == null {
        return status(Code::InvalidArgument);
    }
    return switch syn::format_file("<text>", view(text, text_len), 120) {
        Ok(t) => give(out, t, Vector::<ResItem>::new()),
        Err(e) => status(e.code),
    };
}

/// `superc_result_count`.
@export("superc_result_count")
pub fn result_count(r: *const Res) usize {
    if r == null {
        return 0;
    }
    return unsafe (*r).items.len();
}

/// `superc_result_text`: the result's text; valid until the result is freed.
@export("superc_result_text")
pub fn result_text(r: *const Res, ptr: *mut *const u8, len: *mut usize) {
    if r == null || ptr == null || len == null {
        return;
    }
    unsafe *ptr = unsafe (*r).text.as_ptr();
    unsafe *len = unsafe (*r).text.len();
}

/// `superc_result_item`: item `i` into `*item`, whose `size` the caller set; strings valid until the result is
/// freed.
@export("superc_result_item")
pub fn result_item(r: *const Res, i: usize, item: *mut CItem) i32 {
    if r == null || item == null || i >= unsafe (*r).items.len() || (unsafe (*item).size) as usize < sizeof(CItem) {
        return status(Code::InvalidArgument);
    }
    let it = unsafe &(*r).items[i];
    unsafe *item = CItem {
        size: sizeof(CItem) as u32,
        api_version: API_VERSION,
        file: it.file.as_ptr(),
        file_len: it.file.len(),
        start: it.start,
        end: it.end,
        severity: it.severity,
        code: it.code,
        text: it.text.as_ptr(),
        text_len: it.text.len(),
    };
    return 0;
}

/// `superc_result_free`.
@export("superc_result_free")
pub fn result_free(r: *mut Res) {
    if r != null {
        let _ = from_heap(r);
    }
}

/// `superc_code_name`: the stable name of diagnostic code `code` (empty for an unknown one); static storage.
@export("superc_code_name")
pub fn code_name(code: u32, ptr: *mut *const u8, len: *mut usize) {
    if ptr == null || len == null {
        return;
    }
    let n = if code <= 0xFFFF {
        dc::name(code as u16);
    } else {
        "";
    };
    unsafe *ptr = n.ptr();
    unsafe *len = n.len();
}

/// `superc_api_v1`: the version 1 function table.
pub struct TableV1 {
    pub size: u32,
    pub version: u32,
    pub api_version: fn() u32,
    pub session_open_file: fn(*const u8, usize, *const u8, usize, *mut *mut Handle) i32,
    pub session_open_project: fn(*const u8, usize, *const u8, usize, *mut *mut Handle) i32,
    pub session_free: fn(*mut Handle),
    pub session_generation: fn(*const Handle) u64,
    pub session_set_text: fn(*mut Handle, *const u8, usize, *const u8, usize, *mut i64) i32,
    pub session_check: fn(*mut Handle) i32,
    pub session_error: fn(*mut Handle, *mut *mut Res) i32,
    pub session_diagnostics: fn(*mut Handle, u64, *mut *mut Res) i32,
    pub session_symbol_at: fn(*mut Handle, u64, *const u8, usize, u32, *mut *mut Res) i32,
    pub session_references: fn(*mut Handle, u64, *const u8, usize, u32, *mut *mut Res) i32,
    pub format: fn(*const u8, usize, *mut *mut Res) i32,
    pub result_count: fn(*const Res) usize,
    pub result_text: fn(*const Res, *mut *const u8, *mut usize),
    pub result_item: fn(*const Res, usize, *mut CItem) i32,
    pub result_free: fn(*mut Res),
    pub code_name: fn(u32, *mut *const u8, *mut usize),
}

/// `superc_api_table`: fill the function table of `version` at `table` (`size` bytes, at least the table's
/// size): `SUPERC_VERSION_MISMATCH` for a version this library does not fill. A table of a newer minor version
/// only appends functions, so a client compiled against an older header reads the prefix it knows.
@export("superc_api_table")
pub fn api_table(version: u32, table: *mut TableV1, size: usize) i32 {
    if version != TABLE_V1 {
        return status(Code::VersionMismatch);
    }
    if table == null || size < sizeof(TableV1) {
        return status(Code::InvalidArgument);
    }
    unsafe *table = TableV1 {
        size: sizeof(TableV1) as u32,
        version: TABLE_V1,
        api_version: api_version,
        session_open_file: session_open_file,
        session_open_project: session_open_project,
        session_free: session_free,
        session_generation: session_generation,
        session_set_text: session_set_text,
        session_check: session_check,
        session_error: session_error,
        session_diagnostics: session_diagnostics,
        session_symbol_at: session_symbol_at,
        session_references: session_references,
        format: format_text,
        result_count: result_count,
        result_text: result_text,
        result_item: result_item,
        result_free: result_free,
        code_name: code_name,
    };
    return 0;
}
