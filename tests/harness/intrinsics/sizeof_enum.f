//! TEST: sizeof_enum
//! EXIT: 4

// Test that size_of works with enum types.
// Enum names in call arguments are auto-wrapped as Type(Enum).

type Color = enum { Red, Green, Blue }

pub fn main() i32 {
    return size_of(Color) as i32
}
