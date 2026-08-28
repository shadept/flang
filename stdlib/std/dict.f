// Generic hash map (dictionary) backed by manually managed heap storage. Uses open addressing with
// linear probing for collision resolution.
//
// Probing uses bounded for-in loops over 0..capacity with break, which avoids the need for while
// loops.
//
// The stored hash doubles as the slot state (the combined-hash trick): 0 is EMPTY, 1 is a
// tombstone, and >= 2 is an occupied slot holding the key's hash. `hash_key` remaps the two
// reserved values (`h < 2` becomes `h + 2`), a negligible dent in a 64-bit hash space, and the
// state byte - and its alignment padding - disappears from every entry. A zeroed table is
// all-empty, so `alloc_table` and `clear` stay a plain memset.

import std.allocator
import std.mem
import std.option
import std.string
import std.test

const HASH_EMPTY: usize = 0
const HASH_DEAD: usize = 1

// A single entry in the hash map. `hash` is also the slot state - see the header comment; `key` and
// `value` are meaningful only when it is at least 2.
pub type Entry = struct(K, V) {
    hash: usize
    key: K
    value: V
}

pub type Dict = struct(K, V) {
    entries: &Entry(K, V)
    length: usize
    // Tombstones left by removals. They occupy probe slots until the next rehash, so the load
    // factor must count them or a delete-heavy dict fills up while `length` stays low.
    dead: usize
    cap: usize
    allocator: &Allocator?
}

// Construct an empty Dict. Storage is allocated lazily on the first `set` / `op_set_index`. `K` and
// `V` are inferred from the call's expected type (e.g. `let d: Dict(String, i32) = dict()`).
pub fn dict(allocator: &Allocator? = null) Dict($K, $V) {
    let result: Dict(K, V)
    result.allocator = allocator
    return result
}

pub fn dict(capacity: usize, allocator: &Allocator) Dict($K, $V) {
    return dict(capacity, Some(allocator))
}

// Construct a Dict whose table starts at `capacity` slots, rounded up to a power of two
// (`probe_slot` masks instead of dividing; minimum 8). Growth still triggers at the 75% load
// factor, so the table holds about three quarters of `capacity` entries before its first rehash.
// `dict(0)` is the lazy empty form.
pub fn dict(capacity: usize, allocator: &Allocator? = null) Dict($K, $V) {
    let result: Dict(K, V)
    result.allocator = allocator
    if capacity > 0 {
        alloc_table(&result, next_pow2_min8(capacity))
    }
    return result
}

// The smallest power of two at or above `v`, floored at 8 - every capacity branch must yield one,
// or `probe_slot`'s mask breaks.
fn next_pow2_min8(v: usize) usize {
    let n: usize = 8
    while n < v { n = n * 2 }
    return n
}

// Install a zeroed table of `cap` slots (all states empty). `cap` must be a power of two.
fn alloc_table(self: &Dict($K, $V), cap: usize) {
    const alloc_size: usize = cap * size_of(Entry(K, V))
    const raw: u8[] = self.allocator.or_global().alloc(alloc_size,
        8).expect("dict: allocation failed")
    memset(raw.ptr, 0, alloc_size)
    self.entries = raw.ptr as &Entry(K, V)
    self.cap = cap
}

// Bytes the bucket array occupies. Counts every slot, live or not: a dict holds `cap` slots and
// `len` of them carry an entry. What a key or value owns on the heap of its own is not in here.
pub fn capacity_bytes(self: &Dict($K, $V)) usize {
    return self.cap * size_of(Entry(K, V))
}

// Free the backing storage. The dict should not be used after this. Calls deinit on all stored keys
// and values before freeing.
pub fn deinit(self: &Dict($K, $V)) {
    if self.cap > 0 {
        // Deinit all occupied keys and values
        for i in 0..self.cap as isize {
            const entry: &Entry(K, V) = self.entries + (i as usize)
            if entry.hash >= 2 {
                entry.key.deinit()
                entry.value.deinit()
            }
        }
        self.allocator.or_global()
            .free(slice_from_raw_parts(self.entries, self.cap))
    }

    let zero: usize = 0
    self.entries = zero as &Entry(K, V)
    self.length = 0
    self.dead = 0
    self.cap = 0
}

