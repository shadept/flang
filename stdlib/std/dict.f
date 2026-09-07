// Hash maps in two flavours, the managed and unmanaged split of spec §9.4:
//
//   UnmanagedDict(K, V)  the table: `entries`, `length`, `dead`, `cap`, and every operation on it.
//                        The ones that allocate or free take the allocator as an argument
//                        (`d.set(k, v, alloc)`), so a composite stores one allocator for all its
//                        children and passes it at the call that allocates.
//   Dict(K, V)           an `UnmanagedDict` with its allocator beside it (`d.set(k, v)`). It reaches
//                        the table through `op_deref`, so `d.len()` and `d.get(k)` read the same on
//                        either, and its allocating functions are one-line wrappers. A null
//                        allocator is the global one (§4.1), so a zero-initialised `Dict` is a
//                        valid empty dict.
//
// `__storage` is readable like any field; treat it as private. Calling the unmanaged API on a
// `Dict` through it, or through the `op_deref` peel (`d.set(k, v, other_alloc)`), compiles and
// mixes allocators.
//
// Open addressing with linear probing. The stored hash doubles as the slot state (the combined-hash
// trick): 0 is EMPTY, 1 is a tombstone, and >= 2 is an occupied slot holding the key's hash.
// `hash_key` remaps the two reserved values (`h < 2` becomes `h + 2`), a negligible dent in a
// 64-bit hash space, and the state byte - and its alignment padding - disappears from every entry.
// A zeroed table is all-empty, so `alloc_table` and `clear` stay a plain memset.

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

pub type UnmanagedDict = struct(K, V) {
    entries: &Entry(K, V)
    length: usize
    // Tombstones left by removals. They occupy probe slots until the next rehash, so the load
    // factor must count them or a delete-heavy dict fills up while `length` stays low.
    dead: usize
    cap: usize
}

pub type Dict = struct(K, V) {
    __storage: UnmanagedDict(K, V)
    allocator: &Allocator
}

// Reaches the table: `d.len()`, `d.get(k)` and every `UnmanagedDict` read resolve through this.
pub fn op_deref(self: &Dict($K, $V)) &UnmanagedDict(K, V) {
    return &self.__storage
}

// =============================================================================
// Construction
// =============================================================================

// Creates an unmanaged dict whose table starts at `capacity` slots, rounded up to a power of two
// (`probe_slot` masks instead of dividing; minimum 8). Zero allocates nothing; a zero-initialised
// `UnmanagedDict` is the same empty dict. Growth still triggers at the 75% load factor, so the
// table holds about three quarters of `capacity` entries before its first rehash.
//
// - `allocator`: grows and frees the table. Pass the same one to every allocating call.
//
// Panics when the allocation fails.
pub fn unmanaged_dict(capacity: usize, allocator: &Allocator) UnmanagedDict($K, $V) {
    let out: UnmanagedDict(K, V)
    if capacity > 0 {
        out.alloc_table(next_pow2_min8(capacity), allocator)
    }
    return out
}

// Construct an empty Dict. Storage is allocated lazily on the first `set` / `op_set_index`. `K` and
// `V` are inferred from the call's expected type (e.g. `let d: Dict(String, i32) = dict()`).
pub fn dict(allocator: &Allocator? = null) Dict($K, $V) {
    let out: Dict(K, V)
    out.allocator = allocator.unwrap_or(0usize as &Allocator)
    return out
}

pub fn dict(capacity: usize, allocator: &Allocator) Dict($K, $V) {
    return dict(capacity, Some(allocator))
}

// Construct a Dict whose table starts at `capacity` slots, rounded up as `unmanaged_dict` does.
// `dict(0)` is the lazy empty form.
//
// - `allocator`: kept for the dict's whole life. Null is the global allocator.
pub fn dict(capacity: usize, allocator: &Allocator? = null) Dict($K, $V) {
    let out: Dict(K, V)
    out.allocator = allocator.unwrap_or(0usize as &Allocator)
    out.__storage = unmanaged_dict(capacity, out.allocator)
    return out
}

// The smallest power of two at or above `v`, floored at 8 - every capacity branch must yield one,
// or `probe_slot`'s mask breaks.
fn next_pow2_min8(v: usize) usize {
    let n: usize = 8
    while n < v { n = n * 2 }
    return n
}

