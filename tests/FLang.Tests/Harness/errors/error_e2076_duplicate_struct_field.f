//! TEST: error_e2076_duplicate_struct_field
//! COMPILE-ERROR: E2076

type Vector2 = struct {
    x: f32
    x: f32  // ERROR: duplicate field name
    z: f32
}

pub fn main() i32 {
    return 0
}
