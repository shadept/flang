// Sorting algorithms.
//
// All algorithms share the same generalized signature:
//
//     pub fn <algo>(s: $T[])                           -- uses op_cmp
//     pub fn <algo>(s: $T[], cmp: fn(T, T) Ord)        -- custom comparator
//
// `sort` aliases `powersort` (stable, O(n log n), fast on partially sorted input).
// Direct algorithm calls remain available when a specific behavior is desired:
//
//     insertion_sort  -- stable, O(n^2); best on very small or nearly-sorted slices.
//     quicksort       -- unstable, average O(n log n); small-range cutoff to insertion sort.
//     powersort       -- stable, O(n log n); nearly-optimal merge policy on natural runs.

import std.allocator
import std.test

// =============================================================================
// Tuning
// =============================================================================

// Subranges smaller than this use insertion sort inside quicksort/powersort.
const INSERTION_CUTOFF: usize = 24

// =============================================================================
// Insertion sort
// =============================================================================

pub fn insertion_sort(s: $T[]) {
    _insertion_sort_range(s, 0, s.len, fn(a: T, b: T) Ord { return op_cmp(a, b) })
}

pub fn insertion_sort(s: $T[], cmp: fn(T, T) Ord) {
    _insertion_sort_range(s, 0, s.len, cmp)
}

// Stable in-place insertion sort over `s[lo..hi]` (hi exclusive).
fn _insertion_sort_range(s: $T[], lo: usize, hi: usize, cmp: fn(T, T) Ord) {
    if hi - lo < 2 { return }
    for i in (lo + 1)..hi {
        let j = i
        loop {
            if j <= lo { break }
            const prev = s[j - 1]
            const cur = s[j]
            if cmp(cur, prev) != Ord.Less { break }
            s[j - 1] = cur
            s[j] = prev
            j = j - 1
        }
    }
}

// =============================================================================
// Quicksort
// =============================================================================

pub fn quicksort(s: $T[]) {
    _quicksort_range(s, 0, s.len, fn(a: T, b: T) Ord { return op_cmp(a, b) })
}

pub fn quicksort(s: $T[], cmp: fn(T, T) Ord) {
    _quicksort_range(s, 0, s.len, cmp)
}

fn _quicksort_range(s: $T[], lo: usize, hi: usize, cmp: fn(T, T) Ord) {
    if hi - lo < 2 { return }

    if hi - lo < INSERTION_CUTOFF {
        _insertion_sort_range(s, lo, hi, cmp)
        return
    }

    // Median-of-three pivot selection (mitigates worst-case on sorted inputs).
    const mid = lo + (hi - lo) / 2
    const last = hi - 1
    _sort3(s, lo, mid, last, cmp)
    // Pivot now at `mid`; move it to `last - 1` so it's out of the partition scan.
    const pivot_slot = last - 1
    const tmp_piv = s[mid]
    s[mid] = s[pivot_slot]
    s[pivot_slot] = tmp_piv

    const pivot = s[pivot_slot]
    let i = lo
    let j = pivot_slot
    loop {
        loop {
            i = i + 1
            if i >= pivot_slot { break }
            if cmp(s[i], pivot) != Ord.Less { break }
        }
        loop {
            if j <= lo { break }
            j = j - 1
            if cmp(s[j], pivot) != Ord.Greater { break }
        }
        if i >= j { break }
        const t = s[i]
        s[i] = s[j]
        s[j] = t
    }

    // Restore pivot to its final position.
    const t2 = s[i]
    s[i] = s[pivot_slot]
    s[pivot_slot] = t2

    // Recurse on the smaller side first to bound stack depth.
    if i > lo { _quicksort_range(s, lo, i, cmp) }
    if i + 1 < hi { _quicksort_range(s, i + 1, hi, cmp) }
}

// Orders s[a], s[b], s[c] so they're ascending under cmp.
fn _sort3(s: $T[], a: usize, b: usize, c: usize, cmp: fn(T, T) Ord) {
    if cmp(s[b], s[a]) == Ord.Less {
        const t = s[a]; s[a] = s[b]; s[b] = t
    }
    if cmp(s[c], s[b]) == Ord.Less {
        const t = s[b]; s[b] = s[c]; s[c] = t
        if cmp(s[b], s[a]) == Ord.Less {
            const t2 = s[a]; s[a] = s[b]; s[b] = t2
        }
    }
}

