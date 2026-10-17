//! TEST: context_default_not_constant
//! COMPILE-ERROR: E2148
//! EXIT: 1

fn start() i32 {
    return 3
}

context level: i32 = start() // error E2148: runs code

pub fn main() i32 {
    return 0
}
