//! TEST: tuple_op_cmp_basic
//! EXIT: 0

import std.allocator
import std.sort

pub fn main() i32 {
    // Array literal of tuples: each tuple is `(?T1, ?T2)` initially; element-wise
    // unification has to descend into the anon-tuple FieldsOrVariants so the element
    // TypeVars actually get bound to i32. Used to fail with E2001 because the
    // identity short-circuit treated TypeVars-in-tuple-fields as wildcards.
    let arr: [(i32, i32); 4] = [(2, 1), (1, 9), (1, 2), (2, 0)]

    // Lexicographic sort via the generic tuple op_cmp.
    sort(arr)

    if arr[0].0 != 1 or arr[0].1 != 2 { return 11 }
    if arr[1].0 != 1 or arr[1].1 != 9 { return 12 }
    if arr[2].0 != 2 or arr[2].1 != 0 { return 13 }
    if arr[3].0 != 2 or arr[3].1 != 1 { return 14 }
    return 0
}
