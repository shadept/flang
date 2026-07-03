//! TEST: derive_eq
//! EXIT: 0

import std.derive

type Vec2 = struct {
    x: i32
    y: i32
}

#derive(Vec2, eq)

pub fn main() i32 {
    let a = Vec2 { x = 10, y = 20 }
    let b = Vec2 { x = 10, y = 20 }
    let c = Vec2 { x = 10, y = 99 }

    if a != b { return 1 }
    if a == c { return 2 }
    if !(a == b) { return 3 }
    if !(a != c) { return 4 }

    return 0
}
