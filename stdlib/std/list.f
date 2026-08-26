// Generic dynamic array backed by manually managed heap storage.
// Uses raw malloc/free for simplicity (allocator support to be added later).

import std.allocator
import std.dict
import std.mem
import std.option
import std.sort
import std.string
import std.string_builder
import std.test

pub type List = struct(T) {
    ptr: &T
    len: usize
    cap: usize
    allocator: &Allocator?
}

const DEFAULT_CAPACITY: usize = 16

pub fn list(capacity: usize, allocator: &Allocator) List($T) {
    return list(capacity, Some(allocator))
}

pub fn list(capacity: usize, allocator: &Allocator? = null) List($T) {
    if capacity == 0 {
        let empty: List(T)
        empty.allocator = allocator
        return empty
    }
    const bytes = capacity * size_of(T)
    const buf = allocator.or_global()
        .alloc(bytes, align_of(T))
        .expect("list: allocation failed")

    return .{
        ptr = buf.ptr as &T,
        len = 0,
        cap = capacity,
        allocator = allocator,
    }
}

// Create a shallow copy of an existing list.
// Allocates new backing storage and copies all elements.
pub fn list(source: List($T), allocator: &Allocator? = null) List(T) {
    if source.len == 0 {
        let empty: List(T)
        empty.allocator = allocator
        return empty
    }
    const bytes = source.len * size_of(T)
    const buf = allocator.or_global()
        .alloc(bytes, align_of(T))
        .expect("list(copy): allocation failed")
    memcpy(buf.ptr, source.ptr as &u8, bytes)
    return .{
        ptr = buf.ptr as &T,
        len = source.len,
        cap = source.len,
        allocator = allocator,
    }
}

// A list of `count` copies of `value`, with `len == count` from the start:
// a table to index and assign into, where `list(capacity)` gives an empty
// buffer to push onto.
pub fn filled_list(count: usize, value: $T, allocator: &Allocator? = null) List(T) {
    let out: List(T) = list(count, allocator)
    for _i in 0..count {
        out.push(value)
    }
    return out
}

// Bytes the backing storage occupies. Counts the whole capacity, not just the
// `len` elements in use. What an element owns on the heap of its own is not
// in here.
pub fn capacity_bytes(self: &List($T)) usize {
    return self.cap * size_of(T)
}

// Free the backing storage. The list should not be used after this.
// Calls deinit on all stored elements before freeing.
pub fn deinit(self: &List($T)) {
    if self.cap > 0 {
        // Deinit all live elements
        // TODO use #if to check if T supports deinit(&T)
        for i in 0..self.len {
            const elem = self.get_ref(i)
            const elem2 = elem.unwrap()
            elem2.deinit()
        }
        self.allocator.or_global().free(slice_from_raw_parts(self.ptr, self.cap))
    }

    self.ptr = 0usize as &T
    self.len = 0
    self.cap = 0
}

pub fn as_slice(self: List($T)) T[] {
    return slice_from_raw_parts(self.ptr, self.len)
}

// Transfer ownership of the list's buffer as a `(T[], &Allocator)` pair.
// The slice is shrunk-to-fit (`cap == len` after the call) so no excess
// capacity is leaked. The list is reset to empty (ptr=null, cap=0) so a
// subsequent `deinit()` is a no-op - pair this with the
// `let l = list(...); defer l.deinit(); ...; l.to_owned_slice()` pattern.
//
// The returned `&Allocator` is the resolved allocator (global by default)
// - the caller frees the slice via
// `alloc.dealloc(slice_from_raw_parts(s.ptr as &u8, s.len * size_of(T)))`
// when done. Element `deinit()` is *not* called here; callers that own
// non-trivial elements must walk the slice and deinit each element
// before freeing the buffer.
pub fn to_owned_slice(self: &List($T)) (T[], &Allocator) {
    const alloc = self.allocator.or_global()
    const elem_size: usize = size_of(T)

    if self.len == 0 {
        if self.cap > 0 {
            alloc.free(slice_from_raw_parts(self.ptr, self.cap))
        }
        let zero: usize = 0
        self.ptr = zero as &T
        self.cap = 0
        const empty: T[] = slice_from_raw_parts(zero as &T, 0)
        return (empty, alloc)
    }

    if self.cap > self.len {
        const old_bytes = self.cap * elem_size
        const new_bytes = self.len * elem_size
        const old_slice = slice_from_raw_parts(self.ptr as &u8, old_bytes)
        const resized = alloc.realloc(old_slice, new_bytes)
        if resized.is_some() {
            self.ptr = resized.unwrap().ptr as &T
            self.cap = self.len
        }
    }

    const result_slice = slice_from_raw_parts(self.ptr, self.len)
    let zero: usize = 0
    self.ptr = zero as &T
    self.len = 0
    self.cap = 0
    return (result_slice, alloc)
}

