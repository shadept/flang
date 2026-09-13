// Slice types, operations, and iterator implementation.
//
// Slices are fat-pointer views into contiguous memory: `struct { ptr: &T, len: usize }`. They do
// NOT own the underlying data. Use `T[]` syntax as shorthand for `Slice(T)`.
//
// Indexing:
//   s[i]       - returns element at index i, panics if out of bounds
//   s[a..b]    - returns a sub-slice from a (inclusive) to b (exclusive), clamped to bounds
//
// Iteration (iterator protocol):
//   for val in s { ... }
//   Equivalent to: iter(&s) -> SliceIterator(T), then repeated next(&it) -> T?
//
// Construction:
//   slice_from_raw_parts(ptr, len)  - create a slice from a raw pointer and length

import core.math
import core.panic
import core.range
import core.rtti

import std.option
import std.test

// A view into a contiguous sequence of elements of type T. A Slice does not own ptr.
pub type Slice = struct(T) {
    ptr: &T
    len: usize
}

// =============================================================================
// Construction
// =============================================================================

// Creates a slice from a raw pointer and length.
// The caller must ensure `ptr` points to at least `len` contiguous elements of T.
pub fn slice_from_raw_parts(ptr: &$T, len: usize) T[] {
    return .{ ptr, len }
}

// =============================================================================
// Queries
//
// Element access, then search. Predicate forms take any callable `$F` usable as `fn(T) bool`; value
// forms compare with `==`. A form that copies an element out is a compile-time error on an owning
// element type (RFC-032) and names the reference twin to use instead.
// =============================================================================

// Returns the element at `idx`, or null if `idx` is out of bounds. Copyable elements only: a slice
// lends its storage and never hands an element over, so an owning element type is a compile-time
// error at the call (RFC-032).
pub fn get(s: $T[], idx: usize) T? {
    #if !type_info(T).copyable {
        #error($"get copies the element out, and {T.name} owns something",
            $"read it in place with get_ref, or take it out of the container with pop or drain")
    }
    if idx >= s.len {
        return null
    }
    const ptr = s.ptr + idx
    return Some(ptr.*)
}

// Returns a reference to the element at `idx`, or null past the end.
pub fn get_ref(s: $T[], idx: usize) &T? {
    if idx >= s.len {
        return null
    }
    return Some(s.ptr + idx)
}

// Returns the first element, or null when empty. Copyable elements only; an owning element type is
// a compile-time error at the call (RFC-032).
pub fn first(s: $T[]) T? {
    #if !type_info(T).copyable {
        #error($"first copies the element out, and {T.name} owns something", "use first_ref")
    }
    if s.len == 0 {
        return null
    }
    return Some(s[0])
}

// Returns the last element, or null when empty. Copyable elements only; an owning element type is a
// compile-time error at the call (RFC-032).
pub fn last(s: $T[]) T? {
    #if !type_info(T).copyable {
        #error($"last copies the element out, and {T.name} owns something", "use last_ref")
    }
    if s.len == 0 {
        return null
    }
    return Some(s[s.len - 1])
}

// Returns true if the slice contains `value`.
pub fn contains(s: $T[], value: T) bool {
    for x in s {
        if x == value {
            return true
        }
    }
    return false
}

// Returns the index of the first occurrence of `value`, or null if not found.
pub fn index_of(s: $T[], value: T) usize? {
    for i in 0..s.len {
        if s[i] == value {
            return Some(i)
        }
    }
    return null
}

// Returns the index of the last occurrence of `value`, or null if not found.
pub fn last_index_of(s: $T[], value: T) usize? {
    let i = s.len
    for _i in 0..s.len {
        i = i - 1
        if s[i] == value {
            return Some(i)
        }
    }
    return null
}

// Returns the number of elements equal to `value`.
pub fn count(s: $T[], value: T) usize {
    let n: usize = 0
    for x in s {
        if x == value {
            n = n + 1
        }
    }
    return n
}

// Returns how many elements satisfy `pred`. `count` counts occurrences of a value.
pub fn count_if(s: $T[], pred: $F) usize {
    let n: usize = 0
    for i in 0..s.len {
        let hit: bool = false
        #if type_info(T).copyable {
            hit = pred(s[i])
        } else {
            hit = pred(s.ptr + i)
        }
        if hit {
            n = n + 1
        }
    }
    return n
}