// Slot for the `i`th linear probe of hash `h`. Capacity is always a power of two (`ensure_capacity`
// starts at 8 and only doubles), so the wrap is a mask - a `%` here is a hardware divide on every
// probe of every lookup.
fn probe_slot(h: usize, i: usize, cap: usize) usize {
    return (h + i) & (cap - 1)
}

// Hash a key using the public hash() function, remapped off the two reserved slot states. Types
// with custom hash semantics (e.g. String, OwnedString) provide their own hash() overload, so Dict
// automatically uses content-aware hashing.
fn hash_key(key: $K) usize {
    const h = hash(key)
    if h < 2 {
        return h + 2
    }
    return h
}

// Returns the number of key-value pairs in the dict.
pub fn len(self: Dict($K, $V)) usize {
    return self.length
}

// Returns true if the dict is empty.
pub fn is_empty(self: Dict($K, $V)) bool {
    return self.length == 0
}

// Make room for one more entry: grow when the insert would push the table past a 75% load factor,
// and on the first insert, when there is no table at all. Tombstones count toward the load - see
// `Dict.dead`.
fn ensure_capacity(self: &Dict($K, $V)) {
    const slots_needed = self.length + self.dead + 1
    if self.cap > 0 and slots_needed * 4 <= self.cap * 3 {
        return
    }

    const old_cap: usize = self.cap
    const old_entries: &Entry(K, V) = self.entries
    // A rehash that mostly clears tombstones keeps its capacity; only live-entry pressure grows the
    // table. Every branch here must yield a power of two - `probe_slot` masks instead of dividing.
    let new_cap: usize = 8
    if old_cap > 0 {
        new_cap = if self.length * 2 <= old_cap { old_cap } else { old_cap * 2 }
    }

    alloc_table(self, new_cap)
    self.length = 0
    self.dead = 0

    // Re-insert old entries
    if old_cap > 0 {
        for i in 0..old_cap as isize {
            const old_entry: &Entry(K, V) = old_entries + (i as usize)
            if old_entry.hash >= 2 {
                self.set(old_entry.key, old_entry.value)
            }
        }
        self.allocator.or_global().free(slice_from_raw_parts(old_entries, old_cap))
    }
}

// Insert or update a key-value pair.
pub fn set(self: &Dict($K, $V), key: K, value: V) {
    self.ensure_capacity()

    const h: usize = hash_key(key)
    let tombstone_idx: usize = self.cap // sentinel: no tombstone found

    for i in 0..self.cap as isize {
        const idx: usize = probe_slot(h, i as usize, self.cap)
        const entry: &Entry(K, V) = self.entries + idx

        if entry.hash == HASH_EMPTY {
            // Empty slot: use tombstone slot if we passed one, otherwise this slot
            const target_idx: usize = if tombstone_idx < self.cap { tombstone_idx } else { idx }
            if tombstone_idx < self.cap {
                self.dead = self.dead - 1
            }
            const target: &Entry(K, V) = self.entries + target_idx
            target.hash = h
            target.key = key
            target.value = value
            self.length = self.length + 1
            return
        }

        if entry.hash == HASH_DEAD {
            // Tombstone: remember first one for potential reuse
            if tombstone_idx == self.cap {
                tombstone_idx = idx
            }
            continue
        }

        // Occupied: check if same key. A stored hash is >= 2, so it can never collide with the
        // reserved states.
        if entry.hash == h {
            if entry.key == key {
                // Key already exists: deinit old value and unused new key
                entry.value.deinit()
                key.deinit()
                entry.value = value
                return
            }
        }
    }

    // Should never reach here if load factor is maintained
    panic("dict: set failed - table full")
}

