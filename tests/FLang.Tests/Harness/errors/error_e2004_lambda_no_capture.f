//! TEST: lambda_no_capture
//! COMPILE-ERROR: E2004

// Test that lambdas cannot capture variables from enclosing scope

pub fn main() i32 {
    let x = 10
    let f = fn(y: i32) i32 { x + y }
    return f(32)
}
