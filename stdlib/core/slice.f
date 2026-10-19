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

// Creates a slice from a raw pointer and length.
// The caller must ensure `ptr` points to at least `len` contiguous elements of T.
pub fn slice_from_raw_parts(ptr: &$T, len: usize) T[] {
    return .{ ptr, len }
}

// =============================================================================
// Element access
// =============================================================================

// Returns the element at `idx`, or null if `idx` is out of bounds.
pub fn get(s: $T[], idx: usize) T? where T: copyable {
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

// Returns the element at `idx`. Panics if `idx >= s.len`.
pub fn op_index(s: $T[], idx: usize) T where T: copyable {
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

// Sets the element at `index` to `value`. Panics if `index >= s.len`.
pub fn op_set_index(s: &Slice($T), index: usize, value: move T) {
    if index >= s.len {
        panic("index out of bounds")
    }
    const slot = s.ptr + index
    slot.* = move value
}

// Returns the first element, or null when empty.
pub fn first(s: $T[]) T? where T: copyable {
    if s.len == 0 {
        return null
    }
    return Some(s[0])
}

// Returns the last element, or null when empty.
pub fn last(s: $T[]) T? where T: copyable {
    if s.len == 0 {
        return null
    }
    return Some(s[s.len - 1])
}

// =============================================================================
// Search and query
//
// Predicate forms take a `fn(T) bool`; value forms compare with `==`.
// =============================================================================

// Returns true if the slice contains `value`.
pub fn contains(s: $T[], value: T) bool where T: Eq {
    for i in 0..s.len {
        if s[i] == value {
            return true
        }
    }
    return false
}

// Returns the index of the first occurrence of `value`, or null if not found.
pub fn index_of(s: $T[], value: T) usize? where T: Eq {
    for i in 0..s.len {
        if s[i] == value {
            return Some(i)
        }
    }
    return null
}

// Returns the index of the last occurrence of `value`, or null if not found.
pub fn last_index_of(s: $T[], value: T) usize? where T: Eq {
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
    for i in 0..s.len {
        if s[i] == value {
            n = n + 1
        }
    }
    return n
}

// Returns how many elements satisfy `pred`. `count` counts occurrences of a value.
pub fn count_if(s: $T[], pred: fn(T) bool) usize {
    let n: usize = 0
    for i in 0..s.len {
        if pred(s[i]) {
            n = n + 1
        }
    }
    return n
}

// Returns the first element satisfying `pred`, or null.
pub fn find(s: $T[], pred: fn(T) bool) T? where T: copyable {
    for i in 0..s.len {
        if pred(s[i]) {
            return Some(s[i])
        }
    }
    return null
}

// Returns the index of the first element satisfying `pred`, or null.
pub fn find_index(s: $T[], pred: fn(T) bool) usize? {
    for i in 0..s.len {
        if pred(s[i]) {
            return Some(i)
        }
    }
    return null
}

// Returns whether any element satisfies `pred`. False when empty.
pub fn any(s: $T[], pred: fn(T) bool) bool {
    return s.find_index(pred).is_some()
}

// Returns whether every element satisfies `pred`. True when empty.
pub fn all(s: $T[], pred: fn(T) bool) bool {
    for i in 0..s.len {
        let ok: bool = pred(s[i])
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
pub fn partition_point(s: $T[], pred: fn(T) bool) usize {
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
pub fn lower_bound(s: $T[], value: T) usize where T: Ordered {
    return s.partition_point { it < value }
}

// Returns the index of the first element greater than `value`: the last position at which `value`
// could be inserted and keep `s` sorted. `upper_bound - lower_bound` counts the copies of `value`.
//
// - `s`: must be sorted ascending.
pub fn upper_bound(s: $T[], value: T) usize where T: Ordered {
    return s.partition_point { !(value < it) }
}

// Returns the index of `value`, or null when absent; with duplicates, the first.
//
// - `s`: must be sorted ascending; the result is meaningless otherwise.
pub fn binary_search(s: $T[], value: T) usize? where T: Ordered {
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

// Returns the smallest element by `<`, or null when empty.
pub fn min(s: $T[]) T? where T: copyable {
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

// Returns the largest element by `<`, or null when empty.
pub fn max(s: $T[]) T? where T: copyable {
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

// Returns the element with the smallest `key(x)`, or null when empty. Ties keep the earliest.
pub fn min_by(s: $T[], key: fn(T) $K) T? where T: copyable, K: copyable + Ordered {
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
pub fn max_by(s: $T[], key: fn(T) $K) T? where T: copyable, K: copyable + Ordered {
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
// Traversal and folds
// =============================================================================

// Calls `f` on every element, in order. To accumulate, use `fold`, or assign a captured name.
pub fn each(s: $T[], f: fn(T)) {
    for i in 0..s.len {
        f(s[i])
    }
}

// Combines left to right: `f(f(f(init, x0), x1), x2)`.
pub fn fold(s: $T[], init: move $A, f: fn(move A, T) A) A {
    let acc = move init
    for i in 0..s.len {
        acc = f(acc, s[i])
    }
    return acc
}

// Combines right to left: `f(x0, f(x1, f(x2, init)))`. The accumulator is `f`'s second argument.
pub fn fold_right(s: $T[], init: move $A, f: fn(T, move A) A) A {
    let acc = move init
    let i = s.len
    while i > 0 {
        i = i - 1
        acc = f(s[i], acc)
    }
    return acc
}

// =============================================================================
// In-place mutation
// =============================================================================

// Exchanges the values in two slots. `&move` says the values leave their storage, so an owning `T`
// swaps with no copy and no second owner; the caller keeps both slots, each holding the other's
// value.
pub fn swap(a: &move $T, b: &move T) {
    let tmp = move a.*
    a.* = move b.*
    b.* = move tmp
}

// Puts `value` into the slot and hands back what was there. The caller names what goes in, so an
// owning type is never left holding a zeroed stand-in.
pub fn replace(slot: &move $T, value: move T) T {
    let old = move slot.*
    slot.* = move value
    return old
}

// Puts `value` into the slot and releases what was there: the assign-over-a-live-value the language
// refuses on its own (E2126), with the release the refusal is about.
pub fn install(slot: &move $T, value: move T) {
    let old = replace(slot, value)
    release(old)
}

// Fills every element of the slice with `value`.
pub fn fill(s: $T[], value: T) where T: copyable {
    for i in 0..s.len {
        const slot = s.ptr + i
        slot.* = value
    }
}

// Replaces all occurrences of `old` with `new` in-place. Returns the number of replacements made.
pub fn replace(s: $T[], old: T, new: T) usize where T: copyable {
    let n: usize = 0
    for i in 0..s.len {
        if s[i] == old {
            const slot = s.ptr + i
            slot.* = new
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
// Copy and reinterpretation
// =============================================================================

// Copies `src` into the front of `dst`. The two may overlap.
//
// Panics when `dst` is shorter than `src`.
#inline
pub fn copy_to(src: $T[], dst: T[]) where T: copyable {
    move_bytes(src, dst)
}

// Moves the elements of `src` into the front of `dst`, leaving the source slots dead. The two may
// overlap. For a non-copyable `T` the checker requires `src` to reach storage through an `owned`
// field of a type the calling module declares, written in the call (spec 3.2); for a copyable `T`
// it is `copy_to`.
//
// Panics when `dst` is shorter than `src`.
#intrinsic
#inline
pub fn move_to(src: $T[], dst: T[]) {
    move_bytes(src, dst)
}

#inline
fn move_bytes(src: $T[], dst: T[]) {
    if dst.len < src.len {
        panic("destination shorter than source")
    }
    if src.len == 0 {
        return
    }
    memmove(dst.ptr as &u8, src.ptr as &u8, src.len * size_of(T))
}

// The bytes of `s`, a view over the same memory.
pub fn as_bytes(s: $T[]) u8[] where T: copyable {
    return slice_from_raw_parts(s.ptr as &u8, s.len * size_of(T))
}

// Element-wise equality: the same length and `==` at every index.
pub fn op_eq(a: $T[], b: T[]) bool where T: Eq {
    if a.len != b.len {
        return false
    }
    for i in 0..a.len {
        if !(a[i] == b[i]) {
            return false
        }
    }
    return true
}

// Reinterprets a slice of T as a slice of U.
// Panics if the total byte size is not evenly divisible by size_of(U).
pub fn reinterpret(src: $T[]) $U[] {
    const total_bytes = src.len * size_of(T)
    const size_of_u = size_of(U)
    if total_bytes % size_of(U) != 0 {
        panic("Alignment/Size mismatch")
    }
    return .{ ptr = src.ptr as &U, len = total_bytes / size_of_u }
}

// =============================================================================
// Iteration
// =============================================================================

// Iterator state for slices. Created by `iter(&slice)`. Stores a copy of the slice and tracks the
// current position.
pub type SliceIterator = struct(T) {
    slice: T[]
    index: usize
}

// Creates an iterator over the elements of a slice.
pub fn iter(slice: &$T[]) SliceIterator(T) {
    return .{ slice = slice.*, index = 0 }
}

// An iterator is its own iterable, so adapter chains can consume it.
pub fn iter(it: &SliceIterator($T)) SliceIterator(T) {
    return it.*
}

// Advances the iterator and returns the next element, or null if exhausted.
pub fn next(iter: &SliceIterator($T)) T? where T: copyable {
    if iter.index >= iter.slice.len {
        return null
    }
    let val: T = iter.slice[iter.index]
    iter.index = iter.index + 1
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
pub fn iter(it: &SliceRefIterator($T)) SliceRefIterator(T) {
    return it.*
}

// Advances and returns a reference to the next element, or null at the end.
pub fn next(iter: &SliceRefIterator($T)) &T? {
    if iter.index >= iter.slice.len {
        return null
    }
    const p: &T = iter.slice.ptr + iter.index
    iter.index = iter.index + 1
    return Some(p)
}

// Iterator over a slice's elements by value, last to first. A snapshot of the view it was made
// from: the storage is not modified while it is being iterated.
pub type SliceRevIterator = struct(T) {
    slice: T[]
    remaining: usize
}

// Iterates the elements by value, last to first: `for x in s.iter_rev()`.
pub fn iter_rev(slice: &$T[]) SliceRevIterator(T) {
    return .{ slice = slice.*, remaining = slice.len }
}

// An iterator is its own iterable, so adapter chains can consume it.
pub fn iter(it: &SliceRevIterator($T)) SliceRevIterator(T) {
    return it.*
}

// Advances toward the front and returns the next element, or null after the first.
pub fn next(iter: &SliceRevIterator($T)) T? where T: copyable {
    if iter.remaining == 0 {
        return null
    }
    iter.remaining = iter.remaining - 1
    let val: T = iter.slice[iter.remaining]
    return Some(val)
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
    assert_eq(s.partition_point { it < 5 }, 4 as usize, "prefix below 5")
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
    assert_eq(s.min_by { 0 - it }.unwrap(), 9, "min_by negated")
    assert_eq(s.fold(0i32) { a, b => a + b }, 13, "fold")
    assert_eq(
        s.fold_right(10i32) { x, acc => acc - x },
        10 - 1 - 9 - 3,
        "fold_right runs from the end",
    )
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