pub fn reserve(self: &List($T), capacity: usize) {
    if self.cap >= capacity {
        return
    }

    // Calculate new capacity: start with 4, then double
    let new_cap = if self.cap == 0 { DEFAULT_CAPACITY } else { self.cap * 2 }
    if new_cap < capacity {
        new_cap = capacity
    }

    // Allocate new buffer using raw malloc
    const elem_size: usize = size_of(T)
    const elem_align: usize = align_of(T)
    const new_bytes: usize = new_cap * elem_size
    const new_buf = self.allocator.or_global().alloc(new_bytes, elem_align)
        .expect("reserve(List(T), capacity): allocation failed")
    const new_ptr: &T = new_buf.ptr as &T

    // Copy existing elements
    if self.len > 0 {
        const old_bytes = self.len * elem_size
        memcpy(new_ptr as &u8, self.ptr as &u8, old_bytes)
    }

    // Free old buffer if it existed
    if self.cap > 0 {
        self.allocator.or_global().free(slice_from_raw_parts(self.ptr, self.cap))
    }

    self.ptr = new_ptr
    self.cap = new_cap
}

// Append an element to the end of the list.
pub fn push(self: &List($T), value: T) {
    self.reserve(self.len + 1)

    // Write value at index len using memcpy
    self.len = self.len + 1
    let data = self.as_slice()
    data[self.len - 1] = value
    // let dest: &u8 = (self.ptr + self.len) as &u8
    // memcpy(dest, &value as &u8, type.size as usize)
}

// Append every element of `xs` to the end of the list, in order. Both
// buffers are contiguous, so the copy is a single memcpy; `xs` must not
// alias the list's own storage - growth may reallocate (and free) that
// storage before the copy, so no copy primitive makes self-append safe.
pub fn push_all(self: &List($T), xs: T[]) {
    if xs.len == 0 { return }
    self.reserve(self.len + xs.len)
    memcpy((self.ptr + self.len) as &u8, xs.ptr as &u8, xs.len * size_of(T))
    self.len = self.len + xs.len
}

// Remove and return the last element, or null if empty. Prefer `Stack(T)`
// in new code when the access pattern is LIFO - this primitive exists so
// `Stack.pop` can mutate the underlying length without breaching scoped
// mutability (planned, see spec.md §8).
pub fn pop(list: &List($T)) T? {
    if list.len == 0 {
        return null
    }

    list.len = list.len - 1
    let last: &T = list.ptr + list.len
    return Some(last.*)
}

// Get the element at the given index.
pub fn get(list: List($T), index: usize) T? {
    if index >= list.len { return null }
    let elem: &T = list.ptr + index
    return Some(elem.*)
}

// Get the element at the given index.
pub fn get_ref(list: List($T), index: usize) &T? {
    if index >= list.len { return null }
    let elem: &T = list.ptr + index
    return Some(elem)
}

// Set the element at the given index.
// Panics if index is out of bounds.
#deprecated("Prefer index syntax: list[idx] = value")
pub fn set(list: &List($T), index: usize, value: T) {
    if index >= list.len {
        panic("List: index out of bounds")
    }

    // Write value using memcpy
    let dest: &u8 = (list.ptr + index) as &u8
    memcpy(dest, &value as &u8, size_of(T))
}

