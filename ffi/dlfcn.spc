// FFI bindings for dynamic loading APIs (<dlfcn.h>). Import with `import dlfcn;`.

extern "C" {
    pub fn dlopen(path: *const char, flags: i32) *mut void;
    pub fn dlsym(handle: *mut void, symbol: *const char) *mut void;
    pub fn dlclose(handle: *mut void) i32;
    pub fn dlerror() *const char;
}
