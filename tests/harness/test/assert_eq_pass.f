//! TEST: assert_eq_pass
//! EXIT: 0

import std.test

pub fn main() i32 {
    let a: i32 = 42
    let b: i32 = 42
    assert_eq(a, b, "values should be equal")
    return 0
}