pub fn set(self: &Dict(OwnedString, $V), key: String, value: V) {
    self.ensure_capacity()

    // Fake OwnedString for comparison - no allocation for lookups.
    const fake = OwnedString { ptr = key.ptr, len = key.len, allocator = null }
    const h: usize = hash_key(fake)
    let tombstone_idx: usize = self.cap

    for i in 0..self.cap as isize {
        const idx: usize = probe_slot(h, i as usize, self.cap)
        const entry: &Entry(OwnedString, V) = self.entries + idx

        if entry.hash == HASH_EMPTY {
            // Empty slot: allocate owned key and insert
            const target_idx: usize = if tombstone_idx < self.cap { tombstone_idx } else { idx }
            if tombstone_idx < self.cap {
                self.dead = self.dead - 1
            }
            const target: &Entry(OwnedString, V) = self.entries + target_idx
            target.hash = h
            target.key = from_view(key, self.allocator)
            target.value = value
            self.length = self.length + 1
            return
        }

        if entry.hash == HASH_DEAD {
            if tombstone_idx == self.cap {
                tombstone_idx = idx
            }
            continue
        }

        if entry.hash == h {
            if entry.key == fake {
                // Key exists: update value only, no key allocation
                entry.value.deinit()
                entry.value = value
                return
            }
        }
    }

    panic("dict: set failed - table full")
}

pub fn op_index(self: Dict($K, $V), key: K) V? {
    return self.get(key)
}

pub fn op_set_index(self: &Dict($K, $V), key: K, value: V) {
    self.set(key, value)
}

// Get the value associated with a key, or null if not found.
pub fn get(self: Dict($K, $V), key: K) V? {
    return Some((self.get_ref(key)?).*)
}

// Get a reference to the value associated with a key, or null if not found.
pub fn get_ref(self: Dict($K, $V), key: K) &V? {
    if self.cap == 0 {
        return null
    }

    const h: usize = hash_key(key)

    for i in 0..self.cap as isize {
        const idx: usize = probe_slot(h, i as usize, self.cap)
        const entry: &Entry(K, V) = self.entries + idx

        if entry.hash == HASH_EMPTY {
            return null
        }

        // A stored hash is >= 2, so a hash match implies an occupied slot; tombstones (1) fall
        // through and keep probing.
        if entry.hash == h {
            if entry.key == key {
                return Some(&entry.value)
            }
        }
    }

    return null
}

pub fn get(self: Dict(OwnedString, $V), key: String) V? {
    return Some((self.get_ref(key)?).*)
}

pub fn get_ref(self: Dict(OwnedString, $V), key: String) &V? {
    const fake = OwnedString { ptr = key.ptr, len = key.len, allocator = null }
    return get_ref(self, fake)
}

// Check if a key exists in the dict.
pub fn contains(self: Dict($K, $V), key: K) bool {
    if self.cap == 0 {
        return false
    }

    const h: usize = hash_key(key)

    for i in 0..self.cap as isize {
        const idx: usize = probe_slot(h, i as usize, self.cap)
        const entry: &Entry(K, V) = self.entries + idx

        if entry.hash == HASH_EMPTY {
            return false
        }

        if entry.hash == h {
            if entry.key == key {
                return true
            }
        }
    }

    return false
}

pub fn contains(self: Dict(OwnedString, $V), key: String) bool {
    const fake = OwnedString { ptr = key.ptr, len = key.len, allocator = null }
    return contains(self, fake)
}

// String-key removal for `Dict(OwnedString, V)`: take a `String` view, fabricate a non-owning
// OwnedString just for the hash/compare, and delegate. Mirrors the `set`/`contains` overload above.
pub fn remove(self: &Dict(OwnedString, $V), key: String) V? {
    const fake = OwnedString { ptr = key.ptr, len = key.len, allocator = null }
    return remove(self, fake)
}

