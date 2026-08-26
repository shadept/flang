// Generic hash set backed by `Dict(T, u8)`. Membership test is the only operation that matters; the
// value slot is a single byte sentinel and is never inspected by callers.
//
// For dense integer-indexed sets prefer `Bitset` - it stores one bit per element and supports
// O(words) union/intersect.

import std.allocator
import std.list
import std.test
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

// Insert a value. No-op when the value is already present (no allocation or replacement). Returns
// nothing - the value-add idempotence is the expected behavior; callers that want to know whether
// it was new should `contains()` first.
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

// Drop every element. Element `deinit()` is NOT called - clear is a fast reset, not a full release.
// Use `deinit()` followed by a fresh `set(...)` when elements own heap.
pub fn clear(self: &Set($T)) {
    self.inner.clear()
}

// =============================================================================
// String-key convenience overloads for `Set(OwnedString)`.
//
// Mirror `Dict(OwnedString, V)`'s pattern: callers pass a borrowed `String` view; the set
// materialises an OwnedString on insertion when needed.
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

// An iterator is its own iterable, so `for x in s.iter()` and the std.iter combinators can consume
// it.
pub fn iter(it: &SetIterator($T)) SetIterator(T) {
    return it.*
}

pub fn next(it: &SetIterator($T)) T? {
    return it.inner.next() match {
        Some(entry) => Some(entry.key)
        None => None
    }
}

// =============================================================================
// Functional utilities (callbacks are duck-typed $F, RFC-014)
// =============================================================================

// The elements `pred` accepts, as a new set.
pub fn filter(self: &Set($T), pred: $F, allocator: &Allocator? = null) Set(T) {
    let out: Set(T) = set(allocator)
    for x in self.iter() {
        if pred(x) {
            out.add(x)
        }
    }
    return out
}

// Run `f` on every element. Iteration order is unspecified.
pub fn each(self: &Set($T), f: $F) {
    for x in self.iter() {
        f(x)
    }
}

// Whether any element satisfies `pred`. False for an empty set.
pub fn any(self: &Set($T), pred: $F) bool {
    for x in self.iter() {
        if pred(x) {
            return true
        }
    }
    return false
}

// Whether every element satisfies `pred`. True for an empty set.
pub fn all(self: &Set($T), pred: $F) bool {
    for x in self.iter() {
        let ok: bool = pred(x)
        if !ok {
            return false
        }
    }
    return true
}

// The elements as a fresh List, in unspecified order.
pub fn to_list(self: &Set($T), allocator: &Allocator? = null) List(T) {
    let out: List(T) = list(self.len(), allocator)
    for x in self.iter() {
        out.push(x)
    }
    return out
}

test "set functional utilities" {
    let s: Set(i32) = set()
    defer s.deinit()
    s.add(1i32)
    s.add(2i32)
    s.add(3i32)

    let evens = s.filter(fn(x) { x % 2 == 0 })
    defer evens.deinit()
    assert_eq(evens.len(), 1 as usize, "one even element")
    assert_true(evens.contains(2i32), "the right one")

    let sum = 0i32
    let sum_ref = &sum
    s.each(fn(x) { sum_ref.* = sum_ref.* + x })
    assert_eq(sum, 6i32, "each visited every element")

    assert_true(s.any(fn(x) { x > 2 }), "one element exceeds 2")
    assert_true(!s.all(fn(x) { x > 2 }), "not all do")

    let xs = s.to_list()
    defer xs.deinit()
    xs.sort()
    assert_eq(xs.len, 3 as usize, "all elements collected")
    assert_eq(xs[0], 1i32, "sorted view starts at the smallest")
}