// Returns the first element satisfying `pred`, or null. Copyable elements only; an owning element
// type is a compile-time error at the call (RFC-032).
pub fn find(s: $T[], pred: $F) T? {
    #if !type_info(T).copyable {
        #error($"find copies the element out, and {T.name} owns something", "use find_ref")
    }
    for x in s {
        if pred(x) {
            return Some(x)
        }
    }
    return null
}

// Returns a reference to the first element satisfying `pred`, or null. The reference is valid until
// the storage behind the slice moves.
pub fn find_ref(s: $T[], pred: $F) &T? {
    const i = s.find_index(pred)?
    return Some(s.ptr + i)
}

// Returns the index of the first element satisfying `pred`, or null.
pub fn find_index(s: $T[], pred: $F) usize? {
    for i in 0..s.len {
        let hit: bool = false
        #if type_info(T).copyable {
            hit = pred(s[i])
        } else {
            hit = pred(s.ptr + i)
        }
        if hit {
            return Some(i)
        }
    }
    return null
}

// Returns whether any element satisfies `pred`. False when empty.
pub fn any(s: $T[], pred: $F) bool {
    return s.find_index(pred).is_some()
}

// Returns whether every element satisfies `pred`. True when empty.
pub fn all(s: $T[], pred: $F) bool {
    for i in 0..s.len {
        let ok: bool = false
        #if type_info(T).copyable {
            ok = pred(s[i])
        } else {
            ok = pred(s.ptr + i)
        }
        if !ok {
            return false
        }
    }
    return true
}

// Returns the index of the first element for which `pred` is false. O(log n).
//
// - `pred`: must be true for a prefix of `s` and false for the rest; the precondition is not
//   checked. `lower_bound`, `upper_bound` and `binary_search` are built on this.
//
// Returns `s.len` when `pred` holds everywhere and 0 when it holds nowhere.
pub fn partition_point(s: $T[], pred: $F) usize {
    let lo: usize = 0
    let hi: usize = s.len
    while lo < hi {
        const mid = lo + (hi - lo) / 2
        if pred(s[mid]) {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo
}

// Returns the index of the first element not less than `value`: the first position at which `value`
// could be inserted and keep `s` sorted. `s.len` when every element is smaller.
//
// - `s`: must be sorted ascending.
pub fn lower_bound(s: $T[], value: T) usize {
    return s.partition_point(fn(x) { x < value })
}

// Returns the index of the first element greater than `value`: the last position at which `value`
// could be inserted and keep `s` sorted. `upper_bound - lower_bound` counts the copies of `value`.
//
// - `s`: must be sorted ascending.
pub fn upper_bound(s: $T[], value: T) usize {
    return s.partition_point(fn(x) { !(value < x) })
}

// Returns the index of `value`, or null when absent; with duplicates, the first.
//
// - `s`: must be sorted ascending; the result is meaningless otherwise.
pub fn binary_search(s: $T[], value: T) usize? {
    const i = s.lower_bound(value)
    if i < s.len and s[i] == value {
        return Some(i)
    }
    return null
}

// Returns true if `s` starts with the elements in `prefix`.
pub fn starts_with(s: $T[], prefix: T[]) bool {
    if prefix.len > s.len {
        return false
    }
    for i in 0..prefix.len {
        if s[i] != prefix[i] {
            return false
        }
    }
    return true
}

// Returns true if `s` ends with the elements in `suffix`.
pub fn ends_with(s: $T[], suffix: T[]) bool {
    if suffix.len > s.len {
        return false
    }
    const offset = s.len - suffix.len
    for i in 0..suffix.len {
        if s[offset + i] != suffix[i] {
            return false
        }
    }
    return true
}

// Returns the smallest element by `<`, or null when empty. Copyable elements only; an owning
// element type is a compile-time error at the call (RFC-032).
pub fn min(s: $T[]) T? {
    #if !type_info(T).copyable {
        #error($"min copies the element out, and {T.name} owns something", "use min_ref")
    }
    if s.len == 0 {
        return null
    }
    let best = s[0]
    for i in 1..s.len {
        if s[i] < best {
            best = s[i]
        }
    }
    return Some(best)
}

// Returns a reference to the smallest element by `<`, or null when empty. The reference is valid
// until the storage behind the slice moves.
pub fn min_ref(s: $T[]) &T? {
    if s.len == 0 {
        return null
    }
    let best: &T = s.ptr
    for i in 1..s.len {
        const cand: &T = s.ptr + i
        if cand.* < best.* {
            best = cand
        }
    }
    return Some(best)
}

// Returns the largest element by `<`, or null when empty. Copyable elements only; an owning element
// type is a compile-time error at the call (RFC-032).
pub fn max(s: $T[]) T? {
    #if !type_info(T).copyable {
        #error($"max copies the element out, and {T.name} owns something", "use max_ref")
    }
    if s.len == 0 {
        return null
    }
    let best = s[0]
    for i in 1..s.len {
        if best < s[i] {
            best = s[i]
        }
    }
    return Some(best)
}

