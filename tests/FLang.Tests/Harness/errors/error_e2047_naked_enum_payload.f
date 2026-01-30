//! TEST: error_e2047_naked_enum_payload
//! COMPILE-ERROR: E2047

enum Bad {
    A = 0
    B(i32)
}

pub fn main() i32 {
    return 0
}
