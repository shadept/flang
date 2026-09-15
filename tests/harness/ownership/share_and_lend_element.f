//! TEST: share_and_lend_element
//! COMPILE-ERROR: E2133
//! EXIT: 1

import std.collections.list

fn g(first: i32, xs: &List(i32)) i32 {
    xs.push(first)
    return first
}

// The element lives in the buffer `g` may grow while it reads `first`.
pub fn main() i32 {
    let xs: List(i32) = list(1)
    defer xs.deinit()
    xs.push(3)
    return g(xs[0], &xs)           // error E2133
}