// Returns a reference to the largest element by `<`, or null when empty. The reference is valid
// until the storage behind the slice moves.
pub fn max_ref(s: $T[]) &T? {
    if s.len == 0 {
        return null
    }
    let best: &T = s.ptr
    for i in 1..s.len {
        const cand: &T = s.ptr + i
        if best.* < cand.* {
            best = cand
        }
    }
    return Some(best)
}

// Returns the element with the smallest `key(x)`, or null when empty. Ties keep the earliest.
// Copyable elements only; an owning element type is a compile-time error at the call (RFC-032).
pub fn min_by(s: $T[], key: $F) T? {
    #if !type_info(T).copyable {
        #error($"min_by copies the element out, and {T.name} owns something", "use min_ref")
    }
    if s.len == 0 {
        return null
    }
    let best = s[0]
    let best_key = key(best)
    for i in 1..s.len {
        let k = key(s[i])
        if k < best_key {
            best_key = k
            best = s[i]
        }
    }
    return Some(best)
}

// Returns the element with the largest `key(x)`, or null when empty. Ties keep the earliest.
// Copyable elements only; an owning element type is a compile-time error at the call (RFC-032).
pub fn max_by(s: $T[], key: $F) T? {
    #if !type_info(T).copyable {
        #error($"max_by copies the element out, and {T.name} owns something", "use max_ref")
    }
    if s.len == 0 {
        return null
    }
    let best = s[0]
    let best_key = key(best)
    for i in 1..s.len {
        let k = key(s[i])
        if best_key < k {
            best_key = k
            best = s[i]
        }
    }
    return Some(best)
}

// =============================================================================
// Mutations
// =============================================================================

// Swaps the values at two mutable references. No value is read into a second location and none is
// released, so the same owners exist before and after: this is the one exchange an owning element
// type has (RFC-032), and `reverse` and `sort` are built on it.
//
// A copyable element goes through a local temporary, which the C compiler turns into register
// moves; an owning one cannot be read into a temporary at all, so its bytes are exchanged in place.
//
// - `a`, `b`: must not point into each other. The same reference twice is a no-op.
pub fn swap(a: &$T, b: &T) {
    #if type_info(T).copyable {
        let tmp = a.*
        a.* = b.*
        b.* = tmp
    } else {
        memswap(a as &u8, b as &u8, size_of(T))
    }
}

// Fills every element of the slice with `value`. Copyable elements only: every element it
// overwrites would be dropped with nobody releasing it, and one owning value cannot be `len` of
// them, so an owning element type is a compile-time error at the call (RFC-032).
pub fn fill(s: $T[], value: T) {
    #if !type_info(T).copyable {
        #error($"fill needs copyable elements, {T.name} owns something",
            "clear the container and push a clone per element")
    }
    for i in 0..s.len {
        s[i] = value
    }
}

// Replaces all occurrences of `old` with `new` in-place. Returns the number of replacements made.
// Copyable elements only, for the reason `fill` is: an owning element type is a compile-time error
// at the call (RFC-032).
pub fn replace(s: $T[], old: T, new: T) usize {
    #if !type_info(T).copyable {
        #error($"replace needs copyable elements, {T.name} owns something",
            "exchange the element with swap, or go through the container's set")
    }
    let n: usize = 0
    for i in 0..s.len {
        if s[i] == old {
            s[i] = new
            n = n + 1
        }
    }
    return n
}