// Remove a key from the dict. Returns the removed value, or null if not found.
pub fn remove(self: &Dict($K, $V), key: K) V? {
    if self.cap == 0 {
        return null
    }

    const h: usize = hash_key(key)

    for i in 0..self.cap as isize {
        const idx: usize = probe_slot(h, i as usize, self.cap)
        const entry: &Entry(K, V) = self.entries + idx

        if entry.hash == HASH_EMPTY {
            return null
        }

        if entry.hash == h {
            if entry.key == key {
                const val: V = entry.value
                entry.key.deinit()
                entry.hash = HASH_DEAD
                self.length = self.length - 1
                self.dead = self.dead + 1
                return Some(val)
            }
        }
    }

    return null
}

// Remove all entries from the dict without freeing backing storage. Deinits all stored keys and
// values.
pub fn clear(self: &Dict($K, $V)) {
    if self.cap > 0 {
        for i in 0..self.cap as isize {
            const entry: &Entry(K, V) = self.entries + (i as usize)
            if entry.hash >= 2 {
                entry.key.deinit()
                entry.value.deinit()
            }
        }
        const bytes: usize = self.cap * size_of(Entry(K, V))
        memset(self.entries as &u8, 0, bytes)
    }
    self.length = 0
    self.dead = 0
}

// =============================================================================
// Dict Iterator
// =============================================================================

pub type DictIterator = struct(K, V) {
    dict: &Dict(K, V)
    current: usize
}

// Create iterator from dict
pub fn iter(dict: &Dict($K, $V)) DictIterator(K, V) {
    return .{ dict = dict, current = 0 }
}

// An iterator is its own iterable, so `for e in d.iter()` and the std.iter combinators can consume
// it.
pub fn iter(it: &DictIterator($K, $V)) DictIterator(K, V) {
    return it.*
}

// Advance iterator and return next occupied entry
pub fn next(it: &DictIterator($K, $V)) Entry(K, V)? {
    for idx in it.current..it.dict.cap {
        const entry: &Entry(K, V) = it.dict.entries + idx
        if entry.hash >= 2 {
            it.current = idx + 1
            // Wrapped explicitly - see the note in core/range.f::next.
            return Some(entry.*)
        }
    }
    it.current = it.dict.cap
    return null
}

test "a capacity constructor preallocates a power-of-two table" {
    let d: Dict(u32, u32) = dict(100)
    defer d.deinit()
    assert_eq(d.cap, 128 as usize, "rounded up to the next power of two")
    for i in 0..64usize {
        d.set(i as u32, i as u32)
    }
    assert_eq(d.cap, 128 as usize, "no growth below the load factor")
    assert_eq(d.len(), 64 as usize, "every entry present")

    let e: Dict(u32, u32) = dict(32768)
    defer e.deinit()
    assert_eq(e.cap, 32768 as usize, "an exact power of two is kept")

    let z: Dict(u32, u32) = dict(0)
    defer z.deinit()
    assert_eq(z.cap, 0 as usize, "zero stays the lazy empty form")
}

test "a key whose hash is a reserved state still round-trips" {
    // mix64(0) is 0, so the key 0u32 naturally hashes to EMPTY's reserved value - `hash_key` must
    // remap it or the entry reads as a hole.
    let d: Dict(u32, i32) = dict()
    defer d.deinit()
    d.set(0u32, 7i32)
    d.set(9u32, 9i32)
    assert_eq(d.get(0u32).unwrap(), 7i32, "the remapped key reads back")
    assert_true(d.contains(0u32), "and is visible to contains")
    assert_eq(d.remove(0u32).unwrap(), 7i32, "and removes")
    assert_true(!d.contains(0u32), "gone after removal")
    d.set(0u32, 8i32)
    assert_eq(d.get(0u32).unwrap(), 8i32, "reinserts through the tombstone")
    assert_eq(d.len(), 2 as usize, "the other entry is untouched")
}

test "delete-heavy churn never fills the table" {
    let d: Dict(u32, u32) = dict()
    defer d.deinit()
    for i in 0..64usize {
        d.set(i as u32, 1u32)
        let _r = d.remove(i as u32)
    }
    d.set(7u32, 2u32)
    assert_eq(d.len(), 1 as usize, "one live entry after churn")
    assert_eq(d.get(7u32).unwrap(), 2u32, "the surviving entry reads back")
    assert_eq(d.cap, 8 as usize, "tombstone rehashes keep the capacity")
}

