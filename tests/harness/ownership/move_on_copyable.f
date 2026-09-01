//! TEST: move_on_copyable
//! COMPILE-WARNING: W2005 does not consume
//! EXIT: 3

pub fn main() i32 {
    let n = 3
    let m = move n                 // warning W2005: `i32` is copyable, nothing consumes it
    return m
}
