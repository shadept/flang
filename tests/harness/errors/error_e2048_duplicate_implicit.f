//! TEST: error_e2048_duplicate_implicit
//! COMPILE-ERROR: E2048

type Bad = enum {
    A
    B
    C = 6
    D
    E = 5
    F
}

pub fn main() i32 {
    return 0
}