// Install a zeroed table of `cap` slots (all states empty). `cap` must be a power of two.
fn alloc_table(self: &UnmanagedDict($K, $V), cap: usize, allocator: &Allocator) {
    const alloc_size: usize = cap * size_of(Entry(K, V))
    const raw: u8[] = allocator.alloc(alloc_size, 8).expect("dict: allocation failed")
    memset(raw.ptr, 0, alloc_size)
    self.entries = raw.ptr as &Entry(K, V)
    self.cap = cap
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
    const h = key.hash()
    if h < 2 {
        return h + 2
    }
    return h
}

// A borrowed `String` dressed as an `OwnedString` so it hashes and compares like one - no
// allocation for a lookup by view.
fn fake_owned(key: String) OwnedString {
    return .{ ptr = key.ptr, len = key.len, allocator = null }
}

// =============================================================================
// UnmanagedDict: growth and release, allocator explicit
// =============================================================================

// Make room for one more entry: grow when the insert would push the table past a 75% load factor,
// and on the first insert, when there is no table at all. Tombstones count toward the load - see
// `UnmanagedDict.dead`.
fn ensure_capacity(self: &UnmanagedDict($K, $V), allocator: &Allocator) {
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

    self.alloc_table(new_cap, allocator)
    self.length = 0
    self.dead = 0

    if old_cap > 0 {
        for i in 0..old_cap {
            const old_entry: &Entry(K, V) = old_entries + i
            if old_entry.hash >= 2 {
                self.place(old_entry.hash, old_entry.key, old_entry.value)
            }
        }
        allocator.free(slice_from_raw_parts(old_entries, old_cap))
    }
}

// Store a key known to be absent in the first tombstone or empty slot on its probe sequence. The
// table must have room (`ensure_capacity`).
fn place(self: &UnmanagedDict($K, $V), h: usize, key: K, value: V) {
    for i in 0..self.cap {
        const entry: &Entry(K, V) = self.entries + probe_slot(h, i, self.cap)
        if entry.hash == HASH_EMPTY or entry.hash == HASH_DEAD {
            if entry.hash == HASH_DEAD {
                self.dead = self.dead - 1
            }
            entry.hash = h
            entry.key = key
            entry.value = value
            self.length = self.length + 1
            return
        }
    }
    // Unreachable while the load factor is maintained
    panic("dict: set failed - table full")
}

// Insert or update a key-value pair. On an update the old value is deinited, and so is `key`, since
// the entry keeps the one it already has. Panics when the allocation fails.
pub fn set(self: &UnmanagedDict($K, $V), key: K, value: V, allocator: &Allocator) {
    const existing = self.get_ref(key)
    if existing.is_some() {
        const slot = existing.unwrap()
        slot.deinit()
        slot.* = value
        key.deinit()
        return
    }
    self.ensure_capacity(allocator)
    self.place(hash_key(key), key, value)
}

// String-key insert for `UnmanagedDict(OwnedString, V)`: the key is a borrowed view, copied into an
// owned key only when it is new to the table.
pub fn set(self: &UnmanagedDict(OwnedString, $V), key: String, value: V, allocator: &Allocator) {
    const fake = fake_owned(key)
    const existing = self.find_entry(fake)
    if existing.is_some() {
        const entry = existing.unwrap()
        entry.value.deinit()
        entry.value = value
        return
    }
    self.ensure_capacity(allocator)
    self.place(hash_key(fake), from_view(key, allocator), value)
}

// Deinits every live key and value, frees the table and resets to empty, so a second call is a
// no-op.
pub fn deinit(self: &UnmanagedDict($K, $V), allocator: &Allocator) {
    if self.cap > 0 {
        self.deinit_entries()
        allocator.free(slice_from_raw_parts(self.entries, self.cap))
    }
    self.entries = 0usize as &Entry(K, V)
    self.length = 0
    self.dead = 0
    self.cap = 0
}

// Copy every entry of `other` into `self`, overwriting on key collisions. Entries are copied
// shallowly: with owned keys or values, both dicts end up referencing the same buffers - deinit
// only one of them.
pub fn merge(self: &UnmanagedDict($K, $V), other: &UnmanagedDict(K, V), allocator: &Allocator) {
    for e in other.iter() {
        self.set(e.key, e.value, allocator)
    }
}

