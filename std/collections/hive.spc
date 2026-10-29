// Hive<T, A = Global>: a container whose elements never move (C++26 `std::hive`, [hive], with the design of
// plf::hive). `insert` returns a `HiveHandle` that names the element's slot until the element is removed.
// Elements live in blocks from allocator A. A removed element's slot joins a free list of its block, and an
// insert reuses a free slot before it takes a new one. Iteration skips removed slots through a jump-counting
// skipfield: each step reads one entry, whatever the number of removed slots it passes.
//
// Block layout: a header (40 bytes on 64-bit targets, 24 on wasm32), `cap` slots, then `cap + 1` skipfield
// entries (the last is a 0 sentinel). A slot is a union of T and two u16 free-list links: at least 4 bytes and
// 2-byte aligned. A skipfield entry is a u8 when the slot is at most 10 bytes in size and alignment (blocks of at most
// 255 slots), else a u16 (blocks of at most 8192 slots). A run of removed slots (a skipblock) holds its length
// in its first and last entries; a live slot or a slot not used yet holds 0. Each block lists its skipblocks
// through the links in their first slots, and the hive lists the blocks that have a skipblock. The memory
// cost per slot is its skipfield entry (1 or 2 bytes) and the slot padding (none for a T of 4 bytes or more
// and an even size).
//
// Block sizes: the first block has 256 bytes of slots (at least 8 slots); each later new block has as many
// slots as the hive has elements, up to the maximum, so the capacity doubles until blocks are at the maximum.
// Measured (Apple M3 Max, release, 2^20 elements; ns per insert / per element of a full iteration / per
// live element after removing a random half / per random remove and insert): i64 with u8 entries and 255
// slots 2.2 / 0.60 / 1.8 / 13.6, with u16 entries and 8192 slots 2.1 / 0.56 / 1.6 / 15.6 (twice the
// skipfield bytes); a 24-byte T with 8192 slots 2.4 / 0.58 / 1.7 / 22, 1024 slots 2.6 / 0.72 / 1.8 / 20,
// 32768 slots 2.3 / 0.56 / 1.6 / 22. Against Vector (push 0.8 to 1.4, iteration 0.07 to 0.11) and Deque
// (push 1.2 to 1.9, iteration 0.5 to 0.64), a hive costs a slower iteration for its stable addresses.
//
// Complexity, with C++ [hive.overview] and [hive.modifiers] as the reference:
//   insert: O(1); a new block costs one allocation and one clear of its skipfield.
//   remove, get, get_mut, len, is_empty, capacity: O(1).
//   iter, iter_mut: O(1) to create and per step; a whole walk is O(len + blocks).
//   retain, clear, drop: O(len + blocks). reserve: O(1) per block it allocates. trim_capacity: O(blocks freed).
//
// Invalidation: no operation moves an element, so a handle and the address of its element stay valid until
// the element is removed (`remove`, `retain`, `clear`, or the drop of the hive). A later insert can reuse the
// slot, so a stale handle can name another element or no element: `get`, `get_mut` and `remove` are unsafe
// for that reason. A block that loses its last element stays allocated as a reserved block; `reserve` adds
// reserved blocks and `trim_capacity` frees them. Safe code cannot hold a reference across a mutation (the
// borrow rules reject it); a pointer to an element stays valid as long as its handle.
//
// Iteration runs over the blocks in order and over the slots of each block in order. That is not the order
// of insertion: an insert fills a free slot of an earlier block first.
//
// Allocation: one block per `cap` slots through A, nothing per element; a zero-sized T takes 4-byte slots.
// Thread safety: no internal synchronization; a Hive is Send and Sync when T and A are, so a shared reference
// allows concurrent reads and a mutation needs exclusive access. A HiveHandle is neither.

extern "C" {
    fn memset(dst: *mut void, value: i32, n: usize) *mut void;
}

const NONE: usize = 0xFFFF; // the end of a free list: above every slot index
const MIN_CAP: usize = 8;
const MIN_SLOT_BYTES: usize = 256; // slot bytes of the first block
const MAX_CAP_NARROW: usize = 255; // the largest length a u8 skipfield entry holds
const MAX_CAP_WIDE: usize = 8192;

