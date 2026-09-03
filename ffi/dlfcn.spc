// FFI bindings for dynamic loading APIs (<dlfcn.h>). Import with `import dlfcn;`.
// Carries `@c.link("dl")` (links libdl); every call site requires `unsafe`.
//
// The constants are `extern` (no initializer): each binds to the real `<dlfcn.h>` macro, so the platform's
// own values are used rather than hardcoded numbers. They are runtime flag values (e.g.
// `dlopen(p, RTLD_NOW | RTLD_GLOBAL)`), not Super-C constant expressions.

@c.link("dl")
extern "C" "dlfcn.h" {
    /// Load a shared library; null on failure (see dlerror). `path` is NUL-terminated.
    pub fn dlopen(path: *const char, flags: i32) *mut void;
    /// Address of `symbol` in `handle`; null when absent.
    pub fn dlsym(handle: *mut void, symbol: *const char) *mut void;
    /// Release a handle; 0 on success.
    pub fn dlclose(handle: *mut void) i32;
    /// The last dl* error message (owned by libc, invalidated by the next call), or null.
    pub fn dlerror() *const char;

    /// Binding mode (exactly one).
    pub const RTLD_LAZY: i32;
    /// Resolve every symbol at load time.
    pub const RTLD_NOW: i32;

    /// Symbol scope.
    pub const RTLD_GLOBAL: i32;
    /// Keep the library's symbols out of the global namespace.
    pub const RTLD_LOCAL: i32;
}
