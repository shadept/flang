//! TEST: error_e1001_return_in_call
//! COMPILE-ERROR: E1001

// return must not be valid in arbitrary expression position (function arguments)
fn foo(x: i32) i32 { return x }

pub fn main() i32 {
    return foo(return 3)
}
