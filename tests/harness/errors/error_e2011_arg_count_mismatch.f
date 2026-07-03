//! TEST: error_e2011_arg_count_mismatch
//! COMPILE-ERROR: E2011

pub fn add(a: i32, b: i32) i32 {
    return a + b
}

pub fn main() i32 {
    return add(10)  // ERROR: function `add` expects 2 arguments but 1 were provided
}
