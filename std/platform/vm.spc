// Virtual memory of std::platform: the page size, and address ranges reserved without memory behind them,
// then committed, protected and released page by page (mmap, mprotect and munmap on POSIX; VirtualAlloc,
// VirtualProtect and VirtualFree on Windows). WASI has one linear memory and no such calls: there every
// reservation is Unsupported. Unstable, internal to std and the compiler.
import sc_runtime;
import std::platform::error;

@platform(macos | ios | linux | android)
extern "C" "sys/mman.h" {
    fn mmap(addr: *mut void, len: usize, prot: i32, flags: i32, fd: i32, off: i64) *mut void;
    fn munmap(addr: *mut void, len: usize) i32;
    fn mprotect(addr: *mut void, len: usize, prot: i32) i32;
    const PROT_NONE: i32 = 0;
    const PROT_READ: i32 = 1;
    const PROT_WRITE: i32 = 2;
    const MAP_PRIVATE: i32 = 2;
    @platform(linux | android)
    @import("MAP_ANONYMOUS")
    const MAP_ANON: i32 = 0x20;
}

// <sys/mman.h> defines MAP_ANON on Darwin only above the build's strict POSIX level.
@platform(macos | ios)
const MAP_ANON: i32 = 0x1000;

@platform(windows)
extern "C" "windows.h" {
    fn VirtualAlloc(addr: *mut void, size: usize, kind: u32, protect: u32) *mut void;
    fn VirtualFree(addr: *mut void, size: usize, kind: u32) i32;
    // The old protection goes to a DWORD: a `*mut void`, converted through `void *`.
    fn VirtualProtect(addr: *mut void, size: usize, protect: u32, old: *mut void) i32;
    const MEM_COMMIT: u32 = 0x1000;
    const MEM_RESERVE: u32 = 0x2000;
    const MEM_RELEASE: u32 = 0x8000;
    const PAGE_NOACCESS: u32 = 1;
    const PAGE_READONLY: u32 = 2;
    const PAGE_READWRITE: u32 = 4;
}

/// The access a range of pages allows.
@derive(Eq, Format)
pub enum Protection {
    None,
    Read,
    ReadWrite,
}

/// A reserved address range, a whole number of pages, that no other mapping overlaps. Released when it is
/// dropped; pointers into it are then dangling.
@no_const
pub struct Mapping {
    ptr: *mut u8,
    len: usize,
}

/// The size of a page, in bytes: the unit of every range of this module (65536 on WASI).
pub fn page_size() Result<usize, IoError> {
    return Ok(sc_runtime::sc_rt_page_size());
}

/// Reserve `len` bytes of address space (rounded up to whole pages) with no access and no memory
/// committed behind them. InvalidInput for a zero length.
pub fn reserve(len: usize) Result<Mapping, IoError> {
    let page = sc_runtime::sc_rt_page_size();
    if len == 0 || len > usize::MAX - page {
        return Err(IoError::new(IoErrorKind::InvalidInput, IoOp::Reserve));
    }
    let size = (len + page - 1) / page * page;
    let p = os_reserve(size);
    if p == null {
        return Err(reserve_error());
    }
    return Ok(Mapping::adopt(p as *mut u8, size));
}