// Reverses the elements of the slice in-place.
pub fn reverse(s: $T[]) {
    if s.len <= 1 {
        return
    }
    let lo: usize = 0
    let hi: usize = s.len - 1
    for _i in 0..s.len / 2 {
        swap(&s[lo], &s[hi])
        lo = lo + 1
        hi = hi - 1
    }
}

// =============================================================================
// Traversal, folds and copies
// =============================================================================

// Calls `f` on every element, in order. To accumulate, use `fold`; to mutate outer state from a
// closure, capture a reference and write through it.
pub fn each(s: $T[], f: $F) {
    for i in 0..s.len {
        #if type_info(T).copyable {
            f(s[i])
        } else {
            f(s.ptr + i)
        }
    }
}

// Combines left to right: `f(f(f(init, x0), x1), x2)`.
pub fn fold(s: $T[], init: $A, f: $F) A {
    let acc = init
    for i in 0..s.len {
        #if type_info(T).copyable {
            acc = f(acc, s[i])
        } else {
            acc = f(acc, s.ptr + i)
        }
    }
    return acc
}

// Combines right to left: `f(x0, f(x1, f(x2, init)))`. The accumulator is `f`'s second argument.
pub fn fold_right(s: $T[], init: $A, f: $F) A {
    let acc = init
    let i = s.len
    while i > 0 {
        i = i - 1
        #if type_info(T).copyable {
            acc = f(s[i], acc)
        } else {
            acc = f(s.ptr + i, acc)
        }
    }
    return acc
}

// Copies min(src.len, dest.len) elements from `src` into `dest` bitwise and returns the number
// copied. Copyable elements only: a slice carries no allocator to clone owning elements with, so
// those are cloned by the caller, one `clone(&T, allocator)` per element. An owning element type is
// a compile-time error at the call.
pub fn copy_to(src: $T[], dest: T[]) usize {
    #if !type_info(T).copyable {
        #error($"copy_to needs copyable elements, {T.name} owns something",
            $"clone each element with clone(&{T.name}, allocator)")
    }
    const len = min(src.len, dest.len)
    memmove(dest.ptr, src.ptr, len * size_of(T))
    return len
}

// Reinterprets a slice of T as a slice of U.
// Panics if the total byte size is not evenly divisible by size_of(U).
//
// Copyable elements only: two views over one owner is two releasers, with nothing in either view
// saying which holds the element. An owning element type is a compile-time error at the call.
pub fn reinterpret(src: $T[]) $U[] {
    #if !type_info(T).copyable {
        #error($"reinterpret would make a second view over elements {T.name} owns", "")
    }
    const total_bytes = src.len * size_of(T)
    const size_of_u = size_of(U)
    if total_bytes % size_of(U) != 0 {
        panic("Alignment/Size mismatch")
    }
    return .{ ptr = src.ptr as &U, len = total_bytes / size_of_u }
}

// =============================================================================
// Operators
// =============================================================================

// Returns the element at `idx`. Panics if `idx >= s.len`. Copyable elements only; an owning element
// type is a compile-time error at the call (RFC-032).
pub fn op_index(s: $T[], idx: usize) T {
    #if !type_info(T).copyable {
        #error($"s[i] copies the element out, and {T.name} owns something",
            $"take a reference with &s[i], or take the element out with pop or drain")
    }
    if idx >= s.len {
        panic("index out of bounds")
    }

    const ptr = s.ptr + idx
    return ptr.*
}

// Returns a sub-slice for the given range.
// Out-of-bounds indices are clamped; an invalid range (start > end) yields an empty slice.
pub fn op_index(s: $T[], range: Range(usize)) T[] {
    let start = range.start
    let end = range.end

    // Clamp to valid bounds, return empty slice for invalid ranges
    if start > s.len {
        start = s.len
    }
    if end > s.len {
        end = s.len
    }
    if start > end {
        end = start
    }

    return slice_from_raw_parts(s.ptr + start, end - start)
}

