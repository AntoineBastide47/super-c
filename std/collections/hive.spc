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
union Slot<T> {
    val: T,
    link: [u16; 2],
}

// A block header. The slots follow it at offset `slot_offset()`, the skipfield follows the slots. Every
// active block holds an element; every active block other than the tail has used all its slots. Each list
// holds its blocks through `next`, the hive's `head` and `reserved` and the size each holder states; `prev`
// and the erased list only name blocks.
struct Block<T, A: Allocator>
    invariant self.next == null || A::owns(
        self.next,
        Block::<T, A>::bytes(self.next_cap as usize),
        Block::<T, A>::align(),
    )
{
    next: *mut Block<T, A>, // the next active block; in the reserved list, the next reserved block
    prev: *mut Block<T, A>, // the previous active block
    erased_next: *mut Block<T, A>, // the next block with a skipblock
    erased_prev: *mut Block<T, A>,
    cap: u16,
    len: u16, // live elements
    free_head: u16, // the first slot of the first skipblock, or NONE
    next_cap: u16, // the slots of `next`
}

/// A container whose elements keep their address until removed, in blocks from allocator A. An insert
/// reuses the slot of a removed element first; iteration skips removed slots in O(1) per step.
pub struct Hive<T, A: Allocator = Global>
    invariant self.head == null || A::owns(
        self.head,
        Block::<T, A>::bytes(self.head_cap as usize),
        Block::<T, A>::align(),
    )
    invariant self.reserved == null || A::owns(
        self.reserved,
        Block::<T, A>::bytes(self.reserved_cap as usize),
        Block::<T, A>::align(),
    )
{
    head: *mut Block<T, A>, // the first active block, null when no element is stored
    tail: *mut Block<T, A>, // the last active block: the only one with slots not used yet
    tail_used: usize, // slots of `tail` used, live or removed
    erased: *mut Block<T, A>, // the first block with a skipblock
    reserved: *mut Block<T, A>, // the blocks without an element, linked through `next`
    len: usize,
    cap: usize, // slots of every block, active and reserved
    head_cap: u16, // the slots of `head`
    reserved_cap: u16, // the slots of `reserved`
    alloc: A,
}

// A Hive owns its elements, so it is Send / Sync when its elements and allocator are (the block pointers
// make it structurally neither).
unsafe extend<T: Send, A: Allocator + Send> Hive<T, A> as Send {}

unsafe extend<T: Sync, A: Allocator + Sync> Hive<T, A> as Sync {}

/// The slot of one element of a Hive: valid from the `insert` that returns it until the element is removed.
/// A copy that does not borrow the hive.
@derive(Copy)
pub struct HiveHandle<T> {
    slot: *mut Slot<T>,
    block: *mut void, // the `Block` of `slot`
}

// The position of a walk over the live elements: `block` and `i` name the next one, while `rem` > 0.
struct Cursor<T, A: Allocator> {
    block: *mut Block<T, A>,
    slots: *mut Slot<T>, // the slots of `block`
    skip: *const u8, // the skipfield of `block`
    cap: usize, // the slots of `block`
    i: usize,
    rem: usize, // live elements not yet passed
}

/// A borrowing iterator over a Hive, in block and slot order; exact size.
pub struct HiveIter<'a, T, A: Allocator = Global> {
    c: Cursor<T, A>,
}

/// A mutably borrowing iterator over a Hive, in block and slot order; exact size.
pub struct HiveIterMut<'a, T, A: Allocator = Global> {
    c: Cursor<T, A>,
}

// True when the skipfield entries are u8: plf::hive's rule, a slot of at most 10 bytes in size and
// alignment, where a u16 entry would add more than 20% to each slot.
const fn narrow<T>() bool {
    return sizeof(Slot<T>) <= 10 && alignof(Slot<T>) <= 10;
}

// Skipfield entry `i`, u8 or u16 as `narrow` selects.
@always_inline
const fn skip_get<T>(sk: *const u8, i: usize) usize {
    if narrow::<T>() {
        return (unsafe sk[i]) as usize;
    }
    return (unsafe (sk as *const u16)[i]) as usize;
}

