// A pool of interned strings: each distinct string is stored once, in one contiguous buffer, and
// named by a small integer id. Tables that key by name key by `StrId` instead, so their lookups
// hash and compare integers, and a name is copied exactly once however many tables cite it.
//
// The buffer holds every string's bytes end to end and a split table says where each one ends; an
// open-addressing index maps bytes back to their id. That is three allocations for a pool of any
// size, against one heap block, a header and an allocator pointer per string when each is an
// `OwnedString`. The buffer moves when it grows, so a `String` read back through `get` is valid
// only until the next `intern`: hold the id across interns, and read the bytes at the point of use.
//
// Managed only: stores its allocator once (spec §9.4).

import std.allocator
import std.collections.list
import std.option
import std.test

// The name of a pooled string: its index in insertion order, from zero.
pub type StrId = u32

// An empty index slot, and the id `find` never returns.
const NO_STR: u32 = 0xFFFF_FFFF

// Interned strings in one buffer, named by `StrId`. Ids are dense and stable for the pool's life;
// `get(id)` is the string with that id, as a view that the next `intern` may invalidate.
pub type StringPool = struct {
    // Every string's bytes, end to end, in id order.
    bytes: UnmanagedList(u8)
    // `ends[id]` is the exclusive end of string `id` in `bytes`; its start is `ends[id - 1]`, or 0
    // for id 0.
    ends: UnmanagedList(u32)
    // Open-addressing index from a string's hash to its id, `NO_STR` in an empty slot. Its length
    // is a power of two or zero. Probes compare bytes through `bytes`, so the index holds no view
    // and survives the buffer moving.
    index: UnmanagedList(StrId)
    allocator: &Allocator
}

// Creates an empty pool. Nothing allocates until the first `intern`.
//
// - `allocator`: kept for the pool's whole life; the buffer, the split table and the index grow and
//   free through it. Null is the global allocator.
pub fn string_pool(allocator: &Allocator? = null) StringPool {
    let out: StringPool
    out.allocator = allocator.or_global()
    return move out
}

// Creates an empty pool that allocates through `allocator` for its whole life.
pub fn string_pool(allocator: &Allocator) StringPool {
    return string_pool(Some(allocator))
}

// Creates an empty pool with room for `capacity_bytes` of string data before the buffer first
// grows. Panics when the allocation fails.
pub fn string_pool(capacity_bytes: usize, allocator: &Allocator? = null) StringPool {
    let out: StringPool = string_pool(allocator)
    out.bytes.reserve(capacity_bytes, out.allocator)
    return move out
}

// Returns the id of `s`, storing a copy of its bytes when the pool has no equal string yet. Equal
// bytes always yield the same id, so ids compare as the strings would. Panics when the buffer, the
// split table or the index cannot grow.
pub fn intern(self: &StringPool, s: String) StrId {
    self.ensure_index_room()
    const h = hash(s)
    let slot = self.probe(h, s)
    if self.index[slot] != NO_STR {
        return self.index[slot]
    }
    const id = self.ends.len as StrId
    self.bytes.push_all(slice_from_raw_parts(s.ptr, s.len), self.allocator)
    self.ends.push(self.bytes.len as u32, self.allocator)
    self.index[slot] = id
    return id
}

// Returns the id of `s` when an equal string was interned, without storing anything otherwise.
pub fn find(self: &StringPool, s: String) StrId? {
    if self.index.len == 0 {
        return null
    }
    const slot = self.probe(hash(s), s)
    if self.index[slot] == NO_STR {
        return null
    }
    return Some(self.index[slot])
}

// Returns the bytes of `id` as a view into the buffer, valid until the next `intern`. Panics on an
// id the pool never handed out.
pub fn get(self: &StringPool, id: StrId) String {
    const i = id as usize
    if i >= self.ends.len {
        panic("string_pool: unknown id")
    }
    const start = if i == 0 { 0usize } else { self.ends[i - 1] as usize }
    const end = self.ends[i] as usize
    return .{ ptr = self.bytes.ptr + start, len = end - start }
}

// Returns the number of strings held.
pub fn len(self: &StringPool) usize {
    return self.ends.len
}

// Returns the number of string bytes held.
pub fn byte_len(self: &StringPool) usize {
    return self.bytes.len
}

// Returns the bytes the buffer, the split table and the index occupy: the whole capacity of each.
pub fn capacity_bytes(self: &StringPool) usize {
    return self.bytes.capacity_bytes() + self.ends.capacity_bytes() + self.index.capacity_bytes()
}

// Drops every string and forgets every id, keeping the storage for reuse. Ids hand out again from
// zero.
pub fn clear(self: &StringPool) {
    self.bytes.clear(self.allocator)
    self.ends.clear(self.allocator)
    for i in 0..self.index.len {
        self.index[i] = NO_STR
    }
}

// Frees the buffer, the split table and the index. Idempotent: a second call is a no-op.
pub fn deinit(self: &StringPool) {
    self.bytes.deinit(self.allocator)
    self.ends.deinit(self.allocator)
    self.index.deinit(self.allocator)
}

