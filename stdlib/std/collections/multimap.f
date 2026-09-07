// A map from a key to many values, for append-and-iterate tables: overload sets, adjacency rows,
// the arguments recorded against a call. Every value lives in one shared pool and the values of one
// key form a chain through it, so the map is two allocations whatever the key count - against the
// `Dict(K, List(V))` shape's block and 24-byte header per key - an append is one probe, and
// `deinit` is two frees.
//
// The trade: a key's values are not contiguous. `values(k)` walks the chain in insertion order;
// nothing hands out a `V[]`. `remove_key` unlinks a chain and leaves its slots behind as
// tombstones; `compact` rebuilds the pool without them.
//
// Managed only: stores its allocator once (spec §9.4).

import std.allocator
import std.collections.dict
import std.collections.list
import std.option
import std.test

// End of a chain, and the `first`/`last` of a key with no values.
const NONE: u32 = 0xFFFF_FFFF

// One key's chain: its first and last slot in the pool, and how many slots it has.
pub type Chain = struct {
    first: u32
    last: u32
    count: u32
}

// One value in the pool and the index of the next value of the same key.
pub type Slot = struct(V) {
    value: V
    next: u32
}

// A map from each key to the sequence of values added under it.
//
// The values of every key share one pool, chained per key in insertion order, so the whole map is
// two allocations and adding a value never allocates a block of its own. Values are reached by
// walking a key's chain (`values`, `values_ref`); there is no contiguous `V[]` per key. Removing a
// key unlinks its chain and leaves the slots behind until `compact`.
pub type MultiMap = struct(K, V) {
    chains: UnmanagedDict(K, Chain)
    pool: UnmanagedList(Slot(V))
    // Slots unlinked by `remove_key`, reclaimed by `compact`.
    dead: usize
    allocator: &Allocator
}

// Creates an empty multimap. Nothing allocates until the first `add`.
//
// - `allocator`: kept for the map's whole life; the pool and the key table grow and free through
//   it. Null is the global allocator.
pub fn multimap(allocator: &Allocator? = null) MultiMap($K, $V) {
    let out: MultiMap(K, V)
    out.allocator = allocator.or_global()
    return out
}

// Creates an empty multimap that allocates through `allocator` for its whole life.
pub fn multimap(allocator: &Allocator) MultiMap($K, $V) {
    return multimap(Some(allocator))
}

// Adds `value` under `key`, after any values already there. A key seen for the first time is
// inserted. Panics when the pool or the key table cannot grow.
//
// - `key`: stored on first sight; a later `add` of an equal key reuses the stored one, so an owned
//   key passed again is the caller's to deinit.
// - `value`: owned by the map from here; deinited by `remove_key` or `deinit`.
pub fn add(self: &MultiMap($K, $V), key: K, value: V) {
    const idx = self.pool.len as u32
    self.pool.push(Slot(V) { value = value, next = NONE }, self.allocator)
    const chain = self.chains.get_or_insert_with(key, fn() { Chain { first = NONE, last = NONE,
            count = 0u32 } }, self.allocator)
    if chain.last == NONE {
        chain.first = idx
    } else {
        const tail = &self.pool[chain.last as usize]
        tail.next = idx
    }
    chain.last = idx
    chain.count = chain.count + 1
}

// Returns the number of values under `key`; zero for a key never added or since removed.
pub fn count(self: &MultiMap($K, $V), key: K) usize {
    return self.chains.get(key) match {
        Some(c) => c.count as usize
        None => 0usize
    }
}

// Returns whether `key` has any values.
pub fn contains(self: &MultiMap($K, $V), key: K) bool {
    return self.chains.contains(key)
}

// Returns the number of keys with values.
pub fn len(self: &MultiMap($K, $V)) usize {
    return self.chains.len()
}

// Returns the number of values over every key.
pub fn total(self: &MultiMap($K, $V)) usize {
    return self.pool.len - self.dead
}

// Removes `key` and every value under it, deiniting each value.
//
// The values' slots stay in the pool, unreachable, until `compact` reclaims them; `total` no longer
// counts them. Returns how many values were removed, zero for an absent key.
pub fn remove_key(self: &MultiMap($K, $V), key: K) usize {
    const gone = self.chains.remove(key)
    if gone.is_none() {
        return 0
    }
    let cur = gone.unwrap().first
    while cur != NONE {
        const slot = &self.pool[cur as usize]
        slot.value.deinit()
        cur = slot.next
    }
    self.dead = self.dead + gone.unwrap().count as usize
    return gone.unwrap().count as usize
}

// Rebuilds the pool without the slots `remove_key` left behind, each key's values laid out
// contiguously. A no-op when nothing was removed. References from `values_ref` are invalid
// afterwards. Panics when the new pool cannot be allocated.
pub fn compact(self: &MultiMap($K, $V)) {
    if self.dead == 0 {
        return
    }
    let fresh: UnmanagedList(Slot(V)) = unmanaged_list(self.pool.len - self.dead, self.allocator)
    for e in self.chains {
        const chain = self.chains.get_ref(e.key).unwrap()
        let cur = chain.first
        chain.first = fresh.len as u32
        while cur != NONE {
            const slot = self.pool[cur as usize]
            const link = if slot.next == NONE { NONE } else { (fresh.len + 1) as u32 }
            fresh.push(Slot(V) { value = slot.value, next = link }, self.allocator)
            cur = slot.next
        }
        chain.last = (fresh.len - 1) as u32
    }
    self.pool.deinit(self.allocator)
    self.pool = fresh
    self.dead = 0
}

