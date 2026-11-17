// RecList<K>: the recycled `call_c` records of class `K` that the blocking pool (`std::parallel::blocking`)
// keeps, `CACHE_MIN << K` bytes each. Its own file holds its invariants, so each class the pool record
// holds keeps them as a `Box` keeps its own.

/// The smallest record class, in bytes.
pub(package) const CACHE_MIN: usize = 64;
/// The record classes: 64, 128, .., 4096 bytes.
pub(package) const CLASSES: usize = 7;

// A cached record of class `K`: its first word links the class's next record, null for none.
struct RecNode<const K: usize>
    invariant self.next == null || K < CLASSES && Global::owns(self.next, CACHE_MIN << K, 16)
{
    next: *mut RecNode<K>,
}

/// The cached records of class `K`, the last one cached first.
pub(package) struct RecList<const K: usize>
    invariant self.head == null || K < CLASSES && Global::owns(self.head, CACHE_MIN << K, 16)
{
    head: *mut RecNode<K>,
}

extend<const K: usize> RecList<K> {
    /// No record.
    pub(package) const fn empty() RecList<K> {
        return RecList::<K> { head: null };
    }

    /// The last record cached, which leaves the class; null when it has none.
    pub(package) const fn take(self: &mut Self) *mut void
        ensures |r| r == null || K < CLASSES && Global::owns(r, CACHE_MIN << K, 16)
    {
        let b = self.head;
        if b != null {
            // The record leaves unlinked: the next one is the class's alone.
            self.head = unsafe (*b).next;
            unsafe (*b).next = null;
        }
        return b;
    }

    /// Cache record `b`.
    pub(package) const fn give(self: &mut Self, b: *mut void)
        requires K < CLASSES && Global::owns(b, CACHE_MIN << K, 16)
    {
        let n = b as *mut RecNode<K>;
        unsafe *n = RecNode::<K> { next: self.head };
        self.head = n;
    }

    /// Free every record of the class.
    pub(package) fn drain(self: &mut Self) {
        let mut g = Global {};
        let mut b = self.head;
        self.head = null;
        while b != null
            invariant b == null || K < CLASSES && Global::owns(b, CACHE_MIN << K, 16)
        {
            let nx = unsafe (*b).next;
            unsafe g.dealloc(b, CACHE_MIN << K, 16);
            b = nx;
        }
    }
}