// An element, or, in the first slot of a skipblock, the first slots of the previous and the next skipblock
// of the block's free list (NONE at an end).
pub(module) union Slot<T> {
    val: T,
    link: [u16; 2],
}

// A block header. The slots follow it at offset `slot_offset()`, the skipfield follows the slots. Every
// active block holds an element; every active block other than the tail has used all its slots.
pub(module) struct Block<T> {
    pub(module) next: *mut Block<T>, // the next active block; in the reserved list, the next reserved block
    pub(module) prev: *mut Block<T>, // the previous active block
    pub(module) erased_next: *mut Block<T>, // the next block with a skipblock
    pub(module) erased_prev: *mut Block<T>,
    pub(module) cap: u16,
    pub(module) len: u16, // live elements
    pub(module) free_head: u16, // the first slot of the first skipblock, or NONE
}

/// A container whose elements keep their address until removed, in blocks from allocator A. An insert
/// reuses the slot of a removed element first; iteration skips removed slots in O(1) per step.
pub struct Hive<T, A = Global> {
    head: *mut Block<T>, // the first active block, null when no element is stored
    tail: *mut Block<T>, // the last active block: the only one with slots not used yet
    tail_used: usize, // slots of `tail` used, live or removed
    erased: *mut Block<T>, // the first block with a skipblock
    reserved: *mut Block<T>, // the blocks without an element, linked through `next`
    len: usize,
    cap: usize, // slots of every block, active and reserved
    alloc: A,
}

// A Hive owns its elements, so it is Send / Sync when its elements and allocator are (the block pointers
// make it structurally neither).
unsafe extend<T: Send, A: Send> Hive<T, A> as Send {}

unsafe extend<T: Sync, A: Sync> Hive<T, A> as Sync {}

/// The slot of one element of a Hive: valid from the `insert` that returns it until the element is removed.
/// A copy that does not borrow the hive.
@derive(Copy)
pub struct HiveHandle<T> {
    pub(module) slot: *mut Slot<T>,
    pub(module) block: *mut Block<T>,
}

// The position of a walk over the live elements: `block` and `i` name the next one, while `rem` > 0.
pub(module) struct Cursor<T> {
    pub(module) block: *mut Block<T>,
    slots: *mut Slot<T>, // the slots of `block`
    skip: *const u8, // the skipfield of `block`
    cap: usize, // the slots of `block`
    pub(module) i: usize,
    pub(module) rem: usize, // live elements not yet passed
}

/// A borrowing iterator over a Hive, in block and slot order; exact size.
pub struct HiveIter<'a, T> {
    pub(module) c: Cursor<T>,
}

/// A mutably borrowing iterator over a Hive, in block and slot order; exact size.
pub struct HiveIterMut<'a, T> {
    pub(module) c: Cursor<T>,
}

// Skipfield entry `i`, u8 or u16 as Block<T>::narrow() selects.
@always_inline
const fn skip_get<T>(sk: *const u8, i: usize) usize {
    if Block::<T>::narrow() {
        return (unsafe sk[i]) as usize;
    }
    return (unsafe (sk as *const u16)[i]) as usize;
}

@always_inline
const fn skip_set<T>(sk: *mut u8, i: usize, v: usize) {
    if Block::<T>::narrow() {
        unsafe sk[i] = v as u8;
    } else {
        unsafe (sk as *mut u16)[i] = v as u16;
    }
}

// The free-list links of slot `i`: [0] the previous skipblock, [1] the next.
@always_inline
const fn link<T>(slots: *mut Slot<T>, i: usize) *mut u16 {
    return (unsafe (slots + i)) as *mut u16;
}

