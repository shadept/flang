//! TEST: enum_error_recursive
//! COMPILE-ERROR: E2035

// Error: Enum cannot contain itself directly (infinite size)
enum Bad {
    Value(i32)
    Recursive(Bad)
}

pub fn main() i32 {
    return 0
}

