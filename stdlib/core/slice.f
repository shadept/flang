// Slice types, operations, and iterator implementation.
//
// Slices are fat-pointer views into contiguous memory: `struct { ptr: &T, len: usize }`.
// They do NOT own the underlying data. Use `T[]` syntax as shorthand for `Slice(T)`.
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

// A view into a contiguous sequence of elements of type T.
// A Slice does not own ptr.
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
// Indexing
// =============================================================================

// Returns the element at `idx`, or null if `idx` is out of bounds.
pub fn get(s: $T[], idx: usize) T? {
    if idx >= s.len {
        return null
    }
    const ptr = s.ptr + idx
    return ptr.*
}

// Returns the element at `idx`. Panics if `idx >= s.len`.
pub fn op_index(s: $T[], idx: usize) T {
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
    if start > s.len { start = s.len }
    if end > s.len { end = s.len }
    if start > end { end = start }

    return .{
        ptr = s.ptr + start,
        len = end - start
    }
}

// Sets the element at `index` to `value`. Panics if `index >= s.len`.
pub fn op_set_index(s: &Slice($T), index: usize, value: T) {
    if index >= s.len {
        panic("index out of bounds")
    }
    const slot = s.ptr + index
    slot.* = value
}

// =============================================================================
// Search
// =============================================================================

// Returns true if the slice contains `value`.
pub fn contains(s: $T[], value: T) bool {
    for i in 0..s.len {
        if s[i] == value {
            return true
        }
    }
    return false
}

