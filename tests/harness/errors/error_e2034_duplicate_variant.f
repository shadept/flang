//! TEST: error_e2034_duplicate_variant
//! COMPILE-ERROR: E2034

type Status = enum {
    Ok
    Error
    Ok  // ERROR: variant names must be unique within an enum
}

pub fn main() i32 {
    return 0
}
