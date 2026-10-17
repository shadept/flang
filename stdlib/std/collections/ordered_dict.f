// Hash maps that iterate in insertion order, in the managed and unmanaged split of spec §9.4:
//
//   UnmanagedOrderedDict(K, V)  the entries and their index; allocating operations take the
//                               allocator as their last argument
//   OrderedDict(K, V)           an `UnmanagedOrderedDict` with its allocator beside it
//
// Entries live in a list in the order their keys were first inserted; updating a key keeps its
// position. The index is an open-addressing table of entry positions (0 is an empty slot, `i + 1`
// is entry `i`) probed linearly, so lookups cost what `Dict`'s do. A removal shifts the later
// entries down and rebuilds the index: O(len).

import std.allocator
import std.collections.list
import std.option
import std.string
import std.test

// One entry: the key's hash, the key and its value.
pub type OrderedEntry = struct(K, V) {
    hash: usize
    key: K
    value: V
}

// Deinits the key and the value.
pub fn deinit(self: move OrderedEntry($K, $V)) {
    release(self.key)
    release(self.value)
}

// A map from `K` to `V` that iterates in insertion order and carries no allocator. A
// zero-initialised value is a valid empty dict. Keys and values are owned: `deinit` deinits each.
pub type UnmanagedOrderedDict = struct(K: Hash + Eq, V) {
    entries: UnmanagedList(OrderedEntry(K, V))
    owned index: &usize
    cap: usize
}

// A map from `K` to `V` that iterates in insertion order and remembers the allocator it grows and
// frees through. Every `UnmanagedOrderedDict` operation applies to it through `op_deref`, the
// allocating ones without the allocator argument. A zero-initialised value is a valid empty dict on
// the global allocator.
pub type OrderedDict = struct(K: Hash + Eq, V) {
    __storage: UnmanagedOrderedDict(K, V)
    allocator: &Allocator
}

// Reaches the storage: `d.len()`, `d.get(k)` and every `UnmanagedOrderedDict` read resolve through
// this.
pub fn op_deref(self: &OrderedDict($K, $V)) &UnmanagedOrderedDict(K, V) {
    return &self.__storage
}

// Creates an empty ordered dict. Nothing allocates until the first insert.
//
// - `allocator`: kept for the dict's whole life. Null is the global allocator.
pub fn ordered_dict(allocator: &Allocator = context.allocator) OrderedDict($K, $V) {
    let empty: UnmanagedOrderedDict(K, V)
    return .{ __storage = move empty, allocator = allocator }
}

// =============================================================================
// Index
// =============================================================================

fn index_slot(self: &UnmanagedOrderedDict($K, $V), i: usize) &usize {
    return self.index + i
}

// Grows the index so one more entry keeps it under a 75% load. Capacity is a power of two.
fn reserve_index(self: &UnmanagedOrderedDict($K, $V), allocator: &Allocator) {
    const needed = self.entries.len + 1
    if self.cap > 0 and needed * 4 <= self.cap * 3 {
        return
    }
    let new_cap: usize = if self.cap == 0 { 8 } else { self.cap * 2 }
    if self.cap > 0 {
        allocator.free(slice_from_raw_parts(self.index, self.cap))
    }
    const raw: u8[] = allocator.alloc(new_cap * size_of(usize), align_of(usize))
        .expect("ordered_dict: allocation failed")
    self.index = raw.ptr as &usize
    self.cap = new_cap
    self.reindex()
}

// Rebuilds the index from the entries.
fn reindex(self: &UnmanagedOrderedDict($K, $V)) {
    for i in 0..self.cap {
        self.index_slot(i).* = 0
    }
    for i in 0..self.entries.len {
        self.place(self.entries[i].hash, i)
    }
}

fn place(self: &UnmanagedOrderedDict($K, $V), h: usize, pos: usize) {
    const mask = self.cap - 1
    for i in 0..self.cap {
        const slot = self.index_slot((h + i) & mask)
        if slot.* == 0 {
            slot.* = pos + 1
            return
        }
    }
    panic("ordered_dict: index full")
}

// The position of the entry whose key equals `key`, or null. `key` is a `K` or a probe whose `hash`
// and `==` agree with `K`'s.
fn find(self: &UnmanagedOrderedDict($K, $V), key: $Q) usize? where Q: Hash {
    if self.cap == 0 {
        return null
    }
    const h = key.hash()
    const mask = self.cap - 1
    for i in 0..self.cap {
        const slot = self.index_slot((h + i) & mask).*
        if slot == 0 {
            return null
        }
        const e = &self.entries[slot - 1]
        if e.hash == h {
            if e.key == key {
                return Some(slot - 1)
            }
        }
    }
    return null
}

