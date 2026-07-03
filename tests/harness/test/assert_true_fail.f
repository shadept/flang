//! TEST: assert_true_fail
//! EXIT: 1
//! STDOUT: assertion failed

import std.test

pub fn main() i32 {
    assert_true(false, "assertion failed")
    return 0
}
