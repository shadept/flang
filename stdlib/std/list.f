// Generic dynamic array backed by manually managed heap storage.
// Uses raw malloc/free for simplicity (allocator support to be added later).

import std.allocator
import std.mem
import std.option
import std.sort
import std.test

pub type List = struct(T) {
    ptr: &T
    len: usize
    cap: usize
    allocator: &Allocator?
}

const DEFAULT_CAPACITY: usize = 16

pub fn list(capacity: usize, allocator: &Allocator? = null) List($T) {
    if capacity == 0 {
        let empty: List(T)
        empty.allocator = allocator
        return empty
    }
    const bytes = capacity * size_of(T)
    const buf = allocator.or_global().alloc(bytes, align_of(T))
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
    const buf = allocator.or_global().alloc(bytes, align_of(T))
        .expect("list(copy): allocation failed")
    memcpy(buf.ptr, source.ptr as &u8, bytes)
    return .{
        ptr = buf.ptr as &T,
        len = source.len,
        cap = source.len,
        allocator = allocator,
    }
}

// Free the backing storage. The list should not be used after this.
// Calls deinit on all stored elements before freeing.
pub fn deinit(self: &List($T)) {
    if self.cap > 0 {
        // Deinit all live elements
        for i in 0..self.len as isize {
            const elem: &T = self.ptr + (i as usize)
            elem.deinit()
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

pub fn sort(list: &List($T), cmp: fn(T, T) Ord) {
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

// Advance iterator and return next value
pub fn next(it: &ListIterator($T)) T? {
    if it.current >= it.list.len {
        return null
    }

    const elem = it.list.get(it.current)
    it.current = it.current + 1
    return elem
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
pub fn map(self: &List($T), f: fn(T) $U, allocator: &Allocator? = null) List(U) {
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
pub fn flat_map(self: &List($T), f: fn(T) List($U), allocator: &Allocator? = null) List(U) {
    let out: List(U) = list(self.len, Some(derived_allocator(self.allocator, allocator)))
    for i in 0..self.len {
        let part = f(self[i])
        out.push_all(part.as_slice())
        part.deinit()
    }
    return out
}

// The elements `keep` accepts, in order.
pub fn filter(self: &List($T), keep: fn(T) bool, allocator: &Allocator? = null) List(T) {
    let out: List(T) = list(self.len, Some(derived_allocator(self.allocator, allocator)))
    for i in 0..self.len {
        if keep(self[i]) { out.push(self[i]) }
    }
    return out
}

// The elements `drop` rejects - `filter` with the predicate negated, spelled
// the way the intent usually reads.
pub fn remove(self: &List($T), drop: fn(T) bool, allocator: &Allocator? = null) List(T) {
    let out: List(T) = list(self.len, Some(derived_allocator(self.allocator, allocator)))
    for i in 0..self.len {
        if !drop(self[i]) { out.push(self[i]) }
    }
    return out
}

// Combine left to right: `f(f(f(init, x0), x1), x2)`.
pub fn fold(self: &List($T), init: $A, f: fn(A, T) A) A {
    let acc = init
    for i in 0..self.len {
        acc = f(acc, self[i])
    }
    return acc
}

// Combine right to left: `f(x0, f(x1, f(x2, init)))`. The accumulator is the
// second argument, mirroring the direction of travel.
pub fn fold_right(self: &List($T), init: $A, f: fn(T, A) A) A {
    let acc = init
    let i = self.len
    while i > 0 {
        i = i - 1
        acc = f(self[i], acc)
    }
    return acc
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
    let l = xs.fold(0, fn(acc: i32, v: i32) i32 { acc - v })
    let r = xs.fold_right(0, fn(v: i32, acc: i32) i32 { v - acc })
    assert_eq(l, -6, "left-associated")
    assert_eq(r, 2, "right-associated")
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
