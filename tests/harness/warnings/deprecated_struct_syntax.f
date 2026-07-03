//! TEST: deprecated_struct_syntax
//! COMPILE-ERROR: E1050
//! EXIT: 1

struct OldStyle {
    x: i32
}

pub fn main() i32 {
    let s: OldStyle = OldStyle { x = 1 }
    return 0
}
