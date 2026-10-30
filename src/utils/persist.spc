// Binary save and load of compiler state, for the checked prelude image (`driver::prelude_image`).
// A type conforms with `extend T as Persist {}`: its fields save in declaration order through their
// own conformances (the `fields` binder). A type of plain data (no pointer, no owning field) declares
// `plain()` true and saves its bytes as they are (`save_bytes`), which is also what a vector of it does
// in one copy.
// Raw pointers have no conformance: a type holding one writes its own `save` and `load`, or keeps the
// pointer in a wrapper that does. The image is only ever read by the compiler binary that wrote it.
import string as cstring;
import std::mem::cell;

/// The image being written. A sizing writer writes nothing and counts the bytes a save gives
/// (`len`), so the save can then write into one allocation of that size.
pub(package) struct Writer {
    pub(package) buf: String,
    sizing: bool,
    size: usize,
}

extend Writer {
    pub(package) fn new() Writer {
        return Writer { buf: String::new(), sizing: false, size: 0 };
    }

    /// A writer that only counts.
    pub(package) fn sizing() Writer {
        return Writer { buf: String::new(), sizing: true, size: 0 };
    }

    /// The bytes written (counted, for a sizing writer).
    pub(package) const fn len(self: &Writer) usize {
        if self.sizing {
            return self.size;
        }
        return self.buf.len();
    }

    /// Append the `n` bytes at `p`.
    pub(package) fn bytes(self: &mut Writer, p: *const u8, n: usize) {
        if self.sizing {
            self.size += n;
            return;
        }
        self.buf.push_str(unsafe str::from_raw(p, n));
    }

    /// Append `v`, little-endian.
    pub(package) fn u64(self: &mut Writer, v: u64) {
        if self.sizing {
            self.size += 8;
            return;
        }
        for i in 0..8 {
            self.buf.push_byte((v >> (i * 8) as u64) as u8);
        }
    }

    /// Pad to a multiple of 16 bytes, so the bytes that follow can be read in place.
    pub(package) fn align(self: &mut Writer) {
        if self.sizing {
            self.size = (self.size + 15) / 16 * 16;
            return;
        }
        while self.buf.len() % 16 != 0 {
            self.buf.push_byte(0);
        }
    }
}

/// The image being read: `buf[0..len]`, from `at` on. `ok` turns false at the first read past the
/// end; every read after it yields zero bytes, and the caller discards the result.
pub(package) struct Reader {
    buf: *const u8,
    len: usize,
    at: usize,
    pub(package) ok: bool,
}

extend Reader {
    /// A reader over the `len` bytes at `buf`, which must be 16-byte aligned.
    pub(package) const fn new(buf: *const u8, len: usize) Reader {
        return Reader { buf: buf, len: len, at: 0, ok: true };
    }

    /// The bytes not read yet.
    pub(package) const fn left(self: &Reader) usize {
        return self.len - self.at;
    }

    /// The `n` bytes at the read position, in place, and step past them; null past the end.
    pub(package) const fn view(self: &mut Reader, n: usize) *const u8 {
        if !self.ok || n > self.len - self.at {
            self.ok = false;
            return null;
        }
        let p = unsafe (self.buf + self.at);
        self.at += n;
        return p;
    }

    /// Copy the next `n` bytes to `p`; zeros past the end.
    pub(package) const fn bytes(self: &mut Reader, p: *mut u8, n: usize) {
        let src = self.view(n);
        if src == null {
            unsafe cstring::memset(p, 0, n);
            return;
        }
        unsafe cstring::memcpy(p, src, n);
    }

    /// The next 8 bytes as a little-endian `u64`; 0 past the end.
    pub(package) const fn u64(self: &mut Reader) u64 {
        let p = self.view(8);
        let mut v: u64 = 0;
        if p != null {
            for i in 0..8 {
                v = v | (unsafe *(p + i)) as u64 << (i * 8) as u64;
            }
        }
        return v;
    }

    /// Skip the writer's padding to a multiple of 16 bytes.
    pub(package) const fn align(self: &mut Reader) {
        let pad = (16 - self.at % 16) % 16;
        let _ = self.view(pad);
    }
}

/// Binary save and load (see the module comment). `load` fills a value that starts as all-zero
/// bytes (`zeroed`), which releasing leaves as a no-op for every owning std type. The defaults save and
/// load field by field; a plain type overrides all three with `save_bytes` and `load_bytes`.
pub(package) interface Persist {
    /// Whether the type is plain data: no pointer and no owning field, so its bytes are its value.
    fn plain() bool {
        return false;
    }

    fn save(self: &Self, w: &mut Writer) {
        save_fields(self, w);
    }

    fn load(self: &mut Self, r: &mut Reader) {
        load_fields(self, r);
    }
}

/// Save the bytes of plain value `v`.
pub(package) fn save_bytes<T>(v: &T, w: &mut Writer) {
    w.bytes((v as *const T) as *const u8, sizeof(T));
}

/// Load the bytes of plain value `v`.
pub(package) const fn load_bytes<T>(v: &mut T, r: &mut Reader) {
    r.bytes((v as *mut T) as *mut u8, sizeof(T));
}

