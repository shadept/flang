//! TEST: self_declared
//! COMPILE-ERROR: E2140
//! EXIT: 1

type Self = struct { // error E2140
    x: i32
}

pub fn main() i32 {
    return 0
}
