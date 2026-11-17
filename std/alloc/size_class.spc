// PoolClass<K>: size class `K` of a `Pool` (`std::alloc::pool`), and the free blocks it links. Its own
// file holds its invariants, so each class the pool holds keeps them as a `Box` keeps its own.

/// The smallest block size of a size class: every block holds at least a free-list link.
pub(package) const BLOCK_SIZE_MIN: usize = 16;
/// The size classes: blocks of 16, 32, .., 4096 bytes.
pub(package) const CLASS_COUNT: usize = 9;

// Size class `K`, of blocks of `16 << K` bytes: its free list, and the uncarved part `cur..end` of its
// newest chunk (both null before its first chunk). Each block it holds is aligned to the block size.
pub(package) struct PoolClass<const K: usize>
    invariant self.free == null || K < CLASS_COUNT && (self.free as usize & (BLOCK_SIZE_MIN << K) - 1) == 0
    invariant self.cur as usize <= self.end as usize && (self.cur == self.end || K < CLASS_COUNT && self.cur != null && (self.cur as usize & (BLOCK_SIZE_MIN << K) - 1) == 0)
{
    free: *mut u8, // free-list head; null when empty
    cur: *mut u8, // next uncarved block of the newest chunk
    end: *mut u8, // one past the newest chunk
    chunk_count: usize, // the chunks the class requested
}

// A free block of class `K`: its first word holds the class's next free block, null for none. Its
// invariant holds wherever the pool reads one (a free block is memory of this type).
struct FreeNode<const K: usize>
    invariant self.next == null || K < CLASS_COUNT && (self.next as usize & (BLOCK_SIZE_MIN << K) - 1) == 0
{
    next: *mut u8,
}

extend<const K: usize> PoolClass<K> {
    // The class's chunks.
    pub(package) const fn chunk_count(self: &Self) usize {
        return self.chunk_count;
    }

    // The class with no block.
    pub(package) const fn empty() PoolClass<K> {
        return PoolClass::<K> { free: null, cur: null, end: null, chunk_count: 0 };
    }

    // The class's next block: its first free one, else its next uncarved one; null when it has neither.
    @always_inline
    pub(package) unsafe const fn take(self: &mut Self) *mut u8
        requires K < CLASS_COUNT
        ensures |r| r == null || (r as usize & (BLOCK_SIZE_MIN << K) - 1) == 0
    {
        let b = self.free;
        if likely(b != null) {
            self.free = unsafe (*(b as *mut FreeNode<K>)).next;
            return b;
        }
        let size = BLOCK_SIZE_MIN << K;
        if self.end as usize - self.cur as usize >= size {
            let p = self.cur;
            // `p` is not `end`, so the invariant's other case holds: `p` is aligned to the block size.
            assert (p as usize & size - 1) == 0 by {};
            self.cur = unsafe (p + size);
            return p;
        }
        return null;
    }

    // Put block `p` of the class first on its free list.
    @always_inline
    pub(package) unsafe const fn give(self: &mut Self, p: *mut u8)
        requires K < CLASS_COUNT && p != null && (p as usize & (BLOCK_SIZE_MIN << K) - 1) == 0
    {
        unsafe *(p as *mut FreeNode<K>) = FreeNode::<K> { next: self.free };
        self.free = p;
    }

    // The class, with `count` chunks, carves its next blocks from `cur` to `end`.
    pub(package) const fn carve(self: &mut Self, count: usize, cur: *mut u8, end: *mut u8)
        requires K < CLASS_COUNT && cur as usize <= end as usize && (cur == end || cur != null && (cur as usize & (BLOCK_SIZE_MIN << K) - 1) == 0)
    {
        self.chunk_count = count;
        self.cur = cur;
        self.end = end;
    }
}
