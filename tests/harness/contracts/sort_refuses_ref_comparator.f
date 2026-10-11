//! TEST: sort_refuses_ref_comparator
//! COMPILE-ERROR: E2134
//! EXIT: 1

import std.sort

// A `&T` parameter may write; the comparator slot promises the elements are only read.
fn by_ref(a: &i32, b: &i32) Ord {
    return op_cmp(a.*, b.*)
}

pub fn main() i32 {
    let arr = [3i32, 1, 2]
    sort(arr[..], by_ref) // error E2134
    return 0
}
