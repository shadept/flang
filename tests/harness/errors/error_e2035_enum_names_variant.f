//! TEST: error_e2035_enum_names_variant
//! COMPILE-ERROR: E2035 variant `Recursive` reaches back to it

// The member that closes the loop is named, and an enum's is a variant rather than a field.
type Bad = enum {
    Value(i32)
    Recursive(Bad)
}

pub fn main() i32 {
    return 0
}
