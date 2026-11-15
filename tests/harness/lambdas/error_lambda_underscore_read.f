//! TEST: error_lambda_underscore_read
//! COMPILE-ERROR: E2004 `_` discards a value and cannot be read

// A `_` parameter has no name to read it by.

fn apply(f: fn(i32) i32) i32 {
    return f(1)
}

pub fn main() i32 {
    return apply { _ => _ } // error[E2004]: `_` discards a value and cannot be read
}