// Element form (README, Expected functions). The value carries its own allocator.
pub fn deinit(self: &StringPool, allocator: &Allocator) {
    self.deinit()
}

// The index slot holding `s`'s id, or the empty slot where it would go: linear probing from the
// hash. The index must have a free slot.
fn probe(self: &StringPool, h: usize, s: String) usize {
    const mask = self.index.len - 1
    let slot = h & mask
    loop {
        const id = self.index[slot]
        if id == NO_STR or self.get(id) == s {
            return slot
        }
        slot = (slot + 1) & mask
    }
}

// Grows the index when the next intern would push it past a 75% load factor, rehashing every id
// through its bytes. Starts at 16 slots.
fn ensure_index_room(self: &StringPool) {
    const n = self.ends.len + 1
    if self.index.len > 0 and n * 4 <= self.index.len * 3 {
        return
    }
    const new_len = if self.index.len == 0 { 16usize } else { self.index.len * 2 }
    let fresh: UnmanagedList(StrId) = filled_unmanaged_list(new_len, NO_STR, self.allocator)
    const mask = new_len - 1
    for id in 0..self.ends.len {
        let slot = hash(self.get(id as StrId)) & mask
        while fresh[slot] != NO_STR {
            slot = (slot + 1) & mask
        }
        fresh[slot] = id as StrId
    }
    self.index.deinit(self.allocator)
    self.index = move fresh
}

// =============================================================================
// Iteration
// =============================================================================

// One pooled string with its id.
pub type PooledString = struct {
    id: StrId
    text: String
}

// Iterator over a pool's strings in id order. A snapshot: the pool is not interned into while it is
// being iterated.
pub type StringPoolIter = struct {
    pool: &StringPool
    next_id: StrId
}

// Iterates every string with its id, in id order.
pub fn iter(self: &StringPool) StringPoolIter {
    return .{ pool = self, next_id = 0 }
}

// An iterator is its own iterable, so adapter chains can consume it.
pub fn iter(self: &StringPoolIter) StringPoolIter {
    return self.*
}

// Advances and returns the next string with its id, or null after the last.
pub fn next(self: &StringPoolIter) PooledString? {
    if self.next_id as usize >= self.pool.len() {
        return null
    }
    const id = self.next_id
    self.next_id = self.next_id + 1
    return Some(.{ id = id, text = self.pool.get(id) })
}

// =============================================================================
// Tests
// =============================================================================

test "equal strings intern to one id and read back; distinct strings get dense ids" {
    let p = string_pool()
    defer p.deinit()
    const a = p.intern("alpha")
    const b = p.intern("beta")
    const a2 = p.intern("alpha")
    assert_eq(a, 0u32, "ids start at zero")
    assert_eq(b, 1u32, "and are dense")
    assert_eq(a2, a, "an equal string is the same id")
    assert_eq(p.len(), 2 as usize, "two strings held")
    assert_true(p.get(a) == "alpha", "reads back")
    assert_true(p.get(b) == "beta", "each its own bytes")
    assert_true(p.find("beta").unwrap() == b, "find sees an interned string")
    assert_true(p.find("gamma").is_none(), "and not an absent one")
    const e = p.intern("")
    assert_true(p.get(e) == "", "the empty string is a string")
    assert_eq(p.intern(""), e, "and interns once")
}

test "the index grows past the load factor and ids survive the rehash" {
    let counting = counting_allocator(global())
    const alloc = counting.allocator()
    let p = string_pool(&alloc)
    let names: [u8; 4] = [0; 4]
    for i in 0..200u32 {
        names[0] = ((i / 100) % 10) as u8 + 48u8
        names[1] = ((i / 10) % 10) as u8 + 48u8
        names[2] = (i % 10) as u8 + 48u8
        names[3] = 33u8
        const view: String = .{ ptr = &names[0], len = 4 }
        assert_eq(p.intern(view), i, "each new name is the next id")
    }
    assert_eq(p.len(), 200 as usize, "two hundred strings")
    for i in 0..200u32 {
        names[0] = ((i / 100) % 10) as u8 + 48u8
        names[1] = ((i / 10) % 10) as u8 + 48u8
        names[2] = (i % 10) as u8 + 48u8
        const view: String = .{ ptr = &names[0], len = 4 }
        assert_eq(p.find(view).unwrap(), i, "found again after the rehashes")
    }
    let seen = 0usize
    for s in p {
        assert_eq(s.text.len, 4 as usize, "iteration yields the stored bytes")
        seen = seen + 1
    }
    assert_eq(seen, 200 as usize, "every string visited once")
    p.deinit()
    assert_eq(counting.live_bytes, 0 as usize, "three blocks, all freed")
}

test "clear keeps the storage and restarts the ids" {
    let counting = counting_allocator(global())
    const alloc = counting.allocator()
    let p = string_pool(&alloc)
    const _a = p.intern("one")
    const _b = p.intern("two")
    const before = counting.allocs
    p.clear()
    assert_eq(p.len(), 0 as usize, "empty")
    assert_true(p.find("one").is_none(), "forgotten")
    assert_eq(p.intern("three"), 0u32, "ids restart")
    assert_eq(counting.allocs, before, "no allocation after clear")
    p.deinit()
}