@always_inline
const fn skip_set<T>(sk: *mut u8, i: usize, v: usize) {
    if narrow::<T>() {
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

// Free the blocks of the list from `first`, of `first_cap` slots, through `alloc`; the slots they had.
fn free_blocks<T, A: Allocator>(alloc: &mut A, first: *mut Block<T, A>, first_cap: u16) usize
    requires first == null || A::owns(first, Block::<T, A>::bytes(first_cap as usize), Block::<T, A>::align())
    panics if true
{
    let mut b = first;
    let mut bc = first_cap;
    let mut freed: usize = 0;
    while b != null
        invariant b == null || A::owns(b, Block::<T, A>::bytes(bc as usize), Block::<T, A>::align())
    {
        let n = unsafe (*b).next;
        let nc = unsafe (*b).next_cap;
        freed += bc as usize;
        unsafe alloc.dealloc(b, Block::<T, A>::bytes(bc as usize), Block::<T, A>::align());
        b = n;
        bc = nc;
    }
    return freed;
}

// A block of `cap` slots from `alloc`, no element in it, before block `next` of `next_cap` slots.
fn new_block<T, A: Allocator>(alloc: &mut A, cap: u16, next: *mut Block<T, A>, next_cap: u16) *mut Block<T, A>
    requires next == null || A::owns(next, Block::<T, A>::bytes(next_cap as usize), Block::<T, A>::align())
    ensures |r| A::owns(r, Block::<T, A>::bytes(cap as usize), Block::<T, A>::align())
    panics if true
{
    let b = (unsafe alloc.alloc(alloc_size(Block::<T, A>::bytes(cap as usize)), Block::<T, A>::align())) as *mut Block<
        T,
        A
    >;
    unsafe *b = Block::<T, A> {
        next: next,
        prev: null,
        erased_next: null,
        erased_prev: null,
        cap: cap,
        len: 0,
        free_head: NONE as u16,
        next_cap: next_cap,
    };
    return b;
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
            head_cap: 0,
            reserved_cap: 0,
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
        let b: *mut Block<T, A>;
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
        self.len += 1;
        unsafe (*b).len += 1;
        let p = unsafe (b.slots() + i);
        unsafe *(p as *mut T) = value;
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
        let b = h.block as *mut Block<T, A>;
        let i = (h.slot as usize - b.slots() as usize) / sizeof(Slot<T>);
        return self.remove_at(b, i);
    }

    /// Keeps the elements for which `pred` returns true and frees the others (C++ `erase_if`). `pred` borrows
    /// each element once, in iteration order. No element moves.
    pub fn retain<F: fn(&T) bool>(self: &mut Hive<T, A>, pred: F) {
        let mut c = Cursor::<T, A>::new(self.head, self.len);
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
        let mut c = Cursor::<T, A>::new(self.head, self.len);
        while c.rem > 0 {
            let p = c.next();
            unsafe (*(p as *mut T)).free();
        }
        self.reserve_active();
    }

    // Move every active block to the reserved list.
    const fn reserve_active(self: &mut Hive<T, A>) {
        let mut b = self.head;
        let mut bc = self.head_cap;
        let mut r = self.reserved;
        let mut rc = self.reserved_cap;
        self.head = null;
        self.head_cap = 0;
        self.reserved = null;
        self.reserved_cap = 0;
        self.tail = null;
        self.tail_used = 0;
        self.erased = null;
        self.len = 0;
        while b != null
            invariant b == null || A::owns(b, Block::<T, A>::bytes(bc as usize), Block::<T, A>::align())
            invariant r == null || A::owns(r, Block::<T, A>::bytes(rc as usize), Block::<T, A>::align())
        {
            let n = unsafe (*b).next;
            let nc = unsafe (*b).next_cap;
            unsafe {
                (*b).next = r;
                (*b).next_cap = rc;
            }
            r = b;
            rc = bc;
            b = n;
            bc = nc;
        }
        self.reserved = r;
        self.reserved_cap = rc;
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
            let c = need.max(Block::<T, A>::min_cap()).min(Block::<T, A>::max_cap());
            self.add_reserved(c as u16);
            need -= need.min(c);
        }
    }

    /// Frees every reserved block (C++ `trim_capacity`). No element moves.
    pub fn trim_capacity(self: &mut Hive<T, A>) {
        let b = self.reserved;
        let bc = self.reserved_cap;
        self.reserved = null;
        self.reserved_cap = 0;
        let freed = free_blocks::<T, A>(&mut self.alloc, b, bc);
        self.cap -= freed;
    }

    /// A borrowing iterator in block and slot order; exact size.
    pub const fn iter(self: &Hive<T, A>) HiveIter<T, A> {
        return HiveIter::<T, A> { c: Cursor::<T, A>::new(self.head, self.len) };
    }

    /// A mutably borrowing iterator in block and slot order; exact size.
    pub const fn iter_mut(self: &mut Hive<T, A>) HiveIterMut<T, A> {
        return HiveIterMut::<T, A> { c: Cursor::<T, A>::new(self.head, self.len) };
    }

    // Add a new block of `cap` slots, no element in it, to the reserved list.
    fn add_reserved(self: &mut Hive<T, A>, cap: u16) {
        let r = self.reserved;
        let rc = self.reserved_cap;
        self.reserved = null;
        self.reserved_cap = 0;
        self.reserved = new_block::<T, A>(&mut self.alloc, cap, r, rc);
        self.reserved_cap = cap;
        self.cap += cap as usize;
    }

    // Append a reserved block, or else a new one, as the empty tail. A new block has as many slots as the hive
    // has elements, within the block limits: every active block is full at this point, so the capacity doubles.
    @noinline
    fn push_block(self: &mut Hive<T, A>) {
        let b: *mut Block<T, A>;
        let bc: u16;
        if self.reserved == null {
            bc = self.len.max(Block::<T, A>::min_cap()).min(Block::<T, A>::max_cap()) as u16;
            b = new_block::<T, A>(&mut self.alloc, bc, null, 0);
            self.cap += bc as usize;
        } else {
            b = self.reserved;
            bc = self.reserved_cap;
            let n = unsafe (*b).next;
            let nc = unsafe (*b).next_cap;
            self.reserved = n;
            self.reserved_cap = nc;
        }
        let t = self.tail;
        if t == null {
            self.head = b;
            self.head_cap = bc;
        }
        self.tail = b;
        self.tail_used = 0;
        unsafe {
            (*b).len = 0;
            (*b).free_head = NONE as u16;
            (*b).next = null;
            (*b).next_cap = 0;
            (*b).prev = t;
            (*b).erased_next = null;
            (*b).erased_prev = null;
        }
        if t != null {
            unsafe {
                (*t).next = b;
                (*t).next_cap = bc;
            }
        }
        unsafe memset(b.skips(), 0, (b.cap() + 1) * Block::<T, A>::skip_bytes());
    }

    // Take the first slot of the first skipblock of `b` (the head of the erased list) and return its index.
    // The skipblock shrinks from its front, or leaves the free list when it was one slot long; `b` leaves the
    // erased list with its last skipblock.
    const fn take_free_slot(self: &mut Hive<T, A>, b: *mut Block<T, A>) usize {
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
    const fn remove_at(self: &mut Hive<T, A>, b: *mut Block<T, A>, i: usize) T {
        let slots = b.slots();
        let sk = b.skips();
        let v = unsafe *((slots + i) as *mut T);
        let left = if i > 0 {
            skip_get::<T>(sk, i - 1)
        } else {
            0
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
    // removed, so `retain` never reads the `next` this overwrites. The link that holds `b` is checked: `b`
    // comes from a handle, and only that link states its size.
    const fn retire(self: &mut Hive<T, A>, b: *mut Block<T, A>) {
        let p = unsafe (*b).prev;
        let n = unsafe (*b).next;
        let nc = unsafe (*b).next_cap;
        let r = self.reserved;
        let rc = self.reserved_cap;
        self.reserved = null;
        self.reserved_cap = 0;
        // `n` leaves `b`, and the reserved list follows it.
        unsafe {
            (*b).next = r;
            (*b).next_cap = rc;
        }
        let bc: u16;
        if p == null {
            if self.head != b {
                panic("Hive: a block is not linked from the one before it");
            }
            bc = self.head_cap;
            self.head = n;
            self.head_cap = nc;
        } else {
            if unsafe (*p).next != b {
                panic("Hive: a block is not linked from the one before it");
            }
            bc = unsafe (*p).next_cap;
            unsafe {
                (*p).next = n;
                (*p).next_cap = nc;
            }
        }
        if n == null {
            self.tail = p;
            self.tail_used = if p == null {
                0
            } else {
                p.cap()
            };
        } else {
            unsafe (*n).prev = p;
        }
        self.reserved = b;
        self.reserved_cap = bc;
        self.unlink_erased(b);
    }

    const fn link_erased(self: &mut Hive<T, A>, b: *mut Block<T, A>) {
        let e = self.erased;
        self.erased = b;
        unsafe {
            (*b).erased_prev = null;
            (*b).erased_next = e;
        }
        if e != null {
            unsafe (*e).erased_prev = b;
        }
    }

    const fn unlink_erased(self: &mut Hive<T, A>, b: *mut Block<T, A>) {
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

extend<T, A: Allocator> Block<T, A> {
    const fn skip_bytes() usize {
        if narrow::<T>() {
            return 1;
        }
        return 2;
    }

    const fn max_cap() usize
        ensures |r| r <= MAX_CAP_WIDE
    {
        if narrow::<T>() {
            return MAX_CAP_NARROW;
        }
        return MAX_CAP_WIDE;
    }

    const fn min_cap() usize {
        return (MIN_SLOT_BYTES / sizeof(Slot<T>)).max(MIN_CAP).min(Block::<T, A>::max_cap());
    }

    // The bytes of a block of `cap` slots; `reserve` and the block limits keep it within an isize.
    const fn bytes(cap: usize) usize {
        return Block::<T, A>::slot_offset() + cap * sizeof(Slot<T>) + (cap + 1) * Block::<T, A>::skip_bytes();
    }

    // The header rounded up to the alignment of a slot.
    const fn slot_offset() usize {
        return sizeof(Block<T, A>) + alignof(Slot<T>) - 1 & ~(alignof(Slot<T>) - 1);
    }

    const fn align() usize
        ensures |r| r != 0 && (r & r - 1) == 0
    {
        return alignof(Block<T, A>).max(alignof(Slot<T>));
    }

    @always_inline
    const fn cap(self: *mut Block<T, A>) usize {
        return (unsafe (*self).cap) as usize;
    }

    @always_inline
    const fn slots(self: *mut Block<T, A>) *mut Slot<T> {
        return (unsafe (self as *mut u8 + Block::<T, A>::slot_offset())) as *mut Slot<T>;
    }

    @always_inline
    const fn skips(self: *mut Block<T, A>) *mut u8 {
        return (unsafe (self.slots() + self.cap())) as *mut u8;
    }

    // Point the free-list neighbors `prev` and `next` (NONE at an end) of a skipblock at `to_next` and
    // `to_prev`: the first slot of a moved skipblock for both, or each other when the skipblock leaves the list.
    const fn relink(
        self: *mut Block<T, A>,
        slots: *mut Slot<T>,
        prev: usize,
        next: usize,
        to_next: usize,
        to_prev: usize,
    ) {
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

extend<T, A: Allocator> Cursor<T, A> {
    const fn new(head: *mut Block<T, A>, len: usize) Cursor<T, A> {
        let mut c = Cursor::<T, A> { block: head, slots: null, skip: null, cap: 0, i: 0, rem: len };
        if len > 0 {
            c.enter(head);
        }
        return c;
    }

    // Start at the first live slot of `b`, which holds an element.
    @always_inline
    const fn enter(self: &mut Cursor<T, A>, b: *mut Block<T, A>) {
        self.block = b;
        self.slots = b.slots();
        self.skip = b.skips();
        self.cap = b.cap();
        self.i = skip_get::<T>(self.skip, 0);
    }

    // The slot of the next live element; the cursor then names the one after it, in the next block when the
    // slot was the last live one of its block. Needs rem > 0.
    @always_inline
    const fn next(self: &mut Cursor<T, A>) *mut Slot<T> {
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

extend<'a, T, A: Allocator> HiveIter<'a, T, A> as Iterator<&'a T> {
    pub fn next(self: &mut HiveIter<'a, T, A>) Option<&'a T> {
        if self.c.rem == 0 {
            return None;
        }
        let p = self.c.next();
        return Some(unsafe &*(p as *const T));
    }

    pub const fn size_hint(self: &HiveIter<'a, T, A>) (usize, Option<usize>) {
        return (self.c.rem, Option::<usize>::Some(self.c.rem));
    }
}

extend<'a, T, A: Allocator> HiveIterMut<'a, T, A> as Iterator<&'a mut T> {
    pub fn next(self: &mut HiveIterMut<'a, T, A>) Option<&'a mut T> {
        if self.c.rem == 0 {
            return None;
        }
        let p = self.c.next();
        return Some(unsafe &mut *(p as *mut T));
    }

    pub const fn size_hint(self: &HiveIterMut<'a, T, A>) (usize, Option<usize>) {
        return (self.c.rem, Option::<usize>::Some(self.c.rem));
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