extend<T, A: Allocator> Hive<T, A> {
    /// An empty hive that allocates through `alloc`; no allocation until the first insert.
    pub const fn new_in(alloc: A) Hive<T, A> {
        return Hive::<T, A> {
            head: null,
            tail: null,
            tail_used: 0,
            erased: null,
            reserved: null,
            len: 0,
            cap: 0,
            alloc: alloc,
        };
    }

    /// Number of elements.
    pub const fn len(self: &Hive<T, A>) usize {
        return self.len;
    }

    /// True when no element is stored.
    pub const fn is_empty(self: &Hive<T, A>) bool {
        return self.len == 0;
    }

    /// Slots of every block, active and reserved: `capacity() - len()` inserts allocate nothing.
    pub const fn capacity(self: &Hive<T, A>) usize {
        return self.cap;
    }

    /// Stores `value` and returns its handle: in a free slot when a block has one, else in a slot not used
    /// yet, else in a reserved or a new block. O(1); no element moves.
    pub fn insert(self: &mut Hive<T, A>, value: T) HiveHandle<T> {
        let b: *mut Block<T>;
        let i: usize;
        if self.erased != null {
            b = self.erased;
            i = self.take_free_slot(b);
        } else {
            if self.tail == null || self.tail_used == self.tail.cap() {
                self.push_block();
            }
            b = self.tail;
            i = self.tail_used;
            self.tail_used += 1;
        }
        let p = unsafe (b.slots() + i);
        unsafe *(p as *mut T) = value;
        unsafe (*b).len += 1;
        self.len += 1;
        return HiveHandle::<T> { slot: p, block: b };
    }

    /// The element `h` names. Safety: `h` comes from `insert` on this hive and its element is not removed.
    pub unsafe const fn get(self: &Hive<T, A>, h: HiveHandle<T>) &T {
        return unsafe &*(h.slot as *const T);
    }

    /// The element `h` names, writable. Safety: as for `get`.
    pub unsafe const fn get_mut(self: &mut Hive<T, A>, h: HiveHandle<T>) &mut T {
        return unsafe &mut *(h.slot as *mut T);
    }

    /// Removes the element `h` names and moves it to the caller; O(1), no other element moves. Its slot goes
    /// to the free list; a block left without an element becomes a reserved block. Safety: as for `get`.
    pub unsafe const fn remove(self: &mut Hive<T, A>, h: HiveHandle<T>) T {
        let i = (h.slot as usize - h.block.slots() as usize) / sizeof(Slot<T>);
        return self.remove_at(h.block, i);
    }

    /// Keeps the elements for which `pred` returns true and frees the others (C++ `erase_if`). `pred` borrows
    /// each element once, in iteration order. No element moves.
    pub fn retain<F: fn(&T) bool>(self: &mut Hive<T, A>, pred: F) {
        let mut c = Cursor::<T>::new(self.head, self.len);
        while c.rem > 0 {
            let b = c.block;
            let i = c.i;
            let p = c.next();
            if !pred(unsafe &*(p as *const T)) {
                let _ = self.remove_at(b, i);
            }
        }
    }

    /// Frees every element and keeps every block as a reserved block.
    pub fn clear(self: &mut Hive<T, A>) {
        let mut c = Cursor::<T>::new(self.head, self.len);
        while c.rem > 0 {
            let p = c.next();
            unsafe (*(p as *mut T)).free();
        }
        let mut b = self.head;
        while b != null {
            let n = unsafe (*b).next;
            unsafe (*b).next = self.reserved;
            self.reserved = b;
            b = n;
        }
        self.head = null;
        self.tail = null;
        self.tail_used = 0;
        self.erased = null;
        self.len = 0;
    }

    /// Makes room for at least `additional` more elements: allocates reserved blocks (of at most 8192 slots
    /// each, 255 for a slot of at most 10 bytes) until `capacity() - len() >= additional`. No element moves.
    /// Panics when the slot bytes overflow an isize.
    pub fn reserve(self: &mut Hive<T, A>, additional: usize) {
        let free = self.cap - self.len;
        if additional <= free {
            return;
        }
        if additional > (~(0 as usize) >> 1) / sizeof(Slot<T>) - self.len {
            panic("Hive: capacity overflow");
        }
        let mut need = additional - free;
        while need > 0 {
            let c = need.max(Block::<T>::min_cap()).min(Block::<T>::max_cap());
            let b = self.alloc_block(c);
            unsafe (*b).next = self.reserved;
            self.reserved = b;
            need -= need.min(c);
        }
    }

    /// Frees every reserved block (C++ `trim_capacity`). No element moves.
    pub fn trim_capacity(self: &mut Hive<T, A>) {
        while self.reserved != null {
            let b = self.reserved;
            self.reserved = unsafe (*b).next;
            let c = b.cap();
            self.cap -= c;
            unsafe self.alloc.dealloc(b, Block::<T>::bytes(c), Block::<T>::align());
        }
    }

    /// A borrowing iterator in block and slot order; exact size.
    pub const fn iter(self: &Hive<T, A>) HiveIter<T> {
        return HiveIter::<T> { c: Cursor::<T>::new(self.head, self.len) };
    }

    /// A mutably borrowing iterator in block and slot order; exact size.
    pub const fn iter_mut(self: &mut Hive<T, A>) HiveIterMut<T> {
        return HiveIterMut::<T> { c: Cursor::<T>::new(self.head, self.len) };
    }

    // A block of `cap` slots from the allocator, its links not set.
    fn alloc_block(self: &mut Hive<T, A>, cap: usize) *mut Block<T> {
        let b = (unsafe self.alloc.alloc(Block::<T>::bytes(cap), Block::<T>::align())) as *mut Block<T>;
        unsafe (*b).cap = cap as u16;
        self.cap += cap;
        return b;
    }

    // Append a reserved block, or else a new one, as the empty tail. A new block has as many slots as the hive
    // has elements, within the block limits: every active block is full at this point, so the capacity doubles.
    @noinline
    fn push_block(self: &mut Hive<T, A>) {
        let b: *mut Block<T>;
        if self.reserved != null {
            b = self.reserved;
            self.reserved = unsafe (*b).next;
        } else {
            b = self.alloc_block(self.len.max(Block::<T>::min_cap()).min(Block::<T>::max_cap()));
        }
        let cap = b.cap();
        unsafe memset(b.skips(), 0, (cap + 1) * Block::<T>::skip_bytes());
        unsafe {
            (*b).len = 0;
            (*b).free_head = NONE as u16;
            (*b).next = null;
            (*b).prev = self.tail;
            (*b).erased_next = null;
            (*b).erased_prev = null;
        }
        if self.tail == null {
            self.head = b;
        } else {
            unsafe (*self.tail).next = b;
        }
        self.tail = b;
        self.tail_used = 0;
    }

    // Take the first slot of the first skipblock of `b` (the head of the erased list) and return its index.
    // The skipblock shrinks from its front, or leaves the free list when it was one slot long; `b` leaves the
    // erased list with its last skipblock.
    const fn take_free_slot(self: &mut Hive<T, A>, b: *mut Block<T>) usize {
        let slots = b.slots();
        let sk = b.skips();
        let i = (unsafe (*b).free_head) as usize;
        let n = skip_get::<T>(sk, i);
        let next = (unsafe link(slots, i)[1]) as usize;
        skip_set::<T>(sk, i, 0);
        if n == 1 {
            unsafe (*b).free_head = next as u16;
            if next == NONE {
                self.unlink_erased(b);
            } else {
                unsafe link(slots, next)[0] = NONE as u16;
            }
        } else {
            skip_set::<T>(sk, i + 1, n - 1);
            skip_set::<T>(sk, i + n - 1, n - 1);
            let l = link(slots, i + 1);
            unsafe {
                l[0] = NONE as u16;
                l[1] = next as u16;
                (*b).free_head = (i + 1) as u16;
            }
            if next != NONE {
                unsafe link(slots, next)[0] = (i + 1) as u16;
            }
        }
        return i;
    }

    // Move the live element in slot `i` of `b` out and add the slot to the skipfield: a new skipblock, the
    // extension of a neighbor one, or the merge of both neighbors. Only the end entries of a skipblock are
    // read (an element is never next to the inside of one), so only those are written.
    const fn remove_at(self: &mut Hive<T, A>, b: *mut Block<T>, i: usize) T {
        let slots = b.slots();
        let sk = b.skips();
        let v = unsafe *((slots + i) as *mut T);
        let left = if i > 0 {
            skip_get::<T>(sk, i - 1);
        } else {
            0;
        };
        let right = skip_get::<T>(sk, i + 1);
        if left == 0 && right == 0 {
            let head = (unsafe (*b).free_head) as usize;
            skip_set::<T>(sk, i, 1);
            let l = link(slots, i);
            unsafe {
                l[0] = NONE as u16;
                l[1] = head as u16;
                (*b).free_head = i as u16;
            }
            if head == NONE {
                self.link_erased(b);
            } else {
                unsafe link(slots, head)[0] = i as u16;
            }
        } else if right == 0 {
            skip_set::<T>(sk, i - left, left + 1);
            skip_set::<T>(sk, i, left + 1);
        } else {
            // The skipblock at `i + 1` grows to the left: its free-list node moves to `i`, or leaves the
            // list when the skipblock on the left absorbs it.
            skip_set::<T>(sk, i - left, left + right + 1);
            skip_set::<T>(sk, i + right, left + right + 1);
            let old = link(slots, i + 1);
            let prev = (unsafe old[0]) as usize;
            let next = (unsafe old[1]) as usize;
            if left == 0 {
                let l = link(slots, i);
                unsafe {
                    l[0] = prev as u16;
                    l[1] = next as u16;
                }
                b.relink(slots, prev, next, i, i);
            } else {
                b.relink(slots, prev, next, next, prev);
            }
        }
        self.len -= 1;
        unsafe (*b).len -= 1;
        if unsafe (*b).len == 0 {
            self.retire(b);
        }
        return v;
    }

    // Unlink `b`, which has no element left, from the active and the erased lists and add it to the reserved
    // list. A cursor leaves a block when it yields the block's last live element, before that element can be
    // removed, so `retain` never reads the `next` this overwrites.
    const fn retire(self: &mut Hive<T, A>, b: *mut Block<T>) {
        let p = unsafe (*b).prev;
        let n = unsafe (*b).next;
        if p == null {
            self.head = n;
        } else {
            unsafe (*p).next = n;
        }
        if n == null {
            self.tail = p;
            self.tail_used = if p == null {
                0;
            } else {
                p.cap();
            };
        } else {
            unsafe (*n).prev = p;
        }
        self.unlink_erased(b);
        unsafe (*b).next = self.reserved;
        self.reserved = b;
    }

    const fn link_erased(self: &mut Hive<T, A>, b: *mut Block<T>) {
        unsafe {
            (*b).erased_prev = null;
            (*b).erased_next = self.erased;
        }
        if self.erased != null {
            unsafe (*self.erased).erased_prev = b;
        }
        self.erased = b;
    }

    const fn unlink_erased(self: &mut Hive<T, A>, b: *mut Block<T>) {
        let p = unsafe (*b).erased_prev;
        let n = unsafe (*b).erased_next;
        if p == null {
            self.erased = n;
        } else {
            unsafe (*p).erased_next = n;
        }
        if n != null {
            unsafe (*n).erased_prev = p;
        }
    }
}