// Scalar indexing - ref-form. One function covers reads, writes, and
// address-of; the compiler desugars `list[i]`, `list[i] = v`, and `&list[i]`
// all through this. Panics on out-of-bounds.
pub fn op_index_ref(list: &List($T), index: usize) &T {
    if index >= list.len {
        panic("List: index out of bounds")
    }
    return list.ptr + index
}

// Range indexing: returns a sub-slice of the list's live elements.
// Out-of-bounds indices are clamped; an invalid range yields an empty slice.
// Value-form overload (returns a new slice); distinct idx type from the
// scalar ref-form below, so the two coexist without ambiguity.
pub fn op_index(list: List($T), range: Range(usize)) T[] {
    let start = range.start
    let end = range.end
    if start > list.len { start = list.len }
    if end > list.len { end = list.len }
    if start > end { end = start }
    return slice_from_raw_parts(list.ptr + start, end - start)
}

// Remove all elements from the list without freeing memory.
pub fn clear(list: &List($T)) {
    list.len = 0
}

pub fn sort(list: &List($T)) {
    sort(list.as_slice())
}

pub fn sort(list: &List($T), cmp: $F) {
    sort(list.as_slice(), cmp)
}

// =============================================================================
// List Iterator
// =============================================================================

pub type ListIterator = struct(T) {
    list: &List(T)
    current: usize
}

// Create iterator from list
pub fn iter(l: &List($T)) ListIterator(T) {
    return .{ list = l, current = 0 }
}

// An iterator is its own iterable, so `for x in xs.iter().filter(f)`-style
// chains (and the iter combinators' `for item in it`) can consume it.
pub fn iter(it: &ListIterator($T)) ListIterator(T) {
    return it.*
}

// Advance iterator and return next value
pub fn next(it: &ListIterator($T)) T? {
    if it.current >= it.list.len {
        return null
    }

    const elem = it.list.get(it.current)
    it.current = it.current + 1
    return elem
}

// `for &x in xs` - elements by reference, through the slice's iterator.
pub fn iter_ref(l: &List($T)) SliceRefIterator(T) {
    return l.as_slice().iter_ref()
}

test "for &x writes through to the list, directly and via as_slice" {
    let xs: List(u32) = list(0)
    defer xs.deinit()
    xs.push(1u32)
    xs.push(2u32)
    for &x in xs { x.* = x.* * 10 }
    for &x in xs.as_slice() { x.* = x.* + 1 }
    assert_eq(xs[0], 11u32, "first element written through both refs")
    assert_eq(xs[1], 21u32, "second element written through both refs")
}

test "push_all appends a slice in order" {
    let xs: List(u32) = list(0)
    defer xs.deinit()
    xs.push(1u32)
    let more: List(u32) = list(2)
    defer more.deinit()
    more.push(2u32)
    more.push(3u32)
    xs.push_all(more.as_slice())
    assert_eq(xs.len, 3 as usize, "three elements after push_all")
    assert_eq(xs[0], 1u32, "existing element untouched")
    assert_eq(xs[2], 3u32, "order preserved")

    let none: List(u32) = list(0)
    defer none.deinit()
    xs.push_all(none.as_slice())
    assert_eq(xs.len, 3 as usize, "empty source is a no-op")
}

// ─────────────────────────────────────────────────────────────────────────
// Transformations
//
// Each of these returns a fresh `List` and leaves the receiver untouched.
// The result inherits the receiver's allocator unless one is passed, so a
// derived list is freed by the same arena as the list it came from.
// ─────────────────────────────────────────────────────────────────────────

// The allocator a derived list should use: the caller's if given, otherwise
// the receiver's.
fn derived_allocator(own: &Allocator?, override: &Allocator?) &Allocator {
    if override.is_some() { return override.unwrap() }
    return own.or_global()
}

// Apply `f` to every element, in order.
pub fn map(self: &List($T), f: $F, allocator: &Allocator? = null) List($U) {
    let out: List(U) = list(self.len, Some(derived_allocator(self.allocator, allocator)))
    for i in 0..self.len {
        out.push(f(self[i]))
    }
    return out
}

