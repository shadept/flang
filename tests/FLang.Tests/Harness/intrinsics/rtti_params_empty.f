//! TEST: rtti_params_empty
//! EXIT: 0

// Non-function types should have an empty params slice

import core.rtti

type Vec2 = struct {
    x: i32
    y: i32
}

fn check_params_empty(t: Type($T)) bool {
    return t.params.len == 0
}

pub fn main() i32 {
    // Primitive: params should be empty
    if !check_params_empty(i32) { return 1 }

    // Struct: params should be empty
    if !check_params_empty(Vec2) { return 2 }

    return 0
}