extend<T, A: Allocator + Default> Hive<T, A> {
    /// An empty hive on the default allocator; no allocation until the first insert.
    pub const fn new() Hive<T, A> {
        return Hive::<T, A>::new_in(A::default());
    }
}

extend<T> Block<T> {
    // True when the skipfield entries are u8: plf::hive's rule, a slot of at most 10 bytes in size and
    // alignment, where a u16 entry would add more than 20% to each slot.
    const fn narrow() bool {
        return sizeof(Slot<T>) <= 10 && alignof(Slot<T>) <= 10;
    }

    const fn skip_bytes() usize {
        if Block::<T>::narrow() {
            return 1;
        }
        return 2;
    }

    const fn max_cap() usize {
        if Block::<T>::narrow() {
            return MAX_CAP_NARROW;
        }
        return MAX_CAP_WIDE;
    }

    const fn min_cap() usize {
        return (MIN_SLOT_BYTES / sizeof(Slot<T>)).max(MIN_CAP).min(Block::<T>::max_cap());
    }

    // The bytes of a block of `cap` slots; `reserve` and the block limits keep it within an isize.
    const fn bytes(cap: usize) usize {
        return Block::<T>::slot_offset() + cap * sizeof(Slot<T>) + (cap + 1) * Block::<T>::skip_bytes();
    }

    // The header rounded up to the alignment of a slot.
    const fn slot_offset() usize {
        return sizeof(Block<T>) + alignof(Slot<T>) - 1 & ~(alignof(Slot<T>) - 1);
    }

    const fn align() usize {
        return alignof(Block<T>).max(alignof(Slot<T>));
    }

    @always_inline
    const fn cap(self: *mut Block<T>) usize {
        return (unsafe (*self).cap) as usize;
    }

    @always_inline
    const fn slots(self: *mut Block<T>) *mut Slot<T> {
        return (unsafe (self as *mut u8 + Block::<T>::slot_offset())) as *mut Slot<T>;
    }

    @always_inline
    const fn skips(self: *mut Block<T>) *mut u8 {
        return (unsafe (self.slots() + self.cap())) as *mut u8;
    }

    // Point the free-list neighbors `prev` and `next` (NONE at an end) of a skipblock at `to_next` and
    // `to_prev`: the first slot of a moved skipblock for both, or each other when the skipblock leaves the list.
    const fn relink(self: *mut Block<T>, slots: *mut Slot<T>, prev: usize, next: usize, to_next: usize, to_prev: usize) {
        if prev == NONE {
            unsafe (*self).free_head = to_next as u16;
        } else {
            unsafe link(slots, prev)[1] = to_next as u16;
        }
        if next != NONE {
            unsafe link(slots, next)[0] = to_prev as u16;
        }
    }
}