// Deinits every value and key, then frees the pool and the key table. Idempotent: a second call is
// a no-op.
pub fn deinit(self: &MultiMap($K, $V)) {
    for e in self.chains {
        let cur = e.value.first
        while cur != NONE {
            const slot = &self.pool[cur as usize]
            slot.value.deinit()
            cur = slot.next
        }
    }
    self.pool.deinit(self.allocator)
    self.chains.deinit(self.allocator)
    self.dead = 0
}

// Returns the bytes the pool and the key table occupy: the whole capacity of both, and nothing the
// values own on their own.
pub fn capacity_bytes(self: &MultiMap($K, $V)) usize {
    return self.pool.capacity_bytes() + self.chains.capacity_bytes()
}

// =============================================================================
// Iteration
// =============================================================================

// Iterator over one key's values, by value, in insertion order. A snapshot of the chain: the map is
// not modified while it is being iterated.
pub type ValuesIter = struct(V) {
    pool: &UnmanagedList(Slot(V))
    cur: u32
}

// Iterates the values under `key` by value, in insertion order; nothing for an absent key.
pub fn values(self: &MultiMap($K, $V), key: K) ValuesIter(V) {
    const first = self.chains.get(key) match {
        Some(c) => c.first
        None => NONE
    }
    return .{ pool = &self.pool, cur = first }
}

// An iterator is its own iterable, so adapter chains can consume it.
pub fn iter(it: &ValuesIter($V)) ValuesIter(V) {
    return it.*
}

// Advances and returns the next value, or null at the end of the chain.
pub fn next(it: &ValuesIter($V)) V? {
    if it.cur == NONE {
        return null
    }
    const slot = &it.pool[it.cur as usize]
    it.cur = slot.next
    return Some(slot.value)
}

// Iterator over one key's values by reference into the pool, in insertion order, so a loop can
// write them in place: `for v in m.values_ref(k) { v.* = ... }`. A reference is valid until the
// next `add` or `compact`, either of which may move the pool.
pub type ValuesRefIter = struct(V) {
    pool: &UnmanagedList(Slot(V))
    cur: u32
}

// Iterates the values under `key` by reference, in insertion order; nothing for an absent key.
pub fn values_ref(self: &MultiMap($K, $V), key: K) ValuesRefIter(V) {
    const first = self.chains.get(key) match {
        Some(c) => c.first
        None => NONE
    }
    return .{ pool = &self.pool, cur = first }
}

// An iterator is its own iterable, so adapter chains can consume it.
pub fn iter(it: &ValuesRefIter($V)) ValuesRefIter(V) {
    return it.*
}

// Advances and returns a reference to the next value, or null at the end of the chain.
pub fn next(it: &ValuesRefIter($V)) &V? {
    if it.cur == NONE {
        return null
    }
    const slot = &it.pool[it.cur as usize]
    it.cur = slot.next
    return Some(&slot.value)
}

// Iterates the keys that have values, in unspecified order.
pub fn keys(self: &MultiMap($K, $V)) KeysIter(K, Chain) {
    return self.chains.keys()
}

// =============================================================================
// Tests
// =============================================================================

test "values come back per key in insertion order, interleaved adds notwithstanding" {
    let m: MultiMap(u32, i32) = multimap()
    defer m.deinit()
    m.add(1u32, 10i32)
    m.add(2u32, 20i32)
    m.add(1u32, 11i32)
    m.add(2u32, 21i32)
    m.add(1u32, 12i32)
    assert_eq(m.count(1u32), 3 as usize, "three under key 1")
    assert_eq(m.count(2u32), 2 as usize, "two under key 2")
    assert_eq(m.count(3u32), 0 as usize, "none under an unknown key")
    assert_eq(m.len(), 2 as usize, "two keys")
    assert_eq(m.total(), 5 as usize, "five values")
    let seen = 0i32
    for v in m.values(1u32) {
        seen = seen * 100 + v
    }
    assert_eq(seen, 101112i32, "key 1's values in the order they were added")
    let none = 0i32
    for v in m.values(3u32) {
        none = none + v
    }
    assert_eq(none, 0i32, "an unknown key iterates nothing")
}

test "values_ref writes through, remove_key unlinks, compact reclaims" {
    let counting = counting_allocator(global())
    const alloc = counting.allocator()
    let m: MultiMap(u32, i32) = multimap(&alloc)
    for i in 0..10i32 {
        m.add((i % 3) as u32, i)
    }
    for v in m.values_ref(0u32) {
        v.* = v.* * 10
    }
    let sum = 0i32
    for v in m.values(0u32) {
        sum = sum + v
    }
    assert_eq(sum, 180i32, "0 + 30 + 60 + 90 written through")

    assert_eq(m.remove_key(1u32), 3 as usize, "three values unlinked")
    assert_eq(m.count(1u32), 0 as usize, "the key is gone")
    assert_eq(m.total(), 7 as usize, "seven live values")
    m.compact()
    assert_eq(m.pool.len, 7 as usize, "the pool holds exactly the live values")
    let after = 0i32
    for v in m.values(0u32) {
        after = after + v
    }
    assert_eq(after, 180i32, "chains survive the rebuild")
    let twos = 0i32
    for v in m.values(2u32) {
        twos = twos * 100 + v
    }
    assert_eq(twos, 20508i32, "and keep their order: 2, 5, 8")
    m.add(1u32, 99i32)
    assert_eq(m.count(1u32), 1 as usize, "a removed key can be added again")
    m.deinit()
    assert_eq(counting.live_bytes, 0 as usize, "pool and key table freed")
}