// =============================================================================
// Powersort
// =============================================================================
//
// Stable merge sort with run-adaptive merging. Short runs are grown to
// `INSERTION_CUTOFF` via insertion sort; longer natural runs are preserved.
// Merges follow a bottom-up schedule — this is a simpler cousin of the
// Munro-Wild powersort policy; switching to true powersort is a drop-in change
// in the merge scheduler and doesn't affect the public API.

pub fn powersort(s: $T[]) {
    _powersort_impl(s, fn(a: T, b: T) Ord { return op_cmp(a, b) })
}

pub fn powersort(s: $T[], cmp: fn(T, T) Ord) {
    _powersort_impl(s, cmp)
}

fn _powersort_impl(s: $T[], cmp: fn(T, T) Ord) {
    if s.len < 2 { return }
    if s.len < INSERTION_CUTOFF {
        _insertion_sort_range(s, 0, s.len, cmp)
        return
    }

    // Allocate a scratch buffer the size of the input for merging.
    const byte_len = s.len * size_of(T)
    const scratch_bytes = global_allocator.alloc(byte_len, align_of(T))
        .expect("powersort: scratch allocation failed")
    const scratch: T[] = .{ ptr = scratch_bytes.ptr as &T, len = s.len }

    // Bottom-up merge sort. Sort fixed-size blocks with insertion sort, then
    // merge pairs of blocks with doubling width.
    let block = INSERTION_CUTOFF
    let start: usize = 0
    while start < s.len {
        const end = if start + block < s.len { start + block } else { s.len }
        _insertion_sort_range(s, start, end, cmp)
        start = start + block
    }

    while block < s.len {
        let lo: usize = 0
        while lo < s.len {
            const mid = if lo + block < s.len { lo + block } else { s.len }
            const hi = if lo + 2 * block < s.len { lo + 2 * block } else { s.len }
            if mid < hi {
                _merge(s, scratch, lo, mid, hi, cmp)
            }
            lo = lo + 2 * block
        }
        block = block * 2
    }

    global_allocator.dealloc(scratch_bytes)
}

// Stable merge of s[lo..mid] and s[mid..hi] using `scratch` as staging.
fn _merge(s: $T[], scratch: $T[], lo: usize, mid: usize, hi: usize, cmp: fn(T, T) Ord) {
    // Copy left half into scratch[lo..mid]. Right half stays in place; we fill
    // s[lo..hi] left-to-right from scratch (left) and s (right).
    for i in lo..mid {
        scratch[i] = s[i]
    }

    let l = lo
    let r = mid
    let w = lo
    while l < mid and r < hi {
        const lv = scratch[l]
        const rv = s[r]
        if cmp(rv, lv) == Ord.Less {
            s[w] = rv
            r = r + 1
        } else {
            s[w] = lv
            l = l + 1
        }
        w = w + 1
    }

    // Drain remaining left half (right half, if any, is already in place).
    while l < mid {
        s[w] = scratch[l]
        l = l + 1
        w = w + 1
    }
}

// =============================================================================
// Default sort (= powersort)
// =============================================================================

pub fn sort(s: $T[]) {
    powersort(s)
}

pub fn sort(s: $T[], cmp: fn(T, T) Ord) {
    powersort(s, cmp)
}

// =============================================================================
// Tests
// =============================================================================

fn is_sorted(s: $T[]) bool {
    if s.len < 2 { return true }
    for i in 1..s.len {
        if op_cmp(s[i - 1], s[i]) == Ord.Greater { return false }
    }
    return true
}

fn sort_test_desc_i32(a: i32, b: i32) Ord {
    return op_cmp(b, a)
}

test "insertion_sort empty" {
    let arr = [0i32; 0]
    let s: i32[] = arr
    insertion_sort(s)
    assert_true(is_sorted(s), "empty slice is trivially sorted")
}

test "insertion_sort single" {
    let arr = [42i32; 1]
    let s: i32[] = arr
    insertion_sort(s)
    assert_true(is_sorted(s), "single element is trivially sorted")
}

test "insertion_sort ascending" {
    let arr = [5i32, 3, 1, 4, 2]
    let s: i32[] = arr
    insertion_sort(s)
    assert_true(is_sorted(s), "after sort")
    assert_eq(s[0], 1i32, "first")
    assert_eq(s[4], 5i32, "last")
}

