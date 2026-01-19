// Testing utilities for FLang
// Part of Milestone 16: Test Framework

import core.panic

// Assert that a condition is true, panic with message if false
pub fn assert_true(condition: bool, msg: String) {
    if (condition == false) {
        panic(msg)
    }
}

// Assert that two values are equal
// NOTE: Uses == operator, so types must support equality comparison
pub fn assert_eq(a: $T, b: T, msg: String) {
    let equal: bool = a == b
    if (equal == false) {
        panic(msg)
    }
}