// =============================================================================
// UnmanagedDict: in-place mutation
// =============================================================================

// Remove a key from the dict. Returns the removed value, or null if not found.
pub fn remove(self: &UnmanagedDict($K, $V), key: K) V? {
    const found = self.find_entry(key)
    if found.is_none() {
        return null
    }
    const entry = found.unwrap()
    const val: V = entry.value
    entry.key.deinit()
    entry.hash = HASH_DEAD
    self.length = self.length - 1
    self.dead = self.dead + 1
    return Some(val)
}

pub fn remove(self: &UnmanagedDict(OwnedString, $V), key: String) V? {
    return remove(self, fake_owned(key))
}

// Remove all entries from the dict without freeing backing storage. Deinits all stored keys and
// values.
pub fn clear(self: &UnmanagedDict($K, $V)) {
    if self.cap > 0 {
        self.deinit_entries()
        memset(self.entries as &u8, 0, self.cap * size_of(Entry(K, V)))
    }
    self.length = 0
    self.dead = 0
}

// Deinit every live key and value, leaving the slots as they are.
fn deinit_entries(self: &UnmanagedDict($K, $V)) {
    for i in 0..self.cap {
        const entry: &Entry(K, V) = self.entries + i
        if entry.hash >= 2 {
            entry.key.deinit()
            entry.value.deinit()
        }
    }
}

// Mutate the value for `key` in place via `f(&value)`. Returns whether the key was present.
// In-place mutation (not get-modify-set) is the only sound shape for owned values: `set` deinits
// the value it overwrites.
pub fn update(self: &UnmanagedDict($K, $V), key: K, f: $F) bool {
    let r = self.get_ref(key)
    if r.is_none() {
        return false
    }
    f(r.unwrap())
    return true
}

// =============================================================================
// UnmanagedDict: reads
// =============================================================================

// The live entry for `key`, or null. Tombstones fall through and keep probing; the first empty slot
// ends the search.
fn find_entry(self: &UnmanagedDict($K, $V), key: K) &Entry(K, V)? {
    if self.cap == 0 {
        return null
    }
    const h: usize = hash_key(key)
    for i in 0..self.cap {
        const entry: &Entry(K, V) = self.entries + probe_slot(h, i, self.cap)
        if entry.hash == HASH_EMPTY {
            return null
        }
        // A stored hash is >= 2, so a hash match implies an occupied slot and can never collide
        // with the reserved states.
        if entry.hash == h {
            if entry.key == key {
                return Some(entry)
            }
        }
    }
    return null
}

// Bytes the bucket array occupies. Counts every slot, live or not: a dict holds `cap` slots and
// `len` of them carry an entry. What a key or value owns on the heap of its own is not in here.
pub fn capacity_bytes(self: &UnmanagedDict($K, $V)) usize {
    return self.cap * size_of(Entry(K, V))
}

// Returns the number of key-value pairs in the dict.
pub fn len(self: &UnmanagedDict($K, $V)) usize {
    return self.length
}

// Returns true if the dict is empty.
pub fn is_empty(self: &UnmanagedDict($K, $V)) bool {
    return self.length == 0
}

pub fn op_index(self: &UnmanagedDict($K, $V), key: K) V? {
    return self.get(key)
}

// Get the value associated with a key, or null if not found.
pub fn get(self: &UnmanagedDict($K, $V), key: K) V? {
    return Some((self.get_ref(key)?).*)
}

// Get a reference to the value associated with a key, or null if not found.
pub fn get_ref(self: &UnmanagedDict($K, $V), key: K) &V? {
    const found = self.find_entry(key)
    if found.is_none() {
        return null
    }
    const entry = found.unwrap()
    return Some(&entry.value)
}

pub fn get(self: &UnmanagedDict(OwnedString, $V), key: String) V? {
    return Some((self.get_ref(key)?).*)
}

pub fn get_ref(self: &UnmanagedDict(OwnedString, $V), key: String) &V? {
    return get_ref(self, fake_owned(key))
}