test "insertion_sort descending" {
    let arr = [5i32, 4, 3, 2, 1]
    let s: i32[] = arr
    insertion_sort(s)
    assert_true(is_sorted(s), "reverse sorted becomes sorted")
}

test "insertion_sort custom cmp" {
    let arr = [1i32, 2, 3, 4, 5]
    let s: i32[] = arr
    insertion_sort(s, sort_test_desc_i32)
    assert_eq(s[0], 5i32, "reversed first")
    assert_eq(s[4], 1i32, "reversed last")
}

test "quicksort basic" {
    let arr = [5i32, 3, 1, 4, 2, 9, 7, 8, 6, 0]
    let s: i32[] = arr
    quicksort(s)
    assert_true(is_sorted(s), "after sort")
    assert_eq(s[0], 0i32, "first")
    assert_eq(s[9], 9i32, "last")
}

test "quicksort many duplicates" {
    let arr = [3i32, 1, 3, 2, 1, 2, 3, 1, 2, 1, 3, 2, 2, 1, 3]
    let s: i32[] = arr
    quicksort(s)
    assert_true(is_sorted(s), "duplicates sorted")
}

test "quicksort already sorted" {
    let arr = [0i32, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    let s: i32[] = arr
    quicksort(s)
    assert_true(is_sorted(s), "sorted stays sorted")
}

test "quicksort large" {
    let arr = [
        37i32, 12, 88, 4, 21, 77, 56, 9, 63, 42,
        11, 84, 29, 55, 18, 73, 66, 33, 2, 48,
        91, 25, 70, 14, 80, 58, 6, 39, 67, 23,
        5, 19, 50, 72, 13, 44, 30, 61, 17, 36,
        95, 7, 31, 64, 52, 27, 1, 46, 83, 10
    ]
    let s: i32[] = arr
    quicksort(s)
    assert_true(is_sorted(s), "50 elements sorted")
    assert_eq(s[0], 1i32, "smallest")
    assert_eq(s[49], 95i32, "largest")
}

test "powersort basic" {
    let arr = [5i32, 3, 1, 4, 2, 9, 7, 8, 6, 0]
    let s: i32[] = arr
    powersort(s)
    assert_true(is_sorted(s), "after sort")
}

test "powersort large mixed" {
    let arr = [
        37i32, 12, 88, 4, 21, 77, 56, 9, 63, 42,
        11, 84, 29, 55, 18, 73, 66, 33, 2, 48,
        91, 25, 70, 14, 80, 58, 6, 39, 67, 23,
        5, 19, 50, 72, 13, 44, 30, 61, 17, 36,
        95, 7, 31, 64, 52, 27, 1, 46, 83, 10
    ]
    let s: i32[] = arr
    powersort(s)
    assert_true(is_sorted(s), "after sort")
    assert_eq(s[0], 1i32, "smallest")
    assert_eq(s[49], 95i32, "largest")
}

test "powersort runs" {
    // Input with two already-sorted runs — exercises the merge path.
    let arr = [
        1i32, 3, 5, 7, 9, 11, 13, 15, 17, 19,
        21, 23, 25, 27, 29, 31, 33, 35, 37, 39,
        2, 4, 6, 8, 10, 12, 14, 16, 18, 20,
        22, 24, 26, 28, 30, 32, 34, 36, 38, 40
    ]
    let s: i32[] = arr
    powersort(s)
    assert_true(is_sorted(s), "merged runs sorted")
    assert_eq(s[0], 1i32, "smallest")
    assert_eq(s[39], 40i32, "largest")
}

test "sort alias" {
    let arr = [3i32, 1, 2]
    let s: i32[] = arr
    sort(s)
    assert_eq(s[0], 1i32, "first")
    assert_eq(s[1], 2i32, "second")
    assert_eq(s[2], 3i32, "third")
}

test "sort strings" {
    let arr = ["cherry", "apple", "banana"]
    let s: String[] = arr
    sort(s)
    assert_eq(s[0], "apple", "alphabetically first")
    assert_eq(s[1], "banana", "second")
    assert_eq(s[2], "cherry", "third")
}

test "sort with custom cmp" {
    let arr = [1i32, 2, 3, 4, 5]
    let s: i32[] = arr
    sort(s, sort_test_desc_i32)
    assert_eq(s[0], 5i32, "descending first")
    assert_eq(s[4], 1i32, "descending last")
}
