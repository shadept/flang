//! TEST: error_e2037_unknown_variant
//! COMPILE-ERROR: E2037

enum Color {
    Red
    Green
    Blue
}

pub fn main() i32 {
    let c: Color = Color.Red
    return c match {
        Red => 1,
        Yellow => 2,  // ERROR: no variant `Yellow` in enum `Color`
        else => 0
    }
}
