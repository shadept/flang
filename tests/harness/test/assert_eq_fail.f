//! TEST: assert_eq_fail
//! EXIT: 1
//! STDOUT: values not equal

import std.test

pub fn main() i32 {
    let a: i32 = 1
    let b: i32 = 2
    assert_eq(a, b, "values not equal")
    return 0
}