// Apply `f` to every element and concatenate the results. Each intermediate
// list is consumed: `f` hands over ownership, and this frees it.
//
// ponytail: one allocation and one free per element, plus a copy into `out`.
// The intermediates are pure scratch - nothing outlives the loop iteration
// that made it - so the allocator traffic is the whole cost of the call for
// small results. Upgrade path: thread an allocator into `f` and hand it a
// temporary arena created once per call, so the intermediates are bump
// allocations reclaimed in one shot; better still, let `f` append directly
// into `out` and drop the intermediates entirely. Both need an API decision
// about the callback's shape, not just an implementation change - see
// docs/known-issues.md.
pub fn flat_map(self: &List($T), f: $F, allocator: &Allocator? = null) List($U) {
    let out: List(U) = list(self.len, Some(derived_allocator(self.allocator, allocator)))
    for i in 0..self.len {
        let part = f(self[i])
        out.push_all(part.as_slice())
        part.deinit()
    }
    return out
}

// The elements `keep` accepts, in order.
pub fn filter(self: &List($T), keep: $F, allocator: &Allocator? = null) List(T) {
    let out: List(T) = list(self.len, Some(derived_allocator(self.allocator, allocator)))
    for i in 0..self.len {
        if keep(self[i]) { out.push(self[i]) }
    }
    return out
}

// The elements `drop` rejects - `filter` with the predicate negated, spelled
// the way the intent usually reads.
pub fn remove(self: &List($T), drop: $F, allocator: &Allocator? = null) List(T) {
    let out: List(T) = list(self.len, Some(derived_allocator(self.allocator, allocator)))
    for i in 0..self.len {
        let dropped: bool = drop(self[i])
        if !dropped { out.push(self[i]) }
    }
    return out
}

// Combine left to right: `f(f(f(init, x0), x1), x2)`.
pub fn fold(self: &List($T), init: $A, f: $F) A {
    let acc = init
    for i in 0..self.len {
        acc = f(acc, self[i])
    }
    return acc
}

// Combine right to left: `f(x0, f(x1, f(x2, init)))`. The accumulator is the
// second argument, mirroring the direction of travel.
pub fn fold_right(self: &List($T), init: $A, f: $F) A {
    let acc = init
    let i = self.len
    while i > 0 {
        i = i - 1
        acc = f(self[i], acc)
    }
    return acc
}

// ─── Search / query ──────────────────────────────────────────────────
//
// Predicate-taking forms (`find`, `find_index`, `any`, `all`) take any
// callable `$F` usable as `fn(T) bool` — bare functions and capturing
// closures alike (RFC-014). Value-taking forms (`contains`, `index_of`)
// compare with `==`, so they require an element type that supports it.

// First element, or null when empty.
pub fn first(self: List($T)) T? {
    if self.len == 0 { return null }
    return Some(self[0])
}

// Last element, or null when empty.
pub fn last(self: List($T)) T? {
    if self.len == 0 { return null }
    return Some(self[self.len - 1])
}

// Whether any element equals `value`.
pub fn contains(self: List($T), value: T) bool {
    return self.index_of(value).is_some()
}

// Index of the first element equal to `value`, or null.
pub fn index_of(self: List($T), value: T) usize? {
    for i in 0..self.len {
        if self[i] == value { return Some(i) }
    }
    return null
}

// First element satisfying `pred`, or null.
pub fn find(self: &List($T), pred: $F) T? {
    for i in 0..self.len {
        if pred(self[i]) { return Some(self[i]) }
    }
    return null
}

// Index of the first element satisfying `pred`, or null.
pub fn find_index(self: &List($T), pred: $F) usize? {
    for i in 0..self.len {
        if pred(self[i]) { return Some(i) }
    }
    return null
}

// Whether any element satisfies `pred`. False for an empty list.
pub fn any(self: &List($T), pred: $F) bool {
    return self.find_index(pred).is_some()
}

// Whether every element satisfies `pred`. True for an empty list.
pub fn all(self: &List($T), pred: $F) bool {
    for i in 0..self.len {
        let ok: bool = pred(self[i])
        if !ok { return false }
    }
    return true
}