// Check if a key exists in the dict.
pub fn contains(self: &UnmanagedDict($K, $V), key: K) bool {
    return self.find_entry(key).is_some()
}

pub fn contains(self: &UnmanagedDict(OwnedString, $V), key: String) bool {
    return contains(self, fake_owned(key))
}

// The value for `key`, or `fallback` when absent.
pub fn get_or(self: &UnmanagedDict($K, $V), key: K, fallback: V) V {
    let v = self.get(key)
    if v.is_some() {
        return v.unwrap()
    }
    return fallback
}

// The value for `key`, or `make()` when absent - the lazy counterpart of `get_or`, for fallbacks
// that are expensive (or effectful) to build.
pub fn get_or_else(self: &UnmanagedDict($K, $V), key: K, make: $F) V {
    let v = self.get(key)
    if v.is_some() {
        return v.unwrap()
    }
    return make()
}

// Run `f(key, value)` on every entry. Iteration order is unspecified.
pub fn each(self: &UnmanagedDict($K, $V), f: $F) {
    for e in self.iter() {
        f(e.key, e.value)
    }
}

// Whether any entry satisfies `pred(key, value)`. False for an empty dict.
pub fn any(self: &UnmanagedDict($K, $V), pred: $F) bool {
    for e in self.iter() {
        if pred(e.key, e.value) {
            return true
        }
    }
    return false
}

// Whether every entry satisfies `pred(key, value)`. True for an empty dict.
pub fn all(self: &UnmanagedDict($K, $V), pred: $F) bool {
    for e in self.iter() {
        let ok: bool = pred(e.key, e.value)
        if !ok {
            return false
        }
    }
    return true
}

// Number of entries `pred(key, value)` accepts.
pub fn count(self: &UnmanagedDict($K, $V), pred: $F) usize {
    let n: usize = 0
    for e in self.iter() {
        if pred(e.key, e.value) {
            n = n + 1
        }
    }
    return n
}

// =============================================================================
// Iterators
// =============================================================================

pub type DictIterator = struct(K, V) {
    dict: &UnmanagedDict(K, V)
    current: usize
}

