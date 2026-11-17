# Heap Proofs: Owned Blocks, Shares, Handoffs, Static Invariants

Every build proves that each block an allocator gives is freed at most once, by a holder of it. This
file gives the model and the clauses that state it. The contract syntax is in [basics.md](basics.md).

## Blocks and Their Holders

`A::owns(p, size, align)` (a spec function of the `Allocator` interface) is a block that `A` gave.
`alloc` ensures `r != null`, the alignment and `owns(r, size, align)`; `realloc` requires
`owns(ptr, old_size, align)` (or `ptr == null && old_size == 0`); `dealloc` requires `owns(ptr, size,
align)`. `Global` aligns any power of two. `owns_array::<T, A>(p, n)` is an array of `n` values (null
for none). `alloc_size(n)` and `array_bytes::<T>(n)` state their `panics if` limits.

A block has one holder at a time, as a value does:

- A call takes the blocks its `requires` clauses name and the blocks of the values it receives by value,
  and gives the blocks its `ensures` clauses name and the blocks of the values it returns or writes
  through a `&mut` parameter. `forget(v)` ends `v` without its destructor: its blocks stay with the
  body.
- A value of a type with an invariant holds the blocks its invariant names (`Box`, `Vector`, `String`,
  `Arc`). A `&T` parameter lends its target's blocks: the body may not take one ("cannot prove that
  this takes no block a shared parameter lends").
