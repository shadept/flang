//! TEST: sort_basic
//! EXIT: 0

import std.list
import std.sort

fn is_sorted(s: i32[]) bool {
    if s.len < 2 { return true }
    for i in 1..s.len {
        if s[i - 1] > s[i] { return false }
    }
    return true
}

fn desc_i32(a: i32, b: i32) Ord {
    return op_cmp(b, a)
}

pub fn main() i32 {
    // insertion sort
    let arr1 = [5i32, 3, 1, 4, 2]
    let s1: i32[] = arr1
    insertion_sort(s1)
    if !is_sorted(s1) { return 1 }

    // quicksort
    let arr2 = [
        37i32, 12, 88, 4, 21, 77, 56, 9, 63, 42,
        11, 84, 29, 55, 18, 73, 66, 33, 2, 48,
        91, 25, 70, 14, 80, 58, 6, 39, 67, 23,
        5, 19, 50, 72, 13, 44, 30, 61, 17, 36,
        95, 7, 31, 64, 52, 27, 1, 46, 83, 10
    ]
    let s2: i32[] = arr2
    quicksort(s2)
    if !is_sorted(s2) { return 2 }
    if s2[0] != 1 { return 3 }
    if s2[49] != 95 { return 4 }

    // powersort
    let arr3 = [
        37i32, 12, 88, 4, 21, 77, 56, 9, 63, 42,
        11, 84, 29, 55, 18, 73, 66, 33, 2, 48,
        91, 25, 70, 14, 80, 58, 6, 39, 67, 23,
        5, 19, 50, 72, 13, 44, 30, 61, 17, 36,
        95, 7, 31, 64, 52, 27, 1, 46, 83, 10
    ]
    let s3: i32[] = arr3
    powersort(s3)
    if !is_sorted(s3) { return 5 }

    // default sort alias
    let arr4 = [3i32, 1, 2]
    let s4: i32[] = arr4
    sort(s4)
    if s4[0] != 1 { return 6 }
    if s4[2] != 3 { return 7 }

    // custom comparator
    let arr5 = [1i32, 2, 3, 4, 5]
    let s5: i32[] = arr5
    sort(s5, desc_i32)
    if s5[0] != 5 { return 8 }
    if s5[4] != 1 { return 9 }

    // List.sort via UFCS
    let lst = list(10)
    lst.push(3i32)
    lst.push(1i32)
    lst.push(2i32)
    lst.sort()
    if lst[0] != 1 { return 10 }
    if lst[1] != 2 { return 11 }
    if lst[2] != 3 { return 12 }
    lst.deinit()

    return 0
}
