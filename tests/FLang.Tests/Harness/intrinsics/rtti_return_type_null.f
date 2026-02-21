//! TEST: rtti_return_type_null
//! EXIT: 0

// Non-function types should have a null return_type pointer

import core.rtti

type Point = struct {
    x: i32
    y: i32
}

pub fn main() i32 {
    let t1 = i32
    let t2 = Point

    // return_type is &TypeInfo — should be null for non-function types
    let ptr1 = t1.return_type as usize
    if ptr1 != 0 { return 1 }

    let ptr2 = t2.return_type as usize
    if ptr2 != 0 { return 2 }

    return 0
}
