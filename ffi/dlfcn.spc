// FFI bindings for dynamic loading APIs (<dlfcn.h>). Import with `import dlfcn;`.
//
// The constants are `extern` (no initializer): each binds to the real `<dlfcn.h>` macro, so the platform's
// own values are used rather than hardcoded numbers. They are runtime flag values (e.g.
// `dlopen(p, RTLD_NOW | RTLD_GLOBAL)`), not Super-C constant expressions.

extern "C" "dlfcn.h" {
    pub fn dlopen(path: *const char, flags: i32) *mut void;
    pub fn dlsym(handle: *mut void, symbol: *const char) *mut void;
    pub fn dlclose(handle: *mut void) i32;
    pub fn dlerror() *const char;

    // Binding mode (exactly one).
    pub const RTLD_LAZY: i32;
    pub const RTLD_NOW: i32;

    // Symbol scope.
    pub const RTLD_GLOBAL: i32;
    pub const RTLD_LOCAL: i32;
}