@platform(macos | ios | linux | android)
fn os_reserve(size: usize) *mut void {
    let p = unsafe mmap(null, size, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if p as isize == -1 {
        return null;
    }
    return p;
}
@platform(windows)
fn os_reserve(size: usize) *mut void {
    return unsafe VirtualAlloc(null, size, MEM_RESERVE, PAGE_NOACCESS);
}
@platform(wasm)
fn os_reserve(_size: usize) *mut void {
    return null;
}

@platform(!wasm)
fn reserve_error() IoError {
    return error::last_error(IoOp::Reserve);
}
@platform(wasm)
fn reserve_error() IoError {
    return error::unsupported(IoOp::Reserve);
}

extend Mapping {
    fn adopt(ptr: *mut u8, len: usize) Mapping {
        return Mapping { ptr: ptr, len: len };
    }
    /// The first byte of the range.
    pub fn as_ptr(self: &Mapping) *mut u8 {
        return self.ptr;
    }
    /// The size of the range in bytes, a multiple of the page size.
    pub fn len(self: &Mapping) usize {
        return self.len;
    }
    /// Back the pages `[offset, offset + len)` with zero-filled memory that can be read and written.
    /// Panics: the bounds are not page-aligned or leave the range.
    pub fn commit(self: &mut Mapping, offset: usize, len: usize) Result<Unit, IoError> {
        self.check(offset, len);
        return self.os_commit(offset, len);
    }
    /// Set the access of the committed pages `[offset, offset + len)`.
    /// Panics: the bounds are not page-aligned or leave the range.
    pub fn protect(self: &mut Mapping, offset: usize, len: usize, prot: Protection) Result<Unit, IoError> {
        self.check(offset, len);
        return self.os_protect(offset, len, prot);
    }

    fn check(self: &Mapping, offset: usize, len: usize) {
        let page = sc_runtime::sc_rt_page_size();
        assert(offset % page == 0, "vm: offset is not page-aligned");
        assert(len % page == 0, "vm: length is not a whole number of pages");
        assert(offset <= self.len && len <= self.len - offset, "vm: range leaves the mapping");
    }

    @platform(macos | ios | linux | android)
    fn os_commit(self: &mut Mapping, offset: usize, len: usize) Result<Unit, IoError> {
        return self.os_protect(offset, len, Protection::ReadWrite);
    }
    @platform(windows)
    fn os_commit(self: &mut Mapping, offset: usize, len: usize) Result<Unit, IoError> {
        if unsafe VirtualAlloc(unsafe (self.ptr + offset), len, MEM_COMMIT, PAGE_READWRITE) == null {
            return Err(error::last_error(IoOp::Commit));
        }
        return Ok(Unit {});
    }
    @platform(wasm)
    fn os_commit(self: &mut Mapping, _offset: usize, _len: usize) Result<Unit, IoError> {
        return Result::<Unit, IoError>::Err(error::unsupported(IoOp::Commit));
    }

    @platform(macos | ios | linux | android)
    fn os_protect(self: &mut Mapping, offset: usize, len: usize, prot: Protection) Result<Unit, IoError> {
        let p = switch prot {
            None => PROT_NONE,
            Read => PROT_READ,
            ReadWrite => PROT_READ | PROT_WRITE,
        };
        if unsafe mprotect(unsafe (self.ptr + offset), len, p) != 0 {
            return Err(error::last_error(IoOp::Protect));
        }
        return Ok(Unit {});
    }
    @platform(windows)
    fn os_protect(self: &mut Mapping, offset: usize, len: usize, prot: Protection) Result<Unit, IoError> {
        let p = switch prot {
            None => PAGE_NOACCESS,
            Read => PAGE_READONLY,
            ReadWrite => PAGE_READWRITE,
        };
        let mut old: u32 = 0;
        if unsafe VirtualProtect(unsafe (self.ptr + offset), len, p, &mut old) == 0 {
            return Err(error::last_error(IoOp::Protect));
        }
        return Ok(Unit {});
    }
    @platform(wasm)
    fn os_protect(self: &mut Mapping, _offset: usize, _len: usize, _prot: Protection) Result<Unit, IoError> {
        return Result::<Unit, IoError>::Err(error::unsupported(IoOp::Protect));
    }
}

extend Mapping as Free {
    // A failed release leaves the range mapped: a reservation that cannot be returned is corrupt state.
    @platform(macos | ios | linux | android)
    pub fn free(self: &mut Mapping) {
        if unsafe munmap(self.ptr, self.len) != 0 {
            panic("vm: cannot release a reserved range");
        }
    }
    @platform(windows)
    pub fn free(self: &mut Mapping) {
        if unsafe VirtualFree(self.ptr, 0, MEM_RELEASE) == 0 {
            panic("vm: cannot release a reserved range");
        }
    }
    @platform(wasm)
    pub fn free(self: &mut Mapping) {}
}
