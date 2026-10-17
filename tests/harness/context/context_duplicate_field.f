//! TEST: context_duplicate_field
//! COMPILE-ERROR: E2005
//! EXIT: 1

context level: i32 = 0
context level: i32 = 1 // error E2005

pub fn main() i32 {
    return 0
}