fn append(
    self: &UnmanagedOrderedDict($K, $V),
    h: usize,
    key: move K,
    value: move V,
    allocator: &Allocator,
) {
    self.reserve_index(allocator)
    const pos = self.entries.len
    self.entries.push(
        OrderedEntry(K, V) { hash = h, key = move key, value = move value },
        allocator,
    )
    self.place(h, pos)
}

// =============================================================================
// UnmanagedOrderedDict: growth and release, allocator explicit
// =============================================================================

// Inserts or updates. A new key goes last; an existing key keeps its position, its old value is
// deinited, and so is `key`. Panics when the allocation fails.
pub fn set(self: &UnmanagedOrderedDict($K, $V), key: move K, value: move V, allocator: &Allocator) {
    const found = self.find(key)
    if found.is_some() {
        const old = replace(&self.entries[found.unwrap()].value, value)
        release(old)
        release(key)
        return
    }
    self.append(key.hash(), key, value, allocator)
}

// String-key `set` for `UnmanagedOrderedDict(OwnedString, V)`: `key` is copied into an owned key
// only when it is new.
pub fn set(
    self: &UnmanagedOrderedDict(OwnedString, $V),
    key: String,
    value: move V,
    allocator: &Allocator,
) {
    const found = self.find(key)
    if found.is_some() {
        const old = replace(&self.entries[found.unwrap()].value, value)
        release(old)
        return
    }
    self.append(key.hash(), from_view(key, allocator), value, allocator)
}

// Inserts `key` with `value` unless the key is present, and returns whether it was inserted. A
// present key keeps its entry, and `key` and `value` stay the caller's.
pub fn add(
    self: &UnmanagedOrderedDict($K, $V),
    key: move K,
    value: move V,
    allocator: &Allocator,
) bool {
    if self.find(key).is_some() {
        return false
    }
    self.append(key.hash(), key, value, allocator)
    return true
}

// String-key `add` for `UnmanagedOrderedDict(OwnedString, V)`: `key` is copied only when inserted.
pub fn add(
    self: &UnmanagedOrderedDict(OwnedString, $V),
    key: String,
    value: move V,
    allocator: &Allocator,
) bool {
    if self.find(key).is_some() {
        return false
    }
    self.append(key.hash(), from_view(key, allocator), value, allocator)
    return true
}

// Deinits every key and value, frees the storage and resets to empty, so a second call is a no-op.
pub fn deinit(self: move UnmanagedOrderedDict($K, $V), allocator: &Allocator) {
    self.entries.deinit(allocator)
    if self.cap > 0 {
        allocator.free(slice_from_raw_parts(self.index, self.cap))
    }
    self.index = 0usize as &usize
    self.cap = 0
}

// =============================================================================
// UnmanagedOrderedDict: in-place mutation
// =============================================================================

// Removes `key` and returns its value, or null when absent. The stored key is deinited; the value
// is the caller's. Later entries keep their order. O(len).
pub fn remove(self: &UnmanagedOrderedDict($K, $V), key: $Q) V? where Q: Hash {
    const found = self.find(key)
    if found.is_none() {
        return null
    }
    let e = self.entries.remove_at(found.unwrap()).unwrap()
    let k = move e.key
    release(k)
    self.reindex()
    return Some(move e.value)
}

// Removes every entry, deiniting each key and value. The storage is kept for reuse.
pub fn clear(self: &UnmanagedOrderedDict($K, $V)) {
    self.entries.clear()
    self.reindex()
}

// =============================================================================
// UnmanagedOrderedDict: reads
// =============================================================================

// Returns the number of entries.
pub fn len(self: &UnmanagedOrderedDict($K, $V)) usize {
    return self.entries.len
}

// Returns whether there are no entries.
pub fn is_empty(self: &UnmanagedOrderedDict($K, $V)) bool {
    return self.entries.len == 0
}

// Returns whether `key` is present. `key` is a `K` or a probe whose `hash` and `==` agree with
// `K`'s.
pub fn contains(self: &UnmanagedOrderedDict($K, $V), key: $Q) bool where Q: Hash {
    return self.find(key).is_some()
}

// Returns the value for `key`, or null when absent.
pub fn get(self: &UnmanagedOrderedDict($K, $V), key: $Q) V? where V: copyable, Q: Hash {
    return Some((self.get_ref(key)?).*)
}

// Returns a reference to the value for `key`, or null when absent. Valid until the next insert or
// removal.
pub fn get_ref(self: &UnmanagedOrderedDict($K, $V), key: $Q) &V? where Q: Hash {
    const found = self.find(key)
    if found.is_none() {
        return null
    }
    return Some(&self.entries[found.unwrap()].value)
}

// `d[key]`: the value for `key`, or null when absent.
pub fn op_index(self: &UnmanagedOrderedDict($K, $V), key: K) V? where V: copyable {
    return self.get(key)
}