/// Save every field of `v` in declaration order.
pub(package) fn save_fields<T>(v: &T, w: &mut Writer) {
    inline for f in fields(v) {
        save_one(&f.value, w);
    }
}

/// Load every field of `v` in declaration order.
pub(package) fn load_fields<T>(v: &mut T, r: &mut Reader) {
    inline for f in fields(v) {
        load_one(&mut f.value, r);
    }
}

/// Save `v`.
pub(package) fn save_one<V: Persist>(v: &V, w: &mut Writer) {
    v.save(w);
}

/// Load into `v`.
pub(package) fn load_one<V: Persist>(v: &mut V, r: &mut Reader) {
    v.load(r);
}

/// A loaded value of `V`.
pub(package) fn load_new<V: Persist>(r: &mut Reader) V {
    let mut v = unsafe zeroed::<V>();
    v.load(r);
    return v;
}

extend u8 as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &u8, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut u8, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend u16 as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &u16, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut u16, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend u32 as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &u32, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut u32, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend u64 as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &u64, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut u64, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend usize as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &usize, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut usize, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend i8 as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &i8, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut i8, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend i16 as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &i16, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut i16, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend i32 as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &i32, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut i32, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend i64 as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &i64, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut i64, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend isize as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &isize, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut isize, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend bool as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &bool, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut bool, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend f32 as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &f32, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut f32, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend f64 as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &f64, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut f64, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend char as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &char, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut char, r: &mut Reader) {
        load_bytes(self, r);
    }
}

extend<T: Persist> Vector<T> as Persist {
    fn save(self: &Vector<T>, w: &mut Writer) {
        w.u64(self.len() as u64);
        if T::plain() {
            w.align();
            w.bytes(self.as_ptr() as *const u8, self.len() * sizeof(T));
            return;
        }
        for i in 0..self.len() {
            self.at(i).save(w);
        }
    }

    fn load(self: &mut Vector<T>, r: &mut Reader) {
        let n = r.u64() as usize;
        if T::plain() {
            r.align();
            // A count past the image is corrupt: no allocation is sized by it.
            if sizeof(T) != 0 && n > r.left() / sizeof(T) {
                r.ok = false;
                return;
            }
            let p = r.view(n * sizeof(T)) as *const T;
            if p == null && n != 0 {
                return;
            }
            *self = Vector::<T>::with_capacity(n);
            for i in 0..n {
                self.push(unsafe *(p + i));
            }
            return;
        }
        if n > r.left() {
            r.ok = false;
            return;
        }
        *self = Vector::<T>::with_capacity(n);
        for _ in 0..n {
            let e = load_new::<T>(r);
            self.push(e);
        }
    }
}

extend String as Persist {
    fn save(self: &String, w: &mut Writer) {
        w.u64(self.len() as u64);
        w.bytes(self.as_str().ptr(), self.len());
    }

    fn load(self: &mut String, r: &mut Reader) {
        let n = r.u64() as usize;
        let p = r.view(n);
        if p == null {
            return;
        }
        *self = String::from_str(unsafe str::from_raw(p, n));
    }
}

extend<K: Persist + Hash + Eq, V: Persist> Map<K, V> as Persist {
    fn save(self: &Map<K, V>, w: &mut Writer) {
        w.u64(self.len() as u64);
        let mut it = self.keys();
        loop {
            switch it.next() {
                Some(k) => {
                    k.save(w);
                    self.get(k).unwrap().save(w);
                },
                None => {
                    break;
                },
            }
        }
    }

    fn load(self: &mut Map<K, V>, r: &mut Reader) {
        let n = r.u64() as usize;
        if n > r.left() {
            r.ok = false;
            return;
        }
        *self = Map::<K, V>::new();
        for _ in 0..n {
            let k = load_new::<K>(r);
            let v = load_new::<V>(r);
            self.insert(k, v);
        }
    }
}

extend<T: Persist + Hash + Eq> Set<T> as Persist {
    fn save(self: &Set<T>, w: &mut Writer) {
        w.u64(self.len() as u64);
        let mut it = self.iter();
        loop {
            switch it.next() {
                Some(k) => {
                    k.save(w);
                },
                None => {
                    break;
                },
            }
        }
    }

    fn load(self: &mut Set<T>, r: &mut Reader) {
        let n = r.u64() as usize;
        if n > r.left() {
            r.ok = false;
            return;
        }
        *self = Set::<T>::new();
        for _ in 0..n {
            self.insert(load_new::<T>(r));
        }
    }
}

// A cell saves and loads its value.
extend<T: Persist> UnsafeCell<T> as Persist {
    fn save(self: &UnsafeCell<T>, w: &mut Writer) {
        self.get_ref().save(w);
    }

    fn load(self: &mut UnsafeCell<T>, r: &mut Reader) {
        unsafe (*self.get()).load(r);
    }
}

extend<T: Copy + Persist> cell::Cell<T> as Persist {
    fn save(self: &cell::Cell<T>, w: &mut Writer) {
        let v = self.get();
        v.save(w);
    }

    fn load(self: &mut cell::Cell<T>, r: &mut Reader) {
        self.get_mut().load(r);
    }
}