// Everything after the first `n` elements. Fewer than `n` elements yields an
// empty list rather than an error.
pub fn drop_first(self: &List($T), n: usize, allocator: &Allocator? = null) List(T) {
    let out: List(T) = list(self.len, Some(derived_allocator(self.allocator, allocator)))
    let start = if n > self.len { self.len } else { n }
    for i in start..self.len {
        out.push(self[i])
    }
    return out
}

// ─── Direct-loop counterparts of the iterator consumers ──────────────
//
// These duplicate `std.iter` on purpose: no adapter structs, no generic
// nesting — guaranteed straight loops for hot paths.

// Run `f` on every element, in order. To accumulate, use `fold`; to mutate
// outer state from a closure, capture a reference and write through it.
pub fn each(self: &List($T), f: $F) {
    for i in 0..self.len {
        f(self[i])
    }
}

// Number of elements `pred` accepts.
pub fn count(self: &List($T), pred: $F) usize {
    let n: usize = 0
    for i in 0..self.len {
        if pred(self[i]) { n = n + 1 }
    }
    return n
}

// Smallest element by `<`, or null when empty. Requires an ordered element
// type (primitive or `op_cmp`).
pub fn min(self: &List($T)) T? {
    if self.len == 0 { return null }
    let best = self[0]
    for i in 1..self.len {
        if self[i] < best { best = self[i] }
    }
    return Some(best)
}

// Largest element by `<`, or null when empty.
pub fn max(self: &List($T)) T? {
    if self.len == 0 { return null }
    let best = self[0]
    for i in 1..self.len {
        if best < self[i] { best = self[i] }
    }
    return Some(best)
}

// Element with the smallest `key(x)`, or null when empty. Ties keep the
// earliest.
pub fn min_by(self: &List($T), key: $F) T? {
    if self.len == 0 { return null }
    let best = self[0]
    let best_key = key(best)
    for i in 1..self.len {
        let k = key(self[i])
        if k < best_key {
            best_key = k
            best = self[i]
        }
    }
    return Some(best)
}

// Element with the largest `key(x)`, or null when empty. Ties keep the
// earliest.
pub fn max_by(self: &List($T), key: $F) T? {
    if self.len == 0 { return null }
    let best = self[0]
    let best_key = key(best)
    for i in 1..self.len {
        let k = key(self[i])
        if best_key < k {
            best_key = k
            best = self[i]
        }
    }
    return Some(best)
}

// Sort in place, ordering elements by `key(x)` ascending.
// `<` rather than `op_cmp` in the comparator: the overloaded `op_cmp`
// name cannot resolve while the key type is still generic.
pub fn sort_by(self: &List($T), key: $F) {
    sort(self.as_slice(), fn(a, b) {
        let ka = key(a)
        let kb = key(b)
        if ka < kb { Ord.Less } else if kb < ka { Ord.Greater } else { Ord.Equal }
    })
}

// Reverse in place.
pub fn reverse(self: &List($T)) {
    if self.len < 2 { return }
    let i: usize = 0
    let j = self.len - 1
    while i < j {
        let tmp = self[i]
        self[i] = self[j]
        self[j] = tmp
        i = i + 1
        j = j - 1
    }
}

// Reversed copy; the receiver is untouched.
pub fn reversed(self: &List($T), allocator: &Allocator? = null) List(T) {
    let out: List(T) = list(self.len, Some(derived_allocator(self.allocator, allocator)))
    let i = self.len
    while i > 0 {
        i = i - 1
        out.push(self[i])
    }
    return out
}

// The last `n` elements (all of them when `n` exceeds the length).
pub fn take_last(self: &List($T), n: usize, allocator: &Allocator? = null) List(T) {
    let out: List(T) = list(n, Some(derived_allocator(self.allocator, allocator)))
    let start = if n > self.len { 0 as usize } else { self.len - n }
    for i in start..self.len {
        out.push(self[i])
    }
    return out
}

// Pair up elements positionally, stopping at the shorter list.
pub fn zip(self: &List($T), other: &List($B), allocator: &Allocator? = null) List((T, B)) {
    let n = if self.len < other.len { self.len } else { other.len }
    let out: List((T, B)) = list(n, Some(derived_allocator(self.allocator, allocator)))
    for i in 0..n {
        out.push((self[i], other[i]))
    }
    return out
}