// Sets the element at `index` to `value`. Panics if `index >= s.len`. Copyable elements only: the
// overwritten element would be dropped with nobody releasing it, so an owning element type is a
// compile-time error at the call (RFC-032).
pub fn op_set_index(self: &Slice($T), index: usize, value: T) {
    #if !type_info(T).copyable {
        #error($"s[i] = v drops the element it overwrites, and {T.name} owns something",
            "exchange it with swap, or go through the container's set, which deinits the old value")
    }
    if index >= self.len {
        panic("index out of bounds")
    }
    const slot = self.ptr + index
    slot.* = value
}

// =============================================================================
// Iterators
// =============================================================================

// Iterator state for slices. Created by `iter(&slice)`. Stores a copy of the slice and tracks the
// current position.
pub type SliceIterator = struct(T) {
    slice: T[]
    index: usize
}

// Creates an iterator over the elements of a slice. Copyable elements only: the iterator yields a
// copy per step, so an owning element type is a compile-time error at the loop (RFC-032).
pub fn iter(slice: &$T[]) SliceIterator(T) {
    #if !type_info(T).copyable {
        #error($"`for x in xs` copies each element, and {T.name} owns something",
            "iterate by reference with `for &x in xs`, or consume the container with `for x in xs.drain()`")
    }
    return .{ slice = slice.*, index = 0 }
}

// An iterator is its own iterable, so adapter chains can consume it.
pub fn iter(self: &SliceIterator($T)) SliceIterator(T) {
    return self.*
}

// Advances the iterator and returns the next element, or null if exhausted.
pub fn next(self: &SliceIterator($T)) T? {
    if self.index >= self.slice.len {
        return null
    }
    let val: T = self.slice[self.index]
    self.index = self.index + 1
    return Some(val)
}

// Reference iterator: `for x in xs.iter_ref()` yields `&T` into the slice's storage instead of a
// copy.
pub type SliceRefIterator = struct(T) {
    slice: T[]
    index: usize
}

// Iterates the elements by reference, in order: `for &x in s`.
pub fn iter_ref(slice: &$T[]) SliceRefIterator(T) {
    return .{ slice = slice.*, index = 0 }
}

// An iterator is its own iterable, so adapter chains can consume it.
pub fn iter(self: &SliceRefIterator($T)) SliceRefIterator(T) {
    return self.*
}

// Advances and returns a reference to the next element, or null at the end.
pub fn next(self: &SliceRefIterator($T)) &T? {
    if self.index >= self.slice.len {
        return null
    }
    const p: &T = self.slice.ptr + self.index
    self.index = self.index + 1
    return Some(p)
}

// Iterator over a slice's elements by value, last to first. A snapshot of the view it was made
// from: the storage is not modified while it is being iterated.
pub type SliceRevIterator = struct(T) {
    slice: T[]
    remaining: usize
}

// Iterates the elements by value, last to first: `for x in s.iter_rev()`. Copyable elements only;
// an owning element type is a compile-time error at the loop (RFC-032).
pub fn iter_rev(slice: &$T[]) SliceRevIterator(T) {
    #if !type_info(T).copyable {
        #error($"iter_rev copies each element, and {T.name} owns something", "use iter_rev_ref")
    }
    return .{ slice = slice.*, remaining = slice.len }
}

// An iterator is its own iterable, so adapter chains can consume it.
pub fn iter(self: &SliceRevIterator($T)) SliceRevIterator(T) {
    return self.*
}

// Advances toward the front and returns the next element, or null after the first.
pub fn next(self: &SliceRevIterator($T)) T? {
    if self.remaining == 0 {
        return null
    }
    self.remaining = self.remaining - 1
    let val: T = self.slice[self.remaining]
    return Some(val)
}

// Iterator over a slice's elements by reference, last to first: the reference form of
// `SliceRevIterator`, for an element type that is not copied.
pub type SliceRevRefIterator = struct(T) {
    slice: T[]
    remaining: usize
}

// Iterates the elements by reference, last to first: `for &x in s.iter_rev_ref()`.
pub fn iter_rev_ref(slice: &$T[]) SliceRevRefIterator(T) {
    return .{ slice = slice.*, remaining = slice.len }
}

