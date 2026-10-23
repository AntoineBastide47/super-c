// Dynamic libraries of std::platform: load a shared library, look up a symbol's address, unload it
// (dlopen, dlsym and dlclose on POSIX, `ffi/dlfcn.spc`; LoadLibraryW, GetProcAddress and FreeLibrary on
// Windows). Every call is `unsafe`: loading runs the library's initializers, and an address is only as
// valid as the caller's idea of its type. WASI cannot load code: there `open` is Unsupported. Unstable,
// internal to std and the compiler.
@platform(macos | ios | linux | android)
import dlfcn;
import std::platform::error;
import std::platform::path;

@platform(windows)
extern "C" "windows.h" {
    fn LoadLibraryW(path: *const u16) *mut void;
    // `INT_PTR (WINAPI *)(void)`: any symbol's address, read through `ProcBits`.
    @layout(8, 8)
    type FARPROC;
    fn GetProcAddress(module: *mut void, name: *const char) FARPROC;
    fn FreeLibrary(module: *mut void) i32;
}

// The address GetProcAddress returns, as a data pointer.
@platform(windows)
union ProcBits {
    pub h: FARPROC,
    pub p: *mut void,
}

/// A loaded library. Dropping it unloads it: every address taken from it is then dangling.
@no_const
pub struct Library {
    handle: *mut void,
}

/// Load the library at `path` (its name alone searches the system's library path), resolving every
/// symbol now, its symbols local to it. Other: the loader refused, with no error number on POSIX.
/// Safety: the library's initializers run in this process.
@platform(macos | ios | linux | android)
pub unsafe fn open(path: str) Result<Library, IoError> {
    let np = path::native(path, IoOp::LoadLibrary)?;
    let h = unsafe dlfcn::dlopen(np.ptr(), dlfcn::RTLD_NOW | dlfcn::RTLD_LOCAL);
    if h == null {
        return Result::<Library, IoError>::Err(IoError::new(IoErrorKind::Other, IoOp::LoadLibrary));
    }
    return Result::<Library, IoError>::Ok(Library::adopt(h));
}
/// Load the library at `path` (its name alone searches the system's library path), resolving every
/// symbol now, its symbols local to it. Other: the loader refused, with no error number on POSIX.
/// Safety: the library's initializers run in this process.
@platform(windows)
pub unsafe fn open(path: str) Result<Library, IoError> {
    let np = path::native(path, IoOp::LoadLibrary)?;
    let h = unsafe LoadLibraryW(np.ptr());
    if h == null {
        return Result::<Library, IoError>::Err(error::last_error(IoOp::LoadLibrary));
    }
    return Result::<Library, IoError>::Ok(Library::adopt(h));
}
/// Load a library. Unsupported: WASI cannot load code.
/// Safety: the library's initializers run in this process.
@platform(wasm)
pub unsafe fn open(_path: str) Result<Library, IoError> {
    return Result::<Library, IoError>::Err(error::unsupported(IoOp::LoadLibrary));
}

extend Library {
    @platform(!wasm)
    fn adopt(handle: *mut void) Library {
        return Library { handle: handle };
    }

    /// The address of symbol `name`; NotFound when the library does not define it.
    /// Safety: the caller uses the address as the type the library gives the symbol, only while the
    /// library stays loaded.
    @platform(macos | ios | linux | android)
    pub unsafe fn symbol(self: &Library, name: str) Result<*mut void, IoError> {
        let n = path::native(name, IoOp::Symbol)?;
        let p = unsafe dlfcn::dlsym(self.handle, n.ptr());
        if p == null {
            return Result::<*mut void, IoError>::Err(IoError::new(IoErrorKind::NotFound, IoOp::Symbol));
        }
        return Result::<*mut void, IoError>::Ok(p);
    }
    /// The address of symbol `name`; NotFound when the library does not define it.
    /// Safety: the caller uses the address as the type the library gives the symbol, only while the
    /// library stays loaded.
    @platform(windows)
    pub unsafe fn symbol(self: &Library, name: str) Result<*mut void, IoError> {
        // GetProcAddress takes the symbol's bytes, not UTF-16.
        let mut n = String::from_str(name);
        if name.find_byte(0) >= 0 {
            return Result::<*mut void, IoError>::Err(IoError::new(IoErrorKind::InvalidInput, IoOp::Symbol));
        }
        let p = ProcBits { h: unsafe GetProcAddress(self.handle, n.cstr()) }.p;
        if p == null {
            return Result::<*mut void, IoError>::Err(error::last_error(IoOp::Symbol));
        }
        return Result::<*mut void, IoError>::Ok(p);
    }
    /// The address of symbol `name`. Unsupported on WASI, where no library loads.
    /// Safety: as on the other targets.
    @platform(wasm)
    pub unsafe fn symbol(self: &Library, _name: str) Result<*mut void, IoError> {
        return Result::<*mut void, IoError>::Err(error::unsupported(IoOp::Symbol));
    }
}

extend Library {
    /// Unload the library and report a refusal (Other on POSIX, which gives no error number), which
    /// dropping it ignores.
    /// Safety: no address taken from the library is used afterwards.
    @platform(macos | ios | linux | android)
    pub unsafe fn close(self: Library) Result<Unit, IoError> {
        let h = self.handle;
        forget(self);
        if unsafe dlfcn::dlclose(h) != 0 {
            return Result::<Unit, IoError>::Err(IoError::new(IoErrorKind::Other, IoOp::Close));
        }
        return Result::<Unit, IoError>::Ok(Unit {});
    }
    /// Unload the library and report a refusal (Other on POSIX, which gives no error number), which
    /// dropping it ignores.
    /// Safety: no address taken from the library is used afterwards.
    @platform(windows)
    pub unsafe fn close(self: Library) Result<Unit, IoError> {
        let h = self.handle;
        forget(self);
        if unsafe FreeLibrary(h) == 0 {
            return Result::<Unit, IoError>::Err(error::last_error(IoOp::Close));
        }
        return Result::<Unit, IoError>::Ok(Unit {});
    }
    /// Unload the library. Unsupported on WASI, where no library loads.
    /// Safety: as on the other targets.
    @platform(wasm)
    pub unsafe fn close(self: Library) Result<Unit, IoError> {
        forget(self);
        return Result::<Unit, IoError>::Err(error::unsupported(IoOp::Close));
    }
}

extend Library as Free {
    @platform(macos | ios | linux | android)
    pub fn free(self: &mut Library) {
        let _ = unsafe dlfcn::dlclose(self.handle);
    }
    @platform(windows)
    pub fn free(self: &mut Library) {
        let _ = unsafe FreeLibrary(self.handle);
    }
    @platform(wasm)
    pub fn free(self: &mut Library) {}
}