// Split into (accepted, rejected) by `pred`, preserving order.
pub fn partition(self: &List($T), pred: $F, allocator: &Allocator? = null) (List(T), List(T)) {
    let yes: List(T) = list(0, Some(derived_allocator(self.allocator, allocator)))
    let no: List(T) = list(0, Some(derived_allocator(self.allocator, allocator)))
    for i in 0..self.len {
        if pred(self[i]) {
            yes.push(self[i])
        } else {
            no.push(self[i])
        }
    }
    return (yes, no)
}

// Copy with runs of consecutive `==` duplicates collapsed to one element
// (Rust-style dedup). Fully unique across the whole list needs a Set.
pub fn dedup(self: &List($T), allocator: &Allocator? = null) List(T) {
    let out: List(T) = list(0, Some(derived_allocator(self.allocator, allocator)))
    for i in 0..self.len {
        if i == 0 {
            out.push(self[i])
        } else {
            let same: bool = self[i] == self[i - 1]
            if !same { out.push(self[i]) }
        }
    }
    return out
}

// Concatenate string views with `sep` between them.
pub fn join(self: &List(String), sep: String, allocator: &Allocator? = null) OwnedString {
    let sb = string_builder(0, allocator)
    for i in 0..self.len {
        if i > 0 { sb.append(sep) }
        sb.append(self[i])
    }
    return sb.to_string()
}

test "map applies f in order and leaves the receiver alone" {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    xs.push(1); xs.push(2); xs.push(3)

    let doubled = xs.map(fn(v: i32) i32 { v * 2 })
    defer doubled.deinit()
    assert_eq(doubled.len, 3 as usize, "same length")
    assert_eq(doubled[0], 2, "first doubled")
    assert_eq(doubled[2], 6, "last doubled")
    assert_eq(xs[0], 1, "receiver untouched")
}

test "flat_map concatenates and frees the intermediates" {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    xs.push(1); xs.push(2)

    let out = xs.flat_map(fn(v: i32) List(i32) {
        let part: List(i32) = list(2)
        part.push(v)
        part.push(v * 10)
        part
    })
    defer out.deinit()
    assert_eq(out.len, 4 as usize, "two elements each")
    assert_eq(out[1], 10, "second of the first pair")
    assert_eq(out[2], 2, "first of the second pair")
}

test "filter keeps matches, remove keeps the rest" {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    for i in 0..6 { xs.push(i as i32) }

    let evens = xs.filter(fn(v: i32) bool { v % 2 == 0 })
    defer evens.deinit()
    let odds = xs.remove(fn(v: i32) bool { v % 2 == 0 })
    defer odds.deinit()

    assert_eq(evens.len, 3 as usize, "three evens")
    assert_eq(odds.len, 3 as usize, "three odds")
    assert_eq(evens[0], 0, "first even")
    assert_eq(odds[0], 1, "first odd")
    assert_eq(evens.len + odds.len, xs.len, "the two partitions cover the input")
}

test "fold and fold_right differ in association" {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    xs.push(1); xs.push(2); xs.push(3)

    // Subtraction is not associative, so the two directions disagree:
    // left  ((0-1)-2)-3 = -6
    // right 1-(2-(3-0)) = 2
    // The seed pins the accumulator type ($A): a bare `0` won't default,
    // because `f` is duck-typed ($F) and only constrains A at instantiation.
    let l = xs.fold(0i32, fn(acc, v) { acc - v })
    let r = xs.fold_right(0i32, fn(v, acc) { v - acc })
    assert_eq(l, -6i32, "left-associated")
    assert_eq(r, 2i32, "right-associated")
}

test "drop_first skips a prefix and clamps past the end" {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    for i in 0..4 { xs.push(i as i32) }

    let tail = xs.drop_first(2 as usize)
    defer tail.deinit()
    assert_eq(tail.len, 2 as usize, "two remain")
    assert_eq(tail[0], 2, "starts after the prefix")

    let past = xs.drop_first(99 as usize)
    defer past.deinit()
    assert_eq(past.len, 0 as usize, "dropping past the end is empty, not an error")
}