// =============================================================================
// Keys / values iterators
//
// Lightweight projections of DictIterator. Materialize with std.iter's `to_list()`:
// `d.keys().to_list()`.
// =============================================================================

pub type KeysIter = struct(K, V) {
    it: DictIterator(K, V)
}

pub fn iter(self: &KeysIter($K, $V)) KeysIter(K, V) {
    return self.*
}

pub fn next(self: &KeysIter($K, $V)) K? {
    let e = self.it.next()
    if e.is_none() {
        return null
    }
    return Some(e.unwrap().key)
}

pub fn keys(self: &Dict($K, $V)) KeysIter(K, V) {
    return .{ it = self.iter() }
}

pub type ValuesIter = struct(K, V) {
    it: DictIterator(K, V)
}

pub fn iter(self: &ValuesIter($K, $V)) ValuesIter(K, V) {
    return self.*
}

pub fn next(self: &ValuesIter($K, $V)) V? {
    let e = self.it.next()
    if e.is_none() {
        return null
    }
    return Some(e.unwrap().value)
}

pub fn values(self: &Dict($K, $V)) ValuesIter(K, V) {
    return .{ it = self.iter() }
}

// =============================================================================
// Functional utilities
//
// Callbacks are duck-typed `$F` (RFC-014): entry-wise callbacks take
// `(key, value)` as two arguments. Derived dicts copy entries shallowly —
// the same convention as List's transformations.
// =============================================================================

// The allocator a derived dict should use: the caller's if given, otherwise
// the receiver's. Kept optional — resolution happens at the allocating leaf.
fn dict_derived_allocator(own: &Allocator?, override: &Allocator?) &Allocator? {
    if override.is_some() {
        return override
    }
    return own
}

// A new dict with the same keys and `f(key, value)` as values.
pub fn map_values(self: &Dict($K, $V), f: $F, allocator: &Allocator? = null) Dict(K, $U) {
    let out: Dict(K, U) = dict(dict_derived_allocator(self.allocator, allocator))
    for e in self.iter() {
        out.set(e.key, f(e.key, e.value))
    }
    return out
}

// The entries `pred(key, value)` accepts.
pub fn filter(self: &Dict($K, $V), pred: $F, allocator: &Allocator? = null) Dict(K, V) {
    let out: Dict(K, V) = dict(dict_derived_allocator(self.allocator, allocator))
    for e in self.iter() {
        if pred(e.key, e.value) {
            out.set(e.key, e.value)
        }
    }
    return out
}

// Run `f(key, value)` on every entry. Iteration order is unspecified.
pub fn each(self: &Dict($K, $V), f: $F) {
    for e in self.iter() {
        f(e.key, e.value)
    }
}

// Whether any entry satisfies `pred(key, value)`. False for an empty dict.
pub fn any(self: &Dict($K, $V), pred: $F) bool {
    for e in self.iter() {
        if pred(e.key, e.value) {
            return true
        }
    }
    return false
}

// Whether every entry satisfies `pred(key, value)`. True for an empty dict.
pub fn all(self: &Dict($K, $V), pred: $F) bool {
    for e in self.iter() {
        let ok: bool = pred(e.key, e.value)
        if !ok {
            return false
        }
    }
    return true
}

// Number of entries `pred(key, value)` accepts.
pub fn count(self: &Dict($K, $V), pred: $F) usize {
    let n: usize = 0
    for e in self.iter() {
        if pred(e.key, e.value) {
            n = n + 1
        }
    }
    return n
}

// The value for `key`, or `fallback` when absent.
pub fn get_or(self: Dict($K, $V), key: K, fallback: V) V {
    let v = self.get(key)
    if v.is_some() {
        return v.unwrap()
    }
    return fallback
}

// The value for `key`, or `make()` when absent - the lazy counterpart of `get_or`, for fallbacks
// that are expensive (or effectful) to build.
pub fn get_or_else(self: Dict($K, $V), key: K, make: $F) V {
    let v = self.get(key)
    if v.is_some() {
        return v.unwrap()
    }
    return make()
}

