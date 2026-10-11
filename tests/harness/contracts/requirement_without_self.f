//! TEST: requirement_without_self
//! COMPILE-ERROR: E2141
//! EXIT: 1

type Bad = contract {
    fn make(x: i32) i32 // error E2141
}

pub fn main() i32 {
    return 0
}
