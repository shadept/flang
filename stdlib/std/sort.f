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
//     powersort       -- stable, O(n log n); near-optimal merge policy on natural runs.

import std.allocator
import std.test

// =============================================================================
// Tuning
// =============================================================================

// Subranges smaller than this use insertion sort inside quicksort/powersort.
// Also used as the minimum run length in powersort.
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
// Uses shifts rather than swaps: one write per displaced element instead of
// three — materially faster for any T larger than a register.
fn _insertion_sort_range(s: $T[], lo: usize, hi: usize, cmp: fn(T, T) Ord) {
    if hi - lo < 2 { return }
    for i in (lo + 1)..hi {
        const cur = s[i]
        let j = i
        while j > lo and cmp(cur, s[j - 1]) == Ord.Less {
            s[j] = s[j - 1]
            j = j - 1
        }
        s[j] = cur
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

// Iterative on the larger side, recursive on the smaller — keeps stack depth
// bounded to O(log n) even on adversarial inputs.
fn _quicksort_range(s: $T[], lo: usize, hi: usize, cmp: fn(T, T) Ord) {
    let l = lo
    let h = hi
    while h - l >= INSERTION_CUTOFF {
        const p = _partition(s, l, h, cmp)
        const left_len = p - l
        const right_len = h - p - 1
        if left_len < right_len {
            if left_len > 0 { _quicksort_range(s, l, p, cmp) }
            l = p + 1
        } else {
            if right_len > 0 { _quicksort_range(s, p + 1, h, cmp) }
            h = p
        }
    }
    _insertion_sort_range(s, l, h, cmp)
}

// Hoare-style partition with median-of-three pivot selection. After the call,
// the pivot sits at the returned index, everything to its left is `<= pivot`,
// and everything to its right is `>= pivot`.
//
// Median-of-three leaves sentinels in place: s[lo] <= pivot and s[hi-1] >= pivot,
// plus pivot itself at `pivot_slot`. These let the inner scans run without
// explicit bounds checks.
fn _partition(s: $T[], lo: usize, hi: usize, cmp: fn(T, T) Ord) usize {
    const mid = lo + (hi - lo) / 2
    const last = hi - 1
    _sort3(s, lo, mid, last, cmp)

    // Park the pivot at `last - 1` so the right scan's sentinel (s[last] >= pivot)
    // sits just past the partition window.
    const pivot_slot = last - 1
    swap(&s[mid], &s[pivot_slot])
    const pivot = s[pivot_slot]

    let i = lo
    let j = pivot_slot
    loop {
        // Scan up from the left past elements strictly less than pivot.
        // Stops at pivot_slot at the latest (s[pivot_slot] == pivot).
        i = i + 1
        while cmp(s[i], pivot) == Ord.Less { i = i + 1 }
        // Scan down from the right past elements strictly greater than pivot.
        // Stops at `lo` at the latest (s[lo] <= pivot from median-of-three).
        j = j - 1
        while cmp(s[j], pivot) == Ord.Greater { j = j - 1 }
        if i >= j { break }
        swap(&s[i], &s[j])
    }

    // Put the pivot into its final position.
    swap(&s[i], &s[pivot_slot])
    return i
}

// Sorts s[a], s[b], s[c] in ascending order under cmp.
// Three comparisons, up to three swaps — classical 3-element insertion sort.
fn _sort3(s: $T[], a: usize, b: usize, c: usize, cmp: fn(T, T) Ord) {
    if cmp(s[b], s[a]) == Ord.Less { swap(&s[a], &s[b]) }
    if cmp(s[c], s[b]) == Ord.Less { swap(&s[b], &s[c]) }
    if cmp(s[b], s[a]) == Ord.Less { swap(&s[a], &s[b]) }
}

// =============================================================================
// Powersort
// =============================================================================
//
// Munro-Wild powersort (2018). Stable, O(n log n) worst case, O(n) on already
// sorted input. Scans the input once to identify natural runs (ascending runs
// are kept, strictly descending runs are reversed — strict to preserve
// stability). Short runs are extended to INSERTION_CUTOFF with insertion sort.
//
// Runs are kept on a stack. Each run carries a "power" — the depth in an
// idealised balanced merge tree where the boundary between this run and the
// previous one would live. When a new run arrives with power P, we merge off
// any stack entries whose power is strictly greater than P before pushing.
// This produces the same merge schedule a perfectly balanced merge sort would,
// in a single pass, without ever materialising the run list up front.
//
// Reference: Munro & Wild, "Nearly-Optimal Mergesorts: Fast, Practical
// Sorting Methods That Optimally Adapt to Existing Runs" (ESA 2018).

pub fn powersort(s: $T[]) {
    _powersort_impl(s, fn(a: T, b: T) Ord { return op_cmp(a, b) })
}

pub fn powersort(s: $T[], cmp: fn(T, T) Ord) {
    _powersort_impl(s, cmp)
}

fn _powersort_impl(s: $T[], cmp: fn(T, T) Ord) {
    const n = s.len
    if n < 2 { return }
    if n < INSERTION_CUTOFF {
        _insertion_sort_range(s, 0, n, cmp)
        return
    }

    const byte_len = n * size_of(T)
    const scratch_bytes = global_allocator.alloc(byte_len, align_of(T))
        .expect("powersort: scratch allocation failed")
    const scratch: T[] = .{ ptr = scratch_bytes.ptr as &T, len = n }
    defer global_allocator.dealloc(scratch_bytes)

    // Run stack. Bounded by the number of distinct powers, which for any
    // practical n fits in ~40 slots. 64 covers n up to ~2^64.
    let stack_start: [usize; 64] = [0; 64]
    let stack_power: [u32; 64] = [0; 64]
    let top: usize = 0

    // Establish the first run.
    let run_start: usize = 0
    let run_end = _next_run(s, 0, n, cmp)

    while run_end < n {
        const next_start = run_end
        const next_end = _next_run(s, next_start, n, cmp)

        // Power of the boundary between the current run and the next one.
        const p = _node_power(n, run_start, next_start, next_end)

        // Drain any pending runs whose own boundary power exceeds p — those
        // boundaries live deeper in the merge tree than this one and must
        // resolve first.
        while top >= 1 and stack_power[top - 1] > p {
            const merge_lo = stack_start[top - 1]
            _merge(s, scratch, merge_lo, run_start, run_end, cmp)
            run_start = merge_lo
            top = top - 1
        }

        // Push the (now possibly grown) current run, tagged with p.
        stack_start[top] = run_start
        stack_power[top] = p
        top = top + 1

        run_start = next_start
        run_end = next_end
    }

    // Final pass: collapse the stack into the active run.
    while top > 0 {
        top = top - 1
        const merge_lo = stack_start[top]
        _merge(s, scratch, merge_lo, run_start, n, cmp)
        run_start = merge_lo
    }
}

// Detect the next natural run starting at `lo`. Ascending runs (non-strict,
// to preserve stability on equal keys) are kept; strictly descending runs are
// reversed. Short runs are padded up to INSERTION_CUTOFF with insertion sort.
// Returns the exclusive end index of the finalised run.
fn _next_run(s: $T[], lo: usize, hi: usize, cmp: fn(T, T) Ord) usize {
    if hi - lo <= 1 { return hi }
    let end = lo + 1
    if cmp(s[end], s[lo]) == Ord.Less {
        // Strictly descending — scan, then reverse in place.
        while end < hi and cmp(s[end], s[end - 1]) == Ord.Less { end = end + 1 }
        _reverse_range(s, lo, end)
    } else {
        // Non-descending.
        while end < hi and cmp(s[end], s[end - 1]) != Ord.Greater { end = end + 1 }
    }
    // Force every run to at least INSERTION_CUTOFF elements. The existing run
    // is already sorted, so insertion sort just folds in the tail efficiently.
    if end - lo < INSERTION_CUTOFF {
        const new_end = if lo + INSERTION_CUTOFF < hi { lo + INSERTION_CUTOFF } else { hi }
        _insertion_sort_range(s, lo, new_end, cmp)
        return new_end
    }
    return end
}

fn _reverse_range(s: $T[], lo: usize, hi: usize) {
    if hi - lo < 2 { return }
    let l = lo
    let h = hi - 1
    while l < h {
        swap(&s[l], &s[h])
        l = l + 1
        h = h - 1
    }
}

// Power of the merge node straddling the boundary between runs
// A = s[start_a..start_b] and B = s[start_b..end_b] within a total array
// length of n. Higher power = deeper in the balanced merge tree = merge later.
//
// The canonical formulation: let m_A = midpoint(A)/n and m_B = midpoint(B)/n,
// both in [0, 1). The power is the index of the first binary digit where
// m_A and m_B differ. We compute this via long division without ever
// materialising a floating-point value — a/n and b/n are compared bit by bit.
fn _node_power(n: usize, start_a: usize, start_b: usize, end_b: usize) u32 {
    // `a` and `b` hold twice the midpoint of each run; doubling avoids a
    // rounding error from dividing run lengths by 2 before the shift.
    let a = start_a + start_b
    let b = start_b + end_b
    let result: u32 = 0
    loop {
        result = result + 1
        if a >= n {
            // Current high bit of a/n is 1. Both values carry it (a <= b), so
            // subtract to keep the comparison in-range.
            a = a - n
            b = b - n
        } else if b >= n {
            // a/n's high bit is 0, b/n's is 1: first differing bit found.
            break
        }
        a = a * 2
        b = b * 2
    }
    return result
}

// Stable merge of s[lo..mid] and s[mid..hi] using `scratch` as staging.
fn _merge(s: $T[], scratch: $T[], lo: usize, mid: usize, hi: usize, cmp: fn(T, T) Ord) {
    if lo >= mid or mid >= hi { return }

    // Copy the left half into scratch and stream results back into s. The right
    // half stays put — we only race to overwrite it once its elements have been
    // consumed, and that pointer (r) never lags behind the write head (w).
    for i in lo..mid { scratch[i] = s[i] }

    let l = lo
    let r = mid
    let w = lo
    while l < mid and r < hi {
        const lv = scratch[l]
        const rv = s[r]
        // `!= Less` (i.e. left <= right) keeps the merge stable: equal keys
        // from the left half always go first.
        if cmp(rv, lv) == Ord.Less {
            s[w] = rv
            r = r + 1
        } else {
            s[w] = lv
            l = l + 1
        }
        w = w + 1
    }

    // Drain any leftover left half. A leftover right half is already in place.
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

test "powersort two ascending runs" {
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

test "powersort descending run reversal" {
    // A long strictly-descending prefix exercises the reverse path.
    let arr = [
        50i32, 49, 48, 47, 46, 45, 44, 43, 42, 41,
        40, 39, 38, 37, 36, 35, 34, 33, 32, 31,
        30, 29, 28, 27, 26, 25, 24, 23, 22, 21,
        20, 19, 18, 17, 16, 15, 14, 13, 12, 11,
        10, 9, 8, 7, 6, 5, 4, 3, 2, 1
    ]
    let s: i32[] = arr
    powersort(s)
    assert_true(is_sorted(s), "descending becomes ascending")
    assert_eq(s[0], 1i32, "smallest")
    assert_eq(s[49], 50i32, "largest")
}

test "powersort many runs" {
    // Alternating pattern creates many short runs — exercises the run-stack
    // merge scheduling.
    let arr = [
        10i32, 20, 5, 15, 25, 1, 11, 21, 31, 3,
        13, 23, 33, 43, 7, 17, 27, 37, 47, 2,
        12, 22, 32, 42, 52, 4, 14, 24, 34, 44,
        54, 64, 6, 16, 26, 36, 46, 56, 8, 18,
        28, 38, 48, 58, 68, 9, 19, 29, 39, 49
    ]
    let s: i32[] = arr
    powersort(s)
    assert_true(is_sorted(s), "many-run input sorted")
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