// An iterator is its own iterable, so adapter chains can consume it.
pub fn iter(self: &SliceRevRefIterator($T)) SliceRevRefIterator(T) {
    return self.*
}

// Advances toward the front and returns a reference to the next element, or null after the first.
pub fn next(self: &SliceRevRefIterator($T)) &T? {
    if self.remaining == 0 {
        return null
    }
    self.remaining = self.remaining - 1
    return Some(self.slice.ptr + self.remaining)
}

// =============================================================================
// Tests
// =============================================================================

fn slice_test_is_even(x: i32) bool {
    return x % 2 == 0
}

test "first, last, find, any, all over a slice" {
    let arr = [3i32, 4i32, 5i32]
    const s = arr as i32[]
    assert_eq(s.first().unwrap(), 3, "first")
    assert_eq(s.last().unwrap(), 5, "last")
    assert_eq(s.find(slice_test_is_even).unwrap(), 4, "find")
    assert_eq(s.find_index(slice_test_is_even).unwrap(), 1 as usize, "find_index")
    assert_true(s.any(slice_test_is_even), "any")
    assert_true(!s.all(slice_test_is_even), "all")
    assert_eq(s.count_if(slice_test_is_even), 1 as usize, "count_if")
    const empty = s[0..0]
    assert_true(empty.first().is_none(), "first of empty")
    assert_true(empty.all(slice_test_is_even), "all of empty")
}

test "partition_point, lower_bound, upper_bound and binary_search over a sorted slice" {
    let arr = [1i32, 3i32, 3i32, 3i32, 8i32]
    const s = arr as i32[]
    assert_eq(s.partition_point(fn(x: i32) bool { x < 5 }), 4 as usize, "prefix below 5")
    assert_eq(s.lower_bound(3), 1 as usize, "first 3")
    assert_eq(s.upper_bound(3), 4 as usize, "past the last 3")
    assert_eq(s.upper_bound(3) - s.lower_bound(3), 3 as usize, "three copies")
    assert_eq(s.lower_bound(5), 4 as usize, "absent value: its insertion point")
    assert_eq(s.upper_bound(5), 4 as usize, "absent value: same point")
    assert_eq(s.lower_bound(0), 0 as usize, "below everything")
    assert_eq(s.lower_bound(9), 5 as usize, "above everything")
    assert_eq(s.binary_search(3).unwrap(), 1 as usize, "found, first copy")
    assert_eq(s.binary_search(8).unwrap(), 4 as usize, "found at the end")
    assert_true(s.binary_search(5).is_none(), "absent")
    const empty = s[0..0]
    assert_eq(empty.lower_bound(3), 0 as usize, "empty")
    assert_true(empty.binary_search(3).is_none(), "empty search")
}

test "min, max and the folds over a slice" {
    let arr = [3i32, 9i32, 1i32]
    const s = arr as i32[]
    assert_eq(s.min().unwrap(), 1, "min")
    assert_eq(s.max().unwrap(), 9, "max")
    assert_eq(s.min_by(fn(v: i32) i32 { 0 - v }).unwrap(), 9, "min_by negated")
    assert_eq(s.fold(0i32, fn(a: i32, b: i32) i32 { a + b }), 13, "fold")
    assert_eq(s.fold_right(10i32, fn(x: i32, acc: i32) i32 { acc - x }), 10 - 1 - 9 - 3,
        "fold_right runs from the end")
}

// =============================================================================
// Foreigns
//
// Kept last: a bare `fn` directly after a return-type-less `#foreign fn` is parsed as its return
// type (docs/known-issues.md).
// =============================================================================

// Fills `len` bytes starting at `ptr` with the byte `value`.
#foreign fn memset(ptr: &u8, value: u8, len: usize)

// Copies `len` bytes from `src` to `dst`. Handles overlapping regions safely.
#foreign fn memmove(dst: &u8, src: &u8, len: usize)

// Exchanges the `len` bytes at `a` with the `len` bytes at `b`. The regions must not overlap
// (`slice.c`).
#foreign fn memswap(a: &u8, b: &u8, len: usize)
