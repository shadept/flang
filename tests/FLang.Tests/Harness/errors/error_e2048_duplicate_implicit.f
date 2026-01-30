//! TEST: error_e2048_duplicate_implicit
//! COMPILE-ERROR: E2048

enum Bad {
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
