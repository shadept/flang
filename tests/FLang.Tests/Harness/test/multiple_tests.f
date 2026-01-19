//! TEST: multiple_tests
//! EXIT: 0

import std.test

test "test one" {
    assert_true(true, "test one should pass")
}

test "test two" {
    let a: i32 = 42
    let b: i32 = 42
    assert_eq(a, b, "42 should equal 42")
}

test "test three" {
    let x: i32 = 10
    let y: i32 = 5
    let sum: i32 = x + y
    let expected: i32 = 15
    assert_eq(sum, expected, "10 + 5 should equal 15")
}

pub fn main() i32 {
    return 0
}
