//! TEST: closure_capture_write_reaches_outer
//! EXIT: 2

// An assignment to a captured name writes the outer binding.
pub fn main() i32 {
    let c = 0
    let bump = { => c = c + 1 }
    bump()
    bump()
    return c
}
