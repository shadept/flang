// Hash sets: membership, insertion and removal in constant expected time, over any element type
// with `hash` and `==`.
//
// Two flavours, the managed and unmanaged split of spec §9.4. `Set(T)` owns its storage and its
// allocator (`s.add(v)`); `UnmanagedSet(T)` carries no allocator and takes one at every allocating
// call (`s.add(v, alloc)`), for composites that keep one allocator for all their children. Both are
// a dict from the element to a one-byte marker, so a set costs what the dict does.
//
// For dense integer-indexed sets prefer `Bitset`: one bit per element and word-at-a-time union and
// intersection.

import std.allocator
import std.collections.dict
import std.collections.list
import std.option
import std.string
import std.test

// A hash set of `T` that carries no allocator: `add` and `deinit` take one as their last argument,
// and the same allocator must be passed every time. A zero-initialised value is a valid empty set.
// Elements are owned: `deinit` deinits each. `T` needs `hash` and `==`.
pub type UnmanagedSet = struct(T) {
    __inner: UnmanagedDict(T, u8)
}

// A hash set of `T` that owns its table and remembers the allocator it grows and frees through.
// Every `UnmanagedSet` operation applies to it as well, reached through `op_deref`, and the
// allocating ones come without the allocator argument. A zero-initialised value is a valid empty
// set on the global allocator.
pub type Set = struct(T) {
    __storage: UnmanagedSet(T)
    allocator: &Allocator
}

// Reaches the storage: `s.len()`, `s.contains(v)` and every `UnmanagedSet` read resolve through
// this.
pub fn op_deref(self: &Set($T)) &UnmanagedSet(T) {
    return &self.__storage
}

// Creates an empty set. Nothing allocates until the first `add`.
//
// - `allocator`: kept for the set's whole life. Null is the global allocator.
pub fn set(allocator: &Allocator? = null) Set($T) {
    let out: Set(T)
    out.allocator = allocator.or_global()
    return move out
}

// =============================================================================
// UnmanagedSet: growth and release, allocator explicit
// =============================================================================

// Adds `value` unless it is present, and returns whether it was added.
//
// A present value is left as it is, and the `value` passed stays the caller's to deinit; an added
// one is owned by the set. One probe either way, so a visited check is `if seen.add(x, alloc) { ...
// }`. Panics when the table cannot grow.
pub fn add(self: &UnmanagedSet($T), value: T, allocator: &Allocator) bool {
    return self.__inner.add(move value, 1u8, allocator)
}

// String `add` for `UnmanagedSet(OwnedString)`: `value` is a borrowed view, copied into an owned
// element only when it is added.
pub fn add(self: &UnmanagedSet(OwnedString), value: String, allocator: &Allocator) bool {
    return self.__inner.add(value, 1u8, allocator)
}

// Deinits every element and frees the table. Idempotent: a second call is a no-op.
pub fn deinit(self: &UnmanagedSet($T), allocator: &Allocator) {
    self.__inner.deinit(allocator)
}

// Returns a new set of the elements `pred` accepts, copied bitwise: an owned element is then owned
// by both sets, and only one may deinit it.
pub fn filter(self: &UnmanagedSet($T), pred: $F, allocator: &Allocator) UnmanagedSet(T) {
    let out: UnmanagedSet(T)
    for x in self.iter() {
        if pred(x) {
            out.add(x, allocator)
        }
    }
    return move out
}

// Returns the elements as a new list, in unspecified order, copied bitwise.
pub fn to_list(self: &UnmanagedSet($T), allocator: &Allocator) UnmanagedList(T) {
    let out: UnmanagedList(T) = unmanaged_list(self.len(), allocator)
    for x in self.iter() {
        out.push(x, allocator)
    }
    return move out
}

// =============================================================================
// UnmanagedSet: in-place mutation and reads
// =============================================================================

// Returns the number of elements.
pub fn len(self: &UnmanagedSet($T)) usize {
    return self.__inner.len()
}

// Returns whether there are no elements.
pub fn is_empty(self: &UnmanagedSet($T)) bool {
    return self.__inner.is_empty()
}

