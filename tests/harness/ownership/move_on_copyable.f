//! TEST: move_on_copyable
//! COMPILE-WARNING: W2004 does not consume
//! EXIT: 3
//! SKIP: RFC-027 not implemented

pub fn main() i32 {
    let n = 3
    let m = move n                 // warning W2004: `i32` is copyable, nothing consumes it
    return m
}