// Iterates the live entries, in unspecified order.
pub fn iter(dict: &UnmanagedDict($K, $V)) DictIterator(K, V) {
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

// Lightweight projections of DictIterator. Materialize with std.iter's `to_list()`:
// `d.keys().to_list()`.
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

pub fn keys(self: &UnmanagedDict($K, $V)) KeysIter(K, V) {
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

pub fn values(self: &UnmanagedDict($K, $V)) ValuesIter(K, V) {
    return .{ it = self.iter() }
}

// =============================================================================
// UnmanagedDict: derived dicts, allocator explicit
//
// Callbacks are duck-typed `$F` (RFC-014) and take `(key, value)`. Entries are copied shallowly,
// the same convention as List's transformations.
// =============================================================================

// A new dict with the same keys and `f(key, value)` as values.
pub fn map_values(self: &UnmanagedDict($K, $V), f: $F, allocator: &Allocator) UnmanagedDict(K, $U) {
    let out: UnmanagedDict(K, U)
    for e in self.iter() {
        out.set(e.key, f(e.key, e.value), allocator)
    }
    return out
}

// The entries `pred(key, value)` accepts.
pub fn filter(self: &UnmanagedDict($K, $V), pred: $F, allocator: &Allocator) UnmanagedDict(K, V) {
    let out: UnmanagedDict(K, V)
    for e in self.iter() {
        if pred(e.key, e.value) {
            out.set(e.key, e.value, allocator)
        }
    }
    return out
}

// =============================================================================
// Dict: the managed API
//
// The same operations over the dict's own allocator. A derived dict takes an optional allocator for
// its result and otherwise uses the receiver's.
// =============================================================================

// Insert or update a key-value pair. Panics when the allocation fails.
pub fn set(self: &Dict($K, $V), key: K, value: V) {
    self.__storage.set(key, value, self.allocator)
}

pub fn set(self: &Dict(OwnedString, $V), key: String, value: V) {
    self.__storage.set(key, value, self.allocator)
}

pub fn op_set_index(self: &Dict($K, $V), key: K, value: V) {
    self.__storage.set(key, value, self.allocator)
}

// Indexing and `for` resolve through `op_deref` since 2026-09-07 (spec.md §7), but the committed
// seed's checker still stops at the wrapper; these wrappers stay until the next promote.
pub fn op_index(self: &Dict($K, $V), key: K) V? {
    return self.__storage.get(key)
}

pub fn iter(self: &Dict($K, $V)) DictIterator(K, V) {
    return self.__storage.iter()
}

// Deinits every live key and value and frees the table. Idempotent: a second call is a no-op.
pub fn deinit(self: &Dict($K, $V)) {
    self.__storage.deinit(self.allocator)
}

// Copy every entry of `other` into `self`, overwriting on key collisions - see the unmanaged
// `merge` for the aliasing caveat.
pub fn merge(self: &Dict($K, $V), other: &Dict(K, V)) {
    self.__storage.merge(&other.__storage, self.allocator)
}

// A new dict with the same keys and `f(key, value)` as values.
pub fn map_values(self: &Dict($K, $V), f: $F, allocator: &Allocator? = null) Dict(K, $U) {
    const alloc = allocator ?? self.allocator
    return .{ __storage = self.__storage.map_values(f, alloc), allocator = alloc }
}

// The entries `pred(key, value)` accepts.
pub fn filter(self: &Dict($K, $V), pred: $F, allocator: &Allocator? = null) Dict(K, V) {
    const alloc = allocator ?? self.allocator
    return .{ __storage = self.__storage.filter(pred, alloc), allocator = alloc }
}

// =============================================================================
// Tests
// =============================================================================

test "an UnmanagedDict takes its allocator at every allocating call" {
    let counting = counting_allocator(global())
    const alloc = counting.allocator()
    let d: UnmanagedDict(u32, i32) = unmanaged_dict(0, &alloc)
    d.set(1u32, 10i32, &alloc)
    d.set(2u32, 20i32, &alloc)
    d.set(1u32, 11i32, &alloc)
    assert_eq(d.len(), 2 as usize, "an update does not add an entry")
    assert_eq(d.get(1u32).unwrap(), 11i32, "the update took")
    assert_true(d.contains(2u32), "contains")
    assert_eq(d.remove(2u32).unwrap(), 20i32, "remove hands back the value")
    let sum = 0i32
    for e in d {
        sum = sum + e.value
    }
    assert_eq(sum, 11i32, "for over the live entries")
    const doubled = d.map_values(fn(k, v) { v * 2 }, &alloc)
    assert_eq(doubled.get(1u32).unwrap(), 22i32, "derived dict with explicit allocator")
    doubled.deinit(&alloc)
    d.deinit(&alloc)
    assert_eq(counting.live_bytes, 0 as usize, "everything went back through that allocator")
}

test "a zero-initialised Dict is a valid empty dict" {
    let d: Dict(u32, u32)
    defer d.deinit()
    assert_true(d.is_empty(), "empty")
    assert_true(d.get(1u32).is_none(), "a lookup finds nothing")
    d.set(1u32, 2u32)
    assert_eq(d[1u32].unwrap(), 2u32, "and it grows on the first set")
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

test "string keys are copied on insert and looked up by view" {
    // Block counts, not bytes: an OwnedString frees `len` of the `len + 1` it allocated, so a
    // counting allocator's `live_bytes` is inexact with string keys.
    let counting = counting_allocator(global())
    const alloc = counting.allocator()
    let d: Dict(OwnedString, i32) = dict(0, &alloc)
    d.set("one", 1i32)
    d.set("two", 2i32)
    d.set("one", 10i32)
    assert_eq(d.len(), 2 as usize, "an update by view does not add an entry")
    assert_eq(d.get("one").unwrap(), 10i32, "the update took")
    assert_true(d.contains("two"), "contains by view")
    assert_eq(d.remove("two").unwrap(), 2i32, "remove by view")
    assert_true(!d.contains("two"), "gone")
    d.deinit()
    assert_eq(counting.allocs, 3 as usize, "two keys and one table")
    assert_eq(counting.deallocs, counting.allocs,
        "keys and table freed through the dict's allocator")
}

test "keys and values iterate the live entries" {
    // std.iter (to_list etc.) can't be imported here - see the harness test stdlib_dict_iter_chain
    // for combinator chains over keys()/values().
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
