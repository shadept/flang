//! TEST: rtti_params_empty
//! EXIT: 0

// Non-function types should have an empty params slice

import core.rtti

type Vec2 = struct {
    x: i32
    y: i32
}

pub fn main() i32 {
    // Primitive: params should be empty
    let t1 = i32
    if t1.params.len != 0 { return 1 }

    // Struct: params should be empty
    let t2 = Vec2
    if t2.params.len != 0 { return 2 }

    return 0
}