// Returns the index of the first occurrence of `value`, or null if not found.
pub fn index_of(s: $T[], value: T) usize? {
    for i in 0..s.len {
        if s[i] == value {
            return i
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
            return i
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

// Searches a sorted slice for `value` using binary search.
// Returns the index if found, or null if not present.
// The slice MUST be sorted in ascending order; results are undefined otherwise.
pub fn binary_search(s: $T[], value: T) usize? {
    let lo: usize = 0
    let hi: usize = s.len
    for _i in 0..s.len {
        if lo >= hi {
            return null
        }
        const mid = lo + (hi - lo) / 2
        const elem = s[mid]
        if elem == value {
            return mid
        }
        if elem < value {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return null
}

// =============================================================================
// Comparison
// =============================================================================

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

// =============================================================================
// Mutation
// =============================================================================

// Swaps the values at two mutable references.
pub fn swap(a: &$T, b: &T) {
    let tmp = a.*
    a.* = b.*
    b.* = tmp
}

// Fills every element of the slice with `value`.
pub fn fill(s: $T[], value: T) {
    for i in 0..s.len {
        const slot = s.ptr + i
        slot.* = value
    }
}

// Replaces all occurrences of `old` with `new` in-place.
// Returns the number of replacements made.
pub fn replace(s: $T[], old: T, new: T) usize {
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

// Sorts the slice in ascending order using quicksort.
// Requires that `<` and `<=` are defined for T.
pub fn sort(s: $T[]) {
    if s.len <= 1 {
        return
    }
    _quicksort(s, 0, s.len - 1)
}

fn _quicksort(s: $T[], lo: usize, hi: usize) {
    if lo >= hi {
        return
    }
    let pivot = s[hi]
    let i = lo
    for j in lo..hi {
        if s[j] <= pivot {
            swap(&s[i], &s[j])
            i = i + 1
        }
    }
    swap(&s[i], &s[hi])

    if i > lo {
        _quicksort(s, lo, i - 1)
    }
    _quicksort(s, i + 1, hi)
}

// =============================================================================
// Copy
// =============================================================================

// Copies elements from `src` into `dest`.
// Copies min(src.len, dest.len) elements and returns the number copied.
pub fn copy_to(src: $T[], dest: T[]) usize {
    const len = if src.len < dest.len { src.len } else { dest.len }
    memmove(dest.ptr, src.ptr, len * size_of(T))
    return len
}

// Reinterprets a slice of T as a slice of U.
// Panics if the total byte size is not evenly divisible by size_of(U).
pub fn reinterpret(src: $T[]) $U[] {
    const total_bytes = src.len * size_of(T)
    const size_of_u = size_of(U)
    if total_bytes % size_of(U) {
        panic("Alignment/Size mismatch")
    }
    return .{ ptr=src.ptr as &U, len=total_bytes / size_of_u }
}

// =============================================================================
// Slice Iterator
// =============================================================================

// Iterator state for slices. Created by `iter(&slice)`.
// Stores a copy of the slice and tracks the current position.
pub type SliceIterator = struct(T) {
    slice: T[]
    index: usize
}

// Creates an iterator over the elements of a slice.
pub fn iter(slice: &$T[]) SliceIterator(T) {
    return .{ slice = slice.*, index = 0}
}

// Advances the iterator and returns the next element, or null if exhausted.
pub fn next(iter: &SliceIterator($T)) T? {
    if iter.index >= iter.slice.len {
        return null
    }
    let val: T = iter.slice[iter.index]
    iter.index = iter.index + 1
    return val
}

// =============================================================================
// Foreigns
// =============================================================================

// Fills `len` bytes starting at `ptr` with the byte `value`.
#foreign fn memset(ptr: &u8, value: u8, len: usize)

// Copies `len` bytes from `src` to `dst`. Handles overlapping regions safely.
#foreign fn memmove(dst: &u8, src: &u8, len: usize)

// =============================================================================
// Tests
// =============================================================================

// test "contains" {
//     let arr = [1i32, 2, 3, 4, 5]
//     let s: i32[] = arr
//     assert_true(s.contains(3), "should contain 3")
//     assert_true(!s.contains(6), "should not contain 6")
// }

// test "index_of" {
//     let arr = [10i32, 20, 30, 20, 40]
//     let s: i32[] = arr
//     let idx = s.index_of(30)
//     assert_true(idx != null, "should find 30")
//     assert_eq(idx.value, 2 as usize, "index of 30 should be 2")
//     assert_true(s.index_of(99) == null, "should not find 99")
// }

// test "last_index_of" {
//     let arr = [10i32, 20, 30, 20, 40]
//     let s: i32[] = arr
//     let idx = s.last_index_of(20)
//     assert_true(idx != null, "should find 20")
//     assert_eq(idx.value, 3 as usize, "last index of 20 should be 3")
// }

// test "count" {
//     let arr = [1i32, 2, 1, 3, 1]
//     let s: i32[] = arr
//     assert_eq(s.count(1), 3 as usize, "count of 1 should be 3")
//     assert_eq(s.count(9), 0 as usize, "count of 9 should be 0")
// }

// test "starts_with" {
//     let arr = [1i32, 2, 3, 4, 5]
//     let s: i32[] = arr
//     let prefix = [1i32, 2, 3]
//     assert_true(s.starts_with(prefix), "should start with [1,2,3]")
//     let bad = [1i32, 3]
//     assert_true(!s.starts_with(bad), "should not start with [1,3]")
// }

// test "ends_with" {
//     let arr = [1i32, 2, 3, 4, 5]
//     let s: i32[] = arr
//     let suffix = [3i32, 4, 5]
//     assert_true(s.ends_with(suffix), "should end with [3,4,5]")
//     let bad = [4i32, 3]
//     assert_true(!s.ends_with(bad), "should not end with [4,3]")
// }

// test "fill" {
//     let arr = [0i32, 0, 0, 0]
//     let s: i32[] = arr
//     s.fill(42)
//     assert_eq(s[0], 42, "s[0] should be 42")
//     assert_eq(s[3], 42, "s[3] should be 42")
// }

// test "replace" {
//     let arr = [1i32, 2, 1, 3, 1]
//     let s: i32[] = arr
//     let n = s.replace(1, 9)
//     assert_eq(n, 3 as usize, "should replace 3 times")
//     assert_eq(s[0], 9, "s[0] should be 9")
//     assert_eq(s[1], 2, "s[1] should still be 2")
// }

// test "reverse" {
//     let arr = [1i32, 2, 3, 4, 5]
//     let s: i32[] = arr
//     s.reverse()
//     assert_eq(s[0], 5, "s[0] should be 5")
//     assert_eq(s[4], 1, "s[4] should be 1")
// }

// test "sort" {
//     let arr = [5i32, 3, 1, 4, 2]
//     let s: i32[] = arr
//     s.sort()
//     assert_eq(s[0], 1, "s[0] should be 1")
//     assert_eq(s[1], 2, "s[1] should be 2")
//     assert_eq(s[4], 5, "s[4] should be 5")
// }

// test "binary_search" {
//     let arr = [1i32, 2, 3, 4, 5]
//     let s: i32[] = arr
//     let idx = s.binary_search(3)
//     assert_true(idx != null, "should find 3")
//     assert_eq(idx.value, 2 as usize, "binary_search(3) should be 2")
//     assert_true(s.binary_search(6) == null, "should not find 6")
// }

// test "swap" {
//     let a: i32 = 10
//     let b: i32 = 20
//     swap(&a, &b)
//     assert_eq(a, 20, "a should be 20")
//     assert_eq(b, 10, "b should be 10")
// }