// Returns the entry at insertion position `i`, or null past the end.
pub fn entry_at(self: &UnmanagedOrderedDict($K, $V), i: usize) &OrderedEntry(K, V)? {
    return self.entries.get_ref(i)
}

// Iterates the entries by reference, in insertion order: `for e in d`.
pub fn iter(self: &UnmanagedOrderedDict($K, $V)) SliceRefIterator(OrderedEntry(K, V)) {
    return self.entries.iter_ref()
}

// =============================================================================
// The managed API: `OrderedDict`
// =============================================================================

// Inserts or updates. A new key goes last; an existing key keeps its position. Panics when the
// allocation fails.
pub fn set(self: &OrderedDict($K, $V), key: move K, value: move V) {
    self.__storage.set(key, value, self.allocator)
}

// String-key `set` for an `OrderedDict(OwnedString, V)`: `key` is copied only when it is new.
pub fn set(self: &OrderedDict(OwnedString, $V), key: String, value: move V) {
    self.__storage.set(key, value, self.allocator)
}

// `d[key] = value`: insert or update.
pub fn op_set_index(self: &OrderedDict($K, $V), key: move K, value: move V) {
    self.__storage.set(key, value, self.allocator)
}

// Inserts `key` with `value` unless the key is present, and returns whether it was inserted.
pub fn add(self: &OrderedDict($K, $V), key: move K, value: move V) bool {
    return self.__storage.add(key, value, self.allocator)
}

// String-key `add` for an `OrderedDict(OwnedString, V)`: `key` is copied only when inserted.
pub fn add(self: &OrderedDict(OwnedString, $V), key: String, value: move V) bool {
    return self.__storage.add(key, value, self.allocator)
}

// Deinits every key and value and frees the storage. Idempotent.
pub fn deinit(self: move OrderedDict($K, $V)) {
    self.__storage.deinit(self.allocator)
}

// The element form, for a container that releases its elements with an allocator in hand. The dict
// carries its own.
pub fn deinit(self: move OrderedDict($K, $V), allocator: &Allocator) {
    self.deinit()
}

// =============================================================================
// Tests
// =============================================================================

test "iteration follows insertion order, and an update keeps the position" {
    let d: OrderedDict(u32, i32) = ordered_dict()
    defer d.deinit()
    d.set(30u32, 3i32)
    d.set(10u32, 1i32)
    d.set(20u32, 2i32)
    d.set(10u32, 11i32)
    assert_eq(d.len(), 3 as usize, "an update adds no entry")

    let order: List(u32) = list(0)
    defer order.deinit()
    for e in d {
        order.push(e.key)
    }
    assert_eq(order[0], 30u32, "first inserted first")
    assert_eq(order[1], 10u32, "updated key kept its place")
    assert_eq(order[2], 20u32, "last inserted last")
    assert_eq(d.get(10u32).unwrap(), 11i32, "the update took")
}

test "removal keeps the remaining order and the index finds every key" {
    let d: OrderedDict(u32, u32) = ordered_dict()
    defer d.deinit()
    for i in 0..100usize {
        d.set(i as u32, (i * 2) as u32)
    }
    assert_eq(d.remove(50u32).unwrap(), 100u32, "remove hands back the value")
    assert_true(d.remove(50u32).is_none(), "a second remove finds nothing")
    assert_eq(d.len(), 99 as usize, "one fewer")
    assert_eq(d.entry_at(50).unwrap().key, 51u32, "later entries shifted down")
    for i in 0..100usize {
        const present = d.contains(i as u32)
        assert_eq(present, i != 50, "index agrees with the entries")
    }
}

test "string keys are copied on insert, looked up by view and freed" {
    let counting = counting_allocator(context.allocator)
    const alloc = counting.allocator()
    let d: OrderedDict(OwnedString, i32) = ordered_dict(&alloc)
    d.set("b", 1i32)
    d.set("a", 2i32)
    d.set("b", 3i32)
    assert_true(!d.add("a", 9i32), "add leaves a present key alone")
    assert_eq(d.get("b").unwrap(), 3i32, "lookup by view")
    assert_true(d.entry_at(0).unwrap().key.view == "b", "first key")
    assert_eq(d.remove("b").unwrap(), 3i32, "remove by view")
    d.deinit()
    assert_eq(counting.deallocs, counting.allocs, "keys, entries and index freed")
}

test "a zero-initialised OrderedDict is a valid empty dict" {
    let d: OrderedDict(u32, u32)
    defer d.deinit()
    assert_true(d.is_empty(), "empty")
    assert_true(d.get(1u32).is_none(), "a lookup finds nothing")
    d[1u32] = 2u32
    assert_eq(d[1u32].unwrap(), 2u32, "and it grows on the first set")
}
