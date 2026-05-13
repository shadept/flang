// Generic hash set backed by `Dict(T, u8)`. Membership test is the only
// operation that matters; the value slot is a single byte sentinel and
// is never inspected by callers.
//
// (Storing `()` instead would save one byte per entry, but the current
// Dict layout doesn't pad entry size to alignment — see docs/known-issues.md
// "Dict entry stride ignores alignment padding". A `u8` value keeps us
// out of that trap.)
//
// For dense integer-indexed sets prefer `Bitset` — it stores one bit per
// element and supports O(words) union/intersect.

import std.allocator
import std.dict
import std.option
import std.string

pub type Set = struct(T) {
    inner: Dict(T, u8)
}

// Construct an empty set. `T` is inferred from context.
pub fn set(allocator: &Allocator? = null) Set($T) {
    return .{ inner = dict(allocator) }
}

// Free the backing storage. Each live key's `deinit()` runs first.
pub fn deinit(self: &Set($T)) {
    self.inner.deinit()
}

// Number of distinct elements currently in the set.
pub fn len(self: Set($T)) usize {
    return self.inner.len()
}

// True when the set holds no elements.
pub fn is_empty(self: Set($T)) bool {
    return self.inner.is_empty()
}

// Insert a value. No-op when the value is already present (no allocation
// or replacement). Returns nothing — the value-add idempotence is the
// expected behavior; callers that want to know whether it was new should
// `contains()` first.
pub fn add(self: &Set($T), value: T) {
    self.inner.set(value, 1u8)
}

// Test membership.
pub fn contains(self: Set($T), value: T) bool {
    return self.inner.contains(value)
}

// Remove a value. Returns `true` iff the value was present.
pub fn remove(self: &Set($T), value: T) bool {
    return self.inner.remove(value).is_some()
}

// Drop every element. Element `deinit()` is NOT called — clear is a fast
// reset, not a full release. Use `deinit()` followed by a fresh
// `set(...)` when elements own heap.
pub fn clear(self: &Set($T)) {
    self.inner.clear()
}

// =============================================================================
// String-key convenience overloads for `Set(OwnedString)`.
//
// Mirror `Dict(OwnedString, V)`'s pattern: callers pass a borrowed `String`
// view; the set materialises an OwnedString on insertion when needed.
// =============================================================================

pub fn add(self: &Set(OwnedString), value: String) {
    self.inner.set(value, 1u8)
}

pub fn contains(self: Set(OwnedString), value: String) bool {
    return self.inner.contains(value)
}

pub fn remove(self: &Set(OwnedString), value: String) bool {
    return self.inner.remove(value).is_some()
}

// =============================================================================
// Iterator (yields elements in undefined order)
// =============================================================================

pub type SetIterator = struct(T) {
    inner: DictIterator(T, u8)
}

pub fn iter(self: &Set($T)) SetIterator(T) {
    return .{ inner = self.inner.iter() }
}

pub fn next(it: &SetIterator($T)) T? {
    return it.inner.next() match {
        Some(entry) => Some(entry.key),
        None => None
    }
}
