//! TEST: error_e2155_type_name_case
//! COMPILE-ERROR: E2155

// A type's name starts uppercase (RFC-039).
type point = struct {
    x: i32
}

pub fn main() i32 {
    return 0
}