fn test_is_even(x: i32) bool { return x % 2 == 0 }

test "search utilities: contains, index_of, first, last" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(10i32)
    xs.push(20i32)
    xs.push(30i32)

    assert_true(xs.contains(20i32), "present value is found")
    assert_true(!xs.contains(99i32), "absent value is not")
    assert_eq(xs.index_of(30i32).unwrap(), 2 as usize, "index of the last element")
    assert_true(xs.index_of(99i32).is_none(), "absent value has no index")
    assert_eq(xs.first().unwrap(), 10i32, "first element")
    assert_eq(xs.last().unwrap(), 30i32, "last element")

    let empty: List(i32) = list(0)
    defer empty.deinit()
    assert_true(empty.first().is_none(), "empty list has no first")
    assert_true(empty.last().is_none(), "empty list has no last")
}

test "search utilities: find, find_index, any, all" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(2i32)
    xs.push(4i32)

    assert_eq(xs.find(test_is_even).unwrap(), 2i32, "first even element")
    assert_eq(xs.find_index(test_is_even).unwrap(), 1 as usize, "its index")
    assert_true(xs.any(test_is_even), "any is true when one matches")
    assert_true(!xs.all(test_is_even), "all is false when one does not")

    let evens: List(i32) = list(2)
    defer evens.deinit()
    evens.push(2i32)
    evens.push(4i32)
    assert_true(evens.all(test_is_even), "all is true when every element matches")

    let empty: List(i32) = list(0)
    defer empty.deinit()
    assert_true(!empty.any(test_is_even), "any is false on empty")
    assert_true(empty.all(test_is_even), "all is vacuously true on empty")
}

test "deinit is idempotent on every core container" {
    // Any deinit may run twice: state nulls on the first call, so the
    // second is a no-op, not a double free.
    let xs: List(OwnedString) = list(2)
    xs.push(from_view("alpha"))
    xs.push(from_view("beta"))
    xs.deinit()
    xs.deinit()
    assert_eq(xs.len, 0 as usize, "list is empty after deinit")

    let d: Dict(OwnedString, i32) = dict()
    d.set("k", 1i32)
    d.deinit()
    d.deinit()

    let s = from_view("gamma")
    s.deinit()
    s.deinit()

    let sb = string_builder(8)
    sb.append("x")
    sb.deinit()
    sb.deinit()

    let o: OwnedString? = Some(from_view("delta"))
    o.deinit()
    o.deinit()
    assert_true(o.is_none(), "option resets to None on deinit")
}

test "combinators accept capturing closures with unannotated params" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32); xs.push(2i32); xs.push(3i32)

    let floor = 1
    let scale = 10
    let kept = xs.filter(fn(v) { v > floor })
    defer kept.deinit()
    let scaled = kept.map(fn(v) { v * scale })
    defer scaled.deinit()
    assert_eq(scaled.len, 2 as usize, "two elements pass the floor")
    assert_eq(scaled[0], 20i32, "closure saw the captured scale")
}

test "each and count" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32); xs.push(2i32); xs.push(3i32)

    // Captures are by value and read-only: mutate through a captured reference.
    let sum = 0i32
    let sum_ref = &sum
    xs.each(fn(v) { sum_ref.* = sum_ref.* + v })
    assert_eq(sum, 6i32, "each visited every element")

    assert_eq(xs.count(test_is_even), 1 as usize, "one even element")
}

test "min max min_by max_by on lists" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(4i32); xs.push(1i32); xs.push(3i32)

    assert_eq(xs.min().unwrap(), 1i32, "smallest")
    assert_eq(xs.max().unwrap(), 4i32, "largest")
    assert_eq(xs.min_by(fn(v) { 0 - v }).unwrap(), 4i32, "smallest key = largest value")
    assert_eq(xs.max_by(fn(v) { 0 - v }).unwrap(), 1i32, "largest key = smallest value")

    let empty: List(i32) = list(0)
    defer empty.deinit()
    assert_true(empty.min().is_none(), "empty min is null")
    assert_true(empty.min_by(fn(v) { v }).is_none(), "empty min_by is null")
}

