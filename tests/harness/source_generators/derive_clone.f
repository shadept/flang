//! TEST: derive_clone
//! EXIT: 0

import std.derive

type Point = struct {
    x: i32
    y: i32
}

#derive(Point, clone)

pub fn main() i32 {
    let p = Point { x = 42, y = 99 }
    let q = p.clone()

    // Clone has same values
    if q.x != 42 { return 1 }
    if q.y != 99 { return 2 }

    // Mutate original — clone should be independent
    p.x = 0
    if q.x != 42 { return 3 }

    return 0
}
