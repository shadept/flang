//! TEST: closure_capture_sees_outer_write
//! EXIT: 9

// Captures are by reference (RFC-033): the closure reads the outer `k` when it runs, not when it
// was built.
pub fn main() i32 {
    let k = 5
    let f = fn() i32 { k }
    k = 999
    return f() - 990
}
