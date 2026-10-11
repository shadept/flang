//! TEST: sort_refuses_unordered
//! COMPILE-ERROR: E2134
//! EXIT: 1

import std.sort

type Point = struct {
    x: i32
}

pub fn main() i32 {
    let ps = [Point { x = 2 }, Point { x = 1 }]
    sort(ps[..]) // error E2134: `Point` is not `Ordered`
    return 0
}
