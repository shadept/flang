//! TEST: struct_error_recursive
//! COMPILE-ERROR: E2035

// Error: Struct cannot contain itself directly (infinite size)
type Bad = struct {
    value: i32
    child: Bad
}

pub fn main() i32 {
    return 0
}
