//! TEST: closure_capture_multiple
//! EXIT: 23

// Two locals captured by value. Capture set is { a, b }; both surface as
// fields on the synthesized closure struct.

pub fn main() i32 {
    let a = 10
    let b = 13
    let f = fn() i32 { a + b }
    return f()
}