// Returns whether `value` is present.
pub fn contains(self: &UnmanagedSet($T), value: T) bool {
    return self.__inner.contains(move value)
}

// String `contains` for `UnmanagedSet(OwnedString)`: looks the owned element up by the view.
pub fn contains(self: &UnmanagedSet(OwnedString), value: String) bool {
    return self.__inner.contains(value)
}

// Removes `value`, deiniting the stored element, and returns whether it was present.
pub fn remove(self: &UnmanagedSet($T), value: T) bool {
    return self.__inner.remove(move value).is_some()
}

// String `remove` for `UnmanagedSet(OwnedString)`: looks the owned element up by the view.
pub fn remove(self: &UnmanagedSet(OwnedString), value: String) bool {
    return self.__inner.remove(value).is_some()
}

// Removes every element, deiniting each. The table is kept for reuse.
pub fn clear(self: &UnmanagedSet($T)) {
    self.__inner.clear()
}

// Calls `f` on every element, in unspecified order.
pub fn each(self: &UnmanagedSet($T), f: $F) {
    for x in self.iter() {
        f(x)
    }
}

// Returns whether any element satisfies `pred`. False when empty.
pub fn any(self: &UnmanagedSet($T), pred: $F) bool {
    for x in self.iter() {
        if pred(x) {
            return true
        }
    }
    return false
}

// Returns whether every element satisfies `pred`. True when empty.
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

// Iterator over a set's elements, by value, in unspecified order. A snapshot: the set is not
// modified while it is being iterated.
pub type SetIterator = struct(T) {
    __inner: DictIterator(T, u8)
}

// Iterates the elements by value, in unspecified order.
pub fn iter(self: &UnmanagedSet($T)) SetIterator(T) {
    return .{ __inner = self.__inner.iter() }
}

// An iterator is its own iterable, so `for x in s.iter()` and the std.iter combinators can consume
// it.
pub fn iter(self: &SetIterator($T)) SetIterator(T) {
    return self.*
}

// Advances and returns the next element, or null after the last.
pub fn next(self: &SetIterator($T)) T? {
    return self.__inner.next() match {
        Some(entry) => Some(entry.key)
        None => None
    }
}

// Iterator over a set's elements by reference, in unspecified order: the form for an element type
// that cannot be copied.
pub type SetRefIterator = struct(T) {
    __inner: DictIterator(T, u8)
}

// Iterates the elements by reference, in unspecified order.
pub fn iter_ref(self: &UnmanagedSet($T)) SetRefIterator(T) {
    return .{ __inner = self.__inner.iter() }
}

// An iterator is its own iterable.
pub fn iter(self: &SetRefIterator($T)) SetRefIterator(T) {
    return self.*
}

// Advances and returns a reference to the next element, or null after the last.
pub fn next(self: &SetRefIterator($T)) &T? {
    return self.__inner.next() match {
        Some(entry) => Some(&entry.key)
        None => None
    }
}

// =============================================================================
// Set: the managed API
//
// The same operations over the set's own allocator. A derived container takes an optional allocator
// for its result and otherwise uses the receiver's.
// =============================================================================

// Adds `value` unless it is present, and returns whether it was added. A present value is left as
// it is, and the `value` passed stays the caller's. Panics when the table cannot grow.
pub fn add(self: &Set($T), value: T) bool {
    return self.__storage.add(value, self.allocator)
}

// String `add` for `Set(OwnedString)`: `value` is copied into an owned element only when added.
pub fn add(self: &Set(OwnedString), value: String) bool {
    return self.__storage.add(value, self.allocator)
}

// Deinits every element and frees the table. Idempotent: a second call is a no-op.
pub fn deinit(self: &Set($T)) {
    self.__storage.deinit(self.allocator)
}

// Returns a new set of the elements `pred` accepts, copied bitwise. The result is on `allocator`,
// or on the receiver's when null.
pub fn filter(self: &Set($T), pred: $F, allocator: &Allocator? = null) Set(T) {
    const alloc = allocator ?? self.allocator
    return .{ __storage = self.__storage.filter(pred, alloc), allocator = alloc }
}

// Returns the elements as a new list, in unspecified order, copied bitwise. The result is on
// `allocator`, or on the receiver's when null.
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