extend<T> Cursor<T> {
    const fn new(head: *mut Block<T>, len: usize) Cursor<T> {
        let mut c = Cursor::<T> { block: head, slots: null, skip: null, cap: 0, i: 0, rem: len };
        if len > 0 {
            c.enter(head);
        }
        return c;
    }

    // Start at the first live slot of `b`, which holds an element.
    @always_inline
    const fn enter(self: &mut Cursor<T>, b: *mut Block<T>) {
        self.block = b;
        self.slots = b.slots();
        self.skip = b.skips();
        self.cap = b.cap();
        self.i = skip_get::<T>(self.skip, 0);
    }

    // The slot of the next live element; the cursor then names the one after it, in the next block when the
    // slot was the last live one of its block. Needs rem > 0.
    @always_inline
    const fn next(self: &mut Cursor<T>) *mut Slot<T> {
        let p = unsafe (self.slots + self.i);
        self.rem -= 1;
        self.i += 1;
        self.i += skip_get::<T>(self.skip, self.i);
        if self.i == self.cap && self.rem > 0 {
            self.enter(unsafe (*self.block).next);
        }
        return p;
    }
}

extend<'a, T> HiveIter<'a, T> as Iterator<&'a T> {
    pub fn next(self: &mut HiveIter<'a, T>) Option<&'a T> {
        if self.c.rem == 0 {
            return Option::<&'a T>::None;
        }
        let p = self.c.next();
        return Option::<&'a T>::Some(unsafe &*(p as *const T));
    }

    pub const fn size_hint(self: &HiveIter<'a, T>) (usize, Option<usize>) {
        return self.c.rem, Option::<usize>::Some(self.c.rem);
    }
}

extend<'a, T> HiveIterMut<'a, T> as Iterator<&'a mut T> {
    pub fn next(self: &mut HiveIterMut<'a, T>) Option<&'a mut T> {
        if self.c.rem == 0 {
            return Option::<&'a mut T>::None;
        }
        let p = self.c.next();
        return Option::<&'a mut T>::Some(unsafe &mut *(p as *mut T));
    }

    pub const fn size_hint(self: &HiveIterMut<'a, T>) (usize, Option<usize>) {
        return self.c.rem, Option::<usize>::Some(self.c.rem);
    }
}

// Deep-free the elements, then return every block to `A`. Sound because the accessors borrow and `remove`
// moves the element out, so the hive is the only owner of each live element.
extend<T, A: Allocator> Hive<T, A> as Free {
    pub fn free(self: &mut Hive<T, A>) {
        self.clear();
        self.trim_capacity();
    }
}

extend<T, A: Allocator + Default> Hive<T, A> as Default {
    pub const fn default() Hive<T, A> {
        return Hive::<T, A>::new();
    }
}