// Mutate the value for `key` in place via `f(&value)`. Returns whether the key was present.
// In-place mutation (not get-modify-set) is the only sound shape for owned values: `set` deinits
// the value it overwrites.
pub fn update(self: &Dict($K, $V), key: K, f: $F) bool {
    let r = self.get_ref(key)
    if r.is_none() {
        return false
    }
    f(r.unwrap())
    return true
}

// Copy every entry of `other` into `self`, overwriting on key collisions. Entries are copied
// shallowly: with owned keys or values, both dicts end
// up referencing the same buffers — deinit only one of them.
pub fn merge(self: &Dict($K, $V), other: &Dict(K, V)) {
    for e in other.iter() {
        self.set(e.key, e.value)
    }
}

test "keys and values iterate the live entries" {
    // std.iter (to_list etc.) can't be imported here — see the harness test
    // stdlib_dict_iter_chain for combinator chains over keys()/values().
    let d: Dict(u32, i32) = dict()
    defer d.deinit()
    d.set(1u32, 10i32)
    d.set(2u32, 20i32)

    let key_sum = 0u32
    for k in d.keys() {
        key_sum = key_sum + k
    }
    assert_eq(key_sum, 3u32, "both keys visited")

    let value_sum = 0i32
    for v in d.values() {
        value_sum = value_sum + v
    }
    assert_eq(value_sum, 30i32, "both values visited")
}

test "map_values filter each any all count" {
    let d: Dict(u32, i32) = dict()
    defer d.deinit()
    d.set(1u32, 1i32)
    d.set(2u32, 2i32)
    d.set(3u32, 3i32)

    let scale = 10i32
    let scaled = d.map_values(fn(k, v) { v * scale })
    defer scaled.deinit()
    assert_eq(scaled.get(2u32).unwrap(), 20i32, "value mapped, key kept")
    assert_eq(scaled.len(), 3 as usize, "same entry count")

    let evens = d.filter(fn(k, v) { v % 2 == 0 })
    defer evens.deinit()
    assert_eq(evens.len(), 1 as usize, "one even value")
    assert_eq(evens.get(2u32).unwrap(), 2i32, "the right entry survived")

    let sum = 0i32
    let sum_ref = &sum
    d.each(fn(k, v) { sum_ref.* = sum_ref.* + v })
    assert_eq(sum, 6i32, "each visited every entry")

    assert_true(d.any(fn(k, v) { v > 2 }), "one value exceeds 2")
    assert_true(!d.all(fn(k, v) { v > 2 }), "not all do")
    assert_eq(d.count(fn(k, v) { v > 1 }), 2 as usize, "two values exceed 1")
}

test "get_or update merge" {
    let d: Dict(u32, i32) = dict()
    defer d.deinit()
    d.set(1u32, 5i32)

    assert_eq(d.get_or(1u32, 0i32), 5i32, "present key reads its value")
    assert_eq(d.get_or(9u32, -1i32), -1i32, "absent key reads the fallback")
    assert_eq(d.get_or_else(1u32, fn() { 0i32 }), 5i32, "present key skips the fallback fn")
    let expensive = 42i32
    assert_eq(d.get_or_else(9u32, fn() { expensive }), 42i32, "absent key computes it")

    assert_true(d.update(1u32, fn(v) { v.* = v.* + 1i32 }), "update hits the key")
    assert_eq(d.get(1u32).unwrap(), 6i32, "mutated in place")
    assert_true(!d.update(9u32, fn(v) { v.* = 0i32 }), "absent key reports false")

    let other: Dict(u32, i32) = dict()
    defer other.deinit()
    other.set(1u32, 100i32)
    other.set(2u32, 200i32)
    d.merge(&other)
    assert_eq(d.len(), 2 as usize, "merged entry added")
    assert_eq(d.get(1u32).unwrap(), 100i32, "collision overwritten by other")
}