test "sort_by orders by key" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32); xs.push(3i32); xs.push(2i32)

    xs.sort_by(fn(v) { 0 - v })
    assert_eq(xs[0], 3i32, "descending by negated key")
    assert_eq(xs[2], 1i32, "smallest last")
}

test "reverse in place and reversed copy" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32); xs.push(2i32); xs.push(3i32)

    let back = xs.reversed()
    defer back.deinit()
    assert_eq(back[0], 3i32, "copy is reversed")
    assert_eq(xs[0], 1i32, "receiver untouched by reversed()")

    xs.reverse()
    assert_eq(xs[0], 3i32, "in-place reversal")
    assert_eq(xs[2], 1i32, "ends swapped")

    let two: List(i32) = list(2)
    defer two.deinit()
    two.push(7i32); two.push(9i32)
    two.reverse()
    assert_eq(two[0], 9i32, "even length reverses fully")
}

test "take_last clamps like drop_first" {
    let xs: List(i32) = list(4)
    defer xs.deinit()
    for i in 0..4 { xs.push(i as i32) }

    let tail = xs.take_last(2 as usize)
    defer tail.deinit()
    assert_eq(tail.len, 2 as usize, "two elements")
    assert_eq(tail[0], 2i32, "the last two")

    let all_of_them = xs.take_last(99 as usize)
    defer all_of_them.deinit()
    assert_eq(all_of_them.len, 4 as usize, "over-asking yields everything")
}

test "zip pairs positionally and stops at the shorter list" {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32); xs.push(2i32); xs.push(3i32)
    let ys: List(i32) = list(2)
    defer ys.deinit()
    ys.push(10i32); ys.push(20i32)

    let pairs = xs.zip(&ys)
    defer pairs.deinit()
    assert_eq(pairs.len, 2 as usize, "shorter side bounds the zip")
    assert_eq(pairs[0].0, 1i32, "left element")
    assert_eq(pairs[1].1, 20i32, "right element")
}

test "partition splits by predicate preserving order" {
    let xs: List(i32) = list(4)
    defer xs.deinit()
    for i in 0..4 { xs.push(i as i32) }

    let parts = xs.partition(test_is_even)
    let evens = parts.0
    defer evens.deinit()
    let odds = parts.1
    defer odds.deinit()
    assert_eq(evens.len, 2 as usize, "two evens")
    assert_eq(evens[0], 0i32, "in order")
    assert_eq(odds[1], 3i32, "rejects in order too")
}

test "dedup collapses consecutive runs only" {
    let xs: List(i32) = list(6)
    defer xs.deinit()
    xs.push(1i32); xs.push(1i32); xs.push(2i32); xs.push(2i32); xs.push(2i32); xs.push(1i32)

    let out = xs.dedup()
    defer out.deinit()
    assert_eq(out.len, 3 as usize, "runs collapsed")
    assert_eq(out[0], 1i32, "first run")
    assert_eq(out[1], 2i32, "second run")
    assert_eq(out[2], 1i32, "non-consecutive duplicate survives")
}

test "join concatenates with separator" {
    let xs: List(String) = list(3)
    defer xs.deinit()
    xs.push("a")
    xs.push("b")
    xs.push("c")

    let joined = xs.join(", ")
    defer joined.deinit()
    assert_eq(joined.as_view(), "a, b, c", "separators between elements only")

    let one: List(String) = list(1)
    defer one.deinit()
    one.push("solo")
    let single = one.join(", ")
    defer single.deinit()
    assert_eq(single.as_view(), "solo", "no separator for one element")
}

test "filled_list gives a list of length count, ready to index" {
    let xs: List(usize) = filled_list(3, 7)
    defer xs.deinit()
    assert_eq(xs.len, 3 as usize, "length is the count, not a reserved capacity")
    assert_eq(xs[0], 7 as usize, "every slot holds the value")
    assert_eq(xs[2], 7 as usize, "including the last")
    xs[1] = 9
    assert_eq(xs[1], 9 as usize, "and the slots are assignable")

    let empty: List(bool) = filled_list(0, true)
    defer empty.deinit()
    assert_eq(empty.len, 0 as usize, "a count of zero is an empty list")
}