- The blocks one source gives (one clause, one value) are distinct. A call's takes, a return's gives
  and the values left at a panic must be distinct too ("cannot prove that the blocks this call takes
  are distinct", "... this return gives ...", "... the values left ... hold distinct blocks").
- A raw pointer local holds no block across a loop's header unless the loop's `invariant` states it:
  `while m != null invariant m == null || Global::owns(m, sizeof(Node), alignof(Node)) { .. }`.
- A function with `requires` or `ensures` is a function with clauses: it must also prove that it does
  not panic, or state `panics if` (`panics if true` where it may panic anywhere). A loop invariant
  alone has the same effect.

## Memory Invariants

A struct with an invariant behind a raw pointer is memory that holds the struct's blocks:

- A read through the pointer assumes the invariant (memory holds the blocks it names).
- A write through the pointer opens the struct: the body holds the old value's blocks, and must prove
  the invariant of the new value ("cannot prove the invariant of 'S' after the writes through a
  pointer") at the next call, drop, check that may panic, return or loop header, and before an
  assignment reads or writes another pointer. The memory then holds the new value's blocks. A call of
  `Global`'s methods keeps the struct open (the C heap writes no block but its own).
- To take a block out of memory, write the field that holds it (`(*m).next = null`), then free it.
- A `dealloc` of a typed `*mut S` frees the struct and opens it: the blocks its invariant names are the
  caller's (to free or to give on), and nothing of the freed struct is left to prove. A struct the path
  already wrote through that pointer is open already.
- A write through one pointer ends what the proof knows of memory through another pointer, which may
  alias it. Write the parent record first, then the record it links: `(*p).live = t;` then `(*t).next
  = old;`. In the other order the write through `t` may change `*p`, and the parent's invariant no
  longer follows.
- A block an allocator just gave holds no value until a write of the whole value: neither a read nor
  a write of it assumes its invariant.
- A write through a raw pointer forwards its value to later reads of the same address until the next
  memory event; `p[0]` and `*p` are one address.

## Patterns

- **An invariant reads only its own struct's fields.** A struct that holds a pointer states the size of
  the pointee's block: `invariant self.next == null || Global::owns(self.next, sizeof(Node), alignof(Node))`.
  A node list holds each node through the node before it, and the list's freeing loop names the next
  node in its `invariant`: the `dealloc` of a node gives its `next` block to the loop.
- **A list of blocks of one size class per type.** A const generic parameter gives each class its own
  type and invariant: `RecList<K>` in `std/parallel/rec_cache.spc` holds blocks of `CACHE_MIN << K`
  bytes, and `PoolClass` in `std/alloc/size_class.spc` does the same for `std/alloc/pool.spc`. The pool record
  holds one field per class, and a `switch` on the class picks the field. Keep the list in its own file:
  the file that holds the list's fields proves its invariant, and every other file assumes it.
- **A block whose size a flag selects: one clause over the flag.** A BTree link (`Edge` in
  `std/collections/btree.spc`) holds a node's address plus 1 for a leaf, and its invariant states either
  block with one `owns`: a spec function of the bits gives the size, and both kinds take one alignment. A
  Hive block (`std/collections/hive.spc`) stores the next block's slot count beside its pointer
  (`next_cap`), so its invariant states that block's size.
- **A record two threads hold: a unit each.** The `call_c` record of `std/parallel/blocking.spc` counts
  its holders in an `@counter` field (Counted Shares); the pool thread's unit travels in the job
  (`invariant self.unit == null || rc_share(self.unit, 0, 1)`), and the last holder frees the record.
- **Trusted lemmas only for facts no code can give.** A pointer a C caller gives back (`c_handle` in
  `src/api/c_abi.spc`) is the one left in std and the compiler. A trusted lemma is `@trusted`, has no
  body, and is called next to the operation it describes; no proof checks that pairing.

- **A conformance proves its interface's contract.** Its `requires` and `panics if` must follow from the
  interface's ("cannot prove this 'panics if' from the interface's 'panics if'"), and the interface's
  `ensures` must hold at each return. A conformance that may panic where its interface states no
  `panics if` cannot be written: change the interface, or prove that the body does not panic.
- **A function used as a value has no `requires`**, except as a handoff's entry (Handoffs). Give it the
  blocks it needs through an invariant of its argument's type: `run_ccall` takes the record's unit out of
  its `Job`.

## Counted Shares

A reference count's holders share a block. `rc_share(p, k, n)` is `n` units of counter `k` of block `p`;
`rc_units(p, k)` is the units the body holds now. Units are linear, as blocks are, and at each return
and lent take the units the clauses name must fit in the units held.

Counter `k` is the `k`-th field of the block's struct marked `@counter("guard")`, an integer. The guard
is a spec function of the same file, `guard<struct's generics>(p: *mut S) bool`: what the live
counter holds (the block, or a unit of another counter). The prover counts the units of each counter
and checks every write of the field (error 564):

- **Start:** a whole-struct write `*p = S { .. }`, or a plain store while no unit of `p` exists, takes the
  guard and gives as many units as the literal count.
- **Increase:** `atomic::add_*(&mut (*p).n, 1, ..)`, a `cas` from `o` to `o + 1`, or a plain store of
  the count plus one needs a live block (a unit of `p`) and gives a unit. Check for overflow with a panic.
- **Decrease:** a `sub` of one, a `cas` down by one, or a plain store of the count minus one takes a unit; where the old count was 1 the body
  holds the guard. A `cas(n, 1, 0)` that fails keeps the unit.
- **Lock:** with `@counter_lock`, the all-ones value locks the counter: a `cas` to it gives a lock unit,
  and the atomic store of 1 that unlocks takes it back.

A counter field's address goes only to an atomic operation's first argument (copies and casts are
followed), and a member a guard reads changes only by a whole-struct write. Write the count right after
the reads that decide it, with no call or allocation between. From `std/parallel/arc.spc`:

```superc
struct ArcInner<T> {
    @counter("arc_value_guard")
    pub strong: usize,
    @counter("arc_block_guard")
    @counter_lock
    pub weak: usize,
    pub value: T,
}

// What the live strong count of block `p` holds: the strong handles' weak unit (and the value).
spec fn arc_value_guard<T>(p: *mut ArcInner<T>) bool {
    return rc_share(p, 1, 1);
}

// What the live weak count of block `p` holds: the block.
spec fn arc_block_guard<T>(p: *mut ArcInner<T>) bool {
    return Global::owns(p, sizeof(ArcInner<T>), alignof(ArcInner<T>));
}
```

The handle's invariant names one unit: `invariant self.ptr == null || rc_share(self.ptr, 0, 1)`. Std
counts `Arc`/`Weak`, `Rc` and its `Weak`, the thread result cell, the channel handles and the `call_c`
record this way.

## Handoffs

A function that stores an entry and its argument for a later call (a thread's start, a task's) states
`requires pre_of(entry, arg)`: the caller proves the entry's `requires` of `arg` where it hands them over,
and the blocks those clauses name are the callee's from there. `pre_any(entry)` states them of every
argument (an entry that runs on storage of the callee's own). A function with `requires` may be a value
only as such an argument. The entry states what it takes:

```superc
pub unsafe fn job_entry<F: fn move()>(env: *mut void)
    requires Global::owns(env, sizeof(F), alignof(F))
```

## Static Invariants

```superc
static mut G_STATS: *mut BuildStats = null
    invariant G_STATS == null || Global::owns(G_STATS, sizeof(BuildStats), alignof(BuildStats));
```

- Each clause reads the static ("a static's invariant states a fact of its value: it reads the
  static"). The first value must satisfy it ("cannot prove the invariant of this static's first
  value").
- Each read assumes it. A write, in the static's own file only, opens it; the file proves it again at
  the next call, drop, return or loop header ("cannot prove the invariant of static 'G' here"). A write
  from another file is an error ("a static with an invariant is written in its own file").
- Such a static is read and written by name only: a reference to it (`&mut G`, an atomic through its
  address) is an error.
