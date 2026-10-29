// Stack: the task-local stack allocator. `Vector::<T, Stack>::new()`, and every other container that takes
// an `A: Allocator`, allocates from a region of the running task the way its `Global` version allocates
// from the C heap. Like `Global`, `Stack` is a zero-sized tag; unlike it, it is neither `Send` nor `Sync`,
// so a container that holds one stays in the task that made it.
//
// Each coroutine has its own region, made at its first `Stack` allocation and released when its body
// returns; a plain thread, and the data-parallel jobs a worker thread runs, share the thread's region,
// released when the thread exits. A region is an address range of REGION_BYTES bytes reserved without
// memory behind it; its pages are committed as its top grows, at least doubling each time. When frees
// bring the top below a quarter of the committed bytes (at least FIRST_COMMIT counted as used), the pages
// above twice the used bytes go back to the system: a container that grows and shrinks around one size
// does not commit and give back each time. The runtime keeps the current region (`sc_rt_stk_get`).
//
// - `alloc`: O(1) amortized, a bump of the top. Each block has a 16-byte header before it and is aligned
//   to its request, at least 8.
// - `dealloc`: O(1) amortized. Freeing the top block moves the top below it, and below every block under
//   it that was freed before; freeing another block only marks it. So blocks freed in reverse order of
//   allocation are reclaimed at once, and the others when every block above them is freed.
// - `realloc`: grows or shrinks the top block in place, and shrinks any other block in place; otherwise
//   a new top block, a copy, and the old block marked freed.
// - Zero-size requests take a header and return an aligned pointer with no memory behind it.
//
// Exhaustion: a region past REGION_BYTES panics, and so does a refused reservation or commit. The leak
// check does not see `Stack` blocks; `Stack::used` gives the bytes the current task holds. WebAssembly
// cannot reserve address ranges: there `Stack` takes its blocks from `Global`.
import sc_runtime;

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
}

/// The task-local stack allocator: a zero-sized tag, neither `Send` nor `Sync`.
@derive(Copy)
pub struct Stack {
    // A raw pointer type keeps `Stack` and its containers in their task; the array holds nothing.
    task_local: [*const u8; 0],
}

extend Stack {
    pub const fn new() Stack {
        return Stack { task_local: [] };
    }

    /// The bytes the current task (off the pool: the current thread) holds in its region, headers and
    /// alignment padding included; 0 when it has no region, and always on WebAssembly.
    @platform(!wasm)
    pub fn used() usize {
        let r = sc_runtime::sc_rt_stk_get() as *mut Region;
        if r == null {
            return 0;
        }
        return unsafe (*r).top - (r as usize + sizeof(Region));
    }
    @platform(wasm)
    pub fn used() usize {
        return 0;
    }
}

extend Stack as Default {
    pub const fn default() Stack {
        return Stack::new();
    }
}

@platform(!wasm)
extend Stack as Allocator {
    @always_inline
    pub unsafe fn alloc(self: &mut Stack, size: usize, align: usize) *mut void {
        return unsafe (*region()).alloc(size, align);
    }
    @always_inline
    pub unsafe fn realloc(self: &mut Stack, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        return unsafe (*region()).realloc(ptr, old_size, new_size, align);
    }
    @always_inline
    pub unsafe fn dealloc(self: &mut Stack, ptr: *mut void, _size: usize, _align: usize) {
        unsafe (*region()).dealloc(ptr);
    }
}

@platform(wasm)
extend Stack as Allocator {
    @always_inline
    pub unsafe fn alloc(self: &mut Stack, size: usize, align: usize) *mut void {
        let mut g = Global {};
        return unsafe g.alloc(size, align);
    }
    @always_inline
    pub unsafe fn realloc(self: &mut Stack, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        let mut g = Global {};
        return unsafe g.realloc(ptr, old_size, new_size, align);
    }
    @always_inline
    pub unsafe fn dealloc(self: &mut Stack, ptr: *mut void, size: usize, align: usize) {
        let mut g = Global {};
        unsafe g.dealloc(ptr, size, align);
    }
}

// The address range of one region: 4 GiB, so the 128 TiB of a 47-bit address space hold 32768 regions.
@platform(!wasm)
const REGION_BYTES: usize = 1 << 32;
// The bytes committed when a region is made.
@platform(!wasm)
const FIRST_COMMIT: usize = 1 << 16;
// The header before each block: the top before the block, then the start of the block below it (0 for
// none) with FREED set once the block is freed while it is not on top.
@platform(!wasm)
const HDR: usize = 2 * sizeof(usize);
@platform(!wasm)
const FREED: usize = 1;

// A region's state, at the start of its own address range.
@platform(!wasm)
struct Region {
    pub(module) len: usize, // the bytes of the range: first, where `sc_rt_stk_release` reads it
    pub(module) top: usize, // the end of the top block: the next free byte
    pub(module) last: usize, // the start of the top block; 0 when the region holds none
    pub(module) commit: usize, // the end of the committed bytes
}

