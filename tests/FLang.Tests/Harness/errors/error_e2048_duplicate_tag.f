//! TEST: error_e2048_duplicate_tag
//! COMPILE-ERROR: E2048

type Bad = enum {
    A = 1
    B = 1
}

pub fn main() i32 {
    return 0
}
