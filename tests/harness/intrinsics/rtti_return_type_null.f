//! TEST: rtti_return_type_null
//! EXIT: 0

// Non-function types should have a null return_type pointer

import core.rtti

type Point = struct {
    x: i32
    y: i32
}

fn check_return_null(t: Type($T)) bool {
    return t.return_type as usize == 0
}

pub fn main() i32 {
    if !check_return_null(i32) { return 1 }
    if !check_return_null(Point) { return 2 }
    return 0
}