// The current region, made at the first use.
@platform(!wasm)
@always_inline
fn region() *mut Region {
    let r = sc_runtime::sc_rt_stk_get() as *mut Region;
    if likely(r != null) {
        return r;
    }
    return region_new();
}

@platform(!wasm)
@noinline
fn region_new() *mut Region {
    let page = sc_runtime::sc_rt_page_size();
    let first = (FIRST_COMMIT + page - 1) / page * page;
    let p = unsafe sc_runtime::sc_rt_region_reserve(REGION_BYTES);
    if p == null {
        panic("Stack: cannot reserve the address range of a region");
    }
    if !unsafe sc_runtime::sc_rt_region_commit(p, first) {
        panic("Stack: out of memory");
    }
    let r = p as *mut Region;
    let base = p as usize;
    unsafe *r = Region { len: REGION_BYTES, top: base + sizeof(Region), last: 0, commit: base + first };
    unsafe sc_runtime::sc_rt_stk_adopt(p);
    return r;
}

@platform(!wasm)
extend Region {
    @always_inline
    unsafe fn alloc(self: &mut Region, size: usize, align: usize) *mut void {
        let a = align.max(8);
        let p = self.top + HDR + a - 1 & ~(a - 1);
        let limit = self.limit();
        if unlikely(p > limit || size > limit - p) {
            panic("Stack: the region is full");
        }
        let end = p + size;
        if unlikely(end > self.commit) {
            self.grow(end);
        }
        let h = (p - HDR) as *mut usize;
        unsafe *h = self.top;
        unsafe *(h + 1) = self.last;
        self.last = p;
        self.top = end;
        return p as *mut void;
    }

    @always_inline
    unsafe fn dealloc(self: &mut Region, ptr: *mut void) {
        // A null pointer (an empty container's) is no block, and `last` is 0 when the region holds none.
        let at = ptr as usize;
        if at == 0 {
            return;
        }
        if at == self.last {
            self.pop();
        } else {
            unsafe *((at - HDR) as *mut usize + 1) |= FREED;
        }
    }

    unsafe fn realloc(self: &mut Region, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        let at = ptr as usize;
        if at == 0 {
            return unsafe self.alloc(new_size, align);
        }
        if at == self.last {
            if new_size > self.limit() - at {
                panic("Stack: the region is full");
            }
            let end = at + new_size;
            if end > self.commit {
                self.grow(end);
            }
            self.top = end;
            if new_size < old_size {
                self.shrunk();
            }
            return ptr;
        }
        if new_size <= old_size {
            return ptr;
        }
        let q = unsafe self.alloc(new_size, align);
        unsafe memcpy(q, ptr, old_size);
        unsafe *((at - HDR) as *mut usize + 1) |= FREED;
        return q;
    }

    // One past the last byte of the range.
    const fn limit(self: &Region) usize {
        return (self as *const Region) as usize + self.len;
    }

    // Remove the top block, then each freed block that comes on top after it.
    fn pop(self: &mut Region) {
        loop {
            let h = (self.last - HDR) as *const usize;
            self.top = unsafe *h;
            self.last = unsafe *(h + 1) & ~FREED;
            if self.last == 0 || (unsafe *((self.last - HDR) as *const usize + 1) & FREED) == 0 {
                self.shrunk();
                return;
            }
        }
    }

    // The top went down: give pages back when the committed bytes pass four times the used ones.
    @always_inline
    fn shrunk(self: &mut Region) {
        let base = (self as *mut Region) as usize;
        let used = (self.top - base).max(FIRST_COMMIT);
        if unlikely(self.commit - base > 4 * used) {
            self.trim(used);
        }
    }

    // Keep twice `used` bytes committed, whole pages, and give the rest back.
    @noinline
    fn trim(self: &mut Region, used: usize) {
        let base = (self as *mut Region) as usize;
        let page = sc_runtime::sc_rt_page_size();
        let keep = (2 * used + page - 1) / page * page;
        unsafe sc_runtime::sc_rt_region_decommit((base + keep) as *mut void, self.commit - base - keep);
        self.commit = base + keep;
    }

    // Commit the pages up to `end`, and at least double the committed bytes.
    @noinline
    fn grow(self: &mut Region, end: usize) {
        let base = (self as *mut Region) as usize;
        let page = sc_runtime::sc_rt_page_size();
        let have = self.commit - base;
        let mut want = if have > self.len / 2 {
            self.len;
        } else {
            have * 2;
        };
        if want < end - base {
            want = (end - base + page - 1) / page * page;
        }
        if !unsafe sc_runtime::sc_rt_region_commit(self.commit as *mut void, want - have) {
            panic("Stack: out of memory");
        }
        self.commit = base + want;
    }
}
