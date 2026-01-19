//! TEST: assert_true_pass
//! EXIT: 0

import std.test

pub fn main() i32 {
    assert_true(true, "this should not panic")
    return 0
}
