// Hash sets in two flavours, the managed and unmanaged split of spec §9.4, each a `u8`-valued
// dict of the matching flavour: `UnmanagedSet(T)` over `UnmanagedDict(T, u8)`, taking the allocator
// at every allocating call (`s.add(v, alloc)`), and `Set(T)` with its allocator beside it
// (`s.add(v)`), reaching the storage through `op_deref`. The value slot is a single byte sentinel
// and is never inspected by callers.
//
// For dense integer-indexed sets prefer `Bitset` - it stores one bit per element and supports
// O(words) union/intersect.

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.test

pub type UnmanagedSet = struct(T) {
    __inner: UnmanagedDict(T, u8)
}

pub type Set = struct(T) {
    __storage: UnmanagedSet(T)
    allocator: &Allocator
}

// Reaches the storage: `s.len()`, `s.contains(v)` and every `UnmanagedSet` read resolve through
// this.
pub fn op_deref(self: &Set($T)) &UnmanagedSet(T) {
    return &self.__storage
}

// Construct an empty set. `T` is inferred from context.
//
// - `allocator`: kept for the set's whole life. Null is the global allocator.
pub fn set(allocator: &Allocator? = null) Set($T) {
    let out: Set(T)
    out.allocator = allocator.unwrap_or(0usize as &Allocator)
    return out
}

// =============================================================================
// UnmanagedSet: growth and release, allocator explicit
// =============================================================================

// Insert a value. Returns whether it was new, so a visited check is one probe: `if seen.add(x,
// alloc) { work.push(x, alloc) }`. A present value is left as it is.
pub fn add(self: &UnmanagedSet($T), value: T, allocator: &Allocator) bool {
    return self.__inner.add(value, 1u8, allocator)
}

// String-key insert for `UnmanagedSet(OwnedString)`: the view is copied into an owned key only when
// it is new to the set.
pub fn add(self: &UnmanagedSet(OwnedString), value: String, allocator: &Allocator) bool {
    return self.__inner.add(value, 1u8, allocator)
}

// Free the backing storage. Each live key's `deinit()` runs first. Idempotent.
pub fn deinit(self: &UnmanagedSet($T), allocator: &Allocator) {
    self.__inner.deinit(allocator)
}

// The elements `pred` accepts, as a new set.
pub fn filter(self: &UnmanagedSet($T), pred: $F, allocator: &Allocator) UnmanagedSet(T) {
    let out: UnmanagedSet(T)
    for x in self.iter() {
        if pred(x) {
            out.add(x, allocator)
        }
    }
    return out
}

// The elements as a fresh list, in unspecified order.
pub fn to_list(self: &UnmanagedSet($T), allocator: &Allocator) UnmanagedList(T) {
    let out: UnmanagedList(T) = unmanaged_list(self.len(), allocator)
    for x in self.iter() {
        out.push(x, allocator)
    }
    return out
}

// =============================================================================
// UnmanagedSet: in-place mutation and reads
// =============================================================================

// Number of distinct elements currently in the set.
pub fn len(self: &UnmanagedSet($T)) usize {
    return self.__inner.len()
}

// True when the set holds no elements.
pub fn is_empty(self: &UnmanagedSet($T)) bool {
    return self.__inner.is_empty()
}

// Test membership.
pub fn contains(self: &UnmanagedSet($T), value: T) bool {
    return self.__inner.contains(value)
}

pub fn contains(self: &UnmanagedSet(OwnedString), value: String) bool {
    return self.__inner.contains(value)
}

// Remove a value. Returns `true` iff the value was present.
pub fn remove(self: &UnmanagedSet($T), value: T) bool {
    return self.__inner.remove(value).is_some()
}

pub fn remove(self: &UnmanagedSet(OwnedString), value: String) bool {
    return self.__inner.remove(value).is_some()
}

// Drop every element, deiniting each. Backing storage is kept for reuse.
pub fn clear(self: &UnmanagedSet($T)) {
    self.__inner.clear()
}

// Run `f` on every element. Iteration order is unspecified.
pub fn each(self: &UnmanagedSet($T), f: $F) {
    for x in self.iter() {
        f(x)
    }
}

// Whether any element satisfies `pred`. False for an empty set.
pub fn any(self: &UnmanagedSet($T), pred: $F) bool {
    for x in self.iter() {
        if pred(x) {
            return true
        }
    }
    return false
}

// Whether every element satisfies `pred`. True for an empty set.
pub fn all(self: &UnmanagedSet($T), pred: $F) bool {
    for x in self.iter() {
        let ok: bool = pred(x)
        if !ok {
            return false
        }
    }
    return true
}

// =============================================================================
// Iterator (yields elements in undefined order)
// =============================================================================

pub type SetIterator = struct(T) {
    __inner: DictIterator(T, u8)
}

pub fn iter(self: &UnmanagedSet($T)) SetIterator(T) {
    return .{ __inner = self.__inner.iter() }
}

// An iterator is its own iterable, so `for x in s.iter()` and the std.iter combinators can consume
// it.
pub fn iter(it: &SetIterator($T)) SetIterator(T) {
    return it.*
}

pub fn next(it: &SetIterator($T)) T? {
    return it.__inner.next() match {
        Some(entry) => Some(entry.key)
        None => None
    }
}

// =============================================================================
// Set: the managed API
//
// The same operations over the set's own allocator. A derived container takes an optional allocator
// for its result and otherwise uses the receiver's.
// =============================================================================

// Insert a value. Returns whether it was new.
pub fn add(self: &Set($T), value: T) bool {
    return self.__storage.add(value, self.allocator)
}

pub fn add(self: &Set(OwnedString), value: String) bool {
    return self.__storage.add(value, self.allocator)
}

// Free the backing storage. Each live key's `deinit()` runs first. Idempotent.
pub fn deinit(self: &Set($T)) {
    self.__storage.deinit(self.allocator)
}

// The elements `pred` accepts, as a new set.
pub fn filter(self: &Set($T), pred: $F, allocator: &Allocator? = null) Set(T) {
    const alloc = allocator ?? self.allocator
    return .{ __storage = self.__storage.filter(pred, alloc), allocator = alloc }
}

// The elements as a fresh List, in unspecified order.
pub fn to_list(self: &Set($T), allocator: &Allocator? = null) List(T) {
    const alloc = allocator ?? self.allocator
    return .{ __storage = self.__storage.to_list(alloc), allocator = alloc }
}

// =============================================================================
// Tests
// =============================================================================

test "an UnmanagedSet takes its allocator at every allocating call" {
    let counting = counting_allocator(global())
    const alloc = counting.allocator()
    let s: UnmanagedSet(i32)
    assert_true(s.add(1i32, &alloc), "a new value reports true")
    assert_true(s.add(2i32, &alloc), "so does the next")
    assert_true(!s.add(2i32, &alloc), "a duplicate reports false")
    assert_eq(s.len(), 2 as usize, "and does not add")
    assert_true(s.contains(2i32), "contains")
    assert_true(s.remove(1i32), "remove reports presence")
    let sum = 0i32
    for x in s {
        sum = sum + x
    }
    assert_eq(sum, 2i32, "for over the live elements")
    const xs = s.to_list(&alloc)
    assert_eq(xs.len, 1 as usize, "to_list with explicit allocator")
    xs.deinit(&alloc)
    s.deinit(&alloc)
    assert_eq(counting.live_bytes, 0 as usize, "everything went back through that allocator")
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
